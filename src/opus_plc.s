# Handwritten stateful normal-mode CELT packet-loss concealment.
# RFC6716 celt.c: pitch/LPC reconstruction and comfort noise, BSD conditions
# in THIRD_PARTY_NOTICES. Copyright (c) 2007-2012 IETF Trust, CSIRO,
# Xiph.Org Foundation, Gregory Maxwell. No CRT/C/codec-DLL runtime.
.include "lamp.inc"
.include "opus_decoder_layout.inc"
.include "opus_lpc_layout.inc"
.include "opus_pitch_layout.inc"
.include "opus_spectral_layout.inc"
.include "opus_mdct_layout.inc"
.include "opus_filter_layout.inc"
RODATA
pl_ebands: .short 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100
pl_one: .float 1.0
pl_fade: .float 0.8
pl_decay_first: .float 1.5
pl_decay_later: .float 0.5
pl_noise: .float 1.0001
pl_lag: .float 0.008
pl_explosion: .float 0.2
.text
.equ PL_EXC, 0                   # 1024 floats
.equ PL_AC, 4096                 # 25 floats
.equ PL_MEM, 4224                # 24 floats
.equ PL_E, 4352                  # 1200 floats
.equ PL_ACWORK, 9152             # 1024 floats
.equ PL_CHANNEL, 112
.equ PL_PITCH, 116
.equ PL_LEN, 120
.equ PL_OFFSET, 124
.equ PL_DECAY, 128
.equ PL_S1, 132
.equ PL_S2, 136
.equ PL_FADE, 140
.equ PL_BAND, 144
.equ PL_SEED, 148
# Internal entry: frame request already validated by op_celt_decode_frame.
# A numerical/helper failure returns0; public caller poisons decoder state.
FN op_celt_decode_lost
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 176
    mov rbx, rcx
    mov r12, [rbx + DF_STATE]
    mov r13, [rbx + DF_WORK]
    mov r15d, [r12 + SD_CHANNELS]
    mov ecx, [rbx + DF_LM]
    mov r14d, 120
    shl r14d, cl
    lea eax, [r14 + 240]
    mov [rsp + PL_LEN], eax
    mov eax, dword ptr [rip + pl_one]
    mov [rsp + PL_FADE], eax
    mov dword ptr [rsp + PL_CHANNEL], 0
    cmp dword ptr [r12 + SD_LOSS], 5
    jge .Lpl_noise_path
    cmp dword ptr [rbx + DF_START], 0
    jne .Lpl_noise_path
    cmp dword ptr [r12 + SD_LOSS], 0
    jne .Lpl_reuse_pitch
    lea rax, [r12 + SD_DECODE]
    mov [rsp + 32 + PP_LEFT], rax
    add rax, SD_DECODE_STRIDE
    mov [rsp + 32 + PP_RIGHT], rax
    mov [rsp + 32 + PP_WORK], r13
    mov [rsp + 32 + PP_CHANNELS], r15d
    mov dword ptr [rsp + 32 + PP_INPUT_CAP], 2048
    mov dword ptr [rsp + 32 + PP_WORK_CAP], DW_SIZE
    lea rcx, [rsp + 32]
    call op_celt_pitch
    test eax, eax
    jz .Lpl_failed
    mov [r12 + SD_LAST_PITCH], eax
    jmp .Lpl_pitch_ready
.Lpl_reuse_pitch:
    mov eax, dword ptr [rip + pl_fade]
    mov [rsp + PL_FADE], eax
    mov eax, [r12 + SD_LAST_PITCH]
.Lpl_pitch_ready:
    mov [rsp + PL_PITCH], eax
.Lpl_pitch_channel:
    mov eax, [rsp + PL_CHANNEL]
    imul eax, SD_DECODE_STRIDE
    lea rsi, [r12 + SD_DECODE + 4096]
    add rsi, rax                # out_mem = decode + 2048-1024
    xor ecx, ecx
