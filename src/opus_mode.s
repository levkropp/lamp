# RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
# Opus mode-frame orchestration adapted from RFC6716 opus_decoder.c.
# Copyright(c)2010-2012 IETF Trust,Xiph.Org Foundation,Skype Limited.
# BSD in THIRD_PARTY_NOTICES. MASM/SSE2; no codec DLL/CRT dependency.
.include "lamp.inc"
.include "opus_mode_layout.inc"
.include "opus_silk_decoder_layout.inc"
.include "opus_decoder_layout.inc"
RODATA
mf_silk_ms: .long 10, 20, 40, 60
mf_celt_end: .long 13, 17, 19, 21
mf_int16_scale: .float 0.000030517578125
mf_one: .float 1.0
.text
FN op_opus_decoder_init
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    test rcx, rcx
    jz .Lmi_bad
    mov rsi, rcx
    mov rbx, [rsi + MI_STATE]
    test rbx, rbx
    jz .Lmi_bad
    cmp dword ptr [rsi + MI_CAP], MO_SIZE
    jb .Lmi_bad
    mov eax, [rsi + MI_CHANNELS]
    dec eax
    cmp eax, 1
    ja .Lmi_bad
    mov eax, [rsi + MI_FS]
    cmp eax, 8000
    je .Lmi_clear
    cmp eax, 12000
    je .Lmi_clear
    cmp eax, 16000
    je .Lmi_clear
    cmp eax, 24000
    je .Lmi_clear
    cmp eax, 48000
    jne .Lmi_bad
.Lmi_clear:
    mov rdi, rbx
    mov ecx, MO_SIZE/8
    xor eax, eax
    rep stosq
    mov eax, [rsi + MI_FS]
    mov [rbx + MO_FS], eax
    mov [rbx + MO_CTRL + KC_API_FS], eax
    xor edx, edx
    mov ecx, 400
    div ecx
    mov [rbx + MO_FRAME], eax
    mov eax, [rsi + MI_CHANNELS]
    mov [rbx + MO_CHANNELS], eax
    mov [rbx + MO_STREAM], eax
    mov [rbx + MO_CTRL + KC_API_CH], eax
    lea rax, [rbx + MO_SILK]
    mov [rsp + 32 + KI_STATE], rax
    mov dword ptr [rsp + 32 + KI_CAP], KD_SIZE
    lea rcx, [rsp + 32]
    call op_silk_decoder_init
    test eax, eax
    jz .Lmi_bad
    lea rcx, [rbx + MO_CELT]
    mov edx, SD_SIZE
    mov r8d, [rbx + MO_CHANNELS]
    mov r9d, [rbx + MO_FS]
    call op_celt_decoder_init
    test eax, eax
    jz .Lmi_bad
    mov dword ptr [rbx + MO_TAG], MO_MAGIC
    mov eax, 1
    jmp .Lmi_done
.Lmi_bad:
    xor eax, eax
.Lmi_done:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_opus_decoder_init
# Private fade: RCX=in1,RDX=in2,R8=out,R9=mode state. Aliasing
# output with either input is supported; window stride follows API rate.
LOCALFN mf_fade
    push rbx
    push rsi
    mov rsi, r9
    mov r9, rcx
    mov eax, 48000
    xor edx, edx
    div dword ptr [rsi + MO_FS]
    mov ebx, eax
    # RDX input2 was overwritten by division, saved by caller in R10.
    mov rdx, r10
    mov eax, [rsi + MO_FS]
    xor ecx, ecx
    mov ecx, 400
    xor r11d, r11d
    xor edx, edx
    div ecx
    mov rdx, r10
    mov r11d, eax
    xor ecx, ecx
    lea r10, [rip + op_celt_window]
.Lmf_fade_sample:
    mov eax, ecx
    imul eax, ebx
    movss xmm0, dword ptr [r10 + rax*4]
    mulss xmm0, xmm0
    movss xmm1, [rip + mf_one]
    subss xmm1, xmm0
    mov eax, ecx
    imul eax, dword ptr [rsi + MO_CHANNELS]
    movss xmm2, dword ptr [rdx + rax*4]
    mulss xmm2, xmm0
    movss xmm3, dword ptr [r9 + rax*4]
    mulss xmm3, xmm1
    addss xmm2, xmm3
    movss dword ptr [r8 + rax*4], xmm2
    cmp dword ptr [rsi + MO_CHANNELS], 2
    jne .Lmf_fade_next
    movss xmm2, dword ptr [rdx + rax*4 + 4]
    mulss xmm2, xmm0
    movss xmm3, dword ptr [r9 + rax*4 + 4]
    mulss xmm3, xmm1
    addss xmm2, xmm3
    movss dword ptr [r8 + rax*4 + 4], xmm2
