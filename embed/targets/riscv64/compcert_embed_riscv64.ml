(* In-process CompCert for riscv64; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Riscv64) (Cc_compile)
