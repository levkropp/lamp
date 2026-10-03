; Original x86-64 CELT signed-pulse enumeration. Algorithm: RFC6716 cwrs.c.
; General small-footprint recurrence, unsigned 32-bit arithmetic throughout.
; Reference license and algorithm attribution: THIRD_PARTY_NOTICES.
option casemap:none
EXTERN op_ec_uint:PROC
PUBLIC op_cwrs_urow, op_cwrs_decode, op_decode_pulses
.data?
op_cwrs_workspace dd 32769 dup (?)
.code
; RCX=row, EDX=length, R8D=initial -> next row, in place.
op_cwrs_next PROC
    mov r9d,1
op_cwrs_next_loop:
    mov eax,[rcx+r9*4]
    add eax,[rcx+r9*4-4]
    add eax,r8d
    mov [rcx+r9*4-4],r8d
    mov r8d,eax
    inc r9d
    cmp r9d,edx
    jb op_cwrs_next_loop
    mov [rcx+r9*4-4],r8d
    ret
op_cwrs_next ENDP

; ECX=N>=2, EDX=K>=1, R8=row[K+2] -> EAX=V(N,K).
; Caller ensures the unsigned enumeration fits in 32 bits.
op_cwrs_urow PROC
    push rbx
    push rsi
    push rdi
    sub rsp,32
    mov ebx,ecx
    mov esi,edx
    mov rdi,r8
    mov dword ptr [rdi],0
    mov dword ptr [rdi+4],1
    mov ecx,2
    lea edx,[rsi+2]
op_cwrs_init:
    lea eax,[rcx+rcx-1]
    mov [rdi+rcx*4],eax
    inc ecx
    cmp ecx,edx
    jb op_cwrs_init
    sub ebx,2
    jle op_cwrs_count
op_cwrs_build:
    lea rcx,[rdi+4]
    lea edx,[rsi+1]
    mov r8d,1
    call op_cwrs_next
    dec ebx
    jnz op_cwrs_build
op_cwrs_count:
    mov eax,[rdi+rsi*4]
    add eax,[rdi+rsi*4+4]
    add rsp,32
    pop rdi
    pop rsi
    pop rbx
    ret
op_cwrs_urow ENDP

; ECX=N, EDX=K, R8D=index, R9=output[N], [rsp+40]=row[K+2].
; Destructively consumes the row; output has sum(abs(pulse)) exactly K.
op_cwrs_decode PROC
    push rbx
    push rsi
    push rdi
    push r12
    mov ebx,ecx
    mov esi,edx
    mov edi,r8d
    mov r12,[rsp+72]
op_cwrs_coordinate:
    mov eax,[r12+rsi*4+4]
    xor edx,edx
    cmp edi,eax
    jb op_cwrs_positive
    mov edx,-1
    sub edi,eax
op_cwrs_positive:
    mov r8d,esi
    mov eax,[r12+rsi*4]
op_cwrs_search:
    cmp eax,edi
    jbe op_cwrs_found
    dec esi
    mov eax,[r12+rsi*4]
    jmp op_cwrs_search
op_cwrs_found:
    sub edi,eax
    sub r8d,esi
    add r8d,edx
    xor r8d,edx
    mov [r9],r8d
    add r9,4
    ; U(N-1,k) = U(N,k)-U(N,k-1)-U(N-1,k-1).
    lea ecx,[rsi+2]
    xor edx,edx
    mov r8d,1
op_cwrs_previous:
    mov eax,[r12+r8*4]
    sub eax,[r12+r8*4-4]
    sub eax,edx
    mov [r12+r8*4-4],edx
    mov edx,eax
    inc r8d
    cmp r8d,ecx
    jb op_cwrs_previous
    mov [r12+r8*4-4],edx
    dec ebx
    jnz op_cwrs_coordinate
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_cwrs_decode ENDP

; RCX=output, EDX=N>=2, R8D=K, R9=range context -> EAX=1/0.
; Scratch is single-instance, like the rest of the decoder; no per-frame heap.
op_decode_pulses PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,56
    mov rbx,rcx
    mov esi,edx
    mov edi,r8d
    mov r12,r9
    cmp esi,2
    jb op_pulses_bad
    cmp esi,1024
    ja op_pulses_bad
    cmp edi,1
    jb op_pulses_bad
    cmp edi,32767
    ja op_pulses_bad
    mov ecx,esi
    mov edx,edi
    lea r8,op_cwrs_workspace
    call op_cwrs_urow
    test eax,eax
    jz op_pulses_bad
    mov edx,eax
    mov rcx,r12
    call op_ec_uint
    mov r8d,eax
    mov ecx,esi
    mov edx,edi
    mov r9,rbx
    lea rax,op_cwrs_workspace
    mov [rsp+32],rax
    call op_cwrs_decode
    mov eax,1
    jmp op_pulses_done
op_pulses_bad:
    xor eax,eax
op_pulses_done:
    add rsp,56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_decode_pulses ENDP
END
