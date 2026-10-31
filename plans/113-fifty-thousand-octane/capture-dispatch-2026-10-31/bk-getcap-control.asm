(lldb) target create out/boomkat
Current executable set to '/Users/rtomasi/cousas/boomkat/.worktrees/rat/out/boomkat' (arm64).
(lldb) disassemble -n boomkat.vm.th_getcap
boomkat`boomkat.vm.th_getcap:
boomkat[0x100146ad0] <+0>:   stp    x24, x23, [sp, #-0x40]!
boomkat[0x100146ad4] <+4>:   stp    x22, x21, [sp, #0x10]
boomkat[0x100146ad8] <+8>:   stp    x20, x19, [sp, #0x20]
boomkat[0x100146adc] <+12>:  stp    x29, x30, [sp, #0x30]
boomkat[0x100146ae0] <+16>:  ldr    w23, [x0]
boomkat[0x100146ae4] <+20>:  mov    x21, x0
boomkat[0x100146ae8] <+24>:  ldr    x0, [x3, #0x10]
boomkat[0x100146aec] <+28>:  mov    x22, x1
boomkat[0x100146af0] <+32>:  mov    x19, x3
boomkat[0x100146af4] <+36>:  mov    x20, x2
boomkat[0x100146af8] <+40>:  lsr    w8, w23, #16
boomkat[0x100146afc] <+44>:  mov    w1, w8
boomkat[0x100146b00] <+48>:  bl     0x10014ee8c               ; boomkat.vm.capture_read_slot
boomkat[0x100146b04] <+52>:  cbz    x0, 0x100146c40           ; <+368>
boomkat[0x100146b08] <+56>:  ldr    x10, [x19, #0x8]
boomkat[0x100146b0c] <+60>:  ldr    x8, [x0]
boomkat[0x100146b10] <+64>:  ubfx   w9, w23, #8, #8
boomkat[0x100146b14] <+68>:  ldrb   w11, [x10, #0xf73]
boomkat[0x100146b18] <+72>:  cmp    w11, #0x1
boomkat[0x100146b1c] <+76>:  b.ne   0x100146b30               ; <+96>
boomkat[0x100146b20] <+80>:  mov    x11, #-0xfffd             ; =-65533 
boomkat[0x100146b24] <+84>:  add    x11, x11, x8, lsr #48
boomkat[0x100146b28] <+88>:  cmn    x11, #0x4
boomkat[0x100146b2c] <+92>:  b.hs   0x100146c30               ; <+352>
boomkat[0x100146b30] <+96>:  ldr    x10, [x20, w9, uxtw #3]
boomkat[0x100146b34] <+100>: asr    x11, x10, #48
boomkat[0x100146b38] <+104>: cmn    x11, #0x8
boomkat[0x100146b3c] <+108>: and    x11, x10, #0xffffffffffff
boomkat[0x100146b40] <+112>: ccmp   x11, #0x0, #0x4, eq
boomkat[0x100146b44] <+116>: b.ne   0x100146c20               ; <+336>
boomkat[0x100146b48] <+120>: asr    x11, x8, #48
boomkat[0x100146b4c] <+124>: cmn    x11, #0x8
boomkat[0x100146b50] <+128>: b.ne   0x100146b84               ; <+180>
boomkat[0x100146b54] <+132>: ands   x11, x8, #0xffffffffffff
boomkat[0x100146b58] <+136>: b.eq   0x100146b84               ; <+180>
boomkat[0x100146b5c] <+140>: ldr    w12, [x11, #0x4]
boomkat[0x100146b60] <+144>: mov    w13, #0x7fffffff          ; =2147483647 
boomkat[0x100146b64] <+148>: cmp    w12, w13
boomkat[0x100146b68] <+152>: b.ne   0x100146b78               ; <+168>
boomkat[0x100146b6c] <+156>: ldrb   w13, [x11]
boomkat[0x100146b70] <+160>: tst    w13, #0x3
boomkat[0x100146b74] <+164>: b.eq   0x100146b84               ; <+180>
boomkat[0x100146b78] <+168>: add    w10, w12, #0x1
boomkat[0x100146b7c] <+172>: str    w10, [x11, #0x4]
boomkat[0x100146b80] <+176>: ldr    x10, [x20, w9, uxtw #3]
boomkat[0x100146b84] <+180>: asr    x11, x10, #48
boomkat[0x100146b88] <+184>: cmn    x11, #0x8
boomkat[0x100146b8c] <+188>: b.ne   0x100146bbc               ; <+236>
boomkat[0x100146b90] <+192>: ands   x10, x10, #0xffffffffffff
boomkat[0x100146b94] <+196>: b.eq   0x100146bbc               ; <+236>
boomkat[0x100146b98] <+200>: ldr    w11, [x10, #0x4]
boomkat[0x100146b9c] <+204>: mov    w12, #0x7fffffff          ; =2147483647 
boomkat[0x100146ba0] <+208>: cmp    w11, w12
boomkat[0x100146ba4] <+212>: b.ne   0x100146bb4               ; <+228>
boomkat[0x100146ba8] <+216>: ldrb   w12, [x10]
boomkat[0x100146bac] <+220>: tst    w12, #0x3
boomkat[0x100146bb0] <+224>: b.eq   0x100146bbc               ; <+236>
boomkat[0x100146bb4] <+228>: sub    w11, w11, #0x1
boomkat[0x100146bb8] <+232>: str    w11, [x10, #0x4]
boomkat[0x100146bbc] <+236>: tst    x8, #0xffffffffffff
boomkat[0x100146bc0] <+240>: str    x8, [x20, w9, uxtw #3]
boomkat[0x100146bc4] <+244>: b.eq   0x100146bf4               ; <+292>
boomkat[0x100146bc8] <+248>: mov    x9, #-0xfffd              ; =-65533 
boomkat[0x100146bcc] <+252>: add    x8, x9, x8, lsr #48
boomkat[0x100146bd0] <+256>: cmn    x8, #0x5
boomkat[0x100146bd4] <+260>: b.lo   0x100146bf4               ; <+292>
boomkat[0x100146bd8] <+264>: ldr    x8, [x19, #0x10]
boomkat[0x100146bdc] <+268>: ldrb   w9, [x21, #0x1]
boomkat[0x100146be0] <+272>: ldr    w10, [x8, #0x4c]
boomkat[0x100146be4] <+276>: cmp    w9, w10
boomkat[0x100146be8] <+280>: b.lo   0x100146bf4               ; <+292>
boomkat[0x100146bec] <+284>: add    w9, w9, #0x1
boomkat[0x100146bf0] <+288>: str    w9, [x8, #0x4c]
boomkat[0x100146bf4] <+292>: ldrb   w8, [x21, #0x4]!
boomkat[0x100146bf8] <+296>: mov    x0, x21
boomkat[0x100146bfc] <+300>: mov    x1, x22
boomkat[0x100146c00] <+304>: mov    x2, x20
boomkat[0x100146c04] <+308>: mov    x3, x19
boomkat[0x100146c08] <+312>: ldr    x4, [x22, x8, lsl #3]
boomkat[0x100146c0c] <+316>: ldp    x29, x30, [sp, #0x30]
boomkat[0x100146c10] <+320>: ldp    x20, x19, [sp, #0x20]
boomkat[0x100146c14] <+324>: ldp    x22, x21, [sp, #0x10]
boomkat[0x100146c18] <+328>: ldp    x24, x23, [sp], #0x40
boomkat[0x100146c1c] <+332>: br     x4
boomkat[0x100146c20] <+336>: ldr    w11, [x11, #0x4]
boomkat[0x100146c24] <+340>: cmp    w11, #0x2
boomkat[0x100146c28] <+344>: b.hs   0x100146b48               ; <+120>
boomkat[0x100146c2c] <+348>: b      0x100146c40               ; <+368>
boomkat[0x100146c30] <+352>: lsr    x11, x8, #48
boomkat[0x100146c34] <+356>: mov    w12, #0xfffc              ; =65532 
boomkat[0x100146c38] <+360>: cmp    x11, x12
boomkat[0x100146c3c] <+364>: b.ne   0x100146c58               ; <+392>
boomkat[0x100146c40] <+368>: mov    x0, x21
boomkat[0x100146c44] <+372>: ldp    x29, x30, [sp, #0x30]
boomkat[0x100146c48] <+376>: ldp    x20, x19, [sp, #0x20]
boomkat[0x100146c4c] <+380>: ldp    x22, x21, [sp, #0x10]
boomkat[0x100146c50] <+384>: ldp    x24, x23, [sp], #0x40
boomkat[0x100146c54] <+388>: ret    
boomkat[0x100146c58] <+392>: ands   x11, x8, #0xffffffffffff
boomkat[0x100146c5c] <+396>: b.eq   0x100146b30               ; <+96>
boomkat[0x100146c60] <+400>: ldrb   w12, [x11]
boomkat[0x100146c64] <+404>: tbnz   w12, #0x2, 0x100146b30    ; <+96>
boomkat[0x100146c68] <+408>: ldrb   w12, [x10, #0xf74]
boomkat[0x100146c6c] <+412>: cbz    w12, 0x100146c40          ; <+368>
boomkat[0x100146c70] <+416>: ldrb   w11, [x11, #0x4]
boomkat[0x100146c74] <+420>: tbz    w11, #0x1, 0x100146c40    ; <+368>
boomkat[0x100146c78] <+424>: mov    w11, #0x1049              ; =4169 
boomkat[0x100146c7c] <+428>: ldrb   w10, [x10, x11]
boomkat[0x100146c80] <+432>: tbz    w10, #0x0, 0x100146b30    ; <+96>
boomkat[0x100146c84] <+436>: b      0x100146c40               ; <+368>
(lldb) disassemble -n boomkat.vm.capture_read_slot
boomkat`boomkat.vm.capture_read_slot:
boomkat[0x10014ee8c] <+0>:   ldr    x8, [x0, #0x70]
boomkat[0x10014ee90] <+4>:   asr    x9, x8, #48
boomkat[0x10014ee94] <+8>:   cmn    x9, #0x7
boomkat[0x10014ee98] <+12>:  b.ne   0x10014eee4               ; <+88>
boomkat[0x10014ee9c] <+16>:  and    x9, x8, #0xffffffffffff
boomkat[0x10014eea0] <+20>:  ldr    x8, [x9, #0x80]
boomkat[0x10014eea4] <+24>:  cbz    x8, 0x10014eee4           ; <+88>
boomkat[0x10014eea8] <+28>:  ldr    x9, [x9, #0x38]
boomkat[0x10014eeac] <+32>:  cbz    x9, 0x10014eee4           ; <+88>
boomkat[0x10014eeb0] <+36>:  ldr    x10, [x0]
boomkat[0x10014eeb4] <+40>:  cmp    x9, x10
boomkat[0x10014eeb8] <+44>:  b.ne   0x10014eee4               ; <+88>
boomkat[0x10014eebc] <+48>:  ldr    w9, [x9, #0x40]
boomkat[0x10014eec0] <+52>:  cmp    w1, w9
boomkat[0x10014eec4] <+56>:  b.hs   0x10014eee4               ; <+88>
boomkat[0x10014eec8] <+60>:  add    x0, x8, w1, uxtw #4
boomkat[0x10014eecc] <+64>:  ldrb   w8, [x0, #0xe]
boomkat[0x10014eed0] <+68>:  tbnz   w8, #0x0, 0x10014eee8     ; <+92>
boomkat[0x10014eed4] <+72>:  ldr    x9, [x0]
boomkat[0x10014eed8] <+76>:  cbz    x9, 0x10014eee4           ; <+88>
boomkat[0x10014eedc] <+80>:  ldrb   w8, [x0, #0xd]
boomkat[0x10014eee0] <+84>:  tbz    w8, #0x0, 0x10014eeec     ; <+96>
boomkat[0x10014eee4] <+88>:  mov    x0, xzr
boomkat[0x10014eee8] <+92>:  ret    
boomkat[0x10014eeec] <+96>:  ldrb   w8, [x0, #0xc]
boomkat[0x10014eef0] <+100>: tbz    w8, #0x0, 0x10014ef04     ; <+120>
boomkat[0x10014eef4] <+104>: ldr    w10, [x0, #0x8]
boomkat[0x10014eef8] <+108>: ldr    w11, [x9, #0x18]
boomkat[0x10014eefc] <+112>: cmp    w10, w11
boomkat[0x10014ef00] <+116>: b.hs   0x10014eee4               ; <+88>
boomkat[0x10014ef04] <+120>: ldr    x10, [x9, #0x28]
boomkat[0x10014ef08] <+124>: cbnz   x10, 0x10014ef1c          ; <+144>
boomkat[0x10014ef0c] <+128>: ldr    w10, [x9, #0x4]
boomkat[0x10014ef10] <+132>: lsr    x10, x10, #8
boomkat[0x10014ef14] <+136>: and    x10, x10, #0xf8
boomkat[0x10014ef18] <+140>: add    x10, x9, x10
boomkat[0x10014ef1c] <+144>: ldr    w9, [x0, #0x8]
boomkat[0x10014ef20] <+148>: add    x0, x10, x9, lsl #3
boomkat[0x10014ef24] <+152>: tbnz   w8, #0x0, 0x10014eee8     ; <+92>
boomkat[0x10014ef28] <+156>: ldr    x8, [x0]
boomkat[0x10014ef2c] <+160>: asr    x9, x8, #48
boomkat[0x10014ef30] <+164>: tst    x8, #0xffffffffffff
boomkat[0x10014ef34] <+168>: ccmn   x9, #0xd, #0x0, ne
boomkat[0x10014ef38] <+172>: b.eq   0x10014eee4               ; <+88>
boomkat[0x10014ef3c] <+176>: b      0x10014eee8               ; <+92>
(lldb) quit
