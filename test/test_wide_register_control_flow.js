// Control flow inside a scope whose locals exceed 255 registers: every
// jump target, back-edge, and handler PC must land on a WIDE prefix word
// when the targeted instruction carries widened operands, or the VM
// decodes truncated (low-byte) registers and silently reads the wrong
// slots. Exercises loops, break/continue, try/catch/finally, ternaries,
// multi-arg calls, and closures past the 8-bit boundary.
// See plans/070-real-world-battle-testing.md (B1).
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " - expected " + expected + ", got " + actual);
        failures++;
    }
}

(function () {
    function g0() { return 0; }
    function g1() { return 1; }
    function g2() { return 2; }
    function g3() { return 3; }
    function g4() { return 4; }
    function g5() { return 5; }
    function g6() { return 6; }
    function g7() { return 7; }
    function g8() { return 8; }
    function g9() { return 9; }
    function g10() { return 10; }
    function g11() { return 11; }
    function g12() { return 12; }
    function g13() { return 13; }
    function g14() { return 14; }
    function g15() { return 15; }
    function g16() { return 16; }
    function g17() { return 17; }
    function g18() { return 18; }
    function g19() { return 19; }
    function g20() { return 20; }
    function g21() { return 21; }
    function g22() { return 22; }
    function g23() { return 23; }
    function g24() { return 24; }
    function g25() { return 25; }
    function g26() { return 26; }
    function g27() { return 27; }
    function g28() { return 28; }
    function g29() { return 29; }
    function g30() { return 30; }
    function g31() { return 31; }
    function g32() { return 32; }
    function g33() { return 33; }
    function g34() { return 34; }
    function g35() { return 35; }
    function g36() { return 36; }
    function g37() { return 37; }
    function g38() { return 38; }
    function g39() { return 39; }
    function g40() { return 40; }
    function g41() { return 41; }
    function g42() { return 42; }
    function g43() { return 43; }
    function g44() { return 44; }
    function g45() { return 45; }
    function g46() { return 46; }
    function g47() { return 47; }
    function g48() { return 48; }
    function g49() { return 49; }
    function g50() { return 50; }
    function g51() { return 51; }
    function g52() { return 52; }
    function g53() { return 53; }
    function g54() { return 54; }
    function g55() { return 55; }
    function g56() { return 56; }
    function g57() { return 57; }
    function g58() { return 58; }
    function g59() { return 59; }
    function g60() { return 60; }
    function g61() { return 61; }
    function g62() { return 62; }
    function g63() { return 63; }
    function g64() { return 64; }
    function g65() { return 65; }
    function g66() { return 66; }
    function g67() { return 67; }
    function g68() { return 68; }
    function g69() { return 69; }
    function g70() { return 70; }
    function g71() { return 71; }
    function g72() { return 72; }
    function g73() { return 73; }
    function g74() { return 74; }
    function g75() { return 75; }
    function g76() { return 76; }
    function g77() { return 77; }
    function g78() { return 78; }
    function g79() { return 79; }
    function g80() { return 80; }
    function g81() { return 81; }
    function g82() { return 82; }
    function g83() { return 83; }
    function g84() { return 84; }
    function g85() { return 85; }
    function g86() { return 86; }
    function g87() { return 87; }
    function g88() { return 88; }
    function g89() { return 89; }
    function g90() { return 90; }
    function g91() { return 91; }
    function g92() { return 92; }
    function g93() { return 93; }
    function g94() { return 94; }
    function g95() { return 95; }
    function g96() { return 96; }
    function g97() { return 97; }
    function g98() { return 98; }
    function g99() { return 99; }
    function g100() { return 100; }
    function g101() { return 101; }
    function g102() { return 102; }
    function g103() { return 103; }
    function g104() { return 104; }
    function g105() { return 105; }
    function g106() { return 106; }
    function g107() { return 107; }
    function g108() { return 108; }
    function g109() { return 109; }
    function g110() { return 110; }
    function g111() { return 111; }
    function g112() { return 112; }
    function g113() { return 113; }
    function g114() { return 114; }
    function g115() { return 115; }
    function g116() { return 116; }
    function g117() { return 117; }
    function g118() { return 118; }
    function g119() { return 119; }
    function g120() { return 120; }
    function g121() { return 121; }
    function g122() { return 122; }
    function g123() { return 123; }
    function g124() { return 124; }
    function g125() { return 125; }
    function g126() { return 126; }
    function g127() { return 127; }
    function g128() { return 128; }
    function g129() { return 129; }
    function g130() { return 130; }
    function g131() { return 131; }
    function g132() { return 132; }
    function g133() { return 133; }
    function g134() { return 134; }
    function g135() { return 135; }
    function g136() { return 136; }
    function g137() { return 137; }
    function g138() { return 138; }
    function g139() { return 139; }
    function g140() { return 140; }
    function g141() { return 141; }
    function g142() { return 142; }
    function g143() { return 143; }
    function g144() { return 144; }
    function g145() { return 145; }
    function g146() { return 146; }
    function g147() { return 147; }
    function g148() { return 148; }
    function g149() { return 149; }
    function g150() { return 150; }
    function g151() { return 151; }
    function g152() { return 152; }
    function g153() { return 153; }
    function g154() { return 154; }
    function g155() { return 155; }
    function g156() { return 156; }
    function g157() { return 157; }
    function g158() { return 158; }
    function g159() { return 159; }
    function g160() { return 160; }
    function g161() { return 161; }
    function g162() { return 162; }
    function g163() { return 163; }
    function g164() { return 164; }
    function g165() { return 165; }
    function g166() { return 166; }
    function g167() { return 167; }
    function g168() { return 168; }
    function g169() { return 169; }
    function g170() { return 170; }
    function g171() { return 171; }
    function g172() { return 172; }
    function g173() { return 173; }
    function g174() { return 174; }
    function g175() { return 175; }
    function g176() { return 176; }
    function g177() { return 177; }
    function g178() { return 178; }
    function g179() { return 179; }
    function g180() { return 180; }
    function g181() { return 181; }
    function g182() { return 182; }
    function g183() { return 183; }
    function g184() { return 184; }
    function g185() { return 185; }
    function g186() { return 186; }
    function g187() { return 187; }
    function g188() { return 188; }
    function g189() { return 189; }
    function g190() { return 190; }
    function g191() { return 191; }
    function g192() { return 192; }
    function g193() { return 193; }
    function g194() { return 194; }
    function g195() { return 195; }
    function g196() { return 196; }
    function g197() { return 197; }
    function g198() { return 198; }
    function g199() { return 199; }
    function g200() { return 200; }
    function g201() { return 201; }
    function g202() { return 202; }
    function g203() { return 203; }
    function g204() { return 204; }
    function g205() { return 205; }
    function g206() { return 206; }
    function g207() { return 207; }
    function g208() { return 208; }
    function g209() { return 209; }
    function g210() { return 210; }
    function g211() { return 211; }
    function g212() { return 212; }
    function g213() { return 213; }
    function g214() { return 214; }
    function g215() { return 215; }
    function g216() { return 216; }
    function g217() { return 217; }
    function g218() { return 218; }
    function g219() { return 219; }
    function g220() { return 220; }
    function g221() { return 221; }
    function g222() { return 222; }
    function g223() { return 223; }
    function g224() { return 224; }
    function g225() { return 225; }
    function g226() { return 226; }
    function g227() { return 227; }
    function g228() { return 228; }
    function g229() { return 229; }
    function g230() { return 230; }
    function g231() { return 231; }
    function g232() { return 232; }
    function g233() { return 233; }
    function g234() { return 234; }
    function g235() { return 235; }
    function g236() { return 236; }
    function g237() { return 237; }
    function g238() { return 238; }
    function g239() { return 239; }
    function g240() { return 240; }
    function g241() { return 241; }
    function g242() { return 242; }
    function g243() { return 243; }
    function g244() { return 244; }
    function g245() { return 245; }
    function g246() { return 246; }
    function g247() { return 247; }
    function g248() { return 248; }
    function g249() { return 249; }
    function g250() { return 250; }
    function g251() { return 251; }
    function g252() { return 252; }
    function g253() { return 253; }
    function g254() { return 254; }
    function g255() { return 255; }
    function g256() { return 256; }
    function g257() { return 257; }
    function g258() { return 258; }
    function g259() { return 259; }

    // A loop whose body instructions sit past the 8-bit boundary.
    var total = 0;
    for (var i = 0; i < 10; i++) {
        if (i === 3) { continue; }
        if (i === 8) { break; }
        total += i;
    }
    assertEq(total, 25, "loop with break/continue in a wide scope");

    // try/catch/finally with the throw crossing high registers.
    var seen = "";
    function thrower(n) { throw new Error("e" + n); }
    try {
        thrower(7);
    } catch (e) {
        seen = e.message;
    } finally {
        seen += "!";
    }
    assertEq(seen, "e7!", "try/catch/finally in a wide scope");

    // Ternary join: both arms write past-boundary registers.
    var pick = total > 20 ? g200() : g100();
    assertEq(pick, 200, "ternary reading wide registers");

    // Multi-argument call whose argument window is entirely past 255.
    function sum5(a, b, c, d, e) { return a + b + c + d + e; }
    assertEq(sum5(g1(), g2(), g3(), g4(), g5()), 15, "wide call window");

    // Closure capture from the wide scope.
    var mk = function () { return g259(); };
    assertEq(mk(), 259, "closure over a wide-scope local");

    // While loop with a comparison against a wide-register bound.
    var limit = g5();
    var n = 0;
    while (n < limit) { n++; }
    assertEq(n, 5, "while loop bounded by a wide register");
}());

if (failures === 0) {
    print("PASS: control flow survives a wide-register scope");
} else {
    print("FAILURES: " + failures);
}
