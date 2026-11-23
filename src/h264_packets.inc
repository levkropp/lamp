# Original AVCDecoderConfigurationRecord and timestamped access-unit frontend.
# Included by h264.s. No container I/O, conversion buffer or software decoding.

# RCX=new/closed parser, RDX=avcC payload, R8=bytes,R9=cancelDWORD*.
# 1 success,0 failure; close required after an initialized failure.
FN h264_packet_open
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    call h264_open
    test eax, eax
    jz .Lhpa_open_return
    lea rax, [rbx+HP_SPS_RAW]
    mov [rbx+HP_DATA], rax # Stable ownership marker; config not retained.
    mov dword ptr [rbx+HP_PACKET_MODE], 1
    cmp r13, 7
    jb .Lhpa_open_bad
    cmp r13, 8207
    ja .Lhpa_open_limit
    add r13, r12
    cmp byte ptr [r12], 1
    jne .Lhpa_open_bad
    movzx eax, byte ptr [r12+4]
    mov edx, eax
    and edx, 252
    cmp edx, 252
    jne .Lhpa_open_bad
    and eax, 3
    cmp eax, 2
    je .Lhpa_open_unsupported
    inc eax
    mov [rbx+HP_PACKET_LENGTH], eax
    movzx eax, byte ptr [r12+5]
    mov edx, eax
    and edx, 224
    cmp edx, 224
    jne .Lhpa_open_bad
    and eax, 31
    cmp eax, 1
    jne .Lhpa_open_unsupported
    lea rsi, [r12+6]
    xor ebp, ebp
.Lhpa_parameter:
    mov rax, r13
    sub rax, rsi
    cmp rax, 2
    jb .Lhpa_open_bad
    movzx ecx, byte ptr [rsi]
    shl ecx, 8
    mov cl, [rsi+1]
    add rsi, 2
    test ecx, ecx
    jz .Lhpa_open_bad
    cmp ecx, 4096
    ja .Lhpa_open_limit
    sub rax, 2
    cmp rcx, rax
    ja .Lhpa_open_bad
    mov [rbx+HP_NAL_PTR], rsi
    mov [rbx+HP_NAL_BYTES], rcx
    movzx eax, byte ptr [rsi]
    test eax, 0x80
    jnz .Lhpa_open_bad
    test eax, 0x60
    jz .Lhpa_open_bad
    and eax, 31
    test ebp, ebp
    jnz .Lhpa_pps
    cmp eax, 7
    jne .Lhpa_open_bad
    mov rcx, rbx
    call hp_sps
    test eax, eax
    jz .Lhpa_open_zero
    mov eax, [rbx+HP_PROFILE]
    cmp al, [r12+1]
    jne .Lhpa_open_bad
    mov eax, [rbx+HP_CONSTRAINTS]
    cmp al, [r12+2]
    jne .Lhpa_open_bad
    mov eax, [rbx+HP_LEVEL]
    cmp al, [r12+3]
    jne .Lhpa_open_bad
    mov ecx, [rbx+HP_NAL_BYTES]
    mov [rbx+HP_SPS_BYTES], ecx
    lea rdi, [rbx+HP_SPS_RAW]
    rep movsb
    cmp rsi, r13
    jae .Lhpa_open_bad
    cmp byte ptr [rsi], 1
    jne .Lhpa_open_unsupported
    inc rsi
    inc ebp
    jmp .Lhpa_parameter
.Lhpa_pps:
    cmp eax, 8
    jne .Lhpa_open_bad
    mov rcx, rbx
    call hp_pps
    test eax, eax
    jz .Lhpa_open_zero
    mov ecx, [rbx+HP_NAL_BYTES]
    mov [rbx+HP_PPS_BYTES], ecx
    lea rdi, [rbx+HP_PPS_RAW]
    rep movsb
    cmp rsi, r13
    je .Lhpa_configured
    # High's optional record extension must describe the supported8bit420 subset.
    cmp dword ptr [rbx+HP_PROFILE], 100
    jne .Lhpa_open_bad
    mov rax, r13
    sub rax, rsi
    cmp rax, 4
    jne .Lhpa_open_bad
    cmp dword ptr [rsi], 0x00f8f8fd
    jne .Lhpa_open_unsupported
.Lhpa_configured:
    mov dword ptr [rbx+HP_STATE], 3
    mov qword ptr [rbx+HP_CURSOR], 0
    mov qword ptr [rbx+HP_END], 0
    mov eax, 1
    jmp .Lhpa_open_return
.Lhpa_open_limit:
    mov dword ptr [rbx+HP_ERROR], 3
    jmp .Lhpa_open_zero
.Lhpa_open_unsupported:
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhpa_open_zero
.Lhpa_open_bad:
    mov dword ptr [rbx+HP_ERROR], 1
.Lhpa_open_zero:
    xor eax, eax
.Lhpa_open_return:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN h264_packet_open

