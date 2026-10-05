# Stateful SILK packet-to-API PCM, RFC6716 dec_API.c. Copyright(c)
# 2006-2012 IETF Trust/Skype Limited. BSD in THIRD_PARTY_NOTICES.
# Native-rate change/reset, FEC/loss, stereo/mid-only and decoder resampling.
.include "lamp.inc"
.include "opus_silk_decoder_layout.inc"
.include "opus_silk_frame_layout.inc"
.include "opus_silk_packet_layout.inc"
.include "opus_silk_stereo_layout.inc"
.include "opus_silk_resampler_layout.inc"
.include "opus_silk_synthesis_layout.inc"
.include "opus_silk_state_layout.inc"
.include "opus_silk_plc_layout.inc"
.include "opus_silk_cng_layout.inc"
.text
# Private zeroed native channel initialization. RCX=3908-byte state.
# Caller cleared all bytes; no rate selected yet,matching silk_init_decoder.
LOCALFN kd_channel_init
    mov dword ptr [rcx + FN_CORE + CS_GAIN], 65536
    mov dword ptr [rcx + FN_PARAM + DS_FIRST], 1
    mov dword ptr [rcx + FN_CNG + CN_RNG], 3176576
    mov dword ptr [rcx + FN_PLC + PN_GAINS], 65536
    mov dword ptr [rcx + FN_PLC + PN_GAINS + 4], 65536
    mov dword ptr [rcx + FN_PLC + PN_SUBLEN], 20
    mov dword ptr [rcx + FN_PLC + PN_SUBFR], 2
    mov dword ptr [rcx + FN_TAG], FN_TAG_VALUE
    ret
ENDFN kd_channel_init
FN op_silk_decoder_init
    push rbx
    push rdi
    sub rsp, 40
    test rcx, rcx
    jz .Lki_bad
    mov rbx, [rcx + KI_STATE]
    test rbx, rbx
    jz .Lki_bad
    cmp dword ptr [rcx + KI_CAP], KD_SIZE
    jb .Lki_bad
    mov rdi, rbx
    mov ecx, KD_SIZE/4
    xor eax, eax
    rep stosd
    lea rcx, [rbx + KD_CHANNEL0]
    call kd_channel_init
    lea rcx, [rbx + KD_CHANNEL1]
    call kd_channel_init
    mov dword ptr [rbx + KD_TAG], KD_TAG_VALUE
    mov eax, 1
    jmp .Lki_done
.Lki_bad:
    xor eax, eax
.Lki_done:
    add rsp, 40
    pop rdi
    pop rbx
    ret
ENDFN op_silk_decoder_init
# Return API sample count per channel,0 failure. Invalid request/config
# rejects before writes; later component failures mark sticky state.
FN op_silk_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 224
    mov rbx, rcx
    test rbx, rbx
    jz .Lkk_bad
    mov rsi, [rbx + KK_STATE]
    mov r12, [rbx + KK_CTRL]
    mov r13, [rbx + KK_WORK]
    mov r14, [rbx + KK_PCM]
    mov r15, [rbx + KK_EC]
    test rsi, rsi
    jz .Lkk_bad
    test r12, r12
    jz .Lkk_bad
    test r13, r13
    jz .Lkk_bad
    test r14, r14
    jz .Lkk_bad
    cmp dword ptr [rbx + KK_STATE_CAP], KD_SIZE
    jb .Lkk_bad
    cmp dword ptr [rbx + KK_CTRL_CAP], 24
    jb .Lkk_bad
    cmp dword ptr [rbx + KK_WORK_CAP], KW_SIZE
    jb .Lkk_bad
    cmp dword ptr [rsi + KD_TAG], KD_TAG_VALUE
    jne .Lkk_bad
    cmp dword ptr [rsi + KD_ERROR], 0
    jne .Lkk_bad
    cmp dword ptr [rbx + KK_MODE], 2
    ja .Lkk_bad
    cmp dword ptr [rbx + KK_NEW], 1
    ja .Lkk_bad
    mov eax, [r12 + KC_API_CH]
    dec eax
    cmp eax, 1
    ja .Lkk_bad
    mov eax, [r12 + KC_INT_CH]
    dec eax
    cmp eax, 1
    ja .Lkk_bad
    mov eax, [r12 + KC_INT_FS]
    cmp eax, 8000
    je .Lkk_rate
    cmp eax, 12000
    je .Lkk_rate
    cmp eax, 16000
    jne .Lkk_bad
