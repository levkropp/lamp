# Original reentrant ISO BMFF video sample/timestamp index. MIT.
# ISO/IEC14496-12/-15 and Apple's QuickTime atom documentation; no codec library.
.include "lamp.inc"
.include "video_mp4.inc"

# RCX=ctx,RDX=cursor,R8=parent end ->EAX=FourCC,RDX=payload,R8=box end.
# Zero indicates a sticky malformed/limit/cancel error; unknown payload is opaque.
LOCALFN vm_box
    mov rax, [rcx+VM_CANCEL]
    test rax, rax
    jz .Lvm_box_budget
    cmp dword ptr [rax], 0
    jne .Lvm_box_cancel
.Lvm_box_budget:
    inc dword ptr [rcx+VM_VISITS]
    cmp dword ptr [rcx+VM_VISITS], 16777216
    ja .Lvm_box_limit
    cmp rdx, r8
    ja .Lvm_box_bad
    mov r9, r8
    sub r9, rdx
    cmp r9, 8
    jb .Lvm_box_bad
    mov r10d, [rdx]
    bswap r10d
    mov eax, [rdx+4]
    test eax, eax
    jz .Lvm_box_bad
    cmp r10d, 1
    je .Lvm_box_large
    test r10d, r10d
    jz .Lvm_box_rest
    cmp r10d, 8
    jb .Lvm_box_bad
    cmp r10, r9
    ja .Lvm_box_bad
    lea r8, [rdx+r10]
    add rdx, 8
    ret
.Lvm_box_large:
    cmp r9, 16
    jb .Lvm_box_bad
    mov r10, [rdx+8]
    bswap r10
    cmp r10, 16
    jb .Lvm_box_bad
    cmp r10, r9
    ja .Lvm_box_bad
    lea r8, [rdx+r10]
    add rdx, 16
    ret
.Lvm_box_rest:
    add rdx, 8
    ret
.Lvm_box_cancel:
    mov dword ptr [rcx+VM_ERROR], 61
    jmp .Lvm_box_zero
.Lvm_box_limit:
    mov dword ptr [rcx+VM_ERROR], 3
    jmp .Lvm_box_zero
.Lvm_box_bad:
    mov dword ptr [rcx+VM_ERROR], 1
.Lvm_box_zero:
    xor eax, eax
    ret
ENDFN vm_box

# RCX=ctx,RDX=parent payload,R8=end,R9D=type ->RAX=unique child payload,
# RDX=child end. Zero absent; all sibling box boundaries checked; duplicates fail.
LOCALFN vm_child
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov ebp, r9d
    xor r12d, r12d
    xor r13d, r13d
.Lvm_child_next:
    cmp rsi, rdi
    je .Lvm_child_done
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_child_zero
    mov rsi, r8
    cmp eax, ebp
    jne .Lvm_child_next
    test r12, r12
    jnz .Lvm_child_bad
    mov r12, rdx
    mov r13, r8
    jmp .Lvm_child_next
.Lvm_child_done:
    mov rax, r12
    mov rdx, r13
    jmp .Lvm_child_return
.Lvm_child_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_child_zero:
    xor eax, eax
.Lvm_child_return:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_child

# RCX=ctx,RDX=&{reserved pointer,committed bytes},R8=needed,R9=reservation cap.
LOCALFN vm_commit
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    add rdi, 65535
    jc .Lvm_commit_limit
    and rdi, -65536
    cmp rdi, r9
    ja .Lvm_commit_limit
    cmp qword ptr [rsi], 0
    jne .Lvm_commit_pages
    mov rcx, r9
    call mem_reserve
    test rax, rax
    jz .Lvm_commit_memory
    mov [rsi], rax
.Lvm_commit_pages:
    cmp rdi, [rsi+8]
    jbe .Lvm_commit_ready
    mov rcx, [rsi]
    add rcx, [rsi+8]
    mov rdx, rdi
    sub rdx, [rsi+8]
    call mem_commit
    test rax, rax
    jz .Lvm_commit_memory
    mov [rsi+8], rdi
.Lvm_commit_ready:
    mov rax, [rsi]
    jmp .Lvm_commit_return
