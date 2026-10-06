# Original G.726 and G.722 ADPCM decoders in x86-64 assembly. MIT, see LICENSE.
# G.726 (16-40 kbit/s, 2-5-bit codes): the adaptive quantizer's inverse,
# its fast/slow scale factors and speed control, tone and transition
# detection, and the pole-zero predictor, whose products use G.726's 11-bit
# floating-point arithmetic. G.722 (64 kbit/s, 8-bit codewords at 16 kHz):
# a 6-bit low and 2-bit high band, each with its own adaptive quantizer and
# pole-zero predictor, recombined by the 24-tap quadrature mirror filter.
# Arithmetic follows FFmpeg's g726.c and g722.c/g722dec.c, which the tests
# compare against; the tables are G.726's and G.722's (as FFmpeg lists
# them). Called by src/adpcm.s for the WAVE, AU and private tags.
.include "lamp.inc"
.globl g726_reset, g726_block, g722_reset, g722_block

# G.726 state: values are dwords; an 11-bit float is sign, exponent and
# mantissa dwords.
.equ GA_A, 0                        # a[2]
.equ GA_B, 8                        # b[6]
.equ GA_PK, 32                      # pk[2]
.equ GA_SR, 40                      # sr[2] floats
.equ GA_DQ, 64                      # dq[6] floats
.equ GA_AP, 136
.equ GA_YU, 140
.equ GA_YL, 144
.equ GA_DMS, 148
.equ GA_DML, 152
.equ GA_TD, 156
.equ GA_SE, 160
.equ GA_SEZ, 164
.equ GA_Y, 168
.equ GA_SIZE, 172
# G.722 band state (dwords).
.equ GB_PREDICTOR, 0                # s_predictor
.equ GB_ZERO, 4                     # s_zero
.equ GB_PART, 8                     # part_reconst_mem[2]
.equ GB_QTZD, 16                    # prev_qtzd_reconst
.equ GB_POLE, 20                    # pole_mem[2]
.equ GB_DIFF, 28                    # diff_mem[6]
.equ GB_ZMEM, 52                    # zero_mem[6]
.equ GB_LOG, 76                     # log_factor
.equ GB_SCALE, 80                   # scale_factor
.equ GB_SIZE, 84
.equ G722_HISTORY, 1024

RODATA
.p2align 2
# G.726 quantizer tables by code size (2-5 bits): inverse quantizer (log
# domain), scale factor multiplier W and speed control F, indexed by code.
g726_iquant2: .long 116, 365, 365, 116
g726_w2: .long -22, 439, 439, -22
g726_f2: .long 0, 7, 7, 0
g726_iquant3: .long -32768, 135, 273, 373, 373, 273, 135, -32768
g726_w3: .long -4, 30, 137, 582, 582, 137, 30, -4
g726_f3: .long 0, 1, 2, 7, 7, 2, 1, 0
g726_iquant4: .long -32768, 4, 135, 213, 273, 323, 373, 425, 425, 373, 323, 273, 213, 135, 4, -32768
g726_w4: .long -12, 18, 41, 64, 112, 198, 355, 1122, 1122, 355, 198, 112, 64, 41, 18, -12
g726_f4: .long 0, 0, 0, 1, 1, 1, 3, 7, 7, 3, 1, 1, 1, 0, 0, 0
g726_iquant5: .long -32768, -66, 28, 104, 169, 224, 274, 318, 358, 395, 429, 459, 488, 514, 539, 566
    .long 566, 539, 514, 488, 459, 429, 395, 358, 318, 274, 224, 169, 104, 28, -66, -32768
g726_w5: .long 14, 14, 24, 39, 40, 41, 58, 100, 141, 179, 219, 280, 358, 440, 529, 696
    .long 696, 529, 440, 358, 280, 219, 179, 141, 100, 58, 41, 40, 39, 24, 14, 14
g726_f5: .long 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 6, 6, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0
.p2align 3
g726_tables: .quad g726_iquant2, g726_w2, g726_f2, g726_iquant3, g726_w3, g726_f3
    .quad g726_iquant4, g726_w4, g726_f4, g726_iquant5, g726_w5, g726_f5
.p2align 2
# G.722: inverse log2 (the scale factor's mantissa), quantizer steps of the
# log scale factors, and the inverse quantizers of the low (6- and 4-bit)
# and high (2-bit) bands.
g722_inv_log2: .long 2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383, 2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834
    .long 2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371, 3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008
