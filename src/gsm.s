# Original GSM 06.10 full-rate speech decoder in x86-64 assembly. MIT, see
# LICENSE. RPE-LTP decoding in 16-bit fixed point, bit-exact with libgsm
# (Jutta Degener and Carsten Bormann, Technische Universitaet Berlin; its
# notice is in THIRD_PARTY_NOTICES) and FFmpeg: RPE (APCM inverse
# quantization and grid positioning), long-term synthesis, decoding and
# interpolation of the log-area ratios, the short-term synthesis lattice and
# de-emphasis. Each 20 ms frame holds 260 bits: eight log-area ratios, then
# per 5 ms subframe the LTP lag and gain, the grid position, the block
# maximum and 13 RPE pulses. Standard frames are 33 bytes, a 0xD nibble and
# the bits from the most significant; Microsoft's WAVE format (tag 0x31)
# packs two frames in 65 bytes from the least significant bit. The tables
# are GSM 06.10's tables 4.1-4.6 as libgsm lists them.
.include "lamp.inc"
.globl gsm_reset, gsm_block, gsm_probe, gsm_open

.equ TK_ADPCM, 10
.equ CODEC_GSM, 19

RODATA
# Table 4.1: twice B, MIC, INVA (table 4.2) for LAR 1-8.
gsm_b2: .long 0, 0, 4096, -5120, 188, -3584, -682, -2288
gsm_mic: .long -32, -32, -16, -16, -8, -8, -4, -4
gsm_inva: .long 13107, 13107, 13107, 13107, 19223, 17476, 31454, 29708
# Table 4.3b: LTP gains.
gsm_qlb: .long 3277, 11469, 21299, 32767
# Table 4.6: normalized direct mantissas.
gsm_fac: .long 18431, 20479, 22527, 24575, 26623, 28671, 30719, 32767
# Bits per parameter of a frame: LARc 1-8, then per subframe Nc, bc, Mc,
# xmaxc and 13 pulses.
gsm_widths: .byte 6, 6, 5, 5, 4, 4, 3, 3
    .rept 4
    .byte 7, 2, 2, 6, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
    .endr

.bss
.p2align 4
# 32-bit words of 16-bit values throughout.
gsm_dp: .zero 160*4                 # reconstructed short-term residual, drp[-120..39]
gsm_v: .zero 9*4                    # short-term synthesis lattice state
gsm_larpp: .zero 2*8*4              # decoded log-area ratios: two frames
gsm_params: .zero 76*4              # one frame's parameters
gsm_wt: .zero 160*4                 # the frame's short-term residual
gsm_larp: .zero 8*4                 # interpolated ratios, then reflection coefficients
gsm_j: .long 0                      # which LARpp row is current
gsm_nrp: .long 0                    # last valid LTP lag
gsm_msr: .long 0                    # de-emphasis state

.data
# The WAVE-style format of raw GSM for the ADPCM track decoder: ADPCM_GSM,
# mono, 8 kHz, 33-byte frames.
gsm_raw_fmt: .short 0x5347, 1
    .long 8000, 1650
    .short 33, 0

.text
# Saturates EAX to 16 bits. Clobbers EDX.
.macro GSM_SAT
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
.endm

# EAX = (EAX * ECX + 16384) >> 15 for 16-bit operands, not both -32768
# (the decoder never multiplies two of them).
.macro GSM_MULT_R
    imul eax, ecx
    add eax, 16384
    sar eax, 15
.endm

# Clears the decoder state (stream start, seeks).
FN gsm_reset
    push rdi
    lea rdi, [rip + gsm_dp]
    mov ecx, 160 + 9 + 16
    xor eax, eax
    rep stosd
    mov dword ptr [rip + gsm_j], 0
    mov dword ptr [rip + gsm_nrp], 40
    mov dword ptr [rip + gsm_msr], 0
    pop rdi
    ret
ENDFN gsm_reset

# RCX=start, RDX=end -> EAX=1 for a raw GSM stream: two or more whole
# 33-byte frames, each beginning with the 0xD nibble (a shorter tail is
# ignored).
FN gsm_probe
    mov rax, rdx
    sub rax, rcx
    xor edx, edx
    mov r8d, 33
    div r8
    cmp rax, 2
    jb .Lgsm_probe_no
.Lgsm_probe_frame:
    movzx edx, byte ptr [rcx]
    shr edx, 4
    cmp edx, 0xd
    jne .Lgsm_probe_no
    add rcx, 33
    dec rax
    jnz .Lgsm_probe_frame
    mov eax, 1
    ret
.Lgsm_probe_no:
    xor eax, eax
    ret
ENDFN gsm_probe

# RCX=start, RDX=end of a raw GSM stream -> EAX=1 with its frames, 20 per
# packet, opened by the ADPCM track decoder (codec_kind 19).
FN gsm_open
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    mov ecx, TK_ADPCM
    call track_begin
    test eax, eax
    jz .Lgsm_open_bad
