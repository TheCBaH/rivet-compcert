/* expect: 42 */
/* Seeded from the cross_data fixture (asm/fixtures/compcert-3.17/cross_data): its two sources merged into one translation unit, with an entry wrapper. */

/* The other half of the cross-file data reference slice - see caller.c.

   Non-zero on purpose, for the same reason global_ldst.c's is: CompCert
   routes an uninitialized or all-zero global to .comm or .bss, and this
   fixture is testing the ordinary PROGBITS .data cross-reference, not
   common/NOBITS storage - that is cross_call's and a future fixture's
   territory, not this one's. */
int shared_value = 20;

/* The cross-file data reference slice.

   shared_value is declared but never defined in this translation unit - the
   defining half lives in data.c, a separate input to the same link. This is
   global_ldst's own load/store pair, generalized across a real module
   boundary: PC-relative on x86-64, absolute on x86-32, a page/low-12 pair on
   AArch64, a movw/movt pair on ARM, and RISC-V's own pcrel-hi20/pcrel-lo12-i
   (load) and pcrel-lo12-s (store) split, each anchored on a numeric local
   label paired within this file but pointing at a symbol this file never
   defines - exactly the case the internal linker exists to resolve without
   ever invoking an external one. */
extern int shared_value;

int asm_test_entry(void)
{
  int v = shared_value;
  shared_value = v + 22;
  return shared_value;
}

long entry(void *io) { return asm_test_entry(); }
