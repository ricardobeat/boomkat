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
