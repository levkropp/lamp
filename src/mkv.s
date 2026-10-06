# Original Matroska/WebM audio demuxer. MIT, see LICENSE.
# Reference: IETF RFC 9559 (Matroska) and RFC 8794 (EBML).
# Selects one audio track: the first enabled track with a supported codec
# whose FlagDefault is set, else the first enabled supported track. Its
# frames, including Xiph, EBML and fixed lacing, become track packets;
# video, subtitles and other tracks are skipped. Compressed or encrypted
# tracks (ContentEncodings) are not supported. Unknown-size Segment and
# Cluster elements, as written by live recorders, are accepted.
.include "lamp.inc"
.globl mkv_track_number

.equ ID_EBML, 0x1a45dfa3
.equ ID_DOCTYPE, 0x4282
.equ ID_SEGMENT, 0x18538067
.equ ID_TRACKS, 0x1654ae6b
.equ ID_TRACK_ENTRY, 0xae
.equ ID_TRACK_NUMBER, 0xd7
.equ ID_TRACK_TYPE, 0x83
.equ ID_FLAG_ENABLED, 0xb9
.equ ID_FLAG_DEFAULT, 0x88
.equ ID_CODEC_ID, 0x86
.equ ID_CODEC_PRIVATE, 0x63a2
.equ ID_AUDIO, 0xe1
.equ ID_SAMPLING, 0xb5
.equ ID_CHANNELS, 0x9f
.equ ID_BIT_DEPTH, 0x6264
.equ ID_ENCODINGS, 0x6d80
.equ ID_CLUSTER, 0x1f43b675
.equ ID_SIMPLE_BLOCK, 0xa3
.equ ID_BLOCK_GROUP, 0xa0
.equ ID_BLOCK, 0xa1
.equ ID_DISCARD, 0x75a2
.equ ID_CUES, 0x1c53bb6b
.equ ID_TAGS, 0x1254c367
.equ ID_CHAPTERS, 0x1043a770
.equ ID_ATTACHMENTS, 0x1941a469
.equ ID_SEEK_HEAD, 0x114d9b74
.equ ID_INFO, 0x1549a966

RODATA
mkv_doc_matroska: .ascii "matroska"
mkv_doc_webm: .ascii "webm"
# CodecID strings: length byte, text, then the track codec and PCM flags.
mkv_codecs:
    .byte 6
    .ascii "A_OPUS"
    .byte 5, 0
    .byte 8
    .ascii "A_VORBIS"
    .byte 4, 0
    .byte 6
    .ascii "A_FLAC"
    .byte 2, 0
    .byte 9
    .ascii "A_MPEG/L3"
    .byte 3, 0
    .byte 9
    .ascii "A_MPEG/L2"
    .byte 3, 0
    .byte 9
    .ascii "A_MPEG/L1"
    .byte 3, 0
    .byte 13
    .ascii "A_PCM/INT/LIT"
    .byte 1, 0
    .byte 13
    .ascii "A_PCM/INT/BIG"
    .byte 1, 1
    .byte 16
    .ascii "A_PCM/FLOAT/IEEE"
    .byte 1, 2
    .byte 6
    .ascii "A_ALAC"
    .byte 6, 0
    .byte 5
    .ascii "A_AAC"
    .byte 7, 0
    .byte 5
    .ascii "A_AC3"
    .byte 8, 0
    .byte 6
    .ascii "A_EAC3"
    .byte 8, 0                           # recognised; rejects as unsupported
    .byte 10
    .ascii "A_WAVPACK4"
    .byte 9, 0
    .byte 0
.p2align 3

.data
mkv_track_number: .quad 0            # selected track; 0 until Tracks is read
mkv_codec: .long 0
mkv_pcm_flags: .long 0
mkv_private: .quad 0
mkv_private_bytes: .long 0
mkv_rate: .double 0.0
mkv_channels: .long 0
mkv_bits: .long 0
mkv_tracks_seen: .long 0
mkv_discard: .quad 0                 # DiscardPadding ns of the latest block group
mkv_discard_packet: .quad -1         # packet count after that group's block
mkv_vorbis_headers: .zero 3*16
# Candidate track being parsed.
mkv_entry_number: .quad 0
mkv_entry_type: .quad 0
mkv_entry_enabled: .quad 1
mkv_entry_default: .quad 1
mkv_entry_codec: .long 0
mkv_entry_flags: .long 0
mkv_entry_private: .quad 0
mkv_entry_private_bytes: .long 0
mkv_entry_encoded: .long 0
mkv_entry_rate: .double 0.0
mkv_entry_channels: .quad 1
mkv_entry_bits: .quad 0
mkv_selected_default: .long 0

