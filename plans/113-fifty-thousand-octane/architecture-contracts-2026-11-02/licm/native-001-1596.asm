0000: stp      x29, x30, [sp, #-0x50]!
0004: stp      x19, x20, [sp, #0x40]
0008: stp      x21, x22, [sp, #0x30]
000c: stp      x23, x24, [sp, #0x20]
0010: str      x25, [sp, #0x18]
0014: mov      x29, sp
0018: mov      x19, x0
001c: mov      x20, x1
0020: ldr      x0, [x19]
0024: ldr      x10, [x19, #0x210]
0028: cmp      x0, x10
002c: b.ne     0x1048bff00
0030: ldr      x24, [x19, #0x220]
0034: ldr      x25, [x19, #0x218]
0038: ldr      x0, [x19, #0x9a0]
003c: ldr      x0, [x0, #0x50]
0040: ldr      x0, [x0]
0044: mov      x7, x0
0048: ldr      x0, [x19, #0x9a0]
004c: ldr      x0, [x0, #0x50]
0050: ldr      x0, [x0, #0x8]
0054: mov      x21, x0
0058: ldr      x0, [x19, #0x9a0]
005c: ldr      x0, [x0, #0x50]
0060: ldr      x0, [x0, #0x10]
0064: mov      x22, x0
0068: ldr      x0, [x19, #0x9a0]
006c: ldr      x0, [x0, #0x50]
0070: ldr      x0, [x0, #0x18]
0074: mov      x23, x0
0078: ldr      x0, [x19, #0x9a0]
007c: ldr      x0, [x0, #0x50]
0080: ldr      x0, [x0, #0x20]
0084: str      x0, [x19, #0x9b8]
0088: ldr      x0, [x19, #0x9a0]
008c: ldr      x0, [x0, #0x50]
0090: ldr      x0, [x0, #0x28]
0094: str      x0, [x19, #0x9c0]
0098: ldr      x0, [x19, #0x9a0]
009c: ldr      x0, [x0, #0x50]
00a0: ldr      x0, [x0, #0x30]
00a4: mov      x4, x0
00a8: ldr      x0, [x19, #0x9a0]
00ac: ldr      x0, [x0, #0x50]
00b0: ldr      x0, [x0, #0x38]
00b4: mov      x5, x0
00b8: ldr      x0, [x19, #0x9a0]
00bc: ldr      x0, [x0, #0x50]
00c0: ldr      x0, [x0, #0x40]
00c4: mov      x6, x0
00c8: ldr      x0, [x19, #0x9a0]
00cc: ldr      x0, [x0, #0x50]
00d0: ldr      x0, [x0, #0x48]
00d4: str      x0, [x19, #0x9c8]
00d8: ldr      x0, [x19, #0x9a0]
00dc: ldr      x0, [x0, #0x50]
00e0: ldr      x0, [x0, #0x50]
00e4: str      x0, [x19, #0x9d0]
00e8: ldr      w0, [x19, #0x20c]
00ec: cbnz     x0, 0x1048bfbc8
00f0: mov      x0, x7
00f4: str      x0, [x19, #0x9e8]
00f8: mov      x0, x21
00fc: lsr      x3, x0, #48
0100: mov      x10, #0xfff1
0104: cmp      x3, x10
0108: b.eq     0x1048bfb18
010c: mov      x10, #0xfff1
0110: cmp      x3, x10
0114: b.hi     0x1048bff00
0118: fmov     d0, x0
011c: fcmp     d0, d0
0120: b.vs     0x1048bff00
0124: mov      x1, #-0x3e20000000000000
0128: fmov     d1, x1
012c: fcmp     d0, d1
0130: b.mi     0x1048bff00
0134: mov      x1, #0x41e0000000000000
0138: fmov     d1, x1
013c: fcmp     d0, d1
0140: b.ge     0x1048bff00
0144: lsl      x3, x0, #1
0148: cbnz     x3, 0x1048bfafc
014c: cmp      x0, #0x0
0150: b.lt     0x1048bff00
0154: fcvtzs   x0, d0
0158: scvtf    d1, x0
015c: fcmp     d0, d1
0160: cset     x9, ne
0164: ccmp     x9, #0x0, #0x4, vc
0168: b.ne     0x1048bff00
016c: b        0x1048bfb30
0170: sxtw     x3, w0
0174: lsl      x1, x0, #16
0178: asr      x1, x1, #16
017c: cmp      x1, x3
0180: b.ne     0x1048bff00
0184: mov      x0, x1
0188: str      x0, [x19, #0x9f0]
018c: mov      x0, x22
0190: lsr      x3, x0, #48
0194: mov      x10, #0xfff1
0198: cmp      x3, x10
019c: b.hi     0x1048bff00
01a0: mov      x10, #0xfff1
01a4: cmp      x3, x10
01a8: b.ne     0x1048bfb64
01ac: lsl      x0, x0, #16
01b0: asr      x0, x0, #16
01b4: scvtf    d0, x0
01b8: b        0x1048bfb68
01bc: fmov     d0, x0
01c0: str      d0, [x19, #0x9f8]
01c4: mov      x0, x23
01c8: lsr      x3, x0, #48
01cc: mov      x10, #0xfff1
01d0: cmp      x3, x10
01d4: b.hi     0x1048bff00
01d8: mov      x10, #0xfff1
01dc: cmp      x3, x10
01e0: b.ne     0x1048bfb9c
01e4: lsl      x0, x0, #16
01e8: asr      x0, x0, #16
01ec: scvtf    d0, x0
01f0: b        0x1048bfba0
01f4: fmov     d0, x0
01f8: str      d0, [x19, #0xa00]
01fc: ldr      x0, [x19, #0x9e8]
0200: mov      x4, x0
0204: ldr      x0, [x19, #0x9f0]
0208: mov      x5, x0
020c: ldr      d0, [x19, #0x9f8]
0210: fmov     d2, d0
0214: ldr      d0, [x19, #0xa00]
0218: fmov     d3, d0
021c: b        0x1048bfee0
0220: ldr      w0, [x19, #0x20c]
0224: cmp      x0, #0x4
0228: b.ne     0x1048bfde0
022c: mov      x0, x7
0230: str      x0, [x19, #0x9e8]
0234: mov      x0, x21
0238: lsr      x3, x0, #48
023c: mov      x10, #0xfff1
0240: cmp      x3, x10
0244: b.eq     0x1048bfc54
0248: mov      x10, #0xfff1
024c: cmp      x3, x10
0250: b.hi     0x1048bff00
0254: fmov     d0, x0
0258: fcmp     d0, d0
025c: b.vs     0x1048bff00
0260: mov      x1, #-0x3e20000000000000
0264: fmov     d1, x1
0268: fcmp     d0, d1
026c: b.mi     0x1048bff00
0270: mov      x1, #0x41e0000000000000
0274: fmov     d1, x1
0278: fcmp     d0, d1
027c: b.ge     0x1048bff00
0280: lsl      x3, x0, #1
0284: cbnz     x3, 0x1048bfc38
0288: cmp      x0, #0x0
028c: b.lt     0x1048bff00
0290: fcvtzs   x0, d0
0294: scvtf    d1, x0
0298: fcmp     d0, d1
029c: cset     x9, ne
02a0: ccmp     x9, #0x0, #0x4, vc
02a4: b.ne     0x1048bff00
02a8: b        0x1048bfc6c
02ac: sxtw     x3, w0
02b0: lsl      x1, x0, #16
02b4: asr      x1, x1, #16
02b8: cmp      x1, x3
02bc: b.ne     0x1048bff00
02c0: mov      x0, x1
02c4: str      x0, [x19, #0x9f0]
02c8: mov      x0, x22
02cc: lsr      x3, x0, #48
02d0: mov      x10, #0xfff1
02d4: cmp      x3, x10
02d8: b.hi     0x1048bff00
02dc: mov      x10, #0xfff1
02e0: cmp      x3, x10
02e4: b.ne     0x1048bfca0
02e8: lsl      x0, x0, #16
02ec: asr      x0, x0, #16
02f0: scvtf    d0, x0
02f4: b        0x1048bfca4
02f8: fmov     d0, x0
02fc: str      d0, [x19, #0x9f8]
0300: mov      x0, x23
0304: lsr      x3, x0, #48
0308: mov      x10, #0xfff1
030c: cmp      x3, x10
0310: b.hi     0x1048bff00
0314: mov      x10, #0xfff1
0318: cmp      x3, x10
031c: b.ne     0x1048bfcd8
0320: lsl      x0, x0, #16
0324: asr      x0, x0, #16
0328: scvtf    d0, x0
032c: b        0x1048bfcdc
0330: fmov     d0, x0
0334: str      d0, [x19, #0xa00]
0338: ldr      x0, [x19, #0x9b8]
033c: lsr      x3, x0, #48
0340: mov      x10, #0xfff1
0344: cmp      x3, x10
0348: b.hi     0x1048bff00
034c: mov      x10, #0xfff1
0350: cmp      x3, x10
0354: b.ne     0x1048bfd10
0358: lsl      x0, x0, #16
035c: asr      x0, x0, #16
0360: scvtf    d0, x0
0364: b        0x1048bfd14
0368: fmov     d0, x0
036c: str      d0, [x19, #0xa08]
0370: ldr      x0, [x19, #0x9c0]
0374: lsr      x3, x0, #48
0378: mov      x10, #0xfff1
037c: cmp      x3, x10
0380: b.eq     0x1048bfd90
0384: mov      x10, #0xfff1
0388: cmp      x3, x10
038c: b.hi     0x1048bff00
0390: fmov     d0, x0
0394: fcmp     d0, d0
0398: b.vs     0x1048bff00
039c: mov      x1, #-0x3e20000000000000
03a0: fmov     d1, x1
03a4: fcmp     d0, d1
03a8: b.mi     0x1048bff00
03ac: mov      x1, #0x41e0000000000000
03b0: fmov     d1, x1
03b4: fcmp     d0, d1
03b8: b.ge     0x1048bff00
03bc: lsl      x3, x0, #1
03c0: cbnz     x3, 0x1048bfd74
03c4: cmp      x0, #0x0
03c8: b.lt     0x1048bff00
03cc: fcvtzs   x0, d0
03d0: scvtf    d1, x0
03d4: fcmp     d0, d1
03d8: cset     x9, ne
03dc: ccmp     x9, #0x0, #0x4, vc
03e0: b.ne     0x1048bff00
03e4: b        0x1048bfda8
03e8: sxtw     x3, w0
03ec: lsl      x1, x0, #16
03f0: asr      x1, x1, #16
03f4: cmp      x1, x3
03f8: b.ne     0x1048bff00
03fc: mov      x0, x1
0400: str      x0, [x19, #0xa10]
0404: ldr      x0, [x19, #0x9e8]
0408: mov      x4, x0
040c: ldr      x0, [x19, #0x9f0]
0410: mov      x5, x0
0414: ldr      d0, [x19, #0x9f8]
0418: fmov     d2, d0
041c: ldr      d0, [x19, #0xa00]
0420: fmov     d3, d0
0424: ldr      d0, [x19, #0xa08]
0428: fmov     d4, d0
042c: ldr      x0, [x19, #0xa10]
0430: mov      x6, x0
0434: b        0x1048bfee4
0438: b        0x1048bff00
043c: mov      x6, #0x0
0440: mov      x1, #0x0
0444: cmp      x5, x1
0448: b.gt     0x1048bfdf8
044c: b        0x1048bfdfc
0450: b        0x1048bfe00
0454: b        0x1048bff10
0458: mov      x7, x4
045c: mov      x21, x5
0460: fmov     d5, d2
0464: fmov     d6, d3
0468: scvtf    d7, x6
046c: mov      x22, x6
0470: b        0x1048bfea0
0474: ldr      x0, [x19, #0x9b0]
0478: scvtf    d3, x0
047c: fadd     d4, d2, d3
0480: ldr      x1, [x19, #0x9b0]
0484: cmp      x1, x24
0488: b.hs     0x1048bff20
048c: lsl      x1, x1, #3
0490: add      x2, x25, x1
0494: fmov     d0, d4
0498: str      d0, [x2]
049c: ldr      x1, [x19, #0x9b0]
04a0: cmp      x1, x24
04a4: b.hs     0x1048bff30
04a8: lsl      x1, x1, #3
04ac: add      x2, x25, x1
04b0: ldr      d3, [x2]
04b4: fadd     d4, d18, d3
04b8: ldr      x0, [x19, #0x9b0]
04bc: adds     w4, w0, #0x1
04c0: b.vs     0x1048bff40
04c4: sxtw     x4, w4
04c8: ldr      x1, [x19, #0x9a8]
04cc: cmp      x4, x1
04d0: b.lt     0x1048bfe80
04d4: b        0x1048bfe9c
04d8: cmp      x20, #0x1
04dc: b.ls     0x1048bff50
04e0: sub      x20, x20, #0x1
04e4: fmov     d18, d4
04e8: mov      x0, x4
04ec: str      x0, [x19, #0x9b0]
04f0: b        0x1048bfe1c
04f4: b        0x1048bff60
04f8: mov      x0, #0x3ff4000000000000
04fc: fmov     d2, x0
0500: fmul     d3, d5, d2
0504: orr      x0, xzr, #0x3fe0000000000000
0508: fmov     d2, x0
050c: fmul     d4, d6, d2
0510: fadd     d2, d3, d4
0514: mov      x23, x7
0518: mov      x0, x21
051c: str      x0, [x19, #0x9a8]
0520: fmov     d16, d5
0524: fmov     d17, d6
0528: fmov     d18, d7
052c: mov      x0, x22
0530: str      x0, [x19, #0x9b0]
0534: b        0x1048bfe1c
0538: b        0x1048bfde4
053c: mov      x7, x4
0540: mov      x21, x5
0544: fmov     d5, d2
0548: fmov     d6, d3
054c: fmov     d7, d4
0550: mov      x22, x6
0554: b        0x1048bfea0
0558: mov      x0, #0x8220
055c: movk     x0, #0xa4cc, lsl #16
0560: movk     x0, #0x77, lsl #32
0564: b        0x1048bff70
0568: mov      x0, #0x8240
056c: movk     x0, #0xa4cc, lsl #16
0570: movk     x0, #0x77, lsl #32
0574: b        0x1048bff70
0578: mov      x0, #0x8260
057c: movk     x0, #0xa4cc, lsl #16
0580: movk     x0, #0x77, lsl #32
0584: b        0x1048bff70
0588: mov      x0, #0x8280
058c: movk     x0, #0xa4cc, lsl #16
0590: movk     x0, #0x77, lsl #32
0594: b        0x1048bff70
0598: mov      x0, #0x82a0
059c: movk     x0, #0xa4cc, lsl #16
05a0: movk     x0, #0x77, lsl #32
05a4: b        0x1048bff70
05a8: mov      x0, #0x82c0
05ac: movk     x0, #0xa4cc, lsl #16
05b0: movk     x0, #0x77, lsl #32
05b4: b        0x1048bff70
05b8: mov      x0, #0x82e0
05bc: movk     x0, #0xa4cc, lsl #16
05c0: movk     x0, #0x77, lsl #32
05c4: b        0x1048bff70
05c8: ldr      x1, [x19, #0x9a0]
05cc: ldr      x2, [x1, #0x70]
05d0: str      x7, [x2]
05d4: str      x21, [x2, #0x8]
05d8: str      x22, [x2, #0x10]
05dc: str      x23, [x2, #0x18]
05e0: str      x4, [x2, #0x20]
05e4: str      x5, [x2, #0x28]
05e8: str      x6, [x2, #0x30]
05ec: str      d2, [x2, #0x38]
05f0: str      d3, [x2, #0x40]
05f4: str      d4, [x2, #0x48]
05f8: str      d5, [x2, #0x50]
05fc: str      d6, [x2, #0x58]
0600: str      d7, [x2, #0x60]
0604: str      d16, [x2, #0x68]
0608: str      d17, [x2, #0x70]
060c: str      d18, [x2, #0x78]
0610: str      x20, [x19, #0x398]
0614: mov      x1, x0
0618: ldr      x0, [x19, #0x9a0]
061c: bl       0x1042b5d8c
0620: ldp      x29, x30, [sp]
0624: ldp      x19, x20, [sp, #0x40]
0628: ldp      x21, x22, [sp, #0x30]
062c: ldp      x23, x24, [sp, #0x20]
0630: ldr      x25, [sp, #0x18]
0634: add      sp, sp, #0x50
0638: ret
