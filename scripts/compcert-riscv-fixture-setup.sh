#!/usr/bin/env bash
# Build freestanding CompCert fixture generators for RV32 and RV64.  These
# installations are intentionally compile-to-assembly only: neither a RISC-V
# libc nor a compiler-driver link is part of the fixture contract.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
COMPCERT_DIR="$REPO_ROOT/modules/CompCert"
WORK_ROOT="${CROSS_SMOKE_WORK:-$REPO_ROOT/.cross-smoke-work}"
JOBS="${COMPCERT_JOBS:-$(nproc)}"

# shellcheck source=target-matrix.sh
. "$SCRIPT_DIR/target-matrix.sh"

Fatal() { echo "FATAL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [riscv32|riscv64|all]" >&2; }
Opam() { if command -v opam >/dev/null 2>&1; then opam exec -- "$@"; else "$@"; fi; }

run_target() {
  local target=$1
  target_config "$target"
  command -v riscv64-linux-gnu-gcc >/dev/null 2>&1 \
    || Fatal "riscv64-linux-gnu-gcc is required for $target configuration probes"

  local build="$WORK_ROOT/build/$target"
  local install="$WORK_ROOT/install/$target"
  local artifacts="$WORK_ROOT/artifacts/$target"
  local wrappers="$WORK_ROOT/tool-wrappers"

  rm -rf "$build" "$install" "$artifacts"
  mkdir -p "$install" "$artifacts" "$wrappers"
  echo "== [$target] mirroring CompCert source tree =="
  (cd "$COMPCERT_DIR" && ./tools/linkhier "$build")

  # CompCert prefixes every probe tool with -toolprefix.  Supplying an
  # absolute prefix ending in "$target-" selects the project-owned gcc link
  # above while leaving the GNU RISC-V tools used later unambiguous.
  local probe_prefix="$wrappers/$target-"
  ln -sfn "$SCRIPT_DIR/riscv-gcc-wrapper.sh" "${probe_prefix}gcc"
  local configure=(-prefix "$install" -toolprefix "$probe_prefix")
  configure+=("${COMPCERT_CONFIGURE_ARGS[@]}" "$CONFIGURE_TARGET")

  echo "== [$target] configuring freestanding compiler =="
  (cd "$build" && Opam ./configure "${configure[@]}")
  echo "== [$target] building freestanding compiler =="
  (cd "$build" && Opam make -j"$JOBS" all)
  (cd "$build" && Opam make install)

  [ -x "$install/bin/ccomp" ] || Fatal "missing installed compiler $install/bin/ccomp"
  "$install/bin/ccomp" -version | tee "$artifacts/ccomp-version.txt"
  cp "$build/Makefile.config" "$artifacts/Makefile.config"
  printf '%q ' "$build/configure" "${configure[@]}" > "$artifacts/configure-command.txt"
  printf '\n' >> "$artifacts/configure-command.txt"
}

requested=${1:-all}
case "$requested" in
  all) targets=(riscv32 riscv64) ;;
  riscv32|riscv64) targets=("$requested") ;;
  *) usage; Fatal "unknown RISC-V fixture profile '$requested'" ;;
esac

for target in "${targets[@]}"; do run_target "$target"; done
