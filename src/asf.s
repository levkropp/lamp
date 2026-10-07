# Original ASF audio demuxer in x86-64 assembly. MIT, see LICENSE.
# Local, unencrypted ASF: bounded GUID objects, audio ordinals, packet
# length fields, interleaving, fragmented and compressed media objects.
# WAVE formats reuse AVI's format policy and gathered Wave64 image; AAC
# with an AudioSpecificConfig uses complete rebuilt objects as track packets.
# No timestamps are synthesized: the presented audio is consecutive decoded
# samples. Network chunk framing, DVR-MS and scrambled audio stay unsupported.
.include "lamp.inc"
.globl asf_open, asf_stream
.equ ASF_MALFORMED, 100
.equ ASF_UNSUPPORTED, 101
.equ ASF_LIMIT, 1 << 24
.equ ASF_HEADER_OBJECTS, 4096
.equ ASF_FMT_LIMIT, 18 + 65535

RODATA
asf_header_guid: .quad 0x11cf668e75b22630, 0x6cce6200aa00d9a6
asf_file_guid: .quad 0x11cfa9478cabdca1, 0x6553200cc000e48e
asf_stream_guid: .quad 0x11cfa9b7b7dc0791, 0x6553200cc000e68e
asf_audio_guid: .quad 0x11cf5b4df8699e40, 0x2b445c5f8000fda8
asf_data_guid: .quad 0x11cf668e75b22636, 0x6cce6200aa00d9a6
asf_extension_guid: .quad 0x11cfa92e5fbf03b5, 0x6553200cc000e38e
asf_marker_guid: .quad 0x11cfa951f487cd01, 0x6553200cc000e68e
asf_encrypt_guid: .quad 0x11d2bd232211b3fb, 0x6efc55c9a000b7b4
asf_ext_encrypt_guid: .quad 0x4c172622298ae614, 0x9c28e97ee0da35b9

.data
asf_file: .quad 0
asf_end: .quad 0
asf_header_end: .quad 0
asf_file_id: .zero 16
asf_min_packet: .long 0
asf_max_packet: .long 0
asf_file_seen: .long 0
asf_top_objects: .long 0
asf_top_markers: .long 0
asf_all_objects: .long 0
asf_broadcast: .long 0
asf_stream: .long 0                 # stream id 1..127, 0 when none
asf_mode: .long 0                   # AVI format mode: Wave64/AAC/ADTS
asf_tag: .long 0
asf_fmt_bytes: .long 0
asf_fmt: .quad 0
asf_packets: .quad 0
asf_seen_ids: .zero 128
asf_pending: .long 0
asf_object: .long 0
asf_object_size: .long 0
asf_object_have: .long 0
asf_object_start: .quad 0
asf_payload_stream: .long 0
asf_payload_object: .long 0
asf_payload_offset: .long 0
asf_payload_replic: .long 0
asf_payload_size: .long 0

.text
# RCX=data, RDX=GUID -> ZF=1 if equal. Caller bounds the sixteen bytes.
LOCALFN asf_guid
    mov rax, [rcx]
    xor rax, [rdx]
    mov r8, [rcx + 8]
    xor r8, [rdx + 8]
    or rax, r8
    ret
ENDFN asf_guid

LOCALFN asf_cancelled
    xor eax, eax
    mov rcx, [rip + ogg_cancel_ptr]
    test rcx, rcx
    jz .Lasf_cancel_return
    cmp dword ptr [rcx], 0
    setne al
.Lasf_cancel_return:
    ret
ENDFN asf_cancelled

# Internal cursor convention: RSI..RDI; ECX=2-bit length code. Returns
# EAX=value (code 0 means zero), advances RSI; CF=1 on a short field.
LOCALFN asf_var
    and ecx, 3
    xor eax, eax
    test ecx, ecx
    jz .Lasf_var_ok
    mov edx, ecx
    cmp ecx, 3
    jne .Lasf_var_bound
    mov edx, 4
