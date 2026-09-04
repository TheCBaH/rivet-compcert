(* Corpus_classify_gcc_cmd - hermetic: fakes/stubs only, no process and no
   cross toolchain, except the one integration test at the bottom which needs
   the real, already-built asm.exe. Mirrors test_corpus_classify.ml's own
   shape, scoped to what differs here: no ccomp/gcc process is ever spawned by
   this file, and there is no outcome:compile-failed (gcc compiles the whole
   test/c/ corpus cleanly on every target, so the module carries only
   accepted/rejected). *)

open Compcert_tools
open Corpus_classify_gcc_cmd

let ( let* ) = Result.bind
let failures = ref 0

let check name cond =
  if cond then Printf.printf "  ok   %s\n" name
  else (
    Printf.printf "  FAIL %s\n" name;
    incr failures)

let check_eq name ~expected ~actual =
  if String.equal expected actual then Printf.printf "  ok   %s\n" name
  else (
    Printf.printf "  FAIL %s\n    expected: %S\n    actual:   %S\n" name expected actual;
    incr failures)

let contains hay needle =
  let n = String.length needle and m = String.length hay in
  let rec go i = i + n <= m && (String.sub hay i n = needle || go (i + 1)) in
  go 0

let is_ok = function Ok _ -> true | Error _ -> false
let is_err = function Ok _ -> false | Error _ -> true

let with_tmp f =
  let dir = Filename.temp_file "corpus_classify_gcc" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun e -> rm (Filename.concat p e)) (Sys.readdir p);
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  in
  Fun.protect ~finally:(fun () -> rm dir) (fun () -> f (Fpath.v dir))

let write p s =
  let dir = Filename.dirname (Fpath.to_string p) in
  if not (Sys.file_exists dir) then ignore (Tool_fs.mkdir_p (Fpath.v dir));
  let oc = open_out_bin (Fpath.to_string p) in
  output_string oc s;
  close_out oc

let make_repo root =
  write Fpath.(root / "Makefile") "";
  write Fpath.(root / "tools" / "target-matrix.sh") "";
  write Fpath.(root / "asm" / "dune-project") "";
  match Repo.resolve ~cli:(Some root) ~env:(fun _ -> None) ~cwd:root with
  | Ok r -> r
  | Error _ -> failwith "test repo did not validate"

let exists p = Sys.file_exists (Fpath.to_string p)
let sha256_of p = match Tool_fs.sha256 p with Ok h -> h | Error _ -> failwith "sha256 failed"

(* {1 normalize, classify_all} *)

let test_normalize () =
  check "normalize: exit 0 is Accepted" (normalize (Exited { code = 0; stderr = "" }) = Accepted);
  check "normalize: a nonzero exit with a diagnostic uses its first non-empty line"
    (normalize (Exited { code = 1; stderr = "\n  bad.s:3: unknown directive .foo\nmore\n" })
    = Rejected "bad.s:3: unknown directive .foo");
  check "normalize: a nonzero exit with empty stderr falls back to a fixed string"
    (normalize (Exited { code = 2; stderr = "" }) = Rejected "(no diagnostic; exit 2)");
  check "normalize: Runner_failed passes through unchanged"
    (normalize (Runner_failed "spawn failed") = Runner_failed "spawn failed")

let entry ?(stem = "case") ?(source_sha = String.make 64 'a') ?(generated_sha = String.make 64 'b')
    () =
  {
    ce_path = "modules/CompCert/test/c/" ^ stem ^ ".c";
    ce_source_sha256 = source_sha;
    ce_generated_s_rel = ".corpus-work/c-gcc/" ^ stem ^ "/output.s";
    ce_generated_sha256 = generated_sha;
  }

let fake_gas_ok : gas_prober =
 fun ~generated_s_rel:_ -> Ok (Gas_ok { objdump_sha256 = String.make 64 '0' })

