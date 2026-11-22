# Original bounded Speex bit access and header/packet inspection. MIT.
# Format and bit-access references: Xiph Speex 1.2.1, bits.c, modes.c,
# modes_wb.c, nb_celp.c, sb_celp.c and speex_callbacks.c (BSD-3-Clause).
# See THIRD_PARTY_NOTICES. This module does not synthesize Speex PCM yet.
.include "lamp.inc"
.include "speex_packet.inc"

RODATA
.p2align 2
spx_nb_frame_bits: .long 5, 43, 119, 160, 220, 300, 364, 492, 79
spx_wb_frame_bits: .long 4, 36, 112, 192, 352
spx_control_bits: .long 1, 1, 4, 4, 4, 4, 4, 4, 8, 8, 16, 16, 32, 32, 64, 64
.text

# RCX=24-byte caller state, RDX=data, R8D=bytes -> EAX=1 initialized,
# 0 invalid. Empty buffers may use a null data pointer. Maximum 1 MiB.
# State is cleared on invalid input; a null state fails without writing.
FN spx_bits_init
    mov r8d, r8d
    test rcx, rcx
    jz .Lspxb_init_bad
    pxor xmm0, xmm0
    movdqu [rcx], xmm0
    movq [rcx+16], xmm0
    cmp r8d, SPX_MAX_PACKET
    ja .Lspxb_init_error
    test r8d, r8d
    jz .Lspxb_init_valid
    test rdx, rdx
    jz .Lspxb_init_error
    mov rax, rdx
    add rax, r8
    jc .Lspxb_init_error
.Lspxb_init_valid:
    mov [rcx+SPXB_DATA], rdx
    shl r8d, 3
    mov [rcx+SPXB_BITS], r8d
    mov eax, 1
    ret
.Lspxb_init_error:
    mov dword ptr [rcx+SPXB_ERROR], 1
.Lspxb_init_bad:
    xor eax, eax
    ret
ENDFN spx_bits_init

# RCX=state, EDX=0..32 -> EAX=value. Sticky failure returns zero without
# advancing. Peek shares the same bounds checks but does not move position.
FN spx_bits_read
    mov r8d, 1
    jmp spx_bits_extract
ENDFN spx_bits_read
FN spx_bits_peek
    xor r8d, r8d
    jmp spx_bits_extract
ENDFN spx_bits_peek
LOCALFN spx_bits_extract
    push r8
    xor eax, eax
    test rcx, rcx
    jz .Lspxb_extract_return
    mov r11, rcx
    cmp dword ptr [r11+SPXB_ERROR], 0
    jne .Lspxb_extract_return
    cmp edx, 32
    ja .Lspxb_extract_bad
    mov r9d, [r11+SPXB_POS]
    mov r10d, r9d
    add r10d, edx
    jc .Lspxb_extract_bad
    cmp r10d, [r11+SPXB_BITS]
    ja .Lspxb_extract_bad
    mov rdx, [r11+SPXB_DATA]
    cmp r9d, r10d
    je .Lspxb_extract_done
.Lspxb_extract_bit:
    mov ecx, r9d
    shr ecx, 3
    movzx r8d, byte ptr [rdx+rcx]
    mov ecx, r9d
    and ecx, 7
    xor ecx, 7
    shr r8d, cl
    and r8d, 1
    shl eax, 1
    or eax, r8d
    inc r9d
    cmp r9d, r10d
    jb .Lspxb_extract_bit
.Lspxb_extract_done:
    cmp dword ptr [rsp], 0
    je .Lspxb_extract_return
    mov [r11+SPXB_POS], r9d
    jmp .Lspxb_extract_return
.Lspxb_extract_bad:
    mov dword ptr [r11+SPXB_ERROR], 1
.Lspxb_extract_return:
    add rsp, 8
    ret
ENDFN spx_bits_extract

# RCX=state, EDX=nonnegative advance -> EAX=1 success/0 sticky failure.
FN spx_bits_advance
    xor eax, eax
    test rcx, rcx
    jz .Lspxb_advance_return
    cmp dword ptr [rcx+SPXB_ERROR], 0
    jne .Lspxb_advance_return
    mov r8d, [rcx+SPXB_POS]
    add r8d, edx
    jc .Lspxb_advance_bad
    cmp r8d, [rcx+SPXB_BITS]
    ja .Lspxb_advance_bad
    mov [rcx+SPXB_POS], r8d
    mov eax, 1
    ret
.Lspxb_advance_bad:
    mov dword ptr [rcx+SPXB_ERROR], 1
.Lspxb_advance_return:
    ret
ENDFN spx_bits_advance

# RCX=state -> EAX=remaining bits or -1 when invalid/sticky failure.
FN spx_bits_remaining
    test rcx, rcx
    jz .Lspxb_remaining_bad
    cmp dword ptr [rcx+SPXB_ERROR], 0
    jne .Lspxb_remaining_bad
    mov eax, [rcx+SPXB_BITS]
    sub eax, [rcx+SPXB_POS]
    jc .Lspxb_remaining_mark
    ret
