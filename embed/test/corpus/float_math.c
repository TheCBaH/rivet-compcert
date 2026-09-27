/* expect: 2718280958044 */
/* double and float arithmetic, constants that do and do not fit fmov's
   immediate form, conversions both ways, and a floating-point loop. */

static double poly(double x) { return ((0.5 * x - 1.25) * x + 3.0) * x - 0.1; }
static float halve(float f) { return f * 0.5f; }

long entry(void *io)
{
  double e = 1.0, term = 1.0;
  int i;
  for (i = 1; i < 20; i++) {
    term /= i;
    e += term;
  }
  double p = poly(2.0) + poly(-1.5);      /* 3.9 + (-8.9125) */
  float f = halve(3.0f) + (float)i;       /* 1.5 + 20 */
  long check = (long)(p * 10000.0) + (long)(f * 2.0f);
  unsigned u = 4000000000u;
  double du = u;
  if ((unsigned)du != u) return -2;
  return (long)(e * 1000000.0) * 1000000 + check;
}