.Lvm_commit_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_commit_zero
.Lvm_commit_memory:
    mov dword ptr [rbx+VM_ERROR], 12
.Lvm_commit_zero:
    xor eax, eax
.Lvm_commit_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_commit

# RCX=ctx,RDX/R8=mdat payload/end, absolute addresses from vm_box.
LOCALFN vm_mdat
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r8d, [rbx+VM_MDAT_COUNT]
    cmp r8d, VM_MAX_MDATS
    jae .Lvm_mdat_limit
    inc r8d
    shl r8, 4
    lea rdx, [rbx+VM_MDATS]
    mov r9d, VM_MAX_MDATS*16
    call vm_commit
    test rax, rax
    jz .Lvm_mdat_return
    mov ecx, [rbx+VM_MDAT_COUNT]
    shl ecx, 4
    sub rsi, [rbx+VM_BEGIN]
    sub rdi, [rbx+VM_BEGIN]
    mov [rax+rcx], rsi
    mov [rax+rcx+8], rdi
    inc dword ptr [rbx+VM_MDAT_COUNT]
    mov eax, 1
    jmp .Lvm_mdat_return
.Lvm_mdat_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    xor eax, eax
.Lvm_mdat_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_mdat

# RCX=ctx,RDX=file-relative offset,R8=size ->1 if wholly inside one mdat.
# Empty samples dereference no media bytes; their offset may be any file position.
LOCALFN vm_range
    push rbx
    test r8, r8
    jz .Lvm_range_empty
    xor r9d, r9d
    mov r10d, [rcx+VM_MDAT_COUNT]
    mov r11, [rcx+VM_MDATS]
.Lvm_range_find:
    cmp r9d, r10d
    jae .Lvm_range_found
    lea eax, [r9+r10]
    shr eax, 1
    mov ebx, eax
    shl ebx, 4
    cmp rdx, [r11+rbx]
    jb .Lvm_range_lower
    lea r9d, [rax+1]
    jmp .Lvm_range_find
.Lvm_range_lower:
    mov r10d, eax
    jmp .Lvm_range_find
.Lvm_range_found:
    test r9d, r9d
    jz .Lvm_range_bad
    lea ebx, [r9-1]
    shl ebx, 4
    mov rax, [r11+rbx+8]
    cmp rdx, rax
    ja .Lvm_range_bad
    sub rax, rdx
    cmp r8, rax
    ja .Lvm_range_bad
    mov eax, 1
    pop rbx
    ret
.Lvm_range_empty:
    mov rax, [rcx+VM_END]
    sub rax, [rcx+VM_BEGIN]
    cmp rdx, rax
    ja .Lvm_range_bad
    mov eax, 1
    pop rbx
    ret
.Lvm_range_bad:
    mov dword ptr [rcx+VM_ERROR], 1
    xor eax, eax
    pop rbx
    ret
ENDFN vm_range

# RCX=ctx,RDX=file-relative offset,R8D=size,R9D=flags ->new zeroed48B record.
LOCALFN vm_record
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    mov r12d, r9d
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_record_count
    cmp dword ptr [rax], 0
    jne .Lvm_record_cancel
.Lvm_record_count:
    cmp dword ptr [rbx+VM_COUNT], VM_MAX_SAMPLES
    jae .Lvm_record_limit
    cmp edi, 16777216
    ja .Lvm_record_limit
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_range
    test eax, eax
    jz .Lvm_record_return
    mov rcx, rbx
    lea rdx, [rbx+VM_RECORDS]
    mov r8d, [rbx+VM_COUNT]
    inc r8d
    imul r8, r8, VM_RECORD_BYTES
    mov r9d, VM_MAX_RECORD_BYTES
    call vm_commit
    test rax, rax
    jz .Lvm_record_return
    mov ecx, [rbx+VM_COUNT]
    imul rcx, rcx, VM_RECORD_BYTES
    add rax, rcx
    pxor xmm0, xmm0
    movdqu [rax], xmm0
    movdqu [rax+16], xmm0
    movdqu [rax+32], xmm0
    mov [rax], rsi
    mov [rax+8], edi
    test edi, edi
    jnz .Lvm_record_flags
    and r12d, -2
    or r12d, VM_EMPTY
