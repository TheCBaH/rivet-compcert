# The `corpus` command: classifying CompCert's own test suites

M5 ("Expand CompCert coverage in parallel", `.ai/asm_plan.md`) grows the
fixture corpus beyond the 10 hand-picked cases under
`asm/fixtures/compcert-3.17/` by running CompCert's own test suites through
this project's parser and recording, per file, whether it was accepted.

The first (and currently only) increment covers `modules/CompCert/test/c/`
(24 files), parse-level classification only - not a GNU `as` differential,
not execution. Other CompCert test suites (`regression`, `abi`,
`compression`) and later pipeline stages are follow-ups; see the bottom of
this document.

## Commands

- `compcert-tools corpus classify-c-<target>` - the heavy path, one explicit
  subcommand per target (`classify-c-x86_32`, `classify-c-x86_64`,
  `classify-c-arm`, `classify-c-aarch64`, `classify-c-riscv32`,
  `classify-c-riscv64` - never a `--target` flag accepting an unimplemented
  value). Requires that target's cross compiler (`make asm-cross-setup`) and
  a clean `modules/CompCert` checkout. Compiles every `test/c/*.c` file with
  CompCert, classifies the generated assembly with this project's own parser
  (`asm --target <target> --dump-source-ast`), and publishes
  `asm/fixtures/corpus/c/<target>/{manifest.txt,summary.txt}`.
- `compcert-tools corpus check` - the cheap path. No cross toolchain, no
  CompCert build, no `asm.exe`. Discovers every target with an already-
  published manifest and verifies each one's committed manifest and summary
  against the live tree; see "What `check` verifies" below.

Makefile targets: `make asm-corpus-classify-c-<target>` (one per target, a
static pattern rule over the same six targets as the fixture goals) and
`make asm-corpus-check-c`; the latter is part of `asm-ci`.
`asm/fixtures/corpus/c/x86_64/manifest.txt`/`summary.txt` are committed, from
a real `classify-c-x86_64` run against CompCert 3.17 (`modules/CompCert` HEAD
at the revision recorded in the manifest): **24 of 24 files are accepted.**
The other five targets are not yet classified; see Follow-ups. The prior
17 rejections were three gaps, all now fixed: a general octal string-escape
(`\NNN`, 1-3 digits) in the lexer; `%r8b`-`%r15b` (8-bit REX-extended
sub-registers, a register-table addition); and `%xmm0`-`%xmm15` plus the
SSE2 scalar-float instruction family CompCert's x86_64 double/float codegen
needs (`addsd`/`movsd`/`cvtsi2sd`/etc. - a new register class and ~11 codec
forms, byte-verified against real GNU `as`/`objdump`). A separate,
already-fixed gap (base-less scaled-index addressing, `leaq 0(,%rcx,8),
%rdi`) preceded these three; see git history for that fix.

**"24/24 accepted" is `classify-c`'s own metric and still means parse-level
acceptance only** (`classify-c` calls `asm --target x86_64
--dump-source-ast`, i.e. just the `parse` phase) - `classify-c` itself was
not changed to measure further than that; see "Actually assembling this
corpus" below for the separate, now-completed check that goes past it.

