# Original MPEG transport and program stream audio demuxer in x86-64
# assembly. MIT, see LICENSE. Reference: ISO/IEC 13818-1. The first
# supported audio stream (MPEG audio, AAC in ADTS or LATM, or AC-3) is
# gathered from its PES packets into one buffer, which then opens as the raw
# stream it carries, so decoding, timing and seeking are those of .mp3,
# .aac, .loas and .ac3 files. Transport streams: 188-byte packets, 192-byte M2TS/BDAV packets and
# 204-byte packets; the program association table and the first program's
# map select the stream. Program streams (.mpg, .vob): MPEG-1 and MPEG-2
# packs, audio stream ids 0xC0-0xDF and private stream 1 AC-3 substreams.
.include "lamp.inc"
.globl mts_probe, mts_open, mps_probe, mps_open, mts_close
.globl mts_begin, mts_append, mts_buffer, mts_bytes   # AVI gathers its audio here

.equ MTS_MALFORMED, 100
.equ MTS_UNSUPPORTED, 101
.equ MTS_CHUNK, 1 << 20             # buffer commit step
.equ MPS_AUDIO_IDS, 128             # all 32 MPEG + 72 recognized private audio IDs fit
.equ KIND_MPA, 1
.equ KIND_ADTS, 2
.equ KIND_AC3, 3
.equ KIND_OTHER, 4                  # audio LAMP does not decode
.equ KIND_PROBE, 5                  # private data without descriptors: by content
.equ KIND_LATM, 6                   # AAC in LOAS/LATM
.equ KIND_NONE, 7                   # private data that is not audio
.equ KIND_DVD, 8                    # DVD LPCM (program streams)
.equ KIND_BLURAY, 9                 # Blu-ray LPCM (transport streams)
.equ LPCM_DVD, 1
.equ LPCM_BLURAY, 2

RODATA
# Transport packet sizes and the sync byte's offset in each.
mts_layouts: .long 188, 0, 192, 4, 204, 0

.data
mts_buffer: .quad 0                 # gathered elementary stream
mts_bytes: .quad 0
mts_committed: .quad 0
mts_capacity: .quad 0
mts_packet: .long 0
mts_offset: .long 0
mts_unsupported: .long 0            # unsupported audio was seen
mts_hdmv: .long 0                   # the program carries an HDMV registration
mts_audio_index: .long -1           # audio streams of the map read (track_choice); -1: no map
mps_audio_count: .long 0            # program stream audio ids, by first appearance
.bss
mps_audio_ids: .zero MPS_AUDIO_IDS*4
.data

.text
FN mts_close
    sub rsp, 40
    mov rcx, [rip + mts_buffer]
    test rcx, rcx
    jz .Lmts_close_done
    call mem_free
.Lmts_close_done:
    mov qword ptr [rip + mts_buffer], 0
    mov qword ptr [rip + mts_bytes], 0
    mov qword ptr [rip + mts_committed], 0
    add rsp, 40
    ret
ENDFN mts_close

# RCX=input bytes: reserves the elementary stream buffer -> EAX=1.
FN mts_begin
    sub rsp, 40
    mov [rip + mts_capacity], rcx
    mov qword ptr [rip + mts_bytes], 0
    mov qword ptr [rip + mts_committed], 0
    mov dword ptr [rip + mts_unsupported], 0
    call mem_reserve
    mov [rip + mts_buffer], rax
    test rax, rax
    setnz al
    movzx eax, al
    add rsp, 40
    ret
ENDFN mts_begin

# RCX=data, RDX=bytes: appended to the buffer -> EAX=1.
FN mts_append
    push rsi
    push rdi
    push rbx
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov rbx, rdx
    mov eax, 1
    test rbx, rbx
    jz .Lmts_append_return
    mov rax, [rip + mts_bytes]
    add rax, rbx
    cmp rax, [rip + mts_capacity]
    ja .Lmts_append_full
.Lmts_append_commit:
    mov rax, [rip + mts_bytes]
    add rax, rbx
    cmp rax, [rip + mts_committed]
    jbe .Lmts_append_copy
    mov r12, [rip + mts_capacity]
    sub r12, [rip + mts_committed]
    cmp r12, MTS_CHUNK
    jbe .Lmts_append_step
    mov r12d, MTS_CHUNK
.Lmts_append_step:
    mov rcx, [rip + mts_buffer]
    add rcx, [rip + mts_committed]
    mov rdx, r12
    call mem_commit
    test rax, rax
    jz .Lmts_append_full
    add [rip + mts_committed], r12
    jmp .Lmts_append_commit
.Lmts_append_copy:
    mov rdi, [rip + mts_buffer]
    add rdi, [rip + mts_bytes]
    mov rcx, rbx
    rep movsb
    add [rip + mts_bytes], rbx
    mov eax, 1
    jmp .Lmts_append_return
