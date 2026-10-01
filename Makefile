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

# The GNU as outcome for CompCert's own assembly (fixtures/gas-frontier), re-recorded
# from the committed fixtures and the pinned export's runtime sources. It must
# leave the tree unchanged.
gas-frontier-diff: compcert-fetch tools-build
	RIVET_ROOT=$(CURDIR) $(TOOLS_EXE) gas-frontier regen
	@test -z "$$(git status --porcelain -- fixtures/gas-frontier)" || { \
	  git status --porcelain -- fixtures/gas-frontier; \
	  echo "gas-frontier changed - review the diff above" >&2; exit 1; }

$1
#
# CompCert's own test suites, classified against rivet. The *-check goals read
# committed manifests; corpus-classify-<target> regenerates that target's
# corpora from the pinned artifacts and requires them unchanged.

# The manifests record each source's hash under its logical modules/CompCert name,
# so even the check reads the sources through the corpus view (any target's
# unpacked suite is the same).
corpus-check: tools-build compcert-fetch
	scripts/corpus-view.sh x86_64
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

# {1 The CompCert adapter and the embedded compiler}
#
# Both link a CompCert library built from the export tarball (make ccomp-<t>),
# so they stay out of every default build behind the RIVET_COMPCERT_* gates.

INSTALL_LIB = $(CURDIR)/_compcert/$(1)/install/lib
EMBED_LIB   = $(CURDIR)/_compcert/$(1)/embed/_build/install/default/lib
HELPERS_DIR := $(CURDIR)/vendor/rivet/.asm-helpers

adapter-test: submodules ccomp-aarch64
	OCAMLPATH=$(call INSTALL_LIB,aarch64):$$OCAMLPATH \
	  COMPCERT_CONFIG=$(CURDIR)/_compcert/aarch64/install/share/compcert.ini \
	  RIVET_COMPCERT_ADAPTER=true opam exec -- dune build @adapter/runtest

# The environment that enables embed/ for one target: its variant on OCAMLPATH,
# the shared gate and the target's own. COMPCERT_CONFIG is unset on purpose: the
# variant must not need a compcert.ini.
embed_env = env -u COMPCERT_CONFIG \
  OCAMLPATH=$(call EMBED_LIB,$(1)):$$OCAMLPATH \
  RIVET_NATIVE_EXEC=true RIVET_COMPCERT_EMBED=true RIVET_COMPCERT_EMBED_$(shell echo $(1) | tr a-z A-Z)=true

# The target's library and its Tier A report (C to assembly to image against the
# committed fixtures), plus embed/test, which runs aarch64 code, on an aarch64 host.
EMBED_HOST_ISA := $(shell uname -m | sed -e 's/^amd64$$/x86_64/' -e 's/^arm64$$/aarch64/')
embed_suites = @embed/targets/$(1)/all @embed/targets/$(1)/runtest \
  $(if $(filter $(EMBED_HOST_ISA),$(1)),$(if $(filter aarch64,$(1)),@embed/test/runtest))

EMBED_BUILD_GOALS := $(addprefix embed-build-,$(TARGETS))
EMBED_TEST_GOALS  := $(addprefix embed-test-,$(TARGETS))
EMBED_QEMU_GOALS  := $(addprefix embed-qemu-,$(TARGETS))
EMBED_SOAK_GOALS  := $(addprefix embed-soak-,$(TARGETS))
.PHONY: $(EMBED_BUILD_GOALS) $(EMBED_TEST_GOALS) $(EMBED_QEMU_GOALS) $(EMBED_SOAK_GOALS) \
  embed-corpus-check helpers exec

$(EMBED_BUILD_GOALS): embed-build-%: compcert-fetch
	scripts/compcert-embed-sync.sh $*
	cd _compcert/$*/embed && opam exec -- dune build --root . @install

$(EMBED_TEST_GOALS): embed-test-%: submodules embed-build-%
	$(call embed_env,$*) opam exec -- dune build $(call embed_suites,$*)

# The embedded corpus under each target's QEMU; every result must equal the
# program's recorded expectation.
$(EMBED_QEMU_GOALS): embed-qemu-%: helpers
	$(call embed_env,$*) opam exec -- dune build embed/targets/$*/test/qemu_diff.exe
	RIVET_HELPERS_DIR=$(HELPERS_DIR) \
	  ./_build/default/embed/targets/$*/test/qemu_diff.exe embed/test/corpus

# SOAK_CYCLES compile+assemble cycles over the corpus in one process, each
# checked against its first compile.
SOAK_CYCLES ?= 10000
$(EMBED_SOAK_GOALS): embed-soak-%:
	$(call embed_env,$*) opam exec -- dune build embed/targets/$*/test/tier_a_test.exe
	./_build/default/embed/targets/$*/test/tier_a_test.exe --soak embed/test/corpus $(SOAK_CYCLES)

# Every corpus program's expectation against gcc for the host and each cross
# target. Needs the cross toolchains and QEMU.
embed-corpus-check:
	embed/test/corpus-expect.sh embed/test/corpus

# {1 Execution}

# The helpers are rivet's; its Makefile builds them.
helpers: submodules
	$(MAKE) -C vendor/rivet helpers

# The assembler's own image of each CompCert fixture, run under QEMU.
exec: helpers fixtures-check
	opam exec -- dune build test/exec/exec.exe
	RIVET_HELPERS_DIR=$(HELPERS_DIR) ./_build/default/test/exec/exec.exe

.PHONY: default fmt-ocamlformat submodules build fmt fmt-check compcert-fetch compcert-bump \
  tools-build tools-test asm-build fixtures-check fixture-oracle fixtures-regen tools-oracle-diff \
  corpus-check adapter-test gas-frontier-diff
