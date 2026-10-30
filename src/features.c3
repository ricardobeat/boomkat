// Compile-time capabilities shared by the builtin registry and value boundaries.
module boomkat::features;

const bool ITERATOR_HELPERS = !$feat(NO_ITERATOR_HELPERS);
const bool BIGINT = !$feat(NO_BIGINT);
const bool WEAKREF = !$feat(NO_WEAKREF);
const bool SHARED_MEMORY = !$feat(NO_SHARED_MEMORY);
const bool TYPESCRIPT = !$feat(NO_TYPESCRIPT);
const bool JSX = !$feat(NO_JSX);
const bool MODULE_LOADING = !$feat(NO_MODULE_LOADING);
const bool ASYNC_GENERATORS = !$feat(NO_ASYNC_GENERATORS);
const bool SOURCE_COMPILER = !$feat(BYTECODE_ONLY);
// The test262 host globals ($262, __evalScript, __detachArrayBuffer) are a
// runtime opt-in, but only a source-evaluating profile or the harness can turn
// them on. Bytecode-only runners never do, so they leave the host, its agent
// threads and its source-evaluating globals out of the link.
const bool TEST262_HOST = SOURCE_COMPILER || $feat(TEST262_HELPERS);
const bool PORTABLE_BYTECODE = $feat(BYTECODE_GENERATOR);
const bool REGEXP = !$feat(NO_REGEXP);
const bool COLLECTIONS = !$feat(NO_COLLECTIONS);
const bool BUFFERS = !$feat(NO_BUFFERS);
const bool PROXY = !$feat(NO_PROXY);
const bool NORMALIZE = !$feat(NO_NORMALIZE);
const bool STRICT_ONLY = $feat(STRICT_ONLY);
const bool EXTENDED_BUILTINS = !$feat(CORE_BUILTINS_ONLY);
const bool ALL_OPTIONAL = EXTENDED_BUILTINS && ITERATOR_HELPERS && BIGINT && WEAKREF && SHARED_MEMORY && MODULE_LOADING && ASYNC_GENERATORS && REGEXP && COLLECTIONS && BUFFERS && PROXY && NORMALIZE;

macro validate_dependencies() {
    $assert SOURCE_COMPILER || !MODULE_LOADING : "BYTECODE_ONLY requires NO_MODULE_LOADING";
    $assert BIGINT || !$feat(TEMPORAL) : "TEMPORAL requires BigInt";
}
