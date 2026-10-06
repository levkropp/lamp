# Original IMA and Microsoft ADPCM decoders in x86-64 assembly. MIT, see LICENSE.
# WAVE format tags 0x11 (IMA ADPCM, 4-bit samples, 1-8 channels) and 2
# (Microsoft ADPCM, mono or stereo). Every block starts with its channels'
# predictor state, so blocks are track packets that decode independently; a
# short final block decodes the whole sample groups it holds. QuickTime IMA4
# (CAF and AIFF-C "ima4", described by a WAVE-style fmt with the private tag
# ADPCM_QT) packs 64 samples per channel in 34-byte blocks whose headers keep
# only the predictor's top nine bits, so a header close to the running state
# continues it (as FFmpeg does) and seeks decode one primer packet. Flash
# ADPCM (FLV and SWF sound data, the private tag ADPCM_SWF) is a bitstream:
# a 2-bit code size (2-5 bits), then blocks of 4096 samples per channel,
# each a 16-bit sample and a 6-bit step index per channel and 4095
# interleaved codes, with the SWF specification's step index tables.
# Decoding follows FFmpeg's adpcm_ima_wav, adpcm_ms, adpcm_ima_qt and
# adpcm_swf; the tables are src/adpcm_tables.inc (with the G.711 expansions
# used by the PCM reader). G.726 (WAVE tags 0x45, 0x14, 0x40 and 0x64, codes
# packed from the most significant bit; AU, the private tag ADPCM_G726LE,
# from the least) and G.722 (0x28f) are mono bitstreams whose state runs on
# across packets of about 4 KiB (src/g72x.s): a seek decodes three primer
# packets from a reset state. GSM 06.10 (src/gsm.s), whose state runs on as
# well, comes as Microsoft's 65-byte blocks of two frames (WAVE tag 0x31) or
# as 33-byte frames (the private tag ADPCM_GSM: AIFF-C, QuickTime, raw).
.include "lamp.inc"
.globl adpcm_track_open, adpcm_track_samples, adpcm_track_decode, adpcm_track_close, adpcm_track_reset
.globl adpcm_primer, g711_alaw, g711_ulaw, adpcm_packet_layout

.equ ADPCM_MALFORMED, 100
.equ ADPCM_UNSUPPORTED, 101
.equ ADPCM_IMA, 0x11
.equ ADPCM_MS, 2
.equ ADPCM_QT, 0x4d49               # LAMP's tag for QuickTime IMA4 (not a WAVE tag)
.equ ADPCM_SWF, 0x5346              # LAMP's tag for Flash ADPCM (not a WAVE tag)
.equ ADPCM_G726, 0x45
.equ ADPCM_G726LE, 0x4c47           # LAMP's tag for AU's G.726 (codes from the low bit)
.equ ADPCM_G722, 0x28f
.equ ADPCM_GSM_MS, 0x31
.equ ADPCM_GSM, 0x5347              # LAMP's tag for 33-byte GSM frames (not a WAVE tag)
.equ GSM_PRIMER, 3                  # packets decoded before a seek target
.equ G72X_PACKET, 4096              # bytes per packet at most
.equ G72X_PRIMER, 3                 # packets decoded before a seek target
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
# Flash ADPCM step index changes by code size (2-5 bits), indexed by the
# code's magnitude bits (SWF File Format Specification, version 19).
swf_index:
    .byte -1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte -1, -1, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte -1, -1, -1, -1, 2, 4, 6, 8, 0, 0, 0, 0, 0, 0, 0, 0
    .byte -1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16

.data
adpcm_tag: .long 0
adpcm_channels: .long 0
adpcm_align: .long 0
adpcm_stride: .long 0                    # bytes per channel plane
adpcm_planes: .quad 0                    # int16 channel planes of one block
adpcm_primer: .long 0                    # packets decoded before a seek target (0: none)
adpcm_bits: .long 0                      # Flash ADPCM code size of the packet

.bss
.p2align 3
adpcm_state: .zero 8*8                   # IMA predictor and step index per channel
ms_state: .zero 2*MS_SIZE

