/*
Copyright (c) 2014, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice,
    * this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright notice,
    * this list of conditions and the following disclaimer in the documentation
    * and/or other materials provided with the distribution.

    * Neither the name of Intel Corporation nor the names of its contributors
    * may be used to endorse or promote products derived from this software
    * without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/******************************************************************************/
//                     ALGORITHM DESCRIPTION
//                     ---------------------
//
//     1. RANGE REDUCTION
//
//     We perform an initial range reduction from X to r with
//
//          X =~= N * pi/32 + r
//
//     so that |r| <= pi/64 + epsilon. We restrict inputs to those
//     where |N| <= 932560. Beyond this, the range reduction is
//     insufficiently accurate. For extremely small inputs, 
//     denormalization can occur internally, impacting performance.
//     This means that the main path is actually only taken for
//     2^-252 <= |X| < 90112.
//
//     To avoid branches, we perform the range reduction to full
//     accuracy each time.
//
//          X - N * (P_1 + P_2 + P_3)
//
//     where P_1 and P_2 are 32-bit numbers (so multiplication by N
//     is exact) and P_3 is a 53-bit number. Together, these
//     approximate pi well enough for all cases in the restricted
//     range.
//
//     The main reduction sequence is:
//
//             y = 32/pi * x
//             N = integer(y)
//     (computed by adding and subtracting off SHIFTER)
//
//             m_1 = N * P_1
//             m_2 = N * P_2
//             r_1 = x - m_1
//             r = r_1 - m_2
//     (this r can be used for most of the calculation)
//
//             c_1 = r_1 - r
//             m_3 = N * P_3
//             c_2 = c_1 - m_2
//             c = c_2 - m_3
//
//     2. MAIN ALGORITHM
//
//     The algorithm uses a table lookup based on B = M * pi / 32
//     where M = N mod 64. The stored values are:
//       sigma             closest power of 2 to cos(B)
//       C_hl              53-bit cos(B) - sigma
//       S_hi + S_lo       2 * 53-bit sin(B)
//
//     The computation is organized as follows:
//
//          sin(B + r + c) = [sin(B) + sigma * r] +
//                           r * (cos(B) - sigma) +
//                           sin(B) * [cos(r + c) - 1] +
//                           cos(B) * [sin(r + c) - r]
//
//     which is approximately:
//
//          [S_hi + sigma * r] +
//          C_hl * r +
//          S_lo + S_hi * [(cos(r) - 1) - r * c] +
//          (C_hl + sigma) * [(sin(r) - r) + c]
//
//     and this is what is actually computed. We separate this sum
//     into four parts:
//
//          hi + med + pols + corr
//
//     where
//
//          hi       = S_hi + sigma r
//          med      = C_hl * r
//          pols     = S_hi * (cos(r) - 1) + (C_hl + sigma) * (sin(r) - r)
//          corr     = S_lo + c * ((C_hl + sigma) - S_hi * r)
//
//     3. POLYNOMIAL
//
//     The polynomial S_hi * (cos(r) - 1) + (C_hl + sigma) *
//     (sin(r) - r) can be rearranged freely, since it is quite
//     small, so we exploit parallelism to the fullest.
//
//          psc4       =   SC_4 * r_1
//          msc4       =   psc4 * r
//          r2         =   r * r
//          msc2       =   SC_2 * r2
//          r4         =   r2 * r2
//          psc3       =   SC_3 + msc4
//          psc1       =   SC_1 + msc2
//          msc3       =   r4 * psc3
//          sincospols =   psc1 + msc3
//          pols       =   sincospols *
//                         <S_hi * r^2 | (C_hl + sigma) * r^3>
//
//     4. CORRECTION TERM
//
//     This is where the "c" component of the range reduction is
//     taken into account; recall that just "r" is used for most of
//     the calculation.
//
//          -c   = m_3 - c_2
//          -d   = S_hi * r - (C_hl + sigma)
//          corr = -c * -d + S_lo
//
//     5. COMPENSATED SUMMATIONS
//
//     The two successive compensated summations add up the high
//     and medium parts, leaving just the low parts to add up at
//     the end.
//
//          rs        =  sigma * r
//          res_int   =  S_hi + rs
//          k_0       =  S_hi - res_int
//          k_2       =  k_0 + rs
//          med       =  C_hl * r
//          res_hi    =  res_int + med
//          k_1       =  res_int - res_hi
//          k_3       =  k_1 + med
//
//     6. FINAL SUMMATION
//
//     We now add up all the small parts:
//
//          res_lo = pols(hi) + pols(lo) + corr + k_1 + k_3
//
//     Now the overall result is just:
//
//          res_hi + res_lo
//
//     7. SMALL ARGUMENTS
//
//     Inputs with |X| < 2^-252 are treated specially as
//     1 - |x|.
//
// Special cases:
//  cos(NaN) = quiet NaN, and raise invalid exception
//  cos(INF) = NaN and raise invalid exception
//  cos(0) = 1
//
/******************************************************************************/

