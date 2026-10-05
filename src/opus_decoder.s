# Handwritten stateful standard-mode CELT frame decoder.
# Normative BSD RFC6716 celt.c frame/state orchestration, see THIRD_PARTY_NOTICES.
# Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
# Gregory Maxwell. No C/CRT/codec DLL runtime dependencies.
.include "lamp.inc"
.include "opus_decoder_layout.inc"
.include "opus_controls_layout.inc"
.include "opus_bands_layout.inc"
.include "opus_spectral_layout.inc"
.include "opus_mdct_layout.inc"
.include "opus_filter_layout.inc"
RODATA
df_floor: .float -28.0
df_background_step: .float 0.001
.text
# RCX=state, EDX=byte capacity, R8D=output channels1/2, R9D=output rate.
# EAX=1/0. Reset initializes independent output/postfilter/energy histories.
FN op_celt_decoder_init
    test rcx, rcx
    jz .Ldf_init_bad
    cmp edx, SD_SIZE
    jb .Ldf_init_bad
    cmp r8d, 1
    jb .Ldf_init_bad
    cmp r8d, 2
    ja .Ldf_init_bad
    mov r10d, 1
    cmp r9d, 48000
    je .Ldf_init_rate
    mov r10d, 2
    cmp r9d, 24000
    je .Ldf_init_rate
    mov r10d, 3
    cmp r9d, 16000
    je .Ldf_init_rate
    mov r10d, 4
    cmp r9d, 12000
    je .Ldf_init_rate
    mov r10d, 6
    cmp r9d, 8000
    jne .Ldf_init_bad
.Ldf_init_rate:
    push rdi
    mov r11, rcx
    mov rdi, rcx
    xor eax, eax
    mov ecx, SD_SIZE/8
    rep stosq
    mov dword ptr [r11 + SD_MAGIC], SD_MAGIC_VALUE
    mov [r11 + SD_CHANNELS], r8d
    mov [r11 + SD_DOWNSAMPLE], r10d
    xor ecx, ecx
    mov eax, 0xc1e00000
.Ldf_init_histories:
    mov [r11 + rcx*4 + SD_OLD_LOG], eax
    mov [r11 + rcx*4 + SD_OLD_LOG2], eax
    inc ecx
    cmp ecx, 42
    jb .Ldf_init_histories
    mov eax, 1
    pop rdi
    ret
.Ldf_init_bad:
    xor eax, eax
    ret
ENDFN op_celt_decoder_init

.equ FD_ANTI, 176
.equ FD_CC, 180
.equ FD_C, 184
.equ FD_SAMPLES, 188
.equ FD_CHANNEL, 192
.equ FD_HISTORY, 196
# RCX=72-byte request. EAX=frames/channel, 0 rejected public input, or -1
# failed entropy/numerical frame. Late failure poisons state until reset.
# Input request is immutable. State/work/PCM/payload/entropy do not overlap.
# Shared primitive scratch still requires one decode owner at a time.
# Null/zero/one-byte payloads invoke the bounded loss-concealment stage.
FN op_celt_decode_frame
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 208
    mov rbx, rcx
    test rbx, rbx
    jz .Ldf_invalid
    mov r12, [rbx + DF_STATE]
    mov r13, [rbx + DF_WORK]
    test r12, r12
    jz .Ldf_invalid
    test r13, r13
    jz .Ldf_invalid
    cmp qword ptr [rbx + DF_PCM], 0
    je .Ldf_invalid
    cmp dword ptr [rbx + DF_STATE_CAP], SD_SIZE
    jb .Ldf_invalid
    cmp dword ptr [rbx + DF_WORK_CAP], DW_SIZE
    jb .Ldf_invalid
    cmp dword ptr [rbx + DF_LEN], 1275
    ja .Ldf_invalid
    cmp dword ptr [r12 + SD_MAGIC], SD_MAGIC_VALUE
    jne .Ldf_invalid
    cmp dword ptr [r12 + SD_ERROR], 0
    jne .Ldf_invalid
    cmp dword ptr [r12 + SD_LOSS], 0x7ffffffe
    ja .Ldf_invalid
    mov eax, [r12 + SD_CHANNELS]
    cmp eax, 1
    jb .Ldf_invalid
    cmp eax, 2
    ja .Ldf_invalid
    mov [rsp + FD_CC], eax
    mov ecx, [rbx + DF_CHANNELS]
    cmp ecx, 1
    jb .Ldf_invalid
    cmp ecx, 2
    ja .Ldf_invalid
    mov [rsp + FD_C], ecx
    mov ecx, [rbx + DF_LM]
    cmp ecx, 3
    ja .Ldf_invalid
    mov r15d, 1
    shl r15d, cl
    imul r14d, r15d, 120
    mov eax, r14d
    xor edx, edx
    mov ecx, [r12 + SD_DOWNSAMPLE]
    cmp ecx, 1
    jb .Ldf_invalid
    cmp ecx, 4
    jbe .Ldf_rate_valid
    cmp ecx, 6
    jne .Ldf_invalid
