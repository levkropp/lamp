; Stateful SILK channel initialization, rate configuration and frame PCM.
; RFC6716 init_decoder.c/decoder_set_fs.c/decode_frame.c, Copyright(c)
; 2006-2012 IETF Trust/Skype Limited. BSD in THIRD_PARTY_NOTICES.
option casemap:none
include opus_silk_frame_layout.inc
include opus_silk_indices_layout.inc
include opus_silk_state_layout.inc
include opus_silk_synthesis_layout.inc
include opus_silk_plc_layout.inc
include opus_silk_cng_layout.inc
EXTERN op_silk_indices:PROC,op_silk_pulses:PROC
EXTERN op_silk_decode_parameters:PROC,op_silk_synthesis:PROC
EXTERN op_silk_plc:PROC,op_silk_plc_glue:PROC,op_silk_cng:PROC
PUBLIC op_silk_frame_init,op_silk_frame_config,op_silk_decode_frame
.code
; Validate init/config request; EAX=1/0, R8=state, EDX=fs, R9D=subframes.
fi_validate PROC
    test rcx,rcx
    jz fi_invalid
    mov r8,[rcx+FI_STATE]
    test r8,r8
    jz fi_invalid
    cmp dword ptr [rcx+FI_STATE_CAP],FN_SIZE
    jb fi_invalid
    mov edx,[rcx+FI_FS]
    cmp edx,8
    je fi_rate
    cmp edx,12
    je fi_rate
    cmp edx,16
    jne fi_invalid
fi_rate:
    mov r9d,[rcx+FI_SUBFR]
    cmp r9d,2
    je fi_valid
    cmp r9d,4
    jne fi_invalid
fi_valid:
    mov eax,1
    ret
fi_invalid:
    xor eax,eax
    ret
fi_validate ENDP
op_silk_frame_init PROC
    push rdi
    sub rsp,32
    call fi_validate
    test eax,eax
    jz fi_init_done
    mov rdi,r8
    mov ecx,FN_SIZE/4
    xor eax,eax
    rep stosd
    mov dword ptr [r8+FN_CORE+CS_GAIN],65536
    mov dword ptr [r8+FN_CNG+CN_RNG],3176576
    mov dword ptr [r8+FN_PLC+PN_GAINS],65536
    mov dword ptr [r8+FN_PLC+PN_GAINS+4],65536
    mov dword ptr [r8+FN_PLC+PN_SUBLEN],20
    mov dword ptr [r8+FN_PLC+PN_SUBFR],2
    mov [r8+FN_FS],edx
    mov [r8+FN_SUBFR],r9d
    mov dword ptr [r8+FN_CORE+CS_LAG],100
    mov byte ptr [r8+FN_PARAM+DS_GAIN],10
    mov dword ptr [r8+FN_PARAM+DS_FIRST],1
    mov dword ptr [r8+FN_TAG],FN_TAG_VALUE
    mov eax,1
fi_init_done:
    add rsp,32
    pop rdi
    ret
op_silk_frame_init ENDP
op_silk_frame_config PROC
    push rdi
    sub rsp,32
    call fi_validate
    test eax,eax
    jz fi_config_done
    cmp dword ptr [r8+FN_TAG],FN_TAG_VALUE
    jne fi_config_bad
    cmp dword ptr [r8+FN_ERROR],0
    jne fi_config_bad
    mov eax,[r8+FN_FS]
    cmp eax,8
    je fi_current_rate
    cmp eax,12
    je fi_current_rate
    cmp eax,16
    jne fi_config_bad
fi_current_rate:
    cmp dword ptr [r8+FN_SUBFR],2
    je fi_current_subfr
    cmp dword ptr [r8+FN_SUBFR],4
    jne fi_config_bad
fi_current_subfr:
    cmp [r8+FN_FS],edx
    je fi_config_subfr
    ; Normative internal-rate reset preserves excitation, gain, indices,
    ; previous NLSFs and PLC/CNG until their next frame-rate checks.
    lea rdi,[r8+FN_CORE+CS_LPC]
    mov ecx,16
    xor eax,eax
    rep stosd
    lea rdi,[r8+FN_CORE+CS_OUT]
    mov ecx,240
    rep stosd
    mov dword ptr [r8+FN_CORE+CS_LAG],100
    mov dword ptr [r8+FN_CORE+CS_SIGNAL],0
    mov byte ptr [r8+FN_PARAM+DS_GAIN],10
    mov dword ptr [r8+FN_PARAM+DS_FIRST],1
    mov [r8+FN_FS],edx
