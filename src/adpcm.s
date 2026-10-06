# Original IMA and Microsoft ADPCM decoders in x86-64 assembly. MIT, see LICENSE.
# WAVE format tags 0x11 (IMA ADPCM, 4-bit samples, 1-8 channels) and 2
# (Microsoft ADPCM, mono or stereo). Every block starts with its channels'
# predictor state, so blocks are track packets that decode independently; a
# short final block decodes the whole sample groups it holds. QuickTime IMA4
# (CAF and AIFF-C "ima4", described by a WAVE-style fmt with the private tag
# ADPCM_QT) packs 64 samples per channel in 34-byte blocks whose headers keep
# only the predictor's top nine bits, so a header close to the running state
# continues it (as FFmpeg does) and seeks decode one primer packet. Decoding
# follows FFmpeg's adpcm_ima_wav, adpcm_ms and adpcm_ima_qt; the tables are
# src/adpcm_tables.inc (with the G.711 expansions used by the PCM reader).
.include "lamp.inc"
.globl adpcm_track_open, adpcm_track_samples, adpcm_track_decode, adpcm_track_close, adpcm_track_reset
.globl adpcm_primer, g711_alaw, g711_ulaw

.equ ADPCM_MALFORMED, 100
.equ ADPCM_UNSUPPORTED, 101
.equ ADPCM_IMA, 0x11
.equ ADPCM_MS, 2
.equ ADPCM_QT, 0x4d49               # LAMP's tag for QuickTime IMA4 (not a WAVE tag)
.equ MS_C1, 0                       # Microsoft channel state
.equ MS_C2, 4
.equ MS_DELTA, 8
.equ MS_S1, 12
.equ MS_S2, 16
.equ MS_SIZE, 20
.equ MS_DELTA_MAX, 0x7fffffff / 768

RODATA
.include "adpcm_tables.inc"
.p2align 2
adpcm_scale: .float 3.0517578125e-5     # 2^-15

.data
adpcm_tag: .long 0
adpcm_channels: .long 0
adpcm_align: .long 0
adpcm_stride: .long 0                    # bytes per channel plane
adpcm_planes: .quad 0                    # int16 channel planes of one block
adpcm_primer: .long 0                    # packets decoded before a seek target

.bss
.p2align 3
adpcm_state: .zero 8*8                   # IMA predictor and step index per channel
ms_state: .zero 2*MS_SIZE

.text
# ECX=block bytes -> EAX=samples per channel, 0 below the channels' headers
# (FFmpeg: IMA 1 + whole 8-sample groups, Microsoft 2 + two per byte).
LOCALFN adpcm_block_samples
    mov r8d, [rip + adpcm_channels]
    cmp dword ptr [rip + adpcm_tag], ADPCM_QT
    je .Ladpcm_samples_qt
    cmp dword ptr [rip + adpcm_tag], ADPCM_IMA
    jne .Ladpcm_samples_ms
    lea eax, [r8*4]
    sub ecx, eax
    jb .Ladpcm_samples_none
    mov eax, ecx
    xor edx, edx
    lea ecx, [r8*4]
    div ecx
    lea eax, [rax*8 + 1]
    ret
.Ladpcm_samples_ms:
    imul eax, r8d, 7
    sub ecx, eax
    jb .Ladpcm_samples_none
    lea eax, [rcx*2]
    xor edx, edx
    div r8d
    add eax, 2
    ret
.Ladpcm_samples_qt:
    mov eax, ecx                          # 64 per whole 34-byte block group
    xor edx, edx
    imul ecx, r8d, 34
    div ecx
    shl eax, 6
    ret
.Ladpcm_samples_none:
    xor eax, eax
    ret
ENDFN adpcm_block_samples

# RCX=WAVE fmt chunk, EDX=its bytes, R8/R9D=first packet (unused) -> EAX=1
# with the format published and the channel planes allocated.
FN adpcm_track_open
    push rbx
    push rsi
    sub rsp, 40
    mov dword ptr [rip + decode_error], ADPCM_MALFORMED
    cmp edx, 16
    jb .Ladpcm_open_fail
    movzx ebx, word ptr [rcx]
    xor r10d, r10d                         # channel mask, 0 for the default
    cmp ebx, 0xfffe                        # extensible: the subformat's tag
    jne .Ladpcm_open_tag
    cmp edx, 40
    jb .Ladpcm_open_fail
    movzx ebx, word ptr [rcx + 24]
    mov r10d, [rcx + 20]
