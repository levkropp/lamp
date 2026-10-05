# Original bounded Vorbis decoder in x86-64 assembly. MIT, see LICENSE.
# Floor 1, residue 0/1/2, mapping 0, 1..255 channels. Reference: Xiph Vorbis I.
.include "lamp.inc"
.include "vorbis_layout.inc"
.globl vorbis_index_count, vorbis_index_stride, vorbis_seek_preroll
.equ VB_INDEX_CAP, 2048
.equ VB_INDEX_POINT, 32
.data
vb_arena: .quad 0
vb_allocated: .long 0
vb_committed: .long 0
vb_ptr: .quad 0
vb_end: .quad 0
vb_acc: .quad 0
vb_count: .long 0
vb_bad: .long 0
vb_short: .long 0
vb_long: .long 0
vb_books_count: .long 0
vb_floors_count: .long 0
vb_residues_count: .long 0
vb_maps_count: .long 0
vb_modes_count: .long 0
vb_mode_bits: .long 0
vb_first: .long 1
vb_previous: .long 0
vb_available: .long 0
vb_used: .long 0
vb_emitted: .quad 0
vb_index: .quad 0
vorbis_index_count: .long 0
vorbis_index_stride: .quad 16
vorbis_seek_preroll: .long 0
vb_origin_known: .long 0
vb_origin: .quad 0
vb_initial_skip: .long 0
vb_trim_start: .long 0
vb_frame_skip: .long 0
vb_n: .long 0
vb_block: .long 0
vb_left: .long 0
vb_left_end: .long 0
vb_right: .long 0
vb_right_end: .long 0
vb_current_map: .quad 0
vb_range_table: .long 256, 128, 86, 64
vb_float_mant: .long 0
vb_float_exp: .long 0
vb_lengths_total: .long 0
vb_tree_used: .long 0
vb_quant_ptr: .quad 0
vb_min: .float 0.0
vb_delta: .float 0.0
vb_rs_ptr: .quad 0
vb_rs_channels: .long 0
vb_rs_groups: .long 0
vb_rs_active: .zero 255*4
vb_rs_channel: .zero 255*4
vb_rs_parts: .long 0
vb_rs_words: .long 0
vb_rs_begin: .long 0
vb_rs_type: .long 0
vb_spectrum_ptr: .quad 0
vb_time_ptr: .quad 0
vb_tail_ptr: .quad 0
vb_y_ptr: .quad 0
vb_active_ptr: .quad 0
vb_classdata_ptr: .quad 0
vb_mix_one: .double 1.0
vb_mix_two: .double 2.0
vb_mix_coeff: .zero 16*8
# Zero-based WAVE roles, in Vorbis's specified encoded channel order.
vb_channel_roles: .byte 2, 255, 255, 255, 255, 255, 255, 255
 .byte 0, 1, 255, 255, 255, 255, 255, 255
 .byte 0, 2, 1, 255, 255, 255, 255, 255
 .byte 0, 1, 4, 5, 255, 255, 255, 255
 .byte 0, 2, 1, 4, 5, 255, 255, 255
 .byte 0, 2, 1, 4, 5, 3, 255, 255
 .byte 0, 2, 1, 9, 10, 8, 3, 255
 .byte 0, 2, 1, 9, 10, 4, 5, 3
.include "vorbis_tables.inc"
.bss
.p2align 4
vb_books: .zero CB_SIZE*256
vb_floors: .zero FL_SIZE*64
vb_residues: .zero RS_SIZE*64
vb_maps: .zero MP_SIZE*64
vb_modes: .zero 128*4
vb_codes_available: .zero 33*4
vb_spectrum: .zero 8192*4
vb_time: .zero 16384*4
vb_tail: .zero 8192*4
vb_pcm: .zero 16384*4
vb_y: .zero 512*4
vb_active: .zero 512*4
vb_floor_channel: .zero 255*8
vb_zero: .zero 255*4
vb_really_zero: .zero 255*4
vb_classdata: .zero 32768*4
vb_audio_checkpoint: .zero 2*8
vb_scan_checkpoint: .zero 2*8
.text
# Bounded little-endian bit reader. Only EAX and flags are clobbered.
LOCALFN vb_bits
    push rcx
    push rdx
    push r8
    cmp ecx, 32
    ja .Lvb_bits_bad
    test ecx, ecx
    jz .Lvb_bits_zero
    mov r8d, [rip + vb_count]
