/*
 * dtoa wrapper — implementation. See dtoa_wrapper.h.
 */
#include <inttypes.h>
#include "dtoa_wrapper.h"
#include "dtoa.h"

double duktape_js_atod(const char *str, const char **pnext, int radix, int flags,
                       void *tmp)
{
    return js_atod(str, pnext, radix, flags, (JSATODTempMem *)tmp);
}

int duktape_js_dtoa(char *buf, double d, int radix, int n_digits, int flags,
                    void *tmp)
{
    return js_dtoa(buf, d, radix, n_digits, flags, (JSDTOATempMem *)tmp);
}