.Ladpcm_open_tag:
    movzx esi, word ptr [rcx + 2]
    mov [rip + adpcm_tag], ebx
    mov [rip + adpcm_channels], esi
    movzx eax, word ptr [rcx + 12]
    mov [rip + adpcm_align], eax
    test esi, esi
    jz .Ladpcm_open_fail
    mov dword ptr [rip + decode_error], ADPCM_UNSUPPORTED
    cmp word ptr [rcx + 14], 4             # 4-bit samples only
    jne .Ladpcm_open_fail
    mov eax, [rcx + 4]
    cmp eax, 8000
    jb .Ladpcm_open_fail
    cmp eax, 192000
    ja .Ladpcm_open_fail
    mov [rip + sample_rate], eax
    cmp esi, 8
    ja .Ladpcm_open_fail
    cmp ebx, ADPCM_IMA
    je .Ladpcm_open_layout
    cmp ebx, ADPCM_QT
    je .Ladpcm_open_layout
    cmp ebx, ADPCM_MS
    jne .Ladpcm_open_fail
    cmp esi, 2
    ja .Ladpcm_open_fail
.Ladpcm_open_layout:
    mov dword ptr [rip + decode_error], ADPCM_MALFORMED
    mov ecx, [rip + adpcm_align]
    call adpcm_block_samples
    test eax, eax
    jz .Ladpcm_open_fail
    lea eax, [rax*2 + 63]
    and eax, -64
    mov [rip + adpcm_stride], eax
    mov [rip + source_channels], esi
    mov dword ptr [rip + source_bits], 4
    mov [rip + pcm_channel_mask], r10d
    xor eax, eax
    test r10d, r10d
    setnz al
    mov [rip + pcm_mask_seen], eax
    mov [rip + pcm_ignore_extra], eax      # as WAVE masks are read
    mov dword ptr [rip + pcm_mix], 0
    call pcm_build_mix
    test eax, eax
    jz .Ladpcm_open_fail
    mov ecx, [rip + adpcm_stride]
    imul ecx, esi
    call mem_alloc
    test rax, rax
    jz .Ladpcm_open_fail
    mov [rip + adpcm_planes], rax
    xor eax, eax
    cmp dword ptr [rip + adpcm_tag], ADPCM_QT
    sete al
    mov [rip + adpcm_primer], eax
    call adpcm_track_reset
    mov dword ptr [rip + decode_error], 0
    mov eax, 1
    jmp .Ladpcm_open_return
.Ladpcm_open_fail:
    xor eax, eax
.Ladpcm_open_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN adpcm_track_open

# Clears the IMA4 running state (stream start, seeks).
FN adpcm_track_reset
    lea rcx, [rip + adpcm_state]
    xor eax, eax
.Ladpcm_reset_word:
    mov qword ptr [rcx + rax*8], 0
    inc eax
    cmp eax, 8
    jb .Ladpcm_reset_word
    ret
ENDFN adpcm_track_reset

FN adpcm_track_close
    sub rsp, 40
    mov rcx, [rip + adpcm_planes]
    test rcx, rcx
    jz .Ladpcm_close_done
    call mem_free
    mov qword ptr [rip + adpcm_planes], 0
.Ladpcm_close_done:
    add rsp, 40
    ret
ENDFN adpcm_track_close

# RCX=packet, EDX=bytes -> EAX=samples, or -1 for a block beyond the block
# size or without whole headers.
FN adpcm_track_samples
    sub rsp, 40
    mov eax, -1
    cmp edx, [rip + adpcm_align]
    ja .Ladpcm_track_samples_return
    mov ecx, edx
    call adpcm_block_samples
    test eax, eax
    jnz .Ladpcm_track_samples_return
    mov eax, -1
.Ladpcm_track_samples_return:
    add rsp, 40
    ret
ENDFN adpcm_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# or -1 with decode_error set (a step index above 88, a predictor above 6).
FN adpcm_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, r8
    mov r12d, r9d
    mov ecx, edx
    call adpcm_block_samples
    mov ebx, eax
    test eax, eax
    jz .Ladpcm_decode_bad
    cmp eax, r12d
    ja .Ladpcm_decode_bad
    mov rcx, rsi
    mov edx, ebx
    cmp dword ptr [rip + adpcm_tag], ADPCM_QT
    je .Ladpcm_decode_qt
    cmp dword ptr [rip + adpcm_tag], ADPCM_IMA
    jne .Ladpcm_decode_ms
    call ima_block
    jmp .Ladpcm_decode_check
.Ladpcm_decode_qt:
    call ima4_block
    jmp .Ladpcm_decode_check
.Ladpcm_decode_ms:
    call ms_block
