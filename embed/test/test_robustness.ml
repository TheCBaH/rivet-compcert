[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The decided robustness behaviors: varargs are refused before code
   generation, and crashes and hangs in generated code are contained by the
   opt-in isolation mode. *)

let io () =
  let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 64 in
  Bigarray.Array1.fill io '\000';
  io

let show = function
  | Ok (o : Native_exec.outcome) -> Printf.printf "Ok %Ld\n" o.value
  | Error e -> Format.printf "Error %a@." Compcert_embed.pp_error e

let run ?isolate ?timeout_s source =
  match Compcert_embed_aarch64.compile source with
  | Error e -> Error e
  | Ok laid ->
      Native_exec.run ?isolate ?timeout_s laid ~io:(io ())
      |> Result.map_error (fun e ->
          {
            Compcert_embed.stage = Execute;
            message = Format.asprintf "%a" Native_exec.pp_error e;
            codes = [];
          })

let%expect_test "a variadic function definition is refused at the compile stage" =
  show (run "int sum(int n, ...) { return n; }\nlong entry(void *io) { return sum(1, 2); }\n");
  [%expect
    {| Error [compile] gen.c: error: variadic functions are not supported (vararg.S is never linked): sum |}]

let%expect_test "a call to a variadic external is refused too" =
  show (run "int printf(const char *, ...);\nlong entry(void *io) { printf(\"hi\"); return 0; }\n");
  [%expect
    {| Error [compile] gen.c: error: variadic functions are not supported (vararg.S is never linked): printf |}]

let%expect_test "isolated runs return the value and the io buffer" =
  let buf = io () in
  (match
     Compcert_embed_aarch64.compile "long entry(void *io) { ((char *)io)[3] = 'k'; return 99; }\n"
   with
  | Error e -> Format.printf "%a@." Compcert_embed.pp_error e
  | Ok laid -> (
      match Native_exec.run ~isolate:true laid ~io:buf with
      | Ok o -> Printf.printf "value %Ld, io[3] %c\n" o.value buf.{3}
      | Error e -> Format.printf "%a@." Native_exec.pp_error e));
  [%expect {| value 99, io[3] k |}]

let%expect_test "a faulting program is reported, not fatal, when isolated" =
  show (run ~isolate:true "long entry(void *io) { return *(volatile long *)8; }\n");
  [%expect {| Error [execute] generated code was killed by SIGSEGV |}]

let%expect_test "an infinite loop is stopped by the timeout when isolated" =
  show (run ~isolate:true ~timeout_s:1.0 "long entry(void *io) { for (;;) ; return 0; }\n");
  [%expect {| Error [execute] generated code ran longer than 1s |}]

(* 64 MB of locals: far past the host thread's stack. *)
let huge_frame =
  "long entry(void *io) { volatile char big[64 * 1024 * 1024]; big[0] = 1; big[sizeof big - 1] = \
   2; return big[0] + big[sizeof big - 1]; }\n"

let%expect_test "a huge stack frame overflows the stack and is contained when isolated" =
  show (run ~isolate:true huge_frame);
  [%expect {| Error [execute] generated code was killed by SIGSEGV |}]

let%expect_test "a large but reasonable frame runs in-process" =
  show
    (run
       "long entry(void *io) { volatile char big[1024 * 1024]; big[0] = 1; big[sizeof big - 1] = \
        2; return big[0] + big[sizeof big - 1]; }\n");
  [%expect {| Ok 3 |}]

let%expect_test "the host keeps working after contained failures" =
  show (run "long entry(void *io) { return 5; }\n");
  [%expect {| Ok 5 |}]
