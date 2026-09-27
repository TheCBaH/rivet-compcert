(* Usage: soak.exe <corpus-dir> [<cycles>]. Runs compile+run cycles over the
   corpus, round robin, in one process, and reports memory growth every 1000
   cycles: OCaml heap, resident set size, and the size of CompCert's atom
   tables, which grow with every distinct identifier ever compiled. Any
   result that differs from the program's recorded expectation is fatal. *)

module CC = Compcert_embed_aarch64.CC

let read path = In_channel.with_open_bin path In_channel.input_all

let expected source =
  Scanf.sscanf (List.hd (String.split_on_char '\n' source)) "/* expect: %Ld */" Fun.id

let rss_kb () =
  In_channel.with_open_bin "/proc/self/status" In_channel.input_all
  |> String.split_on_char '\n'
  |> List.find_map (fun l -> try Scanf.sscanf l "VmRSS: %d kB" Option.some with _ -> None)
  |> Option.value ~default:(-1)

let report cycle t0 =
  let st = Gc.quick_stat () in
  Printf.printf "cycle %6d  %6.1fs  heap %7d KB  top-heap %7d KB  rss %7d KB  atoms %6d\n%!" cycle
    (Unix.gettimeofday () -. t0)
    (st.heap_words * 8 / 1024)
    (st.top_heap_words * 8 / 1024)
    (rss_kb ())
    (Hashtbl.length CC.Camlcoq.atom_of_string)

let () =
  let dir = Sys.argv.(1) in
  let cycles = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 10_000 in
  let programs =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".c")
    |> List.sort compare
    |> List.map (fun f ->
        let s = read (Filename.concat dir f) in
        (f, s, expected s))
    |> Array.of_list
  in
  let io = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4096 in
  let t0 = Unix.gettimeofday () in
  report 0 t0;
  for i = 1 to cycles do
    let name, source, want = programs.(i mod Array.length programs) in
    Bigarray.Array1.fill io '\000';
    (match Compcert_embed_aarch64.run ~name source ~io with
    | Ok o when o.value = want -> ()
    | Ok o ->
        Printf.printf "cycle %d: %s returned %Ld, want %Ld\n" i name o.value want;
        exit 1
    | Error e ->
        Format.printf "cycle %d: %s: %a@." i name Compcert_embed.pp_error e;
        exit 1);
    if i mod 1000 = 0 then report i t0
  done
