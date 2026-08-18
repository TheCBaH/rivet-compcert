let path target ~work_root =
  Fpath.(work_root / "install" / Target.to_string target / "bin" / "ccomp")

let installed target ~work_root =
  let p = path target ~work_root in
  match Unix.access (Fpath.to_string p) [ Unix.X_OK ] with
  | () -> Some p
  | exception Unix.Unix_error _ -> None

let require_all targets ~work_root =
  let missing = List.filter (fun t -> installed t ~work_root = None) targets in
  if missing = [] then Ok ()
  else
    Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
      (Tool_error.v Tool_error.Spawn
         (Printf.sprintf
            "no installed ccomp for: %s - run 'make asm-cross-setup' \
             (tools/compcert-fixture-setup.sh all; it never skips)"
            (String.concat " " (List.map Target.to_string missing))))

let first_line s = match String.index_opt s '\n' with None -> s | Some i -> String.sub s 0 i

let version compiler =
  match
    Tool_process.exec
      (Tool_process.spec ~stdout:Tool_process.Out_capture ~stderr:Tool_process.Err_to_stdout
         ~accepted:Process_status.Zero_only ~label:"ccomp -version" (Fpath.to_string compiler)
         [ "-version" ])
  with
  | Error e -> Error e
  | Ok { Tool_process.stdout = Some s; _ } -> Ok (first_line s)
  | Ok _ ->
      Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
        (Tool_error.v Tool_error.Exec "ccomp -version produced no output")

let compile_s ~compiler ~cwd ~args ~out_rel ~source_rel ~case ~target =
  match
    Tool_process.exec
      (Tool_process.spec ~cwd ~stderr:Tool_process.Err_capture ~accepted:Process_status.Zero_only
         ~label:"ccomp" (Fpath.to_string compiler)
         (("-S" :: args) @ [ "-o"; out_rel; source_rel ]))
  with
  | Ok _ -> Ok ()
  | Error e ->
      (* The shell's wording, verbatim: this line is byte-compared. The child's
         own stderr has already been written through by the runner's error
         payload, so it is not repeated here. *)
      Err.map_error ~pos:__POS__ ~pp_error:Tool_error.pp
        (fun payload ->
          {
            payload with
            Tool_error.detail =
              Printf.sprintf "fixture compilation failed for %s/%s" case (Target.to_string target);
          })
        (Error e)
