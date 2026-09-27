/* expect: -1489641617 */
/* Narrow integer types and 32-bit division: signed and unsigned char and
   short loads, stores and extensions; a struct of shorts large enough to be
   copied by CompCert's memcpy loop at 2-byte alignment; and int / and %
   over mixed signs and magnitudes (the __aeabi_* division on arm). */

typedef long long i64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

struct shorts { short v[40]; };

static signed char sc[8] = { -128, -1, 0, 1, 127, -77, 33, -5 };
static unsigned char uc[8] = { 0, 1, 127, 128, 200, 255, 17, 90 };
static short ss[8] = { -32768, -1, 0, 1, 32767, -12345, 2222, -7 };
static unsigned short us[8] = { 0, 1, 32767, 32768, 50000, 65535, 4321, 9 };

static struct shorts copy_shorts(struct shorts s) { struct shorts t = s; t.v[0] = -t.v[0]; return t; }

long entry(void *io)
{
  volatile int nv[7] = { 0, 7, -7, 1000000007, -2147483647, 2147483647, 65536 };
  volatile int dv[6] = { 1, -1, 3, -10, 65537, 2147483647 };
  volatile unsigned un[4] = { 0u, 5u, 4000000000u, 4294967295u };
  volatile unsigned ud[4] = { 1u, 3u, 65536u, 4294967295u };
  unsigned char *p = io;
  short *q = (short *)((char *)io + 64);
  struct shorts a, b;
  i64 h = 17;
  int i, j;
  for (i = 0; i < 8; i++) {
    p[i] = uc[i] + sc[i];
    q[i] = (short)(ss[i] * 3 + us[i]);
    h = h * 31 + sc[i] + uc[i] + ss[i] + us[i] + (signed char)p[i] + q[i] + (unsigned short)q[i];
  }
  for (i = 0; i < 40; i++) a.v[i] = (short)(i * 1111 - 20000);
  b = copy_shorts(a);
  for (i = 0; i < 40; i++) h = h * 7 + b.v[i];
  for (i = 0; i < 7; i++)
    for (j = 0; j < 6; j++) {
      if (nv[i] == -2147483647 - 1 && dv[j] == -1) continue;
      h = h * 13 + nv[i] / dv[j] + nv[i] % dv[j];
    }
  for (i = 0; i < 4; i++)
    for (j = 0; j < 4; j++) h = h * 11 + un[i] / ud[j] + un[i] % ud[j];
  return fold(h);
}
