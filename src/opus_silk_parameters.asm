; Handwritten SILK gain and pitch/LTP parameter reconstruction.
; RFC6716 gain_quant.c,log2lin.c,decode_pitch.c,decode_parameters.c.
; Copyright(c)2006-2012 IETF Trust and Skype Limited, BSD conditions
; in THIRD_PARTY_NOTICES. Integer assembly only; no CRT/C runtime.
option casemap:none
include opus_silk_parameters_layout.inc
include opus_silk_indices_layout.inc
PUBLIC op_silk_log2lin, op_silk_gains, op_silk_pitch_ltp
.const
include opus_silk_parameters_tables.inc
.code
; ECX=Q7 log value, EAX=normative linear approximation. Negative values map
; to0; supported nonnegative range0..3967, higher values reject with0.
op_silk_log2lin PROC
    test ecx,ecx
    js sg_log_zero
    cmp ecx,3967
    ja sg_log_zero
    mov r9d,ecx
    mov r8d,ecx
    and r8d,127
    mov edx,128
    sub edx,r8d
    imul edx,r8d
    imul edx,edx,-174
    sar edx,16
    add r8d,edx
    sar ecx,7
    mov eax,1
    shl eax,cl
    mov edx,eax
    cmp r9d,2048
    jge sg_log_high
    imul edx,r8d
    sar edx,7
    add eax,edx
    ret
sg_log_high:
    sar edx,7
    imul edx,r8d
    add eax,edx
    ret
sg_log_zero:
    xor eax,eax
    ret
op_silk_log2lin ENDP

op_silk_gains PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,32
    mov rbx,rcx
    test rbx,rbx
    jz sg_bad
    mov rsi,[rbx+SG_IND]
    mov rdi,[rbx+SG_OUT]
    mov r12,[rbx+SG_PREV]
    test rsi,rsi
    jz sg_bad
    test rdi,rdi
    jz sg_bad
    test r12,r12
    jz sg_bad
    mov eax,[rbx+SG_SUBFR]
    cmp eax,2
    je sg_subfr
    cmp eax,4
    jne sg_bad
sg_subfr:
    cmp [rbx+SG_IND_CAP],eax
    jb sg_bad
    cmp [rbx+SG_OUT_CAP],eax
    jb sg_bad
    cmp dword ptr [rbx+SG_PREV_CAP],1
    jb sg_bad
    cmp dword ptr [rbx+SG_CONDITIONAL],1
    ja sg_bad
    cmp byte ptr [r12],63
    ja sg_bad
    xor ecx,ecx
sg_index_guard:
    movzx edx,byte ptr [rsi+rcx]
    test ecx,ecx
    jnz sg_delta_guard
    cmp dword ptr [rbx+SG_CONDITIONAL],0
    jne sg_delta_guard
    cmp edx,63
    ja sg_bad
    jmp sg_guard_next
sg_delta_guard:
    cmp edx,40
    ja sg_bad
sg_guard_next:
    inc ecx
    cmp ecx,eax
    jb sg_index_guard
    xor r13d,r13d
sg_subframe:
    movzx eax,byte ptr [rsi+r13]
    movzx edx,byte ptr [r12]
    test r13d,r13d
    jnz sg_delta
    cmp dword ptr [rbx+SG_CONDITIONAL],0
    jne sg_delta
    sub edx,16
    cmp eax,edx
    cmovl eax,edx
    jmp sg_clamp
sg_delta:
    sub eax,4
    lea r8d,[rdx+8]            ; threshold=2*36-64+last
    cmp eax,r8d
    jle sg_single_step
    add eax,eax
    sub eax,r8d
sg_single_step:
    add eax,edx
sg_clamp:
    xor edx,edx
    test eax,eax
    cmovs eax,edx
    mov edx,63
    cmp eax,edx
    cmovg eax,edx
    mov [r12],al
    imul ecx,eax,1907825       ; INV_SCALE_Q16
    sar ecx,16
    add ecx,2090               ; OFFSET
    mov eax,3967
    cmp ecx,eax
    cmovg ecx,eax
    call op_silk_log2lin
    mov [rdi+r13*4],eax
    inc r13d
    cmp r13d,[rbx+SG_SUBFR]
    jb sg_subframe
    mov eax,1
    jmp sg_done
sg_bad:
    xor eax,eax
sg_done:
    add rsp,32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_gains ENDP

