# Original FLV audio demuxer in x86-64 assembly. MIT, see LICENSE.
# Adobe's Flash Video format (FLV version 1, Video File Format
# Specification version 10.1, annex E): a 9-byte header, then tags (type,
# 24-bit size, timestamp, stream id, data, previous tag size). The audio
# tags of the first audio tag's sound format are read in file order; video,
# script data and audio of another format are skipped, as are encrypted
# tags. PCM (8-bit unsigned, 16-bit little-endian), G.711 and MP3 tag data
# is gathered without changing byte order, then split into packet views; AAC
# raw frames (after the AudioSpecificConfig of the first sequence header)
# and Flash ADPCM/Speex tags are track packets.
.include "lamp.inc"
.globl flv_open

.equ FLV_MALFORMED, 100
.equ FLV_UNSUPPORTED, 101
.equ TK_AAC, 7
.equ TK_PCM, 1
.equ TK_MPA, 3
.equ TK_ADPCM, 10
.equ TK_SPEEX, 11
.equ ADPCM_SWF, 0x5346
.equ FLV_IMAGE, 0
.equ FLV_AAC, 1
.equ FLV_ADPCM, 2
.equ FLV_SPEEX, 3
.equ FLV_PACKET_MAX, 65535          # Flash ADPCM tag data (a WAVE block size)

RODATA
# FLV sound format11 has no codec header: WB,16kHz,mono. The low audio
# flags are ignored, including FFmpeg's legacy11kHz rate flag. Packet frame
# counts come from the bitstream, not this synthetic header's nominal1.
flv_speex_header:
    .ascii "Speex   lamp"
    .zero 16
    .long 1,80,16000,1,4,1,-1,320,0,1,0,0,0

.data
flv_file: .quad 0
flv_end: .quad 0
flv_flags: .long 0                  # the first audio tag's flags byte
flv_mode: .long 0
flv_started: .long 0
flv_config: .quad 0                 # AAC AudioSpecificConfig
flv_config_bytes: .long 0
flv_largest: .long 0                # largest Flash ADPCM packet
flv_timestamp: .long 0              # complete signed millisecond tag clock
flv_stamp_ns: .quad 0               # next owned frame, including a continuation
flv_last_samples: .long 0
flv_trim_start: .long 0
flv_trim_end: .long 0
.p2align 2
flv_fmt: .zero 16                   # gathered PCM/G.711 or Flash ADPCM configuration

.text
# -> EAX=1 when the open was cancelled.
LOCALFN flv_cancelled
    xor eax, eax
    mov rcx, [rip + ogg_cancel_ptr]
    test rcx, rcx
    jz .Lflv_cancelled_return
    cmp dword ptr [rcx], 0
    setne al
.Lflv_cancelled_return:
    ret
ENDFN flv_cancelled

# ECX=flags of the first audio tag: chooses the stream's handling -> EAX=1,
# 0 with decode_error set.
LOCALFN flv_start
    push rbx
    sub rsp, 32
    mov ebx, ecx
    mov [rip + flv_flags], ecx
    mov dword ptr [rip + flv_started], 1
    lea r8, [rip + flv_fmt]
    mov eax, ecx
    and eax, 1
    inc eax
    mov [r8 + 2], ax                      # channels
    mov eax, 44100
    mov ecx, ebx
    shr ecx, 2
    and ecx, 3
    shl eax, cl
    shr eax, 3                            # 5512, 11025, 22050, 44100 Hz
    mov [r8 + 4], eax
    mov eax, ebx
    and eax, 2
    lea eax, [rax*4 + 8]                  # 8 or 16 bits
    mov [r8 + 14], ax
    mov eax, ebx
    shr eax, 4                            # sound format
    cmp eax, 0                            # PCM in the platform's (little) byte order
    je .Lflv_start_pcm
    cmp eax, 3                            # PCM, little-endian
    je .Lflv_start_pcm
    cmp eax, 7
    je .Lflv_start_alaw
    cmp eax, 8
    je .Lflv_start_ulaw
    cmp eax, 2
    je .Lflv_start_mp3
    cmp eax, 14                           # MP3 at 8 kHz
    je .Lflv_start_mp3
    cmp eax, 10
    je .Lflv_start_aac
    cmp eax, 1
    je .Lflv_start_adpcm
    cmp eax, 11
    je .Lflv_start_speex
    jmp .Lflv_start_unsupported           # Nellymoser and others
