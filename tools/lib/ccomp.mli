(** The CompCert compilers installed from the extractor's export tarballs
    ([make ccomp-<target>]) under [_compcert/<target>/install], and the
    compilation the fixtures and corpora make with them. *)

val work_root : Repo.t -> Fpath.t
(** [_compcert] under the repository root. *)

val configure_target : Target.t -> string
(** CompCert's own target name, e.g. ["aarch64-linux"]. *)

val configure_args : Target.t -> string list
(** The extra [configure] arguments of the freestanding RISC-V builds. *)

val args : Target.t -> string list
(** The arguments every compilation passes besides [-S -o]. They are recorded
    in the manifests and, through ccomp's command-line banner, in the bytes. *)

val gcc_args : Target.t -> string list
(** {!args} plus, for RISC-V, the [-march]/[-mabi]/[-mno-relax] a generic cross
    gcc needs to compile the same ISA. What [classify-c-gcc] passes after [-S]. *)

val path : Target.t -> work_root:Fpath.t -> Fpath.t
(** Where a target's ccomp would be, whether or not it is installed. *)

val installed : Target.t -> work_root:Fpath.t -> Fpath.t option
(** Performs no [ensure]: asking whether a compiler exists creates nothing. *)

val require_all : Target.t list -> work_root:Fpath.t -> (unit, Tool_error.t) Err.t
(** Names every missing target in one diagnostic. *)

val version : Fpath.t -> (string, Tool_error.t) Err.t
(** The first line of [ccomp -version]. *)

val compile_s :
  ?env:(string * string option) list ->
  compiler:Fpath.t ->
  cwd:Fpath.t ->
  args:string list ->
  out_rel:string ->
  source_rel:string ->
  case:string ->
  target:Target.t ->
  unit ->
  (unit, Tool_error.t) Err.t
(** [cwd] and BOTH paths are relative, and that is a correctness requirement
    rather than a style choice: ccomp writes the command line into a banner in
    the generated assembly, so an absolute path would put this checkout's
    location into the committed bytes. *)

val compiler : work_root:Fpath.t -> Compiler.t
(** What {!Fixture_cmd} generates and verifies the fixtures with. *)