.Lmf_fade_next:
    inc ecx
    cmp ecx, r11d
    jb .Lmf_fade_sample
    pop rsi
    pop rbx
    ret
ENDFN mf_fade
# Stack locals (outgoing request32..103, nested request112..175).
.equ ML_DEPTH, 192
.equ ML_MODE, 196
.equ ML_N, 200
.equ ML_F2, 204
.equ ML_F5, 208
.equ ML_F10, 212
.equ ML_F20, 216
.equ ML_TRANS, 220
.equ ML_RED, 224
.equ ML_DIR, 228
.equ ML_BYTES, 232
.equ ML_LEN, 236
.equ ML_START, 240
.equ ML_RED_RNG, 244
.equ ML_DONE, 248
.equ ML_NEW, 252
.equ ML_LM, 256
.equ ML_CFG_FRAME, 260
.equ ML_CFG_MODE, 264
.equ ML_CFG_END, 268
.equ ML_CFG_FS, 272
.equ ML_LIMIT, 276
.equ ML_SUPER, 292              #preserved API/internal channel metadata
FN op_opus_decode_frame
    xor edx, edx
    jmp mf_core
ENDFN op_opus_decode_frame
LOCALFN mf_core
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 320
    mov [rsp + ML_DEPTH], edx
    mov rbx, rcx
    test rbx, rbx
    jz .Lmf_bad
    mov r12, [rbx + MF_STATE]
    mov r13, [rbx + MF_WORK]
    mov r14, [rbx + MF_PCM]
    mov r15, [rbx + MF_DATA]
    test r12, r12
    jz .Lmf_bad
    test r13, r13
    jz .Lmf_bad
    test r14, r14
    jz .Lmf_bad
    cmp dword ptr [rbx + MF_STATE_CAP], MO_SIZE
    jb .Lmf_bad
    mov eax, MW_SIZE
    cmp dword ptr [rsp + ML_DEPTH], 0
    je .Lmf_work_guard
    mov eax, MW_LOCAL
.Lmf_work_guard:
    cmp [rbx + MF_WORK_CAP], eax
    jb .Lmf_bad
    cmp dword ptr [r12 + MO_TAG], MO_MAGIC
    jne .Lmf_bad
    cmp dword ptr [r12 + MO_ERROR], 0
    jne .Lmf_bad
    cmp dword ptr [rbx + MF_LEN], 1275
    ja .Lmf_bad
    test r15, r15
    jnz .Lmf_length_valid
    cmp dword ptr [rbx + MF_LEN], 0
    jne .Lmf_bad
.Lmf_length_valid:
    cmp dword ptr [rbx + MF_FEC], 1
    ja .Lmf_bad
    cmp dword ptr [rbx + MF_CONFIG], 31
    ja .Lmf_bad
    mov eax, [rbx + MF_STREAM]
    dec eax
    cmp eax, 1
    ja .Lmf_bad
    mov eax, [r12 + MO_CHANNELS]
    dec eax
    cmp eax, 1
    ja .Lmf_bad
    cmp dword ptr [r12 + MO_PREV], 3
    ja .Lmf_bad
    cmp dword ptr [r12 + MO_RED], 1
    ja .Lmf_bad
    mov eax, [r12 + MO_FS]
    cmp eax, 8000
    je .Lmf_valid_rate
    cmp eax, 12000
    je .Lmf_valid_rate
    cmp eax, 16000
    je .Lmf_valid_rate
    cmp eax, 24000
    je .Lmf_valid_rate
    cmp eax, 48000
    jne .Lmf_bad
.Lmf_valid_rate:
    xor edx, edx
    mov ecx, 400
    div ecx
    mov [rsp + ML_F2], eax
    shl eax, 1
    mov [rsp + ML_F5], eax
    shl eax, 1
    mov [rsp + ML_F10], eax
    shl eax, 1
    mov [rsp + ML_F20], eax
    mov eax, [r12 + MO_FRAME]
    cmp eax, [rsp + ML_F2]
    je .Lmf_state_frame_valid
    cmp eax, [rsp + ML_F5]
    je .Lmf_state_frame_valid
    cmp eax, [rsp + ML_F10]
    je .Lmf_state_frame_valid
    cmp eax, [rsp + ML_F20]
    je .Lmf_state_frame_valid
    mov ecx, [rsp + ML_F20]
    imul ecx, 2
    cmp eax, ecx
    je .Lmf_state_frame_valid
    add ecx, [rsp + ML_F20]
    cmp eax, ecx
    jne .Lmf_bad
