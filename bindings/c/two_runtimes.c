#include <boomkat.h>
#include <assert.h>
#include <stdio.h>

int main(void) {
    bk_runtime a = bk_new_runtime(), b = bk_new_runtime();
    bk_ctx first = bk_new_context(a), sibling = bk_new_context(a), isolated = bk_new_context(b);
    assert(first && sibling && isolated);
    bk_value object = bk_new_object(first), answer = bk_new_number(first, 42);
    assert(bk_set_property(sibling, object, "answer", 6, answer) == BK_OK);
    bk_value value = bk_get_property(sibling, object, "answer", 6);
    assert(bk_to_number(sibling, value) == 42);
    assert(bk_get_property(isolated, object, "answer", 6) == BK_EXCEPTION);
    bk_free_value(sibling, value);
    bk_free_value(first, answer);
    bk_free_value(first, object);
    bk_free_context(first);
    bk_free_context(sibling);
    bk_free_context(isolated);
    bk_free_runtime(a);
    bk_free_runtime(b);
    puts("Sibling realms share values; independent runtimes reject them.");
    return 0;
}
