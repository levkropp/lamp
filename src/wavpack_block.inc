# WavPack blocks and frames (included by src/wavpack.s): block iteration in
# native and Matroska packets, metadata sub-blocks, frame decoding into the
# channel buffers, stereo output, and the probe, file and track entry points.

.bss
.p2align 3
wv_blk_body: .zero 8                # current block's metadata
wv_blk_bytes: .zero 4
wv_block_format: .zero 4            # sample format of the current block
wv_block_bits: .zero 4              # bytes per output sample * 8
wv_frame_samples: .zero 4

.text
# RCX=packet, EDX=bytes -> EAX=1 when its blocks can be walked (a Matroska
# frame starts with its sample count; FFmpeg needs at least 12 bytes).
LOCALFN wv_iter_start
    mov [rip + wv_iter], rcx
    mov eax, edx
    add rax, rcx
    mov [rip + wv_iter + 8], rax
    mov eax, 1
    cmp dword ptr [rip + wv_matroska], 0
    je .Lwv_iter_start_done
    xor eax, eax
    cmp edx, 12
    jb .Lwv_iter_start_done
    mov eax, [rcx]
    mov [rip + wv_iter + 16], eax
    add qword ptr [rip + wv_iter], 4
    mov eax, 1
.Lwv_iter_start_done:
    ret
ENDFN wv_iter_start

# -> EAX=1 with the next block's metadata (wv_blk_body, wv_blk_bytes) and its
# sample count, flags and CRC; 0 after the last block; -1 when a block
# overruns the packet. Native blocks carry the 32-byte header; Matroska
# blocks keep flags and CRC, and a size unless the frame is one block.
LOCALFN wv_iter_next
    mov rcx, [rip + wv_iter]
    mov rdx, [rip + wv_iter + 8]
    sub rdx, rcx                          # bytes left
    cmp dword ptr [rip + wv_matroska], 0
    jne .Lwv_next_matroska
    xor eax, eax
    cmp rdx, 32
    jbe .Lwv_next_return                  # a header alone is not decoded
    mov r8d, [rcx + 4]                    # block size after the first 8 bytes
    mov eax, -1
    cmp r8d, 24
    jb .Lwv_next_return
    lea r9, [r8 + 8]
    cmp r9, rdx
    ja .Lwv_next_return
    mov eax, [rcx + 20]
    mov [rip + wv_samples], eax
    mov eax, [rcx + 24]
    mov [rip + wv_flags], eax
    mov eax, [rcx + 28]
    mov [rip + wv_crc], eax
    lea rax, [rcx + 32]
    mov [rip + wv_blk_body], rax
    sub r8d, 24
    mov [rip + wv_blk_bytes], r8d
    add rcx, r9
    mov [rip + wv_iter], rcx
    mov eax, 1
    ret
.Lwv_next_matroska:
    xor eax, eax
    cmp rdx, 8
    jb .Lwv_next_return
    mov eax, [rcx]
    mov [rip + wv_flags], eax
    mov r8d, [rcx + 4]
    mov [rip + wv_crc], r8d
    mov r8d, [rip + wv_iter + 16]
    mov [rip + wv_samples], r8d
    add rcx, 8
    sub rdx, 8
    and eax, F_INITIAL | F_FINAL
    cmp eax, F_INITIAL | F_FINAL
    je .Lwv_next_single                   # the rest of the frame
    mov eax, -1
    cmp rdx, 4
    jb .Lwv_next_return
    mov r8d, [rcx]
    add rcx, 4
    sub rdx, 4
    cmp r8, rdx
    ja .Lwv_next_return
    mov rdx, r8
.Lwv_next_single:
    mov [rip + wv_blk_body], rcx
    mov [rip + wv_blk_bytes], edx
    add rcx, rdx
    mov [rip + wv_iter], rcx
    mov eax, 1
.Lwv_next_return:
    ret
ENDFN wv_iter_next

# ECX=block flags -> EAX=sample format: 0 16-bit domain (up to 16 bits),
# 1 32-bit, 2 float. Clobbers RCX.
LOCALFN wv_format_of
    mov eax, 2
    test ecx, F_FLOAT | F_DSD
    jnz .Lwv_format_done
    and ecx, 3
    xor eax, eax
    cmp ecx, 1
    seta al
.Lwv_format_done:
    ret
ENDFN wv_format_of

# -> EAX=sample rate of the block in wv_flags (its SAMPLE_RATE sub-block when
# the rate code is 15), 0 when missing.
LOCALFN wv_block_rate_of
    mov eax, [rip + wv_flags]
    shr eax, 23
    and eax, 15
    cmp eax, 15
    je .Lwv_rate_custom
    lea rcx, [rip + wv_rates]
    mov eax, [rcx + rax*4]
    ret
.Lwv_rate_custom:
    mov eax, [rip + wv_block_rate]
    ret
ENDFN wv_block_rate_of

# -> EAX=channels of the frame whose first block was just parsed, EDX=its
# WAVE channel mask (0 for the default layout); EAX=0 when they disagree.
# One-block frames are mono or stereo; others use the first block's
# CHANNEL_INFO (FFmpeg's rules).
LOCALFN wv_frame_layout
    mov eax, [rip + wv_flags]
    and eax, F_INITIAL | F_FINAL
    cmp eax, F_INITIAL | F_FINAL
    jne .Lwv_layout_multi
    mov eax, [rip + wv_stereo]
    inc eax
    mov edx, 4
    cmp eax, 1
    je .Lwv_layout_return
    mov edx, 3
    ret
