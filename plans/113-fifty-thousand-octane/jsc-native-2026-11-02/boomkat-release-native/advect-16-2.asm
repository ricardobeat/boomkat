	stp	x29, x30, [sp, #-96]!
	stp	x19, x20, [sp, #80]
	stp	x21, x22, [sp, #64]
	stp	x23, x24, [sp, #48]
	stp	x25, x26, [sp, #32]
	str	x27, [sp, #24]
	mov	x29, sp
	mov	x19, x0
	mov	x20, x1
	ldr	x0, [x19, #24]
	ldr	x10, [x19, #528]
	cmp	x0, x10
	b.ne	#2620
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x0, [x19, #32]
	ldr	x10, [x19, #560]
	cmp	x0, x10
	b.ne	#2596
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #16]
	ldr	x10, [x19, #592]
	cmp	x0, x10
	b.ne	#2572
	ldr	x0, [x19, #8]
	ldr	x10, [x19, #624]
	cmp	x0, x10
	b.ne	#2556
	ldr	x0, [x19, #48]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2536
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	fmov	d2, d0
	ldr	x0, [x19, #56]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2480
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	fmov	d3, d0
	ldr	x0, [x19, #64]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2412
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#2400
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2384
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2368
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#2352
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#2328
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#2304
	mov	x0, x1
	mov	x6, x0
	ldr	x0, [x19, #72]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2264
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#2252
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2236
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2220
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#2204
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#2180
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#2156
	mov	x0, x1
	mov	x7, x0
	ldr	x0, [x19, #80]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2128
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	fmov	d4, d0
	ldr	x0, [x19, #88]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2060
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#2048
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2032
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2016
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#2000
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#1976
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#1952
	mov	x0, x1
	mov	x4, x0
	ldr	x0, [x19, #96]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#1912
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#1900
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#1884
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#1868
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#1852
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#1828
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#1804
	mov	x0, x1
	mov	x5, x0
	adds	w21, w4, #1
	b.vs	#1836
	sxtw	x21, w21
	mov	x1, x21
	cmp	x1, x24
	b.hs	#2044
	lsl	x1, x1, #3
	add	x2, x25, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2016
	fmov	d5, x0
	fmul	d6, d2, d5
	mov	x0, x5
	scvtf	d7, x0
	fsub	d16, d7, d6
	mov	x1, x21
	cmp	x1, x26
	b.hs	#2208
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2180
	fmov	d7, x0
	fmul	d17, d3, d7
	fsub	d5, d4, d17
	fmov	d0, d16
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fcmp	d0, d1
	b.pl	#8
	b	#8
	b	#20
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	d7, d0
	b	#44
	mov	x0, x6
	scvtf	d6, x0
	fmov	d0, d16
	fmov	d1, d6
	fcmp	d0, d1
	b.le	#8
	b	#12
	fmov	d7, d16
	b	#8
	scvtf	d7, x6
	fmov	d0, d7
	fcmp	d0, d0
	b.vs	#2396
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2380
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2364
	fcvtzs	x22, d0
	sxtw	x22, w22
	orr	x23, x22, xzr
	sxtw	x23, w23
	adds	w22, w23, #1
	b.vs	#2700
	sxtw	x22, w22
	fmov	d0, d5
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fcmp	d0, d1
	b.pl	#8
	b	#8
	b	#20
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	d16, d0
	b	#44
	mov	x0, x7
	scvtf	d6, x0
	fmov	d0, d5
	fmov	d1, d6
	fcmp	d0, d1
	b.le	#8
	b	#12
	fmov	d16, d5
	b	#8
	scvtf	d16, x7
	fmov	d0, d16
	fcmp	d0, d0
	b.vs	#2980
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2964
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2948
	fcvtzs	x0, d0
	sxtw	x0, w0
	str	x0, [x19, #928]
	ldr	x0, [x19, #928]
	orr	x0, x0, xzr
	sxtw	x0, w0
	str	x0, [x19, #936]
	ldr	x0, [x19, #936]
	adds	w0, w0, #1
	b.vs	#3308
	sxtw	x0, w0
	str	x0, [x19, #944]
	mov	x0, x23
	scvtf	d5, x0
	fsub	d6, d7, d5
	mov	x0, #1                          // =0x1
	scvtf	d0, x0
	str	d0, [x19, #952]
	ldr	d0, [x19, #952]
	fsub	d0, d0, d6
	str	d0, [x19, #960]
	ldr	x0, [x19, #936]
	scvtf	d0, x0
	str	d0, [x19, #968]
	ldr	d1, [x19, #968]
	fsub	d0, d16, d1
	str	d0, [x19, #976]
	mov	x0, #1                          // =0x1
	scvtf	d0, x0
	str	d0, [x19, #984]
	ldr	d0, [x19, #984]
	ldr	d1, [x19, #976]
	fsub	d0, d0, d1
	str	d0, [x19, #992]
	ldr	x0, [x19, #784]
	str	x0, [x19, #1000]
	ldr	x0, [x19, #1000]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3604
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #1008]
	ldr	d0, [x19, #968]
	ldr	d1, [x19, #1008]
	fmul	d0, d0, d1
	str	d0, [x19, #1016]
	ldr	x0, [x19, #944]
	scvtf	d0, x0
	str	d0, [x19, #1024]
	ldr	x0, [x19, #1000]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4060
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #1032]
	ldr	d0, [x19, #1024]
	ldr	d1, [x19, #1032]
	fmul	d0, d0, d1
	str	d0, [x19, #1040]
	ldr	d1, [x19, #1016]
	fadd	d0, d5, d1
	str	d0, [x19, #1048]
	ldr	d0, [x19, #1048]
	fcmp	d0, d0
	b.vs	#4556
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#4540
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#4524
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#4508
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	b.eq	#8
	b	#4488
	sxtw	x0, w0
	str	x0, [x19, #1056]
	ldr	x1, [x19, #1056]
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#4464
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#4432
	fmov	d0, x0
	str	d0, [x19, #1064]
	ldr	d0, [x19, #992]
	ldr	d1, [x19, #1064]
	fmul	d0, d0, d1
	str	d0, [x19, #1072]
	ldr	d1, [x19, #1040]
	fadd	d0, d5, d1
	str	d0, [x19, #1080]
	ldr	d0, [x19, #1080]
	fcmp	d0, d0
	b.vs	#5028
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#5012
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#4996
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#4980
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	b.eq	#8
	b	#4960
	sxtw	x0, w0
	str	x0, [x19, #1088]
	ldr	x1, [x19, #1088]
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#4936
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#4904
	fmov	d5, x0
	ldr	d0, [x19, #976]
	fmul	d0, d0, d5
	str	d0, [x19, #1096]
	ldr	d0, [x19, #1072]
	ldr	d1, [x19, #1096]
	fadd	d0, d0, d1
	str	d0, [x19, #1104]
	ldr	d0, [x19, #960]
	ldr	d1, [x19, #1104]
	fmul	d0, d0, d1
	str	d0, [x19, #1112]
	mov	x0, x22
	scvtf	d0, x0
	str	d0, [x19, #1120]
	ldr	d0, [x19, #1120]
	ldr	d1, [x19, #1016]
	fadd	d0, d0, d1
	str	d0, [x19, #1128]
	ldr	d0, [x19, #1128]
	fcmp	d0, d0
	b.vs	#5556
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#5540
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#5524
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#5508
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	b.eq	#8
	b	#5488
	sxtw	x0, w0
	str	x0, [x19, #1136]
	ldr	x1, [x19, #1136]
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#5464
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#5432
	fmov	d0, x0
	str	d0, [x19, #1144]
	ldr	d0, [x19, #992]
	ldr	d1, [x19, #1144]
	fmul	d0, d0, d1
	str	d0, [x19, #1152]
	ldr	d0, [x19, #1120]
	ldr	d1, [x19, #1040]
	fadd	d0, d0, d1
	str	d0, [x19, #1160]
	ldr	d0, [x19, #1160]
	fcmp	d0, d0
	b.vs	#6216
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#6200
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#6184
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#6168
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	b.eq	#8
	b	#6148
	sxtw	x0, w0
	str	x0, [x19, #1168]
	ldr	x1, [x19, #1168]
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#6124
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#6092
	fmov	d0, x0
	str	d0, [x19, #1176]
	ldr	d0, [x19, #976]
	ldr	d1, [x19, #1176]
	fmul	d0, d0, d1
	str	d0, [x19, #1184]
	ldr	d0, [x19, #1152]
	ldr	d1, [x19, #1184]
	fadd	d0, d0, d1
	str	d0, [x19, #1192]
	ldr	d1, [x19, #1192]
	fmul	d0, d6, d1
	str	d0, [x19, #1200]
	ldr	d0, [x19, #1112]
	ldr	d1, [x19, #1200]
	fadd	d0, d0, d1
	str	d0, [x19, #1208]
	ldr	d0, [x19, #1208]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #1216]
	mov	x1, x21
	ldr	x10, [x19, #640]
	cmp	x1, x10
	b.hs	#6908
	lsl	x1, x1, #3
	ldr	x2, [x19, #632]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6876
	ldr	x0, [x19, #1216]
	str	x0, [x2]
	adds	w0, w5, #1
	b.vs	#7856
	sxtw	x0, w0
	str	x0, [x19, #1224]
	ldr	x0, [x19, #792]
	str	x0, [x19, #1232]
	ldr	x0, [x19, #1224]
	scvtf	d0, x0
	str	d0, [x19, #1240]
	ldr	x0, [x19, #1232]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8804
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #1248]
	cmp	x20, #1
	b.ls	#9744
	sub	x20, x20, #1
	mov	x4, x21
	ldr	x0, [x19, #1224]
	mov	x5, x0
	ldr	d0, [x19, #1240]
	ldr	d1, [x19, #1248]
	fcmp	d0, d1
	b.ls	#-1700
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	mov	x9, #6144                       // =0x1800
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #71                         // =0x47
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x9, #0                          // =0x0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #16                         // =0x10
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	mov	x9, #8128                       // =0x1fc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #16                         // =0x10
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	mov	x9, #8128                       // =0x1fc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #17                         // =0x11
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #200]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #16320                      // =0x3fc0
	movk	x9, #1536, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #20                         // =0x14
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #32704                      // =0x7fc0
	movk	x9, #1536, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #29                         // =0x1d
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #65472                      // =0xffc0
	movk	x9, #1536, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #30                         // =0x1e
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #65472                      // =0xffc0
	movk	x9, #1537, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #37                         // =0x25
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #65472                      // =0xffc0
	movk	x9, #1539, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #38                         // =0x26
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	x0, [x19, #1000]
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #65472                      // =0xffc0
	movk	x9, #1663, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #46                         // =0x2e
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	x0, [x19, #1000]
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	mov	x9, #65472                      // =0xffc0
	movk	x9, #1791, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #48                         // =0x30
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	mov	w9, #268435392                  // =0xfffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #51                         // =0x33
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1072]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	mov	w9, #2147483584                 // =0x7fffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #54                         // =0x36
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1104]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #248]
	ldr	d0, [x19, #1112]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #256]
	ldr	d0, [x19, #1128]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #264]
	mov	x9, #17179869120                // =0x3ffffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #59                         // =0x3b
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1104]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #248]
	ldr	d0, [x19, #1112]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #256]
	ldr	d0, [x19, #1128]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #264]
	ldr	d0, [x19, #1144]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #272]
	ldr	d0, [x19, #1152]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #280]
	ldr	d0, [x19, #1160]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #288]
	mov	x9, #137438953408               // =0x1fffffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #62                         // =0x3e
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1104]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #248]
	ldr	d0, [x19, #1208]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #256]
	ldr	d0, [x19, #1128]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #264]
	ldr	d0, [x19, #1144]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #272]
	ldr	d0, [x19, #1192]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #280]
	ldr	d0, [x19, #1160]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #288]
	ldr	d0, [x19, #1176]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #296]
	ldr	d0, [x19, #1200]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #304]
	mov	x9, #549755813824               // =0x7fffffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #67                         // =0x43
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1104]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #248]
	ldr	d0, [x19, #1208]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #256]
	ldr	d0, [x19, #1128]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #264]
	ldr	d0, [x19, #1144]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #272]
	ldr	d0, [x19, #1192]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #280]
	ldr	d0, [x19, #1160]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #288]
	ldr	d0, [x19, #1176]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #296]
	ldr	d0, [x19, #1200]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #304]
	mov	x9, #549755813824               // =0x7fffffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #68                         // =0x44
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #48]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #56]
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #64]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #72]
	fmov	d0, d4
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #80]
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	ldr	x0, [x19, #1224]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	fmov	d0, d7
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #104]
	fmov	d0, d16
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #112]
	mov	x0, x23
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #120]
	mov	x0, x22
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	ldr	x0, [x19, #936]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #136]
	ldr	x0, [x19, #944]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #144]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #152]
	ldr	d0, [x19, #960]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #160]
	ldr	d0, [x19, #976]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #168]
	ldr	d0, [x19, #992]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #176]
	ldr	d0, [x19, #1016]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #184]
	ldr	d0, [x19, #1040]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #192]
	ldr	x0, [x19, #1232]
	str	x0, [x19, #200]
	fmov	d0, d17
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #208]
	ldr	d0, [x19, #1048]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #216]
	ldr	d0, [x19, #1064]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #224]
	ldr	d0, [x19, #1104]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #232]
	ldr	d0, [x19, #1080]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #240]
	fmov	d0, d5
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #248]
	ldr	d0, [x19, #1208]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #256]
	ldr	d0, [x19, #1128]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #264]
	ldr	d0, [x19, #1144]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #272]
	ldr	d0, [x19, #1192]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #280]
	ldr	d0, [x19, #1160]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #288]
	ldr	d0, [x19, #1176]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #296]
	ldr	d0, [x19, #1200]
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #304]
	mov	x9, #549755813824               // =0x7fffffffc0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #70                         // =0x46
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x0, x21
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #88]
	ldr	x0, [x19, #1224]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #96]
	ldr	x0, [x19, #1232]
	str	x0, [x19, #200]
	mov	x9, #6144                       // =0x1800
	movk	x9, #512, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #70                         // =0x46
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
