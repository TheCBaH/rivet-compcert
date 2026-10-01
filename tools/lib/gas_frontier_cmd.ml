let ( let* ) = Result.bind
let err detail = Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp (Tool_error.v Tool_error.Validate detail)
let fixture_origin = "asm/fixtures/compcert-3.17/return42/"

let record_gas tools ~dir ~src =
  Tool_workspace.with_scratch ~label:"gas" (fun work ->
      let obj = Fpath.(work / "obj.o") in
      let* outcome = Gnu_tools.try_assemble tools ~src ~obj ~include_dir:None in
      match outcome with
      | Gnu_tools.Rejected body -> Tool_fs.write Fpath.(dir / "gas.txt") ("error\n" ^ body)
      | Gnu_tools.Assembled ->
          let* () = Tool_fs.write Fpath.(dir / "gas.txt") "ok\n" in
          let* disasm =
            Gnu_tools.objdump_disasm tools obj ~scrub:work ~drop_banner:true ~riscv_numeric:false
          in
          let* () = Tool_fs.write Fpath.(dir / "objdump.txt") disasm in
          let bin = Fpath.(work / "text.bin") in
          let* _ = Gnu_tools.objcopy_section tools ~src:obj ~section:".text" ~out:bin in
          let* bytes = Tool_fs.read bin in
          Tool_fs.write Fpath.(dir / "text.hex") (Hex_dump.of_bytes bytes))

let starts_with p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

let regen_case repo target dir =
  let* origin = Tool_fs.read Fpath.(dir / "origin.txt") in
  let origin = String.trim origin in
  let input = Fpath.(dir / "input.s") in
  let* () =
    if starts_with fixture_origin origin then
      let rel = Fpath.v ("fixtures/compcert-3.17/return42/" ^ Target.to_string target) in
      Tool_fs.copy ~src:Fpath.(Repo.path repo // rel / "asm_test_entry.s") ~dst:input
    else Ccomp.preexisting repo ~target ~origin ~out:input
  in
  record_gas (Gnu_tools.for_target target) ~dir ~src:input

let regen repo =
  let step =
    let root = Fpath.(Repo.path repo / "fixtures" / "gas-frontier") in
    let* () =
      List.fold_left
        (fun acc t ->
          let* () = acc in
          Gnu_tools.require (Gnu_tools.for_target t) ~qemu:false)
        (Ok ()) Target.all
    in
    let* n =
      List.fold_left
        (fun acc t ->
          let* n = acc in
          let tdir = Fpath.(root / Target.to_string t) in
          let* entries = Tool_fs.files ~root:tdir ~exclude:(fun _ -> false) in
          let cases =
            List.filter_map
              (fun rel -> if Filename.basename rel = "origin.txt" then Some (Filename.dirname rel) else None)
              entries
            |> List.sort String.compare
          in
          List.fold_left
            (fun acc c ->
              let* n = acc in
              let* () = regen_case repo t Fpath.(tdir // v c) in
              Ok (n + 1))
            (Ok n) cases)
        (Ok 0) Target.all
    in
    if n = 0 then err "no frontier cases under fixtures/gas-frontier"
    else Ok (Printf.sprintf "gas-frontier: %d cases re-recorded" n)
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]