.Ldf_rate_valid:
    div ecx
    mov [rsp + FD_SAMPLES], eax
    imul eax, dword ptr [rsp + FD_CC]
    cmp [rbx + DF_PCM_CAP], eax
    jb .Ldf_invalid
    mov eax, [rbx + DF_START]
    cmp eax, 20
    ja .Ldf_invalid
    mov edx, [rbx + DF_END]
    cmp edx, 21
    ja .Ldf_invalid
    test edx, edx
    jz .Ldf_invalid
    cmp edx, eax
    jg .Ldf_band_range_valid
    # Hybrid PLC during a bandwidth transition can have no active bands.
    cmp qword ptr [rbx + DF_DATA], 0
    je .Ldf_band_range_valid
    cmp dword ptr [rbx + DF_LEN], 1
    ja .Ldf_invalid
.Ldf_band_range_valid:
    cmp dword ptr [r12 + SD_PERIOD], 1022
    ja .Ldf_invalid
    cmp dword ptr [r12 + SD_PERIOD_OLD], 1022
    ja .Ldf_invalid
    cmp dword ptr [r12 + SD_TAP], 2
    ja .Ldf_invalid
    cmp dword ptr [r12 + SD_TAP_OLD], 2
    ja .Ldf_invalid
    mov eax, [r12 + SD_GAIN]
    cmp eax, 0x3f800000
    ja .Ldf_invalid
    mov eax, [r12 + SD_GAIN_OLD]
    cmp eax, 0x3f800000
    ja .Ldf_invalid
    xor ecx, ecx
.Ldf_state_signal_guard:
    mov eax, [r12 + rcx*4 + SD_DECODE]
    and eax, 0x7fffffff
    cmp eax, 0x76800000
    ja .Ldf_invalid
    inc ecx
    cmp ecx, 4336
    jb .Ldf_state_signal_guard
    xor ecx, ecx
.Ldf_state_energy_guard:
    mov eax, [r12 + rcx*4 + SD_OLD_E]
    and eax, 0x7fffffff
    cmp eax, 0x43200000
    ja .Ldf_invalid
    inc ecx
    cmp ecx, 168
    jb .Ldf_state_energy_guard
    xor ecx, ecx
.Ldf_state_lpc_guard:
    mov eax, [r12 + rcx*4 + SD_LPC]
    and eax, 0x7fffffff
    cmp eax, 0x58800000
    ja .Ldf_invalid
    inc ecx
    cmp ecx, 48
    jb .Ldf_state_lpc_guard
    mov eax, [r12 + SD_DEEMPH]
    and eax, 0x7fffffff
    cmp eax, 0x7b800000
    ja .Ldf_invalid
    mov eax, [r12 + SD_DEEMPH + 4]
    and eax, 0x7fffffff
    cmp eax, 0x7b800000
    ja .Ldf_invalid
    cmp qword ptr [rbx + DF_DATA], 0
    je .Ldf_lost_frame
    cmp dword ptr [rbx + DF_LEN], 1
    jbe .Ldf_lost_frame
    mov rsi, [rbx + DF_EC]
    test rsi, rsi
    jz .Ldf_guards_done
    mov rax, [rbx + DF_DATA]
    cmp [rsi], rax
    jne .Ldf_invalid
    mov eax, [rbx + DF_LEN]
    cmp [rsi + 8], eax
    jne .Ldf_invalid
    cmp [rsi + 28], eax
    ja .Ldf_invalid
    cmp [rsi + 12], eax
    ja .Ldf_invalid
    cmp dword ptr [rsi + 32], 0x800000
    jbe .Ldf_invalid
    cmp dword ptr [rsi + 32], 0x80000000
    ja .Ldf_invalid
    cmp dword ptr [rsi + 20], 32
    ja .Ldf_invalid
    cmp dword ptr [rsi + 24], 32768
    ja .Ldf_invalid