.text
# RCX=element start, RDX=limit -> EAX=ID with its length marker (0 on error),
# RDX=payload bytes (-1 when unknown), R8=payload start. A known payload
# must fit before the limit.
LOCALFN mkv_element
    mov r9, rdx
    cmp rcx, r9
    jae .Lmkv_element_bad
    movzx eax, byte ptr [rcx]
    mov r10d, 1
    cmp eax, 0x80
    jae .Lmkv_id_ready
    mov r10d, 2
    cmp eax, 0x40
    jae .Lmkv_id_ready
    mov r10d, 3
    cmp eax, 0x20
    jae .Lmkv_id_ready
    mov r10d, 4
    cmp eax, 0x10
    jb .Lmkv_element_bad
.Lmkv_id_ready:
    lea r8, [rcx + r10]
    cmp r8, r9
    jae .Lmkv_element_bad
    xor eax, eax
.Lmkv_id_byte:
    shl eax, 8
    movzx edx, byte ptr [rcx]
    or eax, edx
    inc rcx
    dec r10d
    jnz .Lmkv_id_byte
    # Size: leading zeros give its length; all value bits set means unknown.
    movzx edx, byte ptr [rcx]
    test edx, edx
    jz .Lmkv_element_bad
    bsr r10d, edx
    mov r11d, 8
    sub r11d, r10d                       # length in bytes
    lea r8, [rcx + r11]
    cmp r8, r9
    ja .Lmkv_element_bad
    push rbx
    mov ebx, 1
    mov ecx, r10d
    shl ebx, cl
    dec ebx
    and edx, ebx                         # first byte's value bits
    mov r10, rdx
    lea rcx, [r8 + 0]
    sub rcx, r11
    inc rcx
    mov rbx, rdx                         # all-ones check accumulates in RBX
    mov edx, r11d
    dec edx
.Lmkv_size_byte:
    test edx, edx
    jz .Lmkv_size_done
    shl r10, 8
    movzx ebx, byte ptr [rcx]
    or r10, rbx
    inc rcx
    dec edx
    jmp .Lmkv_size_byte
.Lmkv_size_done:
    # Unknown: every value bit is one (7 bits per length byte).
    imul ecx, r11d, 7
    mov rbx, 1
    shl rbx, cl
    dec rbx
    cmp r10, rbx
    pop rbx
    je .Lmkv_size_unknown
    mov rdx, r10
    mov rcx, r9
    sub rcx, r8
    cmp rdx, rcx
    ja .Lmkv_element_bad
    ret
.Lmkv_size_unknown:
    mov rdx, -1
    ret
.Lmkv_element_bad:
    xor eax, eax
    ret
ENDFN mkv_element

# RCX=data, EDX=bytes (0-8) -> RAX=big-endian unsigned value.
LOCALFN mkv_uint
    xor eax, eax
    cmp edx, 8
    ja .Lmkv_uint_done
.Lmkv_uint_byte:
    test edx, edx
    jz .Lmkv_uint_done
    shl rax, 8
    movzx r8d, byte ptr [rcx]
    or rax, r8
    inc rcx
    dec edx
    jmp .Lmkv_uint_byte
.Lmkv_uint_done:
    ret
ENDFN mkv_uint

# RCX=data, EDX=bytes -> XMM0=big-endian float (4 or 8 bytes), else 0.
LOCALFN mkv_float
    xorpd xmm0, xmm0
    cmp edx, 4
    je .Lmkv_float32
    cmp edx, 8
    jne .Lmkv_float_done
    mov rax, [rcx]
    bswap rax
    movq xmm0, rax
    ret
.Lmkv_float32:
    mov eax, [rcx]
    bswap eax
    movd xmm0, eax
    cvtss2sd xmm0, xmm0
.Lmkv_float_done:
    ret
ENDFN mkv_float

# RCX=CodecID text, EDX=bytes (trailing NULs ignored) -> EAX=track codec or 0,
# R8D=PCM flags.
LOCALFN mkv_codec_lookup
    push rsi
    push rdi
