# Original ISO base media (MP4/M4A/MOV) audio demuxer. MIT, see LICENSE.
# Reference: ISO/IEC 14496-12 and 14496-14, QuickTime File Format; codec
# mappings: ISO/IEC 14496-3 (esds), Opus in ISOBMFF (dOps), FLAC in
# ISOBMFF (dfLa), Apple Lossless ('alac' box), ISO/IEC 23003-5 (pcmC).
# Selects the first enabled sound track with a supported sample entry (or
# the sound track that track_choice numbers, in trak order) and
# lists its samples as track packets, from the sample tables (stsz/stz2,
# stsc, stco/co64) or from movie fragments (moof/traf/tfhd/trun). The
# first non-empty edit trims the start and limits the presented duration.
.include "lamp.inc"
.globl mp4_track_id, mp4_config, mp4_config_bytes

.equ BOX_MOOV, 0x766f6f6d
.equ BOX_TRAK, 0x6b617274
.equ BOX_TKHD, 0x64686b74
.equ BOX_MDIA, 0x6169646d
.equ BOX_MDHD, 0x6468646d
.equ BOX_HDLR, 0x726c6468
.equ BOX_MINF, 0x666e696d
.equ BOX_STBL, 0x6c627473
.equ BOX_STSD, 0x64737473
.equ BOX_STSZ, 0x7a737473
.equ BOX_STZ2, 0x327a7473
.equ BOX_STSC, 0x63737473
.equ BOX_STCO, 0x6f637473
.equ BOX_CO64, 0x34366f63
.equ BOX_EDTS, 0x73746465
.equ BOX_ELST, 0x74736c65
.equ BOX_STTS, 0x73747473
.equ BOX_MVHD, 0x6468766d
.equ BOX_MVEX, 0x7865766d
.equ BOX_TREX, 0x78657274
.equ BOX_MOOF, 0x666f6f6d
.equ BOX_TRAF, 0x66617274
.equ BOX_TFHD, 0x64686674
.equ BOX_TRUN, 0x6e757274
.equ BOX_ESDS, 0x73647365
.equ BOX_WAVE, 0x65766177
.equ BOX_DOPS, 0x73704f64
.equ BOX_DFLA, 0x614c6664
.equ BOX_ALAC, 0x63616c61
.equ BOX_PCMC, 0x436d6370
.equ BOX_ENDA, 0x61646e65
.equ SOUN, 0x6e756f73
.equ PCM_PACKET, 4096                 # PCM frames per packet

RODATA
# Sample entry FourCC -> track codec (1 PCM, 2 FLAC, 3 MPEG audio, 5 Opus,
# 6 ALAC, 8 AC-3 (E-AC-3 rejects at open), 255 esds-dependent), PCM bits and flags (1 big-endian, 2 float,
# 4 signed 8-bit; 8 = from the entry; 16 = from lpcm flags; 32 = pcmC).
mp4_formats:
    .ascii "mp4a"
    .byte 255, 0, 0, 0
    .ascii ".mp3"
    .byte 3, 0, 0, 0
    .ascii "Opus"
    .byte 5, 0, 0, 0
    .ascii "fLaC"
    .byte 2, 0, 0, 0
    .ascii "alac"
    .byte 6, 0, 0, 0
    .ascii "ac-3"
    .byte 8, 0, 0, 0
    .ascii "ec-3"
    .byte 8, 0, 0, 0
    .ascii "alaw"
    .byte 1, 8, 8, 64
    .ascii "ulaw"
    .byte 1, 8, 16, 64
    .ascii "ima4"
    .byte 10, 4, 0, 0
    .ascii "agsm"
    .byte 10, 0, 0, 0
    .ascii "sowt"
    .byte 1, 16, 4, 8
    .ascii "twos"
    .byte 1, 16, 5, 8
    .ascii "in24"
    .byte 1, 24, 1, 0
    .ascii "in32"
    .byte 1, 32, 1, 0
    .ascii "fl32"
    .byte 1, 32, 3, 0
    .ascii "fl64"
    .byte 1, 64, 3, 0
    .ascii "raw "
    .byte 1, 8, 0, 0
    .ascii "lpcm"
    .byte 1, 0, 16, 0
    .ascii "ipcm"
    .byte 1, 0, 32, 0
    .ascii "fpcm"
    .byte 1, 0, 34, 0
    .long 0

.data
mp4_track_id: .long 0
mp4_selected: .long 0
mp4_audio_index: .long 0             # sound traks read
mp4_codec: .long 0
mp4_pcm_bits: .long 0
mp4_pcm_flags: .long 0
mp4_channels: .long 0
mp4_rate: .long 0
mp4_movie_scale: .long 0
mp4_media_scale: .long 0
mp4_config: .quad 0
mp4_config_bytes: .long 0
mp4_edit_start: .quad 0             # media units
mp4_edit_duration: .quad 0          # movie units, 0 = none
mp4_edit_found: .long 0
mp4_duration_unknown: .long 0
mp4_media_duration: .quad 0         # sum of sample durations, media units
mp4_trex_duration: .long 0
mp4_trex_index: .long 0
mp4_stsz: .quad 0
mp4_stz2: .long 0
mp4_stsc: .quad 0
mp4_stco: .quad 0
mp4_co64: .long 0
mp4_fragmented: .long 0
mp4_trex_size: .long 0
mp4_begin: .quad 0
mp4_end: .quad 0
mp4_pcm_frame: .long 0
mp4_qt_block: .long 0              # bytes per compressed block
mp4_qt_frames: .long 0             # decoded frames per block
mp4_qt_legacy: .long 0             # stsc/stsz count decoded samples
mp4_opus_head: .zero 19 + 2 + 255
.bss
mp4_candidate: .zero 128            # the sound track being parsed
mp4_adpcm_fmt: .zero 16

.text
# RCX=box, RDX=limit -> EAX=type (0 when malformed), RDX=payload end,
# R8=payload start. Size 0 extends to the limit; size 1 is 64-bit.
LOCALFN mp4_box
    lea rax, [rcx + 8]
    cmp rax, rdx
    ja .Lmp4_box_bad
    mov r9, rdx
    mov r8d, [rcx]
    bswap r8d
    mov eax, [rcx + 4]
    cmp r8d, 1
    je .Lmp4_box_large
    test r8d, r8d
    jz .Lmp4_box_rest
    cmp r8d, 8
    jb .Lmp4_box_bad
    lea rdx, [rcx + r8]
    lea r8, [rcx + 8]
    jmp .Lmp4_box_check
.Lmp4_box_large:
    lea r8, [rcx + 16]
    cmp r8, r9
    ja .Lmp4_box_bad
    mov rdx, [rcx + 8]
    bswap rdx
    cmp rdx, 16
    jb .Lmp4_box_bad
    mov r10, r9
    sub r10, rcx
    cmp rdx, r10
    ja .Lmp4_box_bad
    add rdx, rcx
    jmp .Lmp4_box_done
