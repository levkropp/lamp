; Original Ogg version-0 demuxer in x86-64 assembly. MIT, see LICENSE.
; Single logical stream, sequential mapped input. CRC and structure validated
; once at open. Packet assembly uses one bounded 4 MiB allocation.
option casemap:none
EXTERN VirtualAlloc:PROC, VirtualFree:PROC
EXTERN decode_error:DWORD
PUBLIC ogg_open, ogg_next, ogg_close, ogg_rewind
PUBLIC ogg_checkpoint,ogg_resume
PUBLIC ogg_granule, ogg_total_granule, ogg_eos, ogg_packet_length
PUBLIC ogg_packet_page, ogg_packet_last, ogg_packet_page_end
PUBLIC ogg_cancel_ptr

OGG_PACKET_CAP EQU 400000h
.data
ogg_begin dq 0
ogg_cancel_ptr dq 0          ;optional caller-owned DWORD cancellation flag
ogg_end dq 0
ogg_cursor dq 0
ogg_buffer dq 0
ogg_granule dq -1
ogg_total_granule dq 0
ogg_page_granule dq -1
ogg_eos dd 0
ogg_packet_length dd 0
ogg_packet_page dq 0
ogg_packet_last dd 0
ogg_packet_page_end dd 0
ogg_page_flags dd 0
ogg_segments dd 0
ogg_segment dd 0
ogg_last_complete dd -1
ogg_laces dq 0
ogg_body dq 0
ogg_serial dd 0
ogg_sequence dd 0
ogg_continued dd 0
ogg_seen_eos dd 0
ogg_crc_ready dd 0
ogg_resume_segment dd 0
.data?
ogg_crc_table dd 256 dup (?)
.code
ogg_close PROC
    sub rsp,40
    mov rcx,[ogg_buffer]
    test rcx,rcx
    jz ogg_close_done
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
    mov qword ptr [ogg_buffer],0
ogg_close_done:
    add rsp,40
    ret
ogg_close ENDP

; Reuse an already validated mapped stream without allocation or a CRC pass.
ogg_rewind PROC
    mov rax,[ogg_begin]
    mov [ogg_cursor],rax
    mov dword ptr [ogg_segment],0
    mov dword ptr [ogg_segments],0
    mov dword ptr [ogg_page_flags],0
    mov dword ptr [ogg_eos],0
    mov dword ptr [ogg_packet_length],0
    mov dword ptr [ogg_packet_last],0
    mov dword ptr [ogg_packet_page_end],0
    mov qword ptr [ogg_packet_page],0
    mov qword ptr [ogg_granule],-1
    mov dword ptr [ogg_resume_segment],0
    ret
ogg_rewind ENDP

; Capture a packet boundary in 16 bytes: validated page pointer and next lace.
; Normalize exhausted pages to the next page, keeping continued packets intact.
ogg_checkpoint PROC
    mov eax,[ogg_segment]
    cmp eax,[ogg_segments]
    jb ogg_checkpoint_current
    mov rdx,[ogg_cursor]
    mov eax,[ogg_resume_segment] ;a restored page may not have been loaded yet
    jmp ogg_checkpoint_store
ogg_checkpoint_current:
    mov rdx,[ogg_packet_page]
ogg_checkpoint_store:
    mov [rcx],rdx
    mov [rcx+8],eax
    mov dword ptr [rcx+12],0
    ret
ogg_checkpoint ENDP

; Restore a checkpoint from this still-open validated mapping, without a CRC
; pass or allocation. Checks refuse closed/out-of-range or invalid lace state.
ogg_resume PROC
    push rbx
    sub rsp,32
    xor eax,eax
    cmp qword ptr [ogg_buffer],0
    je ogg_resume_return
    mov rbx,rcx
    mov rdx,[rbx]
    cmp rdx,[ogg_begin]
    jb ogg_resume_return
    lea r8,[rdx+27]
    cmp r8,[ogg_end]
    ja ogg_resume_return
    cmp dword ptr [rdx],5367674fh
    jne ogg_resume_return
    movzx r8d,byte ptr [rdx+26]
    cmp [rbx+8],r8d
    ja ogg_resume_return
    call ogg_rewind
    mov rax,[rbx]
    mov [ogg_cursor],rax
    mov eax,[rbx+8]
    mov [ogg_resume_segment],eax
    mov eax,1
ogg_resume_return:
    add rsp,32
    pop rbx
    ret
ogg_resume ENDP

ogg_crc_init PROC
    cmp dword ptr [ogg_crc_ready],0
    jne ogg_crc_init_done
    lea r8,ogg_crc_table
    xor r9d,r9d
ogg_crc_init_byte:
    mov eax,r9d
    shl eax,24
    mov ecx,8
ogg_crc_init_bit:
    shl eax,1
    jnc ogg_crc_init_next
    xor eax,04c11db7h