.Lmf_state_frame_valid:
    cmp dword ptr [r12 + MO_MODE], 3
    ja .Lmf_bad
    mov eax, [r12 + MO_STREAM]
    dec eax
    cmp eax, 1
    ja .Lmf_bad
    mov eax, [r12 + MO_CHANNELS]
    cmp eax, [r12 + MO_CTRL + KC_API_CH]
    jne .Lmf_bad
    cmp eax, [r12 + MO_CELT + SD_CHANNELS]
    jne .Lmf_bad
    mov eax, [r12 + MO_FS]
    cmp eax, [r12 + MO_CTRL + KC_API_FS]
    jne .Lmf_bad
    mov eax, 48000
    xor edx, edx
    div dword ptr [r12 + MO_FS]
    cmp eax, [r12 + MO_CELT + SD_DOWNSAMPLE]
    jne .Lmf_bad
    lea rsi, [r13 + MW_EC]
    mov dword ptr [rsp + ML_TRANS], 0
    mov dword ptr [rsp + ML_RED], 0
    mov dword ptr [rsp + ML_BYTES], 0
    mov dword ptr [rsp + ML_DIR], 0
    mov dword ptr [rsp + ML_RED_RNG], 0
    mov eax, [rbx + MF_LEN]
    mov [rsp + ML_LEN], eax
    # Compute TOC configuration without modifying state during validation.
    mov eax, [r12 + MO_FRAME]
    mov [rsp + ML_CFG_FRAME], eax
    mov eax, [r12 + MO_MODE]
    mov [rsp + ML_CFG_MODE], eax
    mov eax, [r12 + MO_END]
    mov [rsp + ML_CFG_END], eax
    test r15, r15
    jz .Lmf_limit
    mov eax, [rbx + MF_CONFIG]
    cmp eax, 12
    jb .Lmf_config_silk
    cmp eax, 16
    jb .Lmf_config_hybrid
    mov dword ptr [rsp + ML_CFG_MODE], 3
    mov ecx, eax
    and ecx, 3
    mov eax, [rsp + ML_F2]
    shl eax, cl
    mov [rsp + ML_CFG_FRAME], eax
    mov eax, [rbx + MF_CONFIG]
    shr eax, 2
    sub eax, 4
    lea rcx, [rip + mf_celt_end]
    mov eax, [rcx + rax*4]
    mov [rsp + ML_CFG_END], eax
    jmp .Lmf_limit
.Lmf_config_hybrid:
    mov dword ptr [rsp + ML_CFG_MODE], 2
    mov dword ptr [rsp + ML_CFG_FS], 16000
    mov dword ptr [rsp + ML_CFG_END], 19
    test eax, 2
    jz .Lmf_config_hybrid_size
    mov dword ptr [rsp + ML_CFG_END], 21
.Lmf_config_hybrid_size:
    and eax, 1
    mov ecx, eax
    mov eax, [rsp + ML_F10]
    shl eax, cl
    mov [rsp + ML_CFG_FRAME], eax
    jmp .Lmf_limit
.Lmf_config_silk:
    mov dword ptr [rsp + ML_CFG_MODE], 1
    shr eax, 2
    imul eax, 4000
    add eax, 8000
    mov [rsp + ML_CFG_FS], eax
    mov ecx, [rbx + MF_CONFIG]
    and ecx, 3
    lea rax, [rip + mf_silk_ms]
    mov eax, [rax + rcx*4]
    imul eax, [r12 + MO_FS]
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [rsp + ML_CFG_FRAME], eax
    mov dword ptr [rsp + ML_CFG_END], 17
    cmp dword ptr [rsp + ML_CFG_FS], 8000
    jne .Lmf_limit
    mov dword ptr [rsp + ML_CFG_END], 13
.Lmf_limit:
    mov eax, [rbx + MF_COUNT]
    test eax, eax
    jnz .Lmf_requested_limit
    mov eax, [rsp + ML_CFG_FRAME]
.Lmf_requested_limit:
    cmp eax, [rsp + ML_F2]
    jb .Lmf_bad
    mov ecx, [rsp + ML_F20]
    imul ecx, 6
    cmp eax, ecx
    ja .Lmf_bad
    mov [rsp + ML_LIMIT], eax
    # Long PLC must use whole20ms blocks to keep its output within capacity.
    test r15, r15
    jz .Lmf_select_loss
    cmp dword ptr [rbx + MF_LEN], 1
    jbe .Lmf_select_loss
    cmp eax, [rsp + ML_CFG_FRAME]
    jb .Lmf_bad
    mov eax, [rsp + ML_CFG_FRAME]
    mov [rsp + ML_N], eax
    mov eax, [rsp + ML_CFG_MODE]
    mov [rsp + ML_MODE], eax
    jmp .Lmf_output_guard