g722_low_step: .long -60, 3042, 1198, 538, 334, 172, 58, -30, 3042, 1198, 538, 334, 172, 58, -30, -60
g722_low_iquant4: .long 0, -2557, -1612, -1121, -786, -530, -323, -150, 2557, 1612, 1121, 786, 530, 323, 150, 0
g722_low_iquant6: .long -17, -17, -17, -17, -3101, -2738, -2376, -2088, -1873, -1689, -1535, -1399, -1279, -1170, -1072, -982
    .long -899, -822, -750, -682, -618, -558, -501, -447, -396, -347, -300, -254, -211, -170, -130, -91
    .long 3101, 2738, 2376, 2088, 1873, 1689, 1535, 1399, 1279, 1170, 1072, 982, 899, 822, 750, 682
    .long 618, 558, 501, 447, 396, 347, 300, 254, 211, 170, 130, 91, 54, 17, -54, -17
g722_high_iquant: .long -926, -202, 926, 202
g722_high_step: .long 798, -214
# Quadrature mirror filter coefficients (G.722 Table 11), in the order the
# history is read: even taps feed the second output, odd taps the first.
g722_qmf: .long 3, -11, -11, 53, 12, -156, 32, 362, -210, -805, 951, 3876
    .long 3876, 951, -805, -210, 362, 32, -156, 12, 53, -11, -11, 3

.bss
.p2align 3
g726_state: .zero GA_SIZE
g726_bits: .zero 4                  # code size
g726_iquant: .zero 8                # tables of the code size
g726_w: .zero 8
g726_f: .zero 8
g722_band: .zero 2*GB_SIZE          # low band, high band
g722_pos: .zero 4
.p2align 1
g722_history: .zero G722_HISTORY*2  # int16 subband sums and differences

.text
# ECX=code size (2-5): selects the tables and clears the state.
FN g726_reset
    push rdi
    mov [rip + g726_bits], ecx
    lea eax, [rcx - 2]
    imul eax, eax, 24
    lea rdx, [rip + g726_tables]
    add rdx, rax
    mov rax, [rdx]
    mov [rip + g726_iquant], rax
    mov rax, [rdx + 8]
    mov [rip + g726_w], rax
    mov rax, [rdx + 16]
    mov [rip + g726_f], rax
    lea rdi, [rip + g726_state]
    xor eax, eax
    mov ecx, GA_SIZE/4
    rep stosd
    lea rdx, [rip + g726_state]
    mov dword ptr [rdx + GA_SR + 8], 32          # sr[0].mant
    mov dword ptr [rdx + GA_SR + 20], 32         # sr[1].mant
    mov dword ptr [rdx + GA_PK], 1
    mov dword ptr [rdx + GA_PK + 4], 1
    xor ecx, ecx
.Lg726_reset_dq:
    lea eax, [rcx + rcx*2]
    mov dword ptr [rdx + GA_DQ + rax*4 + 8], 32
    inc ecx
    cmp ecx, 6
    jb .Lg726_reset_dq
    mov dword ptr [rdx + GA_YU], 544
    mov dword ptr [rdx + GA_YL], 34816
    mov dword ptr [rdx + GA_Y], 544
    pop rdi
    ret
ENDFN g726_reset

# ECX=value, RDX=float (sign, exponent, mantissa dwords): G.726's i2f.
# Clobbers RAX, RCX, R8.
LOCALFN g726_float
    xor eax, eax
    test ecx, ecx
    jns .Lg726_float_positive
    neg ecx
    mov eax, 1
.Lg726_float_positive:
    mov [rdx], eax
    test ecx, ecx
    jz .Lg726_float_zero
    bsr eax, ecx
    inc eax                                      # exponent: bit length
    mov [rdx + 4], eax
    shl ecx, 6
    mov r8d, ecx
    mov ecx, eax
    shr r8d, cl
    mov [rdx + 8], r8d
    ret
.Lg726_float_zero:
    mov dword ptr [rdx + 4], 0
    mov dword ptr [rdx + 8], 32
    ret
ENDFN g726_float

# RCX=float, RDX=float -> EAX=their product as G.726 forms it (int16).
# Clobbers RCX, R8, R9.
LOCALFN g726_mult
    mov eax, [rcx + 8]
    imul eax, [rdx + 8]
    add eax, 0x30
    sar eax, 4
    mov r8d, [rcx + 4]
    add r8d, [rdx + 4]                           # exponent
    mov r9d, [rcx]
    xor r9d, [rdx]                               # sign
    sub r8d, 19
    jle .Lg726_mult_down
    mov ecx, r8d
    shl eax, cl
    jmp .Lg726_mult_sign