.Lpl_exc_copy:
    mov eax, [rsi + rcx*4]
    mov [r13 + rcx*4 + PL_EXC], eax
    inc ecx
    cmp ecx, 1024
    jb .Lpl_exc_copy
    cmp dword ptr [r12 + SD_LOSS], 0
    jne .Lpl_fir_request
    lea rax, [r13 + PL_EXC]
    mov [rsp + 32 + LA_X], rax
    lea rax, [r13 + PL_AC]
    mov [rsp + 32 + LA_AC], rax
    lea rax, [rip + op_celt_window]
    mov [rsp + 32 + LA_WINDOW], rax
    lea rax, [r13 + PL_ACWORK]
    mov [rsp + 32 + LA_SCRATCH], rax
    mov dword ptr [rsp + 32 + LA_N], 1024
    mov dword ptr [rsp + 32 + LA_LAG], 24
    mov dword ptr [rsp + 32 + LA_OVERLAP], 120
    mov dword ptr [rsp + 32 + LA_X_CAP], 1024
    mov dword ptr [rsp + 32 + LA_AC_CAP], 25
    mov dword ptr [rsp + 32 + LA_WINDOW_CAP], 120
    mov dword ptr [rsp + 32 + LA_SCRATCH_CAP], 1024
    lea rcx, [rsp + 32]
    call op_celt_autocorr
    test eax, eax
    jz .Lpl_failed
    movss xmm0, dword ptr [r13 + PL_AC]
    mulss xmm0, dword ptr [rip + pl_noise]
    movss dword ptr [r13 + PL_AC], xmm0
    mov ecx, 1
.Lpl_lag_window:
    cvtsi2ss xmm0, ecx
    mulss xmm0, dword ptr [rip + pl_lag]
    movss xmm1, dword ptr [r13 + rcx*4 + PL_AC]
    movaps xmm2, xmm1
    mulss xmm2, xmm0
    mulss xmm2, xmm0
    subss xmm1, xmm2
    movss dword ptr [r13 + rcx*4 + PL_AC], xmm1
    inc ecx
    cmp ecx, 24
    jbe .Lpl_lag_window
    mov eax, [rsp + PL_CHANNEL]
    imul eax, 96
    lea rax, [r12 + rax + SD_LPC]
    mov [rsp + 32 + LL_OUT], rax
    lea rax, [r13 + PL_AC]
    mov [rsp + 32 + LL_AC], rax
    mov dword ptr [rsp + 32 + LL_ORDER], 24
    mov dword ptr [rsp + 32 + LL_OUT_CAP], 24
    mov dword ptr [rsp + 32 + LL_AC_CAP], 25
    lea rcx, [rsp + 32]
    call op_celt_lpc
    test eax, eax
    jz .Lpl_failed
.Lpl_fir_request:
    xor ecx, ecx
.Lpl_fir_memory:
    mov eax, 1023
    sub eax, ecx
    mov eax, [rsi + rax*4]
    mov [r13 + rcx*4 + PL_MEM], eax
    inc ecx
    cmp ecx, 24
    jb .Lpl_fir_memory
    lea rax, [r13 + PL_EXC]
    mov [rsp + 32 + LF_X], rax
    mov [rsp + 32 + LF_OUT], rax
    mov eax, [rsp + PL_CHANNEL]
    imul eax, 96
    lea rax, [r12 + rax + SD_LPC]
    mov [rsp + 32 + LF_COEF], rax
    lea rax, [r13 + PL_MEM]
    mov [rsp + 32 + LF_MEM], rax
    mov dword ptr [rsp + 32 + LF_N], 1024
    mov dword ptr [rsp + 32 + LF_ORDER], 24
    mov dword ptr [rsp + 32 + LF_X_CAP], 1024
    mov dword ptr [rsp + 32 + LF_COEF_CAP], 24
    mov dword ptr [rsp + 32 + LF_OUT_CAP], 1024
    mov dword ptr [rsp + 32 + LF_MEM_CAP], 24
    lea rcx, [rsp + 32]
    call op_celt_fir
    test eax, eax
    jz .Lpl_failed
    mov r8d, [rsp + PL_PITCH]
    cmp r8d, 512
    jle .Lpl_energy_period
    mov r8d, 512
.Lpl_energy_period:
    movss xmm0, dword ptr [rip + pl_one] # E1
    movaps xmm1, xmm0             # E2
    mov eax, 1024
    sub eax, r8d
    lea r9, [r13 + PL_EXC]
    lea r9, [r9 + rax*4]
    sub eax, r8d
    lea r10, [r13 + PL_EXC]
    lea r10, [r10 + rax*4]
    xor ecx, ecx
.Lpl_energy:
    movss xmm2, dword ptr [r9 + rcx*4]
    mulss xmm2, xmm2
    addss xmm0, xmm2
    movss xmm2, dword ptr [r10 + rcx*4]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    inc ecx
    cmp ecx, r8d
    jb .Lpl_energy
    minss xmm0, xmm1
    divss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss dword ptr [rsp + PL_DECAY], xmm0
    mov eax, 1024
    sub eax, [rsp + PL_PITCH]
    mov [rsp + PL_OFFSET], eax
    xorps xmm3, xmm3
    xor ecx, ecx