.Lspxb_remaining_mark:
    mov dword ptr [rcx+SPXB_ERROR], 1
.Lspxb_remaining_bad:
    mov eax, -1
    ret
ENDFN spx_bits_remaining

# RCX=header, EDX=bytes, R8=32-byte summary -> 1 valid / 0 invalid.
# Caller input/output ranges must not overlap. Failure leaves output intact.
# Speex bitstream version 4, format version 0/1, modes 0..2, mono/stereo;
# custom playback rates 8..192 kHz, canonical frame sizes and bounded counts.
FN spx_header_parse
    mov edx, edx
    test rcx, rcx
    jz .Lspxh_bad
    test r8, r8
    jz .Lspxh_bad
    cmp edx, 80
    jb .Lspxh_bad
    cmp edx, 65536
    ja .Lspxh_bad
    mov r9, rcx
    add r9, rdx
    jc .Lspxh_bad
    mov r10, r8
    add r10, SPXH_SIZE
    jc .Lspxh_bad
    cmp r8, r9
    jae .Lspxh_disjoint
    cmp rcx, r10
    jb .Lspxh_bad
.Lspxh_disjoint:
    mov rax, 0x2020207865657053       # "Speex   "
    cmp [rcx], rax
    jne .Lspxh_bad
    cmp dword ptr [rcx+28], 1
    ja .Lspxh_bad
    mov eax, [rcx+32]
    cmp eax, 80
    jb .Lspxh_bad
    cmp eax, edx
    ja .Lspxh_bad
    cmp dword ptr [rcx+36], 8000
    jb .Lspxh_bad
    cmp dword ptr [rcx+36], 192000
    ja .Lspxh_bad
    cmp dword ptr [rcx+40], 2
    ja .Lspxh_bad
    cmp dword ptr [rcx+44], 4
    jne .Lspxh_bad
    mov eax, [rcx+48]
    dec eax
    cmp eax, 1
    ja .Lspxh_bad
    mov eax, [rcx+52]
    cmp eax, -1
    je .Lspxh_bitrate_ok
    cmp eax, 10000000
    ja .Lspxh_bad
.Lspxh_bitrate_ok:
    mov r10, rcx
    mov ecx, [r10+40]
    mov eax, 160
    shl eax, cl
    cmp eax, [r10+56]
    jne .Lspxh_bad
    cmp dword ptr [r10+60], 1
    ja .Lspxh_bad
    cmp dword ptr [r10+64], SPX_MAX_FRAMES
    ja .Lspxh_bad
    cmp dword ptr [r10+68], 64
    ja .Lspxh_bad
    mov eax, [r10+36]
    mov [r8], eax
    mov eax, [r10+40]
    mov [r8+4], eax
    mov eax, [r10+48]
    mov [r8+8], eax
    mov eax, [r10+56]
    mov [r8+12], eax
    mov eax, [r10+64]
    test eax, eax
    mov edx, 1
    cmovz eax, edx
    mov [r8+16], eax
    mov eax, [r10+68]
    mov [r8+20], eax
    mov eax, [r10+60]
    mov [r8+24], eax
    mov eax, [r10+52]
    mov [r8+28], eax
    mov eax, 1
    ret
.Lspxh_bad:
    xor eax, eax
    ret
ENDFN spx_header_parse

# RCX=packet, EDX=bytes, R8D=output mode 0..2, R9=32-byte summary.
# Returns frame count (1..64), or -1 without writing summary. Canonical
# packets start at a narrowband frame/control and end with optional Speex
# zero/ones padding or an explicit terminator. No PCM validity claim.
FN spx_packet_scan
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 128
    mov edx, edx
    test r9, r9
    jz .Lspxp_bad
    cmp r8d, 2
    ja .Lspxp_bad
    mov [rsp+96], r9
    mov [rsp+104], r8d
    mov r10, r9
    add r10, SPXP_SIZE
    jc .Lspxp_bad
    mov rax, rcx
    add rax, rdx
    jc .Lspxp_bad
    cmp r9, rax
    jae .Lspxp_disjoint
    cmp rcx, r10
    jb .Lspxp_bad
.Lspxp_disjoint:
    mov r8d, edx
    mov rdx, rcx
    lea rbx, [rsp+32]
    mov rcx, rbx
    call spx_bits_init
    test eax, eax
    jz .Lspxp_bad
    xor r12d, r12d                    # frames
    xor r13d, r13d                    # controls
    xor r14d, r14d                    # wideband layers
    xor r15d, r15d                    # ultra-wideband layers
    xor esi, esi                      # stereo control count
    xor edi, edi                      # current frame's higher layer count
    mov dword ptr [rsp+112], 0         # coded bits excluding padding
