[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* In-process CompCert for arm; see Compcert_embed. *)

module CC = Embed_cc.CC
include Compcert_embed.Make (Arm) (Cc_compile)
