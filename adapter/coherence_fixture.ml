[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The aarch64 return42 module built directly, as CompCert's output for it reads: the normalized
   and lowered ASTs a compiler holding semantic instructions would hand Rivet instead of
   assembly text, and the text path over the committed fixture. test_adapter checks that
   CompCert's own compile, converted by Adapter, meets both. *)

module P = Driver.Registry.Aarch64
module T = Aarch64
open Asm_core

let origin = Foundation.Origin.synthesized ~pass:"direct" ()

(* Through the parser's own name table, so this file and the text path resolve
   [sp] the same way. A typo cannot reach an encoding - it fails here, at module
   initialization, where nothing has printed a test name yet and the message is
   the only diagnosis available. *)
let x n =
  match T.Reg.find n with Some r -> r | None -> Fmt.failwith "%s: unknown register %S" T.name n

(* A64 has no one- two- or three-byte no-op, so those entries are legitimately
   empty; the alignment here is four and the gap is always zero. *)

(* {1 The direct normalized AST}

   Written as a compiler would produce it: directives are values, the aliases
   are already resolved ([mov x15, sp] is [Opcode.Mov] with two registers, which
   lowering turns into [add ..., #0]), and nothing here mentions a token, a span
   or a spelling. *)
let direct_normalized : T.Instruction.t Normalized_ast.module_ =
  let insn i = Normalized_ast.Instruction { insn = i; origin } in
  let dir d = Normalized_ast.Directive { directive = d; origin } in
  {
    Normalized_ast.unit_name = "asm_test_entry";
    items =
      [
        dir (Directive.Section { name = ".text"; perms = Perms.rx; nobits = false });
        dir (Directive.Align { boundary = 4; fill = None; max_skip = None });
        dir (Directive.Global { name = "asm_test_entry" });
        Normalized_ast.Label { name = "asm_test_entry"; origin };
        insn
          {
            T.Instruction.op = T.Opcode.Mov;
            ops = [ T.Operand.Reg (x "x15"); T.Operand.Reg (x "sp") ];
          };
        insn
          {
            T.Instruction.op = T.Opcode.Stp;
            ops =
              [
                T.Operand.Reg (x "x15");
                T.Operand.Reg (x "x30");
                T.Operand.Mem
                  {
                    T.Mem.base = x "sp";
                    offset = T.Disp.Const (-16L);
                    writeback = true;
                    pre = true;
                  };
              ];
          };
        insn
          {
            T.Instruction.op = T.Opcode.Movz;
            ops = [ T.Operand.Reg (x "w0"); T.Operand.Imm (Foundation.Bigint.of_int 42) ];
          };
        insn
          {
            T.Instruction.op = T.Opcode.Ldr;
            ops =
              [
                T.Operand.Reg (x "x30");
                T.Operand.Mem
                  { T.Mem.base = x "sp"; offset = T.Disp.Const 8L; writeback = false; pre = true };
              ];
          };
        insn
          {
            T.Instruction.op = T.Opcode.Add;
            ops =
              [
                T.Operand.Reg (x "sp");
                T.Operand.Reg (x "sp");
                T.Operand.Imm (Foundation.Bigint.of_int 16);
              ];
          };
        insn { T.Instruction.op = T.Opcode.Ret; ops = [ T.Operand.Reg (x "x30") ] };
        dir (Directive.Sym_type { name = "asm_test_entry"; kind = Directive.Function });
        dir
          (Directive.Sym_size
             {
               name = "asm_test_entry";
               size = Expr.Binary (Expr.Sub, Expr.Current_location, Expr.Symbol "asm_test_entry");
             });
        dir (Directive.Declared_section { name = ".note.GNU-stack" });
      ];
  }

(* The committed CompCert output; its banner is a comment, so the module it reads is the same. *)
let fixture = "../fixtures/compcert-3.17/return42/aarch64/asm_test_entry.s"

let from_text () =
  let text = In_channel.with_open_bin fixture In_channel.input_all in
  let source = Foundation.Span.source ~name:"aarch64.s" ~contents:text in
  match P.parse ~unit_name:"asm_test_entry" ~source with
  | Error ds -> failwith (Foundation.Diag.render ds)
  | Ok src -> (
      match P.simplify ~state:T.default_state src with
      | Error ds -> failwith (Foundation.Diag.render ds)
      | Ok (n, state) -> (n, state))

let render_normalized = Fmt.to_to_string (Normalized_ast.pp T.Instruction.pp)

(* {1 The direct lowered module}

   The stage below, written directly. It carries bytes and a form id, and no
   addresses at all - which is the property this fixture is really pinning: a
   lowered module that contained an address could not be laid out twice. *)

let bytes_of l =
  match T.encode l with
  | Ok (`Fixed a) -> a.Lowered_ast.bytes
  | Ok (`Relax (a :: _)) -> a.Lowered_ast.bytes
  | Ok (`Relax []) -> failwith "empty relaxation ladder"
  | Error d -> failwith (Foundation.Diagnostic.message (T.error_diagnostic (Err.Error.kind d)))

let form_of l =
  match T.encode l with
  | Ok (`Fixed a) -> Some ("aarch64." ^ a.Lowered_ast.form)
  | Ok (`Relax (a :: _)) -> Some ("aarch64." ^ a.Lowered_ast.form)
  | Ok (`Relax []) -> failwith "empty relaxation ladder"
  | Error d -> failwith (Foundation.Diagnostic.message (T.error_diagnostic (Err.Error.kind d)))

let direct_lowered : T.fixup_kind Lowered_ast.module_ =
  let frag l = Lowered_ast.Bytes { bytes = bytes_of l; form = form_of l; fixups = []; origin } in
  {
    Lowered_ast.unit_name = "asm_test_entry";
    target = "aarch64";
    sections =
      [
        {
          Lowered_ast.sec =
            {
              Lowered_ast.sec_name = ".text";
              perms = Perms.rx;
              alignment = 4;
              kind = Lowered_ast.Progbits;
            };
          fragments =
            [
              Lowered_ast.Align { boundary = 4; fill = None; max_skip = None; origin };
              Lowered_ast.Label_def { name = "asm_test_entry"; origin };
              frag
                (T.Lowered.Add_imm
                   { rd = x "x15"; rn = x "sp"; imm = T.Disp.Const 0L; shift12 = false });
              frag (T.Lowered.Stp_pre { rt = x "x15"; rt2 = x "x30"; rn = x "sp"; offset = -16L });
              frag (T.Lowered.Movz { rd = x "w0"; imm16 = 42L; hw = 0 });
              frag
                (T.Lowered.Ldst_uoff
                   { size = T.X; load = true; rt = x "x30"; rn = x "sp"; offset = T.Disp.Const 8L });
              frag
                (T.Lowered.Add_imm
                   { rd = x "sp"; rn = x "sp"; imm = T.Disp.Const 16L; shift12 = false });
              frag (T.Lowered.Ret { rn = x "x30" });
              Lowered_ast.Set_size
                {
                  name = "asm_test_entry";
                  size = Expr.Binary (Expr.Sub, Expr.Current_location, Expr.Symbol "asm_test_entry");
                  origin;
                };
            ];
        };
      ];
    symbols =
      [
        {
          Lowered_ast.name = "asm_test_entry";
          binding = Lowered_ast.Global;
          visibility = Lowered_ast.Default;
          kind = Directive.Function;
          size = Some (Expr.Binary (Expr.Sub, Expr.Current_location, Expr.Symbol "asm_test_entry"));
          section = ".text";
        };
      ];
    commons = [];
    declared_sections = [ ".note.GNU-stack" ];
  }

let render_lowered m = Fmt.to_to_string Lowered_ast.pp m
