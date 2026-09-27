(* Injected into the embed variant of CompCert (see ../compcert-embed-sync.sh).

   [Diagnostics.fatal_error_raw], which reports syntax errors, prints straight
   to the standard error channel with [Printf.kfprintf] instead of going
   through [Format.err_formatter] like every other diagnostic. Shadowing both
   names sends that text to [stderr] below, a buffer the embedding drains
   after each compile. [out_channel] is shadowed for Diagnostics.mli, whose
   [fatal_error_raw] signature names the channel type. *)

type out_channel = Buffer.t

let stderr = Buffer.create 256

module Printf = struct
  include Stdlib.Printf

  let kfprintf = kbprintf
end