.Lmf_select_loss:
    cmp dword ptr [rbx + MF_LEN], 1
    ja .Lmf_loss_limit_ready
    cmp eax, [rsp + ML_CFG_FRAME]
    jbe .Lmf_loss_limit_ready
    mov eax, [rsp + ML_CFG_FRAME]
.Lmf_loss_limit_ready:
    mov [rsp + ML_N], eax
    mov eax, [r12 + MO_PREV]
    mov [rsp + ML_MODE], eax
    test eax, eax
    jz .Lmf_output_guard
    cmp eax, 1
    je .Lmf_silk_loss_length
    mov eax, [rsp + ML_N]
    cmp eax, [rsp + ML_F20]
    ja .Lmf_long_loss_length
    cmp eax, [rsp + ML_F20]
    je .Lmf_output_guard
    cmp eax, [rsp + ML_F10]
    je .Lmf_output_guard
    cmp eax, [rsp + ML_F5]
    je .Lmf_output_guard
    cmp eax, [rsp + ML_F2]
    jne .Lmf_bad
    jmp .Lmf_output_guard
.Lmf_long_loss_length:
    xor edx, edx
    div dword ptr [rsp + ML_F20]
    test edx, edx
    jnz .Lmf_bad
    jmp .Lmf_output_guard
.Lmf_silk_loss_length:
    mov eax, [rsp + ML_N]
    cmp eax, [rsp + ML_F20]
    jbe .Lmf_output_guard
    mov ecx, [rsp + ML_F20]
    imul ecx, 2
    cmp eax, ecx
    je .Lmf_output_guard
    add ecx, [rsp + ML_F20]
    cmp eax, ecx
    jne .Lmf_bad
.Lmf_output_guard:
    mov eax, [rsp + ML_N]
    imul eax, [r12 + MO_CHANNELS]
    cmp [rbx + MF_PCM_CAP], eax
    jb .Lmf_bad
    test r15, r15
    jz .Lmf_payload_ready
    mov eax, [rsp + ML_CFG_MODE]
    mov [r12 + MO_MODE], eax
    mov eax, [rsp + ML_CFG_FRAME]
    mov [r12 + MO_FRAME], eax
    mov eax, [rsp + ML_CFG_END]
    mov [r12 + MO_END], eax
    mov eax, [rbx + MF_STREAM]
    mov [r12 + MO_STREAM], eax
.Lmf_payload_ready:
    cmp dword ptr [rbx + MF_LEN], 1
    ja .Lmf_data_ready
    xor r15d, r15d
.Lmf_data_ready:
    test r15, r15
    jz .Lmf_lost_ready
    mov rcx, rsi
    mov rdx, r15
    mov r8d, [rbx + MF_LEN]
    call op_ec_init
    jmp .Lmf_transition_check
.Lmf_lost_ready:
    cmp dword ptr [r12 + MO_PREV], 0
    jne .Lmf_long_loss
    mov rdi, r14
    mov ecx, [rsp + ML_N]
    imul ecx, [r12 + MO_CHANNELS]
    xor eax, eax
    rep stosd
    jmp .Lmf_success
.Lmf_long_loss:
    cmp dword ptr [rsp + ML_MODE], 1
    je .Lmf_transition_check
    mov eax, [rsp + ML_N]
    cmp eax, [rsp + ML_F20]
    jbe .Lmf_transition_check
    mov dword ptr [rsp + ML_DONE], 0
.Lmf_long_loss_loop:
    mov eax, [rsp + ML_DONE]
    imul eax, [r12 + MO_CHANNELS]
    lea rdx, [r14 + rax*4]
    mov ecx, [rsp + ML_F20]
    call mf_child_request
    cmp eax, [rsp + ML_F20]
    jne .Lmf_failed
    add [rsp + ML_DONE], eax
    mov eax, [rsp + ML_DONE]
    cmp eax, [rsp + ML_N]
    jb .Lmf_long_loss_loop
    jmp .Lmf_success
.Lmf_transition_check:
    test r15, r15
    jz .Lmf_silk
    mov eax, [r12 + MO_PREV]
    test eax, eax
    jz .Lmf_silk
    cmp dword ptr [rsp + ML_MODE], 3
    jne .Lmf_transition_from_celt
    cmp eax, 3
    je .Lmf_silk
    cmp dword ptr [r12 + MO_RED], 0
    jne .Lmf_silk
    mov dword ptr [rsp + ML_TRANS], 1
    mov ecx, [rsp + ML_F5]
    cmp ecx, [rsp + ML_N]
    jbe .Lmf_transition_celt_count
    mov ecx, [rsp + ML_N]
.Lmf_transition_celt_count:
    lea rdx, [r13 + MW_TRANS]
    call mf_child_request
    test eax, eax
    jle .Lmf_failed
    jmp .Lmf_silk
