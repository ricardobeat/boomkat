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