.Lasf_var_bound:
    mov r8, rdi
    sub r8, rsi
    cmp r8, rdx
    jb .Lasf_var_bad
    cmp ecx, 1
    je .Lasf_var_byte
    cmp ecx, 2
    je .Lasf_var_word
    mov eax, [rsi]
    jmp .Lasf_var_advance
.Lasf_var_word:
    movzx eax, word ptr [rsi]
    jmp .Lasf_var_advance
.Lasf_var_byte:
    movzx eax, byte ptr [rsi]
.Lasf_var_advance:
    add rsi, rdx
.Lasf_var_ok:
    clc
    ret
.Lasf_var_bad:
    stc
    ret
ENDFN asf_var

# RCX=Stream Properties object, RDX=its end -> EAX=1/0. Count unsupported
# audio too. Duplicate stream ids and type-specific lengths are rejected.
LOCALFN asf_stream_properties
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    sub rdx, rcx
    cmp rdx, 78
    jb .Lasf_stream_bad
    movzx ebx, word ptr [rsi + 72]
    mov eax, ebx
    and eax, 127
    jz .Lasf_stream_bad
    lea rcx, [rip + asf_seen_ids]
    cmp byte ptr [rcx + rax], 0
    jne .Lasf_stream_bad
    mov byte ptr [rcx + rax], 1
    mov eax, [rsi + 64]
    mov ecx, [rsi + 68]
    add rax, rcx
    add rax, 78
    cmp rax, rdx
    ja .Lasf_stream_bad
    lea rcx, [rsi + 24]
    lea rdx, [rip + asf_audio_guid]
    call asf_guid
    jnz .Lasf_stream_ok
    inc dword ptr [rip + audio_tracks_count]
    mov eax, [rip + track_choice]
    test eax, eax
    jz .Lasf_stream_auto
    cmp eax, [rip + audio_tracks_count]
    jne .Lasf_stream_ok
    mov dword ptr [rip + track_choice_used], 1
    jmp .Lasf_stream_choose
.Lasf_stream_auto:
    cmp dword ptr [rip + asf_stream], 0
    jne .Lasf_stream_ok
.Lasf_stream_choose:
    test ebx, 0x8000                    # encrypted stream is unavailable
    jnz .Lasf_stream_ok
    lea rcx, [rsi + 78]
    mov edx, [rsi + 64]
    cmp edx, ASF_FMT_LIMIT
    ja .Lasf_stream_ok
    call avi_format
    test eax, eax
    jz .Lasf_stream_ok
    # Some producers include spreading data outside its advertised length.
    # Span 1 is already in order; span >1 needs descrambling not implemented.
    mov r8d, [rsi + 64]
    lea r8, [rsi + r8 + 78]
    cmp r8, rdi
    jae .Lasf_stream_take
    cmp byte ptr [r8], 1
    ja .Lasf_stream_ok
.Lasf_stream_take:
    mov [rip + asf_tag], eax
    mov [rip + asf_mode], edx
    and ebx, 127
    mov [rip + asf_stream], ebx
    lea rax, [rsi + 78]
    mov [rip + asf_fmt], rax
    mov eax, [rsi + 64]
    mov [rip + asf_fmt_bytes], eax
    mov eax, [rip + audio_tracks_count]
    mov [rip + audio_track_selected], eax
.Lasf_stream_ok:
    mov eax, 1
    jmp .Lasf_stream_return
.Lasf_stream_bad:
    xor eax, eax
.Lasf_stream_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_stream_properties

# RCX=objects, RDX=end, R8D=depth -> EAX=1/0. Unknown GUIDs are skipped
# exactly once. Header Extensions are parsed within their explicit bounds.
LOCALFN asf_objects
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    cmp r12d, 4
    ja .Lasf_objects_bad
