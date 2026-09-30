#!/usr/bin/env bash
# Present a target's unpacked artifacts as the tree the corpus manifests name:
#
#   modules/CompCert/test     -> _compcert/<target>/asm/sources
#   modules/CompCert/runtime  -> _compcert/<target>/export/runtime
#
# ccomp writes the source path it was given into every .s it emits, so the
# committed hashes only reproduce when the sources are reached under these
# names. There is no CompCert checkout behind them.
set -euo pipefail
cd "$(dirname "$0")/.."

t=${1:?usage: corpus-view.sh <target>}
[ -d "_compcert/$t/asm/sources" ] || { echo "corpus-view: run 'make compcert-fetch' first" >&2; exit 1; }

mkdir -p modules/CompCert
ln -sfn "../../_compcert/$t/asm/sources" modules/CompCert/test
ln -sfn "../../_compcert/$t/export/runtime" modules/CompCert/runtime
