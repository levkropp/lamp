# Original Ogg version-0 demuxer in x86-64 assembly. MIT, see LICENSE.
# Single logical stream, sequential mapped input. CRC and structure validated
# once at open. Packet assembly uses one bounded 4 MiB allocation.
.include "lamp.inc"
.globl ogg_granule, ogg_total_granule, ogg_eos, ogg_packet_length
.globl ogg_packet_page, ogg_packet_last, ogg_packet_page_end
.globl ogg_cancel_ptr

.equ OGG_PACKET_CAP, 0x400000
.data
ogg_begin: .quad 0
ogg_cancel_ptr: .quad 0          #optional caller-owned DWORD cancellation flag
ogg_end: .quad 0
ogg_cursor: .quad 0
ogg_buffer: .quad 0
ogg_granule: .quad -1
ogg_total_granule: .quad 0
ogg_page_granule: .quad -1
ogg_eos: .long 0
ogg_packet_length: .long 0
ogg_packet_page: .quad 0
ogg_packet_last: .long 0
ogg_packet_page_end: .long 0
ogg_page_flags: .long 0
ogg_segments: .long 0
ogg_segment: .long 0
ogg_last_complete: .long -1
ogg_laces: .quad 0
ogg_body: .quad 0
ogg_serial: .long 0
ogg_sequence: .long 0
ogg_continued: .long 0
ogg_seen_eos: .long 0
ogg_crc_ready: .long 0
ogg_resume_segment: .long 0
.bss
ogg_crc_table: .zero (8*256)*4
.text
FN ogg_close
    sub rsp, 40
    mov rcx, [rip + ogg_buffer]
    test rcx, rcx
    jz .Logg_close_done
    call mem_free
    mov qword ptr [rip + ogg_buffer], 0
.Logg_close_done:
    add rsp, 40
    ret
ENDFN ogg_close

# Reuse an already validated mapped stream without allocation or a CRC pass.
FN ogg_rewind
    mov rax, [rip + ogg_begin]
    mov [rip + ogg_cursor], rax
    mov dword ptr [rip + ogg_segment], 0
    mov dword ptr [rip + ogg_segments], 0
    mov dword ptr [rip + ogg_page_flags], 0
    mov dword ptr [rip + ogg_eos], 0
    mov dword ptr [rip + ogg_packet_length], 0
    mov dword ptr [rip + ogg_packet_last], 0
    mov dword ptr [rip + ogg_packet_page_end], 0
    mov qword ptr [rip + ogg_packet_page], 0
    mov qword ptr [rip + ogg_granule], -1
    mov dword ptr [rip + ogg_resume_segment], 0
    ret
ENDFN ogg_rewind

# Capture a packet boundary in 16 bytes: validated page pointer and next lace.
# Normalize exhausted pages to the next page, keeping continued packets intact.
FN ogg_checkpoint
    mov eax, [rip + ogg_segment]
    cmp eax, [rip + ogg_segments]
    jb .Logg_checkpoint_current
    mov rdx, [rip + ogg_cursor]
    mov eax, [rip + ogg_resume_segment] #a restored page may not have been loaded yet
    jmp .Logg_checkpoint_store
.Logg_checkpoint_current:
    mov rdx, [rip + ogg_packet_page]
.Logg_checkpoint_store:
    mov [rcx], rdx
    mov [rcx + 8], eax
    mov dword ptr [rcx + 12], 0
    ret
ENDFN ogg_checkpoint

# Restore a checkpoint from this still-open validated mapping, without a CRC
# pass or allocation. Checks refuse closed/out-of-range or invalid lace state.
FN ogg_resume
    push rbx
    sub rsp, 32
    xor eax, eax
    cmp qword ptr [rip + ogg_buffer], 0
    je .Logg_resume_return
    mov rbx, rcx
    mov rdx, [rbx]
    cmp rdx, [rip + ogg_begin]
    jb .Logg_resume_return
    lea r8, [rdx + 27]
    cmp r8, [rip + ogg_end]
    ja .Logg_resume_return
    cmp dword ptr [rdx], 0x5367674f
    jne .Logg_resume_return
    movzx r8d, byte ptr [rdx + 26]
    cmp [rbx + 8], r8d
    ja .Logg_resume_return
    call ogg_rewind
    mov rax, [rbx]
    mov [rip + ogg_cursor], rax
    mov eax, [rbx + 8]
    mov [rip + ogg_resume_segment], eax
    mov eax, 1