.Lvb_bits_load:
    cmp r8d, ecx
    jae .Lvb_bits_extract
    mov rdx, [rip + vb_ptr]
    cmp rdx, [rip + vb_end]
    jae .Lvb_bits_bad
    movzx eax, byte ptr [rdx]
    inc rdx
    mov [rip + vb_ptr], rdx
    mov edx, ecx
    mov ecx, r8d
    shl rax, cl
    or [rip + vb_acc], rax
    mov ecx, edx
    add r8d, 8
    jmp .Lvb_bits_load
.Lvb_bits_extract:
    mov rax, [rip + vb_acc]
    mov edx, -1
    cmp ecx, 32
    je .Lvb_bits_mask
    mov edx, 1
    shl edx, cl
    dec edx
.Lvb_bits_mask:
    and eax, edx
    shr qword ptr [rip + vb_acc], cl
    sub r8d, ecx
    mov [rip + vb_count], r8d
    jmp .Lvb_bits_done
.Lvb_bits_bad:
    mov dword ptr [rip + vb_bad], 1
.Lvb_bits_zero:
    xor eax, eax
.Lvb_bits_done:
    pop r8
    pop rdx
    pop rcx
    ret
ENDFN vb_bits

# EAX=nonnegative integer -> ECX=ilog(integer).
LOCALFN vb_ilog
    xor ecx, ecx
    test eax, eax
    jz .Lvb_ilog_done
    bsr ecx, eax
    inc ecx
.Lvb_ilog_done:
    ret
ENDFN vb_ilog

# EAX=bytes, aligned zeroed arena -> RAX. Failures are sticky.
LOCALFN vb_alloc
    push rbx
    push rsi
    sub rsp, 40
    add eax, 15
    jc .Lvb_alloc_bad
    and eax, -16
    mov edx, [rip + vb_allocated]
    add eax, edx
    jc .Lvb_alloc_bad
    cmp eax, VB_ARENA
    ja .Lvb_alloc_bad
    mov [rip + vb_allocated], eax
    mov esi, edx
    cmp eax, [rip + vb_committed]
    jbe .Lvb_alloc_ready
    add eax, 65535
    and eax, -65536
    mov ebx, eax
    mov edx, [rip + vb_committed]
    mov rcx, [rip + vb_arena]
    add rcx, rdx
    mov eax, ebx
    sub eax, edx
    mov edx, eax
    call mem_commit
    test rax, rax
    jz .Lvb_alloc_bad
    mov [rip + vb_committed], ebx
.Lvb_alloc_ready:
    mov rax, [rip + vb_arena]
    add rax, rsi
    jmp .Lvb_alloc_return
.Lvb_alloc_bad:
    mov dword ptr [rip + vb_bad], 1
    xor eax, eax
.Lvb_alloc_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN vb_alloc

