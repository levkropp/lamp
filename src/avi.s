# Original AVI audio demuxer in x86-64 assembly. MIT, see LICENSE.
# Microsoft's AVI RIFF format with the OpenDML extensions: hdrl's stream
# lists (strh, strf) choose the first audio stream whose WAVE format LAMP
# decodes (or the audio stream that track_choice numbers), and its "NNwb" chunks are read from LIST movi (and LIST rec
# groups) in the first RIFF AVI and the RIFF AVIX lists after it. The
# indexes (idx1, indx, ix##) are not needed. AVI audio is a byte stream cut
# into chunks, so the chunks are gathered behind a Wave64 header holding the
# stream's format, and the WAV reader opens that image: PCM, float, G.711,
# IMA and Microsoft ADPCM, MPEG audio and AC-3 decode as they do in WAV.
# AAC chunks (WAVE tag 0xFF) are whole frames: with an AudioSpecificConfig
# in the format they become track packets, without one they are gathered and
# open as ADTS. Video and other streams are skipped.
.include "lamp.inc"
.globl avi_open, avi_format, wav_image_begin, wav_image_end
.globl avi_w64_header, avi_w64_data   # LPCM builds its Wave64 images with them

.equ AVI_MALFORMED, 100
.equ AVI_UNSUPPORTED, 101
.equ TK_AAC, 7
.equ AVI_IMAGE, 0                   # gathered into a Wave64 image
.equ AVI_PACKETS, 1                 # AAC frames as track packets
.equ AVI_ADTS, 2                    # AAC frames gathered as ADTS

RODATA
# Wave64 "riff" GUID, size, "wave" GUID, then the "fmt " chunk's GUID.
avi_w64_header:
    .long 0x66666972, 0x11cf912e
    .quad 0x0000c104db28d6a5, 0
    .long 0x65766177, 0x11d3acf3
    .quad 0x8adb8e4fc000d18c
    .long 0x20746d66, 0x11d3acf3
    .quad 0x8adb8e4fc000d18c
avi_w64_data:
    .long 0x61746164, 0x11d3acf3
    .quad 0x8adb8e4fc000d18c
avi_zeros: .quad 0, 0

.data
avi_file: .quad 0                   # mapped file
avi_end: .quad 0
avi_stage: .long 0                  # 0 before hdrl, 1 after it
avi_riffs: .long 0                  # RIFF AVI/AVIX lists read
avi_movis: .long 0                  # movi lists read
avi_stream: .long 0                 # selected stream number, -1 = none
avi_streams: .long 0                # stream lists seen
avi_audio_index: .long 0            # audio stream lists seen
avi_tag: .long 0                    # selected format tag (extensible: its subformat)
avi_mode: .long 0
avi_fmt: .quad 0                    # its strf payload
avi_fmt_bytes: .long 0
avi_id: .long 0                     # its chunk id ("NNwb")
avi_data: .quad 0                   # image offset of the Wave64 data chunk
avi_size: .quad 0                   # Wave64 fmt chunk size

.text
# RCX=chunk, RDX=end of its list -> RAX=payload end (clamped to the list's
# end for a truncated last chunk), RCX=payload, EDX=chunk id; RAX=0 when no
# chunk header fits.
LOCALFN avi_chunk
    mov rax, rdx
    sub rax, rcx
    cmp rax, 8
    jl .Lavi_chunk_none
    sub rax, 8
    mov r8d, [rcx + 4]
    cmp r8, rax
    cmova r8, rax
    mov edx, [rcx]
    add rcx, 8
    lea rax, [rcx + r8]
    ret
.Lavi_chunk_none:
    xor eax, eax
    ret
ENDFN avi_chunk

# RAX=payload end -> RAX=next chunk (word-aligned).
.macro AVI_NEXT
    inc rax
    and rax, -2
.endm

# -> EAX=1 when the open was cancelled.
LOCALFN avi_cancelled
    xor eax, eax
    mov rcx, [rip + ogg_cancel_ptr]
    test rcx, rcx
    jz .Lavi_cancelled_return
    cmp dword ptr [rcx], 0
    setne al
.Lavi_cancelled_return:
    ret
ENDFN avi_cancelled