.Lmts_append_full:
    xor eax, eax
.Lmts_append_return:
    add rsp, 40
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mts_append

# Opens the gathered stream as ECX=kind -> EAX=1.
LOCALFN mts_open_stream
    sub rsp, 40
    mov eax, ecx
    mov rcx, [rip + mts_buffer]
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    cmp qword ptr [rip + mts_bytes], 0
    je .Lmts_stream_bad
    cmp eax, KIND_MPA
    je .Lmts_stream_mpa
    cmp eax, KIND_ADTS
    je .Lmts_stream_adts
    cmp eax, KIND_LATM
    je .Lmts_stream_latm
    cmp eax, KIND_DVD
    je .Lmts_stream_lpcm
    cmp eax, KIND_BLURAY
    je .Lmts_stream_lpcm
    call ac3_open
    jmp .Lmts_stream_return
.Lmts_stream_adts:
    call adts_open
    jmp .Lmts_stream_return
.Lmts_stream_lpcm:
    call lpcm_image                       # EAX=2: a Wave64 image
    jmp .Lmts_stream_return
.Lmts_stream_latm:
    call adts_probe                       # ADTS labelled LATM (FFmpeg's -c copy
    mov rcx, [rip + mts_buffer]           # with -mpegts_flags latm) plays as ADTS
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    test eax, eax
    jnz .Lmts_stream_adts
    call loas_open
    jmp .Lmts_stream_return
.Lmts_stream_mpa:
    call mp3_open
    test eax, eax
    jz .Lmts_stream_return
    mov dword ptr [rip + codec_kind], 3
    jmp .Lmts_stream_return
.Lmts_stream_bad:
    mov dword ptr [rip + decode_error], MTS_MALFORMED   # no audio data
    xor eax, eax
.Lmts_stream_return:
    add rsp, 40
    ret
ENDFN mts_open_stream

# RCX=start, RDX=end -> EAX=packet size (0 when the data is not a transport
# stream), EDX=sync offset. At least five packets (or all of a shorter file)
# must start with the sync byte.
LOCALFN mts_layout
    push rbx
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
    lea r8, [rip + mts_layouts]
    xor r9d, r9d                          # layout
.Lmts_layout_try:
    cmp r9d, 3
    jae .Lmts_layout_none
    mov eax, [r8 + r9*8]                  # packet size
    mov edx, [r8 + r9*8 + 4]              # offset
    mov rcx, rdi
    sub rcx, rsi
    mov r10, rcx
    xor ebx, ebx                          # packets checked
    lea r11, [rsi + rdx]
.Lmts_layout_packet:
    cmp ebx, 5
    jae .Lmts_layout_found
    lea rcx, [r11 + rax]
    sub rcx, rdx
    cmp rcx, rdi
    ja .Lmts_layout_short
    cmp byte ptr [r11], 0x47
    jne .Lmts_layout_next
    add r11, rax
    inc ebx
    jmp .Lmts_layout_packet
.Lmts_layout_short:
    cmp ebx, 2                            # a shorter file: every packet synced
    jae .Lmts_layout_found
.Lmts_layout_next:
    inc r9d
    jmp .Lmts_layout_try
.Lmts_layout_found:
    pop rdi
    pop rsi
    pop rbx
    ret
.Lmts_layout_none:
    xor eax, eax
    xor edx, edx
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mts_layout

# RCX=start, RDX=end -> EAX=1 for a transport stream.
FN mts_probe
    sub rsp, 40
    call mts_layout
    test eax, eax
    setnz al
    movzx eax, al
    add rsp, 40
    ret
ENDFN mts_probe

# RCX=transport packet (at its sync byte) -> RAX=payload or 0, RDX=payload
# end, R8D=PID, R9D=1 when a unit (PES packet or section) starts here.
LOCALFN mts_payload
    movzx eax, byte ptr [rcx + 1]
    test eax, 0x80                        # transport error
    jnz .Lmts_payload_none
    mov r9d, eax
    shr r9d, 6
    and r9d, 1
    shl eax, 8
    movzx r8d, byte ptr [rcx + 2]
    or r8d, eax
    and r8d, 0x1fff
    movzx eax, byte ptr [rcx + 3]
    lea rdx, [rcx + 188]
    test eax, 0x10
    jz .Lmts_payload_none                 # no payload
    lea r10, [rcx + 4]
    test eax, 0x20
    jz .Lmts_payload_ready
    movzx eax, byte ptr [rcx + 4]
    lea r10, [rcx + rax + 5]              # after the adaptation field
    cmp r10, rdx
    jae .Lmts_payload_none
.Lmts_payload_ready:
    mov rax, r10
    ret
