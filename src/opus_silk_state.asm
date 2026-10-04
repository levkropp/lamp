; Stateful SILK parameter reconstruction, interpolation and loss recovery.
; RFC6716 decode_parameters.c. Copyright(c)2006-2012 IETF Trust and
; Skype Limited. BSD conditions in THIRD_PARTY_NOTICES. Assembly only.
; Local copies make all failed requests atomic for caller-visible buffers.
option casemap:none
include opus_silk_state_layout.inc
include opus_silk_indices_layout.inc
include opus_silk_parameters_layout.inc
include opus_silk_nlsf_layout.inc
include opus_silk_lpc_layout.inc
EXTERN op_silk_gains:PROC,op_silk_pitch_ltp:PROC
EXTERN op_silk_nlsf_decode:PROC,op_silk_nlsf2a:PROC,op_silk_bwexpand:PROC
PUBLIC op_silk_decode_parameters
.code
op_silk_decode_parameters PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,576
    mov rbx,rcx
    test rbx,rbx
    jz sd_bad
    mov rsi,[rbx+SD_IND]
    mov rdi,[rbx+SD_STATE]
    mov r12,[rbx+SD_OUT]
    test rsi,rsi
    jz sd_bad
    test rdi,rdi
    jz sd_bad
    test r12,r12
    jz sd_bad
    cmp dword ptr [rbx+SD_IND_CAP],36
    jb sd_bad
    cmp dword ptr [rbx+SD_STATE_CAP],DS_SIZE
    jb sd_bad
    cmp dword ptr [rbx+SD_OUT_CAP],DC_SIZE
    jb sd_bad
    mov r14d,[rbx+SD_FS]
    mov r13d,10
    cmp r14d,8
    je sd_rate
    cmp r14d,12
    je sd_rate
    cmp r14d,16
    jne sd_bad
    mov r13d,16
sd_rate:
    mov r15d,[rbx+SD_SUBFR]
    cmp r15d,2
    je sd_subfr
    cmp r15d,4
    jne sd_bad
sd_subfr:
    cmp dword ptr [rbx+SD_COND],2
    ja sd_bad
    cmp byte ptr [rdi+DS_GAIN],63
    ja sd_bad
    cmp dword ptr [rdi+DS_FIRST],1
    ja sd_bad
    cmp dword ptr [rdi+DS_LOSS],0
    jl sd_bad
    cmp byte ptr [rsi+SX_INTERP],4
    ja sd_bad
    xor ecx,ecx
sd_prev_guard:
    cmp word ptr [rdi+DS_PREV+rcx*2],32767
    ja sd_bad
    inc ecx
    cmp ecx,r13d
    jb sd_prev_guard
    ; Preserve unused fields/padding by starting from full caller copies.
    lea rdi,[rsp+96]
    mov ecx,4
    rep movsq
    movsd
    mov rsi,[rbx+SD_STATE]
    lea rdi,[rsp+144]
    mov ecx,6
    rep movsq
    mov rsi,r12
    lea rdi,[rsp+208]
    mov ecx,17
    rep movsq
    movsd
    ; Gains and last-index history, on local copies.
    lea rax,[rsp+96+SX_GAINS]
    mov [rsp+32+SG_IND],rax
    lea rax,[rsp+208+DC_GAINS]
    mov [rsp+32+SG_OUT],rax
    lea rax,[rsp+144+DS_GAIN]
    mov [rsp+32+SG_PREV],rax
    mov [rsp+32+SG_SUBFR],r15d
    xor eax,eax
    cmp dword ptr [rbx+SD_COND],2
    sete al
    mov [rsp+32+SG_CONDITIONAL],eax
    mov [rsp+32+SG_IND_CAP],r15d
    mov [rsp+32+SG_OUT_CAP],r15d
    mov dword ptr [rsp+32+SG_PREV_CAP],1
    lea rcx,[rsp+32]
    call op_silk_gains
    test eax,eax
    jz sd_bad
    ; Pitch/LTP also validates all active voiced indices.
    lea rax,[rsp+96]
    mov [rsp+32+SP_IND],rax
    lea rax,[rsp+208+DC_PITCH]
    mov [rsp+32+SP_PITCH],rax
    lea rax,[rsp+208+DC_LTP]
    mov [rsp+32+SP_LTP],rax
    lea rax,[rsp+208+DC_SCALE]
    mov [rsp+32+SP_SCALE],rax
    mov [rsp+32+SP_FS],r14d
    mov [rsp+32+SP_SUBFR],r15d
    mov [rsp+32+SP_PITCH_CAP],r15d
    imul eax,r15d,5
    mov [rsp+32+SP_LTP_CAP],eax
    mov dword ptr [rsp+32+SP_SCALE_CAP],1
    lea rcx,[rsp+32]
    call op_silk_pitch_ltp
    test eax,eax
    jz sd_bad
    cmp byte ptr [rsp+96+SX_SIGNAL],2
    je sd_nlsf
    mov byte ptr [rsp+96+SX_PER],0
