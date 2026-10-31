(lldb) target create out/boomkat
Current executable set to '/Users/rtomasi/cousas/boomkat/.worktrees/rat/out/boomkat' (arm64).
(lldb) disassemble -n boomkat.vm.th_getcap
boomkat`boomkat.vm.th_getcap:
boomkat[0x100146ad0] <+0>:   ldr    x8, [x3, #0x10]
boomkat[0x100146ad4] <+4>:   ldr    x9, [x8, #0x70]
boomkat[0x100146ad8] <+8>:   asr    x10, x9, #48
boomkat[0x100146adc] <+12>:  cmn    x10, #0x7
boomkat[0x100146ae0] <+16>:  b.ne   0x100146d44               ; <+628>
boomkat[0x100146ae4] <+20>:  and    x10, x9, #0xffffffffffff
boomkat[0x100146ae8] <+24>:  ldr    x9, [x10, #0x80]
boomkat[0x100146aec] <+28>:  cbz    x9, 0x100146d44           ; <+628>
boomkat[0x100146af0] <+32>:  ldr    x10, [x10, #0x38]
boomkat[0x100146af4] <+36>:  cbz    x10, 0x100146d44          ; <+628>
boomkat[0x100146af8] <+40>:  ldr    x8, [x8]
boomkat[0x100146afc] <+44>:  cmp    x10, x8
boomkat[0x100146b00] <+48>:  b.ne   0x100146d44               ; <+628>
boomkat[0x100146b04] <+52>:  ldr    w8, [x0]
boomkat[0x100146b08] <+56>:  ldr    w10, [x10, #0x40]
boomkat[0x100146b0c] <+60>:  lsr    w11, w8, #16
boomkat[0x100146b10] <+64>:  cmp    w11, w10
boomkat[0x100146b14] <+68>:  b.hs   0x100146d44               ; <+628>
boomkat[0x100146b18] <+72>:  add    x12, x9, w11, uxtw #4
boomkat[0x100146b1c] <+76>:  ldrb   w9, [x12, #0xe]
boomkat[0x100146b20] <+80>:  tbz    w9, #0x0, 0x100146c30     ; <+352>
boomkat[0x100146b24] <+84>:  ubfx   w9, w8, #8, #8
boomkat[0x100146b28] <+88>:  mov    x13, #-0x8000000000000    ; =-2251799813685248 
boomkat[0x100146b2c] <+92>:  ldr    x8, [x12]
boomkat[0x100146b30] <+96>:  ldr    x10, [x2, w9, uxtw #3]
boomkat[0x100146b34] <+100>: and    x11, x10, #0xffff000000000000
boomkat[0x100146b38] <+104>: cmp    x11, x13
boomkat[0x100146b3c] <+108>: b.ne   0x100146c84               ; <+436>
boomkat[0x100146b40] <+112>: ldr    x12, [x3, #0x8]
boomkat[0x100146b44] <+116>: ldrb   w13, [x12, #0xf73]
boomkat[0x100146b48] <+120>: cmp    w13, #0x1
boomkat[0x100146b4c] <+124>: b.ne   0x100146b60               ; <+144>
boomkat[0x100146b50] <+128>: mov    x13, #-0xfffd             ; =-65533 
boomkat[0x100146b54] <+132>: add    x13, x13, x8, lsr #48
boomkat[0x100146b58] <+136>: cmn    x13, #0x4
boomkat[0x100146b5c] <+140>: b.hs   0x100146cf0               ; <+544>
boomkat[0x100146b60] <+144>: mov    x12, #-0x8000000000000    ; =-2251799813685248 
boomkat[0x100146b64] <+148>: cmp    x11, x12
boomkat[0x100146b68] <+152>: b.ne   0x100146b80               ; <+176>
boomkat[0x100146b6c] <+156>: ands   x11, x10, #0xffffffffffff
boomkat[0x100146b70] <+160>: b.eq   0x100146b80               ; <+176>
boomkat[0x100146b74] <+164>: ldr    w11, [x11, #0x4]
boomkat[0x100146b78] <+168>: cmp    w11, #0x2
boomkat[0x100146b7c] <+172>: b.lo   0x100146d44               ; <+628>
boomkat[0x100146b80] <+176>: asr    x11, x8, #48
boomkat[0x100146b84] <+180>: cmn    x11, #0x8
boomkat[0x100146b88] <+184>: b.ne   0x100146bbc               ; <+236>
boomkat[0x100146b8c] <+188>: ands   x11, x8, #0xffffffffffff
boomkat[0x100146b90] <+192>: b.eq   0x100146bbc               ; <+236>
boomkat[0x100146b94] <+196>: ldr    w12, [x11, #0x4]
boomkat[0x100146b98] <+200>: mov    w13, #0x7fffffff          ; =2147483647 
boomkat[0x100146b9c] <+204>: cmp    w12, w13
boomkat[0x100146ba0] <+208>: b.ne   0x100146bb0               ; <+224>
boomkat[0x100146ba4] <+212>: ldrb   w13, [x11]
boomkat[0x100146ba8] <+216>: tst    w13, #0x3
boomkat[0x100146bac] <+220>: b.eq   0x100146bbc               ; <+236>
boomkat[0x100146bb0] <+224>: add    w10, w12, #0x1
boomkat[0x100146bb4] <+228>: str    w10, [x11, #0x4]
boomkat[0x100146bb8] <+232>: ldr    x10, [x2, w9, uxtw #3]
boomkat[0x100146bbc] <+236>: asr    x11, x10, #48
boomkat[0x100146bc0] <+240>: cmn    x11, #0x8
boomkat[0x100146bc4] <+244>: b.ne   0x100146bf4               ; <+292>
boomkat[0x100146bc8] <+248>: ands   x10, x10, #0xffffffffffff
boomkat[0x100146bcc] <+252>: b.eq   0x100146bf4               ; <+292>
boomkat[0x100146bd0] <+256>: ldr    w11, [x10, #0x4]
boomkat[0x100146bd4] <+260>: mov    w12, #0x7fffffff          ; =2147483647 
boomkat[0x100146bd8] <+264>: cmp    w11, w12
boomkat[0x100146bdc] <+268>: b.ne   0x100146bec               ; <+284>
boomkat[0x100146be0] <+272>: ldrb   w12, [x10]
boomkat[0x100146be4] <+276>: tst    w12, #0x3
boomkat[0x100146be8] <+280>: b.eq   0x100146bf4               ; <+292>
boomkat[0x100146bec] <+284>: sub    w11, w11, #0x1
boomkat[0x100146bf0] <+288>: str    w11, [x10, #0x4]
boomkat[0x100146bf4] <+292>: tst    x8, #0xffffffffffff
boomkat[0x100146bf8] <+296>: str    x8, [x2, w9, uxtw #3]
boomkat[0x100146bfc] <+300>: b.eq   0x100146c94               ; <+452>
boomkat[0x100146c00] <+304>: mov    x9, #-0xfffd              ; =-65533 
boomkat[0x100146c04] <+308>: add    x8, x9, x8, lsr #48
boomkat[0x100146c08] <+312>: cmn    x8, #0x5
boomkat[0x100146c0c] <+316>: b.lo   0x100146c94               ; <+452>
boomkat[0x100146c10] <+320>: ldr    x8, [x3, #0x10]
boomkat[0x100146c14] <+324>: ldrb   w9, [x0, #0x1]
boomkat[0x100146c18] <+328>: ldr    w10, [x8, #0x4c]
boomkat[0x100146c1c] <+332>: cmp    w9, w10
boomkat[0x100146c20] <+336>: b.lo   0x100146c94               ; <+452>
boomkat[0x100146c24] <+340>: add    w9, w9, #0x1
boomkat[0x100146c28] <+344>: str    w9, [x8, #0x4c]
boomkat[0x100146c2c] <+348>: b      0x100146c94               ; <+452>
boomkat[0x100146c30] <+352>: ldr    x9, [x12]
boomkat[0x100146c34] <+356>: cbz    x9, 0x100146d44           ; <+628>
boomkat[0x100146c38] <+360>: ldrb   w10, [x12, #0xd]
boomkat[0x100146c3c] <+364>: tbnz   w10, #0x0, 0x100146d44    ; <+628>
boomkat[0x100146c40] <+368>: ldrb   w10, [x12, #0xc]
boomkat[0x100146c44] <+372>: tbz    w10, #0x0, 0x100146c58    ; <+392>
boomkat[0x100146c48] <+376>: ldr    w11, [x12, #0x8]
boomkat[0x100146c4c] <+380>: ldr    w13, [x9, #0x18]
boomkat[0x100146c50] <+384>: cmp    w11, w13
boomkat[0x100146c54] <+388>: b.hs   0x100146d44               ; <+628>
boomkat[0x100146c58] <+392>: ldr    x11, [x9, #0x28]
boomkat[0x100146c5c] <+396>: cbnz   x11, 0x100146c70          ; <+416>
boomkat[0x100146c60] <+400>: ldr    w11, [x9, #0x4]
boomkat[0x100146c64] <+404>: lsr    x11, x11, #8
boomkat[0x100146c68] <+408>: and    x11, x11, #0xf8
boomkat[0x100146c6c] <+412>: add    x11, x9, x11
boomkat[0x100146c70] <+416>: ldr    w9, [x12, #0x8]
boomkat[0x100146c74] <+420>: add    x12, x11, x9, lsl #3
boomkat[0x100146c78] <+424>: tbz    w10, #0x0, 0x100146d30    ; <+608>
boomkat[0x100146c7c] <+428>: cbnz   x11, 0x100146b24          ; <+84>
boomkat[0x100146c80] <+432>: b      0x100146d44               ; <+628>
boomkat[0x100146c84] <+436>: mov    x12, #-0x8000000000001    ; =-2251799813685249 
boomkat[0x100146c88] <+440>: cmp    x8, x12
boomkat[0x100146c8c] <+444>: b.hi   0x100146ca0               ; <+464>
boomkat[0x100146c90] <+448>: str    x8, [x2, w9, uxtw #3]
boomkat[0x100146c94] <+452>: ldrb   w8, [x0, #0x4]!
boomkat[0x100146c98] <+456>: ldr    x4, [x1, x8, lsl #3]
boomkat[0x100146c9c] <+460>: br     x4
boomkat[0x100146ca0] <+464>: asr    x12, x8, #48
boomkat[0x100146ca4] <+468>: cmn    x12, #0x7
boomkat[0x100146ca8] <+472>: b.ne   0x100146b40               ; <+112>
boomkat[0x100146cac] <+476>: ldr    x12, [x3, #0x8]
boomkat[0x100146cb0] <+480>: ldrb   w13, [x12, #0xf73]
boomkat[0x100146cb4] <+484>: cmp    w13, #0x1
boomkat[0x100146cb8] <+488>: and    x13, x8, #0xffffffffffff
boomkat[0x100146cbc] <+492>: b.ne   0x100146d48               ; <+632>
boomkat[0x100146cc0] <+496>: cbz    x13, 0x100146c90          ; <+448>
boomkat[0x100146cc4] <+500>: ldrb   w14, [x13]
boomkat[0x100146cc8] <+504>: tbnz   w14, #0x2, 0x100146ce8    ; <+536>
boomkat[0x100146ccc] <+508>: ldrb   w14, [x12, #0xf74]
boomkat[0x100146cd0] <+512>: cbz    w14, 0x100146b40          ; <+112>
boomkat[0x100146cd4] <+516>: ldrb   w13, [x13, #0x4]
boomkat[0x100146cd8] <+520>: tbz    w13, #0x1, 0x100146b40    ; <+112>
boomkat[0x100146cdc] <+524>: mov    w13, #0x1049              ; =4169 
boomkat[0x100146ce0] <+528>: ldrb   w12, [x12, x13]
boomkat[0x100146ce4] <+532>: tbnz   w12, #0x0, 0x100146b40    ; <+112>
boomkat[0x100146ce8] <+536>: str    x8, [x2, w9, uxtw #3]
boomkat[0x100146cec] <+540>: b      0x100146c10               ; <+320>
boomkat[0x100146cf0] <+544>: lsr    x13, x8, #48
boomkat[0x100146cf4] <+548>: mov    w14, #0xfffc              ; =65532 
boomkat[0x100146cf8] <+552>: cmp    x13, x14
boomkat[0x100146cfc] <+556>: b.eq   0x100146d44               ; <+628>
boomkat[0x100146d00] <+560>: ands   x13, x8, #0xffffffffffff
boomkat[0x100146d04] <+564>: b.eq   0x100146b60               ; <+144>
boomkat[0x100146d08] <+568>: ldrb   w14, [x13]
boomkat[0x100146d0c] <+572>: tbnz   w14, #0x2, 0x100146b60    ; <+144>
boomkat[0x100146d10] <+576>: ldrb   w14, [x12, #0xf74]
boomkat[0x100146d14] <+580>: cbz    w14, 0x100146d44          ; <+628>
boomkat[0x100146d18] <+584>: ldrb   w13, [x13, #0x4]
boomkat[0x100146d1c] <+588>: tbz    w13, #0x1, 0x100146d44    ; <+628>
boomkat[0x100146d20] <+592>: mov    w13, #0x1049              ; =4169 
boomkat[0x100146d24] <+596>: ldrb   w12, [x12, x13]
boomkat[0x100146d28] <+600>: tbz    w12, #0x0, 0x100146b60    ; <+144>
boomkat[0x100146d2c] <+604>: b      0x100146d44               ; <+628>
boomkat[0x100146d30] <+608>: ldr    x9, [x12]
boomkat[0x100146d34] <+612>: asr    x10, x9, #48
boomkat[0x100146d38] <+616>: tst    x9, #0xffffffffffff
boomkat[0x100146d3c] <+620>: ccmn   x10, #0xd, #0x0, ne
boomkat[0x100146d40] <+624>: b.ne   0x100146b24               ; <+84>
boomkat[0x100146d44] <+628>: ret    
boomkat[0x100146d48] <+632>: str    x8, [x2, w9, uxtw #3]
boomkat[0x100146d4c] <+636>: cbnz   x13, 0x100146c10          ; <+320>
boomkat[0x100146d50] <+640>: b      0x100146c94               ; <+452>
(lldb) quit