# Channel working buffers share the bounded setup arena. Mono/stereo retain
# their original static buffers; larger streams allocate only their count.
LOCALFN vb_workspace
    sub rsp, 40
    lea rax, [rip + vb_spectrum]
    mov [rip + vb_spectrum_ptr], rax
    lea rax, [rip + vb_time]
    mov [rip + vb_time_ptr], rax
    lea rax, [rip + vb_tail]
    mov [rip + vb_tail_ptr], rax
    lea rax, [rip + vb_y]
    mov [rip + vb_y_ptr], rax
    lea rax, [rip + vb_active]
    mov [rip + vb_active_ptr], rax
    lea rax, [rip + vb_classdata]
    mov [rip + vb_classdata_ptr], rax
    cmp dword ptr [rip + source_channels], 2
    jbe .Lvb_workspace_ready
    mov eax, [rip + source_channels]
    shl eax, 14
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_spectrum_ptr], rax
    mov eax, [rip + source_channels]
    shl eax, 15
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_time_ptr], rax
    mov eax, [rip + source_channels]
    shl eax, 14
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_tail_ptr], rax
    mov eax, [rip + source_channels]
    shl eax, 10
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_y_ptr], rax
    mov eax, [rip + source_channels]
    shl eax, 10
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_active_ptr], rax
    # Per-group stride remains 16384 classification integers. Residue 2
    # has one group and can use the whole channel-count-sized allocation.
    mov eax, [rip + source_channels]
    shl eax, 16
    call vb_alloc
    test rax, rax
    jz .Lvb_workspace_bad
    mov [rip + vb_classdata_ptr], rax
.Lvb_workspace_ready:
    mov eax, 1
    add rsp, 40
    ret
.Lvb_workspace_bad:
    xor eax, eax
    add rsp, 40
    ret
ENDFN vb_workspace

# Standard 1..8-channel roles use the shared stereo weights/headroom policy.
# Larger channel layouts are application-defined: output ports 0/1 directly.
LOCALFN vb_build_mix
    mov ecx, [rip + source_channels]
    cmp ecx, 2
    jbe .Lvb_mix_done
    cmp ecx, 8
    ja .Lvb_mix_done
    mov eax, ecx
    dec eax
    lea r9, [rip + vb_channel_roles]
    lea r9, [r9 + rax*8]
    lea r8, [rip + vb_mix_coeff]
    lea r10, [rip + pcm_speaker_weights]
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    xor edx, edx
.Lvb_mix_role:
    movzx eax, byte ptr [r9 + rdx]
    shl eax, 4
    movsd xmm2, qword ptr [r10 + rax]
    movsd xmm3, qword ptr [r10 + rax + 8]
    movsd qword ptr [r8], xmm2
    movsd qword ptr [r8 + 8], xmm3
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r8, 16
    inc edx
    cmp edx, ecx
    jb .Lvb_mix_role
    maxsd xmm0, xmm1
    movsd xmm2, [rip + vb_mix_one]
    cmp ecx, 4
    jbe .Lvb_mix_normalize
    movsd xmm2, [rip + vb_mix_two]
.Lvb_mix_normalize:
    divsd xmm2, xmm0
    lea r8, [rip + vb_mix_coeff]
.Lvb_mix_scale:
    movsd xmm0, qword ptr [r8]
    movsd xmm1, qword ptr [r8 + 8]
    mulsd xmm0, xmm2
    mulsd xmm1, xmm2
    movsd qword ptr [r8], xmm0
    movsd qword ptr [r8 + 8], xmm1
    add r8, 16
    dec ecx
    jnz .Lvb_mix_scale
.Lvb_mix_done:
    ret
ENDFN vb_build_mix

# EAX=Vorbis packed float -> XMM0; x87 handles signed binary exponent.
LOCALFN vb_unpack
    mov edx, eax
    and edx, 0x1fffff
    test eax, 0x80000000
    jz .Lvb_unpack_positive
    neg edx
.Lvb_unpack_positive:
    mov [rip + vb_float_mant], edx
    shr eax, 21
    and eax, 0x3ff
    sub eax, 788
    mov [rip + vb_float_exp], eax
    fild dword ptr [rip + vb_float_exp]
    fild dword ptr [rip + vb_float_mant]
    fscale
    fstp dword ptr [rip + vb_float_mant]
    fstp st(0)
    movss xmm0, dword ptr [rip + vb_float_mant]
    ret
ENDFN vb_unpack

