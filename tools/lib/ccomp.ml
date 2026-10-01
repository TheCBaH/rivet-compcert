let first_line s = match String.index_opt s '\n' with None -> s | Some i -> String.sub s 0 i
let work_root repo = Fpath.(Repo.path repo / "_compcert")

let configure_target : Target.t -> string = function
  | X86_32 -> "x86_32-linux"
  | X86_64 -> "x86_64-linux"
  | Arm -> "arm-linux"
  | Aarch64 -> "aarch64-linux"
  | Riscv32 -> "rv32-linux"
  | Riscv64 -> "rv64-linux"

(* The RISC-V profiles are freestanding: no target libc probe. *)
let configure_args : Target.t -> string list = function
  | Riscv32 | Riscv64 -> [ "-no-runtime-lib"; "-no-standard-headers" ]
  | X86_32 | X86_64 | Arm | Aarch64 -> []

(* -fno-pie: this project has no GOT, so the PIE addressing ccomp would choose
   for an external symbol could never be resolved. *)
let args : Target.t -> string list = function
  | Arm -> [ "-marm"; "-fno-pie" ]
  | X86_32 | X86_64 | Aarch64 | Riscv32 | Riscv64 -> [ "-fno-pie" ]

(* What classify-c-gcc passes the system cross gcc: ccomp's own arguments, and
   for RISC-V the ISA/ABI that ccomp has baked into its configuration and a
   generic cross gcc does not. *)
let gcc_args target =
  match target with
  | Target.Riscv32 -> args target @ [ "-march=rv32imafd"; "-mabi=ilp32d"; "-mno-relax" ]
  | Target.Riscv64 -> args target @ [ "-march=rv64imafd"; "-mabi=lp64d"; "-mno-relax" ]
  | Target.X86_32 | Target.X86_64 | Target.Arm | Target.Aarch64 -> args target

let install_dir target ~work_root = Fpath.(work_root / Target.to_string target / "install")
let path target ~work_root = Fpath.(install_dir target ~work_root / "bin" / "ccomp")

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
         (Printf.sprintf "no installed ccomp for: %s - run 'make ccomp-<target>'"
            (String.concat " " (List.map Target.to_string missing))))

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