.Lmkv_codec_trim:
    test edx, edx
    jz .Lmkv_codec_none
    cmp byte ptr [rcx + rdx - 1], 0
    jne .Lmkv_codec_search
    dec edx
    jmp .Lmkv_codec_trim
.Lmkv_codec_search:
    lea r9, [rip + mkv_codecs]
.Lmkv_codec_entry:
    movzx eax, byte ptr [r9]
    test eax, eax
    jz .Lmkv_codec_none
    cmp eax, edx
    jne .Lmkv_codec_next
    lea rsi, [r9 + 1]
    mov rdi, rcx
    push rcx
    mov ecx, eax
    repe cmpsb
    pop rcx
    jne .Lmkv_codec_next
    movzx eax, byte ptr [r9 + rdx + 1]
    movzx r8d, byte ptr [r9 + rdx + 2]
    jmp .Lmkv_codec_return
.Lmkv_codec_next:
    movzx eax, byte ptr [r9]
    lea r9, [r9 + rax + 3]
    jmp .Lmkv_codec_entry
.Lmkv_codec_none:
    xor eax, eax
    xor r8d, r8d
.Lmkv_codec_return:
    pop rdi
    pop rsi
    ret
ENDFN mkv_codec_lookup

# RCX=TrackEntry payload, RDX=end -> EAX=1 unless malformed. Selects it when
# it is the first usable audio track, or the first with FlagDefault.
LOCALFN mkv_track_entry
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    mov qword ptr [rip + mkv_entry_number], 0
    mov qword ptr [rip + mkv_entry_type], 0
    mov qword ptr [rip + mkv_entry_enabled], 1
    mov qword ptr [rip + mkv_entry_default], 1
    mov dword ptr [rip + mkv_entry_codec], 0
    mov dword ptr [rip + mkv_entry_flags], 0
    mov qword ptr [rip + mkv_entry_private], 0
    mov dword ptr [rip + mkv_entry_private_bytes], 0
    mov dword ptr [rip + mkv_entry_encoded], 0
    xorpd xmm0, xmm0
    movsd [rip + mkv_entry_rate], xmm0
    mov qword ptr [rip + mkv_entry_channels], 1
    mov qword ptr [rip + mkv_entry_bits], 0
.Lmkv_entry_child:
    cmp rsi, rdi
    jae .Lmkv_entry_done
    mov rcx, rsi
    mov rdx, rdi
    call mkv_element
    test eax, eax
    jz .Lmkv_entry_bad
    cmp rdx, -1
    je .Lmkv_entry_bad
    lea rsi, [r8 + rdx]
    cmp eax, ID_TRACK_NUMBER
    je .Lmkv_entry_number
    cmp eax, ID_TRACK_TYPE
    je .Lmkv_entry_type
    cmp eax, ID_FLAG_ENABLED
    je .Lmkv_entry_enabled
    cmp eax, ID_FLAG_DEFAULT
    je .Lmkv_entry_default
    cmp eax, ID_CODEC_ID
    je .Lmkv_entry_codec
    cmp eax, ID_CODEC_PRIVATE
    je .Lmkv_entry_private
    cmp eax, ID_ENCODINGS
    je .Lmkv_entry_encodings
    cmp eax, ID_AUDIO
    je .Lmkv_entry_audio
    jmp .Lmkv_entry_child
.Lmkv_entry_number:
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_number], rax
    jmp .Lmkv_entry_child
.Lmkv_entry_type:
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_type], rax
    jmp .Lmkv_entry_child
.Lmkv_entry_enabled:
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_enabled], rax
    jmp .Lmkv_entry_child
.Lmkv_entry_default:
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_default], rax
    jmp .Lmkv_entry_child
.Lmkv_entry_codec:
    mov rcx, r8
    call mkv_codec_lookup
    mov [rip + mkv_entry_codec], eax
    mov [rip + mkv_entry_flags], r8d
    jmp .Lmkv_entry_child
.Lmkv_entry_private:
    mov [rip + mkv_entry_private], r8
    mov [rip + mkv_entry_private_bytes], edx
    jmp .Lmkv_entry_child
.Lmkv_entry_encodings:
    mov dword ptr [rip + mkv_entry_encoded], 1
    jmp .Lmkv_entry_child
