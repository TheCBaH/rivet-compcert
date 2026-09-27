/* expect: 32640 */
/* Loops over the io buffer: fills it, transforms it in place, and returns
   a checksum. The host reads the buffer back after the call. */

long entry(void *io)
{
  unsigned char *p = io;
  long *words = io;
  int i;
  long sum = 0;
  for (i = 0; i < 256; i++) p[i] = (unsigned char)i;
  for (i = 0; i < 256; i++) sum += p[i];
  for (i = 0; i < 256; i++) p[i] = (unsigned char)(255 - p[i]);
  words[64] = sum;                        /* bytes 512..519 */
  return sum;
}
