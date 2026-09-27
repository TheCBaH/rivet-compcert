#!/usr/bin/env bash
# Build the embed variant of one target's CompCert library:
# compcert-lib-<target>-embed/, dune package compcert_<target>_embed.
#
# The variant is the pristine compcert-lib-<target>/src, copied, plus the
# injected modules under tools/compcert-embed/ and a strict patch that adds
# one `open` line to each file whose I/O or configuration they shadow. It
# never modifies compcert-lib-<target>/ itself, whose other consumers expect
# CompCert's ordinary file-based behavior.
#
# The patch applies with --fuzz=0 and fails on any reject, so a CompCert
# change that moves its anchors stops the sync instead of being guessed at.
# Every run starts from a fresh copy, so re-running is always safe.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
EMBED_DIR="$SCRIPT_DIR/compcert-embed"
WORK_ROOT="${COMPCERT_LIB_WORK:-$REPO_ROOT/.compcert-lib-work}"

Fatal() { echo "FATAL: $*" >&2; exit 1; }

target="${1:-}"
[ "$target" = aarch64 ] || Fatal "usage: $0 aarch64 (the only target with an embed patch)"

pristine="$REPO_ROOT/compcert-lib-$target"
variant="$REPO_ROOT/compcert-lib-$target-embed"
patchfile="$EMBED_DIR/$target.patch"
ini="$WORK_ROOT/build/$target/compcert.ini"

[ -f "$pristine/src/Compiler.ml" ] ||
  Fatal "no synced $pristine/src - run make compcert-lib-sync-$target first"
[ -f "$ini" ] || Fatal "missing $ini - run make compcert-lib-sync-$target first"

rm -rf "$variant"
mkdir -p "$variant/src"
cp "$pristine"/src/*.ml "$pristine"/src/*.mli "$variant/src/"

for m in embed_asm_out embed_source_in embed_config; do
  cp "$EMBED_DIR/$m.ml" "$variant/src/"
done
"$EMBED_DIR/gen-config-data.sh" "$ini" > "$variant/src/embed_config_data.ml"

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
sed -e "s/compcert_$target\b/compcert_${target}_embed/g" -e '/^;/d' \
  "$pristine/src/dune" > "$variant/src/dune"
grep -q "(name compcert_${target}_embed)" "$variant/src/dune" ||
  Fatal "could not derive $variant/src/dune from $pristine/src/dune"

echo "== [$target] done: $variant synced =="