.Lasf_objects_next:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_objects_bad
    cmp rsi, rdi
    je .Lasf_objects_done
    mov rax, rdi
    sub rax, rsi
    cmp rax, 24
    jb .Lasf_objects_bad
    mov rbx, [rsi + 16]
    cmp rbx, 24
    jb .Lasf_objects_bad
    cmp rbx, rax
    ja .Lasf_objects_bad
    lea r13, [rsi + rbx]
    inc dword ptr [rip + asf_all_objects]
    cmp dword ptr [rip + asf_all_objects], ASF_HEADER_OBJECTS
    ja .Lasf_objects_unsupported
    test r12d, r12d
    jnz .Lasf_objects_counted
    inc dword ptr [rip + asf_top_objects]
.Lasf_objects_counted:
    mov rcx, rsi
    lea rdx, [rip + asf_file_guid]
    call asf_guid
    jz .Lasf_objects_file
    mov rcx, rsi
    lea rdx, [rip + asf_stream_guid]
    call asf_guid
    jz .Lasf_objects_stream
    mov rcx, rsi
    lea rdx, [rip + asf_extension_guid]
    call asf_guid
    jz .Lasf_objects_extension
    mov rcx, rsi
    lea rdx, [rip + asf_encrypt_guid]
    call asf_guid
    jz .Lasf_objects_unsupported
    mov rcx, rsi
    lea rdx, [rip + asf_ext_encrypt_guid]
    call asf_guid
    jz .Lasf_objects_unsupported
    test r12d, r12d
    jnz .Lasf_objects_advance
    cmp rbx, 48
    jb .Lasf_objects_advance
    mov rcx, rsi
    lea rdx, [rip + asf_marker_guid]
    call asf_guid
    jnz .Lasf_objects_advance
    inc dword ptr [rip + asf_top_markers]
    jmp .Lasf_objects_advance
.Lasf_objects_file:
    cmp dword ptr [rip + asf_file_seen], 0
    jne .Lasf_objects_bad
    cmp rbx, 104
    jb .Lasf_objects_bad
    mov dword ptr [rip + asf_file_seen], 1
    mov rax, [rsi + 24]
    mov [rip + asf_file_id], rax
    mov rax, [rsi + 32]
    mov [rip + asf_file_id + 8], rax
    mov eax, [rsi + 88]
    and eax, 1
    mov [rip + asf_broadcast], eax
    mov eax, [rsi + 92]
    mov edx, [rsi + 96]
    test eax, eax
    jz .Lasf_objects_bad
    cmp eax, edx
    ja .Lasf_objects_bad
    cmp edx, ASF_LIMIT
    ja .Lasf_objects_unsupported
    mov [rip + asf_min_packet], eax
    mov [rip + asf_max_packet], edx
    jmp .Lasf_objects_advance
.Lasf_objects_stream:
    mov rcx, rsi
    mov rdx, r13
    call asf_stream_properties
    test eax, eax
    jz .Lasf_objects_bad
    jmp .Lasf_objects_advance
.Lasf_objects_extension:
    cmp rbx, 46
    jb .Lasf_objects_bad
    mov edx, [rsi + 42]
    lea rax, [rdx + 46]
    cmp rax, rbx
    jne .Lasf_objects_bad
    lea rcx, [rsi + 46]
    add rdx, rcx
    lea r8d, [r12 + 1]
    call asf_objects
    test eax, eax
    jz .Lasf_objects_bad
.Lasf_objects_advance:
    mov rsi, r13
    jmp .Lasf_objects_next
.Lasf_objects_unsupported:
    mov dword ptr [rip + decode_error], ASF_UNSUPPORTED
.Lasf_objects_bad:
    xor eax, eax
    jmp .Lasf_objects_return
.Lasf_objects_done:
    mov eax, 1
.Lasf_objects_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_objects

