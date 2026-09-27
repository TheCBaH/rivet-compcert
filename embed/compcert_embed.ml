(* In-process CompCert for aarch64: C source text in, assembly text out, with
   no file read or written on the way.

   The embed variant of CompCert (compcert_aarch64_embed) reads the source
   from [Embed_source_in.files] and prints into a [Buffer.t]; everything else
   is CompCert's own unmodified pipeline, driven here the way ccomp -S drives
   it. Compiles share CompCert's global state, so they are serialized: this
   API is not reentrant. *)

module CC = Compcert_aarch64_embed

type error = { message : string }

(* CompCert reports through [Format.err_formatter]. Diverting it into a buffer
   for the duration of [f] keeps diagnostics off the host's stderr and gives
   them back to the caller; the previous output functions are restored on
   every path. *)
let capturing_diagnostics f =
  let buf = Buffer.create 256 in
  let saved = Format.pp_get_formatter_out_functions Format.err_formatter () in
  Format.pp_print_flush Format.err_formatter ();
  Format.pp_set_formatter_out_functions Format.err_formatter
    { saved with Format.out_string = Buffer.add_substring buf; out_flush = ignore };
  let restore () =
    Format.pp_print_flush Format.err_formatter ();
    Format.pp_set_formatter_out_functions Format.err_formatter saved
  in
  match f () with
  | v ->
      restore ();
      (v, Buffer.contents buf)
  | exception e ->
      restore ();
      raise e

(* ccomp's defaults, except for the two options every fixture is compiled
   with: -fno-pie (there is no GOT to route global accesses through: images
   are bound absolutely) and no -g. Reset before each compile because the
   options are global refs a previous caller may have changed. *)
let set_options () =
  CC.Clflags.option_fpie := false;
  CC.Clflags.option_fpic := false;
  CC.Clflags.option_g := false

(* CompCert colors its diagnostics when the host's stderr is a terminal, and
   the switch is not exported. Captured text is for the caller, not the
   terminal, so the SGR sequences are dropped. *)
let strip_colors s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '\027' && i + 1 < n && s.[i + 1] = '[' then (
      let j = ref (i + 2) in
      while !j < n && match s.[!j] with '0' .. '9' | ';' -> true | _ -> false do
        incr j
      done;
      go (if !j < n && s.[!j] = 'm' then !j + 1 else !j))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

let render_errcode msg = Format.asprintf "%a" CC.Driveraux.print_error msg

let compile_to_asm ?(name = "gen.c") source =
  set_options ();
  CC.Diagnostics.reset ();
  CC.Frontend.init ();
  CC.DebugInit.init ();
  Hashtbl.replace CC.Embed_source_in.files name source;
  let compile () =
    let csyntax = CC.Frontend.parse_c_file name name in
    match
      CC.Compiler.apply_partial (CC.Compiler.transf_c_program csyntax) CC.Asmexpand.expand_program
    with
    | CC.Errors.OK asm ->
        let out = Buffer.create 4096 in
        CC.PrintAsm.print_program out asm;
        Ok (Buffer.contents out)
    | CC.Errors.Error msg -> Error (Printf.sprintf "%s: error: %s\n" name (render_errcode msg))
  in
  let result, diagnostics =
    Fun.protect
      ~finally:(fun () -> Hashtbl.remove CC.Embed_source_in.files name)
      (fun () ->
        capturing_diagnostics (fun () -> try compile () with CC.Diagnostics.Abort -> Error ""))
  in
  match result with
  | Ok asm -> Ok asm
  | Error extra -> Error { message = strip_colors (diagnostics ^ extra) }