# ECX=codebook index -> EAX=symbol. Simple tree, maximum 32 bits.
LOCALFN vb_symbol
    push rdx
    push r8
    push r9
    cmp ecx, [rip + vb_books_count]
    jae .Lvb_symbol_bad
    mov eax, ecx
    shl eax, 6
    lea r8, [rip + vb_books]
    mov r8, [r8 + rax + CB_TREE]
    xor r9d, r9d
    xor edx, edx
.Lvb_symbol_bit:
    VB_GET 1
    lea rax, [rax + rdx*2]
    mov edx, [r8 + rax*4]
    test edx, edx
    js .Lvb_symbol_leaf
    test edx, edx
    jz .Lvb_symbol_bad
    inc r9d
    cmp r9d, 32
    jb .Lvb_symbol_bit
.Lvb_symbol_bad:
    mov dword ptr [rip + vb_bad], 1
    xor eax, eax
    jmp .Lvb_symbol_done
.Lvb_symbol_leaf:
    mov eax, edx
    not eax
.Lvb_symbol_done:
    pop r9
    pop r8
    pop rdx
    ret
ENDFN vb_symbol

FN vorbis_close
    sub rsp, 40
    mov rcx, [rip + vb_index]
    mov qword ptr [rip + vb_index], 0
    mov dword ptr [rip + vorbis_index_count], 0
    mov dword ptr [rip + vorbis_seek_preroll], 0
    test rcx, rcx
    jz .Lvb_close_arena
    call mem_free
.Lvb_close_arena:
    mov rcx, [rip + vb_arena]
    test rcx, rcx
    jz .Lvb_close_done
    call mem_free
    mov qword ptr [rip + vb_arena], 0
.Lvb_close_done:
    add rsp, 40
    ret
ENDFN vorbis_close

FN vorbis_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    call ogg_open
    test eax, eax
    jz .Lvb_open_bad
    call vorbis_close
    mov dword ptr [rip + vb_bad], 0
    mov dword ptr [rip + vb_allocated], 0
    mov dword ptr [rip + vb_committed], 0
    mov dword ptr [rip + vb_first], 1
    mov dword ptr [rip + vb_previous], 0
    mov dword ptr [rip + vb_available], 0
    mov dword ptr [rip + vb_used], 0
    mov qword ptr [rip + vb_emitted], 0
    mov dword ptr [rip + vb_initial_skip], 0
    mov dword ptr [rip + vb_trim_start], 0
    call ogg_next
    test rax, rax
    jz .Lvb_open_bad
    cmp edx, 30
    jne .Lvb_open_bad
    cmp dword ptr [rax], 0x726f7601
    jne .Lvb_open_bad
    cmp word ptr [rax + 4], 0x6962
    jne .Lvb_open_bad
    cmp byte ptr [rax + 6], 0x73
    jne .Lvb_open_bad
    cmp dword ptr [rax + 7], 0
    jne .Lvb_open_bad
    movzx ecx, byte ptr [rax + 11]
    cmp ecx, 1
    jb .Lvb_open_bad
    mov [rip + source_channels], ecx
    mov ecx, [rax + 12]
    cmp ecx, 8000
    jb .Lvb_open_bad
    cmp ecx, 192000
    ja .Lvb_open_bad
    mov [rip + sample_rate], ecx
    movzx ecx, byte ptr [rax + 28]
    mov edx, ecx
    and ecx, 15
    shr edx, 4
    cmp ecx, 6
    jb .Lvb_open_bad
    cmp edx, 13
    ja .Lvb_open_bad
    cmp edx, ecx
    jb .Lvb_open_bad
    mov ebx, 1
    shl ebx, cl
    mov [rip + vb_short], ebx
    mov ecx, edx
    mov ebx, 1
    shl ebx, cl
    mov [rip + vb_long], ebx
    cmp byte ptr [rax + 29], 1
    jne .Lvb_open_bad
    mov dword ptr [rip + source_bits], 32
    mov rax, [rip + ogg_total_granule]
    mov [rip + total_frames], rax
    call ogg_next
    test rax, rax
    jz .Lvb_open_bad
    cmp edx, 16
    jb .Lvb_open_bad
    cmp dword ptr [rax], 0x726f7603
    jne .Lvb_open_bad
    cmp word ptr [rax + 4], 0x6962
    jne .Lvb_open_bad
    cmp byte ptr [rax + 6], 0x73
    jne .Lvb_open_bad
    # Validate bounded vendor and comment strings without allocating them.
    mov rsi, rax
    lea rdi, [rax + rdx]
    add rsi, 7
    mov eax, [rsi]
    add rsi, 4
    add rsi, rax
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lvb_open_bad
    mov ebx, [rsi]
    add rsi, 4