.Lspxp_next:
    mov rcx, rbx
    call spx_bits_remaining
    test eax, eax
    js .Lspxp_bad
    jz .Lspxp_finish
    cmp eax, 5
    jae .Lspxp_flag
    mov rcx, rbx
    mov edx, 1
    call spx_bits_peek
    test eax, eax
    jnz .Lspxp_flag                    # a four-bit null higher-band layer
    mov rcx, rbx
    call spx_bits_remaining
    jmp .Lspxp_padding
.Lspxp_flag:
    mov rcx, rbx
    mov edx, 1
    call spx_bits_read
    test eax, eax
    jnz .Lspxp_layer
    mov rcx, rbx
    mov edx, 4
    call spx_bits_read
    cmp eax, 8
    ja .Lspxp_control
    lea rdx, [rip+spx_nb_frame_bits]
    mov edx, [rdx+rax*4]
    sub edx, 5
    mov rcx, rbx
    call spx_bits_advance
    test eax, eax
    jz .Lspxp_bad
    inc r12d
    cmp r12d, SPX_MAX_FRAMES
    ja .Lspxp_bad
    xor edi, edi
    jmp .Lspxp_record
.Lspxp_layer:
    test r12d, r12d
    jz .Lspxp_bad
    cmp edi, 2
    jae .Lspxp_bad
    mov rcx, rbx
    mov edx, 3
    call spx_bits_read
    cmp eax, 4
    ja .Lspxp_bad
    test edi, edi
    jz .Lspxp_wideband
    cmp eax, 1                         # UWB has null/folding modes only
    ja .Lspxp_bad
    inc r15d
    jmp .Lspxp_layer_size
.Lspxp_wideband:
    inc r14d
.Lspxp_layer_size:
    inc edi
    lea rdx, [rip+spx_wb_frame_bits]
    mov edx, [rdx+rax*4]
    sub edx, 4
    mov rcx, rbx
    call spx_bits_advance
    test eax, eax
    jz .Lspxp_bad
    jmp .Lspxp_record
.Lspxp_control:
    cmp eax, 15
    je .Lspxp_terminator
    cmp eax, 13
    jb .Lspxp_bad
    inc r13d
    cmp r13d, SPX_MAX_CONTROLS
    ja .Lspxp_bad
    cmp eax, 14
    je .Lspxp_standard_control
    mov rcx, rbx
    mov edx, 4
    call spx_bits_read
    lea edx, [rax*8+5]
    jmp .Lspxp_skip_control
.Lspxp_standard_control:
    mov rcx, rbx
    mov edx, 4
    call spx_bits_read
    cmp eax, 9
    jne .Lspxp_control_size
    inc esi
.Lspxp_control_size:
    lea rdx, [rip+spx_control_bits]
    mov edx, [rdx+rax*4]
.Lspxp_skip_control:
    mov rcx, rbx
    call spx_bits_advance
    test eax, eax
    jz .Lspxp_bad
.Lspxp_record:
    mov eax, [rbx+SPXB_POS]
    mov [rsp+112], eax
    jmp .Lspxp_next
.Lspxp_padding:
    mov edx, eax
    mov rcx, rbx
    call spx_bits_read
    mov ecx, [rbx+SPXB_BITS]
    sub ecx, [rsp+112]
    dec ecx
    mov edx, 1
    shl edx, cl
    dec edx
    cmp eax, edx                      # a zero bit followed only by ones
    jne .Lspxp_bad
    jmp .Lspxp_finish
.Lspxp_terminator:
    mov rcx, rbx
    call spx_bits_remaining
    cmp eax, 7
    ja .Lspxp_bad
    test eax, eax
    jz .Lspxp_finish
    mov [rsp+116], eax
    mov edx, eax
    mov rcx, rbx
    call spx_bits_read
    mov ecx, [rsp+116]
    mov edx, 1
    shl edx, cl
    dec edx
    cmp eax, edx                      # remaining ones of an alignment marker
    je .Lspxp_finish
    shr edx, 1                        # explicit terminator, then zero/ones pad
    cmp eax, edx
    jne .Lspxp_bad
.Lspxp_finish:
    test r12d, r12d
    jz .Lspxp_bad
    mov r9, [rsp+96]
    mov [r9], r12d
    mov ecx, [rsp+104]
    imul eax, r12d, 160
    shl eax, cl
    mov [r9+4], eax
    mov eax, [rsp+112]
    mov [r9+8], eax
    mov [r9+12], r13d
    mov [r9+16], r14d
    mov [r9+20], r15d
    mov [r9+24], esi
    mov dword ptr [r9+28], 0
    mov eax, r12d
    jmp .Lspxp_return
.Lspxp_bad:
    mov eax, -1
.Lspxp_return:
    add rsp, 128
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_packet_scan
