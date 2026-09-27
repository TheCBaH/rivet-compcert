/* expect: 3542 */
/* Structs passed and returned by value: a small one (in registers), a
   large one (through memory), and struct assignment (inline memcpy). */

typedef long long i64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

struct small { int a; int b; };
struct large { i64 v[10]; char tag; };

static struct small make_small(int a, int b) { struct small s; s.a = a; s.b = b; return s; }
static int sum_small(struct small s) { return s.a + s.b; }

static struct large make_large(i64 seed)
{
  struct large l;
  int i;
  for (i = 0; i < 10; i++) l.v[i] = seed + i;
  l.tag = 'x';
  return l;
}

static i64 sum_large(struct large l)
{
  i64 s = 0;
  int i;
  for (i = 0; i < 10; i++) s += l.v[i];
  return s + l.tag;
}

long entry(void *io)
{
  struct small s = make_small(300, 12);
  struct large l = make_large(100);
  struct large copy;
  copy = l;
  copy.v[0] = 1000;
  return fold(sum_small(s) + sum_large(l) + sum_large(copy));
}
