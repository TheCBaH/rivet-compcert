/* The other half of M3's cross-file call slice - see caller.c. Exported
   rather than static, so the call from caller.c is to a global symbol that
   only the link (not this file alone) can resolve. */
int asm_test_callee(int x) { return x + x; }
