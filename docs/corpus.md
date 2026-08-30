# The `corpus` command: classifying CompCert's own test suites

M5 ("Expand CompCert coverage in parallel", `.ai/asm_plan.md`) grows the
fixture corpus beyond the 10 hand-picked cases under
`asm/fixtures/compcert-3.17/` by running CompCert's own test suites through
this project's parser and recording, per file, whether it was accepted.

The first increment covers `modules/CompCert/test/c/` (24 files), parse-level
classification only - not a GNU `as` differential, not execution
(`classify-c`, below). The second increment runs the same 24 files through
the full pipeline instead of stopping at parsing (`assemble-c`, below). The
third increment classifies CompCert's two other static, committed-source test
suites the same parse-level way `classify-c` does: `test/regression/` (108
files) and `test/compression/` (12 files) - `classify-regression`/
`classify-compression`, below. `test/abi/`'s sources are generator-produced
(some with an explicit random seed) rather than committed, so it does not fit
this "hash a committed `.c` file" model and is deliberately not covered; see
Follow-ups. A GNU `as` differential and execution over the wider corpus are
also follow-ups; see the bottom of this document.

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
- `compcert-tools corpus assemble-c-<target>` - `classify-c-<target>`'s
  pipeline-level sibling, same one-explicit-subcommand-per-target discipline
  (`assemble-c-x86_32`, ..., `assemble-c-riscv64`). Requires the same cross
  compiler and clean checkout as `classify-c-<target>`, and compiles the same
  `test/c/*.c` files the identical way. But instead of stopping at
  `--dump-source-ast`, it runs each generated `.s` through `asm`'s default,
  full `parse -> simplify -> lower -> encode -> plan_image` path and
  publishes `asm/fixtures/corpus/c-assemble/<target>/{manifest.txt,summary.txt}`
  - a separate destination from `classify-c`'s, so the two are never
  conflated. See "The assemble-c manifest format" below for how it tells an
  expected libc/cross-file `image.undefined` block apart from a real gap.
- `compcert-tools corpus check-assemble` - `check`'s cheap-path sibling for
  `assemble-c`'s manifests.
- `compcert-tools corpus classify-regression-<target>` /
  `classify-compression-<target>` - `classify-c-<target>`'s own siblings over
  `test/regression/` and `test/compression/`, same one-explicit-subcommand-
  per-target discipline, same cross-compiler and clean-checkout requirement.
  Unlike `classify-c`, a file in these bigger, less curated suites can fail to
  *compile* at all for a given target (a different architecture's builtins, a
  documented CompCert `FAILURES` case, ...) - that becomes a third outcome,
  `outcome:compile-failed`, rather than aborting the run; see "The
  classify-regression/classify-compression manifest format" below. Published
  under `asm/fixtures/corpus/regression/<target>/` and
  `asm/fixtures/corpus/compression/<target>/`.
- `compcert-tools corpus check-regression` / `check-compression` - `check`'s
  cheap-path siblings for those two suites' manifests.

Makefile targets: `make asm-corpus-classify-c-<target>` / `make
asm-corpus-assemble-c-<target>` / `make asm-corpus-classify-regression-<target>`
/ `make asm-corpus-classify-compression-<target>` (one per target each, static
pattern rules over the same six targets as the fixture goals) and `make
asm-corpus-check-c` / `make asm-corpus-check-assemble-c` / `make
asm-corpus-check-regression` / `make asm-corpus-check-compression`; all four
`check` targets are part of `asm-ci`. All six targets are classified and their
`manifest.txt`/`summary.txt` committed under `asm/fixtures/corpus/c/<target>/`,
from real `classify-c-<target>` runs against CompCert 3.17 (`modules/CompCert`
HEAD at the revision recorded in each manifest): x86_64, x86_32, arm,
aarch64, riscv32, and riscv64 each accept **24 of 24 files** (x86_32's
former three rejections - `disp(%base)` with a symbolic displacement and no
index/scale - are fixed; see Follow-ups). The x86_64 corpus's prior 17
rejections were three
gaps, all now fixed: a general octal string-escape
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

