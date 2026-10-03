[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

let dir repo suite target =
  Fpath.(Repo.path repo / "fixtures" / "corpus" / suite / Target.to_string target)

let c repo target = dir repo "c" target
let c_assemble repo target = dir repo "c-assemble" target
let c_gcc repo target = dir repo "c-gcc" target
let regression repo target = dir repo "regression" target
let compression repo target = dir repo "compression" target
