asm                          <0> 0x12a656500:    pacibsp
asm                          <4> 0x12a656504:    stp	fp, lr, [sp, #-0x10]!
asm                          <8> 0x12a656508:    mov	fp, sp
asm                         <12> 0x12a65650c:    sub	x0, fp, #0x110
asm                         <16> 0x12a656510:    mov	x17, #0x6068
asm                         <20> 0x12a656514:    movk	x17, #0xf42, lsl #0x10
asm                         <24> 0x12a656518:    movk	x17, #0x1, lsl #0x20 -> 0x10f426068 vm +104: vm.softStackLimit()
asm                         <28> 0x12a65651c:    ldr	x16, [x17, xzr]
asm                         <32> 0x12a656520:    cmp	x16, x0
asm                         <36> 0x12a656524:    b.gt	0x12a61c000 -> JIT PC
asm                         <40> 0x12a656528:    sub	sp, sp, #0xa0
asm                         <44> 0x12a65652c:    stp	x19, x20, [fp, #-0x40]
asm                         <48> 0x12a656530:    stp	x21, x22, [fp, #-0x30]
asm                         <52> 0x12a656534:    stp	x23, x24, [fp, #-0x20]
asm                         <56> 0x12a656538:    stur	x25, [fp, #-0x10]
asm                         <60> 0x12a65653c:    ldur	x11, [fp, #0x50]
asm                         <64> 0x12a656540:    mov	x1, #0x2
asm                         <68> 0x12a656544:    movk	x1, #0xfffe, lsl #0x30 -> 0xfffe000000000002
asm                         <72> 0x12a656548:    tst	x11, x1
asm                         <76> 0x12a65654c:    b.ne	0x12a656960 -> <1120>
asm                         <80> 0x12a656550:    ldur	x2, [fp, #0x48]
asm                         <84> 0x12a656554:    tst	x2, x1
asm                         <88> 0x12a656558:    b.ne	0x12a656974 -> <1140>
asm                         <92> 0x12a65655c:    ldur	x13, [fp, #0x40]
asm                         <96> 0x12a656560:    tst	x13, x1
asm                        <100> 0x12a656564:    b.ne	0x12a656988 -> <1160>
asm                        <104> 0x12a656568:    ldur	x0, [fp, #0x38]
asm                        <108> 0x12a65656c:    tst	x0, x1
asm                        <112> 0x12a656570:    b.ne	0x12a65699c -> <1180>
asm                        <116> 0x12a656574:    ldur	x1, [fp, #0x30]
asm                        <120> 0x12a656578:    ldur	w3, [x0]
asm                        <124> 0x12a65657c:    mov	x4, #0x2780
asm                        <128> 0x12a656580:    movk	x4, #0x100, lsl #0x10 -> 0x1002780
asm                        <132> 0x12a656584:    cmp	w3, w4
asm                        <136> 0x12a656588:    b.ne	0x12a6569b0 -> <1200>
asm                        <140> 0x12a65658c:    ldur	w3, [x13]
asm                        <144> 0x12a656590:    cmp	w3, w4
asm                        <148> 0x12a656594:    b.ne	0x12a6569c4 -> <1220>
asm                        <152> 0x12a656598:    ldur	w3, [x2]
asm                        <156> 0x12a65659c:    cmp	w3, w4
asm                        <160> 0x12a6565a0:    b.ne	0x12a6569d8 -> <1240>
asm                        <164> 0x12a6565a4:    ldur	w3, [x11]
asm                        <168> 0x12a6565a8:    cmp	w3, w4
asm                        <172> 0x12a6565ac:    b.ne	0x12a6569ec -> <1260>
asm                        <176> 0x12a6565b0:    ldur	x4, [fp, #0x58]
asm                        <180> 0x12a6565b4:    mov	x8, #0x42b0; InvalidationPoint
asm                        <184> 0x12a6565b8:    movk	x8, #0xf1e, lsl #0x10
asm                        <188> 0x12a6565bc:    movk	x8, #0x1, lsl #0x20 -> 0x10f1e42b0
asm                        <192> 0x12a6565c0:    ldur	x3, [x8]
asm                        <196> 0x12a6565c4:    orr	x9, xzr, #0xfffe000000000000
asm                        <200> 0x12a6565c8:    cmp	x4, x9
asm                        <204> 0x12a6565cc:    b.lo	0x12a656854 -> <852>
asm                        <208> 0x12a6565d0:    scvtf	d1, w4
asm                        <212> 0x12a6565d4:    cmp	x3, x9
asm                        <216> 0x12a6565d8:    cset	w10, cc
asm                        <220> 0x12a6565dc:    cmp	x3, x9
asm                        <224> 0x12a6565e0:    b.lo	0x12a656874 -> <884>
asm                        <228> 0x12a6565e4:    scvtf	d3, w3
asm                        <232> 0x12a6565e8:    mov	x10, #0
asm                        <236> 0x12a6565ec:    fmul	d0, d1, d3
asm                        <240> 0x12a6565f0:    ldur	x4, [x8, #-0x18]
asm                        <244> 0x12a6565f4:    cmp	x4, x9
asm                        <248> 0x12a6565f8:    b.lo	0x12a656888 -> <904>
asm                        <252> 0x12a6565fc:    scvtf	d4, w4
asm                        <256> 0x12a656600:    fmul	d1, d1, d4
asm                        <260> 0x12a656604:    fmov	d2, #0.50000000
asm                        <264> 0x12a656608:    fadd	d3, d3, d2
asm                        <268> 0x12a65660c:    fadd	d4, d4, d2
asm                        <272> 0x12a656610:    cmp	x4, x9
asm                        <276> 0x12a656614:    b.lo	0x12a656a14 -> <1300>
asm                        <280> 0x12a656618:    fmov	d5, #1.00000000
asm                        <284> 0x12a65661c:    mov	x5, #0x29a0
asm                        <288> 0x12a656620:    movk	x5, #0xf1a, lsl #0x10
asm                        <292> 0x12a656624:    movk	x5, #0x1, lsl #0x20 -> 0x10f1a29a0
asm                        <296> 0x12a656628:    sub	x6, x8, #0xb0
asm                        <300> 0x12a65662c:    orr	x7, xzr, #0x3
asm                        <304> 0x12a656630:    cmp	w4, #0x1
asm                        <308> 0x12a656634:    b.lt	0x12a65689c -> <924>
asm                        <312> 0x12a656638:    ldur	x8, [x8, #0x28]
asm                        <316> 0x12a65663c:    cmp	x8, x9
asm                        <320> 0x12a656640:    b.lo	0x12a656a28 -> <1320>
asm                        <324> 0x12a656644:    cbnz	w10, 0x12a656a3c -> <1340>
asm                        <328> 0x12a656648:    ldur	x9, [x2, #0x8]
asm                        <332> 0x12a65664c:    ldur	w10, [x9, #-0x8]
asm                        <336> 0x12a656650:    ldur	x11, [x11, #0x8]
asm                        <340> 0x12a656654:    ldur	w12, [x11, #-0x8]
asm                        <344> 0x12a656658:    ldur	x13, [x13, #0x8]
asm                        <348> 0x12a65665c:    ldur	w14, [x13, #-0x8]
asm                        <352> 0x12a656660:    ldur	x15, [x0, #0x8]
asm                        <356> 0x12a656664:    ldur	w16, [x15, #-0x8]
asm                        <360> 0x12a656668:    cmp	w3, #0x1
asm                        <364> 0x12a65666c:    b.lt	0x12a6568f4 -> <1012>
asm                        <368> 0x12a656670:    orr	x17, xzr, #0x1
asm                        <372> 0x12a656674:    mov	x19, x8
asm                        <376> 0x12a656678:    orr	x20, xzr, #0x1
asm                        <380> 0x12a65667c:    scvtf	d6, w17
asm                        <384> 0x12a656680:    adds	w19, w19, #0x1
asm                        <388> 0x12a656684:    b.vs	0x12a656a50 -> <1360>
asm                        <392> 0x12a656688:    cmp	w10, w19
asm                        <396> 0x12a65668c:    b.ls	0x12a656a68 -> <1384>
asm                        <400> 0x12a656690:    ldr	d7, [x9, w19, uxtw #0x3]
asm                        <404> 0x12a656694:    fmul	d7, d0, d7
asm                        <408> 0x12a656698:    scvtf	d16, w20
asm                        <412> 0x12a65669c:    fsub	d7, d16, d7
asm                        <416> 0x12a6566a0:    cmp	w12, w19
asm                        <420> 0x12a6566a4:    b.ls	0x12a656a7c -> <1404>
asm                        <424> 0x12a6566a8:    ldr	d16, [x11, w19, uxtw #0x3]
asm                        <428> 0x12a6566ac:    fmul	d16, d1, d16
asm                        <432> 0x12a6566b0:    fsub	d16, d6, d16
asm                        <436> 0x12a6566b4:    fcmp	d7, d2
asm                        <440> 0x12a6566b8:    b.lo	0x12a6568fc -> <1020>
asm                        <444> 0x12a6566bc:    fcmp	d3, d7
asm                        <448> 0x12a6566c0:    b.hs	0x12a6566c8 -> <456>
asm                        <452> 0x12a6566c4:    fmov	d7, d3
asm                        <456> 0x12a6566c8:    fjcvtzs	w22, d7
asm                        <460> 0x12a6566cc:    adds	w21, w22, #0x1
asm                        <464> 0x12a6566d0:    b.vs	0x12a656a90 -> <1424>
asm                        <468> 0x12a6566d4:    fcmp	d16, d2
asm                        <472> 0x12a6566d8:    b.lo	0x12a656904 -> <1028>
asm                        <476> 0x12a6566dc:    fcmp	d4, d16
asm                        <480> 0x12a6566e0:    b.hs	0x12a6566e8 -> <488>
asm                        <484> 0x12a6566e4:    fmov	d16, d4
asm                        <488> 0x12a6566e8:    fjcvtzs	w23, d16
asm                        <492> 0x12a6566ec:    adds	w24, w23, #0x1
asm                        <496> 0x12a6566f0:    b.vs	0x12a656aa4 -> <1444>
asm                        <500> 0x12a6566f4:    scvtf	d17, w22
asm                        <504> 0x12a6566f8:    fsub	d7, d7, d17
asm                        <508> 0x12a6566fc:    fsub	d17, d5, d7
asm                        <512> 0x12a656700:    scvtf	d18, w23
asm                        <516> 0x12a656704:    fsub	d16, d16, d18
asm                        <520> 0x12a656708:    fsub	d18, d5, d16
asm                        <524> 0x12a65670c:    smull	x25, w8, w23
asm                        <528> 0x12a656710:    cmp	x25, w25, sxtw
asm                        <532> 0x12a656714:    mov	w25, w25
asm                        <536> 0x12a656718:    b.ne	0x12a656ab8 -> <1464>
asm                        <540> 0x12a65671c:    smull	x23, w8, w24
asm                        <544> 0x12a656720:    cmp	x23, w23, sxtw
asm                        <548> 0x12a656724:    mov	w23, w23
asm                        <552> 0x12a656728:    b.ne	0x12a656acc -> <1484>
asm                        <556> 0x12a65672c:    adds	w24, w22, w25
asm                        <560> 0x12a656730:    b.vs	0x12a656ae0 -> <1504>
asm                        <564> 0x12a656734:    cmp	w14, w24
asm                        <568> 0x12a656738:    b.ls	0x12a656af4 -> <1524>
asm                        <572> 0x12a65673c:    ldr	d19, [x13, w24, uxtw #0x3]
asm                        <576> 0x12a656740:    fmul	d19, d18, d19
asm                        <580> 0x12a656744:    adds	w22, w22, w23
asm                        <584> 0x12a656748:    b.vs	0x12a656b08 -> <1544>
asm                        <588> 0x12a65674c:    cmp	w14, w22
asm                        <592> 0x12a656750:    b.ls	0x12a656b20 -> <1568>
asm                        <596> 0x12a656754:    ldr	d20, [x13, w22, uxtw #0x3]
asm                        <600> 0x12a656758:    fmul	d20, d16, d20
asm                        <604> 0x12a65675c:    fadd	d19, d19, d20
asm                        <608> 0x12a656760:    fmul	d17, d17, d19
asm                        <612> 0x12a656764:    adds	w22, w21, w25
asm                        <616> 0x12a656768:    b.vs	0x12a656b34 -> <1588>
asm                        <620> 0x12a65676c:    cmp	w14, w22
asm                        <624> 0x12a656770:    b.ls	0x12a656b48 -> <1608>
asm                        <628> 0x12a656774:    ldr	d19, [x13, w22, uxtw #0x3]
asm                        <632> 0x12a656778:    fmul	d18, d18, d19
asm                        <636> 0x12a65677c:    adds	w21, w21, w23
asm                        <640> 0x12a656780:    b.vs	0x12a656b5c -> <1628>
asm                        <644> 0x12a656784:    cmp	w14, w21
asm                        <648> 0x12a656788:    b.ls	0x12a656b74 -> <1652>
asm                        <652> 0x12a65678c:    ldr	d19, [x13, w21, uxtw #0x3]
asm                        <656> 0x12a656790:    fmul	d16, d16, d19
asm                        <660> 0x12a656794:    fadd	d16, d18, d16
asm                        <664> 0x12a656798:    fmul	d7, d7, d16
asm                        <668> 0x12a65679c:    fadd	d7, d17, d7
asm                        <672> 0x12a6567a0:    cmp	w16, w19
asm                        <676> 0x12a6567a4:    b.ls	0x12a656b88 -> <1672>
asm                        <680> 0x12a6567a8:    fcmp	d7, d7
asm                        <684> 0x12a6567ac:    b.ne	0x12a656b9c -> <1692>
asm                        <688> 0x12a6567b0:    str	d7, [x15, w19, uxtw #0x3]
asm                        <692> 0x12a6567b4:    adds	w20, w20, #0x1
asm                        <696> 0x12a6567b8:    b.vs	0x12a656bb0 -> <1712>
asm                        <700> 0x12a6567bc:    cmp	w3, w20
asm                        <704> 0x12a6567c0:    b.ge	0x12a656680 -> <384>
asm                        <708> 0x12a6567c4:    adds	w17, w17, #0x1
asm                        <712> 0x12a6567c8:    b.vs	0x12a656bc8 -> <1736>
asm                        <716> 0x12a6567cc:    cmp	w17, w4
asm                        <720> 0x12a6567d0:    b.gt	0x12a6567fc -> <764>
asm                        <724> 0x12a6567d4:    smull	x19, w17, w8
asm                        <728> 0x12a6567d8:    cmp	x19, w19, sxtw
asm                        <732> 0x12a6567dc:    mov	w19, w19
asm                        <736> 0x12a6567e0:    b.ne	0x12a656be0 -> <1760>
asm                        <740> 0x12a6567e4:    cmp	w3, #0x1
asm                        <744> 0x12a6567e8:    b.ge	0x12a656678 -> <376>
asm                        <748> 0x12a6567ec:    adds	w17, w17, #0x1
asm                        <752> 0x12a6567f0:    b.vs	0x12a656bf4 -> <1780>
asm                        <756> 0x12a6567f4:    cmp	w17, w4
asm                        <760> 0x12a6567f8:    b.le	0x12a6567d4 -> <724>
asm                        <764> 0x12a6567fc:    stur	x5, [fp, #-0x98]
asm                        <768> 0x12a656800:    stur	w7, [fp, #-0x90]
asm                        <772> 0x12a656804:    stur	x6, [fp, #-0x88]
asm                        <776> 0x12a656808:    stur	x1, [fp, #-0x80]
asm                        <780> 0x12a65680c:    stur	x0, [fp, #-0x78]
asm                        <784> 0x12a656810:    orr	w16, wzr, #0x1; DirectCallOrConstruct
asm                        <788> 0x12a656814:    stur	w16, [fp, #0x24]
asm                        <792> 0x12a656818:    mov	x16, #0
asm                        <796> 0x12a65681c:    movk	x16, #0, lsl #0x10
asm                        <800> 0x12a656820:    movk	x16, #0, lsl #0x20
asm                        <804> 0x12a656824:    movk	x16, #0, lsl #0x30
asm                        <808> 0x12a656828:    stur	x16, [sp]
asm                        <812> 0x12a65682c:    bl	0x12a65682c -> <812>
asm                        <816> 0x12a656830:    sub	sp, fp, #0xa0
asm                        <820> 0x12a656834:    mov	x0, #0xa -> 10; InvalidationPoint
asm                        <824> 0x12a656838:    ldp	x19, x20, [fp, #-0x40]
asm                        <828> 0x12a65683c:    ldp	x21, x22, [fp, #-0x30]
asm                        <832> 0x12a656840:    ldp	x23, x24, [fp, #-0x20]
asm                        <836> 0x12a656844:    ldur	x25, [fp, #-0x10]
asm                        <840> 0x12a656848:    mov	sp, fp
asm                        <844> 0x12a65684c:    ldp	fp, lr, [sp], #0x10
asm                        <848> 0x12a656850:    retab
asm                        <852> 0x12a656854:    tst	x4, #0xfffe000000000000
asm                        <856> 0x12a656858:    b.eq	0x12a656944 -> <1092>
asm                        <860> 0x12a65685c:    add	x4, x4, x9
asm                        <864> 0x12a656860:    fmov	d1, x4
asm                        <868> 0x12a656864:    cmp	x3, x9
asm                        <872> 0x12a656868:    cset	w10, cc
asm                        <876> 0x12a65686c:    cmp	x3, x9
asm                        <880> 0x12a656870:    b.hs	0x12a6565e4 -> <228>
asm                        <884> 0x12a656874:    tst	x3, #0xfffe000000000000
asm                        <888> 0x12a656878:    b.eq	0x12a656928 -> <1064>
asm                        <892> 0x12a65687c:    add	x4, x3, x9
asm                        <896> 0x12a656880:    fmov	d3, x4
asm                        <900> 0x12a656884:    b	0x12a6565ec -> <236>
asm                        <904> 0x12a656888:    tst	x4, #0xfffe000000000000
asm                        <908> 0x12a65688c:    b.eq	0x12a65690c -> <1036>
asm                        <912> 0x12a656890:    add	x5, x4, x9
asm                        <916> 0x12a656894:    fmov	d4, x5
asm                        <920> 0x12a656898:    b	0x12a656600 -> <256>
asm                        <924> 0x12a65689c:    stur	x5, [fp, #-0x98]
asm                        <928> 0x12a6568a0:    stur	w7, [fp, #-0x90]
asm                        <932> 0x12a6568a4:    stur	x6, [fp, #-0x88]
asm                        <936> 0x12a6568a8:    stur	x1, [fp, #-0x80]
asm                        <940> 0x12a6568ac:    stur	x0, [fp, #-0x78]
asm                        <944> 0x12a6568b0:    orr	w16, wzr, #0x2; DirectCallOrConstruct
asm                        <948> 0x12a6568b4:    stur	w16, [fp, #0x24]
asm                        <952> 0x12a6568b8:    mov	x16, #0
asm                        <956> 0x12a6568bc:    movk	x16, #0, lsl #0x10
asm                        <960> 0x12a6568c0:    movk	x16, #0, lsl #0x20
asm                        <964> 0x12a6568c4:    movk	x16, #0, lsl #0x30
asm                        <968> 0x12a6568c8:    stur	x16, [sp]
asm                        <972> 0x12a6568cc:    bl	0x12a6568cc -> <972>
asm                        <976> 0x12a6568d0:    sub	sp, fp, #0xa0
asm                        <980> 0x12a6568d4:    mov	x0, #0xa -> 10; InvalidationPoint
asm                        <984> 0x12a6568d8:    ldp	x19, x20, [fp, #-0x40]
asm                        <988> 0x12a6568dc:    ldp	x21, x22, [fp, #-0x30]
asm                        <992> 0x12a6568e0:    ldp	x23, x24, [fp, #-0x20]
asm                        <996> 0x12a6568e4:    ldur	x25, [fp, #-0x10]
asm                       <1000> 0x12a6568e8:    mov	sp, fp
asm                       <1004> 0x12a6568ec:    ldp	fp, lr, [sp], #0x10
asm                       <1008> 0x12a6568f0:    retab
asm                       <1012> 0x12a6568f4:    orr	x17, xzr, #0x1
asm                       <1016> 0x12a6568f8:    b	0x12a6567ec -> <748>
asm                       <1020> 0x12a6568fc:    fmov	d7, d2
asm                       <1024> 0x12a656900:    b	0x12a6566c8 -> <456>
asm                       <1028> 0x12a656904:    fmov	d16, d2
asm                       <1032> 0x12a656908:    b	0x12a6566e8 -> <488>
asm                       <1036> 0x12a65690c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1040> 0x12a656910:    orr	w16, wzr, #0x3
asm                       <1044> 0x12a656914:    stur	x16, [sp]
asm                       <1048> 0x12a656918:    ldur	x16, [sp, #0x8]
asm                       <1052> 0x12a65691c:    b	0x12a630400 -> JIT PC
asm                       <1056> 0x12a656920:    mov	w16, #0x9b -> 155
asm                       <1060> 0x12a656924:    brk	#0xbb08
asm                       <1064> 0x12a656928:    stp	x16, x16, [sp, #-0x10]!
asm                       <1068> 0x12a65692c:    orr	w16, wzr, #0x4
asm                       <1072> 0x12a656930:    stur	x16, [sp]
asm                       <1076> 0x12a656934:    ldur	x16, [sp, #0x8]
asm                       <1080> 0x12a656938:    b	0x12a630400 -> JIT PC
asm                       <1084> 0x12a65693c:    mov	w16, #0x9b -> 155
asm                       <1088> 0x12a656940:    brk	#0xbb08
asm                       <1092> 0x12a656944:    stp	x16, x16, [sp, #-0x10]!
asm                       <1096> 0x12a656948:    mov	w16, #0x5 -> 5
asm                       <1100> 0x12a65694c:    stur	x16, [sp]
asm                       <1104> 0x12a656950:    ldur	x16, [sp, #0x8]
asm                       <1108> 0x12a656954:    b	0x12a630400 -> JIT PC
asm                       <1112> 0x12a656958:    mov	w16, #0x9b -> 155
asm                       <1116> 0x12a65695c:    brk	#0xbb08
asm                       <1120> 0x12a656960:    stp	x16, x16, [sp, #-0x10]!
asm                       <1124> 0x12a656964:    orr	w16, wzr, #0x6
asm                       <1128> 0x12a656968:    stur	x16, [sp]
asm                       <1132> 0x12a65696c:    ldur	x16, [sp, #0x8]
asm                       <1136> 0x12a656970:    b	0x12a630400 -> JIT PC
asm                       <1140> 0x12a656974:    stp	x16, x16, [sp, #-0x10]!
asm                       <1144> 0x12a656978:    orr	w16, wzr, #0x7
asm                       <1148> 0x12a65697c:    stur	x16, [sp]
asm                       <1152> 0x12a656980:    ldur	x16, [sp, #0x8]
asm                       <1156> 0x12a656984:    b	0x12a630400 -> JIT PC
asm                       <1160> 0x12a656988:    stp	x16, x16, [sp, #-0x10]!
asm                       <1164> 0x12a65698c:    orr	w16, wzr, #0x8
asm                       <1168> 0x12a656990:    stur	x16, [sp]
asm                       <1172> 0x12a656994:    ldur	x16, [sp, #0x8]
asm                       <1176> 0x12a656998:    b	0x12a630400 -> JIT PC
asm                       <1180> 0x12a65699c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1184> 0x12a6569a0:    mov	w16, #0x9 -> 9
asm                       <1188> 0x12a6569a4:    stur	x16, [sp]
asm                       <1192> 0x12a6569a8:    ldur	x16, [sp, #0x8]
asm                       <1196> 0x12a6569ac:    b	0x12a630400 -> JIT PC
asm                       <1200> 0x12a6569b0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1204> 0x12a6569b4:    mov	w16, #0xa -> 10
asm                       <1208> 0x12a6569b8:    stur	x16, [sp]
asm                       <1212> 0x12a6569bc:    ldur	x16, [sp, #0x8]
asm                       <1216> 0x12a6569c0:    b	0x12a630400 -> JIT PC
asm                       <1220> 0x12a6569c4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1224> 0x12a6569c8:    mov	w16, #0xb -> 11
asm                       <1228> 0x12a6569cc:    stur	x16, [sp]
asm                       <1232> 0x12a6569d0:    ldur	x16, [sp, #0x8]
asm                       <1236> 0x12a6569d4:    b	0x12a630400 -> JIT PC
asm                       <1240> 0x12a6569d8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1244> 0x12a6569dc:    orr	w16, wzr, #0xc
asm                       <1248> 0x12a6569e0:    stur	x16, [sp]
asm                       <1252> 0x12a6569e4:    ldur	x16, [sp, #0x8]
asm                       <1256> 0x12a6569e8:    b	0x12a630400 -> JIT PC
asm                       <1260> 0x12a6569ec:    stp	x16, x16, [sp, #-0x10]!
asm                       <1264> 0x12a6569f0:    mov	w16, #0xd -> 13
asm                       <1268> 0x12a6569f4:    stur	x16, [sp]
asm                       <1272> 0x12a6569f8:    ldur	x16, [sp, #0x8]
asm                       <1276> 0x12a6569fc:    b	0x12a630400 -> JIT PC
asm                       <1280> 0x12a656a00:    stp	x16, x16, [sp, #-0x10]!
asm                       <1284> 0x12a656a04:    mov	w16, #0
asm                       <1288> 0x12a656a08:    stur	x16, [sp]
asm                       <1292> 0x12a656a0c:    ldur	x16, [sp, #0x8]
asm                       <1296> 0x12a656a10:    b	0x12a630400 -> JIT PC
asm                       <1300> 0x12a656a14:    stp	x16, x16, [sp, #-0x10]!
asm                       <1304> 0x12a656a18:    orr	w16, wzr, #0xe
asm                       <1308> 0x12a656a1c:    stur	x16, [sp]
asm                       <1312> 0x12a656a20:    ldur	x16, [sp, #0x8]
asm                       <1316> 0x12a656a24:    b	0x12a630400 -> JIT PC
asm                       <1320> 0x12a656a28:    stp	x16, x16, [sp, #-0x10]!
asm                       <1324> 0x12a656a2c:    orr	w16, wzr, #0xf
asm                       <1328> 0x12a656a30:    stur	x16, [sp]
asm                       <1332> 0x12a656a34:    ldur	x16, [sp, #0x8]
asm                       <1336> 0x12a656a38:    b	0x12a630400 -> JIT PC
asm                       <1340> 0x12a656a3c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1344> 0x12a656a40:    orr	w16, wzr, #0x10
asm                       <1348> 0x12a656a44:    stur	x16, [sp]
asm                       <1352> 0x12a656a48:    ldur	x16, [sp, #0x8]
asm                       <1356> 0x12a656a4c:    b	0x12a630400 -> JIT PC
asm                       <1360> 0x12a656a50:    sub	w19, w19, #0x1
asm                       <1364> 0x12a656a54:    stp	x16, x16, [sp, #-0x10]!
asm                       <1368> 0x12a656a58:    mov	w16, #0x11 -> 17
asm                       <1372> 0x12a656a5c:    stur	x16, [sp]
asm                       <1376> 0x12a656a60:    ldur	x16, [sp, #0x8]
asm                       <1380> 0x12a656a64:    b	0x12a630400 -> JIT PC
asm                       <1384> 0x12a656a68:    stp	x16, x16, [sp, #-0x10]!
asm                       <1388> 0x12a656a6c:    mov	w16, #0x12 -> 18
asm                       <1392> 0x12a656a70:    stur	x16, [sp]
asm                       <1396> 0x12a656a74:    ldur	x16, [sp, #0x8]
asm                       <1400> 0x12a656a78:    b	0x12a630400 -> JIT PC
asm                       <1404> 0x12a656a7c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1408> 0x12a656a80:    mov	w16, #0x13 -> 19
asm                       <1412> 0x12a656a84:    stur	x16, [sp]
asm                       <1416> 0x12a656a88:    ldur	x16, [sp, #0x8]
asm                       <1420> 0x12a656a8c:    b	0x12a630400 -> JIT PC
asm                       <1424> 0x12a656a90:    stp	x16, x16, [sp, #-0x10]!
asm                       <1428> 0x12a656a94:    mov	w16, #0x14 -> 20
asm                       <1432> 0x12a656a98:    stur	x16, [sp]
asm                       <1436> 0x12a656a9c:    ldur	x16, [sp, #0x8]
asm                       <1440> 0x12a656aa0:    b	0x12a630400 -> JIT PC
asm                       <1444> 0x12a656aa4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1448> 0x12a656aa8:    mov	w16, #0x15 -> 21
asm                       <1452> 0x12a656aac:    stur	x16, [sp]
asm                       <1456> 0x12a656ab0:    ldur	x16, [sp, #0x8]
asm                       <1460> 0x12a656ab4:    b	0x12a630400 -> JIT PC
asm                       <1464> 0x12a656ab8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1468> 0x12a656abc:    mov	w16, #0x16 -> 22
asm                       <1472> 0x12a656ac0:    stur	x16, [sp]
asm                       <1476> 0x12a656ac4:    ldur	x16, [sp, #0x8]
asm                       <1480> 0x12a656ac8:    b	0x12a630400 -> JIT PC
asm                       <1484> 0x12a656acc:    stp	x16, x16, [sp, #-0x10]!
asm                       <1488> 0x12a656ad0:    mov	w16, #0x17 -> 23
asm                       <1492> 0x12a656ad4:    stur	x16, [sp]
asm                       <1496> 0x12a656ad8:    ldur	x16, [sp, #0x8]
asm                       <1500> 0x12a656adc:    b	0x12a630400 -> JIT PC
asm                       <1504> 0x12a656ae0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1508> 0x12a656ae4:    orr	w16, wzr, #0x18
asm                       <1512> 0x12a656ae8:    stur	x16, [sp]
asm                       <1516> 0x12a656aec:    ldur	x16, [sp, #0x8]
asm                       <1520> 0x12a656af0:    b	0x12a630400 -> JIT PC
asm                       <1524> 0x12a656af4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1528> 0x12a656af8:    mov	w16, #0x19 -> 25
asm                       <1532> 0x12a656afc:    stur	x16, [sp]
asm                       <1536> 0x12a656b00:    ldur	x16, [sp, #0x8]
asm                       <1540> 0x12a656b04:    b	0x12a630400 -> JIT PC
asm                       <1544> 0x12a656b08:    sub	w22, w22, w23
asm                       <1548> 0x12a656b0c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1552> 0x12a656b10:    mov	w16, #0x1a -> 26
asm                       <1556> 0x12a656b14:    stur	x16, [sp]
asm                       <1560> 0x12a656b18:    ldur	x16, [sp, #0x8]
asm                       <1564> 0x12a656b1c:    b	0x12a630400 -> JIT PC
asm                       <1568> 0x12a656b20:    stp	x16, x16, [sp, #-0x10]!
asm                       <1572> 0x12a656b24:    mov	w16, #0x1b -> 27
asm                       <1576> 0x12a656b28:    stur	x16, [sp]
asm                       <1580> 0x12a656b2c:    ldur	x16, [sp, #0x8]
asm                       <1584> 0x12a656b30:    b	0x12a630400 -> JIT PC
asm                       <1588> 0x12a656b34:    stp	x16, x16, [sp, #-0x10]!
asm                       <1592> 0x12a656b38:    orr	w16, wzr, #0x1c
asm                       <1596> 0x12a656b3c:    stur	x16, [sp]
asm                       <1600> 0x12a656b40:    ldur	x16, [sp, #0x8]
asm                       <1604> 0x12a656b44:    b	0x12a630400 -> JIT PC
asm                       <1608> 0x12a656b48:    stp	x16, x16, [sp, #-0x10]!
asm                       <1612> 0x12a656b4c:    mov	w16, #0x1d -> 29
asm                       <1616> 0x12a656b50:    stur	x16, [sp]
asm                       <1620> 0x12a656b54:    ldur	x16, [sp, #0x8]
asm                       <1624> 0x12a656b58:    b	0x12a630400 -> JIT PC
asm                       <1628> 0x12a656b5c:    sub	w21, w21, w23
asm                       <1632> 0x12a656b60:    stp	x16, x16, [sp, #-0x10]!
asm                       <1636> 0x12a656b64:    orr	w16, wzr, #0x1e
asm                       <1640> 0x12a656b68:    stur	x16, [sp]
asm                       <1644> 0x12a656b6c:    ldur	x16, [sp, #0x8]
asm                       <1648> 0x12a656b70:    b	0x12a630400 -> JIT PC
asm                       <1652> 0x12a656b74:    stp	x16, x16, [sp, #-0x10]!
asm                       <1656> 0x12a656b78:    orr	w16, wzr, #0x1f
asm                       <1660> 0x12a656b7c:    stur	x16, [sp]
asm                       <1664> 0x12a656b80:    ldur	x16, [sp, #0x8]
asm                       <1668> 0x12a656b84:    b	0x12a630400 -> JIT PC
asm                       <1672> 0x12a656b88:    stp	x16, x16, [sp, #-0x10]!
asm                       <1676> 0x12a656b8c:    orr	w16, wzr, #0x20
asm                       <1680> 0x12a656b90:    stur	x16, [sp]
asm                       <1684> 0x12a656b94:    ldur	x16, [sp, #0x8]
asm                       <1688> 0x12a656b98:    b	0x12a630400 -> JIT PC
asm                       <1692> 0x12a656b9c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1696> 0x12a656ba0:    mov	w16, #0x21 -> 33
asm                       <1700> 0x12a656ba4:    stur	x16, [sp]
asm                       <1704> 0x12a656ba8:    ldur	x16, [sp, #0x8]
asm                       <1708> 0x12a656bac:    b	0x12a630400 -> JIT PC
asm                       <1712> 0x12a656bb0:    sub	w20, w20, #0x1
asm                       <1716> 0x12a656bb4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1720> 0x12a656bb8:    mov	w16, #0x22 -> 34
asm                       <1724> 0x12a656bbc:    stur	x16, [sp]
asm                       <1728> 0x12a656bc0:    ldur	x16, [sp, #0x8]
asm                       <1732> 0x12a656bc4:    b	0x12a630400 -> JIT PC
asm                       <1736> 0x12a656bc8:    sub	w17, w17, #0x1
asm                       <1740> 0x12a656bcc:    stp	x16, x16, [sp, #-0x10]!
asm                       <1744> 0x12a656bd0:    mov	w16, #0x23 -> 35
asm                       <1748> 0x12a656bd4:    stur	x16, [sp]
asm                       <1752> 0x12a656bd8:    ldur	x16, [sp, #0x8]
asm                       <1756> 0x12a656bdc:    b	0x12a630400 -> JIT PC
asm                       <1760> 0x12a656be0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1764> 0x12a656be4:    mov	w16, #0x24 -> 36
asm                       <1768> 0x12a656be8:    stur	x16, [sp]
asm                       <1772> 0x12a656bec:    ldur	x16, [sp, #0x8]
asm                       <1776> 0x12a656bf0:    b	0x12a630400 -> JIT PC
asm                       <1780> 0x12a656bf4:    sub	w17, w17, #0x1
asm                       <1784> 0x12a656bf8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1788> 0x12a656bfc:    mov	w16, #0x25 -> 37
asm                       <1792> 0x12a656c00:    stur	x16, [sp]
asm                       <1796> 0x12a656c04:    ldur	x16, [sp, #0x8]
asm                       <1800> 0x12a656c08:    b	0x12a630400 -> JIT PC
asm                       <1804> 0x12a656c0c:    orr	w16, wzr, #0x2
asm                       <1808> 0x12a656c10:    stur	w16, [fp, #0x24]
asm                       <1812> 0x12a656c14:    sub	sp, sp, #0x10
asm                       <1816> 0x12a656c18:    mov	x1, x5
asm                       <1820> 0x12a656c1c:    mov	x0, #0xe880
asm                       <1824> 0x12a656c20:    movk	x0, #0xe18, lsl #0x10
asm                       <1828> 0x12a656c24:    movk	x0, #0x1, lsl #0x20 -> 0x10e18e880
asm                       <1832> 0x12a656c28:    mov	lr, #0xda9 -> 0xda9 JITThunkPtrTag ?
asm                       <1836> 0x12a656c2c:    mov	x16, #0
asm                       <1840> 0x12a656c30:    movk	x16, #0, lsl #0x10
asm                       <1844> 0x12a656c34:    movk	x16, #0, lsl #0x20
asm                       <1848> 0x12a656c38:    movk	x16, #0, lsl #0x30
asm                       <1852> 0x12a656c3c:    blrab	x16, lr
asm                       <1856> 0x12a656c40:    add	sp, sp, #0x10
asm                       <1860> 0x12a656c44:    mov	x17, #0x6008; Exception check from vm
asm                       <1864> 0x12a656c48:    movk	x17, #0xf42, lsl #0x10
asm                       <1868> 0x12a656c4c:    movk	x17, #0x1, lsl #0x20 -> 0x10f426008 vm +8: vm.m_exception
asm                       <1872> 0x12a656c50:    ldr	x16, [x17, xzr]
asm                       <1876> 0x12a656c54:    cbnz	x16, 0x12a656c54 -> <1876>
asm                       <1880> 0x12a656c58:    nop
asm                       <1884> 0x12a656c5c:    b	0x12a656810 -> <784>
asm                       <1888> 0x12a656c60:    stp	x16, x16, [sp, #-0x10]!
asm                       <1892> 0x12a656c64:    orr	w16, wzr, #0x1
asm                       <1896> 0x12a656c68:    stur	x16, [sp]
asm                       <1900> 0x12a656c6c:    ldur	x16, [sp, #0x8]
asm                       <1904> 0x12a656c70:    b	0x12a630400 -> JIT PC
asm                       <1908> 0x12a656c74:    orr	w16, wzr, #0x2
asm                       <1912> 0x12a656c78:    stur	w16, [fp, #0x24]
asm                       <1916> 0x12a656c7c:    sub	sp, sp, #0x10
asm                       <1920> 0x12a656c80:    mov	x1, x5
asm                       <1924> 0x12a656c84:    mov	x0, #0xeb00
asm                       <1928> 0x12a656c88:    movk	x0, #0xe18, lsl #0x10
asm                       <1932> 0x12a656c8c:    movk	x0, #0x1, lsl #0x20 -> 0x10e18eb00
asm                       <1936> 0x12a656c90:    mov	lr, #0xda9 -> 0xda9 JITThunkPtrTag ?
asm                       <1940> 0x12a656c94:    mov	x16, #0
asm                       <1944> 0x12a656c98:    movk	x16, #0, lsl #0x10
asm                       <1948> 0x12a656c9c:    movk	x16, #0, lsl #0x20
asm                       <1952> 0x12a656ca0:    movk	x16, #0, lsl #0x30
asm                       <1956> 0x12a656ca4:    blrab	x16, lr
asm                       <1960> 0x12a656ca8:    add	sp, sp, #0x10
asm                       <1964> 0x12a656cac:    mov	x17, #0x6008; Exception check from vm
asm                       <1968> 0x12a656cb0:    movk	x17, #0xf42, lsl #0x10
asm                       <1972> 0x12a656cb4:    movk	x17, #0x1, lsl #0x20 -> 0x10f426008 vm +8: vm.m_exception
asm                       <1976> 0x12a656cb8:    ldr	x16, [x17, xzr]
asm                       <1980> 0x12a656cbc:    cbnz	x16, 0x12a656cbc -> <1980>
asm                       <1984> 0x12a656cc0:    nop
asm                       <1988> 0x12a656cc4:    b	0x12a6568b0 -> <944>
asm                       <1992> 0x12a656cc8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1996> 0x12a656ccc:    orr	w16, wzr, #0x2
asm                       <2000> 0x12a656cd0:    stur	x16, [sp]
asm                       <2004> 0x12a656cd4:    ldur	x16, [sp, #0x8]
asm                       <2008> 0x12a656cd8:    b	0x12a630400 -> JIT PC
asm                       <2012> 0x12a656cdc:    b	0x12a614080 -> JIT PC
asm                       <2016> 0x12a656ce0:    ldur	w2, [sp, #0x10]
asm                       <2020> 0x12a656ce4:    cmp	w2, #0x7
asm                       <2024> 0x12a656ce8:    b.hs	0x12a656500 -> <0>
asm                       <2028> 0x12a656cec:    orr	w0, wzr, #0x7
asm                       <2032> 0x12a656cf0:    sub	w0, w0, w2
asm                       <2036> 0x12a656cf4:    add	w1, w0, #0x1
asm                       <2040> 0x12a656cf8:    and	w1, w1, #0xfffffffe
asm                       <2044> 0x12a656cfc:    lsl	x1, x1, #0x3
asm                       <2048> 0x12a656d00:    sub	x3, sp, x1
asm                       <2052> 0x12a656d04:    mov	x17, #0x6068
asm                       <2056> 0x12a656d08:    movk	x17, #0xf42, lsl #0x10
asm                       <2060> 0x12a656d0c:    movk	x17, #0x1, lsl #0x20 -> 0x10f426068 vm +104: vm.softStackLimit()
asm                       <2064> 0x12a656d10:    ldr	x16, [x17, xzr]
asm                       <2068> 0x12a656d14:    cmp	x16, x3
asm                       <2072> 0x12a656d18:    b.gt	0x12a656d34 -> <2100>
asm                       <2076> 0x12a656d1c:    pacizb	lr
asm                       <2080> 0x12a656d20:    mov	x1, lr
asm                       <2084> 0x12a656d24:    bl	0x12a614000 -> JIT PC
asm                       <2088> 0x12a656d28:    mov	lr, x1
asm                       <2092> 0x12a656d2c:    autizb	lr
asm                       <2096> 0x12a656d30:    b	0x12a656500 -> <0>
asm                       <2100> 0x12a656d34:    pacibsp
asm                       <2104> 0x12a656d38:    stp	fp, lr, [sp, #-0x10]!
asm                       <2108> 0x12a656d3c:    mov	fp, sp
asm                       <2112> 0x12a656d40:    b	0x12a61c000 -> JIT PC
asm                       <2116> 0x12a656d44:    brk	#0xbb08
asm                       <2120> 0x12a656d48:    brk	#0xbb08
asm                       <2124> 0x12a656d4c:    brk	#0xbb08
