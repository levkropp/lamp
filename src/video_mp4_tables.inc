# Original classic sample placement and decode/composition timing expansion.
LOCALFN vm_tables
    push rbx
    sub rsp, 32
    mov rbx, rcx
    call vm_sizes
    test eax, eax
    jz .Lvm_tables_return
    mov rcx, rbx
    call vm_places
    test eax, eax
    jz .Lvm_tables_return
    mov rcx, rbx
    call vm_durations
    test eax, eax
    jz .Lvm_tables_return
    mov rcx, rbx
    call vm_composition
    test eax, eax
    jz .Lvm_tables_return
    mov rcx, rbx
    call vm_sync
.Lvm_tables_return:
    add rsp, 32
    pop rbx
    ret
ENDFN vm_tables

LOCALFN vm_sizes
    mov rdx, [rcx+VM_STSZ]
    test rdx, rdx
    jz .Lvm_sizes_bad
    mov r8, [rcx+VM_STSZ_END]
    sub r8, rdx
    cmp r8, 12
    jb .Lvm_sizes_bad
    cmp dword ptr [rdx], 0
    jne .Lvm_sizes_bad
    mov r9d, [rdx+8]
    bswap r9d
    cmp r9d, VM_MAX_SAMPLES
    ja .Lvm_sizes_limit
    mov [rcx+VM_SAMPLE_COUNT], r9d
    cmp dword ptr [rcx+VM_STZ2], 0
    jne .Lvm_sizes_compact
    mov eax, [rdx+4]
    bswap eax
    mov [rcx+VM_CONSTANT_SIZE], eax
    test eax, eax
    jnz .Lvm_sizes_constant
    lea rax, [r9*4+12]
    jmp .Lvm_sizes_length
.Lvm_sizes_constant:
    mov eax, 12
    jmp .Lvm_sizes_length
.Lvm_sizes_compact:
    test dword ptr [rdx+4], 0x00ffffff
    jnz .Lvm_sizes_bad
    movzx eax, byte ptr [rdx+7]
    cmp eax, 4
    je .Lvm_sizes_bits
    cmp eax, 8
    je .Lvm_sizes_bits
    cmp eax, 16
    jne .Lvm_sizes_bad
.Lvm_sizes_bits:
    mov [rcx+VM_STZ2], eax
    imul rax, r9
    add rax, 7
    shr rax, 3
    add rax, 12
.Lvm_sizes_length:
    cmp rax, r8
    jne .Lvm_sizes_bad
    mov eax, 1
    ret
.Lvm_sizes_limit:
    mov dword ptr [rcx+VM_ERROR], 3
    xor eax, eax
    ret
.Lvm_sizes_bad:
    mov dword ptr [rcx+VM_ERROR], 1
    xor eax, eax
    ret
ENDFN vm_sizes

LOCALFN vm_places
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov rbx, rcx
    mov r13, [rbx+VM_STSC]
    test r13, r13
    jz .Lvm_places_bad
    mov rax, [rbx+VM_STSC_END]
    sub rax, r13
    cmp rax, 8
    jb .Lvm_places_bad
    cmp dword ptr [r13], 0
    jne .Lvm_places_bad
    mov r14d, [r13+4]
    bswap r14d
    cmp r14d, VM_MAX_SAMPLES
    ja .Lvm_places_limit
    imul rcx, r14, 12
    add rcx, 8
    cmp rax, rcx
    jne .Lvm_places_bad
    mov r12, [rbx+VM_STCO]
    test r12, r12
    jz .Lvm_places_bad
    mov rax, [rbx+VM_STCO_END]
    sub rax, r12
    cmp rax, 8
    jb .Lvm_places_bad
    cmp dword ptr [r12], 0
    jne .Lvm_places_bad
    mov edx, [r12+4]
    bswap edx
    cmp edx, VM_MAX_SAMPLES
    ja .Lvm_places_limit
    mov [rsp+36], edx
    mov ecx, 4
    cmp dword ptr [rbx+VM_CO64], 0
    je .Lvm_places_offset_bytes
    mov ecx, 8
