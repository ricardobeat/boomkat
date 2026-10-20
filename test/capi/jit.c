#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void check(bk_ctx ctx, const char *source) {
    bk_value value = bk_eval(ctx, source, strlen(source), "jit.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(value)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(value) && bk_to_bool(ctx, value));
    bk_free_value(ctx, value);
}

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    assert(runtime);
    assert(bk_set_jit(NULL, 1) == BK_ERR_INVALID);
    assert(bk_set_jit(runtime, 1) == BK_OK);
    bk_ctx ctx = bk_new_context(runtime);
    assert(ctx);
    check(ctx, "function render(items){let out='';for(let i=0;i<items.length;i++){const item=items[i];out+=`<li>${item.id}:${item.name}</li>`;}return out;}"
               "var rows=[{id:1,name:'one'},{id:2,name:'two'}];"
               "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw 'bad render';}true");
    assert(bk_set_jit(runtime, 0) == BK_OK);
    check(ctx, "rows[0].id=3;render(rows)==='<li>3:one</li><li>2:two</li>'");
    assert(bk_set_jit(runtime, 1) == BK_OK);
    check(ctx, "render(rows)==='<li>3:one</li><li>2:two</li>'");
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    puts("C API JIT: PASS");
}