.Lpl_repeat:
    mov eax, [rsp + PL_OFFSET]
    add eax, ecx
    cmp eax, 1024
    jl .Lpl_repeat_sample
    mov edx, [rsp + PL_PITCH]
    sub [rsp + PL_OFFSET], edx
    sub eax, edx
    mulss xmm0, xmm0
.Lpl_repeat_sample:
    movss xmm1, dword ptr [r13 + rax*4 + PL_EXC]
    mulss xmm1, xmm0
    movss dword ptr [r13 + rcx*4 + PL_E], xmm1
    movss xmm2, dword ptr [rsi + rax*4]
    mulss xmm2, xmm2
    addss xmm3, xmm2
    inc ecx
    cmp ecx, [rsp + PL_LEN]
    jb .Lpl_repeat
    movss dword ptr [rsp + PL_S1], xmm3
    movss xmm0, dword ptr [rsp + PL_FADE]
    xor ecx, ecx
.Lpl_apply_fade:
    movss xmm1, dword ptr [r13 + rcx*4 + PL_E]
    mulss xmm1, xmm0
    movss dword ptr [r13 + rcx*4 + PL_E], xmm1
    inc ecx
    cmp ecx, [rsp + PL_LEN]
    jb .Lpl_apply_fade
    xor ecx, ecx
.Lpl_iir_memory:
    mov eax, 1023
    sub eax, ecx
    mov eax, [rsi + rax*4]
    mov [r13 + rcx*4 + PL_MEM], eax
    inc ecx
    cmp ecx, 24
    jb .Lpl_iir_memory
    lea rax, [r13 + PL_E]
    mov [rsp + 32 + LF_X], rax
    mov [rsp + 32 + LF_OUT], rax
    mov eax, [rsp + PL_LEN]
    mov [rsp + 32 + LF_N], eax
    mov [rsp + 32 + LF_X_CAP], eax
    mov [rsp + 32 + LF_OUT_CAP], eax
    lea rcx, [rsp + 32]
    call op_celt_iir
    test eax, eax
    jz .Lpl_failed
    xorps xmm0, xmm0
    xor ecx, ecx
.Lpl_output_energy:
    movss xmm1, dword ptr [r13 + rcx*4 + PL_E]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc ecx
    cmp ecx, [rsp + PL_LEN]
    jb .Lpl_output_energy
    movaps xmm1, xmm0
    mulss xmm1, dword ptr [rip + pl_explosion]
    movss xmm2, dword ptr [rsp + PL_S1]
    comiss xmm2, xmm1
    jbe .Lpl_zero_explosion
    comiss xmm2, xmm0
    jae .Lpl_filter_overlap
    addss xmm2, dword ptr [rip + pl_one]
    addss xmm0, dword ptr [rip + pl_one]
    divss xmm2, xmm0
    cvtss2sd xmm2, xmm2
    sqrtsd xmm2, xmm2
    cvtsd2ss xmm2, xmm2
    xor ecx, ecx
.Lpl_attenuate:
    movss xmm0, dword ptr [r13 + rcx*4 + PL_E]
    mulss xmm0, xmm2
    movss dword ptr [r13 + rcx*4 + PL_E], xmm0
    inc ecx
    cmp ecx, [rsp + PL_LEN]
    jb .Lpl_attenuate
    jmp .Lpl_filter_overlap
.Lpl_zero_explosion:
    xor ecx, ecx
.Lpl_zero_loop:
    mov dword ptr [r13 + rcx*4 + PL_E], 0
    inc ecx
    cmp ecx, [rsp + PL_LEN]
    jb .Lpl_zero_loop
.Lpl_filter_overlap:
    mov [rsp + 32 + OF_BUFFER], rsi
    lea rax, [rsi + 4096]
    mov [rsp + 32 + OF_OUT], rax
    mov dword ptr [rsp + 32 + OF_N], 120
    mov dword ptr [rsp + 32 + OF_HISTORY], 1024
    mov eax, [r12 + SD_PERIOD]
    cmp eax, 15
    jge .Lpl_overlap_period
    mov eax, 15