.Lmp4_box_rest:
    mov rdx, r9
    lea r8, [rcx + 8]
    jmp .Lmp4_box_done
.Lmp4_box_check:
    cmp rdx, r9
    ja .Lmp4_box_bad
    cmp rdx, rcx
    jb .Lmp4_box_bad
.Lmp4_box_done:
    test eax, eax
    jz .Lmp4_box_bad
    ret
.Lmp4_box_bad:
    xor eax, eax
    ret
ENDFN mp4_box

# RCX=parent payload, RDX=end, R8D=type -> RAX=child payload (0 if absent),
# RDX=child end. The first child of that type.
LOCALFN mp4_child
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ebx, r8d
.Lmp4_child_next:
    cmp rsi, rdi
    jae .Lmp4_child_none
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test eax, eax
    jz .Lmp4_child_none
    mov rsi, rdx
    cmp eax, ebx
    jne .Lmp4_child_next
    mov rax, r8
    jmp .Lmp4_child_return
.Lmp4_child_none:
    xor eax, eax
.Lmp4_child_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_child

# MPEG-4 descriptor length: RCX=cursor, RDX=end -> RAX=length, RCX advanced;
# RAX=-1 when malformed. Up to four 7-bit groups.
LOCALFN mp4_descriptor_length
    xor eax, eax
    mov r8d, 4
.Lmp4_length_byte:
    cmp rcx, rdx
    jae .Lmp4_length_bad
    movzx r9d, byte ptr [rcx]
    inc rcx
    shl rax, 7
    mov r10d, r9d
    and r10d, 0x7f
    or rax, r10
    test r9d, 0x80
    jz .Lmp4_length_done
    dec r8d
    jnz .Lmp4_length_byte
.Lmp4_length_bad:
    mov rax, -1
.Lmp4_length_done:
    ret
ENDFN mp4_descriptor_length

# esds payload (RCX, end RDX) -> EAX=track codec: 3 for MPEG-1/2 audio
# object types, 7 for MPEG-4 audio and MPEG-2 AAC LC (configuration from the
# DecoderSpecificInfo in mp4_config); 0 otherwise.
LOCALFN mp4_esds
    add rcx, 4                            # FullBox version and flags
    jmp mp4_es_descriptor
ENDFN mp4_esds

# ES_Descriptor (RCX, end RDX) -> EAX as mp4_esds (CAF kuki chunks hold one).
FN mp4_es_descriptor
    push rbx
    sub rsp, 32
    cmp rcx, rdx
    jae .Lmp4_esds_none
    cmp byte ptr [rcx], 3                 # ES_Descriptor
    jne .Lmp4_esds_none
    inc rcx
    call mp4_descriptor_length
    cmp rax, -1
    je .Lmp4_esds_none
    lea rax, [rcx + 3]
    cmp rax, rdx
    ja .Lmp4_esds_none
    movzx ebx, byte ptr [rcx + 2]         # flags
    add rcx, 3
    test ebx, 0x80
    jz .Lmp4_esds_url
    add rcx, 2
.Lmp4_esds_url:
    test ebx, 0x40
    jz .Lmp4_esds_ocr
    cmp rcx, rdx
    jae .Lmp4_esds_none
    movzx eax, byte ptr [rcx]
    lea rcx, [rcx + rax + 1]
.Lmp4_esds_ocr:
    test ebx, 0x20
    jz .Lmp4_esds_config
    add rcx, 2
.Lmp4_esds_config:
    cmp rcx, rdx
    jae .Lmp4_esds_none
    cmp byte ptr [rcx], 4                 # DecoderConfigDescriptor
    jne .Lmp4_esds_none
    inc rcx
    call mp4_descriptor_length
    cmp rax, -1
    je .Lmp4_esds_none
    cmp rcx, rdx
    jae .Lmp4_esds_none
    movzx eax, byte ptr [rcx]             # objectTypeIndication
    cmp eax, 0x69                         # MPEG-2 audio (lower rates)
    je .Lmp4_esds_mpa
    cmp eax, 0x6b                         # MPEG-1 audio
    je .Lmp4_esds_mpa
    cmp eax, 0x40                         # MPEG-4 audio
    je .Lmp4_esds_aac
    cmp eax, 0x67                         # MPEG-2 AAC LC
    je .Lmp4_esds_aac
.Lmp4_esds_none:
    xor eax, eax
    jmp .Lmp4_esds_return
.Lmp4_esds_mpa:
    mov eax, 3
    jmp .Lmp4_esds_return
.Lmp4_esds_aac:
    # DecoderSpecificInfo after the 13 fixed bytes: the AudioSpecificConfig.
    lea rax, [rcx + 14]
    cmp rax, rdx
    ja .Lmp4_esds_none
    cmp byte ptr [rcx + 13], 5
    jne .Lmp4_esds_none
    add rcx, 14
    call mp4_descriptor_length
    cmp rax, -1
    je .Lmp4_esds_none
    lea r8, [rcx + rax]
    cmp r8, rdx
    ja .Lmp4_esds_none
    mov [rip + mp4_config], rcx
    mov [rip + mp4_config_bytes], eax
    mov eax, 7
.Lmp4_esds_return:
    add rsp, 32
    pop rbx
    ret
ENDFN mp4_es_descriptor

# The first sample entry of stsd (RCX payload, RDX end) -> EAX=1 when it is
# a supported audio format; sets the codec, configuration and PCM layout.
LOCALFN mp4_sample_entry
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov dword ptr [rip + mp4_codec], 0
    mov dword ptr [rip + mp4_qt_block], 0
    mov dword ptr [rip + mp4_qt_legacy], 0
    mov qword ptr [rip + mp4_config], 0
    mov dword ptr [rip + mp4_config_bytes], 0
    lea rax, [rcx + 8]
    cmp rax, rdx
    ja .Lmp4_entry_none
    cmp dword ptr [rcx + 4], 0            # entry count
    je .Lmp4_entry_none
    lea rcx, [rcx + 8]
    call mp4_box                          # the first entry
    test eax, eax
    jz .Lmp4_entry_none
    mov rsi, rcx                          # entry start (header included)
    mov rdi, rdx                          # entry end
    mov ebx, eax                          # FourCC
    lea rax, [rsi + 36]
    cmp rax, rdi
    ja .Lmp4_entry_none
    lea r9, [rip + mp4_formats]
.Lmp4_entry_format:
    mov eax, [r9]
    test eax, eax
    jz .Lmp4_entry_none
    cmp eax, ebx
    je .Lmp4_entry_known
    add r9, 8
    jmp .Lmp4_entry_format