# -> EAX=1. Adds the completed gathered object to an AAC packet track.
LOCALFN asf_complete
    sub rsp, 40
    mov dword ptr [rip + asf_pending], 0
    mov eax, 1
    cmp dword ptr [rip + asf_mode], 1
    jne .Lasf_complete_return
    mov rcx, [rip + mts_buffer]
    add rcx, [rip + asf_object_start]
    mov edx, [rip + asf_object_have]
    call track_add
.Lasf_complete_return:
    add rsp, 40
    ret
ENDFN asf_complete

# RCX=payload, EDX=bytes. Validates selected media-object continuity and
# bounds before appending. Replicated data size 0 may continue an object
# whose size was established earlier; it cannot start an unknown-sized one.
LOCALFN asf_fragment
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov ebx, edx
    test ebx, ebx
    jz .Lasf_fragment_bad
    cmp dword ptr [rip + asf_payload_offset], 0
    jne .Lasf_fragment_continue
    cmp dword ptr [rip + asf_pending], 0
    jne .Lasf_fragment_bad
    mov eax, [rip + asf_payload_object]
    mov [rip + asf_object], eax
    mov eax, [rip + asf_payload_size]
    cmp dword ptr [rip + asf_payload_replic], 0
    je .Lasf_fragment_bad
.Lasf_fragment_size:
    test eax, eax
    jz .Lasf_fragment_bad
    cmp eax, ASF_LIMIT
    ja .Lasf_fragment_bad
    mov [rip + asf_object_size], eax
    mov dword ptr [rip + asf_object_have], 0
    mov rax, [rip + mts_bytes]
    mov [rip + asf_object_start], rax
    mov dword ptr [rip + asf_pending], 1
    jmp .Lasf_fragment_append
.Lasf_fragment_continue:
    cmp dword ptr [rip + asf_pending], 1
    jne .Lasf_fragment_bad
    mov eax, [rip + asf_payload_object]
    cmp eax, [rip + asf_object]
    jne .Lasf_fragment_bad
    mov eax, [rip + asf_payload_offset]
    cmp eax, [rip + asf_object_have]
    jne .Lasf_fragment_bad
    cmp dword ptr [rip + asf_payload_replic], 0
    je .Lasf_fragment_append
    mov eax, [rip + asf_payload_size]
    cmp eax, [rip + asf_object_size]
    jne .Lasf_fragment_bad
.Lasf_fragment_append:
    mov eax, [rip + asf_object_size]
    sub eax, [rip + asf_object_have]
    cmp ebx, eax
    ja .Lasf_fragment_bad
    mov rcx, rsi
    mov edx, ebx
    call mts_append
    test eax, eax
    jz .Lasf_fragment_bad
    add [rip + asf_object_have], ebx
    mov eax, [rip + asf_object_have]
    cmp eax, [rip + asf_object_size]
    jne .Lasf_fragment_ok
    call asf_complete
    jmp .Lasf_fragment_return
.Lasf_fragment_ok:
    mov eax, 1
    jmp .Lasf_fragment_return
.Lasf_fragment_bad:
    xor eax, eax
.Lasf_fragment_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN asf_fragment

# RCX=packet, RDX=data end -> RAX=next physical packet or 0 on failure.
# RSI..RDI bound all variable fields. Payloads of other streams are skipped
# after their complete framing is checked, without allocating object buffers.
LOCALFN asf_packet
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rsi, rcx
    mov [rsp + 32], rcx
    mov rdi, rdx
    mov ecx, 1
    call asf_var
    jc .Lasf_packet_bad
    test eax, 0x80
    jz .Lasf_packet_flags
    test eax, 0x70                     # nonstandard ECC layouts unsupported
    jnz .Lasf_packet_bad
    and eax, 15
    mov rdx, rdi
    sub rdx, rsi
    cmp rax, rdx
    ja .Lasf_packet_bad
    add rsi, rax
    mov ecx, 1
    call asf_var
    jc .Lasf_packet_bad
