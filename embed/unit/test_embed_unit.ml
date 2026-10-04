[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

module Fake = struct
  let inside = Atomic.make 0
  let widest = Atomic.make 0
  let boom = ref false

  let compile_to_asm ~name:_ source =
    if !boom then failwith "compiler crashed";
    let n = Atomic.fetch_and_add inside 1 + 1 in
    if n > Atomic.get widest then Atomic.set widest n;
    for _ = 1 to 5 do
      Thread.yield ()
    done;
    ignore (Atomic.fetch_and_add inside (-1));
    Ok source

  let runtime_units () = Ok []
end

module E = Compcert_embed.Make (X86_64) (Fake)

let show = function
  | Ok _ -> print_endline "ok"
  | Error (e : Compcert_embed.error) ->
      Printf.printf "%s [%s]\n"
        (Format.asprintf "%a" Compcert_embed.pp_error e)
        (String.concat "," e.codes)

let%expect_test "preprocessed C is accepted, with line markers and pragmas" =
  show
    (Compcert_embed.check_preprocessed
       "# 1 \"a.c\"\n# 3 \"a.c\" 2\n#line 9\n#pragma once\n  int x; /* # not a directive */\n");
  [%expect {| ok |}]

let%expect_test "a directive is refused with its line, however it is spelled" =
  List.iter
    (fun src -> show (Compcert_embed.check_preprocessed ~name:"m.c" src))
    [
      "#include <stdint.h>\nint x;\n";
      "int x;\n  #define N 3\n";
      "int x;\n#if 0\n#endif\n";
      "#define LONG \\\n  1\n";
      "int y = 1;\n#undef\n";
    ];
  [%expect
    {|
    [input] m.c:1: error: source is not preprocessed: "#include <stdint.h>" (the embedded compiler has no preprocessor and no system headers) [embed.input.directive]
    [input] m.c:2: error: source is not preprocessed: "#define N 3" (the embedded compiler has no preprocessor and no system headers) [embed.input.directive]
    [input] m.c:2: error: source is not preprocessed: "#if 0" (the embedded compiler has no preprocessor and no system headers) [embed.input.directive]
    [input] m.c:1: error: source is not preprocessed: "#define LONG \\\n  1" (the embedded compiler has no preprocessor and no system headers) [embed.input.directive]
    [input] m.c:2: error: source is not preprocessed: "#undef" (the embedded compiler has no preprocessor and no system headers) [embed.input.directive]
    |}]

let%expect_test "a # inside a comment or a literal is not a directive" =
  show
    (Compcert_embed.check_preprocessed
       "/* one\n#include <x.h>\n*/\nchar *s = \"# x\";\nchar c = '#';\n// x\n#pragma p\n");
  [%expect {| ok |}]

let%expect_test "the compiler is never entered twice at once, and a crash releases it" =
  let worker () =
    for _ = 1 to 20 do
      ignore (E.compile_to_asm "x")
    done
  in
  List.iter Thread.join (List.init 8 (fun _ -> Thread.create worker ()));
  Printf.printf "widest %d\n" (Atomic.get Fake.widest);
  Fake.boom := true;
  (match E.compile_to_asm "x" with exception Failure m -> print_endline m | _ -> ());
  Fake.boom := false;
  show (E.compile_to_asm "x");
  [%expect {|
    widest 1
    compiler crashed
    ok |}]