# RCX=strf payload, RDX=bytes -> EAX=the WAVE tag (an extensible header's
# subformat) when LAMP decodes it, 0 otherwise; EDX=mode.
LOCALFN avi_format
    xor eax, eax
    mov r8d, AVI_IMAGE
    cmp rdx, 16
    jb .Lavi_format_return
    movzx eax, word ptr [rcx]
    cmp eax, 0xfffe
    jne .Lavi_format_tag
    xor eax, eax
    cmp rdx, 40
    jb .Lavi_format_return
    movzx eax, word ptr [rcx + 24]
    cmp eax, 0xff
    je .Lavi_format_none                  # AAC only with its basic tag
.Lavi_format_tag:
    cmp eax, 1
    je .Lavi_format_return
    cmp eax, 3
    je .Lavi_format_return
    cmp eax, 6
    je .Lavi_format_return
    cmp eax, 7
    je .Lavi_format_return
    cmp eax, 2
    je .Lavi_format_return
    cmp eax, 0x11
    je .Lavi_format_return
    cmp eax, 0x61
    je .Lavi_format_return
    cmp eax, 0x62
    je .Lavi_format_return
    cmp eax, 0x50
    je .Lavi_format_return
    cmp eax, 0x55
    je .Lavi_format_return
    cmp eax, 0x2000
    je .Lavi_format_return
    cmp eax, 0xff
    jne .Lavi_format_none
    # AAC: an AudioSpecificConfig after the 18-byte WAVEFORMATEX, or ADTS.
    mov r8d, AVI_ADTS
    cmp rdx, 20
    jb .Lavi_format_return
    movzx r9d, word ptr [rcx + 16]
    cmp r9d, 2
    jb .Lavi_format_return
    add r9d, 18
    cmp r9, rdx
    ja .Lavi_format_return
    mov r8d, AVI_PACKETS
    jmp .Lavi_format_return
.Lavi_format_none:
    xor eax, eax
.Lavi_format_return:
    mov edx, r8d
    ret
ENDFN avi_format

# RCX=strl payload, RDX=end: one stream's header and format; selects it
# when it is the first decodable audio stream, or the chosen one.
LOCALFN avi_strl
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    xor r12d, r12d                        # strh
    xor r13d, r13d                        # strf
    xor ebx, ebx                          # strf bytes
.Lavi_strl_chunk:
    mov rcx, rsi
    mov rdx, rdi
    call avi_chunk
    test rax, rax
    jz .Lavi_strl_done
    mov rsi, rax
    cmp edx, 0x68727473                   # strh
    jne .Lavi_strl_format
    sub rax, rcx
    cmp rax, 4
    jb .Lavi_strl_next
    mov r12, rcx
    jmp .Lavi_strl_next
.Lavi_strl_format:
    cmp edx, 0x66727473                   # strf
    jne .Lavi_strl_next
    mov r13, rcx
    sub rax, rcx
    mov rbx, rax
.Lavi_strl_next:
    mov rax, rsi
    AVI_NEXT
    mov rsi, rax
    jmp .Lavi_strl_chunk
.Lavi_strl_done:
    mov eax, [rip + avi_streams]
    inc dword ptr [rip + avi_streams]
    test r12, r12
    jz .Lavi_strl_return
    cmp dword ptr [r12], 0x73647561       # auds
    jne .Lavi_strl_return
    inc dword ptr [rip + avi_audio_index]
    mov ecx, [rip + avi_audio_index]
    mov [rip + audio_tracks_count], ecx
    mov ecx, [rip + track_choice]
    test ecx, ecx
    jz .Lavi_strl_first
    cmp ecx, [rip + avi_audio_index]
    jne .Lavi_strl_return
    mov dword ptr [rip + track_choice_used], 1
    jmp .Lavi_strl_take
.Lavi_strl_first:
    cmp dword ptr [rip + avi_stream], -1
    jne .Lavi_strl_return                 # the first decodable one wins
.Lavi_strl_take:
    test r13, r13
    jz .Lavi_strl_return
    cmp eax, 99                           # two-digit chunk ids
    ja .Lavi_strl_return
    mov [rsp + 32], eax
    mov rcx, r13
    mov rdx, rbx
    call avi_format
    test eax, eax
    jz .Lavi_strl_return
    mov [rip + avi_tag], eax
    mov [rip + avi_mode], edx
    mov [rip + avi_fmt], r13
    mov [rip + avi_fmt_bytes], ebx
    mov eax, [rip + avi_audio_index]
    mov [rip + audio_track_selected], eax
    mov eax, [rsp + 32]
    mov [rip + avi_stream], eax
    xor edx, edx
    mov ecx, 10
    div ecx
    add eax, '0'
    add edx, '0'
    shl edx, 8
    or eax, edx
    or eax, 0x62770000                    # "wb"
    mov [rip + avi_id], eax
