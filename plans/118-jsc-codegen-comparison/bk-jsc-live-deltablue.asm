(lldb) process attach --pid 43156
Process 43156 stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
       frame #0: 0x000000010029a078 boomkat`boomkat.vm.th_resume_caller + 304
boomkat`boomkat.vm.th_resume_caller:
->  0x10029a078 <+304>: ldrb   w9, [x0]
    0x10029a07c <+308>: ldr    x2, [x3, #0x38]
    0x10029a080 <+312>: mov    x3, x8
    0x10029a084 <+316>: ldr    x4, [x1, x9, lsl #3]
Target 0: (boomkat) stopped.
Executable binary set to "/private/tmp/bk-jsc-map/boomkat".
Architecture set to: arm64-apple-macosx-.
(lldb) disassemble --start-address 0x10042a120 --end-address 0x10042a740
    0x10042a120: ldr    x0, [x24]
    0x10042a124: lsr    x3, x0, #48
    0x10042a128: mov    x10, #0xfff8              ; =65528 
    0x10042a12c: cmp    x3, x10
    0x10042a130: b.eq   0x10042a740
    0x10042a134: str    x22, [x21, #0x488]
    0x10042a138: str    x6, [x21, #0x490]
    0x10042a13c: mov    x19, x23
    0x10042a140: mov    x22, x6
    0x10042a144: mov    x2, #0x9568               ; =38248 
    0x10042a148: movk   x2, #0xc90f, lsl #16
    0x10042a14c: movk   x2, #0x74, lsl #32
    0x10042a150: ldr    x0, [x20, #0x8]
    0x10042a154: ldr    w0, [x0, #0x1ba8]
    0x10042a158: ldr    w1, [x2, #0x14]
    0x10042a15c: cmp    x0, x1
    0x10042a160: b.ne   0x10042a6e8
    0x10042a164: ldrb   w0, [x2, #0x1c]
    0x10042a168: and    x0, x0, #0x8
    0x10042a16c: cbnz   x0, 0x10042a6e8
    0x10042a170: ldr    x2, [x2, #0x30]
    0x10042a174: cbz    x2, 0x10042a6e8
    0x10042a178: ldr    x0, [x2]
    0x10042a17c: lsr    x3, x0, #48
    0x10042a180: mov    x10, #0xfff3              ; =65523 
    0x10042a184: cmp    x3, x10
    0x10042a188: b.ne   0x10042a198
    0x10042a18c: mov    x10, #-0xd000000000000    ; =-3659174697238528 
    0x10042a190: cmp    x0, x10
    0x10042a194: b.ne   0x10042a6e8
    0x10042a198: lsr    x3, x0, #48
    0x10042a19c: mov    x10, #0xfff8              ; =65528 
    0x10042a1a0: cmp    x3, x10
    0x10042a1a4: b.eq   0x10042a6e8
    0x10042a1a8: str    x0, [x21, #0x180]
    0x10042a1ac: mov    x1, #0x87                 ; =135 
    0x10042a1b0: movk   x1, #0x0, lsl #16
    0x10042a1b4: movk   x1, #0x0, lsl #32
    0x10042a1b8: movk   x1, #0x0, lsl #48
    0x10042a1bc: ldr    x0, [x20, #0x8]
    0x10042a1c0: ldr    w0, [x0, #0x1ba8]
    0x10042a1c4: cmp    x0, x1
    0x10042a1c8: b.ne   0x10042a6e8
    0x10042a1cc: mov    x0, x22
    0x10042a1d0: mov    x4, x0
    0x10042a1d4: mov    x0, x4
    0x10042a1d8: lsr    x3, x0, #48
    0x10042a1dc: mov    x10, #0xfff9              ; =65529 
    0x10042a1e0: cmp    x3, x10
    0x10042a1e4: b.ne   0x10042a6e8
    0x10042a1e8: and    x0, x0, #0xffffffffffff
    0x10042a1ec: cbz    x0, 0x10042a6e8
    0x10042a1f0: ldr    w3, [x0]
    0x10042a1f4: mov    x10, #0xf000              ; =61440 
    0x10042a1f8: movk   x10, #0x503f, lsl #16
    0x10042a1fc: and    x3, x3, x10
    0x10042a200: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a204: b.ne   0x10042a6e8
    0x10042a208: ldr    w2, [x0, #0x10]
    0x10042a20c: cmp    x2, #0x116
    0x10042a210: b.ne   0x10042a6e8
    0x10042a214: ldr    x0, [x0, #0x8]
    0x10042a218: cbz    x0, 0x10042a6e8
    0x10042a21c: ldr    w3, [x0]
    0x10042a220: mov    x10, #0xf000              ; =61440 
    0x10042a224: movk   x10, #0x503f, lsl #16
    0x10042a228: and    x3, x3, x10
    0x10042a22c: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a230: b.ne   0x10042a6e8
    0x10042a234: ldr    w2, [x0, #0x10]
    0x10042a238: cmp    x2, #0xe5
    0x10042a23c: b.ne   0x10042a6e8
    0x10042a240: ldr    x0, [x0, #0x8]
    0x10042a244: cbz    x0, 0x10042a6e8
    0x10042a248: ldr    w3, [x0]
    0x10042a24c: mov    x10, #0xf000              ; =61440 
    0x10042a250: movk   x10, #0x503f, lsl #16
    0x10042a254: and    x3, x3, x10
    0x10042a258: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a25c: b.ne   0x10042a6e8
    0x10042a260: ldr    w2, [x0, #0x10]
    0x10042a264: cmp    x2, #0xfa
    0x10042a268: b.ne   0x10042a6e8
    0x10042a26c: ldr    x1, [x0, #0x28]
    0x10042a270: cbnz   x1, 0x10042a278
    0x10042a274: add    x1, x0, #0x38
    0x10042a278: mov    x5, x1
    0x10042a27c: mov    x1, x5
    0x10042a280: ldr    x6, [x1, #0x28]
    0x10042a284: mov    x0, x6
    0x10042a288: lsr    x3, x0, #48
    0x10042a28c: mov    x10, #0xfff9              ; =65529 
    0x10042a290: cmp    x3, x10
    0x10042a294: b.ne   0x10042a6e8
    0x10042a298: and    x0, x0, #0xffffffffffff
    0x10042a29c: cbz    x0, 0x10042a6e8
    0x10042a2a0: ldr    w1, [x0]
    0x10042a2a4: mov    x10, #0x8600              ; =34304 
    0x10042a2a8: movk   x10, #0x3f, lsl #16
    0x10042a2ac: and    x1, x1, x10
    0x10042a2b0: mov    x10, #0x200               ; =512 
    0x10042a2b4: movk   x10, #0x3, lsl #16
    0x10042a2b8: cmp    x1, x10
    0x10042a2bc: b.ne   0x10042a6e8
    0x10042a2c0: ldr    x1, [x0, #0x38]
    0x10042a2c4: mov    x10, #0x4000              ; =16384 
    0x10042a2c8: movk   x10, #0xc910, lsl #16
    0x10042a2cc: movk   x10, #0x74, lsl #32
    0x10042a2d0: cmp    x1, x10
    0x10042a2d4: b.ne   0x10042a6e8
    0x10042a2d8: ldr    x1, [x0, #0x88]
    0x10042a2dc: cbnz   x1, 0x10042a6e8
    0x10042a2e0: mov    x0, x4
    0x10042a2e4: lsr    x3, x0, #48
    0x10042a2e8: mov    x10, #0xfff9              ; =65529 
    0x10042a2ec: cmp    x3, x10
    0x10042a2f0: b.ne   0x10042a6e8
    0x10042a2f4: and    x0, x0, #0xffffffffffff
    0x10042a2f8: cbz    x0, 0x10042a6e8
    0x10042a2fc: ldr    w3, [x0]
    0x10042a300: mov    x10, #0xf000              ; =61440 
    0x10042a304: movk   x10, #0x503f, lsl #16
    0x10042a308: and    x3, x3, x10
    0x10042a30c: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a310: b.ne   0x10042a6e8
    0x10042a314: ldr    w2, [x0, #0x10]
    0x10042a318: cmp    x2, #0x116
    0x10042a31c: b.ne   0x10042a6e8
    0x10042a320: mov    x0, x4
    0x10042a324: and    x0, x0, #0xffffffffffff
    0x10042a328: ldr    x1, [x0, #0x28]
    0x10042a32c: cbnz   x1, 0x10042a334
    0x10042a330: add    x1, x0, #0x38
    0x10042a334: mov    x6, x1
    0x10042a338: mov    x1, x6
    0x10042a33c: ldr    x0, [x1, #0x18]
    0x10042a340: lsr    x3, x0, #48
    0x10042a344: mov    x10, #0xfff1              ; =65521 
    0x10042a348: cmp    x3, x10
    0x10042a34c: b.ne   0x10042a6e8
    0x10042a350: sxtw   x3, w0
    0x10042a354: lsl    x0, x0, #16
    0x10042a358: asr    x0, x0, #16
    0x10042a35c: cmp    x0, x3
    0x10042a360: b.ne   0x10042a6e8
    0x10042a364: str    x0, [x21, #0x188]
    0x10042a368: ldr    x0, [x21, #0x180]
    0x10042a36c: lsr    x3, x0, #48
    0x10042a370: mov    x10, #0xfff8              ; =65528 
    0x10042a374: cmp    x3, x10
    0x10042a378: b.eq   0x10042a6e8
    0x10042a37c: str    x0, [x21, #0x190]
    0x10042a380: ldr    x0, [x21, #0x190]
    0x10042a384: lsr    x3, x0, #48
    0x10042a388: mov    x10, #0xfff9              ; =65529 
    0x10042a38c: cmp    x3, x10
    0x10042a390: b.ne   0x10042a6e8
    0x10042a394: and    x0, x0, #0xffffffffffff
    0x10042a398: cbz    x0, 0x10042a6e8
    0x10042a39c: ldr    w3, [x0]
    0x10042a3a0: mov    x10, #0xf000              ; =61440 
    0x10042a3a4: movk   x10, #0x503f, lsl #16
    0x10042a3a8: and    x3, x3, x10
    0x10042a3ac: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a3b0: b.ne   0x10042a6e8
    0x10042a3b4: ldr    w2, [x0, #0x10]
    0x10042a3b8: cmp    x2, #0xea
    0x10042a3bc: b.ne   0x10042a6e8
    0x10042a3c0: ldr    x0, [x21, #0x190]
    0x10042a3c4: and    x0, x0, #0xffffffffffff
    0x10042a3c8: ldr    x1, [x0, #0x28]
    0x10042a3cc: cbnz   x1, 0x10042a3d4
    0x10042a3d0: add    x1, x0, #0x38
    0x10042a3d4: str    x1, [x21, #0x198]
    0x10042a3d8: ldr    x1, [x21, #0x198]
    0x10042a3dc: ldr    x0, [x1, #0x8]
    0x10042a3e0: lsr    x3, x0, #48
    0x10042a3e4: mov    x10, #0xfff1              ; =65521 
    0x10042a3e8: cmp    x3, x10
    0x10042a3ec: b.ne   0x10042a6e8
    0x10042a3f0: sxtw   x3, w0
    0x10042a3f4: lsl    x0, x0, #16
    0x10042a3f8: asr    x0, x0, #16
    0x10042a3fc: cmp    x0, x3
    0x10042a400: b.ne   0x10042a6e8
    0x10042a404: str    x0, [x21, #0x1a0]
    0x10042a408: ldr    x0, [x21, #0x188]
    0x10042a40c: ldr    x1, [x21, #0x1a0]
    0x10042a410: cmp    x0, x1
    0x10042a414: cset   x0, ne
    0x10042a418: mov    x10, #-0xb000000000000    ; =-3096224743817216 
    0x10042a41c: orr    x0, x0, x10
    0x10042a420: str    x0, [x21, #0x1a8]
    0x10042a424: mov    x1, x6
    0x10042a428: ldr    x0, [x1, #0x10]
    0x10042a42c: lsr    x3, x0, #48
    0x10042a430: mov    x10, #0xfff8              ; =65528 
    0x10042a434: cmp    x3, x10
    0x10042a438: b.eq   0x10042a6e8
    0x10042a43c: str    x0, [x21, #0x1b0]
    0x10042a440: mov    x1, x6
    0x10042a444: ldr    x0, [x1, #0x8]
    0x10042a448: lsr    x3, x0, #48
    0x10042a44c: mov    x10, #0xfff8              ; =65528 
    0x10042a450: cmp    x3, x10
    0x10042a454: b.eq   0x10042a6e8
    0x10042a458: str    x0, [x21, #0x1b8]
    0x10042a45c: ldr    x1, [x21, #0x1b8]
    0x10042a460: ldr    x2, [x21, #0x1b0]
    0x10042a464: ldr    x0, [x21, #0x1a8]
    0x10042a468: mov    x10, #-0xb000000000000    ; =-3096224743817216 
    0x10042a46c: cmp    x0, x10
    0x10042a470: csel   x0, x2, x1, eq
    0x10042a474: lsr    x3, x0, #48
    0x10042a478: mov    x10, #0xfff8              ; =65528 
    0x10042a47c: cmp    x3, x10
    0x10042a480: b.eq   0x10042a6e8
    0x10042a484: str    x0, [x21, #0x1c0]
    0x10042a488: ldr    x0, [x21, #0x1c0]
    0x10042a48c: lsr    x3, x0, #48
    0x10042a490: mov    x10, #0xfff8              ; =65528 
    0x10042a494: cmp    x3, x10
    0x10042a498: b.eq   0x10042a6e8
    0x10042a49c: str    x0, [x21, #0x1c0]
    0x10042a4a0: mov    x1, x5
    0x10042a4a4: ldr    x0, [x1, #0x20]
    0x10042a4a8: lsr    x3, x0, #48
    0x10042a4ac: mov    x10, #0xfff8              ; =65528 
    0x10042a4b0: cmp    x3, x10
    0x10042a4b4: b.eq   0x10042a6e8
    0x10042a4b8: str    x0, [x21, #0x1c8]
    0x10042a4bc: ldr    x0, [x21, #0x1c8]
    0x10042a4c0: lsr    x3, x0, #48
    0x10042a4c4: mov    x10, #0xfff9              ; =65529 
    0x10042a4c8: cmp    x3, x10
    0x10042a4cc: b.ne   0x10042a6e8
    0x10042a4d0: and    x0, x0, #0xffffffffffff
    0x10042a4d4: cbz    x0, 0x10042a6e8
    0x10042a4d8: ldr    w1, [x0]
    0x10042a4dc: mov    x10, #0x8600              ; =34304 
    0x10042a4e0: movk   x10, #0x3f, lsl #16
    0x10042a4e4: and    x1, x1, x10
    0x10042a4e8: mov    x10, #0x200               ; =512 
    0x10042a4ec: movk   x10, #0x3, lsl #16
    0x10042a4f0: cmp    x1, x10
    0x10042a4f4: b.ne   0x10042a6e8
    0x10042a4f8: ldr    x1, [x0, #0x38]
    0x10042a4fc: mov    x10, #0x3d40              ; =15680 
    0x10042a500: movk   x10, #0xc910, lsl #16
    0x10042a504: movk   x10, #0x74, lsl #32
    0x10042a508: cmp    x1, x10
    0x10042a50c: b.ne   0x10042a6e8
    0x10042a510: ldr    x1, [x0, #0x88]
    0x10042a514: cbnz   x1, 0x10042a6e8
    0x10042a518: ldr    x0, [x21, #0x188]
    0x10042a51c: str    x0, [x21, #0x188]
    0x10042a520: ldr    x0, [x21, #0x190]
    0x10042a524: lsr    x3, x0, #48
    0x10042a528: mov    x10, #0xfff8              ; =65528 
    0x10042a52c: cmp    x3, x10
    0x10042a530: b.eq   0x10042a6e8
    0x10042a534: str    x0, [x21, #0x190]
    0x10042a538: ldr    x0, [x21, #0x198]
    0x10042a53c: str    x0, [x21, #0x198]
    0x10042a540: ldr    x0, [x21, #0x1a0]
    0x10042a544: str    x0, [x21, #0x1a0]
    0x10042a548: ldr    x0, [x21, #0x188]
    0x10042a54c: ldr    x1, [x21, #0x1a0]
    0x10042a550: cmp    x0, x1
    0x10042a554: cset   x0, ne
    0x10042a558: mov    x10, #-0xb000000000000    ; =-3096224743817216 
    0x10042a55c: orr    x0, x0, x10
    0x10042a560: mov    x5, x0
    0x10042a564: ldr    x0, [x21, #0x1b8]
    0x10042a568: lsr    x3, x0, #48
    0x10042a56c: mov    x10, #0xfff8              ; =65528 
    0x10042a570: cmp    x3, x10
    0x10042a574: b.eq   0x10042a6e8
    0x10042a578: str    x0, [x21, #0x1b8]
    0x10042a57c: ldr    x0, [x21, #0x1b0]
    0x10042a580: lsr    x3, x0, #48
    0x10042a584: mov    x10, #0xfff8              ; =65528 
    0x10042a588: cmp    x3, x10
    0x10042a58c: b.eq   0x10042a6e8
    0x10042a590: str    x0, [x21, #0x1b0]
    0x10042a594: ldr    x1, [x21, #0x1b0]
    0x10042a598: ldr    x2, [x21, #0x1b8]
    0x10042a59c: mov    x0, x5
    0x10042a5a0: mov    x10, #-0xb000000000000    ; =-3096224743817216 
    0x10042a5a4: cmp    x0, x10
    0x10042a5a8: csel   x6, x2, x1, eq
    0x10042a5ac: mov    x0, x6
    0x10042a5b0: lsr    x3, x0, #48
    0x10042a5b4: mov    x10, #0xfff9              ; =65529 
    0x10042a5b8: cmp    x3, x10
    0x10042a5bc: b.ne   0x10042a6e8
    0x10042a5c0: and    x0, x0, #0xffffffffffff
    0x10042a5c4: cbz    x0, 0x10042a6e8
    0x10042a5c8: ldr    w3, [x0]
    0x10042a5cc: mov    x10, #0xf000              ; =61440 
    0x10042a5d0: movk   x10, #0x503f, lsl #16
    0x10042a5d4: and    x3, x3, x10
    0x10042a5d8: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a5dc: b.ne   0x10042a6e8
    0x10042a5e0: ldr    w2, [x0, #0x10]
    0x10042a5e4: cmp    x2, #0x112
    0x10042a5e8: b.ne   0x10042a6e8
    0x10042a5ec: mov    x0, x6
    0x10042a5f0: and    x0, x0, #0xffffffffffff
    0x10042a5f4: ldr    x1, [x0, #0x28]
    0x10042a5f8: cbnz   x1, 0x10042a600
    0x10042a5fc: add    x1, x0, #0x38
    0x10042a600: mov    x5, x1
    0x10042a604: mov    x1, x5
    0x10042a608: ldr    x0, [x1]
    0x10042a60c: lsr    x3, x0, #48
    0x10042a610: mov    x10, #0xfff1              ; =65521 
    0x10042a614: cmp    x3, x10
    0x10042a618: b.ne   0x10042a6e8
    0x10042a61c: sxtw   x3, w0
    0x10042a620: lsl    x6, x0, #16
    0x10042a624: asr    x6, x6, #16
    0x10042a628: cmp    x6, x3
    0x10042a62c: b.ne   0x10042a6e8
    0x10042a630: mov    x0, x6
    0x10042a634: and    x0, x0, #0xffffffffffff
    0x10042a638: mov    x10, #-0xf000000000000    ; =-4222124650659840 
    0x10042a63c: orr    x0, x0, x10
    0x10042a640: mov    x5, x0
    0x10042a644: ldr    x0, [x21, #0x1c0]
    0x10042a648: lsr    x3, x0, #48
    0x10042a64c: mov    x10, #0xfff9              ; =65529 
    0x10042a650: cmp    x3, x10
    0x10042a654: b.ne   0x10042a6e8
    0x10042a658: and    x0, x0, #0xffffffffffff
    0x10042a65c: cbz    x0, 0x10042a6e8
    0x10042a660: ldr    w3, [x0]
    0x10042a664: mov    x10, #0xf000              ; =61440 
    0x10042a668: movk   x10, #0x503f, lsl #16
    0x10042a66c: and    x3, x3, x10
    0x10042a670: cmp    x3, #0x10, lsl #12        ; =0x10000 
    0x10042a674: b.ne   0x10042a6e8
    0x10042a678: ldr    w2, [x0, #0x10]
    0x10042a67c: cmp    x2, #0x112
    0x10042a680: b.ne   0x10042a6e8
    0x10042a684: ldr    x0, [x21, #0x1c0]
    0x10042a688: and    x0, x0, #0xffffffffffff
    0x10042a68c: ldr    w3, [x0, #0x4]
    0x10042a690: and    x3, x3, #0x20
    0x10042a694: cbnz   x3, 0x10042a6e8
    0x10042a698: ldr    x0, [x21, #0x1c0]
    0x10042a69c: and    x0, x0, #0xffffffffffff
    0x10042a6a0: ldr    x1, [x0, #0x28]
    0x10042a6a4: cbnz   x1, 0x10042a6ac
    0x10042a6a8: add    x1, x0, #0x38
    0x10042a6ac: mov    x4, x1
    0x10042a6b0: mov    x0, x5
    0x10042a6b4: lsr    x3, x0, #48
    0x10042a6b8: mov    x10, #0xfff1              ; =65521 
    0x10042a6bc: cmp    x3, x10
    0x10042a6c0: b.hi   0x10042a6e8
    0x10042a6c4: mov    x2, x4
    0x10042a6c8: ldr    x3, [x2]
    0x10042a6cc: lsr    x3, x3, #48
    0x10042a6d0: mov    x10, #0xfff8              ; =65528 
    0x10042a6d4: cmp    x3, x10
    0x10042a6d8: b.eq   0x10042a6e8
    0x10042a6dc: str    x0, [x2]
    0x10042a6e0: mov    x0, #-0xd000000000000     ; =-3659174697238528 
    0x10042a6e4: b      0x10042a6f0
    0x10042a6e8: mov    x0, #-0x3000000000000     ; =-844424930131968 
    0x10042a6ec: b      0x10042a6f0
    0x10042a6f0: mov    x10, #-0x3000000000000    ; =-844424930131968 
    0x10042a6f4: cmp    x0, x10
    0x10042a6f8: b.eq   0x10042a72c
    0x10042a6fc: str    x0, [x24]
    0x10042a700: ldr    x0, [x21, #0x8]
    0x10042a704: sub    x0, x0, #0x1
    0x10042a708: str    x0, [x21, #0x8]
    0x10042a70c: ldr    x0, [x20, #0x10]
    0x10042a710: ldr    x19, [x0, #0x38]
    0x10042a714: mov    x0, #0x0                  ; =0 
    0x10042a718: ldp    x29, x30, [sp]
    0x10042a71c: ldp    x22, x23, [sp, #0x20]
    0x10042a720: ldr    x24, [sp, #0x18]
    0x10042a724: add    sp, sp, #0x30
    0x10042a728: ret    
    0x10042a72c: ldr    x22, [x21, #0x488]
    0x10042a730: ldr    x6, [x21, #0x490]
    0x10042a734: ldr    x0, [x20, #0x10]
    0x10042a738: ldr    x19, [x0, #0x38]
    0x10042a73c: ldr    x4, [x20]
(lldb) process detach
Process 43156 detached