.text
# ECX=block bytes -> EAX=samples per channel, 0 below the channels' headers
# (FFmpeg: IMA 1 + whole 8-sample groups, Microsoft 2 + two per byte).
LOCALFN adpcm_block_samples
    mov r8d, [rip + adpcm_channels]
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM
    je .Ladpcm_samples_gsm
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM_MS
    je .Ladpcm_samples_gsm_ms
    cmp dword ptr [rip + adpcm_tag], ADPCM_G722
    je .Ladpcm_samples_g722
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726
    je .Ladpcm_samples_g726
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726LE
    je .Ladpcm_samples_g726
    cmp dword ptr [rip + adpcm_tag], ADPCM_SWF
    je .Ladpcm_samples_swf
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
.Ladpcm_samples_swf:
    # Flash (adpcm_bits per code): whole 4096-sample blocks, then a partial
    # block's first sample and whole code groups.
    lea r9d, [rcx*8 - 2]                  # bits after the code size
    test ecx, ecx
    jz .Ladpcm_samples_none
    imul r10d, r8d, 22                    # block headers
    mov r11d, [rip + adpcm_bits]
    imul r11d, r8d                        # bits per code group
    imul ecx, r11d, 4095
    add ecx, r10d                         # bits per block
    mov eax, r9d
    xor edx, edx
    div ecx
    shl eax, 12
    mov ecx, eax                          # samples of whole blocks
    sub edx, r10d                         # bits left after a header
    jb .Ladpcm_samples_swf_done
    mov eax, edx
    xor edx, edx
    div r11d
    lea ecx, [rcx + rax + 1]
.Ladpcm_samples_swf_done:
    mov eax, ecx
    ret
.Ladpcm_samples_g722:
    lea eax, [rcx*2]                      # two samples per codeword
    ret
.Ladpcm_samples_gsm:
    mov eax, ecx                          # 160 per whole 33-byte frame
    xor edx, edx
    mov ecx, 33
    div ecx
    imul eax, eax, 160
    ret
.Ladpcm_samples_gsm_ms:
    mov eax, ecx                          # 320 per whole 65-byte block
    xor edx, edx
    mov ecx, 65
    div ecx
    imul eax, eax, 320
    ret
.Ladpcm_samples_g726:
    lea eax, [rcx*8]                      # whole codes
    xor edx, edx
    div dword ptr [rip + adpcm_bits]
    ret
.Ladpcm_samples_none:
    xor eax, eax
    ret
ENDFN adpcm_block_samples

# RCX=WAVE fmt chunk (16 bytes or more) -> EAX=bytes per packet, EDX=the
# fewest bytes a packet decodes from. Blocks for IMA and Microsoft ADPCM
# (their headers); for G.726 and G.722 runs of whole codes as FFmpeg's WAVE
# demuxer reads them (4096 bytes, or 4095 for 3- and 5-bit codes).
FN adpcm_packet_layout
    movzx eax, word ptr [rcx]
    cmp eax, 0xfffe
    jne .Ladpcm_layout_tag
    movzx eax, word ptr [rcx + 24]
.Ladpcm_layout_tag:
    mov r9d, eax
    call adpcm_g72x_tag
    cmp eax, 2
    je .Ladpcm_layout_gsm
    test eax, eax
    jnz .Ladpcm_layout_g72x
    movzx edx, word ptr [rcx + 2]
    imul edx, edx, 7
    cmp r9d, ADPCM_IMA
    jne .Ladpcm_layout_block
    movzx edx, word ptr [rcx + 2]
    shl edx, 2
.Ladpcm_layout_block:
    movzx eax, word ptr [rcx + 12]
    ret
.Ladpcm_layout_g72x:
    mov eax, G72X_PACKET
    mov edx, 1
    cmp r9d, ADPCM_G722
    je .Ladpcm_layout_return
    movzx r8d, word ptr [rcx + 14]
    cmp r8d, 3
    je .Ladpcm_layout_odd
    cmp r8d, 5
    jne .Ladpcm_layout_return
.Ladpcm_layout_odd:
    dec eax                               # 4095: whole 3- or 5-bit codes
.Ladpcm_layout_return:
    ret
.Ladpcm_layout_gsm:
    mov eax, 65*20                        # 20 blocks (or frames) per packet
    mov edx, 65
    cmp r9d, ADPCM_GSM_MS
    je .Ladpcm_layout_return
    mov eax, 33*20
    mov edx, 33
    ret
ENDFN adpcm_packet_layout

