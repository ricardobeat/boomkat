// MOVE_GG fusion: GETGLOBAL_PRIM rX, S + PUTGLOBAL_PRIM rX, D -> MOVE_GG for a
// plain `a = b` assignment between two proven primitive-only globals. Both
// globals only ever hold primitives (numbers), and there is no
// eval/globalThis/Function/with, so the prim-slot proof classifies them as
// primitive-only and the fused two-word MOVE_GG replaces the scratch round-trip.
var a = 1, b = 2, c = 3;
for (var i = 0; i < 3; i++) { a = b; b = c; c = i; }
print(a + b + c);