.Lg726_mult_down:
    neg r8d
    mov ecx, r8d
    sar eax, cl
.Lg726_mult_sign:
    test r9d, r9d
    jz .Lg726_mult_return
    neg eax
.Lg726_mult_return:
    movsx eax, ax
    ret
ENDFN g726_mult

# ECX=code -> EAX=the decoded sample (int16).
LOCALFN g726_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                                  # [rsp]: a scratch float
    lea rbx, [rip + g726_state]
    mov r12d, ecx                                # I
    mov eax, [rip + g726_bits]
    lea ecx, [rax - 1]
    mov r13d, r12d
    shr r13d, cl                                 # sign of the code
    # Inverse quantizer.
    mov rax, [rip + g726_iquant]
    mov eax, [rax + r12*4]
    mov ecx, [rbx + GA_Y]
    sar ecx, 2
    add eax, ecx                                 # dql
    xor esi, esi                                 # dq
    test eax, eax
    js .Lg726_dq_done
    mov ecx, eax
    shr ecx, 7
    and ecx, 15
    and eax, 0x7f
    add eax, 128
    shl eax, cl
    sar eax, 7
    movsx esi, ax
.Lg726_dq_done:
    # Transition: a tone and a difference above 3/4 of the threshold.
    mov eax, [rbx + GA_YL]
    mov ecx, eax
    sar ecx, 15                                  # ylint
    sar eax, 10
    and eax, 31                                  # ylfrac
    mov edx, 31 << 10
    cmp ecx, 9
    jg .Lg726_thr_done
    add eax, 32
    shl eax, cl
    mov edx, eax
.Lg726_thr_done:
    lea edx, [rdx + rdx*2]
    sar edx, 2
    xor r14d, r14d                               # tr
    cmp dword ptr [rbx + GA_TD], 1
    jne .Lg726_tr_done
    cmp esi, edx
    jle .Lg726_tr_done
    mov r14d, 1
.Lg726_tr_done:
    test r13d, r13d
    jz .Lg726_dq_signed
    neg esi
.Lg726_dq_signed:
    mov eax, [rbx + GA_SE]
    add eax, esi
    movsx r15d, ax                               # reconstructed signal
    mov eax, [rbx + GA_SEZ]                      # pk0: sign of sez + dq, or 0
    add eax, esi
    xor edi, edi
    test eax, eax
    jz .Lg726_pk0_done
    mov edi, 1
    jns .Lg726_pk0_done
    mov edi, -1
.Lg726_pk0_done:
    xor r8d, r8d                                 # dq0: sign of dq, or 0
    test esi, esi
    jz .Lg726_dq0_done
    mov r8d, 1
    jns .Lg726_dq0_done
    mov r8d, -1
.Lg726_dq0_done:
    test r14d, r14d
    jz .Lg726_adapt
    xor eax, eax
    mov [rbx + GA_A], eax
    mov [rbx + GA_A + 4], eax
    xor ecx, ecx
.Lg726_clear_b:
    mov [rbx + GA_B + rcx*4], eax
    inc ecx
    cmp ecx, 6
    jb .Lg726_clear_b
    jmp .Lg726_shift
.Lg726_adapt:
    mov eax, [rbx + GA_A]                        # fa1 = clip((-a0*pk[0]*pk0) >> 5)
    neg eax
    imul eax, [rbx + GA_PK]
    imul eax, edi
    sar eax, 5
    mov ecx, -256
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 255
    cmp eax, ecx
    cmovg eax, ecx
    mov r9d, eax
    mov eax, edi                                 # a1 += 128*pk0*pk[1] + fa1 - (a1 >> 7)
    imul eax, [rbx + GA_PK + 4]
    shl eax, 7
    add eax, r9d
    mov ecx, [rbx + GA_A + 4]
    mov edx, ecx
    sar edx, 7
    sub eax, edx
    add eax, ecx
    mov ecx, -12288
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 12288
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + GA_A + 4], eax
    mov r9d, 15360                               # a0 += 192*pk0*pk[0] - (a0 >> 8)
    sub r9d, eax
    mov eax, edi
    imul eax, [rbx + GA_PK]
    imul eax, eax, 192
    mov ecx, [rbx + GA_A]
    mov edx, ecx
    sar edx, 8
    sub eax, edx
    add eax, ecx
    cmp eax, r9d
    cmovg eax, r9d
    neg r9d
    cmp eax, r9d
    cmovl eax, r9d
    mov [rbx + GA_A], eax
    xor ecx, ecx                                 # b[i] += 128*dq0*sgn - (b[i] >> 8)