.Lflv_start_alaw:
    mov word ptr [r8], 6
    jmp .Lflv_start_g711
.Lflv_start_ulaw:
    mov word ptr [r8], 7
.Lflv_start_g711:
    mov dword ptr [r8 + 4], 8000
    mov word ptr [r8 + 14], 8
    jmp .Lflv_start_frames
.Lflv_start_pcm:
    mov word ptr [r8], 1
    cmp dword ptr [r8 + 4], 8000
    jb .Lflv_start_unsupported            # 5.5 kHz
.Lflv_start_frames:
    movzx eax, word ptr [r8 + 14]
    shr eax, 3
    movzx ecx, word ptr [r8 + 2]
    imul eax, ecx
    mov [r8 + 12], ax                     # block alignment
    imul eax, [r8 + 4]
    mov [r8 + 8], eax                     # bytes per second
    jmp .Lflv_start_image
.Lflv_start_mp3:
    mov word ptr [r8], 0x55
    mov word ptr [r8 + 12], 1
    mov word ptr [r8 + 14], 0
.Lflv_start_image:
    mov dword ptr [rip + flv_mode], FLV_IMAGE
    mov rcx, [rip + flv_end]
    sub rcx, [rip + flv_file]
    call mts_begin
    jmp .Lflv_start_return
.Lflv_start_aac:
    mov dword ptr [rip + flv_mode], FLV_AAC
    mov ecx, TK_AAC
    call track_begin
    jmp .Lflv_start_timed
.Lflv_start_adpcm:
    mov word ptr [r8], ADPCM_SWF
    mov word ptr [r8 + 14], 4
    cmp dword ptr [r8 + 4], 8000
    jb .Lflv_start_unsupported
    mov dword ptr [rip + flv_mode], FLV_ADPCM
    mov ecx, TK_ADPCM
    call track_begin
    jmp .Lflv_start_timed
.Lflv_start_speex:
    mov dword ptr [rip + flv_mode], FLV_SPEEX
    mov ecx, TK_SPEEX
    call track_begin
    jmp .Lflv_start_timed
.Lflv_start_timed:
    test eax, eax
    jz .Lflv_start_return
    mov dword ptr [rip + track_time_enabled], 1
    mov qword ptr [rip + track_time_scale_ns], 1000000
    jmp .Lflv_start_return
.Lflv_start_unsupported:
    mov dword ptr [rip + decode_error], FLV_UNSUPPORTED
    xor eax, eax
.Lflv_start_return:
    add rsp, 32
    pop rbx
    ret
ENDFN flv_start

# RCX=payload, EDX=bytes ->1/0. Only accepted complete audio packets own
# timestamps; sequence headers and skipped/encrypted tags do not anchor PCM.
LOCALFN flv_add_packet
    sub rsp, 40
    call track_add
    test eax, eax
    jz .Lflv_add_return
    mov rcx, [rip + track_count]
    dec rcx
    mov edx, [rip + flv_timestamp]
    call track_time_mark_signed
.Lflv_add_return:
    add rsp, 40
    ret
ENDFN flv_add_packet

# RCX=audio tag data, RDX=bytes (at least 1), R8D=1 when the file ends
# inside it -> EAX=1, 0 on failure.
LOCALFN flv_audio
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ebx, r8d
    movzx ecx, byte ptr [rsi]
    cmp dword ptr [rip + flv_started], 0
    jne .Lflv_audio_format
    call flv_start
    test eax, eax
    jz .Lflv_audio_return
    movzx ecx, byte ptr [rsi]
