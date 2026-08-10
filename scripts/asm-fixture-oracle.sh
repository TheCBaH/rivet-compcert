#!/usr/bin/env bash
# The reference-assembler oracle for one fixture (.ai/asm_plan.md M0.2).
#
# Runs the target's GNU `as` over the committed fixture and records what it
# produced: section headers, symbols, relocations, disassembly, and the .text
# bytes. These artifacts are what M1.5's differential gate compares our own
# encoder against, so they are committed and reviewed rather than recomputed
# on the fly.
#
# Two normalizations matter and both are about making a diff mean something:
#
#   - absolute paths, the object filename and tool banners are stripped, so the
#     artifacts do not encode where this checkout lives or which binutils build
#     produced them. Exact versions go to oracle/tool-versions.txt instead,
#     where a change is visible as a change rather than as noise on every line.
#
#   - .text is dumped in **memory order**. objdump prints ARM and AArch64
#     instruction *words*, and both are little-endian, so AArch64 910003ef is
#     ef 03 00 91 in memory. Comparing word order against our byte-oriented
#     encoder would appear to work and be wrong.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=target-matrix.sh
. "$SCRIPT_DIR/target-matrix.sh"

FIXTURE_ROOT="$REPO_ROOT/asm/fixtures/compcert-3.17/return42"

Fatal() { echo "FATAL: $*" 1>&2; exit 1; }
usage() { echo "Usage: $0 <target|all>" 1>&2; }

# A hex dump of the raw section contents, 16 bytes per line, lower case. Plain
# `od` output carries an offset column in octal and a trailing duplicate-line
# marker; neither survives review well, so the format is fixed here.
hexdump_memory_order() {
  od -An -v -tx1 "$1" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//' | awk 'NF'
}

run_one() {
  local target=$1
  target_config "$target"
  local src="$FIXTURE_ROOT/$target/asm_test_entry.s"
  [ -f "$src" ] || Fatal "no fixture for $target (run tools/asm-fixture-gen.sh --regen)"
  command -v "${TOOLPREFIX}as" >/dev/null 2>&1 \
    || Fatal "${TOOLPREFIX}as not installed - the oracle needs the cross binutils"

  local out="$FIXTURE_ROOT/$target/oracle"
  mkdir -p "$out"
  local work
  work=$(mktemp -d); trap 'rm -rf "$work"' RETURN

  # Assembled as `obj.o` in a scratch directory, so neither the object name nor
  # its path can reach the recorded output.
  ( cd "$work" && "${TOOLPREFIX}as" -o obj.o "$src" )

  "${TOOLPREFIX}readelf" -SWsWr "$work/obj.o" \
    | sed -e "s|$work/||g" -e 's/^File: .*$//' \
    | awk 'NF || p { print } { p = NF }' > "$out/readelf.txt"

  "${TOOLPREFIX}objdump" -dr "$work/obj.o" \
    | sed -e "s|$work/||g" -e '1,2d' \
    > "$out/objdump.txt"

  "${TOOLPREFIX}objcopy" --only-section=.text -O binary "$work/obj.o" "$work/text.bin"
  hexdump_memory_order "$work/text.bin" > "$out/text.hex"

  {
    printf 'as\t%s\n' "$("${TOOLPREFIX}as" --version | head -1)"
    printf 'objdump\t%s\n' "$("${TOOLPREFIX}objdump" --version | head -1)"
    printf 'readelf\t%s\n' "$("${TOOLPREFIX}readelf" --version | head -1)"
    printf 'objcopy\t%s\n' "$("${TOOLPREFIX}objcopy" --version | head -1)"
  } > "$out/tool-versions.txt"

  local bytes
  bytes=$(wc -c < "$work/text.bin")
  echo "$target: .text $bytes bytes -> $(printf '%s' "${out#"$REPO_ROOT"/}")"

  # The plan's fact, asserted rather than assumed: .text is relocation-free, so
  # M1.5's byte gate is a plain compare with no relocation protocol. The only
  # relocations in these objects are in .eh_frame, which we discard.
  if grep -qE '^RELOCATION RECORDS FOR \[\.text\]' "$out/objdump.txt"; then
    Fatal "$target: .text carries relocations - M1.5's byte gate assumes it does not"
  fi
}

case "${1:-all}" in
  all) for t in "${ALL_TARGETS[@]}"; do run_one "$t"; done ;;
  x86_32|x86_64|arm|aarch64) run_one "$1" ;;
  *) usage; exit 2 ;;
esac
