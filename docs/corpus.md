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
Follow-ups. A fourth increment classifies the same `test/c/` corpus a second
time, compiled with the system cross `gcc` instead of `ccomp`
(`classify-c-gcc`, below) - independent evidence of this project's real-world
GNU-syntax coverage, since gcc's own assembly idioms are not the ones `ccomp`
emits. A GNU `as` differential and execution over the wider corpus are also
follow-ups; see the bottom of this document.

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
- `compcert-tools corpus classify-c-gcc-<target>` - `classify-c`'s second,
  independent-compiler sibling: the identical `test/c/*.c` corpus, compiled
  with the *system cross `gcc`* instead of `ccomp`, then classified the same
  parse-level `--dump-source-ast` way. Needs no cross-compiler build (all six
  cross `gcc` toolchains are already on the container's PATH) and no
  `modules/CompCert` build - only a clean checkout, to compile from. Published
  under `asm/fixtures/corpus/c-gcc/<target>/`, with its own manifest header
  (`gcc-version`/`gcc-args` rather than `ccomp-version`/`ccomp-args`) so a
  classify-c regression and a classify-c-gcc regression are never conflated.
  See "classify-c-gcc: a second, independent-compiler corpus" below.
- `compcert-tools corpus check-c-gcc` - `check`'s cheap-path sibling for
  `classify-c-gcc`'s manifests.

Makefile targets: `make asm-corpus-classify-c-<target>` / `make
asm-corpus-assemble-c-<target>` / `make asm-corpus-classify-regression-<target>`
/ `make asm-corpus-classify-compression-<target>` / `make
asm-corpus-classify-c-gcc-<target>` (one per target each, static pattern rules
over the same six targets as the fixture goals) and `make asm-corpus-check-c` /
`make asm-corpus-check-assemble-c` / `make asm-corpus-check-regression` / `make
asm-corpus-check-compression` / `make asm-corpus-check-c-gcc`; all five `check`
targets are part of `asm-ci`. All six targets are classified and their
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
| arm     |                  101 |        2 |                         5 |                     12 |                   0 |
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
24-file corpus ever exercised, grouped in each `summary.txt`. Two
GNU-extension parse gaps (`dollars.c`'s `$`-prefixed identifiers, `extasm.c`'s
extended-asm operand syntax on the targets where it compiles) remain open -
see "Capability ladder" below for the scope decision on each. Every other
previously-tracked recurring gap is now fixed, and the table above
reflects the re-run in every case: RISC-V's `%pcrel_hi`/`%pcrel_lo`
rejections (both profiles, 5 files on riscv32, 5 on riscv64) were a parser
bug, not a missing form (96→101 accepted on each); AArch64's `uxtx #0` was a
genuinely missing ADD/SUB (extended register) encoding, now added (101→102
accepted); x86_64's `%r8w`-`%r15w` (16-bit REX-extended sub-registers, also
the compression corpus's sole rejection, `arcode.c`'s `%r10w`) needed a new
16-bit operand-size prefix rather than a register-table row, now added
(regression 96→102 accepted, compression 11→12 accepted); ARM's
`{r0, r1, r2, r3}` register-list operand needed a new mnemonic (`push`), a
new operand syntax, and a new multi-register encoding together, now added
(98→101 accepted).

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

## `classify-c-gcc`: a second, independent-compiler corpus

Every classification above compiles `test/c/*.c` with CompCert's own `ccomp`.
`classify-c-gcc` compiles the *identical* 24 files with the *system cross
`gcc`* instead - a genuinely different code generator, whose GNU-syntax idioms
(CFI directives, `$symbol`-style symbolic immediates, frame-pointer-based
prologues, ...) are not the ones `ccomp` happens to emit. Its accepted/
rejected split is therefore new, independent evidence of this project's
real-world GNU-assembler compatibility, not a restatement of `classify-c`'s
own findings - and, unlike every `classify-*`/`assemble-*` command above, it
needs no `make asm-cross-setup`: all six cross `gcc` toolchains are already on
the container's PATH (five Debian cross packages plus the published riscv32
toolchain `asm-cross-setup`'s own riscv32 leg installs), so `classify-c-gcc`
depends on nothing but a clean `modules/CompCert` checkout to compile from.
`Gcc` (`asm/tools/lib/gcc.ml`) resolves each target's `gcc` by bare name
through the child's PATH - `Gnu_tools.installed`'s own convention, applied to
`gcc` instead of `as`/`ld` - and `classify-c-gcc-<target>`'s `-S` flags are
each target's `ccomp_args` (`-fno-pie`, plus `-marm` on arm) with RISC-V
additionally pinned to `-march=rv<32|64>imafd -mabi=<ilp32d|lp64d> -mno-relax`
- without it, the riscv64 cross-package defaults to
`rv64imafdc_zicsr_zifencei` (compressed instructions included), a strictly
wider ISA than the `imafd` profile every other target-aware tool in this
project assumes, and would silently test the wrong instruction set.

First real run against all six targets (CompCert 3.17, `modules/CompCert`
HEAD at the revision each manifest records; every `.c` file compiles cleanly
with `gcc` on every target - 24/24, no `outcome:compile-failed` case exists in
this manifest format at all):

| target  | accepted | rejected |
|---------|---------:|---------:|
| x86_64  |        0 |       24 |
| x86_32  |        0 |       24 |
| aarch64 |        0 |       24 |
| arm     |        6 |       18 |
| riscv32 |       21 |        3 |
| riscv64 |       21 |        3 |

Grouped by capability (each `summary.txt` has the full per-file detail):

