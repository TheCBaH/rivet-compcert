(* In-process CompCert: C source text in, assembly text, a laid-out image, or
   a native run out, with no file read or written on the way.

   This is the target-agnostic half. The CompCert-facing half (options,
   diagnostics capture, the varargs check and the printer call) touches types
   that are distinct per CompCert build, so each target has its own copy,
   compcert_embed_<target>, which applies [Make] to its assembler target and
   that copy. Compiles share CompCert's global state, so they are serialized:
   this API is not reentrant. *)

(* Which step failed. [Compile] is CompCert (including the varargs check),
   [Execute] is mapping or calling the image, and the others are the
   assembler's own pipeline stages. *)
type stage = Compile | Parse | Simplify | Lower | Plan | Execute

type error = {
  stage : stage;
  message : string;
  codes : string list;  (** diagnostic codes, e.g. [image.undefined]; empty for [Compile] *)
}

let stage_name = function
  | Compile -> "compile"
  | Parse -> "parse"
  | Simplify -> "simplify"
  | Lower -> "lower"
  | Plan -> "plan"
  | Execute -> "execute"

let pp_error ppf e = Format.fprintf ppf "[%s] %s" (stage_name e.stage) e.message

(* CompCert colors its diagnostics when the host's stderr is a terminal, and
   the switch is not exported. Captured text is for the caller, not the
   terminal, so the SGR sequences are dropped. *)
let strip_colors s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '\027' && i + 1 < n && s.[i + 1] = '[' then (
      let j = ref (i + 2) in
      while !j < n && match s.[!j] with '0' .. '9' | ';' -> true | _ -> false do
        incr j
      done;
      go (if !j < n && s.[!j] = 'm' then !j + 1 else !j))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(* One target's CompCert, driven the way ccomp -S drives it. [Error] carries
   everything CompCert reported, as it would have appeared on stderr. *)
module type COMPILER = sig
  val compile_to_asm : name:string -> string -> (string, string) result

  val runtime_units : unit -> ((string * string) list, string) result
  (** the target's [__compcert_i64_*] helpers as assembly units, named after
      their CompCert runtime file ([i64_sdiv], ...); empty where ccomp links
      none *)
end

(* {1 Runtime helpers} *)

let is_symbol_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '$' -> true
  | _ -> false

(* Every symbol that follows [prefix] in [text], in order of appearance. *)
let symbols_after prefix ~skip_blanks text =
  let n = String.length text and k = String.length prefix in
  let rec scan i acc =
    if i + k > n then List.rev acc
    else if String.sub text i k = prefix then (
      let j = ref (i + k) in
      if skip_blanks then
        while !j < n && (text.[!j] = ' ' || text.[!j] = '\t') do
          incr j
        done;
      let start = !j in
      while !j < n && is_symbol_char text.[!j] do
        incr j
      done;
      let name = String.sub text start (!j - start) in
      scan !j (if name = "" then acc else name :: acc))
    else scan (i + 1) acc
  in
  scan 0 []

let globals text =
  symbols_after ".globl" ~skip_blanks:true text @ symbols_after ".global" ~skip_blanks:true text

let helper_references text =
  symbols_after "__compcert_i64_" ~skip_blanks:false text |> List.map (( ^ ) "__compcert_i64_")

module Make (T : Target_intf.Target.TARGET) (C : COMPILER) = struct
  module P = Driver.Pipeline.Make (T)

  let target = T.name

  let compile_to_asm ?(name = "gen.c") source =
    C.compile_to_asm ~name source
    |> Result.map_error (fun m -> { stage = Compile; message = strip_colors m; codes = [] })

  (* {1 Assembly} *)

  let entry_symbol = "entry"

  let assembler_error stage e =
    {
      stage;
      message = Foundation.Diag.render e;
      codes = List.map Foundation.Diagnostic.code (Foundation.Diag.diagnostics e);
    }

  let ( let* ) = Result.bind
  let at stage r = Result.map_error (assembler_error stage) r

  let lower_unit (unit_name, text) =
    let source = Foundation.Span.source ~name:unit_name ~contents:text in
    let* src = at Parse (P.parse ~unit_name ~source) in
    let* norm, _ = at Simplify (P.simplify ~state:T.default_state src) in
    at Lower (P.lower ~state:T.default_state norm)

  (* [units] plus every runtime helper they need, directly or through other
     helpers: a helper is added when some unit names a [__compcert_i64_]
     symbol that no unit defines. Units that define a helper themselves
     (for example a fixture's own copy) keep it. *)
  let with_runtime units =
    let defined us = List.concat_map (fun (_, t) -> globals t) us in
    let missing us =
      let d = defined us in
      List.concat_map (fun (_, t) -> helper_references t) us
      |> List.sort_uniq compare
      |> List.filter (fun s -> not (List.mem s d))
    in
    match missing units with
    | [] -> Ok units
    | _ -> (
        match C.runtime_units () with
        | Error m -> Error { stage = Compile; message = strip_colors m; codes = [] }
        | Ok runtime ->
            let rec close us =
              let wanted = missing us in
              let adds =
                List.filter
                  (fun (name, t) ->
                    (not (List.mem_assoc name us))
                    && List.exists (fun g -> List.mem g wanted) (globals t))
                  runtime
              in
              if adds = [] then us else close (us @ adds)
            in
            Ok (close units))

  let runtime_units () =
    C.runtime_units ()
    |> Result.map_error (fun m -> { stage = Compile; message = strip_colors m; codes = [] })

  let assemble_units ?(entry = entry_symbol) units =
    let* units = with_runtime units in
    let rec lower_all acc = function
      | [] -> Ok (List.rev acc)
      | u :: rest ->
          let* m = lower_unit u in
          lower_all (m :: acc) rest
    in
    let* modules = lower_all [] units in
    match modules with [ m ] -> at Plan (P.plan ~entry m) | ms -> at Plan (P.plan_many ~entry ms)

  let assemble ?entry ?(unit_name = "gen") text = assemble_units ?entry [ (unit_name, text) ]

  let compile ?entry ?name source =
    let* text = compile_to_asm ?name source in
    assemble ?entry ?unit_name:name text

  (* {1 Running} *)

  (* Only where this process runs [target]'s ISA; elsewhere [Native_exec]
     refuses the image. [~isolate:true] runs it in a forked child (see
     [Native_exec.run]): a crash or a hang in generated code is then an
     [Execute] error instead of the end of this process. *)
  let run ?entry ?name ?read_globals ?isolate ?timeout_s source ~io =
    let* laid = compile ?entry ?name source in
    Native_exec.run ~target ?read_globals ?isolate ?timeout_s laid ~io
    |> Result.map_error (fun e ->
        { stage = Execute; message = Format.asprintf "%a" Native_exec.pp_error e; codes = [] })
end