.Lvb_comment:
    test ebx, ebx
    jz .Lvb_comment_end
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lvb_open_bad
    mov eax, [rsi]
    add rsi, 4
    add rsi, rax
    cmp rsi, rdi
    ja .Lvb_open_bad
    dec ebx
    jmp .Lvb_comment
.Lvb_comment_end:
    cmp rsi, rdi
    jae .Lvb_open_bad
    test byte ptr [rsi], 1
    jz .Lvb_open_bad
    mov ecx, VB_ARENA        # reserve address space; commit setup pages as needed
    call mem_reserve
    test rax, rax
    jz .Lvb_open_bad
    mov [rip + vb_arena], rax
    call ogg_next
    test rax, rax
    jz .Lvb_open_bad
    cmp edx, 8
    jb .Lvb_open_bad
    cmp dword ptr [rax], 0x726f7605
    jne .Lvb_open_bad
    cmp word ptr [rax + 4], 0x6962
    jne .Lvb_open_bad
    cmp byte ptr [rax + 6], 0x73
    jne .Lvb_open_bad
    lea rcx, [rax + rdx]
    mov [rip + vb_end], rcx
    add rax, 7
    mov [rip + vb_ptr], rax
    mov qword ptr [rip + vb_acc], 0
    mov dword ptr [rip + vb_count], 0
    call vb_setup
    test eax, eax
    jz .Lvb_open_bad
    call vb_workspace
    test eax, eax
    jz .Lvb_open_bad
    call vb_build_mix
    mov ecx, [rip + vb_short]
    mov edx, [rip + vb_long]
    call vb_transform_init
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lvb_open_bad
    call vb_build_index
    test eax, eax
    jz .Lvb_open_bad
    mov eax, 1
    jmp .Lvb_open_done
.Lvb_open_bad:
    mov dword ptr [rip + decode_error], 23
    xor eax, eax
.Lvb_open_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vorbis_open

# Packet-mode/window scan only. Points capture a packet boundary and the raw
# sample position after that packet. Decode it once to prime exact overlap.
# Limit memory to 64 KiB and compact alternate points at the 2048-point cap.
LOCALFN vb_build_index
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    lea rcx, [rip + vb_audio_checkpoint]
    call ogg_checkpoint
    mov ecx, VB_INDEX_CAP*VB_INDEX_POINT
    call mem_alloc
    mov [rip + vb_index], rax       #allocation failure keeps correct sequential use
    mov qword ptr [rip + vorbis_index_stride], 16
    mov dword ptr [rip + vb_origin_known], 0
    mov qword ptr [rip + vb_origin], 0
    xor ebx, ebx             #audio packet ordinal
    xor r12d, r12d           #untrimmed emitted PCM after this packet
    xor r13d, r13d           #previous packet's right overlap width
.Lvb_index_packet:
    lea rcx, [rip + vb_scan_checkpoint]
    call ogg_checkpoint
    call ogg_next
    test rax, rax
    jz .Lvb_index_complete
    call vb_packet_header
    test eax, eax
    jz .Lvb_index_bad
    mov r14d, [rip + vb_right]
    sub r14d, [rip + vb_left]
    test r13d, r13d
    jnz .Lvb_index_following
    mov eax, [rip + vb_n]
    shr eax, 1
    mov ecx, [rip + vb_right]
    sub ecx, eax
    add r12, rcx             #first long-to-short packet's unwindowed prefix
    jmp .Lvb_index_first