.Lmkv_entry_audio:
    lea rbx, [r8 + rdx]                  # Audio children
.Lmkv_audio_child:
    cmp r8, rbx
    jae .Lmkv_entry_child
    mov rcx, r8
    mov rdx, rbx
    call mkv_element
    test eax, eax
    jz .Lmkv_entry_bad
    cmp rdx, -1
    je .Lmkv_entry_bad
    lea r11, [r8 + rdx]
    mov [rsp + 32], r11
    cmp eax, ID_SAMPLING
    jne .Lmkv_audio_channels
    mov rcx, r8
    call mkv_float
    movsd [rip + mkv_entry_rate], xmm0
    jmp .Lmkv_audio_next
.Lmkv_audio_channels:
    cmp eax, ID_CHANNELS
    jne .Lmkv_audio_bits
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_channels], rax
    jmp .Lmkv_audio_next
.Lmkv_audio_bits:
    cmp eax, ID_BIT_DEPTH
    jne .Lmkv_audio_next
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_entry_bits], rax
.Lmkv_audio_next:
    mov r8, [rsp + 32]
    jmp .Lmkv_audio_child
.Lmkv_entry_done:
    # Usable: enabled audio, supported codec, no content encodings.
    cmp qword ptr [rip + mkv_entry_type], 2
    jne .Lmkv_entry_ok
    cmp qword ptr [rip + mkv_entry_enabled], 0
    je .Lmkv_entry_ok
    cmp dword ptr [rip + mkv_entry_codec], 0
    je .Lmkv_entry_ok
    cmp dword ptr [rip + mkv_entry_encoded], 0
    jne .Lmkv_entry_ok
    cmp qword ptr [rip + mkv_entry_number], 0
    je .Lmkv_entry_bad
    cmp qword ptr [rip + mkv_track_number], 0
    je .Lmkv_entry_select
    cmp dword ptr [rip + mkv_selected_default], 0
    jne .Lmkv_entry_ok
    cmp qword ptr [rip + mkv_entry_default], 0
    je .Lmkv_entry_ok
.Lmkv_entry_select:
    mov rax, [rip + mkv_entry_number]
    mov [rip + mkv_track_number], rax
    mov eax, [rip + mkv_entry_codec]
    mov [rip + mkv_codec], eax
    mov eax, [rip + mkv_entry_flags]
    mov [rip + mkv_pcm_flags], eax
    mov rax, [rip + mkv_entry_private]
    mov [rip + mkv_private], rax
    mov eax, [rip + mkv_entry_private_bytes]
    mov [rip + mkv_private_bytes], eax
    movsd xmm0, [rip + mkv_entry_rate]
    movsd [rip + mkv_rate], xmm0
    mov rax, [rip + mkv_entry_channels]
    mov [rip + mkv_channels], eax
    mov rax, [rip + mkv_entry_bits]
    mov [rip + mkv_bits], eax
    xor eax, eax
    cmp qword ptr [rip + mkv_entry_default], 0
    setne al
    mov [rip + mkv_selected_default], eax
.Lmkv_entry_ok:
    mov eax, 1
    jmp .Lmkv_entry_return
.Lmkv_entry_bad:
    xor eax, eax
.Lmkv_entry_return:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mkv_track_entry

# RCX=Block/SimpleBlock payload, RDX=bytes -> EAX=1 unless malformed. Adds
# the selected track's frames to the track list.
LOCALFN mkv_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    lea rdi, [rcx + rdx]
    # Track number: an EBML variable-length integer.
    cmp rsi, rdi
    jae .Lmkv_block_bad
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz .Lmkv_block_bad
    bsr ecx, eax
    mov r8d, 8
    sub r8d, ecx                         # length
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    lea r9, [rsi + r8]
    cmp r9, rdi
    ja .Lmkv_block_bad
    inc rsi
.Lmkv_block_track:
    dec r8d
    jz .Lmkv_block_track_done
    shl rax, 8
    movzx edx, byte ptr [rsi]
    or rax, rdx
    inc rsi
    jmp .Lmkv_block_track
