# Original Sun/NeXT AU reader, included by src/decoder.s. MIT, see LICENSE.
# A ".snd" header of six big-endian 32-bit fields (data offset, data size or
# 0xFFFFFFFF for "to the end", encoding, rate, channels), an annotation up
# to the data offset, then interleaved samples read directly by the PCM
# reader: encodings 1 (µ-law), 27 (A-law), 2-5 (signed 8-32-bit
# big-endian), 6 and 7 (big-endian float32/64). Channels mix to stereo with
# the default WAVE layout of their count. G.726 (encodings 23, 25 and 26 for
# 4-, 3- and 5-bit codes, "7262" for 2-bit, packed from the low bit) and
# G.722 (24) open through the WAVE reader's ADPCM packets, described by a
# WAVE-style fmt.
.equ AU_MALFORMED, 100
.equ AU_UNSUPPORTED, 101

.bss
au_fmt: .zero 16

.text
# RCX=file (".snd"), RDX=end -> EAX=1 with the PCM reader set up, or 2 with
# wav_codec, its fmt and the data bounds set for the ADPCM packets.
LOCALFN au_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov dword ptr [rip + decode_error], AU_MALFORMED
    mov rax, rdi
    sub rax, rsi
    cmp rax, 24
    jb .Lau_bad
    mov ebx, [rsi + 4]
    bswap ebx                               # data offset
    cmp ebx, 24
    jb .Lau_bad
    cmp rbx, rax
    ja .Lau_bad
    mov eax, [rsi + 20]
    bswap eax                               # channels
    test eax, eax
    jz .Lau_bad
    mov ecx, [rsi + 16]
    bswap ecx                               # rate
    test ecx, ecx
    jz .Lau_bad
    mov dword ptr [rip + decode_error], AU_UNSUPPORTED
    cmp eax, 8
    ja .Lau_bad
    mov [rip + source_channels], eax
    cmp ecx, 8000
    jb .Lau_bad
    cmp ecx, 192000
    ja .Lau_bad
    mov [rip + sample_rate], ecx
    mov eax, [rsi + 12]
    bswap eax                               # encoding
    mov dword ptr [rip + wav_format], 1
    mov dword ptr [rip + pcm_big_endian], 1
    mov edx, 8
    cmp eax, 1
    je .Lau_ulaw
    cmp eax, 27
    je .Lau_alaw
    cmp eax, 2
    je .Lau_signed8
    mov edx, 16
    cmp eax, 3
    je .Lau_bits
    mov edx, 24
    cmp eax, 4
    je .Lau_bits
    mov edx, 32
    cmp eax, 5
    je .Lau_bits
    cmp eax, 6
    je .Lau_float
    mov edx, 64
    cmp eax, 7
    je .Lau_float
    mov edx, 4                              # G.726 code size
    cmp eax, 23
    je .Lau_g726
    mov edx, 3
    cmp eax, 25
    je .Lau_g726
    mov edx, 5
    cmp eax, 26
    je .Lau_g726
    mov edx, 2
    cmp eax, 0x37323632                     # "7262"
    je .Lau_g726
    cmp eax, 24
    jne .Lau_bad                            # other encodings
    mov eax, 0x28f                          # G.722
    mov edx, 4
    jmp .Lau_codec
.Lau_g726:
    mov eax, 0x4c47                         # ADPCM_G726LE in src/adpcm.s
.Lau_codec:
    lea rcx, [rip + au_fmt]
    mov [rcx], ax
    mov r8d, [rip + source_channels]
    mov [rcx + 2], r8w
    mov r8d, [rip + sample_rate]
    mov [rcx + 4], r8d
    mov word ptr [rcx + 12], 1
    mov [rcx + 14], dx
    mov [rip + wav_codec], eax
    mov [rip + wav_codec_fmt], rcx
    mov dword ptr [rip + wav_codec_fmt_bytes], 16
    mov dword ptr [rip + wav_codec_kind], 16
    lea r8, [rsi + rbx]                     # data
    mov eax, [rsi + 8]
    bswap eax                               # data bytes
    mov r9, rdi
    cmp eax, 0xffffffff
    je .Lau_codec_sized
    lea r10, [r8 + rax]
    cmp r10, r9
    cmovb r9, r10
.Lau_codec_sized:
    cmp r9, r8
    jbe .Lau_malformed
    mov [rip + wav_begin], r8
    mov [rip + wav_end], r9
    mov dword ptr [rip + decode_error], 0
    mov eax, 2
    jmp .Lau_return
.Lau_malformed:
    mov dword ptr [rip + decode_error], AU_MALFORMED
    jmp .Lau_bad
.Lau_float:
    mov dword ptr [rip + wav_format], 3
    jmp .Lau_bits
.Lau_ulaw:
    mov dword ptr [rip + pcm_g711], 2
    jmp .Lau_bits
.Lau_alaw:
    mov dword ptr [rip + pcm_g711], 1
    jmp .Lau_bits
.Lau_signed8:
    mov dword ptr [rip + pcm_signed8], 1
.Lau_bits:
    mov [rip + wav_container_bits], edx
    mov [rip + source_bits], edx
    shr edx, 3
    imul edx, [rip + source_channels]
    mov [rip + wav_align], edx
    lea r8, [rsi + rbx]                     # data
    mov eax, [rsi + 8]
    bswap eax                               # data bytes
    mov r9, rdi
    cmp eax, 0xffffffff
    je .Lau_sized
    lea r10, [r8 + rax]
    cmp r10, r9
    cmovb r9, r10                           # a short file ends sooner
.Lau_sized:
    mov rax, r9
    sub rax, r8
    xor edx, edx
    mov ecx, [rip + wav_align]
    div rcx                                 # whole frames
    mov [rip + total_frames], rax
    imul rax, rcx
    mov [rip + wav_begin], r8
    mov [rip + input_cursor], r8
    add rax, r8
    mov [rip + wav_end], rax
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    call pcm_build_mix
    test eax, eax
    jz .Lau_bad
    mov eax, 128
    sub eax, [rip + wav_container_bits]
    cmp dword ptr [rip + pcm_g711], 0
    je .Lau_scale
    mov eax, 128 - 16                       # G.711 expands to 16 bits
.Lau_scale:
    shl eax, 23
    mov [rip + float_scale], eax
    mov dword ptr [rip + codec_kind], 16
    mov dword ptr [rip + decode_error], 0
    mov eax, 1
    jmp .Lau_return
.Lau_bad:
    xor eax, eax
.Lau_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN au_open
