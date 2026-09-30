/* The other half of M3's cross-file data reference slice - see caller.c.

   Non-zero on purpose, for the same reason global_ldst.c's is: CompCert
   routes an uninitialized or all-zero global to .comm or .bss, and this
   fixture is testing the ordinary PROGBITS .data cross-reference, not
   common/NOBITS storage - that is cross_call's and a future fixture's
   territory, not this one's. */
int shared_value = 20;
