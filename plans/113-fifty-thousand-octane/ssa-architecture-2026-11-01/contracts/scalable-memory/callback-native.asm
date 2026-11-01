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
0028: str      x0, [x19, #0x9e0]
002c: ldr      x0, [x19, #0x9a0]
0030: ldr      x0, [x0, #0x50]
0034: ldr      x0, [x0, #0x8]
0038: str      x0, [x19, #0x9e8]
003c: ldr      x0, [x19, #0x9a0]
0040: ldr      x0, [x0, #0x50]
0044: ldr      x0, [x0, #0x10]
0048: str      x0, [x19, #0x9f0]
004c: ldr      x0, [x19, #0x9a0]
0050: ldr      x0, [x0, #0x50]
0054: ldr      x0, [x0, #0x18]
0058: str      x0, [x19, #0x9f8]
005c: ldr      x0, [x19, #0x9a0]
0060: ldr      x0, [x0, #0x50]
0064: ldr      x0, [x0, #0x20]
0068: str      x0, [x19, #0xa00]
006c: ldr      x0, [x19, #0x9a0]
0070: ldr      x0, [x0, #0x50]
0074: ldr      x0, [x0, #0x28]
0078: str      x0, [x19, #0xa08]
007c: ldr      x0, [x19, #0x9a0]
0080: ldr      x0, [x0, #0x50]
0084: ldr      x0, [x0, #0x30]
0088: str      x0, [x19, #0xa10]
008c: ldr      x0, [x19, #0x9a0]
0090: ldr      x0, [x0, #0x50]
0094: ldr      x0, [x0, #0x38]
0098: mov      x4, x0
009c: ldr      x0, [x19, #0x9a0]
00a0: ldr      x0, [x0, #0x50]
00a4: ldr      x0, [x0, #0x40]
00a8: mov      x21, x0
00ac: ldr      x0, [x19, #0x9a0]
00b0: ldr      x0, [x0, #0x50]
00b4: ldr      x0, [x0, #0x48]
00b8: mov      x5, x0
00bc: ldr      x0, [x19, #0x9a0]
00c0: ldr      x0, [x0, #0x50]
00c4: ldr      x0, [x0, #0x50]
00c8: mov      x6, x0
00cc: ldr      x0, [x19, #0x9a0]
00d0: ldr      x0, [x0, #0x50]
00d4: ldr      x0, [x0, #0x58]
00d8: mov      x7, x0
00dc: ldr      w0, [x19, #0x20c]
00e0: cbnz     x0, 0x100dc81b4
00e4: ldr      x0, [x19, #0x9e0]
00e8: str      x0, [x19, #0xa40]
00ec: ldr      x0, [x19, #0x9e8]
00f0: lsr      x3, x0, #48
00f4: mov      x10, #0xfff1
00f8: cmp      x3, x10
00fc: b.eq     0x100dc8174
0100: mov      x10, #0xfff1
0104: cmp      x3, x10
0108: b.hi     0x100dc98dc
010c: fmov     d0, x0
0110: fcmp     d0, d0
0114: b.vs     0x100dc98dc
0118: mov      x1, #-0x3e20000000000000
011c: fmov     d1, x1
0120: fcmp     d0, d1
0124: b.mi     0x100dc98dc
0128: mov      x1, #0x41e0000000000000
012c: fmov     d1, x1
0130: fcmp     d0, d1
0134: b.ge     0x100dc98dc
0138: lsl      x3, x0, #1
013c: cbnz     x3, 0x100dc8158
0140: cmp      x0, #0x0
0144: b.lt     0x100dc98dc
0148: fcvtzs   x0, d0
014c: scvtf    d1, x0
0150: fcmp     d0, d1
0154: cset     x9, ne
0158: ccmp     x9, #0x0, #0x4, vc
015c: b.ne     0x100dc98dc
0160: b        0x100dc818c
0164: sxtw     x3, w0
0168: lsl      x1, x0, #16
016c: asr      x1, x1, #16
0170: cmp      x1, x3
0174: b.ne     0x100dc98dc
0178: mov      x0, x1
017c: str      x0, [x19, #0xa48]
0180: ldr      x0, [x19, #0x9f0]
0184: str      x0, [x19, #0xa50]
0188: ldr      x0, [x19, #0xa40]
018c: mov      x4, x0
0190: ldr      x0, [x19, #0xa48]
0194: mov      x5, x0
0198: ldr      x0, [x19, #0xa50]
019c: mov      x6, x0
01a0: b        0x100dc8d28
01a4: ldr      w0, [x19, #0x20c]
01a8: cmp      x0, #0x3
01ac: b.ne     0x100dc835c
01b0: ldr      x0, [x19, #0x9e0]
01b4: str      x0, [x19, #0xa40]
01b8: ldr      x0, [x19, #0x9e8]
01bc: lsr      x3, x0, #48
01c0: mov      x10, #0xfff1
01c4: cmp      x3, x10
01c8: b.eq     0x100dc8240
01cc: mov      x10, #0xfff1
01d0: cmp      x3, x10
01d4: b.hi     0x100dc98dc
01d8: fmov     d0, x0
01dc: fcmp     d0, d0
01e0: b.vs     0x100dc98dc
01e4: mov      x1, #-0x3e20000000000000
01e8: fmov     d1, x1
01ec: fcmp     d0, d1
01f0: b.mi     0x100dc98dc
01f4: mov      x1, #0x41e0000000000000
01f8: fmov     d1, x1
01fc: fcmp     d0, d1
0200: b.ge     0x100dc98dc
0204: lsl      x3, x0, #1
0208: cbnz     x3, 0x100dc8224
020c: cmp      x0, #0x0
0210: b.lt     0x100dc98dc
0214: fcvtzs   x0, d0
0218: scvtf    d1, x0
021c: fcmp     d0, d1
0220: cset     x9, ne
0224: ccmp     x9, #0x0, #0x4, vc
0228: b.ne     0x100dc98dc
022c: b        0x100dc8258
0230: sxtw     x3, w0
0234: lsl      x1, x0, #16
0238: asr      x1, x1, #16
023c: cmp      x1, x3
0240: b.ne     0x100dc98dc
0244: mov      x0, x1
0248: str      x0, [x19, #0xa48]
024c: ldr      x0, [x19, #0x9f0]
0250: str      x0, [x19, #0xa50]
0254: ldr      x0, [x19, #0x9f8]
0258: lsr      x3, x0, #48
025c: mov      x10, #0xfff1
0260: cmp      x3, x10
0264: b.hi     0x100dc98dc
0268: mov      x10, #0xfff1
026c: cmp      x3, x10
0270: b.ne     0x100dc8294
0274: lsl      x0, x0, #16
0278: asr      x0, x0, #16
027c: scvtf    d0, x0
0280: b        0x100dc8298
0284: fmov     d0, x0
0288: str      d0, [x19, #0xa58]
028c: ldr      x0, [x19, #0xa00]
0290: lsr      x3, x0, #48
0294: mov      x10, #0xfff1
0298: cmp      x3, x10
029c: b.eq     0x100dc8314
02a0: mov      x10, #0xfff1
02a4: cmp      x3, x10
02a8: b.hi     0x100dc98dc
02ac: fmov     d0, x0
02b0: fcmp     d0, d0
02b4: b.vs     0x100dc98dc
02b8: mov      x1, #-0x3e20000000000000
02bc: fmov     d1, x1
02c0: fcmp     d0, d1
02c4: b.mi     0x100dc98dc
02c8: mov      x1, #0x41e0000000000000
02cc: fmov     d1, x1
02d0: fcmp     d0, d1
02d4: b.ge     0x100dc98dc
02d8: lsl      x3, x0, #1
02dc: cbnz     x3, 0x100dc82f8
02e0: cmp      x0, #0x0
02e4: b.lt     0x100dc98dc
02e8: fcvtzs   x0, d0
02ec: scvtf    d1, x0
02f0: fcmp     d0, d1
02f4: cset     x9, ne
02f8: ccmp     x9, #0x0, #0x4, vc
02fc: b.ne     0x100dc98dc
0300: b        0x100dc832c
0304: sxtw     x3, w0
0308: lsl      x1, x0, #16
030c: asr      x1, x1, #16
0310: cmp      x1, x3
0314: b.ne     0x100dc98dc
0318: mov      x0, x1
031c: str      x0, [x19, #0xa60]
0320: ldr      x0, [x19, #0xa40]
0324: mov      x4, x0
0328: ldr      x0, [x19, #0xa48]
032c: mov      x5, x0
0330: ldr      x0, [x19, #0xa50]
0334: mov      x6, x0
0338: ldr      d0, [x19, #0xa58]
033c: fmov     d2, d0
0340: ldr      x0, [x19, #0xa60]
0344: mov      x7, x0
0348: b        0x100dc8d54
034c: ldr      w0, [x19, #0x20c]
0350: cmp      x0, #0x4
0354: b.ne     0x100dc8544
0358: ldr      x0, [x19, #0x9e0]
035c: str      x0, [x19, #0xa40]
0360: ldr      x0, [x19, #0x9e8]
0364: lsr      x3, x0, #48
0368: mov      x10, #0xfff1
036c: cmp      x3, x10
0370: b.eq     0x100dc83e8
0374: mov      x10, #0xfff1
0378: cmp      x3, x10
037c: b.hi     0x100dc98dc
0380: fmov     d0, x0
0384: fcmp     d0, d0
0388: b.vs     0x100dc98dc
038c: mov      x1, #-0x3e20000000000000
0390: fmov     d1, x1
0394: fcmp     d0, d1
0398: b.mi     0x100dc98dc
039c: mov      x1, #0x41e0000000000000
03a0: fmov     d1, x1
03a4: fcmp     d0, d1
03a8: b.ge     0x100dc98dc
03ac: lsl      x3, x0, #1
03b0: cbnz     x3, 0x100dc83cc
03b4: cmp      x0, #0x0
03b8: b.lt     0x100dc98dc
03bc: fcvtzs   x0, d0
03c0: scvtf    d1, x0
03c4: fcmp     d0, d1
03c8: cset     x9, ne
03cc: ccmp     x9, #0x0, #0x4, vc
03d0: b.ne     0x100dc98dc
03d4: b        0x100dc8400
03d8: sxtw     x3, w0
03dc: lsl      x1, x0, #16
03e0: asr      x1, x1, #16
03e4: cmp      x1, x3
03e8: b.ne     0x100dc98dc
03ec: mov      x0, x1
03f0: str      x0, [x19, #0xa48]
03f4: ldr      x0, [x19, #0x9f0]
03f8: str      x0, [x19, #0xa50]
03fc: ldr      x0, [x19, #0x9f8]
0400: lsr      x3, x0, #48
0404: mov      x10, #0xfff1
0408: cmp      x3, x10
040c: b.hi     0x100dc98dc
0410: mov      x10, #0xfff1
0414: cmp      x3, x10
0418: b.ne     0x100dc843c
041c: lsl      x0, x0, #16
0420: asr      x0, x0, #16
0424: scvtf    d0, x0
0428: b        0x100dc8440
042c: fmov     d0, x0
0430: str      d0, [x19, #0xa58]
0434: ldr      x0, [x19, #0xa00]
0438: lsr      x3, x0, #48
043c: mov      x10, #0xfff1
0440: cmp      x3, x10
0444: b.eq     0x100dc84bc
0448: mov      x10, #0xfff1
044c: cmp      x3, x10
0450: b.hi     0x100dc98dc
0454: fmov     d0, x0
0458: fcmp     d0, d0
045c: b.vs     0x100dc98dc
0460: mov      x1, #-0x3e20000000000000
0464: fmov     d1, x1
0468: fcmp     d0, d1
046c: b.mi     0x100dc98dc
0470: mov      x1, #0x41e0000000000000
0474: fmov     d1, x1
0478: fcmp     d0, d1
047c: b.ge     0x100dc98dc
0480: lsl      x3, x0, #1
0484: cbnz     x3, 0x100dc84a0
0488: cmp      x0, #0x0
048c: b.lt     0x100dc98dc
0490: fcvtzs   x0, d0
0494: scvtf    d1, x0
0498: fcmp     d0, d1
049c: cset     x9, ne
04a0: ccmp     x9, #0x0, #0x4, vc
04a4: b.ne     0x100dc98dc
04a8: b        0x100dc84d4
04ac: sxtw     x3, w0
04b0: lsl      x1, x0, #16
04b4: asr      x1, x1, #16
04b8: cmp      x1, x3
04bc: b.ne     0x100dc98dc
04c0: mov      x0, x1
04c4: str      x0, [x19, #0xa60]
04c8: ldr      x0, [x19, #0xa08]
04cc: lsr      x3, x0, #48
04d0: mov      x10, #0xfff1
04d4: cmp      x3, x10
04d8: b.hi     0x100dc98dc
04dc: mov      x10, #0xfff1
04e0: cmp      x3, x10
04e4: b.ne     0x100dc8508
04e8: lsl      x0, x0, #16
04ec: asr      x0, x0, #16
04f0: scvtf    d0, x0
04f4: b        0x100dc850c
04f8: fmov     d0, x0
04fc: str      d0, [x19, #0xa68]
0500: ldr      x0, [x19, #0xa40]
0504: mov      x21, x0
0508: ldr      x0, [x19, #0xa48]
050c: mov      x22, x0
0510: ldr      x0, [x19, #0xa50]
0514: mov      x23, x0
0518: ldr      d0, [x19, #0xa58]
051c: fmov     d3, d0
0520: ldr      x0, [x19, #0xa60]
0524: str      x0, [x19, #0x9a8]
0528: ldr      d0, [x19, #0xa68]
052c: fmov     d4, d0
0530: b        0x100dc8e80
0534: ldr      w0, [x19, #0x20c]
0538: cmp      x0, #0x8
053c: b.ne     0x100dc872c
0540: ldr      x0, [x19, #0x9e0]
0544: str      x0, [x19, #0xa40]
0548: ldr      x0, [x19, #0x9e8]
054c: lsr      x3, x0, #48
0550: mov      x10, #0xfff1
0554: cmp      x3, x10
0558: b.eq     0x100dc85d0
055c: mov      x10, #0xfff1
0560: cmp      x3, x10
0564: b.hi     0x100dc98dc
0568: fmov     d0, x0
056c: fcmp     d0, d0
0570: b.vs     0x100dc98dc
0574: mov      x1, #-0x3e20000000000000
0578: fmov     d1, x1
057c: fcmp     d0, d1
0580: b.mi     0x100dc98dc
0584: mov      x1, #0x41e0000000000000
0588: fmov     d1, x1
058c: fcmp     d0, d1
0590: b.ge     0x100dc98dc
0594: lsl      x3, x0, #1
0598: cbnz     x3, 0x100dc85b4
059c: cmp      x0, #0x0
05a0: b.lt     0x100dc98dc
05a4: fcvtzs   x0, d0
05a8: scvtf    d1, x0
05ac: fcmp     d0, d1
05b0: cset     x9, ne
05b4: ccmp     x9, #0x0, #0x4, vc
05b8: b.ne     0x100dc98dc
05bc: b        0x100dc85e8
05c0: sxtw     x3, w0
05c4: lsl      x1, x0, #16
05c8: asr      x1, x1, #16
05cc: cmp      x1, x3
05d0: b.ne     0x100dc98dc
05d4: mov      x0, x1
05d8: str      x0, [x19, #0xa48]
05dc: ldr      x0, [x19, #0x9f0]
05e0: str      x0, [x19, #0xa50]
05e4: ldr      x0, [x19, #0x9f8]
05e8: lsr      x3, x0, #48
05ec: mov      x10, #0xfff1
05f0: cmp      x3, x10
05f4: b.hi     0x100dc98dc
05f8: mov      x10, #0xfff1
05fc: cmp      x3, x10
0600: b.ne     0x100dc8624
0604: lsl      x0, x0, #16
0608: asr      x0, x0, #16
060c: scvtf    d0, x0
0610: b        0x100dc8628
0614: fmov     d0, x0
0618: str      d0, [x19, #0xa58]
061c: ldr      x0, [x19, #0xa00]
0620: lsr      x3, x0, #48
0624: mov      x10, #0xfff1
0628: cmp      x3, x10
062c: b.eq     0x100dc86a4
0630: mov      x10, #0xfff1
0634: cmp      x3, x10
0638: b.hi     0x100dc98dc
063c: fmov     d0, x0
0640: fcmp     d0, d0
0644: b.vs     0x100dc98dc
0648: mov      x1, #-0x3e20000000000000
064c: fmov     d1, x1
0650: fcmp     d0, d1
0654: b.mi     0x100dc98dc
0658: mov      x1, #0x41e0000000000000
065c: fmov     d1, x1
0660: fcmp     d0, d1
0664: b.ge     0x100dc98dc
0668: lsl      x3, x0, #1
066c: cbnz     x3, 0x100dc8688
0670: cmp      x0, #0x0
0674: b.lt     0x100dc98dc
0678: fcvtzs   x0, d0
067c: scvtf    d1, x0
0680: fcmp     d0, d1
0684: cset     x9, ne
0688: ccmp     x9, #0x0, #0x4, vc
068c: b.ne     0x100dc98dc
0690: b        0x100dc86bc
0694: sxtw     x3, w0
0698: lsl      x1, x0, #16
069c: asr      x1, x1, #16
06a0: cmp      x1, x3
06a4: b.ne     0x100dc98dc
06a8: mov      x0, x1
06ac: str      x0, [x19, #0xa60]
06b0: ldr      x0, [x19, #0xa08]
06b4: lsr      x3, x0, #48
06b8: mov      x10, #0xfff1
06bc: cmp      x3, x10
06c0: b.hi     0x100dc98dc
06c4: mov      x10, #0xfff1
06c8: cmp      x3, x10
06cc: b.ne     0x100dc86f0
06d0: lsl      x0, x0, #16
06d4: asr      x0, x0, #16
06d8: scvtf    d0, x0
06dc: b        0x100dc86f4
06e0: fmov     d0, x0
06e4: str      d0, [x19, #0xa68]
06e8: ldr      x0, [x19, #0xa40]
06ec: mov      x4, x0
06f0: ldr      x0, [x19, #0xa48]
06f4: mov      x5, x0
06f8: ldr      x0, [x19, #0xa50]
06fc: mov      x6, x0
0700: ldr      d0, [x19, #0xa58]
0704: fmov     d2, d0
0708: ldr      x0, [x19, #0xa60]
070c: mov      x7, x0
0710: ldr      d0, [x19, #0xa68]
0714: fmov     d5, d0
0718: b        0x100dc9110
071c: ldr      w0, [x19, #0x20c]
0720: cmp      x0, #0x9
0724: b.ne     0x100dc8954
0728: ldr      x0, [x19, #0x9e0]
072c: str      x0, [x19, #0xa40]
0730: ldr      x0, [x19, #0x9e8]
0734: lsr      x3, x0, #48
0738: mov      x10, #0xfff1
073c: cmp      x3, x10
0740: b.eq     0x100dc87b8
0744: mov      x10, #0xfff1
0748: cmp      x3, x10
074c: b.hi     0x100dc98dc
0750: fmov     d0, x0
0754: fcmp     d0, d0
0758: b.vs     0x100dc98dc
075c: mov      x1, #-0x3e20000000000000
0760: fmov     d1, x1
0764: fcmp     d0, d1
0768: b.mi     0x100dc98dc
076c: mov      x1, #0x41e0000000000000
0770: fmov     d1, x1
0774: fcmp     d0, d1
0778: b.ge     0x100dc98dc
077c: lsl      x3, x0, #1
0780: cbnz     x3, 0x100dc879c
0784: cmp      x0, #0x0
0788: b.lt     0x100dc98dc
078c: fcvtzs   x0, d0
0790: scvtf    d1, x0
0794: fcmp     d0, d1
0798: cset     x9, ne
079c: ccmp     x9, #0x0, #0x4, vc
07a0: b.ne     0x100dc98dc
07a4: b        0x100dc87d0
07a8: sxtw     x3, w0
07ac: lsl      x1, x0, #16
07b0: asr      x1, x1, #16
07b4: cmp      x1, x3
07b8: b.ne     0x100dc98dc
07bc: mov      x0, x1
07c0: str      x0, [x19, #0xa48]
07c4: ldr      x0, [x19, #0x9f0]
07c8: str      x0, [x19, #0xa50]
07cc: ldr      x0, [x19, #0x9f8]
07d0: lsr      x3, x0, #48
07d4: mov      x10, #0xfff1
07d8: cmp      x3, x10
07dc: b.hi     0x100dc98dc
07e0: mov      x10, #0xfff1
07e4: cmp      x3, x10
07e8: b.ne     0x100dc880c
07ec: lsl      x0, x0, #16
07f0: asr      x0, x0, #16
07f4: scvtf    d0, x0
07f8: b        0x100dc8810
07fc: fmov     d0, x0
0800: str      d0, [x19, #0xa58]
0804: ldr      x0, [x19, #0xa00]
0808: lsr      x3, x0, #48
080c: mov      x10, #0xfff1
0810: cmp      x3, x10
0814: b.eq     0x100dc888c
0818: mov      x10, #0xfff1
081c: cmp      x3, x10
0820: b.hi     0x100dc98dc
0824: fmov     d0, x0
0828: fcmp     d0, d0
082c: b.vs     0x100dc98dc
0830: mov      x1, #-0x3e20000000000000
0834: fmov     d1, x1
0838: fcmp     d0, d1
083c: b.mi     0x100dc98dc
0840: mov      x1, #0x41e0000000000000
0844: fmov     d1, x1
0848: fcmp     d0, d1
084c: b.ge     0x100dc98dc
0850: lsl      x3, x0, #1
0854: cbnz     x3, 0x100dc8870
0858: cmp      x0, #0x0
085c: b.lt     0x100dc98dc
0860: fcvtzs   x0, d0
0864: scvtf    d1, x0
0868: fcmp     d0, d1
086c: cset     x9, ne
0870: ccmp     x9, #0x0, #0x4, vc
0874: b.ne     0x100dc98dc
0878: b        0x100dc88a4
087c: sxtw     x3, w0
0880: lsl      x1, x0, #16
0884: asr      x1, x1, #16
0888: cmp      x1, x3
088c: b.ne     0x100dc98dc
0890: mov      x0, x1
0894: str      x0, [x19, #0xa60]
0898: ldr      x0, [x19, #0xa08]
089c: lsr      x3, x0, #48
08a0: mov      x10, #0xfff1
08a4: cmp      x3, x10
08a8: b.hi     0x100dc98dc
08ac: mov      x10, #0xfff1
08b0: cmp      x3, x10
08b4: b.ne     0x100dc88d8
08b8: lsl      x0, x0, #16
08bc: asr      x0, x0, #16
08c0: scvtf    d0, x0
08c4: b        0x100dc88dc
08c8: fmov     d0, x0
08cc: str      d0, [x19, #0xa68]
08d0: ldr      x0, [x19, #0xa10]
08d4: lsr      x3, x0, #48
08d8: mov      x10, #0xfff1
08dc: cmp      x3, x10
08e0: b.hi     0x100dc98dc
08e4: mov      x10, #0xfff1
08e8: cmp      x3, x10
08ec: b.ne     0x100dc8910
08f0: lsl      x0, x0, #16
08f4: asr      x0, x0, #16
08f8: scvtf    d0, x0
08fc: b        0x100dc8914
0900: fmov     d0, x0
0904: str      d0, [x19, #0xa70]
0908: ldr      x0, [x19, #0xa40]
090c: mov      x21, x0
0910: ldr      x0, [x19, #0xa48]
0914: mov      x22, x0
0918: ldr      x0, [x19, #0xa50]
091c: mov      x23, x0
0920: ldr      d0, [x19, #0xa58]
0924: fmov     d3, d0
0928: ldr      x0, [x19, #0xa60]
092c: str      x0, [x19, #0x9b0]
0930: ldr      d0, [x19, #0xa68]
0934: fmov     d4, d0
0938: ldr      d0, [x19, #0xa70]
093c: fmov     d6, d0
0940: b        0x100dc924c
0944: ldr      w0, [x19, #0x20c]
0948: cmp      x0, #0xd
094c: b.ne     0x100dc8b7c
0950: ldr      x0, [x19, #0x9e0]
0954: str      x0, [x19, #0xa40]
0958: ldr      x0, [x19, #0x9e8]
095c: lsr      x3, x0, #48
0960: mov      x10, #0xfff1
0964: cmp      x3, x10
0968: b.eq     0x100dc89e0
096c: mov      x10, #0xfff1
0970: cmp      x3, x10
0974: b.hi     0x100dc98dc
0978: fmov     d0, x0
097c: fcmp     d0, d0
0980: b.vs     0x100dc98dc
0984: mov      x1, #-0x3e20000000000000
0988: fmov     d1, x1
098c: fcmp     d0, d1
0990: b.mi     0x100dc98dc
0994: mov      x1, #0x41e0000000000000
0998: fmov     d1, x1
099c: fcmp     d0, d1
09a0: b.ge     0x100dc98dc
09a4: lsl      x3, x0, #1
09a8: cbnz     x3, 0x100dc89c4
09ac: cmp      x0, #0x0
09b0: b.lt     0x100dc98dc
09b4: fcvtzs   x0, d0
09b8: scvtf    d1, x0
09bc: fcmp     d0, d1
09c0: cset     x9, ne
09c4: ccmp     x9, #0x0, #0x4, vc
09c8: b.ne     0x100dc98dc
09cc: b        0x100dc89f8
09d0: sxtw     x3, w0
09d4: lsl      x1, x0, #16
09d8: asr      x1, x1, #16
09dc: cmp      x1, x3
09e0: b.ne     0x100dc98dc
09e4: mov      x0, x1
09e8: str      x0, [x19, #0xa48]
09ec: ldr      x0, [x19, #0x9f0]
09f0: str      x0, [x19, #0xa50]
09f4: ldr      x0, [x19, #0x9f8]
09f8: lsr      x3, x0, #48
09fc: mov      x10, #0xfff1
0a00: cmp      x3, x10
0a04: b.hi     0x100dc98dc
0a08: mov      x10, #0xfff1
0a0c: cmp      x3, x10
0a10: b.ne     0x100dc8a34
0a14: lsl      x0, x0, #16
0a18: asr      x0, x0, #16
0a1c: scvtf    d0, x0
0a20: b        0x100dc8a38
0a24: fmov     d0, x0
0a28: str      d0, [x19, #0xa58]
0a2c: ldr      x0, [x19, #0xa00]
0a30: lsr      x3, x0, #48
0a34: mov      x10, #0xfff1
0a38: cmp      x3, x10
0a3c: b.eq     0x100dc8ab4
0a40: mov      x10, #0xfff1
0a44: cmp      x3, x10
0a48: b.hi     0x100dc98dc
0a4c: fmov     d0, x0
0a50: fcmp     d0, d0
0a54: b.vs     0x100dc98dc
0a58: mov      x1, #-0x3e20000000000000
0a5c: fmov     d1, x1
0a60: fcmp     d0, d1
0a64: b.mi     0x100dc98dc
0a68: mov      x1, #0x41e0000000000000
0a6c: fmov     d1, x1
0a70: fcmp     d0, d1
0a74: b.ge     0x100dc98dc
0a78: lsl      x3, x0, #1
0a7c: cbnz     x3, 0x100dc8a98
0a80: cmp      x0, #0x0
0a84: b.lt     0x100dc98dc
0a88: fcvtzs   x0, d0
0a8c: scvtf    d1, x0
0a90: fcmp     d0, d1
0a94: cset     x9, ne
0a98: ccmp     x9, #0x0, #0x4, vc
0a9c: b.ne     0x100dc98dc
0aa0: b        0x100dc8acc
0aa4: sxtw     x3, w0
0aa8: lsl      x1, x0, #16
0aac: asr      x1, x1, #16
0ab0: cmp      x1, x3
0ab4: b.ne     0x100dc98dc
0ab8: mov      x0, x1
0abc: str      x0, [x19, #0xa60]
0ac0: ldr      x0, [x19, #0xa10]
0ac4: lsr      x3, x0, #48
0ac8: mov      x10, #0xfff1
0acc: cmp      x3, x10
0ad0: b.hi     0x100dc98dc
0ad4: mov      x10, #0xfff1
0ad8: cmp      x3, x10
0adc: b.ne     0x100dc8b00
0ae0: lsl      x0, x0, #16
0ae4: asr      x0, x0, #16
0ae8: scvtf    d0, x0
0aec: b        0x100dc8b04
0af0: fmov     d0, x0
0af4: str      d0, [x19, #0xa68]
0af8: mov      x0, x21
0afc: lsr      x3, x0, #48
0b00: mov      x10, #0xfff1
0b04: cmp      x3, x10
0b08: b.hi     0x100dc98dc
0b0c: mov      x10, #0xfff1
0b10: cmp      x3, x10
0b14: b.ne     0x100dc8b38
0b18: lsl      x0, x0, #16
0b1c: asr      x0, x0, #16
0b20: scvtf    d0, x0
0b24: b        0x100dc8b3c
0b28: fmov     d0, x0
0b2c: str      d0, [x19, #0xa70]
0b30: ldr      x0, [x19, #0xa40]
0b34: mov      x4, x0
0b38: ldr      x0, [x19, #0xa48]
0b3c: mov      x5, x0
0b40: ldr      x0, [x19, #0xa50]
0b44: mov      x6, x0
0b48: ldr      d0, [x19, #0xa58]
0b4c: fmov     d2, d0
0b50: ldr      x0, [x19, #0xa60]
0b54: mov      x7, x0
0b58: ldr      d0, [x19, #0xa68]
0b5c: fmov     d3, d0
0b60: ldr      d0, [x19, #0xa70]
0b64: fmov     d4, d0
0b68: b        0x100dc9394
0b6c: ldr      w0, [x19, #0x20c]
0b70: cmp      x0, #0xf
0b74: b.ne     0x100dc8d24
0b78: ldr      x0, [x19, #0x9e0]
0b7c: str      x0, [x19, #0xa40]
0b80: ldr      x0, [x19, #0x9e8]
0b84: lsr      x3, x0, #48
0b88: mov      x10, #0xfff1
0b8c: cmp      x3, x10
0b90: b.eq     0x100dc8c08
0b94: mov      x10, #0xfff1
0b98: cmp      x3, x10
0b9c: b.hi     0x100dc98dc
0ba0: fmov     d0, x0
0ba4: fcmp     d0, d0
0ba8: b.vs     0x100dc98dc
0bac: mov      x1, #-0x3e20000000000000
0bb0: fmov     d1, x1
0bb4: fcmp     d0, d1
0bb8: b.mi     0x100dc98dc
0bbc: mov      x1, #0x41e0000000000000
0bc0: fmov     d1, x1
0bc4: fcmp     d0, d1
0bc8: b.ge     0x100dc98dc
0bcc: lsl      x3, x0, #1
0bd0: cbnz     x3, 0x100dc8bec
0bd4: cmp      x0, #0x0
0bd8: b.lt     0x100dc98dc
0bdc: fcvtzs   x0, d0
0be0: scvtf    d1, x0
0be4: fcmp     d0, d1
0be8: cset     x9, ne
0bec: ccmp     x9, #0x0, #0x4, vc
0bf0: b.ne     0x100dc98dc
0bf4: b        0x100dc8c20
0bf8: sxtw     x3, w0
0bfc: lsl      x1, x0, #16
0c00: asr      x1, x1, #16
0c04: cmp      x1, x3
0c08: b.ne     0x100dc98dc
0c0c: mov      x0, x1
0c10: str      x0, [x19, #0xa48]
0c14: ldr      x0, [x19, #0x9f0]
0c18: str      x0, [x19, #0xa50]
0c1c: ldr      x0, [x19, #0x9f8]
0c20: lsr      x3, x0, #48
0c24: mov      x10, #0xfff1
0c28: cmp      x3, x10
0c2c: b.hi     0x100dc98dc
0c30: mov      x10, #0xfff1
0c34: cmp      x3, x10
0c38: b.ne     0x100dc8c5c
0c3c: lsl      x0, x0, #16
0c40: asr      x0, x0, #16
0c44: scvtf    d0, x0
0c48: b        0x100dc8c60
0c4c: fmov     d0, x0
0c50: str      d0, [x19, #0xa58]
0c54: ldr      x0, [x19, #0xa00]
0c58: lsr      x3, x0, #48
0c5c: mov      x10, #0xfff1
0c60: cmp      x3, x10
0c64: b.eq     0x100dc8cdc
0c68: mov      x10, #0xfff1
0c6c: cmp      x3, x10
0c70: b.hi     0x100dc98dc
0c74: fmov     d0, x0
0c78: fcmp     d0, d0
0c7c: b.vs     0x100dc98dc
0c80: mov      x1, #-0x3e20000000000000
0c84: fmov     d1, x1
0c88: fcmp     d0, d1
0c8c: b.mi     0x100dc98dc
0c90: mov      x1, #0x41e0000000000000
0c94: fmov     d1, x1
0c98: fcmp     d0, d1
0c9c: b.ge     0x100dc98dc
0ca0: lsl      x3, x0, #1
0ca4: cbnz     x3, 0x100dc8cc0
0ca8: cmp      x0, #0x0
0cac: b.lt     0x100dc98dc
0cb0: fcvtzs   x0, d0
0cb4: scvtf    d1, x0
0cb8: fcmp     d0, d1
0cbc: cset     x9, ne
0cc0: ccmp     x9, #0x0, #0x4, vc
0cc4: b.ne     0x100dc98dc
0cc8: b        0x100dc8cf4
0ccc: sxtw     x3, w0
0cd0: lsl      x1, x0, #16
0cd4: asr      x1, x1, #16
0cd8: cmp      x1, x3
0cdc: b.ne     0x100dc98dc
0ce0: mov      x0, x1
0ce4: str      x0, [x19, #0xa60]
0ce8: ldr      x0, [x19, #0xa40]
0cec: mov      x21, x0
0cf0: ldr      x0, [x19, #0xa48]
0cf4: mov      x22, x0
0cf8: ldr      x0, [x19, #0xa50]
0cfc: mov      x23, x0
0d00: ldr      d0, [x19, #0xa58]
0d04: fmov     d3, d0
0d08: ldr      x0, [x19, #0xa60]
0d0c: str      x0, [x19, #0x9b8]
0d10: b        0x100dc94f0
0d14: b        0x100dc98dc
0d18: mov      x7, #0x0
0d1c: mov      x0, x4
0d20: str      x0, [x19, #0x9c0]
0d24: mov      x0, x5
0d28: str      x0, [x19, #0x9c8]
0d2c: mov      x0, x6
0d30: str      x0, [x19, #0x9d0]
0d34: scvtf    d4, x7
0d38: mov      x0, x7
0d3c: str      x0, [x19, #0x9d8]
0d40: b        0x100dc9524
0d44: mov      x0, x4
0d48: lsr      x3, x0, #48
0d4c: mov      x10, #0xfff9
0d50: cmp      x3, x10
0d54: b.ne     0x100dc98ec
0d58: and      x0, x0, #0xffffffffffff
0d5c: cbz      x0, 0x100dc98ec
0d60: mov      x1, x7
0d64: ldr      w2, [x0]
0d68: mov      x10, #0x8000
0d6c: movk     x10, #0x503f, lsl #16
0d70: and      x3, x2, x10
0d74: cmp      x3, #0x20, lsl #12
0d78: b.ne     0x100dc98ec
0d7c: ldr      w3, [x0, #0x1c]
0d80: cmp      x1, x3
0d84: b.hs     0x100dc98ec
0d88: ldr      w3, [x0, #0x38]
0d8c: cmp      x1, x3
0d90: b.hs     0x100dc98ec
0d94: ldr      x2, [x0, #0x28]
0d98: cbnz     x2, 0x100dc8dbc
0d9c: ldr      w3, [x0, #0x3c]
0da0: cbz      x3, 0x100dc98ec
0da4: add      x2, x0, #0x40
0da8: b        0x100dc8dc8
0dac: ldr      w3, [x0, #0x14]
0db0: lsl      x3, x3, #3
0db4: add      x2, x2, x3
0db8: lsl      x1, x1, #3
0dbc: add      x2, x2, x1
0dc0: mov      x21, x2
0dc4: mov      x2, x21
0dc8: ldr      x0, [x2]
0dcc: lsr      x3, x0, #48
0dd0: mov      x10, #0xfff1
0dd4: cmp      x3, x10
0dd8: b.hi     0x100dc98ec
0ddc: str      x0, [x19, #0xa18]
0de0: mov      x0, x4
0de4: str      x0, [x19, #0xa40]
0de8: mov      x0, x5
0dec: str      x0, [x19, #0xa48]
0df0: mov      x0, x6
0df4: str      x0, [x19, #0xa50]
0df8: fmov     d0, d2
0dfc: str      d0, [x19, #0xa58]
0e00: mov      x0, x7
0e04: str      x0, [x19, #0xa60]
0e08: ldr      x0, [x19, #0xa18]
0e0c: lsr      x3, x0, #48
0e10: mov      x10, #0xfff1
0e14: cmp      x3, x10
0e18: b.hi     0x100dc98fc
0e1c: mov      x10, #0xfff1
0e20: cmp      x3, x10
0e24: b.ne     0x100dc8e48
0e28: lsl      x0, x0, #16
0e2c: asr      x0, x0, #16
0e30: scvtf    d0, x0
0e34: b        0x100dc8e4c
0e38: fmov     d0, x0
0e3c: str      d0, [x19, #0xa68]
0e40: ldr      x0, [x19, #0xa40]
0e44: mov      x21, x0
0e48: ldr      x0, [x19, #0xa48]
0e4c: mov      x22, x0
0e50: ldr      x0, [x19, #0xa50]
0e54: mov      x23, x0
0e58: ldr      d0, [x19, #0xa58]
0e5c: fmov     d3, d0
0e60: ldr      x0, [x19, #0xa60]
0e64: str      x0, [x19, #0x9a8]
0e68: ldr      d0, [x19, #0xa68]
0e6c: fmov     d4, d0
0e70: mov      x0, x21
0e74: ldr      x3, [x19, #0x9a0]
0e78: ldr      x3, [x3, #0x70]
0e7c: str      x0, [x3, #0xc8]
0e80: mov      x0, x22
0e84: ldr      x3, [x19, #0x9a0]
0e88: ldr      x3, [x3, #0x70]
0e8c: str      x0, [x3, #0xd0]
0e90: mov      x0, x23
0e94: ldr      x3, [x19, #0x9a0]
0e98: ldr      x3, [x3, #0x70]
0e9c: str      x0, [x3, #0xd8]
0ea0: fmov     d0, d3
0ea4: fmov     x0, d0
0ea8: ldr      x3, [x19, #0x9a0]
0eac: ldr      x3, [x3, #0x70]
0eb0: str      x0, [x3, #0xe0]
0eb4: ldr      x0, [x19, #0x9a8]
0eb8: ldr      x3, [x19, #0x9a0]
0ebc: ldr      x3, [x3, #0x70]
0ec0: str      x0, [x3, #0xe8]
0ec4: fmov     d0, d4
0ec8: fmov     x0, d0
0ecc: ldr      x3, [x19, #0x9a0]
0ed0: ldr      x3, [x3, #0x70]
0ed4: str      x0, [x3, #0xf0]
0ed8: mov      x0, x21
0edc: ldr      x3, [x19, #0x9a0]
0ee0: ldr      x3, [x3, #0x70]
0ee4: str      x0, [x3, #0xc8]
0ee8: mov      x0, x23
0eec: ldr      x3, [x19, #0x9a0]
0ef0: ldr      x3, [x3, #0x70]
0ef4: str      x0, [x3, #0xd8]
0ef8: mov      x0, x21
0efc: ldr      x2, [x19, #0x9a0]
0f00: ldr      x2, [x2, #0x78]
0f04: mov      x9, #0x0
0f08: str      w9, [x2]
0f0c: str      x0, [x2, #0x8]
0f10: mov      x0, x22
0f14: and      x0, x0, #0xffffffffffff
0f18: mov      x10, #-0xf000000000000
0f1c: orr      x0, x0, x10
0f20: ldr      x2, [x19, #0x9a0]
0f24: ldr      x2, [x2, #0x78]
0f28: mov      x9, #0x1
0f2c: str      w9, [x2, #0x10]
0f30: str      x0, [x2, #0x18]
0f34: mov      x0, x23
0f38: ldr      x2, [x19, #0x9a0]
0f3c: ldr      x2, [x2, #0x78]
0f40: mov      x9, #0x2
0f44: str      w9, [x2, #0x20]
0f48: str      x0, [x2, #0x28]
0f4c: fmov     d0, d3
0f50: fmov     x0, d0
0f54: lsr      x3, x0, #48
0f58: mov      x10, #0xfff1
0f5c: cmp      x3, x10
0f60: b.lo     0x100dc8f78
0f64: orr      x0, xzr, #0x7ff8000000000000
0f68: ldr      x2, [x19, #0x9a0]
0f6c: ldr      x2, [x2, #0x78]
0f70: mov      x9, #0x3
0f74: str      w9, [x2, #0x30]
0f78: str      x0, [x2, #0x38]
0f7c: ldr      x0, [x19, #0x9a8]
0f80: and      x0, x0, #0xffffffffffff
0f84: mov      x10, #-0xf000000000000
0f88: orr      x0, x0, x10
0f8c: ldr      x2, [x19, #0x9a0]
0f90: ldr      x2, [x2, #0x78]
0f94: mov      x9, #0x4
0f98: str      w9, [x2, #0x40]
0f9c: str      x0, [x2, #0x48]
0fa0: fmov     d0, d4
0fa4: fmov     x0, d0
0fa8: lsr      x3, x0, #48
0fac: mov      x10, #0xfff1
0fb0: cmp      x3, x10
0fb4: b.lo     0x100dc8fcc
0fb8: orr      x0, xzr, #0x7ff8000000000000
0fbc: ldr      x2, [x19, #0x9a0]
0fc0: ldr      x2, [x2, #0x78]
0fc4: mov      x9, #0x5
0fc8: str      w9, [x2, #0x50]
0fcc: str      x0, [x2, #0x58]
0fd0: mov      x0, x23
0fd4: ldr      x2, [x19, #0x9a0]
0fd8: ldr      x2, [x2, #0x78]
0fdc: mov      x9, #0x6
0fe0: str      w9, [x2, #0x60]
0fe4: str      x0, [x2, #0x68]
0fe8: mov      x0, x21
0fec: ldr      x2, [x19, #0x9a0]
0ff0: ldr      x2, [x2, #0x78]
0ff4: mov      x9, #0x8
0ff8: str      w9, [x2, #0x70]
0ffc: str      x0, [x2, #0x78]
1000: ldr      x0, [x19, #0x9a8]
1004: and      x0, x0, #0xffffffffffff
1008: mov      x10, #-0xf000000000000
100c: orr      x0, x0, x10
1010: ldr      x2, [x19, #0x9a0]
1014: ldr      x2, [x2, #0x78]
1018: mov      x9, #0x9
101c: str      w9, [x2, #0x80]
1020: str      x0, [x2, #0x88]
1024: ldr      x2, [x19, #0x9a0]
1028: mov      x9, #0x9
102c: str      w9, [x2, #0x80]
1030: str      x20, [x19, #0x398]
1034: mov      x0, x19
1038: mov      x1, #0xa00
103c: movk     x1, #0x90c5, lsl #16
1040: movk     x1, #0x76, lsl #32
1044: bl       0x100bdf8a0
1048: cbz      x0, 0x100dc9078
104c: ldr      w0, [x19, #0x20c]
1050: ldp      x29, x30, [sp]
1054: ldp      x19, x20, [sp, #0x30]
1058: ldp      x21, x22, [sp, #0x20]
105c: ldr      x23, [sp, #0x18]
1060: add      sp, sp, #0x40
1064: ret      
1068: ldr      x3, [x19, #0x9a0]
106c: ldr      x3, [x3, #0x70]
1070: ldr      x0, [x3, #0xc8]
1074: mov      x21, x0
1078: ldr      x3, [x19, #0x9a0]
107c: ldr      x3, [x3, #0x70]
1080: ldr      x0, [x3, #0xd0]
1084: mov      x22, x0
1088: ldr      x3, [x19, #0x9a0]
108c: ldr      x3, [x3, #0x70]
1090: ldr      x0, [x3, #0xd8]
1094: mov      x23, x0
1098: ldr      x3, [x19, #0x9a0]
109c: ldr      x3, [x3, #0x70]
10a0: ldr      x0, [x3, #0xe0]
10a4: fmov     d0, x0
10a8: fmov     d3, d0
10ac: ldr      x3, [x19, #0x9a0]
10b0: ldr      x3, [x3, #0x70]
10b4: ldr      x0, [x3, #0xe8]
10b8: str      x0, [x19, #0x9a8]
10bc: ldr      x3, [x19, #0x9a0]
10c0: ldr      x3, [x3, #0x70]
10c4: ldr      x0, [x3, #0xf0]
10c8: fmov     d0, x0
10cc: fmov     d4, d0
10d0: ldr      x0, [x19, #0x9a0]
10d4: ldr      x0, [x0, #0x50]
10d8: ldr      x0, [x0, #0x30]
10dc: mov      x4, x0
10e0: mov      x4, #-0xd000000000000
10e4: mov      x4, x21
10e8: mov      x5, x22
10ec: mov      x6, x23
10f0: fmov     d2, d3
10f4: ldr      x0, [x19, #0x9a8]
10f8: mov      x7, x0
10fc: fmov     d5, d4
1100: mov      x0, x4
1104: lsr      x3, x0, #48
1108: mov      x10, #0xfff9
110c: cmp      x3, x10
1110: b.ne     0x100dc990c
1114: and      x0, x0, #0xffffffffffff
1118: cbz      x0, 0x100dc990c
111c: mov      x1, x7
1120: ldr      w2, [x0]
1124: mov      x10, #0x8000
1128: movk     x10, #0x503f, lsl #16
112c: and      x3, x2, x10
1130: cmp      x3, #0x20, lsl #12
1134: b.ne     0x100dc990c
1138: ldr      w3, [x0, #0x1c]
113c: cmp      x1, x3
1140: b.hs     0x100dc990c
1144: ldr      w3, [x0, #0x38]
1148: cmp      x1, x3
114c: b.hs     0x100dc990c
1150: ldr      x2, [x0, #0x28]
1154: cbnz     x2, 0x100dc9178
1158: ldr      w3, [x0, #0x3c]
115c: cbz      x3, 0x100dc990c
1160: add      x2, x0, #0x40
1164: b        0x100dc9184
1168: ldr      w3, [x0, #0x14]
116c: lsl      x3, x3, #3
1170: add      x2, x2, x3
1174: lsl      x1, x1, #3
1178: add      x2, x2, x1
117c: mov      x21, x2
1180: mov      x2, x21
1184: ldr      x0, [x2]
1188: lsr      x3, x0, #48
118c: mov      x10, #0xfff1
1190: cmp      x3, x10
1194: b.hi     0x100dc990c
1198: str      x0, [x19, #0xa20]
119c: mov      x0, x4
11a0: str      x0, [x19, #0xa40]
11a4: mov      x0, x5
11a8: str      x0, [x19, #0xa48]
11ac: mov      x0, x6
11b0: str      x0, [x19, #0xa50]
11b4: fmov     d0, d2
11b8: str      d0, [x19, #0xa58]
11bc: mov      x0, x7
11c0: str      x0, [x19, #0xa60]
11c4: fmov     d0, d5
11c8: str      d0, [x19, #0xa68]
11cc: ldr      x0, [x19, #0xa20]
11d0: lsr      x3, x0, #48
11d4: mov      x10, #0xfff1
11d8: cmp      x3, x10
11dc: b.hi     0x100dc991c
11e0: mov      x10, #0xfff1
11e4: cmp      x3, x10
11e8: b.ne     0x100dc920c
11ec: lsl      x0, x0, #16
11f0: asr      x0, x0, #16
11f4: scvtf    d0, x0
11f8: b        0x100dc9210
11fc: fmov     d0, x0
1200: str      d0, [x19, #0xa70]
1204: ldr      x0, [x19, #0xa40]
1208: mov      x21, x0
120c: ldr      x0, [x19, #0xa48]
1210: mov      x22, x0
1214: ldr      x0, [x19, #0xa50]
1218: mov      x23, x0
121c: ldr      d0, [x19, #0xa58]
1220: fmov     d3, d0
1224: ldr      x0, [x19, #0xa60]
1228: str      x0, [x19, #0x9b0]
122c: ldr      d0, [x19, #0xa68]
1230: fmov     d4, d0
1234: ldr      d0, [x19, #0xa70]
1238: fmov     d6, d0
123c: fadd     d2, d4, d6
1240: fadd     d5, d3, d2
1244: mov      x0, x21
1248: lsr      x3, x0, #48
124c: mov      x10, #0xfff9
1250: cmp      x3, x10
1254: b.ne     0x100dc992c
1258: and      x0, x0, #0xffffffffffff
125c: cbz      x0, 0x100dc992c
1260: ldr      x1, [x19, #0x9b0]
1264: ldr      w2, [x0]
1268: mov      x10, #0x8000
126c: movk     x10, #0x503f, lsl #16
1270: and      x3, x2, x10
1274: cmp      x3, #0x20, lsl #12
1278: b.ne     0x100dc992c
127c: ldr      w3, [x0, #0x1c]
1280: cmp      x1, x3
1284: b.hs     0x100dc992c
1288: ldr      w3, [x0, #0x38]
128c: cmp      x1, x3
1290: b.hs     0x100dc992c
1294: ldr      x2, [x0, #0x28]
1298: cbnz     x2, 0x100dc92bc
129c: ldr      w3, [x0, #0x3c]
12a0: cbz      x3, 0x100dc992c
12a4: add      x2, x0, #0x40
12a8: b        0x100dc92c8
12ac: ldr      w3, [x0, #0x14]
12b0: lsl      x3, x3, #3
12b4: add      x2, x2, x3
12b8: lsl      x1, x1, #3
12bc: add      x2, x2, x1
12c0: mov      x4, x2
12c4: mov      x2, x4
12c8: ldr      x0, [x2]
12cc: lsr      x3, x0, #48
12d0: mov      x10, #0xfff1
12d4: cmp      x3, x10
12d8: b.hi     0x100dc992c
12dc: str      x0, [x19, #0xa28]
12e0: mov      x0, x21
12e4: str      x0, [x19, #0xa40]
12e8: mov      x0, x22
12ec: str      x0, [x19, #0xa48]
12f0: mov      x0, x23
12f4: str      x0, [x19, #0xa50]
12f8: fmov     d0, d5
12fc: str      d0, [x19, #0xa58]
1300: ldr      x0, [x19, #0x9b0]
1304: str      x0, [x19, #0xa60]
1308: ldr      x0, [x19, #0x9b0]
130c: scvtf    d0, x0
1310: str      d0, [x19, #0xa68]
1314: ldr      x0, [x19, #0xa28]
1318: lsr      x3, x0, #48
131c: mov      x10, #0xfff1
1320: cmp      x3, x10
1324: b.hi     0x100dc993c
1328: mov      x10, #0xfff1
132c: cmp      x3, x10
1330: b.ne     0x100dc9354
1334: lsl      x0, x0, #16
1338: asr      x0, x0, #16
133c: scvtf    d0, x0
1340: b        0x100dc9358
1344: fmov     d0, x0
1348: str      d0, [x19, #0xa70]
134c: ldr      x0, [x19, #0xa40]
1350: mov      x4, x0
1354: ldr      x0, [x19, #0xa48]
1358: mov      x5, x0
135c: ldr      x0, [x19, #0xa50]
1360: mov      x6, x0
1364: ldr      d0, [x19, #0xa58]
1368: fmov     d2, d0
136c: ldr      x0, [x19, #0xa60]
1370: mov      x7, x0
1374: ldr      d0, [x19, #0xa68]
1378: fmov     d3, d0
137c: ldr      d0, [x19, #0xa70]
1380: fmov     d4, d0
1384: orr      x0, xzr, #0x3ff0000000000000
1388: fmov     d1, x0
138c: fadd     d5, d4, d1
1390: fmov     d0, d3
1394: fcmp     d0, d0
1398: b.vs     0x100dc994c
139c: fmov     x1, d0
13a0: orr      x10, xzr, #0x8000000000000000
13a4: cmp      x1, x10
13a8: b.eq     0x100dc994c
13ac: mov      x1, #-0x3e20000000000000
13b0: fmov     d1, x1
13b4: fcmp     d0, d1
13b8: b.mi     0x100dc994c
13bc: mov      x1, #0x41e0000000000000
13c0: fmov     d1, x1
13c4: fcmp     d0, d1
13c8: b.ge     0x100dc994c
13cc: fcvtzs   x21, d0
13d0: scvtf    d1, x21
13d4: fcmp     d0, d1
13d8: b.eq     0x100dc93f0
13dc: b        0x100dc994c
13e0: sxtw     x21, w21
13e4: fmov     x22, d5
13e8: lsr      x3, x22, #48
13ec: mov      x10, #0xfff1
13f0: cmp      x3, x10
13f4: b.lo     0x100dc940c
13f8: orr      x22, xzr, #0x7ff8000000000000
13fc: mov      x0, x4
1400: lsr      x3, x0, #48
1404: mov      x10, #0xfff9
1408: cmp      x3, x10
140c: b.ne     0x100dc994c
1410: and      x0, x0, #0xffffffffffff
1414: cbz      x0, 0x100dc994c
1418: mov      x1, x21
141c: ldr      w2, [x0]
1420: mov      x10, #0x8000
1424: movk     x10, #0x703f, lsl #16
1428: and      x3, x2, x10
142c: cmp      x3, #0x20, lsl #12
1430: b.ne     0x100dc994c
1434: and      x3, x2, #0x80
1438: cbz      x3, 0x100dc994c
143c: ldr      w3, [x0, #0x4]
1440: mov      x10, #0x20
1444: movk     x10, #0x1, lsl #16
1448: and      x3, x3, x10
144c: cbnz     x3, 0x100dc994c
1450: ldr      w3, [x0, #0x1c]
1454: cmp      x1, x3
1458: b.hs     0x100dc994c
145c: ldr      w3, [x0, #0x38]
1460: cmp      x1, x3
1464: b.hs     0x100dc994c
1468: ldr      x2, [x0, #0x28]
146c: cbnz     x2, 0x100dc9490
1470: ldr      w3, [x0, #0x3c]
1474: cbz      x3, 0x100dc994c
1478: add      x2, x0, #0x40
147c: b        0x100dc949c
1480: ldr      w3, [x0, #0x14]
1484: lsl      x3, x3, #3
1488: add      x2, x2, x3
148c: lsl      x1, x1, #3
1490: add      x2, x2, x1
1494: mov      x23, x2
1498: mov      x2, x23
149c: mov      x0, x22
14a0: lsr      x3, x0, #48
14a4: mov      x10, #0xfff1
14a8: cmp      x3, x10
14ac: b.hi     0x100dc994c
14b0: ldr      x3, [x2]
14b4: lsr      x3, x3, #48
14b8: mov      x10, #0xfff1
14bc: cmp      x3, x10
14c0: b.hi     0x100dc994c
14c4: str      x0, [x2]
14c8: mov      x21, x4
14cc: mov      x22, x5
14d0: mov      x23, x6
14d4: fmov     d3, d2
14d8: mov      x0, x7
14dc: str      x0, [x19, #0x9b8]
14e0: ldr      x0, [x19, #0x9b8]
14e4: adds     w4, w0, #0x1
14e8: b.vs     0x100dc995c
14ec: sxtw     x4, w4
14f0: mov      x0, x21
14f4: str      x0, [x19, #0x9c0]
14f8: mov      x0, x22
14fc: str      x0, [x19, #0x9c8]
1500: mov      x0, x23
1504: str      x0, [x19, #0x9d0]
1508: fmov     d4, d3
150c: mov      x0, x4
1510: str      x0, [x19, #0x9d8]
1514: ldr      x0, [x19, #0x9d8]
1518: ldr      x1, [x19, #0x9c8]
151c: cmp      x0, x1
1520: b.lt     0x100dc9538
1524: b        0x100dc956c
1528: cmp      x20, #0x1
152c: b.ls     0x100dc996c
1530: sub      x20, x20, #0x1
1534: ldr      x0, [x19, #0x9c0]
1538: mov      x4, x0
153c: ldr      x0, [x19, #0x9c8]
1540: mov      x5, x0
1544: ldr      x0, [x19, #0x9d0]
1548: mov      x6, x0
154c: fmov     d2, d4
1550: ldr      x0, [x19, #0x9d8]
1554: mov      x7, x0
1558: b        0x100dc8d54
155c: ldr      x0, [x19, #0x9c8]
1560: and      x4, x0, #0x1
1564: sxtw     x4, w4
1568: mov      x0, x4
156c: scvtf    d2, x0
1570: fadd     d3, d4, d2
1574: mov      x0, x4
1578: scvtf    d2, x0
157c: fadd     d4, d3, d2
1580: mov      x0, x4
1584: scvtf    d2, x0
1588: fadd     d3, d4, d2
158c: mov      x0, x4
1590: scvtf    d2, x0
1594: fadd     d4, d3, d2
1598: mov      x0, x4
159c: scvtf    d2, x0
15a0: fadd     d3, d4, d2
15a4: mov      x0, x4
15a8: scvtf    d2, x0
15ac: fadd     d4, d3, d2
15b0: mov      x0, x4
15b4: scvtf    d2, x0
15b8: fadd     d3, d4, d2
15bc: mov      x0, x4
15c0: scvtf    d2, x0
15c4: fadd     d4, d3, d2
15c8: mov      x0, x4
15cc: scvtf    d2, x0
15d0: fadd     d3, d4, d2
15d4: mov      x0, x4
15d8: scvtf    d2, x0
15dc: fadd     d4, d3, d2
15e0: mov      x0, x4
15e4: scvtf    d2, x0
15e8: fadd     d3, d4, d2
15ec: mov      x0, x4
15f0: scvtf    d2, x0
15f4: fadd     d4, d3, d2
15f8: mov      x0, x4
15fc: scvtf    d2, x0
1600: fadd     d3, d4, d2
1604: mov      x0, x4
1608: scvtf    d2, x0
160c: fadd     d4, d3, d2
1610: mov      x0, x4
1614: scvtf    d2, x0
1618: fadd     d3, d4, d2
161c: mov      x0, x4
1620: scvtf    d2, x0
1624: fadd     d4, d3, d2
1628: mov      x0, x4
162c: scvtf    d2, x0
1630: fadd     d3, d4, d2
1634: mov      x0, x4
1638: scvtf    d2, x0
163c: fadd     d4, d3, d2
1640: mov      x0, x4
1644: scvtf    d2, x0
1648: fadd     d3, d4, d2
164c: mov      x0, x4
1650: scvtf    d2, x0
1654: fadd     d4, d3, d2
1658: mov      x0, x4
165c: scvtf    d2, x0
1660: fadd     d3, d4, d2
1664: mov      x0, x4
1668: scvtf    d2, x0
166c: fadd     d4, d3, d2
1670: mov      x0, x4
1674: scvtf    d2, x0
1678: fadd     d3, d4, d2
167c: mov      x0, x4
1680: scvtf    d2, x0
1684: fadd     d4, d3, d2
1688: mov      x0, x4
168c: scvtf    d2, x0
1690: fadd     d3, d4, d2
1694: mov      x0, x4
1698: scvtf    d2, x0
169c: fadd     d4, d3, d2
16a0: mov      x0, x4
16a4: scvtf    d2, x0
16a8: fadd     d3, d4, d2
16ac: mov      x0, x4
16b0: scvtf    d2, x0
16b4: fadd     d4, d3, d2
16b8: mov      x0, x4
16bc: scvtf    d2, x0
16c0: fadd     d3, d4, d2
16c4: mov      x0, x4
16c8: scvtf    d2, x0
16cc: fadd     d4, d3, d2
16d0: mov      x0, x4
16d4: scvtf    d2, x0
16d8: fadd     d3, d4, d2
16dc: mov      x0, x4
16e0: scvtf    d2, x0
16e4: fadd     d4, d3, d2
16e8: mov      x0, x4
16ec: scvtf    d2, x0
16f0: fadd     d3, d4, d2
16f4: mov      x0, x4
16f8: scvtf    d2, x0
16fc: fadd     d4, d3, d2
1700: mov      x0, x4
1704: scvtf    d2, x0
1708: fadd     d3, d4, d2
170c: mov      x0, x4
1710: scvtf    d2, x0
1714: fadd     d4, d3, d2
1718: mov      x0, x4
171c: scvtf    d2, x0
1720: fadd     d3, d4, d2
1724: mov      x0, x4
1728: scvtf    d2, x0
172c: fadd     d4, d3, d2
1730: mov      x0, x4
1734: scvtf    d2, x0
1738: fadd     d3, d4, d2
173c: mov      x0, x4
1740: scvtf    d2, x0
1744: fadd     d4, d3, d2
1748: mov      x0, x4
174c: scvtf    d2, x0
1750: fadd     d3, d4, d2
1754: mov      x0, x4
1758: scvtf    d2, x0
175c: fadd     d4, d3, d2
1760: mov      x0, x4
1764: scvtf    d2, x0
1768: fadd     d3, d4, d2
176c: mov      x0, x4
1770: scvtf    d2, x0
1774: fadd     d4, d3, d2
1778: mov      x0, x4
177c: scvtf    d2, x0
1780: fadd     d3, d4, d2
1784: mov      x0, x4
1788: scvtf    d2, x0
178c: fadd     d4, d3, d2
1790: mov      x0, x4
1794: scvtf    d2, x0
1798: fadd     d3, d4, d2
179c: mov      x0, x4
17a0: scvtf    d2, x0
17a4: fadd     d4, d3, d2
17a8: mov      x0, x4
17ac: scvtf    d2, x0
17b0: fadd     d3, d4, d2
17b4: mov      x0, x4
17b8: scvtf    d2, x0
17bc: fadd     d4, d3, d2
17c0: mov      x0, x4
17c4: scvtf    d2, x0
17c8: fadd     d3, d4, d2
17cc: mov      x0, x4
17d0: scvtf    d2, x0
17d4: fadd     d4, d3, d2
17d8: mov      x0, x4
17dc: scvtf    d2, x0
17e0: fadd     d3, d4, d2
17e4: mov      x0, x4
17e8: scvtf    d2, x0
17ec: fadd     d4, d3, d2
17f0: mov      x0, x4
17f4: scvtf    d2, x0
17f8: fadd     d3, d4, d2
17fc: mov      x0, x4
1800: scvtf    d2, x0
1804: fadd     d4, d3, d2
1808: mov      x0, x4
180c: scvtf    d2, x0
1810: fadd     d3, d4, d2
1814: mov      x0, x4
1818: scvtf    d2, x0
181c: fadd     d4, d3, d2
1820: mov      x0, x4
1824: scvtf    d2, x0
1828: fadd     d3, d4, d2
182c: mov      x0, x4
1830: scvtf    d2, x0
1834: fadd     d4, d3, d2
1838: mov      x0, x4
183c: scvtf    d2, x0
1840: fadd     d3, d4, d2
1844: mov      x0, x4
1848: scvtf    d2, x0
184c: fadd     d4, d3, d2
1850: mov      x0, x4
1854: scvtf    d2, x0
1858: fadd     d3, d4, d2
185c: mov      x0, x4
1860: scvtf    d2, x0
1864: fadd     d4, d3, d2
1868: mov      x0, x4
186c: scvtf    d2, x0
1870: fadd     d3, d4, d2
1874: mov      x0, x4
1878: scvtf    d2, x0
187c: fadd     d4, d3, d2
1880: mov      x0, x4
1884: scvtf    d2, x0
1888: fadd     d3, d4, d2
188c: mov      x0, x4
1890: scvtf    d2, x0
1894: fadd     d4, d3, d2
1898: mov      x0, x4
189c: scvtf    d2, x0
18a0: fadd     d3, d4, d2
18a4: mov      x0, x4
18a8: scvtf    d2, x0
18ac: fadd     d4, d3, d2
18b0: mov      x0, x4
18b4: scvtf    d2, x0
18b8: fadd     d3, d4, d2
18bc: mov      x0, x4
18c0: scvtf    d2, x0
18c4: fadd     d4, d3, d2
18c8: b        0x100dc997c
18cc: mov      x0, #0x9010
18d0: movk     x0, #0x155, lsl #16
18d4: movk     x0, #0x1, lsl #32
18d8: b        0x100dc998c
18dc: mov      x0, #0xd8b0
18e0: movk     x0, #0x155, lsl #16
18e4: movk     x0, #0x1, lsl #32
18e8: b        0x100dc998c
18ec: mov      x0, #0xd8d0
18f0: movk     x0, #0x155, lsl #16
18f4: movk     x0, #0x1, lsl #32
18f8: b        0x100dc998c
18fc: mov      x0, #0x4000
1900: movk     x0, #0x90d2, lsl #16
1904: movk     x0, #0x76, lsl #32
1908: b        0x100dc998c
190c: mov      x0, #0x4020
1910: movk     x0, #0x90d2, lsl #16
1914: movk     x0, #0x76, lsl #32
1918: b        0x100dc998c
191c: mov      x0, #0x4040
1920: movk     x0, #0x90d2, lsl #16
1924: movk     x0, #0x76, lsl #32
1928: b        0x100dc998c
192c: mov      x0, #0x4060
1930: movk     x0, #0x90d2, lsl #16
1934: movk     x0, #0x76, lsl #32
1938: b        0x100dc998c
193c: mov      x0, #0x4080
1940: movk     x0, #0x90d2, lsl #16
1944: movk     x0, #0x76, lsl #32
1948: b        0x100dc998c
194c: mov      x0, #0x40a0
1950: movk     x0, #0x90d2, lsl #16
1954: movk     x0, #0x76, lsl #32
1958: b        0x100dc998c
195c: mov      x0, #0x40c0
1960: movk     x0, #0x90d2, lsl #16
1964: movk     x0, #0x76, lsl #32
1968: b        0x100dc998c
196c: mov      x0, #0x40e0
1970: movk     x0, #0x90d2, lsl #16
1974: movk     x0, #0x76, lsl #32
1978: b        0x100dc998c
197c: ldr      x1, [x19, #0x9a0]
1980: ldr      x2, [x1, #0x70]
1984: str      x4, [x2]
1988: str      x21, [x2, #0x8]
198c: str      x5, [x2, #0x10]
1990: str      x6, [x2, #0x18]
1994: str      x7, [x2, #0x20]
1998: str      d2, [x2, #0x28]
199c: str      x22, [x2, #0x30]
19a0: str      x23, [x2, #0x38]
19a4: str      d3, [x2, #0x40]
19a8: str      d4, [x2, #0x48]
19ac: str      d5, [x2, #0x50]
19b0: str      d6, [x2, #0x58]
19b4: str      x20, [x19, #0x398]
19b8: mov      x1, x0
19bc: ldr      x0, [x19, #0x9a0]
19c0: bl       0x100bd9c5c
19c4: ldp      x29, x30, [sp]
19c8: ldp      x19, x20, [sp, #0x30]
19cc: ldp      x21, x22, [sp, #0x20]
19d0: ldr      x23, [sp, #0x18]
19d4: add      sp, sp, #0x40
19d8: ret      
