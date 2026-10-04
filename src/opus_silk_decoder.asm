; Stateful SILK packet-to-API PCM, RFC6716 dec_API.c. Copyright(c)
; 2006-2012 IETF Trust/Skype Limited. BSD in THIRD_PARTY_NOTICES.
; Native-rate change/reset, FEC/loss, stereo/mid-only and decoder resampling.
option casemap:none
include opus_silk_decoder_layout.inc
include opus_silk_frame_layout.inc
include opus_silk_packet_layout.inc
include opus_silk_stereo_layout.inc
include opus_silk_resampler_layout.inc
include opus_silk_synthesis_layout.inc
include opus_silk_state_layout.inc
include opus_silk_plc_layout.inc
include opus_silk_cng_layout.inc
EXTERN op_silk_frame_init:PROC,op_silk_frame_config:PROC,op_silk_decode_frame:PROC
EXTERN op_silk_packet_header:PROC,op_silk_stereo_indices:PROC,op_silk_stereo:PROC
EXTERN op_silk_resampler_init:PROC,op_silk_resampler:PROC
PUBLIC op_silk_decoder_init,op_silk_decode
.code
; Private zeroed native channel initialization. RCX=3908-byte state.
; Caller cleared all bytes; no rate selected yet,matching silk_init_decoder.
kd_channel_init PROC
    mov dword ptr [rcx+FN_CORE+CS_GAIN],65536
    mov dword ptr [rcx+FN_PARAM+DS_FIRST],1
    mov dword ptr [rcx+FN_CNG+CN_RNG],3176576
    mov dword ptr [rcx+FN_PLC+PN_GAINS],65536
    mov dword ptr [rcx+FN_PLC+PN_GAINS+4],65536
    mov dword ptr [rcx+FN_PLC+PN_SUBLEN],20
    mov dword ptr [rcx+FN_PLC+PN_SUBFR],2
    mov dword ptr [rcx+FN_TAG],FN_TAG_VALUE
    ret
kd_channel_init ENDP
op_silk_decoder_init PROC
    push rbx
    push rdi
    sub rsp,40
    test rcx,rcx
    jz ki_bad
    mov rbx,[rcx+KI_STATE]
    test rbx,rbx
    jz ki_bad
    cmp dword ptr [rcx+KI_CAP],KD_SIZE
    jb ki_bad
    mov rdi,rbx
    mov ecx,KD_SIZE/4
    xor eax,eax
    rep stosd
    lea rcx,[rbx+KD_CHANNEL0]
    call kd_channel_init
    lea rcx,[rbx+KD_CHANNEL1]
    call kd_channel_init
    mov dword ptr [rbx+KD_TAG],KD_TAG_VALUE
    mov eax,1
    jmp ki_done
ki_bad:
    xor eax,eax
ki_done:
    add rsp,40
    pop rdi
    pop rbx
    ret
op_silk_decoder_init ENDP
; Return API sample count per channel,0 failure. Invalid request/config
; rejects before writes; later component failures mark sticky state.
op_silk_decode PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,224
    mov rbx,rcx
    test rbx,rbx
    jz kk_bad
    mov rsi,[rbx+KK_STATE]
    mov r12,[rbx+KK_CTRL]
    mov r13,[rbx+KK_WORK]
    mov r14,[rbx+KK_PCM]
    mov r15,[rbx+KK_EC]
    test rsi,rsi
    jz kk_bad
    test r12,r12
    jz kk_bad
    test r13,r13
    jz kk_bad
    test r14,r14
    jz kk_bad
    cmp dword ptr [rbx+KK_STATE_CAP],KD_SIZE
    jb kk_bad
    cmp dword ptr [rbx+KK_CTRL_CAP],24
    jb kk_bad
    cmp dword ptr [rbx+KK_WORK_CAP],KW_SIZE
    jb kk_bad
    cmp dword ptr [rsi+KD_TAG],KD_TAG_VALUE
    jne kk_bad
    cmp dword ptr [rsi+KD_ERROR],0
    jne kk_bad
    cmp dword ptr [rbx+KK_MODE],2
    ja kk_bad
    cmp dword ptr [rbx+KK_NEW],1
    ja kk_bad
    mov eax,[r12+KC_API_CH]
    dec eax
    cmp eax,1
    ja kk_bad
    mov eax,[r12+KC_INT_CH]
    dec eax
    cmp eax,1
    ja kk_bad
    mov eax,[r12+KC_INT_FS]
    cmp eax,8000
    je kk_rate
    cmp eax,12000
    je kk_rate
    cmp eax,16000
    jne kk_bad