.Lmp4_entry_known:
    movzx eax, byte ptr [r9 + 4]
    mov [rip + mp4_codec], eax
    movzx eax, byte ptr [r9 + 5]
    mov [rip + mp4_pcm_bits], eax
    movzx r12d, byte ptr [r9 + 6]         # flags and how to complete them
    movzx r13d, byte ptr [r9 + 7]
    # AudioSampleEntry: version selects where child boxes begin.
    movzx eax, word ptr [rsi + 16]
    rol ax, 8
    movzx ecx, word ptr [rsi + 24]
    rol cx, 8
    mov [rip + mp4_channels], ecx
    movzx ecx, word ptr [rsi + 32]
    rol cx, 8
    mov [rip + mp4_rate], ecx             # integer part of 16.16
    lea r8, [rsi + 36]
    cmp eax, 1
    jne .Lmp4_entry_v2
    lea r8, [rsi + 52]
    jmp .Lmp4_entry_children
.Lmp4_entry_v2:
    cmp eax, 2
    jne .Lmp4_entry_children
    lea r8, [rsi + 72]
    cmp r8, rdi
    ja .Lmp4_entry_none
    mov rax, [rsi + 40]
    bswap rax
    movq xmm0, rax
    cvttsd2si rax, xmm0
    mov [rip + mp4_rate], eax
    mov eax, [rsi + 48]
    bswap eax
    mov [rip + mp4_channels], eax
    test r12d, 16                         # lpcm: bits and flags from the entry
    jz .Lmp4_entry_children
    mov eax, [rsi + 56]
    bswap eax
    mov [rip + mp4_pcm_bits], eax
    mov eax, [rsi + 60]
    bswap eax
    xor r12d, r12d
    test eax, 1
    jz .Lmp4_lpcm_order
    or r12d, 2                            # float
.Lmp4_lpcm_order:
    test eax, 2
    jz .Lmp4_lpcm_signed
    or r12d, 1                            # big-endian
.Lmp4_lpcm_signed:
    test eax, 4
    jz .Lmp4_entry_children
    or r12d, 4                            # signed (matters for 8-bit)
.Lmp4_entry_children:
    cmp r8, rdi
    ja .Lmp4_entry_none
    mov [rsp + 24], r8
    mov eax, [rip + mp4_codec]
    cmp eax, 255
    je .Lmp4_entry_esds
    cmp eax, 5
    je .Lmp4_entry_opus
    cmp eax, 2
    je .Lmp4_entry_flac
    cmp eax, 6
    je .Lmp4_entry_alac
    cmp eax, 1
    je .Lmp4_entry_pcm
    cmp eax, 10
    je .Lmp4_entry_adpcm
    jmp .Lmp4_entry_ok                    # MPEG audio needs no configuration
.Lmp4_entry_adpcm:
    mov eax, [rip + mp4_channels]
    cmp eax, 1
    jb .Lmp4_entry_none
    cmp eax, 8
    ja .Lmp4_entry_none
    lea rcx, [rip + mp4_adpcm_fmt]
    mov [rcx + 2], ax
    imul eax, eax, 34
    mov word ptr [rcx], 0x4d49            # QuickTime IMA
    mov word ptr [rcx + 14], 4
    mov dword ptr [rip + mp4_qt_frames], 64
    cmp ebx, 0x6d736761                   # agsm: standard 33-byte GSM
    jne .Lmp4_entry_adpcm_block
    cmp dword ptr [rip + mp4_channels], 1
    jne .Lmp4_entry_none
    mov word ptr [rcx], 0x5347
    mov word ptr [rcx + 14], 0
    mov dword ptr [rip + mp4_qt_frames], 160
    mov eax, 33
.Lmp4_entry_adpcm_block:
    mov [rip + mp4_qt_block], eax
    imul eax, eax, 20                     # bounded groups; GSM seek primer
    mov [rcx + 12], ax
    mov eax, [rip + mp4_rate]
    mov [rcx + 4], eax
    mov [rip + mp4_config], rcx
    mov dword ptr [rip + mp4_config_bytes], 16
    jmp .Lmp4_entry_ok
.Lmp4_entry_esds:
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_ESDS
    call mp4_child
    test rax, rax
    jnz .Lmp4_entry_esds_found
    mov rcx, [rsp + 24]                   # QuickTime: inside 'wave'
    mov rdx, rdi
    mov r8d, BOX_WAVE
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
    mov rcx, rax
    mov r8d, BOX_ESDS
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
.Lmp4_entry_esds_found:
    mov rcx, rax
    call mp4_esds
    mov [rip + mp4_codec], eax
    test eax, eax
    jz .Lmp4_entry_none
    jmp .Lmp4_entry_ok
.Lmp4_entry_opus:
    # dOps (big-endian) becomes an OpusHead (little-endian).
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_DOPS
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
    mov rcx, rdx
    sub rcx, rax                          # dOps bytes
    cmp rcx, 11
    jb .Lmp4_entry_none
    cmp byte ptr [rax], 0
    jne .Lmp4_entry_none
    lea rdx, [rip + mp4_opus_head]
    mov r8, 0x646165487375704f
    mov [rdx], r8
    mov byte ptr [rdx + 8], 1
    movzx r8d, byte ptr [rax + 1]         # channels
    mov [rdx + 9], r8b
    movzx r9d, word ptr [rax + 2]
    rol r9w, 8
    mov [rdx + 10], r9w                   # pre-skip
    mov r9d, [rax + 4]
    bswap r9d
    mov [rdx + 12], r9d                   # input rate
    movzx r9d, word ptr [rax + 8]
    rol r9w, 8
    mov [rdx + 16], r9w                   # gain
    movzx r9d, byte ptr [rax + 10]
    mov [rdx + 18], r9b                   # mapping family
    mov r10d, 19
    test r9d, r9d
    jz .Lmp4_opus_done
    lea r11, [r8 + 13]                    # family, streams, coupled, map
    cmp rcx, r11
    jb .Lmp4_entry_none
    lea r10d, [r8 + 21]
    xor r11d, r11d
.Lmp4_opus_map:
    lea r9d, [r8 + 2]
    cmp r11d, r9d
    jae .Lmp4_opus_done
    movzx r9d, byte ptr [rax + r11 + 11]
    mov [rdx + r11 + 19], r9b
    inc r11d
    jmp .Lmp4_opus_map
.Lmp4_opus_done:
    mov [rip + mp4_config], rdx
    mov [rip + mp4_config_bytes], r10d
    jmp .Lmp4_entry_ok
.Lmp4_entry_flac:
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_DFLA
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
    add rax, 4                            # FullBox version and flags
    cmp rax, rdx
    ja .Lmp4_entry_none
    mov [rip + mp4_config], rax
    sub rdx, rax
    mov [rip + mp4_config_bytes], edx
    jmp .Lmp4_entry_ok
.Lmp4_entry_alac:
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_ALAC
    call mp4_child
    test rax, rax
    jnz .Lmp4_entry_alac_found
    mov rcx, [rsp + 24]                   # QuickTime: inside 'wave'
    mov rdx, rdi
    mov r8d, BOX_WAVE
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
    mov rcx, rax
    mov r8d, BOX_ALAC
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
.Lmp4_entry_alac_found:
    mov [rip + mp4_config], rax
    sub rdx, rax
    mov [rip + mp4_config_bytes], edx
    jmp .Lmp4_entry_ok
