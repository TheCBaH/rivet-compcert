/* The M1 walking skeleton (.ai/asm_plan.md). Compiled by four unmodified
   CompCert 3.17 configurations; the 26 instruction forms those four outputs
   contain *are* the M1 scope.

   Deliberately minimal: the point is not to exercise the compiler but to pin a
   relocation-free .text whose bytes our assembler must reproduce exactly. The
   only relocation any of the four objects carries is R_*_PC32/PREL32 in
   .eh_frame, from .cfi_*, which we discard. */
int asm_test_entry(void) { return 42; }