.Lkk_rate:
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [rsp + 168], eax           #requested internal kHz
    mov eax, [r12 + KC_API_FS]
    cmp eax, 8000
    je .Lkk_api_rate
    cmp eax, 12000
    je .Lkk_api_rate
    cmp eax, 16000
    je .Lkk_api_rate
    cmp eax, 24000
    je .Lkk_api_rate
    cmp eax, 48000
    jne .Lkk_bad
.Lkk_api_rate:
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [rsp + 140], eax           #API kHz,converted to frame count below
    mov dword ptr [rsp + 128], 1   #frames per packet
    mov dword ptr [rsp + 132], 2   #subframes per frame
    mov eax, [r12 + KC_MS]
    test eax, eax
    jz .Lkk_duration
    cmp eax, 10
    je .Lkk_duration
    mov dword ptr [rsp + 132], 4
    cmp eax, 20
    je .Lkk_duration
    mov dword ptr [rsp + 128], 2
    cmp eax, 40
    je .Lkk_duration
    mov dword ptr [rsp + 128], 3
    cmp eax, 60
    jne .Lkk_bad
.Lkk_duration:
    mov eax, [rsp + 132]
    imul eax, 5
    mov ecx, eax
    imul eax, [rsp + 168]
    mov [rsp + 136], eax           #source frame count
    imul ecx, [rsp + 140]
    mov [rsp + 140], ecx           #API frame count
    imul ecx, [r12 + KC_API_CH]
    cmp [rbx + KK_PCM_CAP], ecx
    jb .Lkk_bad
    cmp dword ptr [rsi + KD_API_CH], 2
    ja .Lkk_bad
    cmp dword ptr [rsi + KD_INT_CH], 2
    ja .Lkk_bad
    cmp dword ptr [rsi + KD_PREV_MID], 1
    ja .Lkk_bad
    cmp dword ptr [rbx + KK_NEW], 1
    je .Lkk_entropy_guard
    mov eax, [rsi + KD_META + PD_FRAMES]
    cmp eax, [rsp + 128]
    jne .Lkk_bad
    mov ecx, [rsi + KD_DECODED]
    cmp ecx, eax
    jae .Lkk_bad
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_continue_channels
    cmp ecx, [rsi + KD_DECODED + 4]
    jne .Lkk_bad
.Lkk_continue_channels:
    mov eax, [rsi + KD_META + PD_CHANNELS]
    cmp eax, [r12 + KC_INT_CH]
    jne .Lkk_bad
    mov eax, [rsi + KD_API_FS]
    cmp eax, [r12 + KC_API_FS]
    jne .Lkk_bad
    mov eax, [rsi + KD_CHANNEL0 + FN_FS]
    cmp eax, [rsp + 168]
    jne .Lkk_bad
    mov eax, [rsi + KD_CHANNEL0 + FN_SUBFR]
    cmp eax, [rsp + 132]
    jne .Lkk_bad
.Lkk_entropy_guard:
    cmp dword ptr [rbx + KK_MODE], 1
    je .Lkk_start
    test r15, r15
    jz .Lkk_bad
    cmp dword ptr [rbx + KK_EC_CAP], 64
    jb .Lkk_bad
    cmp qword ptr [r15], 0
    je .Lkk_bad
    cmp dword ptr [r15 + 8], 1275
    ja .Lkk_bad
    mov eax, [r15 + 8]
    cmp [r15 + 12], eax
    ja .Lkk_bad
    cmp [r15 + 28], eax
    ja .Lkk_bad
    cmp dword ptr [r15 + 32], 0x800000
    jbe .Lkk_bad
    cmp dword ptr [r15 + 32], 0x80000000
    ja .Lkk_bad
    mov eax, [r15 + 32]
    cmp [r15 + 36], eax
    jae .Lkk_bad
    cmp dword ptr [r15 + 20], 32
    ja .Lkk_bad
    cmp dword ptr [r15 + 24], 32768
    ja .Lkk_bad