.Lmkv_block_track_done:
    cmp rax, [rip + mkv_track_number]
    jne .Lmkv_block_ok                   # another track
    lea rax, [rsi + 3]                   # 16-bit timestamp and flags
    cmp rax, rdi
    ja .Lmkv_block_bad
    movzx ebx, byte ptr [rsi + 2]
    shr ebx, 1
    and ebx, 3                           # lacing
    mov rsi, rax
    test ebx, ebx
    jnz .Lmkv_block_laced
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    call track_add
    test eax, eax
    jz .Lmkv_block_bad
    jmp .Lmkv_block_ok
.Lmkv_block_laced:
    cmp rsi, rdi
    jae .Lmkv_block_bad
    movzx r12d, byte ptr [rsi]
    inc r12d                             # frames
    inc rsi
    cmp ebx, 2
    je .Lmkv_block_fixed
    # Xiph or EBML lacing: sizes of all frames but the last, stored on the
    # stack area below; the last frame takes the remaining bytes.
    sub rsp, 256*8
    xor r13d, r13d                       # frame index
    xor r9d, r9d                         # previous EBML size
.Lmkv_lace_size:
    lea eax, [r12 - 1]
    cmp r13d, eax
    jae .Lmkv_lace_sizes_done
    cmp ebx, 1
    jne .Lmkv_lace_ebml
    xor edx, edx
.Lmkv_lace_xiph:
    cmp rsi, rdi
    jae .Lmkv_lace_bad
    movzx eax, byte ptr [rsi]
    inc rsi
    add rdx, rax
    cmp eax, 255
    je .Lmkv_lace_xiph
    jmp .Lmkv_lace_store
.Lmkv_lace_ebml:
    cmp rsi, rdi
    jae .Lmkv_lace_bad
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz .Lmkv_lace_bad
    bsr ecx, eax
    mov r8d, 8
    sub r8d, ecx                         # length n
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    lea r10, [rsi + r8]
    cmp r10, rdi
    ja .Lmkv_lace_bad
    inc rsi
    mov r10d, r8d
.Lmkv_lace_ebml_byte:
    dec r10d
    jz .Lmkv_lace_ebml_value
    shl rax, 8
    movzx edx, byte ptr [rsi]
    or rax, rdx
    inc rsi
    jmp .Lmkv_lace_ebml_byte
.Lmkv_lace_ebml_value:
    mov rdx, rax
    test r13d, r13d
    jz .Lmkv_lace_ebml_first
    # Later sizes are signed differences: value - (2^(7n-1) - 1).
    imul ecx, r8d, 7
    dec ecx
    mov r10, 1
    shl r10, cl
    dec r10
    sub rdx, r10
    add rdx, r9
    js .Lmkv_lace_bad
.Lmkv_lace_ebml_first:
    mov r9, rdx
.Lmkv_lace_store:
    mov [rsp + r13*8], rdx
    inc r13d
    jmp .Lmkv_lace_size
.Lmkv_lace_sizes_done:
    # Frames follow the sizes.
    xor r13d, r13d
.Lmkv_lace_frame:
    lea eax, [r12 - 1]
    cmp r13d, eax
    jae .Lmkv_lace_last
    mov rdx, [rsp + r13*8]
    mov rax, rdi
    sub rax, rsi
    cmp rdx, rax
    ja .Lmkv_lace_bad
    mov rcx, rsi
    add rsi, rdx
    sub rsp, 32
    call track_add
    add rsp, 32
    test eax, eax
    jz .Lmkv_lace_bad
    inc r13d
    jmp .Lmkv_lace_frame
.Lmkv_lace_last:
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    sub rsp, 32
    call track_add
    add rsp, 32
    add rsp, 256*8
    test eax, eax
    jz .Lmkv_block_bad
    jmp .Lmkv_block_ok
.Lmkv_lace_bad:
    add rsp, 256*8
    jmp .Lmkv_block_bad
.Lmkv_block_fixed:
    mov rax, rdi
    sub rax, rsi
    xor edx, edx
    div r12
    test rdx, rdx
    jnz .Lmkv_block_bad
    mov r13, rax                         # frame bytes
.Lmkv_fixed_frame:
    mov rcx, rsi
    mov rdx, r13
    add rsi, r13
    call track_add
    test eax, eax
    jz .Lmkv_block_bad
    dec r12d
    jnz .Lmkv_fixed_frame
.Lmkv_block_ok:
    mov eax, 1
    jmp .Lmkv_block_return
.Lmkv_block_bad:
    xor eax, eax