.Ldf_guards_done:
    # All public validation has finished. A later failure requires reset.
    mov rdi, r13
    xor eax, eax
    mov ecx, DW_SIZE/8
    rep stosq
    test rsi, rsi
    jnz .Ldf_entropy_ready
    lea rsi, [r13 + DW_EC]
    mov rcx, rsi
    mov rdx, [rbx + DF_DATA]
    mov r8d, [rbx + DF_LEN]
    call op_ec_init
.Ldf_entropy_ready:
    lea rdi, [r13 + DW_CONTROLS]
    mov [rdi + OCT_EC], rsi
    lea rax, [r12 + SD_OLD_E]
    mov [rdi + OCT_OLD], rax
    lea rax, [r13 + DW_TF]
    mov [rdi + OCT_TF], rax
    lea rax, [r13 + DW_OFFSETS]
    mov [rdi + OCT_OFFSETS], rax
    lea rax, [r13 + DW_CAPS]
    mov [rdi + OCT_CAPS], rax
    lea rax, [r13 + DW_BITS]
    mov [rdi + OCT_BITS], rax
    lea rax, [r13 + DW_FINE]
    mov [rdi + OCT_FINE], rax
    lea rax, [r13 + DW_PRIORITY]
    mov [rdi + OCT_PRIORITY], rax
    mov eax, [rbx + DF_START]
    mov [rdi + OCT_START], eax
    mov eax, [rbx + DF_END]
    mov [rdi + OCT_END], eax
    mov eax, [rsp + FD_C]
    mov [rdi + OCT_CHANNELS], eax
    mov eax, [rbx + DF_LM]
    mov [rdi + OCT_LM], eax
    mov rcx, rdi
    call op_celt_controls
    test eax, eax
    js .Ldf_failed
    # Shared spectral reconstruction, with planar X stride N per channel.
    mov [rsp + 32 + OA_EC], rsi
    lea rax, [r13 + DW_X]
    mov [rsp + 32 + OA_X], rax
    xor eax, eax
    cmp dword ptr [rsp + FD_C], 2
    jne .Ldf_bands_y_ready
    lea rax, [r13 + DW_X]
    lea rax, [rax + r14*4]
.Ldf_bands_y_ready:
    mov [rsp + 32 + OA_Y], rax
    lea rax, [r13 + DW_MASKS]
    mov [rsp + 32 + OA_MASKS], rax
    lea rax, [r13 + DW_BITS]
    mov [rsp + 32 + OA_PULSES], rax
    lea rax, [r13 + DW_TF]
    mov [rsp + 32 + OA_TF], rax
    lea rax, [r13 + DW_NORM]
    mov [rsp + 32 + OA_NORM], rax
    lea rax, [r13 + DW_BAND_SCRATCH]
    mov [rsp + 32 + OA_SCRATCH], rax
    lea rax, [r12 + SD_RNG]
    mov [rsp + 32 + OA_SEED], rax
    mov eax, [rbx + DF_START]
    mov [rsp + 32 + OA_START], eax
    mov eax, [rbx + DF_END]
    mov [rsp + 32 + OA_END], eax
    mov eax, [rbx + DF_LM]
    mov [rsp + 32 + OA_LM], eax
    mov eax, [r13 + DW_CONTROLS + OCT_TRANSIENT]
    mov [rsp + 32 + OA_SHORT], eax
    mov eax, [r13 + DW_CONTROLS + OCT_SPREAD]
    mov [rsp + 32 + OA_SPREAD], eax
    mov eax, [r13 + DW_CONTROLS + OCT_DUAL]
    mov [rsp + 32 + OA_DUAL], eax
    mov eax, [r13 + DW_CONTROLS + OCT_INTENSITY]
    mov [rsp + 32 + OA_INTENSITY], eax
    mov eax, [rbx + DF_LEN]
    shl eax, 6
    sub eax, [r13 + DW_CONTROLS + OCT_ANTI]
    mov [rsp + 32 + OA_TOTAL], eax
    mov eax, [r13 + DW_CONTROLS + OCT_BALANCE]
    mov [rsp + 32 + OA_BALANCE], eax
    mov eax, [r13 + DW_CONTROLS + OCT_CODED]
    mov [rsp + 32 + OA_CODED], eax
    mov [rsp + 32 + OA_X_CAP], r14d
    mov [rsp + 32 + OA_Y_CAP], r14d
    mov dword ptr [rsp + 32 + OA_NORM_CAP], 1600
    mov dword ptr [rsp + 32 + OA_SCRATCH_CAP], 176
    mov dword ptr [rsp + 32 + OA_MASK_CAP], 42
    lea rcx, [rsp + 32]
    call op_celt_bands
    test eax, eax
    jz .Ldf_failed
    mov dword ptr [rsp + FD_ANTI], 0
    cmp dword ptr [r13 + DW_CONTROLS + OCT_ANTI], 0
    je .Ldf_final_energy
    mov rcx, rsi
    mov edx, 1
    call op_ec_bits
    mov [rsp + FD_ANTI], eax
