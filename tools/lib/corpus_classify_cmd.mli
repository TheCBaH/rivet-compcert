(** M5 corpus growth: classify CompCert's own [test/c/] suite against this
    project's parser, one target at a time.

    Scope is deliberately narrow: one corpus, parse-level classification only
    (not a GNU-[as] differential, not execution) - but now over any of the six
    targets, each published under its own [asm/fixtures/corpus/c/<target>/].
    See [asm/docs/corpus.md]. *)

(** {1 The parser-runner seam}

    Split into a fakeable raw layer plus a pure normalizer, so the
    empty-stderr fallback and the [Runner_failed] distinction are directly
    unit-testable without a subprocess. *)

type raw_outcome =
  | Exited of { code : int; stderr : string }
  | Runner_failed of string
      (** A spawn failure, or any outcome {!Tool_process.exec} rejects (a
          signal death or a timeout) - never a corpus finding, always a sign
          the tooling itself is broken. *)

type parse_outcome = Accepted | Rejected of string | Runner_failed of string

val normalize : raw_outcome -> parse_outcome
(** [Exited { code = 0; _ }] is [Accepted]. A nonzero [Exited] becomes
    [Rejected] of the first non-empty, trimmed line of [stderr], or
    ["(no diagnostic; exit <code>)"] when [stderr] has no non-empty line.
    [Runner_failed] passes through unchanged. *)

type runner = generated_s_rel:string -> raw_outcome

val real_runner : Repo.t -> Target.t -> runner
(** Invokes the real, already-built [asm.exe] with [--target <t>
    --dump-source-ast]. *)

(** {1 One compiled corpus file} *)

type compiled_entry = {
  ce_path : string;  (** repo-relative, e.g. [modules/CompCert/test/c/aes.c] *)
  ce_source_sha256 : string;
  ce_generated_s_rel : string;  (** repo-relative, e.g. [.corpus-work/c/aes/output.s] *)
  ce_generated_sha256 : string;
}

type outcome = Rec_accepted | Rec_rejected of string | Rec_compile_failed of string

type file_record = {
  path : string;
  source_sha256 : string;
  generated_sha256 : string option;
      (** [None] only for [Rec_compile_failed]: there is no generated [.s] to
          hash when [ccomp] itself never produced one. *)
  outcome : outcome;
}

val classify_all : runner -> compiled_entry list -> (file_record list, Tool_error.t) Err.t
(** Classify every entry with [runner]. A single [Runner_failed] outcome
    aborts the whole traversal - it is a tooling failure, not a corpus
    finding; an [Accepted]/[Rejected] outcome always becomes a record. *)

(** {1 The manifest and summary formats} *)

type header = {
  suite : string;
  target : string;
  ccomp_version : string;
  ccomp_args : string;
  compcert_revision : string;
  shared_header_path : string;
  shared_header_sha256 : string;
}

type manifest = { header : header; files : file_record list }

val render_manifest : manifest -> string
(** Canonical rendering: fixed header block, then one line per file sorted by
    path. {!parse_manifest} is not required to accept only canonical bytes,
    but {!check} requires [render_manifest (parse_manifest s) = s]. *)

val render_summary : manifest -> string
(** Totals, then rejected files grouped by exact reason text, sorted by
    reason. Deterministic and total: has no failure case. *)

val parse_manifest : string -> (manifest, Tool_error.t) Err.t
(** A strict, positional parser: the six header lines in their fixed order,
    then zero or more file records. Rejects a malformed hash, a record
    missing the field its outcome requires, a path that is not repo-relative
    or contains a [..] segment, and a duplicate path. Does not itself require
    canonical ordering or check the fixed header values against their
    literals - {!check} does both, on top of a successful parse. *)

(** {1 The CompCert checkout} *)

type git_probe = {
  status_porcelain : unit -> (string, Tool_error.t) Err.t;
  head : unit -> (string, Tool_error.t) Err.t;
}
(** [modules/CompCert]'s working-tree status and HEAD, injectable so tests can
    exercise dirty-checkout and revision-mismatch handling without a real git
    checkout. *)

val real_git_probe : Repo.t -> git_probe

