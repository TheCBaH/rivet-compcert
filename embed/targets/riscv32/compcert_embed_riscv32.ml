(* In-process CompCert for riscv32; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Riscv32) (Cc_compile)