let test_classify_all () =
  let accept ~generated_s_rel:_ = Exited { code = 0; stderr = "" } in
  let reject ~generated_s_rel:_ = Exited { code = 1; stderr = "boom\n" } in
  (match classify_all accept fake_gas_ok [ entry ~stem:"a" (); entry ~stem:"b" () ] with
  | Ok
      [
        { path = "modules/CompCert/test/c/a.c"; outcome = Rec_accepted; _ };
        { path = "modules/CompCert/test/c/b.c"; outcome = Rec_accepted; _ };
      ] ->
      check "classify_all: every file accepted, in input order" true
  | _ -> check "classify_all: every file accepted, in input order" false);
  (match classify_all reject fake_gas_ok [ entry ~stem:"a" () ] with
  | Ok [ { outcome = Rec_rejected "boom"; _ } ] ->
      check "classify_all: a rejection becomes a record" true
  | _ -> check "classify_all: a rejection becomes a record" false);
  (match classify_all accept fake_gas_ok [ entry ~stem:"a" () ] with
  | Ok [ { gas = Gas_ok { objdump_sha256 }; _ } ] ->
      check "classify_all: the gas prober's result is threaded into the record"
        (String.equal objdump_sha256 (String.make 64 '0'))
  | _ -> check "classify_all: the gas prober's result is threaded into the record" false);
  let flaky = ref 0 in
  let runner : runner =
   fun ~generated_s_rel ->
    incr flaky;
    if !flaky = 2 then Runner_failed "the parser crashed"
    else Exited { code = 0; stderr = generated_s_rel }
  in
  check "classify_all: a Runner_failed outcome aborts the whole traversal, not just one record"
    (is_err
       (classify_all runner fake_gas_ok
          [ entry ~stem:"a" (); entry ~stem:"b" (); entry ~stem:"c" () ]));
  let failing_gas_prober : gas_prober =
   fun ~generated_s_rel:_ ->
    Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp (Tool_error.v Tool_error.Exec "gas probe broke")
  in
  check "classify_all: a gas-prober Error aborts the whole traversal too"
    (is_err (classify_all accept failing_gas_prober [ entry ~stem:"a" () ]))

(* {1 manifest/summary rendering, parsing, and round-tripping} *)

let sample_header =
  {
    suite = "c-gcc";
    target = "x86_64";
    gcc_version = "x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0";
    gcc_args = "-fno-pie";
    compcert_revision = String.make 40 '7';
    shared_header_path = "test/endian.h";
    shared_header_sha256 = String.make 64 '9';
  }

let sample_manifest =
  {
    header = sample_header;
    files =
      [
        {
          path = "modules/CompCert/test/c/aes.c";
          source_sha256 = String.make 64 'a';
          generated_sha256 = String.make 64 'b';
          outcome = Rec_accepted;
          gas = Gas_ok { objdump_sha256 = String.make 64 '1' };
        };
        {
          path = "modules/CompCert/test/c/fib.c";
          source_sha256 = String.make 64 'c';
          generated_sha256 = String.make 64 'd';
          outcome = Rec_rejected "cannot parse operand $.LC0";
          gas = Gas_error "Error: no such instruction";
        };
      ];
  }

let test_manifest_round_trip () =
  let text = render_manifest sample_manifest in
  check "render_manifest: sorted by path" (contains text "aes.c" && contains text "fib.c");
  match parse_manifest text with
  | Error _ -> check "parse_manifest: a rendered manifest parses back" false
  | Ok m ->
      check "parse_manifest: header round-trips" (m.header = sample_header);
      check "parse_manifest: files round-trip"
        (List.sort compare m.files = List.sort compare sample_manifest.files);
      check_eq "render_manifest: canonical round-trip is byte-for-byte" ~expected:text
        ~actual:(render_manifest m)

let test_render_summary () =
  let text = render_summary sample_manifest in
  check_eq "render_summary: totals and one reason group"
    ~expected:
      "total:2\n\
       accepted:1\n\
       rejected:1\n\
       reason:1\tcannot parse operand $.LC0\n\
       gas-ok:1\n\
       gas-error:1\n\
       gas-reason:1\tError: no such instruction\n"
    ~actual:text

let good_header =
  "suite:c-gcc\ntarget:x86_64\ngcc-version:v\ngcc-args:a\ncompcert-revision:" ^ String.make 40 '1'
  ^ "\nshared-header:test/endian.h\tsha256:" ^ String.make 64 '2' ^ "\n"

let good_gas = "\tgas:ok:" ^ String.make 64 '3'

let good_record =
  "modules/CompCert/test/c/aes.c\tsource-sha256:" ^ String.make 64 'a' ^ "\tgenerated-sha256:"
  ^ String.make 64 'b' ^ "\toutcome:accepted" ^ good_gas ^ "\n"

