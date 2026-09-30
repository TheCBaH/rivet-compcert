/* M2's arithmetic slice (.ai/asm_plan.md §12, Milestone 2).

   Two functions, because the slice has two halves that must not be merged.
   [asm_test_sum] is where integer *arguments* live: it is exported and never
   called, so argument-register lowering is exercised without introducing a
   call - and therefore without a relocation, which belongs to direct_call.
   [asm_test_entry] is the executable half, and X1 requires it to take no
   arguments and return a determined value.

   The locals are [volatile] so CompCert cannot fold the whole computation to
   [return 42] and leave nothing to assemble. That also makes the entry emit
   stack loads and stores, which is the memory shape this slice wants.

   Two globals in one unit is deliberate: it is what makes entry selection a
   real decision rather than the single-global inference M1 could get away
   with.

   Deliberately no division or modulo. CompCert lowers `/ 3` to a signed
   multiply-high magic-number sequence - smull/mla on ARM, madd/sxtw on
   AArch64, imull/shrl on x86 - and that is a lowering axis of its own, not the
   add/sub/mul this slice is for. It can have its own fixture when it is worth
   one. */
int asm_test_sum(int a, int b, int c, int d) { return (a + (b * c)) - d; }

int asm_test_entry(void)
{
  volatile int a = 7, b = 5, c = 9;
  int x = a * b;
  int y = x - c;
  return y + (b * 2) + 6;
}
