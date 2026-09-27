/* expect: 133726 */
/* Globals in .data, .rodata and BSS: initialized arrays, a const table,
   zero-initialized storage written at run time, and a pointer initialized
   with the address of another global (an absolute data relocation). */

typedef long long i64;
static long fold(i64 x) { return (int)(x ^ (x >> 32)); }

int table[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
const int weights[8] = { 10, 20, 30, 40, 50, 60, 70, 80 };
static i64 scratch[512];
int counter;
int *table_ptr = &table[3];
const char message[] = "compcert";

long entry(void *io)
{
  i64 sum = 0;
  int i;
  for (i = 0; i < 8; i++) sum += (i64)table[i] * weights[i];       /* 2040 */
  for (i = 0; i < 512; i++) scratch[i] = i;
  for (i = 0; i < 512; i++) sum += scratch[i];                      /* +130816 */
  counter += 5;
  sum += counter;                                                   /* +5 */
  sum += *table_ptr;                                                /* +4 */
  for (i = 0; message[i] != 0; i++) sum += message[i];              /* +846 */
  return fold(sum);
}