#include <private/bionic_asm.h>
# -- Begin  static_func
        .text
        .align __bionic_asm_align
        .type static_func, @function
static_func:
..B1.1:
        call      ..L2
..L2:
        popl      %eax
        lea       _GLOBAL_OFFSET_TABLE_+[. - ..L2](%eax), %eax
        lea       static_const_table@GOTOFF(%eax), %eax
        ret
        .size   static_func,.-static_func
# -- End  static_func

# -- Begin  cos
ENTRY(cos)
# parameter 1: 8 + %ebp
..B2.1:
..B2.2:
        pushl     %ebp
        movl      %esp, %ebp
        subl      $120, %esp
        movl      %ebx, 56(%esp)
        call      static_func
        movl      %eax, %ebx
        movsd     128(%esp), %xmm0
        pextrw    $3, %xmm0, %eax
        andl      $32767, %eax
        subl      $12336, %eax
        cmpl      $4293, %eax
        ja        .L_2TAG_PACKET_0.0.2
        movsd     2160(%ebx), %xmm1
        mulsd     %xmm0, %xmm1
        movapd    2240(%ebx), %xmm5
        movsd     2224(%ebx), %xmm4
        andpd     %xmm0, %xmm4
        orps      %xmm4, %xmm5
        movsd     2128(%ebx), %xmm3
        movapd    2112(%ebx), %xmm2
        addpd     %xmm5, %xmm1
        cvttsd2si %xmm1, %edx
        cvtsi2sdl %edx, %xmm1
        mulsd     %xmm1, %xmm3
        unpcklpd  %xmm1, %xmm1
        addl      $1865232, %edx
        movapd    %xmm0, %xmm4
        andl      $63, %edx
        movapd    2096(%ebx), %xmm5
        lea       (%ebx), %eax
        shll      $5, %edx
        addl      %edx, %eax
        mulpd     %xmm1, %xmm2
        subsd     %xmm3, %xmm0
        mulsd     2144(%ebx), %xmm1
        subsd     %xmm3, %xmm4
        movsd     8(%eax), %xmm7
        unpcklpd  %xmm0, %xmm0
        movapd    %xmm4, %xmm3
        subsd     %xmm2, %xmm4
        mulpd     %xmm0, %xmm5
        subpd     %xmm2, %xmm0
        movapd    2064(%ebx), %xmm6
        mulsd     %xmm4, %xmm7
        subsd     %xmm4, %xmm3
        mulpd     %xmm0, %xmm5
        mulpd     %xmm0, %xmm0
        subsd     %xmm2, %xmm3
        movapd    (%eax), %xmm2
        subsd     %xmm3, %xmm1
        movsd     24(%eax), %xmm3
        addsd     %xmm3, %xmm2
        subsd     %xmm2, %xmm7
        mulsd     %xmm4, %xmm2
        mulpd     %xmm0, %xmm6
        mulsd     %xmm4, %xmm3
        mulpd     %xmm0, %xmm2
        mulpd     %xmm0, %xmm0
        addpd     2080(%ebx), %xmm5
        mulsd     (%eax), %xmm4
        addpd     2048(%ebx), %xmm6
        mulpd     %xmm0, %xmm5
        movapd    %xmm3, %xmm0
        addsd     8(%eax), %xmm3
        mulpd     %xmm7, %xmm1
        movapd    %xmm4, %xmm7
        addsd     %xmm3, %xmm4
        addpd     %xmm5, %xmm6
        movsd     8(%eax), %xmm5
        subsd     %xmm3, %xmm5
        subsd     %xmm4, %xmm3
        addsd     16(%eax), %xmm1
        mulpd     %xmm2, %xmm6
        addsd     %xmm0, %xmm5
        addsd     %xmm7, %xmm3
        addsd     %xmm5, %xmm1
        addsd     %xmm3, %xmm1
        addsd     %xmm6, %xmm1
        unpckhpd  %xmm6, %xmm6
        addsd     %xmm6, %xmm1
        addsd     %xmm1, %xmm4
        movsd     %xmm4, (%esp)
        fldl      (%esp)
        jmp       .L_2TAG_PACKET_1.0.2
