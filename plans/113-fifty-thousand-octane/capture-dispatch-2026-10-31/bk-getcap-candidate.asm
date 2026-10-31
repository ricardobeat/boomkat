(lldb) target create out/boomkat
Current executable set to '/Users/rtomasi/cousas/boomkat/.worktrees/rat/out/boomkat' (arm64).
(lldb) disassemble -n boomkat.vm.th_getcap
boomkat`boomkat.vm.th_getcap:
boomkat[0x100146ad0] <+0>:   ldr    x9, [x3, #0x10]
boomkat[0x100146ad4] <+4>:   ldr    x8, [x9, #0x70]
boomkat[0x100146ad8] <+8>:   asr    x10, x8, #48
boomkat[0x100146adc] <+12>:  cmn    x10, #0x7
boomkat[0x100146ae0] <+16>:  b.ne   0x100146cd0               ; <+512>
boomkat[0x100146ae4] <+20>:  and    x10, x8, #0xffffffffffff
boomkat[0x100146ae8] <+24>:  ldr    x8, [x10, #0x80]
boomkat[0x100146aec] <+28>:  cbz    x8, 0x100146cd0           ; <+512>
boomkat[0x100146af0] <+32>:  ldr    x10, [x10, #0x38]
boomkat[0x100146af4] <+36>:  cbz    x10, 0x100146cd0          ; <+512>
boomkat[0x100146af8] <+40>:  ldr    x9, [x9]
boomkat[0x100146afc] <+44>:  cmp    x10, x9
boomkat[0x100146b00] <+48>:  b.ne   0x100146cd0               ; <+512>
boomkat[0x100146b04] <+52>:  ldr    w9, [x0]
boomkat[0x100146b08] <+56>:  ldr    w10, [x10, #0x40]
boomkat[0x100146b0c] <+60>:  lsr    w11, w9, #16
boomkat[0x100146b10] <+64>:  cmp    w11, w10
boomkat[0x100146b14] <+68>:  b.hs   0x100146cd0               ; <+512>
boomkat[0x100146b18] <+72>:  add    x8, x8, w11, uxtw #4
boomkat[0x100146b1c] <+76>:  ldrb   w10, [x8, #0xe]
boomkat[0x100146b20] <+80>:  tbz    w10, #0x0, 0x100146c28    ; <+344>
boomkat[0x100146b24] <+84>:  ldr    x10, [x3, #0x8]
boomkat[0x100146b28] <+88>:  ldr    x8, [x8]
boomkat[0x100146b2c] <+92>:  ubfx   w9, w9, #8, #8
boomkat[0x100146b30] <+96>:  ldrb   w11, [x10, #0xf73]
boomkat[0x100146b34] <+100>: cmp    w11, #0x1
boomkat[0x100146b38] <+104>: b.ne   0x100146b4c               ; <+124>
boomkat[0x100146b3c] <+108>: mov    x11, #-0xfffd             ; =-65533 
boomkat[0x100146b40] <+112>: add    x11, x11, x8, lsr #48
boomkat[0x100146b44] <+116>: cmn    x11, #0x4
boomkat[0x100146b48] <+120>: b.hs   0x100146c7c               ; <+428>
boomkat[0x100146b4c] <+124>: ldr    x10, [x2, w9, uxtw #3]
boomkat[0x100146b50] <+128>: asr    x11, x10, #48
boomkat[0x100146b54] <+132>: cmn    x11, #0x8
boomkat[0x100146b58] <+136>: b.ne   0x100146b70               ; <+160>
boomkat[0x100146b5c] <+140>: ands   x11, x10, #0xffffffffffff
boomkat[0x100146b60] <+144>: b.eq   0x100146b70               ; <+160>
boomkat[0x100146b64] <+148>: ldr    w11, [x11, #0x4]
boomkat[0x100146b68] <+152>: cmp    w11, #0x2
boomkat[0x100146b6c] <+156>: b.lo   0x100146cd0               ; <+512>
boomkat[0x100146b70] <+160>: asr    x11, x8, #48
boomkat[0x100146b74] <+164>: cmn    x11, #0x8
boomkat[0x100146b78] <+168>: b.ne   0x100146bac               ; <+220>
boomkat[0x100146b7c] <+172>: ands   x11, x8, #0xffffffffffff
boomkat[0x100146b80] <+176>: b.eq   0x100146bac               ; <+220>
boomkat[0x100146b84] <+180>: ldr    w12, [x11, #0x4]
boomkat[0x100146b88] <+184>: mov    w13, #0x7fffffff          ; =2147483647 
boomkat[0x100146b8c] <+188>: cmp    w12, w13
boomkat[0x100146b90] <+192>: b.ne   0x100146ba0               ; <+208>
boomkat[0x100146b94] <+196>: ldrb   w13, [x11]
boomkat[0x100146b98] <+200>: tst    w13, #0x3
boomkat[0x100146b9c] <+204>: b.eq   0x100146bac               ; <+220>
boomkat[0x100146ba0] <+208>: add    w10, w12, #0x1
boomkat[0x100146ba4] <+212>: str    w10, [x11, #0x4]
boomkat[0x100146ba8] <+216>: ldr    x10, [x2, w9, uxtw #3]
boomkat[0x100146bac] <+220>: asr    x11, x10, #48
boomkat[0x100146bb0] <+224>: cmn    x11, #0x8
boomkat[0x100146bb4] <+228>: b.ne   0x100146be4               ; <+276>
boomkat[0x100146bb8] <+232>: ands   x10, x10, #0xffffffffffff
boomkat[0x100146bbc] <+236>: b.eq   0x100146be4               ; <+276>
boomkat[0x100146bc0] <+240>: ldr    w11, [x10, #0x4]
boomkat[0x100146bc4] <+244>: mov    w12, #0x7fffffff          ; =2147483647 
boomkat[0x100146bc8] <+248>: cmp    w11, w12
boomkat[0x100146bcc] <+252>: b.ne   0x100146bdc               ; <+268>
boomkat[0x100146bd0] <+256>: ldrb   w12, [x10]
boomkat[0x100146bd4] <+260>: tst    w12, #0x3
boomkat[0x100146bd8] <+264>: b.eq   0x100146be4               ; <+276>
boomkat[0x100146bdc] <+268>: sub    w11, w11, #0x1
boomkat[0x100146be0] <+272>: str    w11, [x10, #0x4]
boomkat[0x100146be4] <+276>: tst    x8, #0xffffffffffff
boomkat[0x100146be8] <+280>: str    x8, [x2, w9, uxtw #3]
boomkat[0x100146bec] <+284>: b.eq   0x100146c1c               ; <+332>
boomkat[0x100146bf0] <+288>: mov    x9, #-0xfffd              ; =-65533 
boomkat[0x100146bf4] <+292>: add    x8, x9, x8, lsr #48
boomkat[0x100146bf8] <+296>: cmn    x8, #0x5
boomkat[0x100146bfc] <+300>: b.lo   0x100146c1c               ; <+332>
boomkat[0x100146c00] <+304>: ldr    x8, [x3, #0x10]
boomkat[0x100146c04] <+308>: ldrb   w9, [x0, #0x1]
boomkat[0x100146c08] <+312>: ldr    w10, [x8, #0x4c]
boomkat[0x100146c0c] <+316>: cmp    w9, w10
boomkat[0x100146c10] <+320>: b.lo   0x100146c1c               ; <+332>
boomkat[0x100146c14] <+324>: add    w9, w9, #0x1
boomkat[0x100146c18] <+328>: str    w9, [x8, #0x4c]
boomkat[0x100146c1c] <+332>: ldrb   w8, [x0, #0x4]!
boomkat[0x100146c20] <+336>: ldr    x4, [x1, x8, lsl #3]
boomkat[0x100146c24] <+340>: br     x4
boomkat[0x100146c28] <+344>: ldr    x10, [x8]
boomkat[0x100146c2c] <+348>: cbz    x10, 0x100146cd0          ; <+512>
boomkat[0x100146c30] <+352>: ldrb   w11, [x8, #0xd]
boomkat[0x100146c34] <+356>: tbnz   w11, #0x0, 0x100146cd0    ; <+512>
boomkat[0x100146c38] <+360>: ldrb   w11, [x8, #0xc]
boomkat[0x100146c3c] <+364>: tbz    w11, #0x0, 0x100146c50    ; <+384>
boomkat[0x100146c40] <+368>: ldr    w12, [x8, #0x8]
boomkat[0x100146c44] <+372>: ldr    w13, [x10, #0x18]
boomkat[0x100146c48] <+376>: cmp    w12, w13
boomkat[0x100146c4c] <+380>: b.hs   0x100146cd0               ; <+512>
boomkat[0x100146c50] <+384>: ldr    x12, [x10, #0x28]
boomkat[0x100146c54] <+388>: cbnz   x12, 0x100146c68          ; <+408>
boomkat[0x100146c58] <+392>: ldr    w12, [x10, #0x4]
boomkat[0x100146c5c] <+396>: lsr    x12, x12, #8
boomkat[0x100146c60] <+400>: and    x12, x12, #0xf8
boomkat[0x100146c64] <+404>: add    x12, x10, x12
boomkat[0x100146c68] <+408>: ldr    w8, [x8, #0x8]
boomkat[0x100146c6c] <+412>: add    x8, x12, x8, lsl #3
boomkat[0x100146c70] <+416>: tbz    w11, #0x0, 0x100146cbc    ; <+492>
boomkat[0x100146c74] <+420>: cbnz   x12, 0x100146b24          ; <+84>
boomkat[0x100146c78] <+424>: b      0x100146cd0               ; <+512>
boomkat[0x100146c7c] <+428>: lsr    x11, x8, #48
boomkat[0x100146c80] <+432>: mov    w12, #0xfffc              ; =65532 
boomkat[0x100146c84] <+436>: cmp    x11, x12
boomkat[0x100146c88] <+440>: b.eq   0x100146cd0               ; <+512>
boomkat[0x100146c8c] <+444>: ands   x11, x8, #0xffffffffffff
boomkat[0x100146c90] <+448>: b.eq   0x100146b4c               ; <+124>
boomkat[0x100146c94] <+452>: ldrb   w12, [x11]
boomkat[0x100146c98] <+456>: tbnz   w12, #0x2, 0x100146b4c    ; <+124>
boomkat[0x100146c9c] <+460>: ldrb   w12, [x10, #0xf74]
boomkat[0x100146ca0] <+464>: cbz    w12, 0x100146cd0          ; <+512>
boomkat[0x100146ca4] <+468>: ldrb   w11, [x11, #0x4]
boomkat[0x100146ca8] <+472>: tbz    w11, #0x1, 0x100146cd0    ; <+512>
boomkat[0x100146cac] <+476>: mov    w11, #0x1049              ; =4169 
boomkat[0x100146cb0] <+480>: ldrb   w10, [x10, x11]
boomkat[0x100146cb4] <+484>: tbz    w10, #0x0, 0x100146b4c    ; <+124>
boomkat[0x100146cb8] <+488>: b      0x100146cd0               ; <+512>
boomkat[0x100146cbc] <+492>: ldr    x10, [x8]
boomkat[0x100146cc0] <+496>: asr    x11, x10, #48
boomkat[0x100146cc4] <+500>: tst    x10, #0xffffffffffff
boomkat[0x100146cc8] <+504>: ccmn   x11, #0xd, #0x0, ne
boomkat[0x100146ccc] <+508>: b.ne   0x100146b24               ; <+84>
boomkat[0x100146cd0] <+512>: ret    
(lldb) quit
