(lldb) target create out/boomkat
Current executable set to '/Users/rtomasi/cousas/boomkat/.worktrees/rat/out/boomkat' (arm64).
(lldb) disassemble -n boomkat.vm.th_wide
boomkat`boomkat.vm.th_wide:
boomkat[0x10013ecec] <+0>:   ldp    w11, w10, [x0]
boomkat[0x10013ecf0] <+4>:   and    w8, w11, #0xff00
boomkat[0x10013ecf4] <+8>:   and    w9, w10, #0xff
boomkat[0x10013ecf8] <+12>:  bfxil  w8, w10, #8, #8
boomkat[0x10013ecfc] <+16>:  cmp    w9, #0x3
boomkat[0x10013ed00] <+20>:  b.ne   0x10013ed5c               ; <+112>
boomkat[0x10013ed04] <+24>:  ldr    x9, [x2, w8, uxtw #3]
boomkat[0x10013ed08] <+28>:  asr    x12, x9, #48
boomkat[0x10013ed0c] <+32>:  cmn    x12, #0x8
boomkat[0x10013ed10] <+36>:  b.ne   0x10013edc8               ; <+220>
boomkat[0x10013ed14] <+40>:  ands   x12, x9, #0xffffffffffff
boomkat[0x10013ed18] <+44>:  b.eq   0x10013ed28               ; <+60>
boomkat[0x10013ed1c] <+48>:  ldr    w9, [x12, #0x4]
boomkat[0x10013ed20] <+52>:  cmp    w9, #0x1
boomkat[0x10013ed24] <+56>:  b.ls   0x10013f010               ; <+804>
boomkat[0x10013ed28] <+60>:  bfxil  w11, w10, #16, #16
boomkat[0x10013ed2c] <+64>:  sub    w9, w11, #0x8, lsl #12    ; =0x8000 
boomkat[0x10013ed30] <+68>:  cbz    x12, 0x10013edd0          ; <+228>
boomkat[0x10013ed34] <+72>:  ldr    w10, [x12, #0x4]
boomkat[0x10013ed38] <+76>:  mov    w11, #0x7fffffff          ; =2147483647 
boomkat[0x10013ed3c] <+80>:  cmp    w10, w11
boomkat[0x10013ed40] <+84>:  b.ne   0x10013ed50               ; <+100>
boomkat[0x10013ed44] <+88>:  ldrb   w11, [x12]
boomkat[0x10013ed48] <+92>:  tst    w11, #0x3
boomkat[0x10013ed4c] <+96>:  b.eq   0x10013edd0               ; <+228>
boomkat[0x10013ed50] <+100>: sub    w10, w10, #0x1
boomkat[0x10013ed54] <+104>: str    w10, [x12, #0x4]
boomkat[0x10013ed58] <+108>: b      0x10013edd0               ; <+228>
boomkat[0x10013ed5c] <+112>: lsr    w12, w11, #8
boomkat[0x10013ed60] <+116>: and    w12, w12, #0xff00
boomkat[0x10013ed64] <+120>: bfxil  w12, w10, #16, #8
boomkat[0x10013ed68] <+124>: cbz    w9, 0x10013edec           ; <+256>
boomkat[0x10013ed6c] <+128>: lsr    w11, w11, #16
boomkat[0x10013ed70] <+132>: sub    w13, w9, #0x1f
boomkat[0x10013ed74] <+136>: cmp    w13, #0x6
boomkat[0x10013ed78] <+140>: and    w11, w11, #0xff00
boomkat[0x10013ed7c] <+144>: bfxil  w11, w10, #24, #8
boomkat[0x10013ed80] <+148>: b.hs   0x10013eefc               ; <+528>
boomkat[0x10013ed84] <+152>: ldr    x10, [x2, w12, uxtw #3]
boomkat[0x10013ed88] <+156>: ldr    x11, [x2, w11, uxtw #3]
boomkat[0x10013ed8c] <+160>: eor    x12, x10, #0xfff1ffffffffffff
boomkat[0x10013ed90] <+164>: eor    x13, x11, #0xfff1ffffffffffff
boomkat[0x10013ed94] <+168>: orr    x12, x13, x12
boomkat[0x10013ed98] <+172>: lsr    x12, x12, #48
boomkat[0x10013ed9c] <+176>: cbnz   x12, 0x10013f010          ; <+804>
boomkat[0x10013eda0] <+180>: cmp    w9, #0x20
boomkat[0x10013eda4] <+184>: b.le   0x10013ef54               ; <+616>
boomkat[0x10013eda8] <+188>: cmp    w9, #0x21
boomkat[0x10013edac] <+192>: b.eq   0x10013efb0               ; <+708>
boomkat[0x10013edb0] <+196>: cmp    w9, #0x22
boomkat[0x10013edb4] <+200>: b.eq   0x10013efb8               ; <+716>
boomkat[0x10013edb8] <+204>: cmp    w9, #0x23
boomkat[0x10013edbc] <+208>: b.ne   0x10013f014               ; <+808>
boomkat[0x10013edc0] <+212>: asr    w9, w10, w11
boomkat[0x10013edc4] <+216>: b      0x10013efc4               ; <+728>
boomkat[0x10013edc8] <+220>: bfxil  w11, w10, #16, #16
boomkat[0x10013edcc] <+224>: sub    w9, w11, #0x8, lsl #12    ; =0x8000 
boomkat[0x10013edd0] <+228>: sxtw   x9, w9
boomkat[0x10013edd4] <+232>: mov    x10, #-0xf000000000000    ; =-4222124650659840 
boomkat[0x10013edd8] <+236>: bfxil  x10, x9, #0, #48
boomkat[0x10013eddc] <+240>: str    x10, [x2, w8, uxtw #3]
boomkat[0x10013ede0] <+244>: ldrb   w8, [x0, #0x8]!
boomkat[0x10013ede4] <+248>: ldr    x4, [x1, x8, lsl #3]
boomkat[0x10013ede8] <+252>: br     x4
boomkat[0x10013edec] <+256>: ldr    x9, [x2, w12, uxtw #3]
boomkat[0x10013edf0] <+260>: mov    x10, #-0x8000000000001    ; =-2251799813685249 
boomkat[0x10013edf4] <+264>: cmp    x9, x10
boomkat[0x10013edf8] <+268>: b.hi   0x10013ee0c               ; <+288>
boomkat[0x10013edfc] <+272>: ldr    x10, [x2, w8, uxtw #3]
boomkat[0x10013ee00] <+276>: asr    x10, x10, #48
boomkat[0x10013ee04] <+280>: cmn    x10, #0x8
boomkat[0x10013ee08] <+284>: b.ne   0x10013ef4c               ; <+608>
boomkat[0x10013ee0c] <+288>: ldr    x10, [x3, #0x8]
boomkat[0x10013ee10] <+292>: ldrb   w11, [x10, #0xf73]
boomkat[0x10013ee14] <+296>: cmp    w11, #0x1
boomkat[0x10013ee18] <+300>: b.ne   0x10013ee2c               ; <+320>
boomkat[0x10013ee1c] <+304>: mov    x11, #-0xfffd             ; =-65533 
boomkat[0x10013ee20] <+308>: add    x11, x11, x9, lsr #48
boomkat[0x10013ee24] <+312>: cmn    x11, #0x4
boomkat[0x10013ee28] <+316>: b.hs   0x10013ef6c               ; <+640>
boomkat[0x10013ee2c] <+320>: ldr    x10, [x2, w8, uxtw #3]
boomkat[0x10013ee30] <+324>: asr    x11, x10, #48
boomkat[0x10013ee34] <+328>: cmn    x11, #0x8
boomkat[0x10013ee38] <+332>: b.ne   0x10013ee50               ; <+356>
boomkat[0x10013ee3c] <+336>: ands   x11, x10, #0xffffffffffff
boomkat[0x10013ee40] <+340>: b.eq   0x10013ee50               ; <+356>
boomkat[0x10013ee44] <+344>: ldr    w11, [x11, #0x4]
boomkat[0x10013ee48] <+348>: cmp    w11, #0x2
boomkat[0x10013ee4c] <+352>: b.lo   0x10013f010               ; <+804>
boomkat[0x10013ee50] <+356>: asr    x11, x9, #48
boomkat[0x10013ee54] <+360>: cmn    x11, #0x8
boomkat[0x10013ee58] <+364>: b.ne   0x10013ee8c               ; <+416>
boomkat[0x10013ee5c] <+368>: ands   x11, x9, #0xffffffffffff
boomkat[0x10013ee60] <+372>: b.eq   0x10013ee8c               ; <+416>
boomkat[0x10013ee64] <+376>: ldr    w12, [x11, #0x4]
boomkat[0x10013ee68] <+380>: mov    w13, #0x7fffffff          ; =2147483647 
boomkat[0x10013ee6c] <+384>: cmp    w12, w13
boomkat[0x10013ee70] <+388>: b.ne   0x10013ee80               ; <+404>
boomkat[0x10013ee74] <+392>: ldrb   w13, [x11]
boomkat[0x10013ee78] <+396>: tst    w13, #0x3
boomkat[0x10013ee7c] <+400>: b.eq   0x10013ee8c               ; <+416>
boomkat[0x10013ee80] <+404>: add    w10, w12, #0x1
boomkat[0x10013ee84] <+408>: str    w10, [x11, #0x4]
boomkat[0x10013ee88] <+412>: ldr    x10, [x2, w8, uxtw #3]
boomkat[0x10013ee8c] <+416>: asr    x11, x10, #48
boomkat[0x10013ee90] <+420>: cmn    x11, #0x8
boomkat[0x10013ee94] <+424>: b.ne   0x10013eec4               ; <+472>
boomkat[0x10013ee98] <+428>: ands   x10, x10, #0xffffffffffff
boomkat[0x10013ee9c] <+432>: b.eq   0x10013eec4               ; <+472>
boomkat[0x10013eea0] <+436>: ldr    w11, [x10, #0x4]
boomkat[0x10013eea4] <+440>: mov    w12, #0x7fffffff          ; =2147483647 
boomkat[0x10013eea8] <+444>: cmp    w11, w12
boomkat[0x10013eeac] <+448>: b.ne   0x10013eebc               ; <+464>
boomkat[0x10013eeb0] <+452>: ldrb   w12, [x10]
boomkat[0x10013eeb4] <+456>: tst    w12, #0x3
boomkat[0x10013eeb8] <+460>: b.eq   0x10013eec4               ; <+472>
boomkat[0x10013eebc] <+464>: sub    w11, w11, #0x1
boomkat[0x10013eec0] <+468>: str    w11, [x10, #0x4]
boomkat[0x10013eec4] <+472>: tst    x9, #0xffffffffffff
boomkat[0x10013eec8] <+476>: str    x9, [x2, w8, uxtw #3]
boomkat[0x10013eecc] <+480>: b.eq   0x10013ede0               ; <+244>
boomkat[0x10013eed0] <+484>: mov    x10, #-0xfffd             ; =-65533 
boomkat[0x10013eed4] <+488>: add    x9, x10, x9, lsr #48
boomkat[0x10013eed8] <+492>: cmn    x9, #0x5
boomkat[0x10013eedc] <+496>: b.lo   0x10013ede0               ; <+244>
boomkat[0x10013eee0] <+500>: ldr    x9, [x3, #0x10]
boomkat[0x10013eee4] <+504>: ldr    w10, [x9, #0x4c]
boomkat[0x10013eee8] <+508>: cmp    w8, w10
boomkat[0x10013eeec] <+512>: b.lo   0x10013ede0               ; <+244>
boomkat[0x10013eef0] <+516>: add    w8, w8, #0x1
boomkat[0x10013eef4] <+520>: str    w8, [x9, #0x4c]
boomkat[0x10013eef8] <+524>: b      0x10013ede0               ; <+244>
boomkat[0x10013eefc] <+528>: sub    w10, w9, #0xa
boomkat[0x10013ef00] <+532>: cmp    w10, #0x1
boomkat[0x10013ef04] <+536>: b.hi   0x10013efac               ; <+704>
boomkat[0x10013ef08] <+540>: ldr    x10, [x2, w12, uxtw #3]
boomkat[0x10013ef0c] <+544>: ldr    x11, [x2, w11, uxtw #3]
boomkat[0x10013ef10] <+548>: eor    x12, x10, #0xfff1ffffffffffff
boomkat[0x10013ef14] <+552>: eor    x13, x11, #0xfff1ffffffffffff
boomkat[0x10013ef18] <+556>: orr    x12, x13, x12
boomkat[0x10013ef1c] <+560>: lsr    x12, x12, #48
boomkat[0x10013ef20] <+564>: cbnz   x12, 0x10013f010          ; <+804>
boomkat[0x10013ef24] <+568>: sbfx   x11, x11, #0, #48
boomkat[0x10013ef28] <+572>: lsl    x10, x10, #16
boomkat[0x10013ef2c] <+576>: cmp    w9, #0xa
boomkat[0x10013ef30] <+580>: cneg   x9, x11, ne
boomkat[0x10013ef34] <+584>: add    x9, x9, x10, asr #16
boomkat[0x10013ef38] <+588>: mov    x10, #0x800000000000      ; =140737488355328 
boomkat[0x10013ef3c] <+592>: add    x10, x9, x10
boomkat[0x10013ef40] <+596>: lsr    x10, x10, #48
boomkat[0x10013ef44] <+600>: cbz    x10, 0x10013efc8          ; <+732>
boomkat[0x10013ef48] <+604>: b      0x10013f010               ; <+804>
boomkat[0x10013ef4c] <+608>: str    x9, [x2, w8, uxtw #3]
boomkat[0x10013ef50] <+612>: b      0x10013ede0               ; <+244>
boomkat[0x10013ef54] <+616>: cmp    w9, #0x1f
boomkat[0x10013ef58] <+620>: b.eq   0x10013efc0               ; <+724>
boomkat[0x10013ef5c] <+624>: cmp    w9, #0x20
boomkat[0x10013ef60] <+628>: b.ne   0x10013f014               ; <+808>
boomkat[0x10013ef64] <+632>: orr    w9, w11, w10
boomkat[0x10013ef68] <+636>: b      0x10013efc4               ; <+728>
boomkat[0x10013ef6c] <+640>: lsr    x11, x9, #48
boomkat[0x10013ef70] <+644>: mov    w12, #0xfffc              ; =65532 
boomkat[0x10013ef74] <+648>: cmp    x11, x12
boomkat[0x10013ef78] <+652>: b.eq   0x10013f010               ; <+804>
boomkat[0x10013ef7c] <+656>: ands   x11, x9, #0xffffffffffff
boomkat[0x10013ef80] <+660>: b.eq   0x10013ee2c               ; <+320>
boomkat[0x10013ef84] <+664>: ldrb   w12, [x11]
boomkat[0x10013ef88] <+668>: tbnz   w12, #0x2, 0x10013ee2c    ; <+320>
boomkat[0x10013ef8c] <+672>: ldrb   w12, [x10, #0xf74]
boomkat[0x10013ef90] <+676>: cbz    w12, 0x10013f010          ; <+804>
boomkat[0x10013ef94] <+680>: ldrb   w11, [x11, #0x4]
boomkat[0x10013ef98] <+684>: tbz    w11, #0x1, 0x10013f010    ; <+804>
boomkat[0x10013ef9c] <+688>: mov    w11, #0x1049              ; =4169 
boomkat[0x10013efa0] <+692>: ldrb   w10, [x10, x11]
boomkat[0x10013efa4] <+696>: tbz    w10, #0x0, 0x10013ee2c    ; <+320>
boomkat[0x10013efa8] <+700>: b      0x10013f010               ; <+804>
boomkat[0x10013efac] <+704>: b      0x100150db0               ; boomkat.vm.th_wide_test
boomkat[0x10013efb0] <+708>: eor    w9, w11, w10
boomkat[0x10013efb4] <+712>: b      0x10013efc4               ; <+728>
boomkat[0x10013efb8] <+716>: lsl    w9, w10, w11
boomkat[0x10013efbc] <+720>: b      0x10013efc4               ; <+728>
boomkat[0x10013efc0] <+724>: and    w9, w11, w10
boomkat[0x10013efc4] <+728>: sxtw   x9, w9
boomkat[0x10013efc8] <+732>: ldr    x10, [x2, w8, uxtw #3]
boomkat[0x10013efcc] <+736>: asr    x11, x10, #48
boomkat[0x10013efd0] <+740>: cmn    x11, #0x8
boomkat[0x10013efd4] <+744>: b.ne   0x10013edd4               ; <+232>
boomkat[0x10013efd8] <+748>: ands   x10, x10, #0xffffffffffff
boomkat[0x10013efdc] <+752>: b.eq   0x10013edd4               ; <+232>
boomkat[0x10013efe0] <+756>: ldr    w11, [x10, #0x4]
boomkat[0x10013efe4] <+760>: cmp    w11, #0x2
boomkat[0x10013efe8] <+764>: b.lo   0x10013f010               ; <+804>
boomkat[0x10013efec] <+768>: mov    w12, #0x7fffffff          ; =2147483647 
boomkat[0x10013eff0] <+772>: cmp    w11, w12
boomkat[0x10013eff4] <+776>: b.ne   0x10013f004               ; <+792>
boomkat[0x10013eff8] <+780>: ldrb   w12, [x10]
boomkat[0x10013effc] <+784>: tst    w12, #0x3
boomkat[0x10013f000] <+788>: b.eq   0x10013edd4               ; <+232>
boomkat[0x10013f004] <+792>: sub    w11, w11, #0x1
boomkat[0x10013f008] <+796>: str    w11, [x10, #0x4]
boomkat[0x10013f00c] <+800>: b      0x10013edd4               ; <+232>
boomkat[0x10013f010] <+804>: ret    
boomkat[0x10013f014] <+808>: lsr    w9, w10, w11
boomkat[0x10013f018] <+812>: b      0x10013efc8               ; <+732>
(lldb) quit
