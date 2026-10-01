# rivet-compcert

Runs [CompCert](https://github.com/AbsInt/CompCert) against
[rivet](https://github.com/TheCBaH/rivet), the retargetable assembler: CompCert's
assembly output is assembled by rivet and compared with GNU `as` and with QEMU
execution, and CompCert's extracted OCaml is embedded in-process behind rivet's
driver.

## Data flow

```
TheCBaH/devcontainer.CompCert  --release v3.17-2-->  compcert.lock  --make compcert-fetch-->  _compcert/<target>/
TheCBaH/rivet                  --submodule------->   vendor/rivet
```

- **CompCert arrives only as release artifacts** of
  [devcontainer.CompCert](https://github.com/TheCBaH/devcontainer.CompCert):
  per target, `compcert-export-<target>` (the extracted OCaml, a portable
  `compcert.ini` and the runtime) and `compcert-asm-<target>` (CompCert's
  assembly for its own test programs). `compcert.lock` pins the tag and every
  tarball's SHA-256; `scripts/fetch-compcert.sh` verifies them. There is no
  CompCert submodule and no Rocq in the toolchain.
- **rivet is a submodule** at `vendor/rivet`, used through its public
  `rivet.<library>` names and its `rivet-tools` command-line libraries.

## Use

```sh
make compcert-fetch          # download and verify the pinned artifacts
make ccomp-aarch64           # build ccomp from the aarch64 export tarball
make build tools-test        # build everything, run the tool and corpus tests
make fixtures-check corpus-check   # committed evidence, no toolchain needed
make fixture-oracle-aarch64  # regenerate one target's fixtures, GNU oracle, QEMU
make embed-test-aarch64      # the embedded compiler for one target
make adapter-test            # the aarch64 adapter
make gas-frontier-diff       # GNU as outcome for CompCert's own assembly
make compcert-bump TAG=v3.17-3   # repin to another extractor release
```

Every regeneration goal ends in `git diff`: the committed bytes must reproduce
from the pinned artifacts. CI (`.github/workflows/ci.yml`) runs `check`,
`oracle-diff`, `fixture-oracle` and `compcert-embed` per target,
`compcert-embed-corpus` and `adapter`; `corpus-regen` is a manual dispatch.

`docs/fixture-oracle.md` and `docs/corpus.md` describe the evidence chain and
the corpora.

## License

The tooling in this repository is MIT licensed (`LICENSE`). **Content derived
from CompCert is not**: the committed CompCert assembly under `fixtures/`, the
CompCert runtime copies, the files in `_compcert/` and the embedded CompCert
OCaml are covered by CompCert's own non-commercial license, reproduced in
`LICENSE.CompCert`. Check that license before using any of them commercially.