.Lkk_start:
    mov eax, [rsi + KD_API_FS]
    mov [rsp + 164], eax           #old API Hz
    mov dword ptr [rsp + 148], 0   #stereo-to-mono history transition
    cmp dword ptr [r12 + KC_INT_CH], 1
    jne .Lkk_new_packet
    cmp dword ptr [rsi + KD_INT_CH], 2
    jne .Lkk_new_packet
    mov eax, [rsi + KD_CHANNEL0 + FN_FS]
    cmp eax, [rsp + 168]
    jne .Lkk_new_packet
    mov dword ptr [rsp + 148], 1
.Lkk_new_packet:
    cmp dword ptr [rbx + KK_NEW], 0
    je .Lkk_channel_transition
    mov dword ptr [rsi + KD_DECODED], 0
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_channel_transition
    mov dword ptr [rsi + KD_DECODED + 4], 0
.Lkk_channel_transition:
    mov eax, [r12 + KC_INT_CH]
    cmp eax, [rsi + KD_INT_CH]
    jle .Lkk_config_start
    lea rdi, [rsi + KD_CHANNEL1]
    mov ecx, FN_SIZE/4
    xor eax, eax
    rep stosd
    lea rcx, [rsi + KD_CHANNEL1]
    call kd_channel_init
    lea rdi, [rsi + KD_RS1]
    mov ecx, RS_SIZE/4
    xor eax, eax
    rep stosd
    mov qword ptr [rsi + KD_META + PD_VAD + 12], 0
    mov dword ptr [rsi + KD_META + PD_VAD + 20], 0
    mov qword ptr [rsi + KD_META + PD_LBRR + 12], 0
    mov dword ptr [rsi + KD_META + PD_LBRR + 20], 0
    mov dword ptr [rsi + KD_META + PD_FLAG + 4], 0
    mov dword ptr [rsi + KD_DECODED + 4], 0
.Lkk_config_start:
    cmp dword ptr [rsi + KD_DECODED], 0
    jne .Lkk_stereo_setup
    mov eax, [rsp + 128]
    mov [rsi + KD_META + PD_FRAMES], eax
    mov eax, [r12 + KC_INT_CH]
    mov [rsi + KD_META + PD_CHANNELS], eax
    mov dword ptr [rsp + 160], 0
.Lkk_config_channel:
    mov ecx, [rsp + 160]
    imul eax, ecx, FN_SIZE
    lea r8, [rsi + rax]
    mov [rsp + 184], r8
    mov eax, [r8 + FN_FS]
    cmp eax, [rsp + 168]
    jne .Lkk_init_resampler
    mov eax, [rsp + 164]
    cmp eax, [r12 + KC_API_FS]
    je .Lkk_config_frame
.Lkk_init_resampler:
    imul eax, dword ptr [rsp + 160], RS_SIZE
    lea rax, [rsi + rax + KD_RS0]
    mov [rsp + 32 + RI_STATE], rax
    mov eax, [r12 + KC_INT_FS]
    mov [rsp + 32 + RI_IN], eax
    mov eax, [r12 + KC_API_FS]
    mov [rsp + 32 + RI_OUT], eax
    mov dword ptr [rsp + 32 + RI_CAP], RS_SIZE
    lea rcx, [rsp + 32]
    call op_silk_resampler_init
    test eax, eax
    jz .Lkk_failed
.Lkk_config_frame:
    mov r8, [rsp + 184]
    mov [rsp + 32 + FI_STATE], r8
    mov eax, [rsp + 168]
    mov [rsp + 32 + FI_FS], eax
    mov eax, [rsp + 132]
    mov [rsp + 32 + FI_SUBFR], eax
    mov dword ptr [rsp + 32 + FI_STATE_CAP], FN_SIZE
    cmp dword ptr [r8 + FN_FS], 0
    jne .Lkk_config_existing
    lea rcx, [rsp + 32]
    call op_silk_frame_init
    jmp .Lkk_config_result
.Lkk_config_existing:
    lea rcx, [rsp + 32]
    call op_silk_frame_config
