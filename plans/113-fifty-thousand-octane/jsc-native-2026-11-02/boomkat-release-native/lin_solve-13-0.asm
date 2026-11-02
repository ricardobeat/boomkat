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
	b.ne	#664
	ldr	x24, [x19, #544]
	ldr	x25, [x19, #536]
	ldr	x0, [x19, #8]
	ldr	x10, [x19, #560]
	cmp	x0, x10
	b.ne	#640
	ldr	x26, [x19, #576]
	ldr	x27, [x19, #568]
	ldr	x0, [x19, #48]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#600
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#588
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#572
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#556
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#540
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#516
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#492
	mov	x0, x1
	mov	x4, x0
	ldr	x0, [x19, #56]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.eq	#104
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#452
	fmov	d0, x0
	fcmp	d0, d0
	b.vs	#440
	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.mi	#424
	mov	x1, #4746794007248502784        // =0x41e0000000000000
	fmov	d1, x1
	fcmp	d0, d1
	b.ge	#408
	lsl	x3, x0, #1
	cbnz	x3, #12
	cmp	x0, #0
	b.lt	#392
	fcvtzs	x0, d0
	scvtf	d1, x0
	fcmp	d0, d1
	cset	x9, ne
	ccmp	x9, #0, #4, vc
	b.ne	#368
	b	#28
	sxtw	x3, w0
	lsl	x1, x0, #16
	asr	x1, x1, #16
	cmp	x1, x3
	b.ne	#344
	mov	x0, x1
	mov	x5, x0
	mov	x1, x4
	cmp	x1, x24
	b.hs	#372
	lsl	x1, x1, #3
	add	x2, x25, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hs	#344
	fmov	d2, x0
	fmov	x6, d2
	lsr	x3, x6, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x6, xzr, #0x7ff8000000000000
	mov	x1, x4
	cmp	x1, x26
	b.hs	#416
	lsl	x1, x1, #3
	add	x2, x27, x1
	ldr	x0, [x2]
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#388
	mov	x0, x6
	str	x0, [x2]
	adds	w6, w4, #1
	b.vs	#516
	sxtw	x6, w6
	adds	w7, w5, #1
	b.vs	#648
	sxtw	x7, w7
	ldr	x0, [x19, #784]
	mov	x21, x0
	mov	x0, x7
	scvtf	d3, x0
	mov	x0, x21
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.hi	#752
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.ne	#20
	lsl	x0, x0, #16
	asr	x0, x0, #16
	scvtf	d4, x0
	b	#8
	fmov	d4, x0
	cmp	x20, #1
	b.ls	#844
	sub	x20, x20, #1
	mov	x4, x6
	mov	x5, x7
	fmov	d0, d3
	fmov	d1, d4
	fcmp	d0, d1
	b.mi	#-240
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x9, #192                        // =0xc0
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
	mov	x9, #0                          // =0x0
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #13                         // =0xd
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	mov	x9, #192                        // =0xc0
	movk	x9, #1, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #14                         // =0xe
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #144]
	mov	x9, #192                        // =0xc0
	movk	x9, #5, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #15                         // =0xf
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #144]
	mov	x9, #192                        // =0xc0
	movk	x9, #5, lsl #16
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
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x5
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x4
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #128]
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #144]
	mov	x9, #192                        // =0xc0
	movk	x9, #5, lsl #16
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
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x21
	str	x0, [x19, #128]
	fmov	d0, d2
	fmov	x0, d0
	lsr	x3, x0, #48
	mov	x10, #65521                     // =0xfff1
	cmp	x3, x10
	b.lo	#8
	orr	x0, xzr, #0x7ff8000000000000
	str	x0, [x19, #144]
	mov	x9, #192                        // =0xc0
	movk	x9, #5, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #19                         // =0x13
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
	mov	x0, x6
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #48]
	mov	x0, x7
	and	x0, x0, #0xffffffffffff
	mov	x10, #-4222124650659840         // =0xfff1000000000000
	orr	x0, x0, x10
	str	x0, [x19, #56]
	mov	x0, x21
	str	x0, [x19, #128]
	mov	x9, #192                        // =0xc0
	movk	x9, #1, lsl #16
	str	x9, [x19, #912]
	str	x20, [x19, #920]
	mov	x0, #19                         // =0x13
	ldp	x29, x30, [sp]
	ldp	x19, x20, [sp, #80]
	ldp	x21, x22, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #32]
	ldr	x27, [sp, #24]
	add	sp, sp, #96
	ret