.Lflv_audio_format:
    mov eax, 1
    mov edx, [rip + flv_flags]
    xor edx, ecx
    test edx, 0xf0
    jnz .Lflv_audio_return                # another sound format
    cmp dword ptr [rip + flv_mode], FLV_AAC
    je .Lflv_audio_aac
    cmp dword ptr [rip + flv_mode], FLV_ADPCM
    je .Lflv_audio_adpcm
    cmp dword ptr [rip + flv_mode], FLV_SPEEX
    je .Lflv_audio_speex
    mov ecx, [rip + flv_flags]
    shr ecx, 4
    cmp ecx, 2
    je .Lflv_audio_gather
    cmp ecx, 14
    je .Lflv_audio_gather
    test edx, edx
    jnz .Lflv_audio_return                # PCM of another rate or layout
.Lflv_audio_gather:
    lea rcx, [rsi + 1]
    lea rdx, [rdi - 1]
    call mts_append
    jmp .Lflv_audio_return
.Lflv_audio_aac:
    cmp rdi, 2
    jbe .Lflv_audio_return
    cmp byte ptr [rsi + 1], 0
    jne .Lflv_audio_frame
    cmp qword ptr [rip + flv_config], 0
    jne .Lflv_audio_return                # the first sequence header holds
    test ebx, ebx
    jnz .Lflv_audio_return
    lea rax, [rsi + 2]
    mov [rip + flv_config], rax
    lea eax, [rdi - 2]
    mov [rip + flv_config_bytes], eax
    mov eax, 1
    jmp .Lflv_audio_return
.Lflv_audio_frame:
    cmp byte ptr [rsi + 1], 1
    jne .Lflv_audio_return
    cmp qword ptr [rip + flv_config], 0
    je .Lflv_audio_return                 # frames before the configuration
    test ebx, ebx
    jnz .Lflv_audio_return                # a truncated frame
    lea rcx, [rsi + 2]
    lea edx, [rdi - 2]
    call flv_add_packet
    jmp .Lflv_audio_return
.Lflv_audio_adpcm:
    test edx, edx
    jnz .Lflv_audio_return
    test ebx, ebx
    jnz .Lflv_audio_return
    lea rdx, [rdi - 1]
    cmp rdx, FLV_PACKET_MAX
    ja .Lflv_audio_unsupported
    # At least the code size and one block header per channel.
    lea r8, [rdx*8 - 2]
    movzx ecx, word ptr [rip + flv_fmt + 2]
    imul ecx, ecx, 22
    cmp r8, rcx
    jb .Lflv_audio_return
    cmp edx, [rip + flv_largest]
    jbe .Lflv_audio_packet
    mov [rip + flv_largest], edx
.Lflv_audio_packet:
    lea rcx, [rsi + 1]
    call flv_add_packet
    jmp .Lflv_audio_return
.Lflv_audio_speex:
    test ebx, ebx
    jnz .Lflv_audio_return                # discard an incomplete final tag
    cmp rdi, 1
    jbe .Lflv_audio_return
    lea rdx, [rdi - 1]
    cmp rdx, 1048576
    ja .Lflv_audio_unsupported
    jmp .Lflv_audio_packet
.Lflv_audio_unsupported:
    mov dword ptr [rip + decode_error], FLV_UNSUPPORTED
    xor eax, eax
.Lflv_audio_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flv_audio

# Revisit accepted byte fragments after gathering. A sample/MPEG frame
# belongs to the tag containing its first byte. It may finish in a later
# tag; no bytes are lost, duplicated, or interpreted as separate frames.
# Continuation-only tags own no new frame. A continuation with a new frame
# advances that frame's tag clock by the preceding frame's full duration.
LOCALFN flv_gathered_finish
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    mov dword ptr [rip + flv_last_samples], 0
    cmp word ptr [rip + flv_fmt], 0x55
    jne .Lflv_views_pcm
    mov rcx, [rip + mts_buffer]
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    call mp3_open                       # existing metadata/trim/structure rules
    test eax, eax
    jz .Lflv_views_bad
    call mp3_stream_layout
    mov r14, rax
    mov r15, rdx
    mov [rip + flv_trim_start], r8d
    mov [rip + flv_trim_end], r9d
    call mp3_close                      # packet views replace the native index
    mov ecx, TK_MPA
    call track_begin
    test eax, eax
    jz .Lflv_views_bad
    mov eax, [rip + flv_trim_start]
    mov [rip + track_start_trim], rax
    mov eax, [rip + flv_trim_end]
    mov [rip + track_end_trim], rax
    jmp .Lflv_views_ready
