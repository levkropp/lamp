; Original bounded Opus packet framing and Ogg header parser. MIT.
; Reference: RFC6716 section 3 and RFC7845 mapping family 0.
option casemap:none
EXTERN ogg_open:PROC, ogg_next:PROC, ogg_total_granule:QWORD
EXTERN ogg_granule:QWORD,ogg_packet_page:QWORD,ogg_packet_page_end:DWORD
EXTERN sample_rate:DWORD, source_channels:DWORD, source_bits:DWORD
EXTERN total_frames:QWORD, decode_error:DWORD
PUBLIC opus_headers, op_opus_packet_parse
PUBLIC op_frame_ptr, op_frame_size, op_frame_count, op_frame_samples
PUBLIC op_config, op_stereo, op_preskip, op_gain, op_packet_samples
.data
op_frame_count dd 0
op_frame_samples dd 0
op_packet_samples dd 0
op_config dd 0
op_stereo dd 0
op_preskip dd 0
op_gain dd 0
op_silk_duration dd 480,960,1920,2880
.data?
op_frame_ptr dq 48 dup (?)
op_frame_size dd 48 dup (?)
.code
; RCX=cursor, RDX=end -> EAX=0..1275 or -1, RCX advanced.
opus_read_size PROC
    cmp rcx,rdx
    jae opus_size_bad
    movzx eax,byte ptr [rcx]
    inc rcx
    cmp eax,252
    jb opus_size_done
    cmp rcx,rdx
    jae opus_size_bad
    movzx r8d,byte ptr [rcx]
    inc rcx
    lea eax,[rax+r8*4]
opus_size_done:
    ret
opus_size_bad:
    mov eax,-1
    ret
opus_read_size ENDP

; RCX=packet, EDX=bytes -> EAX=frame count or zero on invalid framing.
op_opus_packet_parse PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,32
    mov dword ptr [op_frame_count],0
    test edx,edx
    jz opus_packet_bad
    mov rsi,rcx
    lea rdi,[rcx+rdx]
    movzx ebx,byte ptr [rsi]
    inc rsi
    mov eax,ebx
    shr eax,3
    mov [op_config],eax
    mov edx,ebx
    shr edx,2
    and edx,1
    mov [op_stereo],edx
    cmp eax,12
    jb opus_packet_silk
    cmp eax,16
    jb opus_packet_hybrid
    and eax,3
    mov ecx,eax
    mov eax,120
    shl eax,cl
    jmp opus_packet_duration
opus_packet_hybrid:
    and eax,1
    mov ecx,eax
    mov eax,480
    shl eax,cl
    jmp opus_packet_duration
opus_packet_silk:
    and eax,3
    lea rdx,op_silk_duration
    mov eax,[rdx+rax*4]
opus_packet_duration:
    mov [op_frame_samples],eax
    and ebx,3
    cmp ebx,0
    je opus_packet_code0
    cmp ebx,1
    je opus_packet_code1
    cmp ebx,2
    je opus_packet_code2
    cmp rsi,rdi
    jae opus_packet_bad
    movzx r13d,byte ptr [rsi]
    inc rsi
    mov r12d,r13d
    and r12d,63
    test r12d,r12d
    jz opus_packet_bad
    cmp r12d,48
    ja opus_packet_bad
    mov eax,[op_frame_samples]
    imul eax,r12d
    cmp eax,5760
    ja opus_packet_bad
    test r13d,40h
    jz opus_packet_code3_body
    xor r15d,r15d
opus_packet_padding:
    cmp rsi,rdi
    jae opus_packet_bad
    movzx eax,byte ptr [rsi]
    inc rsi
    mov edx,eax
    cmp eax,255
    jne opus_packet_padding_last
    dec eax
opus_packet_padding_last:
    add r15,rax
    mov rax,rdi
    sub rax,rsi
    cmp r15,rax
    ja opus_packet_bad
    cmp edx,255
    je opus_packet_padding
    sub rdi,r15
opus_packet_code3_body:
    test r13d,80h
    jz opus_packet_cbr
    xor r14d,r14d
    xor r15d,r15d
opus_packet_vbr_size:
    lea eax,[r14+1]
    cmp eax,r12d
    jae opus_packet_vbr_last
    mov rcx,rsi
    mov rdx,rdi
    call opus_read_size
    cmp eax,-1
    je opus_packet_bad
    mov rsi,rcx
    lea rdx,op_frame_size
    mov [rdx+r14*4],eax
    add r15,rax
    inc r14d
    jmp opus_packet_vbr_size
opus_packet_vbr_last:
    mov rax,rdi
    sub rax,rsi
    sub rax,r15
    jc opus_packet_bad
    cmp rax,1275
    ja opus_packet_bad
    lea rdx,op_frame_size
    mov [rdx+r14*4],eax
    jmp opus_packet_pointers
