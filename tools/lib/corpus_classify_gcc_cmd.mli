(** M5 corpus growth: classify-c-gcc, a second, independent-compiler sibling of
    {!Corpus_classify_cmd}'s classify-c.

    Same [modules/CompCert/test/c/*.c] corpus, same parse-level
    [--dump-source-ast] classification, but compiled with the system cross
    [gcc] ({!Gcc}) instead of [ccomp] - a genuinely different code generator,
    so its accepted/rejected split is independent evidence of this project's
    real-world GNU-syntax coverage, not a restatement of classify-c's own
    findings. Published under its own destination,
    [asm/fixtures/corpus/c-gcc/<target>/], with its own manifest header
    ([gcc-version]/[gcc-args] rather than [ccomp-version]/[ccomp-args]) - see
    [asm/docs/corpus.md]. *)

(** {1 The parser-runner seam} *)

type raw_outcome = Exited of { code : int; stderr : string } | Runner_failed of string
type parse_outcome = Accepted | Rejected of string | Runner_failed of string

val normalize : raw_outcome -> parse_outcome

type runner = generated_s_rel:string -> raw_outcome

val real_runner : Repo.t -> Target.t -> runner
(** Invokes the real, already-built [asm.exe] with [--target <t>
    --dump-source-ast], the same 120s external [timeout] Corpus_classify_cmd's
    own runner uses. *)

(** {1 One compiled corpus file} *)

type compiled_entry = {
  ce_path : string;
  ce_source_sha256 : string;
  ce_generated_s_rel : string;
  ce_generated_sha256 : string;
}

type outcome = Rec_accepted | Rec_rejected of string

type file_record = {
  path : string;
  source_sha256 : string;
  generated_sha256 : string;
  outcome : outcome;
}

val classify_all : runner -> compiled_entry list -> (file_record list, Tool_error.t) Err.t

(** {1 The manifest and summary formats} *)

type header = {
  suite : string;
  target : string;
  gcc_version : string;
  gcc_args : string;
  compcert_revision : string;
  shared_header_path : string;
  shared_header_sha256 : string;
}

type manifest = { header : header; files : file_record list }

val render_manifest : manifest -> string
val render_summary : manifest -> string
val parse_manifest : string -> (manifest, Tool_error.t) Err.t

(** {1 The CompCert checkout} - re-exported from {!Corpus_classify_cmd},
    unmodified: a plain git probe with no manifest-format coupling. *)

type git_probe = Corpus_classify_cmd.git_probe = {
  status_porcelain : unit -> (string, Tool_error.t) Err.t;
  head : unit -> (string, Tool_error.t) Err.t;
}

val real_git_probe : Repo.t -> git_probe
val check_clean_checkout : git_probe -> (unit, Tool_error.t) Err.t
val check_revision_matches : git_probe -> expected:string -> (unit, Tool_error.t) Err.t

(** {1 Discovering and compiling the corpus} *)

val discover_c_files : Repo.t -> (string list, Tool_error.t) Err.t
(** Re-exported from {!Corpus_classify_cmd}: source-directory discovery only,
    no compiler involved, so both classify-c and classify-c-gcc share exactly
    one definition of "the corpus". *)

val compile_entry :
  Repo.t ->
  compiler:string ->
  args:string list ->
  corpus_work_root:Tool_workspace.recreatable_root ->
  target:Target.t ->
  string ->
  (compiled_entry, Tool_error.t) Err.t
(** Compiles one [test/c/<file>] with [gcc -S] into
    [.corpus-work/c-gcc/<target>/<stem>/output.s] and hashes both the source
    and the generated assembly. [compiler] is a bare PATH-resolved name
    (e.g. from {!Gcc.tool_name}), not an absolute path - matching every other
    cross-tool invocation in this project. *)

(** {1 Publication} *)

val publish : Repo.t -> target:Target.t -> manifest -> (unit, Tool_error.t) Err.t
(** Creates [asm/fixtures/corpus/c-gcc/<target>/] if absent, then installs
    [manifest.txt] and [summary.txt] with the same crash-safe staged-install
    discipline as {!Corpus_classify_cmd.publish}. *)

type commit_step = final:Fpath.t -> text:string -> (unit, Tool_error.t) Err.t

type restore_step =
  manifest_path:Fpath.t -> backup:Fpath.t -> prior_exists:bool -> (unit, Tool_error.t) Err.t

val default_commit : commit_step

val publish_with :
  Repo.t ->
  target:Target.t ->
  manifest ->
  commit_manifest:commit_step ->
  commit_summary:commit_step ->
  restore:restore_step ->
  (unit, Tool_error.t) Err.t
(** {!publish}'s body, parameterized over its three fallible steps - see
    {!Corpus_classify_cmd.publish_with}, whose test-injection rationale
    applies identically here. *)

(** {1 CLI entry points} *)

val classify_c_gcc_core :
  Repo.t ->
  git:git_probe ->
  runner:runner ->
  compiler:string ->
  args:string list ->
  gcc_version:string ->
  target:Target.t ->
  (string, Tool_error.t) Err.t
(** {!classify_c_gcc}'s body, parameterized over the CompCert checkout probe,
    the parser runner, and the compiler invocation, so a test can supply a
    dirty [git] stub and confirm the run stops at {!check_clean_checkout} -
    before [modules/CompCert/test/c] is even read, and before [gcc] is
    required to be installed at all. *)

val classify_c_gcc : Repo.t -> Target.t -> Command.t
(** The heavy path for one target: requires that target's cross [gcc]
    (installed system-wide - unlike classify-c, no [make asm-cross-setup] and
    no CompCert build) and a clean [modules/CompCert] checkout. Compiles all of
    [test/c/*.c] for it, classifies each with the real parser, and publishes
    to [asm/fixtures/corpus/c-gcc/<target>/]. *)

val check_with : Repo.t -> git:git_probe -> Target.t -> Command.t
val published_targets : Repo.t -> Target.t list

val check : Repo.t -> Command.t
(** The cheap path: no cross toolchain, no CompCert build, no [asm.exe]. Same
    shape as {!Corpus_classify_cmd.check}, against [c-gcc]'s own published
    manifests. *)