.Lg726_b:
    lea eax, [rcx + rcx*2]
    mov eax, [rbx + GA_DQ + rax*4]               # dq[i] sign
    mov edx, r8d
    shl edx, 7
    mov r9d, edx
    neg r9d
    test eax, eax
    cmovnz edx, r9d
    mov eax, [rbx + GA_B + rcx*4]
    mov r9d, eax
    sar r9d, 8
    sub edx, r9d
    add eax, edx
    mov [rbx + GA_B + rcx*4], eax
    inc ecx
    cmp ecx, 6
    jb .Lg726_b
.Lg726_shift:
    mov eax, [rbx + GA_PK]
    mov [rbx + GA_PK + 4], eax
    mov eax, 1
    test edi, edi
    cmovnz eax, edi
    mov [rbx + GA_PK], eax
    mov ecx, 2                                   # sr[1] = sr[0]
.Lg726_sr:
    mov eax, [rbx + GA_SR + rcx*4]
    mov [rbx + GA_SR + 12 + rcx*4], eax
    dec ecx
    jns .Lg726_sr
    mov ecx, r15d
    lea rdx, [rbx + GA_SR]
    call g726_float
    mov ecx, 14                                  # dq[5..1] = dq[4..0]
.Lg726_dq_history:
    mov eax, [rbx + GA_DQ + rcx*4]
    mov [rbx + GA_DQ + 12 + rcx*4], eax
    dec ecx
    jns .Lg726_dq_history
    mov ecx, esi
    lea rdx, [rbx + GA_DQ]
    call g726_float
    mov [rbx + GA_DQ], r13d                      # the code's sign, even for zero
    xor eax, eax
    cmp dword ptr [rbx + GA_A + 4], -11776
    setl al
    mov [rbx + GA_TD], eax
    # Speed control.
    mov rax, [rip + g726_f]
    mov ecx, [rax + r12*4]
    shl ecx, 4                                   # F[I] << 4
    mov eax, [rbx + GA_DMS]
    mov edx, eax
    neg edx
    sar edx, 5
    add eax, ecx
    add eax, edx
    mov [rbx + GA_DMS], eax
    mov eax, [rbx + GA_DML]
    mov edx, eax
    neg edx
    sar edx, 7
    add eax, ecx
    add eax, edx
    mov [rbx + GA_DML], eax
    test r14d, r14d
    jz .Lg726_ap
    mov dword ptr [rbx + GA_AP], 256
    jmp .Lg726_scale
.Lg726_ap:
    mov eax, [rbx + GA_AP]
    mov edx, eax
    neg edx
    sar edx, 4
    add eax, edx
    cmp dword ptr [rbx + GA_Y], 1535
    jle .Lg726_ap_up
    cmp dword ptr [rbx + GA_TD], 0
    jne .Lg726_ap_up
    mov ecx, [rbx + GA_DMS]
    shl ecx, 2
    sub ecx, [rbx + GA_DML]
    mov edx, ecx
    neg edx
    cmovs edx, ecx                               # |(dms << 2) - dml|
    mov ecx, [rbx + GA_DML]
    sar ecx, 3
    cmp edx, ecx
    jl .Lg726_ap_store
.Lg726_ap_up:
    add eax, 0x20
.Lg726_ap_store:
    mov [rbx + GA_AP], eax
.Lg726_scale:
    # yu = clip(y + W[I] + ((-y) >> 5), 544, 5120); yl += yu + ((-yl) >> 6)
    mov ecx, [rbx + GA_Y]
    mov rax, [rip + g726_w]
    mov eax, [rax + r12*4]
    add eax, ecx
    neg ecx
    sar ecx, 5
    add eax, ecx
    mov ecx, 544
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 5120
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + GA_YU], eax
    mov ecx, [rbx + GA_YL]
    mov edx, ecx
    neg edx
    sar edx, 6
    add ecx, eax
    add ecx, edx
    mov [rbx + GA_YL], ecx
    # y = (yl + (yu - (yl >> 6))*al) >> 6, al = 64 or ap >> 2
    mov edx, [rbx + GA_AP]
    sar edx, 2
    cmp dword ptr [rbx + GA_AP], 256
    mov r9d, 64
    cmovge edx, r9d
    mov r9d, ecx
    sar r9d, 6
    sub eax, r9d
    imul eax, edx
    add eax, ecx
    sar eax, 6
    mov [rbx + GA_Y], eax
    # The next estimates: zero section, then the poles.
    xor edi, edi                                 # se
    xor esi, esi
