/* expect: 947836 */
/* Dense switches, which CompCert compiles to jump tables, plus a sparse one
   that stays a compare chain. */

typedef long long i64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

static int dense(int x)
{
  switch (x) {
  case 0: return 3;
  case 1: return 14;
  case 2: return 15;
  case 3: return 92;
  case 4: return 65;
  case 5: return 35;
  case 6: return 89;
  case 7: return 79;
  case 8: return 32;
  case 9: return 38;
  default: return 1000;
  }
}

static int sparse(int x)
{
  switch (x) {
  case 1: return 1;
  case 100: return 2;
  case 10000: return 3;
  case -5: return 4;
  default: return 0;
  }
}

long entry(void *io)
{
  i64 acc = 0;
  int i;
  for (i = -2; i < 14; i++) acc = acc * 3 % 1000003 + dense(i);
  acc += sparse(1) + 10 * sparse(100) + 100 * sparse(10000) + 1000 * sparse(-5) + sparse(7);
  return fold(acc);
}
