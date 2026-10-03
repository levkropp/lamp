; Original x86-64 CELT Haar and Hadamard layout transformations.
; Reference: BSD normative RFC6716 bands.c, see THIRD_PARTY_NOTICES.
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
option casemap:none
PUBLIC op_celt_haar, op_celt_reorder
.const
ob_sqrt_half real4 0.70710678
; The order is the bit-reversed Gray-code order in the normative reference.
ob_order dd 1,0,3,0,2,1,7,0,4,3,6,1,5,2
    dd 15,0,8,7,12,3,11,4,14,1,9,6,13,2,10,5
.data?
ALIGN 16
ob_scratch dd 1024 dup (?)
.code
; RCX=X, EDX=N0 (even), R8D=stride. Caller supplies finite normalized data.
; Total size N0*stride <= 1024. EAX=1 success / 0 invalid.
op_celt_haar PROC
    test rcx,rcx
    jz ob_haar_bad
    cmp edx,2
    jb ob_haar_bad
    cmp edx,1024
    ja ob_haar_bad
    test edx,1
    jnz ob_haar_bad
    cmp r8d,1
    jb ob_haar_bad
    cmp r8d,1024
    ja ob_haar_bad
    mov eax,edx
    imul eax,r8d
    cmp eax,1024
    ja ob_haar_bad
    shr edx,1
    xor r9d,r9d
    movss xmm2,dword ptr [ob_sqrt_half]
ob_haar_lane:
    xor r10d,r10d
ob_haar_pair:
    lea eax,[r10*2]
    imul eax,r8d
    add eax,r9d
    movss xmm0,dword ptr [rcx+rax*4]
    lea r11,[rcx+r8*4]
    movss xmm1,dword ptr [r11+rax*4]
    mulss xmm0,xmm2
    mulss xmm1,xmm2
    movaps xmm3,xmm0
    addss xmm3,xmm1
    subss xmm0,xmm1
    movss dword ptr [rcx+rax*4],xmm3
    movss dword ptr [r11+rax*4],xmm0
    inc r10d
    cmp r10d,edx
    jb ob_haar_pair
    inc r9d
    cmp r9d,r8d
    jb ob_haar_lane
    mov eax,1
    ret
ob_haar_bad:
    xor eax,eax
    ret
op_celt_haar ENDP

; RCX=request: X*q0, N0*d8, stride*d12, hadamard*d16, inverse*d20.
; stride is 1/2/4/8/16; hadamard requires stride >=2.
; inverse=0 deinterleaves, inverse=1 interleaves. EAX=1/0.
; Preserves raw float bits. Bounded single-producer scratch, no heap allocation.
op_celt_reorder PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    test rcx,rcx
    jz ob_reorder_bad
    mov rbx,[rcx]
    mov r12d,[rcx+8]
    mov r8d,[rcx+12]
    mov r9d,[rcx+16]
    mov r10d,[rcx+20]
    test rbx,rbx
    jz ob_reorder_bad
    cmp r12d,1
    jb ob_reorder_bad
    cmp r12d,1024
    ja ob_reorder_bad
    cmp r8d,1
    jb ob_reorder_bad
    cmp r8d,16
    ja ob_reorder_bad
    lea eax,[r8-1]
    test eax,r8d
    jnz ob_reorder_bad
    cmp r9d,1
    ja ob_reorder_bad
    cmp r10d,1
    ja ob_reorder_bad
    test r9d,r9d
    jz ob_reorder_size
    cmp r8d,2
    jb ob_reorder_bad
ob_reorder_size:
    mov eax,r12d
    imul eax,r8d
    cmp eax,1024
    ja ob_reorder_bad
    mov edx,eax
    lea rdi,ob_scratch
    xor esi,esi
ob_reorder_lane:
    lea r11,ob_order
    mov eax,esi
    test r9d,r9d
    jz ob_reorder_ordered
    lea ecx,[r8+rsi-2]
    mov eax,[r11+rcx*4]
ob_reorder_ordered:
    imul eax,r12d
    mov ecx,eax            ; ordered chunk index
    mov eax,esi           ; interleaved lane index
    xor r13d,r13d
ob_reorder_bin:
    test r10d,r10d
    jnz ob_reorder_inverse
    mov r11d,[rbx+rax*4]
    mov [rdi+rcx*4],r11d
    jmp ob_reorder_next
ob_reorder_inverse:
    mov r11d,[rbx+rcx*4]
    mov [rdi+rax*4],r11d
ob_reorder_next:
    inc ecx
    add eax,r8d
    inc r13d
    cmp r13d,r12d
    jb ob_reorder_bin
    inc esi
    cmp esi,r8d
    jb ob_reorder_lane
    mov rsi,rdi
    mov rdi,rbx
    mov ecx,edx
    rep movsd
    mov eax,1
    jmp ob_reorder_done
ob_reorder_bad:
    xor eax,eax
    jmp ob_reorder_done
ob_reorder_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_reorder ENDP
END