.Lflv_views_pcm:
    mov ecx, TK_PCM
    call track_begin
    test eax, eax
    jz .Lflv_views_bad
    mov eax, [rip + flv_fmt + 4]
    mov [rip + sample_rate], eax
    movzx eax, word ptr [rip + flv_fmt + 2]
    mov [rip + track_pcm_channels], eax
    movzx eax, word ptr [rip + flv_fmt + 14]
    mov [rip + track_pcm_bits], eax
    xor eax, eax
    cmp word ptr [rip + flv_fmt], 6
    jne .Lflv_views_ulaw
    mov eax, 8
.Lflv_views_ulaw:
    cmp word ptr [rip + flv_fmt], 7
    jne .Lflv_views_pcm_flags
    mov eax, 16
.Lflv_views_pcm_flags:
    mov [rip + track_pcm_flags], eax
    mov rax, [rip + mts_bytes]
    xor edx, edx
    movzx ecx, word ptr [rip + flv_fmt + 12]
    div rcx
    mov r15, [rip + mts_bytes]
    sub r15, rdx                       # discard only an incomplete final sample
    xor r14d, r14d                     # next unowned PCM byte
.Lflv_views_ready:
    mov dword ptr [rip + track_time_enabled], 1
    mov qword ptr [rip + track_time_scale_ns], 1000000
    mov rsi, [rip + flv_file]
    mov rdi, [rip + flv_end]
    mov eax, [rsi + 5]
    bswap eax
    lea r12, [rsi + rax + 4]
    xor r13d, r13d                     # accepted gathered bytes through this tag
.Lflv_views_tag:
    call flv_cancelled
    test eax, eax
    jnz .Lflv_views_bad
    mov rax, rdi
    sub rax, r12
    cmp rax, 11
    jl .Lflv_views_done
    sub rax, 11
    mov ebx, [r12]
    bswap ebx
    and ebx, 0xffffff
    mov dword ptr [rsp+32], 0
    cmp rbx, rax
    jbe .Lflv_views_sized
    mov rbx, rax
    mov dword ptr [rsp+32], 1
.Lflv_views_sized:
    movzx eax, byte ptr [r12]
    and eax, 0x3f
    cmp eax, 8
    jne .Lflv_views_next
    test rbx, rbx
    jz .Lflv_views_next
    movzx eax, byte ptr [r12+11]
    xor eax, [rip + flv_flags]
    test eax, 0xf0
    jnz .Lflv_views_next
    cmp word ptr [rip + flv_fmt], 0x55
    je .Lflv_views_accept
    test eax, eax
    jnz .Lflv_views_next
.Lflv_views_accept:
    mov [rsp+56], r13                  # original tag byte start
    lea rax, [r13 + rbx - 1]
    cmp rax, [rip + mts_bytes]
    ja .Lflv_views_bad
    mov r13, rax
    mov rax, [rip + track_count]
    mov [rsp+40], rax                  # first packet this tag will own
    mov eax, [r12+4]
    bswap eax
    ror eax, 8
    movsxd rax, eax
    imul rax, rax, 1000000
    mov [rip + flv_stamp_ns], rax
    cmp word ptr [rip + flv_fmt], 0x55
    je .Lflv_views_mpa
    movzx ecx, word ptr [rip + flv_fmt + 12]
    mov rax, [rsp+56]
    xor edx, edx
    div rcx
    test edx, edx
    jz .Lflv_views_pcm_end
    mov ecx, 1
    call flv_stamp_advance
.Lflv_views_pcm_end:
    movzx ecx, word ptr [rip + flv_fmt + 12]
    lea rax, [r13 + rcx - 1]
    xor edx, edx
    div rcx
    imul rax, rcx
    cmp rax, r15
    cmova rax, r15
    mov [rsp+48], rax
