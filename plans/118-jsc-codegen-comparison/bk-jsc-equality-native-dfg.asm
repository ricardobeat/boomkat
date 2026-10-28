                 <0> 0x11d668840:    stp	fp, lr, [sp, #-0x10]!
                 <4> 0x11d668844:    mov	fp, sp
                 <8> 0x11d668848:    sub	x1, fp, #0xc0
                <12> 0x11d66884c:    mov	x17, #0x68
                <16> 0x11d668850:    movk	x17, #0x1440, lsl #0x10
                <20> 0x11d668854:    movk	x17, #0x1, lsl #0x20 -> 0x114400068 vm +104: vm.softStackLimit()
                <24> 0x11d668858:    ldr	x16, [x17, xzr]
                <28> 0x11d66885c:    cmp	x16, x1
                <32> 0x11d668860:    b.gt	0x11d6689d8 -> <408>
                <36> 0x11d668864:    sub	sp, fp, #0x60
                <40> 0x11d668868:    stp	x26, x27, [fp, #-0x18]; emitSaveCalleeSavesFor
                <44> 0x11d66886c:    stur	x28, [fp, #-0x8]
                <48> 0x11d668870:    orr	x27, xzr, #0xfffe000000000000
                <52> 0x11d668874:    orr	x28, x27, #0x2
                <56> 0x11d668878:    ldur	x26, [fp, #0x10]
                <60> 0x11d66887c:    ldur	x26, [x26, #0x80]
                <64> 0x11d668880:    ldur	x16, [fp, #0x28]
                <68> 0x11d668884:    tst	x16, x28
                <72> 0x11d668888:    b.ne	0x11d668a50 -> <528>
                <76> 0x11d66888c:    ldur	x0, [fp, #0x28]
                <80> 0x11d668890:    cbz	x0, 0x11d6688a8 -> <104>
                <84> 0x11d668894:    ldur	w17, [x0]
                <88> 0x11d668898:    mov	w16, #0xabe0
                <92> 0x11d66889c:    movk	w16, #0x100, lsl #0x10 -> 0x100abe0
                <96> 0x11d6688a0:    cmp	w17, w16
               <100> 0x11d6688a4:    b.ne	0x11d668a58 -> <536>
               <104> 0x11d6688a8:    stur	x0, [fp, #-0x28]
               <108> 0x11d6688ac:    mov	x1, #0xb260
               <112> 0x11d6688b0:    movk	x1, #0x1409, lsl #0x10
               <116> 0x11d6688b4:    movk	x1, #0x1, lsl #0x20 -> 0x11409b260
               <120> 0x11d6688b8:    stur	x1, [fp, #-0x20]
                 <124> 0x11d6688bc:    ldur	x1, [x0, #0x28]
                 <128> 0x11d6688c0:    cmp	x1, x27
                 <132> 0x11d6688c4:    b.lo	0x11d668a68 -> <552>
                 <136> 0x11d6688c8:    cmp	w1, #0x1
                 <140> 0x11d6688cc:    b.ne	0x11d668928 -> <232>
                 <144> 0x11d6688d0:    ldur	x0, [fp, #-0x28]
                 <148> 0x11d6688d4:    ldur	x1, [x0, #0x20]
                 <152> 0x11d6688d8:    tst	x1, x28
                 <156> 0x11d6688dc:    b.ne	0x11d668a70 -> <560>
                 <160> 0x11d6688e0:    ldur	w17, [x1]
                 <164> 0x11d6688e4:    mov	w16, #0xa940
                 <168> 0x11d6688e8:    movk	w16, #0x100, lsl #0x10 -> 0x100a940
                 <172> 0x11d6688ec:    cmp	w17, w16
                 <176> 0x11d6688f0:    b.ne	0x11d668a78 -> <568>
                 <180> 0x11d6688f4:    stur	x1, [fp, #-0x20]
               <184> 0x11d6688f8:    ldur	x0, [fp, #0x28]
               <188> 0x11d6688fc:    stur	x0, [fp, #-0x38]
               <192> 0x11d668900:    mov	x1, #0xb240
               <196> 0x11d668904:    movk	x1, #0x1409, lsl #0x10
               <200> 0x11d668908:    movk	x1, #0x1, lsl #0x20 -> 0x11409b240
               <204> 0x11d66890c:    stur	x1, [fp, #-0x30]
                 <208> 0x11d668910:    ldur	x1, [x0, #0x28]
                 <212> 0x11d668914:    cmp	x1, x27
                 <216> 0x11d668918:    b.lo	0x11d668a88 -> <584>
                 <220> 0x11d66891c:    cmp	w1, #0x1
                 <224> 0x11d668920:    b.eq	0x11d668938 -> <248>
                 <228> 0x11d668924:    b	0x11d6689c0 -> <384>
                 <232> 0x11d668928:    b	0x11d668a90 -> <592>
                 <236> 0x11d66892c:    mov	x17, #0x196 -> 406
                 <240> 0x11d668930:    mov	w16, #0xa2 -> 162
                 <244> 0x11d668934:    brk	#0xc471
                 <248> 0x11d668938:    ldur	x0, [fp, #-0x38]
                 <252> 0x11d66893c:    ldur	x1, [x0, #0x18]
                 <256> 0x11d668940:    tst	x1, x28
                 <260> 0x11d668944:    b.ne	0x11d668a98 -> <600>
                 <264> 0x11d668948:    ldur	w17, [x1]
                 <268> 0x11d66894c:    mov	w16, #0xa940
                 <272> 0x11d668950:    movk	w16, #0x100, lsl #0x10 -> 0x100a940
                 <276> 0x11d668954:    cmp	w17, w16
                 <280> 0x11d668958:    b.ne	0x11d668aa0 -> <608>
               <284> 0x11d66895c:    ldur	x0, [x1, #0x10]
               <288> 0x11d668960:    ldur	x1, [fp, #-0x20]
               <292> 0x11d668964:    cmp	x0, x27
               <296> 0x11d668968:    b.lo	0x11d668aa8 -> <616>
               <300> 0x11d66896c:    stur	x0, [x1, #0x10]
               <304> 0x11d668970:    ldurb	w0, [x1, #0x7]
               <308> 0x11d668974:    mov	x17, #0x348
               <312> 0x11d668978:    movk	x17, #0x1440, lsl #0x10
               <316> 0x11d66897c:    movk	x17, #0x1, lsl #0x20 -> 0x114400348 vm +840: vm.heap.m_barrierThreshold
               <320> 0x11d668980:    ldr	w16, [x17, xzr]
               <324> 0x11d668984:    cmp	w16, w0
               <328> 0x11d668988:    b.hs	0x11d668a00 -> <448>
               <332> 0x11d66898c:    ldur	w16, [x26, #0x28]
               <336> 0x11d668990:    adds	w16, w16, #0xf
               <340> 0x11d668994:    stur	w16, [x26, #0x28]
               <344> 0x11d668998:    b.pl	0x11d6689dc -> <412>
               <348> 0x11d66899c:    mov	x0, #0xa -> 10
               <352> 0x11d6689a0:    ldp	x26, x27, [fp, #-0x18]; emitRestoreCalleeSavesFor
               <356> 0x11d6689a4:    ldur	x28, [fp, #-0x8]
               <360> 0x11d6689a8:    mov	sp, fp
               <364> 0x11d6689ac:    ldp	fp, lr, [sp], #0x10
               <368> 0x11d6689b0:    ret
               <372> 0x11d6689b4:    mov	x17, #0x18b -> 395
               <376> 0x11d6689b8:    mov	w16, #0xa1 -> 161
               <380> 0x11d6689bc:    brk	#0xc471
                 <384> 0x11d6689c0:    b	0x11d668ab0 -> <624>
                 <388> 0x11d6689c4:    mov	x17, #0x196 -> 406
                 <392> 0x11d6689c8:    mov	w16, #0xa2 -> 162
                 <396> 0x11d6689cc:    brk	#0xc471
               <400> 0x11d6689d0:    stp	fp, lr, [sp, #-0x10]!
               <404> 0x11d6689d4:    mov	fp, sp
               <408> 0x11d6689d8:    b	0x11d60c200 -> JIT PC
               <412> 0x11d6689dc:    mov	x0, #0x14400000
               <416> 0x11d6689e0:    movk	x0, #0x1, lsl #0x20 -> 0x114400000 vm
               <420> 0x11d6689e4:    orr	w16, wzr, #0x1
               <424> 0x11d6689e8:    stur	w16, [fp, #0x24]
               <428> 0x11d6689ec:    mov	x16, #0x1690
               <432> 0x11d6689f0:    movk	x16, #0x31e, lsl #0x10
               <436> 0x11d6689f4:    movk	x16, #0x1, lsl #0x20 -> 0x1031e1690
               <440> 0x11d6689f8:    blr	x16
               <444> 0x11d6689fc:    b	0x11d66899c -> <348>
               <448> 0x11d668a00:    mov	x17, #0x343
               <452> 0x11d668a04:    movk	x17, #0x1440, lsl #0x10
               <456> 0x11d668a08:    movk	x17, #0x1, lsl #0x20 -> 0x114400343 vm +835
               <460> 0x11d668a0c:    ldrb	w17, [x17, xzr]
               <464> 0x11d668a10:    cbz	w17, 0x11d668a24 -> <484>
               <468> 0x11d668a14:    dmb	ish
               <472> 0x11d668a18:    ldurb	w17, [x1, #0x7]
               <476> 0x11d668a1c:    cmp	w17, #0
               <480> 0x11d668a20:    b.hi	0x11d66898c -> <332>
               <484> 0x11d668a24:    stur	x1, [fp, #-0x50]
               <488> 0x11d668a28:    mov	x0, #0x14400000
               <492> 0x11d668a2c:    movk	x0, #0x1, lsl #0x20 -> 0x114400000 vm
               <496> 0x11d668a30:    orr	w16, wzr, #0x2
               <500> 0x11d668a34:    stur	w16, [fp, #0x24]
               <504> 0x11d668a38:    mov	x16, #0xb430
               <508> 0x11d668a3c:    movk	x16, #0x371, lsl #0x10
               <512> 0x11d668a40:    movk	x16, #0x1, lsl #0x20 -> 0x10371b430
               <516> 0x11d668a44:    blr	x16
               <520> 0x11d668a48:    ldur	x1, [fp, #-0x50]
               <524> 0x11d668a4c:    b	0x11d66898c -> <332>
               <528> 0x11d668a50:    mov	w27, #0
               <532> 0x11d668a54:    b	0x11d624b60 -> JIT PC
               <536> 0x11d668a58:    orr	w27, wzr, #0x1
               <540> 0x11d668a5c:    b	0x11d624b60 -> JIT PC
               <544> 0x11d668a60:    orr	w27, wzr, #0x2
               <548> 0x11d668a64:    b	0x11d624b60 -> JIT PC
               <552> 0x11d668a68:    orr	w27, wzr, #0x3
               <556> 0x11d668a6c:    b	0x11d624b60 -> JIT PC
               <560> 0x11d668a70:    orr	w27, wzr, #0x4
               <564> 0x11d668a74:    b	0x11d624b60 -> JIT PC
               <568> 0x11d668a78:    mov	w27, #0x5 -> 5
               <572> 0x11d668a7c:    b	0x11d624b60 -> JIT PC
               <576> 0x11d668a80:    orr	w27, wzr, #0x6
               <580> 0x11d668a84:    b	0x11d624b60 -> JIT PC
               <584> 0x11d668a88:    orr	w27, wzr, #0x7
               <588> 0x11d668a8c:    b	0x11d624b60 -> JIT PC
               <592> 0x11d668a90:    orr	w27, wzr, #0x8
               <596> 0x11d668a94:    b	0x11d624b60 -> JIT PC
               <600> 0x11d668a98:    mov	w27, #0x9 -> 9
               <604> 0x11d668a9c:    b	0x11d624b60 -> JIT PC
               <608> 0x11d668aa0:    mov	w27, #0xa -> 10
               <612> 0x11d668aa4:    b	0x11d624b60 -> JIT PC
               <616> 0x11d668aa8:    mov	w27, #0xb -> 11
               <620> 0x11d668aac:    b	0x11d624b60 -> JIT PC
               <624> 0x11d668ab0:    orr	w27, wzr, #0xc
               <628> 0x11d668ab4:    b	0x11d624b60 -> JIT PC
