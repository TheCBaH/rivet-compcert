/* M3's cross-file .bss/.comm slice (.ai/asm_plan.md Milestone 3, follow-up
   2). shared_value is declared but never
   defined in this translation unit - the defining half lives in data.c, a
   separate input to the same link, exactly as in cross_data. The
   difference from cross_data is entirely in data.c: there the global is
   given a non-zero initializer on purpose, to test the ordinary PROGBITS
   cross-reference without touching common/NOBITS storage; here it is left
   uninitialized on purpose, so CompCert routes its definition through
   `.comm` and the GNU linker realizes that reservation into `.bss` - the
   path cross_data explicitly avoided and `fixture_gate.ml`'s blanket
   Comm_or_local/Bss_or_nobits rejection existed to keep out of every case
   except this one. */
extern int shared_value;

int asm_test_entry(void)
{
  int v = shared_value;
  shared_value = v + 22;
  return shared_value;
}