ogg_crc_init_next:
    dec ecx
    jnz ogg_crc_init_bit
    mov [r8+r9*4],eax
    inc r9d
    cmp r9d,256
    jb ogg_crc_init_byte
    mov dword ptr [ogg_crc_ready],1
ogg_crc_init_done:
    ret
ogg_crc_init ENDP

; RCX=page. RAX=next page or zero. Sequence/continuation state is updated.
ogg_validate_page PROC
    push rbx
    push rsi
    push rdi
    mov rsi,rcx
    lea rax,[rsi+27]
    cmp rax,[ogg_end]
    ja ogg_page_bad
    cmp dword ptr [rsi],5367674fh
    jne ogg_page_bad
    cmp byte ptr [rsi+4],0
    jne ogg_page_bad
    movzx ebx,byte ptr [rsi+5]
    test ebx,0f8h
    jnz ogg_page_bad
    cmp dword ptr [ogg_seen_eos],0
    jne ogg_page_bad
    mov eax,[rsi+18]
    cmp eax,[ogg_sequence]
    jne ogg_page_bad
    cmp dword ptr [ogg_sequence],0
    jne ogg_page_later
    cmp ebx,2
    jne ogg_page_bad
    mov eax,[rsi+14]
    mov [ogg_serial],eax
    jmp ogg_page_stream_ok
ogg_page_later:
    test ebx,2
    jnz ogg_page_bad
    mov eax,[rsi+14]
    cmp eax,[ogg_serial]
    jne ogg_page_bad
    mov eax,ebx
    and eax,1
    cmp eax,[ogg_continued]
    jne ogg_page_bad
ogg_page_stream_ok:
    movzx r9d,byte ptr [rsi+26]
    lea rdi,[rsi+r9+27]
    cmp rdi,[ogg_end]
    ja ogg_page_bad
    xor edx,edx
    xor ecx,ecx
    mov r10d,-1
ogg_page_lengths:
    cmp ecx,r9d
    jae ogg_page_length_done
    movzx eax,byte ptr [rsi+rcx+27]
    add edx,eax
    cmp eax,255
    je ogg_page_no_complete
    mov r10d,ecx
ogg_page_no_complete:
    inc ecx
    jmp ogg_page_lengths
ogg_page_length_done:
    add rdi,rdx
    cmp rdi,[ogg_end]
    ja ogg_page_bad
    test r9d,r9d
    jz ogg_page_empty
    movzx eax,byte ptr [rsi+r9+26]
    cmp eax,255
    sete al
    movzx eax,al
    mov [ogg_continued],eax
ogg_page_empty:
    test ebx,4
    jz ogg_check_granule
    cmp dword ptr [ogg_continued],0
    jne ogg_page_bad
    mov dword ptr [ogg_seen_eos],1
    cmp rdi,[ogg_end]
    jne ogg_page_bad          ; Chained/multiplexed streams need a new decoder.
ogg_check_granule:
    mov rax,[rsi+6]
    cmp r10d,-1
    jne ogg_page_has_complete
    cmp rax,-1
    jne ogg_page_bad
    jmp ogg_page_crc
ogg_page_has_complete:
    test rax,rax
    js ogg_page_unknown
    cmp rax,[ogg_total_granule]
    jb ogg_page_bad
    mov [ogg_total_granule],rax
    jmp ogg_page_crc
ogg_page_unknown:
    cmp rax,-1
    jne ogg_page_bad
    test ebx,4
    jnz ogg_page_bad
ogg_page_crc:
    xor eax,eax
    xor ecx,ecx
    lea r8,ogg_crc_table
    mov r9,rdi
    sub r9,rsi
ogg_page_crc_byte:
    xor edx,edx
    cmp ecx,22
    jb ogg_page_crc_read
    cmp ecx,26
    jb ogg_page_crc_update
ogg_page_crc_read:
    movzx edx,byte ptr [rsi+rcx]
ogg_page_crc_update:
    mov r10d,eax
    shr r10d,24
    xor edx,r10d
    shl eax,8
    xor eax,[r8+rdx*4]
    inc ecx
    cmp rcx,r9
    jb ogg_page_crc_byte
    cmp eax,[rsi+22]
    jne ogg_page_bad
    inc dword ptr [ogg_sequence]
    mov rax,rdi
    jmp ogg_page_return
ogg_page_bad:
    xor eax,eax
ogg_page_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ogg_validate_page ENDP

; RCX=mapped beginning, RDX=end. Validate complete file before exposing packets.
ogg_open PROC
    push rbx
    push rsi
    push rdi
    sub rsp,32
    mov [ogg_begin],rcx
    mov [ogg_end],rdx
    mov rsi,rcx
    call ogg_close
    call ogg_crc_init
    mov dword ptr [ogg_sequence],0
    mov dword ptr [ogg_continued],0
    mov dword ptr [ogg_seen_eos],0
    mov qword ptr [ogg_total_granule],0
