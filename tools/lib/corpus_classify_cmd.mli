(** M5 corpus growth: classify CompCert's own [test/c/] suite against this
    project's parser, for x86_64 only.

    Scope is deliberately narrow: one target, one corpus, parse-level
    classification only (not a GNU-[as] differential, not execution). See
    [asm/docs/corpus.md]. *)

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

(** {1 One compiled corpus file} *)

type compiled_entry = {
  ce_path : string;  (** repo-relative, e.g. [modules/CompCert/test/c/aes.c] *)
  ce_source_sha256 : string;
  ce_generated_s_rel : string;  (** repo-relative, e.g. [.corpus-work/c/aes/output.s] *)
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

val check_clean_checkout : git_probe -> (unit, Tool_error.t) Err.t
(** Fails, naming the dirty paths, unless [status_porcelain] is empty. Both
    {!classify_c} and {!check} call this before trusting [HEAD] at all - a
    locally modified compiler or standard header leaves [HEAD] unchanged, so
    a bare revision comparison cannot catch it. *)

val check_revision_matches : git_probe -> expected:string -> (unit, Tool_error.t) Err.t
(** Fails, naming both revisions, unless [expected] equals [git.head ()]. *)

(** {1 Publication} *)

val publish : Repo.t -> manifest -> (unit, Tool_error.t) Err.t
(** Creates [asm/fixtures/corpus/c/x86_64/] if absent, then installs
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
  manifest ->
  commit_manifest:commit_step ->
  commit_summary:commit_step ->
  restore:restore_step ->
  (unit, Tool_error.t) Err.t
(** {!publish}'s body, parameterized over its three fallible steps, so a test
    can fail each independently: committing the manifest, committing the
    summary, and restoring or removing the manifest when the summary commit
    fails. *)

(** {1 CLI entry points} *)

val classify_c_core :
  Repo.t -> git:git_probe -> runner:runner -> compiler:Fpath.t -> (string, Tool_error.t) Err.t
(** {!classify_c}'s body, parameterized over the CompCert checkout probe, the
    parser runner and the compiler path, so a test can supply a dirty [git]
    stub and confirm the run stops at {!check_clean_checkout} - before
    [modules/CompCert/test/c] is even read - rather than reaching the
    compiler at all. *)

val classify_c : Repo.t -> Command.t
(** The heavy path: requires the x86_64 cross compiler
    ([make asm-cross-setup]) and a clean [modules/CompCert] checkout. Compiles
    all of [test/c/*.c], classifies each with the real parser, and publishes. *)

val check_with : Repo.t -> git:git_probe -> Command.t
(** {!check}'s body, parameterized over the CompCert checkout probe so a test
    can exercise revision-mismatch and dirty-checkout handling without a real
    git checkout. *)

val check : Repo.t -> Command.t
(** The cheap path: no cross toolchain, no CompCert build, no [asm.exe].
    Fails on the first structural problem; see [asm/docs/corpus.md] for
    exactly what is re-verified against the live tree versus recorded only
    for audit. *)
