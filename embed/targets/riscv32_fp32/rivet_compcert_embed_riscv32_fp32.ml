[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic"]

(* In-process CompCert for the F-only riscv32 profile; see Rivet_compcert_embed. *)

module CC = Embed_cc.CC
include Rivet_compcert_embed.Make (Rivet_riscv32) (Cc_compile)
