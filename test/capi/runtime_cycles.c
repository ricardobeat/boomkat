#include <stdio.h>
#include <string.h>
#include "jse.h"
/*
 * Repeated open/eval/close cycles, for the GC_STRESS + AddressSanitizer build.
 *
 * Heap.destroy frees every object directly instead of refcounting it down, and
 * signals that with Heap.tearing_down so object teardown skips its decref pass.
 * Releasing references there would touch the string table the sweep is walking.
 * The JS suites run one destroy per process and so barely cover this; each
 * iteration here is a full heap lifecycle.
 *
 * Every object class the free path special-cases is built first: promise,
 * arraybuffer, generator, bound function, error, getter/setter, plus objects
 * carrying a property hash table and a private shape from a delete.
 *
 * Build the sanitized library with `make jse-stress`, then link this against
 * out/jse_stress.dylib. Mutating tearing_down to stay false makes this abort,
 * which is what makes it worth running.
 */
static const char *SRC =
  "var o={}; for(var i=0;i<80;i++)o['k'+i]=i;"           /* prop hash + shapes */
  "delete o.k40; delete o.k7;"                            /* private shapes */
  "var p=Promise.resolve(1).then(function(v){return v+1;});"
  "var ab=new ArrayBuffer(64); var ta=new Uint8Array(ab);"
  "function*g(){yield 1;yield 2;} var it=g(); it.next();"
  "var bf=function(a,b){return a+b;}.bind(null,1);"
  "var e=new TypeError('x');"
  "var gs={}; Object.defineProperty(gs,'p',{get:function(){return 1;}});"
  "var m=new Map([[1,2]]); var s=new Set([1,2,3]);"
  "1";
int main(void){
    for(int i=0;i<40;i++){
        jse_runtime rt=NULL; jse_value v;
        if(jse_open(&rt)!=JSE_OK){ printf("open failed at %d\n",i); return 1; }
        if(jse_eval(rt,SRC,strlen(SRC),&v)!=JSE_OK){ printf("eval failed at %d: %s\n",i,jse_last_error(rt)); jse_close(rt); return 1; }
        jse_value_free(rt,v);
        jse_drain_microtasks(rt);
        jse_close(rt);                 /* <- Heap.destroy, tearing_down path */
    }
    printf("40 open/eval/close cycles clean\n");
    return 0;
}
