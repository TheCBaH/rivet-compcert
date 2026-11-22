[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* In-process CompCert for arm; see Rivet_compcert_embed. *)

module CC = Embed_cc.CC
include Rivet_compcert_embed.Make (Arm) (Cc_compile)
