asm                          <0> 0x113c40600:    pacibsp
asm                          <4> 0x113c40604:    stp	fp, lr, [sp, #-0x10]!
asm                          <8> 0x113c40608:    mov	fp, sp
asm                         <12> 0x113c4060c:    sub	x0, fp, #0x60
asm                         <16> 0x113c40610:    mov	x17, #0x6068
asm                         <20> 0x113c40614:    movk	x17, #0x1142, lsl #0x10
asm                         <24> 0x113c40618:    movk	x17, #0x1, lsl #0x20 -> 0x111426068 vm +104: vm.softStackLimit()
asm                         <28> 0x113c4061c:    ldr	x16, [x17, xzr]
asm                         <32> 0x113c40620:    cmp	x16, x0
asm                         <36> 0x113c40624:    b.gt	0x113c18000 -> JIT PC
asm                         <40> 0x113c40628:    sub	sp, sp, #0x20
asm                         <44> 0x113c4062c:    ldur	x2, [fp, #0x38]
asm                         <48> 0x113c40630:    orr	x0, xzr, #0xfffe000000000000
asm                         <52> 0x113c40634:    cmp	x2, x0
asm                         <56> 0x113c40638:    b.lo	0x113c40928 -> <808>
asm                         <60> 0x113c4063c:    ldur	x1, [fp, #0x30]
asm                         <64> 0x113c40640:    add	x3, x0, #0x2
asm                         <68> 0x113c40644:    tst	x1, x3
asm                         <72> 0x113c40648:    b.ne	0x113c4093c -> <828>
asm                         <76> 0x113c4064c:    ldur	w4, [x1]
asm                         <80> 0x113c40650:    mov	x5, #0x2710
asm                         <84> 0x113c40654:    movk	x5, #0x100, lsl #0x10 -> 0x1002710
asm                         <88> 0x113c40658:    cmp	w4, w5
asm                         <92> 0x113c4065c:    b.ne	0x113c40950 -> <848>
asm                         <96> 0x113c40660:    movi	v0.16b, #0; InvalidationPoint
asm                        <100> 0x113c40664:    mov	x4, #0x7d10
asm                        <104> 0x113c40668:    movk	x4, #0x1000, lsl #0x10
asm                        <108> 0x113c4066c:    movk	x4, #0x1, lsl #0x20 -> 0x110007d10
asm                        <112> 0x113c40670:    ldur	d1, [x4]
asm                        <116> 0x113c40674:    mov	x4, #0x6a90
asm                        <120> 0x113c40678:    movk	x4, #0x100, lsl #0x10 -> 0x1006a90
asm                        <124> 0x113c4067c:    cmp	w2, #0
asm                        <128> 0x113c40680:    b.le	0x113c406c0 -> <192>
asm                        <132> 0x113c40684:    mov	x5, #0
asm                        <136> 0x113c40688:    ldur	x6, [x1, #0x8]
asm                        <140> 0x113c4068c:    ldur	w7, [x6, #-0x8]
asm                        <144> 0x113c40690:    and	w8, w5, #0xff
asm                        <148> 0x113c40694:    cmp	w7, w8
asm                        <152> 0x113c40698:    b.ls	0x113c40978 -> <888>
asm                        <156> 0x113c4069c:    ldr	x8, [x6, w8, uxtw #0x3]
asm                        <160> 0x113c406a0:    cbnz	x8, 0x113c406d4 -> <212>
asm                        <164> 0x113c406a4:    stp	x16, x16, [sp, #-0x10]!
asm                        <168> 0x113c406a8:    orr	w16, wzr, #0x1
asm                        <172> 0x113c406ac:    stur	x16, [sp]
asm                        <176> 0x113c406b0:    ldur	x16, [sp, #0x8]
asm                        <180> 0x113c406b4:    b	0x113c2c400 -> JIT PC
asm                        <184> 0x113c406b8:    mov	w16, #0x9b -> 155
asm                        <188> 0x113c406bc:    brk	#0xbb08
asm                        <192> 0x113c406c0:    fmov	x1, d0
asm                        <196> 0x113c406c4:    sub	x0, x1, x0
asm                        <200> 0x113c406c8:    mov	sp, fp
asm                        <204> 0x113c406cc:    ldp	fp, lr, [sp], #0x10
asm                        <208> 0x113c406d0:    retab
asm                        <212> 0x113c406d4:    tst	x8, x3
asm                        <216> 0x113c406d8:    b.ne	0x113c4098c -> <908>
asm                        <220> 0x113c406dc:    ldur	w9, [x8]
asm                        <224> 0x113c406e0:    cmp	w9, w4
asm                        <228> 0x113c406e4:    b.ne	0x113c409a0 -> <928>
asm                        <232> 0x113c406e8:    ldur	d3, [x8, #0x10]
asm                        <236> 0x113c406ec:    sub	d2, d3, d1
asm                        <240> 0x113c406f0:    fcmp	d2, d2
asm                        <244> 0x113c406f4:    b.ne	0x113c40914 -> <788>
asm                        <248> 0x113c406f8:    ldur	d4, [x8, #0x18]
asm                        <252> 0x113c406fc:    sub	d3, d4, d1
asm                        <256> 0x113c40700:    fcmp	d3, d3
asm                        <260> 0x113c40704:    b.ne	0x113c40900 -> <768>
asm                        <264> 0x113c40708:    fmul	d2, d2, d3
asm                        <268> 0x113c4070c:    fadd	d0, d0, d2
asm                        <272> 0x113c40710:    add	w8, w5, #0x1
asm                        <276> 0x113c40714:    cmp	w8, w2
asm                        <280> 0x113c40718:    b.ge	0x113c406c0 -> <192>
asm                        <284> 0x113c4071c:    and	w9, w8, #0xff
asm                        <288> 0x113c40720:    cmp	w7, w9
asm                        <292> 0x113c40724:    b.ls	0x113c409b4 -> <948>
asm                        <296> 0x113c40728:    ldr	x9, [x6, w9, uxtw #0x3]
asm                        <300> 0x113c4072c:    cbnz	x9, 0x113c4074c -> <332>
asm                        <304> 0x113c40730:    stp	x16, x16, [sp, #-0x10]!
asm                        <308> 0x113c40734:    orr	w16, wzr, #0x2
asm                        <312> 0x113c40738:    stur	x16, [sp]
asm                        <316> 0x113c4073c:    ldur	x16, [sp, #0x8]
asm                        <320> 0x113c40740:    b	0x113c2c400 -> JIT PC
asm                        <324> 0x113c40744:    mov	w16, #0x9b -> 155
asm                        <328> 0x113c40748:    brk	#0xbb08
asm                        <332> 0x113c4074c:    tst	x9, x3
asm                        <336> 0x113c40750:    b.ne	0x113c409c8 -> <968>
asm                        <340> 0x113c40754:    ldur	w10, [x9]
asm                        <344> 0x113c40758:    cmp	w10, w4
asm                        <348> 0x113c4075c:    b.ne	0x113c409dc -> <988>
asm                        <352> 0x113c40760:    ldur	d3, [x9, #0x10]
asm                        <356> 0x113c40764:    sub	d2, d3, d1
asm                        <360> 0x113c40768:    fcmp	d2, d2
asm                        <364> 0x113c4076c:    b.ne	0x113c408ec -> <748>
asm                        <368> 0x113c40770:    ldur	d4, [x9, #0x18]
asm                        <372> 0x113c40774:    sub	d3, d4, d1
asm                        <376> 0x113c40778:    fcmp	d3, d3
asm                        <380> 0x113c4077c:    b.ne	0x113c408d8 -> <728>
asm                        <384> 0x113c40780:    fmul	d2, d2, d3
asm                        <388> 0x113c40784:    fadd	d0, d0, d2
asm                        <392> 0x113c40788:    add	w8, w5, #0x2
asm                        <396> 0x113c4078c:    cmp	w8, w2
asm                        <400> 0x113c40790:    b.ge	0x113c406c0 -> <192>
asm                        <404> 0x113c40794:    and	w9, w8, #0xff
asm                        <408> 0x113c40798:    cmp	w7, w9
asm                        <412> 0x113c4079c:    b.ls	0x113c409f0 -> <1008>
asm                        <416> 0x113c407a0:    ldr	x9, [x6, w9, uxtw #0x3]
asm                        <420> 0x113c407a4:    cbnz	x9, 0x113c407c4 -> <452>
asm                        <424> 0x113c407a8:    stp	x16, x16, [sp, #-0x10]!
asm                        <428> 0x113c407ac:    orr	w16, wzr, #0x3
asm                        <432> 0x113c407b0:    stur	x16, [sp]
asm                        <436> 0x113c407b4:    ldur	x16, [sp, #0x8]
asm                        <440> 0x113c407b8:    b	0x113c2c400 -> JIT PC
asm                        <444> 0x113c407bc:    mov	w16, #0x9b -> 155
asm                        <448> 0x113c407c0:    brk	#0xbb08
asm                        <452> 0x113c407c4:    tst	x9, x3
asm                        <456> 0x113c407c8:    b.ne	0x113c40a04 -> <1028>
asm                        <460> 0x113c407cc:    ldur	w10, [x9]
asm                        <464> 0x113c407d0:    cmp	w10, w4
asm                        <468> 0x113c407d4:    b.ne	0x113c40a18 -> <1048>
asm                        <472> 0x113c407d8:    ldur	d3, [x9, #0x10]
asm                        <476> 0x113c407dc:    sub	d2, d3, d1
asm                        <480> 0x113c407e0:    fcmp	d2, d2
asm                        <484> 0x113c407e4:    b.ne	0x113c408c4 -> <708>
asm                        <488> 0x113c407e8:    ldur	d4, [x9, #0x18]
asm                        <492> 0x113c407ec:    sub	d3, d4, d1
asm                        <496> 0x113c407f0:    fcmp	d3, d3
asm                        <500> 0x113c407f4:    b.ne	0x113c408b0 -> <688>
asm                        <504> 0x113c407f8:    fmul	d2, d2, d3
asm                        <508> 0x113c407fc:    fadd	d0, d0, d2
asm                        <512> 0x113c40800:    add	w8, w5, #0x3
asm                        <516> 0x113c40804:    cmp	w8, w2
asm                        <520> 0x113c40808:    b.ge	0x113c406c0 -> <192>
asm                        <524> 0x113c4080c:    and	w9, w8, #0xff
asm                        <528> 0x113c40810:    cmp	w7, w9
asm                        <532> 0x113c40814:    b.ls	0x113c40a2c -> <1068>
asm                        <536> 0x113c40818:    ldr	x9, [x6, w9, uxtw #0x3]
asm                        <540> 0x113c4081c:    cbnz	x9, 0x113c4083c -> <572>
asm                        <544> 0x113c40820:    stp	x16, x16, [sp, #-0x10]!
asm                        <548> 0x113c40824:    orr	w16, wzr, #0x4
asm                        <552> 0x113c40828:    stur	x16, [sp]
asm                        <556> 0x113c4082c:    ldur	x16, [sp, #0x8]
asm                        <560> 0x113c40830:    b	0x113c2c400 -> JIT PC
asm                        <564> 0x113c40834:    mov	w16, #0x9b -> 155
asm                        <568> 0x113c40838:    brk	#0xbb08
asm                        <572> 0x113c4083c:    tst	x9, x3
asm                        <576> 0x113c40840:    b.ne	0x113c40a40 -> <1088>
asm                        <580> 0x113c40844:    ldur	w10, [x9]
asm                        <584> 0x113c40848:    cmp	w10, w4
asm                        <588> 0x113c4084c:    b.ne	0x113c40a54 -> <1108>
asm                        <592> 0x113c40850:    ldur	d3, [x9, #0x10]
asm                        <596> 0x113c40854:    sub	d2, d3, d1
asm                        <600> 0x113c40858:    fcmp	d2, d2
asm                        <604> 0x113c4085c:    b.ne	0x113c4089c -> <668>
asm                        <608> 0x113c40860:    ldur	d4, [x9, #0x18]
asm                        <612> 0x113c40864:    sub	d3, d4, d1
asm                        <616> 0x113c40868:    fcmp	d3, d3
asm                        <620> 0x113c4086c:    b.ne	0x113c40888 -> <648>
asm                        <624> 0x113c40870:    fmul	d2, d2, d3
asm                        <628> 0x113c40874:    fadd	d0, d0, d2
asm                        <632> 0x113c40878:    add	w5, w5, #0x4
asm                        <636> 0x113c4087c:    cmp	w5, w2
asm                        <640> 0x113c40880:    b.lt	0x113c40690 -> <144>
asm                        <648> 0x113c40888:    fmov	x10, d4
asm                        <652> 0x113c4088c:    cmp	x10, x0
asm                        <656> 0x113c40890:    b.lo	0x113c40a68 -> <1128>
asm                        <660> 0x113c40894:    scvtf	d3, w10
asm                        <664> 0x113c40898:    b	0x113c40870 -> <624>
asm                        <668> 0x113c4089c:    fmov	x10, d3
asm                        <672> 0x113c408a0:    cmp	x10, x0
asm                        <676> 0x113c408a4:    b.lo	0x113c40a7c -> <1148>
asm                        <680> 0x113c408a8:    scvtf	d2, w10
asm                        <684> 0x113c408ac:    b	0x113c40860 -> <608>
asm                        <688> 0x113c408b0:    fmov	x10, d4
asm                        <692> 0x113c408b4:    cmp	x10, x0
asm                        <696> 0x113c408b8:    b.lo	0x113c40a90 -> <1168>
asm                        <700> 0x113c408bc:    scvtf	d3, w10
asm                        <704> 0x113c408c0:    b	0x113c407f8 -> <504>
asm                        <708> 0x113c408c4:    fmov	x10, d3
asm                        <712> 0x113c408c8:    cmp	x10, x0
asm                        <716> 0x113c408cc:    b.lo	0x113c40aa4 -> <1188>
asm                        <720> 0x113c408d0:    scvtf	d2, w10
asm                        <724> 0x113c408d4:    b	0x113c407e8 -> <488>
asm                        <728> 0x113c408d8:    fmov	x10, d4
asm                        <732> 0x113c408dc:    cmp	x10, x0
asm                        <736> 0x113c408e0:    b.lo	0x113c40ab8 -> <1208>
asm                        <740> 0x113c408e4:    scvtf	d3, w10
asm                        <744> 0x113c408e8:    b	0x113c40780 -> <384>
asm                        <748> 0x113c408ec:    fmov	x10, d3
asm                        <752> 0x113c408f0:    cmp	x10, x0
asm                        <756> 0x113c408f4:    b.lo	0x113c40acc -> <1228>
asm                        <760> 0x113c408f8:    scvtf	d2, w10
asm                        <764> 0x113c408fc:    b	0x113c40770 -> <368>
asm                        <768> 0x113c40900:    fmov	x9, d4
asm                        <772> 0x113c40904:    cmp	x9, x0
asm                        <776> 0x113c40908:    b.lo	0x113c40ae0 -> <1248>
asm                        <780> 0x113c4090c:    scvtf	d3, w9
asm                        <784> 0x113c40910:    b	0x113c40708 -> <264>
asm                        <788> 0x113c40914:    fmov	x9, d3
asm                        <792> 0x113c40918:    cmp	x9, x0
asm                        <796> 0x113c4091c:    b.lo	0x113c40af4 -> <1268>
asm                        <800> 0x113c40920:    scvtf	d2, w9
asm                        <804> 0x113c40924:    b	0x113c406f8 -> <248>
asm                        <808> 0x113c40928:    stp	x16, x16, [sp, #-0x10]!
asm                        <812> 0x113c4092c:    mov	w16, #0x5 -> 5
asm                        <816> 0x113c40930:    stur	x16, [sp]
asm                        <820> 0x113c40934:    ldur	x16, [sp, #0x8]
asm                        <824> 0x113c40938:    b	0x113c2c400 -> JIT PC
asm                        <828> 0x113c4093c:    stp	x16, x16, [sp, #-0x10]!
asm                        <832> 0x113c40940:    orr	w16, wzr, #0x6
asm                        <836> 0x113c40944:    stur	x16, [sp]
asm                        <840> 0x113c40948:    ldur	x16, [sp, #0x8]
asm                        <844> 0x113c4094c:    b	0x113c2c400 -> JIT PC
asm                        <848> 0x113c40950:    stp	x16, x16, [sp, #-0x10]!
asm                        <852> 0x113c40954:    orr	w16, wzr, #0x7
asm                        <856> 0x113c40958:    stur	x16, [sp]
asm                        <860> 0x113c4095c:    ldur	x16, [sp, #0x8]
asm                        <864> 0x113c40960:    b	0x113c2c400 -> JIT PC
asm                        <868> 0x113c40964:    stp	x16, x16, [sp, #-0x10]!
asm                        <872> 0x113c40968:    mov	w16, #0
asm                        <876> 0x113c4096c:    stur	x16, [sp]
asm                        <880> 0x113c40970:    ldur	x16, [sp, #0x8]
asm                        <884> 0x113c40974:    b	0x113c2c400 -> JIT PC
asm                        <888> 0x113c40978:    stp	x16, x16, [sp, #-0x10]!
asm                        <892> 0x113c4097c:    orr	w16, wzr, #0x8
asm                        <896> 0x113c40980:    stur	x16, [sp]
asm                        <900> 0x113c40984:    ldur	x16, [sp, #0x8]
asm                        <904> 0x113c40988:    b	0x113c2c400 -> JIT PC
asm                        <908> 0x113c4098c:    stp	x16, x16, [sp, #-0x10]!
asm                        <912> 0x113c40990:    mov	w16, #0x9 -> 9
asm                        <916> 0x113c40994:    stur	x16, [sp]
asm                        <920> 0x113c40998:    ldur	x16, [sp, #0x8]
asm                        <924> 0x113c4099c:    b	0x113c2c400 -> JIT PC
asm                        <928> 0x113c409a0:    stp	x16, x16, [sp, #-0x10]!
asm                        <932> 0x113c409a4:    mov	w16, #0xa -> 10
asm                        <936> 0x113c409a8:    stur	x16, [sp]
asm                        <940> 0x113c409ac:    ldur	x16, [sp, #0x8]
asm                        <944> 0x113c409b0:    b	0x113c2c400 -> JIT PC
asm                        <948> 0x113c409b4:    stp	x16, x16, [sp, #-0x10]!
asm                        <952> 0x113c409b8:    mov	w16, #0xb -> 11
asm                        <956> 0x113c409bc:    stur	x16, [sp]
asm                        <960> 0x113c409c0:    ldur	x16, [sp, #0x8]
asm                        <964> 0x113c409c4:    b	0x113c2c400 -> JIT PC
asm                        <968> 0x113c409c8:    stp	x16, x16, [sp, #-0x10]!
asm                        <972> 0x113c409cc:    orr	w16, wzr, #0xc
asm                        <976> 0x113c409d0:    stur	x16, [sp]
asm                        <980> 0x113c409d4:    ldur	x16, [sp, #0x8]
asm                        <984> 0x113c409d8:    b	0x113c2c400 -> JIT PC
asm                        <988> 0x113c409dc:    stp	x16, x16, [sp, #-0x10]!
asm                        <992> 0x113c409e0:    mov	w16, #0xd -> 13
asm                        <996> 0x113c409e4:    stur	x16, [sp]
asm                       <1000> 0x113c409e8:    ldur	x16, [sp, #0x8]
asm                       <1004> 0x113c409ec:    b	0x113c2c400 -> JIT PC
asm                       <1008> 0x113c409f0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1012> 0x113c409f4:    orr	w16, wzr, #0xe
asm                       <1016> 0x113c409f8:    stur	x16, [sp]
asm                       <1020> 0x113c409fc:    ldur	x16, [sp, #0x8]
asm                       <1024> 0x113c40a00:    b	0x113c2c400 -> JIT PC
asm                       <1028> 0x113c40a04:    stp	x16, x16, [sp, #-0x10]!
asm                       <1032> 0x113c40a08:    orr	w16, wzr, #0xf
asm                       <1036> 0x113c40a0c:    stur	x16, [sp]
asm                       <1040> 0x113c40a10:    ldur	x16, [sp, #0x8]
asm                       <1044> 0x113c40a14:    b	0x113c2c400 -> JIT PC
asm                       <1048> 0x113c40a18:    stp	x16, x16, [sp, #-0x10]!
asm                       <1052> 0x113c40a1c:    orr	w16, wzr, #0x10
asm                       <1056> 0x113c40a20:    stur	x16, [sp]
asm                       <1060> 0x113c40a24:    ldur	x16, [sp, #0x8]
asm                       <1064> 0x113c40a28:    b	0x113c2c400 -> JIT PC
asm                       <1068> 0x113c40a2c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1072> 0x113c40a30:    mov	w16, #0x11 -> 17
asm                       <1076> 0x113c40a34:    stur	x16, [sp]
asm                       <1080> 0x113c40a38:    ldur	x16, [sp, #0x8]
asm                       <1084> 0x113c40a3c:    b	0x113c2c400 -> JIT PC
asm                       <1088> 0x113c40a40:    stp	x16, x16, [sp, #-0x10]!
asm                       <1092> 0x113c40a44:    mov	w16, #0x12 -> 18
asm                       <1096> 0x113c40a48:    stur	x16, [sp]
asm                       <1100> 0x113c40a4c:    ldur	x16, [sp, #0x8]
asm                       <1104> 0x113c40a50:    b	0x113c2c400 -> JIT PC
asm                       <1108> 0x113c40a54:    stp	x16, x16, [sp, #-0x10]!
asm                       <1112> 0x113c40a58:    mov	w16, #0x13 -> 19
asm                       <1116> 0x113c40a5c:    stur	x16, [sp]
asm                       <1120> 0x113c40a60:    ldur	x16, [sp, #0x8]
asm                       <1124> 0x113c40a64:    b	0x113c2c400 -> JIT PC
asm                       <1128> 0x113c40a68:    stp	x16, x16, [sp, #-0x10]!
asm                       <1132> 0x113c40a6c:    mov	w16, #0x14 -> 20
asm                       <1136> 0x113c40a70:    stur	x16, [sp]
asm                       <1140> 0x113c40a74:    ldur	x16, [sp, #0x8]
asm                       <1144> 0x113c40a78:    b	0x113c2c400 -> JIT PC
asm                       <1148> 0x113c40a7c:    stp	x16, x16, [sp, #-0x10]!
asm                       <1152> 0x113c40a80:    mov	w16, #0x15 -> 21
asm                       <1156> 0x113c40a84:    stur	x16, [sp]
asm                       <1160> 0x113c40a88:    ldur	x16, [sp, #0x8]
asm                       <1164> 0x113c40a8c:    b	0x113c2c400 -> JIT PC
asm                       <1168> 0x113c40a90:    stp	x16, x16, [sp, #-0x10]!
asm                       <1172> 0x113c40a94:    mov	w16, #0x16 -> 22
asm                       <1176> 0x113c40a98:    stur	x16, [sp]
asm                       <1180> 0x113c40a9c:    ldur	x16, [sp, #0x8]
asm                       <1184> 0x113c40aa0:    b	0x113c2c400 -> JIT PC
asm                       <1188> 0x113c40aa4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1192> 0x113c40aa8:    mov	w16, #0x17 -> 23
asm                       <1196> 0x113c40aac:    stur	x16, [sp]
asm                       <1200> 0x113c40ab0:    ldur	x16, [sp, #0x8]
asm                       <1204> 0x113c40ab4:    b	0x113c2c400 -> JIT PC
asm                       <1208> 0x113c40ab8:    stp	x16, x16, [sp, #-0x10]!
asm                       <1212> 0x113c40abc:    orr	w16, wzr, #0x18
asm                       <1216> 0x113c40ac0:    stur	x16, [sp]
asm                       <1220> 0x113c40ac4:    ldur	x16, [sp, #0x8]
asm                       <1224> 0x113c40ac8:    b	0x113c2c400 -> JIT PC
asm                       <1228> 0x113c40acc:    stp	x16, x16, [sp, #-0x10]!
asm                       <1232> 0x113c40ad0:    mov	w16, #0x19 -> 25
asm                       <1236> 0x113c40ad4:    stur	x16, [sp]
asm                       <1240> 0x113c40ad8:    ldur	x16, [sp, #0x8]
asm                       <1244> 0x113c40adc:    b	0x113c2c400 -> JIT PC
asm                       <1248> 0x113c40ae0:    stp	x16, x16, [sp, #-0x10]!
asm                       <1252> 0x113c40ae4:    mov	w16, #0x1a -> 26
asm                       <1256> 0x113c40ae8:    stur	x16, [sp]
asm                       <1260> 0x113c40aec:    ldur	x16, [sp, #0x8]
asm                       <1264> 0x113c40af0:    b	0x113c2c400 -> JIT PC
asm                       <1268> 0x113c40af4:    stp	x16, x16, [sp, #-0x10]!
asm                       <1272> 0x113c40af8:    mov	w16, #0x1b -> 27
asm                       <1276> 0x113c40afc:    stur	x16, [sp]
asm                       <1280> 0x113c40b00:    ldur	x16, [sp, #0x8]
asm                       <1284> 0x113c40b04:    b	0x113c2c400 -> JIT PC
asm                       <1288> 0x113c40b08:    b	0x113c10080 -> JIT PC
asm                       <1292> 0x113c40b0c:    ldur	w2, [sp, #0x10]
asm                       <1296> 0x113c40b10:    cmp	w2, #0x3
asm                       <1300> 0x113c40b14:    b.hs	0x113c40600 -> <0>
asm                       <1304> 0x113c40b18:    orr	w0, wzr, #0x3
asm                       <1308> 0x113c40b1c:    sub	w0, w0, w2
asm                       <1312> 0x113c40b20:    add	w1, w0, #0x1
asm                       <1316> 0x113c40b24:    and	w1, w1, #0xfffffffe
asm                       <1320> 0x113c40b28:    lsl	x1, x1, #0x3
asm                       <1324> 0x113c40b2c:    sub	x3, sp, x1
asm                       <1328> 0x113c40b30:    mov	x17, #0x6068
asm                       <1332> 0x113c40b34:    movk	x17, #0x1142, lsl #0x10
asm                       <1336> 0x113c40b38:    movk	x17, #0x1, lsl #0x20 -> 0x111426068 vm +104: vm.softStackLimit()
asm                       <1340> 0x113c40b3c:    ldr	x16, [x17, xzr]
asm                       <1344> 0x113c40b40:    cmp	x16, x3
asm                       <1348> 0x113c40b44:    b.gt	0x113c40b60 -> <1376>
asm                       <1352> 0x113c40b48:    pacizb	lr
asm                       <1356> 0x113c40b4c:    mov	x1, lr
asm                       <1360> 0x113c40b50:    bl	0x113c10000 -> JIT PC
asm                       <1364> 0x113c40b54:    mov	lr, x1
asm                       <1368> 0x113c40b58:    autizb	lr
asm                       <1372> 0x113c40b5c:    b	0x113c40600 -> <0>
asm                       <1376> 0x113c40b60:    pacibsp
asm                       <1380> 0x113c40b64:    stp	fp, lr, [sp, #-0x10]!
asm                       <1384> 0x113c40b68:    mov	fp, sp
asm                       <1388> 0x113c40b6c:    b	0x113c18000 -> JIT PC
asm                       <1392> 0x113c40b70:    brk	#0xbb08
