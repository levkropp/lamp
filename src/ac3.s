# AC-3 and conventional E-AC-3 (ATSC A/52) decoder in x86-64 assembly. MIT, see LICENSE.
# Reference: ATSC A/52 (Digital Audio Compression Standard). The structure,
# fixed-point mantissa path and error concealment follow FFmpeg's decoder,
# which the tests compare against. Tables: src/ac3_tables.inc
# (tests/generate-ac3-tables.py). Track mode: Matroska, MP4 and raw .ac3
# streams supply one or more sync frames per packet. bsid 0-10 (the
# alternate syntax of bsid 6, the half- and quarter-rate ids 9 and 10), plus
# E-AC-3 conventional mantissas (see eac3.inc and docs/eac3.md), all
# channel modes with LFE, block switching, coupling with phase flags,
# rematrixing, delta bit allocation, dynamic range and dither. The output
# mixes to stereo with the shared WAVE speaker weights. A frame whose CRC
# fails, and a block that does not decode, repeat the previous block's output.
.include "lamp.inc"
.globl ac3_probe, ac3_open, ac3_track_open, ac3_track_samples, ac3_track_decode
.globl ac3_track_reset, ac3_track_close

.equ AC3_MALFORMED, 100
.equ AC3_UNSUPPORTED, 101
.equ AC3_BLOCK, 256
.equ AC3_FRAME, 1536
.equ AC3_MAX_BYTES, 4096
.equ TK_AC3, 8
.equ CODEC_AC3, 11
.equ CODEC_EAC3, 20

RODATA
.include "ac3_tables.inc"
ac3_rates: .long 48000, 44100, 32000
ac3_channel_counts: .byte 2, 1, 2, 3, 3, 4, 4, 5
.p2align 1
ac3_remat_tab: .short 13, 25, 37, 61, 253
.p2align 2
# WAVE speaker masks by acmod (LFE adds 8): 1+1 as a stereo pair, 2/2 and 3/2
# surrounds as side speakers.
ac3_masks: .long 3, 4, 3, 7, 0x103, 0x107, 0x603, 0x607
# AC-3 channel (LFE last) -> WAVE position, by acmod and LFE.
ac3_wave_index:
    .byte 0, 1, 0, 0, 0, 0, 0, 0,  0, 1, 2, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0,  0, 1, 0, 0, 0, 0, 0, 0
    .byte 0, 1, 0, 0, 0, 0, 0, 0,  0, 1, 2, 0, 0, 0, 0, 0
    .byte 0, 2, 1, 0, 0, 0, 0, 0,  0, 2, 1, 3, 0, 0, 0, 0
    .byte 0, 1, 2, 0, 0, 0, 0, 0,  0, 1, 3, 2, 0, 0, 0, 0
    .byte 0, 2, 1, 3, 0, 0, 0, 0,  0, 2, 1, 4, 3, 0, 0, 0
    .byte 0, 1, 2, 3, 0, 0, 0, 0,  0, 1, 3, 4, 2, 0, 0, 0
    .byte 0, 2, 1, 3, 4, 0, 0, 0,  0, 2, 1, 4, 5, 3, 0, 0
.p2align 2
ac3_one: .float 1.0
ac3_gain_scale: .float 2.384185791015625e-7  # 2^-22

.data
ac3_key: .long -1                   # fscod | sr_shift << 2 | acmod << 4 | lfeon << 7 | enhanced << 8
ac3_bitpos: .long 0
ac3_bitlimit: .long 0               # frame bytes
ac3_acmod: .long 0
ac3_nf: .long 0                     # full-bandwidth channels
ac3_lfe: .long 0
ac3_lfe_ch: .long -1                # channel index of the LFE (nf + 1), or -1
ac3_channels: .long 0               # nf + lfe
ac3_shift: .long 0                  # sr_shift (bsid 9, 10)
ac3_fscod: .long 0
ac3_bsid: .long 0
ac3_enhanced: .long 0
ac3_blocks: .long 6
ac3_frame_samples: .long AC3_FRAME
ac3_lfg_index: .long 0
ac3_wave: .quad 0                   # this stream's row of ac3_wave_index