What still blocks a *complete* image (not a `classify-c` concern) is symbol
resolution: every one of the 24 files references at least one libc function
(`malloc`, `atoi`, `printf`, `cos`, `memcmp`, ...) or a symbol defined in a
CompCert test-suite file this corpus does not also compile (`i`, `p`, `data`,
`arch_big_endian`), and `plan_image` correctly reports each as
`image.undefined` - libc linking is `.ai/asm_plan.md` §2.2's explicit
non-goal, and multi-file linking of the *rest* of the suite (not just
`test/c/`) is unstarted. `corpus assemble-c-<target>` is the reproducible,
committed-manifest form of this check (`asm.exe`'s default path, no
`--dump` flag): it distinguishes a file whose diagnostics are *only*
`image.undefined` (`outcome:blocked` - the expected, already-understood
libc/cross-file gap above) from a file with at least one diagnostic of some
other code (`outcome:rejected` - a real parser, lowering, encoding, or
image-planning bug `classify-c`'s parse-only check cannot see). Run for real
against all six targets (CompCert 3.17, `modules/CompCert` HEAD at the
revision each manifest records):

| target  | accepted | blocked | rejected |
|---------|---------:|--------:|---------:|
| x86_64  |        0 |      24 |        0 |
| arm     |        0 |       3 |       21 |
| riscv32 |        0 |      10 |       14 |
| riscv64 |        0 |      10 |       14 |
| x86_32  |        0 |       0 |       24 |
| aarch64 |        0 |       0 |       24 |

x86_64 is fully blocked-only, matching "actually assembling this corpus"
above - every rejection that check found before this manifest existed has
already been fixed. The other five targets were never run past
`--dump-source-ast` before now, and their `rejected` counts are new,
real findings, not regressions: `x86_32`/`aarch64` reject on every file
(each target's own set of not-yet-lowered instructions, e.g. `fstpl`/`fldl`
on x86_32 and `eor`/`cbz`/`scvtf` on aarch64 - see each `summary.txt` for the
full per-target reason list); `arm`/`riscv32`/`riscv64` are a mix. None of
these are `classify-c` regressions - `classify-c`'s own parse-only manifests
are untouched - and none are fixed here: deciding whether a recurring reason
warrants new instruction/lowering support is deliberately a separate,
evidence-driven step from building the check that can see the evidence; see
Follow-ups.

**Classifying `test/regression/` and `test/compression/` (2026-08-28).** Run
for real against all six targets (CompCert 3.17, `modules/CompCert` HEAD at
the revision each manifest records; `classify-regression` passes `-fall` in
addition to each target's own `ccomp_args`, matching
`test/regression/Makefile`'s own `CCOMPFLAGS` - `test/c/` and
`test/compression/` need no such addition):

| target  | regression accepted | rejected | compile-failed (of 108) | compression accepted | rejected (of 12) |
|---------|---------------------:|---------:|-------------------------:|----------------------:|-------------------:|
| x86_32  |                  102 |        3 |                         3 |                     12 |                   0 |
| x86_64  |                  102 |        2 |                         4 |                     12 |                   0 |
| arm     |                   98 |        5 |                         5 |                     12 |                   0 |
| aarch64 |                  102 |        1 |                         5 |                     12 |                   0 |
| riscv32 |                  101 |        2 |                         5 |                     12 |                   0 |
| riscv64 |                  101 |        1 |                         6 |                     12 |                   0 |

`compile-failed` is consistent and unsurprising across targets, all recorded
in each manifest for audit rather than fixed here: `funct1.c` is CompCert's
own documented `FAILURES` case (too few/many arguments - a real, upstream
test-suite bug, not this project's); each `builtins-<arch>.c` fails to
compile on every target other than its own architecture (`use of unknown
builtin`, expected - CompCert's own compiler, not this project's parser);
`extasm.c` (GCC extended-asm register-pair constraints, `%R0`/`%Q0`) fails to
compile on the three 64-bit-native targets (x86_64, aarch64, riscv64) and
succeeds on the three where a 64-bit value needs a register pair (x86_32,
arm, riscv32), which is exactly the constraint's own purpose.

The `rejected` reasons are real, new parser gaps beyond what `classify-c`'s
24-file corpus ever exercised, grouped in each `summary.txt`. ARM's
`{r0 r1 r2 r3}` register-list operand syntax and two GNU-extension parse
gaps (`dollars.c`'s `$`-prefixed identifiers, `extasm.c`'s extended-asm
operand syntax on the targets where it compiles) remain open - see
"Capability ladder" below for the scope decision on each. Three gaps are
already fixed and the table above reflects the re-run in every case:
RISC-V's `%pcrel_hi`/`%pcrel_lo` rejections (both profiles, 5 files on
riscv32, 5 on riscv64) were a parser bug, not a missing form (96→101
accepted on each); AArch64's `uxtx #0` was a genuinely missing ADD/SUB
(extended register) encoding, now added (101→102 accepted); x86_64's
`%r8w`-`%r15w` (16-bit REX-extended sub-registers, also the compression
corpus's sole rejection, `arcode.c`'s `%r10w`) needed a new 16-bit
operand-size prefix rather than a register-table row, now added
(regression 96→102 accepted, compression 11→12 accepted).

**One shared timeout, not a per-target rejection.** `test/regression/floats.c`
compiles to roughly 110,000 lines of assembly (an exhaustive float-conversion
table), and this project's own `--dump-source-ast` does not return on it in
any bounded time this session tried (over 5 CPU-minutes, still running).
Every manifest above records it as `outcome:rejected reason:(no diagnostic;
exit 124)` - `classify-regression`'s parser invocation is now wrapped in the
external `timeout` (120s, the same convention `gnu_tools.ml`'s `qemu_run`
uses for a guest run), so this is a bounded, recorded finding rather than a
hung `classify-regression` run - and, since it is in `asm-ci`, a hung CI
pipeline. The underlying performance pathology itself is unfixed; see
Follow-ups.

## The `classify-c` manifest format

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

## The `assemble-c` manifest format

`asm/fixtures/corpus/c-assemble/x86_64/manifest.txt`: the same fixed
six-line header as `classify-c`'s (`suite` is the literal `c-assemble`
rather than `c`), then one line per corpus file, sorted by path, with a
third possible `outcome` alongside `accepted`/`rejected`:

