0fb4: mov      x2, #0xa820
0fb8: movk     x2, #0xf284, lsl #16
0fbc: movk     x2, #0x78, lsl #32
0fc0: ldr      x3, [x20, #0x8]
0fc4: ldr      w3, [x3, #0x1680]
0fc8: ldr      w1, [x2, #0x14]
0fcc: cmp      x3, x1
0fd0: b.ne     0x100375990
0fd4: ldrb     w3, [x2, #0x1c]
0fd8: and      x3, x3, #0x8
0fdc: cbnz     x3, 0x100375990
0fe0: ldr      x1, [x2, #0x8]
0fe4: cbz      x1, 0x100375990
0fe8: ldr      w3, [x1, #0x10]
0fec: ldr      w1, [x2, #0x10]
0ff0: cmp      x3, x1
0ff4: b.ne     0x100375990
0ff8: ldr      x2, [x2, #0x30]
0ffc: cbz      x2, 0x100375990
1000: ldr      x0, [x2]
1004: lsr      x3, x0, #48
1008: mov      x10, #0xfff9
100c: cmp      x3, x10
1010: b.ne     0x100375990
1014: and      x0, x0, #0xffffffffffff
1018: cbz      x0, 0x100375990
101c: ldr      w1, [x0]
1020: mov      x10, #0x8600
1024: movk     x10, #0x3f, lsl #16
1028: and      x1, x1, x10
102c: mov      x10, #0x200
1030: movk     x10, #0x3, lsl #16
1034: cmp      x1, x10
1038: b.ne     0x100375990
103c: ldr      x1, [x0, #0x38]
1040: mov      x10, #0xc400
1044: movk     x10, #0xf29a, lsl #16
1048: movk     x10, #0x78, lsl #32
104c: cmp      x1, x10
1050: b.ne     0x100375990
1054: ldr      x1, [x0, #0x88]
1058: cbnz     x1, 0x100375990
105c: ldr      x0, [x19, #0x48]
1060: lsr      x3, x0, #48
1064: mov      x10, #0xfff1
1068: cmp      x3, x10
106c: b.eq     0x10037330c
1070: mov      x10, #0xfff1
1074: cmp      x3, x10
1078: b.hi     0x100373450
107c: fmov     d0, x0
1080: fcmp     d0, d0
1084: b.vs     0x100373450
1088: mov      x1, #-0x3e20000000000000
108c: fmov     d1, x1
1090: fcmp     d0, d1
1094: b.mi     0x100373450
1098: mov      x1, #0x41e0000000000000
109c: fmov     d1, x1
10a0: fcmp     d0, d1
10a4: b.ge     0x100373450
10a8: lsl      x3, x0, #1
10ac: cbnz     x3, 0x1003732f0
10b0: cmp      x0, #0x0
10b4: b.lt     0x100373450
10b8: fcvtzs   x0, d0
10bc: scvtf    d1, x0
10c0: fcmp     d0, d1
10c4: cset     x9, ne
10c8: ccmp     x9, #0x0, #0x4, vc
10cc: b.ne     0x100373450
10d0: b        0x100373324
10d4: sxtw     x3, w0
10d8: lsl      x1, x0, #16
10dc: asr      x1, x1, #16
10e0: cmp      x1, x3
10e4: b.ne     0x100373450
10e8: mov      x0, x1
10ec: mov      x4, x0
10f0: mov      x5, #0x1
10f4: lsr      w6, w4, #16
10f8: mov      w6, w6
10fc: mov      w10, #0x7fffffff
1100: cmp      x6, x10
1104: b.hi     0x100373450
1108: sxtw     x6, w6
110c: mov      x7, #0x0
1110: cmp      x6, x7
1114: b.eq     0x100373354
1118: b        0x10037335c
111c: mov      x6, x4
1120: b        0x100373370
1124: mov      x4, #0x10
1128: adds     w11, w5, w4
112c: b.vs     0x100373450
1130: sxtw     x11, w11
1134: mov      x5, x11
1138: asr      w4, w6, #8
113c: sxtw     x4, w4
1140: cmp      x4, x7
1144: b.eq     0x100373384
1148: b        0x10037338c
114c: mov      x4, x6
1150: b        0x1003733a0
1154: mov      x6, #0x8
1158: adds     w11, w5, w6
115c: b.vs     0x100373450
1160: sxtw     x11, w11
1164: mov      x5, x11
1168: asr      w6, w4, #4
116c: sxtw     x6, w6
1170: cmp      x6, x7
1174: b.eq     0x1003733b4
1178: b        0x1003733bc
117c: mov      x6, x4
1180: b        0x1003733d0
1184: mov      x4, #0x4
1188: adds     w11, w5, w4
118c: b.vs     0x100373450
1190: sxtw     x11, w11
1194: mov      x5, x11
1198: asr      w4, w6, #2
119c: sxtw     x4, w4
11a0: cmp      x4, x7
11a4: b.eq     0x1003733e4
11a8: b        0x1003733ec
11ac: mov      x4, x6
11b0: b        0x100373400
11b4: mov      x6, #0x2
11b8: adds     w11, w5, w6
11bc: b.vs     0x100373450
11c0: sxtw     x11, w11
11c4: mov      x5, x11
11c8: asr      w6, w4, #1
11cc: sxtw     x6, w6
11d0: cmp      x6, x7
11d4: b.eq     0x100373414
11d8: b        0x10037341c
11dc: mov      x6, x4
11e0: b        0x10037342c
11e4: adds     w4, w5, #0x1
11e8: b.vs     0x100373450
11ec: sxtw     x4, w4
11f0: mov      x5, x4
11f4: mov      x0, x5
11f8: and      x0, x0, #0xffffffffffff
11fc: mov      x10, #-0xf000000000000
1200: orr      x0, x0, x10
1204: lsr      x1, x0, #48
1208: mov      x10, #0xfff8
120c: cmp      x1, x10
1210: b.eq     0x100373450
1214: b        0x100373458
1218: mov      x0, #-0x3000000000000
121c: b        0x100373458
1220: mov      x1, #0x7648
1224: movk     x1, #0xf2ac, lsl #16
1228: movk     x1, #0x78, lsl #32
122c: ldr      x2, [x1]
1230: add      x2, x2, #0x1
1234: str      x2, [x1]
1238: mov      x10, #-0x3000000000000
123c: cmp      x0, x10
1240: b.eq     0x100375990
1244: mov      x1, #0x6b00
1248: movk     x1, #0xf2ac, lsl #16
124c: movk     x1, #0x78, lsl #32
1250: ldr      x2, [x1]
1254: add      x2, x2, #0x1
1258: str      x2, [x1]
125c: ldr      x1, [x19, #0x38]
1260: lsr      x3, x1, #48
1264: mov      x10, #0xfff8
1268: cmp      x3, x10
126c: b.eq     0x1003734b0
1270: str      x0, [x19, #0x38]
1274: b        0x100373510
1278: lsr      x3, x1, #48
127c: mov      x10, #0xfff8
1280: cmp      x3, x10
1284: b.ne     0x1003734dc
1288: and      x2, x1, #0xffffffffffff
128c: cbz      x2, 0x1003734dc
1290: cmp      x0, x1
1294: b.eq     0x1003734dc
1298: ldr      w3, [x2, #0x4]
129c: cmp      x3, #0x1
12a0: b.ls     0x100375990
12a4: lsr      x3, x1, #48
12a8: mov      x10, #0xfff8
12ac: cmp      x3, x10
12b0: b.ne     0x10037350c
12b4: and      x2, x1, #0xffffffffffff
12b8: cbz      x2, 0x10037350c
12bc: ldr      w3, [x2, #0x4]
12c0: mov      w10, #0x7fffffff
12c4: cmp      x3, x10
12c8: b.eq     0x10037350c
12cc: sub      x3, x3, #0x1
12d0: str      w3, [x2, #0x4]
12d4: str      x0, [x19, #0x38]