.Lavi_strl_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN avi_strl

# RCX=hdrl payload, RDX=end: reads its stream lists.
LOCALFN avi_hdrl
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
.Lavi_hdrl_chunk:
    mov rcx, rsi
    mov rdx, rdi
    call avi_chunk
    test rax, rax
    jz .Lavi_hdrl_return
    mov rsi, rax
    cmp edx, 0x5453494c                   # LIST
    jne .Lavi_hdrl_next
    lea rdx, [rcx + 4]
    cmp rdx, rax
    ja .Lavi_hdrl_next
    cmp dword ptr [rcx], 0x6c727473       # strl
    jne .Lavi_hdrl_next
    mov rcx, rdx
    mov rdx, rax
    call avi_strl
.Lavi_hdrl_next:
    mov rax, rsi
    AVI_NEXT
    mov rsi, rax
    jmp .Lavi_hdrl_chunk
.Lavi_hdrl_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN avi_hdrl

# RCX=data, RDX=bytes: appended to the gathered stream -> EAX=1.
LOCALFN avi_append
    sub rsp, 40
    call mts_append
    add rsp, 40
    ret
ENDFN avi_append

# RCX=WAVE format, EDX=its bytes, R8=audio bytes at most: starts a Wave64
# image in the gather buffer (riff, wave and fmt GUIDs, fmt's size, the
# format padded to 8 bytes, then data's GUID and a size set by
# wav_image_end) -> EAX=1. Shared with FLV.
FN wav_image_begin
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov ebx, edx
    lea rcx, [r8 + rbx + 128]
    call mts_begin
    test eax, eax
    jz .Lwav_image_begin_return
    lea rcx, [rip + avi_w64_header]
    mov edx, 56
    call avi_append
    test eax, eax
    jz .Lwav_image_begin_return
    lea rax, [rbx + 24]
    mov [rip + avi_size], rax
    lea rcx, [rip + avi_size]
    mov edx, 8
    call avi_append
    test eax, eax
    jz .Lwav_image_begin_return
    mov rcx, rsi
    mov edx, ebx
    call avi_append
    test eax, eax
    jz .Lwav_image_begin_return
    mov edx, ebx
    neg edx
    and edx, 7
    lea rcx, [rip + avi_zeros]
    call avi_append
    test eax, eax
    jz .Lwav_image_begin_return
    # A compressed format's zero block alignment means "unknown"; the WAV
    # reader needs it nonzero.
    mov rcx, [rip + mts_buffer]
    cmp word ptr [rcx + 64 + 12], 0
    jne .Lwav_image_begin_data
    movzx eax, word ptr [rcx + 64]
    cmp eax, 0xfffe
    jne .Lwav_image_begin_tag
    cmp ebx, 40
    jb .Lwav_image_begin_data
    movzx eax, word ptr [rcx + 64 + 24]
.Lwav_image_begin_tag:
    cmp eax, 0x50
    je .Lwav_image_begin_align
    cmp eax, 0x55
    je .Lwav_image_begin_align
    cmp eax, 0x2000
    jne .Lwav_image_begin_data
.Lwav_image_begin_align:
    mov word ptr [rcx + 64 + 12], 1
.Lwav_image_begin_data:
    mov rax, [rip + mts_bytes]
    mov [rip + avi_data], rax
    lea rcx, [rip + avi_w64_data]
    mov edx, 16
    call avi_append
    test eax, eax
    jz .Lwav_image_begin_return
    lea rcx, [rip + avi_zeros]
    mov edx, 8
    call avi_append
.Lwav_image_begin_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN wav_image_begin

# ECX=frame bytes to keep whole (0: every byte): sets the image's sizes ->
# RCX=image, RDX=its end.
FN wav_image_end
    mov r8d, ecx
    mov rcx, [rip + mts_buffer]
    mov r9, [rip + mts_bytes]
    sub r9, [rip + avi_data]
    sub r9, 24                            # audio bytes
    test r8d, r8d
    jz .Lwav_image_end_sizes
    mov rax, r9
    xor edx, edx
    div r8
    sub r9, rdx
.Lwav_image_end_sizes:
    mov rdx, [rip + avi_data]
    lea rax, [r9 + 24]
    mov [rcx + rdx + 16], rax
    lea rdx, [rdx + r9 + 24]              # image bytes
    mov [rcx + 16], rdx
    add rdx, rcx
    ret
