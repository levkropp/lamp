# Original integer clock normalization and bounded stable presentation indexing.

# RCX=ctx,R9:RDX=signed128 units,R8D=scale ->RAX=floor(units*1e9/scale),
# RDX=nonnegative remainder. Actual inputs have at most65 significant bits.
LOCALFN vm_scale
    mov r8d, r8d
    test r8d, r8d
    jz .Lvm_scale_limit
    mov rax, rdx
    mov r10, r9
    sar r9, 63
    test r9, r9
    jz .Lvm_scale_multiply
    neg rax
    adc r10, 0
    neg r10
.Lvm_scale_multiply:
    mov r11d, 1000000000
    mul r11
    imul r10, r10, 1000000000
    add rdx, r10
    jc .Lvm_scale_limit
    cmp rdx, r8
    jae .Lvm_scale_limit
    div r8
    test r9, r9
    jnz .Lvm_scale_negative
    test rax, rax
    js .Lvm_scale_limit
    ret
.Lvm_scale_negative:
    mov r10, 0x8000000000000000
    cmp rax, r10
    ja .Lvm_scale_limit
    jne .Lvm_scale_negate
    test rdx, rdx
    jnz .Lvm_scale_limit
.Lvm_scale_negate:
    neg rax
    test rdx, rdx
    jz .Lvm_scale_return
    dec rax
    mov r10, r8
    sub r10, rdx
    mov rdx, r10
.Lvm_scale_return:
    ret
.Lvm_scale_limit:
    mov dword ptr [rcx+VM_ERROR], 3
    xor eax, eax
    xor edx, edx
    ret
ENDFN vm_scale

# RCX=ctx,R8:RDX=signed128 shifted media units ->floor(media/sc+empty/movieSc).
# Fractional remainders are combined before rounding, including negative preroll.
LOCALFN vm_stamp
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov r9, r8
    mov r8d, [rbx+VM_MEDIA_SCALE]
    call vm_scale
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_stamp_zero
    add rax, [rbx+VM_GAP_NS]
    jo .Lvm_stamp_limit
    mov r9d, [rbx+VM_MOVIE_SCALE]
    imul rdx, r9
    mov r10d, [rbx+VM_MEDIA_SCALE]
    mov r11d, r9d
    sub r11d, [rbx+VM_GAP_REM]
    imul r11, r10
    cmp rdx, r11
    jb .Lvm_stamp_return
    inc rax
    jo .Lvm_stamp_limit
    jmp .Lvm_stamp_return
.Lvm_stamp_limit:
    mov dword ptr [rbx+VM_ERROR], 3
.Lvm_stamp_zero:
    xor eax, eax
.Lvm_stamp_return:
    add rsp, 32
    pop rbx
    ret
ENDFN vm_stamp

# Compare two sample indices by (signed PTS,decode index), strict greater.
LOCALFN vm_greater
    mov r9, [rcx+VM_RECORDS]
    imul r10, rdx, VM_RECORD_BYTES
    mov r11, [r9+r10+24]
    imul r10, r8, VM_RECORD_BYTES
    cmp r11, [r9+r10+24]
    jg .Lvm_greater_yes
    jl .Lvm_greater_no
    xor eax, eax
    cmp edx, r8d
    seta al
    ret
.Lvm_greater_yes:
    mov eax, 1
    ret
.Lvm_greater_no:
    xor eax, eax
    ret
ENDFN vm_greater

# RCX=ctx,EDX=heap root,R8D=exclusive heap count. Maxheap of sample indices.
LOCALFN vm_sift
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov ebp, edx
    mov edi, r8d
    mov rsi, [rbx+VM_SORT]
.Lvm_sift_next:
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_sift_child
    cmp dword ptr [rax], 0
    jne .Lvm_sift_cancel
.Lvm_sift_child:
    lea r12d, [rbp+rbp+1]
    cmp r12d, edi
    jae .Lvm_sift_ok
    lea eax, [r12+1]
    cmp eax, edi
    jae .Lvm_sift_compare
    mov rcx, rbx
    mov edx, [rsi+r12*4]
    mov r8d, [rsi+rax*4]
    call vm_greater
    test eax, eax
    jnz .Lvm_sift_compare
    inc r12d
.Lvm_sift_compare:
    mov rcx, rbx
    mov edx, [rsi+r12*4]
    mov r8d, [rsi+rbp*4]
    call vm_greater
    test eax, eax
    jz .Lvm_sift_ok
    mov eax, [rsi+rbp*4]
    mov edx, [rsi+r12*4]
    mov [rsi+rbp*4], edx
    mov [rsi+r12*4], eax
    mov ebp, r12d
    jmp .Lvm_sift_next
.Lvm_sift_ok:
    mov eax, 1
    jmp .Lvm_sift_return
.Lvm_sift_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    xor eax, eax
.Lvm_sift_return:
    add rsp, 32
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_sift

LOCALFN vm_sort
    push rbx
    push rbp
    push rsi
    sub rsp, 32
    mov rbx, rcx
    mov ebp, [rbx+VM_COUNT]
    test ebp, ebp
    jz .Lvm_sort_ok
    lea ecx, [rbp*4]
    call mem_alloc
    test rax, rax
    jz .Lvm_sort_memory
    mov [rbx+VM_SORT], rax
    mov rsi, rax
    xor ecx, ecx
.Lvm_sort_indices:
    mov [rsi+rcx*4], ecx
    inc ecx
    cmp ecx, ebp
    jb .Lvm_sort_indices
    shr ebp, 1
