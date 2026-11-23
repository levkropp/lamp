# Original track-fragment field and run expansion. Included after VM_BE macros.

# RCX=ctx,RDX/R8=traf payload/end,R9=&{moof offset,previous traf data end}.
LOCALFN vm_traf
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 120
    mov rbx, rcx
    mov [rsp+32], r9
    mov [rsp+40], rdx
    mov [rsp+48], r8
    mov r9d, VM_TFHD_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_traf_bad
    mov rsi, rax
    mov rdi, rdx
    sub rdx, rax
    cmp rdx, 8
    jb .Lvm_traf_bad
    cmp byte ptr [rsi], 0
    jne .Lvm_traf_unsupported
    mov ebp, [rsi]
    bswap ebp
    test ebp, 0xfffcffc4
    jnz .Lvm_traf_unsupported
    mov r15d, [rsi+4]
    bswap r15d
    mov [rsp+96], r15d
    xor ecx, ecx
.Lvm_traf_track:
    cmp ecx, [rbx+VM_TRACK_COUNT]
    jae .Lvm_traf_bad
    cmp r15d, [rbx+rcx*4+VM_TRACK_IDS]
    je .Lvm_traf_defaults
    inc ecx
    jmp .Lvm_traf_track
.Lvm_traf_defaults:
    mov dword ptr [rsp+80], 1
    mov dword ptr [rsp+84], 0
    mov qword ptr [rsp+88], 0
    mov dword ptr [rsp+100], 0
    mov eax, ebp
    and eax, 0x10000
    mov [rsp+104], eax
    mov dword ptr [rsp+108], 0
    xor ecx, ecx
.Lvm_traf_trex:
    cmp ecx, [rbx+VM_TREX_COUNT]
    jae .Lvm_traf_base
    imul rax, rcx, 24
    lea rdx, [rbx+rax+VM_TREX]
    cmp r15d, [rdx]
    je .Lvm_traf_trex_found
    inc ecx
    jmp .Lvm_traf_trex
.Lvm_traf_trex_found:
    movdqu xmm0, [rdx+4]
    movdqu [rsp+80], xmm0
.Lvm_traf_base:
    add rsi, 8
    mov rax, [rsp+32]
    mov r12, [rax+8]
    test ebp, 0x20000
    jz .Lvm_traf_explicit
    mov r12, [rax]
.Lvm_traf_explicit:
    test ebp, 1
    jz .Lvm_traf_index
    VM_BE64 r12,.Lvm_traf_bad
.Lvm_traf_index:
    mov [rsp+56], r12
    mov [rsp+64], r12
    test ebp, 2
    jz .Lvm_traf_duration
    VM_BE32 r12d,.Lvm_traf_bad
    mov [rsp+80], r12d
.Lvm_traf_duration:
    test ebp, 8
    jz .Lvm_traf_size
    VM_BE32 r12d,.Lvm_traf_bad
    mov [rsp+84], r12d
.Lvm_traf_size:
    test ebp, 16
    jz .Lvm_traf_flags
    VM_BE32 r12d,.Lvm_traf_bad
    mov [rsp+88], r12d
.Lvm_traf_flags:
    test ebp, 32
    jz .Lvm_traf_fields_done
    VM_BE32 r12d,.Lvm_traf_bad
    mov [rsp+92], r12d
.Lvm_traf_fields_done:
    cmp rsi, rdi
    jne .Lvm_traf_bad
    cmp dword ptr [rsp+80], 0
    je .Lvm_traf_bad
    mov qword ptr [rsp+72], 0
    cmp r15d, [rbx+VM_TRACK_ID]
    jne .Lvm_traf_runs_start
    mov dword ptr [rsp+100], 1
    cmp dword ptr [rsp+80], 1
    jne .Lvm_traf_unsupported
    mov rax, [rbx+VM_DECODE_END]
    mov [rsp+72], rax
    mov rcx, rbx
    mov rdx, [rsp+40]
    mov r8, [rsp+48]
    mov r9d, VM_TFDT_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_traf_optional_tfdt
    mov rsi, rax
    mov rdi, rdx
    sub rdx, rax
    cmp rdx, 8
    jb .Lvm_traf_bad
    test dword ptr [rsi], 0xffffff00
    jnz .Lvm_traf_bad
    cmp byte ptr [rsi], 0
    je .Lvm_traf_tfdt32
    cmp byte ptr [rsi], 1
    jne .Lvm_traf_unsupported
    cmp rdx, 12
    jne .Lvm_traf_bad
    mov r12, [rsi+4]
    bswap r12
    jmp .Lvm_traf_tfdt_store