ENDFN wav_image_end

# After hdrl: starts the packet list or the gathered stream -> EAX=1.
LOCALFN avi_start
    sub rsp, 40
    cmp dword ptr [rip + avi_mode], AVI_PACKETS
    jne .Lavi_start_gather
    mov ecx, TK_AAC
    call track_begin
    jmp .Lavi_start_return
.Lavi_start_gather:
    mov r8, [rip + avi_end]
    sub r8, [rip + avi_file]
    cmp dword ptr [rip + avi_mode], AVI_ADTS
    je .Lavi_start_adts
    mov rcx, [rip + avi_fmt]
    mov edx, [rip + avi_fmt_bytes]
    call wav_image_begin
    jmp .Lavi_start_return
.Lavi_start_adts:
    mov rcx, r8
    call mts_begin
.Lavi_start_return:
    add rsp, 40
    ret
ENDFN avi_start

# RCX=movi (or rec) payload, RDX=end -> EAX=1, 0 on failure.
LOCALFN avi_movi
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
.Lavi_movi_chunk:
    call avi_cancelled
    test eax, eax
    jnz .Lavi_movi_bad
    mov rcx, rsi
    mov rdx, rdi
    call avi_chunk
    test rax, rax
    jz .Lavi_movi_done
    mov rsi, rax
    cmp edx, [rip + avi_id]
    je .Lavi_movi_audio
    cmp edx, 0x5453494c                   # LIST rec groups
    jne .Lavi_movi_next
    lea rdx, [rcx + 4]
    cmp rdx, rax
    ja .Lavi_movi_next
    cmp dword ptr [rcx], 0x20636572       # "rec "
    jne .Lavi_movi_next
    mov rcx, rdx
    mov rdx, rax
    call avi_movi
    test eax, eax
    jz .Lavi_movi_bad
    jmp .Lavi_movi_next
.Lavi_movi_audio:
    mov rdx, rax
    sub rdx, rcx
    jz .Lavi_movi_next                    # empty chunks carry nothing
    cmp dword ptr [rip + avi_mode], AVI_PACKETS
    je .Lavi_movi_packet
    call avi_append
    jmp .Lavi_movi_added
.Lavi_movi_packet:
    call track_add
.Lavi_movi_added:
    test eax, eax
    jz .Lavi_movi_bad
.Lavi_movi_next:
    mov rax, rsi
    AVI_NEXT
    mov rsi, rax
    jmp .Lavi_movi_chunk
.Lavi_movi_done:
    mov eax, 1
    jmp .Lavi_movi_return
.Lavi_movi_bad:
    xor eax, eax
.Lavi_movi_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN avi_movi

# RCX=RIFF payload after its form type, RDX=end: hdrl, then movi lists ->
# EAX=1, 0 on failure.
LOCALFN avi_riff
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
.Lavi_riff_chunk:
    mov rcx, rsi
    mov rdx, rdi
    call avi_chunk
    test rax, rax
    jz .Lavi_riff_done
    mov rsi, rax
    cmp edx, 0x5453494c                   # LIST
    jne .Lavi_riff_next
    lea rdx, [rcx + 4]
    cmp rdx, rax
    ja .Lavi_riff_next
    cmp dword ptr [rcx], 0x6c726468       # hdrl
    je .Lavi_riff_hdrl
    cmp dword ptr [rcx], 0x69766f6d       # movi
    jne .Lavi_riff_next
    cmp dword ptr [rip + avi_stage], 0
    je .Lavi_riff_bad                     # movi before hdrl
    inc dword ptr [rip + avi_movis]
    mov rcx, rdx
    mov rdx, rax
    call avi_movi
    test eax, eax
    jz .Lavi_riff_bad
    jmp .Lavi_riff_next
.Lavi_riff_hdrl:
    cmp dword ptr [rip + avi_stage], 0
    jne .Lavi_riff_bad                    # a second hdrl
    cmp dword ptr [rip + avi_riffs], 1
    jne .Lavi_riff_bad                    # only in RIFF AVI
    mov dword ptr [rip + avi_stage], 1
    mov rcx, rdx
    mov rdx, rax
    call avi_hdrl
    cmp dword ptr [rip + avi_stream], -1
    jne .Lavi_riff_start
    mov dword ptr [rip + decode_error], AVI_UNSUPPORTED
    jmp .Lavi_riff_bad
