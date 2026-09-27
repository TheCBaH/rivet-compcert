/* expect: 42 */
/* Seeded from the cross_call fixture (asm/fixtures/compcert-3.17/cross_call): its two sources merged into one translation unit, with an entry wrapper. */

/* The other half of M3's cross-file call slice - see caller.c. Exported
   rather than static, so the call from caller.c is to a global symbol that
   only the link (not this file alone) can resolve. */
int asm_test_callee(int x) { return x + x; }

/* M3's cross-file call slice (.ai/asm_plan.md Milestone 3, section 12).

   asm_test_callee is declared but never defined in this translation unit -
   the defining half lives in callee.c, a separate input to the same link.
   CompCert therefore cannot resolve the call within this file the way
   direct_call's same-file callee lets it: on x86_64 the call is spelled
   [call asm_test_callee@PLT], and on riscv32/riscv64 [call asm_test_callee@plt] -
   the same R_*_PLT32/R_RISCV_CALL_PLT-class relocation direct_call already
   exercises, but only reachable across a real module boundary, which is
   exactly what M3's internal linker exists to resolve without ever invoking
   an external one. */
extern int asm_test_callee(int x);

int asm_test_entry(void) { return asm_test_callee(20) + 2; }

long entry(void *io) { return asm_test_entry(); }