.Lvm_traf_tfdt32:
    cmp rdx, 8
    jne .Lvm_traf_bad
    mov r12d, [rsi+4]
    bswap r12d
.Lvm_traf_tfdt_store:
    cmp r12, [rbx+VM_DECODE_END]
    jb .Lvm_traf_bad
    mov [rsp+72], r12
.Lvm_traf_optional_tfdt:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_traf_zero
.Lvm_traf_runs_start:
    mov rsi, [rsp+40]
    mov rdi, [rsp+48]
.Lvm_traf_run:
    cmp rsi, rdi
    je .Lvm_traf_done
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_traf_zero
    mov rsi, r8
    cmp eax, VM_TRUN_TYPE
    je .Lvm_traf_trun
    cmp dword ptr [rsp+100], 0
    je .Lvm_traf_run
    cmp eax, VM_SENC_TYPE
    je .Lvm_traf_unsupported
    cmp eax, VM_SAIZ_TYPE
    je .Lvm_traf_unsupported
    cmp eax, VM_SAIO_TYPE
    je .Lvm_traf_unsupported
    jmp .Lvm_traf_run
.Lvm_traf_trun:
    mov rcx, rbx
    lea r9, [rsp+56]
    call vm_trun
    test eax, eax
    jz .Lvm_traf_zero
    jmp .Lvm_traf_run
.Lvm_traf_done:
    mov rax, [rsp+32]
    mov rdx, [rsp+64]
    mov [rax+8], rdx
    cmp dword ptr [rsp+100], 0
    je .Lvm_traf_ok
    mov rax, [rsp+72]
    mov [rbx+VM_DECODE_END], rax
.Lvm_traf_ok:
    mov eax, 1
    jmp .Lvm_traf_return
.Lvm_traf_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_traf_zero
.Lvm_traf_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_traf_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_traf_zero:
    xor eax, eax
.Lvm_traf_return:
    add rsp, 120
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_traf

# R9=state {base,end,dts,desc:u32,dur,size,flags,track,selected,empty,haveRun}.
LOCALFN vm_trun
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    mov rbx, rcx
    mov rbp, r9
    mov rsi, rdx
    mov rdi, r8
    sub r8, rdx
    cmp r8, 8
    jb .Lvm_trun_bad
    movzx r15d, byte ptr [rsi]
    cmp r15d, 1
    ja .Lvm_trun_unsupported
    mov r14d, [rsi]
    bswap r14d
    and r14d, 0xffffff
    test r14d, 0xfffff0fa
    jnz .Lvm_trun_unsupported
    mov eax, r14d
    and eax, 0x404
    cmp eax, 0x404
    je .Lvm_trun_bad
    mov r12d, [rsi+4]
    bswap r12d
    mov rax, [rbx+VM_WORK_SAMPLES]
    add rax, r12
    cmp rax, VM_MAX_WORK_SAMPLES
    ja .Lvm_trun_limit
    mov [rbx+VM_WORK_SAMPLES], rax
    cmp dword ptr [rbp+44], 0
    je .Lvm_trun_empty
    mov eax, [rbx+VM_COUNT]
    add rax, r12
    cmp rax, VM_MAX_SAMPLES
    ja .Lvm_trun_limit
.Lvm_trun_empty:
    test r12d, r12d
    jz .Lvm_trun_header
    cmp dword ptr [rbp+48], 0
    jne .Lvm_trun_bad
.Lvm_trun_header:
    add rsi, 8
    test r14d, 1
    jz .Lvm_trun_first_flags
    VM_BE32 r13d,.Lvm_trun_bad
    movsxd r13, r13d
    mov rdx, [rbp]
    test r13, r13
    js .Lvm_trun_negative_offset
    add rdx, r13
    jc .Lvm_trun_bad
    jmp .Lvm_trun_offset