kk_rate:
    xor edx,edx
    mov ecx,1000
    div ecx
    mov [rsp+168],eax           ;requested internal kHz
    mov eax,[r12+KC_API_FS]
    cmp eax,8000
    je kk_api_rate
    cmp eax,12000
    je kk_api_rate
    cmp eax,16000
    je kk_api_rate
    cmp eax,24000
    je kk_api_rate
    cmp eax,48000
    jne kk_bad
kk_api_rate:
    xor edx,edx
    mov ecx,1000
    div ecx
    mov [rsp+140],eax           ;API kHz,converted to frame count below
    mov dword ptr [rsp+128],1   ;frames per packet
    mov dword ptr [rsp+132],2   ;subframes per frame
    mov eax,[r12+KC_MS]
    test eax,eax
    jz kk_duration
    cmp eax,10
    je kk_duration
    mov dword ptr [rsp+132],4
    cmp eax,20
    je kk_duration
    mov dword ptr [rsp+128],2
    cmp eax,40
    je kk_duration
    mov dword ptr [rsp+128],3
    cmp eax,60
    jne kk_bad
kk_duration:
    mov eax,[rsp+132]
    imul eax,5
    mov ecx,eax
    imul eax,[rsp+168]
    mov [rsp+136],eax           ;source frame count
    imul ecx,[rsp+140]
    mov [rsp+140],ecx           ;API frame count
    imul ecx,[r12+KC_API_CH]
    cmp [rbx+KK_PCM_CAP],ecx
    jb kk_bad
    cmp dword ptr [rsi+KD_API_CH],2
    ja kk_bad
    cmp dword ptr [rsi+KD_INT_CH],2
    ja kk_bad
    cmp dword ptr [rsi+KD_PREV_MID],1
    ja kk_bad
    cmp dword ptr [rbx+KK_NEW],1
    je kk_entropy_guard
    mov eax,[rsi+KD_META+PD_FRAMES]
    cmp eax,[rsp+128]
    jne kk_bad
    mov ecx,[rsi+KD_DECODED]
    cmp ecx,eax
    jae kk_bad
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_continue_channels
    cmp ecx,[rsi+KD_DECODED+4]
    jne kk_bad
kk_continue_channels:
    mov eax,[rsi+KD_META+PD_CHANNELS]
    cmp eax,[r12+KC_INT_CH]
    jne kk_bad
    mov eax,[rsi+KD_API_FS]
    cmp eax,[r12+KC_API_FS]
    jne kk_bad
    mov eax,[rsi+KD_CHANNEL0+FN_FS]
    cmp eax,[rsp+168]
    jne kk_bad
    mov eax,[rsi+KD_CHANNEL0+FN_SUBFR]
    cmp eax,[rsp+132]
    jne kk_bad
kk_entropy_guard:
    cmp dword ptr [rbx+KK_MODE],1
    je kk_start
    test r15,r15
    jz kk_bad
    cmp dword ptr [rbx+KK_EC_CAP],64
    jb kk_bad
    cmp qword ptr [r15],0
    je kk_bad
    cmp dword ptr [r15+8],1275
    ja kk_bad
    mov eax,[r15+8]
    cmp [r15+12],eax
    ja kk_bad
    cmp [r15+28],eax
    ja kk_bad
    cmp dword ptr [r15+32],800000h
    jbe kk_bad
    cmp dword ptr [r15+32],80000000h
    ja kk_bad
    mov eax,[r15+32]
    cmp [r15+36],eax
    jae kk_bad
    cmp dword ptr [r15+20],32
    ja kk_bad
    cmp dword ptr [r15+24],32768
    ja kk_bad