opus_packet_code0:
    mov r12d,1
    jmp opus_packet_cbr
opus_packet_code1:
    mov r12d,2
    jmp opus_packet_cbr
opus_packet_code2:
    mov r12d,2
    mov rcx,rsi
    mov rdx,rdi
    call opus_read_size
    cmp eax,-1
    je opus_packet_bad
    mov rsi,rcx
    mov [op_frame_size],eax
    mov rdx,rdi
    sub rdx,rsi
    sub rdx,rax
    jc opus_packet_bad
    cmp rdx,1275
    ja opus_packet_bad
    mov [op_frame_size+4],edx
    jmp opus_packet_pointers
opus_packet_cbr:
    mov rax,rdi
    sub rax,rsi
    xor edx,edx
    div r12
    test edx,edx
    jnz opus_packet_bad
    cmp rax,1275
    ja opus_packet_bad
    xor r14d,r14d
    lea rdx,op_frame_size
opus_packet_cbr_fill:
    mov [rdx+r14*4],eax
    inc r14d
    cmp r14d,r12d
    jb opus_packet_cbr_fill
opus_packet_pointers:
    lea r8,op_frame_ptr
    lea r9,op_frame_size
    xor r14d,r14d
opus_packet_pointer:
    mov [r8+r14*8],rsi
    mov eax,[r9+r14*4]
    add rsi,rax
    cmp rsi,rdi
    ja opus_packet_bad
    inc r14d
    cmp r14d,r12d
    jb opus_packet_pointer
    cmp rsi,rdi
    jne opus_packet_bad
    mov [op_frame_count],r12d
    mov eax,[op_frame_samples]
    imul eax,r12d
    mov [op_packet_samples],eax
    mov eax,r12d
    jmp opus_packet_done
opus_packet_bad:
    xor eax,eax
opus_packet_done:
    add rsp,32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_opus_packet_parse ENDP

; RCX=mapped beginning, RDX=end. PCM reconstruction is a separate stage.
opus_headers PROC
    push rbx
    push rsi
    push rdi
    sub rsp,32
    mov rbx,rcx
    call ogg_open
    test eax,eax
    jz opus_header_bad
    call ogg_next
    test rax,rax
    jz opus_header_bad
    cmp [ogg_packet_page],rbx
    jne opus_header_bad
    cmp dword ptr [ogg_packet_page_end],1
    jne opus_header_bad
    cmp qword ptr [ogg_granule],0
    jne opus_header_bad
    cmp edx,19
    jb opus_header_bad
    mov r8,0646165487375704fh ; OpusHead
    cmp [rax],r8
    jne opus_header_bad
    cmp byte ptr [rax+8],15
    ja opus_header_bad
    movzx ecx,byte ptr [rax+9]
    cmp ecx,1
    jb opus_header_bad
    cmp ecx,2
    ja opus_header_bad
    cmp byte ptr [rax+18],0
    jne opus_header_bad       ; mapping family 0, mono/stereo
    cmp byte ptr [rax+8],1
    ja opus_header_extended
    cmp edx,19
    jne opus_header_bad
opus_header_extended:
    mov [source_channels],ecx
    movzx ecx,word ptr [rax+10]
    mov [op_preskip],ecx
    movsx ecx,word ptr [rax+16]
    mov [op_gain],ecx         ; signed Q8 dB; applied after synthesis
    mov dword ptr [sample_rate],48000
    mov dword ptr [source_bits],32
    mov qword ptr [total_frames],0 ;audio-page anchoring establishes duration
    call ogg_next
    test rax,rax
    jz opus_header_bad
    cmp dword ptr [ogg_packet_page_end],1
    jne opus_header_bad
    cmp qword ptr [ogg_granule],0
    jne opus_header_bad
    cmp edx,16
    jb opus_header_bad
    mov r8,0736761547375704fh ; OpusTags
    cmp [rax],r8
    jne opus_header_bad
    lea rdi,[rax+rdx]
    lea rsi,[rax+8]
    mov eax,[rsi]
    add rsi,4
    add rsi,rax
    lea rax,[rsi+4]
    cmp rax,rdi
    ja opus_header_bad
    mov ebx,[rsi]
    add rsi,4
opus_header_comment:
    test ebx,ebx
    jz opus_header_ok
    lea rax,[rsi+4]
    cmp rax,rdi
    ja opus_header_bad
    mov eax,[rsi]
    add rsi,4
    add rsi,rax
    cmp rsi,rdi
    ja opus_header_bad
    dec ebx
    jmp opus_header_comment
opus_header_ok:
    mov eax,1
    jmp opus_header_done
opus_header_bad:
    mov dword ptr [decode_error],25
    xor eax,eax
opus_header_done:
    add rsp,32
    pop rdi
    pop rsi
    pop rbx
    ret
opus_headers ENDP
END
