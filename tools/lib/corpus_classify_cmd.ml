let ( let* ) = Result.bind

let err ?path op detail =
  Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp (Tool_error.v ?path op detail)

(* {1 The parser-runner seam} *)

type raw_outcome = Exited of { code : int; stderr : string } | Runner_failed of string
type parse_outcome = Accepted | Rejected of string | Runner_failed of string
type runner = generated_s_rel:string -> raw_outcome

let first_nonempty_line s =
  String.split_on_char '\n' s |> List.map String.trim |> List.find_opt (fun l -> l <> "")

let normalize = function
  | Exited { code = 0; _ } -> Accepted
  | Exited { code; stderr } -> (
      match first_nonempty_line stderr with
      | Some l -> Rejected l
      | None -> Rejected (Printf.sprintf "(no diagnostic; exit %d)" code))
  | Runner_failed msg -> Runner_failed msg

(* A bigger, less curated suite than test/c/ can contain a file the parser
   handles pathologically rather than rejects outright - CompCert's
   test/regression/floats.c generates ~110K lines of assembly, and this
   project's --dump-source-ast does not return on it in any bounded time this
   session tried (still running past 60s of CPU time). Wrapped in the
   external `timeout`, the same way gnu_tools.ml's qemu_run bounds a guest
   run, so ONE such file becomes a bounded, recorded outcome (exit 124, the
   same reserved code expected-status.mli documents) instead of hanging the
   whole classify run - and, in CI, the whole pipeline - forever. *)
let classify_timeout_s = 120
let asm_exe repo = Fpath.(Repo.path repo / "asm" / "_build" / "default" / "tool" / "asm.exe")

let real_runner repo (target : Target.t) : runner =
 fun ~generated_s_rel ->
  match
    Tool_process.exec
      (Tool_process.spec ~cwd:(Repo.path repo) ~stdout:Tool_process.Out_null
         ~stderr:Tool_process.Err_capture ~parsed_output:true ~accepted:Process_status.Any_exit
         ~label:"corpus-classify-parse" "timeout"
         (Printf.sprintf "%ds" classify_timeout_s
         :: Fpath.to_string (asm_exe repo)
         :: [ "--target"; Target.to_string target; "--dump-source-ast"; generated_s_rel ]))
  with
  | Ok { Tool_process.status = Process_status.Exited code; stderr; _ } ->
      Exited { code; stderr = Option.value stderr ~default:"" }
  | Ok { Tool_process.status = Process_status.Signaled _ | Process_status.Timed_out; _ } ->
      (* Unreachable: accepted:Any_exit accepts every Exited _ and nothing
         else, so exec would have returned Error for a signal death or a
         timeout instead. *)
      Runner_failed "parser exited abnormally"
  | Error e -> Runner_failed (Format.asprintf "%a" (Err.Error.pp Tool_error.pp) e)

(* {1 One compiled corpus file, and classifying it} *)

type compiled_entry = {
  ce_path : string;
  ce_source_sha256 : string;
  ce_generated_s_rel : string;
  ce_generated_sha256 : string;
}

type outcome = Rec_accepted | Rec_rejected of string | Rec_compile_failed of string

type file_record = {
  path : string;
  source_sha256 : string;
  generated_sha256 : string option;
      (** [None] only for {!Rec_compile_failed}: there is no generated [.s] to
          hash when [ccomp] itself never produced one. *)
  outcome : outcome;
}

let classify_entry runner (e : compiled_entry) =
  match normalize (runner ~generated_s_rel:e.ce_generated_s_rel) with
  | Accepted ->
      Ok
        {
          path = e.ce_path;
          source_sha256 = e.ce_source_sha256;
          generated_sha256 = Some e.ce_generated_sha256;
          outcome = Rec_accepted;
        }
  | Rejected reason ->
      Ok
        {
          path = e.ce_path;
          source_sha256 = e.ce_source_sha256;
          generated_sha256 = Some e.ce_generated_sha256;
          outcome = Rec_rejected reason;
        }
  | Runner_failed msg -> Error msg

let classify_all runner entries =
  let* records =
    List.fold_left
      (fun acc e ->
        let* rs = acc in
        match classify_entry runner e with
        | Ok r -> Ok (r :: rs)
        | Error msg ->
            err Tool_error.Exec (Printf.sprintf "parser invocation failed for %s: %s" e.ce_path msg))
      (Ok []) entries
  in
  Ok (List.rev records)

(* {1 The manifest and summary formats} *)

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