.Lflv_views_pcm_packet:
    cmp r14, [rsp+48]
    jae .Lflv_views_mark
    call flv_cancelled
    test eax, eax
    jnz .Lflv_views_bad
    mov rdx, [rsp+48]
    sub rdx, r14
    movzx eax, word ptr [rip + flv_fmt + 12]
    shl eax, 18                       # existing packet PCM capacity
    cmp rdx, rax
    cmova rdx, rax
    mov [rsp+64], rdx
    mov rcx, [rip + mts_buffer]
    add rcx, r14
    call track_add
    test eax, eax
    jz .Lflv_views_bad
    add r14, [rsp+64]
    jmp .Lflv_views_pcm_packet
.Lflv_views_mpa:
    mov rax, [rip + mts_buffer]
    add rax, [rsp+56]
    cmp r14, rax
    jbe .Lflv_views_mpa_end
    mov ecx, [rip + flv_last_samples]
    test ecx, ecx
    jz .Lflv_views_mpa_end
    call flv_stamp_advance
.Lflv_views_mpa_end:
    mov rax, [rip + mts_buffer]
    add rax, r13
    mov [rsp+48], rax
.Lflv_views_mpa_packet:
    cmp r14, [rsp+48]
    jae .Lflv_views_mark
    cmp r14, r15
    jae .Lflv_views_mark
    call flv_cancelled
    test eax, eax
    jnz .Lflv_views_bad
    mov rax, r15
    sub rax, r14
    cmp rax, 128
    jne .Lflv_views_mpa_frame
    cmp word ptr [r14], 0x4154
    jne .Lflv_views_mpa_frame
    cmp byte ptr [r14+2], 'G'
    jne .Lflv_views_mpa_frame
    mov r14, r15                       # native ID3v1 trailer, not audio
    jmp .Lflv_views_mark
.Lflv_views_mpa_frame:
    mov rcx, r14
    mov rdx, r15
    call mpa_frame_bytes
    test eax, eax
    jz .Lflv_views_bad
    mov [rsp+64], rax
    mov eax, [rip + mp_samples]
    mov [rip + flv_last_samples], eax
    mov rcx, r14
    mov edx, [rsp+64]
    call track_add
    test eax, eax
    jz .Lflv_views_bad
    add r14, [rsp+64]
    jmp .Lflv_views_mpa_packet
.Lflv_views_mark:
    mov rcx, [rsp+40]
    cmp rcx, [rip + track_count]
    jae .Lflv_views_next
    mov rdx, [rip + flv_stamp_ns]
    call track_time_mark_ns
    test eax, eax
    jz .Lflv_views_bad
.Lflv_views_next:
    cmp dword ptr [rsp+32], 0
    jne .Lflv_views_done
    lea r12, [r12 + rbx + 15]
    jmp .Lflv_views_tag
.Lflv_views_done:
    cmp r13, [rip + mts_bytes]
    jne .Lflv_views_bad
    call track_finish
    test eax, eax
    jz .Lflv_views_bad
    mov dword ptr [rip + codec_kind], 15
    cmp word ptr [rip + flv_fmt], 0x55
    jne .Lflv_views_ok
    mov dword ptr [rip + codec_kind], 3
.Lflv_views_ok:
    mov eax, 1
    jmp .Lflv_views_return
.Lflv_views_bad:
    call mp3_close
    xor eax, eax
.Lflv_views_return:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flv_gathered_finish

# ECX=samples before the tag's next newly owned frame. Nanosecond precision
# avoids overflowing a signed millisecond field at its positive boundary.
LOCALFN flv_stamp_advance
    mov eax, ecx
    mov ecx, 1000000000
    mul rcx
    mov ecx, [rip + sample_rate]
    mov r8d, ecx
    shr r8d, 1
    add rax, r8
    adc rdx, 0
    div rcx
    add [rip + flv_stamp_ns], rax
    ret
ENDFN flv_stamp_advance

# RCX=mapped start ("FLV", version 1), RDX=end -> EAX=1 with the packet
# stream open, or 0 with decode_error set.
FN flv_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    mov [rip + flv_file], rcx
    mov [rip + flv_end], rdx
    xor eax, eax
    mov [rip + flv_started], eax
    mov [rip + flv_config], rax
    mov [rip + flv_config_bytes], eax
    mov [rip + flv_largest], eax
    mov [rip + flv_fmt], rax
    mov [rip + flv_fmt + 8], rax
    mov rax, rdi
    sub rax, rsi
    cmp rax, 13
    jb .Lflv_open_bad
    mov eax, [rsi + 5]
    bswap eax                             # header size
    cmp eax, 9
    jb .Lflv_open_bad
    lea r12, [rsi + rax + 4]              # past the first previous tag size