.Lmkv_block_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mkv_block

# EAX=element ID -> EAX=1 when it is a Segment-level element, which ends an
# unknown-size Cluster.
LOCALFN mkv_level1
    cmp eax, ID_CLUSTER
    je .Lmkv_level1_yes
    cmp eax, ID_CUES
    je .Lmkv_level1_yes
    cmp eax, ID_TAGS
    je .Lmkv_level1_yes
    cmp eax, ID_CHAPTERS
    je .Lmkv_level1_yes
    cmp eax, ID_ATTACHMENTS
    je .Lmkv_level1_yes
    cmp eax, ID_SEEK_HEAD
    je .Lmkv_level1_yes
    cmp eax, ID_INFO
    je .Lmkv_level1_yes
    cmp eax, ID_TRACKS
    je .Lmkv_level1_yes
    xor eax, eax
    ret
.Lmkv_level1_yes:
    mov eax, 1
    ret
ENDFN mkv_level1

# RCX=mapped start, RDX=end -> EAX=1 with the selected track's packets listed
# and its codec opened by track_finish.
FN mkv_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    mov qword ptr [rip + mkv_track_number], 0
    mov dword ptr [rip + mkv_selected_default], 0
    mov dword ptr [rip + mkv_tracks_seen], 0
    mov qword ptr [rip + mkv_discard], 0
    mov qword ptr [rip + mkv_discard_packet], -1
    # EBML header with DocType matroska or webm.
    mov rcx, rsi
    mov rdx, rdi
    call mkv_element
    cmp eax, ID_EBML
    jne .Lmkv_open_bad
    cmp rdx, -1
    je .Lmkv_open_bad
    lea r12, [r8 + rdx]                  # header end
    xor r13d, r13d                       # DocType accepted
.Lmkv_header_child:
    cmp r8, r12
    jae .Lmkv_header_done
    mov rcx, r8
    mov rdx, r12
    call mkv_element
    test eax, eax
    jz .Lmkv_open_bad
    cmp rdx, -1
    je .Lmkv_open_bad
    lea r14, [r8 + rdx]
    cmp eax, ID_DOCTYPE
    jne .Lmkv_header_next
    # Trailing NULs are padding.
.Lmkv_doctype_trim:
    test rdx, rdx
    jz .Lmkv_header_next
    cmp byte ptr [r8 + rdx - 1], 0
    jne .Lmkv_doctype_compare
    dec rdx
    jmp .Lmkv_doctype_trim
.Lmkv_doctype_compare:
    cmp rdx, 8
    jne .Lmkv_doctype_webm
    mov rax, [r8]
    cmp rax, [rip + mkv_doc_matroska]
    jne .Lmkv_header_next
    mov r13d, 1
    jmp .Lmkv_header_next
.Lmkv_doctype_webm:
    cmp rdx, 4
    jne .Lmkv_header_next
    mov eax, [r8]
    cmp eax, [rip + mkv_doc_webm]
    jne .Lmkv_header_next
    mov r13d, 1
.Lmkv_header_next:
    mov r8, r14
    jmp .Lmkv_header_child
.Lmkv_header_done:
    test r13d, r13d
    jz .Lmkv_open_bad
    # Segment: an unknown size extends to the end of the file.
    mov rcx, r12
    mov rdx, rdi
    call mkv_element
    cmp eax, ID_SEGMENT
    jne .Lmkv_open_bad
    mov rsi, r8
    cmp rdx, -1
    je .Lmkv_segment_ready
    lea rdi, [r8 + rdx]
.Lmkv_segment_ready:
    mov ecx, 1                           # placeholder codec until Tracks
    call track_begin
    test eax, eax
    jz .Lmkv_open_bad
.Lmkv_top:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmkv_top_continue
    cmp dword ptr [rax], 0
    jne .Lmkv_open_bad
.Lmkv_top_continue:
    cmp rsi, rdi
    jae .Lmkv_top_done
    mov rcx, rsi
    mov rdx, rdi
    call mkv_element
    test eax, eax
    jz .Lmkv_open_bad
    mov r12, r8                          # payload
    mov r13, rdx                         # bytes or -1
    cmp eax, ID_TRACKS
    je .Lmkv_tracks
    cmp eax, ID_CLUSTER
    je .Lmkv_cluster
    cmp rdx, -1
    je .Lmkv_open_bad                    # only Segment and Cluster may be unsized
    lea rsi, [r8 + rdx]
    jmp .Lmkv_top