sd_nlsf:
    lea rax,[rsp+96+SX_NLSF]
    mov [rsp+32+SN_IND],rax
    lea rax,[rsp+368]
    mov [rsp+32+SN_OUT],rax
    lea rax,[rsp+448]
    mov [rsp+32+SN_WORK],rax
    mov [rsp+32+SN_FS],r14d
    lea eax,[r13+1]
    mov [rsp+32+SN_IND_CAP],eax
    mov [rsp+32+SN_OUT_CAP],r13d
    mov dword ptr [rsp+32+SN_WORK_CAP],NW_SIZE
    lea rcx,[rsp+32]
    call op_silk_nlsf_decode
    test eax,eax
    jz sd_bad
    lea rax,[rsp+368]
    mov [rsp+32+SA_NLSF],rax
    lea rax,[rsp+208+DC_PRED+32]
    mov [rsp+32+SA_OUT],rax
    mov [rsp+32+SA_ORDER],r13d
    mov [rsp+32+SA_IN_CAP],r13d
    mov [rsp+32+SA_OUT_CAP],r13d
    lea rcx,[rsp+32]
    call op_silk_nlsf2a
    test eax,eax
    jz sd_bad
    cmp dword ptr [rsp+144+DS_FIRST],1
    jne sd_interp
    mov byte ptr [rsp+96+SX_INTERP],4
sd_interp:
    movzx r8d,byte ptr [rsp+96+SX_INTERP]
    cmp r8d,4
    je sd_copy_filter
    xor ecx,ecx
sd_interp_vector:
    movzx edx,word ptr [rsp+144+DS_PREV+rcx*2]
    movzx eax,word ptr [rsp+368+rcx*2]
    sub eax,edx
    imul eax,r8d
    sar eax,2
    add eax,edx
    mov [rsp+400+rcx*2],ax
    inc ecx
    cmp ecx,r13d
    jb sd_interp_vector
    lea rax,[rsp+400]
    mov [rsp+32+SA_NLSF],rax
    lea rax,[rsp+208+DC_PRED]
    mov [rsp+32+SA_OUT],rax
    lea rcx,[rsp+32]
    call op_silk_nlsf2a
    test eax,eax
    jz sd_bad
    jmp sd_save_nlsf
sd_copy_filter:
    lea rsi,[rsp+208+DC_PRED+32]
    lea rdi,[rsp+208+DC_PRED]
    mov ecx,r13d
    rep movsw
sd_save_nlsf:
    lea rsi,[rsp+368]
    lea rdi,[rsp+144+DS_PREV]
    mov ecx,r13d
    rep movsw
    cmp dword ptr [rsp+144+DS_LOSS],0
    je sd_commit
    lea rax,[rsp+208+DC_PRED]
    mov [rsp+32+SB_AR],rax
    mov [rsp+32+SB_ORDER],r13d
    mov dword ptr [rsp+32+SB_CHIRP],63570
    mov [rsp+32+SB_CAP],r13d
    mov dword ptr [rsp+32+SB_WIDTH],16
    lea rcx,[rsp+32]
    call op_silk_bwexpand
    lea rax,[rsp+208+DC_PRED+32]
    mov [rsp+32+SB_AR],rax
    lea rcx,[rsp+32]
    call op_silk_bwexpand
sd_commit:
    lea rsi,[rsp+96]
    mov rdi,[rbx+SD_IND]
    mov ecx,4
    rep movsq
    movsd
    lea rsi,[rsp+144]
    mov rdi,[rbx+SD_STATE]
    mov ecx,6
    rep movsq
    lea rsi,[rsp+208]
    mov rdi,r12
    mov ecx,17
    rep movsq
    movsd
    mov eax,1
    jmp sd_done
sd_bad:
    xor eax,eax
sd_done:
    add rsp,576
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_decode_parameters ENDP
END
