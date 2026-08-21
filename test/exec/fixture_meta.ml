(* M4 (.ai/asm_plan.md §12): a small, complete, read-only mirror of exactly
   the manifest record families [asm/tools/lib/manifest.ml]'s [Manifest]
   module also parses - [abi-version], [supported-targets],
   [expected-value:<i>], [observation:<i>].

   [asm/tools] is a deliberately isolated Dune project (its own header
   comment: an fmt/bos dependency conflict; zero references to any [asm/lib]
   module today), so this project cannot depend on its [Manifest] module or
   its [Target.t]. This file is the one place in this milestone where the
   same manifest.txt format has two independent readers: [Manifest] in
   [asm/tools] remains the sole WRITER/rehasher of these records - this
   module never writes one, and every field it decodes is already validated
   there before it can be committed. Its own checks below (index pairing,
   duplicates) are defense in depth on that already-validated file, not a
   second grammar authority. *)

open Asm_oracle

type t = {
  abi_version : int;
  supported_targets : Abi.profile list option;
  expected_tail : int64 list;
  observations : (string * int * bool) list;
      (** [(symbol, width, sign_extend)], in [expected_tail]'s order (index 1..N). *)
}

let default = { abi_version = 1; supported_targets = None; expected_tail = []; observations = [] }

let profile_of_string = function
  | "x86_32" -> Some Abi.X86_32
  | "x86_64" -> Some Abi.X86_64
  | "arm" -> Some Abi.Arm
  | "aarch64" -> Some Abi.Aarch64
  | "riscv32" -> Some Abi.Riscv32
  | "riscv64" -> Some Abi.Riscv64
  | _ -> None

let split_tab line =
  match String.index_opt line '\t' with
  | None -> (line, None)
  | Some i -> (String.sub line 0 i, Some (String.sub line (i + 1) (String.length line - i - 1)))

let starts_with prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let strip_prefix prefix s =
  String.sub s (String.length prefix) (String.length s - String.length prefix)

let read case_dir =
  let path = Filename.concat case_dir "manifest.txt" in
  if not (Sys.file_exists path) then default
  else
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let text = really_input_string ic n in
    close_in ic;
    let fail fmt = Printf.ksprintf (fun m -> failwith (path ^ ": " ^ m)) fmt in
    let lines = String.split_on_char '\n' text |> List.filter (fun l -> l <> "") in
    let abi_version = ref 1 in
    let supported_targets = ref None in
    let expected_tbl : (int, int64) Hashtbl.t = Hashtbl.create 4 in
    let obs_tbl : (int, string * int * bool) Hashtbl.t = Hashtbl.create 4 in
    List.iter
      (fun line ->
        let key, value = split_tab line in
        match value with
        | None -> ()
        | Some v ->
            if key = "abi-version" then abi_version := int_of_string v
            else if key = "supported-targets" then
              supported_targets :=
                Some
                  (String.split_on_char ' ' v
                  |> List.filter (fun s -> s <> "")
                  |> List.map (fun s ->
                      match profile_of_string s with
                      | Some p -> p
                      | None -> fail "unknown target %S" s))
            else if starts_with "expected-value:" key then (
              let i = int_of_string (strip_prefix "expected-value:" key) in
              if Hashtbl.mem expected_tbl i then fail "duplicate expected-value:%d" i;
              Hashtbl.add expected_tbl i (Int64.of_string v))
            else if starts_with "observation:" key then (
              let i = int_of_string (strip_prefix "observation:" key) in
              if Hashtbl.mem obs_tbl i then fail "duplicate observation:%d" i;
              match String.split_on_char ' ' v with
              | [ symbol; width_s; sign_s ] ->
                  Hashtbl.add obs_tbl i (symbol, int_of_string width_s, sign_s = "1")
              | _ -> fail "malformed observation:%d" i))
      lines;
    let n_expected = Hashtbl.length expected_tbl and n_obs = Hashtbl.length obs_tbl in
    if n_expected <> n_obs then
      fail "expected-value/observation counts do not match (%d vs %d)" n_expected n_obs;
    let indices = List.init n_expected (fun i -> i + 1) in
    let expected_tail =
      List.map
        (fun i ->
          match Hashtbl.find_opt expected_tbl i with
          | Some v -> v
          | None -> fail "missing expected-value:%d (indices must be 1..N with no gaps)" i)
        indices
    in
    let observations =
      List.map
        (fun i ->
          match Hashtbl.find_opt obs_tbl i with
          | Some o -> o
          | None -> fail "missing observation:%d" i)
        indices
    in
    {
      abi_version = !abi_version;
      supported_targets = !supported_targets;
      expected_tail;
      observations;
    }

let supports profile t =
  match t.supported_targets with None -> true | Some l -> List.mem profile l