kk_start:
    mov eax,[rsi+KD_API_FS]
    mov [rsp+164],eax           ;old API Hz
    mov dword ptr [rsp+148],0   ;stereo-to-mono history transition
    cmp dword ptr [r12+KC_INT_CH],1
    jne kk_new_packet
    cmp dword ptr [rsi+KD_INT_CH],2
    jne kk_new_packet
    mov eax,[rsi+KD_CHANNEL0+FN_FS]
    cmp eax,[rsp+168]
    jne kk_new_packet
    mov dword ptr [rsp+148],1
kk_new_packet:
    cmp dword ptr [rbx+KK_NEW],0
    je kk_channel_transition
    mov dword ptr [rsi+KD_DECODED],0
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_channel_transition
    mov dword ptr [rsi+KD_DECODED+4],0
kk_channel_transition:
    mov eax,[r12+KC_INT_CH]
    cmp eax,[rsi+KD_INT_CH]
    jle kk_config_start
    lea rdi,[rsi+KD_CHANNEL1]
    mov ecx,FN_SIZE/4
    xor eax,eax
    rep stosd
    lea rcx,[rsi+KD_CHANNEL1]
    call kd_channel_init
    lea rdi,[rsi+KD_RS1]
    mov ecx,RS_SIZE/4
    xor eax,eax
    rep stosd
    mov qword ptr [rsi+KD_META+PD_VAD+12],0
    mov dword ptr [rsi+KD_META+PD_VAD+20],0
    mov qword ptr [rsi+KD_META+PD_LBRR+12],0
    mov dword ptr [rsi+KD_META+PD_LBRR+20],0
    mov dword ptr [rsi+KD_META+PD_FLAG+4],0
    mov dword ptr [rsi+KD_DECODED+4],0
kk_config_start:
    cmp dword ptr [rsi+KD_DECODED],0
    jne kk_stereo_setup
    mov eax,[rsp+128]
    mov [rsi+KD_META+PD_FRAMES],eax
    mov eax,[r12+KC_INT_CH]
    mov [rsi+KD_META+PD_CHANNELS],eax
    mov dword ptr [rsp+160],0
kk_config_channel:
    mov ecx,[rsp+160]
    imul eax,ecx,FN_SIZE
    lea r8,[rsi+rax]
    mov [rsp+184],r8
    mov eax,[r8+FN_FS]
    cmp eax,[rsp+168]
    jne kk_init_resampler
    mov eax,[rsp+164]
    cmp eax,[r12+KC_API_FS]
    je kk_config_frame
kk_init_resampler:
    imul eax,dword ptr [rsp+160],RS_SIZE
    lea rax,[rsi+KD_RS0+rax]
    mov [rsp+32+RI_STATE],rax
    mov eax,[r12+KC_INT_FS]
    mov [rsp+32+RI_IN],eax
    mov eax,[r12+KC_API_FS]
    mov [rsp+32+RI_OUT],eax
    mov dword ptr [rsp+32+RI_CAP],RS_SIZE
    lea rcx,[rsp+32]
    call op_silk_resampler_init
    test eax,eax
    jz kk_failed
kk_config_frame:
    mov r8,[rsp+184]
    mov [rsp+32+FI_STATE],r8
    mov eax,[rsp+168]
    mov [rsp+32+FI_FS],eax
    mov eax,[rsp+132]
    mov [rsp+32+FI_SUBFR],eax
    mov dword ptr [rsp+32+FI_STATE_CAP],FN_SIZE
    cmp dword ptr [r8+FN_FS],0
    jne kk_config_existing
    lea rcx,[rsp+32]
    call op_silk_frame_init
    jmp kk_config_result