.Lmts_payload_none:
    xor eax, eax
    ret
ENDFN mts_payload

# RCX=payload starting a section (pointer field first), RDX=payload end,
# R8D=table id -> RAX=section body after the 8-byte long header or 0,
# RDX=its end before the CRC. Sections must fit in their first packet.
LOCALFN mts_section
    movzx eax, byte ptr [rcx]
    lea rcx, [rcx + rax + 1]
    lea rax, [rcx + 8]
    cmp rax, rdx
    ja .Lmts_section_none
    movzx eax, byte ptr [rcx]
    cmp eax, r8d
    jne .Lmts_section_none
    movzx eax, byte ptr [rcx + 1]
    and eax, 0x0f
    shl eax, 8
    movzx r9d, byte ptr [rcx + 2]
    or eax, r9d                           # section length
    cmp eax, 9
    jb .Lmts_section_none
    lea r9, [rcx + rax + 3]
    cmp r9, rdx
    ja .Lmts_section_none
    lea rdx, [r9 - 4]
    lea rax, [rcx + 8]
    ret
.Lmts_section_none:
    xor eax, eax
    ret
ENDFN mts_section

# Stream type ECX with descriptors RDX..R8 -> EAX=kind (0 for non-audio;
# KIND_PROBE for private data that no descriptor identifies).
LOCALFN mts_classify
    mov eax, KIND_MPA
    cmp ecx, 3
    je .Lmts_classify_done
    cmp ecx, 4
    je .Lmts_classify_done
    mov eax, KIND_ADTS
    cmp ecx, 0x0f
    je .Lmts_classify_done
    mov eax, KIND_AC3
    cmp ecx, 0x81
    je .Lmts_classify_done
    cmp ecx, 0x87                         # ATSC E-AC-3
    je .Lmts_classify_done
    mov eax, KIND_LATM
    cmp ecx, 0x11                         # LATM AAC
    je .Lmts_classify_done
    mov eax, KIND_BLURAY
    cmp ecx, 0x80                         # Blu-ray LPCM, under an HDMV registration
    jne .Lmts_classify_other_types
    cmp dword ptr [rip + mts_hdmv], 0
    jne .Lmts_classify_done
.Lmts_classify_other_types:
    mov eax, KIND_OTHER
    cmp ecx, 0x80
    jb .Lmts_classify_private
    cmp ecx, 0x87                         # DTS, TrueHD, E-AC-3
    jbe .Lmts_classify_done
    cmp ecx, 0xa1
    je .Lmts_classify_done
    cmp ecx, 0xa2
    je .Lmts_classify_done
.Lmts_classify_private:
    xor eax, eax
    cmp ecx, 6                            # private data: the descriptors say
    jne .Lmts_classify_done
    mov eax, KIND_PROBE
.Lmts_classify_descriptor:
    lea r9, [rdx + 2]
    cmp r9, r8
    ja .Lmts_classify_done
    movzx r9d, byte ptr [rdx]             # tag
    movzx r10d, byte ptr [rdx + 1]
    lea r11, [rdx + r10 + 2]
    cmp r11, r8
    ja .Lmts_classify_done
    cmp r9d, 0x6a                         # DVB AC-3
    je .Lmts_classify_ac3
    cmp r9d, 0x7a                         # DVB E-AC-3
    je .Lmts_classify_ac3
    cmp r9d, 0x7b                         # DTS
    je .Lmts_classify_other
    cmp r9d, 0x7c                         # DVB AAC
    je .Lmts_classify_other
    cmp r9d, 5                            # registration
    jne .Lmts_classify_skip
    cmp r10d, 4
    jb .Lmts_classify_skip
    mov r9d, [rdx + 2]
    cmp r9d, 0x332d4341                   # "AC-3"
    je .Lmts_classify_ac3
    cmp r9d, 0x33434145                   # "EAC3"
    je .Lmts_classify_ac3
    and r9d, 0x00ffffff
    cmp r9d, 0x00535444                   # "DTS"
    je .Lmts_classify_other
.Lmts_classify_skip:
    xor eax, eax                          # a described private stream is not audio
    mov rdx, r11
    jmp .Lmts_classify_descriptor
.Lmts_classify_ac3:
    mov eax, KIND_AC3
    ret
.Lmts_classify_other:
    mov eax, KIND_OTHER
.Lmts_classify_done:
    ret
ENDFN mts_classify

# RCX=PES packet start in a payload, RDX=payload end -> RAX=elementary data
# or 0 when the payload does not start an MPEG-2 PES packet.
LOCALFN mts_pes_data
    lea rax, [rcx + 9]
    cmp rax, rdx
    ja .Lmts_pes_none
    cmp word ptr [rcx], 0
    jne .Lmts_pes_none
    cmp byte ptr [rcx + 2], 1
    jne .Lmts_pes_none
    movzx eax, byte ptr [rcx + 6]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Lmts_pes_none
    movzx eax, byte ptr [rcx + 8]
    lea rax, [rcx + rax + 9]
    cmp rax, rdx
    ja .Lmts_pes_none
    ret