.Lmf_transition_from_celt:
    cmp eax, 3
    jne .Lmf_silk
    mov dword ptr [rsp + ML_TRANS], 1
.Lmf_silk:
    cmp dword ptr [rsp + ML_MODE], 3
    je .Lmf_redundancy
    cmp dword ptr [r12 + MO_PREV], 3
    jne .Lmf_silk_control
    # RFC8251 reset clears stereo history and the previous middle-only flag.
    # The native initializer retains only API/internal channel metadata.
    mov eax, [r12 + MO_SILK + KD_API_CH]
    mov [rsp + ML_SUPER], eax
    mov eax, [r12 + MO_SILK + KD_INT_CH]
    mov [rsp + ML_SUPER + 4], eax
    lea rax, [r12 + MO_SILK]
    mov [rsp + 32 + KI_STATE], rax
    mov dword ptr [rsp + 32 + KI_CAP], KD_SIZE
    lea rcx, [rsp + 32]
    call op_silk_decoder_init
    test eax, eax
    jz .Lmf_failed
    mov eax, [rsp + ML_SUPER]
    mov [r12 + MO_SILK + KD_API_CH], eax
    mov eax, [rsp + ML_SUPER + 4]
    mov [r12 + MO_SILK + KD_INT_CH], eax
.Lmf_silk_control:
    mov eax, [rsp + ML_N]
    imul eax, 1000
    xor edx, edx
    div dword ptr [r12 + MO_FS]
    cmp eax, 10
    jae .Lmf_silk_duration
    mov eax, 10
.Lmf_silk_duration:
    mov [r12 + MO_CTRL + KC_MS], eax
    test r15, r15
    jz .Lmf_silk_frames
    mov eax, [r12 + MO_STREAM]
    mov [r12 + MO_CTRL + KC_INT_CH], eax
    mov eax, [rsp + ML_CFG_FS]
    mov [r12 + MO_CTRL + KC_INT_FS], eax
.Lmf_silk_frames:
    mov dword ptr [rsp + ML_DONE], 0
    mov dword ptr [rsp + ML_NEW], 1
.Lmf_silk_loop:
    lea rax, [r12 + MO_SILK]
    mov [rsp + 32 + KK_STATE], rax
    mov [rsp + 32 + KK_EC], rsi
    mov eax, [rsp + ML_DONE]
    imul eax, [r12 + MO_CHANNELS]
    lea rax, [r13 + rax*2 + MW_SILK]
    mov [rsp + 32 + KK_PCM], rax
    lea rax, [r13 + MW_CODEC]
    mov [rsp + 32 + KK_WORK], rax
    lea rax, [r12 + MO_CTRL]
    mov [rsp + 32 + KK_CTRL], rax
    mov eax, [rbx + MF_FEC]
    shl eax, 1
    test r15, r15
    jnz .Lmf_silk_mode
    mov eax, 1
.Lmf_silk_mode:
    mov [rsp + 32 + KK_MODE], eax
    mov eax, [rsp + ML_NEW]
    mov [rsp + 32 + KK_NEW], eax
    mov dword ptr [rsp + 32 + KK_STATE_CAP], KD_SIZE
    mov dword ptr [rsp + 32 + KK_EC_CAP], 64
    mov dword ptr [rsp + 32 + KK_PCM_CAP], 5760
    mov dword ptr [rsp + 32 + KK_WORK_CAP], KW_SIZE
    mov dword ptr [rsp + 32 + KK_CTRL_CAP], 24
    lea rcx, [rsp + 32]
    call op_silk_decode
    test eax, eax
    jz .Lmf_failed
    add [rsp + ML_DONE], eax
    mov dword ptr [rsp + ML_NEW], 0
    mov eax, [rsp + ML_DONE]
    cmp eax, [rsp + ML_N]
    jb .Lmf_silk_loop
.Lmf_redundancy:
    mov dword ptr [rsp + ML_START], 0
    cmp dword ptr [rsp + ML_MODE], 3
    je .Lmf_after_redundancy
    mov dword ptr [rsp + ML_START], 17
    test r15, r15
    jz .Lmf_after_redundancy
    cmp dword ptr [rbx + MF_FEC], 0
    jne .Lmf_after_redundancy
    mov rcx, rsi
    call op_ec_tell
    add eax, 17
    cmp dword ptr [r12 + MO_MODE], 2
    jne .Lmf_redundancy_budget
    add eax, 20
.Lmf_redundancy_budget:
    mov ecx, [rsp + ML_LEN]
    shl ecx, 3
    cmp eax, ecx
    ja .Lmf_after_redundancy
    mov eax, 1
    cmp dword ptr [rsp + ML_MODE], 2
    jne .Lmf_redundancy_flag
    mov rcx, rsi
    mov edx, 12
    call op_ec_logp
