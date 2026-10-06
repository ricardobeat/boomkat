	ldr	d0, [x0]
	ldr	d1, [x0, #8]
	fadd	d2, d0, d1
	ldr	d3, [x0, #16]
	fmul	d4, d2, d3
	fsub	d5, d4, d0
	str	d5, [x1]
	ret