fi_config_subfr:
    mov [r8+FN_SUBFR],r9d
    mov eax,1
    jmp fi_config_done
fi_config_bad:
    xor eax,eax
fi_config_done:
    add rsp,32
    pop rdi
    ret
op_silk_frame_config ENDP
; Returns source-rate sample count,0 on failure. Public request/header
; errors reject before writes. A later component error marks sticky
; failure; discard that frame's PCM/state and reinitialize before reuse.
op_silk_decode_frame PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,144
    mov rbx,rcx
    test rbx,rbx
    jz ff_bad
    mov rsi,[rbx+FF_STATE]
    mov r12,[rbx+FF_PCM]
    mov r13,[rbx+FF_WORK]
    mov r14,[rbx+FF_EC]
    test rsi,rsi
    jz ff_bad
    test r12,r12
    jz ff_bad
    test r13,r13
    jz ff_bad
    cmp dword ptr [rbx+FF_STATE_CAP],FN_SIZE
    jb ff_bad
    cmp dword ptr [rbx+FF_WORK_CAP],FW_SIZE
    jb ff_bad
    cmp dword ptr [rsi+FN_TAG],FN_TAG_VALUE
    jne ff_bad
    cmp dword ptr [rsi+FN_ERROR],0
    jne ff_bad
    mov eax,[rsi+FN_FS]
    cmp eax,8
    je ff_rate
    cmp eax,12
    je ff_rate
    cmp eax,16
    jne ff_bad
ff_rate:
    mov ecx,[rsi+FN_SUBFR]
    cmp ecx,2
    je ff_subfr
    cmp ecx,4
    jne ff_bad
ff_subfr:
    imul eax,ecx
    imul r15d,eax,5
    cmp [rbx+FF_PCM_CAP],r15d
    jb ff_bad
    cmp dword ptr [rbx+FF_MODE],2
    ja ff_bad
    cmp dword ptr [rbx+FF_VAD],1
    ja ff_bad
    cmp dword ptr [rbx+FF_LBRR],1
    ja ff_bad
    cmp dword ptr [rbx+FF_COND],2
    ja ff_bad
    cmp dword ptr [rsi+FN_CORE+CS_GAIN],0
    jle ff_bad
    cmp dword ptr [rsi+FN_CORE+CS_SIGNAL],2
    ja ff_bad
    cmp dword ptr [rsi+FN_CORE+CS_LOSS],0
    jl ff_bad
    cmp dword ptr [rsi+FN_PARAM+DS_FIRST],1
    ja ff_bad
    cmp byte ptr [rsi+FN_PARAM+DS_GAIN],63
    ja ff_bad
    mov dword ptr [rsp+128],0    ;actual loss branch
    cmp dword ptr [rbx+FF_MODE],0
    je ff_entropy_guard
    cmp dword ptr [rbx+FF_MODE],1
    je ff_loss_guard
    cmp dword ptr [rbx+FF_LBRR],1
    je ff_entropy_guard
ff_loss_guard:
    mov dword ptr [rsp+128],1
    cmp dword ptr [rsi+FN_CORE+CS_LOSS],7fffffffh
    je ff_bad
    jmp ff_start
ff_entropy_guard:
    test r14,r14
    jz ff_bad
    cmp dword ptr [rbx+FF_EC_CAP],64
    jb ff_bad
    cmp qword ptr [r14],0
    je ff_bad
    cmp dword ptr [r14+8],1275
    ja ff_bad
    mov eax,[r14+8]
    cmp [r14+12],eax
    ja ff_bad
    cmp [r14+28],eax
    ja ff_bad
    cmp dword ptr [r14+32],800000h
    jbe ff_bad
    cmp dword ptr [r14+32],80000000h
    ja ff_bad
    mov eax,[r14+32]
    cmp [r14+36],eax
    jae ff_bad
    cmp dword ptr [r14+20],32
    ja ff_bad
    cmp dword ptr [r14+24],32768
    ja ff_bad
    cmp dword ptr [rsi+FN_PREVIOUS+SS_SIGNAL],2
    ja ff_bad
    mov eax,[rsi+FN_PREVIOUS+SS_LAG]
    cmp eax,-32768
    jl ff_bad
    cmp eax,32767
    jg ff_bad
