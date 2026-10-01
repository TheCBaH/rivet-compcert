(* The in-memory C -> assembly -> image path reproduces the fixture oracle's
   post-link bytes: every case's sources are compiled and assembled in
   memory, the image is bound at the addresses the reference link used
   (oracle/linked/manifest.txt), and each PROGBITS section is compared with
   the bytes GNU ld produced. *)

let fixtures = "../../fixtures/compcert-3.17"
let fixture_sources = "../../fixtures/c"
let read path = In_channel.with_open_bin path In_channel.input_all
let ( / ) = Filename.concat

let sources case =
  let dir = fixture_sources / case in
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.filter (fun f -> Filename.check_suffix f ".c")
  |> List.map (fun f -> (Filename.chop_suffix f ".c", read (dir / f)))

let cases () =
  Sys.readdir fixtures |> Array.to_list |> List.sort compare
  |> List.filter (fun c ->
      Sys.file_exists (fixtures / c / "aarch64" / "oracle" / "linked" / "manifest.txt"))

(* [text.hex]: whitespace-separated bytes in memory order. *)
let bytes_of_hex path =
  read path |> String.split_on_char '\n'
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (( <> ) "")
  |> List.map (fun h -> Char.chr (int_of_string ("0x" ^ h)))
  |> List.to_seq |> String.of_seq

let manifest case =
  read (fixtures / case / "aarch64" / "oracle" / "linked" / "manifest.txt")
  |> String.split_on_char '\n'
  |> List.filter_map (fun l ->
      match String.split_on_char '\t' (String.trim l) with
      | [ sec; kind; addr; size; file ] when sec <> "" ->
          Some (sec, kind, Int64.of_string addr, int_of_string size, file)
      | _ -> None)

let check case =
  let compiled =
    List.map
      (fun (stem, c) ->
        match Compcert_embed_aarch64.compile_to_asm ~name:(stem ^ ".c") c with
        | Ok s -> (stem, s)
        | Error e -> failwith (Format.asprintf "%a" Compcert_embed.pp_error e))
      (sources case)
  in
  match Compcert_embed_aarch64.assemble_units ~entry:"asm_test_entry" compiled with
  | Error e -> Printf.printf "%s: %s\n" case (Format.asprintf "%a" Compcert_embed.pp_error e)
  | Ok laid -> (
      let m = manifest case in
      let addresses = List.map (fun (sec, _, a, _, _) -> (sec, a)) m in
      match Image.bind_image laid ~addresses with
      | Error e -> Printf.printf "%s: BIND %s\n" case (Foundation.Diag.render e)
      | Ok image ->
          List.iter
            (fun (sec, kind, _, size, file) ->
              match List.find_opt (fun (s : Image.segment) -> s.name = sec) image.segments with
              | None -> Printf.printf "%s %s: missing\n" case sec
              | Some s ->
                  let ours = String.length s.bytes + s.zero_fill in
                  if kind = "nobits" then
                    Printf.printf "%s %s: %s\n" case sec
                      (if ours = size && s.bytes = "" then "size matches" else "SIZE DIFFERS")
                  else
                    let want = bytes_of_hex (fixtures / case / "aarch64" / "oracle" / file) in
                    Printf.printf "%s %s: %s\n" case sec
                      (if String.equal want s.bytes then "identical" else "BYTES DIFFER"))
            m)

let%expect_test "every aarch64 fixture case links to the oracle's bytes" =
  List.iter check (cases ());
  [%expect
    {|
    args_arith .text: identical
    cond_select .text: identical
    cross_bss .text: identical
    cross_bss .bss: size matches
    cross_call .text: identical
    cross_data .text: identical
    cross_data .data: identical
    direct_call .text: identical
    global_ldst .text: identical
    global_ldst .data: identical
    loop .text: identical
    return42 .text: identical |}]

let%expect_test "an undefined external function is a plan-stage image.undefined error naming it" =
  (match
     Compcert_embed_aarch64.compile
       "extern int helper(int);\nlong entry(void *io) { return helper(3); }\n"
   with
  | Ok _ -> print_endline "unexpectedly Ok"
  | Error e ->
      Printf.printf "stage %s, codes %s\n%s\n"
        (Compcert_embed.stage_name e.stage)
        (String.concat "," e.codes) e.message);
  [%expect
    {|
    stage plan, codes image.undefined
    <synthesized by aarch64.encode>: error[image.undefined]: fixup target references undefined symbol helper |}]

let%expect_test "a CompCert error is tagged with the compile stage" =
  (match Compcert_embed_aarch64.compile "long entry(void *io) { return 1 +; }\n" with
  | Ok _ -> print_endline "unexpectedly Ok"
  | Error e -> Printf.printf "stage %s\n" (Compcert_embed.stage_name e.stage));
  [%expect {| stage compile |}]