let render_manifest (m : manifest) =
  let b = Buffer.create 4096 in
  Buffer.add_string b (Printf.sprintf "suite:%s\n" m.header.suite);
  Buffer.add_string b (Printf.sprintf "target:%s\n" m.header.target);
  Buffer.add_string b (Printf.sprintf "ccomp-version:%s\n" (Manifest.escape m.header.ccomp_version));
  Buffer.add_string b (Printf.sprintf "ccomp-args:%s\n" (Manifest.escape m.header.ccomp_args));
  Buffer.add_string b (Printf.sprintf "compcert-revision:%s\n" m.header.compcert_revision);
  Buffer.add_string b
    (Printf.sprintf "shared-header:%s\tsha256:%s\n" m.header.shared_header_path
       m.header.shared_header_sha256);
  let sorted =
    List.sort (fun (a : file_record) (b : file_record) -> String.compare a.path b.path) m.files
  in
  List.iter
    (fun (r : file_record) ->
      match (r.outcome, r.generated_sha256) with
      | Rec_accepted, Some g ->
          Buffer.add_string b
            (Printf.sprintf "%s\tsource-sha256:%s\tgenerated-sha256:%s\toutcome:accepted\n" r.path
               r.source_sha256 g)
      | Rec_rejected reason, Some g ->
          Buffer.add_string b
            (Printf.sprintf
               "%s\tsource-sha256:%s\tgenerated-sha256:%s\toutcome:rejected\treason:%s\n" r.path
               r.source_sha256 g (Manifest.escape reason))
      | Rec_compile_failed reason, None ->
          Buffer.add_string b
            (Printf.sprintf "%s\tsource-sha256:%s\toutcome:compile-failed\treason:%s\n" r.path
               r.source_sha256 (Manifest.escape reason))
      | (Rec_accepted | Rec_rejected _), None ->
          invalid_arg
            (Printf.sprintf "render_manifest: %s is accepted/rejected but has no generated-sha256"
               r.path)
      | Rec_compile_failed _, Some _ ->
          invalid_arg
            (Printf.sprintf "render_manifest: %s is compile-failed but carries a generated-sha256"
               r.path))
    sorted;
  Buffer.contents b

(* [extract] picks the reason text this bucket cares about out of one record,
   or [None] if the record belongs to a different bucket - shared by the
   rejected-reason and compile-failed-reason groupings below so they stay
   identically sorted, deduplicated, and counted. *)
let group_reasons (files : file_record list) (extract : file_record -> string option) =
  List.filter_map extract files |> List.sort_uniq String.compare
  |> List.map (fun reason ->
      let count = List.length (List.filter (fun r -> extract r = Some reason) files) in
      (reason, count))

let render_summary (m : manifest) =
  let total = List.length m.files in
  let accepted =
    List.length (List.filter (fun (r : file_record) -> r.outcome = Rec_accepted) m.files)
  in
  let compile_failed =
    List.length
      (List.filter
         (fun (r : file_record) -> match r.outcome with Rec_compile_failed _ -> true | _ -> false)
         m.files)
  in
  let rejected_reasons =
    group_reasons m.files (fun r -> match r.outcome with Rec_rejected s -> Some s | _ -> None)
  in
  let compile_failed_reasons =
    group_reasons m.files (fun r ->
        match r.outcome with Rec_compile_failed s -> Some s | _ -> None)
  in
  let b = Buffer.create 1024 in
  Buffer.add_string b (Printf.sprintf "total:%d\n" total);
  Buffer.add_string b (Printf.sprintf "accepted:%d\n" accepted);
  Buffer.add_string b (Printf.sprintf "rejected:%d\n" (total - accepted - compile_failed));
  (* compile-failed:0 is never rendered - suites that never fail to compile
     (test/c, and every existing published manifest) keep byte-for-byte the
     same summary.txt they always had. *)
  if compile_failed > 0 then
    Buffer.add_string b (Printf.sprintf "compile-failed:%d\n" compile_failed);
  List.iter
    (fun (reason, count) ->
      Buffer.add_string b (Printf.sprintf "reason:%d\t%s\n" count (Manifest.escape reason)))
    rejected_reasons;
  List.iter
    (fun (reason, count) ->
      Buffer.add_string b (Printf.sprintf "compile-reason:%d\t%s\n" count (Manifest.escape reason)))
    compile_failed_reasons;
  Buffer.contents b

(* {2 Parsing} *)

let is_hex64 s =
  String.length s = 64 && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let strip_prefix ~prefix s =
  let n = String.length prefix in
  if String.length s >= n && String.sub s 0 n = prefix then
    Some (String.sub s n (String.length s - n))
  else None

let parse_header_line ~line_no ~prefix text =
  match strip_prefix ~prefix text with
  | Some v -> Ok v
  | None ->
      err Tool_error.Parse
        (Printf.sprintf "manifest line %d: expected it to start with %S" line_no prefix)

let parse_hash_field ~line_no ~field ~prefix text =
  match strip_prefix ~prefix text with
  | None ->
      err Tool_error.Parse (Printf.sprintf "manifest line %d: expected field %S" line_no field)
  | Some h ->
      if is_hex64 h then Ok h
      else
        err Tool_error.Parse
          (Printf.sprintf "manifest line %d: %s is not 64 lowercase hex characters" line_no field)

