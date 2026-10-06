# Original Core Audio Format reader (included by src/decoder.s). MIT, see LICENSE.
# Apple's CAF specification: a "caff" header (version 1), then big-endian
# chunks with 64-bit sizes; desc must come first, a data chunk sized -1 runs
# to the end of the file. Linear PCM (8-32-bit integers and float32/64 in
# either byte order) and G.711 read directly like AIFF-C, with the chan
# chunk's Core Audio layout; IMA4, ALAC, AAC, MPEG audio, AC-3 and Opus
# packets (constant sizes from desc, or variable from pakt) go through the
# track layer, the packet table's priming and remainder frames trimmed.

.equ CAF_UNSUPPORTED, 101
.equ CAF_MALFORMED, 100
.equ CAF_FPP, 16                    # desc fields after the float64 rate
.equ CAF_FORMAT, 8
.equ CAF_FLAGS, 12
.equ CAF_BPP, 16
.equ CAF_FRAMES, 20
.equ CAF_CHANNELS, 24
.equ CAF_BITS, 28

RODATA
.p2align 3
caf_rate_low: .double 7999.5        # rates that round into 8-192 kHz
caf_rate_high: .double 192000.49

.data
caf_desc: .quad 0
caf_data: .quad 0
caf_data_end: .quad 0
caf_pakt: .quad 0
caf_pakt_end: .quad 0
caf_kuki: .quad 0
caf_kuki_bytes: .long 0
caf_fields: .zero 32                # desc in native byte order

.bss
caf_fmt: .zero 16                   # WAVE-style description for IMA4
caf_opus_head: .zero 20             # OpusHead for Opus (no kuki)

.text
# RCX=big-endian 64-bit pointer -> RAX.
.macro CAF_BE64 dst, address
    mov \dst, \address
    bswap \dst
.endm

# R8=cursor, R9=end -> RAX=next packet table number (seven bits a byte, the
# high bit continuing), R8 advanced; RAX=-1 past the end or beyond 32 bits.
LOCALFN caf_varint
    xor eax, eax
    mov ecx, 5
.Lcaf_varint_byte:
    cmp r8, r9
    jae .Lcaf_varint_bad
    movzx edx, byte ptr [r8]
    inc r8
    shl rax, 7
    mov r10d, edx
    and r10d, 0x7f
    or rax, r10
    test edx, 0x80
    jz .Lcaf_varint_done
    dec ecx
    jnz .Lcaf_varint_byte
.Lcaf_varint_bad:
    mov rax, -1
    ret
.Lcaf_varint_done:
    mov rdx, rax
    shr rdx, 32
    jnz .Lcaf_varint_bad
    ret
ENDFN caf_varint

# RCX=mapped start, RDX=end -> EAX=1 with the stream opened.
LOCALFN caf_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    xor eax, eax
    mov [rip + caf_desc], rax
    mov [rip + caf_data], rax
    mov [rip + caf_pakt], rax
    mov [rip + caf_kuki], rax
    mov qword ptr [rip + aiff_chan], 0
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jb .Lcaf_bad
    cmp word ptr [rsi + 4], 0x0100          # version 1
    jne .Lcaf_bad
    lea rbx, [rsi + 8]                      # chunk
.Lcaf_chunk:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lcaf_chunk_continue
    cmp dword ptr [rax], 0
    jne .Lcaf_bad
.Lcaf_chunk_continue:
    mov rax, rdi
    sub rax, rbx
    cmp rax, 12
    jb .Lcaf_chunks_done                    # the end, or a fragment after it
    mov r12d, [rbx]                         # type
    CAF_BE64 r13, [rbx + 4]                 # size
    lea r14, [rbx + 12]                     # payload
    cmp qword ptr [rip + caf_desc], 0
    jne .Lcaf_sized
    cmp r12d, 0x63736564                    # desc must come first
    jne .Lcaf_bad
.Lcaf_sized:
    cmp r13, -1
    jne .Lcaf_size
    cmp r12d, 0x61746164                    # only data may run to the end
    jne .Lcaf_bad
    mov r15, rdi
    jmp .Lcaf_dispatch
.Lcaf_size:
    test r13, r13
    js .Lcaf_bad
    mov rax, rdi
    sub rax, r14
    cmp r13, rax
    ja .Lcaf_bad
    lea r15, [r14 + r13]                    # payload end
.Lcaf_dispatch:
    mov rax, r15
    sub rax, r14
    cmp r12d, 0x63736564                    # desc
    je .Lcaf_desc
    cmp r12d, 0x61746164                    # data
    je .Lcaf_data
    cmp r12d, 0x746b6170                    # pakt
    je .Lcaf_pakt
    cmp r12d, 0x696b756b                    # kuki
    je .Lcaf_kuki
    cmp r12d, 0x6e616863                    # chan
    je .Lcaf_chan
    jmp .Lcaf_next