.Lasf_packet_flags:
    mov r12d, eax
    test eax, 0x80
    jnz .Lasf_packet_bad
    mov ecx, 1
    call asf_var
    jc .Lasf_packet_bad
    mov r13d, eax
    # ASF always has a one-byte stream-number field (length type 01).
    and eax, 0xc0
    cmp eax, 0x40
    jne .Lasf_packet_bad
    mov ecx, r12d
    shr ecx, 5
    call asf_var
    jc .Lasf_packet_bad
    test eax, eax
    jnz .Lasf_packet_length
    test r12d, 0x60                   # explicit length zero is invalid
    jnz .Lasf_packet_bad
    mov eax, [rip + asf_max_packet]
.Lasf_packet_length:
    cmp eax, [rip + asf_max_packet]
    ja .Lasf_packet_bad
    mov [rsp + 40], eax                # logical packet length
    cmp eax, [rip + asf_min_packet]
    jae .Lasf_packet_physical
    mov eax, [rip + asf_min_packet]
.Lasf_packet_physical:
    mov rbx, [rsp + 32]
    add rbx, rax
    cmp rbx, rdi
    ja .Lasf_packet_bad
    # Bound packet fields by the logical end, not following packets.
    mov eax, [rsp + 40]
    mov rdi, [rsp + 32]
    add rdi, rax
    cmp rsi, rdi
    ja .Lasf_packet_bad
    mov ecx, r12d
    shr ecx, 1
    call asf_var                     # sequence field
    jc .Lasf_packet_bad
    mov ecx, r12d
    shr ecx, 3
    call asf_var                     # padding field
    jc .Lasf_packet_bad
    mov rdx, rdi
    sub rdx, rsi
    cmp rax, rdx
    ja .Lasf_packet_bad
    sub rdi, rax
    mov rax, rdi
    sub rax, rsi
    cmp rax, 6
    jb .Lasf_packet_bad
    add rsi, 6                       # send time and duration
    mov r14d, 1
    xor r15d, r15d
    test r12d, 1
    jz .Lasf_packet_payload
    mov ecx, 1
    call asf_var
    jc .Lasf_packet_bad
    mov r14d, eax
    and r14d, 63
    jz .Lasf_packet_bad
    shr eax, 6
    mov r15d, eax
    test eax, eax
    jz .Lasf_packet_bad
.Lasf_packet_payload:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_packet_bad
    mov ecx, 1
    call asf_var
    jc .Lasf_packet_bad
    and eax, 127
    jz .Lasf_packet_bad
    mov [rip + asf_payload_stream], eax
    mov ecx, r13d
    shr ecx, 4
    call asf_var
    jc .Lasf_packet_bad
    mov [rip + asf_payload_object], eax
    mov ecx, r13d
    shr ecx, 2
    call asf_var
    jc .Lasf_packet_bad
    mov [rip + asf_payload_offset], eax
    mov ecx, r13d
    call asf_var
    jc .Lasf_packet_bad
    mov [rip + asf_payload_replic], eax
    mov dword ptr [rip + asf_payload_size], 0
    mov rdx, rdi
    sub rdx, rsi
    cmp rax, rdx
    ja .Lasf_packet_bad
    test eax, eax
    jz .Lasf_packet_rep_done
    cmp eax, 1
    je .Lasf_packet_rep_done
    cmp eax, 8
    jb .Lasf_packet_bad
    mov edx, [rsi]
    mov [rip + asf_payload_size], edx
.Lasf_packet_rep_done:
    add rsi, rax
    test r12d, 1
    jz .Lasf_packet_single_size
    mov ecx, r15d
    call asf_var
    jc .Lasf_packet_bad
    jmp .Lasf_packet_size
.Lasf_packet_single_size:
    mov rax, rdi
    sub rax, rsi
