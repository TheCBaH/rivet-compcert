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

CORPUS_ROOT="$REPO_ROOT/asm/fixtures/compcert-3.17"

Fatal() { echo "FATAL: $*" 1>&2; exit 1; }
usage() { echo "Usage: $0 <target|all> [case ...]" 1>&2; }

all_cases() {
  ( cd "$CORPUS_ROOT" && find . -mindepth 2 -maxdepth 2 -type d -name source \
      | sed -e 's|^\./||' -e 's|/source$||' | LC_ALL=C sort )
}

# The stem is the source basename, matching tools/asm-fixture-gen.sh: return42
# is built from asm_test_entry.c and its outputs are named for it.
case_stem() {
  local m="$CORPUS_ROOT/$1/manifest.txt" s=""
  [ -f "$m" ] && s=$(awk -F'\t' '$1 == "source" { print $2; exit }' "$m")
  [ -n "$s" ] || s="source/$1.c"
  basename "$s" .c
}

# The allocatable sections M2 lays out, in the order the artifacts list them.
ALLOC_SECTIONS=(.text .rodata .data)

# A hex dump of the raw section contents, 16 bytes per line, lower case. Plain
# `od` output carries an offset column in octal and a trailing duplicate-line
# marker; neither survives review well, so the format is fixed here.
hexdump_memory_order() {
  od -An -v -tx1 "$1" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//' | awk 'NF'
}

# {1 Relocation intent (.ai/asm_plan.md §11.3)}
#
# `objdump -r` groups records under a per-section banner and spells the addend
# into the symbol column as `sym+0xN` / `sym-0xN`. Normalizing to one
# tab-separated row per record - and dropping the .eh_frame records the .cfi_*
# directives produce, which we discard and never reproduce - is what makes the
# artifact reviewable and comparable field by field.
#
# The addend column is `-` on REL targets (x86-32, ARM), where it lives in the
# instruction field rather than the record; recovering it is per-relocation-kind
# work and belongs to the reader, not to this dump. Where RELA does carry one it
# is kept in signed hex exactly as objdump spelled it, which OCaml's
# Int64.of_string reads directly and which avoids depending on gawk's strtonum
# (this container's awk is mawk).
normalize_relocs() {
  # REL versus RELA cannot be read off `objdump -r`: its banner names the
  # section the relocations *apply to* (.text), not the section they live in
  # (.rela.text). readelf names the latter. The distinction is not decoration -
  # it is the difference between "the addend is 0" and "the addend is in the
  # instruction field", which O2 needs to recover an ARM split immediate.
  local kind=rel
  "${TOOLPREFIX}readelf" -SW "$1" | grep -qE '^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+\.rela\.' \
    && kind=rela

  "${TOOLPREFIX}objdump" -r "$1" | awk -v OFS='\t' -v kind="$kind" '
    # Trim to significant digits, then pad to 8. Fixed width makes a plain
    # lexicographic sort agree with address order, and makes a 32-bit and a
    # 64-bit target spell the same offset the same way.
    function pad8(h,   d) {
      d = h; sub(/^0+/, "", d); if (d == "") d = "0"
      while (length(d) < 8) d = "0" d
      return d
    }
    function trim(h,   d) { d = h; sub(/^0+/, "", d); return (d == "") ? "0" : d }
    /^RELOCATION RECORDS FOR/ {
      sec = $0; sub(/.*\[/, "", sec); sub(/\].*/, "", sec)
      next
    }
    /^OFFSET/ || /file format/ || NF == 0 { next }
    sec == ".text" || sec == ".rodata" || sec == ".data" {
      off = $1; type = $2; val = $3
      sym = val
      addend = (kind == "rela") ? "0x0" : "-"
      i = match(val, /[+-]0x[0-9a-f]+$/)
      if (i > 0) {
        sym = substr(val, 1, i - 1)
        addend = substr(val, i, 1) "0x" trim(substr(val, i + 3))
      }
      print sec, "0x" pad8(off), kind, type, sym, addend
    }
  ' | LC_ALL=C sort
}

# The symbol facts O1 classifies on - binding, visibility, defining section -
# recorded next to the records so a reviewer can see *why* GNU kept or resolved
# a reference without re-running readelf.
symbol_facts() {
  "${TOOLPREFIX}readelf" -sW "$1" | awk -v OFS='\t' '
    $1 ~ /^[0-9]+:$/ && $8 != "" {
      name = $8
      if (name == "" || name ~ /\.(c|s)$/) next
      bind = $5; vis = $6; ndx = $7
      defined = (ndx == "UND") ? "undefined" : "defined"
      print name, tolower(bind), tolower(vis), ndx, defined
    }
  ' | LC_ALL=C sort -u
}

