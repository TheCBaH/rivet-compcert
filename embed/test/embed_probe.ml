(* Usage: embed_probe <file.c> [<repeat>]. The source is read up front, before
   any compile starts, so that a trace of the compile itself has no reason to
   touch the file system. *)
let () =
  let path = Sys.argv.(1) in
  let repeat = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 1 in
  let source = In_channel.with_open_bin path In_channel.input_all in
  print_string "--- compile start\n";
  flush stdout;
  let last = ref (Ok "") in
  for _ = 1 to repeat do
    last := Compcert_embed.compile_to_asm ~name:(Filename.basename path) source
  done;
  match !last with
  | Ok asm -> print_string asm
  | Error { Compcert_embed.message } ->
      prerr_string message;
      exit 1
