module CC = Corpus_classify_cmd

let ( let* ) = Result.bind

let err ?path op detail =
  Err.fail ~pos:__POS__ ~pp_error:Tool_error.pp (Tool_error.v ?path op detail)

(* {1 The assembler-runner seam} *)

type raw_outcome = Exited of { code : int; stderr : string } | Runner_failed of string
type runner = generated_s_rel:string -> raw_outcome

type assemble_outcome =
  | Assembled
  | Blocked of { undefined_count : int; reasons : string }
  | Rejected of string
  | Runner_failed of string

let first_nonempty_line s =
  String.split_on_char '\n' s |> List.map String.trim |> List.find_opt (fun l -> l <> "")

(* asm/lib/foundation/diagnostic.ml's [pp_header] renders every diagnostic as
   "<origin>: error[<code>]: <message>" on one line, with no breakable space
   (asm/docs/errors.md's byte-for-byte rendering discipline) - so every
   diagnostic's code and message live on exactly one stderr line, and a plain
   substring search over each line is enough; no diagnostic here is ever
   Warning or Note severity (image.ml's [diag] always builds an Error). *)
let find_from hay needle from =
  let n = String.length needle and m = String.length hay in
  let rec go i =
    if i + n > m then None else if String.sub hay i n = needle then Some i else go (i + 1)
  in
  go from

let diagnostic_of_line line =
  match find_from line ": error[" 0 with
  | None -> None
  | Some i -> (
      let code_start = i + String.length ": error[" in
      match find_from line "]: " code_start with
      | None -> None
      | Some j -> Some (String.sub line code_start (j - code_start), String.trim line))

let normalize = function
  | Exited { code = 0; _ } -> Assembled
  | Exited { code; stderr } -> (
      match String.split_on_char '\n' stderr |> List.filter_map diagnostic_of_line with
      | [] -> (
          match first_nonempty_line stderr with
          | Some l -> Rejected l
          | None -> Rejected (Printf.sprintf "(no diagnostic; exit %d)" code))
      | diags -> (
          if List.for_all (fun (c, _) -> String.equal c "image.undefined") diags then
            let reasons = List.sort_uniq String.compare (List.map snd diags) in
            Blocked { undefined_count = List.length diags; reasons = String.concat "; " reasons }
          else
            match List.find_opt (fun (c, _) -> not (String.equal c "image.undefined")) diags with
            | Some (_, l) -> Rejected l
            | None -> Rejected (snd (List.hd diags))))
  | Runner_failed msg -> Runner_failed msg

let asm_exe repo = Fpath.(Repo.path repo / "asm" / "_build" / "default" / "tool" / "asm.exe")

(* No --dump flag: the default path all the way to plan_image (asm/tool/asm.ml),
   exactly the "actually assembling this corpus" check asm/docs/corpus.md
   describes - not classify-c's --dump-source-ast parse-only stop. *)
let real_runner repo (target : Target.t) : runner =
 fun ~generated_s_rel ->
  match
    Tool_process.exec
      (Tool_process.spec ~cwd:(Repo.path repo) ~stdout:Tool_process.Out_null
         ~stderr:Tool_process.Err_capture ~parsed_output:true ~accepted:Process_status.Any_exit
         ~label:"corpus-assemble-plan"
         (Fpath.to_string (asm_exe repo))
         [ "--target"; Target.to_string target; generated_s_rel ])
  with
  | Ok { Tool_process.status = Process_status.Exited code; stderr; _ } ->
      Exited { code; stderr = Option.value stderr ~default:"" }
  | Ok { Tool_process.status = Process_status.Signaled _ | Process_status.Timed_out; _ } ->
      (* Unreachable: accepted:Any_exit accepts every Exited _ and nothing
         else, so exec would have returned Error for a signal death or a
         timeout instead. *)
      Runner_failed "assembler exited abnormally"
  | Error e -> Runner_failed (Format.asprintf "%a" (Err.Error.pp Tool_error.pp) e)

(* {1 Classifying compiled entries} *)

type outcome =
  | Rec_accepted
  | Rec_blocked of { undefined_count : int; reasons : string }
  | Rec_rejected of string

type file_record = {
  path : string;
  source_sha256 : string;
  generated_sha256 : string;
  outcome : outcome;
}

let classify_entry runner (e : CC.compiled_entry) =
  let path = e.CC.ce_path in
  let source_sha256 = e.CC.ce_source_sha256 in
  let generated_sha256 = e.CC.ce_generated_sha256 in
  match normalize (runner ~generated_s_rel:e.CC.ce_generated_s_rel) with
  | Assembled -> Ok { path; source_sha256; generated_sha256; outcome = Rec_accepted }
  | Blocked { undefined_count; reasons } ->
      Ok
        {
          path;
          source_sha256;
          generated_sha256;
          outcome = Rec_blocked { undefined_count; reasons };
        }
  | Rejected reason -> Ok { path; source_sha256; generated_sha256; outcome = Rec_rejected reason }
  | Runner_failed msg -> Error msg

let classify_all runner entries =
  let* records =
    List.fold_left
      (fun acc e ->
        let* rs = acc in
        match classify_entry runner e with
        | Ok r -> Ok (r :: rs)
        | Error msg ->
            err Tool_error.Exec
              (Printf.sprintf "assembler invocation failed for %s: %s" e.CC.ce_path msg))
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
      match r.outcome with
      | Rec_accepted ->
          Buffer.add_string b
            (Printf.sprintf "%s\tsource-sha256:%s\tgenerated-sha256:%s\toutcome:accepted\n" r.path
               r.source_sha256 r.generated_sha256)
      | Rec_blocked { undefined_count; reasons } ->
          Buffer.add_string b
            (Printf.sprintf
               "%s\tsource-sha256:%s\tgenerated-sha256:%s\toutcome:blocked\tundefined:%d\treasons:%s\n"
               r.path r.source_sha256 r.generated_sha256 undefined_count (Manifest.escape reasons))
      | Rec_rejected reason ->
          Buffer.add_string b
            (Printf.sprintf
               "%s\tsource-sha256:%s\tgenerated-sha256:%s\toutcome:rejected\treason:%s\n" r.path
               r.source_sha256 r.generated_sha256 (Manifest.escape reason)))
    sorted;
  Buffer.contents b

let render_summary (m : manifest) =
  let total = List.length m.files in
  let count pred = List.length (List.filter pred m.files) in
  let accepted = count (fun (r : file_record) -> r.outcome = Rec_accepted) in
  let blocked =
    count (fun (r : file_record) -> match r.outcome with Rec_blocked _ -> true | _ -> false)
  in
  let rejected = total - accepted - blocked in
  let reasons =
    List.filter_map
      (fun (r : file_record) ->
        match r.outcome with Rec_rejected s -> Some s | Rec_accepted | Rec_blocked _ -> None)
      m.files
    |> List.sort_uniq String.compare
    |> List.map (fun reason ->
        let c =
          List.length
            (List.filter
               (fun (r : file_record) ->
                 match r.outcome with
                 | Rec_rejected s -> String.equal s reason
                 | Rec_accepted | Rec_blocked _ -> false)
               m.files)
        in
        (reason, c))
  in
  let b = Buffer.create 1024 in
  Buffer.add_string b (Printf.sprintf "total:%d\n" total);
  Buffer.add_string b (Printf.sprintf "accepted:%d\n" accepted);
  Buffer.add_string b (Printf.sprintf "blocked:%d\n" blocked);
  Buffer.add_string b (Printf.sprintf "rejected:%d\n" rejected);
  List.iter
    (fun (reason, count) ->
      Buffer.add_string b (Printf.sprintf "reason:%d\t%s\n" count (Manifest.escape reason)))
    reasons;
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
      Ok { path; source_sha256; generated_sha256; outcome = Rec_accepted }
  | [ path; source; generated; "outcome:blocked"; undefined_field; reasons_field ] -> (
      let* () = Identifier.relative_path path |> Result.map ignore in
      let* source_sha256 =
        parse_hash_field ~line_no ~field:"source-sha256" ~prefix:"source-sha256:" source
      in
      let* generated_sha256 =
        parse_hash_field ~line_no ~field:"generated-sha256" ~prefix:"generated-sha256:" generated
      in
      let* undefined_count =
        match strip_prefix ~prefix:"undefined:" undefined_field with
        | None ->
            err Tool_error.Parse
              (Printf.sprintf "manifest line %d: expected field \"undefined\"" line_no)
        | Some n_s -> (
            match int_of_string_opt n_s with
            | Some n when n > 0 -> Ok n
            | _ ->
                err Tool_error.Parse
                  (Printf.sprintf "manifest line %d: undefined count %S is not a positive integer"
                     line_no n_s))
      in
      match strip_prefix ~prefix:"reasons:" reasons_field with
      | None ->
          err Tool_error.Parse
            (Printf.sprintf "manifest line %d: expected field \"reasons\"" line_no)
      | Some r ->
          let* reasons = Manifest.unescape r in
          Ok
            {
              path;
              source_sha256;
              generated_sha256;
              outcome = Rec_blocked { undefined_count; reasons };
            })
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
          Ok { path; source_sha256; generated_sha256; outcome = Rec_rejected reason })
  | _ ->
      err Tool_error.Parse
        (Printf.sprintf "manifest line %d: malformed file record %S" line_no line)

let parse_manifest text =
  if text = "" || text.[String.length text - 1] <> '\n' then
    err Tool_error.Parse "manifest is empty or missing a final newline"
  else
    let lines =
      let all = String.split_on_char '\n' text in
      match List.rev all with "" :: rest -> List.rev rest | _ -> all
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

let publish_with repo ~(target : Target.t) (m : manifest) ~commit_manifest ~commit_summary ~restore
    =
  let dest_dir = Repo.corpus_c_assemble repo target in
  let* () = Tool_fs.mkdir_p dest_dir in
  let manifest_path = Fpath.(dest_dir / "manifest.txt") in
  let summary_path = Fpath.(dest_dir / "summary.txt") in
  let manifest_text = render_manifest m in
  let summary_text = render_summary m in
  let prior_exists = Sys.file_exists (Fpath.to_string manifest_path) in
  Tool_workspace.with_scratch ~label:"corpus-assemble-publish" (fun scratch ->
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

(* {1 assemble-c} *)

let assemble_c_core repo ~git ~runner ~compiler ~(target : Target.t) =
  let* () = CC.check_clean_checkout git in
  let* files = CC.discover_c_files repo in
  if files = [] then err Tool_error.Validate "modules/CompCert/test/c contains no .c files"
  else
    let* corpus_work_root = Tool_workspace.corpus_work repo in
    let* () = Tool_workspace.recreate_root corpus_work_root in
    let args = (Target.config target).Target.ccomp_args in
    let* entries =
      List.fold_left
        (fun acc f ->
          let* es = acc in
          let* e = CC.compile_entry repo ~compiler ~args ~corpus_work_root ~target f in
          Ok (e :: es))
        (Ok []) files
    in
    let entries = List.rev entries in
    let* records = classify_all runner entries in
    let* ccomp_version = Ccomp.version compiler in
    let* compcert_revision = git.CC.head () in
    let shared_header_path = "test/endian.h" in
    let* shared_header_sha256 =
      Tool_fs.sha256 Fpath.(Repo.path repo / "modules" / "CompCert" / "test" / "endian.h")
    in
    let header =
      {
        suite = "c-assemble";
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
    let blocked =
      List.length
        (List.filter
           (fun (r : file_record) -> match r.outcome with Rec_blocked _ -> true | _ -> false)
           records)
    in
    Ok
      (Printf.sprintf "corpus assemble-c-%s: %d accepted, %d blocked, %d rejected (of %d)"
         (Target.to_string target) accepted blocked
         (List.length records - accepted - blocked)
         (List.length records))

let fixture_work_root repo =
  Result.map Tool_workspace.read_path (Tool_workspace.fixture_work repo ~env:Sys.getenv_opt)

let assemble_c repo (target : Target.t) =
  let step =
    let* work_root = fixture_work_root repo in
    let* () = Ccomp.require_all [ target ] ~work_root in
    let compiler = Ccomp.path target ~work_root in
    assemble_c_core repo ~git:(CC.real_git_probe repo) ~runner:(real_runner repo target) ~compiler
      ~target
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

(* {1 corpus check-assemble} *)

let check_with repo ~git (target : Target.t) =
  let target_s = Target.to_string target in
  let dest_dir = Repo.corpus_c_assemble repo target in
  let manifest_path = Fpath.(dest_dir / "manifest.txt") in
  let summary_path = Fpath.(dest_dir / "summary.txt") in
  let step =
    if not (Sys.file_exists (Fpath.to_string manifest_path)) then
      err ~path:manifest_path Tool_error.Read_file
        (Printf.sprintf "no manifest at %s - run 'make asm-corpus-assemble-c-%s' first"
           (Fpath.to_string manifest_path) target_s)
    else
      let* manifest_text = Tool_fs.read manifest_path in
      let* m = parse_manifest manifest_text in
      let* () =
        if String.equal m.header.suite "c-assemble" then Ok ()
        else
          err Tool_error.Validate
            (Printf.sprintf "manifest suite is %S, expected \"c-assemble\"" m.header.suite)
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
      let* present = CC.discover_c_files repo in
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
      let* () = CC.check_clean_checkout git in
      let* () = CC.check_revision_matches git ~expected:m.header.compcert_revision in
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
      let blocked =
        List.length
          (List.filter
             (fun (r : file_record) -> match r.outcome with Rec_blocked _ -> true | _ -> false)
             m.files)
      in
      Ok
        (Printf.sprintf
           "corpus check-assemble-%s: %d files match (%d accepted, %d blocked, %d rejected)"
           target_s (List.length m.files) accepted blocked
           (List.length m.files - accepted - blocked))
  in
  match step with Error e -> Command.of_error e | Ok line -> Command.ok [ Diagnostic.stdout line ]

let published_targets repo =
  List.filter
    (fun target ->
      Sys.file_exists (Fpath.to_string Fpath.(Repo.corpus_c_assemble repo target / "manifest.txt")))
    Target.all

let check repo =
  let git = CC.real_git_probe repo in
  match published_targets repo with
  | [] ->
      Command.of_error
        (Err.Error.make ~pos:__POS__ ~pp_error:Tool_error.pp
           (Tool_error.v Tool_error.Read_file
              "no corpus/c-assemble manifest published yet for any target - run a 'corpus \
               assemble-c-<target>' first"))
  | targets -> Command.accumulate targets ~f:(fun target -> check_with repo ~git target)
