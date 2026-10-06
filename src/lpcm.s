# Original DVD and Blu-ray LPCM reader in x86-64 assembly. MIT, see LICENSE.
# DVD LPCM: private stream 1 substreams 0xA0-0xA7 of program streams. Each
# packet holds the substream number, a frame count, a first access unit
# pointer and a three-byte header (emphasis, mute, frame number; sample
# size, rate and channels; dynamic range control), then big-endian samples.
# 20- and 24-bit samples come in groups of four (two in mono): the groups'
# top 16 bits, then their low bits. The sample stream runs on across packets.
# Blu-ray LPCM: transport stream type 0x80 under an HDMV registration. Each
# PES packet holds a four-byte header (frame size; channel assignment and
# rate; sample size), then frames of big-endian 16- or 24-bit samples with
# the channels padded to an even count. Both follow FFmpeg's pcm_dvd and
# pcm_bluray decoders, channel layouts and remapping included. The demuxer
# hands each packet to lpcm_dvd_packet or lpcm_bluray_packet, which check
# its header against the first and append its samples to the gather buffer;
# lpcm_image then converts them to little-endian PCM in a Wave64 image for
# the WAV reader.
.include "lamp.inc"
.globl lpcm_begin, lpcm_dvd_packet, lpcm_bluray_packet, lpcm_image

.equ LPCM_DVD, 1
.equ LPCM_BLURAY, 2

RODATA
lpcm_dvd_rates: .long 48000, 96000, 44100, 32000
# FFmpeg's default layouts for 1-8 channels (WAVE channel masks).
lpcm_dvd_masks: .long 0x4, 0x3, 0xb, 0x107, 0x37, 0x3f, 0x70f, 0x63f
# Blu-ray channel assignments 0-15: source channels (0 = reserved), output
# channels, WAVE mask, and each source channel's output index (255: padding).
lpcm_bd_layouts:
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 2, 1, 0, 0, 0x04, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255   # mono
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 2, 2, 0, 0, 0x03, 0, 0, 0, 0, 1, 255, 255, 255, 255, 255, 255     # stereo
    .byte 4, 3, 0, 0, 0x07, 0, 0, 0, 0, 1, 2, 255, 255, 255, 255, 255       # 3/0
    .byte 4, 3, 0, 0, 0x03, 1, 0, 0, 0, 1, 2, 255, 255, 255, 255, 255       # 2/1
    .byte 4, 4, 0, 0, 0x07, 1, 0, 0, 0, 1, 2, 3, 255, 255, 255, 255         # 3/1
    .byte 4, 4, 0, 0, 0x03, 6, 0, 0, 0, 1, 2, 3, 255, 255, 255, 255         # 2/2
    .byte 6, 5, 0, 0, 0x07, 6, 0, 0, 0, 1, 2, 3, 4, 255, 255, 255           # 3/2
    .byte 6, 6, 0, 0, 0x0f, 6, 0, 0, 0, 1, 2, 4, 5, 3, 255, 255             # 3/2+LFE
    .byte 8, 7, 0, 0, 0x37, 6, 0, 0, 0, 1, 2, 5, 3, 4, 6, 255               # 3/4
    .byte 8, 8, 0, 0, 0x3f, 6, 0, 0, 0, 1, 2, 6, 4, 5, 7, 3                 # 3/4+LFE
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
# The PCM SubFormat GUID's last 14 bytes, after the format tag.
lpcm_pcm_guid: .byte 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71

.data
lpcm_kind: .long 0
lpcm_seen: .long 0                  # a header was read
lpcm_header: .long 0                # DVD: header byte 1; Blu-ray: bytes 2 and 3
lpcm_frame: .long 0                 # Blu-ray: bytes per source frame
lpcm_pes: .quad 0                   # Blu-ray: gathered bytes when the packet began

