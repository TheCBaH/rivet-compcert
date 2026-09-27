/* 32-bit division for CompCert's arm target.

   CompCert configured for armv7a, which has no divide instruction, calls
   __aeabi_idiv and __aeabi_uidiv (AAPCS run-time ABI) for / on int and
   unsigned; ccomp's link takes them from libgcc. The embed has no libgcc,
   so these are the same functions, compiled by the embedded CompCert
   itself. They are written without / or %, which would call them.

   Remainders are not needed: CompCert computes n % d as n - (n / d) * d.
   Division by zero is undefined in C; these return 0 for it. */

unsigned __aeabi_uidiv(unsigned n, unsigned d)
{
  unsigned q = 0, r = 0;
  int i;
  if (d == 0) return 0;
  for (i = 31; i >= 0; i--) {
    /* r < d here, so 2r + bit < 2^33: [top] is the bit that falls off */
    unsigned top = r >> 31;
    r = (r << 1) | ((n >> i) & 1u);
    if (top || r >= d) {
      r -= d;
      q |= 1u << i;
    }
  }
  return q;
}

int __aeabi_idiv(int n, int d)
{
  unsigned un = n < 0 ? 0u - (unsigned)n : (unsigned)n;
  unsigned ud = d < 0 ? 0u - (unsigned)d : (unsigned)d;
  unsigned q = __aeabi_uidiv(un, ud);
  return (n < 0) != (d < 0) ? (int)(0u - q) : (int)q;
}
