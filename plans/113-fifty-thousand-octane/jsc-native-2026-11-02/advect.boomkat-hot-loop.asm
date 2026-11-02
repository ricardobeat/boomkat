  3792: 	orr	x0, xzr, #0x3ff0000000000000
  3796: 	fmov	d1, x0
  3800: 	fadd	d20, d19, d1
  3804: 	fmov	d0, d20
  3808: 	fcmp	d0, d0
  3812: 	b.vs	#3612
  3816: 	fmov	x1, d0
  3820: 	orr	x10, xzr, #0x8000000000000000
  3824: 	cmp	x1, x10
  3828: 	b.eq	#3596
  3832: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  3836: 	fmov	d1, x1
  3840: 	fcmp	d0, d1
  3844: 	b.mi	#3580
  3848: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  3852: 	fmov	d1, x1
  3856: 	fcmp	d0, d1
  3860: 	b.ge	#3564
  3864: 	fcvtzs	x4, d0
  3868: 	scvtf	d1, x4
  3872: 	fcmp	d0, d1
  3876: 	b.eq	#8
  3880: 	b	#3544
  3884: 	sxtw	x4, w4
  3888: 	mov	x1, x4
  3892: 	cmp	x1, x24
  3896: 	b.hs	#3528
  3900: 	lsl	x1, x1, #3
  3904: 	add	x2, x25, x1
  3908: 	ldr	x0, [x2]
  3912: 	lsr	x3, x0, #48
  3916: 	mov	x10, #65521                     // =0xfff1
  3920: 	cmp	x3, x10
  3924: 	b.hs	#3500
  3928: 	fmov	d2, x0
  3932: 	fmul	d3, d7, d2
  3936: 	ldr	x0, [x19, #2560]
  3940: 	scvtf	d2, x0
  3944: 	fsub	d4, d2, d3
  3948: 	mov	x1, x4
  3952: 	cmp	x1, x26
  3956: 	b.hs	#3484
  3960: 	lsl	x1, x1, #3
  3964: 	add	x2, x27, x1
  3968: 	ldr	x0, [x2]
  3972: 	lsr	x3, x0, #48
  3976: 	mov	x10, #65521                     // =0xfff1
  3980: 	cmp	x3, x10
  3984: 	b.hs	#3456
  3988: 	fmov	d2, x0
  3992: 	fmul	d3, d16, d2
  3996: 	ldr	x0, [x19, #2552]
  4000: 	scvtf	d2, x0
  4004: 	fsub	d5, d2, d3
  4008: 	fmov	d0, d4
  4012: 	orr	x3, xzr, #0x3fe0000000000000
  4016: 	fmov	d1, x3
  4020: 	fcmp	d0, d1
  4024: 	b.pl	#8
  4028: 	b	#8
  4032: 	b	#20
  4036: 	orr	x3, xzr, #0x3fe0000000000000
  4040: 	fmov	d0, x3
  4044: 	fmov	d2, d0
  4048: 	b	#36
  4052: 	fmov	d0, d4
  4056: 	fmov	d1, d17
  4060: 	fcmp	d0, d1
  4064: 	b.le	#8
  4068: 	b	#12
  4072: 	fmov	d2, d4
  4076: 	b	#8
  4080: 	fmov	d2, d17
  4084: 	fmov	d0, d2
  4088: 	fcmp	d0, d0
  4092: 	b.vs	#3364
  4096: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  4100: 	fmov	d1, x1
  4104: 	fcmp	d0, d1
  4108: 	b.mi	#3348
  4112: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  4116: 	fmov	d1, x1
  4120: 	fcmp	d0, d1
  4124: 	b.ge	#3332
  4128: 	fcvtzs	x5, d0
  4132: 	sxtw	x5, w5
  4136: 	orr	x6, x5, xzr
  4140: 	sxtw	x6, w6
  4144: 	adds	w5, w6, #1
  4148: 	b.vs	#3324
  4152: 	sxtw	x5, w5
  4156: 	fmov	d0, d5
  4160: 	orr	x3, xzr, #0x3fe0000000000000
  4164: 	fmov	d1, x3
  4168: 	fcmp	d0, d1
  4172: 	b.pl	#8
  4176: 	b	#8
  4180: 	b	#20
  4184: 	orr	x3, xzr, #0x3fe0000000000000
  4188: 	fmov	d0, x3
  4192: 	fmov	d3, d0
  4196: 	b	#36
  4200: 	fmov	d0, d5
  4204: 	fmov	d1, d18
  4208: 	fcmp	d0, d1
  4212: 	b.le	#8
  4216: 	b	#12
  4220: 	fmov	d3, d5
  4224: 	b	#8
  4228: 	fmov	d3, d18
  4232: 	fmov	d0, d3
  4236: 	fcmp	d0, d0
  4240: 	b.vs	#3248
  4244: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  4248: 	fmov	d1, x1
  4252: 	fcmp	d0, d1
  4256: 	b.mi	#3232
  4260: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  4264: 	fmov	d1, x1
  4268: 	fcmp	d0, d1
  4272: 	b.ge	#3216
  4276: 	fcvtzs	x7, d0
  4280: 	sxtw	x7, w7
  4284: 	orr	x21, x7, xzr
  4288: 	sxtw	x21, w21
  4292: 	adds	w7, w21, #1
  4296: 	b.vs	#3208
  4300: 	sxtw	x7, w7
  4304: 	mov	x0, x6
  4308: 	scvtf	d4, x0
  4312: 	fsub	d5, d2, d4
  4316: 	mov	x0, #1                          // =0x1
  4320: 	scvtf	d2, x0
  4324: 	fsub	d6, d2, d5
  4328: 	mov	x0, x21
  4332: 	scvtf	d2, x0
  4336: 	fsub	d19, d3, d2
  4340: 	mov	x0, #1                          // =0x1
  4344: 	scvtf	d3, x0
  4348: 	fsub	d21, d3, d19
  4352: 	ldr	x2, [x19, #2464]
  4356: 	ldr	x2, [x2]
  4360: 	ldr	x1, [x2, #16]
  4364: 	ldr	x0, [x1]
  4368: 	mov	x10, #62864                     // =0xf590
  4372: 	movk	x10, #1288, lsl #16
  4376: 	movk	x10, #1, lsl #32
  4380: 	cmp	x0, x10
  4384: 	b.ne	#3136
  4388: 	ldr	x0, [x1, #112]
  4392: 	lsr	x3, x0, #48
  4396: 	mov	x10, #65529                     // =0xfff9
  4400: 	cmp	x3, x10
  4404: 	b.ne	#3116
  4408: 	and	x0, x0, #0xffffffffffff
  4412: 	cbz	x0, #3108
  4416: 	ldr	x3, [x0, #56]
  4420: 	mov	x10, #62864                     // =0xf590
  4424: 	movk	x10, #1288, lsl #16
  4428: 	movk	x10, #1, lsl #32
  4432: 	cmp	x3, x10
  4436: 	b.ne	#3084
  4440: 	ldr	x1, [x0, #128]
  4444: 	cbz	x1, #3076
  4448: 	add	x1, x1, #32
  4452: 	ldrb	w3, [x1, #14]
  4456: 	cbz	x3, #12
  4460: 	ldr	x0, [x1]
  4464: 	b	#84
  4468: 	ldrb	w3, [x1, #13]
  4472: 	cbnz	x3, #3048
  4476: 	ldr	x2, [x1]
  4480: 	cbz	x2, #3040
  4484: 	ldr	w0, [x1, #8]
  4488: 	ldr	w3, [x2, #24]
  4492: 	cmp	x0, x3
  4496: 	b.hs	#3024
  4500: 	ldr	w3, [x2]
  4504: 	mov	x10, #32768                     // =0x8000
  4508: 	movk	x10, #4159, lsl #16
  4512: 	and	x3, x3, x10
  4516: 	cmp	x3, #16, lsl #12                // =65536
  4520: 	b.ne	#3000
  4524: 	lsl	x0, x0, #3
  4528: 	ldr	x3, [x2, #40]
  4532: 	cbnz	x3, #8
  4536: 	add	x3, x2, #56
  4540: 	add	x3, x3, x0
  4544: 	ldr	x0, [x3]
  4548: 	lsr	x3, x0, #48
  4552: 	mov	x10, #65528                     // =0xfff8
  4556: 	cmp	x3, x10
  4560: 	b.eq	#2960
  4564: 	mov	x10, #65523                     // =0xfff3
  4568: 	cmp	x3, x10
  4572: 	b.ne	#16
  4576: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  4580: 	cmp	x0, x10
  4584: 	b.ne	#2936
  4588: 	mov	x22, x0
  4592: 	mov	x0, x22
  4596: 	lsr	x3, x0, #48
  4600: 	mov	x10, #65521                     // =0xfff1
  4604: 	cmp	x3, x10
  4608: 	b.hi	#2928
  4612: 	mov	x10, #65521                     // =0xfff1
  4616: 	cmp	x3, x10
  4620: 	b.ne	#20
  4624: 	lsl	x0, x0, #16
  4628: 	asr	x0, x0, #16
  4632: 	scvtf	d3, x0
  4636: 	b	#8
  4640: 	fmov	d3, x0
  4644: 	fmul	d22, d2, d3
  4648: 	ldr	x2, [x19, #2464]
  4652: 	ldr	x2, [x2]
  4656: 	ldr	x1, [x2, #16]
  4660: 	ldr	x0, [x1]
  4664: 	mov	x10, #62864                     // =0xf590
  4668: 	movk	x10, #1288, lsl #16
  4672: 	movk	x10, #1, lsl #32
  4676: 	cmp	x0, x10
  4680: 	b.ne	#2872
  4684: 	ldr	x0, [x1, #112]
  4688: 	lsr	x3, x0, #48
  4692: 	mov	x10, #65529                     // =0xfff9
  4696: 	cmp	x3, x10
  4700: 	b.ne	#2852
  4704: 	and	x0, x0, #0xffffffffffff
  4708: 	cbz	x0, #2844
  4712: 	ldr	x3, [x0, #56]
  4716: 	mov	x10, #62864                     // =0xf590
  4720: 	movk	x10, #1288, lsl #16
  4724: 	movk	x10, #1, lsl #32
  4728: 	cmp	x3, x10
  4732: 	b.ne	#2820
  4736: 	ldr	x1, [x0, #128]
  4740: 	cbz	x1, #2812
  4744: 	add	x1, x1, #32
  4748: 	ldrb	w3, [x1, #14]
  4752: 	cbz	x3, #12
  4756: 	ldr	x0, [x1]
  4760: 	b	#84
  4764: 	ldrb	w3, [x1, #13]
  4768: 	cbnz	x3, #2784
  4772: 	ldr	x2, [x1]
  4776: 	cbz	x2, #2776
  4780: 	ldr	w0, [x1, #8]
  4784: 	ldr	w3, [x2, #24]
  4788: 	cmp	x0, x3
  4792: 	b.hs	#2760
  4796: 	ldr	w3, [x2]
  4800: 	mov	x10, #32768                     // =0x8000
  4804: 	movk	x10, #4159, lsl #16
  4808: 	and	x3, x3, x10
  4812: 	cmp	x3, #16, lsl #12                // =65536
  4816: 	b.ne	#2736
  4820: 	lsl	x0, x0, #3
  4824: 	ldr	x3, [x2, #40]
  4828: 	cbnz	x3, #8
  4832: 	add	x3, x2, #56
  4836: 	add	x3, x3, x0
  4840: 	ldr	x0, [x3]
  4844: 	lsr	x3, x0, #48
  4848: 	mov	x10, #65528                     // =0xfff8
  4852: 	cmp	x3, x10
  4856: 	b.eq	#2696
  4860: 	mov	x10, #65523                     // =0xfff3
  4864: 	cmp	x3, x10
  4868: 	b.ne	#16
  4872: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  4876: 	cmp	x0, x10
  4880: 	b.ne	#2672
  4884: 	mov	x21, x0
  4888: 	mov	x0, x7
  4892: 	scvtf	d2, x0
  4896: 	mov	x0, x21
  4900: 	lsr	x3, x0, #48
  4904: 	mov	x10, #65521                     // =0xfff1
  4908: 	cmp	x3, x10
  4912: 	b.hi	#2656
  4916: 	mov	x10, #65521                     // =0xfff1
  4920: 	cmp	x3, x10
  4924: 	b.ne	#20
  4928: 	lsl	x0, x0, #16
  4932: 	asr	x0, x0, #16
  4936: 	scvtf	d3, x0
  4940: 	b	#8
  4944: 	fmov	d3, x0
  4948: 	fmul	d23, d2, d3
  4952: 	fadd	d2, d4, d22
  4956: 	fmov	d0, d2
  4960: 	fcmp	d0, d0
  4964: 	b.vs	#2620
  4968: 	fmov	x1, d0
  4972: 	orr	x10, xzr, #0x8000000000000000
  4976: 	cmp	x1, x10
  4980: 	b.eq	#2604
  4984: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  4988: 	fmov	d1, x1
  4992: 	fcmp	d0, d1
  4996: 	b.mi	#2588
  5000: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5004: 	fmov	d1, x1
  5008: 	fcmp	d0, d1
  5012: 	b.ge	#2572
  5016: 	fcvtzs	x7, d0
  5020: 	scvtf	d1, x7
  5024: 	fcmp	d0, d1
  5028: 	b.eq	#8
  5032: 	b	#2552
  5036: 	sxtw	x7, w7
  5040: 	mov	x1, x7
  5044: 	ldr	x10, [x19, #608]
  5048: 	cmp	x1, x10
  5052: 	b.hs	#2532
  5056: 	lsl	x1, x1, #3
  5060: 	ldr	x2, [x19, #600]
  5064: 	add	x2, x2, x1
  5068: 	ldr	x0, [x2]
  5072: 	lsr	x3, x0, #48
  5076: 	mov	x10, #65521                     // =0xfff1
  5080: 	cmp	x3, x10
  5084: 	b.hs	#2500
  5088: 	fmov	d3, x0
  5092: 	fmul	d2, d21, d3
  5096: 	fadd	d3, d4, d23
  5100: 	fmov	d0, d3
  5104: 	fcmp	d0, d0
  5108: 	b.vs	#2492
  5112: 	fmov	x1, d0
  5116: 	orr	x10, xzr, #0x8000000000000000
  5120: 	cmp	x1, x10
  5124: 	b.eq	#2476
  5128: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  5132: 	fmov	d1, x1
  5136: 	fcmp	d0, d1
  5140: 	b.mi	#2460
  5144: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5148: 	fmov	d1, x1
  5152: 	fcmp	d0, d1
  5156: 	b.ge	#2444
  5160: 	fcvtzs	x6, d0
  5164: 	scvtf	d1, x6
  5168: 	fcmp	d0, d1
  5172: 	b.eq	#8
  5176: 	b	#2424
  5180: 	sxtw	x6, w6
  5184: 	mov	x1, x6
  5188: 	ldr	x10, [x19, #608]
  5192: 	cmp	x1, x10
  5196: 	b.hs	#2404
  5200: 	lsl	x1, x1, #3
  5204: 	ldr	x2, [x19, #600]
  5208: 	add	x2, x2, x1
  5212: 	ldr	x0, [x2]
  5216: 	lsr	x3, x0, #48
  5220: 	mov	x10, #65521                     // =0xfff1
  5224: 	cmp	x3, x10
  5228: 	b.hs	#2372
  5232: 	fmov	d4, x0
  5236: 	fmul	d3, d19, d4
  5240: 	fadd	d4, d2, d3
  5244: 	fmul	d2, d6, d4
  5248: 	mov	x0, x5
  5252: 	scvtf	d3, x0
  5256: 	fadd	d4, d3, d22
  5260: 	fmov	d0, d4
  5264: 	fcmp	d0, d0
  5268: 	b.vs	#2348
  5272: 	fmov	x1, d0
  5276: 	orr	x10, xzr, #0x8000000000000000
  5280: 	cmp	x1, x10
  5284: 	b.eq	#2332
  5288: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  5292: 	fmov	d1, x1
  5296: 	fcmp	d0, d1
  5300: 	b.mi	#2316
  5304: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5308: 	fmov	d1, x1
  5312: 	fcmp	d0, d1
  5316: 	b.ge	#2300
  5320: 	fcvtzs	x6, d0
  5324: 	scvtf	d1, x6
  5328: 	fcmp	d0, d1
  5332: 	b.eq	#8
  5336: 	b	#2280
  5340: 	sxtw	x6, w6
  5344: 	mov	x1, x6
  5348: 	ldr	x10, [x19, #608]
  5352: 	cmp	x1, x10
  5356: 	b.hs	#2260
  5360: 	lsl	x1, x1, #3
  5364: 	ldr	x2, [x19, #600]
  5368: 	add	x2, x2, x1
  5372: 	ldr	x0, [x2]
  5376: 	lsr	x3, x0, #48
  5380: 	mov	x10, #65521                     // =0xfff1
  5384: 	cmp	x3, x10
  5388: 	b.hs	#2228
  5392: 	fmov	d6, x0
  5396: 	fmul	d4, d21, d6
  5400: 	fadd	d6, d3, d23
  5404: 	fmov	d0, d6
  5408: 	fcmp	d0, d0
  5412: 	b.vs	#2220
  5416: 	fmov	x1, d0
  5420: 	orr	x10, xzr, #0x8000000000000000
  5424: 	cmp	x1, x10
  5428: 	b.eq	#2204
  5432: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  5436: 	fmov	d1, x1
  5440: 	fcmp	d0, d1
  5444: 	b.mi	#2188
  5448: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5452: 	fmov	d1, x1
  5456: 	fcmp	d0, d1
  5460: 	b.ge	#2172
  5464: 	fcvtzs	x5, d0
  5468: 	scvtf	d1, x5
  5472: 	fcmp	d0, d1
  5476: 	b.eq	#8
  5480: 	b	#2152
  5484: 	sxtw	x5, w5
  5488: 	mov	x1, x5
  5492: 	ldr	x10, [x19, #608]
  5496: 	cmp	x1, x10
  5500: 	b.hs	#2132
  5504: 	lsl	x1, x1, #3
  5508: 	ldr	x2, [x19, #600]
  5512: 	add	x2, x2, x1
  5516: 	ldr	x0, [x2]
  5520: 	lsr	x3, x0, #48
  5524: 	mov	x10, #65521                     // =0xfff1
  5528: 	cmp	x3, x10
  5532: 	b.hs	#2100
  5536: 	fmov	d3, x0
  5540: 	fmul	d6, d19, d3
  5544: 	fadd	d3, d4, d6
  5548: 	fmul	d4, d5, d3
  5552: 	fadd	d3, d2, d4
  5556: 	fmov	x5, d3
  5560: 	lsr	x3, x5, #48
  5564: 	mov	x10, #65521                     // =0xfff1
  5568: 	cmp	x3, x10
  5572: 	b.lo	#8
  5576: 	orr	x5, xzr, #0x7ff8000000000000
  5580: 	mov	x1, x4
  5584: 	ldr	x10, [x19, #640]
  5588: 	cmp	x1, x10
  5592: 	b.hs	#2056
  5596: 	lsl	x1, x1, #3
  5600: 	ldr	x2, [x19, #632]
  5604: 	add	x2, x2, x1
  5608: 	ldr	x0, [x2]
  5612: 	lsr	x3, x0, #48
  5616: 	mov	x10, #65521                     // =0xfff1
  5620: 	cmp	x3, x10
  5624: 	b.hi	#2024
  5628: 	mov	x0, x5
  5632: 	str	x0, [x2]
  5636: 	ldr	x0, [x19, #2560]
  5640: 	adds	w0, w0, #1
  5644: 	b.vs	#2020
  5648: 	sxtw	x0, w0
  5652: 	str	x0, [x19, #2960]
  5656: 	ldr	x0, [x19, #2512]
  5660: 	mov	x4, x0
  5664: 	ldr	x0, [x19, #2520]
  5668: 	mov	x5, x0
  5672: 	ldr	x0, [x19, #2528]
  5676: 	mov	x6, x0
  5680: 	ldr	x0, [x19, #2536]
  5684: 	mov	x7, x0
  5688: 	ldr	x0, [x19, #2544]
  5692: 	mov	x21, x0
  5696: 	fmov	d2, d7
  5700: 	fmov	d3, d16
  5704: 	fmov	d4, d17
  5708: 	fmov	d5, d18
  5712: 	ldr	x0, [x19, #2552]
  5716: 	mov	x22, x0
  5720: 	fmov	d6, d20
  5724: 	ldr	x0, [x19, #2960]
  5728: 	mov	x23, x0
  5732: 	ldr	x2, [x19, #2464]
  5736: 	ldr	x2, [x2]
  5740: 	ldr	x1, [x2, #16]
  5744: 	ldr	x0, [x1]
  5748: 	mov	x10, #62864                     // =0xf590
  5752: 	movk	x10, #1288, lsl #16
  5756: 	movk	x10, #1, lsl #32
  5760: 	cmp	x0, x10
  5764: 	b.ne	#1916
  5768: 	ldr	x0, [x1, #112]
  5772: 	lsr	x3, x0, #48
  5776: 	mov	x10, #65529                     // =0xfff9
  5780: 	cmp	x3, x10
  5784: 	b.ne	#1896
  5788: 	and	x0, x0, #0xffffffffffff
  5792: 	cbz	x0, #1888
  5796: 	ldr	x3, [x0, #56]
  5800: 	mov	x10, #62864                     // =0xf590
  5804: 	movk	x10, #1288, lsl #16
  5808: 	movk	x10, #1, lsl #32
  5812: 	cmp	x3, x10
  5816: 	b.ne	#1864
  5820: 	ldr	x1, [x0, #128]
  5824: 	cbz	x1, #1856
  5828: 	ldrb	w3, [x1, #14]
  5832: 	cbz	x3, #12
  5836: 	ldr	x0, [x1]
  5840: 	b	#84
  5844: 	ldrb	w3, [x1, #13]
  5848: 	cbnz	x3, #1832
  5852: 	ldr	x2, [x1]
  5856: 	cbz	x2, #1824
  5860: 	ldr	w0, [x1, #8]
  5864: 	ldr	w3, [x2, #24]
  5868: 	cmp	x0, x3
  5872: 	b.hs	#1808
  5876: 	ldr	w3, [x2]
  5880: 	mov	x10, #32768                     // =0x8000
  5884: 	movk	x10, #4159, lsl #16
  5888: 	and	x3, x3, x10
  5892: 	cmp	x3, #16, lsl #12                // =65536
  5896: 	b.ne	#1784
  5900: 	lsl	x0, x0, #3
  5904: 	ldr	x3, [x2, #40]
  5908: 	cbnz	x3, #8
  5912: 	add	x3, x2, #56
  5916: 	add	x3, x3, x0
  5920: 	ldr	x0, [x3]
  5924: 	lsr	x3, x0, #48
  5928: 	mov	x10, #65528                     // =0xfff8
  5932: 	cmp	x3, x10
  5936: 	b.eq	#1744
  5940: 	mov	x10, #65523                     // =0xfff3
  5944: 	cmp	x3, x10
  5948: 	b.ne	#16
  5952: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  5956: 	cmp	x0, x10
  5960: 	b.ne	#1720
  5964: 	str	x0, [x19, #2968]
  5968: 	mov	x0, x23
  5972: 	scvtf	d7, x0
  5976: 	ldr	x0, [x19, #2968]
  5980: 	lsr	x3, x0, #48
  5984: 	mov	x10, #65521                     // =0xfff1
  5988: 	cmp	x3, x10
  5992: 	b.hi	#1704
  5996: 	mov	x10, #65521                     // =0xfff1
  6000: 	cmp	x3, x10
  6004: 	b.ne	#20
  6008: 	lsl	x0, x0, #16
  6012: 	asr	x0, x0, #16
  6016: 	scvtf	d16, x0
  6020: 	b	#8
  6024: 	fmov	d16, x0
  6028: 	fmov	d0, d7
  6032: 	fmov	d1, d16
  6036: 	fcmp	d0, d1
  6040: 	b.ls	#8
  6044: 	b	#96
  6048: 	cmp	x20, #1
  6052: 	b.ls	#1644
  6056: 	sub	x20, x20, #1
  6060: 	mov	x0, x4
  6064: 	str	x0, [x19, #2512]
  6068: 	mov	x0, x5
  6072: 	str	x0, [x19, #2520]
  6076: 	mov	x0, x6
  6080: 	str	x0, [x19, #2528]
  6084: 	mov	x0, x7
  6088: 	str	x0, [x19, #2536]
  6092: 	mov	x0, x21
  6096: 	str	x0, [x19, #2544]
  6100: 	fmov	d7, d2
  6104: 	fmov	d16, d3
  6108: 	fmov	d17, d4
  6112: 	fmov	d18, d5
  6116: 	mov	x0, x22
  6120: 	str	x0, [x19, #2552]
  6124: 	fmov	d19, d6
  6128: 	mov	x0, x23
  6132: 	str	x0, [x19, #2560]
  6136: 	b	#-2344
