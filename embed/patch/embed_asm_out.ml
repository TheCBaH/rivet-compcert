(* Injected into the embed variant of CompCert (see ../compcert-embed-sync.sh).

   Every assembly printer module gets a one-line [open Embed_asm_out] ahead of
   its own [open Printf]. That shadows the output channel type and the three
   ways the printers write to it, so the printers compile unchanged but write
   into a [Buffer.t] instead of a file. Nothing else is defined here: a name
   this module does not shadow keeps its standard-library meaning. *)

type out_channel = Buffer.t

let output_string = Buffer.add_string
let output_char = Buffer.add_char

module Printf = struct
  include Stdlib.Printf

  let fprintf = bprintf
end