.Lvm_places_offset_bytes:
    imul rcx, rdx
    add rcx, 8
    cmp rax, rcx
    jne .Lvm_places_bad
    cmp dword ptr [rbx+VM_SAMPLE_COUNT], 0
    jne .Lvm_places_nonempty
    test edx, edx
    jnz .Lvm_places_bad
    test r14d, r14d
    jnz .Lvm_places_bad
    jmp .Lvm_places_ok
.Lvm_places_nonempty:
    test edx, edx
    jz .Lvm_places_bad
    test r14d, r14d
    jz .Lvm_places_bad
    add r13, 8
    add r12, 8
    xor ecx, ecx
    xor r9d, r9d
.Lvm_places_validate:
    imul rax, rcx, 12
    mov r8d, [r13+rax]
    bswap r8d
    cmp r8d, r9d
    jbe .Lvm_places_bad
    cmp r8d, [rsp+36]
    ja .Lvm_places_bad
    test ecx, ecx
    jnz .Lvm_places_validate_count
    cmp r8d, 1
    jne .Lvm_places_bad
.Lvm_places_validate_count:
    cmp dword ptr [r13+rax+4], 0
    je .Lvm_places_bad
    cmp dword ptr [r13+rax+8], 0x01000000
    jne .Lvm_places_unsupported
    mov r9d, r8d
    inc ecx
    cmp ecx, r14d
    jb .Lvm_places_validate
    xor ebp, ebp # sample
    xor esi, esi # chunk
    xor eax, eax
    cmp qword ptr [rbx+VM_STSS], 0
    sete al
    mov [rsp+32], eax
.Lvm_places_chunk:
    cmp esi, [rsp+36]
    jae .Lvm_places_done
.Lvm_places_stsc:
    lea rax, [r13+12]
    cmp rax, [rbx+VM_STSC_END]
    jae .Lvm_places_stsc_ready
    mov edx, [r13+12]
    bswap edx
    lea eax, [rsi+1]
    cmp eax, edx
    jb .Lvm_places_stsc_ready
    add r13, 12
    jmp .Lvm_places_stsc
.Lvm_places_stsc_ready:
    mov edi, [r13+4]
    bswap edi
    mov eax, ebp
    add rax, rdi
    mov edx, [rbx+VM_SAMPLE_COUNT]
    cmp rax, rdx
    ja .Lvm_places_bad
    cmp dword ptr [rbx+VM_CO64], 0
    jne .Lvm_places_offset64
    mov r15d, [r12+rsi*4]
    bswap r15d
    jmp .Lvm_places_sample
.Lvm_places_offset64:
    mov r15, [r12+rsi*8]
    bswap r15
.Lvm_places_sample:
    mov r8d, [rbx+VM_CONSTANT_SIZE]
    test r8d, r8d
    jnz .Lvm_places_add
    mov rax, [rbx+VM_STSZ]
    add rax, 12
    mov ecx, [rbx+VM_STZ2]
    cmp ecx, 16
    je .Lvm_places_size16
    cmp ecx, 8
    je .Lvm_places_size8
    cmp ecx, 4
    je .Lvm_places_size4
    mov r8d, [rax+rbp*4]
    bswap r8d
    jmp .Lvm_places_add
.Lvm_places_size16:
    movzx r8d, word ptr [rax+rbp*2]
    rol r8w, 8
    jmp .Lvm_places_add
.Lvm_places_size8:
    movzx r8d, byte ptr [rax+rbp]
    jmp .Lvm_places_add
.Lvm_places_size4:
    mov ecx, ebp
    shr ecx, 1
    movzx r8d, byte ptr [rax+rcx]
    test ebp, 1
    jnz .Lvm_places_nibble
    shr r8d, 4
