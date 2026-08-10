(* The differential gate (.ai/asm_plan.md M1.5).

   Per target, at a fixed base of 0x0: byte-for-byte equality in memory order
   with the committed [oracle/text.hex], and canonical disassembly compared
   against [oracle/objdump.txt] after a *declared* set of spelling
   normalizations.

   The two comparisons are not equally strong and are not treated as though they
   were. The byte comparison is exact and unnormalized: it is the claim that this
   assembler and GNU as produce the same machine code. The disassembly comparison
   passes through the normalizer below, so what it can establish is weaker - that
   the two disagree about nothing except spellings this file has enumerated. A
   normalization that changed a register, an immediate or a mnemonic's identity
   would make that claim vacuous, so every rule here is required to be a pure
   syntax rewrite and is listed with the difference it absorbs.

   No relocation resolution is needed, because every fixture's .text is
   relocation-free once .cfi_* and therefore .eh_frame are discarded. *)

let fixture_root = "../../fixtures/compcert-3.17/return42"

let read path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let hex_of s =
  String.concat " " (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

(* [text.hex] is a whitespace-separated byte list in memory order, wrapped at
   sixteen bytes a line. Reading it back as a byte list rather than comparing
   the rendered text means a difference in line wrapping is not reported as a
   difference in code. *)
let bytes_of_hex_file path =
  let text = read path in
  let buf = Buffer.create 64 in
  String.split_on_char '\n' text
  |> List.iter (fun line ->
      String.split_on_char ' ' line
      |> List.iter (fun tok ->
          let tok = String.trim tok in
          if tok <> "" then Buffer.add_char buf (Char.chr (int_of_string ("0x" ^ tok)))));
  Buffer.contents buf

(* {1 The declared normalizations}

   Each entry says what GNU prints, what this assembler prints, and why they
   differ. Nothing here may change which register, which immediate or which
   operation a line names. *)

let strip_comment target line =
  (* objdump appends the decimal or hexadecimal value of an immediate after the
     target's comment introducer: [mov r0, #42 @ 0x2a] on ARM and
     [mov w0, #0x2a // #42] on AArch64. It is a second rendering of an operand
     that is already on the line, so removing it removes no information. *)
  let intro = match target with "arm" -> "@" | "aarch64" -> "//" | _ -> "#" in
  match
    let rec find i =
      if i + String.length intro > String.length line then None
      else if String.sub line i (String.length intro) = intro then Some i
      else find (i + 1)
    in
    find 0
  with
  | Some i -> String.sub line 0 i
  | None -> line

let collapse_space s =
  let b = Buffer.create (String.length s) in
  let prev_space = ref true in
  String.iter
    (fun c ->
      let c = if c = '\t' then ' ' else c in
      if c = ' ' then (
        if not !prev_space then Buffer.add_char b c;
        prev_space := true)
      else (
        Buffer.add_char b c;
        prev_space := false))
    s;
  String.trim (Buffer.contents b)

(* objdump writes numbers in hexadecimal - [#0x10] on AArch64, [$0x2a] and
   [0x10(%esp)] on x86 - and this assembler writes decimal everywhere. Rewriting
   every [0xN] literal to its decimal value is a base change, not a value
   change, and it is applied to both sides so a decimal literal on either is
   left alone. *)
let decimalize s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') in
  let i = ref 0 in
  while !i < n do
    if !i + 2 < n && s.[!i] = '0' && (s.[!i + 1] = 'x' || s.[!i + 1] = 'X') && is_hex s.[!i + 2]
    then (
      let j = ref (!i + 2) in
      while !j < n && is_hex s.[!j] do
        incr j
      done;
      let digits = String.sub s (!i + 2) (!j - !i - 2) in
      Buffer.add_string b (Int64.to_string (Int64.of_string ("0x" ^ digits)));
      i := !j)
    else (
      Buffer.add_char b s.[!i];
      incr i)
  done;
  Buffer.contents b

(* objdump separates operands with a bare comma and this assembler with a comma
   and a space. Whitespace only. *)
let tighten_commas s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    Buffer.add_char b s.[!i];
    if s.[!i] = ',' then
      while !i + 1 < n && s.[!i + 1] = ' ' do
        incr i
      done;
    incr i
  done;
  Buffer.contents b

(* AT&T size suffixes. objdump drops the [b]/[w]/[l]/[q] whenever a register
   operand already fixes the operand size, which is every x86 line in these
   fixtures; this assembler always prints it, because a canonical dump must be
   re-parseable and GAS needs the suffix on forms where no register appears.

   The rewrite therefore fires only when the line *has* a register operand -
   that is precisely objdump's own condition - so it cannot erase a suffix that
   carries the only size information on the line. *)
let drop_size_suffix target line =
  if target <> "x86_32" && target <> "x86_64" then line
  else if not (String.contains line '%') then line
  else
    match String.index_opt line ' ' with
    | None -> line
    | Some sp ->
        let m = String.sub line 0 sp in
        let n = String.length m in
        let stem = if n >= 2 then String.sub m 0 (n - 1) else m in
        (* Only for the M1 mnemonic set, and only when the *stem* is in it. A
           blind "drop the last letter" would turn objdump's already-suffixless
           [sub] into [su]. *)
        if
          List.mem stem [ "add"; "sub"; "mov"; "lea" ]
          && match m.[n - 1] with 'b' | 'w' | 'l' | 'q' -> true | _ -> false
        then stem ^ String.sub line sp (String.length line - sp)
        else line

(* AArch64's [movz wD, #imm] with a zero shift is spelled [mov wD, #imm] by
   objdump, which is the MOV (wide immediate) alias. This assembler prints the
   underlying form, because resolving the alias in the *other* direction would
   require a surface [mov] with an immediate that M1 does not accept. The
   rewrite maps objdump's spelling onto this one and is the only rule here that
   touches a mnemonic; it is safe because it fires only for a [mov] whose second
   operand is an immediate, which on A64 has exactly one encoding. *)
let movz_alias target line =
  if target <> "aarch64" then line
  else
    match String.split_on_char ' ' line with
    | "mov" :: rest when String.contains line '#' -> String.concat " " ("movz" :: rest)
    | _ -> line

let normalize target line =
  line |> strip_comment target |> collapse_space |> decimalize |> tighten_commas
  |> drop_size_suffix target |> movz_alias target

(* objdump's body lines look like [   4:\te24dd008 \tsub\tsp, sp, #8]; the
   address and the encoding word are dropped, because the byte comparison
   already covers them exactly and covers them better. *)
let objdump_instructions target path =
  read path |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      match String.index_opt line ':' with
      | None -> None
      | Some i ->
          let before = String.sub line 0 i in
          if String.trim before = "" then None
          else if
            String.for_all
              (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c = ' ')
              before
          then
            let after = String.sub line (i + 1) (String.length line - i - 1) in
            (* the encoding word is the first tab-separated field after the colon *)
            match String.split_on_char '\t' after with
            | _ :: _word :: rest when rest <> [] -> Some (normalize target (String.concat " " rest))
            | _ -> None
          else None)

let target_of_name name =
  match Driver.Registry.find name with Some d -> d | None -> failwith ("no such target: " ^ name)

let assemble_bytes name =
  let (module D : Target_intf.Target.DRIVER) = target_of_name name in
  let path = Filename.concat (Filename.concat fixture_root name) "asm_test_entry.s" in
  let source = Foundation.Span.source ~name:path ~contents:(read path) in
  match D.assemble ~unit_name:"asm_test_entry" ~source with
  | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
  | Ok laid_out -> (
      let plan = Image.plan_of laid_out in
      let addresses =
        List.map (fun (s : Image.segment_plan) -> (s.Image.seg_name, 0L)) plan.Image.segments
      in
      match Image.bind_image laid_out ~addresses with
      | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
      | Ok img -> ( match img.Image.segments with s :: _ -> s.Image.bytes | [] -> ""))

let check_bytes name =
  let ours = assemble_bytes name in
  let theirs =
    bytes_of_hex_file (Filename.concat (Filename.concat fixture_root name) "oracle/text.hex")
  in
  if String.equal ours theirs then
    Printf.printf "%-8s bytes: %d, identical\n" name (String.length ours)
  else
    Printf.printf "%-8s BYTES DIFFER\n  ours:   %s\n  oracle: %s\n" name (hex_of ours)
      (hex_of theirs)

let check_disasm name =
  let (module D : Target_intf.Target.DRIVER) = target_of_name name in
  let bytes = assemble_bytes name in
  let ours =
    match D.dump_disasm_canonical ~address:0L bytes with
    | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
    | Ok text ->
        String.split_on_char '\n' text
        |> List.filter_map (fun l ->
            let l = normalize name l in
            if l = "" then None else Some l)
  in
  let theirs =
    objdump_instructions name
      (Filename.concat (Filename.concat fixture_root name) "oracle/objdump.txt")
  in
  if List.length ours <> List.length theirs then
    Printf.printf "%-8s DISASM LENGTH DIFFERS: %d vs %d\n" name (List.length ours)
      (List.length theirs)
  else
    let bad = List.filter (fun (a, b) -> not (String.equal a b)) (List.combine ours theirs) in
    if bad = [] then
      Printf.printf "%-8s disasm: %d lines agree after normalization\n" name (List.length ours)
    else
      List.iter
        (fun (a, b) -> Printf.printf "%-8s DISASM DIFFERS\n  ours:   %s\n  objdump: %s\n" name a b)
        bad

let%expect_test "bytes match the GNU oracle exactly" =
  List.iter check_bytes [ "x86_32"; "x86_64"; "arm"; "aarch64" ];
  [%expect
    {|
    x86_32   bytes: 19, identical
    x86_64   bytes: 23, identical
    arm      bytes: 32, identical
    aarch64  bytes: 24, identical
    |}]

let%expect_test "canonical disassembly agrees with objdump after normalization" =
  List.iter check_disasm [ "x86_32"; "x86_64"; "arm"; "aarch64" ];
  [%expect
    {|
    x86_32   disasm: 6 lines agree after normalization
    x86_64   disasm: 6 lines agree after normalization
    arm      disasm: 8 lines agree after normalization
    aarch64  disasm: 6 lines agree after normalization
    |}]

(* The canonical dump has to be *exactly re-parseable*: feeding it back through
   the assembler must produce the identical image. That is the property that
   makes it usable as a test artifact at all, and it is a stronger statement
   than "it decodes", because it goes back through the lexer, the grammar, the
   target's operand parser, simplify, lower and encode. *)
let check_round_trip name =
  let (module D : Target_intf.Target.DRIVER) = target_of_name name in
  let bytes = assemble_bytes name in
  match D.dump_disasm_canonical ~address:0L bytes with
  | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
  | Ok text -> (
      let section =
        match name with
        | "arm" | "aarch64" -> "\t.text\n\t.balign 4\n"
        | _ -> "\t.text\n\t.align 16\n"
      in
      let source = Foundation.Span.source ~name:(name ^ ":round-trip") ~contents:(section ^ text) in
      match D.assemble ~unit_name:"round" ~source with
      | Error ds ->
          Printf.printf "%-8s ROUND TRIP FAILED TO ASSEMBLE\n%s\n" name
            (Foundation.Diagnostic.render_all ds)
      | Ok l -> (
          let plan = Image.plan_of l in
          let addresses =
            List.map (fun (s : Image.segment_plan) -> (s.Image.seg_name, 0L)) plan.Image.segments
          in
          match Image.bind_image l ~addresses with
          | Error ds ->
              Printf.printf "%-8s ROUND TRIP FAILED TO BIND\n%s\n" name
                (Foundation.Diagnostic.render_all ds)
          | Ok img ->
              let again = match img.Image.segments with s :: _ -> s.Image.bytes | [] -> "" in
              if String.equal again bytes then
                Printf.printf "%-8s round trip: %d bytes reproduced\n" name (String.length again)
              else
                Printf.printf "%-8s ROUND TRIP DIFFERS\n  first:  %s\n  second: %s\n" name
                  (hex_of bytes) (hex_of again)))

let%expect_test "canonical disassembly re-assembles to the same bytes" =
  List.iter check_round_trip [ "x86_32"; "x86_64"; "arm"; "aarch64" ];
  [%expect
    {|
    x86_32   round trip: 19 bytes reproduced
    x86_64   round trip: 23 bytes reproduced
    arm      round trip: 32 bytes reproduced
    aarch64  round trip: 24 bytes reproduced
    |}]

(* {1 The embedded copies}

   test/dump embeds the four fixture texts as string literals, because a Melange
   build shares no filesystem with the native one and a three-build driver that
   read files would compare three programs with three different inputs. That
   copy is only safe while it is a copy, so this is where it is checked. Without
   this the embedded text could quietly drift into a second, easier input and
   the three-build gate would still pass. *)
let%expect_test "the embedded dump inputs are byte-identical to the fixtures" =
  List.iter
    (fun (name, embedded) ->
      let path = Filename.concat (Filename.concat fixture_root name) "asm_test_entry.s" in
      let committed = read path in
      (* The fixture carries a two-line CompCert provenance banner that the
         embedded copy drops: it is a comment, so it changes no output, and
         keeping it would put a tool version inside a byte-compared artifact. *)
      let strip_banner s =
        match String.split_on_char '\n' s with
        | a :: b :: rest when String.length a > 0 && (a.[0] = '#' || a.[0] = '@' || a.[0] = '/') ->
            ignore b;
            String.concat "\n" rest
        | _ -> s
      in
      if String.equal (strip_banner committed) embedded then
        Printf.printf "%-8s embedded copy matches the fixture\n" name
      else Printf.printf "%-8s EMBEDDED COPY HAS DRIFTED FROM THE FIXTURE\n" name)
    Test_dump_inputs.all;
  [%expect
    {|
    x86_32   embedded copy matches the fixture
    x86_64   embedded copy matches the fixture
    arm      embedded copy matches the fixture
    aarch64  embedded copy matches the fixture
    |}]
