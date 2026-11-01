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
0058: mov      x6, x0
005c: ldr      x0, [x19, #0x9a0]
0060: ldr      x0, [x0, #0x50]
0064: ldr      x0, [x0, #0x20]
0068: mov      x4, x0
006c: ldr      x0, [x19, #0x9a0]
0070: ldr      x0, [x0, #0x50]
0074: ldr      x0, [x0, #0x28]
0078: mov      x5, x0
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
00b0: cbnz     x0, 0x100568530
00b4: mov      x4, x7
00b8: mov      x0, x21
00bc: lsr      x3, x0, #48
00c0: mov      x10, #0xfff1
00c4: cmp      x3, x10
00c8: b.eq     0x100568510
00cc: mov      x10, #0xfff1
00d0: cmp      x3, x10
00d4: b.hi     0x1005691e8
00d8: fmov     d0, x0
00dc: fcmp     d0, d0
00e0: b.vs     0x1005691e8
00e4: mov      x1, #-0x3e20000000000000
00e8: fmov     d1, x1
00ec: fcmp     d0, d1
00f0: b.mi     0x1005691e8
00f4: mov      x1, #0x41e0000000000000
00f8: fmov     d1, x1
00fc: fcmp     d0, d1
0100: b.ge     0x1005691e8
0104: lsl      x3, x0, #1
0108: cbnz     x3, 0x1005684f4
010c: cmp      x0, #0x0
0110: b.lt     0x1005691e8
0114: fcvtzs   x5, d0
0118: scvtf    d1, x5
011c: fcmp     d0, d1
0120: cset     x9, ne
0124: ccmp     x9, #0x0, #0x4, vc
0128: b.ne     0x1005691e8
012c: b        0x100568528
0130: sxtw     x3, w0
0134: lsl      x1, x0, #16
0138: asr      x1, x1, #16
013c: cmp      x1, x3
0140: b.ne     0x1005691e8
0144: mov      x5, x1
0148: mov      x6, x22
014c: b        0x1005691c0
0150: ldr      w0, [x19, #0x20c]
0154: cmp      x0, #0x5
0158: b.ne     0x100568608
015c: mov      x4, x7
0160: mov      x0, x21
0164: lsr      x3, x0, #48
0168: mov      x10, #0xfff1
016c: cmp      x3, x10
0170: b.eq     0x1005685b8
0174: mov      x10, #0xfff1
0178: cmp      x3, x10
017c: b.hi     0x1005691e8
0180: fmov     d0, x0
0184: fcmp     d0, d0
0188: b.vs     0x1005691e8
018c: mov      x1, #-0x3e20000000000000
0190: fmov     d1, x1
0194: fcmp     d0, d1
0198: b.mi     0x1005691e8
019c: mov      x1, #0x41e0000000000000
01a0: fmov     d1, x1
01a4: fcmp     d0, d1
01a8: b.ge     0x1005691e8
01ac: lsl      x3, x0, #1
01b0: cbnz     x3, 0x10056859c
01b4: cmp      x0, #0x0
01b8: b.lt     0x1005691e8
01bc: fcvtzs   x5, d0
01c0: scvtf    d1, x5
01c4: fcmp     d0, d1
01c8: cset     x9, ne
01cc: ccmp     x9, #0x0, #0x4, vc
01d0: b.ne     0x1005691e8
01d4: b        0x1005685d0
01d8: sxtw     x3, w0
01dc: lsl      x1, x0, #16
01e0: asr      x1, x1, #16
01e4: cmp      x1, x3
01e8: b.ne     0x1005691e8
01ec: mov      x5, x1
01f0: mov      x0, x6
01f4: lsr      x3, x0, #48
01f8: mov      x10, #0xfff1
01fc: cmp      x3, x10
0200: b.hi     0x1005691e8
0204: mov      x10, #0xfff1
0208: cmp      x3, x10
020c: b.ne     0x100568600
0210: lsl      x0, x0, #16
0214: asr      x0, x0, #16
0218: scvtf    d2, x0
021c: b        0x100568604
0220: fmov     d2, x0
0224: b        0x1005691c4
0228: b        0x1005691e8
022c: mov      x7, #0x7
0230: mov      x0, x4
0234: lsr      x3, x0, #48
0238: mov      x10, #0xfff9
023c: cmp      x3, x10
0240: b.ne     0x1005691f8
0244: and      x0, x0, #0xffffffffffff
0248: cbz      x0, 0x1005691f8
024c: mov      x1, x7
0250: ldr      w2, [x0]
0254: mov      x10, #0x8000
0258: movk     x10, #0x503f, lsl #16
025c: and      x3, x2, x10
0260: cmp      x3, #0x20, lsl #12
0264: b.ne     0x1005691f8
0268: ldr      w3, [x0, #0x1c]
026c: cmp      x1, x3
0270: b.hs     0x1005691f8
0274: ldr      w3, [x0, #0x38]
0278: cmp      x1, x3
027c: b.hs     0x1005691f8
0280: ldr      x2, [x0, #0x28]
0284: cbnz     x2, 0x100568678
0288: ldr      w3, [x0, #0x3c]
028c: cbz      x3, 0x1005691f8
0290: add      x2, x0, #0x40
0294: b        0x100568684
0298: ldr      w3, [x0, #0x14]
029c: lsl      x3, x3, #3
02a0: add      x2, x2, x3
02a4: lsl      x1, x1, #3
02a8: add      x2, x2, x1
02ac: mov      x21, x2
02b0: mov      x2, x21
02b4: ldr      x0, [x2]
02b8: lsr      x3, x0, #48
02bc: mov      x10, #0xfff1
02c0: cmp      x3, x10
02c4: b.hi     0x1005691f8
02c8: mov      x22, x0
02cc: mov      x0, x4
02d0: ldr      x3, [x19, #0x9a0]
02d4: ldr      x3, [x3, #0x70]
02d8: str      x0, [x3, #0x48]
02dc: mov      x0, x5
02e0: ldr      x3, [x19, #0x9a0]
02e4: ldr      x3, [x3, #0x70]
02e8: str      x0, [x3, #0x50]
02ec: mov      x0, x22
02f0: ldr      x3, [x19, #0x9a0]
02f4: ldr      x3, [x3, #0x70]
02f8: str      x0, [x3, #0x88]
02fc: mov      x0, x4
0300: ldr      x3, [x19, #0x9a0]
0304: ldr      x3, [x3, #0x70]
0308: str      x0, [x3, #0x48]
030c: mov      x0, x6
0310: ldr      x3, [x19, #0x9a0]
0314: ldr      x3, [x3, #0x70]
0318: str      x0, [x3, #0x58]
031c: mov      x0, x22
0320: ldr      x3, [x19, #0x9a0]
0324: ldr      x3, [x3, #0x70]
0328: str      x0, [x3, #0x88]
032c: mov      x0, x4
0330: ldr      x2, [x19, #0x9a0]
0334: ldr      x2, [x2, #0x78]
0338: mov      x9, #0x0
033c: str      w9, [x2]
0340: str      x0, [x2, #0x8]
0344: mov      x0, x5
0348: and      x0, x0, #0xffffffffffff
034c: mov      x10, #-0xf000000000000
0350: orr      x0, x0, x10
0354: ldr      x2, [x19, #0x9a0]
0358: ldr      x2, [x2, #0x78]
035c: mov      x9, #0x1
0360: str      w9, [x2, #0x10]
0364: str      x0, [x2, #0x18]
0368: mov      x0, x22
036c: ldr      x2, [x19, #0x9a0]
0370: ldr      x2, [x2, #0x78]
0374: mov      x9, #0x3
0378: str      w9, [x2, #0x20]
037c: str      x0, [x2, #0x28]
0380: mov      x0, x6
0384: ldr      x2, [x19, #0x9a0]
0388: ldr      x2, [x2, #0x78]
038c: mov      x9, #0x6
0390: str      w9, [x2, #0x30]
0394: str      x0, [x2, #0x38]
0398: mov      x0, x4
039c: ldr      x2, [x19, #0x9a0]
03a0: ldr      x2, [x2, #0x78]
03a4: mov      x9, #0x8
03a8: str      w9, [x2, #0x40]
03ac: str      x0, [x2, #0x48]
03b0: ldr      x2, [x19, #0x9a0]
03b4: mov      x9, #0x5
03b8: str      w9, [x2, #0x80]
03bc: str      x20, [x19, #0x398]
03c0: mov      x0, x19
03c4: mov      x1, #0x7c20
03c8: movk     x1, #0xbd, lsl #16
03cc: movk     x1, #0x1, lsl #32
03d0: bl       0x10026b934
03d4: cbz      x0, 0x1005687d4
03d8: ldr      w0, [x19, #0x20c]
03dc: ldp      x29, x30, [sp]
03e0: ldp      x19, x20, [sp, #0x30]
03e4: ldp      x21, x22, [sp, #0x20]
03e8: ldr      x23, [sp, #0x18]
03ec: add      sp, sp, #0x40
03f0: ret
03f4: ldr      x3, [x19, #0x9a0]
03f8: ldr      x3, [x3, #0x70]
03fc: ldr      x0, [x3, #0x48]
0400: mov      x4, x0
0404: ldr      x3, [x19, #0x9a0]
0408: ldr      x3, [x3, #0x70]
040c: ldr      x0, [x3, #0x50]
0410: mov      x5, x0
0414: ldr      x3, [x19, #0x9a0]
0418: ldr      x3, [x3, #0x70]
041c: ldr      x0, [x3, #0x88]
0420: mov      x22, x0
0424: ldr      x0, [x19, #0x9a0]
0428: ldr      x0, [x0, #0x50]
042c: ldr      x0, [x0, #0x30]
0430: mov      x7, x0
0434: mov      x6, #-0xd000000000000
0438: mov      x6, x4
043c: mov      x7, x5
0440: mov      x21, x22
0444: and      x4, x7, #0x7
0448: sxtw     x4, w4
044c: mov      x0, x6
0450: lsr      x3, x0, #48
0454: mov      x10, #0xfff9
0458: cmp      x3, x10
045c: b.ne     0x100569208
0460: and      x0, x0, #0xffffffffffff
0464: cbz      x0, 0x100569208
0468: mov      x1, x4
046c: ldr      w2, [x0]
0470: mov      x10, #0x8000
0474: movk     x10, #0x503f, lsl #16
0478: and      x3, x2, x10
047c: cmp      x3, #0x20, lsl #12
0480: b.ne     0x100569208
0484: ldr      w3, [x0, #0x1c]
0488: cmp      x1, x3
048c: b.hs     0x100569208
0490: ldr      w3, [x0, #0x38]
0494: cmp      x1, x3
0498: b.hs     0x100569208
049c: ldr      x2, [x0, #0x28]
04a0: cbnz     x2, 0x100568894
04a4: ldr      w3, [x0, #0x3c]
04a8: cbz      x3, 0x100569208
04ac: add      x2, x0, #0x40
04b0: b        0x1005688a0
04b4: ldr      w3, [x0, #0x14]
04b8: lsl      x3, x3, #3
04bc: add      x2, x2, x3
04c0: lsl      x1, x1, #3
04c4: add      x2, x2, x1
04c8: mov      x5, x2
04cc: mov      x2, x5
04d0: ldr      x0, [x2]
04d4: lsr      x3, x0, #48
04d8: mov      x10, #0xfff1
04dc: cmp      x3, x10
04e0: b.hi     0x100569208
04e4: mov      x22, x0
04e8: mov      x4, #0x0
04ec: and      x5, x7, #0x1
04f0: sxtw     x5, w5
04f4: add      w6, w4, w5
04f8: sxtw     x6, w6
04fc: add      w4, w6, w5
0500: sxtw     x4, w4
0504: add      w6, w4, w5
0508: sxtw     x6, w6
050c: add      w4, w6, w5
0510: sxtw     x4, w4
0514: add      w6, w4, w5
0518: sxtw     x6, w6
051c: add      w4, w6, w5
0520: sxtw     x4, w4
0524: add      w6, w4, w5
0528: sxtw     x6, w6
052c: add      w4, w6, w5
0530: sxtw     x4, w4
0534: add      w6, w4, w5
0538: sxtw     x6, w6
053c: add      w4, w6, w5
0540: sxtw     x4, w4
0544: add      w6, w4, w5
0548: sxtw     x6, w6
054c: add      w4, w6, w5
0550: sxtw     x4, w4
0554: add      w6, w4, w5
0558: sxtw     x6, w6
055c: add      w4, w6, w5
0560: sxtw     x4, w4
0564: add      w6, w4, w5
0568: sxtw     x6, w6
056c: add      w4, w6, w5
0570: sxtw     x4, w4
0574: add      w6, w4, w5
0578: sxtw     x6, w6
057c: add      w4, w6, w5
0580: sxtw     x4, w4
0584: add      w6, w4, w5
0588: sxtw     x6, w6
058c: add      w4, w6, w5
0590: sxtw     x4, w4
0594: add      w6, w4, w5
0598: sxtw     x6, w6
059c: add      w4, w6, w5
05a0: sxtw     x4, w4
05a4: add      w6, w4, w5
05a8: sxtw     x6, w6
05ac: add      w4, w6, w5
05b0: sxtw     x4, w4
05b4: add      w6, w4, w5
05b8: sxtw     x6, w6
05bc: add      w4, w6, w5
05c0: sxtw     x4, w4
05c4: add      w6, w4, w5
05c8: sxtw     x6, w6
05cc: add      w4, w6, w5
05d0: sxtw     x4, w4
05d4: add      w6, w4, w5
05d8: sxtw     x6, w6
05dc: add      w4, w6, w5
05e0: sxtw     x4, w4
05e4: add      w6, w4, w5
05e8: sxtw     x6, w6
05ec: add      w4, w6, w5
05f0: sxtw     x4, w4
05f4: add      w6, w4, w5
05f8: sxtw     x6, w6
05fc: add      w4, w6, w5
0600: sxtw     x4, w4
0604: add      w6, w4, w5
0608: sxtw     x6, w6
060c: add      w4, w6, w5
0610: sxtw     x4, w4
0614: add      w6, w4, w5
0618: sxtw     x6, w6
061c: add      w4, w6, w5
0620: sxtw     x4, w4
0624: add      w6, w4, w5
0628: sxtw     x6, w6
062c: add      w4, w6, w5
0630: sxtw     x4, w4
0634: add      w6, w4, w5
0638: sxtw     x6, w6
063c: add      w4, w6, w5
0640: sxtw     x4, w4
0644: add      w6, w4, w5
0648: sxtw     x6, w6
064c: add      w4, w6, w5
0650: sxtw     x4, w4
0654: add      w6, w4, w5
0658: sxtw     x6, w6
065c: add      w4, w6, w5
0660: sxtw     x4, w4
0664: add      w6, w4, w5
0668: sxtw     x6, w6
066c: add      w4, w6, w5
0670: sxtw     x4, w4
0674: add      w6, w4, w5
0678: sxtw     x6, w6
067c: add      w4, w6, w5
0680: sxtw     x4, w4
0684: add      w6, w4, w5
0688: sxtw     x6, w6
068c: add      w4, w6, w5
0690: sxtw     x4, w4
0694: add      w6, w4, w5
0698: sxtw     x6, w6
069c: add      w4, w6, w5
06a0: sxtw     x4, w4
06a4: add      w6, w4, w5
06a8: sxtw     x6, w6
06ac: add      w4, w6, w5
06b0: sxtw     x4, w4
06b4: add      w6, w4, w5
06b8: sxtw     x6, w6
06bc: add      w4, w6, w5
06c0: sxtw     x4, w4
06c4: add      w6, w4, w5
06c8: sxtw     x6, w6
06cc: add      w4, w6, w5
06d0: sxtw     x4, w4
06d4: add      w6, w4, w5
06d8: sxtw     x6, w6
06dc: add      w4, w6, w5
06e0: sxtw     x4, w4
06e4: add      w6, w4, w5
06e8: sxtw     x6, w6
06ec: add      w4, w6, w5
06f0: sxtw     x4, w4
06f4: add      w6, w4, w5
06f8: sxtw     x6, w6
06fc: add      w4, w6, w5
0700: sxtw     x4, w4
0704: add      w6, w4, w5
0708: sxtw     x6, w6
070c: add      w4, w6, w5
0710: sxtw     x4, w4
0714: add      w6, w4, w5
0718: sxtw     x6, w6
071c: add      w4, w6, w5
0720: sxtw     x4, w4
0724: add      w6, w4, w5
0728: sxtw     x6, w6
072c: add      w4, w6, w5
0730: sxtw     x4, w4
0734: add      w6, w4, w5
0738: sxtw     x6, w6
073c: add      w4, w6, w5
0740: sxtw     x4, w4
0744: add      w6, w4, w5
0748: sxtw     x6, w6
074c: add      w4, w6, w5
0750: sxtw     x4, w4
0754: add      w6, w4, w5
0758: sxtw     x6, w6
075c: add      w4, w6, w5
0760: sxtw     x4, w4
0764: add      w6, w4, w5
0768: sxtw     x6, w6
076c: add      w4, w6, w5
0770: sxtw     x4, w4
0774: add      w6, w4, w5
0778: sxtw     x6, w6
077c: add      w4, w6, w5
0780: sxtw     x4, w4
0784: add      w6, w4, w5
0788: sxtw     x6, w6
078c: add      w4, w6, w5
0790: sxtw     x4, w4
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
0d64: mov      x0, x21
0d68: lsr      x3, x0, #48
0d6c: mov      x10, #0xfff1
0d70: cmp      x3, x10
0d74: b.hi     0x100569218
0d78: mov      x10, #0xfff1
0d7c: cmp      x3, x10
0d80: b.ne     0x100569174
0d84: lsl      x0, x0, #16
0d88: asr      x0, x0, #16
0d8c: scvtf    d2, x0
0d90: b        0x100569178
0d94: fmov     d2, x0
0d98: mov      x0, x22
0d9c: lsr      x3, x0, #48
0da0: mov      x10, #0xfff1
0da4: cmp      x3, x10
0da8: b.hi     0x100569218
0dac: mov      x10, #0xfff1
0db0: cmp      x3, x10
0db4: b.ne     0x1005691a8
0db8: lsl      x0, x0, #16
0dbc: asr      x0, x0, #16
0dc0: scvtf    d3, x0
0dc4: b        0x1005691ac
0dc8: fmov     d3, x0
0dcc: fadd     d4, d2, d3
0dd0: mov      x0, x4
0dd4: scvtf    d2, x0
0dd8: fadd     d3, d4, d2
0ddc: b        0x100569228
0de0: b        0x10056860c
0de4: mov      x6, x4
0de8: mov      x7, x5
0dec: fmov     x21, d2
0df0: lsr      x3, x21, #48
0df4: mov      x10, #0xfff1
0df8: cmp      x3, x10
0dfc: b.lo     0x1005691e4
0e00: orr      x21, xzr, #0x7ff8000000000000
0e04: b        0x100568824
0e08: mov      x0, #0x6690
0e0c: movk     x0, #0xbd, lsl #16
0e10: movk     x0, #0x1, lsl #32
0e14: b        0x100569238
0e18: mov      x0, #0x66b0
0e1c: movk     x0, #0xbd, lsl #16
0e20: movk     x0, #0x1, lsl #32
0e24: b        0x100569238
0e28: mov      x0, #0x85e0
0e2c: movk     x0, #0xbd, lsl #16
0e30: movk     x0, #0x1, lsl #32
0e34: b        0x100569238
0e38: mov      x0, #0x8600
0e3c: movk     x0, #0xbd, lsl #16
0e40: movk     x0, #0x1, lsl #32
0e44: b        0x100569238
0e48: mov      x0, #0x8700
0e4c: movk     x0, #0xbd, lsl #16
0e50: movk     x0, #0x1, lsl #32
0e54: b        0x100569238
0e58: ldr      x1, [x19, #0x9a0]
0e5c: ldr      x2, [x1, #0x70]
0e60: str      x7, [x2]
0e64: str      x21, [x2, #0x8]
0e68: str      x22, [x2, #0x10]
0e6c: str      x6, [x2, #0x18]
0e70: str      x4, [x2, #0x20]
0e74: str      x5, [x2, #0x28]
0e78: str      x23, [x2, #0x30]
0e7c: str      d2, [x2, #0x38]
0e80: str      d3, [x2, #0x40]
0e84: str      d4, [x2, #0x48]
0e88: str      x20, [x19, #0x398]
0e8c: mov      x1, x0
0e90: ldr      x0, [x19, #0x9a0]
0e94: bl       0x100261148
0e98: ldp      x29, x30, [sp]
0e9c: ldp      x19, x20, [sp, #0x30]
0ea0: ldp      x21, x22, [sp, #0x20]
0ea4: ldr      x23, [sp, #0x18]
0ea8: add      sp, sp, #0x40
0eac: ret