.Lvm_places_nibble:
    and r8d, 15
.Lvm_places_add:
    mov rcx, rbx
    mov rdx, r15
    mov r9d, [rsp+32]
    call vm_record
    test rax, rax
    jz .Lvm_places_return
    mov edx, [rax+8]
    add r15, rdx
    inc ebp
    dec edi
    jnz .Lvm_places_sample
    inc esi
    jmp .Lvm_places_chunk
.Lvm_places_done:
    cmp ebp, [rbx+VM_SAMPLE_COUNT]
    jne .Lvm_places_bad
.Lvm_places_ok:
    mov eax, 1
    jmp .Lvm_places_return
.Lvm_places_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_places_zero
.Lvm_places_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_places_zero
.Lvm_places_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_places_zero:
    xor eax, eax
.Lvm_places_return:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_places

LOCALFN vm_durations
    push rbx
    push rbp
    push rsi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    mov rsi, [rbx+VM_STTS]
    test rsi, rsi
    jz .Lvm_stts_bad
    mov rax, [rbx+VM_STTS_END]
    sub rax, rsi
    cmp rax, 8
    jb .Lvm_stts_bad
    cmp dword ptr [rsi], 0
    jne .Lvm_stts_bad
    mov r13d, [rsi+4]
    bswap r13d
    cmp r13d, VM_MAX_SAMPLES
    ja .Lvm_stts_limit
    lea rdx, [r13*8+8]
    cmp rdx, rax
    jne .Lvm_stts_bad
    add rsi, 8
    xor ebp, ebp
    xor r12d, r12d
.Lvm_stts_run:
    test r13d, r13d
    jz .Lvm_stts_done
    mov eax, [rsi]
    bswap eax
    test eax, eax
    jz .Lvm_stts_bad
    mov [rsp+32], eax
    add rax, rbp
    mov edx, [rbx+VM_COUNT]
    cmp rax, rdx
    ja .Lvm_stts_bad
    mov eax, [rsi+4]
    bswap eax
    mov [rsp+36], eax
    add rsi, 8
.Lvm_stts_sample:
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_stts_time
    cmp dword ptr [rax], 0
    jne .Lvm_stts_cancel
.Lvm_stts_time:
    imul rax, rbp, VM_RECORD_BYTES
    add rax, [rbx+VM_RECORDS]
    mov [rax+16], r12
    mov edx, [rsp+36]
    mov [rax+32], rdx
    add r12, rdx
    jc .Lvm_stts_limit
    test edx, edx
    jnz .Lvm_stts_advance
    or dword ptr [rax+12], VM_ZERO_DURATION
.Lvm_stts_advance:
    inc ebp
    dec dword ptr [rsp+32]
    jnz .Lvm_stts_sample
    dec r13d
    jmp .Lvm_stts_run
.Lvm_stts_done:
    cmp ebp, [rbx+VM_COUNT]
    jne .Lvm_stts_bad
    mov [rbx+VM_DECODE_END], r12
    mov eax, 1
    jmp .Lvm_stts_return
.Lvm_stts_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_stts_zero
.Lvm_stts_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_stts_zero
.Lvm_stts_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_stts_zero:
    xor eax, eax
.Lvm_stts_return:
    add rsp, 48
    pop r13
    pop r12
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_durations

LOCALFN vm_composition
    push rbx
    push rbp
    push rsi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    mov rsi, [rbx+VM_CTTS]
    test rsi, rsi
    jz .Lvm_ctts_ok
    mov rax, [rbx+VM_CTTS_END]
    sub rax, rsi
    cmp rax, 8
    jb .Lvm_ctts_bad
    test dword ptr [rsi], 0xffffff00
    jnz .Lvm_ctts_bad
    movzx r13d, byte ptr [rsi]
    cmp r13d, 1
    ja .Lvm_ctts_unsupported
    mov r12d, [rsi+4]
    bswap r12d
    cmp r12d, VM_MAX_SAMPLES
    ja .Lvm_ctts_limit
    lea rdx, [r12*8+8]
    cmp rdx, rax
    jne .Lvm_ctts_bad
    add rsi, 8
    xor ebp, ebp