.Lwv_layout_multi:
    mov edx, [rip + wv_block_mask]
    mov eax, [rip + wv_block_chan]
    test edx, edx
    jz .Lwv_layout_return                 # default layout for the count
    xor eax, eax                          # speakers in the mask
    mov ecx, edx
.Lwv_layout_bits:
    test ecx, ecx
    jz .Lwv_layout_counted
    lea r8d, [rcx - 1]
    and ecx, r8d
    inc eax
    jmp .Lwv_layout_bits
.Lwv_layout_counted:
    mov ecx, [rip + wv_block_chan]
    test ecx, ecx
    jz .Lwv_layout_return
    cmp ecx, eax
    je .Lwv_layout_return
    xor eax, eax
.Lwv_layout_return:
    ret
ENDFN wv_frame_layout

# R9=cursor, R11=sub-block end -> EAX=next little-endian word (zero past the
# end); R9 advances by two.
LOCALFN wv_meta_word
    xor eax, eax
    lea rcx, [r9 + 2]
    cmp rcx, r11
    ja .Lwv_meta_word_past
    movzx eax, word ptr [r9]
.Lwv_meta_word_past:
    add r9, 2
    ret
ENDFN wv_meta_word

# R9=cursor, R11=sub-block end -> EAX=wp_exp2 of the next word. Clobbers
# RCX, RDX, R8.
LOCALFN wv_meta_exp2
    call wv_meta_word
    mov ecx, eax
    jmp wv_exp2
ENDFN wv_meta_exp2

# Weight byte in EAX (signed) -> EAX=weight: w * 8, plus (w + 64) >> 7 when
# positive. Clobbers EDX.
.macro WV_WEIGHT
    shl eax, 3
    test eax, eax
    jle 8f
    lea edx, [rax + 64]
    sar edx, 7
    add eax, edx
8:
.endm

# Block state from wv_flags and the metadata sub-blocks of the current block
# (FFmpeg wavpack_decode_block) -> EAX=1, 0 when malformed, 2 for DSD audio.
# Registers: RSI sub-block payload, RDI metadata end, R13D payload bytes,
# R14D id, R15 bytes with padding.
LOCALFN wv_parse_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    lea rdi, [rip + wv_decorr]
    mov ecx, 16*DC_SIZE/4
    xor eax, eax
    rep stosd
    lea rdi, [rip + wv_ch]
    mov ecx, 2*CH_SIZE/4
    rep stosd
    mov [rip + wv_terms], eax
    mov [rip + wv_extra_bits], eax
    mov [rip + wv_and], eax
    mov [rip + wv_or], eax
    mov [rip + wv_shift], eax
    mov [rip + wv_got_extra], eax
    mov [rip + wv_got], eax
    mov [rip + wv_block_rate], eax
    mov [rip + wv_block_chan], eax
    mov [rip + wv_block_mask], eax
    # Channel arrangement and modes.
    mov ebx, [rip + wv_flags]
    test ebx, F_MONO
    setz al
    mov [rip + wv_stereo], eax
    test ebx, F_FALSE_STEREO
    jz .Lwv_parse_stereo_in
    xor eax, eax
.Lwv_parse_stereo_in:
    mov [rip + wv_stereo_in], eax
    mov eax, ebx
    and eax, F_HYBRID
    mov [rip + wv_hybrid], eax
    mov eax, ebx
    and eax, F_HYBRID_BITRATE
    mov [rip + wv_bitrate], eax
    # post_shift = output bits - original bits + the header's shift; hybrid
    # output clips to the original bits.
    mov ecx, ebx
    call wv_format_of
    mov [rip + wv_block_format], eax
    mov r12d, 32
    test eax, eax
    jnz .Lwv_parse_bits
    mov r12d, 16
.Lwv_parse_bits:
    mov [rip + wv_block_bits], r12d
    mov ecx, ebx
    and ecx, 3
    inc ecx
    shl ecx, 3                            # original bits
    mov eax, r12d
    sub eax, ecx
    mov edx, ebx
    shr edx, 13
    and edx, 0x1f
    add eax, edx
    cmp eax, 31
    ja .Lwv_parse_bad
    mov [rip + wv_post_shift], eax
    dec ecx
    mov eax, 1
    shl eax, cl
    lea edx, [rax - 1]
    mov [rip + wv_maxclip], edx
    neg eax
    mov [rip + wv_minclip], eax
    mov rsi, [rip + wv_blk_body]
    mov edi, [rip + wv_blk_bytes]
    add rdi, rsi
.Lwv_meta:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 2
    jb .Lwv_meta_done
    movzx r14d, byte ptr [rsi]
    movzx r15d, byte ptr [rsi + 1]        # size in words
    add rsi, 2
    test r14d, 0x80                       # long size
    jz .Lwv_meta_size
    cmp rax, 4
    jb .Lwv_meta_done
    movzx eax, word ptr [rsi]
    shl eax, 8
    or r15d, eax
    add rsi, 2