ff_start:
    lea rdi,[r13+FW_CTRL]
    xor eax,eax
    mov ecx,35
    rep stosd
    cmp dword ptr [rsp+128],0
    jne ff_plc
    mov [rsp+32+SI_EC],r14
    lea rax,[rsi+FN_PREVIOUS]
    mov [rsp+32+SI_STATE],rax
    lea rax,[rsi+FN_IND]
    mov [rsp+32+SI_OUT],rax
    mov eax,[rsi+FN_FS]
    mov [rsp+32+SI_FS],eax
    mov eax,[rsi+FN_SUBFR]
    mov [rsp+32+SI_SUBFR],eax
    mov eax,[rbx+FF_VAD]
    mov [rsp+32+SI_VAD],eax
    xor eax,eax
    cmp dword ptr [rbx+FF_MODE],2
    sete al
    mov [rsp+32+SI_LBRR],eax
    mov eax,[rbx+FF_COND]
    mov [rsp+32+SI_COND],eax
    mov dword ptr [rsp+32+SI_OUT_CAP],36
    mov dword ptr [rsp+32+SI_STATE_CAP],8
    lea rcx,[rsp+32]
    call op_silk_indices
    test eax,eax
    jz ff_failed
    mov rcx,r14
    lea rdx,[r13+FW_PULSES]
    movzx r8d,byte ptr [rsi+FN_IND+SX_SIGNAL]
    movzx r9d,byte ptr [rsi+FN_IND+SX_OFFSET]
    mov [rsp+32],r15d
    call op_silk_pulses
    test eax,eax
    jz ff_failed
    mov eax,[rsi+FN_CORE+CS_LOSS]
    mov [rsi+FN_PARAM+DS_LOSS],eax
    lea rax,[rsi+FN_IND]
    mov [rsp+32+SD_IND],rax
    lea rax,[rsi+FN_PARAM]
    mov [rsp+32+SD_STATE],rax
    lea rax,[r13+FW_CTRL]
    mov [rsp+32+SD_OUT],rax
    mov eax,[rsi+FN_FS]
    mov [rsp+32+SD_FS],eax
    mov eax,[rsi+FN_SUBFR]
    mov [rsp+32+SD_SUBFR],eax
    mov eax,[rbx+FF_COND]
    mov [rsp+32+SD_COND],eax
    mov dword ptr [rsp+32+SD_IND_CAP],36
    mov dword ptr [rsp+32+SD_STATE_CAP],DS_SIZE
    mov dword ptr [rsp+32+SD_OUT_CAP],DC_SIZE
    lea rcx,[rsp+32]
    call op_silk_decode_parameters
    test eax,eax
    jz ff_failed
    lea rax,[rsi+FN_CORE]
    mov [rsp+32+SC_STATE],rax
    lea rax,[r13+FW_CTRL]
    mov [rsp+32+SC_CTRL],rax
    lea rax,[rsi+FN_IND]
    mov [rsp+32+SC_IND],rax
    lea rax,[r13+FW_PULSES]
    mov [rsp+32+SC_PULSES],rax
    mov [rsp+32+SC_PCM],r12
    lea rax,[r13+FW_TEMP]
    mov [rsp+32+SC_WORK],rax
    mov eax,[rsi+FN_FS]
    mov [rsp+32+SC_FS],eax
    mov eax,[rsi+FN_SUBFR]
    mov [rsp+32+SC_SUBFR],eax
    mov dword ptr [rsp+32+SC_STATE_CAP],CS_SIZE
    mov dword ptr [rsp+32+SC_CTRL_CAP],DC_SIZE
    mov [rsp+32+SC_PULSE_CAP],r15d
    mov [rsp+32+SC_PCM_CAP],r15d
    mov dword ptr [rsp+32+SC_WORK_CAP],SW_SIZE
    mov dword ptr [rsp+32+SC_IND_CAP],36
    lea rcx,[rsp+32]
    call op_silk_synthesis
    test eax,eax
    jz ff_failed