.Lvb_index_following:
    mov eax, [rip + vb_left_end]
    sub eax, [rip + vb_left]
    cmp eax, r13d
    jne .Lvb_index_bad
    add r12, r14
.Lvb_index_first:
    mov r13d, [rip + vb_right_end]
    sub r13d, [rip + vb_right]
    cmp dword ptr [rip + ogg_packet_last], 1
    jne .Lvb_index_point
    mov r15, r12
    mov eax, [rip + vb_n]
    shr eax, 1
    sub eax, [rip + vb_right]       #granule is the center, before next-short lookahead
    movsxd rax, eax
    add r15, rax
    mov rax, [rip + ogg_granule]
    test rax, rax
    js .Lvb_index_bad
    cmp dword ptr [rip + vb_origin_known], 0
    jne .Lvb_index_granule
    cmp dword ptr [rip + ogg_eos], 1
    je .Lvb_index_origin_ready #first/final page only trims its end
    test rbx, rbx
    jz .Lvb_index_point        #first packet primes overlap but returns no PCM
    sub rax, r15
    jz .Lvb_index_origin_ready
    cmp rbx, 1               #nonzero origins require the second packet flush
    jne .Lvb_index_bad
    test rax, rax
    jns .Lvb_index_origin_positive
    mov rcx, rax
    neg rcx
    cmp rcx, r15
    ja .Lvb_index_bad
    mov [rip + vb_initial_skip], ecx
.Lvb_index_origin_positive:
    mov [rip + vb_origin], rax
.Lvb_index_origin_ready:
    mov dword ptr [rip + vb_origin_known], 1
.Lvb_index_granule:
    mov rax, r15
    add rax, [rip + vb_origin]
    jo .Lvb_index_bad
    cmp dword ptr [rip + ogg_eos], 1
    je .Lvb_index_final_granule
    cmp rax, [rip + ogg_granule]
    jne .Lvb_index_bad
    jmp .Lvb_index_point
.Lvb_index_final_granule:
    cmp rax, [rip + ogg_granule]
    jb .Lvb_index_bad
.Lvb_index_point:
    cmp qword ptr [rip + vb_index], 0
    je .Lvb_index_next
    mov rax, [rip + vorbis_index_stride]
    dec rax
    test rbx, rax
    jnz .Lvb_index_next
    cmp dword ptr [rip + vorbis_index_count], VB_INDEX_CAP
    jb .Lvb_index_store
    mov r15, 1
.Lvb_index_compact:
    mov rsi, r15
    shl rsi, 6
    add rsi, [rip + vb_index]
    mov rdi, r15
    shl rdi, 5
    add rdi, [rip + vb_index]
    mov ecx, 4
    rep movsq
    inc r15d
    cmp r15d, VB_INDEX_CAP/2
    jb .Lvb_index_compact
    mov dword ptr [rip + vorbis_index_count], VB_INDEX_CAP/2
    shl qword ptr [rip + vorbis_index_stride], 1
.Lvb_index_store:
    mov eax, [rip + vorbis_index_count]
    shl eax, 5
    add rax, [rip + vb_index]
    mov rcx, [rip + vb_scan_checkpoint]
    mov [rax], rcx
    mov rcx, [rip + vb_scan_checkpoint + 8]
    mov [rax + 8], rcx
    mov [rax + 16], r12
    mov [rax + 24], rbx
    inc dword ptr [rip + vorbis_index_count]
.Lvb_index_next:
    inc rbx
    jmp .Lvb_index_packet