kk_config_existing:
    lea rcx,[rsp+32]
    call op_silk_frame_config
kk_config_result:
    test eax,eax
    jz kk_failed
    inc dword ptr [rsp+160]
    mov eax,[rsp+160]
    cmp eax,[r12+KC_INT_CH]
    jb kk_config_channel
    ; Output-rate changes during stereo collapse also reset the inactive
    ; right resampler. The RFC leaves it at the old rate, which cannot
    ; safely produce the newly requested right-channel sample count.
    cmp dword ptr [rsp+148],0
    je kk_stereo_setup
    mov eax,[rsp+164]
    cmp eax,[r12+KC_API_FS]
    je kk_stereo_setup
    lea rax,[rsi+KD_RS1]
    mov [rsp+32+RI_STATE],rax
    mov eax,[r12+KC_INT_FS]
    mov [rsp+32+RI_IN],eax
    mov eax,[r12+KC_API_FS]
    mov [rsp+32+RI_OUT],eax
    mov dword ptr [rsp+32+RI_CAP],RS_SIZE
    lea rcx,[rsp+32]
    call op_silk_resampler_init
    test eax,eax
    jz kk_failed
kk_stereo_setup:
    cmp dword ptr [r12+KC_API_CH],2
    jne kk_set_channels
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_set_channels
    cmp dword ptr [rsi+KD_API_CH],1
    je kk_stereo_reset
    cmp dword ptr [rsi+KD_INT_CH],1
    jne kk_set_channels
kk_stereo_reset:
    mov dword ptr [rsi+KD_STEREO+SN_PRED],0
    mov dword ptr [rsi+KD_STEREO+SN_SIDE],0
    lea r8,[rsi+KD_RS0]
    lea r9,[rsi+KD_RS1]
    xor ecx,ecx
kk_copy_resampler:
    mov rax,[r8+rcx*8]
    mov [r9+rcx*8],rax
    inc ecx
    cmp ecx,RS_SIZE/8
    jb kk_copy_resampler
kk_set_channels:
    mov eax,[r12+KC_API_CH]
    mov [rsi+KD_API_CH],eax
    mov eax,[r12+KC_INT_CH]
    mov [rsi+KD_INT_CH],eax
    mov eax,[r12+KC_API_FS]
    mov [rsi+KD_API_FS],eax
    cmp dword ptr [rbx+KK_MODE],1
    je kk_predictors
    cmp dword ptr [rsi+KD_DECODED],0
    jne kk_predictors
    lea rax,[rsi+KD_CHANNEL0]
    mov [rsp+32+PH_STATE],rax
    lea rax,[rsi+KD_META]
    mov [rsp+32+PH_META],rax
    mov [rsp+32+PH_EC],r15
    lea rax,[r13+KW_TEMP]
    mov [rsp+32+PH_WORK],rax
    mov eax,[rsp+128]
    mov [rsp+32+PH_FRAMES],eax
    mov eax,[r12+KC_INT_CH]
    mov [rsp+32+PH_CHANNELS],eax
    mov eax,[rbx+KK_MODE]
    mov [rsp+32+PH_MODE],eax
    mov dword ptr [rsp+32+PH_STATE_CAP],FN_SIZE*2
    mov dword ptr [rsp+32+PH_META_CAP],PD_SIZE
    mov dword ptr [rsp+32+PH_EC_CAP],64
    mov dword ptr [rsp+32+PH_WORK_CAP],1280
    lea rcx,[rsp+32]
    call op_silk_packet_header
    test eax,eax
    jz kk_failed
kk_predictors:
    mov dword ptr [rsp+152],0    ;decode_only_middle
    mov qword ptr [rsp+176],0    ;two int32 predictors
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_side_reset_check
    cmp dword ptr [rbx+KK_MODE],0
    je kk_decode_predictors
    cmp dword ptr [rbx+KK_MODE],2
    jne kk_old_predictors
    mov ecx,[rsi+KD_DECODED]
    cmp dword ptr [rsi+KD_META+PD_LBRR+rcx*4],1
    je kk_decode_predictors