.Lmkv_tracks:
    cmp rdx, -1
    je .Lmkv_open_bad
    cmp dword ptr [rip + mkv_tracks_seen], 0
    jne .Lmkv_open_bad
    mov dword ptr [rip + mkv_tracks_seen], 1
    lea r14, [r8 + rdx]
.Lmkv_track_child:
    cmp r12, r14
    jae .Lmkv_tracks_done
    mov rcx, r12
    mov rdx, r14
    call mkv_element
    test eax, eax
    jz .Lmkv_open_bad
    cmp rdx, -1
    je .Lmkv_open_bad
    lea r12, [r8 + rdx]
    cmp eax, ID_TRACK_ENTRY
    jne .Lmkv_track_child
    mov rcx, r8
    mov rdx, r12
    call mkv_track_entry
    test eax, eax
    jz .Lmkv_open_bad
    jmp .Lmkv_track_child
.Lmkv_tracks_done:
    mov rsi, r14
    cmp qword ptr [rip + mkv_track_number], 0
    je .Lmkv_open_bad                    # no supported audio track
    mov eax, [rip + mkv_codec]
    mov [rip + track_codec], eax
    jmp .Lmkv_top
.Lmkv_cluster:
    cmp dword ptr [rip + mkv_tracks_seen], 0
    je .Lmkv_open_bad
    mov r14, rdi                         # unknown size: until a level-1 element
    cmp r13, -1
    je .Lmkv_cluster_child
    lea r14, [r12 + r13]
.Lmkv_cluster_child:
    cmp r12, r14
    jae .Lmkv_cluster_done
    mov rcx, r12
    mov rdx, r14
    call mkv_element
    test eax, eax
    jz .Lmkv_open_bad
    cmp r13, -1
    jne .Lmkv_cluster_sized
    push rax
    push rdx
    push r8
    sub rsp, 8
    call mkv_level1
    add rsp, 8
    mov ecx, eax
    pop r8
    pop rdx
    pop rax
    test ecx, ecx
    jnz .Lmkv_cluster_done               # the next top-level element
.Lmkv_cluster_sized:
    cmp rdx, -1
    je .Lmkv_open_bad
    lea r12, [r8 + rdx]
    cmp eax, ID_SIMPLE_BLOCK
    je .Lmkv_simple_block
    cmp eax, ID_BLOCK_GROUP
    jne .Lmkv_cluster_child
    # BlockGroup: Block and DiscardPadding.
    mov qword ptr [rip + mkv_discard], 0
    mov rax, [rip + track_count]
    mov [rip + mkv_group_packets], rax
    mov rbx, r8
.Lmkv_group_child:
    cmp rbx, r12
    jae .Lmkv_group_done
    mov rcx, rbx
    mov rdx, r12
    call mkv_element
    test eax, eax
    jz .Lmkv_open_bad
    cmp rdx, -1
    je .Lmkv_open_bad
    lea rbx, [r8 + rdx]
    cmp eax, ID_BLOCK
    jne .Lmkv_group_discard
    mov rcx, r8
    call mkv_block
    test eax, eax
    jz .Lmkv_open_bad
    jmp .Lmkv_group_child
.Lmkv_group_discard:
    cmp eax, ID_DISCARD
    jne .Lmkv_group_child
    test rdx, rdx
    jz .Lmkv_group_child
    test byte ptr [r8], 0x80             # signed; negative padding is invalid
    jnz .Lmkv_open_bad
    mov rcx, r8
    call mkv_uint
    mov [rip + mkv_discard], rax
    jmp .Lmkv_group_child
.Lmkv_group_done:
    cmp qword ptr [rip + mkv_discard], 0
    je .Lmkv_cluster_child
    mov rax, [rip + track_count]
    cmp rax, [rip + mkv_group_packets]
    je .Lmkv_cluster_child               # another track's block
    # Only the final packet may discard padding; a later packet rejects.
    cmp qword ptr [rip + mkv_discard_packet], -1
    jne .Lmkv_open_bad
    mov rax, [rip + track_count]
    mov [rip + mkv_discard_packet], rax
    mov rax, [rip + mkv_discard]
    mov [rip + mkv_discard_ns], rax
    jmp .Lmkv_cluster_child
