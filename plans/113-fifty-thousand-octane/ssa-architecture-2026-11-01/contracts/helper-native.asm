0000: stp      x29, x30, [sp, #-0x40]!
0004: stp      x19, x20, [sp, #0x30]
0008: stp      x21, x22, [sp, #0x20]
000c: str      x23, [sp, #0x18]
0010: mov      x29, sp
0014: mov      x19, x0
0018: mov      x20, x1
001c: mov      x1, #0x12
0020: movk     x1, #0x0, lsl #16
0024: movk     x1, #0x0, lsl #32
0028: movk     x1, #0x0, lsl #48
002c: ldr      w0, [x19, #0x208]
0030: cmp      x0, x1
0034: b.ne     0x1049e8c50
0038: ldr      x0, [x19, #0x9a0]
003c: ldr      x0, [x0, #0x50]
0040: ldr      x0, [x0]
0044: str      x0, [x19, #0x9d0]
0048: ldr      x0, [x19, #0x9a0]
004c: ldr      x0, [x0, #0x50]
0050: ldr      x0, [x0, #0x8]
0054: str      x0, [x19, #0x9d8]
0058: ldr      x0, [x19, #0x9a0]
005c: ldr      x0, [x0, #0x50]
0060: ldr      x0, [x0, #0x10]
0064: str      x0, [x19, #0x9e0]
0068: ldr      x0, [x19, #0x9a0]
006c: ldr      x0, [x0, #0x50]
0070: ldr      x0, [x0, #0x18]
0074: str      x0, [x19, #0x9e8]
0078: ldr      x0, [x19, #0x9a0]
007c: ldr      x0, [x0, #0x50]
0080: ldr      x0, [x0, #0x20]
0084: str      x0, [x19, #0x9f0]
0088: ldr      x0, [x19, #0x9a0]
008c: ldr      x0, [x0, #0x50]
0090: ldr      x0, [x0, #0x28]
0094: mov      x4, x0
0098: ldr      x0, [x19, #0x9a0]
009c: ldr      x0, [x0, #0x50]
00a0: ldr      x0, [x0, #0x30]
00a4: mov      x5, x0
00a8: ldr      x0, [x19, #0x9a0]
00ac: ldr      x0, [x0, #0x50]
00b0: ldr      x0, [x0, #0x38]
00b4: mov      x6, x0
00b8: ldr      x0, [x19, #0x9a0]
00bc: ldr      x0, [x0, #0x50]
00c0: ldr      x0, [x0, #0x40]
00c4: mov      x7, x0
00c8: ldr      x0, [x19, #0x9a0]
00cc: ldr      x0, [x0, #0x50]
00d0: ldr      x0, [x0, #0x48]
00d4: mov      x21, x0
00d8: ldr      x0, [x19, #0x9a0]
00dc: ldr      x0, [x0, #0x50]
00e0: ldr      x0, [x0, #0x50]
00e4: mov      x22, x0
00e8: ldr      w0, [x19, #0x20c]
00ec: cbnz     x0, 0x1049e81c0
00f0: ldr      x0, [x19, #0x9d0]
00f4: str      x0, [x19, #0xa10]
00f8: ldr      x0, [x19, #0x9d8]
00fc: lsr      x3, x0, #48
0100: mov      x10, #0xfff1
0104: cmp      x3, x10
0108: b.eq     0x1049e8180
010c: mov      x10, #0xfff1
0110: cmp      x3, x10
0114: b.hi     0x1049e8c50
0118: fmov     d0, x0
011c: fcmp     d0, d0
0120: b.vs     0x1049e8c50
0124: mov      x1, #-0x3e20000000000000
0128: fmov     d1, x1
012c: fcmp     d0, d1
0130: b.mi     0x1049e8c50
0134: mov      x1, #0x41e0000000000000
0138: fmov     d1, x1
013c: fcmp     d0, d1
0140: b.ge     0x1049e8c50
0144: lsl      x3, x0, #1
0148: cbnz     x3, 0x1049e8164
014c: cmp      x0, #0x0
0150: b.lt     0x1049e8c50
0154: fcvtzs   x0, d0
0158: scvtf    d1, x0
015c: fcmp     d0, d1
0160: cset     x9, ne
0164: ccmp     x9, #0x0, #0x4, vc
0168: b.ne     0x1049e8c50
016c: b        0x1049e8198
0170: sxtw     x3, w0
0174: lsl      x1, x0, #16
0178: asr      x1, x1, #16
017c: cmp      x1, x3
0180: b.ne     0x1049e8c50
0184: mov      x0, x1
0188: str      x0, [x19, #0xa18]
018c: ldr      x0, [x19, #0x9e0]
0190: str      x0, [x19, #0xa20]
0194: ldr      x0, [x19, #0xa10]
0198: mov      x4, x0
019c: ldr      x0, [x19, #0xa18]
01a0: mov      x5, x0
01a4: ldr      x0, [x19, #0xa20]
01a8: mov      x6, x0
01ac: b        0x1049e857c
01b0: ldr      w0, [x19, #0x20c]
01b4: cmp      x0, #0x3
01b8: b.ne     0x1049e8368
01bc: ldr      x0, [x19, #0x9d0]
01c0: str      x0, [x19, #0xa10]
01c4: ldr      x0, [x19, #0x9d8]
01c8: lsr      x3, x0, #48
01cc: mov      x10, #0xfff1
01d0: cmp      x3, x10
01d4: b.eq     0x1049e824c
01d8: mov      x10, #0xfff1
01dc: cmp      x3, x10
01e0: b.hi     0x1049e8c50
01e4: fmov     d0, x0
01e8: fcmp     d0, d0
01ec: b.vs     0x1049e8c50
01f0: mov      x1, #-0x3e20000000000000
01f4: fmov     d1, x1
01f8: fcmp     d0, d1
01fc: b.mi     0x1049e8c50
0200: mov      x1, #0x41e0000000000000
0204: fmov     d1, x1
0208: fcmp     d0, d1
020c: b.ge     0x1049e8c50
0210: lsl      x3, x0, #1
0214: cbnz     x3, 0x1049e8230
0218: cmp      x0, #0x0
021c: b.lt     0x1049e8c50
0220: fcvtzs   x0, d0
0224: scvtf    d1, x0
0228: fcmp     d0, d1
022c: cset     x9, ne
0230: ccmp     x9, #0x0, #0x4, vc
0234: b.ne     0x1049e8c50
0238: b        0x1049e8264
023c: sxtw     x3, w0
0240: lsl      x1, x0, #16
0244: asr      x1, x1, #16
0248: cmp      x1, x3
024c: b.ne     0x1049e8c50
0250: mov      x0, x1
0254: str      x0, [x19, #0xa18]
0258: ldr      x0, [x19, #0x9e0]
025c: str      x0, [x19, #0xa20]
0260: ldr      x0, [x19, #0x9e8]
0264: lsr      x3, x0, #48
0268: mov      x10, #0xfff1
026c: cmp      x3, x10
0270: b.hi     0x1049e8c50
0274: mov      x10, #0xfff1
0278: cmp      x3, x10
027c: b.ne     0x1049e82a0
0280: lsl      x0, x0, #16
0284: asr      x0, x0, #16
0288: scvtf    d0, x0
028c: b        0x1049e82a4
0290: fmov     d0, x0
0294: str      d0, [x19, #0xa28]
0298: ldr      x0, [x19, #0x9f0]
029c: lsr      x3, x0, #48
02a0: mov      x10, #0xfff1
02a4: cmp      x3, x10
02a8: b.eq     0x1049e8320
02ac: mov      x10, #0xfff1
02b0: cmp      x3, x10
02b4: b.hi     0x1049e8c50
02b8: fmov     d0, x0
02bc: fcmp     d0, d0
02c0: b.vs     0x1049e8c50
02c4: mov      x1, #-0x3e20000000000000
02c8: fmov     d1, x1
02cc: fcmp     d0, d1
02d0: b.mi     0x1049e8c50
02d4: mov      x1, #0x41e0000000000000
02d8: fmov     d1, x1
02dc: fcmp     d0, d1
02e0: b.ge     0x1049e8c50
02e4: lsl      x3, x0, #1
02e8: cbnz     x3, 0x1049e8304
02ec: cmp      x0, #0x0
02f0: b.lt     0x1049e8c50
02f4: fcvtzs   x0, d0
02f8: scvtf    d1, x0
02fc: fcmp     d0, d1
0300: cset     x9, ne
0304: ccmp     x9, #0x0, #0x4, vc
0308: b.ne     0x1049e8c50
030c: b        0x1049e8338
0310: sxtw     x3, w0
0314: lsl      x1, x0, #16
0318: asr      x1, x1, #16
031c: cmp      x1, x3
0320: b.ne     0x1049e8c50
0324: mov      x0, x1
0328: str      x0, [x19, #0xa30]
032c: ldr      x0, [x19, #0xa10]
0330: mov      x4, x0
0334: ldr      x0, [x19, #0xa18]
0338: mov      x5, x0
033c: ldr      x0, [x19, #0xa20]
0340: mov      x6, x0
0344: ldr      d0, [x19, #0xa28]
0348: fmov     d2, d0
034c: ldr      x0, [x19, #0xa30]
0350: mov      x7, x0
0354: b        0x1049e85b0
0358: ldr      w0, [x19, #0x20c]
035c: cmp      x0, #0x9
0360: b.ne     0x1049e8550
0364: ldr      x0, [x19, #0x9d0]
0368: str      x0, [x19, #0xa10]
036c: ldr      x0, [x19, #0x9d8]
0370: lsr      x3, x0, #48
0374: mov      x10, #0xfff1
0378: cmp      x3, x10
037c: b.eq     0x1049e83f4
0380: mov      x10, #0xfff1
0384: cmp      x3, x10
0388: b.hi     0x1049e8c50
038c: fmov     d0, x0
0390: fcmp     d0, d0
0394: b.vs     0x1049e8c50
0398: mov      x1, #-0x3e20000000000000
039c: fmov     d1, x1
03a0: fcmp     d0, d1
03a4: b.mi     0x1049e8c50
03a8: mov      x1, #0x41e0000000000000
03ac: fmov     d1, x1
03b0: fcmp     d0, d1
03b4: b.ge     0x1049e8c50
03b8: lsl      x3, x0, #1
03bc: cbnz     x3, 0x1049e83d8
03c0: cmp      x0, #0x0
03c4: b.lt     0x1049e8c50
03c8: fcvtzs   x0, d0
03cc: scvtf    d1, x0
03d0: fcmp     d0, d1
03d4: cset     x9, ne
03d8: ccmp     x9, #0x0, #0x4, vc
03dc: b.ne     0x1049e8c50
03e0: b        0x1049e840c
03e4: sxtw     x3, w0
03e8: lsl      x1, x0, #16
03ec: asr      x1, x1, #16
03f0: cmp      x1, x3
03f4: b.ne     0x1049e8c50
03f8: mov      x0, x1
03fc: str      x0, [x19, #0xa18]
0400: ldr      x0, [x19, #0x9e0]
0404: str      x0, [x19, #0xa20]
0408: ldr      x0, [x19, #0x9e8]
040c: lsr      x3, x0, #48
0410: mov      x10, #0xfff1
0414: cmp      x3, x10
0418: b.hi     0x1049e8c50
041c: mov      x10, #0xfff1
0420: cmp      x3, x10
0424: b.ne     0x1049e8448
0428: lsl      x0, x0, #16
042c: asr      x0, x0, #16
0430: scvtf    d0, x0
0434: b        0x1049e844c
0438: fmov     d0, x0
043c: str      d0, [x19, #0xa28]
0440: ldr      x0, [x19, #0x9f0]
0444: lsr      x3, x0, #48
0448: mov      x10, #0xfff1
044c: cmp      x3, x10
0450: b.eq     0x1049e84c8
0454: mov      x10, #0xfff1
0458: cmp      x3, x10
045c: b.hi     0x1049e8c50
0460: fmov     d0, x0
0464: fcmp     d0, d0
0468: b.vs     0x1049e8c50
046c: mov      x1, #-0x3e20000000000000
0470: fmov     d1, x1
0474: fcmp     d0, d1
0478: b.mi     0x1049e8c50
047c: mov      x1, #0x41e0000000000000
0480: fmov     d1, x1
0484: fcmp     d0, d1
0488: b.ge     0x1049e8c50
048c: lsl      x3, x0, #1
0490: cbnz     x3, 0x1049e84ac
0494: cmp      x0, #0x0
0498: b.lt     0x1049e8c50
049c: fcvtzs   x0, d0
04a0: scvtf    d1, x0
04a4: fcmp     d0, d1
04a8: cset     x9, ne
04ac: ccmp     x9, #0x0, #0x4, vc
04b0: b.ne     0x1049e8c50
04b4: b        0x1049e84e0
04b8: sxtw     x3, w0
04bc: lsl      x1, x0, #16
04c0: asr      x1, x1, #16
04c4: cmp      x1, x3
04c8: b.ne     0x1049e8c50
04cc: mov      x0, x1
04d0: str      x0, [x19, #0xa30]
04d4: mov      x0, x4
04d8: lsr      x3, x0, #48
04dc: mov      x10, #0xfff1
04e0: cmp      x3, x10
04e4: b.hi     0x1049e8c50
04e8: mov      x10, #0xfff1
04ec: cmp      x3, x10
04f0: b.ne     0x1049e8514
04f4: lsl      x0, x0, #16
04f8: asr      x0, x0, #16
04fc: scvtf    d0, x0
0500: b        0x1049e8518
0504: fmov     d0, x0
0508: str      d0, [x19, #0xa38]
050c: ldr      x0, [x19, #0xa10]
0510: mov      x21, x0
0514: ldr      x0, [x19, #0xa18]
0518: mov      x22, x0
051c: ldr      x0, [x19, #0xa20]
0520: mov      x23, x0
0524: ldr      d0, [x19, #0xa28]
0528: fmov     d3, d0
052c: ldr      x0, [x19, #0xa30]
0530: str      x0, [x19, #0x9a8]
0534: ldr      d0, [x19, #0xa38]
0538: fmov     d4, d0
053c: b        0x1049e89dc
0540: ldr      x2, [x19, #0x9a0]
0544: mov      x9, #0x0
0548: str      w9, [x2, #0x80]
054c: str      x20, [x19, #0x398]
0550: ldr      w0, [x19, #0x20c]
0554: ldp      x29, x30, [sp]
0558: ldp      x19, x20, [sp, #0x30]
055c: ldp      x21, x22, [sp, #0x20]
0560: ldr      x23, [sp, #0x18]
0564: add      sp, sp, #0x40
0568: ret      
056c: mov      x0, #0x3fd0000000000000
0570: fmov     d2, x0
0574: mov      x7, #0x0
0578: mov      x0, x4
057c: str      x0, [x19, #0x9b0]
0580: mov      x0, x5
0584: str      x0, [x19, #0x9b8]
0588: mov      x0, x6
058c: str      x0, [x19, #0x9c0]
0590: fmov     d3, d2
0594: mov      x0, x7
0598: str      x0, [x19, #0x9c8]
059c: b        0x1049e8bac
05a0: mov      x0, x4
05a4: lsr      x3, x0, #48
05a8: mov      x10, #0xfff9
05ac: cmp      x3, x10
05b0: b.ne     0x1049e8c7c
05b4: and      x0, x0, #0xffffffffffff
05b8: cbz      x0, 0x1049e8c7c
05bc: ldr      w3, [x0]
05c0: mov      x10, #0xf000
05c4: movk     x10, #0x503f, lsl #16
05c8: and      x3, x3, x10
05cc: cmp      x3, #0x10, lsl #12
05d0: b.ne     0x1049e8c7c
05d4: ldr      w2, [x0, #0x10]
05d8: cmp      x2, #0x18
05dc: b.ne     0x1049e8c7c
05e0: mov      x0, x4
05e4: and      x0, x0, #0xffffffffffff
05e8: ldr      x1, [x0, #0x28]
05ec: cbnz     x1, 0x1049e8604
05f0: add      x1, x0, #0x38
05f4: mov      x21, x1
05f8: mov      x1, x21
05fc: ldr      x0, [x1]
0600: lsr      x3, x0, #48
0604: mov      x10, #0xfff1
0608: cmp      x3, x10
060c: b.eq     0x1049e8684
0610: mov      x10, #0xfff1
0614: cmp      x3, x10
0618: b.hi     0x1049e8c7c
061c: fmov     d0, x0
0620: fcmp     d0, d0
0624: b.vs     0x1049e8c7c
0628: mov      x1, #-0x3e20000000000000
062c: fmov     d1, x1
0630: fcmp     d0, d1
0634: b.mi     0x1049e8c7c
0638: mov      x1, #0x41e0000000000000
063c: fmov     d1, x1
0640: fcmp     d0, d1
0644: b.ge     0x1049e8c7c
0648: lsl      x3, x0, #1
064c: cbnz     x3, 0x1049e8668
0650: cmp      x0, #0x0
0654: b.lt     0x1049e8c7c
0658: fcvtzs   x22, d0
065c: scvtf    d1, x22
0660: fcmp     d0, d1
0664: cset     x9, ne
0668: ccmp     x9, #0x0, #0x4, vc
066c: b.ne     0x1049e8c7c
0670: b        0x1049e869c
0674: sxtw     x3, w0
0678: lsl      x1, x0, #16
067c: asr      x1, x1, #16
0680: cmp      x1, x3
0684: b.ne     0x1049e8c7c
0688: mov      x22, x1
068c: adds     w23, w22, #0x1
0690: b.vs     0x1049e8d50
0694: sxtw     x23, w23
0698: mov      x0, x23
069c: and      x0, x0, #0xffffffffffff
06a0: mov      x10, #-0xf000000000000
06a4: orr      x0, x0, x10
06a8: mov      x22, x0
06ac: mov      x0, x4
06b0: lsr      x3, x0, #48
06b4: mov      x10, #0xfff9
06b8: cmp      x3, x10
06bc: b.ne     0x1049e8e48
06c0: and      x0, x0, #0xffffffffffff
06c4: cbz      x0, 0x1049e8e48
06c8: ldr      w3, [x0]
06cc: mov      x10, #0xf000
06d0: movk     x10, #0x503f, lsl #16
06d4: and      x3, x3, x10
06d8: cmp      x3, #0x10, lsl #12
06dc: b.ne     0x1049e8e48
06e0: ldr      w2, [x0, #0x10]
06e4: cmp      x2, #0x18
06e8: b.ne     0x1049e8e48
06ec: mov      x0, x4
06f0: and      x0, x0, #0xffffffffffff
06f4: ldr      w3, [x0, #0x4]
06f8: mov      x10, #0x20
06fc: movk     x10, #0x1, lsl #16
0700: and      x3, x3, x10
0704: cbnz     x3, 0x1049e8e48
0708: mov      x0, x22
070c: lsr      x3, x0, #48
0710: mov      x10, #0xfff1
0714: cmp      x3, x10
0718: b.hi     0x1049e8e48
071c: mov      x2, x21
0720: ldr      x3, [x2]
0724: lsr      x3, x3, #48
0728: mov      x10, #0xfff8
072c: cmp      x3, x10
0730: b.eq     0x1049e8e48
0734: str      x0, [x2]
0738: mov      x0, x4
073c: ldr      x3, [x19, #0x9a0]
0740: ldr      x3, [x3, #0x70]
0744: str      x0, [x3, #0x88]
0748: mov      x0, x5
074c: ldr      x3, [x19, #0x9a0]
0750: ldr      x3, [x3, #0x70]
0754: str      x0, [x3, #0x90]
0758: mov      x0, x6
075c: ldr      x3, [x19, #0x9a0]
0760: ldr      x3, [x3, #0x70]
0764: str      x0, [x3, #0x98]
0768: fmov     d0, d2
076c: fmov     x0, d0
0770: ldr      x3, [x19, #0x9a0]
0774: ldr      x3, [x3, #0x70]
0778: str      x0, [x3, #0xa0]
077c: mov      x0, x7
0780: ldr      x3, [x19, #0x9a0]
0784: ldr      x3, [x3, #0x70]
0788: str      x0, [x3, #0xa8]
078c: mov      x0, x4
0790: ldr      x3, [x19, #0x9a0]
0794: ldr      x3, [x3, #0x70]
0798: str      x0, [x3, #0x88]
079c: mov      x0, x6
07a0: ldr      x3, [x19, #0x9a0]
07a4: ldr      x3, [x3, #0x70]
07a8: str      x0, [x3, #0x98]
07ac: mov      x0, x4
07b0: ldr      x2, [x19, #0x9a0]
07b4: ldr      x2, [x2, #0x78]
07b8: mov      x9, #0x0
07bc: str      w9, [x2]
07c0: str      x0, [x2, #0x8]
07c4: mov      x0, x5
07c8: and      x0, x0, #0xffffffffffff
07cc: mov      x10, #-0xf000000000000
07d0: orr      x0, x0, x10
07d4: ldr      x2, [x19, #0x9a0]
07d8: ldr      x2, [x2, #0x78]
07dc: mov      x9, #0x1
07e0: str      w9, [x2, #0x10]
07e4: str      x0, [x2, #0x18]
07e8: mov      x0, x6
07ec: ldr      x2, [x19, #0x9a0]
07f0: ldr      x2, [x2, #0x78]
07f4: mov      x9, #0x2
07f8: str      w9, [x2, #0x20]
07fc: str      x0, [x2, #0x28]
0800: fmov     d0, d2
0804: fmov     x0, d0
0808: lsr      x3, x0, #48
080c: mov      x10, #0xfff1
0810: cmp      x3, x10
0814: b.lo     0x1049e882c
0818: orr      x0, xzr, #0x7ff8000000000000
081c: ldr      x2, [x19, #0x9a0]
0820: ldr      x2, [x2, #0x78]
0824: mov      x9, #0x3
0828: str      w9, [x2, #0x30]
082c: str      x0, [x2, #0x38]
0830: mov      x0, x7
0834: and      x0, x0, #0xffffffffffff
0838: mov      x10, #-0xf000000000000
083c: orr      x0, x0, x10
0840: ldr      x2, [x19, #0x9a0]
0844: ldr      x2, [x2, #0x78]
0848: mov      x9, #0x4
084c: str      w9, [x2, #0x40]
0850: str      x0, [x2, #0x48]
0854: mov      x0, x6
0858: ldr      x2, [x19, #0x9a0]
085c: ldr      x2, [x2, #0x78]
0860: mov      x9, #0x5
0864: str      w9, [x2, #0x50]
0868: str      x0, [x2, #0x58]
086c: mov      x0, x7
0870: and      x0, x0, #0xffffffffffff
0874: mov      x10, #-0xf000000000000
0878: orr      x0, x0, x10
087c: ldr      x2, [x19, #0x9a0]
0880: ldr      x2, [x2, #0x78]
0884: mov      x9, #0x7
0888: str      w9, [x2, #0x60]
088c: str      x0, [x2, #0x68]
0890: ldr      x2, [x19, #0x9a0]
0894: mov      x9, #0x7
0898: str      w9, [x2, #0x80]
089c: str      x20, [x19, #0x398]
08a0: mov      x0, x19
08a4: mov      x1, #0xf930
08a8: movk     x1, #0x4dd, lsl #16
08ac: movk     x1, #0x1, lsl #32
08b0: bl       0x1046db3a4
08b4: cbz      x0, 0x1049e88e4
08b8: ldr      w0, [x19, #0x20c]
08bc: ldp      x29, x30, [sp]
08c0: ldp      x19, x20, [sp, #0x30]
08c4: ldp      x21, x22, [sp, #0x20]
08c8: ldr      x23, [sp, #0x18]
08cc: add      sp, sp, #0x40
08d0: ret      
08d4: ldr      x3, [x19, #0x9a0]
08d8: ldr      x3, [x3, #0x70]
08dc: ldr      x0, [x3, #0x88]
08e0: mov      x4, x0
08e4: ldr      x3, [x19, #0x9a0]
08e8: ldr      x3, [x3, #0x70]
08ec: ldr      x0, [x3, #0x90]
08f0: mov      x5, x0
08f4: ldr      x3, [x19, #0x9a0]
08f8: ldr      x3, [x3, #0x70]
08fc: ldr      x0, [x3, #0x98]
0900: mov      x6, x0
0904: ldr      x3, [x19, #0x9a0]
0908: ldr      x3, [x3, #0x70]
090c: ldr      x0, [x3, #0xa0]
0910: fmov     d0, x0
0914: fmov     d2, d0
0918: ldr      x3, [x19, #0x9a0]
091c: ldr      x3, [x3, #0x70]
0920: ldr      x0, [x3, #0xa8]
0924: mov      x7, x0
0928: ldr      x0, [x19, #0x9a0]
092c: ldr      x0, [x0, #0x50]
0930: ldr      x0, [x0, #0x28]
0934: str      x0, [x19, #0x9f8]
0938: mov      x21, #-0xd000000000000
093c: mov      x0, x4
0940: str      x0, [x19, #0xa10]
0944: mov      x0, x5
0948: str      x0, [x19, #0xa18]
094c: mov      x0, x6
0950: str      x0, [x19, #0xa20]
0954: fmov     d0, d2
0958: str      d0, [x19, #0xa28]
095c: mov      x0, x7
0960: str      x0, [x19, #0xa30]
0964: ldr      x0, [x19, #0x9f8]
0968: lsr      x3, x0, #48
096c: mov      x10, #0xfff1
0970: cmp      x3, x10
0974: b.hi     0x1049e8f40
0978: mov      x10, #0xfff1
097c: cmp      x3, x10
0980: b.ne     0x1049e89a4
0984: lsl      x0, x0, #16
0988: asr      x0, x0, #16
098c: scvtf    d0, x0
0990: b        0x1049e89a8
0994: fmov     d0, x0
0998: str      d0, [x19, #0xa38]
099c: ldr      x0, [x19, #0xa10]
09a0: mov      x21, x0
09a4: ldr      x0, [x19, #0xa18]
09a8: mov      x22, x0
09ac: ldr      x0, [x19, #0xa20]
09b0: mov      x23, x0
09b4: ldr      d0, [x19, #0xa28]
09b8: fmov     d3, d0
09bc: ldr      x0, [x19, #0xa30]
09c0: str      x0, [x19, #0x9a8]
09c4: ldr      d0, [x19, #0xa38]
09c8: fmov     d4, d0
09cc: fadd     d2, d3, d4
09d0: mov      x0, x21
09d4: lsr      x3, x0, #48
09d8: mov      x10, #0xfff9
09dc: cmp      x3, x10
09e0: b.ne     0x1049e9050
09e4: and      x0, x0, #0xffffffffffff
09e8: cbz      x0, 0x1049e9050
09ec: ldr      w3, [x0]
09f0: mov      x10, #0xf000
09f4: movk     x10, #0x503f, lsl #16
09f8: and      x3, x3, x10
09fc: cmp      x3, #0x10, lsl #12
0a00: b.ne     0x1049e9050
0a04: ldr      w2, [x0, #0x10]
0a08: cmp      x2, #0x18
0a0c: b.ne     0x1049e9050
0a10: mov      x0, x21
0a14: and      x0, x0, #0xffffffffffff
0a18: ldr      x1, [x0, #0x28]
0a1c: cbnz     x1, 0x1049e8a34
0a20: add      x1, x0, #0x38
0a24: mov      x4, x1
0a28: mov      x1, x4
0a2c: ldr      x0, [x1, #0x8]
0a30: lsr      x3, x0, #48
0a34: mov      x10, #0xfff1
0a38: cmp      x3, x10
0a3c: b.eq     0x1049e8ab4
0a40: mov      x10, #0xfff1
0a44: cmp      x3, x10
0a48: b.hi     0x1049e9050
0a4c: fmov     d0, x0
0a50: fcmp     d0, d0
0a54: b.vs     0x1049e9050
0a58: mov      x1, #-0x3e20000000000000
0a5c: fmov     d1, x1
0a60: fcmp     d0, d1
0a64: b.mi     0x1049e9050
0a68: mov      x1, #0x41e0000000000000
0a6c: fmov     d1, x1
0a70: fcmp     d0, d1
0a74: b.ge     0x1049e9050
0a78: lsl      x3, x0, #1
0a7c: cbnz     x3, 0x1049e8a98
0a80: cmp      x0, #0x0
0a84: b.lt     0x1049e9050
0a88: fcvtzs   x5, d0
0a8c: scvtf    d1, x5
0a90: fcmp     d0, d1
0a94: cset     x9, ne
0a98: ccmp     x9, #0x0, #0x4, vc
0a9c: b.ne     0x1049e9050
0aa0: b        0x1049e8acc
0aa4: sxtw     x3, w0
0aa8: lsl      x1, x0, #16
0aac: asr      x1, x1, #16
0ab0: cmp      x1, x3
0ab4: b.ne     0x1049e9050
0ab8: mov      x5, x1
0abc: adds     w6, w5, #0x1
0ac0: b.vs     0x1049e9124
0ac4: sxtw     x6, w6
0ac8: mov      x0, x6
0acc: and      x0, x0, #0xffffffffffff
0ad0: mov      x10, #-0xf000000000000
0ad4: orr      x0, x0, x10
0ad8: mov      x5, x0
0adc: mov      x0, x21
0ae0: lsr      x3, x0, #48
0ae4: mov      x10, #0xfff9
0ae8: cmp      x3, x10
0aec: b.ne     0x1049e921c
0af0: and      x0, x0, #0xffffffffffff
0af4: cbz      x0, 0x1049e921c
0af8: ldr      w3, [x0]
0afc: mov      x10, #0xf000
0b00: movk     x10, #0x503f, lsl #16
0b04: and      x3, x3, x10
0b08: cmp      x3, #0x10, lsl #12
0b0c: b.ne     0x1049e921c
0b10: ldr      w2, [x0, #0x10]
0b14: cmp      x2, #0x18
0b18: b.ne     0x1049e921c
0b1c: mov      x0, x21
0b20: and      x0, x0, #0xffffffffffff
0b24: ldr      w3, [x0, #0x4]
0b28: mov      x10, #0x20
0b2c: movk     x10, #0x1, lsl #16
0b30: and      x3, x3, x10
0b34: cbnz     x3, 0x1049e921c
0b38: mov      x0, x5
0b3c: lsr      x3, x0, #48
0b40: mov      x10, #0xfff1
0b44: cmp      x3, x10
0b48: b.hi     0x1049e921c
0b4c: mov      x2, x4
0b50: ldr      x3, [x2, #0x8]
0b54: lsr      x3, x3, #48
0b58: mov      x10, #0xfff8
0b5c: cmp      x3, x10
0b60: b.eq     0x1049e921c
0b64: str      x0, [x2, #0x8]
0b68: ldr      x0, [x19, #0x9a8]
0b6c: adds     w4, w0, #0x1
0b70: b.vs     0x1049e9314
0b74: sxtw     x4, w4
0b78: mov      x0, x21
0b7c: str      x0, [x19, #0x9b0]
0b80: mov      x0, x22
0b84: str      x0, [x19, #0x9b8]
0b88: mov      x0, x23
0b8c: str      x0, [x19, #0x9c0]
0b90: fmov     d3, d2
0b94: mov      x0, x4
0b98: str      x0, [x19, #0x9c8]
0b9c: ldr      x0, [x19, #0x9c8]
0ba0: ldr      x1, [x19, #0x9b8]
0ba4: cmp      x0, x1
0ba8: b.lt     0x1049e8bc0
0bac: b        0x1049e8bf4
0bb0: cmp      x20, #0x1
0bb4: b.ls     0x1049e93e8
0bb8: sub      x20, x20, #0x1
0bbc: ldr      x0, [x19, #0x9b0]
0bc0: mov      x4, x0
0bc4: ldr      x0, [x19, #0x9b8]
0bc8: mov      x5, x0
0bcc: ldr      x0, [x19, #0x9c0]
0bd0: mov      x6, x0
0bd4: fmov     d2, d3
0bd8: ldr      x0, [x19, #0x9c8]
0bdc: mov      x7, x0
0be0: b        0x1049e85b0
0be4: fmov     d0, d3
0be8: fmov     x0, d0
0bec: lsr      x3, x0, #48
0bf0: mov      x10, #0xfff1
0bf4: cmp      x3, x10
0bf8: b.lo     0x1049e8c10
0bfc: orr      x0, xzr, #0x7ff8000000000000
0c00: ldr      x2, [x19, #0x9a0]
0c04: ldr      x2, [x2, #0x78]
0c08: mov      x9, #0x3
0c0c: str      w9, [x2]
0c10: str      x0, [x2, #0x8]
0c14: ldr      x2, [x19, #0x9a0]
0c18: mov      x9, #0x1
0c1c: str      w9, [x2, #0x80]
0c20: str      x20, [x19, #0x398]
0c24: mov      x0, #0x10
0c28: ldp      x29, x30, [sp]
0c2c: ldp      x19, x20, [sp, #0x30]
0c30: ldp      x21, x22, [sp, #0x20]
0c34: ldr      x23, [sp, #0x18]
0c38: add      sp, sp, #0x40
0c3c: ret      
0c40: ldr      x2, [x19, #0x9a0]
0c44: mov      x9, #0x0
0c48: str      w9, [x2, #0x80]
0c4c: str      x20, [x19, #0x398]
0c50: ldr      w0, [x19, #0x20c]
0c54: ldp      x29, x30, [sp]
0c58: ldp      x19, x20, [sp, #0x30]
0c5c: ldp      x21, x22, [sp, #0x20]
0c60: ldr      x23, [sp, #0x18]
0c64: add      sp, sp, #0x40
0c68: ret      
0c6c: mov      x0, x4
0c70: ldr      x2, [x19, #0x9a0]
0c74: ldr      x2, [x2, #0x78]
0c78: mov      x9, #0x0
0c7c: str      w9, [x2]
0c80: str      x0, [x2, #0x8]
0c84: mov      x0, x5
0c88: and      x0, x0, #0xffffffffffff
0c8c: mov      x10, #-0xf000000000000
0c90: orr      x0, x0, x10
0c94: ldr      x2, [x19, #0x9a0]
0c98: ldr      x2, [x2, #0x78]
0c9c: mov      x9, #0x1
0ca0: str      w9, [x2, #0x10]
0ca4: str      x0, [x2, #0x18]
0ca8: mov      x0, x6
0cac: ldr      x2, [x19, #0x9a0]
0cb0: ldr      x2, [x2, #0x78]
0cb4: mov      x9, #0x2
0cb8: str      w9, [x2, #0x20]
0cbc: str      x0, [x2, #0x28]
0cc0: fmov     d0, d2
0cc4: fmov     x0, d0
0cc8: lsr      x3, x0, #48
0ccc: mov      x10, #0xfff1
0cd0: cmp      x3, x10
0cd4: b.lo     0x1049e8cec
0cd8: orr      x0, xzr, #0x7ff8000000000000
0cdc: ldr      x2, [x19, #0x9a0]
0ce0: ldr      x2, [x2, #0x78]
0ce4: mov      x9, #0x3
0ce8: str      w9, [x2, #0x30]
0cec: str      x0, [x2, #0x38]
0cf0: mov      x0, x7
0cf4: and      x0, x0, #0xffffffffffff
0cf8: mov      x10, #-0xf000000000000
0cfc: orr      x0, x0, x10
0d00: ldr      x2, [x19, #0x9a0]
0d04: ldr      x2, [x2, #0x78]
0d08: mov      x9, #0x4
0d0c: str      w9, [x2, #0x40]
0d10: str      x0, [x2, #0x48]
0d14: ldr      x2, [x19, #0x9a0]
0d18: mov      x9, #0x5
0d1c: str      w9, [x2, #0x80]
0d20: str      x20, [x19, #0x398]
0d24: mov      x0, #0x3
0d28: ldp      x29, x30, [sp]
0d2c: ldp      x19, x20, [sp, #0x30]
0d30: ldp      x21, x22, [sp, #0x20]
0d34: ldr      x23, [sp, #0x18]
0d38: add      sp, sp, #0x40
0d3c: ret      
0d40: mov      x0, x4
0d44: ldr      x2, [x19, #0x9a0]
0d48: ldr      x2, [x2, #0x78]
0d4c: mov      x9, #0x0
0d50: str      w9, [x2]
0d54: str      x0, [x2, #0x8]
0d58: mov      x0, x5
0d5c: and      x0, x0, #0xffffffffffff
0d60: mov      x10, #-0xf000000000000
0d64: orr      x0, x0, x10
0d68: ldr      x2, [x19, #0x9a0]
0d6c: ldr      x2, [x2, #0x78]
0d70: mov      x9, #0x1
0d74: str      w9, [x2, #0x10]
0d78: str      x0, [x2, #0x18]
0d7c: mov      x0, x6
0d80: ldr      x2, [x19, #0x9a0]
0d84: ldr      x2, [x2, #0x78]
0d88: mov      x9, #0x2
0d8c: str      w9, [x2, #0x20]
0d90: str      x0, [x2, #0x28]
0d94: fmov     d0, d2
0d98: fmov     x0, d0
0d9c: lsr      x3, x0, #48
0da0: mov      x10, #0xfff1
0da4: cmp      x3, x10
0da8: b.lo     0x1049e8dc0
0dac: orr      x0, xzr, #0x7ff8000000000000
0db0: ldr      x2, [x19, #0x9a0]
0db4: ldr      x2, [x2, #0x78]
0db8: mov      x9, #0x3
0dbc: str      w9, [x2, #0x30]
0dc0: str      x0, [x2, #0x38]
0dc4: mov      x0, x7
0dc8: and      x0, x0, #0xffffffffffff
0dcc: mov      x10, #-0xf000000000000
0dd0: orr      x0, x0, x10
0dd4: ldr      x2, [x19, #0x9a0]
0dd8: ldr      x2, [x2, #0x78]
0ddc: mov      x9, #0x4
0de0: str      w9, [x2, #0x40]
0de4: str      x0, [x2, #0x48]
0de8: mov      x0, x22
0dec: and      x0, x0, #0xffffffffffff
0df0: mov      x10, #-0xf000000000000
0df4: orr      x0, x0, x10
0df8: ldr      x2, [x19, #0x9a0]
0dfc: ldr      x2, [x2, #0x78]
0e00: mov      x9, #0x7
0e04: str      w9, [x2, #0x50]
0e08: str      x0, [x2, #0x58]
0e0c: ldr      x2, [x19, #0x9a0]
0e10: mov      x9, #0x6
0e14: str      w9, [x2, #0x80]
0e18: str      x20, [x19, #0x398]
0e1c: mov      x0, #0x4
0e20: ldp      x29, x30, [sp]
0e24: ldp      x19, x20, [sp, #0x30]
0e28: ldp      x21, x22, [sp, #0x20]
0e2c: ldr      x23, [sp, #0x18]
0e30: add      sp, sp, #0x40
0e34: ret      
0e38: mov      x0, x4
0e3c: ldr      x2, [x19, #0x9a0]
0e40: ldr      x2, [x2, #0x78]
0e44: mov      x9, #0x0
0e48: str      w9, [x2]
0e4c: str      x0, [x2, #0x8]
0e50: mov      x0, x5
0e54: and      x0, x0, #0xffffffffffff
0e58: mov      x10, #-0xf000000000000
0e5c: orr      x0, x0, x10
0e60: ldr      x2, [x19, #0x9a0]
0e64: ldr      x2, [x2, #0x78]
0e68: mov      x9, #0x1
0e6c: str      w9, [x2, #0x10]
0e70: str      x0, [x2, #0x18]
0e74: mov      x0, x6
0e78: ldr      x2, [x19, #0x9a0]
0e7c: ldr      x2, [x2, #0x78]
0e80: mov      x9, #0x2
0e84: str      w9, [x2, #0x20]
0e88: str      x0, [x2, #0x28]
0e8c: fmov     d0, d2
0e90: fmov     x0, d0
0e94: lsr      x3, x0, #48
0e98: mov      x10, #0xfff1
0e9c: cmp      x3, x10
0ea0: b.lo     0x1049e8eb8
0ea4: orr      x0, xzr, #0x7ff8000000000000
0ea8: ldr      x2, [x19, #0x9a0]
0eac: ldr      x2, [x2, #0x78]
0eb0: mov      x9, #0x3
0eb4: str      w9, [x2, #0x30]
0eb8: str      x0, [x2, #0x38]
0ebc: mov      x0, x7
0ec0: and      x0, x0, #0xffffffffffff
0ec4: mov      x10, #-0xf000000000000
0ec8: orr      x0, x0, x10
0ecc: ldr      x2, [x19, #0x9a0]
0ed0: ldr      x2, [x2, #0x78]
0ed4: mov      x9, #0x4
0ed8: str      w9, [x2, #0x40]
0edc: str      x0, [x2, #0x48]
0ee0: mov      x0, x23
0ee4: and      x0, x0, #0xffffffffffff
0ee8: mov      x10, #-0xf000000000000
0eec: orr      x0, x0, x10
0ef0: ldr      x2, [x19, #0x9a0]
0ef4: ldr      x2, [x2, #0x78]
0ef8: mov      x9, #0x9
0efc: str      w9, [x2, #0x50]
0f00: str      x0, [x2, #0x58]
0f04: ldr      x2, [x19, #0x9a0]
0f08: mov      x9, #0x6
0f0c: str      w9, [x2, #0x80]
0f10: str      x20, [x19, #0x398]
0f14: mov      x0, #0x5
0f18: ldp      x29, x30, [sp]
0f1c: ldp      x19, x20, [sp, #0x30]
0f20: ldp      x21, x22, [sp, #0x20]
0f24: ldr      x23, [sp, #0x18]
0f28: add      sp, sp, #0x40
0f2c: ret      
0f30: mov      x0, x4
0f34: ldr      x2, [x19, #0x9a0]
0f38: ldr      x2, [x2, #0x78]
0f3c: mov      x9, #0x0
0f40: str      w9, [x2]
0f44: str      x0, [x2, #0x8]
0f48: mov      x0, x5
0f4c: and      x0, x0, #0xffffffffffff
0f50: mov      x10, #-0xf000000000000
0f54: orr      x0, x0, x10
0f58: ldr      x2, [x19, #0x9a0]
0f5c: ldr      x2, [x2, #0x78]
0f60: mov      x9, #0x1
0f64: str      w9, [x2, #0x10]
0f68: str      x0, [x2, #0x18]
0f6c: mov      x0, x6
0f70: ldr      x2, [x19, #0x9a0]
0f74: ldr      x2, [x2, #0x78]
0f78: mov      x9, #0x2
0f7c: str      w9, [x2, #0x20]
0f80: str      x0, [x2, #0x28]
0f84: fmov     d0, d2
0f88: fmov     x0, d0
0f8c: lsr      x3, x0, #48
0f90: mov      x10, #0xfff1
0f94: cmp      x3, x10
0f98: b.lo     0x1049e8fb0
0f9c: orr      x0, xzr, #0x7ff8000000000000
0fa0: ldr      x2, [x19, #0x9a0]
0fa4: ldr      x2, [x2, #0x78]
0fa8: mov      x9, #0x3
0fac: str      w9, [x2, #0x30]
0fb0: str      x0, [x2, #0x38]
0fb4: mov      x0, x7
0fb8: and      x0, x0, #0xffffffffffff
0fbc: mov      x10, #-0xf000000000000
0fc0: orr      x0, x0, x10
0fc4: ldr      x2, [x19, #0x9a0]
0fc8: ldr      x2, [x2, #0x78]
0fcc: mov      x9, #0x4
0fd0: str      w9, [x2, #0x40]
0fd4: str      x0, [x2, #0x48]
0fd8: mov      x0, x6
0fdc: ldr      x2, [x19, #0x9a0]
0fe0: ldr      x2, [x2, #0x78]
0fe4: mov      x9, #0x5
0fe8: str      w9, [x2, #0x50]
0fec: str      x0, [x2, #0x58]
0ff0: mov      x0, x7
0ff4: and      x0, x0, #0xffffffffffff
0ff8: mov      x10, #-0xf000000000000
0ffc: orr      x0, x0, x10
1000: ldr      x2, [x19, #0x9a0]
1004: ldr      x2, [x2, #0x78]
1008: mov      x9, #0x7
100c: str      w9, [x2, #0x60]
1010: str      x0, [x2, #0x68]
1014: ldr      x2, [x19, #0x9a0]
1018: mov      x9, #0x7
101c: str      w9, [x2, #0x80]
1020: str      x20, [x19, #0x398]
1024: mov      x0, #0x8
1028: ldp      x29, x30, [sp]
102c: ldp      x19, x20, [sp, #0x30]
1030: ldp      x21, x22, [sp, #0x20]
1034: ldr      x23, [sp, #0x18]
1038: add      sp, sp, #0x40
103c: ret      
1040: mov      x0, x21
1044: ldr      x2, [x19, #0x9a0]
1048: ldr      x2, [x2, #0x78]
104c: mov      x9, #0x0
1050: str      w9, [x2]
1054: str      x0, [x2, #0x8]
1058: mov      x0, x22
105c: and      x0, x0, #0xffffffffffff
1060: mov      x10, #-0xf000000000000
1064: orr      x0, x0, x10
1068: ldr      x2, [x19, #0x9a0]
106c: ldr      x2, [x2, #0x78]
1070: mov      x9, #0x1
1074: str      w9, [x2, #0x10]
1078: str      x0, [x2, #0x18]
107c: mov      x0, x23
1080: ldr      x2, [x19, #0x9a0]
1084: ldr      x2, [x2, #0x78]
1088: mov      x9, #0x2
108c: str      w9, [x2, #0x20]
1090: str      x0, [x2, #0x28]
1094: fmov     d0, d2
1098: fmov     x0, d0
109c: lsr      x3, x0, #48
10a0: mov      x10, #0xfff1
10a4: cmp      x3, x10
10a8: b.lo     0x1049e90c0
10ac: orr      x0, xzr, #0x7ff8000000000000
10b0: ldr      x2, [x19, #0x9a0]
10b4: ldr      x2, [x2, #0x78]
10b8: mov      x9, #0x3
10bc: str      w9, [x2, #0x30]
10c0: str      x0, [x2, #0x38]
10c4: ldr      x0, [x19, #0x9a8]
10c8: and      x0, x0, #0xffffffffffff
10cc: mov      x10, #-0xf000000000000
10d0: orr      x0, x0, x10
10d4: ldr      x2, [x19, #0x9a0]
10d8: ldr      x2, [x2, #0x78]
10dc: mov      x9, #0x4
10e0: str      w9, [x2, #0x40]
10e4: str      x0, [x2, #0x48]
10e8: ldr      x2, [x19, #0x9a0]
10ec: mov      x9, #0x5
10f0: str      w9, [x2, #0x80]
10f4: str      x20, [x19, #0x398]
10f8: mov      x0, #0xb
10fc: ldp      x29, x30, [sp]
1100: ldp      x19, x20, [sp, #0x30]
1104: ldp      x21, x22, [sp, #0x20]
1108: ldr      x23, [sp, #0x18]
110c: add      sp, sp, #0x40
1110: ret      
1114: mov      x0, x21
1118: ldr      x2, [x19, #0x9a0]
111c: ldr      x2, [x2, #0x78]
1120: mov      x9, #0x0
1124: str      w9, [x2]
1128: str      x0, [x2, #0x8]
112c: mov      x0, x22
1130: and      x0, x0, #0xffffffffffff
1134: mov      x10, #-0xf000000000000
1138: orr      x0, x0, x10
113c: ldr      x2, [x19, #0x9a0]
1140: ldr      x2, [x2, #0x78]
1144: mov      x9, #0x1
1148: str      w9, [x2, #0x10]
114c: str      x0, [x2, #0x18]
1150: mov      x0, x23
1154: ldr      x2, [x19, #0x9a0]
1158: ldr      x2, [x2, #0x78]
115c: mov      x9, #0x2
1160: str      w9, [x2, #0x20]
1164: str      x0, [x2, #0x28]
1168: fmov     d0, d2
116c: fmov     x0, d0
1170: lsr      x3, x0, #48
1174: mov      x10, #0xfff1
1178: cmp      x3, x10
117c: b.lo     0x1049e9194
1180: orr      x0, xzr, #0x7ff8000000000000
1184: ldr      x2, [x19, #0x9a0]
1188: ldr      x2, [x2, #0x78]
118c: mov      x9, #0x3
1190: str      w9, [x2, #0x30]
1194: str      x0, [x2, #0x38]
1198: ldr      x0, [x19, #0x9a8]
119c: and      x0, x0, #0xffffffffffff
11a0: mov      x10, #-0xf000000000000
11a4: orr      x0, x0, x10
11a8: ldr      x2, [x19, #0x9a0]
11ac: ldr      x2, [x2, #0x78]
11b0: mov      x9, #0x4
11b4: str      w9, [x2, #0x40]
11b8: str      x0, [x2, #0x48]
11bc: mov      x0, x5
11c0: and      x0, x0, #0xffffffffffff
11c4: mov      x10, #-0xf000000000000
11c8: orr      x0, x0, x10
11cc: ldr      x2, [x19, #0x9a0]
11d0: ldr      x2, [x2, #0x78]
11d4: mov      x9, #0x7
11d8: str      w9, [x2, #0x50]
11dc: str      x0, [x2, #0x58]
11e0: ldr      x2, [x19, #0x9a0]
11e4: mov      x9, #0x6
11e8: str      w9, [x2, #0x80]
11ec: str      x20, [x19, #0x398]
11f0: mov      x0, #0xc
11f4: ldp      x29, x30, [sp]
11f8: ldp      x19, x20, [sp, #0x30]
11fc: ldp      x21, x22, [sp, #0x20]
1200: ldr      x23, [sp, #0x18]
1204: add      sp, sp, #0x40
1208: ret      
120c: mov      x0, x21
1210: ldr      x2, [x19, #0x9a0]
1214: ldr      x2, [x2, #0x78]
1218: mov      x9, #0x0
121c: str      w9, [x2]
1220: str      x0, [x2, #0x8]
1224: mov      x0, x22
1228: and      x0, x0, #0xffffffffffff
122c: mov      x10, #-0xf000000000000
1230: orr      x0, x0, x10
1234: ldr      x2, [x19, #0x9a0]
1238: ldr      x2, [x2, #0x78]
123c: mov      x9, #0x1
1240: str      w9, [x2, #0x10]
1244: str      x0, [x2, #0x18]
1248: mov      x0, x23
124c: ldr      x2, [x19, #0x9a0]
1250: ldr      x2, [x2, #0x78]
1254: mov      x9, #0x2
1258: str      w9, [x2, #0x20]
125c: str      x0, [x2, #0x28]
1260: fmov     d0, d2
1264: fmov     x0, d0
1268: lsr      x3, x0, #48
126c: mov      x10, #0xfff1
1270: cmp      x3, x10
1274: b.lo     0x1049e928c
1278: orr      x0, xzr, #0x7ff8000000000000
127c: ldr      x2, [x19, #0x9a0]
1280: ldr      x2, [x2, #0x78]
1284: mov      x9, #0x3
1288: str      w9, [x2, #0x30]
128c: str      x0, [x2, #0x38]
1290: ldr      x0, [x19, #0x9a8]
1294: and      x0, x0, #0xffffffffffff
1298: mov      x10, #-0xf000000000000
129c: orr      x0, x0, x10
12a0: ldr      x2, [x19, #0x9a0]
12a4: ldr      x2, [x2, #0x78]
12a8: mov      x9, #0x4
12ac: str      w9, [x2, #0x40]
12b0: str      x0, [x2, #0x48]
12b4: mov      x0, x6
12b8: and      x0, x0, #0xffffffffffff
12bc: mov      x10, #-0xf000000000000
12c0: orr      x0, x0, x10
12c4: ldr      x2, [x19, #0x9a0]
12c8: ldr      x2, [x2, #0x78]
12cc: mov      x9, #0x9
12d0: str      w9, [x2, #0x50]
12d4: str      x0, [x2, #0x58]
12d8: ldr      x2, [x19, #0x9a0]
12dc: mov      x9, #0x6
12e0: str      w9, [x2, #0x80]
12e4: str      x20, [x19, #0x398]
12e8: mov      x0, #0xd
12ec: ldp      x29, x30, [sp]
12f0: ldp      x19, x20, [sp, #0x30]
12f4: ldp      x21, x22, [sp, #0x20]
12f8: ldr      x23, [sp, #0x18]
12fc: add      sp, sp, #0x40
1300: ret      
1304: mov      x0, x21
1308: ldr      x2, [x19, #0x9a0]
130c: ldr      x2, [x2, #0x78]
1310: mov      x9, #0x0
1314: str      w9, [x2]
1318: str      x0, [x2, #0x8]
131c: mov      x0, x22
1320: and      x0, x0, #0xffffffffffff
1324: mov      x10, #-0xf000000000000
1328: orr      x0, x0, x10
132c: ldr      x2, [x19, #0x9a0]
1330: ldr      x2, [x2, #0x78]
1334: mov      x9, #0x1
1338: str      w9, [x2, #0x10]
133c: str      x0, [x2, #0x18]
1340: mov      x0, x23
1344: ldr      x2, [x19, #0x9a0]
1348: ldr      x2, [x2, #0x78]
134c: mov      x9, #0x2
1350: str      w9, [x2, #0x20]
1354: str      x0, [x2, #0x28]
1358: fmov     d0, d2
135c: fmov     x0, d0
1360: lsr      x3, x0, #48
1364: mov      x10, #0xfff1
1368: cmp      x3, x10
136c: b.lo     0x1049e9384
1370: orr      x0, xzr, #0x7ff8000000000000
1374: ldr      x2, [x19, #0x9a0]
1378: ldr      x2, [x2, #0x78]
137c: mov      x9, #0x3
1380: str      w9, [x2, #0x30]
1384: str      x0, [x2, #0x38]
1388: ldr      x0, [x19, #0x9a8]
138c: and      x0, x0, #0xffffffffffff
1390: mov      x10, #-0xf000000000000
1394: orr      x0, x0, x10
1398: ldr      x2, [x19, #0x9a0]
139c: ldr      x2, [x2, #0x78]
13a0: mov      x9, #0x4
13a4: str      w9, [x2, #0x40]
13a8: str      x0, [x2, #0x48]
13ac: ldr      x2, [x19, #0x9a0]
13b0: mov      x9, #0x5
13b4: str      w9, [x2, #0x80]
13b8: str      x20, [x19, #0x398]
13bc: mov      x0, #0xe
13c0: ldp      x29, x30, [sp]
13c4: ldp      x19, x20, [sp, #0x30]
13c8: ldp      x21, x22, [sp, #0x20]
13cc: ldr      x23, [sp, #0x18]
13d0: add      sp, sp, #0x40
13d4: ret      
13d8: ldr      x0, [x19, #0x9b0]
13dc: ldr      x2, [x19, #0x9a0]
13e0: ldr      x2, [x2, #0x78]
13e4: mov      x9, #0x0
13e8: str      w9, [x2]
13ec: str      x0, [x2, #0x8]
13f0: ldr      x0, [x19, #0x9b8]
13f4: and      x0, x0, #0xffffffffffff
13f8: mov      x10, #-0xf000000000000
13fc: orr      x0, x0, x10
1400: ldr      x2, [x19, #0x9a0]
1404: ldr      x2, [x2, #0x78]
1408: mov      x9, #0x1
140c: str      w9, [x2, #0x10]
1410: str      x0, [x2, #0x18]
1414: ldr      x0, [x19, #0x9c0]
1418: ldr      x2, [x19, #0x9a0]
141c: ldr      x2, [x2, #0x78]
1420: mov      x9, #0x2
1424: str      w9, [x2, #0x20]
1428: str      x0, [x2, #0x28]
142c: fmov     d0, d3
1430: fmov     x0, d0
1434: lsr      x3, x0, #48
1438: mov      x10, #0xfff1
143c: cmp      x3, x10
1440: b.lo     0x1049e9458
1444: orr      x0, xzr, #0x7ff8000000000000
1448: ldr      x2, [x19, #0x9a0]
144c: ldr      x2, [x2, #0x78]
1450: mov      x9, #0x3
1454: str      w9, [x2, #0x30]
1458: str      x0, [x2, #0x38]
145c: ldr      x0, [x19, #0x9c8]
1460: and      x0, x0, #0xffffffffffff
1464: mov      x10, #-0xf000000000000
1468: orr      x0, x0, x10
146c: ldr      x2, [x19, #0x9a0]
1470: ldr      x2, [x2, #0x78]
1474: mov      x9, #0x4
1478: str      w9, [x2, #0x40]
147c: str      x0, [x2, #0x48]
1480: ldr      x2, [x19, #0x9a0]
1484: mov      x9, #0x5
1488: str      w9, [x2, #0x80]
148c: str      x20, [x19, #0x398]
1490: mov      x0, #0xf
1494: ldp      x29, x30, [sp]
1498: ldp      x19, x20, [sp, #0x30]
149c: ldp      x21, x22, [sp, #0x20]
14a0: ldr      x23, [sp, #0x18]
14a4: add      sp, sp, #0x40
14a8: ret      