.Lwv_meta_size:
    add r15d, r15d
    mov r13d, r15d
    test r14d, 0x40                       # odd size: one padding byte
    jz .Lwv_meta_fits
    dec r13d
    js .Lwv_meta_done
.Lwv_meta_fits:
    mov rax, rdi
    sub rax, rsi
    cmp rax, r15
    jb .Lwv_meta_done
    mov eax, r14d
    and eax, 0x3f
    cmp eax, 2
    je .Lwv_meta_terms
    cmp eax, 3
    je .Lwv_meta_weights
    cmp eax, 4
    je .Lwv_meta_samples
    cmp eax, 5
    je .Lwv_meta_entropy
    cmp eax, 6
    je .Lwv_meta_hybrid
    cmp eax, 8
    je .Lwv_meta_float
    cmp eax, 9
    je .Lwv_meta_int32
    cmp eax, 0xa
    je .Lwv_meta_data
    cmp eax, 0xc
    je .Lwv_meta_extra
    cmp eax, 0xd
    je .Lwv_meta_channels
    cmp eax, 0xe
    je .Lwv_meta_dsd
    cmp eax, 0x27
    je .Lwv_meta_rate
    jmp .Lwv_meta_next                    # other ids are skipped
.Lwv_meta_terms:
    cmp r13d, 16
    jbe .Lwv_terms_fit
    mov dword ptr [rip + wv_terms], 0
    jmp .Lwv_meta_next
.Lwv_terms_fit:
    mov [rip + wv_terms], r13d
    xor ecx, ecx
.Lwv_terms_byte:
    cmp ecx, r13d
    jae .Lwv_terms_done
    movzx eax, byte ptr [rsi + rcx]
    mov edx, r13d
    sub edx, ecx
    dec edx                               # stored last term first
    imul edx, edx, DC_SIZE
    lea r8, [rip + wv_decorr]
    add r8, rdx
    mov edx, eax
    and edx, 0x1f
    sub edx, 5
    mov [r8 + DC_VALUE], edx
    shr eax, 5
    mov [r8 + DC_DELTA], eax
    inc ecx
    jmp .Lwv_terms_byte
.Lwv_terms_done:
    or dword ptr [rip + wv_got], GOT_TERMS
    jmp .Lwv_meta_next
.Lwv_meta_weights:
    test dword ptr [rip + wv_got], GOT_TERMS
    jz .Lwv_meta_next
    mov r8d, r13d
    mov ecx, [rip + wv_stereo_in]
    shr r8d, cl                           # weights
    cmp r8d, 16
    ja .Lwv_meta_next
    cmp r8d, [rip + wv_terms]
    ja .Lwv_meta_next
    xor ecx, ecx
    mov r9, rsi
.Lwv_weights_term:
    cmp ecx, r8d
    jae .Lwv_weights_done
    mov edx, [rip + wv_terms]
    sub edx, ecx
    dec edx
    imul edx, edx, DC_SIZE
    lea r10, [rip + wv_decorr]
    add r10, rdx
    movsx eax, byte ptr [r9]
    inc r9
    WV_WEIGHT
    mov [r10 + DC_WA], eax
    cmp dword ptr [rip + wv_stereo_in], 0
    je .Lwv_weights_next
    movsx eax, byte ptr [r9]
    inc r9
    WV_WEIGHT
    mov [r10 + DC_WB], eax
.Lwv_weights_next:
    inc ecx
    jmp .Lwv_weights_term
.Lwv_weights_done:
    or dword ptr [rip + wv_got], GOT_WEIGHTS
    jmp .Lwv_meta_next
.Lwv_meta_samples:
    # History for each term from the last, until the sub-block is used up.
    test dword ptr [rip + wv_got], GOT_TERMS
    jz .Lwv_meta_next
    xor ebx, ebx                          # bytes accounted
    mov r12d, [rip + wv_terms]
    mov r9, rsi
    lea r11, [rsi + r13]
.Lwv_samples_term:
    dec r12d
    js .Lwv_samples_done
    cmp ebx, r13d
    jge .Lwv_samples_done
    imul eax, r12d, DC_SIZE
    lea r10, [rip + wv_decorr]
    add r10, rax
    mov eax, [r10 + DC_VALUE]
    cmp eax, 8
    jle .Lwv_samples_short
    call wv_meta_exp2
    mov [r10 + DC_SA], eax
    call wv_meta_exp2
    mov [r10 + DC_SA + 4], eax
    add ebx, 4
    cmp dword ptr [rip + wv_stereo_in], 0
    je .Lwv_samples_term
    call wv_meta_exp2
    mov [r10 + DC_SB], eax
    call wv_meta_exp2
    mov [r10 + DC_SB + 4], eax
    add ebx, 4
    jmp .Lwv_samples_term
.Lwv_samples_short:
    test eax, eax
    jns .Lwv_samples_history
    call wv_meta_exp2
    mov [r10 + DC_SA], eax
    call wv_meta_exp2
    mov [r10 + DC_SB], eax
    add ebx, 4
    jmp .Lwv_samples_term
.Lwv_samples_history:
    xor r14d, r14d