.L_2TAG_PACKET_0.0.2:
        jg        .L_2TAG_PACKET_2.0.2
        pextrw    $3, %xmm0, %eax
        andl      $32767, %eax
        pinsrw    $3, %eax, %xmm0
        movsd     2192(%ebx), %xmm1
        subsd     %xmm0, %xmm1
        movsd     %xmm1, (%esp)
        fldl      (%esp)
        jmp       .L_2TAG_PACKET_1.0.2
.L_2TAG_PACKET_2.0.2:
        movl      132(%esp), %eax
        andl      $2146435072, %eax
        cmpl      $2146435072, %eax
        je        .L_2TAG_PACKET_3.0.2
        subl      $32, %esp
        movsd     %xmm0, (%esp)
        lea       40(%esp), %eax
        movl      %eax, 8(%esp)
        movl      $1, %eax
        movl      %eax, 12(%esp)
        call      __libm_sincos_huge
        addl      $32, %esp
        fldl      8(%esp)
        jmp       .L_2TAG_PACKET_1.0.2
.L_2TAG_PACKET_3.0.2:
        fldl      128(%esp)
        fmull     2208(%ebx)
.L_2TAG_PACKET_1.0.2:
        movl      56(%esp), %ebx
        movl      %ebp, %esp
        popl      %ebp
        ret       
..B2.3:
END(cos)
# -- End  cos

# Start file scope ASM
.weak cosl
.equ cosl, cos
# End file scope ASM
	.section .rodata, "a"
	.align 16
	.align 16