.Lkk_config_result:
    test eax, eax
    jz .Lkk_failed
    inc dword ptr [rsp + 160]
    mov eax, [rsp + 160]
    cmp eax, [r12 + KC_INT_CH]
    jb .Lkk_config_channel
    # Output-rate changes during stereo collapse also reset the inactive
    # right resampler. The RFC leaves it at the old rate, which cannot
    # safely produce the newly requested right-channel sample count.
    cmp dword ptr [rsp + 148], 0
    je .Lkk_stereo_setup
    mov eax, [rsp + 164]
    cmp eax, [r12 + KC_API_FS]
    je .Lkk_stereo_setup
    lea rax, [rsi + KD_RS1]
    mov [rsp + 32 + RI_STATE], rax
    mov eax, [r12 + KC_INT_FS]
    mov [rsp + 32 + RI_IN], eax
    mov eax, [r12 + KC_API_FS]
    mov [rsp + 32 + RI_OUT], eax
    mov dword ptr [rsp + 32 + RI_CAP], RS_SIZE
    lea rcx, [rsp + 32]
    call op_silk_resampler_init
    test eax, eax
    jz .Lkk_failed
.Lkk_stereo_setup:
    cmp dword ptr [r12 + KC_API_CH], 2
    jne .Lkk_set_channels
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_set_channels
    cmp dword ptr [rsi + KD_API_CH], 1
    je .Lkk_stereo_reset
    cmp dword ptr [rsi + KD_INT_CH], 1
    jne .Lkk_set_channels
.Lkk_stereo_reset:
    mov dword ptr [rsi + KD_STEREO + SN_PRED], 0
    mov dword ptr [rsi + KD_STEREO + SN_SIDE], 0
    lea r8, [rsi + KD_RS0]
    lea r9, [rsi + KD_RS1]
    xor ecx, ecx
.Lkk_copy_resampler:
    mov rax, [r8 + rcx*8]
    mov [r9 + rcx*8], rax
    inc ecx
    cmp ecx, RS_SIZE/8
    jb .Lkk_copy_resampler
.Lkk_set_channels:
    mov eax, [r12 + KC_API_CH]
    mov [rsi + KD_API_CH], eax
    mov eax, [r12 + KC_INT_CH]
    mov [rsi + KD_INT_CH], eax
    mov eax, [r12 + KC_API_FS]
    mov [rsi + KD_API_FS], eax
    cmp dword ptr [rbx + KK_MODE], 1
    je .Lkk_predictors
    cmp dword ptr [rsi + KD_DECODED], 0
    jne .Lkk_predictors
    lea rax, [rsi + KD_CHANNEL0]
    mov [rsp + 32 + PH_STATE], rax
    lea rax, [rsi + KD_META]
    mov [rsp + 32 + PH_META], rax
    mov [rsp + 32 + PH_EC], r15
    lea rax, [r13 + KW_TEMP]
    mov [rsp + 32 + PH_WORK], rax
    mov eax, [rsp + 128]
    mov [rsp + 32 + PH_FRAMES], eax
    mov eax, [r12 + KC_INT_CH]
    mov [rsp + 32 + PH_CHANNELS], eax
    mov eax, [rbx + KK_MODE]
    mov [rsp + 32 + PH_MODE], eax
    mov dword ptr [rsp + 32 + PH_STATE_CAP], FN_SIZE*2
    mov dword ptr [rsp + 32 + PH_META_CAP], PD_SIZE
    mov dword ptr [rsp + 32 + PH_EC_CAP], 64
    mov dword ptr [rsp + 32 + PH_WORK_CAP], 1280
    lea rcx, [rsp + 32]
    call op_silk_packet_header
    test eax, eax
    jz .Lkk_failed
.Lkk_predictors:
    mov dword ptr [rsp + 152], 0    #decode_only_middle
    mov qword ptr [rsp + 176], 0    #two int32 predictors
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_side_reset_check
    cmp dword ptr [rbx + KK_MODE], 0
    je .Lkk_decode_predictors
    cmp dword ptr [rbx + KK_MODE], 2
    jne .Lkk_old_predictors
    mov ecx, [rsi + KD_DECODED]
    cmp dword ptr [rsi + rcx*4 + KD_META + PD_LBRR], 1
    je .Lkk_decode_predictors
.Lkk_old_predictors:
    movsx eax, word ptr [rsi + KD_STEREO + SN_PRED]
    mov [rsp + 176], eax
    movsx eax, word ptr [rsi + KD_STEREO + SN_PRED + 2]
    mov [rsp + 180], eax
    jmp .Lkk_side_reset_check