- **A universal lexer gap, on every target: `\b`/`\f` string escapes - fixed.**
  `aes.c` (`\b`) and `sha3.c`/`siphash24.c` (`\f`) failed identically on all
  six targets - the lexer's string-escape table
  (`asm/lib/asm_syntax/lexer.ml`, `scan_string`) recognized only
  `\n \t \r \\ \"` and a GAS octal escape (`\NNN`, added for `classify-c`'s own
  `aes.c` finding - see above); `\b` (backspace, `0x08`) and `\f` (form feed,
  `0x0C`) were the two-letter gap gcc's own string-literal escaping reaches
  that ccomp's never did - checked against real `x86_64-linux-gnu-as`:
  `.ascii "a\bc\fd"` assembles to `61 08 63 0c 64`. This was riscv32/riscv64's
  *entire* remaining rejection count (21/24 → 24/24).
- **x86 (`x86_64`, `x86_32`) - fixed, three separate gaps.** A bare symbolic
  `$symbol`/`$symbol+offset` immediate operand (`movl $.LC0, %edi`,
  `addq $bodies+24, %rax`, `pushl $sym`) was dominant on both targets - `ccomp`
  always materializes a symbol address through `lea`/RIP-relative addressing
  or a relocation-carrying `mov`, where gcc's `$symbol` is a symbolic
  *immediate*; parses (`Operand.Imm_sym`). `mov`'s register-destination form
  now lowers and encodes it too (`Lowered.Mov_r_imm`'s `imm` field became a
  `Disp.t`, carrying either a constant or a symbol the same way a memory
  displacement already could - checked against real `i686-linux-gnu-as`/
  `x86_64-linux-gnu-as`: `movl $sym, %eax` assembles to `b8 <disp32>` with an
  `R_386_32`/`R_X86_64_32` relocation). The ALU-immediate form (`addq
  $sym,%rax`) is fixed too, the same way: `Lowered.Alu_rm_imm`'s `imm` field
  is now a `Disp.t`, and its imm32 rung reuses the same fixup codec - checked
  against real `x86_64-linux-gnu-as`: `addq $sym, %rcx` assembles to `48 81
  c1 <disp32>` with an `R_X86_64_32S` relocation, *signed* unlike `mov`'s
  `R_X86_64_32` (matching this form's own prior sign-extending decode).
  Discovered while checking that: gcc's own accumulator-destination case
  (`addq $sym, %rax`, the corpus's literal spelling) doesn't byte-match at
  all yet, symbolic or not - real `as` picks a shorter, ModR/M-less encoding
  (`05 id`) for a full-width immediate against the accumulator specifically,
  which this project's ALU-immediate encoder never had (confirmed with a
  plain, non-symbolic `addl $1000, %eax` - real `as` gives `05 e8 03 00 00`,
  five bytes, where this encoder's only form gives the seven-byte ModR/M
  `81 c0 e8 03 00 00`). `push`-immediate (`pushl $sym`) is now fixed too:
  unlike `mov`/the ALU ops, `push` had no non-symbolic immediate lowering at
  all yet, so this added a new `Lowered.Push_imm` alongside the existing
  register-only `Lowered.Push`, with its own short/long (`0x6a ib`/`0x68
  id`) priority ladder mirroring `Alu_rm_imm`'s - checked against real
  `i686-linux-gnu-as`: `pushl $sym` assembles to `68 <disp32>` with an
  `R_386_32` relocation, and `pushl $100` still picks the pre-existing
  `6a 64` short form, confirming the new ladder didn't regress the plain
  literal case. All three symbolic-immediate sub-gaps (`mov`, ALU, `push`)
  are now closed; the accumulator-destination ALU encoding gap noted above
  remains open on its own.
  `(%base,%index)` with the scale omitted (GAS defaults it to 1)
  and x86_32's own `%ah`/`%ch`/`%dh`/`%bh` legacy high-byte registers (the
  register-4-7 table had been borrowed whole from x86_64's REX-bearing one,
  which cannot exist without a REX byte) closed the rest: x86_64 0→24/24,
  x86_32 0→24/24.