.bss
.p2align 6
ac3_fft: .zero 128*16               # complex doubles
ac3_y: .zero 256*8                  # DCT-IV output
ac3_coef: .zero 256*4               # one channel's scaled coefficients
ac3_fixed: .zero 7*256*4            # 24-bit fixed-point coefficients, channel 0 coupling
ac3_excite: .zero 64*4
ac3_groups: .zero 256               # exponent group values of one channel
ac3_frame: .zero AC3_MAX_BYTES + 16 # frame copy, zero padded for the bit reader
ac3_pcm: .zero 6*AC3_FRAME*4        # decoded frame, AC-3 channel order
ac3_last: .zero 6*AC3_BLOCK*4       # previous block's output, for concealment
ac3_lfg: .zero 64*4                 # dither generator state
ac3_stages: .zero 8                 # bit allocation stages to run, per channel
ac3_mant: .zero 32                  # grouped mantissas: counts and pending values
.p2align 6
ac3_state:                          # decoder state cleared by ac3_track_reset
ac3_delay: .zero 6*128*8            # overlap halves (doubles)
ac3_dexps: .zero 7*256
ac3_bap: .zero 7*256
ac3_psd: .zero 7*256*2
ac3_band_psd: .zero 7*64*2
ac3_mask: .zero 7*64*2
ac3_start: .zero 8*4
ac3_end: .zero 8*4
ac3_expstr: .zero 8*4
ac3_ngrps: .zero 8*4
ac3_incpl: .zero 8*4
ac3_coords: .zero 8*32*4            # coupling coordinates [channel][band]
ac3_phase: .zero 32
ac3_bndstrc: .zero 32
ac3_bndsz: .zero 32
ac3_ncplbnd: .zero 4
ac3_cplinu: .zero 4
ac3_phsinu: .zero 4
ac3_nremat: .zero 4
ac3_remat: .zero 4*4
ac3_sdecay: .zero 4
ac3_fdecay: .zero 4
ac3_sgain: .zero 4
ac3_dbknee: .zero 4
ac3_floorv: .zero 4
ac3_cplfleak: .zero 4
ac3_cplsleak: .zero 4
ac3_snr: .zero 8*4
ac3_fgain: .zero 8*4
ac3_dbamode: .zero 8*4
ac3_dbansegs: .zero 8*4
ac3_dbaoffst: .zero 64
ac3_dbalen: .zero 64
ac3_dbaval: .zero 64
ac3_dyn: .zero 8                    # two floats (dual mono: second channel's first)
ac3_blksw: .zero 8*4
ac3_dith: .zero 8*4
ac3_has_last: .zero 4
eac3_spx_active: .zero 4
eac3_spx_ch: .zero 8*4
eac3_spx_first: .zero 8*4
eac3_spx_atten_code: .zero 8*4
eac3_spx_copy: .zero 4
eac3_spx_start: .zero 4
eac3_spx_end: .zero 4
eac3_spx_count: .zero 4
eac3_spx_struct: .zero 32
eac3_spx_sizes: .zero 17*4
eac3_spx_noise: .zero 8*17*4
eac3_spx_signal: .zero 8*17*4
eac3_spx_rms: .zero 17*4
eac3_spx_wrap: .zero 17*4
.p2align 3
ac3_state_end:

.text
# ECX=bits (1-32) -> EAX from the frame copy; zero past the frame's end.
# Clobbers RCX, RDX.
LOCALFN ac3_get
    push rbx
    mov ebx, ecx
    mov edx, [rip + ac3_bitpos]
    add [rip + ac3_bitpos], ecx
    mov ecx, edx
    shr edx, 3
    xor eax, eax
    cmp edx, [rip + ac3_bitlimit]
    jae .Lac3_get_done
    lea rax, [rip + ac3_frame]
    mov rax, [rax + rdx]
    bswap rax
    and ecx, 7
    shl rax, cl
    mov ecx, 64
    sub ecx, ebx
    shr rax, cl