kk_old_predictors:
    movsx eax,word ptr [rsi+KD_STEREO+SN_PRED]
    mov [rsp+176],eax
    movsx eax,word ptr [rsi+KD_STEREO+SN_PRED+2]
    mov [rsp+180],eax
    jmp kk_side_reset_check
kk_decode_predictors:
    mov [rsp+32+ST_EC],r15
    lea rax,[rsp+176]
    mov [rsp+32+ST_OUT],rax
    mov dword ptr [rsp+32+ST_KIND],0
    mov dword ptr [rsp+32+ST_OUT_CAP],2
    mov dword ptr [rsp+32+ST_EC_CAP],64
    lea rcx,[rsp+32]
    call op_silk_stereo_indices
    test eax,eax
    jz kk_failed
    mov ecx,[rsi+KD_DECODED]
    cmp dword ptr [rbx+KK_MODE],0
    jne kk_fec_mid_flag
    cmp dword ptr [rsi+KD_META+PD_VAD+12+rcx*4],0
    je kk_mid_flag
    jmp kk_side_reset_check
kk_fec_mid_flag:
    cmp dword ptr [rsi+KD_META+PD_LBRR+12+rcx*4],0
    jne kk_side_reset_check
kk_mid_flag:
    lea rax,[rsp+152]
    mov [rsp+32+ST_OUT],rax
    mov dword ptr [rsp+32+ST_KIND],1
    mov dword ptr [rsp+32+ST_OUT_CAP],1
    lea rcx,[rsp+32]
    call op_silk_stereo_indices
    test eax,eax
    jz kk_failed
kk_side_reset_check:
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_has_side
    cmp dword ptr [rsp+152],0
    jne kk_has_side
    cmp dword ptr [rsi+KD_PREV_MID],1
    jne kk_has_side
    lea rdi,[rsi+KD_CHANNEL1+FN_CORE+CS_LPC]
    xor eax,eax
    mov ecx,16
    rep stosd
    lea rdi,[rsi+KD_CHANNEL1+FN_CORE+CS_OUT]
    mov ecx,240
    rep stosd
    mov dword ptr [rsi+KD_CHANNEL1+FN_CORE+CS_LAG],100
    mov dword ptr [rsi+KD_CHANNEL1+FN_CORE+CS_SIGNAL],0
    mov byte ptr [rsi+KD_CHANNEL1+FN_PARAM+DS_GAIN],10
    mov dword ptr [rsi+KD_CHANNEL1+FN_PARAM+DS_FIRST],1
kk_has_side:
    mov dword ptr [rsp+156],1
    cmp dword ptr [rbx+KK_MODE],0
    jne kk_lost_side
    mov eax,1
    sub eax,[rsp+152]
    mov [rsp+156],eax
    jmp kk_frame_start
kk_lost_side:
    cmp dword ptr [rsi+KD_PREV_MID],0
    je kk_frame_start
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_no_side
    cmp dword ptr [rbx+KK_MODE],2
    jne kk_no_side
    mov ecx,[rsi+KD_DECODED+4]
    cmp dword ptr [rsi+KD_META+PD_LBRR+12+rcx*4],1
    je kk_frame_start
kk_no_side:
    mov dword ptr [rsp+156],0
kk_frame_start:
    mov dword ptr [rsp+160],0
kk_frame_channel:
    mov ecx,[rsp+160]
    test ecx,ecx
    jz kk_frame_decode
    cmp dword ptr [rsp+156],0
    jne kk_frame_decode
    lea rdi,[r13+KW_SIDE+4]
    mov ecx,[rsp+136]
    xor eax,eax
    rep stosw
    jmp kk_frame_next
