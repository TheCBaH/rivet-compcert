(* Proves the CompCert Asm.program adapter (adapter.ml) end to end: a real
   in-process CompCert compile of the return42/asm_test_entry fixture on
   aarch64, run through Adapter.convert, compared against
   asm/test/coherence/test_coherence.ml's direct_normalized/direct_lowered
   and against the text (parse/simplify) path - the "fourth producer" against
   the same assertions that file already makes (next.md "the direct CompCert
   integration", Order item 2). *)

module CC = Compcert_aarch64
module P = Driver.Registry.Aarch64
module T = Aarch64
open Asm_core

(* Byte-for-byte copy of
   asm/fixtures/compcert-3.17/return42/source/asm_test_entry.c - diffed
   against that file at authoring time, not transcribed from memory. Deliberately one
   physical line with explicit \n escapes rather than OCaml's
   backslash-newline continuation: that continuation mechanism strips all
   leading whitespace from each continued line, which would silently eat the
   C comment's real 3-space indentation. *)
let asm_test_entry_c =
  "/* The M1 walking skeleton (.ai/asm_plan.md). Compiled by four unmodified\n\
  \   CompCert 3.17 configurations; the 26 instruction forms those four outputs\n\
  \   contain *are* the M1 scope.\n\n\
  \   Deliberately minimal: the point is not to exercise the compiler but to pin a\n\
  \   relocation-free .text whose bytes our assembler must reproduce exactly. The\n\
  \   only relocation any of the four objects carries is R_*_PC32/PREL32 in\n\
  \   .eh_frame, from .cfi_*, which we discard. */\n\
   int asm_test_entry(void) { return 42; }\n"

let render_error (msg : CC.Errors.errcode list) : string =
  Format.asprintf "%a" CC.Driveraux.print_error msg

let compile_via_compcert () : CC.Asm.program =
  let tmp = Filename.temp_file "asm_test_entry" ".c" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp)
    (fun () ->
      let oc = open_out tmp in
      output_string oc asm_test_entry_c;
      close_out oc;
      CC.Frontend.init ();
      let csyntax = CC.Frontend.parse_c_file tmp tmp in
      match
        CC.Compiler.apply_partial (CC.Compiler.transf_c_program csyntax) CC.Asmexpand.expand_program
      with
      | CC.Errors.OK asm -> asm
      | CC.Errors.Error msg -> failwith (render_error msg))

(* Correction from plan review: Pmovz's third/fourth fields are BinNums.coq_Z
   (an extracted variant), not plain OCaml ints - Camlcoq.Z.of_sint builds
   them from an int. This is the only place a nonzero movz shift amount is
   exercised, since return42's own Pmovz always carries pos = 0. *)
let%expect_test "Pmovz with a nonzero shift amount converts to a trailing lsl Shift operand" =
  let synthetic =
    CC.Asm.Pmovz (CC.Asm.W, CC.Asm.X0, CC.Camlcoq.Z.of_sint 42, CC.Camlcoq.Z.of_sint 16)
  in
  (match Adapter.convert_instr synthetic with
  | Some { T.Instruction.ops; _ } ->
      if
        List.exists
          (function T.Operand.Shift { T.Shift.kind = "lsl"; amount = 16 } -> true | _ -> false)
          ops
      then print_endline "shift operand present"
      else print_endline "shift operand MISSING"
  | None -> print_endline "convert_instr returned None");
  [%expect {| shift operand present |}]

let render_normalized = Fmt.to_to_string (Normalized_ast.pp T.Instruction.pp)
let render_lowered = Fmt.to_to_string Lowered_ast.pp

let%expect_test
    "the CompCert adapter's output on a real compile of return42 equals the direct normalized AST \
     and the text path, and lowers identically to the direct lowered module" =
  let adapted = Adapter.convert (compile_via_compcert ()) in
  let a = render_normalized adapted in
  let b = render_normalized Test_coherence.direct_normalized in
  let parsed, _ = Test_coherence.from_text () in
  let c = render_normalized parsed in
  if String.equal a b && String.equal b c then
    print_endline "adapter, direct, and text-path normalized ASTs are identical"
  else Printf.printf "NORMALIZED ASTS DIFFER\n--- adapter\n%s\n--- direct\n%s\n--- text\n%s\n" a b c;
  (match P.lower ~state:T.default_state adapted with
  | Error ds -> print_endline (Foundation.Diag.render ds)
  | Ok low ->
      let low_a = render_lowered low in
      let low_b = render_lowered Test_coherence.direct_lowered in
      if String.equal low_a low_b then print_endline "adapter lowers identically to direct_lowered"
      else Printf.printf "LOWERED MODULES DIFFER\n--- adapter\n%s\n--- direct\n%s\n" low_a low_b);
  [%expect
    {|
    adapter, direct, and text-path normalized ASTs are identical
    adapter lowers identically to direct_lowered
    |}]