(** {1 Discovering and compiling the corpus}

    Shared with {!Corpus_assemble_cmd}, which classifies the same
    [test/c/*.c] files through a later pipeline stage and must compile them
    the identical way - same discovery order, same [ccomp -S] invocation - so
    the two stages can never silently diverge on what "the corpus" is. *)

val discover_c_files : Repo.t -> (string list, Tool_error.t) Err.t
(** Every [*.c] file directly under [modules/CompCert/test/c], sorted. *)

val compile_entry :
  Repo.t ->
  compiler:Fpath.t ->
  args:string list ->
  corpus_work_root:Tool_workspace.recreatable_root ->
  target:Target.t ->
  string ->
  (compiled_entry, Tool_error.t) Err.t
(** Compiles one [test/c/<file>] with [ccomp -S] into
    [.corpus-work/c/<target>/<stem>/output.s] and hashes both the source and
    the generated assembly. *)

(** {1 Other CompCert test suites}

    Generalizes {!discover_c_files}/{!compile_entry} above to CompCert's other
    static, committed-source test suites ([regression], [compression] - not
    [abi], whose sources are generator-produced, some with an explicit random
    seed, so it does not fit this "hash a committed .c file" model; see
    asm/docs/corpus.md's Follow-ups). {!discover_c_files} and {!compile_entry}
    themselves are untouched by this generalization: {!Corpus_assemble_cmd}
    depends on their exact current behavior for [test/c/]. *)

type suite_spec = {
  suite_tag : string;  (** The manifest's [suite:] value, e.g. ["regression"]. *)
  test_subdir : string;
      (** The directory name under [modules/CompCert/test/], e.g. ["regression"]. *)
  extra_ccomp_args : string list;  (** Appended after the target's own [ccomp_args]. *)
  dest : Repo.t -> Target.t -> Fpath.t;
}

val regression_spec : suite_spec
val compression_spec : suite_spec

val discover_suite_files : Repo.t -> suite_spec -> (string list, Tool_error.t) Err.t
(** Every [*.c] file directly under [modules/CompCert/test/<spec.test_subdir>],
    sorted. *)

(** [compile_or_record]'s result: a file that compiled becomes {!Ready}, ready
    for {!classify_all}-style classification; a file that failed to compile at
    all becomes an already-final {!Precompiled} record
    ([outcome:compile-failed]) - unlike {!compile_entry}, this never aborts
    the whole run for one file CompCert itself cannot compile
    (asm/docs/corpus.md's Follow-ups: a bigger, less curated suite than
    [test/c/] can contain files known not to compile for a given target, e.g.
    a different architecture's builtins). *)
type prepared = Ready of compiled_entry | Precompiled of file_record

val compile_or_record :
  Repo.t ->
  compiler:Fpath.t ->
  args:string list ->
  corpus_work_root:Tool_workspace.recreatable_root ->
  spec:suite_spec ->
  target:Target.t ->
  string ->
  (prepared, Tool_error.t) Err.t

val prepare_all :
  Repo.t ->
  compiler:Fpath.t ->
  args:string list ->
  corpus_work_root:Tool_workspace.recreatable_root ->
  spec:suite_spec ->
  target:Target.t ->
  string list ->
  (prepared list, Tool_error.t) Err.t

val classify_prepared : runner -> prepared list -> (file_record list, Tool_error.t) Err.t
(** Like {!classify_all}, but passes an already-{!Precompiled} record through
    unchanged instead of invoking [runner] on it. *)

val check_clean_checkout : git_probe -> (unit, Tool_error.t) Err.t
(** Fails, naming the dirty paths, unless [status_porcelain] is empty. Both
    {!classify_c} and {!check} call this before trusting [HEAD] at all - a
    locally modified compiler or standard header leaves [HEAD] unchanged, so
    a bare revision comparison cannot catch it. *)

val check_revision_matches : git_probe -> expected:string -> (unit, Tool_error.t) Err.t
(** Fails, naming both revisions, unless [expected] equals [git.head ()]. *)

(** {1 Publication} *)

val publish : Repo.t -> target:Target.t -> manifest -> (unit, Tool_error.t) Err.t
(** Creates [asm/fixtures/corpus/c/<target>/] if absent, then installs
    [manifest.txt] and [summary.txt] so the destination is always either the
    last known-good pair or the new pair, including on the very first run (no
    prior manifest) and including when the second install fails after the
    first succeeded - see [asm/docs/corpus.md]. *)

type commit_step = final:Fpath.t -> text:string -> (unit, Tool_error.t) Err.t

type restore_step =
  manifest_path:Fpath.t -> backup:Fpath.t -> prior_exists:bool -> (unit, Tool_error.t) Err.t

val default_commit : commit_step
(** The real, atomic single-file commit {!publish} uses for both files -
    {!Tool_fs.with_staging}. Exposed so a test can keep one of
    {!publish_with}'s two commit steps real while stubbing the other. *)

val publish_with :
  Repo.t ->
  target:Target.t ->
  ?dest_dir:Fpath.t ->
  manifest ->
  commit_manifest:commit_step ->
  commit_summary:commit_step ->
  restore:restore_step ->
  (unit, Tool_error.t) Err.t
(** {!publish}'s body, parameterized over its three fallible steps, so a test
    can fail each independently: committing the manifest, committing the
    summary, and restoring or removing the manifest when the summary commit
    fails. [dest_dir] defaults to [Repo.corpus_c repo target] - {!publish}'s
    own destination; {!publish_suite} overrides it with the [suite_spec]'s
    own. *)

val publish_suite :
  suite_spec -> Repo.t -> target:Target.t -> manifest -> (unit, Tool_error.t) Err.t
(** {!publish}, publishing to [spec.dest repo target] instead of
    {!Repo.corpus_c}. *)

(** {1 CLI entry points} *)

val classify_c_core :
  Repo.t ->
  git:git_probe ->
  runner:runner ->
  compiler:Fpath.t ->
  target:Target.t ->
  (string, Tool_error.t) Err.t
(** {!classify_c}'s body, parameterized over the CompCert checkout probe, the
    parser runner, the compiler path and the target, so a test can supply a
    dirty [git] stub and confirm the run stops at {!check_clean_checkout} -
    before [modules/CompCert/test/c] is even read - rather than reaching the
    compiler at all. *)

val classify_c : Repo.t -> Target.t -> Command.t
(** The heavy path for one target: requires that target's cross compiler
    ([make asm-cross-setup], or a single-target
    [tools/compcert-fixture-setup.sh <target>]) and a clean [modules/CompCert]
    checkout. Compiles all of [test/c/*.c] for it, classifies each with the
    real parser, and publishes to [asm/fixtures/corpus/c/<target>/]. *)

val check_with : Repo.t -> git:git_probe -> Target.t -> Command.t
(** {!check}'s body for one target, parameterized over the CompCert checkout
    probe so a test can exercise revision-mismatch and dirty-checkout
    handling without a real git checkout. *)

val published_targets : Repo.t -> Target.t list
(** Every target with a [manifest.txt] already published under
    [asm/fixtures/corpus/c/<target>/], in {!Target.all} order - not every one
    of the six, since a target's manifest lands only once its own
    [classify-c-<target>] has actually been run against a real compiler. *)

val check : Repo.t -> Command.t
(** The cheap path: no cross toolchain, no CompCert build, no [asm.exe]. Runs
    {!check_with} against every {!published_targets} target and accumulates
    every target's output and failures (P4: a later target's success is never
    hidden by an earlier target's failure). Fails outright if no target has
    been published yet. See [asm/docs/corpus.md] for exactly what is
    re-verified against the live tree versus recorded only for audit. *)

(** {1 classify-regression, classify-compression}

    {!classify_c}'s same shape, over {!regression_spec}/{!compression_spec}
    instead of the hard-coded [test/c/] literals. *)

val classify_suite_core :
  Repo.t ->
  git:git_probe ->
  runner:runner ->
  compiler:Fpath.t ->
  spec:suite_spec ->
  target:Target.t ->
  (string, Tool_error.t) Err.t

val classify_suite : suite_spec -> Repo.t -> Target.t -> Command.t

val classify_regression : Repo.t -> Target.t -> Command.t
(** [classify_suite regression_spec]: CompCert's [test/regression/] suite. *)

val classify_compression : Repo.t -> Target.t -> Command.t
(** [classify_suite compression_spec]: CompCert's [test/compression/] suite. *)

(** {1 check-regression, check-compression} *)

val check_suite_with : Repo.t -> git:git_probe -> suite_spec -> Target.t -> Command.t
val published_targets_for : suite_spec -> Repo.t -> Target.t list
val check_suite : suite_spec -> Repo.t -> Command.t
val check_regression : Repo.t -> Command.t
val check_compression : Repo.t -> Command.t
