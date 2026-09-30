#!/usr/bin/env bash
# Download the CompCert artifacts pinned in compcert.lock, verify their
# checksums and unpack them to _compcert/<target>/{export,asm}.
#
#   scripts/fetch-compcert.sh [<target>|all]
#
# A target whose .stamp equals the hash of its lock lines is left alone, so a
# repeat run (or a CI cache hit) downloads nothing. Tarballs are kept in
# _compcert/dl and re-verified on every run that unpacks them.
set -euo pipefail
cd "$(dirname "$0")/.."

lock=compcert.lock
targets=(x86_32 x86_64 arm aarch64 riscv32 riscv64)
want=${1:-all}

die() { echo "fetch-compcert: $*" >&2; exit 1; }

tag=$(awk '$1 == "tag" { print $2 }' "$lock")
repo=$(awk '$1 == "repo" { print $2 }' "$lock")
[ -n "$tag" ] && [ -n "$repo" ] || die "$lock has no tag/repo line"

if [ "$want" = all ]; then sel=("${targets[@]}"); else sel=("$want"); fi

lock_sha() { awk -v f="$1" '$2 == f { print $1 }' "$lock"; }

mkdir -p _compcert/dl
for t in "${sel[@]}"; do
  printf '%s\n' "${targets[@]}" | grep -qx "$t" || die "unknown target '$t'"
  files=("compcert-export-$t.tar.gz" "compcert-asm-$t.tar.gz")
  lines=("tag $tag")
  for f in "${files[@]}"; do
    sha=$(lock_sha "$f")
    [ -n "$sha" ] || die "$lock has no checksum for $f"
    lines+=("$sha $f")
  done
  stamp=$(printf '%s\n' "${lines[@]}" | sha256sum | cut -d' ' -f1)
  if [ "$(cat "_compcert/$t/.stamp" 2>/dev/null || true)" = "$stamp" ]; then
    echo "compcert $t: up to date"
    continue
  fi

  for f in "${files[@]}"; do
    if [ ! -f "_compcert/dl/$f" ]; then
      curl -fsSL --retry 3 -o "_compcert/dl/$f.part" \
        "https://github.com/$repo/releases/download/$tag/$f"
      mv "_compcert/dl/$f.part" "_compcert/dl/$f"
    fi
    if ! echo "$(lock_sha "$f")  _compcert/dl/$f" | sha256sum -c --quiet -; then
      rm -f "_compcert/dl/$f"
      die "checksum mismatch for $f"
    fi
  done

  rm -rf "_compcert/$t"
  mkdir -p "_compcert/$t/export" "_compcert/$t/asm"
  tar -xzf "_compcert/dl/compcert-export-$t.tar.gz" -C "_compcert/$t/export"
  tar -xzf "_compcert/dl/compcert-asm-$t.tar.gz" -C "_compcert/$t/asm"

  # The export's compcert.ini names its tools by bare command, so it is only
  # portable if they are the ones rivet's target table expects.
  if [ -f vendor/rivet/scripts/target-matrix.sh ]; then
    # shellcheck disable=SC1091
    . vendor/rivet/scripts/target-matrix.sh
    target_config "$t"
    asm=$(sed -n 's/^asm=//p' "_compcert/$t/export/compcert.ini")
    [ "$asm" = "${TOOLPREFIX}gcc" ] ||
      die "$t: compcert.ini asm=$asm, rivet expects ${TOOLPREFIX}gcc"
  fi

  echo "$stamp" > "_compcert/$t/.stamp"
  echo "compcert $t: fetched $tag"
done
