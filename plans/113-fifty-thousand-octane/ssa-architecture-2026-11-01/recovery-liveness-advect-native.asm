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
0030: b.ne     0x100301dbc
0034: ldr      x24, [x19, #0x220]
0038: ldr      x25, [x19, #0x218]
003c: ldr      x0, [x19, #0x20]
0040: ldr      x10, [x19, #0x230]
0044: cmp      x0, x10
0048: b.ne     0x100301dbc
004c: ldr      x26, [x19, #0x240]
0050: ldr      x27, [x19, #0x238]
0054: ldr      x0, [x19, #0x10]
0058: ldr      x10, [x19, #0x250]
005c: cmp      x0, x10
0060: b.ne     0x100301dbc
0064: ldr      x0, [x19, #0x8]
0068: ldr      x10, [x19, #0x270]
006c: cmp      x0, x10
0070: b.ne     0x100301dbc
0074: ldr      x0, [x19]
0078: str      x0, [x19, #0x428]
007c: ldr      x0, [x19, #0x8]
0080: str      x0, [x19, #0x430]
0084: ldr      x0, [x19, #0x10]
0088: str      x0, [x19, #0x438]
008c: ldr      x0, [x19, #0x18]
0090: str      x0, [x19, #0x440]
0094: ldr      x0, [x19, #0x20]
0098: str      x0, [x19, #0x448]
009c: ldr      x0, [x19, #0x28]
00a0: mov      x22, x0
00a4: ldr      x0, [x19, #0x30]
00a8: str      x0, [x19, #0x450]
00ac: ldr      x0, [x19, #0x38]
00b0: str      x0, [x19, #0x458]
00b4: ldr      x0, [x19, #0x40]
00b8: str      x0, [x19, #0x460]
00bc: ldr      x0, [x19, #0x48]
00c0: str      x0, [x19, #0x468]
00c4: ldr      x0, [x19, #0x50]
00c8: str      x0, [x19, #0x470]
00cc: ldr      x0, [x19, #0x58]
00d0: str      x0, [x19, #0x478]
00d4: ldr      x0, [x19, #0x60]
00d8: str      x0, [x19, #0x480]
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
0110: str      x0, [x19, #0x488]
0114: ldr      x0, [x19, #0xa0]
0118: str      x0, [x19, #0x490]
011c: ldr      x0, [x19, #0xa8]
0120: str      x0, [x19, #0x498]
0124: ldr      x0, [x19, #0xb0]
0128: str      x0, [x19, #0x4a0]
012c: ldr      x0, [x19, #0xb8]
0130: str      x0, [x19, #0x4a8]
0134: ldr      x0, [x19, #0xc0]
0138: str      x0, [x19, #0x4b0]
013c: ldr      x0, [x19, #0xc8]
0140: str      x0, [x19, #0x4b8]
0144: ldr      x0, [x19, #0xd0]
0148: str      x0, [x19, #0x4c0]
014c: ldr      x0, [x19, #0xd8]
0150: str      x0, [x19, #0x4c8]
0154: ldr      x0, [x19, #0xe0]
0158: str      x0, [x19, #0x4d0]
015c: ldr      x0, [x19, #0xe8]
0160: str      x0, [x19, #0x4d8]
0164: ldr      x0, [x19, #0xf0]
0168: str      x0, [x19, #0x4e0]
016c: ldr      x0, [x19, #0xf8]
0170: str      x0, [x19, #0x4e8]
0174: ldr      x0, [x19, #0x100]
0178: str      x0, [x19, #0x4f0]
017c: ldr      x0, [x19, #0x108]
0180: str      x0, [x19, #0x4f8]
0184: ldr      x0, [x19, #0x110]
0188: str      x0, [x19, #0x500]
018c: ldr      x0, [x19, #0x118]
0190: str      x0, [x19, #0x508]
0194: ldr      x0, [x19, #0x120]
0198: str      x0, [x19, #0x510]
019c: ldr      x0, [x19, #0x128]
01a0: str      x0, [x19, #0x518]
01a4: ldr      x0, [x19, #0x130]
01a8: str      x0, [x19, #0x520]
01ac: ldr      w0, [x19, #0x20c]
01b0: cbnz     x0, 0x100300df8
01b4: ldr      x0, [x19, #0x428]
01b8: str      x0, [x19, #0x7a0]
01bc: ldr      x0, [x19, #0x430]
01c0: str      x0, [x19, #0x7a8]
01c4: ldr      x0, [x19, #0x438]
01c8: str      x0, [x19, #0x7b0]
01cc: ldr      x0, [x19, #0x440]
01d0: str      x0, [x19, #0x7b8]
01d4: ldr      x0, [x19, #0x448]
01d8: str      x0, [x19, #0x7c0]
01dc: mov      x0, x22
01e0: lsr      x3, x0, #48
01e4: mov      x10, #0xfff1
01e8: cmp      x3, x10
01ec: b.hi     0x100301dbc
01f0: mov      x10, #0xfff1
01f4: cmp      x3, x10
01f8: b.ne     0x100300dbc
01fc: lsl      x0, x0, #16
0200: asr      x0, x0, #16
0204: scvtf    d0, x0
0208: b        0x100300dc0
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
0244: b        0x10030130c
0248: ldr      w0, [x19, #0x20c]
024c: cmp      x0, #0xc
0250: b.ne     0x100300ff4
0254: ldr      x0, [x19, #0x428]
0258: str      x0, [x19, #0x7a0]
025c: ldr      x0, [x19, #0x430]
0260: str      x0, [x19, #0x7a8]
0264: ldr      x0, [x19, #0x438]
0268: str      x0, [x19, #0x7b0]
026c: ldr      x0, [x19, #0x440]
0270: str      x0, [x19, #0x7b8]
0274: ldr      x0, [x19, #0x448]
0278: str      x0, [x19, #0x7c0]
027c: ldr      x0, [x19, #0x450]
0280: lsr      x3, x0, #48
0284: mov      x10, #0xfff1
0288: cmp      x3, x10
028c: b.hi     0x100301dbc
0290: mov      x10, #0xfff1
0294: cmp      x3, x10
0298: b.ne     0x100300e5c
029c: lsl      x0, x0, #16
02a0: asr      x0, x0, #16
02a4: scvtf    d0, x0
02a8: b        0x100300e60
02ac: fmov     d0, x0
02b0: str      d0, [x19, #0x7c8]
02b4: ldr      x0, [x19, #0x458]
02b8: lsr      x3, x0, #48
02bc: mov      x10, #0xfff1
02c0: cmp      x3, x10
02c4: b.hi     0x100301dbc
02c8: mov      x10, #0xfff1
02cc: cmp      x3, x10
02d0: b.ne     0x100300e94
02d4: lsl      x0, x0, #16
02d8: asr      x0, x0, #16
02dc: scvtf    d0, x0
02e0: b        0x100300e98
02e4: fmov     d0, x0
02e8: str      d0, [x19, #0x7d0]
02ec: ldr      x0, [x19, #0x460]
02f0: lsr      x3, x0, #48
02f4: mov      x10, #0xfff1
02f8: cmp      x3, x10
02fc: b.hi     0x100301dbc
0300: mov      x10, #0xfff1
0304: cmp      x3, x10
0308: b.ne     0x100300ecc
030c: lsl      x0, x0, #16
0310: asr      x0, x0, #16
0314: scvtf    d0, x0
0318: b        0x100300ed0
031c: fmov     d0, x0
0320: str      d0, [x19, #0x7d8]
0324: ldr      x0, [x19, #0x468]
0328: lsr      x3, x0, #48
032c: mov      x10, #0xfff1
0330: cmp      x3, x10
0334: b.hi     0x100301dbc
0338: mov      x10, #0xfff1
033c: cmp      x3, x10
0340: b.ne     0x100300f04
0344: lsl      x0, x0, #16
0348: asr      x0, x0, #16
034c: scvtf    d0, x0
0350: b        0x100300f08
0354: fmov     d0, x0
0358: str      d0, [x19, #0x7e0]
035c: ldr      x0, [x19, #0x470]
0360: lsr      x3, x0, #48
0364: mov      x10, #0xfff1
0368: cmp      x3, x10
036c: b.eq     0x100300f84
0370: mov      x10, #0xfff1
0374: cmp      x3, x10
0378: b.hi     0x100301dbc
037c: fmov     d0, x0
0380: fcmp     d0, d0
0384: b.vs     0x100301dbc
0388: mov      x1, #-0x3e20000000000000
038c: fmov     d1, x1
0390: fcmp     d0, d1
0394: b.mi     0x100301dbc
0398: mov      x1, #0x41e0000000000000
039c: fmov     d1, x1
03a0: fcmp     d0, d1
03a4: b.ge     0x100301dbc
03a8: lsl      x3, x0, #1
03ac: cbnz     x3, 0x100300f68
03b0: cmp      x0, #0x0
03b4: b.lt     0x100301dbc
03b8: fcvtzs   x0, d0
03bc: scvtf    d1, x0
03c0: fcmp     d0, d1
03c4: cset     x9, ne
03c8: ccmp     x9, #0x0, #0x4, vc
03cc: b.ne     0x100301dbc
03d0: b        0x100300f9c
03d4: sxtw     x3, w0
03d8: lsl      x1, x0, #16
03dc: asr      x1, x1, #16
03e0: cmp      x1, x3
03e4: b.ne     0x100301dbc
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
0440: b        0x100301454
0444: ldr      w0, [x19, #0x20c]
0448: cmp      x0, #0x10
044c: b.ne     0x1003012cc
0450: ldr      x0, [x19, #0x428]
0454: str      x0, [x19, #0x7a0]
0458: ldr      x0, [x19, #0x430]
045c: str      x0, [x19, #0x7a8]
0460: ldr      x0, [x19, #0x438]
0464: str      x0, [x19, #0x7b0]
0468: ldr      x0, [x19, #0x440]
046c: str      x0, [x19, #0x7b8]
0470: ldr      x0, [x19, #0x448]
0474: str      x0, [x19, #0x7c0]
0478: ldr      x0, [x19, #0x450]
047c: lsr      x3, x0, #48
0480: mov      x10, #0xfff1
0484: cmp      x3, x10
0488: b.hi     0x100301dbc
048c: mov      x10, #0xfff1
0490: cmp      x3, x10
0494: b.ne     0x100301058
0498: lsl      x0, x0, #16
049c: asr      x0, x0, #16
04a0: scvtf    d0, x0
04a4: b        0x10030105c
04a8: fmov     d0, x0
04ac: str      d0, [x19, #0x7c8]
04b0: ldr      x0, [x19, #0x458]
04b4: lsr      x3, x0, #48
04b8: mov      x10, #0xfff1
04bc: cmp      x3, x10
04c0: b.hi     0x100301dbc
04c4: mov      x10, #0xfff1
04c8: cmp      x3, x10
04cc: b.ne     0x100301090
04d0: lsl      x0, x0, #16
04d4: asr      x0, x0, #16
04d8: scvtf    d0, x0
04dc: b        0x100301094
04e0: fmov     d0, x0
04e4: str      d0, [x19, #0x7d0]
04e8: ldr      x0, [x19, #0x460]
04ec: lsr      x3, x0, #48
04f0: mov      x10, #0xfff1
04f4: cmp      x3, x10
04f8: b.hi     0x100301dbc
04fc: mov      x10, #0xfff1
0500: cmp      x3, x10
0504: b.ne     0x1003010c8
0508: lsl      x0, x0, #16
050c: asr      x0, x0, #16
0510: scvtf    d0, x0
0514: b        0x1003010cc
0518: fmov     d0, x0
051c: str      d0, [x19, #0x7d8]
0520: ldr      x0, [x19, #0x468]
0524: lsr      x3, x0, #48
0528: mov      x10, #0xfff1
052c: cmp      x3, x10
0530: b.hi     0x100301dbc
0534: mov      x10, #0xfff1
0538: cmp      x3, x10
053c: b.ne     0x100301100
0540: lsl      x0, x0, #16
0544: asr      x0, x0, #16
0548: scvtf    d0, x0
054c: b        0x100301104
0550: fmov     d0, x0
0554: str      d0, [x19, #0x7e0]
0558: ldr      x0, [x19, #0x470]
055c: lsr      x3, x0, #48
0560: mov      x10, #0xfff1
0564: cmp      x3, x10
0568: b.eq     0x100301180
056c: mov      x10, #0xfff1
0570: cmp      x3, x10
0574: b.hi     0x100301dbc
0578: fmov     d0, x0
057c: fcmp     d0, d0
0580: b.vs     0x100301dbc
0584: mov      x1, #-0x3e20000000000000
0588: fmov     d1, x1
058c: fcmp     d0, d1
0590: b.mi     0x100301dbc
0594: mov      x1, #0x41e0000000000000
0598: fmov     d1, x1
059c: fcmp     d0, d1
05a0: b.ge     0x100301dbc
05a4: lsl      x3, x0, #1
05a8: cbnz     x3, 0x100301164
05ac: cmp      x0, #0x0
05b0: b.lt     0x100301dbc
05b4: fcvtzs   x0, d0
05b8: scvtf    d1, x0
05bc: fcmp     d0, d1
05c0: cset     x9, ne
05c4: ccmp     x9, #0x0, #0x4, vc
05c8: b.ne     0x100301dbc
05cc: b        0x100301198
05d0: sxtw     x3, w0
05d4: lsl      x1, x0, #16
05d8: asr      x1, x1, #16
05dc: cmp      x1, x3
05e0: b.ne     0x100301dbc
05e4: mov      x0, x1
05e8: str      x0, [x19, #0x7e8]
05ec: ldr      x0, [x19, #0x478]
05f0: lsr      x3, x0, #48
05f4: mov      x10, #0xfff1
05f8: cmp      x3, x10
05fc: b.hi     0x100301dbc
0600: mov      x10, #0xfff1
0604: cmp      x3, x10
0608: b.ne     0x1003011cc
060c: lsl      x0, x0, #16
0610: asr      x0, x0, #16
0614: scvtf    d0, x0
0618: b        0x1003011d0
061c: fmov     d0, x0
0620: str      d0, [x19, #0x7f0]
0624: ldr      x0, [x19, #0x480]
0628: lsr      x3, x0, #48
062c: mov      x10, #0xfff1
0630: cmp      x3, x10
0634: b.eq     0x10030124c
0638: mov      x10, #0xfff1
063c: cmp      x3, x10
0640: b.hi     0x100301dbc
0644: fmov     d0, x0
0648: fcmp     d0, d0
064c: b.vs     0x100301dbc
0650: mov      x1, #-0x3e20000000000000
0654: fmov     d1, x1
0658: fcmp     d0, d1
065c: b.mi     0x100301dbc
0660: mov      x1, #0x41e0000000000000
0664: fmov     d1, x1
0668: fcmp     d0, d1
066c: b.ge     0x100301dbc
0670: lsl      x3, x0, #1
0674: cbnz     x3, 0x100301230
0678: cmp      x0, #0x0
067c: b.lt     0x100301dbc
0680: fcvtzs   x0, d0
0684: scvtf    d1, x0
0688: fcmp     d0, d1
068c: cset     x9, ne
0690: ccmp     x9, #0x0, #0x4, vc
0694: b.ne     0x100301dbc
0698: b        0x100301264
069c: sxtw     x3, w0
06a0: lsl      x1, x0, #16
06a4: asr      x1, x1, #16
06a8: cmp      x1, x3
06ac: b.ne     0x100301dbc
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
0718: b        0x1003014fc
071c: ldr      w0, [x19, #0x20c]
0720: cmp      x0, #0x4e
0724: b.ne     0x1003012dc
0728: b        0x100301d8c
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
0774: b.hi     0x100301dec
0778: mov      x10, #0xfff1
077c: cmp      x3, x10
0780: b.ne     0x100301344
0784: lsl      x0, x0, #16
0788: asr      x0, x0, #16
078c: scvtf    d3, x0
0790: b        0x100301348
0794: fmov     d3, x0
0798: fmul     d4, d2, d3
079c: ldr      x0, [x19, #0x318]
07a0: mov      x23, x0
07a4: mov      x0, x23
07a8: lsr      x3, x0, #48
07ac: mov      x10, #0xfff1
07b0: cmp      x3, x10
07b4: b.hi     0x100301e70
07b8: mov      x10, #0xfff1
07bc: cmp      x3, x10
07c0: b.ne     0x100301384
07c4: lsl      x0, x0, #16
07c8: asr      x0, x0, #16
07cc: scvtf    d3, x0
07d0: b        0x100301388
07d4: fmov     d3, x0
07d8: fmul     d5, d2, d3
07dc: orr      x0, xzr, #0x3fe0000000000000
07e0: fmov     d2, x0
07e4: mov      x0, x22
07e8: lsr      x3, x0, #48
07ec: mov      x10, #0xfff1
07f0: cmp      x3, x10
07f4: b.hi     0x100301f14
07f8: mov      x10, #0xfff1
07fc: cmp      x3, x10
0800: b.ne     0x1003013c4
0804: lsl      x0, x0, #16
0808: asr      x0, x0, #16
080c: scvtf    d3, x0
0810: b        0x1003013c8
0814: fmov     d3, x0
0818: fadd     d7, d3, d2
081c: mov      x0, x23
0820: lsr      x3, x0, #48
0824: mov      x10, #0xfff1
0828: cmp      x3, x10
082c: b.hi     0x100301fd8
0830: mov      x10, #0xfff1
0834: cmp      x3, x10
0838: b.ne     0x1003013fc
083c: lsl      x0, x0, #16
0840: asr      x0, x0, #16
0844: scvtf    d3, x0
0848: b        0x100301400
084c: fmov     d3, x0
0850: fadd     d16, d3, d2
0854: mov      x22, #0x1
0858: mov      x23, x4
085c: mov      x0, x5
0860: str      x0, [x19, #0x3e8]
0864: mov      x0, x6
0868: str      x0, [x19, #0x3f0]
086c: mov      x0, x7
0870: str      x0, [x19, #0x3f8]
0874: mov      x0, x21
0878: str      x0, [x19, #0x400]
087c: fmov     d6, d4
0880: fmov     d0, d5
0884: str      d0, [x19, #0x408]
0888: fmov     d0, d7
088c: str      d0, [x19, #0x410]
0890: fmov     d0, d16
0894: str      d0, [x19, #0x418]
0898: mov      x0, x22
089c: str      x0, [x19, #0x420]
08a0: b        0x100301c6c
08a4: ldr      x0, [x19, #0x320]
08a8: mov      x23, x0
08ac: mov      x0, x22
08b0: scvtf    d6, x0
08b4: mov      x0, x23
08b8: lsr      x3, x0, #48
08bc: mov      x10, #0xfff1
08c0: cmp      x3, x10
08c4: b.hi     0x1003020bc
08c8: mov      x10, #0xfff1
08cc: cmp      x3, x10
08d0: b.ne     0x100301494
08d4: lsl      x0, x0, #16
08d8: asr      x0, x0, #16
08dc: scvtf    d7, x0
08e0: b        0x100301498
08e4: fmov     d7, x0
08e8: fmul     d0, d6, d7
08ec: str      d0, [x19, #0x528]
08f0: mov      x23, #0x1
08f4: mov      x0, x4
08f8: str      x0, [x19, #0x3a0]
08fc: mov      x0, x5
0900: str      x0, [x19, #0x3a8]
0904: mov      x0, x6
0908: str      x0, [x19, #0x3b0]
090c: mov      x0, x7
0910: str      x0, [x19, #0x3b8]
0914: mov      x0, x21
0918: str      x0, [x19, #0x3c0]
091c: fmov     d7, d2
0920: fmov     d16, d3
0924: fmov     d17, d4
0928: fmov     d0, d5
092c: str      d0, [x19, #0x3c8]
0930: mov      x0, x22
0934: str      x0, [x19, #0x3d0]
0938: ldr      d0, [x19, #0x528]
093c: str      d0, [x19, #0x3d8]
0940: mov      x0, x23
0944: str      x0, [x19, #0x3e0]
0948: b        0x100301b54
094c: orr      x0, xzr, #0x3ff0000000000000
0950: fmov     d1, x0
0954: fadd     d0, d6, d1
0958: str      d0, [x19, #0x530]
095c: ldr      d0, [x19, #0x530]
0960: fcmp     d0, d0
0964: b.vs     0x1003021b4
0968: fmov     x1, d0
096c: orr      x10, xzr, #0x8000000000000000
0970: cmp      x1, x10
0974: b.eq     0x1003021b4
0978: mov      x1, #-0x3e20000000000000
097c: fmov     d1, x1
0980: fcmp     d0, d1
0984: b.mi     0x1003021b4
0988: mov      x1, #0x41e0000000000000
098c: fmov     d1, x1
0990: fcmp     d0, d1
0994: b.ge     0x1003021b4
0998: fcvtzs   x0, d0
099c: scvtf    d1, x0
09a0: fcmp     d0, d1
09a4: b.eq     0x10030155c
09a8: b        0x1003021b4
09ac: sxtw     x0, w0
09b0: str      x0, [x19, #0x538]
09b4: ldr      x1, [x19, #0x538]
09b8: cmp      x1, x24
09bc: b.hs     0x1003021b4
09c0: lsl      x1, x1, #3
09c4: add      x2, x25, x1
09c8: ldr      x0, [x2]
09cc: lsr      x3, x0, #48
09d0: mov      x10, #0xfff1
09d4: cmp      x3, x10
09d8: b.hs     0x1003021b4
09dc: fmov     d6, x0
09e0: fmul     d7, d2, d6
09e4: mov      x0, x23
09e8: scvtf    d6, x0
09ec: fsub     d16, d6, d7
09f0: ldr      x1, [x19, #0x538]
09f4: cmp      x1, x26
09f8: b.hs     0x1003022d4
09fc: lsl      x1, x1, #3
0a00: add      x2, x27, x1
0a04: ldr      x0, [x2]
0a08: lsr      x3, x0, #48
0a0c: mov      x10, #0xfff1
0a10: cmp      x3, x10
0a14: b.hs     0x1003022d4
0a18: fmov     d6, x0
0a1c: fmul     d7, d3, d6
0a20: mov      x0, x22
0a24: scvtf    d6, x0
0a28: fsub     d17, d6, d7
0a2c: orr      x0, xzr, #0x3fe0000000000000
0a30: fmov     d0, x0
0a34: str      d0, [x19, #0x540]
0a38: fmov     d0, d16
0a3c: ldr      d1, [x19, #0x540]
0a40: fcmp     d0, d1
0a44: b.pl     0x1003015fc
0a48: b        0x100301600
0a4c: b        0x10030160c
0a50: ldr      d0, [x19, #0x540]
0a54: fmov     d6, d0
0a58: b        0x10030162c
0a5c: fmov     d0, d16
0a60: fmov     d1, d4
0a64: fcmp     d0, d1
0a68: b.le     0x100301620
0a6c: b        0x100301628
0a70: fmov     d6, d16
0a74: b        0x10030162c
0a78: fmov     d6, d4
0a7c: fmov     d0, d6
0a80: fcmp     d0, d0
0a84: b.vs     0x100302414
0a88: mov      x1, #-0x3e20000000000000
0a8c: fmov     d1, x1
0a90: fcmp     d0, d1
0a94: b.mi     0x100302414
0a98: mov      x1, #0x41e0000000000000
0a9c: fmov     d1, x1
0aa0: fcmp     d0, d1
0aa4: b.ge     0x100302414
0aa8: fcvtzs   x0, d0
0aac: sxtw     x0, w0
0ab0: str      x0, [x19, #0x548]
0ab4: ldr      x0, [x19, #0x548]
0ab8: orr      x0, x0, xzr
0abc: sxtw     x0, w0
0ac0: str      x0, [x19, #0x550]
0ac4: ldr      x0, [x19, #0x550]
0ac8: adds     w0, w0, #0x1
0acc: b.vs     0x100302574
0ad0: sxtw     x0, w0
0ad4: str      x0, [x19, #0x558]
0ad8: fmov     d0, d17
0adc: ldr      d1, [x19, #0x540]
0ae0: fcmp     d0, d1
0ae4: b.pl     0x10030169c
0ae8: b        0x1003016a0
0aec: b        0x1003016ac
0af0: ldr      d0, [x19, #0x540]
0af4: fmov     d7, d0
0af8: b        0x1003016cc
0afc: fmov     d0, d17
0b00: fmov     d1, d5
0b04: fcmp     d0, d1
0b08: b.le     0x1003016c0
0b0c: b        0x1003016c8
0b10: fmov     d7, d17
0b14: b        0x1003016cc
0b18: fmov     d7, d5
0b1c: fmov     d0, d7
0b20: fcmp     d0, d0
0b24: b.vs     0x1003026e8
0b28: mov      x1, #-0x3e20000000000000
0b2c: fmov     d1, x1
0b30: fcmp     d0, d1
0b34: b.mi     0x1003026e8
0b38: mov      x1, #0x41e0000000000000
0b3c: fmov     d1, x1
0b40: fcmp     d0, d1
0b44: b.ge     0x1003026e8
0b48: fcvtzs   x0, d0
0b4c: sxtw     x0, w0
0b50: str      x0, [x19, #0x560]
0b54: ldr      x0, [x19, #0x560]
0b58: orr      x0, x0, xzr
0b5c: sxtw     x0, w0
0b60: str      x0, [x19, #0x568]
0b64: ldr      x0, [x19, #0x568]
0b68: adds     w0, w0, #0x1
0b6c: b.vs     0x100302874
0b70: sxtw     x0, w0
0b74: str      x0, [x19, #0x570]
0b78: ldr      x0, [x19, #0x550]
0b7c: scvtf    d16, x0
0b80: fsub     d17, d6, d16
0b84: mov      x0, #0x1
0b88: str      x0, [x19, #0x578]
0b8c: ldr      x0, [x19, #0x578]
0b90: scvtf    d6, x0
0b94: fsub     d0, d6, d17
0b98: str      d0, [x19, #0x580]
0b9c: ldr      x0, [x19, #0x568]
0ba0: scvtf    d6, x0
0ba4: fsub     d0, d7, d6
0ba8: str      d0, [x19, #0x588]
0bac: ldr      x0, [x19, #0x578]
0bb0: scvtf    d7, x0
0bb4: ldr      d1, [x19, #0x588]
0bb8: fsub     d0, d7, d1
0bbc: str      d0, [x19, #0x590]
0bc0: ldr      x0, [x19, #0x320]
0bc4: str      x0, [x19, #0x598]
0bc8: ldr      x0, [x19, #0x598]
0bcc: lsr      x3, x0, #48
0bd0: mov      x10, #0xfff1
0bd4: cmp      x3, x10
0bd8: b.hi     0x100302a14
0bdc: mov      x10, #0xfff1
0be0: cmp      x3, x10
0be4: b.ne     0x1003017a8
0be8: lsl      x0, x0, #16
0bec: asr      x0, x0, #16
0bf0: scvtf    d7, x0
0bf4: b        0x1003017ac
0bf8: fmov     d7, x0
0bfc: fmul     d0, d6, d7
0c00: str      d0, [x19, #0x5a0]
0c04: ldr      x0, [x19, #0x570]
0c08: scvtf    d6, x0
0c0c: ldr      x0, [x19, #0x598]
0c10: lsr      x3, x0, #48
0c14: mov      x10, #0xfff1
0c18: cmp      x3, x10
0c1c: b.hi     0x100302c10
0c20: mov      x10, #0xfff1
0c24: cmp      x3, x10
0c28: b.ne     0x1003017ec
0c2c: lsl      x0, x0, #16
0c30: asr      x0, x0, #16
0c34: scvtf    d7, x0
0c38: b        0x1003017f0
0c3c: fmov     d7, x0
0c40: fmul     d0, d6, d7
0c44: str      d0, [x19, #0x5a8]
0c48: ldr      d1, [x19, #0x5a0]
0c4c: fadd     d6, d16, d1
0c50: fmov     d0, d6
0c54: fcmp     d0, d0
0c58: b.vs     0x100302e18
0c5c: fmov     x1, d0
0c60: orr      x10, xzr, #0x8000000000000000
0c64: cmp      x1, x10
0c68: b.eq     0x100302e18
0c6c: mov      x1, #-0x3e20000000000000
0c70: fmov     d1, x1
0c74: fcmp     d0, d1
0c78: b.mi     0x100302e18
0c7c: mov      x1, #0x41e0000000000000
0c80: fmov     d1, x1
0c84: fcmp     d0, d1
0c88: b.ge     0x100302e18
0c8c: fcvtzs   x0, d0
0c90: scvtf    d1, x0
0c94: fcmp     d0, d1
0c98: b.eq     0x100301850
0c9c: b        0x100302e18
0ca0: sxtw     x0, w0
0ca4: str      x0, [x19, #0x5b0]
0ca8: ldr      x1, [x19, #0x5b0]
0cac: ldr      x10, [x19, #0x260]
0cb0: cmp      x1, x10
0cb4: b.hs     0x100302e18
0cb8: lsl      x1, x1, #3
0cbc: ldr      x2, [x19, #0x258]
0cc0: add      x2, x2, x1
0cc4: ldr      x0, [x2]
0cc8: lsr      x3, x0, #48
0ccc: mov      x10, #0xfff1
0cd0: cmp      x3, x10
0cd4: b.hs     0x100302e18
0cd8: fmov     d7, x0
0cdc: ldr      d0, [x19, #0x590]
0ce0: fmul     d6, d0, d7
0ce4: ldr      d1, [x19, #0x5a8]
0ce8: fadd     d7, d16, d1
0cec: fmov     d0, d7
0cf0: fcmp     d0, d0
0cf4: b.vs     0x100303064
0cf8: fmov     x1, d0
0cfc: orr      x10, xzr, #0x8000000000000000
0d00: cmp      x1, x10
0d04: b.eq     0x100303064
0d08: mov      x1, #-0x3e20000000000000
0d0c: fmov     d1, x1
0d10: fcmp     d0, d1
0d14: b.mi     0x100303064
0d18: mov      x1, #0x41e0000000000000
0d1c: fmov     d1, x1
0d20: fcmp     d0, d1
0d24: b.ge     0x100303064
0d28: fcvtzs   x0, d0
0d2c: scvtf    d1, x0
0d30: fcmp     d0, d1
0d34: b.eq     0x1003018ec
0d38: b        0x100303064
0d3c: sxtw     x0, w0
0d40: str      x0, [x19, #0x5b8]
0d44: ldr      x1, [x19, #0x5b8]
0d48: ldr      x10, [x19, #0x260]
0d4c: cmp      x1, x10
0d50: b.hs     0x100303064
0d54: lsl      x1, x1, #3
0d58: ldr      x2, [x19, #0x258]
0d5c: add      x2, x2, x1
0d60: ldr      x0, [x2]
0d64: lsr      x3, x0, #48
0d68: mov      x10, #0xfff1
0d6c: cmp      x3, x10
0d70: b.hs     0x100303064
0d74: fmov     d16, x0
0d78: ldr      d0, [x19, #0x588]
0d7c: fmul     d7, d0, d16
0d80: fadd     d16, d6, d7
0d84: ldr      d0, [x19, #0x580]
0d88: fmul     d6, d0, d16
0d8c: ldr      x0, [x19, #0x558]
0d90: scvtf    d7, x0
0d94: ldr      d1, [x19, #0x5a0]
0d98: fadd     d16, d7, d1
0d9c: fmov     d0, d16
0da0: fcmp     d0, d0
0da4: b.vs     0x1003032bc
0da8: fmov     x1, d0
0dac: orr      x10, xzr, #0x8000000000000000
0db0: cmp      x1, x10
0db4: b.eq     0x1003032bc
0db8: mov      x1, #-0x3e20000000000000
0dbc: fmov     d1, x1
0dc0: fcmp     d0, d1
0dc4: b.mi     0x1003032bc
0dc8: mov      x1, #0x41e0000000000000
0dcc: fmov     d1, x1
0dd0: fcmp     d0, d1
0dd4: b.ge     0x1003032bc
0dd8: fcvtzs   x0, d0
0ddc: scvtf    d1, x0
0de0: fcmp     d0, d1
0de4: b.eq     0x10030199c
0de8: b        0x1003032bc
0dec: sxtw     x0, w0
0df0: str      x0, [x19, #0x5c0]
0df4: ldr      x1, [x19, #0x5c0]
0df8: ldr      x10, [x19, #0x260]
0dfc: cmp      x1, x10
0e00: b.hs     0x1003032bc
0e04: lsl      x1, x1, #3
0e08: ldr      x2, [x19, #0x258]
0e0c: add      x2, x2, x1
0e10: ldr      x0, [x2]
0e14: lsr      x3, x0, #48
0e18: mov      x10, #0xfff1
0e1c: cmp      x3, x10
0e20: b.hs     0x1003032bc
0e24: fmov     d0, x0
0e28: str      d0, [x19, #0x5c8]
0e2c: ldr      d0, [x19, #0x590]
0e30: ldr      d1, [x19, #0x5c8]
0e34: fmul     d16, d0, d1
0e38: ldr      d1, [x19, #0x5a8]
0e3c: fadd     d0, d7, d1
0e40: str      d0, [x19, #0x5d0]
0e44: ldr      d0, [x19, #0x5d0]
0e48: fcmp     d0, d0
0e4c: b.vs     0x1003034d8
0e50: fmov     x1, d0
0e54: orr      x10, xzr, #0x8000000000000000
0e58: cmp      x1, x10
0e5c: b.eq     0x1003034d8
0e60: mov      x1, #-0x3e20000000000000
0e64: fmov     d1, x1
0e68: fcmp     d0, d1
0e6c: b.mi     0x1003034d8
0e70: mov      x1, #0x41e0000000000000
0e74: fmov     d1, x1
0e78: fcmp     d0, d1
0e7c: b.ge     0x1003034d8
0e80: fcvtzs   x0, d0
0e84: scvtf    d1, x0
0e88: fcmp     d0, d1
0e8c: b.eq     0x100301a44
0e90: b        0x1003034d8
0e94: sxtw     x0, w0
0e98: str      x0, [x19, #0x5d8]
0e9c: ldr      x1, [x19, #0x5d8]
0ea0: ldr      x10, [x19, #0x260]
0ea4: cmp      x1, x10
0ea8: b.hs     0x1003034d8
0eac: lsl      x1, x1, #3
0eb0: ldr      x2, [x19, #0x258]
0eb4: add      x2, x2, x1
0eb8: ldr      x0, [x2]
0ebc: lsr      x3, x0, #48
0ec0: mov      x10, #0xfff1
0ec4: cmp      x3, x10
0ec8: b.hs     0x1003034d8
0ecc: fmov     d7, x0
0ed0: ldr      d0, [x19, #0x588]
0ed4: fmul     d0, d0, d7
0ed8: str      d0, [x19, #0x5e0]
0edc: ldr      d1, [x19, #0x5e0]
0ee0: fadd     d7, d16, d1
0ee4: fmul     d16, d17, d7
0ee8: fadd     d7, d6, d16
0eec: fmov     x0, d7
0ef0: lsr      x3, x0, #48
0ef4: mov      x10, #0xfff1
0ef8: cmp      x3, x10
0efc: b.lo     0x100301ab4
0f00: orr      x0, xzr, #0x7ff8000000000000
0f04: str      x0, [x19, #0x5e8]
0f08: ldr      x1, [x19, #0x538]
0f0c: ldr      x10, [x19, #0x280]
0f10: cmp      x1, x10
0f14: b.hs     0x1003036c0
0f18: lsl      x1, x1, #3
0f1c: ldr      x2, [x19, #0x278]
0f20: add      x2, x2, x1
0f24: ldr      x0, [x2]
0f28: lsr      x3, x0, #48
0f2c: mov      x10, #0xfff1
0f30: cmp      x3, x10
0f34: b.hi     0x1003036c0
0f38: ldr      x0, [x19, #0x5e8]
0f3c: str      x0, [x2]
0f40: adds     w0, w23, #0x1
0f44: b.vs     0x100303828
0f48: sxtw     x0, w0
0f4c: str      x0, [x19, #0x5f0]
0f50: mov      x0, x4
0f54: str      x0, [x19, #0x3a0]
0f58: mov      x0, x5
0f5c: str      x0, [x19, #0x3a8]
0f60: mov      x0, x6
0f64: str      x0, [x19, #0x3b0]
0f68: mov      x0, x7
0f6c: str      x0, [x19, #0x3b8]
0f70: mov      x0, x21
0f74: str      x0, [x19, #0x3c0]
0f78: fmov     d7, d2
0f7c: fmov     d16, d3
0f80: fmov     d17, d4
0f84: fmov     d0, d5
0f88: str      d0, [x19, #0x3c8]
0f8c: mov      x0, x22
0f90: str      x0, [x19, #0x3d0]
0f94: ldr      d0, [x19, #0x530]
0f98: str      d0, [x19, #0x3d8]
0f9c: ldr      x0, [x19, #0x5f0]
0fa0: str      x0, [x19, #0x3e0]
0fa4: ldr      x0, [x19, #0x310]
0fa8: str      x0, [x19, #0x5f8]
0fac: ldr      x0, [x19, #0x3e0]
0fb0: scvtf    d2, x0
0fb4: ldr      x0, [x19, #0x5f8]
0fb8: lsr      x3, x0, #48
0fbc: mov      x10, #0xfff1
0fc0: cmp      x3, x10
0fc4: b.hi     0x100303948
0fc8: mov      x10, #0xfff1
0fcc: cmp      x3, x10
0fd0: b.ne     0x100301b94
0fd4: lsl      x0, x0, #16
0fd8: asr      x0, x0, #16
0fdc: scvtf    d3, x0
0fe0: b        0x100301b98
0fe4: fmov     d3, x0
0fe8: fmov     d0, d2
0fec: fmov     d1, d3
0ff0: fcmp     d0, d1
0ff4: b.ls     0x100301bac
0ff8: b        0x100301c10
0ffc: cmp      x20, #0x1
1000: b.ls     0x100303948
1004: sub      x20, x20, #0x1
1008: ldr      x0, [x19, #0x3a0]
100c: mov      x4, x0
1010: ldr      x0, [x19, #0x3a8]
1014: mov      x5, x0
1018: ldr      x0, [x19, #0x3b0]
101c: mov      x6, x0
1020: ldr      x0, [x19, #0x3b8]
1024: mov      x7, x0
1028: ldr      x0, [x19, #0x3c0]
102c: mov      x21, x0
1030: fmov     d2, d7
1034: fmov     d3, d16
1038: fmov     d4, d17
103c: ldr      d0, [x19, #0x3c8]
1040: fmov     d5, d0
1044: ldr      x0, [x19, #0x3d0]
1048: mov      x22, x0
104c: ldr      d0, [x19, #0x3d8]
1050: fmov     d6, d0
1054: ldr      x0, [x19, #0x3e0]
1058: mov      x23, x0
105c: b        0x1003014fc
1060: ldr      x0, [x19, #0x3d0]
1064: adds     w4, w0, #0x1
1068: b.vs     0x100303a74
106c: sxtw     x4, w4
1070: ldr      x0, [x19, #0x3a0]
1074: mov      x23, x0
1078: ldr      x0, [x19, #0x3a8]
107c: str      x0, [x19, #0x3e8]
1080: ldr      x0, [x19, #0x3b0]
1084: str      x0, [x19, #0x3f0]
1088: ldr      x0, [x19, #0x3b8]
108c: str      x0, [x19, #0x3f8]
1090: ldr      x0, [x19, #0x3c0]
1094: str      x0, [x19, #0x400]
1098: fmov     d6, d7
109c: fmov     d0, d16
10a0: str      d0, [x19, #0x408]
10a4: fmov     d0, d17
10a8: str      d0, [x19, #0x410]
10ac: ldr      d0, [x19, #0x3c8]
10b0: str      d0, [x19, #0x418]
10b4: mov      x0, x4
10b8: str      x0, [x19, #0x420]
10bc: ldr      x0, [x19, #0x318]
10c0: mov      x4, x0
10c4: ldr      x0, [x19, #0x420]
10c8: scvtf    d2, x0
10cc: mov      x0, x4
10d0: lsr      x3, x0, #48
10d4: mov      x10, #0xfff1
10d8: cmp      x3, x10
10dc: b.hi     0x100303b60
10e0: mov      x10, #0xfff1
10e4: cmp      x3, x10
10e8: b.ne     0x100301cac
10ec: lsl      x0, x0, #16
10f0: asr      x0, x0, #16
10f4: scvtf    d3, x0
10f8: b        0x100301cb0
10fc: fmov     d3, x0
1100: fmov     d0, d2
1104: fmov     d1, d3
1108: fcmp     d0, d1
110c: b.ls     0x100301cc8
1110: mov      x0, #-0xb000000000000
1114: b        0x100301cd0
1118: mov      x0, #0x1
111c: movk     x0, #0xfff5, lsl #48
1120: str      x0, [x19, #0x600]
1124: ldr      x0, [x19, #0x600]
1128: lsr      x3, x0, #48
112c: mov      x10, #0xfff5
1130: cmp      x3, x10
1134: b.ne     0x100303c58
1138: and      x1, x0, #0xffffffffffff
113c: cbnz     x1, 0x100301cf4
1140: b        0x100301d4c
1144: cmp      x20, #0x1
1148: b.ls     0x100303c58
114c: sub      x20, x20, #0x1
1150: mov      x4, x23
1154: ldr      x0, [x19, #0x3e8]
1158: mov      x5, x0
115c: ldr      x0, [x19, #0x3f0]
1160: mov      x6, x0
1164: ldr      x0, [x19, #0x3f8]
1168: mov      x7, x0
116c: ldr      x0, [x19, #0x400]
1170: mov      x21, x0
1174: fmov     d2, d6
1178: ldr      d0, [x19, #0x408]
117c: fmov     d3, d0
1180: ldr      d0, [x19, #0x410]
1184: fmov     d4, d0
1188: ldr      d0, [x19, #0x418]
118c: fmov     d5, d0
1190: ldr      x0, [x19, #0x420]
1194: mov      x22, x0
1198: b        0x100301454
119c: mov      x0, x23
11a0: str      x0, [x19, #0xd8]
11a4: ldr      x0, [x19, #0x3e8]
11a8: str      x0, [x19, #0xe0]
11ac: mov      x9, #0x18000000
11b0: str      x9, [x19, #0x390]
11b4: str      x20, [x19, #0x398]
11b8: mov      x0, #0x4d
11bc: ldp      x29, x30, [sp]
11c0: ldp      x19, x20, [sp, #0x50]
11c4: ldp      x21, x22, [sp, #0x40]
11c8: ldp      x23, x24, [sp, #0x30]
11cc: ldp      x25, x26, [sp, #0x20]
11d0: ldr      x27, [sp, #0x18]
11d4: add      sp, sp, #0x60
11d8: ret      
11dc: mov      x9, #0x0
11e0: str      x9, [x19, #0x390]
11e4: str      x20, [x19, #0x398]
11e8: mov      x0, #0x4e
11ec: ldp      x29, x30, [sp]
11f0: ldp      x19, x20, [sp, #0x50]
11f4: ldp      x21, x22, [sp, #0x40]
11f8: ldp      x23, x24, [sp, #0x30]
11fc: ldp      x25, x26, [sp, #0x20]
1200: ldr      x27, [sp, #0x18]
1204: add      sp, sp, #0x60
1208: ret      
120c: mov      x9, #0x0
1210: str      x9, [x19, #0x390]
1214: str      x20, [x19, #0x398]
1218: ldr      w0, [x19, #0x20c]
121c: ldp      x29, x30, [sp]
1220: ldp      x19, x20, [sp, #0x50]
1224: ldp      x21, x22, [sp, #0x40]
1228: ldp      x23, x24, [sp, #0x30]
122c: ldp      x25, x26, [sp, #0x20]
1230: ldr      x27, [sp, #0x18]
1234: add      sp, sp, #0x60
1238: ret      
123c: mov      x0, x4
1240: str      x0, [x19]
1244: mov      x0, x5
1248: str      x0, [x19, #0x8]
124c: mov      x0, x6
1250: str      x0, [x19, #0x10]
1254: mov      x0, x7
1258: str      x0, [x19, #0x18]
125c: mov      x0, x21
1260: str      x0, [x19, #0x20]
1264: fmov     d0, d2
1268: fmov     x0, d0
126c: lsr      x3, x0, #48
1270: mov      x10, #0xfff1
1274: cmp      x3, x10
1278: b.lo     0x100301e30
127c: orr      x0, xzr, #0x7ff8000000000000
1280: str      x0, [x19, #0x28]
1284: mov      x0, x22
1288: str      x0, [x19, #0xc8]
128c: mov      x9, #0x3f
1290: movk     x9, #0x200, lsl #16
1294: str      x9, [x19, #0x390]
1298: str      x20, [x19, #0x398]
129c: mov      x0, #0x1
12a0: ldp      x29, x30, [sp]
12a4: ldp      x19, x20, [sp, #0x50]
12a8: ldp      x21, x22, [sp, #0x40]
12ac: ldp      x23, x24, [sp, #0x30]
12b0: ldp      x25, x26, [sp, #0x20]
12b4: ldr      x27, [sp, #0x18]
12b8: add      sp, sp, #0x60
12bc: ret      
12c0: mov      x0, x4
12c4: str      x0, [x19]
12c8: mov      x0, x5
12cc: str      x0, [x19, #0x8]
12d0: mov      x0, x6
12d4: str      x0, [x19, #0x10]
12d8: mov      x0, x7
12dc: str      x0, [x19, #0x18]
12e0: mov      x0, x21
12e4: str      x0, [x19, #0x20]
12e8: fmov     d0, d2
12ec: fmov     x0, d0
12f0: lsr      x3, x0, #48
12f4: mov      x10, #0xfff1
12f8: cmp      x3, x10
12fc: b.lo     0x100301eb4
1300: orr      x0, xzr, #0x7ff8000000000000
1304: str      x0, [x19, #0x28]
1308: fmov     d0, d4
130c: fmov     x0, d0
1310: lsr      x3, x0, #48
1314: mov      x10, #0xfff1
1318: cmp      x3, x10
131c: b.lo     0x100301ed4
1320: orr      x0, xzr, #0x7ff8000000000000
1324: str      x0, [x19, #0x30]
1328: mov      x0, x23
132c: str      x0, [x19, #0xc8]
1330: mov      x9, #0x7f
1334: movk     x9, #0x200, lsl #16
1338: str      x9, [x19, #0x390]
133c: str      x20, [x19, #0x398]
1340: mov      x0, #0x3
1344: ldp      x29, x30, [sp]
1348: ldp      x19, x20, [sp, #0x50]
134c: ldp      x21, x22, [sp, #0x40]
1350: ldp      x23, x24, [sp, #0x30]
1354: ldp      x25, x26, [sp, #0x20]
1358: ldr      x27, [sp, #0x18]
135c: add      sp, sp, #0x60
1360: ret      
1364: mov      x0, x4
1368: str      x0, [x19]
136c: mov      x0, x5
1370: str      x0, [x19, #0x8]
1374: mov      x0, x6
1378: str      x0, [x19, #0x10]
137c: mov      x0, x7
1380: str      x0, [x19, #0x18]
1384: mov      x0, x21
1388: str      x0, [x19, #0x20]
138c: fmov     d0, d4
1390: fmov     x0, d0
1394: lsr      x3, x0, #48
1398: mov      x10, #0xfff1
139c: cmp      x3, x10
13a0: b.lo     0x100301f58
13a4: orr      x0, xzr, #0x7ff8000000000000
13a8: str      x0, [x19, #0x30]
13ac: fmov     d0, d5
13b0: fmov     x0, d0
13b4: lsr      x3, x0, #48
13b8: mov      x10, #0xfff1
13bc: cmp      x3, x10
13c0: b.lo     0x100301f78
13c4: orr      x0, xzr, #0x7ff8000000000000
13c8: str      x0, [x19, #0x38]
13cc: mov      x0, x22
13d0: str      x0, [x19, #0xc8]
13d4: fmov     d0, d2
13d8: fmov     x0, d0
13dc: lsr      x3, x0, #48
13e0: mov      x10, #0xfff1
13e4: cmp      x3, x10
13e8: b.lo     0x100301fa0
13ec: orr      x0, xzr, #0x7ff8000000000000
13f0: str      x0, [x19, #0xd0]
13f4: mov      x9, #0xdf
13f8: movk     x9, #0x600, lsl #16
13fc: str      x9, [x19, #0x390]
1400: str      x20, [x19, #0x398]
1404: mov      x0, #0x6
1408: ldp      x29, x30, [sp]
140c: ldp      x19, x20, [sp, #0x50]
1410: ldp      x21, x22, [sp, #0x40]
1414: ldp      x23, x24, [sp, #0x30]
1418: ldp      x25, x26, [sp, #0x20]
141c: ldr      x27, [sp, #0x18]
1420: add      sp, sp, #0x60
1424: ret      
1428: mov      x0, x4
142c: str      x0, [x19]
1430: mov      x0, x5
1434: str      x0, [x19, #0x8]
1438: mov      x0, x6
143c: str      x0, [x19, #0x10]
1440: mov      x0, x7
1444: str      x0, [x19, #0x18]
1448: mov      x0, x21
144c: str      x0, [x19, #0x20]
1450: fmov     d0, d4
1454: fmov     x0, d0
1458: lsr      x3, x0, #48
145c: mov      x10, #0xfff1
1460: cmp      x3, x10
1464: b.lo     0x10030201c
1468: orr      x0, xzr, #0x7ff8000000000000
146c: str      x0, [x19, #0x30]
1470: fmov     d0, d5
1474: fmov     x0, d0
1478: lsr      x3, x0, #48
147c: mov      x10, #0xfff1
1480: cmp      x3, x10
1484: b.lo     0x10030203c
1488: orr      x0, xzr, #0x7ff8000000000000
148c: str      x0, [x19, #0x38]
1490: fmov     d0, d7
1494: fmov     x0, d0
1498: lsr      x3, x0, #48
149c: mov      x10, #0xfff1
14a0: cmp      x3, x10
14a4: b.lo     0x10030205c
14a8: orr      x0, xzr, #0x7ff8000000000000
14ac: str      x0, [x19, #0x40]
14b0: mov      x0, x23
14b4: str      x0, [x19, #0xc8]
14b8: fmov     d0, d2
14bc: fmov     x0, d0
14c0: lsr      x3, x0, #48
14c4: mov      x10, #0xfff1
14c8: cmp      x3, x10
14cc: b.lo     0x100302084
14d0: orr      x0, xzr, #0x7ff8000000000000
14d4: str      x0, [x19, #0xd0]
14d8: mov      x9, #0x1df
14dc: movk     x9, #0x600, lsl #16
14e0: str      x9, [x19, #0x390]
14e4: str      x20, [x19, #0x398]
14e8: mov      x0, #0x9
14ec: ldp      x29, x30, [sp]
14f0: ldp      x19, x20, [sp, #0x50]
14f4: ldp      x21, x22, [sp, #0x40]
14f8: ldp      x23, x24, [sp, #0x30]
14fc: ldp      x25, x26, [sp, #0x20]
1500: ldr      x27, [sp, #0x18]
1504: add      sp, sp, #0x60
1508: ret      
150c: mov      x0, x4
1510: str      x0, [x19]
1514: mov      x0, x5
1518: str      x0, [x19, #0x8]
151c: mov      x0, x6
1520: str      x0, [x19, #0x10]
1524: mov      x0, x7
1528: str      x0, [x19, #0x18]
152c: mov      x0, x21
1530: str      x0, [x19, #0x20]
1534: fmov     d0, d2
1538: fmov     x0, d0
153c: lsr      x3, x0, #48
1540: mov      x10, #0xfff1
1544: cmp      x3, x10
1548: b.lo     0x100302100
154c: orr      x0, xzr, #0x7ff8000000000000
1550: str      x0, [x19, #0x30]
1554: fmov     d0, d3
1558: fmov     x0, d0
155c: lsr      x3, x0, #48
1560: mov      x10, #0xfff1
1564: cmp      x3, x10
1568: b.lo     0x100302120
156c: orr      x0, xzr, #0x7ff8000000000000
1570: str      x0, [x19, #0x38]
1574: fmov     d0, d4
1578: fmov     x0, d0
157c: lsr      x3, x0, #48
1580: mov      x10, #0xfff1
1584: cmp      x3, x10
1588: b.lo     0x100302140
158c: orr      x0, xzr, #0x7ff8000000000000
1590: str      x0, [x19, #0x40]
1594: fmov     d0, d5
1598: fmov     x0, d0
159c: lsr      x3, x0, #48
15a0: mov      x10, #0xfff1
15a4: cmp      x3, x10
15a8: b.lo     0x100302160
15ac: orr      x0, xzr, #0x7ff8000000000000
15b0: str      x0, [x19, #0x48]
15b4: mov      x0, x22
15b8: and      x0, x0, #0xffffffffffff
15bc: mov      x10, #-0xf000000000000
15c0: orr      x0, x0, x10
15c4: str      x0, [x19, #0x50]
15c8: mov      x0, x23
15cc: str      x0, [x19, #0xc8]
15d0: mov      x9, #0x7df
15d4: movk     x9, #0x200, lsl #16
15d8: str      x9, [x19, #0x390]
15dc: str      x20, [x19, #0x398]
15e0: mov      x0, #0xd
15e4: ldp      x29, x30, [sp]
15e8: ldp      x19, x20, [sp, #0x50]
15ec: ldp      x21, x22, [sp, #0x40]
15f0: ldp      x23, x24, [sp, #0x30]
15f4: ldp      x25, x26, [sp, #0x20]
15f8: ldr      x27, [sp, #0x18]
15fc: add      sp, sp, #0x60
1600: ret      
1604: mov      x0, x4
1608: str      x0, [x19]
160c: mov      x0, x5
1610: str      x0, [x19, #0x8]
1614: mov      x0, x6
1618: str      x0, [x19, #0x10]
161c: mov      x0, x7
1620: str      x0, [x19, #0x18]
1624: mov      x0, x21
1628: str      x0, [x19, #0x20]
162c: fmov     d0, d2
1630: fmov     x0, d0
1634: lsr      x3, x0, #48
1638: mov      x10, #0xfff1
163c: cmp      x3, x10
1640: b.lo     0x1003021f8
1644: orr      x0, xzr, #0x7ff8000000000000
1648: str      x0, [x19, #0x30]
164c: fmov     d0, d3
1650: fmov     x0, d0
1654: lsr      x3, x0, #48
1658: mov      x10, #0xfff1
165c: cmp      x3, x10
1660: b.lo     0x100302218
1664: orr      x0, xzr, #0x7ff8000000000000
1668: str      x0, [x19, #0x38]
166c: fmov     d0, d4
1670: fmov     x0, d0
1674: lsr      x3, x0, #48
1678: mov      x10, #0xfff1
167c: cmp      x3, x10
1680: b.lo     0x100302238
1684: orr      x0, xzr, #0x7ff8000000000000
1688: str      x0, [x19, #0x40]
168c: fmov     d0, d5
1690: fmov     x0, d0
1694: lsr      x3, x0, #48
1698: mov      x10, #0xfff1
169c: cmp      x3, x10
16a0: b.lo     0x100302258
16a4: orr      x0, xzr, #0x7ff8000000000000
16a8: str      x0, [x19, #0x48]
16ac: mov      x0, x22
16b0: and      x0, x0, #0xffffffffffff
16b4: mov      x10, #-0xf000000000000
16b8: orr      x0, x0, x10
16bc: str      x0, [x19, #0x50]
16c0: ldr      d0, [x19, #0x530]
16c4: fmov     x0, d0
16c8: lsr      x3, x0, #48
16cc: mov      x10, #0xfff1
16d0: cmp      x3, x10
16d4: b.lo     0x10030228c
16d8: orr      x0, xzr, #0x7ff8000000000000
16dc: str      x0, [x19, #0x58]
16e0: mov      x0, x23
16e4: and      x0, x0, #0xffffffffffff
16e8: mov      x10, #-0xf000000000000
16ec: orr      x0, x0, x10
16f0: str      x0, [x19, #0x60]
16f4: mov      x9, #0x1fdf
16f8: str      x9, [x19, #0x390]
16fc: str      x20, [x19, #0x398]
1700: mov      x0, #0x11
1704: ldp      x29, x30, [sp]
1708: ldp      x19, x20, [sp, #0x50]
170c: ldp      x21, x22, [sp, #0x40]
1710: ldp      x23, x24, [sp, #0x30]
1714: ldp      x25, x26, [sp, #0x20]
1718: ldr      x27, [sp, #0x18]
171c: add      sp, sp, #0x60
1720: ret      
1724: mov      x0, x4
1728: str      x0, [x19]
172c: mov      x0, x5
1730: str      x0, [x19, #0x8]
1734: mov      x0, x6
1738: str      x0, [x19, #0x10]
173c: mov      x0, x7
1740: str      x0, [x19, #0x18]
1744: mov      x0, x21
1748: str      x0, [x19, #0x20]
174c: fmov     d0, d2
1750: fmov     x0, d0
1754: lsr      x3, x0, #48
1758: mov      x10, #0xfff1
175c: cmp      x3, x10
1760: b.lo     0x100302318
1764: orr      x0, xzr, #0x7ff8000000000000
1768: str      x0, [x19, #0x30]
176c: fmov     d0, d3
1770: fmov     x0, d0
1774: lsr      x3, x0, #48
1778: mov      x10, #0xfff1
177c: cmp      x3, x10
1780: b.lo     0x100302338
1784: orr      x0, xzr, #0x7ff8000000000000
1788: str      x0, [x19, #0x38]
178c: fmov     d0, d4
1790: fmov     x0, d0
1794: lsr      x3, x0, #48
1798: mov      x10, #0xfff1
179c: cmp      x3, x10
17a0: b.lo     0x100302358
17a4: orr      x0, xzr, #0x7ff8000000000000
17a8: str      x0, [x19, #0x40]
17ac: fmov     d0, d5
17b0: fmov     x0, d0
17b4: lsr      x3, x0, #48
17b8: mov      x10, #0xfff1
17bc: cmp      x3, x10
17c0: b.lo     0x100302378
17c4: orr      x0, xzr, #0x7ff8000000000000
17c8: str      x0, [x19, #0x48]
17cc: mov      x0, x22
17d0: and      x0, x0, #0xffffffffffff
17d4: mov      x10, #-0xf000000000000
17d8: orr      x0, x0, x10
17dc: str      x0, [x19, #0x50]
17e0: ldr      d0, [x19, #0x530]
17e4: fmov     x0, d0
17e8: lsr      x3, x0, #48
17ec: mov      x10, #0xfff1
17f0: cmp      x3, x10
17f4: b.lo     0x1003023ac
17f8: orr      x0, xzr, #0x7ff8000000000000
17fc: str      x0, [x19, #0x58]
1800: mov      x0, x23
1804: and      x0, x0, #0xffffffffffff
1808: mov      x10, #-0xf000000000000
180c: orr      x0, x0, x10
1810: str      x0, [x19, #0x60]
1814: fmov     d0, d16
1818: fmov     x0, d0
181c: lsr      x3, x0, #48
1820: mov      x10, #0xfff1
1824: cmp      x3, x10
1828: b.lo     0x1003023e0
182c: orr      x0, xzr, #0x7ff8000000000000
1830: str      x0, [x19, #0x68]
1834: mov      x9, #0x3fdf
1838: str      x9, [x19, #0x390]
183c: str      x20, [x19, #0x398]
1840: mov      x0, #0x14
1844: ldp      x29, x30, [sp]
1848: ldp      x19, x20, [sp, #0x50]
184c: ldp      x21, x22, [sp, #0x40]
1850: ldp      x23, x24, [sp, #0x30]
1854: ldp      x25, x26, [sp, #0x20]
1858: ldr      x27, [sp, #0x18]
185c: add      sp, sp, #0x60
1860: ret      
1864: mov      x0, x4
1868: str      x0, [x19]
186c: mov      x0, x5
1870: str      x0, [x19, #0x8]
1874: mov      x0, x6
1878: str      x0, [x19, #0x10]
187c: mov      x0, x7
1880: str      x0, [x19, #0x18]
1884: mov      x0, x21
1888: str      x0, [x19, #0x20]
188c: fmov     d0, d2
1890: fmov     x0, d0
1894: lsr      x3, x0, #48
1898: mov      x10, #0xfff1
189c: cmp      x3, x10
18a0: b.lo     0x100302458
18a4: orr      x0, xzr, #0x7ff8000000000000
18a8: str      x0, [x19, #0x30]
18ac: fmov     d0, d3
18b0: fmov     x0, d0
18b4: lsr      x3, x0, #48
18b8: mov      x10, #0xfff1
18bc: cmp      x3, x10
18c0: b.lo     0x100302478
18c4: orr      x0, xzr, #0x7ff8000000000000
18c8: str      x0, [x19, #0x38]
18cc: fmov     d0, d4
18d0: fmov     x0, d0
18d4: lsr      x3, x0, #48
18d8: mov      x10, #0xfff1
18dc: cmp      x3, x10
18e0: b.lo     0x100302498
18e4: orr      x0, xzr, #0x7ff8000000000000
18e8: str      x0, [x19, #0x40]
18ec: fmov     d0, d5
18f0: fmov     x0, d0
18f4: lsr      x3, x0, #48
18f8: mov      x10, #0xfff1
18fc: cmp      x3, x10
1900: b.lo     0x1003024b8
1904: orr      x0, xzr, #0x7ff8000000000000
1908: str      x0, [x19, #0x48]
190c: mov      x0, x22
1910: and      x0, x0, #0xffffffffffff
1914: mov      x10, #-0xf000000000000
1918: orr      x0, x0, x10
191c: str      x0, [x19, #0x50]
1920: ldr      d0, [x19, #0x530]
1924: fmov     x0, d0
1928: lsr      x3, x0, #48
192c: mov      x10, #0xfff1
1930: cmp      x3, x10
1934: b.lo     0x1003024ec
1938: orr      x0, xzr, #0x7ff8000000000000
193c: str      x0, [x19, #0x58]
1940: mov      x0, x23
1944: and      x0, x0, #0xffffffffffff
1948: mov      x10, #-0xf000000000000
194c: orr      x0, x0, x10
1950: str      x0, [x19, #0x60]
1954: fmov     d0, d6
1958: fmov     x0, d0
195c: lsr      x3, x0, #48
1960: mov      x10, #0xfff1
1964: cmp      x3, x10
1968: b.lo     0x100302520
196c: orr      x0, xzr, #0x7ff8000000000000
1970: str      x0, [x19, #0x68]
1974: fmov     d0, d17
1978: fmov     x0, d0
197c: lsr      x3, x0, #48
1980: mov      x10, #0xfff1
1984: cmp      x3, x10
1988: b.lo     0x100302540
198c: orr      x0, xzr, #0x7ff8000000000000
1990: str      x0, [x19, #0x70]
1994: mov      x9, #0x7fdf
1998: str      x9, [x19, #0x390]
199c: str      x20, [x19, #0x398]
19a0: mov      x0, #0x1d
19a4: ldp      x29, x30, [sp]
19a8: ldp      x19, x20, [sp, #0x50]
19ac: ldp      x21, x22, [sp, #0x40]
19b0: ldp      x23, x24, [sp, #0x30]
19b4: ldp      x25, x26, [sp, #0x20]
19b8: ldr      x27, [sp, #0x18]
19bc: add      sp, sp, #0x60
19c0: ret      
19c4: mov      x0, x4
19c8: str      x0, [x19]
19cc: mov      x0, x5
19d0: str      x0, [x19, #0x8]
19d4: mov      x0, x6
19d8: str      x0, [x19, #0x10]
19dc: mov      x0, x7
19e0: str      x0, [x19, #0x18]
19e4: mov      x0, x21
19e8: str      x0, [x19, #0x20]
19ec: fmov     d0, d2
19f0: fmov     x0, d0
19f4: lsr      x3, x0, #48
19f8: mov      x10, #0xfff1
19fc: cmp      x3, x10
1a00: b.lo     0x1003025b8
1a04: orr      x0, xzr, #0x7ff8000000000000
1a08: str      x0, [x19, #0x30]
1a0c: fmov     d0, d3
1a10: fmov     x0, d0
1a14: lsr      x3, x0, #48
1a18: mov      x10, #0xfff1
1a1c: cmp      x3, x10
1a20: b.lo     0x1003025d8
1a24: orr      x0, xzr, #0x7ff8000000000000
1a28: str      x0, [x19, #0x38]
1a2c: fmov     d0, d4
1a30: fmov     x0, d0
1a34: lsr      x3, x0, #48
1a38: mov      x10, #0xfff1
1a3c: cmp      x3, x10
1a40: b.lo     0x1003025f8
1a44: orr      x0, xzr, #0x7ff8000000000000
1a48: str      x0, [x19, #0x40]
1a4c: fmov     d0, d5
1a50: fmov     x0, d0
1a54: lsr      x3, x0, #48
1a58: mov      x10, #0xfff1
1a5c: cmp      x3, x10
1a60: b.lo     0x100302618
1a64: orr      x0, xzr, #0x7ff8000000000000
1a68: str      x0, [x19, #0x48]
1a6c: mov      x0, x22
1a70: and      x0, x0, #0xffffffffffff
1a74: mov      x10, #-0xf000000000000
1a78: orr      x0, x0, x10
1a7c: str      x0, [x19, #0x50]
1a80: ldr      d0, [x19, #0x530]
1a84: fmov     x0, d0
1a88: lsr      x3, x0, #48
1a8c: mov      x10, #0xfff1
1a90: cmp      x3, x10
1a94: b.lo     0x10030264c
1a98: orr      x0, xzr, #0x7ff8000000000000
1a9c: str      x0, [x19, #0x58]
1aa0: mov      x0, x23
1aa4: and      x0, x0, #0xffffffffffff
1aa8: mov      x10, #-0xf000000000000
1aac: orr      x0, x0, x10
1ab0: str      x0, [x19, #0x60]
1ab4: fmov     d0, d6
1ab8: fmov     x0, d0
1abc: lsr      x3, x0, #48
1ac0: mov      x10, #0xfff1
1ac4: cmp      x3, x10
1ac8: b.lo     0x100302680
1acc: orr      x0, xzr, #0x7ff8000000000000
1ad0: str      x0, [x19, #0x68]
1ad4: fmov     d0, d17
1ad8: fmov     x0, d0
1adc: lsr      x3, x0, #48
1ae0: mov      x10, #0xfff1
1ae4: cmp      x3, x10
1ae8: b.lo     0x1003026a0
1aec: orr      x0, xzr, #0x7ff8000000000000
1af0: str      x0, [x19, #0x70]
1af4: ldr      x0, [x19, #0x550]
1af8: and      x0, x0, #0xffffffffffff
1afc: mov      x10, #-0xf000000000000
1b00: orr      x0, x0, x10
1b04: str      x0, [x19, #0x78]
1b08: mov      x9, #0xffdf
1b0c: str      x9, [x19, #0x390]
1b10: str      x20, [x19, #0x398]
1b14: mov      x0, #0x1e
1b18: ldp      x29, x30, [sp]
1b1c: ldp      x19, x20, [sp, #0x50]
1b20: ldp      x21, x22, [sp, #0x40]
1b24: ldp      x23, x24, [sp, #0x30]
1b28: ldp      x25, x26, [sp, #0x20]
1b2c: ldr      x27, [sp, #0x18]
1b30: add      sp, sp, #0x60
1b34: ret      
1b38: mov      x0, x4
1b3c: str      x0, [x19]
1b40: mov      x0, x5
1b44: str      x0, [x19, #0x8]
1b48: mov      x0, x6
1b4c: str      x0, [x19, #0x10]
1b50: mov      x0, x7
1b54: str      x0, [x19, #0x18]
1b58: mov      x0, x21
1b5c: str      x0, [x19, #0x20]
1b60: fmov     d0, d2
1b64: fmov     x0, d0
1b68: lsr      x3, x0, #48
1b6c: mov      x10, #0xfff1
1b70: cmp      x3, x10
1b74: b.lo     0x10030272c
1b78: orr      x0, xzr, #0x7ff8000000000000
1b7c: str      x0, [x19, #0x30]
1b80: fmov     d0, d3
1b84: fmov     x0, d0
1b88: lsr      x3, x0, #48
1b8c: mov      x10, #0xfff1
1b90: cmp      x3, x10
1b94: b.lo     0x10030274c
1b98: orr      x0, xzr, #0x7ff8000000000000
1b9c: str      x0, [x19, #0x38]
1ba0: fmov     d0, d4
1ba4: fmov     x0, d0
1ba8: lsr      x3, x0, #48
1bac: mov      x10, #0xfff1
1bb0: cmp      x3, x10
1bb4: b.lo     0x10030276c
1bb8: orr      x0, xzr, #0x7ff8000000000000
1bbc: str      x0, [x19, #0x40]
1bc0: fmov     d0, d5
1bc4: fmov     x0, d0
1bc8: lsr      x3, x0, #48
1bcc: mov      x10, #0xfff1
1bd0: cmp      x3, x10
1bd4: b.lo     0x10030278c
1bd8: orr      x0, xzr, #0x7ff8000000000000
1bdc: str      x0, [x19, #0x48]
1be0: mov      x0, x22
1be4: and      x0, x0, #0xffffffffffff
1be8: mov      x10, #-0xf000000000000
1bec: orr      x0, x0, x10
1bf0: str      x0, [x19, #0x50]
1bf4: ldr      d0, [x19, #0x530]
1bf8: fmov     x0, d0
1bfc: lsr      x3, x0, #48
1c00: mov      x10, #0xfff1
1c04: cmp      x3, x10
1c08: b.lo     0x1003027c0
1c0c: orr      x0, xzr, #0x7ff8000000000000
1c10: str      x0, [x19, #0x58]
1c14: mov      x0, x23
1c18: and      x0, x0, #0xffffffffffff
1c1c: mov      x10, #-0xf000000000000
1c20: orr      x0, x0, x10
1c24: str      x0, [x19, #0x60]
1c28: fmov     d0, d6
1c2c: fmov     x0, d0
1c30: lsr      x3, x0, #48
1c34: mov      x10, #0xfff1
1c38: cmp      x3, x10
1c3c: b.lo     0x1003027f4
1c40: orr      x0, xzr, #0x7ff8000000000000
1c44: str      x0, [x19, #0x68]
1c48: fmov     d0, d7
1c4c: fmov     x0, d0
1c50: lsr      x3, x0, #48
1c54: mov      x10, #0xfff1
1c58: cmp      x3, x10
1c5c: b.lo     0x100302814
1c60: orr      x0, xzr, #0x7ff8000000000000
1c64: str      x0, [x19, #0x70]
1c68: ldr      x0, [x19, #0x550]
1c6c: and      x0, x0, #0xffffffffffff
1c70: mov      x10, #-0xf000000000000
1c74: orr      x0, x0, x10
1c78: str      x0, [x19, #0x78]
1c7c: ldr      x0, [x19, #0x558]
1c80: and      x0, x0, #0xffffffffffff
1c84: mov      x10, #-0xf000000000000
1c88: orr      x0, x0, x10
1c8c: str      x0, [x19, #0x80]
1c90: mov      x9, #0xffdf
1c94: movk     x9, #0x1, lsl #16
1c98: str      x9, [x19, #0x390]
1c9c: str      x20, [x19, #0x398]
1ca0: mov      x0, #0x25
1ca4: ldp      x29, x30, [sp]
1ca8: ldp      x19, x20, [sp, #0x50]
1cac: ldp      x21, x22, [sp, #0x40]
1cb0: ldp      x23, x24, [sp, #0x30]
1cb4: ldp      x25, x26, [sp, #0x20]
1cb8: ldr      x27, [sp, #0x18]
1cbc: add      sp, sp, #0x60
1cc0: ret      
1cc4: mov      x0, x4
1cc8: str      x0, [x19]
1ccc: mov      x0, x5
1cd0: str      x0, [x19, #0x8]
1cd4: mov      x0, x6
1cd8: str      x0, [x19, #0x10]
1cdc: mov      x0, x7
1ce0: str      x0, [x19, #0x18]
1ce4: mov      x0, x21
1ce8: str      x0, [x19, #0x20]
1cec: fmov     d0, d2
1cf0: fmov     x0, d0
1cf4: lsr      x3, x0, #48
1cf8: mov      x10, #0xfff1
1cfc: cmp      x3, x10
1d00: b.lo     0x1003028b8
1d04: orr      x0, xzr, #0x7ff8000000000000
1d08: str      x0, [x19, #0x30]
1d0c: fmov     d0, d3
1d10: fmov     x0, d0
1d14: lsr      x3, x0, #48
1d18: mov      x10, #0xfff1
1d1c: cmp      x3, x10
1d20: b.lo     0x1003028d8
1d24: orr      x0, xzr, #0x7ff8000000000000
1d28: str      x0, [x19, #0x38]
1d2c: fmov     d0, d4
1d30: fmov     x0, d0
1d34: lsr      x3, x0, #48
1d38: mov      x10, #0xfff1
1d3c: cmp      x3, x10
1d40: b.lo     0x1003028f8
1d44: orr      x0, xzr, #0x7ff8000000000000
1d48: str      x0, [x19, #0x40]
1d4c: fmov     d0, d5
1d50: fmov     x0, d0
1d54: lsr      x3, x0, #48
1d58: mov      x10, #0xfff1
1d5c: cmp      x3, x10
1d60: b.lo     0x100302918
1d64: orr      x0, xzr, #0x7ff8000000000000
1d68: str      x0, [x19, #0x48]
1d6c: mov      x0, x22
1d70: and      x0, x0, #0xffffffffffff
1d74: mov      x10, #-0xf000000000000
1d78: orr      x0, x0, x10
1d7c: str      x0, [x19, #0x50]
1d80: ldr      d0, [x19, #0x530]
1d84: fmov     x0, d0
1d88: lsr      x3, x0, #48
1d8c: mov      x10, #0xfff1
1d90: cmp      x3, x10
1d94: b.lo     0x10030294c
1d98: orr      x0, xzr, #0x7ff8000000000000
1d9c: str      x0, [x19, #0x58]
1da0: mov      x0, x23
1da4: and      x0, x0, #0xffffffffffff
1da8: mov      x10, #-0xf000000000000
1dac: orr      x0, x0, x10
1db0: str      x0, [x19, #0x60]
1db4: fmov     d0, d6
1db8: fmov     x0, d0
1dbc: lsr      x3, x0, #48
1dc0: mov      x10, #0xfff1
1dc4: cmp      x3, x10
1dc8: b.lo     0x100302980
1dcc: orr      x0, xzr, #0x7ff8000000000000
1dd0: str      x0, [x19, #0x68]
1dd4: fmov     d0, d7
1dd8: fmov     x0, d0
1ddc: lsr      x3, x0, #48
1de0: mov      x10, #0xfff1
1de4: cmp      x3, x10
1de8: b.lo     0x1003029a0
1dec: orr      x0, xzr, #0x7ff8000000000000
1df0: str      x0, [x19, #0x70]
1df4: ldr      x0, [x19, #0x550]
1df8: and      x0, x0, #0xffffffffffff
1dfc: mov      x10, #-0xf000000000000
1e00: orr      x0, x0, x10
1e04: str      x0, [x19, #0x78]
1e08: ldr      x0, [x19, #0x558]
1e0c: and      x0, x0, #0xffffffffffff
1e10: mov      x10, #-0xf000000000000
1e14: orr      x0, x0, x10
1e18: str      x0, [x19, #0x80]
1e1c: ldr      x0, [x19, #0x568]
1e20: and      x0, x0, #0xffffffffffff
1e24: mov      x10, #-0xf000000000000
1e28: orr      x0, x0, x10
1e2c: str      x0, [x19, #0x88]
1e30: mov      x9, #0xffdf
1e34: movk     x9, #0x3, lsl #16
1e38: str      x9, [x19, #0x390]
1e3c: str      x20, [x19, #0x398]
1e40: mov      x0, #0x26
1e44: ldp      x29, x30, [sp]
1e48: ldp      x19, x20, [sp, #0x50]
1e4c: ldp      x21, x22, [sp, #0x40]
1e50: ldp      x23, x24, [sp, #0x30]
1e54: ldp      x25, x26, [sp, #0x20]
1e58: ldr      x27, [sp, #0x18]
1e5c: add      sp, sp, #0x60
1e60: ret      
1e64: mov      x0, x4
1e68: str      x0, [x19]
1e6c: mov      x0, x5
1e70: str      x0, [x19, #0x8]
1e74: mov      x0, x6
1e78: str      x0, [x19, #0x10]
1e7c: mov      x0, x7
1e80: str      x0, [x19, #0x18]
1e84: mov      x0, x21
1e88: str      x0, [x19, #0x20]
1e8c: fmov     d0, d2
1e90: fmov     x0, d0
1e94: lsr      x3, x0, #48
1e98: mov      x10, #0xfff1
1e9c: cmp      x3, x10
1ea0: b.lo     0x100302a58
1ea4: orr      x0, xzr, #0x7ff8000000000000
1ea8: str      x0, [x19, #0x30]
1eac: fmov     d0, d3
1eb0: fmov     x0, d0
1eb4: lsr      x3, x0, #48
1eb8: mov      x10, #0xfff1
1ebc: cmp      x3, x10
1ec0: b.lo     0x100302a78
1ec4: orr      x0, xzr, #0x7ff8000000000000
1ec8: str      x0, [x19, #0x38]
1ecc: fmov     d0, d4
1ed0: fmov     x0, d0
1ed4: lsr      x3, x0, #48
1ed8: mov      x10, #0xfff1
1edc: cmp      x3, x10
1ee0: b.lo     0x100302a98
1ee4: orr      x0, xzr, #0x7ff8000000000000
1ee8: str      x0, [x19, #0x40]
1eec: fmov     d0, d5
1ef0: fmov     x0, d0
1ef4: lsr      x3, x0, #48
1ef8: mov      x10, #0xfff1
1efc: cmp      x3, x10
1f00: b.lo     0x100302ab8
1f04: orr      x0, xzr, #0x7ff8000000000000
1f08: str      x0, [x19, #0x48]
1f0c: mov      x0, x22
1f10: and      x0, x0, #0xffffffffffff
1f14: mov      x10, #-0xf000000000000
1f18: orr      x0, x0, x10
1f1c: str      x0, [x19, #0x50]
1f20: ldr      d0, [x19, #0x530]
1f24: fmov     x0, d0
1f28: lsr      x3, x0, #48
1f2c: mov      x10, #0xfff1
1f30: cmp      x3, x10
1f34: b.lo     0x100302aec
1f38: orr      x0, xzr, #0x7ff8000000000000
1f3c: str      x0, [x19, #0x58]
1f40: mov      x0, x23
1f44: and      x0, x0, #0xffffffffffff
1f48: mov      x10, #-0xf000000000000
1f4c: orr      x0, x0, x10
1f50: str      x0, [x19, #0x60]
1f54: ldr      x0, [x19, #0x550]
1f58: and      x0, x0, #0xffffffffffff
1f5c: mov      x10, #-0xf000000000000
1f60: orr      x0, x0, x10
1f64: str      x0, [x19, #0x78]
1f68: ldr      x0, [x19, #0x558]
1f6c: and      x0, x0, #0xffffffffffff
1f70: mov      x10, #-0xf000000000000
1f74: orr      x0, x0, x10
1f78: str      x0, [x19, #0x80]
1f7c: ldr      x0, [x19, #0x568]
1f80: and      x0, x0, #0xffffffffffff
1f84: mov      x10, #-0xf000000000000
1f88: orr      x0, x0, x10
1f8c: str      x0, [x19, #0x88]
1f90: ldr      x0, [x19, #0x570]
1f94: and      x0, x0, #0xffffffffffff
1f98: mov      x10, #-0xf000000000000
1f9c: orr      x0, x0, x10
1fa0: str      x0, [x19, #0x90]
1fa4: fmov     d0, d17
1fa8: fmov     x0, d0
1fac: lsr      x3, x0, #48
1fb0: mov      x10, #0xfff1
1fb4: cmp      x3, x10
1fb8: b.lo     0x100302b70
1fbc: orr      x0, xzr, #0x7ff8000000000000
1fc0: str      x0, [x19, #0x98]
1fc4: ldr      d0, [x19, #0x580]
1fc8: fmov     x0, d0
1fcc: lsr      x3, x0, #48
1fd0: mov      x10, #0xfff1
1fd4: cmp      x3, x10
1fd8: b.lo     0x100302b90
1fdc: orr      x0, xzr, #0x7ff8000000000000
1fe0: str      x0, [x19, #0xa0]
1fe4: ldr      d0, [x19, #0x588]
1fe8: fmov     x0, d0
1fec: lsr      x3, x0, #48
1ff0: mov      x10, #0xfff1
1ff4: cmp      x3, x10
1ff8: b.lo     0x100302bb0
1ffc: orr      x0, xzr, #0x7ff8000000000000
2000: str      x0, [x19, #0xa8]
2004: ldr      d0, [x19, #0x590]
2008: fmov     x0, d0
200c: lsr      x3, x0, #48
2010: mov      x10, #0xfff1
2014: cmp      x3, x10
2018: b.lo     0x100302bd0
201c: orr      x0, xzr, #0x7ff8000000000000
2020: str      x0, [x19, #0xb0]
2024: ldr      x0, [x19, #0x598]
2028: str      x0, [x19, #0xc8]
202c: mov      x9, #0x9fdf
2030: movk     x9, #0x27f, lsl #16
2034: str      x9, [x19, #0x390]
2038: str      x20, [x19, #0x398]
203c: mov      x0, #0x2e
2040: ldp      x29, x30, [sp]
2044: ldp      x19, x20, [sp, #0x50]
2048: ldp      x21, x22, [sp, #0x40]
204c: ldp      x23, x24, [sp, #0x30]
2050: ldp      x25, x26, [sp, #0x20]
2054: ldr      x27, [sp, #0x18]
2058: add      sp, sp, #0x60
205c: ret      
2060: mov      x0, x4
2064: str      x0, [x19]
2068: mov      x0, x5
206c: str      x0, [x19, #0x8]
2070: mov      x0, x6
2074: str      x0, [x19, #0x10]
2078: mov      x0, x7
207c: str      x0, [x19, #0x18]
2080: mov      x0, x21
2084: str      x0, [x19, #0x20]
2088: fmov     d0, d2
208c: fmov     x0, d0
2090: lsr      x3, x0, #48
2094: mov      x10, #0xfff1
2098: cmp      x3, x10
209c: b.lo     0x100302c54
20a0: orr      x0, xzr, #0x7ff8000000000000
20a4: str      x0, [x19, #0x30]
20a8: fmov     d0, d3
20ac: fmov     x0, d0
20b0: lsr      x3, x0, #48
20b4: mov      x10, #0xfff1
20b8: cmp      x3, x10
20bc: b.lo     0x100302c74
20c0: orr      x0, xzr, #0x7ff8000000000000
20c4: str      x0, [x19, #0x38]
20c8: fmov     d0, d4
20cc: fmov     x0, d0
20d0: lsr      x3, x0, #48
20d4: mov      x10, #0xfff1
20d8: cmp      x3, x10
20dc: b.lo     0x100302c94
20e0: orr      x0, xzr, #0x7ff8000000000000
20e4: str      x0, [x19, #0x40]
20e8: fmov     d0, d5
20ec: fmov     x0, d0
20f0: lsr      x3, x0, #48
20f4: mov      x10, #0xfff1
20f8: cmp      x3, x10
20fc: b.lo     0x100302cb4
2100: orr      x0, xzr, #0x7ff8000000000000
2104: str      x0, [x19, #0x48]
2108: mov      x0, x22
210c: and      x0, x0, #0xffffffffffff
2110: mov      x10, #-0xf000000000000
2114: orr      x0, x0, x10
2118: str      x0, [x19, #0x50]
211c: ldr      d0, [x19, #0x530]
2120: fmov     x0, d0
2124: lsr      x3, x0, #48
2128: mov      x10, #0xfff1
212c: cmp      x3, x10
2130: b.lo     0x100302ce8
2134: orr      x0, xzr, #0x7ff8000000000000
2138: str      x0, [x19, #0x58]
213c: mov      x0, x23
2140: and      x0, x0, #0xffffffffffff
2144: mov      x10, #-0xf000000000000
2148: orr      x0, x0, x10
214c: str      x0, [x19, #0x60]
2150: ldr      x0, [x19, #0x550]
2154: and      x0, x0, #0xffffffffffff
2158: mov      x10, #-0xf000000000000
215c: orr      x0, x0, x10
2160: str      x0, [x19, #0x78]
2164: ldr      x0, [x19, #0x558]
2168: and      x0, x0, #0xffffffffffff
216c: mov      x10, #-0xf000000000000
2170: orr      x0, x0, x10
2174: str      x0, [x19, #0x80]
2178: ldr      x0, [x19, #0x570]
217c: and      x0, x0, #0xffffffffffff
2180: mov      x10, #-0xf000000000000
2184: orr      x0, x0, x10
2188: str      x0, [x19, #0x90]
218c: fmov     d0, d17
2190: fmov     x0, d0
2194: lsr      x3, x0, #48
2198: mov      x10, #0xfff1
219c: cmp      x3, x10
21a0: b.lo     0x100302d58
21a4: orr      x0, xzr, #0x7ff8000000000000
21a8: str      x0, [x19, #0x98]
21ac: ldr      d0, [x19, #0x580]
21b0: fmov     x0, d0
21b4: lsr      x3, x0, #48
21b8: mov      x10, #0xfff1
21bc: cmp      x3, x10
21c0: b.lo     0x100302d78
21c4: orr      x0, xzr, #0x7ff8000000000000
21c8: str      x0, [x19, #0xa0]
21cc: ldr      d0, [x19, #0x588]
21d0: fmov     x0, d0
21d4: lsr      x3, x0, #48
21d8: mov      x10, #0xfff1
21dc: cmp      x3, x10
21e0: b.lo     0x100302d98
21e4: orr      x0, xzr, #0x7ff8000000000000
21e8: str      x0, [x19, #0xa8]
21ec: ldr      d0, [x19, #0x590]
21f0: fmov     x0, d0
21f4: lsr      x3, x0, #48
21f8: mov      x10, #0xfff1
21fc: cmp      x3, x10
2200: b.lo     0x100302db8
2204: orr      x0, xzr, #0x7ff8000000000000
2208: str      x0, [x19, #0xb0]
220c: ldr      d0, [x19, #0x5a0]
2210: fmov     x0, d0
2214: lsr      x3, x0, #48
2218: mov      x10, #0xfff1
221c: cmp      x3, x10
2220: b.lo     0x100302dd8
2224: orr      x0, xzr, #0x7ff8000000000000
2228: str      x0, [x19, #0xb8]
222c: ldr      x0, [x19, #0x598]
2230: str      x0, [x19, #0xc8]
2234: mov      x9, #0x9fdf
2238: movk     x9, #0x2fd, lsl #16
223c: str      x9, [x19, #0x390]
2240: str      x20, [x19, #0x398]
2244: mov      x0, #0x30
2248: ldp      x29, x30, [sp]
224c: ldp      x19, x20, [sp, #0x50]
2250: ldp      x21, x22, [sp, #0x40]
2254: ldp      x23, x24, [sp, #0x30]
2258: ldp      x25, x26, [sp, #0x20]
225c: ldr      x27, [sp, #0x18]
2260: add      sp, sp, #0x60
2264: ret      
2268: mov      x0, x4
226c: str      x0, [x19]
2270: mov      x0, x5
2274: str      x0, [x19, #0x8]
2278: mov      x0, x6
227c: str      x0, [x19, #0x10]
2280: mov      x0, x7
2284: str      x0, [x19, #0x18]
2288: mov      x0, x21
228c: str      x0, [x19, #0x20]
2290: fmov     d0, d2
2294: fmov     x0, d0
2298: lsr      x3, x0, #48
229c: mov      x10, #0xfff1
22a0: cmp      x3, x10
22a4: b.lo     0x100302e5c
22a8: orr      x0, xzr, #0x7ff8000000000000
22ac: str      x0, [x19, #0x30]
22b0: fmov     d0, d3
22b4: fmov     x0, d0
22b8: lsr      x3, x0, #48
22bc: mov      x10, #0xfff1
22c0: cmp      x3, x10
22c4: b.lo     0x100302e7c
22c8: orr      x0, xzr, #0x7ff8000000000000
22cc: str      x0, [x19, #0x38]
22d0: fmov     d0, d4
22d4: fmov     x0, d0
22d8: lsr      x3, x0, #48
22dc: mov      x10, #0xfff1
22e0: cmp      x3, x10
22e4: b.lo     0x100302e9c
22e8: orr      x0, xzr, #0x7ff8000000000000
22ec: str      x0, [x19, #0x40]
22f0: fmov     d0, d5
22f4: fmov     x0, d0
22f8: lsr      x3, x0, #48
22fc: mov      x10, #0xfff1
2300: cmp      x3, x10
2304: b.lo     0x100302ebc
2308: orr      x0, xzr, #0x7ff8000000000000
230c: str      x0, [x19, #0x48]
2310: mov      x0, x22
2314: and      x0, x0, #0xffffffffffff
2318: mov      x10, #-0xf000000000000
231c: orr      x0, x0, x10
2320: str      x0, [x19, #0x50]
2324: ldr      d0, [x19, #0x530]
2328: fmov     x0, d0
232c: lsr      x3, x0, #48
2330: mov      x10, #0xfff1
2334: cmp      x3, x10
2338: b.lo     0x100302ef0
233c: orr      x0, xzr, #0x7ff8000000000000
2340: str      x0, [x19, #0x58]
2344: mov      x0, x23
2348: and      x0, x0, #0xffffffffffff
234c: mov      x10, #-0xf000000000000
2350: orr      x0, x0, x10
2354: str      x0, [x19, #0x60]
2358: ldr      x0, [x19, #0x550]
235c: and      x0, x0, #0xffffffffffff
2360: mov      x10, #-0xf000000000000
2364: orr      x0, x0, x10
2368: str      x0, [x19, #0x78]
236c: ldr      x0, [x19, #0x558]
2370: and      x0, x0, #0xffffffffffff
2374: mov      x10, #-0xf000000000000
2378: orr      x0, x0, x10
237c: str      x0, [x19, #0x80]
2380: fmov     d0, d17
2384: fmov     x0, d0
2388: lsr      x3, x0, #48
238c: mov      x10, #0xfff1
2390: cmp      x3, x10
2394: b.lo     0x100302f4c
2398: orr      x0, xzr, #0x7ff8000000000000
239c: str      x0, [x19, #0x98]
23a0: ldr      d0, [x19, #0x580]
23a4: fmov     x0, d0
23a8: lsr      x3, x0, #48
23ac: mov      x10, #0xfff1
23b0: cmp      x3, x10
23b4: b.lo     0x100302f6c
23b8: orr      x0, xzr, #0x7ff8000000000000
23bc: str      x0, [x19, #0xa0]
23c0: ldr      d0, [x19, #0x588]
23c4: fmov     x0, d0
23c8: lsr      x3, x0, #48
23cc: mov      x10, #0xfff1
23d0: cmp      x3, x10
23d4: b.lo     0x100302f8c
23d8: orr      x0, xzr, #0x7ff8000000000000
23dc: str      x0, [x19, #0xa8]
23e0: ldr      d0, [x19, #0x590]
23e4: fmov     x0, d0
23e8: lsr      x3, x0, #48
23ec: mov      x10, #0xfff1
23f0: cmp      x3, x10
23f4: b.lo     0x100302fac
23f8: orr      x0, xzr, #0x7ff8000000000000
23fc: str      x0, [x19, #0xb0]
2400: ldr      d0, [x19, #0x5a0]
2404: fmov     x0, d0
2408: lsr      x3, x0, #48
240c: mov      x10, #0xfff1
2410: cmp      x3, x10
2414: b.lo     0x100302fcc
2418: orr      x0, xzr, #0x7ff8000000000000
241c: str      x0, [x19, #0xb8]
2420: ldr      d0, [x19, #0x5a8]
2424: fmov     x0, d0
2428: lsr      x3, x0, #48
242c: mov      x10, #0xfff1
2430: cmp      x3, x10
2434: b.lo     0x100302fec
2438: orr      x0, xzr, #0x7ff8000000000000
243c: str      x0, [x19, #0xc0]
2440: ldr      d0, [x19, #0x530]
2444: fmov     x0, d0
2448: lsr      x3, x0, #48
244c: mov      x10, #0xfff1
2450: cmp      x3, x10
2454: b.lo     0x10030300c
2458: orr      x0, xzr, #0x7ff8000000000000
245c: str      x0, [x19, #0xc8]
2460: fmov     d0, d6
2464: fmov     x0, d0
2468: lsr      x3, x0, #48
246c: mov      x10, #0xfff1
2470: cmp      x3, x10
2474: b.lo     0x10030302c
2478: orr      x0, xzr, #0x7ff8000000000000
247c: str      x0, [x19, #0xd8]
2480: mov      x9, #0x9fdf
2484: movk     x9, #0xbf9, lsl #16
2488: str      x9, [x19, #0x390]
248c: str      x20, [x19, #0x398]
2490: mov      x0, #0x33
2494: ldp      x29, x30, [sp]
2498: ldp      x19, x20, [sp, #0x50]
249c: ldp      x21, x22, [sp, #0x40]
24a0: ldp      x23, x24, [sp, #0x30]
24a4: ldp      x25, x26, [sp, #0x20]
24a8: ldr      x27, [sp, #0x18]
24ac: add      sp, sp, #0x60
24b0: ret      
24b4: mov      x0, x4
24b8: str      x0, [x19]
24bc: mov      x0, x5
24c0: str      x0, [x19, #0x8]
24c4: mov      x0, x6
24c8: str      x0, [x19, #0x10]
24cc: mov      x0, x7
24d0: str      x0, [x19, #0x18]
24d4: mov      x0, x21
24d8: str      x0, [x19, #0x20]
24dc: fmov     d0, d2
24e0: fmov     x0, d0
24e4: lsr      x3, x0, #48
24e8: mov      x10, #0xfff1
24ec: cmp      x3, x10
24f0: b.lo     0x1003030a8
24f4: orr      x0, xzr, #0x7ff8000000000000
24f8: str      x0, [x19, #0x30]
24fc: fmov     d0, d3
2500: fmov     x0, d0
2504: lsr      x3, x0, #48
2508: mov      x10, #0xfff1
250c: cmp      x3, x10
2510: b.lo     0x1003030c8
2514: orr      x0, xzr, #0x7ff8000000000000
2518: str      x0, [x19, #0x38]
251c: fmov     d0, d4
2520: fmov     x0, d0
2524: lsr      x3, x0, #48
2528: mov      x10, #0xfff1
252c: cmp      x3, x10
2530: b.lo     0x1003030e8
2534: orr      x0, xzr, #0x7ff8000000000000
2538: str      x0, [x19, #0x40]
253c: fmov     d0, d5
2540: fmov     x0, d0
2544: lsr      x3, x0, #48
2548: mov      x10, #0xfff1
254c: cmp      x3, x10
2550: b.lo     0x100303108
2554: orr      x0, xzr, #0x7ff8000000000000
2558: str      x0, [x19, #0x48]
255c: mov      x0, x22
2560: and      x0, x0, #0xffffffffffff
2564: mov      x10, #-0xf000000000000
2568: orr      x0, x0, x10
256c: str      x0, [x19, #0x50]
2570: ldr      d0, [x19, #0x530]
2574: fmov     x0, d0
2578: lsr      x3, x0, #48
257c: mov      x10, #0xfff1
2580: cmp      x3, x10
2584: b.lo     0x10030313c
2588: orr      x0, xzr, #0x7ff8000000000000
258c: str      x0, [x19, #0x58]
2590: mov      x0, x23
2594: and      x0, x0, #0xffffffffffff
2598: mov      x10, #-0xf000000000000
259c: orr      x0, x0, x10
25a0: str      x0, [x19, #0x60]
25a4: ldr      x0, [x19, #0x558]
25a8: and      x0, x0, #0xffffffffffff
25ac: mov      x10, #-0xf000000000000
25b0: orr      x0, x0, x10
25b4: str      x0, [x19, #0x80]
25b8: fmov     d0, d17
25bc: fmov     x0, d0
25c0: lsr      x3, x0, #48
25c4: mov      x10, #0xfff1
25c8: cmp      x3, x10
25cc: b.lo     0x100303184
25d0: orr      x0, xzr, #0x7ff8000000000000
25d4: str      x0, [x19, #0x98]
25d8: ldr      d0, [x19, #0x580]
25dc: fmov     x0, d0
25e0: lsr      x3, x0, #48
25e4: mov      x10, #0xfff1
25e8: cmp      x3, x10
25ec: b.lo     0x1003031a4
25f0: orr      x0, xzr, #0x7ff8000000000000
25f4: str      x0, [x19, #0xa0]
25f8: ldr      d0, [x19, #0x588]
25fc: fmov     x0, d0
2600: lsr      x3, x0, #48
2604: mov      x10, #0xfff1
2608: cmp      x3, x10
260c: b.lo     0x1003031c4
2610: orr      x0, xzr, #0x7ff8000000000000
2614: str      x0, [x19, #0xa8]
2618: ldr      d0, [x19, #0x590]
261c: fmov     x0, d0
2620: lsr      x3, x0, #48
2624: mov      x10, #0xfff1
2628: cmp      x3, x10
262c: b.lo     0x1003031e4
2630: orr      x0, xzr, #0x7ff8000000000000
2634: str      x0, [x19, #0xb0]
2638: ldr      d0, [x19, #0x5a0]
263c: fmov     x0, d0
2640: lsr      x3, x0, #48
2644: mov      x10, #0xfff1
2648: cmp      x3, x10
264c: b.lo     0x100303204
2650: orr      x0, xzr, #0x7ff8000000000000
2654: str      x0, [x19, #0xb8]
2658: ldr      d0, [x19, #0x5a8]
265c: fmov     x0, d0
2660: lsr      x3, x0, #48
2664: mov      x10, #0xfff1
2668: cmp      x3, x10
266c: b.lo     0x100303224
2670: orr      x0, xzr, #0x7ff8000000000000
2674: str      x0, [x19, #0xc0]
2678: ldr      d0, [x19, #0x530]
267c: fmov     x0, d0
2680: lsr      x3, x0, #48
2684: mov      x10, #0xfff1
2688: cmp      x3, x10
268c: b.lo     0x100303244
2690: orr      x0, xzr, #0x7ff8000000000000
2694: str      x0, [x19, #0xc8]
2698: fmov     d0, d6
269c: fmov     x0, d0
26a0: lsr      x3, x0, #48
26a4: mov      x10, #0xfff1
26a8: cmp      x3, x10
26ac: b.lo     0x100303264
26b0: orr      x0, xzr, #0x7ff8000000000000
26b4: str      x0, [x19, #0xe8]
26b8: fmov     d0, d7
26bc: fmov     x0, d0
26c0: lsr      x3, x0, #48
26c4: mov      x10, #0xfff1
26c8: cmp      x3, x10
26cc: b.lo     0x100303284
26d0: orr      x0, xzr, #0x7ff8000000000000
26d4: str      x0, [x19, #0xf0]
26d8: mov      x9, #0x1fdf
26dc: movk     x9, #0x63f9, lsl #16
26e0: str      x9, [x19, #0x390]
26e4: str      x20, [x19, #0x398]
26e8: mov      x0, #0x36
26ec: ldp      x29, x30, [sp]
26f0: ldp      x19, x20, [sp, #0x50]
26f4: ldp      x21, x22, [sp, #0x40]
26f8: ldp      x23, x24, [sp, #0x30]
26fc: ldp      x25, x26, [sp, #0x20]
2700: ldr      x27, [sp, #0x18]
2704: add      sp, sp, #0x60
2708: ret      
270c: mov      x0, x4
2710: str      x0, [x19]
2714: mov      x0, x5
2718: str      x0, [x19, #0x8]
271c: mov      x0, x6
2720: str      x0, [x19, #0x10]
2724: mov      x0, x7
2728: str      x0, [x19, #0x18]
272c: mov      x0, x21
2730: str      x0, [x19, #0x20]
2734: fmov     d0, d2
2738: fmov     x0, d0
273c: lsr      x3, x0, #48
2740: mov      x10, #0xfff1
2744: cmp      x3, x10
2748: b.lo     0x100303300
274c: orr      x0, xzr, #0x7ff8000000000000
2750: str      x0, [x19, #0x30]
2754: fmov     d0, d3
2758: fmov     x0, d0
275c: lsr      x3, x0, #48
2760: mov      x10, #0xfff1
2764: cmp      x3, x10
2768: b.lo     0x100303320
276c: orr      x0, xzr, #0x7ff8000000000000
2770: str      x0, [x19, #0x38]
2774: fmov     d0, d4
2778: fmov     x0, d0
277c: lsr      x3, x0, #48
2780: mov      x10, #0xfff1
2784: cmp      x3, x10
2788: b.lo     0x100303340
278c: orr      x0, xzr, #0x7ff8000000000000
2790: str      x0, [x19, #0x40]
2794: fmov     d0, d5
2798: fmov     x0, d0
279c: lsr      x3, x0, #48
27a0: mov      x10, #0xfff1
27a4: cmp      x3, x10
27a8: b.lo     0x100303360
27ac: orr      x0, xzr, #0x7ff8000000000000
27b0: str      x0, [x19, #0x48]
27b4: mov      x0, x22
27b8: and      x0, x0, #0xffffffffffff
27bc: mov      x10, #-0xf000000000000
27c0: orr      x0, x0, x10
27c4: str      x0, [x19, #0x50]
27c8: ldr      d0, [x19, #0x530]
27cc: fmov     x0, d0
27d0: lsr      x3, x0, #48
27d4: mov      x10, #0xfff1
27d8: cmp      x3, x10
27dc: b.lo     0x100303394
27e0: orr      x0, xzr, #0x7ff8000000000000
27e4: str      x0, [x19, #0x58]
27e8: mov      x0, x23
27ec: and      x0, x0, #0xffffffffffff
27f0: mov      x10, #-0xf000000000000
27f4: orr      x0, x0, x10
27f8: str      x0, [x19, #0x60]
27fc: ldr      x0, [x19, #0x558]
2800: and      x0, x0, #0xffffffffffff
2804: mov      x10, #-0xf000000000000
2808: orr      x0, x0, x10
280c: str      x0, [x19, #0x80]
2810: fmov     d0, d17
2814: fmov     x0, d0
2818: lsr      x3, x0, #48
281c: mov      x10, #0xfff1
2820: cmp      x3, x10
2824: b.lo     0x1003033dc
2828: orr      x0, xzr, #0x7ff8000000000000
282c: str      x0, [x19, #0x98]
2830: ldr      d0, [x19, #0x588]
2834: fmov     x0, d0
2838: lsr      x3, x0, #48
283c: mov      x10, #0xfff1
2840: cmp      x3, x10
2844: b.lo     0x1003033fc
2848: orr      x0, xzr, #0x7ff8000000000000
284c: str      x0, [x19, #0xa8]
2850: ldr      d0, [x19, #0x590]
2854: fmov     x0, d0
2858: lsr      x3, x0, #48
285c: mov      x10, #0xfff1
2860: cmp      x3, x10
2864: b.lo     0x10030341c
2868: orr      x0, xzr, #0x7ff8000000000000
286c: str      x0, [x19, #0xb0]
2870: ldr      d0, [x19, #0x5a8]
2874: fmov     x0, d0
2878: lsr      x3, x0, #48
287c: mov      x10, #0xfff1
2880: cmp      x3, x10
2884: b.lo     0x10030343c
2888: orr      x0, xzr, #0x7ff8000000000000
288c: str      x0, [x19, #0xc0]
2890: ldr      d0, [x19, #0x530]
2894: fmov     x0, d0
2898: lsr      x3, x0, #48
289c: mov      x10, #0xfff1
28a0: cmp      x3, x10
28a4: b.lo     0x10030345c
28a8: orr      x0, xzr, #0x7ff8000000000000
28ac: str      x0, [x19, #0xc8]
28b0: fmov     d0, d6
28b4: fmov     x0, d0
28b8: lsr      x3, x0, #48
28bc: mov      x10, #0xfff1
28c0: cmp      x3, x10
28c4: b.lo     0x10030347c
28c8: orr      x0, xzr, #0x7ff8000000000000
28cc: str      x0, [x19, #0x100]
28d0: fmov     d0, d16
28d4: fmov     x0, d0
28d8: lsr      x3, x0, #48
28dc: mov      x10, #0xfff1
28e0: cmp      x3, x10
28e4: b.lo     0x10030349c
28e8: orr      x0, xzr, #0x7ff8000000000000
28ec: str      x0, [x19, #0x108]
28f0: mov      x9, #0x1fdf
28f4: movk     x9, #0x369, lsl #16
28f8: movk     x9, #0x3, lsl #32
28fc: str      x9, [x19, #0x390]
2900: str      x20, [x19, #0x398]
2904: mov      x0, #0x3b
2908: ldp      x29, x30, [sp]
290c: ldp      x19, x20, [sp, #0x50]
2910: ldp      x21, x22, [sp, #0x40]
2914: ldp      x23, x24, [sp, #0x30]
2918: ldp      x25, x26, [sp, #0x20]
291c: ldr      x27, [sp, #0x18]
2920: add      sp, sp, #0x60
2924: ret      
2928: mov      x0, x4
292c: str      x0, [x19]
2930: mov      x0, x5
2934: str      x0, [x19, #0x8]
2938: mov      x0, x6
293c: str      x0, [x19, #0x10]
2940: mov      x0, x7
2944: str      x0, [x19, #0x18]
2948: mov      x0, x21
294c: str      x0, [x19, #0x20]
2950: fmov     d0, d2
2954: fmov     x0, d0
2958: lsr      x3, x0, #48
295c: mov      x10, #0xfff1
2960: cmp      x3, x10
2964: b.lo     0x10030351c
2968: orr      x0, xzr, #0x7ff8000000000000
296c: str      x0, [x19, #0x30]
2970: fmov     d0, d3
2974: fmov     x0, d0
2978: lsr      x3, x0, #48
297c: mov      x10, #0xfff1
2980: cmp      x3, x10
2984: b.lo     0x10030353c
2988: orr      x0, xzr, #0x7ff8000000000000
298c: str      x0, [x19, #0x38]
2990: fmov     d0, d4
2994: fmov     x0, d0
2998: lsr      x3, x0, #48
299c: mov      x10, #0xfff1
29a0: cmp      x3, x10
29a4: b.lo     0x10030355c
29a8: orr      x0, xzr, #0x7ff8000000000000
29ac: str      x0, [x19, #0x40]
29b0: fmov     d0, d5
29b4: fmov     x0, d0
29b8: lsr      x3, x0, #48
29bc: mov      x10, #0xfff1
29c0: cmp      x3, x10
29c4: b.lo     0x10030357c
29c8: orr      x0, xzr, #0x7ff8000000000000
29cc: str      x0, [x19, #0x48]
29d0: mov      x0, x22
29d4: and      x0, x0, #0xffffffffffff
29d8: mov      x10, #-0xf000000000000
29dc: orr      x0, x0, x10
29e0: str      x0, [x19, #0x50]
29e4: ldr      d0, [x19, #0x530]
29e8: fmov     x0, d0
29ec: lsr      x3, x0, #48
29f0: mov      x10, #0xfff1
29f4: cmp      x3, x10
29f8: b.lo     0x1003035b0
29fc: orr      x0, xzr, #0x7ff8000000000000
2a00: str      x0, [x19, #0x58]
2a04: mov      x0, x23
2a08: and      x0, x0, #0xffffffffffff
2a0c: mov      x10, #-0xf000000000000
2a10: orr      x0, x0, x10
2a14: str      x0, [x19, #0x60]
2a18: fmov     d0, d17
2a1c: fmov     x0, d0
2a20: lsr      x3, x0, #48
2a24: mov      x10, #0xfff1
2a28: cmp      x3, x10
2a2c: b.lo     0x1003035e4
2a30: orr      x0, xzr, #0x7ff8000000000000
2a34: str      x0, [x19, #0x98]
2a38: ldr      d0, [x19, #0x588]
2a3c: fmov     x0, d0
2a40: lsr      x3, x0, #48
2a44: mov      x10, #0xfff1
2a48: cmp      x3, x10
2a4c: b.lo     0x100303604
2a50: orr      x0, xzr, #0x7ff8000000000000
2a54: str      x0, [x19, #0xa8]
2a58: ldr      d0, [x19, #0x530]
2a5c: fmov     x0, d0
2a60: lsr      x3, x0, #48
2a64: mov      x10, #0xfff1
2a68: cmp      x3, x10
2a6c: b.lo     0x100303624
2a70: orr      x0, xzr, #0x7ff8000000000000
2a74: str      x0, [x19, #0xc8]
2a78: fmov     d0, d6
2a7c: fmov     x0, d0
2a80: lsr      x3, x0, #48
2a84: mov      x10, #0xfff1
2a88: cmp      x3, x10
2a8c: b.lo     0x100303644
2a90: orr      x0, xzr, #0x7ff8000000000000
2a94: str      x0, [x19, #0x100]
2a98: fmov     d0, d16
2a9c: fmov     x0, d0
2aa0: lsr      x3, x0, #48
2aa4: mov      x10, #0xfff1
2aa8: cmp      x3, x10
2aac: b.lo     0x100303664
2ab0: orr      x0, xzr, #0x7ff8000000000000
2ab4: str      x0, [x19, #0x118]
2ab8: ldr      d0, [x19, #0x5d0]
2abc: fmov     x0, d0
2ac0: lsr      x3, x0, #48
2ac4: mov      x10, #0xfff1
2ac8: cmp      x3, x10
2acc: b.lo     0x100303684
2ad0: orr      x0, xzr, #0x7ff8000000000000
2ad4: str      x0, [x19, #0x120]
2ad8: mov      x9, #0x1fdf
2adc: movk     x9, #0x228, lsl #16
2ae0: movk     x9, #0x19, lsl #32
2ae4: str      x9, [x19, #0x390]
2ae8: str      x20, [x19, #0x398]
2aec: mov      x0, #0x3e
2af0: ldp      x29, x30, [sp]
2af4: ldp      x19, x20, [sp, #0x50]
2af8: ldp      x21, x22, [sp, #0x40]
2afc: ldp      x23, x24, [sp, #0x30]
2b00: ldp      x25, x26, [sp, #0x20]
2b04: ldr      x27, [sp, #0x18]
2b08: add      sp, sp, #0x60
2b0c: ret      
2b10: mov      x0, x4
2b14: str      x0, [x19]
2b18: mov      x0, x5
2b1c: str      x0, [x19, #0x8]
2b20: mov      x0, x6
2b24: str      x0, [x19, #0x10]
2b28: mov      x0, x7
2b2c: str      x0, [x19, #0x18]
2b30: mov      x0, x21
2b34: str      x0, [x19, #0x20]
2b38: fmov     d0, d2
2b3c: fmov     x0, d0
2b40: lsr      x3, x0, #48
2b44: mov      x10, #0xfff1
2b48: cmp      x3, x10
2b4c: b.lo     0x100303704
2b50: orr      x0, xzr, #0x7ff8000000000000
2b54: str      x0, [x19, #0x30]
2b58: fmov     d0, d3
2b5c: fmov     x0, d0
2b60: lsr      x3, x0, #48
2b64: mov      x10, #0xfff1
2b68: cmp      x3, x10
2b6c: b.lo     0x100303724
2b70: orr      x0, xzr, #0x7ff8000000000000
2b74: str      x0, [x19, #0x38]
2b78: fmov     d0, d4
2b7c: fmov     x0, d0
2b80: lsr      x3, x0, #48
2b84: mov      x10, #0xfff1
2b88: cmp      x3, x10
2b8c: b.lo     0x100303744
2b90: orr      x0, xzr, #0x7ff8000000000000
2b94: str      x0, [x19, #0x40]
2b98: fmov     d0, d5
2b9c: fmov     x0, d0
2ba0: lsr      x3, x0, #48
2ba4: mov      x10, #0xfff1
2ba8: cmp      x3, x10
2bac: b.lo     0x100303764
2bb0: orr      x0, xzr, #0x7ff8000000000000
2bb4: str      x0, [x19, #0x48]
2bb8: mov      x0, x22
2bbc: and      x0, x0, #0xffffffffffff
2bc0: mov      x10, #-0xf000000000000
2bc4: orr      x0, x0, x10
2bc8: str      x0, [x19, #0x50]
2bcc: ldr      d0, [x19, #0x530]
2bd0: fmov     x0, d0
2bd4: lsr      x3, x0, #48
2bd8: mov      x10, #0xfff1
2bdc: cmp      x3, x10
2be0: b.lo     0x100303798
2be4: orr      x0, xzr, #0x7ff8000000000000
2be8: str      x0, [x19, #0x58]
2bec: mov      x0, x23
2bf0: and      x0, x0, #0xffffffffffff
2bf4: mov      x10, #-0xf000000000000
2bf8: orr      x0, x0, x10
2bfc: str      x0, [x19, #0x60]
2c00: ldr      d0, [x19, #0x530]
2c04: fmov     x0, d0
2c08: lsr      x3, x0, #48
2c0c: mov      x10, #0xfff1
2c10: cmp      x3, x10
2c14: b.lo     0x1003037cc
2c18: orr      x0, xzr, #0x7ff8000000000000
2c1c: str      x0, [x19, #0xc8]
2c20: fmov     d0, d7
2c24: fmov     x0, d0
2c28: lsr      x3, x0, #48
2c2c: mov      x10, #0xfff1
2c30: cmp      x3, x10
2c34: b.lo     0x1003037ec
2c38: orr      x0, xzr, #0x7ff8000000000000
2c3c: str      x0, [x19, #0x100]
2c40: mov      x9, #0x1fdf
2c44: movk     x9, #0x200, lsl #16
2c48: movk     x9, #0x1, lsl #32
2c4c: str      x9, [x19, #0x390]
2c50: str      x20, [x19, #0x398]
2c54: mov      x0, #0x43
2c58: ldp      x29, x30, [sp]
2c5c: ldp      x19, x20, [sp, #0x50]
2c60: ldp      x21, x22, [sp, #0x40]
2c64: ldp      x23, x24, [sp, #0x30]
2c68: ldp      x25, x26, [sp, #0x20]
2c6c: ldr      x27, [sp, #0x18]
2c70: add      sp, sp, #0x60
2c74: ret      
2c78: mov      x0, x4
2c7c: str      x0, [x19]
2c80: mov      x0, x5
2c84: str      x0, [x19, #0x8]
2c88: mov      x0, x6
2c8c: str      x0, [x19, #0x10]
2c90: mov      x0, x7
2c94: str      x0, [x19, #0x18]
2c98: mov      x0, x21
2c9c: str      x0, [x19, #0x20]
2ca0: fmov     d0, d2
2ca4: fmov     x0, d0
2ca8: lsr      x3, x0, #48
2cac: mov      x10, #0xfff1
2cb0: cmp      x3, x10
2cb4: b.lo     0x10030386c
2cb8: orr      x0, xzr, #0x7ff8000000000000
2cbc: str      x0, [x19, #0x30]
2cc0: fmov     d0, d3
2cc4: fmov     x0, d0
2cc8: lsr      x3, x0, #48
2ccc: mov      x10, #0xfff1
2cd0: cmp      x3, x10
2cd4: b.lo     0x10030388c
2cd8: orr      x0, xzr, #0x7ff8000000000000
2cdc: str      x0, [x19, #0x38]
2ce0: fmov     d0, d4
2ce4: fmov     x0, d0
2ce8: lsr      x3, x0, #48
2cec: mov      x10, #0xfff1
2cf0: cmp      x3, x10
2cf4: b.lo     0x1003038ac
2cf8: orr      x0, xzr, #0x7ff8000000000000
2cfc: str      x0, [x19, #0x40]
2d00: fmov     d0, d5
2d04: fmov     x0, d0
2d08: lsr      x3, x0, #48
2d0c: mov      x10, #0xfff1
2d10: cmp      x3, x10
2d14: b.lo     0x1003038cc
2d18: orr      x0, xzr, #0x7ff8000000000000
2d1c: str      x0, [x19, #0x48]
2d20: mov      x0, x22
2d24: and      x0, x0, #0xffffffffffff
2d28: mov      x10, #-0xf000000000000
2d2c: orr      x0, x0, x10
2d30: str      x0, [x19, #0x50]
2d34: ldr      d0, [x19, #0x530]
2d38: fmov     x0, d0
2d3c: lsr      x3, x0, #48
2d40: mov      x10, #0xfff1
2d44: cmp      x3, x10
2d48: b.lo     0x100303900
2d4c: orr      x0, xzr, #0x7ff8000000000000
2d50: str      x0, [x19, #0x58]
2d54: mov      x0, x23
2d58: and      x0, x0, #0xffffffffffff
2d5c: mov      x10, #-0xf000000000000
2d60: orr      x0, x0, x10
2d64: str      x0, [x19, #0x60]
2d68: mov      x9, #0x1fdf
2d6c: str      x9, [x19, #0x390]
2d70: str      x20, [x19, #0x398]
2d74: mov      x0, #0x44
2d78: ldp      x29, x30, [sp]
2d7c: ldp      x19, x20, [sp, #0x50]
2d80: ldp      x21, x22, [sp, #0x40]
2d84: ldp      x23, x24, [sp, #0x30]
2d88: ldp      x25, x26, [sp, #0x20]
2d8c: ldr      x27, [sp, #0x18]
2d90: add      sp, sp, #0x60
2d94: ret      
2d98: ldr      x0, [x19, #0x3a0]
2d9c: str      x0, [x19]
2da0: ldr      x0, [x19, #0x3a8]
2da4: str      x0, [x19, #0x8]
2da8: ldr      x0, [x19, #0x3b0]
2dac: str      x0, [x19, #0x10]
2db0: ldr      x0, [x19, #0x3b8]
2db4: str      x0, [x19, #0x18]
2db8: ldr      x0, [x19, #0x3c0]
2dbc: str      x0, [x19, #0x20]
2dc0: fmov     d0, d7
2dc4: fmov     x0, d0
2dc8: lsr      x3, x0, #48
2dcc: mov      x10, #0xfff1
2dd0: cmp      x3, x10
2dd4: b.lo     0x10030398c
2dd8: orr      x0, xzr, #0x7ff8000000000000
2ddc: str      x0, [x19, #0x30]
2de0: fmov     d0, d16
2de4: fmov     x0, d0
2de8: lsr      x3, x0, #48
2dec: mov      x10, #0xfff1
2df0: cmp      x3, x10
2df4: b.lo     0x1003039ac
2df8: orr      x0, xzr, #0x7ff8000000000000
2dfc: str      x0, [x19, #0x38]
2e00: fmov     d0, d17
2e04: fmov     x0, d0
2e08: lsr      x3, x0, #48
2e0c: mov      x10, #0xfff1
2e10: cmp      x3, x10
2e14: b.lo     0x1003039cc
2e18: orr      x0, xzr, #0x7ff8000000000000
2e1c: str      x0, [x19, #0x40]
2e20: ldr      d0, [x19, #0x3c8]
2e24: fmov     x0, d0
2e28: lsr      x3, x0, #48
2e2c: mov      x10, #0xfff1
2e30: cmp      x3, x10
2e34: b.lo     0x1003039ec
2e38: orr      x0, xzr, #0x7ff8000000000000
2e3c: str      x0, [x19, #0x48]
2e40: ldr      x0, [x19, #0x3d0]
2e44: and      x0, x0, #0xffffffffffff
2e48: mov      x10, #-0xf000000000000
2e4c: orr      x0, x0, x10
2e50: str      x0, [x19, #0x50]
2e54: ldr      d0, [x19, #0x3d8]
2e58: fmov     x0, d0
2e5c: lsr      x3, x0, #48
2e60: mov      x10, #0xfff1
2e64: cmp      x3, x10
2e68: b.lo     0x100303a20
2e6c: orr      x0, xzr, #0x7ff8000000000000
2e70: str      x0, [x19, #0x58]
2e74: ldr      x0, [x19, #0x3e0]
2e78: and      x0, x0, #0xffffffffffff
2e7c: mov      x10, #-0xf000000000000
2e80: orr      x0, x0, x10
2e84: str      x0, [x19, #0x60]
2e88: ldr      x0, [x19, #0x5f8]
2e8c: str      x0, [x19, #0xc8]
2e90: mov      x9, #0x1fdf
2e94: movk     x9, #0x200, lsl #16
2e98: str      x9, [x19, #0x390]
2e9c: str      x20, [x19, #0x398]
2ea0: mov      x0, #0x46
2ea4: ldp      x29, x30, [sp]
2ea8: ldp      x19, x20, [sp, #0x50]
2eac: ldp      x21, x22, [sp, #0x40]
2eb0: ldp      x23, x24, [sp, #0x30]
2eb4: ldp      x25, x26, [sp, #0x20]
2eb8: ldr      x27, [sp, #0x18]
2ebc: add      sp, sp, #0x60
2ec0: ret      
2ec4: ldr      x0, [x19, #0x3a0]
2ec8: str      x0, [x19]
2ecc: ldr      x0, [x19, #0x3a8]
2ed0: str      x0, [x19, #0x8]
2ed4: ldr      x0, [x19, #0x3b0]
2ed8: str      x0, [x19, #0x10]
2edc: ldr      x0, [x19, #0x3b8]
2ee0: str      x0, [x19, #0x18]
2ee4: ldr      x0, [x19, #0x3c0]
2ee8: str      x0, [x19, #0x20]
2eec: fmov     d0, d7
2ef0: fmov     x0, d0
2ef4: lsr      x3, x0, #48
2ef8: mov      x10, #0xfff1
2efc: cmp      x3, x10
2f00: b.lo     0x100303ab8
2f04: orr      x0, xzr, #0x7ff8000000000000
2f08: str      x0, [x19, #0x30]
2f0c: fmov     d0, d16
2f10: fmov     x0, d0
2f14: lsr      x3, x0, #48
2f18: mov      x10, #0xfff1
2f1c: cmp      x3, x10
2f20: b.lo     0x100303ad8
2f24: orr      x0, xzr, #0x7ff8000000000000
2f28: str      x0, [x19, #0x38]
2f2c: fmov     d0, d17
2f30: fmov     x0, d0
2f34: lsr      x3, x0, #48
2f38: mov      x10, #0xfff1
2f3c: cmp      x3, x10
2f40: b.lo     0x100303af8
2f44: orr      x0, xzr, #0x7ff8000000000000
2f48: str      x0, [x19, #0x40]
2f4c: ldr      d0, [x19, #0x3c8]
2f50: fmov     x0, d0
2f54: lsr      x3, x0, #48
2f58: mov      x10, #0xfff1
2f5c: cmp      x3, x10
2f60: b.lo     0x100303b18
2f64: orr      x0, xzr, #0x7ff8000000000000
2f68: str      x0, [x19, #0x48]
2f6c: ldr      x0, [x19, #0x3d0]
2f70: and      x0, x0, #0xffffffffffff
2f74: mov      x10, #-0xf000000000000
2f78: orr      x0, x0, x10
2f7c: str      x0, [x19, #0x50]
2f80: mov      x9, #0x7df
2f84: str      x9, [x19, #0x390]
2f88: str      x20, [x19, #0x398]
2f8c: mov      x0, #0x47
2f90: ldp      x29, x30, [sp]
2f94: ldp      x19, x20, [sp, #0x50]
2f98: ldp      x21, x22, [sp, #0x40]
2f9c: ldp      x23, x24, [sp, #0x30]
2fa0: ldp      x25, x26, [sp, #0x20]
2fa4: ldr      x27, [sp, #0x18]
2fa8: add      sp, sp, #0x60
2fac: ret      
2fb0: mov      x0, x23
2fb4: str      x0, [x19]
2fb8: ldr      x0, [x19, #0x3e8]
2fbc: str      x0, [x19, #0x8]
2fc0: ldr      x0, [x19, #0x3f0]
2fc4: str      x0, [x19, #0x10]
2fc8: ldr      x0, [x19, #0x3f8]
2fcc: str      x0, [x19, #0x18]
2fd0: ldr      x0, [x19, #0x400]
2fd4: str      x0, [x19, #0x20]
2fd8: fmov     d0, d6
2fdc: fmov     x0, d0
2fe0: lsr      x3, x0, #48
2fe4: mov      x10, #0xfff1
2fe8: cmp      x3, x10
2fec: b.lo     0x100303ba4
2ff0: orr      x0, xzr, #0x7ff8000000000000
2ff4: str      x0, [x19, #0x30]
2ff8: ldr      d0, [x19, #0x408]
2ffc: fmov     x0, d0
3000: lsr      x3, x0, #48
3004: mov      x10, #0xfff1
3008: cmp      x3, x10
300c: b.lo     0x100303bc4
3010: orr      x0, xzr, #0x7ff8000000000000
3014: str      x0, [x19, #0x38]
3018: ldr      d0, [x19, #0x410]
301c: fmov     x0, d0
3020: lsr      x3, x0, #48
3024: mov      x10, #0xfff1
3028: cmp      x3, x10
302c: b.lo     0x100303be4
3030: orr      x0, xzr, #0x7ff8000000000000
3034: str      x0, [x19, #0x40]
3038: ldr      d0, [x19, #0x418]
303c: fmov     x0, d0
3040: lsr      x3, x0, #48
3044: mov      x10, #0xfff1
3048: cmp      x3, x10
304c: b.lo     0x100303c04
3050: orr      x0, xzr, #0x7ff8000000000000
3054: str      x0, [x19, #0x48]
3058: ldr      x0, [x19, #0x420]
305c: and      x0, x0, #0xffffffffffff
3060: mov      x10, #-0xf000000000000
3064: orr      x0, x0, x10
3068: str      x0, [x19, #0x50]
306c: mov      x0, x4
3070: str      x0, [x19, #0xc8]
3074: mov      x9, #0x7df
3078: movk     x9, #0x200, lsl #16
307c: str      x9, [x19, #0x390]
3080: str      x20, [x19, #0x398]
3084: mov      x0, #0x49
3088: ldp      x29, x30, [sp]
308c: ldp      x19, x20, [sp, #0x50]
3090: ldp      x21, x22, [sp, #0x40]
3094: ldp      x23, x24, [sp, #0x30]
3098: ldp      x25, x26, [sp, #0x20]
309c: ldr      x27, [sp, #0x18]
30a0: add      sp, sp, #0x60
30a4: ret      
30a8: mov      x0, x23
30ac: str      x0, [x19]
30b0: ldr      x0, [x19, #0x3e8]
30b4: str      x0, [x19, #0x8]
30b8: ldr      x0, [x19, #0x3f0]
30bc: str      x0, [x19, #0x10]
30c0: ldr      x0, [x19, #0x3f8]
30c4: str      x0, [x19, #0x18]
30c8: ldr      x0, [x19, #0x400]
30cc: str      x0, [x19, #0x20]
30d0: fmov     d0, d6
30d4: fmov     x0, d0
30d8: lsr      x3, x0, #48
30dc: mov      x10, #0xfff1
30e0: cmp      x3, x10
30e4: b.lo     0x100303c9c
30e8: orr      x0, xzr, #0x7ff8000000000000
30ec: str      x0, [x19, #0x30]
30f0: ldr      d0, [x19, #0x408]
30f4: fmov     x0, d0
30f8: lsr      x3, x0, #48
30fc: mov      x10, #0xfff1
3100: cmp      x3, x10
3104: b.lo     0x100303cbc
3108: orr      x0, xzr, #0x7ff8000000000000
310c: str      x0, [x19, #0x38]
3110: ldr      d0, [x19, #0x410]
3114: fmov     x0, d0
3118: lsr      x3, x0, #48
311c: mov      x10, #0xfff1
3120: cmp      x3, x10
3124: b.lo     0x100303cdc
3128: orr      x0, xzr, #0x7ff8000000000000
312c: str      x0, [x19, #0x40]
3130: ldr      d0, [x19, #0x418]
3134: fmov     x0, d0
3138: lsr      x3, x0, #48
313c: mov      x10, #0xfff1
3140: cmp      x3, x10
3144: b.lo     0x100303cfc
3148: orr      x0, xzr, #0x7ff8000000000000
314c: str      x0, [x19, #0x48]
3150: ldr      x0, [x19, #0x420]
3154: and      x0, x0, #0xffffffffffff
3158: mov      x10, #-0xf000000000000
315c: orr      x0, x0, x10
3160: str      x0, [x19, #0x50]
3164: ldr      x0, [x19, #0x600]
3168: str      x0, [x19, #0xd0]
316c: mov      x9, #0x7df
3170: movk     x9, #0x400, lsl #16
3174: str      x9, [x19, #0x390]
3178: str      x20, [x19, #0x398]
317c: mov      x0, #0x4a
3180: ldp      x29, x30, [sp]
3184: ldp      x19, x20, [sp, #0x50]
3188: ldp      x21, x22, [sp, #0x40]
318c: ldp      x23, x24, [sp, #0x30]
3190: ldp      x25, x26, [sp, #0x20]
3194: ldr      x27, [sp, #0x18]
3198: add      sp, sp, #0x60
319c: ret      
