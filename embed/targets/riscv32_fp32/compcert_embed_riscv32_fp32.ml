[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic"]

(* In-process CompCert for the F-only riscv32 profile; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Riscv32) (Cc_compile)