op_silk_pitch_ltp PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rbx,rcx
    test rbx,rbx
    jz sp_bad
    mov rsi,[rbx+SP_IND]
    mov rdi,[rbx+SP_PITCH]
    mov r12,[rbx+SP_LTP]
    mov r13,[rbx+SP_SCALE]
    test rsi,rsi
    jz sp_bad
    test rdi,rdi
    jz sp_bad
    test r12,r12
    jz sp_bad
    test r13,r13
    jz sp_bad
    mov eax,[rbx+SP_FS]
    cmp eax,8
    je sp_rate
    cmp eax,12
    je sp_rate
    cmp eax,16
    jne sp_bad
sp_rate:
    mov ecx,[rbx+SP_SUBFR]
    cmp ecx,2
    je sp_subfr
    cmp ecx,4
    jne sp_bad
sp_subfr:
    cmp [rbx+SP_PITCH_CAP],ecx
    jb sp_bad
    imul edx,ecx,5
    cmp [rbx+SP_LTP_CAP],edx
    jb sp_bad
    cmp dword ptr [rbx+SP_SCALE_CAP],1
    jb sp_bad
    cmp byte ptr [rsi+SX_SIGNAL],2
    ja sp_bad
    jne sp_unvoiced
    lea r14,sp_contour
    mov r10d,34
    cmp ecx,4
    jne sp_choose10
    cmp eax,8
    jne sp_contour_chosen
    lea r14,sp_contour_nb
    mov r10d,11
    jmp sp_contour_chosen
sp_choose10:
    lea r14,sp_contour10
    mov r10d,12
    cmp eax,8
    jne sp_contour_chosen
    lea r14,sp_contour10_nb
    mov r10d,3
sp_contour_chosen:
    movzx eax,byte ptr [rsi+SX_CONTOUR]
    cmp eax,r10d
    jae sp_bad
    add r14,rax
    movzx eax,byte ptr [rsi+SX_PER]
    cmp eax,2
    ja sp_bad
    lea rdx,sp_ltp_ptr
    mov r15,[rdx+rax*8]
    mov ecx,eax
    mov r8d,8
    shl r8d,cl
    cmp byte ptr [rsi+SX_SCALE],2
    ja sp_bad
    xor ecx,ecx
sp_ltp_guard:
    movzx eax,byte ptr [rsi+SX_LTP+rcx]
    cmp eax,r8d
    jae sp_bad
    inc ecx
    cmp ecx,[rbx+SP_SUBFR]
    jb sp_ltp_guard
    mov r8d,[rbx+SP_FS]
    imul r9d,r8d,18            ; max18ms
    add r8d,r8d                ; min2ms
    movsx r11d,word ptr [rsi+SX_LAG]
    add r11d,r8d
    xor ecx,ecx
sp_pitch_loop:
    movsx eax,byte ptr [r14]
    add eax,r11d
    cmp eax,r8d
    cmovl eax,r8d
    cmp eax,r9d
    cmovg eax,r9d
    mov [rdi+rcx*4],eax
    add r14,r10
    inc ecx
    cmp ecx,[rbx+SP_SUBFR]
    jb sp_pitch_loop
    xor r8d,r8d
sp_ltp_subframe:
    movzx eax,byte ptr [rsi+SX_LTP+r8]
    imul eax,5
    lea r9,[r15+rax]
    imul eax,r8d,5
    lea r10,[r12+rax*2]
    xor ecx,ecx
sp_ltp_tap:
    movsx eax,byte ptr [r9+rcx]
    shl eax,7
    mov [r10+rcx*2],ax
    inc ecx
    cmp ecx,5
    jb sp_ltp_tap
    inc r8d
    cmp r8d,[rbx+SP_SUBFR]
    jb sp_ltp_subframe
    movzx eax,byte ptr [rsi+SX_SCALE]
    lea rdx,sp_scales
    movsx eax,word ptr [rdx+rax*2]
    mov [r13],eax
    jmp sp_good
sp_unvoiced:
    xor ecx,ecx
sp_clear_pitch:
    mov dword ptr [rdi+rcx*4],0
    inc ecx
    cmp ecx,[rbx+SP_SUBFR]
    jb sp_clear_pitch
    imul edx,ecx,5
    xor ecx,ecx
sp_clear_ltp:
    mov word ptr [r12+rcx*2],0
    inc ecx
    cmp ecx,edx
    jb sp_clear_ltp
    mov dword ptr [r13],0
sp_good:
    mov eax,1
    jmp sp_done
sp_bad:
    xor eax,eax
sp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_pitch_ltp ENDP
END
