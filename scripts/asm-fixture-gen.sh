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
#   --regen   requires all six compilers, regenerates, and fails on any
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
CORPUS_ROOT="$REPO_ROOT/asm/fixtures/compcert-3.17"

usage() {
  echo "Usage: $0 --check | --regen | --rehash [case ...]" >&2
  echo "       $0 --verify <target> [case ...]" >&2
}
Fatal() { echo "FATAL: $*" 1>&2; exit 1; }

# {1 The case list}
#
# One directory per case, each with its own source/, per-target outputs and
# manifest. A case is anything under the corpus root that has a source/
# directory, so adding a fixture is adding a directory - there is no list to
# forget to update. The order is LC_ALL=C so every artifact and log is
# reproducible.
all_cases() {
  ( cd "$CORPUS_ROOT" && find . -mindepth 2 -maxdepth 2 -type d -name source \
      | sed -e 's|^\./||' -e 's|/source$||' | LC_ALL=C sort )
}

# Sets FIXTURE_ROOT, MANIFEST, SOURCE_REL and STEM for one case.
#
# SOURCE_REL comes from the committed manifest when there is one, and only
# falls back to source/<case>.c for a case being generated for the first time.
# Deriving it rather than fixing it is what lets return42 keep the
# asm_test_entry.c spelling its committed bytes were generated with: CompCert
# writes the source path into the "# Command line:" banner, so renaming the
# file would change every one of that case's hashes.
case_config() {
  FIXTURE_ROOT="$CORPUS_ROOT/$1"
  MANIFEST="$FIXTURE_ROOT/manifest.txt"
  SOURCE_REL=""
  if [ -f "$MANIFEST" ]; then
    SOURCE_REL=$(awk -F'\t' '$1 == "source" { print $2; exit }' "$MANIFEST")
  fi
  [ -n "$SOURCE_REL" ] || SOURCE_REL="source/$1.c"
  STEM=$(basename "$SOURCE_REL" .c)
}

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

check_case() {
  case_config "$1"
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
    echo "fixtures: $1: $seen files match the manifest"
  fi
  return "$rc"
}

require_compilers() {
  local t missing=()
  for t in "${FIXTURE_TARGETS[@]}"; do
    [ -x "$WORK_ROOT/install/$t/bin/ccomp" ] || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    Fatal "no installed ccomp for: ${missing[*]} - run 'make asm-cross-setup' (it requires zero skips)"
  fi
}

# {2 Acceptance gates on the generated assembly}
#
# A generated fixture that silently loses the construct it exists to exercise
# is worse than no fixture: it passes every byte gate and proves nothing. These
# run on --regen, and a failure means the C source must change, not the gate.
#
# Uninitialized globals become .comm (and .local + .comm for statics), and an
# all-zero initializer is routed to .bss - both of which are M3, so a fixture
# that reaches them has drifted out of M2's scope.
#
# A same-file call written as `return callee(x);` becomes a tail branch on
# x86-64, ARM and AArch64, which is exactly the relocation the direct-call
# fixture exists to produce. Requiring the call instruction by name is the only
# way to notice.
gate_case() {
  local c=$1 t rc=0 f
  for t in "${FIXTURE_TARGETS[@]}"; do
    f="$CORPUS_ROOT/$c/$t/$STEM.s"
    if grep -qE '^[[:space:]]*\.(comm|local)\b' "$f"; then
      echo "GATE $c/$t: .comm/.local is M3 scope; give the global a non-zero initializer" >&2; rc=1
    fi
    if grep -qE '^[[:space:]]*\.bss\b|[@%]nobits' "$f"; then
      echo "GATE $c/$t: .bss/nobits is M3 scope; give the global a non-zero initializer" >&2; rc=1
    fi
    if [ "$c" = "direct_call" ] && ! grep -qE '^[[:space:]]*(call|bl)[[:space:]]' "$f"; then
      echo "GATE $c/$t: no call/bl - the call was tail-converted; make the call site non-tail" >&2; rc=1
    fi
    if ! grep -qE '^asm_test_entry:' "$f"; then
      echo "GATE $c/$t: no asm_test_entry label - every execution fixture needs the frozen entry" >&2; rc=1
    fi
  done
  return "$rc"
}

regen_case() {
  case_config "$1"
  [ -f "$FIXTURE_ROOT/$SOURCE_REL" ] || Fatal "missing fixture source $FIXTURE_ROOT/$SOURCE_REL"

  local t
  for t in "${FIXTURE_TARGETS[@]}"; do
    target_config "$t"
    mkdir -p "$FIXTURE_ROOT/$t"
    # Generated from *inside* the fixture directory with relative paths, so
    # CompCert's "# Command line:" header is reproducible: an absolute path
    # would embed this checkout's location in the committed bytes.
    ( cd "$FIXTURE_ROOT" \
      && "$WORK_ROOT/install/$t/bin/ccomp" -S "${CCOMP_EXTRA_ARGS[@]}" \
           -o "$t/$STEM.s" "$SOURCE_REL" )
  done
  gate_case "$1"
  write_manifest
}

