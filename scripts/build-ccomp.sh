#!/usr/bin/env bash
# Build ccomp, its runtime and the compcert_<target> OCaml library from the
# export tarball unpacked by fetch-compcert.sh, into _compcert/<target>/install.
#
#   scripts/build-ccomp.sh <target>
#
# Needs OCaml, dune, menhirLib and the target's cross toolchain, and no Rocq.
set -euo pipefail
cd "$(dirname "$0")/.."

t=${1:?usage: build-ccomp.sh <target>}
scripts/fetch-compcert.sh "$t"

root=_compcert/$t
stamp=$(cat "$root/.stamp")
if [ "$(cat "$root/install/.stamp" 2>/dev/null || true)" = "$stamp" ]; then
  echo "ccomp $t: up to date"
  exit 0
fi

rm -rf "$root/install"
prefix=$PWD/$root/install
(cd "$root/export" && opam exec -- ./install.sh "$prefix")
"$prefix/bin/ccomp" -version | grep -q CompCert
echo "$stamp" > "$root/install/.stamp"
echo "ccomp $t: $("$prefix/bin/ccomp" -version)"
