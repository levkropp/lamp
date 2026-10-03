; Handwritten x86-64 Opus range decoder. Reference: RFC6716 entdec.c/entcode.c.
; Algorithm attribution and RFC BSD notice: see THIRD_PARTY_NOTICES.
option casemap:none
PUBLIC op_ec_init, op_ec_decode, op_ec_bin, op_ec_update, op_ec_logp
PUBLIC op_ec_icdf, op_ec_bits, op_ec_uint, op_ec_tell, op_ec_frac
EC_BUF EQU 0
EC_SIZE EQU 8
EC_END EQU 12
EC_WINDOW EQU 16
EC_NEND EQU 20
EC_TOTAL EQU 24
EC_OFF EQU 28
EC_RNG EQU 32
EC_VAL EQU 36
EC_EXT EQU 40
EC_REM EQU 44
EC_ERROR EQU 48
.code
; RCX=context. End-of-frame zero padding is normative, not a bounds failure.
op_ec_normalize PROC
    mov r8d,[rcx+EC_RNG]
    test r8d,r8d
    jz op_ec_zero_range
    mov r9d,[rcx+EC_VAL]
op_ec_normalize_loop:
    cmp r8d,800000h
    ja op_ec_normalize_done
    add dword ptr [rcx+EC_TOTAL],8
    shl r8d,8
    mov eax,[rcx+EC_REM]
    shl eax,8
    mov edx,[rcx+EC_OFF]
    cmp edx,[rcx+EC_SIZE]
    jae op_ec_padding
    push rax
    mov rax,[rcx+EC_BUF]
    movzx edx,byte ptr [rax+rdx]
    pop rax
    inc dword ptr [rcx+EC_OFF]
    jmp op_ec_symbol
op_ec_padding:
    xor edx,edx
op_ec_symbol:
    mov [rcx+EC_REM],edx
    or eax,edx
    shr eax,1
    not eax
    and eax,255
    shl r9d,8
    add r9d,eax
    and r9d,7fffffffh
    jmp op_ec_normalize_loop
op_ec_normalize_done:
    mov [rcx+EC_RNG],r8d
    mov [rcx+EC_VAL],r9d
    ret
op_ec_zero_range:
    mov dword ptr [rcx+EC_ERROR],1
    ret
op_ec_normalize ENDP

; RCX=context (64 bytes), RDX=frame bytes, R8D=byte length.
op_ec_init PROC
    mov [rcx+EC_BUF],rdx
    mov [rcx+EC_SIZE],r8d
    mov qword ptr [rcx+EC_END],0
    mov dword ptr [rcx+EC_NEND],0
    mov dword ptr [rcx+EC_TOTAL],9
    mov dword ptr [rcx+EC_OFF],0
    mov dword ptr [rcx+EC_RNG],128
    mov dword ptr [rcx+EC_ERROR],0
    mov dword ptr [rcx+EC_EXT],0
    xor eax,eax
    test r8d,r8d
    jz op_ec_init_empty
    movzx eax,byte ptr [rdx]
    mov dword ptr [rcx+EC_OFF],1
op_ec_init_empty:
    mov [rcx+EC_REM],eax
    shr eax,1
    mov edx,127
    sub edx,eax
    mov [rcx+EC_VAL],edx
    jmp op_ec_normalize
op_ec_init ENDP

; RCX=context, EDX=total frequency -> EAX=cumulative frequency.
op_ec_decode PROC
    mov r8d,edx
    test edx,edx
    jz op_ec_decode_bad
    mov eax,[rcx+EC_RNG]
    xor edx,edx
    div r8d
    test eax,eax
    jz op_ec_decode_bad
    mov [rcx+EC_EXT],eax
    mov r9d,eax
    mov eax,[rcx+EC_VAL]
    xor edx,edx
    div r9d
    inc eax
    cmp eax,r8d
    cmova eax,r8d
    sub r8d,eax
    mov eax,r8d
    ret
op_ec_decode_bad:
    mov dword ptr [rcx+EC_ERROR],1
    xor eax,eax
    ret
op_ec_decode ENDP
op_ec_bin PROC
    push rcx
    mov ecx,edx
    mov edx,1
    shl edx,cl
    pop rcx
    jmp op_ec_decode
op_ec_bin ENDP

; RCX=context, EDX=fl, R8D=fh, R9D=ft. Uses ext from op_ec_decode.
op_ec_update PROC
    mov eax,r9d
    sub eax,r8d
    imul eax,[rcx+EC_EXT]
    sub [rcx+EC_VAL],eax
    test edx,edx
    jz op_ec_update_zero
    sub r8d,edx
    imul r8d,[rcx+EC_EXT]
    mov [rcx+EC_RNG],r8d
    jmp op_ec_normalize
op_ec_update_zero:
    sub [rcx+EC_RNG],eax
    jmp op_ec_normalize
op_ec_update ENDP

; RCX=context, EDX=log2 reciprocal probability of one -> EAX=bit.
op_ec_logp PROC
    sub rsp,40
    mov r8d,[rcx+EC_RNG]
    mov r9d,[rcx+EC_VAL]
    push rcx
    mov ecx,edx
    mov eax,r8d
    shr eax,cl
    pop rcx
    xor r10d,r10d
    cmp r9d,eax
    setb r10b
    test r10d,r10d
    jnz op_ec_logp_one
    sub r9d,eax
    sub r8d,eax
    jmp op_ec_logp_store