.text
# ECX=LPCM_DVD or LPCM_BLURAY: a new stream.
FN lpcm_begin
    mov [rip + lpcm_kind], ecx
    mov dword ptr [rip + lpcm_seen], 0
    mov qword ptr [rip + lpcm_pes], 0
    ret
ENDFN lpcm_begin

# RCX=DVD substream data (the substream number), RDX=packet end -> EAX=1
# with its samples appended, 2 for an unsupported or changed format, 0 when
# the buffer is full. A packet without a whole header is skipped.
FN lpcm_dvd_packet
    sub rsp, 40
    mov eax, 1
    lea r8, [rcx + 7]
    cmp r8, rdx
    ja .Llpcm_dvd_return
    movzx r9d, byte ptr [rcx + 5]         # sample size, rate, channels
    cmp dword ptr [rip + lpcm_seen], 0
    jne .Llpcm_dvd_compare
    mov eax, r9d
    shr eax, 6
    cmp eax, 3                            # 28 bits: reserved
    je .Llpcm_dvd_unsupported
    mov [rip + lpcm_header], r9d
    mov dword ptr [rip + lpcm_seen], 1
    jmp .Llpcm_dvd_append
.Llpcm_dvd_compare:
    cmp r9d, [rip + lpcm_header]
    jne .Llpcm_dvd_unsupported            # a format change
.Llpcm_dvd_append:
    mov rcx, r8
    sub rdx, r8
    call mts_append
    jmp .Llpcm_dvd_return
.Llpcm_dvd_unsupported:
    mov eax, 2
.Llpcm_dvd_return:
    add rsp, 40
    ret
ENDFN lpcm_dvd_packet

# Ends the Blu-ray packet being gathered: a last partial frame is dropped,
# as FFmpeg decodes each packet's whole frames.
LOCALFN lpcm_bluray_end
    cmp dword ptr [rip + lpcm_seen], 0
    je .Llpcm_end_return
    mov rax, [rip + mts_bytes]
    sub rax, [rip + lpcm_pes]
    xor edx, edx
    mov ecx, [rip + lpcm_frame]
    div rcx
    sub [rip + mts_bytes], rdx
.Llpcm_end_return:
    ret
ENDFN lpcm_bluray_end

# RCX=a Blu-ray PES packet's data, RDX=end of its first transport packet's
# payload -> EAX=1 with the samples there appended (the rest of the packet
# follows as plain payload), 2 for an unsupported or changed format, 0 when
# malformed or the buffer is full.
FN lpcm_bluray_packet
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    call lpcm_bluray_end
    xor eax, eax
    lea r8, [rbx + 4]
    cmp r8, rsi
    ja .Llpcm_bd_return                   # the header must fit
    movzx r9d, word ptr [rbx + 2]
    rol r9w, 8                            # assignment and rate, sample size
    cmp dword ptr [rip + lpcm_seen], 0
    jne .Llpcm_bd_compare
    mov eax, 2
    mov ecx, r9d
    shr ecx, 12                           # channel assignment
    imul ecx, ecx, 16
    lea r10, [rip + lpcm_bd_layouts]
    movzx edx, byte ptr [r10 + rcx]       # source channels
    test edx, edx
    jz .Llpcm_bd_return
    mov ecx, r9d
    shr ecx, 8
    and ecx, 15                           # rate: 1, 4 or 5
    cmp ecx, 1
    je .Llpcm_bd_rate
    cmp ecx, 4
    je .Llpcm_bd_rate
    cmp ecx, 5
    jne .Llpcm_bd_return
.Llpcm_bd_rate:
    movzx ecx, r9b
    shr ecx, 6                            # sample size: 1 (16) or 3 (24)
    cmp ecx, 1
    je .Llpcm_bd_size
    cmp ecx, 3
    jne .Llpcm_bd_return
    dec ecx
.Llpcm_bd_size:
    inc ecx                               # bytes per sample
    imul edx, ecx
    mov [rip + lpcm_frame], edx
    mov [rip + lpcm_header], r9d
    mov dword ptr [rip + lpcm_seen], 1
    jmp .Llpcm_bd_append