.Lmts_pes_none:
    xor eax, eax
    ret
ENDFN mts_pes_data

# Private data identified by its first PES packet: RCX=PES start code,
# RAX=its elementary data, RDX=payload end -> ECX=kind: MPEG audio or ADTS
# for audio stream ids (0xC0-0xDF), AC-3 for private stream 1 starting with
# an AC-3 sync frame; KIND_OTHER for reserved ids or DTS there; KIND_NONE for
# anything else. RAX and RDX are kept.
LOCALFN mts_identify
    movzx r8d, byte ptr [rcx + 3]         # stream id
    mov ecx, KIND_NONE
    lea r9, [rax + 6]
    cmp r9, rdx
    ja .Lmts_identify_done
    movzx r9d, word ptr [rax]
    rol r9w, 8                            # first two bytes, big-endian
    cmp r8d, 0xc0
    jb .Lmts_identify_private
    cmp r8d, 0xdf
    ja .Lmts_identify_done
    mov ecx, KIND_MPA
    mov r10d, r9d
    and r10d, 0xfff6
    cmp r10d, 0xfff0                      # ADTS: sync with layer 0
    jne .Lmts_identify_done
    mov ecx, KIND_ADTS
    ret
.Lmts_identify_private:
    cmp r8d, 0xbd
    jne .Lmts_identify_done
    cmp r9d, 0x0b77
    jne .Lmts_identify_dts
    movzx r10d, byte ptr [rax + 5]
    shr r10d, 3                           # bsid
    mov ecx, KIND_AC3
    cmp r10d, 16
    jbe .Lmts_identify_done
    mov ecx, KIND_OTHER                   # reserved bitstream id
    ret
.Lmts_identify_dts:
    cmp dword ptr [rax], 0x0180fe7f       # DTS core sync
    jne .Lmts_identify_done
    mov ecx, KIND_OTHER
.Lmts_identify_done:
    ret
ENDFN mts_identify

# RCX=mapped start, RDX=end -> EAX=1 with the selected audio stream open.
# Locals: 32 stream entry, 40 next entry, 48 private stream candidate.
FN mts_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rsi, rcx
    mov rdi, rdx
    call mts_layout
    test eax, eax
    jz .Lmts_open_bad
    mov [rip + mts_packet], eax
    mov [rip + mts_offset], edx
    mov rcx, rdi
    sub rcx, rsi
    call mts_begin
    test eax, eax
    jz .Lmts_open_bad
    # Pass 1: the program association table, then the first program's map.
    mov r12d, -1                          # PMT PID
    mov r13d, -1                          # selected PID
    xor r14d, r14d                        # kind
    mov dword ptr [rsp + 48], -1          # private stream to identify by content
    mov dword ptr [rip + mts_audio_index], -1
    mov rbx, rsi
.Lmts_open_tables:
    mov eax, [rip + mts_packet]
    lea rcx, [rbx + rax]
    cmp rcx, rdi
    ja .Lmts_open_tables_done
    mov eax, [rip + mts_offset]
    lea rcx, [rbx + rax]
    cmp byte ptr [rcx], 0x47
    jne .Lmts_open_tables_next
    call mts_payload
    test rax, rax
    jz .Lmts_open_tables_next
    test r9d, r9d
    jz .Lmts_open_tables_next
    mov rcx, rax
    test r8d, r8d
    jnz .Lmts_open_pmt
    cmp r12d, -1
    jne .Lmts_open_tables_next
    xor r8d, r8d
    call mts_section                      # PAT
    test rax, rax
    jz .Lmts_open_tables_next
.Lmts_open_pat_entry:
    lea rcx, [rax + 4]
    cmp rcx, rdx
    ja .Lmts_open_tables_next
    movzx ecx, word ptr [rax]
    test ecx, ecx
    jz .Lmts_open_pat_next                # network PID
    movzx r12d, byte ptr [rax + 2]
    and r12d, 0x1f
    shl r12d, 8
    movzx ecx, byte ptr [rax + 3]
    or r12d, ecx
    jmp .Lmts_open_tables_next
.Lmts_open_pat_next:
    add rax, 4
    jmp .Lmts_open_pat_entry
