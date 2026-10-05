# Original bounded Opus packet framing and Ogg header parser. MIT.
# Reference: RFC6716 section3/AppendixB and RFC7845 mapping families0/1.
.include "lamp.inc"
.globl op_packet_bytes
.globl op_mapping, op_streams, op_coupled, op_channel_map
.globl op_frame_ptr, op_frame_size, op_frame_count, op_frame_samples
.globl op_config, op_stereo, op_preskip, op_gain, op_packet_samples
.data
op_frame_count: .long 0
op_frame_samples: .long 0
op_packet_samples: .long 0
op_packet_bytes: .long 0         #consumed prefix,including any declared padding
op_config: .long 0
op_stereo: .long 0
op_preskip: .long 0
op_gain: .long 0
op_mapping: .long 0
op_streams: .long 1
op_coupled: .long 0
op_channel_map: .zero 8
op_silk_duration: .long 480, 960, 1920, 2880
.bss
op_frame_ptr: .zero 48*8
op_frame_size: .zero 48*4
.text
# RCX=cursor, RDX=end -> EAX=0..1275 or -1, RCX advanced.
LOCALFN opus_read_size
    cmp rcx, rdx
    jae .Lopus_size_bad
    movzx eax, byte ptr [rcx]
    inc rcx
    cmp eax, 252
    jb .Lopus_size_done
    cmp rcx, rdx
    jae .Lopus_size_bad
    movzx r8d, byte ptr [rcx]
    inc rcx
    lea eax, [rax + r8*4]
.Lopus_size_done:
    ret
.Lopus_size_bad:
    mov eax, -1
    ret
ENDFN opus_read_size

# RCX=packet, EDX=bytes -> EAX=frame count or zero on invalid framing.
FN op_opus_packet_parse
    xor r8d, r8d
    jmp op_opus_packet_parse_ex
ENDFN op_opus_packet_parse

# RCX=packet,EDX=available bytes,R8D=0 regular/1 self-delimited (RFC6716 B).
# Self-delimited packets may be followed by other packed streams. Report the
# complete consumed prefix in op_packet_bytes; keep frame pointers zero-copy.
FN op_opus_packet_parse_ex
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov [rsp + 32], r8d
    mov [rsp + 40], rcx
    mov qword ptr [rsp + 48], 0 #padding bytes at the end of this stream packet
    mov dword ptr [rip + op_frame_count], 0
    mov dword ptr [rip + op_packet_bytes], 0
    cmp r8d, 1
    ja .Lopus_packet_bad
    test edx, edx
    jz .Lopus_packet_bad
    test rcx, rcx
    jz .Lopus_packet_bad
    mov rsi, rcx
    lea rdi, [rcx + rdx]
    movzx ebx, byte ptr [rsi]
    inc rsi
    mov eax, ebx
    shr eax, 3
    mov [rip + op_config], eax
    mov edx, ebx
    shr edx, 2
    and edx, 1
    mov [rip + op_stereo], edx
    cmp eax, 12
    jb .Lopus_packet_silk
    cmp eax, 16
    jb .Lopus_packet_hybrid
    and eax, 3
    mov ecx, eax
    mov eax, 120
    shl eax, cl
    jmp .Lopus_packet_duration
.Lopus_packet_hybrid:
    and eax, 1
    mov ecx, eax
    mov eax, 480
    shl eax, cl
    jmp .Lopus_packet_duration
.Lopus_packet_silk:
    and eax, 3
    lea rdx, [rip + op_silk_duration]
    mov eax, [rdx + rax*4]