kk_frame_decode:
    mov ecx,[rsp+160]
    imul eax,ecx,FN_SIZE
    lea rax,[rsi+rax]
    mov [rsp+32+FF_STATE],rax
    mov [rsp+32+FF_EC],r15
    imul eax,ecx,644
    lea rax,[r13+rax+4]
    mov [rsp+32+FF_PCM],rax
    lea rax,[r13+KW_TEMP]
    mov [rsp+32+FF_WORK],rax
    mov eax,[rbx+KK_MODE]
    mov [rsp+32+FF_MODE],eax
    mov edx,[rsi+KD_DECODED+rcx*4]
    imul r8d,ecx,3
    add r8d,edx
    mov eax,[rsi+KD_META+PD_VAD+r8*4]
    mov [rsp+32+FF_VAD],eax
    mov eax,[rsi+KD_META+PD_LBRR+r8*4]
    mov [rsp+32+FF_LBRR],eax
    mov eax,[rsi+KD_DECODED]
    sub eax,ecx
    xor edx,edx
    test eax,eax
    jle kk_coding_ready
    cmp dword ptr [rbx+KK_MODE],2
    jne kk_coding_normal
    imul r8d,ecx,3
    add r8d,eax
    cmp dword ptr [rsi+KD_META+PD_LBRR+r8*4-4],1
    jne kk_coding_ready
    mov edx,2
    jmp kk_coding_ready
kk_coding_normal:
    mov edx,2
    test ecx,ecx
    jz kk_coding_ready
    cmp dword ptr [rsi+KD_PREV_MID],1
    jne kk_coding_ready
    mov edx,1
kk_coding_ready:
    mov [rsp+32+FF_COND],edx
    mov dword ptr [rsp+32+FF_STATE_CAP],FN_SIZE
    mov dword ptr [rsp+32+FF_EC_CAP],64
    mov eax,[rsp+136]
    mov [rsp+32+FF_PCM_CAP],eax
    mov dword ptr [rsp+32+FF_WORK_CAP],FW_SIZE
    lea rcx,[rsp+32]
    call op_silk_decode_frame
    cmp eax,[rsp+136]
    jne kk_failed
kk_frame_next:
    mov ecx,[rsp+160]
    inc dword ptr [rsi+KD_DECODED+rcx*4]
    inc ecx
    mov [rsp+160],ecx
    cmp ecx,[r12+KC_INT_CH]
    jb kk_frame_channel
    cmp dword ptr [r12+KC_API_CH],2
    jne kk_buffer_mid
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_buffer_mid
    lea rax,[rsi+KD_STEREO]
    mov [rsp+32+SM_STATE],rax
    lea rax,[r13+KW_MID]
    mov [rsp+32+SM_MID],rax
    lea rax,[r13+KW_SIDE]
    mov [rsp+32+SM_SIDE],rax
    lea rax,[rsp+176]
    mov [rsp+32+SM_PRED],rax
    mov eax,[rsp+168]
    mov [rsp+32+SM_FS],eax
    mov eax,[rsp+136]
    mov [rsp+32+SM_N],eax
    mov dword ptr [rsp+32+SM_STATE_CAP],12
    mov dword ptr [rsp+32+SM_MID_CAP],322
    mov dword ptr [rsp+32+SM_SIDE_CAP],322
    mov dword ptr [rsp+32+SM_PRED_CAP],2
    lea rcx,[rsp+32]
    call op_silk_stereo
    test eax,eax
    jz kk_failed
    jmp kk_resample_start
kk_buffer_mid:
    mov eax,[rsi+KD_STEREO+SN_MID]
    mov [r13+KW_MID],eax
    mov ecx,[rsp+136]
    mov eax,[r13+KW_MID+rcx*2]
    mov [rsi+KD_STEREO+SN_MID],eax
kk_resample_start:
    mov dword ptr [rsp+160],0
kk_resample_channel:
    mov ecx,[rsp+160]
    imul eax,ecx,RS_SIZE
    lea rax,[rsi+KD_RS0+rax]
    mov [rsp+32+RR_STATE],rax
    mov rax,r14
    cmp dword ptr [r12+KC_API_CH],1
    je kk_resample_output
    lea rax,[r13+KW_RES]
