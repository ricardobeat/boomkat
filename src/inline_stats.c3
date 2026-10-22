module boomkat::bytecode;

import std::io;

// The performance gate keeps expansion opt-in; loaded bytecode always executes it.
bool inline_enabled = false;
bool inline_profile;
tlocal ulong inline_attempts, inline_hits, inline_avoided;
tlocal ulong inline_sites, inline_before, inline_after;

fn void inline_dump_stats() {
    if (!inline_profile) return;
    io::eprintfn("INLINE sites=%d attempts=%d guard_hits=%d calls_avoided=%d fallback=%d bytecode_before=%d bytecode_after=%d",
        inline_sites, inline_attempts, inline_hits, inline_avoided,
        inline_attempts - inline_avoided, inline_before * Instruction::size, inline_after * Instruction::size);
}
