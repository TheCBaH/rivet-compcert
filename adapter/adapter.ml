(* CompCert Asm.program -> Normalized_ast.module_, scoped to exactly the six
   instruction forms the aarch64 return42/asm_test_entry fixture needs. Not a
   general N-instruction, N-global program converter - widening past this
   one fixture is future work.

   The directive synthesis in [items_of_function] below (.text/.align/
   .globl/.type/.size/.note.GNU-stack) is validated against this fixture's
   own committed oracle output
   (asm/fixtures/compcert-3.17/return42/aarch64/asm_test_entry.s) and against
   PrintAsm/TargetPrinter's own ELF/aarch64-specific printing convention -
   Asm.program itself carries no directive nodes at all, so this is a
   fixture-specific reconstruction of what CompCert always prints around a
   single global function, not something inferred generically from the
   program value. *)

module CC = Compcert_aarch64
module CC_asm = CC.Asm
open Asm_core

let origin = Foundation.Origin.synthesized ~pass:"compcert-adapter" ()

let imm (z : CC.BinNums.coq_Z) : Aarch64.Operand.t =
  Aarch64.Operand.Imm (Foundation.Bigint.of_int64 (CC.Camlcoq.Z.to_int64 z))

let reg ?(width = 64) ?(is_sp = false) (num : int) : Aarch64.Reg.t =
  { Aarch64.Reg.num; width; is_sp }

let ireg_num : CC_asm.ireg -> int = function
  | CC_asm.X0 -> 0
  | CC_asm.X1 -> 1
  | CC_asm.X2 -> 2
  | CC_asm.X3 -> 3
  | CC_asm.X4 -> 4
  | CC_asm.X5 -> 5
  | CC_asm.X6 -> 6
  | CC_asm.X7 -> 7
  | CC_asm.X8 -> 8
  | CC_asm.X9 -> 9
  | CC_asm.X10 -> 10
  | CC_asm.X11 -> 11
  | CC_asm.X12 -> 12
  | CC_asm.X13 -> 13
  | CC_asm.X14 -> 14
  | CC_asm.X15 -> 15
  | CC_asm.X16 -> 16
  | CC_asm.X17 -> 17
  | CC_asm.X18 -> 18
  | CC_asm.X19 -> 19
  | CC_asm.X20 -> 20
  | CC_asm.X21 -> 21
  | CC_asm.X22 -> 22
  | CC_asm.X23 -> 23
  | CC_asm.X24 -> 24
  | CC_asm.X25 -> 25
  | CC_asm.X26 -> 26
  | CC_asm.X27 -> 27
  | CC_asm.X28 -> 28
  | CC_asm.X29 -> 29
  | CC_asm.X30 -> 30

let ireg_reg ?width (r : CC_asm.ireg) : Aarch64.Reg.t = reg ?width (ireg_num r)

let iregsp_reg ?width : CC_asm.iregsp -> Aarch64.Reg.t = function
  | CC_asm.RR1 r -> ireg_reg ?width r
  | CC_asm.XSP -> reg ?width ~is_sp:true 31

let width_of_isize : CC_asm.isize -> int = function CC_asm.W -> 32 | CC_asm.X -> 64

let mem_of_addressing (a : CC_asm.addressing) : Aarch64.Mem.t =
  match a with
  | CC_asm.ADimm (base, off) ->
      {
        Aarch64.Mem.base = iregsp_reg base;
        offset = Aarch64.Disp.Const (CC.Camlcoq.camlint64_of_coqint off);
        writeback = false;
        pre = true;
      }
  | CC_asm.ADpreincr (base, off) ->
      {
        Aarch64.Mem.base = iregsp_reg base;
        offset = Aarch64.Disp.Const (CC.Camlcoq.camlint64_of_coqint off);
        writeback = true;
        pre = true;
      }
  | _ -> failwith "Compcert_adapter.mem_of_addressing: addressing mode out of return42 scope"