.Lmf_redundancy_flag:
    mov [rsp + ML_RED], eax
    test eax, eax
    jz .Lmf_after_redundancy
    mov rcx, rsi
    mov edx, 1
    call op_ec_logp
    mov [rsp + ML_DIR], eax
    cmp dword ptr [rsp + ML_MODE], 2
    jne .Lmf_silk_redundancy_bytes
    mov rcx, rsi
    mov edx, 256
    call op_ec_uint
    add eax, 2
    jmp .Lmf_redundancy_bytes
.Lmf_silk_redundancy_bytes:
    mov rcx, rsi
    call op_ec_tell
    add eax, 7
    shr eax, 3
    mov ecx, [rsp + ML_LEN]
    sub ecx, eax
    mov eax, ecx
.Lmf_redundancy_bytes:
    mov [rsp + ML_BYTES], eax
    sub [rsp + ML_LEN], eax
    mov rcx, rsi
    call op_ec_tell
    mov ecx, [rsp + ML_LEN]
    shl ecx, 3
    cmp ecx, eax
    jge .Lmf_shrink_entropy
    mov dword ptr [rsp + ML_LEN], 0
    mov dword ptr [rsp + ML_BYTES], 0
    mov dword ptr [rsp + ML_RED], 0
.Lmf_shrink_entropy:
    mov eax, [rsp + ML_BYTES]
    sub [rsi + 8], eax
.Lmf_after_redundancy:
    cmp dword ptr [rsp + ML_RED], 0
    je .Lmf_transition_late
    mov dword ptr [rsp + ML_TRANS], 0
.Lmf_transition_late:
    cmp dword ptr [rsp + ML_TRANS], 0
    je .Lmf_redundant_first
    cmp dword ptr [rsp + ML_MODE], 3
    je .Lmf_redundant_first
    mov ecx, [rsp + ML_F5]
    cmp ecx, [rsp + ML_N]
    jbe .Lmf_transition_silk_count
    mov ecx, [rsp + ML_N]
.Lmf_transition_silk_count:
    lea rdx, [r13 + MW_TRANS]
    call mf_child_request
    test eax, eax
    jle .Lmf_failed
.Lmf_redundant_first:
    cmp dword ptr [rsp + ML_RED], 0
    je .Lmf_celt
    cmp dword ptr [rsp + ML_DIR], 0
    je .Lmf_celt
    call mf_redundant_decode
    test eax, eax
    jle .Lmf_failed
.Lmf_celt:
    cmp dword ptr [rsp + ML_MODE], 1
    je .Lmf_silk_only_pcm
    mov eax, [rsp + ML_MODE]
    cmp eax, [r12 + MO_PREV]
    je .Lmf_celt_request
    cmp dword ptr [r12 + MO_PREV], 0
    je .Lmf_celt_request
    cmp dword ptr [r12 + MO_RED], 0
    jne .Lmf_celt_request
    call mf_celt_reset
    test eax, eax
    jz .Lmf_failed
.Lmf_celt_request:
    lea rax, [r12 + MO_CELT]
    mov [rsp + 32 + DF_STATE], rax
    mov [rsp + 32 + DF_DATA], r15
    cmp dword ptr [rbx + MF_FEC], 0
    je .Lmf_celt_data
    mov qword ptr [rsp + 32 + DF_DATA], 0
.Lmf_celt_data:
    mov [rsp + 32 + DF_PCM], r14
    mov [rsp + 32 + DF_EC], rsi
    lea rax, [r13 + MW_CODEC]
    mov [rsp + 32 + DF_WORK], rax
    mov eax, [rsp + ML_LEN]
    mov [rsp + 32 + DF_LEN], eax
    mov eax, [r12 + MO_STREAM]
    mov [rsp + 32 + DF_CHANNELS], eax
    mov eax, [rsp + ML_N]
    cmp eax, [rsp + ML_F20]
    jbe .Lmf_celt_size
    mov eax, [rsp + ML_F20]
.Lmf_celt_size:
    call mf_size_lm
    mov [rsp + 32 + DF_LM], eax
    mov eax, [rsp + ML_START]
    mov [rsp + 32 + DF_START], eax
    mov eax, [r12 + MO_END]
    mov [rsp + 32 + DF_END], eax
    mov dword ptr [rsp + 32 + DF_PCM_CAP], 11520
    mov dword ptr [rsp + 32 + DF_WORK_CAP], DW_SIZE
    mov dword ptr [rsp + 32 + DF_STATE_CAP], SD_SIZE
    lea rcx, [rsp + 32]
    call op_celt_decode_frame
    test eax, eax
    jle .Lmf_failed
    jmp .Lmf_add_silk