.Lcaf_desc:
    cmp qword ptr [rip + caf_desc], 0
    jne .Lcaf_bad
    cmp rax, 32
    jb .Lcaf_bad
    mov [rip + caf_desc], r14
    jmp .Lcaf_next
.Lcaf_data:
    cmp qword ptr [rip + caf_data], 0
    jne .Lcaf_bad
    cmp rax, 4                              # edit count
    jb .Lcaf_bad
    lea rax, [r14 + 4]
    mov [rip + caf_data], rax
    mov [rip + caf_data_end], r15
    jmp .Lcaf_next
.Lcaf_pakt:
    cmp qword ptr [rip + caf_pakt], 0
    jne .Lcaf_bad
    cmp rax, 24
    jb .Lcaf_bad
    mov [rip + caf_pakt], r14
    mov [rip + caf_pakt_end], r15
    jmp .Lcaf_next
.Lcaf_kuki:
    cmp qword ptr [rip + caf_kuki], 0
    jne .Lcaf_bad
    mov [rip + caf_kuki], r14
    mov [rip + caf_kuki_bytes], eax
    jmp .Lcaf_next
.Lcaf_chan:
    cmp qword ptr [rip + aiff_chan], 0
    jne .Lcaf_bad
    cmp rax, 12
    jb .Lcaf_bad
    mov [rip + aiff_chan], r14
    mov [rip + aiff_chan_size], rax
    mov ecx, [r14 + 8]
    bswap ecx
    imul rcx, 20
    add rcx, 12
    cmp rcx, rax
    ja .Lcaf_bad
.Lcaf_next:
    mov rbx, r15
    cmp r13, -1
    jne .Lcaf_chunk
.Lcaf_chunks_done:
    cmp qword ptr [rip + caf_desc], 0
    je .Lcaf_bad
    cmp qword ptr [rip + caf_data], 0
    je .Lcaf_bad
    # desc fields in native order.
    mov rax, [rip + caf_desc]
    lea rcx, [rip + caf_fields]
    CAF_BE64 rdx, [rax]
    mov [rcx], rdx
    xor edx, edx
.Lcaf_field:
    mov r8d, [rax + rdx*4 + 8]
    cmp edx, 0
    je .Lcaf_field_store                    # format id stays a FourCC
    bswap r8d
.Lcaf_field_store:
    mov [rcx + rdx*4 + 8], r8d
    inc edx
    cmp edx, 6
    jb .Lcaf_field
    # Rate: positive, finite, 8-192 kHz after rounding.
    movsd xmm0, [rcx]
    ucomisd xmm0, [rip + caf_rate_low]
    jp .Lcaf_unsupported
    jb .Lcaf_unsupported
    ucomisd xmm0, [rip + caf_rate_high]
    ja .Lcaf_unsupported
    cvtsd2si eax, xmm0
    mov [rip + sample_rate], eax
    mov eax, [rcx + CAF_CHANNELS]
    test eax, eax
    jz .Lcaf_bad
    cmp eax, 8
    ja .Lcaf_unsupported
    mov [rip + source_channels], eax
    mov eax, [rcx + CAF_FORMAT]
    cmp eax, 0x6d63706c                     # lpcm
    je .Lcaf_pcm
    cmp eax, 0x77616c61                     # alaw
    je .Lcaf_alaw
    cmp eax, 0x77616c75                     # ulaw
    je .Lcaf_ulaw
    # Packets through the track layer.
    mov ebx, 10                             # TK_ADPCM
    cmp eax, 0x34616d69                     # ima4
    je .Lcaf_track
    mov ebx, 6                              # TK_ALAC
    cmp eax, 0x63616c61                     # alac
    je .Lcaf_track
    mov ebx, 7                              # TK_AAC
    cmp eax, 0x20636161                     # "aac "
    je .Lcaf_track
    mov ebx, 3                              # TK_MPA
    cmp eax, 0x33706d2e                     # .mp3
    je .Lcaf_track
    cmp eax, 0x32706d2e                     # .mp2
    je .Lcaf_track
    cmp eax, 0x31706d2e                     # .mp1
    je .Lcaf_track
    mov ebx, 8                              # TK_AC3
    cmp eax, 0x332d6361                     # ac-3
    je .Lcaf_track
    mov ebx, 5                              # TK_OPUS
    cmp eax, 0x7375706f                     # opus
    je .Lcaf_track
    jmp .Lcaf_unsupported