.Lasf_packet_size:
    mov rdx, rdi
    sub rdx, rsi
    cmp rax, rdx
    ja .Lasf_packet_bad
    lea rdx, [rsi + rax]
    mov [rsp + 48], rdx               # next payload
    mov edx, [rip + asf_payload_stream]
    cmp edx, [rip + asf_stream]
    jne .Lasf_packet_next
    cmp dword ptr [rip + asf_payload_replic], 1
    je .Lasf_packet_compressed
    mov rcx, rsi
    mov edx, eax
    call asf_fragment
    test eax, eax
    jz .Lasf_packet_bad
    jmp .Lasf_packet_next
.Lasf_packet_compressed:
    cmp dword ptr [rip + asf_pending], 0
    jne .Lasf_packet_bad
.Lasf_packet_subpayload:
    cmp rsi, [rsp + 48]
    je .Lasf_packet_next
    movzx edx, byte ptr [rsi]
    inc rsi
    test edx, edx
    jz .Lasf_packet_bad
    mov rax, [rsp + 48]
    sub rax, rsi
    cmp rdx, rax
    ja .Lasf_packet_bad
    mov [rsp + 56], edx
    mov rax, [rip + mts_bytes]
    mov [rip + asf_object_start], rax
    mov [rip + asf_object_have], edx
    mov rcx, rsi
    call mts_append
    test eax, eax
    jz .Lasf_packet_bad
    call asf_complete
    test eax, eax
    jz .Lasf_packet_bad
    mov edx, [rsp + 56]
    add rsi, rdx
    jmp .Lasf_packet_subpayload
.Lasf_packet_next:
    mov rsi, [rsp + 48]
    dec r14d
    jnz .Lasf_packet_payload
    cmp rsi, rdi
    jne .Lasf_packet_bad
    mov rax, rbx
    jmp .Lasf_packet_return
.Lasf_packet_bad:
    xor eax, eax
.Lasf_packet_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_packet

# RCX=mapped start, RDX=end -> EAX=1 open AAC/ADTS, 2 with RCX..RDX a
# Wave64 image, 0 on failure. The gather allocation is owned by mts_close.
FN asf_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    mov [rip + asf_file], rcx
    mov [rip + asf_end], rdx
    mov dword ptr [rip + asf_file_seen], 0
    mov dword ptr [rip + asf_top_objects], 0
    mov dword ptr [rip + asf_top_markers], 0
    mov dword ptr [rip + asf_all_objects], 0
    mov dword ptr [rip + asf_stream], 0
    mov dword ptr [rip + asf_pending], 0
    mov qword ptr [rip + asf_packets], 0
    lea rdx, [rip + asf_seen_ids]
    xor eax, eax
    mov ecx, 128
.Lasf_open_clear:
    mov [rdx], al
    inc rdx
    loop .Lasf_open_clear
    mov rax, rdi
    sub rax, rsi
    cmp rax, 30
    jb .Lasf_open_bad
    mov rcx, rsi
    lea rdx, [rip + asf_header_guid]
    call asf_guid
    jnz .Lasf_open_bad
    cmp byte ptr [rsi + 28], 1
    jne .Lasf_open_bad
    cmp byte ptr [rsi + 29], 2
    jne .Lasf_open_bad
    mov rax, rdi
    sub rax, rsi
    mov rbx, [rsi + 16]
    cmp rbx, 30
    jb .Lasf_open_bad
    cmp rbx, rax
    ja .Lasf_open_bad
    lea rbx, [rsi + rbx]
    mov [rip + asf_header_end], rbx
    lea rcx, [rsi + 30]
    mov rdx, rbx
    xor r8d, r8d
    call asf_objects
    test eax, eax
    jz .Lasf_open_bad
    mov rax, [rip + asf_file]
    mov eax, [rax + 24]
    cmp eax, [rip + asf_top_objects]
    je .Lasf_open_header_counted
    # FFmpeg 9.0.1's ASF muxer omits its single Marker Object from this
    # count. Permit only that exact undercount with one top-level marker;
    # all object sizes, the header end and the work cap remain validated.
    cmp dword ptr [rip + asf_top_markers], 1
    jne .Lasf_open_bad
    inc eax
    cmp eax, [rip + asf_top_objects]
    jne .Lasf_open_bad
