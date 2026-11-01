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
00b0: cbnz     x0, 0x10055df00
00b4: mov      x4, x7
00b8: mov      x5, x21
00bc: mov      x0, x22
00c0: lsr      x3, x0, #48
00c4: mov      x10, #0xfff1
00c8: cmp      x3, x10
00cc: b.eq     0x10055dee4
00d0: mov      x10, #0xfff1
00d4: cmp      x3, x10
00d8: b.hi     0x10055ed90
00dc: fmov     d0, x0
00e0: fcmp     d0, d0
00e4: b.vs     0x10055ed90
00e8: mov      x1, #-0x3e20000000000000
00ec: fmov     d1, x1
00f0: fcmp     d0, d1
00f4: b.mi     0x10055ed90
00f8: mov      x1, #0x41e0000000000000
00fc: fmov     d1, x1
0100: fcmp     d0, d1
0104: b.ge     0x10055ed90
0108: lsl      x3, x0, #1
010c: cbnz     x3, 0x10055dec8
0110: cmp      x0, #0x0
0114: b.lt     0x10055ed90
0118: fcvtzs   x6, d0
011c: scvtf    d1, x6
0120: fcmp     d0, d1
0124: cset     x9, ne
0128: ccmp     x9, #0x0, #0x4, vc
012c: b.ne     0x10055ed90
0130: b        0x10055defc
0134: sxtw     x3, w0
0138: lsl      x1, x0, #16
013c: asr      x1, x1, #16
0140: cmp      x1, x3
0144: b.ne     0x10055ed90
0148: mov      x6, x1
014c: b        0x10055ed80
0150: ldr      w0, [x19, #0x20c]
0154: cmp      x0, #0x3
0158: b.ne     0x10055dfa4
015c: mov      x0, x22
0160: lsr      x3, x0, #48
0164: mov      x10, #0xfff1
0168: cmp      x3, x10
016c: b.eq     0x10055df84
0170: mov      x10, #0xfff1
0174: cmp      x3, x10
0178: b.hi     0x10055ed90
017c: fmov     d0, x0
0180: fcmp     d0, d0
0184: b.vs     0x10055ed90
0188: mov      x1, #-0x3e20000000000000
018c: fmov     d1, x1
0190: fcmp     d0, d1
0194: b.mi     0x10055ed90
0198: mov      x1, #0x41e0000000000000
019c: fmov     d1, x1
01a0: fcmp     d0, d1
01a4: b.ge     0x10055ed90
01a8: lsl      x3, x0, #1
01ac: cbnz     x3, 0x10055df68
01b0: cmp      x0, #0x0
01b4: b.lt     0x10055ed90
01b8: fcvtzs   x4, d0
01bc: scvtf    d1, x4
01c0: fcmp     d0, d1
01c4: cset     x9, ne
01c8: ccmp     x9, #0x0, #0x4, vc
01cc: b.ne     0x10055ed90
01d0: b        0x10055df9c
01d4: sxtw     x3, w0
01d8: lsl      x1, x0, #16
01dc: asr      x1, x1, #16
01e0: cmp      x1, x3
01e4: b.ne     0x10055ed90
01e8: mov      x4, x1
01ec: mov      x5, x6
01f0: b        0x10055ed84
01f4: b        0x10055ed90
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
02b0: mov      x1, #0x540
02b4: movk     x1, #0x114f, lsl #16
02b8: movk     x1, #0x75, lsl #32
02bc: bl       0x10026b934
02c0: cbz      x0, 0x10055e090
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
0330: b.ne     0x10055eda0
0334: and      x0, x0, #0xffffffffffff
0338: cbz      x0, 0x10055eda0
033c: ldr      w1, [x0]
0340: mov      x10, #0x8600
0344: movk     x10, #0x3f, lsl #16
0348: and      x1, x1, x10
034c: mov      x10, #0x200
0350: movk     x10, #0x3, lsl #16
0354: cmp      x1, x10
0358: b.ne     0x10055eda0
035c: ldr      x1, [x0, #0x38]
0360: mov      x10, #0x5c00
0364: movk     x10, #0x10c7, lsl #16
0368: movk     x10, #0x75, lsl #32
036c: cmp      x1, x10
0370: b.ne     0x10055eda0
0374: ldr      x1, [x0, #0x88]
0378: cbnz     x1, 0x10055eda0
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
0454: mov      x1, #0x480
0458: movk     x1, #0x114f, lsl #16
045c: movk     x1, #0x75, lsl #32
0460: bl       0x10026b934
0464: cbz      x0, 0x10055e234
0468: ldr      w0, [x19, #0x20c]
046c: ldp      x29, x30, [sp]
0470: ldp      x19, x20, [sp, #0x30]
0474: ldp      x21, x22, [sp, #0x20]
0478: ldr      x23, [sp, #0x18]
047c: add      sp, sp, #0x40
0480: ret
0484: ldr      x3, [x19, #0x9a0]
0488: ldr      x3, [x3, #0x70]
048c: ldr      x0, [x3, #0x48]
0490: mov      x4, x0
0494: ldr      x3, [x19, #0x9a0]
0498: ldr      x3, [x3, #0x70]
049c: ldr      x0, [x3, #0x50]
04a0: mov      x5, x0
04a4: ldr      x3, [x19, #0x9a0]
04a8: ldr      x3, [x3, #0x70]
04ac: ldr      x0, [x3, #0x58]
04b0: mov      x6, x0
04b4: ldr      x3, [x19, #0x9a0]
04b8: ldr      x3, [x3, #0x70]
04bc: ldr      x0, [x3, #0x80]
04c0: mov      x7, x0
04c4: mov      x22, #-0xd000000000000
04c8: mov      x0, x4
04cc: lsr      x3, x0, #48
04d0: mov      x10, #0xfff9
04d4: cmp      x3, x10
04d8: b.ne     0x10055edb0
04dc: and      x0, x0, #0xffffffffffff
04e0: cbz      x0, 0x10055edb0
04e4: ldr      w3, [x0]
04e8: mov      x10, #0xf000
04ec: movk     x10, #0x503f, lsl #16
04f0: and      x3, x3, x10
04f4: cmp      x3, #0x10, lsl #12
04f8: b.ne     0x10055edb0
04fc: ldr      w3, [x0, #0x10]
0500: cmp      x3, #0x17
0504: b.ne     0x10055edb0
0508: mov      x2, #0xc6a0
050c: movk     x2, #0x10c0, lsl #16
0510: movk     x2, #0x75, lsl #32
0514: ldr      x2, [x2]
0518: ldr      x2, [x2, #0xb8]
051c: cbz      x2, 0x10055edb0
0520: ldr      w3, [x2]
0524: cmp      x3, #0x6a
0528: b.ne     0x10055edb0
052c: ldr      x2, [x0, #0x28]
0530: cbnz     x2, 0x10055e2e8
0534: add      x2, x0, #0x38
0538: add      x2, x2, #0x0
053c: mov      x21, x2
0540: mov      x2, x21
0544: ldr      x0, [x2]
0548: lsr      x3, x0, #48
054c: mov      x10, #0xfff1
0550: cmp      x3, x10
0554: b.hi     0x10055edb0
0558: mov      x23, x0
055c: mov      x0, x23
0560: lsr      x3, x0, #48
0564: mov      x10, #0xfff1
0568: cmp      x3, x10
056c: b.hi     0x10055edc0
0570: mov      x10, #0xfff1
0574: cmp      x3, x10
0578: b.ne     0x10055e33c
057c: lsl      x0, x0, #16
0580: asr      x0, x0, #16
0584: scvtf    d2, x0
0588: b        0x10055e340
058c: fmov     d2, x0
0590: orr      x0, xzr, #0x3ff0000000000000
0594: fmov     d3, x0
0598: fadd     d4, d2, d3
059c: mov      x0, x4
05a0: lsr      x3, x0, #48
05a4: mov      x10, #0xfff9
05a8: cmp      x3, x10
05ac: b.ne     0x10055edd0
05b0: and      x0, x0, #0xffffffffffff
05b4: cbz      x0, 0x10055edd0
05b8: ldr      w3, [x0]
05bc: mov      x10, #0xf000
05c0: movk     x10, #0x503f, lsl #16
05c4: and      x3, x3, x10
05c8: cmp      x3, #0x10, lsl #12
05cc: b.ne     0x10055edd0
05d0: ldr      w3, [x0, #0x4]
05d4: mov      x10, #0x20
05d8: movk     x10, #0x1, lsl #16
05dc: and      x3, x3, x10
05e0: cbnz     x3, 0x10055edd0
05e4: ldr      w3, [x0, #0x10]
05e8: cmp      x3, #0x17
05ec: b.ne     0x10055edd0
05f0: mov      x2, #0xc6a0
05f4: movk     x2, #0x10c0, lsl #16
05f8: movk     x2, #0x75, lsl #32
05fc: ldr      x2, [x2]
0600: ldr      x2, [x2, #0xb8]
0604: cbz      x2, 0x10055edd0
0608: ldr      w3, [x2]
060c: cmp      x3, #0x6a
0610: b.ne     0x10055edd0
0614: ldr      x2, [x0, #0x28]
0618: cbnz     x2, 0x10055e3d0
061c: add      x2, x0, #0x38
0620: add      x2, x2, #0x0
0624: mov      x21, x2
0628: fmov     x23, d4
062c: lsr      x3, x23, #48
0630: mov      x10, #0xfff1
0634: cmp      x3, x10
0638: b.lo     0x10055e3f0
063c: orr      x23, xzr, #0x7ff8000000000000
0640: mov      x2, x21
0644: mov      x0, x23
0648: lsr      x3, x0, #48
064c: mov      x10, #0xfff1
0650: cmp      x3, x10
0654: b.hi     0x10055edd0
0658: ldr      x3, [x2]
065c: lsr      x3, x3, #48
0660: mov      x10, #0xfff1
0664: cmp      x3, x10
0668: b.hi     0x10055edd0
066c: str      x0, [x2]
0670: mov      x0, x4
0674: lsr      x3, x0, #48
0678: mov      x10, #0xfff9
067c: cmp      x3, x10
0680: b.ne     0x10055ede0
0684: and      x0, x0, #0xffffffffffff
0688: cbz      x0, 0x10055ede0
068c: ldr      w3, [x0]
0690: mov      x10, #0xf000
0694: movk     x10, #0x503f, lsl #16
0698: and      x3, x3, x10
069c: cmp      x3, #0x10, lsl #12
06a0: b.ne     0x10055ede0
06a4: ldr      w3, [x0, #0x10]
06a8: cmp      x3, #0x17
06ac: b.ne     0x10055ede0
06b0: mov      x2, #0xc6a0
06b4: movk     x2, #0x10c0, lsl #16
06b8: movk     x2, #0x75, lsl #32
06bc: ldr      x2, [x2]
06c0: ldr      x2, [x2, #0xb8]
06c4: cbz      x2, 0x10055ede0
06c8: ldr      w3, [x2]
06cc: cmp      x3, #0x6a
06d0: b.ne     0x10055ede0
06d4: ldr      x2, [x0, #0x28]
06d8: cbnz     x2, 0x10055e490
06dc: add      x2, x0, #0x38
06e0: add      x2, x2, #0x0
06e4: mov      x21, x2
06e8: mov      x2, x21
06ec: ldr      x0, [x2]
06f0: lsr      x3, x0, #48
06f4: mov      x10, #0xfff1
06f8: cmp      x3, x10
06fc: b.hi     0x10055ede0
0700: mov      x23, x0
0704: b        0x10055edf0
0708: mov      x7, x6
070c: mov      x21, x22
0710: mov      x4, #0x0
0714: and      x5, x7, #0x1
0718: sxtw     x5, w5
071c: add      w6, w4, w5
0720: sxtw     x6, w6
0724: add      w4, w6, w5
0728: sxtw     x4, w4
072c: add      w6, w4, w5
0730: sxtw     x6, w6
0734: add      w4, w6, w5
0738: sxtw     x4, w4
073c: add      w6, w4, w5
0740: sxtw     x6, w6
0744: add      w4, w6, w5
0748: sxtw     x4, w4
074c: add      w6, w4, w5
0750: sxtw     x6, w6
0754: add      w4, w6, w5
0758: sxtw     x4, w4
075c: add      w6, w4, w5
0760: sxtw     x6, w6
0764: add      w4, w6, w5
0768: sxtw     x4, w4
076c: add      w6, w4, w5
0770: sxtw     x6, w6
0774: add      w4, w6, w5
0778: sxtw     x4, w4
077c: add      w6, w4, w5
0780: sxtw     x6, w6
0784: add      w4, w6, w5
0788: sxtw     x4, w4
078c: add      w6, w4, w5
0790: sxtw     x6, w6
0794: add      w4, w6, w5
0798: sxtw     x4, w4
079c: add      w6, w4, w5
07a0: sxtw     x6, w6
07a4: add      w4, w6, w5
07a8: sxtw     x4, w4
07ac: add      w6, w4, w5
07b0: sxtw     x6, w6
07b4: add      w4, w6, w5
07b8: sxtw     x4, w4
07bc: add      w6, w4, w5
07c0: sxtw     x6, w6
07c4: add      w4, w6, w5
07c8: sxtw     x4, w4
07cc: add      w6, w4, w5
07d0: sxtw     x6, w6
07d4: add      w4, w6, w5
07d8: sxtw     x4, w4
07dc: add      w6, w4, w5
07e0: sxtw     x6, w6
07e4: add      w4, w6, w5
07e8: sxtw     x4, w4
07ec: add      w6, w4, w5
07f0: sxtw     x6, w6
07f4: add      w4, w6, w5
07f8: sxtw     x4, w4
07fc: add      w6, w4, w5
0800: sxtw     x6, w6
0804: add      w4, w6, w5
0808: sxtw     x4, w4
080c: add      w6, w4, w5
0810: sxtw     x6, w6
0814: add      w4, w6, w5
0818: sxtw     x4, w4
081c: add      w6, w4, w5
0820: sxtw     x6, w6
0824: add      w4, w6, w5
0828: sxtw     x4, w4
082c: add      w6, w4, w5
0830: sxtw     x6, w6
0834: add      w4, w6, w5
0838: sxtw     x4, w4
083c: add      w6, w4, w5
0840: sxtw     x6, w6
0844: add      w4, w6, w5
0848: sxtw     x4, w4
084c: add      w6, w4, w5
0850: sxtw     x6, w6
0854: add      w4, w6, w5
0858: sxtw     x4, w4
085c: add      w6, w4, w5
0860: sxtw     x6, w6
0864: add      w4, w6, w5
0868: sxtw     x4, w4
086c: add      w6, w4, w5
0870: sxtw     x6, w6
0874: add      w4, w6, w5
0878: sxtw     x4, w4
087c: add      w6, w4, w5
0880: sxtw     x6, w6
0884: add      w4, w6, w5
0888: sxtw     x4, w4
088c: add      w6, w4, w5
0890: sxtw     x6, w6
0894: add      w4, w6, w5
0898: sxtw     x4, w4
089c: add      w6, w4, w5
08a0: sxtw     x6, w6
08a4: add      w4, w6, w5
08a8: sxtw     x4, w4
08ac: add      w6, w4, w5
08b0: sxtw     x6, w6
08b4: add      w4, w6, w5
08b8: sxtw     x4, w4
08bc: add      w6, w4, w5
08c0: sxtw     x6, w6
08c4: add      w4, w6, w5
08c8: sxtw     x4, w4
08cc: add      w6, w4, w5
08d0: sxtw     x6, w6
08d4: add      w4, w6, w5
08d8: sxtw     x4, w4
08dc: add      w6, w4, w5
08e0: sxtw     x6, w6
08e4: add      w4, w6, w5
08e8: sxtw     x4, w4
08ec: add      w6, w4, w5
08f0: sxtw     x6, w6
08f4: add      w4, w6, w5
08f8: sxtw     x4, w4
08fc: add      w6, w4, w5
0900: sxtw     x6, w6
0904: add      w4, w6, w5
0908: sxtw     x4, w4
090c: add      w6, w4, w5
0910: sxtw     x6, w6
0914: add      w4, w6, w5
0918: sxtw     x4, w4
091c: add      w6, w4, w5
0920: sxtw     x6, w6
0924: add      w4, w6, w5
0928: sxtw     x4, w4
092c: add      w6, w4, w5
0930: sxtw     x6, w6
0934: add      w4, w6, w5
0938: sxtw     x4, w4
093c: add      w6, w4, w5
0940: sxtw     x6, w6
0944: add      w4, w6, w5
0948: sxtw     x4, w4
094c: add      w6, w4, w5
0950: sxtw     x6, w6
0954: add      w4, w6, w5
0958: sxtw     x4, w4
095c: add      w6, w4, w5
0960: sxtw     x6, w6
0964: add      w4, w6, w5
0968: sxtw     x4, w4
096c: add      w6, w4, w5
0970: sxtw     x6, w6
0974: add      w4, w6, w5
0978: sxtw     x4, w4
097c: add      w6, w4, w5
0980: sxtw     x6, w6
0984: add      w4, w6, w5
0988: sxtw     x4, w4
098c: add      w6, w4, w5
0990: sxtw     x6, w6
0994: add      w4, w6, w5
0998: sxtw     x4, w4
099c: add      w6, w4, w5
09a0: sxtw     x6, w6
09a4: add      w4, w6, w5
09a8: sxtw     x4, w4
09ac: add      w6, w4, w5
09b0: sxtw     x6, w6
09b4: add      w4, w6, w5
09b8: sxtw     x4, w4
09bc: add      w6, w4, w5
09c0: sxtw     x6, w6
09c4: add      w4, w6, w5
09c8: sxtw     x4, w4
09cc: add      w6, w4, w5
09d0: sxtw     x6, w6
09d4: add      w4, w6, w5
09d8: sxtw     x4, w4
09dc: add      w6, w4, w5
09e0: sxtw     x6, w6
09e4: add      w4, w6, w5
09e8: sxtw     x4, w4
09ec: add      w6, w4, w5
09f0: sxtw     x6, w6
09f4: add      w4, w6, w5
09f8: sxtw     x4, w4
09fc: add      w6, w4, w5
0a00: sxtw     x6, w6
0a04: add      w4, w6, w5
0a08: sxtw     x4, w4
0a0c: add      w6, w4, w5
0a10: sxtw     x6, w6
0a14: add      w4, w6, w5
0a18: sxtw     x4, w4
0a1c: add      w6, w4, w5
0a20: sxtw     x6, w6
0a24: add      w4, w6, w5
0a28: sxtw     x4, w4
0a2c: add      w6, w4, w5
0a30: sxtw     x6, w6
0a34: add      w4, w6, w5
0a38: sxtw     x4, w4
0a3c: add      w6, w4, w5
0a40: sxtw     x6, w6
0a44: add      w4, w6, w5
0a48: sxtw     x4, w4
0a4c: add      w6, w4, w5
0a50: sxtw     x6, w6
0a54: add      w4, w6, w5
0a58: sxtw     x4, w4
0a5c: add      w6, w4, w5
0a60: sxtw     x6, w6
0a64: add      w4, w6, w5
0a68: sxtw     x4, w4
0a6c: add      w6, w4, w5
0a70: sxtw     x6, w6
0a74: add      w4, w6, w5
0a78: sxtw     x4, w4
0a7c: add      w6, w4, w5
0a80: sxtw     x6, w6
0a84: add      w4, w6, w5
0a88: sxtw     x4, w4
0a8c: add      w6, w4, w5
0a90: sxtw     x6, w6
0a94: add      w4, w6, w5
0a98: sxtw     x4, w4
0a9c: add      w6, w4, w5
0aa0: sxtw     x6, w6
0aa4: add      w4, w6, w5
0aa8: sxtw     x4, w4
0aac: add      w6, w4, w5
0ab0: sxtw     x6, w6
0ab4: add      w4, w6, w5
0ab8: sxtw     x4, w4
0abc: add      w6, w4, w5
0ac0: sxtw     x6, w6
0ac4: add      w4, w6, w5
0ac8: sxtw     x4, w4
0acc: add      w6, w4, w5
0ad0: sxtw     x6, w6
0ad4: add      w4, w6, w5
0ad8: sxtw     x4, w4
0adc: add      w6, w4, w5
0ae0: sxtw     x6, w6
0ae4: add      w4, w6, w5
0ae8: sxtw     x4, w4
0aec: add      w6, w4, w5
0af0: sxtw     x6, w6
0af4: add      w4, w6, w5
0af8: sxtw     x4, w4
0afc: add      w6, w4, w5
0b00: sxtw     x6, w6
0b04: add      w4, w6, w5
0b08: sxtw     x4, w4
0b0c: add      w6, w4, w5
0b10: sxtw     x6, w6
0b14: add      w4, w6, w5
0b18: sxtw     x4, w4
0b1c: add      w6, w4, w5
0b20: sxtw     x6, w6
0b24: add      w4, w6, w5
0b28: sxtw     x4, w4
0b2c: add      w6, w4, w5
0b30: sxtw     x6, w6
0b34: add      w4, w6, w5
0b38: sxtw     x4, w4
0b3c: add      w6, w4, w5
0b40: sxtw     x6, w6
0b44: add      w4, w6, w5
0b48: sxtw     x4, w4
0b4c: add      w6, w4, w5
0b50: sxtw     x6, w6
0b54: add      w4, w6, w5
0b58: sxtw     x4, w4
0b5c: add      w6, w4, w5
0b60: sxtw     x6, w6
0b64: add      w4, w6, w5
0b68: sxtw     x4, w4
0b6c: add      w6, w4, w5
0b70: sxtw     x6, w6
0b74: add      w4, w6, w5
0b78: sxtw     x4, w4
0b7c: add      w6, w4, w5
0b80: sxtw     x6, w6
0b84: add      w4, w6, w5
0b88: sxtw     x4, w4
0b8c: add      w6, w4, w5
0b90: sxtw     x6, w6
0b94: add      w4, w6, w5
0b98: sxtw     x4, w4
0b9c: add      w6, w4, w5
0ba0: sxtw     x6, w6
0ba4: add      w4, w6, w5
0ba8: sxtw     x4, w4
0bac: add      w6, w4, w5
0bb0: sxtw     x6, w6
0bb4: add      w4, w6, w5
0bb8: sxtw     x4, w4
0bbc: add      w6, w4, w5
0bc0: sxtw     x6, w6
0bc4: add      w4, w6, w5
0bc8: sxtw     x4, w4
0bcc: add      w6, w4, w5
0bd0: sxtw     x6, w6
0bd4: add      w4, w6, w5
0bd8: sxtw     x4, w4
0bdc: add      w6, w4, w5
0be0: sxtw     x6, w6
0be4: add      w4, w6, w5
0be8: sxtw     x4, w4
0bec: add      w6, w4, w5
0bf0: sxtw     x6, w6
0bf4: add      w4, w6, w5
0bf8: sxtw     x4, w4
0bfc: add      w6, w4, w5
0c00: sxtw     x6, w6
0c04: add      w4, w6, w5
0c08: sxtw     x4, w4
0c0c: add      w6, w4, w5
0c10: sxtw     x6, w6
0c14: add      w4, w6, w5
0c18: sxtw     x4, w4
0c1c: add      w6, w4, w5
0c20: sxtw     x6, w6
0c24: add      w4, w6, w5
0c28: sxtw     x4, w4
0c2c: add      w6, w4, w5
0c30: sxtw     x6, w6
0c34: add      w4, w6, w5
0c38: sxtw     x4, w4
0c3c: add      w6, w4, w5
0c40: sxtw     x6, w6
0c44: add      w4, w6, w5
0c48: sxtw     x4, w4
0c4c: add      w6, w4, w5
0c50: sxtw     x6, w6
0c54: add      w4, w6, w5
0c58: sxtw     x4, w4
0c5c: add      w6, w4, w5
0c60: sxtw     x6, w6
0c64: add      w4, w6, w5
0c68: sxtw     x4, w4
0c6c: add      w6, w4, w5
0c70: sxtw     x6, w6
0c74: add      w4, w6, w5
0c78: sxtw     x4, w4
0c7c: add      w6, w4, w5
0c80: sxtw     x6, w6
0c84: add      w4, w6, w5
0c88: sxtw     x4, w4
0c8c: add      w6, w4, w5
0c90: sxtw     x6, w6
0c94: add      w4, w6, w5
0c98: sxtw     x4, w4
0c9c: add      w6, w4, w5
0ca0: sxtw     x6, w6
0ca4: add      w4, w6, w5
0ca8: sxtw     x4, w4
0cac: add      w6, w4, w5
0cb0: sxtw     x6, w6
0cb4: add      w4, w6, w5
0cb8: sxtw     x4, w4
0cbc: add      w6, w4, w5
0cc0: sxtw     x6, w6
0cc4: add      w4, w6, w5
0cc8: sxtw     x4, w4
0ccc: add      w6, w4, w5
0cd0: sxtw     x6, w6
0cd4: add      w4, w6, w5
0cd8: sxtw     x4, w4
0cdc: add      w6, w4, w5
0ce0: sxtw     x6, w6
0ce4: add      w4, w6, w5
0ce8: sxtw     x4, w4
0cec: add      w6, w4, w5
0cf0: sxtw     x6, w6
0cf4: add      w4, w6, w5
0cf8: sxtw     x4, w4
0cfc: add      w6, w4, w5
0d00: sxtw     x6, w6
0d04: add      w4, w6, w5
0d08: sxtw     x4, w4
0d0c: add      w6, w4, w5
0d10: sxtw     x6, w6
0d14: add      w4, w6, w5
0d18: sxtw     x4, w4
0d1c: add      w6, w4, w5
0d20: sxtw     x6, w6
0d24: add      w4, w6, w5
0d28: sxtw     x4, w4
0d2c: add      w6, w4, w5
0d30: sxtw     x6, w6
0d34: add      w4, w6, w5
0d38: sxtw     x4, w4
0d3c: add      w6, w4, w5
0d40: sxtw     x6, w6
0d44: add      w4, w6, w5
0d48: sxtw     x4, w4
0d4c: add      w6, w4, w5
0d50: sxtw     x6, w6
0d54: add      w4, w6, w5
0d58: sxtw     x4, w4
0d5c: add      w6, w4, w5
0d60: sxtw     x6, w6
0d64: add      w4, w6, w5
0d68: sxtw     x4, w4
0d6c: add      w6, w4, w5
0d70: sxtw     x6, w6
0d74: add      w4, w6, w5
0d78: sxtw     x4, w4
0d7c: add      w6, w4, w5
0d80: sxtw     x6, w6
0d84: add      w4, w6, w5
0d88: sxtw     x4, w4
0d8c: add      w6, w4, w5
0d90: sxtw     x6, w6
0d94: add      w4, w6, w5
0d98: sxtw     x4, w4
0d9c: add      w6, w4, w5
0da0: sxtw     x6, w6
0da4: add      w4, w6, w5
0da8: sxtw     x4, w4
0dac: add      w6, w4, w5
0db0: sxtw     x6, w6
0db4: add      w4, w6, w5
0db8: sxtw     x4, w4
0dbc: add      w6, w4, w5
0dc0: sxtw     x6, w6
0dc4: add      w4, w6, w5
0dc8: sxtw     x4, w4
0dcc: add      w6, w4, w5
0dd0: sxtw     x6, w6
0dd4: add      w4, w6, w5
0dd8: sxtw     x4, w4
0ddc: add      w6, w4, w5
0de0: sxtw     x6, w6
0de4: add      w4, w6, w5
0de8: sxtw     x4, w4
0dec: add      w6, w4, w5
0df0: sxtw     x6, w6
0df4: add      w4, w6, w5
0df8: sxtw     x4, w4
0dfc: add      w6, w4, w5
0e00: sxtw     x6, w6
0e04: add      w4, w6, w5
0e08: sxtw     x4, w4
0e0c: add      w6, w4, w5
0e10: sxtw     x6, w6
0e14: add      w4, w6, w5
0e18: sxtw     x4, w4
0e1c: add      w6, w4, w5
0e20: sxtw     x6, w6
0e24: add      w4, w6, w5
0e28: sxtw     x4, w4
0e2c: add      w6, w4, w5
0e30: sxtw     x6, w6
0e34: add      w4, w6, w5
0e38: sxtw     x4, w4
0e3c: add      w6, w4, w5
0e40: sxtw     x6, w6
0e44: add      w4, w6, w5
0e48: sxtw     x4, w4
0e4c: add      w6, w4, w5
0e50: sxtw     x6, w6
0e54: add      w4, w6, w5
0e58: sxtw     x4, w4
0e5c: add      w6, w4, w5
0e60: sxtw     x6, w6
0e64: add      w4, w6, w5
0e68: sxtw     x4, w4
0e6c: add      w6, w4, w5
0e70: sxtw     x6, w6
0e74: add      w4, w6, w5
0e78: sxtw     x4, w4
0e7c: add      w6, w4, w5
0e80: sxtw     x6, w6
0e84: add      w4, w6, w5
0e88: sxtw     x4, w4
0e8c: add      w6, w4, w5
0e90: sxtw     x6, w6
0e94: add      w4, w6, w5
0e98: sxtw     x4, w4
0e9c: add      w6, w4, w5
0ea0: sxtw     x6, w6
0ea4: add      w4, w6, w5
0ea8: sxtw     x4, w4
0eac: add      w6, w4, w5
0eb0: sxtw     x6, w6
0eb4: add      w4, w6, w5
0eb8: sxtw     x4, w4
0ebc: add      w6, w4, w5
0ec0: sxtw     x6, w6
0ec4: add      w4, w6, w5
0ec8: sxtw     x4, w4
0ecc: add      w6, w4, w5
0ed0: sxtw     x6, w6
0ed4: add      w4, w6, w5
0ed8: sxtw     x4, w4
0edc: add      w6, w4, w5
0ee0: sxtw     x6, w6
0ee4: add      w4, w6, w5
0ee8: sxtw     x4, w4
0eec: add      w6, w4, w5
0ef0: sxtw     x6, w6
0ef4: add      w4, w6, w5
0ef8: sxtw     x4, w4
0efc: add      w6, w4, w5
0f00: sxtw     x6, w6
0f04: add      w4, w6, w5
0f08: sxtw     x4, w4
0f0c: add      w6, w4, w5
0f10: sxtw     x6, w6
0f14: add      w4, w6, w5
0f18: sxtw     x4, w4
0f1c: add      w6, w4, w5
0f20: sxtw     x6, w6
0f24: add      w4, w6, w5
0f28: sxtw     x4, w4
0f2c: add      w6, w4, w5
0f30: sxtw     x6, w6
0f34: add      w4, w6, w5
0f38: sxtw     x4, w4
0f3c: add      w6, w4, w5
0f40: sxtw     x6, w6
0f44: add      w4, w6, w5
0f48: sxtw     x4, w4
0f4c: add      w6, w4, w5
0f50: sxtw     x6, w6
0f54: add      w4, w6, w5
0f58: sxtw     x4, w4
0f5c: add      w6, w4, w5
0f60: sxtw     x6, w6
0f64: add      w4, w6, w5
0f68: sxtw     x4, w4
0f6c: add      w6, w4, w5
0f70: sxtw     x6, w6
0f74: add      w4, w6, w5
0f78: sxtw     x4, w4
0f7c: add      w6, w4, w5
0f80: sxtw     x6, w6
0f84: add      w4, w6, w5
0f88: sxtw     x4, w4
0f8c: mov      x0, x21
0f90: lsr      x3, x0, #48
0f94: mov      x10, #0xfff1
0f98: cmp      x3, x10
0f9c: b.hi     0x10055ee00
0fa0: mov      x10, #0xfff1
0fa4: cmp      x3, x10
0fa8: b.ne     0x10055ed6c
0fac: lsl      x0, x0, #16
0fb0: asr      x0, x0, #16
0fb4: scvtf    d2, x0
0fb8: b        0x10055ed70
0fbc: fmov     d2, x0
0fc0: mov      x0, x4
0fc4: scvtf    d3, x0
0fc8: fadd     d4, d2, d3
0fcc: b        0x10055ee10
0fd0: b        0x10055dfa8
0fd4: mov      x7, x4
0fd8: mov      x21, x5
0fdc: b        0x10055e4c0
0fe0: mov      x0, #0x640
0fe4: movk     x0, #0x1159, lsl #16
0fe8: movk     x0, #0x75, lsl #32
0fec: b        0x10055ee20
0ff0: mov      x0, #0x660
0ff4: movk     x0, #0x1159, lsl #16
0ff8: movk     x0, #0x75, lsl #32
0ffc: b        0x10055ee20
1000: mov      x0, #0x680
1004: movk     x0, #0x1159, lsl #16
1008: movk     x0, #0x75, lsl #32
100c: b        0x10055ee20
1010: mov      x0, #0x6a0
1014: movk     x0, #0x1159, lsl #16
1018: movk     x0, #0x75, lsl #32
101c: b        0x10055ee20
1020: mov      x0, #0x6c0
1024: movk     x0, #0x1159, lsl #16
1028: movk     x0, #0x75, lsl #32
102c: b        0x10055ee20
1030: mov      x0, #0x6e0
1034: movk     x0, #0x1159, lsl #16
1038: movk     x0, #0x75, lsl #32
103c: b        0x10055ee20
1040: mov      x0, #0x700
1044: movk     x0, #0x1159, lsl #16
1048: movk     x0, #0x75, lsl #32
104c: b        0x10055ee20
1050: mov      x0, #0x720
1054: movk     x0, #0x1159, lsl #16
1058: movk     x0, #0x75, lsl #32
105c: b        0x10055ee20
1060: mov      x0, #0x740
1064: movk     x0, #0x1159, lsl #16
1068: movk     x0, #0x75, lsl #32
106c: b        0x10055ee20
1070: ldr      x1, [x19, #0x9a0]
1074: ldr      x2, [x1, #0x70]
1078: str      x7, [x2]
107c: str      x21, [x2, #0x8]
1080: str      x22, [x2, #0x10]
1084: str      x4, [x2, #0x18]
1088: str      x5, [x2, #0x20]
108c: str      x6, [x2, #0x28]
1090: str      x23, [x2, #0x30]
1094: str      d2, [x2, #0x38]
1098: str      d3, [x2, #0x40]
109c: str      d4, [x2, #0x48]
10a0: str      x20, [x19, #0x398]
10a4: mov      x1, x0
10a8: ldr      x0, [x19, #0x9a0]
10ac: bl       0x100261148
10b0: ldp      x29, x30, [sp]
10b4: ldp      x19, x20, [sp, #0x30]
10b8: ldp      x21, x22, [sp, #0x20]
10bc: ldr      x23, [sp, #0x18]
10c0: add      sp, sp, #0x40
10c4: ret
