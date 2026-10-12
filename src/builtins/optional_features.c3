// Registration consults dispatch slots selected by the compile-time providers.
module boomkat::builtins;

import boomkat::features;

// Registration follows the selected dispatch handler. Full builds fold this
// predicate away; reduced builds reuse the table populated at engine startup.
macro bool optional_builtin_enabled(uint index) {
    $if features::ALL_OPTIONAL:
        return true;
    $else
        return index >= Builtin::values.len || builtin_dispatch_table[index] != null;
    $endif
}

macro bool @optional_registration($enabled, #registration) {
    $if $enabled:
        return #registration;
    $else
        return true;
    $endif
}
