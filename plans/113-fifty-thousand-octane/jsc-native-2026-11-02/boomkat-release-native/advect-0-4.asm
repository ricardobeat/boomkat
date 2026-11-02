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
	b.ne	#7200
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x0, [x19, #32]
	ldr	x10, [x19, #560]
	cmp	x0, x10
	b.ne	#7176
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #16]
	ldr	x10, [x19, #592]
	cmp	x0, x10
	b.ne	#7152
	ldr	x0, [x19, #8]
	ldr	x10, [x19, #624]
	cmp	x0, x10
	b.ne	#7136
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0]
	str	x0, [x19, #2704]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #8]
	str	x0, [x19, #2712]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #16]
	str	x0, [x19, #2720]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #24]
	str	x0, [x19, #2728]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #32]
	str	x0, [x19, #2736]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #40]
	mov	x22, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #48]
	str	x0, [x19, #2744]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #56]
	str	x0, [x19, #2752]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #64]
	str	x0, [x19, #2760]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #72]
	str	x0, [x19, #2768]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #80]
	str	x0, [x19, #2776]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #88]
	str	x0, [x19, #2784]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #96]
	str	x0, [x19, #2792]
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
	mov	x7, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #136]
	mov	x21, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #144]
	mov	x23, x0
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #152]
	str	x0, [x19, #2800]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #160]
	str	x0, [x19, #2808]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #168]
	str	x0, [x19, #2816]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #176]
	str	x0, [x19, #2824]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #184]
	str	x0, [x19, #2832]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #192]
	str	x0, [x19, #2840]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #200]
	str	x0, [x19, #2848]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #208]
	str	x0, [x19, #2856]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #216]
	str	x0, [x19, #2864]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #224]
	str	x0, [x19, #2872]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #232]
	str	x0, [x19, #2880]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #240]
	str	x0, [x19, #2888]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #248]
	str	x0, [x19, #2896]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #256]
	str	x0, [x19, #2904]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #264]
	str	x0, [x19, #2912]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #272]
	str	x0, [x19, #2920]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #280]
	str	x0, [x19, #2928]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #288]
	str	x0, [x19, #2936]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #296]
	str	x0, [x19, #2944]
	ldr	x0, [x19, #2464]
	ldr	x0, [x0, #88]
	ldr	x0, [x0, #304]
	str	x0, [x19, #2952]
	ldr	w0, [x19, #524]
	cbnz	x0, #152
	ldr	x0, [x19, #2704]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2712]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2720]
	str	x0, [x19, #3008]
	ldr	x0, [x19, #2728]
	str	x0, [x19, #3016]
	ldr	x0, [x19, #2736]
	str	x0, [x19, #3024]
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6444
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3032]
	ldr	x0, [x19, #2992]
	mov	x4, x0
	ldr	x0, [x19, #3000]
	mov	x5, x0
	ldr	x0, [x19, #3008]
	mov	x6, x0
	ldr	x0, [x19, #3016]
	mov	x7, x0
	ldr	x0, [x19, #3024]
	mov	x21, x0
	ldr	d0, [x19, #3032]
	fmov	d2, d0
	b	#6204
	ldr	w0, [x19, #524]
	cmp	x0, #12
	b.ne	#500
	ldr	x0, [x19, #2704]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2712]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2720]
	str	x0, [x19, #3008]
	ldr	x0, [x19, #2728]
	str	x0, [x19, #3016]
	ldr	x0, [x19, #2736]
	str	x0, [x19, #3024]
	ldr	x0, [x19, #2744]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6284
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3032]
	ldr	x0, [x19, #2752]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6228
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3040]
	ldr	x0, [x19, #2760]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6172
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3048]
	ldr	x0, [x19, #2768]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6116
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3056]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#6048
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#6036
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#6020
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#6004
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#5988
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#5964
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#5940
	mov	x0, x1
	str	x0, [x19, #3064]
	ldr	x0, [x19, #2992]
	mov	x4, x0
	ldr	x0, [x19, #3000]
	mov	x5, x0
	ldr	x0, [x19, #3008]
	mov	x6, x0
	ldr	x0, [x19, #3016]
	mov	x7, x0
	ldr	x0, [x19, #3024]
	mov	x21, x0
	ldr	d0, [x19, #3032]
	fmov	d2, d0
	ldr	d0, [x19, #3040]
	fmov	d3, d0
	ldr	d0, [x19, #3048]
	fmov	d4, d0
	ldr	d0, [x19, #3056]
	fmov	d5, d0
	ldr	x0, [x19, #3064]
	mov	x22, x0
	b	#5700
	ldr	w0, [x19, #524]
	cmp	x0, #16
	b.ne	#720
	ldr	x0, [x19, #2704]
	str	x0, [x19, #2992]
	ldr	x0, [x19, #2712]
	str	x0, [x19, #3000]
	ldr	x0, [x19, #2720]
	str	x0, [x19, #3008]
	ldr	x0, [x19, #2728]
	str	x0, [x19, #3016]
	ldr	x0, [x19, #2736]
	str	x0, [x19, #3024]
	ldr	x0, [x19, #2744]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5776
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3032]
	ldr	x0, [x19, #2752]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5720
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3040]
	ldr	x0, [x19, #2760]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5664
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3048]
	ldr	x0, [x19, #2768]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5608
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3056]
	ldr	x0, [x19, #2776]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5540
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#5528
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#5512
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#5496
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#5480
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#5456
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#5432
	mov	x0, x1
	str	x0, [x19, #3064]
	ldr	x0, [x19, #2784]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5404
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d0, x0
	b	#8
	fmov	d0, x0
	str	d0, [x19, #3072]
	ldr	x0, [x19, #2792]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#5336
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#5324
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#5308
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#5292
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#5276
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#5252
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#5228
	mov	x0, x1
	str	x0, [x19, #3080]
	ldr	x0, [x19, #2992]
	mov	x4, x0
	ldr	x0, [x19, #3000]
	mov	x5, x0
	ldr	x0, [x19, #3008]
	mov	x6, x0
	ldr	x0, [x19, #3016]
	mov	x7, x0
	ldr	x0, [x19, #3024]
	mov	x21, x0
	ldr	d0, [x19, #3032]
	fmov	d2, d0
	ldr	d0, [x19, #3040]
	fmov	d3, d0
	ldr	d0, [x19, #3048]
	fmov	d4, d0
	ldr	d0, [x19, #3056]
	fmov	d5, d0
	ldr	x0, [x19, #3064]
	mov	x22, x0
	ldr	d0, [x19, #3072]
	fmov	d6, d0
	ldr	x0, [x19, #3080]
	mov	x23, x0
	b	#5036
	ldr	w0, [x19, #524]
	cmp	x0, #78
	b.ne	#8
	b	#5100
	b	#5100
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#5080
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#5060
	and	x0, x0, #0xffffffffffff
	cbz	x0, #5052
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#5028
	ldr	x1, [x0, #128]
	cbz	x1, #5020
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4996
	ldr	x2, [x1]
	cbz	x2, #4988
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4972
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4948
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4908
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4884
	mov	x22, x0
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4876
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
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4820
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4800
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4792
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4768
	ldr	x1, [x0, #128]
	cbz	x1, #4760
	add	x1, x1, #16
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
	mov	x22, x0
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4612
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d7, d2, d3
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4556
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4536
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4528
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4504
	ldr	x1, [x0, #128]
	cbz	x1, #4496
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4472
	ldr	x2, [x1]
	cbz	x2, #4464
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4448
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4424
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4384
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4360
	mov	x22, x0
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4352
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d2, x0
	b	#8
	fmov	d2, x0
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fadd	d16, d2, d1
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#4288
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#4268
	and	x0, x0, #0xffffffffffff
	cbz	x0, #4260
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#4236
	ldr	x1, [x0, #128]
	cbz	x1, #4228
	add	x1, x1, #16
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #4200
	ldr	x2, [x1]
	cbz	x2, #4192
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#4176
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#4152
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#4112
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#4088
	mov	x22, x0
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#4080
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d2, x0
	b	#8
	fmov	d2, x0
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fadd	d17, d2, d1
	mov	x23, x4
	mov	x0, x5
	str	x0, [x19, #2664]
	mov	x0, x6
	str	x0, [x19, #2672]
	mov	x0, x7
	str	x0, [x19, #2680]
	mov	x0, x21
	str	x0, [x19, #2688]
	fmov	d2, d6
	fmov	d3, d7
	fmov	d4, d16
	fmov	d5, d17
	mov	x0, #1                          // =0x1
	str	x0, [x19, #2696]
	b	#3628
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#3952
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#3932
	and	x0, x0, #0xffffffffffff
	cbz	x0, #3924
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#3900
	ldr	x1, [x0, #128]
	cbz	x1, #3892
	add	x1, x1, #32
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #3864
	ldr	x2, [x1]
	cbz	x2, #3856
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#3840
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#3816
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#3776
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#3752
	mov	x4, x0
	ldr	x0, [x19, #2504]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#3736
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d4, d2, d3
	mov	x0, x23
	str	x0, [x19, #2608]
	ldr	x0, [x19, #2472]
	str	x0, [x19, #2616]
	ldr	x0, [x19, #2480]
	str	x0, [x19, #2624]
	ldr	x0, [x19, #2488]
	str	x0, [x19, #2632]
	ldr	x0, [x19, #2496]
	str	x0, [x19, #2640]
	fmov	d18, d6
	fmov	d19, d7
	fmov	d20, d16
	fmov	d21, d17
	ldr	x0, [x19, #2504]
	str	x0, [x19, #2648]
	fmov	d22, d4
	mov	x0, #1                          // =0x1
	str	x0, [x19, #2656]
	b	#3164
	orr	x0, xzr, #0x3ff0000000000000
	fmov	d1, x0
	fadd	d20, d19, d1
	fmov	d0, d20
	fcmp	d0, d0
	b.vs	#3612
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#3596
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3580
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3564
	fcvtzs	x4, d0
	scvtf	d1, x4
	fcmp	d0, d1
	b.eq	#8
	b	#3544
	sxtw	x4, w4
	mov	x1, x4
	cmp	x1, x24
	b.hs	#3528
	lsl	x1, x1, #3
	add	x2, x25, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#3500
	fmov	d2, x0
	fmul	d3, d7, d2
	ldr	x0, [x19, #2560]
	scvtf	d2, x0
	fsub	d4, d2, d3
	mov	x1, x4
	cmp	x1, x26
	b.hs	#3484
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#3456
	fmov	d2, x0
	fmul	d3, d16, d2
	ldr	x0, [x19, #2552]
	scvtf	d2, x0
	fsub	d5, d2, d3
	fmov	d0, d4
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fcmp	d0, d1
	b.pl	#8
	b	#8
	b	#20
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	d2, d0
	b	#36
	fmov	d0, d4
	fmov	d1, d17
	fcmp	d0, d1
	b.le	#8
	b	#12
	fmov	d2, d4
	b	#8
	fmov	d2, d17
	fmov	d0, d2
	fcmp	d0, d0
	b.vs	#3364
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3348
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3332
	fcvtzs	x5, d0
	sxtw	x5, w5
	orr	x6, x5, xzr
	sxtw	x6, w6
	adds	w5, w6, #1
	b.vs	#3324
	sxtw	x5, w5
	fmov	d0, d5
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d1, x3
	fcmp	d0, d1
	b.pl	#8
	b	#8
	b	#20
	orr	x3, xzr, #0x3fe0000000000000
	fmov	d0, x3
	fmov	d3, d0
	b	#36
	fmov	d0, d5
	fmov	d1, d18
	fcmp	d0, d1
	b.le	#8
	b	#12
	fmov	d3, d5
	b	#8
	fmov	d3, d18
	fmov	d0, d3
	fcmp	d0, d0
	b.vs	#3248
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#3232
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#3216
	fcvtzs	x7, d0
	sxtw	x7, w7
	orr	x21, x7, xzr
	sxtw	x21, w21
	adds	w7, w21, #1
	b.vs	#3208
	sxtw	x7, w7
	mov	x0, x6
	scvtf	d4, x0
	fsub	d5, d2, d4
	mov	x0, #1                          // =0x1
	scvtf	d2, x0
	fsub	d6, d2, d5
	mov	x0, x21
	scvtf	d2, x0
	fsub	d19, d3, d2
	mov	x0, #1                          // =0x1
	scvtf	d3, x0
	fsub	d21, d3, d19
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#3136
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#3116
	and	x0, x0, #0xffffffffffff
	cbz	x0, #3108
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#3084
	ldr	x1, [x0, #128]
	cbz	x1, #3076
	add	x1, x1, #32
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #3048
	ldr	x2, [x1]
	cbz	x2, #3040
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#3024
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#3000
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#2960
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#2936
	mov	x22, x0
	mov	x0, x22
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2928
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d22, d2, d3
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#2872
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#2852
	and	x0, x0, #0xffffffffffff
	cbz	x0, #2844
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#2820
	ldr	x1, [x0, #128]
	cbz	x1, #2812
	add	x1, x1, #32
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #2784
	ldr	x2, [x1]
	cbz	x2, #2776
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#2760
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#2736
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#2696
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#2672
	mov	x21, x0
	mov	x0, x7
	scvtf	d2, x0
	mov	x0, x21
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2656
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d3, x0
	b	#8
	fmov	d3, x0
	fmul	d23, d2, d3
	fadd	d2, d4, d22
	fmov	d0, d2
	fcmp	d0, d0
	b.vs	#2620
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#2604
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2588
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2572
	fcvtzs	x7, d0
	scvtf	d1, x7
	fcmp	d0, d1
	b.eq	#8
	b	#2552
	sxtw	x7, w7
	mov	x1, x7
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#2532
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2500
	fmov	d3, x0
	fmul	d2, d21, d3
	fadd	d3, d4, d23
	fmov	d0, d3
	fcmp	d0, d0
	b.vs	#2492
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#2476
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2460
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2444
	fcvtzs	x6, d0
	scvtf	d1, x6
	fcmp	d0, d1
	b.eq	#8
	b	#2424
	sxtw	x6, w6
	mov	x1, x6
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#2404
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2372
	fmov	d4, x0
	fmul	d3, d19, d4
	fadd	d4, d2, d3
	fmul	d2, d6, d4
	mov	x0, x5
	scvtf	d3, x0
	fadd	d4, d3, d22
	fmov	d0, d4
	fcmp	d0, d0
	b.vs	#2348
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#2332
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2316
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2300
	fcvtzs	x6, d0
	scvtf	d1, x6
	fcmp	d0, d1
	b.eq	#8
	b	#2280
	sxtw	x6, w6
	mov	x1, x6
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#2260
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2228
	fmov	d6, x0
	fmul	d4, d21, d6
	fadd	d6, d3, d23
	fmov	d0, d6
	fcmp	d0, d0
	b.vs	#2220
	fmov	x1, d0
	orr	x10, xzr, #0x8000000000000000
	cmp	x1, x10
	b.eq	#2204
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#2188
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#2172
	fcvtzs	x5, d0
	scvtf	d1, x5
	fcmp	d0, d1
	b.eq	#8
	b	#2152
	sxtw	x5, w5
	mov	x1, x5
	ldr	x10, [x19, #608]
	cmp	x1, x10
	b.hs	#2132
	lsl	x1, x1, #3
	ldr	x2, [x19, #600]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#2100
	fmov	d3, x0
	fmul	d6, d19, d3
	fadd	d3, d4, d6
	fmul	d4, d5, d3
	fadd	d3, d2, d4
	fmov	x5, d3
	lsr	x3, x5, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x5, xzr, #0x7ff8000000000000
	mov	x1, x4
	ldr	x10, [x19, #640]
	cmp	x1, x10
	b.hs	#2056
	lsl	x1, x1, #3
	ldr	x2, [x19, #632]
	add	x2, x2, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#2024
	mov	x0, x5
	str	x0, [x2]
	ldr	x0, [x19, #2560]
	adds	w0, w0, #1
	b.vs	#2020
	sxtw	x0, w0
	str	x0, [x19, #2960]
	ldr	x0, [x19, #2512]
	mov	x4, x0
	ldr	x0, [x19, #2520]
	mov	x5, x0
	ldr	x0, [x19, #2528]
	mov	x6, x0
	ldr	x0, [x19, #2536]
	mov	x7, x0
	ldr	x0, [x19, #2544]
	mov	x21, x0
	fmov	d2, d7
	fmov	d3, d16
	fmov	d4, d17
	fmov	d5, d18
	ldr	x0, [x19, #2552]
	mov	x22, x0
	fmov	d6, d20
	ldr	x0, [x19, #2960]
	mov	x23, x0
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#1916
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#1896
	and	x0, x0, #0xffffffffffff
	cbz	x0, #1888
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#1864
	ldr	x1, [x0, #128]
	cbz	x1, #1856
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #1832
	ldr	x2, [x1]
	cbz	x2, #1824
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#1808
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#1784
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#1744
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#1720
	str	x0, [x19, #2968]
	mov	x0, x23
	scvtf	d7, x0
	ldr	x0, [x19, #2968]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#1704
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d16, x0
	b	#8
	fmov	d16, x0
	fmov	d0, d7
	fmov	d1, d16
	fcmp	d0, d1
	b.ls	#8
	b	#96
	cmp	x20, #1
	b.ls	#1644
	sub	x20, x20, #1
	mov	x0, x4
	str	x0, [x19, #2512]
	mov	x0, x5
	str	x0, [x19, #2520]
	mov	x0, x6
	str	x0, [x19, #2528]
	mov	x0, x7
	str	x0, [x19, #2536]
	mov	x0, x21
	str	x0, [x19, #2544]
	fmov	d7, d2
	fmov	d16, d3
	fmov	d17, d4
	fmov	d18, d5
	mov	x0, x22
	str	x0, [x19, #2552]
	fmov	d19, d6
	mov	x0, x23
	str	x0, [x19, #2560]
	b	#-2344
	adds	w23, w22, #1
	b.vs	#1568
	sxtw	x23, w23
	mov	x22, x4
	mov	x0, x5
	str	x0, [x19, #2568]
	mov	x0, x6
	str	x0, [x19, #2576]
	mov	x0, x7
	str	x0, [x19, #2584]
	mov	x0, x21
	str	x0, [x19, #2592]
	fmov	d18, d2
	fmov	d19, d3
	fmov	d20, d4
	fmov	d21, d5
	mov	x0, x23
	str	x0, [x19, #2600]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2]
	ldr	x1, [x2, #16]
	ldr	x0, [x1]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x0, x10
	b.ne	#1484
	ldr	x0, [x1, #112]
	lsr	x3, x0, #48
	mov	x10, #65529                     // =0xfff9
	cmp	x3, x10
	b.ne	#1464
	and	x0, x0, #0xffffffffffff
	cbz	x0, #1456
	ldr	x3, [x0, #56]
	mov	x10, #62864                     // =0xf590
	movk	x10, #1288, lsl #16
	movk	x10, #1, lsl #32
	cmp	x3, x10
	b.ne	#1432
	ldr	x1, [x0, #128]
	cbz	x1, #1424
	add	x1, x1, #16
	ldrb	w3, [x1, #14]
	cbz	x3, #12
	ldr	x0, [x1]
	b	#84
	ldrb	w3, [x1, #13]
	cbnz	x3, #1396
	ldr	x2, [x1]
	cbz	x2, #1388
	ldr	w0, [x1, #8]
	ldr	w3, [x2, #24]
	cmp	x0, x3
	b.hs	#1372
	ldr	w3, [x2]
	mov	x10, #32768                     // =0x8000
	movk	x10, #4159, lsl #16
	and	x3, x3, x10
	cmp	x3, #16, lsl #12                // =65536
	b.ne	#1348
	lsl	x0, x0, #3
	ldr	x3, [x2, #40]
	cbnz	x3, #8
	add	x3, x2, #56
	add	x3, x3, x0
	ldr	x0, [x3]
	lsr	x3, x0, #48
	mov	x10, #65528                     // =0xfff8
	cmp	x3, x10
	b.eq	#1308
	mov	x10, #65523                     // =0xfff3
	cmp	x3, x10
	b.ne	#16
	mov	x10, #-3659174697238528         // =0xfff3000000000000
	cmp	x0, x10
	b.ne	#1284
	mov	x4, x0
	ldr	x0, [x19, #2600]
	scvtf	d2, x0
	mov	x0, x4
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#1268
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
	b.lo	#1160
	mov	x10, #65524                     // =0xfff4
	cmp	x3, x10
	b.hi	#1148
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
	b	#80
	cmp	x20, #1
	b.ls	#1080
	sub	x20, x20, #1
	mov	x23, x22
	ldr	x0, [x19, #2568]
	str	x0, [x19, #2472]
	ldr	x0, [x19, #2576]
	str	x0, [x19, #2480]
	ldr	x0, [x19, #2584]
	str	x0, [x19, #2488]
	ldr	x0, [x19, #2592]
	str	x0, [x19, #2496]
	fmov	d6, d18
	fmov	d7, d19
	fmov	d16, d20
	fmov	d17, d21
	ldr	x0, [x19, #2600]
	str	x0, [x19, #2504]
	b	#-3340
	mov	x0, x22
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1656]
	ldr	x0, [x19, #2568]
	ldr	x3, [x19, #2464]
	ldr	x3, [x3, #120]
	str	x0, [x3, #1664]
	mov	x0, x22
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #27                         // =0x1b
	str	w9, [x2]
	str	x0, [x2, #8]
	ldr	x0, [x19, #2568]
	ldr	x2, [x19, #2464]
	ldr	x2, [x2, #128]
	mov	x9, #28                         // =0x1c
	str	w9, [x2, #16]
	str	x0, [x2, #24]
	ldr	x2, [x19, #2464]
	mov	x9, #2                          // =0x2
	str	w9, [x2, #136]
	str	x20, [x19, #920]
	mov	x0, x19
	mov	x1, #17504                      // =0x4460
	movk	x1, #11537, lsl #16
	movk	x1, #121, lsl #32
	bl	#-2423296
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
	ldr	x0, [x0, #200]
	mov	x4, x0
	mov	x4, #-3659174697238528          // =0xfff3000000000000
	b	#828
	ldr	x0, [x19, #2608]
	mov	x4, x0
	ldr	x0, [x19, #2616]
	mov	x5, x0
	ldr	x0, [x19, #2624]
	mov	x6, x0
	ldr	x0, [x19, #2632]
	mov	x7, x0
	ldr	x0, [x19, #2640]
	mov	x21, x0
	fmov	d2, d18
	fmov	d3, d19
	fmov	d4, d20
	fmov	d5, d21
	ldr	x0, [x19, #2648]
	mov	x22, x0
	fmov	d6, d22
	ldr	x0, [x19, #2656]
	mov	x23, x0
	b	#-1296
	mov	x22, x23
	ldr	x0, [x19, #2664]
	str	x0, [x19, #2568]
	ldr	x0, [x19, #2672]
	str	x0, [x19, #2576]
	ldr	x0, [x19, #2680]
	str	x0, [x19, #2584]
	ldr	x0, [x19, #2688]
	str	x0, [x19, #2592]
	fmov	d18, d2
	fmov	d19, d3
	fmov	d20, d4
	fmov	d21, d5
	ldr	x0, [x19, #2696]
	str	x0, [x19, #2600]
	b	#-880
	b	#-4944
	mov	x23, x4
	mov	x0, x5
	str	x0, [x19, #2472]
	mov	x0, x6
	str	x0, [x19, #2480]
	mov	x0, x7
	str	x0, [x19, #2488]
	mov	x0, x21
	str	x0, [x19, #2496]
	fmov	d6, d2
	fmov	d7, d3
	fmov	d16, d4
	fmov	d17, d5
	mov	x0, x22
	str	x0, [x19, #2504]
	b	#-3752
	mov	x0, x4
	str	x0, [x19, #2512]
	mov	x0, x5
	str	x0, [x19, #2520]
	mov	x0, x6
	str	x0, [x19, #2528]
	mov	x0, x7
	str	x0, [x19, #2536]
	mov	x0, x21
	str	x0, [x19, #2544]
	fmov	d7, d2
	fmov	d16, d3
	fmov	d17, d4
	fmov	d18, d5
	mov	x0, x22
	str	x0, [x19, #2552]
	fmov	d19, d6
	mov	x0, x23
	str	x0, [x19, #2560]
	b	#-3448
	b	#-296
	mov	x0, #52160                      // =0xcbc0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#532
	mov	x0, #52192                      // =0xcbe0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#516
	mov	x0, #52224                      // =0xcc00
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#500
	mov	x0, #52256                      // =0xcc20
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#484
	mov	x0, #52288                      // =0xcc40
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#468
	mov	x0, #52320                      // =0xcc60
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#452
	mov	x0, #52352                      // =0xcc80
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#436
	mov	x0, #52384                      // =0xcca0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#420
	mov	x0, #52416                      // =0xccc0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#404
	mov	x0, #52448                      // =0xcce0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#388
	mov	x0, #52480                      // =0xcd00
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#372
	mov	x0, #52512                      // =0xcd20
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#356
	mov	x0, #52544                      // =0xcd40
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#340
	mov	x0, #52576                      // =0xcd60
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#324
	mov	x0, #52608                      // =0xcd80
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#308
	mov	x0, #52640                      // =0xcda0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#292
	mov	x0, #52672                      // =0xcdc0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#276
	mov	x0, #52704                      // =0xcde0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#260
	mov	x0, #52736                      // =0xce00
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#244
	mov	x0, #52768                      // =0xce20
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#228
	mov	x0, #52800                      // =0xce40
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#212
	mov	x0, #52832                      // =0xce60
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#196
	mov	x0, #52864                      // =0xce80
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#180
	mov	x0, #52896                      // =0xcea0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#164
	mov	x0, #52928                      // =0xcec0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#148
	mov	x0, #52960                      // =0xcee0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#132
	mov	x0, #52992                      // =0xcf00
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#116
	mov	x0, #53024                      // =0xcf20
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#100
	mov	x0, #54464                      // =0xd4c0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#84
	mov	x0, #54496                      // =0xd4e0
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#68
	mov	x0, #54528                      // =0xd500
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#52
	mov	x0, #54560                      // =0xd520
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#36
	mov	x0, #54592                      // =0xd540
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#20
	mov	x0, #54624                      // =0xd560
	movk	x0, #11536, lsl #16
	movk	x0, #121, lsl #32
	b	#4
	ldr	x1, [x19, #2464]
	ldr	x2, [x1, #120]
	str	x22, [x2]
	str	x4, [x2, #8]
	str	x5, [x2, #16]
	str	x6, [x2, #24]
	str	x7, [x2, #32]
	str	x21, [x2, #40]
	str	x23, [x2, #48]
	str	d2, [x2, #56]
	str	d3, [x2, #64]
	str	d4, [x2, #72]
	str	d5, [x2, #80]
	str	d6, [x2, #88]
	str	d7, [x2, #96]
	str	d16, [x2, #104]
	str	d17, [x2, #112]
	str	d18, [x2, #120]
	str	d19, [x2, #128]
	str	d20, [x2, #136]
	str	d21, [x2, #144]
	str	d22, [x2, #152]
	str	d23, [x2, #160]
	str	x20, [x19, #920]
	mov	x1, x0
	ldr	x0, [x19, #2464]
	bl	#-2451436
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