- **ARM/AArch64: pre-indexed load/store with immediate writeback - fixed for
  the single-register `str`/`ldr` case, and for `stp`.**
  (`str fp, [sp, #-4]!` on arm, `stp x29, x30, [sp, -48]!` on aarch64) -
  `ccomp`'s codegen never uses register writeback, so `classify-c`/
  `classify-regression` never exercised it. On aarch64, `Opcode.Stp` with
  pre-index writeback was *already fully implemented* in the encoder - the
  real blocker turned out to be a second, much bigger gap the `stp` framing
  understated: gcc's aarch64 backend never writes the immediate's leading
  `#` at all (5156 of 5156 bracket-immediate offsets in the corpus omit it),
  so even a plain `ldr x0, [sp, 16]` never parsed. Making `#` optional
  (GNU accepts it either way, confirmed against real `as`) for every affected
  shape - memory offsets, the register-offset shift amount, the ADD/SUB
  extended-register amount, and FP immediates (which needed their own second
  fix: every FP literal in the corpus is scientific notation, `1.0e+0`/
  `5.0e-1`, a shape nothing parsed at all before) - took aarch64 0→24/24. ARM's
  own `str`/`ldr` writeback (`Lowered.Ldst_imm` gained a real `writeback`
  field; the codec's `W` bit was a hard-coded 0) took arm 6→13/24; ARM's
  remaining rejections are two *different* capabilities (below), not this one.
- **ARM only: VFP floating-point immediate literals - fixed.**
  (`vmov.f32 s0, #2.0e+0`, several files) - the exact same scientific-notation
  gap the aarch64 fix above named, `float_lit` never having parsed an
  exponent (with or without `#`); `Vmov_imm_s`/`Vmov_imm_d` themselves needed
  no change - the values were always encodable, the operand just never
  reached them. Took arm 13→19/24.
- **ARM only, fixed: `vpush {dN, ...}`** (`almabench.c`/`fft.c`/`fftsp.c`/
  `perlin.c`'s `vpush.64 {d8, d9}`/`vpush.64 {d8-d9}`/`vpush.64 {d8-d10}`) -
  a D-register reglist push, structurally unrelated to the already-supported
  GPR `push {reglist}` (a new `Operand.Dreglist`, dispatched off the first
  brace member: a "dN" spelling is never also a GPR name, so `Reg.find` and
  `Dreg.find` never both succeed on the same string). The real gap here was
  bigger than the `{d8, d9}` framing suggested: gcc's own VFP printer spells
  the reglist as a hyphenated *range*, not the flat comma list GPR `push`
  uses (`{d8-d9}`, `{d8-d10}`) - confirmed against real
  `arm-linux-gnueabihf-as`/`objdump` that both spellings assemble to the
  identical bytes (`ed2d8b04` for `{d8-d9}` and `{d8, d9}` alike), so the
  range is expanded into the same flat register-number list a comma form
  would produce. Parse-level only at the time, like `$symbol`/`%st(n)` below:
  `vpush` itself was not yet in `Opcode.t`. 4 files. Since fully closed:
  `vpush` now has a real `Opcode.t` entry and a VSTM-class lowering/encoding,
  distinct from `push`'s STMDB-class one - no bitmask, only a base D
  register and a count, so lowering requires the operand's `Dreglist` to be
  non-empty, ascending, and contiguous - see the Follow-ups entry below.
- **ARM only, fixed: `stmia`/`ldm`/`pop {reglist}`'s own LDM-class
  writeback** (`aes.c`'s `stmia r3!, {r0, r1}` - a bare `Rn!` base register
  with no brackets, a genuinely different grammar from `str`/`ldr`'s
  bracketed `[Rn, #imm]!` fixed above, and with no `Operand.t` shape to hold
  it: `Mem.t` models an explicit offset, and STM/LDM's writeback amount is
  implicit, four bytes per listed register) - a new `Operand.Reg_writeback`
  parses the bare `Rn!` base; the `{reglist}` half was already covered by the
  existing GPR `Reglist` grammar. Parse-level only at the time, the same scope
  as `vpush` above: `stmia`/`ldmia`'s own mnemonics weren't even in the opcode
  table, and `dump-source-ast` never validates a mnemonic, only its
  operands (`pop {reglist}` itself, with no `!`-less base, already parsed
  before this fix, for the same reason). The `gas_frontier.t` runtime-helper
  corpus's own already-documented Follow-up, closed too. 1 file. Since fully
  closed: `stmia`/`ldmia`/`pop` now have real `Opcode.t` entries and an
  increment-after LDM-class lowering/encoding, distinct from `push`'s
  STMDB-class one - see the Follow-ups entry below.
- **x86_32 only, fixed: the x87 stack-register operand** (`%st(1)`, one file,
  `almabench.c`) - `%st`/`%st(n)` now parse (a new `st` register-table entry
  plus a dedicated `[Register "st"; Lparen; Int n; Rparen]` parser pattern
  synthesizing `st(n)`), though no x87 mnemonic is in the M1 instruction table
  at all yet, so this is parse-level only, the same way `$symbol` is above.

Current state (real runs, all six targets): x86_64 24/24, x86_32 24/24,
aarch64 24/24, riscv32 24/24, riscv64 24/24, arm 24/24 - every target in the
classify-c-gcc corpus is now fully closed.

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

## The `classify-c-gcc` manifest format

`asm/fixtures/corpus/c-gcc/x86_64/manifest.txt`: the same fixed six-line
header shape as `classify-c`'s (`suite` is the literal `c-gcc`), but with
`gcc-version`/`gcc-args` in place of `ccomp-version`/`ccomp-args` - a
deliberately separate header from `classify-c`'s own `header` type
(`Corpus_classify_gcc_cmd`, not `Corpus_classify_cmd`), so the two are never
byte-for-byte confusable even though their shapes are structurally close. Only
two outcomes exist, `accepted`/`rejected` - there is no `compile-failed`, since
gcc compiles every `test/c/*.c` file cleanly on every target:

```
suite:c-gcc
target:x86_64
gcc-version:<first line of `<toolprefix>gcc --version`>
gcc-args:<space-joined gcc flags>
compcert-revision:<git -C modules/CompCert rev-parse HEAD>
shared-header:test/endian.h	sha256:<hex>
modules/CompCert/test/c/return42.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:accepted
modules/CompCert/test/c/fib.c	source-sha256:<hex>	generated-sha256:<hex>	outcome:rejected	reason:<first diagnostic line>
```

`asm/fixtures/corpus/c-gcc/x86_64/summary.txt`: `total`/`accepted`/`rejected`
counts, then rejected files grouped by exact reason text - `classify-c`'s own
two-outcome summary shape, rendered by `Corpus_classify_gcc_cmd`'s own
`render_summary` rather than `Corpus_classify_cmd`'s.

`check-c-gcc` verifies each `c-gcc/<target>/manifest.txt` against the same
eight-step list "What `check` verifies" describes below, `suite` literally
`"c-gcc"` at step 2 and step 4's inventory compared against
`modules/CompCert/test/c/*.c` (the same files `classify-c` itself classifies -
`classify-c-gcc` is a different compiler over the same corpus, not a
different corpus). Own manifest, own destination, own errors - a
`classify-c` regression and a `classify-c-gcc` regression are never
conflated.

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
2. **x86_32 `assemble-c` (pipeline-level, not parse-level).** `lea`'s 12
   recurrences (the highest-signal single reason in this corpus) are **fixed**:
   every one was `leal sym, %reg` - a bare-symbol source operand
   (`Operand.Sym`), the same shape `Mov` already read through `mem_of_symbol`
   rather than a second `Lea` constructor, so `Lea` just needed the matching
   arm. No codec change: the encoder's general base-less-disp32 `Mem` form
   already produces the byte-identical `8d 0d <disp32>` real
   i686-linux-gnu-as/objdump emit for `leal sym, %ecx`, with an `R_386_32`
   relocation against `sym`. Fixing it retired all 12 `lea` rejections and let
   those files progress further: 8 now reach `blocked` (only libc/runtime
   symbols left undefined - the furthest state reachable without multi-file
   linking); `aes.c`/`chomp.c`/`sha1.c`/`vmach.c` and others among them. The
   remaining 2 of those 12 (`mandelbrot.c`, `knucleotide.c`) hit a
   *different* gap the `lea` rejection had been masking in the same files:
   `no movsd form takes these operands` and `no movss form takes these
   operands` respectively - the x86_64-style SSE scalar-float move, not the
   GPR move-string-doubleword mnemonic this list previously (and incorrectly)
   guessed the sole pre-fix `movsd` occurrence to be; that occurrence was
   always a third, `lea`-unrelated file (`fftw.c`) - both real floating-point
   users, so the SSE reading is the consistent one for all three. That gap is
   now **also fixed**: every recurrence (`fftw.c`, `knucleotide.c`,
   `mandelbrot.c` - `movsd` twice, `movss` once) was `movsd/movss sym,
   %xmmN`, the identical bare-symbol-source duality `lea` had just needed;
   `Sse_mov_r_rm` already had the general `Mem` form, so this was one more
   `Operand.Sym` arm reusing `mem_of_symbol`, no codec change. Byte-checked
   against real i686-linux-gnu-as/objdump: `movsd .Lc, %xmm0` ->
   `f2 0f 10 05 <disp32>`, `movss .Lc, %xmm1` -> `f3 0f 10 0d <disp32>`, both
   `R_386_32`-relocated, the same base-less-disp32 ModR/M shape as `lea`. All
   three files now reach `blocked` (libc-only). `fstpl`/`fstps`/`fldl` (x87
   double/single load-store, 8 recurrences) is now **fixed** too: no x87
   mnemonic was in `Opcode.t` at all before this, so it needed a new
   `Lowered.Fpu_mem { op; mem }` (opcode 0xD9/0xDD plus a ModR/M-reg
   extension, exactly the shape `Alu_r_rm`'s own `op`-carrying constructor
   already uses - `ext = 0` for `fldl`'s load, `ext = 3` for
   `fstpl`/`fstps`'s store-and-pop) - a bare `Mem.t` rather than the general
   `Rm.t` every GPR/xmm form uses, since the mod=11 ModR/M shape this opcode
   family also permits means an `%st(n)` register operand instead, which no
   fixture selects. Every recurrence in this corpus is `disp(%esp)`.
   Byte-checked against real i686-linux-gnu-as: `fldl 8(%esp)` assembles to
   `dd 44 24 08`, `fstpl 24(%esp)` to `dd 5c 24 18`, `fstps 52(%esp)` to
   `d9 5c 24 34`. Regenerating x86_32's `assemble-c` manifest with this fix
   moved it from 13 blocked/11 rejected to 22 blocked/2 rejected: all 8
   `fldl`/`fstpl`/`fstps` files now reach `blocked` (libc-only), and so does
   a ninth this fix unmasked - see `xorpd` below. `shldl` (double-precision
   shift) recurred twice - the only real-gap reason then left in this
   corpus's x86_32 `assemble-c` results - and is now **fixed** too: every
   recurrence (sha3.c/siphash24.c's 64-bit-rotate idiom built from two
   32-bit halves) is `shldl $imm8, %src, %dst`, a new `Lowered.Shld_imm_rm`
   (`0F A4 /r ib` - AT&T reverses Intel's `SHLD r/m32, r32, imm8` order,
   putting the count first and the r/m destination last; the ModR/M reg
   field carries the bit-supplying source register, not an extension code,
   unlike group-2's `shr`/`sar`/etc.). Byte-checked against real
   i686-linux-gnu-as/objdump: `shldl $6, %ecx, %eax` -> `0f a4 c8 06`,
   decoding back with no size suffix (both operands are registers, the same
   precedent as `ror $27, %eax`). Register destination only; no fixture
   selects a memory one.

   Regenerating unmasked one further, unrelated gap in the same
   `siphash24.c`: `adcl %ecx, %edx`, ADC's own rm-written-from-reg direction
   (`0x11 /r`). This direction already existed for `Add`/`Xor`/`Sub`/etc
   (M4/M5), and even ADC's own mirror direction (`adcl mem, %reg`, `0x13`)
   was already present - only the `0x11` table entry and its reg-reg
   lowering case were missing, an oversight rather than a new instruction
   family. Byte-checked against real i686-linux-gnu-as: `adcl %ecx, %edx`
   -> `11 ca`. Fixing it also closed a previously-recorded `gas_frontier.t`
   finding: `runtime-i64_umulh` (x86_32's real CompCert runtime helper)
   now assembles and agrees byte-for-byte with real `as` in the differential
   oracle, not just this corpus's own pipeline. Regenerating x86_32's
   `assemble-c` manifest with both fixes reaches 24 blocked/0 rejected -
   every file in this corpus now clears parsing through image binding on
   x86_32, with only external-symbol linking left (M6+ scope).

   Regenerating also surfaced `xorpd __negd_mask, %xmmN` (ccomp's own
   sign-flip idiom for float negation/`fabs`) as the corpus's new
   highest-signal reason (6 recurrences) once `fldl` stopped masking it in
   the same files - now **fixed** too, the same bare-symbol-source duality
   as `movsd`/`movss` below, on `Xorpd` specifically (the only binop
   mnemonic this corpus evidences it for). Byte-checked against real
   i686-linux-gnu-as: `xorpd sym, %xmm5` assembles to `66 0f 57 2d <disp32>`
   with an `R_386_32` relocation.

   Fixing `xorpd` surfaced a real, previously-uncaught bug in the `movsd`/
   `movss` bare-symbol-source fix below (present since it landed earlier
   this session, not introduced by `xorpd`): `expr_of_lowered` had no case
   for `Sse_binop_r_rm`/`Sse_mov_r_rm`/`Sse_mov_rm_r`, so a symbolic `Mem`
   built through any of them never registered its fixup expression - the
   placeholder disp32 byte-checks correctly against real `as` (which only
   proves the *text* is valid GAS syntax) but this project's own image
   binding silently left the placeholder at its all-zero value instead of
   patching in the symbol's real address, with no diagnostic anywhere. A
   direct test through this project's own tool (not just real `as`) caught
   it: `movsd f, %xmm0` decoded back as `movsd 0, %xmm0` instead of the
   resolved address every other symbolic form prints. Fixed by adding all
   three constructors to the same `disp_expr rm` case the GPR forms already
   share (`asm/test/targets/test_targets.ml`'s `movsd`/`movss` test now
   shows the correct resolved address).

   Two unrelated, pre-existing gaps surfaced while chasing the `fldl` fix
   through `gas_frontier.t`'s `vararg`/`i64_dtou` runtime-helper fixtures
   past their own `fldl` blocker to whatever came next. One is now fixed:

   - A real, pre-existing encoding bug, unrelated to x87: an ALU-immediate
     literal written as the unsigned-looking hex spelling of a negative
     value at its own width (`vararg.S`'s real `andl $0xfffffffc, %edx`,
     GAS's own idiom for a 4-byte-alignment mask) failed to encode at all,
     because `alu_form`'s `fits_s8`/`fits_s32` range check ran against the
     raw parsed `Bigint` value (4294967292) rather than that value reduced
     to the instruction's declared width and reinterpreted as signed (which
     is -4, fitting an imm8) - checked against real i686-linux-gnu-as,
     which picks the short form (`83 e2 fc`) precisely because it performs
     that reduction. `$-4` (the decimal spelling of the identical bit
     pattern) already encoded correctly, isolating the bug to hex/wide-
     literal parsing rather than the ALU-immediate form itself. Now
     **fixed**, by a new `to_width_signed` helper applied everywhere a rung
     is chosen by range *and* everywhere the chosen value is threaded into
     the codec (not only the pre-check: the imm8 rung's own `Field`-based
     range check independently re-validates whatever value reaches it, so
     the raw magnitude has to stop surviving past the guard, not merely be
     tested by a corrected one). `imul_imm_form` and `push_imm_form` shared
     the identical pattern and are fixed the same way, checked against real
     `as`: `imull $0xfffffff9, %ecx` -> `6b c9 f9`, `pushl $0xfffffffc` ->
     `6a fc`.

     This bug was masked by a second, independent one in the diagnostic
     itself: `Codec.attempt`'s `Relax` case (`asm/lib/codec/codec.ml`)
     returned `` `No_rung `` - a real failure - when every rung simply
     declined a value that was never a candidate for that ladder in the
     first place (for example, any non-`jmp` instruction reaching the
     `jmp-rel` alternative during the top-level `Alt` scan, since each
     rung's own projection is what declines, not one wrapping the whole
     ladder), rather than `Declined`; since `Alt`'s own scan remembers only
     the *first* such failure and a later real match cannot override it,
     this stayed invisible right up until a value had no encoding anywhere
     at all, at which point the reported cause was `` `No_rung "jmp"` `` -
     "relax jmp: no rung applies" - regardless of which alternative and
     value actually failed, exactly what `andl $0xfffffffc, %edx` reported
     before either fix landed. Now **fixed**: a `Relax` node whose every
     rung declines (none even recognized the value's shape) reports
     `Declined` like an `Alt`'s own `Iso_fun`-decline case, reserving
     `` `No_rung `` for when at least one rung's shape matched but genuinely
     failed to fit. Covered by a dedicated codec-library regression
     (`asm/test/lib/codec/test_codec.ml`'s `relaxed_isa`, modelling the
     exact shape) independent of any target. Fixing both let `vararg.S`
     progress: `gas_frontier.t`'s `x86_32 vararg` finding is now `assembles`
     and matches real `as` byte-for-byte in the differential oracle.
   - `flds` (x87 single-precision *load*, as opposed to `fstps`'s
     single-precision *store* above) is now **fixed**: the same shared-
     opcode-disjoint-extension shape `Fldl`/`Fstpl` already use on `0xDD`,
     here sharing `Fstps`'s own `0xD9` (`ext = 0` for `flds`'s load, `ext =
     3` for `fstps`'s store). `flds LC1` (`i64_dtou.S`'s bare-symbol source)
     needed the identical `mem_of_symbol` duality `lea`/`movsd`/`xorpd`
     already have - scoped to `Flds` alone, since `fldl`/`fstpl`/`fstps`
     never evidence it. Byte-checked against real `i686-linux-gnu-as`:
     `flds 4(%esp)` -> `d9 44 24 04`; `flds LC1` -> `d9 05 <disp32>` with
     `R_386_32`. `gas_frontier.t`'s `x86_32 i64_dtou` finding progressed
     from `flds` to a new, separate gap (`fucomp`, x87 compare-and-pop) -
     not addressed here.
3. **ARM.** `classify-regression`'s `{r0, r1, r2, r3}` register-list operand
   (`varargs1`/`varargs2`/`varargs3`, from `push {r0, r1, r2, r3}`) is
   **fixed**: it needed a new mnemonic, a new operand syntax
   (`Operand.Reglist`, one bit per register number - `arm.ml`'s `regroup`
   already rejoins a brace-grouped operand's comma-split pieces, but per its
   own comment does not reinsert the commas, so the parsed shape is a flat
   `Ident` run, not a comma-separated one), and a new multi-register STMDB
   encoding together (`100100101101`, i.e. `P=1 U=0 S=0 W=1 L=0`, base
   register fixed to SP) - not a small parser addition. Deliberately scoped
   to two-or-more-register `push` only: `push {r4}` is a fixed diagnostic
   rather than the different `str r4, [sp, #-4]!` encoding GNU's own
   canonical printer prefers there, since CompCert's own codegen never emits
   a one-register `push` (only ever the fixed four-argument-register
   varargs-spill shape); see
   `asm/test/targets/test_targets.ml`'s `push {reglist}` tests. Re-running
   the wider `gas_frontier.t` runtime-helper corpus after this fix (not one
   of the four `classify-regression`/`classify-compression` suites, but the
   same frontier check M4 uses) surfaced a sibling, still-open gap the
   register-list parse error had been masking: `pop {reglist}` (used by
   `i64_udivmod`/`i64_umod`'s epilogue) is a genuinely different encoding
   (LDM-class, not STM) and is not implemented here (since fully closed - see
   the ARM `stmia`/`ldmia`/`pop` and `vpush` Follow-ups entries).
   `assemble-c`'s recurring integer/logical/shift family - `eor`/`rsb`/`orr`/
   `mvn`/`lsl`/`nop`, and the further `bic`/`adc`/`adds` and `eor`/`orr`/
   `bic`'s own three-operand immediate form regenerating unmasked along the
   way - is now **fixed**: every one of `eor`(dp=1)/`rsb`(dp=3)/`orr`(dp=12)/
   `bic`(dp=14)/`mvn`(dp=15)/`adc`(dp=5) is the identical `Dp_imm`/`Dp_reg`
   shape `add`/`sub`/`and`/`mov`/`cmp`(dp=0/2/4/10/13) already lower - one
   more `to_dp`/`of_dp` table entry each, no new codec alt - except `mvn`,
   which reuses `mov`'s own two-operand (no `rn`) shape rather than the
   three-operand one. `adds` (evidenced only as `add`'s own flag-setting
   three-register form, `siphash24.c`'s 64-bit-add lower half, its upper half
   the plain `adc` above) needed its own opcode and dedicated lowering/
   printing case instead of joining that generic table: a `dp` value alone
   cannot distinguish `add` from `adds`, only the pre-existing `s` field can,
   and the generic lowering always produces `s = false`. `lsl`/`lsr`/`asr`/
   `ror rd, rm, rs` (register-shift-amount form, evidenced only as `lsl`) are
   GNU's own mnemonics for `mov` with a register-specified shift amount - a
   different word shape from the already-supported immediate-shift-amount
   one (bit 4 is the immediate/register discriminator, and `Rs` sits where
   the 5-bit immediate amount otherwise would), so this added a dedicated
   `Lowered.Shift_reg` and codec alt rather than widening `Dp_reg`. `nop` is
   the dedicated ARMv7 hint-NOP word (`e320f000`, the same bytes `nop_bytes`
   already pads a section with), now reachable from a source-level `nop`
   mnemonic too, added as its own codec alt at a negative priority so it is
   tried before `dp-imm` swallows its overlapping fixed bits (the same
   overlap `movw`/`movt` already document). Every form byte-checked against
   real `arm-linux-gnueabihf-as`/`objdump`; see
   `asm/test/targets/test_targets.ml`'s dedicated tests. Regenerating
   `assemble-c`'s arm manifest through this whole chain (each fix unmasking
   the next, the same iterative pattern as x86_32's `lea`/`fldl`/`shldl`
   chain above) moved arm from 3 blocked/21 rejected to 13 blocked/11
   rejected: every remaining rejection reason (`vdiv.f32`/`vmul.f32`/`vldr`,
   9 recurrences) is now VFP floating-point, the deliberate second slice
   Ordered Work item 3 defers - the integer/logical/shift slice is fully
   closed for this corpus.

   The floating-point slice's first ARM cut, `vadd`/`vsub`/`vmul`/`vdiv.f32`
   (register-register-register, `fftsp.c`/`knucleotide.c`), is now **fixed**:
   the double-precision family already had a complete codec end to end
   (`Lowered.V3_d`/`Lowered.V3_s` were both defined and both encoded/decoded
   correctly, since M1), so only the single-precision *entry points* were
   missing - a `.f32` row in the mnemonic table, and a three-`Sreg` lowering
   case alongside the existing three-`Dreg` one. Byte-checked against real
   `arm-linux-gnueabihf-as`/`objdump` (`-mfpu=vfpv3`): `vmul.f32 s24, s26,
   s6` -> `ee2dca03`, `vdiv.f32 s24, s26, s6` -> `ee8dca03`, `vadd.f32 s0,
   s1, s2` -> `ee300a81`, `vsub.f32 s0, s1, s2` -> `ee300ac1` - all four
   bit-for-bit identical to the pre-existing `.f64` encoder with S registers
   in place of D ones, confirming the codec itself needed no change.

   Caught before it reached any fixture, a real, independent bug: the one
   shared `Opcode.V3 of V3.op` constructor could not tell its own two widths
   apart (only the *operands* it was paired with could), so `Opcode.name` -
   which prints any not-yet-lowered `Instruction.t` for
   `--dump-disasm=canonical`/diagnostics - hard-coded the `.f64` spelling
   regardless of which width a given instance actually carried. Decoding a
   real `.f32` instruction and printing it canonically therefore emitted
   `vmul.f64 s24, s26, s6` - S registers under an `.f64` mnemonic, text real
   `as` rejects outright (`invalid instruction shape`) even though this
   project's own re-lowering happened to still accept it (operand shape, not
   the mnemonic suffix, is what actually selects `V3_d` vs. `V3_s`) - quietly
   defeating `--dump-disasm=canonical`'s own "exactly re-parseable" contract
   for exactly the width this change was adding. Fixed by splitting
   `Opcode.V3` into `Opcode.V3d`/`Opcode.V3s`, the same pattern every other
   ARM width pair in this file already uses (`Vneg_d`/`Vneg_s`,
   `Vcmp_d`/`Vcmp_s`, ...): confirmed by feeding `--dump-disasm=canonical`'s
   own output back through real `arm-linux-gnueabihf-as` (it failed before
   this fix, and now assembles byte-identically to the original).

   Regenerating arm's `assemble-c` manifest at that point left the 13
   blocked/11 rejected totals unchanged - both `fftsp.c` and `knucleotide.c`
   also contain `vldr sN, .Lxxx` (a PC-relative literal-pool load), which was
   already masking the same file's `.f32` rejection and now blocked it
   directly - but it collapsed the reason count: `vdiv.f32`/`vmul.f32` were
   gone, leaving `vldr` (`reason:11`, was `reason:9` plus these two files'
   own reasons) as arm's *only* remaining `assemble-c` rejection reason.

   That capability - `vldr sN/dN, .Lxxx` with an implicit PC base and no
   explicit register operand, structurally distinct from the already-complete
   `Vmem_d`/`Vmem_s` (base register plus a resolved-at-lowering-time constant
   offset, never a symbolic one) - is now **fixed**: a new `Lowered.Vldr_lit_d`/
   `Vldr_lit_s` carries a symbolic target (`Asm_core.Lowered_ast.branch`, the
   same type `b`/`bl`/`movw`/`movt` already use), and a new `Pcrel_vldr8`
   fixup kind computes `target - (place + 8)` the same way `Pcrel_b26`
   already does. Scoped to load only (`vstr` never reaches the new lowering
   case: real hardware defines the store encoding's `Rn = 1111` as
   UNPREDICTABLE, and GAS only accepts it with a deprecation warning, no
   fixture spells it) and forward-only (`U` is fixed to 1 in the codec, not a
   field the fixup carries - every corpus occurrence is a trailing
   same-function literal pool, and a backward target is now a dedicated
   diagnostic, `vldr literal-pool target must follow the instruction`, rather
   than a silent wraparound). The new codec alt necessarily overlaps
   `Vmem_d`/`Vmem_s`'s own fixed bits (their `Rn`/`U`/`L` are wildcards, so an
   `Rn=1111`/`U=1`/`L=1` instance already fits both) and is given the lower
   priority so they win on decode: real `objdump` disassembles this exact
   word as `vldr sN, [pc, #imm]`, never a bare label, and this project's own
   canonical disassembly now matches that choice bit-for-bit (confirmed by
   feeding a decoded instance back through `--dump-disasm=canonical` and
   real `arm-linux-gnueabihf-as`) rather than round-tripping through a
   spelling nothing re-parses back to the identical word. Byte-checked
   against real `arm-linux-gnueabihf-as`/`objdump`: `vldr s0, .L1` (16 bytes
   ahead) -> `ed9f0a04`, `vldr d1, .L2` (4 bytes ahead) -> `ed9f1b01`, both
   resolving to the identical distances real `as` computes. Regenerating
   arm's `assemble-c` manifest with this fix reaches **24 blocked/0
   rejected**: every file in this corpus now clears parsing through image
   binding on ARM too, matching x86_32/x86_64's already-fully-closed state,
   with only external-symbol linking (M6+ scope) left. `asm-fixture-oracle-arm`
   (the hand-picked byte/QEMU corpus) stayed green throughout, confirming no
   drift in any previously-verified encoding.
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

- `classify-c-gcc`'s first-increment findings (see "`classify-c-gcc`: a
  second, independent-compiler corpus" above) are now fully closed: all six
  targets reach 24/24, including ARM's last two gaps, `vpush {dN, ...}` (a
  new `Operand.Dreglist`, D-register reglist push, unrelated to the already-
  supported GPR one - and, discovered while closing it, gcc actually spells
  the list as a hyphenated range, `{d8-d9}`, not the flat comma form
  `{d8, d9}` GPR `push` uses) and `stmia`/`ldm`/`pop {reglist}`'s own bare
  `Rn!` writeback base (a new `Operand.Reg_writeback`, structurally different
  from the now-supported bracketed `str`/`ldr` writeback). Both fixes were
  parse-level only at the time, the same scope as `x86.lower`'s
  `Operand.Imm_sym`/`x86.simplify`'s `%st(n)` below: `dump-source-ast`'s
  operand-only check is what closed them, not real lowering. Both are since
  fully closed too - see "ARM `stmia`/`pop {reglist}`" and "ARM `vpush`" just
  below. `x86.lower`'s `Operand.Imm_sym` is now fully closed too - see
  "x86 `movl $sym, %reg`"/"x86 `addq $sym, %reg`"/"x86 `pushl $sym`" below -
  but `x86.simplify`'s `%st(n)` remains a parse-level-only closure not yet
  triaged into "Capability ladder"'s scope-exclusion-or-real-gap grouping
  below.
- ARM `stmia`/`ldmia`/`pop {reglist}` (LDM-class - a genuinely different
  encoding from `push`'s STM-class one, not a shared form with a direction
  bit): evidenced by `gas_frontier.t`'s runtime-helper corpus (`i64_udivmod`/
  `i64_umod`) and by classify-c-gcc's `aes.c` (`stmia r3!, {r0, r1}`). Now
  fixed: `Opcode.Stmia`/`Opcode.Ldmia`/`Opcode.Pop` all lower into one
  `Lowered.Ldm` (cond, load, rn, regs), a 32-bit word with P=0/U=0/S=0/W=1
  fixed (increment-after, writeback forced - the only evidenced shape) and
  L/Rn/reglist variable. `pop` lowers into the same form with `rn` fixed to
  `sp`, mirroring `push`'s own relationship to `stmdb sp!`; decoding
  collapses a load with `rn = sp` and two or more registers back to `pop`,
  matching real `objdump`'s own alias choice (verified: `ldmia sp!, {r0}` -
  a single register - disassembles as `ldmfd sp!, {r0}`, not `pop {r0}`,
  since real `pop {r0}` is the unrelated `ldr r0, [sp], #4` encoding; `pop`
  here keeps `push`'s existing two-or-more-registers scope for the same
  reason). Byte-for-byte checked against real
  arm-linux-gnueabihf-as/objdump. With this fixed, `gas_frontier.t`'s
  `i64_udiv`/`i64_umod` now progress past `pop` to a later, separate
  finding: an undefined `__compcert_i64_udivmod` reference (an
  `image.undefined` multi-file-linking gap, not an assembler one).
