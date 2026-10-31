(lldb) target create /tmp/bk-capture-before
Current executable set to '/tmp/bk-capture-before' (arm64).
(lldb) disassemble -n boomkat.vm.th_wide
bk-capture-before`boomkat.vm.th_wide:
bk-capture-before[0x10013ecec] <+0>:   ldp    w11, w10, [x0]
bk-capture-before[0x10013ecf0] <+4>:   ubfx   w12, w10, #16, #8
bk-capture-before[0x10013ecf4] <+8>:   lsr    w14, w11, #16
bk-capture-before[0x10013ecf8] <+12>:  and    w8, w11, #0xff00
bk-capture-before[0x10013ecfc] <+16>:  and    w9, w10, #0xff
bk-capture-before[0x10013ed00] <+20>:  bfxil  w8, w10, #8, #8
bk-capture-before[0x10013ed04] <+24>:  mov    w13, w12
bk-capture-before[0x10013ed08] <+28>:  cmp    w9, #0x1e
bk-capture-before[0x10013ed0c] <+32>:  bfi    w13, w14, #8, #8
bk-capture-before[0x10013ed10] <+36>:  and    w14, w14, #0xff00
bk-capture-before[0x10013ed14] <+40>:  bfxil  w14, w10, #24, #8
bk-capture-before[0x10013ed18] <+44>:  b.le   0x10013ed6c               ; <+128>
bk-capture-before[0x10013ed1c] <+48>:  sub    w10, w9, #0x1f
bk-capture-before[0x10013ed20] <+52>:  cmp    w10, #0x6
bk-capture-before[0x10013ed24] <+56>:  b.hs   0x10013ee00               ; <+276>
bk-capture-before[0x10013ed28] <+60>:  ldr    x10, [x2, w13, uxtw #3]
bk-capture-before[0x10013ed2c] <+64>:  ldr    x11, [x2, w14, uxtw #3]
bk-capture-before[0x10013ed30] <+68>:  eor    x12, x10, #0xfff1ffffffffffff
bk-capture-before[0x10013ed34] <+72>:  eor    x13, x11, #0xfff1ffffffffffff
bk-capture-before[0x10013ed38] <+76>:  orr    x12, x13, x12
bk-capture-before[0x10013ed3c] <+80>:  lsr    x12, x12, #48
bk-capture-before[0x10013ed40] <+84>:  cbnz   x12, 0x10013efa8          ; <+700>
bk-capture-before[0x10013ed44] <+88>:  cmp    w9, #0x20
bk-capture-before[0x10013ed48] <+92>:  b.le   0x10013ede8               ; <+252>
bk-capture-before[0x10013ed4c] <+96>:  cmp    w9, #0x21
bk-capture-before[0x10013ed50] <+100>: b.eq   0x10013ef14               ; <+552>
bk-capture-before[0x10013ed54] <+104>: cmp    w9, #0x22
bk-capture-before[0x10013ed58] <+108>: b.eq   0x10013ef1c               ; <+560>
bk-capture-before[0x10013ed5c] <+112>: cmp    w9, #0x23
bk-capture-before[0x10013ed60] <+116>: b.ne   0x10013ef88               ; <+668>
bk-capture-before[0x10013ed64] <+120>: asr    w9, w10, w11
bk-capture-before[0x10013ed68] <+124>: b      0x10013ef28               ; <+572>
bk-capture-before[0x10013ed6c] <+128>: sub    w15, w9, #0xa
bk-capture-before[0x10013ed70] <+132>: cmp    w15, #0x2
bk-capture-before[0x10013ed74] <+136>: b.lo   0x10013eda4               ; <+184>
bk-capture-before[0x10013ed78] <+140>: cbz    w9, 0x10013ee04           ; <+280>
bk-capture-before[0x10013ed7c] <+144>: cmp    w9, #0x3
bk-capture-before[0x10013ed80] <+148>: b.ne   0x10013ee00               ; <+276>
bk-capture-before[0x10013ed84] <+152>: ubfx   w9, w11, #16, #8
bk-capture-before[0x10013ed88] <+156>: and    w11, w11, #0xff000000
bk-capture-before[0x10013ed8c] <+160>: lsr    w10, w10, #24
bk-capture-before[0x10013ed90] <+164>: orr    w11, w11, w12
bk-capture-before[0x10013ed94] <+168>: orr    w9, w11, w9, lsl #16
bk-capture-before[0x10013ed98] <+172>: orr    w9, w9, w10, lsl #8
bk-capture-before[0x10013ed9c] <+176>: sub    w9, w9, #0x8, lsl #12     ; =0x8000 
bk-capture-before[0x10013eda0] <+180>: b      0x10013ef28               ; <+572>
bk-capture-before[0x10013eda4] <+184>: ldr    x10, [x2, w13, uxtw #3]
bk-capture-before[0x10013eda8] <+188>: ldr    x11, [x2, w14, uxtw #3]
bk-capture-before[0x10013edac] <+192>: eor    x12, x10, #0xfff1ffffffffffff
bk-capture-before[0x10013edb0] <+196>: eor    x13, x11, #0xfff1ffffffffffff
bk-capture-before[0x10013edb4] <+200>: orr    x12, x13, x12
bk-capture-before[0x10013edb8] <+204>: lsr    x12, x12, #48
bk-capture-before[0x10013edbc] <+208>: cbnz   x12, 0x10013efa8          ; <+700>
bk-capture-before[0x10013edc0] <+212>: sbfx   x11, x11, #0, #48
bk-capture-before[0x10013edc4] <+216>: lsl    x10, x10, #16
bk-capture-before[0x10013edc8] <+220>: cmp    w9, #0xa
bk-capture-before[0x10013edcc] <+224>: cneg   x9, x11, ne
bk-capture-before[0x10013edd0] <+228>: add    x9, x9, x10, asr #16
bk-capture-before[0x10013edd4] <+232>: mov    x10, #0x800000000000      ; =140737488355328 
bk-capture-before[0x10013edd8] <+236>: add    x10, x9, x10
bk-capture-before[0x10013eddc] <+240>: lsr    x10, x10, #48
bk-capture-before[0x10013ede0] <+244>: cbz    x10, 0x10013ef2c          ; <+576>
bk-capture-before[0x10013ede4] <+248>: b      0x10013efa8               ; <+700>
bk-capture-before[0x10013ede8] <+252>: cmp    w9, #0x1f
bk-capture-before[0x10013edec] <+256>: b.eq   0x10013ef24               ; <+568>
bk-capture-before[0x10013edf0] <+260>: cmp    w9, #0x20
bk-capture-before[0x10013edf4] <+264>: b.ne   0x10013ef88               ; <+668>
bk-capture-before[0x10013edf8] <+268>: orr    w9, w11, w10
bk-capture-before[0x10013edfc] <+272>: b      0x10013ef28               ; <+572>
bk-capture-before[0x10013ee00] <+276>: b      0x100150d70               ; boomkat.vm.th_wide_test
bk-capture-before[0x10013ee04] <+280>: ldr    x9, [x2, w13, uxtw #3]
bk-capture-before[0x10013ee08] <+284>: mov    x10, #-0x8000000000001    ; =-2251799813685249 
bk-capture-before[0x10013ee0c] <+288>: cmp    x9, x10
bk-capture-before[0x10013ee10] <+292>: b.hi   0x10013ee24               ; <+312>
bk-capture-before[0x10013ee14] <+296>: ldr    x10, [x2, x8, lsl #3]
bk-capture-before[0x10013ee18] <+300>: asr    x10, x10, #48
bk-capture-before[0x10013ee1c] <+304>: cmn    x10, #0x8
bk-capture-before[0x10013ee20] <+308>: b.ne   0x10013ef90               ; <+676>
bk-capture-before[0x10013ee24] <+312>: ldr    x10, [x3, #0x8]
bk-capture-before[0x10013ee28] <+316>: ldrb   w11, [x10, #0xf73]
bk-capture-before[0x10013ee2c] <+320>: cmp    w11, #0x1
bk-capture-before[0x10013ee30] <+324>: b.ne   0x10013ee44               ; <+344>
bk-capture-before[0x10013ee34] <+328>: mov    x11, #-0xfffd             ; =-65533 
bk-capture-before[0x10013ee38] <+332>: add    x11, x11, x9, lsr #48
bk-capture-before[0x10013ee3c] <+336>: cmn    x11, #0x4
bk-capture-before[0x10013ee40] <+340>: b.hs   0x10013ef98               ; <+684>
bk-capture-before[0x10013ee44] <+344>: ldr    x10, [x2, x8, lsl #3]
bk-capture-before[0x10013ee48] <+348>: asr    x11, x10, #48
bk-capture-before[0x10013ee4c] <+352>: cmn    x11, #0x8
bk-capture-before[0x10013ee50] <+356>: b.ne   0x10013ee68               ; <+380>
bk-capture-before[0x10013ee54] <+360>: ands   x11, x10, #0xffffffffffff
bk-capture-before[0x10013ee58] <+364>: b.eq   0x10013ee68               ; <+380>
bk-capture-before[0x10013ee5c] <+368>: ldr    w11, [x11, #0x4]
bk-capture-before[0x10013ee60] <+372>: cmp    w11, #0x2
bk-capture-before[0x10013ee64] <+376>: b.lo   0x10013efa8               ; <+700>
bk-capture-before[0x10013ee68] <+380>: asr    x11, x9, #48
bk-capture-before[0x10013ee6c] <+384>: cmn    x11, #0x8
bk-capture-before[0x10013ee70] <+388>: b.ne   0x10013eea4               ; <+440>
bk-capture-before[0x10013ee74] <+392>: ands   x11, x9, #0xffffffffffff
bk-capture-before[0x10013ee78] <+396>: b.eq   0x10013eea4               ; <+440>
bk-capture-before[0x10013ee7c] <+400>: ldr    w12, [x11, #0x4]
bk-capture-before[0x10013ee80] <+404>: mov    w13, #0x7fffffff          ; =2147483647 
bk-capture-before[0x10013ee84] <+408>: cmp    w12, w13
bk-capture-before[0x10013ee88] <+412>: b.ne   0x10013ee98               ; <+428>
bk-capture-before[0x10013ee8c] <+416>: ldrb   w13, [x11]
bk-capture-before[0x10013ee90] <+420>: tst    w13, #0x3
bk-capture-before[0x10013ee94] <+424>: b.eq   0x10013eea4               ; <+440>
bk-capture-before[0x10013ee98] <+428>: add    w10, w12, #0x1
bk-capture-before[0x10013ee9c] <+432>: str    w10, [x11, #0x4]
bk-capture-before[0x10013eea0] <+436>: ldr    x10, [x2, x8, lsl #3]
bk-capture-before[0x10013eea4] <+440>: asr    x11, x10, #48
bk-capture-before[0x10013eea8] <+444>: cmn    x11, #0x8
bk-capture-before[0x10013eeac] <+448>: b.ne   0x10013eedc               ; <+496>
bk-capture-before[0x10013eeb0] <+452>: ands   x10, x10, #0xffffffffffff
bk-capture-before[0x10013eeb4] <+456>: b.eq   0x10013eedc               ; <+496>
bk-capture-before[0x10013eeb8] <+460>: ldr    w11, [x10, #0x4]
bk-capture-before[0x10013eebc] <+464>: mov    w12, #0x7fffffff          ; =2147483647 
bk-capture-before[0x10013eec0] <+468>: cmp    w11, w12
bk-capture-before[0x10013eec4] <+472>: b.ne   0x10013eed4               ; <+488>
bk-capture-before[0x10013eec8] <+476>: ldrb   w12, [x10]
bk-capture-before[0x10013eecc] <+480>: tst    w12, #0x3
bk-capture-before[0x10013eed0] <+484>: b.eq   0x10013eedc               ; <+496>
bk-capture-before[0x10013eed4] <+488>: sub    w11, w11, #0x1
bk-capture-before[0x10013eed8] <+492>: str    w11, [x10, #0x4]
bk-capture-before[0x10013eedc] <+496>: tst    x9, #0xffffffffffff
bk-capture-before[0x10013eee0] <+500>: str    x9, [x2, x8, lsl #3]
bk-capture-before[0x10013eee4] <+504>: b.eq   0x10013ef7c               ; <+656>
bk-capture-before[0x10013eee8] <+508>: mov    x10, #-0xfffd             ; =-65533 
bk-capture-before[0x10013eeec] <+512>: add    x9, x10, x9, lsr #48
bk-capture-before[0x10013eef0] <+516>: cmn    x9, #0x5
bk-capture-before[0x10013eef4] <+520>: b.lo   0x10013ef7c               ; <+656>
bk-capture-before[0x10013eef8] <+524>: ldr    x9, [x3, #0x10]
bk-capture-before[0x10013eefc] <+528>: ldr    w10, [x9, #0x4c]
bk-capture-before[0x10013ef00] <+532>: cmp    w8, w10
bk-capture-before[0x10013ef04] <+536>: b.lo   0x10013ef7c               ; <+656>
bk-capture-before[0x10013ef08] <+540>: add    w8, w8, #0x1
bk-capture-before[0x10013ef0c] <+544>: str    w8, [x9, #0x4c]
bk-capture-before[0x10013ef10] <+548>: b      0x10013ef7c               ; <+656>
bk-capture-before[0x10013ef14] <+552>: eor    w9, w11, w10
bk-capture-before[0x10013ef18] <+556>: b      0x10013ef28               ; <+572>
bk-capture-before[0x10013ef1c] <+560>: lsl    w9, w10, w11
bk-capture-before[0x10013ef20] <+564>: b      0x10013ef28               ; <+572>
bk-capture-before[0x10013ef24] <+568>: and    w9, w11, w10
bk-capture-before[0x10013ef28] <+572>: sxtw   x9, w9
bk-capture-before[0x10013ef2c] <+576>: ldr    x10, [x2, x8, lsl #3]
bk-capture-before[0x10013ef30] <+580>: asr    x11, x10, #48
bk-capture-before[0x10013ef34] <+584>: cmn    x11, #0x8
bk-capture-before[0x10013ef38] <+588>: b.ne   0x10013ef70               ; <+644>
bk-capture-before[0x10013ef3c] <+592>: ands   x10, x10, #0xffffffffffff
bk-capture-before[0x10013ef40] <+596>: b.eq   0x10013ef70               ; <+644>
bk-capture-before[0x10013ef44] <+600>: ldr    w11, [x10, #0x4]
bk-capture-before[0x10013ef48] <+604>: cmp    w11, #0x2
bk-capture-before[0x10013ef4c] <+608>: b.lo   0x10013efa8               ; <+700>
bk-capture-before[0x10013ef50] <+612>: mov    w12, #0x7fffffff          ; =2147483647 
bk-capture-before[0x10013ef54] <+616>: cmp    w11, w12
bk-capture-before[0x10013ef58] <+620>: b.ne   0x10013ef68               ; <+636>
bk-capture-before[0x10013ef5c] <+624>: ldrb   w12, [x10]
bk-capture-before[0x10013ef60] <+628>: tst    w12, #0x3
bk-capture-before[0x10013ef64] <+632>: b.eq   0x10013ef70               ; <+644>
bk-capture-before[0x10013ef68] <+636>: sub    w11, w11, #0x1
bk-capture-before[0x10013ef6c] <+640>: str    w11, [x10, #0x4]
bk-capture-before[0x10013ef70] <+644>: mov    x10, #-0xf000000000000    ; =-4222124650659840 
bk-capture-before[0x10013ef74] <+648>: bfxil  x10, x9, #0, #48
bk-capture-before[0x10013ef78] <+652>: str    x10, [x2, x8, lsl #3]
bk-capture-before[0x10013ef7c] <+656>: ldrb   w8, [x0, #0x8]!
bk-capture-before[0x10013ef80] <+660>: ldr    x4, [x1, x8, lsl #3]
bk-capture-before[0x10013ef84] <+664>: br     x4
bk-capture-before[0x10013ef88] <+668>: lsr    w9, w10, w11
bk-capture-before[0x10013ef8c] <+672>: b      0x10013ef2c               ; <+576>
bk-capture-before[0x10013ef90] <+676>: str    x9, [x2, x8, lsl #3]
bk-capture-before[0x10013ef94] <+680>: b      0x10013ef7c               ; <+656>
bk-capture-before[0x10013ef98] <+684>: lsr    x11, x9, #48
bk-capture-before[0x10013ef9c] <+688>: mov    w12, #0xfffc              ; =65532 
bk-capture-before[0x10013efa0] <+692>: cmp    x11, x12
bk-capture-before[0x10013efa4] <+696>: b.ne   0x10013efac               ; <+704>
bk-capture-before[0x10013efa8] <+700>: ret    
bk-capture-before[0x10013efac] <+704>: ands   x11, x9, #0xffffffffffff
bk-capture-before[0x10013efb0] <+708>: b.eq   0x10013ee44               ; <+344>
bk-capture-before[0x10013efb4] <+712>: ldrb   w12, [x11]
bk-capture-before[0x10013efb8] <+716>: tbnz   w12, #0x2, 0x10013ee44    ; <+344>
bk-capture-before[0x10013efbc] <+720>: ldrb   w12, [x10, #0xf74]
bk-capture-before[0x10013efc0] <+724>: cbz    w12, 0x10013efa8          ; <+700>
bk-capture-before[0x10013efc4] <+728>: ldrb   w11, [x11, #0x4]
bk-capture-before[0x10013efc8] <+732>: tbz    w11, #0x1, 0x10013efa8    ; <+700>
bk-capture-before[0x10013efcc] <+736>: mov    w11, #0x1049              ; =4169 
bk-capture-before[0x10013efd0] <+740>: ldrb   w10, [x10, x11]
bk-capture-before[0x10013efd4] <+744>: tbz    w10, #0x0, 0x10013ee44    ; <+344>
bk-capture-before[0x10013efd8] <+748>: b      0x10013efa8               ; <+700>
(lldb) quit