.Lwv_samples_value:
    cmp r14d, [r10 + DC_VALUE]
    jae .Lwv_samples_counted
    call wv_meta_exp2
    mov [r10 + DC_SA + r14*4], eax
    cmp dword ptr [rip + wv_stereo_in], 0
    je .Lwv_samples_value_next
    call wv_meta_exp2
    mov [r10 + DC_SB + r14*4], eax
.Lwv_samples_value_next:
    inc r14d
    jmp .Lwv_samples_value
.Lwv_samples_counted:
    mov eax, [r10 + DC_VALUE]
    mov ecx, [rip + wv_stereo_in]
    inc ecx
    imul eax, ecx
    lea ebx, [rbx + rax*2]
    jmp .Lwv_samples_term
.Lwv_samples_done:
    or dword ptr [rip + wv_got], GOT_SAMPLES
    jmp .Lwv_meta_next
.Lwv_meta_entropy:
    mov eax, [rip + wv_stereo_in]
    inc eax
    imul eax, eax, 6
    cmp r13d, eax
    jne .Lwv_meta_next
    mov r9, rsi
    lea r11, [rsi + r13]
    lea r10, [rip + wv_ch]
    xor r12d, r12d
.Lwv_entropy_channel:
    cmp r12d, [rip + wv_stereo_in]
    ja .Lwv_entropy_done
    call wv_meta_exp2
    mov [r10 + CH_MEDIAN], eax
    call wv_meta_exp2
    mov [r10 + CH_MEDIAN + 4], eax
    call wv_meta_exp2
    mov [r10 + CH_MEDIAN + 8], eax
    add r10, CH_SIZE
    inc r12d
    jmp .Lwv_entropy_channel
.Lwv_entropy_done:
    or dword ptr [rip + wv_got], GOT_ENTROPY
    jmp .Lwv_meta_next
.Lwv_meta_hybrid:
    # Slow levels (bit rate mode), accumulators, then deltas when sent.
    mov r9, rsi
    lea r11, [rsi + r13]
    mov ebx, r13d                         # bytes left
    cmp dword ptr [rip + wv_bitrate], 0
    je .Lwv_hybrid_rate
    lea r10, [rip + wv_ch]
    xor r12d, r12d
.Lwv_hybrid_slow:
    cmp r12d, [rip + wv_stereo_in]
    ja .Lwv_hybrid_rate
    call wv_meta_exp2
    mov [r10 + CH_SLOW], eax
    sub ebx, 2
    add r10, CH_SIZE
    inc r12d
    jmp .Lwv_hybrid_slow
.Lwv_hybrid_rate:
    lea r10, [rip + wv_ch]
    xor r12d, r12d
.Lwv_hybrid_acc:
    cmp r12d, [rip + wv_stereo_in]
    ja .Lwv_hybrid_delta
    call wv_meta_word
    shl eax, 16
    mov [r10 + CH_ACC], eax
    sub ebx, 2
    add r10, CH_SIZE
    inc r12d
    jmp .Lwv_hybrid_acc
.Lwv_hybrid_delta:
    test ebx, ebx
    jle .Lwv_hybrid_done                  # no deltas: they stay zero
    lea r10, [rip + wv_ch]
    xor r12d, r12d
.Lwv_hybrid_delta_channel:
    cmp r12d, [rip + wv_stereo_in]
    ja .Lwv_hybrid_done
    call wv_meta_exp2
    mov [r10 + CH_DELTA], eax
    add r10, CH_SIZE
    inc r12d
    jmp .Lwv_hybrid_delta_channel
.Lwv_hybrid_done:
    or dword ptr [rip + wv_got], GOT_HYBRID
    jmp .Lwv_meta_next
.Lwv_meta_int32:
    # Extra bits, or a shift with zeros, ones or copies of the low bit.
    cmp r13d, 4
    jne .Lwv_meta_next
    movzx eax, byte ptr [rsi]
    cmp eax, 30
    ja .Lwv_meta_next
    test eax, eax
    jz .Lwv_int32_shift
    mov [rip + wv_extra_bits], eax
    jmp .Lwv_int32_check
.Lwv_int32_shift:
    movzx eax, byte ptr [rsi + 1]
    test eax, eax
    jz .Lwv_int32_ones
    mov [rip + wv_shift], eax
    jmp .Lwv_int32_check
.Lwv_int32_ones:
    movzx eax, byte ptr [rsi + 2]
    test eax, eax
    jz .Lwv_int32_dup
    mov dword ptr [rip + wv_and], 1
    mov dword ptr [rip + wv_or], 1
    mov [rip + wv_shift], eax
    jmp .Lwv_int32_check
.Lwv_int32_dup:
    movzx eax, byte ptr [rsi + 3]
    test eax, eax
    jz .Lwv_int32_check
    mov dword ptr [rip + wv_and], 1
    mov [rip + wv_shift], eax
.Lwv_int32_check:
    cmp dword ptr [rip + wv_shift], 31
    jbe .Lwv_int32_clip
    xor eax, eax
    mov [rip + wv_and], eax
    mov [rip + wv_or], eax
    mov [rip + wv_shift], eax
    jmp .Lwv_meta_next
