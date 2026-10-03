[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* In-process CompCert for x86_64; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (X86_64) (Cc_compile)