# EAX=format tag -> EAX=1 for G.726 (any of its tags) or G.722, 2 for GSM.
LOCALFN adpcm_g72x_tag
    cmp eax, ADPCM_GSM_MS
    je .Ladpcm_g72x_gsm
    cmp eax, ADPCM_GSM
    je .Ladpcm_g72x_gsm
    cmp eax, ADPCM_G726
    je .Ladpcm_g72x_yes
    cmp eax, 0x14
    je .Ladpcm_g72x_yes
    cmp eax, 0x40
    je .Ladpcm_g72x_yes
    cmp eax, 0x64
    je .Ladpcm_g72x_yes
    cmp eax, ADPCM_G726LE
    je .Ladpcm_g72x_yes
    cmp eax, ADPCM_G722
    je .Ladpcm_g72x_yes
    xor eax, eax
    ret
.Ladpcm_g72x_yes:
    mov eax, 1
    ret
.Ladpcm_g72x_gsm:
    mov eax, 2
    ret
ENDFN adpcm_g72x_tag

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
    mov eax, [rcx + 4]
    cmp eax, 8000
    jb .Ladpcm_open_fail
    cmp eax, 192000
    ja .Ladpcm_open_fail
    mov [rip + sample_rate], eax
    mov eax, ebx
    call adpcm_g72x_tag
    cmp eax, 2
    je .Ladpcm_open_gsm
    test eax, eax
    jnz .Ladpcm_open_g72x
    cmp word ptr [rcx + 14], 4             # 4-bit samples only
    jne .Ladpcm_open_fail
    cmp esi, 8
    ja .Ladpcm_open_fail
    cmp ebx, ADPCM_IMA
    je .Ladpcm_open_layout
    cmp ebx, ADPCM_QT
    je .Ladpcm_open_layout
    cmp ebx, ADPCM_SWF
    je .Ladpcm_open_two
    cmp ebx, ADPCM_MS
    jne .Ladpcm_open_fail
.Ladpcm_open_two:
    cmp esi, 2
    ja .Ladpcm_open_fail
    jmp .Ladpcm_open_layout
.Ladpcm_open_g72x:
    # G.726 and G.722: one channel; G.726 codes of 2-5 bits. Every tag
    # of G.726 in WAVE decodes as 0x45.
    cmp esi, 1
    jne .Ladpcm_open_fail
    mov dword ptr [rip + adpcm_align], G72X_PACKET
    movzx eax, word ptr [rcx + 14]
    cmp ebx, ADPCM_G722
    je .Ladpcm_open_g722
    cmp ebx, ADPCM_G726LE
    je .Ladpcm_open_g726
    mov ebx, ADPCM_G726
    mov [rip + adpcm_tag], ebx
.Ladpcm_open_g726:
    cmp eax, 2
    jb .Ladpcm_open_fail
    cmp eax, 5
    ja .Ladpcm_open_fail
    mov [rip + adpcm_bits], eax
    jmp .Ladpcm_open_g72x_layout
.Ladpcm_open_g722:
    mov dword ptr [rip + adpcm_bits], 4
    jmp .Ladpcm_open_g72x_layout
.Ladpcm_open_gsm:
    # GSM: one channel, packets of 20 frames or blocks.
    cmp esi, 1
    jne .Ladpcm_open_fail
    mov eax, 65*20
    cmp ebx, ADPCM_GSM_MS
    je .Ladpcm_open_gsm_align
    mov eax, 33*20
.Ladpcm_open_gsm_align:
    mov [rip + adpcm_align], eax
    mov dword ptr [rip + adpcm_bits], 0
.Ladpcm_open_g72x_layout:
    mov dword ptr [rip + decode_error], ADPCM_MALFORMED
    jmp .Ladpcm_open_samples
.Ladpcm_open_layout:
    mov dword ptr [rip + decode_error], ADPCM_MALFORMED
    mov dword ptr [rip + adpcm_bits], 2   # Flash: the most samples per byte
.Ladpcm_open_samples:
    mov [rsp + 32], r10d
    mov ecx, [rip + adpcm_align]
    call adpcm_block_samples
    mov r10d, [rsp + 32]
    test eax, eax
    jz .Ladpcm_open_fail
    lea eax, [rax*2 + 63]
    and eax, -64
    mov [rip + adpcm_stride], eax
    mov [rip + source_channels], esi
    mov eax, [rip + adpcm_bits]           # G.726: its code size; GSM 0; others 4
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726
    je .Ladpcm_open_bits
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726LE
    je .Ladpcm_open_bits
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM
    je .Ladpcm_open_bits
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM_MS
    je .Ladpcm_open_bits
    mov eax, 4
