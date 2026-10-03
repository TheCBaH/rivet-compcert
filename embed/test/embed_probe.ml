[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Usage: embed_probe [--run] <file.c> [<repeat>]. The source is read up
   front, before any compile starts, so that a trace of the compile itself has
   no reason to touch the file system. Without --run the assembly is printed;
   with it the program is also assembled and run natively, and its result
   printed. *)
let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let run, args = match args with "--run" :: rest -> (true, rest) | _ -> (false, args) in
  let path, repeat =
    match args with
    | [ p ] -> (p, 1)
    | [ p; n ] -> (p, int_of_string n)
    | _ -> failwith "usage: embed_probe [--run] <file.c> [<repeat>]"
  in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let name = Filename.basename path in
  let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4096 in
  print_string "--- compile start\n";
  flush stdout;
  let fail e =
    prerr_string (Format.asprintf "%a\n" Compcert_embed.pp_error e);
    exit 1
  in
  for i = 1 to repeat do
    let last = i = repeat in
    if run then (
      Bigarray.Array1.fill io '\000';
      match Compcert_embed_aarch64.run ~name source ~io with
      | Ok o -> if last then Printf.printf "%Ld\n" o.value
      | Error e -> fail e)
    else
      match Compcert_embed_aarch64.compile_to_asm ~name source with
      | Ok asm -> if last then print_string asm
      | Error e -> fail e
  done