let parse_file_record ~line_no line =
  match String.split_on_char '\t' line with
  | [ path; source; generated; "outcome:accepted" ] ->
      let* () = Identifier.relative_path path |> Result.map ignore in
      let* source_sha256 =
        parse_hash_field ~line_no ~field:"source-sha256" ~prefix:"source-sha256:" source
      in
      let* generated_sha256 =
        parse_hash_field ~line_no ~field:"generated-sha256" ~prefix:"generated-sha256:" generated
      in
      Ok { path; source_sha256; generated_sha256 = Some generated_sha256; outcome = Rec_accepted }
  | [ path; source; generated; "outcome:rejected"; reason ] -> (
      let* () = Identifier.relative_path path |> Result.map ignore in
      let* source_sha256 =
        parse_hash_field ~line_no ~field:"source-sha256" ~prefix:"source-sha256:" source
      in
      let* generated_sha256 =
        parse_hash_field ~line_no ~field:"generated-sha256" ~prefix:"generated-sha256:" generated
      in
      match strip_prefix ~prefix:"reason:" reason with
      | None ->
          err Tool_error.Parse
            (Printf.sprintf "manifest line %d: expected field \"reason\"" line_no)
      | Some r ->
          let* reason = Manifest.unescape r in
          Ok
            {
              path;
              source_sha256;
              generated_sha256 = Some generated_sha256;
              outcome = Rec_rejected reason;
            })
  | [ path; source; "outcome:compile-failed"; reason ] -> (
      let* () = Identifier.relative_path path |> Result.map ignore in
      let* source_sha256 =
        parse_hash_field ~line_no ~field:"source-sha256" ~prefix:"source-sha256:" source
      in
      match strip_prefix ~prefix:"reason:" reason with
      | None ->
          err Tool_error.Parse
            (Printf.sprintf "manifest line %d: expected field \"reason\"" line_no)
      | Some r ->
          let* reason = Manifest.unescape r in
          Ok { path; source_sha256; generated_sha256 = None; outcome = Rec_compile_failed reason })
  | _ ->
      err Tool_error.Parse
        (Printf.sprintf "manifest line %d: malformed file record %S" line_no line)

let parse_manifest text =
  if text = "" || text.[String.length text - 1] <> '\n' then
    err Tool_error.Parse "manifest is empty or missing a final newline"
  else
    let lines =
      let all = String.split_on_char '\n' text in
      (* text ends in "\n", so split_on_char leaves one trailing "" - drop it. *)
      match List.rev all with
      | "" :: rest -> List.rev rest
      | _ -> all
    in
    match lines with
    | suite_l :: target_l :: version_l :: args_l :: rev_l :: header_l :: file_lines ->
        let* suite = parse_header_line ~line_no:1 ~prefix:"suite:" suite_l in
        let* target = parse_header_line ~line_no:2 ~prefix:"target:" target_l in
        let* ccomp_version_raw = parse_header_line ~line_no:3 ~prefix:"ccomp-version:" version_l in
        let* ccomp_version = Manifest.unescape ccomp_version_raw in
        let* ccomp_args_raw = parse_header_line ~line_no:4 ~prefix:"ccomp-args:" args_l in
        let* ccomp_args = Manifest.unescape ccomp_args_raw in
        let* compcert_revision = parse_header_line ~line_no:5 ~prefix:"compcert-revision:" rev_l in
        let* () =
          if is_hex64 compcert_revision then Ok ()
          else if
            (* git revisions are 40 hex chars, not 64 - this is a distinct
               shape check from the SHA-256 fields below. *)
            String.length compcert_revision = 40
            && String.for_all
                 (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                 compcert_revision
          then Ok ()
          else
            err Tool_error.Parse
              "manifest line 5: compcert-revision is not 40 lowercase hex characters"
        in
        let* header_fields =
          match String.split_on_char '\t' header_l with
          | [ shared; sha ]
            when String.length shared >= 14 && String.sub shared 0 14 = "shared-header:" ->
              Ok (String.sub shared 14 (String.length shared - 14), sha)
          | _ -> err Tool_error.Parse "manifest line 6: malformed shared-header record"
        in
        let shared_header_path, sha_field = header_fields in
        let* shared_header_sha256 =
          parse_hash_field ~line_no:6 ~field:"sha256" ~prefix:"sha256:" sha_field
        in
        let* records =
          List.fold_left
            (fun acc (i, line) ->
              let* rs = acc in
              let* r = parse_file_record ~line_no:(6 + i) line in
              Ok (r :: rs))
            (Ok [])
            (List.mapi (fun i l -> (i + 1, l)) file_lines)
        in
        let records = List.rev records in
        let* () =
          let sorted = List.sort String.compare (List.map (fun r -> r.path) records) in
          let rec dup = function
            | a :: (b :: _ as rest) -> if String.equal a b then Some a else dup rest
            | _ -> None
          in
          match dup sorted with
          | Some p -> err Tool_error.Parse (Printf.sprintf "manifest: duplicate path %s" p)
          | None -> Ok ()
        in
        Ok
          {
            header =
              {
                suite;
                target;
                ccomp_version;
                ccomp_args;
                compcert_revision;
                shared_header_path;
                shared_header_sha256;
              };
            files = records;
          }
    | _ -> err Tool_error.Parse "manifest is missing its 6-line header"

(* {1 The CompCert checkout} *)

type git_probe = {
  status_porcelain : unit -> (string, Tool_error.t) Err.t;
  head : unit -> (string, Tool_error.t) Err.t;
}

let git_in_compcert repo args ~label =
  Tool_process.exec
    (Tool_process.spec ~cwd:(Repo.path repo) ~stdout:Tool_process.Out_capture
       ~stderr:Tool_process.Err_capture ~accepted:Process_status.Zero_only ~label "git"
       ([ "-C"; "modules/CompCert" ] @ args))

let real_git_probe repo =
  {
    status_porcelain =
      (fun () ->
        Result.map
          (fun (r : Tool_process.result) -> Option.value r.stdout ~default:"")
          (git_in_compcert repo [ "status"; "--porcelain" ] ~label:"corpus-classify git status"));
    head =
      (fun () ->
        Result.map
          (fun (r : Tool_process.result) -> String.trim (Option.value r.stdout ~default:""))
          (git_in_compcert repo [ "rev-parse"; "HEAD" ] ~label:"corpus-classify git rev-parse"));
  }

let check_clean_checkout git =
  let* out = git.status_porcelain () in
  if String.trim out = "" then Ok ()
  else err Tool_error.Validate (Printf.sprintf "modules/CompCert checkout is dirty:\n%s" out)

let check_revision_matches git ~expected =
  let* head = git.head () in
  if String.equal head expected then Ok ()
  else
    err Tool_error.Validate
      (Printf.sprintf "compcert-revision %s does not match live HEAD %s" expected head)

(* {1 Discovering and compiling the corpus} *)

let discover_c_files repo =
  let dir = Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "c") in
  match Sys.readdir (Fpath.to_string dir) with
  | exception Sys_error m -> err ~path:dir Tool_error.Traverse m
  | entries ->
      Ok
        (entries |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".c")
        |> List.sort String.compare)