op_ec_logp_one:
    mov r8d,eax
op_ec_logp_store:
    mov [rcx+EC_VAL],r9d
    mov [rcx+EC_RNG],r8d
    call op_ec_normalize
    mov eax,r10d
    add rsp,40
    ret
op_ec_logp ENDP

; RCX=context, RDX=ICDF bytes ending in zero, R8D=probability precision.
op_ec_icdf PROC
    push rbx
    push rsi
    sub rsp,40
    mov rsi,rcx
    mov rbx,rdx
    mov eax,[rsi+EC_RNG]
    mov r11d,eax
    mov ecx,r8d
    shr eax,cl
    mov r8d,eax
    mov r9d,[rsi+EC_VAL]
    xor r10d,r10d
op_ec_icdf_symbol:
    movzx eax,byte ptr [rbx+r10]
    imul eax,r8d
    cmp r9d,eax
    jae op_ec_icdf_found
    mov r11d,eax
    inc r10d
    cmp r10d,256
    jb op_ec_icdf_symbol
    mov dword ptr [rsi+EC_ERROR],1
    xor r10d,r10d
    jmp op_ec_icdf_return
op_ec_icdf_found:
    sub r9d,eax
    sub r11d,eax
    mov [rsi+EC_VAL],r9d
    mov [rsi+EC_RNG],r11d
    mov rcx,rsi
    call op_ec_normalize
op_ec_icdf_return:
    mov eax,r10d
    add rsp,40
    pop rsi
    pop rbx
    ret
op_ec_icdf ENDP

; RCX=context, EDX=0..25 raw bits, read backwards LSB first.
op_ec_bits PROC
    push rbx
    push rsi
    mov rsi,rcx
    mov ebx,edx
    mov r8d,[rsi+EC_WINDOW]
    mov r9d,[rsi+EC_NEND]
    cmp r9d,ebx
    jae op_ec_bits_extract
op_ec_bits_load:
    mov eax,[rsi+EC_END]
    cmp eax,[rsi+EC_SIZE]
    jae op_ec_bits_padding
    inc eax
    mov [rsi+EC_END],eax
    mov edx,[rsi+EC_SIZE]
    sub edx,eax
    mov rax,[rsi+EC_BUF]
    movzx eax,byte ptr [rax+rdx]
    jmp op_ec_bits_insert
op_ec_bits_padding:
    xor eax,eax
op_ec_bits_insert:
    mov ecx,r9d
    shl eax,cl
    or r8d,eax
    add r9d,8
    cmp r9d,24
    jbe op_ec_bits_load
op_ec_bits_extract:
    mov ecx,ebx
    mov eax,1
    shl eax,cl
    dec eax
    and eax,r8d
    shr r8d,cl
    sub r9d,ebx
    mov [rsi+EC_WINDOW],r8d
    mov [rsi+EC_NEND],r9d
    add [rsi+EC_TOTAL],ebx
    pop rsi
    pop rbx
    ret
op_ec_bits ENDP

; RCX=context, EDX=ft>1. Uniform integer up to 2^32-1 values.
op_ec_uint PROC
    push rbx
    push rsi
    push r12
    sub rsp,48
    mov rsi,rcx
    mov ebx,edx
    dec ebx
    bsr r12d,ebx
    inc r12d
    cmp r12d,8
    jbe op_ec_uint_small
    sub r12d,8
    mov eax,ebx
    mov ecx,r12d
    shr eax,cl
    inc eax
    mov [rsp+32],eax
    mov edx,eax
    jmp op_ec_uint_decode
op_ec_uint_small:
    mov dword ptr [rsp+32],edx
    xor r12d,r12d
op_ec_uint_decode:
    mov rcx,rsi
    call op_ec_decode
    mov [rsp+36],eax
    mov edx,eax
    lea r8d,[eax+1]
    mov r9d,[rsp+32]
    mov rcx,rsi
    call op_ec_update
    mov eax,[rsp+36]
    test r12d,r12d
    jz op_ec_uint_done
    mov ecx,r12d
    shl eax,cl
    mov [rsp+36],eax
    mov rcx,rsi
    mov edx,r12d
    call op_ec_bits
    or eax,[rsp+36]
    cmp eax,ebx
    jbe op_ec_uint_done
    mov eax,ebx
    mov dword ptr [rsi+EC_ERROR],1
op_ec_uint_done:
    add rsp,48
    pop r12
    pop rsi
    pop rbx
    ret
op_ec_uint ENDP

op_ec_tell PROC
    mov eax,[rcx+EC_RNG]
    bsr edx,eax
    inc edx
    mov eax,[rcx+EC_TOTAL]
    sub eax,edx
    ret
op_ec_tell ENDP
op_ec_frac PROC
    mov r8d,[rcx+EC_TOTAL]
    shl r8d,3
    mov eax,[rcx+EC_RNG]
    bsr edx,eax
    inc edx
    mov ecx,edx
    sub ecx,16
    shr eax,cl
    mov r9d,3
op_ec_frac_bit:
    imul eax,eax
    shr eax,15
    mov ecx,eax
    shr ecx,16
    shl edx,1
    or edx,ecx
    shr eax,cl
    dec r9d
    jnz op_ec_frac_bit
    mov eax,r8d
    sub eax,edx
    ret
op_ec_frac ENDP
END