- ARM `vpush {dN, ...}` (VSTM-class - the D-register cousin of `push`'s
  STMDB one, evidenced by classify-c-gcc's `almabench.c`/`fft.c`/`fftsp.c`/
  `perlin.c`): now fixed. `Opcode.Vpush` lowers into `Lowered.Vpush` (cond,
  vd, count), a base D register plus a register count rather than a
  bitmask - VSTM-class encodings have no bitmask field, only
  `imm8 = count * 2`. Lowering requires the operand's `Dreglist` to be
  non-empty, ascending, and contiguous (both `{d8, d9}` and gcc's own
  `{d8-d9}` already parsed to the identical list, so no further parser
  change was needed). Byte-for-byte checked against real
  arm-linux-gnueabihf-as/objdump (`-march=armv7-a -mfpu=vfpv3`): `ed2d8b04`
  for `vpush.64 {d8, d9}` (2 registers, identical bytes for `{d8-d9}`),
  `ed2d8b06` for `{d8-d10}` (3), `ed2d8b02` for `{d8}` (1, no separate
  one-register alias the way GPR `push` needs), and `ed6d0b04` for
  `{d16-d17}` (a base register at D16+, exercising the D:Vd split's high
  half).
- x86 `movl $sym, %reg` (`Operand.Imm_sym` in `mov`'s register-destination
  form; gcc's idiom for materializing a string/array address into a
  register): now fixed. `Lowered.Mov_r_imm`'s `imm` field became a `Disp.t`
  (was a bare `int64`) so it can carry a symbol the same way a memory
  displacement already could; the field codec swapped a plain little-endian
  field for `sym_imm32`, a fixup-carrying sibling of the existing `sym_disp`
  (decode masks rather than sign-extends, to keep the change purely additive
  for every already-round-tripping constant value). Byte-checked against
  real i686-linux-gnu-as/x86_64-linux-gnu-as: `movl $sym, %eax` assembles to
  `b8 <disp32>` with an `R_386_32` relocation on x86-32 and `R_X86_64_32` on
  x86-64 - the same absolute-address relocation kind `mov`'s `mem_of_symbol`
  disp32 form already uses.
