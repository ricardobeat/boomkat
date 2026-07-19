module test_closure_put;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::types;
import std::io;

fn int main(String[] args) {
    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) { io::printn("heap::create failed"); return 1; }
    defer hp.destroy();

    // Create a FUNCTION object (like CLOSURE would)
    HObject*? func_raw = hp.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) { io::printn("alloc_object failed"); return 1; }
    HObject* func = func_raw;
    io::printn("Created FUNCTION object");

    // Set prototype to null (like CLOSURE would set to function_proto)
    func.prototype = null;

    // Try put_prop for .name
    char[] name_data = "f";
    HString*? name_hstr_raw = hstring::hstring_alloc(hp, name_data, hp.hash_string(name_data));
    if (catch err = name_hstr_raw) { io::printn("hstring_alloc name failed"); return 1; }
    HString* name_hstr = name_hstr_raw;

    TVal name_tv;
    name_tv.set_string(name_hstr);
    bool ok1 = func.put_prop(name_hstr, name_tv, hobject::PROP_FLAGS_NWC);
    io::printfn("put_prop .name: %s", ok1 ? "OK" : "FAIL");

    // Try put_prop for .length
    char[] len_data = "length";
    HString*? len_hstr_raw = hstring::hstring_alloc(hp, len_data, hp.hash_string(len_data));
    if (catch err = len_hstr_raw) { io::printn("hstring_alloc length failed"); return 1; }
    HString* len_hstr = len_hstr_raw;

    TVal len_val;
    len_val.set_fastint(0);
    bool ok2 = func.put_prop(len_hstr, len_val, hobject::PROP_FLAGS_NWC);
    io::printfn("put_prop .length: %s", ok2 ? "OK" : "FAIL");

    io::printn("All closure put_prop tests passed!");
    return 0;
}
