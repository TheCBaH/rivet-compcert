(* Compiling each checked-in CompCert fixture source in memory reproduces the
   checked-in ccomp -S output byte for byte. The one line allowed to differ is
   the header's command-line comment, which records the argv of whichever
   process did the compiling. *)

let fixtures = "../../fixtures/compcert-3.17"
let fixture_sources = "../../fixtures/c"
let read path = In_channel.with_open_bin path In_channel.input_all

let without_command_line text =
  String.split_on_char '\n' text
  |> List.filter (fun l -> not (String.starts_with ~prefix:"// Command line:" l))
  |> String.concat "\n"

let sources () =
  Sys.readdir fixtures |> Array.to_list |> List.sort compare
  |> List.concat_map (fun case ->
      let dir = Filename.concat fixture_sources case in
      (* Not every case has an aarch64 build: i64_divmod is 32-bit only. *)
      if
        Sys.file_exists dir
        && Sys.file_exists (Filename.concat (Filename.concat fixtures case) "aarch64")
      then
        Sys.readdir dir |> Array.to_list |> List.sort compare
        |> List.filter (fun f -> Filename.check_suffix f ".c")
        |> List.map (fun f -> (case, f))
      else [])

let expected case file =
  read
    (Filename.concat fixtures
       (Filename.concat case (Filename.concat "aarch64" (Filename.chop_suffix file ".c" ^ ".s"))))

let flags case =
  read (Filename.concat fixtures (Filename.concat case "manifest.txt"))
  |> String.split_on_char '\n'
  |> List.find_map (fun l ->
      String.starts_with ~prefix:"ccomp-args:aarch64\t" l |> function
      | true -> Some (List.nth (String.split_on_char '\t' l) 1)
      | false -> None)
  |> Option.value ~default:"?"

let compile case file =
  let source = read (Filename.concat fixture_sources (Filename.concat case file)) in
  Compcert_embed_aarch64.compile_to_asm ~name:file source

let%expect_test "every fixture source compiles to its checked-in aarch64 assembly" =
  List.iter
    (fun (case, file) ->
      (* compile_to_asm always compiles as -fno-pie with ccomp's other
         defaults; a fixture recorded with any other flags would need them
         passed through. *)
      if flags case <> "-fno-pie" then Printf.printf "%s: unexpected flags %S\n" case (flags case);
      match compile case file with
      | Error { message; _ } -> Printf.printf "%s/%s: ERROR\n%s" case file message
      | Ok asm ->
          let want = without_command_line (expected case file) in
          let got = without_command_line asm in
          Printf.printf "%s/%s: %s\n" case file
            (if String.equal want got then "identical" else "DIFFERS:\n" ^ got))
    (sources ());
  [%expect
    {|
    args_arith/args_arith.c: identical
    cond_select/cond_select.c: identical
    cross_bss/caller.c: identical
    cross_bss/data.c: identical
    cross_call/callee.c: identical
    cross_call/caller.c: identical
    cross_data/caller.c: identical
    cross_data/data.c: identical
    direct_call/direct_call.c: identical
    global_ldst/global_ldst.c: identical
    loop/loop.c: identical
    return42/asm_test_entry.c: identical |}]

let%expect_test "the command-line comment is the only line excluded, and it is present" =
  (match compile "return42" "asm_test_entry.c" with
  | Ok asm ->
      String.split_on_char '\n' asm
      |> List.filter (fun l -> String.starts_with ~prefix:"// Command line:" l)
      |> List.length
      |> Printf.printf "command-line lines: %d\n"
  | Error { message; _ } -> print_string message);
  [%expect {| command-line lines: 1 |}]

let print_result = function
  | Ok _ -> print_endline "Ok"
  | Error { Compcert_embed.message; _ } -> Printf.printf "Error:\n%s" message

let%expect_test "a syntax error is an Error carrying CompCert's message" =
  print_result
    (Compcert_embed_aarch64.compile_to_asm ~name:"bad.c" "int entry(void) { return 1 +; }\n");
  [%expect
    {|
    Error:
    bad.c:1:29: syntax error after '+' and before ';'.
    Ill-formed use of the binary operator '+'.
    At this point, an expression is expected.
    Fatal error; compilation aborted. |}]

let%expect_test "a type error is an Error carrying CompCert's message" =
  print_result
    (Compcert_embed_aarch64.compile_to_asm ~name:"bad.c"
       "struct s { int a; };\nint entry(void) { struct s x; return x + 1; }\n");
  [%expect
    {|
    Error:
    bad.c:2: error: invalid operands to binary '+' ('struct s' and 'int') |}]

let%expect_test "the process keeps compiling after errors" =
  print_result
    (Compcert_embed_aarch64.compile_to_asm ~name:"bad.c" "int entry(void) { return 1 +; }\n");
  print_result (Compcert_embed_aarch64.compile_to_asm "int entry(void) { return 7; }\n");
  [%expect
    {|
    Error:
    bad.c:1:29: syntax error after '+' and before ';'.
    Ill-formed use of the binary operator '+'.
    At this point, an expression is expected.
    Fatal error; compilation aborted.
    Ok |}]

let%expect_test "100 sequential compiles of mixed inputs give identical outputs" =
  let inputs = List.map (fun (case, file) () -> compile case file) (sources ()) in
  let inputs =
    inputs
    @ [
        (fun () ->
          Compcert_embed_aarch64.compile_to_asm ~name:"bad.c" "int entry(void) { return 1 +; }\n");
      ]
  in
  let render = function
    | Ok s -> "ok\n" ^ s
    | Error { Compcert_embed.message; _ } -> "error\n" ^ message
  in
  let first = List.map (fun f -> render (f ())) inputs in
  let n = List.length inputs in
  let mismatches = ref 0 in
  for i = 0 to 99 do
    let k = i mod n in
    if not (String.equal (render ((List.nth inputs k) ())) (List.nth first k)) then incr mismatches
  done;
  Printf.printf "inputs: %d, compiles: 100, mismatches: %d\n" n !mismatches;
  [%expect {| inputs: 13, compiles: 100, mismatches: 0 |}]
