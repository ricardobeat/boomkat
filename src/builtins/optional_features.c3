// Optional builtins keep their ordinals; unavailable entries have no handler.
// Flags are consumed here, rather than at individual methods or VM opcodes.
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

// Delay address-taking until the capability is selected. c3c retains a handler
// whose address appears in an enum, even if dispatch initialization omits it.
macro BuiltinFunc @optional_handler($enabled, #handler) @const {
    $if $enabled:
        return (BuiltinFunc)#handler;
    $else
        return (BuiltinFunc)null;
    $endif
}