let compile_s ?env ~compiler ~cwd ~args ~out_rel ~source_rel ~case ~target () =
  match
    Tool_process.exec
      (Tool_process.spec ~cwd ?env ~stderr:Tool_process.Err_capture
         ~accepted:Process_status.Zero_only ~label:"ccomp" (Fpath.to_string compiler)
         (("-S" :: args) @ [ "-o"; out_rel; source_rel ]))
  with
  | Ok _ -> Ok ()
  | Error e ->
      (* The child's own stderr has already been written through by the
         runner's error payload, so it is not repeated here. *)
      Err.map_error ~pos:__POS__ ~pp_error:Tool_error.pp
        (fun payload ->
          {
            payload with
            Tool_error.detail =
              Printf.sprintf "fixture compilation failed for %s/%s" case (Target.to_string target);
          })
        (Error e)

(* The fixtures are freestanding for the RISC-V targets, which the export
   ships a second compcert.ini for; the headers-free configuration must not
   change what the fixtures contain, so it is the one they were recorded with. *)
let fixture_env target ~work_root =
  match target with
  | Target.Riscv32 | Target.Riscv64 ->
      let ini = Fpath.(install_dir target ~work_root / "share" / "compcert.freestanding.ini") in
      if Sys.file_exists (Fpath.to_string ini) then
        Some [ ("COMPCERT_CONFIG", Some (Fpath.to_string ini)) ]
      else None
  | Target.X86_32 | Target.X86_64 | Target.Arm | Target.Aarch64 -> None

let compiler ~work_root =
  {
    Compiler.name = "ccomp";
    generator = "rivet-compcert-tools fixture regen";
    installed = (fun target -> installed target ~work_root <> None);
    require_all = (fun targets -> require_all targets ~work_root);
    version =
      (fun target ->
        match installed target ~work_root with
        | Some p -> version p
        | None -> require_all [ target ] ~work_root |> Result.map (fun () -> ""));
    provenance =
      (fun target ->
        [
          (Manifest.Compiler_target ("ccomp", target), Some (configure_target target));
          ( Manifest.Compiler_configure_args ("ccomp", target),
            match configure_args target with [] -> None | a -> Some (String.concat " " a) );
          (Manifest.Compiler_args ("ccomp", target), Some (String.concat " " (args target)));
        ]);
    compile_s =
      (fun target ~cwd ~out_rel ~source_rel ~case ->
        match installed target ~work_root with
        | None -> require_all [ target ] ~work_root
        | Some compiler ->
            compile_s ?env:(fixture_env target ~work_root) ~compiler ~cwd ~args:(args target)
              ~out_rel ~source_rel ~case ~target ());
  }

(* CompCert's runtime tree is arch-named, not target-named: both RISC-V profiles
   share runtime/riscV, and it is the MODEL_ define - not the directory - that
   selects the 32- or 64-bit half of vararg.S. *)
let runtime_dir = function Target.Riscv32 | Target.Riscv64 -> "riscV" | t -> Target.to_string t

(* CompCert compiles its runtime with -DMODEL_/-DABI_/-DENDIANNESS_/-DSYS_, the
   values its own configure picks per target. Without them FUNCTION is left
   undefined and every file preprocesses to text no assembler can read. *)
let runtime_defines = function
  | Target.Arm -> [ "-DMODEL_armv7a"; "-DABI_hardfloat"; "-DENDIANNESS_little"; "-DSYS_linux" ]
  | Target.X86_32 -> [ "-DMODEL_32sse2"; "-DABI_standard"; "-DENDIANNESS_little"; "-DSYS_linux" ]
  | Target.X86_64 -> [ "-DMODEL_64"; "-DABI_standard"; "-DENDIANNESS_little"; "-DSYS_linux" ]
  | Target.Aarch64 -> [ "-DMODEL_default"; "-DABI_standard"; "-DENDIANNESS_little"; "-DSYS_linux" ]
  | Target.Riscv32 -> [ "-DMODEL_32"; "-DABI_standard"; "-DENDIANNESS_little"; "-DSYS_linux" ]
  | Target.Riscv64 -> [ "-DMODEL_64"; "-DABI_standard"; "-DENDIANNESS_little"; "-DSYS_linux" ]

let logical_runtime = "modules/CompCert/runtime/"

(* The runtime sources an origin names, inside the export tarball: the logical
   name stays modules/CompCert/runtime/<dir>/<file>, as committed in the
   manifests, and maps to _compcert/<target>/export/runtime. *)
let runtime_source repo ~target origin =
  let expected = logical_runtime ^ Target.to_string target ^ "/" in
  let n = String.length expected in
  if not (String.length origin > n && String.sub origin 0 n = expected) then
    Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
      (Tool_error.v Tool_error.Validate
         (Printf.sprintf "origin %S is not under %s for target %s" origin expected
            (Target.to_string target)))
  else
    let rest = Filename.concat (runtime_dir target) (Filename.basename origin) in
    Ok Fpath.(work_root repo / Target.to_string target / "export" / "runtime" // v rest)

let preexisting repo ~target ~origin ~out =
  let ( let* ) = Result.bind in
  let* src = runtime_source repo ~target origin in
  let tools = Gnu_tools.for_target target in
  let* ok =
    Gnu_tools.preprocess tools ~src ~out ~defines:(runtime_defines target)
      ~include_dir:(Fpath.parent src)
  in
  if ok then Ok ()
  else
    Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
      (Tool_error.v Tool_error.Spawn
         (Printf.sprintf "preprocessing %s for %s failed" origin (Target.to_string target)))
