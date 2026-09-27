(* The CompCert-facing half of Compcert_embed, for one target. Every
   compcert_embed_<target> library copies this file and supplies
   [Embed_cc.CC], its own CompCert embed variant: the types used below are
   distinct in each build, so this cannot be shared as compiled code.

   The embed variant reads the source from [Embed_source_in.files] and prints
   into a [Buffer.t]; everything else is CompCert's own unmodified pipeline,
   driven here the way ccomp -S drives it. *)

module CC = Embed_cc.CC

(* CompCert reports through [Format.err_formatter], except for syntax errors,
   which the embed variant sends to [Embed_diag_out.stderr]. Diverting the
   formatter into a buffer for the duration of [f] keeps diagnostics off the
   host's stderr and gives them back to the caller; the previous output
   functions are restored on every path. *)
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
  Buffer.clear CC.Embed_diag_out.stderr;
  match f () with
  | v ->
      restore ();
      (* A raw fatal error (Embed_diag_out) is always the last thing reported:
         it raises [Abort] as soon as it is printed. *)
      (v, Buffer.contents buf ^ Buffer.contents CC.Embed_diag_out.stderr)
  | exception e ->
      restore ();
      raise e

(* ccomp's defaults, except for the options every fixture is compiled with:
   -fno-pie (there is no GOT to route global accesses through: images are
   bound absolutely), no -g, and -marm on arm, where the default follows the
   configured model; and -fstruct-passing, so that generated code can pass
   and return structs by value (the target's standard convention; nothing
   outside the image sees it either way). Reset before each compile because
   the options are global refs a previous caller may have changed. *)
let set_options () =
  CC.Clflags.option_fstruct_passing := true;
  CC.Clflags.option_fpie := false;
  CC.Clflags.option_fpic := false;
  CC.Clflags.option_mthumb := false;
  CC.Clflags.option_g := false

(* Varargs would need CompCert's runtime/<arch>/vararg.S, which is never
   linked. So a variadic function, defined or declared as an external, is
   refused here, on the CompCert C program, before any code is generated.
   CompCert declares some of its own builtins (__builtin_debug,
   __builtin_annot, ...) as variadic in every program; those are expanded
   inline, never called, so they are exempt. *)
let variadic_functions (p : CC.Csyntax.program) =
  List.filter_map
    (fun (id, def) ->
      match def with
      | CC.AST.Gfun (CC.Ctypes.Internal (f : CC.Csyntax.coq_function))
        when f.fn_callconv.cc_vararg <> None ->
          Some (CC.Camlcoq.extern_atom id)
      | CC.AST.Gfun (CC.Ctypes.External (CC.AST.EF_external (name, _), _, _, cc))
        when cc.CC.AST.cc_vararg <> None && not (String.starts_with ~prefix:"__builtin_" name) ->
          Some (CC.Camlcoq.extern_atom id)
      | _ -> None)
    p.CC.Ctypes.prog_defs

(* CompCert's atom tables ([Camlcoq]) intern every identifier ever seen, for the life of the
   process: ccomp compiles one unit per process, so it never notices. Here they leak between
   compiles, visibly - [C2C]'s string-literal names skip any name already interned, so the
   second compile of a program with literals printed [__stringlit_5] where ccomp prints
   [__stringlit_2] - and they grow without bound. So they are put back, before every compile,
   to what they held before the first one. *)
let atoms_at_start =
  lazy
    ( Hashtbl.copy CC.Camlcoq.atom_of_string,
      Hashtbl.copy CC.Camlcoq.string_of_atom,
      !CC.Camlcoq.next_atom )

let restore_atoms () =
  let a, s, n = Lazy.force atoms_at_start in
  let refill dst src =
    Hashtbl.reset dst;
    Hashtbl.iter (Hashtbl.add dst) src
  in
  refill CC.Camlcoq.atom_of_string a;
  refill CC.Camlcoq.string_of_atom s;
  CC.Camlcoq.next_atom := n

let render_errcode msg = Format.asprintf "%a" CC.Driveraux.print_error msg

let compile_to_asm ~name source =
  restore_atoms ();
  set_options ();
  CC.Diagnostics.reset ();
  CC.Frontend.init ();
  CC.DebugInit.init ();
  Hashtbl.replace CC.Embed_source_in.files name source;
  let compile () =
    let csyntax = CC.Frontend.parse_c_file name name in
    match variadic_functions csyntax with
    | _ :: _ as fs ->
        Error
          (Printf.sprintf
             "%s: error: variadic functions are not supported (vararg.S is never linked): %s\n" name
             (String.concat ", " fs))
    | [] -> (
        match
          CC.Compiler.apply_partial
            (CC.Compiler.transf_c_program csyntax)
            CC.Asmexpand.expand_program
        with
        | CC.Errors.OK asm ->
            (* The printer numbers its own labels from a process-wide counter
               that starts at 100; ccomp prints one unit per process, so it
               always starts there. Everything else the printers keep is reset
               per function or per file. *)
            CC.PrintAsmaux.next_label := 100;
            let out = Buffer.create 4096 in
            CC.PrintAsm.print_program out asm;
            Ok (Buffer.contents out)
        | CC.Errors.Error msg -> Error (Printf.sprintf "%s: error: %s\n" name (render_errcode msg)))
  in
  let result, diagnostics =
    Fun.protect
      ~finally:(fun () -> Hashtbl.remove CC.Embed_source_in.files name)
      (fun () ->
        capturing_diagnostics (fun () -> try compile () with CC.Diagnostics.Abort -> Error ""))
  in
  match result with Ok asm -> Ok asm | Error extra -> Error (diagnostics ^ extra)

(* Every name [runtime/Makefile] gives an [i64_] prefix in the compiled C
   helpers is renamed the way its [sed 's/i64_/__compcert_i64_/g'] does:
   CompCert refuses the reserved names in C, so the sources use short ones. *)
let rename_i64 text =
  let b = Buffer.create (String.length text + 256) in
  let n = String.length text in
  let rec go i =
    if i >= n then ()
    else if i + 4 <= n && String.sub text i 4 = "i64_" then (
      Buffer.add_string b "__compcert_i64_";
      go (i + 4))
    else (
      Buffer.add_char b text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(* The target's __compcert_i64_* helpers (Embed_runtime_data, generated at
   sync time) as assembly units. C helpers are compiled once per process,
   on first use, by this same CompCert. *)
let runtime =
  lazy
    (List.fold_left
       (fun acc (name, lang, text) ->
         Result.bind acc (fun units ->
             match lang with
             | CC.Embed_runtime_data.Asm -> Ok ((name, text) :: units)
             | CC.Embed_runtime_data.C -> (
                 match compile_to_asm ~name:(name ^ ".c") text with
                 | Ok asm -> Ok ((name, rename_i64 asm) :: units)
                 | Error m -> Error m)))
       (Ok []) CC.Embed_runtime_data.helpers
    |> Result.map List.rev)

let runtime_units () = Lazy.force runtime