.Lvm_sort_heapify:
    test ebp, ebp
    jz .Lvm_sort_extract_start
    dec ebp
    mov rcx, rbx
    mov edx, ebp
    mov r8d, [rbx+VM_COUNT]
    call vm_sift
    test eax, eax
    jz .Lvm_sort_return
    jmp .Lvm_sort_heapify
.Lvm_sort_extract_start:
    mov ebp, [rbx+VM_COUNT]
    dec ebp
.Lvm_sort_extract:
    test ebp, ebp
    jz .Lvm_sort_ok
    mov eax, [rsi]
    mov edx, [rsi+rbp*4]
    mov [rsi], edx
    mov [rsi+rbp*4], eax
    mov rcx, rbx
    xor edx, edx
    mov r8d, ebp
    call vm_sift
    test eax, eax
    jz .Lvm_sort_return
    dec ebp
    jmp .Lvm_sort_extract
.Lvm_sort_ok:
    mov eax, 1
    jmp .Lvm_sort_return
.Lvm_sort_memory:
    mov dword ptr [rbx+VM_ERROR], 12
    xor eax, eax
.Lvm_sort_return:
    add rsp, 32
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_sort

LOCALFN vm_times
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov rbx, rcx
    mov rdx, [rbx+VM_GAP_UNITS]
    mov r8d, [rbx+VM_MOVIE_SCALE]
    xor r9d, r9d
    call vm_scale
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_times_zero
    mov [rbx+VM_GAP_NS], rax
    mov [rbx+VM_GAP_REM], edx
    mov rax, 0x7fffffffffffffff
    mov [rbx+VM_EDIT_END], rax
    cmp dword ptr [rbx+VM_EDIT_FOUND], 0
    je .Lvm_times_start
    cmp dword ptr [rbx+VM_EDIT_FOUND], 1
    jne .Lvm_times_edit_end
    cmp qword ptr [rbx+VM_EDIT_DURATION], 0
    je .Lvm_times_start
.Lvm_times_edit_end:
    mov rdx, [rbx+VM_GAP_UNITS]
    xor r9d, r9d
    add rdx, [rbx+VM_EDIT_DURATION]
    adc r9, 0
    mov r8d, [rbx+VM_MOVIE_SCALE]
    mov rcx, rbx
    call vm_scale
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_times_zero
    mov [rbx+VM_EDIT_END], rax
.Lvm_times_start:
    xor ebp, ebp
.Lvm_times_sample:
    cmp ebp, [rbx+VM_COUNT]
    jae .Lvm_times_sort
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_times_units
    cmp dword ptr [rax], 0
    jne .Lvm_times_cancel
.Lvm_times_units:
    imul rsi, rbp, VM_RECORD_BYTES
    add rsi, [rbx+VM_RECORDS]
    mov rdi, [rsi+16]
    mov r12, [rsi+24]
    mov r13, [rsi+32]
    mov rdx, rdi
    xor r8d, r8d
    sub rdx, [rbx+VM_MEDIA_START]
    sbb r8, 0
    mov rcx, rbx
    call vm_stamp
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_times_zero
    mov r14, rax
    mov rdx, rdi
    mov r8, r12
    sar r8, 63
    add rdx, r12
    adc r8, 0
    sub rdx, [rbx+VM_MEDIA_START]
    sbb r8, 0
    mov rcx, rbx
    call vm_stamp
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_times_zero
    mov r15, rax
    mov rdx, rdi
    xor r8d, r8d
    add rdx, r13
    adc r8, 0
    sub rdx, [rbx+VM_MEDIA_START]
    sbb r8, 0
    mov rcx, rbx
    call vm_stamp
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_times_zero
    sub rax, r14
    jo .Lvm_times_limit
    test rax, rax
    js .Lvm_times_limit
    mov [rsi+40], rax # Last picture's default: unrounded-endpoint decode span.
    jnz .Lvm_times_duration
    or dword ptr [rsi+12], VM_ZERO_DURATION
    inc eax # Decoder interface requires positive duration; hidden output may be0.
.Lvm_times_duration:
    mov [rsi+32], rax
    add rax, r15
    jo .Lvm_times_limit
    mov [rsi+16], r14
    mov [rsi+24], r15
    inc ebp
    jmp .Lvm_times_sample
.Lvm_times_sort:
    mov rcx, rbx
    call vm_sort
    test eax, eax
    jz .Lvm_times_zero
    xor ebp, ebp
    mov rdi, [rbx+VM_SORT]
.Lvm_times_display:
    cmp ebp, [rbx+VM_COUNT]
    jae .Lvm_times_ok
    mov eax, [rdi+rbp*4]
    imul rsi, rax, VM_RECORD_BYTES
    add rsi, [rbx+VM_RECORDS]
    lea eax, [rbp+1]
    cmp eax, [rbx+VM_COUNT]
    jae .Lvm_times_endpoint
    mov eax, [rdi+rax*4]
    imul rax, rax, VM_RECORD_BYTES
    add rax, [rbx+VM_RECORDS]
    mov rax, [rax+24]
    sub rax, [rsi+24]
    jo .Lvm_times_limit
    test rax, rax
    js .Lvm_times_limit
    mov [rsi+40], rax
.Lvm_times_endpoint:
    mov rax, [rsi+24]
    add rax, [rsi+40]
    jo .Lvm_times_limit
    inc ebp
    jmp .Lvm_times_display
.Lvm_times_ok:
    mov eax, 1
    jmp .Lvm_times_return
.Lvm_times_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_times_zero
.Lvm_times_limit:
    mov dword ptr [rbx+VM_ERROR], 3
.Lvm_times_zero:
    xor eax, eax
.Lvm_times_return:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_times