kk_resample_output:
    mov [rsp+32+RR_OUT],rax
    imul eax,ecx,644
    lea rax,[r13+rax+2]
    mov [rsp+32+RR_IN],rax
    lea rax,[r13+KW_TEMP]
    mov [rsp+32+RR_WORK],rax
    mov eax,[rsp+136]
    mov [rsp+32+RR_N],eax
    mov [rsp+32+RR_IN_CAP],eax
    mov eax,[rsp+140]
    mov [rsp+32+RR_OUT_CAP],eax
    mov dword ptr [rsp+32+RR_STATE_CAP],RS_SIZE
    mov dword ptr [rsp+32+RR_WORK_CAP],RR_WORK_SIZE
    lea rcx,[rsp+32]
    call op_silk_resampler
    cmp eax,[rsp+140]
    jne kk_failed
    cmp dword ptr [r12+KC_API_CH],1
    je kk_resample_next
    xor ecx,ecx
    mov r8d,[rsp+160]
kk_interleave:
    mov ax,[r13+KW_RES+rcx*2]
    lea edx,[r8+rcx*2]
    mov [r14+rdx*2],ax
    inc ecx
    cmp ecx,[rsp+140]
    jb kk_interleave
kk_resample_next:
    inc dword ptr [rsp+160]
    mov eax,[rsp+160]
    cmp eax,[r12+KC_API_CH]
    jae kk_mono_duplicate
    cmp eax,[r12+KC_INT_CH]
    jb kk_resample_channel
kk_mono_duplicate:
    cmp dword ptr [r12+KC_API_CH],2
    jne kk_pitch
    cmp dword ptr [r12+KC_INT_CH],1
    jne kk_pitch
    cmp dword ptr [rsp+148],0
    je kk_duplicate_left
    lea rax,[rsi+KD_RS1]
    mov [rsp+32+RR_STATE],rax
    lea rax,[r13+KW_RES]
    mov [rsp+32+RR_OUT],rax
    lea rax,[r13+KW_MID+2]
    mov [rsp+32+RR_IN],rax
    lea rcx,[rsp+32]
    call op_silk_resampler
    cmp eax,[rsp+140]
    jne kk_failed
    xor ecx,ecx
kk_right_history:
    mov ax,[r13+KW_RES+rcx*2]
    mov [r14+rcx*4+2],ax
    inc ecx
    cmp ecx,[rsp+140]
    jb kk_right_history
    jmp kk_pitch
kk_duplicate_left:
    xor ecx,ecx
kk_duplicate_sample:
    mov ax,[r14+rcx*4]
    mov [r14+rcx*4+2],ax
    inc ecx
    cmp ecx,[rsp+140]
    jb kk_duplicate_sample
kk_pitch:
    xor eax,eax
    cmp dword ptr [rsi+KD_CHANNEL0+FN_CORE+CS_SIGNAL],2
    jne kk_pitch_ready
    mov eax,48
    xor edx,edx
    div dword ptr [rsp+168]
    imul eax,[rsi+KD_CHANNEL0+FN_CORE+CS_LAG]
kk_pitch_ready:
    mov [r12+KC_PITCH],eax
    cmp dword ptr [rbx+KK_MODE],1
    jne kk_mid_history
    mov byte ptr [rsi+KD_CHANNEL0+FN_PARAM+DS_GAIN],10
    cmp dword ptr [r12+KC_INT_CH],2
    jne kk_success
    mov byte ptr [rsi+KD_CHANNEL1+FN_PARAM+DS_GAIN],10
    jmp kk_success
kk_mid_history:
    mov eax,[rsp+152]
    mov [rsi+KD_PREV_MID],eax
kk_success:
    mov eax,[rsp+140]
    jmp kk_done
kk_failed:
    mov dword ptr [rsi+KD_ERROR],1
kk_bad:
    xor eax,eax
kk_done:
    add rsp,224
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_decode ENDP
END