.Lwv_int32_clip:
    # Lossy 32-bit audio clips as 24-bit (as the WavPack library does).
    cmp dword ptr [rip + wv_hybrid], 0
    je .Lwv_meta_next
    cmp dword ptr [rip + wv_block_bits], 32
    jne .Lwv_meta_next
    cmp dword ptr [rip + wv_post_shift], 8
    jae .Lwv_meta_next
    cmp dword ptr [rip + wv_shift], 8
    jbe .Lwv_meta_next
    add dword ptr [rip + wv_post_shift], 8
    sub dword ptr [rip + wv_shift], 8
    sar dword ptr [rip + wv_maxclip], 8
    sar dword ptr [rip + wv_minclip], 8
    jmp .Lwv_meta_next
.Lwv_meta_float:
    cmp r13d, 4
    jne .Lwv_meta_next
    movzx eax, byte ptr [rsi]
    mov [rip + wv_float_flag], eax
    movzx eax, byte ptr [rsi + 1]
    mov [rip + wv_float_shift], eax
    movzx eax, byte ptr [rsi + 2]
    mov [rip + wv_float_exp], eax
    cmp dword ptr [rip + wv_float_shift], 31
    jbe .Lwv_float_info
    mov dword ptr [rip + wv_float_shift], 0
    jmp .Lwv_meta_next
.Lwv_float_info:
    or dword ptr [rip + wv_got], GOT_FLOAT
    jmp .Lwv_meta_next
.Lwv_meta_data:
    cmp r13d, 0x10000000
    jae .Lwv_parse_bad
    mov [rip + wv_main + BR_DATA], rsi
    lea eax, [r13*8]
    mov [rip + wv_main + BR_BITS], eax
    mov dword ptr [rip + wv_main + BR_POS], 0
    or dword ptr [rip + wv_got], GOT_DATA
    jmp .Lwv_meta_next
.Lwv_meta_extra:
    cmp r13d, 4
    jbe .Lwv_meta_next
    cmp r13d, 0x10000000
    jae .Lwv_parse_bad
    mov [rip + wv_extra + BR_DATA], rsi
    lea eax, [r13*8]
    mov [rip + wv_extra + BR_BITS], eax
    mov dword ptr [rip + wv_extra + BR_POS], 0
    lea rcx, [rip + wv_extra]
    mov edx, 32
    call wv_read
    mov [rip + wv_crc_extra_want], eax
    mov dword ptr [rip + wv_got_extra], 1
    jmp .Lwv_meta_next
.Lwv_meta_channels:
    # Channel count, then the mask in 1-4 bytes; 6-7 bytes is the extended
    # form with 12-bit counts (count - 1) and a 3-4 byte mask.
    cmp r13d, 1
    jbe .Lwv_parse_bad
    movzx eax, byte ptr [rsi]
    mov [rip + wv_block_chan], eax
    lea ecx, [r13 - 2]
    lea r8, [rsi + 1]
    lea r9d, [r13 - 1]                    # mask bytes
    cmp ecx, 4
    jb .Lwv_channels_mask
    cmp ecx, 5
    ja .Lwv_meta_next
    movzx edx, byte ptr [rsi + 2]
    and edx, 0xf
    shl edx, 8
    or eax, edx
    inc eax
    mov [rip + wv_block_chan], eax
    lea r8, [rsi + 3]
    lea r9d, [r13 - 3]
.Lwv_channels_mask:
    xor eax, eax
.Lwv_channels_byte:
    dec r9d
    js .Lwv_channels_done
    shl eax, 8
    movzx edx, byte ptr [r8 + r9]
    or eax, edx
    jmp .Lwv_channels_byte
.Lwv_channels_done:
    mov [rip + wv_block_mask], eax
    jmp .Lwv_meta_next
.Lwv_meta_rate:
    cmp r13d, 3
    jne .Lwv_parse_bad
    movzx eax, word ptr [rsi]
    movzx ecx, byte ptr [rsi + 2]
    shl ecx, 16
    or eax, ecx
    mov [rip + wv_block_rate], eax
    jmp .Lwv_meta_next
.Lwv_meta_dsd:
    mov eax, 2
    jmp .Lwv_parse_return
.Lwv_meta_next:
    add rsi, r15
    jmp .Lwv_meta
.Lwv_meta_done:
    # Required sub-blocks.
    mov eax, [rip + wv_got]
    and eax, GOT_TERMS | GOT_WEIGHTS | GOT_SAMPLES | GOT_ENTROPY | GOT_DATA
    cmp eax, GOT_TERMS | GOT_WEIGHTS | GOT_SAMPLES | GOT_ENTROPY | GOT_DATA
    jne .Lwv_parse_bad
    cmp dword ptr [rip + wv_hybrid], 0
    je .Lwv_parse_float
    test dword ptr [rip + wv_got], GOT_HYBRID
    jz .Lwv_parse_bad
.Lwv_parse_float:
    cmp dword ptr [rip + wv_block_format], 2
    jne .Lwv_parse_extra
    test dword ptr [rip + wv_got], GOT_FLOAT
    jz .Lwv_parse_bad
    jmp .Lwv_parse_ok