.Lmp4_entry_pcm:
    test r13d, 64                         # G.711 has one code per channel
    jz .Lmp4_entry_pcm_linear
    mov [rip + mp4_pcm_flags], r12d
    mov eax, [rip + mp4_channels]
    test eax, eax
    jz .Lmp4_entry_none
    mov [rip + mp4_pcm_frame], eax
    jmp .Lmp4_entry_ok
.Lmp4_entry_pcm_linear:
    test r12d, 32                         # ipcm/fpcm: pcmC gives order and size
    jz .Lmp4_pcm_quicktime
    and r12d, 2
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_PCMC
    call mp4_child
    test rax, rax
    jz .Lmp4_entry_none
    lea rcx, [rax + 6]
    cmp rcx, rdx
    ja .Lmp4_entry_none
    movzx ecx, byte ptr [rax + 5]
    mov [rip + mp4_pcm_bits], ecx
    test byte ptr [rax + 4], 1
    jnz .Lmp4_pcm_flags
    or r12d, 1                            # big-endian unless flagged little
    jmp .Lmp4_pcm_flags
.Lmp4_pcm_quicktime:
    test r13d, 8                          # twos/sowt: 8 or 16 bits per the entry
    jz .Lmp4_pcm_enda
    movzx ecx, word ptr [rsi + 26]
    rol cx, 8
    cmp ecx, 8
    jne .Lmp4_pcm_enda
    mov dword ptr [rip + mp4_pcm_bits], 8
.Lmp4_pcm_enda:
    # QuickTime 'enda' (inside 'wave') selects little-endian samples.
    test r12d, 1
    jz .Lmp4_pcm_flags
    mov rcx, r8
    mov rdx, rdi
    mov r8d, BOX_WAVE
    call mp4_child
    test rax, rax
    jz .Lmp4_pcm_flags
    mov rcx, rax
    mov r8d, BOX_ENDA
    call mp4_child
    test rax, rax
    jz .Lmp4_pcm_flags
    lea rcx, [rax + 2]
    cmp rcx, rdx
    ja .Lmp4_entry_none
    cmp word ptr [rax], 0x0100            # big-endian 1: little-endian data
    jne .Lmp4_pcm_flags
    and r12d, -2
.Lmp4_pcm_flags:
    and r12d, 7
    mov [rip + mp4_pcm_flags], r12d
    mov eax, [rip + mp4_pcm_bits]
    shr eax, 3
    imul eax, [rip + mp4_channels]
    test eax, eax
    jz .Lmp4_entry_none
    mov [rip + mp4_pcm_frame], eax
.Lmp4_entry_ok:
    mov eax, 1
    jmp .Lmp4_entry_return
.Lmp4_entry_none:
    mov dword ptr [rip + mp4_codec], 0
    xor eax, eax
.Lmp4_entry_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_sample_entry

# One trak (RCX payload, RDX end). Selects it when it is the first enabled
# sound track with a supported sample entry. EAX=0 only when malformed.
LOCALFN mp4_trak
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    cmp dword ptr [rip + mp4_selected], 0
    jne .Lmp4_trak_ok
    # Track header: enabled flag and track ID.
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, BOX_TKHD
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    lea rcx, [rax + 24]
    cmp rcx, rdx
    ja .Lmp4_trak_bad
    test byte ptr [rax + 3], 1
    jnz .Lmp4_trak_enabled
    cmp dword ptr [rip + track_choice], 0
    je .Lmp4_trak_ok                      # disabled (a chosen track may be)
.Lmp4_trak_enabled:
    mov ecx, [rax + 12]
    cmp byte ptr [rax], 1
    jne .Lmp4_trak_id
    mov ecx, [rax + 20]
.Lmp4_trak_id:
    bswap ecx
    mov [rip + mp4_track_id], ecx
    # Media: handler, timescale and the sample tables.
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, BOX_MDIA
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    mov r12, rax
    mov r13, rdx
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_HDLR
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    lea rcx, [rax + 12]
    cmp rcx, rdx
    ja .Lmp4_trak_bad
    cmp dword ptr [rax + 8], SOUN
    jne .Lmp4_trak_ok
    inc dword ptr [rip + mp4_audio_index]
    mov eax, [rip + track_choice]
    test eax, eax
    jz .Lmp4_trak_sound
    cmp eax, [rip + mp4_audio_index]
    jne .Lmp4_trak_ok
    mov dword ptr [rip + track_choice_used], 1
.Lmp4_trak_sound:
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_MDHD
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    lea rcx, [rax + 24]
    cmp rcx, rdx
    ja .Lmp4_trak_bad
    mov ecx, [rax + 12]
    cmp byte ptr [rax], 1
    jne .Lmp4_trak_scale
    mov ecx, [rax + 20]
.Lmp4_trak_scale:
    bswap ecx
    test ecx, ecx
    jz .Lmp4_trak_bad
    mov [rip + mp4_media_scale], ecx
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_MINF
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    mov rcx, rax
    mov r8d, BOX_STBL
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    mov r12, rax
    mov r13, rdx
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STSD
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_bad
    mov rcx, rax
    call mp4_sample_entry
    test eax, eax
    jz .Lmp4_trak_ok                      # unsupported format: keep looking
    # Sample tables; fragmented files may have empty ones.
    mov qword ptr [rip + mp4_stsz], 0
    mov qword ptr [rip + mp4_stsc], 0
    mov qword ptr [rip + mp4_stco], 0
    mov dword ptr [rip + mp4_stz2], 0
    mov dword ptr [rip + mp4_co64], 0
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STSZ
    call mp4_child
    test rax, rax
    jnz .Lmp4_trak_sizes
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STZ2
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_chunks
    mov dword ptr [rip + mp4_stz2], 1
.Lmp4_trak_sizes:
    mov [rip + mp4_stsz], rax
    mov [rip + mp4_stsz_end], rdx
.Lmp4_trak_chunks:
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STSC
    call mp4_child
    mov [rip + mp4_stsc], rax
    mov [rip + mp4_stsc_end], rdx
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STCO
    call mp4_child
    test rax, rax
    jnz .Lmp4_trak_offsets
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_CO64
    call mp4_child
    mov dword ptr [rip + mp4_co64], 1
.Lmp4_trak_offsets:
    mov [rip + mp4_stco], rax
    mov [rip + mp4_stco_end], rdx
    # Media duration: the stts deltas, when they cover every sample.
    mov qword ptr [rip + mp4_media_duration], 0
    mov dword ptr [rip + mp4_duration_unknown], 0
    mov rcx, r12
    mov rdx, r13
    mov r8d, BOX_STTS
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_stts_done
    lea rcx, [rax + 8]
    cmp rcx, rdx
    ja .Lmp4_trak_bad
    mov r8d, [rax + 4]
    bswap r8d                             # entries
    xor r9d, r9d                          # samples covered
    xor r10d, r10d                        # duration
