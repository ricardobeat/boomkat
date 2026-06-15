module minimal_engine;

import duktape::heap;

/**
 * Minimal entry point — just initialises and tears down the engine
 * so we can measure the true base footprint (no script execution).
 */
fn int main() {
    Heap*? hp = heap::create();
    if (catch h = hp) return 1;
    defer hp.destroy();
    return 0;
}