.Lvm_ctts_run:
    test r12d, r12d
    jz .Lvm_ctts_done
    mov eax, [rsi]
    bswap eax
    test eax, eax
    jz .Lvm_ctts_bad
    mov [rsp+32], eax
    add rax, rbp
    mov edx, [rbx+VM_COUNT]
    cmp rax, rdx
    ja .Lvm_ctts_bad
    mov eax, [rsi+4]
    bswap eax
    test r13d, r13d
    jz .Lvm_ctts_offset
    movsxd rax, eax
.Lvm_ctts_offset:
    mov [rsp+40], rax
    add rsi, 8
.Lvm_ctts_sample:
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_ctts_time
    cmp dword ptr [rax], 0
    jne .Lvm_ctts_cancel
.Lvm_ctts_time:
    imul rax, rbp, VM_RECORD_BYTES
    add rax, [rbx+VM_RECORDS]
    mov rdx, [rsp+40]
    mov [rax+24], rdx
    inc ebp
    dec dword ptr [rsp+32]
    jnz .Lvm_ctts_sample
    dec r12d
    jmp .Lvm_ctts_run
.Lvm_ctts_done:
    cmp ebp, [rbx+VM_COUNT]
    jne .Lvm_ctts_bad
.Lvm_ctts_ok:
    mov eax, 1
    jmp .Lvm_ctts_return
.Lvm_ctts_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_ctts_zero
.Lvm_ctts_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_ctts_zero
.Lvm_ctts_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_ctts_zero
.Lvm_ctts_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_ctts_zero:
    xor eax, eax
.Lvm_ctts_return:
    add rsp, 48
    pop r13
    pop r12
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_composition

LOCALFN vm_sync
    mov rdx, [rcx+VM_STSS]
    test rdx, rdx
    jz .Lvm_sync_ok
    mov r8, [rcx+VM_STSS_END]
    sub r8, rdx
    cmp r8, 8
    jb .Lvm_sync_bad
    cmp dword ptr [rdx], 0
    jne .Lvm_sync_bad
    mov r9d, [rdx+4]
    bswap r9d
    cmp r9d, [rcx+VM_COUNT]
    ja .Lvm_sync_bad
    lea rax, [r9*4+8]
    cmp rax, r8
    jne .Lvm_sync_bad
    add rdx, 8
    xor r10d, r10d
    xor r11d, r11d
.Lvm_sync_next:
    cmp r10d, r9d
    jae .Lvm_sync_ok
    mov rax, [rcx+VM_CANCEL]
    test rax, rax
    jz .Lvm_sync_number
    cmp dword ptr [rax], 0
    jne .Lvm_sync_cancel
.Lvm_sync_number:
    mov eax, [rdx+r10*4]
    bswap eax
    cmp eax, r11d
    jbe .Lvm_sync_bad
    cmp eax, [rcx+VM_COUNT]
    ja .Lvm_sync_bad
    mov r11d, eax
    dec eax
    imul rax, rax, VM_RECORD_BYTES
    add rax, [rcx+VM_RECORDS]
    test dword ptr [rax+12], VM_EMPTY
    jnz .Lvm_sync_advance
    or dword ptr [rax+12], VM_SYNC
.Lvm_sync_advance:
    inc r10d
    jmp .Lvm_sync_next
.Lvm_sync_ok:
    mov eax, 1
    ret
.Lvm_sync_cancel:
    mov dword ptr [rcx+VM_ERROR], 61
    xor eax, eax
    ret
.Lvm_sync_bad:
    mov dword ptr [rcx+VM_ERROR], 1
    xor eax, eax
    ret
ENDFN vm_sync
