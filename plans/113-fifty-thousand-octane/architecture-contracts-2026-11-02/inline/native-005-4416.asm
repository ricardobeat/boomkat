0000: stp      x29, x30, [sp, #-0x40]!
0004: stp      x19, x20, [sp, #0x30]
0008: stp      x21, x22, [sp, #0x20]
000c: str      x23, [sp, #0x18]
0010: mov      x29, sp
0014: mov      x19, x0
0018: mov      x20, x1
001c: ldr      x0, [x19, #0x9a0]
0020: ldr      x0, [x0, #0x50]
0024: ldr      x0, [x0]
0028: mov      x7, x0
002c: ldr      x0, [x19, #0x9a0]
0030: ldr      x0, [x0, #0x50]
0034: ldr      x0, [x0, #0x8]
0038: mov      x21, x0
003c: ldr      x0, [x19, #0x9a0]
0040: ldr      x0, [x0, #0x50]
0044: ldr      x0, [x0, #0x10]
0048: mov      x22, x0
004c: ldr      x0, [x19, #0x9a0]
0050: ldr      x0, [x0, #0x50]
0054: ldr      x0, [x0, #0x18]
0058: mov      x4, x0
005c: ldr      x0, [x19, #0x9a0]
0060: ldr      x0, [x0, #0x50]
0064: ldr      x0, [x0, #0x20]
0068: mov      x5, x0
006c: ldr      x0, [x19, #0x9a0]
0070: ldr      x0, [x0, #0x50]
0074: ldr      x0, [x0, #0x28]
0078: mov      x6, x0
007c: ldr      x0, [x19, #0x9a0]
0080: ldr      x0, [x0, #0x50]
0084: ldr      x0, [x0, #0x30]
0088: mov      x23, x0
008c: ldr      x0, [x19, #0x9a0]
0090: ldr      x0, [x0, #0x50]
0094: ldr      x0, [x0, #0x38]
0098: str      x0, [x19, #0x9a8]
009c: ldr      x0, [x19, #0x9a0]
00a0: ldr      x0, [x0, #0x50]
00a4: ldr      x0, [x0, #0x40]
00a8: str      x0, [x19, #0x9b0]
00ac: ldr      w0, [x19, #0x20c]
00b0: cbnz     x0, 0x10055f000
00b4: mov      x4, x7
00b8: mov      x5, x21
00bc: mov      x0, x22
00c0: lsr      x3, x0, #48
00c4: mov      x10, #0xfff1
00c8: cmp      x3, x10
00cc: b.eq     0x10055efe4
00d0: mov      x10, #0xfff1
00d4: cmp      x3, x10
00d8: b.hi     0x10055ff08
00dc: fmov     d0, x0
00e0: fcmp     d0, d0
00e4: b.vs     0x10055ff08
00e8: mov      x1, #-0x3e20000000000000
00ec: fmov     d1, x1
00f0: fcmp     d0, d1
00f4: b.mi     0x10055ff08
00f8: mov      x1, #0x41e0000000000000
00fc: fmov     d1, x1
0100: fcmp     d0, d1
0104: b.ge     0x10055ff08
0108: lsl      x3, x0, #1
010c: cbnz     x3, 0x10055efc8
0110: cmp      x0, #0x0
0114: b.lt     0x10055ff08
0118: fcvtzs   x6, d0
011c: scvtf    d1, x6
0120: fcmp     d0, d1
0124: cset     x9, ne
0128: ccmp     x9, #0x0, #0x4, vc
012c: b.ne     0x10055ff08
0130: b        0x10055effc
0134: sxtw     x3, w0
0138: lsl      x1, x0, #16
013c: asr      x1, x1, #16
0140: cmp      x1, x3
0144: b.ne     0x10055ff08
0148: mov      x6, x1
014c: b        0x10055fef8
0150: ldr      w0, [x19, #0x20c]
0154: cmp      x0, #0x3
0158: b.ne     0x10055f0a4
015c: mov      x0, x22
0160: lsr      x3, x0, #48
0164: mov      x10, #0xfff1
0168: cmp      x3, x10
016c: b.eq     0x10055f084
0170: mov      x10, #0xfff1
0174: cmp      x3, x10
0178: b.hi     0x10055ff08
017c: fmov     d0, x0
0180: fcmp     d0, d0
0184: b.vs     0x10055ff08
0188: mov      x1, #-0x3e20000000000000
018c: fmov     d1, x1
0190: fcmp     d0, d1
0194: b.mi     0x10055ff08
0198: mov      x1, #0x41e0000000000000
019c: fmov     d1, x1
01a0: fcmp     d0, d1
01a4: b.ge     0x10055ff08
01a8: lsl      x3, x0, #1
01ac: cbnz     x3, 0x10055f068
01b0: cmp      x0, #0x0
01b4: b.lt     0x10055ff08
01b8: fcvtzs   x4, d0
01bc: scvtf    d1, x4
01c0: fcmp     d0, d1
01c4: cset     x9, ne
01c8: ccmp     x9, #0x0, #0x4, vc
01cc: b.ne     0x10055ff08
01d0: b        0x10055f09c
01d4: sxtw     x3, w0
01d8: lsl      x1, x0, #16
01dc: asr      x1, x1, #16
01e0: cmp      x1, x3
01e4: b.ne     0x10055ff08
01e8: mov      x4, x1
01ec: mov      x5, x6
01f0: b        0x10055fefc
01f4: b        0x10055ff08
01f8: mov      x0, x4
01fc: ldr      x3, [x19, #0x9a0]
0200: ldr      x3, [x3, #0x70]
0204: str      x0, [x3, #0x48]
0208: mov      x0, x5
020c: ldr      x3, [x19, #0x9a0]
0210: ldr      x3, [x3, #0x70]
0214: str      x0, [x3, #0x50]
0218: mov      x0, x6
021c: ldr      x3, [x19, #0x9a0]
0220: ldr      x3, [x3, #0x70]
0224: str      x0, [x3, #0x58]
0228: mov      x0, x4
022c: ldr      x3, [x19, #0x9a0]
0230: ldr      x3, [x3, #0x70]
0234: str      x0, [x3, #0x48]
0238: mov      x0, x5
023c: ldr      x3, [x19, #0x9a0]
0240: ldr      x3, [x3, #0x70]
0244: str      x0, [x3, #0x50]
0248: mov      x0, x6
024c: and      x0, x0, #0xffffffffffff
0250: mov      x10, #-0xf000000000000
0254: orr      x0, x0, x10
0258: ldr      x2, [x19, #0x9a0]
025c: ldr      x2, [x2, #0x78]
0260: mov      x9, #0x2
0264: str      w9, [x2]
0268: str      x0, [x2, #0x8]
026c: mov      x0, x4
0270: ldr      x2, [x19, #0x9a0]
0274: ldr      x2, [x2, #0x78]
0278: mov      x9, #0x7
027c: str      w9, [x2, #0x10]
0280: str      x0, [x2, #0x18]
0284: mov      x0, x5
0288: ldr      x2, [x19, #0x9a0]
028c: ldr      x2, [x2, #0x78]
0290: mov      x9, #0x8
0294: str      w9, [x2, #0x20]
0298: str      x0, [x2, #0x28]
029c: ldr      x2, [x19, #0x9a0]
02a0: mov      x9, #0x3
02a4: str      w9, [x2, #0x80]
02a8: str      x20, [x19, #0x398]
02ac: mov      x0, x19
02b0: mov      x1, #0xc0
02b4: movk     x1, #0x114f, lsl #16
02b8: movk     x1, #0x75, lsl #32
02bc: bl       0x10026b934
02c0: cbz      x0, 0x10055f190
02c4: ldr      w0, [x19, #0x20c]
02c8: ldp      x29, x30, [sp]
02cc: ldp      x19, x20, [sp, #0x30]
02d0: ldp      x21, x22, [sp, #0x20]
02d4: ldr      x23, [sp, #0x18]
02d8: add      sp, sp, #0x40
02dc: ret
02e0: ldr      x3, [x19, #0x9a0]
02e4: ldr      x3, [x3, #0x70]
02e8: ldr      x0, [x3, #0x48]
02ec: mov      x4, x0
02f0: ldr      x3, [x19, #0x9a0]
02f4: ldr      x3, [x3, #0x70]
02f8: ldr      x0, [x3, #0x50]
02fc: mov      x5, x0
0300: ldr      x3, [x19, #0x9a0]
0304: ldr      x3, [x3, #0x70]
0308: ldr      x0, [x3, #0x58]
030c: mov      x6, x0
0310: ldr      x0, [x19, #0x9a0]
0314: ldr      x0, [x0, #0x50]
0318: ldr      x0, [x0, #0x28]
031c: mov      x7, x0
0320: mov      x0, x7
0324: lsr      x3, x0, #48
0328: mov      x10, #0xfff9
032c: cmp      x3, x10
0330: b.ne     0x10055ff18
0334: and      x0, x0, #0xffffffffffff
0338: cbz      x0, 0x10055ff18
033c: ldr      w1, [x0]
0340: mov      x10, #0x8600
0344: movk     x10, #0x3f, lsl #16
0348: and      x1, x1, x10
034c: mov      x10, #0x200
0350: movk     x10, #0x3, lsl #16
0354: cmp      x1, x10
0358: b.ne     0x10055ff18
035c: ldr      x1, [x0, #0x38]
0360: mov      x10, #0x5600
0364: movk     x10, #0x10c7, lsl #16
0368: movk     x10, #0x75, lsl #32
036c: cmp      x1, x10
0370: b.ne     0x10055ff18
0374: ldr      x1, [x0, #0x88]
0378: cbnz     x1, 0x10055ff18
037c: mov      x0, x4
0380: ldr      x3, [x19, #0x9a0]
0384: ldr      x3, [x3, #0x70]
0388: str      x0, [x3, #0x48]
038c: mov      x0, x5
0390: ldr      x3, [x19, #0x9a0]
0394: ldr      x3, [x3, #0x70]
0398: str      x0, [x3, #0x50]
039c: mov      x0, x6
03a0: ldr      x3, [x19, #0x9a0]
03a4: ldr      x3, [x3, #0x70]
03a8: str      x0, [x3, #0x58]
03ac: mov      x0, x7
03b0: ldr      x3, [x19, #0x9a0]
03b4: ldr      x3, [x3, #0x70]
03b8: str      x0, [x3, #0x80]
03bc: mov      x0, x4
03c0: ldr      x3, [x19, #0x9a0]
03c4: ldr      x3, [x3, #0x70]
03c8: str      x0, [x3, #0x48]
03cc: mov      x0, x5
03d0: ldr      x3, [x19, #0x9a0]
03d4: ldr      x3, [x3, #0x70]
03d8: str      x0, [x3, #0x50]
03dc: mov      x0, x7
03e0: ldr      x3, [x19, #0x9a0]
03e4: ldr      x3, [x3, #0x70]
03e8: str      x0, [x3, #0x80]
03ec: mov      x0, x6
03f0: and      x0, x0, #0xffffffffffff
03f4: mov      x10, #-0xf000000000000
03f8: orr      x0, x0, x10
03fc: ldr      x2, [x19, #0x9a0]
0400: ldr      x2, [x2, #0x78]
0404: mov      x9, #0x2
0408: str      w9, [x2]
040c: str      x0, [x2, #0x8]
0410: mov      x0, x4
0414: ldr      x2, [x19, #0x9a0]
0418: ldr      x2, [x2, #0x78]
041c: mov      x9, #0x7
0420: str      w9, [x2, #0x10]
0424: str      x0, [x2, #0x18]
0428: mov      x0, x5
042c: ldr      x2, [x19, #0x9a0]
0430: ldr      x2, [x2, #0x78]
0434: mov      x9, #0x8
0438: str      w9, [x2, #0x20]
043c: str      x0, [x2, #0x28]
0440: ldr      x2, [x19, #0x9a0]
0444: mov      x9, #0x3
0448: str      w9, [x2, #0x80]
044c: str      x20, [x19, #0x398]
0450: mov      x0, x19
0454: mov      x1, #0x114f0000
0458: movk     x1, #0x75, lsl #32
045c: bl       0x10026b934
0460: cbz      x0, 0x10055f330
0464: ldr      w0, [x19, #0x20c]
0468: ldp      x29, x30, [sp]
046c: ldp      x19, x20, [sp, #0x30]
0470: ldp      x21, x22, [sp, #0x20]
0474: ldr      x23, [sp, #0x18]
0478: add      sp, sp, #0x40
047c: ret
0480: ldr      x3, [x19, #0x9a0]
0484: ldr      x3, [x3, #0x70]
0488: ldr      x0, [x3, #0x48]
048c: mov      x4, x0
0490: ldr      x3, [x19, #0x9a0]
0494: ldr      x3, [x3, #0x70]
0498: ldr      x0, [x3, #0x50]
049c: mov      x5, x0
04a0: ldr      x3, [x19, #0x9a0]
04a4: ldr      x3, [x3, #0x70]
04a8: ldr      x0, [x3, #0x58]
04ac: mov      x6, x0
04b0: ldr      x3, [x19, #0x9a0]
04b4: ldr      x3, [x3, #0x70]
04b8: ldr      x0, [x3, #0x80]
04bc: mov      x7, x0
04c0: mov      x21, #-0xd000000000000
04c4: mov      x0, x4
04c8: lsr      x3, x0, #48
04cc: mov      x10, #0xfff9
04d0: cmp      x3, x10
04d4: b.ne     0x10055ff28
04d8: and      x0, x0, #0xffffffffffff
04dc: cbz      x0, 0x10055ff28
04e0: ldr      w3, [x0]
04e4: mov      x10, #0xf000
04e8: movk     x10, #0x503f, lsl #16
04ec: and      x3, x3, x10
04f0: cmp      x3, #0x10, lsl #12
04f4: b.ne     0x10055ff28
04f8: ldr      w3, [x0, #0x10]
04fc: cmp      x3, #0x17
0500: b.ne     0x10055ff28
0504: mov      x2, #0xc6a0
0508: movk     x2, #0x10c0, lsl #16
050c: movk     x2, #0x75, lsl #32
0510: ldr      x2, [x2]
0514: ldr      x2, [x2, #0xb8]
0518: cbz      x2, 0x10055ff28
051c: ldr      w3, [x2]
0520: cmp      x3, #0x6a
0524: b.ne     0x10055ff28
0528: ldr      x2, [x0, #0x28]
052c: cbnz     x2, 0x10055f3e4
0530: add      x2, x0, #0x38
0534: add      x2, x2, #0x0
0538: mov      x22, x2
053c: mov      x2, x22
0540: ldr      x0, [x2]
0544: lsr      x3, x0, #48
0548: mov      x10, #0xfff1
054c: cmp      x3, x10
0550: b.hi     0x10055ff28
0554: mov      x23, x0
0558: mov      x0, x23
055c: lsr      x3, x0, #48
0560: mov      x10, #0xfff1
0564: cmp      x3, x10
0568: b.hi     0x10055ff38
056c: mov      x10, #0xfff1
0570: cmp      x3, x10
0574: b.ne     0x10055f438
0578: lsl      x0, x0, #16
057c: asr      x0, x0, #16
0580: scvtf    d2, x0
0584: b        0x10055f43c
0588: fmov     d2, x0
058c: orr      x0, xzr, #0x3ff0000000000000
0590: fmov     d3, x0
0594: fadd     d4, d2, d3
0598: mov      x0, x4
059c: lsr      x3, x0, #48
05a0: mov      x10, #0xfff9
05a4: cmp      x3, x10
05a8: b.ne     0x10055ff48
05ac: and      x0, x0, #0xffffffffffff
05b0: cbz      x0, 0x10055ff48
05b4: ldr      w3, [x0]
05b8: mov      x10, #0xf000
05bc: movk     x10, #0x503f, lsl #16
05c0: and      x3, x3, x10
05c4: cmp      x3, #0x10, lsl #12
05c8: b.ne     0x10055ff48
05cc: ldr      w3, [x0, #0x4]
05d0: mov      x10, #0x20
05d4: movk     x10, #0x1, lsl #16
05d8: and      x3, x3, x10
05dc: cbnz     x3, 0x10055ff48
05e0: ldr      w3, [x0, #0x10]
05e4: cmp      x3, #0x17
05e8: b.ne     0x10055ff48
05ec: mov      x2, #0xc6a0
05f0: movk     x2, #0x10c0, lsl #16
05f4: movk     x2, #0x75, lsl #32
05f8: ldr      x2, [x2]
05fc: ldr      x2, [x2, #0xb8]
0600: cbz      x2, 0x10055ff48
0604: ldr      w3, [x2]
0608: cmp      x3, #0x6a
060c: b.ne     0x10055ff48
0610: ldr      x2, [x0, #0x28]
0614: cbnz     x2, 0x10055f4cc
0618: add      x2, x0, #0x38
061c: add      x2, x2, #0x0
0620: mov      x22, x2
0624: fmov     x23, d4
0628: lsr      x3, x23, #48
062c: mov      x10, #0xfff1
0630: cmp      x3, x10
0634: b.lo     0x10055f4ec
0638: orr      x23, xzr, #0x7ff8000000000000
063c: mov      x2, x22
0640: mov      x0, x23
0644: lsr      x3, x0, #48
0648: mov      x10, #0xfff1
064c: cmp      x3, x10
0650: b.hi     0x10055ff48
0654: ldr      x3, [x2]
0658: lsr      x3, x3, #48
065c: mov      x10, #0xfff1
0660: cmp      x3, x10
0664: b.hi     0x10055ff48
0668: str      x0, [x2]
066c: mov      x0, x4
0670: lsr      x3, x0, #48
0674: mov      x10, #0xfff9
0678: cmp      x3, x10
067c: b.ne     0x10055ff58
0680: and      x0, x0, #0xffffffffffff
0684: cbz      x0, 0x10055ff58
0688: ldr      w3, [x0]
068c: mov      x10, #0xf000
0690: movk     x10, #0x503f, lsl #16
0694: and      x3, x3, x10
0698: cmp      x3, #0x10, lsl #12
069c: b.ne     0x10055ff58
06a0: ldr      w3, [x0, #0x10]
06a4: cmp      x3, #0x17
06a8: b.ne     0x10055ff58
06ac: mov      x2, #0xc6a0
06b0: movk     x2, #0x10c0, lsl #16
06b4: movk     x2, #0x75, lsl #32
06b8: ldr      x2, [x2]
06bc: ldr      x2, [x2, #0xb8]
06c0: cbz      x2, 0x10055ff58
06c4: ldr      w3, [x2]
06c8: cmp      x3, #0x6a
06cc: b.ne     0x10055ff58
06d0: ldr      x2, [x0, #0x28]
06d4: cbnz     x2, 0x10055f58c
06d8: add      x2, x0, #0x38
06dc: add      x2, x2, #0x0
06e0: mov      x22, x2
06e4: mov      x2, x22
06e8: ldr      x0, [x2]
06ec: lsr      x3, x0, #48
06f0: mov      x10, #0xfff1
06f4: cmp      x3, x10
06f8: b.hi     0x10055ff58
06fc: mov      x23, x0
0700: mov      x0, x23
0704: lsr      x3, x0, #48
0708: mov      x10, #0xfff1
070c: cmp      x3, x10
0710: b.hi     0x10055ff68
0714: mov      x10, #0xfff1
0718: cmp      x3, x10
071c: b.ne     0x10055f5e0
0720: lsl      x0, x0, #16
0724: asr      x0, x0, #16
0728: scvtf    d2, x0
072c: b        0x10055f5e4
0730: fmov     d2, x0
0734: mov      x0, x5
0738: lsr      x3, x0, #48
073c: mov      x10, #0xfff1
0740: cmp      x3, x10
0744: b.hi     0x10055ff68
0748: mov      x10, #0xfff1
074c: cmp      x3, x10
0750: b.ne     0x10055f614
0754: lsl      x0, x0, #16
0758: asr      x0, x0, #16
075c: scvtf    d3, x0
0760: b        0x10055f618
0764: fmov     d3, x0
0768: fadd     d4, d2, d3
076c: mov      x7, x6
0770: fmov     x21, d4
0774: lsr      x3, x21, #48
0778: mov      x10, #0xfff1
077c: cmp      x3, x10
0780: b.lo     0x10055f638
0784: orr      x21, xzr, #0x7ff8000000000000
0788: mov      x4, #0x0
078c: and      x5, x7, #0x1
0790: sxtw     x5, w5
0794: add      w6, w4, w5
0798: sxtw     x6, w6
079c: add      w4, w6, w5
07a0: sxtw     x4, w4
07a4: add      w6, w4, w5
07a8: sxtw     x6, w6
07ac: add      w4, w6, w5
07b0: sxtw     x4, w4
07b4: add      w6, w4, w5
07b8: sxtw     x6, w6
07bc: add      w4, w6, w5
07c0: sxtw     x4, w4
07c4: add      w6, w4, w5
07c8: sxtw     x6, w6
07cc: add      w4, w6, w5
07d0: sxtw     x4, w4
07d4: add      w6, w4, w5
07d8: sxtw     x6, w6
07dc: add      w4, w6, w5
07e0: sxtw     x4, w4
07e4: add      w6, w4, w5
07e8: sxtw     x6, w6
07ec: add      w4, w6, w5
07f0: sxtw     x4, w4
07f4: add      w6, w4, w5
07f8: sxtw     x6, w6
07fc: add      w4, w6, w5
0800: sxtw     x4, w4
0804: add      w6, w4, w5
0808: sxtw     x6, w6
080c: add      w4, w6, w5
0810: sxtw     x4, w4
0814: add      w6, w4, w5
0818: sxtw     x6, w6
081c: add      w4, w6, w5
0820: sxtw     x4, w4
0824: add      w6, w4, w5
0828: sxtw     x6, w6
082c: add      w4, w6, w5
0830: sxtw     x4, w4
0834: add      w6, w4, w5
0838: sxtw     x6, w6
083c: add      w4, w6, w5
0840: sxtw     x4, w4
0844: add      w6, w4, w5
0848: sxtw     x6, w6
084c: add      w4, w6, w5
0850: sxtw     x4, w4
0854: add      w6, w4, w5
0858: sxtw     x6, w6
085c: add      w4, w6, w5
0860: sxtw     x4, w4
0864: add      w6, w4, w5
0868: sxtw     x6, w6
086c: add      w4, w6, w5
0870: sxtw     x4, w4
0874: add      w6, w4, w5
0878: sxtw     x6, w6
087c: add      w4, w6, w5
0880: sxtw     x4, w4
0884: add      w6, w4, w5
0888: sxtw     x6, w6
088c: add      w4, w6, w5
0890: sxtw     x4, w4
0894: add      w6, w4, w5
0898: sxtw     x6, w6
089c: add      w4, w6, w5
08a0: sxtw     x4, w4
08a4: add      w6, w4, w5
08a8: sxtw     x6, w6
08ac: add      w4, w6, w5
08b0: sxtw     x4, w4
08b4: add      w6, w4, w5
08b8: sxtw     x6, w6
08bc: add      w4, w6, w5
08c0: sxtw     x4, w4
08c4: add      w6, w4, w5
08c8: sxtw     x6, w6
08cc: add      w4, w6, w5
08d0: sxtw     x4, w4
08d4: add      w6, w4, w5
08d8: sxtw     x6, w6
08dc: add      w4, w6, w5
08e0: sxtw     x4, w4
08e4: add      w6, w4, w5
08e8: sxtw     x6, w6
08ec: add      w4, w6, w5
08f0: sxtw     x4, w4
08f4: add      w6, w4, w5
08f8: sxtw     x6, w6
08fc: add      w4, w6, w5
0900: sxtw     x4, w4
0904: add      w6, w4, w5
0908: sxtw     x6, w6
090c: add      w4, w6, w5
0910: sxtw     x4, w4
0914: add      w6, w4, w5
0918: sxtw     x6, w6
091c: add      w4, w6, w5
0920: sxtw     x4, w4
0924: add      w6, w4, w5
0928: sxtw     x6, w6
092c: add      w4, w6, w5
0930: sxtw     x4, w4
0934: add      w6, w4, w5
0938: sxtw     x6, w6
093c: add      w4, w6, w5
0940: sxtw     x4, w4
0944: add      w6, w4, w5
0948: sxtw     x6, w6
094c: add      w4, w6, w5
0950: sxtw     x4, w4
0954: add      w6, w4, w5
0958: sxtw     x6, w6
095c: add      w4, w6, w5
0960: sxtw     x4, w4
0964: add      w6, w4, w5
0968: sxtw     x6, w6
096c: add      w4, w6, w5
0970: sxtw     x4, w4
0974: add      w6, w4, w5
0978: sxtw     x6, w6
097c: add      w4, w6, w5
0980: sxtw     x4, w4
0984: add      w6, w4, w5
0988: sxtw     x6, w6
098c: add      w4, w6, w5
0990: sxtw     x4, w4
0994: add      w6, w4, w5
0998: sxtw     x6, w6
099c: add      w4, w6, w5
09a0: sxtw     x4, w4
09a4: add      w6, w4, w5
09a8: sxtw     x6, w6
09ac: add      w4, w6, w5
09b0: sxtw     x4, w4
09b4: add      w6, w4, w5
09b8: sxtw     x6, w6
09bc: add      w4, w6, w5
09c0: sxtw     x4, w4
09c4: add      w6, w4, w5
09c8: sxtw     x6, w6
09cc: add      w4, w6, w5
09d0: sxtw     x4, w4
09d4: add      w6, w4, w5
09d8: sxtw     x6, w6
09dc: add      w4, w6, w5
09e0: sxtw     x4, w4
09e4: add      w6, w4, w5
09e8: sxtw     x6, w6
09ec: add      w4, w6, w5
09f0: sxtw     x4, w4
09f4: add      w6, w4, w5
09f8: sxtw     x6, w6
09fc: add      w4, w6, w5
0a00: sxtw     x4, w4
0a04: add      w6, w4, w5
0a08: sxtw     x6, w6
0a0c: add      w4, w6, w5
0a10: sxtw     x4, w4
0a14: add      w6, w4, w5
0a18: sxtw     x6, w6
0a1c: add      w4, w6, w5
0a20: sxtw     x4, w4
0a24: add      w6, w4, w5
0a28: sxtw     x6, w6
0a2c: add      w4, w6, w5
0a30: sxtw     x4, w4
0a34: add      w6, w4, w5
0a38: sxtw     x6, w6
0a3c: add      w4, w6, w5
0a40: sxtw     x4, w4
0a44: add      w6, w4, w5
0a48: sxtw     x6, w6
0a4c: add      w4, w6, w5
0a50: sxtw     x4, w4
0a54: add      w6, w4, w5
0a58: sxtw     x6, w6
0a5c: add      w4, w6, w5
0a60: sxtw     x4, w4
0a64: add      w6, w4, w5
0a68: sxtw     x6, w6
0a6c: add      w4, w6, w5
0a70: sxtw     x4, w4
0a74: add      w6, w4, w5
0a78: sxtw     x6, w6
0a7c: add      w4, w6, w5
0a80: sxtw     x4, w4
0a84: add      w6, w4, w5
0a88: sxtw     x6, w6
0a8c: add      w4, w6, w5
0a90: sxtw     x4, w4
0a94: add      w6, w4, w5
0a98: sxtw     x6, w6
0a9c: add      w4, w6, w5
0aa0: sxtw     x4, w4
0aa4: add      w6, w4, w5
0aa8: sxtw     x6, w6
0aac: add      w4, w6, w5
0ab0: sxtw     x4, w4
0ab4: add      w6, w4, w5
0ab8: sxtw     x6, w6
0abc: add      w4, w6, w5
0ac0: sxtw     x4, w4
0ac4: add      w6, w4, w5
0ac8: sxtw     x6, w6
0acc: add      w4, w6, w5
0ad0: sxtw     x4, w4
0ad4: add      w6, w4, w5
0ad8: sxtw     x6, w6
0adc: add      w4, w6, w5
0ae0: sxtw     x4, w4
0ae4: add      w6, w4, w5
0ae8: sxtw     x6, w6
0aec: add      w4, w6, w5
0af0: sxtw     x4, w4
0af4: add      w6, w4, w5
0af8: sxtw     x6, w6
0afc: add      w4, w6, w5
0b00: sxtw     x4, w4
0b04: add      w6, w4, w5
0b08: sxtw     x6, w6
0b0c: add      w4, w6, w5
0b10: sxtw     x4, w4
0b14: add      w6, w4, w5
0b18: sxtw     x6, w6
0b1c: add      w4, w6, w5
0b20: sxtw     x4, w4
0b24: add      w6, w4, w5
0b28: sxtw     x6, w6
0b2c: add      w4, w6, w5
0b30: sxtw     x4, w4
0b34: add      w6, w4, w5
0b38: sxtw     x6, w6
0b3c: add      w4, w6, w5
0b40: sxtw     x4, w4
0b44: add      w6, w4, w5
0b48: sxtw     x6, w6
0b4c: add      w4, w6, w5
0b50: sxtw     x4, w4
0b54: add      w6, w4, w5
0b58: sxtw     x6, w6
0b5c: add      w4, w6, w5
0b60: sxtw     x4, w4
0b64: add      w6, w4, w5
0b68: sxtw     x6, w6
0b6c: add      w4, w6, w5
0b70: sxtw     x4, w4
0b74: add      w6, w4, w5
0b78: sxtw     x6, w6
0b7c: add      w4, w6, w5
0b80: sxtw     x4, w4
0b84: add      w6, w4, w5
0b88: sxtw     x6, w6
0b8c: add      w4, w6, w5
0b90: sxtw     x4, w4
0b94: add      w6, w4, w5
0b98: sxtw     x6, w6
0b9c: add      w4, w6, w5
0ba0: sxtw     x4, w4
0ba4: add      w6, w4, w5
0ba8: sxtw     x6, w6
0bac: add      w4, w6, w5
0bb0: sxtw     x4, w4
0bb4: add      w6, w4, w5
0bb8: sxtw     x6, w6
0bbc: add      w4, w6, w5
0bc0: sxtw     x4, w4
0bc4: add      w6, w4, w5
0bc8: sxtw     x6, w6
0bcc: add      w4, w6, w5
0bd0: sxtw     x4, w4
0bd4: add      w6, w4, w5
0bd8: sxtw     x6, w6
0bdc: add      w4, w6, w5
0be0: sxtw     x4, w4
0be4: add      w6, w4, w5
0be8: sxtw     x6, w6
0bec: add      w4, w6, w5
0bf0: sxtw     x4, w4
0bf4: add      w6, w4, w5
0bf8: sxtw     x6, w6
0bfc: add      w4, w6, w5
0c00: sxtw     x4, w4
0c04: add      w6, w4, w5
0c08: sxtw     x6, w6
0c0c: add      w4, w6, w5
0c10: sxtw     x4, w4
0c14: add      w6, w4, w5
0c18: sxtw     x6, w6
0c1c: add      w4, w6, w5
0c20: sxtw     x4, w4
0c24: add      w6, w4, w5
0c28: sxtw     x6, w6
0c2c: add      w4, w6, w5
0c30: sxtw     x4, w4
0c34: add      w6, w4, w5
0c38: sxtw     x6, w6
0c3c: add      w4, w6, w5
0c40: sxtw     x4, w4
0c44: add      w6, w4, w5
0c48: sxtw     x6, w6
0c4c: add      w4, w6, w5
0c50: sxtw     x4, w4
0c54: add      w6, w4, w5
0c58: sxtw     x6, w6
0c5c: add      w4, w6, w5
0c60: sxtw     x4, w4
0c64: add      w6, w4, w5
0c68: sxtw     x6, w6
0c6c: add      w4, w6, w5
0c70: sxtw     x4, w4
0c74: add      w6, w4, w5
0c78: sxtw     x6, w6
0c7c: add      w4, w6, w5
0c80: sxtw     x4, w4
0c84: add      w6, w4, w5
0c88: sxtw     x6, w6
0c8c: add      w4, w6, w5
0c90: sxtw     x4, w4
0c94: add      w6, w4, w5
0c98: sxtw     x6, w6
0c9c: add      w4, w6, w5
0ca0: sxtw     x4, w4
0ca4: add      w6, w4, w5
0ca8: sxtw     x6, w6
0cac: add      w4, w6, w5
0cb0: sxtw     x4, w4
0cb4: add      w6, w4, w5
0cb8: sxtw     x6, w6
0cbc: add      w4, w6, w5
0cc0: sxtw     x4, w4
0cc4: add      w6, w4, w5
0cc8: sxtw     x6, w6
0ccc: add      w4, w6, w5
0cd0: sxtw     x4, w4
0cd4: add      w6, w4, w5
0cd8: sxtw     x6, w6
0cdc: add      w4, w6, w5
0ce0: sxtw     x4, w4
0ce4: add      w6, w4, w5
0ce8: sxtw     x6, w6
0cec: add      w4, w6, w5
0cf0: sxtw     x4, w4
0cf4: add      w6, w4, w5
0cf8: sxtw     x6, w6
0cfc: add      w4, w6, w5
0d00: sxtw     x4, w4
0d04: add      w6, w4, w5
0d08: sxtw     x6, w6
0d0c: add      w4, w6, w5
0d10: sxtw     x4, w4
0d14: add      w6, w4, w5
0d18: sxtw     x6, w6
0d1c: add      w4, w6, w5
0d20: sxtw     x4, w4
0d24: add      w6, w4, w5
0d28: sxtw     x6, w6
0d2c: add      w4, w6, w5
0d30: sxtw     x4, w4
0d34: add      w6, w4, w5
0d38: sxtw     x6, w6
0d3c: add      w4, w6, w5
0d40: sxtw     x4, w4
0d44: add      w6, w4, w5
0d48: sxtw     x6, w6
0d4c: add      w4, w6, w5
0d50: sxtw     x4, w4
0d54: add      w6, w4, w5
0d58: sxtw     x6, w6
0d5c: add      w4, w6, w5
0d60: sxtw     x4, w4
0d64: add      w6, w4, w5
0d68: sxtw     x6, w6
0d6c: add      w4, w6, w5
0d70: sxtw     x4, w4
0d74: add      w6, w4, w5
0d78: sxtw     x6, w6
0d7c: add      w4, w6, w5
0d80: sxtw     x4, w4
0d84: add      w6, w4, w5
0d88: sxtw     x6, w6
0d8c: add      w4, w6, w5
0d90: sxtw     x4, w4
0d94: add      w6, w4, w5
0d98: sxtw     x6, w6
0d9c: add      w4, w6, w5
0da0: sxtw     x4, w4
0da4: add      w6, w4, w5
0da8: sxtw     x6, w6
0dac: add      w4, w6, w5
0db0: sxtw     x4, w4
0db4: add      w6, w4, w5
0db8: sxtw     x6, w6
0dbc: add      w4, w6, w5
0dc0: sxtw     x4, w4
0dc4: add      w6, w4, w5
0dc8: sxtw     x6, w6
0dcc: add      w4, w6, w5
0dd0: sxtw     x4, w4
0dd4: add      w6, w4, w5
0dd8: sxtw     x6, w6
0ddc: add      w4, w6, w5
0de0: sxtw     x4, w4
0de4: add      w6, w4, w5
0de8: sxtw     x6, w6
0dec: add      w4, w6, w5
0df0: sxtw     x4, w4
0df4: add      w6, w4, w5
0df8: sxtw     x6, w6
0dfc: add      w4, w6, w5
0e00: sxtw     x4, w4
0e04: add      w6, w4, w5
0e08: sxtw     x6, w6
0e0c: add      w4, w6, w5
0e10: sxtw     x4, w4
0e14: add      w6, w4, w5
0e18: sxtw     x6, w6
0e1c: add      w4, w6, w5
0e20: sxtw     x4, w4
0e24: add      w6, w4, w5
0e28: sxtw     x6, w6
0e2c: add      w4, w6, w5
0e30: sxtw     x4, w4
0e34: add      w6, w4, w5
0e38: sxtw     x6, w6
0e3c: add      w4, w6, w5
0e40: sxtw     x4, w4
0e44: add      w6, w4, w5
0e48: sxtw     x6, w6
0e4c: add      w4, w6, w5
0e50: sxtw     x4, w4
0e54: add      w6, w4, w5
0e58: sxtw     x6, w6
0e5c: add      w4, w6, w5
0e60: sxtw     x4, w4
0e64: add      w6, w4, w5
0e68: sxtw     x6, w6
0e6c: add      w4, w6, w5
0e70: sxtw     x4, w4
0e74: add      w6, w4, w5
0e78: sxtw     x6, w6
0e7c: add      w4, w6, w5
0e80: sxtw     x4, w4
0e84: add      w6, w4, w5
0e88: sxtw     x6, w6
0e8c: add      w4, w6, w5
0e90: sxtw     x4, w4
0e94: add      w6, w4, w5
0e98: sxtw     x6, w6
0e9c: add      w4, w6, w5
0ea0: sxtw     x4, w4
0ea4: add      w6, w4, w5
0ea8: sxtw     x6, w6
0eac: add      w4, w6, w5
0eb0: sxtw     x4, w4
0eb4: add      w6, w4, w5
0eb8: sxtw     x6, w6
0ebc: add      w4, w6, w5
0ec0: sxtw     x4, w4
0ec4: add      w6, w4, w5
0ec8: sxtw     x6, w6
0ecc: add      w4, w6, w5
0ed0: sxtw     x4, w4
0ed4: add      w6, w4, w5
0ed8: sxtw     x6, w6
0edc: add      w4, w6, w5
0ee0: sxtw     x4, w4
0ee4: add      w6, w4, w5
0ee8: sxtw     x6, w6
0eec: add      w4, w6, w5
0ef0: sxtw     x4, w4
0ef4: add      w6, w4, w5
0ef8: sxtw     x6, w6
0efc: add      w4, w6, w5
0f00: sxtw     x4, w4
0f04: add      w6, w4, w5
0f08: sxtw     x6, w6
0f0c: add      w4, w6, w5
0f10: sxtw     x4, w4
0f14: add      w6, w4, w5
0f18: sxtw     x6, w6
0f1c: add      w4, w6, w5
0f20: sxtw     x4, w4
0f24: add      w6, w4, w5
0f28: sxtw     x6, w6
0f2c: add      w4, w6, w5
0f30: sxtw     x4, w4
0f34: add      w6, w4, w5
0f38: sxtw     x6, w6
0f3c: add      w4, w6, w5
0f40: sxtw     x4, w4
0f44: add      w6, w4, w5
0f48: sxtw     x6, w6
0f4c: add      w4, w6, w5
0f50: sxtw     x4, w4
0f54: add      w6, w4, w5
0f58: sxtw     x6, w6
0f5c: add      w4, w6, w5
0f60: sxtw     x4, w4
0f64: add      w6, w4, w5
0f68: sxtw     x6, w6
0f6c: add      w4, w6, w5
0f70: sxtw     x4, w4
0f74: add      w6, w4, w5
0f78: sxtw     x6, w6
0f7c: add      w4, w6, w5
0f80: sxtw     x4, w4
0f84: add      w6, w4, w5
0f88: sxtw     x6, w6
0f8c: add      w4, w6, w5
0f90: sxtw     x4, w4
0f94: add      w6, w4, w5
0f98: sxtw     x6, w6
0f9c: add      w4, w6, w5
0fa0: sxtw     x4, w4
0fa4: add      w6, w4, w5
0fa8: sxtw     x6, w6
0fac: add      w4, w6, w5
0fb0: sxtw     x4, w4
0fb4: add      w6, w4, w5
0fb8: sxtw     x6, w6
0fbc: add      w4, w6, w5
0fc0: sxtw     x4, w4
0fc4: add      w6, w4, w5
0fc8: sxtw     x6, w6
0fcc: add      w4, w6, w5
0fd0: sxtw     x4, w4
0fd4: add      w6, w4, w5
0fd8: sxtw     x6, w6
0fdc: add      w4, w6, w5
0fe0: sxtw     x4, w4
0fe4: add      w6, w4, w5
0fe8: sxtw     x6, w6
0fec: add      w4, w6, w5
0ff0: sxtw     x4, w4
0ff4: add      w6, w4, w5
0ff8: sxtw     x6, w6
0ffc: add      w4, w6, w5
1000: sxtw     x4, w4
1004: mov      x0, x21
1008: lsr      x3, x0, #48
100c: mov      x10, #0xfff1
1010: cmp      x3, x10
1014: b.hi     0x10055ff78
1018: mov      x10, #0xfff1
101c: cmp      x3, x10
1020: b.ne     0x10055fee4
1024: lsl      x0, x0, #16
1028: asr      x0, x0, #16
102c: scvtf    d2, x0
1030: b        0x10055fee8
1034: fmov     d2, x0
1038: mov      x0, x4
103c: scvtf    d3, x0
1040: fadd     d4, d2, d3
1044: b        0x10055ff88
1048: b        0x10055f0a8
104c: mov      x7, x4
1050: mov      x21, x5
1054: b        0x10055f638
1058: mov      x0, #0x240
105c: movk     x0, #0x1159, lsl #16
1060: movk     x0, #0x75, lsl #32
1064: b        0x10055ff98
1068: mov      x0, #0x260
106c: movk     x0, #0x1159, lsl #16
1070: movk     x0, #0x75, lsl #32
1074: b        0x10055ff98
1078: mov      x0, #0x280
107c: movk     x0, #0x1159, lsl #16
1080: movk     x0, #0x75, lsl #32
1084: b        0x10055ff98
1088: mov      x0, #0x2a0
108c: movk     x0, #0x1159, lsl #16
1090: movk     x0, #0x75, lsl #32
1094: b        0x10055ff98
1098: mov      x0, #0x2c0
109c: movk     x0, #0x1159, lsl #16
10a0: movk     x0, #0x75, lsl #32
10a4: b        0x10055ff98
10a8: mov      x0, #0x2e0
10ac: movk     x0, #0x1159, lsl #16
10b0: movk     x0, #0x75, lsl #32
10b4: b        0x10055ff98
10b8: mov      x0, #0x300
10bc: movk     x0, #0x1159, lsl #16
10c0: movk     x0, #0x75, lsl #32
10c4: b        0x10055ff98
10c8: mov      x0, #0x320
10cc: movk     x0, #0x1159, lsl #16
10d0: movk     x0, #0x75, lsl #32
10d4: b        0x10055ff98
10d8: mov      x0, #0x340
10dc: movk     x0, #0x1159, lsl #16
10e0: movk     x0, #0x75, lsl #32
10e4: b        0x10055ff98
10e8: ldr      x1, [x19, #0x9a0]
10ec: ldr      x2, [x1, #0x70]
10f0: str      x7, [x2]
10f4: str      x21, [x2, #0x8]
10f8: str      x22, [x2, #0x10]
10fc: str      x4, [x2, #0x18]
1100: str      x5, [x2, #0x20]
1104: str      x6, [x2, #0x28]
1108: str      x23, [x2, #0x30]
110c: str      d2, [x2, #0x38]
1110: str      d3, [x2, #0x40]
1114: str      d4, [x2, #0x48]
1118: str      x20, [x19, #0x398]
111c: mov      x1, x0
1120: ldr      x0, [x19, #0x9a0]
1124: bl       0x100261148
1128: ldp      x29, x30, [sp]
112c: ldp      x19, x20, [sp, #0x30]
1130: ldp      x21, x22, [sp, #0x20]
1134: ldr      x23, [sp, #0x18]
1138: add      sp, sp, #0x40
113c: ret
