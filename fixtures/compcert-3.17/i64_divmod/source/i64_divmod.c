/* M4 (.ai/asm_plan.md §12): the CompCert-runtime-helper fixture. Two
   volatile long long operands force real __compcert_i64_sdiv/
   __compcert_i64_smod runtime calls on x86_32 (which has no 64-bit divide
   instruction) rather than a compile-time-folded constant - the whole
   point of this fixture. The two result globals are what make the
   quotient and remainder independently observable after return, via the
   v3 ABI's Image.exports-resolved observation protocol
   (docs/exec-abi-v3.md); their compile-time initializer is a nonzero
   placeholder purely so CompCert places them in .data rather than
   .bss/.comm (an uninitialized global routes there, which the fixture
   gate rejects for a case without a carve-out) - it carries no meaning
   and is always overwritten before being observed.

   Arithmetic, checked by hand (C99 truncating division, remainder sign
   follows the dividend): 13 * 538461538 = 6999999994,
   7000000000 - 6999999994 = 6, so -7000000000 / 13 = -538461538
   remainder -6. */
volatile long long i64_divmod_dividend = -7000000000LL;
volatile long long i64_divmod_divisor = 13LL;
long long i64_divmod_quotient = -1;
long long i64_divmod_remainder = -1;

int asm_test_entry(void)
{
  i64_divmod_quotient = i64_divmod_dividend / i64_divmod_divisor;
  i64_divmod_remainder = i64_divmod_dividend % i64_divmod_divisor;
  return 42;
}
