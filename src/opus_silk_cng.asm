; Handwritten SILK comfort-noise estimation and synthesis, RFC6716 CNG.c.
; Copyright(c)2006-2012 IETF Trust and Skype Limited. BSD conditions in
; THIRD_PARTY_NOTICES. Caller-owned state/scratch; no CRT or heap.
option casemap:none
include opus_silk_cng_layout.inc
include opus_silk_synthesis_layout.inc
include opus_silk_state_layout.inc
include opus_silk_lpc_layout.inc
EXTERN op_silk_nlsf2a:PROC
PUBLIC op_silk_cng
.code
op_silk_cng PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,64
    mov rbx,rcx
    test rbx,rbx
    jz cg_bad
    mov rsi,[rbx+CG_STATE]
    mov r15,[rbx+CG_CORE]
    mov rdi,[rbx+CG_PCM]
    mov r12,[rbx+CG_WORK]
    test rsi,rsi
    jz cg_bad
    test r15,r15
    jz cg_bad
    test rdi,rdi
    jz cg_bad
    test r12,r12
    jz cg_bad
    cmp qword ptr [rbx+CG_PARAM],0
    je cg_bad
    cmp qword ptr [rbx+CG_CTRL],0
    je cg_bad
    cmp dword ptr [rbx+CG_STATE_CAP],CN_SIZE
    jb cg_bad
    cmp dword ptr [rbx+CG_CORE_CAP],CS_SIZE
    jb cg_bad
    cmp dword ptr [rbx+CG_PARAM_CAP],DS_SIZE
    jb cg_bad
    cmp dword ptr [rbx+CG_CTRL_CAP],DC_SIZE
    jb cg_bad
    cmp dword ptr [rbx+CG_WORK_CAP],CW_SIZE
    jb cg_bad
    mov eax,[rbx+CG_FS]
    mov r13d,10
    cmp eax,8
    je cg_rate
    cmp eax,12
    je cg_rate
    cmp eax,16
    jne cg_bad
    mov r13d,16
cg_rate:
    mov ecx,[rbx+CG_SUBFR]
    cmp ecx,2
    je cg_subfr
    cmp ecx,4
    jne cg_bad
cg_subfr:
    imul eax,ecx
    imul eax,5
    mov r14d,[rbx+CG_N]
    cmp r14d,1
    jl cg_bad
    cmp r14d,eax
    ja cg_bad
    cmp [rbx+CG_PCM_CAP],r14d
    jb cg_bad
    cmp dword ptr [r15+CS_LOSS],0
    jl cg_bad
    cmp dword ptr [r15+CS_SIGNAL],2
    ja cg_bad
    mov eax,[rbx+CG_FS]
    cmp eax,[rsi+CN_FS]
    jne cg_input_guard
    cmp dword ptr [rsi+CN_GAIN],0
    jl cg_bad
    xor ecx,ecx
cg_history_guard:
    cmp word ptr [rsi+CN_NLSF+rcx*2],32767
    ja cg_bad
    inc ecx
    cmp ecx,r13d
    jb cg_history_guard
cg_input_guard:
    cmp dword ptr [r15+CS_LOSS],0
    jne cg_reset_check
    cmp dword ptr [r15+CS_SIGNAL],0
    jne cg_reset_check
    mov r8,[rbx+CG_PARAM]
    xor ecx,ecx
cg_nlsf_guard:
    cmp word ptr [r8+DS_PREV+rcx*2],32767
    ja cg_bad
    inc ecx
    cmp ecx,r13d
    jb cg_nlsf_guard
    mov r8,[rbx+CG_CTRL]
    xor ecx,ecx
cg_gain_guard:
    cmp dword ptr [r8+DC_GAINS+rcx*4],0
    jle cg_bad
    inc ecx
    cmp ecx,[rbx+CG_SUBFR]
    jb cg_gain_guard
cg_reset_check:
    mov eax,[rbx+CG_FS]
    cmp eax,[rsi+CN_FS]
    je cg_update_check
    mov [rsi+CN_FS],eax
    mov eax,32767
    lea ecx,[r13+1]
    xor edx,edx
    div ecx
    mov r8d,eax               ;uniform NLSF step
    xor ecx,ecx
    xor eax,eax
cg_reset_nlsf:
    add eax,r8d
    mov [rsi+CN_NLSF+rcx*2],ax
    inc ecx
    cmp ecx,r13d
    jb cg_reset_nlsf
    mov dword ptr [rsi+CN_GAIN],0
    mov dword ptr [rsi+CN_RNG],3176576
cg_update_check:
    cmp dword ptr [r15+CS_LOSS],0
    jne cg_synthesis
    cmp dword ptr [r15+CS_SIGNAL],0
    jne cg_clear_synthesis
    mov r8,[rbx+CG_PARAM]
    xor ecx,ecx