.Logg_resume_return:
    add rsp, 32
    pop rbx
    ret
ENDFN ogg_resume

LOCALFN ogg_crc_init
    cmp dword ptr [rip + ogg_crc_ready], 0
    jne .Logg_crc_init_done
    lea r8, [rip + ogg_crc_table]
    xor r9d, r9d
.Logg_crc_init_byte:
    mov eax, r9d
    shl eax, 24
    mov ecx, 8
.Logg_crc_init_bit:
    shl eax, 1
    jnc .Logg_crc_init_next
    xor eax, 0x4c11db7
.Logg_crc_init_next:
    dec ecx
    jnz .Logg_crc_init_bit
    mov [r8 + r9*4], eax
    inc r9d
    cmp r9d, 256
    jb .Logg_crc_init_byte
    lea r11, [rip + ogg_crc_table + 1024]
    mov r10d, 7
.Logg_crc_init_slice:
    xor r9d, r9d
.Logg_crc_init_slice_byte:
    mov eax, [r11 + r9*4 - 1024]
    mov ecx, eax
    shr ecx, 24
    shl eax, 8
    xor eax, [r8 + rcx*4]
    mov [r11 + r9*4], eax
    inc r9d
    cmp r9d, 256
    jb .Logg_crc_init_slice_byte
    add r11, 1024
    dec r10d
    jnz .Logg_crc_init_slice
    mov dword ptr [rip + ogg_crc_ready], 1
.Logg_crc_init_done:
    ret
ENDFN ogg_crc_init

# RCX=bounded bytes,EDX=count,EAX=incoming nonreflected Ogg CRC.
# Eight independent table lookups avoid the serial dependency per input byte.
# Reads never cross the supplied extent; tails retain the original byte step.
LOCALFN ogg_crc_bytes
    lea r8, [rip + ogg_crc_table]
    cmp edx, 8
    jb .Logg_crc_tail
.Logg_crc_eight:
    mov r10d, [rcx]
    bswap r10d
    xor r10d, eax
    movzx r11d, r10b
    mov eax, [r8 + r11*4 + 4096]
    shr r10d, 8
    movzx r11d, r10b
    xor eax, [r8 + r11*4 + 5120]
    shr r10d, 8
    movzx r11d, r10b
    xor eax, [r8 + r11*4 + 6144]
    shr r10d, 8
    xor eax, [r8 + r10*4 + 7168]
    mov r9d, [rcx + 4]
    movzx r11d, r9b
    xor eax, [r8 + r11*4 + 3072]
    shr r9d, 8
    movzx r11d, r9b
    xor eax, [r8 + r11*4 + 2048]
    shr r9d, 8
    movzx r11d, r9b
    xor eax, [r8 + r11*4 + 1024]
    shr r9d, 8
    xor eax, [r8 + r9*4]
    add rcx, 8
    sub edx, 8
    cmp edx, 8
    jae .Logg_crc_eight
.Logg_crc_tail:
    test edx, edx
    jz .Logg_crc_bytes_done
.Logg_crc_tail_byte:
    mov r9d, eax
    shr r9d, 24
    movzx r10d, byte ptr [rcx]
    xor r9d, r10d
    shl eax, 8
    xor eax, [r8 + r9*4]
    inc rcx
    dec edx
    jnz .Logg_crc_tail_byte
.Logg_crc_bytes_done:
    ret
ENDFN ogg_crc_bytes

# RCX=page. RAX=next page or zero. Sequence/continuation state is updated.
LOCALFN ogg_validate_page
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    lea rax, [rsi + 27]
    cmp rax, [rip + ogg_end]
    ja .Logg_page_bad
    cmp dword ptr [rsi], 0x5367674f
    jne .Logg_page_bad
    cmp byte ptr [rsi + 4], 0
    jne .Logg_page_bad
    movzx ebx, byte ptr [rsi + 5]
    test ebx, 0xf8
    jnz .Logg_page_bad
    cmp dword ptr [rip + ogg_seen_eos], 0
    jne .Logg_page_bad
    mov eax, [rsi + 18]
    cmp eax, [rip + ogg_sequence]
    jne .Logg_page_bad
    cmp dword ptr [rip + ogg_sequence], 0
    jne .Logg_page_later
    cmp ebx, 2
    jne .Logg_page_bad
    mov eax, [rsi + 14]
    mov [rip + ogg_serial], eax
    jmp .Logg_page_stream_ok
