/* M3's cross-file data reference slice (.ai/asm_plan.md Milestone 3, section 12).

   shared_value is declared but never defined in this translation unit - the
   defining half lives in data.c, a separate input to the same link. This is
   global_ldst's own load/store pair, generalized across a real module
   boundary: PC-relative on x86-64, absolute on x86-32, a page/low-12 pair on
   AArch64, a movw/movt pair on ARM, and RISC-V's own pcrel-hi20/pcrel-lo12-i
   (load) and pcrel-lo12-s (store) split, each anchored on a numeric local
   label paired within this file but pointing at a symbol this file never
   defines - exactly the case M3's internal linker exists to resolve without
   ever invoking an external one. */
extern int shared_value;

int asm_test_entry(void)
{
  int v = shared_value;
  shared_value = v + 22;
  return shared_value;
}