.Lavi_riff_start:
    call avi_start
    test eax, eax
    jz .Lavi_riff_bad
.Lavi_riff_next:
    mov rax, rsi
    AVI_NEXT
    mov rsi, rax
    jmp .Lavi_riff_chunk
.Lavi_riff_done:
    mov eax, 1
    jmp .Lavi_riff_return
.Lavi_riff_bad:
    xor eax, eax
.Lavi_riff_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN avi_riff

# RCX=mapped start (a RIFF "AVI " header), RDX=end -> EAX=1 with the stream
# open (AAC), EAX=2 with RCX..RDX a Wave64 image for the WAV reader, or 0
# with decode_error set.
FN avi_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov [rip + avi_file], rcx
    mov [rip + avi_end], rdx
    xor eax, eax
    mov [rip + avi_stage], eax
    mov [rip + avi_riffs], eax
    mov [rip + avi_movis], eax
    mov [rip + avi_streams], eax
    mov [rip + avi_audio_index], eax
    mov [rip + avi_id], eax
    mov dword ptr [rip + avi_stream], -1
.Lavi_open_chunk:
    call avi_cancelled
    test eax, eax
    jnz .Lavi_open_bad
    mov rcx, rsi
    mov rdx, rdi
    call avi_chunk
    test rax, rax
    jz .Lavi_open_done
    mov rsi, rax
    cmp edx, 0x46464952                   # RIFF
    jne .Lavi_open_next
    lea rdx, [rcx + 4]
    cmp rdx, rax
    ja .Lavi_open_next
    mov r8d, [rcx]
    cmp dword ptr [rip + avi_riffs], 0
    jne .Lavi_open_extension
    cmp r8d, 0x20495641                   # "AVI " first
    jne .Lavi_open_bad
    jmp .Lavi_open_riff
.Lavi_open_extension:
    cmp r8d, 0x58495641                   # then OpenDML AVIX
    jne .Lavi_open_next
.Lavi_open_riff:
    inc dword ptr [rip + avi_riffs]
    mov rcx, rdx
    mov rdx, rax
    call avi_riff
    test eax, eax
    jz .Lavi_open_bad
.Lavi_open_next:
    cmp dword ptr [rip + avi_riffs], 0
    je .Lavi_open_bad
    mov rax, rsi
    AVI_NEXT
    mov rsi, rax
    jmp .Lavi_open_chunk
.Lavi_open_done:
    cmp dword ptr [rip + avi_stage], 0
    je .Lavi_open_bad
    cmp dword ptr [rip + avi_movis], 0
    je .Lavi_open_bad
    mov eax, [rip + avi_mode]
    cmp eax, AVI_PACKETS
    je .Lavi_open_packets
    cmp eax, AVI_ADTS
    je .Lavi_open_adts
    # The Wave64 image: whole PCM frames (a truncated last chunk may end
    # within one).
    xor ecx, ecx
    mov eax, [rip + avi_tag]
    cmp eax, 1
    je .Lavi_open_frames
    cmp eax, 3
    je .Lavi_open_frames
    cmp eax, 6
    je .Lavi_open_frames
    cmp eax, 7
    jne .Lavi_open_image
.Lavi_open_frames:
    mov rax, [rip + avi_fmt]
    movzx ecx, word ptr [rax + 12]
.Lavi_open_image:
    call wav_image_end
    mov eax, 2
    jmp .Lavi_open_return
.Lavi_open_adts:
    mov rcx, [rip + mts_buffer]
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    cmp qword ptr [rip + mts_bytes], 0
    je .Lavi_open_bad
    call adts_open
    test eax, eax
    jz .Lavi_open_failed
    jmp .Lavi_open_return
.Lavi_open_packets:
    cmp qword ptr [rip + track_count], 0
    je .Lavi_open_bad
    mov rax, [rip + avi_fmt]
    add rax, 18
    mov [rip + track_config], rax
    mov rax, [rip + avi_fmt]
    movzx eax, word ptr [rax + 16]
    mov [rip + track_config_bytes], eax
    call track_finish
    test eax, eax
    jz .Lavi_open_failed
    mov dword ptr [rip + codec_kind], 10
    mov eax, 1
    jmp .Lavi_open_return
.Lavi_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lavi_open_failed
    mov dword ptr [rip + decode_error], AVI_MALFORMED
.Lavi_open_failed:
    call track_close
    call mts_close
    xor eax, eax
.Lavi_open_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN avi_open