.Lac3_get_done:
    pop rbx
    ret
ENDFN ac3_get

# ECX=bits (1-32) -> EAX sign-extended. Clobbers RCX, RDX.
LOCALFN ac3_get_signed
    push rbx
    mov ebx, ecx
    call ac3_get
    mov ecx, 32
    sub ecx, ebx
    shl eax, cl
    sar eax, cl
    pop rbx
    ret
ENDFN ac3_get_signed

# RCX=data, RDX=bytes available (at least 8 are read) -> EAX=frame bytes, or 0
# when not a supported AC-3/E-AC-3 sync frame; EDX=key; ECX=bsid; R11D=blocks.
LOCALFN ac3_header
    push rbx
    xor eax, eax
    xor r10d, r10d
    cmp rdx, 8
    jb .Lac3_header_return
    cmp word ptr [rcx], 0x770b
    jne .Lac3_header_return
    movzx r10d, byte ptr [rcx + 5]
    shr r10d, 3                           # bsid
    cmp r10d, 10
    ja .Lac3_header_enhanced
    movzx r8d, byte ptr [rcx + 4]
    mov r9d, r8d
    shr r9d, 6                            # fscod
    cmp r9d, 3
    je .Lac3_header_return
    and r8d, 63                           # frmsizecod
    cmp r8d, 37
    ja .Lac3_header_return
    imul r11d, r9d, 38
    add r11d, r8d
    lea rax, [rip + ac3_frame_words]
    movzx eax, word ptr [rax + r11*2]
    add eax, eax                          # bytes
    movzx r11d, byte ptr [rcx + 6]
    shl r11d, 8
    movzx r8d, byte ptr [rcx + 7]
    or r11d, r8d                          # acmod in bits 15-13
    mov r8d, r11d
    shr r8d, 13                           # acmod
    xor ebx, ebx                          # bits between acmod and lfeon
    cmp r8d, 2
    jne .Lac3_header_mix
    mov ebx, 2                            # dsurmod
    jmp .Lac3_header_lfe
.Lac3_header_mix:
    test r8d, 1
    jz .Lac3_header_surround
    cmp r8d, 1
    je .Lac3_header_surround
    add ebx, 2                            # cmixlev
.Lac3_header_surround:
    test r8d, 4
    jz .Lac3_header_lfe
    add ebx, 2                            # surmixlev
.Lac3_header_lfe:
    mov ecx, 12
    sub ecx, ebx
    shr r11d, cl
    and r11d, 1                           # lfeon
    mov edx, r10d
    sub edx, 8
    jae .Lac3_header_key
    xor edx, edx                          # sr_shift
.Lac3_header_key:
    shl edx, 2
    or edx, r9d
    shl r8d, 4
    or edx, r8d
    shl r11d, 7
    or edx, r11d
.Lac3_header_return:
    mov r11d, 6
    mov ecx, r10d
    pop rbx
    ret
# E-AC-3 has a distinct sync header; keep the same stream-key contract.
.Lac3_header_enhanced:
    pop rbx
    jmp eac3_header
ENDFN ac3_header

# RCX=mapped start, RDX=end -> EAX=1 when the data begins with an AC-3 frame
# followed by another of the same stream, an ID3v1 tag or the end.
FN ac3_probe
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    mov [rsp + 32], rax                   # first frame
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    call ac3_header
    test eax, eax
    jnz .Lac3_probe_frame
    cmp ecx, 11                           # E-AC-3: recognise unsupported/malformed sync profiles
    jb .Lac3_probe_return
    cmp ecx, 16
    ja .Lac3_probe_return
    mov eax, 1
    jmp .Lac3_probe_return
