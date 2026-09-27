(* In-process CompCert for aarch64; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Aarch64) (Cc_compile)