.Lvm_record_flags:
    mov [rax+12], r12d
    inc dword ptr [rbx+VM_COUNT]
    jmp .Lvm_record_return
.Lvm_record_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_record_zero
.Lvm_record_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_record_zero
.Lvm_record_zero:
    xor eax, eax
.Lvm_record_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_record

# RCX=new/closed8192B ctx,RDX=mapped bytes,R8=size,R9=optional24B options:
# {video ordinal:u32,reserved:u32,cancelDWORD*:u64,epoch:u64}. ordinal0=default.
# Borrow input until close.1success/0failure; initialized failures need close.
FN video_mp4_open
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 32
    mov rbx, rcx
    cmp qword ptr [rbx+VM_BEGIN], 0
    jne .Lvm_open_zero
    cmp qword ptr [rbx+VM_RECORDS], 0
    jne .Lvm_open_zero
    cmp qword ptr [rbx+VM_MDATS], 0
    jne .Lvm_open_zero
    cmp qword ptr [rbx+VM_SORT], 0
    jne .Lvm_open_zero
    mov rsi, rdx
    mov r12, r8
    mov rbp, r9
    mov rdi, rbx
    mov ecx, VM_BYTES/8
    xor eax, eax
    rep stosq
    mov qword ptr [rbx+VM_EPOCH], 1
    test rbp, rbp
    jz .Lvm_open_input
    cmp dword ptr [rbp+4], 0
    jne .Lvm_open_bad
    mov eax, [rbp]
    mov [rbx+VM_CHOICE], eax
    mov rax, [rbp+8]
    mov [rbx+VM_CANCEL], rax
    mov rax, [rbp+16]
    test rax, rax
    jz .Lvm_open_bad
    mov [rbx+VM_EPOCH], rax
.Lvm_open_input:
    test rsi, rsi
    jz .Lvm_open_bad
    cmp r12, 8
    jb .Lvm_open_bad
    test r12, r12
    js .Lvm_open_limit
    add r12, rsi
    jc .Lvm_open_bad
    mov [rbx+VM_BEGIN], rsi
    mov [rbx+VM_END], r12
.Lvm_open_top:
    cmp rsi, r12
    je .Lvm_open_movie
    mov rcx, rbx
    mov rdx, rsi
    mov r8, r12
    call vm_box
    test eax, eax
    jz .Lvm_open_zero
    mov rsi, r8
    cmp eax, VM_MOOV_TYPE
    je .Lvm_open_moov
    cmp eax, VM_MDAT_TYPE
    je .Lvm_open_mdat
    cmp eax, VM_MOOF_TYPE
    jne .Lvm_open_top
    mov dword ptr [rbx+VM_FRAGMENTED], 1
    jmp .Lvm_open_top
.Lvm_open_moov:
    cmp qword ptr [rbx+VM_MOOV], 0
    jne .Lvm_open_bad
    mov [rbx+VM_MOOV], rdx
    mov [rbx+VM_MOOV_END], r8
    jmp .Lvm_open_top
.Lvm_open_mdat:
    mov rcx, rbx
    call vm_mdat
    test eax, eax
    jz .Lvm_open_zero
    jmp .Lvm_open_top
.Lvm_open_movie:
    cmp qword ptr [rbx+VM_MOOV], 0
    je .Lvm_open_bad
    mov rcx, rbx
    call vm_headers
    test eax, eax
    jz .Lvm_open_zero
    mov rcx, rbx
    call vm_tables
    test eax, eax
    jz .Lvm_open_zero
    mov rcx, rbx
    call vm_fragments
    test eax, eax
    jz .Lvm_open_zero
    mov rcx, rbx
    call vm_times
    test eax, eax
    jz .Lvm_open_zero
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_open_ready
    cmp dword ptr [rax], 0
    jne .Lvm_open_cancel
.Lvm_open_ready:
    mov dword ptr [rbx+VM_READY], 1
    mov eax, 1
    jmp .Lvm_open_return