.Ladpcm_open_bits:
    mov [rip + source_bits], eax
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
    mov ecx, G72X_PRIMER
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726
    cmove eax, ecx
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726LE
    cmove eax, ecx
    cmp dword ptr [rip + adpcm_tag], ADPCM_G722
    cmove eax, ecx
    mov ecx, GSM_PRIMER
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM
    cmove eax, ecx
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM_MS
    cmove eax, ecx
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

# Clears the IMA4 and G.726/G.722 running state (stream start, seeks).
FN adpcm_track_reset
    sub rsp, 40
    lea rcx, [rip + adpcm_state]
    xor eax, eax
.Ladpcm_reset_word:
    mov qword ptr [rcx + rax*8], 0
    inc eax
    cmp eax, 8
    jb .Ladpcm_reset_word
    cmp dword ptr [rip + adpcm_tag], ADPCM_G722
    je .Ladpcm_reset_g722
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM
    je .Ladpcm_reset_gsm
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM_MS
    je .Ladpcm_reset_gsm
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726
    je .Ladpcm_reset_g726
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726LE
    jne .Ladpcm_reset_return
.Ladpcm_reset_g726:
    mov ecx, [rip + adpcm_bits]
    call g726_reset
    jmp .Ladpcm_reset_return
.Ladpcm_reset_g722:
    call g722_reset
    jmp .Ladpcm_reset_return
.Ladpcm_reset_gsm:
    call gsm_reset
.Ladpcm_reset_return:
    add rsp, 40
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
    call adpcm_packet_bits
    mov ecx, edx
    call adpcm_block_samples
    test eax, eax
    jnz .Ladpcm_track_samples_return
    mov eax, -1
.Ladpcm_track_samples_return:
    add rsp, 40
    ret
ENDFN adpcm_track_samples

# RCX=packet, EDX=bytes: a Flash packet's code size -> adpcm_bits.
LOCALFN adpcm_packet_bits
    cmp dword ptr [rip + adpcm_tag], ADPCM_SWF
    jne .Ladpcm_packet_bits_return
    test edx, edx
    jz .Ladpcm_packet_bits_return
    movzx eax, byte ptr [rcx]
    shr eax, 6
    add eax, 2
    mov [rip + adpcm_bits], eax
.Ladpcm_packet_bits_return:
    ret
ENDFN adpcm_packet_bits

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
    mov r13d, edx
    call adpcm_packet_bits
    mov ecx, r13d
    call adpcm_block_samples
    mov ebx, eax
    test eax, eax
    jz .Ladpcm_decode_bad
    cmp eax, r12d
    ja .Ladpcm_decode_bad
    mov rcx, rsi
    mov edx, ebx
    mov r8, [rip + adpcm_planes]
    cmp dword ptr [rip + adpcm_tag], ADPCM_G722
    je .Ladpcm_decode_g722
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726
    je .Ladpcm_decode_g726
    xor r9d, r9d
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM
    je .Ladpcm_decode_gsm
    inc r9d
    cmp dword ptr [rip + adpcm_tag], ADPCM_GSM_MS
    je .Ladpcm_decode_gsm
    xor r9d, r9d
    inc r9d
    cmp dword ptr [rip + adpcm_tag], ADPCM_G726LE
    je .Ladpcm_decode_g726_codes
    cmp dword ptr [rip + adpcm_tag], ADPCM_SWF
    je .Ladpcm_decode_swf
    cmp dword ptr [rip + adpcm_tag], ADPCM_QT
    je .Ladpcm_decode_qt
    cmp dword ptr [rip + adpcm_tag], ADPCM_IMA
    jne .Ladpcm_decode_ms
    call ima_block
    jmp .Ladpcm_decode_check
.Ladpcm_decode_qt:
    call ima4_block
    jmp .Ladpcm_decode_check
.Ladpcm_decode_swf:
    mov edx, r13d
    call swf_block
    jmp .Ladpcm_decode_check
.Ladpcm_decode_g726:
    xor r9d, r9d                          # codes from the high bit
.Ladpcm_decode_g726_codes:
    call g726_block
    mov eax, 1
    jmp .Ladpcm_decode_check
.Ladpcm_decode_g722:
    mov edx, r13d                         # bytes
    call g722_block
    mov eax, 1
    jmp .Ladpcm_decode_check
.Ladpcm_decode_gsm:
    mov edx, r13d                         # bytes; R9D: Microsoft blocks
    call gsm_block
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

# ECX=bits (1-16), RSI=data, R13D=bit position (advanced) -> EAX, most
# significant bit first. Clobbers EDX and R8D only.
LOCALFN swf_get
    xor eax, eax