.Lmp4_trak_stts:
    test r8d, r8d
    jz .Lmp4_trak_stts_end
    dec r8d
    lea r11, [rcx + 8]
    cmp r11, rdx
    ja .Lmp4_trak_bad
    mov eax, [rcx]
    bswap eax                             # count
    mov r11d, [rcx + 4]
    bswap r11d                            # delta
    add r9, rax
    imul rax, r11
    add r10, rax
    jc .Lmp4_trak_stts_unknown
    add rcx, 8
    jmp .Lmp4_trak_stts
.Lmp4_trak_stts_end:
    mov rax, [rip + mp4_stsz]
    test rax, rax
    jz .Lmp4_trak_stts_done
    mov eax, [rax + 8]
    bswap eax                             # sample count
    cmp r9, rax
    jne .Lmp4_trak_stts_unknown
    mov [rip + mp4_media_duration], r10
    jmp .Lmp4_trak_stts_done
.Lmp4_trak_stts_unknown:
    mov dword ptr [rip + mp4_duration_unknown], 1
.Lmp4_trak_stts_done:
    # Edit list: the first non-empty edit.
    mov qword ptr [rip + mp4_edit_start], 0
    mov qword ptr [rip + mp4_edit_duration], 0
    mov dword ptr [rip + mp4_edit_found], 0
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, BOX_EDTS
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_selected
    mov rcx, rax
    mov r8d, BOX_ELST
    call mp4_child
    test rax, rax
    jz .Lmp4_trak_selected
    lea rcx, [rax + 8]
    cmp rcx, rdx
    ja .Lmp4_trak_bad
    movzx r8d, byte ptr [rax]             # version
    mov r9d, [rax + 4]
    bswap r9d                             # entries
.Lmp4_trak_edit:
    test r9d, r9d
    jz .Lmp4_trak_selected
    dec r9d
    test r8d, r8d
    jnz .Lmp4_trak_edit64
    lea r10, [rcx + 12]
    cmp r10, rdx
    ja .Lmp4_trak_bad
    mov eax, [rcx]
    bswap eax
    mov r11d, [rcx + 4]
    bswap r11d
    movsxd r11, r11d
    mov rcx, r10
    jmp .Lmp4_trak_edit_entry
.Lmp4_trak_edit64:
    lea r10, [rcx + 20]
    cmp r10, rdx
    ja .Lmp4_trak_bad
    mov rax, [rcx]
    bswap rax
    mov r11, [rcx + 8]
    bswap r11
    mov rcx, r10
.Lmp4_trak_edit_entry:
    cmp r11, -1
    je .Lmp4_trak_edit                    # empty edit: no gap is inserted
    test r11, r11
    js .Lmp4_trak_bad
    mov [rip + mp4_edit_start], r11
    mov [rip + mp4_edit_duration], rax
    mov dword ptr [rip + mp4_edit_found], 1
.Lmp4_trak_selected:
    mov dword ptr [rip + mp4_selected], 1
.Lmp4_trak_ok:
    mov eax, 1
    jmp .Lmp4_trak_return
.Lmp4_trak_bad:
    xor eax, eax
.Lmp4_trak_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_trak

# Adds a packet; PCM packets that continue the previous one in the file are
# merged up to PCM_PACKET frames. RCX=data, EDX=bytes -> EAX=1.
LOCALFN mp4_packet
    lea rax, [rcx + rdx]
    cmp rax, [rip + mp4_end]
    ja .Lmp4_packet_bad
    cmp rcx, [rip + mp4_begin]
    jb .Lmp4_packet_bad
    cmp dword ptr [rip + mp4_codec], 1
    je .Lmp4_packet_pcm
    cmp dword ptr [rip + mp4_codec], 10
    jne track_add
    mov r8d, [rip + mp4_qt_block]
    imul r8d, r8d, 20
    jmp track_append
.Lmp4_packet_pcm:
    mov r8d, [rip + mp4_pcm_frame]
    imul r8d, r8d, PCM_PACKET
    jmp track_append
.Lmp4_packet_bad:
    xor eax, eax
    ret
ENDFN mp4_packet

# Sample tables -> packets. EAX=1 on success.
LOCALFN mp4_sample_tables
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rax, [rip + mp4_stsz]
    test rax, rax
    jz .Lmp4_tables_bad
    cmp qword ptr [rip + mp4_stsc], 0
    je .Lmp4_tables_bad
    cmp qword ptr [rip + mp4_stco], 0
    je .Lmp4_tables_bad
    # Sizes: constant, a 32-bit table, or stz2 fields of 4/8/16 bits.
    lea rcx, [rax + 12]
    cmp rcx, [rip + mp4_stsz_end]
    ja .Lmp4_tables_bad
    mov ecx, [rax + 8]
    bswap ecx
    mov [rsp + 32], ecx                   # sample count
    mov ecx, [rax + 4]
    bswap ecx                             # constant size, or stz2 field size
    cmp dword ptr [rip + mp4_stz2], 0
    je .Lmp4_tables_size
    and ecx, 0xff
    cmp ecx, 4
    je .Lmp4_tables_field
    cmp ecx, 8
    je .Lmp4_tables_field
    cmp ecx, 16
    jne .Lmp4_tables_bad
.Lmp4_tables_field:
    mov [rsp + 36], ecx
    mov dword ptr [rsp + 40], 0
    jmp .Lmp4_tables_size_checked
.Lmp4_tables_size:
    mov [rsp + 40], ecx                   # constant size (0 = table)
    mov dword ptr [rsp + 36], 32
.Lmp4_tables_size_checked:
    # Old QuickTime sound tables count decoded samples, not blocks. The
    # flag lives outside the stack's per-packet size temporary at +44.
    mov dword ptr [rip + mp4_qt_legacy], 0
    cmp dword ptr [rip + mp4_codec], 10
    jne .Lmp4_tables_size_mode
    cmp dword ptr [rip + mp4_stz2], 0
    jne .Lmp4_tables_size_mode
    cmp dword ptr [rsp + 40], 1
    jne .Lmp4_tables_size_mode
    mov dword ptr [rip + mp4_qt_legacy], 1
.Lmp4_tables_size_mode:
    cmp dword ptr [rsp + 40], 0
    jne .Lmp4_tables_counts
    # The table must hold every sample.
    mov eax, [rsp + 32]
    imul rax, rax, 1
    mov ecx, [rsp + 36]
    imul rax, rcx
    add rax, 7
    shr rax, 3
    mov rcx, [rip + mp4_stsz]
    lea rcx, [rcx + rax + 12]
    cmp rcx, [rip + mp4_stsz_end]
    ja .Lmp4_tables_bad