# RCX=packet-mode parser,RDX=48B {data,size,dts_ns,pts_ns,duration_ns,epoch}.
# One complete access unit only. Returns1 frame,-1 sticky error. No EOF packet.
# No old surface/descriptor may still be in a pending decoder submission.
FN h264_packet_next
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    cmp dword ptr [rbx+HP_PACKET_MODE], 1
    jne .Lhpa_next_bad
    cmp dword ptr [rbx+HP_STATE], 3
    jne .Lhpa_next_bad
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhpa_next_error
    mov rax, [rsi]
    test rax, rax
    jz .Lhpa_next_bad
    mov rdx, [rsi+8]
    test rdx, rdx
    jz .Lhpa_next_bad
    cmp rdx, HP_MAX_FRAME
    ja .Lhpa_next_limit
    add rdx, rax
    jc .Lhpa_next_bad
    mov r8, [rsi+32]
    test r8, r8
    jle .Lhpa_next_bad
    add r8, [rsi+24]
    jo .Lhpa_next_bad
    cmp qword ptr [rsi+40], 0
    je .Lhpa_next_bad
    cmp dword ptr [rbx+HP_PACKET_SEEN], 0
    je .Lhpa_next_input
    mov r8, [rsi+40]
    cmp r8, [rbx+HP_PACKET_EPOCH]
    jne .Lhpa_next_bad
    mov r8, [rsi+16]
    cmp r8, [rbx+HP_PACKET_DTS]
    jl .Lhpa_next_bad
.Lhpa_next_input:
    mov [rbx+HP_CURSOR], rax
    mov [rbx+HP_END], rdx
    mov dword ptr [rbx+HP_PACKET_READS], 0
    mov rcx, rbx
    call h264_next
    cmp eax, 1
    jne .Lhpa_next_bad
    # Consume allowed trailing non-VCL NALs; a second picture is an invalid AU.
    mov rax, [rbx+HP_CURSOR]
    cmp rax, [rbx+HP_END]
    je .Lhpa_next_timing
    mov rcx, rbx
    call h264_next
    test eax, eax
    jnz .Lhpa_next_bad
    mov eax, [rbx+HP_DESC+24]
    mov [rbx+HP_FRAME_BYTES], eax
    mov eax, [rbx+HP_DESC+40]
    mov [rbx+HP_SLICES], eax
.Lhpa_next_timing:
    mov rax, [rsi+16]
    mov [rbx+HP_PACKET_DTS], rax
    mov rax, [rsi+24]
    mov [rbx+HP_PACKET_PTS], rax
    mov rax, [rsi+32]
    mov [rbx+HP_PACKET_DURATION], rax
    mov rax, [rsi+40]
    mov [rbx+HP_PACKET_EPOCH], rax
    mov dword ptr [rbx+HP_PACKET_SEEN], 1
    mov eax, 1
    jmp .Lhpa_next_return
.Lhpa_next_limit:
    mov dword ptr [rbx+HP_ERROR], 3
    jmp .Lhpa_next_error
.Lhpa_next_bad:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhpa_next_error
    mov dword ptr [rbx+HP_ERROR], 1
.Lhpa_next_error:
    mov eax, -1
.Lhpa_next_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN h264_packet_next

# Length-prefixed NAL reader, sharing h264_next's checked syntax/DPB machinery.
LOCALFN hp_packet_nal
    mov rdx, [rcx+HP_CANCEL]
    test rdx, rdx
    jz .Lhpa_nal_begin
    cmp dword ptr [rdx], 0
    jne .Lhp_nal_cancel
.Lhpa_nal_begin:
    mov r8, [rcx+HP_CURSOR]
    mov r10, [rcx+HP_END]
    cmp r8, r10
    je .Lhp_nal_eof
    ja .Lhp_nal_bad
    inc dword ptr [rcx+HP_PACKET_READS]
    cmp dword ptr [rcx+HP_PACKET_READS], 4096
    ja .Lhp_nal_limit
    mov [rcx+HP_NAL_START], r8
    mov r9d, [rcx+HP_PACKET_LENGTH]
    mov rax, r10
    sub rax, r8
    cmp rax, r9
    jb .Lhp_nal_bad
    xor edx, edx
.Lhpa_length:
    shl edx, 8
    mov dl, [r8]
    inc r8
    dec r9d
    jnz .Lhpa_length
    test edx, edx
    jz .Lhp_nal_bad
    cmp edx, HP_MAX_FRAME
    ja .Lhp_nal_limit
    mov rax, r10
    sub rax, r8
    cmp rdx, rax
    ja .Lhp_nal_bad
    test byte ptr [r8], 0x80
    jnz .Lhp_nal_bad
    mov [rcx+HP_NAL_PTR], r8
    mov [rcx+HP_NAL_BYTES], rdx
    add r8, rdx
    mov [rcx+HP_CURSOR], r8
    inc qword ptr [rcx+HP_NALS]
    mov eax, 1
    ret
ENDFN hp_packet_nal