# Regenerate one profile in scratch storage, preserving the relative command
# line embedded by CompCert, and compare it byte-for-byte with the committed
# source assembly.  This is deliberately profile-local so RV32 and RV64 oracle
# jobs do not depend on one another.
verify_case() {
  case_config "$1"
  local target=$VERIFY_TARGET
  local compiler="$WORK_ROOT/install/$target/bin/ccomp"
  local scratch
  scratch=$(mktemp -d)
  mkdir -p "$scratch/$(dirname "$SOURCE_REL")" "$scratch/$target"
  cp "$FIXTURE_ROOT/$SOURCE_REL" "$scratch/$SOURCE_REL"
  target_config "$target"
  (cd "$scratch" && "$compiler" -S "${CCOMP_EXTRA_ARGS[@]}" \
    -o "$target/$STEM.s" "$SOURCE_REL")
  if ! cmp -s "$scratch/$target/$STEM.s" "$FIXTURE_ROOT/$target/$STEM.s"; then
    diff -u "$FIXTURE_ROOT/$target/$STEM.s" "$scratch/$target/$STEM.s" || true
    rm -rf "$scratch"
    Fatal "fixture regeneration differs for $1/$target"
  fi
  rm -rf "$scratch"
  echo "fixtures: $1/$target regenerates byte-identically"
}

# Recompute the manifest without recompiling. Used after tools/asm-fixture-oracle.sh
# adds the oracle artifacts, so that --check covers those bytes too rather than
# reporting them as UNRECORDED forever. It reports differences exactly as
# --regen does: if a fixture .s changed here, something regenerated it behind
# our back and that is a finding, not a refresh.
rehash_case() {
  case_config "$1"
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
    for t in "${FIXTURE_TARGETS[@]}"; do
      target_config "$t"
      if [ -x "$WORK_ROOT/install/$t/bin/ccomp" ]; then
        v=$("$WORK_ROOT/install/$t/bin/ccomp" -version 2>&1 | head -1)
        printf 'ccomp-version:%s\t%s\n' "$t" "$(esc "$v")"
      elif [ -f "$MANIFEST" ]; then
        grep "^ccomp-version:$t	" "$MANIFEST" || true
      fi
      printf 'ccomp-target:%s\t%s\n' "$t" "$CONFIGURE_TARGET"
      if [ "${#CCOMP_EXTRA_ARGS[@]}" -eq 0 ]; then
        printf 'ccomp-args:%s\n' "$t"
      else
        printf 'ccomp-args:%s\t%s\n' "$t" "${CCOMP_EXTRA_ARGS[*]}"
      fi
      if [ "${#COMPCERT_CONFIGURE_ARGS[@]}" -eq 0 ]; then
        printf 'ccomp-configure-args:%s\n' "$t"
      else
        printf 'ccomp-configure-args:%s\t%s\n' "$t" "${COMPCERT_CONFIGURE_ARGS[*]}"
      fi
    done
    local f
    while IFS= read -r f; do
      printf 'sha256:%s\t%s\n' "$f" "$(hash_of "$FIXTURE_ROOT/$f")"
    done < <(fixture_files)
  } | LC_ALL=C sort > "$MANIFEST.new"

  if [ -f "$MANIFEST" ] && ! diff -u "$MANIFEST" "$MANIFEST.new" > "$MANIFEST.diff"; then
    mv "$MANIFEST.new" "$MANIFEST"
    echo "fixtures: manifest CHANGED - review the differences, they change the tested scope" >&2
    cat "$MANIFEST.diff" >&2
    rm -f "$MANIFEST.diff"
    return 1
  fi
  rm -f "$MANIFEST.diff"
  mv "$MANIFEST.new" "$MANIFEST"
  echo "fixtures: $(basename "$FIXTURE_ROOT"): manifest up to date"
}

# Every mode runs over every case unless named ones are given, and one case's
# failure must not hide another's: the loop records the worst status rather
# than exiting at the first.
run_over_cases() {
  local fn=$1; shift
  local cases=("$@") rc=0 c
  if [ "${#cases[@]}" -eq 0 ]; then
    mapfile -t cases < <(all_cases)
    [ "${#cases[@]}" -gt 0 ] || Fatal "no cases under $CORPUS_ROOT"
  fi
  for c in "${cases[@]}"; do
    [ -d "$CORPUS_ROOT/$c" ] || Fatal "no such case '$c' under $CORPUS_ROOT"
    "$fn" "$c" || rc=1
  done
  return "$rc"
}

mode="${1:-}"
[ "$#" -gt 0 ] && shift
case "$mode" in
  --check) run_over_cases check_case "$@" ;;
  --regen) require_compilers; run_over_cases regen_case "$@" ;;
  --rehash) run_over_cases rehash_case "$@" ;;
  --verify)
    [ "$#" -gt 0 ] || { usage; exit 2; }
    VERIFY_TARGET=$1; shift
    case "$VERIFY_TARGET" in
      riscv32|riscv64) ;;
      *) Fatal "--verify supports riscv32 or riscv64, got '$VERIFY_TARGET'" ;;
    esac
    [ -x "$WORK_ROOT/install/$VERIFY_TARGET/bin/ccomp" ] \
      || Fatal "no installed ccomp for $VERIFY_TARGET - run tools/compcert-riscv-fixture-setup.sh $VERIFY_TARGET"
    run_over_cases verify_case "$@"
    ;;
  *) usage; exit 2 ;;
esac