.Lmts_open_pmt:
    cmp r8d, r12d
    jne .Lmts_open_tables_next
    mov r8d, 2
    call mts_section
    test rax, rax
    jz .Lmts_open_tables_next
    mov r15, rdx                          # section end
    lea rcx, [rax + 4]
    cmp rcx, r15
    ja .Lmts_open_bad
    movzx ecx, byte ptr [rax + 2]
    and ecx, 0x0f
    shl ecx, 8
    movzx edx, byte ptr [rax + 3]
    or ecx, edx                           # program info length
    lea rdx, [rax + 4]
    lea rax, [rax + rcx + 4]
    mov dword ptr [rip + mts_hdmv], 0
    mov dword ptr [rip + mts_audio_index], 0
.Lmts_open_program_info:
    lea r8, [rdx + 2]                     # registration descriptors
    cmp r8, rax
    ja .Lmts_open_stream
    movzx r8d, byte ptr [rdx + 1]
    lea r9, [rdx + r8 + 2]
    cmp r9, rax
    ja .Lmts_open_stream
    cmp r9, r15
    ja .Lmts_open_stream
    cmp byte ptr [rdx], 5
    jne .Lmts_open_program_next
    cmp r8d, 4
    jb .Lmts_open_program_next
    mov r10d, [rdx + 2]
    cmp r10d, 0x564d4448                  # "HDMV"
    je .Lmts_open_hdmv
    cmp r10d, 0x52504448                  # "HDPR"
    jne .Lmts_open_program_next
.Lmts_open_hdmv:
    mov dword ptr [rip + mts_hdmv], 1
.Lmts_open_program_next:
    mov rdx, r9
    jmp .Lmts_open_program_info
.Lmts_open_stream:
    lea rcx, [rax + 5]
    cmp rcx, r15
    ja .Lmts_open_pmt_done
    mov [rsp + 32], rax
    movzx ecx, byte ptr [rax]             # stream type
    movzx edx, byte ptr [rax + 3]
    and edx, 0x0f
    shl edx, 8
    movzx r8d, byte ptr [rax + 4]
    or edx, r8d                           # ES info length
    lea r8, [rax + rdx + 5]
    cmp r8, r15
    ja .Lmts_open_pmt_done
    mov [rsp + 40], r8
    lea rdx, [rax + 5]
    call mts_classify
    mov rcx, [rsp + 32]
    test eax, eax
    jz .Lmts_open_stream_next
    inc dword ptr [rip + mts_audio_index]
    mov edx, [rip + mts_audio_index]
    mov [rip + audio_tracks_count], edx
    cmp r13d, -1                        # keep scanning the complete first map after selection
    jne .Lmts_open_stream_next
    cmp dword ptr [rip + track_choice], 0
    je .Lmts_open_stream_automatic
    # A chosen track: the Nth audio stream of the map.
    mov edx, [rip + mts_audio_index]
    cmp edx, [rip + track_choice]
    jne .Lmts_open_stream_next
    mov dword ptr [rip + track_choice_used], 1
    cmp eax, KIND_OTHER
    jne .Lmts_open_stream_select
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmts_open_bad
.Lmts_open_stream_automatic:
    cmp eax, KIND_OTHER
    jne .Lmts_open_stream_kind
    mov dword ptr [rip + mts_unsupported], 1
    jmp .Lmts_open_stream_next
.Lmts_open_stream_kind:
    test eax, eax
    jz .Lmts_open_stream_next
    cmp eax, KIND_PROBE
    jne .Lmts_open_stream_select
    cmp dword ptr [rsp + 48], -1
    jne .Lmts_open_stream_next
    movzx eax, byte ptr [rcx + 1]
    and eax, 0x1f
    shl eax, 8
    movzx edx, byte ptr [rcx + 2]
    or eax, edx
    mov [rsp + 48], eax
    mov eax, [rip + mts_audio_index]
    mov [rip + audio_track_selected], eax
    jmp .Lmts_open_stream_next
.Lmts_open_stream_select:
    mov edx, [rip + mts_audio_index]
    mov [rip + audio_track_selected], edx
    mov r14d, eax
    movzx r13d, byte ptr [rcx + 1]
    and r13d, 0x1f
    shl r13d, 8
    movzx eax, byte ptr [rcx + 2]
    or r13d, eax
    jmp .Lmts_open_stream_next
.Lmts_open_stream_next:
    mov rax, [rsp + 40]
    jmp .Lmts_open_stream
.Lmts_open_pmt_done:
    cmp r13d, -1
    jne .Lmts_open_tables_done
    mov eax, [rsp + 48]                   # no typed audio: the private candidate
    cmp eax, -1
    je .Lmts_open_tables_done
    mov r13d, eax
    mov r14d, KIND_PROBE
    jmp .Lmts_open_tables_done
.Lmts_open_tables_next:
    mov eax, [rip + mts_packet]
    add rbx, rax
    jmp .Lmts_open_tables