.Lflv_open_tag:
    call flv_cancelled
    test eax, eax
    jnz .Lflv_open_bad
    mov rax, rdi
    sub rax, r12
    cmp rax, 11
    jl .Lflv_open_done
    sub rax, 11                           # data bytes present
    mov ebx, [r12]
    bswap ebx
    and ebx, 0xffffff                     # data size
    xor r8d, r8d
    cmp rbx, rax
    jbe .Lflv_open_sized
    mov rbx, rax                          # the file ends inside this tag
    mov r8d, 1
.Lflv_open_sized:
    movzx eax, byte ptr [r12]
    and eax, 0x3f                         # type and the encryption filter bit
    cmp eax, 8
    jne .Lflv_open_next
    test rbx, rbx
    jz .Lflv_open_next
    lea rcx, [r12 + 11]
    mov rdx, rbx
    mov eax, [r12 + 4]
    bswap eax
    ror eax, 8                           # upper eight bits are TimestampExtended
    mov [rip + flv_timestamp], eax
    mov [rsp + 32], r8d
    call flv_audio
    test eax, eax
    jz .Lflv_open_bad
    mov r8d, [rsp + 32]
.Lflv_open_next:
    test r8d, r8d
    jnz .Lflv_open_done
    lea r12, [r12 + rbx + 15]             # header, data, previous tag size
    jmp .Lflv_open_tag
.Lflv_open_done:
    cmp dword ptr [rip + flv_started], 0
    jne .Lflv_open_finish
    mov dword ptr [rip + decode_error], FLV_UNSUPPORTED  # no audio LAMP decodes
    jmp .Lflv_open_bad
.Lflv_open_finish:
    mov eax, [rip + flv_mode]
    cmp eax, FLV_AAC
    je .Lflv_open_aac
    cmp eax, FLV_ADPCM
    je .Lflv_open_adpcm
    cmp eax, FLV_SPEEX
    je .Lflv_open_speex
    call flv_gathered_finish
    test eax, eax
    jz .Lflv_open_bad
    jmp .Lflv_open_return
.Lflv_open_aac:
    cmp qword ptr [rip + flv_config], 0
    je .Lflv_open_bad
    cmp qword ptr [rip + track_count], 0
    je .Lflv_open_bad
    mov rax, [rip + flv_config]
    mov [rip + track_config], rax
    mov eax, [rip + flv_config_bytes]
    mov [rip + track_config_bytes], eax
    call track_finish
    test eax, eax
    jz .Lflv_open_failed
    mov dword ptr [rip + codec_kind], 10
    mov eax, 1
    jmp .Lflv_open_return
.Lflv_open_adpcm:
    cmp qword ptr [rip + track_count], 0
    je .Lflv_open_bad
    mov eax, [rip + flv_largest]
    mov [rip + flv_fmt + 12], ax
    lea rax, [rip + flv_fmt]
    mov [rip + track_config], rax
    mov dword ptr [rip + track_config_bytes], 16
    call track_finish
    test eax, eax
    jz .Lflv_open_failed
    mov dword ptr [rip + codec_kind], 15
    mov eax, 1
    jmp .Lflv_open_return
.Lflv_open_speex:
    cmp qword ptr [rip + track_count], 0
    je .Lflv_open_bad
    lea rax, [rip + flv_speex_header]
    mov [rip + track_config], rax
    mov dword ptr [rip + track_config_bytes], 80
    call track_finish
    test eax, eax
    jz .Lflv_open_failed
    mov dword ptr [rip + codec_kind], 22
    mov eax, 1
    jmp .Lflv_open_return
.Lflv_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lflv_open_failed
    mov dword ptr [rip + decode_error], FLV_MALFORMED
.Lflv_open_failed:
    call track_close
    call mts_close
    xor eax, eax
.Lflv_open_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flv_open
