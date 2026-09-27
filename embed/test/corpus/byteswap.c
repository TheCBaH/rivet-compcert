/* expect: -364808335 */
/* CompCert's byte-swap and bit-count builtins, which each target expands
   inline (x86 bswap/rolw/bsr/bsf, arm and aarch64 rev/rev16/clz/rbit,
   shifts, masks and loops elsewhere), on values only known at run time.
   The counts are only taken of nonzero values, where they are defined. */

typedef long long i64;
typedef unsigned long long u64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

long entry(void *io)
{
  volatile unsigned v32[4] = { 0x12345678u, 0xdeadbeefu, 0u, 0xffu };
  volatile unsigned short v16[3] = { 0x1234, 0xbeef, 0x00ff };
  volatile u64 v64[3] = { 0x0123456789abcdefULL, 0xff00000000000001ULL, 42 };
  u64 h = 7;
  int i;
  for (i = 0; i < 4; i++) h = h * 31 + __builtin_bswap32(v32[i]);
  for (i = 0; i < 3; i++) h = h * 37 + __builtin_bswap16(v16[i]);
  for (i = 0; i < 3; i++) h = h * 41 + __builtin_bswap64(v64[i]);
  for (i = 0; i < 4; i++)
    if (v32[i] != 0) h = h * 43 + __builtin_clz(v32[i]) * 64 + __builtin_ctz(v32[i]);
  for (i = 0; i < 3; i++)
    h = h * 47 + __builtin_clzll(v64[i]) * 64 + __builtin_ctzll(v64[i]);
  return fold((i64)h);
}