.Lmts_open_tables_done:
    cmp r13d, -1
    jne .Lmts_open_gather
    cmp dword ptr [rip + track_choice], 0
    je .Lmts_open_tables_none
    cmp dword ptr [rip + mts_audio_index], -1
    je .Lmts_open_tables_none             # no map: malformed
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED   # no such track
    jmp .Lmts_open_bad
.Lmts_open_tables_none:
    cmp dword ptr [rip + mts_unsupported], 0
    je .Lmts_open_bad
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmts_open_bad
.Lmts_open_gather:
    # Pass 2: the selected stream's PES payloads, headers removed.
    mov ecx, LPCM_BLURAY
    call lpcm_begin
    mov rbx, rsi
    xor r15d, r15d                        # inside a PES packet
.Lmts_open_packet:
    mov eax, [rip + mts_packet]
    lea rcx, [rbx + rax]
    cmp rcx, rdi
    ja .Lmts_open_gathered
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmts_open_packet_continue
    cmp dword ptr [rax], 0
    jne .Lmts_open_bad
.Lmts_open_packet_continue:
    mov eax, [rip + mts_offset]
    lea rcx, [rbx + rax]
    cmp byte ptr [rcx], 0x47
    jne .Lmts_open_packet_next
    call mts_payload
    test rax, rax
    jz .Lmts_open_packet_next
    cmp r8d, r13d
    jne .Lmts_open_packet_next
    test r9d, r9d
    jz .Lmts_open_packet_data
    mov rcx, rax
    mov [rsp + 32], rdx
    call mts_pes_data
    mov rdx, [rsp + 32]
    xor r15d, r15d
    test rax, rax
    jz .Lmts_open_packet_next
    mov r15d, 1
    cmp r14d, KIND_BLURAY
    jne .Lmts_open_packet_probe
    mov rcx, rax                          # each packet's LPCM header
    call lpcm_bluray_packet
    cmp eax, 1
    je .Lmts_open_packet_next
    test eax, eax
    jz .Lmts_open_bad
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmts_open_bad
.Lmts_open_packet_probe:
    cmp r14d, KIND_PROBE
    jne .Lmts_open_packet_data
    call mts_identify
    mov r14d, ecx
    cmp ecx, KIND_OTHER
    jb .Lmts_open_packet_data
    ja .Lmts_open_bad                     # not audio
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmts_open_bad
.Lmts_open_packet_data:
    test r15d, r15d
    jz .Lmts_open_packet_next
    mov rcx, rax
    sub rdx, rax
    call mts_append
    test eax, eax
    jz .Lmts_open_bad
.Lmts_open_packet_next:
    mov eax, [rip + mts_packet]
    add rbx, rax
    jmp .Lmts_open_packet
.Lmts_open_gathered:
    mov ecx, r14d
    call mts_open_stream
    test eax, eax
    jz .Lmts_open_failed
    jmp .Lmts_open_return
.Lmts_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lmts_open_failed
    mov dword ptr [rip + decode_error], MTS_MALFORMED
.Lmts_open_failed:
    call mts_close
    xor eax, eax
.Lmts_open_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mts_open

# RCX=mapped start, RDX=end -> EAX=1 for a program stream (pack header first).
FN mps_probe
    xor eax, eax
    lea r8, [rcx + 14]
    cmp r8, rdx
    ja .Lmps_probe_done
    cmp dword ptr [rcx], 0xba010000
    sete al
.Lmps_probe_done:
    ret
ENDFN mps_probe

# RCX=PES packet (start code), RDX=its end -> RAX=elementary data or 0:
# MPEG-2 headers, or MPEG-1 stuffing, buffer size and time stamps.
LOCALFN mps_pes_data
    lea rax, [rcx + 6]
    cmp rax, rdx
    jae .Lmps_pes_none
    movzx r8d, byte ptr [rax]
    mov r9d, r8d
    and r9d, 0xc0
    cmp r9d, 0x80
    jne .Lmps_pes_mpeg1
    lea r9, [rax + 3]
    cmp r9, rdx
    ja .Lmps_pes_none
    movzx r8d, byte ptr [rax + 2]
    lea rax, [rax + r8 + 3]
    cmp rax, rdx
    ja .Lmps_pes_none
    ret
.Lmps_pes_mpeg1:
    mov r9d, 16
.Lmps_pes_stuffing:
    cmp rax, rdx
    jae .Lmps_pes_none
    cmp byte ptr [rax], 0xff
    jne .Lmps_pes_buffer
    inc rax
    dec r9d
    jnz .Lmps_pes_stuffing
    jmp .Lmps_pes_none
.Lmps_pes_buffer:
    movzx r8d, byte ptr [rax]
    mov r9d, r8d
    and r9d, 0xc0
    cmp r9d, 0x40
    jne .Lmps_pes_stamps
    add rax, 2
    cmp rax, rdx
    jae .Lmps_pes_none
    movzx r8d, byte ptr [rax]
