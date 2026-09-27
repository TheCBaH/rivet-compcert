(* In-process CompCert for x86_32; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (X86_32) (Cc_compile)