.Lmp4_tables_counts:
    mov rax, [rip + mp4_stsc]
    lea rcx, [rax + 8]
    cmp rcx, [rip + mp4_stsc_end]
    ja .Lmp4_tables_bad
    mov r14d, [rax + 4]
    bswap r14d                            # stsc entries
    test r14d, r14d
    jz .Lmp4_tables_bad
    lea rcx, [rax + r14*8 + 8]
    lea rcx, [rcx + r14*4]
    cmp rcx, [rip + mp4_stsc_end]
    ja .Lmp4_tables_bad
    mov rax, [rip + mp4_stco]
    lea rcx, [rax + 8]
    cmp rcx, [rip + mp4_stco_end]
    ja .Lmp4_tables_bad
    mov r15d, [rax + 4]
    bswap r15d                            # chunks
    mov ecx, 4
    cmp dword ptr [rip + mp4_co64], 0
    je .Lmp4_tables_offset_size
    mov ecx, 8
.Lmp4_tables_offset_size:
    mov eax, r15d
    imul rax, rcx
    add rax, [rip + mp4_stco]
    add rax, 8
    cmp rax, [rip + mp4_stco_end]
    ja .Lmp4_tables_bad
    xor ebx, ebx                          # sample
    xor r12d, r12d                        # chunk (0-based)
    xor r13d, r13d                        # stsc entry
.Lmp4_tables_chunk:
    cmp r12d, r15d
    jae .Lmp4_tables_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmp4_tables_continue
    cmp dword ptr [rax], 0
    jne .Lmp4_tables_bad
.Lmp4_tables_continue:
    # Advance stsc while the next entry's first chunk has been reached.
.Lmp4_tables_stsc:
    lea eax, [r13 + 1]
    cmp eax, r14d
    jae .Lmp4_tables_stsc_ready
    imul rcx, rax, 12
    add rcx, [rip + mp4_stsc]
    mov ecx, [rcx + 8]
    bswap ecx
    dec ecx
    cmp r12d, ecx
    jb .Lmp4_tables_stsc_ready
    inc r13d
    jmp .Lmp4_tables_stsc
.Lmp4_tables_stsc_ready:
    imul rcx, r13, 12
    add rcx, [rip + mp4_stsc]
    cmp dword ptr [rcx + 16], 0x01000000  # only the first sample description
    jne .Lmp4_tables_bad
    mov edi, [rcx + 12]
    bswap edi                             # samples in this chunk
    mov rcx, [rip + mp4_stco]
    cmp dword ptr [rip + mp4_co64], 0
    jne .Lmp4_tables_offset64
    mov esi, [rcx + r12*4 + 8]
    bswap esi
    jmp .Lmp4_tables_offset_ready
.Lmp4_tables_offset64:
    mov rsi, [rcx + r12*8 + 8]
    bswap rsi
.Lmp4_tables_offset_ready:
    add rsi, [rip + mp4_begin]            # absolute chunk start
    jc .Lmp4_tables_bad
    cmp dword ptr [rip + mp4_qt_legacy], 0
    jne .Lmp4_tables_legacy
    cmp dword ptr [rip + mp4_codec], 1
    jne .Lmp4_tables_sample
    # PCM: the chunk holds that many frames, listed in PCM_PACKET pieces.
    add ebx, edi
.Lmp4_tables_pcm:
    test edi, edi
    jz .Lmp4_tables_next_chunk
    mov eax, edi
    cmp eax, PCM_PACKET
    jbe .Lmp4_tables_pcm_piece
    mov eax, PCM_PACKET
.Lmp4_tables_pcm_piece:
    sub edi, eax
    imul eax, [rip + mp4_pcm_frame]
    mov rcx, rsi
    mov edx, eax
    add rsi, rax
    call mp4_packet
    test eax, eax
    jz .Lmp4_tables_bad
    jmp .Lmp4_tables_pcm
.Lmp4_tables_legacy:
    mov eax, edi
    add ebx, edi
    jc .Lmp4_tables_bad
    cmp ebx, [rsp + 32]
    ja .Lmp4_tables_bad
    xor edx, edx
    div dword ptr [rip + mp4_qt_frames]
    test edx, edx
    jnz .Lmp4_tables_bad                   # no partial compressed block
    mov edi, eax
.Lmp4_tables_legacy_block:
    test edi, edi
    jz .Lmp4_tables_next_chunk
    mov rcx, rsi
    mov edx, [rip + mp4_qt_block]
    add rsi, rdx
    call mp4_packet
    test eax, eax
    jz .Lmp4_tables_bad
    dec edi
    jmp .Lmp4_tables_legacy_block
.Lmp4_tables_sample:
    test edi, edi
    jz .Lmp4_tables_next_chunk
    cmp ebx, [rsp + 32]
    jae .Lmp4_tables_bad
    mov edx, [rsp + 40]
    test edx, edx
    jnz .Lmp4_tables_add
    mov rcx, [rip + mp4_stsz]
    add rcx, 12
    mov eax, [rsp + 36]
    cmp eax, 32
    jne .Lmp4_tables_field_size
    mov edx, [rcx + rbx*4]
    bswap edx
    jmp .Lmp4_tables_add
.Lmp4_tables_field_size:
    cmp eax, 16
    jne .Lmp4_tables_field8
    movzx edx, word ptr [rcx + rbx*2]
    rol dx, 8
    jmp .Lmp4_tables_add
.Lmp4_tables_field8:
    cmp eax, 8
    jne .Lmp4_tables_field4
    movzx edx, byte ptr [rcx + rbx]
    jmp .Lmp4_tables_add
.Lmp4_tables_field4:
    mov eax, ebx
    shr eax, 1
    movzx edx, byte ptr [rcx + rax]
    test ebx, 1
    jnz .Lmp4_tables_low_nibble
    shr edx, 4
.Lmp4_tables_low_nibble:
    and edx, 15
.Lmp4_tables_add:
    mov [rsp + 44], edx
    mov rcx, rsi
    call mp4_packet
    test eax, eax
    jz .Lmp4_tables_bad
    mov eax, [rsp + 44]
    add rsi, rax
    inc ebx
    dec edi
    jmp .Lmp4_tables_sample
.Lmp4_tables_next_chunk:
    inc r12d
    jmp .Lmp4_tables_chunk
.Lmp4_tables_done:
    cmp ebx, [rsp + 32]
    jne .Lmp4_tables_bad                  # every listed sample is placed
    mov eax, 1
    jmp .Lmp4_tables_return
.Lmp4_tables_bad:
    xor eax, eax
.Lmp4_tables_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_sample_tables

# Movie fragments: every moof's traf for the selected track, in file order.
# Defaults come from trex, overridden by tfhd. Locals: 32 implicit base (moof
# start, then the end of the previous traf's data), 40 traf base, 48 default
# size, 52 current size, 56 trun scan cursor, 64 data cursor, 72 moof start,
# 80 default duration.
LOCALFN mp4_fragments
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov rsi, [rip + mp4_begin]
.Lmp4_frag_box:
    cmp rsi, [rip + mp4_end]
    jae .Lmp4_frag_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmp4_frag_continue
    cmp dword ptr [rax], 0
    jne .Lmp4_frag_bad
