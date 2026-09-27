(* The Tier A checks for one target: C source in memory -> assembly text ->
   laid-out image, against the committed CompCert fixtures. Every
   compcert_embed/targets/<target>/test copies this file and supplies
   [Embed], its target's instance of Compcert_embed.Make; the report is
   compared with that target's tier_a.expected.

   Usage:
     tier_a_test.exe <fixtures-dir>   the report
     tier_a_test.exe --probe <file.c> compile one file and print the assembly;
                                      the file is read before a
                                      "--- compile start" marker on stderr, so
                                      an strace of the compile itself can be
                                      told apart from it *)

let read path = In_channel.with_open_bin path In_channel.input_all
let ( / ) = Filename.concat
let target = Embed.target
let pp_error = Compcert_embed.pp_error

(* The header comment recording the argv of whichever process compiled; its
   comment leader is the target's (//, #, @). *)
let is_command_line l =
  List.exists (fun c -> String.starts_with ~prefix:(c ^ " Command line:") l) [ "//"; "#"; "@" ]

let without_command_line text =
  String.split_on_char '\n' text |> List.filter (fun l -> not (is_command_line l))

(* The first line where [got] departs from [want], for a readable report. *)
let first_difference want got =
  let rec go i = function
    | w :: ws, g :: gs -> if String.equal w g then go (i + 1) (ws, gs) else Some (i, w, g)
    | [], g :: _ -> Some (i, "<end>", g)
    | w :: _, [] -> Some (i, w, "<end>")
    | [], [] -> None
  in
  go 1 (want, got)

let manifest_values fixtures case key =
  read (fixtures / case / "manifest.txt")
  |> String.split_on_char '\n'
  |> List.filter_map (fun l ->
      match String.split_on_char '\t' l with
      | [ k; v ] when k = key -> Some v
      | k :: _ when k = key -> Some ""
      | _ -> None)

(* The cases with a build for this target, and their C sources. *)
let cases fixtures =
  Sys.readdir fixtures |> Array.to_list |> List.sort compare
  |> List.filter (fun c -> Sys.file_exists (fixtures / c / target))

let sources fixtures case =
  let dir = fixtures / case / "source" in
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.filter (fun f -> Filename.check_suffix f ".c")
  |> List.map (fun f -> (f, read (dir / f)))

(* The ccomp flags each fixture was compiled with, which the shim always sets.
   Anything else would need passing through, so it is reported. *)
let known_flags = [ "-fno-pie"; "-marm" ]

let check_flags fixtures case =
  match manifest_values fixtures case ("ccomp-args:" ^ target) with
  | [ args ] ->
      String.split_on_char ' ' args
      |> List.filter (fun f -> f <> "" && not (List.mem f known_flags))
      |> List.iter (fun f -> Printf.printf "%s: flag %s is not set by the shim\n" case f)
  | _ -> Printf.printf "%s: no ccomp-args:%s in manifest.txt\n" case target

(* {1 C -> assembly} *)

let identity fixtures =
  print_endline "== C -> assembly: byte identity with ccomp -S (command-line comment excluded)";
  List.iter
    (fun case ->
      check_flags fixtures case;
      List.iter
        (fun (file, c) ->
          let want = fixtures / case / target / (Filename.chop_suffix file ".c" ^ ".s") in
          match Embed.compile_to_asm ~name:file c with
          | Error e -> Format.printf "%s/%s: ERROR %a@." case file pp_error e
          | Ok asm ->
              let n = String.split_on_char '\n' asm |> List.filter is_command_line |> List.length in
              Printf.printf "%s/%s: %s%s\n" case file
                (match
                   first_difference (without_command_line (read want)) (without_command_line asm)
                 with
                | None -> "identical"
                | Some (i, w, g) -> Printf.sprintf "DIFFERS at line %d:\n  want %S\n  got  %S" i w g)
                (if n = 1 then "" else Printf.sprintf " (%d command-line lines)" n))
        (sources fixtures case))
    (cases fixtures)

let print_result = function
  | Ok _ -> print_endline "Ok"
  | Error (e : Compcert_embed.error) -> Printf.printf "Error:\n%s" e.message

let syntax_error = "int entry(void) { return 1 +; }\n"

let errors () =
  print_endline "== C -> assembly: errors";
  print_result (Embed.compile_to_asm ~name:"bad.c" syntax_error);
  print_result
    (Embed.compile_to_asm ~name:"bad.c"
       "struct s { int a; };\nint entry(void) { struct s x; return x + 1; }\n");
  print_result (Embed.compile_to_asm "int entry(void) { return 7; }\n")

(* Shapes the fixtures lack, whose printing keeps per-target state: jump
   tables, float and 64-bit literals (constant pools on arm, literal tables on
   x86 and riscv). State that leaks from one compile into the next shows up as
   a mismatch below. *)
let printer_state_inputs =
  [
    ( "switch.c",
      "int entry(int x) { switch (x) { case 0: return 11; case 1: return 22; case 2: return 33;\n\
       case 3: return 44; case 4: return 55; case 5: return 66; default: return 0; } }\n" );
    ( "floats.c",
      "double k(double x) { return x * 3.25 + 1.0e10; }\n\
       float f(float x) { return x * 0.5f - 7.75f; }\n\
       int entry(void) { return (int)(k(2.0) / 1.0e9) + (int)f(20.0f); }\n" );
    ( "wide.c",
      "long long entry(void) { long long a = 0x123456789abcdefLL; return a ^ 0x0fedcba987654321LL; }\n"
    );
  ]

let repeated fixtures =
  print_endline "== C -> assembly: 100 sequential compiles";
  let inputs =
    List.concat_map
      (fun case ->
        List.map (fun (file, c) () -> Embed.compile_to_asm ~name:file c) (sources fixtures case))
      (cases fixtures)
    @ List.map (fun (name, c) () -> Embed.compile_to_asm ~name c) printer_state_inputs
    @ [ (fun () -> Embed.compile_to_asm ~name:"bad.c" syntax_error) ]
  in
  let render = function
    | Ok s -> "ok\n" ^ s
    | Error (e : Compcert_embed.error) -> "error\n" ^ e.message
  in
  let first = List.map (fun f -> render (f ())) inputs in
  let n = List.length inputs in
  let mismatches = ref 0 in
  for i = 0 to 99 do
    let k = i mod n in
    if not (String.equal (render ((List.nth inputs k) ())) (List.nth first k)) then incr mismatches
  done;
  Printf.printf "inputs: %d, compiles: 100, mismatches: %d\n" n !mismatches

(* {1 Assembly -> image} *)

(* [*.hex]: whitespace-separated bytes in memory order. *)
let bytes_of_hex path =
  read path |> String.split_on_char '\n'
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (( <> ) "")
  |> List.map (fun h -> Char.chr (int_of_string ("0x" ^ h)))
  |> List.to_seq |> String.of_seq

let linked fixtures case =
  read (fixtures / case / target / "oracle" / "linked" / "manifest.txt")
  |> String.split_on_char '\n'
  |> List.filter_map (fun l ->
      match String.split_on_char '\t' (String.trim l) with
      | [ sec; kind; addr; size; file ] when sec <> "" ->
          Some (sec, kind, Int64.of_string addr, int_of_string size, file)
      | _ -> None)

(* The fixture's own runtime helpers (manifest [origin:] lines), linked the
   way the oracle linked them: from the committed preprocessed [.s]. *)
let helper_units fixtures case =
  read (fixtures / case / "manifest.txt")
  |> String.split_on_char '\n'
  |> List.filter_map (fun l ->
      match String.split_on_char '\t' l with
      | [ k; _ ] when String.starts_with ~prefix:"origin:" k ->
          let stem = String.sub k 7 (String.length k - 7) in
          let s = fixtures / case / target / (stem ^ ".s") in
          if Sys.file_exists s then Some (stem, read s) else None
      | _ -> None)

let link_one ?(with_fixture_helpers = true) fixtures case =
  let compiled =
    List.map
      (fun (file, c) ->
        match Embed.compile_to_asm ~name:file c with
        | Ok s -> (Filename.chop_suffix file ".c", s)
        | Error e -> failwith (Format.asprintf "%a" pp_error e))
      (sources fixtures case)
  in
  let helpers = if with_fixture_helpers then helper_units fixtures case else [] in
  let label = if with_fixture_helpers then case else case ^ " (embed helpers)" in
  match Embed.assemble_units ~entry:"asm_test_entry" (compiled @ helpers) with
  | Error e -> Format.printf "%s: %a@." label pp_error e
  | Ok laid -> (
      let m = linked fixtures case in
      let addresses = List.map (fun (sec, _, a, _, _) -> (sec, a)) m in
      match Image.bind_image laid ~addresses with
      | Error e -> Printf.printf "%s: BIND %s\n" label (Foundation.Diag.render e)
      | Ok image ->
          List.iter
            (fun (sec, kind, _, size, file) ->
              match List.find_opt (fun (s : Image.segment) -> s.name = sec) image.segments with
              | None -> Printf.printf "%s %s: missing\n" label sec
              | Some s ->
                  let ours = String.length s.bytes + s.zero_fill in
                  if kind = "nobits" then
                    Printf.printf "%s %s: %s\n" label sec
                      (if ours = size && s.bytes = "" then "size matches" else "SIZE DIFFERS")
                  else
                    let want = bytes_of_hex (fixtures / case / target / "oracle" / file) in
                    Printf.printf "%s %s: %s\n" label sec
                      (if String.equal want s.bytes then "identical" else "BYTES DIFFER"))
            m)

let link fixtures =
  print_endline "== assembly -> image: GNU ld oracle bytes at the oracle's addresses";
  List.iter
    (fun case ->
      if Sys.file_exists (fixtures / case / target / "oracle" / "linked" / "manifest.txt") then
        try link_one fixtures case with Failure m -> Printf.printf "%s: %s" case m)
    (cases fixtures)

(* {1 Runtime helpers} *)

(* Uses every operation CompCert may implement with a __compcert_i64_*
   helper on a 32-bit target: 64-bit division and remainder (by a variable,
   and by a constant, which becomes a multiply-high), variable shifts, and
   conversions between 64-bit integers and floating point. *)
let helper_program =
  "long long sdiv(long long x, long long y) { return x / y + x % y; }\n\
   unsigned long long udiv(unsigned long long x, unsigned long long y) { return x / y + x % y; }\n\
   long long sconst(long long x) { return x / 7; }\n\
   unsigned long long uconst(unsigned long long x) { return x / 7; }\n\
   long long shifts(long long x, int n) { return (x << n) + (x >> n); }\n\
   unsigned long long ushr(unsigned long long x, int n) { return x >> n; }\n\
   double stod(long long x) { return (double)x; }\n\
   double utod(unsigned long long x) { return (double)x; }\n\
   float stof(long long x) { return (float)x; }\n\
   float utof(unsigned long long x) { return (float)x; }\n\
   long long dtos(double x) { return (long long)x; }\n\
   unsigned long long dtou(double x) { return (unsigned long long)x; }\n\
   int entry(void) { return 0; }\n"

let runtime fixtures =
  print_endline "== runtime helpers";
  match Embed.runtime_units () with
  | Error e -> Format.printf "ERROR %a@." pp_error e
  | Ok units ->
      Printf.printf "available: %s\n"
        (match units with [] -> "none" | us -> String.concat " " (List.map fst us));
      (* The same helper, preprocessed for a fixture, must be the same text. *)
      List.iter
        (fun (name, text) ->
          List.iter
            (fun case ->
              let f = fixtures / case / target / (name ^ ".s") in
              if Sys.file_exists f then
                Printf.printf "%s vs %s/%s/%s.s: %s\n" name case target name
                  (if String.equal (read f) text then "identical" else "DIFFERS"))
            (cases fixtures))
        units;
      (* Each helper on its own, entered at its own symbol (with whatever
         other helpers it calls), so that one unit's failure hides no other. *)
      List.iter
        (fun (name, text) ->
          let entry = "__compcert_" ^ name in
          Printf.printf "%s: %s\n" name
            (match Embed.assemble_units ~entry [ (name, text) ] with
            | Ok _ -> "ok"
            | Error e -> Format.asprintf "%a" pp_error e))
        units;
      (match Embed.compile_to_asm ~name:"helpers.c" helper_program with
      | Error e -> Format.printf "helpers.c: ERROR %a@." pp_error e
      | Ok asm -> (
          match Embed.with_runtime [ ("helpers", asm) ] with
          | Error e -> Format.printf "helpers.c: ERROR %a@." pp_error e
          | Ok us ->
              Printf.printf "helpers.c links: %s\n"
                (match List.tl us with [] -> "none" | hs -> String.concat " " (List.map fst hs));
              Printf.printf "helpers.c plans: %s\n"
                (match Embed.assemble_units us with
                | Ok _ -> "ok"
                | Error e -> Format.asprintf "%a" pp_error e)));
      (* A case that the oracle linked with the fixture's own helper copies,
         linked instead with the embed's. *)
      List.iter
        (fun case ->
          if helper_units fixtures case <> [] then
            link_one ~with_fixture_helpers:false fixtures case)
        (cases fixtures)

let stages () =
  print_endline "== stage-tagged errors";
  (match Embed.compile "extern int helper(int);\nlong entry(void *io) { return helper(3); }\n" with
  | Ok _ -> print_endline "unexpectedly Ok"
  | Error e ->
      Printf.printf "stage %s, codes %s\n%s\n"
        (Compcert_embed.stage_name e.stage)
        (String.concat "," e.codes) e.message);
  match Embed.compile "long entry(void *io) { return 1 +; }\n" with
  | Ok _ -> print_endline "unexpectedly Ok"
  | Error e -> Printf.printf "stage %s\n" (Compcert_embed.stage_name e.stage)

let probe file =
  let source = read file in
  prerr_endline "--- compile start";
  match Embed.compile_to_asm ~name:(Filename.basename file) source with
  | Ok asm -> print_string asm
  | Error e ->
      Format.eprintf "%a@." pp_error e;
      exit 1

let () =
  match Sys.argv with
  | [| _; "--probe"; file |] -> probe file
  | [| _; fixtures |] ->
      Printf.printf "target %s\n" target;
      identity fixtures;
      errors ();
      repeated fixtures;
      link fixtures;
      runtime fixtures;
      stages ()
  | _ ->
      prerr_endline "usage: tier_a_test.exe <fixtures-dir> | --probe <file.c>";
      exit 2
