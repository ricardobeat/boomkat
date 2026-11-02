  4388: 	ldr	x0, [x19, #2568]
  4392: 	adds	w0, w0, #1
  4396: 	b.vs	#3568
  4400: 	sxtw	x0, w0
  4404: 	str	x0, [x19, #2992]
  4408: 	ldr	x1, [x19, #2992]
  4412: 	cmp	x1, x24
  4416: 	b.hs	#3564
  4420: 	lsl	x1, x1, #3
  4424: 	add	x2, x25, x1
  4428: 	ldr	x0, [x2]
  4432: 	lsr	x3, x0, #48
  4436: 	mov	x10, #65521                     // =0xfff1
  4440: 	cmp	x3, x10
  4444: 	b.hs	#3536
  4448: 	fmov	d2, x0
  4452: 	fmul	d3, d6, d2
  4456: 	ldr	x0, [x19, #2576]
  4460: 	scvtf	d2, x0
  4464: 	fsub	d4, d2, d3
  4468: 	ldr	x1, [x19, #2992]
  4472: 	cmp	x1, x26
  4476: 	b.hs	#3520
  4480: 	lsl	x1, x1, #3
  4484: 	add	x2, x27, x1
  4488: 	ldr	x0, [x2]
  4492: 	lsr	x3, x0, #48
  4496: 	mov	x10, #65521                     // =0xfff1
  4500: 	cmp	x3, x10
  4504: 	b.hs	#3492
  4508: 	fmov	d2, x0
  4512: 	fmul	d3, d7, d2
  4516: 	ldr	x0, [x19, #2560]
  4520: 	scvtf	d2, x0
  4524: 	fsub	d5, d2, d3
  4528: 	fmov	d0, d4
  4532: 	orr	x3, xzr, #0x3fe0000000000000
  4536: 	fmov	d1, x3
  4540: 	fcmp	d0, d1
  4544: 	b.pl	#8
  4548: 	b	#8
  4552: 	b	#20
  4556: 	orr	x3, xzr, #0x3fe0000000000000
  4560: 	fmov	d0, x3
  4564: 	fmov	d2, d0
  4568: 	b	#36
  4572: 	fmov	d0, d4
  4576: 	fmov	d1, d16
  4580: 	fcmp	d0, d1
  4584: 	b.le	#8
  4588: 	b	#12
  4592: 	fmov	d2, d4
  4596: 	b	#8
  4600: 	fmov	d2, d16
  4604: 	fmov	d0, d2
  4608: 	fcmp	d0, d0
  4612: 	b.vs	#3400
  4616: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  4620: 	fmov	d1, x1
  4624: 	fcmp	d0, d1
  4628: 	b.mi	#3384
  4632: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  4636: 	fmov	d1, x1
  4640: 	fcmp	d0, d1
  4644: 	b.ge	#3368
  4648: 	fcvtzs	x4, d0
  4652: 	sxtw	x4, w4
  4656: 	orr	x5, x4, xzr
  4660: 	sxtw	x5, w5
  4664: 	adds	w4, w5, #1
  4668: 	b.vs	#3360
  4672: 	sxtw	x4, w4
  4676: 	fmov	d0, d5
  4680: 	orr	x3, xzr, #0x3fe0000000000000
  4684: 	fmov	d1, x3
  4688: 	fcmp	d0, d1
  4692: 	b.pl	#8
  4696: 	b	#8
  4700: 	b	#20
  4704: 	orr	x3, xzr, #0x3fe0000000000000
  4708: 	fmov	d0, x3
  4712: 	fmov	d3, d0
  4716: 	b	#36
  4720: 	fmov	d0, d5
  4724: 	fmov	d1, d17
  4728: 	fcmp	d0, d1
  4732: 	b.le	#8
  4736: 	b	#12
  4740: 	fmov	d3, d5
  4744: 	b	#8
  4748: 	fmov	d3, d17
  4752: 	fmov	d0, d3
  4756: 	fcmp	d0, d0
  4760: 	b.vs	#3284
  4764: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  4768: 	fmov	d1, x1
  4772: 	fcmp	d0, d1
  4776: 	b.mi	#3268
  4780: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  4784: 	fmov	d1, x1
  4788: 	fcmp	d0, d1
  4792: 	b.ge	#3252
  4796: 	fcvtzs	x6, d0
  4800: 	sxtw	x6, w6
  4804: 	orr	x7, x6, xzr
  4808: 	sxtw	x7, w7
  4812: 	adds	w6, w7, #1
  4816: 	b.vs	#3244
  4820: 	sxtw	x6, w6
  4824: 	mov	x0, x5
  4828: 	scvtf	d4, x0
  4832: 	fsub	d5, d2, d4
  4836: 	mov	x0, #1                          // =0x1
  4840: 	scvtf	d2, x0
  4844: 	fsub	d4, d2, d5
  4848: 	mov	x0, x7
  4852: 	scvtf	d2, x0
  4856: 	fsub	d18, d3, d2
  4860: 	mov	x0, #1                          // =0x1
  4864: 	scvtf	d2, x0
  4868: 	fsub	d3, d2, d18
  4872: 	ldr	x2, [x19, #2464]
  4876: 	ldr	x2, [x2]
  4880: 	ldr	x1, [x2, #16]
  4884: 	ldr	x0, [x1]
  4888: 	mov	x10, #47120                     // =0xb810
  4892: 	movk	x10, #271, lsl #16
  4896: 	movk	x10, #1, lsl #32
  4900: 	cmp	x0, x10
  4904: 	b.ne	#3172
  4908: 	ldr	x0, [x1, #112]
  4912: 	lsr	x3, x0, #48
  4916: 	mov	x10, #65529                     // =0xfff9
  4920: 	cmp	x3, x10
  4924: 	b.ne	#3152
  4928: 	and	x0, x0, #0xffffffffffff
  4932: 	cbz	x0, #3144
  4936: 	ldr	x3, [x0, #56]
  4940: 	mov	x10, #47120                     // =0xb810
  4944: 	movk	x10, #271, lsl #16
  4948: 	movk	x10, #1, lsl #32
  4952: 	cmp	x3, x10
  4956: 	b.ne	#3120
  4960: 	ldr	x1, [x0, #128]
  4964: 	cbz	x1, #3112
  4968: 	add	x1, x1, #32
  4972: 	ldrb	w3, [x1, #14]
  4976: 	cbz	x3, #12
  4980: 	ldr	x0, [x1]
  4984: 	b	#84
  4988: 	ldrb	w3, [x1, #13]
  4992: 	cbnz	x3, #3084
  4996: 	ldr	x2, [x1]
  5000: 	cbz	x2, #3076
  5004: 	ldr	w0, [x1, #8]
  5008: 	ldr	w3, [x2, #24]
  5012: 	cmp	x0, x3
  5016: 	b.hs	#3060
  5020: 	ldr	w3, [x2]
  5024: 	mov	x10, #32768                     // =0x8000
  5028: 	movk	x10, #4159, lsl #16
  5032: 	and	x3, x3, x10
  5036: 	cmp	x3, #16, lsl #12                // =65536
  5040: 	b.ne	#3036
  5044: 	lsl	x0, x0, #3
  5048: 	ldr	x3, [x2, #40]
  5052: 	cbnz	x3, #8
  5056: 	add	x3, x2, #56
  5060: 	add	x3, x3, x0
  5064: 	ldr	x0, [x3]
  5068: 	lsr	x3, x0, #48
  5072: 	mov	x10, #65528                     // =0xfff8
  5076: 	cmp	x3, x10
  5080: 	b.eq	#2996
  5084: 	mov	x10, #65523                     // =0xfff3
  5088: 	cmp	x3, x10
  5092: 	b.ne	#16
  5096: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  5100: 	cmp	x0, x10
  5104: 	b.ne	#2972
  5108: 	lsr	x3, x0, #48
  5112: 	mov	x10, #65521                     // =0xfff1
  5116: 	cmp	x3, x10
  5120: 	b.eq	#104
  5124: 	mov	x10, #65521                     // =0xfff1
  5128: 	cmp	x3, x10
  5132: 	b.hi	#2944
  5136: 	fmov	d0, x0
  5140: 	fcmp	d0, d0
  5144: 	b.vs	#2932
  5148: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  5152: 	fmov	d1, x1
  5156: 	fcmp	d0, d1
  5160: 	b.mi	#2916
  5164: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5168: 	fmov	d1, x1
  5172: 	fcmp	d0, d1
  5176: 	b.ge	#2900
  5180: 	lsl	x3, x0, #1
  5184: 	cbnz	x3, #12
  5188: 	cmp	x0, #0
  5192: 	b.lt	#2884
  5196: 	fcvtzs	x0, d0
  5200: 	scvtf	d1, x0
  5204: 	fcmp	d0, d1
  5208: 	cset	x9, ne
  5212: 	ccmp	x9, #0, #4, vc
  5216: 	b.ne	#2860
  5220: 	b	#28
  5224: 	sxtw	x3, w0
  5228: 	lsl	x1, x0, #16
  5232: 	asr	x1, x1, #16
  5236: 	cmp	x1, x3
  5240: 	b.ne	#2836
  5244: 	mov	x0, x1
  5248: 	mov	x21, x0
  5252: 	orr	x3, x7, x21
  5256: 	smull	x22, w7, w21
  5260: 	add	x30, xzr, x22, asr #31
  5264: 	cmp	x30, x22, asr #63
  5268: 	b.ne	#2824
  5272: 	cbnz	x22, #12
  5276: 	cmp	x3, #0
  5280: 	b.lt	#2812
  5284: 	sxtw	x22, w22
  5288: 	ldr	x2, [x19, #2464]
  5292: 	ldr	x2, [x2]
  5296: 	ldr	x1, [x2, #16]
  5300: 	ldr	x0, [x1]
  5304: 	mov	x10, #47120                     // =0xb810
  5308: 	movk	x10, #271, lsl #16
  5312: 	movk	x10, #1, lsl #32
  5316: 	cmp	x0, x10
  5320: 	b.ne	#2788
  5324: 	ldr	x0, [x1, #112]
  5328: 	lsr	x3, x0, #48
  5332: 	mov	x10, #65529                     // =0xfff9
  5336: 	cmp	x3, x10
  5340: 	b.ne	#2768
  5344: 	and	x0, x0, #0xffffffffffff
  5348: 	cbz	x0, #2760
  5352: 	ldr	x3, [x0, #56]
  5356: 	mov	x10, #47120                     // =0xb810
  5360: 	movk	x10, #271, lsl #16
  5364: 	movk	x10, #1, lsl #32
  5368: 	cmp	x3, x10
  5372: 	b.ne	#2736
  5376: 	ldr	x1, [x0, #128]
  5380: 	cbz	x1, #2728
  5384: 	add	x1, x1, #32
  5388: 	ldrb	w3, [x1, #14]
  5392: 	cbz	x3, #12
  5396: 	ldr	x0, [x1]
  5400: 	b	#84
  5404: 	ldrb	w3, [x1, #13]
  5408: 	cbnz	x3, #2700
  5412: 	ldr	x2, [x1]
  5416: 	cbz	x2, #2692
  5420: 	ldr	w0, [x1, #8]
  5424: 	ldr	w3, [x2, #24]
  5428: 	cmp	x0, x3
  5432: 	b.hs	#2676
  5436: 	ldr	w3, [x2]
  5440: 	mov	x10, #32768                     // =0x8000
  5444: 	movk	x10, #4159, lsl #16
  5448: 	and	x3, x3, x10
  5452: 	cmp	x3, #16, lsl #12                // =65536
  5456: 	b.ne	#2652
  5460: 	lsl	x0, x0, #3
  5464: 	ldr	x3, [x2, #40]
  5468: 	cbnz	x3, #8
  5472: 	add	x3, x2, #56
  5476: 	add	x3, x3, x0
  5480: 	ldr	x0, [x3]
  5484: 	lsr	x3, x0, #48
  5488: 	mov	x10, #65528                     // =0xfff8
  5492: 	cmp	x3, x10
  5496: 	b.eq	#2612
  5500: 	mov	x10, #65523                     // =0xfff3
  5504: 	cmp	x3, x10
  5508: 	b.ne	#16
  5512: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  5516: 	cmp	x0, x10
  5520: 	b.ne	#2588
  5524: 	lsr	x3, x0, #48
  5528: 	mov	x10, #65521                     // =0xfff1
  5532: 	cmp	x3, x10
  5536: 	b.eq	#104
  5540: 	mov	x10, #65521                     // =0xfff1
  5544: 	cmp	x3, x10
  5548: 	b.hi	#2560
  5552: 	fmov	d0, x0
  5556: 	fcmp	d0, d0
  5560: 	b.vs	#2548
  5564: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  5568: 	fmov	d1, x1
  5572: 	fcmp	d0, d1
  5576: 	b.mi	#2532
  5580: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  5584: 	fmov	d1, x1
  5588: 	fcmp	d0, d1
  5592: 	b.ge	#2516
  5596: 	lsl	x3, x0, #1
  5600: 	cbnz	x3, #12
  5604: 	cmp	x0, #0
  5608: 	b.lt	#2500
  5612: 	fcvtzs	x0, d0
  5616: 	scvtf	d1, x0
  5620: 	fcmp	d0, d1
  5624: 	cset	x9, ne
  5628: 	ccmp	x9, #0, #4, vc
  5632: 	b.ne	#2476
  5636: 	b	#28
  5640: 	sxtw	x3, w0
  5644: 	lsl	x1, x0, #16
  5648: 	asr	x1, x1, #16
  5652: 	cmp	x1, x3
  5656: 	b.ne	#2452
  5660: 	mov	x0, x1
  5664: 	mov	x7, x0
  5668: 	orr	x3, x6, x7
  5672: 	smull	x21, w6, w7
  5676: 	add	x30, xzr, x21, asr #31
  5680: 	cmp	x30, x21, asr #63
  5684: 	b.ne	#2440
  5688: 	cbnz	x21, #12
  5692: 	cmp	x3, #0
  5696: 	b.lt	#2428
  5700: 	sxtw	x21, w21
  5704: 	adds	w6, w5, w22
  5708: 	b.vs	#2432
  5712: 	sxtw	x6, w6
  5716: 	mov	x1, x6
  5720: 	ldr	x10, [x19, #608]
  5724: 	cmp	x1, x10
  5728: 	b.hs	#2428
  5732: 	lsl	x1, x1, #3
  5736: 	ldr	x2, [x19, #600]
  5740: 	add	x2, x2, x1
  5744: 	ldr	x0, [x2]
  5748: 	lsr	x3, x0, #48
  5752: 	mov	x10, #65521                     // =0xfff1
  5756: 	cmp	x3, x10
  5760: 	b.hs	#2396
  5764: 	fmov	d2, x0
  5768: 	fmul	d19, d3, d2
  5772: 	adds	w6, w5, w21
  5776: 	b.vs	#2396
  5780: 	sxtw	x6, w6
  5784: 	mov	x1, x6
  5788: 	ldr	x10, [x19, #608]
  5792: 	cmp	x1, x10
  5796: 	b.hs	#2392
  5800: 	lsl	x1, x1, #3
  5804: 	ldr	x2, [x19, #600]
  5808: 	add	x2, x2, x1
  5812: 	ldr	x0, [x2]
  5816: 	lsr	x3, x0, #48
  5820: 	mov	x10, #65521                     // =0xfff1
  5824: 	cmp	x3, x10
  5828: 	b.hs	#2360
  5832: 	fmov	d2, x0
  5836: 	fmul	d20, d18, d2
  5840: 	fadd	d2, d19, d20
  5844: 	fmul	d19, d4, d2
  5848: 	adds	w5, w4, w22
  5852: 	b.vs	#2352
  5856: 	sxtw	x5, w5
  5860: 	mov	x1, x5
  5864: 	ldr	x10, [x19, #608]
  5868: 	cmp	x1, x10
  5872: 	b.hs	#2348
  5876: 	lsl	x1, x1, #3
  5880: 	ldr	x2, [x19, #600]
  5884: 	add	x2, x2, x1
  5888: 	ldr	x0, [x2]
  5892: 	lsr	x3, x0, #48
  5896: 	mov	x10, #65521                     // =0xfff1
  5900: 	cmp	x3, x10
  5904: 	b.hs	#2316
  5908: 	fmov	d2, x0
  5912: 	fmul	d4, d3, d2
  5916: 	adds	w5, w4, w21
  5920: 	b.vs	#2316
  5924: 	sxtw	x5, w5
  5928: 	mov	x1, x5
  5932: 	ldr	x10, [x19, #608]
  5936: 	cmp	x1, x10
  5940: 	b.hs	#2312
  5944: 	lsl	x1, x1, #3
  5948: 	ldr	x2, [x19, #600]
  5952: 	add	x2, x2, x1
  5956: 	ldr	x0, [x2]
  5960: 	lsr	x3, x0, #48
  5964: 	mov	x10, #65521                     // =0xfff1
  5968: 	cmp	x3, x10
  5972: 	b.hs	#2280
  5976: 	fmov	d2, x0
  5980: 	fmul	d3, d18, d2
  5984: 	fadd	d2, d4, d3
  5988: 	fmul	d3, d5, d2
  5992: 	fadd	d2, d19, d3
  5996: 	fmov	x4, d2
  6000: 	lsr	x3, x4, #48
  6004: 	mov	x10, #65521                     // =0xfff1
  6008: 	cmp	x3, x10
  6012: 	b.lo	#8
  6016: 	orr	x4, xzr, #0x7ff8000000000000
  6020: 	ldr	x1, [x19, #2992]
  6024: 	ldr	x10, [x19, #640]
  6028: 	cmp	x1, x10
  6032: 	b.hs	#2236
  6036: 	lsl	x1, x1, #3
  6040: 	ldr	x2, [x19, #632]
  6044: 	add	x2, x2, x1
  6048: 	ldr	x0, [x2]
  6052: 	lsr	x3, x0, #48
  6056: 	mov	x10, #65521                     // =0xfff1
  6060: 	cmp	x3, x10
  6064: 	b.hi	#2204
  6068: 	mov	x0, x4
  6072: 	str	x0, [x2]
  6076: 	ldr	x0, [x19, #2576]
  6080: 	adds	w0, w0, #1
  6084: 	b.vs	#2200
  6088: 	sxtw	x0, w0
  6092: 	str	x0, [x19, #3000]
  6096: 	ldr	x0, [x19, #2520]
  6100: 	mov	x4, x0
  6104: 	ldr	x0, [x19, #2528]
  6108: 	mov	x5, x0
  6112: 	ldr	x0, [x19, #2536]
  6116: 	mov	x6, x0
  6120: 	ldr	x0, [x19, #2544]
  6124: 	mov	x7, x0
  6128: 	ldr	x0, [x19, #2552]
  6132: 	mov	x21, x0
  6136: 	fmov	d2, d6
  6140: 	fmov	d3, d7
  6144: 	fmov	d4, d16
  6148: 	fmov	d5, d17
  6152: 	ldr	x0, [x19, #2560]
  6156: 	mov	x22, x0
  6160: 	ldr	x0, [x19, #2992]
  6164: 	mov	x23, x0
  6168: 	ldr	x0, [x19, #3000]
  6172: 	str	x0, [x19, #2584]
  6176: 	ldr	x2, [x19, #2464]
  6180: 	ldr	x2, [x2]
  6184: 	ldr	x1, [x2, #16]
  6188: 	ldr	x0, [x1]
  6192: 	mov	x10, #47120                     // =0xb810
  6196: 	movk	x10, #271, lsl #16
  6200: 	movk	x10, #1, lsl #32
  6204: 	cmp	x0, x10
  6208: 	b.ne	#2092
  6212: 	ldr	x0, [x1, #112]
  6216: 	lsr	x3, x0, #48
  6220: 	mov	x10, #65529                     // =0xfff9
  6224: 	cmp	x3, x10
  6228: 	b.ne	#2072
  6232: 	and	x0, x0, #0xffffffffffff
  6236: 	cbz	x0, #2064
  6240: 	ldr	x3, [x0, #56]
  6244: 	mov	x10, #47120                     // =0xb810
  6248: 	movk	x10, #271, lsl #16
  6252: 	movk	x10, #1, lsl #32
  6256: 	cmp	x3, x10
  6260: 	b.ne	#2040
  6264: 	ldr	x1, [x0, #128]
  6268: 	cbz	x1, #2032
  6272: 	ldrb	w3, [x1, #14]
  6276: 	cbz	x3, #12
  6280: 	ldr	x0, [x1]
  6284: 	b	#84
  6288: 	ldrb	w3, [x1, #13]
  6292: 	cbnz	x3, #2008
  6296: 	ldr	x2, [x1]
  6300: 	cbz	x2, #2000
  6304: 	ldr	w0, [x1, #8]
  6308: 	ldr	w3, [x2, #24]
  6312: 	cmp	x0, x3
  6316: 	b.hs	#1984
  6320: 	ldr	w3, [x2]
  6324: 	mov	x10, #32768                     // =0x8000
  6328: 	movk	x10, #4159, lsl #16
  6332: 	and	x3, x3, x10
  6336: 	cmp	x3, #16, lsl #12                // =65536
  6340: 	b.ne	#1960
  6344: 	lsl	x0, x0, #3
  6348: 	ldr	x3, [x2, #40]
  6352: 	cbnz	x3, #8
  6356: 	add	x3, x2, #56
  6360: 	add	x3, x3, x0
  6364: 	ldr	x0, [x3]
  6368: 	lsr	x3, x0, #48
  6372: 	mov	x10, #65528                     // =0xfff8
  6376: 	cmp	x3, x10
  6380: 	b.eq	#1920
  6384: 	mov	x10, #65523                     // =0xfff3
  6388: 	cmp	x3, x10
  6392: 	b.ne	#16
  6396: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  6400: 	cmp	x0, x10
  6404: 	b.ne	#1896
  6408: 	lsr	x3, x0, #48
  6412: 	mov	x10, #65521                     // =0xfff1
  6416: 	cmp	x3, x10
  6420: 	b.eq	#104
  6424: 	mov	x10, #65521                     // =0xfff1
  6428: 	cmp	x3, x10
  6432: 	b.hi	#1868
  6436: 	fmov	d0, x0
  6440: 	fcmp	d0, d0
  6444: 	b.vs	#1856
  6448: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  6452: 	fmov	d1, x1
  6456: 	fcmp	d0, d1
  6460: 	b.mi	#1840
  6464: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  6468: 	fmov	d1, x1
  6472: 	fcmp	d0, d1
  6476: 	b.ge	#1824
  6480: 	lsl	x3, x0, #1
  6484: 	cbnz	x3, #12
  6488: 	cmp	x0, #0
  6492: 	b.lt	#1808
  6496: 	fcvtzs	x0, d0
  6500: 	scvtf	d1, x0
  6504: 	fcmp	d0, d1
  6508: 	cset	x9, ne
  6512: 	ccmp	x9, #0, #4, vc
  6516: 	b.ne	#1784
  6520: 	b	#28
  6524: 	sxtw	x3, w0
  6528: 	lsl	x1, x0, #16
  6532: 	asr	x1, x1, #16
  6536: 	cmp	x1, x3
  6540: 	b.ne	#1760
  6544: 	mov	x0, x1
  6548: 	str	x0, [x19, #3008]
  6552: 	ldr	x0, [x19, #2584]
  6556: 	ldr	x1, [x19, #3008]
  6560: 	cmp	x0, x1
  6564: 	b.le	#8
  6568: 	b	#100
  6572: 	cmp	x20, #1
  6576: 	b.ls	#1740
  6580: 	sub	x20, x20, #1
  6584: 	mov	x0, x4
  6588: 	str	x0, [x19, #2520]
  6592: 	mov	x0, x5
  6596: 	str	x0, [x19, #2528]
  6600: 	mov	x0, x6
  6604: 	str	x0, [x19, #2536]
  6608: 	mov	x0, x7
  6612: 	str	x0, [x19, #2544]
  6616: 	mov	x0, x21
  6620: 	str	x0, [x19, #2552]
  6624: 	fmov	d6, d2
  6628: 	fmov	d7, d3
  6632: 	fmov	d16, d4
  6636: 	fmov	d17, d5
  6640: 	mov	x0, x22
  6644: 	str	x0, [x19, #2560]
  6648: 	mov	x0, x23
  6652: 	str	x0, [x19, #2568]
  6656: 	ldr	x0, [x19, #2584]
  6660: 	str	x0, [x19, #2576]
  6664: 	b	#-2276
