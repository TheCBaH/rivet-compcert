#!/usr/bin/env bash
# Build the embed variant of one target's CompCert library:
# _compcert/<target>/embed, dune package compcert_<target>_embed.
#
# The variant is the pristine src/ of the export tarball (make compcert-fetch),
# copied, plus the injected modules under embed/patch/ and a strict patch that
# adds one `open` line to each file whose I/O or configuration they shadow. The
# export itself is never modified, whose other consumers expect CompCert's
# ordinary file-based behavior.
#
# The patch applies with --fuzz=0 and fails on any reject, so a CompCert
# change that moves its anchors stops the sync instead of being guessed at.
# Every run starts from a fresh copy, so re-running is always safe.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
EMBED_DIR="$REPO_ROOT/embed/patch"

Fatal() { echo "FATAL: $*" >&2; exit 1; }

# shellcheck source=../vendor/rivet/scripts/target-matrix.sh
. "$REPO_ROOT/vendor/rivet/scripts/target-matrix.sh"

target="${1:-}"
found=false
for t in "${FIXTURE_TARGETS[@]}"; do
  [ "$t" = "$target" ] && found=true
done
[ "$found" = true ] || Fatal "usage: $0 <target>  (targets: ${FIXTURE_TARGETS[*]})"

pristine="$REPO_ROOT/_compcert/$target/export"
variant="$REPO_ROOT/_compcert/$target/embed"
# One patch for every target: the only per-target file it touches is
# TargetPrinter.ml, whose banner (the hunk's whole context) is the same in
# each architecture's directory.
patchfile="$EMBED_DIR/common.patch"
ini="$pristine/compcert.ini"

[ -f "$pristine/src/Compiler.ml" ] ||
  Fatal "no $pristine/src - run make compcert-fetch first"
[ -f "$ini" ] || Fatal "missing $ini - run make compcert-fetch first"

rm -rf "$variant"
mkdir -p "$variant/src"
cp "$pristine"/src/*.ml "$pristine"/src/*.mli "$variant/src/"

for m in embed_asm_out embed_source_in embed_config embed_diag_out; do
  cp "$EMBED_DIR/$m.ml" "$variant/src/"
done
"$EMBED_DIR/gen-config-data.sh" "$ini" "$pristine/src/Readconfig.ml" > "$variant/src/embed_config_data.ml"
"$EMBED_DIR/gen-runtime-data.sh" "$ini" "$pristine/src/Readconfig.ml" "$pristine/src/Version.ml" \
  "$pristine/runtime" > "$variant/src/embed_runtime_data.ml" ||
  Fatal "could not generate the runtime helpers for $target"

(cd "$variant/src" && patch -p1 --forward --fuzz=0 --no-backup-if-mismatch < "$patchfile") ||
  Fatal "$patchfile does not apply exactly to $pristine/src"
if compgen -G "$variant/src/*.rej" > /dev/null || compgen -G "$variant/src/*.orig" > /dev/null; then
  Fatal "patch left .rej/.orig files in $variant/src"
fi

cat > "$variant/dune-project" <<DUNE
(lang dune 3.0)
DUNE
cat > "$variant/compcert_${target}_embed.opam" <<OPAM
opam-version: "2.0"
synopsis: "CompCert $target, patched to compile from and print into memory"
OPAM
# Same stanza as the pristine library's src/dune, under the variant's name.
# The export is unwrapped for ccomp's own main; the embed code addresses the
# library through its wrapper module, as it always has.
sed -e "s/compcert_$target\b/compcert_${target}_embed/g" -e '/^;/d' \
  "$pristine/src/dune" > "$variant/src/dune"
sed -i '/^ *(wrapped false)$/d' "$variant/src/dune"
grep -q "(name compcert_${target}_embed)" "$variant/src/dune" ||
  Fatal "could not derive $variant/src/dune from $pristine/src/dune"
# Only some pristine libraries are installable; the variant always is, since
# the tests find it through OCAMLPATH.
if ! grep -q "(public_name compcert_${target}_embed)" "$variant/src/dune"; then
  sed -i "s/^\( *\)(name compcert_${target}_embed)\$/&\n\1(public_name compcert_${target}_embed)/" \
    "$variant/src/dune"
  grep -q "(public_name compcert_${target}_embed)" "$variant/src/dune" ||
    Fatal "could not add a public_name to $variant/src/dune"
fi

echo "== [$target] done: $variant synced =="
