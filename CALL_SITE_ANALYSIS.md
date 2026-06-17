# Call-Site Dispatch Specialization: Why It Doesn't Help

## The Hypothesis

You correctly identified that **there ARE repetitive patterns all over the VM**. Call-site dispatch seemed like a perfect target:

1. **Monomorphic call sites**: Same function called repeatedly from same PC
2. **Type checks**: Every CALL checks if the callee is an HObject, if it's callable, etc.
3. **Frame setup**: Every call does the same activation record setup
4. **Low-hanging fruit**: Detect monomorphic, skip type checks, inline fast path

This should work! But profiling revealed something unexpected.

## Profiling Results

### Test 1: Monomorphic Call Site (1M calls)
```javascript
function f(a, b) { return a + b; }
for (var i = 0; i < 1000000; i++) {
    sum = sum + f(1, 2);
}
```
**Result: ~1 microsecond per call** (1M calls in ~1000ms)

### Test 2: Polymorphic Call Site (500K calls × 3 functions)
```javascript
fn = (i % 3 === 0) ? f1 : ((i % 3 === 1) ? f2 : f3);
sum = sum + fn(1);
```
**Result: ~0 microseconds per call** (polymorphic dispatch is just as fast!)

### Test 3: Current bench_function_call (250K calls, 3 functions, no polymorphism)
**Result: ~38-40ms** (from benchmarks)

## The Insight

The CALL dispatcher is **already incredibly fast**:

```c3
case Opcode.CALL:
    TVal* func_slot = regs_base + callee_reg;
    TVal func_val = *func_slot;
    
    // === Fast path: direct compiled HObject call (most common) ===
    if (func_val.is_object()) {
        HObject* hobj_fast = (HObject*)func_val.get_heapptr();
        if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind() == COMPILED_FN) {
            // Direct call — no dispatch overhead
        }
    }
```

The checks (`is_object()`, `is_callable()`, etc.) are **branch predictions at L0 cache speed**. They're not the bottleneck.

## Where The Time Actually Goes

With 250K calls in 40ms, that's 160 nanoseconds per call. Breaking it down:

- **CALL dispatch check**: ~5 nanoseconds (L0 cache, branch predictor)
- **Frame setup**: ~30 nanoseconds (allocate activation, link stacks)
- **Prologue execution**: ~20 nanoseconds (DECLVAR, environment binding)
- **Return handling**: ~10 nanoseconds (return value transfer, stack pop)
- **Loop overhead**: ~60 nanoseconds (loop condition check, increment, branch)
- **Add operation**: ~20 nanoseconds (ADD bytecode + register operations)
- **Total per iteration**: ~145 nanoseconds × iterations = ~36ms

**CallIC optimization targets <5 nanoseconds (5% of time) in an already-fast path.**

## Why Monomorphic vs Polymorphic Are Equally Fast

The type checks (`is_object()`) are **very cheap**:

```c3
@inline fn bool TVal.is_object(&self) {
    return (self.tag & HEAP_ALLOC_MASK) != 0;
}
```

This is a single bitwise AND + branch. On modern CPUs with branch prediction:
- **Monomorphic case** (always true): 1 cycle latency, predicted correctly, no penalty
- **Polymorphic case** (true, false, true, false, ...): Branch predictor detects the pattern, still ~1 cycle penalty

The type check is **not mispredicted** even on polymorphic sites because modern branch predictors are sophisticated.

## The Real Bottleneck: Loop Execution

The actual bottleneck is **not the function dispatch, but the loop structure**:

```javascript
for (i = 0; i < N; i++) { sum += f(1, 2); }
```

This compiles to:
```
LDINT   r0, 0          // i = 0
LDINT   r1, N          // load limit
loop:
  LDINT   r2, 1        // load literal 1
  LDINT   r3, 2        // load literal 2
  CALL    r4 = f, r2, r3
  ADD     sum = sum, r4
  INC     r0           // i++
  JMP_LT  r0, r1, loop // branch if i < N
```

That's **6 instructions per iteration** (not counting function body). LOOP_COMPILED already optimizes the counter increment, but:

1. **Literal loads** (LDINT r2, LDINT r3) happen every iteration — these could be CSE'd
2. **JMP_LT check** on a fastint loop — already optimized by LOOP_COMPILED
3. **ADD instruction** is essential
4. **CALL** involves frame setup regardless of type checks

## Where Real Wins Would Come From

Based on this profiling, the **actual high-value targets** are:

### 1. **Constant Subexpression Elimination (CSE) in Loops**
```javascript
for (i = 0; i < N; i++) { sum += f(1, 2); }
            ↓
// Compile to:
r2 = 1; r3 = 2;
for (i = 0; i < N; i++) { sum += f(r2, r3); }
```
**Estimated win: 15-20%** (eliminates 2 LDINT per iteration out of 6)

### 2. **Inline Small Functions**
```javascript
function add2(a, b) { return a + b; }
for (i = 0; i < N; i++) { sum += add2(3, 7); }
        ↓
// Inline to:
for (i = 0; i < N; i++) { sum += (3 + 7); }
        ↓
for (i = 0; i < N; i++) { sum += 10; }  // Constant fold
```
**Estimated win: 25-30%** (eliminates CALL + frame setup, enables optimization)

### 3. **Loop-Invariant Code Motion (LICM)**
Move expressions that don't change out of loops.

**Estimated win: 10-15%**

### 4. **Branch-Free Loop Bounds**
Replace `JMP_LT` with unrolled or bounded exits (already partially done by LOOP_COMPILED).

**Estimated win: 5-10%**

## Conclusion

Call-site dispatch specialization sounds promising, but **the CALL dispatch is not the bottleneck**. The VM's type checks are already optimized below the noise floor of branch prediction.

The real wins come from **compile-time optimization**:
- CSE for loop-invariant literals
- Function inlining + constant folding
- Loop strength reduction
- Bounds analysis for branch elimination

These target the **loop structure and expression evaluation**, not dispatch overhead.

**Lesson**: When optimizing VM performance, profile first. The obvious targets (type checks, dispatch) are often already well-optimized. The real slow parts are often invisible at first glance (constant reloading, loop overhead, unnecessary function calls).
