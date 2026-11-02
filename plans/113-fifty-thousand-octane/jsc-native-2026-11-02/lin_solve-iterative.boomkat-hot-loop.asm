  7044: 	fmov	d0, d17
  7048: 	fcmp	d0, d0
  7052: 	b.vs	#3688
  7056: 	fmov	x1, d0
  7060: 	orr	x10, xzr, #0x8000000000000000
  7064: 	cmp	x1, x10
  7068: 	b.eq	#3672
  7072: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  7076: 	fmov	d1, x1
  7080: 	fcmp	d0, d1
  7084: 	b.mi	#3656
  7088: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  7092: 	fmov	d1, x1
  7096: 	fcmp	d0, d1
  7100: 	b.ge	#3640
  7104: 	fcvtzs	x4, d0
  7108: 	scvtf	d1, x4
  7112: 	fcmp	d0, d1
  7116: 	b.eq	#8
  7120: 	b	#3620
  7124: 	sxtw	x4, w4
  7128: 	mov	x1, x4
  7132: 	cmp	x1, x24
  7136: 	b.hs	#3604
  7140: 	lsl	x1, x1, #3
  7144: 	add	x2, x25, x1
  7148: 	ldr	x0, [x2]
  7152: 	lsr	x3, x0, #48
  7156: 	mov	x10, #65521                     // =0xfff1
  7160: 	cmp	x3, x10
  7164: 	b.hs	#3576
  7168: 	fmov	d2, x0
  7172: 	orr	x0, xzr, #0x3ff0000000000000
  7176: 	fmov	d1, x0
  7180: 	fadd	d22, d17, d1
  7184: 	fmov	d0, d22
  7188: 	fcmp	d0, d0
  7192: 	b.vs	#3564
  7196: 	fmov	x1, d0
  7200: 	orr	x10, xzr, #0x8000000000000000
  7204: 	cmp	x1, x10
  7208: 	b.eq	#3548
  7212: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  7216: 	fmov	d1, x1
  7220: 	fcmp	d0, d1
  7224: 	b.mi	#3532
  7228: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  7232: 	fmov	d1, x1
  7236: 	fcmp	d0, d1
  7240: 	b.ge	#3516
  7244: 	fcvtzs	x5, d0
  7248: 	scvtf	d1, x5
  7252: 	fcmp	d0, d1
  7256: 	b.eq	#8
  7260: 	b	#3496
  7264: 	sxtw	x5, w5
  7268: 	mov	x1, x5
  7272: 	cmp	x1, x26
  7276: 	b.hs	#3480
  7280: 	lsl	x1, x1, #3
  7284: 	add	x2, x27, x1
  7288: 	ldr	x6, [x2]
  7292: 	lsr	x3, x6, #48
  7296: 	mov	x10, #65521                     // =0xfff1
  7300: 	cmp	x3, x10
  7304: 	b.hi	#3452
  7308: 	mov	x0, x6
  7312: 	lsr	x3, x0, #48
  7316: 	mov	x10, #65521                     // =0xfff1
  7320: 	cmp	x3, x10
  7324: 	b.hi	#3448
  7328: 	mov	x10, #65521                     // =0xfff1
  7332: 	cmp	x3, x10
  7336: 	b.ne	#20
  7340: 	lsl	x0, x0, #16
  7344: 	asr	x0, x0, #16
  7348: 	scvtf	d3, x0
  7352: 	b	#8
  7356: 	fmov	d3, x0
  7360: 	fadd	d4, d21, d3
  7364: 	orr	x0, xzr, #0x3ff0000000000000
  7368: 	fmov	d1, x0
  7372: 	fadd	d21, d19, d1
  7376: 	fmov	d0, d21
  7380: 	fcmp	d0, d0
  7384: 	b.vs	#3404
  7388: 	fmov	x1, d0
  7392: 	orr	x10, xzr, #0x8000000000000000
  7396: 	cmp	x1, x10
  7400: 	b.eq	#3388
  7404: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  7408: 	fmov	d1, x1
  7412: 	fcmp	d0, d1
  7416: 	b.mi	#3372
  7420: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  7424: 	fmov	d1, x1
  7428: 	fcmp	d0, d1
  7432: 	b.ge	#3356
  7436: 	fcvtzs	x5, d0
  7440: 	scvtf	d1, x5
  7444: 	fcmp	d0, d1
  7448: 	b.eq	#8
  7452: 	b	#3336
  7456: 	sxtw	x5, w5
  7460: 	mov	x1, x5
  7464: 	cmp	x1, x26
  7468: 	b.hs	#3320
  7472: 	lsl	x1, x1, #3
  7476: 	add	x2, x27, x1
  7480: 	ldr	x6, [x2]
  7484: 	lsr	x3, x6, #48
  7488: 	mov	x10, #65521                     // =0xfff1
  7492: 	cmp	x3, x10
  7496: 	b.hi	#3292
  7500: 	mov	x0, x6
  7504: 	lsr	x3, x0, #48
  7508: 	mov	x10, #65521                     // =0xfff1
  7512: 	cmp	x3, x10
  7516: 	b.hi	#3288
  7520: 	mov	x10, #65521                     // =0xfff1
  7524: 	cmp	x3, x10
  7528: 	b.ne	#20
  7532: 	lsl	x0, x0, #16
  7536: 	asr	x0, x0, #16
  7540: 	scvtf	d3, x0
  7544: 	b	#8
  7548: 	fmov	d3, x0
  7552: 	fadd	d5, d4, d3
  7556: 	orr	x0, xzr, #0x3ff0000000000000
  7560: 	fmov	d1, x0
  7564: 	fadd	d19, d20, d1
  7568: 	fmov	d0, d19
  7572: 	fcmp	d0, d0
  7576: 	b.vs	#3244
  7580: 	fmov	x1, d0
  7584: 	orr	x10, xzr, #0x8000000000000000
  7588: 	cmp	x1, x10
  7592: 	b.eq	#3228
  7596: 	mov	x1, #-4476578029606273024       // =0xc1e0000000000000
  7600: 	fmov	d1, x1
  7604: 	fcmp	d0, d1
  7608: 	b.mi	#3212
  7612: 	mov	x1, #4746794007248502784        // =0x41e0000000000000
  7616: 	fmov	d1, x1
  7620: 	fcmp	d0, d1
  7624: 	b.ge	#3196
  7628: 	fcvtzs	x5, d0
  7632: 	scvtf	d1, x5
  7636: 	fcmp	d0, d1
  7640: 	b.eq	#8
  7644: 	b	#3176
  7648: 	sxtw	x5, w5
  7652: 	mov	x1, x5
  7656: 	cmp	x1, x26
  7660: 	b.hs	#3160
  7664: 	lsl	x1, x1, #3
  7668: 	add	x2, x27, x1
  7672: 	ldr	x6, [x2]
  7676: 	lsr	x3, x6, #48
  7680: 	mov	x10, #65521                     // =0xfff1
  7684: 	cmp	x3, x10
  7688: 	b.hi	#3132
  7692: 	mov	x0, x6
  7696: 	lsr	x3, x0, #48
  7700: 	mov	x10, #65521                     // =0xfff1
  7704: 	cmp	x3, x10
  7708: 	b.hi	#3128
  7712: 	mov	x10, #65521                     // =0xfff1
  7716: 	cmp	x3, x10
  7720: 	b.ne	#20
  7724: 	lsl	x0, x0, #16
  7728: 	asr	x0, x0, #16
  7732: 	scvtf	d3, x0
  7736: 	b	#8
  7740: 	fmov	d3, x0
  7744: 	fadd	d4, d5, d3
  7748: 	fmul	d3, d16, d4
  7752: 	fadd	d4, d2, d3
  7756: 	fmul	d20, d4, d18
  7760: 	fmov	x5, d20
  7764: 	lsr	x3, x5, #48
  7768: 	mov	x10, #65521                     // =0xfff1
  7772: 	cmp	x3, x10
  7776: 	b.lo	#8
  7780: 	orr	x5, xzr, #0x7ff8000000000000
  7784: 	mov	x1, x4
  7788: 	cmp	x1, x26
  7792: 	b.hs	#3060
  7796: 	lsl	x1, x1, #3
  7800: 	add	x2, x27, x1
  7804: 	ldr	x0, [x2]
  7808: 	lsr	x3, x0, #48
  7812: 	mov	x10, #65521                     // =0xfff1
  7816: 	cmp	x3, x10
  7820: 	b.hi	#3032
  7824: 	mov	x0, x5
  7828: 	str	x0, [x2]
  7832: 	ldr	x0, [x19, #2584]
  7836: 	adds	w0, w0, #1
  7840: 	b.vs	#3028
  7844: 	sxtw	x0, w0
  7848: 	str	x0, [x19, #2944]
  7852: 	mov	x4, x23
  7856: 	ldr	x0, [x19, #2560]
  7860: 	mov	x5, x0
  7864: 	ldr	x0, [x19, #2568]
  7868: 	mov	x6, x0
  7872: 	fmov	d2, d16
  7876: 	ldr	x0, [x19, #2576]
  7880: 	mov	x7, x0
  7884: 	fmov	d3, d22
  7888: 	ldr	x0, [x19, #2944]
  7892: 	mov	x21, x0
  7896: 	fmov	d4, d18
  7900: 	ldr	x0, [x19, #2592]
  7904: 	mov	x22, x0
  7908: 	fmov	d5, d21
  7912: 	fmov	d6, d19
  7916: 	fmov	d7, d20
  7920: 	ldr	x2, [x19, #2464]
  7924: 	ldr	x2, [x2]
  7928: 	ldr	x1, [x2, #16]
  7932: 	ldr	x0, [x1]
  7936: 	mov	x10, #54352                     // =0xd450
  7940: 	movk	x10, #1288, lsl #16
  7944: 	movk	x10, #1, lsl #32
  7948: 	cmp	x0, x10
  7952: 	b.ne	#2932
  7956: 	ldr	x0, [x1, #112]
  7960: 	lsr	x3, x0, #48
  7964: 	mov	x10, #65529                     // =0xfff9
  7968: 	cmp	x3, x10
  7972: 	b.ne	#2912
  7976: 	and	x0, x0, #0xffffffffffff
  7980: 	cbz	x0, #2904
  7984: 	ldr	x3, [x0, #56]
  7988: 	mov	x10, #54352                     // =0xd450
  7992: 	movk	x10, #1288, lsl #16
  7996: 	movk	x10, #1, lsl #32
  8000: 	cmp	x3, x10
  8004: 	b.ne	#2880
  8008: 	ldr	x1, [x0, #128]
  8012: 	cbz	x1, #2872
  8016: 	add	x1, x1, #16
  8020: 	ldrb	w3, [x1, #14]
  8024: 	cbz	x3, #12
  8028: 	ldr	x0, [x1]
  8032: 	b	#84
  8036: 	ldrb	w3, [x1, #13]
  8040: 	cbnz	x3, #2844
  8044: 	ldr	x2, [x1]
  8048: 	cbz	x2, #2836
  8052: 	ldr	w0, [x1, #8]
  8056: 	ldr	w3, [x2, #24]
  8060: 	cmp	x0, x3
  8064: 	b.hs	#2820
  8068: 	ldr	w3, [x2]
  8072: 	mov	x10, #32768                     // =0x8000
  8076: 	movk	x10, #4159, lsl #16
  8080: 	and	x3, x3, x10
  8084: 	cmp	x3, #16, lsl #12                // =65536
  8088: 	b.ne	#2796
  8092: 	lsl	x0, x0, #3
  8096: 	ldr	x3, [x2, #40]
  8100: 	cbnz	x3, #8
  8104: 	add	x3, x2, #56
  8108: 	add	x3, x3, x0
  8112: 	ldr	x0, [x3]
  8116: 	lsr	x3, x0, #48
  8120: 	mov	x10, #65528                     // =0xfff8
  8124: 	cmp	x3, x10
  8128: 	b.eq	#2756
  8132: 	mov	x10, #65523                     // =0xfff3
  8136: 	cmp	x3, x10
  8140: 	b.ne	#16
  8144: 	mov	x10, #-3659174697238528         // =0xfff3000000000000
  8148: 	cmp	x0, x10
  8152: 	b.ne	#2732
  8156: 	str	x0, [x19, #2952]
  8160: 	mov	x0, x21
  8164: 	scvtf	d16, x0
  8168: 	ldr	x0, [x19, #2952]
  8172: 	lsr	x3, x0, #48
  8176: 	mov	x10, #65521                     // =0xfff1
  8180: 	cmp	x3, x10
  8184: 	b.hi	#2716
  8188: 	mov	x10, #65521                     // =0xfff1
  8192: 	cmp	x3, x10
  8196: 	b.ne	#20
  8200: 	lsl	x0, x0, #16
  8204: 	asr	x0, x0, #16
  8208: 	scvtf	d17, x0
  8212: 	b	#8
  8216: 	fmov	d17, x0
  8220: 	fmov	d0, d16
  8224: 	fmov	d1, d17
  8228: 	fcmp	d0, d1
  8232: 	b.ls	#8
  8236: 	b	#88
  8240: 	cmp	x20, #1
  8244: 	b.ls	#2656
  8248: 	sub	x20, x20, #1
  8252: 	mov	x23, x4
  8256: 	mov	x0, x5
  8260: 	str	x0, [x19, #2560]
  8264: 	mov	x0, x6
  8268: 	str	x0, [x19, #2568]
  8272: 	fmov	d16, d2
  8276: 	mov	x0, x7
  8280: 	str	x0, [x19, #2576]
  8284: 	fmov	d17, d3
  8288: 	mov	x0, x21
  8292: 	str	x0, [x19, #2584]
  8296: 	fmov	d18, d4
  8300: 	mov	x0, x22
  8304: 	str	x0, [x19, #2592]
  8308: 	fmov	d19, d5
  8312: 	fmov	d20, d6
  8316: 	fmov	d21, d7
  8320: 	b	#-1276