.Logg_page_later:
    test ebx, 2
    jnz .Logg_page_bad
    mov eax, [rsi + 14]
    cmp eax, [rip + ogg_serial]
    jne .Logg_page_bad
    mov eax, ebx
    and eax, 1
    cmp eax, [rip + ogg_continued]
    jne .Logg_page_bad
.Logg_page_stream_ok:
    movzx r9d, byte ptr [rsi + 26]
    lea rdi, [rsi + r9 + 27]
    cmp rdi, [rip + ogg_end]
    ja .Logg_page_bad
    xor edx, edx
    xor ecx, ecx
    mov r10d, -1
.Logg_page_lengths:
    cmp ecx, r9d
    jae .Logg_page_length_done
    movzx eax, byte ptr [rsi + rcx + 27]
    add edx, eax
    cmp eax, 255
    je .Logg_page_no_complete
    mov r10d, ecx
.Logg_page_no_complete:
    inc ecx
    jmp .Logg_page_lengths
.Logg_page_length_done:
    add rdi, rdx
    cmp rdi, [rip + ogg_end]
    ja .Logg_page_bad
    test r9d, r9d
    jz .Logg_page_empty
    movzx eax, byte ptr [rsi + r9 + 26]
    cmp eax, 255
    sete al
    movzx eax, al
    mov [rip + ogg_continued], eax
.Logg_page_empty:
    test ebx, 4
    jz .Logg_check_granule
    cmp dword ptr [rip + ogg_continued], 0
    jne .Logg_page_bad
    mov dword ptr [rip + ogg_seen_eos], 1
    cmp rdi, [rip + ogg_end]
    jne .Logg_page_bad          # Chained/multiplexed streams need a new decoder.
.Logg_check_granule:
    mov rax, [rsi + 6]
    cmp r10d, -1
    jne .Logg_page_has_complete
    cmp rax, -1
    jne .Logg_page_bad
    jmp .Logg_page_crc
.Logg_page_has_complete:
    test rax, rax
    js .Logg_page_unknown
    cmp rax, [rip + ogg_total_granule]
    jb .Logg_page_bad
    mov [rip + ogg_total_granule], rax
    jmp .Logg_page_crc
.Logg_page_unknown:
    cmp rax, -1
    jne .Logg_page_bad
    test ebx, 4
    jnz .Logg_page_bad
.Logg_page_crc:
    xor eax, eax
    mov rcx, rsi
    mov edx, 22
    call ogg_crc_bytes
    mov ecx, 4              #checksum bytes22..25 are defined as zero
.Logg_page_crc_zero:
    mov edx, eax
    shr edx, 24
    shl eax, 8
    xor eax, [r8 + rdx*4]
    dec ecx
    jnz .Logg_page_crc_zero
    lea rcx, [rsi + 26]
    mov rdx, rdi
    sub rdx, rcx
    call ogg_crc_bytes
    cmp eax, [rsi + 22]
    jne .Logg_page_bad
    inc dword ptr [rip + ogg_sequence]
    mov rax, rdi
    jmp .Logg_page_return
.Logg_page_bad:
    xor eax, eax
.Logg_page_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ogg_validate_page

# RCX=mapped beginning, RDX=end. Validate complete file before exposing packets.
FN ogg_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov [rip + ogg_begin], rcx
    mov [rip + ogg_end], rdx
    mov rsi, rcx
    call ogg_close
    call ogg_crc_init
    mov dword ptr [rip + ogg_sequence], 0
    mov dword ptr [rip + ogg_continued], 0
    mov dword ptr [rip + ogg_seen_eos], 0
    mov qword ptr [rip + ogg_total_granule], 0
.Logg_open_page:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Logg_open_continue
    cmp dword ptr [rax], 0
    jne .Logg_open_bad
.Logg_open_continue:
    cmp rsi, [rip + ogg_end]
    jae .Logg_open_end
    mov rcx, rsi
    call ogg_validate_page
    test rax, rax
    jz .Logg_open_bad
    mov rsi, rax
    jmp .Logg_open_page
.Logg_open_end:
    cmp dword ptr [rip + ogg_seen_eos], 1
    jne .Logg_open_bad
    cmp dword ptr [rip + ogg_continued], 0
    jne .Logg_open_bad
    mov ecx, OGG_PACKET_CAP
    call mem_alloc
    test rax, rax
    jz .Logg_open_bad
    mov [rip + ogg_buffer], rax
    call ogg_rewind
    mov eax, 1
    jmp .Logg_open_return
