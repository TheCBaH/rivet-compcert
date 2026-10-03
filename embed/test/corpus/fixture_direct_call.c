/* expect: 42 */
/* Seeded from the direct_call fixture (asm/fixtures/compcert-3.17/direct_call), with an entry wrapper. */

/* The direct-call slice.

   The [+ 2] is load-bearing. Written as `return asm_test_callee(20);` this
   becomes a tail branch on x86-64, ARM and AArch64, and the fixture would
   contain no call and no call relocation - passing every byte gate while
   testing nothing it was written for. Consuming the result forces a real
   call/bl, and tools/asm-fixture-gen.sh gates on the instruction by name so a
   future compiler cannot quietly take it away again.

   The callee is exported rather than static so the call is to a global symbol,
   which is the case where the four targets disagree about whether a
   relocation survives assembly at all. */
int asm_test_callee(int x) { return x + x; }

int asm_test_entry(void) { return asm_test_callee(20) + 2; }

long entry(void *io) { return asm_test_entry(); }
