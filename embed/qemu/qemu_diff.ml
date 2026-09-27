(* The embedded corpus under QEMU, for one target, and natively as well
   where this host runs that target's ISA. Every
   compcert_embed/targets/<target>/test copies this file and supplies
   [Embed], its target's instance of Compcert_embed.Make.

   Each corpus program gets a zero-argument wrapper, [qemu_entry], that calls
   [entry] with a static io area, because the exec ABI's helper enters its
   guest with no arguments, and returns [entry]'s result as an [int], because
   the helper records only the low 32 bits of the return register (exec ABI
   v1 §13). The programs fold their own results to 32 bits, so nothing is
   lost. The laid-out image is run under the target's QEMU by the exec-ABI
   helper, bound at the ABI's fixed addresses, and, on a host of the same
   ISA, natively by Native_exec as well. Every result must equal the
   program's recorded expectation.

   Usage: qemu_diff.exe [--native-only] <corpus-dir>. Needs the exec-ABI helpers
   (ASM_HELPERS_DIR, built by make asm-helpers) and the target's QEMU, except with
   --native-only, which runs natively only and checks against the general expectation (for
   a process that cannot start QEMU itself, such as one already running under it). *)

open Asm_oracle
open Asm_oracle_run

let target = Embed.target

let profile =
  match Abi.profile_of_name target with
  | Some p -> p
  | None -> failwith ("no exec-ABI profile for " ^ target)

let read path = In_channel.with_open_bin path In_channel.input_all

let wrapper =
  "\nint qemu_entry(void) { static long long io_area[512]; return (int)entry((void *)io_area); }\n"

let low32 v = Int64.of_int32 (Int64.to_int32 v)

(* The first line is the program's value on every target. A line
   [/* qemu <target>: <value> -- <reason>] replaces it for that target under
   QEMU only, where the emulator itself is known to compute something else. *)
let expected source =
  let lines = String.split_on_char '\n' source in
  let override =
    List.find_map
      (fun l ->
        try Scanf.sscanf l "/* qemu %s@: %Ld --" (fun t v -> if t = target then Some v else None)
        with Scanf.Scan_failure _ | End_of_file | Failure _ -> None)
      lines
  in
  let general = Scanf.sscanf (List.hd lines) "/* expect: %Ld */" Fun.id in
  (general, override)

(* The exec ABI has one region per kind of segment; CompCert can emit several segments of a
   kind ([.rodata], [.rodata.cst8], ...), so each is placed on the page after the previous one
   of its kind. *)
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
      (* The runner maps each segment on whole pages (exec ABI v1 §9), so two segments may
         not share one, whatever their own alignment. *)
      let a = Int64.of_int (max 4096 s.alignment) in
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
      (* v2: the first exec-ABI version with the RISC-V profiles, and the one whose BSS window
         [region] uses *)
      let abi_version = Abi_v2.abi_version in
      let o =
        Qemu_user.run ~abi_version ~profile
          ~manifest:(Manifest.serialize ~abi_version m)
          ~expected_case_id:42 ()
      in
      match (o.termination, o.record) with
      | Qemu_user.Completed, Some (Record.Valid r)
        when r.record_state = Abi.Returned && Array.length r.values = 1 ->
          Ok r.values.(0)
      | _ -> Error (Fmt.str "%a" Qemu_user.pp o))

let () =
  let native_only, dir =
    match Sys.argv with
    | [| _; "--native-only"; d |] -> (true, d)
    | [| _; d |] -> (false, d)
    | _ ->
        prerr_endline "usage: qemu_diff.exe [--native-only] <corpus-dir>";
        exit 2
  in
  let files =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".c")
    |> List.sort compare
  in
  let failures = ref 0 in
  let native = Native_exec.host_isa = Some target in
  if native_only && not native then (
    Printf.printf "target %s: --native-only needs a host of this ISA\n" target;
    exit 2);
  Printf.printf "target %s, %s\n" target
    (if native_only then "native only"
     else if native then "native and qemu"
     else "qemu only (not this host's ISA)");
  List.iter
    (fun file ->
      let source = read (Filename.concat dir file) in
      let general, qemu_override = expected source in
      let want = Option.value qemu_override ~default:general in
      let line =
        match Embed.compile ~entry:"qemu_entry" ~name:file (source ^ wrapper) with
        | Error e -> Error (Format.asprintf "%a" Compcert_embed.pp_error e)
        | Ok laid -> (
            let native_value =
              if not native then Ok None
              else
                let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 16 in
                match Native_exec.run ~target laid ~io with
                | Error e -> Error (Format.asprintf "native: %a" Native_exec.pp_error e)
                (* [qemu_entry] returns an [int]: only the low 32 bits are defined. *)
                | Ok { value; _ } -> Ok (Some (low32 value))
            in
            match native_value with
            | Error m -> Error m
            | Ok (Some n) when native_only -> (
                (* the same image again in a forked child (~isolate:true) *)
                let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 16 in
                match Native_exec.run ~target ~isolate:true laid ~io with
                | Error e -> Error (Format.asprintf "isolated: %a" Native_exec.pp_error e)
                | Ok { value; _ } ->
                    let iso = low32 value in
                    if n = general && iso = general then
                      Ok (Printf.sprintf "native = isolated = %Ld" n)
                    else
                      Error (Printf.sprintf "native %Ld, isolated %Ld, expected %Ld" n iso general))
            | Ok nv -> (
                match qemu_value laid ~expected:want with
                | Error m -> Error ("qemu: " ^ m)
                | Ok q -> (
                    match nv with
                    | Some n when n = general && q = want ->
                        Ok
                          (if n = q then Printf.sprintf "native = qemu = %Ld" q
                           else Printf.sprintf "native = %Ld, qemu = %Ld (recorded)" n q)
                    | None when q = want ->
                        Ok
                          (if qemu_override = None then Printf.sprintf "qemu = %Ld" q
                           else Printf.sprintf "qemu = %Ld (recorded for this target)" q)
                    | _ ->
                        Error
                          (Printf.sprintf "%sqemu %Ld, expected %Ld"
                             (match nv with
                             | Some n -> Printf.sprintf "native %Ld, " n
                             | None -> "")
                             q want))))
      in
      match line with
      | Ok m -> Printf.printf "  ok   %-28s %s\n" file m
      | Error m ->
          incr failures;
          Printf.printf "  FAIL %-28s %s\n" file m)
    files;
  (* A fault in generated code, contained by isolation and classified by signal. *)
  (if native_only then
     match Embed.compile "long entry(void *io) { *(volatile long *)8 = 1; return 0; }\n" with
     | Error e -> Format.printf "  FAIL fault program: %a@." Compcert_embed.pp_error e
     | Ok laid -> (
         let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 16 in
         match Native_exec.run ~target ~isolate:true laid ~io with
         | Error (Native_exec.Signal _ as e) ->
             Format.printf "  ok   isolated fault: %a@." Native_exec.pp_error e
         | Error e ->
             incr failures;
             Format.printf "  FAIL isolated fault: %a@." Native_exec.pp_error e
         | Ok _ ->
             incr failures;
             print_endline "  FAIL isolated fault: returned normally"));
  Printf.printf "%d programs, %d failures\n" (List.length files) !failures;
  if !failures > 0 then exit 1