.Lpl_overlap_period:
    mov [rsp + 32 + OF_PERIOD0], eax
    mov [rsp + 32 + OF_PERIOD1], eax
    mov eax, [r12 + SD_GAIN]
    mov [rsp + 32 + OF_GAIN0], eax
    mov [rsp + 32 + OF_GAIN1], eax
    mov eax, [r12 + SD_TAP]
    mov [rsp + 32 + OF_TAP0], eax
    mov [rsp + 32 + OF_TAP1], eax
    mov dword ptr [rsp + 32 + OF_OVERLAP], 0
    mov dword ptr [rsp + 32 + OF_BUFFER_CAP], 1144
    mov dword ptr [rsp + 32 + OF_OUT_CAP], 120
    lea rcx, [rsp + 32]
    call op_celt_comb_filter
    test eax, eax
    jz .Lpl_failed
    mov edx, 1144
    sub edx, r14d
    lea r8, [rsi + r14*4]
    xor ecx, ecx
.Lpl_shift_pitch:
    mov eax, [r8 + rcx*4]
    mov [rsi + rcx*4], eax
    inc ecx
    cmp ecx, edx
    jb .Lpl_shift_pitch
    lea r8, [rip + op_celt_window]
    lea r9, [r13 + PL_E]
    lea r9, [r9 + r14*4]
    xor ecx, ecx
.Lpl_tdac:
    mov eax, 119
    sub eax, ecx
    movss xmm0, dword ptr [r8 + rcx*4]
    mulss xmm0, dword ptr [r9 + rax*4]
    movss xmm1, dword ptr [r8 + rax*4]
    mulss xmm1, dword ptr [r9 + rcx*4]
    addss xmm0, xmm1
    movaps xmm1, xmm0
    mulss xmm1, dword ptr [r8 + rax*4]
    movss dword ptr [rsi + rcx*4 + 4096], xmm1
    mulss xmm0, dword ptr [r8 + rcx*4]
    movss dword ptr [rsi + rax*4 + 4096], xmm0
    inc ecx
    cmp ecx, 60
    jb .Lpl_tdac
    mov eax, 1024
    sub eax, r14d
    lea r8, [rsi + rax*4]
    xor ecx, ecx
