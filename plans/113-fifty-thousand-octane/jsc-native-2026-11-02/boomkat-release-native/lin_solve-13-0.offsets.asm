     0: 	stp	x29, x30, [sp, #-96]!
     4: 	stp	x19, x20, [sp, #80]
     8: 	stp	x21, x22, [sp, #64]
    12: 	stp	x23, x24, [sp, #48]
    16: 	stp	x25, x26, [sp, #32]
    20: 	str	x27, [sp, #24]
    24: 	mov	x29, sp
    28: 	mov	x19, x0
    32: 	mov	x20, x1
    36: 	ldr	x0, [x19, #16]
    40: 	ldr	x10, [x19, #528]
    44: 	cmp	x0, x10
    48: 	b.ne	#664
    52: 	ldr	x24, [x19, #544]
    56: 	ldr	x25, [x19, #536]
    60: 	ldr	x0, [x19, #8]
    64: 	ldr	x10, [x19, #560]
    68: 	cmp	x0, x10
    72: 	b.ne	#640
    76: 	ldr	x26, [x19, #576]
    80: 	ldr	x27, [x19, #568]
    84: 	ldr	x0, [x19, #48]
    88: 	lsr	x3, x0, #48
    92: 	mov	x10, #65521                     // =0xfff1
    96: 	cmp	x3, x10
   100: 	b.eq	#104
   104: 	mov	x10, #65521                     // =0xfff1
   108: 	cmp	x3, x10
   112: 	b.hi	#600
   116: 	fmov	d0, x0
   120: 	fcmp	d0, d0
   124: 	b.vs	#588
   128: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   132: 	fmov	d1, x1
   136: 	fcmp	d0, d1
   140: 	b.mi	#572
   144: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   148: 	fmov	d1, x1
   152: 	fcmp	d0, d1
   156: 	b.ge	#556
   160: 	lsl	x3, x0, #1
   164: 	cbnz	x3, #12
   168: 	cmp	x0, #0
   172: 	b.lt	#540
   176: 	fcvtzs	x0, d0
   180: 	scvtf	d1, x0
   184: 	fcmp	d0, d1
   188: 	cset	x9, ne
   192: 	ccmp	x9, #0, #4, vc
   196: 	b.ne	#516
   200: 	b	#28
   204: 	sxtw	x3, w0
   208: 	lsl	x1, x0, #16
   212: 	asr	x1, x1, #16
   216: 	cmp	x1, x3
   220: 	b.ne	#492
   224: 	mov	x0, x1
   228: 	mov	x4, x0
   232: 	ldr	x0, [x19, #56]
   236: 	lsr	x3, x0, #48
   240: 	mov	x10, #65521                     // =0xfff1
   244: 	cmp	x3, x10
   248: 	b.eq	#104
   252: 	mov	x10, #65521                     // =0xfff1
   256: 	cmp	x3, x10
   260: 	b.hi	#452
   264: 	fmov	d0, x0
   268: 	fcmp	d0, d0
   272: 	b.vs	#440
   276: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   280: 	fmov	d1, x1
   284: 	fcmp	d0, d1
   288: 	b.mi	#424
   292: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   296: 	fmov	d1, x1
   300: 	fcmp	d0, d1
   304: 	b.ge	#408
   308: 	lsl	x3, x0, #1
   312: 	cbnz	x3, #12
   316: 	cmp	x0, #0
   320: 	b.lt	#392
   324: 	fcvtzs	x0, d0
   328: 	scvtf	d1, x0
   332: 	fcmp	d0, d1
   336: 	cset	x9, ne
   340: 	ccmp	x9, #0, #4, vc
   344: 	b.ne	#368
   348: 	b	#28
   352: 	sxtw	x3, w0
   356: 	lsl	x1, x0, #16
   360: 	asr	x1, x1, #16
   364: 	cmp	x1, x3
   368: 	b.ne	#344
   372: 	mov	x0, x1
   376: 	mov	x5, x0
   380: 	mov	x1, x4
   384: 	cmp	x1, x24
   388: 	b.hs	#372
   392: 	lsl	x1, x1, #3
   396: 	add	x2, x25, x1
   400: 	ldr	x0, [x2]
   404: 	lsr	x3, x0, #48
   408: 	mov	x10, #65521                     // =0xfff1
   412: 	cmp	x3, x10
   416: 	b.hs	#344
   420: 	fmov	d2, x0
   424: 	fmov	x6, d2
   428: 	lsr	x3, x6, #48
   432: 	mov	x10, #65521                     // =0xfff1
   436: 	cmp	x3, x10
   440: 	b.lo	#8
   444: 	orr	x6, xzr, #0x7ff8000000000000
   448: 	mov	x1, x4
   452: 	cmp	x1, x26
   456: 	b.hs	#416
   460: 	lsl	x1, x1, #3
   464: 	add	x2, x27, x1
   468: 	ldr	x0, [x2]
   472: 	lsr	x3, x0, #48
   476: 	mov	x10, #65521                     // =0xfff1
   480: 	cmp	x3, x10
   484: 	b.hi	#388
   488: 	mov	x0, x6
   492: 	str	x0, [x2]
   496: 	adds	w6, w4, #1
   500: 	b.vs	#516
   504: 	sxtw	x6, w6
   508: 	adds	w7, w5, #1
   512: 	b.vs	#648
   516: 	sxtw	x7, w7
   520: 	ldr	x0, [x19, #784]
   524: 	mov	x21, x0
   528: 	mov	x0, x7
   532: 	scvtf	d3, x0
   536: 	mov	x0, x21
   540: 	lsr	x3, x0, #48
   544: 	mov	x10, #65521                     // =0xfff1
   548: 	cmp	x3, x10
   552: 	b.hi	#752
   556: 	mov	x10, #65521                     // =0xfff1
   560: 	cmp	x3, x10
   564: 	b.ne	#20
   568: 	lsl	x0, x0, #16
   572: 	asr	x0, x0, #16
   576: 	scvtf	d4, x0
   580: 	b	#8
   584: 	fmov	d4, x0
   588: 	cmp	x20, #1
   592: 	b.ls	#844
   596: 	sub	x20, x20, #1
   600: 	mov	x4, x6
   604: 	mov	x5, x7
   608: 	fmov	d0, d3
   612: 	fmov	d1, d4
   616: 	fcmp	d0, d1
   620: 	b.mi	#-240
   624: 	mov	x0, x4
   628: 	and	x0, x0, #0xffffffffffff
   632: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   636: 	orr	x0, x0, x10
   640: 	str	x0, [x19, #48]
   644: 	mov	x0, x5
   648: 	and	x0, x0, #0xffffffffffff
   652: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   656: 	orr	x0, x0, x10
   660: 	str	x0, [x19, #56]
   664: 	mov	x9, #192                        // =0xc0
   668: 	str	x9, [x19, #912]
   672: 	str	x20, [x19, #920]
   676: 	mov	x0, #20                         // =0x14
   680: 	ldp	x29, x30, [sp]
   684: 	ldp	x19, x20, [sp, #80]
   688: 	ldp	x21, x22, [sp, #64]
   692: 	ldp	x23, x24, [sp, #48]
   696: 	ldp	x25, x26, [sp, #32]
   700: 	ldr	x27, [sp, #24]
   704: 	add	sp, sp, #96
   708: 	ret
   712: 	mov	x9, #0                          // =0x0
   716: 	str	x9, [x19, #912]
   720: 	str	x20, [x19, #920]
   724: 	mov	x0, #13                         // =0xd
   728: 	ldp	x29, x30, [sp]
   732: 	ldp	x19, x20, [sp, #80]
   736: 	ldp	x21, x22, [sp, #64]
   740: 	ldp	x23, x24, [sp, #48]
   744: 	ldp	x25, x26, [sp, #32]
   748: 	ldr	x27, [sp, #24]
   752: 	add	sp, sp, #96
   756: 	ret
   760: 	mov	x0, x4
   764: 	and	x0, x0, #0xffffffffffff
   768: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   772: 	orr	x0, x0, x10
   776: 	str	x0, [x19, #48]
   780: 	mov	x0, x5
   784: 	and	x0, x0, #0xffffffffffff
   788: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   792: 	orr	x0, x0, x10
   796: 	str	x0, [x19, #56]
   800: 	mov	x0, x4
   804: 	and	x0, x0, #0xffffffffffff
   808: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   812: 	orr	x0, x0, x10
   816: 	str	x0, [x19, #128]
   820: 	mov	x9, #192                        // =0xc0
   824: 	movk	x9, #1, lsl #16
   828: 	str	x9, [x19, #912]
   832: 	str	x20, [x19, #920]
   836: 	mov	x0, #14                         // =0xe
   840: 	ldp	x29, x30, [sp]
   844: 	ldp	x19, x20, [sp, #80]
   848: 	ldp	x21, x22, [sp, #64]
   852: 	ldp	x23, x24, [sp, #48]
   856: 	ldp	x25, x26, [sp, #32]
   860: 	ldr	x27, [sp, #24]
   864: 	add	sp, sp, #96
   868: 	ret
   872: 	mov	x0, x4
   876: 	and	x0, x0, #0xffffffffffff
   880: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   884: 	orr	x0, x0, x10
   888: 	str	x0, [x19, #48]
   892: 	mov	x0, x5
   896: 	and	x0, x0, #0xffffffffffff
   900: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   904: 	orr	x0, x0, x10
   908: 	str	x0, [x19, #56]
   912: 	mov	x0, x4
   916: 	and	x0, x0, #0xffffffffffff
   920: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
   924: 	orr	x0, x0, x10
   928: 	str	x0, [x19, #128]
   932: 	fmov	d0, d2
   936: 	fmov	x0, d0
   940: 	lsr	x3, x0, #48
   944: 	mov	x10, #65521                     // =0xfff1
   948: 	cmp	x3, x10
   952: 	b.lo	#8
   956: 	orr	x0, xzr, #0x7ff8000000000000
   960: 	str	x0, [x19, #144]
   964: 	mov	x9, #192                        // =0xc0
   968: 	movk	x9, #5, lsl #16
   972: 	str	x9, [x19, #912]
   976: 	str	x20, [x19, #920]
   980: 	mov	x0, #15                         // =0xf
   984: 	ldp	x29, x30, [sp]
   988: 	ldp	x19, x20, [sp, #80]
   992: 	ldp	x21, x22, [sp, #64]
   996: 	ldp	x23, x24, [sp, #48]
  1000: 	ldp	x25, x26, [sp, #32]
  1004: 	ldr	x27, [sp, #24]
  1008: 	add	sp, sp, #96
  1012: 	ret
  1016: 	mov	x0, x4
  1020: 	and	x0, x0, #0xffffffffffff
  1024: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1028: 	orr	x0, x0, x10
  1032: 	str	x0, [x19, #48]
  1036: 	mov	x0, x5
  1040: 	and	x0, x0, #0xffffffffffff
  1044: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1048: 	orr	x0, x0, x10
  1052: 	str	x0, [x19, #56]
  1056: 	mov	x0, x4
  1060: 	and	x0, x0, #0xffffffffffff
  1064: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1068: 	orr	x0, x0, x10
  1072: 	str	x0, [x19, #128]
  1076: 	fmov	d0, d2
  1080: 	fmov	x0, d0
  1084: 	lsr	x3, x0, #48
  1088: 	mov	x10, #65521                     // =0xfff1
  1092: 	cmp	x3, x10
  1096: 	b.lo	#8
  1100: 	orr	x0, xzr, #0x7ff8000000000000
  1104: 	str	x0, [x19, #144]
  1108: 	mov	x9, #192                        // =0xc0
  1112: 	movk	x9, #5, lsl #16
  1116: 	str	x9, [x19, #912]
  1120: 	str	x20, [x19, #920]
  1124: 	mov	x0, #16                         // =0x10
  1128: 	ldp	x29, x30, [sp]
  1132: 	ldp	x19, x20, [sp, #80]
  1136: 	ldp	x21, x22, [sp, #64]
  1140: 	ldp	x23, x24, [sp, #48]
  1144: 	ldp	x25, x26, [sp, #32]
  1148: 	ldr	x27, [sp, #24]
  1152: 	add	sp, sp, #96
  1156: 	ret
  1160: 	mov	x0, x6
  1164: 	and	x0, x0, #0xffffffffffff
  1168: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1172: 	orr	x0, x0, x10
  1176: 	str	x0, [x19, #48]
  1180: 	mov	x0, x5
  1184: 	and	x0, x0, #0xffffffffffff
  1188: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1192: 	orr	x0, x0, x10
  1196: 	str	x0, [x19, #56]
  1200: 	mov	x0, x4
  1204: 	and	x0, x0, #0xffffffffffff
  1208: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1212: 	orr	x0, x0, x10
  1216: 	str	x0, [x19, #128]
  1220: 	fmov	d0, d2
  1224: 	fmov	x0, d0
  1228: 	lsr	x3, x0, #48
  1232: 	mov	x10, #65521                     // =0xfff1
  1236: 	cmp	x3, x10
  1240: 	b.lo	#8
  1244: 	orr	x0, xzr, #0x7ff8000000000000
  1248: 	str	x0, [x19, #144]
  1252: 	mov	x9, #192                        // =0xc0
  1256: 	movk	x9, #5, lsl #16
  1260: 	str	x9, [x19, #912]
  1264: 	str	x20, [x19, #920]
  1268: 	mov	x0, #17                         // =0x11
  1272: 	ldp	x29, x30, [sp]
  1276: 	ldp	x19, x20, [sp, #80]
  1280: 	ldp	x21, x22, [sp, #64]
  1284: 	ldp	x23, x24, [sp, #48]
  1288: 	ldp	x25, x26, [sp, #32]
  1292: 	ldr	x27, [sp, #24]
  1296: 	add	sp, sp, #96
  1300: 	ret
  1304: 	mov	x0, x6
  1308: 	and	x0, x0, #0xffffffffffff
  1312: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1316: 	orr	x0, x0, x10
  1320: 	str	x0, [x19, #48]
  1324: 	mov	x0, x7
  1328: 	and	x0, x0, #0xffffffffffff
  1332: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1336: 	orr	x0, x0, x10
  1340: 	str	x0, [x19, #56]
  1344: 	mov	x0, x21
  1348: 	str	x0, [x19, #128]
  1352: 	fmov	d0, d2
  1356: 	fmov	x0, d0
  1360: 	lsr	x3, x0, #48
  1364: 	mov	x10, #65521                     // =0xfff1
  1368: 	cmp	x3, x10
  1372: 	b.lo	#8
  1376: 	orr	x0, xzr, #0x7ff8000000000000
  1380: 	str	x0, [x19, #144]
  1384: 	mov	x9, #192                        // =0xc0
  1388: 	movk	x9, #5, lsl #16
  1392: 	str	x9, [x19, #912]
  1396: 	str	x20, [x19, #920]
  1400: 	mov	x0, #19                         // =0x13
  1404: 	ldp	x29, x30, [sp]
  1408: 	ldp	x19, x20, [sp, #80]
  1412: 	ldp	x21, x22, [sp, #64]
  1416: 	ldp	x23, x24, [sp, #48]
  1420: 	ldp	x25, x26, [sp, #32]
  1424: 	ldr	x27, [sp, #24]
  1428: 	add	sp, sp, #96
  1432: 	ret
  1436: 	mov	x0, x6
  1440: 	and	x0, x0, #0xffffffffffff
  1444: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1448: 	orr	x0, x0, x10
  1452: 	str	x0, [x19, #48]
  1456: 	mov	x0, x7
  1460: 	and	x0, x0, #0xffffffffffff
  1464: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  1468: 	orr	x0, x0, x10
  1472: 	str	x0, [x19, #56]
  1476: 	mov	x0, x21
  1480: 	str	x0, [x19, #128]
  1484: 	mov	x9, #192                        // =0xc0
  1488: 	movk	x9, #1, lsl #16
  1492: 	str	x9, [x19, #912]
  1496: 	str	x20, [x19, #920]
  1500: 	mov	x0, #19                         // =0x13
  1504: 	ldp	x29, x30, [sp]
  1508: 	ldp	x19, x20, [sp, #80]
  1512: 	ldp	x21, x22, [sp, #64]
  1516: 	ldp	x23, x24, [sp, #48]
  1520: 	ldp	x25, x26, [sp, #32]
  1524: 	ldr	x27, [sp, #24]
  1528: 	add	sp, sp, #96
  1532: 	ret