.Lcaf_alaw:
    mov dword ptr [rip + pcm_g711], 1
    jmp .Lcaf_g711
.Lcaf_ulaw:
    mov dword ptr [rip + pcm_g711], 2
.Lcaf_g711:
    mov eax, 8
    mov edx, 8
    jmp .Lcaf_direct
.Lcaf_pcm:
    # Signed integers (8-32 bits) or IEEE floats, filling their containers.
    mov dword ptr [rip + wav_format], 1
    mov dword ptr [rip + pcm_signed8], 1
    xor eax, eax
    test dword ptr [rcx + CAF_FLAGS], 2     # little-endian
    setz al
    mov [rip + pcm_big_endian], eax
    mov eax, [rcx + CAF_BPP]
    xor edx, edx
    div dword ptr [rcx + CAF_CHANNELS]
    test edx, edx
    jnz .Lcaf_bad
    shl eax, 3                              # container bits
    mov edx, [rcx + CAF_BITS]
    cmp edx, eax
    jne .Lcaf_unsupported
    test dword ptr [rcx + CAF_FLAGS], 1     # float
    jz .Lcaf_pcm_integer
    mov dword ptr [rip + wav_format], 3
    cmp eax, 32
    je .Lcaf_direct
    cmp eax, 64
    je .Lcaf_direct
    jmp .Lcaf_unsupported
.Lcaf_pcm_integer:
    cmp eax, 8
    je .Lcaf_direct
    cmp eax, 16
    je .Lcaf_direct
    cmp eax, 24
    je .Lcaf_direct
    cmp eax, 32
    jne .Lcaf_unsupported
.Lcaf_direct:
    # EAX=container bits, EDX=valid bits; one frame per packet.
    cmp dword ptr [rcx + CAF_FRAMES], 1
    jne .Lcaf_bad
    mov [rip + wav_container_bits], eax
    mov [rip + source_bits], edx
    shr eax, 3
    imul eax, [rip + source_channels]
    cmp eax, [rcx + CAF_BPP]
    jne .Lcaf_bad
    mov [rip + wav_align], eax
    mov r8, [rip + caf_data]
    mov rax, [rip + caf_data_end]
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
    cmp qword ptr [rip + aiff_chan], 0
    je .Lcaf_default_layout
    call aiff_build_mix
    test eax, eax
    jz .Lcaf_bad
    jmp .Lcaf_scale
.Lcaf_default_layout:
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    call pcm_build_mix
    test eax, eax
    jz .Lcaf_bad
.Lcaf_scale:
    mov eax, 128
    sub eax, [rip + wav_container_bits]
    cmp dword ptr [rip + pcm_g711], 0
    je .Lcaf_scale_set
    mov eax, 128 - 16                       # G.711 expands to 16 bits
.Lcaf_scale_set:
    shl eax, 23
    mov [rip + float_scale], eax
    jmp .Lcaf_ok
.Lcaf_track:
    mov ecx, ebx
    call track_begin
    test eax, eax
    jz .Lcaf_bad
    mov qword ptr [rip + track_config], 0
    mov dword ptr [rip + track_config_bytes], 0
    lea r15, [rip + caf_fields]
    cmp ebx, 10
    je .Lcaf_ima4
    cmp ebx, 6
    je .Lcaf_alac
    cmp ebx, 7
    je .Lcaf_aac
    cmp ebx, 5
    je .Lcaf_opus
    jmp .Lcaf_packets
.Lcaf_ima4:
    # A WAVE-style description: 34-byte blocks, 64 frames each.
    imul eax, [r15 + CAF_CHANNELS], 34
    cmp eax, [r15 + CAF_BPP]
    jne .Lcaf_bad
    cmp dword ptr [r15 + CAF_FRAMES], 64
    jne .Lcaf_bad
    lea rcx, [rip + caf_fmt]
    mov word ptr [rcx], 0x4d49              # ADPCM_QT in src/adpcm.s
    mov eax, [r15 + CAF_CHANNELS]
    mov [rcx + 2], ax
    mov eax, [rip + sample_rate]
    mov [rcx + 4], eax
    mov eax, [r15 + CAF_BPP]
    mov [rcx + 12], ax
    mov word ptr [rcx + 14], 4
    mov [rip + track_config], rcx
    mov dword ptr [rip + track_config_bytes], 16
    jmp .Lcaf_packets
