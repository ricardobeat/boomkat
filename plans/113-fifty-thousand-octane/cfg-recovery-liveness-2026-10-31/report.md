# CFG-based loop continuation liveness, 2026-10-31

Rat `9da6427e`, control `5aae48bc`. This slice reuses the compiler's canonical
operand roles and backwards liveness for SSA-loop fallthrough. It does not
implement cyclic function SSA or meet the 50K target.

The old scan treated every A/B/C byte after the loop as a register, including
literal values and property-name indices, yet missed implicit argument windows.
For unaliased functions with at most 512 bytecodes and modeled opcodes, the
candidate computes the CFG live-in set at the loop's fallthrough. It also keeps
the latch comparison operands live because budget/guard exits replay that
branch. Unsupported opcodes, WIDE, aliased windows, large functions, direct eval,
mapped arguments, generators and allocation failures use a conservative scan;
alias slots are mapped back to original VM registers. A function containing
TRY preserves every written loop slot for exception recovery.

The temporary CFG data is bounded by 512 instructions and 1023 VM registers:
up to 16 KiB of RegSet descriptors plus 128.125 KiB of words on this 64-bit
build, freed after each analysis. The fallback is required for correctness,
not permission to treat unsupported control flow as modeled.

## Bytecode and generated ARM64 code

Captures use matching SLJIT_STATS builds plus diagnostic-only source probes;
they are not timing runs. Hex was read from the generated executable range,
emitted as assembler bytes, then decoded by `clang -arch arm64` and
`otool -tvV`. Instrumentation patches, bytecode and complete disassemblies
are included. Counts cover all instructions in each native range, including
cold guard exits; they are static, not executed-instruction measurements.

The isolated `phiProbe` bytecode has a loop writing r4 at pc 4–5 and a later
`LDINT r3,+4` at pc 8. The old scanner treated that immediate 4 as a use of r4,
creating a recovery phi. The new graph marks it dead: 852→796 bytes,
213→199 ARM64 instructions and 59→55 static load/store instructions. The
control has an entry `ldr x0,[x19,#0x20]` and move for that value which the
candidate removes. The traced source and disassemblies are in `dead-*`.

The real Navier–Stokes `lin_solve` pc 47–65 SSA loop goes from 5828 to 5736
bytes, 1457→1434 instructions, 348→329 static loads/stores and 142→141
conditional branches. Slot 19 loses an unnecessary recovery phi. A first
conservative whole-function scan instead introduced seven extra phis and
increased that loop to 6592 bytes; it was rejected. `navier-loop-bytecode.txt`,
`navier-*-phis.txt` and `navier-*.asm` preserve the evidence.

For the high-register recovery fixture, control and the earlier conservative
candidate produced identical 1288-byte native loops; the fixture is evidence
of recovery, not a claimed code-size win. Final statistics show the loop uses
SSA with 47 hits and 1169 iterations. The nested-loop fixture has 11 SSA hits
and 43 iterations. Its exception-handler loop has 201 hits/1598 iterations and
records a fallback at ADD_FUSED after four iterations; the handler observes the
right local and the throwing coercion executes once.

A first precise-CFG experiment lost the latch operand when fallthrough
immediately overwrote it, and the native-call embedding test produced 82608
instead of 82600. That result was rejected. Preserving operands required to
replay the latch fixes that concrete failure; ARM64 and x64 embedding tests
pass with the fix, including jitNativeStep's SSA loop and budget exits.

## Performance and cost

Five alternating mini pairs (control→candidate ms): Navier–Stokes 191→190,
Mandreel 558→554, Gameboy 276→277, PdfJS 359→360, Crypto 164→165,
TypeScript 1234→1232. A separate five-pair 100-iteration Navier–Stokes run
is 2035→2033 ms median. These are flat/noisy and not a throughput claim.

A compilation-heavy probe creates 250 functions and, under stress diagnostics,
installs 249 functions and 75 loops in both binaries (945180 native bytes).
Seven alternating non-instrumented runs have 8→8 ms median; five `wait4` peak
RSS samples have medians 8077312→8110080 bytes. The probe is too short to
resolve small CPU or RSS changes and is not an Octane score. Raw pairs,
resource samples and exact probe source are included. No full Octane run was
performed for this slice.

## Validation and remaining work

53 focused jit*/sljit* fixtures agree in interpreter, JIT and stress modes.
ARM64/x64 embedding checks, ASan fixture and local/Rosetta/modules differential
checks pass. The local suite returns status 1 in both modes due to the existing
feature-limited baseline; Rosetta and modules return 0. The exact fixture,
control/candidate binary hashes and raw results accompany this report.

This computes recovery-aware continuation liveness for existing loop SSA. It
is not a general cyclic function graph, does not handle exact CFG recovery for
aliased or WIDE regions, and does not eliminate effects, calls or GC boundaries.
Further work must build cyclic CFG/phis with exact recovery and optimize hot
property/element accesses across those boundaries. The 50K score remains open.