.Lwv_parse_extra:
    # Integer extra bits are ignored unless every sample's are present.
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_parse_ok
    mov eax, [rip + wv_samples]
    mov ecx, [rip + wv_extra_bits]
    imul rax, rcx
    mov ecx, [rip + wv_stereo_in]
    shl rax, cl
    lea rcx, [rip + wv_extra]
    mov edx, [rcx + BR_BITS]
    sub edx, [rcx + BR_POS]
    movsxd rdx, edx
    cmp rdx, rax
    jge .Lwv_parse_ok
    mov dword ptr [rip + wv_got_extra], 0
.Lwv_parse_ok:
    mov eax, 1
    jmp .Lwv_parse_return
.Lwv_parse_bad:
    xor eax, eax
.Lwv_parse_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_parse_block

.text
# RCX=packet, EDX=bytes -> EAX=samples per channel decoded into the channel
# buffers, or 0 with decode_error set. Every block must have the frame's
# sample count and the stream's format; the first block fixes the rate and
# channel count, which must match the stream's; blocks for channels beyond
# them are ignored, too few channels fail (FFmpeg's rules). Registers: ESI
# next channel, EDI blocks seen.
LOCALFN wv_decode_frame
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    call wv_iter_start
    test eax, eax
    jz .Lwv_frame_bad
    xor esi, esi
    xor edi, edi
.Lwv_frame_block:
    call wv_iter_next
    test eax, eax
    jz .Lwv_frame_end
    js .Lwv_frame_bad
    mov eax, [rip + wv_samples]
    test edi, edi
    jnz .Lwv_frame_later
    lea ecx, [rax - 1]
    cmp ecx, WV_MAX_SAMPLES - 1
    ja .Lwv_frame_bad
    mov [rip + wv_frame_samples], eax
    jmp .Lwv_frame_format
.Lwv_frame_later:
    cmp eax, [rip + wv_frame_samples]
    jne .Lwv_frame_bad
.Lwv_frame_format:
    mov ecx, [rip + wv_flags]
    call wv_format_of
    cmp eax, [rip + wv_format]
    jne .Lwv_frame_bad
    call wv_parse_block
    cmp eax, 2
    je .Lwv_frame_unsupported
    test eax, eax
    jz .Lwv_frame_bad
    test edi, edi
    jnz .Lwv_frame_place
    call wv_block_rate_of
    cmp eax, [rip + sample_rate]
    jne .Lwv_frame_bad
    call wv_frame_layout
    cmp eax, [rip + wv_channels]
    jne .Lwv_frame_bad
.Lwv_frame_place:
    inc edi
    mov eax, esi
    add eax, [rip + wv_stereo]
    cmp eax, [rip + wv_channels]
    jb .Lwv_frame_unpack
    test esi, esi
    jz .Lwv_frame_bad
    jmp .Lwv_frame_block                  # beyond the frame's channels
.Lwv_frame_unpack:
    imul rax, rsi, WV_STRIDE
    add rax, [rip + wv_buffers]
    mov [rip + wv_out], rax
    add rax, WV_STRIDE
    mov [rip + wv_out + 8], rax
    mov eax, [rip + wv_stereo]
    lea esi, [rsi + rax + 1]
    mov dword ptr [rip + wv_crc_extra], -1
    cmp dword ptr [rip + wv_stereo_in], 0
    je .Lwv_frame_mono
    call wv_unpack_stereo
    test eax, eax
    jz .Lwv_frame_bad
    jmp .Lwv_frame_block
.Lwv_frame_mono:
    call wv_unpack_mono
    test eax, eax
    jz .Lwv_frame_bad
    cmp dword ptr [rip + wv_stereo], 0
    je .Lwv_frame_block
    # False stereo: both channels are the decoded one.
    mov r8, [rip + wv_out]
    mov r9, [rip + wv_out + 8]
    mov ecx, [rip + wv_samples]
.Lwv_frame_copy:
    mov eax, [r8 + rcx*4 - 4]
    mov [r9 + rcx*4 - 4], eax
    dec ecx
    jnz .Lwv_frame_copy
    jmp .Lwv_frame_block
.Lwv_frame_end:
    test edi, edi
    jz .Lwv_frame_bad
    cmp esi, [rip + wv_channels]
    jne .Lwv_frame_bad
    mov eax, [rip + wv_frame_samples]
    jmp .Lwv_frame_return
.Lwv_frame_unsupported:
    mov dword ptr [rip + decode_error], WV_UNSUPPORTED
.Lwv_frame_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lwv_frame_failed
    mov dword ptr [rip + decode_error], WV_MALFORMED
.Lwv_frame_failed:
    xor eax, eax
.Lwv_frame_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_decode_frame

# XMM register <- channel sample at the address as FFmpeg's float output
# presents it: int16 / 2^15, int32 / 2^31 or the float itself (R11D=format).
# Clobbers EAX.
.macro WV_TO_FLOAT reg, address
    cmp r11d, 1
    jb 5f
    je 6f
    movss \reg, \address
    jmp 7f
5:
    movsx eax, word ptr \address
    cvtsi2ss \reg, eax
    mulss \reg, [rip + wv_scale16]
    jmp 7f
6:
    cvtsi2ss \reg, dword ptr \address
    mulss \reg, [rip + wv_scale32]
7:
.endm

