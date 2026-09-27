(* The embedded corpus: self-contained C programs, each run natively end to
   end - compiled, assembled, mapped and called in this process - and
   checked against the result recorded on its first line. *)

let corpus = "corpus"
let read path = In_channel.with_open_bin path In_channel.input_all

let programs () =
  Sys.readdir corpus |> Array.to_list |> List.sort compare
  |> List.filter (fun f -> Filename.check_suffix f ".c")

(* First line: [/* expect: <int64> */]. *)
let expected source =
  let first = List.hd (String.split_on_char '\n' source) in
  Scanf.sscanf first "/* expect: %Ld */" Fun.id

let fresh_io () =
  let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4096 in
  Bigarray.Array1.fill io '\000';
  io

let run_one ?(io = fresh_io ()) file =
  let source = read (Filename.concat corpus file) in
  (Compcert_embed_aarch64.run ~name:file source ~io, expected source)

let%expect_test "every corpus program returns its expected value natively" =
  List.iter
    (fun file ->
      match run_one file with
      | Ok o, want when o.Native_exec.value = want -> Printf.printf "%s: ok\n" file
      | Ok o, want -> Printf.printf "%s: got %Ld, want %Ld\n" file o.value want
      | Error e, _ -> Printf.printf "%s: %s\n" file (Format.asprintf "%a" Compcert_embed.pp_error e))
    (programs ());
  [%expect
    {|
    byteswap.c: ok
    fixture_args_arith.c: ok
    fixture_cond_select.c: ok
    fixture_cross_bss.c: ok
    fixture_cross_call.c: ok
    fixture_cross_data.c: ok
    fixture_direct_call.c: ok
    fixture_global_ldst.c: ok
    fixture_i64_divmod.c: ok
    fixture_loop.c: ok
    fixture_return42.c: ok
    float_math.c: ok
    globals_sections.c: ok
    int64_helpers.c: ok
    io_buffer.c: ok
    misc_int.c: ok
    narrow_div32.c: ok
    recursion_frames.c: ok
    struct_byvalue.c: ok
    switch_table.c: ok |}]

let%expect_test "io_buffer's writes are visible to the host after the call" =
  let io = fresh_io () in
  (match run_one ~io "io_buffer.c" with
  | Ok _, _ ->
      let word = ref 0L in
      for i = 7 downto 0 do
        word := Int64.logor (Int64.shift_left !word 8) (Int64.of_int (Char.code io.{512 + i}))
      done;
      Printf.printf "io[0]=%d io[255]=%d word@512=%Ld\n"
        (Char.code io.{0})
        (Char.code io.{255})
        !word
  | Error e, _ -> print_endline (Format.asprintf "%a" Compcert_embed.pp_error e));
  [%expect {| io[0]=255 io[255]=0 word@512=32640 |}]

let%expect_test "exported globals can be read back after the call" =
  let source = "int counter = 5;\nlong entry(void *io) { counter += 37; return 0; }\n" in
  (match Compcert_embed_aarch64.run ~read_globals:[ "counter" ] source ~io:(fresh_io ()) with
  | Ok { globals = [ (_, b) ]; _ } -> Printf.printf "counter = %ld\n" (String.get_int32_le b 0)
  | Ok _ -> print_endline "unexpected globals"
  | Error e -> print_endline (Format.asprintf "%a" Compcert_embed.pp_error e));
  [%expect {| counter = 42 |}]
