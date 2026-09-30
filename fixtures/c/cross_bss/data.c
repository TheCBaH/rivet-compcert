/* The other half of M3's cross-file .bss/.comm slice - see caller.c.

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