.Lac3_probe_frame:
    mov ebx, edx
    add rsi, rax
    mov eax, 1
    cmp rsi, rdi
    jae .Lac3_probe_return                # one frame, possibly truncated
    mov rcx, rdi
    sub rcx, rsi
    cmp rcx, 128
    jne .Lac3_probe_next
    cmp word ptr [rsi], 0x4154            # "TA"
    jne .Lac3_probe_next
    cmp byte ptr [rsi + 2], 'G'
    je .Lac3_probe_return
.Lac3_probe_next:
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    call ac3_header
    test eax, eax
    jz .Lac3_probe_crc
    cmp edx, ebx
    je .Lac3_probe_yes
.Lac3_probe_crc:
    # Otherwise a first frame whose CRC holds still identifies the stream.
    mov rcx, [rsp + 32]
    mov rdx, rsi
    sub rdx, rcx
    call ac3_crc
    test eax, eax
    setz al
    movzx eax, al
    jmp .Lac3_probe_return
.Lac3_probe_yes:
    mov eax, 1
.Lac3_probe_return:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_probe

# RCX=frame, RDX=bytes -> EAX=CRC-16 of the bytes after the sync word (zero
# for an intact frame).
LOCALFN ac3_crc
    lea r8, [rip + ac3_crc_table]
    lea r9, [rcx + rdx]
    add rcx, 2
    xor eax, eax
.Lac3_crc_byte:
    cmp rcx, r9
    jae .Lac3_crc_done
    movzx edx, byte ptr [rcx]
    inc rcx
    mov r10d, eax
    shr r10d, 8
    xor edx, r10d
    and edx, 0xff
    shl eax, 8
    movzx edx, word ptr [r8 + rdx*2]
    xor eax, edx
    and eax, 0xffff
    jmp .Lac3_crc_byte
.Lac3_crc_done:
    ret
ENDFN ac3_crc

# RCX=mapped start, RDX=end -> EAX=1 with every frame listed as a track
# packet and the decoder opened. A leading ID3v2 tag, a trailing ID3v1 tag
# and a truncated final frame are skipped.
FN ac3_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    call ac3_header
    test eax, eax
    jnz .Lac3_open_first
    cmp ecx, 11
    jb .Lac3_open_bad
    cmp ecx, 16
    ja .Lac3_open_bad
    mov [rip + decode_error], r11d
    jmp .Lac3_open_bad
.Lac3_open_first:
    mov r12d, edx                         # stream key
    mov ecx, TK_AC3
    call track_begin
    test eax, eax
    jz .Lac3_open_bad
.Lac3_open_frame:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jb .Lac3_open_frames_done
    mov rcx, [rip + ogg_cancel_ptr]
    test rcx, rcx
    jz .Lac3_open_continue
    cmp dword ptr [rcx], 0
    jne .Lac3_open_bad
.Lac3_open_continue:
    cmp rax, 128
    jne .Lac3_open_header
    cmp word ptr [rsi], 0x4154            # trailing ID3v1 "TAG"
    jne .Lac3_open_header
    cmp byte ptr [rsi + 2], 'G'
    je .Lac3_open_frames_done
.Lac3_open_header:
    mov rcx, rsi
    mov rdx, rax
    mov rbx, rax
    call ac3_header
    test eax, eax
    jnz .Lac3_open_header_valid
    cmp ecx, 11
    jb .Lac3_open_bad
    cmp ecx, 16
    ja .Lac3_open_bad
    mov [rip + decode_error], r11d
    jmp .Lac3_open_bad
.Lac3_open_header_valid:
    cmp edx, r12d
    jne .Lac3_open_bad
    cmp rax, rbx
    ja .Lac3_open_frames_done             # truncated final frame
    mov rbx, rax
    mov rcx, rsi
    mov edx, ebx
    call track_add
    test eax, eax
    jz .Lac3_open_bad
    add rsi, rbx
    jmp .Lac3_open_frame
