(* Execution: E5 (.ai/asm_plan.md M1.6) and X1.

   The last rung of the evidence ladder, and the only one where the assembler's
   own output is the thing that runs. Every earlier gate compares this
   assembler's bytes to GNU as's bytes; this one binds the image at the ABI-v1
   profile addresses, hands it to the checked-in user-mode helper, and requires
   the guest to have actually returned 42.

   Four conditions, all of them, per §16.3 and the M1.6 acceptance:

     termination  = completed
     result       = recovered
     record_state = returned
     status       = passed, committed, with expected = [42] and values = [42]

   The commit marker is what makes the actuals evidence at all. A record whose
   status field reads "passed" without its commit bit set has not been written
   by a guest that finished; it has been read out of memory that may never have
   been stored to.

   X1 is what makes this generalize past return42. Every case's entry is a
   zero-argument [asm_test_entry] returning 42, because the ABI helpers install
   no arguments (exec-abi-v1.md §11) and a fixture consuming unspecified ones
   has no deterministic result. A case needing operands supplies them as
   constants from inside that entry - which for args_arith and direct_call is
   also what produces the non-tail call the fixture gate requires.

   The induced-failure control is the other half. A gate that cannot fail is not
   a gate, and a random bit flip is not good enough: most flips in this code
   leave something that still returns 42 or that faults, and a fault would be
   attributed to the environment rather than to the mutation. So the mutation is
   the constant-materializing immediate and nothing else, chosen per target so
   the function provably returns 41. Each mutation is required to match exactly
   once in the image, which is what stops it from silently becoming a no-op if
   the encoding ever changes. It applies to return42 alone: the other cases
   reach 42 by arithmetic rather than by materializing it, so there is no single
   splice that provably lands on 41, and inventing one per case would be four
   more things to keep true. One live control is what the gate needs. *)

open Asm_oracle
open Asm_oracle_run

let profiles = [ Abi.X86_32; Abi.X86_64; Abi.Arm; Abi.Aarch64 ]
let target_of_profile = Abi.profile_name
let case_id = 42
let stack_16k = 16 * 1024

(* Relative to the asm/ directory, which is where the Makefile runs this from.
   It reads the real source tree rather than a dune dependency set on purpose:
   asm-exec is deliberately not reachable from asm-test, because it needs the
   cross-assembled helpers and four qemu-user binaries that the portable CI leg
   does not have. *)
let corpus_root = "fixtures/compcert-3.17"

let read path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let cases () =
  Sys.readdir corpus_root |> Array.to_list
  |> List.filter (fun c ->
      Sys.file_exists (Filename.concat (Filename.concat corpus_root c) "source"))
  |> List.sort compare