.Lmf_silk_only_pcm:
    mov rdi, r14
    mov ecx, [rsp + ML_N]
    imul ecx, [r12 + MO_CHANNELS]
    xor eax, eax
    rep stosd
    cmp dword ptr [r12 + MO_PREV], 2
    jne .Lmf_add_silk
    cmp dword ptr [rsp + ML_RED], 0
    je .Lmf_silk_fade_out
    cmp dword ptr [rsp + ML_DIR], 0
    je .Lmf_silk_fade_out
    cmp dword ptr [r12 + MO_RED], 0
    jne .Lmf_add_silk
.Lmf_silk_fade_out:
    lea rax, [r12 + MO_CELT]
    mov [rsp + 32 + DF_STATE], rax
    mov word ptr [rsp + 304], 0xffff
    lea rax, [rsp + 304]
    mov [rsp + 32 + DF_DATA], rax
    mov [rsp + 32 + DF_PCM], r14
    mov qword ptr [rsp + 32 + DF_EC], 0
    lea rax, [r13 + MW_CODEC]
    mov [rsp + 32 + DF_WORK], rax
    mov dword ptr [rsp + 32 + DF_LEN], 2
    mov eax, [r12 + MO_STREAM]
    mov [rsp + 32 + DF_CHANNELS], eax
    mov dword ptr [rsp + 32 + DF_LM], 0
    mov dword ptr [rsp + 32 + DF_START], 0
    mov eax, [r12 + MO_END]
    mov [rsp + 32 + DF_END], eax
    mov dword ptr [rsp + 32 + DF_PCM_CAP], 11520
    mov dword ptr [rsp + 32 + DF_WORK_CAP], DW_SIZE
    mov dword ptr [rsp + 32 + DF_STATE_CAP], SD_SIZE
    lea rcx, [rsp + 32]
    call op_celt_decode_frame
    test eax, eax
    jle .Lmf_failed
.Lmf_add_silk:
    cmp dword ptr [rsp + ML_MODE], 3
    je .Lmf_redundant_last
    mov ecx, [rsp + ML_N]
    imul ecx, [r12 + MO_CHANNELS]
    xor edx, edx
.Lmf_add_sample:
    movsx eax, word ptr [r13 + rdx*2 + MW_SILK]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip + mf_int16_scale]
    addss xmm0, dword ptr [r14 + rdx*4]
    movss dword ptr [r14 + rdx*4], xmm0
    inc edx
    cmp edx, ecx
    jb .Lmf_add_sample
.Lmf_redundant_last:
    cmp dword ptr [rsp + ML_RED], 0
    je .Lmf_transition_output
    cmp dword ptr [rsp + ML_DIR], 0
    jne .Lmf_redundant_first_output
    call mf_celt_reset
    test eax, eax
    jz .Lmf_failed
    call mf_redundant_decode
    test eax, eax
    jle .Lmf_failed
    mov eax, [rsp + ML_N]
    sub eax, [rsp + ML_F2]
    imul eax, [r12 + MO_CHANNELS]
    lea rcx, [r14 + rax*4]
    mov eax, [rsp + ML_F2]
    imul eax, [r12 + MO_CHANNELS]
    lea rdx, [r13 + rax*4 + MW_RED]
    mov r8, rcx
    mov r9, r12
    mov r10, rdx
    call mf_fade
    jmp .Lmf_transition_output
.Lmf_redundant_first_output:
    mov ecx, [rsp + ML_F2]
    imul ecx, [r12 + MO_CHANNELS]
    lea rax, [r13 + MW_RED]
    xor edx, edx
.Lmf_copy_redundant:
    mov r8d, [rax + rdx*4]
    mov [r14 + rdx*4], r8d
    inc edx
    cmp edx, ecx
    jb .Lmf_copy_redundant
    lea rcx, [rax + rdx*4]
    lea rdx, [r14 + rdx*4]
    mov r8, rdx
    mov r9, r12
    mov r10, rdx
    call mf_fade
.Lmf_transition_output:
    cmp dword ptr [rsp + ML_TRANS], 0
    je .Lmf_finish
    mov eax, [rsp + ML_N]
    cmp eax, [rsp + ML_F5]
    jb .Lmf_transition_short
    mov ecx, [rsp + ML_F2]
    imul ecx, [r12 + MO_CHANNELS]
    lea rax, [r13 + MW_TRANS]
    xor edx, edx
.Lmf_copy_transition:
    mov r8d, [rax + rdx*4]
    mov [r14 + rdx*4], r8d
    inc edx
    cmp edx, ecx
    jb .Lmf_copy_transition
    lea rcx, [rax + rdx*4]
    lea rdx, [r14 + rdx*4]
    jmp .Lmf_transition_fade