.Lac3_open_frames_done:
    mov qword ptr [rip + track_config], 0
    mov dword ptr [rip + track_config_bytes], 0
    call track_finish
    test eax, eax
    jz .Lac3_open_bad
    mov eax, CODEC_AC3
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_open_codec
    mov eax, CODEC_EAC3
.Lac3_open_codec:
    mov [rip + codec_kind], eax
    mov eax, 1
    jmp .Lac3_open_return
.Lac3_open_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lac3_open_failed
    mov dword ptr [rip + decode_error], AC3_MALFORMED
.Lac3_open_failed:
    xor eax, eax
.Lac3_open_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_open

# RCX=configuration (unused), EDX=its bytes, R8=first packet, R9D=its bytes
# -> EAX=1 with the format published and the decoder reset.
FN ac3_track_open
    push rbx
    sub rsp, 32
    mov rcx, r8
    mov edx, r9d
    call ac3_header
    test eax, eax
    jnz .Lac3_track_open_supported
    mov eax, AC3_MALFORMED
    cmp ecx, 11
    jb .Lac3_track_open_fail
    cmp ecx, 16
    ja .Lac3_track_open_fail
    mov eax, r11d                        # unsupported or malformed E-AC-3
    jmp .Lac3_track_open_fail
.Lac3_track_open_supported:
    mov [rip + ac3_key], edx
    mov eax, edx
    shr eax, 8
    mov [rip + ac3_enhanced], eax
    mov eax, edx
    and eax, 3
    mov [rip + ac3_fscod], eax
    lea rcx, [rip + ac3_rates]
    mov r8d, [rcx + rax*4]
    mov ecx, edx
    shr ecx, 2
    and ecx, 3
    mov [rip + ac3_shift], ecx
    shr r8d, cl
    mov [rip + sample_rate], r8d
    mov eax, edx
    shr eax, 4
    and eax, 7
    mov [rip + ac3_acmod], eax
    lea rcx, [rip + ac3_channel_counts]
    movzx ecx, byte ptr [rcx + rax]
    mov [rip + ac3_nf], ecx
    mov r8d, edx
    shr r8d, 7
    and r8d, 1
    mov [rip + ac3_lfe], r8d
    lea r9d, [rcx + r8]
    mov [rip + ac3_channels], r9d
    mov [rip + source_channels], r9d
    mov dword ptr [rip + source_bits], 0
    lea r9d, [rcx + 1]
    test r8d, r8d
    jnz .Lac3_track_open_lfe
    mov r9d, -1
.Lac3_track_open_lfe:
    mov [rip + ac3_lfe_ch], r9d
    lea rcx, [rip + ac3_masks]
    mov ecx, [rcx + rax*4]
    lea r9d, [rcx + 8]
    test r8d, r8d
    cmovnz ecx, r9d
    mov [rip + pcm_channel_mask], ecx
    shl eax, 4
    shl r8d, 3
    add eax, r8d
    lea rcx, [rip + ac3_wave_index]
    add rcx, rax
    mov [rip + ac3_wave], rcx
    mov dword ptr [rip + pcm_mask_seen], 1
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + pcm_mix], 0
    call pcm_build_mix
    test eax, eax
    mov eax, AC3_MALFORMED
    jz .Lac3_track_open_fail
    # FFmpeg's dither generator, seeded once per stream.
    lea rcx, [rip + ac3_lfg_init]
    lea rdx, [rip + ac3_lfg]
    xor eax, eax
.Lac3_track_open_lfg:
    mov r8d, [rcx + rax*4]
    mov [rdx + rax*4], r8d
    inc eax
    cmp eax, 64
    jb .Lac3_track_open_lfg
    mov dword ptr [rip + ac3_lfg_index], 0
    call ac3_track_reset
    mov eax, 1
    jmp .Lac3_track_open_return