.Lg726_zeros:
    mov ecx, [rbx + GA_B + rsi*4]
    sar ecx, 2
    mov rdx, rsp
    call g726_float
    lea eax, [rsi + rsi*2]
    lea rdx, [rbx + GA_DQ + rax*4]
    mov rcx, rsp
    call g726_mult
    add edi, eax
    inc esi
    cmp esi, 6
    jb .Lg726_zeros
    mov eax, edi
    sar eax, 1
    mov [rbx + GA_SEZ], eax
    xor esi, esi
.Lg726_poles:
    mov ecx, [rbx + GA_A + rsi*4]
    sar ecx, 2
    mov rdx, rsp
    call g726_float
    lea eax, [rsi + rsi*2]
    lea rdx, [rbx + GA_SR + rax*4]
    mov rcx, rsp
    call g726_mult
    add edi, eax
    inc esi
    cmp esi, 2
    jb .Lg726_poles
    sar edi, 1
    mov [rbx + GA_SE], edi
    lea eax, [r15*4]                             # clip(sr*4, +-0xffff) as int16
    mov ecx, -0xffff
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 0xffff
    cmp eax, ecx
    cmovg eax, ecx
    movsx eax, ax
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN g726_decode

# RCX=codes, EDX=samples, R8=int16 output, R9D=1 for codes packed from the
# least significant bit (AU), else from the most significant (WAVE).
FN g726_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov ebx, edx
    mov rdi, r8
    mov r12d, r9d
    xor r13d, r13d                               # bit buffer
    xor r14d, r14d                               # bits in it
    mov ecx, [rip + g726_bits]
    mov r15d, 1
    shl r15d, cl
    dec r15d                                     # code mask
    test ebx, ebx
    jz .Lg726_block_done
.Lg726_block_sample:
    cmp r14d, [rip + g726_bits]
    jae .Lg726_block_code
    movzx eax, byte ptr [rsi]
    inc rsi
    test r12d, r12d
    jnz .Lg726_block_le_byte
    shl r13d, 8
    or r13d, eax
    add r14d, 8
    jmp .Lg726_block_sample
.Lg726_block_le_byte:
    mov ecx, r14d
    shl eax, cl
    or r13d, eax
    add r14d, 8
    jmp .Lg726_block_sample
.Lg726_block_code:
    sub r14d, [rip + g726_bits]
    test r12d, r12d
    jnz .Lg726_block_le_code
    mov eax, r13d
    mov ecx, r14d
    shr eax, cl
    and eax, r15d
    jmp .Lg726_block_decode
.Lg726_block_le_code:
    mov eax, r13d
    and eax, r15d
    mov ecx, [rip + g726_bits]
    shr r13d, cl
.Lg726_block_decode:
    mov ecx, eax
    call g726_decode
    mov [rdi], ax
    add rdi, 2
    dec ebx
    jnz .Lg726_block_sample
.Lg726_block_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN g726_block

# Clears both bands and the filter history.
FN g722_reset
    push rdi
    lea rdi, [rip + g722_band]
    xor eax, eax
    mov ecx, 2*GB_SIZE/4
    rep stosd
    lea rdi, [rip + g722_history]
    mov ecx, G722_HISTORY/2
    rep stosd
    mov dword ptr [rip + g722_band + GB_SCALE], 8
    mov dword ptr [rip + g722_band + GB_SIZE + GB_SCALE], 2
    mov dword ptr [rip + g722_pos], 22
    pop rdi
    ret
ENDFN g722_reset

# ECX=log factor -> EAX=linear scale factor. Clobbers RCX, RDX.
LOCALFN g722_linear
    mov eax, ecx
    sar eax, 6
    and eax, 31
    lea rdx, [rip + g722_inv_log2]
    mov eax, [rdx + rax*4]
    sar ecx, 11
    js .Lg722_linear_down
    shl eax, cl
    ret
