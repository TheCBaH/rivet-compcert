[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* In-process CompCert for riscv32; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Riscv32) (Cc_compile)
