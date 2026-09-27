/* expect: 0 */
/* Integer odds and ends: unsigned and signed division and shifts, 64-bit
   multiply, bitfields, function pointers, and a string table. Returns the
   number of failed checks. */

struct flags { unsigned a : 3; unsigned b : 5; int c : 7; };

static int add(int x, int y) { return x + y; }
static int mul(int x, int y) { return x * y; }
static int (*const ops[2])(int, int) = { add, mul };
static const char *const names[3] = { "zero", "one", "two" };

static int length(const char *s) { int n = 0; while (s[n]) n++; return n; }

long entry(void *io)
{
  int bad = 0;
  volatile int neg = -17, five = 5;
  volatile unsigned big = 0xF0000000u;
  volatile long long w = 0x123456789LL;
  struct flags f;
  f.a = 5; f.b = 17; f.c = -20;
  if (neg / five != -3) bad++;
  if (neg % five != -2) bad++;
  if (big >> 28 != 15u) bad++;
  if ((neg >> 1) != -9) bad++;
  if (w * 16 != 0x1234567890LL) bad++;
  if ((unsigned long long)w / 3 != 0x61172283ULL) bad++;
  if (f.a != 5 || f.b != 17 || f.c != -20) bad++;
  if (ops[0](3, 4) != 7 || ops[1](3, 4) != 12) bad++;
  if (length(names[0]) + length(names[1]) + length(names[2]) != 10) bad++;
  return bad;
}
