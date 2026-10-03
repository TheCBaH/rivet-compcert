[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

let%expect_test "the embed variant of CompCert and the image library link together" =
  print_endline Compcert_embed_aarch64.CC.Configuration.arch;
  print_endline (if Image.default_policy.Image.entry_symbol = None then "image linked" else "?");
  [%expect {|
    aarch64
    image linked
    |}]
