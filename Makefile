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

# {1 The tool project}

TOOLS_EXE := $(CURDIR)/_build/default/tools/bin/rivet_compcert_tools.exe
ASM_EXE   := $(CURDIR)/_build/default/vendor/rivet/tool/asm.exe

# Targeted rather than @all, so a check that only reads committed files never
# waits for the assembler.
tools-build: submodules
	opam exec -- dune build tools/bin/rivet_compcert_tools.exe

# The corpus tests run the real assembler, so it is built first.
tools-test: tools-build
	opam exec -- dune build @tools/runtest

asm-build: submodules
	opam exec -- dune build vendor/rivet/tool/asm.exe

# {1 Fixtures}
#
# fixtures/compcert-3.17 holds ccomp output for the C fixtures
# (fixtures/c) and the GNU and QEMU evidence recorded for it.
# fixtures-check reads only committed files.

fixtures-check: tools-build
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture check

# One target's whole leg, in the one order that makes the evidence chain hold:
# exact regeneration with the pinned ccomp, GNU oracle, QEMU execution, manifest
# completeness, clean tree. --check before git diff because git diff cannot see
# an untracked file.
FIXTURE_ORACLE_GOALS := $(addprefix fixture-oracle-,$(TARGETS))
.PHONY: $(FIXTURE_ORACLE_GOALS)
$(FIXTURE_ORACLE_GOALS): fixture-oracle-%: ccomp-% tools-build
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture verify -- $*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture oracle -- $*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture exec -- $*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture check
	git diff --exit-code -- fixtures/compcert-3.17

fixture-oracle:
	@for t in $(TARGETS); do $(MAKE) fixture-oracle-$$t || exit 1; done

# A regeneration difference is a reviewed failure, not a refresh.
fixtures-regen: tools-build
	$(MAKE) $(addprefix ccomp-,$(TARGETS))
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture regen

# The GNU oracle for the committed .s files. Needs the cross binutils, not ccomp.
tools-oracle-diff: tools-build
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) fixture oracle all
	@test -z "$$(git status --porcelain -- fixtures/compcert-3.17)" || { \
	  git status --porcelain -- fixtures/compcert-3.17; \
	  echo "oracle artifacts changed - review the diff above" >&2; exit 1; }

# {1 The corpora}
#
# CompCert's own test suites, classified against rivet. The *-check goals read
# committed manifests; corpus-classify-<target> regenerates that target's
# corpora from the pinned artifacts and requires them unchanged.

corpus-check: tools-build
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus check
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus check-assemble
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus check-regression
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus check-compression
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus check-c-gcc

CORPUS_CLASSIFY_GOALS := $(addprefix corpus-classify-,$(TARGETS))
.PHONY: $(CORPUS_CLASSIFY_GOALS)
$(CORPUS_CLASSIFY_GOALS): corpus-classify-%: ccomp-% tools-build asm-build
	scripts/corpus-view.sh $*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus classify-c-$*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus assemble-c-$*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus classify-regression-$*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus classify-compression-$*
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) corpus classify-c-gcc-$*
	git diff --exit-code -- fixtures/corpus

.PHONY: default fmt-ocamlformat submodules build fmt fmt-check compcert-fetch compcert-bump \
  tools-build tools-test asm-build fixtures-check fixture-oracle fixtures-regen tools-oracle-diff \
  corpus-check