(* [None] for Pcfi_adjust/Pcfi_rel_offset: Asmexpand's expansion of
   Pallocframe emits these into fn_code (matching the real
   .cfi_adjust_cfa_offset/.cfi_rel_offset lines PrintAsm prints), but the
   text-parsing path discards .cfi_* directives as pure metadata
   (asm/lib/asm_core/directive.ml's own doc comment), so a producer that
   wants to agree with that path must drop them too, not convert or reject
   them. Exposed (not just used inside [convert]) so test_adapter.ml can
   unit-test the Pmovz nonzero-shift case directly. *)
let convert_instr (i : CC_asm.instruction) : Aarch64.Instruction.t option =
  match i with
  | CC_asm.Pcfi_adjust _ | CC_asm.Pcfi_rel_offset _ -> None
  | CC_asm.Pmov (rd, rs) ->
      Some
        {
          Aarch64.Instruction.op = Aarch64.Opcode.Mov;
          ops = [ Aarch64.Operand.Reg (iregsp_reg rd); Aarch64.Operand.Reg (iregsp_reg rs) ];
        }
  | CC_asm.Pstp (r1, r2, addr) ->
      Some
        {
          Aarch64.Instruction.op = Aarch64.Opcode.Stp;
          ops =
            [
              Aarch64.Operand.Reg (ireg_reg r1);
              Aarch64.Operand.Reg (ireg_reg r2);
              Aarch64.Operand.Mem (mem_of_addressing addr);
            ];
        }
  | CC_asm.Pmovz (sz, rd, n, pos) ->
      let width = width_of_isize sz in
      (* [pos] is already the printed lsl bit amount (0/16/32/48), the same
         unit Operand.Shift.amount uses - see adapter.ml's plan notes. Do not
         divide by 16. *)
      let amount = Int64.to_int (CC.Camlcoq.Z.to_int64 pos) in
      let shift =
        if amount = 0 then [] else [ Aarch64.Operand.Shift { Aarch64.Shift.kind = "lsl"; amount } ]
      in
      Some
        {
          Aarch64.Instruction.op = Aarch64.Opcode.Movz;
          ops = Aarch64.Operand.Reg (ireg_reg ~width rd) :: imm n :: shift;
        }
  | CC_asm.Pldrx (rd, addr) ->
      Some
        {
          Aarch64.Instruction.op = Aarch64.Opcode.Ldr;
          ops = [ Aarch64.Operand.Reg (ireg_reg rd); Aarch64.Operand.Mem (mem_of_addressing addr) ];
        }
  | CC_asm.Paddimm (sz, rd, rn, n) ->
      let width = width_of_isize sz in
      Some
        {
          Aarch64.Instruction.op = Aarch64.Opcode.Add;
          ops =
            [
              Aarch64.Operand.Reg (iregsp_reg ~width rd);
              Aarch64.Operand.Reg (iregsp_reg ~width rn);
              imm n;
            ];
        }
  | CC_asm.Pret rd ->
      Some
        { Aarch64.Instruction.op = Aarch64.Opcode.Ret; ops = [ Aarch64.Operand.Reg (ireg_reg rd) ] }
  | _ -> failwith "Compcert_adapter.convert_instr: instruction out of return42 scope"

let items_of_function (name : string) (f : CC_asm.coq_function) =
  let insn i = Normalized_ast.Instruction { insn = i; origin } in
  let dir d = Normalized_ast.Directive { directive = d; origin } in
  List.concat
    [
      [
        dir (Directive.Section { name = ".text"; perms = Perms.rx; nobits = false });
        dir (Directive.Align { boundary = 4 });
        dir (Directive.Global { name });
        Normalized_ast.Label { name; origin };
      ];
      List.filter_map (fun i -> Option.map insn (convert_instr i)) f.CC_asm.fn_code;
      [
        dir (Directive.Sym_type { name; kind = Directive.Function });
        dir
          (Directive.Sym_size
             { name; size = Expr.Binary (Expr.Sub, Expr.Current_location, Expr.Symbol name) });
        dir (Directive.Declared_section { name = ".note.GNU-stack" });
      ];
    ]

let describe_def (id, g) =
  let kind =
    match g with
    | CC.AST.Gfun (CC.AST.Internal _) -> "Gfun Internal"
    | CC.AST.Gfun (CC.AST.External _) -> "Gfun External"
    | CC.AST.Gvar _ -> "Gvar"
  in
  Printf.sprintf "%s (%s)" (CC.Camlcoq.extern_atom id) kind

(* Requires exactly one internal function and no Gvar/second-function
   surprises, rather than picking the first internal function found with
   List.find/List.find_map: this adapter synthesizes program-level
   directives that are not actually present in Asm.program, so a program
   with more structure than return42's must be rejected with a diagnostic,
   not silently narrowed to a plausible-looking but wrong result.

   Gfun External entries ARE expected and tolerated, not just return42's own
   narrow case: C2C.convertProgram/Env.set_builtins unconditionally register
   CompCert's ~50 runtime builtins (__builtin_ prefixed, __compcert_i64_ prefixed) as
   external declarations in every compiled program's prog_defs, whether or
   not the source calls any of them - confirmed empirically compiling
   return42 itself, which calls none of them yet still carries all of them.
   An external declaration that's never called produces no assembly output
   at all (PrintAsm only emits code for Gfun Internal and data for Gvar),
   matching asm_test_entry.s exactly - which has no trace of any builtin -
   so silently ignoring Gfun External here reproduces the real printer's
   behavior rather than working around it. *)
let convert (p : CC_asm.program) : Aarch64.Instruction.t Normalized_ast.module_ =
  let is_internal_fun (_, g) =
    match g with CC.AST.Gfun (CC.AST.Internal _) -> true | _ -> false
  in
  let is_external_fun (_, g) =
    match g with CC.AST.Gfun (CC.AST.External _) -> true | _ -> false
  in
  let internal_funs = List.filter is_internal_fun p.CC.AST.prog_defs in
  let unexpected =
    List.filter (fun d -> (not (is_internal_fun d)) && not (is_external_fun d)) p.CC.AST.prog_defs
  in
  match (internal_funs, unexpected) with
  | [ (id, CC.AST.Gfun (CC.AST.Internal f)) ], [] ->
      let name = CC.Camlcoq.extern_atom id in
      { Normalized_ast.unit_name = name; items = items_of_function name f }
  | _ ->
      failwith
        (Printf.sprintf
           "Compcert_adapter.convert: expected exactly one internal function and no Gvar/extra \
            internal functions, found %d internal function(s) and %d unexpected def(s): %s"
           (List.length internal_funs) (List.length unexpected)
           (String.concat ", " (List.map describe_def (internal_funs @ unexpected))))