```
suite:c-assemble
target:x86_64
ccomp-version:<first line of `ccomp -version`>
ccomp-args:<space-joined x86_64 ccomp flags>
compcert-revision:<git -C modules/CompCert rev-parse HEAD>
shared-header:test/endian.h	sha256:<hex>
modules/CompCert/test/c/return42.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:accepted
modules/CompCert/test/c/aes.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:blocked	undefined:4	reasons:<sorted, deduplicated, "; "-joined diagnostic messages>
modules/CompCert/test/c/fib.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:rejected	reason:<first non-image.undefined diagnostic line>
```

`outcome:blocked` records `undefined:<n>`, the number of `image.undefined`
diagnostics `asm.exe` reported for that file, and `reasons:`, their sorted,
deduplicated messages (not the raw diagnostic lines, which repeat the
generated file's own path) joined with `"; "` and escaped the same way as
every other free-text manifest field. `outcome:rejected`'s `reason` is the
first diagnostic *line* whose code is not `image.undefined` - the real gap,
even when the same file also has `image.undefined` diagnostics alongside it.
A file with no recognizable `<origin>: error[<code>]: <message>` diagnostic
line at all (a crash, or a diagnostic-free nonzero exit) falls back to the
first non-empty stderr line, or a fixed placeholder for empty stderr -
mirroring `classify-c`'s own fallback.

`asm/fixtures/corpus/c-assemble/x86_64/summary.txt`: `total`/`accepted`/
`blocked`/`rejected` counts, then *rejected* files grouped by exact reason
text the same way `classify-c`'s summary groups its rejections - `blocked`
files are not grouped by reason in the summary, since their per-file
evidence already lives in `manifest.txt` and grouping by which libc
functions a file happens to call would mostly just re-sort the corpus.

## The `classify-regression`/`classify-compression` manifest format

`asm/fixtures/corpus/regression/x86_64/manifest.txt`: the same fixed six-line
header as `classify-c`'s (`suite` is the literal `regression` or
`compression`), then one line per corpus file, sorted by path, with a third
possible `outcome` alongside `accepted`/`rejected` - `compile-failed`, for a
file that never produced a `.s` at all:

