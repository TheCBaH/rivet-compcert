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
revision recorded in the manifest): **24 of 24 files are accepted.** The prior
17 rejections were three gaps, all now fixed: a general octal string-escape
(`\NNN`, 1-3 digits) in the lexer; `%r8b`-`%r15b` (8-bit REX-extended
sub-registers, a register-table addition); and `%xmm0`-`%xmm15` plus the
SSE2 scalar-float instruction family CompCert's x86_64 double/float codegen
needs (`addsd`/`movsd`/`cvtsi2sd`/etc. - a new register class and ~11 codec
forms, byte-verified against real GNU `as`/`objdump`). A separate,
already-fixed gap (base-less scaled-index addressing, `leaq 0(,%rcx,8),
%rdi`) preceded these three; see git history for that fix.

**"24/24 accepted" means parse-level acceptance only** (`classify-c` calls
`asm --target x86_64 --dump-source-ast`, i.e. just the `parse` phase) - it
does **not** mean this corpus fully assembles. Mnemonic validity is checked
in a later phase (`simplify_instruction`) that parse-level classification
never reaches, so a mnemonic can parse (any `mnemonic operand, operand` shape
whose operands parse is accepted) without this project knowing what it means.
Confirmed unimplemented and still present throughout this corpus:
`movzbl`/`movzwl` (zero-extending byte/word move), `movslq` (sign-extending
move, 18 of 24 files), `setl`/`sete`/etc. (byte-set-on-condition), and
likely more once those are addressed. Actually assembling this corpus
(simplify + lower + encode all 24 files) is a materially larger follow-up
needing its own runner - `classify-c`'s `--dump-source-ast` cannot measure
it - and is not scoped here.

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

- **Actually assemble this corpus, not just parse it.** `movzbl`/`movzwl`,
  `movslq`, `setl`/`sete`/etc. are unimplemented in `simplify_instruction`
  and appear throughout these 24 files; classify-c's parse-only check can't
  see that. Needs a new runner (not `--dump-source-ast`) plus the missing
  instruction support.
- A symbolic base-less-SIB displacement (`seg_start(,%ecx,4)`): the encoder/
  decoder already handle it (the SIB "no base" codec alternative uses the
  same fixup-carrying displacement codec as RIP-relative addressing), only
  the parser needs a fourth case for an `Ident`-led token shape. Currently
  masked in `asm/fixtures/gas-xref/frontier/x86_32/helper-helper/input.s` by
  an unrelated earlier lexer error.
- A negative-displacement three-register SIB form (`-1(%rbp,%rcx,2)`,
  base+index+scale all present): no existing parser pattern covers it. Not
  evidenced by any corpus rejection; fix if and when a fixture needs it.
- A permanent GNU-`as`/`objdump` differential regression test for the new
  base-less-SIB form: verified once by hand against the real, installed
  cross binutils (byte-for-byte match), but not wired into a permanent
  fixture - `asm/test/snippets/snippet_ast.ml`'s `X86_shared` corpus, which
  feeds both `gas-xref`'s generated corpus and the QEMU exec-ABI harness, is
  a closed nine-case ABI-conformance record (`return42`, `trap`, `spin`,
  ...), not an open list of operand-coverage snippets, so a new differential
  case needs its own small fixture design rather than an entry there.
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
