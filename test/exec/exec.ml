(* Execution: E5 (.ai/asm_plan.md M1.6).

   The last rung of the evidence ladder, and the only one where the assembler's
   own output is the thing that runs. Every earlier gate compares this
   assembler's bytes to GNU as's bytes; this one binds the image at the ABI-v1
   profile code base, hands it to the checked-in user-mode helper, and requires
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

   The induced-failure control is the other half. A gate that cannot fail is not
   a gate, and a random bit flip is not good enough: most flips in this code
   leave something that still returns 42 or that faults, and a fault would be
   attributed to the environment rather than to the mutation. So the mutation is
   the constant-materializing immediate and nothing else, chosen per target so
   the function provably returns 41. Each mutation is required to match exactly
   once in the image, which is what stops it from silently becoming a no-op if
   the encoding ever changes. *)

open Asm_oracle
open Asm_oracle_run

let profiles = [ Abi.X86_32; Abi.X86_64; Abi.Arm; Abi.Aarch64 ]

let target_of_profile = function
  | Abi.X86_32 -> "x86_32"
  | Abi.X86_64 -> "x86_64"
  | Abi.Arm -> "arm"
  | Abi.Aarch64 -> "aarch64"

let case_id = 42
let stack_16k = 16 * 1024

let hex s =
  String.concat " " (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

(* {1 Assembling the fixture at the profile's code base}

   Note which address is used: [Abi.code_addr profile], the address the helper
   will map the segment at. That is the whole point of §9's two-step contract -
   the assembler said what alignment it needed, the host chose where, and
   [bind_image] is where the two meet. Binding at 0x0 as the differential gate
   does and then running it at another address would be testing a different
   image. *)
let assemble profile =
  let name = target_of_profile profile in
  let (module D : Target_intf.Target.DRIVER) =
    match Driver.Registry.find name with Some d -> d | None -> failwith ("no such target: " ^ name)
  in
  let text = List.assoc name Test_dump_inputs.all in
  let source = Foundation.Span.source ~name:(name ^ ".s") ~contents:text in
  match D.assemble ~unit_name:"asm_test_entry" ~source with
  | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
  | Ok laid_out -> (
      let plan = Image.plan_of laid_out in
      let base = Abi.code_addr profile in
      let addresses =
        List.map (fun (s : Image.segment_plan) -> (s.Image.seg_name, base)) plan.Image.segments
      in
      match Image.bind_image laid_out ~addresses with
      | Error ds -> failwith (Foundation.Diagnostic.render_all ds)
      | Ok img -> (
          match img.Image.segments with
          | s :: _ -> s.Image.bytes
          | [] -> failwith "the image has no segment"))

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

let run profile code ~expected =
  let manifest =
    Manifest.serialize
      (Manifest.single_code ~case_id ~stack_size:stack_16k ~timeout_ms:2000 ~expected profile code)
  in
  Qemu_user.run ~profile ~manifest ~expected_case_id:case_id ()

type verdict = Ok_ of string | Bad of string

(* Every one of the four conditions is checked separately and named separately.
   A single boolean would report "did not pass" for a guest that faulted, for a
   guest that returned the wrong value, and for a record that was never
   committed - three different failures with three different causes. *)
let verdict ~want_status ~want_value (o : Qemu_user.t) =
  let fail f = Bad (Printf.sprintf "%s (actual: %s)" f (Fmt.str "%a" Qemu_user.pp o)) in
  match o.Qemu_user.termination with
  | Qemu_user.Completed -> (
      match o.Qemu_user.record with
      | None -> fail "result is not recovered"
      | Some (Record.Invalid m) -> fail ("record failed the recovery validator: " ^ m)
      | Some Record.Pending_pre_run_error -> fail "record is a pending pre-run error"
      | Some (Record.Valid r) ->
          if r.Record.record_state <> Abi.Returned then fail "record_state is not returned"
          else if r.Record.status <> want_status then fail "status is not the expected one"
          else if r.Record.values <> [| want_value |] then fail "values are not the expected ones"
          else if want_status = Abi.Passed && r.Record.expected <> [| want_value |] then
            fail "expected[] does not hold the value the manifest declared"
          else
            Ok_
              (Printf.sprintf "%s, record_state=returned, values=[%Ld]"
                 (if want_status = Abi.Passed then "passed" else "failed")
                 want_value))
  | _ -> fail "termination is not completed"

let failures = ref 0

let report profile label = function
  | Ok_ detail -> Printf.printf "  ok   %-24s %s\n" label detail
  | Bad why ->
      incr failures;
      Printf.printf "  FAIL %-24s %s\n" label why;
      ignore profile

let () =
  Printf.printf "asm-exec: E5, the assembler's own image under QEMU user mode\n";
  List.iter
    (fun profile ->
      let name = target_of_profile profile in
      match Qemu_user.provenance profile with
      | [] ->
          incr failures;
          Printf.printf "%s: FAIL no helper in %s (run `make asm-helpers`)\n" name
            (Qemu_user.helpers_dir ())
      | prov -> (
          Printf.printf "%s\n" name;
          List.iter (fun l -> Printf.printf "  %s\n" l) prov;
          let code = assemble profile in
          Printf.printf "  image %d bytes at 0x%Lx: %s\n" (String.length code)
            (Abi.code_addr profile) (hex code);
          report profile "returns 42"
            (verdict ~want_status:Abi.Passed ~want_value:42L (run profile code ~expected:[ 42L ]));
          (* The control declares expected = [42] and gets 41, so the helper
             publishes [failed]. Declaring [41] instead would make the mutated
             image "pass" and prove nothing about the gate's ability to fail. *)
          match mutate profile code with
          | Error m ->
              incr failures;
              Printf.printf "  FAIL %-24s %s\n" "induced-failure control" m
          | Ok mutated ->
              report profile "induced 41"
                (verdict ~want_status:Abi.Failed ~want_value:41L
                   (run profile mutated ~expected:[ 42L ]))))
    profiles;
  if !failures = 0 then (
    Printf.printf "asm-exec: %d profiles, 0 failures\n" (List.length profiles);
    exit 0)
  else (
    Printf.printf "asm-exec: %d failures\n" !failures;
    exit 1)