.Lasf_open_header_counted:
    cmp dword ptr [rip + asf_file_seen], 1
    jne .Lasf_open_bad
    cmp dword ptr [rip + asf_stream], 0
    je .Lasf_open_unsupported
    # Data Object must immediately follow Header Object.
    mov rax, rdi
    sub rax, rbx
    cmp rax, 50
    jb .Lasf_open_bad
    mov rcx, rbx
    lea rdx, [rip + asf_data_guid]
    call asf_guid
    jnz .Lasf_open_bad
    lea rcx, [rbx + 24]
    lea rdx, [rip + asf_file_id]
    call asf_guid
    jnz .Lasf_open_bad
    cmp dword ptr [rip + asf_broadcast], 0
    jne .Lasf_open_broadcast
    mov rax, rdi
    sub rax, rbx
    mov rdx, [rbx + 16]
    cmp rdx, 50
    jb .Lasf_open_bad
    cmp rdx, rax
    ja .Lasf_open_bad
    lea rdi, [rbx + rdx]
    mov rax, [rbx + 40]
    mov [rip + asf_packets], rax
.Lasf_open_broadcast:
    lea rsi, [rbx + 50]
    mov r8, rdi
    sub r8, rsi                       # audio cannot exceed Data Object bytes
    mov rcx, [rip + asf_fmt]
    mov edx, [rip + asf_fmt_bytes]
    cmp dword ptr [rip + asf_mode], 0
    jne .Lasf_open_raw
    call wav_image_begin
    jmp .Lasf_open_started
.Lasf_open_raw:
    mov rcx, r8
    call mts_begin
    test eax, eax
    jz .Lasf_open_bad
    cmp dword ptr [rip + asf_mode], 1
    jne .Lasf_open_started
    mov ecx, 7                        # TK_AAC
    call track_begin
.Lasf_open_started:
    test eax, eax
    jz .Lasf_open_bad
    xor r12d, r12d
.Lasf_open_packet:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_open_bad
    cmp rsi, rdi
    je .Lasf_open_done
    mov rcx, rsi
    mov rdx, rdi
    call asf_packet
    test rax, rax
    jz .Lasf_open_bad
    mov rsi, rax
    inc r12
    jmp .Lasf_open_packet
.Lasf_open_done:
    cmp dword ptr [rip + asf_pending], 0
    jne .Lasf_open_bad
    cmp dword ptr [rip + asf_broadcast], 0
    jne .Lasf_open_finish
    cmp r12, [rip + asf_packets]
    jne .Lasf_open_bad
.Lasf_open_finish:
    cmp dword ptr [rip + asf_mode], 1
    je .Lasf_open_aac
    cmp dword ptr [rip + asf_mode], 2
    je .Lasf_open_adts
    xor ecx, ecx
    call wav_image_end
    mov eax, 2
    jmp .Lasf_open_return
.Lasf_open_adts:
    mov rcx, [rip + mts_buffer]
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    call adts_open
    jmp .Lasf_open_return
.Lasf_open_aac:
    mov rax, [rip + asf_fmt]
    add rax, 18
    mov [rip + track_config], rax
    mov rax, [rip + asf_fmt]
    movzx eax, word ptr [rax + 16]
    mov [rip + track_config_bytes], eax
    mov ecx, 21                       # ASF codec label
    call track_finish
    jmp .Lasf_open_return
.Lasf_open_unsupported:
    mov dword ptr [rip + decode_error], ASF_UNSUPPORTED
.Lasf_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lasf_open_fail
    mov dword ptr [rip + decode_error], ASF_MALFORMED
.Lasf_open_fail:
    xor eax, eax
.Lasf_open_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_open
