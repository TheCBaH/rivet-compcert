(* The corpus commands: CompCert's own test suites, compiled with the installed
   ccomp and classified against rivet's parser and pipeline. *)
open Rivet_tools
open Rivet_compcert_tools
module Cli = Rivet_tools_cli.Cli

let corpus_check_cmd =
  let run (err_trace, root) = (err_trace, Cli.with_repo root Corpus_classify_cmd.check) in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "check"
       ~doc:"Verify every already-published CompCert c/ classification, no toolchain needed")
    Cmdliner.Term.(const run $ Cli.common)

(* One explicit subcommand per target, never a `--target` flag with
   unimplemented values (asm/docs/corpus.md's own Follow-ups) - `Target.of_string`
   stays internal to Target.all's own literals here, not exposed to argv. *)
let corpus_classify_c_cmd (target : Target.t) =
  let name = "classify-c-" ^ Target.to_string target in
  let run (err_trace, root) =
    (err_trace, Cli.with_repo root (fun repo -> Corpus_classify_cmd.classify_c repo target))
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info name
       ~doc:
         (Printf.sprintf
            "Compile CompCert's test/c/ suite for %s and classify each file against the parser"
            (Target.to_string target)))
    Cmdliner.Term.(const run $ Cli.common)

let corpus_check_assemble_cmd =
  let run (err_trace, root) = (err_trace, Cli.with_repo root Corpus_assemble_cmd.check) in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "check-assemble"
       ~doc:
         "Verify every already-published CompCert c/ assemble classification, no toolchain needed")
    Cmdliner.Term.(const run $ Cli.common)

(* Same one-subcommand-per-target discipline as corpus_classify_c_cmd. *)
let corpus_assemble_c_cmd (target : Target.t) =
  let name = "assemble-c-" ^ Target.to_string target in
  let run (err_trace, root) =
    (err_trace, Cli.with_repo root (fun repo -> Corpus_assemble_cmd.assemble_c repo target))
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info name
       ~doc:
         (Printf.sprintf
            "Compile CompCert's test/c/ suite for %s and run each generated .s through the full \
             parse/simplify/lower/encode/plan_image pipeline"
            (Target.to_string target)))
    Cmdliner.Term.(const run $ Cli.common)

(* One explicit subcommand per (suite, target) pair, same discipline as
   corpus_classify_c_cmd - never a --suite/--target flag accepting an
   unimplemented value. *)
let corpus_classify_suite_cmd ~(spec : Corpus_classify_cmd.suite_spec) (target : Target.t) =
  let name = "classify-" ^ spec.suite_tag ^ "-" ^ Target.to_string target in
  let run (err_trace, root) =
    (err_trace, Cli.with_repo root (fun repo -> Corpus_classify_cmd.classify_suite spec repo target))
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info name
       ~doc:
         (Printf.sprintf
            "Compile CompCert's test/%s/ suite for %s and classify each file against the parser"
            spec.test_subdir (Target.to_string target)))
    Cmdliner.Term.(const run $ Cli.common)

let corpus_check_suite_cmd ~(spec : Corpus_classify_cmd.suite_spec) =
  let name = "check-" ^ spec.suite_tag in
  let run (err_trace, root) =
    (err_trace, Cli.with_repo root (fun repo -> Corpus_classify_cmd.check_suite spec repo))
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info name
       ~doc:
         (Printf.sprintf
            "Verify every already-published CompCert %s/ classification, no toolchain needed"
            spec.test_subdir))
    Cmdliner.Term.(const run $ Cli.common)

let corpus_classify_regression_cmd =
  corpus_classify_suite_cmd ~spec:Corpus_classify_cmd.regression_spec

let corpus_classify_compression_cmd =
  corpus_classify_suite_cmd ~spec:Corpus_classify_cmd.compression_spec

(* classify-c-gcc: same test/c/ corpus as corpus_classify_c_cmd, compiled with
   the system cross gcc (Gcc) instead of ccomp - a second, independent-compiler
   classification, published under its own asm/fixtures/corpus/c-gcc/<target>/
   destination (Corpus_classify_gcc_cmd). Same one-explicit-subcommand-per-
   target discipline as every other corpus subcommand. *)
let corpus_check_c_gcc_cmd =
  let run (err_trace, root) = (err_trace, Cli.with_repo root Corpus_classify_gcc_cmd.check) in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "check-c-gcc"
       ~doc:"Verify every already-published CompCert c-gcc/ classification, no toolchain needed")
    Cmdliner.Term.(const run $ Cli.common)

let corpus_classify_c_gcc_cmd (target : Target.t) =
  let name = "classify-c-gcc-" ^ Target.to_string target in
  let run (err_trace, root) =
    (err_trace, Cli.with_repo root (fun repo -> Corpus_classify_gcc_cmd.classify_c_gcc repo target))
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info name
       ~doc:
         (Printf.sprintf
            "Compile CompCert's test/c/ suite for %s with gcc and classify each file against the \
             parser"
            (Target.to_string target)))
    Cmdliner.Term.(const run $ Cli.common)

let corpus_cmd =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "corpus" ~doc:"CompCert's own test suites, classified against the parser")
    ((corpus_check_cmd :: List.map corpus_classify_c_cmd Target.all)
    @ (corpus_check_assemble_cmd :: List.map corpus_assemble_c_cmd Target.all)
    @ corpus_check_suite_cmd ~spec:Corpus_classify_cmd.regression_spec
      :: List.map corpus_classify_regression_cmd Target.all
    @ corpus_check_suite_cmd ~spec:Corpus_classify_cmd.compression_spec
      :: List.map corpus_classify_compression_cmd Target.all
    @ (corpus_check_c_gcc_cmd :: List.map corpus_classify_c_gcc_cmd Target.all))

let () =
  let work_root =
    let root =
      match Sys.getenv_opt "RIVET_ROOT" with
      | Some s when s <> "" -> Fpath.v s
      | _ -> Fpath.v (Sys.getcwd ())
    in
    Fpath.(root / "_compcert")
  in
  exit
    (Cli.main ~name:"rivet-compcert-tools"
       ~doc:"rivet's repository tooling with CompCert as the fixture compiler"
       ~fixtures:("vendor/rivet/fixtures/c", "fixtures/compcert-3.17")
       ~extra:[ corpus_cmd ] ~compiler:(Ccomp.compiler ~work_root) ())
