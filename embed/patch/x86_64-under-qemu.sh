#!/usr/bin/env bash
# Run OCaml bytecode as an x86_64 process under qemu-x86_64, on a host of
# another ISA. This is how asm-compcert-embed-x86_64-under-qemu exercises
# native_exec's in-process execution of x86_64 code without an x86_64
# machine: the bytecode is portable, and only the OCaml runtime and the C
# stubs it loads have to be x86_64.
#
#   x86_64-under-qemu.sh setup
#       Cross-build, into $WORK, the bytecode runtime (ocamlrun) of the
#       installed OCaml version and the stub libraries the embed's bytecode
#       programs load: unix, str, native_exec, and the ppx_inline_test /
#       ppx_expect / base / time_now stubs the inline-test runner needs,
#       from their sources at the installed versions. Needs
#       x86_64-linux-gnu-gcc, network access for the sources, and opam.
#   x86_64-under-qemu.sh run <program.bc> [args...]
#       Run a bytecode program under qemu-x86_64 with those libraries.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORK="${X86_64_UNDER_QEMU_WORK:-$REPO_ROOT/.x86_64-under-qemu}"
CC=x86_64-linux-gnu-gcc
SYSROOT=/usr/x86_64-linux-gnu

Fatal() { echo "FATAL: $*" >&2; exit 1; }
Opam() { opam exec -- "$@"; }

ocaml_version=$(Opam ocamlc -version)
ocaml_src="$WORK/ocaml-$ocaml_version"
stublibs="$WORK/stublibs"

setup() {
  command -v "$CC" > /dev/null || Fatal "$CC not found"
  command -v qemu-x86_64 > /dev/null || Fatal "qemu-x86_64 not found"
  mkdir -p "$WORK" "$stublibs"

  # The bytecode runtime. Its build runs a helper, sak, on the build machine,
  # so that one is built with the host compiler.
  if [ ! -x "$ocaml_src/runtime/ocamlrun" ]; then
    rm -rf "$ocaml_src"
    curl -fsSL "https://github.com/ocaml/ocaml/archive/refs/tags/$ocaml_version.tar.gz" |
      tar xz -C "$WORK"
    (cd "$ocaml_src" &&
      ./configure --host=x86_64-linux-gnu --disable-native-compiler --disable-ocamldoc \
        --disable-debugger > "$WORK/configure.log" 2>&1 &&
      make -C runtime SAK_CC=gcc 'SAK_LINK=gcc -o $(1) $(2)' -j"$(nproc)" ocamlrun \
        > "$WORK/runtime.log" 2>&1) ||
      Fatal "building the x86_64 runtime failed; see $WORK/*.log"
  fi

  # Package sources at exactly the installed versions.
  for p in base time_now ppx_inline_test ppx_expect; do
    v=$(opam list --installed --columns=version --short "$p")
    [ -d "$WORK/src-$p-$v" ] || opam source "$p.$v" --dir="$WORK/src-$p-$v" > /dev/null ||
      Fatal "cannot fetch the source of $p.$v"
  done
  src() { echo "$WORK/src-$1-$(opam list --installed --columns=version --short "$1")"; }

  dll() { # dll <name> <cflags...> -- <sources...>
    local name=$1; shift
    local flags=()
    while [ "$1" != -- ]; do flags+=("$1"); shift; done
    shift
    "$CC" -shared -fPIC -O2 -D_FILE_OFFSET_BITS=64 -I "$ocaml_src/runtime" "${flags[@]}" \
      -o "$stublibs/dll$name.so" "$@" || Fatal "building dll$name.so failed"
  }
  dll unix -I "$ocaml_src/otherlibs/unix" -- "$ocaml_src"/otherlibs/unix/*.c
  dll camlstr -- "$ocaml_src/otherlibs/str/strstubs.c"
  dll native_exec_stubs -- "$REPO_ROOT/asm/native_exec/native_exec_stubs.c"
  # base's own [Base_am_testing] is a weak "false" that a statically linked
  # test runner overrides; stub DLLs are searched in an order that does not
  # guarantee the override, so this test-only build leaves the default out
  # and the runner's "true" is the only definition.
  local base; base=$(src base)
  dll base_internalhash_types_stubs -- "$base/hash_types/src/internalhash_stubs.c"
  dll base_stubs -I "$base/hash_types/src" -- \
    "$base"/src/bytes_stubs.c "$base"/src/int_math_stubs.c "$base"/src/exn_stubs.c \
    "$base"/src/hash_stubs.c
  # time_now's jane-street-headers include <caml/unixsupport.h> and <caml/threads.h>, which
  # an installed OCaml provides and the source tree keeps in otherlibs
  mkdir -p "$WORK/include/caml"
  cp "$ocaml_src/otherlibs/unix/unixsupport.h" "$ocaml_src/otherlibs/systhreads/threads.h" \
    "$WORK/include/caml/"
  dll time_now_stubs -std=c11 -I "$WORK/include" -I "$(opam var lib)/jst-config" \
    -I "$(opam var lib)/jane-street-headers" -- \
    "$(src time_now)/src/time_now_stubs.c"
  dll ppx_inline_test_runner_lib_stubs -- "$(src ppx_inline_test)/runner/lib/am_testing.c"
  dll expect_test_collector_stubs -- "$(src ppx_expect)/collector/expect_test_collector_stubs.c"
  echo "== x86_64 runtime and stubs ready in $WORK =="
}

run() {
  [ -x "$ocaml_src/runtime/ocamlrun" ] || Fatal "run '$0 setup' first"
  # the corpus check faults on purpose in a child; qemu-user would write a core file for it
  ulimit -c 0
  exec qemu-x86_64 -L "$SYSROOT" -E "CAML_LD_LIBRARY_PATH=$stublibs" \
    "$ocaml_src/runtime/ocamlrun" "$@"
}

case "${1:-}" in
  setup) setup ;;
  run) shift; run "$@" ;;
  *) Fatal "usage: $0 setup | run <program.bc> [args...]" ;;
esac
