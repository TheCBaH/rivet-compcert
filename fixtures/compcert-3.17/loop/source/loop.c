/* M2's loop slice (.ai/asm_plan.md §12, Milestone 2).

   A backward branch, which is what turns relaxation from a design note into a
   requirement: GNU as encodes both the forward exit test and the backward
   latch of this loop in two bytes on x86-32 and x86-64 (`7d 08`, `eb f0`).
   An assembler that always emitted the near forms would still be correct and
   would still fail the byte-for-byte gate, so M2.F0 has to select rel8 the
   same way.

   The bound is [volatile] so the loop survives; the body adds 7 six times so
   the result is 42 without a trailing fudge constant. */
int asm_test_entry(void)
{
  volatile int n = 6;
  int s = 0;
  for (int i = 0; i < n; i++) s += 7;
  return s;
}