let test_parse_manifest_rejects () =
  check "parse_manifest: a missing final newline is rejected"
    (is_err (parse_manifest (good_header ^ good_record ^ "x")));
  check "parse_manifest: a missing header line is rejected"
    (is_err (parse_manifest "suite:c-gcc\ntarget:x86_64\n"));
  check "parse_manifest: outcome:accepted with a reason is rejected"
    (is_err
       (parse_manifest
          (good_header ^ "modules/CompCert/test/c/aes.c\tsource-sha256:" ^ String.make 64 'a'
         ^ "\tgenerated-sha256:" ^ String.make 64 'b' ^ "\toutcome:accepted\treason:x" ^ good_gas
         ^ "\n")));
  check "parse_manifest: outcome:rejected without a reason is rejected"
    (is_err
       (parse_manifest
          (good_header ^ "modules/CompCert/test/c/fib.c\tsource-sha256:" ^ String.make 64 'a'
         ^ "\tgenerated-sha256:" ^ String.make 64 'b' ^ "\toutcome:rejected" ^ good_gas ^ "\n")));
  check "parse_manifest: a record missing its trailing gas field is rejected"
    (is_err
       (parse_manifest
          (good_header ^ "modules/CompCert/test/c/aes.c\tsource-sha256:" ^ String.make 64 'a'
         ^ "\tgenerated-sha256:" ^ String.make 64 'b' ^ "\toutcome:accepted\n")));
  check "parse_manifest: a malformed gas field is rejected"
    (is_err
       (parse_manifest
          (good_header ^ "modules/CompCert/test/c/aes.c\tsource-sha256:" ^ String.make 64 'a'
         ^ "\tgenerated-sha256:" ^ String.make 64 'b' ^ "\toutcome:accepted\tgas:maybe\n")));
  check "parse_manifest: a duplicate path is rejected"
    (is_err (parse_manifest (good_header ^ good_record ^ good_record)));
  check "parse_manifest: an absolute path is rejected"
    (is_err
       (parse_manifest
          (good_header ^ "/etc/passwd\tsource-sha256:" ^ String.make 64 'a' ^ "\tgenerated-sha256:"
         ^ String.make 64 'b' ^ "\toutcome:accepted" ^ good_gas ^ "\n")));
  check "parse_manifest: a well-formed manifest with no file records is accepted"
    (is_ok (parse_manifest good_header))

(* {1 git_probe} - re-exported from Corpus_classify_cmd unmodified, so this
   only needs to confirm the re-export wires through, not re-derive the dirty-
   checkout/revision-mismatch behavior test_corpus_classify.ml already covers. *)

let stub_git ?(status = "") ?(head = String.make 40 '0') () =
  { status_porcelain = (fun () -> Ok status); head = (fun () -> Ok head) }

let test_git_checks () =
  check "check_clean_checkout: an empty status is clean"
    (is_ok (check_clean_checkout (stub_git ())));
  check "check_revision_matches: equal revisions succeed"
    (is_ok
       (check_revision_matches
          (stub_git ~head:(String.make 40 '1') ())
          ~expected:(String.make 40 '1')))

(* {1 publish - the recoverable two-file install} *)

let read p = match Tool_fs.read p with Ok s -> s | Error _ -> failwith "read failed"

let test_publish_first_run_no_prior () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let dest = Repo.corpus_c_gcc repo Target.X86_64 in
      check "publish: the destination directory does not exist yet" (not (exists dest));
      match publish repo ~target:Target.X86_64 sample_manifest with
      | Error _ -> check "publish: a from-scratch run creates the directory and both files" false
      | Ok () ->
          check "publish: the destination directory now exists" (exists dest);
          check_eq "publish: manifest.txt matches render_manifest"
            ~expected:(render_manifest sample_manifest)
            ~actual:(read Fpath.(dest / "manifest.txt"));
          check_eq "publish: summary.txt matches render_summary"
            ~expected:(render_summary sample_manifest)
            ~actual:(read Fpath.(dest / "summary.txt")))

let other_manifest = { sample_manifest with files = [ List.hd sample_manifest.files ] }