.Lcaf_alac:
    # kuki: the 24-byte ALACSpecificConfig, or (older files) frma and alac
    # atoms around it.
    mov rax, [rip + caf_kuki]
    test rax, rax
    jz .Lcaf_bad
    mov ecx, [rip + caf_kuki_bytes]
    cmp ecx, 24
    jb .Lcaf_bad
    cmp ecx, 48
    jb .Lcaf_alac_config
    cmp dword ptr [rax + 4], 0x616d7266     # frma
    jne .Lcaf_alac_config
    cmp dword ptr [rax + 8], 0x63616c61     # alac
    jne .Lcaf_alac_config
    add rax, 24                             # frma atom, alac atom header
    sub ecx, 24
.Lcaf_alac_config:
    mov [rip + track_config], rax
    mov [rip + track_config_bytes], ecx
    jmp .Lcaf_packets
.Lcaf_aac:
    # kuki: an ES_Descriptor with the AudioSpecificConfig.
    mov rcx, [rip + caf_kuki]
    test rcx, rcx
    jz .Lcaf_bad
    mov edx, [rip + caf_kuki_bytes]
    add rdx, rcx
    call mp4_es_descriptor
    cmp eax, 7
    jne .Lcaf_unsupported
    mov rax, [rip + mp4_config]
    mov [rip + track_config], rax
    mov eax, [rip + mp4_config_bytes]
    mov [rip + track_config_bytes], eax
    jmp .Lcaf_packets
.Lcaf_opus:
    # No cookie: a mapping family 0 OpusHead with no pre-skip (the packet
    # table's priming trims instead).
    mov eax, [r15 + CAF_CHANNELS]
    cmp eax, 2
    ja .Lcaf_unsupported
    lea rcx, [rip + caf_opus_head]
    mov rdx, 0x646165487375704f             # "OpusHead"
    mov [rcx], rdx
    mov byte ptr [rcx + 8], 1
    mov [rcx + 9], al
    mov word ptr [rcx + 10], 0
    mov eax, [rip + sample_rate]
    mov [rcx + 12], eax
    mov word ptr [rcx + 16], 0
    mov byte ptr [rcx + 18], 0
    mov [rip + track_config], rcx
    mov dword ptr [rip + track_config_bytes], 19
    mov dword ptr [rip + track_edit], 1     # keep the packet table's trim
.Lcaf_packets:
    mov rsi, [rip + caf_data]
    mov rdi, [rip + caf_data_end]
    mov r12d, [r15 + CAF_BPP]
    test r12d, r12d
    jz .Lcaf_table
.Lcaf_constant:
    # Constant packet size: whole packets.
    mov rax, rdi
    sub rax, rsi
    cmp rax, r12
    jb .Lcaf_packets_done
    mov rcx, rsi
    mov edx, r12d
    add rsi, r12
    call track_add
    test eax, eax
    jz .Lcaf_bad
    jmp .Lcaf_constant
.Lcaf_table:
    # Variable sizes from the packet table; variable frames are unsupported.
    cmp dword ptr [r15 + CAF_FRAMES], 0
    je .Lcaf_unsupported
    mov r8, [rip + caf_pakt]
    test r8, r8
    jz .Lcaf_bad
    mov r9, [rip + caf_pakt_end]
    CAF_BE64 r13, [r8]                      # packets
    mov eax, [r8 + 16]
    bswap eax
    mov [rip + track_start_trim], rax       # priming frames
    mov eax, [r8 + 20]
    bswap eax
    mov [rip + track_end_trim], rax         # remainder frames
    add r8, 24
.Lcaf_table_entry:
    test r13, r13
    jz .Lcaf_packets_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lcaf_table_continue
    cmp dword ptr [rax], 0
    jne .Lcaf_bad
.Lcaf_table_continue:
    call caf_varint
    cmp rax, -1
    je .Lcaf_bad
    mov rdx, rdi
    sub rdx, rsi
    cmp rax, rdx
    ja .Lcaf_bad
    mov rcx, rsi
    mov edx, eax
    add rsi, rax
    mov [rsp + 32], r8
    mov [rsp + 40], r9
    call track_add
    mov r8, [rsp + 32]
    mov r9, [rsp + 40]
    test eax, eax
    jz .Lcaf_bad
    dec r13
    jmp .Lcaf_table_entry
.Lcaf_packets_done:
    cmp qword ptr [rip + track_count], 0
    je .Lcaf_bad
    call track_finish
    test eax, eax
    jz .Lcaf_bad
.Lcaf_ok:
    mov dword ptr [rip + codec_kind], 13
    mov eax, 1
    jmp .Lcaf_return
.Lcaf_unsupported:
    mov dword ptr [rip + decode_error], CAF_UNSUPPORTED
.Lcaf_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lcaf_failed
    mov dword ptr [rip + decode_error], CAF_MALFORMED
.Lcaf_failed:
    xor eax, eax
.Lcaf_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN caf_open
