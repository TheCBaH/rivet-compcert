[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* In-process CompCert: C source text in, assembly text, a laid-out image, or
   a native run out, with no file read or written on the way.

   This is the target-agnostic half. The CompCert-facing half (options,
   diagnostics capture, the varargs check and the printer call) touches types
   that are distinct per CompCert build, so each target has its own copy,
   compcert_embed_<target>, which applies [Make] to its assembler target and
   that copy. Compiles share CompCert's global state and redirect the process's
   [Format.err_formatter], so they are serialized by one lock for the whole
   process: any number of threads may call in, one compiles at a time. The lock
   covers compilation only. Assembly and running touch no shared state, and
   other code writing to [Format.err_formatter] while a compile is in progress
   has its output captured with the compiler's.

   Input contract: C source must already be preprocessed. There is no
   preprocessor here and no system headers, so every type and function the
   source uses is declared in it, and [#include], [#define], [#if] and the
   like are refused up front as [Input] errors; line markers ([# 12 "f.c"]),
   [#line] and [#pragma] are accepted. *)

(* Which step failed. [Compile] is CompCert (including the varargs check),
   [Execute] is mapping or calling the image, [Input] is a source that breaks the
   preprocessed-C contract, and the others are the assembler's own pipeline
   stages. *)
type stage = Input | Compile | Parse | Simplify | Lower | Plan | Execute

type error = {
  stage : stage;
  message : string;
  codes : string list;  (** diagnostic codes, e.g. [image.undefined]; empty for [Compile] *)
}

let stage_name = function
  | Input -> "input"
  | Compile -> "compile"
  | Parse -> "parse"
  | Simplify -> "simplify"
  | Lower -> "lower"
  | Plan -> "plan"
  | Execute -> "execute"

let pp_error ppf e = Format.fprintf ppf "[%s] %s" (stage_name e.stage) e.message

(* The first directive in [source] that is not a line marker, [#line] or
   [#pragma], as (line, text). Comments and string and character literals are
   skipped, so a [#] that starts a line inside one is not a directive. *)
let first_directive source =
  let n = String.length source in
  let rec line_end i = if i >= n || source.[i] = '\n' then i else line_end (i + 1) in
  (* A directive runs to the first newline not escaped by a backslash. *)
  let rec directive_end i =
    let e = line_end i in
    if e < n && e > i && source.[e - 1] = '\\' then directive_end (e + 1) else e
  in
  let allowed text =
    let t = String.trim (String.sub text 1 (String.length text - 1)) in
    (t <> "" && match t.[0] with '0' .. '9' -> true | _ -> false)
    || List.exists (fun p -> String.starts_with ~prefix:p t) [ "line"; "pragma" ]
  in
  let rec code i line at_start =
    if i >= n then None
    else
      match source.[i] with
      | '\n' -> code (i + 1) (line + 1) true
      | ' ' | '\t' | '\r' -> code (i + 1) line at_start
      | '#' when at_start ->
          let e = directive_end i in
          let text = String.sub source i (e - i) in
          if allowed text then code e line true else Some (line, String.trim text)
      | '/' when i + 1 < n && source.[i + 1] = '/' -> code (line_end i) line false
      | '/' when i + 1 < n && source.[i + 1] = '*' -> block (i + 2) line
      | ('"' | '\'') as q -> literal q (i + 1) line
      | _ -> code (i + 1) line false
  and block i line =
    if i + 1 >= n then None
    else if source.[i] = '*' && source.[i + 1] = '/' then code (i + 2) line false
    else block (i + 1) (if source.[i] = '\n' then line + 1 else line)
  and literal q i line =
    if i >= n then None
    else
      match source.[i] with
      | '\\' -> literal q (i + 2) line
      | c when c = q -> code (i + 1) line false
      | '\n' -> code (i + 1) (line + 1) true
      | _ -> literal q (i + 1) line
  in
  code 0 1 true

let check_preprocessed ?(name = "gen.c") source =
  match first_directive source with
  | None -> Ok ()
  | Some (line, text) ->
      let shown = if String.length text > 60 then String.sub text 0 60 ^ "..." else text in
      Error
        {
          stage = Input;
          message =
            Printf.sprintf
              "%s:%d: error: source is not preprocessed: %S (the embedded compiler has no \
               preprocessor and no system headers)"
              name line shown;
          codes = [ "embed.input.directive" ];
        }

(* One lock for every target: CompCert's state is per build, but the
   formatter it is redirected through is the process's. *)
let compiler_lock = Mutex.create ()

let serialized f =
  Mutex.lock compiler_lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock compiler_lock) f

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

(* The runtime's symbol prefixes: CompCert's own helpers, and the AAPCS division functions
   its arm code calls. *)
let runtime_prefixes = [ "__compcert_i64_"; "__aeabi_" ]

let helper_references text =
  List.concat_map
    (fun prefix -> symbols_after prefix ~skip_blanks:false text |> List.map (( ^ ) prefix))
    runtime_prefixes

module Make (T : Target_intf.Target.TARGET) (C : COMPILER) = struct
  module P = Driver.Pipeline.Make (T)

  let target = T.name

  let compile_to_asm ?(name = "gen.c") source =
    Result.bind (check_preprocessed ~name source) (fun () ->
        serialized (fun () -> C.compile_to_asm ~name source)
        |> Result.map_error (fun m -> { stage = Compile; message = strip_colors m; codes = [] }))

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
     helpers: a helper is added when some unit names a runtime symbol
     ({!runtime_prefixes}) that no unit defines. Units that define a helper themselves
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
        match serialized C.runtime_units with
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
    serialized C.runtime_units
    |> Result.map_error (fun m -> { stage = Compile; message = strip_colors m; codes = [] })

  (* Names of host functions the units call, bound to this process's
     addresses by a trampoline unit (see [Native_exec.bind_host]). The
     addresses are process-specific: an image assembled with them is only for
     this process. *)
  let with_host_symbols host_symbols units =
    match host_symbols with
    | [] -> Ok units
    | names -> (
        match Native_exec.bind_host ~target names with
        | Ok text -> Ok (units @ [ ("host", text) ])
        | Error e ->
            Error
              {
                stage = Execute;
                message = Format.asprintf "%a" Native_exec.pp_error e;
                codes = [ "embed.host_symbol" ];
              })

  let assemble_units ?(entry = entry_symbol) ?(host_symbols = []) units =
    let* units = with_runtime units in
    let* units = with_host_symbols host_symbols units in
    let rec lower_all acc = function
      | [] -> Ok (List.rev acc)
      | u :: rest ->
          let* m = lower_unit u in
          lower_all (m :: acc) rest
    in
    let* modules = lower_all [] units in
    match modules with [ m ] -> at Plan (P.plan ~entry m) | ms -> at Plan (P.plan_many ~entry ms)

  let assemble ?entry ?host_symbols ?(unit_name = "gen") text =
    assemble_units ?entry ?host_symbols [ (unit_name, text) ]

  let compile ?entry ?host_symbols ?name source =
    let* text = compile_to_asm ?name source in
    assemble ?entry ?host_symbols ?unit_name:name text

  (* {1 Running} *)

  (* Only where this process runs [target]'s ISA; elsewhere [Native_exec]
     refuses the image. [~isolate:true] runs it in a forked child (see
     [Native_exec.run]): a crash or a hang in generated code is then an
     [Execute] error instead of the end of this process. *)
  let execute_error e =
    { stage = Execute; message = Format.asprintf "%a" Native_exec.pp_error e; codes = [] }

  (* A persistent mapping for repeated calls: [Native_exec.call] on the result,
     [Native_exec.close] when done. *)
  let load ?entry ?host_symbols ?name source =
    let* laid = compile ?entry ?host_symbols ?name source in
    Native_exec.load ~target laid |> Result.map_error execute_error

  let run ?entry ?host_symbols ?name ?read_globals ?isolate ?timeout_s source ~io =
    let* laid = compile ?entry ?host_symbols ?name source in
    Native_exec.run ~target ?read_globals ?isolate ?timeout_s laid ~io
    |> Result.map_error execute_error
end
