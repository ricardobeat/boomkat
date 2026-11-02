0000: stp      x29, x30, [sp, #-0x60]!
0004: stp      x19, x20, [sp, #0x50]
0008: stp      x21, x22, [sp, #0x40]
000c: stp      x23, x24, [sp, #0x30]
0010: stp      x25, x26, [sp, #0x20]
0014: str      x27, [sp, #0x18]
0018: mov      x29, sp
001c: mov      x19, x0
0020: mov      x20, x1
0024: ldr      x0, [x19, #0x18]
0028: ldr      x10, [x19, #0x210]
002c: cmp      x0, x10
0030: b.ne     0x10030103c
0034: ldr      x24, [x19, #0x220]
0038: ldr      x25, [x19, #0x218]
003c: ldr      x0, [x19, #0x20]
0040: ldr      x10, [x19, #0x230]
0044: cmp      x0, x10
0048: b.ne     0x10030103c
004c: ldr      x26, [x19, #0x240]
0050: ldr      x27, [x19, #0x238]
0054: ldr      x0, [x19, #0x10]
0058: ldr      x10, [x19, #0x250]
005c: cmp      x0, x10
0060: b.ne     0x10030103c
0064: ldr      x0, [x19, #0x8]
0068: ldr      x10, [x19, #0x270]
006c: cmp      x0, x10
0070: b.ne     0x10030103c
0074: ldr      x0, [x19]
0078: str      x0, [x19, #0x430]
007c: ldr      x0, [x19, #0x8]
0080: str      x0, [x19, #0x438]
0084: ldr      x0, [x19, #0x10]
0088: str      x0, [x19, #0x440]
008c: ldr      x0, [x19, #0x18]
0090: str      x0, [x19, #0x448]
0094: ldr      x0, [x19, #0x20]
0098: str      x0, [x19, #0x450]
009c: ldr      x0, [x19, #0x28]
00a0: mov      x22, x0
00a4: ldr      x0, [x19, #0x30]
00a8: str      x0, [x19, #0x458]
00ac: ldr      x0, [x19, #0x38]
00b0: str      x0, [x19, #0x460]
00b4: ldr      x0, [x19, #0x40]
00b8: str      x0, [x19, #0x468]
00bc: ldr      x0, [x19, #0x48]
00c0: str      x0, [x19, #0x470]
00c4: ldr      x0, [x19, #0x50]
00c8: str      x0, [x19, #0x478]
00cc: ldr      x0, [x19, #0x58]
00d0: str      x0, [x19, #0x480]
00d4: ldr      x0, [x19, #0x60]
00d8: str      x0, [x19, #0x488]
00dc: ldr      x0, [x19, #0x68]
00e0: mov      x4, x0
00e4: ldr      x0, [x19, #0x70]
00e8: mov      x5, x0
00ec: ldr      x0, [x19, #0x78]
00f0: mov      x6, x0
00f4: ldr      x0, [x19, #0x80]
00f8: mov      x7, x0
00fc: ldr      x0, [x19, #0x88]
0100: mov      x21, x0
0104: ldr      x0, [x19, #0x90]
0108: mov      x23, x0
010c: ldr      x0, [x19, #0x98]
0110: str      x0, [x19, #0x490]
0114: ldr      x0, [x19, #0xa0]
0118: str      x0, [x19, #0x498]
011c: ldr      x0, [x19, #0xa8]
0120: str      x0, [x19, #0x4a0]
0124: ldr      x0, [x19, #0xb0]
0128: str      x0, [x19, #0x4a8]
012c: ldr      x0, [x19, #0xb8]
0130: str      x0, [x19, #0x4b0]
0134: ldr      x0, [x19, #0xc0]
0138: str      x0, [x19, #0x4b8]
013c: ldr      x0, [x19, #0xc8]
0140: str      x0, [x19, #0x4c0]
0144: ldr      x0, [x19, #0xd0]
0148: str      x0, [x19, #0x4c8]
014c: ldr      x0, [x19, #0xd8]
0150: str      x0, [x19, #0x4d0]
0154: ldr      x0, [x19, #0xe0]
0158: str      x0, [x19, #0x4d8]
015c: ldr      x0, [x19, #0xe8]
0160: str      x0, [x19, #0x4e0]
0164: ldr      x0, [x19, #0xf0]
0168: str      x0, [x19, #0x4e8]
016c: ldr      x0, [x19, #0xf8]
0170: str      x0, [x19, #0x4f0]
0174: ldr      x0, [x19, #0x100]
0178: str      x0, [x19, #0x4f8]
017c: ldr      x0, [x19, #0x108]
0180: str      x0, [x19, #0x500]
0184: ldr      x0, [x19, #0x110]
0188: str      x0, [x19, #0x508]
018c: ldr      x0, [x19, #0x118]
0190: str      x0, [x19, #0x510]
0194: ldr      x0, [x19, #0x120]
0198: str      x0, [x19, #0x518]
019c: ldr      x0, [x19, #0x128]
01a0: str      x0, [x19, #0x520]
01a4: ldr      x0, [x19, #0x130]
01a8: str      x0, [x19, #0x528]
01ac: ldr      w0, [x19, #0x20c]
01b0: cbnz     x0, 0x1002ffef0
01b4: ldr      x0, [x19, #0x430]
01b8: str      x0, [x19, #0x7a0]
01bc: ldr      x0, [x19, #0x438]
01c0: str      x0, [x19, #0x7a8]
01c4: ldr      x0, [x19, #0x440]
01c8: str      x0, [x19, #0x7b0]
01cc: ldr      x0, [x19, #0x448]
01d0: str      x0, [x19, #0x7b8]
01d4: ldr      x0, [x19, #0x450]
01d8: str      x0, [x19, #0x7c0]
01dc: mov      x0, x22
01e0: lsr      x3, x0, #48
01e4: mov      x10, #0xfff1
01e8: cmp      x3, x10
01ec: b.hi     0x10030103c
01f0: mov      x10, #0xfff1
01f4: cmp      x3, x10
01f8: b.ne     0x1002ffeb4
01fc: lsl      x0, x0, #16
0200: asr      x0, x0, #16
0204: scvtf    d0, x0
0208: b        0x1002ffeb8
020c: fmov     d0, x0
0210: str      d0, [x19, #0x7c8]
0214: ldr      x0, [x19, #0x7a0]
0218: mov      x4, x0
021c: ldr      x0, [x19, #0x7a8]
0220: mov      x5, x0
0224: ldr      x0, [x19, #0x7b0]
0228: mov      x6, x0
022c: ldr      x0, [x19, #0x7b8]
0230: mov      x7, x0
0234: ldr      x0, [x19, #0x7c0]
0238: mov      x21, x0
023c: ldr      d0, [x19, #0x7c8]
0240: fmov     d2, d0
0244: b        0x100300404
0248: ldr      w0, [x19, #0x20c]
024c: cmp      x0, #0xc
0250: b.ne     0x1003000ec
0254: ldr      x0, [x19, #0x430]
0258: str      x0, [x19, #0x7a0]
025c: ldr      x0, [x19, #0x438]
0260: str      x0, [x19, #0x7a8]
0264: ldr      x0, [x19, #0x440]
0268: str      x0, [x19, #0x7b0]
026c: ldr      x0, [x19, #0x448]
0270: str      x0, [x19, #0x7b8]
0274: ldr      x0, [x19, #0x450]
0278: str      x0, [x19, #0x7c0]
027c: ldr      x0, [x19, #0x458]
0280: lsr      x3, x0, #48
0284: mov      x10, #0xfff1
0288: cmp      x3, x10
028c: b.hi     0x10030103c
0290: mov      x10, #0xfff1
0294: cmp      x3, x10
0298: b.ne     0x1002fff54
029c: lsl      x0, x0, #16
02a0: asr      x0, x0, #16
02a4: scvtf    d0, x0
02a8: b        0x1002fff58
02ac: fmov     d0, x0
02b0: str      d0, [x19, #0x7c8]
02b4: ldr      x0, [x19, #0x460]
02b8: lsr      x3, x0, #48
02bc: mov      x10, #0xfff1
02c0: cmp      x3, x10
02c4: b.hi     0x10030103c
02c8: mov      x10, #0xfff1
02cc: cmp      x3, x10
02d0: b.ne     0x1002fff8c
02d4: lsl      x0, x0, #16
02d8: asr      x0, x0, #16
02dc: scvtf    d0, x0
02e0: b        0x1002fff90
02e4: fmov     d0, x0
02e8: str      d0, [x19, #0x7d0]
02ec: ldr      x0, [x19, #0x468]
02f0: lsr      x3, x0, #48
02f4: mov      x10, #0xfff1
02f8: cmp      x3, x10
02fc: b.hi     0x10030103c
0300: mov      x10, #0xfff1
0304: cmp      x3, x10
0308: b.ne     0x1002fffc4
030c: lsl      x0, x0, #16
0310: asr      x0, x0, #16
0314: scvtf    d0, x0
0318: b        0x1002fffc8
031c: fmov     d0, x0
0320: str      d0, [x19, #0x7d8]
0324: ldr      x0, [x19, #0x470]
0328: lsr      x3, x0, #48
032c: mov      x10, #0xfff1
0330: cmp      x3, x10
0334: b.hi     0x10030103c
0338: mov      x10, #0xfff1
033c: cmp      x3, x10
0340: b.ne     0x1002ffffc
0344: lsl      x0, x0, #16
0348: asr      x0, x0, #16
034c: scvtf    d0, x0
0350: b        0x100300000
0354: fmov     d0, x0
0358: str      d0, [x19, #0x7e0]
035c: ldr      x0, [x19, #0x478]
0360: lsr      x3, x0, #48
0364: mov      x10, #0xfff1
0368: cmp      x3, x10
036c: b.eq     0x10030007c
0370: mov      x10, #0xfff1
0374: cmp      x3, x10
0378: b.hi     0x10030103c
037c: fmov     d0, x0
0380: fcmp     d0, d0
0384: b.vs     0x10030103c
0388: mov      x1, #-0x3e20000000000000
038c: fmov     d1, x1
0390: fcmp     d0, d1
0394: b.mi     0x10030103c
0398: mov      x1, #0x41e0000000000000
039c: fmov     d1, x1
03a0: fcmp     d0, d1
03a4: b.ge     0x10030103c
03a8: lsl      x3, x0, #1
03ac: cbnz     x3, 0x100300060
03b0: cmp      x0, #0x0
03b4: b.lt     0x10030103c
03b8: fcvtzs   x0, d0
03bc: scvtf    d1, x0
03c0: fcmp     d0, d1
03c4: cset     x9, ne
03c8: ccmp     x9, #0x0, #0x4, vc
03cc: b.ne     0x10030103c
03d0: b        0x100300094
03d4: sxtw     x3, w0
03d8: lsl      x1, x0, #16
03dc: asr      x1, x1, #16
03e0: cmp      x1, x3
03e4: b.ne     0x10030103c
03e8: mov      x0, x1
03ec: str      x0, [x19, #0x7e8]
03f0: ldr      x0, [x19, #0x7a0]
03f4: mov      x4, x0
03f8: ldr      x0, [x19, #0x7a8]
03fc: mov      x5, x0
0400: ldr      x0, [x19, #0x7b0]
0404: mov      x6, x0
0408: ldr      x0, [x19, #0x7b8]
040c: mov      x7, x0
0410: ldr      x0, [x19, #0x7c0]
0414: mov      x21, x0
0418: ldr      d0, [x19, #0x7c8]
041c: fmov     d2, d0
0420: ldr      d0, [x19, #0x7d0]
0424: fmov     d3, d0
0428: ldr      d0, [x19, #0x7d8]
042c: fmov     d4, d0
0430: ldr      d0, [x19, #0x7e0]
0434: fmov     d5, d0
0438: ldr      x0, [x19, #0x7e8]
043c: mov      x22, x0
0440: b        0x100300554
0444: ldr      w0, [x19, #0x20c]
0448: cmp      x0, #0x10
044c: b.ne     0x1003003c4
0450: ldr      x0, [x19, #0x430]
0454: str      x0, [x19, #0x7a0]
0458: ldr      x0, [x19, #0x438]
045c: str      x0, [x19, #0x7a8]
0460: ldr      x0, [x19, #0x440]
0464: str      x0, [x19, #0x7b0]
0468: ldr      x0, [x19, #0x448]
046c: str      x0, [x19, #0x7b8]
0470: ldr      x0, [x19, #0x450]
0474: str      x0, [x19, #0x7c0]
0478: ldr      x0, [x19, #0x458]
047c: lsr      x3, x0, #48
0480: mov      x10, #0xfff1
0484: cmp      x3, x10
0488: b.hi     0x10030103c
048c: mov      x10, #0xfff1
0490: cmp      x3, x10
0494: b.ne     0x100300150
0498: lsl      x0, x0, #16
049c: asr      x0, x0, #16
04a0: scvtf    d0, x0
04a4: b        0x100300154
04a8: fmov     d0, x0
04ac: str      d0, [x19, #0x7c8]
04b0: ldr      x0, [x19, #0x460]
04b4: lsr      x3, x0, #48
04b8: mov      x10, #0xfff1
04bc: cmp      x3, x10
04c0: b.hi     0x10030103c
04c4: mov      x10, #0xfff1
04c8: cmp      x3, x10
04cc: b.ne     0x100300188
04d0: lsl      x0, x0, #16
04d4: asr      x0, x0, #16
04d8: scvtf    d0, x0
04dc: b        0x10030018c
04e0: fmov     d0, x0
04e4: str      d0, [x19, #0x7d0]
04e8: ldr      x0, [x19, #0x468]
04ec: lsr      x3, x0, #48
04f0: mov      x10, #0xfff1
04f4: cmp      x3, x10
04f8: b.hi     0x10030103c
04fc: mov      x10, #0xfff1
0500: cmp      x3, x10
0504: b.ne     0x1003001c0
0508: lsl      x0, x0, #16
050c: asr      x0, x0, #16
0510: scvtf    d0, x0
0514: b        0x1003001c4
0518: fmov     d0, x0
051c: str      d0, [x19, #0x7d8]
0520: ldr      x0, [x19, #0x470]
0524: lsr      x3, x0, #48
0528: mov      x10, #0xfff1
052c: cmp      x3, x10
0530: b.hi     0x10030103c
0534: mov      x10, #0xfff1
0538: cmp      x3, x10
053c: b.ne     0x1003001f8
0540: lsl      x0, x0, #16
0544: asr      x0, x0, #16
0548: scvtf    d0, x0
054c: b        0x1003001fc
0550: fmov     d0, x0
0554: str      d0, [x19, #0x7e0]
0558: ldr      x0, [x19, #0x478]
055c: lsr      x3, x0, #48
0560: mov      x10, #0xfff1
0564: cmp      x3, x10
0568: b.eq     0x100300278
056c: mov      x10, #0xfff1
0570: cmp      x3, x10
0574: b.hi     0x10030103c
0578: fmov     d0, x0
057c: fcmp     d0, d0
0580: b.vs     0x10030103c
0584: mov      x1, #-0x3e20000000000000
0588: fmov     d1, x1
058c: fcmp     d0, d1
0590: b.mi     0x10030103c
0594: mov      x1, #0x41e0000000000000
0598: fmov     d1, x1
059c: fcmp     d0, d1
05a0: b.ge     0x10030103c
05a4: lsl      x3, x0, #1
05a8: cbnz     x3, 0x10030025c
05ac: cmp      x0, #0x0
05b0: b.lt     0x10030103c
05b4: fcvtzs   x0, d0
05b8: scvtf    d1, x0
05bc: fcmp     d0, d1
05c0: cset     x9, ne
05c4: ccmp     x9, #0x0, #0x4, vc
05c8: b.ne     0x10030103c
05cc: b        0x100300290
05d0: sxtw     x3, w0
05d4: lsl      x1, x0, #16
05d8: asr      x1, x1, #16
05dc: cmp      x1, x3
05e0: b.ne     0x10030103c
05e4: mov      x0, x1
05e8: str      x0, [x19, #0x7e8]
05ec: ldr      x0, [x19, #0x480]
05f0: lsr      x3, x0, #48
05f4: mov      x10, #0xfff1
05f8: cmp      x3, x10
05fc: b.hi     0x10030103c
0600: mov      x10, #0xfff1
0604: cmp      x3, x10
0608: b.ne     0x1003002c4
060c: lsl      x0, x0, #16
0610: asr      x0, x0, #16
0614: scvtf    d0, x0
0618: b        0x1003002c8
061c: fmov     d0, x0
0620: str      d0, [x19, #0x7f0]
0624: ldr      x0, [x19, #0x488]
0628: lsr      x3, x0, #48
062c: mov      x10, #0xfff1
0630: cmp      x3, x10
0634: b.eq     0x100300344
0638: mov      x10, #0xfff1
063c: cmp      x3, x10
0640: b.hi     0x10030103c
0644: fmov     d0, x0
0648: fcmp     d0, d0
064c: b.vs     0x10030103c
0650: mov      x1, #-0x3e20000000000000
0654: fmov     d1, x1
0658: fcmp     d0, d1
065c: b.mi     0x10030103c
0660: mov      x1, #0x41e0000000000000
0664: fmov     d1, x1
0668: fcmp     d0, d1
066c: b.ge     0x10030103c
0670: lsl      x3, x0, #1
0674: cbnz     x3, 0x100300328
0678: cmp      x0, #0x0
067c: b.lt     0x10030103c
0680: fcvtzs   x0, d0
0684: scvtf    d1, x0
0688: fcmp     d0, d1
068c: cset     x9, ne
0690: ccmp     x9, #0x0, #0x4, vc
0694: b.ne     0x10030103c
0698: b        0x10030035c
069c: sxtw     x3, w0
06a0: lsl      x1, x0, #16
06a4: asr      x1, x1, #16
06a8: cmp      x1, x3
06ac: b.ne     0x10030103c
06b0: mov      x0, x1
06b4: str      x0, [x19, #0x7f8]
06b8: ldr      x0, [x19, #0x7a0]
06bc: mov      x4, x0
06c0: ldr      x0, [x19, #0x7a8]
06c4: mov      x5, x0
06c8: ldr      x0, [x19, #0x7b0]
06cc: mov      x6, x0
06d0: ldr      x0, [x19, #0x7b8]
06d4: mov      x7, x0
06d8: ldr      x0, [x19, #0x7c0]
06dc: mov      x21, x0
06e0: ldr      d0, [x19, #0x7c8]
06e4: fmov     d2, d0
06e8: ldr      d0, [x19, #0x7d0]
06ec: fmov     d3, d0
06f0: ldr      d0, [x19, #0x7d8]
06f4: fmov     d4, d0
06f8: ldr      d0, [x19, #0x7e0]
06fc: fmov     d5, d0
0700: ldr      x0, [x19, #0x7e8]
0704: mov      x22, x0
0708: ldr      d0, [x19, #0x7f0]
070c: fmov     d6, d0
0710: ldr      x0, [x19, #0x7f8]
0714: mov      x23, x0
0718: b        0x10030060c
071c: ldr      w0, [x19, #0x20c]
0720: cmp      x0, #0x4e
0724: b.ne     0x1003003d4
0728: b        0x10030100c
072c: mov      x9, #0x0
0730: str      x9, [x19, #0x390]
0734: str      x20, [x19, #0x398]
0738: ldr      w0, [x19, #0x20c]
073c: ldp      x29, x30, [sp]
0740: ldp      x19, x20, [sp, #0x50]
0744: ldp      x21, x22, [sp, #0x40]
0748: ldp      x23, x24, [sp, #0x30]
074c: ldp      x25, x26, [sp, #0x20]
0750: ldr      x27, [sp, #0x18]
0754: add      sp, sp, #0x60
0758: ret      
075c: ldr      x0, [x19, #0x310]
0760: mov      x22, x0
0764: mov      x0, x22
0768: lsr      x3, x0, #48
076c: mov      x10, #0xfff1
0770: cmp      x3, x10
0774: b.hi     0x10030106c
0778: mov      x10, #0xfff1
077c: cmp      x3, x10
0780: b.ne     0x10030043c
0784: lsl      x0, x0, #16
0788: asr      x0, x0, #16
078c: scvtf    d3, x0
0790: b        0x100300440
0794: fmov     d3, x0
0798: fmul     d4, d2, d3
079c: ldr      x0, [x19, #0x318]
07a0: str      x0, [x19, #0x530]
07a4: ldr      x0, [x19, #0x530]
07a8: lsr      x3, x0, #48
07ac: mov      x10, #0xfff1
07b0: cmp      x3, x10
07b4: b.hi     0x1003010f0
07b8: mov      x10, #0xfff1
07bc: cmp      x3, x10
07c0: b.ne     0x10030047c
07c4: lsl      x0, x0, #16
07c8: asr      x0, x0, #16
07cc: scvtf    d3, x0
07d0: b        0x100300480
07d4: fmov     d3, x0
07d8: fmul     d5, d2, d3
07dc: orr      x0, xzr, #0x3fe0000000000000
07e0: fmov     d3, x0
07e4: mov      x0, x22
07e8: lsr      x3, x0, #48
07ec: mov      x10, #0xfff1
07f0: cmp      x3, x10
07f4: b.hi     0x100301194
07f8: mov      x10, #0xfff1
07fc: cmp      x3, x10
0800: b.ne     0x1003004bc
0804: lsl      x0, x0, #16
0808: asr      x0, x0, #16
080c: scvtf    d6, x0
0810: b        0x1003004c0
0814: fmov     d6, x0
0818: fadd     d16, d6, d3
081c: ldr      x0, [x19, #0x530]
0820: lsr      x3, x0, #48
0824: mov      x10, #0xfff1
0828: cmp      x3, x10
082c: b.hi     0x100301278
0830: mov      x10, #0xfff1
0834: cmp      x3, x10
0838: b.ne     0x1003004f4
083c: lsl      x0, x0, #16
0840: asr      x0, x0, #16
0844: scvtf    d6, x0
0848: b        0x1003004f8
084c: fmov     d6, x0
0850: fadd     d17, d6, d3
0854: mov      x0, #0x1
0858: str      x0, [x19, #0x538]
085c: mov      x23, x4
0860: mov      x0, x5
0864: str      x0, [x19, #0x3f8]
0868: mov      x0, x6
086c: str      x0, [x19, #0x400]
0870: mov      x0, x7
0874: str      x0, [x19, #0x408]
0878: mov      x0, x21
087c: str      x0, [x19, #0x410]
0880: fmov     d6, d4
0884: fmov     d7, d5
0888: fmov     d0, d16
088c: str      d0, [x19, #0x418]
0890: fmov     d0, d17
0894: str      d0, [x19, #0x420]
0898: ldr      x0, [x19, #0x538]
089c: str      x0, [x19, #0x428]
08a0: ldr      x0, [x19, #0x530]
08a4: mov      x22, x0
08a8: b        0x100300e20
08ac: ldr      x0, [x19, #0x320]
08b0: mov      x23, x0
08b4: mov      x0, x22
08b8: scvtf    d6, x0
08bc: mov      x0, x23
08c0: lsr      x3, x0, #48
08c4: mov      x10, #0xfff1
08c8: cmp      x3, x10
08cc: b.hi     0x10030137c
08d0: mov      x10, #0xfff1
08d4: cmp      x3, x10
08d8: b.ne     0x100300594
08dc: lsl      x0, x0, #16
08e0: asr      x0, x0, #16
08e4: scvtf    d7, x0
08e8: b        0x100300598
08ec: fmov     d7, x0
08f0: fmul     d0, d6, d7
08f4: str      d0, [x19, #0x540]
08f8: mov      x0, #0x1
08fc: str      x0, [x19, #0x548]
0900: mov      x0, x4
0904: str      x0, [x19, #0x3a0]
0908: mov      x0, x5
090c: str      x0, [x19, #0x3a8]
0910: mov      x0, x6
0914: str      x0, [x19, #0x3b0]
0918: mov      x0, x7
091c: str      x0, [x19, #0x3b8]
0920: mov      x0, x21
0924: str      x0, [x19, #0x3c0]
0928: fmov     d16, d2
092c: fmov     d17, d3
0930: fmov     d0, d4
0934: str      d0, [x19, #0x3c8]
0938: fmov     d0, d5
093c: str      d0, [x19, #0x3d0]
0940: mov      x0, x22
0944: str      x0, [x19, #0x3d8]
0948: ldr      d0, [x19, #0x540]
094c: str      d0, [x19, #0x3e0]
0950: ldr      x0, [x19, #0x548]
0954: str      x0, [x19, #0x3e8]
0958: mov      x0, x23
095c: str      x0, [x19, #0x3f0]
0960: b        0x100300d00
0964: orr      x0, xzr, #0x3ff0000000000000
0968: fmov     d1, x0
096c: fadd     d0, d6, d1
0970: str      d0, [x19, #0x550]
0974: ldr      d0, [x19, #0x550]
0978: fcmp     d0, d0
097c: b.vs     0x100301474
0980: fmov     x1, d0
0984: orr      x10, xzr, #0x8000000000000000
0988: cmp      x1, x10
098c: b.eq     0x100301474
0990: mov      x1, #-0x3e20000000000000
0994: fmov     d1, x1
0998: fcmp     d0, d1
099c: b.mi     0x100301474
09a0: mov      x1, #0x41e0000000000000
09a4: fmov     d1, x1
09a8: fcmp     d0, d1
09ac: b.ge     0x100301474
09b0: fcvtzs   x0, d0
09b4: scvtf    d1, x0
09b8: fcmp     d0, d1
09bc: b.eq     0x10030066c
09c0: b        0x100301474
09c4: sxtw     x0, w0
09c8: str      x0, [x19, #0x558]
09cc: ldr      x1, [x19, #0x558]
09d0: cmp      x1, x24
09d4: b.hs     0x100301474
09d8: lsl      x1, x1, #3
09dc: add      x2, x25, x1
09e0: ldr      x0, [x2]
09e4: lsr      x3, x0, #48
09e8: mov      x10, #0xfff1
09ec: cmp      x3, x10
09f0: b.hs     0x100301474
09f4: fmov     d6, x0
09f8: fmul     d7, d2, d6
09fc: mov      x0, x23
0a00: scvtf    d16, x0
0a04: fsub     d17, d16, d7
0a08: ldr      x1, [x19, #0x558]
0a0c: cmp      x1, x26
0a10: b.hs     0x100301594
0a14: lsl      x1, x1, #3
0a18: add      x2, x27, x1
0a1c: ldr      x0, [x2]
0a20: lsr      x3, x0, #48
0a24: mov      x10, #0xfff1
0a28: cmp      x3, x10
0a2c: b.hs     0x100301594
0a30: fmov     d16, x0
0a34: fmul     d0, d3, d16
0a38: str      d0, [x19, #0x560]
0a3c: mov      x0, x22
0a40: scvtf    d6, x0
0a44: ldr      d1, [x19, #0x560]
0a48: fsub     d0, d6, d1
0a4c: str      d0, [x19, #0x568]
0a50: orr      x0, xzr, #0x3fe0000000000000
0a54: fmov     d0, x0
0a58: str      d0, [x19, #0x570]
0a5c: fmov     d0, d17
0a60: ldr      d1, [x19, #0x570]
0a64: fcmp     d0, d1
0a68: b.pl     0x100300718
0a6c: b        0x10030071c
0a70: b        0x100300728
0a74: ldr      d0, [x19, #0x570]
0a78: fmov     d6, d0
0a7c: b        0x100300748
0a80: fmov     d0, d17
0a84: fmov     d1, d4
0a88: fcmp     d0, d1
0a8c: b.le     0x10030073c
0a90: b        0x100300744
0a94: fmov     d6, d17
0a98: b        0x100300748
0a9c: fmov     d6, d4
0aa0: fmov     d0, d6
0aa4: fcmp     d0, d0
0aa8: b.vs     0x100301718
0aac: mov      x1, #-0x3e20000000000000
0ab0: fmov     d1, x1
0ab4: fcmp     d0, d1
0ab8: b.mi     0x100301718
0abc: mov      x1, #0x41e0000000000000
0ac0: fmov     d1, x1
0ac4: fcmp     d0, d1
0ac8: b.ge     0x100301718
0acc: fcvtzs   x0, d0
0ad0: sxtw     x0, w0
0ad4: str      x0, [x19, #0x578]
0ad8: ldr      x0, [x19, #0x578]
0adc: orr      x0, x0, xzr
0ae0: sxtw     x0, w0
0ae4: str      x0, [x19, #0x580]
0ae8: ldr      x0, [x19, #0x580]
0aec: adds     w0, w0, #0x1
0af0: b.vs     0x1003018bc
0af4: sxtw     x0, w0
0af8: str      x0, [x19, #0x588]
0afc: ldr      d0, [x19, #0x568]
0b00: ldr      d1, [x19, #0x570]
0b04: fcmp     d0, d1
0b08: b.pl     0x1003007b8
0b0c: b        0x1003007bc
0b10: b        0x1003007c8
0b14: ldr      d0, [x19, #0x570]
0b18: fmov     d7, d0
0b1c: b        0x1003007ec
0b20: ldr      d0, [x19, #0x568]
0b24: fmov     d1, d5
0b28: fcmp     d0, d1
0b2c: b.le     0x1003007dc
0b30: b        0x1003007e8
0b34: ldr      d0, [x19, #0x568]
0b38: fmov     d7, d0
0b3c: b        0x1003007ec
0b40: fmov     d7, d5
0b44: fmov     d0, d7
0b48: fcmp     d0, d0
0b4c: b.vs     0x100301a74
0b50: mov      x1, #-0x3e20000000000000
0b54: fmov     d1, x1
0b58: fcmp     d0, d1
0b5c: b.mi     0x100301a74
0b60: mov      x1, #0x41e0000000000000
0b64: fmov     d1, x1
0b68: fcmp     d0, d1
0b6c: b.ge     0x100301a74
0b70: fcvtzs   x0, d0
0b74: sxtw     x0, w0
0b78: str      x0, [x19, #0x590]
0b7c: ldr      x0, [x19, #0x590]
0b80: orr      x0, x0, xzr
0b84: sxtw     x0, w0
0b88: str      x0, [x19, #0x598]
0b8c: ldr      x0, [x19, #0x598]
0b90: adds     w0, w0, #0x1
0b94: b.vs     0x100301c40
0b98: sxtw     x0, w0
0b9c: str      x0, [x19, #0x5a0]
0ba0: ldr      x0, [x19, #0x580]
0ba4: scvtf    d16, x0
0ba8: fsub     d0, d6, d16
0bac: str      d0, [x19, #0x5a8]
0bb0: mov      x0, #0x1
0bb4: str      x0, [x19, #0x5b0]
0bb8: ldr      x0, [x19, #0x5b0]
0bbc: scvtf    d17, x0
0bc0: ldr      d1, [x19, #0x5a8]
0bc4: fsub     d0, d17, d1
0bc8: str      d0, [x19, #0x5b8]
0bcc: ldr      x0, [x19, #0x598]
0bd0: scvtf    d17, x0
0bd4: fsub     d0, d7, d17
0bd8: str      d0, [x19, #0x5c0]
0bdc: ldr      x0, [x19, #0x5b0]
0be0: scvtf    d0, x0
0be4: str      d0, [x19, #0x5c8]
0be8: ldr      d0, [x19, #0x5c8]
0bec: ldr      d1, [x19, #0x5c0]
0bf0: fsub     d0, d0, d1
0bf4: str      d0, [x19, #0x5d0]
0bf8: ldr      x0, [x19, #0x320]
0bfc: str      x0, [x19, #0x5d8]
0c00: ldr      x0, [x19, #0x5d8]
0c04: lsr      x3, x0, #48
0c08: mov      x10, #0xfff1
0c0c: cmp      x3, x10
0c10: b.hi     0x100301e20
0c14: mov      x10, #0xfff1
0c18: cmp      x3, x10
0c1c: b.ne     0x1003008d8
0c20: lsl      x0, x0, #16
0c24: asr      x0, x0, #16
0c28: scvtf    d0, x0
0c2c: b        0x1003008dc
0c30: fmov     d0, x0
0c34: str      d0, [x19, #0x5e0]
0c38: ldr      d1, [x19, #0x5e0]
0c3c: fmul     d0, d17, d1
0c40: str      d0, [x19, #0x5e8]
0c44: ldr      x0, [x19, #0x5a0]
0c48: scvtf    d17, x0
0c4c: ldr      x0, [x19, #0x5d8]
0c50: lsr      x3, x0, #48
0c54: mov      x10, #0xfff1
0c58: cmp      x3, x10
0c5c: b.hi     0x10030207c
0c60: mov      x10, #0xfff1
0c64: cmp      x3, x10
0c68: b.ne     0x100300924
0c6c: lsl      x0, x0, #16
0c70: asr      x0, x0, #16
0c74: scvtf    d0, x0
0c78: b        0x100300928
0c7c: fmov     d0, x0
0c80: str      d0, [x19, #0x5f0]
0c84: ldr      d1, [x19, #0x5f0]
0c88: fmul     d0, d17, d1
0c8c: str      d0, [x19, #0x5f8]
0c90: ldr      d1, [x19, #0x5e8]
0c94: fadd     d0, d16, d1
0c98: str      d0, [x19, #0x600]
0c9c: ldr      d0, [x19, #0x600]
0ca0: fcmp     d0, d0
0ca4: b.vs     0x1003022f8
0ca8: fmov     x1, d0
0cac: orr      x10, xzr, #0x8000000000000000
0cb0: cmp      x1, x10
0cb4: b.eq     0x1003022f8
0cb8: mov      x1, #-0x3e20000000000000
0cbc: fmov     d1, x1
0cc0: fcmp     d0, d1
0cc4: b.mi     0x1003022f8
0cc8: mov      x1, #0x41e0000000000000
0ccc: fmov     d1, x1
0cd0: fcmp     d0, d1
0cd4: b.ge     0x1003022f8
0cd8: fcvtzs   x0, d0
0cdc: scvtf    d1, x0
0ce0: fcmp     d0, d1
0ce4: b.eq     0x100300994
0ce8: b        0x1003022f8
0cec: sxtw     x0, w0
0cf0: str      x0, [x19, #0x608]
0cf4: ldr      x1, [x19, #0x608]
0cf8: ldr      x10, [x19, #0x260]
0cfc: cmp      x1, x10
0d00: b.hs     0x1003022f8
0d04: lsl      x1, x1, #3
0d08: ldr      x2, [x19, #0x258]
0d0c: add      x2, x2, x1
0d10: ldr      x0, [x2]
0d14: lsr      x3, x0, #48
0d18: mov      x10, #0xfff1
0d1c: cmp      x3, x10
0d20: b.hs     0x1003022f8
0d24: fmov     d0, x0
0d28: str      d0, [x19, #0x610]
0d2c: ldr      d0, [x19, #0x5d0]
0d30: ldr      d1, [x19, #0x610]
0d34: fmul     d17, d0, d1
0d38: ldr      d1, [x19, #0x5f8]
0d3c: fadd     d0, d16, d1
0d40: str      d0, [x19, #0x618]
0d44: ldr      d0, [x19, #0x618]
0d48: fcmp     d0, d0
0d4c: b.vs     0x1003025cc
0d50: fmov     x1, d0
0d54: orr      x10, xzr, #0x8000000000000000
0d58: cmp      x1, x10
0d5c: b.eq     0x1003025cc
0d60: mov      x1, #-0x3e20000000000000
0d64: fmov     d1, x1
0d68: fcmp     d0, d1
0d6c: b.mi     0x1003025cc
0d70: mov      x1, #0x41e0000000000000
0d74: fmov     d1, x1
0d78: fcmp     d0, d1
0d7c: b.ge     0x1003025cc
0d80: fcvtzs   x0, d0
0d84: scvtf    d1, x0
0d88: fcmp     d0, d1
0d8c: b.eq     0x100300a3c
0d90: b        0x1003025cc
0d94: sxtw     x0, w0
0d98: str      x0, [x19, #0x620]
0d9c: ldr      x1, [x19, #0x620]
0da0: ldr      x10, [x19, #0x260]
0da4: cmp      x1, x10
0da8: b.hs     0x1003025cc
0dac: lsl      x1, x1, #3
0db0: ldr      x2, [x19, #0x258]
0db4: add      x2, x2, x1
0db8: ldr      x0, [x2]
0dbc: lsr      x3, x0, #48
0dc0: mov      x10, #0xfff1
0dc4: cmp      x3, x10
0dc8: b.hs     0x1003025cc
0dcc: fmov     d0, x0
0dd0: str      d0, [x19, #0x628]
0dd4: ldr      d0, [x19, #0x5c0]
0dd8: ldr      d1, [x19, #0x628]
0ddc: fmul     d16, d0, d1
0de0: fadd     d0, d17, d16
0de4: str      d0, [x19, #0x630]
0de8: ldr      d0, [x19, #0x5b8]
0dec: ldr      d1, [x19, #0x630]
0df0: fmul     d17, d0, d1
0df4: ldr      x0, [x19, #0x588]
0df8: scvtf    d16, x0
0dfc: ldr      d1, [x19, #0x5e8]
0e00: fadd     d0, d16, d1
0e04: str      d0, [x19, #0x638]
0e08: ldr      d0, [x19, #0x638]
0e0c: fcmp     d0, d0
0e10: b.vs     0x100302900
0e14: fmov     x1, d0
0e18: orr      x10, xzr, #0x8000000000000000
0e1c: cmp      x1, x10
0e20: b.eq     0x100302900
0e24: mov      x1, #-0x3e20000000000000
0e28: fmov     d1, x1
0e2c: fcmp     d0, d1
0e30: b.mi     0x100302900
0e34: mov      x1, #0x41e0000000000000
0e38: fmov     d1, x1
0e3c: fcmp     d0, d1
0e40: b.ge     0x100302900
0e44: fcvtzs   x0, d0
0e48: scvtf    d1, x0
0e4c: fcmp     d0, d1
0e50: b.eq     0x100300b00
0e54: b        0x100302900
0e58: sxtw     x0, w0
0e5c: str      x0, [x19, #0x640]
0e60: ldr      x1, [x19, #0x640]
0e64: ldr      x10, [x19, #0x260]
0e68: cmp      x1, x10
0e6c: b.hs     0x100302900
0e70: lsl      x1, x1, #3
0e74: ldr      x2, [x19, #0x258]
0e78: add      x2, x2, x1
0e7c: ldr      x0, [x2]
0e80: lsr      x3, x0, #48
0e84: mov      x10, #0xfff1
0e88: cmp      x3, x10
0e8c: b.hs     0x100302900
0e90: fmov     d0, x0
0e94: str      d0, [x19, #0x648]
0e98: ldr      d0, [x19, #0x5d0]
0e9c: ldr      d1, [x19, #0x648]
0ea0: fmul     d0, d0, d1
0ea4: str      d0, [x19, #0x650]
0ea8: ldr      d1, [x19, #0x5f8]
0eac: fadd     d0, d16, d1
0eb0: str      d0, [x19, #0x658]
0eb4: ldr      d0, [x19, #0x658]
0eb8: fcmp     d0, d0
0ebc: b.vs     0x100302c98
0ec0: fmov     x1, d0
0ec4: orr      x10, xzr, #0x8000000000000000
0ec8: cmp      x1, x10
0ecc: b.eq     0x100302c98
0ed0: mov      x1, #-0x3e20000000000000
0ed4: fmov     d1, x1
0ed8: fcmp     d0, d1
0edc: b.mi     0x100302c98
0ee0: mov      x1, #0x41e0000000000000
0ee4: fmov     d1, x1
0ee8: fcmp     d0, d1
0eec: b.ge     0x100302c98
0ef0: fcvtzs   x0, d0
0ef4: scvtf    d1, x0
0ef8: fcmp     d0, d1
0efc: b.eq     0x100300bac
0f00: b        0x100302c98
0f04: sxtw     x0, w0
0f08: str      x0, [x19, #0x660]
0f0c: ldr      x1, [x19, #0x660]
0f10: ldr      x10, [x19, #0x260]
0f14: cmp      x1, x10
0f18: b.hs     0x100302c98
0f1c: lsl      x1, x1, #3
0f20: ldr      x2, [x19, #0x258]
0f24: add      x2, x2, x1
0f28: ldr      x0, [x2]
0f2c: lsr      x3, x0, #48
0f30: mov      x10, #0xfff1
0f34: cmp      x3, x10
0f38: b.hs     0x100302c98
0f3c: fmov     d0, x0
0f40: str      d0, [x19, #0x668]
0f44: ldr      d0, [x19, #0x5c0]
0f48: ldr      d1, [x19, #0x668]
0f4c: fmul     d16, d0, d1
0f50: ldr      d0, [x19, #0x650]
0f54: fadd     d0, d0, d16
0f58: str      d0, [x19, #0x670]
0f5c: ldr      d0, [x19, #0x5a8]
0f60: ldr      d1, [x19, #0x670]
0f64: fmul     d0, d0, d1
0f68: str      d0, [x19, #0x678]
0f6c: ldr      d1, [x19, #0x678]
0f70: fadd     d0, d17, d1
0f74: str      d0, [x19, #0x680]
0f78: ldr      d0, [x19, #0x680]
0f7c: fmov     x0, d0
0f80: lsr      x3, x0, #48
0f84: mov      x10, #0xfff1
0f88: cmp      x3, x10
0f8c: b.lo     0x100300c3c
0f90: orr      x0, xzr, #0x7ff8000000000000
0f94: str      x0, [x19, #0x688]
0f98: ldr      x1, [x19, #0x558]
0f9c: ldr      x10, [x19, #0x280]
0fa0: cmp      x1, x10
0fa4: b.hs     0x100303090
0fa8: lsl      x1, x1, #3
0fac: ldr      x2, [x19, #0x278]
0fb0: add      x2, x2, x1
0fb4: ldr      x0, [x2]
0fb8: lsr      x3, x0, #48
0fbc: mov      x10, #0xfff1
0fc0: cmp      x3, x10
0fc4: b.hi     0x100303090
0fc8: ldr      x0, [x19, #0x688]
0fcc: str      x0, [x2]
0fd0: adds     w0, w23, #0x1
0fd4: b.vs     0x1003034c8
0fd8: sxtw     x0, w0
0fdc: str      x0, [x19, #0x690]
0fe0: mov      x0, x4
0fe4: str      x0, [x19, #0x3a0]
0fe8: mov      x0, x5
0fec: str      x0, [x19, #0x3a8]
0ff0: mov      x0, x6
0ff4: str      x0, [x19, #0x3b0]
0ff8: mov      x0, x7
0ffc: str      x0, [x19, #0x3b8]
1000: mov      x0, x21
1004: str      x0, [x19, #0x3c0]
1008: fmov     d16, d2
100c: fmov     d17, d3
1010: fmov     d0, d4
1014: str      d0, [x19, #0x3c8]
1018: fmov     d0, d5
101c: str      d0, [x19, #0x3d0]
1020: mov      x0, x22
1024: str      x0, [x19, #0x3d8]
1028: ldr      d0, [x19, #0x550]
102c: str      d0, [x19, #0x3e0]
1030: ldr      x0, [x19, #0x690]
1034: str      x0, [x19, #0x3e8]
1038: ldr      d0, [x19, #0x550]
103c: fmov     x0, d0
1040: lsr      x3, x0, #48
1044: mov      x10, #0xfff1
1048: cmp      x3, x10
104c: b.lo     0x100300cfc
1050: orr      x0, xzr, #0x7ff8000000000000
1054: str      x0, [x19, #0x3f0]
1058: ldr      x0, [x19, #0x310]
105c: str      x0, [x19, #0x698]
1060: ldr      x0, [x19, #0x3e8]
1064: scvtf    d2, x0
1068: ldr      x0, [x19, #0x698]
106c: lsr      x3, x0, #48
1070: mov      x10, #0xfff1
1074: cmp      x3, x10
1078: b.hi     0x100303900
107c: mov      x10, #0xfff1
1080: cmp      x3, x10
1084: b.ne     0x100300d40
1088: lsl      x0, x0, #16
108c: asr      x0, x0, #16
1090: scvtf    d3, x0
1094: b        0x100300d44
1098: fmov     d3, x0
109c: fmov     d0, d2
10a0: fmov     d1, d3
10a4: fcmp     d0, d1
10a8: b.ls     0x100300d58
10ac: b        0x100300dc0
10b0: cmp      x20, #0x1
10b4: b.ls     0x100303900
10b8: sub      x20, x20, #0x1
10bc: ldr      x0, [x19, #0x3a0]
10c0: mov      x4, x0
10c4: ldr      x0, [x19, #0x3a8]
10c8: mov      x5, x0
10cc: ldr      x0, [x19, #0x3b0]
10d0: mov      x6, x0
10d4: ldr      x0, [x19, #0x3b8]
10d8: mov      x7, x0
10dc: ldr      x0, [x19, #0x3c0]
10e0: mov      x21, x0
10e4: fmov     d2, d16
10e8: fmov     d3, d17
10ec: ldr      d0, [x19, #0x3c8]
10f0: fmov     d4, d0
10f4: ldr      d0, [x19, #0x3d0]
10f8: fmov     d5, d0
10fc: ldr      x0, [x19, #0x3d8]
1100: mov      x22, x0
1104: ldr      d0, [x19, #0x3e0]
1108: fmov     d6, d0
110c: ldr      x0, [x19, #0x3e8]
1110: mov      x23, x0
1114: b        0x10030060c
1118: ldr      x0, [x19, #0x3d8]
111c: adds     w4, w0, #0x1
1120: b.vs     0x100303a2c
1124: sxtw     x4, w4
1128: ldr      x0, [x19, #0x3a0]
112c: mov      x23, x0
1130: ldr      x0, [x19, #0x3a8]
1134: str      x0, [x19, #0x3f8]
1138: ldr      x0, [x19, #0x3b0]
113c: str      x0, [x19, #0x400]
1140: ldr      x0, [x19, #0x3b8]
1144: str      x0, [x19, #0x408]
1148: ldr      x0, [x19, #0x3c0]
114c: str      x0, [x19, #0x410]
1150: fmov     d6, d16
1154: fmov     d7, d17
1158: ldr      d0, [x19, #0x3c8]
115c: str      d0, [x19, #0x418]
1160: ldr      d0, [x19, #0x3d0]
1164: str      d0, [x19, #0x420]
1168: mov      x0, x4
116c: str      x0, [x19, #0x428]
1170: ldr      x0, [x19, #0x698]
1174: mov      x22, x0
1178: ldr      x0, [x19, #0x318]
117c: str      x0, [x19, #0x6a0]
1180: ldr      x0, [x19, #0x428]
1184: scvtf    d2, x0
1188: ldr      x0, [x19, #0x6a0]
118c: lsr      x3, x0, #48
1190: mov      x10, #0xfff1
1194: cmp      x3, x10
1198: b.hi     0x100303b58
119c: mov      x10, #0xfff1
11a0: cmp      x3, x10
11a4: b.ne     0x100300e60
11a8: lsl      x0, x0, #16
11ac: asr      x0, x0, #16
11b0: scvtf    d3, x0
11b4: b        0x100300e64
11b8: fmov     d3, x0
11bc: fmov     d0, d2
11c0: fmov     d1, d3
11c4: fcmp     d0, d1
11c8: b.ls     0x100300e7c
11cc: mov      x0, #-0xb000000000000
11d0: b        0x100300e84
11d4: mov      x0, #0x1
11d8: movk     x0, #0xfff5, lsl #48
11dc: str      x0, [x19, #0x6a8]
11e0: ldr      x0, [x19, #0x6a8]
11e4: lsr      x3, x0, #48
11e8: mov      x10, #0xfff5
11ec: cmp      x3, x10
11f0: b.ne     0x100303c50
11f4: and      x1, x0, #0xffffffffffff
11f8: cbnz     x1, 0x100300ea8
11fc: b        0x100300efc
1200: cmp      x20, #0x1
1204: b.ls     0x100303c50
1208: sub      x20, x20, #0x1
120c: mov      x4, x23
1210: ldr      x0, [x19, #0x3f8]
1214: mov      x5, x0
1218: ldr      x0, [x19, #0x400]
121c: mov      x6, x0
1220: ldr      x0, [x19, #0x408]
1224: mov      x7, x0
1228: ldr      x0, [x19, #0x410]
122c: mov      x21, x0
1230: fmov     d2, d6
1234: fmov     d3, d7
1238: ldr      d0, [x19, #0x418]
123c: fmov     d4, d0
1240: ldr      d0, [x19, #0x420]
1244: fmov     d5, d0
1248: ldr      x0, [x19, #0x428]
124c: mov      x22, x0
1250: b        0x100300554
1254: mov      x0, x23
1258: str      x0, [x19]
125c: ldr      x0, [x19, #0x3f8]
1260: str      x0, [x19, #0x8]
1264: ldr      x0, [x19, #0x400]
1268: str      x0, [x19, #0x10]
126c: ldr      x0, [x19, #0x408]
1270: str      x0, [x19, #0x18]
1274: ldr      x0, [x19, #0x410]
1278: str      x0, [x19, #0x20]
127c: fmov     d0, d6
1280: fmov     x0, d0
1284: lsr      x3, x0, #48
1288: mov      x10, #0xfff1
128c: cmp      x3, x10
1290: b.lo     0x100300f40
1294: orr      x0, xzr, #0x7ff8000000000000
1298: str      x0, [x19, #0x30]
129c: fmov     d0, d7
12a0: fmov     x0, d0
12a4: lsr      x3, x0, #48
12a8: mov      x10, #0xfff1
12ac: cmp      x3, x10
12b0: b.lo     0x100300f60
12b4: orr      x0, xzr, #0x7ff8000000000000
12b8: str      x0, [x19, #0x38]
12bc: ldr      d0, [x19, #0x418]
12c0: fmov     x0, d0
12c4: lsr      x3, x0, #48
12c8: mov      x10, #0xfff1
12cc: cmp      x3, x10
12d0: b.lo     0x100300f80
12d4: orr      x0, xzr, #0x7ff8000000000000
12d8: str      x0, [x19, #0x40]
12dc: ldr      d0, [x19, #0x420]
12e0: fmov     x0, d0
12e4: lsr      x3, x0, #48
12e8: mov      x10, #0xfff1
12ec: cmp      x3, x10
12f0: b.lo     0x100300fa0
12f4: orr      x0, xzr, #0x7ff8000000000000
12f8: str      x0, [x19, #0x48]
12fc: ldr      x0, [x19, #0x428]
1300: and      x0, x0, #0xffffffffffff
1304: mov      x10, #-0xf000000000000
1308: orr      x0, x0, x10
130c: str      x0, [x19, #0x50]
1310: ldr      x0, [x19, #0x6a0]
1314: str      x0, [x19, #0xc8]
1318: ldr      x0, [x19, #0x6a8]
131c: str      x0, [x19, #0xd0]
1320: mov      x0, x23
1324: str      x0, [x19, #0xd8]
1328: ldr      x0, [x19, #0x3f8]
132c: str      x0, [x19, #0xe0]
1330: mov      x9, #0x7df
1334: movk     x9, #0x1e00, lsl #16
1338: str      x9, [x19, #0x390]
133c: str      x20, [x19, #0x398]
1340: mov      x0, #0x4d
1344: ldp      x29, x30, [sp]
1348: ldp      x19, x20, [sp, #0x50]
134c: ldp      x21, x22, [sp, #0x40]
1350: ldp      x23, x24, [sp, #0x30]
1354: ldp      x25, x26, [sp, #0x20]
1358: ldr      x27, [sp, #0x18]
135c: add      sp, sp, #0x60
1360: ret      
1364: mov      x9, #0x0
1368: str      x9, [x19, #0x390]
136c: str      x20, [x19, #0x398]
1370: mov      x0, #0x4e
1374: ldp      x29, x30, [sp]
1378: ldp      x19, x20, [sp, #0x50]
137c: ldp      x21, x22, [sp, #0x40]
1380: ldp      x23, x24, [sp, #0x30]
1384: ldp      x25, x26, [sp, #0x20]
1388: ldr      x27, [sp, #0x18]
138c: add      sp, sp, #0x60
1390: ret      
1394: mov      x9, #0x0
1398: str      x9, [x19, #0x390]
139c: str      x20, [x19, #0x398]
13a0: ldr      w0, [x19, #0x20c]
13a4: ldp      x29, x30, [sp]
13a8: ldp      x19, x20, [sp, #0x50]
13ac: ldp      x21, x22, [sp, #0x40]
13b0: ldp      x23, x24, [sp, #0x30]
13b4: ldp      x25, x26, [sp, #0x20]
13b8: ldr      x27, [sp, #0x18]
13bc: add      sp, sp, #0x60
13c0: ret      
13c4: mov      x0, x4
13c8: str      x0, [x19]
13cc: mov      x0, x5
13d0: str      x0, [x19, #0x8]
13d4: mov      x0, x6
13d8: str      x0, [x19, #0x10]
13dc: mov      x0, x7
13e0: str      x0, [x19, #0x18]
13e4: mov      x0, x21
13e8: str      x0, [x19, #0x20]
13ec: fmov     d0, d2
13f0: fmov     x0, d0
13f4: lsr      x3, x0, #48
13f8: mov      x10, #0xfff1
13fc: cmp      x3, x10
1400: b.lo     0x1003010b0
1404: orr      x0, xzr, #0x7ff8000000000000
1408: str      x0, [x19, #0x28]
140c: mov      x0, x22
1410: str      x0, [x19, #0xc8]
1414: mov      x9, #0x3f
1418: movk     x9, #0x200, lsl #16
141c: str      x9, [x19, #0x390]
1420: str      x20, [x19, #0x398]
1424: mov      x0, #0x1
1428: ldp      x29, x30, [sp]
142c: ldp      x19, x20, [sp, #0x50]
1430: ldp      x21, x22, [sp, #0x40]
1434: ldp      x23, x24, [sp, #0x30]
1438: ldp      x25, x26, [sp, #0x20]
143c: ldr      x27, [sp, #0x18]
1440: add      sp, sp, #0x60
1444: ret      
1448: mov      x0, x4
144c: str      x0, [x19]
1450: mov      x0, x5
1454: str      x0, [x19, #0x8]
1458: mov      x0, x6
145c: str      x0, [x19, #0x10]
1460: mov      x0, x7
1464: str      x0, [x19, #0x18]
1468: mov      x0, x21
146c: str      x0, [x19, #0x20]
1470: fmov     d0, d2
1474: fmov     x0, d0
1478: lsr      x3, x0, #48
147c: mov      x10, #0xfff1
1480: cmp      x3, x10
1484: b.lo     0x100301134
1488: orr      x0, xzr, #0x7ff8000000000000
148c: str      x0, [x19, #0x28]
1490: fmov     d0, d4
1494: fmov     x0, d0
1498: lsr      x3, x0, #48
149c: mov      x10, #0xfff1
14a0: cmp      x3, x10
14a4: b.lo     0x100301154
14a8: orr      x0, xzr, #0x7ff8000000000000
14ac: str      x0, [x19, #0x30]
14b0: ldr      x0, [x19, #0x530]
14b4: str      x0, [x19, #0xc8]
14b8: mov      x9, #0x7f
14bc: movk     x9, #0x200, lsl #16
14c0: str      x9, [x19, #0x390]
14c4: str      x20, [x19, #0x398]
14c8: mov      x0, #0x3
14cc: ldp      x29, x30, [sp]
14d0: ldp      x19, x20, [sp, #0x50]
14d4: ldp      x21, x22, [sp, #0x40]
14d8: ldp      x23, x24, [sp, #0x30]
14dc: ldp      x25, x26, [sp, #0x20]
14e0: ldr      x27, [sp, #0x18]
14e4: add      sp, sp, #0x60
14e8: ret      
14ec: mov      x0, x4
14f0: str      x0, [x19]
14f4: mov      x0, x5
14f8: str      x0, [x19, #0x8]
14fc: mov      x0, x6
1500: str      x0, [x19, #0x10]
1504: mov      x0, x7
1508: str      x0, [x19, #0x18]
150c: mov      x0, x21
1510: str      x0, [x19, #0x20]
1514: fmov     d0, d2
1518: fmov     x0, d0
151c: lsr      x3, x0, #48
1520: mov      x10, #0xfff1
1524: cmp      x3, x10
1528: b.lo     0x1003011d8
152c: orr      x0, xzr, #0x7ff8000000000000
1530: str      x0, [x19, #0x28]
1534: fmov     d0, d4
1538: fmov     x0, d0
153c: lsr      x3, x0, #48
1540: mov      x10, #0xfff1
1544: cmp      x3, x10
1548: b.lo     0x1003011f8
154c: orr      x0, xzr, #0x7ff8000000000000
1550: str      x0, [x19, #0x30]
1554: fmov     d0, d5
1558: fmov     x0, d0
155c: lsr      x3, x0, #48
1560: mov      x10, #0xfff1
1564: cmp      x3, x10
1568: b.lo     0x100301218
156c: orr      x0, xzr, #0x7ff8000000000000
1570: str      x0, [x19, #0x38]
1574: mov      x0, x22
1578: str      x0, [x19, #0xc8]
157c: fmov     d0, d3
1580: fmov     x0, d0
1584: lsr      x3, x0, #48
1588: mov      x10, #0xfff1
158c: cmp      x3, x10
1590: b.lo     0x100301240
1594: orr      x0, xzr, #0x7ff8000000000000
1598: str      x0, [x19, #0xd0]
159c: mov      x9, #0xff
15a0: movk     x9, #0x600, lsl #16
15a4: str      x9, [x19, #0x390]
15a8: str      x20, [x19, #0x398]
15ac: mov      x0, #0x6
15b0: ldp      x29, x30, [sp]
15b4: ldp      x19, x20, [sp, #0x50]
15b8: ldp      x21, x22, [sp, #0x40]
15bc: ldp      x23, x24, [sp, #0x30]
15c0: ldp      x25, x26, [sp, #0x20]
15c4: ldr      x27, [sp, #0x18]
15c8: add      sp, sp, #0x60
15cc: ret      
15d0: mov      x0, x4
15d4: str      x0, [x19]
15d8: mov      x0, x5
15dc: str      x0, [x19, #0x8]
15e0: mov      x0, x6
15e4: str      x0, [x19, #0x10]
15e8: mov      x0, x7
15ec: str      x0, [x19, #0x18]
15f0: mov      x0, x21
15f4: str      x0, [x19, #0x20]
15f8: fmov     d0, d2
15fc: fmov     x0, d0
1600: lsr      x3, x0, #48
1604: mov      x10, #0xfff1
1608: cmp      x3, x10
160c: b.lo     0x1003012bc
1610: orr      x0, xzr, #0x7ff8000000000000
1614: str      x0, [x19, #0x28]
1618: fmov     d0, d4
161c: fmov     x0, d0
1620: lsr      x3, x0, #48
1624: mov      x10, #0xfff1
1628: cmp      x3, x10
162c: b.lo     0x1003012dc
1630: orr      x0, xzr, #0x7ff8000000000000
1634: str      x0, [x19, #0x30]
1638: fmov     d0, d5
163c: fmov     x0, d0
1640: lsr      x3, x0, #48
1644: mov      x10, #0xfff1
1648: cmp      x3, x10
164c: b.lo     0x1003012fc
1650: orr      x0, xzr, #0x7ff8000000000000
1654: str      x0, [x19, #0x38]
1658: fmov     d0, d16
165c: fmov     x0, d0
1660: lsr      x3, x0, #48
1664: mov      x10, #0xfff1
1668: cmp      x3, x10
166c: b.lo     0x10030131c
1670: orr      x0, xzr, #0x7ff8000000000000
1674: str      x0, [x19, #0x40]
1678: ldr      x0, [x19, #0x530]
167c: str      x0, [x19, #0xc8]
1680: fmov     d0, d3
1684: fmov     x0, d0
1688: lsr      x3, x0, #48
168c: mov      x10, #0xfff1
1690: cmp      x3, x10
1694: b.lo     0x100301344
1698: orr      x0, xzr, #0x7ff8000000000000
169c: str      x0, [x19, #0xd0]
16a0: mov      x9, #0x1ff
16a4: movk     x9, #0x600, lsl #16
16a8: str      x9, [x19, #0x390]
16ac: str      x20, [x19, #0x398]
16b0: mov      x0, #0x9
16b4: ldp      x29, x30, [sp]
16b8: ldp      x19, x20, [sp, #0x50]
16bc: ldp      x21, x22, [sp, #0x40]
16c0: ldp      x23, x24, [sp, #0x30]
16c4: ldp      x25, x26, [sp, #0x20]
16c8: ldr      x27, [sp, #0x18]
16cc: add      sp, sp, #0x60
16d0: ret      
16d4: mov      x0, x4
16d8: str      x0, [x19]
16dc: mov      x0, x5
16e0: str      x0, [x19, #0x8]
16e4: mov      x0, x6
16e8: str      x0, [x19, #0x10]
16ec: mov      x0, x7
16f0: str      x0, [x19, #0x18]
16f4: mov      x0, x21
16f8: str      x0, [x19, #0x20]
16fc: fmov     d0, d2
1700: fmov     x0, d0
1704: lsr      x3, x0, #48
1708: mov      x10, #0xfff1
170c: cmp      x3, x10
1710: b.lo     0x1003013c0
1714: orr      x0, xzr, #0x7ff8000000000000
1718: str      x0, [x19, #0x30]
171c: fmov     d0, d3
1720: fmov     x0, d0
1724: lsr      x3, x0, #48
1728: mov      x10, #0xfff1
172c: cmp      x3, x10
1730: b.lo     0x1003013e0
1734: orr      x0, xzr, #0x7ff8000000000000
1738: str      x0, [x19, #0x38]
173c: fmov     d0, d4
1740: fmov     x0, d0
1744: lsr      x3, x0, #48
1748: mov      x10, #0xfff1
174c: cmp      x3, x10
1750: b.lo     0x100301400
1754: orr      x0, xzr, #0x7ff8000000000000
1758: str      x0, [x19, #0x40]
175c: fmov     d0, d5
1760: fmov     x0, d0
1764: lsr      x3, x0, #48
1768: mov      x10, #0xfff1
176c: cmp      x3, x10
1770: b.lo     0x100301420
1774: orr      x0, xzr, #0x7ff8000000000000
1778: str      x0, [x19, #0x48]
177c: mov      x0, x22
1780: and      x0, x0, #0xffffffffffff
1784: mov      x10, #-0xf000000000000
1788: orr      x0, x0, x10
178c: str      x0, [x19, #0x50]
1790: mov      x0, x23
1794: str      x0, [x19, #0xc8]
1798: mov      x9, #0x7df
179c: movk     x9, #0x200, lsl #16
17a0: str      x9, [x19, #0x390]
17a4: str      x20, [x19, #0x398]
17a8: mov      x0, #0xd
17ac: ldp      x29, x30, [sp]
17b0: ldp      x19, x20, [sp, #0x50]
17b4: ldp      x21, x22, [sp, #0x40]
17b8: ldp      x23, x24, [sp, #0x30]
17bc: ldp      x25, x26, [sp, #0x20]
17c0: ldr      x27, [sp, #0x18]
17c4: add      sp, sp, #0x60
17c8: ret      
17cc: mov      x0, x4
17d0: str      x0, [x19]
17d4: mov      x0, x5
17d8: str      x0, [x19, #0x8]
17dc: mov      x0, x6
17e0: str      x0, [x19, #0x10]
17e4: mov      x0, x7
17e8: str      x0, [x19, #0x18]
17ec: mov      x0, x21
17f0: str      x0, [x19, #0x20]
17f4: fmov     d0, d2
17f8: fmov     x0, d0
17fc: lsr      x3, x0, #48
1800: mov      x10, #0xfff1
1804: cmp      x3, x10
1808: b.lo     0x1003014b8
180c: orr      x0, xzr, #0x7ff8000000000000
1810: str      x0, [x19, #0x30]
1814: fmov     d0, d3
1818: fmov     x0, d0
181c: lsr      x3, x0, #48
1820: mov      x10, #0xfff1
1824: cmp      x3, x10
1828: b.lo     0x1003014d8
182c: orr      x0, xzr, #0x7ff8000000000000
1830: str      x0, [x19, #0x38]
1834: fmov     d0, d4
1838: fmov     x0, d0
183c: lsr      x3, x0, #48
1840: mov      x10, #0xfff1
1844: cmp      x3, x10
1848: b.lo     0x1003014f8
184c: orr      x0, xzr, #0x7ff8000000000000
1850: str      x0, [x19, #0x40]
1854: fmov     d0, d5
1858: fmov     x0, d0
185c: lsr      x3, x0, #48
1860: mov      x10, #0xfff1
1864: cmp      x3, x10
1868: b.lo     0x100301518
186c: orr      x0, xzr, #0x7ff8000000000000
1870: str      x0, [x19, #0x48]
1874: mov      x0, x22
1878: and      x0, x0, #0xffffffffffff
187c: mov      x10, #-0xf000000000000
1880: orr      x0, x0, x10
1884: str      x0, [x19, #0x50]
1888: ldr      d0, [x19, #0x550]
188c: fmov     x0, d0
1890: lsr      x3, x0, #48
1894: mov      x10, #0xfff1
1898: cmp      x3, x10
189c: b.lo     0x10030154c
18a0: orr      x0, xzr, #0x7ff8000000000000
18a4: str      x0, [x19, #0x58]
18a8: mov      x0, x23
18ac: and      x0, x0, #0xffffffffffff
18b0: mov      x10, #-0xf000000000000
18b4: orr      x0, x0, x10
18b8: str      x0, [x19, #0x60]
18bc: mov      x9, #0x1fdf
18c0: str      x9, [x19, #0x390]
18c4: str      x20, [x19, #0x398]
18c8: mov      x0, #0x11
18cc: ldp      x29, x30, [sp]
18d0: ldp      x19, x20, [sp, #0x50]
18d4: ldp      x21, x22, [sp, #0x40]
18d8: ldp      x23, x24, [sp, #0x30]
18dc: ldp      x25, x26, [sp, #0x20]
18e0: ldr      x27, [sp, #0x18]
18e4: add      sp, sp, #0x60
18e8: ret      
18ec: mov      x0, x4
18f0: str      x0, [x19]
18f4: mov      x0, x5
18f8: str      x0, [x19, #0x8]
18fc: mov      x0, x6
1900: str      x0, [x19, #0x10]
1904: mov      x0, x7
1908: str      x0, [x19, #0x18]
190c: mov      x0, x21
1910: str      x0, [x19, #0x20]
1914: fmov     d0, d2
1918: fmov     x0, d0
191c: lsr      x3, x0, #48
1920: mov      x10, #0xfff1
1924: cmp      x3, x10
1928: b.lo     0x1003015d8
192c: orr      x0, xzr, #0x7ff8000000000000
1930: str      x0, [x19, #0x30]
1934: fmov     d0, d3
1938: fmov     x0, d0
193c: lsr      x3, x0, #48
1940: mov      x10, #0xfff1
1944: cmp      x3, x10
1948: b.lo     0x1003015f8
194c: orr      x0, xzr, #0x7ff8000000000000
1950: str      x0, [x19, #0x38]
1954: fmov     d0, d4
1958: fmov     x0, d0
195c: lsr      x3, x0, #48
1960: mov      x10, #0xfff1
1964: cmp      x3, x10
1968: b.lo     0x100301618
196c: orr      x0, xzr, #0x7ff8000000000000
1970: str      x0, [x19, #0x40]
1974: fmov     d0, d5
1978: fmov     x0, d0
197c: lsr      x3, x0, #48
1980: mov      x10, #0xfff1
1984: cmp      x3, x10
1988: b.lo     0x100301638
198c: orr      x0, xzr, #0x7ff8000000000000
1990: str      x0, [x19, #0x48]
1994: mov      x0, x22
1998: and      x0, x0, #0xffffffffffff
199c: mov      x10, #-0xf000000000000
19a0: orr      x0, x0, x10
19a4: str      x0, [x19, #0x50]
19a8: ldr      d0, [x19, #0x550]
19ac: fmov     x0, d0
19b0: lsr      x3, x0, #48
19b4: mov      x10, #0xfff1
19b8: cmp      x3, x10
19bc: b.lo     0x10030166c
19c0: orr      x0, xzr, #0x7ff8000000000000
19c4: str      x0, [x19, #0x58]
19c8: mov      x0, x23
19cc: and      x0, x0, #0xffffffffffff
19d0: mov      x10, #-0xf000000000000
19d4: orr      x0, x0, x10
19d8: str      x0, [x19, #0x60]
19dc: fmov     d0, d17
19e0: fmov     x0, d0
19e4: lsr      x3, x0, #48
19e8: mov      x10, #0xfff1
19ec: cmp      x3, x10
19f0: b.lo     0x1003016a0
19f4: orr      x0, xzr, #0x7ff8000000000000
19f8: str      x0, [x19, #0x68]
19fc: fmov     d0, d6
1a00: fmov     x0, d0
1a04: lsr      x3, x0, #48
1a08: mov      x10, #0xfff1
1a0c: cmp      x3, x10
1a10: b.lo     0x1003016c0
1a14: orr      x0, xzr, #0x7ff8000000000000
1a18: str      x0, [x19, #0xc8]
1a1c: fmov     d0, d7
1a20: fmov     x0, d0
1a24: lsr      x3, x0, #48
1a28: mov      x10, #0xfff1
1a2c: cmp      x3, x10
1a30: b.lo     0x1003016e0
1a34: orr      x0, xzr, #0x7ff8000000000000
1a38: str      x0, [x19, #0xd0]
1a3c: mov      x9, #0x3fdf
1a40: movk     x9, #0x600, lsl #16
1a44: str      x9, [x19, #0x390]
1a48: str      x20, [x19, #0x398]
1a4c: mov      x0, #0x14
1a50: ldp      x29, x30, [sp]
1a54: ldp      x19, x20, [sp, #0x50]
1a58: ldp      x21, x22, [sp, #0x40]
1a5c: ldp      x23, x24, [sp, #0x30]
1a60: ldp      x25, x26, [sp, #0x20]
1a64: ldr      x27, [sp, #0x18]
1a68: add      sp, sp, #0x60
1a6c: ret      
1a70: mov      x0, x4
1a74: str      x0, [x19]
1a78: mov      x0, x5
1a7c: str      x0, [x19, #0x8]
1a80: mov      x0, x6
1a84: str      x0, [x19, #0x10]
1a88: mov      x0, x7
1a8c: str      x0, [x19, #0x18]
1a90: mov      x0, x21
1a94: str      x0, [x19, #0x20]
1a98: fmov     d0, d2
1a9c: fmov     x0, d0
1aa0: lsr      x3, x0, #48
1aa4: mov      x10, #0xfff1
1aa8: cmp      x3, x10
1aac: b.lo     0x10030175c
1ab0: orr      x0, xzr, #0x7ff8000000000000
1ab4: str      x0, [x19, #0x30]
1ab8: fmov     d0, d3
1abc: fmov     x0, d0
1ac0: lsr      x3, x0, #48
1ac4: mov      x10, #0xfff1
1ac8: cmp      x3, x10
1acc: b.lo     0x10030177c
1ad0: orr      x0, xzr, #0x7ff8000000000000
1ad4: str      x0, [x19, #0x38]
1ad8: fmov     d0, d4
1adc: fmov     x0, d0
1ae0: lsr      x3, x0, #48
1ae4: mov      x10, #0xfff1
1ae8: cmp      x3, x10
1aec: b.lo     0x10030179c
1af0: orr      x0, xzr, #0x7ff8000000000000
1af4: str      x0, [x19, #0x40]
1af8: fmov     d0, d5
1afc: fmov     x0, d0
1b00: lsr      x3, x0, #48
1b04: mov      x10, #0xfff1
1b08: cmp      x3, x10
1b0c: b.lo     0x1003017bc
1b10: orr      x0, xzr, #0x7ff8000000000000
1b14: str      x0, [x19, #0x48]
1b18: mov      x0, x22
1b1c: and      x0, x0, #0xffffffffffff
1b20: mov      x10, #-0xf000000000000
1b24: orr      x0, x0, x10
1b28: str      x0, [x19, #0x50]
1b2c: ldr      d0, [x19, #0x550]
1b30: fmov     x0, d0
1b34: lsr      x3, x0, #48
1b38: mov      x10, #0xfff1
1b3c: cmp      x3, x10
1b40: b.lo     0x1003017f0
1b44: orr      x0, xzr, #0x7ff8000000000000
1b48: str      x0, [x19, #0x58]
1b4c: mov      x0, x23
1b50: and      x0, x0, #0xffffffffffff
1b54: mov      x10, #-0xf000000000000
1b58: orr      x0, x0, x10
1b5c: str      x0, [x19, #0x60]
1b60: fmov     d0, d6
1b64: fmov     x0, d0
1b68: lsr      x3, x0, #48
1b6c: mov      x10, #0xfff1
1b70: cmp      x3, x10
1b74: b.lo     0x100301824
1b78: orr      x0, xzr, #0x7ff8000000000000
1b7c: str      x0, [x19, #0x68]
1b80: ldr      d0, [x19, #0x568]
1b84: fmov     x0, d0
1b88: lsr      x3, x0, #48
1b8c: mov      x10, #0xfff1
1b90: cmp      x3, x10
1b94: b.lo     0x100301844
1b98: orr      x0, xzr, #0x7ff8000000000000
1b9c: str      x0, [x19, #0x70]
1ba0: ldr      d0, [x19, #0x570]
1ba4: fmov     x0, d0
1ba8: lsr      x3, x0, #48
1bac: mov      x10, #0xfff1
1bb0: cmp      x3, x10
1bb4: b.lo     0x100301864
1bb8: orr      x0, xzr, #0x7ff8000000000000
1bbc: str      x0, [x19, #0xc8]
1bc0: ldr      d0, [x19, #0x560]
1bc4: fmov     x0, d0
1bc8: lsr      x3, x0, #48
1bcc: mov      x10, #0xfff1
1bd0: cmp      x3, x10
1bd4: b.lo     0x100301884
1bd8: orr      x0, xzr, #0x7ff8000000000000
1bdc: str      x0, [x19, #0xd0]
1be0: mov      x9, #0x7fdf
1be4: movk     x9, #0x600, lsl #16
1be8: str      x9, [x19, #0x390]
1bec: str      x20, [x19, #0x398]
1bf0: mov      x0, #0x1d
1bf4: ldp      x29, x30, [sp]
1bf8: ldp      x19, x20, [sp, #0x50]
1bfc: ldp      x21, x22, [sp, #0x40]
1c00: ldp      x23, x24, [sp, #0x30]
1c04: ldp      x25, x26, [sp, #0x20]
1c08: ldr      x27, [sp, #0x18]
1c0c: add      sp, sp, #0x60
1c10: ret      
1c14: mov      x0, x4
1c18: str      x0, [x19]
1c1c: mov      x0, x5
1c20: str      x0, [x19, #0x8]
1c24: mov      x0, x6
1c28: str      x0, [x19, #0x10]
1c2c: mov      x0, x7
1c30: str      x0, [x19, #0x18]
1c34: mov      x0, x21
1c38: str      x0, [x19, #0x20]
1c3c: fmov     d0, d2
1c40: fmov     x0, d0
1c44: lsr      x3, x0, #48
1c48: mov      x10, #0xfff1
1c4c: cmp      x3, x10
1c50: b.lo     0x100301900
1c54: orr      x0, xzr, #0x7ff8000000000000
1c58: str      x0, [x19, #0x30]
1c5c: fmov     d0, d3
1c60: fmov     x0, d0
1c64: lsr      x3, x0, #48
1c68: mov      x10, #0xfff1
1c6c: cmp      x3, x10
1c70: b.lo     0x100301920
1c74: orr      x0, xzr, #0x7ff8000000000000
1c78: str      x0, [x19, #0x38]
1c7c: fmov     d0, d4
1c80: fmov     x0, d0
1c84: lsr      x3, x0, #48
1c88: mov      x10, #0xfff1
1c8c: cmp      x3, x10
1c90: b.lo     0x100301940
1c94: orr      x0, xzr, #0x7ff8000000000000
1c98: str      x0, [x19, #0x40]
1c9c: fmov     d0, d5
1ca0: fmov     x0, d0
1ca4: lsr      x3, x0, #48
1ca8: mov      x10, #0xfff1
1cac: cmp      x3, x10
1cb0: b.lo     0x100301960
1cb4: orr      x0, xzr, #0x7ff8000000000000
1cb8: str      x0, [x19, #0x48]
1cbc: mov      x0, x22
1cc0: and      x0, x0, #0xffffffffffff
1cc4: mov      x10, #-0xf000000000000
1cc8: orr      x0, x0, x10
1ccc: str      x0, [x19, #0x50]
1cd0: ldr      d0, [x19, #0x550]
1cd4: fmov     x0, d0
1cd8: lsr      x3, x0, #48
1cdc: mov      x10, #0xfff1
1ce0: cmp      x3, x10
1ce4: b.lo     0x100301994
1ce8: orr      x0, xzr, #0x7ff8000000000000
1cec: str      x0, [x19, #0x58]
1cf0: mov      x0, x23
1cf4: and      x0, x0, #0xffffffffffff
1cf8: mov      x10, #-0xf000000000000
1cfc: orr      x0, x0, x10
1d00: str      x0, [x19, #0x60]
1d04: fmov     d0, d6
1d08: fmov     x0, d0
1d0c: lsr      x3, x0, #48
1d10: mov      x10, #0xfff1
1d14: cmp      x3, x10
1d18: b.lo     0x1003019c8
1d1c: orr      x0, xzr, #0x7ff8000000000000
1d20: str      x0, [x19, #0x68]
1d24: ldr      d0, [x19, #0x568]
1d28: fmov     x0, d0
1d2c: lsr      x3, x0, #48
1d30: mov      x10, #0xfff1
1d34: cmp      x3, x10
1d38: b.lo     0x1003019e8
1d3c: orr      x0, xzr, #0x7ff8000000000000
1d40: str      x0, [x19, #0x70]
1d44: ldr      x0, [x19, #0x580]
1d48: and      x0, x0, #0xffffffffffff
1d4c: mov      x10, #-0xf000000000000
1d50: orr      x0, x0, x10
1d54: str      x0, [x19, #0x78]
1d58: ldr      d0, [x19, #0x570]
1d5c: fmov     x0, d0
1d60: lsr      x3, x0, #48
1d64: mov      x10, #0xfff1
1d68: cmp      x3, x10
1d6c: b.lo     0x100301a1c
1d70: orr      x0, xzr, #0x7ff8000000000000
1d74: str      x0, [x19, #0xc8]
1d78: ldr      d0, [x19, #0x560]
1d7c: fmov     x0, d0
1d80: lsr      x3, x0, #48
1d84: mov      x10, #0xfff1
1d88: cmp      x3, x10
1d8c: b.lo     0x100301a3c
1d90: orr      x0, xzr, #0x7ff8000000000000
1d94: str      x0, [x19, #0xd0]
1d98: mov      x9, #0xffdf
1d9c: movk     x9, #0x600, lsl #16
1da0: str      x9, [x19, #0x390]
1da4: str      x20, [x19, #0x398]
1da8: mov      x0, #0x1e
1dac: ldp      x29, x30, [sp]
1db0: ldp      x19, x20, [sp, #0x50]
1db4: ldp      x21, x22, [sp, #0x40]
1db8: ldp      x23, x24, [sp, #0x30]
1dbc: ldp      x25, x26, [sp, #0x20]
1dc0: ldr      x27, [sp, #0x18]
1dc4: add      sp, sp, #0x60
1dc8: ret      
1dcc: mov      x0, x4
1dd0: str      x0, [x19]
1dd4: mov      x0, x5
1dd8: str      x0, [x19, #0x8]
1ddc: mov      x0, x6
1de0: str      x0, [x19, #0x10]
1de4: mov      x0, x7
1de8: str      x0, [x19, #0x18]
1dec: mov      x0, x21
1df0: str      x0, [x19, #0x20]
1df4: fmov     d0, d2
1df8: fmov     x0, d0
1dfc: lsr      x3, x0, #48
1e00: mov      x10, #0xfff1
1e04: cmp      x3, x10
1e08: b.lo     0x100301ab8
1e0c: orr      x0, xzr, #0x7ff8000000000000
1e10: str      x0, [x19, #0x30]
1e14: fmov     d0, d3
1e18: fmov     x0, d0
1e1c: lsr      x3, x0, #48
1e20: mov      x10, #0xfff1
1e24: cmp      x3, x10
1e28: b.lo     0x100301ad8
1e2c: orr      x0, xzr, #0x7ff8000000000000
1e30: str      x0, [x19, #0x38]
1e34: fmov     d0, d4
1e38: fmov     x0, d0
1e3c: lsr      x3, x0, #48
1e40: mov      x10, #0xfff1
1e44: cmp      x3, x10
1e48: b.lo     0x100301af8
1e4c: orr      x0, xzr, #0x7ff8000000000000
1e50: str      x0, [x19, #0x40]
1e54: fmov     d0, d5
1e58: fmov     x0, d0
1e5c: lsr      x3, x0, #48
1e60: mov      x10, #0xfff1
1e64: cmp      x3, x10
1e68: b.lo     0x100301b18
1e6c: orr      x0, xzr, #0x7ff8000000000000
1e70: str      x0, [x19, #0x48]
1e74: mov      x0, x22
1e78: and      x0, x0, #0xffffffffffff
1e7c: mov      x10, #-0xf000000000000
1e80: orr      x0, x0, x10
1e84: str      x0, [x19, #0x50]
1e88: ldr      d0, [x19, #0x550]
1e8c: fmov     x0, d0
1e90: lsr      x3, x0, #48
1e94: mov      x10, #0xfff1
1e98: cmp      x3, x10
1e9c: b.lo     0x100301b4c
1ea0: orr      x0, xzr, #0x7ff8000000000000
1ea4: str      x0, [x19, #0x58]
1ea8: mov      x0, x23
1eac: and      x0, x0, #0xffffffffffff
1eb0: mov      x10, #-0xf000000000000
1eb4: orr      x0, x0, x10
1eb8: str      x0, [x19, #0x60]
1ebc: fmov     d0, d6
1ec0: fmov     x0, d0
1ec4: lsr      x3, x0, #48
1ec8: mov      x10, #0xfff1
1ecc: cmp      x3, x10
1ed0: b.lo     0x100301b80
1ed4: orr      x0, xzr, #0x7ff8000000000000
1ed8: str      x0, [x19, #0x68]
1edc: fmov     d0, d7
1ee0: fmov     x0, d0
1ee4: lsr      x3, x0, #48
1ee8: mov      x10, #0xfff1
1eec: cmp      x3, x10
1ef0: b.lo     0x100301ba0
1ef4: orr      x0, xzr, #0x7ff8000000000000
1ef8: str      x0, [x19, #0x70]
1efc: ldr      x0, [x19, #0x580]
1f00: and      x0, x0, #0xffffffffffff
1f04: mov      x10, #-0xf000000000000
1f08: orr      x0, x0, x10
1f0c: str      x0, [x19, #0x78]
1f10: ldr      x0, [x19, #0x588]
1f14: and      x0, x0, #0xffffffffffff
1f18: mov      x10, #-0xf000000000000
1f1c: orr      x0, x0, x10
1f20: str      x0, [x19, #0x80]
1f24: ldr      d0, [x19, #0x570]
1f28: fmov     x0, d0
1f2c: lsr      x3, x0, #48
1f30: mov      x10, #0xfff1
1f34: cmp      x3, x10
1f38: b.lo     0x100301be8
1f3c: orr      x0, xzr, #0x7ff8000000000000
1f40: str      x0, [x19, #0xc8]
1f44: ldr      d0, [x19, #0x560]
1f48: fmov     x0, d0
1f4c: lsr      x3, x0, #48
1f50: mov      x10, #0xfff1
1f54: cmp      x3, x10
1f58: b.lo     0x100301c08
1f5c: orr      x0, xzr, #0x7ff8000000000000
1f60: str      x0, [x19, #0xd0]
1f64: mov      x9, #0xffdf
1f68: movk     x9, #0x601, lsl #16
1f6c: str      x9, [x19, #0x390]
1f70: str      x20, [x19, #0x398]
1f74: mov      x0, #0x25
1f78: ldp      x29, x30, [sp]
1f7c: ldp      x19, x20, [sp, #0x50]
1f80: ldp      x21, x22, [sp, #0x40]
1f84: ldp      x23, x24, [sp, #0x30]
1f88: ldp      x25, x26, [sp, #0x20]
1f8c: ldr      x27, [sp, #0x18]
1f90: add      sp, sp, #0x60
1f94: ret      
1f98: mov      x0, x4
1f9c: str      x0, [x19]
1fa0: mov      x0, x5
1fa4: str      x0, [x19, #0x8]
1fa8: mov      x0, x6
1fac: str      x0, [x19, #0x10]
1fb0: mov      x0, x7
1fb4: str      x0, [x19, #0x18]
1fb8: mov      x0, x21
1fbc: str      x0, [x19, #0x20]
1fc0: fmov     d0, d2
1fc4: fmov     x0, d0
1fc8: lsr      x3, x0, #48
1fcc: mov      x10, #0xfff1
1fd0: cmp      x3, x10
1fd4: b.lo     0x100301c84
1fd8: orr      x0, xzr, #0x7ff8000000000000
1fdc: str      x0, [x19, #0x30]
1fe0: fmov     d0, d3
1fe4: fmov     x0, d0
1fe8: lsr      x3, x0, #48
1fec: mov      x10, #0xfff1
1ff0: cmp      x3, x10
1ff4: b.lo     0x100301ca4
1ff8: orr      x0, xzr, #0x7ff8000000000000
1ffc: str      x0, [x19, #0x38]
2000: fmov     d0, d4
2004: fmov     x0, d0
2008: lsr      x3, x0, #48
200c: mov      x10, #0xfff1
2010: cmp      x3, x10
2014: b.lo     0x100301cc4
2018: orr      x0, xzr, #0x7ff8000000000000
201c: str      x0, [x19, #0x40]
2020: fmov     d0, d5
2024: fmov     x0, d0
2028: lsr      x3, x0, #48
202c: mov      x10, #0xfff1
2030: cmp      x3, x10
2034: b.lo     0x100301ce4
2038: orr      x0, xzr, #0x7ff8000000000000
203c: str      x0, [x19, #0x48]
2040: mov      x0, x22
2044: and      x0, x0, #0xffffffffffff
2048: mov      x10, #-0xf000000000000
204c: orr      x0, x0, x10
2050: str      x0, [x19, #0x50]
2054: ldr      d0, [x19, #0x550]
2058: fmov     x0, d0
205c: lsr      x3, x0, #48
2060: mov      x10, #0xfff1
2064: cmp      x3, x10
2068: b.lo     0x100301d18
206c: orr      x0, xzr, #0x7ff8000000000000
2070: str      x0, [x19, #0x58]
2074: mov      x0, x23
2078: and      x0, x0, #0xffffffffffff
207c: mov      x10, #-0xf000000000000
2080: orr      x0, x0, x10
2084: str      x0, [x19, #0x60]
2088: fmov     d0, d6
208c: fmov     x0, d0
2090: lsr      x3, x0, #48
2094: mov      x10, #0xfff1
2098: cmp      x3, x10
209c: b.lo     0x100301d4c
20a0: orr      x0, xzr, #0x7ff8000000000000
20a4: str      x0, [x19, #0x68]
20a8: fmov     d0, d7
20ac: fmov     x0, d0
20b0: lsr      x3, x0, #48
20b4: mov      x10, #0xfff1
20b8: cmp      x3, x10
20bc: b.lo     0x100301d6c
20c0: orr      x0, xzr, #0x7ff8000000000000
20c4: str      x0, [x19, #0x70]
20c8: ldr      x0, [x19, #0x580]
20cc: and      x0, x0, #0xffffffffffff
20d0: mov      x10, #-0xf000000000000
20d4: orr      x0, x0, x10
20d8: str      x0, [x19, #0x78]
20dc: ldr      x0, [x19, #0x588]
20e0: and      x0, x0, #0xffffffffffff
20e4: mov      x10, #-0xf000000000000
20e8: orr      x0, x0, x10
20ec: str      x0, [x19, #0x80]
20f0: ldr      x0, [x19, #0x598]
20f4: and      x0, x0, #0xffffffffffff
20f8: mov      x10, #-0xf000000000000
20fc: orr      x0, x0, x10
2100: str      x0, [x19, #0x88]
2104: ldr      d0, [x19, #0x570]
2108: fmov     x0, d0
210c: lsr      x3, x0, #48
2110: mov      x10, #0xfff1
2114: cmp      x3, x10
2118: b.lo     0x100301dc8
211c: orr      x0, xzr, #0x7ff8000000000000
2120: str      x0, [x19, #0xc8]
2124: ldr      d0, [x19, #0x560]
2128: fmov     x0, d0
212c: lsr      x3, x0, #48
2130: mov      x10, #0xfff1
2134: cmp      x3, x10
2138: b.lo     0x100301de8
213c: orr      x0, xzr, #0x7ff8000000000000
2140: str      x0, [x19, #0xd0]
2144: mov      x9, #0xffdf
2148: movk     x9, #0x603, lsl #16
214c: str      x9, [x19, #0x390]
2150: str      x20, [x19, #0x398]
2154: mov      x0, #0x26
2158: ldp      x29, x30, [sp]
215c: ldp      x19, x20, [sp, #0x50]
2160: ldp      x21, x22, [sp, #0x40]
2164: ldp      x23, x24, [sp, #0x30]
2168: ldp      x25, x26, [sp, #0x20]
216c: ldr      x27, [sp, #0x18]
2170: add      sp, sp, #0x60
2174: ret      
2178: mov      x0, x4
217c: str      x0, [x19]
2180: mov      x0, x5
2184: str      x0, [x19, #0x8]
2188: mov      x0, x6
218c: str      x0, [x19, #0x10]
2190: mov      x0, x7
2194: str      x0, [x19, #0x18]
2198: mov      x0, x21
219c: str      x0, [x19, #0x20]
21a0: fmov     d0, d2
21a4: fmov     x0, d0
21a8: lsr      x3, x0, #48
21ac: mov      x10, #0xfff1
21b0: cmp      x3, x10
21b4: b.lo     0x100301e64
21b8: orr      x0, xzr, #0x7ff8000000000000
21bc: str      x0, [x19, #0x30]
21c0: fmov     d0, d3
21c4: fmov     x0, d0
21c8: lsr      x3, x0, #48
21cc: mov      x10, #0xfff1
21d0: cmp      x3, x10
21d4: b.lo     0x100301e84
21d8: orr      x0, xzr, #0x7ff8000000000000
21dc: str      x0, [x19, #0x38]
21e0: fmov     d0, d4
21e4: fmov     x0, d0
21e8: lsr      x3, x0, #48
21ec: mov      x10, #0xfff1
21f0: cmp      x3, x10
21f4: b.lo     0x100301ea4
21f8: orr      x0, xzr, #0x7ff8000000000000
21fc: str      x0, [x19, #0x40]
2200: fmov     d0, d5
2204: fmov     x0, d0
2208: lsr      x3, x0, #48
220c: mov      x10, #0xfff1
2210: cmp      x3, x10
2214: b.lo     0x100301ec4
2218: orr      x0, xzr, #0x7ff8000000000000
221c: str      x0, [x19, #0x48]
2220: mov      x0, x22
2224: and      x0, x0, #0xffffffffffff
2228: mov      x10, #-0xf000000000000
222c: orr      x0, x0, x10
2230: str      x0, [x19, #0x50]
2234: ldr      d0, [x19, #0x550]
2238: fmov     x0, d0
223c: lsr      x3, x0, #48
2240: mov      x10, #0xfff1
2244: cmp      x3, x10
2248: b.lo     0x100301ef8
224c: orr      x0, xzr, #0x7ff8000000000000
2250: str      x0, [x19, #0x58]
2254: mov      x0, x23
2258: and      x0, x0, #0xffffffffffff
225c: mov      x10, #-0xf000000000000
2260: orr      x0, x0, x10
2264: str      x0, [x19, #0x60]
2268: fmov     d0, d6
226c: fmov     x0, d0
2270: lsr      x3, x0, #48
2274: mov      x10, #0xfff1
2278: cmp      x3, x10
227c: b.lo     0x100301f2c
2280: orr      x0, xzr, #0x7ff8000000000000
2284: str      x0, [x19, #0x68]
2288: fmov     d0, d7
228c: fmov     x0, d0
2290: lsr      x3, x0, #48
2294: mov      x10, #0xfff1
2298: cmp      x3, x10
229c: b.lo     0x100301f4c
22a0: orr      x0, xzr, #0x7ff8000000000000
22a4: str      x0, [x19, #0x70]
22a8: ldr      x0, [x19, #0x580]
22ac: and      x0, x0, #0xffffffffffff
22b0: mov      x10, #-0xf000000000000
22b4: orr      x0, x0, x10
22b8: str      x0, [x19, #0x78]
22bc: ldr      x0, [x19, #0x588]
22c0: and      x0, x0, #0xffffffffffff
22c4: mov      x10, #-0xf000000000000
22c8: orr      x0, x0, x10
22cc: str      x0, [x19, #0x80]
22d0: ldr      x0, [x19, #0x598]
22d4: and      x0, x0, #0xffffffffffff
22d8: mov      x10, #-0xf000000000000
22dc: orr      x0, x0, x10
22e0: str      x0, [x19, #0x88]
22e4: ldr      x0, [x19, #0x5a0]
22e8: and      x0, x0, #0xffffffffffff
22ec: mov      x10, #-0xf000000000000
22f0: orr      x0, x0, x10
22f4: str      x0, [x19, #0x90]
22f8: ldr      d0, [x19, #0x5a8]
22fc: fmov     x0, d0
2300: lsr      x3, x0, #48
2304: mov      x10, #0xfff1
2308: cmp      x3, x10
230c: b.lo     0x100301fbc
2310: orr      x0, xzr, #0x7ff8000000000000
2314: str      x0, [x19, #0x98]
2318: ldr      d0, [x19, #0x5b8]
231c: fmov     x0, d0
2320: lsr      x3, x0, #48
2324: mov      x10, #0xfff1
2328: cmp      x3, x10
232c: b.lo     0x100301fdc
2330: orr      x0, xzr, #0x7ff8000000000000
2334: str      x0, [x19, #0xa0]
2338: ldr      d0, [x19, #0x5c0]
233c: fmov     x0, d0
2340: lsr      x3, x0, #48
2344: mov      x10, #0xfff1
2348: cmp      x3, x10
234c: b.lo     0x100301ffc
2350: orr      x0, xzr, #0x7ff8000000000000
2354: str      x0, [x19, #0xa8]
2358: ldr      d0, [x19, #0x5d0]
235c: fmov     x0, d0
2360: lsr      x3, x0, #48
2364: mov      x10, #0xfff1
2368: cmp      x3, x10
236c: b.lo     0x10030201c
2370: orr      x0, xzr, #0x7ff8000000000000
2374: str      x0, [x19, #0xb0]
2378: ldr      x0, [x19, #0x5d8]
237c: str      x0, [x19, #0xc8]
2380: ldr      d0, [x19, #0x560]
2384: fmov     x0, d0
2388: lsr      x3, x0, #48
238c: mov      x10, #0xfff1
2390: cmp      x3, x10
2394: b.lo     0x100302044
2398: orr      x0, xzr, #0x7ff8000000000000
239c: str      x0, [x19, #0xd0]
23a0: mov      x9, #0xffdf
23a4: movk     x9, #0x67f, lsl #16
23a8: str      x9, [x19, #0x390]
23ac: str      x20, [x19, #0x398]
23b0: mov      x0, #0x2e
23b4: ldp      x29, x30, [sp]
23b8: ldp      x19, x20, [sp, #0x50]
23bc: ldp      x21, x22, [sp, #0x40]
23c0: ldp      x23, x24, [sp, #0x30]
23c4: ldp      x25, x26, [sp, #0x20]
23c8: ldr      x27, [sp, #0x18]
23cc: add      sp, sp, #0x60
23d0: ret      
23d4: mov      x0, x4
23d8: str      x0, [x19]
23dc: mov      x0, x5
23e0: str      x0, [x19, #0x8]
23e4: mov      x0, x6
23e8: str      x0, [x19, #0x10]
23ec: mov      x0, x7
23f0: str      x0, [x19, #0x18]
23f4: mov      x0, x21
23f8: str      x0, [x19, #0x20]
23fc: fmov     d0, d2
2400: fmov     x0, d0
2404: lsr      x3, x0, #48
2408: mov      x10, #0xfff1
240c: cmp      x3, x10
2410: b.lo     0x1003020c0
2414: orr      x0, xzr, #0x7ff8000000000000
2418: str      x0, [x19, #0x30]
241c: fmov     d0, d3
2420: fmov     x0, d0
2424: lsr      x3, x0, #48
2428: mov      x10, #0xfff1
242c: cmp      x3, x10
2430: b.lo     0x1003020e0
2434: orr      x0, xzr, #0x7ff8000000000000
2438: str      x0, [x19, #0x38]
243c: fmov     d0, d4
2440: fmov     x0, d0
2444: lsr      x3, x0, #48
2448: mov      x10, #0xfff1
244c: cmp      x3, x10
2450: b.lo     0x100302100
2454: orr      x0, xzr, #0x7ff8000000000000
2458: str      x0, [x19, #0x40]
245c: fmov     d0, d5
2460: fmov     x0, d0
2464: lsr      x3, x0, #48
2468: mov      x10, #0xfff1
246c: cmp      x3, x10
2470: b.lo     0x100302120
2474: orr      x0, xzr, #0x7ff8000000000000
2478: str      x0, [x19, #0x48]
247c: mov      x0, x22
2480: and      x0, x0, #0xffffffffffff
2484: mov      x10, #-0xf000000000000
2488: orr      x0, x0, x10
248c: str      x0, [x19, #0x50]
2490: ldr      d0, [x19, #0x550]
2494: fmov     x0, d0
2498: lsr      x3, x0, #48
249c: mov      x10, #0xfff1
24a0: cmp      x3, x10
24a4: b.lo     0x100302154
24a8: orr      x0, xzr, #0x7ff8000000000000
24ac: str      x0, [x19, #0x58]
24b0: mov      x0, x23
24b4: and      x0, x0, #0xffffffffffff
24b8: mov      x10, #-0xf000000000000
24bc: orr      x0, x0, x10
24c0: str      x0, [x19, #0x60]
24c4: fmov     d0, d6
24c8: fmov     x0, d0
24cc: lsr      x3, x0, #48
24d0: mov      x10, #0xfff1
24d4: cmp      x3, x10
24d8: b.lo     0x100302188
24dc: orr      x0, xzr, #0x7ff8000000000000
24e0: str      x0, [x19, #0x68]
24e4: fmov     d0, d7
24e8: fmov     x0, d0
24ec: lsr      x3, x0, #48
24f0: mov      x10, #0xfff1
24f4: cmp      x3, x10
24f8: b.lo     0x1003021a8
24fc: orr      x0, xzr, #0x7ff8000000000000
2500: str      x0, [x19, #0x70]
2504: ldr      x0, [x19, #0x580]
2508: and      x0, x0, #0xffffffffffff
250c: mov      x10, #-0xf000000000000
2510: orr      x0, x0, x10
2514: str      x0, [x19, #0x78]
2518: ldr      x0, [x19, #0x588]
251c: and      x0, x0, #0xffffffffffff
2520: mov      x10, #-0xf000000000000
2524: orr      x0, x0, x10
2528: str      x0, [x19, #0x80]
252c: ldr      x0, [x19, #0x598]
2530: and      x0, x0, #0xffffffffffff
2534: mov      x10, #-0xf000000000000
2538: orr      x0, x0, x10
253c: str      x0, [x19, #0x88]
2540: ldr      x0, [x19, #0x5a0]
2544: and      x0, x0, #0xffffffffffff
2548: mov      x10, #-0xf000000000000
254c: orr      x0, x0, x10
2550: str      x0, [x19, #0x90]
2554: ldr      d0, [x19, #0x5a8]
2558: fmov     x0, d0
255c: lsr      x3, x0, #48
2560: mov      x10, #0xfff1
2564: cmp      x3, x10
2568: b.lo     0x100302218
256c: orr      x0, xzr, #0x7ff8000000000000
2570: str      x0, [x19, #0x98]
2574: ldr      d0, [x19, #0x5b8]
2578: fmov     x0, d0
257c: lsr      x3, x0, #48
2580: mov      x10, #0xfff1
2584: cmp      x3, x10
2588: b.lo     0x100302238
258c: orr      x0, xzr, #0x7ff8000000000000
2590: str      x0, [x19, #0xa0]
2594: ldr      d0, [x19, #0x5c0]
2598: fmov     x0, d0
259c: lsr      x3, x0, #48
25a0: mov      x10, #0xfff1
25a4: cmp      x3, x10
25a8: b.lo     0x100302258
25ac: orr      x0, xzr, #0x7ff8000000000000
25b0: str      x0, [x19, #0xa8]
25b4: ldr      d0, [x19, #0x5d0]
25b8: fmov     x0, d0
25bc: lsr      x3, x0, #48
25c0: mov      x10, #0xfff1
25c4: cmp      x3, x10
25c8: b.lo     0x100302278
25cc: orr      x0, xzr, #0x7ff8000000000000
25d0: str      x0, [x19, #0xb0]
25d4: ldr      d0, [x19, #0x5e8]
25d8: fmov     x0, d0
25dc: lsr      x3, x0, #48
25e0: mov      x10, #0xfff1
25e4: cmp      x3, x10
25e8: b.lo     0x100302298
25ec: orr      x0, xzr, #0x7ff8000000000000
25f0: str      x0, [x19, #0xb8]
25f4: ldr      x0, [x19, #0x5d8]
25f8: str      x0, [x19, #0xc8]
25fc: ldr      d0, [x19, #0x560]
2600: fmov     x0, d0
2604: lsr      x3, x0, #48
2608: mov      x10, #0xfff1
260c: cmp      x3, x10
2610: b.lo     0x1003022c0
2614: orr      x0, xzr, #0x7ff8000000000000
2618: str      x0, [x19, #0xd0]
261c: mov      x9, #0xffdf
2620: movk     x9, #0x6ff, lsl #16
2624: str      x9, [x19, #0x390]
2628: str      x20, [x19, #0x398]
262c: mov      x0, #0x30
2630: ldp      x29, x30, [sp]
2634: ldp      x19, x20, [sp, #0x50]
2638: ldp      x21, x22, [sp, #0x40]
263c: ldp      x23, x24, [sp, #0x30]
2640: ldp      x25, x26, [sp, #0x20]
2644: ldr      x27, [sp, #0x18]
2648: add      sp, sp, #0x60
264c: ret      
2650: mov      x0, x4
2654: str      x0, [x19]
2658: mov      x0, x5
265c: str      x0, [x19, #0x8]
2660: mov      x0, x6
2664: str      x0, [x19, #0x10]
2668: mov      x0, x7
266c: str      x0, [x19, #0x18]
2670: mov      x0, x21
2674: str      x0, [x19, #0x20]
2678: fmov     d0, d2
267c: fmov     x0, d0
2680: lsr      x3, x0, #48
2684: mov      x10, #0xfff1
2688: cmp      x3, x10
268c: b.lo     0x10030233c
2690: orr      x0, xzr, #0x7ff8000000000000
2694: str      x0, [x19, #0x30]
2698: fmov     d0, d3
269c: fmov     x0, d0
26a0: lsr      x3, x0, #48
26a4: mov      x10, #0xfff1
26a8: cmp      x3, x10
26ac: b.lo     0x10030235c
26b0: orr      x0, xzr, #0x7ff8000000000000
26b4: str      x0, [x19, #0x38]
26b8: fmov     d0, d4
26bc: fmov     x0, d0
26c0: lsr      x3, x0, #48
26c4: mov      x10, #0xfff1
26c8: cmp      x3, x10
26cc: b.lo     0x10030237c
26d0: orr      x0, xzr, #0x7ff8000000000000
26d4: str      x0, [x19, #0x40]
26d8: fmov     d0, d5
26dc: fmov     x0, d0
26e0: lsr      x3, x0, #48
26e4: mov      x10, #0xfff1
26e8: cmp      x3, x10
26ec: b.lo     0x10030239c
26f0: orr      x0, xzr, #0x7ff8000000000000
26f4: str      x0, [x19, #0x48]
26f8: mov      x0, x22
26fc: and      x0, x0, #0xffffffffffff
2700: mov      x10, #-0xf000000000000
2704: orr      x0, x0, x10
2708: str      x0, [x19, #0x50]
270c: ldr      d0, [x19, #0x550]
2710: fmov     x0, d0
2714: lsr      x3, x0, #48
2718: mov      x10, #0xfff1
271c: cmp      x3, x10
2720: b.lo     0x1003023d0
2724: orr      x0, xzr, #0x7ff8000000000000
2728: str      x0, [x19, #0x58]
272c: mov      x0, x23
2730: and      x0, x0, #0xffffffffffff
2734: mov      x10, #-0xf000000000000
2738: orr      x0, x0, x10
273c: str      x0, [x19, #0x60]
2740: fmov     d0, d6
2744: fmov     x0, d0
2748: lsr      x3, x0, #48
274c: mov      x10, #0xfff1
2750: cmp      x3, x10
2754: b.lo     0x100302404
2758: orr      x0, xzr, #0x7ff8000000000000
275c: str      x0, [x19, #0x68]
2760: fmov     d0, d7
2764: fmov     x0, d0
2768: lsr      x3, x0, #48
276c: mov      x10, #0xfff1
2770: cmp      x3, x10
2774: b.lo     0x100302424
2778: orr      x0, xzr, #0x7ff8000000000000
277c: str      x0, [x19, #0x70]
2780: ldr      x0, [x19, #0x580]
2784: and      x0, x0, #0xffffffffffff
2788: mov      x10, #-0xf000000000000
278c: orr      x0, x0, x10
2790: str      x0, [x19, #0x78]
2794: ldr      x0, [x19, #0x588]
2798: and      x0, x0, #0xffffffffffff
279c: mov      x10, #-0xf000000000000
27a0: orr      x0, x0, x10
27a4: str      x0, [x19, #0x80]
27a8: ldr      x0, [x19, #0x598]
27ac: and      x0, x0, #0xffffffffffff
27b0: mov      x10, #-0xf000000000000
27b4: orr      x0, x0, x10
27b8: str      x0, [x19, #0x88]
27bc: ldr      x0, [x19, #0x5a0]
27c0: and      x0, x0, #0xffffffffffff
27c4: mov      x10, #-0xf000000000000
27c8: orr      x0, x0, x10
27cc: str      x0, [x19, #0x90]
27d0: ldr      d0, [x19, #0x5a8]
27d4: fmov     x0, d0
27d8: lsr      x3, x0, #48
27dc: mov      x10, #0xfff1
27e0: cmp      x3, x10
27e4: b.lo     0x100302494
27e8: orr      x0, xzr, #0x7ff8000000000000
27ec: str      x0, [x19, #0x98]
27f0: ldr      d0, [x19, #0x5b8]
27f4: fmov     x0, d0
27f8: lsr      x3, x0, #48
27fc: mov      x10, #0xfff1
2800: cmp      x3, x10
2804: b.lo     0x1003024b4
2808: orr      x0, xzr, #0x7ff8000000000000
280c: str      x0, [x19, #0xa0]
2810: ldr      d0, [x19, #0x5c0]
2814: fmov     x0, d0
2818: lsr      x3, x0, #48
281c: mov      x10, #0xfff1
2820: cmp      x3, x10
2824: b.lo     0x1003024d4
2828: orr      x0, xzr, #0x7ff8000000000000
282c: str      x0, [x19, #0xa8]
2830: ldr      d0, [x19, #0x5d0]
2834: fmov     x0, d0
2838: lsr      x3, x0, #48
283c: mov      x10, #0xfff1
2840: cmp      x3, x10
2844: b.lo     0x1003024f4
2848: orr      x0, xzr, #0x7ff8000000000000
284c: str      x0, [x19, #0xb0]
2850: ldr      d0, [x19, #0x5e8]
2854: fmov     x0, d0
2858: lsr      x3, x0, #48
285c: mov      x10, #0xfff1
2860: cmp      x3, x10
2864: b.lo     0x100302514
2868: orr      x0, xzr, #0x7ff8000000000000
286c: str      x0, [x19, #0xb8]
2870: ldr      d0, [x19, #0x5f8]
2874: fmov     x0, d0
2878: lsr      x3, x0, #48
287c: mov      x10, #0xfff1
2880: cmp      x3, x10
2884: b.lo     0x100302534
2888: orr      x0, xzr, #0x7ff8000000000000
288c: str      x0, [x19, #0xc0]
2890: ldr      d0, [x19, #0x550]
2894: fmov     x0, d0
2898: lsr      x3, x0, #48
289c: mov      x10, #0xfff1
28a0: cmp      x3, x10
28a4: b.lo     0x100302554
28a8: orr      x0, xzr, #0x7ff8000000000000
28ac: str      x0, [x19, #0xc8]
28b0: ldr      d0, [x19, #0x560]
28b4: fmov     x0, d0
28b8: lsr      x3, x0, #48
28bc: mov      x10, #0xfff1
28c0: cmp      x3, x10
28c4: b.lo     0x100302574
28c8: orr      x0, xzr, #0x7ff8000000000000
28cc: str      x0, [x19, #0xd0]
28d0: ldr      d0, [x19, #0x600]
28d4: fmov     x0, d0
28d8: lsr      x3, x0, #48
28dc: mov      x10, #0xfff1
28e0: cmp      x3, x10
28e4: b.lo     0x100302594
28e8: orr      x0, xzr, #0x7ff8000000000000
28ec: str      x0, [x19, #0xd8]
28f0: mov      x9, #0xffdf
28f4: movk     x9, #0xfff, lsl #16
28f8: str      x9, [x19, #0x390]
28fc: str      x20, [x19, #0x398]
2900: mov      x0, #0x33
2904: ldp      x29, x30, [sp]
2908: ldp      x19, x20, [sp, #0x50]
290c: ldp      x21, x22, [sp, #0x40]
2910: ldp      x23, x24, [sp, #0x30]
2914: ldp      x25, x26, [sp, #0x20]
2918: ldr      x27, [sp, #0x18]
291c: add      sp, sp, #0x60
2920: ret      
2924: mov      x0, x4
2928: str      x0, [x19]
292c: mov      x0, x5
2930: str      x0, [x19, #0x8]
2934: mov      x0, x6
2938: str      x0, [x19, #0x10]
293c: mov      x0, x7
2940: str      x0, [x19, #0x18]
2944: mov      x0, x21
2948: str      x0, [x19, #0x20]
294c: fmov     d0, d2
2950: fmov     x0, d0
2954: lsr      x3, x0, #48
2958: mov      x10, #0xfff1
295c: cmp      x3, x10
2960: b.lo     0x100302610
2964: orr      x0, xzr, #0x7ff8000000000000
2968: str      x0, [x19, #0x30]
296c: fmov     d0, d3
2970: fmov     x0, d0
2974: lsr      x3, x0, #48
2978: mov      x10, #0xfff1
297c: cmp      x3, x10
2980: b.lo     0x100302630
2984: orr      x0, xzr, #0x7ff8000000000000
2988: str      x0, [x19, #0x38]
298c: fmov     d0, d4
2990: fmov     x0, d0
2994: lsr      x3, x0, #48
2998: mov      x10, #0xfff1
299c: cmp      x3, x10
29a0: b.lo     0x100302650
29a4: orr      x0, xzr, #0x7ff8000000000000
29a8: str      x0, [x19, #0x40]
29ac: fmov     d0, d5
29b0: fmov     x0, d0
29b4: lsr      x3, x0, #48
29b8: mov      x10, #0xfff1
29bc: cmp      x3, x10
29c0: b.lo     0x100302670
29c4: orr      x0, xzr, #0x7ff8000000000000
29c8: str      x0, [x19, #0x48]
29cc: mov      x0, x22
29d0: and      x0, x0, #0xffffffffffff
29d4: mov      x10, #-0xf000000000000
29d8: orr      x0, x0, x10
29dc: str      x0, [x19, #0x50]
29e0: ldr      d0, [x19, #0x550]
29e4: fmov     x0, d0
29e8: lsr      x3, x0, #48
29ec: mov      x10, #0xfff1
29f0: cmp      x3, x10
29f4: b.lo     0x1003026a4
29f8: orr      x0, xzr, #0x7ff8000000000000
29fc: str      x0, [x19, #0x58]
2a00: mov      x0, x23
2a04: and      x0, x0, #0xffffffffffff
2a08: mov      x10, #-0xf000000000000
2a0c: orr      x0, x0, x10
2a10: str      x0, [x19, #0x60]
2a14: fmov     d0, d6
2a18: fmov     x0, d0
2a1c: lsr      x3, x0, #48
2a20: mov      x10, #0xfff1
2a24: cmp      x3, x10
2a28: b.lo     0x1003026d8
2a2c: orr      x0, xzr, #0x7ff8000000000000
2a30: str      x0, [x19, #0x68]
2a34: fmov     d0, d7
2a38: fmov     x0, d0
2a3c: lsr      x3, x0, #48
2a40: mov      x10, #0xfff1
2a44: cmp      x3, x10
2a48: b.lo     0x1003026f8
2a4c: orr      x0, xzr, #0x7ff8000000000000
2a50: str      x0, [x19, #0x70]
2a54: ldr      x0, [x19, #0x580]
2a58: and      x0, x0, #0xffffffffffff
2a5c: mov      x10, #-0xf000000000000
2a60: orr      x0, x0, x10
2a64: str      x0, [x19, #0x78]
2a68: ldr      x0, [x19, #0x588]
2a6c: and      x0, x0, #0xffffffffffff
2a70: mov      x10, #-0xf000000000000
2a74: orr      x0, x0, x10
2a78: str      x0, [x19, #0x80]
2a7c: ldr      x0, [x19, #0x598]
2a80: and      x0, x0, #0xffffffffffff
2a84: mov      x10, #-0xf000000000000
2a88: orr      x0, x0, x10
2a8c: str      x0, [x19, #0x88]
2a90: ldr      x0, [x19, #0x5a0]
2a94: and      x0, x0, #0xffffffffffff
2a98: mov      x10, #-0xf000000000000
2a9c: orr      x0, x0, x10
2aa0: str      x0, [x19, #0x90]
2aa4: ldr      d0, [x19, #0x5a8]
2aa8: fmov     x0, d0
2aac: lsr      x3, x0, #48
2ab0: mov      x10, #0xfff1
2ab4: cmp      x3, x10
2ab8: b.lo     0x100302768
2abc: orr      x0, xzr, #0x7ff8000000000000
2ac0: str      x0, [x19, #0x98]
2ac4: ldr      d0, [x19, #0x5b8]
2ac8: fmov     x0, d0
2acc: lsr      x3, x0, #48
2ad0: mov      x10, #0xfff1
2ad4: cmp      x3, x10
2ad8: b.lo     0x100302788
2adc: orr      x0, xzr, #0x7ff8000000000000
2ae0: str      x0, [x19, #0xa0]
2ae4: ldr      d0, [x19, #0x5c0]
2ae8: fmov     x0, d0
2aec: lsr      x3, x0, #48
2af0: mov      x10, #0xfff1
2af4: cmp      x3, x10
2af8: b.lo     0x1003027a8
2afc: orr      x0, xzr, #0x7ff8000000000000
2b00: str      x0, [x19, #0xa8]
2b04: ldr      d0, [x19, #0x5d0]
2b08: fmov     x0, d0
2b0c: lsr      x3, x0, #48
2b10: mov      x10, #0xfff1
2b14: cmp      x3, x10
2b18: b.lo     0x1003027c8
2b1c: orr      x0, xzr, #0x7ff8000000000000
2b20: str      x0, [x19, #0xb0]
2b24: ldr      d0, [x19, #0x5e8]
2b28: fmov     x0, d0
2b2c: lsr      x3, x0, #48
2b30: mov      x10, #0xfff1
2b34: cmp      x3, x10
2b38: b.lo     0x1003027e8
2b3c: orr      x0, xzr, #0x7ff8000000000000
2b40: str      x0, [x19, #0xb8]
2b44: ldr      d0, [x19, #0x5f8]
2b48: fmov     x0, d0
2b4c: lsr      x3, x0, #48
2b50: mov      x10, #0xfff1
2b54: cmp      x3, x10
2b58: b.lo     0x100302808
2b5c: orr      x0, xzr, #0x7ff8000000000000
2b60: str      x0, [x19, #0xc0]
2b64: ldr      d0, [x19, #0x550]
2b68: fmov     x0, d0
2b6c: lsr      x3, x0, #48
2b70: mov      x10, #0xfff1
2b74: cmp      x3, x10
2b78: b.lo     0x100302828
2b7c: orr      x0, xzr, #0x7ff8000000000000
2b80: str      x0, [x19, #0xc8]
2b84: ldr      d0, [x19, #0x560]
2b88: fmov     x0, d0
2b8c: lsr      x3, x0, #48
2b90: mov      x10, #0xfff1
2b94: cmp      x3, x10
2b98: b.lo     0x100302848
2b9c: orr      x0, xzr, #0x7ff8000000000000
2ba0: str      x0, [x19, #0xd0]
2ba4: ldr      d0, [x19, #0x600]
2ba8: fmov     x0, d0
2bac: lsr      x3, x0, #48
2bb0: mov      x10, #0xfff1
2bb4: cmp      x3, x10
2bb8: b.lo     0x100302868
2bbc: orr      x0, xzr, #0x7ff8000000000000
2bc0: str      x0, [x19, #0xd8]
2bc4: ldr      d0, [x19, #0x610]
2bc8: fmov     x0, d0
2bcc: lsr      x3, x0, #48
2bd0: mov      x10, #0xfff1
2bd4: cmp      x3, x10
2bd8: b.lo     0x100302888
2bdc: orr      x0, xzr, #0x7ff8000000000000
2be0: str      x0, [x19, #0xe0]
2be4: fmov     d0, d17
2be8: fmov     x0, d0
2bec: lsr      x3, x0, #48
2bf0: mov      x10, #0xfff1
2bf4: cmp      x3, x10
2bf8: b.lo     0x1003028a8
2bfc: orr      x0, xzr, #0x7ff8000000000000
2c00: str      x0, [x19, #0xe8]
2c04: ldr      d0, [x19, #0x618]
2c08: fmov     x0, d0
2c0c: lsr      x3, x0, #48
2c10: mov      x10, #0xfff1
2c14: cmp      x3, x10
2c18: b.lo     0x1003028c8
2c1c: orr      x0, xzr, #0x7ff8000000000000
2c20: str      x0, [x19, #0xf0]
2c24: mov      x9, #0xffdf
2c28: movk     x9, #0x7fff, lsl #16
2c2c: str      x9, [x19, #0x390]
2c30: str      x20, [x19, #0x398]
2c34: mov      x0, #0x36
2c38: ldp      x29, x30, [sp]
2c3c: ldp      x19, x20, [sp, #0x50]
2c40: ldp      x21, x22, [sp, #0x40]
2c44: ldp      x23, x24, [sp, #0x30]
2c48: ldp      x25, x26, [sp, #0x20]
2c4c: ldr      x27, [sp, #0x18]
2c50: add      sp, sp, #0x60
2c54: ret      
2c58: mov      x0, x4
2c5c: str      x0, [x19]
2c60: mov      x0, x5
2c64: str      x0, [x19, #0x8]
2c68: mov      x0, x6
2c6c: str      x0, [x19, #0x10]
2c70: mov      x0, x7
2c74: str      x0, [x19, #0x18]
2c78: mov      x0, x21
2c7c: str      x0, [x19, #0x20]
2c80: fmov     d0, d2
2c84: fmov     x0, d0
2c88: lsr      x3, x0, #48
2c8c: mov      x10, #0xfff1
2c90: cmp      x3, x10
2c94: b.lo     0x100302944
2c98: orr      x0, xzr, #0x7ff8000000000000
2c9c: str      x0, [x19, #0x30]
2ca0: fmov     d0, d3
2ca4: fmov     x0, d0
2ca8: lsr      x3, x0, #48
2cac: mov      x10, #0xfff1
2cb0: cmp      x3, x10
2cb4: b.lo     0x100302964
2cb8: orr      x0, xzr, #0x7ff8000000000000
2cbc: str      x0, [x19, #0x38]
2cc0: fmov     d0, d4
2cc4: fmov     x0, d0
2cc8: lsr      x3, x0, #48
2ccc: mov      x10, #0xfff1
2cd0: cmp      x3, x10
2cd4: b.lo     0x100302984
2cd8: orr      x0, xzr, #0x7ff8000000000000
2cdc: str      x0, [x19, #0x40]
2ce0: fmov     d0, d5
2ce4: fmov     x0, d0
2ce8: lsr      x3, x0, #48
2cec: mov      x10, #0xfff1
2cf0: cmp      x3, x10
2cf4: b.lo     0x1003029a4
2cf8: orr      x0, xzr, #0x7ff8000000000000
2cfc: str      x0, [x19, #0x48]
2d00: mov      x0, x22
2d04: and      x0, x0, #0xffffffffffff
2d08: mov      x10, #-0xf000000000000
2d0c: orr      x0, x0, x10
2d10: str      x0, [x19, #0x50]
2d14: ldr      d0, [x19, #0x550]
2d18: fmov     x0, d0
2d1c: lsr      x3, x0, #48
2d20: mov      x10, #0xfff1
2d24: cmp      x3, x10
2d28: b.lo     0x1003029d8
2d2c: orr      x0, xzr, #0x7ff8000000000000
2d30: str      x0, [x19, #0x58]
2d34: mov      x0, x23
2d38: and      x0, x0, #0xffffffffffff
2d3c: mov      x10, #-0xf000000000000
2d40: orr      x0, x0, x10
2d44: str      x0, [x19, #0x60]
2d48: fmov     d0, d6
2d4c: fmov     x0, d0
2d50: lsr      x3, x0, #48
2d54: mov      x10, #0xfff1
2d58: cmp      x3, x10
2d5c: b.lo     0x100302a0c
2d60: orr      x0, xzr, #0x7ff8000000000000
2d64: str      x0, [x19, #0x68]
2d68: fmov     d0, d7
2d6c: fmov     x0, d0
2d70: lsr      x3, x0, #48
2d74: mov      x10, #0xfff1
2d78: cmp      x3, x10
2d7c: b.lo     0x100302a2c
2d80: orr      x0, xzr, #0x7ff8000000000000
2d84: str      x0, [x19, #0x70]
2d88: ldr      x0, [x19, #0x580]
2d8c: and      x0, x0, #0xffffffffffff
2d90: mov      x10, #-0xf000000000000
2d94: orr      x0, x0, x10
2d98: str      x0, [x19, #0x78]
2d9c: ldr      x0, [x19, #0x588]
2da0: and      x0, x0, #0xffffffffffff
2da4: mov      x10, #-0xf000000000000
2da8: orr      x0, x0, x10
2dac: str      x0, [x19, #0x80]
2db0: ldr      x0, [x19, #0x598]
2db4: and      x0, x0, #0xffffffffffff
2db8: mov      x10, #-0xf000000000000
2dbc: orr      x0, x0, x10
2dc0: str      x0, [x19, #0x88]
2dc4: ldr      x0, [x19, #0x5a0]
2dc8: and      x0, x0, #0xffffffffffff
2dcc: mov      x10, #-0xf000000000000
2dd0: orr      x0, x0, x10
2dd4: str      x0, [x19, #0x90]
2dd8: ldr      d0, [x19, #0x5a8]
2ddc: fmov     x0, d0
2de0: lsr      x3, x0, #48
2de4: mov      x10, #0xfff1
2de8: cmp      x3, x10
2dec: b.lo     0x100302a9c
2df0: orr      x0, xzr, #0x7ff8000000000000
2df4: str      x0, [x19, #0x98]
2df8: ldr      d0, [x19, #0x5b8]
2dfc: fmov     x0, d0
2e00: lsr      x3, x0, #48
2e04: mov      x10, #0xfff1
2e08: cmp      x3, x10
2e0c: b.lo     0x100302abc
2e10: orr      x0, xzr, #0x7ff8000000000000
2e14: str      x0, [x19, #0xa0]
2e18: ldr      d0, [x19, #0x5c0]
2e1c: fmov     x0, d0
2e20: lsr      x3, x0, #48
2e24: mov      x10, #0xfff1
2e28: cmp      x3, x10
2e2c: b.lo     0x100302adc
2e30: orr      x0, xzr, #0x7ff8000000000000
2e34: str      x0, [x19, #0xa8]
2e38: ldr      d0, [x19, #0x5d0]
2e3c: fmov     x0, d0
2e40: lsr      x3, x0, #48
2e44: mov      x10, #0xfff1
2e48: cmp      x3, x10
2e4c: b.lo     0x100302afc
2e50: orr      x0, xzr, #0x7ff8000000000000
2e54: str      x0, [x19, #0xb0]
2e58: ldr      d0, [x19, #0x5e8]
2e5c: fmov     x0, d0
2e60: lsr      x3, x0, #48
2e64: mov      x10, #0xfff1
2e68: cmp      x3, x10
2e6c: b.lo     0x100302b1c
2e70: orr      x0, xzr, #0x7ff8000000000000
2e74: str      x0, [x19, #0xb8]
2e78: ldr      d0, [x19, #0x5f8]
2e7c: fmov     x0, d0
2e80: lsr      x3, x0, #48
2e84: mov      x10, #0xfff1
2e88: cmp      x3, x10
2e8c: b.lo     0x100302b3c
2e90: orr      x0, xzr, #0x7ff8000000000000
2e94: str      x0, [x19, #0xc0]
2e98: ldr      d0, [x19, #0x550]
2e9c: fmov     x0, d0
2ea0: lsr      x3, x0, #48
2ea4: mov      x10, #0xfff1
2ea8: cmp      x3, x10
2eac: b.lo     0x100302b5c
2eb0: orr      x0, xzr, #0x7ff8000000000000
2eb4: str      x0, [x19, #0xc8]
2eb8: ldr      d0, [x19, #0x560]
2ebc: fmov     x0, d0
2ec0: lsr      x3, x0, #48
2ec4: mov      x10, #0xfff1
2ec8: cmp      x3, x10
2ecc: b.lo     0x100302b7c
2ed0: orr      x0, xzr, #0x7ff8000000000000
2ed4: str      x0, [x19, #0xd0]
2ed8: ldr      d0, [x19, #0x600]
2edc: fmov     x0, d0
2ee0: lsr      x3, x0, #48
2ee4: mov      x10, #0xfff1
2ee8: cmp      x3, x10
2eec: b.lo     0x100302b9c
2ef0: orr      x0, xzr, #0x7ff8000000000000
2ef4: str      x0, [x19, #0xd8]
2ef8: ldr      d0, [x19, #0x610]
2efc: fmov     x0, d0
2f00: lsr      x3, x0, #48
2f04: mov      x10, #0xfff1
2f08: cmp      x3, x10
2f0c: b.lo     0x100302bbc
2f10: orr      x0, xzr, #0x7ff8000000000000
2f14: str      x0, [x19, #0xe0]
2f18: ldr      d0, [x19, #0x630]
2f1c: fmov     x0, d0
2f20: lsr      x3, x0, #48
2f24: mov      x10, #0xfff1
2f28: cmp      x3, x10
2f2c: b.lo     0x100302bdc
2f30: orr      x0, xzr, #0x7ff8000000000000
2f34: str      x0, [x19, #0xe8]
2f38: ldr      d0, [x19, #0x618]
2f3c: fmov     x0, d0
2f40: lsr      x3, x0, #48
2f44: mov      x10, #0xfff1
2f48: cmp      x3, x10
2f4c: b.lo     0x100302bfc
2f50: orr      x0, xzr, #0x7ff8000000000000
2f54: str      x0, [x19, #0xf0]
2f58: ldr      d0, [x19, #0x628]
2f5c: fmov     x0, d0
2f60: lsr      x3, x0, #48
2f64: mov      x10, #0xfff1
2f68: cmp      x3, x10
2f6c: b.lo     0x100302c1c
2f70: orr      x0, xzr, #0x7ff8000000000000
2f74: str      x0, [x19, #0xf8]
2f78: fmov     d0, d17
2f7c: fmov     x0, d0
2f80: lsr      x3, x0, #48
2f84: mov      x10, #0xfff1
2f88: cmp      x3, x10
2f8c: b.lo     0x100302c3c
2f90: orr      x0, xzr, #0x7ff8000000000000
2f94: str      x0, [x19, #0x100]
2f98: ldr      d0, [x19, #0x638]
2f9c: fmov     x0, d0
2fa0: lsr      x3, x0, #48
2fa4: mov      x10, #0xfff1
2fa8: cmp      x3, x10
2fac: b.lo     0x100302c5c
2fb0: orr      x0, xzr, #0x7ff8000000000000
2fb4: str      x0, [x19, #0x108]
2fb8: mov      x9, #0xffdf
2fbc: movk     x9, #0xffff, lsl #16
2fc0: movk     x9, #0x3, lsl #32
2fc4: str      x9, [x19, #0x390]
2fc8: str      x20, [x19, #0x398]
2fcc: mov      x0, #0x3b
2fd0: ldp      x29, x30, [sp]
2fd4: ldp      x19, x20, [sp, #0x50]
2fd8: ldp      x21, x22, [sp, #0x40]
2fdc: ldp      x23, x24, [sp, #0x30]
2fe0: ldp      x25, x26, [sp, #0x20]
2fe4: ldr      x27, [sp, #0x18]
2fe8: add      sp, sp, #0x60
2fec: ret      
2ff0: mov      x0, x4
2ff4: str      x0, [x19]
2ff8: mov      x0, x5
2ffc: str      x0, [x19, #0x8]
3000: mov      x0, x6
3004: str      x0, [x19, #0x10]
3008: mov      x0, x7
300c: str      x0, [x19, #0x18]
3010: mov      x0, x21
3014: str      x0, [x19, #0x20]
3018: fmov     d0, d2
301c: fmov     x0, d0
3020: lsr      x3, x0, #48
3024: mov      x10, #0xfff1
3028: cmp      x3, x10
302c: b.lo     0x100302cdc
3030: orr      x0, xzr, #0x7ff8000000000000
3034: str      x0, [x19, #0x30]
3038: fmov     d0, d3
303c: fmov     x0, d0
3040: lsr      x3, x0, #48
3044: mov      x10, #0xfff1
3048: cmp      x3, x10
304c: b.lo     0x100302cfc
3050: orr      x0, xzr, #0x7ff8000000000000
3054: str      x0, [x19, #0x38]
3058: fmov     d0, d4
305c: fmov     x0, d0
3060: lsr      x3, x0, #48
3064: mov      x10, #0xfff1
3068: cmp      x3, x10
306c: b.lo     0x100302d1c
3070: orr      x0, xzr, #0x7ff8000000000000
3074: str      x0, [x19, #0x40]
3078: fmov     d0, d5
307c: fmov     x0, d0
3080: lsr      x3, x0, #48
3084: mov      x10, #0xfff1
3088: cmp      x3, x10
308c: b.lo     0x100302d3c
3090: orr      x0, xzr, #0x7ff8000000000000
3094: str      x0, [x19, #0x48]
3098: mov      x0, x22
309c: and      x0, x0, #0xffffffffffff
30a0: mov      x10, #-0xf000000000000
30a4: orr      x0, x0, x10
30a8: str      x0, [x19, #0x50]
30ac: ldr      d0, [x19, #0x550]
30b0: fmov     x0, d0
30b4: lsr      x3, x0, #48
30b8: mov      x10, #0xfff1
30bc: cmp      x3, x10
30c0: b.lo     0x100302d70
30c4: orr      x0, xzr, #0x7ff8000000000000
30c8: str      x0, [x19, #0x58]
30cc: mov      x0, x23
30d0: and      x0, x0, #0xffffffffffff
30d4: mov      x10, #-0xf000000000000
30d8: orr      x0, x0, x10
30dc: str      x0, [x19, #0x60]
30e0: fmov     d0, d6
30e4: fmov     x0, d0
30e8: lsr      x3, x0, #48
30ec: mov      x10, #0xfff1
30f0: cmp      x3, x10
30f4: b.lo     0x100302da4
30f8: orr      x0, xzr, #0x7ff8000000000000
30fc: str      x0, [x19, #0x68]
3100: fmov     d0, d7
3104: fmov     x0, d0
3108: lsr      x3, x0, #48
310c: mov      x10, #0xfff1
3110: cmp      x3, x10
3114: b.lo     0x100302dc4
3118: orr      x0, xzr, #0x7ff8000000000000
311c: str      x0, [x19, #0x70]
3120: ldr      x0, [x19, #0x580]
3124: and      x0, x0, #0xffffffffffff
3128: mov      x10, #-0xf000000000000
312c: orr      x0, x0, x10
3130: str      x0, [x19, #0x78]
3134: ldr      x0, [x19, #0x588]
3138: and      x0, x0, #0xffffffffffff
313c: mov      x10, #-0xf000000000000
3140: orr      x0, x0, x10
3144: str      x0, [x19, #0x80]
3148: ldr      x0, [x19, #0x598]
314c: and      x0, x0, #0xffffffffffff
3150: mov      x10, #-0xf000000000000
3154: orr      x0, x0, x10
3158: str      x0, [x19, #0x88]
315c: ldr      x0, [x19, #0x5a0]
3160: and      x0, x0, #0xffffffffffff
3164: mov      x10, #-0xf000000000000
3168: orr      x0, x0, x10
316c: str      x0, [x19, #0x90]
3170: ldr      d0, [x19, #0x5a8]
3174: fmov     x0, d0
3178: lsr      x3, x0, #48
317c: mov      x10, #0xfff1
3180: cmp      x3, x10
3184: b.lo     0x100302e34
3188: orr      x0, xzr, #0x7ff8000000000000
318c: str      x0, [x19, #0x98]
3190: ldr      d0, [x19, #0x5b8]
3194: fmov     x0, d0
3198: lsr      x3, x0, #48
319c: mov      x10, #0xfff1
31a0: cmp      x3, x10
31a4: b.lo     0x100302e54
31a8: orr      x0, xzr, #0x7ff8000000000000
31ac: str      x0, [x19, #0xa0]
31b0: ldr      d0, [x19, #0x5c0]
31b4: fmov     x0, d0
31b8: lsr      x3, x0, #48
31bc: mov      x10, #0xfff1
31c0: cmp      x3, x10
31c4: b.lo     0x100302e74
31c8: orr      x0, xzr, #0x7ff8000000000000
31cc: str      x0, [x19, #0xa8]
31d0: ldr      d0, [x19, #0x5d0]
31d4: fmov     x0, d0
31d8: lsr      x3, x0, #48
31dc: mov      x10, #0xfff1
31e0: cmp      x3, x10
31e4: b.lo     0x100302e94
31e8: orr      x0, xzr, #0x7ff8000000000000
31ec: str      x0, [x19, #0xb0]
31f0: ldr      d0, [x19, #0x5e8]
31f4: fmov     x0, d0
31f8: lsr      x3, x0, #48
31fc: mov      x10, #0xfff1
3200: cmp      x3, x10
3204: b.lo     0x100302eb4
3208: orr      x0, xzr, #0x7ff8000000000000
320c: str      x0, [x19, #0xb8]
3210: ldr      d0, [x19, #0x5f8]
3214: fmov     x0, d0
3218: lsr      x3, x0, #48
321c: mov      x10, #0xfff1
3220: cmp      x3, x10
3224: b.lo     0x100302ed4
3228: orr      x0, xzr, #0x7ff8000000000000
322c: str      x0, [x19, #0xc0]
3230: ldr      d0, [x19, #0x550]
3234: fmov     x0, d0
3238: lsr      x3, x0, #48
323c: mov      x10, #0xfff1
3240: cmp      x3, x10
3244: b.lo     0x100302ef4
3248: orr      x0, xzr, #0x7ff8000000000000
324c: str      x0, [x19, #0xc8]
3250: ldr      d0, [x19, #0x560]
3254: fmov     x0, d0
3258: lsr      x3, x0, #48
325c: mov      x10, #0xfff1
3260: cmp      x3, x10
3264: b.lo     0x100302f14
3268: orr      x0, xzr, #0x7ff8000000000000
326c: str      x0, [x19, #0xd0]
3270: ldr      d0, [x19, #0x600]
3274: fmov     x0, d0
3278: lsr      x3, x0, #48
327c: mov      x10, #0xfff1
3280: cmp      x3, x10
3284: b.lo     0x100302f34
3288: orr      x0, xzr, #0x7ff8000000000000
328c: str      x0, [x19, #0xd8]
3290: ldr      d0, [x19, #0x610]
3294: fmov     x0, d0
3298: lsr      x3, x0, #48
329c: mov      x10, #0xfff1
32a0: cmp      x3, x10
32a4: b.lo     0x100302f54
32a8: orr      x0, xzr, #0x7ff8000000000000
32ac: str      x0, [x19, #0xe0]
32b0: ldr      d0, [x19, #0x630]
32b4: fmov     x0, d0
32b8: lsr      x3, x0, #48
32bc: mov      x10, #0xfff1
32c0: cmp      x3, x10
32c4: b.lo     0x100302f74
32c8: orr      x0, xzr, #0x7ff8000000000000
32cc: str      x0, [x19, #0xe8]
32d0: ldr      d0, [x19, #0x618]
32d4: fmov     x0, d0
32d8: lsr      x3, x0, #48
32dc: mov      x10, #0xfff1
32e0: cmp      x3, x10
32e4: b.lo     0x100302f94
32e8: orr      x0, xzr, #0x7ff8000000000000
32ec: str      x0, [x19, #0xf0]
32f0: ldr      d0, [x19, #0x628]
32f4: fmov     x0, d0
32f8: lsr      x3, x0, #48
32fc: mov      x10, #0xfff1
3300: cmp      x3, x10
3304: b.lo     0x100302fb4
3308: orr      x0, xzr, #0x7ff8000000000000
330c: str      x0, [x19, #0xf8]
3310: fmov     d0, d17
3314: fmov     x0, d0
3318: lsr      x3, x0, #48
331c: mov      x10, #0xfff1
3320: cmp      x3, x10
3324: b.lo     0x100302fd4
3328: orr      x0, xzr, #0x7ff8000000000000
332c: str      x0, [x19, #0x100]
3330: ldr      d0, [x19, #0x638]
3334: fmov     x0, d0
3338: lsr      x3, x0, #48
333c: mov      x10, #0xfff1
3340: cmp      x3, x10
3344: b.lo     0x100302ff4
3348: orr      x0, xzr, #0x7ff8000000000000
334c: str      x0, [x19, #0x108]
3350: ldr      d0, [x19, #0x648]
3354: fmov     x0, d0
3358: lsr      x3, x0, #48
335c: mov      x10, #0xfff1
3360: cmp      x3, x10
3364: b.lo     0x100303014
3368: orr      x0, xzr, #0x7ff8000000000000
336c: str      x0, [x19, #0x110]
3370: ldr      d0, [x19, #0x650]
3374: fmov     x0, d0
3378: lsr      x3, x0, #48
337c: mov      x10, #0xfff1
3380: cmp      x3, x10
3384: b.lo     0x100303034
3388: orr      x0, xzr, #0x7ff8000000000000
338c: str      x0, [x19, #0x118]
3390: ldr      d0, [x19, #0x658]
3394: fmov     x0, d0
3398: lsr      x3, x0, #48
339c: mov      x10, #0xfff1
33a0: cmp      x3, x10
33a4: b.lo     0x100303054
33a8: orr      x0, xzr, #0x7ff8000000000000
33ac: str      x0, [x19, #0x120]
33b0: mov      x9, #0xffdf
33b4: movk     x9, #0xffff, lsl #16
33b8: movk     x9, #0x1f, lsl #32
33bc: str      x9, [x19, #0x390]
33c0: str      x20, [x19, #0x398]
33c4: mov      x0, #0x3e
33c8: ldp      x29, x30, [sp]
33cc: ldp      x19, x20, [sp, #0x50]
33d0: ldp      x21, x22, [sp, #0x40]
33d4: ldp      x23, x24, [sp, #0x30]
33d8: ldp      x25, x26, [sp, #0x20]
33dc: ldr      x27, [sp, #0x18]
33e0: add      sp, sp, #0x60
33e4: ret      
33e8: mov      x0, x4
33ec: str      x0, [x19]
33f0: mov      x0, x5
33f4: str      x0, [x19, #0x8]
33f8: mov      x0, x6
33fc: str      x0, [x19, #0x10]
3400: mov      x0, x7
3404: str      x0, [x19, #0x18]
3408: mov      x0, x21
340c: str      x0, [x19, #0x20]
3410: fmov     d0, d2
3414: fmov     x0, d0
3418: lsr      x3, x0, #48
341c: mov      x10, #0xfff1
3420: cmp      x3, x10
3424: b.lo     0x1003030d4
3428: orr      x0, xzr, #0x7ff8000000000000
342c: str      x0, [x19, #0x30]
3430: fmov     d0, d3
3434: fmov     x0, d0
3438: lsr      x3, x0, #48
343c: mov      x10, #0xfff1
3440: cmp      x3, x10
3444: b.lo     0x1003030f4
3448: orr      x0, xzr, #0x7ff8000000000000
344c: str      x0, [x19, #0x38]
3450: fmov     d0, d4
3454: fmov     x0, d0
3458: lsr      x3, x0, #48
345c: mov      x10, #0xfff1
3460: cmp      x3, x10
3464: b.lo     0x100303114
3468: orr      x0, xzr, #0x7ff8000000000000
346c: str      x0, [x19, #0x40]
3470: fmov     d0, d5
3474: fmov     x0, d0
3478: lsr      x3, x0, #48
347c: mov      x10, #0xfff1
3480: cmp      x3, x10
3484: b.lo     0x100303134
3488: orr      x0, xzr, #0x7ff8000000000000
348c: str      x0, [x19, #0x48]
3490: mov      x0, x22
3494: and      x0, x0, #0xffffffffffff
3498: mov      x10, #-0xf000000000000
349c: orr      x0, x0, x10
34a0: str      x0, [x19, #0x50]
34a4: ldr      d0, [x19, #0x550]
34a8: fmov     x0, d0
34ac: lsr      x3, x0, #48
34b0: mov      x10, #0xfff1
34b4: cmp      x3, x10
34b8: b.lo     0x100303168
34bc: orr      x0, xzr, #0x7ff8000000000000
34c0: str      x0, [x19, #0x58]
34c4: mov      x0, x23
34c8: and      x0, x0, #0xffffffffffff
34cc: mov      x10, #-0xf000000000000
34d0: orr      x0, x0, x10
34d4: str      x0, [x19, #0x60]
34d8: fmov     d0, d6
34dc: fmov     x0, d0
34e0: lsr      x3, x0, #48
34e4: mov      x10, #0xfff1
34e8: cmp      x3, x10
34ec: b.lo     0x10030319c
34f0: orr      x0, xzr, #0x7ff8000000000000
34f4: str      x0, [x19, #0x68]
34f8: fmov     d0, d7
34fc: fmov     x0, d0
3500: lsr      x3, x0, #48
3504: mov      x10, #0xfff1
3508: cmp      x3, x10
350c: b.lo     0x1003031bc
3510: orr      x0, xzr, #0x7ff8000000000000
3514: str      x0, [x19, #0x70]
3518: ldr      x0, [x19, #0x580]
351c: and      x0, x0, #0xffffffffffff
3520: mov      x10, #-0xf000000000000
3524: orr      x0, x0, x10
3528: str      x0, [x19, #0x78]
352c: ldr      x0, [x19, #0x588]
3530: and      x0, x0, #0xffffffffffff
3534: mov      x10, #-0xf000000000000
3538: orr      x0, x0, x10
353c: str      x0, [x19, #0x80]
3540: ldr      x0, [x19, #0x598]
3544: and      x0, x0, #0xffffffffffff
3548: mov      x10, #-0xf000000000000
354c: orr      x0, x0, x10
3550: str      x0, [x19, #0x88]
3554: ldr      x0, [x19, #0x5a0]
3558: and      x0, x0, #0xffffffffffff
355c: mov      x10, #-0xf000000000000
3560: orr      x0, x0, x10
3564: str      x0, [x19, #0x90]
3568: ldr      d0, [x19, #0x5a8]
356c: fmov     x0, d0
3570: lsr      x3, x0, #48
3574: mov      x10, #0xfff1
3578: cmp      x3, x10
357c: b.lo     0x10030322c
3580: orr      x0, xzr, #0x7ff8000000000000
3584: str      x0, [x19, #0x98]
3588: ldr      d0, [x19, #0x5b8]
358c: fmov     x0, d0
3590: lsr      x3, x0, #48
3594: mov      x10, #0xfff1
3598: cmp      x3, x10
359c: b.lo     0x10030324c
35a0: orr      x0, xzr, #0x7ff8000000000000
35a4: str      x0, [x19, #0xa0]
35a8: ldr      d0, [x19, #0x5c0]
35ac: fmov     x0, d0
35b0: lsr      x3, x0, #48
35b4: mov      x10, #0xfff1
35b8: cmp      x3, x10
35bc: b.lo     0x10030326c
35c0: orr      x0, xzr, #0x7ff8000000000000
35c4: str      x0, [x19, #0xa8]
35c8: ldr      d0, [x19, #0x5d0]
35cc: fmov     x0, d0
35d0: lsr      x3, x0, #48
35d4: mov      x10, #0xfff1
35d8: cmp      x3, x10
35dc: b.lo     0x10030328c
35e0: orr      x0, xzr, #0x7ff8000000000000
35e4: str      x0, [x19, #0xb0]
35e8: ldr      d0, [x19, #0x5e8]
35ec: fmov     x0, d0
35f0: lsr      x3, x0, #48
35f4: mov      x10, #0xfff1
35f8: cmp      x3, x10
35fc: b.lo     0x1003032ac
3600: orr      x0, xzr, #0x7ff8000000000000
3604: str      x0, [x19, #0xb8]
3608: ldr      d0, [x19, #0x5f8]
360c: fmov     x0, d0
3610: lsr      x3, x0, #48
3614: mov      x10, #0xfff1
3618: cmp      x3, x10
361c: b.lo     0x1003032cc
3620: orr      x0, xzr, #0x7ff8000000000000
3624: str      x0, [x19, #0xc0]
3628: ldr      d0, [x19, #0x550]
362c: fmov     x0, d0
3630: lsr      x3, x0, #48
3634: mov      x10, #0xfff1
3638: cmp      x3, x10
363c: b.lo     0x1003032ec
3640: orr      x0, xzr, #0x7ff8000000000000
3644: str      x0, [x19, #0xc8]
3648: ldr      d0, [x19, #0x560]
364c: fmov     x0, d0
3650: lsr      x3, x0, #48
3654: mov      x10, #0xfff1
3658: cmp      x3, x10
365c: b.lo     0x10030330c
3660: orr      x0, xzr, #0x7ff8000000000000
3664: str      x0, [x19, #0xd0]
3668: ldr      d0, [x19, #0x600]
366c: fmov     x0, d0
3670: lsr      x3, x0, #48
3674: mov      x10, #0xfff1
3678: cmp      x3, x10
367c: b.lo     0x10030332c
3680: orr      x0, xzr, #0x7ff8000000000000
3684: str      x0, [x19, #0xd8]
3688: ldr      d0, [x19, #0x610]
368c: fmov     x0, d0
3690: lsr      x3, x0, #48
3694: mov      x10, #0xfff1
3698: cmp      x3, x10
369c: b.lo     0x10030334c
36a0: orr      x0, xzr, #0x7ff8000000000000
36a4: str      x0, [x19, #0xe0]
36a8: ldr      d0, [x19, #0x630]
36ac: fmov     x0, d0
36b0: lsr      x3, x0, #48
36b4: mov      x10, #0xfff1
36b8: cmp      x3, x10
36bc: b.lo     0x10030336c
36c0: orr      x0, xzr, #0x7ff8000000000000
36c4: str      x0, [x19, #0xe8]
36c8: ldr      d0, [x19, #0x618]
36cc: fmov     x0, d0
36d0: lsr      x3, x0, #48
36d4: mov      x10, #0xfff1
36d8: cmp      x3, x10
36dc: b.lo     0x10030338c
36e0: orr      x0, xzr, #0x7ff8000000000000
36e4: str      x0, [x19, #0xf0]
36e8: ldr      d0, [x19, #0x628]
36ec: fmov     x0, d0
36f0: lsr      x3, x0, #48
36f4: mov      x10, #0xfff1
36f8: cmp      x3, x10
36fc: b.lo     0x1003033ac
3700: orr      x0, xzr, #0x7ff8000000000000
3704: str      x0, [x19, #0xf8]
3708: ldr      d0, [x19, #0x680]
370c: fmov     x0, d0
3710: lsr      x3, x0, #48
3714: mov      x10, #0xfff1
3718: cmp      x3, x10
371c: b.lo     0x1003033cc
3720: orr      x0, xzr, #0x7ff8000000000000
3724: str      x0, [x19, #0x100]
3728: ldr      d0, [x19, #0x638]
372c: fmov     x0, d0
3730: lsr      x3, x0, #48
3734: mov      x10, #0xfff1
3738: cmp      x3, x10
373c: b.lo     0x1003033ec
3740: orr      x0, xzr, #0x7ff8000000000000
3744: str      x0, [x19, #0x108]
3748: ldr      d0, [x19, #0x648]
374c: fmov     x0, d0
3750: lsr      x3, x0, #48
3754: mov      x10, #0xfff1
3758: cmp      x3, x10
375c: b.lo     0x10030340c
3760: orr      x0, xzr, #0x7ff8000000000000
3764: str      x0, [x19, #0x110]
3768: ldr      d0, [x19, #0x670]
376c: fmov     x0, d0
3770: lsr      x3, x0, #48
3774: mov      x10, #0xfff1
3778: cmp      x3, x10
377c: b.lo     0x10030342c
3780: orr      x0, xzr, #0x7ff8000000000000
3784: str      x0, [x19, #0x118]
3788: ldr      d0, [x19, #0x658]
378c: fmov     x0, d0
3790: lsr      x3, x0, #48
3794: mov      x10, #0xfff1
3798: cmp      x3, x10
379c: b.lo     0x10030344c
37a0: orr      x0, xzr, #0x7ff8000000000000
37a4: str      x0, [x19, #0x120]
37a8: ldr      d0, [x19, #0x668]
37ac: fmov     x0, d0
37b0: lsr      x3, x0, #48
37b4: mov      x10, #0xfff1
37b8: cmp      x3, x10
37bc: b.lo     0x10030346c
37c0: orr      x0, xzr, #0x7ff8000000000000
37c4: str      x0, [x19, #0x128]
37c8: ldr      d0, [x19, #0x678]
37cc: fmov     x0, d0
37d0: lsr      x3, x0, #48
37d4: mov      x10, #0xfff1
37d8: cmp      x3, x10
37dc: b.lo     0x10030348c
37e0: orr      x0, xzr, #0x7ff8000000000000
37e4: str      x0, [x19, #0x130]
37e8: mov      x9, #0xffdf
37ec: movk     x9, #0xffff, lsl #16
37f0: movk     x9, #0x7f, lsl #32
37f4: str      x9, [x19, #0x390]
37f8: str      x20, [x19, #0x398]
37fc: mov      x0, #0x43
3800: ldp      x29, x30, [sp]
3804: ldp      x19, x20, [sp, #0x50]
3808: ldp      x21, x22, [sp, #0x40]
380c: ldp      x23, x24, [sp, #0x30]
3810: ldp      x25, x26, [sp, #0x20]
3814: ldr      x27, [sp, #0x18]
3818: add      sp, sp, #0x60
381c: ret      
3820: mov      x0, x4
3824: str      x0, [x19]
3828: mov      x0, x5
382c: str      x0, [x19, #0x8]
3830: mov      x0, x6
3834: str      x0, [x19, #0x10]
3838: mov      x0, x7
383c: str      x0, [x19, #0x18]
3840: mov      x0, x21
3844: str      x0, [x19, #0x20]
3848: fmov     d0, d2
384c: fmov     x0, d0
3850: lsr      x3, x0, #48
3854: mov      x10, #0xfff1
3858: cmp      x3, x10
385c: b.lo     0x10030350c
3860: orr      x0, xzr, #0x7ff8000000000000
3864: str      x0, [x19, #0x30]
3868: fmov     d0, d3
386c: fmov     x0, d0
3870: lsr      x3, x0, #48
3874: mov      x10, #0xfff1
3878: cmp      x3, x10
387c: b.lo     0x10030352c
3880: orr      x0, xzr, #0x7ff8000000000000
3884: str      x0, [x19, #0x38]
3888: fmov     d0, d4
388c: fmov     x0, d0
3890: lsr      x3, x0, #48
3894: mov      x10, #0xfff1
3898: cmp      x3, x10
389c: b.lo     0x10030354c
38a0: orr      x0, xzr, #0x7ff8000000000000
38a4: str      x0, [x19, #0x40]
38a8: fmov     d0, d5
38ac: fmov     x0, d0
38b0: lsr      x3, x0, #48
38b4: mov      x10, #0xfff1
38b8: cmp      x3, x10
38bc: b.lo     0x10030356c
38c0: orr      x0, xzr, #0x7ff8000000000000
38c4: str      x0, [x19, #0x48]
38c8: mov      x0, x22
38cc: and      x0, x0, #0xffffffffffff
38d0: mov      x10, #-0xf000000000000
38d4: orr      x0, x0, x10
38d8: str      x0, [x19, #0x50]
38dc: ldr      d0, [x19, #0x550]
38e0: fmov     x0, d0
38e4: lsr      x3, x0, #48
38e8: mov      x10, #0xfff1
38ec: cmp      x3, x10
38f0: b.lo     0x1003035a0
38f4: orr      x0, xzr, #0x7ff8000000000000
38f8: str      x0, [x19, #0x58]
38fc: mov      x0, x23
3900: and      x0, x0, #0xffffffffffff
3904: mov      x10, #-0xf000000000000
3908: orr      x0, x0, x10
390c: str      x0, [x19, #0x60]
3910: fmov     d0, d6
3914: fmov     x0, d0
3918: lsr      x3, x0, #48
391c: mov      x10, #0xfff1
3920: cmp      x3, x10
3924: b.lo     0x1003035d4
3928: orr      x0, xzr, #0x7ff8000000000000
392c: str      x0, [x19, #0x68]
3930: fmov     d0, d7
3934: fmov     x0, d0
3938: lsr      x3, x0, #48
393c: mov      x10, #0xfff1
3940: cmp      x3, x10
3944: b.lo     0x1003035f4
3948: orr      x0, xzr, #0x7ff8000000000000
394c: str      x0, [x19, #0x70]
3950: ldr      x0, [x19, #0x580]
3954: and      x0, x0, #0xffffffffffff
3958: mov      x10, #-0xf000000000000
395c: orr      x0, x0, x10
3960: str      x0, [x19, #0x78]
3964: ldr      x0, [x19, #0x588]
3968: and      x0, x0, #0xffffffffffff
396c: mov      x10, #-0xf000000000000
3970: orr      x0, x0, x10
3974: str      x0, [x19, #0x80]
3978: ldr      x0, [x19, #0x598]
397c: and      x0, x0, #0xffffffffffff
3980: mov      x10, #-0xf000000000000
3984: orr      x0, x0, x10
3988: str      x0, [x19, #0x88]
398c: ldr      x0, [x19, #0x5a0]
3990: and      x0, x0, #0xffffffffffff
3994: mov      x10, #-0xf000000000000
3998: orr      x0, x0, x10
399c: str      x0, [x19, #0x90]
39a0: ldr      d0, [x19, #0x5a8]
39a4: fmov     x0, d0
39a8: lsr      x3, x0, #48
39ac: mov      x10, #0xfff1
39b0: cmp      x3, x10
39b4: b.lo     0x100303664
39b8: orr      x0, xzr, #0x7ff8000000000000
39bc: str      x0, [x19, #0x98]
39c0: ldr      d0, [x19, #0x5b8]
39c4: fmov     x0, d0
39c8: lsr      x3, x0, #48
39cc: mov      x10, #0xfff1
39d0: cmp      x3, x10
39d4: b.lo     0x100303684
39d8: orr      x0, xzr, #0x7ff8000000000000
39dc: str      x0, [x19, #0xa0]
39e0: ldr      d0, [x19, #0x5c0]
39e4: fmov     x0, d0
39e8: lsr      x3, x0, #48
39ec: mov      x10, #0xfff1
39f0: cmp      x3, x10
39f4: b.lo     0x1003036a4
39f8: orr      x0, xzr, #0x7ff8000000000000
39fc: str      x0, [x19, #0xa8]
3a00: ldr      d0, [x19, #0x5d0]
3a04: fmov     x0, d0
3a08: lsr      x3, x0, #48
3a0c: mov      x10, #0xfff1
3a10: cmp      x3, x10
3a14: b.lo     0x1003036c4
3a18: orr      x0, xzr, #0x7ff8000000000000
3a1c: str      x0, [x19, #0xb0]
3a20: ldr      d0, [x19, #0x5e8]
3a24: fmov     x0, d0
3a28: lsr      x3, x0, #48
3a2c: mov      x10, #0xfff1
3a30: cmp      x3, x10
3a34: b.lo     0x1003036e4
3a38: orr      x0, xzr, #0x7ff8000000000000
3a3c: str      x0, [x19, #0xb8]
3a40: ldr      d0, [x19, #0x5f8]
3a44: fmov     x0, d0
3a48: lsr      x3, x0, #48
3a4c: mov      x10, #0xfff1
3a50: cmp      x3, x10
3a54: b.lo     0x100303704
3a58: orr      x0, xzr, #0x7ff8000000000000
3a5c: str      x0, [x19, #0xc0]
3a60: ldr      d0, [x19, #0x550]
3a64: fmov     x0, d0
3a68: lsr      x3, x0, #48
3a6c: mov      x10, #0xfff1
3a70: cmp      x3, x10
3a74: b.lo     0x100303724
3a78: orr      x0, xzr, #0x7ff8000000000000
3a7c: str      x0, [x19, #0xc8]
3a80: ldr      d0, [x19, #0x560]
3a84: fmov     x0, d0
3a88: lsr      x3, x0, #48
3a8c: mov      x10, #0xfff1
3a90: cmp      x3, x10
3a94: b.lo     0x100303744
3a98: orr      x0, xzr, #0x7ff8000000000000
3a9c: str      x0, [x19, #0xd0]
3aa0: ldr      d0, [x19, #0x600]
3aa4: fmov     x0, d0
3aa8: lsr      x3, x0, #48
3aac: mov      x10, #0xfff1
3ab0: cmp      x3, x10
3ab4: b.lo     0x100303764
3ab8: orr      x0, xzr, #0x7ff8000000000000
3abc: str      x0, [x19, #0xd8]
3ac0: ldr      d0, [x19, #0x610]
3ac4: fmov     x0, d0
3ac8: lsr      x3, x0, #48
3acc: mov      x10, #0xfff1
3ad0: cmp      x3, x10
3ad4: b.lo     0x100303784
3ad8: orr      x0, xzr, #0x7ff8000000000000
3adc: str      x0, [x19, #0xe0]
3ae0: ldr      d0, [x19, #0x630]
3ae4: fmov     x0, d0
3ae8: lsr      x3, x0, #48
3aec: mov      x10, #0xfff1
3af0: cmp      x3, x10
3af4: b.lo     0x1003037a4
3af8: orr      x0, xzr, #0x7ff8000000000000
3afc: str      x0, [x19, #0xe8]
3b00: ldr      d0, [x19, #0x618]
3b04: fmov     x0, d0
3b08: lsr      x3, x0, #48
3b0c: mov      x10, #0xfff1
3b10: cmp      x3, x10
3b14: b.lo     0x1003037c4
3b18: orr      x0, xzr, #0x7ff8000000000000
3b1c: str      x0, [x19, #0xf0]
3b20: ldr      d0, [x19, #0x628]
3b24: fmov     x0, d0
3b28: lsr      x3, x0, #48
3b2c: mov      x10, #0xfff1
3b30: cmp      x3, x10
3b34: b.lo     0x1003037e4
3b38: orr      x0, xzr, #0x7ff8000000000000
3b3c: str      x0, [x19, #0xf8]
3b40: ldr      d0, [x19, #0x680]
3b44: fmov     x0, d0
3b48: lsr      x3, x0, #48
3b4c: mov      x10, #0xfff1
3b50: cmp      x3, x10
3b54: b.lo     0x100303804
3b58: orr      x0, xzr, #0x7ff8000000000000
3b5c: str      x0, [x19, #0x100]
3b60: ldr      d0, [x19, #0x638]
3b64: fmov     x0, d0
3b68: lsr      x3, x0, #48
3b6c: mov      x10, #0xfff1
3b70: cmp      x3, x10
3b74: b.lo     0x100303824
3b78: orr      x0, xzr, #0x7ff8000000000000
3b7c: str      x0, [x19, #0x108]
3b80: ldr      d0, [x19, #0x648]
3b84: fmov     x0, d0
3b88: lsr      x3, x0, #48
3b8c: mov      x10, #0xfff1
3b90: cmp      x3, x10
3b94: b.lo     0x100303844
3b98: orr      x0, xzr, #0x7ff8000000000000
3b9c: str      x0, [x19, #0x110]
3ba0: ldr      d0, [x19, #0x670]
3ba4: fmov     x0, d0
3ba8: lsr      x3, x0, #48
3bac: mov      x10, #0xfff1
3bb0: cmp      x3, x10
3bb4: b.lo     0x100303864
3bb8: orr      x0, xzr, #0x7ff8000000000000
3bbc: str      x0, [x19, #0x118]
3bc0: ldr      d0, [x19, #0x658]
3bc4: fmov     x0, d0
3bc8: lsr      x3, x0, #48
3bcc: mov      x10, #0xfff1
3bd0: cmp      x3, x10
3bd4: b.lo     0x100303884
3bd8: orr      x0, xzr, #0x7ff8000000000000
3bdc: str      x0, [x19, #0x120]
3be0: ldr      d0, [x19, #0x668]
3be4: fmov     x0, d0
3be8: lsr      x3, x0, #48
3bec: mov      x10, #0xfff1
3bf0: cmp      x3, x10
3bf4: b.lo     0x1003038a4
3bf8: orr      x0, xzr, #0x7ff8000000000000
3bfc: str      x0, [x19, #0x128]
3c00: ldr      d0, [x19, #0x678]
3c04: fmov     x0, d0
3c08: lsr      x3, x0, #48
3c0c: mov      x10, #0xfff1
3c10: cmp      x3, x10
3c14: b.lo     0x1003038c4
3c18: orr      x0, xzr, #0x7ff8000000000000
3c1c: str      x0, [x19, #0x130]
3c20: mov      x9, #0xffdf
3c24: movk     x9, #0xffff, lsl #16
3c28: movk     x9, #0x7f, lsl #32
3c2c: str      x9, [x19, #0x390]
3c30: str      x20, [x19, #0x398]
3c34: mov      x0, #0x44
3c38: ldp      x29, x30, [sp]
3c3c: ldp      x19, x20, [sp, #0x50]
3c40: ldp      x21, x22, [sp, #0x40]
3c44: ldp      x23, x24, [sp, #0x30]
3c48: ldp      x25, x26, [sp, #0x20]
3c4c: ldr      x27, [sp, #0x18]
3c50: add      sp, sp, #0x60
3c54: ret      
3c58: ldr      x0, [x19, #0x3a0]
3c5c: str      x0, [x19]
3c60: ldr      x0, [x19, #0x3a8]
3c64: str      x0, [x19, #0x8]
3c68: ldr      x0, [x19, #0x3b0]
3c6c: str      x0, [x19, #0x10]
3c70: ldr      x0, [x19, #0x3b8]
3c74: str      x0, [x19, #0x18]
3c78: ldr      x0, [x19, #0x3c0]
3c7c: str      x0, [x19, #0x20]
3c80: fmov     d0, d16
3c84: fmov     x0, d0
3c88: lsr      x3, x0, #48
3c8c: mov      x10, #0xfff1
3c90: cmp      x3, x10
3c94: b.lo     0x100303944
3c98: orr      x0, xzr, #0x7ff8000000000000
3c9c: str      x0, [x19, #0x30]
3ca0: fmov     d0, d17
3ca4: fmov     x0, d0
3ca8: lsr      x3, x0, #48
3cac: mov      x10, #0xfff1
3cb0: cmp      x3, x10
3cb4: b.lo     0x100303964
3cb8: orr      x0, xzr, #0x7ff8000000000000
3cbc: str      x0, [x19, #0x38]
3cc0: ldr      d0, [x19, #0x3c8]
3cc4: fmov     x0, d0
3cc8: lsr      x3, x0, #48
3ccc: mov      x10, #0xfff1
3cd0: cmp      x3, x10
3cd4: b.lo     0x100303984
3cd8: orr      x0, xzr, #0x7ff8000000000000
3cdc: str      x0, [x19, #0x40]
3ce0: ldr      d0, [x19, #0x3d0]
3ce4: fmov     x0, d0
3ce8: lsr      x3, x0, #48
3cec: mov      x10, #0xfff1
3cf0: cmp      x3, x10
3cf4: b.lo     0x1003039a4
3cf8: orr      x0, xzr, #0x7ff8000000000000
3cfc: str      x0, [x19, #0x48]
3d00: ldr      x0, [x19, #0x3d8]
3d04: and      x0, x0, #0xffffffffffff
3d08: mov      x10, #-0xf000000000000
3d0c: orr      x0, x0, x10
3d10: str      x0, [x19, #0x50]
3d14: ldr      d0, [x19, #0x3e0]
3d18: fmov     x0, d0
3d1c: lsr      x3, x0, #48
3d20: mov      x10, #0xfff1
3d24: cmp      x3, x10
3d28: b.lo     0x1003039d8
3d2c: orr      x0, xzr, #0x7ff8000000000000
3d30: str      x0, [x19, #0x58]
3d34: ldr      x0, [x19, #0x3e8]
3d38: and      x0, x0, #0xffffffffffff
3d3c: mov      x10, #-0xf000000000000
3d40: orr      x0, x0, x10
3d44: str      x0, [x19, #0x60]
3d48: ldr      x0, [x19, #0x698]
3d4c: str      x0, [x19, #0xc8]
3d50: mov      x9, #0x1fdf
3d54: movk     x9, #0x200, lsl #16
3d58: str      x9, [x19, #0x390]
3d5c: str      x20, [x19, #0x398]
3d60: mov      x0, #0x46
3d64: ldp      x29, x30, [sp]
3d68: ldp      x19, x20, [sp, #0x50]
3d6c: ldp      x21, x22, [sp, #0x40]
3d70: ldp      x23, x24, [sp, #0x30]
3d74: ldp      x25, x26, [sp, #0x20]
3d78: ldr      x27, [sp, #0x18]
3d7c: add      sp, sp, #0x60
3d80: ret      
3d84: ldr      x0, [x19, #0x3a0]
3d88: str      x0, [x19]
3d8c: ldr      x0, [x19, #0x3a8]
3d90: str      x0, [x19, #0x8]
3d94: ldr      x0, [x19, #0x3b0]
3d98: str      x0, [x19, #0x10]
3d9c: ldr      x0, [x19, #0x3b8]
3da0: str      x0, [x19, #0x18]
3da4: ldr      x0, [x19, #0x3c0]
3da8: str      x0, [x19, #0x20]
3dac: fmov     d0, d16
3db0: fmov     x0, d0
3db4: lsr      x3, x0, #48
3db8: mov      x10, #0xfff1
3dbc: cmp      x3, x10
3dc0: b.lo     0x100303a70
3dc4: orr      x0, xzr, #0x7ff8000000000000
3dc8: str      x0, [x19, #0x30]
3dcc: fmov     d0, d17
3dd0: fmov     x0, d0
3dd4: lsr      x3, x0, #48
3dd8: mov      x10, #0xfff1
3ddc: cmp      x3, x10
3de0: b.lo     0x100303a90
3de4: orr      x0, xzr, #0x7ff8000000000000
3de8: str      x0, [x19, #0x38]
3dec: ldr      d0, [x19, #0x3c8]
3df0: fmov     x0, d0
3df4: lsr      x3, x0, #48
3df8: mov      x10, #0xfff1
3dfc: cmp      x3, x10
3e00: b.lo     0x100303ab0
3e04: orr      x0, xzr, #0x7ff8000000000000
3e08: str      x0, [x19, #0x40]
3e0c: ldr      d0, [x19, #0x3d0]
3e10: fmov     x0, d0
3e14: lsr      x3, x0, #48
3e18: mov      x10, #0xfff1
3e1c: cmp      x3, x10
3e20: b.lo     0x100303ad0
3e24: orr      x0, xzr, #0x7ff8000000000000
3e28: str      x0, [x19, #0x48]
3e2c: ldr      x0, [x19, #0x3d8]
3e30: and      x0, x0, #0xffffffffffff
3e34: mov      x10, #-0xf000000000000
3e38: orr      x0, x0, x10
3e3c: str      x0, [x19, #0x50]
3e40: ldr      d0, [x19, #0x3e0]
3e44: fmov     x0, d0
3e48: lsr      x3, x0, #48
3e4c: mov      x10, #0xfff1
3e50: cmp      x3, x10
3e54: b.lo     0x100303b04
3e58: orr      x0, xzr, #0x7ff8000000000000
3e5c: str      x0, [x19, #0x58]
3e60: ldr      x0, [x19, #0x3e8]
3e64: and      x0, x0, #0xffffffffffff
3e68: mov      x10, #-0xf000000000000
3e6c: orr      x0, x0, x10
3e70: str      x0, [x19, #0x60]
3e74: ldr      x0, [x19, #0x698]
3e78: str      x0, [x19, #0xc8]
3e7c: mov      x9, #0x1fdf
3e80: movk     x9, #0x200, lsl #16
3e84: str      x9, [x19, #0x390]
3e88: str      x20, [x19, #0x398]
3e8c: mov      x0, #0x47
3e90: ldp      x29, x30, [sp]
3e94: ldp      x19, x20, [sp, #0x50]
3e98: ldp      x21, x22, [sp, #0x40]
3e9c: ldp      x23, x24, [sp, #0x30]
3ea0: ldp      x25, x26, [sp, #0x20]
3ea4: ldr      x27, [sp, #0x18]
3ea8: add      sp, sp, #0x60
3eac: ret      
3eb0: mov      x0, x23
3eb4: str      x0, [x19]
3eb8: ldr      x0, [x19, #0x3f8]
3ebc: str      x0, [x19, #0x8]
3ec0: ldr      x0, [x19, #0x400]
3ec4: str      x0, [x19, #0x10]
3ec8: ldr      x0, [x19, #0x408]
3ecc: str      x0, [x19, #0x18]
3ed0: ldr      x0, [x19, #0x410]
3ed4: str      x0, [x19, #0x20]
3ed8: fmov     d0, d6
3edc: fmov     x0, d0
3ee0: lsr      x3, x0, #48
3ee4: mov      x10, #0xfff1
3ee8: cmp      x3, x10
3eec: b.lo     0x100303b9c
3ef0: orr      x0, xzr, #0x7ff8000000000000
3ef4: str      x0, [x19, #0x30]
3ef8: fmov     d0, d7
3efc: fmov     x0, d0
3f00: lsr      x3, x0, #48
3f04: mov      x10, #0xfff1
3f08: cmp      x3, x10
3f0c: b.lo     0x100303bbc
3f10: orr      x0, xzr, #0x7ff8000000000000
3f14: str      x0, [x19, #0x38]
3f18: ldr      d0, [x19, #0x418]
3f1c: fmov     x0, d0
3f20: lsr      x3, x0, #48
3f24: mov      x10, #0xfff1
3f28: cmp      x3, x10
3f2c: b.lo     0x100303bdc
3f30: orr      x0, xzr, #0x7ff8000000000000
3f34: str      x0, [x19, #0x40]
3f38: ldr      d0, [x19, #0x420]
3f3c: fmov     x0, d0
3f40: lsr      x3, x0, #48
3f44: mov      x10, #0xfff1
3f48: cmp      x3, x10
3f4c: b.lo     0x100303bfc
3f50: orr      x0, xzr, #0x7ff8000000000000
3f54: str      x0, [x19, #0x48]
3f58: ldr      x0, [x19, #0x428]
3f5c: and      x0, x0, #0xffffffffffff
3f60: mov      x10, #-0xf000000000000
3f64: orr      x0, x0, x10
3f68: str      x0, [x19, #0x50]
3f6c: ldr      x0, [x19, #0x6a0]
3f70: str      x0, [x19, #0xc8]
3f74: mov      x9, #0x7df
3f78: movk     x9, #0x200, lsl #16
3f7c: str      x9, [x19, #0x390]
3f80: str      x20, [x19, #0x398]
3f84: mov      x0, #0x49
3f88: ldp      x29, x30, [sp]
3f8c: ldp      x19, x20, [sp, #0x50]
3f90: ldp      x21, x22, [sp, #0x40]
3f94: ldp      x23, x24, [sp, #0x30]
3f98: ldp      x25, x26, [sp, #0x20]
3f9c: ldr      x27, [sp, #0x18]
3fa0: add      sp, sp, #0x60
3fa4: ret      
3fa8: mov      x0, x23
3fac: str      x0, [x19]
3fb0: ldr      x0, [x19, #0x3f8]
3fb4: str      x0, [x19, #0x8]
3fb8: ldr      x0, [x19, #0x400]
3fbc: str      x0, [x19, #0x10]
3fc0: ldr      x0, [x19, #0x408]
3fc4: str      x0, [x19, #0x18]
3fc8: ldr      x0, [x19, #0x410]
3fcc: str      x0, [x19, #0x20]
3fd0: fmov     d0, d6
3fd4: fmov     x0, d0
3fd8: lsr      x3, x0, #48
3fdc: mov      x10, #0xfff1
3fe0: cmp      x3, x10
3fe4: b.lo     0x100303c94
3fe8: orr      x0, xzr, #0x7ff8000000000000
3fec: str      x0, [x19, #0x30]
3ff0: fmov     d0, d7
3ff4: fmov     x0, d0
3ff8: lsr      x3, x0, #48
3ffc: mov      x10, #0xfff1
4000: cmp      x3, x10
4004: b.lo     0x100303cb4
4008: orr      x0, xzr, #0x7ff8000000000000
400c: str      x0, [x19, #0x38]
4010: ldr      d0, [x19, #0x418]
4014: fmov     x0, d0
4018: lsr      x3, x0, #48
401c: mov      x10, #0xfff1
4020: cmp      x3, x10
4024: b.lo     0x100303cd4
4028: orr      x0, xzr, #0x7ff8000000000000
402c: str      x0, [x19, #0x40]
4030: ldr      d0, [x19, #0x420]
4034: fmov     x0, d0
4038: lsr      x3, x0, #48
403c: mov      x10, #0xfff1
4040: cmp      x3, x10
4044: b.lo     0x100303cf4
4048: orr      x0, xzr, #0x7ff8000000000000
404c: str      x0, [x19, #0x48]
4050: ldr      x0, [x19, #0x428]
4054: and      x0, x0, #0xffffffffffff
4058: mov      x10, #-0xf000000000000
405c: orr      x0, x0, x10
4060: str      x0, [x19, #0x50]
4064: ldr      x0, [x19, #0x6a0]
4068: str      x0, [x19, #0xc8]
406c: ldr      x0, [x19, #0x6a8]
4070: str      x0, [x19, #0xd0]
4074: mov      x9, #0x7df
4078: movk     x9, #0x600, lsl #16
407c: str      x9, [x19, #0x390]
4080: str      x20, [x19, #0x398]
4084: mov      x0, #0x4a
4088: ldp      x29, x30, [sp]
408c: ldp      x19, x20, [sp, #0x50]
4090: ldp      x21, x22, [sp, #0x40]
4094: ldp      x23, x24, [sp, #0x30]
4098: ldp      x25, x26, [sp, #0x20]
409c: ldr      x27, [sp, #0x18]
40a0: add      sp, sp, #0x60
40a4: ret      
