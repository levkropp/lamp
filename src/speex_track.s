# Original Speex packet-track adapter. MIT, see LICENSE.
# Runtime decoding uses the shared assembly NB/WB/UWB decoder. A container
# supplies an identification header and complete packets, without Ogg timing.
.include "lamp.inc"
.include "speex_packet.inc"
.include "speex_decoder.inc"
RODATA
spxt_normalize: .float .000030517578125
.data
spxt_active: .long 0
.bss
.p2align 4
spxt_header: .zero 32
spxt_summary: .zero 32
spxt_bits: .zero SPXB_SIZE
spxt_state: .zero SPXD_SIZE
spxt_pcm: .zero 1280*4
.text
FN speex_track_close
    mov dword ptr [rip+spxt_active], 0
    ret
ENDFN speex_track_close

# Clear every decoder history. The track layer seeks this codec from packet0.
FN speex_track_reset
    sub rsp, 40
    xor eax, eax
    cmp dword ptr [rip+spxt_active], 1
    jne .Lspxt_reset_return
    lea rcx, [rip+spxt_state]
    mov edx, SPXD_SIZE
    mov r8d, [rip+spxt_header+4]
    call spx_decoder_init
    test eax, eax
    jz .Lspxt_reset_return
    lea rcx, [rip+spxt_state]
    mov edx, [rip+spxt_header+8]
    call spx_decoder_set_channels
.Lspxt_reset_return:
    add rsp, 40
    ret
ENDFN speex_track_reset

# RCX=Speex identification header, EDX=bytes ->1/0. No container delay is
# inferred here; the demuxer owns trimming. Header frames/packet is advisory:
# packet structure supplies duration, including a shorter final group.
FN speex_track_open
    sub rsp, 40
    mov dword ptr [rip+spxt_active], 0
    lea r8, [rip+spxt_header]
    call spx_header_parse
    test eax, eax
    jz .Lspxt_open_return
    mov dword ptr [rip+spxt_active], 1
    call speex_track_reset
    test eax, eax
    jz .Lspxt_open_bad
    mov eax, [rip+spxt_header]
    mov [rip+sample_rate], eax
    mov eax, [rip+spxt_header+8]
    mov [rip+source_channels], eax
    mov dword ptr [rip+source_bits], 0
    mov eax, 1
    jmp .Lspxt_open_return
.Lspxt_open_bad:
    mov dword ptr [rip+spxt_active], 0
.Lspxt_open_return:
    add rsp, 40
    ret
ENDFN speex_track_open

# RCX=packet, EDX=bytes -> projected samples/channel or -1. Structural scan
# is bounded to1MiB,64 frames and1024 in-band controls by spx_packet_scan.
FN speex_track_samples
    sub rsp, 40
    cmp dword ptr [rip+spxt_active], 1
    jne .Lspxt_samples_bad
    mov r8d, [rip+spxt_header+4]
    lea r9, [rip+spxt_summary]
    call spx_packet_scan
    test eax, eax
    jle .Lspxt_samples_bad
    mov eax, [rip+spxt_summary+4]
    jmp .Lspxt_samples_return
.Lspxt_samples_bad:
    mov eax, -1
.Lspxt_samples_return:
    add rsp, 40
    ret
ENDFN speex_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=frame capacity ->frames
# or -1. Decode errors are sticky in the owning track; partial packet output
# and history must be discarded/closed after an error. No packet allocation.
FN speex_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov r12d, edx
    mov rdi, r8
    mov [rsp+32], r9d
    test rdi, rdi
    jz .Lspxt_decode_bad
    call speex_track_samples
    test eax, eax
    jle .Lspxt_decode_bad
    cmp eax, [rsp+32]
    ja .Lspxt_decode_bad
    mov [rsp+36], eax
    lea rdx, [rax*8]
    add rdx, rdi
    jc .Lspxt_decode_bad
    lea rcx, [rsi+r12]
    cmp rdi, rcx
    jae .Lspxt_decode_disjoint
    cmp rsi, rdx
    jb .Lspxt_decode_bad
.Lspxt_decode_disjoint:
    mov ebx, [rip+spxt_summary]
    lea rcx, [rip+spxt_bits]
    mov rdx, rsi
    mov r8d, r12d
    call spx_bits_init
    test eax, eax
    jz .Lspxt_decode_bad
.Lspxt_decode_frame:
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Lspxt_decode_continue
    cmp dword ptr [rax], 0
    jne .Lspxt_decode_bad
.Lspxt_decode_continue:
    lea rcx, [rip+spxt_state]
    lea rdx, [rip+spxt_bits]
    lea r8, [rip+spxt_pcm]
    mov r9d, 1280
    call spx_decoder_frame
    cmp eax, [rip+spxt_header+12]
    jne .Lspxt_decode_bad
    mov r13d, eax
    lea rsi, [rip+spxt_pcm]
    movss xmm2, [rip+spxt_normalize]
    shufps xmm2, xmm2, 0
    xor ecx, ecx
    cmp dword ptr [rip+spxt_header+8], 1
    je .Lspxt_decode_mono
.Lspxt_decode_stereo:
    movq xmm0, [rsi+rcx*8]
    mulps xmm0, xmm2
    movq [rdi+rcx*8], xmm0
    inc ecx
    cmp ecx, r13d
    jb .Lspxt_decode_stereo
    jmp .Lspxt_decode_next
.Lspxt_decode_mono:
    movss xmm0, [rsi+rcx*4]
    mulss xmm0, xmm2
    unpcklps xmm0, xmm0
    movq [rdi+rcx*8], xmm0
    inc ecx
    cmp ecx, r13d
    jb .Lspxt_decode_mono
.Lspxt_decode_next:
    lea rdi, [rdi+r13*8]
    dec ebx
    jnz .Lspxt_decode_frame
    mov eax, [rsp+36]
    jmp .Lspxt_decode_return
.Lspxt_decode_bad:
    mov eax, -1
.Lspxt_decode_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN speex_track_decode
