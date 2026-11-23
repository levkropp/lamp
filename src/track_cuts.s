# Original sparse packet-block padding map. MIT, see LICENSE.
# Before finish: first packet, exclusive last packet, signed nanoseconds.
# After finish: raw begin, raw end, presented boundary, cumulative removal.
.include "lamp.inc"
.equ TC_ITEM, 32
.equ TC_CAP, 1 << 24
.equ TC_COMMIT, 65536
.globl track_cut_count
.data
tc_data: .quad 0
tc_committed: .quad 0
track_cut_count: .long 0
tc_ready: .long 0
.text
FN track_cuts_close
    sub rsp, 40
    mov rcx, [rip+tc_data]
    test rcx, rcx
    jz .Ltc_close_clear
    call mem_free
.Ltc_close_clear:
    mov qword ptr [rip+tc_data], 0
    mov qword ptr [rip+tc_committed], 0
    mov dword ptr [rip+track_cut_count], 0
    mov dword ptr [rip+tc_ready], 0
    add rsp, 40
    ret
ENDFN track_cuts_close

# ECX=resolved removal index -> RAX=raw begin, RDX=raw end; -1/-1 past end.
# Read-only iterator used when resolving a timestamped presentation timeline.
FN track_cut_at
    cmp ecx, [rip+track_cut_count]
    jae .Ltc_at_none
    mov eax, ecx
    shl rax, 5
    add rax, [rip+tc_data]
    mov rdx, [rax+8]
    mov rax, [rax]
    ret
.Ltc_at_none:
    mov rax, -1
    mov rdx, -1
    ret
ENDFN track_cut_at

# RCX=first packet, RDX=exclusive last, R8=signed nanoseconds ->1/0.
# Blocks are appended in order and cannot overlap. Zero padding is a no-op.
FN track_cut_add
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    cmp dword ptr [rip+tc_ready], 0
    jne .Ltc_add_bad
    cmp rbx, rsi
    jae .Ltc_add_bad
    cmp rsi, [rip+track_count]
    ja .Ltc_add_bad
    test rdi, rdi
    jz .Ltc_add_ok
    mov eax, [rip+track_cut_count]
    cmp eax, TC_CAP
    jae .Ltc_add_bad
    test eax, eax
    jz .Ltc_add_reserve
    dec eax
    shl rax, 5
    add rax, [rip+tc_data]
    cmp rbx, [rax+8]
    jb .Ltc_add_bad
.Ltc_add_reserve:
    cmp qword ptr [rip+tc_data], 0
    jne .Ltc_add_commit
    mov ecx, TC_CAP*TC_ITEM
    call mem_reserve
    test rax, rax
    jz .Ltc_add_bad
    mov [rip+tc_data], rax
.Ltc_add_commit:
    mov eax, [rip+track_cut_count]
    inc eax
    shl rax, 5
    cmp rax, [rip+tc_committed]
    jbe .Ltc_add_store
    mov rcx, [rip+tc_data]
    add rcx, [rip+tc_committed]
    mov edx, TC_COMMIT
    call mem_commit
    test rax, rax
    jz .Ltc_add_bad
    add qword ptr [rip+tc_committed], TC_COMMIT
.Ltc_add_store:
    mov eax, [rip+track_cut_count]
    shl rax, 5
    add rax, [rip+tc_data]
    mov [rax], rbx
    mov [rax+8], rsi
    mov [rax+16], rdi
    mov qword ptr [rax+24], 0
    inc dword ptr [rip+track_cut_count]
.Ltc_add_ok:
    mov eax, 1
    jmp .Ltc_add_return
.Ltc_add_bad:
    xor eax, eax
.Ltc_add_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_cut_add

# RCX=24-byte packet table, RDX=count, R8=raw total ->1/0.
# Resolve and clip block-edge removals to the globally presented interval.
# A failed finish requires close; converted records are never reused as input.
FN track_cuts_finish
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    cmp dword ptr [rip+tc_ready], 0
    jne .Ltc_finish_bad
    mov dword ptr [rip+tc_ready], 2
    mov r12, rcx
    mov r13, rdx
    mov r14, r8
    sub r14, [rip+track_end_trim]
    jc .Ltc_finish_bad
    cmp r14, [rip+track_start_trim]
    jb .Ltc_finish_bad
    mov rsi, [rip+tc_data]
    mov rdi, rsi
    xor ebx, ebx
    xor r15d, r15d                     # cumulative removed samples
.Ltc_finish_item:
    cmp ebx, [rip+track_cut_count]
    jae .Ltc_finish_done
    mov rax, [rsi+8]
    test rax, rax
    jz .Ltc_finish_bad
    cmp rax, r13
    ja .Ltc_finish_bad
    dec rax
    imul rax, rax, 24
    add rax, r12
    mov r10, [rax+8]
    mov ecx, [rax+20]
    add r10, rcx                       # raw end of block
    mov rax, [rsi]
    cmp rax, [rsi+8]
    jae .Ltc_finish_bad
    imul rax, rax, 24
    mov r11, [r12+rax+8]               # raw beginning of block
    mov rax, [rsi+16]
    test rax, rax
    jns .Ltc_finish_magnitude
    neg rax                           # unsigned magnitude also handles INT64_MIN
.Ltc_finish_magnitude:
    mov ecx, [rip+sample_rate]
    mul rcx
    add rax, 500000000
    adc rdx, 0
    mov ecx, 1000000000
    cmp rdx, rcx
    jae .Ltc_finish_bad
    div rcx
    mov rcx, r10
    sub rcx, r11
    jc .Ltc_finish_bad
    cmp rax, rcx
    ja .Ltc_finish_bad                 # padding cannot exceed its entire block
    cmp qword ptr [rsi+16], 0
    jl .Ltc_finish_head
    mov r11, r10
    sub r11, rax
    jmp .Ltc_finish_clip