.Lopus_packet_duration:
    mov [rip + op_frame_samples], eax
    and ebx, 3
    cmp ebx, 0
    je .Lopus_packet_code0
    cmp ebx, 1
    je .Lopus_packet_code1
    cmp ebx, 2
    je .Lopus_packet_code2
    cmp rsi, rdi
    jae .Lopus_packet_bad
    movzx r13d, byte ptr [rsi]
    inc rsi
    mov r12d, r13d
    and r12d, 63
    test r12d, r12d
    jz .Lopus_packet_bad
    cmp r12d, 48
    ja .Lopus_packet_bad
    mov eax, [rip + op_frame_samples]
    imul eax, r12d
    cmp eax, 5760
    ja .Lopus_packet_bad
    test r13d, 0x40
    jz .Lopus_packet_code3_body
    xor r15d, r15d
.Lopus_packet_padding:
    cmp rsi, rdi
    jae .Lopus_packet_bad
    movzx eax, byte ptr [rsi]
    inc rsi
    mov edx, eax
    cmp eax, 255
    jne .Lopus_packet_padding_last
    dec eax
.Lopus_packet_padding_last:
    add r15, rax
    mov rax, rdi
    sub rax, rsi
    cmp r15, rax
    ja .Lopus_packet_bad
    cmp edx, 255
    je .Lopus_packet_padding
    sub rdi, r15
    mov [rsp + 48], r15
.Lopus_packet_code3_body:
    test r13d, 0x80
    jz .Lopus_packet_cbr
    xor r14d, r14d
    xor r15d, r15d
.Lopus_packet_vbr_size:
    lea eax, [r14 + 1]
    cmp eax, r12d
    jae .Lopus_packet_vbr_last
    mov rcx, rsi
    mov rdx, rdi
    call opus_read_size
    cmp eax, -1
    je .Lopus_packet_bad
    mov rsi, rcx
    lea rdx, [rip + op_frame_size]
    mov [rdx + r14*4], eax
    add r15, rax
    inc r14d
    jmp .Lopus_packet_vbr_size
.Lopus_packet_vbr_last:
    cmp dword ptr [rsp + 32], 1
    je .Lopus_packet_self_vbr
    mov rax, rdi
    sub rax, rsi
    sub rax, r15
    jc .Lopus_packet_bad
    cmp rax, 1275
    ja .Lopus_packet_bad
    lea rdx, [rip + op_frame_size]
    mov [rdx + r14*4], eax
    jmp .Lopus_packet_pointers
.Lopus_packet_code0:
    mov r12d, 1
    jmp .Lopus_packet_cbr
.Lopus_packet_code1:
    mov r12d, 2
    jmp .Lopus_packet_cbr
.Lopus_packet_code2:
    mov r12d, 2
    mov rcx, rsi
    mov rdx, rdi
    call opus_read_size
    cmp eax, -1
    je .Lopus_packet_bad
    mov rsi, rcx
    mov [rip + op_frame_size], eax
    cmp dword ptr [rsp + 32], 1
    jne .Lopus_packet_code2_regular
    mov r15d, eax
    mov r14d, 1
    jmp .Lopus_packet_self_vbr
.Lopus_packet_code2_regular:
    mov rdx, rdi
    sub rdx, rsi
    sub rdx, rax
    jc .Lopus_packet_bad
    cmp rdx, 1275
    ja .Lopus_packet_bad
    mov [rip + op_frame_size + 4], edx
    jmp .Lopus_packet_pointers
.Lopus_packet_cbr:
    cmp dword ptr [rsp + 32], 1
    je .Lopus_packet_self_cbr
    mov rax, rdi
    sub rax, rsi
    xor edx, edx
    div r12
    test edx, edx
    jnz .Lopus_packet_bad
    cmp rax, 1275
    ja .Lopus_packet_bad
    xor r14d, r14d
    lea rdx, [rip + op_frame_size]
.Lopus_packet_cbr_fill:
    mov [rdx + r14*4], eax
    inc r14d
    cmp r14d, r12d
    jb .Lopus_packet_cbr_fill
    jmp .Lopus_packet_pointers