let compile_entry repo ~compiler ~args ~corpus_work_root ~(target : Target.t) file =
  let target_s = Target.to_string target in
  let stem = Filename.remove_extension (Filename.basename file) in
  let* dir = Tool_workspace.child_of_recreatable corpus_work_root [ "c"; target_s; stem ] in
  let* () = Tool_workspace.ensure dir in
  let out_rel = ".corpus-work/c/" ^ target_s ^ "/" ^ stem ^ "/output.s" in
  let source_rel = "modules/CompCert/test/c/" ^ file in
  let* () =
    Ccomp.compile_s ~compiler ~cwd:(Repo.path repo) ~args ~out_rel ~source_rel ~case:stem ~target
  in
  let* source_sha256 = Tool_fs.sha256 Fpath.(Repo.path repo // v source_rel) in
  let* generated_sha256 = Tool_fs.sha256 Fpath.(Repo.path repo // v out_rel) in
  Ok
    {
      ce_path = source_rel;
      ce_source_sha256 = source_sha256;
      ce_generated_s_rel = out_rel;
      ce_generated_sha256 = generated_sha256;
    }

(* {1 Other CompCert test suites}

   [suite_spec] generalizes the [test/c/] path above to CompCert's other
   static, committed-source test suites (currently [regression] and
   [compression] - [abi]'s sources are generator-produced, some with an
   explicit random seed, and so do not fit this "hash a committed .c file"
   corpus model at all; see asm/docs/corpus.md's Follow-ups). It is
   deliberately NOT used by [discover_c_files]/[compile_entry]/[classify_c]
   above, which {!Corpus_assemble_cmd} also calls directly and which stay
   exactly as they were before this suite generalized - only new suites go
   through this path. *)

type suite_spec = {
  suite_tag : string;  (** The manifest's [suite:] value, e.g. ["regression"]. *)
  test_subdir : string;
      (** The directory name under [modules/CompCert/test/], e.g. ["regression"]. *)
  extra_ccomp_args : string list;
      (** Appended after the target's own [ccomp_args] - e.g. [test/regression]'s
          own Makefile passes [-fall] to accept the struct-passing and
          unstructured-switch constructs several of its files use; this
          project's own parser is not involved in that decision, ccomp is. *)
  dest : Repo.t -> Target.t -> Fpath.t;
}

let discover_suite_files repo (spec : suite_spec) =
  let dir = Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / spec.test_subdir) in
  match Sys.readdir (Fpath.to_string dir) with
  | exception Sys_error m -> err ~path:dir Tool_error.Traverse m
  | entries ->
      Ok
        (entries |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".c")
        |> List.sort String.compare)

(* Unlike [compile_entry] above (used only by [test/c/], where every file is
   known to compile), a bigger, less curated suite can contain a file that
   never compiles at all for this target - CompCert's own
   [test/regression/Makefile] documents one such case (funct1.c, its own
   FAILURES list) and several files are legitimately for a different
   architecture (builtins-arm.c, builtins-aarch64.c, ...). That is real
   evidence for the "decide whether a recurring reason warrants support"
   follow-up (asm/docs/corpus.md), not a tooling failure, so it becomes an
   [outcome:compile-failed] record rather than aborting the whole run the way
   a [ccomp] spawn failure still does. *)
type prepared = Ready of compiled_entry | Precompiled of file_record

let compile_or_record repo ~compiler ~args ~corpus_work_root ~(spec : suite_spec)
    ~(target : Target.t) file =
  let target_s = Target.to_string target in
  let stem = Filename.remove_extension (Filename.basename file) in
  let* dir =
    Tool_workspace.child_of_recreatable corpus_work_root [ spec.suite_tag; target_s; stem ]
  in
  let* () = Tool_workspace.ensure dir in
  let out_rel = ".corpus-work/" ^ spec.suite_tag ^ "/" ^ target_s ^ "/" ^ stem ^ "/output.s" in
  let source_rel = "modules/CompCert/test/" ^ spec.test_subdir ^ "/" ^ file in
  let* source_sha256 = Tool_fs.sha256 Fpath.(Repo.path repo // v source_rel) in
  match
    Tool_process.exec
      (Tool_process.spec ~cwd:(Repo.path repo) ~stdout:Tool_process.Out_null
         ~stderr:Tool_process.Err_capture ~parsed_output:true ~accepted:Process_status.Any_exit
         ~label:"corpus-classify-compile" (Fpath.to_string compiler)
         (("-S" :: args) @ [ "-o"; out_rel; source_rel ]))
  with
  | Ok { Tool_process.status = Process_status.Exited 0; _ } ->
      let* generated_sha256 = Tool_fs.sha256 Fpath.(Repo.path repo // v out_rel) in
      Ok
        (Ready
           {
             ce_path = source_rel;
             ce_source_sha256 = source_sha256;
             ce_generated_s_rel = out_rel;
             ce_generated_sha256 = generated_sha256;
           })
  | Ok { Tool_process.status = Process_status.Exited code; stderr; _ } ->
      let reason =
        match first_nonempty_line (Option.value stderr ~default:"") with
        | Some l -> l
        | None -> Printf.sprintf "(no diagnostic; exit %d)" code
      in
      Ok
        (Precompiled
           {
             path = source_rel;
             source_sha256;
             generated_sha256 = None;
             outcome = Rec_compile_failed reason;
           })
  | Ok { Tool_process.status = Process_status.Signaled _ | Process_status.Timed_out; _ } ->
      (* Unreachable for the same reason real_runner's is: accepted:Any_exit
         accepts every Exited _ and nothing else. *)
      err Tool_error.Exec (Printf.sprintf "ccomp exited abnormally compiling %s" source_rel)
  | Error e -> Error e

let prepare_all repo ~compiler ~args ~corpus_work_root ~spec ~target files =
  let* ps =
    List.fold_left
      (fun acc f ->
        let* ps = acc in
        let* p = compile_or_record repo ~compiler ~args ~corpus_work_root ~spec ~target f in
        Ok (p :: ps))
      (Ok []) files
  in
  Ok (List.rev ps)

let classify_prepared runner prepared =
  let* rs =
    List.fold_left
      (fun acc p ->
        let* rs = acc in
        match p with
        | Precompiled r -> Ok (r :: rs)
        | Ready e -> (
            match classify_entry runner e with
            | Ok r -> Ok (r :: rs)
            | Error msg ->
                err Tool_error.Exec
                  (Printf.sprintf "parser invocation failed for %s: %s" e.ce_path msg)))
      (Ok []) prepared
  in
  Ok (List.rev rs)

(* {1 Publication} *)

let stage_one final text =
  Tool_fs.with_staging ~final ~install_suffix:".new" ~auxiliary_suffixes:[]
    (fun ~install:_ ~auxiliary:_ ~write_install ~write_auxiliary:_ ~commit ->
      let* () = write_install text in
      commit ())

type commit_step = final:Fpath.t -> text:string -> (unit, Tool_error.t) Err.t

type restore_step =
  manifest_path:Fpath.t -> backup:Fpath.t -> prior_exists:bool -> (unit, Tool_error.t) Err.t

let default_commit : commit_step = fun ~final ~text -> stage_one final text

let default_restore : restore_step =
 fun ~manifest_path ~backup ~prior_exists ->
  if prior_exists then Tool_fs.copy ~src:backup ~dst:manifest_path
  else
    try
      Sys.remove (Fpath.to_string manifest_path);
      Ok ()
    with Sys_error m -> err ~path:manifest_path Tool_error.Write_file m

let publish_with repo ~(target : Target.t) ?dest_dir (m : manifest) ~commit_manifest ~commit_summary
    ~restore =
  let dest_dir = match dest_dir with Some d -> d | None -> Repo.corpus_c repo target in
  (* After all compilation/classification has already succeeded, and
     idempotent on every later run - this is a brand-new corpus and
     Tool_fs.write never creates a missing parent directory. *)
  let* () = Tool_fs.mkdir_p dest_dir in
  let manifest_path = Fpath.(dest_dir / "manifest.txt") in
  let summary_path = Fpath.(dest_dir / "summary.txt") in
  let manifest_text = render_manifest m in
  let summary_text = render_summary m in
  let prior_exists = Sys.file_exists (Fpath.to_string manifest_path) in
  Tool_workspace.with_scratch ~label:"corpus-publish" (fun scratch ->
      let backup = Fpath.(scratch / "manifest.txt.bak") in
      let* () = if prior_exists then Tool_fs.copy ~src:manifest_path ~dst:backup else Ok () in
      let* () = commit_manifest ~final:manifest_path ~text:manifest_text in
      match commit_summary ~final:summary_path ~text:summary_text with
      | Ok () -> Ok ()
      | Error summary_err -> (
          match restore ~manifest_path ~backup ~prior_exists with
          | Ok () -> Error summary_err
          | Error restore_err ->
              err Tool_error.Write_file
                (Printf.sprintf
                   "publish failed and the rollback also failed - summary install: %s; rollback: \
                    %s; retained: %s, %s.new%s"
                   (Err.Error.kind summary_err).Tool_error.detail
                   (Err.Error.kind restore_err).Tool_error.detail (Fpath.to_string manifest_path)
                   (Fpath.to_string summary_path)
                   (if prior_exists then ", " ^ Fpath.to_string backup else ""))))

let publish repo ~target (m : manifest) =
  publish_with repo ~target m ~commit_manifest:default_commit ~commit_summary:default_commit
    ~restore:default_restore

let publish_suite (spec : suite_spec) repo ~target (m : manifest) =
  publish_with repo ~target ~dest_dir:(spec.dest repo target) m ~commit_manifest:default_commit
    ~commit_summary:default_commit ~restore:default_restore

(* {1 classify-c} *)

let classify_c_core repo ~git ~runner ~compiler ~(target : Target.t) =
  let* () = check_clean_checkout git in
  let* files = discover_c_files repo in
  if files = [] then err Tool_error.Validate "modules/CompCert/test/c contains no .c files"
  else
    let* corpus_work_root = Tool_workspace.corpus_work repo in
    let* () = Tool_workspace.recreate_root corpus_work_root in
    let args = (Target.config target).Target.ccomp_args in
    let* entries =
      List.fold_left
        (fun acc f ->
          let* es = acc in
          let* e = compile_entry repo ~compiler ~args ~corpus_work_root ~target f in
          Ok (e :: es))
        (Ok []) files
    in
    let entries = List.rev entries in
    let* records = classify_all runner entries in
    let* ccomp_version = Ccomp.version compiler in
    let* compcert_revision = git.head () in
    let shared_header_path = "test/endian.h" in
    let* shared_header_sha256 =
      Tool_fs.sha256 Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
    in
    let header =
      {
        suite = "c";
        target = Target.to_string target;
        ccomp_version;
        ccomp_args = String.concat " " args;
        compcert_revision;
        shared_header_path;
        shared_header_sha256;
      }
    in
    let manifest = { header; files = records } in
    let* () = publish repo ~target manifest in
    let accepted =
      List.length (List.filter (fun (r : file_record) -> r.outcome = Rec_accepted) records)
    in
    Ok
      (Printf.sprintf "corpus classify-c-%s: %d accepted, %d rejected (of %d)"
         (Target.to_string target) accepted
         (List.length records - accepted)
         (List.length records))

let fixture_work_root repo =
  Result.map Tool_workspace.read_path (Tool_workspace.fixture_work repo ~env:Sys.getenv_opt)

let classify_c repo (target : Target.t) =
  let step =
    let* work_root = fixture_work_root repo in
    let* () = Ccomp.require_all [ target ] ~work_root in
    let compiler = Ccomp.path target ~work_root in
    classify_c_core repo ~git:(real_git_probe repo) ~runner:(real_runner repo target) ~compiler
      ~target
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

(* {1 classify-regression, classify-compression} *)

let regression_spec : suite_spec =
  {
    suite_tag = "regression";
    test_subdir = "regression";
    extra_ccomp_args = [ "-fall" ];
    dest = Repo.corpus_regression;
  }

let compression_spec : suite_spec =
  {
    suite_tag = "compression";
    test_subdir = "compression";
    extra_ccomp_args = [];
    dest = Repo.corpus_compression;
  }

let classify_suite_core repo ~git ~runner ~compiler ~(spec : suite_spec) ~(target : Target.t) =
  let* () = check_clean_checkout git in
  let* files = discover_suite_files repo spec in
  if files = [] then
    err Tool_error.Validate
      (Printf.sprintf "modules/CompCert/test/%s contains no .c files" spec.test_subdir)
  else
    let* corpus_work_root = Tool_workspace.corpus_work repo in
    let* () = Tool_workspace.recreate_root corpus_work_root in
    let args = (Target.config target).Target.ccomp_args @ spec.extra_ccomp_args in
    let* prepared = prepare_all repo ~compiler ~args ~corpus_work_root ~spec ~target files in
    let* records = classify_prepared runner prepared in
    let* ccomp_version = Ccomp.version compiler in
    let* compcert_revision = git.head () in
    let shared_header_path = "test/endian.h" in
    let* shared_header_sha256 =
      Tool_fs.sha256 Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
    in
    let header =
      {
        suite = spec.suite_tag;
        target = Target.to_string target;
        ccomp_version;
        ccomp_args = String.concat " " args;
        compcert_revision;
        shared_header_path;
        shared_header_sha256;
      }
    in
    let manifest = { header; files = records } in
    let* () = publish_suite spec repo ~target manifest in
    let accepted =
      List.length (List.filter (fun (r : file_record) -> r.outcome = Rec_accepted) records)
    in
    let compile_failed =
      List.length
        (List.filter
           (fun (r : file_record) ->
             match r.outcome with Rec_compile_failed _ -> true | _ -> false)
           records)
    in
    Ok
      (Printf.sprintf "corpus classify-%s-%s: %d accepted, %d rejected, %d compile-failed (of %d)"
         spec.suite_tag (Target.to_string target) accepted
         (List.length records - accepted - compile_failed)
         compile_failed (List.length records))

let classify_suite (spec : suite_spec) repo (target : Target.t) =
  let step =
    let* work_root = fixture_work_root repo in
    let* () = Ccomp.require_all [ target ] ~work_root in
    let compiler = Ccomp.path target ~work_root in
    classify_suite_core repo ~git:(real_git_probe repo) ~runner:(real_runner repo target) ~compiler
      ~spec ~target
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

let classify_regression repo (target : Target.t) = classify_suite regression_spec repo target
let classify_compression repo (target : Target.t) = classify_suite compression_spec repo target

(* {1 corpus check} *)

let check_with repo ~git (target : Target.t) =
  let target_s = Target.to_string target in
  let dest_dir = Repo.corpus_c repo target in
  let manifest_path = Fpath.(dest_dir / "manifest.txt") in
  let summary_path = Fpath.(dest_dir / "summary.txt") in
  let step =
    if not (Sys.file_exists (Fpath.to_string manifest_path)) then
      err ~path:manifest_path Tool_error.Read_file
        (Printf.sprintf "no manifest at %s - run 'make asm-corpus-classify-c-%s' first"
           (Fpath.to_string manifest_path) target_s)
    else
      let* manifest_text = Tool_fs.read manifest_path in
      let* m = parse_manifest manifest_text in
      let* () =
        if String.equal m.header.suite "c" then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest suite is %S, expected \"c\"" m.header.suite)
      in
      let* () =
        if String.equal m.header.target target_s then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest target is %S, expected %S" m.header.target target_s)
      in
      let* () =
        if String.equal m.header.shared_header_path "test/endian.h" then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest shared-header is %S, expected \"test/endian.h\""
               m.header.shared_header_path)
      in
      let* () =
        if String.equal (render_manifest m) manifest_text then Ok ()
        else
          err ~path:manifest_path Tool_error.Validate
            "manifest.txt is not in canonical form (reordered, reformatted, or hand-edited)"
      in
      let* present = discover_c_files repo in
      let expected_paths =
        List.sort String.compare (List.map (fun f -> "modules/CompCert/test/c/" ^ f) present)
      in
      let manifest_paths =
        List.sort String.compare (List.map (fun (r : file_record) -> r.path) m.files)
      in
      let* () =
        if expected_paths = manifest_paths then Ok ()
        else
          err Tool_error.Validate
            "manifest.txt does not list exactly the files under modules/CompCert/test/c"
      in
      let* () = check_clean_checkout git in
      let* () = check_revision_matches git ~expected:m.header.compcert_revision in
      let* () =
        List.fold_left
          (fun acc (r : file_record) ->
            let* () = acc in
            let src = Fpath.(Repo.path repo // v r.path) in
            let* h = Tool_fs.sha256 src in
            if String.equal h r.source_sha256 then Ok ()
            else
              err ~path:src Tool_error.Hash (Printf.sprintf "source-sha256 mismatch for %s" r.path))
          (Ok ()) m.files
      in
      let* header_sha256 =
        Tool_fs.sha256 Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
      in
      let* () =
        if String.equal header_sha256 m.header.shared_header_sha256 then Ok ()
        else err Tool_error.Hash "shared-header sha256 mismatch for test/endian.h"
      in
      let* summary_text = Tool_fs.read summary_path in
      let* () =
        if String.equal (render_summary m) summary_text then Ok ()
        else
          err ~path:summary_path Tool_error.Validate
            "summary.txt does not match the manifest (stale or hand-edited)"
      in
      let accepted =
        List.length (List.filter (fun (r : file_record) -> r.outcome = Rec_accepted) m.files)
      in
      Ok
        (Printf.sprintf "corpus check-%s: %d files match (%d accepted, %d rejected)" target_s
           (List.length m.files) accepted
           (List.length m.files - accepted))
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

(* Every target that has a published manifest so far - not a fixed list of
   six, since a target's manifest lands only once its classify-c has actually
   been run for real (corpus.md: "checked-in provenance manifests where CI
   cannot regenerate them"). A target with no manifest yet is silently
   skipped here rather than failing check - that is what lets classify-c-arm
   etc. land one target at a time without check breaking for the rest. *)
let published_targets repo =
  List.filter
    (fun target ->
      Sys.file_exists (Fpath.to_string Fpath.(Repo.corpus_c repo target / "manifest.txt")))
    Target.all

let check repo =
  let git = real_git_probe repo in
  match published_targets repo with
  | [] ->
      Command.of_error
        (Err.Error.make ~pos:__POS__ ~pp_error:Tool_error.pp
           (Tool_error.v Tool_error.Read_file
              "no corpus/c manifest published yet for any target - run a 'corpus \
               classify-c-<target>' first"))
  | targets -> Command.accumulate targets ~f:(fun target -> check_with repo ~git target)

(* {1 check-regression, check-compression}

   {!check_with}'s same eight-step verification (asm/docs/corpus.md), against
   a [suite_spec] instead of the hard-coded [test/c/] literals. *)

let check_suite_with repo ~git (spec : suite_spec) (target : Target.t) =
  let target_s = Target.to_string target in
  let dest_dir = spec.dest repo target in
  let manifest_path = Fpath.(dest_dir / "manifest.txt") in
  let summary_path = Fpath.(dest_dir / "summary.txt") in
  let step =
    if not (Sys.file_exists (Fpath.to_string manifest_path)) then
      err ~path:manifest_path Tool_error.Read_file
        (Printf.sprintf "no manifest at %s - run 'make asm-corpus-classify-%s-%s' first"
           (Fpath.to_string manifest_path) spec.suite_tag target_s)
    else
      let* manifest_text = Tool_fs.read manifest_path in
      let* m = parse_manifest manifest_text in
      let* () =
        if String.equal m.header.suite spec.suite_tag then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest suite is %S, expected %S" m.header.suite spec.suite_tag)
      in
      let* () =
        if String.equal m.header.target target_s then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest target is %S, expected %S" m.header.target target_s)
      in
      let* () =
        if String.equal m.header.shared_header_path "test/endian.h" then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest shared-header is %S, expected \"test/endian.h\""
               m.header.shared_header_path)
      in
      let* () =
        if String.equal (render_manifest m) manifest_text then Ok ()
        else
          err ~path:manifest_path Tool_error.Validate
            "manifest.txt is not in canonical form (reordered, reformatted, or hand-edited)"
      in
      let* present = discover_suite_files repo spec in
      let expected_paths =
        List.sort String.compare
          (List.map (fun f -> "modules/CompCert/test/" ^ spec.test_subdir ^ "/" ^ f) present)
      in
      let manifest_paths =
        List.sort String.compare (List.map (fun (r : file_record) -> r.path) m.files)
      in
      let* () =
        if expected_paths = manifest_paths then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf
               "manifest.txt does not list exactly the files under modules/CompCert/test/%s"
               spec.test_subdir)
      in
      let* () = check_clean_checkout git in
      let* () = check_revision_matches git ~expected:m.header.compcert_revision in
      let* () =
        List.fold_left
          (fun acc (r : file_record) ->
            let* () = acc in
            let src = Fpath.(Repo.path repo // v r.path) in
            let* h = Tool_fs.sha256 src in
            if String.equal h r.source_sha256 then Ok ()
            else
              err ~path:src Tool_error.Hash (Printf.sprintf "source-sha256 mismatch for %s" r.path))
          (Ok ()) m.files
      in
      let* header_sha256 =
        Tool_fs.sha256 Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
      in
      let* () =
        if String.equal header_sha256 m.header.shared_header_sha256 then Ok ()
        else err Tool_error.Hash "shared-header sha256 mismatch for test/endian.h"
      in
      let* summary_text = Tool_fs.read summary_path in
      let* () =
        if String.equal (render_summary m) summary_text then Ok ()
        else
          err ~path:summary_path Tool_error.Validate
            "summary.txt does not match the manifest (stale or hand-edited)"
      in
      let accepted =
        List.length (List.filter (fun (r : file_record) -> r.outcome = Rec_accepted) m.files)
      in
      let compile_failed =
        List.length
          (List.filter
             (fun (r : file_record) ->
               match r.outcome with Rec_compile_failed _ -> true | _ -> false)
             m.files)
      in
      Ok
        (Printf.sprintf
           "corpus check-%s-%s: %d files match (%d accepted, %d rejected, %d compile-failed)"
           spec.suite_tag target_s (List.length m.files) accepted
           (List.length m.files - accepted - compile_failed)
           compile_failed)
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

let published_targets_for (spec : suite_spec) repo =
  List.filter
    (fun target -> Sys.file_exists (Fpath.to_string Fpath.(spec.dest repo target / "manifest.txt")))
    Target.all

let check_suite (spec : suite_spec) repo =
  let git = real_git_probe repo in
  match published_targets_for spec repo with
  | [] ->
      Command.of_error
        (Err.Error.make ~pos:__POS__ ~pp_error:Tool_error.pp
           (Tool_error.v Tool_error.Read_file
              (Printf.sprintf
                 "no corpus/%s manifest published yet for any target - run a 'corpus \
                  classify-%s-<target>' first"
                 spec.suite_tag spec.suite_tag)))
  | targets -> Command.accumulate targets ~f:(fun target -> check_suite_with repo ~git spec target)

let check_regression repo = check_suite regression_spec repo
let check_compression repo = check_suite compression_spec repo
