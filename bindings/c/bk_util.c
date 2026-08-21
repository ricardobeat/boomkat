#include "bk_util.h"

#include <stdlib.h>
#include <string.h>

int bku_eval_cstr(bk_runtime rt, const char *src, bk_value *out_val)
{
    if (src == NULL) {
        return BK_ERR_INVALID;
    }
    return bk_eval(rt, src, strlen(src), out_val);
}

char *bku_string_dup(bk_runtime rt, bk_value v)
{
    size_t len = 0;
    char *buf;

    /* Call 1: measure. buf == NULL asks only for the byte length. */
    if (bk_get_string(rt, v, NULL, 0, &len) != BK_OK) {
        return NULL;
    }

    buf = malloc(len + 1); /* +1 for the NUL the ABI writes */
    if (buf == NULL) {
        return NULL;
    }

    /* Call 2: fill. */
    if (bk_get_string(rt, v, buf, len + 1, &len) != BK_OK) {
        free(buf);
        return NULL;
    }
    return buf;
}

char *bku_eval_to_string(bk_runtime rt, const char *src)
{
    /*
     * bk_get_string is strict and will not coerce, so stringification is done
     * on the JS side. The source is wrapped in String(...) rather than being
     * converted in C, which keeps the conversion exactly what JS would do.
     */
    static const char pre[] = "String((";
    static const char post[] = "))";

    char *wrapped;
    char *result;
    bk_value v = BK_INVALID_VALUE;
    size_t n;

    if (src == NULL) {
        return NULL;
    }
    n = strlen(src);

    wrapped = malloc(sizeof(pre) - 1 + n + sizeof(post)); /* sizeof(post) covers the NUL */
    if (wrapped == NULL) {
        return NULL;
    }
    memcpy(wrapped, pre, sizeof(pre) - 1);
    memcpy(wrapped + sizeof(pre) - 1, src, n);
    memcpy(wrapped + sizeof(pre) - 1 + n, post, sizeof(post));

    if (bk_eval(rt, wrapped, strlen(wrapped), &v) != BK_OK) {
        free(wrapped);
        return NULL;
    }
    free(wrapped);

    result = bku_string_dup(rt, v);
    bk_value_free(rt, v);
    return result;
}

const char *bku_type_name(int type)
{
    switch (type) {
    case BK_TYPE_UNDEFINED: return "undefined";
    case BK_TYPE_NULL:      return "null";
    case BK_TYPE_BOOLEAN:   return "boolean";
    case BK_TYPE_NUMBER:    return "number";
    case BK_TYPE_STRING:    return "string";
    case BK_TYPE_OBJECT:    return "object";
    case BK_TYPE_FUNCTION:  return "function";
    case BK_TYPE_OTHER:     return "other";
    default:                 return "?";
    }
}

const char *bku_status_name(int status)
{
    switch (status) {
    case BK_OK:           return "OK";
    case BK_ERR_NOMEM:    return "NOMEM";
    case BK_ERR_SYNTAX:   return "SYNTAX";
    case BK_ERR_THROW:    return "THROW";
    case BK_ERR_INTERNAL: return "INTERNAL";
    case BK_ERR_INVALID:  return "INVALID";
    case BK_ERR_TYPE:     return "TYPE";
    case BK_ERR_FULL:     return "FULL";
    default:               return "?";
    }
}
