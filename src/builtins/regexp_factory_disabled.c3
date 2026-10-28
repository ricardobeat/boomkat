module boomkat::builtins @feat(NO_REGEXP);

import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;

fn HObject* create_regexp_from_string(Heap* heap, HString* pattern, int js_flags) {
    return null;
}
