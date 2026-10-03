/* expect: 22 */
/* Seeded from the cross_bss fixture (asm/fixtures/compcert-3.17/cross_bss): its two sources merged into one translation unit, with an entry wrapper. */

/* The other half of the cross-file .bss/.comm slice - see caller.c.

   Deliberately uninitialized: a tentative definition of a non-static
   global is exactly the construct CompCert routes to `.comm` (under its
   default -fcommon behavior) rather than an ordinary `.data`/`.bss` label
   - see PrintAsmaux.ml's variable_section and each target's own
   print_comm_symb in its TargetPrinter.ml. The GNU linker then folds
   every `.comm` declaration of this name into a single
   reservation in the canonical `.bss` output section, which is the
   allocation this fixture exists to carry through this project's own
   internal linker (asm/lib/image/image.ml's strong/common/weak
   resolver) instead. */
int shared_value;

/* The cross-file .bss/.comm slice. shared_value is declared but never
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

long entry(void *io) { return asm_test_entry(); }
