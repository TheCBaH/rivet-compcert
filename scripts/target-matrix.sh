#!/usr/bin/env bash
# rivet owns the target table. This stand-in is also one of the sentinels
# rivet-tools uses to recognise a repository root.
exec "$(dirname "${BASH_SOURCE[0]}")/../vendor/rivet/scripts/target-matrix.sh" "$@"
