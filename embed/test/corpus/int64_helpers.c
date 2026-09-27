/* expect: 1508589552 */
/* qemu x86_32: 414990084 -- qemu-i386 (10.0) applies the x87 precision-control
   field to fld/fistp, which hardware does not, and CompCert's x86_32
   i64_dtos/i64_dtou set it to single while truncating. The same value comes
   from this program's CompCert assembly built with GNU as/ld under the same
   QEMU. */
/* Every operation CompCert may implement with a __compcert_i64_* runtime
   helper on a 32-bit target, on values that reach the helpers' interesting
   paths: signed and unsigned 64-bit division and remainder by a variable
   (both operand signs, 64-bit and 32-bit-sized divisors) and by a
   constant (a multiply-high), variable shifts across the 32-bit boundary,
   and conversions between 64-bit integers and double/float, including
   unsigned values past 2^63. Each result is mixed into a checksum. */

typedef long long i64;
typedef unsigned long long u64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

static u64 mix(u64 h, u64 v) { return (h ^ v) * 0x100000001b3ULL + (v >> 7); }

long entry(void *io)
{
  volatile i64 sv[6] = { -7000000000LL, 7000000000LL, -13, 123456789012345LL,
                         -9223372036854775807LL - 1, 1 };
  volatile i64 sd[4] = { 13, -13, 1000000007LL, -4294967311LL };
  volatile u64 uv[4] = { 18446744073709551557ULL, 12345678901234567ULL,
                         9223372036854775808ULL, 5 };
  volatile u64 ud[3] = { 7, 4294967311ULL, 18446744073709551615ULL };
  volatile int sh[5] = { 0, 1, 31, 32, 63 };
  volatile double dv[4] = { 1.5e18, -2.75e15, 9.3e18, 123.99 };
  u64 h = 1469598103934665603ULL;
  int i, j;
  for (i = 0; i < 6; i++)
    for (j = 0; j < 4; j++) {
      h = mix(h, (u64)(sv[i] / sd[j]));
      h = mix(h, (u64)(sv[i] % sd[j]));
    }
  for (i = 0; i < 4; i++)
    for (j = 0; j < 3; j++) {
      h = mix(h, uv[i] / ud[j]);
      h = mix(h, uv[i] % ud[j]);
    }
  for (i = 0; i < 6; i++) h = mix(h, (u64)(sv[i] / 7));
  for (i = 0; i < 4; i++) h = mix(h, uv[i] / 7);
  for (i = 0; i < 6; i++)
    for (j = 0; j < 5; j++) {
      h = mix(h, (u64)sv[i] << sh[j]);
      h = mix(h, (u64)(sv[i] >> sh[j]));
      h = mix(h, (u64)sv[i] >> sh[j]);
    }
  for (i = 0; i < 6; i++) {
    h = mix(h, (u64)(i64)((double)sv[i] / 1024.0));
    h = mix(h, (u64)(i64)((float)sv[i] / 1024.0f));
  }
  for (i = 0; i < 4; i++) {
    h = mix(h, (u64)((double)uv[i] / 4096.0));
    h = mix(h, (u64)((float)uv[i] / 4096.0f));
  }
  for (i = 0; i < 4; i++) {
    if (dv[i] < 9.2e18) h = mix(h, (u64)(i64)dv[i]);   /* in range for long long */
    if (dv[i] >= 0) h = mix(h, (u64)dv[i]);
  }
  return fold((i64)h);
}