.Lkk_decode_predictors:
    mov [rsp + 32 + ST_EC], r15
    lea rax, [rsp + 176]
    mov [rsp + 32 + ST_OUT], rax
    mov dword ptr [rsp + 32 + ST_KIND], 0
    mov dword ptr [rsp + 32 + ST_OUT_CAP], 2
    mov dword ptr [rsp + 32 + ST_EC_CAP], 64
    lea rcx, [rsp + 32]
    call op_silk_stereo_indices
    test eax, eax
    jz .Lkk_failed
    mov ecx, [rsi + KD_DECODED]
    cmp dword ptr [rbx + KK_MODE], 0
    jne .Lkk_fec_mid_flag
    cmp dword ptr [rsi + rcx*4 + KD_META + PD_VAD + 12], 0
    je .Lkk_mid_flag
    jmp .Lkk_side_reset_check
.Lkk_fec_mid_flag:
    cmp dword ptr [rsi + rcx*4 + KD_META + PD_LBRR + 12], 0
    jne .Lkk_side_reset_check
.Lkk_mid_flag:
    lea rax, [rsp + 152]
    mov [rsp + 32 + ST_OUT], rax
    mov dword ptr [rsp + 32 + ST_KIND], 1
    mov dword ptr [rsp + 32 + ST_OUT_CAP], 1
    lea rcx, [rsp + 32]
    call op_silk_stereo_indices
    test eax, eax
    jz .Lkk_failed
.Lkk_side_reset_check:
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_has_side
    cmp dword ptr [rsp + 152], 0
    jne .Lkk_has_side
    cmp dword ptr [rsi + KD_PREV_MID], 1
    jne .Lkk_has_side
    lea rdi, [rsi + KD_CHANNEL1 + FN_CORE + CS_LPC]
    xor eax, eax
    mov ecx, 16
    rep stosd
    lea rdi, [rsi + KD_CHANNEL1 + FN_CORE + CS_OUT]
    mov ecx, 240
    rep stosd
    mov dword ptr [rsi + KD_CHANNEL1 + FN_CORE + CS_LAG], 100
    mov dword ptr [rsi + KD_CHANNEL1 + FN_CORE + CS_SIGNAL], 0
    mov byte ptr [rsi + KD_CHANNEL1 + FN_PARAM + DS_GAIN], 10
    mov dword ptr [rsi + KD_CHANNEL1 + FN_PARAM + DS_FIRST], 1
.Lkk_has_side:
    mov dword ptr [rsp + 156], 1
    cmp dword ptr [rbx + KK_MODE], 0
    jne .Lkk_lost_side
    mov eax, 1
    sub eax, [rsp + 152]
    mov [rsp + 156], eax
    jmp .Lkk_frame_start
.Lkk_lost_side:
    cmp dword ptr [rsi + KD_PREV_MID], 0
    je .Lkk_frame_start
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_no_side
    cmp dword ptr [rbx + KK_MODE], 2
    jne .Lkk_no_side
    mov ecx, [rsi + KD_DECODED + 4]
    cmp dword ptr [rsi + rcx*4 + KD_META + PD_LBRR + 12], 1
    je .Lkk_frame_start
.Lkk_no_side:
    mov dword ptr [rsp + 156], 0
.Lkk_frame_start:
    mov dword ptr [rsp + 160], 0
.Lkk_frame_channel:
    mov ecx, [rsp + 160]
    test ecx, ecx
    jz .Lkk_frame_decode
    cmp dword ptr [rsp + 156], 0
    jne .Lkk_frame_decode
    lea rdi, [r13 + KW_SIDE + 4]
    mov ecx, [rsp + 136]
    xor eax, eax
    rep stosw
    jmp .Lkk_frame_next