.Ltc_finish_head:
    lea r10, [r11+rax]
.Ltc_finish_clip:
    cmp r11, [rip+track_start_trim]
    cmovb r11, [rip+track_start_trim]
    cmp r10, r14
    cmova r10, r14
    cmp r11, r10
    jae .Ltc_finish_next
    mov [rdi], r11
    mov [rdi+8], r10
    sub r11, [rip+track_start_trim]
    sub r11, r15
    jc .Ltc_finish_bad
    mov [rdi+16], r11                  # compressed boundary before removal
    sub r10, [rdi]
    add r15, r10
    mov [rdi+24], r15
    add rdi, TC_ITEM
.Ltc_finish_next:
    add rsi, TC_ITEM
    inc ebx
    jmp .Ltc_finish_item
.Ltc_finish_done:
    sub [rip+total_frames], r15
    jc .Ltc_finish_bad
    sub rdi, [rip+tc_data]
    shr rdi, 5
    mov [rip+track_cut_count], edi
    mov dword ptr [rip+tc_ready], 1
    mov eax, 1
    jmp .Ltc_finish_return
.Ltc_finish_bad:
    xor eax, eax
.Ltc_finish_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_cuts_finish

# RCX=packet raw start, EDX=used, R8D=available -> EAX=used, EDX=available.
# At most one disjoint block-edge removal can intersect a packet.
FN track_cut_buffer
    mov eax, edx
    mov edx, r8d
    add rax, rcx
    add rdx, rcx
    cmp rax, rdx
    jae .Ltc_buffer_done
    xor r8d, r8d
    mov r9d, [rip+track_cut_count]
.Ltc_buffer_search:
    cmp r8d, r9d
    jae .Ltc_buffer_found
    mov r10d, r9d
    sub r10d, r8d
    shr r10d, 1
    add r10d, r8d
    mov r11d, r10d
    shl r11, 5
    add r11, [rip+tc_data]
    cmp [r11+8], rax
    ja .Ltc_buffer_upper
    lea r8d, [r10+1]
    jmp .Ltc_buffer_search
.Ltc_buffer_upper:
    mov r9d, r10d
    jmp .Ltc_buffer_search
.Ltc_buffer_found:
    cmp r8d, [rip+track_cut_count]
    jae .Ltc_buffer_done
    shl r8, 5
    add r8, [rip+tc_data]
    cmp [r8], rdx
    jae .Ltc_buffer_done
    cmp [r8], rax
    ja .Ltc_buffer_tail
    mov rax, [r8+8]
    cmp rax, rdx
    cmova rax, rdx
    jmp .Ltc_buffer_done
.Ltc_buffer_tail:
    mov rdx, [r8]
.Ltc_buffer_done:
    sub rax, rcx
    sub rdx, rcx
    ret
ENDFN track_cut_buffer

# RCX=presented target -> RAX=raw target. Equal boundaries skip all adjacent
# removals, including completely discarded blocks.
FN track_cut_to_raw
    mov rax, rcx
    add rax, [rip+track_start_trim]
    xor r8d, r8d
    mov r9d, [rip+track_cut_count]
.Ltc_raw_search:
    cmp r8d, r9d
    jae .Ltc_raw_found
    mov r10d, r9d
    sub r10d, r8d
    shr r10d, 1
    add r10d, r8d
    mov r11d, r10d
    shl r11, 5
    add r11, [rip+tc_data]
    cmp [r11+16], rcx
    ja .Ltc_raw_upper
    lea r8d, [r10+1]
    jmp .Ltc_raw_search
.Ltc_raw_upper:
    mov r9d, r10d
    jmp .Ltc_raw_search
.Ltc_raw_found:
    test r8d, r8d
    jz .Ltc_raw_done
    dec r8d
    shl r8, 5
    add r8, [rip+tc_data]
    add rax, [r8+24]
.Ltc_raw_done:
    ret
ENDFN track_cut_to_raw

# RCX=raw resume point -> RAX=presented position, saturated at global start.
FN track_cut_to_presented
    mov rax, rcx
    sub rax, [rip+track_start_trim]
    jb .Ltc_present_zero
    xor r8d, r8d
    mov r9d, [rip+track_cut_count]
.Ltc_present_search:
    cmp r8d, r9d
    jae .Ltc_present_found
    mov r10d, r9d
    sub r10d, r8d
    shr r10d, 1
    add r10d, r8d
    mov r11d, r10d
    shl r11, 5
    add r11, [rip+tc_data]
    cmp [r11], rcx
    ja .Ltc_present_upper
    lea r8d, [r10+1]
    jmp .Ltc_present_search
.Ltc_present_upper:
    mov r9d, r10d
    jmp .Ltc_present_search
.Ltc_present_found:
    test r8d, r8d
    jz .Ltc_present_done
    dec r8d
    shl r8, 5
    add r8, [rip+tc_data]
    mov rdx, [r8+24]
    mov r9, [r8+8]
    sub r9, rcx
    jbe .Ltc_present_subtract
    sub rdx, r9                       # only the removed prefix before this point
.Ltc_present_subtract:
    sub rax, rdx
    jae .Ltc_present_done
.Ltc_present_zero:
    xor eax, eax
.Ltc_present_done:
    ret
ENDFN track_cut_to_presented