.Lmps_pes_stamps:
    mov r9d, r8d
    and r9d, 0xf0
    cmp r9d, 0x20
    je .Lmps_pes_pts
    cmp r9d, 0x30
    je .Lmps_pes_dts
    cmp r8d, 0x0f
    jne .Lmps_pes_none
    inc rax
    jmp .Lmps_pes_check
.Lmps_pes_pts:
    add rax, 5
    jmp .Lmps_pes_check
.Lmps_pes_dts:
    add rax, 10
.Lmps_pes_check:
    cmp rax, rdx
    ja .Lmps_pes_none
    ret
.Lmps_pes_none:
    xor eax, eax
    ret
ENDFN mps_pes_data

# ECX=a program stream's audio stream id -> R10D=its number (from 1) in
# order of first appearance, 0 if the bounded table is full. All currently
# recognized 104 IDs fit. Keeps RAX, R8 and R9.
LOCALFN mps_audio_seen
    lea r11, [rip + mps_audio_ids]
    xor r10d, r10d
.Lmps_seen_entry:
    cmp r10d, [rip + mps_audio_count]
    jae .Lmps_seen_new
    cmp [r11 + r10*4], ecx
    je .Lmps_seen_found
    inc r10d
    jmp .Lmps_seen_entry
.Lmps_seen_new:
    cmp r10d, MPS_AUDIO_IDS
    jae .Lmps_seen_full
    mov [r11 + r10*4], ecx
    inc dword ptr [rip + mps_audio_count]
.Lmps_seen_found:
    inc r10d
    ret
.Lmps_seen_full:
    xor r10d, r10d
    ret
ENDFN mps_audio_seen

# RCX=mapped start, RDX=end -> EAX=1 with the first audio stream open (or
# EAX=2 with a Wave64 image of LPCM): an MPEG audio stream id, or 0xBD00 |
# an AC-3 or LPCM substream of private stream 1; track_choice picks the Nth
# audio stream to appear instead.
# Locals: 32 stream id, 40 PES packet end.
FN mps_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    mov rcx, rdi
    sub rcx, rsi
    call mts_begin
    test eax, eax
    jz .Lmps_open_bad
    mov r12d, -1                          # selected stream
    xor r13d, r13d                        # kind
    mov dword ptr [rip + mps_audio_count], 0
    mov rbx, rsi
.Lmps_open_code:
    lea rax, [rbx + 4]
    cmp rax, rdi
    ja .Lmps_open_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmps_open_continue
    cmp dword ptr [rax], 0
    jne .Lmps_open_bad
.Lmps_open_continue:
    cmp word ptr [rbx], 0
    jne .Lmps_open_resync
    cmp byte ptr [rbx + 2], 1
    jne .Lmps_open_resync
    movzx eax, byte ptr [rbx + 3]
    cmp eax, 0xba
    je .Lmps_open_pack
    cmp eax, 0xb9
    je .Lmps_open_end_code
    cmp eax, 0xbb
    jb .Lmps_open_resync
    # A PES packet or system header: 6 + length bytes.
    lea rcx, [rbx + 6]
    cmp rcx, rdi
    ja .Lmps_open_done
    movzx ecx, word ptr [rbx + 4]
    xchg cl, ch
    lea rdx, [rbx + rcx + 6]
    cmp rdx, rdi
    ja .Lmps_open_done                    # truncated final packet
    mov [rsp + 40], rdx
    cmp eax, 0xbd
    je .Lmps_open_private
    cmp eax, 0xc0
    jb .Lmps_open_skip
    cmp eax, 0xdf
    ja .Lmps_open_skip
    mov [rsp + 32], eax                   # MPEG audio stream id
    mov rcx, rbx
    call mps_pes_data
    test rax, rax
    jz .Lmps_open_skip
    mov r8d, [rsp + 32]
    mov r9d, KIND_MPA
    jmp .Lmps_open_select
.Lmps_open_private:
    mov rcx, rbx
    call mps_pes_data
    test rax, rax
    jz .Lmps_open_skip
    mov rdx, [rsp + 40]
    cmp rax, rdx
    jae .Lmps_open_skip
    # Private stream 1 audio substreams, as FFmpeg lists them.
    movzx r8d, byte ptr [rax]             # substream
    cmp r8d, 0x80
    jb .Lmps_open_skip
    cmp r8d, 0x87
    jbe .Lmps_open_private_ac3
    mov r9d, KIND_OTHER
    cmp r8d, 0x90                         # DTS 0x88-0x8F
    jb .Lmps_open_private_audio
    cmp r8d, 0x98                         # SDDS 0x90-0x97: no stream
    jb .Lmps_open_skip
    cmp r8d, 0xa0                         # DTS 0x98-0x9F
    jb .Lmps_open_private_audio
    cmp r8d, 0xa7
    jbe .Lmps_open_private_lpcm
    cmp r8d, 0xcf                         # MLP, TrueHD, EVOB AC-3 and E-AC-3
    jbe .Lmps_open_private_audio
    jmp .Lmps_open_skip