.Lac3_track_open_fail:
    mov [rip + decode_error], eax
    xor eax, eax
.Lac3_track_open_return:
    add rsp, 32
    pop rbx
    ret
ENDFN ac3_track_open

FN ac3_track_close
    mov dword ptr [rip + ac3_key], -1
    ret
ENDFN ac3_track_close

# Clears the overlap, concealment and parameter state (stream start, seeks).
FN ac3_track_reset
    push rdi
    lea rdi, [rip + ac3_state]
    lea rcx, [rip + ac3_state_end]
    sub rcx, rdi
    xor eax, eax
    rep stosb
    pop rdi
    ret
ENDFN ac3_track_reset

# RCX=packet, EDX=bytes -> EAX=256 * blocks per sync frame, or -1 unless the packet
# holds whole frames of this stream.
FN ac3_track_samples
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov edi, edx
    xor ebx, ebx
.Lac3_samples_frame:
    test edi, edi
    jz .Lac3_samples_done
    mov rcx, rsi
    mov edx, edi
    call ac3_header
    test eax, eax
    jnz .Lac3_samples_header_valid
    cmp ecx, 11
    jb .Lac3_samples_bad
    cmp ecx, 16
    ja .Lac3_samples_bad
    mov [rip + decode_error], r11d
    jmp .Lac3_samples_bad
.Lac3_samples_header_valid:
    cmp edx, [rip + ac3_key]
    jne .Lac3_samples_bad
    cmp eax, edi
    ja .Lac3_samples_bad
    add rsi, rax
    sub edi, eax
    shl r11d, 8
    add ebx, r11d
    jc .Lac3_samples_bad
    jmp .Lac3_samples_frame
.Lac3_samples_done:
    mov eax, ebx
    test eax, eax
    jnz .Lac3_samples_return
.Lac3_samples_bad:
    mov eax, -1
.Lac3_samples_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames.
FN ac3_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov edi, edx
    mov r12, r8
    mov [rsp + 36], r9d
    xor ebx, ebx
.Lac3_decode_frame:
    test edi, edi
    jz .Lac3_decode_done
    mov rcx, rsi
    mov edx, edi
    call ac3_header
    test eax, eax
    jz .Lac3_decode_bad
    cmp eax, edi
    ja .Lac3_decode_bad
    cmp edx, [rip + ac3_key]
    jne .Lac3_decode_bad
    mov [rip + ac3_blocks], r11d
    shl r11d, 8
    mov [rip + ac3_frame_samples], r11d
    add r11d, ebx
    jc .Lac3_decode_bad
    cmp r11d, [rsp + 36]
    ja .Lac3_decode_bad
    mov [rsp + 32], eax
    mov rcx, rsi
    mov edx, eax
    call ac3_decode
    test eax, eax
    jz .Lac3_decode_failed
    lea rcx, [r12 + rbx*8]
    call ac3_emit
    mov eax, [rsp + 32]
    add rsi, rax
    sub edi, eax
    add ebx, [rip + ac3_frame_samples]
    jmp .Lac3_decode_frame
.Lac3_decode_bad:
    mov dword ptr [rip + decode_error], AC3_MALFORMED
.Lac3_decode_failed:
    xor ebx, ebx
.Lac3_decode_done:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_track_decode

# RCX=stereo float output: the decoded frame mixed to stereo.
LOCALFN ac3_emit
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    lea rsi, [rip + ac3_pcm]
    mov ebx, [rip + ac3_channels]
    xor ecx, ecx
    cmp dword ptr [rip + pcm_mix], 0
    jne .Lac3_emit_mix
    cmp ebx, 2
    je .Lac3_emit_stereo
.Lac3_emit_mono:
    movss xmm0, [rsi + rcx*4]
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm0
    inc ecx
    cmp ecx, [rip + ac3_frame_samples]
    jb .Lac3_emit_mono
    jmp .Lac3_emit_done