.Lmp4_frag_continue:
    mov rcx, rsi
    mov rdx, [rip + mp4_end]
    call mp4_box
    test eax, eax
    jz .Lmp4_frag_bad
    mov [rsp + 72], rsi                   # moof start
    mov rsi, rdx
    cmp eax, BOX_MOOF
    jne .Lmp4_frag_box
    mov r12, r8                           # moof children
    mov r13, rdx
    mov rax, [rsp + 72]
    mov [rsp + 32], rax
.Lmp4_frag_traf:
    cmp r12, r13
    jae .Lmp4_frag_box
    mov rcx, r12
    mov rdx, r13
    call mp4_box
    test eax, eax
    jz .Lmp4_frag_bad
    mov r12, rdx
    cmp eax, BOX_TRAF
    jne .Lmp4_frag_traf
    mov r14, r8                           # traf payload
    mov r15, rdx
    mov rcx, r14
    mov rdx, r15
    mov r8d, BOX_TFHD
    call mp4_child
    test rax, rax
    jz .Lmp4_frag_bad
    lea rcx, [rax + 8]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov ecx, [rax + 4]
    bswap ecx
    cmp ecx, [rip + mp4_track_id]
    jne .Lmp4_frag_traf                   # another track
    mov edi, [rax]
    bswap edi
    and edi, 0xffffff                     # tfhd flags
    lea r8, [rax + 8]
    mov r9, [rsp + 32]
    test edi, 1
    jz .Lmp4_frag_no_base
    lea rcx, [r8 + 8]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov r9, [r8]
    bswap r9
    add r9, [rip + mp4_begin]
    add r8, 8
    jmp .Lmp4_frag_base_ready
.Lmp4_frag_no_base:
    test edi, 0x20000
    jz .Lmp4_frag_base_ready
    mov r9, [rsp + 72]                    # default-base-is-moof
.Lmp4_frag_base_ready:
    mov [rsp + 40], r9
    mov [rsp + 64], r9
    mov eax, [rip + mp4_trex_index]       # only the first sample description
    test edi, 2
    jz .Lmp4_frag_description
    lea rcx, [r8 + 4]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov eax, [r8]
    bswap eax
    add r8, 4
.Lmp4_frag_description:
    cmp eax, 1
    ja .Lmp4_frag_bad
    test edi, 2
    jz .Lmp4_frag_no_description
    test eax, eax
    jz .Lmp4_frag_bad
.Lmp4_frag_no_description:
    mov eax, [rip + mp4_trex_duration]
    test edi, 8
    jz .Lmp4_frag_no_duration
    lea rcx, [r8 + 4]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov eax, [r8]
    bswap eax
    add r8, 4
.Lmp4_frag_no_duration:
    mov [rsp + 80], eax
    mov eax, [rip + mp4_trex_size]
    test edi, 0x10
    jz .Lmp4_frag_size_ready
    lea rcx, [r8 + 4]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov eax, [r8]
    bswap eax
.Lmp4_frag_size_ready:
    mov [rsp + 48], eax
    mov [rsp + 56], r14
.Lmp4_frag_trun:
    mov rcx, [rsp + 56]
    cmp rcx, r15
    jae .Lmp4_frag_traf_done
    mov rdx, r15
    call mp4_box
    test eax, eax
    jz .Lmp4_frag_bad
    mov [rsp + 56], rdx
    cmp eax, BOX_TRUN
    jne .Lmp4_frag_trun
    lea rcx, [r8 + 8]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov edi, [r8]
    bswap edi
    and edi, 0xffffff                     # trun flags
    mov ebx, [r8 + 4]
    bswap ebx                             # samples
    add r8, 8
    mov rsi, [rsp + 64]                   # without an offset, data continues
    test edi, 1
    jz .Lmp4_frag_trun_offset_ready
    lea rcx, [r8 + 4]
    cmp rcx, rdx
    ja .Lmp4_frag_bad
    mov eax, [r8]
    bswap eax
    movsxd rax, eax
    mov rsi, [rsp + 40]
    add rsi, rax
    add r8, 4
.Lmp4_frag_trun_offset_ready:
    test edi, 4
    jz .Lmp4_frag_first_flags
    add r8, 4
.Lmp4_frag_first_flags:
    xor r10d, r10d                        # bytes per sample record
    test edi, 0x100
    jz .Lmp4_frag_w1
    add r10d, 4
.Lmp4_frag_w1:
    mov r11d, r10d                        # size offset in the record
    test edi, 0x200
    jz .Lmp4_frag_w2
    add r10d, 4
.Lmp4_frag_w2:
    test edi, 0x400
    jz .Lmp4_frag_w3
    add r10d, 4
.Lmp4_frag_w3:
    test edi, 0x800
    jz .Lmp4_frag_w4
    add r10d, 4
.Lmp4_frag_w4:
    mov eax, ebx
    imul rax, r10
    add rax, r8
    cmp rax, rdx
    ja .Lmp4_frag_bad
.Lmp4_frag_sample:
    test ebx, ebx
    jz .Lmp4_frag_trun_end
    mov edx, [rsp + 48]
    test edi, 0x200
    jz .Lmp4_frag_sample_size
    mov edx, [r8 + r11]
    bswap edx
.Lmp4_frag_sample_size:
    mov eax, [rsp + 80]                   # duration: the record's or the default
    test edi, 0x100
    jz .Lmp4_frag_sample_duration
    mov eax, [r8]
    bswap eax
.Lmp4_frag_sample_duration:
    test eax, eax
    jz .Lmp4_frag_duration_unknown
    add [rip + mp4_media_duration], rax
    jnc .Lmp4_frag_duration_done
.Lmp4_frag_duration_unknown:
    mov dword ptr [rip + mp4_duration_unknown], 1
.Lmp4_frag_duration_done:
    add r8, r10
    mov [rsp + 52], edx
    push r8
    push r10
    push r11
    sub rsp, 8
    mov rcx, rsi
    call mp4_packet
    add rsp, 8
    pop r11
    pop r10
    pop r8
    test eax, eax
    jz .Lmp4_frag_bad
    mov eax, [rsp + 52]
    add rsi, rax
    dec ebx
    jmp .Lmp4_frag_sample
.Lmp4_frag_trun_end:
    mov [rsp + 64], rsi
    jmp .Lmp4_frag_trun
.Lmp4_frag_traf_done:
    mov rax, [rsp + 64]
    mov [rsp + 32], rax
    jmp .Lmp4_frag_traf
.Lmp4_frag_done:
    mov eax, 1
    jmp .Lmp4_frag_return
.Lmp4_frag_bad:
    xor eax, eax
.Lmp4_frag_return:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_fragments

# RCX=mapped start, RDX=end -> EAX=1 with the selected track's packets
# listed and its codec opened by track_finish.
FN mp4_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov [rip + mp4_begin], rcx
    mov [rip + mp4_end], rdx
    mov dword ptr [rip + mp4_selected], 0
    mov dword ptr [rip + mp4_audio_index], 0
    mov dword ptr [rip + mp4_fragmented], 0
    mov dword ptr [rip + mp4_trex_size], 0
    mov dword ptr [rip + mp4_trex_duration], 0
    mov dword ptr [rip + mp4_trex_index], 0
    mov qword ptr [rip + mp4_config], 0
    mov dword ptr [rip + mp4_config_bytes], 0
    # Exactly one moov at the top level.
    mov rsi, rcx
    xor ebx, ebx
