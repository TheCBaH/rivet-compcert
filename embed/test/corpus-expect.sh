#!/usr/bin/env bash
# Checks (or, with --update, rewrites) each embedded-corpus program's
# "/* expect: N */" line against independent compilers: gcc for the host
# and every target whose cross gcc and QEMU are installed, at -O0 and -O1,
# LP64 and ILP32 alike. Every one must return the same value, because the
# programs fold their own results to 32 bits. Floating point is kept to what
# CompCert does: no contraction, and SSE rather than x87 on i686.
#
# Needs the cross toolchains and QEMU, like the fixture-oracle legs, so it is
# not part of any test target: make asm-compcert-embed-corpus-check.
set -euo pipefail

dir=$(cd -- "${1:?usage: $0 <corpus-dir> [--update]}" && pwd)
update=${2:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# name | compiler | extra flags | runner
refs=(
  "host|gcc||"
  "aarch64|aarch64-linux-gnu-gcc|-static|qemu-aarch64"
  "x86_64|x86_64-linux-gnu-gcc|-static|qemu-x86_64"
  "riscv64|riscv64-linux-gnu-gcc|-static|qemu-riscv64"
  "i686|i686-linux-gnu-gcc|-static -msse2 -mfpmath=sse|qemu-i386"
  "arm|arm-linux-gnueabihf-gcc|-static|qemu-arm"
  "riscv32|riscv32-linux-gnu-gcc|-static|qemu-riscv32"
)

status=0
for src in "$dir"/*.c; do
  name=$(basename "$src")
  { cat "$src"
    printf '\n#include <stdio.h>\nint main(void) { static long long io[512]; printf("%%d\\n", (int)entry((void *)io)); return 0; }\n'
  } > "$work/main.c"
  values=()
  for r in "${refs[@]}"; do
    IFS='|' read -r ref cc flags runner <<< "$r"
    command -v "$cc" > /dev/null || continue
    [ -z "$runner" ] || command -v "$runner" > /dev/null || continue
    for opt in -O0 -O1; do
      # shellcheck disable=SC2086
      "$cc" $opt -ffp-contract=off -fno-strict-aliasing -w $flags "$work/main.c" -o "$work/a.out"
      v=$($runner "$work/a.out")
      values+=("$ref$opt=$v")
    done
  done
  distinct=$(printf '%s\n' "${values[@]}" | cut -d= -f2 | sort -u)
  want=$(head -1 "$src" | sed -n 's|^/\* expect: \(-\{0,1\}[0-9]*\) \*/$|\1|p')
  if [ "$(printf '%s\n' "$distinct" | wc -l)" -ne 1 ]; then
    echo "DISAGREE $name: ${values[*]}"
    status=1
  elif [ "$distinct" != "$want" ]; then
    if [ "$update" = --update ]; then
      sed -i "1s|.*|/* expect: $distinct */|" "$src"
      echo "updated  $name: $distinct (${#values[@]} references)"
    else
      echo "STALE    $name: expect $want, references say $distinct"
      status=1
    fi
  else
    echo "ok       $name: $distinct (${#values[@]} references)"
  fi
done
exit $status
