(* Native vs QEMU differential over the embedded corpus.

   Each corpus program gets a zero-argument wrapper, [qemu_entry], that calls
   [entry] with a static io area, because the exec ABI's helper enters its
   guest with no arguments, and that folds [entry]'s 64-bit result into an
   [int], because the helper records only [w0], sign-extended (exec ABI v1
   §13). The same laid-out image is then run twice: natively
   by Native_exec, bound wherever the host's mapping landed, and under
   qemu-aarch64 by the exec-ABI helper, bound at the ABI's fixed addresses. The
   two results must agree with each other and with the program's recorded
   expectation.

   Usage: qemu_diff.exe <corpus-dir>. Needs the exec-ABI helpers
   (ASM_HELPERS_DIR, built by make asm-helpers) and qemu-aarch64. *)

open Asm_oracle
open Asm_oracle_run

let profile = Abi.Aarch64
let read path = In_channel.with_open_bin path In_channel.input_all

let wrapper =
  "\n\
   int qemu_entry(void) { static long io_area[512]; long v = entry((void *)io_area); return \
   (int)(v ^ (v >> 32)); }\n"

let fold v = Int64.of_int32 (Int64.to_int32 (Int64.logxor v (Int64.shift_right v 32)))
let low32 v = Int64.of_int32 (Int64.to_int32 v)

let expected source =
  Scanf.sscanf (List.hd (String.split_on_char '\n' source)) "/* expect: %Ld */" Fun.id

(* The exec ABI has one region per kind of segment; CompCert can emit several segments of a
   kind ([.rodata], [.rodata.cst8], ...), so each is packed after the previous one of its kind. *)
let region name =
  let starts p = String.starts_with ~prefix:p name in
  if starts ".text" then Abi_v2.code_addr profile
  else if starts ".rodata" then Abi_v2.rodata_addr profile
  else if starts ".data" then Abi_v2.data_addr profile
  else if starts ".bss" then Abi_v2.bss_addr profile
  else failwith ("no ABI region for section " ^ name)

let addresses (plan : Image.plan) =
  let next = Hashtbl.create 4 in
  List.map
    (fun (s : Image.segment_plan) ->
      let base = region s.seg_name in
      let at = Option.value (Hashtbl.find_opt next base) ~default:base in
      let a = Int64.of_int (max 1 s.alignment) in
      let at = Int64.mul (Int64.div (Int64.add at (Int64.sub a 1L)) a) a in
      Hashtbl.replace next base (Int64.add at (Int64.of_int (s.init_size + s.zero_fill)));
      (s.seg_name, at))
    plan.segments

let manifest (img : Image.t) ~expected =
  {
    Manifest.profile;
    case_id = 42;
    entry_addr = Option.get img.entry;
    result_addr = Abi.result_addr profile;
    stack_size = Abi.stack_size_max;
    timeout_ms = 10000;
    expected = [ expected ];
    observations = [];
    segments =
      List.map
        (fun (s : Image.segment) ->
          {
            Manifest.vaddr = s.address;
            init = s.bytes;
            zero_len = Int64.of_int s.zero_fill;
            align = max 16 s.alignment;
            perms =
              ((if s.perms.read then Abi.perm_r else 0)
              lor (if s.perms.write then Abi.perm_w else 0)
              lor if s.perms.execute then Abi.perm_x else 0);
          })
        img.segments;
  }

let qemu_value laid ~expected =
  match Image.bind_image laid ~addresses:(addresses (Image.plan_of laid)) with
  | Error e -> Error ("bind: " ^ Foundation.Diag.render e)
  | Ok img -> (
      let m = manifest img ~expected in
      let o =
        Qemu_user.run ~profile
          ~manifest:(Manifest.serialize ~abi_version:Abi.abi_version m)
          ~expected_case_id:42 ()
      in
      match (o.termination, o.record) with
      | Qemu_user.Completed, Some (Record.Valid r)
        when r.record_state = Abi.Returned && Array.length r.values = 1 ->
          Ok r.values.(0)
      | _ -> Error (Fmt.str "%a" Qemu_user.pp o))

let () =
  let dir = Sys.argv.(1) in
  let files =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".c")
    |> List.sort compare
  in
  let failures = ref 0 in
  List.iter
    (fun file ->
      let source = read (Filename.concat dir file) in
      let want = fold (expected source) in
      let line =
        match Compcert_embed_aarch64.compile ~entry:"qemu_entry" ~name:file (source ^ wrapper) with
        | Error e -> Error (Format.asprintf "%a" Compcert_embed.pp_error e)
        | Ok laid -> (
            let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 16 in
            match Native_exec.run laid ~io with
            | Error e -> Error (Format.asprintf "native: %a" Native_exec.pp_error e)
            | Ok { value; _ } -> (
                (* [qemu_entry] returns an [int]: only [w0] is defined. *)
                let native = low32 value in
                match qemu_value laid ~expected:want with
                | Error m -> Error ("qemu: " ^ m)
                | Ok q ->
                    if native = q && q = want then Ok (Printf.sprintf "native = qemu = %Ld" q)
                    else Error (Printf.sprintf "native %Ld, qemu %Ld, expected %Ld" native q want)))
      in
      match line with
      | Ok m -> Printf.printf "  ok   %-28s %s\n" file m
      | Error m ->
          incr failures;
          Printf.printf "  FAIL %-28s %s\n" file m)
    files;
  Printf.printf "%d programs, %d failures\n" (List.length files) !failures;
  if !failures > 0 then exit 1