.Lgsm_open_packet:
    mov rdx, rdi
    sub rdx, rsi
    cmp rdx, 33
    jb .Lgsm_open_done
    mov eax, 33*20
    cmp rdx, rax
    cmova rdx, rax
    mov rcx, rsi
    add rsi, rdx
    call track_add
    test eax, eax
    jz .Lgsm_open_bad
    jmp .Lgsm_open_packet
.Lgsm_open_done:
    lea rax, [rip + gsm_raw_fmt]
    mov [rip + track_config], rax
    mov dword ptr [rip + track_config_bytes], 16
    call track_finish
    test eax, eax
    jz .Lgsm_open_bad
    mov dword ptr [rip + codec_kind], CODEC_GSM
    mov eax, 1
    jmp .Lgsm_open_return
.Lgsm_open_bad:
    call track_close
    xor eax, eax
.Lgsm_open_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN gsm_open

# RCX=packet, EDX=bytes, R8=int16 output, R9D=1 for Microsoft's 65-byte
# blocks (else 33-byte frames) -> EAX=samples: 160 per whole frame, 320 per
# whole block. The 0xD nibble of standard frames is not checked, as FFmpeg
# decodes frames without it.
FN gsm_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rsi, rcx
    mov r12d, edx
    mov rdi, r8
    mov r13d, r9d
    xor r14d, r14d                        # samples
.Lgsm_block_next:
    mov eax, 33
    test r13d, r13d
    jz .Lgsm_block_size
    mov eax, 65
.Lgsm_block_size:
    cmp r12d, eax
    jb .Lgsm_block_done
    sub r12d, eax
    mov rbx, rsi
    add rsi, rax
    mov rcx, rbx
    mov edx, 4                            # after the 0xD nibble
    test r13d, r13d
    jz .Lgsm_block_frame
    xor edx, edx
.Lgsm_block_frame:
    mov r8d, r13d
    call gsm_unpack                       # EAX=bit position after the frame
    mov [rsp + 32], eax
    mov rcx, rdi
    call gsm_frame
    add rdi, 320
    add r14d, 160
    test r13d, r13d
    jz .Lgsm_block_next
    mov rcx, rbx                          # Microsoft: the second frame
    mov edx, [rsp + 32]
    mov r8d, 1
    call gsm_unpack
    mov rcx, rdi
    call gsm_frame
    add rdi, 320
    add r14d, 160
    jmp .Lgsm_block_next
.Lgsm_block_done:
    mov eax, r14d
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN gsm_block

# RCX=frame bytes, EDX=first bit, R8D=1 for least significant bit first ->
# gsm_params filled, EAX=the bit after them. Clobbers R9-R11.
LOCALFN gsm_unpack
    push rbx
    push rsi
    xor r9d, r9d                          # parameter
    lea r10, [rip + gsm_params]
.Lgsm_unpack_param:
    lea r11, [rip + gsm_widths]
    movzx ebx, byte ptr [r11 + r9]        # its width
    xor eax, eax
    xor esi, esi                          # bits read
.Lgsm_unpack_bit:
    push rcx
    mov r11d, edx
    shr r11d, 3
    movzx r11d, byte ptr [rcx + r11]
    mov ecx, edx
    and ecx, 7
    test r8d, r8d
    jnz .Lgsm_unpack_lsb
    neg ecx
    add ecx, 7
    shr r11d, cl
    and r11d, 1
    add eax, eax
    or eax, r11d                          # most significant first
    jmp .Lgsm_unpack_bit_done
.Lgsm_unpack_lsb:
    shr r11d, cl
    and r11d, 1
    mov ecx, esi
    shl r11d, cl
    or eax, r11d                          # least significant first
.Lgsm_unpack_bit_done:
    pop rcx
    inc edx
    inc esi
    cmp esi, ebx
    jb .Lgsm_unpack_bit
    mov [r10 + r9*4], eax
    inc r9d
    cmp r9d, 76
    jb .Lgsm_unpack_param
    mov eax, edx
    pop rsi
    pop rbx
    ret
ENDFN gsm_unpack

# RCX=int16 output -> 160 samples synthesized from gsm_params (4.3).
LOCALFN gsm_frame
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r15, rcx
    # Subframes: RPE decoding (4.2.15-4.2.17) and long-term synthesis
    # (4.3.2) into drp[0..39], gsm_dp[120..159].
    xor r12d, r12d                        # subframe
.Lgsm_frame_subframe:
    lea rsi, [rip + gsm_params]
    imul eax, r12d, 17
    lea rsi, [rsi + rax*4 + 8*4]          # Nc, bc, Mc, xmaxc, xMc[13]
    # The block maximum's exponent and mantissa.
    mov eax, [rsi + 12]                   # xmaxc
    xor ebx, ebx                          # exp
    cmp eax, 15
    jle .Lgsm_frame_exp
    mov ebx, eax
    sar ebx, 3
    dec ebx