```
suite:regression
target:x86_64
ccomp-version:<first line of `ccomp -version`>
ccomp-args:<space-joined x86_64 ccomp flags, including -fall>
compcert-revision:<git -C modules/CompCert rev-parse HEAD>
shared-header:test/endian.h	sha256:<hex>
modules/CompCert/test/regression/aes.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:accepted
modules/CompCert/test/regression/fib.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:rejected	reason:<first diagnostic line>
modules/CompCert/test/regression/funct1.c	source-sha256:<hex>	outcome:compile-failed	reason:<first ccomp diagnostic line>
```

`outcome:compile-failed` has no `generated-sha256` field - there is no
generated `.s` to hash when `ccomp` itself never produced one - and its
`reason` is the same first-non-empty-stderr-line (or fixed placeholder for
empty stderr) fallback `classify-c`'s own `Rejected` reason uses, applied to
`ccomp`'s stderr instead of `asm.exe`'s.

`asm/fixtures/corpus/regression/x86_64/summary.txt`: `total`/`accepted`/
`rejected` counts, a `compile-failed` count (omitted, along with its reason
group, when it is zero - which is every already-published `classify-c`/
`classify-compression` manifest, so their `summary.txt` stays byte-for-byte
what `classify-c`'s two-outcome format always produced), then *rejected*
files grouped by reason (`reason:<count><TAB><text>`, sorted) and
*compile-failed* files grouped by reason the identical way
(`compile-reason:<count><TAB><text>`, sorted) - two separate groups, since a
file's `.c` source not compiling at all is different evidence from its
generated `.s` not parsing.

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

`check-assemble` verifies each `c-assemble/<target>/manifest.txt` the
identical way, against the identical eight-step list, with two differences:
`suite` must literally be `"c-assemble"` rather than `"c"` at step 2, and
step 8 additionally re-derives the `blocked`/`accepted`/`rejected` totals
`render_summary` computes rather than just `accepted`/`rejected`. It is a
wholly separate command from `check` (own manifest, own destination
directory, own errors) so an `assemble-c` regression is never conflated with
a `classify-c` one, and vice versa.

`check-regression`/`check-compression` verify `regression/<target>/` and
`compression/<target>/` the same eight-step way, `suite` literally
`"regression"`/`"compression"` at step 2 and step 4's inventory compared
against `modules/CompCert/test/regression/*.c`/`test/compression/*.c`
instead of `test/c/*.c` - each its own command, own manifests, own errors,
never conflated with `classify-c`'s or each other's.

## Publication is recoverable

`classify-c`, `assemble-c`, `classify-regression`, and `classify-compression`
each compute both of their own files' full
content before touching their own destination, then install them so the
destination is always either the last known-good pair or the new pair -
including on the very first run (no prior manifest at all) and including
when the second (`summary.txt`) install fails right after the first
succeeded, in which case the prior `manifest.txt` is restored (or, on a
first run, the just-installed one is removed) rather than left dangling
without a matching summary. If that restoration itself fails, both failures
are reported and every retained file is named in the diagnostic rather than
silently deleted.

## Capability ladder: turning the manifests into scope decisions

M5's ordered work starts by grouping every recurring `assemble-c`/
`classify-regression`/`classify-compression` rejection reason (the tables and
`summary.txt` files above) into either a documented scope exclusion or a real
gap with a next-smallest fixture, rather than pursuing one suite or one
architecture to exhaustion. This section is that grouping; it supersedes the
undifferentiated "decide whether X warrants support" bullets that used to
stand in for it below.

**Scope exclusions (not fixed, by design).** These recur but are not corpus
gaps:

- `funct1.c` `compile-failed` on every target: CompCert's own documented
  `FAILURES` case (too few/many arguments), not this project's.
- `builtins-<arch>.c` `compile-failed` on every target but its own
  architecture: `ccomp` itself rejects an unknown builtin - expected, and it
  is `ccomp`'s diagnostic, not this project's parser.
- `extasm.c` `compile-failed` on the three 64-bit-native targets (x86_64,
  aarch64, riscv64): the GCC extended-asm register-pair constraint (`%R0`/
  `%Q0`) is meaningless where a 64-bit value needs no register pair - exactly
  the constraint's own purpose, not a gap.
- `extasm.c` `outcome:rejected` (`error[parse]: unexpected token`) on the
  three targets where it *does* compile (x86_32, arm, riscv32): real GNU
  extended-asm operand syntax this project does not parse. `.ai/asm_plan.md`
  §10 stages inline-assembly support as incremental and later; this is that
  gap's first corpus evidence, deliberately deferred until inline-asm work
  starts rather than special-cased here.
- `dollars.c` `outcome:rejected` (`error[parse]: unexpected token`) on x86_32/
  x86_64: `$`-prefixed identifiers are a GNU assembler extension CompCert
  itself never emits - `dollars.c` is a regression test *for* the extension,
  not evidence of a CompCert-compatibility gap. Left unsupported; revisit only
  if a real CompCert-generated fixture ever needs it.
- `test/regression/floats.c`'s parse timeout: tracked separately (below, as
  a follow-up performance item), not a per-target rejection to fix here.

