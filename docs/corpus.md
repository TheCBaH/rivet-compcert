# The `corpus` command: classifying CompCert's own test suites

M5 ("Expand CompCert coverage in parallel", `.ai/asm_plan.md`) grows the
fixture corpus beyond the 10 hand-picked cases under
`asm/fixtures/compcert-3.17/` by running CompCert's own test suites through
this project's parser and recording, per file, whether it was accepted.

The first (and currently only) increment covers `modules/CompCert/test/c/`
(24 files), x86_64 only, parse-level classification only - not a GNU `as`
differential, not execution. Wider targets, other CompCert test suites
(`regression`, `abi`, `compression`), and later pipeline stages are
follow-ups; see the bottom of this document.

## Commands

- `compcert-tools corpus classify-c` - the heavy path. Requires the x86_64
  cross compiler (`make asm-cross-setup`) and a clean `modules/CompCert`
  checkout. Compiles every `test/c/*.c` file with CompCert, classifies the
  generated assembly with this project's own parser
  (`asm --target x86_64 --dump-source-ast`), and publishes
  `asm/fixtures/corpus/c/x86_64/{manifest.txt,summary.txt}`.
- `compcert-tools corpus check` - the cheap path. No cross toolchain, no
  CompCert build, no `asm.exe`. Verifies the committed manifest and summary
  against the live tree; see "What `check` verifies" below.

Makefile targets: `make asm-corpus-classify-c-x86_64` and
`make asm-corpus-check-c`; the latter is part of `asm-ci`.
`asm/fixtures/corpus/c/x86_64/manifest.txt`/`summary.txt` are committed, from
a real `classify-c` run against CompCert 3.17 (`modules/CompCert` HEAD at the
revision recorded in the manifest): 2 of the 24 files are accepted, 22 are
rejected - overwhelmingly on `%xmm*` register operands ("unknown register")
and on a memory-operand shape this project's x86_64 parser does not yet
accept ("cannot parse operand"). See `summary.txt` for the full breakdown;
this is real M5 corpus evidence to triage, not a tooling bug - the rejected
files are the next concrete instruction/addressing-mode coverage work.

## The manifest format

`asm/fixtures/corpus/c/x86_64/manifest.txt`: a fixed six-line header, then
one line per corpus file, sorted by path.

```
suite:c
target:x86_64
ccomp-version:<first line of `ccomp -version`>
ccomp-args:<space-joined x86_64 ccomp flags>
compcert-revision:<git -C modules/CompCert rev-parse HEAD>
shared-header:test/endian.h	sha256:<hex>
modules/CompCert/test/c/aes.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:accepted
modules/CompCert/test/c/fib.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:rejected	reason:<first diagnostic line>
```

`outcome:accepted` never carries a `reason` field; `outcome:rejected` always
does. Values that could contain a backslash, tab or newline (`ccomp-version`,
`ccomp-args`, `reason`) are escaped the same way `Manifest.escape` already
escapes fixture manifest values.

`asm/fixtures/corpus/c/x86_64/summary.txt`: total/accepted/rejected counts,
then rejected files grouped by exact reason text, one `reason:<count><TAB>
<text>` line per distinct reason, sorted by reason text. Both files are
rendered by one canonical function each (`render_manifest`, `render_summary`)
- `classify-c` and `check` never format them differently.

The raw generated `.s` files are **not** committed, only their hashes.

## What `check` verifies

In order, failing on the first problem:

1. **Parses** `manifest.txt` with a strict parser that rejects a malformed
   hash, a record missing the field its outcome requires, a path that is not
   repo-relative or contains a `..` segment, and a duplicate path.
2. **Checks the fixed header values literally**: `suite` must be `"c"`,
   `target` must be `"x86_64"`, and the `shared-header` path must be
   `"test/endian.h"` - not merely well-formed, but exactly these constants.
3. **Canonical round-trip**: re-rendering the parsed manifest with
   `render_manifest` must reproduce `manifest.txt` byte-for-byte. A
   reordered, reformatted or hand-edited-but-parseable manifest fails here.
4. **Inventory**: the set of paths in the manifest must equal
   `modules/CompCert/test/c/*.c` on disk, exactly.
5. **A clean `modules/CompCert` checkout**: `git -C modules/CompCert status
   --porcelain` must be empty, checked *before* the revision comparison below
   - a locally modified compiler or standard header leaves `HEAD` unchanged,
   so a bare revision check cannot catch it.
6. **`compcert-revision`** against a live `git -C modules/CompCert rev-parse
   HEAD`.
7. **Every `source-sha256`** against a fresh hash of the real `.c` file, and
   **`shared-header`'s hash** against a fresh hash of `test/endian.h`.
8. **`summary.txt` byte-for-byte** against `render_summary` re-derived from
   the parsed manifest - not just the three totals, every reason group.

**Recorded for audit only, never re-verified by `check`**: `ccomp-version`,
`ccomp-args`, and every `generated-sha256` - reproducing these needs `ccomp`
itself, which is `classify-c`'s job, not `check`'s.

## Publication is recoverable

`classify-c` computes both files' full content before touching the
destination, then installs them so the destination is always either the last
known-good pair or the new pair - including on the very first run (no prior
manifest at all) and including when the second (`summary.txt`) install fails
right after the first succeeded, in which case the prior `manifest.txt` is
restored (or, on a first run, the just-installed one is removed) rather than
left dangling without a matching summary. If that restoration itself fails,
both failures are reported and every retained file is named in the
diagnostic rather than silently deleted.

## Follow-ups

- Triage the 22 rejected `test/c/` files' reasons (`%xmm*` registers, the
  unsupported memory-operand shape) into concrete instruction/addressing-mode
  work, per the decision bullet below.
- Add `classify-c-arm`, `classify-c-aarch64`, etc. (each its own explicit
  subcommand, never a `--target` flag with unimplemented values) for the
  other five targets.
- Add `classify-regression`, `classify-abi`, `classify-compression`
  subcommands for CompCert's other three test suites.
- Add a differential stage (GNU `as`/`objdump` cross-check) for accepted
  files.
- Decide whether recurring rejection reasons warrant new instruction or
  directive support, or are legitimately out of scope (libc-dependent, PIC,
  etc., already excluded per `.ai/asm_plan.md`).