.Lkk_frame_decode:
    mov ecx, [rsp + 160]
    imul eax, ecx, FN_SIZE
    lea rax, [rsi + rax]
    mov [rsp + 32 + FF_STATE], rax
    mov [rsp + 32 + FF_EC], r15
    imul eax, ecx, 644
    lea rax, [r13 + rax + 4]
    mov [rsp + 32 + FF_PCM], rax
    lea rax, [r13 + KW_TEMP]
    mov [rsp + 32 + FF_WORK], rax
    mov eax, [rbx + KK_MODE]
    mov [rsp + 32 + FF_MODE], eax
    mov edx, [rsi + rcx*4 + KD_DECODED]
    imul r8d, ecx, 3
    add r8d, edx
    mov eax, [rsi + r8*4 + KD_META + PD_VAD]
    mov [rsp + 32 + FF_VAD], eax
    mov eax, [rsi + r8*4 + KD_META + PD_LBRR]
    mov [rsp + 32 + FF_LBRR], eax
    mov eax, [rsi + KD_DECODED]
    sub eax, ecx
    xor edx, edx
    test eax, eax
    jle .Lkk_coding_ready
    cmp dword ptr [rbx + KK_MODE], 2
    jne .Lkk_coding_normal
    imul r8d, ecx, 3
    add r8d, eax
    cmp dword ptr [rsi + r8*4 + KD_META + PD_LBRR - 4], 1
    jne .Lkk_coding_ready
    mov edx, 2
    jmp .Lkk_coding_ready
.Lkk_coding_normal:
    mov edx, 2
    test ecx, ecx
    jz .Lkk_coding_ready
    cmp dword ptr [rsi + KD_PREV_MID], 1
    jne .Lkk_coding_ready
    mov edx, 1
.Lkk_coding_ready:
    mov [rsp + 32 + FF_COND], edx
    mov dword ptr [rsp + 32 + FF_STATE_CAP], FN_SIZE
    mov dword ptr [rsp + 32 + FF_EC_CAP], 64
    mov eax, [rsp + 136]
    mov [rsp + 32 + FF_PCM_CAP], eax
    mov dword ptr [rsp + 32 + FF_WORK_CAP], FW_SIZE
    lea rcx, [rsp + 32]
    call op_silk_decode_frame
    cmp eax, [rsp + 136]
    jne .Lkk_failed
.Lkk_frame_next:
    mov ecx, [rsp + 160]
    inc dword ptr [rsi + rcx*4 + KD_DECODED]
    inc ecx
    mov [rsp + 160], ecx
    cmp ecx, [r12 + KC_INT_CH]
    jb .Lkk_frame_channel
    cmp dword ptr [r12 + KC_API_CH], 2
    jne .Lkk_buffer_mid
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_buffer_mid
    lea rax, [rsi + KD_STEREO]
    mov [rsp + 32 + SM_STATE], rax
    lea rax, [r13 + KW_MID]
    mov [rsp + 32 + SM_MID], rax
    lea rax, [r13 + KW_SIDE]
    mov [rsp + 32 + SM_SIDE], rax
    lea rax, [rsp + 176]
    mov [rsp + 32 + SM_PRED], rax
    mov eax, [rsp + 168]
    mov [rsp + 32 + SM_FS], eax
    mov eax, [rsp + 136]
    mov [rsp + 32 + SM_N], eax
    mov dword ptr [rsp + 32 + SM_STATE_CAP], 12
    mov dword ptr [rsp + 32 + SM_MID_CAP], 322
    mov dword ptr [rsp + 32 + SM_SIDE_CAP], 322
    mov dword ptr [rsp + 32 + SM_PRED_CAP], 2
    lea rcx, [rsp + 32]
    call op_silk_stereo
    test eax, eax
    jz .Lkk_failed
    jmp .Lkk_resample_start
.Lkk_buffer_mid:
    mov eax, [rsi + KD_STEREO + SN_MID]
    mov [r13 + KW_MID], eax
    mov ecx, [rsp + 136]
    mov eax, [r13 + rcx*2 + KW_MID]
    mov [rsi + KD_STEREO + SN_MID], eax
.Lkk_resample_start:
    mov dword ptr [rsp + 160], 0
.Lkk_resample_channel:
    mov ecx, [rsp + 160]
    imul eax, ecx, RS_SIZE
    lea rax, [rsi + rax + KD_RS0]
    mov [rsp + 32 + RR_STATE], rax
    mov rax, r14
    cmp dword ptr [r12 + KC_API_CH], 1
    je .Lkk_resample_output
    lea rax, [r13 + KW_RES]
