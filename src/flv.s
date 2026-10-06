# Original FLV audio demuxer in x86-64 assembly. MIT, see LICENSE.
# Adobe's Flash Video format (FLV version 1, Video File Format
# Specification version 10.1, annex E): a 9-byte header, then tags (type,
# 24-bit size, timestamp, stream id, data, previous tag size). The audio
# tags of the first audio tag's sound format are read in file order; video,
# script data and audio of another format are skipped, as are encrypted
# tags. PCM (8-bit unsigned, 16-bit little-endian), G.711 and MP3 tag data
# is gathered behind a Wave64 header for the WAV reader, as AVI's is; AAC
# raw frames (after the AudioSpecificConfig of the first sequence header)
# and Flash ADPCM tags are track packets.
.include "lamp.inc"
.globl flv_open

.equ FLV_MALFORMED, 100
.equ FLV_UNSUPPORTED, 101
.equ TK_AAC, 7
.equ TK_ADPCM, 10
.equ ADPCM_SWF, 0x5346
.equ FLV_IMAGE, 0
.equ FLV_AAC, 1
.equ FLV_ADPCM, 2
.equ FLV_PACKET_MAX, 65535          # Flash ADPCM tag data (a WAVE block size)

.data
flv_file: .quad 0
flv_end: .quad 0
flv_flags: .long 0                  # the first audio tag's flags byte
flv_mode: .long 0
flv_started: .long 0
flv_config: .quad 0                 # AAC AudioSpecificConfig
flv_config_bytes: .long 0
flv_largest: .long 0                # largest Flash ADPCM packet
.p2align 2
flv_fmt: .zero 16                   # WAVE format: the image's or the ADPCM track's

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
    jmp .Lflv_start_unsupported           # Nellymoser, Speex and others
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
    lea rcx, [rip + flv_fmt]
    mov edx, 16
    mov r8, [rip + flv_end]
    sub r8, [rip + flv_file]
    call wav_image_begin
    jmp .Lflv_start_return
.Lflv_start_aac:
    mov dword ptr [rip + flv_mode], FLV_AAC
    mov ecx, TK_AAC
    call track_begin
    jmp .Lflv_start_return
.Lflv_start_adpcm:
    mov word ptr [r8], ADPCM_SWF
    mov word ptr [r8 + 14], 4
    cmp dword ptr [r8 + 4], 8000
    jb .Lflv_start_unsupported
    mov dword ptr [rip + flv_mode], FLV_ADPCM
    mov ecx, TK_ADPCM
    call track_begin
    jmp .Lflv_start_return
.Lflv_start_unsupported:
    mov dword ptr [rip + decode_error], FLV_UNSUPPORTED
    xor eax, eax
.Lflv_start_return:
    add rsp, 32
    pop rbx
    ret
ENDFN flv_start

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
    call track_add
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
    call track_add
    jmp .Lflv_audio_return
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

# RCX=mapped start ("FLV", version 1), RDX=end -> EAX=1 with the stream open
# (AAC, Flash ADPCM), EAX=2 with RCX..RDX a Wave64 image for the WAV reader,
# or 0 with decode_error set.
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
    xor ecx, ecx
    cmp word ptr [rip + flv_fmt], 0x55
    je .Lflv_open_image
    movzx ecx, word ptr [rip + flv_fmt + 12]  # whole PCM frames
.Lflv_open_image:
    call wav_image_end
    mov eax, 2
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
