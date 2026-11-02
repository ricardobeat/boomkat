     0: 	stp	x29, x30, [sp, #-96]!
     4: 	stp	x19, x20, [sp, #80]
     8: 	stp	x21, x22, [sp, #64]
    12: 	stp	x23, x24, [sp, #48]
    16: 	stp	x25, x26, [sp, #32]
    20: 	str	x27, [sp, #24]
    24: 	mov	x29, sp
    28: 	mov	x19, x0
    32: 	mov	x20, x1
    36: 	ldr	x0, [x19, #24]
    40: 	ldr	x10, [x19, #528]
    44: 	cmp	x0, x10
    48: 	b.ne	#2620
    52: 	ldr	x24, [x19, #544]
    56: 	ldr	x25, [x19, #536]
    60: 	ldr	x0, [x19, #32]
    64: 	ldr	x10, [x19, #560]
    68: 	cmp	x0, x10
    72: 	b.ne	#2596
    76: 	ldr	x26, [x19, #576]
    80: 	ldr	x27, [x19, #568]
    84: 	ldr	x0, [x19, #16]
    88: 	ldr	x10, [x19, #592]
    92: 	cmp	x0, x10
    96: 	b.ne	#2572
   100: 	ldr	x0, [x19, #8]
   104: 	ldr	x10, [x19, #624]
   108: 	cmp	x0, x10
   112: 	b.ne	#2556
   116: 	ldr	x0, [x19, #48]
   120: 	lsr	x3, x0, #48
   124: 	mov	x10, #65521                     // =0xfff1
   128: 	cmp	x3, x10
   132: 	b.hi	#2536
   136: 	mov	x10, #65521                     // =0xfff1
   140: 	cmp	x3, x10
   144: 	b.ne	#20
   148: 	lsl	x0, x0, #16
   152: 	asr	x0, x0, #16
   156: 	scvtf	d0, x0
   160: 	b	#8
   164: 	fmov	d0, x0
   168: 	fmov	d2, d0
   172: 	ldr	x0, [x19, #56]
   176: 	lsr	x3, x0, #48
   180: 	mov	x10, #65521                     // =0xfff1
   184: 	cmp	x3, x10
   188: 	b.hi	#2480
   192: 	mov	x10, #65521                     // =0xfff1
   196: 	cmp	x3, x10
   200: 	b.ne	#20
   204: 	lsl	x0, x0, #16
   208: 	asr	x0, x0, #16
   212: 	scvtf	d0, x0
   216: 	b	#8
   220: 	fmov	d0, x0
   224: 	fmov	d3, d0
   228: 	ldr	x0, [x19, #64]
   232: 	lsr	x3, x0, #48
   236: 	mov	x10, #65521                     // =0xfff1
   240: 	cmp	x3, x10
   244: 	b.eq	#104
   248: 	mov	x10, #65521                     // =0xfff1
   252: 	cmp	x3, x10
   256: 	b.hi	#2412
   260: 	fmov	d0, x0
   264: 	fcmp	d0, d0
   268: 	b.vs	#2400
   272: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   276: 	fmov	d1, x1
   280: 	fcmp	d0, d1
   284: 	b.mi	#2384
   288: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   292: 	fmov	d1, x1
   296: 	fcmp	d0, d1
   300: 	b.ge	#2368
   304: 	lsl	x3, x0, #1
   308: 	cbnz	x3, #12
   312: 	cmp	x0, #0
   316: 	b.lt	#2352
   320: 	fcvtzs	x0, d0
   324: 	scvtf	d1, x0
   328: 	fcmp	d0, d1
   332: 	cset	x9, ne
   336: 	ccmp	x9, #0, #4, vc
   340: 	b.ne	#2328
   344: 	b	#28
   348: 	sxtw	x3, w0
   352: 	lsl	x1, x0, #16
   356: 	asr	x1, x1, #16
   360: 	cmp	x1, x3
   364: 	b.ne	#2304
   368: 	mov	x0, x1
   372: 	mov	x6, x0
   376: 	ldr	x0, [x19, #72]
   380: 	lsr	x3, x0, #48
   384: 	mov	x10, #65521                     // =0xfff1
   388: 	cmp	x3, x10
   392: 	b.eq	#104
   396: 	mov	x10, #65521                     // =0xfff1
   400: 	cmp	x3, x10
   404: 	b.hi	#2264
   408: 	fmov	d0, x0
   412: 	fcmp	d0, d0
   416: 	b.vs	#2252
   420: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   424: 	fmov	d1, x1
   428: 	fcmp	d0, d1
   432: 	b.mi	#2236
   436: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   440: 	fmov	d1, x1
   444: 	fcmp	d0, d1
   448: 	b.ge	#2220
   452: 	lsl	x3, x0, #1
   456: 	cbnz	x3, #12
   460: 	cmp	x0, #0
   464: 	b.lt	#2204
   468: 	fcvtzs	x0, d0
   472: 	scvtf	d1, x0
   476: 	fcmp	d0, d1
   480: 	cset	x9, ne
   484: 	ccmp	x9, #0, #4, vc
   488: 	b.ne	#2180
   492: 	b	#28
   496: 	sxtw	x3, w0
   500: 	lsl	x1, x0, #16
   504: 	asr	x1, x1, #16
   508: 	cmp	x1, x3
   512: 	b.ne	#2156
   516: 	mov	x0, x1
   520: 	mov	x7, x0
   524: 	ldr	x0, [x19, #80]
   528: 	lsr	x3, x0, #48
   532: 	mov	x10, #65521                     // =0xfff1
   536: 	cmp	x3, x10
   540: 	b.hi	#2128
   544: 	mov	x10, #65521                     // =0xfff1
   548: 	cmp	x3, x10
   552: 	b.ne	#20
   556: 	lsl	x0, x0, #16
   560: 	asr	x0, x0, #16
   564: 	scvtf	d0, x0
   568: 	b	#8
   572: 	fmov	d0, x0
   576: 	fmov	d4, d0
   580: 	ldr	x0, [x19, #88]
   584: 	lsr	x3, x0, #48
   588: 	mov	x10, #65521                     // =0xfff1
   592: 	cmp	x3, x10
   596: 	b.eq	#104
   600: 	mov	x10, #65521                     // =0xfff1
   604: 	cmp	x3, x10
   608: 	b.hi	#2060
   612: 	fmov	d0, x0
   616: 	fcmp	d0, d0
   620: 	b.vs	#2048
   624: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   628: 	fmov	d1, x1
   632: 	fcmp	d0, d1
   636: 	b.mi	#2032
   640: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   644: 	fmov	d1, x1
   648: 	fcmp	d0, d1
   652: 	b.ge	#2016
   656: 	lsl	x3, x0, #1
   660: 	cbnz	x3, #12
   664: 	cmp	x0, #0
   668: 	b.lt	#2000
   672: 	fcvtzs	x0, d0
   676: 	scvtf	d1, x0
   680: 	fcmp	d0, d1
   684: 	cset	x9, ne
   688: 	ccmp	x9, #0, #4, vc
   692: 	b.ne	#1976
   696: 	b	#28
   700: 	sxtw	x3, w0
   704: 	lsl	x1, x0, #16
   708: 	asr	x1, x1, #16
   712: 	cmp	x1, x3
   716: 	b.ne	#1952
   720: 	mov	x0, x1
   724: 	mov	x4, x0
   728: 	ldr	x0, [x19, #96]
   732: 	lsr	x3, x0, #48
   736: 	mov	x10, #65521                     // =0xfff1
   740: 	cmp	x3, x10
   744: 	b.eq	#104
   748: 	mov	x10, #65521                     // =0xfff1
   752: 	cmp	x3, x10
   756: 	b.hi	#1912
   760: 	fmov	d0, x0
   764: 	fcmp	d0, d0
   768: 	b.vs	#1900
   772: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   776: 	fmov	d1, x1
   780: 	fcmp	d0, d1
   784: 	b.mi	#1884
   788: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   792: 	fmov	d1, x1
   796: 	fcmp	d0, d1
   800: 	b.ge	#1868
   804: 	lsl	x3, x0, #1
   808: 	cbnz	x3, #12
   812: 	cmp	x0, #0
   816: 	b.lt	#1852
   820: 	fcvtzs	x0, d0
   824: 	scvtf	d1, x0
   828: 	fcmp	d0, d1
   832: 	cset	x9, ne
   836: 	ccmp	x9, #0, #4, vc
   840: 	b.ne	#1828
   844: 	b	#28
   848: 	sxtw	x3, w0
   852: 	lsl	x1, x0, #16
   856: 	asr	x1, x1, #16
   860: 	cmp	x1, x3
   864: 	b.ne	#1804
   868: 	mov	x0, x1
   872: 	mov	x5, x0
   876: 	adds	w21, w4, #1
   880: 	b.vs	#1836
   884: 	sxtw	x21, w21
   888: 	mov	x1, x21
   892: 	cmp	x1, x24
   896: 	b.hs	#2044
   900: 	lsl	x1, x1, #3
   904: 	add	x2, x25, x1
   908: 	ldr	x0, [x2]
   912: 	lsr	x3, x0, #48
   916: 	mov	x10, #65521                     // =0xfff1
   920: 	cmp	x3, x10
   924: 	b.hs	#2016
   928: 	fmov	d5, x0
   932: 	fmul	d6, d2, d5
   936: 	mov	x0, x5
   940: 	scvtf	d7, x0
   944: 	fsub	d16, d7, d6
   948: 	mov	x1, x21
   952: 	cmp	x1, x26
   956: 	b.hs	#2208
   960: 	lsl	x1, x1, #3
   964: 	add	x2, x27, x1
   968: 	ldr	x0, [x2]
   972: 	lsr	x3, x0, #48
   976: 	mov	x10, #65521                     // =0xfff1
   980: 	cmp	x3, x10
   984: 	b.hs	#2180
   988: 	fmov	d7, x0
   992: 	fmul	d17, d3, d7
   996: 	fsub	d5, d4, d17
  1000: 	fmov	d0, d16
  1004: 	orr	x3, xzr, #0x3fe0000000000000
  1008: 	fmov	d1, x3
  1012: 	fcmp	d0, d1
  1016: 	b.pl	#8
  1020: 	b	#8
  1024: 	b	#20
  1028: 	orr	x3, xzr, #0x3fe0000000000000
  1032: 	fmov	d0, x3
  1036: 	fmov	d7, d0
  1040: 	b	#44
  1044: 	mov	x0, x6
  1048: 	scvtf	d6, x0
  1052: 	fmov	d0, d16
  1056: 	fmov	d1, d6
  1060: 	fcmp	d0, d1
  1064: 	b.le	#8
  1068: 	b	#12
  1072: 	fmov	d7, d16
  1076: 	b	#8
  1080: 	scvtf	d7, x6
  1084: 	fmov	d0, d7
  1088: 	fcmp	d0, d0
  1092: 	b.vs	#2396
  1096: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1100: 	fmov	d1, x1
  1104: 	fcmp	d0, d1
  1108: 	b.mi	#2380
  1112: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1116: 	fmov	d1, x1
  1120: 	fcmp	d0, d1
  1124: 	b.ge	#2364
  1128: 	fcvtzs	x22, d0
  1132: 	sxtw	x22, w22
  1136: 	orr	x23, x22, xzr
  1140: 	sxtw	x23, w23
  1144: 	adds	w22, w23, #1
  1148: 	b.vs	#2700
  1152: 	sxtw	x22, w22
  1156: 	fmov	d0, d5
  1160: 	orr	x3, xzr, #0x3fe0000000000000
  1164: 	fmov	d1, x3
  1168: 	fcmp	d0, d1
  1172: 	b.pl	#8
  1176: 	b	#8
  1180: 	b	#20
  1184: 	orr	x3, xzr, #0x3fe0000000000000
  1188: 	fmov	d0, x3
  1192: 	fmov	d16, d0
  1196: 	b	#44
  1200: 	mov	x0, x7
  1204: 	scvtf	d6, x0
  1208: 	fmov	d0, d5
  1212: 	fmov	d1, d6
  1216: 	fcmp	d0, d1
  1220: 	b.le	#8
  1224: 	b	#12
  1228: 	fmov	d16, d5
  1232: 	b	#8
  1236: 	scvtf	d16, x7
  1240: 	fmov	d0, d16
  1244: 	fcmp	d0, d0
  1248: 	b.vs	#2980
  1252: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1256: 	fmov	d1, x1
  1260: 	fcmp	d0, d1
  1264: 	b.mi	#2964
  1268: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1272: 	fmov	d1, x1
  1276: 	fcmp	d0, d1
  1280: 	b.ge	#2948
  1284: 	fcvtzs	x0, d0
  1288: 	sxtw	x0, w0
  1292: 	str	x0, [x19, #928]
  1296: 	ldr	x0, [x19, #928]
  1300: 	orr	x0, x0, xzr
  1304: 	sxtw	x0, w0
  1308: 	str	x0, [x19, #936]
  1312: 	ldr	x0, [x19, #936]
  1316: 	adds	w0, w0, #1
  1320: 	b.vs	#3308
  1324: 	sxtw	x0, w0
  1328: 	str	x0, [x19, #944]
  1332: 	mov	x0, x23
  1336: 	scvtf	d5, x0
  1340: 	fsub	d6, d7, d5
  1344: 	mov	x0, #1                          // =0x1
  1348: 	scvtf	d0, x0
  1352: 	str	d0, [x19, #952]
  1356: 	ldr	d0, [x19, #952]
  1360: 	fsub	d0, d0, d6
  1364: 	str	d0, [x19, #960]
  1368: 	ldr	x0, [x19, #936]
  1372: 	scvtf	d0, x0
  1376: 	str	d0, [x19, #968]
  1380: 	ldr	d1, [x19, #968]
  1384: 	fsub	d0, d16, d1
  1388: 	str	d0, [x19, #976]
  1392: 	mov	x0, #1                          // =0x1
  1396: 	scvtf	d0, x0
  1400: 	str	d0, [x19, #984]
  1404: 	ldr	d0, [x19, #984]
  1408: 	ldr	d1, [x19, #976]
  1412: 	fsub	d0, d0, d1
  1416: 	str	d0, [x19, #992]
  1420: 	ldr	x0, [x19, #784]
  1424: 	str	x0, [x19, #1000]
  1428: 	ldr	x0, [x19, #1000]
  1432: 	lsr	x3, x0, #48
  1436: 	mov	x10, #65521                     // =0xfff1
  1440: 	cmp	x3, x10
  1444: 	b.hi	#3604
  1448: 	mov	x10, #65521                     // =0xfff1
  1452: 	cmp	x3, x10
  1456: 	b.ne	#20
  1460: 	lsl	x0, x0, #16
  1464: 	asr	x0, x0, #16
  1468: 	scvtf	d0, x0
  1472: 	b	#8
  1476: 	fmov	d0, x0
  1480: 	str	d0, [x19, #1008]
  1484: 	ldr	d0, [x19, #968]
  1488: 	ldr	d1, [x19, #1008]
  1492: 	fmul	d0, d0, d1
  1496: 	str	d0, [x19, #1016]
  1500: 	ldr	x0, [x19, #944]
  1504: 	scvtf	d0, x0
  1508: 	str	d0, [x19, #1024]
  1512: 	ldr	x0, [x19, #1000]
  1516: 	lsr	x3, x0, #48
  1520: 	mov	x10, #65521                     // =0xfff1
  1524: 	cmp	x3, x10
  1528: 	b.hi	#4060
  1532: 	mov	x10, #65521                     // =0xfff1
  1536: 	cmp	x3, x10
  1540: 	b.ne	#20
  1544: 	lsl	x0, x0, #16
  1548: 	asr	x0, x0, #16
  1552: 	scvtf	d0, x0
  1556: 	b	#8
  1560: 	fmov	d0, x0
  1564: 	str	d0, [x19, #1032]
  1568: 	ldr	d0, [x19, #1024]
  1572: 	ldr	d1, [x19, #1032]
  1576: 	fmul	d0, d0, d1
  1580: 	str	d0, [x19, #1040]
  1584: 	ldr	d1, [x19, #1016]
  1588: 	fadd	d0, d5, d1
  1592: 	str	d0, [x19, #1048]
  1596: 	ldr	d0, [x19, #1048]
  1600: 	fcmp	d0, d0
  1604: 	b.vs	#4556
  1608: 	fmov	x1, d0
  1612: 	orr	x10, xzr, #0x8000000000000000
  1616: 	cmp	x1, x10
  1620: 	b.eq	#4540
  1624: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1628: 	fmov	d1, x1
  1632: 	fcmp	d0, d1
  1636: 	b.mi	#4524
  1640: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1644: 	fmov	d1, x1
  1648: 	fcmp	d0, d1
  1652: 	b.ge	#4508
  1656: 	fcvtzs	x0, d0
  1660: 	scvtf	d1, x0
  1664: 	fcmp	d0, d1
  1668: 	b.eq	#8
  1672: 	b	#4488
  1676: 	sxtw	x0, w0
  1680: 	str	x0, [x19, #1056]
  1684: 	ldr	x1, [x19, #1056]
  1688: 	ldr	x10, [x19, #608]
  1692: 	cmp	x1, x10
  1696: 	b.hs	#4464
  1700: 	lsl	x1, x1, #3
  1704: 	ldr	x2, [x19, #600]
  1708: 	add	x2, x2, x1
  1712: 	ldr	x0, [x2]
  1716: 	lsr	x3, x0, #48
  1720: 	mov	x10, #65521                     // =0xfff1
  1724: 	cmp	x3, x10
  1728: 	b.hs	#4432
  1732: 	fmov	d0, x0
  1736: 	str	d0, [x19, #1064]
  1740: 	ldr	d0, [x19, #992]
  1744: 	ldr	d1, [x19, #1064]
  1748: 	fmul	d0, d0, d1
  1752: 	str	d0, [x19, #1072]
  1756: 	ldr	d1, [x19, #1040]
  1760: 	fadd	d0, d5, d1
  1764: 	str	d0, [x19, #1080]
  1768: 	ldr	d0, [x19, #1080]
  1772: 	fcmp	d0, d0
  1776: 	b.vs	#5028
  1780: 	fmov	x1, d0
  1784: 	orr	x10, xzr, #0x8000000000000000
  1788: 	cmp	x1, x10
  1792: 	b.eq	#5012
  1796: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1800: 	fmov	d1, x1
  1804: 	fcmp	d0, d1
  1808: 	b.mi	#4996
  1812: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1816: 	fmov	d1, x1
  1820: 	fcmp	d0, d1
  1824: 	b.ge	#4980
  1828: 	fcvtzs	x0, d0
  1832: 	scvtf	d1, x0
  1836: 	fcmp	d0, d1
  1840: 	b.eq	#8
  1844: 	b	#4960
  1848: 	sxtw	x0, w0
  1852: 	str	x0, [x19, #1088]
  1856: 	ldr	x1, [x19, #1088]
  1860: 	ldr	x10, [x19, #608]
  1864: 	cmp	x1, x10
  1868: 	b.hs	#4936
  1872: 	lsl	x1, x1, #3
  1876: 	ldr	x2, [x19, #600]
  1880: 	add	x2, x2, x1
  1884: 	ldr	x0, [x2]
  1888: 	lsr	x3, x0, #48
  1892: 	mov	x10, #65521                     // =0xfff1
  1896: 	cmp	x3, x10
  1900: 	b.hs	#4904
  1904: 	fmov	d5, x0
  1908: 	ldr	d0, [x19, #976]
  1912: 	fmul	d0, d0, d5
  1916: 	str	d0, [x19, #1096]
  1920: 	ldr	d0, [x19, #1072]
  1924: 	ldr	d1, [x19, #1096]
  1928: 	fadd	d0, d0, d1
  1932: 	str	d0, [x19, #1104]
  1936: 	ldr	d0, [x19, #960]
  1940: 	ldr	d1, [x19, #1104]
  1944: 	fmul	d0, d0, d1
  1948: 	str	d0, [x19, #1112]
  1952: 	mov	x0, x22
  1956: 	scvtf	d0, x0
  1960: 	str	d0, [x19, #1120]
  1964: 	ldr	d0, [x19, #1120]
  1968: 	ldr	d1, [x19, #1016]
  1972: 	fadd	d0, d0, d1
  1976: 	str	d0, [x19, #1128]
  1980: 	ldr	d0, [x19, #1128]
  1984: 	fcmp	d0, d0
  1988: 	b.vs	#5556
  1992: 	fmov	x1, d0
  1996: 	orr	x10, xzr, #0x8000000000000000
  2000: 	cmp	x1, x10
  2004: 	b.eq	#5540
  2008: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  2012: 	fmov	d1, x1
  2016: 	fcmp	d0, d1
  2020: 	b.mi	#5524
  2024: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  2028: 	fmov	d1, x1
  2032: 	fcmp	d0, d1
  2036: 	b.ge	#5508
  2040: 	fcvtzs	x0, d0
  2044: 	scvtf	d1, x0
  2048: 	fcmp	d0, d1
  2052: 	b.eq	#8
  2056: 	b	#5488
  2060: 	sxtw	x0, w0
  2064: 	str	x0, [x19, #1136]
  2068: 	ldr	x1, [x19, #1136]
  2072: 	ldr	x10, [x19, #608]
  2076: 	cmp	x1, x10
  2080: 	b.hs	#5464
  2084: 	lsl	x1, x1, #3
  2088: 	ldr	x2, [x19, #600]
  2092: 	add	x2, x2, x1
  2096: 	ldr	x0, [x2]
  2100: 	lsr	x3, x0, #48
  2104: 	mov	x10, #65521                     // =0xfff1
  2108: 	cmp	x3, x10
  2112: 	b.hs	#5432
  2116: 	fmov	d0, x0
  2120: 	str	d0, [x19, #1144]
  2124: 	ldr	d0, [x19, #992]
  2128: 	ldr	d1, [x19, #1144]
  2132: 	fmul	d0, d0, d1
  2136: 	str	d0, [x19, #1152]
  2140: 	ldr	d0, [x19, #1120]
  2144: 	ldr	d1, [x19, #1040]
  2148: 	fadd	d0, d0, d1
  2152: 	str	d0, [x19, #1160]
  2156: 	ldr	d0, [x19, #1160]
  2160: 	fcmp	d0, d0
  2164: 	b.vs	#6216
  2168: 	fmov	x1, d0
  2172: 	orr	x10, xzr, #0x8000000000000000
  2176: 	cmp	x1, x10
  2180: 	b.eq	#6200
  2184: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  2188: 	fmov	d1, x1
  2192: 	fcmp	d0, d1
  2196: 	b.mi	#6184
  2200: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  2204: 	fmov	d1, x1
  2208: 	fcmp	d0, d1
  2212: 	b.ge	#6168
  2216: 	fcvtzs	x0, d0
  2220: 	scvtf	d1, x0
  2224: 	fcmp	d0, d1
  2228: 	b.eq	#8
  2232: 	b	#6148
  2236: 	sxtw	x0, w0
  2240: 	str	x0, [x19, #1168]
  2244: 	ldr	x1, [x19, #1168]
  2248: 	ldr	x10, [x19, #608]
  2252: 	cmp	x1, x10
  2256: 	b.hs	#6124
  2260: 	lsl	x1, x1, #3
  2264: 	ldr	x2, [x19, #600]
  2268: 	add	x2, x2, x1
  2272: 	ldr	x0, [x2]
  2276: 	lsr	x3, x0, #48
  2280: 	mov	x10, #65521                     // =0xfff1
  2284: 	cmp	x3, x10
  2288: 	b.hs	#6092
  2292: 	fmov	d0, x0
  2296: 	str	d0, [x19, #1176]
  2300: 	ldr	d0, [x19, #976]
  2304: 	ldr	d1, [x19, #1176]
  2308: 	fmul	d0, d0, d1
  2312: 	str	d0, [x19, #1184]
  2316: 	ldr	d0, [x19, #1152]
  2320: 	ldr	d1, [x19, #1184]
  2324: 	fadd	d0, d0, d1
  2328: 	str	d0, [x19, #1192]
  2332: 	ldr	d1, [x19, #1192]
  2336: 	fmul	d0, d6, d1
  2340: 	str	d0, [x19, #1200]
  2344: 	ldr	d0, [x19, #1112]
  2348: 	ldr	d1, [x19, #1200]
  2352: 	fadd	d0, d0, d1
  2356: 	str	d0, [x19, #1208]
  2360: 	ldr	d0, [x19, #1208]
  2364: 	fmov	x0, d0
  2368: 	lsr	x3, x0, #48
  2372: 	mov	x10, #65521                     // =0xfff1
  2376: 	cmp	x3, x10
  2380: 	b.lo	#8
  2384: 	orr	x0, xzr, #0x7ff8000000000000
  2388: 	str	x0, [x19, #1216]
  2392: 	mov	x1, x21
  2396: 	ldr	x10, [x19, #640]
  2400: 	cmp	x1, x10
  2404: 	b.hs	#6908
  2408: 	lsl	x1, x1, #3
  2412: 	ldr	x2, [x19, #632]
  2416: 	add	x2, x2, x1
  2420: 	ldr	x0, [x2]
  2424: 	lsr	x3, x0, #48
  2428: 	mov	x10, #65521                     // =0xfff1
  2432: 	cmp	x3, x10
  2436: 	b.hi	#6876
  2440: 	ldr	x0, [x19, #1216]
  2444: 	str	x0, [x2]
  2448: 	adds	w0, w5, #1
  2452: 	b.vs	#7856
  2456: 	sxtw	x0, w0
  2460: 	str	x0, [x19, #1224]
  2464: 	ldr	x0, [x19, #792]
  2468: 	str	x0, [x19, #1232]
  2472: 	ldr	x0, [x19, #1224]
  2476: 	scvtf	d0, x0
  2480: 	str	d0, [x19, #1240]
  2484: 	ldr	x0, [x19, #1232]
  2488: 	lsr	x3, x0, #48
  2492: 	mov	x10, #65521                     // =0xfff1
  2496: 	cmp	x3, x10
  2500: 	b.hi	#8804
  2504: 	mov	x10, #65521                     // =0xfff1
  2508: 	cmp	x3, x10
  2512: 	b.ne	#20
  2516: 	lsl	x0, x0, #16
  2520: 	asr	x0, x0, #16
  2524: 	scvtf	d0, x0
  2528: 	b	#8
  2532: 	fmov	d0, x0
  2536: 	str	d0, [x19, #1248]
  2540: 	cmp	x20, #1
  2544: 	b.ls	#9744
  2548: 	sub	x20, x20, #1
  2552: 	mov	x4, x21
  2556: 	ldr	x0, [x19, #1224]
  2560: 	mov	x5, x0
  2564: 	ldr	d0, [x19, #1240]
  2568: 	ldr	d1, [x19, #1248]
  2572: 	fcmp	d0, d1
  2576: 	b.ls	#-1700
  2580: 	mov	x0, x4
  2584: 	and	x0, x0, #0xffffffffffff
  2588: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2592: 	orr	x0, x0, x10
  2596: 	str	x0, [x19, #88]
  2600: 	mov	x0, x5
  2604: 	and	x0, x0, #0xffffffffffff
  2608: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2612: 	orr	x0, x0, x10
  2616: 	str	x0, [x19, #96]
  2620: 	mov	x9, #6144                       // =0x1800
  2624: 	str	x9, [x19, #912]
  2628: 	str	x20, [x19, #920]
  2632: 	mov	x0, #71                         // =0x47
  2636: 	ldp	x29, x30, [sp]
  2640: 	ldp	x19, x20, [sp, #80]
  2644: 	ldp	x21, x22, [sp, #64]
  2648: 	ldp	x23, x24, [sp, #48]
  2652: 	ldp	x25, x26, [sp, #32]
  2656: 	ldr	x27, [sp, #24]
  2660: 	add	sp, sp, #96
  2664: 	ret
  2668: 	mov	x9, #0                          // =0x0
  2672: 	str	x9, [x19, #912]
  2676: 	str	x20, [x19, #920]
  2680: 	mov	x0, #16                         // =0x10
  2684: 	ldp	x29, x30, [sp]
  2688: 	ldp	x19, x20, [sp, #80]
  2692: 	ldp	x21, x22, [sp, #64]
  2696: 	ldp	x23, x24, [sp, #48]
  2700: 	ldp	x25, x26, [sp, #32]
  2704: 	ldr	x27, [sp, #24]
  2708: 	add	sp, sp, #96
  2712: 	ret
  2716: 	fmov	d0, d2
  2720: 	fmov	x0, d0
  2724: 	lsr	x3, x0, #48
  2728: 	mov	x10, #65521                     // =0xfff1
  2732: 	cmp	x3, x10
  2736: 	b.lo	#8
  2740: 	orr	x0, xzr, #0x7ff8000000000000
  2744: 	str	x0, [x19, #48]
  2748: 	fmov	d0, d3
  2752: 	fmov	x0, d0
  2756: 	lsr	x3, x0, #48
  2760: 	mov	x10, #65521                     // =0xfff1
  2764: 	cmp	x3, x10
  2768: 	b.lo	#8
  2772: 	orr	x0, xzr, #0x7ff8000000000000
  2776: 	str	x0, [x19, #56]
  2780: 	mov	x0, x6
  2784: 	and	x0, x0, #0xffffffffffff
  2788: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2792: 	orr	x0, x0, x10
  2796: 	str	x0, [x19, #64]
  2800: 	mov	x0, x7
  2804: 	and	x0, x0, #0xffffffffffff
  2808: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2812: 	orr	x0, x0, x10
  2816: 	str	x0, [x19, #72]
  2820: 	fmov	d0, d4
  2824: 	fmov	x0, d0
  2828: 	lsr	x3, x0, #48
  2832: 	mov	x10, #65521                     // =0xfff1
  2836: 	cmp	x3, x10
  2840: 	b.lo	#8
  2844: 	orr	x0, xzr, #0x7ff8000000000000
  2848: 	str	x0, [x19, #80]
  2852: 	mov	x0, x4
  2856: 	and	x0, x0, #0xffffffffffff
  2860: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2864: 	orr	x0, x0, x10
  2868: 	str	x0, [x19, #88]
  2872: 	mov	x0, x5
  2876: 	and	x0, x0, #0xffffffffffff
  2880: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2884: 	orr	x0, x0, x10
  2888: 	str	x0, [x19, #96]
  2892: 	mov	x9, #8128                       // =0x1fc0
  2896: 	str	x9, [x19, #912]
  2900: 	str	x20, [x19, #920]
  2904: 	mov	x0, #16                         // =0x10
  2908: 	ldp	x29, x30, [sp]
  2912: 	ldp	x19, x20, [sp, #80]
  2916: 	ldp	x21, x22, [sp, #64]
  2920: 	ldp	x23, x24, [sp, #48]
  2924: 	ldp	x25, x26, [sp, #32]
  2928: 	ldr	x27, [sp, #24]
  2932: 	add	sp, sp, #96
  2936: 	ret
  2940: 	fmov	d0, d2
  2944: 	fmov	x0, d0
  2948: 	lsr	x3, x0, #48
  2952: 	mov	x10, #65521                     // =0xfff1
  2956: 	cmp	x3, x10
  2960: 	b.lo	#8
  2964: 	orr	x0, xzr, #0x7ff8000000000000
  2968: 	str	x0, [x19, #48]
  2972: 	fmov	d0, d3
  2976: 	fmov	x0, d0
  2980: 	lsr	x3, x0, #48
  2984: 	mov	x10, #65521                     // =0xfff1
  2988: 	cmp	x3, x10
  2992: 	b.lo	#8
  2996: 	orr	x0, xzr, #0x7ff8000000000000
  3000: 	str	x0, [x19, #56]
  3004: 	mov	x0, x6
  3008: 	and	x0, x0, #0xffffffffffff
  3012: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3016: 	orr	x0, x0, x10
  3020: 	str	x0, [x19, #64]
  3024: 	mov	x0, x7
  3028: 	and	x0, x0, #0xffffffffffff
  3032: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3036: 	orr	x0, x0, x10
  3040: 	str	x0, [x19, #72]
  3044: 	fmov	d0, d4
  3048: 	fmov	x0, d0
  3052: 	lsr	x3, x0, #48
  3056: 	mov	x10, #65521                     // =0xfff1
  3060: 	cmp	x3, x10
  3064: 	b.lo	#8
  3068: 	orr	x0, xzr, #0x7ff8000000000000
  3072: 	str	x0, [x19, #80]
  3076: 	mov	x0, x21
  3080: 	and	x0, x0, #0xffffffffffff
  3084: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3088: 	orr	x0, x0, x10
  3092: 	str	x0, [x19, #88]
  3096: 	mov	x0, x5
  3100: 	and	x0, x0, #0xffffffffffff
  3104: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3108: 	orr	x0, x0, x10
  3112: 	str	x0, [x19, #96]
  3116: 	mov	x9, #8128                       // =0x1fc0
  3120: 	str	x9, [x19, #912]
  3124: 	str	x20, [x19, #920]
  3128: 	mov	x0, #17                         // =0x11
  3132: 	ldp	x29, x30, [sp]
  3136: 	ldp	x19, x20, [sp, #80]
  3140: 	ldp	x21, x22, [sp, #64]
  3144: 	ldp	x23, x24, [sp, #48]
  3148: 	ldp	x25, x26, [sp, #32]
  3152: 	ldr	x27, [sp, #24]
  3156: 	add	sp, sp, #96
  3160: 	ret
  3164: 	fmov	d0, d2
  3168: 	fmov	x0, d0
  3172: 	lsr	x3, x0, #48
  3176: 	mov	x10, #65521                     // =0xfff1
  3180: 	cmp	x3, x10
  3184: 	b.lo	#8
  3188: 	orr	x0, xzr, #0x7ff8000000000000
  3192: 	str	x0, [x19, #48]
  3196: 	fmov	d0, d3
  3200: 	fmov	x0, d0
  3204: 	lsr	x3, x0, #48
  3208: 	mov	x10, #65521                     // =0xfff1
  3212: 	cmp	x3, x10
  3216: 	b.lo	#8
  3220: 	orr	x0, xzr, #0x7ff8000000000000
  3224: 	str	x0, [x19, #56]
  3228: 	mov	x0, x6
  3232: 	and	x0, x0, #0xffffffffffff
  3236: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3240: 	orr	x0, x0, x10
  3244: 	str	x0, [x19, #64]
  3248: 	mov	x0, x7
  3252: 	and	x0, x0, #0xffffffffffff
  3256: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3260: 	orr	x0, x0, x10
  3264: 	str	x0, [x19, #72]
  3268: 	fmov	d0, d4
  3272: 	fmov	x0, d0
  3276: 	lsr	x3, x0, #48
  3280: 	mov	x10, #65521                     // =0xfff1
  3284: 	cmp	x3, x10
  3288: 	b.lo	#8
  3292: 	orr	x0, xzr, #0x7ff8000000000000
  3296: 	str	x0, [x19, #80]
  3300: 	mov	x0, x21
  3304: 	and	x0, x0, #0xffffffffffff
  3308: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3312: 	orr	x0, x0, x10
  3316: 	str	x0, [x19, #88]
  3320: 	mov	x0, x5
  3324: 	and	x0, x0, #0xffffffffffff
  3328: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3332: 	orr	x0, x0, x10
  3336: 	str	x0, [x19, #96]
  3340: 	fmov	d0, d16
  3344: 	fmov	x0, d0
  3348: 	lsr	x3, x0, #48
  3352: 	mov	x10, #65521                     // =0xfff1
  3356: 	cmp	x3, x10
  3360: 	b.lo	#8
  3364: 	orr	x0, xzr, #0x7ff8000000000000
  3368: 	str	x0, [x19, #104]
  3372: 	fmov	d0, d5
  3376: 	fmov	x0, d0
  3380: 	lsr	x3, x0, #48
  3384: 	mov	x10, #65521                     // =0xfff1
  3388: 	cmp	x3, x10
  3392: 	b.lo	#8
  3396: 	orr	x0, xzr, #0x7ff8000000000000
  3400: 	str	x0, [x19, #200]
  3404: 	fmov	d0, d6
  3408: 	fmov	x0, d0
  3412: 	lsr	x3, x0, #48
  3416: 	mov	x10, #65521                     // =0xfff1
  3420: 	cmp	x3, x10
  3424: 	b.lo	#8
  3428: 	orr	x0, xzr, #0x7ff8000000000000
  3432: 	str	x0, [x19, #208]
  3436: 	mov	x9, #16320                      // =0x3fc0
  3440: 	movk	x9, #1536, lsl #16
  3444: 	str	x9, [x19, #912]
  3448: 	str	x20, [x19, #920]
  3452: 	mov	x0, #20                         // =0x14
  3456: 	ldp	x29, x30, [sp]
  3460: 	ldp	x19, x20, [sp, #80]
  3464: 	ldp	x21, x22, [sp, #64]
  3468: 	ldp	x23, x24, [sp, #48]
  3472: 	ldp	x25, x26, [sp, #32]
  3476: 	ldr	x27, [sp, #24]
  3480: 	add	sp, sp, #96
  3484: 	ret
  3488: 	fmov	d0, d2
  3492: 	fmov	x0, d0
  3496: 	lsr	x3, x0, #48
  3500: 	mov	x10, #65521                     // =0xfff1
  3504: 	cmp	x3, x10
  3508: 	b.lo	#8
  3512: 	orr	x0, xzr, #0x7ff8000000000000
  3516: 	str	x0, [x19, #48]
  3520: 	fmov	d0, d3
  3524: 	fmov	x0, d0
  3528: 	lsr	x3, x0, #48
  3532: 	mov	x10, #65521                     // =0xfff1
  3536: 	cmp	x3, x10
  3540: 	b.lo	#8
  3544: 	orr	x0, xzr, #0x7ff8000000000000
  3548: 	str	x0, [x19, #56]
  3552: 	mov	x0, x6
  3556: 	and	x0, x0, #0xffffffffffff
  3560: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3564: 	orr	x0, x0, x10
  3568: 	str	x0, [x19, #64]
  3572: 	mov	x0, x7
  3576: 	and	x0, x0, #0xffffffffffff
  3580: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3584: 	orr	x0, x0, x10
  3588: 	str	x0, [x19, #72]
  3592: 	fmov	d0, d4
  3596: 	fmov	x0, d0
  3600: 	lsr	x3, x0, #48
  3604: 	mov	x10, #65521                     // =0xfff1
  3608: 	cmp	x3, x10
  3612: 	b.lo	#8
  3616: 	orr	x0, xzr, #0x7ff8000000000000
  3620: 	str	x0, [x19, #80]
  3624: 	mov	x0, x21
  3628: 	and	x0, x0, #0xffffffffffff
  3632: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3636: 	orr	x0, x0, x10
  3640: 	str	x0, [x19, #88]
  3644: 	mov	x0, x5
  3648: 	and	x0, x0, #0xffffffffffff
  3652: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3656: 	orr	x0, x0, x10
  3660: 	str	x0, [x19, #96]
  3664: 	fmov	d0, d7
  3668: 	fmov	x0, d0
  3672: 	lsr	x3, x0, #48
  3676: 	mov	x10, #65521                     // =0xfff1
  3680: 	cmp	x3, x10
  3684: 	b.lo	#8
  3688: 	orr	x0, xzr, #0x7ff8000000000000
  3692: 	str	x0, [x19, #104]
  3696: 	fmov	d0, d5
  3700: 	fmov	x0, d0
  3704: 	lsr	x3, x0, #48
  3708: 	mov	x10, #65521                     // =0xfff1
  3712: 	cmp	x3, x10
  3716: 	b.lo	#8
  3720: 	orr	x0, xzr, #0x7ff8000000000000
  3724: 	str	x0, [x19, #112]
  3728: 	orr	x3, xzr, #0x3fe0000000000000
  3732: 	fmov	d0, x3
  3736: 	fmov	x0, d0
  3740: 	lsr	x3, x0, #48
  3744: 	mov	x10, #65521                     // =0xfff1
  3748: 	cmp	x3, x10
  3752: 	b.lo	#8
  3756: 	orr	x0, xzr, #0x7ff8000000000000
  3760: 	str	x0, [x19, #200]
  3764: 	fmov	d0, d17
  3768: 	fmov	x0, d0
  3772: 	lsr	x3, x0, #48
  3776: 	mov	x10, #65521                     // =0xfff1
  3780: 	cmp	x3, x10
  3784: 	b.lo	#8
  3788: 	orr	x0, xzr, #0x7ff8000000000000
  3792: 	str	x0, [x19, #208]
  3796: 	mov	x9, #32704                      // =0x7fc0
  3800: 	movk	x9, #1536, lsl #16
  3804: 	str	x9, [x19, #912]
  3808: 	str	x20, [x19, #920]
  3812: 	mov	x0, #29                         // =0x1d
  3816: 	ldp	x29, x30, [sp]
  3820: 	ldp	x19, x20, [sp, #80]
  3824: 	ldp	x21, x22, [sp, #64]
  3828: 	ldp	x23, x24, [sp, #48]
  3832: 	ldp	x25, x26, [sp, #32]
  3836: 	ldr	x27, [sp, #24]
  3840: 	add	sp, sp, #96
  3844: 	ret
  3848: 	fmov	d0, d2
  3852: 	fmov	x0, d0
  3856: 	lsr	x3, x0, #48
  3860: 	mov	x10, #65521                     // =0xfff1
  3864: 	cmp	x3, x10
  3868: 	b.lo	#8
  3872: 	orr	x0, xzr, #0x7ff8000000000000
  3876: 	str	x0, [x19, #48]
  3880: 	fmov	d0, d3
  3884: 	fmov	x0, d0
  3888: 	lsr	x3, x0, #48
  3892: 	mov	x10, #65521                     // =0xfff1
  3896: 	cmp	x3, x10
  3900: 	b.lo	#8
  3904: 	orr	x0, xzr, #0x7ff8000000000000
  3908: 	str	x0, [x19, #56]
  3912: 	mov	x0, x6
  3916: 	and	x0, x0, #0xffffffffffff
  3920: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3924: 	orr	x0, x0, x10
  3928: 	str	x0, [x19, #64]
  3932: 	mov	x0, x7
  3936: 	and	x0, x0, #0xffffffffffff
  3940: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3944: 	orr	x0, x0, x10
  3948: 	str	x0, [x19, #72]
  3952: 	fmov	d0, d4
  3956: 	fmov	x0, d0
  3960: 	lsr	x3, x0, #48
  3964: 	mov	x10, #65521                     // =0xfff1
  3968: 	cmp	x3, x10
  3972: 	b.lo	#8
  3976: 	orr	x0, xzr, #0x7ff8000000000000
  3980: 	str	x0, [x19, #80]
  3984: 	mov	x0, x21
  3988: 	and	x0, x0, #0xffffffffffff
  3992: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3996: 	orr	x0, x0, x10
  4000: 	str	x0, [x19, #88]
  4004: 	mov	x0, x5
  4008: 	and	x0, x0, #0xffffffffffff
  4012: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4016: 	orr	x0, x0, x10
  4020: 	str	x0, [x19, #96]
  4024: 	fmov	d0, d7
  4028: 	fmov	x0, d0
  4032: 	lsr	x3, x0, #48
  4036: 	mov	x10, #65521                     // =0xfff1
  4040: 	cmp	x3, x10
  4044: 	b.lo	#8
  4048: 	orr	x0, xzr, #0x7ff8000000000000
  4052: 	str	x0, [x19, #104]
  4056: 	fmov	d0, d5
  4060: 	fmov	x0, d0
  4064: 	lsr	x3, x0, #48
  4068: 	mov	x10, #65521                     // =0xfff1
  4072: 	cmp	x3, x10
  4076: 	b.lo	#8
  4080: 	orr	x0, xzr, #0x7ff8000000000000
  4084: 	str	x0, [x19, #112]
  4088: 	mov	x0, x23
  4092: 	and	x0, x0, #0xffffffffffff
  4096: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4100: 	orr	x0, x0, x10
  4104: 	str	x0, [x19, #120]
  4108: 	orr	x3, xzr, #0x3fe0000000000000
  4112: 	fmov	d0, x3
  4116: 	fmov	x0, d0
  4120: 	lsr	x3, x0, #48
  4124: 	mov	x10, #65521                     // =0xfff1
  4128: 	cmp	x3, x10
  4132: 	b.lo	#8
  4136: 	orr	x0, xzr, #0x7ff8000000000000
  4140: 	str	x0, [x19, #200]
  4144: 	fmov	d0, d17
  4148: 	fmov	x0, d0
  4152: 	lsr	x3, x0, #48
  4156: 	mov	x10, #65521                     // =0xfff1
  4160: 	cmp	x3, x10
  4164: 	b.lo	#8
  4168: 	orr	x0, xzr, #0x7ff8000000000000
  4172: 	str	x0, [x19, #208]
  4176: 	mov	x9, #65472                      // =0xffc0
  4180: 	movk	x9, #1536, lsl #16
  4184: 	str	x9, [x19, #912]
  4188: 	str	x20, [x19, #920]
  4192: 	mov	x0, #30                         // =0x1e
  4196: 	ldp	x29, x30, [sp]
  4200: 	ldp	x19, x20, [sp, #80]
  4204: 	ldp	x21, x22, [sp, #64]
  4208: 	ldp	x23, x24, [sp, #48]
  4212: 	ldp	x25, x26, [sp, #32]
  4216: 	ldr	x27, [sp, #24]
  4220: 	add	sp, sp, #96
  4224: 	ret
  4228: 	fmov	d0, d2
  4232: 	fmov	x0, d0
  4236: 	lsr	x3, x0, #48
  4240: 	mov	x10, #65521                     // =0xfff1
  4244: 	cmp	x3, x10
  4248: 	b.lo	#8
  4252: 	orr	x0, xzr, #0x7ff8000000000000
  4256: 	str	x0, [x19, #48]
  4260: 	fmov	d0, d3
  4264: 	fmov	x0, d0
  4268: 	lsr	x3, x0, #48
  4272: 	mov	x10, #65521                     // =0xfff1
  4276: 	cmp	x3, x10
  4280: 	b.lo	#8
  4284: 	orr	x0, xzr, #0x7ff8000000000000
  4288: 	str	x0, [x19, #56]
  4292: 	mov	x0, x6
  4296: 	and	x0, x0, #0xffffffffffff
  4300: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4304: 	orr	x0, x0, x10
  4308: 	str	x0, [x19, #64]
  4312: 	mov	x0, x7
  4316: 	and	x0, x0, #0xffffffffffff
  4320: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4324: 	orr	x0, x0, x10
  4328: 	str	x0, [x19, #72]
  4332: 	fmov	d0, d4
  4336: 	fmov	x0, d0
  4340: 	lsr	x3, x0, #48
  4344: 	mov	x10, #65521                     // =0xfff1
  4348: 	cmp	x3, x10
  4352: 	b.lo	#8
  4356: 	orr	x0, xzr, #0x7ff8000000000000
  4360: 	str	x0, [x19, #80]
  4364: 	mov	x0, x21
  4368: 	and	x0, x0, #0xffffffffffff
  4372: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4376: 	orr	x0, x0, x10
  4380: 	str	x0, [x19, #88]
  4384: 	mov	x0, x5
  4388: 	and	x0, x0, #0xffffffffffff
  4392: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4396: 	orr	x0, x0, x10
  4400: 	str	x0, [x19, #96]
  4404: 	fmov	d0, d7
  4408: 	fmov	x0, d0
  4412: 	lsr	x3, x0, #48
  4416: 	mov	x10, #65521                     // =0xfff1
  4420: 	cmp	x3, x10
  4424: 	b.lo	#8
  4428: 	orr	x0, xzr, #0x7ff8000000000000
  4432: 	str	x0, [x19, #104]
  4436: 	fmov	d0, d16
  4440: 	fmov	x0, d0
  4444: 	lsr	x3, x0, #48
  4448: 	mov	x10, #65521                     // =0xfff1
  4452: 	cmp	x3, x10
  4456: 	b.lo	#8
  4460: 	orr	x0, xzr, #0x7ff8000000000000
  4464: 	str	x0, [x19, #112]
  4468: 	mov	x0, x23
  4472: 	and	x0, x0, #0xffffffffffff
  4476: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4480: 	orr	x0, x0, x10
  4484: 	str	x0, [x19, #120]
  4488: 	mov	x0, x22
  4492: 	and	x0, x0, #0xffffffffffff
  4496: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4500: 	orr	x0, x0, x10
  4504: 	str	x0, [x19, #128]
  4508: 	orr	x3, xzr, #0x3fe0000000000000
  4512: 	fmov	d0, x3
  4516: 	fmov	x0, d0
  4520: 	lsr	x3, x0, #48
  4524: 	mov	x10, #65521                     // =0xfff1
  4528: 	cmp	x3, x10
  4532: 	b.lo	#8
  4536: 	orr	x0, xzr, #0x7ff8000000000000
  4540: 	str	x0, [x19, #200]
  4544: 	fmov	d0, d17
  4548: 	fmov	x0, d0
  4552: 	lsr	x3, x0, #48
  4556: 	mov	x10, #65521                     // =0xfff1
  4560: 	cmp	x3, x10
  4564: 	b.lo	#8
  4568: 	orr	x0, xzr, #0x7ff8000000000000
  4572: 	str	x0, [x19, #208]
  4576: 	mov	x9, #65472                      // =0xffc0
  4580: 	movk	x9, #1537, lsl #16
  4584: 	str	x9, [x19, #912]
  4588: 	str	x20, [x19, #920]
  4592: 	mov	x0, #37                         // =0x25
  4596: 	ldp	x29, x30, [sp]
  4600: 	ldp	x19, x20, [sp, #80]
  4604: 	ldp	x21, x22, [sp, #64]
  4608: 	ldp	x23, x24, [sp, #48]
  4612: 	ldp	x25, x26, [sp, #32]
  4616: 	ldr	x27, [sp, #24]
  4620: 	add	sp, sp, #96
  4624: 	ret
  4628: 	fmov	d0, d2
  4632: 	fmov	x0, d0
  4636: 	lsr	x3, x0, #48
  4640: 	mov	x10, #65521                     // =0xfff1
  4644: 	cmp	x3, x10
  4648: 	b.lo	#8
  4652: 	orr	x0, xzr, #0x7ff8000000000000
  4656: 	str	x0, [x19, #48]
  4660: 	fmov	d0, d3
  4664: 	fmov	x0, d0
  4668: 	lsr	x3, x0, #48
  4672: 	mov	x10, #65521                     // =0xfff1
  4676: 	cmp	x3, x10
  4680: 	b.lo	#8
  4684: 	orr	x0, xzr, #0x7ff8000000000000
  4688: 	str	x0, [x19, #56]
  4692: 	mov	x0, x6
  4696: 	and	x0, x0, #0xffffffffffff
  4700: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4704: 	orr	x0, x0, x10
  4708: 	str	x0, [x19, #64]
  4712: 	mov	x0, x7
  4716: 	and	x0, x0, #0xffffffffffff
  4720: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4724: 	orr	x0, x0, x10
  4728: 	str	x0, [x19, #72]
  4732: 	fmov	d0, d4
  4736: 	fmov	x0, d0
  4740: 	lsr	x3, x0, #48
  4744: 	mov	x10, #65521                     // =0xfff1
  4748: 	cmp	x3, x10
  4752: 	b.lo	#8
  4756: 	orr	x0, xzr, #0x7ff8000000000000
  4760: 	str	x0, [x19, #80]
  4764: 	mov	x0, x21
  4768: 	and	x0, x0, #0xffffffffffff
  4772: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4776: 	orr	x0, x0, x10
  4780: 	str	x0, [x19, #88]
  4784: 	mov	x0, x5
  4788: 	and	x0, x0, #0xffffffffffff
  4792: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4796: 	orr	x0, x0, x10
  4800: 	str	x0, [x19, #96]
  4804: 	fmov	d0, d7
  4808: 	fmov	x0, d0
  4812: 	lsr	x3, x0, #48
  4816: 	mov	x10, #65521                     // =0xfff1
  4820: 	cmp	x3, x10
  4824: 	b.lo	#8
  4828: 	orr	x0, xzr, #0x7ff8000000000000
  4832: 	str	x0, [x19, #104]
  4836: 	fmov	d0, d16
  4840: 	fmov	x0, d0
  4844: 	lsr	x3, x0, #48
  4848: 	mov	x10, #65521                     // =0xfff1
  4852: 	cmp	x3, x10
  4856: 	b.lo	#8
  4860: 	orr	x0, xzr, #0x7ff8000000000000
  4864: 	str	x0, [x19, #112]
  4868: 	mov	x0, x23
  4872: 	and	x0, x0, #0xffffffffffff
  4876: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4880: 	orr	x0, x0, x10
  4884: 	str	x0, [x19, #120]
  4888: 	mov	x0, x22
  4892: 	and	x0, x0, #0xffffffffffff
  4896: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4900: 	orr	x0, x0, x10
  4904: 	str	x0, [x19, #128]
  4908: 	ldr	x0, [x19, #936]
  4912: 	and	x0, x0, #0xffffffffffff
  4916: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4920: 	orr	x0, x0, x10
  4924: 	str	x0, [x19, #136]
  4928: 	orr	x3, xzr, #0x3fe0000000000000
  4932: 	fmov	d0, x3
  4936: 	fmov	x0, d0
  4940: 	lsr	x3, x0, #48
  4944: 	mov	x10, #65521                     // =0xfff1
  4948: 	cmp	x3, x10
  4952: 	b.lo	#8
  4956: 	orr	x0, xzr, #0x7ff8000000000000
  4960: 	str	x0, [x19, #200]
  4964: 	fmov	d0, d17
  4968: 	fmov	x0, d0
  4972: 	lsr	x3, x0, #48
  4976: 	mov	x10, #65521                     // =0xfff1
  4980: 	cmp	x3, x10
  4984: 	b.lo	#8
  4988: 	orr	x0, xzr, #0x7ff8000000000000
  4992: 	str	x0, [x19, #208]
  4996: 	mov	x9, #65472                      // =0xffc0
  5000: 	movk	x9, #1539, lsl #16
  5004: 	str	x9, [x19, #912]
  5008: 	str	x20, [x19, #920]
  5012: 	mov	x0, #38                         // =0x26
  5016: 	ldp	x29, x30, [sp]
  5020: 	ldp	x19, x20, [sp, #80]
  5024: 	ldp	x21, x22, [sp, #64]
  5028: 	ldp	x23, x24, [sp, #48]
  5032: 	ldp	x25, x26, [sp, #32]
  5036: 	ldr	x27, [sp, #24]
  5040: 	add	sp, sp, #96
  5044: 	ret
  5048: 	fmov	d0, d2
  5052: 	fmov	x0, d0
  5056: 	lsr	x3, x0, #48
  5060: 	mov	x10, #65521                     // =0xfff1
  5064: 	cmp	x3, x10
  5068: 	b.lo	#8
  5072: 	orr	x0, xzr, #0x7ff8000000000000
  5076: 	str	x0, [x19, #48]
  5080: 	fmov	d0, d3
  5084: 	fmov	x0, d0
  5088: 	lsr	x3, x0, #48
  5092: 	mov	x10, #65521                     // =0xfff1
  5096: 	cmp	x3, x10
  5100: 	b.lo	#8
  5104: 	orr	x0, xzr, #0x7ff8000000000000
  5108: 	str	x0, [x19, #56]
  5112: 	mov	x0, x6
  5116: 	and	x0, x0, #0xffffffffffff
  5120: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5124: 	orr	x0, x0, x10
  5128: 	str	x0, [x19, #64]
  5132: 	mov	x0, x7
  5136: 	and	x0, x0, #0xffffffffffff
  5140: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5144: 	orr	x0, x0, x10
  5148: 	str	x0, [x19, #72]
  5152: 	fmov	d0, d4
  5156: 	fmov	x0, d0
  5160: 	lsr	x3, x0, #48
  5164: 	mov	x10, #65521                     // =0xfff1
  5168: 	cmp	x3, x10
  5172: 	b.lo	#8
  5176: 	orr	x0, xzr, #0x7ff8000000000000
  5180: 	str	x0, [x19, #80]
  5184: 	mov	x0, x21
  5188: 	and	x0, x0, #0xffffffffffff
  5192: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5196: 	orr	x0, x0, x10
  5200: 	str	x0, [x19, #88]
  5204: 	mov	x0, x5
  5208: 	and	x0, x0, #0xffffffffffff
  5212: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5216: 	orr	x0, x0, x10
  5220: 	str	x0, [x19, #96]
  5224: 	fmov	d0, d7
  5228: 	fmov	x0, d0
  5232: 	lsr	x3, x0, #48
  5236: 	mov	x10, #65521                     // =0xfff1
  5240: 	cmp	x3, x10
  5244: 	b.lo	#8
  5248: 	orr	x0, xzr, #0x7ff8000000000000
  5252: 	str	x0, [x19, #104]
  5256: 	fmov	d0, d16
  5260: 	fmov	x0, d0
  5264: 	lsr	x3, x0, #48
  5268: 	mov	x10, #65521                     // =0xfff1
  5272: 	cmp	x3, x10
  5276: 	b.lo	#8
  5280: 	orr	x0, xzr, #0x7ff8000000000000
  5284: 	str	x0, [x19, #112]
  5288: 	mov	x0, x23
  5292: 	and	x0, x0, #0xffffffffffff
  5296: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5300: 	orr	x0, x0, x10
  5304: 	str	x0, [x19, #120]
  5308: 	mov	x0, x22
  5312: 	and	x0, x0, #0xffffffffffff
  5316: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5320: 	orr	x0, x0, x10
  5324: 	str	x0, [x19, #128]
  5328: 	ldr	x0, [x19, #936]
  5332: 	and	x0, x0, #0xffffffffffff
  5336: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5340: 	orr	x0, x0, x10
  5344: 	str	x0, [x19, #136]
  5348: 	ldr	x0, [x19, #944]
  5352: 	and	x0, x0, #0xffffffffffff
  5356: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5360: 	orr	x0, x0, x10
  5364: 	str	x0, [x19, #144]
  5368: 	fmov	d0, d6
  5372: 	fmov	x0, d0
  5376: 	lsr	x3, x0, #48
  5380: 	mov	x10, #65521                     // =0xfff1
  5384: 	cmp	x3, x10
  5388: 	b.lo	#8
  5392: 	orr	x0, xzr, #0x7ff8000000000000
  5396: 	str	x0, [x19, #152]
  5400: 	ldr	d0, [x19, #960]
  5404: 	fmov	x0, d0
  5408: 	lsr	x3, x0, #48
  5412: 	mov	x10, #65521                     // =0xfff1
  5416: 	cmp	x3, x10
  5420: 	b.lo	#8
  5424: 	orr	x0, xzr, #0x7ff8000000000000
  5428: 	str	x0, [x19, #160]
  5432: 	ldr	d0, [x19, #976]
  5436: 	fmov	x0, d0
  5440: 	lsr	x3, x0, #48
  5444: 	mov	x10, #65521                     // =0xfff1
  5448: 	cmp	x3, x10
  5452: 	b.lo	#8
  5456: 	orr	x0, xzr, #0x7ff8000000000000
  5460: 	str	x0, [x19, #168]
  5464: 	ldr	d0, [x19, #992]
  5468: 	fmov	x0, d0
  5472: 	lsr	x3, x0, #48
  5476: 	mov	x10, #65521                     // =0xfff1
  5480: 	cmp	x3, x10
  5484: 	b.lo	#8
  5488: 	orr	x0, xzr, #0x7ff8000000000000
  5492: 	str	x0, [x19, #176]
  5496: 	ldr	x0, [x19, #1000]
  5500: 	str	x0, [x19, #200]
  5504: 	fmov	d0, d17
  5508: 	fmov	x0, d0
  5512: 	lsr	x3, x0, #48
  5516: 	mov	x10, #65521                     // =0xfff1
  5520: 	cmp	x3, x10
  5524: 	b.lo	#8
  5528: 	orr	x0, xzr, #0x7ff8000000000000
  5532: 	str	x0, [x19, #208]
  5536: 	mov	x9, #65472                      // =0xffc0
  5540: 	movk	x9, #1663, lsl #16
  5544: 	str	x9, [x19, #912]
  5548: 	str	x20, [x19, #920]
  5552: 	mov	x0, #46                         // =0x2e
  5556: 	ldp	x29, x30, [sp]
  5560: 	ldp	x19, x20, [sp, #80]
  5564: 	ldp	x21, x22, [sp, #64]
  5568: 	ldp	x23, x24, [sp, #48]
  5572: 	ldp	x25, x26, [sp, #32]
  5576: 	ldr	x27, [sp, #24]
  5580: 	add	sp, sp, #96
  5584: 	ret
  5588: 	fmov	d0, d2
  5592: 	fmov	x0, d0
  5596: 	lsr	x3, x0, #48
  5600: 	mov	x10, #65521                     // =0xfff1
  5604: 	cmp	x3, x10
  5608: 	b.lo	#8
  5612: 	orr	x0, xzr, #0x7ff8000000000000
  5616: 	str	x0, [x19, #48]
  5620: 	fmov	d0, d3
  5624: 	fmov	x0, d0
  5628: 	lsr	x3, x0, #48
  5632: 	mov	x10, #65521                     // =0xfff1
  5636: 	cmp	x3, x10
  5640: 	b.lo	#8
  5644: 	orr	x0, xzr, #0x7ff8000000000000
  5648: 	str	x0, [x19, #56]
  5652: 	mov	x0, x6
  5656: 	and	x0, x0, #0xffffffffffff
  5660: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5664: 	orr	x0, x0, x10
  5668: 	str	x0, [x19, #64]
  5672: 	mov	x0, x7
  5676: 	and	x0, x0, #0xffffffffffff
  5680: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5684: 	orr	x0, x0, x10
  5688: 	str	x0, [x19, #72]
  5692: 	fmov	d0, d4
  5696: 	fmov	x0, d0
  5700: 	lsr	x3, x0, #48
  5704: 	mov	x10, #65521                     // =0xfff1
  5708: 	cmp	x3, x10
  5712: 	b.lo	#8
  5716: 	orr	x0, xzr, #0x7ff8000000000000
  5720: 	str	x0, [x19, #80]
  5724: 	mov	x0, x21
  5728: 	and	x0, x0, #0xffffffffffff
  5732: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5736: 	orr	x0, x0, x10
  5740: 	str	x0, [x19, #88]
  5744: 	mov	x0, x5
  5748: 	and	x0, x0, #0xffffffffffff
  5752: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5756: 	orr	x0, x0, x10
  5760: 	str	x0, [x19, #96]
  5764: 	fmov	d0, d7
  5768: 	fmov	x0, d0
  5772: 	lsr	x3, x0, #48
  5776: 	mov	x10, #65521                     // =0xfff1
  5780: 	cmp	x3, x10
  5784: 	b.lo	#8
  5788: 	orr	x0, xzr, #0x7ff8000000000000
  5792: 	str	x0, [x19, #104]
  5796: 	fmov	d0, d16
  5800: 	fmov	x0, d0
  5804: 	lsr	x3, x0, #48
  5808: 	mov	x10, #65521                     // =0xfff1
  5812: 	cmp	x3, x10
  5816: 	b.lo	#8
  5820: 	orr	x0, xzr, #0x7ff8000000000000
  5824: 	str	x0, [x19, #112]
  5828: 	mov	x0, x23
  5832: 	and	x0, x0, #0xffffffffffff
  5836: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5840: 	orr	x0, x0, x10
  5844: 	str	x0, [x19, #120]
  5848: 	mov	x0, x22
  5852: 	and	x0, x0, #0xffffffffffff
  5856: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5860: 	orr	x0, x0, x10
  5864: 	str	x0, [x19, #128]
  5868: 	ldr	x0, [x19, #936]
  5872: 	and	x0, x0, #0xffffffffffff
  5876: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5880: 	orr	x0, x0, x10
  5884: 	str	x0, [x19, #136]
  5888: 	ldr	x0, [x19, #944]
  5892: 	and	x0, x0, #0xffffffffffff
  5896: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5900: 	orr	x0, x0, x10
  5904: 	str	x0, [x19, #144]
  5908: 	fmov	d0, d6
  5912: 	fmov	x0, d0
  5916: 	lsr	x3, x0, #48
  5920: 	mov	x10, #65521                     // =0xfff1
  5924: 	cmp	x3, x10
  5928: 	b.lo	#8
  5932: 	orr	x0, xzr, #0x7ff8000000000000
  5936: 	str	x0, [x19, #152]
  5940: 	ldr	d0, [x19, #960]
  5944: 	fmov	x0, d0
  5948: 	lsr	x3, x0, #48
  5952: 	mov	x10, #65521                     // =0xfff1
  5956: 	cmp	x3, x10
  5960: 	b.lo	#8
  5964: 	orr	x0, xzr, #0x7ff8000000000000
  5968: 	str	x0, [x19, #160]
  5972: 	ldr	d0, [x19, #976]
  5976: 	fmov	x0, d0
  5980: 	lsr	x3, x0, #48
  5984: 	mov	x10, #65521                     // =0xfff1
  5988: 	cmp	x3, x10
  5992: 	b.lo	#8
  5996: 	orr	x0, xzr, #0x7ff8000000000000
  6000: 	str	x0, [x19, #168]
  6004: 	ldr	d0, [x19, #992]
  6008: 	fmov	x0, d0
  6012: 	lsr	x3, x0, #48
  6016: 	mov	x10, #65521                     // =0xfff1
  6020: 	cmp	x3, x10
  6024: 	b.lo	#8
  6028: 	orr	x0, xzr, #0x7ff8000000000000
  6032: 	str	x0, [x19, #176]
  6036: 	ldr	d0, [x19, #1016]
  6040: 	fmov	x0, d0
  6044: 	lsr	x3, x0, #48
  6048: 	mov	x10, #65521                     // =0xfff1
  6052: 	cmp	x3, x10
  6056: 	b.lo	#8
  6060: 	orr	x0, xzr, #0x7ff8000000000000
  6064: 	str	x0, [x19, #184]
  6068: 	ldr	x0, [x19, #1000]
  6072: 	str	x0, [x19, #200]
  6076: 	fmov	d0, d17
  6080: 	fmov	x0, d0
  6084: 	lsr	x3, x0, #48
  6088: 	mov	x10, #65521                     // =0xfff1
  6092: 	cmp	x3, x10
  6096: 	b.lo	#8
  6100: 	orr	x0, xzr, #0x7ff8000000000000
  6104: 	str	x0, [x19, #208]
  6108: 	mov	x9, #65472                      // =0xffc0
  6112: 	movk	x9, #1791, lsl #16
  6116: 	str	x9, [x19, #912]
  6120: 	str	x20, [x19, #920]
  6124: 	mov	x0, #48                         // =0x30
  6128: 	ldp	x29, x30, [sp]
  6132: 	ldp	x19, x20, [sp, #80]
  6136: 	ldp	x21, x22, [sp, #64]
  6140: 	ldp	x23, x24, [sp, #48]
  6144: 	ldp	x25, x26, [sp, #32]
  6148: 	ldr	x27, [sp, #24]
  6152: 	add	sp, sp, #96
  6156: 	ret
  6160: 	fmov	d0, d2
  6164: 	fmov	x0, d0
  6168: 	lsr	x3, x0, #48
  6172: 	mov	x10, #65521                     // =0xfff1
  6176: 	cmp	x3, x10
  6180: 	b.lo	#8
  6184: 	orr	x0, xzr, #0x7ff8000000000000
  6188: 	str	x0, [x19, #48]
  6192: 	fmov	d0, d3
  6196: 	fmov	x0, d0
  6200: 	lsr	x3, x0, #48
  6204: 	mov	x10, #65521                     // =0xfff1
  6208: 	cmp	x3, x10
  6212: 	b.lo	#8
  6216: 	orr	x0, xzr, #0x7ff8000000000000
  6220: 	str	x0, [x19, #56]
  6224: 	mov	x0, x6
  6228: 	and	x0, x0, #0xffffffffffff
  6232: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6236: 	orr	x0, x0, x10
  6240: 	str	x0, [x19, #64]
  6244: 	mov	x0, x7
  6248: 	and	x0, x0, #0xffffffffffff
  6252: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6256: 	orr	x0, x0, x10
  6260: 	str	x0, [x19, #72]
  6264: 	fmov	d0, d4
  6268: 	fmov	x0, d0
  6272: 	lsr	x3, x0, #48
  6276: 	mov	x10, #65521                     // =0xfff1
  6280: 	cmp	x3, x10
  6284: 	b.lo	#8
  6288: 	orr	x0, xzr, #0x7ff8000000000000
  6292: 	str	x0, [x19, #80]
  6296: 	mov	x0, x21
  6300: 	and	x0, x0, #0xffffffffffff
  6304: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6308: 	orr	x0, x0, x10
  6312: 	str	x0, [x19, #88]
  6316: 	mov	x0, x5
  6320: 	and	x0, x0, #0xffffffffffff
  6324: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6328: 	orr	x0, x0, x10
  6332: 	str	x0, [x19, #96]
  6336: 	fmov	d0, d7
  6340: 	fmov	x0, d0
  6344: 	lsr	x3, x0, #48
  6348: 	mov	x10, #65521                     // =0xfff1
  6352: 	cmp	x3, x10
  6356: 	b.lo	#8
  6360: 	orr	x0, xzr, #0x7ff8000000000000
  6364: 	str	x0, [x19, #104]
  6368: 	fmov	d0, d16
  6372: 	fmov	x0, d0
  6376: 	lsr	x3, x0, #48
  6380: 	mov	x10, #65521                     // =0xfff1
  6384: 	cmp	x3, x10
  6388: 	b.lo	#8
  6392: 	orr	x0, xzr, #0x7ff8000000000000
  6396: 	str	x0, [x19, #112]
  6400: 	mov	x0, x23
  6404: 	and	x0, x0, #0xffffffffffff
  6408: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6412: 	orr	x0, x0, x10
  6416: 	str	x0, [x19, #120]
  6420: 	mov	x0, x22
  6424: 	and	x0, x0, #0xffffffffffff
  6428: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6432: 	orr	x0, x0, x10
  6436: 	str	x0, [x19, #128]
  6440: 	ldr	x0, [x19, #936]
  6444: 	and	x0, x0, #0xffffffffffff
  6448: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6452: 	orr	x0, x0, x10
  6456: 	str	x0, [x19, #136]
  6460: 	ldr	x0, [x19, #944]
  6464: 	and	x0, x0, #0xffffffffffff
  6468: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6472: 	orr	x0, x0, x10
  6476: 	str	x0, [x19, #144]
  6480: 	fmov	d0, d6
  6484: 	fmov	x0, d0
  6488: 	lsr	x3, x0, #48
  6492: 	mov	x10, #65521                     // =0xfff1
  6496: 	cmp	x3, x10
  6500: 	b.lo	#8
  6504: 	orr	x0, xzr, #0x7ff8000000000000
  6508: 	str	x0, [x19, #152]
  6512: 	ldr	d0, [x19, #960]
  6516: 	fmov	x0, d0
  6520: 	lsr	x3, x0, #48
  6524: 	mov	x10, #65521                     // =0xfff1
  6528: 	cmp	x3, x10
  6532: 	b.lo	#8
  6536: 	orr	x0, xzr, #0x7ff8000000000000
  6540: 	str	x0, [x19, #160]
  6544: 	ldr	d0, [x19, #976]
  6548: 	fmov	x0, d0
  6552: 	lsr	x3, x0, #48
  6556: 	mov	x10, #65521                     // =0xfff1
  6560: 	cmp	x3, x10
  6564: 	b.lo	#8
  6568: 	orr	x0, xzr, #0x7ff8000000000000
  6572: 	str	x0, [x19, #168]
  6576: 	ldr	d0, [x19, #992]
  6580: 	fmov	x0, d0
  6584: 	lsr	x3, x0, #48
  6588: 	mov	x10, #65521                     // =0xfff1
  6592: 	cmp	x3, x10
  6596: 	b.lo	#8
  6600: 	orr	x0, xzr, #0x7ff8000000000000
  6604: 	str	x0, [x19, #176]
  6608: 	ldr	d0, [x19, #1016]
  6612: 	fmov	x0, d0
  6616: 	lsr	x3, x0, #48
  6620: 	mov	x10, #65521                     // =0xfff1
  6624: 	cmp	x3, x10
  6628: 	b.lo	#8
  6632: 	orr	x0, xzr, #0x7ff8000000000000
  6636: 	str	x0, [x19, #184]
  6640: 	ldr	d0, [x19, #1040]
  6644: 	fmov	x0, d0
  6648: 	lsr	x3, x0, #48
  6652: 	mov	x10, #65521                     // =0xfff1
  6656: 	cmp	x3, x10
  6660: 	b.lo	#8
  6664: 	orr	x0, xzr, #0x7ff8000000000000
  6668: 	str	x0, [x19, #192]
  6672: 	mov	x0, x21
  6676: 	and	x0, x0, #0xffffffffffff
  6680: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6684: 	orr	x0, x0, x10
  6688: 	str	x0, [x19, #200]
  6692: 	fmov	d0, d17
  6696: 	fmov	x0, d0
  6700: 	lsr	x3, x0, #48
  6704: 	mov	x10, #65521                     // =0xfff1
  6708: 	cmp	x3, x10
  6712: 	b.lo	#8
  6716: 	orr	x0, xzr, #0x7ff8000000000000
  6720: 	str	x0, [x19, #208]
  6724: 	ldr	d0, [x19, #1048]
  6728: 	fmov	x0, d0
  6732: 	lsr	x3, x0, #48
  6736: 	mov	x10, #65521                     // =0xfff1
  6740: 	cmp	x3, x10
  6744: 	b.lo	#8
  6748: 	orr	x0, xzr, #0x7ff8000000000000
  6752: 	str	x0, [x19, #216]
  6756: 	mov	w9, #268435392                  // =0xfffffc0
  6760: 	str	x9, [x19, #912]
  6764: 	str	x20, [x19, #920]
  6768: 	mov	x0, #51                         // =0x33
  6772: 	ldp	x29, x30, [sp]
  6776: 	ldp	x19, x20, [sp, #80]
  6780: 	ldp	x21, x22, [sp, #64]
  6784: 	ldp	x23, x24, [sp, #48]
  6788: 	ldp	x25, x26, [sp, #32]
  6792: 	ldr	x27, [sp, #24]
  6796: 	add	sp, sp, #96
  6800: 	ret
  6804: 	fmov	d0, d2
  6808: 	fmov	x0, d0
  6812: 	lsr	x3, x0, #48
  6816: 	mov	x10, #65521                     // =0xfff1
  6820: 	cmp	x3, x10
  6824: 	b.lo	#8
  6828: 	orr	x0, xzr, #0x7ff8000000000000
  6832: 	str	x0, [x19, #48]
  6836: 	fmov	d0, d3
  6840: 	fmov	x0, d0
  6844: 	lsr	x3, x0, #48
  6848: 	mov	x10, #65521                     // =0xfff1
  6852: 	cmp	x3, x10
  6856: 	b.lo	#8
  6860: 	orr	x0, xzr, #0x7ff8000000000000
  6864: 	str	x0, [x19, #56]
  6868: 	mov	x0, x6
  6872: 	and	x0, x0, #0xffffffffffff
  6876: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6880: 	orr	x0, x0, x10
  6884: 	str	x0, [x19, #64]
  6888: 	mov	x0, x7
  6892: 	and	x0, x0, #0xffffffffffff
  6896: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6900: 	orr	x0, x0, x10
  6904: 	str	x0, [x19, #72]
  6908: 	fmov	d0, d4
  6912: 	fmov	x0, d0
  6916: 	lsr	x3, x0, #48
  6920: 	mov	x10, #65521                     // =0xfff1
  6924: 	cmp	x3, x10
  6928: 	b.lo	#8
  6932: 	orr	x0, xzr, #0x7ff8000000000000
  6936: 	str	x0, [x19, #80]
  6940: 	mov	x0, x21
  6944: 	and	x0, x0, #0xffffffffffff
  6948: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6952: 	orr	x0, x0, x10
  6956: 	str	x0, [x19, #88]
  6960: 	mov	x0, x5
  6964: 	and	x0, x0, #0xffffffffffff
  6968: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6972: 	orr	x0, x0, x10
  6976: 	str	x0, [x19, #96]
  6980: 	fmov	d0, d7
  6984: 	fmov	x0, d0
  6988: 	lsr	x3, x0, #48
  6992: 	mov	x10, #65521                     // =0xfff1
  6996: 	cmp	x3, x10
  7000: 	b.lo	#8
  7004: 	orr	x0, xzr, #0x7ff8000000000000
  7008: 	str	x0, [x19, #104]
  7012: 	fmov	d0, d16
  7016: 	fmov	x0, d0
  7020: 	lsr	x3, x0, #48
  7024: 	mov	x10, #65521                     // =0xfff1
  7028: 	cmp	x3, x10
  7032: 	b.lo	#8
  7036: 	orr	x0, xzr, #0x7ff8000000000000
  7040: 	str	x0, [x19, #112]
  7044: 	mov	x0, x23
  7048: 	and	x0, x0, #0xffffffffffff
  7052: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7056: 	orr	x0, x0, x10
  7060: 	str	x0, [x19, #120]
  7064: 	mov	x0, x22
  7068: 	and	x0, x0, #0xffffffffffff
  7072: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7076: 	orr	x0, x0, x10
  7080: 	str	x0, [x19, #128]
  7084: 	ldr	x0, [x19, #936]
  7088: 	and	x0, x0, #0xffffffffffff
  7092: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7096: 	orr	x0, x0, x10
  7100: 	str	x0, [x19, #136]
  7104: 	ldr	x0, [x19, #944]
  7108: 	and	x0, x0, #0xffffffffffff
  7112: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7116: 	orr	x0, x0, x10
  7120: 	str	x0, [x19, #144]
  7124: 	fmov	d0, d6
  7128: 	fmov	x0, d0
  7132: 	lsr	x3, x0, #48
  7136: 	mov	x10, #65521                     // =0xfff1
  7140: 	cmp	x3, x10
  7144: 	b.lo	#8
  7148: 	orr	x0, xzr, #0x7ff8000000000000
  7152: 	str	x0, [x19, #152]
  7156: 	ldr	d0, [x19, #960]
  7160: 	fmov	x0, d0
  7164: 	lsr	x3, x0, #48
  7168: 	mov	x10, #65521                     // =0xfff1
  7172: 	cmp	x3, x10
  7176: 	b.lo	#8
  7180: 	orr	x0, xzr, #0x7ff8000000000000
  7184: 	str	x0, [x19, #160]
  7188: 	ldr	d0, [x19, #976]
  7192: 	fmov	x0, d0
  7196: 	lsr	x3, x0, #48
  7200: 	mov	x10, #65521                     // =0xfff1
  7204: 	cmp	x3, x10
  7208: 	b.lo	#8
  7212: 	orr	x0, xzr, #0x7ff8000000000000
  7216: 	str	x0, [x19, #168]
  7220: 	ldr	d0, [x19, #992]
  7224: 	fmov	x0, d0
  7228: 	lsr	x3, x0, #48
  7232: 	mov	x10, #65521                     // =0xfff1
  7236: 	cmp	x3, x10
  7240: 	b.lo	#8
  7244: 	orr	x0, xzr, #0x7ff8000000000000
  7248: 	str	x0, [x19, #176]
  7252: 	ldr	d0, [x19, #1016]
  7256: 	fmov	x0, d0
  7260: 	lsr	x3, x0, #48
  7264: 	mov	x10, #65521                     // =0xfff1
  7268: 	cmp	x3, x10
  7272: 	b.lo	#8
  7276: 	orr	x0, xzr, #0x7ff8000000000000
  7280: 	str	x0, [x19, #184]
  7284: 	ldr	d0, [x19, #1040]
  7288: 	fmov	x0, d0
  7292: 	lsr	x3, x0, #48
  7296: 	mov	x10, #65521                     // =0xfff1
  7300: 	cmp	x3, x10
  7304: 	b.lo	#8
  7308: 	orr	x0, xzr, #0x7ff8000000000000
  7312: 	str	x0, [x19, #192]
  7316: 	mov	x0, x21
  7320: 	and	x0, x0, #0xffffffffffff
  7324: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7328: 	orr	x0, x0, x10
  7332: 	str	x0, [x19, #200]
  7336: 	fmov	d0, d17
  7340: 	fmov	x0, d0
  7344: 	lsr	x3, x0, #48
  7348: 	mov	x10, #65521                     // =0xfff1
  7352: 	cmp	x3, x10
  7356: 	b.lo	#8
  7360: 	orr	x0, xzr, #0x7ff8000000000000
  7364: 	str	x0, [x19, #208]
  7368: 	ldr	d0, [x19, #1048]
  7372: 	fmov	x0, d0
  7376: 	lsr	x3, x0, #48
  7380: 	mov	x10, #65521                     // =0xfff1
  7384: 	cmp	x3, x10
  7388: 	b.lo	#8
  7392: 	orr	x0, xzr, #0x7ff8000000000000
  7396: 	str	x0, [x19, #216]
  7400: 	ldr	d0, [x19, #1064]
  7404: 	fmov	x0, d0
  7408: 	lsr	x3, x0, #48
  7412: 	mov	x10, #65521                     // =0xfff1
  7416: 	cmp	x3, x10
  7420: 	b.lo	#8
  7424: 	orr	x0, xzr, #0x7ff8000000000000
  7428: 	str	x0, [x19, #224]
  7432: 	ldr	d0, [x19, #1072]
  7436: 	fmov	x0, d0
  7440: 	lsr	x3, x0, #48
  7444: 	mov	x10, #65521                     // =0xfff1
  7448: 	cmp	x3, x10
  7452: 	b.lo	#8
  7456: 	orr	x0, xzr, #0x7ff8000000000000
  7460: 	str	x0, [x19, #232]
  7464: 	ldr	d0, [x19, #1080]
  7468: 	fmov	x0, d0
  7472: 	lsr	x3, x0, #48
  7476: 	mov	x10, #65521                     // =0xfff1
  7480: 	cmp	x3, x10
  7484: 	b.lo	#8
  7488: 	orr	x0, xzr, #0x7ff8000000000000
  7492: 	str	x0, [x19, #240]
  7496: 	mov	w9, #2147483584                 // =0x7fffffc0
  7500: 	str	x9, [x19, #912]
  7504: 	str	x20, [x19, #920]
  7508: 	mov	x0, #54                         // =0x36
  7512: 	ldp	x29, x30, [sp]
  7516: 	ldp	x19, x20, [sp, #80]
  7520: 	ldp	x21, x22, [sp, #64]
  7524: 	ldp	x23, x24, [sp, #48]
  7528: 	ldp	x25, x26, [sp, #32]
  7532: 	ldr	x27, [sp, #24]
  7536: 	add	sp, sp, #96
  7540: 	ret
  7544: 	fmov	d0, d2
  7548: 	fmov	x0, d0
  7552: 	lsr	x3, x0, #48
  7556: 	mov	x10, #65521                     // =0xfff1
  7560: 	cmp	x3, x10
  7564: 	b.lo	#8
  7568: 	orr	x0, xzr, #0x7ff8000000000000
  7572: 	str	x0, [x19, #48]
  7576: 	fmov	d0, d3
  7580: 	fmov	x0, d0
  7584: 	lsr	x3, x0, #48
  7588: 	mov	x10, #65521                     // =0xfff1
  7592: 	cmp	x3, x10
  7596: 	b.lo	#8
  7600: 	orr	x0, xzr, #0x7ff8000000000000
  7604: 	str	x0, [x19, #56]
  7608: 	mov	x0, x6
  7612: 	and	x0, x0, #0xffffffffffff
  7616: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7620: 	orr	x0, x0, x10
  7624: 	str	x0, [x19, #64]
  7628: 	mov	x0, x7
  7632: 	and	x0, x0, #0xffffffffffff
  7636: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7640: 	orr	x0, x0, x10
  7644: 	str	x0, [x19, #72]
  7648: 	fmov	d0, d4
  7652: 	fmov	x0, d0
  7656: 	lsr	x3, x0, #48
  7660: 	mov	x10, #65521                     // =0xfff1
  7664: 	cmp	x3, x10
  7668: 	b.lo	#8
  7672: 	orr	x0, xzr, #0x7ff8000000000000
  7676: 	str	x0, [x19, #80]
  7680: 	mov	x0, x21
  7684: 	and	x0, x0, #0xffffffffffff
  7688: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7692: 	orr	x0, x0, x10
  7696: 	str	x0, [x19, #88]
  7700: 	mov	x0, x5
  7704: 	and	x0, x0, #0xffffffffffff
  7708: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7712: 	orr	x0, x0, x10
  7716: 	str	x0, [x19, #96]
  7720: 	fmov	d0, d7
  7724: 	fmov	x0, d0
  7728: 	lsr	x3, x0, #48
  7732: 	mov	x10, #65521                     // =0xfff1
  7736: 	cmp	x3, x10
  7740: 	b.lo	#8
  7744: 	orr	x0, xzr, #0x7ff8000000000000
  7748: 	str	x0, [x19, #104]
  7752: 	fmov	d0, d16
  7756: 	fmov	x0, d0
  7760: 	lsr	x3, x0, #48
  7764: 	mov	x10, #65521                     // =0xfff1
  7768: 	cmp	x3, x10
  7772: 	b.lo	#8
  7776: 	orr	x0, xzr, #0x7ff8000000000000
  7780: 	str	x0, [x19, #112]
  7784: 	mov	x0, x23
  7788: 	and	x0, x0, #0xffffffffffff
  7792: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7796: 	orr	x0, x0, x10
  7800: 	str	x0, [x19, #120]
  7804: 	mov	x0, x22
  7808: 	and	x0, x0, #0xffffffffffff
  7812: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7816: 	orr	x0, x0, x10
  7820: 	str	x0, [x19, #128]
  7824: 	ldr	x0, [x19, #936]
  7828: 	and	x0, x0, #0xffffffffffff
  7832: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7836: 	orr	x0, x0, x10
  7840: 	str	x0, [x19, #136]
  7844: 	ldr	x0, [x19, #944]
  7848: 	and	x0, x0, #0xffffffffffff
  7852: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7856: 	orr	x0, x0, x10
  7860: 	str	x0, [x19, #144]
  7864: 	fmov	d0, d6
  7868: 	fmov	x0, d0
  7872: 	lsr	x3, x0, #48
  7876: 	mov	x10, #65521                     // =0xfff1
  7880: 	cmp	x3, x10
  7884: 	b.lo	#8
  7888: 	orr	x0, xzr, #0x7ff8000000000000
  7892: 	str	x0, [x19, #152]
  7896: 	ldr	d0, [x19, #960]
  7900: 	fmov	x0, d0
  7904: 	lsr	x3, x0, #48
  7908: 	mov	x10, #65521                     // =0xfff1
  7912: 	cmp	x3, x10
  7916: 	b.lo	#8
  7920: 	orr	x0, xzr, #0x7ff8000000000000
  7924: 	str	x0, [x19, #160]
  7928: 	ldr	d0, [x19, #976]
  7932: 	fmov	x0, d0
  7936: 	lsr	x3, x0, #48
  7940: 	mov	x10, #65521                     // =0xfff1
  7944: 	cmp	x3, x10
  7948: 	b.lo	#8
  7952: 	orr	x0, xzr, #0x7ff8000000000000
  7956: 	str	x0, [x19, #168]
  7960: 	ldr	d0, [x19, #992]
  7964: 	fmov	x0, d0
  7968: 	lsr	x3, x0, #48
  7972: 	mov	x10, #65521                     // =0xfff1
  7976: 	cmp	x3, x10
  7980: 	b.lo	#8
  7984: 	orr	x0, xzr, #0x7ff8000000000000
  7988: 	str	x0, [x19, #176]
  7992: 	ldr	d0, [x19, #1016]
  7996: 	fmov	x0, d0
  8000: 	lsr	x3, x0, #48
  8004: 	mov	x10, #65521                     // =0xfff1
  8008: 	cmp	x3, x10
  8012: 	b.lo	#8
  8016: 	orr	x0, xzr, #0x7ff8000000000000
  8020: 	str	x0, [x19, #184]
  8024: 	ldr	d0, [x19, #1040]
  8028: 	fmov	x0, d0
  8032: 	lsr	x3, x0, #48
  8036: 	mov	x10, #65521                     // =0xfff1
  8040: 	cmp	x3, x10
  8044: 	b.lo	#8
  8048: 	orr	x0, xzr, #0x7ff8000000000000
  8052: 	str	x0, [x19, #192]
  8056: 	mov	x0, x21
  8060: 	and	x0, x0, #0xffffffffffff
  8064: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8068: 	orr	x0, x0, x10
  8072: 	str	x0, [x19, #200]
  8076: 	fmov	d0, d17
  8080: 	fmov	x0, d0
  8084: 	lsr	x3, x0, #48
  8088: 	mov	x10, #65521                     // =0xfff1
  8092: 	cmp	x3, x10
  8096: 	b.lo	#8
  8100: 	orr	x0, xzr, #0x7ff8000000000000
  8104: 	str	x0, [x19, #208]
  8108: 	ldr	d0, [x19, #1048]
  8112: 	fmov	x0, d0
  8116: 	lsr	x3, x0, #48
  8120: 	mov	x10, #65521                     // =0xfff1
  8124: 	cmp	x3, x10
  8128: 	b.lo	#8
  8132: 	orr	x0, xzr, #0x7ff8000000000000
  8136: 	str	x0, [x19, #216]
  8140: 	ldr	d0, [x19, #1064]
  8144: 	fmov	x0, d0
  8148: 	lsr	x3, x0, #48
  8152: 	mov	x10, #65521                     // =0xfff1
  8156: 	cmp	x3, x10
  8160: 	b.lo	#8
  8164: 	orr	x0, xzr, #0x7ff8000000000000
  8168: 	str	x0, [x19, #224]
  8172: 	ldr	d0, [x19, #1104]
  8176: 	fmov	x0, d0
  8180: 	lsr	x3, x0, #48
  8184: 	mov	x10, #65521                     // =0xfff1
  8188: 	cmp	x3, x10
  8192: 	b.lo	#8
  8196: 	orr	x0, xzr, #0x7ff8000000000000
  8200: 	str	x0, [x19, #232]
  8204: 	ldr	d0, [x19, #1080]
  8208: 	fmov	x0, d0
  8212: 	lsr	x3, x0, #48
  8216: 	mov	x10, #65521                     // =0xfff1
  8220: 	cmp	x3, x10
  8224: 	b.lo	#8
  8228: 	orr	x0, xzr, #0x7ff8000000000000
  8232: 	str	x0, [x19, #240]
  8236: 	fmov	d0, d5
  8240: 	fmov	x0, d0
  8244: 	lsr	x3, x0, #48
  8248: 	mov	x10, #65521                     // =0xfff1
  8252: 	cmp	x3, x10
  8256: 	b.lo	#8
  8260: 	orr	x0, xzr, #0x7ff8000000000000
  8264: 	str	x0, [x19, #248]
  8268: 	ldr	d0, [x19, #1112]
  8272: 	fmov	x0, d0
  8276: 	lsr	x3, x0, #48
  8280: 	mov	x10, #65521                     // =0xfff1
  8284: 	cmp	x3, x10
  8288: 	b.lo	#8
  8292: 	orr	x0, xzr, #0x7ff8000000000000
  8296: 	str	x0, [x19, #256]
  8300: 	ldr	d0, [x19, #1128]
  8304: 	fmov	x0, d0
  8308: 	lsr	x3, x0, #48
  8312: 	mov	x10, #65521                     // =0xfff1
  8316: 	cmp	x3, x10
  8320: 	b.lo	#8
  8324: 	orr	x0, xzr, #0x7ff8000000000000
  8328: 	str	x0, [x19, #264]
  8332: 	mov	x9, #17179869120                // =0x3ffffffc0
  8336: 	str	x9, [x19, #912]
  8340: 	str	x20, [x19, #920]
  8344: 	mov	x0, #59                         // =0x3b
  8348: 	ldp	x29, x30, [sp]
  8352: 	ldp	x19, x20, [sp, #80]
  8356: 	ldp	x21, x22, [sp, #64]
  8360: 	ldp	x23, x24, [sp, #48]
  8364: 	ldp	x25, x26, [sp, #32]
  8368: 	ldr	x27, [sp, #24]
  8372: 	add	sp, sp, #96
  8376: 	ret
  8380: 	fmov	d0, d2
  8384: 	fmov	x0, d0
  8388: 	lsr	x3, x0, #48
  8392: 	mov	x10, #65521                     // =0xfff1
  8396: 	cmp	x3, x10
  8400: 	b.lo	#8
  8404: 	orr	x0, xzr, #0x7ff8000000000000
  8408: 	str	x0, [x19, #48]
  8412: 	fmov	d0, d3
  8416: 	fmov	x0, d0
  8420: 	lsr	x3, x0, #48
  8424: 	mov	x10, #65521                     // =0xfff1
  8428: 	cmp	x3, x10
  8432: 	b.lo	#8
  8436: 	orr	x0, xzr, #0x7ff8000000000000
  8440: 	str	x0, [x19, #56]
  8444: 	mov	x0, x6
  8448: 	and	x0, x0, #0xffffffffffff
  8452: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8456: 	orr	x0, x0, x10
  8460: 	str	x0, [x19, #64]
  8464: 	mov	x0, x7
  8468: 	and	x0, x0, #0xffffffffffff
  8472: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8476: 	orr	x0, x0, x10
  8480: 	str	x0, [x19, #72]
  8484: 	fmov	d0, d4
  8488: 	fmov	x0, d0
  8492: 	lsr	x3, x0, #48
  8496: 	mov	x10, #65521                     // =0xfff1
  8500: 	cmp	x3, x10
  8504: 	b.lo	#8
  8508: 	orr	x0, xzr, #0x7ff8000000000000
  8512: 	str	x0, [x19, #80]
  8516: 	mov	x0, x21
  8520: 	and	x0, x0, #0xffffffffffff
  8524: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8528: 	orr	x0, x0, x10
  8532: 	str	x0, [x19, #88]
  8536: 	mov	x0, x5
  8540: 	and	x0, x0, #0xffffffffffff
  8544: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8548: 	orr	x0, x0, x10
  8552: 	str	x0, [x19, #96]
  8556: 	fmov	d0, d7
  8560: 	fmov	x0, d0
  8564: 	lsr	x3, x0, #48
  8568: 	mov	x10, #65521                     // =0xfff1
  8572: 	cmp	x3, x10
  8576: 	b.lo	#8
  8580: 	orr	x0, xzr, #0x7ff8000000000000
  8584: 	str	x0, [x19, #104]
  8588: 	fmov	d0, d16
  8592: 	fmov	x0, d0
  8596: 	lsr	x3, x0, #48
  8600: 	mov	x10, #65521                     // =0xfff1
  8604: 	cmp	x3, x10
  8608: 	b.lo	#8
  8612: 	orr	x0, xzr, #0x7ff8000000000000
  8616: 	str	x0, [x19, #112]
  8620: 	mov	x0, x23
  8624: 	and	x0, x0, #0xffffffffffff
  8628: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8632: 	orr	x0, x0, x10
  8636: 	str	x0, [x19, #120]
  8640: 	mov	x0, x22
  8644: 	and	x0, x0, #0xffffffffffff
  8648: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8652: 	orr	x0, x0, x10
  8656: 	str	x0, [x19, #128]
  8660: 	ldr	x0, [x19, #936]
  8664: 	and	x0, x0, #0xffffffffffff
  8668: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8672: 	orr	x0, x0, x10
  8676: 	str	x0, [x19, #136]
  8680: 	ldr	x0, [x19, #944]
  8684: 	and	x0, x0, #0xffffffffffff
  8688: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8692: 	orr	x0, x0, x10
  8696: 	str	x0, [x19, #144]
  8700: 	fmov	d0, d6
  8704: 	fmov	x0, d0
  8708: 	lsr	x3, x0, #48
  8712: 	mov	x10, #65521                     // =0xfff1
  8716: 	cmp	x3, x10
  8720: 	b.lo	#8
  8724: 	orr	x0, xzr, #0x7ff8000000000000
  8728: 	str	x0, [x19, #152]
  8732: 	ldr	d0, [x19, #960]
  8736: 	fmov	x0, d0
  8740: 	lsr	x3, x0, #48
  8744: 	mov	x10, #65521                     // =0xfff1
  8748: 	cmp	x3, x10
  8752: 	b.lo	#8
  8756: 	orr	x0, xzr, #0x7ff8000000000000
  8760: 	str	x0, [x19, #160]
  8764: 	ldr	d0, [x19, #976]
  8768: 	fmov	x0, d0
  8772: 	lsr	x3, x0, #48
  8776: 	mov	x10, #65521                     // =0xfff1
  8780: 	cmp	x3, x10
  8784: 	b.lo	#8
  8788: 	orr	x0, xzr, #0x7ff8000000000000
  8792: 	str	x0, [x19, #168]
  8796: 	ldr	d0, [x19, #992]
  8800: 	fmov	x0, d0
  8804: 	lsr	x3, x0, #48
  8808: 	mov	x10, #65521                     // =0xfff1
  8812: 	cmp	x3, x10
  8816: 	b.lo	#8
  8820: 	orr	x0, xzr, #0x7ff8000000000000
  8824: 	str	x0, [x19, #176]
  8828: 	ldr	d0, [x19, #1016]
  8832: 	fmov	x0, d0
  8836: 	lsr	x3, x0, #48
  8840: 	mov	x10, #65521                     // =0xfff1
  8844: 	cmp	x3, x10
  8848: 	b.lo	#8
  8852: 	orr	x0, xzr, #0x7ff8000000000000
  8856: 	str	x0, [x19, #184]
  8860: 	ldr	d0, [x19, #1040]
  8864: 	fmov	x0, d0
  8868: 	lsr	x3, x0, #48
  8872: 	mov	x10, #65521                     // =0xfff1
  8876: 	cmp	x3, x10
  8880: 	b.lo	#8
  8884: 	orr	x0, xzr, #0x7ff8000000000000
  8888: 	str	x0, [x19, #192]
  8892: 	mov	x0, x21
  8896: 	and	x0, x0, #0xffffffffffff
  8900: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8904: 	orr	x0, x0, x10
  8908: 	str	x0, [x19, #200]
  8912: 	fmov	d0, d17
  8916: 	fmov	x0, d0
  8920: 	lsr	x3, x0, #48
  8924: 	mov	x10, #65521                     // =0xfff1
  8928: 	cmp	x3, x10
  8932: 	b.lo	#8
  8936: 	orr	x0, xzr, #0x7ff8000000000000
  8940: 	str	x0, [x19, #208]
  8944: 	ldr	d0, [x19, #1048]
  8948: 	fmov	x0, d0
  8952: 	lsr	x3, x0, #48
  8956: 	mov	x10, #65521                     // =0xfff1
  8960: 	cmp	x3, x10
  8964: 	b.lo	#8
  8968: 	orr	x0, xzr, #0x7ff8000000000000
  8972: 	str	x0, [x19, #216]
  8976: 	ldr	d0, [x19, #1064]
  8980: 	fmov	x0, d0
  8984: 	lsr	x3, x0, #48
  8988: 	mov	x10, #65521                     // =0xfff1
  8992: 	cmp	x3, x10
  8996: 	b.lo	#8
  9000: 	orr	x0, xzr, #0x7ff8000000000000
  9004: 	str	x0, [x19, #224]
  9008: 	ldr	d0, [x19, #1104]
  9012: 	fmov	x0, d0
  9016: 	lsr	x3, x0, #48
  9020: 	mov	x10, #65521                     // =0xfff1
  9024: 	cmp	x3, x10
  9028: 	b.lo	#8
  9032: 	orr	x0, xzr, #0x7ff8000000000000
  9036: 	str	x0, [x19, #232]
  9040: 	ldr	d0, [x19, #1080]
  9044: 	fmov	x0, d0
  9048: 	lsr	x3, x0, #48
  9052: 	mov	x10, #65521                     // =0xfff1
  9056: 	cmp	x3, x10
  9060: 	b.lo	#8
  9064: 	orr	x0, xzr, #0x7ff8000000000000
  9068: 	str	x0, [x19, #240]
  9072: 	fmov	d0, d5
  9076: 	fmov	x0, d0
  9080: 	lsr	x3, x0, #48
  9084: 	mov	x10, #65521                     // =0xfff1
  9088: 	cmp	x3, x10
  9092: 	b.lo	#8
  9096: 	orr	x0, xzr, #0x7ff8000000000000
  9100: 	str	x0, [x19, #248]
  9104: 	ldr	d0, [x19, #1112]
  9108: 	fmov	x0, d0
  9112: 	lsr	x3, x0, #48
  9116: 	mov	x10, #65521                     // =0xfff1
  9120: 	cmp	x3, x10
  9124: 	b.lo	#8
  9128: 	orr	x0, xzr, #0x7ff8000000000000
  9132: 	str	x0, [x19, #256]
  9136: 	ldr	d0, [x19, #1128]
  9140: 	fmov	x0, d0
  9144: 	lsr	x3, x0, #48
  9148: 	mov	x10, #65521                     // =0xfff1
  9152: 	cmp	x3, x10
  9156: 	b.lo	#8
  9160: 	orr	x0, xzr, #0x7ff8000000000000
  9164: 	str	x0, [x19, #264]
  9168: 	ldr	d0, [x19, #1144]
  9172: 	fmov	x0, d0
  9176: 	lsr	x3, x0, #48
  9180: 	mov	x10, #65521                     // =0xfff1
  9184: 	cmp	x3, x10
  9188: 	b.lo	#8
  9192: 	orr	x0, xzr, #0x7ff8000000000000
  9196: 	str	x0, [x19, #272]
  9200: 	ldr	d0, [x19, #1152]
  9204: 	fmov	x0, d0
  9208: 	lsr	x3, x0, #48
  9212: 	mov	x10, #65521                     // =0xfff1
  9216: 	cmp	x3, x10
  9220: 	b.lo	#8
  9224: 	orr	x0, xzr, #0x7ff8000000000000
  9228: 	str	x0, [x19, #280]
  9232: 	ldr	d0, [x19, #1160]
  9236: 	fmov	x0, d0
  9240: 	lsr	x3, x0, #48
  9244: 	mov	x10, #65521                     // =0xfff1
  9248: 	cmp	x3, x10
  9252: 	b.lo	#8
  9256: 	orr	x0, xzr, #0x7ff8000000000000
  9260: 	str	x0, [x19, #288]
  9264: 	mov	x9, #137438953408               // =0x1fffffffc0
  9268: 	str	x9, [x19, #912]
  9272: 	str	x20, [x19, #920]
  9276: 	mov	x0, #62                         // =0x3e
  9280: 	ldp	x29, x30, [sp]
  9284: 	ldp	x19, x20, [sp, #80]
  9288: 	ldp	x21, x22, [sp, #64]
  9292: 	ldp	x23, x24, [sp, #48]
  9296: 	ldp	x25, x26, [sp, #32]
  9300: 	ldr	x27, [sp, #24]
  9304: 	add	sp, sp, #96
  9308: 	ret
  9312: 	fmov	d0, d2
  9316: 	fmov	x0, d0
  9320: 	lsr	x3, x0, #48
  9324: 	mov	x10, #65521                     // =0xfff1
  9328: 	cmp	x3, x10
  9332: 	b.lo	#8
  9336: 	orr	x0, xzr, #0x7ff8000000000000
  9340: 	str	x0, [x19, #48]
  9344: 	fmov	d0, d3
  9348: 	fmov	x0, d0
  9352: 	lsr	x3, x0, #48
  9356: 	mov	x10, #65521                     // =0xfff1
  9360: 	cmp	x3, x10
  9364: 	b.lo	#8
  9368: 	orr	x0, xzr, #0x7ff8000000000000
  9372: 	str	x0, [x19, #56]
  9376: 	mov	x0, x6
  9380: 	and	x0, x0, #0xffffffffffff
  9384: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9388: 	orr	x0, x0, x10
  9392: 	str	x0, [x19, #64]
  9396: 	mov	x0, x7
  9400: 	and	x0, x0, #0xffffffffffff
  9404: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9408: 	orr	x0, x0, x10
  9412: 	str	x0, [x19, #72]
  9416: 	fmov	d0, d4
  9420: 	fmov	x0, d0
  9424: 	lsr	x3, x0, #48
  9428: 	mov	x10, #65521                     // =0xfff1
  9432: 	cmp	x3, x10
  9436: 	b.lo	#8
  9440: 	orr	x0, xzr, #0x7ff8000000000000
  9444: 	str	x0, [x19, #80]
  9448: 	mov	x0, x21
  9452: 	and	x0, x0, #0xffffffffffff
  9456: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9460: 	orr	x0, x0, x10
  9464: 	str	x0, [x19, #88]
  9468: 	mov	x0, x5
  9472: 	and	x0, x0, #0xffffffffffff
  9476: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9480: 	orr	x0, x0, x10
  9484: 	str	x0, [x19, #96]
  9488: 	fmov	d0, d7
  9492: 	fmov	x0, d0
  9496: 	lsr	x3, x0, #48
  9500: 	mov	x10, #65521                     // =0xfff1
  9504: 	cmp	x3, x10
  9508: 	b.lo	#8
  9512: 	orr	x0, xzr, #0x7ff8000000000000
  9516: 	str	x0, [x19, #104]
  9520: 	fmov	d0, d16
  9524: 	fmov	x0, d0
  9528: 	lsr	x3, x0, #48
  9532: 	mov	x10, #65521                     // =0xfff1
  9536: 	cmp	x3, x10
  9540: 	b.lo	#8
  9544: 	orr	x0, xzr, #0x7ff8000000000000
  9548: 	str	x0, [x19, #112]
  9552: 	mov	x0, x23
  9556: 	and	x0, x0, #0xffffffffffff
  9560: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9564: 	orr	x0, x0, x10
  9568: 	str	x0, [x19, #120]
  9572: 	mov	x0, x22
  9576: 	and	x0, x0, #0xffffffffffff
  9580: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9584: 	orr	x0, x0, x10
  9588: 	str	x0, [x19, #128]
  9592: 	ldr	x0, [x19, #936]
  9596: 	and	x0, x0, #0xffffffffffff
  9600: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9604: 	orr	x0, x0, x10
  9608: 	str	x0, [x19, #136]
  9612: 	ldr	x0, [x19, #944]
  9616: 	and	x0, x0, #0xffffffffffff
  9620: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9624: 	orr	x0, x0, x10
  9628: 	str	x0, [x19, #144]
  9632: 	fmov	d0, d6
  9636: 	fmov	x0, d0
  9640: 	lsr	x3, x0, #48
  9644: 	mov	x10, #65521                     // =0xfff1
  9648: 	cmp	x3, x10
  9652: 	b.lo	#8
  9656: 	orr	x0, xzr, #0x7ff8000000000000
  9660: 	str	x0, [x19, #152]
  9664: 	ldr	d0, [x19, #960]
  9668: 	fmov	x0, d0
  9672: 	lsr	x3, x0, #48
  9676: 	mov	x10, #65521                     // =0xfff1
  9680: 	cmp	x3, x10
  9684: 	b.lo	#8
  9688: 	orr	x0, xzr, #0x7ff8000000000000
  9692: 	str	x0, [x19, #160]
  9696: 	ldr	d0, [x19, #976]
  9700: 	fmov	x0, d0
  9704: 	lsr	x3, x0, #48
  9708: 	mov	x10, #65521                     // =0xfff1
  9712: 	cmp	x3, x10
  9716: 	b.lo	#8
  9720: 	orr	x0, xzr, #0x7ff8000000000000
  9724: 	str	x0, [x19, #168]
  9728: 	ldr	d0, [x19, #992]
  9732: 	fmov	x0, d0
  9736: 	lsr	x3, x0, #48
  9740: 	mov	x10, #65521                     // =0xfff1
  9744: 	cmp	x3, x10
  9748: 	b.lo	#8
  9752: 	orr	x0, xzr, #0x7ff8000000000000
  9756: 	str	x0, [x19, #176]
  9760: 	ldr	d0, [x19, #1016]
  9764: 	fmov	x0, d0
  9768: 	lsr	x3, x0, #48
  9772: 	mov	x10, #65521                     // =0xfff1
  9776: 	cmp	x3, x10
  9780: 	b.lo	#8
  9784: 	orr	x0, xzr, #0x7ff8000000000000
  9788: 	str	x0, [x19, #184]
  9792: 	ldr	d0, [x19, #1040]
  9796: 	fmov	x0, d0
  9800: 	lsr	x3, x0, #48
  9804: 	mov	x10, #65521                     // =0xfff1
  9808: 	cmp	x3, x10
  9812: 	b.lo	#8
  9816: 	orr	x0, xzr, #0x7ff8000000000000
  9820: 	str	x0, [x19, #192]
  9824: 	mov	x0, x21
  9828: 	and	x0, x0, #0xffffffffffff
  9832: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9836: 	orr	x0, x0, x10
  9840: 	str	x0, [x19, #200]
  9844: 	fmov	d0, d17
  9848: 	fmov	x0, d0
  9852: 	lsr	x3, x0, #48
  9856: 	mov	x10, #65521                     // =0xfff1
  9860: 	cmp	x3, x10
  9864: 	b.lo	#8
  9868: 	orr	x0, xzr, #0x7ff8000000000000
  9872: 	str	x0, [x19, #208]
  9876: 	ldr	d0, [x19, #1048]
  9880: 	fmov	x0, d0
  9884: 	lsr	x3, x0, #48
  9888: 	mov	x10, #65521                     // =0xfff1
  9892: 	cmp	x3, x10
  9896: 	b.lo	#8
  9900: 	orr	x0, xzr, #0x7ff8000000000000
  9904: 	str	x0, [x19, #216]
  9908: 	ldr	d0, [x19, #1064]
  9912: 	fmov	x0, d0
  9916: 	lsr	x3, x0, #48
  9920: 	mov	x10, #65521                     // =0xfff1
  9924: 	cmp	x3, x10
  9928: 	b.lo	#8
  9932: 	orr	x0, xzr, #0x7ff8000000000000
  9936: 	str	x0, [x19, #224]
  9940: 	ldr	d0, [x19, #1104]
  9944: 	fmov	x0, d0
  9948: 	lsr	x3, x0, #48
  9952: 	mov	x10, #65521                     // =0xfff1
  9956: 	cmp	x3, x10
  9960: 	b.lo	#8
  9964: 	orr	x0, xzr, #0x7ff8000000000000
  9968: 	str	x0, [x19, #232]
  9972: 	ldr	d0, [x19, #1080]
  9976: 	fmov	x0, d0
  9980: 	lsr	x3, x0, #48
  9984: 	mov	x10, #65521                     // =0xfff1
  9988: 	cmp	x3, x10
  9992: 	b.lo	#8
  9996: 	orr	x0, xzr, #0x7ff8000000000000
 10000: 	str	x0, [x19, #240]
 10004: 	fmov	d0, d5
 10008: 	fmov	x0, d0
 10012: 	lsr	x3, x0, #48
 10016: 	mov	x10, #65521                     // =0xfff1
 10020: 	cmp	x3, x10
 10024: 	b.lo	#8
 10028: 	orr	x0, xzr, #0x7ff8000000000000
 10032: 	str	x0, [x19, #248]
 10036: 	ldr	d0, [x19, #1208]
 10040: 	fmov	x0, d0
 10044: 	lsr	x3, x0, #48
 10048: 	mov	x10, #65521                     // =0xfff1
 10052: 	cmp	x3, x10
 10056: 	b.lo	#8
 10060: 	orr	x0, xzr, #0x7ff8000000000000
 10064: 	str	x0, [x19, #256]
 10068: 	ldr	d0, [x19, #1128]
 10072: 	fmov	x0, d0
 10076: 	lsr	x3, x0, #48
 10080: 	mov	x10, #65521                     // =0xfff1
 10084: 	cmp	x3, x10
 10088: 	b.lo	#8
 10092: 	orr	x0, xzr, #0x7ff8000000000000
 10096: 	str	x0, [x19, #264]
 10100: 	ldr	d0, [x19, #1144]
 10104: 	fmov	x0, d0
 10108: 	lsr	x3, x0, #48
 10112: 	mov	x10, #65521                     // =0xfff1
 10116: 	cmp	x3, x10
 10120: 	b.lo	#8
 10124: 	orr	x0, xzr, #0x7ff8000000000000
 10128: 	str	x0, [x19, #272]
 10132: 	ldr	d0, [x19, #1192]
 10136: 	fmov	x0, d0
 10140: 	lsr	x3, x0, #48
 10144: 	mov	x10, #65521                     // =0xfff1
 10148: 	cmp	x3, x10
 10152: 	b.lo	#8
 10156: 	orr	x0, xzr, #0x7ff8000000000000
 10160: 	str	x0, [x19, #280]
 10164: 	ldr	d0, [x19, #1160]
 10168: 	fmov	x0, d0
 10172: 	lsr	x3, x0, #48
 10176: 	mov	x10, #65521                     // =0xfff1
 10180: 	cmp	x3, x10
 10184: 	b.lo	#8
 10188: 	orr	x0, xzr, #0x7ff8000000000000
 10192: 	str	x0, [x19, #288]
 10196: 	ldr	d0, [x19, #1176]
 10200: 	fmov	x0, d0
 10204: 	lsr	x3, x0, #48
 10208: 	mov	x10, #65521                     // =0xfff1
 10212: 	cmp	x3, x10
 10216: 	b.lo	#8
 10220: 	orr	x0, xzr, #0x7ff8000000000000
 10224: 	str	x0, [x19, #296]
 10228: 	ldr	d0, [x19, #1200]
 10232: 	fmov	x0, d0
 10236: 	lsr	x3, x0, #48
 10240: 	mov	x10, #65521                     // =0xfff1
 10244: 	cmp	x3, x10
 10248: 	b.lo	#8
 10252: 	orr	x0, xzr, #0x7ff8000000000000
 10256: 	str	x0, [x19, #304]
 10260: 	mov	x9, #549755813824               // =0x7fffffffc0
 10264: 	str	x9, [x19, #912]
 10268: 	str	x20, [x19, #920]
 10272: 	mov	x0, #67                         // =0x43
 10276: 	ldp	x29, x30, [sp]
 10280: 	ldp	x19, x20, [sp, #80]
 10284: 	ldp	x21, x22, [sp, #64]
 10288: 	ldp	x23, x24, [sp, #48]
 10292: 	ldp	x25, x26, [sp, #32]
 10296: 	ldr	x27, [sp, #24]
 10300: 	add	sp, sp, #96
 10304: 	ret
 10308: 	fmov	d0, d2
 10312: 	fmov	x0, d0
 10316: 	lsr	x3, x0, #48
 10320: 	mov	x10, #65521                     // =0xfff1
 10324: 	cmp	x3, x10
 10328: 	b.lo	#8
 10332: 	orr	x0, xzr, #0x7ff8000000000000
 10336: 	str	x0, [x19, #48]
 10340: 	fmov	d0, d3
 10344: 	fmov	x0, d0
 10348: 	lsr	x3, x0, #48
 10352: 	mov	x10, #65521                     // =0xfff1
 10356: 	cmp	x3, x10
 10360: 	b.lo	#8
 10364: 	orr	x0, xzr, #0x7ff8000000000000
 10368: 	str	x0, [x19, #56]
 10372: 	mov	x0, x6
 10376: 	and	x0, x0, #0xffffffffffff
 10380: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10384: 	orr	x0, x0, x10
 10388: 	str	x0, [x19, #64]
 10392: 	mov	x0, x7
 10396: 	and	x0, x0, #0xffffffffffff
 10400: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10404: 	orr	x0, x0, x10
 10408: 	str	x0, [x19, #72]
 10412: 	fmov	d0, d4
 10416: 	fmov	x0, d0
 10420: 	lsr	x3, x0, #48
 10424: 	mov	x10, #65521                     // =0xfff1
 10428: 	cmp	x3, x10
 10432: 	b.lo	#8
 10436: 	orr	x0, xzr, #0x7ff8000000000000
 10440: 	str	x0, [x19, #80]
 10444: 	mov	x0, x21
 10448: 	and	x0, x0, #0xffffffffffff
 10452: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10456: 	orr	x0, x0, x10
 10460: 	str	x0, [x19, #88]
 10464: 	mov	x0, x5
 10468: 	and	x0, x0, #0xffffffffffff
 10472: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10476: 	orr	x0, x0, x10
 10480: 	str	x0, [x19, #96]
 10484: 	fmov	d0, d7
 10488: 	fmov	x0, d0
 10492: 	lsr	x3, x0, #48
 10496: 	mov	x10, #65521                     // =0xfff1
 10500: 	cmp	x3, x10
 10504: 	b.lo	#8
 10508: 	orr	x0, xzr, #0x7ff8000000000000
 10512: 	str	x0, [x19, #104]
 10516: 	fmov	d0, d16
 10520: 	fmov	x0, d0
 10524: 	lsr	x3, x0, #48
 10528: 	mov	x10, #65521                     // =0xfff1
 10532: 	cmp	x3, x10
 10536: 	b.lo	#8
 10540: 	orr	x0, xzr, #0x7ff8000000000000
 10544: 	str	x0, [x19, #112]
 10548: 	mov	x0, x23
 10552: 	and	x0, x0, #0xffffffffffff
 10556: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10560: 	orr	x0, x0, x10
 10564: 	str	x0, [x19, #120]
 10568: 	mov	x0, x22
 10572: 	and	x0, x0, #0xffffffffffff
 10576: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10580: 	orr	x0, x0, x10
 10584: 	str	x0, [x19, #128]
 10588: 	ldr	x0, [x19, #936]
 10592: 	and	x0, x0, #0xffffffffffff
 10596: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10600: 	orr	x0, x0, x10
 10604: 	str	x0, [x19, #136]
 10608: 	ldr	x0, [x19, #944]
 10612: 	and	x0, x0, #0xffffffffffff
 10616: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10620: 	orr	x0, x0, x10
 10624: 	str	x0, [x19, #144]
 10628: 	fmov	d0, d6
 10632: 	fmov	x0, d0
 10636: 	lsr	x3, x0, #48
 10640: 	mov	x10, #65521                     // =0xfff1
 10644: 	cmp	x3, x10
 10648: 	b.lo	#8
 10652: 	orr	x0, xzr, #0x7ff8000000000000
 10656: 	str	x0, [x19, #152]
 10660: 	ldr	d0, [x19, #960]
 10664: 	fmov	x0, d0
 10668: 	lsr	x3, x0, #48
 10672: 	mov	x10, #65521                     // =0xfff1
 10676: 	cmp	x3, x10
 10680: 	b.lo	#8
 10684: 	orr	x0, xzr, #0x7ff8000000000000
 10688: 	str	x0, [x19, #160]
 10692: 	ldr	d0, [x19, #976]
 10696: 	fmov	x0, d0
 10700: 	lsr	x3, x0, #48
 10704: 	mov	x10, #65521                     // =0xfff1
 10708: 	cmp	x3, x10
 10712: 	b.lo	#8
 10716: 	orr	x0, xzr, #0x7ff8000000000000
 10720: 	str	x0, [x19, #168]
 10724: 	ldr	d0, [x19, #992]
 10728: 	fmov	x0, d0
 10732: 	lsr	x3, x0, #48
 10736: 	mov	x10, #65521                     // =0xfff1
 10740: 	cmp	x3, x10
 10744: 	b.lo	#8
 10748: 	orr	x0, xzr, #0x7ff8000000000000
 10752: 	str	x0, [x19, #176]
 10756: 	ldr	d0, [x19, #1016]
 10760: 	fmov	x0, d0
 10764: 	lsr	x3, x0, #48
 10768: 	mov	x10, #65521                     // =0xfff1
 10772: 	cmp	x3, x10
 10776: 	b.lo	#8
 10780: 	orr	x0, xzr, #0x7ff8000000000000
 10784: 	str	x0, [x19, #184]
 10788: 	ldr	d0, [x19, #1040]
 10792: 	fmov	x0, d0
 10796: 	lsr	x3, x0, #48
 10800: 	mov	x10, #65521                     // =0xfff1
 10804: 	cmp	x3, x10
 10808: 	b.lo	#8
 10812: 	orr	x0, xzr, #0x7ff8000000000000
 10816: 	str	x0, [x19, #192]
 10820: 	mov	x0, x21
 10824: 	and	x0, x0, #0xffffffffffff
 10828: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10832: 	orr	x0, x0, x10
 10836: 	str	x0, [x19, #200]
 10840: 	fmov	d0, d17
 10844: 	fmov	x0, d0
 10848: 	lsr	x3, x0, #48
 10852: 	mov	x10, #65521                     // =0xfff1
 10856: 	cmp	x3, x10
 10860: 	b.lo	#8
 10864: 	orr	x0, xzr, #0x7ff8000000000000
 10868: 	str	x0, [x19, #208]
 10872: 	ldr	d0, [x19, #1048]
 10876: 	fmov	x0, d0
 10880: 	lsr	x3, x0, #48
 10884: 	mov	x10, #65521                     // =0xfff1
 10888: 	cmp	x3, x10
 10892: 	b.lo	#8
 10896: 	orr	x0, xzr, #0x7ff8000000000000
 10900: 	str	x0, [x19, #216]
 10904: 	ldr	d0, [x19, #1064]
 10908: 	fmov	x0, d0
 10912: 	lsr	x3, x0, #48
 10916: 	mov	x10, #65521                     // =0xfff1
 10920: 	cmp	x3, x10
 10924: 	b.lo	#8
 10928: 	orr	x0, xzr, #0x7ff8000000000000
 10932: 	str	x0, [x19, #224]
 10936: 	ldr	d0, [x19, #1104]
 10940: 	fmov	x0, d0
 10944: 	lsr	x3, x0, #48
 10948: 	mov	x10, #65521                     // =0xfff1
 10952: 	cmp	x3, x10
 10956: 	b.lo	#8
 10960: 	orr	x0, xzr, #0x7ff8000000000000
 10964: 	str	x0, [x19, #232]
 10968: 	ldr	d0, [x19, #1080]
 10972: 	fmov	x0, d0
 10976: 	lsr	x3, x0, #48
 10980: 	mov	x10, #65521                     // =0xfff1
 10984: 	cmp	x3, x10
 10988: 	b.lo	#8
 10992: 	orr	x0, xzr, #0x7ff8000000000000
 10996: 	str	x0, [x19, #240]
 11000: 	fmov	d0, d5
 11004: 	fmov	x0, d0
 11008: 	lsr	x3, x0, #48
 11012: 	mov	x10, #65521                     // =0xfff1
 11016: 	cmp	x3, x10
 11020: 	b.lo	#8
 11024: 	orr	x0, xzr, #0x7ff8000000000000
 11028: 	str	x0, [x19, #248]
 11032: 	ldr	d0, [x19, #1208]
 11036: 	fmov	x0, d0
 11040: 	lsr	x3, x0, #48
 11044: 	mov	x10, #65521                     // =0xfff1
 11048: 	cmp	x3, x10
 11052: 	b.lo	#8
 11056: 	orr	x0, xzr, #0x7ff8000000000000
 11060: 	str	x0, [x19, #256]
 11064: 	ldr	d0, [x19, #1128]
 11068: 	fmov	x0, d0
 11072: 	lsr	x3, x0, #48
 11076: 	mov	x10, #65521                     // =0xfff1
 11080: 	cmp	x3, x10
 11084: 	b.lo	#8
 11088: 	orr	x0, xzr, #0x7ff8000000000000
 11092: 	str	x0, [x19, #264]
 11096: 	ldr	d0, [x19, #1144]
 11100: 	fmov	x0, d0
 11104: 	lsr	x3, x0, #48
 11108: 	mov	x10, #65521                     // =0xfff1
 11112: 	cmp	x3, x10
 11116: 	b.lo	#8
 11120: 	orr	x0, xzr, #0x7ff8000000000000
 11124: 	str	x0, [x19, #272]
 11128: 	ldr	d0, [x19, #1192]
 11132: 	fmov	x0, d0
 11136: 	lsr	x3, x0, #48
 11140: 	mov	x10, #65521                     // =0xfff1
 11144: 	cmp	x3, x10
 11148: 	b.lo	#8
 11152: 	orr	x0, xzr, #0x7ff8000000000000
 11156: 	str	x0, [x19, #280]
 11160: 	ldr	d0, [x19, #1160]
 11164: 	fmov	x0, d0
 11168: 	lsr	x3, x0, #48
 11172: 	mov	x10, #65521                     // =0xfff1
 11176: 	cmp	x3, x10
 11180: 	b.lo	#8
 11184: 	orr	x0, xzr, #0x7ff8000000000000
 11188: 	str	x0, [x19, #288]
 11192: 	ldr	d0, [x19, #1176]
 11196: 	fmov	x0, d0
 11200: 	lsr	x3, x0, #48
 11204: 	mov	x10, #65521                     // =0xfff1
 11208: 	cmp	x3, x10
 11212: 	b.lo	#8
 11216: 	orr	x0, xzr, #0x7ff8000000000000
 11220: 	str	x0, [x19, #296]
 11224: 	ldr	d0, [x19, #1200]
 11228: 	fmov	x0, d0
 11232: 	lsr	x3, x0, #48
 11236: 	mov	x10, #65521                     // =0xfff1
 11240: 	cmp	x3, x10
 11244: 	b.lo	#8
 11248: 	orr	x0, xzr, #0x7ff8000000000000
 11252: 	str	x0, [x19, #304]
 11256: 	mov	x9, #549755813824               // =0x7fffffffc0
 11260: 	str	x9, [x19, #912]
 11264: 	str	x20, [x19, #920]
 11268: 	mov	x0, #68                         // =0x44
 11272: 	ldp	x29, x30, [sp]
 11276: 	ldp	x19, x20, [sp, #80]
 11280: 	ldp	x21, x22, [sp, #64]
 11284: 	ldp	x23, x24, [sp, #48]
 11288: 	ldp	x25, x26, [sp, #32]
 11292: 	ldr	x27, [sp, #24]
 11296: 	add	sp, sp, #96
 11300: 	ret
 11304: 	fmov	d0, d2
 11308: 	fmov	x0, d0
 11312: 	lsr	x3, x0, #48
 11316: 	mov	x10, #65521                     // =0xfff1
 11320: 	cmp	x3, x10
 11324: 	b.lo	#8
 11328: 	orr	x0, xzr, #0x7ff8000000000000
 11332: 	str	x0, [x19, #48]
 11336: 	fmov	d0, d3
 11340: 	fmov	x0, d0
 11344: 	lsr	x3, x0, #48
 11348: 	mov	x10, #65521                     // =0xfff1
 11352: 	cmp	x3, x10
 11356: 	b.lo	#8
 11360: 	orr	x0, xzr, #0x7ff8000000000000
 11364: 	str	x0, [x19, #56]
 11368: 	mov	x0, x6
 11372: 	and	x0, x0, #0xffffffffffff
 11376: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11380: 	orr	x0, x0, x10
 11384: 	str	x0, [x19, #64]
 11388: 	mov	x0, x7
 11392: 	and	x0, x0, #0xffffffffffff
 11396: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11400: 	orr	x0, x0, x10
 11404: 	str	x0, [x19, #72]
 11408: 	fmov	d0, d4
 11412: 	fmov	x0, d0
 11416: 	lsr	x3, x0, #48
 11420: 	mov	x10, #65521                     // =0xfff1
 11424: 	cmp	x3, x10
 11428: 	b.lo	#8
 11432: 	orr	x0, xzr, #0x7ff8000000000000
 11436: 	str	x0, [x19, #80]
 11440: 	mov	x0, x21
 11444: 	and	x0, x0, #0xffffffffffff
 11448: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11452: 	orr	x0, x0, x10
 11456: 	str	x0, [x19, #88]
 11460: 	ldr	x0, [x19, #1224]
 11464: 	and	x0, x0, #0xffffffffffff
 11468: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11472: 	orr	x0, x0, x10
 11476: 	str	x0, [x19, #96]
 11480: 	fmov	d0, d7
 11484: 	fmov	x0, d0
 11488: 	lsr	x3, x0, #48
 11492: 	mov	x10, #65521                     // =0xfff1
 11496: 	cmp	x3, x10
 11500: 	b.lo	#8
 11504: 	orr	x0, xzr, #0x7ff8000000000000
 11508: 	str	x0, [x19, #104]
 11512: 	fmov	d0, d16
 11516: 	fmov	x0, d0
 11520: 	lsr	x3, x0, #48
 11524: 	mov	x10, #65521                     // =0xfff1
 11528: 	cmp	x3, x10
 11532: 	b.lo	#8
 11536: 	orr	x0, xzr, #0x7ff8000000000000
 11540: 	str	x0, [x19, #112]
 11544: 	mov	x0, x23
 11548: 	and	x0, x0, #0xffffffffffff
 11552: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11556: 	orr	x0, x0, x10
 11560: 	str	x0, [x19, #120]
 11564: 	mov	x0, x22
 11568: 	and	x0, x0, #0xffffffffffff
 11572: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11576: 	orr	x0, x0, x10
 11580: 	str	x0, [x19, #128]
 11584: 	ldr	x0, [x19, #936]
 11588: 	and	x0, x0, #0xffffffffffff
 11592: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11596: 	orr	x0, x0, x10
 11600: 	str	x0, [x19, #136]
 11604: 	ldr	x0, [x19, #944]
 11608: 	and	x0, x0, #0xffffffffffff
 11612: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11616: 	orr	x0, x0, x10
 11620: 	str	x0, [x19, #144]
 11624: 	fmov	d0, d6
 11628: 	fmov	x0, d0
 11632: 	lsr	x3, x0, #48
 11636: 	mov	x10, #65521                     // =0xfff1
 11640: 	cmp	x3, x10
 11644: 	b.lo	#8
 11648: 	orr	x0, xzr, #0x7ff8000000000000
 11652: 	str	x0, [x19, #152]
 11656: 	ldr	d0, [x19, #960]
 11660: 	fmov	x0, d0
 11664: 	lsr	x3, x0, #48
 11668: 	mov	x10, #65521                     // =0xfff1
 11672: 	cmp	x3, x10
 11676: 	b.lo	#8
 11680: 	orr	x0, xzr, #0x7ff8000000000000
 11684: 	str	x0, [x19, #160]
 11688: 	ldr	d0, [x19, #976]
 11692: 	fmov	x0, d0
 11696: 	lsr	x3, x0, #48
 11700: 	mov	x10, #65521                     // =0xfff1
 11704: 	cmp	x3, x10
 11708: 	b.lo	#8
 11712: 	orr	x0, xzr, #0x7ff8000000000000
 11716: 	str	x0, [x19, #168]
 11720: 	ldr	d0, [x19, #992]
 11724: 	fmov	x0, d0
 11728: 	lsr	x3, x0, #48
 11732: 	mov	x10, #65521                     // =0xfff1
 11736: 	cmp	x3, x10
 11740: 	b.lo	#8
 11744: 	orr	x0, xzr, #0x7ff8000000000000
 11748: 	str	x0, [x19, #176]
 11752: 	ldr	d0, [x19, #1016]
 11756: 	fmov	x0, d0
 11760: 	lsr	x3, x0, #48
 11764: 	mov	x10, #65521                     // =0xfff1
 11768: 	cmp	x3, x10
 11772: 	b.lo	#8
 11776: 	orr	x0, xzr, #0x7ff8000000000000
 11780: 	str	x0, [x19, #184]
 11784: 	ldr	d0, [x19, #1040]
 11788: 	fmov	x0, d0
 11792: 	lsr	x3, x0, #48
 11796: 	mov	x10, #65521                     // =0xfff1
 11800: 	cmp	x3, x10
 11804: 	b.lo	#8
 11808: 	orr	x0, xzr, #0x7ff8000000000000
 11812: 	str	x0, [x19, #192]
 11816: 	ldr	x0, [x19, #1232]
 11820: 	str	x0, [x19, #200]
 11824: 	fmov	d0, d17
 11828: 	fmov	x0, d0
 11832: 	lsr	x3, x0, #48
 11836: 	mov	x10, #65521                     // =0xfff1
 11840: 	cmp	x3, x10
 11844: 	b.lo	#8
 11848: 	orr	x0, xzr, #0x7ff8000000000000
 11852: 	str	x0, [x19, #208]
 11856: 	ldr	d0, [x19, #1048]
 11860: 	fmov	x0, d0
 11864: 	lsr	x3, x0, #48
 11868: 	mov	x10, #65521                     // =0xfff1
 11872: 	cmp	x3, x10
 11876: 	b.lo	#8
 11880: 	orr	x0, xzr, #0x7ff8000000000000
 11884: 	str	x0, [x19, #216]
 11888: 	ldr	d0, [x19, #1064]
 11892: 	fmov	x0, d0
 11896: 	lsr	x3, x0, #48
 11900: 	mov	x10, #65521                     // =0xfff1
 11904: 	cmp	x3, x10
 11908: 	b.lo	#8
 11912: 	orr	x0, xzr, #0x7ff8000000000000
 11916: 	str	x0, [x19, #224]
 11920: 	ldr	d0, [x19, #1104]
 11924: 	fmov	x0, d0
 11928: 	lsr	x3, x0, #48
 11932: 	mov	x10, #65521                     // =0xfff1
 11936: 	cmp	x3, x10
 11940: 	b.lo	#8
 11944: 	orr	x0, xzr, #0x7ff8000000000000
 11948: 	str	x0, [x19, #232]
 11952: 	ldr	d0, [x19, #1080]
 11956: 	fmov	x0, d0
 11960: 	lsr	x3, x0, #48
 11964: 	mov	x10, #65521                     // =0xfff1
 11968: 	cmp	x3, x10
 11972: 	b.lo	#8
 11976: 	orr	x0, xzr, #0x7ff8000000000000
 11980: 	str	x0, [x19, #240]
 11984: 	fmov	d0, d5
 11988: 	fmov	x0, d0
 11992: 	lsr	x3, x0, #48
 11996: 	mov	x10, #65521                     // =0xfff1
 12000: 	cmp	x3, x10
 12004: 	b.lo	#8
 12008: 	orr	x0, xzr, #0x7ff8000000000000
 12012: 	str	x0, [x19, #248]
 12016: 	ldr	d0, [x19, #1208]
 12020: 	fmov	x0, d0
 12024: 	lsr	x3, x0, #48
 12028: 	mov	x10, #65521                     // =0xfff1
 12032: 	cmp	x3, x10
 12036: 	b.lo	#8
 12040: 	orr	x0, xzr, #0x7ff8000000000000
 12044: 	str	x0, [x19, #256]
 12048: 	ldr	d0, [x19, #1128]
 12052: 	fmov	x0, d0
 12056: 	lsr	x3, x0, #48
 12060: 	mov	x10, #65521                     // =0xfff1
 12064: 	cmp	x3, x10
 12068: 	b.lo	#8
 12072: 	orr	x0, xzr, #0x7ff8000000000000
 12076: 	str	x0, [x19, #264]
 12080: 	ldr	d0, [x19, #1144]
 12084: 	fmov	x0, d0
 12088: 	lsr	x3, x0, #48
 12092: 	mov	x10, #65521                     // =0xfff1
 12096: 	cmp	x3, x10
 12100: 	b.lo	#8
 12104: 	orr	x0, xzr, #0x7ff8000000000000
 12108: 	str	x0, [x19, #272]
 12112: 	ldr	d0, [x19, #1192]
 12116: 	fmov	x0, d0
 12120: 	lsr	x3, x0, #48
 12124: 	mov	x10, #65521                     // =0xfff1
 12128: 	cmp	x3, x10
 12132: 	b.lo	#8
 12136: 	orr	x0, xzr, #0x7ff8000000000000
 12140: 	str	x0, [x19, #280]
 12144: 	ldr	d0, [x19, #1160]
 12148: 	fmov	x0, d0
 12152: 	lsr	x3, x0, #48
 12156: 	mov	x10, #65521                     // =0xfff1
 12160: 	cmp	x3, x10
 12164: 	b.lo	#8
 12168: 	orr	x0, xzr, #0x7ff8000000000000
 12172: 	str	x0, [x19, #288]
 12176: 	ldr	d0, [x19, #1176]
 12180: 	fmov	x0, d0
 12184: 	lsr	x3, x0, #48
 12188: 	mov	x10, #65521                     // =0xfff1
 12192: 	cmp	x3, x10
 12196: 	b.lo	#8
 12200: 	orr	x0, xzr, #0x7ff8000000000000
 12204: 	str	x0, [x19, #296]
 12208: 	ldr	d0, [x19, #1200]
 12212: 	fmov	x0, d0
 12216: 	lsr	x3, x0, #48
 12220: 	mov	x10, #65521                     // =0xfff1
 12224: 	cmp	x3, x10
 12228: 	b.lo	#8
 12232: 	orr	x0, xzr, #0x7ff8000000000000
 12236: 	str	x0, [x19, #304]
 12240: 	mov	x9, #549755813824               // =0x7fffffffc0
 12244: 	str	x9, [x19, #912]
 12248: 	str	x20, [x19, #920]
 12252: 	mov	x0, #70                         // =0x46
 12256: 	ldp	x29, x30, [sp]
 12260: 	ldp	x19, x20, [sp, #80]
 12264: 	ldp	x21, x22, [sp, #64]
 12268: 	ldp	x23, x24, [sp, #48]
 12272: 	ldp	x25, x26, [sp, #32]
 12276: 	ldr	x27, [sp, #24]
 12280: 	add	sp, sp, #96
 12284: 	ret
 12288: 	mov	x0, x21
 12292: 	and	x0, x0, #0xffffffffffff
 12296: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 12300: 	orr	x0, x0, x10
 12304: 	str	x0, [x19, #88]
 12308: 	ldr	x0, [x19, #1224]
 12312: 	and	x0, x0, #0xffffffffffff
 12316: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 12320: 	orr	x0, x0, x10
 12324: 	str	x0, [x19, #96]
 12328: 	ldr	x0, [x19, #1232]
 12332: 	str	x0, [x19, #200]
 12336: 	mov	x9, #6144                       // =0x1800
 12340: 	movk	x9, #512, lsl #16
 12344: 	str	x9, [x19, #912]
 12348: 	str	x20, [x19, #920]
 12352: 	mov	x0, #70                         // =0x46
 12356: 	ldp	x29, x30, [sp]
 12360: 	ldp	x19, x20, [sp, #80]
 12364: 	ldp	x21, x22, [sp, #64]
 12368: 	ldp	x23, x24, [sp, #48]
 12372: 	ldp	x25, x26, [sp, #32]
 12376: 	ldr	x27, [sp, #24]
 12380: 	add	sp, sp, #96
 12384: 	ret
