# CompCert integration for rivet. See README.md.

default: build

OCAMLFORMAT_VERSION := $(shell awk -F' *= *' '/^version/{print $$2}' .ocamlformat)

fmt-ocamlformat:
	opam install -y ocamlformat.$(OCAMLFORMAT_VERSION)

submodules:
	@test -f vendor/rivet/dune-project || { \
	  echo "vendor/rivet is not checked out; run: git submodule update --init vendor/rivet" >&2; exit 1; }
	@test -f vendor/rivet/vendor/fmt/upstream/src/fmt.ml || \
	  git -C vendor/rivet submodule update --init --depth 1 vendor/fmt/upstream vendor/err_trace/upstream

build: submodules
	opam exec -- dune build @all

fmt: fmt-ocamlformat
	opam exec -- dune build @fmt --auto-promote

fmt-check: fmt-ocamlformat
	opam exec -- dune build @fmt

COMPCERT_REPO := $(shell awk '$$1 == "repo" { print $$2 }' compcert.lock)
TARGETS := x86_32 x86_64 arm aarch64 riscv32 riscv64

# Downloads and verifies the artifacts pinned in compcert.lock (scripts/fetch-compcert.sh).
compcert-fetch:
	scripts/fetch-compcert.sh all

# Repins to another release of the extractor: make compcert-bump TAG=v3.17-2
compcert-bump:
	@test -n "$(TAG)" || { echo "usage: make compcert-bump TAG=<tag>" >&2; exit 1; }
	curl -fsSL -o compcert.lock.sums \
	  https://github.com/$(COMPCERT_REPO)/releases/download/$(TAG)/SHA256SUMS
	{ printf 'tag %s\nrepo %s\n' $(TAG) $(COMPCERT_REPO); cat compcert.lock.sums; } > compcert.lock
	rm compcert.lock.sums

# ccomp, its runtime and the compcert_<target> library, from the export tarball.
CCOMP_GOALS := $(addprefix ccomp-,$(TARGETS))
.PHONY: $(CCOMP_GOALS)
$(CCOMP_GOALS): ccomp-%:
	scripts/build-ccomp.sh $*

.PHONY: default fmt-ocamlformat submodules build fmt fmt-check compcert-fetch compcert-bump