.Lmps_open_private_lpcm:
    lea rcx, [rax + 7]
    cmp rcx, rdx
    ja .Lmps_open_skip
    cmp r12d, -1
    jne .Lmps_open_private_dvd            # a selected stream's packets as they come
    cmp byte ptr [rax + 6], 0x80          # dynamic range control off: LPCM, as
    jne .Lmps_open_private_audio          # FFmpeg tells it from MLP
.Lmps_open_private_dvd:
    mov r9d, KIND_DVD
    jmp .Lmps_open_private_audio
.Lmps_open_private_ac3:
    mov r9d, KIND_AC3
    add rax, 4                            # substream, frame count, first access unit
    cmp rax, rdx
    ja .Lmps_open_skip
.Lmps_open_private_audio:
    or r8d, 0xbd00
.Lmps_open_select:
    # R8D=stream id, R9D=kind, RAX=its data.
    mov ecx, r8d
    call mps_audio_seen                  # catalogue later streams too; preserves packet registers
    mov ecx, [rip + mps_audio_count]
    mov [rip + audio_tracks_count], ecx
    cmp r12d, -1
    jne .Lmps_open_selected
    cmp dword ptr [rip + track_choice], 0
    jne .Lmps_open_choice
    cmp r9d, KIND_OTHER                   # the first supported audio stream
    jne .Lmps_open_take
    mov dword ptr [rip + mts_unsupported], 1
    jmp .Lmps_open_skip
.Lmps_open_choice:
    cmp r10d, [rip + track_choice]
    jne .Lmps_open_skip
    mov dword ptr [rip + track_choice_used], 1
    cmp r9d, KIND_OTHER
    jne .Lmps_open_take
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmps_open_bad
.Lmps_open_take:
    mov [rip + audio_track_selected], r10d
    mov r12d, r8d
    mov r13d, r9d
    cmp r9d, KIND_DVD
    jne .Lmps_open_selected
    mov ecx, LPCM_DVD
    call lpcm_begin
.Lmps_open_selected:
    cmp r8d, r12d
    jne .Lmps_open_skip
    cmp r13d, KIND_DVD
    jne .Lmps_open_append
    mov rcx, rax
    mov rdx, [rsp + 40]
    call lpcm_dvd_packet
    cmp eax, 1
    je .Lmps_open_skip
    test eax, eax
    jz .Lmps_open_bad
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmps_open_bad
.Lmps_open_append:
    mov rcx, rax
    mov rdx, [rsp + 40]
    sub rdx, rax
    call mts_append
    test eax, eax
    jz .Lmps_open_bad
.Lmps_open_skip:
    mov rbx, [rsp + 40]
    jmp .Lmps_open_code
.Lmps_open_pack:
    lea rax, [rbx + 14]
    cmp rax, rdi
    ja .Lmps_open_done
    movzx eax, byte ptr [rbx + 4]
    mov ecx, eax
    and ecx, 0xc0
    cmp ecx, 0x40
    jne .Lmps_open_pack_mpeg1
    movzx ecx, byte ptr [rbx + 13]
    and ecx, 7
    lea rbx, [rbx + rcx + 14]             # MPEG-2 pack header and stuffing
    jmp .Lmps_open_code
.Lmps_open_pack_mpeg1:
    and eax, 0xf0
    cmp eax, 0x20
    jne .Lmps_open_resync
    add rbx, 12
    jmp .Lmps_open_code
.Lmps_open_end_code:
    add rbx, 4
    jmp .Lmps_open_code
.Lmps_open_resync:
    inc rbx                               # look for the next start code
    jmp .Lmps_open_code
.Lmps_open_done:
    cmp r12d, -1
    jne .Lmps_open_stream
    cmp dword ptr [rip + track_choice], 0
    je .Lmps_open_none
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED   # no such track
    jmp .Lmps_open_bad
.Lmps_open_none:
    cmp dword ptr [rip + mts_unsupported], 0
    je .Lmps_open_bad
    mov dword ptr [rip + decode_error], MTS_UNSUPPORTED
    jmp .Lmps_open_bad
.Lmps_open_stream:
    mov ecx, r13d
    call mts_open_stream
    test eax, eax
    jz .Lmps_open_failed
    jmp .Lmps_open_return
.Lmps_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lmps_open_failed
    mov dword ptr [rip + decode_error], MTS_MALFORMED
.Lmps_open_failed:
    call mts_close
    xor eax, eax
.Lmps_open_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mps_open