.Lmkv_simple_block:
    mov rcx, r8
    call mkv_block
    test eax, eax
    jz .Lmkv_open_bad
    jmp .Lmkv_cluster_child
.Lmkv_cluster_done:
    mov rsi, r12
    jmp .Lmkv_top
.Lmkv_top_done:
    cmp dword ptr [rip + mkv_tracks_seen], 0
    je .Lmkv_open_bad
    mov rax, [rip + mkv_discard_packet]
    cmp rax, -1
    je .Lmkv_config
    cmp rax, [rip + track_count]
    jne .Lmkv_open_bad                   # padding must belong to the last packet
    mov rax, [rip + mkv_discard_ns]
    mov [rip + track_end_trim_ns], rax   # converted at the codec's rate
.Lmkv_config:
    mov rcx, [rip + mkv_private]
    mov edx, [rip + mkv_private_bytes]
    mov [rip + track_config], rcx
    mov [rip + track_config_bytes], edx
    mov eax, [rip + mkv_codec]
    cmp eax, 4
    je .Lmkv_config_vorbis
    cmp eax, 1
    je .Lmkv_config_pcm
    cmp eax, 3
    je .Lmkv_finish
    cmp eax, 8
    je .Lmkv_finish                      # AC-3 frames describe themselves
    cmp eax, 9
    je .Lmkv_finish                      # so do WavPack frames (CodecPrivate is the version)
    test rcx, rcx                        # Opus, FLAC, ALAC and AAC need CodecPrivate
    jz .Lmkv_open_bad
    jmp .Lmkv_finish
.Lmkv_config_vorbis:
    # Xiph lacing of three headers: count-1 (2), two sizes, then the data.
    test rcx, rcx
    jz .Lmkv_open_bad
    lea r9, [rcx + rdx]
    cmp edx, 3
    jb .Lmkv_open_bad
    cmp byte ptr [rcx], 2
    jne .Lmkv_open_bad
    inc rcx
    lea r10, [rip + mkv_vorbis_headers]
    xor r11d, r11d
.Lmkv_vorbis_size:
    xor eax, eax
.Lmkv_vorbis_lace:
    cmp rcx, r9
    jae .Lmkv_open_bad
    movzx edx, byte ptr [rcx]
    inc rcx
    add rax, rdx
    cmp edx, 255
    je .Lmkv_vorbis_lace
    mov r8, r11
    shl r8, 4
    mov [r10 + r8 + 8], rax
    inc r11d
    cmp r11d, 2
    jb .Lmkv_vorbis_size
    # Headers: first, second, and the remainder.
    mov [r10], rcx
    add rcx, [r10 + 8]
    jc .Lmkv_open_bad
    mov [r10 + 16], rcx
    add rcx, [r10 + 24]
    jc .Lmkv_open_bad
    cmp rcx, r9
    ja .Lmkv_open_bad
    mov [r10 + 32], rcx
    mov rax, r9
    sub rax, rcx
    mov [r10 + 40], rax
    mov [rip + track_config], r10
    jmp .Lmkv_finish
.Lmkv_config_pcm:
    mov eax, [rip + mkv_channels]
    mov [rip + track_pcm_channels], eax
    mov eax, [rip + mkv_bits]
    mov [rip + track_pcm_bits], eax
    mov eax, [rip + mkv_pcm_flags]
    mov [rip + track_pcm_flags], eax
    movsd xmm0, [rip + mkv_rate]         # integral 8-192 kHz
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    ucomisd xmm0, xmm1
    jne .Lmkv_open_bad
    jp .Lmkv_open_bad
    cmp rax, 8000
    jb .Lmkv_open_bad
    cmp rax, 192000
    ja .Lmkv_open_bad
    mov [rip + sample_rate], eax
.Lmkv_finish:
    call track_finish
    test eax, eax
    jz .Lmkv_open_bad
    mov dword ptr [rip + codec_kind], 8
    mov eax, 1
    jmp .Lmkv_open_return
.Lmkv_open_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lmkv_open_failed
    mov dword ptr [rip + decode_error], 70
.Lmkv_open_failed:
    xor eax, eax
.Lmkv_open_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mkv_open

.data
mkv_discard_ns: .quad 0
mkv_group_packets: .quad 0