.Lopus_packet_self_cbr:
    mov rcx, rsi
    mov rdx, rdi
    call opus_read_size
    cmp eax, -1
    je .Lopus_packet_bad
    mov rsi, rcx
    mov edx, eax
    imul edx, r12d
    lea rcx, [rsi + rdx]
    cmp rcx, rdi
    ja .Lopus_packet_bad
    mov rdi, rcx
    xor r14d, r14d
    lea rdx, [rip + op_frame_size]
    jmp .Lopus_packet_cbr_fill
.Lopus_packet_self_vbr:
    mov rcx, rsi
    mov rdx, rdi
    call opus_read_size
    cmp eax, -1
    je .Lopus_packet_bad
    mov rsi, rcx
    lea rdx, [rip + op_frame_size]
    mov [rdx + r14*4], eax
    add r15, rax
    lea rcx, [rsi + r15]
    cmp rcx, rdi
    ja .Lopus_packet_bad
    mov rdi, rcx
.Lopus_packet_pointers:
    lea r8, [rip + op_frame_ptr]
    lea r9, [rip + op_frame_size]
    xor r14d, r14d
.Lopus_packet_pointer:
    mov [r8 + r14*8], rsi
    mov eax, [r9 + r14*4]
    add rsi, rax
    cmp rsi, rdi
    ja .Lopus_packet_bad
    inc r14d
    cmp r14d, r12d
    jb .Lopus_packet_pointer
    cmp rsi, rdi
    jne .Lopus_packet_bad
    mov [rip + op_frame_count], r12d
    mov eax, [rip + op_frame_samples]
    imul eax, r12d
    mov [rip + op_packet_samples], eax
    mov rax, rdi
    sub rax, [rsp + 40]
    add rax, [rsp + 48]
    mov [rip + op_packet_bytes], eax
    mov eax, r12d
    jmp .Lopus_packet_done
.Lopus_packet_bad:
    xor eax, eax
.Lopus_packet_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_opus_packet_parse_ex

# Validate a complete RFC7845 packed packet. Every stream except the last uses
# self-delimited framing. All streams must have equal48kHz packet durations.
# RCX=packet,EDX=bytes -> EAX=1/0; op_packet_samples=common duration on success.
FN op_opus_multistream_parse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov edi, edx
    mov r13d, edx
    xor ebx, ebx
    xor r12d, r12d
    mov eax, [rip + op_streams]
    dec eax
    cmp eax, 254
    ja .Lopus_multi_bad
.Lopus_multi_stream:
    mov rcx, rsi
    mov edx, edi
    lea eax, [rbx + 1]
    xor r8d, r8d
    cmp eax, [rip + op_streams]
    setb r8b
    call op_opus_packet_parse_ex
    test eax, eax
    jz .Lopus_multi_bad
    mov eax, [rip + op_packet_samples]
    test ebx, ebx
    jz .Lopus_multi_duration
    cmp eax, r12d
    jne .Lopus_multi_bad
.Lopus_multi_duration:
    mov r12d, eax
    mov eax, [rip + op_packet_bytes]
    test eax, eax
    jz .Lopus_multi_bad
    cmp eax, edi
    ja .Lopus_multi_bad
    add rsi, rax
    sub edi, eax
    inc ebx
    cmp ebx, [rip + op_streams]
    jb .Lopus_multi_stream
    test edi, edi
    jnz .Lopus_multi_bad
    mov [rip + op_packet_bytes], r13d
    mov eax, 1
    jmp .Lopus_multi_done
.Lopus_multi_bad:
    mov dword ptr [rip + op_packet_bytes], 0
    mov dword ptr [rip + op_packet_samples], 0
    mov dword ptr [rip + op_frame_count], 0
    xor eax, eax
.Lopus_multi_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_opus_multistream_parse