.Ldf_final_energy:
    mov rcx, rsi
    call op_ec_tell
    mov edx, [rbx + DF_LEN]
    shl edx, 3
    sub edx, eax
    mov [rsp + 32 + 52], edx
    mov [rsp + 32], rsi
    lea rax, [r12 + SD_OLD_E]
    mov [rsp + 32 + 8], rax
    lea rax, [r13 + DW_FINE]
    mov [rsp + 32 + 16], rax
    lea rax, [r13 + DW_PRIORITY]
    mov [rsp + 32 + 24], rax
    mov eax, [rbx + DF_START]
    mov [rsp + 32 + 32], eax
    mov eax, [rbx + DF_END]
    mov [rsp + 32 + 36], eax
    mov eax, [rsp + FD_C]
    mov [rsp + 32 + 40], eax
    mov dword ptr [rsp + 32 + 56], 21
    lea rcx, [rsp + 32]
    call op_celt_final
    cmp dword ptr [rsp + FD_ANTI], 0
    je .Ldf_denormalize
    lea rax, [r13 + DW_X]
    mov [rsp + 32 + OS_X], rax
    lea rax, [r13 + DW_MASKS]
    mov [rsp + 32 + OS_MASKS], rax
    lea rax, [r12 + SD_OLD_E]
    mov [rsp + 32 + OS_ENERGY], rax
    lea rax, [r12 + SD_OLD_LOG]
    mov [rsp + 32 + OS_PREV1], rax
    lea rax, [r12 + SD_OLD_LOG2]
    mov [rsp + 32 + OS_PREV2], rax
    lea rax, [r13 + DW_BITS]
    mov [rsp + 32 + OS_PULSES], rax
    mov eax, [rbx + DF_LM]
    mov [rsp + 32 + OS_LM], eax
    mov eax, [rsp + FD_C]
    mov [rsp + 32 + OS_CHANNELS], eax
    mov [rsp + 32 + OS_SIZE], r14d
    mov eax, [rbx + DF_START]
    mov [rsp + 32 + OS_START], eax
    mov eax, [rbx + DF_END]
    mov [rsp + 32 + OS_END], eax
    mov eax, [r12 + SD_RNG]
    mov [rsp + 32 + OS_SEED], eax
    mov dword ptr [rsp + 32 + OS_X_CAP], 1920
    mov dword ptr [rsp + 32 + OS_MASK_CAP], 42
    mov dword ptr [rsp + 32 + OS_ENERGY_CAP], 42
    mov dword ptr [rsp + 32 + OS_PULSE_CAP], 21
    lea rcx, [rsp + 32]
    call op_celt_anti_collapse
    test eax, eax
    jz .Ldf_failed
