#include <gpac/mpegts.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

/*
** Reproducer command-line:
** gpac -p=0 -i <poc> inspect:interleave=false:deep:pcr
*/


int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  char filename[256];
  /* /tmp is read-only in Mayhem's coverage env; /dev/shm is the only
   * writable tmpfs.  Use /dev/shm so the fopen() succeeds under
   * docker run --read-only (the coverage-collection mount).  */
  sprintf(filename, "/dev/shm/libfuzzer.%d", getpid());

  FILE *fp = fopen(filename, "wb");
  if (!fp)
    return 0;
  fwrite(data, size, 1, fp);
  fclose(fp);

  gf_m2ts_probe_file(filename);

  unlink(filename);
  return 0;
}