.Lac3_emit_stereo:
    movss xmm0, [rsi + rcx*4]
    movss xmm1, [rsi + rcx*4 + AC3_FRAME*4]
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    cmp ecx, [rip + ac3_frame_samples]
    jb .Lac3_emit_stereo
    jmp .Lac3_emit_done
.Lac3_emit_mix:
    mov r8, [rip + ac3_wave]
    lea r9, [rip + pcm_mix_coeff]
.Lac3_emit_frame:
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    xor edx, edx
    lea r10, [rsi + rcx*4]
.Lac3_emit_channel:
    movzx eax, byte ptr [r8 + rdx]
    shl eax, 4
    cvtss2sd xmm2, [r10]
    movsd xmm3, xmm2
    mulsd xmm2, [r9 + rax]
    mulsd xmm3, [r9 + rax + 8]
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r10, AC3_FRAME*4
    inc edx
    cmp edx, ebx
    jb .Lac3_emit_channel
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    cmp ecx, [rip + ac3_frame_samples]
    jb .Lac3_emit_frame
.Lac3_emit_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_emit

# RCX=frame, EDX=its bytes: decodes ac3_blocks blocks into ac3_pcm. A failed CRC or
# a block that does not decode repeats the previous block for the rest of
# the frame.
LOCALFN ac3_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov ebx, edx
    lea rdi, [rip + ac3_frame]
    mov ecx, ebx
    rep movsb
    xor eax, eax
    mov ecx, 16
    rep stosb
    mov [rip + ac3_bitlimit], ebx
    # CRC over the frame after the sync word must be zero.
    lea rcx, [rip + ac3_frame]
    mov edx, ebx
    call ac3_crc
    xor r12d, r12d
    test eax, eax
    setnz r12b                            # error: conceal the frame
    mov dword ptr [rip + ac3_bitpos], 40
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_decode_parse_bsi
    test r12d, r12d
    jnz .Lac3_decode_bsi_ok
.Lac3_decode_parse_bsi:
    call ac3_bsi
    cmp eax, AC3_UNSUPPORTED
    je .Lac3_decode_unsupported
    test eax, eax
    jnz .Lac3_decode_bsi_ok
    mov r12d, 1
.Lac3_decode_bsi_ok:
    xor r13d, r13d                        # block
.Lac3_decode_block:
    test r12d, r12d
    jnz .Lac3_decode_conceal
    mov ecx, r13d
    call ac3_block
    cmp eax, AC3_UNSUPPORTED
    je .Lac3_decode_unsupported
    test eax, eax
    jnz .Lac3_decode_keep
    mov r12d, 1
.Lac3_decode_conceal:
    # Previous block (zeros before the first) into this block's output.
    xor ecx, ecx
.Lac3_decode_conceal_channel:
    cmp ecx, [rip + ac3_channels]
    jae .Lac3_decode_keep
    imul edx, ecx, AC3_FRAME*4
    lea rdi, [rip + ac3_pcm]
    add rdi, rdx
    mov eax, r13d
    shl eax, 10
    add rdi, rax
    mov edx, ecx
    shl edx, 10
    lea rsi, [rip + ac3_last]
    add rsi, rdx
    xor eax, eax
.Lac3_decode_conceal_value:
    xorps xmm0, xmm0
    cmp dword ptr [rip + ac3_has_last], 0
    je .Lac3_decode_conceal_store
    movss xmm0, [rsi + rax*4]
.Lac3_decode_conceal_store:
    movss [rdi + rax*4], xmm0
    inc eax
    cmp eax, AC3_BLOCK
    jb .Lac3_decode_conceal_value
    inc ecx
    jmp .Lac3_decode_conceal_channel
.Lac3_decode_keep:
    # This block's output becomes the concealment block.
    xor ecx, ecx