**Actually assembling this corpus (2026-08-23).** Running the full
`parse -> simplify -> lower -> encode -> plan_image` pipeline (`asm.exe`'s
default, no `--dump-source-ast`) over all 24 generated `.s` files - not
merely parsing them - now succeeds for every file up to symbol resolution.
The gaps `classify-c`'s parse-only check could not see are closed:
`movzbl`/`movzwl`/`movsbl`/`movslq` (zero-/sign-extending move: the `0F
B6/B7/BE/BF` family plus `movslq`'s own `0x63`), `setl`/`sete`/etc.
(byte-set-on-condition, `0F 90+cc`), `orl`/`orq`/`andq`/`xorq` in the
operand shapes CompCert's own codegen needs (register-register, the
mem-source `Alu_r_rm` direction, and the group-1 immediate form), the
general group-2 shift/rotate forms (`rorl $27,%eax`, `sall $16,%eax`,
`sall %cl,%eax` - the `0xC1 ib`/`0xD3` encodings beyond the M4-era
shift-by-1-only `0xD1`), TEST's own immediate form (`0xF7 /0 id`), the
two-operand `imul $imm,reg` form (`0x69`/`0x6B`), 8-bit register-to-register
and register-to-memory `mov` (opcode `0x88`/`0x8A` - a genuinely different
opcode byte from the 16/32/64-bit forms, not a width variant of them - which
also surfaced a real encoding bug: `%spl`/`%bpl`/`%sil`/`%dil` need an empty
REX prefix to be selected over the legacy `%ah`/`%ch`/`%dh`/`%bh` encoding
this project's register table has no representation for, and `prefixes_of`
was not forcing one), a 64-bit absolute data relocation (`Abs64`, for `.quad
symbol`), `.ascii`/`.asciz`/`.string`, and an unsigned 64-bit `.quad`
literal (`0x8000000000000000` and friends - `Bigint.to_uint64_opt` as a
fallback where `to_int64_opt` rejects the bit pattern as "too large").
Every new encoding was checked byte-for-byte against the real, installed
`x86_64-linux-gnu-as`/`objdump` before being written down, and
`make asm-fixture-oracle-x86_64`/`-x86_32` (the full differential/QEMU-execution
suite over the hand-picked fixture corpus) stayed green throughout with no
fixture drift, so this is additive coverage rather than a change to any
previously-verified encoding.

What still blocks a *complete* image (not a `classify-c` concern, and not
fixed here) is symbol resolution: every one of the 24 files references at
least one libc function (`malloc`, `atoi`, `printf`, `cos`, `memcmp`, ...)
or a symbol defined in a CompCert test-suite file this corpus does not also
compile (`i`, `p`, `data`, `arch_big_endian`), and `plan_image` correctly
reports each as `image.undefined` - libc linking is `.ai/asm_plan.md` §2.2's
explicit non-goal, and multi-file linking of the *rest* of the suite (not
just `test/c/`) is unstarted. There is no committed manifest/summary for
this "assemble" stage (unlike `classify-c`'s) - see Follow-ups.

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

- **A committed "assemble" manifest, mirroring `classify-c`'s.** The
  pipeline-level check described above ("Actually assembling this corpus")
  was run and verified this session but has no `corpus assemble-c`
  subcommand, no checked-in manifest/summary, and no `check`-style
  re-verification - unlike `classify-c`, it is not yet CI-enforced or
  regenerable by a single documented command. Needs its own runner (the
  default `asm.exe` invocation reaches `plan_image`, which is as far as a
  single-TU compile can honestly go without a linker for the rest of the
  program) and a manifest format that can distinguish "blocked on an
  undefined external symbol" (expected, given `.ai/asm_plan.md` §2.2) from
  a real encoding gap, rather than collapsing both into one `rejected`
  bucket the way `classify-c`'s does.
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
- `classify-c-arm`/`-aarch64`/`-riscv32`/`-riscv64`/`-x86_32` subcommands are
  landed (see Commands above) and have been run for real against
  `modules/CompCert/test/c/`, the same iterative way the x86_64 gaps above
  were closed: arm 0→24/24 (register-offset addressing; a new VFP
  double-precision family), aarch64 0→24/24 (`add ..., #:lo12:sym`; FP
  immediates; register-offset+extend addressing), riscv64 24/24 with no
  gaps found. x86_32 8→21/24 (xmm0-7 register table; symbolic base-less SIB;
  `jmp *sym(,%reg,scale)`); 3 files still rejected on a related,
  not-yet-fixed gap (`disp(%base)` with a symbolic displacement, no
  index/scale). riscv32 is blocked before any parser code runs: no
  ilp32d-ABI cross-libc-dev package exists in Debian's repos, only the
  lp64d one riscv64 uses.
- Add `classify-regression`, `classify-abi`, `classify-compression`
  subcommands for CompCert's other three test suites.
- Add a differential stage (GNU `as`/`objdump` cross-check) for accepted
  files.
- Decide whether recurring rejection reasons warrant new instruction or
  directive support, or are legitimately out of scope (libc-dependent, PIC,
  etc., already excluded per `.ai/asm_plan.md`).