.Lg722_linear_down:
    neg ecx
    sar eax, cl
    ret
ENDFN g722_linear

# RBX=band, ECX=dequantized difference: G.722's adaptive prediction (pole
# and zero sections). Clobbers RAX, RCX, RDX, R8-R11.
LOCALFN g722_predict
    push rsi
    push rdi
    mov esi, ecx                                 # cur_diff
    mov eax, [rbx + GB_ZERO]
    add eax, esi
    shr eax, 31                                  # cur_part_reconst
    mov r8d, 1                                   # sg0: +1 when it changed
    cmp eax, [rbx + GB_PART]
    jne .Lg722_sg0
    mov r8d, -1
.Lg722_sg0:
    mov r9d, 1                                   # sg1: +1 when equal to two back
    cmp eax, [rbx + GB_PART + 4]
    je .Lg722_sg1
    mov r9d, -1
.Lg722_sg1:
    mov ecx, [rbx + GB_PART]
    mov [rbx + GB_PART + 4], ecx
    mov [rbx + GB_PART], eax
    # pole1 = clip((sg0*clip(pole0, +-8191) >> 5) + sg1*128 + (pole1*127 >> 7))
    mov eax, [rbx + GB_POLE]
    mov ecx, -8191
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 8191
    cmp eax, ecx
    cmovg eax, ecx
    imul eax, r8d
    sar eax, 5
    mov ecx, r9d
    shl ecx, 7
    add eax, ecx
    mov ecx, [rbx + GB_POLE + 4]
    imul ecx, ecx, 127
    sar ecx, 7
    add eax, ecx
    mov ecx, -12288
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 12288
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + GB_POLE + 4], eax
    mov r10d, 15360                              # limit
    sub r10d, eax
    imul eax, r8d, -192                          # pole0 = clip(-192*sg0 + (pole0*255 >> 8))
    mov ecx, [rbx + GB_POLE]
    imul ecx, ecx, 255
    sar ecx, 8
    add eax, ecx
    cmp eax, r10d
    cmovg eax, r10d
    neg r10d
    cmp eax, r10d
    cmovl eax, r10d
    mov [rbx + GB_POLE], eax
    # Zero section: the difference history shifts in; each tap moves by
    # 128 towards the sign agreement of its old value and the new one.
    xor edi, edi                                 # s_zero
    mov r11d, 5
.Lg722_zero:
    test r11d, r11d
    jz .Lg722_zero_new
    mov r9d, [rbx + GB_DIFF + r11*4 - 4]         # x = diff_mem[k-1]
    jmp .Lg722_zero_tap
.Lg722_zero_new:
    lea r9d, [rsi + rsi]                         # x = cur_diff*2
.Lg722_zero_tap:
    mov eax, [rbx + GB_ZMEM + r11*4]
    imul eax, eax, 255
    sar eax, 8
    test esi, esi
    jz .Lg722_zero_store
    mov edx, [rbx + GB_DIFF + r11*4]
    xor edx, esi                                 # signs differ: -128
    mov edx, 128
    jns .Lg722_zero_add
    mov edx, -128
.Lg722_zero_add:
    add eax, edx
.Lg722_zero_store:
    mov [rbx + GB_ZMEM + r11*4], eax
    mov [rbx + GB_DIFF + r11*4], r9d
    imul r9d, eax
    sar r9d, 15
    add edi, r9d
    dec r11d
    jns .Lg722_zero
    mov [rbx + GB_ZERO], edi
    # cur = clip16((s_predictor + cur_diff)*2)
    mov eax, [rbx + GB_PREDICTOR]
    add eax, esi
    add eax, eax
    mov ecx, -32768
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 32767
    cmp eax, ecx
    cmovg eax, ecx
    mov r8d, eax
    # s_predictor = clip16(s_zero + (pole0*cur >> 15) + (pole1*prev >> 15))
    mov ecx, [rbx + GB_POLE]
    imul ecx, eax
    sar ecx, 15
    add edi, ecx
    mov ecx, [rbx + GB_POLE + 4]
    imul ecx, [rbx + GB_QTZD]
    sar ecx, 15
    add edi, ecx
    mov ecx, -32768
    cmp edi, ecx
    cmovl edi, ecx
    mov ecx, 32767
    cmp edi, ecx
    cmovg edi, ecx
    mov [rbx + GB_PREDICTOR], edi
    mov [rbx + GB_QTZD], r8d
    pop rdi
    pop rsi
    ret