**Real gaps, grouped by capability, with the next-smallest fixture:**

1. **x86 16-bit operand size (`%r8w`-`%r15w`, x86_64 `classify-regression`/
   `compression`) - fixed.** This was *not* the register-table-only fix its
   previous description here suggested. `x86_family_encode.ml`'s
   `simplify_instruction` rejected every 16-bit-suffixed mnemonic outright
   (`Some 16 -> bad `Prefix66_out_of_scope`) - the 0x66 operand-size prefix
   had never been implemented for any register, extended or not, so no
   16-bit `mov`/`or`/... form ever reached the register table. Fixed by
   adding a shared `opsz` component to the same `prefixes` record `asz`/REX
   already live in (ordered `asz, 0x66, REX, ...`, matching real `as`'s own
   byte order: `66 44 89 44 24 3a` for `movw %r8w, 0x3a(%rsp)`), then adding
   `extended_regs 16 "w"` to `x86_64_encode.ml`'s register list. Scoped to
   `mov` only via a new `~allow16` exception in `widthed` (mirroring the
   existing `~allow8`) - every other ALU mnemonic keeps the same
   `Prefix66_out_of_scope` diagnostic it had before, since only `mov`'s
   register-to-memory form (`bitfields10.c`'s `movw %r8w, 58(%rsp)`) is
   corpus-evidenced; see `asm/test/targets/test_targets.ml`'s "16-bit operand
   size" tests, including the one pinning that an unrelated mnemonic
   (`addw`/`xorw`) still rejects.
2. **x86_32 `assemble-c` (pipeline-level, not parse-level).** `lea` recurs 12
   times (the highest-signal single reason in this corpus) - an addressing
   shape the existing `lea` forms do not cover; `fstpl`/`fstps`/`fldl` (x87
   double/single load-store) recur 8 times; `shldl` (double-precision shift)
   twice; `movsd` (the *GPR* move-string-doubleword mnem, not the x86_64 SSE
   scalar-float `movsd`) once. Next-smallest fixture: isolate the exact `lea`
   operand shape from one `no lea form takes these operands` diagnostic's
   source line rather than a whole `test/c/` file, since most affected files
   also hit the unrelated x87 gap in the same run.
3. **ARM.** `classify-regression`'s `{r0, r1, r2, r3}` register-list operand
   (`varargs1`/`varargs2`/`varargs3`, from `push {r0, r1, r2, r3}`) is a new
   mnemonic, a new operand syntax, and a new multi-register STMDB-class
   encoding together - not a small parser addition. `assemble-c`'s recurring
   `eor`/`rsb`/`orr`/`mvn`/`lsl`/`nop` (integer/logical/shift family) and
   `vldr`/`vdiv.f32`/`vmul.f32` (VFP double load and arithmetic) remain open,
   scoped as follow-up work.
4. **AArch64.** `classify-regression`'s `uxtx #0` (`add x0, x0, x16, uxtx #0`)
   is **fixed**: it is the ADD/SUB *extended-register* encoding, structurally
   distinct from the already-implemented ADD/SUB *shifted-register* form
   (`aarch64_encode.ml`'s `Addsub_shift`, which only recognized
   `lsl`/`lsr`/`asr`/`ror`) - a different fixed bit at 23:21 (`00 1` versus a
   2-bit shift kind and a `0`), and unlike the shifted form `rd`/`rn` may be
   SP here. The register-offset addressing extend table in the same file
   (`extend_option`) is a *different* 3-bit encoding at different bit values
   for the same keywords, so the new `Addsub_extend` variant and its own
   8-entry option table (`extend_alu_of_name`) are deliberately not unified
   with it. Checked byte-for-byte against real `aarch64-linux-gnu-as`/
   `objdump` across all eight extend keywords and both an SP operand and a
   32-bit-source (`uxtw`/`uxtb`) case; see
   `asm/test/targets/test_targets.ml`'s "ADD/SUB (extended register)" test.
   `assemble-c`'s recurring `cbz`/`cbnz` (compare-and-branch), `sxtw`/`uxtw`
   (integer extension), `eor` (logical), `fcsel`/`scvtf`/`fmul` (FP),
   `lsl`/`ubfiz` (shift/bitfield), and `movn` (mov negated immediate) remain
   open, scoped as follow-up work.
5. **RISC-V (both profiles).** `classify-regression`'s `%pcrel_hi`/
   `%pcrel_lo` rejections (`charlit.c`, `initializers.c`, `initializers2.c`,
   `packedstruct1.c`, `packedstruct2.c`) are **fixed**: the real cause was not
   a missing operand form but an ambiguity bug - `riscv_family.ml`'s
   `parse_one` tried a memory-operand `offset(base)` reading of
   `%pcrel_hi(f1)` before its modifier reading, and `f1` is also a legal
   floating-register spelling, so a real static symbol literally named `f1`
   (as `charlit.c` has) took the register reading and left `%pcrel_hi` with
   no argument to parse. A single leading `Token.Modifier` now decides the
   reading before `Reg.find` is consulted, since a real `offset(base)` never
   starts with one; see `asm/test/targets/test_targets.ml`'s
   `riscv_pcrel_register_name_collision` tests. `assemble-c`'s recurring
   `fsd`/`fld`/`fmul.d`/`fmv.d`/`fcvt.d.w` (F/D floating load-store/convert)
   and `remu` (integer remainder), plus the isolated `no sll/ld form takes
   these operands` lowering gaps, remain open as a shift/remainder slice,
   with the F/D family scoped as a deliberate second, floating-point slice.

None of the five real-gap groups above are fixed by this section itself
(group 5's parser bug is the one exception, fixed in the same change that
added this section) - the point of this pass is the grouping and the
scope/gap decision that later follow-up work builds on.

## Follow-ups

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
- All six `classify-c-<target>` subcommands (see Commands above) have now been
  run for real against `modules/CompCert/test/c/`, the same iterative way the
  x86_64 gaps above were closed: arm 0→24/24 (register-offset addressing; a
  new VFP double-precision family), aarch64 0→24/24 (`add ..., #:lo12:sym`;
  FP immediates; register-offset+extend addressing), riscv64 24/24 with no
  gaps found, riscv32 24/24 with no gaps found (once the published
  `riscv32-linux-gnu` toolchain gave it a real `ilp32d`-ABI cross compiler -
  it no longer shares RV64's GNU-tool prefix or its libc gap; see
  `asm/docs/riscv-inventory.md`). x86_32 8→24/24: xmm0-7 register table;
  symbolic base-less SIB; `jmp *sym(,%reg,scale)`; and, closing its last
  three, a symbolic (as opposed to literal) `disp(%base)` operand, fixed in
  both the parser (a new case for a symbolic displacement) and the encoder
  (the `base-disp32` ModRM alternative no longer declines a symbolic
  displacement), checked against `i686-linux-gnu-as` before being promoted
  into a permanent expect test.
- `classify-regression` and `classify-compression` (see above) are now run
  for real against all six targets. `classify-abi` is deliberately not
  attempted: `test/abi/`'s only static, committed `.c` file is `layout.c`/
  `staticlayout.c`, and both `#include "layout.h"`, a header `test/abi/Makefile`
  generates at build time by compiling and running `genlayout.ml` (itself
  target-ABI-dependent) - every other `.c` file in the suite
  (`fixed_def.c`/`fixed_use.c`, `vararg_def.c`/`vararg_use.c`,
  `struct_def.c`/`struct_use.c`) is generated the same way by `generator.ml`,
  which for `fixed`/`vararg` additionally takes an explicit random seed
  (`-rnd 500`). None of that fits the "hash a committed `.c` file, expect a
  stable manifest" model `classify-c`/`classify-regression`/
  `classify-compression` share - supporting it would mean building and
  running two more OCaml generator programs per target as a new pipeline
  stage, not one more `suite_spec`. Left for a future increment if the ABI
  suite's coverage turns out to matter enough to justify that.
- Add a differential stage (GNU `as`/`objdump` cross-check) for accepted
  files, across all four classified suites.
- Which recurring `assemble-c`/`classify-regression`/`classify-compression`
  reasons warrant new instruction/lowering support, and which are legitimate
  scope exclusions, is now decided in "Capability ladder: turning the
  manifests into scope decisions" above - including the one gap (RISC-V
  `%pcrel_hi`/`%pcrel_lo` on a register-name-colliding symbol) that turned out
  to be a parser bug rather than a missing form, and is already fixed there.
- `test/regression/floats.c` (~110K lines of generated assembly) makes this
  project's `--dump-source-ast` take longer than 5 CPU-minutes without
  returning, on every target (it is the one shared file, so the finding is
  target-independent). `classify-regression` now bounds this with an external
  120s `timeout` rather than hanging, but the underlying performance
  pathology - almost certainly at least quadratic in input size somewhere in
  the lexer, parser, or AST construction, given a well-formed 110K-line file
  never finishing in 5 minutes - is itself unfixed and unprofiled.
- This session's riscv32 `ccomp`/`as` builds and runs fine, but
  `riscv32-linux-gnu-gcc` (the full cross-`gcc`, as opposed to
  `riscv32-linux-gnu-as`/binutils alone, which CompCert's own preprocessing
  step needs even for `-S`) was only reachable once
  `/usr/local/riscv32-linux-gnu-toolchain/bin` was added to `PATH` - already
  in the Dockerfile's own `ENV PATH`, but not present in this interactive
  session's shell for reasons this session did not chase down further.