.Lvm_open_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_open_zero
.Lvm_open_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_open_zero
.Lvm_open_bad:
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_open_zero:
    xor eax, eax
.Lvm_open_return:
    add rsp, 32
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN video_mp4_open

# RCX=ready ctx,RDX=80B out {packet48,flags:u32,index:u32,showPTS:i64,
# showDuration:u64,rawDisplayDuration:u64}.1packet,0EOF,-1sticky error.
FN video_mp4_next
    cmp dword ptr [rcx+VM_ERROR], 0
    jne .Lvm_next_error
    cmp dword ptr [rcx+VM_READY], 1
    jne .Lvm_next_bad
    mov rax, [rcx+VM_CANCEL]
    test rax, rax
    jz .Lvm_next_index
    cmp dword ptr [rax], 0
    jne .Lvm_next_cancel
.Lvm_next_index:
    mov eax, [rcx+VM_CURSOR]
    cmp eax, [rcx+VM_COUNT]
    je .Lvm_next_eof
    ja .Lvm_next_bad
    mov r11d, eax
    imul rax, rax, VM_RECORD_BYTES
    add rax, [rcx+VM_RECORDS]
    mov r8, [rax]
    add r8, [rcx+VM_BEGIN]
    mov [rdx], r8
    mov r8d, [rax+8]
    mov [rdx+8], r8
    movdqu xmm0, [rax+16]
    movdqu [rdx+16], xmm0
    mov r8, [rax+32]
    mov [rdx+32], r8
    mov r8, [rcx+VM_EPOCH]
    mov [rdx+40], r8
    mov r8d, [rax+12]
    mov [rdx+52], r11d
    mov r9, [rax+24]
    mov r10, [rax+40]
    mov [rdx+72], r10
    add r10, r9 # vm_times validated endpoint.
    cmp r9, [rcx+VM_GAP_NS]
    cmovl r9, [rcx+VM_GAP_NS]
    cmp r10, [rcx+VM_EDIT_END]
    cmovg r10, [rcx+VM_EDIT_END]
    mov [rdx+56], r9
    test r8d, VM_EMPTY
    jnz .Lvm_next_hidden
    cmp r10, r9
    jle .Lvm_next_hidden
    sub r10, r9
    mov [rdx+64], r10
    jmp .Lvm_next_flags
.Lvm_next_hidden:
    or r8d, VM_NO_DISPLAY
    mov qword ptr [rdx+64], 0
.Lvm_next_flags:
    mov [rdx+48], r8d
    inc dword ptr [rcx+VM_CURSOR]
    mov eax, 1
    ret
.Lvm_next_eof:
    xor eax, eax
    ret
.Lvm_next_cancel:
    mov dword ptr [rcx+VM_ERROR], 61
    jmp .Lvm_next_error
.Lvm_next_bad:
    mov dword ptr [rcx+VM_ERROR], 1
.Lvm_next_error:
    mov eax, -1
    ret
ENDFN video_mp4_next

# Restart generation only after consumer drains/releases prior work and decoder.
FN video_mp4_rewind
    cmp dword ptr [rcx+VM_READY], 1
    jne .Lvm_rewind_no
    cmp dword ptr [rcx+VM_ERROR], 0
    jne .Lvm_rewind_no
    cmp rdx, [rcx+VM_EPOCH]
    jbe .Lvm_rewind_no
    mov [rcx+VM_EPOCH], rdx
    mov dword ptr [rcx+VM_CURSOR], 0
    mov eax, 1
    ret
.Lvm_rewind_no:
    xor eax, eax
    ret
ENDFN video_mp4_rewind

FN video_mp4_close
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rcx, [rbx+VM_RECORDS]
    call mem_free
    mov rcx, [rbx+VM_MDATS]
    call mem_free
    mov rcx, [rbx+VM_SORT]
    call mem_free
    mov rdi, rbx
    mov ecx, VM_BYTES/8
    xor eax, eax
    rep stosq
    add rsp, 40
    pop rdi
    pop rbx
    ret
ENDFN video_mp4_close

.include "video_mp4_headers.inc"
.include "video_mp4_tables.inc"
.include "video_mp4_time.inc"
.include "video_mp4_fragments.inc"