run_one() {
  local target=$1 case=$2
  target_config "$target"
  local stem; stem=$(case_stem "$case")
  local fixture_root="$CORPUS_ROOT/$case"
  local src="$fixture_root/$target/$stem.s"
  [ -f "$src" ] || Fatal "no fixture for $case/$target (run tools/asm-fixture-gen.sh --regen)"
  command -v "${TOOLPREFIX}as" >/dev/null 2>&1 \
    || Fatal "${TOOLPREFIX}as not installed - the oracle needs the cross binutils"

  local out="$fixture_root/$target/oracle"
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

  normalize_relocs "$work/obj.o" > "$out/reloc.txt"
  symbol_facts "$work/obj.o" > "$out/symbols.txt"

  # {2 The controlled reference link (§11.3)}
  #
  # Unresolved placeholder bytes are not encodings, so a fixture whose .text
  # carries relocations cannot be byte-compared as an object. Both sides are
  # resolved at the same addresses instead, and those addresses are the ones
  # abi.ml gives the QEMU manifest - so the post-link artifact, our own bound
  # image and the executed program are all the same program.
  #
  # .eh_frame is discarded rather than placed: it is the only thing the .cfi_*
  # directives produce, we drop them at parse, and keeping it would add
  # relocations to an output we compare byte for byte.
  cat > "$work/link.ld" <<LD
ENTRY(asm_test_entry)
SECTIONS
{
  . = $LINK_TEXT_ADDR;
  .text : { *(.text) }
  . = $LINK_RODATA_ADDR;
  .rodata : { *(.rodata .rodata.*) }
  . = $LINK_DATA_ADDR;
  .data : { *(.data) }
  /DISCARD/ : { *(.eh_frame) *(.note.GNU-stack) *(.comment) *(.ARM.attributes) }
}
LD
  ( cd "$work" && "${TOOLPREFIX}ld" -static -T link.ld -o linked.elf obj.o )

  mkdir -p "$out/linked"
  rm -f "$out/linked"/*.hex
  local sec name present=()
  for sec in "${ALLOC_SECTIONS[@]}"; do
    name=${sec#.}
    if "${TOOLPREFIX}objcopy" --only-section="$sec" -O binary \
         "$work/linked.elf" "$work/$name.bin" 2>/dev/null \
       && [ -s "$work/$name.bin" ]; then
      hexdump_memory_order "$work/$name.bin" > "$out/linked/$name.hex"
      present+=("$sec")
    fi
  done
  {
    for sec in "${present[@]}"; do
      case "$sec" in
        .text) printf '%s\t%s\t%s\n' "$sec" "$LINK_TEXT_ADDR" "linked/text.hex" ;;
        .rodata) printf '%s\t%s\t%s\n' "$sec" "$LINK_RODATA_ADDR" "linked/rodata.hex" ;;
        .data) printf '%s\t%s\t%s\n' "$sec" "$LINK_DATA_ADDR" "linked/data.hex" ;;
      esac
    done
  } > "$out/linked/manifest.txt"

  {
    printf 'as\t%s\n' "$("${TOOLPREFIX}as" --version | head -1)"
    printf 'objdump\t%s\n' "$("${TOOLPREFIX}objdump" --version | head -1)"
    printf 'readelf\t%s\n' "$("${TOOLPREFIX}readelf" --version | head -1)"
    printf 'objcopy\t%s\n' "$("${TOOLPREFIX}objcopy" --version | head -1)"
    printf 'ld\t%s\n' "$("${TOOLPREFIX}ld" --version | head -1)"
  } > "$out/tool-versions.txt"

  local bytes relocs
  bytes=$(wc -c < "$work/text.bin")
  relocs=$(wc -l < "$out/reloc.txt")
  echo "$case/$target: .text $bytes bytes, $relocs relocation(s), sections ${present[*]}"
}

target=${1:-all}
shift || true
mapfile -t cases < <(if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else all_cases; fi)

case "$target" in
  all) for t in "${ALL_TARGETS[@]}"; do for c in "${cases[@]}"; do run_one "$t" "$c"; done; done ;;
  x86_32|x86_64|arm|aarch64) for c in "${cases[@]}"; do run_one "$target" "$c"; done ;;
  *) usage; exit 2 ;;
esac