cg_smooth_nlsf:
    movsx eax,word ptr [r8+DS_PREV+rcx*2]
    movsx edx,word ptr [rsi+CN_NLSF+rcx*2]
    sub eax,edx
    imul eax,16348
    sar eax,16
    add eax,edx
    mov [rsi+CN_NLSF+rcx*2],ax
    inc ecx
    cmp ecx,r13d
    jb cg_smooth_nlsf
    mov r8,[rbx+CG_CTRL]
    xor ecx,ecx
    xor edx,edx               ;highest gain
    xor r9d,r9d               ;chosen subframe
cg_choose_subframe:
    mov eax,[r8+DC_GAINS+rcx*4]
    cmp eax,edx
    jle cg_choose_next
    mov edx,eax
    mov r9d,ecx
cg_choose_next:
    inc ecx
    cmp ecx,[rbx+CG_SUBFR]
    jb cg_choose_subframe
    imul r10d,dword ptr [rbx+CG_FS],5
    mov ecx,[rbx+CG_SUBFR]
    dec ecx
    imul ecx,r10d
    ; Backward memmove of excitation history by one subframe.
cg_move_excitation:
    dec ecx
    mov eax,[rsi+CN_EXC+rcx*4]
    lea edx,[rcx+r10]
    mov [rsi+CN_EXC+rdx*4],eax
    test ecx,ecx
    jnz cg_move_excitation
    imul r9d,r10d
    lea r9,[r15+CS_EXC+r9*4]
    xor ecx,ecx
cg_copy_excitation:
    mov eax,[r9+rcx*4]
    mov [rsi+CN_EXC+rcx*4],eax
    inc ecx
    cmp ecx,r10d
    jb cg_copy_excitation
    xor ecx,ecx
cg_smooth_gain:
    mov eax,[r8+DC_GAINS+rcx*4]
    sub eax,[rsi+CN_GAIN]
    movsxd rax,eax
    imul rax,4634
    sar rax,16
    add [rsi+CN_GAIN],eax
    inc ecx
    cmp ecx,[rbx+CG_SUBFR]
    jb cg_smooth_gain
cg_clear_synthesis:
    xor ecx,ecx
cg_clear_history:
    mov dword ptr [rsi+CN_SYN+rcx*4],0
    inc ecx
    cmp ecx,r13d
    jb cg_clear_history
    jmp cg_good
cg_synthesis:
    mov r8d,255
cg_noise_mask:
    cmp r8d,r14d
    jle cg_noise_start
    shr r8d,1
    jmp cg_noise_mask
cg_noise_start:
    mov ecx,[rsi+CN_RNG]
    mov r10d,[rsi+CN_GAIN]
    sar r10d,4
    xor r9d,r9d
cg_noise_sample:
    imul ecx,ecx,196314165
    add ecx,907633515
    mov eax,ecx
    sar eax,24
    and eax,r8d
    movsxd rax,dword ptr [rsi+CN_EXC+rax*4]
    imul rax,r10
    sar rax,16
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov [r12+CW_SIG+64+r9*4],eax
    inc r9d
    cmp r9d,r14d
    jb cg_noise_sample
    mov [rsi+CN_RNG],ecx
    lea rax,[rsi+CN_NLSF]
    mov [rsp+32+SA_NLSF],rax
    lea rax,[r12+CW_COEF]
    mov [rsp+32+SA_OUT],rax
    mov [rsp+32+SA_ORDER],r13d
    mov [rsp+32+SA_IN_CAP],r13d
    mov [rsp+32+SA_OUT_CAP],r13d
    lea rcx,[rsp+32]
    call op_silk_nlsf2a
    xor ecx,ecx
cg_copy_synthesis:
    mov eax,[rsi+CN_SYN+rcx*4]
    mov [r12+CW_SIG+rcx*4],eax
    inc ecx
    cmp ecx,16
    jb cg_copy_synthesis
    xor r8d,r8d
cg_filter_sample:
    mov r11d,r13d
    shr r11d,1
    xor ecx,ecx
cg_filter_tap:
    lea edx,[r8+15]
    sub edx,ecx
    movsxd rax,dword ptr [r12+CW_SIG+rdx*4]
    movsx rdx,word ptr [r12+CW_COEF+rcx*2]
    imul rax,rdx
    sar rax,16
    add r11d,eax
    inc ecx
    cmp ecx,r13d
    jb cg_filter_tap
    mov eax,r11d
    shl eax,4
    add [r12+CW_SIG+64+r8*4],eax
    mov eax,r11d
    sar eax,5
    inc eax
    sar eax,1
    movsx edx,word ptr [rdi+r8*2]
    add eax,edx
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov [rdi+r8*2],ax
    inc r8d
    cmp r8d,r14d
    jb cg_filter_sample
    xor ecx,ecx
    mov r8d,r14d
cg_save_synthesis:
    mov eax,[r12+CW_SIG+r8*4]
    mov [rsi+CN_SYN+rcx*4],eax
    inc r8d
    inc ecx
    cmp ecx,16
    jb cg_save_synthesis
cg_good:
    mov eax,1
    jmp cg_done
cg_bad:
    xor eax,eax
cg_done:
    add rsp,64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_cng ENDP
END
