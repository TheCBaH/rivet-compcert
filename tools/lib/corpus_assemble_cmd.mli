(** M5 corpus growth: run CompCert's own [test/c/] suite through the full
    [parse -> simplify -> lower -> encode -> plan_image] pipeline, one target
    at a time - not merely {!Corpus_classify_cmd}'s parse-level check.

    Every file in the corpus references at least one external symbol
    (libc, or a symbol defined in a CompCert test-suite file this corpus does
    not also compile) that a single-translation-unit compile can never
    resolve (.ai/asm_plan.md §2.2's libc-linking non-goal). [plan_image]
    reports every one of those as [image.undefined] and nothing else - so a
    file whose only diagnostics carry that code is {e blocked} on an expected,
    already-understood gap, not rejected for a real parser, lowering,
    encoding, or image-planning bug. This module tells the two apart, and
    publishes the result the same recoverable way {!Corpus_classify_cmd}
    publishes its own manifest/summary pair. See [asm/docs/corpus.md]. *)

(** {1 The assembler-runner seam} *)

type raw_outcome = Exited of { code : int; stderr : string } | Runner_failed of string
type runner = generated_s_rel:string -> raw_outcome

type assemble_outcome =
  | Assembled  (** Exit 0: the full pipeline reached a plan with no diagnostic at all. *)
  | Blocked of { undefined_count : int; reasons : string }
      (** Every diagnostic carries code [image.undefined] - [undefined_count] of
          them, [reasons] their sorted, deduplicated, ["; "]-joined messages. *)
  | Rejected of string
      (** At least one diagnostic carries some other code: a real parser,
          lowering, encoding, or image-planning gap. The first such
          diagnostic's line (or, absent any recognizable diagnostic line, the
          first non-empty stderr line, or a fixed placeholder for empty
          stderr). *)
  | Runner_failed of string

val normalize : raw_outcome -> assemble_outcome

val real_runner : Repo.t -> Target.t -> runner
(** Invokes the real, already-built [asm.exe] with [--target <t>] and no
    [--dump] flag, i.e. its default full-pipeline path to [plan_image]. *)

(** {1 Real GNU as/objdump differential} *)

type gas_record =
  | Gas_ok of { objdump_sha256 : string }
  | Gas_error of string
      (** Whether real GNU [as] for the target also accepts the identical generated
    [.s] file - a question independent of this project's own [outcome] below,
    per Ordered Work item 5 ("Add a broader-corpus differential gate"). Every
    file in this corpus still blocks on [image.undefined], so there is no
    linked image on either side yet to compare byte-for-byte; only a hash of
    real [objdump]'s disassembly is kept, so a drift on regen is visible as a
    changed hash without committing the text itself. *)

type gas_prober = generated_s_rel:string -> (gas_record, Tool_error.t) Err.t
(** Fakeable like {!runner}: every test in this module besides the one
    integration test at the bottom is hermetic, and this seam is what keeps
    the gas differential hermetic-testable too. An [Error] means the probe's
    own machinery broke; real [as] rejecting the input is [Ok (Gas_error _)]. *)

val real_gas_prober : Repo.t -> Gnu_tools.t -> gas_prober
(** Assembles [generated_s_rel] with the real, installed cross [as] for
    [tools]'s target and, on success, hashes real [objdump]'s disassembly. *)

(** {1 Classifying compiled entries} *)

type outcome =
  | Rec_accepted
  | Rec_blocked of { undefined_count : int; reasons : string }
  | Rec_rejected of string

type file_record = {
  path : string;
  source_sha256 : string;
  generated_sha256 : string;
  outcome : outcome;
  gas : gas_record;
}

val classify_all :
  runner ->
  gas_prober ->
  Corpus_classify_cmd.compiled_entry list ->
  (file_record list, Tool_error.t) Err.t
(** Same traversal discipline as {!Corpus_classify_cmd.classify_all}: a single
    [Runner_failed] outcome (from the assembler runner) or gas-prober [Error]
    aborts the whole run rather than becoming one more finding. *)

(** {1 The manifest and summary formats} *)

type header = {
  suite : string;  (** Always ["c-assemble"] - {!check} rejects anything else. *)
  target : string;
  ccomp_version : string;
  ccomp_args : string;
  compcert_revision : string;
  shared_header_path : string;
  shared_header_sha256 : string;
}

type manifest = { header : header; files : file_record list }

val render_manifest : manifest -> string

val render_summary : manifest -> string
(** Totals (accepted/blocked/rejected), then rejected files grouped by exact
    reason text, sorted by reason - the same shape as
    {!Corpus_classify_cmd.render_summary}. [blocked] files are not grouped by
    reason in the summary: their per-file [reasons] evidence lives in
    [manifest.txt], and grouping would mostly just re-sort the corpus by which
    externals each file happens to call. *)

val parse_manifest : string -> (manifest, Tool_error.t) Err.t
(** A strict, positional parser: the six header lines in their fixed order,
    then zero or more file records. Does not itself require canonical
    ordering or check the fixed header values against their literals -
    {!check} does both. *)

(** {1 Publication} *)

val publish : Repo.t -> target:Target.t -> manifest -> (unit, Tool_error.t) Err.t
(** Creates [asm/fixtures/corpus/c-assemble/<target>/] if absent, then
    installs [manifest.txt] and [summary.txt] with the same recoverable
    two-file discipline {!Corpus_classify_cmd.publish} uses. *)

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
    {!Corpus_classify_cmd.publish_with}. *)

(** {1 CLI entry points} *)

val assemble_c_core :
  Repo.t ->
  git:Corpus_classify_cmd.git_probe ->
  runner:runner ->
  gas_prober:gas_prober ->
  compiler:Fpath.t ->
  target:Target.t ->
  (string, Tool_error.t) Err.t
(** {!assemble_c}'s body, parameterized over the CompCert checkout probe, the
    assembler runner, the gas prober, the compiler path and the target - the
    same seam {!Corpus_classify_cmd.classify_c_core} exposes, for the same
    reason. *)

val assemble_c : Repo.t -> Target.t -> Command.t
(** The heavy path for one target: requires that target's cross compiler
    ([make asm-cross-setup]) and a clean [modules/CompCert] checkout.
    Compiles all of [test/c/*.c] for it (the identical compile step
    {!Corpus_classify_cmd.classify_c} uses), runs each generated [.s] through
    the full pipeline, and publishes to
    [asm/fixtures/corpus/c-assemble/<target>/]. *)

val check_with : Repo.t -> git:Corpus_classify_cmd.git_probe -> Target.t -> Command.t
val published_targets : Repo.t -> Target.t list

val check : Repo.t -> Command.t
(** The cheap path: no cross toolchain, no CompCert build, no [asm.exe]. Runs
    {!check_with} against every {!published_targets} target and accumulates
    every target's output and failures, exactly like
    {!Corpus_classify_cmd.check} - kept as an entirely separate command so an
    assemble-c regression is never conflated with a classify-c one. *)