.Lpl_pitch_output:
    mov eax, [r13 + rcx*4 + PL_E]
    mov [r8 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Lpl_pitch_output
    # Remove the postfilter from the new overlap for the next received frame.
    lea rax, [r13 + PL_E]
    mov [rsp + 32 + OF_OUT], rax
    mov eax, [r12 + SD_GAIN]
    xor eax, 0x80000000
    mov [rsp + 32 + OF_GAIN0], eax
    mov [rsp + 32 + OF_GAIN1], eax
    lea rcx, [rsp + 32]
    call op_celt_comb_filter
    test eax, eax
    jz .Lpl_failed
    xor ecx, ecx
.Lpl_save_prefiltered:
    mov eax, [r13 + rcx*4 + PL_E]
    mov [rsi + rcx*4 + 4096], eax
    inc ecx
    cmp ecx, 120
    jb .Lpl_save_prefiltered
    inc dword ptr [rsp + PL_CHANNEL]
    mov eax, [rsp + PL_CHANNEL]
    cmp eax, r15d
    jb .Lpl_pitch_channel
    jmp .Lpl_deemphasis
.Lpl_noise_path:
    mov eax, [r12 + SD_RNG]
    mov [rsp + PL_SEED], eax
    cmp dword ptr [r12 + SD_LOSS], 5
    jge .Lpl_noise_vectors
    movss xmm0, dword ptr [rip + pl_decay_first]
    cmp dword ptr [r12 + SD_LOSS], 0
    je .Lpl_decay_ready
    movss xmm0, dword ptr [rip + pl_decay_later]
.Lpl_decay_ready:
    xor r8d, r8d
.Lpl_decay_channel:
    imul eax, r8d, 21
    lea r9, [r12 + SD_OLD_E]
    lea r9, [r9 + rax*4]
    mov ecx, [rbx + DF_START]
    cmp ecx, [rbx + DF_END]
    jae .Lpl_decay_channel_done
.Lpl_decay_energy:
    movss xmm1, dword ptr [r9 + rcx*4]
    subss xmm1, xmm0
    movss dword ptr [r9 + rcx*4], xmm1
    inc ecx
    cmp ecx, [rbx + DF_END]
    jb .Lpl_decay_energy
.Lpl_decay_channel_done:
    inc r8d
    cmp r8d, r15d
    jb .Lpl_decay_channel
.Lpl_noise_vectors:
    mov dword ptr [rsp + PL_CHANNEL], 0
.Lpl_noise_channel:
    mov eax, [rsp + PL_CHANNEL]
    imul eax, r14d
    lea rdi, [r13 + DW_X]
    lea rdi, [rdi + rax*4]
    xor ecx, ecx
.Lpl_noise_clear:
    mov dword ptr [rdi + rcx*4], 0
    inc ecx
    cmp ecx, r14d
    jb .Lpl_noise_clear
    mov eax, [rbx + DF_START]
    mov [rsp + PL_BAND], eax
.Lpl_noise_band:
    lea r8, [rip + pl_ebands]
    mov eax, [rsp + PL_BAND]
    movzx r9d, word ptr [r8 + rax*2]
    movzx r10d, word ptr [r8 + rax*2 + 2]
    sub r10d, r9d
    mov ecx, [rbx + DF_LM]
    shl r9d, cl
    shl r10d, cl
    lea r8, [rdi + r9*4]
    mov eax, [rsp + PL_SEED]
    xor ecx, ecx
.Lpl_noise_sample:
    imul eax, eax, 1664525
    add eax, 1013904223
    mov edx, eax
    sar edx, 20
    cvtsi2ss xmm0, edx
    movss dword ptr [r8 + rcx*4], xmm0
    inc ecx
    cmp ecx, r10d
    jb .Lpl_noise_sample
    mov [rsp + PL_SEED], eax
    mov rcx, r8
    mov edx, r10d
    movss xmm2, dword ptr [rip + pl_one]
    call op_celt_renormalize
    test eax, eax
    jz .Lpl_failed
    inc dword ptr [rsp + PL_BAND]
    cmp dword ptr [rsp + PL_BAND], 21
    jb .Lpl_noise_band
    inc dword ptr [rsp + PL_CHANNEL]
    mov eax, [rsp + PL_CHANNEL]
    cmp eax, r15d
    jb .Lpl_noise_channel
    mov eax, [rsp + PL_SEED]
    mov [r12 + SD_RNG], eax
    mov eax, [rbx + DF_START]
    cmp eax, [rbx + DF_END]
    jb .Lpl_noise_denormalize
    # log2Amp has zero energy in every band for an empty/reversed range.
    # The reference clears below start and above end after denormalizing.
    lea rdi, [r13 + DW_FREQ]
    mov ecx, r14d
    imul ecx, r15d
    xor eax, eax
    rep stosd
    jmp .Lpl_noise_denormalized
.Lpl_noise_denormalize:
    lea rax, [r13 + DW_X]
    mov [rsp + 32 + OD_X], rax
    lea rax, [r13 + DW_FREQ]
    mov [rsp + 32 + OD_FREQ], rax
    lea rax, [r12 + SD_OLD_E]
    cmp dword ptr [r12 + SD_LOSS], 5
    jl .Lpl_noise_energy
    lea rax, [r12 + SD_BACKGROUND]
.Lpl_noise_energy:
    mov [rsp + 32 + OD_ENERGY], rax
    lea rax, [r13 + DW_GAINS]
    mov [rsp + 32 + OD_GAINS], rax
    mov [rsp + 32 + OD_CHANNELS], r15d
    mov eax, [rbx + DF_LM]
    mov [rsp + 32 + OD_LM], eax
    mov eax, [rbx + DF_START]
    mov [rsp + 32 + OD_START], eax
    mov eax, [rbx + DF_END]
    mov [rsp + 32 + OD_END], eax
    mov eax, [r12 + SD_DOWNSAMPLE]
    mov [rsp + 32 + OD_DOWNSAMPLE], eax
    mov dword ptr [rsp + 32 + OD_X_CAP], 1920
    mov dword ptr [rsp + 32 + OD_FREQ_CAP], 1920
    mov dword ptr [rsp + 32 + OD_ENERGY_CAP], 42
    mov dword ptr [rsp + 32 + OD_GAIN_CAP], 42
    lea rcx, [rsp + 32]
    call op_celt_denormalize
    test eax, eax
    jz .Lpl_failed
.Lpl_noise_denormalized:
    xor r8d, r8d
.Lpl_noise_overlap_channel:
    imul eax, r8d, SD_DECODE_STRIDE
    lea r9, [r12 + SD_DECODE + 8192]
    add r9, rax
    imul eax, r8d, 120
    lea r10, [r13 + DW_OVERLAP]
    lea r10, [r10 + rax*4]
    xor ecx, ecx
.Lpl_noise_overlap_copy:
    mov eax, [r9 + rcx*4]
    mov [r10 + rcx*4], eax
    inc ecx
    cmp ecx, 120
    jb .Lpl_noise_overlap_copy
    inc r8d
    cmp r8d, r15d
    jb .Lpl_noise_overlap_channel
    lea rax, [r13 + DW_FREQ]
    mov [rsp + 32 + OY_FREQ], rax
    lea rax, [r13 + DW_TIME]
    mov [rsp + 32 + OY_OUT], rax
    lea rax, [r13 + DW_OVERLAP]
    mov [rsp + 32 + OY_OVERLAP], rax
    lea rax, [r13 + DW_SYNTH_SCRATCH]
    mov [rsp + 32 + OY_SCRATCH], rax
    mov [rsp + 32 + OY_CHANNELS], r15d
    mov eax, [rbx + DF_LM]
    mov [rsp + 32 + OY_LM], eax
    mov dword ptr [rsp + 32 + OY_SHORT], 0
    mov dword ptr [rsp + 32 + OY_FREQ_CAP], 1920
    mov dword ptr [rsp + 32 + OY_OUT_CAP], 1920
    mov dword ptr [rsp + 32 + OY_OVERLAP_CAP], 240
    mov dword ptr [rsp + 32 + OY_SCRATCH_CAP], 3000
    lea rcx, [rsp + 32]
    call op_celt_synthesis
    test eax, eax
    jz .Lpl_failed
    xor r8d, r8d
.Lpl_noise_output_channel:
    imul eax, r8d, SD_DECODE_STRIDE
    lea r9, [r12 + SD_DECODE]
    add r9, rax
    mov eax, 2048
    sub eax, r14d
    lea r10, [r9 + rax*4]
    mov eax, r8d
    imul eax, r14d
    lea r11, [r13 + DW_TIME]
    lea r11, [r11 + rax*4]
    xor ecx, ecx
.Lpl_noise_output_copy:
    mov eax, [r11 + rcx*4]
    mov [r10 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Lpl_noise_output_copy
    imul eax, r8d, 120
    lea r11, [r13 + DW_OVERLAP]
    lea r11, [r11 + rax*4]
    xor ecx, ecx
.Lpl_noise_overlap_save:
    mov eax, [r11 + rcx*4]
    mov [r9 + rcx*4 + 8192], eax
    inc ecx
    cmp ecx, 120
    jb .Lpl_noise_overlap_save
    inc r8d
    cmp r8d, r15d
    jb .Lpl_noise_output_channel
.Lpl_deemphasis:
    xor r8d, r8d
.Lpl_gather_channel:
    imul eax, r8d, SD_DECODE_STRIDE
    lea r9, [r12 + SD_DECODE]
    add r9, rax
    mov eax, 2048
    sub eax, r14d
    lea r9, [r9 + rax*4]
    mov eax, r8d
    imul eax, r14d
    lea r10, [r13 + DW_TIME]
    lea r10, [r10 + rax*4]
    xor ecx, ecx
.Lpl_gather_sample:
    mov eax, [r9 + rcx*4]
    mov [r10 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Lpl_gather_sample
    inc r8d
    cmp r8d, r15d
    jb .Lpl_gather_channel
    lea rax, [r13 + DW_TIME]
    mov [rsp + 32 + OE_X], rax
    mov rax, [rbx + DF_PCM]
    mov [rsp + 32 + OE_PCM], rax
    lea rax, [r12 + SD_DEEMPH]
    mov [rsp + 32 + OE_MEM], rax
    mov [rsp + 32 + OE_N], r14d
    mov [rsp + 32 + OE_CHANNELS], r15d
    mov eax, [r12 + SD_DOWNSAMPLE]
    mov [rsp + 32 + OE_DOWNSAMPLE], eax
    mov dword ptr [rsp + 32 + OE_X_CAP], 1920
    mov eax, [rbx + DF_PCM_CAP]
    mov [rsp + 32 + OE_PCM_CAP], eax
    mov dword ptr [rsp + 32 + OE_MEM_CAP], 2
    lea rcx, [rsp + 32]
    call op_celt_deemphasis
    test eax, eax
    jz .Lpl_failed
    inc dword ptr [r12 + SD_LOSS]
    mov eax, r14d
    xor edx, edx
    div dword ptr [r12 + SD_DOWNSAMPLE]
    jmp .Lpl_done
.Lpl_failed:
    xor eax, eax
.Lpl_done:
    add rsp, 176
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_decode_lost