ogg_open_page:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz ogg_open_continue
    cmp dword ptr [rax],0
    jne ogg_open_bad
ogg_open_continue:
    cmp rsi,[ogg_end]
    jae ogg_open_end
    mov rcx,rsi
    call ogg_validate_page
    test rax,rax
    jz ogg_open_bad
    mov rsi,rax
    jmp ogg_open_page
ogg_open_end:
    cmp dword ptr [ogg_seen_eos],1
    jne ogg_open_bad
    cmp dword ptr [ogg_continued],0
    jne ogg_open_bad
    xor ecx,ecx
    mov edx,OGG_PACKET_CAP
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    test rax,rax
    jz ogg_open_bad
    mov [ogg_buffer],rax
    call ogg_rewind
    mov eax,1
    jmp ogg_open_return
ogg_open_bad:
    mov dword ptr [decode_error],21
    xor eax,eax
ogg_open_return:
    add rsp,32
    pop rdi
    pop rsi
    pop rbx
    ret
ogg_open ENDP

; RAX=assembled packet, EDX=length; zero RAX means EOF/error. Empty packets
; still return a nonzero pointer. Granule belongs to the last complete packet
; on a page, including pages whose final packet continues to the next page.
ogg_next PROC
    push rbx
    push rsi
    push rdi
    xor ebx,ebx
    mov qword ptr [ogg_granule],-1
    mov dword ptr [ogg_eos],0
    mov dword ptr [ogg_packet_last],0
    mov dword ptr [ogg_packet_page_end],0
ogg_next_segment:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz ogg_next_continue
    cmp dword ptr [rax],0
    jne ogg_next_bad
ogg_next_continue:
    mov eax,[ogg_segment]
    cmp eax,[ogg_segments]
    jb ogg_next_copy
    mov rsi,[ogg_cursor]
    cmp rsi,[ogg_end]
    jae ogg_next_eof
    mov [ogg_packet_page],rsi
    movzx eax,byte ptr [rsi+5]
    mov [ogg_page_flags],eax
    mov rax,[rsi+6]
    mov [ogg_page_granule],rax
    lea rax,[rsi+27]
    mov [ogg_laces],rax
    movzx ecx,byte ptr [rsi+26]
    mov [ogg_segments],ecx
    mov dword ptr [ogg_segment],0
    mov dword ptr [ogg_last_complete],-1
    lea rdi,[rsi+rcx+27]
    mov [ogg_body],rdi
    xor edx,edx
    xor eax,eax
ogg_next_page_laces:
    cmp eax,ecx
    jae ogg_next_page_ready
    movzx r8d,byte ptr [rsi+rax+27]
    add edx,r8d
    cmp r8d,255
    je ogg_next_lace_continue
    mov [ogg_last_complete],eax
ogg_next_lace_continue:
    inc eax
    jmp ogg_next_page_laces
ogg_next_page_ready:
    add rdi,rdx
    mov [ogg_cursor],rdi
    mov ecx,[ogg_resume_segment]
    mov dword ptr [ogg_resume_segment],0
    mov [ogg_segment],ecx
    xor eax,eax
ogg_next_resume_laces:
    cmp eax,ecx
    jae ogg_next_segment
    mov r8,[ogg_laces]
    movzx edx,byte ptr [r8+rax]
    add [ogg_body],rdx
    inc eax
    jmp ogg_next_resume_laces
ogg_next_copy:
    mov r8,[ogg_laces]
    movzx r9d,byte ptr [r8+rax]
    mov ecx,ebx
    add ecx,r9d
    cmp ecx,OGG_PACKET_CAP
    ja ogg_next_bad
    mov rsi,[ogg_body]
    mov rdi,[ogg_buffer]
    add rdi,rbx
    mov ecx,r9d
    rep movsb
    mov [ogg_body],rsi
    add ebx,r9d
    inc dword ptr [ogg_segment]
    cmp r9d,255
    je ogg_next_segment
    mov eax,[ogg_segment]
    cmp eax,[ogg_segments]
    sete al
    movzx eax,al
    mov [ogg_packet_page_end],eax
    mov eax,[ogg_segment]
    dec eax
    cmp eax,[ogg_last_complete]
    jne ogg_next_packet
    mov dword ptr [ogg_packet_last],1
    mov rax,[ogg_page_granule]
    mov [ogg_granule],rax
    mov eax,[ogg_page_flags]
    shr eax,2
    and eax,1
    mov [ogg_eos],eax
ogg_next_packet:
    mov [ogg_packet_length],ebx
    mov edx,ebx
    mov rax,[ogg_buffer]
    jmp ogg_next_return
ogg_next_bad:
    mov dword ptr [decode_error],22
ogg_next_eof:
    xor eax,eax
    xor edx,edx
ogg_next_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ogg_next ENDP
END