let test_publish_rollback_with_prior () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let dest = Repo.corpus_c_gcc repo Target.X86_64 in
      match publish repo ~target:Target.X86_64 sample_manifest with
      | Error _ -> check "publish: seeding a prior pair" false
      | Ok () -> (
          let prior_manifest = read Fpath.(dest / "manifest.txt") in
          Sys.remove (Fpath.to_string Fpath.(dest / "summary.txt"));
          Unix.mkdir (Fpath.to_string Fpath.(dest / "summary.txt")) 0o700;
          Unix.mkdir (Fpath.to_string Fpath.(dest / "summary.txt" / "blocker")) 0o700;
          match publish repo ~target:Target.X86_64 other_manifest with
          | Ok () -> check "publish: a summary-install failure with a prior pair is reported" false
          | Error _ ->
              check_eq "publish: on rollback, manifest.txt is restored byte-for-byte"
                ~expected:prior_manifest
                ~actual:(read Fpath.(dest / "manifest.txt"))))

let test_publish_rollback_itself_fails () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let always_fail_restore ~manifest_path:_ ~backup:_ ~prior_exists:_ =
        Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
          (Tool_error.v Tool_error.Write_file "restore stub always fails")
      in
      let always_fail_summary ~final:_ ~text:_ =
        Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp
          (Tool_error.v Tool_error.Write_file "summary stub always fails")
      in
      match
        publish_with repo ~target:Target.X86_64 sample_manifest ~commit_manifest:default_commit
          ~commit_summary:always_fail_summary ~restore:always_fail_restore
      with
      | Ok () -> check "publish: a rollback failure is reported, not silently swallowed" false
      | Error e ->
          let detail = (Err.Error.kind e).Tool_error.detail in
          check "publish: a rollback failure names both the summary and the restore failure"
            (contains detail "summary" && contains detail "restore"))

(* {1 check_with - the full pipeline against a fake repo} *)

let write_c_corpus repo files =
  List.iter
    (fun (name, contents) ->
      write Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "c" / name) contents)
    files;
  write Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h") "endian\n"

let build_and_seed repo ~git =
  let files = [ ("aes.c", "int aes;\n"); ("fib.c", "int fib;\n") ] in
  write_c_corpus repo files;
  let source_sha stem =
    sha256_of Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "c" / (stem ^ ".c"))
  in
  let header_sha =
    sha256_of Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
  in
  let* head = git.Corpus_classify_cmd.head () in
  let m =
    {
      header =
        {
          suite = "c-gcc";
          target = "x86_64";
          gcc_version = "gcc (Debian 14.2.0-19) 14.2.0";
          gcc_args = "-fno-pie";
          compcert_revision = head;
          shared_header_path = "test/endian.h";
          shared_header_sha256 = header_sha;
        };
      files =
        [
          {
            path = "modules/CompCert/test/c/aes.c";
            source_sha256 = source_sha "aes";
            generated_sha256 = String.make 64 'b';
            outcome = Rec_accepted;
            gas = Gas_ok { objdump_sha256 = String.make 64 '1' };
          };
          {
            path = "modules/CompCert/test/c/fib.c";
            source_sha256 = source_sha "fib";
            generated_sha256 = String.make 64 'd';
            outcome = Rec_rejected "cannot parse operand $.LC0";
            gas = Gas_error "Error: no such instruction";
          };
        ];
    }
  in
  let* () = publish repo ~target:Target.X86_64 m in
  Ok m