.Ldf_denormalize:
    # A silent frame still consumes shapes/final energy before forcing silence.
    cmp dword ptr [r13 + DW_CONTROLS + OCT_SILENCE], 0
    je .Ldf_denorm_request
    mov ecx, [rsp + FD_C]
    imul ecx, 21
    xor eax, eax
.Ldf_silent_energy:
    mov dword ptr [r12 + rax*4 + SD_OLD_E], 0xc1e00000
    inc eax
    cmp eax, ecx
    jb .Ldf_silent_energy
    jmp .Ldf_frequency_ready  # workspace gains/frequencies already zero
.Ldf_denorm_request:
    lea rax, [r13 + DW_X]
    mov [rsp + 32 + OD_X], rax
    lea rax, [r13 + DW_FREQ]
    mov [rsp + 32 + OD_FREQ], rax
    lea rax, [r12 + SD_OLD_E]
    mov [rsp + 32 + OD_ENERGY], rax
    lea rax, [r13 + DW_GAINS]
    mov [rsp + 32 + OD_GAINS], rax
    mov eax, [rsp + FD_C]
    mov [rsp + 32 + OD_CHANNELS], eax
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
    jz .Ldf_failed
.Ldf_frequency_ready:
    mov eax, [rsp + FD_C]
    cmp eax, [rsp + FD_CC]
    je .Ldf_shift_history
    cmp eax, 1
    jne .Ldf_stereo_to_mono
    lea r8, [r13 + DW_FREQ]
    lea r9, [r8 + r14*4]
    xor ecx, ecx