static_const_table:
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	1072693248
	.long	393047345
	.long	3212032302
	.long	3156849708
	.long	1069094822
	.long	3758096384
	.long	3158189848
	.long	0
	.long	1072693248
	.long	18115067
	.long	3214126342
	.long	1013556747
	.long	1070135480
	.long	3221225472
	.long	3160567065
	.long	0
	.long	1072693248
	.long	2476548698
	.long	3215330282
	.long	785751814
	.long	1070765062
	.long	2684354560
	.long	3161838221
	.long	0
	.long	1072693248
	.long	2255197647
	.long	3216211105
	.long	2796464483
	.long	1071152610
	.long	3758096384
	.long	3160878317
	.long	0
	.long	1072693248
	.long	1945768569
	.long	3216915048
	.long	939980347
	.long	1071524701
	.long	536870912
	.long	1012796809
	.long	0
	.long	1072693248
	.long	1539668340
	.long	3217396327
	.long	967731400
	.long	1071761211
	.long	536870912
	.long	1015752157
	.long	0
	.long	1072693248
	.long	1403757309
	.long	3217886718
	.long	621354454
	.long	1071926515
	.long	536870912
	.long	1013450602
	.long	0
	.long	1072693248
	.long	2583490354
	.long	1070236281
	.long	1719614413
	.long	1072079006
	.long	536870912
	.long	3163282740
	.long	0
	.long	1071644672
	.long	2485417816
	.long	1069626316
	.long	1796544321
	.long	1072217216
	.long	536870912
	.long	3162686945
	.long	0
	.long	1071644672
	.long	2598800519
	.long	1068266419
	.long	688824739
	.long	1072339814
	.long	3758096384
	.long	1010431536
	.long	0
	.long	1071644672
	.long	2140183630
	.long	3214756396
	.long	4051746225
	.long	1072445618
	.long	2147483648
	.long	3161907377
	.long	0
	.long	1071644672
	.long	1699043957
	.long	3216902261
	.long	3476196678
	.long	1072533611
	.long	536870912
	.long	1014257638
	.long	0
	.long	1071644672
	.long	1991047213
	.long	1067753521
	.long	1455828442
	.long	1072602945
	.long	3758096384
	.long	1015505073
	.long	0
	.long	1070596096
	.long	240740309
	.long	3215727903
	.long	3489094832
	.long	1072652951
	.long	536870912
	.long	1014325783
	.long	0
	.long	1070596096
	.long	257503056
	.long	3214647653
	.long	2748392742
	.long	1072683149
	.long	1073741824
	.long	3163061750
	.long	0
	.long	1069547520
	.long	0
	.long	0
	.long	0
	.long	1072693248
	.long	0
	.long	0
	.long	0
	.long	0
	.long	257503056
	.long	1067164005
	.long	2748392742
	.long	1072683149
	.long	1073741824
	.long	3163061750
	.long	0
	.long	3217031168
	.long	240740309
	.long	1068244255
	.long	3489094832
	.long	1072652951
	.long	536870912
	.long	1014325783
	.long	0
	.long	3218079744
	.long	1991047213
	.long	3215237169
	.long	1455828442
	.long	1072602945
	.long	3758096384
	.long	1015505073
	.long	0
	.long	3218079744
	.long	1699043957
	.long	1069418613
	.long	3476196678
	.long	1072533611
	.long	536870912
	.long	1014257638
	.long	0
	.long	3219128320
	.long	2140183630
	.long	1067272748
	.long	4051746225
	.long	1072445618
	.long	2147483648
	.long	3161907377
	.long	0
	.long	3219128320
	.long	2598800519
	.long	3215750067
	.long	688824739
	.long	1072339814
	.long	3758096384
	.long	1010431536
	.long	0
	.long	3219128320
	.long	2485417816
	.long	3217109964
	.long	1796544321
	.long	1072217216
	.long	536870912
	.long	3162686945
	.long	0
	.long	3219128320
	.long	2583490354
	.long	3217719929
	.long	1719614413
	.long	1072079006
	.long	536870912
	.long	3163282740
	.long	0
	.long	3219128320
	.long	1403757309
	.long	1070403070
	.long	621354454
	.long	1071926515
	.long	536870912
	.long	1013450602
	.long	0
	.long	3220176896
	.long	1539668340
	.long	1069912679
	.long	967731400
	.long	1071761211
	.long	536870912
	.long	1015752157
	.long	0
	.long	3220176896
	.long	1945768569
	.long	1069431400
	.long	939980347
	.long	1071524701
	.long	536870912
	.long	1012796809
	.long	0
	.long	3220176896
	.long	2255197647
	.long	1068727457
	.long	2796464483
	.long	1071152610
	.long	3758096384
	.long	3160878317
	.long	0
	.long	3220176896
	.long	2476548698
	.long	1067846634
	.long	785751814
	.long	1070765062
	.long	2684354560
	.long	3161838221
	.long	0
	.long	3220176896
	.long	18115067
	.long	1066642694
	.long	1013556747
	.long	1070135480
	.long	3221225472
	.long	3160567065
	.long	0
	.long	3220176896
	.long	393047345
	.long	1064548654
	.long	3156849708
	.long	1069094822
	.long	3758096384
	.long	3158189848
	.long	0
	.long	3220176896
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	3220176896
	.long	393047345
	.long	1064548654
	.long	3156849708
	.long	3216578470
	.long	3758096384
	.long	1010706200
	.long	0
	.long	3220176896
	.long	18115067
	.long	1066642694
	.long	1013556747
	.long	3217619128
	.long	3221225472
	.long	1013083417
	.long	0
	.long	3220176896
	.long	2476548698
	.long	1067846634
	.long	785751814
	.long	3218248710
	.long	2684354560
	.long	1014354573
	.long	0
	.long	3220176896
	.long	2255197647
	.long	1068727457
	.long	2796464483
	.long	3218636258
	.long	3758096384
	.long	1013394669
	.long	0
	.long	3220176896
	.long	1945768569
	.long	1069431400
	.long	939980347
	.long	3219008349
	.long	536870912
	.long	3160280457
	.long	0
	.long	3220176896
	.long	1539668340
	.long	1069912679
	.long	967731400
	.long	3219244859
	.long	536870912
	.long	3163235805
	.long	0
	.long	3220176896
	.long	1403757309
	.long	1070403070
	.long	621354454
	.long	3219410163
	.long	536870912
	.long	3160934250
	.long	0
	.long	3220176896
	.long	2583490354
	.long	3217719929
	.long	1719614413
	.long	3219562654
	.long	536870912
	.long	1015799092
	.long	0
	.long	3219128320
	.long	2485417816
	.long	3217109964
	.long	1796544321
	.long	3219700864
	.long	536870912
	.long	1015203297
	.long	0
	.long	3219128320
	.long	2598800519
	.long	3215750067
	.long	688824739
	.long	3219823462
	.long	3758096384
	.long	3157915184
	.long	0
	.long	3219128320
	.long	2140183630
	.long	1067272748
	.long	4051746225
	.long	3219929266
	.long	2147483648
	.long	1014423729
	.long	0
	.long	3219128320
	.long	1699043957
	.long	1069418613
	.long	3476196678
	.long	3220017259
	.long	536870912
	.long	3161741286
	.long	0
	.long	3219128320
	.long	1991047213
	.long	3215237169
	.long	1455828442
	.long	3220086593
	.long	3758096384
	.long	3162988721
	.long	0
	.long	3218079744
	.long	240740309
	.long	1068244255
	.long	3489094832
	.long	3220136599
	.long	536870912
	.long	3161809431
	.long	0
	.long	3218079744
	.long	257503056
	.long	1067164005
	.long	2748392742
	.long	3220166797
	.long	1073741824
	.long	1015578102
	.long	0
	.long	3217031168
	.long	0
	.long	0
	.long	0
	.long	3220176896
	.long	0
	.long	0
	.long	0
	.long	0
	.long	257503056
	.long	3214647653
	.long	2748392742
	.long	3220166797
	.long	1073741824
	.long	1015578102
	.long	0
	.long	1069547520
	.long	240740309
	.long	3215727903
	.long	3489094832
	.long	3220136599
	.long	536870912
	.long	3161809431
	.long	0
	.long	1070596096
	.long	1991047213
	.long	1067753521
	.long	1455828442
	.long	3220086593
	.long	3758096384
	.long	3162988721
	.long	0
	.long	1070596096
	.long	1699043957
	.long	3216902261
	.long	3476196678
	.long	3220017259
	.long	536870912
	.long	3161741286
	.long	0
	.long	1071644672
	.long	2140183630
	.long	3214756396
	.long	4051746225
	.long	3219929266
	.long	2147483648
	.long	1014423729
	.long	0
	.long	1071644672
	.long	2598800519
	.long	1068266419
	.long	688824739
	.long	3219823462
	.long	3758096384
	.long	3157915184
	.long	0
	.long	1071644672
	.long	2485417816
	.long	1069626316
	.long	1796544321
	.long	3219700864
	.long	536870912
	.long	1015203297
	.long	0
	.long	1071644672
	.long	2583490354
	.long	1070236281
	.long	1719614413
	.long	3219562654
	.long	536870912
	.long	1015799092
	.long	0
	.long	1071644672
	.long	1403757309
	.long	3217886718
	.long	621354454
	.long	3219410163
	.long	536870912
	.long	3160934250
	.long	0
	.long	1072693248
	.long	1539668340
	.long	3217396327
	.long	967731400
	.long	3219244859
	.long	536870912
	.long	3163235805
	.long	0
	.long	1072693248
	.long	1945768569
	.long	3216915048
	.long	939980347
	.long	3219008349
	.long	536870912
	.long	3160280457
	.long	0
	.long	1072693248
	.long	2255197647
	.long	3216211105
	.long	2796464483
	.long	3218636258
	.long	3758096384
	.long	1013394669
	.long	0
	.long	1072693248
	.long	2476548698
	.long	3215330282
	.long	785751814
	.long	3218248710
	.long	2684354560
	.long	1014354573
	.long	0
	.long	1072693248
	.long	18115067
	.long	3214126342
	.long	1013556747
	.long	3217619128
	.long	3221225472
	.long	1013083417
	.long	0
	.long	1072693248
	.long	393047345
	.long	3212032302
	.long	3156849708
	.long	3216578470
	.long	3758096384
	.long	1010706200
	.long	0
	.long	1072693248
	.long	1431655765
	.long	3217380693
	.long	0
	.long	3219128320
	.long	286331153
	.long	1065423121
	.long	1431655765
	.long	1067799893
	.long	436314138
	.long	3207201184
	.long	381774871
	.long	3210133868
	.long	2773927732
	.long	1053236707
	.long	436314138
	.long	1056571808
	.long	442499072
	.long	1032893537
	.long	442499072
	.long	1032893537
	.long	1413480448
	.long	1069097467
	.long	0
	.long	0
	.long	771977331
	.long	996350346
	.long	0
	.long	0
	.long	1841940611
	.long	1076125488
	.long	0
	.long	0
	.long	0
	.long	1127743488
	.long	0
	.long	0
	.long	0
	.long	1072693248
	.long	0
	.long	0
	.long	0
	.long	2147483648
	.long	0
	.long	0
	.long	0
	.long	2147483648
	.long	0
	.long	0
	.long	0
	.long	1071644672
	.long	0
	.long	1071644672
	.type	static_const_table,@object
	.size	static_const_table,2256
	.data
	.hidden __libm_sincos_huge
	.section .note.GNU-stack, ""
# End