.Llpcm_bd_compare:
    mov eax, 2
    cmp r9d, [rip + lpcm_header]
    jne .Llpcm_bd_return                  # a format change
.Llpcm_bd_append:
    mov rax, [rip + mts_bytes]
    mov [rip + lpcm_pes], rax
    lea rcx, [rbx + 4]
    mov rdx, rsi
    sub rdx, rcx
    call mts_append
.Llpcm_bd_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN lpcm_bluray_packet

# -> EAX=2 with RCX..RDX a Wave64 image of the gathered samples as
# little-endian PCM (it replaces the gather buffer), else 0 (decode_error
# set when malformed).
# Locals: 32 channels, 36 output bytes per sample, 40 valid bits, 44 mask,
# 48 rate, 52 output channels, 56 source frame bytes, 64 frames.
FN lpcm_image
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 88
    cmp dword ptr [rip + lpcm_seen], 0
    je .Llpcm_image_bad
    cmp dword ptr [rip + lpcm_kind], LPCM_BLURAY
    je .Llpcm_image_bluray
    # DVD: the format from the header.
    mov eax, [rip + lpcm_header]
    mov ecx, eax
    and ecx, 7
    inc ecx
    mov [rsp + 32], ecx                   # channels
    mov [rsp + 52], ecx
    lea rdx, [rip + lpcm_dvd_masks]
    mov edx, [rdx + rcx*4 - 4]
    mov [rsp + 44], edx
    mov edx, eax
    shr edx, 4
    and edx, 3
    lea r8, [rip + lpcm_dvd_rates]
    mov edx, [r8 + rdx*4]
    mov [rsp + 48], edx
    shr eax, 6                            # 0, 1, 2: 16, 20, 24 bits
    lea edx, [rax*4 + 16]
    mov [rsp + 40], edx
    mov r12d, eax                         # sample size code
    # Block bytes (FFmpeg's): channels * 2 at 16 bits; at 20 and 24 bits,
    # 4 samples (1, 2 or 4 channels), 8 (8 channels) or 4 * channels.
    mov eax, ecx
    shl eax, 1
    mov r13d, 1                           # frames per block
    test r12d, r12d
    jz .Llpcm_dvd_block
    mov eax, 4                            # samples per block
    cmp ecx, 1
    je .Llpcm_dvd_samples
    cmp ecx, 2
    je .Llpcm_dvd_samples
    cmp ecx, 4
    je .Llpcm_dvd_samples
    mov eax, 8
    cmp ecx, 8
    je .Llpcm_dvd_samples
    lea eax, [rcx*4]
.Llpcm_dvd_samples:
    xor edx, edx
    mov r13d, eax
    div ecx
    xchg eax, r13d                        # frames per block
    imul eax, [rsp + 40]
    shr eax, 3                            # block bytes
.Llpcm_dvd_block:
    mov r14d, eax
    mov rax, [rip + mts_bytes]
    xor edx, edx
    div r14
    imul rax, r13                         # whole blocks' frames
    mov [rsp + 64], rax
    mov eax, 3
    test r12d, r12d
    jnz .Llpcm_image_alloc
    mov eax, 2
    jmp .Llpcm_image_alloc
.Llpcm_image_bluray:
    call lpcm_bluray_end
    mov eax, [rip + lpcm_header]
    mov ecx, eax
    shr ecx, 12
    shl ecx, 4
    lea rbx, [rip + lpcm_bd_layouts]
    add rbx, rcx                          # this assignment's row
    movzx ecx, byte ptr [rbx]
    mov [rsp + 32], ecx                   # source channels
    movzx ecx, byte ptr [rbx + 1]
    mov [rsp + 52], ecx
    mov ecx, [rbx + 4]
    mov [rsp + 44], ecx
    mov ecx, eax
    shr ecx, 8
    and ecx, 15
    mov edx, 48000
    cmp ecx, 4
    jne .Llpcm_bd_image_rate
    mov edx, 96000
