/* M2's conditional slice (.ai/asm_plan.md §12, Milestone 2).

   Comparison and conditional selection, which is where the condition code
   stops being a constant: ARM's A32 condition field is [cond_al] throughout
   M1 and becomes a real field here, and x86 gains cmp/jcc.

   Both branches are to same-section local labels, so GNU as resolves them
   while assembling and the object carries no .text relocation for them. They
   are still fixups for this assembler, which has to lay out, relax, bind and
   patch them - that asymmetry is exactly what the oracle's fixup
   classification exists to express.

   [volatile] keeps the comparison from being folded away. */
int asm_test_entry(void)
{
  volatile int a = 20, b = 22;
  int m = (a < b) ? b : a;
  int n = (a > b) ? a : b;
  return (m == n) ? m + 20 : 0;
}