let command_is_success (c : Command.t) = c.exit = `Success

let command_fatal_contains (c : Command.t) needle =
  List.exists
    (function
      | Command.Fatal e -> contains (Err.Error.kind e).Tool_error.detail needle
      | Command.Output _ -> false)
    c.events

let test_check_with_happy_path () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          check "check_with: a freshly published, matching corpus passes"
            (command_is_success (check_with repo ~git Target.X86_64)))

let test_check_with_dirty_checkout () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let clean_git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git:clean_git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          let dirty_git =
            stub_git ~status:" M modules/CompCert/lib/Foo.v\n" ~head:(String.make 40 '5') ()
          in
          let c = check_with repo ~git:dirty_git Target.X86_64 in
          check "check_with: a dirty checkout fails" (not (command_is_success c));
          check "check_with: a dirty checkout is reported distinctly from a HEAD mismatch"
            (command_fatal_contains c "dirty"))

let test_check_with_revision_mismatch () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          let other_git = stub_git ~head:(String.make 40 '6') () in
          let c = check_with repo ~git:other_git Target.X86_64 in
          check "check_with: a HEAD mismatch fails" (not (command_is_success c));
          check "check_with: a HEAD mismatch names both revisions"
            (command_fatal_contains c (String.make 40 '5')))

let test_check_with_source_hash_mismatch () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          write
            Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "c" / "aes.c")
            "int aes; /* tampered */\n";
          check "check_with: a tampered source file is caught"
            (not (command_is_success (check_with repo ~git Target.X86_64))))

let test_check_with_inventory_mismatch () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          write
            Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "c" / "extra.c")
            "int extra;\n";
          check "check_with: an unlisted extra file fails the inventory check"
            (not (command_is_success (check_with repo ~git Target.X86_64))))

let test_check_with_fixed_header_literal () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok m ->
          let wrong = { m with header = { m.header with target = "arm" } } in
          let dest = Repo.corpus_c_gcc repo Target.X86_64 in
          write Fpath.(dest / "manifest.txt") (render_manifest wrong);
          write Fpath.(dest / "summary.txt") (render_summary wrong);
          check "check_with: a manifest declaring the wrong target is rejected"
            (not (command_is_success (check_with repo ~git Target.X86_64))))

let test_check_with_stale_summary () =
  with_tmp (fun root ->
      let repo = make_repo root in
      let git = stub_git ~head:(String.make 40 '5') () in
      match build_and_seed repo ~git with
      | Error _ -> check "check_with: seeding a valid corpus" false
      | Ok _ ->
          let dest = Repo.corpus_c_gcc repo Target.X86_64 in
          write Fpath.(dest / "summary.txt") "total:2\naccepted:2\nrejected:0\n";
          check "check_with: a stale summary.txt (wrong totals) is rejected"
            (not (command_is_success (check_with repo ~git Target.X86_64))))

(* {1 One integration test against the real, already-built asm.exe} *)

let test_real_runner_integration () =
  with_tmp (fun dir ->
      let good = Fpath.(dir / "good.s") in
      let bad = Fpath.(dir / "bad.s") in
      write good ".text\n.globl main\nmain:\n  ret\n";
      write bad ".text\n\tmovl %eax, [[[\n";
      let asm = Filename.concat (Filename.dirname Sys.executable_name) "../../../tool/asm.exe" in
      let run rel =
        Tool_process.exec
          (Tool_process.spec ~cwd:dir ~stdout:Tool_process.Out_null ~stderr:Tool_process.Err_capture
             ~accepted:Process_status.Any_exit ~label:"asm" asm
             [ "--target"; "x86_64"; "--dump-source-ast"; rel ])
      in
      (match run "good.s" with
      | Ok { Tool_process.status = Process_status.Exited 0; _ } ->
          check "integration: a well-formed .s file is accepted (exit 0)" true
      | _ -> check "integration: a well-formed .s file is accepted (exit 0)" false);
      match run "bad.s" with
      | Ok { Tool_process.status = Process_status.Exited code; stderr; _ } ->
          check "integration: a malformed .s file is rejected (nonzero exit)" (code <> 0);
          let reason =
            match normalize (Exited { code; stderr = Option.value stderr ~default:"" }) with
            | Rejected r -> r
            | _ -> ""
          in
          check "integration: the rejection reason carries no absolute path"
            (String.length reason = 0 || reason.[0] <> '/')
      | _ -> check "integration: a malformed .s file is rejected (nonzero exit)" false)

let () =
  print_endline "corpus_classify_gcc:";
  test_normalize ();
  test_classify_all ();
  test_manifest_round_trip ();
  test_render_summary ();
  test_parse_manifest_rejects ();
  test_git_checks ();
  test_publish_first_run_no_prior ();
  test_publish_rollback_with_prior ();
  test_publish_rollback_itself_fails ();
  test_check_with_happy_path ();
  test_check_with_dirty_checkout ();
  test_check_with_revision_mismatch ();
  test_check_with_source_hash_mismatch ();
  test_check_with_inventory_mismatch ();
  test_check_with_fixed_header_literal ();
  test_check_with_stale_summary ();
  test_real_runner_integration ();
  if !failures > 0 then (
    Printf.printf "corpus_classify_gcc: %d failures\n" !failures;
    exit 1)
  else print_endline "corpus_classify_gcc: all checks passed"