# RCX=stereo float output, EDX=frames from the channel buffers -> EAX=frames.
# Mono and stereo pass through; other layouts mix with the speaker weights.
LOCALFN wv_emit
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rcx
    mov ebx, edx
    mov rsi, [rip + wv_buffers]
    mov r11d, [rip + wv_format]
    mov r12d, [rip + wv_channels]
    xor ecx, ecx
    cmp dword ptr [rip + pcm_mix], 0
    jne .Lwv_emit_mix
.Lwv_emit_direct:
    cmp ecx, ebx
    jae .Lwv_emit_done
    WV_TO_FLOAT xmm0, [rsi + rcx*4]
    movaps xmm1, xmm0
    cmp r12d, 1
    je .Lwv_emit_pair
    WV_TO_FLOAT xmm1, [rsi + rcx*4 + WV_STRIDE]
.Lwv_emit_pair:
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    jmp .Lwv_emit_direct
.Lwv_emit_mix:
    cmp ecx, ebx
    jae .Lwv_emit_done
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    lea r8, [rsi + rcx*4]
    lea r9, [rip + pcm_mix_coeff]
    xor edx, edx
.Lwv_emit_channel:
    WV_TO_FLOAT xmm2, [r8]
    cvtss2sd xmm2, xmm2
    movapd xmm3, xmm2
    mulsd xmm2, [r9]
    mulsd xmm3, [r9 + 8]
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r8, WV_STRIDE
    add r9, 16
    inc edx
    cmp edx, r12d
    jb .Lwv_emit_channel
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    jmp .Lwv_emit_mix
.Lwv_emit_done:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_emit

# RCX=mapped start, RDX=end -> EAX=1 when the data (after an ID3v2 tag)
# begins with a WavPack block header.
FN wv_probe
    sub rsp, 40
    mov [rsp + 32], rdx
    call adts_skip_id3
    mov rdx, [rsp + 32]
    sub rdx, rax
    xor ecx, ecx
    cmp rdx, 32
    jbe .Lwv_probe_return
    cmp dword ptr [rax], 0x6b707677       # "wvpk"
    jne .Lwv_probe_return
    mov edx, [rax + 4]
    cmp edx, 24
    jb .Lwv_probe_return
    cmp edx, 1048576
    ja .Lwv_probe_return
    mov ecx, 1
.Lwv_probe_return:
    mov eax, ecx
    add rsp, 40
    ret
ENDFN wv_probe

# RCX=mapped start, RDX=end -> EAX=1 with every frame (the blocks from one
# with audio to a final block) listed as a track packet and the decoder
# opened. Blocks without samples between frames are skipped; the file ends
# at a truncated or invalid block (an APE or ID3v1 tag, a partial frame).
FN wv_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    mov ecx, TK_WAVPACK
    call track_begin
    test eax, eax
    jz .Lwv_open_bad
    xor r12d, r12d                        # start of the open frame
    xor r13d, r13d                        # blocks seen
.Lwv_open_block:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lwv_open_continue
    cmp dword ptr [rax], 0
    jne .Lwv_open_bad
.Lwv_open_continue:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 32
    jb .Lwv_open_done
    cmp dword ptr [rsi], 0x6b707677       # "wvpk"
    jne .Lwv_open_done
    mov ebx, [rsi + 4]
    cmp ebx, 24
    jb .Lwv_open_invalid
    cmp ebx, 1048576
    ja .Lwv_open_invalid
    movzx ecx, word ptr [rsi + 8]
    cmp ecx, 0x402
    jb .Lwv_open_version
    cmp ecx, 0x410
    ja .Lwv_open_version
    lea rcx, [rbx + 8]
    cmp rcx, rax
    ja .Lwv_open_done                     # truncated
    inc r13d
    cmp dword ptr [rsi + 20], 0
    jne .Lwv_open_audio
    test r12, r12
    jnz .Lwv_open_audio                   # inside a frame it fails to decode
    lea rsi, [rsi + rbx + 8]
    jmp .Lwv_open_block
.Lwv_open_audio:
    test r12, r12
    jnz .Lwv_open_in_frame
    mov r12, rsi
.Lwv_open_in_frame:
    mov eax, [rsi + 24]
    lea rsi, [rsi + rbx + 8]
    test eax, F_FINAL
    jz .Lwv_open_block
    mov rcx, r12
    mov rdx, rsi
    sub rdx, r12
    call track_add
    test eax, eax
    jz .Lwv_open_bad
    xor r12d, r12d
    jmp .Lwv_open_block
.Lwv_open_version:
    test r13d, r13d
    jnz .Lwv_open_done
    mov dword ptr [rip + decode_error], WV_UNSUPPORTED
    jmp .Lwv_open_bad
.Lwv_open_invalid:
    test r13d, r13d
    jz .Lwv_open_bad
.Lwv_open_done:
    cmp qword ptr [rip + track_count], 0
    je .Lwv_open_bad
    mov qword ptr [rip + track_config], 0
    mov dword ptr [rip + track_config_bytes], 0
    call track_finish
    test eax, eax
    jz .Lwv_open_bad
    mov dword ptr [rip + codec_kind], CODEC_WAVPACK
    mov eax, 1
    jmp .Lwv_open_return
.Lwv_open_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lwv_open_failed
    mov dword ptr [rip + decode_error], WV_MALFORMED
.Lwv_open_failed:
    xor eax, eax
.Lwv_open_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_open

