#include "boomkat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    char input[1024];
    size_t length = fread(input, 1, sizeof(input), file);
    fclose(file);
    if (length == 0) return 2;
    bk_ctx context = bk_create();
    if (!context) return 2;
    bk_value value = bk_new_string(context, input, length);
    if (!value) return 2;
    char output[1025];
    for (size_t cap = 0; cap <= length + 1; cap++) {
        memset(output, 0x5a, sizeof(output));
        size_t required = 0;
        bk_status status = bk_read_string(context, value, output, cap, &required);
        size_t copied = cap == 0 ? 0 : cap - 1;
        if (copied > length) copied = length;
        if (required != length || memcmp(output, input, copied)
            || (cap > length && output[copied] != 0)
            || output[cap] != 0x5a
            || status != (cap > length ? BK_OK : BK_ERR_FULL)) return 1;
    }
    unsigned long checksum = 0;
    for (unsigned i = 0; i < 2000000; i++) {
        size_t required;
        if (bk_read_string(context, value, output, sizeof(output), &required) != BK_OK)
            return 1;
        checksum += (unsigned char)output[i % length] + required;
    }
    printf("PASS %lu\n", checksum);
    bk_free_value(context, value);
    bk_destroy(context);
    return 0;
}