.Lac3_decode_keep_channel:
    cmp ecx, [rip + ac3_channels]
    jae .Lac3_decode_next
    imul edx, ecx, AC3_FRAME*4
    lea rsi, [rip + ac3_pcm]
    add rsi, rdx
    mov eax, r13d
    shl eax, 10
    add rsi, rax
    mov edx, ecx
    shl edx, 10
    lea rdi, [rip + ac3_last]
    add rdi, rdx
    push rcx
    mov ecx, AC3_BLOCK
    rep movsd
    pop rcx
    inc ecx
    jmp .Lac3_decode_keep_channel
.Lac3_decode_next:
    mov dword ptr [rip + ac3_has_last], 1
    inc r13d
    cmp r13d, [rip + ac3_blocks]
    jb .Lac3_decode_block
    mov eax, 1
    jmp .Lac3_decode_return
.Lac3_decode_unsupported:
    mov dword ptr [rip + decode_error], AC3_UNSUPPORTED
    xor eax, eax
.Lac3_decode_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_decode

# Bit stream information after the sync information; sets the LFE channel's
# fixed range.
LOCALFN ac3_bsi
    cmp dword ptr [rip + ac3_enhanced], 0
    jne eac3_bsi
    push rbx
    sub rsp, 32
    mov ecx, 5
    call ac3_get
    mov [rip + ac3_bsid], eax
    add dword ptr [rip + ac3_bitpos], 6   # bsmod, acmod
    mov eax, [rip + ac3_acmod]
    xor ecx, ecx
    cmp eax, 2
    jne .Lac3_bsi_mix
    mov ecx, 2                            # dsurmod
    jmp .Lac3_bsi_lfe
.Lac3_bsi_mix:
    test eax, 1
    jz .Lac3_bsi_surround
    cmp eax, 1
    je .Lac3_bsi_surround
    add ecx, 2                            # cmixlev
.Lac3_bsi_surround:
    test eax, 4
    jz .Lac3_bsi_lfe
    add ecx, 2                            # surmixlev
.Lac3_bsi_lfe:
    inc ecx                               # lfeon
    add [rip + ac3_bitpos], ecx
    mov ebx, 1
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Lac3_bsi_program
    mov ebx, 2                            # dual mono: two sets
.Lac3_bsi_program:
    add dword ptr [rip + ac3_bitpos], 5   # dialnorm
    mov ecx, 1
    call ac3_get                          # compre
    shl eax, 3
    add [rip + ac3_bitpos], eax
    mov ecx, 1
    call ac3_get                          # langcode
    shl eax, 3
    add [rip + ac3_bitpos], eax
    mov ecx, 1
    call ac3_get                          # audprodie
    imul eax, eax, 7
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Lac3_bsi_program
    add dword ptr [rip + ac3_bitpos], 2   # copyrightb, origbs
    mov ebx, 2                            # timecodes, or the bsid 6 extensions
.Lac3_bsi_extension:
    mov ecx, 1
    call ac3_get
    imul eax, eax, 14
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Lac3_bsi_extension
    mov ecx, 1
    call ac3_get                          # addbsie
    test eax, eax
    jz .Lac3_bsi_done
    mov ecx, 6
    call ac3_get
    inc eax
    shl eax, 3
    add [rip + ac3_bitpos], eax
.Lac3_bsi_done:
    mov ecx, [rip + ac3_lfe_ch]
    test ecx, ecx
    js .Lac3_bsi_return
    lea rax, [rip + ac3_start]
    mov dword ptr [rax + rcx*4], 0
    lea rax, [rip + ac3_end]
    mov dword ptr [rax + rcx*4], 7
    lea rax, [rip + ac3_ngrps]
    mov dword ptr [rax + rcx*4], 2
    lea rax, [rip + ac3_incpl]
    mov dword ptr [rax + rcx*4], 0
.Lac3_bsi_return:
    mov eax, 1
    add rsp, 32
    pop rbx
    ret
ENDFN ac3_bsi

.include "ac3_block.inc"

.include "eac3.inc"
.include "eac3_spx.inc"