.Ladpcm_decode_check:
    test eax, eax
    jz .Ladpcm_decode_bad
    mov rcx, rdi
    mov edx, ebx
    call adpcm_emit
    jmp .Ladpcm_decode_return
.Ladpcm_decode_bad:
    mov dword ptr [rip + decode_error], ADPCM_MALFORMED
    mov eax, -1
.Ladpcm_decode_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN adpcm_track_decode

# RCX=IMA block, EDX=samples per channel -> EAX=1 with the channel planes
# filled. Each channel's header holds its first sample and step index; four
# bytes per channel then carry eight samples, low nibble first.
LOCALFN ima_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov r12d, edx
    mov r13d, [rip + adpcm_channels]
    lea r8, [rip + adpcm_state]
    mov rdi, [rip + adpcm_planes]
    xor ecx, ecx
.Lima_header:
    movsx eax, word ptr [rsi + rcx*4]
    movsx edx, word ptr [rsi + rcx*4 + 2]
    cmp edx, 88
    ja .Lima_bad
    mov [r8 + rcx*8], eax
    mov [r8 + rcx*8 + 4], edx
    mov r9d, [rip + adpcm_stride]
    imul r9d, ecx
    mov [rdi + r9], ax
    inc ecx
    cmp ecx, r13d
    jb .Lima_header
    lea rax, [r13*4]
    add rsi, rax                          # first data group
    mov r14d, 1                           # output sample
    lea r15, [rip + ima_steps]
    lea rbx, [rip + ima_index]
.Lima_group:
    lea eax, [r14 + 7]
    cmp eax, r12d
    jae .Lima_done
    xor ecx, ecx                          # channel
.Lima_channel:
    lea r8, [rip + adpcm_state]
    mov r10d, [r8 + rcx*8]                # predictor
    mov r11d, [r8 + rcx*8 + 4]            # step index
    mov eax, [rip + adpcm_stride]
    imul eax, ecx
    lea rdi, [rax + r14*2]
    add rdi, [rip + adpcm_planes]
    push rcx
    mov ecx, 8
    mov r9d, [rsi]
    add rsi, 4
.Lima_nibble:
    mov edx, r9d
    and edx, 15
    shr r9d, 4
    movzx eax, word ptr [r15 + r11*2]     # step
    mov r8d, edx
    and r8d, 7
    lea r8d, [r8*2 + 1]
    imul r8d, eax
    shr r8d, 3                            # diff
    test edx, 8
    jz .Lima_add
    sub r10d, r8d
    jmp .Lima_clip
.Lima_add:
    add r10d, r8d
.Lima_clip:
    cmp r10d, -32768
    jge .Lima_clip_high
    mov r10d, -32768
.Lima_clip_high:
    cmp r10d, 32767
    jle .Lima_index
    mov r10d, 32767
.Lima_index:
    movsx eax, byte ptr [rbx + rdx]
    add r11d, eax
    jns .Lima_index_high
    xor r11d, r11d
.Lima_index_high:
    cmp r11d, 88
    jbe .Lima_store
    mov r11d, 88
.Lima_store:
    mov [rdi], r10w
    add rdi, 2
    dec ecx
    jnz .Lima_nibble
    pop rcx
    lea r8, [rip + adpcm_state]
    mov [r8 + rcx*8], r10d
    mov [r8 + rcx*8 + 4], r11d
    inc ecx
    cmp ecx, r13d
    jb .Lima_channel
    add r14d, 8
    jmp .Lima_group
.Lima_done:
    mov eax, 1
    jmp .Lima_return
.Lima_bad:
    xor eax, eax
.Lima_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ima_block

# RCX=IMA4 packet, EDX=samples per channel (64 per block group) -> EAX=1 with
# the channel planes filled, 0 for a step index above 88. Each channel's
# block: a big-endian header (predictor's top nine bits, step index), then
# 32 bytes of samples, low nibble first, expanded with shifts and adds.
LOCALFN ima4_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov r12d, edx
    mov r13d, [rip + adpcm_channels]
    lea r15, [rip + ima_steps]
    lea rbx, [rip + ima_index]
    xor r14d, r14d                        # output sample of this group
.Lima4_group:
    cmp r14d, r12d
    jae .Lima4_done
    xor ecx, ecx
.Lima4_channel:
    lea r8, [rip + adpcm_state]
    movzx eax, word ptr [rsi]
    rol ax, 8
    movsx eax, ax
    mov edx, eax
    and edx, 0x7f                         # step index
    and eax, -0x80                        # predictor
    mov r10d, [r8 + rcx*8]
    mov r11d, [r8 + rcx*8 + 4]
    cmp r11d, edx
    jne .Lima4_update
    mov r9d, eax
    sub r9d, r10d
    jns .Lima4_distance
    neg r9d
