[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic"]

(* The F-only profile's own checks: C -> assembly -> image for binary32
   code, with no instruction of the D extension anywhere in the result, the
   profile's runtime ([__compcert_fp32_*], [__compcert_i64_*]) linked where
   the code calls it, and binary64 arithmetic refused by the compiler. The
   report must equal fp32.expected. *)

let pp_error = Compcert_embed.pp_error

(* A mnemonic of the D extension: [fld], [fsd], or an F-format one with a [d]
   component ([fadd.d], [fcvt.d.s], [fmv.x.d], ...). *)
let is_d mnemonic =
  mnemonic = "fld" || mnemonic = "fsd"
  || String.length mnemonic > 1
     && mnemonic.[0] = 'f'
     && List.mem "d" (String.split_on_char '.' mnemonic)

(* The first word of each instruction line: tab-indented, not a directive.
   CompCert separates the operands with a tab, the struct-passing bridges
   (StructPassing.fp32_assembly) with a space. *)
let mnemonics text =
  String.split_on_char '\n' text
  |> List.filter_map (fun l ->
      if String.length l > 1 && l.[0] = '\t' && l.[1] <> '.' then
        match
          String.split_on_char ' ' (String.sub l 1 (String.length l - 1))
          |> List.concat_map (String.split_on_char '\t')
        with
        | m :: _ when m <> "" -> Some m
        | _ -> None
      else None)

let d_instructions text = List.filter is_d (mnemonics text) |> List.sort_uniq compare

let report_d what text =
  match d_instructions text with
  | [] -> Printf.printf "%s: no D instruction\n" what
  | ds -> Printf.printf "%s: D instructions %s\n" what (String.concat " " ds)

let programs =
  [
    ( "arith.c",
      "float axpy(float a, float x, float y) { return a * x + y; }\n\
       float quot(float x, float y) { return x / y; }\n\
       int less(float x, float y) { return x < y; }\n\
       int to_int(float x) { return (int)x; }\n\
       float of_int(int x) { return (float)x; }\n\
       void scale(float *v, int n, float k) { for (int i = 0; i < n; i++) v[i] *= k; }\n" );
    ( "convert.c",
      "double widen(float x) { return x; }\n\
       float narrow(double x) { return (float)x; }\n\
       double copy(double *p) { return *p; }\n" );
    ( "pair.c",
      "struct pair { float x, y; };\n\
       struct pair swap(struct pair p) { struct pair r = { p.y, p.x }; return r; }\n\
       float sum(struct pair p) { return p.x + p.y; }\n" );
    ("int64.c", "long long mul(long long a, long long b) { return a * b / 7; }\n");
    (* The profile's runtime has no __compcert_i64_stof, and CompCert lowers the
       reverse conversion only under -ffp32-approx-double. *)
    ("i64_to_float.c", "float stof(long long x) { return (float)x; }\n");
    ("float_to_i64.c", "long long ftos(float x) { return (long long)x; }\n");
    ("double_arith.c", "double twice(double x) { return x * 2.0; }\n");
    ("builtin.c", "float root(float x) { return __builtin_fsqrt(x); }\n");
  ]

let compile (name, source) =
  Printf.printf "-- %s\n" name;
  match Embed.compile_to_asm ~name source with
  | Error e -> Format.printf "compile: %a@." pp_error e
  | Ok asm -> (
      report_d "assembly" asm;
      match Embed.with_runtime [ (name, asm) ] with
      | Error e -> Format.printf "runtime: %a@." pp_error e
      | Ok units -> (
          Printf.printf "links: %s\n"
            (match List.tl units with [] -> "none" | us -> String.concat " " (List.map fst us));
          let entry = List.hd (Compcert_embed.globals asm) in
          match Embed.assemble_units ~entry [ (name, asm) ] with
          | Ok _ -> print_endline "plans: ok"
          | Error e -> Format.printf "plans: %a@." pp_error e))

let () =
  print_endline "== the D detector";
  report_d "fadd.s fld fcvt.d.s fsd"
    "\tfadd.s\tfa0, fa0, fa1\n\tfld\tfa0, 0(a0)\n\tfcvt.d.s\tfa0, fa0\n\tfsd fa0,8(sp)\n";
  print_endline "== runtime";
  (match Embed.runtime_units () with
  | Error e -> Format.printf "runtime: %a@." pp_error e
  | Ok units ->
      Printf.printf "available: %s\n" (String.concat " " (List.map fst units));
      List.iter (fun (n, t) -> report_d n t) units);
  print_endline "== C -> assembly -> image";
  List.iter compile programs
