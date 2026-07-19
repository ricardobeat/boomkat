module test_prop;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::types;
import std::io;

fn int main(String[] args) {
    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) {
        io::printn("heap::create failed");
        return 1;
    }
    defer hp.destroy();

    // Test 1: Create an object and add properties
    HObject*? obj_raw = hp.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) {
        io::printn("alloc_object failed");
        return 1;
    }
    HObject* obj = obj_raw;

    io::printn("Test 1: Adding properties to object...");

    // Need strings
    char[] key1 = "hello";
    HString*? hs1_raw = hstring::hstring_alloc(hp, key1, hp.hash_string(key1));
    if (catch err = hs1_raw) { io::printn("hstring_alloc failed"); return 1; }
    HString* hs1 = hs1_raw;

    char[] key2 = "world";
    HString*? hs2_raw = hstring::hstring_alloc(hp, key2, hp.hash_string(key2));
    if (catch err = hs2_raw) { io::printn("hstring_alloc 2 failed"); return 1; }
    HString* hs2 = hs2_raw;

    TVal val1; val1.set_fastint(42);
    TVal val2; val2.set_fastint(99);

    bool ok1 = obj.put_prop(hs1, val1, hobject::PROP_FLAGS_WEC);
    io::printfn("put_prop 1: %s", ok1 ? "OK" : "FAIL");

    bool ok2 = obj.put_prop(hs2, val2, hobject::PROP_FLAGS_WEC);
    io::printfn("put_prop 2: %s", ok2 ? "OK" : "FAIL");

    // Test lookup
    int idx1 = obj.find_prop_idx(hs1);
    io::printfn("find 'hello': idx=%d", idx1);

    if (idx1 >= 0) {
        TVal v = obj.prop_values()[idx1].data.value;
        io::printfn("  value: %d", (int)v.get_fastint());
    }

    int idx2 = obj.find_prop_idx(hs2);
    io::printfn("find 'world': idx=%d", idx2);

    // Test 2: Create second object with same shape
    HObject*? obj2_raw = hp.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj2_raw) { io::printn("alloc_object 2 failed"); return 1; }
    HObject* obj2 = obj2_raw;

    bool ok3 = obj2.put_prop(hs1, val1, hobject::PROP_FLAGS_WEC);
    io::printfn("obj2 put_prop 'hello': %s", ok3 ? "OK" : "FAIL");

    io::printn("All tests passed!");
    return 0;
}