.Lvm_trun_negative_offset:
    neg r13
    sub rdx, r13
    jc .Lvm_trun_bad
.Lvm_trun_offset:
    mov [rbp+8], rdx
.Lvm_trun_first_flags:
    mov dword ptr [rsp+64], 0
    test r14d, 4
    jz .Lvm_trun_entries
    VM_BE32 r13d,.Lvm_trun_bad
    mov [rsp+64], r13d
.Lvm_trun_entries:
    mov eax, r14d
    shr eax, 8
    mov ecx, eax
    and ecx, 1
    shr eax, 1
    mov edx, eax
    and edx, 1
    add ecx, edx
    shr eax, 1
    mov edx, eax
    and edx, 1
    add ecx, edx
    shr eax, 1
    and eax, 1
    add ecx, eax
    shl ecx, 2
    imul rcx, r12
    mov rax, rdi
    sub rax, rsi
    cmp rcx, rax
    jne .Lvm_trun_bad
    mov rax, [rbx+VM_END]
    sub rax, [rbx+VM_BEGIN]
    cmp [rbp+8], rax
    ja .Lvm_trun_bad
    xor r13d, r13d
.Lvm_trun_sample:
    cmp r13d, r12d
    jae .Lvm_trun_done
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_trun_duration
    cmp dword ptr [rax], 0
    jne .Lvm_trun_cancel
.Lvm_trun_duration:
    mov edx, [rbp+28]
    test r14d, 0x100
    jz .Lvm_trun_duration_ready
    VM_BE32 edx,.Lvm_trun_bad
.Lvm_trun_duration_ready:
    mov [rsp+36], edx
    mov edx, [rbp+32]
    test r14d, 0x200
    jz .Lvm_trun_size_ready
    VM_BE32 edx,.Lvm_trun_bad
.Lvm_trun_size_ready:
    mov [rsp+32], edx
    mov edx, [rbp+36]
    test r13d, r13d
    jnz .Lvm_trun_flags_field
    test r14d, 4
    jz .Lvm_trun_flags_field
    mov edx, [rsp+64]
.Lvm_trun_flags_field:
    test r14d, 0x400
    jz .Lvm_trun_flags_ready
    VM_BE32 edx,.Lvm_trun_bad
.Lvm_trun_flags_ready:
    mov [rsp+40], edx
    xor edx, edx
    test r14d, 0x800
    jz .Lvm_trun_cto_ready
    VM_BE32 edx,.Lvm_trun_bad
    test r15d, r15d
    jz .Lvm_trun_cto_ready
    movsxd rdx, edx
.Lvm_trun_cto_ready:
    mov [rsp+48], rdx
    cmp dword ptr [rbp+44], 0
    je .Lvm_trun_ignored
    xor r9d, r9d
    test dword ptr [rsp+40], 0x10000
    sete r9b
    mov rcx, rbx
    mov rdx, [rbp+8]
    mov r8d, [rsp+32]
    call vm_record
    test rax, rax
    jz .Lvm_trun_zero
    mov rdx, [rbp+16]
    mov [rax+16], rdx
    mov rdx, [rsp+48]
    mov [rax+24], rdx
    mov edx, [rsp+36]
    mov [rax+32], rdx
    test edx, edx
    jnz .Lvm_trun_dts
    or dword ptr [rax+12], VM_ZERO_DURATION
.Lvm_trun_dts:
    add [rbp+16], rdx
    jc .Lvm_trun_limit
    jmp .Lvm_trun_advance
.Lvm_trun_ignored:
    mov rcx, rbx
    mov rdx, [rbp+8]
    mov r8d, [rsp+32]
    call vm_range
    test eax, eax
    jz .Lvm_trun_zero
.Lvm_trun_advance:
    mov eax, [rsp+32]
    add [rbp+8], rax
    jc .Lvm_trun_bad
    inc r13d
    jmp .Lvm_trun_sample
.Lvm_trun_done:
    mov dword ptr [rbp+52], 1
    mov eax, 1
    jmp .Lvm_trun_return
.Lvm_trun_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_trun_zero
.Lvm_trun_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_trun_zero
.Lvm_trun_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_trun_zero
.Lvm_trun_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_trun_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_trun_zero:
    xor eax, eax
.Lvm_trun_return:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_trun