# RCX=mapped beginning, RDX=end. PCM reconstruction is a separate stage.
FN opus_headers
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    call ogg_open
    test eax, eax
    jz .Lopus_header_bad
    call ogg_next
    test rax, rax
    jz .Lopus_header_bad
    cmp [rip + ogg_packet_page], rbx
    jne .Lopus_header_bad
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lopus_header_bad
    cmp qword ptr [rip + ogg_granule], 0
    jne .Lopus_header_bad
    cmp edx, 19
    jb .Lopus_header_bad
    mov r8, 0x646165487375704f # OpusHead
    cmp [rax], r8
    jne .Lopus_header_bad
    cmp byte ptr [rax + 8], 15
    ja .Lopus_header_bad
    movzx ecx, byte ptr [rax + 9]
    cmp ecx, 1
    jb .Lopus_header_bad
    cmp ecx, 8
    ja .Lopus_header_bad
    mov [rip + source_channels], ecx
    movzx r8d, byte ptr [rax + 18]
    mov [rip + op_mapping], r8d
    test r8d, r8d
    jnz .Lopus_header_family1
    cmp ecx, 2
    ja .Lopus_header_bad
    mov dword ptr [rip + op_streams], 1
    dec ecx
    mov [rip + op_coupled], ecx
    mov byte ptr [rip + op_channel_map], 0
    mov byte ptr [rip + op_channel_map + 1], 1
    mov r8d, 19
    jmp .Lopus_header_length
.Lopus_header_family1:
    cmp r8d, 1
    jne .Lopus_header_bad
    lea r8d, [rcx + 21]
    cmp edx, r8d
    jb .Lopus_header_bad
    movzx ecx, byte ptr [rax + 19]
    test ecx, ecx
    jz .Lopus_header_bad
    mov [rip + op_streams], ecx
    movzx r9d, byte ptr [rax + 20]
    cmp r9d, ecx
    ja .Lopus_header_bad
    mov [rip + op_coupled], r9d
    add r9d, ecx
    cmp r9d, 255
    ja .Lopus_header_bad
    xor ecx, ecx
    lea rdi, [rip + op_channel_map]
.Lopus_header_map:
    movzx r10d, byte ptr [rax + rcx + 21]
    cmp r10d, 255
    je .Lopus_header_map_valid
    cmp r10d, r9d
    jae .Lopus_header_bad
.Lopus_header_map_valid:
    mov [rdi + rcx], r10b
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lopus_header_map
.Lopus_header_length:
    cmp byte ptr [rax + 8], 1
    ja .Lopus_header_extended
    cmp edx, r8d
    jne .Lopus_header_bad
.Lopus_header_extended:
    movzx ecx, word ptr [rax + 10]
    mov [rip + op_preskip], ecx
    movsx ecx, word ptr [rax + 16]
    mov [rip + op_gain], ecx         # signed Q8 dB; applied after synthesis
    mov dword ptr [rip + sample_rate], 48000
    mov dword ptr [rip + source_bits], 32
    mov qword ptr [rip + total_frames], 0 #audio-page anchoring establishes duration
    call ogg_next
    test rax, rax
    jz .Lopus_header_bad
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lopus_header_bad
    cmp qword ptr [rip + ogg_granule], 0
    jne .Lopus_header_bad
    cmp edx, 16
    jb .Lopus_header_bad
    mov r8, 0x736761547375704f # OpusTags
    cmp [rax], r8
    jne .Lopus_header_bad
    lea rdi, [rax + rdx]
    lea rsi, [rax + 8]
    mov eax, [rsi]
    add rsi, 4
    add rsi, rax
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lopus_header_bad
    mov ebx, [rsi]
    add rsi, 4
.Lopus_header_comment:
    test ebx, ebx
    jz .Lopus_header_ok
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lopus_header_bad
    mov eax, [rsi]
    add rsi, 4
    add rsi, rax
    cmp rsi, rdi
    ja .Lopus_header_bad
    dec ebx
    jmp .Lopus_header_comment
.Lopus_header_ok:
    mov eax, 1
    jmp .Lopus_header_done
.Lopus_header_bad:
    mov dword ptr [rip + decode_error], 25
    xor eax, eax
.Lopus_header_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN opus_headers