.Lswf_get_bit:
    mov edx, r13d
    shr edx, 3
    movzx r8d, byte ptr [rsi + rdx]
    mov edx, r13d
    and edx, 7
    xor edx, 7
    bt r8d, edx
    adc eax, eax
    inc r13d
    dec ecx
    jnz .Lswf_get_bit
    ret
ENDFN swf_get

# RCX=Flash ADPCM packet, EDX=bytes -> EAX=1 with the channel planes filled
# (adpcm_block_samples samples per channel). Codes expand like IMA's with
# shifts and adds, over the code's magnitude bits.
LOCALFN swf_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    lea r12d, [rdx*8]                     # bits
    xor r13d, r13d
    mov ecx, 2
    call swf_get
    lea ebx, [rax + 2]                    # code size
    lea r15, [rip + swf_index]
    shl eax, 4
    add r15, rax
    xor r14d, r14d                        # output sample
    mov edi, [rip + adpcm_channels]
.Lswf_block:
    imul eax, edi, 22
    mov edx, r12d
    sub edx, eax
    cmp r13d, edx
    jg .Lswf_done
    mov dword ptr [rsp + 40], 0
.Lswf_header:
    mov ecx, 16
    call swf_get
    movsx r10d, ax
    mov ecx, 6
    call swf_get
    mov r9d, [rsp + 40]
    lea r8, [rip + adpcm_state]
    mov [r8 + r9*8], r10d
    mov [r8 + r9*8 + 4], eax
    mov eax, [rip + adpcm_stride]
    imul eax, r9d
    add rax, [rip + adpcm_planes]
    mov [rax + r14*2], r10w
    inc r9d
    mov [rsp + 40], r9d
    cmp r9d, edi
    jb .Lswf_header
    inc r14d
    mov dword ptr [rsp + 32], 0           # codes in this block
.Lswf_codes:
    cmp dword ptr [rsp + 32], 4095
    jae .Lswf_block
    mov eax, ebx
    imul eax, edi
    mov edx, r12d
    sub edx, eax
    cmp r13d, edx
    jg .Lswf_block
    mov dword ptr [rsp + 40], 0
.Lswf_channel:
    mov ecx, ebx
    call swf_get                          # code
    mov r9d, [rsp + 40]
    lea r8, [rip + adpcm_state]
    mov r10d, [r8 + r9*8]                 # predictor
    mov r11d, [r8 + r9*8 + 4]             # step index
    lea rdx, [rip + ima_steps]
    movzx edx, word ptr [rdx + r11*2]     # step
    xor r8d, r8d                          # difference
    lea ecx, [rbx - 2]
    mov r9d, 1
    shl r9d, cl                           # magnitude bit
.Lswf_bit:
    test eax, r9d
    jz .Lswf_bit_next
    add r8d, edx
.Lswf_bit_next:
    shr edx, 1
    shr r9d, 1
    jnz .Lswf_bit
    add r8d, edx
    lea ecx, [rbx - 1]
    bt eax, ecx                           # sign
    jnc .Lswf_add
    sub r10d, r8d
    jmp .Lswf_index
.Lswf_add:
    add r10d, r8d
.Lswf_index:
    mov r9d, 1
    shl r9d, cl
    dec r9d
    and eax, r9d
    movsx eax, byte ptr [r15 + rax]
    add r11d, eax
    jns .Lswf_index_high
    xor r11d, r11d
.Lswf_index_high:
    cmp r11d, 88
    jbe .Lswf_clip
    mov r11d, 88
.Lswf_clip:
    cmp r10d, -32768
    jge .Lswf_clip_high
    mov r10d, -32768
.Lswf_clip_high:
    cmp r10d, 32767
    jle .Lswf_store
    mov r10d, 32767
.Lswf_store:
    mov r9d, [rsp + 40]
    lea r8, [rip + adpcm_state]
    mov [r8 + r9*8], r10d
    mov [r8 + r9*8 + 4], r11d
    mov eax, [rip + adpcm_stride]
    imul eax, r9d
    add rax, [rip + adpcm_planes]
    mov [rax + r14*2], r10w
    inc r9d
    mov [rsp + 40], r9d
    cmp r9d, edi
    jb .Lswf_channel
    inc r14d
    inc dword ptr [rsp + 32]
    jmp .Lswf_codes
.Lswf_done:
    mov eax, 1
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN swf_block

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