.Lmf_transition_short:
    lea rcx, [r13 + MW_TRANS]
    mov rdx, r14
.Lmf_transition_fade:
    mov r8, rdx
    mov r9, r12
    mov r10, rdx
    call mf_fade
.Lmf_finish:
    xor eax, eax
    cmp dword ptr [rsp + ML_LEN], 1
    jbe .Lmf_final_range
    mov eax, [rsi + 32]
    xor eax, [rsp + ML_RED_RNG]
.Lmf_final_range:
    mov [r12 + MO_RANGE], eax
    mov eax, [rsp + ML_MODE]
    mov [r12 + MO_PREV], eax
    mov eax, [rsp + ML_DIR]
    xor eax, 1
    and eax, [rsp + ML_RED]
    mov [r12 + MO_RED], eax
.Lmf_success:
    mov eax, [rsp + ML_N]
    jmp .Lmf_done
.Lmf_failed:
    mov dword ptr [r12 + MO_ERROR], 1
    mov eax, -1
    jmp .Lmf_done
.Lmf_bad:
    xor eax, eax
.Lmf_done:
    add rsp, 320
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mf_core
# Private helpers use R11=parent RSP captured at entry below. Calls align.
LOCALFN mf_size_lm
    xor ecx, ecx
    mov edx, [rsp + 8 + ML_F2]
.Lmf_size_lm_loop:
    cmp eax, edx
    jbe .Lmf_size_lm_done
    shl edx, 1
    inc ecx
    jmp .Lmf_size_lm_loop
.Lmf_size_lm_done:
    mov eax, ecx
    ret
ENDFN mf_size_lm
LOCALFN mf_celt_reset
    sub rsp, 40
    lea rcx, [r12 + MO_CELT]
    mov edx, SD_SIZE
    mov r8d, [r12 + MO_CHANNELS]
    mov r9d, [r12 + MO_FS]
    call op_celt_decoder_init
    add rsp, 40
    ret
ENDFN mf_celt_reset
LOCALFN mf_child_request
    lea r11, [rsp + 8]
    movdqu xmm0, [rbx]
    movdqu xmm1, [rbx + 16]
    movdqu xmm2, [rbx + 32]
    movdqu xmm3, [rbx + 48]
    movdqu [r11 + 112], xmm0
    movdqu [r11 + 128], xmm1
    movdqu [r11 + 144], xmm2
    movdqu [r11 + 160], xmm3
    mov qword ptr [r11 + 112 + MF_DATA], 0
    mov [r11 + 112 + MF_PCM], rdx
    lea rax, [r13 + MW_CHILD]
    mov [r11 + 112 + MF_WORK], rax
    mov dword ptr [r11 + 112 + MF_LEN], 0
    mov [r11 + 112 + MF_COUNT], ecx
    mov dword ptr [r11 + 112 + MF_FEC], 0
    mov dword ptr [r11 + 112 + MF_WORK_CAP], MW_LOCAL
    mov dword ptr [r11 + 112 + MF_PCM_CAP], 11520
    lea rcx, [r11 + 112]
    mov edx, 1
    sub rsp, 40
    call mf_core
    add rsp, 40
    ret
ENDFN mf_child_request
LOCALFN mf_redundant_decode
    lea r11, [rsp + 8]
    lea rax, [r12 + MO_CELT]
    mov [r11 + 32 + DF_STATE], rax
    mov eax, [r11 + ML_LEN]
    lea rax, [r15 + rax]
    mov [r11 + 32 + DF_DATA], rax
    lea rax, [r13 + MW_RED]
    mov [r11 + 32 + DF_PCM], rax
    mov qword ptr [r11 + 32 + DF_EC], 0
    lea rax, [r13 + MW_CODEC]
    mov [r11 + 32 + DF_WORK], rax
    mov eax, [r11 + ML_BYTES]
    mov [r11 + 32 + DF_LEN], eax
    mov eax, [r12 + MO_STREAM]
    mov [r11 + 32 + DF_CHANNELS], eax
    mov dword ptr [r11 + 32 + DF_LM], 1
    mov dword ptr [r11 + 32 + DF_START], 0
    mov eax, [r12 + MO_END]
    mov [r11 + 32 + DF_END], eax
    mov dword ptr [r11 + 32 + DF_PCM_CAP], 480
    mov dword ptr [r11 + 32 + DF_WORK_CAP], DW_SIZE
    mov dword ptr [r11 + 32 + DF_STATE_CAP], SD_SIZE
    lea rcx, [r11 + 32]
    sub rsp, 40
    call op_celt_decode_frame
    add rsp, 40
    mov edx, [r12 + MO_CELT + SD_RNG]
    mov [rsp + 8 + ML_RED_RNG], edx
    ret
ENDFN mf_redundant_decode