.Llpcm_bd_image_rate:
    cmp ecx, 5
    jne .Llpcm_bd_image_rate_set
    mov edx, 192000
.Llpcm_bd_image_rate_set:
    mov [rsp + 48], edx
    mov ecx, [rip + lpcm_frame]
    mov [rsp + 56], ecx
    mov rax, [rip + mts_bytes]
    xor edx, edx
    div rcx
    mov [rsp + 64], rax
    mov eax, [rip + lpcm_frame]
    xor edx, edx
    div dword ptr [rsp + 32]              # bytes per sample: 2 or 3
    lea ecx, [rax*8]
    mov [rsp + 40], ecx
.Llpcm_image_alloc:
    mov [rsp + 36], eax                   # output bytes per sample
    mov rax, [rsp + 64]
    test rax, rax
    jz .Llpcm_image_bad
    mov ecx, [rsp + 52]
    imul ecx, [rsp + 36]
    imul rax, rcx                         # audio bytes
    mov [rsp + 72], rax
    lea rcx, [rax + 128]
    call mem_alloc
    test rax, rax
    jz .Llpcm_image_bad
    mov rdi, rax
    # The Wave64 header: riff/wave/fmt GUIDs, fmt (WAVE_FORMAT_EXTENSIBLE),
    # data GUID.
    lea rsi, [rip + avi_w64_header]
    mov rcx, rdi
    mov edx, 56
.Llpcm_header_copy:
    mov al, [rsi]
    mov [rcx], al
    inc rsi
    inc rcx
    dec edx
    jnz .Llpcm_header_copy
    mov rax, [rsp + 72]
    lea rdx, [rax + 128]
    mov [rdi + 16], rdx                   # image bytes
    mov qword ptr [rdi + 56], 64          # fmt chunk bytes
    mov word ptr [rdi + 64], 0xfffe
    mov ecx, [rsp + 52]
    mov [rdi + 66], cx                    # channels
    mov edx, [rsp + 48]
    mov [rdi + 68], edx                   # rate
    imul ecx, [rsp + 36]
    mov [rdi + 76], cx                    # block alignment
    imul ecx, edx
    mov [rdi + 72], ecx                   # bytes per second
    mov eax, [rsp + 36]
    shl eax, 3
    mov [rdi + 78], ax                    # container bits
    mov word ptr [rdi + 80], 22
    mov eax, [rsp + 40]
    mov [rdi + 82], ax                    # valid bits
    mov eax, [rsp + 44]
    mov [rdi + 84], eax                   # channel mask
    mov word ptr [rdi + 88], 1            # PCM
    lea rsi, [rip + lpcm_pcm_guid]
    lea rcx, [rdi + 90]
    mov edx, 14
.Llpcm_guid_copy:
    mov al, [rsi]
    mov [rcx], al
    inc rsi
    inc rcx
    dec edx
    jnz .Llpcm_guid_copy
    lea rsi, [rip + avi_w64_data]
    mov rax, [rsi]
    mov [rdi + 104], rax
    mov rax, [rsi + 8]
    mov [rdi + 112], rax
    mov rax, [rsp + 72]
    add rax, 24
    mov [rdi + 120], rax                  # data chunk bytes
    # The samples.
    mov rsi, [rip + mts_buffer]
    lea r8, [rdi + 128]
    cmp dword ptr [rip + lpcm_kind], LPCM_BLURAY
    je .Llpcm_convert_bluray
    mov rax, [rsp + 64]
    mov ecx, [rsp + 32]
    imul rax, rcx                         # samples
    test r12d, r12d
    jnz .Llpcm_convert_groups