.Logg_open_bad:
    mov dword ptr [rip + decode_error], 21
    xor eax, eax
.Logg_open_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ogg_open

# RAX=assembled packet, EDX=length; zero RAX means EOF/error. Empty packets
# still return a nonzero pointer. Granule belongs to the last complete packet
# on a page, including pages whose final packet continues to the next page.
FN ogg_next
    push rbx
    push rsi
    push rdi
    xor ebx, ebx
    mov qword ptr [rip + ogg_granule], -1
    mov dword ptr [rip + ogg_eos], 0
    mov dword ptr [rip + ogg_packet_last], 0
    mov dword ptr [rip + ogg_packet_page_end], 0
.Logg_next_segment:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Logg_next_continue
    cmp dword ptr [rax], 0
    jne .Logg_next_bad
.Logg_next_continue:
    mov eax, [rip + ogg_segment]
    cmp eax, [rip + ogg_segments]
    jb .Logg_next_copy
    mov rsi, [rip + ogg_cursor]
    cmp rsi, [rip + ogg_end]
    jae .Logg_next_eof
    mov [rip + ogg_packet_page], rsi
    movzx eax, byte ptr [rsi + 5]
    mov [rip + ogg_page_flags], eax
    mov rax, [rsi + 6]
    mov [rip + ogg_page_granule], rax
    lea rax, [rsi + 27]
    mov [rip + ogg_laces], rax
    movzx ecx, byte ptr [rsi + 26]
    mov [rip + ogg_segments], ecx
    mov dword ptr [rip + ogg_segment], 0
    mov dword ptr [rip + ogg_last_complete], -1
    lea rdi, [rsi + rcx + 27]
    mov [rip + ogg_body], rdi
    xor edx, edx
    xor eax, eax
.Logg_next_page_laces:
    cmp eax, ecx
    jae .Logg_next_page_ready
    movzx r8d, byte ptr [rsi + rax + 27]
    add edx, r8d
    cmp r8d, 255
    je .Logg_next_lace_continue
    mov [rip + ogg_last_complete], eax
.Logg_next_lace_continue:
    inc eax
    jmp .Logg_next_page_laces
.Logg_next_page_ready:
    add rdi, rdx
    mov [rip + ogg_cursor], rdi
    mov ecx, [rip + ogg_resume_segment]
    mov dword ptr [rip + ogg_resume_segment], 0
    mov [rip + ogg_segment], ecx
    xor eax, eax
.Logg_next_resume_laces:
    cmp eax, ecx
    jae .Logg_next_segment
    mov r8, [rip + ogg_laces]
    movzx edx, byte ptr [r8 + rax]
    add [rip + ogg_body], rdx
    inc eax
    jmp .Logg_next_resume_laces
.Logg_next_copy:
    mov r8, [rip + ogg_laces]
    movzx r9d, byte ptr [r8 + rax]
    mov ecx, ebx
    add ecx, r9d
    cmp ecx, OGG_PACKET_CAP
    ja .Logg_next_bad
    mov rsi, [rip + ogg_body]
    mov rdi, [rip + ogg_buffer]
    add rdi, rbx
    mov ecx, r9d
    rep movsb
    mov [rip + ogg_body], rsi
    add ebx, r9d
    inc dword ptr [rip + ogg_segment]
    cmp r9d, 255
    je .Logg_next_segment
    mov eax, [rip + ogg_segment]
    cmp eax, [rip + ogg_segments]
    sete al
    movzx eax, al
    mov [rip + ogg_packet_page_end], eax
    mov eax, [rip + ogg_segment]
    dec eax
    cmp eax, [rip + ogg_last_complete]
    jne .Logg_next_packet
    mov dword ptr [rip + ogg_packet_last], 1
    mov rax, [rip + ogg_page_granule]
    mov [rip + ogg_granule], rax
    mov eax, [rip + ogg_page_flags]
    shr eax, 2
    and eax, 1
    mov [rip + ogg_eos], eax
.Logg_next_packet:
    mov [rip + ogg_packet_length], ebx
    mov edx, ebx
    mov rax, [rip + ogg_buffer]
    jmp .Logg_next_return
.Logg_next_bad:
    mov dword ptr [rip + decode_error], 22
.Logg_next_eof:
    xor eax, eax
    xor edx, edx
.Logg_next_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ogg_next
