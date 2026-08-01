#include "jse_util.h"

#include <stdlib.h>
#include <string.h>

int jseu_eval_cstr(jse_runtime rt, const char *src, jse_value *out_val)
{
    if (src == NULL) {
        return JSE_ERR_INVALID;
    }
    return jse_eval(rt, src, strlen(src), out_val);
}

char *jseu_string_dup(jse_runtime rt, jse_value v)
{
    size_t len = 0;
    char *buf;

    /* Call 1: measure. buf == NULL asks only for the byte length. */
    if (jse_get_string(rt, v, NULL, 0, &len) != JSE_OK) {
        return NULL;
    }

    buf = malloc(len + 1); /* +1 for the NUL the ABI writes */
    if (buf == NULL) {
        return NULL;
    }

    /* Call 2: fill. */
    if (jse_get_string(rt, v, buf, len + 1, &len) != JSE_OK) {
        free(buf);
        return NULL;
    }
    return buf;
}

char *jseu_eval_to_string(jse_runtime rt, const char *src)
{
    /*
     * jse_get_string is strict and will not coerce, so stringification is done
     * on the JS side. The source is wrapped in String(...) rather than being
     * converted in C, which keeps the conversion exactly what JS would do.
     */
    static const char pre[] = "String((";
    static const char post[] = "))";

    char *wrapped;
    char *result;
    jse_value v = JSE_INVALID_VALUE;
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

    if (jse_eval(rt, wrapped, strlen(wrapped), &v) != JSE_OK) {
        free(wrapped);
        return NULL;
    }
    free(wrapped);

    result = jseu_string_dup(rt, v);
    jse_value_free(rt, v);
    return result;
}

const char *jseu_type_name(int type)
{
    switch (type) {
    case JSE_TYPE_UNDEFINED: return "undefined";
    case JSE_TYPE_NULL:      return "null";
    case JSE_TYPE_BOOLEAN:   return "boolean";
    case JSE_TYPE_NUMBER:    return "number";
    case JSE_TYPE_STRING:    return "string";
    case JSE_TYPE_OBJECT:    return "object";
    case JSE_TYPE_FUNCTION:  return "function";
    case JSE_TYPE_OTHER:     return "other";
    default:                 return "?";
    }
}

const char *jseu_status_name(int status)
{
    switch (status) {
    case JSE_OK:           return "OK";
    case JSE_ERR_NOMEM:    return "NOMEM";
    case JSE_ERR_SYNTAX:   return "SYNTAX";
    case JSE_ERR_THROW:    return "THROW";
    case JSE_ERR_INTERNAL: return "INTERNAL";
    case JSE_ERR_INVALID:  return "INVALID";
    case JSE_ERR_TYPE:     return "TYPE";
    case JSE_ERR_FULL:     return "FULL";
    default:               return "?";
    }
}
