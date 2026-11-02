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
    48: 	b.ne	#2720
    52: 	ldr	x24, [x19, #544]
    56: 	ldr	x25, [x19, #536]
    60: 	ldr	x0, [x19, #32]
    64: 	ldr	x10, [x19, #560]
    68: 	cmp	x0, x10
    72: 	b.ne	#2696
    76: 	ldr	x26, [x19, #576]
    80: 	ldr	x27, [x19, #568]
    84: 	ldr	x0, [x19, #16]
    88: 	ldr	x10, [x19, #592]
    92: 	cmp	x0, x10
    96: 	b.ne	#2672
   100: 	ldr	x0, [x19, #8]
   104: 	ldr	x10, [x19, #624]
   108: 	cmp	x0, x10
   112: 	b.ne	#2656
   116: 	ldr	x0, [x19, #48]
   120: 	lsr	x3, x0, #48
   124: 	mov	x10, #65521                     // =0xfff1
   128: 	cmp	x3, x10
   132: 	b.hi	#2636
   136: 	mov	x10, #65521                     // =0xfff1
   140: 	cmp	x3, x10
   144: 	b.ne	#20
   148: 	lsl	x0, x0, #16
   152: 	asr	x0, x0, #16
   156: 	scvtf	d0, x0
   160: 	b	#8
   164: 	fmov	d0, x0
   168: 	fmov	d3, d0
   172: 	ldr	x0, [x19, #56]
   176: 	lsr	x3, x0, #48
   180: 	mov	x10, #65521                     // =0xfff1
   184: 	cmp	x3, x10
   188: 	b.hi	#2580
   192: 	mov	x10, #65521                     // =0xfff1
   196: 	cmp	x3, x10
   200: 	b.ne	#20
   204: 	lsl	x0, x0, #16
   208: 	asr	x0, x0, #16
   212: 	scvtf	d0, x0
   216: 	b	#8
   220: 	fmov	d0, x0
   224: 	fmov	d4, d0
   228: 	ldr	x0, [x19, #64]
   232: 	lsr	x3, x0, #48
   236: 	mov	x10, #65521                     // =0xfff1
   240: 	cmp	x3, x10
   244: 	b.eq	#104
   248: 	mov	x10, #65521                     // =0xfff1
   252: 	cmp	x3, x10
   256: 	b.hi	#2512
   260: 	fmov	d0, x0
   264: 	fcmp	d0, d0
   268: 	b.vs	#2500
   272: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   276: 	fmov	d1, x1
   280: 	fcmp	d0, d1
   284: 	b.mi	#2484
   288: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   292: 	fmov	d1, x1
   296: 	fcmp	d0, d1
   300: 	b.ge	#2468
   304: 	lsl	x3, x0, #1
   308: 	cbnz	x3, #12
   312: 	cmp	x0, #0
   316: 	b.lt	#2452
   320: 	fcvtzs	x0, d0
   324: 	scvtf	d1, x0
   328: 	fcmp	d0, d1
   332: 	cset	x9, ne
   336: 	ccmp	x9, #0, #4, vc
   340: 	b.ne	#2428
   344: 	b	#28
   348: 	sxtw	x3, w0
   352: 	lsl	x1, x0, #16
   356: 	asr	x1, x1, #16
   360: 	cmp	x1, x3
   364: 	b.ne	#2404
   368: 	mov	x0, x1
   372: 	mov	x5, x0
   376: 	ldr	x0, [x19, #72]
   380: 	lsr	x3, x0, #48
   384: 	mov	x10, #65521                     // =0xfff1
   388: 	cmp	x3, x10
   392: 	b.eq	#104
   396: 	mov	x10, #65521                     // =0xfff1
   400: 	cmp	x3, x10
   404: 	b.hi	#2364
   408: 	fmov	d0, x0
   412: 	fcmp	d0, d0
   416: 	b.vs	#2352
   420: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   424: 	fmov	d1, x1
   428: 	fcmp	d0, d1
   432: 	b.mi	#2336
   436: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   440: 	fmov	d1, x1
   444: 	fcmp	d0, d1
   448: 	b.ge	#2320
   452: 	lsl	x3, x0, #1
   456: 	cbnz	x3, #12
   460: 	cmp	x0, #0
   464: 	b.lt	#2304
   468: 	fcvtzs	x0, d0
   472: 	scvtf	d1, x0
   476: 	fcmp	d0, d1
   480: 	cset	x9, ne
   484: 	ccmp	x9, #0, #4, vc
   488: 	b.ne	#2280
   492: 	b	#28
   496: 	sxtw	x3, w0
   500: 	lsl	x1, x0, #16
   504: 	asr	x1, x1, #16
   508: 	cmp	x1, x3
   512: 	b.ne	#2256
   516: 	mov	x0, x1
   520: 	mov	x6, x0
   524: 	ldr	x0, [x19, #80]
   528: 	lsr	x3, x0, #48
   532: 	mov	x10, #65521                     // =0xfff1
   536: 	cmp	x3, x10
   540: 	b.hi	#2228
   544: 	mov	x10, #65521                     // =0xfff1
   548: 	cmp	x3, x10
   552: 	b.ne	#20
   556: 	lsl	x0, x0, #16
   560: 	asr	x0, x0, #16
   564: 	scvtf	d0, x0
   568: 	b	#8
   572: 	fmov	d0, x0
   576: 	fmov	d5, d0
   580: 	ldr	x0, [x19, #88]
   584: 	lsr	x3, x0, #48
   588: 	mov	x10, #65521                     // =0xfff1
   592: 	cmp	x3, x10
   596: 	b.hi	#2172
   600: 	mov	x10, #65521                     // =0xfff1
   604: 	cmp	x3, x10
   608: 	b.ne	#20
   612: 	lsl	x0, x0, #16
   616: 	asr	x0, x0, #16
   620: 	scvtf	d0, x0
   624: 	b	#8
   628: 	fmov	d0, x0
   632: 	fmov	d2, d0
   636: 	ldr	x0, [x19, #96]
   640: 	lsr	x3, x0, #48
   644: 	mov	x10, #65521                     // =0xfff1
   648: 	cmp	x3, x10
   652: 	b.eq	#104
   656: 	mov	x10, #65521                     // =0xfff1
   660: 	cmp	x3, x10
   664: 	b.hi	#2104
   668: 	fmov	d0, x0
   672: 	fcmp	d0, d0
   676: 	b.vs	#2092
   680: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   684: 	fmov	d1, x1
   688: 	fcmp	d0, d1
   692: 	b.mi	#2076
   696: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   700: 	fmov	d1, x1
   704: 	fcmp	d0, d1
   708: 	b.ge	#2060
   712: 	lsl	x3, x0, #1
   716: 	cbnz	x3, #12
   720: 	cmp	x0, #0
   724: 	b.lt	#2044
   728: 	fcvtzs	x0, d0
   732: 	scvtf	d1, x0
   736: 	fcmp	d0, d1
   740: 	cset	x9, ne
   744: 	ccmp	x9, #0, #4, vc
   748: 	b.ne	#2020
   752: 	b	#28
   756: 	sxtw	x3, w0
   760: 	lsl	x1, x0, #16
   764: 	asr	x1, x1, #16
   768: 	cmp	x1, x3
   772: 	b.ne	#1996
   776: 	mov	x0, x1
   780: 	mov	x4, x0
   784: 	orr	x0, xzr, #0x3ff0000000000000
   788: 	fmov	d1, x0
   792: 	fadd	d6, d2, d1
   796: 	fmov	d0, d6
   800: 	fcmp	d0, d0
   804: 	b.vs	#2012
   808: 	fmov	x1, d0
   812: 	orr	x10, xzr, #0x8000000000000000
   816: 	cmp	x1, x10
   820: 	b.eq	#1996
   824: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
   828: 	fmov	d1, x1
   832: 	fcmp	d0, d1
   836: 	b.mi	#1980
   840: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
   844: 	fmov	d1, x1
   848: 	fcmp	d0, d1
   852: 	b.ge	#1964
   856: 	fcvtzs	x7, d0
   860: 	scvtf	d1, x7
   864: 	fcmp	d0, d1
   868: 	b.eq	#8
   872: 	b	#1944
   876: 	sxtw	x7, w7
   880: 	mov	x1, x7
   884: 	cmp	x1, x24
   888: 	b.hs	#1928
   892: 	lsl	x1, x1, #3
   896: 	add	x2, x25, x1
   900: 	ldr	x0, [x2]
   904: 	lsr	x3, x0, #48
   908: 	mov	x10, #65521                     // =0xfff1
   912: 	cmp	x3, x10
   916: 	b.hs	#1900
   920: 	fmov	d7, x0
   924: 	fmul	d16, d3, d7
   928: 	mov	x0, x4
   932: 	scvtf	d17, x0
   936: 	fsub	d0, d17, d16
   940: 	str	d0, [x19, #928]
   944: 	mov	x1, x7
   948: 	cmp	x1, x26
   952: 	b.hs	#2100
   956: 	lsl	x1, x1, #3
   960: 	add	x2, x27, x1
   964: 	ldr	x0, [x2]
   968: 	lsr	x3, x0, #48
   972: 	mov	x10, #65521                     // =0xfff1
   976: 	cmp	x3, x10
   980: 	b.hs	#2072
   984: 	fmov	d17, x0
   988: 	fmul	d0, d4, d17
   992: 	str	d0, [x19, #936]
   996: 	ldr	d1, [x19, #936]
  1000: 	fsub	d7, d5, d1
  1004: 	ldr	d0, [x19, #928]
  1008: 	orr	x3, xzr, #0x3fe0000000000000
  1012: 	fmov	d1, x3
  1016: 	fcmp	d0, d1
  1020: 	b.pl	#8
  1024: 	b	#8
  1028: 	b	#20
  1032: 	orr	x3, xzr, #0x3fe0000000000000
  1036: 	fmov	d0, x3
  1040: 	fmov	d17, d0
  1044: 	b	#48
  1048: 	mov	x0, x5
  1052: 	scvtf	d16, x0
  1056: 	ldr	d0, [x19, #928]
  1060: 	fmov	d1, d16
  1064: 	fcmp	d0, d1
  1068: 	b.le	#8
  1072: 	b	#16
  1076: 	ldr	d0, [x19, #928]
  1080: 	fmov	d17, d0
  1084: 	b	#8
  1088: 	scvtf	d17, x5
  1092: 	fmov	d0, d17
  1096: 	fcmp	d0, d0
  1100: 	b.vs	#2288
  1104: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1108: 	fmov	d1, x1
  1112: 	fcmp	d0, d1
  1116: 	b.mi	#2272
  1120: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1124: 	fmov	d1, x1
  1128: 	fcmp	d0, d1
  1132: 	b.ge	#2256
  1136: 	fcvtzs	x7, d0
  1140: 	sxtw	x7, w7
  1144: 	orr	x21, x7, xzr
  1148: 	sxtw	x21, w21
  1152: 	adds	w7, w21, #1
  1156: 	b.vs	#2604
  1160: 	sxtw	x7, w7
  1164: 	fmov	d0, d7
  1168: 	orr	x3, xzr, #0x3fe0000000000000
  1172: 	fmov	d1, x3
  1176: 	fcmp	d0, d1
  1180: 	b.pl	#8
  1184: 	b	#8
  1188: 	b	#20
  1192: 	orr	x3, xzr, #0x3fe0000000000000
  1196: 	fmov	d0, x3
  1200: 	str	d0, [x19, #944]
  1204: 	b	#52
  1208: 	mov	x0, x6
  1212: 	scvtf	d16, x0
  1216: 	fmov	d0, d7
  1220: 	fmov	d1, d16
  1224: 	fcmp	d0, d1
  1228: 	b.le	#8
  1232: 	b	#16
  1236: 	fmov	d0, d7
  1240: 	str	d0, [x19, #944]
  1244: 	b	#12
  1248: 	scvtf	d0, x6
  1252: 	str	d0, [x19, #944]
  1256: 	ldr	d0, [x19, #944]
  1260: 	fcmp	d0, d0
  1264: 	b.vs	#2888
  1268: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1272: 	fmov	d1, x1
  1276: 	fcmp	d0, d1
  1280: 	b.mi	#2872
  1284: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1288: 	fmov	d1, x1
  1292: 	fcmp	d0, d1
  1296: 	b.ge	#2856
  1300: 	fcvtzs	x22, d0
  1304: 	sxtw	x22, w22
  1308: 	orr	x23, x22, xzr
  1312: 	sxtw	x23, w23
  1316: 	adds	w22, w23, #1
  1320: 	b.vs	#3244
  1324: 	sxtw	x22, w22
  1328: 	mov	x0, x21
  1332: 	scvtf	d7, x0
  1336: 	fsub	d16, d17, d7
  1340: 	mov	x0, #1                          // =0x1
  1344: 	scvtf	d0, x0
  1348: 	str	d0, [x19, #952]
  1352: 	ldr	d0, [x19, #952]
  1356: 	fsub	d0, d0, d16
  1360: 	str	d0, [x19, #960]
  1364: 	mov	x0, x23
  1368: 	scvtf	d0, x0
  1372: 	str	d0, [x19, #968]
  1376: 	ldr	d0, [x19, #944]
  1380: 	ldr	d1, [x19, #968]
  1384: 	fsub	d0, d0, d1
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
  1444: 	b.hi	#3552
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
  1500: 	mov	x0, x22
  1504: 	scvtf	d0, x0
  1508: 	str	d0, [x19, #1024]
  1512: 	ldr	x0, [x19, #1000]
  1516: 	lsr	x3, x0, #48
  1520: 	mov	x10, #65521                     // =0xfff1
  1524: 	cmp	x3, x10
  1528: 	b.hi	#4020
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
  1588: 	fadd	d0, d7, d1
  1592: 	str	d0, [x19, #1048]
  1596: 	ldr	d0, [x19, #1048]
  1600: 	fcmp	d0, d0
  1604: 	b.vs	#4528
  1608: 	fmov	x1, d0
  1612: 	orr	x10, xzr, #0x8000000000000000
  1616: 	cmp	x1, x10
  1620: 	b.eq	#4512
  1624: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1628: 	fmov	d1, x1
  1632: 	fcmp	d0, d1
  1636: 	b.mi	#4496
  1640: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1644: 	fmov	d1, x1
  1648: 	fcmp	d0, d1
  1652: 	b.ge	#4480
  1656: 	fcvtzs	x0, d0
  1660: 	scvtf	d1, x0
  1664: 	fcmp	d0, d1
  1668: 	b.eq	#8
  1672: 	b	#4460
  1676: 	sxtw	x0, w0
  1680: 	str	x0, [x19, #1056]
  1684: 	ldr	x1, [x19, #1056]
  1688: 	ldr	x10, [x19, #608]
  1692: 	cmp	x1, x10
  1696: 	b.hs	#4436
  1700: 	lsl	x1, x1, #3
  1704: 	ldr	x2, [x19, #600]
  1708: 	add	x2, x2, x1
  1712: 	ldr	x0, [x2]
  1716: 	lsr	x3, x0, #48
  1720: 	mov	x10, #65521                     // =0xfff1
  1724: 	cmp	x3, x10
  1728: 	b.hs	#4404
  1732: 	fmov	d0, x0
  1736: 	str	d0, [x19, #1064]
  1740: 	ldr	d0, [x19, #992]
  1744: 	ldr	d1, [x19, #1064]
  1748: 	fmul	d0, d0, d1
  1752: 	str	d0, [x19, #1072]
  1756: 	ldr	d1, [x19, #1040]
  1760: 	fadd	d0, d7, d1
  1764: 	str	d0, [x19, #1080]
  1768: 	ldr	d0, [x19, #1080]
  1772: 	fcmp	d0, d0
  1776: 	b.vs	#5024
  1780: 	fmov	x1, d0
  1784: 	orr	x10, xzr, #0x8000000000000000
  1788: 	cmp	x1, x10
  1792: 	b.eq	#5008
  1796: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  1800: 	fmov	d1, x1
  1804: 	fcmp	d0, d1
  1808: 	b.mi	#4992
  1812: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  1816: 	fmov	d1, x1
  1820: 	fcmp	d0, d1
  1824: 	b.ge	#4976
  1828: 	fcvtzs	x0, d0
  1832: 	scvtf	d1, x0
  1836: 	fcmp	d0, d1
  1840: 	b.eq	#8
  1844: 	b	#4956
  1848: 	sxtw	x0, w0
  1852: 	str	x0, [x19, #1088]
  1856: 	ldr	x1, [x19, #1088]
  1860: 	ldr	x10, [x19, #608]
  1864: 	cmp	x1, x10
  1868: 	b.hs	#4932
  1872: 	lsl	x1, x1, #3
  1876: 	ldr	x2, [x19, #600]
  1880: 	add	x2, x2, x1
  1884: 	ldr	x0, [x2]
  1888: 	lsr	x3, x0, #48
  1892: 	mov	x10, #65521                     // =0xfff1
  1896: 	cmp	x3, x10
  1900: 	b.hs	#4900
  1904: 	fmov	d7, x0
  1908: 	ldr	d0, [x19, #976]
  1912: 	fmul	d0, d0, d7
  1916: 	str	d0, [x19, #1096]
  1920: 	ldr	d0, [x19, #1072]
  1924: 	ldr	d1, [x19, #1096]
  1928: 	fadd	d0, d0, d1
  1932: 	str	d0, [x19, #1104]
  1936: 	ldr	d0, [x19, #960]
  1940: 	ldr	d1, [x19, #1104]
  1944: 	fmul	d0, d0, d1
  1948: 	str	d0, [x19, #1112]
  1952: 	mov	x0, x7
  1956: 	scvtf	d0, x0
  1960: 	str	d0, [x19, #1120]
  1964: 	ldr	d0, [x19, #1120]
  1968: 	ldr	d1, [x19, #1016]
  1972: 	fadd	d0, d0, d1
  1976: 	str	d0, [x19, #1128]
  1980: 	ldr	d0, [x19, #1128]
  1984: 	fcmp	d0, d0
  1988: 	b.vs	#5576
  1992: 	fmov	x1, d0
  1996: 	orr	x10, xzr, #0x8000000000000000
  2000: 	cmp	x1, x10
  2004: 	b.eq	#5560
  2008: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  2012: 	fmov	d1, x1
  2016: 	fcmp	d0, d1
  2020: 	b.mi	#5544
  2024: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  2028: 	fmov	d1, x1
  2032: 	fcmp	d0, d1
  2036: 	b.ge	#5528
  2040: 	fcvtzs	x0, d0
  2044: 	scvtf	d1, x0
  2048: 	fcmp	d0, d1
  2052: 	b.eq	#8
  2056: 	b	#5508
  2060: 	sxtw	x0, w0
  2064: 	str	x0, [x19, #1136]
  2068: 	ldr	x1, [x19, #1136]
  2072: 	ldr	x10, [x19, #608]
  2076: 	cmp	x1, x10
  2080: 	b.hs	#5484
  2084: 	lsl	x1, x1, #3
  2088: 	ldr	x2, [x19, #600]
  2092: 	add	x2, x2, x1
  2096: 	ldr	x0, [x2]
  2100: 	lsr	x3, x0, #48
  2104: 	mov	x10, #65521                     // =0xfff1
  2108: 	cmp	x3, x10
  2112: 	b.hs	#5452
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
  2164: 	b.vs	#6260
  2168: 	fmov	x1, d0
  2172: 	orr	x10, xzr, #0x8000000000000000
  2176: 	cmp	x1, x10
  2180: 	b.eq	#6244
  2184: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  2188: 	fmov	d1, x1
  2192: 	fcmp	d0, d1
  2196: 	b.mi	#6228
  2200: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  2204: 	fmov	d1, x1
  2208: 	fcmp	d0, d1
  2212: 	b.ge	#6212
  2216: 	fcvtzs	x0, d0
  2220: 	scvtf	d1, x0
  2224: 	fcmp	d0, d1
  2228: 	b.eq	#8
  2232: 	b	#6192
  2236: 	sxtw	x0, w0
  2240: 	str	x0, [x19, #1168]
  2244: 	ldr	x1, [x19, #1168]
  2248: 	ldr	x10, [x19, #608]
  2252: 	cmp	x1, x10
  2256: 	b.hs	#6168
  2260: 	lsl	x1, x1, #3
  2264: 	ldr	x2, [x19, #600]
  2268: 	add	x2, x2, x1
  2272: 	ldr	x0, [x2]
  2276: 	lsr	x3, x0, #48
  2280: 	mov	x10, #65521                     // =0xfff1
  2284: 	cmp	x3, x10
  2288: 	b.hs	#6136
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
  2336: 	fmul	d0, d16, d1
  2340: 	str	d0, [x19, #1200]
  2344: 	ldr	d0, [x19, #1112]
  2348: 	ldr	d1, [x19, #1200]
  2352: 	fadd	d0, d0, d1
  2356: 	str	d0, [x19, #1208]
  2360: 	fmov	d0, d6
  2364: 	fcmp	d0, d0
  2368: 	b.vs	#7012
  2372: 	fmov	x1, d0
  2376: 	orr	x10, xzr, #0x8000000000000000
  2380: 	cmp	x1, x10
  2384: 	b.eq	#6996
  2388: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  2392: 	fmov	d1, x1
  2396: 	fcmp	d0, d1
  2400: 	b.mi	#6980
  2404: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  2408: 	fmov	d1, x1
  2412: 	fcmp	d0, d1
  2416: 	b.ge	#6964
  2420: 	fcvtzs	x0, d0
  2424: 	scvtf	d1, x0
  2428: 	fcmp	d0, d1
  2432: 	b.eq	#8
  2436: 	b	#6944
  2440: 	sxtw	x0, w0
  2444: 	str	x0, [x19, #1216]
  2448: 	ldr	d0, [x19, #1208]
  2452: 	fmov	x0, d0
  2456: 	lsr	x3, x0, #48
  2460: 	mov	x10, #65521                     // =0xfff1
  2464: 	cmp	x3, x10
  2468: 	b.lo	#8
  2472: 	orr	x0, xzr, #0x7ff8000000000000
  2476: 	str	x0, [x19, #1224]
  2480: 	ldr	x1, [x19, #1216]
  2484: 	ldr	x10, [x19, #640]
  2488: 	cmp	x1, x10
  2492: 	b.hs	#6888
  2496: 	lsl	x1, x1, #3
  2500: 	ldr	x2, [x19, #632]
  2504: 	add	x2, x2, x1
  2508: 	ldr	x0, [x2]
  2512: 	lsr	x3, x0, #48
  2516: 	mov	x10, #65521                     // =0xfff1
  2520: 	cmp	x3, x10
  2524: 	b.hi	#6856
  2528: 	ldr	x0, [x19, #1224]
  2532: 	str	x0, [x2]
  2536: 	adds	w0, w4, #1
  2540: 	b.vs	#7860
  2544: 	sxtw	x0, w0
  2548: 	str	x0, [x19, #1232]
  2552: 	ldr	x0, [x19, #792]
  2556: 	str	x0, [x19, #1240]
  2560: 	ldr	x0, [x19, #1232]
  2564: 	scvtf	d0, x0
  2568: 	str	d0, [x19, #1248]
  2572: 	ldr	x0, [x19, #1240]
  2576: 	lsr	x3, x0, #48
  2580: 	mov	x10, #65521                     // =0xfff1
  2584: 	cmp	x3, x10
  2588: 	b.hi	#8832
  2592: 	mov	x10, #65521                     // =0xfff1
  2596: 	cmp	x3, x10
  2600: 	b.ne	#20
  2604: 	lsl	x0, x0, #16
  2608: 	asr	x0, x0, #16
  2612: 	scvtf	d0, x0
  2616: 	b	#8
  2620: 	fmov	d0, x0
  2624: 	str	d0, [x19, #1256]
  2628: 	cmp	x20, #1
  2632: 	b.ls	#9784
  2636: 	sub	x20, x20, #1
  2640: 	fmov	d2, d6
  2644: 	ldr	x0, [x19, #1232]
  2648: 	mov	x4, x0
  2652: 	ldr	d0, [x19, #1248]
  2656: 	ldr	d1, [x19, #1256]
  2660: 	fcmp	d0, d1
  2664: 	b.ls	#-1880
  2668: 	fmov	d0, d2
  2672: 	fmov	x0, d0
  2676: 	lsr	x3, x0, #48
  2680: 	mov	x10, #65521                     // =0xfff1
  2684: 	cmp	x3, x10
  2688: 	b.lo	#8
  2692: 	orr	x0, xzr, #0x7ff8000000000000
  2696: 	str	x0, [x19, #88]
  2700: 	mov	x0, x4
  2704: 	and	x0, x0, #0xffffffffffff
  2708: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2712: 	orr	x0, x0, x10
  2716: 	str	x0, [x19, #96]
  2720: 	mov	x9, #6144                       // =0x1800
  2724: 	str	x9, [x19, #912]
  2728: 	str	x20, [x19, #920]
  2732: 	mov	x0, #71                         // =0x47
  2736: 	ldp	x29, x30, [sp]
  2740: 	ldp	x19, x20, [sp, #80]
  2744: 	ldp	x21, x22, [sp, #64]
  2748: 	ldp	x23, x24, [sp, #48]
  2752: 	ldp	x25, x26, [sp, #32]
  2756: 	ldr	x27, [sp, #24]
  2760: 	add	sp, sp, #96
  2764: 	ret
  2768: 	mov	x9, #0                          // =0x0
  2772: 	str	x9, [x19, #912]
  2776: 	str	x20, [x19, #920]
  2780: 	mov	x0, #16                         // =0x10
  2784: 	ldp	x29, x30, [sp]
  2788: 	ldp	x19, x20, [sp, #80]
  2792: 	ldp	x21, x22, [sp, #64]
  2796: 	ldp	x23, x24, [sp, #48]
  2800: 	ldp	x25, x26, [sp, #32]
  2804: 	ldr	x27, [sp, #24]
  2808: 	add	sp, sp, #96
  2812: 	ret
  2816: 	fmov	d0, d3
  2820: 	fmov	x0, d0
  2824: 	lsr	x3, x0, #48
  2828: 	mov	x10, #65521                     // =0xfff1
  2832: 	cmp	x3, x10
  2836: 	b.lo	#8
  2840: 	orr	x0, xzr, #0x7ff8000000000000
  2844: 	str	x0, [x19, #48]
  2848: 	fmov	d0, d4
  2852: 	fmov	x0, d0
  2856: 	lsr	x3, x0, #48
  2860: 	mov	x10, #65521                     // =0xfff1
  2864: 	cmp	x3, x10
  2868: 	b.lo	#8
  2872: 	orr	x0, xzr, #0x7ff8000000000000
  2876: 	str	x0, [x19, #56]
  2880: 	mov	x0, x5
  2884: 	and	x0, x0, #0xffffffffffff
  2888: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2892: 	orr	x0, x0, x10
  2896: 	str	x0, [x19, #64]
  2900: 	mov	x0, x6
  2904: 	and	x0, x0, #0xffffffffffff
  2908: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2912: 	orr	x0, x0, x10
  2916: 	str	x0, [x19, #72]
  2920: 	fmov	d0, d5
  2924: 	fmov	x0, d0
  2928: 	lsr	x3, x0, #48
  2932: 	mov	x10, #65521                     // =0xfff1
  2936: 	cmp	x3, x10
  2940: 	b.lo	#8
  2944: 	orr	x0, xzr, #0x7ff8000000000000
  2948: 	str	x0, [x19, #80]
  2952: 	fmov	d0, d6
  2956: 	fmov	x0, d0
  2960: 	lsr	x3, x0, #48
  2964: 	mov	x10, #65521                     // =0xfff1
  2968: 	cmp	x3, x10
  2972: 	b.lo	#8
  2976: 	orr	x0, xzr, #0x7ff8000000000000
  2980: 	str	x0, [x19, #88]
  2984: 	mov	x0, x4
  2988: 	and	x0, x0, #0xffffffffffff
  2992: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  2996: 	orr	x0, x0, x10
  3000: 	str	x0, [x19, #96]
  3004: 	mov	x9, #8128                       // =0x1fc0
  3008: 	str	x9, [x19, #912]
  3012: 	str	x20, [x19, #920]
  3016: 	mov	x0, #17                         // =0x11
  3020: 	ldp	x29, x30, [sp]
  3024: 	ldp	x19, x20, [sp, #80]
  3028: 	ldp	x21, x22, [sp, #64]
  3032: 	ldp	x23, x24, [sp, #48]
  3036: 	ldp	x25, x26, [sp, #32]
  3040: 	ldr	x27, [sp, #24]
  3044: 	add	sp, sp, #96
  3048: 	ret
  3052: 	fmov	d0, d3
  3056: 	fmov	x0, d0
  3060: 	lsr	x3, x0, #48
  3064: 	mov	x10, #65521                     // =0xfff1
  3068: 	cmp	x3, x10
  3072: 	b.lo	#8
  3076: 	orr	x0, xzr, #0x7ff8000000000000
  3080: 	str	x0, [x19, #48]
  3084: 	fmov	d0, d4
  3088: 	fmov	x0, d0
  3092: 	lsr	x3, x0, #48
  3096: 	mov	x10, #65521                     // =0xfff1
  3100: 	cmp	x3, x10
  3104: 	b.lo	#8
  3108: 	orr	x0, xzr, #0x7ff8000000000000
  3112: 	str	x0, [x19, #56]
  3116: 	mov	x0, x5
  3120: 	and	x0, x0, #0xffffffffffff
  3124: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3128: 	orr	x0, x0, x10
  3132: 	str	x0, [x19, #64]
  3136: 	mov	x0, x6
  3140: 	and	x0, x0, #0xffffffffffff
  3144: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3148: 	orr	x0, x0, x10
  3152: 	str	x0, [x19, #72]
  3156: 	fmov	d0, d5
  3160: 	fmov	x0, d0
  3164: 	lsr	x3, x0, #48
  3168: 	mov	x10, #65521                     // =0xfff1
  3172: 	cmp	x3, x10
  3176: 	b.lo	#8
  3180: 	orr	x0, xzr, #0x7ff8000000000000
  3184: 	str	x0, [x19, #80]
  3188: 	fmov	d0, d6
  3192: 	fmov	x0, d0
  3196: 	lsr	x3, x0, #48
  3200: 	mov	x10, #65521                     // =0xfff1
  3204: 	cmp	x3, x10
  3208: 	b.lo	#8
  3212: 	orr	x0, xzr, #0x7ff8000000000000
  3216: 	str	x0, [x19, #88]
  3220: 	mov	x0, x4
  3224: 	and	x0, x0, #0xffffffffffff
  3228: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3232: 	orr	x0, x0, x10
  3236: 	str	x0, [x19, #96]
  3240: 	ldr	d0, [x19, #928]
  3244: 	fmov	x0, d0
  3248: 	lsr	x3, x0, #48
  3252: 	mov	x10, #65521                     // =0xfff1
  3256: 	cmp	x3, x10
  3260: 	b.lo	#8
  3264: 	orr	x0, xzr, #0x7ff8000000000000
  3268: 	str	x0, [x19, #104]
  3272: 	fmov	d0, d7
  3276: 	fmov	x0, d0
  3280: 	lsr	x3, x0, #48
  3284: 	mov	x10, #65521                     // =0xfff1
  3288: 	cmp	x3, x10
  3292: 	b.lo	#8
  3296: 	orr	x0, xzr, #0x7ff8000000000000
  3300: 	str	x0, [x19, #200]
  3304: 	fmov	d0, d16
  3308: 	fmov	x0, d0
  3312: 	lsr	x3, x0, #48
  3316: 	mov	x10, #65521                     // =0xfff1
  3320: 	cmp	x3, x10
  3324: 	b.lo	#8
  3328: 	orr	x0, xzr, #0x7ff8000000000000
  3332: 	str	x0, [x19, #208]
  3336: 	mov	x9, #16320                      // =0x3fc0
  3340: 	movk	x9, #1536, lsl #16
  3344: 	str	x9, [x19, #912]
  3348: 	str	x20, [x19, #920]
  3352: 	mov	x0, #20                         // =0x14
  3356: 	ldp	x29, x30, [sp]
  3360: 	ldp	x19, x20, [sp, #80]
  3364: 	ldp	x21, x22, [sp, #64]
  3368: 	ldp	x23, x24, [sp, #48]
  3372: 	ldp	x25, x26, [sp, #32]
  3376: 	ldr	x27, [sp, #24]
  3380: 	add	sp, sp, #96
  3384: 	ret
  3388: 	fmov	d0, d3
  3392: 	fmov	x0, d0
  3396: 	lsr	x3, x0, #48
  3400: 	mov	x10, #65521                     // =0xfff1
  3404: 	cmp	x3, x10
  3408: 	b.lo	#8
  3412: 	orr	x0, xzr, #0x7ff8000000000000
  3416: 	str	x0, [x19, #48]
  3420: 	fmov	d0, d4
  3424: 	fmov	x0, d0
  3428: 	lsr	x3, x0, #48
  3432: 	mov	x10, #65521                     // =0xfff1
  3436: 	cmp	x3, x10
  3440: 	b.lo	#8
  3444: 	orr	x0, xzr, #0x7ff8000000000000
  3448: 	str	x0, [x19, #56]
  3452: 	mov	x0, x5
  3456: 	and	x0, x0, #0xffffffffffff
  3460: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3464: 	orr	x0, x0, x10
  3468: 	str	x0, [x19, #64]
  3472: 	mov	x0, x6
  3476: 	and	x0, x0, #0xffffffffffff
  3480: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3484: 	orr	x0, x0, x10
  3488: 	str	x0, [x19, #72]
  3492: 	fmov	d0, d5
  3496: 	fmov	x0, d0
  3500: 	lsr	x3, x0, #48
  3504: 	mov	x10, #65521                     // =0xfff1
  3508: 	cmp	x3, x10
  3512: 	b.lo	#8
  3516: 	orr	x0, xzr, #0x7ff8000000000000
  3520: 	str	x0, [x19, #80]
  3524: 	fmov	d0, d6
  3528: 	fmov	x0, d0
  3532: 	lsr	x3, x0, #48
  3536: 	mov	x10, #65521                     // =0xfff1
  3540: 	cmp	x3, x10
  3544: 	b.lo	#8
  3548: 	orr	x0, xzr, #0x7ff8000000000000
  3552: 	str	x0, [x19, #88]
  3556: 	mov	x0, x4
  3560: 	and	x0, x0, #0xffffffffffff
  3564: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3568: 	orr	x0, x0, x10
  3572: 	str	x0, [x19, #96]
  3576: 	fmov	d0, d17
  3580: 	fmov	x0, d0
  3584: 	lsr	x3, x0, #48
  3588: 	mov	x10, #65521                     // =0xfff1
  3592: 	cmp	x3, x10
  3596: 	b.lo	#8
  3600: 	orr	x0, xzr, #0x7ff8000000000000
  3604: 	str	x0, [x19, #104]
  3608: 	fmov	d0, d7
  3612: 	fmov	x0, d0
  3616: 	lsr	x3, x0, #48
  3620: 	mov	x10, #65521                     // =0xfff1
  3624: 	cmp	x3, x10
  3628: 	b.lo	#8
  3632: 	orr	x0, xzr, #0x7ff8000000000000
  3636: 	str	x0, [x19, #112]
  3640: 	orr	x3, xzr, #0x3fe0000000000000
  3644: 	fmov	d0, x3
  3648: 	fmov	x0, d0
  3652: 	lsr	x3, x0, #48
  3656: 	mov	x10, #65521                     // =0xfff1
  3660: 	cmp	x3, x10
  3664: 	b.lo	#8
  3668: 	orr	x0, xzr, #0x7ff8000000000000
  3672: 	str	x0, [x19, #200]
  3676: 	ldr	d0, [x19, #936]
  3680: 	fmov	x0, d0
  3684: 	lsr	x3, x0, #48
  3688: 	mov	x10, #65521                     // =0xfff1
  3692: 	cmp	x3, x10
  3696: 	b.lo	#8
  3700: 	orr	x0, xzr, #0x7ff8000000000000
  3704: 	str	x0, [x19, #208]
  3708: 	mov	x9, #32704                      // =0x7fc0
  3712: 	movk	x9, #1536, lsl #16
  3716: 	str	x9, [x19, #912]
  3720: 	str	x20, [x19, #920]
  3724: 	mov	x0, #29                         // =0x1d
  3728: 	ldp	x29, x30, [sp]
  3732: 	ldp	x19, x20, [sp, #80]
  3736: 	ldp	x21, x22, [sp, #64]
  3740: 	ldp	x23, x24, [sp, #48]
  3744: 	ldp	x25, x26, [sp, #32]
  3748: 	ldr	x27, [sp, #24]
  3752: 	add	sp, sp, #96
  3756: 	ret
  3760: 	fmov	d0, d3
  3764: 	fmov	x0, d0
  3768: 	lsr	x3, x0, #48
  3772: 	mov	x10, #65521                     // =0xfff1
  3776: 	cmp	x3, x10
  3780: 	b.lo	#8
  3784: 	orr	x0, xzr, #0x7ff8000000000000
  3788: 	str	x0, [x19, #48]
  3792: 	fmov	d0, d4
  3796: 	fmov	x0, d0
  3800: 	lsr	x3, x0, #48
  3804: 	mov	x10, #65521                     // =0xfff1
  3808: 	cmp	x3, x10
  3812: 	b.lo	#8
  3816: 	orr	x0, xzr, #0x7ff8000000000000
  3820: 	str	x0, [x19, #56]
  3824: 	mov	x0, x5
  3828: 	and	x0, x0, #0xffffffffffff
  3832: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3836: 	orr	x0, x0, x10
  3840: 	str	x0, [x19, #64]
  3844: 	mov	x0, x6
  3848: 	and	x0, x0, #0xffffffffffff
  3852: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3856: 	orr	x0, x0, x10
  3860: 	str	x0, [x19, #72]
  3864: 	fmov	d0, d5
  3868: 	fmov	x0, d0
  3872: 	lsr	x3, x0, #48
  3876: 	mov	x10, #65521                     // =0xfff1
  3880: 	cmp	x3, x10
  3884: 	b.lo	#8
  3888: 	orr	x0, xzr, #0x7ff8000000000000
  3892: 	str	x0, [x19, #80]
  3896: 	fmov	d0, d6
  3900: 	fmov	x0, d0
  3904: 	lsr	x3, x0, #48
  3908: 	mov	x10, #65521                     // =0xfff1
  3912: 	cmp	x3, x10
  3916: 	b.lo	#8
  3920: 	orr	x0, xzr, #0x7ff8000000000000
  3924: 	str	x0, [x19, #88]
  3928: 	mov	x0, x4
  3932: 	and	x0, x0, #0xffffffffffff
  3936: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  3940: 	orr	x0, x0, x10
  3944: 	str	x0, [x19, #96]
  3948: 	fmov	d0, d17
  3952: 	fmov	x0, d0
  3956: 	lsr	x3, x0, #48
  3960: 	mov	x10, #65521                     // =0xfff1
  3964: 	cmp	x3, x10
  3968: 	b.lo	#8
  3972: 	orr	x0, xzr, #0x7ff8000000000000
  3976: 	str	x0, [x19, #104]
  3980: 	fmov	d0, d7
  3984: 	fmov	x0, d0
  3988: 	lsr	x3, x0, #48
  3992: 	mov	x10, #65521                     // =0xfff1
  3996: 	cmp	x3, x10
  4000: 	b.lo	#8
  4004: 	orr	x0, xzr, #0x7ff8000000000000
  4008: 	str	x0, [x19, #112]
  4012: 	mov	x0, x21
  4016: 	and	x0, x0, #0xffffffffffff
  4020: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4024: 	orr	x0, x0, x10
  4028: 	str	x0, [x19, #120]
  4032: 	orr	x3, xzr, #0x3fe0000000000000
  4036: 	fmov	d0, x3
  4040: 	fmov	x0, d0
  4044: 	lsr	x3, x0, #48
  4048: 	mov	x10, #65521                     // =0xfff1
  4052: 	cmp	x3, x10
  4056: 	b.lo	#8
  4060: 	orr	x0, xzr, #0x7ff8000000000000
  4064: 	str	x0, [x19, #200]
  4068: 	ldr	d0, [x19, #936]
  4072: 	fmov	x0, d0
  4076: 	lsr	x3, x0, #48
  4080: 	mov	x10, #65521                     // =0xfff1
  4084: 	cmp	x3, x10
  4088: 	b.lo	#8
  4092: 	orr	x0, xzr, #0x7ff8000000000000
  4096: 	str	x0, [x19, #208]
  4100: 	mov	x9, #65472                      // =0xffc0
  4104: 	movk	x9, #1536, lsl #16
  4108: 	str	x9, [x19, #912]
  4112: 	str	x20, [x19, #920]
  4116: 	mov	x0, #30                         // =0x1e
  4120: 	ldp	x29, x30, [sp]
  4124: 	ldp	x19, x20, [sp, #80]
  4128: 	ldp	x21, x22, [sp, #64]
  4132: 	ldp	x23, x24, [sp, #48]
  4136: 	ldp	x25, x26, [sp, #32]
  4140: 	ldr	x27, [sp, #24]
  4144: 	add	sp, sp, #96
  4148: 	ret
  4152: 	fmov	d0, d3
  4156: 	fmov	x0, d0
  4160: 	lsr	x3, x0, #48
  4164: 	mov	x10, #65521                     // =0xfff1
  4168: 	cmp	x3, x10
  4172: 	b.lo	#8
  4176: 	orr	x0, xzr, #0x7ff8000000000000
  4180: 	str	x0, [x19, #48]
  4184: 	fmov	d0, d4
  4188: 	fmov	x0, d0
  4192: 	lsr	x3, x0, #48
  4196: 	mov	x10, #65521                     // =0xfff1
  4200: 	cmp	x3, x10
  4204: 	b.lo	#8
  4208: 	orr	x0, xzr, #0x7ff8000000000000
  4212: 	str	x0, [x19, #56]
  4216: 	mov	x0, x5
  4220: 	and	x0, x0, #0xffffffffffff
  4224: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4228: 	orr	x0, x0, x10
  4232: 	str	x0, [x19, #64]
  4236: 	mov	x0, x6
  4240: 	and	x0, x0, #0xffffffffffff
  4244: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4248: 	orr	x0, x0, x10
  4252: 	str	x0, [x19, #72]
  4256: 	fmov	d0, d5
  4260: 	fmov	x0, d0
  4264: 	lsr	x3, x0, #48
  4268: 	mov	x10, #65521                     // =0xfff1
  4272: 	cmp	x3, x10
  4276: 	b.lo	#8
  4280: 	orr	x0, xzr, #0x7ff8000000000000
  4284: 	str	x0, [x19, #80]
  4288: 	fmov	d0, d6
  4292: 	fmov	x0, d0
  4296: 	lsr	x3, x0, #48
  4300: 	mov	x10, #65521                     // =0xfff1
  4304: 	cmp	x3, x10
  4308: 	b.lo	#8
  4312: 	orr	x0, xzr, #0x7ff8000000000000
  4316: 	str	x0, [x19, #88]
  4320: 	mov	x0, x4
  4324: 	and	x0, x0, #0xffffffffffff
  4328: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4332: 	orr	x0, x0, x10
  4336: 	str	x0, [x19, #96]
  4340: 	fmov	d0, d17
  4344: 	fmov	x0, d0
  4348: 	lsr	x3, x0, #48
  4352: 	mov	x10, #65521                     // =0xfff1
  4356: 	cmp	x3, x10
  4360: 	b.lo	#8
  4364: 	orr	x0, xzr, #0x7ff8000000000000
  4368: 	str	x0, [x19, #104]
  4372: 	ldr	d0, [x19, #944]
  4376: 	fmov	x0, d0
  4380: 	lsr	x3, x0, #48
  4384: 	mov	x10, #65521                     // =0xfff1
  4388: 	cmp	x3, x10
  4392: 	b.lo	#8
  4396: 	orr	x0, xzr, #0x7ff8000000000000
  4400: 	str	x0, [x19, #112]
  4404: 	mov	x0, x21
  4408: 	and	x0, x0, #0xffffffffffff
  4412: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4416: 	orr	x0, x0, x10
  4420: 	str	x0, [x19, #120]
  4424: 	mov	x0, x7
  4428: 	and	x0, x0, #0xffffffffffff
  4432: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4436: 	orr	x0, x0, x10
  4440: 	str	x0, [x19, #128]
  4444: 	orr	x3, xzr, #0x3fe0000000000000
  4448: 	fmov	d0, x3
  4452: 	fmov	x0, d0
  4456: 	lsr	x3, x0, #48
  4460: 	mov	x10, #65521                     // =0xfff1
  4464: 	cmp	x3, x10
  4468: 	b.lo	#8
  4472: 	orr	x0, xzr, #0x7ff8000000000000
  4476: 	str	x0, [x19, #200]
  4480: 	ldr	d0, [x19, #936]
  4484: 	fmov	x0, d0
  4488: 	lsr	x3, x0, #48
  4492: 	mov	x10, #65521                     // =0xfff1
  4496: 	cmp	x3, x10
  4500: 	b.lo	#8
  4504: 	orr	x0, xzr, #0x7ff8000000000000
  4508: 	str	x0, [x19, #208]
  4512: 	mov	x9, #65472                      // =0xffc0
  4516: 	movk	x9, #1537, lsl #16
  4520: 	str	x9, [x19, #912]
  4524: 	str	x20, [x19, #920]
  4528: 	mov	x0, #37                         // =0x25
  4532: 	ldp	x29, x30, [sp]
  4536: 	ldp	x19, x20, [sp, #80]
  4540: 	ldp	x21, x22, [sp, #64]
  4544: 	ldp	x23, x24, [sp, #48]
  4548: 	ldp	x25, x26, [sp, #32]
  4552: 	ldr	x27, [sp, #24]
  4556: 	add	sp, sp, #96
  4560: 	ret
  4564: 	fmov	d0, d3
  4568: 	fmov	x0, d0
  4572: 	lsr	x3, x0, #48
  4576: 	mov	x10, #65521                     // =0xfff1
  4580: 	cmp	x3, x10
  4584: 	b.lo	#8
  4588: 	orr	x0, xzr, #0x7ff8000000000000
  4592: 	str	x0, [x19, #48]
  4596: 	fmov	d0, d4
  4600: 	fmov	x0, d0
  4604: 	lsr	x3, x0, #48
  4608: 	mov	x10, #65521                     // =0xfff1
  4612: 	cmp	x3, x10
  4616: 	b.lo	#8
  4620: 	orr	x0, xzr, #0x7ff8000000000000
  4624: 	str	x0, [x19, #56]
  4628: 	mov	x0, x5
  4632: 	and	x0, x0, #0xffffffffffff
  4636: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4640: 	orr	x0, x0, x10
  4644: 	str	x0, [x19, #64]
  4648: 	mov	x0, x6
  4652: 	and	x0, x0, #0xffffffffffff
  4656: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4660: 	orr	x0, x0, x10
  4664: 	str	x0, [x19, #72]
  4668: 	fmov	d0, d5
  4672: 	fmov	x0, d0
  4676: 	lsr	x3, x0, #48
  4680: 	mov	x10, #65521                     // =0xfff1
  4684: 	cmp	x3, x10
  4688: 	b.lo	#8
  4692: 	orr	x0, xzr, #0x7ff8000000000000
  4696: 	str	x0, [x19, #80]
  4700: 	fmov	d0, d6
  4704: 	fmov	x0, d0
  4708: 	lsr	x3, x0, #48
  4712: 	mov	x10, #65521                     // =0xfff1
  4716: 	cmp	x3, x10
  4720: 	b.lo	#8
  4724: 	orr	x0, xzr, #0x7ff8000000000000
  4728: 	str	x0, [x19, #88]
  4732: 	mov	x0, x4
  4736: 	and	x0, x0, #0xffffffffffff
  4740: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4744: 	orr	x0, x0, x10
  4748: 	str	x0, [x19, #96]
  4752: 	fmov	d0, d17
  4756: 	fmov	x0, d0
  4760: 	lsr	x3, x0, #48
  4764: 	mov	x10, #65521                     // =0xfff1
  4768: 	cmp	x3, x10
  4772: 	b.lo	#8
  4776: 	orr	x0, xzr, #0x7ff8000000000000
  4780: 	str	x0, [x19, #104]
  4784: 	ldr	d0, [x19, #944]
  4788: 	fmov	x0, d0
  4792: 	lsr	x3, x0, #48
  4796: 	mov	x10, #65521                     // =0xfff1
  4800: 	cmp	x3, x10
  4804: 	b.lo	#8
  4808: 	orr	x0, xzr, #0x7ff8000000000000
  4812: 	str	x0, [x19, #112]
  4816: 	mov	x0, x21
  4820: 	and	x0, x0, #0xffffffffffff
  4824: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4828: 	orr	x0, x0, x10
  4832: 	str	x0, [x19, #120]
  4836: 	mov	x0, x7
  4840: 	and	x0, x0, #0xffffffffffff
  4844: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4848: 	orr	x0, x0, x10
  4852: 	str	x0, [x19, #128]
  4856: 	mov	x0, x23
  4860: 	and	x0, x0, #0xffffffffffff
  4864: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  4868: 	orr	x0, x0, x10
  4872: 	str	x0, [x19, #136]
  4876: 	orr	x3, xzr, #0x3fe0000000000000
  4880: 	fmov	d0, x3
  4884: 	fmov	x0, d0
  4888: 	lsr	x3, x0, #48
  4892: 	mov	x10, #65521                     // =0xfff1
  4896: 	cmp	x3, x10
  4900: 	b.lo	#8
  4904: 	orr	x0, xzr, #0x7ff8000000000000
  4908: 	str	x0, [x19, #200]
  4912: 	ldr	d0, [x19, #936]
  4916: 	fmov	x0, d0
  4920: 	lsr	x3, x0, #48
  4924: 	mov	x10, #65521                     // =0xfff1
  4928: 	cmp	x3, x10
  4932: 	b.lo	#8
  4936: 	orr	x0, xzr, #0x7ff8000000000000
  4940: 	str	x0, [x19, #208]
  4944: 	mov	x9, #65472                      // =0xffc0
  4948: 	movk	x9, #1539, lsl #16
  4952: 	str	x9, [x19, #912]
  4956: 	str	x20, [x19, #920]
  4960: 	mov	x0, #38                         // =0x26
  4964: 	ldp	x29, x30, [sp]
  4968: 	ldp	x19, x20, [sp, #80]
  4972: 	ldp	x21, x22, [sp, #64]
  4976: 	ldp	x23, x24, [sp, #48]
  4980: 	ldp	x25, x26, [sp, #32]
  4984: 	ldr	x27, [sp, #24]
  4988: 	add	sp, sp, #96
  4992: 	ret
  4996: 	fmov	d0, d3
  5000: 	fmov	x0, d0
  5004: 	lsr	x3, x0, #48
  5008: 	mov	x10, #65521                     // =0xfff1
  5012: 	cmp	x3, x10
  5016: 	b.lo	#8
  5020: 	orr	x0, xzr, #0x7ff8000000000000
  5024: 	str	x0, [x19, #48]
  5028: 	fmov	d0, d4
  5032: 	fmov	x0, d0
  5036: 	lsr	x3, x0, #48
  5040: 	mov	x10, #65521                     // =0xfff1
  5044: 	cmp	x3, x10
  5048: 	b.lo	#8
  5052: 	orr	x0, xzr, #0x7ff8000000000000
  5056: 	str	x0, [x19, #56]
  5060: 	mov	x0, x5
  5064: 	and	x0, x0, #0xffffffffffff
  5068: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5072: 	orr	x0, x0, x10
  5076: 	str	x0, [x19, #64]
  5080: 	mov	x0, x6
  5084: 	and	x0, x0, #0xffffffffffff
  5088: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5092: 	orr	x0, x0, x10
  5096: 	str	x0, [x19, #72]
  5100: 	fmov	d0, d5
  5104: 	fmov	x0, d0
  5108: 	lsr	x3, x0, #48
  5112: 	mov	x10, #65521                     // =0xfff1
  5116: 	cmp	x3, x10
  5120: 	b.lo	#8
  5124: 	orr	x0, xzr, #0x7ff8000000000000
  5128: 	str	x0, [x19, #80]
  5132: 	fmov	d0, d6
  5136: 	fmov	x0, d0
  5140: 	lsr	x3, x0, #48
  5144: 	mov	x10, #65521                     // =0xfff1
  5148: 	cmp	x3, x10
  5152: 	b.lo	#8
  5156: 	orr	x0, xzr, #0x7ff8000000000000
  5160: 	str	x0, [x19, #88]
  5164: 	mov	x0, x4
  5168: 	and	x0, x0, #0xffffffffffff
  5172: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5176: 	orr	x0, x0, x10
  5180: 	str	x0, [x19, #96]
  5184: 	fmov	d0, d17
  5188: 	fmov	x0, d0
  5192: 	lsr	x3, x0, #48
  5196: 	mov	x10, #65521                     // =0xfff1
  5200: 	cmp	x3, x10
  5204: 	b.lo	#8
  5208: 	orr	x0, xzr, #0x7ff8000000000000
  5212: 	str	x0, [x19, #104]
  5216: 	ldr	d0, [x19, #944]
  5220: 	fmov	x0, d0
  5224: 	lsr	x3, x0, #48
  5228: 	mov	x10, #65521                     // =0xfff1
  5232: 	cmp	x3, x10
  5236: 	b.lo	#8
  5240: 	orr	x0, xzr, #0x7ff8000000000000
  5244: 	str	x0, [x19, #112]
  5248: 	mov	x0, x21
  5252: 	and	x0, x0, #0xffffffffffff
  5256: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5260: 	orr	x0, x0, x10
  5264: 	str	x0, [x19, #120]
  5268: 	mov	x0, x7
  5272: 	and	x0, x0, #0xffffffffffff
  5276: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5280: 	orr	x0, x0, x10
  5284: 	str	x0, [x19, #128]
  5288: 	mov	x0, x23
  5292: 	and	x0, x0, #0xffffffffffff
  5296: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5300: 	orr	x0, x0, x10
  5304: 	str	x0, [x19, #136]
  5308: 	mov	x0, x22
  5312: 	and	x0, x0, #0xffffffffffff
  5316: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5320: 	orr	x0, x0, x10
  5324: 	str	x0, [x19, #144]
  5328: 	fmov	d0, d16
  5332: 	fmov	x0, d0
  5336: 	lsr	x3, x0, #48
  5340: 	mov	x10, #65521                     // =0xfff1
  5344: 	cmp	x3, x10
  5348: 	b.lo	#8
  5352: 	orr	x0, xzr, #0x7ff8000000000000
  5356: 	str	x0, [x19, #152]
  5360: 	ldr	d0, [x19, #960]
  5364: 	fmov	x0, d0
  5368: 	lsr	x3, x0, #48
  5372: 	mov	x10, #65521                     // =0xfff1
  5376: 	cmp	x3, x10
  5380: 	b.lo	#8
  5384: 	orr	x0, xzr, #0x7ff8000000000000
  5388: 	str	x0, [x19, #160]
  5392: 	ldr	d0, [x19, #976]
  5396: 	fmov	x0, d0
  5400: 	lsr	x3, x0, #48
  5404: 	mov	x10, #65521                     // =0xfff1
  5408: 	cmp	x3, x10
  5412: 	b.lo	#8
  5416: 	orr	x0, xzr, #0x7ff8000000000000
  5420: 	str	x0, [x19, #168]
  5424: 	ldr	d0, [x19, #992]
  5428: 	fmov	x0, d0
  5432: 	lsr	x3, x0, #48
  5436: 	mov	x10, #65521                     // =0xfff1
  5440: 	cmp	x3, x10
  5444: 	b.lo	#8
  5448: 	orr	x0, xzr, #0x7ff8000000000000
  5452: 	str	x0, [x19, #176]
  5456: 	ldr	x0, [x19, #1000]
  5460: 	str	x0, [x19, #200]
  5464: 	ldr	d0, [x19, #936]
  5468: 	fmov	x0, d0
  5472: 	lsr	x3, x0, #48
  5476: 	mov	x10, #65521                     // =0xfff1
  5480: 	cmp	x3, x10
  5484: 	b.lo	#8
  5488: 	orr	x0, xzr, #0x7ff8000000000000
  5492: 	str	x0, [x19, #208]
  5496: 	mov	x9, #65472                      // =0xffc0
  5500: 	movk	x9, #1663, lsl #16
  5504: 	str	x9, [x19, #912]
  5508: 	str	x20, [x19, #920]
  5512: 	mov	x0, #46                         // =0x2e
  5516: 	ldp	x29, x30, [sp]
  5520: 	ldp	x19, x20, [sp, #80]
  5524: 	ldp	x21, x22, [sp, #64]
  5528: 	ldp	x23, x24, [sp, #48]
  5532: 	ldp	x25, x26, [sp, #32]
  5536: 	ldr	x27, [sp, #24]
  5540: 	add	sp, sp, #96
  5544: 	ret
  5548: 	fmov	d0, d3
  5552: 	fmov	x0, d0
  5556: 	lsr	x3, x0, #48
  5560: 	mov	x10, #65521                     // =0xfff1
  5564: 	cmp	x3, x10
  5568: 	b.lo	#8
  5572: 	orr	x0, xzr, #0x7ff8000000000000
  5576: 	str	x0, [x19, #48]
  5580: 	fmov	d0, d4
  5584: 	fmov	x0, d0
  5588: 	lsr	x3, x0, #48
  5592: 	mov	x10, #65521                     // =0xfff1
  5596: 	cmp	x3, x10
  5600: 	b.lo	#8
  5604: 	orr	x0, xzr, #0x7ff8000000000000
  5608: 	str	x0, [x19, #56]
  5612: 	mov	x0, x5
  5616: 	and	x0, x0, #0xffffffffffff
  5620: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5624: 	orr	x0, x0, x10
  5628: 	str	x0, [x19, #64]
  5632: 	mov	x0, x6
  5636: 	and	x0, x0, #0xffffffffffff
  5640: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5644: 	orr	x0, x0, x10
  5648: 	str	x0, [x19, #72]
  5652: 	fmov	d0, d5
  5656: 	fmov	x0, d0
  5660: 	lsr	x3, x0, #48
  5664: 	mov	x10, #65521                     // =0xfff1
  5668: 	cmp	x3, x10
  5672: 	b.lo	#8
  5676: 	orr	x0, xzr, #0x7ff8000000000000
  5680: 	str	x0, [x19, #80]
  5684: 	fmov	d0, d6
  5688: 	fmov	x0, d0
  5692: 	lsr	x3, x0, #48
  5696: 	mov	x10, #65521                     // =0xfff1
  5700: 	cmp	x3, x10
  5704: 	b.lo	#8
  5708: 	orr	x0, xzr, #0x7ff8000000000000
  5712: 	str	x0, [x19, #88]
  5716: 	mov	x0, x4
  5720: 	and	x0, x0, #0xffffffffffff
  5724: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5728: 	orr	x0, x0, x10
  5732: 	str	x0, [x19, #96]
  5736: 	fmov	d0, d17
  5740: 	fmov	x0, d0
  5744: 	lsr	x3, x0, #48
  5748: 	mov	x10, #65521                     // =0xfff1
  5752: 	cmp	x3, x10
  5756: 	b.lo	#8
  5760: 	orr	x0, xzr, #0x7ff8000000000000
  5764: 	str	x0, [x19, #104]
  5768: 	ldr	d0, [x19, #944]
  5772: 	fmov	x0, d0
  5776: 	lsr	x3, x0, #48
  5780: 	mov	x10, #65521                     // =0xfff1
  5784: 	cmp	x3, x10
  5788: 	b.lo	#8
  5792: 	orr	x0, xzr, #0x7ff8000000000000
  5796: 	str	x0, [x19, #112]
  5800: 	mov	x0, x21
  5804: 	and	x0, x0, #0xffffffffffff
  5808: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5812: 	orr	x0, x0, x10
  5816: 	str	x0, [x19, #120]
  5820: 	mov	x0, x7
  5824: 	and	x0, x0, #0xffffffffffff
  5828: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5832: 	orr	x0, x0, x10
  5836: 	str	x0, [x19, #128]
  5840: 	mov	x0, x23
  5844: 	and	x0, x0, #0xffffffffffff
  5848: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5852: 	orr	x0, x0, x10
  5856: 	str	x0, [x19, #136]
  5860: 	mov	x0, x22
  5864: 	and	x0, x0, #0xffffffffffff
  5868: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  5872: 	orr	x0, x0, x10
  5876: 	str	x0, [x19, #144]
  5880: 	fmov	d0, d16
  5884: 	fmov	x0, d0
  5888: 	lsr	x3, x0, #48
  5892: 	mov	x10, #65521                     // =0xfff1
  5896: 	cmp	x3, x10
  5900: 	b.lo	#8
  5904: 	orr	x0, xzr, #0x7ff8000000000000
  5908: 	str	x0, [x19, #152]
  5912: 	ldr	d0, [x19, #960]
  5916: 	fmov	x0, d0
  5920: 	lsr	x3, x0, #48
  5924: 	mov	x10, #65521                     // =0xfff1
  5928: 	cmp	x3, x10
  5932: 	b.lo	#8
  5936: 	orr	x0, xzr, #0x7ff8000000000000
  5940: 	str	x0, [x19, #160]
  5944: 	ldr	d0, [x19, #976]
  5948: 	fmov	x0, d0
  5952: 	lsr	x3, x0, #48
  5956: 	mov	x10, #65521                     // =0xfff1
  5960: 	cmp	x3, x10
  5964: 	b.lo	#8
  5968: 	orr	x0, xzr, #0x7ff8000000000000
  5972: 	str	x0, [x19, #168]
  5976: 	ldr	d0, [x19, #992]
  5980: 	fmov	x0, d0
  5984: 	lsr	x3, x0, #48
  5988: 	mov	x10, #65521                     // =0xfff1
  5992: 	cmp	x3, x10
  5996: 	b.lo	#8
  6000: 	orr	x0, xzr, #0x7ff8000000000000
  6004: 	str	x0, [x19, #176]
  6008: 	ldr	d0, [x19, #1016]
  6012: 	fmov	x0, d0
  6016: 	lsr	x3, x0, #48
  6020: 	mov	x10, #65521                     // =0xfff1
  6024: 	cmp	x3, x10
  6028: 	b.lo	#8
  6032: 	orr	x0, xzr, #0x7ff8000000000000
  6036: 	str	x0, [x19, #184]
  6040: 	ldr	x0, [x19, #1000]
  6044: 	str	x0, [x19, #200]
  6048: 	ldr	d0, [x19, #936]
  6052: 	fmov	x0, d0
  6056: 	lsr	x3, x0, #48
  6060: 	mov	x10, #65521                     // =0xfff1
  6064: 	cmp	x3, x10
  6068: 	b.lo	#8
  6072: 	orr	x0, xzr, #0x7ff8000000000000
  6076: 	str	x0, [x19, #208]
  6080: 	mov	x9, #65472                      // =0xffc0
  6084: 	movk	x9, #1791, lsl #16
  6088: 	str	x9, [x19, #912]
  6092: 	str	x20, [x19, #920]
  6096: 	mov	x0, #48                         // =0x30
  6100: 	ldp	x29, x30, [sp]
  6104: 	ldp	x19, x20, [sp, #80]
  6108: 	ldp	x21, x22, [sp, #64]
  6112: 	ldp	x23, x24, [sp, #48]
  6116: 	ldp	x25, x26, [sp, #32]
  6120: 	ldr	x27, [sp, #24]
  6124: 	add	sp, sp, #96
  6128: 	ret
  6132: 	fmov	d0, d3
  6136: 	fmov	x0, d0
  6140: 	lsr	x3, x0, #48
  6144: 	mov	x10, #65521                     // =0xfff1
  6148: 	cmp	x3, x10
  6152: 	b.lo	#8
  6156: 	orr	x0, xzr, #0x7ff8000000000000
  6160: 	str	x0, [x19, #48]
  6164: 	fmov	d0, d4
  6168: 	fmov	x0, d0
  6172: 	lsr	x3, x0, #48
  6176: 	mov	x10, #65521                     // =0xfff1
  6180: 	cmp	x3, x10
  6184: 	b.lo	#8
  6188: 	orr	x0, xzr, #0x7ff8000000000000
  6192: 	str	x0, [x19, #56]
  6196: 	mov	x0, x5
  6200: 	and	x0, x0, #0xffffffffffff
  6204: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6208: 	orr	x0, x0, x10
  6212: 	str	x0, [x19, #64]
  6216: 	mov	x0, x6
  6220: 	and	x0, x0, #0xffffffffffff
  6224: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6228: 	orr	x0, x0, x10
  6232: 	str	x0, [x19, #72]
  6236: 	fmov	d0, d5
  6240: 	fmov	x0, d0
  6244: 	lsr	x3, x0, #48
  6248: 	mov	x10, #65521                     // =0xfff1
  6252: 	cmp	x3, x10
  6256: 	b.lo	#8
  6260: 	orr	x0, xzr, #0x7ff8000000000000
  6264: 	str	x0, [x19, #80]
  6268: 	fmov	d0, d6
  6272: 	fmov	x0, d0
  6276: 	lsr	x3, x0, #48
  6280: 	mov	x10, #65521                     // =0xfff1
  6284: 	cmp	x3, x10
  6288: 	b.lo	#8
  6292: 	orr	x0, xzr, #0x7ff8000000000000
  6296: 	str	x0, [x19, #88]
  6300: 	mov	x0, x4
  6304: 	and	x0, x0, #0xffffffffffff
  6308: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6312: 	orr	x0, x0, x10
  6316: 	str	x0, [x19, #96]
  6320: 	fmov	d0, d17
  6324: 	fmov	x0, d0
  6328: 	lsr	x3, x0, #48
  6332: 	mov	x10, #65521                     // =0xfff1
  6336: 	cmp	x3, x10
  6340: 	b.lo	#8
  6344: 	orr	x0, xzr, #0x7ff8000000000000
  6348: 	str	x0, [x19, #104]
  6352: 	ldr	d0, [x19, #944]
  6356: 	fmov	x0, d0
  6360: 	lsr	x3, x0, #48
  6364: 	mov	x10, #65521                     // =0xfff1
  6368: 	cmp	x3, x10
  6372: 	b.lo	#8
  6376: 	orr	x0, xzr, #0x7ff8000000000000
  6380: 	str	x0, [x19, #112]
  6384: 	mov	x0, x21
  6388: 	and	x0, x0, #0xffffffffffff
  6392: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6396: 	orr	x0, x0, x10
  6400: 	str	x0, [x19, #120]
  6404: 	mov	x0, x7
  6408: 	and	x0, x0, #0xffffffffffff
  6412: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6416: 	orr	x0, x0, x10
  6420: 	str	x0, [x19, #128]
  6424: 	mov	x0, x23
  6428: 	and	x0, x0, #0xffffffffffff
  6432: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6436: 	orr	x0, x0, x10
  6440: 	str	x0, [x19, #136]
  6444: 	mov	x0, x22
  6448: 	and	x0, x0, #0xffffffffffff
  6452: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6456: 	orr	x0, x0, x10
  6460: 	str	x0, [x19, #144]
  6464: 	fmov	d0, d16
  6468: 	fmov	x0, d0
  6472: 	lsr	x3, x0, #48
  6476: 	mov	x10, #65521                     // =0xfff1
  6480: 	cmp	x3, x10
  6484: 	b.lo	#8
  6488: 	orr	x0, xzr, #0x7ff8000000000000
  6492: 	str	x0, [x19, #152]
  6496: 	ldr	d0, [x19, #960]
  6500: 	fmov	x0, d0
  6504: 	lsr	x3, x0, #48
  6508: 	mov	x10, #65521                     // =0xfff1
  6512: 	cmp	x3, x10
  6516: 	b.lo	#8
  6520: 	orr	x0, xzr, #0x7ff8000000000000
  6524: 	str	x0, [x19, #160]
  6528: 	ldr	d0, [x19, #976]
  6532: 	fmov	x0, d0
  6536: 	lsr	x3, x0, #48
  6540: 	mov	x10, #65521                     // =0xfff1
  6544: 	cmp	x3, x10
  6548: 	b.lo	#8
  6552: 	orr	x0, xzr, #0x7ff8000000000000
  6556: 	str	x0, [x19, #168]
  6560: 	ldr	d0, [x19, #992]
  6564: 	fmov	x0, d0
  6568: 	lsr	x3, x0, #48
  6572: 	mov	x10, #65521                     // =0xfff1
  6576: 	cmp	x3, x10
  6580: 	b.lo	#8
  6584: 	orr	x0, xzr, #0x7ff8000000000000
  6588: 	str	x0, [x19, #176]
  6592: 	ldr	d0, [x19, #1016]
  6596: 	fmov	x0, d0
  6600: 	lsr	x3, x0, #48
  6604: 	mov	x10, #65521                     // =0xfff1
  6608: 	cmp	x3, x10
  6612: 	b.lo	#8
  6616: 	orr	x0, xzr, #0x7ff8000000000000
  6620: 	str	x0, [x19, #184]
  6624: 	ldr	d0, [x19, #1040]
  6628: 	fmov	x0, d0
  6632: 	lsr	x3, x0, #48
  6636: 	mov	x10, #65521                     // =0xfff1
  6640: 	cmp	x3, x10
  6644: 	b.lo	#8
  6648: 	orr	x0, xzr, #0x7ff8000000000000
  6652: 	str	x0, [x19, #192]
  6656: 	fmov	d0, d6
  6660: 	fmov	x0, d0
  6664: 	lsr	x3, x0, #48
  6668: 	mov	x10, #65521                     // =0xfff1
  6672: 	cmp	x3, x10
  6676: 	b.lo	#8
  6680: 	orr	x0, xzr, #0x7ff8000000000000
  6684: 	str	x0, [x19, #200]
  6688: 	ldr	d0, [x19, #936]
  6692: 	fmov	x0, d0
  6696: 	lsr	x3, x0, #48
  6700: 	mov	x10, #65521                     // =0xfff1
  6704: 	cmp	x3, x10
  6708: 	b.lo	#8
  6712: 	orr	x0, xzr, #0x7ff8000000000000
  6716: 	str	x0, [x19, #208]
  6720: 	ldr	d0, [x19, #1048]
  6724: 	fmov	x0, d0
  6728: 	lsr	x3, x0, #48
  6732: 	mov	x10, #65521                     // =0xfff1
  6736: 	cmp	x3, x10
  6740: 	b.lo	#8
  6744: 	orr	x0, xzr, #0x7ff8000000000000
  6748: 	str	x0, [x19, #216]
  6752: 	mov	w9, #268435392                  // =0xfffffc0
  6756: 	str	x9, [x19, #912]
  6760: 	str	x20, [x19, #920]
  6764: 	mov	x0, #51                         // =0x33
  6768: 	ldp	x29, x30, [sp]
  6772: 	ldp	x19, x20, [sp, #80]
  6776: 	ldp	x21, x22, [sp, #64]
  6780: 	ldp	x23, x24, [sp, #48]
  6784: 	ldp	x25, x26, [sp, #32]
  6788: 	ldr	x27, [sp, #24]
  6792: 	add	sp, sp, #96
  6796: 	ret
  6800: 	fmov	d0, d3
  6804: 	fmov	x0, d0
  6808: 	lsr	x3, x0, #48
  6812: 	mov	x10, #65521                     // =0xfff1
  6816: 	cmp	x3, x10
  6820: 	b.lo	#8
  6824: 	orr	x0, xzr, #0x7ff8000000000000
  6828: 	str	x0, [x19, #48]
  6832: 	fmov	d0, d4
  6836: 	fmov	x0, d0
  6840: 	lsr	x3, x0, #48
  6844: 	mov	x10, #65521                     // =0xfff1
  6848: 	cmp	x3, x10
  6852: 	b.lo	#8
  6856: 	orr	x0, xzr, #0x7ff8000000000000
  6860: 	str	x0, [x19, #56]
  6864: 	mov	x0, x5
  6868: 	and	x0, x0, #0xffffffffffff
  6872: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6876: 	orr	x0, x0, x10
  6880: 	str	x0, [x19, #64]
  6884: 	mov	x0, x6
  6888: 	and	x0, x0, #0xffffffffffff
  6892: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6896: 	orr	x0, x0, x10
  6900: 	str	x0, [x19, #72]
  6904: 	fmov	d0, d5
  6908: 	fmov	x0, d0
  6912: 	lsr	x3, x0, #48
  6916: 	mov	x10, #65521                     // =0xfff1
  6920: 	cmp	x3, x10
  6924: 	b.lo	#8
  6928: 	orr	x0, xzr, #0x7ff8000000000000
  6932: 	str	x0, [x19, #80]
  6936: 	fmov	d0, d6
  6940: 	fmov	x0, d0
  6944: 	lsr	x3, x0, #48
  6948: 	mov	x10, #65521                     // =0xfff1
  6952: 	cmp	x3, x10
  6956: 	b.lo	#8
  6960: 	orr	x0, xzr, #0x7ff8000000000000
  6964: 	str	x0, [x19, #88]
  6968: 	mov	x0, x4
  6972: 	and	x0, x0, #0xffffffffffff
  6976: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  6980: 	orr	x0, x0, x10
  6984: 	str	x0, [x19, #96]
  6988: 	fmov	d0, d17
  6992: 	fmov	x0, d0
  6996: 	lsr	x3, x0, #48
  7000: 	mov	x10, #65521                     // =0xfff1
  7004: 	cmp	x3, x10
  7008: 	b.lo	#8
  7012: 	orr	x0, xzr, #0x7ff8000000000000
  7016: 	str	x0, [x19, #104]
  7020: 	ldr	d0, [x19, #944]
  7024: 	fmov	x0, d0
  7028: 	lsr	x3, x0, #48
  7032: 	mov	x10, #65521                     // =0xfff1
  7036: 	cmp	x3, x10
  7040: 	b.lo	#8
  7044: 	orr	x0, xzr, #0x7ff8000000000000
  7048: 	str	x0, [x19, #112]
  7052: 	mov	x0, x21
  7056: 	and	x0, x0, #0xffffffffffff
  7060: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7064: 	orr	x0, x0, x10
  7068: 	str	x0, [x19, #120]
  7072: 	mov	x0, x7
  7076: 	and	x0, x0, #0xffffffffffff
  7080: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7084: 	orr	x0, x0, x10
  7088: 	str	x0, [x19, #128]
  7092: 	mov	x0, x23
  7096: 	and	x0, x0, #0xffffffffffff
  7100: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7104: 	orr	x0, x0, x10
  7108: 	str	x0, [x19, #136]
  7112: 	mov	x0, x22
  7116: 	and	x0, x0, #0xffffffffffff
  7120: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7124: 	orr	x0, x0, x10
  7128: 	str	x0, [x19, #144]
  7132: 	fmov	d0, d16
  7136: 	fmov	x0, d0
  7140: 	lsr	x3, x0, #48
  7144: 	mov	x10, #65521                     // =0xfff1
  7148: 	cmp	x3, x10
  7152: 	b.lo	#8
  7156: 	orr	x0, xzr, #0x7ff8000000000000
  7160: 	str	x0, [x19, #152]
  7164: 	ldr	d0, [x19, #960]
  7168: 	fmov	x0, d0
  7172: 	lsr	x3, x0, #48
  7176: 	mov	x10, #65521                     // =0xfff1
  7180: 	cmp	x3, x10
  7184: 	b.lo	#8
  7188: 	orr	x0, xzr, #0x7ff8000000000000
  7192: 	str	x0, [x19, #160]
  7196: 	ldr	d0, [x19, #976]
  7200: 	fmov	x0, d0
  7204: 	lsr	x3, x0, #48
  7208: 	mov	x10, #65521                     // =0xfff1
  7212: 	cmp	x3, x10
  7216: 	b.lo	#8
  7220: 	orr	x0, xzr, #0x7ff8000000000000
  7224: 	str	x0, [x19, #168]
  7228: 	ldr	d0, [x19, #992]
  7232: 	fmov	x0, d0
  7236: 	lsr	x3, x0, #48
  7240: 	mov	x10, #65521                     // =0xfff1
  7244: 	cmp	x3, x10
  7248: 	b.lo	#8
  7252: 	orr	x0, xzr, #0x7ff8000000000000
  7256: 	str	x0, [x19, #176]
  7260: 	ldr	d0, [x19, #1016]
  7264: 	fmov	x0, d0
  7268: 	lsr	x3, x0, #48
  7272: 	mov	x10, #65521                     // =0xfff1
  7276: 	cmp	x3, x10
  7280: 	b.lo	#8
  7284: 	orr	x0, xzr, #0x7ff8000000000000
  7288: 	str	x0, [x19, #184]
  7292: 	ldr	d0, [x19, #1040]
  7296: 	fmov	x0, d0
  7300: 	lsr	x3, x0, #48
  7304: 	mov	x10, #65521                     // =0xfff1
  7308: 	cmp	x3, x10
  7312: 	b.lo	#8
  7316: 	orr	x0, xzr, #0x7ff8000000000000
  7320: 	str	x0, [x19, #192]
  7324: 	fmov	d0, d6
  7328: 	fmov	x0, d0
  7332: 	lsr	x3, x0, #48
  7336: 	mov	x10, #65521                     // =0xfff1
  7340: 	cmp	x3, x10
  7344: 	b.lo	#8
  7348: 	orr	x0, xzr, #0x7ff8000000000000
  7352: 	str	x0, [x19, #200]
  7356: 	ldr	d0, [x19, #936]
  7360: 	fmov	x0, d0
  7364: 	lsr	x3, x0, #48
  7368: 	mov	x10, #65521                     // =0xfff1
  7372: 	cmp	x3, x10
  7376: 	b.lo	#8
  7380: 	orr	x0, xzr, #0x7ff8000000000000
  7384: 	str	x0, [x19, #208]
  7388: 	ldr	d0, [x19, #1048]
  7392: 	fmov	x0, d0
  7396: 	lsr	x3, x0, #48
  7400: 	mov	x10, #65521                     // =0xfff1
  7404: 	cmp	x3, x10
  7408: 	b.lo	#8
  7412: 	orr	x0, xzr, #0x7ff8000000000000
  7416: 	str	x0, [x19, #216]
  7420: 	ldr	d0, [x19, #1064]
  7424: 	fmov	x0, d0
  7428: 	lsr	x3, x0, #48
  7432: 	mov	x10, #65521                     // =0xfff1
  7436: 	cmp	x3, x10
  7440: 	b.lo	#8
  7444: 	orr	x0, xzr, #0x7ff8000000000000
  7448: 	str	x0, [x19, #224]
  7452: 	ldr	d0, [x19, #1072]
  7456: 	fmov	x0, d0
  7460: 	lsr	x3, x0, #48
  7464: 	mov	x10, #65521                     // =0xfff1
  7468: 	cmp	x3, x10
  7472: 	b.lo	#8
  7476: 	orr	x0, xzr, #0x7ff8000000000000
  7480: 	str	x0, [x19, #232]
  7484: 	ldr	d0, [x19, #1080]
  7488: 	fmov	x0, d0
  7492: 	lsr	x3, x0, #48
  7496: 	mov	x10, #65521                     // =0xfff1
  7500: 	cmp	x3, x10
  7504: 	b.lo	#8
  7508: 	orr	x0, xzr, #0x7ff8000000000000
  7512: 	str	x0, [x19, #240]
  7516: 	mov	w9, #2147483584                 // =0x7fffffc0
  7520: 	str	x9, [x19, #912]
  7524: 	str	x20, [x19, #920]
  7528: 	mov	x0, #54                         // =0x36
  7532: 	ldp	x29, x30, [sp]
  7536: 	ldp	x19, x20, [sp, #80]
  7540: 	ldp	x21, x22, [sp, #64]
  7544: 	ldp	x23, x24, [sp, #48]
  7548: 	ldp	x25, x26, [sp, #32]
  7552: 	ldr	x27, [sp, #24]
  7556: 	add	sp, sp, #96
  7560: 	ret
  7564: 	fmov	d0, d3
  7568: 	fmov	x0, d0
  7572: 	lsr	x3, x0, #48
  7576: 	mov	x10, #65521                     // =0xfff1
  7580: 	cmp	x3, x10
  7584: 	b.lo	#8
  7588: 	orr	x0, xzr, #0x7ff8000000000000
  7592: 	str	x0, [x19, #48]
  7596: 	fmov	d0, d4
  7600: 	fmov	x0, d0
  7604: 	lsr	x3, x0, #48
  7608: 	mov	x10, #65521                     // =0xfff1
  7612: 	cmp	x3, x10
  7616: 	b.lo	#8
  7620: 	orr	x0, xzr, #0x7ff8000000000000
  7624: 	str	x0, [x19, #56]
  7628: 	mov	x0, x5
  7632: 	and	x0, x0, #0xffffffffffff
  7636: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7640: 	orr	x0, x0, x10
  7644: 	str	x0, [x19, #64]
  7648: 	mov	x0, x6
  7652: 	and	x0, x0, #0xffffffffffff
  7656: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7660: 	orr	x0, x0, x10
  7664: 	str	x0, [x19, #72]
  7668: 	fmov	d0, d5
  7672: 	fmov	x0, d0
  7676: 	lsr	x3, x0, #48
  7680: 	mov	x10, #65521                     // =0xfff1
  7684: 	cmp	x3, x10
  7688: 	b.lo	#8
  7692: 	orr	x0, xzr, #0x7ff8000000000000
  7696: 	str	x0, [x19, #80]
  7700: 	fmov	d0, d6
  7704: 	fmov	x0, d0
  7708: 	lsr	x3, x0, #48
  7712: 	mov	x10, #65521                     // =0xfff1
  7716: 	cmp	x3, x10
  7720: 	b.lo	#8
  7724: 	orr	x0, xzr, #0x7ff8000000000000
  7728: 	str	x0, [x19, #88]
  7732: 	mov	x0, x4
  7736: 	and	x0, x0, #0xffffffffffff
  7740: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7744: 	orr	x0, x0, x10
  7748: 	str	x0, [x19, #96]
  7752: 	fmov	d0, d17
  7756: 	fmov	x0, d0
  7760: 	lsr	x3, x0, #48
  7764: 	mov	x10, #65521                     // =0xfff1
  7768: 	cmp	x3, x10
  7772: 	b.lo	#8
  7776: 	orr	x0, xzr, #0x7ff8000000000000
  7780: 	str	x0, [x19, #104]
  7784: 	ldr	d0, [x19, #944]
  7788: 	fmov	x0, d0
  7792: 	lsr	x3, x0, #48
  7796: 	mov	x10, #65521                     // =0xfff1
  7800: 	cmp	x3, x10
  7804: 	b.lo	#8
  7808: 	orr	x0, xzr, #0x7ff8000000000000
  7812: 	str	x0, [x19, #112]
  7816: 	mov	x0, x21
  7820: 	and	x0, x0, #0xffffffffffff
  7824: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7828: 	orr	x0, x0, x10
  7832: 	str	x0, [x19, #120]
  7836: 	mov	x0, x7
  7840: 	and	x0, x0, #0xffffffffffff
  7844: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7848: 	orr	x0, x0, x10
  7852: 	str	x0, [x19, #128]
  7856: 	mov	x0, x23
  7860: 	and	x0, x0, #0xffffffffffff
  7864: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7868: 	orr	x0, x0, x10
  7872: 	str	x0, [x19, #136]
  7876: 	mov	x0, x22
  7880: 	and	x0, x0, #0xffffffffffff
  7884: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  7888: 	orr	x0, x0, x10
  7892: 	str	x0, [x19, #144]
  7896: 	fmov	d0, d16
  7900: 	fmov	x0, d0
  7904: 	lsr	x3, x0, #48
  7908: 	mov	x10, #65521                     // =0xfff1
  7912: 	cmp	x3, x10
  7916: 	b.lo	#8
  7920: 	orr	x0, xzr, #0x7ff8000000000000
  7924: 	str	x0, [x19, #152]
  7928: 	ldr	d0, [x19, #960]
  7932: 	fmov	x0, d0
  7936: 	lsr	x3, x0, #48
  7940: 	mov	x10, #65521                     // =0xfff1
  7944: 	cmp	x3, x10
  7948: 	b.lo	#8
  7952: 	orr	x0, xzr, #0x7ff8000000000000
  7956: 	str	x0, [x19, #160]
  7960: 	ldr	d0, [x19, #976]
  7964: 	fmov	x0, d0
  7968: 	lsr	x3, x0, #48
  7972: 	mov	x10, #65521                     // =0xfff1
  7976: 	cmp	x3, x10
  7980: 	b.lo	#8
  7984: 	orr	x0, xzr, #0x7ff8000000000000
  7988: 	str	x0, [x19, #168]
  7992: 	ldr	d0, [x19, #992]
  7996: 	fmov	x0, d0
  8000: 	lsr	x3, x0, #48
  8004: 	mov	x10, #65521                     // =0xfff1
  8008: 	cmp	x3, x10
  8012: 	b.lo	#8
  8016: 	orr	x0, xzr, #0x7ff8000000000000
  8020: 	str	x0, [x19, #176]
  8024: 	ldr	d0, [x19, #1016]
  8028: 	fmov	x0, d0
  8032: 	lsr	x3, x0, #48
  8036: 	mov	x10, #65521                     // =0xfff1
  8040: 	cmp	x3, x10
  8044: 	b.lo	#8
  8048: 	orr	x0, xzr, #0x7ff8000000000000
  8052: 	str	x0, [x19, #184]
  8056: 	ldr	d0, [x19, #1040]
  8060: 	fmov	x0, d0
  8064: 	lsr	x3, x0, #48
  8068: 	mov	x10, #65521                     // =0xfff1
  8072: 	cmp	x3, x10
  8076: 	b.lo	#8
  8080: 	orr	x0, xzr, #0x7ff8000000000000
  8084: 	str	x0, [x19, #192]
  8088: 	fmov	d0, d6
  8092: 	fmov	x0, d0
  8096: 	lsr	x3, x0, #48
  8100: 	mov	x10, #65521                     // =0xfff1
  8104: 	cmp	x3, x10
  8108: 	b.lo	#8
  8112: 	orr	x0, xzr, #0x7ff8000000000000
  8116: 	str	x0, [x19, #200]
  8120: 	ldr	d0, [x19, #936]
  8124: 	fmov	x0, d0
  8128: 	lsr	x3, x0, #48
  8132: 	mov	x10, #65521                     // =0xfff1
  8136: 	cmp	x3, x10
  8140: 	b.lo	#8
  8144: 	orr	x0, xzr, #0x7ff8000000000000
  8148: 	str	x0, [x19, #208]
  8152: 	ldr	d0, [x19, #1048]
  8156: 	fmov	x0, d0
  8160: 	lsr	x3, x0, #48
  8164: 	mov	x10, #65521                     // =0xfff1
  8168: 	cmp	x3, x10
  8172: 	b.lo	#8
  8176: 	orr	x0, xzr, #0x7ff8000000000000
  8180: 	str	x0, [x19, #216]
  8184: 	ldr	d0, [x19, #1064]
  8188: 	fmov	x0, d0
  8192: 	lsr	x3, x0, #48
  8196: 	mov	x10, #65521                     // =0xfff1
  8200: 	cmp	x3, x10
  8204: 	b.lo	#8
  8208: 	orr	x0, xzr, #0x7ff8000000000000
  8212: 	str	x0, [x19, #224]
  8216: 	ldr	d0, [x19, #1104]
  8220: 	fmov	x0, d0
  8224: 	lsr	x3, x0, #48
  8228: 	mov	x10, #65521                     // =0xfff1
  8232: 	cmp	x3, x10
  8236: 	b.lo	#8
  8240: 	orr	x0, xzr, #0x7ff8000000000000
  8244: 	str	x0, [x19, #232]
  8248: 	ldr	d0, [x19, #1080]
  8252: 	fmov	x0, d0
  8256: 	lsr	x3, x0, #48
  8260: 	mov	x10, #65521                     // =0xfff1
  8264: 	cmp	x3, x10
  8268: 	b.lo	#8
  8272: 	orr	x0, xzr, #0x7ff8000000000000
  8276: 	str	x0, [x19, #240]
  8280: 	fmov	d0, d7
  8284: 	fmov	x0, d0
  8288: 	lsr	x3, x0, #48
  8292: 	mov	x10, #65521                     // =0xfff1
  8296: 	cmp	x3, x10
  8300: 	b.lo	#8
  8304: 	orr	x0, xzr, #0x7ff8000000000000
  8308: 	str	x0, [x19, #248]
  8312: 	ldr	d0, [x19, #1112]
  8316: 	fmov	x0, d0
  8320: 	lsr	x3, x0, #48
  8324: 	mov	x10, #65521                     // =0xfff1
  8328: 	cmp	x3, x10
  8332: 	b.lo	#8
  8336: 	orr	x0, xzr, #0x7ff8000000000000
  8340: 	str	x0, [x19, #256]
  8344: 	ldr	d0, [x19, #1128]
  8348: 	fmov	x0, d0
  8352: 	lsr	x3, x0, #48
  8356: 	mov	x10, #65521                     // =0xfff1
  8360: 	cmp	x3, x10
  8364: 	b.lo	#8
  8368: 	orr	x0, xzr, #0x7ff8000000000000
  8372: 	str	x0, [x19, #264]
  8376: 	mov	x9, #17179869120                // =0x3ffffffc0
  8380: 	str	x9, [x19, #912]
  8384: 	str	x20, [x19, #920]
  8388: 	mov	x0, #59                         // =0x3b
  8392: 	ldp	x29, x30, [sp]
  8396: 	ldp	x19, x20, [sp, #80]
  8400: 	ldp	x21, x22, [sp, #64]
  8404: 	ldp	x23, x24, [sp, #48]
  8408: 	ldp	x25, x26, [sp, #32]
  8412: 	ldr	x27, [sp, #24]
  8416: 	add	sp, sp, #96
  8420: 	ret
  8424: 	fmov	d0, d3
  8428: 	fmov	x0, d0
  8432: 	lsr	x3, x0, #48
  8436: 	mov	x10, #65521                     // =0xfff1
  8440: 	cmp	x3, x10
  8444: 	b.lo	#8
  8448: 	orr	x0, xzr, #0x7ff8000000000000
  8452: 	str	x0, [x19, #48]
  8456: 	fmov	d0, d4
  8460: 	fmov	x0, d0
  8464: 	lsr	x3, x0, #48
  8468: 	mov	x10, #65521                     // =0xfff1
  8472: 	cmp	x3, x10
  8476: 	b.lo	#8
  8480: 	orr	x0, xzr, #0x7ff8000000000000
  8484: 	str	x0, [x19, #56]
  8488: 	mov	x0, x5
  8492: 	and	x0, x0, #0xffffffffffff
  8496: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8500: 	orr	x0, x0, x10
  8504: 	str	x0, [x19, #64]
  8508: 	mov	x0, x6
  8512: 	and	x0, x0, #0xffffffffffff
  8516: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8520: 	orr	x0, x0, x10
  8524: 	str	x0, [x19, #72]
  8528: 	fmov	d0, d5
  8532: 	fmov	x0, d0
  8536: 	lsr	x3, x0, #48
  8540: 	mov	x10, #65521                     // =0xfff1
  8544: 	cmp	x3, x10
  8548: 	b.lo	#8
  8552: 	orr	x0, xzr, #0x7ff8000000000000
  8556: 	str	x0, [x19, #80]
  8560: 	fmov	d0, d6
  8564: 	fmov	x0, d0
  8568: 	lsr	x3, x0, #48
  8572: 	mov	x10, #65521                     // =0xfff1
  8576: 	cmp	x3, x10
  8580: 	b.lo	#8
  8584: 	orr	x0, xzr, #0x7ff8000000000000
  8588: 	str	x0, [x19, #88]
  8592: 	mov	x0, x4
  8596: 	and	x0, x0, #0xffffffffffff
  8600: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8604: 	orr	x0, x0, x10
  8608: 	str	x0, [x19, #96]
  8612: 	fmov	d0, d17
  8616: 	fmov	x0, d0
  8620: 	lsr	x3, x0, #48
  8624: 	mov	x10, #65521                     // =0xfff1
  8628: 	cmp	x3, x10
  8632: 	b.lo	#8
  8636: 	orr	x0, xzr, #0x7ff8000000000000
  8640: 	str	x0, [x19, #104]
  8644: 	ldr	d0, [x19, #944]
  8648: 	fmov	x0, d0
  8652: 	lsr	x3, x0, #48
  8656: 	mov	x10, #65521                     // =0xfff1
  8660: 	cmp	x3, x10
  8664: 	b.lo	#8
  8668: 	orr	x0, xzr, #0x7ff8000000000000
  8672: 	str	x0, [x19, #112]
  8676: 	mov	x0, x21
  8680: 	and	x0, x0, #0xffffffffffff
  8684: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8688: 	orr	x0, x0, x10
  8692: 	str	x0, [x19, #120]
  8696: 	mov	x0, x7
  8700: 	and	x0, x0, #0xffffffffffff
  8704: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8708: 	orr	x0, x0, x10
  8712: 	str	x0, [x19, #128]
  8716: 	mov	x0, x23
  8720: 	and	x0, x0, #0xffffffffffff
  8724: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8728: 	orr	x0, x0, x10
  8732: 	str	x0, [x19, #136]
  8736: 	mov	x0, x22
  8740: 	and	x0, x0, #0xffffffffffff
  8744: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  8748: 	orr	x0, x0, x10
  8752: 	str	x0, [x19, #144]
  8756: 	fmov	d0, d16
  8760: 	fmov	x0, d0
  8764: 	lsr	x3, x0, #48
  8768: 	mov	x10, #65521                     // =0xfff1
  8772: 	cmp	x3, x10
  8776: 	b.lo	#8
  8780: 	orr	x0, xzr, #0x7ff8000000000000
  8784: 	str	x0, [x19, #152]
  8788: 	ldr	d0, [x19, #960]
  8792: 	fmov	x0, d0
  8796: 	lsr	x3, x0, #48
  8800: 	mov	x10, #65521                     // =0xfff1
  8804: 	cmp	x3, x10
  8808: 	b.lo	#8
  8812: 	orr	x0, xzr, #0x7ff8000000000000
  8816: 	str	x0, [x19, #160]
  8820: 	ldr	d0, [x19, #976]
  8824: 	fmov	x0, d0
  8828: 	lsr	x3, x0, #48
  8832: 	mov	x10, #65521                     // =0xfff1
  8836: 	cmp	x3, x10
  8840: 	b.lo	#8
  8844: 	orr	x0, xzr, #0x7ff8000000000000
  8848: 	str	x0, [x19, #168]
  8852: 	ldr	d0, [x19, #992]
  8856: 	fmov	x0, d0
  8860: 	lsr	x3, x0, #48
  8864: 	mov	x10, #65521                     // =0xfff1
  8868: 	cmp	x3, x10
  8872: 	b.lo	#8
  8876: 	orr	x0, xzr, #0x7ff8000000000000
  8880: 	str	x0, [x19, #176]
  8884: 	ldr	d0, [x19, #1016]
  8888: 	fmov	x0, d0
  8892: 	lsr	x3, x0, #48
  8896: 	mov	x10, #65521                     // =0xfff1
  8900: 	cmp	x3, x10
  8904: 	b.lo	#8
  8908: 	orr	x0, xzr, #0x7ff8000000000000
  8912: 	str	x0, [x19, #184]
  8916: 	ldr	d0, [x19, #1040]
  8920: 	fmov	x0, d0
  8924: 	lsr	x3, x0, #48
  8928: 	mov	x10, #65521                     // =0xfff1
  8932: 	cmp	x3, x10
  8936: 	b.lo	#8
  8940: 	orr	x0, xzr, #0x7ff8000000000000
  8944: 	str	x0, [x19, #192]
  8948: 	fmov	d0, d6
  8952: 	fmov	x0, d0
  8956: 	lsr	x3, x0, #48
  8960: 	mov	x10, #65521                     // =0xfff1
  8964: 	cmp	x3, x10
  8968: 	b.lo	#8
  8972: 	orr	x0, xzr, #0x7ff8000000000000
  8976: 	str	x0, [x19, #200]
  8980: 	ldr	d0, [x19, #936]
  8984: 	fmov	x0, d0
  8988: 	lsr	x3, x0, #48
  8992: 	mov	x10, #65521                     // =0xfff1
  8996: 	cmp	x3, x10
  9000: 	b.lo	#8
  9004: 	orr	x0, xzr, #0x7ff8000000000000
  9008: 	str	x0, [x19, #208]
  9012: 	ldr	d0, [x19, #1048]
  9016: 	fmov	x0, d0
  9020: 	lsr	x3, x0, #48
  9024: 	mov	x10, #65521                     // =0xfff1
  9028: 	cmp	x3, x10
  9032: 	b.lo	#8
  9036: 	orr	x0, xzr, #0x7ff8000000000000
  9040: 	str	x0, [x19, #216]
  9044: 	ldr	d0, [x19, #1064]
  9048: 	fmov	x0, d0
  9052: 	lsr	x3, x0, #48
  9056: 	mov	x10, #65521                     // =0xfff1
  9060: 	cmp	x3, x10
  9064: 	b.lo	#8
  9068: 	orr	x0, xzr, #0x7ff8000000000000
  9072: 	str	x0, [x19, #224]
  9076: 	ldr	d0, [x19, #1104]
  9080: 	fmov	x0, d0
  9084: 	lsr	x3, x0, #48
  9088: 	mov	x10, #65521                     // =0xfff1
  9092: 	cmp	x3, x10
  9096: 	b.lo	#8
  9100: 	orr	x0, xzr, #0x7ff8000000000000
  9104: 	str	x0, [x19, #232]
  9108: 	ldr	d0, [x19, #1080]
  9112: 	fmov	x0, d0
  9116: 	lsr	x3, x0, #48
  9120: 	mov	x10, #65521                     // =0xfff1
  9124: 	cmp	x3, x10
  9128: 	b.lo	#8
  9132: 	orr	x0, xzr, #0x7ff8000000000000
  9136: 	str	x0, [x19, #240]
  9140: 	fmov	d0, d7
  9144: 	fmov	x0, d0
  9148: 	lsr	x3, x0, #48
  9152: 	mov	x10, #65521                     // =0xfff1
  9156: 	cmp	x3, x10
  9160: 	b.lo	#8
  9164: 	orr	x0, xzr, #0x7ff8000000000000
  9168: 	str	x0, [x19, #248]
  9172: 	ldr	d0, [x19, #1112]
  9176: 	fmov	x0, d0
  9180: 	lsr	x3, x0, #48
  9184: 	mov	x10, #65521                     // =0xfff1
  9188: 	cmp	x3, x10
  9192: 	b.lo	#8
  9196: 	orr	x0, xzr, #0x7ff8000000000000
  9200: 	str	x0, [x19, #256]
  9204: 	ldr	d0, [x19, #1128]
  9208: 	fmov	x0, d0
  9212: 	lsr	x3, x0, #48
  9216: 	mov	x10, #65521                     // =0xfff1
  9220: 	cmp	x3, x10
  9224: 	b.lo	#8
  9228: 	orr	x0, xzr, #0x7ff8000000000000
  9232: 	str	x0, [x19, #264]
  9236: 	ldr	d0, [x19, #1144]
  9240: 	fmov	x0, d0
  9244: 	lsr	x3, x0, #48
  9248: 	mov	x10, #65521                     // =0xfff1
  9252: 	cmp	x3, x10
  9256: 	b.lo	#8
  9260: 	orr	x0, xzr, #0x7ff8000000000000
  9264: 	str	x0, [x19, #272]
  9268: 	ldr	d0, [x19, #1152]
  9272: 	fmov	x0, d0
  9276: 	lsr	x3, x0, #48
  9280: 	mov	x10, #65521                     // =0xfff1
  9284: 	cmp	x3, x10
  9288: 	b.lo	#8
  9292: 	orr	x0, xzr, #0x7ff8000000000000
  9296: 	str	x0, [x19, #280]
  9300: 	ldr	d0, [x19, #1160]
  9304: 	fmov	x0, d0
  9308: 	lsr	x3, x0, #48
  9312: 	mov	x10, #65521                     // =0xfff1
  9316: 	cmp	x3, x10
  9320: 	b.lo	#8
  9324: 	orr	x0, xzr, #0x7ff8000000000000
  9328: 	str	x0, [x19, #288]
  9332: 	mov	x9, #137438953408               // =0x1fffffffc0
  9336: 	str	x9, [x19, #912]
  9340: 	str	x20, [x19, #920]
  9344: 	mov	x0, #62                         // =0x3e
  9348: 	ldp	x29, x30, [sp]
  9352: 	ldp	x19, x20, [sp, #80]
  9356: 	ldp	x21, x22, [sp, #64]
  9360: 	ldp	x23, x24, [sp, #48]
  9364: 	ldp	x25, x26, [sp, #32]
  9368: 	ldr	x27, [sp, #24]
  9372: 	add	sp, sp, #96
  9376: 	ret
  9380: 	fmov	d0, d3
  9384: 	fmov	x0, d0
  9388: 	lsr	x3, x0, #48
  9392: 	mov	x10, #65521                     // =0xfff1
  9396: 	cmp	x3, x10
  9400: 	b.lo	#8
  9404: 	orr	x0, xzr, #0x7ff8000000000000
  9408: 	str	x0, [x19, #48]
  9412: 	fmov	d0, d4
  9416: 	fmov	x0, d0
  9420: 	lsr	x3, x0, #48
  9424: 	mov	x10, #65521                     // =0xfff1
  9428: 	cmp	x3, x10
  9432: 	b.lo	#8
  9436: 	orr	x0, xzr, #0x7ff8000000000000
  9440: 	str	x0, [x19, #56]
  9444: 	mov	x0, x5
  9448: 	and	x0, x0, #0xffffffffffff
  9452: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9456: 	orr	x0, x0, x10
  9460: 	str	x0, [x19, #64]
  9464: 	mov	x0, x6
  9468: 	and	x0, x0, #0xffffffffffff
  9472: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9476: 	orr	x0, x0, x10
  9480: 	str	x0, [x19, #72]
  9484: 	fmov	d0, d5
  9488: 	fmov	x0, d0
  9492: 	lsr	x3, x0, #48
  9496: 	mov	x10, #65521                     // =0xfff1
  9500: 	cmp	x3, x10
  9504: 	b.lo	#8
  9508: 	orr	x0, xzr, #0x7ff8000000000000
  9512: 	str	x0, [x19, #80]
  9516: 	fmov	d0, d6
  9520: 	fmov	x0, d0
  9524: 	lsr	x3, x0, #48
  9528: 	mov	x10, #65521                     // =0xfff1
  9532: 	cmp	x3, x10
  9536: 	b.lo	#8
  9540: 	orr	x0, xzr, #0x7ff8000000000000
  9544: 	str	x0, [x19, #88]
  9548: 	mov	x0, x4
  9552: 	and	x0, x0, #0xffffffffffff
  9556: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9560: 	orr	x0, x0, x10
  9564: 	str	x0, [x19, #96]
  9568: 	fmov	d0, d17
  9572: 	fmov	x0, d0
  9576: 	lsr	x3, x0, #48
  9580: 	mov	x10, #65521                     // =0xfff1
  9584: 	cmp	x3, x10
  9588: 	b.lo	#8
  9592: 	orr	x0, xzr, #0x7ff8000000000000
  9596: 	str	x0, [x19, #104]
  9600: 	ldr	d0, [x19, #944]
  9604: 	fmov	x0, d0
  9608: 	lsr	x3, x0, #48
  9612: 	mov	x10, #65521                     // =0xfff1
  9616: 	cmp	x3, x10
  9620: 	b.lo	#8
  9624: 	orr	x0, xzr, #0x7ff8000000000000
  9628: 	str	x0, [x19, #112]
  9632: 	mov	x0, x21
  9636: 	and	x0, x0, #0xffffffffffff
  9640: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9644: 	orr	x0, x0, x10
  9648: 	str	x0, [x19, #120]
  9652: 	mov	x0, x7
  9656: 	and	x0, x0, #0xffffffffffff
  9660: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9664: 	orr	x0, x0, x10
  9668: 	str	x0, [x19, #128]
  9672: 	mov	x0, x23
  9676: 	and	x0, x0, #0xffffffffffff
  9680: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9684: 	orr	x0, x0, x10
  9688: 	str	x0, [x19, #136]
  9692: 	mov	x0, x22
  9696: 	and	x0, x0, #0xffffffffffff
  9700: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
  9704: 	orr	x0, x0, x10
  9708: 	str	x0, [x19, #144]
  9712: 	fmov	d0, d16
  9716: 	fmov	x0, d0
  9720: 	lsr	x3, x0, #48
  9724: 	mov	x10, #65521                     // =0xfff1
  9728: 	cmp	x3, x10
  9732: 	b.lo	#8
  9736: 	orr	x0, xzr, #0x7ff8000000000000
  9740: 	str	x0, [x19, #152]
  9744: 	ldr	d0, [x19, #960]
  9748: 	fmov	x0, d0
  9752: 	lsr	x3, x0, #48
  9756: 	mov	x10, #65521                     // =0xfff1
  9760: 	cmp	x3, x10
  9764: 	b.lo	#8
  9768: 	orr	x0, xzr, #0x7ff8000000000000
  9772: 	str	x0, [x19, #160]
  9776: 	ldr	d0, [x19, #976]
  9780: 	fmov	x0, d0
  9784: 	lsr	x3, x0, #48
  9788: 	mov	x10, #65521                     // =0xfff1
  9792: 	cmp	x3, x10
  9796: 	b.lo	#8
  9800: 	orr	x0, xzr, #0x7ff8000000000000
  9804: 	str	x0, [x19, #168]
  9808: 	ldr	d0, [x19, #992]
  9812: 	fmov	x0, d0
  9816: 	lsr	x3, x0, #48
  9820: 	mov	x10, #65521                     // =0xfff1
  9824: 	cmp	x3, x10
  9828: 	b.lo	#8
  9832: 	orr	x0, xzr, #0x7ff8000000000000
  9836: 	str	x0, [x19, #176]
  9840: 	ldr	d0, [x19, #1016]
  9844: 	fmov	x0, d0
  9848: 	lsr	x3, x0, #48
  9852: 	mov	x10, #65521                     // =0xfff1
  9856: 	cmp	x3, x10
  9860: 	b.lo	#8
  9864: 	orr	x0, xzr, #0x7ff8000000000000
  9868: 	str	x0, [x19, #184]
  9872: 	ldr	d0, [x19, #1040]
  9876: 	fmov	x0, d0
  9880: 	lsr	x3, x0, #48
  9884: 	mov	x10, #65521                     // =0xfff1
  9888: 	cmp	x3, x10
  9892: 	b.lo	#8
  9896: 	orr	x0, xzr, #0x7ff8000000000000
  9900: 	str	x0, [x19, #192]
  9904: 	fmov	d0, d6
  9908: 	fmov	x0, d0
  9912: 	lsr	x3, x0, #48
  9916: 	mov	x10, #65521                     // =0xfff1
  9920: 	cmp	x3, x10
  9924: 	b.lo	#8
  9928: 	orr	x0, xzr, #0x7ff8000000000000
  9932: 	str	x0, [x19, #200]
  9936: 	ldr	d0, [x19, #936]
  9940: 	fmov	x0, d0
  9944: 	lsr	x3, x0, #48
  9948: 	mov	x10, #65521                     // =0xfff1
  9952: 	cmp	x3, x10
  9956: 	b.lo	#8
  9960: 	orr	x0, xzr, #0x7ff8000000000000
  9964: 	str	x0, [x19, #208]
  9968: 	ldr	d0, [x19, #1048]
  9972: 	fmov	x0, d0
  9976: 	lsr	x3, x0, #48
  9980: 	mov	x10, #65521                     // =0xfff1
  9984: 	cmp	x3, x10
  9988: 	b.lo	#8
  9992: 	orr	x0, xzr, #0x7ff8000000000000
  9996: 	str	x0, [x19, #216]
 10000: 	ldr	d0, [x19, #1064]
 10004: 	fmov	x0, d0
 10008: 	lsr	x3, x0, #48
 10012: 	mov	x10, #65521                     // =0xfff1
 10016: 	cmp	x3, x10
 10020: 	b.lo	#8
 10024: 	orr	x0, xzr, #0x7ff8000000000000
 10028: 	str	x0, [x19, #224]
 10032: 	ldr	d0, [x19, #1104]
 10036: 	fmov	x0, d0
 10040: 	lsr	x3, x0, #48
 10044: 	mov	x10, #65521                     // =0xfff1
 10048: 	cmp	x3, x10
 10052: 	b.lo	#8
 10056: 	orr	x0, xzr, #0x7ff8000000000000
 10060: 	str	x0, [x19, #232]
 10064: 	ldr	d0, [x19, #1080]
 10068: 	fmov	x0, d0
 10072: 	lsr	x3, x0, #48
 10076: 	mov	x10, #65521                     // =0xfff1
 10080: 	cmp	x3, x10
 10084: 	b.lo	#8
 10088: 	orr	x0, xzr, #0x7ff8000000000000
 10092: 	str	x0, [x19, #240]
 10096: 	fmov	d0, d7
 10100: 	fmov	x0, d0
 10104: 	lsr	x3, x0, #48
 10108: 	mov	x10, #65521                     // =0xfff1
 10112: 	cmp	x3, x10
 10116: 	b.lo	#8
 10120: 	orr	x0, xzr, #0x7ff8000000000000
 10124: 	str	x0, [x19, #248]
 10128: 	ldr	d0, [x19, #1208]
 10132: 	fmov	x0, d0
 10136: 	lsr	x3, x0, #48
 10140: 	mov	x10, #65521                     // =0xfff1
 10144: 	cmp	x3, x10
 10148: 	b.lo	#8
 10152: 	orr	x0, xzr, #0x7ff8000000000000
 10156: 	str	x0, [x19, #256]
 10160: 	ldr	d0, [x19, #1128]
 10164: 	fmov	x0, d0
 10168: 	lsr	x3, x0, #48
 10172: 	mov	x10, #65521                     // =0xfff1
 10176: 	cmp	x3, x10
 10180: 	b.lo	#8
 10184: 	orr	x0, xzr, #0x7ff8000000000000
 10188: 	str	x0, [x19, #264]
 10192: 	ldr	d0, [x19, #1144]
 10196: 	fmov	x0, d0
 10200: 	lsr	x3, x0, #48
 10204: 	mov	x10, #65521                     // =0xfff1
 10208: 	cmp	x3, x10
 10212: 	b.lo	#8
 10216: 	orr	x0, xzr, #0x7ff8000000000000
 10220: 	str	x0, [x19, #272]
 10224: 	ldr	d0, [x19, #1192]
 10228: 	fmov	x0, d0
 10232: 	lsr	x3, x0, #48
 10236: 	mov	x10, #65521                     // =0xfff1
 10240: 	cmp	x3, x10
 10244: 	b.lo	#8
 10248: 	orr	x0, xzr, #0x7ff8000000000000
 10252: 	str	x0, [x19, #280]
 10256: 	ldr	d0, [x19, #1160]
 10260: 	fmov	x0, d0
 10264: 	lsr	x3, x0, #48
 10268: 	mov	x10, #65521                     // =0xfff1
 10272: 	cmp	x3, x10
 10276: 	b.lo	#8
 10280: 	orr	x0, xzr, #0x7ff8000000000000
 10284: 	str	x0, [x19, #288]
 10288: 	ldr	d0, [x19, #1176]
 10292: 	fmov	x0, d0
 10296: 	lsr	x3, x0, #48
 10300: 	mov	x10, #65521                     // =0xfff1
 10304: 	cmp	x3, x10
 10308: 	b.lo	#8
 10312: 	orr	x0, xzr, #0x7ff8000000000000
 10316: 	str	x0, [x19, #296]
 10320: 	ldr	d0, [x19, #1200]
 10324: 	fmov	x0, d0
 10328: 	lsr	x3, x0, #48
 10332: 	mov	x10, #65521                     // =0xfff1
 10336: 	cmp	x3, x10
 10340: 	b.lo	#8
 10344: 	orr	x0, xzr, #0x7ff8000000000000
 10348: 	str	x0, [x19, #304]
 10352: 	mov	x9, #549755813824               // =0x7fffffffc0
 10356: 	str	x9, [x19, #912]
 10360: 	str	x20, [x19, #920]
 10364: 	mov	x0, #67                         // =0x43
 10368: 	ldp	x29, x30, [sp]
 10372: 	ldp	x19, x20, [sp, #80]
 10376: 	ldp	x21, x22, [sp, #64]
 10380: 	ldp	x23, x24, [sp, #48]
 10384: 	ldp	x25, x26, [sp, #32]
 10388: 	ldr	x27, [sp, #24]
 10392: 	add	sp, sp, #96
 10396: 	ret
 10400: 	fmov	d0, d3
 10404: 	fmov	x0, d0
 10408: 	lsr	x3, x0, #48
 10412: 	mov	x10, #65521                     // =0xfff1
 10416: 	cmp	x3, x10
 10420: 	b.lo	#8
 10424: 	orr	x0, xzr, #0x7ff8000000000000
 10428: 	str	x0, [x19, #48]
 10432: 	fmov	d0, d4
 10436: 	fmov	x0, d0
 10440: 	lsr	x3, x0, #48
 10444: 	mov	x10, #65521                     // =0xfff1
 10448: 	cmp	x3, x10
 10452: 	b.lo	#8
 10456: 	orr	x0, xzr, #0x7ff8000000000000
 10460: 	str	x0, [x19, #56]
 10464: 	mov	x0, x5
 10468: 	and	x0, x0, #0xffffffffffff
 10472: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10476: 	orr	x0, x0, x10
 10480: 	str	x0, [x19, #64]
 10484: 	mov	x0, x6
 10488: 	and	x0, x0, #0xffffffffffff
 10492: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10496: 	orr	x0, x0, x10
 10500: 	str	x0, [x19, #72]
 10504: 	fmov	d0, d5
 10508: 	fmov	x0, d0
 10512: 	lsr	x3, x0, #48
 10516: 	mov	x10, #65521                     // =0xfff1
 10520: 	cmp	x3, x10
 10524: 	b.lo	#8
 10528: 	orr	x0, xzr, #0x7ff8000000000000
 10532: 	str	x0, [x19, #80]
 10536: 	fmov	d0, d6
 10540: 	fmov	x0, d0
 10544: 	lsr	x3, x0, #48
 10548: 	mov	x10, #65521                     // =0xfff1
 10552: 	cmp	x3, x10
 10556: 	b.lo	#8
 10560: 	orr	x0, xzr, #0x7ff8000000000000
 10564: 	str	x0, [x19, #88]
 10568: 	mov	x0, x4
 10572: 	and	x0, x0, #0xffffffffffff
 10576: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10580: 	orr	x0, x0, x10
 10584: 	str	x0, [x19, #96]
 10588: 	fmov	d0, d17
 10592: 	fmov	x0, d0
 10596: 	lsr	x3, x0, #48
 10600: 	mov	x10, #65521                     // =0xfff1
 10604: 	cmp	x3, x10
 10608: 	b.lo	#8
 10612: 	orr	x0, xzr, #0x7ff8000000000000
 10616: 	str	x0, [x19, #104]
 10620: 	ldr	d0, [x19, #944]
 10624: 	fmov	x0, d0
 10628: 	lsr	x3, x0, #48
 10632: 	mov	x10, #65521                     // =0xfff1
 10636: 	cmp	x3, x10
 10640: 	b.lo	#8
 10644: 	orr	x0, xzr, #0x7ff8000000000000
 10648: 	str	x0, [x19, #112]
 10652: 	mov	x0, x21
 10656: 	and	x0, x0, #0xffffffffffff
 10660: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10664: 	orr	x0, x0, x10
 10668: 	str	x0, [x19, #120]
 10672: 	mov	x0, x7
 10676: 	and	x0, x0, #0xffffffffffff
 10680: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10684: 	orr	x0, x0, x10
 10688: 	str	x0, [x19, #128]
 10692: 	mov	x0, x23
 10696: 	and	x0, x0, #0xffffffffffff
 10700: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10704: 	orr	x0, x0, x10
 10708: 	str	x0, [x19, #136]
 10712: 	mov	x0, x22
 10716: 	and	x0, x0, #0xffffffffffff
 10720: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 10724: 	orr	x0, x0, x10
 10728: 	str	x0, [x19, #144]
 10732: 	fmov	d0, d16
 10736: 	fmov	x0, d0
 10740: 	lsr	x3, x0, #48
 10744: 	mov	x10, #65521                     // =0xfff1
 10748: 	cmp	x3, x10
 10752: 	b.lo	#8
 10756: 	orr	x0, xzr, #0x7ff8000000000000
 10760: 	str	x0, [x19, #152]
 10764: 	ldr	d0, [x19, #960]
 10768: 	fmov	x0, d0
 10772: 	lsr	x3, x0, #48
 10776: 	mov	x10, #65521                     // =0xfff1
 10780: 	cmp	x3, x10
 10784: 	b.lo	#8
 10788: 	orr	x0, xzr, #0x7ff8000000000000
 10792: 	str	x0, [x19, #160]
 10796: 	ldr	d0, [x19, #976]
 10800: 	fmov	x0, d0
 10804: 	lsr	x3, x0, #48
 10808: 	mov	x10, #65521                     // =0xfff1
 10812: 	cmp	x3, x10
 10816: 	b.lo	#8
 10820: 	orr	x0, xzr, #0x7ff8000000000000
 10824: 	str	x0, [x19, #168]
 10828: 	ldr	d0, [x19, #992]
 10832: 	fmov	x0, d0
 10836: 	lsr	x3, x0, #48
 10840: 	mov	x10, #65521                     // =0xfff1
 10844: 	cmp	x3, x10
 10848: 	b.lo	#8
 10852: 	orr	x0, xzr, #0x7ff8000000000000
 10856: 	str	x0, [x19, #176]
 10860: 	ldr	d0, [x19, #1016]
 10864: 	fmov	x0, d0
 10868: 	lsr	x3, x0, #48
 10872: 	mov	x10, #65521                     // =0xfff1
 10876: 	cmp	x3, x10
 10880: 	b.lo	#8
 10884: 	orr	x0, xzr, #0x7ff8000000000000
 10888: 	str	x0, [x19, #184]
 10892: 	ldr	d0, [x19, #1040]
 10896: 	fmov	x0, d0
 10900: 	lsr	x3, x0, #48
 10904: 	mov	x10, #65521                     // =0xfff1
 10908: 	cmp	x3, x10
 10912: 	b.lo	#8
 10916: 	orr	x0, xzr, #0x7ff8000000000000
 10920: 	str	x0, [x19, #192]
 10924: 	fmov	d0, d6
 10928: 	fmov	x0, d0
 10932: 	lsr	x3, x0, #48
 10936: 	mov	x10, #65521                     // =0xfff1
 10940: 	cmp	x3, x10
 10944: 	b.lo	#8
 10948: 	orr	x0, xzr, #0x7ff8000000000000
 10952: 	str	x0, [x19, #200]
 10956: 	ldr	d0, [x19, #936]
 10960: 	fmov	x0, d0
 10964: 	lsr	x3, x0, #48
 10968: 	mov	x10, #65521                     // =0xfff1
 10972: 	cmp	x3, x10
 10976: 	b.lo	#8
 10980: 	orr	x0, xzr, #0x7ff8000000000000
 10984: 	str	x0, [x19, #208]
 10988: 	ldr	d0, [x19, #1048]
 10992: 	fmov	x0, d0
 10996: 	lsr	x3, x0, #48
 11000: 	mov	x10, #65521                     // =0xfff1
 11004: 	cmp	x3, x10
 11008: 	b.lo	#8
 11012: 	orr	x0, xzr, #0x7ff8000000000000
 11016: 	str	x0, [x19, #216]
 11020: 	ldr	d0, [x19, #1064]
 11024: 	fmov	x0, d0
 11028: 	lsr	x3, x0, #48
 11032: 	mov	x10, #65521                     // =0xfff1
 11036: 	cmp	x3, x10
 11040: 	b.lo	#8
 11044: 	orr	x0, xzr, #0x7ff8000000000000
 11048: 	str	x0, [x19, #224]
 11052: 	ldr	d0, [x19, #1104]
 11056: 	fmov	x0, d0
 11060: 	lsr	x3, x0, #48
 11064: 	mov	x10, #65521                     // =0xfff1
 11068: 	cmp	x3, x10
 11072: 	b.lo	#8
 11076: 	orr	x0, xzr, #0x7ff8000000000000
 11080: 	str	x0, [x19, #232]
 11084: 	ldr	d0, [x19, #1080]
 11088: 	fmov	x0, d0
 11092: 	lsr	x3, x0, #48
 11096: 	mov	x10, #65521                     // =0xfff1
 11100: 	cmp	x3, x10
 11104: 	b.lo	#8
 11108: 	orr	x0, xzr, #0x7ff8000000000000
 11112: 	str	x0, [x19, #240]
 11116: 	fmov	d0, d7
 11120: 	fmov	x0, d0
 11124: 	lsr	x3, x0, #48
 11128: 	mov	x10, #65521                     // =0xfff1
 11132: 	cmp	x3, x10
 11136: 	b.lo	#8
 11140: 	orr	x0, xzr, #0x7ff8000000000000
 11144: 	str	x0, [x19, #248]
 11148: 	ldr	d0, [x19, #1208]
 11152: 	fmov	x0, d0
 11156: 	lsr	x3, x0, #48
 11160: 	mov	x10, #65521                     // =0xfff1
 11164: 	cmp	x3, x10
 11168: 	b.lo	#8
 11172: 	orr	x0, xzr, #0x7ff8000000000000
 11176: 	str	x0, [x19, #256]
 11180: 	ldr	d0, [x19, #1128]
 11184: 	fmov	x0, d0
 11188: 	lsr	x3, x0, #48
 11192: 	mov	x10, #65521                     // =0xfff1
 11196: 	cmp	x3, x10
 11200: 	b.lo	#8
 11204: 	orr	x0, xzr, #0x7ff8000000000000
 11208: 	str	x0, [x19, #264]
 11212: 	ldr	d0, [x19, #1144]
 11216: 	fmov	x0, d0
 11220: 	lsr	x3, x0, #48
 11224: 	mov	x10, #65521                     // =0xfff1
 11228: 	cmp	x3, x10
 11232: 	b.lo	#8
 11236: 	orr	x0, xzr, #0x7ff8000000000000
 11240: 	str	x0, [x19, #272]
 11244: 	ldr	d0, [x19, #1192]
 11248: 	fmov	x0, d0
 11252: 	lsr	x3, x0, #48
 11256: 	mov	x10, #65521                     // =0xfff1
 11260: 	cmp	x3, x10
 11264: 	b.lo	#8
 11268: 	orr	x0, xzr, #0x7ff8000000000000
 11272: 	str	x0, [x19, #280]
 11276: 	ldr	d0, [x19, #1160]
 11280: 	fmov	x0, d0
 11284: 	lsr	x3, x0, #48
 11288: 	mov	x10, #65521                     // =0xfff1
 11292: 	cmp	x3, x10
 11296: 	b.lo	#8
 11300: 	orr	x0, xzr, #0x7ff8000000000000
 11304: 	str	x0, [x19, #288]
 11308: 	ldr	d0, [x19, #1176]
 11312: 	fmov	x0, d0
 11316: 	lsr	x3, x0, #48
 11320: 	mov	x10, #65521                     // =0xfff1
 11324: 	cmp	x3, x10
 11328: 	b.lo	#8
 11332: 	orr	x0, xzr, #0x7ff8000000000000
 11336: 	str	x0, [x19, #296]
 11340: 	ldr	d0, [x19, #1200]
 11344: 	fmov	x0, d0
 11348: 	lsr	x3, x0, #48
 11352: 	mov	x10, #65521                     // =0xfff1
 11356: 	cmp	x3, x10
 11360: 	b.lo	#8
 11364: 	orr	x0, xzr, #0x7ff8000000000000
 11368: 	str	x0, [x19, #304]
 11372: 	mov	x9, #549755813824               // =0x7fffffffc0
 11376: 	str	x9, [x19, #912]
 11380: 	str	x20, [x19, #920]
 11384: 	mov	x0, #68                         // =0x44
 11388: 	ldp	x29, x30, [sp]
 11392: 	ldp	x19, x20, [sp, #80]
 11396: 	ldp	x21, x22, [sp, #64]
 11400: 	ldp	x23, x24, [sp, #48]
 11404: 	ldp	x25, x26, [sp, #32]
 11408: 	ldr	x27, [sp, #24]
 11412: 	add	sp, sp, #96
 11416: 	ret
 11420: 	fmov	d0, d3
 11424: 	fmov	x0, d0
 11428: 	lsr	x3, x0, #48
 11432: 	mov	x10, #65521                     // =0xfff1
 11436: 	cmp	x3, x10
 11440: 	b.lo	#8
 11444: 	orr	x0, xzr, #0x7ff8000000000000
 11448: 	str	x0, [x19, #48]
 11452: 	fmov	d0, d4
 11456: 	fmov	x0, d0
 11460: 	lsr	x3, x0, #48
 11464: 	mov	x10, #65521                     // =0xfff1
 11468: 	cmp	x3, x10
 11472: 	b.lo	#8
 11476: 	orr	x0, xzr, #0x7ff8000000000000
 11480: 	str	x0, [x19, #56]
 11484: 	mov	x0, x5
 11488: 	and	x0, x0, #0xffffffffffff
 11492: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11496: 	orr	x0, x0, x10
 11500: 	str	x0, [x19, #64]
 11504: 	mov	x0, x6
 11508: 	and	x0, x0, #0xffffffffffff
 11512: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11516: 	orr	x0, x0, x10
 11520: 	str	x0, [x19, #72]
 11524: 	fmov	d0, d5
 11528: 	fmov	x0, d0
 11532: 	lsr	x3, x0, #48
 11536: 	mov	x10, #65521                     // =0xfff1
 11540: 	cmp	x3, x10
 11544: 	b.lo	#8
 11548: 	orr	x0, xzr, #0x7ff8000000000000
 11552: 	str	x0, [x19, #80]
 11556: 	fmov	d0, d6
 11560: 	fmov	x0, d0
 11564: 	lsr	x3, x0, #48
 11568: 	mov	x10, #65521                     // =0xfff1
 11572: 	cmp	x3, x10
 11576: 	b.lo	#8
 11580: 	orr	x0, xzr, #0x7ff8000000000000
 11584: 	str	x0, [x19, #88]
 11588: 	ldr	x0, [x19, #1232]
 11592: 	and	x0, x0, #0xffffffffffff
 11596: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11600: 	orr	x0, x0, x10
 11604: 	str	x0, [x19, #96]
 11608: 	fmov	d0, d17
 11612: 	fmov	x0, d0
 11616: 	lsr	x3, x0, #48
 11620: 	mov	x10, #65521                     // =0xfff1
 11624: 	cmp	x3, x10
 11628: 	b.lo	#8
 11632: 	orr	x0, xzr, #0x7ff8000000000000
 11636: 	str	x0, [x19, #104]
 11640: 	ldr	d0, [x19, #944]
 11644: 	fmov	x0, d0
 11648: 	lsr	x3, x0, #48
 11652: 	mov	x10, #65521                     // =0xfff1
 11656: 	cmp	x3, x10
 11660: 	b.lo	#8
 11664: 	orr	x0, xzr, #0x7ff8000000000000
 11668: 	str	x0, [x19, #112]
 11672: 	mov	x0, x21
 11676: 	and	x0, x0, #0xffffffffffff
 11680: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11684: 	orr	x0, x0, x10
 11688: 	str	x0, [x19, #120]
 11692: 	mov	x0, x7
 11696: 	and	x0, x0, #0xffffffffffff
 11700: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11704: 	orr	x0, x0, x10
 11708: 	str	x0, [x19, #128]
 11712: 	mov	x0, x23
 11716: 	and	x0, x0, #0xffffffffffff
 11720: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11724: 	orr	x0, x0, x10
 11728: 	str	x0, [x19, #136]
 11732: 	mov	x0, x22
 11736: 	and	x0, x0, #0xffffffffffff
 11740: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 11744: 	orr	x0, x0, x10
 11748: 	str	x0, [x19, #144]
 11752: 	fmov	d0, d16
 11756: 	fmov	x0, d0
 11760: 	lsr	x3, x0, #48
 11764: 	mov	x10, #65521                     // =0xfff1
 11768: 	cmp	x3, x10
 11772: 	b.lo	#8
 11776: 	orr	x0, xzr, #0x7ff8000000000000
 11780: 	str	x0, [x19, #152]
 11784: 	ldr	d0, [x19, #960]
 11788: 	fmov	x0, d0
 11792: 	lsr	x3, x0, #48
 11796: 	mov	x10, #65521                     // =0xfff1
 11800: 	cmp	x3, x10
 11804: 	b.lo	#8
 11808: 	orr	x0, xzr, #0x7ff8000000000000
 11812: 	str	x0, [x19, #160]
 11816: 	ldr	d0, [x19, #976]
 11820: 	fmov	x0, d0
 11824: 	lsr	x3, x0, #48
 11828: 	mov	x10, #65521                     // =0xfff1
 11832: 	cmp	x3, x10
 11836: 	b.lo	#8
 11840: 	orr	x0, xzr, #0x7ff8000000000000
 11844: 	str	x0, [x19, #168]
 11848: 	ldr	d0, [x19, #992]
 11852: 	fmov	x0, d0
 11856: 	lsr	x3, x0, #48
 11860: 	mov	x10, #65521                     // =0xfff1
 11864: 	cmp	x3, x10
 11868: 	b.lo	#8
 11872: 	orr	x0, xzr, #0x7ff8000000000000
 11876: 	str	x0, [x19, #176]
 11880: 	ldr	d0, [x19, #1016]
 11884: 	fmov	x0, d0
 11888: 	lsr	x3, x0, #48
 11892: 	mov	x10, #65521                     // =0xfff1
 11896: 	cmp	x3, x10
 11900: 	b.lo	#8
 11904: 	orr	x0, xzr, #0x7ff8000000000000
 11908: 	str	x0, [x19, #184]
 11912: 	ldr	d0, [x19, #1040]
 11916: 	fmov	x0, d0
 11920: 	lsr	x3, x0, #48
 11924: 	mov	x10, #65521                     // =0xfff1
 11928: 	cmp	x3, x10
 11932: 	b.lo	#8
 11936: 	orr	x0, xzr, #0x7ff8000000000000
 11940: 	str	x0, [x19, #192]
 11944: 	ldr	x0, [x19, #1240]
 11948: 	str	x0, [x19, #200]
 11952: 	ldr	d0, [x19, #936]
 11956: 	fmov	x0, d0
 11960: 	lsr	x3, x0, #48
 11964: 	mov	x10, #65521                     // =0xfff1
 11968: 	cmp	x3, x10
 11972: 	b.lo	#8
 11976: 	orr	x0, xzr, #0x7ff8000000000000
 11980: 	str	x0, [x19, #208]
 11984: 	ldr	d0, [x19, #1048]
 11988: 	fmov	x0, d0
 11992: 	lsr	x3, x0, #48
 11996: 	mov	x10, #65521                     // =0xfff1
 12000: 	cmp	x3, x10
 12004: 	b.lo	#8
 12008: 	orr	x0, xzr, #0x7ff8000000000000
 12012: 	str	x0, [x19, #216]
 12016: 	ldr	d0, [x19, #1064]
 12020: 	fmov	x0, d0
 12024: 	lsr	x3, x0, #48
 12028: 	mov	x10, #65521                     // =0xfff1
 12032: 	cmp	x3, x10
 12036: 	b.lo	#8
 12040: 	orr	x0, xzr, #0x7ff8000000000000
 12044: 	str	x0, [x19, #224]
 12048: 	ldr	d0, [x19, #1104]
 12052: 	fmov	x0, d0
 12056: 	lsr	x3, x0, #48
 12060: 	mov	x10, #65521                     // =0xfff1
 12064: 	cmp	x3, x10
 12068: 	b.lo	#8
 12072: 	orr	x0, xzr, #0x7ff8000000000000
 12076: 	str	x0, [x19, #232]
 12080: 	ldr	d0, [x19, #1080]
 12084: 	fmov	x0, d0
 12088: 	lsr	x3, x0, #48
 12092: 	mov	x10, #65521                     // =0xfff1
 12096: 	cmp	x3, x10
 12100: 	b.lo	#8
 12104: 	orr	x0, xzr, #0x7ff8000000000000
 12108: 	str	x0, [x19, #240]
 12112: 	fmov	d0, d7
 12116: 	fmov	x0, d0
 12120: 	lsr	x3, x0, #48
 12124: 	mov	x10, #65521                     // =0xfff1
 12128: 	cmp	x3, x10
 12132: 	b.lo	#8
 12136: 	orr	x0, xzr, #0x7ff8000000000000
 12140: 	str	x0, [x19, #248]
 12144: 	ldr	d0, [x19, #1208]
 12148: 	fmov	x0, d0
 12152: 	lsr	x3, x0, #48
 12156: 	mov	x10, #65521                     // =0xfff1
 12160: 	cmp	x3, x10
 12164: 	b.lo	#8
 12168: 	orr	x0, xzr, #0x7ff8000000000000
 12172: 	str	x0, [x19, #256]
 12176: 	ldr	d0, [x19, #1128]
 12180: 	fmov	x0, d0
 12184: 	lsr	x3, x0, #48
 12188: 	mov	x10, #65521                     // =0xfff1
 12192: 	cmp	x3, x10
 12196: 	b.lo	#8
 12200: 	orr	x0, xzr, #0x7ff8000000000000
 12204: 	str	x0, [x19, #264]
 12208: 	ldr	d0, [x19, #1144]
 12212: 	fmov	x0, d0
 12216: 	lsr	x3, x0, #48
 12220: 	mov	x10, #65521                     // =0xfff1
 12224: 	cmp	x3, x10
 12228: 	b.lo	#8
 12232: 	orr	x0, xzr, #0x7ff8000000000000
 12236: 	str	x0, [x19, #272]
 12240: 	ldr	d0, [x19, #1192]
 12244: 	fmov	x0, d0
 12248: 	lsr	x3, x0, #48
 12252: 	mov	x10, #65521                     // =0xfff1
 12256: 	cmp	x3, x10
 12260: 	b.lo	#8
 12264: 	orr	x0, xzr, #0x7ff8000000000000
 12268: 	str	x0, [x19, #280]
 12272: 	ldr	d0, [x19, #1160]
 12276: 	fmov	x0, d0
 12280: 	lsr	x3, x0, #48
 12284: 	mov	x10, #65521                     // =0xfff1
 12288: 	cmp	x3, x10
 12292: 	b.lo	#8
 12296: 	orr	x0, xzr, #0x7ff8000000000000
 12300: 	str	x0, [x19, #288]
 12304: 	ldr	d0, [x19, #1176]
 12308: 	fmov	x0, d0
 12312: 	lsr	x3, x0, #48
 12316: 	mov	x10, #65521                     // =0xfff1
 12320: 	cmp	x3, x10
 12324: 	b.lo	#8
 12328: 	orr	x0, xzr, #0x7ff8000000000000
 12332: 	str	x0, [x19, #296]
 12336: 	ldr	d0, [x19, #1200]
 12340: 	fmov	x0, d0
 12344: 	lsr	x3, x0, #48
 12348: 	mov	x10, #65521                     // =0xfff1
 12352: 	cmp	x3, x10
 12356: 	b.lo	#8
 12360: 	orr	x0, xzr, #0x7ff8000000000000
 12364: 	str	x0, [x19, #304]
 12368: 	mov	x9, #549755813824               // =0x7fffffffc0
 12372: 	str	x9, [x19, #912]
 12376: 	str	x20, [x19, #920]
 12380: 	mov	x0, #70                         // =0x46
 12384: 	ldp	x29, x30, [sp]
 12388: 	ldp	x19, x20, [sp, #80]
 12392: 	ldp	x21, x22, [sp, #64]
 12396: 	ldp	x23, x24, [sp, #48]
 12400: 	ldp	x25, x26, [sp, #32]
 12404: 	ldr	x27, [sp, #24]
 12408: 	add	sp, sp, #96
 12412: 	ret
 12416: 	fmov	d0, d6
 12420: 	fmov	x0, d0
 12424: 	lsr	x3, x0, #48
 12428: 	mov	x10, #65521                     // =0xfff1
 12432: 	cmp	x3, x10
 12436: 	b.lo	#8
 12440: 	orr	x0, xzr, #0x7ff8000000000000
 12444: 	str	x0, [x19, #88]
 12448: 	ldr	x0, [x19, #1232]
 12452: 	and	x0, x0, #0xffffffffffff
 12456: 	mov	x10, #-4222124650659840         // =0xfff1000000000000
 12460: 	orr	x0, x0, x10
 12464: 	str	x0, [x19, #96]
 12468: 	ldr	x0, [x19, #1240]
 12472: 	str	x0, [x19, #200]
 12476: 	mov	x9, #6144                       // =0x1800
 12480: 	movk	x9, #512, lsl #16
 12484: 	str	x9, [x19, #912]
 12488: 	str	x20, [x19, #920]
 12492: 	mov	x0, #70                         // =0x46
 12496: 	ldp	x29, x30, [sp]
 12500: 	ldp	x19, x20, [sp, #80]
 12504: 	ldp	x21, x22, [sp, #64]
 12508: 	ldp	x23, x24, [sp, #48]
 12512: 	ldp	x25, x26, [sp, #32]
 12516: 	ldr	x27, [sp, #24]
 12520: 	add	sp, sp, #96
 12524: 	ret