- x86 `addq $sym, %reg` (`Operand.Imm_sym` in the ALU ops' immediate form;
  gcc's idiom for address arithmetic against a symbol's own address rather
  than through `lea`): now fixed the same way. `Lowered.Alu_rm_imm`'s `imm`
  field became a `Disp.t` too; its imm32 rung reuses `sym_imm32`, keeping
  this form's own prior sign-extending decode (unlike `Mov_r_imm`'s
  unsigned one - the two callers disagreed before either carried a symbol,
  so `sym_imm32` took a `signedness` parameter rather than picking one).
  The imm8 rung can never carry a symbol - GAS never picks it for a
  symbolic operand regardless of the offset's own magnitude - so it is
  wrapped in `const_disp` purely for the tuple shape both rungs of the
  ladder must share. Byte-checked against real `x86_64-linux-gnu-as`:
  `addq $sym, %rcx` assembles to `48 81 c1 <disp32>` with an
  `R_X86_64_32S` relocation - *signed*, unlike `mov`'s `R_X86_64_32`.
  Discovered while checking that: the corpus's literal spelling,
  `addq $sym, %rax` (the accumulator), doesn't byte-match yet at all,
  symbolic or not - real `as` picks a shorter, ModR/M-less encoding
  (`05 id`) for a full-width immediate against the accumulator specifically,
  an encoder gap this project already had before this change (confirmed
  with a plain, non-symbolic `addl $1000, %eax`: real `as` gives
  `05 e8 03 00 00`, five bytes, where this project's only ALU-immediate
  form gives the seven-byte ModR/M `81 c0 e8 03 00 00`) - not evidenced by
  any corpus rejection today (nothing here fails to *lower*, it just
  wouldn't byte-match a differential GNU-as gate yet), so left unfixed
  until that gate exists.
- x86 `pushl $sym` (`Operand.Imm_sym` in `push`'s immediate form): now fixed,
  the last of the three symbolic-immediate sub-gaps. Unlike `mov`/the ALU
  ops, `push` had no non-symbolic immediate lowering at all before this - a
  new `Lowered.Push_imm` constructor carries a `Disp.t` immediate alongside
  the existing register-only `Lowered.Push`, with its own `0x6a ib`/`0x68
  id` short/long ladder (the same short-immediate-first priority and
  `fits_s8`/`fits_s32` check as `Alu_rm_imm`'s form; a symbolic immediate
  always forces the `id` rung, same as the ALU form above). Byte-checked
  against real i686-linux-gnu-as: `pushl $sym` assembles to `68 <disp32>`
  with an `R_386_32` relocation, and `pushl $100` still picks the
  pre-existing `6a 64` short form unchanged. All three sub-gaps of
  `Operand.Imm_sym` (`mov`, the ALU ops, `push`) are now closed; the
  accumulator-destination ALU encoding gap noted above remains open on its
  own.
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