ENDFN g722_predict

# RCX=codewords, EDX=bytes, R8=int16 output (two samples per byte).
FN g722_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov r12d, edx
    mov rdi, r8
    test r12d, r12d
    jz .Lg722_done
.Lg722_byte:
    movzx r13d, byte ptr [rsi]
    inc rsi
    mov r14d, r13d
    shr r14d, 6                                  # ihigh
    and r13d, 63                                 # ilow
    # Low band.
    lea rbx, [rip + g722_band]
    lea rax, [rip + g722_low_iquant6]
    mov eax, [rax + r13*4]
    imul eax, [rbx + GB_SCALE]
    sar eax, 10
    add eax, [rbx + GB_PREDICTOR]
    mov ecx, -16384
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 16383
    cmp eax, ecx
    cmovg eax, ecx
    mov r15d, eax                                # rlow
    shr r13d, 2                                  # the 4-bit index
    lea rax, [rip + g722_low_iquant4]
    mov ecx, [rax + r13*4]
    imul ecx, [rbx + GB_SCALE]
    sar ecx, 10
    call g722_predict
    mov eax, [rbx + GB_LOG]
    imul eax, eax, 127
    sar eax, 7
    lea rcx, [rip + g722_low_step]
    add eax, [rcx + r13*4]
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 18432
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + GB_LOG], eax
    lea ecx, [rax - (8 << 11)]
    call g722_linear
    mov [rbx + GB_SCALE], eax
    # High band.
    lea rbx, [rip + g722_band + GB_SIZE]
    lea rax, [rip + g722_high_iquant]
    mov eax, [rax + r14*4]
    imul eax, [rbx + GB_SCALE]
    sar eax, 10                                  # dhigh
    mov r13d, eax
    add eax, [rbx + GB_PREDICTOR]
    mov ecx, -16384
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 16383
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 24], eax                          # rhigh
    mov ecx, r13d
    call g722_predict
    mov eax, [rbx + GB_LOG]
    imul eax, eax, 127
    sar eax, 7
    and r14d, 1
    lea rcx, [rip + g722_high_step]
    add eax, [rcx + r14*4]
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 22528
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + GB_LOG], eax
    lea ecx, [rax - (10 << 11)]
    call g722_linear
    mov [rbx + GB_SCALE], eax
    # Recombine through the QMF.
    mov eax, [rip + g722_pos]
    lea rdx, [rip + g722_history]
    mov ecx, [rsp + 24]
    lea r8d, [r15 + rcx]
    mov [rdx + rax*2], r8w
    sub r15d, ecx
    mov [rdx + rax*2 + 2], r15w
    add eax, 2
    mov [rip + g722_pos], eax
    lea r9, [rdx + rax*2 - 48]                   # the last 24 values
    lea r10, [rip + g722_qmf]
    xor r8d, r8d                                 # xout[0]
    xor r11d, r11d                               # xout[1]
    xor ecx, ecx
.Lg722_qmf:
    movsx eax, word ptr [r9 + rcx*4]
    imul eax, [r10 + rcx*8]
    add r11d, eax
    movsx eax, word ptr [r9 + rcx*4 + 2]
    imul eax, [r10 + rcx*8 + 4]
    add r8d, eax
    inc ecx
    cmp ecx, 12
    jb .Lg722_qmf
    mov ecx, -32768
    mov edx, 32767
    sar r8d, 11
    cmp r8d, ecx
    cmovl r8d, ecx
    cmp r8d, edx
    cmovg r8d, edx
    sar r11d, 11
    cmp r11d, ecx
    cmovl r11d, ecx
    cmp r11d, edx
    cmovg r11d, edx
    mov [rdi], r8w
    mov [rdi + 2], r11w
    add rdi, 4
    cmp dword ptr [rip + g722_pos], G722_HISTORY
    jb .Lg722_next
    lea rdx, [rip + g722_history]                # keep the last 22 values
    mov eax, [rip + g722_pos]
    lea r9, [rdx + rax*2 - 44]
    xor ecx, ecx
.Lg722_keep:
    movzx r8d, word ptr [r9 + rcx*2]
    mov [rdx + rcx*2], r8w
    inc ecx
    cmp ecx, 22
    jb .Lg722_keep
    mov dword ptr [rip + g722_pos], 22
.Lg722_next:
    dec r12d
    jnz .Lg722_byte
.Lg722_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN g722_block