.Lima4_distance:
    cmp r9d, 0x7f
    jle .Lima4_kept                       # close: keep the running predictor
.Lima4_update:
    mov r10d, eax
    mov r11d, edx
.Lima4_kept:
    cmp r11d, 88
    ja .Lima4_bad
    add rsi, 2
    mov eax, [rip + adpcm_stride]
    imul eax, ecx
    lea rdi, [rax + r14*2]
    add rdi, [rip + adpcm_planes]
    push rcx
    mov ecx, 64
.Lima4_nibble:
    test ecx, 1
    jnz .Lima4_high
    movzx edx, byte ptr [rsi]
    and edx, 15
    jmp .Lima4_expand
.Lima4_high:
    movzx edx, byte ptr [rsi]
    shr edx, 4
    inc rsi
.Lima4_expand:
    movzx eax, word ptr [r15 + r11*2]     # step
    mov r8d, eax
    shr r8d, 3                            # diff
    test edx, 4
    jz .Lima4_bit2
    add r8d, eax
.Lima4_bit2:
    test edx, 2
    jz .Lima4_bit1
    mov r9d, eax
    shr r9d, 1
    add r8d, r9d
.Lima4_bit1:
    test edx, 1
    jz .Lima4_sign
    shr eax, 2
    add r8d, eax
.Lima4_sign:
    test edx, 8
    jz .Lima4_add
    sub r10d, r8d
    jmp .Lima4_clip
.Lima4_add:
    add r10d, r8d
.Lima4_clip:
    cmp r10d, -32768
    jge .Lima4_clip_high
    mov r10d, -32768
.Lima4_clip_high:
    cmp r10d, 32767
    jle .Lima4_index
    mov r10d, 32767
.Lima4_index:
    movsx eax, byte ptr [rbx + rdx]
    add r11d, eax
    jns .Lima4_index_high
    xor r11d, r11d
.Lima4_index_high:
    cmp r11d, 88
    jbe .Lima4_store
    mov r11d, 88
.Lima4_store:
    mov [rdi], r10w
    add rdi, 2
    dec ecx
    jnz .Lima4_nibble
    pop rcx
    lea r8, [rip + adpcm_state]
    mov [r8 + rcx*8], r10d
    mov [r8 + rcx*8 + 4], r11d
    inc ecx
    cmp ecx, r13d
    jb .Lima4_channel
    add r14d, 64
    jmp .Lima4_group
.Lima4_done:
    mov eax, 1
    jmp .Lima4_return
.Lima4_bad:
    xor eax, eax
.Lima4_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ima4_block

# R8=Microsoft channel state, EAX=nibble -> the next sample stored at [RDI]
# (RDI advances). Clobbers RAX, RCX, RDX, R9.
.macro MS_NIBBLE
    mov r9d, eax
    mov eax, [r8 + MS_S1]
    imul eax, [r8 + MS_C1]
    mov ecx, [r8 + MS_S2]
    imul ecx, [r8 + MS_C2]
    add eax, ecx
    cdq
    and edx, 255
    add eax, edx
    sar eax, 8                            # C division by 256
    mov ecx, r9d
    shl ecx, 28
    sar ecx, 28                           # signed nibble
    imul ecx, [r8 + MS_DELTA]
    add eax, ecx
    cmp eax, -32768
    jge 1f
    mov eax, -32768
1:
    cmp eax, 32767
    jle 2f
    mov eax, 32767
2:
    mov ecx, [r8 + MS_S1]
    mov [r8 + MS_S2], ecx
    mov [r8 + MS_S1], eax
    mov [rdi], ax
    add rdi, 2
    lea rcx, [rip + ms_adapt]
    mov eax, [rcx + r9*4]
    imul eax, [r8 + MS_DELTA]
    sar eax, 8
    cmp eax, 16
    jge 3f
    mov eax, 16
3:
    cmp eax, MS_DELTA_MAX
    jle 4f
    mov eax, MS_DELTA_MAX
4:
    mov [r8 + MS_DELTA], eax
.endm

# RCX=Microsoft ADPCM block, EDX=samples per channel -> EAX=1 with the
# channel planes filled. The header holds each channel's predictor, delta
# and two samples (output oldest first); each byte then carries the first
# channel in its high nibble and the last in its low nibble.
LOCALFN ms_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rsi, rcx
    mov r12d, edx
    mov r13d, [rip + adpcm_channels]
    lea r8, [rip + ms_state]
    xor ecx, ecx