.Lkk_resample_output:
    mov [rsp + 32 + RR_OUT], rax
    imul eax, ecx, 644
    lea rax, [r13 + rax + 2]
    mov [rsp + 32 + RR_IN], rax
    lea rax, [r13 + KW_TEMP]
    mov [rsp + 32 + RR_WORK], rax
    mov eax, [rsp + 136]
    mov [rsp + 32 + RR_N], eax
    mov [rsp + 32 + RR_IN_CAP], eax
    mov eax, [rsp + 140]
    mov [rsp + 32 + RR_OUT_CAP], eax
    mov dword ptr [rsp + 32 + RR_STATE_CAP], RS_SIZE
    mov dword ptr [rsp + 32 + RR_WORK_CAP], RR_WORK_SIZE
    lea rcx, [rsp + 32]
    call op_silk_resampler
    cmp eax, [rsp + 140]
    jne .Lkk_failed
    cmp dword ptr [r12 + KC_API_CH], 1
    je .Lkk_resample_next
    xor ecx, ecx
    mov r8d, [rsp + 160]
.Lkk_interleave:
    mov ax, [r13 + rcx*2 + KW_RES]
    lea edx, [r8 + rcx*2]
    mov [r14 + rdx*2], ax
    inc ecx
    cmp ecx, [rsp + 140]
    jb .Lkk_interleave
.Lkk_resample_next:
    inc dword ptr [rsp + 160]
    mov eax, [rsp + 160]
    cmp eax, [r12 + KC_API_CH]
    jae .Lkk_mono_duplicate
    cmp eax, [r12 + KC_INT_CH]
    jb .Lkk_resample_channel
.Lkk_mono_duplicate:
    cmp dword ptr [r12 + KC_API_CH], 2
    jne .Lkk_pitch
    cmp dword ptr [r12 + KC_INT_CH], 1
    jne .Lkk_pitch
    cmp dword ptr [rsp + 148], 0
    je .Lkk_duplicate_left
    lea rax, [rsi + KD_RS1]
    mov [rsp + 32 + RR_STATE], rax
    lea rax, [r13 + KW_RES]
    mov [rsp + 32 + RR_OUT], rax
    lea rax, [r13 + KW_MID + 2]
    mov [rsp + 32 + RR_IN], rax
    lea rcx, [rsp + 32]
    call op_silk_resampler
    cmp eax, [rsp + 140]
    jne .Lkk_failed
    xor ecx, ecx
.Lkk_right_history:
    mov ax, [r13 + rcx*2 + KW_RES]
    mov [r14 + rcx*4 + 2], ax
    inc ecx
    cmp ecx, [rsp + 140]
    jb .Lkk_right_history
    jmp .Lkk_pitch
.Lkk_duplicate_left:
    xor ecx, ecx
.Lkk_duplicate_sample:
    mov ax, [r14 + rcx*4]
    mov [r14 + rcx*4 + 2], ax
    inc ecx
    cmp ecx, [rsp + 140]
    jb .Lkk_duplicate_sample
.Lkk_pitch:
    xor eax, eax
    cmp dword ptr [rsi + KD_CHANNEL0 + FN_CORE + CS_SIGNAL], 2
    jne .Lkk_pitch_ready
    mov eax, 48
    xor edx, edx
    div dword ptr [rsp + 168]
    imul eax, [rsi + KD_CHANNEL0 + FN_CORE + CS_LAG]
.Lkk_pitch_ready:
    mov [r12 + KC_PITCH], eax
    cmp dword ptr [rbx + KK_MODE], 1
    jne .Lkk_mid_history
    mov byte ptr [rsi + KD_CHANNEL0 + FN_PARAM + DS_GAIN], 10
    cmp dword ptr [r12 + KC_INT_CH], 2
    jne .Lkk_success
    mov byte ptr [rsi + KD_CHANNEL1 + FN_PARAM + DS_GAIN], 10
    jmp .Lkk_success
.Lkk_mid_history:
    mov eax, [rsp + 152]
    mov [rsi + KD_PREV_MID], eax
.Lkk_success:
    mov eax, [rsp + 140]
    jmp .Lkk_done
.Lkk_failed:
    mov dword ptr [rsi + KD_ERROR], 1
.Lkk_bad:
    xor eax, eax
.Lkk_done:
    add rsp, 224
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_decode
