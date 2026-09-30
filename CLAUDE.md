# CLAUDE.md

Integration of CompCert with rivet. Boundaries that must hold:

- CompCert comes **only** from `devcontainer.CompCert` release artifacts,
  pinned in `compcert.lock`. Never add a CompCert submodule or a Rocq
  dependency here.
- rivet is the `vendor/rivet` submodule and is used only through its public
  `rivet.<library>` / `rivet-tools.*` names. Changes to rivet go to rivet.
- Regenerating fixtures or corpora must reproduce the committed bytes
  (`git diff --exit-code`); ccomp records its command line in every `.s`, so the
  invocation paths are part of the contract (see `docs/fixture-oracle.md`).
- Anything CompCert-derived stays under `fixtures/`, `embed/`, `adapter/` and
  `_compcert/`, covered by `LICENSE.CompCert`.

`make build`, `make test`, `make compcert-fetch` are the entry points; CI runs
the same goals.