.Lvb_index_complete:
    cmp dword ptr [rip + decode_error], 0
    jne .Lvb_index_bad
    mov rax, [rip + ogg_total_granule]
    sub rax, [rip + vb_origin]
    jo .Lvb_index_bad
    test rax, rax
    js .Lvb_index_bad
    cmp rax, r12
    ja .Lvb_index_bad
    mov rdx, rax             #raw end before start cropping
    mov ecx, [rip + vb_initial_skip]
    sub rax, rcx
    jc .Lvb_index_bad
    mov [rip + total_frames], rax
.Lvb_index_trim_points:
    mov eax, [rip + vorbis_index_count]
    test eax, eax
    jz .Lvb_index_reset
    dec eax
    shl eax, 5
    add rax, [rip + vb_index]
    cmp [rax + 16], rdx
    jbe .Lvb_index_reset
    dec dword ptr [rip + vorbis_index_count]
    jmp .Lvb_index_trim_points
.Lvb_index_reset:
    mov eax, [rip + vb_initial_skip]
    mov [rip + vb_trim_start], eax
    test rbx, rbx
    jz .Lvb_index_empty
    lea rcx, [rip + vb_audio_checkpoint]
    call ogg_resume
    test eax, eax
    jz .Lvb_index_bad
.Lvb_index_empty:
    mov eax, 1
    jmp .Lvb_index_return
.Lvb_index_bad:
    xor eax, eax
.Lvb_index_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vb_build_index

FN vorbis_seek
    push rbx
    push rsi
    sub rsp, 40
    xor eax, eax
    mov dword ptr [rip + vorbis_seek_preroll], 0
    cmp dword ptr [rip + vorbis_index_count], 0
    je .Lvb_seek_return
    test rcx, rcx
    jz .Lvb_seek_return
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lvb_seek_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lvb_seek_zero
.Lvb_seek_not_cancelled:
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    mov eax, [rip + vb_initial_skip]
    add rcx, rax
    mov rsi, rcx
    xor r8d, r8d
    mov r9d, [rip + vorbis_index_count]
.Lvb_seek_search:
    cmp r8d, r9d
    jae .Lvb_seek_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    mov eax, edx
    shl eax, 5
    add rax, [rip + vb_index]
    cmp [rax + 16], rsi
    ja .Lvb_seek_upper
    lea r8d, [rdx + 1]
    jmp .Lvb_seek_search
.Lvb_seek_upper:
    mov r9d, edx
    jmp .Lvb_seek_search
.Lvb_seek_found:
    test r8d, r8d
    jz .Lvb_seek_zero         #target precedes the first packet's optional prefix
    dec r8d
    mov eax, r8d
    shl eax, 5
    add rax, [rip + vb_index]
    mov rbx, [rax + 16]
    mov rcx, rax
    call ogg_resume
    test eax, eax
    jz .Lvb_seek_bad
    mov dword ptr [rip + vb_previous], 0
    mov dword ptr [rip + vb_first], 0
    mov dword ptr [rip + vb_available], 0
    mov dword ptr [rip + vb_used], 0
    mov dword ptr [rip + vb_trim_start], 0
    mov eax, [rip + vb_initial_skip]
    cmp rbx, rax
    jae .Lvb_seek_emitted
    sub eax, ebx
    mov [rip + vb_trim_start], eax
    xor ebx, ebx
    jmp .Lvb_seek_prime
.Lvb_seek_emitted:
    sub rbx, rax
.Lvb_seek_prime:
    mov [rip + vb_emitted], rbx
    inc dword ptr [rip + vorbis_seek_preroll]
    call vb_frame           #only reconstruct the preceding packet's tail
    test eax, eax
    jz .Lvb_seek_bad
    mov rax, rbx
    jmp .Lvb_seek_return
.Lvb_seek_bad:
    mov dword ptr [rip + decode_error], 24
.Lvb_seek_zero:
    xor eax, eax
.Lvb_seek_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN vorbis_seek
.include "vorbis_setup.inc"
.include "vorbis_decode.inc"