.Llpcm_convert_16:
    movzx ecx, word ptr [rsi]
    xchg cl, ch
    mov [r8], cx
    add rsi, 2
    add r8, 2
    dec rax
    jnz .Llpcm_convert_16
    jmp .Llpcm_image_done
.Llpcm_convert_groups:
    # Groups of G samples (G = 2 in mono, else 4): G top words, then the
    # low bytes (24 bits) or nibble pairs (20 bits).
    mov r9d, 4
    cmp dword ptr [rsp + 32], 1
    jne .Llpcm_group_size
    mov r9d, 2
.Llpcm_group_size:
    xor edx, edx
    div r9                                # groups
    mov r10, rax
.Llpcm_group:
    xor ecx, ecx
.Llpcm_group_sample:
    movzx eax, byte ptr [rsi + rcx*2]     # top byte
    mov [r8 + 2], al
    movzx eax, byte ptr [rsi + rcx*2 + 1]
    mov [r8 + 1], al
    lea r11, [rsi + r9*2]                 # the low parts
    cmp r12d, 2
    je .Llpcm_group_24
    mov edx, ecx
    shr edx, 1
    movzx eax, byte ptr [r11 + rdx]       # two 4-bit low parts
    test ecx, 1
    jz .Llpcm_group_20_first
    shl eax, 4
.Llpcm_group_20_first:
    and eax, 0xf0
    jmp .Llpcm_group_low
.Llpcm_group_24:
    movzx eax, byte ptr [r11 + rcx]
.Llpcm_group_low:
    mov [r8], al
    add r8, 3
    inc ecx
    cmp ecx, r9d
    jb .Llpcm_group_sample
    # Next group: 2G + G (24 bits) or 2G + G/2 (20 bits) bytes.
    lea rax, [r9*2]
    add rsi, rax
    mov eax, r9d
    cmp r12d, 2
    je .Llpcm_group_next
    shr eax, 1
.Llpcm_group_next:
    add rsi, rax
    dec r10
    jnz .Llpcm_group
    jmp .Llpcm_image_done
.Llpcm_convert_bluray:
    mov r10, [rsp + 64]                   # frames
    mov r13d, [rsp + 36]                  # bytes per sample
    mov r14d, [rsp + 52]                  # output channels
.Llpcm_bd_frame:
    xor ecx, ecx
.Llpcm_bd_channel:
    movzx edx, byte ptr [rbx + rcx + 8]   # output index
    cmp edx, 255
    je .Llpcm_bd_next
    imul edx, r13d
    lea r11, [r8 + rdx]
    cmp r13d, 2
    je .Llpcm_bd_16
    movzx eax, byte ptr [rsi]
    mov [r11 + 2], al
    movzx eax, byte ptr [rsi + 1]
    mov [r11 + 1], al
    movzx eax, byte ptr [rsi + 2]
    mov [r11], al
    jmp .Llpcm_bd_next
.Llpcm_bd_16:
    movzx eax, byte ptr [rsi]
    mov [r11 + 1], al
    movzx eax, byte ptr [rsi + 1]
    mov [r11], al
.Llpcm_bd_next:
    add rsi, r13
    inc ecx
    cmp ecx, [rsp + 32]
    jb .Llpcm_bd_channel
    mov eax, r14d
    imul eax, r13d
    add r8, rax
    dec r10
    jnz .Llpcm_bd_frame
.Llpcm_image_done:
    # The image replaces the gathered samples.
    mov rcx, [rip + mts_buffer]
    call mem_free
    mov [rip + mts_buffer], rdi
    mov rax, [rsp + 72]
    add rax, 128
    mov [rip + mts_bytes], rax
    mov rcx, rdi
    lea rdx, [rdi + rax]
    mov eax, 2
    jmp .Llpcm_image_return
.Llpcm_image_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Llpcm_image_failed
    mov dword ptr [rip + decode_error], 100
.Llpcm_image_failed:
    xor eax, eax
.Llpcm_image_return:
    add rsp, 88
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN lpcm_image