ff_plc:
    lea rax,[rsi+FN_PLC]
    mov [rsp+32+PL_STATE],rax
    lea rax,[rsi+FN_CORE]
    mov [rsp+32+PL_CORE],rax
    lea rax,[rsi+FN_PARAM]
    mov [rsp+32+PL_PARAM],rax
    lea rax,[r13+FW_CTRL]
    mov [rsp+32+PL_CTRL],rax
    lea rax,[rsi+FN_IND]
    mov [rsp+32+PL_IND],rax
    mov [rsp+32+PL_PCM],r12
    lea rax,[r13+FW_TEMP]
    mov [rsp+32+PL_WORK],rax
    mov eax,[rsi+FN_FS]
    mov [rsp+32+PL_FS],eax
    mov eax,[rsi+FN_SUBFR]
    mov [rsp+32+PL_SUBFR],eax
    mov eax,[rsp+128]
    mov [rsp+32+PL_LOST],eax
    mov dword ptr [rsp+32+PL_STATE_CAP],PN_SIZE
    mov dword ptr [rsp+32+PL_CORE_CAP],CS_SIZE
    mov dword ptr [rsp+32+PL_PARAM_CAP],DS_SIZE
    mov dword ptr [rsp+32+PL_CTRL_CAP],DC_SIZE
    mov dword ptr [rsp+32+PL_IND_CAP],36
    mov [rsp+32+PL_PCM_CAP],r15d
    mov dword ptr [rsp+32+PL_WORK_CAP],PW_SIZE
    lea rcx,[rsp+32]
    call op_silk_plc
    test eax,eax
    jz ff_failed
    cmp dword ptr [rsp+128],0
    jne ff_history
    mov dword ptr [rsi+FN_CORE+CS_LOSS],0
    mov dword ptr [rsi+FN_PARAM+DS_FIRST],0
ff_history:
    ; Maintain unmodified output history before glue/CNG, as decode_frame.c.
    imul r8d,dword ptr [rsi+FN_FS],20
    sub r8d,r15d
    xor ecx,ecx
ff_move_history:
    cmp ecx,r8d
    jae ff_copy_start
    lea edx,[rcx+r15]
    mov ax,[rsi+FN_CORE+CS_OUT+rdx*2]
    mov [rsi+FN_CORE+CS_OUT+rcx*2],ax
    inc ecx
    jmp ff_move_history
ff_copy_start:
    xor ecx,ecx
ff_copy_history:
    mov ax,[r12+rcx*2]
    lea edx,[rcx+r8]
    mov [rsi+FN_CORE+CS_OUT+rdx*2],ax
    inc ecx
    cmp ecx,r15d
    jb ff_copy_history
    lea rax,[rsi+FN_PLC]
    mov [rsp+32+PG_STATE],rax
    mov [rsp+32+PG_PCM],r12
    mov [rsp+32+PG_N],r15d
    mov eax,[rsi+FN_CORE+CS_LOSS]
    mov [rsp+32+PG_LOSS],eax
    mov dword ptr [rsp+32+PG_STATE_CAP],PN_SIZE
    mov [rsp+32+PG_PCM_CAP],r15d
    lea rcx,[rsp+32]
    call op_silk_plc_glue
    test eax,eax
    jz ff_failed
    lea rax,[rsi+FN_CNG]
    mov [rsp+32+CG_STATE],rax
    lea rax,[rsi+FN_CORE]
    mov [rsp+32+CG_CORE],rax
    lea rax,[rsi+FN_PARAM]
    mov [rsp+32+CG_PARAM],rax
    lea rax,[r13+FW_CTRL]
    mov [rsp+32+CG_CTRL],rax
    mov [rsp+32+CG_PCM],r12
    lea rax,[r13+FW_TEMP]
    mov [rsp+32+CG_WORK],rax
    mov eax,[rsi+FN_FS]
    mov [rsp+32+CG_FS],eax
    mov eax,[rsi+FN_SUBFR]
    mov [rsp+32+CG_SUBFR],eax
    mov [rsp+32+CG_N],r15d
    mov dword ptr [rsp+32+CG_STATE_CAP],CN_SIZE
    mov dword ptr [rsp+32+CG_CORE_CAP],CS_SIZE
    mov dword ptr [rsp+32+CG_PARAM_CAP],DS_SIZE
    mov dword ptr [rsp+32+CG_CTRL_CAP],DC_SIZE
    mov [rsp+32+CG_PCM_CAP],r15d
    mov dword ptr [rsp+32+CG_WORK_CAP],CW_SIZE
    lea rcx,[rsp+32]
    call op_silk_cng
    test eax,eax
    jz ff_failed
    mov ecx,[rsi+FN_SUBFR]
    dec ecx
    mov eax,[r13+FW_CTRL+DC_PITCH+rcx*4]
    mov [rsi+FN_CORE+CS_LAG],eax
    mov eax,[rsi+FN_CORE+CS_LOSS]
    mov [rsi+FN_PARAM+DS_LOSS],eax
    mov eax,r15d
    jmp ff_done
ff_failed:
    mov dword ptr [rsi+FN_ERROR],1
ff_bad:
    xor eax,eax
ff_done:
    add rsp,144
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_decode_frame ENDP
END