.Lmp4_top:
    cmp rsi, [rip + mp4_end]
    jae .Lmp4_top_done
    mov rcx, rsi
    mov rdx, [rip + mp4_end]
    call mp4_box
    test eax, eax
    jz .Lmp4_open_bad
    mov rsi, rdx
    cmp eax, BOX_MOOV
    jne .Lmp4_top
    test rbx, rbx
    jnz .Lmp4_open_bad
    mov rbx, r8
    mov rdi, rdx
    jmp .Lmp4_top
.Lmp4_top_done:
    test rbx, rbx
    jz .Lmp4_open_bad
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, BOX_MVHD
    call mp4_child
    test rax, rax
    jz .Lmp4_open_bad
    lea rcx, [rax + 24]
    cmp rcx, rdx
    ja .Lmp4_open_bad
    mov ecx, [rax + 12]
    cmp byte ptr [rax], 1
    jne .Lmp4_movie_scale
    mov ecx, [rax + 20]
.Lmp4_movie_scale:
    bswap ecx
    test ecx, ecx
    jz .Lmp4_open_bad
    mov [rip + mp4_movie_scale], ecx
    # Tracks.
    mov rsi, rbx
.Lmp4_tracks:
    cmp rsi, rdi
    jae .Lmp4_tracks_done
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test eax, eax
    jz .Lmp4_open_bad
    mov rsi, rdx
    cmp eax, BOX_TRAK
    jne .Lmp4_tracks
    mov rcx, r8
    call mp4_trak
    test eax, eax
    jz .Lmp4_open_bad
    jmp .Lmp4_tracks
.Lmp4_tracks_done:
    cmp dword ptr [rip + mp4_selected], 0
    jne .Lmp4_tracks_selected
    cmp dword ptr [rip + track_choice], 0
    je .Lmp4_open_bad
    mov dword ptr [rip + decode_error], 101   # the chosen track is missing or unsupported
    jmp .Lmp4_open_bad
.Lmp4_tracks_selected:
    # Fragment defaults for the selected track.
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, BOX_MVEX
    call mp4_child
    test rax, rax
    jz .Lmp4_packets
    mov dword ptr [rip + mp4_fragmented], 1
    mov r12, rax
    mov rdi, rdx
.Lmp4_trex:
    cmp r12, rdi
    jae .Lmp4_packets
    mov rcx, r12
    mov rdx, rdi
    call mp4_box
    test eax, eax
    jz .Lmp4_open_bad
    mov r12, rdx
    cmp eax, BOX_TREX
    jne .Lmp4_trex
    lea rcx, [r8 + 24]
    cmp rcx, rdx
    ja .Lmp4_open_bad
    mov ecx, [r8 + 4]
    bswap ecx
    cmp ecx, [rip + mp4_track_id]
    jne .Lmp4_trex
    mov ecx, [r8 + 8]
    bswap ecx
    mov [rip + mp4_trex_index], ecx
    mov ecx, [r8 + 12]
    bswap ecx
    mov [rip + mp4_trex_duration], ecx
    mov ecx, [r8 + 16]
    bswap ecx
    mov [rip + mp4_trex_size], ecx
    jmp .Lmp4_trex
.Lmp4_packets:
    mov ecx, [rip + mp4_codec]
    cmp ecx, 255
    je .Lmp4_open_bad
    call track_begin
    test eax, eax
    jz .Lmp4_open_bad
    # Samples in the movie box, then any fragments.
    mov rax, [rip + mp4_stsz]
    test rax, rax
    jz .Lmp4_packets_fragments
    mov ecx, [rax + 8]
    test ecx, ecx
    jz .Lmp4_packets_fragments
    call mp4_sample_tables
    test eax, eax
    jz .Lmp4_open_bad
.Lmp4_packets_fragments:
    cmp dword ptr [rip + mp4_fragmented], 0
    je .Lmp4_packets_done
    call mp4_fragments
    test eax, eax
    jz .Lmp4_open_bad
.Lmp4_packets_done:
    # Configuration, PCM layout and the edit.
    mov rax, [rip + mp4_config]
    mov [rip + track_config], rax
    mov eax, [rip + mp4_config_bytes]
    mov [rip + track_config_bytes], eax
    mov eax, [rip + mp4_channels]
    mov [rip + track_pcm_channels], eax
    mov eax, [rip + mp4_pcm_bits]
    mov [rip + track_pcm_bits], eax
    mov eax, [rip + mp4_pcm_flags]
    mov [rip + track_pcm_flags], eax
    cmp dword ptr [rip + mp4_codec], 1
    jne .Lmp4_edit
    mov eax, [rip + mp4_rate]
    cmp eax, 8000
    jb .Lmp4_open_bad
    cmp eax, 192000
    ja .Lmp4_open_bad
    mov [rip + sample_rate], eax
.Lmp4_edit:
    # Presentation: from the edit's media time (or the codec's own start)
    # to the edit's end or the media's end, whichever comes first.
    mov eax, [rip + mp4_media_scale]
    mov [rip + track_unit_scale], eax
    mov eax, [rip + mp4_edit_found]
    mov [rip + track_edit], eax
    mov rax, [rip + mp4_edit_start]
    mov [rip + track_start_units], rax
    xor r8d, r8d
    cmp dword ptr [rip + mp4_duration_unknown], 0
    jne .Lmp4_edit_media
    mov r8, [rip + mp4_media_duration]
.Lmp4_edit_media:
    mov [rip + track_end_units], r8
    mov rax, [rip + mp4_edit_duration]
    test rax, rax
    jz .Lmp4_finish
    mov ecx, [rip + mp4_media_scale]      # movie units -> media units, rounded
    mul rcx
    mov ecx, [rip + mp4_movie_scale]
    mov r9, rcx
    shr r9, 1
    add rax, r9
    adc rdx, 0
    cmp rdx, rcx
    jae .Lmp4_open_bad
    div rcx
    add rax, [rip + mp4_edit_start]
    jc .Lmp4_open_bad
    test r8, r8
    jz .Lmp4_edit_end
    cmp rax, r8
    jae .Lmp4_finish                      # the media ends first
.Lmp4_edit_end:
    mov [rip + track_end_units], rax
.Lmp4_finish:
    call track_finish
    test eax, eax
    jz .Lmp4_open_bad
    mov dword ptr [rip + codec_kind], 9
    mov eax, 1
    jmp .Lmp4_open_return
.Lmp4_open_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lmp4_open_failed
    mov dword ptr [rip + decode_error], 90
.Lmp4_open_failed:
    xor eax, eax
.Lmp4_open_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_open

.data
mp4_stsz_end: .quad 0
mp4_stsc_end: .quad 0
mp4_stco_end: .quad 0
