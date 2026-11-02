	stp	x29, x30, [sp, #-96]!
	stp	x19, x20, [sp, #80]
	stp	x21, x22, [sp, #64]
	stp	x23, x24, [sp, #48]
	stp	x25, x26, [sp, #32]
	str	x27, [sp, #24]
	mov	x29, sp
	mov	x19, x0
	mov	x20, x1
	ldr	x0, [x19, #16]
	ldr	x10, [x19, #528]
	cmp	x0, x10
	b.ne	#10292
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x0, [x19, #8]
	ldr	x10, [x19, #560]
	cmp	x0, x10
	b.ne	#10268
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0]
	mov	x23, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #8]
	str	x0, [x19, #2760]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #16]
	str	x0, [x19, #2768]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #24]
	str	x0, [x19, #2776]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #32]
	mov	x7, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #40]
	str	x0, [x19, #2784]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #48]
	str	x0, [x19, #2792]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #56]
	str	x0, [x19, #2800]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #64]
	str	x0, [x19, #2808]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #72]
	str	x0, [x19, #2816]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #80]
	str	x0, [x19, #2824]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #88]
	str	x0, [x19, #2832]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #96]
	str	x0, [x19, #2840]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #104]
	mov	x4, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #112]
	mov	x5, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #120]
	mov	x6, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #128]
	mov	x21, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #136]
	mov	x22, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #144]
	str	x0, [x19, #2848]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #152]
	str	x0, [x19, #2856]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #160]
	str	x0, [x19, #2864]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #168]
	str	x0, [x19, #2872]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #176]
	str	x0, [x19, #2880]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #184]
	str	x0, [x19, #2888]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #192]
	str	x0, [x19, #2896]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #200]
	str	x0, [x19, #2904]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #208]
	str	x0, [x19, #2912]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #216]
	str	x0, [x19, #2920]
	ldr	w0, [x19, #524]
	cbnz	x0, #184
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9760
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3008]
	mov	x0, x7
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9704
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3016]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	d0, [x19, #3008]
	fmov	d2, d0
	ldr	d0, [x19, #3016]
	fmov	d3, d0
	b	#9368
	ldr	w0, [x19, #524]
	cmp	x0, #8
	b.ne	#212
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2784]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9556
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#9544
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#9528
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#9512
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#9496
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#9472
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#9448
	mov	x0, x1
	str	x0, [x19, #3008]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	x0, [x19, #3008]
	mov	x7, x0
	b	#9152
	ldr	w0, [x19, #524]
	cmp	x0, #13
	b.ne	#432
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2784]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9336
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#9324
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#9308
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#9292
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#9276
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#9252
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#9228
	mov	x0, x1
	str	x0, [x19, #3008]
	ldr	x0, [x19, #2792]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9200
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3016]
	ldr	x0, [x19, #2800]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#9132
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#9120
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#9104
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#9088
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#9072
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#9048
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#9024
	mov	x0, x1
	str	x0, [x19, #3024]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	x0, [x19, #3008]
	mov	x7, x0
	ldr	d0, [x19, #3016]
	fmov	d2, d0
	ldr	x0, [x19, #3024]
	mov	x21, x0
	b	#8736
	ldr	w0, [x19, #524]
	cmp	x0, #27
	b.ne	#8
	b	#8760
	ldr	w0, [x19, #524]
	cmp	x0, #32
	b.ne	#340
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8892
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3008]
	ldr	x0, [x19, #2808]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8836
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3016]
	ldr	x0, [x19, #2816]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8768
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#8756
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#8740
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#8724
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#8708
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#8684
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#8660
	mov	x0, x1
	str	x0, [x19, #3024]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	d0, [x19, #3008]
	fmov	d2, d0
	ldr	d0, [x19, #3016]
	fmov	d3, d0
	ldr	x0, [x19, #3024]
	mov	x7, x0
	b	#8416
	ldr	w0, [x19, #524]
	cmp	x0, #34
	b.ne	#496
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8544
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3008]
	ldr	x0, [x19, #2784]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8476
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#8464
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#8448
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#8432
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#8416
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#8392
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#8368
	mov	x0, x1
	str	x0, [x19, #3016]
	ldr	x0, [x19, #2808]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8340
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3024]
	ldr	x0, [x19, #2816]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8272
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#8260
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#8244
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#8228
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#8212
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#8188
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#8164
	mov	x0, x1
	str	x0, [x19, #3032]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	d0, [x19, #3008]
	fmov	d2, d0
	ldr	x0, [x19, #3016]
	mov	x7, x0
	ldr	d0, [x19, #3024]
	fmov	d3, d0
	ldr	x0, [x19, #3032]
	mov	x21, x0
	b	#7944
	ldr	w0, [x19, #524]
	cmp	x0, #46
	b.ne	#908
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#8040
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3008]
	ldr	x0, [x19, #2784]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7972
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#7960
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#7944
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#7928
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#7912
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#7888
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#7864
	mov	x0, x1
	str	x0, [x19, #3016]
	ldr	x0, [x19, #2792]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7836
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3024]
	ldr	x0, [x19, #2800]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7768
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#7756
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#7740
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#7724
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#7708
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#7684
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#7660
	mov	x0, x1
	str	x0, [x19, #3032]
	ldr	x0, [x19, #2808]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7632
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3040]
	ldr	x0, [x19, #2816]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7564
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#7552
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#7536
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#7520
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#7504
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#7480
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#7456
	mov	x0, x1
	str	x0, [x19, #3048]
	ldr	x0, [x19, #2824]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7428
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3056]
	ldr	x0, [x19, #2832]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7372
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3064]
	ldr	x0, [x19, #2840]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7316
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3072]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	d0, [x19, #3008]
	fmov	d2, d0
	ldr	x0, [x19, #3016]
	mov	x7, x0
	ldr	d0, [x19, #3024]
	fmov	d3, d0
	ldr	x0, [x19, #3032]
	mov	x21, x0
	ldr	d0, [x19, #3040]
	fmov	d4, d0
	ldr	x0, [x19, #3048]
	mov	x22, x0
	ldr	d0, [x19, #3056]
	fmov	d5, d0
	ldr	d0, [x19, #3064]
	fmov	d6, d0
	ldr	d0, [x19, #3072]
	fmov	d7, d0
	b	#7072
	ldr	w0, [x19, #524]
	cmp	x0, #72
	b.ne	#340
	mov	x0, x23
	str	x0, [x19, #2984]
	ldr	x0, [x19, #2760]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2768]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7124
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3008]
	ldr	x0, [x19, #2808]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7068
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3016]
	ldr	x0, [x19, #2816]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#7000
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#6988
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#6972
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#6956
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#6940
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#6916
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#6892
	mov	x0, x1
	str	x0, [x19, #3024]
	ldr	x0, [x19, #2984]
	mov	x4, x0
	ldr	x0, [x19, #2992]
	mov	x5, x0
	ldr	x0, [x19, #3000]
	mov	x6, x0
	ldr	d0, [x19, #3008]
	fmov	d2, d0
	ldr	d0, [x19, #3016]
	fmov	d3, d0
	ldr	x0, [x19, #3024]
	mov	x7, x0
	b	#6796
	b	#6828
	mov	x0, #0                          // =0x0
	scvtf	d4, x0
	fmov	d0, d2
	fmov	d1, d4
	fcmp	d0, d1
	b.eq	#12
	mov	x0, #-3096224743817216          // =0xfff5000000000000
	b	#12
	mov	x0, #1                          // =0x1
	movk	x0, #65525, lsl #48
	mov	x21, x0
	mov	x0, x21
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#100
	mov	x10, #65525                     // =0xfff5
	cmp	x3, x10
	b.eq	#88
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.eq	#36
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.lo	#6744
	mov	x10, #65524                     // =0xfff4
	cmp	x3, x10
	b.hi	#6732
	mov	x0, #0                          // =0x0
	b	#48
	and	x0, x0, #0xffffffffffff
	mov	x1, #33344                      // =0x8240
	movk	x1, #11520, lsl #16
	movk	x1, #121, lsl #32
	ldr	x1, [x1]
	cmp	x0, x1
	b.eq	#12
	mov	x0, #1                          // =0x1
	b	#12
	mov	x0, #0                          // =0x0
	and	x0, x0, #0xffffffffffff
	cbz	x0, #8
	b	#12
	mov	x7, x21
	b	#52
	mov	x0, #1                          // =0x1
	scvtf	d4, x0
	fmov	d0, d3
	fmov	d1, d4
	fcmp	d0, d1
	b.eq	#12
	mov	x0, #-3096224743817216          // =0xfff5000000000000
	b	#12
	mov	x0, #1                          // =0x1
	movk	x0, #65525, lsl #48
	mov	x21, x0
	mov	x7, x21
	mov	x0, x7
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#100
	mov	x10, #65525                     // =0xfff5
	cmp	x3, x10
	b.eq	#88
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.eq	#36
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.lo	#6576
	mov	x10, #65524                     // =0xfff4
	cmp	x3, x10
	b.hi	#6564
	mov	x0, #0                          // =0x0
	b	#48
	and	x0, x0, #0xffffffffffff
	mov	x1, #33344                      // =0x8240
	movk	x1, #11520, lsl #16
	movk	x1, #121, lsl #32
	ldr	x1, [x1]
	cmp	x0, x1
	b.eq	#12
	mov	x0, #1                          // =0x1
	b	#12
	mov	x0, #0                          // =0x0
	and	x0, x0, #0xffffffffffff
	cbz	x0, #8
	b	#8
	b	#1776
	mov	x21, x4
	mov	x22, x5
	mov	x23, x6
	mov	x0, #1                          // =0x1
	str	x0, [x19, #2680]
	b	#6004
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#6456
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#6436
	and	x0, x0, #0xffffffffffff
	cbz	x0, #6428
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#6404
	ldr	x1, [x0, #128]
	cbz	x1, #6396
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #6372
	ldr	x2, [x1]
	cbz	x2, #6364
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#6348
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#6324
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#6284
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#6260
	mov	x4, x0
	ldr	x0, [x19, #2472]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6244
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d4, d2, d3
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d2, d4, d1
	mov	x0, x21
	str	x0, [x19, #2640]
	mov	x0, x22
	str	x0, [x19, #2648]
	mov	x0, x23
	str	x0, [x19, #2656]
	ldr	x0, [x19, #2472]
	str	x0, [x19, #2664]
	fmov	d3, d2
	mov	x0, #0                          // =0x0
	str	x0, [x19, #2672]
	b	#5596
	fmov	d0, d3
	fcmp	d0, d0
	b.vs	#6152
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#6136
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#6120
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#6104
	fcvtzs	x4, d0
	scvtf	d1, x4
	fcmp	d0, d1
	b.eq	#8
	b	#6084
	sxtw	x4, w4
	mov	x1, x4
	cmp	x1, x24
	b.hs	#6068
	lsl	x1, x1, #3
	add	x2, x25, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#6040
	fmov	d2, x0
	fmov	x5, d2
	lsr	x3, x5, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x5, xzr, #0x7ff8000000000000
	mov	x1, x4
	cmp	x1, x26
	b.hs	#6016
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5988
	mov	x0, x5
	str	x0, [x2]
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d4, d3, d1
	ldr	x0, [x19, #2496]
	adds	w0, w0, #1
	b.vs	#5972
	sxtw	x0, w0
	str	x0, [x19, #2928]
	mov	x4, x22
	mov	x5, x23
	ldr	x0, [x19, #2480]
	mov	x6, x0
	ldr	x0, [x19, #2488]
	mov	x7, x0
	fmov	d2, d4
	ldr	x0, [x19, #2928]
	mov	x21, x0
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#5908
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#5888
	and	x0, x0, #0xffffffffffff
	cbz	x0, #5880
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#5856
	ldr	x1, [x0, #128]
	cbz	x1, #5848
	add	x1, x1, #16
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #5820
	ldr	x2, [x1]
	cbz	x2, #5812
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#5796
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#5772
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#5732
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#5708
	str	x0, [x19, #2936]
	mov	x0, x21
	scvtf	d3, x0
	ldr	x0, [x19, #2936]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5692
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d4, x0
	b	#8
	fmov	d4, x0
	fmov	d0, d3
	fmov	d1, d4
	fcmp	d0, d1
	b.mi	#8
	b	#56
	cmp	x20, #1
	b.ls	#5632
	sub	x20, x20, #1
	mov	x22, x4
	mov	x23, x5
	mov	x0, x6
	str	x0, [x19, #2480]
	mov	x0, x7
	str	x0, [x19, #2488]
	fmov	d3, d2
	mov	x0, x21
	str	x0, [x19, #2496]
	b	#-636
	adds	w21, w7, #1
	b.vs	#5596
	sxtw	x21, w21
	mov	x7, x4
	mov	x0, x5
	str	x0, [x19, #2504]
	mov	x0, x6
	str	x0, [x19, #2512]
	mov	x0, x21
	str	x0, [x19, #2520]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#5544
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#5524
	and	x0, x0, #0xffffffffffff
	cbz	x0, #5516
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#5492
	ldr	x1, [x0, #128]
	cbz	x1, #5484
	add	x1, x1, #32
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #5456
	ldr	x2, [x1]
	cbz	x2, #5448
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#5432
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#5408
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#5368
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#5344
	mov	x4, x0
	ldr	x0, [x19, #2520]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5328
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmov	d0, d2
	fmov	d1, d3
	fcmp	d0, d1
	b.ls	#12
	mov	x0, #-3096224743817216          // =0xfff5000000000000
	b	#12
	mov	x0, #1                          // =0x1
	movk	x0, #65525, lsl #48
	mov	x4, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#100
	mov	x10, #65525                     // =0xfff5
	cmp	x3, x10
	b.eq	#88
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.eq	#36
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.lo	#5220
	mov	x10, #65524                     // =0xfff4
	cmp	x3, x10
	b.hi	#5208
	mov	x0, #0                          // =0x0
	b	#48
	and	x0, x0, #0xffffffffffff
	mov	x1, #33344                      // =0x8240
	movk	x1, #11520, lsl #16
	movk	x1, #121, lsl #32
	ldr	x1, [x1]
	cmp	x0, x1
	b.eq	#12
	mov	x0, #1                          // =0x1
	b	#12
	mov	x0, #0                          // =0x0
	and	x0, x0, #0xffffffffffff
	cbnz	x0, #8
	b	#48
	cmp	x20, #1
	b.ls	#5140
	sub	x20, x20, #1
	mov	x21, x7
	ldr	x0, [x19, #2504]
	mov	x22, x0
	ldr	x0, [x19, #2512]
	mov	x23, x0
	ldr	x0, [x19, #2520]
	str	x0, [x19, #2472]
	b	#-1544
	mov	x0, x7
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #968]
	ldr	x0, [x19, #2504]
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #976]
	mov	x0, x7
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #18                         // =0x12
	str	w9, [x2]
	str	x0, [x2, #8]
	ldr	x0, [x19, #2504]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #19                         // =0x13
	str	w9, [x2, #16]
	str	x0, [x2, #24]
	ldr	x2, [x19, #2464]
	mov	x9, #2                          // =0x2
	str	w9, [x2, #136]
	str	x20, [x19, #920]
	mov	x0, x19
	mov	x1, #17024                      // =0x4280
	movk	x1, #11537, lsl #16
	movk	x1, #121, lsl #32
	bl	#-2064720
	cbz	x0, #40
	ldr	w0, [x19, #524]
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	ldr	x20, [x19, #920]
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #128]
	mov	x4, x0
	mov	x4, #-3659174697238528          // =0xfff3000000000000
	b	#4920
	mov	x0, #1                          // =0x1
	scvtf	d4, x0
	fdiv	d6, d4, d3
	mov	x21, x4
	mov	x22, x5
	mov	x23, x6
	fmov	d4, d2
	fmov	d5, d6
	mov	x0, #0                          // =0x0
	str	x0, [x19, #2752]
	b	#4364
	mov	x4, x21
	mov	x5, x22
	mov	x6, x23
	fmov	d2, d4
	mov	x0, #1                          // =0x1
	str	x0, [x19, #2736]
	fmov	d7, d5
	ldr	x0, [x19, #2528]
	str	x0, [x19, #2744]
	b	#4280
	ldr	x0, [x19, #2544]
	subs	w4, w0, #1
	b.vs	#4840
	sxtw	x4, w4
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4816
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4796
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4788
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4764
	ldr	x1, [x0, #128]
	cbz	x1, #4756
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4732
	ldr	x2, [x1]
	cbz	x2, #4724
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4708
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4684
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4644
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4620
	mov	x5, x0
	mov	x0, x4
	scvtf	d2, x0
	mov	x0, x5
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4604
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d6, d2, d3
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4548
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4528
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4520
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4496
	ldr	x1, [x0, #128]
	cbz	x1, #4488
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4464
	ldr	x2, [x1]
	cbz	x2, #4456
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4440
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4416
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4376
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4352
	mov	x4, x0
	ldr	x0, [x19, #2544]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4336
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d7, d2, d3
	ldr	x0, [x19, #2544]
	adds	w4, w0, #1
	b.vs	#4304
	sxtw	x4, w4
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4280
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4260
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4252
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4228
	ldr	x1, [x0, #128]
	cbz	x1, #4220
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4196
	ldr	x2, [x1]
	cbz	x2, #4188
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4172
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4148
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4108
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4084
	mov	x5, x0
	mov	x0, x4
	scvtf	d2, x0
	mov	x0, x5
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4068
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d22, d2, d3
	fmov	d0, d7
	fcmp	d0, d0
	b.vs	#4036
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#4020
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#4004
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3988
	fcvtzs	x4, d0
	scvtf	d1, x4
	fcmp	d0, d1
	b.eq	#8
	b	#3968
	sxtw	x4, w4
	mov	x1, x4
	cmp	x1, x26
	b.hs	#3952
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x5, [x2]
	lsr	x3, x5, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3924
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d2, d7, d1
	mov	x0, x22
	str	x0, [x19, #2984]
	mov	x0, x23
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2536]
	str	x0, [x19, #3000]
	fmov	d0, d4
	str	d0, [x19, #3008]
	ldr	x0, [x19, #2544]
	str	x0, [x19, #3016]
	fmov	d0, d2
	str	d0, [x19, #3024]
	mov	x0, #1                          // =0x1
	str	x0, [x19, #3032]
	fmov	d0, d5
	str	d0, [x19, #3040]
	ldr	x0, [x19, #2552]
	str	x0, [x19, #3048]
	fmov	d0, d6
	str	d0, [x19, #3056]
	fmov	d0, d22
	str	d0, [x19, #3064]
	mov	x0, x5
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3820
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3072]
	ldr	x0, [x19, #2984]
	str	x0, [x19, #2688]
	ldr	x0, [x19, #2992]
	str	x0, [x19, #2696]
	ldr	x0, [x19, #3000]
	str	x0, [x19, #2704]
	ldr	d0, [x19, #3008]
	fmov	d16, d0
	ldr	x0, [x19, #3016]
	str	x0, [x19, #2712]
	ldr	d0, [x19, #3024]
	fmov	d17, d0
	ldr	x0, [x19, #3032]
	str	x0, [x19, #2720]
	ldr	d0, [x19, #3040]
	fmov	d18, d0
	ldr	x0, [x19, #3048]
	str	x0, [x19, #2728]
	ldr	d0, [x19, #3056]
	fmov	d19, d0
	ldr	d0, [x19, #3064]
	fmov	d20, d0
	ldr	d0, [x19, #3072]
	fmov	d21, d0
	b	#2892
	fmov	d0, d17
	fcmp	d0, d0
	b.vs	#3688
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#3672
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3656
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3640
	fcvtzs	x4, d0
	scvtf	d1, x4
	fcmp	d0, d1
	b.eq	#8
	b	#3620
	sxtw	x4, w4
	mov	x1, x4
	cmp	x1, x24
	b.hs	#3604
	lsl	x1, x1, #3
	add	x2, x25, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#3576
	fmov	d2, x0
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d22, d17, d1
	fmov	d0, d22
	fcmp	d0, d0
	b.vs	#3564
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#3548
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3532
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3516
	fcvtzs	x5, d0
	scvtf	d1, x5
	fcmp	d0, d1
	b.eq	#8
	b	#3496
	sxtw	x5, w5
	mov	x1, x5
	cmp	x1, x26
	b.hs	#3480
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x6, [x2]
	lsr	x3, x6, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3452
	mov	x0, x6
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3448
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fadd	d4, d21, d3
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d21, d19, d1
	fmov	d0, d21
	fcmp	d0, d0
	b.vs	#3404
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#3388
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3372
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3356
	fcvtzs	x5, d0
	scvtf	d1, x5
	fcmp	d0, d1
	b.eq	#8
	b	#3336
	sxtw	x5, w5
	mov	x1, x5
	cmp	x1, x26
	b.hs	#3320
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x6, [x2]
	lsr	x3, x6, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3292
	mov	x0, x6
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3288
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fadd	d5, d4, d3
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d19, d20, d1
	fmov	d0, d19
	fcmp	d0, d0
	b.vs	#3244
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#3228
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3212
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3196
	fcvtzs	x5, d0
	scvtf	d1, x5
	fcmp	d0, d1
	b.eq	#8
	b	#3176
	sxtw	x5, w5
	mov	x1, x5
	cmp	x1, x26
	b.hs	#3160
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x6, [x2]
	lsr	x3, x6, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3132
	mov	x0, x6
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3128
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fadd	d4, d5, d3
	fmul	d3, d16, d4
	fadd	d4, d2, d3
	fmul	d20, d4, d18
	fmov	x5, d20
	lsr	x3, x5, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x5, xzr, #0x7ff8000000000000
	mov	x1, x4
	cmp	x1, x26
	b.hs	#3060
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3032
	mov	x0, x5
	str	x0, [x2]
	ldr	x0, [x19, #2584]
	adds	w0, w0, #1
	b.vs	#3028
	sxtw	x0, w0
	str	x0, [x19, #2944]
	mov	x4, x23
	ldr	x0, [x19, #2560]
	mov	x5, x0
	ldr	x0, [x19, #2568]
	mov	x6, x0
	fmov	d2, d16
	ldr	x0, [x19, #2576]
	mov	x7, x0
	fmov	d3, d22
	ldr	x0, [x19, #2944]
	mov	x21, x0
	fmov	d4, d18
	ldr	x0, [x19, #2592]
	mov	x22, x0
	fmov	d5, d21
	fmov	d6, d19
	fmov	d7, d20
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#2932
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#2912
	and	x0, x0, #0xffffffffffff
	cbz	x0, #2904
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#2880
	ldr	x1, [x0, #128]
	cbz	x1, #2872
	add	x1, x1, #16
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #2844
	ldr	x2, [x1]
	cbz	x2, #2836
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#2820
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#2796
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#2756
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#2732
	str	x0, [x19, #2952]
	mov	x0, x21
	scvtf	d16, x0
	ldr	x0, [x19, #2952]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2716
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d17, x0
	b	#8
	fmov	d17, x0
	fmov	d0, d16
	fmov	d1, d17
	fcmp	d0, d1
	b.ls	#8
	b	#88
	cmp	x20, #1
	b.ls	#2656
	sub	x20, x20, #1
	mov	x23, x4
	mov	x0, x5
	str	x0, [x19, #2560]
	mov	x0, x6
	str	x0, [x19, #2568]
	fmov	d16, d2
	mov	x0, x7
	str	x0, [x19, #2576]
	fmov	d17, d3
	mov	x0, x21
	str	x0, [x19, #2584]
	fmov	d18, d4
	mov	x0, x22
	str	x0, [x19, #2592]
	fmov	d19, d5
	fmov	d20, d6
	fmov	d21, d7
	b	#-1276
	adds	w23, w7, #1
	b.vs	#2588
	sxtw	x23, w23
	mov	x7, x4
	mov	x21, x5
	mov	x0, x6
	str	x0, [x19, #2600]
	fmov	d3, d2
	mov	x0, x23
	str	x0, [x19, #2608]
	fmov	d6, d4
	mov	x0, x22
	str	x0, [x19, #2616]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#2524
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#2504
	and	x0, x0, #0xffffffffffff
	cbz	x0, #2496
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#2472
	ldr	x1, [x0, #128]
	cbz	x1, #2464
	add	x1, x1, #32
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #2436
	ldr	x2, [x1]
	cbz	x2, #2428
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#2412
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#2388
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#2348
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#2324
	mov	x4, x0
	ldr	x0, [x19, #2608]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2308
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d4, x0
	b	#8
	fmov	d4, x0
	fmov	d0, d2
	fmov	d1, d4
	fcmp	d0, d1
	b.ls	#12
	mov	x0, #-3096224743817216          // =0xfff5000000000000
	b	#12
	mov	x0, #1                          // =0x1
	movk	x0, #65525, lsl #48
	mov	x4, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#100
	mov	x10, #65525                     // =0xfff5
	cmp	x3, x10
	b.eq	#88
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.eq	#36
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.lo	#2200
	mov	x10, #65524                     // =0xfff4
	cmp	x3, x10
	b.hi	#2188
	mov	x0, #0                          // =0x0
	b	#48
	and	x0, x0, #0xffffffffffff
	mov	x1, #33344                      // =0x8240
	movk	x1, #11520, lsl #16
	movk	x1, #121, lsl #32
	ldr	x1, [x1]
	cmp	x0, x1
	b.eq	#12
	mov	x0, #1                          // =0x1
	b	#12
	mov	x0, #0                          // =0x0
	and	x0, x0, #0xffffffffffff
	cbnz	x0, #8
	b	#60
	cmp	x20, #1
	b.ls	#2120
	sub	x20, x20, #1
	mov	x22, x7
	mov	x23, x21
	ldr	x0, [x19, #2600]
	str	x0, [x19, #2536]
	fmov	d4, d3
	ldr	x0, [x19, #2608]
	str	x0, [x19, #2544]
	fmov	d5, d6
	ldr	x0, [x19, #2616]
	str	x0, [x19, #2552]
	b	#-3160
	mov	x0, x7
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1832]
	fmov	d0, d3
	fmov	x0, d0
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1856]
	fmov	d0, d6
	fmov	x0, d0
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1872]
	mov	x0, x21
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1840]
	ldr	x0, [x19, #2600]
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1848]
	mov	x0, x7
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #0                          // =0x0
	str	w9, [x2]
	str	x0, [x2, #8]
	mov	x0, x21
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #1                          // =0x1
	str	w9, [x2, #16]
	str	x0, [x2, #24]
	ldr	x0, [x19, #2600]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #2                          // =0x2
	str	w9, [x2, #32]
	str	x0, [x2, #40]
	fmov	d0, d3
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #3                          // =0x3
	str	w9, [x2, #48]
	str	x0, [x2, #56]
	fmov	d0, d6
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #8                          // =0x8
	str	w9, [x2, #64]
	str	x0, [x2, #72]
	ldr	x0, [x19, #2616]
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #9                          // =0x9
	str	w9, [x2, #80]
	str	x0, [x2, #88]
	mov	x0, x7
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #18                         // =0x12
	str	w9, [x2, #96]
	str	x0, [x2, #104]
	mov	x0, x21
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #19                         // =0x13
	str	w9, [x2, #112]
	str	x0, [x2, #120]
	ldr	x2, [x19, #2464]
	mov	x9, #8                          // =0x8
	str	w9, [x2, #136]
	str	x20, [x19, #920]
	mov	x0, x19
	mov	x1, #36928                      // =0x9040
	movk	x1, #11469, lsl #16
	movk	x1, #121, lsl #32
	bl	#-2068428
	cbz	x0, #40
	ldr	w0, [x19, #524]
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	ldr	x20, [x19, #920]
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	ldr	x0, [x3, #1832]
	mov	x7, x0
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	ldr	x0, [x3, #1856]
	fmov	d0, x0
	fmov	d3, d0
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	ldr	x0, [x3, #1872]
	fmov	d0, x0
	fmov	d6, d0
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #128]
	mov	x4, x0
	mov	x4, #-3659174697238528          // =0xfff3000000000000
	mov	x22, x7
	mov	x23, x21
	ldr	x0, [x19, #2600]
	str	x0, [x19, #2624]
	fmov	d4, d3
	fmov	d5, d6
	ldr	x0, [x19, #2616]
	str	x0, [x19, #2632]
	ldr	x0, [x19, #2632]
	adds	w21, w0, #1
	b.vs	#1532
	sxtw	x21, w21
	mov	x4, x22
	mov	x5, x23
	ldr	x0, [x19, #2624]
	mov	x6, x0
	fmov	d2, d4
	fmov	d3, d5
	mov	x7, x21
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#1480
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#1460
	and	x0, x0, #0xffffffffffff
	cbz	x0, #1452
	ldr	x3, [x0, #56]
	mov	x10, #54352                     // =0xd450
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#1428
	ldr	x1, [x0, #128]
	cbz	x1, #1420
	add	x1, x1, #48
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #1392
	ldr	x2, [x1]
	cbz	x2, #1384
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#1368
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#1344
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#1304
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#1280
	str	x0, [x19, #2960]
	mov	x0, x7
	scvtf	d4, x0
	ldr	x0, [x19, #2960]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#1264
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d5, x0
	b	#8
	fmov	d5, x0
	fmov	d0, d4
	fmov	d1, d5
	fcmp	d0, d1
	b.mi	#8
	b	#48
	cmp	x20, #1
	b.ls	#1204
	sub	x20, x20, #1
	mov	x21, x4
	mov	x22, x5
	mov	x23, x6
	fmov	d4, d2
	fmov	d5, d3
	mov	x0, x7
	str	x0, [x19, #2528]
	b	#-4152
	b	#1180
	ldr	x0, [x19, #2640]
	mov	x4, x0
	ldr	x0, [x19, #2648]
	mov	x5, x0
	ldr	x0, [x19, #2656]
	mov	x6, x0
	ldr	x0, [x19, #2664]
	mov	x7, x0
	fmov	d2, d3
	ldr	x0, [x19, #2672]
	mov	x21, x0
	b	#-5368
	mov	x7, x21
	mov	x0, x22
	str	x0, [x19, #2504]
	mov	x0, x23
	str	x0, [x19, #2512]
	ldr	x0, [x19, #2680]
	str	x0, [x19, #2520]
	b	#-4988
	ldr	x0, [x19, #2688]
	mov	x4, x0
	ldr	x0, [x19, #2696]
	mov	x5, x0
	ldr	x0, [x19, #2704]
	mov	x6, x0
	fmov	d2, d16
	ldr	x0, [x19, #2712]
	mov	x7, x0
	fmov	d3, d17
	ldr	x0, [x19, #2720]
	mov	x21, x0
	fmov	d4, d18
	ldr	x0, [x19, #2728]
	mov	x22, x0
	fmov	d5, d19
	fmov	d6, d20
	fmov	d7, d21
	b	#-2084
	mov	x7, x4
	mov	x21, x5
	mov	x0, x6
	str	x0, [x19, #2600]
	fmov	d3, d2
	ldr	x0, [x19, #2736]
	str	x0, [x19, #2608]
	fmov	d6, d7
	ldr	x0, [x19, #2744]
	str	x0, [x19, #2616]
	b	#-1672
	mov	x4, x21
	mov	x5, x22
	mov	x6, x23
	fmov	d2, d4
	fmov	d3, d5
	ldr	x0, [x19, #2752]
	mov	x7, x0
	b	#-596
	b	#-6568
	mov	x21, x4
	mov	x22, x5
	mov	x23, x6
	mov	x0, x7
	str	x0, [x19, #2472]
	b	#-6208
	mov	x22, x4
	mov	x23, x5
	mov	x0, x6
	str	x0, [x19, #2480]
	mov	x0, x7
	str	x0, [x19, #2488]
	fmov	d3, d2
	mov	x0, x21
	str	x0, [x19, #2496]
	b	#-5888
	b	#-4508
	mov	x21, x4
	mov	x22, x5
	mov	x23, x6
	fmov	d4, d2
	fmov	d5, d3
	mov	x0, x7
	str	x0, [x19, #2528]
	b	#-4492
	mov	x22, x4
	mov	x23, x5
	mov	x0, x6
	str	x0, [x19, #2536]
	fmov	d4, d2
	mov	x0, x7
	str	x0, [x19, #2544]
	fmov	d5, d3
	mov	x0, x21
	str	x0, [x19, #2552]
	b	#-4496
	mov	x23, x4
	mov	x0, x5
	str	x0, [x19, #2560]
	mov	x0, x6
	str	x0, [x19, #2568]
	fmov	d16, d2
	mov	x0, x7
	str	x0, [x19, #2576]
	fmov	d17, d3
	mov	x0, x21
	str	x0, [x19, #2584]
	fmov	d18, d4
	mov	x0, x22
	str	x0, [x19, #2592]
	fmov	d19, d5
	fmov	d20, d6
	fmov	d21, d7
	b	#-3256
	mov	x22, x4
	mov	x23, x5
	mov	x0, x6
	str	x0, [x19, #2624]
	fmov	d4, d2
	fmov	d5, d3
	mov	x0, x7
	str	x0, [x19, #2632]
	b	#-896
	mov	x0, #53056                      // =0xcf40
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#692
	mov	x0, #53088                      // =0xcf60
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#676
	mov	x0, #53120                      // =0xcf80
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#660
	mov	x0, #53152                      // =0xcfa0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#644
	mov	x0, #53184                      // =0xcfc0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#628
	mov	x0, #53216                      // =0xcfe0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#612
	mov	x0, #53248                      // =0xd000
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#596
	mov	x0, #53280                      // =0xd020
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#580
	mov	x0, #53312                      // =0xd040
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#564
	mov	x0, #53344                      // =0xd060
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#548
	mov	x0, #53376                      // =0xd080
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#532
	mov	x0, #53408                      // =0xd0a0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#516
	mov	x0, #53440                      // =0xd0c0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#500
	mov	x0, #53472                      // =0xd0e0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#484
	mov	x0, #53504                      // =0xd100
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#468
	mov	x0, #53536                      // =0xd120
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#452
	mov	x0, #53568                      // =0xd140
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#436
	mov	x0, #53600                      // =0xd160
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#420
	mov	x0, #53632                      // =0xd180
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#404
	mov	x0, #53664                      // =0xd1a0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#388
	mov	x0, #53696                      // =0xd1c0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#372
	mov	x0, #53728                      // =0xd1e0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#356
	mov	x0, #53760                      // =0xd200
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#340
	mov	x0, #53792                      // =0xd220
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#324
	mov	x0, #53824                      // =0xd240
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#308
	mov	x0, #53856                      // =0xd260
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#292
	mov	x0, #53888                      // =0xd280
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#276
	mov	x0, #53920                      // =0xd2a0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#260
	mov	x0, #53952                      // =0xd2c0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#244
	mov	x0, #53984                      // =0xd2e0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#228
	mov	x0, #54016                      // =0xd300
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#212
	mov	x0, #54048                      // =0xd320
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#196
	mov	x0, #54080                      // =0xd340
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#180
	mov	x0, #54112                      // =0xd360
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#164
	mov	x0, #54144                      // =0xd380
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#148
	mov	x0, #54176                      // =0xd3a0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#132
	mov	x0, #54208                      // =0xd3c0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#116
	mov	x0, #54240                      // =0xd3e0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#100
	mov	x0, #54272                      // =0xd400
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#84
	mov	x0, #54304                      // =0xd420
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#68
	mov	x0, #54336                      // =0xd440
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#52
	mov	x0, #54368                      // =0xd460
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#36
	mov	x0, #54400                      // =0xd480
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#20
	mov	x0, #54432                      // =0xd4a0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#4
	ldr	x1, [x19, #2464]
	ldr	x2, [x1, #120]
	str	x23, [x2]
	str	x7, [x2, #8]
	str	x4, [x2, #16]
	str	x5, [x2, #24]
	str	x6, [x2, #32]
	str	x21, [x2, #40]
	str	x22, [x2, #48]
	str	d2, [x2, #56]
	str	d3, [x2, #64]
	str	d4, [x2, #72]
	str	d5, [x2, #80]
	str	d6, [x2, #88]
	str	d7, [x2, #96]
	str	d22, [x2, #104]
	str	d16, [x2, #112]
	str	d17, [x2, #120]
	str	d18, [x2, #128]
	str	d19, [x2, #136]
	str	d20, [x2, #144]
	str	d21, [x2, #152]
	str	x20, [x19, #920]
	mov	x1, x0
	ldr	x0, [x19, #2464]
	bl	#-2097412
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
