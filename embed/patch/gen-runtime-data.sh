#!/usr/bin/env bash
# Write embed_runtime_data.ml to stdout: the __compcert_i64_* helpers ccomp
# links from libcompcert.a for one target, as preprocessed source text, for
# the embed to link into images that call them.
#
# The set and the preprocessing follow CompCert's own runtime/Makefile:
#   - x86_64: i64_dtou, i64_utod, i64_utof; aarch64: none; others: all 16.
#     riscv64 is given none: its libcompcert.a has the C versions, but
#     64-bit code never calls them.
#   - runtime/<arch>/i64_*.S where it exists, preprocessed with the
#     target's compiler and -DMODEL_ -DABI_ -DENDIANNESS_ -DSYS_ from
#     compcert.ini (the Makefile's %.o: %.S rule);
#   - otherwise runtime/c/i64_*.c, preprocessed the way ccomp -E would
#     (compcert.ini's prepro and prepro_options, plus ccomp's predefined
#     macros); the embed then compiles it with CompCert itself and renames
#     i64_ to __compcert_i64_, as the Makefile's %.o: c/%.c rule does.
#
# arm also gets __aeabi_idiv/__aeabi_uidiv, which ccomp takes from libgcc:
# the embed's own C versions in runtime/arm_aeabi.c next to this script,
# compiled by the embedded CompCert like the C helpers above.
#
# Needs the target's cross compiler (compcert.ini's prepro) for every target
# that has helpers.
set -euo pipefail

usage="usage: $0 <compcert.ini> <Readconfig.ml> <Version.ml> <CompCert runtime dir>"
ini="${1:?$usage}"
readconfig="${2:?$usage}"
version="${3:?$usage}"
runtime="${4:?$usage}"
for f in "$ini" "$readconfig" "$version"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
[ -d "$runtime" ] || { echo "FATAL: missing $runtime" >&2; exit 1; }

EMBED_RUNTIME_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/runtime" && pwd)

Opam() { if command -v opam >/dev/null 2>&1; then opam exec -- "$@"; else "$@"; fi; }

script=$(mktemp --suffix=.ml)
trap 'rm -f "$script"' EXIT
{
  cat "$readconfig"
  echo "module Version = struct"
  cat "$version"
  echo "end"
  cat <<'OCAML'
let fatal fmt = Printf.ksprintf (fun m -> prerr_endline ("FATAL: " ^ m); exit 1) fmt

let get k =
  match key_val k with Some v -> v | None -> fatal "compcert.ini has no %s" k

let get1 k = match get k with [ v ] -> v | _ -> fatal "compcert.ini: %s is not one word" k

let all16 =
  [ "dtos"; "dtou"; "sar"; "sdiv"; "shl"; "shr"; "smod"; "stod"; "stof"; "udivmod"; "udiv";
    "umod"; "utod"; "utof"; "smulh"; "umulh" ]

(* Runs [prog args] and returns its stdout; any failure is fatal. *)
let capture prog args =
  let out = Filename.temp_file "embed-runtime" ".out" in
  let cmd = Filename.quote_command prog args ~stdout:out in
  if Sys.command cmd <> 0 then fatal "command failed: %s" cmd;
  let s = In_channel.with_open_bin out In_channel.input_all in
  Sys.remove out;
  s

let () =
  let ini = Sys.argv.(1) and runtime = Sys.argv.(2) in
  read_config_file ini;
  let arch = get1 "arch" and model = get1 "model" in
  let dir = match arch with "x86" -> if model = "64" then "x86_64" else "x86_32" | a -> a in
  let helpers =
    match dir with
    | "aarch64" -> []
    | "riscV" when model = "64" -> []
    | "x86_64" -> [ "dtou"; "utod"; "utof" ]
    | _ -> all16
  in
  let prepro = get1 "prepro" in
  let prepro_options = get "prepro_options" in
  let defines =
    List.map
      (fun (d, k) -> Printf.sprintf "-D%s_%s" d (get1 k))
      [ ("MODEL", "model"); ("ABI", "abi"); ("ENDIANNESS", "endianness"); ("SYS", "system") ]
  in
  (* ccomp's own -E flags (driver/Frontend.ml: predefined_macros,
     abi_macros). wchar_t is the only target-dependent one; it is only
     needed for the C fallback, which only riscv32 uses. *)
  let ccomp_macros () =
    let major, minor = Scanf.sscanf Version.version "%d.%d" (fun a b -> (a, b)) in
    let wchar =
      match arch with "riscV" -> "int" | a -> fatal "no wchar_t type recorded for arch %s" a
    in
    [ "-D__COMPCERT__"; Printf.sprintf "-D__COMPCERT_MAJOR__=%d" major;
      Printf.sprintf "-D__COMPCERT_MINOR__=%d" minor;
      Printf.sprintf "-D__COMPCERT_VERSION__=%d" ((100 * major) + minor);
      "-U__STDC_IEC_559_COMPLEX__"; "-D__STDC_NO_ATOMICS__"; "-D__STDC_NO_COMPLEX__";
      "-D__STDC_NO_THREADS__"; "-D__STDC_NO_VLA__" ]
    @ (if Version.buildnr = "" then [] else [ "-D__COMPCERT_BUILDNR__=" ^ Version.buildnr ])
    @ [ "-D__COMPCERT_WCHAR_TYPE__=" ^ wchar ]
    @ if get1 "has_standard_headers" = "true" then [ "-I" ^ Filename.concat runtime "include" ] else []
  in
  let unit h =
    let name = "i64_" ^ h in
    let s = Filename.concat (Filename.concat runtime dir) (name ^ ".S") in
    if Sys.file_exists s then
      (name, "Asm", capture prepro ([ "-E"; "-P"; "-x"; "assembler-with-cpp" ] @ defines @ [ s ]))
    else
      let c = Filename.concat (Filename.concat runtime "c") (name ^ ".c") in
      if not (Sys.file_exists c) then fatal "no source for %s" name;
      ( name,
        "C",
        capture prepro
          (prepro_options @ ccomp_macros () @ [ "-I" ^ Filename.concat runtime "c"; c ]) )
  in
  let own =
    (* the libgcc functions ccomp's arm code calls; see runtime/arm_aeabi.c *)
    if dir = "arm" then
      [ ("aeabi_div", "C",
         In_channel.with_open_bin (Filename.concat Sys.argv.(3) "arm_aeabi.c") In_channel.input_all) ]
    else []
  in
  let units = List.map unit helpers @ own in
  let delim = "embed_runtime" in
  print_string "(* Generated by gen-runtime-data.sh from CompCert's runtime/. Do not edit. *)\n\n";
  print_string "type language = Asm | C\n\n";
  print_string
    "(* Each helper ccomp links from libcompcert.a for this target, as\n\
    \   preprocessed source: assembly, or C for CompCert to compile. *)\n";
  print_string "let helpers : (string * language * string) list =\n  [\n";
  List.iter
    (fun (name, lang, text) ->
      let close = "|" ^ delim ^ "}" in
      let rec contains i =
        i + String.length close <= String.length text
        && (String.sub text i (String.length close) = close || contains (i + 1))
      in
      if contains 0 then fatal "%s contains the quoting delimiter" name;
      Printf.printf "    (%S, %s, {%s|%s|%s});\n" name lang delim text delim)
    units;
  print_string "  ]\n"
OCAML
} > "$script"
Opam ocaml "$script" "$ini" "$runtime" "$EMBED_RUNTIME_DIR"
