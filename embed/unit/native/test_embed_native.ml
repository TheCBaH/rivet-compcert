[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

module Fake = struct
  let compile_to_asm ~name:_ source = Ok source
  let runtime_units () = Ok []
end

module E = Compcert_embed.Make (X86_64) (Fake)

let io_of_string s =
  let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 64 in
  Bigarray.Array1.fill io '\000';
  String.iteri (fun i c -> io.{i} <- c) s;
  io

let caller =
  "\t.text\n\t.globl entry\nentry:\n\tsubq\t$8, %rsp\n\tcall\tstrlen\n\taddq\t$8, %rsp\n\tret\n"

let code = function
  | Ok _ -> "loaded"
  | Error (e : Compcert_embed.error) -> String.concat "," e.codes

let%expect_test "an unbound host symbol and an unresolvable one are both refused" =
  print_endline (code (E.load caller));
  print_endline (code (E.load ~host_symbols:[ "no_such_host_symbol" ] caller));
  [%expect {|
    image.undefined
    embed.host_symbol |}]

let%expect_test "a bound host symbol is called repeatedly through one mapping" =
  let t = Result.get_ok (E.load ~host_symbols:[ "strlen" ] caller) in
  List.iter
    (fun s -> Printf.printf "%Ld\n" (Result.get_ok (Native_exec.call t ~io:(io_of_string s))))
    [ "hello"; ""; "twelve bytes" ];
  Native_exec.close t;
  [%expect {|
    5
    0
    12 |}]
