(** The installed cross compilers, and the one compile invocation the fixtures
    make. *)

val path : Target.t -> work_root:Fpath.t -> Fpath.t
(** Where a target's compiler WOULD be. Every shell call site spells
    "$WORK_ROOT/install/<t>/bin/ccomp" as an absolute path, so a PATH shim never
    intercepts one - which is why the fake-compiler tests install there too. *)

val installed : Target.t -> work_root:Fpath.t -> Fpath.t option
(** Performs no [ensure]: asking whether a compiler exists must not create the
    work root. *)

val require_all : Target.t list -> work_root:Fpath.t -> (unit, Tool_error.t) Err.t
(** Names every missing target in one diagnostic, with the shell's wording. *)

val version : Fpath.t -> (string, Tool_error.t) Err.t
(** `ccomp -version 2>&1 | head -1`. The merge is [Err_to_stdout] rather than
    two captures concatenated, because concatenation loses the interleaving. *)

val compile_s :
  compiler:Fpath.t ->
  cwd:Fpath.t ->
  args:string list ->
  out_rel:string ->
  source_rel:string ->
  case:string ->
  target:Target.t ->
  (unit, Tool_error.t) Err.t
(** [cwd] and BOTH paths are relative, and that is a correctness requirement
    rather than a style choice: CompCert writes the command line into a
    "# Command line:" banner in the generated assembly, so an absolute path
    would put this checkout's location into the committed bytes. *)
