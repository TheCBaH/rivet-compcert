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

.PHONY: default fmt-ocamlformat submodules build fmt fmt-check
