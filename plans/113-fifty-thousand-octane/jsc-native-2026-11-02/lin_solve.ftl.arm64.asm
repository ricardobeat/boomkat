asm                          <0> 0x12a654e00:    pacibsp
asm                          <4> 0x12a654e04:    stp	fp, lr, [sp, #-0x10]!
asm                          <8> 0x12a654e08:    mov	fp, sp
asm                         <12> 0x12a654e0c:    sub	x0, fp, #0xc0
asm                         <16> 0x12a654e10:    mov	x17, #0x6068
asm                         <20> 0x12a654e14:    movk	x17, #0xf42, lsl #0x10
asm                         <24> 0x12a654e18:    movk	x17, #0x1, lsl #0x20 -> 0x10f426068 vm +104: vm.softStackLimit()
asm                         <28> 0x12a654e1c:    ldr	x16, [x17, xzr]
asm                         <32> 0x12a654e20:    cmp	x16, x0
asm                         <36> 0x12a654e24:    b.gt	0x12a61c000 -> JIT PC
asm                         <40> 0x12a654e28:    sub	sp, sp, #0xc0
asm                         <44> 0x12a654e2c:    stp	x19, x20, [fp, #-0x60]
asm                         <48> 0x12a654e30:    stp	x21, x22, [fp, #-0x50]
asm                         <52> 0x12a654e34:    stp	x23, x24, [fp, #-0x40]
asm                         <56> 0x12a654e38:    stp	x25, x26, [fp, #-0x30]
asm                         <60> 0x12a654e3c:    stp	x27, x28, [fp, #-0x20]
asm                         <64> 0x12a654e40:    stp	d8, d9, [fp, #-0x10]
asm                         <68> 0x12a654e44:    ldur	x0, [fp, #0x50]
asm                         <72> 0x12a654e48:    orr	x24, xzr, #0xfffe000000000000
asm                         <76> 0x12a654e4c:    cmp	x0, x24
asm                         <80> 0x12a654e50:    b.lo	0x12a655468 -> <1640>
asm                         <84> 0x12a654e54:    ldur	x26, [fp, #0x48]
asm                         <88> 0x12a654e58:    cmp	x26, x24
asm                         <92> 0x12a654e5c:    b.lo	0x12a65547c -> <1660>
asm                         <96> 0x12a654e60:    ldur	x25, [fp, #0x40]
asm                        <100> 0x12a654e64:    add	x1, x24, #0x2
asm                        <104> 0x12a654e68:    tst	x25, x1
asm                        <108> 0x12a654e6c:    b.ne	0x12a655490 -> <1680>
asm                        <112> 0x12a654e70:    ldur	x19, [fp, #0x38]
asm                        <116> 0x12a654e74:    tst	x19, x1
asm                        <120> 0x12a654e78:    b.ne	0x12a6554a4 -> <1700>
asm                        <124> 0x12a654e7c:    ldur	x20, [fp, #0x30]
asm                        <128> 0x12a654e80:    ldur	w1, [x19]
asm                        <132> 0x12a654e84:    mov	x2, #0x2780
asm                        <136> 0x12a654e88:    movk	x2, #0x100, lsl #0x10 -> 0x1002780
asm                        <140> 0x12a654e8c:    cmp	w1, w2
asm                        <144> 0x12a654e90:    b.ne	0x12a6554b8 -> <1720>
asm                        <148> 0x12a654e94:    ldur	w1, [x25]
asm                        <152> 0x12a654e98:    cmp	w1, w2
asm                        <156> 0x12a654e9c:    b.ne	0x12a6554cc -> <1740>
asm                        <160> 0x12a654ea0:    mov	x27, #0x4298; InvalidationPoint
asm                        <164> 0x12a654ea4:    movk	x27, #0xf1e, lsl #0x10
asm                        <168> 0x12a654ea8:    movk	x27, #0x1, lsl #0x20 -> 0x10f1e4298
asm                        <172> 0x12a654eac:    mov	x21, #0x29a0
asm                        <176> 0x12a654eb0:    movk	x21, #0xf1a, lsl #0x10
asm                        <180> 0x12a654eb4:    movk	x21, #0x1, lsl #0x20 -> 0x10f1a29a0
asm                        <184> 0x12a654eb8:    sub	x22, x27, #0x98
asm                        <188> 0x12a654ebc:    orr	x23, xzr, #0x3
asm                        <192> 0x12a654ec0:    cbnz	w26, 0x12a655068 -> <616>
asm                        <196> 0x12a654ec4:    cmp	w0, #0x1
asm                        <200> 0x12a654ec8:    b.ne	0x12a655068 -> <616>
asm                        <204> 0x12a654ecc:    ldur	x0, [x27]
asm                        <208> 0x12a654ed0:    cmp	x0, x24
asm                        <212> 0x12a654ed4:    b.lo	0x12a6554f4 -> <1780>
asm                        <216> 0x12a654ed8:    cmp	w0, #0x1
asm                        <220> 0x12a654edc:    b.lt	0x12a655304 -> <1284>
asm                        <224> 0x12a654ee0:    orr	x1, xzr, #0x1
asm                        <228> 0x12a654ee4:    ldur	x2, [x27, #0x40]
asm                        <232> 0x12a654ee8:    cmp	x2, x24
asm                        <236> 0x12a654eec:    b.lo	0x12a655508 -> <1800>
asm                        <240> 0x12a654ef0:    ldur	x3, [x27, #0x18]
asm                        <244> 0x12a654ef4:    cbz	x3, 0x12a65551c -> <1820>
asm                        <248> 0x12a654ef8:    cmp	x3, x24
asm                        <252> 0x12a654efc:    b.lo	0x12a655530 -> <1840>
asm                        <256> 0x12a654f00:    ldur	x4, [x25, #0x8]
asm                        <260> 0x12a654f04:    ldur	w5, [x4, #-0x8]
asm                        <264> 0x12a654f08:    ldur	x6, [x19, #0x8]
asm                        <268> 0x12a654f0c:    ldur	w7, [x6, #-0x8]
asm                        <272> 0x12a654f10:    smull	x8, w1, w2
asm                        <276> 0x12a654f14:    cmp	x8, w8, sxtw
asm                        <280> 0x12a654f18:    mov	w8, w8
asm                        <284> 0x12a654f1c:    b.ne	0x12a655544 -> <1860>
asm                        <288> 0x12a654f20:    adds	w8, w8, #0x1
asm                        <292> 0x12a654f24:    b.vs	0x12a655558 -> <1880>
asm                        <296> 0x12a654f28:    cmp	w3, #0
asm                        <300> 0x12a654f2c:    b.le	0x12a655344 -> <1348>
asm                        <304> 0x12a654f30:    mov	x9, #0
asm                        <308> 0x12a654f34:    cmp	w8, w5
asm                        <312> 0x12a654f38:    b.hs	0x12a655570 -> <1904>
asm                        <316> 0x12a654f3c:    ldr	d0, [x4, w8, uxtw #0x3]
asm                        <320> 0x12a654f40:    fcmp	d0, d0
asm                        <324> 0x12a654f44:    b.ne	0x12a655584 -> <1924>
asm                        <328> 0x12a654f48:    cmp	w8, w7
asm                        <332> 0x12a654f4c:    b.hs	0x12a655598 -> <1944>
asm                        <336> 0x12a654f50:    str	d0, [x6, w8, uxtw #0x3]
asm                        <340> 0x12a654f54:    add	w10, w8, #0x1
asm                        <344> 0x12a654f58:    add	w11, w9, #0x1
asm                        <348> 0x12a654f5c:    cmp	w3, w11
asm                        <352> 0x12a654f60:    b.le	0x12a655358 -> <1368>
asm                        <356> 0x12a654f64:    cmp	w5, w10
asm                        <360> 0x12a654f68:    b.ls	0x12a6555ac -> <1964>
asm                        <364> 0x12a654f6c:    ldr	d0, [x4, w10, uxtw #0x3]
asm                        <368> 0x12a654f70:    fcmp	d0, d0
asm                        <372> 0x12a654f74:    b.ne	0x12a6555c0 -> <1984>
asm                        <376> 0x12a654f78:    cmp	w7, w10
asm                        <380> 0x12a654f7c:    b.ls	0x12a6555d4 -> <2004>
asm                        <384> 0x12a654f80:    str	d0, [x6, w10, uxtw #0x3]
asm                        <388> 0x12a654f84:    add	w10, w8, #0x2
asm                        <392> 0x12a654f88:    add	w11, w9, #0x2
asm                        <396> 0x12a654f8c:    cmp	w3, w11
asm                        <400> 0x12a654f90:    b.le	0x12a65536c -> <1388>
asm                        <404> 0x12a654f94:    cmp	w5, w10
asm                        <408> 0x12a654f98:    b.ls	0x12a6555e8 -> <2024>
asm                        <412> 0x12a654f9c:    ldr	d0, [x4, w10, uxtw #0x3]
asm                        <416> 0x12a654fa0:    fcmp	d0, d0
asm                        <420> 0x12a654fa4:    b.ne	0x12a6555fc -> <2044>
asm                        <424> 0x12a654fa8:    cmp	w7, w10
asm                        <428> 0x12a654fac:    b.ls	0x12a655610 -> <2064>
asm                        <432> 0x12a654fb0:    str	d0, [x6, w10, uxtw #0x3]
asm                        <436> 0x12a654fb4:    add	w10, w8, #0x3
asm                        <440> 0x12a654fb8:    add	w11, w9, #0x3
asm                        <444> 0x12a654fbc:    cmp	w3, w11
asm                        <448> 0x12a654fc0:    b.le	0x12a655380 -> <1408>
asm                        <452> 0x12a654fc4:    cmp	w5, w10
asm                        <456> 0x12a654fc8:    b.ls	0x12a655624 -> <2084>
asm                        <460> 0x12a654fcc:    ldr	d0, [x4, w10, uxtw #0x3]
asm                        <464> 0x12a654fd0:    fcmp	d0, d0
asm                        <468> 0x12a654fd4:    b.ne	0x12a655638 -> <2104>
asm                        <472> 0x12a654fd8:    cmp	w7, w10
asm                        <476> 0x12a654fdc:    b.ls	0x12a65564c -> <2124>
asm                        <480> 0x12a654fe0:    str	d0, [x6, w10, uxtw #0x3]
asm                        <484> 0x12a654fe4:    add	w8, w8, #0x4
asm                        <488> 0x12a654fe8:    add	w9, w9, #0x4
asm                        <492> 0x12a654fec:    cmp	w3, w9
asm                        <496> 0x12a654ff0:    b.gt	0x12a654f34 -> <308>
asm                        <500> 0x12a654ff4:    adds	w1, w1, #0x1
asm                        <504> 0x12a654ff8:    b.vs	0x12a655660 -> <2144>
asm                        <508> 0x12a654ffc:    cmp	w1, w0
asm                        <512> 0x12a655000:    b.le	0x12a654f10 -> <272>
asm                        <516> 0x12a655004:    stur	x21, [fp, #-0xb8]
asm                        <520> 0x12a655008:    stur	w23, [fp, #-0xb0]
asm                        <524> 0x12a65500c:    stur	x22, [fp, #-0xa8]
asm                        <528> 0x12a655010:    stur	x20, [fp, #-0xa0]
asm                        <532> 0x12a655014:    stur	x19, [fp, #-0x98]
asm                        <536> 0x12a655018:    orr	w16, wzr, #0x1; DirectCallOrConstruct
asm                        <540> 0x12a65501c:    stur	w16, [fp, #0x24]
asm                        <544> 0x12a655020:    mov	x16, #0
asm                        <548> 0x12a655024:    movk	x16, #0, lsl #0x10
asm                        <552> 0x12a655028:    movk	x16, #0, lsl #0x20
asm                        <556> 0x12a65502c:    movk	x16, #0, lsl #0x30
asm                        <560> 0x12a655030:    stur	x16, [sp]
asm                        <564> 0x12a655034:    bl	0x12a655034 -> <564>
asm                        <568> 0x12a655038:    sub	sp, fp, #0xc0
asm                        <576> 0x12a655040:    mov	x0, #0xa -> 10
asm                        <580> 0x12a655044:    ldp	x19, x20, [fp, #-0x60]
asm                        <584> 0x12a655048:    ldp	x21, x22, [fp, #-0x50]
asm                        <588> 0x12a65504c:    ldp	x23, x24, [fp, #-0x40]
asm                        <592> 0x12a655050:    ldp	x25, x26, [fp, #-0x30]
asm                        <596> 0x12a655054:    ldp	x27, x28, [fp, #-0x20]
asm                        <600> 0x12a655058:    ldp	d8, d9, [fp, #-0x10]
asm                        <604> 0x12a65505c:    mov	sp, fp
asm                        <608> 0x12a655060:    ldp	fp, lr, [sp], #0x10
asm                        <612> 0x12a655064:    retab
asm                        <616> 0x12a655068:    scvtf	d0, w0
asm                        <620> 0x12a65506c:    fmov	d1, #1.00000000
asm                        <624> 0x12a655070:    fdiv	d8, d1, d0
asm                        <628> 0x12a655074:    ldur	x0, [x27, #-0x8]
asm                        <632> 0x12a655078:    cmp	x0, x24
asm                        <636> 0x12a65507c:    b.lo	0x12a6556e0 -> <2272>
asm                        <640> 0x12a655080:    cmp	w0, #0
asm                        <644> 0x12a655084:    b.le	0x12a655394 -> <1428>
asm                        <648> 0x12a655088:    mov	x28, #0
asm                        <652> 0x12a65508c:    scvtf	d9, w26
asm                        <656> 0x12a655090:    ldur	x1, [x27]; InvalidationPoint
asm                        <660> 0x12a655094:    cmp	x1, x24
asm                        <664> 0x12a655098:    b.lo	0x12a655708 -> <2312>
asm                        <668> 0x12a65509c:    cmp	w1, #0x1
asm                        <672> 0x12a6550a0:    b.lt	0x12a6553bc -> <1468>
asm                        <676> 0x12a6550a4:    orr	x6, xzr, #0x1
asm                        <680> 0x12a6550a8:    ldur	x2, [x27, #0x40]
asm                        <684> 0x12a6550ac:    cmp	x2, x24
asm                        <688> 0x12a6550b0:    b.lo	0x12a65571c -> <2332>
asm                        <692> 0x12a6550b4:    ldur	x3, [x19, #0x8]
asm                        <696> 0x12a6550b8:    ldur	w4, [x3, #-0x8]
asm                        <700> 0x12a6550bc:    ldur	x5, [x27, #0x18]
asm                        <704> 0x12a6550c0:    cbz	x5, 0x12a655730 -> <2352>
asm                        <708> 0x12a6550c4:    cmp	x5, x24
asm                        <712> 0x12a6550c8:    b.lo	0x12a655744 -> <2372>
asm                        <716> 0x12a6550cc:    ldur	x7, [x25, #0x8]
asm                        <720> 0x12a6550d0:    ldur	w8, [x7, #-0x8]
asm                        <724> 0x12a6550d4:    sub	w0, w6, #0x1
asm                        <728> 0x12a6550d8:    smull	x11, w2, w0
asm                        <732> 0x12a6550dc:    cmp	x11, w11, sxtw
asm                        <736> 0x12a6550e0:    mov	w11, w11
asm                        <740> 0x12a6550e4:    b.ne	0x12a655758 -> <2392>
asm                        <744> 0x12a6550e8:    smull	x9, w6, w2
asm                        <748> 0x12a6550ec:    cmp	x9, w9, sxtw
asm                        <752> 0x12a6550f0:    mov	w9, w9
asm                        <756> 0x12a6550f4:    b.ne	0x12a65576c -> <2412>
asm                        <760> 0x12a6550f8:    adds	w0, w6, #0x1
asm                        <764> 0x12a6550fc:    b.vs	0x12a655780 -> <2432>
asm                        <768> 0x12a655100:    smull	x10, w2, w0
asm                        <772> 0x12a655104:    cmp	x10, w10, sxtw
asm                        <776> 0x12a655108:    mov	w10, w10
asm                        <780> 0x12a65510c:    b.ne	0x12a655794 -> <2452>
asm                        <784> 0x12a655110:    cmp	w4, w9
asm                        <788> 0x12a655114:    b.ls	0x12a6557a8 -> <2472>
asm                        <792> 0x12a655118:    ldr	d0, [x3, w9, uxtw #0x3]
asm                        <796> 0x12a65511c:    add	w9, w9, #0x1
asm                        <800> 0x12a655120:    cmp	w5, #0x1
asm                        <804> 0x12a655124:    b.lt	0x12a655438 -> <1592>
asm                        <808> 0x12a655128:    orr	x13, xzr, #0x1
asm                        <812> 0x12a65512c:    cmp	w9, w8
asm                        <816> 0x12a655130:    b.hs	0x12a6557bc -> <2492>
asm                        <820> 0x12a655134:    ldr	d1, [x7, w9, uxtw #0x3]
asm                        <824> 0x12a655138:    add	w12, w9, #0x1
asm                        <828> 0x12a65513c:    cmp	w4, w12
asm                        <832> 0x12a655140:    b.ls	0x12a6557d0 -> <2512>
asm                        <836> 0x12a655144:    ldr	d2, [x3, w12, uxtw #0x3]
asm                        <840> 0x12a655148:    fadd	d0, d0, d2
asm                        <844> 0x12a65514c:    adds	w11, w11, #0x1
asm                        <848> 0x12a655150:    b.vs	0x12a6557e4 -> <2532>
asm                        <852> 0x12a655154:    cmp	w4, w11
asm                        <856> 0x12a655158:    b.ls	0x12a6557fc -> <2556>
asm                        <860> 0x12a65515c:    ldr	d2, [x3, w11, uxtw #0x3]
asm                        <864> 0x12a655160:    fadd	d0, d0, d2
asm                        <868> 0x12a655164:    adds	w10, w10, #0x1
asm                        <872> 0x12a655168:    b.vs	0x12a655810 -> <2576>
asm                        <876> 0x12a65516c:    cmp	w4, w10
asm                        <880> 0x12a655170:    b.ls	0x12a655828 -> <2600>
asm                        <884> 0x12a655174:    ldr	d2, [x3, w10, uxtw #0x3]
asm                        <888> 0x12a655178:    fadd	d0, d0, d2
asm                        <892> 0x12a65517c:    fmul	d0, d9, d0
asm                        <896> 0x12a655180:    fadd	d0, d1, d0
asm                        <900> 0x12a655184:    fmul	d0, d8, d0
asm                        <904> 0x12a655188:    fcmp	d0, d0
asm                        <908> 0x12a65518c:    b.ne	0x12a65583c -> <2620>
asm                        <912> 0x12a655190:    str	d0, [x3, w9, uxtw #0x3]
asm                        <916> 0x12a655194:    adds	w14, w13, #0x1
asm                        <920> 0x12a655198:    b.vs	0x12a655850 -> <2640>
asm                        <924> 0x12a65519c:    cmp	w5, w14
asm                        <928> 0x12a6551a0:    b.lt	0x12a655444 -> <1604>
asm                        <932> 0x12a6551a4:    cmp	w8, w12
asm                        <936> 0x12a6551a8:    b.ls	0x12a655864 -> <2660>
asm                        <940> 0x12a6551ac:    ldr	d1, [x7, w12, uxtw #0x3]
asm                        <944> 0x12a6551b0:    add	w13, w9, #0x2
asm                        <948> 0x12a6551b4:    cmp	w4, w13
asm                        <952> 0x12a6551b8:    b.ls	0x12a655878 -> <2680>
asm                        <956> 0x12a6551bc:    ldr	d2, [x3, w13, uxtw #0x3]
asm                        <960> 0x12a6551c0:    fadd	d0, d0, d2
asm                        <964> 0x12a6551c4:    add	w16, w11, #0x1
asm                        <968> 0x12a6551c8:    cmp	w4, w16
asm                        <972> 0x12a6551cc:    b.ls	0x12a65588c -> <2700>
asm                        <976> 0x12a6551d0:    ldr	d2, [x3, w16, uxtw #0x3]
asm                        <980> 0x12a6551d4:    fadd	d0, d0, d2
asm                        <984> 0x12a6551d8:    add	w15, w10, #0x1
asm                        <988> 0x12a6551dc:    cmp	w4, w15
asm                        <992> 0x12a6551e0:    b.ls	0x12a6558a0 -> <2720>
asm                        <996> 0x12a6551e4:    ldr	d2, [x3, w15, uxtw #0x3]
asm                       <1000> 0x12a6551e8:    fadd	d0, d0, d2
asm                       <1004> 0x12a6551ec:    fmul	d0, d9, d0
asm                       <1008> 0x12a6551f0:    fadd	d0, d1, d0
asm                       <1012> 0x12a6551f4:    fmul	d0, d8, d0
asm                       <1016> 0x12a6551f8:    fcmp	d0, d0
asm                       <1020> 0x12a6551fc:    b.ne	0x12a6558b4 -> <2740>
asm                       <1024> 0x12a655200:    str	d0, [x3, w12, uxtw #0x3]
asm                       <1028> 0x12a655204:    adds	w14, w14, #0x1
asm                       <1032> 0x12a655208:    b.vs	0x12a6558c8 -> <2760>
asm                       <1036> 0x12a65520c:    cmp	w5, w14
asm                       <1040> 0x12a655210:    b.lt	0x12a655450 -> <1616>
asm                       <1044> 0x12a655214:    cmp	w8, w13
asm                       <1048> 0x12a655218:    b.ls	0x12a6558e0 -> <2784>
asm                       <1052> 0x12a65521c:    ldr	d1, [x7, w13, uxtw #0x3]
asm                       <1056> 0x12a655220:    add	w12, w9, #0x3
asm                       <1060> 0x12a655224:    cmp	w4, w12
asm                       <1064> 0x12a655228:    b.ls	0x12a6558f4 -> <2804>
asm                       <1068> 0x12a65522c:    ldr	d2, [x3, w12, uxtw #0x3]
asm                       <1072> 0x12a655230:    fadd	d0, d0, d2
asm                       <1076> 0x12a655234:    add	w16, w11, #0x2
asm                       <1080> 0x12a655238:    cmp	w4, w16
asm                       <1084> 0x12a65523c:    b.ls	0x12a655908 -> <2824>
asm                       <1088> 0x12a655240:    ldr	d2, [x3, w16, uxtw #0x3]
asm                       <1092> 0x12a655244:    fadd	d0, d0, d2
asm                       <1096> 0x12a655248:    add	w15, w10, #0x2
asm                       <1100> 0x12a65524c:    cmp	w4, w15
asm                       <1104> 0x12a655250:    b.ls	0x12a65591c -> <2844>
asm                       <1108> 0x12a655254:    ldr	d2, [x3, w15, uxtw #0x3]
asm                       <1112> 0x12a655258:    fadd	d0, d0, d2
asm                       <1116> 0x12a65525c:    fmul	d0, d9, d0
asm                       <1120> 0x12a655260:    fadd	d0, d1, d0
asm                       <1124> 0x12a655264:    fmul	d0, d8, d0
asm                       <1128> 0x12a655268:    fcmp	d0, d0
asm                       <1132> 0x12a65526c:    b.ne	0x12a655930 -> <2864>
asm                       <1136> 0x12a655270:    str	d0, [x3, w13, uxtw #0x3]
asm                       <1140> 0x12a655274:    adds	w13, w14, #0x1
asm                       <1144> 0x12a655278:    b.vs	0x12a655944 -> <2884>
asm                       <1148> 0x12a65527c:    cmp	w5, w13
asm                       <1152> 0x12a655280:    b.lt	0x12a65545c -> <1628>
asm                       <1156> 0x12a655284:    cmp	w8, w12
asm                       <1160> 0x12a655288:    b.ls	0x12a655958 -> <2904>
asm                       <1164> 0x12a65528c:    ldr	d1, [x7, w12, uxtw #0x3]
asm                       <1168> 0x12a655290:    add	w9, w9, #0x4
asm                       <1172> 0x12a655294:    cmp	w4, w9
asm                       <1176> 0x12a655298:    b.ls	0x12a65596c -> <2924>
asm                       <1180> 0x12a65529c:    ldr	d2, [x3, w9, uxtw #0x3]
asm                       <1184> 0x12a6552a0:    fadd	d0, d0, d2
asm                       <1188> 0x12a6552a4:    add	w11, w11, #0x3
asm                       <1192> 0x12a6552a8:    cmp	w4, w11
asm                       <1196> 0x12a6552ac:    b.ls	0x12a655980 -> <2944>
asm                       <1200> 0x12a6552b0:    ldr	d2, [x3, w11, uxtw #0x3]
asm                       <1204> 0x12a6552b4:    fadd	d0, d0, d2
asm                       <1208> 0x12a6552b8:    add	w10, w10, #0x3
asm                       <1212> 0x12a6552bc:    cmp	w4, w10
asm                       <1216> 0x12a6552c0:    b.ls	0x12a655994 -> <2964>
asm                       <1220> 0x12a6552c4:    ldr	d2, [x3, w10, uxtw #0x3]
asm                       <1224> 0x12a6552c8:    fadd	d0, d0, d2
asm                       <1228> 0x12a6552cc:    fmul	d0, d9, d0
asm                       <1232> 0x12a6552d0:    fadd	d0, d1, d0
asm                       <1236> 0x12a6552d4:    fmul	d0, d8, d0
asm                       <1240> 0x12a6552d8:    fcmp	d0, d0
asm                       <1244> 0x12a6552dc:    b.ne	0x12a6559a8 -> <2984>
asm                       <1248> 0x12a6552e0:    str	d0, [x3, w12, uxtw #0x3]
asm                       <1252> 0x12a6552e4:    adds	w13, w13, #0x1
asm                       <1256> 0x12a6552e8:    b.vs	0x12a6559bc -> <3004>
asm                       <1260> 0x12a6552ec:    cmp	w5, w13
asm                       <1264> 0x12a6552f0:    b.ge	0x12a65512c -> <812>
asm                       <1268> 0x12a6552f4:    cmp	w1, w0
asm                       <1272> 0x12a6552f8:    b.lt	0x12a6553bc -> <1468>
asm                       <1276> 0x12a6552fc:    mov	x6, x0
asm                       <1280> 0x12a655300:    b	0x12a6550d4 -> <724>
asm                       <1284> 0x12a655304:    stur	x21, [fp, #-0xb8]
asm                       <1288> 0x12a655308:    stur	w23, [fp, #-0xb0]
asm                       <1292> 0x12a65530c:    stur	x22, [fp, #-0xa8]
asm                       <1296> 0x12a655310:    stur	x20, [fp, #-0xa0]
asm                       <1300> 0x12a655314:    stur	x19, [fp, #-0x98]
asm                       <1304> 0x12a655318:    orr	w16, wzr, #0x2; DirectCallOrConstruct
asm                       <1308> 0x12a65531c:    stur	w16, [fp, #0x24]
asm                       <1312> 0x12a655320:    mov	x16, #0
asm                       <1316> 0x12a655324:    movk	x16, #0, lsl #0x10
asm                       <1320> 0x12a655328:    movk	x16, #0, lsl #0x20
asm                       <1324> 0x12a65532c:    movk	x16, #0, lsl #0x30
asm                       <1328> 0x12a655330:    stur	x16, [sp]
asm                       <1332> 0x12a655334:    bl	0x12a655334 -> <1332>
asm                       <1336> 0x12a655338:    sub	sp, fp, #0xc0
asm                       <1340> 0x12a65533c:    nop; InvalidationPoint
asm                       <1344> 0x12a655340:    b	0x12a655040 -> <576>
asm                       <1348> 0x12a655344:    adds	w1, w1, #0x1
asm                       <1352> 0x12a655348:    b.vs	0x12a655a3c -> <3132>
asm                       <1356> 0x12a65534c:    cmp	w1, w0
asm                       <1360> 0x12a655350:    b.le	0x12a654f10 -> <272>
asm                       <1368> 0x12a655358:    adds	w1, w1, #0x1
asm                       <1372> 0x12a65535c:    b.vs	0x12a655a54 -> <3156>
asm                       <1376> 0x12a655360:    cmp	w1, w0
asm                       <1380> 0x12a655364:    b.le	0x12a654f10 -> <272>
asm                       <1388> 0x12a65536c:    adds	w1, w1, #0x1
asm                       <1392> 0x12a655370:    b.vs	0x12a655a6c -> <3180>
asm                       <1396> 0x12a655374:    cmp	w1, w0
asm                       <1400> 0x12a655378:    b.le	0x12a654f10 -> <272>
asm                       <1408> 0x12a655380:    adds	w1, w1, #0x1
asm                       <1412> 0x12a655384:    b.vs	0x12a655a84 -> <3204>
asm                       <1416> 0x12a655388:    cmp	w1, w0
asm                       <1420> 0x12a65538c:    b.le	0x12a654f10 -> <272>
asm                       <1428> 0x12a655394:    mov	x0, #0xa -> 10
asm                       <1432> 0x12a655398:    ldp	x19, x20, [fp, #-0x60]
asm                       <1436> 0x12a65539c:    ldp	x21, x22, [fp, #-0x50]
asm                       <1440> 0x12a6553a0:    ldp	x23, x24, [fp, #-0x40]
asm                       <1444> 0x12a6553a4:    ldp	x25, x26, [fp, #-0x30]
asm                       <1448> 0x12a6553a8:    ldp	x27, x28, [fp, #-0x20]
asm                       <1452> 0x12a6553ac:    ldp	d8, d9, [fp, #-0x10]
asm                       <1456> 0x12a6553b0:    mov	sp, fp
asm                       <1460> 0x12a6553b4:    ldp	fp, lr, [sp], #0x10
asm                       <1464> 0x12a6553b8:    retab
asm                       <1468> 0x12a6553bc:    stur	x21, [fp, #-0xb8]
asm                       <1472> 0x12a6553c0:    stur	w23, [fp, #-0xb0]
asm                       <1476> 0x12a6553c4:    stur	x22, [fp, #-0xa8]
asm                       <1480> 0x12a6553c8:    stur	x20, [fp, #-0xa0]
asm                       <1484> 0x12a6553cc:    stur	x19, [fp, #-0x98]
asm                       <1488> 0x12a6553d0:    orr	w16, wzr, #0x3; DirectCallOrConstruct
asm                       <1492> 0x12a6553d4:    stur	w16, [fp, #0x24]
asm                       <1496> 0x12a6553d8:    mov	x16, #0
asm                       <1500> 0x12a6553dc:    movk	x16, #0, lsl #0x10
asm                       <1504> 0x12a6553e0:    movk	x16, #0, lsl #0x20
asm                       <1508> 0x12a6553e4:    movk	x16, #0, lsl #0x30
asm                       <1512> 0x12a6553e8:    stur	x16, [sp]
asm                       <1516> 0x12a6553ec:    bl	0x12a6553ec -> <1516>
asm                       <1520> 0x12a6553f0:    sub	sp, fp, #0xc0
asm                       <1524> 0x12a6553f4:    adds	w28, w28, #0x1; InvalidationPoint
asm                       <1528> 0x12a6553f8:    b.vs	0x12a655b04 -> <3332>
asm                       <1532> 0x12a6553fc:    ldur	x0, [x27, #-0x8]
asm                       <1536> 0x12a655400:    cmp	x0, x24
asm                       <1540> 0x12a655404:    b.lo	0x12a655b1c -> <3356>
asm                       <1544> 0x12a655408:    cmp	w28, w0
asm                       <1548> 0x12a65540c:    b.lt	0x12a655090 -> <656>
asm                       <1552> 0x12a655410:    mov	x0, #0xa -> 10
asm                       <1556> 0x12a655414:    ldp	x19, x20, [fp, #-0x60]
asm                       <1560> 0x12a655418:    ldp	x21, x22, [fp, #-0x50]
asm                       <1564> 0x12a65541c:    ldp	x23, x24, [fp, #-0x40]
asm                       <1568> 0x12a655420:    ldp	x25, x26, [fp, #-0x30]
asm                       <1572> 0x12a655424:    ldp	x27, x28, [fp, #-0x20]
asm                       <1576> 0x12a655428:    ldp	d8, d9, [fp, #-0x10]
asm                       <1580> 0x12a65542c:    mov	sp, fp
asm                       <1584> 0x12a655430:    ldp	fp, lr, [sp], #0x10
asm                       <1588> 0x12a655434:    retab
asm                       <1592> 0x12a655438:    cmp	w1, w0
asm                       <1596> 0x12a65543c:    b.ge	0x12a6552fc -> <1276>
asm                       <1604> 0x12a655444:    cmp	w1, w0
asm                       <1608> 0x12a655448:    b.ge	0x12a6552fc -> <1276>
asm                       <1616> 0x12a655450:    cmp	w1, w0
asm                       <1620> 0x12a655454:    b.ge	0x12a6552fc -> <1276>
asm                       <1628> 0x12a65545c:    cmp	w1, w0
asm                       <1632> 0x12a655460:    b.ge	0x12a6552fc -> <1276>
asm                       <1640> 0x12a655468:    stp	x16, x16, [sp, #-0x10]!
asm                       <1644> 0x12a65546c:    mov	w16, #0x5 -> 5
asm                       <1648> 0x12a655470:    stur	x16, [sp]
asm                       <1652> 0x12a655474:    ldur	x16, [sp, #0x8]
asm                       <1656> 0x12a655478:    b	0x12a630400 -> JIT PC
asm                       <1660> 0x12a65547c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1664> 0x12a655480:    orr	w16, wzr, #0x6
asm                       <1668> 0x12a655484:    stur	x16, [sp]
asm                       <1672> 0x12a655488:    ldur	x16, [sp, #0x8]
asm                       <1676> 0x12a65548c:    b	0x12a630400 -> JIT PC
asm                       <1680> 0x12a655490:    stp	x16, x16, [sp, #-0x10]!
asm                       <1684> 0x12a655494:    orr	w16, wzr, #0x7
asm                       <1688> 0x12a655498:    stur	x16, [sp]
asm                       <1692> 0x12a65549c:    ldur	x16, [sp, #0x8]
asm                       <1696> 0x12a6554a0:    b	0x12a630400 -> JIT PC
asm                       <1700> 0x12a6554a4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1704> 0x12a6554a8:    orr	w16, wzr, #0x8
asm                       <1708> 0x12a6554ac:    stur	x16, [sp]
asm                       <1712> 0x12a6554b0:    ldur	x16, [sp, #0x8]
asm                       <1716> 0x12a6554b4:    b	0x12a630400 -> JIT PC
asm                       <1720> 0x12a6554b8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1724> 0x12a6554bc:    mov	w16, #0x9 -> 9
asm                       <1728> 0x12a6554c0:    stur	x16, [sp]
asm                       <1732> 0x12a6554c4:    ldur	x16, [sp, #0x8]
asm                       <1736> 0x12a6554c8:    b	0x12a630400 -> JIT PC
asm                       <1740> 0x12a6554cc:    stp	x16, x16, [sp, #-0x10]!
asm                       <1744> 0x12a6554d0:    mov	w16, #0xa -> 10
asm                       <1748> 0x12a6554d4:    stur	x16, [sp]
asm                       <1752> 0x12a6554d8:    ldur	x16, [sp, #0x8]
asm                       <1756> 0x12a6554dc:    b	0x12a630400 -> JIT PC
asm                       <1760> 0x12a6554e0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1764> 0x12a6554e4:    mov	w16, #0
asm                       <1768> 0x12a6554e8:    stur	x16, [sp]
asm                       <1772> 0x12a6554ec:    ldur	x16, [sp, #0x8]
asm                       <1776> 0x12a6554f0:    b	0x12a630400 -> JIT PC
asm                       <1780> 0x12a6554f4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1784> 0x12a6554f8:    mov	w16, #0xb -> 11
asm                       <1788> 0x12a6554fc:    stur	x16, [sp]
asm                       <1792> 0x12a655500:    ldur	x16, [sp, #0x8]
asm                       <1796> 0x12a655504:    b	0x12a630400 -> JIT PC
asm                       <1800> 0x12a655508:    stp	x16, x16, [sp, #-0x10]!
asm                       <1804> 0x12a65550c:    orr	w16, wzr, #0xc
asm                       <1808> 0x12a655510:    stur	x16, [sp]
asm                       <1812> 0x12a655514:    ldur	x16, [sp, #0x8]
asm                       <1816> 0x12a655518:    b	0x12a630400 -> JIT PC
asm                       <1820> 0x12a65551c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1824> 0x12a655520:    mov	w16, #0xd -> 13
asm                       <1828> 0x12a655524:    stur	x16, [sp]
asm                       <1832> 0x12a655528:    ldur	x16, [sp, #0x8]
asm                       <1836> 0x12a65552c:    b	0x12a630400 -> JIT PC
asm                       <1840> 0x12a655530:    stp	x16, x16, [sp, #-0x10]!
asm                       <1844> 0x12a655534:    orr	w16, wzr, #0xe
asm                       <1848> 0x12a655538:    stur	x16, [sp]
asm                       <1852> 0x12a65553c:    ldur	x16, [sp, #0x8]
asm                       <1856> 0x12a655540:    b	0x12a630400 -> JIT PC
asm                       <1860> 0x12a655544:    stp	x16, x16, [sp, #-0x10]!
asm                       <1864> 0x12a655548:    orr	w16, wzr, #0xf
asm                       <1868> 0x12a65554c:    stur	x16, [sp]
asm                       <1872> 0x12a655550:    ldur	x16, [sp, #0x8]
asm                       <1876> 0x12a655554:    b	0x12a630400 -> JIT PC
asm                       <1880> 0x12a655558:    sub	w8, w8, #0x1
asm                       <1884> 0x12a65555c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1888> 0x12a655560:    orr	w16, wzr, #0x10
asm                       <1892> 0x12a655564:    stur	x16, [sp]
asm                       <1896> 0x12a655568:    ldur	x16, [sp, #0x8]
asm                       <1900> 0x12a65556c:    b	0x12a630400 -> JIT PC
asm                       <1904> 0x12a655570:    stp	x16, x16, [sp, #-0x10]!
asm                       <1908> 0x12a655574:    mov	w16, #0x11 -> 17
asm                       <1912> 0x12a655578:    stur	x16, [sp]
asm                       <1916> 0x12a65557c:    ldur	x16, [sp, #0x8]
asm                       <1920> 0x12a655580:    b	0x12a630400 -> JIT PC
asm                       <1924> 0x12a655584:    stp	x16, x16, [sp, #-0x10]!
asm                       <1928> 0x12a655588:    mov	w16, #0x12 -> 18
asm                       <1932> 0x12a65558c:    stur	x16, [sp]
asm                       <1936> 0x12a655590:    ldur	x16, [sp, #0x8]
asm                       <1940> 0x12a655594:    b	0x12a630400 -> JIT PC
asm                       <1944> 0x12a655598:    stp	x16, x16, [sp, #-0x10]!
asm                       <1948> 0x12a65559c:    mov	w16, #0x13 -> 19
asm                       <1952> 0x12a6555a0:    stur	x16, [sp]
asm                       <1956> 0x12a6555a4:    ldur	x16, [sp, #0x8]
asm                       <1960> 0x12a6555a8:    b	0x12a630400 -> JIT PC
asm                       <1964> 0x12a6555ac:    stp	x16, x16, [sp, #-0x10]!
asm                       <1968> 0x12a6555b0:    mov	w16, #0x14 -> 20
asm                       <1972> 0x12a6555b4:    stur	x16, [sp]
asm                       <1976> 0x12a6555b8:    ldur	x16, [sp, #0x8]
asm                       <1980> 0x12a6555bc:    b	0x12a630400 -> JIT PC
asm                       <1984> 0x12a6555c0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1988> 0x12a6555c4:    mov	w16, #0x15 -> 21
asm                       <1992> 0x12a6555c8:    stur	x16, [sp]
asm                       <1996> 0x12a6555cc:    ldur	x16, [sp, #0x8]
asm                       <2000> 0x12a6555d0:    b	0x12a630400 -> JIT PC
asm                       <2004> 0x12a6555d4:    stp	x16, x16, [sp, #-0x10]!
asm                       <2008> 0x12a6555d8:    mov	w16, #0x16 -> 22
asm                       <2012> 0x12a6555dc:    stur	x16, [sp]
asm                       <2016> 0x12a6555e0:    ldur	x16, [sp, #0x8]
asm                       <2020> 0x12a6555e4:    b	0x12a630400 -> JIT PC
asm                       <2024> 0x12a6555e8:    stp	x16, x16, [sp, #-0x10]!
asm                       <2028> 0x12a6555ec:    mov	w16, #0x17 -> 23
asm                       <2032> 0x12a6555f0:    stur	x16, [sp]
asm                       <2036> 0x12a6555f4:    ldur	x16, [sp, #0x8]
asm                       <2040> 0x12a6555f8:    b	0x12a630400 -> JIT PC
asm                       <2044> 0x12a6555fc:    stp	x16, x16, [sp, #-0x10]!
asm                       <2048> 0x12a655600:    orr	w16, wzr, #0x18
asm                       <2052> 0x12a655604:    stur	x16, [sp]
asm                       <2056> 0x12a655608:    ldur	x16, [sp, #0x8]
asm                       <2060> 0x12a65560c:    b	0x12a630400 -> JIT PC
asm                       <2064> 0x12a655610:    stp	x16, x16, [sp, #-0x10]!
asm                       <2068> 0x12a655614:    mov	w16, #0x19 -> 25
asm                       <2072> 0x12a655618:    stur	x16, [sp]
asm                       <2076> 0x12a65561c:    ldur	x16, [sp, #0x8]
asm                       <2080> 0x12a655620:    b	0x12a630400 -> JIT PC
asm                       <2084> 0x12a655624:    stp	x16, x16, [sp, #-0x10]!
asm                       <2088> 0x12a655628:    mov	w16, #0x1a -> 26
asm                       <2092> 0x12a65562c:    stur	x16, [sp]
asm                       <2096> 0x12a655630:    ldur	x16, [sp, #0x8]
asm                       <2100> 0x12a655634:    b	0x12a630400 -> JIT PC
asm                       <2104> 0x12a655638:    stp	x16, x16, [sp, #-0x10]!
asm                       <2108> 0x12a65563c:    mov	w16, #0x1b -> 27
asm                       <2112> 0x12a655640:    stur	x16, [sp]
asm                       <2116> 0x12a655644:    ldur	x16, [sp, #0x8]
asm                       <2120> 0x12a655648:    b	0x12a630400 -> JIT PC
asm                       <2124> 0x12a65564c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2128> 0x12a655650:    orr	w16, wzr, #0x1c
asm                       <2132> 0x12a655654:    stur	x16, [sp]
asm                       <2136> 0x12a655658:    ldur	x16, [sp, #0x8]
asm                       <2140> 0x12a65565c:    b	0x12a630400 -> JIT PC
asm                       <2144> 0x12a655660:    sub	w1, w1, #0x1
asm                       <2148> 0x12a655664:    stp	x16, x16, [sp, #-0x10]!
asm                       <2152> 0x12a655668:    mov	w16, #0x1d -> 29
asm                       <2156> 0x12a65566c:    stur	x16, [sp]
asm                       <2160> 0x12a655670:    ldur	x16, [sp, #0x8]
asm                       <2164> 0x12a655674:    b	0x12a630400 -> JIT PC
asm                       <2168> 0x12a655678:    orr	w16, wzr, #0x4
asm                       <2172> 0x12a65567c:    stur	w16, [fp, #0x24]
asm                       <2176> 0x12a655680:    sub	sp, sp, #0x10
asm                       <2180> 0x12a655684:    mov	x1, x21
asm                       <2184> 0x12a655688:    mov	x0, #0x7b80
asm                       <2188> 0x12a65568c:    movk	x0, #0xe1b, lsl #0x10
asm                       <2192> 0x12a655690:    movk	x0, #0x1, lsl #0x20 -> 0x10e1b7b80
asm                       <2196> 0x12a655694:    mov	lr, #0xda9 -> 0xda9 JITThunkPtrTag ?
asm                       <2200> 0x12a655698:    mov	x16, #0
asm                       <2204> 0x12a65569c:    movk	x16, #0, lsl #0x10
asm                       <2208> 0x12a6556a0:    movk	x16, #0, lsl #0x20
asm                       <2212> 0x12a6556a4:    movk	x16, #0, lsl #0x30
asm                       <2216> 0x12a6556a8:    blrab	x16, lr
asm                       <2220> 0x12a6556ac:    add	sp, sp, #0x10
asm                       <2224> 0x12a6556b0:    mov	x17, #0x6008; Exception check from vm
asm                       <2228> 0x12a6556b4:    movk	x17, #0xf42, lsl #0x10
asm                       <2232> 0x12a6556b8:    movk	x17, #0x1, lsl #0x20 -> 0x10f426008 vm +8: vm.m_exception
asm                       <2236> 0x12a6556bc:    ldr	x16, [x17, xzr]
asm                       <2240> 0x12a6556c0:    cbnz	x16, 0x12a6556c0 -> <2240>
asm                       <2244> 0x12a6556c4:    nop
asm                       <2248> 0x12a6556c8:    b	0x12a655018 -> <536>
asm                       <2252> 0x12a6556cc:    stp	x16, x16, [sp, #-0x10]!
asm                       <2256> 0x12a6556d0:    orr	w16, wzr, #0x1
asm                       <2260> 0x12a6556d4:    stur	x16, [sp]
asm                       <2264> 0x12a6556d8:    ldur	x16, [sp, #0x8]
asm                       <2268> 0x12a6556dc:    b	0x12a630400 -> JIT PC
asm                       <2272> 0x12a6556e0:    stp	x16, x16, [sp, #-0x10]!
asm                       <2276> 0x12a6556e4:    orr	w16, wzr, #0x1e
asm                       <2280> 0x12a6556e8:    stur	x16, [sp]
asm                       <2284> 0x12a6556ec:    ldur	x16, [sp, #0x8]
asm                       <2288> 0x12a6556f0:    b	0x12a630400 -> JIT PC
asm                       <2292> 0x12a6556f4:    stp	x16, x16, [sp, #-0x10]!
asm                       <2296> 0x12a6556f8:    orr	w16, wzr, #0x2
asm                       <2300> 0x12a6556fc:    stur	x16, [sp]
asm                       <2304> 0x12a655700:    ldur	x16, [sp, #0x8]
asm                       <2308> 0x12a655704:    b	0x12a630400 -> JIT PC
asm                       <2312> 0x12a655708:    stp	x16, x16, [sp, #-0x10]!
asm                       <2316> 0x12a65570c:    orr	w16, wzr, #0x1f
asm                       <2320> 0x12a655710:    stur	x16, [sp]
asm                       <2324> 0x12a655714:    ldur	x16, [sp, #0x8]
asm                       <2328> 0x12a655718:    b	0x12a630400 -> JIT PC
asm                       <2332> 0x12a65571c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2336> 0x12a655720:    orr	w16, wzr, #0x20
asm                       <2340> 0x12a655724:    stur	x16, [sp]
asm                       <2344> 0x12a655728:    ldur	x16, [sp, #0x8]
asm                       <2348> 0x12a65572c:    b	0x12a630400 -> JIT PC
asm                       <2352> 0x12a655730:    stp	x16, x16, [sp, #-0x10]!
asm                       <2356> 0x12a655734:    mov	w16, #0x21 -> 33
asm                       <2360> 0x12a655738:    stur	x16, [sp]
asm                       <2364> 0x12a65573c:    ldur	x16, [sp, #0x8]
asm                       <2368> 0x12a655740:    b	0x12a630400 -> JIT PC
asm                       <2372> 0x12a655744:    stp	x16, x16, [sp, #-0x10]!
asm                       <2376> 0x12a655748:    mov	w16, #0x22 -> 34
asm                       <2380> 0x12a65574c:    stur	x16, [sp]
asm                       <2384> 0x12a655750:    ldur	x16, [sp, #0x8]
asm                       <2388> 0x12a655754:    b	0x12a630400 -> JIT PC
asm                       <2392> 0x12a655758:    stp	x16, x16, [sp, #-0x10]!
asm                       <2396> 0x12a65575c:    mov	w16, #0x23 -> 35
asm                       <2400> 0x12a655760:    stur	x16, [sp]
asm                       <2404> 0x12a655764:    ldur	x16, [sp, #0x8]
asm                       <2408> 0x12a655768:    b	0x12a630400 -> JIT PC
asm                       <2412> 0x12a65576c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2416> 0x12a655770:    mov	w16, #0x24 -> 36
asm                       <2420> 0x12a655774:    stur	x16, [sp]
asm                       <2424> 0x12a655778:    ldur	x16, [sp, #0x8]
asm                       <2428> 0x12a65577c:    b	0x12a630400 -> JIT PC
asm                       <2432> 0x12a655780:    stp	x16, x16, [sp, #-0x10]!
asm                       <2436> 0x12a655784:    mov	w16, #0x25 -> 37
asm                       <2440> 0x12a655788:    stur	x16, [sp]
asm                       <2444> 0x12a65578c:    ldur	x16, [sp, #0x8]
asm                       <2448> 0x12a655790:    b	0x12a630400 -> JIT PC
asm                       <2452> 0x12a655794:    stp	x16, x16, [sp, #-0x10]!
asm                       <2456> 0x12a655798:    mov	w16, #0x26 -> 38
asm                       <2460> 0x12a65579c:    stur	x16, [sp]
asm                       <2464> 0x12a6557a0:    ldur	x16, [sp, #0x8]
asm                       <2468> 0x12a6557a4:    b	0x12a630400 -> JIT PC
asm                       <2472> 0x12a6557a8:    stp	x16, x16, [sp, #-0x10]!
asm                       <2476> 0x12a6557ac:    mov	w16, #0x27 -> 39
asm                       <2480> 0x12a6557b0:    stur	x16, [sp]
asm                       <2484> 0x12a6557b4:    ldur	x16, [sp, #0x8]
asm                       <2488> 0x12a6557b8:    b	0x12a630400 -> JIT PC
asm                       <2492> 0x12a6557bc:    stp	x16, x16, [sp, #-0x10]!
asm                       <2496> 0x12a6557c0:    mov	w16, #0x28 -> 40
asm                       <2500> 0x12a6557c4:    stur	x16, [sp]
asm                       <2504> 0x12a6557c8:    ldur	x16, [sp, #0x8]
asm                       <2508> 0x12a6557cc:    b	0x12a630400 -> JIT PC
asm                       <2512> 0x12a6557d0:    stp	x16, x16, [sp, #-0x10]!
asm                       <2516> 0x12a6557d4:    mov	w16, #0x29 -> 41
asm                       <2520> 0x12a6557d8:    stur	x16, [sp]
asm                       <2524> 0x12a6557dc:    ldur	x16, [sp, #0x8]
asm                       <2528> 0x12a6557e0:    b	0x12a630400 -> JIT PC
asm                       <2532> 0x12a6557e4:    sub	w11, w11, #0x1
asm                       <2536> 0x12a6557e8:    stp	x16, x16, [sp, #-0x10]!
asm                       <2540> 0x12a6557ec:    mov	w16, #0x2a -> 42
asm                       <2544> 0x12a6557f0:    stur	x16, [sp]
asm                       <2548> 0x12a6557f4:    ldur	x16, [sp, #0x8]
asm                       <2552> 0x12a6557f8:    b	0x12a630400 -> JIT PC
asm                       <2556> 0x12a6557fc:    stp	x16, x16, [sp, #-0x10]!
asm                       <2560> 0x12a655800:    mov	w16, #0x2b -> 43
asm                       <2564> 0x12a655804:    stur	x16, [sp]
asm                       <2568> 0x12a655808:    ldur	x16, [sp, #0x8]
asm                       <2572> 0x12a65580c:    b	0x12a630400 -> JIT PC
asm                       <2576> 0x12a655810:    sub	w10, w10, #0x1
asm                       <2580> 0x12a655814:    stp	x16, x16, [sp, #-0x10]!
asm                       <2584> 0x12a655818:    mov	w16, #0x2c -> 44
asm                       <2588> 0x12a65581c:    stur	x16, [sp]
asm                       <2592> 0x12a655820:    ldur	x16, [sp, #0x8]
asm                       <2596> 0x12a655824:    b	0x12a630400 -> JIT PC
asm                       <2600> 0x12a655828:    stp	x16, x16, [sp, #-0x10]!
asm                       <2604> 0x12a65582c:    mov	w16, #0x2d -> 45
asm                       <2608> 0x12a655830:    stur	x16, [sp]
asm                       <2612> 0x12a655834:    ldur	x16, [sp, #0x8]
asm                       <2616> 0x12a655838:    b	0x12a630400 -> JIT PC
asm                       <2620> 0x12a65583c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2624> 0x12a655840:    mov	w16, #0x2e -> 46
asm                       <2628> 0x12a655844:    stur	x16, [sp]
asm                       <2632> 0x12a655848:    ldur	x16, [sp, #0x8]
asm                       <2636> 0x12a65584c:    b	0x12a630400 -> JIT PC
asm                       <2640> 0x12a655850:    stp	x16, x16, [sp, #-0x10]!
asm                       <2644> 0x12a655854:    mov	w16, #0x2f -> 47
asm                       <2648> 0x12a655858:    stur	x16, [sp]
asm                       <2652> 0x12a65585c:    ldur	x16, [sp, #0x8]
asm                       <2656> 0x12a655860:    b	0x12a630400 -> JIT PC
asm                       <2660> 0x12a655864:    stp	x16, x16, [sp, #-0x10]!
asm                       <2664> 0x12a655868:    orr	w16, wzr, #0x30
asm                       <2668> 0x12a65586c:    stur	x16, [sp]
asm                       <2672> 0x12a655870:    ldur	x16, [sp, #0x8]
asm                       <2676> 0x12a655874:    b	0x12a630400 -> JIT PC
asm                       <2680> 0x12a655878:    stp	x16, x16, [sp, #-0x10]!
asm                       <2684> 0x12a65587c:    mov	w16, #0x31 -> 49
asm                       <2688> 0x12a655880:    stur	x16, [sp]
asm                       <2692> 0x12a655884:    ldur	x16, [sp, #0x8]
asm                       <2696> 0x12a655888:    b	0x12a630400 -> JIT PC
asm                       <2700> 0x12a65588c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2704> 0x12a655890:    mov	w16, #0x32 -> 50
asm                       <2708> 0x12a655894:    stur	x16, [sp]
asm                       <2712> 0x12a655898:    ldur	x16, [sp, #0x8]
asm                       <2716> 0x12a65589c:    b	0x12a630400 -> JIT PC
asm                       <2720> 0x12a6558a0:    stp	x16, x16, [sp, #-0x10]!
asm                       <2724> 0x12a6558a4:    mov	w16, #0x33 -> 51
asm                       <2728> 0x12a6558a8:    stur	x16, [sp]
asm                       <2732> 0x12a6558ac:    ldur	x16, [sp, #0x8]
asm                       <2736> 0x12a6558b0:    b	0x12a630400 -> JIT PC
asm                       <2740> 0x12a6558b4:    stp	x16, x16, [sp, #-0x10]!
asm                       <2744> 0x12a6558b8:    mov	w16, #0x34 -> 52
asm                       <2748> 0x12a6558bc:    stur	x16, [sp]
asm                       <2752> 0x12a6558c0:    ldur	x16, [sp, #0x8]
asm                       <2756> 0x12a6558c4:    b	0x12a630400 -> JIT PC
asm                       <2760> 0x12a6558c8:    sub	w14, w14, #0x1
asm                       <2764> 0x12a6558cc:    stp	x16, x16, [sp, #-0x10]!
asm                       <2768> 0x12a6558d0:    mov	w16, #0x35 -> 53
asm                       <2772> 0x12a6558d4:    stur	x16, [sp]
asm                       <2776> 0x12a6558d8:    ldur	x16, [sp, #0x8]
asm                       <2780> 0x12a6558dc:    b	0x12a630400 -> JIT PC
asm                       <2784> 0x12a6558e0:    stp	x16, x16, [sp, #-0x10]!
asm                       <2788> 0x12a6558e4:    mov	w16, #0x36 -> 54
asm                       <2792> 0x12a6558e8:    stur	x16, [sp]
asm                       <2796> 0x12a6558ec:    ldur	x16, [sp, #0x8]
asm                       <2800> 0x12a6558f0:    b	0x12a630400 -> JIT PC
asm                       <2804> 0x12a6558f4:    stp	x16, x16, [sp, #-0x10]!
asm                       <2808> 0x12a6558f8:    mov	w16, #0x37 -> 55
asm                       <2812> 0x12a6558fc:    stur	x16, [sp]
asm                       <2816> 0x12a655900:    ldur	x16, [sp, #0x8]
asm                       <2820> 0x12a655904:    b	0x12a630400 -> JIT PC
asm                       <2824> 0x12a655908:    stp	x16, x16, [sp, #-0x10]!
asm                       <2828> 0x12a65590c:    orr	w16, wzr, #0x38
asm                       <2832> 0x12a655910:    stur	x16, [sp]
asm                       <2836> 0x12a655914:    ldur	x16, [sp, #0x8]
asm                       <2840> 0x12a655918:    b	0x12a630400 -> JIT PC
asm                       <2844> 0x12a65591c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2848> 0x12a655920:    mov	w16, #0x39 -> 57
asm                       <2852> 0x12a655924:    stur	x16, [sp]
asm                       <2856> 0x12a655928:    ldur	x16, [sp, #0x8]
asm                       <2860> 0x12a65592c:    b	0x12a630400 -> JIT PC
asm                       <2864> 0x12a655930:    stp	x16, x16, [sp, #-0x10]!
asm                       <2868> 0x12a655934:    mov	w16, #0x3a -> 58
asm                       <2872> 0x12a655938:    stur	x16, [sp]
asm                       <2876> 0x12a65593c:    ldur	x16, [sp, #0x8]
asm                       <2880> 0x12a655940:    b	0x12a630400 -> JIT PC
asm                       <2884> 0x12a655944:    stp	x16, x16, [sp, #-0x10]!
asm                       <2888> 0x12a655948:    mov	w16, #0x3b -> 59
asm                       <2892> 0x12a65594c:    stur	x16, [sp]
asm                       <2896> 0x12a655950:    ldur	x16, [sp, #0x8]
asm                       <2900> 0x12a655954:    b	0x12a630400 -> JIT PC
asm                       <2904> 0x12a655958:    stp	x16, x16, [sp, #-0x10]!
asm                       <2908> 0x12a65595c:    orr	w16, wzr, #0x3c
asm                       <2912> 0x12a655960:    stur	x16, [sp]
asm                       <2916> 0x12a655964:    ldur	x16, [sp, #0x8]
asm                       <2920> 0x12a655968:    b	0x12a630400 -> JIT PC
asm                       <2924> 0x12a65596c:    stp	x16, x16, [sp, #-0x10]!
asm                       <2928> 0x12a655970:    mov	w16, #0x3d -> 61
asm                       <2932> 0x12a655974:    stur	x16, [sp]
asm                       <2936> 0x12a655978:    ldur	x16, [sp, #0x8]
asm                       <2940> 0x12a65597c:    b	0x12a630400 -> JIT PC
asm                       <2944> 0x12a655980:    stp	x16, x16, [sp, #-0x10]!
asm                       <2948> 0x12a655984:    orr	w16, wzr, #0x3e
asm                       <2952> 0x12a655988:    stur	x16, [sp]
asm                       <2956> 0x12a65598c:    ldur	x16, [sp, #0x8]
asm                       <2960> 0x12a655990:    b	0x12a630400 -> JIT PC
asm                       <2964> 0x12a655994:    stp	x16, x16, [sp, #-0x10]!
asm                       <2968> 0x12a655998:    orr	w16, wzr, #0x3f
asm                       <2972> 0x12a65599c:    stur	x16, [sp]
asm                       <2976> 0x12a6559a0:    ldur	x16, [sp, #0x8]
asm                       <2980> 0x12a6559a4:    b	0x12a630400 -> JIT PC
asm                       <2984> 0x12a6559a8:    stp	x16, x16, [sp, #-0x10]!
asm                       <2988> 0x12a6559ac:    orr	w16, wzr, #0x40
asm                       <2992> 0x12a6559b0:    stur	x16, [sp]
asm                       <2996> 0x12a6559b4:    ldur	x16, [sp, #0x8]
asm                       <3000> 0x12a6559b8:    b	0x12a630400 -> JIT PC
asm                       <3004> 0x12a6559bc:    sub	w13, w13, #0x1
asm                       <3008> 0x12a6559c0:    stp	x16, x16, [sp, #-0x10]!
asm                       <3012> 0x12a6559c4:    mov	w16, #0x41 -> 65
asm                       <3016> 0x12a6559c8:    stur	x16, [sp]
asm                       <3020> 0x12a6559cc:    ldur	x16, [sp, #0x8]
asm                       <3024> 0x12a6559d0:    b	0x12a630400 -> JIT PC
asm                       <3028> 0x12a6559d4:    orr	w16, wzr, #0x4
asm                       <3032> 0x12a6559d8:    stur	w16, [fp, #0x24]
asm                       <3036> 0x12a6559dc:    sub	sp, sp, #0x10
asm                       <3040> 0x12a6559e0:    mov	x1, x21
asm                       <3044> 0x12a6559e4:    mov	x0, #0x7f00
asm                       <3048> 0x12a6559e8:    movk	x0, #0xe1b, lsl #0x10
asm                       <3052> 0x12a6559ec:    movk	x0, #0x1, lsl #0x20 -> 0x10e1b7f00
asm                       <3056> 0x12a6559f0:    mov	lr, #0xda9 -> 0xda9 JITThunkPtrTag ?
asm                       <3060> 0x12a6559f4:    mov	x16, #0
asm                       <3064> 0x12a6559f8:    movk	x16, #0, lsl #0x10
asm                       <3068> 0x12a6559fc:    movk	x16, #0, lsl #0x20
asm                       <3072> 0x12a655a00:    movk	x16, #0, lsl #0x30
asm                       <3076> 0x12a655a04:    blrab	x16, lr
asm                       <3080> 0x12a655a08:    add	sp, sp, #0x10
asm                       <3084> 0x12a655a0c:    mov	x17, #0x6008; Exception check from vm
asm                       <3088> 0x12a655a10:    movk	x17, #0xf42, lsl #0x10
asm                       <3092> 0x12a655a14:    movk	x17, #0x1, lsl #0x20 -> 0x10f426008 vm +8: vm.m_exception
asm                       <3096> 0x12a655a18:    ldr	x16, [x17, xzr]
asm                       <3100> 0x12a655a1c:    cbnz	x16, 0x12a655a1c -> <3100>
asm                       <3104> 0x12a655a20:    nop
asm                       <3108> 0x12a655a24:    b	0x12a655318 -> <1304>
asm                       <3112> 0x12a655a28:    stp	x16, x16, [sp, #-0x10]!
asm                       <3116> 0x12a655a2c:    orr	w16, wzr, #0x3
asm                       <3120> 0x12a655a30:    stur	x16, [sp]
asm                       <3124> 0x12a655a34:    ldur	x16, [sp, #0x8]
asm                       <3128> 0x12a655a38:    b	0x12a630400 -> JIT PC
asm                       <3132> 0x12a655a3c:    sub	w1, w1, #0x1
asm                       <3136> 0x12a655a40:    stp	x16, x16, [sp, #-0x10]!
asm                       <3140> 0x12a655a44:    mov	w16, #0x42 -> 66
asm                       <3144> 0x12a655a48:    stur	x16, [sp]
asm                       <3148> 0x12a655a4c:    ldur	x16, [sp, #0x8]
asm                       <3152> 0x12a655a50:    b	0x12a630400 -> JIT PC
asm                       <3156> 0x12a655a54:    sub	w1, w1, #0x1
asm                       <3160> 0x12a655a58:    stp	x16, x16, [sp, #-0x10]!
asm                       <3164> 0x12a655a5c:    mov	w16, #0x43 -> 67
asm                       <3168> 0x12a655a60:    stur	x16, [sp]
asm                       <3172> 0x12a655a64:    ldur	x16, [sp, #0x8]
asm                       <3176> 0x12a655a68:    b	0x12a630400 -> JIT PC
asm                       <3180> 0x12a655a6c:    sub	w1, w1, #0x1
asm                       <3184> 0x12a655a70:    stp	x16, x16, [sp, #-0x10]!
asm                       <3188> 0x12a655a74:    mov	w16, #0x44 -> 68
asm                       <3192> 0x12a655a78:    stur	x16, [sp]
asm                       <3196> 0x12a655a7c:    ldur	x16, [sp, #0x8]
asm                       <3200> 0x12a655a80:    b	0x12a630400 -> JIT PC
asm                       <3204> 0x12a655a84:    sub	w1, w1, #0x1
asm                       <3208> 0x12a655a88:    stp	x16, x16, [sp, #-0x10]!
asm                       <3212> 0x12a655a8c:    mov	w16, #0x45 -> 69
asm                       <3216> 0x12a655a90:    stur	x16, [sp]
asm                       <3220> 0x12a655a94:    ldur	x16, [sp, #0x8]
asm                       <3224> 0x12a655a98:    b	0x12a630400 -> JIT PC
asm                       <3228> 0x12a655a9c:    mov	w16, #0x5 -> 5
asm                       <3232> 0x12a655aa0:    stur	w16, [fp, #0x24]
asm                       <3236> 0x12a655aa4:    sub	sp, sp, #0x10
asm                       <3240> 0x12a655aa8:    mov	x1, x21
asm                       <3244> 0x12a655aac:    mov	x0, #0x4880
asm                       <3248> 0x12a655ab0:    movk	x0, #0xe1b, lsl #0x10
asm                       <3252> 0x12a655ab4:    movk	x0, #0x1, lsl #0x20 -> 0x10e1b4880
asm                       <3256> 0x12a655ab8:    mov	lr, #0xda9 -> 0xda9 JITThunkPtrTag ?
asm                       <3260> 0x12a655abc:    mov	x16, #0
asm                       <3264> 0x12a655ac0:    movk	x16, #0, lsl #0x10
asm                       <3268> 0x12a655ac4:    movk	x16, #0, lsl #0x20
asm                       <3272> 0x12a655ac8:    movk	x16, #0, lsl #0x30
asm                       <3276> 0x12a655acc:    blrab	x16, lr
asm                       <3280> 0x12a655ad0:    add	sp, sp, #0x10
asm                       <3284> 0x12a655ad4:    mov	x17, #0x6008; Exception check from vm
asm                       <3288> 0x12a655ad8:    movk	x17, #0xf42, lsl #0x10
asm                       <3292> 0x12a655adc:    movk	x17, #0x1, lsl #0x20 -> 0x10f426008 vm +8: vm.m_exception
asm                       <3296> 0x12a655ae0:    ldr	x16, [x17, xzr]
asm                       <3300> 0x12a655ae4:    cbnz	x16, 0x12a655ae4 -> <3300>
asm                       <3304> 0x12a655ae8:    nop
asm                       <3308> 0x12a655aec:    b	0x12a6553d0 -> <1488>
asm                       <3312> 0x12a655af0:    stp	x16, x16, [sp, #-0x10]!
asm                       <3316> 0x12a655af4:    orr	w16, wzr, #0x4
asm                       <3320> 0x12a655af8:    stur	x16, [sp]
asm                       <3324> 0x12a655afc:    ldur	x16, [sp, #0x8]
asm                       <3328> 0x12a655b00:    b	0x12a630400 -> JIT PC
asm                       <3332> 0x12a655b04:    sub	w28, w28, #0x1
asm                       <3336> 0x12a655b08:    stp	x16, x16, [sp, #-0x10]!
asm                       <3340> 0x12a655b0c:    mov	w16, #0x46 -> 70
asm                       <3344> 0x12a655b10:    stur	x16, [sp]
asm                       <3348> 0x12a655b14:    ldur	x16, [sp, #0x8]
asm                       <3352> 0x12a655b18:    b	0x12a630400 -> JIT PC
asm                       <3356> 0x12a655b1c:    stp	x16, x16, [sp, #-0x10]!
asm                       <3360> 0x12a655b20:    mov	w16, #0x47 -> 71
asm                       <3364> 0x12a655b24:    stur	x16, [sp]
asm                       <3368> 0x12a655b28:    ldur	x16, [sp, #0x8]
asm                       <3372> 0x12a655b2c:    b	0x12a630400 -> JIT PC
asm                       <3376> 0x12a655b30:    b	0x12a614080 -> JIT PC
asm                       <3380> 0x12a655b34:    ldur	w2, [sp, #0x10]
asm                       <3384> 0x12a655b38:    cmp	w2, #0x6
asm                       <3388> 0x12a655b3c:    b.hs	0x12a654e00 -> <0>
asm                       <3392> 0x12a655b40:    orr	w0, wzr, #0x7
asm                       <3396> 0x12a655b44:    sub	w0, w0, w2
asm                       <3400> 0x12a655b48:    add	w1, w0, #0x1
asm                       <3404> 0x12a655b4c:    and	w1, w1, #0xfffffffe
asm                       <3408> 0x12a655b50:    lsl	x1, x1, #0x3
asm                       <3412> 0x12a655b54:    sub	x3, sp, x1
asm                       <3416> 0x12a655b58:    mov	x17, #0x6068
asm                       <3420> 0x12a655b5c:    movk	x17, #0xf42, lsl #0x10
asm                       <3424> 0x12a655b60:    movk	x17, #0x1, lsl #0x20 -> 0x10f426068 vm +104: vm.softStackLimit()
asm                       <3428> 0x12a655b64:    ldr	x16, [x17, xzr]
asm                       <3432> 0x12a655b68:    cmp	x16, x3
asm                       <3436> 0x12a655b6c:    b.gt	0x12a655b88 -> <3464>
asm                       <3440> 0x12a655b70:    pacizb	lr
asm                       <3444> 0x12a655b74:    mov	x1, lr
asm                       <3448> 0x12a655b78:    bl	0x12a614000 -> JIT PC
asm                       <3452> 0x12a655b7c:    mov	lr, x1
asm                       <3456> 0x12a655b80:    autizb	lr
asm                       <3460> 0x12a655b84:    b	0x12a654e00 -> <0>
asm                       <3464> 0x12a655b88:    pacibsp
asm                       <3468> 0x12a655b8c:    stp	fp, lr, [sp, #-0x10]!
asm                       <3472> 0x12a655b90:    mov	fp, sp
asm                       <3476> 0x12a655b94:    b	0x12a61c000 -> JIT PC
asm                       <3480> 0x12a655b98:    brk	#0xbb08
asm                       <3484> 0x12a655b9c:    brk	#0xbb08
