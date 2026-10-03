; Original x86-64 SILK excitation pulse, shell-tree, LSB and sign decoder.
; Algorithm/table reference: normative RFC6716 SILK. BSD notice in
; THIRD_PARTY_NOTICES. Audio synthesis and resampling are separate stages.
option casemap:none
EXTERN op_ec_icdf:PROC
PUBLIC op_silk_shell, op_silk_pulses
.const
include opus_silk_tables.inc
.code
; RCX=out, RDX=ec, R8D=sum, R9D=number of leaves (power of 2, <=16).
op_silk_shell_node PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,40
    mov rbx,rcx
    mov rsi,rdx
    mov edi,r8d
    mov r12d,r9d
    cmp r12d,1
    je op_silk_leaf
    test edi,edi
    jz op_silk_shell_zero
    bsr eax,r12d
    dec eax
    lea rdx,op_silk_shell_ptr
    mov rdx,[rdx+rax*8]
    lea rax,op_silk_shell_offsets
    movzx eax,byte ptr [rax+rdi]
    add rdx,rax
    mov rcx,rsi
    mov r8d,8
    call op_ec_icdf
    mov [rsp+32],eax
    shr r12d,1
    mov r8d,eax
    mov rcx,rbx
    mov rdx,rsi
    mov r9d,r12d
    call op_silk_shell_node
    lea rcx,[rbx+r12*4]
    mov rdx,rsi
    mov r8d,edi
    sub r8d,[rsp+32]
    mov r9d,r12d
    call op_silk_shell_node
    jmp op_silk_shell_done
op_silk_leaf:
    mov [rbx],edi
    jmp op_silk_shell_done
op_silk_shell_zero:
    mov rdi,rbx
    mov ecx,r12d
    xor eax,eax
    rep stosd
op_silk_shell_done:
    add rsp,40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_shell_node ENDP

; RCX=16 pulse integers, RDX=ec, R8D=pulse sum 0..16.
op_silk_shell PROC
    cmp r8d,16
    ja op_silk_shell_bad
    mov r9d,16
    jmp op_silk_shell_node
op_silk_shell_bad:
    xor eax,eax
    ret
op_silk_shell ENDP

; RCX=ec, RDX=out[ceil(frame_length/16)*16], R8D=signal type 0..2,
; R9D=quantization offset 0..1, stack argument=frame_length (80..320).
; Valid frame lengths: 80,120,160,240,320. Returns 1, invalid params 0.
op_silk_pulses PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,256
    mov rsi,rcx
    mov rdi,rdx
    mov r12d,r8d
    mov r13d,r9d
    mov eax,[rsp+352]
    cmp r12d,2
    ja op_silk_pulses_bad
    cmp r13d,1
    ja op_silk_pulses_bad
    cmp eax,80
    je op_silk_length_ok
    cmp eax,120
    je op_silk_length_ok
    cmp eax,160
    je op_silk_length_ok
    cmp eax,240
    je op_silk_length_ok
    cmp eax,320
    jne op_silk_pulses_bad
op_silk_length_ok:
    add eax,15
    shr eax,4
    mov r14d,eax
    mov eax,r12d
    shl eax,1
    add eax,r13d
    imul eax,7
    lea rcx,op_silk_sign_pdf
    add rcx,rax
    mov [rsp+232],rcx
    mov eax,r12d
    shr eax,1
    imul eax,9
    lea rdx,op_silk_rate_pdf
    add rdx,rax
    mov rcx,rsi
    mov r8d,8
    call op_ec_icdf
    imul eax,18
    lea rcx,op_silk_sum_pdf
    add rcx,rax
    mov [rsp+240],rcx
    xor r15d,r15d
op_silk_sums:
    mov dword ptr [rsp+r15*4+144],0
    mov rcx,rsi
    mov rdx,[rsp+240]
    mov r8d,8
    call op_ec_icdf
op_silk_escape_check:
    cmp eax,17
    jne op_silk_sum_store
    inc dword ptr [rsp+r15*4+144]
    mov rcx,rsi
    lea rdx,op_silk_sum_pdf+162
    cmp dword ptr [rsp+r15*4+144],10
    jne op_silk_escape_table
    inc rdx
op_silk_escape_table:
    mov r8d,8
    call op_ec_icdf
    jmp op_silk_escape_check
op_silk_sum_store:
    mov [rsp+r15*4+64],eax
    inc r15d
    cmp r15d,r14d
    jb op_silk_sums
    xor r15d,r15d
op_silk_shells:
    mov eax,r15d
    shl eax,6
    lea rcx,[rdi+rax]
    mov rdx,rsi
    mov r8d,[rsp+r15*4+64]
    call op_silk_shell
    inc r15d
    cmp r15d,r14d
    jb op_silk_shells
    xor r15d,r15d
op_silk_lsb_block:
    mov r12d,[rsp+r15*4+144]
    test r12d,r12d
    jz op_silk_lsb_next
    xor ebx,ebx
op_silk_lsb_sample:
    mov eax,r15d
    shl eax,4
    add eax,ebx
    mov r13d,[rdi+rax*4]
    mov [rsp+224],eax
    mov [rsp+228],r12d
op_silk_lsb_bit:
    mov rcx,rsi
    lea rdx,op_silk_lsb_pdf
    mov r8d,8
    call op_ec_icdf
    lea r13d,[r13*2+rax]
    dec dword ptr [rsp+228]
    jnz op_silk_lsb_bit
    mov eax,[rsp+224]
    mov [rdi+rax*4],r13d
    inc ebx
    cmp ebx,16
    jb op_silk_lsb_sample
    mov eax,r12d
    shl eax,5
    or [rsp+r15*4+64],eax
op_silk_lsb_next:
    inc r15d
    cmp r15d,r14d
    jb op_silk_lsb_block
    xor r15d,r15d
    mov word ptr [rsp+48],0
op_silk_sign_block:
    mov eax,[rsp+r15*4+64]
    test eax,eax
    jz op_silk_sign_next
    and eax,31
    mov edx,6
    cmp eax,edx
    cmova eax,edx
    mov rcx,[rsp+232]
    mov al,[rcx+rax]
    mov [rsp+48],al
    xor ebx,ebx
op_silk_sign_sample:
    mov eax,r15d
    shl eax,4
    add eax,ebx
    mov r12d,eax
    cmp dword ptr [rdi+rax*4],0
    jle op_silk_sign_sample_next
    mov rcx,rsi
    lea rdx,[rsp+48]
    mov r8d,8
    call op_ec_icdf
    test eax,eax
    jnz op_silk_sign_sample_next
    neg dword ptr [rdi+r12*4]
op_silk_sign_sample_next:
    inc ebx
    cmp ebx,16
    jb op_silk_sign_sample
op_silk_sign_next:
    inc r15d
    cmp r15d,r14d
    jb op_silk_sign_block
    mov eax,1
    jmp op_silk_pulses_done
op_silk_pulses_bad:
    xor eax,eax
op_silk_pulses_done:
    add rsp,256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_pulses ENDP
END