# RCX=configuration (unused), EDX=its bytes, R8=first packet, R9D=its bytes
# -> EAX=1 with the format of the first frame published and the channel
# buffers allocated. Native packets start with a block header; Matroska
# frames with the sample count.
FN wv_track_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, r8
    mov edi, r9d
    mov dword ptr [rip + wv_matroska], 1
    cmp edi, 4
    jb .Lwv_track_layout
    cmp dword ptr [rsi], 0x6b707677       # "wvpk"
    jne .Lwv_track_layout
    mov dword ptr [rip + wv_matroska], 0
.Lwv_track_layout:
    mov rcx, rsi
    mov edx, edi
    call wv_iter_start
    test eax, eax
    jz .Lwv_track_malformed
    call wv_iter_next
    cmp eax, 1
    jne .Lwv_track_malformed
    mov eax, [rip + wv_samples]
    dec eax
    cmp eax, WV_MAX_SAMPLES - 1
    ja .Lwv_track_malformed
    mov ebx, [rip + wv_flags]
    test ebx, F_DSD
    jnz .Lwv_track_unsupported
    mov ecx, ebx
    call wv_format_of
    mov [rip + wv_format], eax
    call wv_parse_block
    cmp eax, 2
    je .Lwv_track_unsupported
    test eax, eax
    jz .Lwv_track_malformed
    call wv_block_rate_of
    test eax, eax
    jz .Lwv_track_malformed
    cmp eax, 8000
    jb .Lwv_track_unsupported
    cmp eax, 192000
    ja .Lwv_track_unsupported
    mov [rip + sample_rate], eax
    call wv_frame_layout
    test eax, eax
    jz .Lwv_track_malformed
    cmp eax, WV_CHANNELS
    ja .Lwv_track_unsupported
    mov [rip + wv_channels], eax
    mov [rip + source_channels], eax
    mov [rip + pcm_channel_mask], edx
    xor ecx, ecx
    test edx, edx
    setnz cl
    mov [rip + pcm_mask_seen], ecx
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + pcm_mix], 0
    mov eax, ebx
    and eax, 3
    inc eax
    shl eax, 3
    mov [rip + source_bits], eax
    call pcm_build_mix
    test eax, eax
    jz .Lwv_track_unsupported             # speakers beyond the WAVE mask
    mov ecx, [rip + wv_channels]
    imul ecx, ecx, WV_STRIDE
    call mem_alloc
    test rax, rax
    jz .Lwv_track_malformed
    mov [rip + wv_buffers], rax
    mov eax, 1
    jmp .Lwv_track_return
.Lwv_track_unsupported:
    mov dword ptr [rip + decode_error], WV_UNSUPPORTED
    xor eax, eax
    jmp .Lwv_track_return
.Lwv_track_malformed:
    mov dword ptr [rip + decode_error], WV_MALFORMED
    xor eax, eax
.Lwv_track_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_track_open

FN wv_track_close
    sub rsp, 40
    mov rcx, [rip + wv_buffers]
    test rcx, rcx
    jz .Lwv_track_close_done
    call mem_free
    mov qword ptr [rip + wv_buffers], 0
.Lwv_track_close_done:
    add rsp, 40
    ret
ENDFN wv_track_close

# Frames decode independently: nothing to clear.
FN wv_track_reset
    ret
ENDFN wv_track_reset

# RCX=packet, EDX=bytes -> EAX=samples, or -1 unless every block has the
# first block's sample count (1-150000) and the stream's format.
FN wv_track_samples
    push rbx
    push rsi
    sub rsp, 40
    call wv_iter_start
    test eax, eax
    jz .Lwv_samples_bad
    xor ebx, ebx
.Lwv_samples_block:
    call wv_iter_next
    test eax, eax
    jz .Lwv_samples_end
    js .Lwv_samples_bad
    mov eax, [rip + wv_samples]
    test ebx, ebx
    jnz .Lwv_samples_later
    lea ecx, [rax - 1]
    cmp ecx, WV_MAX_SAMPLES - 1
    ja .Lwv_samples_bad
    mov esi, eax
    jmp .Lwv_samples_format
.Lwv_samples_later:
    cmp eax, esi
    jne .Lwv_samples_bad
.Lwv_samples_format:
    mov ecx, [rip + wv_flags]
    call wv_format_of
    cmp eax, [rip + wv_format]
    jne .Lwv_samples_bad
    inc ebx
    jmp .Lwv_samples_block
.Lwv_samples_end:
    test ebx, ebx
    jz .Lwv_samples_bad
    mov eax, esi
    jmp .Lwv_samples_return
.Lwv_samples_bad:
    mov eax, -1
.Lwv_samples_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN wv_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# or -1 with decode_error set.
FN wv_track_decode
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, r8
    mov esi, r9d
    call wv_decode_frame
    test eax, eax
    jz .Lwv_decode_bad
    cmp eax, esi
    ja .Lwv_decode_bad
    mov rcx, rbx
    mov edx, eax
    call wv_emit
    jmp .Lwv_decode_return
.Lwv_decode_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lwv_decode_failed
    mov dword ptr [rip + decode_error], WV_MALFORMED
.Lwv_decode_failed:
    mov eax, -1
.Lwv_decode_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN wv_track_decode
