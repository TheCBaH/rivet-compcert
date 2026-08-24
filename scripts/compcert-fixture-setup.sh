#!/usr/bin/env bash
# Build freestanding CompCert fixture generators for every fixture profile.
# These installations are intentionally compile-to-assembly only: neither a
# target libc nor a compiler-driver link is part of the fixture contract, which
# is what lets RV32/RV64 participate on equal terms with the four profiles that
# do have a sysroot.
#
# Work root: FIXTURE_WORK, default <repo>/.fixture-work. This is deliberately
# NOT .cross-smoke-work: tools/compcert-cross-smoke.sh recreates
# build/install/artifacts destructively for its four targets, and a shared root
# meant either suite could delete the other's evidence mid-run.
#
# Unlike the libc cross-smoke suite, nothing here skips. A missing tool is a
# missing piece of evidence, and the fixture oracle exists to produce evidence.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
COMPCERT_DIR="$REPO_ROOT/modules/CompCert"
WORK_ROOT="${FIXTURE_WORK:-$REPO_ROOT/.fixture-work}"
JOBS="${COMPCERT_JOBS:-$(nproc)}"

# shellcheck source=target-matrix.sh
. "$SCRIPT_DIR/target-matrix.sh"

Fatal() { echo "FATAL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [<target>|all]  (targets: ${FIXTURE_TARGETS[*]})" >&2; }
Opam() { if command -v opam >/dev/null 2>&1; then opam exec -- "$@"; else "$@"; fi; }

missing=()

# Everything this target's whole oracle leg will invoke - the configure probe,
# the binutils the GNU differential oracle and the executor use, and the
# emulator. Checked here rather than at first use so a CI leg cannot spend a
# Rocq build before discovering that its qemu is absent.
preflight_target() {
  local target=$1 tool probe
  target_config "$target"

  # Both RISC-V profiles go through riscv-gcc-wrapper.sh (see run_target
  # below), which bakes the exact march/mabi this project needs into the
  # probe rather than trusting each toolchain's default multilib selection;
  # the wrapper execs each profile's own dedicated cross-gcc (TOOLPREFIX), so
  # the probe binary to check for here is the same as every other target's.
  probe="${TOOLPREFIX}gcc"

  for tool in "$probe" "${TOOLPREFIX}as" "${TOOLPREFIX}ld" \
              "${TOOLPREFIX}readelf" "${TOOLPREFIX}objcopy" \
              "${TOOLPREFIX}objdump" "$QEMU_BIN"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$target:$tool")
  done
}

run_target() {
  local target=$1
  target_config "$target"

  local build="$WORK_ROOT/build/$target"
  local install="$WORK_ROOT/install/$target"
  local artifacts="$WORK_ROOT/artifacts/$target"
  local wrappers="$WORK_ROOT/tool-wrappers"

  rm -rf "$build" "$install" "$artifacts"
  mkdir -p "$install" "$artifacts" "$wrappers"
  echo "== [$target] mirroring CompCert source tree =="
  (cd "$COMPCERT_DIR" && ./tools/linkhier "$build")

  # CompCert prefixes every probe tool with -toolprefix.  For RISC-V that
  # prefix has to name a project-owned wrapper: an absolute prefix ending in
  # "$target-" selects the gcc link below, which bakes -march/-mabi into the
  # configured compiler while leaving the GNU RISC-V tools used later
  # unambiguous. The other four profiles have a real prefixed toolchain and
  # need no shim.
  local configure=(-prefix "$install")
  case "$target" in
    riscv32 | riscv64)
      local probe_prefix="$wrappers/$target-"
      ln -sfn "$SCRIPT_DIR/riscv-gcc-wrapper.sh" "${probe_prefix}gcc"
      configure+=(-toolprefix "$probe_prefix")
      ;;
    *)
      configure+=(-toolprefix "$TOOLPREFIX")
      ;;
  esac
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
if [ "$requested" = "all" ]; then
  targets=("${FIXTURE_TARGETS[@]}")
else
  targets=()
  for t in "${FIXTURE_TARGETS[@]}"; do
    [ "$t" = "$requested" ] && targets=("$t")
  done
  [ "${#targets[@]}" -eq 1 ] || { usage; Fatal "unknown fixture profile '$requested'"; }
fi

# Two loops, and the order is the point: for `all`, checking inside run_target
# would let earlier targets delete and rebuild their trees before a later
# target's missing tool was discovered.
for t in "${targets[@]}"; do preflight_target "$t"; done
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'FATAL: missing tools (target:tool):\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

for t in "${targets[@]}"; do run_target "$t"; done
