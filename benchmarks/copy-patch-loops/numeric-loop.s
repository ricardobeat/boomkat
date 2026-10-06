	ldr	d1, [x0, #8]
	ldr	d2, [x0, #16]
	mov	x9, #0                          // =0x0
	movk	x9, #0, lsl #16
	movk	x9, #0, lsl #32
	movk	x9, #16368, lsl #48
	fmov	d31, x9
	mov	x9, #0                          // =0x0
	movk	x9, #0, lsl #16
	movk	x9, #0, lsl #32
	movk	x9, #16392, lsl #48
	fmov	d6, x9
	mov	x9, #0                          // =0x0
	movk	x9, #0, lsl #16
	movk	x9, #0, lsl #32
	movk	x9, #16384, lsl #48
	fmov	d7, x9
	fmov	d5, d2
	fadd	d27, d5, d6
	fmul	d27, d27, d7
	fsub	d28, d27, d5
	fmov	d3, d28
	fadd	d1, d1, d3
	fadd	d2, d2, d31
	subs	w2, w2, #1
	b.ne	#-32
	str	d1, [x1, #8]
	str	d2, [x1, #16]
	str	d3, [x1, #24]
	str	d5, [x1, #40]
	str	d6, [x1, #48]
	str	d7, [x1, #56]
	ret
