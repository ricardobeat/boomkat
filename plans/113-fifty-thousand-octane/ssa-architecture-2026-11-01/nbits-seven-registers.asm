0f9c: mov      x2, #0xe820
0fa0: movk     x2, #0xa2c2, lsl #16
0fa4: movk     x2, #0x74, lsl #32
0fa8: ldr      x3, [x20, #0x8]
0fac: ldr      w3, [x3, #0x1680]
0fb0: ldr      w1, [x2, #0x14]
0fb4: cmp      x3, x1
0fb8: b.ne     0x100375b80
0fbc: ldrb     w3, [x2, #0x1c]
0fc0: and      x3, x3, #0x8
0fc4: cbnz     x3, 0x100375b80
0fc8: ldr      x1, [x2, #0x8]
0fcc: cbz      x1, 0x100375b80
0fd0: ldr      w3, [x1, #0x10]
0fd4: ldr      w1, [x2, #0x10]
0fd8: cmp      x3, x1
0fdc: b.ne     0x100375b80
0fe0: ldr      x2, [x2, #0x30]
0fe4: cbz      x2, 0x100375b80
0fe8: ldr      x0, [x2]
0fec: lsr      x3, x0, #48
0ff0: mov      x10, #0xfff9
0ff4: cmp      x3, x10
0ff8: b.ne     0x100375b80
0ffc: and      x0, x0, #0xffffffffffff
1000: cbz      x0, 0x100375b80
1004: ldr      w1, [x0]
1008: mov      x10, #0x8600
100c: movk     x10, #0x3f, lsl #16
1010: and      x1, x1, x10
1014: mov      x10, #0x200
1018: movk     x10, #0x3, lsl #16
101c: cmp      x1, x10
1020: b.ne     0x100375b80
1024: ldr      x1, [x0, #0x38]
1028: mov      x10, #0xc600
102c: movk     x10, #0xa2d1, lsl #16
1030: movk     x10, #0x74, lsl #32
1034: cmp      x1, x10
1038: b.ne     0x100375b80
103c: ldr      x1, [x0, #0x88]
1040: cbnz     x1, 0x100375b80
1044: ldr      x0, [x19, #0x48]
1048: lsr      x3, x0, #48
104c: mov      x10, #0xfff1
1050: cmp      x3, x10
1054: b.eq     0x100373594
1058: mov      x10, #0xfff1
105c: cmp      x3, x10
1060: b.hi     0x100373710
1064: fmov     d0, x0
1068: fcmp     d0, d0
106c: b.vs     0x100373710
1070: mov      x1, #-0x3e20000000000000
1074: fmov     d1, x1
1078: fcmp     d0, d1
107c: b.mi     0x100373710
1080: mov      x1, #0x41e0000000000000
1084: fmov     d1, x1
1088: fcmp     d0, d1
108c: b.ge     0x100373710
1090: lsl      x3, x0, #1
1094: cbnz     x3, 0x100373578
1098: cmp      x0, #0x0
109c: b.lt     0x100373710
10a0: fcvtzs   x0, d0
10a4: scvtf    d1, x0
10a8: fcmp     d0, d1
10ac: cset     x9, ne
10b0: ccmp     x9, #0x0, #0x4, vc
10b4: b.ne     0x100373710
10b8: b        0x1003735ac
10bc: sxtw     x3, w0
10c0: lsl      x1, x0, #16
10c4: asr      x1, x1, #16
10c8: cmp      x1, x3
10cc: b.ne     0x100373710
10d0: mov      x0, x1
10d4: mov      x4, x0
10d8: mov      x5, #0x1
10dc: lsr      w6, w4, #16
10e0: mov      w6, w6
10e4: mov      w10, #0x7fffffff
10e8: cmp      x6, x10
10ec: b.hi     0x100373710
10f0: sxtw     x6, w6
10f4: mov      x0, #0x0
10f8: str      x0, [x21, #0x80]
10fc: ldr      x1, [x21, #0x80]
1100: cmp      x6, x1
1104: b.eq     0x1003735e4
1108: b        0x1003735ec
110c: mov      x6, x4
1110: b        0x100373608
1114: mov      x4, #0x10
1118: adds     w0, w5, w4
111c: b.vs     0x100373710
1120: sxtw     x0, w0
1124: str      x0, [x21, #0x88]
1128: ldr      x0, [x21, #0x88]
112c: mov      x5, x0
1130: asr      w4, w6, #8
1134: sxtw     x4, w4
1138: ldr      x1, [x21, #0x80]
113c: cmp      x4, x1
1140: b.eq     0x100373620
1144: b        0x100373628
1148: mov      x4, x6
114c: b        0x100373644
1150: mov      x6, #0x8
1154: adds     w0, w5, w6
1158: b.vs     0x100373710
115c: sxtw     x0, w0
1160: str      x0, [x21, #0x90]
1164: ldr      x0, [x21, #0x90]
1168: mov      x5, x0
116c: asr      w6, w4, #4
1170: sxtw     x6, w6
1174: ldr      x1, [x21, #0x80]
1178: cmp      x6, x1
117c: b.eq     0x10037365c
1180: b        0x100373664
1184: mov      x6, x4
1188: b        0x100373680
118c: mov      x4, #0x4
1190: adds     w0, w5, w4
1194: b.vs     0x100373710
1198: sxtw     x0, w0
119c: str      x0, [x21, #0x98]
11a0: ldr      x0, [x21, #0x98]
11a4: mov      x5, x0
11a8: asr      w4, w6, #2
11ac: sxtw     x4, w4
11b0: ldr      x1, [x21, #0x80]
11b4: cmp      x4, x1
11b8: b.eq     0x100373698
11bc: b        0x1003736a0
11c0: mov      x4, x6
11c4: b        0x1003736bc
11c8: mov      x6, #0x2
11cc: adds     w0, w5, w6
11d0: b.vs     0x100373710
11d4: sxtw     x0, w0
11d8: str      x0, [x21, #0xa0]
11dc: ldr      x0, [x21, #0xa0]
11e0: mov      x5, x0
11e4: asr      w6, w4, #1
11e8: sxtw     x6, w6
11ec: ldr      x1, [x21, #0x80]
11f0: cmp      x6, x1
11f4: b.eq     0x1003736d4
11f8: b        0x1003736dc
11fc: mov      x6, x4
1200: b        0x1003736ec
1204: adds     w4, w5, #0x1
1208: b.vs     0x100373710
120c: sxtw     x4, w4
1210: mov      x5, x4
1214: mov      x0, x5
1218: and      x0, x0, #0xffffffffffff
121c: mov      x10, #-0xf000000000000
1220: orr      x0, x0, x10
1224: lsr      x1, x0, #48
1228: mov      x10, #0xfff8
122c: cmp      x1, x10
1230: b.eq     0x100373710
1234: b        0x100373718
1238: mov      x0, #-0x3000000000000
123c: b        0x100373718
1240: mov      x1, #0x7648
1244: movk     x1, #0xa2dc, lsl #16
1248: movk     x1, #0x74, lsl #32
124c: ldr      x2, [x1]
1250: add      x2, x2, #0x1
1254: str      x2, [x1]
1258: mov      x10, #-0x3000000000000
125c: cmp      x0, x10
1260: b.eq     0x100375b80
1264: mov      x1, #0x6b00
1268: movk     x1, #0xa2dc, lsl #16
126c: movk     x1, #0x74, lsl #32
1270: ldr      x2, [x1]
1274: add      x2, x2, #0x1
1278: str      x2, [x1]
127c: ldr      x1, [x19, #0x38]
1280: lsr      x3, x1, #48
1284: mov      x10, #0xfff8
1288: cmp      x3, x10
128c: b.eq     0x100373770
1290: str      x0, [x19, #0x38]
1294: b        0x1003737d0
1298: lsr      x3, x1, #48
129c: mov      x10, #0xfff8
12a0: cmp      x3, x10
12a4: b.ne     0x10037379c
12a8: and      x2, x1, #0xffffffffffff
12ac: cbz      x2, 0x10037379c
12b0: cmp      x0, x1
12b4: b.eq     0x10037379c
12b8: ldr      w3, [x2, #0x4]
12bc: cmp      x3, #0x1
12c0: b.ls     0x100375b80
12c4: lsr      x3, x1, #48
12c8: mov      x10, #0xfff8
12cc: cmp      x3, x10
12d0: b.ne     0x1003737cc
12d4: and      x2, x1, #0xffffffffffff
12d8: cbz      x2, 0x1003737cc
12dc: ldr      w3, [x2, #0x4]
12e0: mov      w10, #0x7fffffff
12e4: cmp      x3, x10
12e8: b.eq     0x1003737cc
12ec: sub      x3, x3, #0x1
12f0: str      w3, [x2, #0x4]
12f4: str      x0, [x19, #0x38]