(* {1 Assembling the fixture at the profile's addresses}

   Note which addresses are used: the ones [Abi] declares and the helper will
   map the segments at. That is the whole point of §9's two-step contract - the
   assembler said what alignment it needed, the host chose where, and
   [bind_image] is where the two meet. Binding at 0x0 as the differential gate
   does and then running it at another address would be testing a different
   image.

   Every allocatable section gets its own address from the same table the GNU
   reference link and the checked-in policy use, so the running image and the
   byte-compared one are laid out identically rather than merely similarly. *)
let address_for profile section =
  match section with
  | ".text" -> Abi.code_addr profile
  | ".rodata" -> Abi.rodata_addr profile
  | ".data" -> Abi.data_addr profile
  (* M3 (.ai/asm_plan.md §12): a real NOBITS section is now possible, so it
     needs its own address rather than aliasing .data's - two segments at one
     address was exactly M1's silent behavior Image.bind_image no longer
     tolerates once more than one segment can be nonempty (image.ml's
     overlap check). Abi_v2.bss_addr, not a new Abi (v1) constant: BSS
     placement is a policy decision, not a wire-format one, and v1 is frozen
     to its own. *)
  | ".bss" -> Abi_v2.bss_addr profile
  | other -> failwith ("no ABI address for section " ^ other)

(* Sorted lexicographically by filename, each unit named after its own stem -
   the same convention [test_differential.ml]'s [unit_paths]/[build] use, so a
   multi-source case (M3's [cross_call]/[cross_data]) gets a deterministic,
   collision-free set of unit names instead of every file sharing the single
   entry-name unit this function used before it supported more than one. *)
let units_of dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".s")
  |> List.sort compare
  |> List.map (fun f -> (Filename.chop_suffix f ".s", Filename.concat dir f))

let assemble profile case =
  let name = target_of_profile profile in
  let (module D : Target_intf.Target.DRIVER) =
    match Driver.Registry.find name with Some d -> d | None -> failwith ("no such target: " ^ name)
  in
  let dir = Filename.concat (Filename.concat corpus_root case) name in
  let units = units_of dir in
  let sourced =
    List.map
      (fun (stem, path) -> (stem, Foundation.Span.source ~name:path ~contents:(read path)))
      units
  in
  let result =
    match sourced with
    | [] -> failwith (dir ^ " holds no .s files")
    | [ (_, source) ] -> D.assemble ~entry:"asm_test_entry" ~unit_name:"asm_test_entry" ~source ()
    | many -> D.assemble_many ~entry:"asm_test_entry" many ()
  in
  match result with
  | Error ds -> Error (String.trim (Foundation.Diag.render ds))
  | Ok laid_out -> (
      let plan = Image.plan_of laid_out in
      let addresses =
        List.map
          (fun (s : Image.segment_plan) -> (s.Image.seg_name, address_for profile s.Image.seg_name))
          plan.Image.segments
      in
      match Image.bind_image laid_out ~addresses with
      | Error ds -> Error (String.trim (Foundation.Diag.render ds))
      | Ok img -> Ok img)

(* {1 The manifest for a bound image}

   [Manifest.single_code] describes the M1 shape - one executable segment,
   entered at its first byte - and an M2 case with an initialized global has two
   segments with different permissions. Each bound segment becomes its own
   descriptor carrying its own [perms] and [zero_fill], which is what makes a
   two-segment case prove anything: a data segment mapped read-only, or not
   mapped at all, would fault or read the wrong page rather than returning a
   wrong answer.

   The entry comes from the image rather than from the code base, because it is
   no longer the first byte of [.text] - direct_call lays its callee out first.
   An image with no entry is refused rather than entered at offset zero.

   This lives here and not in [Manifest] on purpose: asm_oracle reaches no part
   of the assembler, so that a broken assembler cannot make the ABI conformance
   suite pass. *)
let manifest_of_image profile (img : Image.t) ~expected =
  match img.Image.entry with
  | None -> Error "the image has no entry symbol, so there is no address to enter it at"
  | Some entry_addr ->
      Ok
        {
          Manifest.profile;
          case_id;
          entry_addr;
          result_addr = Abi.result_addr profile;
          stack_size = stack_16k;
          timeout_ms = 2000;
          expected;
          observations = [];
          segments =
            List.map
              (fun (s : Image.segment) ->
                {
                  Manifest.vaddr = s.Image.address;
                  init = s.Image.bytes;
                  zero_len = Int64.of_int s.Image.zero_fill;
                  align = max 16 s.Image.alignment;
                  perms =
                    ((if Asm_core.Perms.readable s.Image.perms then Abi.perm_r else 0)
                    lor (if Asm_core.Perms.writable s.Image.perms then Abi.perm_w else 0)
                    lor if Asm_core.Perms.executable s.Image.perms then Abi.perm_x else 0);
                })
              img.Image.segments;
        }

(* {1 The induced-failure control}

   The byte pair is in {!Snippet_bytes.mutation}, beside the two snippets whose
   difference it is: [return42] and [return41] differ by exactly this splice,
   and stating that fact twice is how the two drift. *)
let mutation = Snippet_bytes.mutation

let occurrences ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i acc =
    if i + n > h then acc
    else if String.sub haystack i n = needle then go (i + 1) (i :: acc)
    else go (i + 1) acc
  in
  List.rev (go 0 [])

let mutate profile bytes =
  let needle, replacement = mutation profile in
  match occurrences ~needle bytes with
  | [ i ] ->
      Ok
        (String.sub bytes 0 i ^ replacement
        ^ String.sub bytes
            (i + String.length needle)
            (String.length bytes - i - String.length needle))
  | [] -> Error "the mutation pattern does not appear in the image"
  | many -> Error (Printf.sprintf "the mutation pattern appears %d times" (List.length many))

(* {1 Running} *)

(* M4 Phase 4: [abi_version] is now a parameter of exec.ml's own driver rather
   than a literal 1 - [Qemu_user]/[Record]/[Abi] were already version-
   parametric (M4 Phase 2.4's dispatch-site table), but this local wrapper was
   the one remaining hardcoded call site. Every existing call site still
   passes [~abi_version:1] explicitly (return42/run_control's fixed point);
   Phase 5.3 is what will make a case's own manifest record choose the
   version. *)
let run ~abi_version profile manifest =
  Qemu_user.run ~abi_version ~profile
    ~manifest:(Manifest.serialize ~abi_version manifest)
    ~expected_case_id:case_id ()

type verdict = Ok_ of string | Bad of string

(* Every one of the four conditions is checked separately and named separately.
   A single boolean would report "did not pass" for a guest that faulted, for a
   guest that returned the wrong value, and for a record that was never
   committed - three different failures with three different causes.

   [want_values] generalizes the old singleton [want_value]: v1/v2 callers
   pass a one-element list, and the element-wise comparison against
   [r.Record.values] is exactly v3's own "expected == actual, in order"
   contract (docs/exec-abi-v3.md §4), so no v3-specific branch is needed here. *)
let verdict ~want_status ~want_values (o : Qemu_user.t) =
  let fail f = Bad (Printf.sprintf "%s (actual: %s)" f (Fmt.str "%a" Qemu_user.pp o)) in
  let want = Array.of_list want_values in
  match o.Qemu_user.termination with
  | Qemu_user.Completed -> (
      match o.Qemu_user.record with
      | None -> fail "result is not recovered"
      | Some (Record.Invalid m) -> fail ("record failed the recovery validator: " ^ m)
      | Some Record.Pending_pre_run_error -> fail "record is a pending pre-run error"
      | Some (Record.Valid r) ->
          if r.Record.record_state <> Abi.Returned then fail "record_state is not returned"
          else if r.Record.status <> want_status then fail "status is not the expected one"
          else if r.Record.values <> want then fail "values are not the expected ones"
          else if want_status = Abi.Passed && r.Record.expected <> want then
            fail "expected[] does not hold the values the manifest declared"
          else
            Ok_
              (Fmt.str "%s, record_state=returned, values=%a"
                 (if want_status = Abi.Passed then "passed" else "failed")
                 (Fmt.array ~sep:(Fmt.any ",") (fun ppf v -> Fmt.pf ppf "%Ld" v))
                 want))
  | _ -> fail "termination is not completed"

let failures = ref 0
let blocked = ref 0

let report label = function
  | Ok_ detail -> Printf.printf "  ok   %-24s %s\n" label detail
  | Bad why ->
      incr failures;
      Printf.printf "  FAIL %-24s %s\n" label why

let describe (img : Image.t) =
  String.concat ", "
    (List.map
       (fun (s : Image.segment) ->
         Printf.sprintf "%s %d bytes at 0x%Lx %s" s.Image.name (String.length s.Image.bytes)
           s.Image.address
           (Asm_core.Perms.to_string s.Image.perms))
       img.Image.segments)

(* M4 Phase 9: an opt-in retry with QEMU's own tracing, decided here rather
   than inside [Qemu_user.run] - [run_control]'s own induced "41 instead of
   42" case is a *designed* failure of [want_status]/[want_values], not
   evidence of a defect, and only this layer knows which verdict was wanted.
   [Qemu_user.run] has no notion of an expected outcome and cannot tell "this
   is run_control working as intended" from "this is a real conformance
   failure" - so the retry decision, and the [ASM_QEMU_TRACE] gate, live here.

   Only re-runs on an actual failure, and only when opted in: a default run
   (env unset) never calls [Qemu_user.run] a second time, so its output is
   byte-identical to before this phase. *)
let maybe_trace ~abi_version ~profile ~manifest = function
  | Ok_ _ -> ()
  | Bad _ -> (
      match Sys.getenv_opt "ASM_QEMU_TRACE" with
      | None -> ()
      | Some _ -> (
          let traced =
            Qemu_user.run ~abi_version ~profile
              ~manifest:(Manifest.serialize ~abi_version manifest)
              ~expected_case_id:case_id
              ~qemu_args:[ "-d"; "in_asm,strace"; "-D"; Qemu_user.trace_file_name ]
              ()
          in
          match traced.Qemu_user.trace with
          | Some t -> Printf.printf "  trace (ASM_QEMU_TRACE):\n%s\n" t
          | None -> Printf.printf "  trace (ASM_QEMU_TRACE): qemu wrote none\n"))

let run_case profile case =
  let label = Printf.sprintf "%s returns 42" case in
  match assemble profile case with
  | Error why ->
      (* Not a failure of this gate: it is the assembler not yet accepting the
         fixture, which the differential transcript already records case by
         case. Counting it here as well would report the same missing
         instruction form as two independent problems. *)
      incr blocked;
      Printf.printf "  --   %-24s not assembled yet (%s)\n" label
        (match String.index_opt why '\n' with Some i -> String.sub why 0 i | None -> why)
  | Ok img -> (
      Printf.printf "  %s: %s\n" case (describe img);
      match manifest_of_image profile img ~expected:[ 42L ] with
      | Error why ->
          incr failures;
          Printf.printf "  FAIL %-24s %s\n" label why
      | Ok m ->
          let v =
            verdict ~want_status:Abi.Passed ~want_values:[ 42L ]
              (run ~abi_version:Abi.abi_version profile m)
          in
          report label v;
          maybe_trace ~abi_version:Abi.abi_version ~profile ~manifest:m v)

(* The control declares expected = [42] and gets 41, so the helper publishes
   [failed]. Declaring [41] instead would make the mutated image "pass" and
   prove nothing about the gate's ability to fail. *)
let run_control profile =
  match assemble profile "return42" with
  | Error why ->
      incr failures;
      Printf.printf "  FAIL %-24s %s\n" "induced-failure control" why
  | Ok img -> (
      match img.Image.segments with
      | [ s ] -> (
          match mutate profile s.Image.bytes with
          | Error m ->
              incr failures;
              Printf.printf "  FAIL %-24s %s\n" "induced-failure control" m
          | Ok mutated -> (
              let img = { img with Image.segments = [ { s with Image.bytes = mutated } ] } in
              match manifest_of_image profile img ~expected:[ 42L ] with
              | Error why ->
                  incr failures;
                  Printf.printf "  FAIL %-24s %s\n" "induced-failure control" why
              | Ok m ->
                  let v =
                    verdict ~want_status:Abi.Failed ~want_values:[ 41L ]
                      (run ~abi_version:Abi.abi_version profile m)
                  in
                  report "induced 41" v;
                  maybe_trace ~abi_version:Abi.abi_version ~profile ~manifest:m v))
      | segs ->
          incr failures;
          Printf.printf "  FAIL %-24s return42 has %d segments, the control splices one\n"
            "induced-failure control" (List.length segs))

(* M4 Phase 4's own exit criterion: a direct proof that the *generalized*
   [run]/[verdict] above - not [Qemu_user]/[Record], already proven generic by
   [abi_v3_smoke.ml] - report a multi-value result correctly at
   [~abi_version:3]. No fixture reaches v3 through [cases()] yet (that is
   Phase 5/6), so this hand-builds a manifest the same way
   [abi_v3_smoke.ml] does: a tiny machine-code segment that writes a known
   constant to a data segment and returns 42, observed as a second value. *)
let run_v3_plumbing_check () =
  let label = "v3 plumbing (Phase 4)" in
  let profile = Abi.X86_64 in
  match Qemu_user.provenance ~abi_version:Abi_v3.abi_version profile with
  | [] ->
      incr failures;
      Printf.printf "  FAIL %-24s no v3 helper in %s (run `make asm-helpers`)\n" label
        (Qemu_user.helpers_dir ())
  | _ ->
      (* x86-64: movabs $0x40020000,%rax ; movl $0x11223344,(%rax) ; movl $42,%eax ; ret *)
      let code =
        "\x48\xb8\x00\x00\x02\x40\x00\x00\x00\x00\xc7\x00\x44\x33\x22\x11\xb8\x2a\x00\x00\x00\xc3"
      in
      let observed_value = 0x11223344L in
      let manifest =
        {
          (Manifest.single_code ~case_id ~expected:[ 42L; observed_value ] profile code) with
          Manifest.segments =
            [
              Manifest.code_segment profile code;
              {
                Manifest.vaddr = Abi.data_addr profile;
                init = "";
                zero_len = 4L;
                align = 16;
                perms = Abi.perm_r lor Abi.perm_w;
              };
            ];
          observations =
            [ { Manifest.obs_vaddr = Abi.data_addr profile; width = 4; sign_extend = false } ];
        }
      in
      report label
        (verdict ~want_status:Abi.Passed ~want_values:[ 42L; observed_value ]
           (run ~abi_version:Abi_v3.abi_version profile manifest))

let () =
  Printf.printf "asm-exec: E5, the assembler's own image under QEMU user mode\n";
  let cases = cases () in
  List.iter
    (fun profile ->
      let name = target_of_profile profile in
      match Qemu_user.provenance ~abi_version:1 profile with
      | [] ->
          incr failures;
          Printf.printf "%s: FAIL no helper in %s (run `make asm-helpers`)\n" name
            (Qemu_user.helpers_dir ())
      | prov ->
          Printf.printf "%s\n" name;
          List.iter (fun l -> Printf.printf "  %s\n" l) prov;
          List.iter (fun c -> run_case profile c) cases;
          run_control profile)
    profiles;
  run_v3_plumbing_check ();
  Printf.printf "asm-exec: %d profiles x %d cases, %d blocked on unimplemented forms, %d failures\n"
    (List.length profiles) (List.length cases) !blocked !failures;
  if !failures = 0 then exit 0 else exit 1