.Ldf_mono_to_stereo:
    mov eax, [r8 + rcx*4]
    mov [r9 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Ldf_mono_to_stereo
    jmp .Ldf_shift_history
.Ldf_stereo_to_mono:
    lea r8, [r13 + DW_FREQ]
    lea r9, [r8 + r14*4]
    mov eax, 0x3f000000
    movd xmm1, eax
    xor ecx, ecx
.Ldf_stereo_mix:
    movss xmm0, dword ptr [r8 + rcx*4]
    addss xmm0, dword ptr [r9 + rcx*4]
    mulss xmm0, xmm1
    movss dword ptr [r8 + rcx*4], xmm0
    inc ecx
    cmp ecx, r14d
    jb .Ldf_stereo_mix
.Ldf_shift_history:
    mov dword ptr [rsp + FD_CHANNEL], 0
.Ldf_shift_channel:
    mov eax, [rsp + FD_CHANNEL]
    imul eax, SD_DECODE_STRIDE
    lea rdi, [r12 + SD_DECODE]
    add rdi, rax
    lea r8, [rdi + r14*4]
    mov ecx, 2048
    sub ecx, r14d
    xor edx, edx
.Ldf_shift_signal:
    mov eax, [r8 + rdx*4]
    mov [rdi + rdx*4], eax
    inc edx
    cmp edx, ecx
    jb .Ldf_shift_signal
    mov eax, [rsp + FD_CHANNEL]
    imul eax, 120
    lea r9, [r13 + DW_OVERLAP]
    lea r9, [r9 + rax*4]
    xor ecx, ecx
.Ldf_overlap_copy_in:
    mov eax, [rdi + rcx*4 + 8192]
    mov [r9 + rcx*4], eax
    inc ecx
    cmp ecx, 120
    jb .Ldf_overlap_copy_in
    inc dword ptr [rsp + FD_CHANNEL]
    mov eax, [rsp + FD_CHANNEL]
    cmp eax, [rsp + FD_CC]
    jb .Ldf_shift_channel
    lea rax, [r13 + DW_FREQ]
    mov [rsp + 32 + OY_FREQ], rax
    lea rax, [r13 + DW_TIME]
    mov [rsp + 32 + OY_OUT], rax
    lea rax, [r13 + DW_OVERLAP]
    mov [rsp + 32 + OY_OVERLAP], rax
    lea rax, [r13 + DW_SYNTH_SCRATCH]
    mov [rsp + 32 + OY_SCRATCH], rax
    mov eax, [rsp + FD_CC]
    mov [rsp + 32 + OY_CHANNELS], eax
    mov eax, [rbx + DF_LM]
    mov [rsp + 32 + OY_LM], eax
    mov eax, [r13 + DW_CONTROLS + OCT_TRANSIENT]
    mov [rsp + 32 + OY_SHORT], eax
    mov dword ptr [rsp + 32 + OY_FREQ_CAP], 1920
    mov dword ptr [rsp + 32 + OY_OUT_CAP], 1920
    mov dword ptr [rsp + 32 + OY_OVERLAP_CAP], 240
    mov dword ptr [rsp + 32 + OY_SCRATCH_CAP], 3000
    lea rcx, [rsp + 32]
    call op_celt_synthesis
    test eax, eax
    jz .Ldf_failed
    # Preserve causal postfilter history in the same sliding decode buffer.
    mov dword ptr [rsp + FD_CHANNEL], 0
    mov eax, 15
    cmp [r12 + SD_PERIOD], eax
    jge .Ldf_period_current
    mov [r12 + SD_PERIOD], eax
.Ldf_period_current:
    cmp [r12 + SD_PERIOD_OLD], eax
    jge .Ldf_period_old
    mov [r12 + SD_PERIOD_OLD], eax
.Ldf_period_old:
    mov eax, 2048
    sub eax, r14d
    mov [rsp + FD_HISTORY], eax
.Ldf_filter_channel:
    mov eax, [rsp + FD_CHANNEL]
    imul eax, SD_DECODE_STRIDE
    lea rdi, [r12 + SD_DECODE]
    add rdi, rax
    mov eax, [rsp + FD_HISTORY]
    lea r8, [rdi + rax*4]
    mov eax, [rsp + FD_CHANNEL]
    imul eax, r14d
    lea r9, [r13 + DW_TIME]
    lea r9, [r9 + rax*4]
    xor ecx, ecx
.Ldf_time_to_history:
    mov eax, [r9 + rcx*4]
    mov [r8 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Ldf_time_to_history
    mov eax, [rsp + FD_CHANNEL]
    imul eax, 120
    lea r9, [r13 + DW_OVERLAP]
    lea r9, [r9 + rax*4]
    xor ecx, ecx
.Ldf_overlap_copy_out:
    mov eax, [r9 + rcx*4]
    mov [rdi + rcx*4 + 8192], eax
    inc ecx
    cmp ecx, 120
    jb .Ldf_overlap_copy_out
    mov [rsp + 32 + OF_BUFFER], rdi
    mov [rsp + 32 + OF_OUT], r8
    mov dword ptr [rsp + 32 + OF_N], 120
    mov eax, [rsp + FD_HISTORY]
    mov [rsp + 32 + OF_HISTORY], eax
    mov eax, [r12 + SD_PERIOD_OLD]
    mov [rsp + 32 + OF_PERIOD0], eax
    mov eax, [r12 + SD_PERIOD]
    mov [rsp + 32 + OF_PERIOD1], eax
    mov eax, [r12 + SD_GAIN_OLD]
    mov [rsp + 32 + OF_GAIN0], eax
    mov eax, [r12 + SD_GAIN]
    mov [rsp + 32 + OF_GAIN1], eax
    mov eax, [r12 + SD_TAP_OLD]
    mov [rsp + 32 + OF_TAP0], eax
    mov eax, [r12 + SD_TAP]
    mov [rsp + 32 + OF_TAP1], eax
    mov dword ptr [rsp + 32 + OF_OVERLAP], 120
    mov dword ptr [rsp + 32 + OF_BUFFER_CAP], 2048
    mov [rsp + 32 + OF_OUT_CAP], r14d
    lea rcx, [rsp + 32]
    call op_celt_comb_filter
    test eax, eax
    jz .Ldf_failed
    cmp dword ptr [rbx + DF_LM], 0
    je .Ldf_filter_next
    add qword ptr [rsp + 32 + OF_OUT], 480
    mov eax, r14d
    sub eax, 120
    mov [rsp + 32 + OF_N], eax
    add dword ptr [rsp + 32 + OF_HISTORY], 120
    mov eax, [r12 + SD_PERIOD]
    mov [rsp + 32 + OF_PERIOD0], eax
    mov eax, [r13 + DW_CONTROLS + OCT_PITCH]
    cmp eax, 15
    jge .Ldf_new_period
    mov eax, 15              # zero-gain absent period still needs safe addresses
.Ldf_new_period:
    mov [rsp + 32 + OF_PERIOD1], eax
    mov eax, [r12 + SD_GAIN]
    mov [rsp + 32 + OF_GAIN0], eax
    mov eax, [r13 + DW_CONTROLS + OCT_GAIN]
    mov [rsp + 32 + OF_GAIN1], eax
    mov eax, [r12 + SD_TAP]
    mov [rsp + 32 + OF_TAP0], eax
    mov eax, [r13 + DW_CONTROLS + OCT_TAPSET]
    mov [rsp + 32 + OF_TAP1], eax
    lea rcx, [rsp + 32]
    call op_celt_comb_filter
    test eax, eax
    jz .Ldf_failed
.Ldf_filter_next:
    inc dword ptr [rsp + FD_CHANNEL]
    mov eax, [rsp + FD_CHANNEL]
    cmp eax, [rsp + FD_CC]
    jb .Ldf_filter_channel
    mov eax, [r12 + SD_PERIOD]
    mov [r12 + SD_PERIOD_OLD], eax
    mov eax, [r12 + SD_GAIN]
    mov [r12 + SD_GAIN_OLD], eax
    mov eax, [r12 + SD_TAP]
    mov [r12 + SD_TAP_OLD], eax
    mov eax, [r13 + DW_CONTROLS + OCT_PITCH]
    mov [r12 + SD_PERIOD], eax
    mov eax, [r13 + DW_CONTROLS + OCT_GAIN]
    mov [r12 + SD_GAIN], eax
    mov eax, [r13 + DW_CONTROLS + OCT_TAPSET]
    mov [r12 + SD_TAP], eax
    cmp dword ptr [rbx + DF_LM], 0
    je .Ldf_energy_histories
    mov eax, [r12 + SD_PERIOD]
    mov [r12 + SD_PERIOD_OLD], eax
    mov eax, [r12 + SD_GAIN]
    mov [r12 + SD_GAIN_OLD], eax
    mov eax, [r12 + SD_TAP]
    mov [r12 + SD_TAP_OLD], eax
.Ldf_energy_histories:
    cmp dword ptr [rsp + FD_C], 1
    jne .Ldf_update_logs
    xor ecx, ecx
.Ldf_energy_mono_copy:
    mov eax, [r12 + rcx*4 + SD_OLD_E]
    mov [r12 + rcx*4 + SD_OLD_E + 84], eax
    inc ecx
    cmp ecx, 21
    jb .Ldf_energy_mono_copy
.Ldf_update_logs:
    xor ecx, ecx
    cmp dword ptr [r13 + DW_CONTROLS + OCT_TRANSIENT], 0
    jne .Ldf_transient_logs
    cvtsi2ss xmm2, r15d
    mulss xmm2, dword ptr [rip + df_background_step]
.Ldf_nontransient_logs:
    mov eax, [r12 + rcx*4 + SD_OLD_LOG]
    mov [r12 + rcx*4 + SD_OLD_LOG2], eax
    movss xmm0, dword ptr [r12 + rcx*4 + SD_OLD_E]
    movss dword ptr [r12 + rcx*4 + SD_OLD_LOG], xmm0
    movss xmm1, dword ptr [r12 + rcx*4 + SD_BACKGROUND]
    addss xmm1, xmm2
    minss xmm1, xmm0
    movss dword ptr [r12 + rcx*4 + SD_BACKGROUND], xmm1
    inc ecx
    cmp ecx, 42
    jb .Ldf_nontransient_logs
    jmp .Ldf_inactive_histories
.Ldf_transient_logs:
    movss xmm0, dword ptr [r12 + rcx*4 + SD_OLD_LOG]
    minss xmm0, dword ptr [r12 + rcx*4 + SD_OLD_E]
    movss dword ptr [r12 + rcx*4 + SD_OLD_LOG], xmm0
    inc ecx
    cmp ecx, 42
    jb .Ldf_transient_logs
.Ldf_inactive_histories:
    xor ecx, ecx
.Ldf_inactive_loop:
    mov eax, ecx
    cmp eax, 21
    jb .Ldf_inactive_index
    sub eax, 21
.Ldf_inactive_index:
    cmp eax, [rbx + DF_START]
    jl .Ldf_inactive_clear
    cmp eax, [rbx + DF_END]
    jl .Ldf_inactive_next
.Ldf_inactive_clear:
    mov dword ptr [r12 + rcx*4 + SD_OLD_E], 0
    mov dword ptr [r12 + rcx*4 + SD_OLD_LOG], 0xc1e00000
    mov dword ptr [r12 + rcx*4 + SD_OLD_LOG2], 0xc1e00000
.Ldf_inactive_next:
    inc ecx
    cmp ecx, 42
    jb .Ldf_inactive_loop
    mov eax, [rsi + 32]
    mov [r12 + SD_RNG], eax
    mov dword ptr [r12 + SD_LOSS], 0
    # Gather filtered decode tails into planar deemphasis input.
    mov dword ptr [rsp + FD_CHANNEL], 0
.Ldf_gather_channel:
    mov eax, [rsp + FD_CHANNEL]
    imul eax, SD_DECODE_STRIDE
    lea r8, [r12 + SD_DECODE]
    add r8, rax
    mov eax, [rsp + FD_HISTORY]
    lea r8, [r8 + rax*4]
    mov eax, [rsp + FD_CHANNEL]
    imul eax, r14d
    lea r9, [r13 + DW_TIME]
    lea r9, [r9 + rax*4]
    xor ecx, ecx
.Ldf_gather_samples:
    mov eax, [r8 + rcx*4]
    mov [r9 + rcx*4], eax
    inc ecx
    cmp ecx, r14d
    jb .Ldf_gather_samples
    inc dword ptr [rsp + FD_CHANNEL]
    mov eax, [rsp + FD_CHANNEL]
    cmp eax, [rsp + FD_CC]
    jb .Ldf_gather_channel
    lea rax, [r13 + DW_TIME]
    mov [rsp + 32 + OE_X], rax
    mov rax, [rbx + DF_PCM]
    mov [rsp + 32 + OE_PCM], rax
    lea rax, [r12 + SD_DEEMPH]
    mov [rsp + 32 + OE_MEM], rax
    mov [rsp + 32 + OE_N], r14d
    mov eax, [rsp + FD_CC]
    mov [rsp + 32 + OE_CHANNELS], eax
    mov eax, [r12 + SD_DOWNSAMPLE]
    mov [rsp + 32 + OE_DOWNSAMPLE], eax
    mov dword ptr [rsp + 32 + OE_X_CAP], 1920
    mov eax, [rbx + DF_PCM_CAP]
    mov [rsp + 32 + OE_PCM_CAP], eax
    mov dword ptr [rsp + 32 + OE_MEM_CAP], 2
    lea rcx, [rsp + 32]
    call op_celt_deemphasis
    test eax, eax
    jz .Ldf_failed
    mov rcx, rsi
    call op_ec_tell
    mov edx, [rbx + DF_LEN]
    shl edx, 3
    cmp eax, edx
    jg .Ldf_failed
    cmp dword ptr [rsi + 48], 0
    jne .Ldf_failed
    mov eax, [rsp + FD_SAMPLES]
    jmp .Ldf_done
.Ldf_lost_frame:
    # Shared public state/capacity checks passed. PLC owns no entropy context.
    cmp dword ptr [r12 + SD_LOSS], 0
    je .Ldf_lost_ready
    cmp dword ptr [r12 + SD_LOSS], 5
    jge .Ldf_lost_ready
    cmp dword ptr [rbx + DF_START], 0
    jne .Ldf_lost_ready
    cmp dword ptr [r12 + SD_LAST_PITCH], 100
    jb .Ldf_invalid
    cmp dword ptr [r12 + SD_LAST_PITCH], 720
    ja .Ldf_invalid
.Ldf_lost_ready:
    mov rcx, rbx
    call op_celt_decode_lost
    test eax, eax
    jz .Ldf_failed
    jmp .Ldf_done
.Ldf_failed:
    mov dword ptr [r12 + SD_ERROR], 1
    mov eax, -1
    jmp .Ldf_done
.Ldf_invalid:
    xor eax, eax
.Ldf_done:
    add rsp, 208
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_celt_decode_frame