.Lgsm_frame_exp:
    mov ecx, ebx
    shl ecx, 3
    sub eax, ecx                          # mant
    jnz .Lgsm_frame_mant
    mov ebx, -4
    mov eax, 7
    jmp .Lgsm_frame_mant_done
.Lgsm_frame_mant:
    cmp eax, 7
    jg .Lgsm_frame_mant_norm
    lea eax, [rax*2 + 1]
    dec ebx
    jmp .Lgsm_frame_mant
.Lgsm_frame_mant_norm:
    sub eax, 8
.Lgsm_frame_mant_done:
    lea rcx, [rip + gsm_fac]
    mov r13d, [rcx + rax*4]               # temp1 = FAC[mant]
    mov r14d, 6
    sub r14d, ebx                         # temp2 = 6 - exp (0..10)
    xor r11d, r11d                        # temp3 = 1 << (temp2 - 1)
    test r14d, r14d
    jz .Lgsm_frame_round
    lea ecx, [r14 - 1]
    mov r11d, 1
    shl r11d, cl
.Lgsm_frame_round:
    # erp: zeros, with the 13 pulses at Mc + 3i.
    lea rdi, [rip + gsm_wt]               # erp in the frame's wt slot
    imul eax, r12d, 40
    lea rdi, [rdi + rax*4]
    xor eax, eax
    mov ecx, 40
.Lgsm_frame_zero:
    mov [rdi + rcx*4 - 4], eax
    dec ecx
    jnz .Lgsm_frame_zero
    mov r9d, [rsi + 8]                    # Mc
    xor r8d, r8d
.Lgsm_frame_pulse:
    mov eax, [rsi + 16 + r8*4]            # xMc
    lea eax, [rax*2 - 7]
    shl eax, 12
    mov ecx, r13d
    GSM_MULT_R
    add eax, r11d
    GSM_SAT
    mov ecx, r14d
    sar eax, cl
    imul ecx, r8d, 3
    add ecx, r9d
    mov [rdi + rcx*4], eax
    inc r8d
    cmp r8d, 13
    jb .Lgsm_frame_pulse
    # Long-term synthesis: drp[k] = erp[k] + QLB[bc] * drp[k - Nr].
    mov eax, [rsi]                        # Nc
    cmp eax, 40
    jl .Lgsm_frame_lag_old
    cmp eax, 120
    jle .Lgsm_frame_lag
.Lgsm_frame_lag_old:
    mov eax, [rip + gsm_nrp]
.Lgsm_frame_lag:
    mov [rip + gsm_nrp], eax
    mov r8d, eax                          # Nr
    mov eax, [rsi + 4]                    # bc
    lea rcx, [rip + gsm_qlb]
    mov r9d, [rcx + rax*4]                # brp
    lea rbx, [rip + gsm_dp + 120*4]       # drp
    xor r10d, r10d                        # k
.Lgsm_frame_ltp:
    mov eax, r10d
    sub eax, r8d
    movsxd rax, eax
    mov eax, [rbx + rax*4]
    mov ecx, r9d
    GSM_MULT_R
    add eax, [rdi + r10*4]
    GSM_SAT
    mov [rbx + r10*4], eax
    mov [rdi + r10*4], eax                # wt[40j + k] = drp[k]
    inc r10d
    cmp r10d, 40
    jb .Lgsm_frame_ltp
    lea rdx, [rip + gsm_dp]               # drp[-120..-1] = drp[-80..39]
    xor ecx, ecx
.Lgsm_frame_shift:
    mov eax, [rdx + rcx*4 + 40*4]
    mov [rdx + rcx*4], eax
    inc ecx
    cmp ecx, 120
    jb .Lgsm_frame_shift
    inc r12d
    cmp r12d, 4
    jb .Lgsm_frame_subframe

    # Log-area ratios (4.2.8): LARpp_j from LARc; LARpp_j_1 is the
    # previous frame's.
    mov eax, [rip + gsm_j]
    lea rsi, [rip + gsm_larpp]
    mov ecx, eax
    shl ecx, 5
    lea rdi, [rsi + rcx]                  # LARpp_j
    xor eax, 1
    mov [rip + gsm_j], eax
    shl eax, 5
    lea rsi, [rsi + rax]                  # LARpp_j_1
    xor r8d, r8d