.Lms_predictor:
    movzx eax, byte ptr [rsi + rcx]
    cmp eax, 6
    ja .Lms_bad
    lea rdx, [rip + ms_coeff1]
    mov r9d, [rdx + rax*4]
    mov [r8 + MS_C1], r9d
    lea rdx, [rip + ms_coeff2]
    mov r9d, [rdx + rax*4]
    mov [r8 + MS_C2], r9d
    add r8, MS_SIZE
    inc ecx
    cmp ecx, r13d
    jb .Lms_predictor
    add rsi, r13                          # deltas, then first and second samples
    lea r8, [rip + ms_state]
    xor ecx, ecx
.Lms_header:
    movsx eax, word ptr [rsi + rcx*2]
    mov [r8 + MS_DELTA], eax
    lea rdx, [rsi + r13*2]
    movsx eax, word ptr [rdx + rcx*2]
    mov [r8 + MS_S1], eax
    lea rdx, [rdx + r13*2]
    movsx eax, word ptr [rdx + rcx*2]
    mov [r8 + MS_S2], eax
    mov r9d, [rip + adpcm_stride]
    imul r9d, ecx
    add r9, [rip + adpcm_planes]
    mov [r9], ax                          # second sample first
    mov eax, [r8 + MS_S1]
    mov [r9 + 2], ax
    add r8, MS_SIZE
    inc ecx
    cmp ecx, r13d
    jb .Lms_header
    lea rax, [r13 + r13*2]
    lea rsi, [rsi + rax*2]                # nibbles
    lea r14d, [r12 - 2]
    imul r14d, r13d
    shr r14d, 1                           # bytes
    mov rdi, [rip + adpcm_planes]
    add rdi, 4
    mov ebx, [rip + adpcm_stride]
    add rbx, rdi                          # second plane (stereo)
.Lms_byte:
    test r14d, r14d
    jz .Lms_done
    movzx eax, byte ptr [rsi]
    shr eax, 4
    lea r8, [rip + ms_state]
    MS_NIBBLE
    movzx eax, byte ptr [rsi]
    and eax, 15
    inc rsi
    dec r14d
    cmp r13d, 1
    je .Lms_mono
    xchg rdi, rbx
    lea r8, [rip + ms_state + MS_SIZE]
    MS_NIBBLE
    xchg rdi, rbx
    jmp .Lms_byte
.Lms_mono:
    lea r8, [rip + ms_state]
    MS_NIBBLE
    jmp .Lms_byte
.Lms_done:
    mov eax, 1
    jmp .Lms_return
.Lms_bad:
    xor eax, eax
.Lms_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ms_block

# RCX=stereo float output, EDX=frames from the int16 planes -> EAX=frames.
LOCALFN adpcm_emit
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    mov ebx, edx
    mov rsi, [rip + adpcm_planes]
    mov r10d, [rip + adpcm_stride]
    mov r11d, [rip + adpcm_channels]
    movss xmm5, [rip + adpcm_scale]
    xor ecx, ecx
    cmp dword ptr [rip + pcm_mix], 0
    jne .Ladpcm_emit_mix
.Ladpcm_emit_direct:
    cmp ecx, ebx
    jae .Ladpcm_emit_done
    movsx eax, word ptr [rsi + rcx*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, xmm5
    movaps xmm1, xmm0
    cmp r11d, 1
    je .Ladpcm_emit_pair
    lea rax, [rsi + r10]
    movsx eax, word ptr [rax + rcx*2]
    cvtsi2ss xmm1, eax
    mulss xmm1, xmm5
.Ladpcm_emit_pair:
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    jmp .Ladpcm_emit_direct
.Ladpcm_emit_mix:
    cmp ecx, ebx
    jae .Ladpcm_emit_done
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    lea r8, [rsi + rcx*2]
    lea r9, [rip + pcm_mix_coeff]
    xor edx, edx
.Ladpcm_emit_channel:
    movsx eax, word ptr [r8]
    cvtsi2ss xmm2, eax
    mulss xmm2, xmm5
    cvtss2sd xmm2, xmm2
    movapd xmm3, xmm2
    mulsd xmm2, [r9]
    mulsd xmm3, [r9 + 8]
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r8, r10
    add r9, 16
    inc edx
    cmp edx, r11d
    jb .Ladpcm_emit_channel
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    jmp .Ladpcm_emit_mix
.Ladpcm_emit_done:
    mov eax, ebx
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN adpcm_emit
