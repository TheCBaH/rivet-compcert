/* expect: 129728 */
/* Recursion, mutual recursion, and a large stack frame (128 KB on every
   target: the buffer is long long). */

typedef long long i64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

static i64 fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int is_odd(int n);
static int is_even(int n) { return n == 0 ? 1 : is_odd(n - 1); }
static int is_odd(int n) { return n == 0 ? 0 : is_even(n - 1); }

static i64 big_frame(int k)
{
  i64 buf[16384];                         /* 128 KB */
  int i;
  for (i = 0; i < 16384; i++) buf[i] = i ^ k;
  i64 s = 0;
  for (i = 0; i < 16384; i += 1024) s += buf[i];
  return s;
}

long entry(void *io)
{
  return fold(fib(20) + is_even(100) + is_odd(7) * 2 + big_frame(5));
}