.Lgsm_frame_lar:
    lea r9, [rip + gsm_params]
    mov eax, [r9 + r8*4]                  # LARc
    lea r9, [rip + gsm_mic]
    add eax, [r9 + r8*4]
    GSM_SAT
    shl eax, 10
    movsx eax, ax                         # a 16-bit shift
    lea r9, [rip + gsm_b2]
    sub eax, [r9 + r8*4]
    GSM_SAT
    lea r9, [rip + gsm_inva]
    mov ecx, [r9 + r8*4]
    GSM_MULT_R
    add eax, eax
    GSM_SAT
    mov [rdi + r8*4], eax
    inc r8d
    cmp r8d, 8
    jb .Lgsm_frame_lar

    # Short-term synthesis in four segments of interpolated coefficients.
    lea r12, [rip + gsm_wt]               # wt
    mov r13, r15                          # output
    xor r14d, r14d                        # segment
.Lgsm_frame_segment:
    xor r8d, r8d
.Lgsm_frame_interp:
    mov eax, [rsi + r8*4]                 # prev
    mov r9d, [rdi + r8*4]                 # cur
    cmp r14d, 0
    je .Lgsm_frame_interp0
    cmp r14d, 1
    je .Lgsm_frame_interp1
    cmp r14d, 2
    je .Lgsm_frame_interp2
    mov eax, r9d                          # 40-159: the current ratios
    jmp .Lgsm_frame_interp_done
.Lgsm_frame_interp0:                      # 0-12: prev/4 + cur/4 + prev/2
    mov r10d, eax
    sar eax, 2
    mov r11d, r9d
    sar r11d, 2
    add eax, r11d
    GSM_SAT
    sar r10d, 1
    add eax, r10d
    GSM_SAT
    jmp .Lgsm_frame_interp_done
.Lgsm_frame_interp1:                      # 13-26: prev/2 + cur/2
    sar eax, 1
    sar r9d, 1
    add eax, r9d
    GSM_SAT
    jmp .Lgsm_frame_interp_done
.Lgsm_frame_interp2:                      # 27-39: prev/4 + cur/4 + cur/2
    sar eax, 2
    mov r11d, r9d
    sar r11d, 2
    add eax, r11d
    GSM_SAT
    sar r9d, 1
    add eax, r9d
    GSM_SAT
.Lgsm_frame_interp_done:
    # LARp to the reflection coefficient rp (4.2.9.2).
    mov r10d, eax
    mov r11d, eax
    neg r11d
    cmp eax, 0
    jge .Lgsm_frame_rp_abs
    mov eax, r11d
    cmp eax, 32768
    jne .Lgsm_frame_rp_abs
    mov eax, 32767
.Lgsm_frame_rp_abs:
    cmp eax, 11059
    jge .Lgsm_frame_rp_mid
    add eax, eax
    jmp .Lgsm_frame_rp_sign
.Lgsm_frame_rp_mid:
    cmp eax, 20070
    jge .Lgsm_frame_rp_high
    add eax, 11059
    jmp .Lgsm_frame_rp_sign
.Lgsm_frame_rp_high:
    sar eax, 2
    add eax, 26112
    GSM_SAT
.Lgsm_frame_rp_sign:
    test r10d, r10d
    jns .Lgsm_frame_rp_store
    neg eax
.Lgsm_frame_rp_store:
    lea r9, [rip + gsm_larp]
    mov [r9 + r8*4], eax
    inc r8d
    cmp r8d, 8
    jb .Lgsm_frame_interp
    # The lattice over this segment's samples.
    lea rax, [rip + gsm_segment_lengths]
    mov ebx, [rax + r14*4]
    lea r9, [rip + gsm_larp]              # rrp
    lea r10, [rip + gsm_v]
.Lgsm_frame_sample:
    mov r11d, [r12]                       # sri = wt
    add r12, 4
    mov r8d, 7
.Lgsm_frame_tap:
    mov eax, [r10 + r8*4]                 # sri -= rrp[i] * v[i]
    mov ecx, [r9 + r8*4]
    GSM_MULT_R
    neg eax
    add eax, r11d
    GSM_SAT
    mov r11d, eax
    mov ecx, [r9 + r8*4]                  # v[i+1] = v[i] + rrp[i] * sri
    GSM_MULT_R
    add eax, [r10 + r8*4]
    GSM_SAT
    mov [r10 + r8*4 + 4], eax
    dec r8d
    jns .Lgsm_frame_tap
    mov [r10], r11d                       # v[0] = sr = sri
    # De-emphasis, truncation and upscaling (4.3.5).
    mov eax, [rip + gsm_msr]
    mov ecx, 28180
    GSM_MULT_R
    add eax, r11d
    GSM_SAT
    mov [rip + gsm_msr], eax
    add eax, eax
    GSM_SAT
    and eax, 0xfff8
    mov [r13], ax
    add r13, 2
    dec ebx
    jnz .Lgsm_frame_sample
    inc r14d
    cmp r14d, 4
    jb .Lgsm_frame_segment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN gsm_frame

RODATA
gsm_segment_lengths: .long 13, 14, 13, 120
