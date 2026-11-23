# Original movie-fragment defaults, byte placement and decode-time expansion.
.macro VM_BE32 reg, bad
    mov rax, rdi
    sub rax, rsi
    cmp rax, 4
    jb \bad
    mov \reg, [rsi]
    bswap \reg
    add rsi, 4
.endm
.macro VM_BE64 reg, bad
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jb \bad
    mov \reg, [rsi]
    bswap \reg
    add rsi, 8
.endm

LOCALFN vm_fragments
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov rdx, [rbx+VM_MOOV]
    mov r8, [rbx+VM_MOOV_END]
    mov r9d, VM_MVEX_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_fragments_no_mvex
    mov rcx, rbx
    mov r8, rdx
    mov rdx, rax
    call vm_trex
    test eax, eax
    jz .Lvm_fragments_return
    mov rsi, [rbx+VM_BEGIN]
    mov rdi, [rbx+VM_END]
.Lvm_fragments_next:
    cmp rsi, rdi
    je .Lvm_fragments_ok
    mov r12, rsi
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_fragments_return
    mov rsi, r8
    cmp eax, VM_MOOF_TYPE
    jne .Lvm_fragments_next
    mov rcx, rbx
    mov r9, r12
    sub r9, [rbx+VM_BEGIN]
    call vm_moof
    test eax, eax
    jz .Lvm_fragments_return
    jmp .Lvm_fragments_next
.Lvm_fragments_no_mvex:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_fragments_zero
    cmp dword ptr [rbx+VM_FRAGMENTED], 0
    jne .Lvm_fragments_bad
.Lvm_fragments_ok:
    mov eax, 1
    jmp .Lvm_fragments_return
.Lvm_fragments_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_fragments_zero:
    xor eax, eax
.Lvm_fragments_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_fragments

# All tracks' defaults are needed for implicit bases following ignored trafs.
LOCALFN vm_trex
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
.Lvm_trex_next:
    cmp rsi, rdi
    je .Lvm_trex_ok
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_trex_return
    mov rsi, r8
    cmp eax, VM_TREX_TYPE
    jne .Lvm_trex_next
    sub r8, rdx
    cmp r8, 24
    jne .Lvm_trex_bad
    cmp dword ptr [rdx], 0
    jne .Lvm_trex_bad
    mov r9d, [rdx+4]
    bswap r9d
    xor ecx, ecx
.Lvm_trex_track:
    cmp ecx, [rbx+VM_TRACK_COUNT]
    jae .Lvm_trex_bad
    cmp r9d, [rbx+rcx*4+VM_TRACK_IDS]
    je .Lvm_trex_unique_start
    inc ecx
    jmp .Lvm_trex_track
.Lvm_trex_unique_start:
    xor ecx, ecx
.Lvm_trex_unique:
    cmp ecx, [rbx+VM_TREX_COUNT]
    jae .Lvm_trex_store
    imul rax, rcx, 24
    cmp r9d, [rbx+rax+VM_TREX]
    je .Lvm_trex_bad
    inc ecx
    jmp .Lvm_trex_unique
.Lvm_trex_store:
    cmp ecx, 256
    jae .Lvm_trex_limit
    cmp dword ptr [rdx+8], 0
    je .Lvm_trex_bad
    imul rax, rcx, 24
    lea r10, [rbx+rax+VM_TREX]
    mov [r10], r9d
    mov eax, [rdx+8]
    bswap eax
    mov [r10+4], eax
    mov eax, [rdx+12]
    bswap eax
    mov [r10+8], eax
    mov eax, [rdx+16]
    bswap eax
    mov [r10+12], eax
    mov eax, [rdx+20]
    bswap eax
    mov [r10+16], eax
    inc dword ptr [rbx+VM_TREX_COUNT]
    jmp .Lvm_trex_next
.Lvm_trex_ok:
    mov eax, 1
    jmp .Lvm_trex_return
.Lvm_trex_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_trex_zero
.Lvm_trex_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_trex_zero:
    xor eax, eax
.Lvm_trex_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_trex

# RCX=ctx,RDX/R8=moof payload/end,R9=moof's file-relative start.
LOCALFN vm_moof
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov [rsp+32], r9
    mov [rsp+40], r9
    mov r9d, VM_MFHD_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_moof_bad
    sub rdx, rax
    cmp rdx, 8
    jne .Lvm_moof_bad
    cmp dword ptr [rax], 0
    jne .Lvm_moof_bad
.Lvm_moof_next:
    cmp rsi, rdi
    je .Lvm_moof_ok
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_moof_return
    mov rsi, r8
    cmp eax, VM_TRAF_TYPE
    jne .Lvm_moof_next
    mov rcx, rbx
    lea r9, [rsp+32]
    call vm_traf
    test eax, eax
    jz .Lvm_moof_return
    jmp .Lvm_moof_next
.Lvm_moof_ok:
    mov eax, 1
    jmp .Lvm_moof_return
.Lvm_moof_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_moof_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_moof_zero:
    xor eax, eax
.Lvm_moof_return:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_moof

.include "video_mp4_traf.inc"
