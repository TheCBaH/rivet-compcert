#!/usr/bin/env bash
# The M1 walking-skeleton fixtures: `int asm_test_entry(void) { return 42; }`
# compiled by four unmodified CompCert configurations.
#
# Two separable entry points, per .ai/asm_plan.md §12's two-mode policy:
#
#   --check   verifies the committed bytes against the manifest hashes. Needs
#             NO cross toolchain at all - this is what every ordinary test run
#             uses, and it is why the portable CI legs can run in full on a
#             machine with no ccomp installed.
#
#   --regen   requires all four compilers, regenerates, and fails on any
#             unexplained difference. A reviewed change: regeneration can alter
#             accepted syntax, relocations, or instruction coverage, so a diff
#             here is a change to the M1 scope and not a refresh.
#
# --regen fails immediately if any installed ccomp is missing, naming
# `make asm-cross-setup` as the fix. It never falls back to
# modules/CompCert/ccomp: that binary is configured for whatever target was
# last built, so falling back would silently produce four copies of one
# target's output.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=target-matrix.sh
. "$SCRIPT_DIR/target-matrix.sh"

WORK_ROOT="${CROSS_SMOKE_WORK:-$REPO_ROOT/.cross-smoke-work}"
FIXTURE_ROOT="$REPO_ROOT/asm/fixtures/compcert-3.17/return42"
SOURCE_REL="source/asm_test_entry.c"
MANIFEST="$FIXTURE_ROOT/manifest.txt"

usage() { echo "Usage: $0 --check | --regen | --rehash" 1>&2; }
Fatal() { echo "FATAL: $*" 1>&2; exit 1; }

# The manifest is one key<TAB>value per line, keys sorted, values escaped for
# backslash, tab and newline. The primary record is the SHA-256 of the exact
# committed bytes: anything else (a compiler version string, a timestamp) can
# agree while the bytes differ.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\t/\\t/g' -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'; }

hash_of() { sha256sum "$1" | cut -d' ' -f1; }

# Every path recorded is relative to the fixture root, so the manifest says
# nothing about where this repository happens to live.
rel() { printf '%s' "${1#"$FIXTURE_ROOT"/}"; }

# manifest.txt* rather than manifest.txt: --regen writes manifest.txt.new
# alongside the fixtures before renaming it, and a plain exclusion would record
# that scratch file in the very manifest it is about to become.
fixture_files() {
  ( cd "$FIXTURE_ROOT" && find . -type f ! -name 'manifest.txt*' | sed 's|^\./||' | LC_ALL=C sort )
}

do_check() {
  [ -f "$MANIFEST" ] || Fatal "no manifest at $MANIFEST - run --regen first"
  local rc=0 seen=0
  while IFS=$'\t' read -r key value; do
    case "$key" in
      sha256:*)
        local path=${key#sha256:}
        seen=$((seen + 1))
        if [ ! -f "$FIXTURE_ROOT/$path" ]; then
          echo "MISSING $path" >&2; rc=1
        elif [ "$(hash_of "$FIXTURE_ROOT/$path")" != "$value" ]; then
          echo "CHANGED $path" >&2; rc=1
        fi
        ;;
    esac
  done < "$MANIFEST"

  # A file present in the tree but absent from the manifest is just as much a
  # divergence as a changed one: it would otherwise ride along unrecorded.
  local f
  while IFS= read -r f; do
    grep -q "^sha256:$f	" "$MANIFEST" || { echo "UNRECORDED $f" >&2; rc=1; }
  done < <(fixture_files)

  [ "$seen" -gt 0 ] || Fatal "manifest records no files"
  if [ "$rc" -eq 0 ]; then
    echo "fixtures: $seen files match the manifest"
  fi
  return "$rc"
}

do_regen() {
  local t missing=()
  for t in "${ALL_TARGETS[@]}"; do
    [ -x "$WORK_ROOT/install/$t/bin/ccomp" ] || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    Fatal "no installed ccomp for: ${missing[*]} - run 'make asm-cross-setup' (it requires zero skips)"
  fi

  [ -f "$FIXTURE_ROOT/$SOURCE_REL" ] || Fatal "missing fixture source $FIXTURE_ROOT/$SOURCE_REL"

  for t in "${ALL_TARGETS[@]}"; do
    target_config "$t"
    local outdir="$FIXTURE_ROOT/$t"
    mkdir -p "$outdir"
    # Generated from *inside* the fixture directory with relative paths, so
    # CompCert's "# Command line:" header is reproducible: an absolute path
    # would embed this checkout's location in the committed bytes.
    ( cd "$FIXTURE_ROOT" \
      && "$WORK_ROOT/install/$t/bin/ccomp" -S "${CCOMP_EXTRA_ARGS[@]}" \
           -o "$t/asm_test_entry.s" "$SOURCE_REL" )
  done
  write_manifest
}

# Recompute the manifest without recompiling. Used after tools/asm-fixture-oracle.sh
# adds the oracle artifacts, so that --check covers those bytes too rather than
# reporting them as UNRECORDED forever. It reports differences exactly as
# --regen does: if a fixture .s changed here, something regenerated it behind
# our back and that is a finding, not a refresh.
do_rehash() {
  [ -d "$FIXTURE_ROOT" ] || Fatal "no fixture tree at $FIXTURE_ROOT"
  write_manifest
}

# The provenance keys come from the manifest being replaced when no compiler is
# available, so --rehash does not silently drop them.
write_manifest() {
  local t v
  {
    echo "generator	tools/asm-fixture-gen.sh"
    echo "source	$SOURCE_REL"
    for t in "${ALL_TARGETS[@]}"; do
      target_config "$t"
      if [ -x "$WORK_ROOT/install/$t/bin/ccomp" ]; then
        v=$("$WORK_ROOT/install/$t/bin/ccomp" -version 2>&1 | head -1)
        printf 'ccomp-version:%s\t%s\n' "$t" "$(esc "$v")"
      elif [ -f "$MANIFEST" ]; then
        grep "^ccomp-version:$t	" "$MANIFEST" || true
      fi
      printf 'ccomp-target:%s\t%s\n' "$t" "$CONFIGURE_TARGET"
      printf 'ccomp-args:%s\t%s\n' "$t" "${CCOMP_EXTRA_ARGS[*]:-}"
    done
    local f
    while IFS= read -r f; do
      printf 'sha256:%s\t%s\n' "$f" "$(hash_of "$FIXTURE_ROOT/$f")"
    done < <(fixture_files)
  } | LC_ALL=C sort > "$MANIFEST.new"

  if [ -f "$MANIFEST" ] && ! diff -u "$MANIFEST" "$MANIFEST.new" > "$MANIFEST.diff"; then
    mv "$MANIFEST.new" "$MANIFEST"
    echo "fixtures: manifest CHANGED - review the differences, they change the M1 scope" >&2
    cat "$MANIFEST.diff" >&2
    rm -f "$MANIFEST.diff"
    return 1
  fi
  rm -f "$MANIFEST.diff"
  mv "$MANIFEST.new" "$MANIFEST"
  echo "fixtures: manifest up to date"
}

case "${1:-}" in
  --check) do_check ;;
  --regen) do_regen ;;
  --rehash) do_rehash ;;
  *) usage; exit 2 ;;
esac
