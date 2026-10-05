# Handwritten x86-64 MPEG Layer III decoder.
# Codebooks and algorithm reference: dr_mp3 (MIT-0), see THIRD_PARTY_NOTICES.
# No reference implementation is compiled or linked into this module.
.include "lamp.inc"
.include "mp3_layout.inc"
.globl mp_grbuf, mp_overlap, mp_qmf, mp_syn
.globl mp3_index_count, mp3_index_stride, mp3_seek_headers
.globl mp_layer, mp_kbps, mp_header, mp_frame_bytes, mp_crc_bytes, mp_bit_pos, mp_bit_limit, mp_bit_base
.globl mp_samples, mp_channels, mp_version, mp_sr_index, mp_pcm, mp_frame_end
.globl mp_pow43
.globl mp_aa, mp_twid9, mp_mdct_win, mp_twid3, mp_synth_win, mp_dct9, mp_dct_sec

RODATA
.include "mp3_tables.inc"
bitrate1: .long 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320
bitrate2: .long 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160
bitrate1_l1: .long 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448
bitrate1_l2: .long 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384
bitrate2_l1: .long 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256
mp_rates: .long 44100, 48000, 32000
sqrt_two: .long 0x3fb504f3
one_float: .long 0x3f800000
# A seek point precedes a compressed frame and retains its exact unused
# main-data reservoir. PCM overlap/QMF history is rebuilt by two full frames.
.equ MP_INDEX_POINT, 544
.equ MP_INDEX_CAP, 2048

.data
mp_cursor: .quad 0
mp_end: .quad 0
mp_frame_end: .quad 0
mp_header: .long 0
mp_layer: .long 3                   # 1, 2 or 3
mp_track_tolerant: .long 0          # track mode: missing reservoir reads as zeros
mp_main_incomplete: .long 0         # this frame's main data lacked reservoir bytes
mp_initial_layer: .long 3
mp_kbps: .long 0
mp_version: .long 0
mp_initial_version: .long 0
mp_rate: .long 0
mp_channels: .long 0
mp_initial_channels: .long 0
mp_samples: .long 0
mp_frame_bytes: .long 0
mp_side_bytes: .long 0
mp_crc_bytes: .long 0
mp_sr_index: .long 0
mp_joint: .long 0
mp_ms: .long 0
mp_intensity: .long 0
mp_reserv_size: .long 0
mp_main_begin: .long 0
mp_main_bytes: .long 0
mp_bit_pos: .long 0
mp_bit_limit: .long 0
mp_bit_base: .quad 0
mp_part_limit: .long 0
mp_granule: .long 0
mp_channel: .long 0
mp_gr_count: .long 0
mp_frame_used: .long 0
mp_frame_ready: .long 0
mp_trim_start: .long 0
mp_trim_end: .long 0
mp_emitted: .quad 0
mp_scfsi: .zero 2*4
mp_scf_sizes: .zero 4*4
mp_scf_counts: .quad 0
mp_scf_shift: .long 0
mp_scale_count: .long 0
mp_max_band: .fill 3, 4, -1
mp_xing_count: .long 0
mp_xing_flags: .long 0
mp_stream_begin: .quad 0
mp_initial_trim: .long 0
mp_index: .quad 0
mp3_index_count: .long 0
mp3_index_stride: .quad 32
mp3_seek_headers: .quad 0

.bss
.p2align 4
mp_info: .zero GI_SIZE*4
mp_reserv: .zero 511
mp_main: .zero 4096
mp_iscf: .zero 40
mp_ist: .zero 40*2
mp_scales: .zero 40*4
mp_temp: .zero 576*4
mp_grbuf: .zero (576*2)*4
mp_overlap: .zero (288*2)*4
mp_qmf: .zero 960*4
mp_syn: .zero 2112*4
mp_pcm: .zero 1152*8

.text
# RCX=file bytes, RDX=end. Layer III MPEG-1/2/2.5 and Layers I/II MPEG-1/2,
# known bitrate; every frame keeps the first frame's layer, version, rate and
# channel count.
FN mp3_open
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    mov rsi, rcx
    mov r12, rdx
    call mp3_close
    mov rcx, rsi
    mov rdx, r12
    mov [rip + mp_cursor], rcx
    mov [rip + mp_end], rdx
    mov dword ptr [rip + mp_reserv_size], 0
    mov dword ptr [rip + mp_frame_ready], 0
    mov dword ptr [rip + mp_frame_used], 0
    mov dword ptr [rip + mp_trim_start], 0
    mov dword ptr [rip + mp_trim_end], 0
    mov qword ptr [rip + mp_emitted], 0
    lea rdi, [rip + mp_ist]
    xor eax, eax
    mov ecx, 80
    rep stosb
    lea rdi, [rip + mp_overlap]
    mov ecx, 576
    rep stosd
    lea rdi, [rip + mp_qmf]
    mov ecx, 960
    rep stosd
    mov rsi, [rip + mp_cursor]
    lea rax, [rsi + 10]
    cmp rax, [rip + mp_end]
    ja .Lmp_open_bad
    cmp word ptr [rsi], 0x4449
    jne .Lmp_no_id3
    cmp byte ptr [rsi + 2], '3'
    jne .Lmp_no_id3
    movzx eax, byte ptr [rsi + 3]
    cmp eax, 2
    jb .Lmp_open_bad
    cmp eax, 4
    ja .Lmp_open_bad
    cmp byte ptr [rsi + 4], 255
    je .Lmp_open_bad
    mov edx, 0x3f
    cmp eax, 2
    je .Lid3_flags
    mov edx, 0x1f
    cmp eax, 3
    je .Lid3_flags
    mov edx, 0xf
.Lid3_flags:
    test byte ptr [rsi + 5], dl
    jnz .Lmp_open_bad
    mov r12, rsi
    xor ebx, ebx
    mov ecx, 6
.Lid3_size:
    movzx edx, byte ptr [rsi + rcx]
    test edx, 0x80
    jnz .Lmp_open_bad
    shl ebx, 7
    or ebx, edx
    inc ecx
    cmp ecx, 10
    jb .Lid3_size
    lea rsi, [rsi + rbx + 10]
    cmp rsi, [rip + mp_end]
    ja .Lmp_open_bad
    test byte ptr [r12 + 5], 0x10
    jz .Lid3_done
    lea rax, [rsi + 10]
    cmp rax, [rip + mp_end]
    ja .Lmp_open_bad
    cmp word ptr [rsi], 0x4433
    jne .Lmp_open_bad
    cmp byte ptr [rsi + 2], 'I'
    jne .Lmp_open_bad
    mov eax, [rsi + 3]
    cmp eax, [r12 + 3]
    jne .Lmp_open_bad
    mov eax, [rsi + 6]
    cmp eax, [r12 + 6]
    jne .Lmp_open_bad
    add rsi, 10
.Lid3_done:
    mov [rip + mp_cursor], rsi
.Lmp_no_id3:
    mov rcx, rsi
    call mp_parse_header
    test eax, eax
    jz .Lmp_open_bad
    mov eax, [rip + mp_rate]
    mov [rip + sample_rate], eax
    mov eax, [rip + mp_channels]
    mov [rip + source_channels], eax
    mov [rip + mp_initial_channels], eax
    mov dword ptr [rip + source_bits], 0
    mov eax, [rip + mp_version]
    mov [rip + mp_initial_version], eax
    mov eax, [rip + mp_layer]
    mov [rip + mp_initial_layer], eax
    mov qword ptr [rip + total_frames], 0
    cmp eax, 3
    jne .Lmp_open_ok                   # Xing/Info and LAME tags are Layer III frames
    # Detect a Xing/Info metadata frame before resetting synthesis/reservoir.
    mov eax, [rip + mp_crc_bytes]
    add eax, [rip + mp_side_bytes]
    lea rbx, [rsi + rax + 4]
    lea rax, [rbx + 8]
    cmp rax, [rip + mp_frame_end]
    ja .Lmp_open_ok
    cmp dword ptr [rbx], 0x676e6958
    je .Lmp_xing
    cmp dword ptr [rbx], 0x6f666e49
    jne .Lmp_open_ok
.Lmp_xing:
    mov eax, [rbx + 4]
    bswap eax
    mov [rip + mp_xing_flags], eax
    mov dword ptr [rip + mp_xing_count], 0
    add rbx, 8
    test eax, 1
    jz .Lxing_bytes
    lea rax, [rbx + 4]
    cmp rax, [rip + mp_frame_end]
    ja .Lmp_open_bad
    mov eax, [rbx]
    bswap eax
    mov [rip + mp_xing_count], eax
    add rbx, 4
.Lxing_bytes:
    test dword ptr [rip + mp_xing_flags], 2
    jz .Lxing_toc
    add rbx, 4
.Lxing_toc:
    test dword ptr [rip + mp_xing_flags], 4
    jz .Lxing_quality
    add rbx, 100
.Lxing_quality:
    test dword ptr [rip + mp_xing_flags], 8
    jz .Lxing_lame
    add rbx, 4
.Lxing_lame:
    cmp rbx, [rip + mp_frame_end]
    ja .Lmp_open_bad
    lea rax, [rbx + 36]
    cmp rax, [rip + mp_frame_end]
    ja .Lxing_done
    cmp byte ptr [rbx], 0
    je .Lxing_done
    movzx eax, byte ptr [rbx + 21]
    shl eax, 4
    movzx edx, byte ptr [rbx + 22]
    mov ecx, edx
    shr ecx, 4
    or eax, ecx
    add eax, 529
    mov [rip + mp_trim_start], eax
    and edx, 15
    shl edx, 8
    movzx eax, byte ptr [rbx + 23]
    or edx, eax
    sub edx, 529
    jns .Lxing_pad_valid
    xor edx, edx
.Lxing_pad_valid:
    mov [rip + mp_trim_end], edx
.Lxing_done:
    mov eax, [rip + mp_xing_count]
    test eax, eax
    jz .Lxing_skip
    mov ecx, [rip + mp_samples]
    mul rcx
    mov ecx, [rip + mp_trim_start]
    sub rax, rcx
    jc .Lmp_open_bad
    mov ecx, [rip + mp_trim_end]
    sub rax, rcx
    jc .Lmp_open_bad
    mov [rip + total_frames], rax
.Lxing_skip:
    mov rax, [rip + mp_frame_end]
    mov [rip + mp_cursor], rax
.Lmp_open_ok:
    mov rax, [rip + mp_cursor]
    mov [rip + mp_stream_begin], rax
    mov eax, [rip + mp_trim_start]
    mov [rip + mp_initial_trim], eax
    call mp_build_index
    test eax, eax
    jz .Lmp_open_bad
    mov eax, 1
    jmp .Lmp_open_return
.Lmp_open_bad:
    xor eax, eax
.Lmp_open_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp3_open

FN mp3_close
    sub rsp, 40
    mov rcx, [rip + mp_index]
    mov qword ptr [rip + mp_index], 0
    mov dword ptr [rip + mp3_index_count], 0
    mov qword ptr [rip + mp3_seek_headers], 0
    test rcx, rcx
    jz .Lmp_index_closed
    call mem_free
.Lmp_index_closed:
    add rsp, 40
    ret
ENDFN mp3_close

# Structural scan only: header/CRC, side information, part lengths and exact
# unused reservoir. Huffman, IMDCT and synthesis are deferred until playback.
# Each point occupies 544 bytes; compact alternate points on reaching the cap.
LOCALFN mp_build_index
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov ecx, MP_INDEX_POINT*MP_INDEX_CAP
    call mem_alloc
    test rax, rax
    jz .Lmp_index_optional
    mov [rip + mp_index], rax
    mov qword ptr [rip + mp3_index_stride], 32
    xor r12d, r12d            #compressed frame ordinal
    xor r13d, r13d            #raw PCM sample count before this frame
.Lmp_index_scan:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmp_index_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lmp_index_bad
.Lmp_index_not_cancelled:
    mov rax, [rip + mp_end]
    sub rax, [rip + mp_cursor]
    jz .Lmp_index_complete
    cmp rax, 128
    jne .Lmp_index_frame
    mov rax, [rip + mp_cursor]
    cmp word ptr [rax], 0x4154
    jne .Lmp_index_frame
    cmp byte ptr [rax + 2], 'G'
    je .Lmp_index_complete
.Lmp_index_frame:
    mov rax, [rip + mp3_index_stride]
    dec rax
    test r12, rax
    jnz .Lmp_index_skip
    cmp dword ptr [rip + mp3_index_count], MP_INDEX_CAP
    jb .Lmp_index_store
    # Entries are multiples of 16 bytes, and the source always follows its
    # destination. Keep 0,2,4,... then double the stride without growing memory.
    mov rbx, 1
.Lmp_index_compact:
    imul rax, rbx, MP_INDEX_POINT*2
    mov rsi, [rip + mp_index]
    add rsi, rax
    imul rax, rbx, MP_INDEX_POINT
    mov rdi, [rip + mp_index]
    add rdi, rax
    mov ecx, MP_INDEX_POINT/8
    rep movsq
    inc ebx
    cmp ebx, MP_INDEX_CAP/2
    jb .Lmp_index_compact
    mov dword ptr [rip + mp3_index_count], MP_INDEX_CAP/2
    shl qword ptr [rip + mp3_index_stride], 1
.Lmp_index_store:
    mov eax, [rip + mp3_index_count]
    imul rax, MP_INDEX_POINT
    add rax, [rip + mp_index]
    mov rcx, [rip + mp_cursor]
    mov [rax], rcx
    mov [rax + 8], r13
    mov ecx, [rip + mp_reserv_size]
    mov [rax + 16], ecx
    lea rdi, [rax + 20]
    lea rsi, [rip + mp_reserv]
    rep movsb
    inc dword ptr [rip + mp3_index_count]
.Lmp_index_skip:
    call mp_skip_frame
    test eax, eax
    jz .Lmp_index_bad
    mov eax, [rip + mp_samples]
    add r13, rax
    inc r12
    jmp .Lmp_index_scan
.Lmp_index_complete:
    mov eax, [rip + mp_initial_trim]
    sub r13, rax
    jc .Lmp_index_bad
    mov eax, [rip + mp_trim_end]
    sub r13, rax
    jc .Lmp_index_bad
    cmp qword ptr [rip + total_frames], 0
    je .Lmp_index_duration
    cmp r13, [rip + total_frames]
    jne .Lmp_index_bad
.Lmp_index_duration:
    mov [rip + total_frames], r13
.Lmp_index_optional:
    mov rax, [rip + mp_stream_begin]
    mov [rip + mp_cursor], rax
    mov dword ptr [rip + mp_reserv_size], 0
    mov eax, 1
    jmp .Lmp_index_return
.Lmp_index_bad:
    xor eax, eax
.Lmp_index_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp_build_index

LOCALFN mp_skip_frame
    push rbx
    sub rsp, 32
    mov rcx, [rip + mp_cursor]
    call mp_parse_header
    test eax, eax
    jz .Lmp_skip_bad
    mov eax, [rip + mp_version]
    cmp eax, [rip + mp_initial_version]
    jne .Lmp_skip_bad
    mov eax, [rip + mp_rate]
    cmp eax, [rip + sample_rate]
    jne .Lmp_skip_bad
    mov eax, [rip + mp_channels]
    cmp eax, [rip + mp_initial_channels]
    jne .Lmp_skip_bad
    mov eax, [rip + mp_layer]
    cmp eax, [rip + mp_initial_layer]
    jne .Lmp_skip_bad
    cmp eax, 3
    je .Lmp_skip_layer3
    call mp_l12_scale_info             # allocation, CRC and scalefactors
    test eax, eax
    jz .Lmp_skip_bad
    mov rax, [rip + mp_frame_end]
    mov [rip + mp_cursor], rax
    mov eax, 1
    jmp .Lmp_skip_return
.Lmp_skip_layer3:
    call mp_sideinfo
    test eax, eax
    jz .Lmp_skip_bad
    lea rdx, [rip + mp_info]
    xor eax, eax
    xor ecx, ecx
.Lmp_skip_parts:
    add eax, [rdx + GI_PART]
    add rdx, GI_SIZE
    inc ecx
    cmp ecx, [rip + mp_gr_count]
    jb .Lmp_skip_parts
    cmp eax, [rip + mp_bit_limit]
    ja .Lmp_skip_bad
    mov [rip + mp_bit_pos], eax
    call mp_save_reservoir
    test eax, eax
    jz .Lmp_skip_bad
    mov rax, [rip + mp_frame_end]
    mov [rip + mp_cursor], rax
    mov eax, 1
    jmp .Lmp_skip_return
.Lmp_skip_bad:
    mov dword ptr [rip + decode_error], 15
    xor eax, eax
.Lmp_skip_return:
    add rsp, 32
    pop rbx
    ret
ENDFN mp_skip_frame

# Fresh-open only. Resume at least two compressed frames before the target so
# ordinary reads reconstruct overlap/QMF exactly before returning target PCM.
FN mp3_seek
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    xor eax, eax
    mov qword ptr [rip + mp3_seek_headers], 0
    test rcx, rcx
    jz .Lmp_seek_return
    cmp dword ptr [rip + mp3_index_count], 0
    je .Lmp_seek_return
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    mov eax, [rip + mp_initial_trim]
    add rcx, rax
    mov r12, rcx
    mov eax, [rip + mp_samples]
    add rax, rax
    sub r12, rax
    jae .Lmp_seek_warm_target
    xor r12d, r12d
.Lmp_seek_warm_target:
    xor r8d, r8d
    mov r9d, [rip + mp3_index_count]
.Lmp_seek_search:
    cmp r8d, r9d
    jae .Lmp_seek_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    imul eax, edx, MP_INDEX_POINT
    add rax, [rip + mp_index]
    cmp [rax + 8], r12
    ja .Lmp_seek_upper
    lea r8d, [rdx + 1]
    jmp .Lmp_seek_search
.Lmp_seek_upper:
    mov r9d, edx
    jmp .Lmp_seek_search
.Lmp_seek_found:
    dec r8d                 #point zero always exists and is at raw sample0
    imul eax, r8d, MP_INDEX_POINT
    add rax, [rip + mp_index]
    mov rcx, [rax]
    mov [rip + mp_cursor], rcx
    mov rbx, [rax + 8]
    mov ecx, [rax + 16]
    mov [rip + mp_reserv_size], ecx
    lea rsi, [rax + 20]
    lea rdi, [rip + mp_reserv]
    rep movsb
.Lmp_seek_skip:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmp_seek_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lmp_seek_cancelled
.Lmp_seek_not_cancelled:
    mov eax, [rip + mp_samples]
    add rax, rbx
    cmp rax, r12
    ja .Lmp_seek_position
    call mp_skip_frame
    test eax, eax
    jz .Lmp_seek_cancelled
    mov eax, [rip + mp_samples]
    add rbx, rax
    inc qword ptr [rip + mp3_seek_headers]
    jmp .Lmp_seek_skip
.Lmp_seek_position:
    mov dword ptr [rip + mp_frame_ready], 0
    mov dword ptr [rip + mp_frame_used], 0
    mov eax, [rip + mp_initial_trim]
    mov dword ptr [rip + mp_trim_start], 0
    cmp rbx, rax
    jae .Lmp_seek_emitted
    sub eax, ebx
    mov [rip + mp_trim_start], eax
    xor ebx, ebx
    jmp .Lmp_seek_ready
.Lmp_seek_emitted:
    sub rbx, rax
.Lmp_seek_ready:
    mov [rip + mp_emitted], rbx
    mov rax, rbx
    jmp .Lmp_seek_return
.Lmp_seek_cancelled:
    xor eax, eax
.Lmp_seek_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp3_seek

# Header inspection. State is only committed after bounds/field validation.
LOCALFN mp_parse_header
    push rbx
    sub rsp, 32
    lea rax, [rcx + 4]
    cmp rax, [rip + mp_end]
    ja .Lheader_bad
    mov ebx, [rcx]
    bswap ebx
    mov eax, ebx
    and eax, 0xffe00000
    cmp eax, 0xffe00000
    jne .Lheader_bad
    mov eax, ebx
    shr eax, 17
    and eax, 3
    jz .Lheader_bad
    mov edx, 4
    sub edx, eax
    mov [rip + mp_layer], edx          # bits 01/10/11 are Layers III/II/I
    mov eax, ebx
    shr eax, 19
    and eax, 3
    cmp eax, 1
    je .Lheader_bad
    test eax, eax
    jnz .Lheader_version_ok
    cmp edx, 3
    jne .Lheader_bad                   # MPEG 2.5 defines Layer III only
.Lheader_version_ok:
    mov [rip + mp_version], eax
    mov edx, ebx
    shr edx, 10
    and edx, 3
    cmp edx, 3
    je .Lheader_bad
    lea r8, [rip + mp_rates]
    mov r8d, [r8 + rdx*4]
    cmp eax, 3
    je .Lheader_mpeg1
    shr r8d, 1
    cmp eax, 2
    je .Lheader_mpeg2
    shr r8d, 1
    cmp edx, 0
    je .Lheader_sr_ready
    dec edx
    jmp .Lheader_sr_ready
.Lheader_mpeg2:
    add edx, 2
    jmp .Lheader_sr_ready
.Lheader_mpeg1:
    add edx, 5
.Lheader_sr_ready:
    mov [rip + mp_sr_index], edx
    mov [rip + mp_rate], r8d
    mov edx, ebx
    shr edx, 12
    and edx, 15
    test edx, edx
    jz .Lheader_bad          # free format intentionally unsupported
    cmp edx, 15
    je .Lheader_bad
    cmp dword ptr [rip + mp_layer], 3
    jne .Lheader_layer12
    lea r9, [rip + bitrate2]
    mov eax, 72000
    mov dword ptr [rip + mp_samples], 576
    cmp dword ptr [rip + mp_version], 3
    jne .Lheader_bitrate
    lea r9, [rip + bitrate1]
    mov eax, 144000
    mov dword ptr [rip + mp_samples], 1152
.Lheader_bitrate:
    mov r10d, [r9 + rdx*4]
    mov [rip + mp_kbps], r10d
    imul eax, r10d
    xor edx, edx
    div r8d
    mov edx, ebx
    shr edx, 9
    and edx, 1
    add eax, edx
    jmp .Lheader_frame_bytes
.Lheader_layer12:
    # Layer II: 1152 samples, 144000*kbps/rate bytes. Layer I: 384 samples in
    # four-byte slots, 4*(12000*kbps/rate + padding) bytes.
    lea r9, [rip + bitrate2]
    cmp dword ptr [rip + mp_version], 3
    jne .Lheader_layer12_table
    lea r9, [rip + bitrate1_l2]
.Lheader_layer12_table:
    cmp dword ptr [rip + mp_layer], 1
    je .Lheader_layer1
    mov r10d, [r9 + rdx*4]
    mov [rip + mp_kbps], r10d
    mov dword ptr [rip + mp_samples], 1152
    mov eax, 144000
    imul eax, r10d
    xor edx, edx
    div r8d
    mov edx, ebx
    shr edx, 9
    and edx, 1
    add eax, edx
    jmp .Lheader_frame_bytes
.Lheader_layer1:
    lea r9, [rip + bitrate2_l1]
    cmp dword ptr [rip + mp_version], 3
    jne .Lheader_layer1_rate
    lea r9, [rip + bitrate1_l1]
.Lheader_layer1_rate:
    mov r10d, [r9 + rdx*4]
    mov [rip + mp_kbps], r10d
    mov dword ptr [rip + mp_samples], 384
    mov eax, 12000
    imul eax, r10d
    xor edx, edx
    div r8d
    mov edx, ebx
    shr edx, 9
    and edx, 1
    add eax, edx
    shl eax, 2
.Lheader_frame_bytes:
    mov [rip + mp_frame_bytes], eax
    lea rax, [rcx + rax]
    cmp rax, [rip + mp_end]
    ja .Lheader_bad
    mov [rip + mp_frame_end], rax
    mov eax, ebx
    shr eax, 6
    and eax, 3
    mov dword ptr [rip + mp_channels], 2
    cmp eax, 3
    jne .Lheader_stereo
    mov dword ptr [rip + mp_channels], 1
.Lheader_stereo:
    mov dword ptr [rip + mp_ms], 0
    mov dword ptr [rip + mp_intensity], 0
    cmp eax, 1
    jne .Lheader_mode_done
    mov eax, ebx
    shr eax, 4
    and eax, 1
    mov [rip + mp_intensity], eax
    mov eax, ebx
    shr eax, 5
    and eax, 1
    mov [rip + mp_ms], eax
.Lheader_mode_done:
    mov eax, ebx
    shr eax, 16
    and eax, 1
    xor eax, 1
    shl eax, 1
    mov [rip + mp_crc_bytes], eax
    xor edx, edx                       # Layers I/II: allocation follows directly
    cmp dword ptr [rip + mp_layer], 3
    jne .Lheader_side_ready
    mov edx, 17
    cmp dword ptr [rip + mp_version], 3
    jne .Lheader_lsf_side
    cmp dword ptr [rip + mp_channels], 2
    jne .Lheader_side_ready
    mov edx, 32
    jmp .Lheader_side_ready
.Lheader_lsf_side:
    cmp dword ptr [rip + mp_channels], 2
    je .Lheader_side_ready
    mov edx, 9
.Lheader_side_ready:
    mov [rip + mp_side_bytes], edx
    add eax, edx
    add eax, 4
    cmp eax, [rip + mp_frame_bytes]
    jae .Lheader_bad
    cmp dword ptr [rip + mp_crc_bytes], 0
    je .Lheader_crc_valid
    cmp dword ptr [rip + mp_layer], 3
    jne .Lheader_crc_valid             # Layers I/II check it with the allocation
    # Layer III CRC: the final 16 header bits and complete side information.
    # MSB first, initial FFFF, polynomial x^16+x^15+x^2+1.
    mov eax, 0xffff
    mov r8d, 2
    mov r9d, 4
.Lheader_crc_byte:
    movzx edx, byte ptr [rcx + r8]
    shl edx, 8
    xor eax, edx
    mov r11d, 8
.Lheader_crc_bit:
    mov edx, eax
    shl eax, 1
    test edx, 0x8000
    jz .Lheader_crc_no_xor
    xor eax, 0x8005
.Lheader_crc_no_xor:
    dec r11d
    jnz .Lheader_crc_bit
    inc r8d
    cmp r8d, r9d
    jb .Lheader_crc_byte
    cmp r9d, 4
    jne .Lheader_crc_compare
    mov r8d, 6
    mov r9d, [rip + mp_side_bytes]
    add r9d, 6
    jmp .Lheader_crc_byte
.Lheader_crc_compare:
    movzx edx, word ptr [rcx + 4]
    rol dx, 8
    and eax, 0xffff
    cmp eax, edx
    jne .Lheader_bad
.Lheader_crc_valid:
    mov [rip + mp_header], ebx
    mov eax, 1
    jmp .Lheader_return
.Lheader_bad:
    xor eax, eax
.Lheader_return:
    add rsp, 32
    pop rbx
    ret
ENDFN mp_parse_header

# Safe bit reads, at most 24 bits per call. Peek zero-pads beyond the byte end
# for Huffman lookahead; actual consumed bits are checked against part limits.
LOCALFN mp_peek
    mov r9d, ecx
    test ecx, ecx
    jz .Lbits_zero
    mov r8d, [rip + mp_bit_pos]
    mov r10d, r8d
    shr r10d, 3
    and r8d, 7
    mov r11, [rip + mp_bit_base]
    mov eax, [rip + mp_bit_limit]
    add eax, 7
    shr eax, 3
    mov edx, eax
    xor eax, eax
    mov ecx, 4
.Lpeek_bytes:
    shl eax, 8
    cmp r10d, edx
    jae .Lpeek_padding
    movzx r8d, byte ptr [r11 + r10]
    or eax, r8d
.Lpeek_padding:
    inc r10d
    dec ecx
    jnz .Lpeek_bytes
    mov ecx, [rip + mp_bit_pos]
    and ecx, 7
    shl eax, cl
    mov ecx, 32
    sub ecx, r9d
    shr eax, cl
    ret
.Lbits_zero:
    xor eax, eax
    ret
ENDFN mp_peek

FN mp_bits
    sub rsp, 40
    mov [rsp + 32], ecx
    call mp_peek
    mov ecx, [rsp + 32]
    add [rip + mp_bit_pos], ecx
    mov ecx, [rip + mp_bit_pos]
    cmp ecx, [rip + mp_bit_limit]
    jbe .Lbits_valid
    mov dword ptr [rip + decode_error], 11
.Lbits_valid:
    add rsp, 40
    ret
ENDFN mp_bits

# Parse one complete side-information section and assemble main-data history.
LOCALFN mp_sideinfo
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    lea rdi, [rip + mp_info]
    xor eax, eax
    mov ecx, GI_SIZE
    rep stosd
    mov rax, [rip + mp_cursor]
    mov ecx, [rip + mp_crc_bytes]
    lea rax, [rax + rcx + 4]
    mov [rip + mp_bit_base], rax
    mov eax, [rip + mp_side_bytes]
    shl eax, 3
    mov [rip + mp_bit_limit], eax
    mov dword ptr [rip + mp_bit_pos], 0
    mov ecx, 8
    mov eax, [rip + mp_channels]
    mov [rip + mp_gr_count], eax
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_lsf_begin
    inc ecx
    shl dword ptr [rip + mp_gr_count], 1
.Lside_lsf_begin:
    call mp_bits
    mov [rip + mp_main_begin], eax
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_lsf_private
    mov ecx, 3
    cmp dword ptr [rip + mp_channels], 1
    jne .Lside_private_read
    mov ecx, 5
.Lside_private_read:
    call mp_bits
    xor ebx, ebx
.Lside_scfsi:
    mov ecx, 4
    call mp_bits
    lea rdx, [rip + mp_scfsi]
    mov [rdx + rbx*4], eax
    inc ebx
    cmp ebx, [rip + mp_channels]
    jb .Lside_scfsi
    jmp .Lside_gr_start
.Lside_lsf_private:
    mov ecx, [rip + mp_channels]
    call mp_bits
.Lside_gr_start:
    xor ebx, ebx
    lea rsi, [rip + mp_info]
.Lside_gr_loop:
    mov ecx, 12
    call mp_bits
    mov [rsi + GI_PART], eax
    mov ecx, 9
    call mp_bits
    cmp eax, 288
    ja .Lside_bad
    mov [rsi + GI_BIG], eax
    mov ecx, 8
    call mp_bits
    mov [rsi + GI_GAIN], eax
    mov ecx, 9
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_sfc_read
    mov ecx, 4
.Lside_sfc_read:
    call mp_bits
    mov [rsi + GI_SFC], eax
    mov dword ptr [rsi + GI_LONG], 22
    mov eax, [rip + mp_sr_index]
    imul eax, 23
    lea rdx, [rip + mp_sfb_long]
    add rdx, rax
    mov [rsi + GI_SFB], rdx
    mov ecx, 1
    call mp_bits
    test eax, eax
    jz .Lside_long
    mov ecx, 2
    call mp_bits
    test eax, eax
    jz .Lside_bad
    mov [rsi + GI_BLOCK], eax
    mov ecx, 1
    call mp_bits
    mov [rsi + GI_MIX], eax
    mov byte ptr [rsi + GI_REGION], 7
    mov byte ptr [rsi + GI_REGION + 1], 255
    cmp dword ptr [rsi + GI_BLOCK], 2
    jne .Lside_switch_tables
    mov eax, [rip + mp_sr_index]
    imul eax, 40
    lea rdx, [rip + mp_sfb_short]
    mov dword ptr [rsi + GI_LONG], 0
    mov dword ptr [rsi + GI_SHORT], 39
    mov byte ptr [rsi + GI_REGION], 8
    cmp dword ptr [rsi + GI_MIX], 0
    je .Lside_short_ready
    lea rdx, [rip + mp_sfb_mixed]
    mov dword ptr [rsi + GI_LONG], 6
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_mixed_lsf
    mov dword ptr [rsi + GI_LONG], 8
.Lside_mixed_lsf:
    mov dword ptr [rsi + GI_SHORT], 30
    mov byte ptr [rsi + GI_REGION], 7
.Lside_short_ready:
    add rdx, rax
    mov [rsi + GI_SFB], rdx
.Lside_switch_tables:
    mov ecx, 5
    call mp_bits
    cmp eax, 4
    je .Lside_bad
    cmp eax, 14
    je .Lside_bad
    mov [rsi + GI_TABLE], al
    mov ecx, 5
    call mp_bits
    cmp eax, 4
    je .Lside_bad
    cmp eax, 14
    je .Lside_bad
    mov [rsi + GI_TABLE + 1], al
    xor edi, edi
.Lside_subgain:
    mov ecx, 3
    call mp_bits
    mov [rsi + rdi + GI_SUBGAIN], al
    inc edi
    cmp edi, 3
    jb .Lside_subgain
    jmp .Lside_preflag
.Lside_long:
    xor edi, edi
.Lside_tables:
    mov ecx, 5
    call mp_bits
    cmp eax, 4
    je .Lside_bad
    cmp eax, 14
    je .Lside_bad
    mov [rsi + rdi + GI_TABLE], al
    inc edi
    cmp edi, 3
    jb .Lside_tables
    mov ecx, 4
    call mp_bits
    mov [rsi + GI_REGION], al
    mov ecx, 3
    call mp_bits
    mov [rsi + GI_REGION + 1], al
    mov byte ptr [rsi + GI_REGION + 2], 255
.Lside_preflag:
    mov eax, [rsi + GI_SFC]
    cmp eax, 500
    setae al
    movzx eax, al
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_pre_ready
    mov ecx, 1
    call mp_bits
.Lside_pre_ready:
    mov [rsi + GI_PRE], eax
    mov ecx, 1
    call mp_bits
    mov [rsi + GI_SCALE], eax
    mov ecx, 1
    call mp_bits
    mov [rsi + GI_COUNT], eax
    cmp dword ptr [rip + mp_version], 3
    jne .Lside_no_scfsi
    cmp ebx, [rip + mp_channels]
    jb .Lside_next
    cmp dword ptr [rsi + GI_BLOCK], 2
    je .Lside_next
    mov eax, ebx
    sub eax, [rip + mp_channels]
    lea rdx, [rip + mp_scfsi]
    mov eax, [rdx + rax*4]
    mov [rsi + GI_SCFSI], eax
    jmp .Lside_next
.Lside_no_scfsi:
    mov dword ptr [rsi + GI_SCFSI], -16
.Lside_next:
    inc ebx
    add rsi, GI_SIZE
    cmp ebx, [rip + mp_gr_count]
    jb .Lside_gr_loop
    cmp dword ptr [rip + decode_error], 0
    jne .Lside_bad
    mov eax, [rip + mp_main_begin]
    cmp eax, [rip + mp_reserv_size]
    jbe .Lside_reservoir_ready
    # After a track-mode seek the reservoir starts empty: earlier main data is
    # read as zeros until a frame finds all of its data. Those pre-roll frames
    # are discarded.
    cmp dword ptr [rip + mp_track_tolerant], 0
    je .Lside_bad
    mov dword ptr [rip + mp_main_incomplete], 1
    lea rdi, [rip + mp_main]
    mov ecx, eax
    sub ecx, [rip + mp_reserv_size]
    xor eax, eax
    rep stosb
    lea rsi, [rip + mp_reserv]
    mov ecx, [rip + mp_reserv_size]
    rep movsb
    jmp .Lside_frame_data
.Lside_reservoir_ready:
    mov dword ptr [rip + mp_track_tolerant], 0
    mov dword ptr [rip + mp_main_incomplete], 0
    mov ecx, eax
    mov eax, [rip + mp_reserv_size]
    sub eax, ecx
    lea rsi, [rip + mp_reserv]
    add rsi, rax
    lea rdi, [rip + mp_main]
    rep movsb
.Lside_frame_data:
    mov rsi, [rip + mp_bit_base]
    mov eax, [rip + mp_side_bytes]
    add rsi, rax
    mov rax, [rip + mp_frame_end]
    sub rax, rsi
    mov ecx, eax
    add eax, [rip + mp_main_begin]
    cmp eax, 4096
    ja .Lside_bad
    mov [rip + mp_main_bytes], eax
    rep movsb
    lea rax, [rip + mp_main]
    mov [rip + mp_bit_base], rax
    mov eax, [rip + mp_main_bytes]
    shl eax, 3
    mov [rip + mp_bit_limit], eax
    mov dword ptr [rip + mp_bit_pos], 0
    mov eax, 1
    jmp .Lside_return
.Lside_bad:
    mov dword ptr [rip + decode_error], 12
    xor eax, eax
.Lside_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_sideinfo

# RCX=granule info. Read and reuse scalefactors; create per-band gains.
LOCALFN mp_scalefactors
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 64
    mov rsi, rcx
    mov eax, [rsi + GI_SCALE]
    inc eax
    mov [rip + mp_scf_shift], eax
    mov eax, [rsi + GI_LONG]
    add eax, [rsi + GI_SHORT]
    mov [rip + mp_scale_count], eax
    lea rdi, [rip + mp_iscf]
    xor eax, eax
    mov ecx, 40
    rep stosb
    mov eax, [rip + mp_channel]
    imul eax, 40
    lea r12, [rip + mp_ist]
    add r12, rax
    mov ebx, [rsi + GI_SCFSI]
    mov eax, 0
    cmp dword ptr [rsi + GI_SHORT], 0
    setne al
    cmp dword ptr [rsi + GI_LONG], 0
    jne .Lsf_part_row
    inc eax
.Lsf_part_row:
    imul eax, 28
    lea r13, [rip + mp_partitions]
    add r13, rax
    lea r14, [rip + mp_scf_sizes]
    cmp dword ptr [rip + mp_version], 3
    jne .Lsf_lsf
    mov eax, [rsi + GI_SFC]
    lea rdx, [rip + mp_scfc]
    movzx eax, byte ptr [rdx + rax]
    mov ecx, eax
    shr eax, 2
    and ecx, 3
    mov [r14], eax
    mov [r14 + 4], eax
    mov [r14 + 8], ecx
    mov [r14 + 12], ecx
    jmp .Lsf_read_groups
.Lsf_lsf:
    mov r10d, [rsi + GI_SFC]
    xor r11d, r11d
    cmp dword ptr [rip + mp_channel], 0
    je .Llsf_mod_loop
    cmp dword ptr [rip + mp_intensity], 0
    je .Llsf_mod_loop
    shr r10d, 1
    mov r11d, 12
.Llsf_mod_loop:
    lea r8, [rip + mp_mod]
    add r8, r11
    mov r9d, 1
    mov edi, 3
.Llsf_mod_digit:
    mov eax, r10d
    xor edx, edx
    div r9d
    movzx ecx, byte ptr [r8 + rdi]
    xor edx, edx
    div ecx
    mov [r14 + rdi*4], edx
    imul r9d, ecx
    dec edi
    jns .Llsf_mod_digit
    sub r10d, r9d
    add r11d, 4
    test r10d, r10d
    jns .Llsf_mod_loop
    add r13, r11
.Lsf_read_groups:
    lea rdi, [rip + mp_iscf]
    xor r14d, r14d
.Lsf_group:
    cmp r14d, 4
    jae .Lsf_post
    movzx eax, byte ptr [r13 + r14]
    test eax, eax
    jz .Lsf_post
    mov [rsp + 32], eax
    test ebx, 8
    jnz .Lsf_reuse
    lea rdx, [rip + mp_scf_sizes]
    mov eax, [rdx + r14*4]
    mov [rsp + 36], eax
    xor r9d, r9d
.Lsf_values:
    mov [rsp + 40], r9d
    mov ecx, [rsp + 36]
    call mp_bits
    mov r9d, [rsp + 40]
    mov [rdi + r9], al
    mov edx, eax
    cmp ebx, 0
    jge .Lsf_ist_store
    cmp dword ptr [rsp + 36], 0
    je .Lsf_ist_store
    mov ecx, [rsp + 36]
    mov eax, 1
    shl eax, cl
    dec eax
    cmp edx, eax
    jne .Lsf_ist_store
    mov edx, 255
.Lsf_ist_store:
    mov [r12 + r9], dl
    inc r9d
    cmp r9d, [rsp + 32]
    jb .Lsf_values
    jmp .Lsf_group_done
.Lsf_reuse:
    xor eax, eax
.Lsf_reuse_loop:
    mov dl, [r12 + rax]
    mov [rdi + rax], dl
    inc eax
    cmp eax, [rsp + 32]
    jb .Lsf_reuse_loop
.Lsf_group_done:
    mov eax, [rsp + 32]
    add rdi, rax
    add r12, rax
    shl ebx, 1
    inc r14d
    jmp .Lsf_group
.Lsf_post:
    cmp dword ptr [rsi + GI_SHORT], 0
    je .Lsf_preemphasis
    mov ebx, [rsi + GI_LONG]
    mov edi, [rsi + GI_SHORT]
    add edi, ebx
    lea r12, [rip + mp_iscf]
.Lsf_subblocks:
    cmp ebx, edi
    jae .Lsf_gain_start
    xor r13d, r13d
.Lsf_subblock_gain:
    movzx eax, byte ptr [rsi + r13 + GI_SUBGAIN]
    mov ecx, 3
    sub ecx, [rip + mp_scf_shift]
    shl eax, cl
    add [r12 + rbx], al
    inc ebx
    inc r13d
    cmp r13d, 3
    jb .Lsf_subblock_gain
    jmp .Lsf_subblocks
.Lsf_preemphasis:
    cmp dword ptr [rsi + GI_PRE], 0
    je .Lsf_gain_start
    lea r12, [rip + mp_iscf]
    lea r13, [rip + mp_preamp]
    xor ebx, ebx
.Lsf_preloop:
    mov al, [r13 + rbx]
    add [r12 + rbx + 11], al
    inc ebx
    cmp ebx, 10
    jb .Lsf_preloop
.Lsf_gain_start:
    xor ebx, ebx
    lea r12, [rip + mp_iscf]
    lea r13, [rip + mp_scales]
    lea r14, [rip + mp_gain]
.Lsf_gain_loop:
    cmp ebx, [rip + mp_scale_count]
    jae .Lsf_done
    movzx edx, byte ptr [r12 + rbx]
    mov ecx, [rip + mp_scf_shift]
    shl edx, cl
    mov eax, [rsi + GI_GAIN]
    sub eax, 214
    sub eax, edx
    mov edx, [rip + mp_ms]
    shl edx, 1
    sub eax, edx
    add eax, 800
    cmp eax, mp_gain_count
    jae .Lsf_bad
    mov eax, [r14 + rax*4]
    mov [r13 + rbx*4], eax
    inc ebx
    jmp .Lsf_gain_loop
.Lsf_bad:
    mov dword ptr [rip + decode_error], 13
.Lsf_done:
    add rsp, 64
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_scalefactors

# RCX=granule info, RDX=spectrum. Bounds-checked Huffman pairs and quads.
LOCALFN mp_huffman
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 96
    mov rsi, rcx
    mov rdi, rdx
    mov r12, [rsi + GI_SFB]
    xor ebx, ebx               # spectral sample index
    xor r13d, r13d             # scale band index
    xor r14d, r14d             # region index
    mov dword ptr [rsp + 32], 0 # pair index
    mov dword ptr [rsp + 36], 0 # band sample end
    movzx eax, byte ptr [rsi + GI_REGION]
    inc eax
    mov [rsp + 40], eax         # exclusive region end in scale bands
.Lhuff_pair:
    mov eax, [rsp + 32]
    cmp eax, [rsi + GI_BIG]
    jae .Lhuff_quads
    cmp ebx, [rsp + 36]
    jb .Lhuff_band_ready
    cmp r13d, [rip + mp_scale_count]
    jae .Lhuff_bad
    movzx eax, byte ptr [r12 + r13]
    test eax, eax
    jz .Lhuff_bad
    add [rsp + 36], eax
    cmp r13d, [rsp + 40]
    jb .Lhuff_same_region
    inc r14d
    cmp r14d, 3
    jae .Lhuff_bad
    movzx eax, byte ptr [rsi + r14 + GI_REGION]
    inc eax
    add [rsp + 40], eax
.Lhuff_same_region:
    lea rax, [rip + mp_scales]
    mov eax, [rax + r13*4]
    mov [rsp + 44], eax
    inc r13d
.Lhuff_band_ready:
    movzx eax, byte ptr [rsi + r14 + GI_TABLE]
    lea rdx, [rip + mp_huff_linbits]
    movzx edx, byte ptr [rdx + rax]
    mov [rsp + 48], edx
    lea rdx, [rip + mp_huff_index]
    movzx eax, word ptr [rdx + rax*2]
    lea rdx, [rip + mp_huff_tabs]
    lea rdx, [rdx + rax*2]
    mov [rsp + 56], rdx
    mov dword ptr [rsp + 64], 5
    mov ecx, 5
    call mp_peek
    mov rdx, [rsp + 56]
    movsx eax, word ptr [rdx + rax*2]
.Lhuff_tree:
    test eax, eax
    jns .Lhuff_leaf
    mov [rsp + 68], eax
    mov ecx, [rsp + 64]
    call mp_bits
    mov eax, [rsp + 68]
    mov ecx, eax
    and ecx, 7
    mov [rsp + 64], ecx
    sar eax, 3
    neg eax
    mov [rsp + 72], eax
    call mp_peek
    add eax, [rsp + 72]
    mov rdx, [rsp + 56]
    lea rdx, [rdx + rax*2]
    lea rax, [rip + mp_huff_index]
    cmp rdx, rax
    jae .Lhuff_bad
    movsx eax, word ptr [rdx]
    jmp .Lhuff_tree
.Lhuff_leaf:
    mov [rsp + 68], eax
    mov ecx, eax
    shr ecx, 8
    call mp_bits
    mov dword ptr [rsp + 76], 0
.Lhuff_pair_values:
    mov eax, [rsp + 68]
    and eax, 15
    mov [rsp + 80], eax
    cmp eax, 15
    jne .Lhuff_sign
    mov ecx, [rsp + 48]
    call mp_bits
    add [rsp + 80], eax
.Lhuff_sign:
    mov dword ptr [rsp + 84], 0
    cmp dword ptr [rsp + 80], 0
    je .Lhuff_dequant
    mov ecx, 1
    call mp_bits
    shl eax, 31
    mov [rsp + 84], eax
.Lhuff_dequant:
    mov eax, [rsp + 80]
    cmp eax, mp_pow43_count
    jae .Lhuff_bad
    lea rdx, [rip + mp_pow43]
    movss xmm0, dword ptr [rdx + rax*4]
    mulss xmm0, dword ptr [rsp + 44]
    movd eax, xmm0
    xor eax, [rsp + 84]
    mov [rdi + rbx*4], eax
    inc ebx
    shr dword ptr [rsp + 68], 4
    inc dword ptr [rsp + 76]
    cmp dword ptr [rsp + 76], 2
    jb .Lhuff_pair_values
    mov eax, [rip + mp_bit_pos]
    cmp eax, [rip + mp_part_limit]
    ja .Lhuff_bad
    inc dword ptr [rsp + 32]
    jmp .Lhuff_pair
.Lhuff_quads:
    cmp ebx, 572
    ja .Lhuff_done
    mov eax, [rip + mp_bit_pos]
    cmp eax, [rip + mp_part_limit]
    jae .Lhuff_done
    mov [rsp + 88], eax
    lea rdx, [rip + mp_count32]
    cmp dword ptr [rsi + GI_COUNT], 0
    je .Lquad_table
    lea rdx, [rip + mp_count33]
.Lquad_table:
    mov [rsp + 56], rdx
    mov ecx, 4
    call mp_peek
    mov rdx, [rsp + 56]
    movzx eax, byte ptr [rdx + rax]
    test eax, 8
    jnz .Lquad_leaf
    mov [rsp + 68], eax
    mov ecx, 4
    call mp_peek             # consume 4-bit prefix for extended table lookup
    mov eax, [rip + mp_bit_pos]
    add eax, 4
    mov [rip + mp_bit_pos], eax
    mov ecx, [rsp + 68]
    and ecx, 3
    call mp_peek
    sub dword ptr [rip + mp_bit_pos], 4
    mov ecx, [rsp + 68]
    shr ecx, 3
    add eax, ecx
    mov rdx, [rsp + 56]
    movzx eax, byte ptr [rdx + rax]
.Lquad_leaf:
    mov [rsp + 68], eax
    mov ecx, eax
    and ecx, 7
    call mp_bits
    mov eax, [rip + mp_bit_pos]
    cmp eax, [rip + mp_part_limit]
    ja .Lhuff_quad_abort
    mov dword ptr [rsp + 76], 0
.Lquad_values:
    cmp ebx, [rsp + 36]
    jb .Lquad_band_ready
    cmp r13d, [rip + mp_scale_count]
    jae .Lhuff_quad_abort
    movzx eax, byte ptr [r12 + r13]
    add [rsp + 36], eax
    lea rdx, [rip + mp_scales]
    mov eax, [rdx + r13*4]
    mov [rsp + 44], eax
    inc r13d
.Lquad_band_ready:
    mov ecx, [rsp + 76]
    mov eax, 128
    shr eax, cl
    test eax, [rsp + 68]
    jz .Lquad_zero
    mov ecx, 1
    call mp_bits
    shl eax, 31
    xor eax, [rsp + 44]
    jmp .Lquad_store
.Lquad_zero:
    xor eax, eax
.Lquad_store:
    mov [rdi + rbx*4], eax
    inc ebx
    inc dword ptr [rsp + 76]
    cmp dword ptr [rsp + 76], 4
    jb .Lquad_values
    mov eax, [rip + mp_bit_pos]
    cmp eax, [rip + mp_part_limit]
    jbe .Lhuff_quads
    # Incomplete terminal quad is stuffing, discard all four values.
    sub ebx, 4
    xor eax, eax
    mov [rdi + rbx*4], eax
    mov [rdi + rbx*4 + 4], eax
    mov [rdi + rbx*4 + 8], eax
    mov [rdi + rbx*4 + 12], eax
.Lhuff_quad_abort:
    mov dword ptr [rip + decode_error], 0
.Lhuff_done:
    mov eax, [rip + mp_part_limit]
    mov [rip + mp_bit_pos], eax
    jmp .Lhuff_return
.Lhuff_bad:
    mov dword ptr [rip + decode_error], 14
.Lhuff_return:
    add rsp, 96
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_huffman

# Joint stereo processing, including MPEG-1 and LSF intensity bands.
LOCALFN mp_stereo
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    cmp dword ptr [rip + mp_channels], 2
    jne .Lstereo_done
    cmp dword ptr [rip + mp_intensity], 0
    jne .Lstereo_intensity
    cmp dword ptr [rip + mp_ms], 0
    je .Lstereo_done
    lea rsi, [rip + mp_grbuf]
    lea rdi, [rip + mp_grbuf + 576*4]
    mov ecx, 144
.Lstereo_ms_loop:
    movups xmm0, [rsi]
    movups xmm1, [rdi]
    movaps xmm2, xmm0
    addps xmm0, xmm1
    subps xmm2, xmm1
    movups [rsi], xmm0
    movups [rdi], xmm2
    add rsi, 16
    add rdi, 16
    dec ecx
    jnz .Lstereo_ms_loop
    jmp .Lstereo_done
.Lstereo_intensity:
    mov eax, [rip + mp_granule]
    imul eax, GI_SIZE
    lea r12, [rip + mp_info]
    add r12, rax
    mov rsi, [r12 + GI_SFB]
    mov eax, [r12 + GI_LONG]
    add eax, [r12 + GI_SHORT]
    mov [rsp + 32], eax
    mov dword ptr [rip + mp_max_band], -1
    mov dword ptr [rip + mp_max_band + 4], -1
    mov dword ptr [rip + mp_max_band + 8], -1
    lea rdi, [rip + mp_grbuf + 576*4]
    xor ebx, ebx
.Lstereo_scan_band:
    cmp ebx, [rsp + 32]
    jae .Lstereo_scan_done
    movzx ecx, byte ptr [rsi + rbx]
    xor eax, eax
.Lstereo_scan_samples:
    cmp eax, ecx
    jae .Lstereo_scan_next
    mov edx, [rdi + rax*4]
    and edx, 0x7fffffff
    jnz .Lstereo_band_nonzero
    inc eax
    jmp .Lstereo_scan_samples
.Lstereo_band_nonzero:
    mov eax, ebx
    xor edx, edx
    mov r8d, 3
    div r8d
    lea rax, [rip + mp_max_band]
    mov [rax + rdx*4], ebx
.Lstereo_scan_next:
    lea rdi, [rdi + rcx*4]
    inc ebx
    jmp .Lstereo_scan_band
.Lstereo_scan_done:
    cmp dword ptr [r12 + GI_LONG], 0
    je .Lstereo_top_short
    mov eax, [rip + mp_max_band]
    cmp eax, [rip + mp_max_band + 4]
    cmovl eax, [rip + mp_max_band + 4]
    cmp eax, [rip + mp_max_band + 8]
    cmovl eax, [rip + mp_max_band + 8]
    mov [rip + mp_max_band], eax
    mov [rip + mp_max_band + 4], eax
    mov [rip + mp_max_band + 8], eax
.Lstereo_top_short:
    mov edi, 1
    cmp dword ptr [r12 + GI_SHORT], 0
    je .Lstereo_top_count
    mov edi, 3
.Lstereo_top_count:
    xor ebx, ebx
.Lstereo_top_loop:
    mov ecx, [rsp + 32]
    sub ecx, edi
    add ecx, ebx
    mov eax, ecx
    sub eax, edi
    lea rdx, [rip + mp_max_band]
    cmp [rdx + rbx*4], eax
    jge .Lstereo_top_default
    lea rdx, [rip + mp_ist + 40]
    mov al, [rdx + rax]
    jmp .Lstereo_top_set
.Lstereo_top_default:
    xor eax, eax
    cmp dword ptr [rip + mp_version], 3
    jne .Lstereo_top_set
    mov eax, 3
.Lstereo_top_set:
    lea rdx, [rip + mp_ist + 40]
    mov [rdx + rcx], al
    inc ebx
    cmp ebx, edi
    jb .Lstereo_top_loop
    xor ebx, ebx
    lea rdi, [rip + mp_grbuf]
.Lstereo_process_band:
    cmp ebx, [rsp + 32]
    jae .Lstereo_done
    movzx eax, byte ptr [rsi + rbx]
    mov [rsp + 36], eax
    mov eax, ebx
    xor edx, edx
    mov ecx, 3
    div ecx
    lea rax, [rip + mp_max_band]
    cmp ebx, [rax + rdx*4]
    jle .Lstereo_band_ms
    lea rax, [rip + mp_ist + 40]
    movzx eax, byte ptr [rax + rbx]
    mov ecx, 64
    cmp dword ptr [rip + mp_version], 3
    jne .Lstereo_position_check
    mov ecx, 7
.Lstereo_position_check:
    cmp eax, ecx
    jae .Lstereo_band_ms
    movss xmm0, dword ptr [rip + one_float]
    movss xmm1, dword ptr [rip + one_float]
    cmp dword ptr [rip + mp_version], 3
    jne .Lstereo_lsf_pan
    lea rdx, [rip + mp_pan]
    movss xmm0, dword ptr [rdx + rax*8]
    movss xmm1, dword ptr [rdx + rax*8 + 4]
    jmp .Lstereo_pan_scale
.Lstereo_lsf_pan:
    mov ecx, eax
    inc ecx
    shr ecx, 1
    mov edx, [r12 + GI_SIZE + GI_SFC]
    and edx, 1
    xchg ecx, edx
    shl edx, cl
    mov ecx, 800
    sub ecx, edx
    lea rdx, [rip + mp_gain]
    movss xmm1, dword ptr [rdx + rcx*4]
    test eax, 1
    jz .Lstereo_pan_scale
    movaps xmm0, xmm1
    movss xmm1, dword ptr [rip + one_float]
.Lstereo_pan_scale:
    cmp dword ptr [rip + mp_ms], 0
    je .Lstereo_pan_loop_start
    mulss xmm0, dword ptr [rip + sqrt_two]
    mulss xmm1, dword ptr [rip + sqrt_two]
.Lstereo_pan_loop_start:
    xor ecx, ecx
.Lstereo_pan_loop:
    cmp ecx, [rsp + 36]
    jae .Lstereo_band_next
    movss xmm2, dword ptr [rdi + rcx*4]
    movaps xmm3, xmm2
    mulss xmm2, xmm0
    mulss xmm3, xmm1
    movss dword ptr [rdi + rcx*4], xmm2
    movss dword ptr [rdi + rcx*4 + 576*4], xmm3
    inc ecx
    jmp .Lstereo_pan_loop
.Lstereo_band_ms:
    cmp dword ptr [rip + mp_ms], 0
    je .Lstereo_band_next
    xor ecx, ecx
.Lstereo_ms_band:
    cmp ecx, [rsp + 36]
    jae .Lstereo_band_next
    movss xmm0, dword ptr [rdi + rcx*4]
    movss xmm1, dword ptr [rdi + rcx*4 + 576*4]
    movaps xmm2, xmm0
    addss xmm0, xmm1
    subss xmm2, xmm1
    movss dword ptr [rdi + rcx*4], xmm0
    movss dword ptr [rdi + rcx*4 + 576*4], xmm2
    inc ecx
    jmp .Lstereo_ms_band
.Lstereo_band_next:
    mov eax, [rsp + 36]
    lea rdi, [rdi + rax*4]
    inc ebx
    jmp .Lstereo_process_band
.Lstereo_done:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_stereo

LOCALFN mp_spectral_finish
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    mov r12, rcx            # granule info
    mov rbx, rdx           # spectrum
    mov eax, 0
    cmp dword ptr [r12 + GI_MIX], 0
    je .Lfinish_long_count
    mov eax, 2
    cmp dword ptr [rip + mp_sr_index], 1
    jne .Lfinish_long_count
    mov eax, 4
.Lfinish_long_count:
    mov [rsp + 32], eax
    mov dword ptr [rsp + 36], 31
    cmp dword ptr [r12 + GI_SHORT], 0
    je .Lfinish_alias
    dec eax
    mov [rsp + 36], eax
    mov eax, [rsp + 32]
    imul eax, 18*4
    lea rsi, [rbx + rax]
    mov [rsp + 40], rsi
    lea rdi, [rip + mp_temp]
    mov r8, [r12 + GI_SFB]
    mov eax, [r12 + GI_LONG]
    add r8, rax
.Lreorder_band:
    movzx ecx, byte ptr [r8]
    test ecx, ecx
    jz .Lreorder_copy
    xor eax, eax
.Lreorder_samples:
    mov edx, [rsi + rax*4]
    mov [rdi], edx
    mov r9d, eax
    add r9d, ecx
    mov edx, [rsi + r9*4]
    mov [rdi + 4], edx
    add r9d, ecx
    mov edx, [rsi + r9*4]
    mov [rdi + 8], edx
    add rdi, 12
    inc eax
    cmp eax, ecx
    jb .Lreorder_samples
    imul ecx, 12
    add rsi, rcx
    add r8, 3
    jmp .Lreorder_band
.Lreorder_copy:
    lea rsi, [rip + mp_temp]
    sub rdi, rsi
    mov rcx, rdi
    shr rcx, 2
    mov rdi, [rsp + 40]
    rep movsd
.Lfinish_alias:
    mov rsi, rbx
    mov edx, [rsp + 36]
.Lalias_band:
    test edx, edx
    jle .Lfinish_hybrid
    xor ecx, ecx
    lea r8, [rip + mp_aa]
.Lalias_pair:
    mov eax, 17
    sub eax, ecx
    movss xmm0, dword ptr [rsi + rcx*4 + 72]
    movss xmm1, dword ptr [rsi + rax*4]
    movaps xmm2, xmm0
    movaps xmm3, xmm1
    mulss xmm0, dword ptr [r8 + rcx*4]
    mulss xmm1, dword ptr [r8 + rcx*4 + 32]
    subss xmm0, xmm1
    mulss xmm2, dword ptr [r8 + rcx*4 + 32]
    mulss xmm3, dword ptr [r8 + rcx*4]
    addss xmm2, xmm3
    movss dword ptr [rsi + rcx*4 + 72], xmm0
    movss dword ptr [rsi + rax*4], xmm2
    inc ecx
    cmp ecx, 8
    jb .Lalias_pair
    add rsi, 72
    dec edx
    jmp .Lalias_band
.Lfinish_hybrid:
    mov rcx, rbx
    mov rdx, r12
    mov eax, [rip + mp_channel]
    imul eax, 288*4
    lea r8, [rip + mp_overlap]
    add r8, rax
    mov r9d, [rsp + 32]
    call mp_hybrid
    # Frequency inversion in odd subbands at odd time samples.
    mov edx, 1
.Linvert_band:
    imul eax, edx, 72
    lea rsi, [rbx + rax]
    mov ecx, 1
.Linvert_time:
    xor dword ptr [rsi + rcx*4], 0x80000000
    add ecx, 2
    cmp ecx, 18
    jb .Linvert_time
    add edx, 2
    cmp edx, 32
    jb .Linvert_band
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_spectral_finish

LOCALFN mp_decode_frame
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    mov rcx, [rip + mp_cursor]
    cmp rcx, [rip + mp_end]
    jae .Lmp_frame_eof
    mov rax, [rip + mp_end]
    sub rax, rcx
    cmp rax, 128
    jne .Lmp_frame_header
    cmp word ptr [rcx], 0x4154
    jne .Lmp_frame_header
    cmp byte ptr [rcx + 2], 'G'
    je .Lmp_frame_eof
.Lmp_frame_header:
    call mp_parse_header
    test eax, eax
    jz .Lmp_frame_bad
    mov eax, [rip + mp_version]
    cmp eax, [rip + mp_initial_version]
    jne .Lmp_frame_bad
    mov eax, [rip + mp_rate]
    cmp eax, [rip + sample_rate]
    jne .Lmp_frame_bad
    mov eax, [rip + mp_channels]
    cmp eax, [rip + mp_initial_channels]
    jne .Lmp_frame_bad
    mov eax, [rip + mp_layer]
    cmp eax, [rip + mp_initial_layer]
    jne .Lmp_frame_bad
    cmp eax, 3
    je .Lmp_frame_layer3
    call mp_l12_frame
    test eax, eax
    jz .Lmp_frame_bad
    jmp .Lmp_frame_decoded
.Lmp_frame_layer3:
    call mp_sideinfo
    test eax, eax
    jz .Lmp_frame_bad
    cmp dword ptr [rip + mp_main_incomplete], 0
    je .Lmp_frame_complete
    # Pre-roll frame without its reservoir: emit silence, keep the reservoir.
    lea rdx, [rip + mp_info]
    xor eax, eax
    xor ecx, ecx
.Lmp_frame_parts:
    add eax, [rdx + GI_PART]
    add rdx, GI_SIZE
    inc ecx
    cmp ecx, [rip + mp_gr_count]
    jb .Lmp_frame_parts
    cmp eax, [rip + mp_bit_limit]
    ja .Lmp_frame_bad
    mov [rip + mp_bit_pos], eax
    lea rdi, [rip + mp_pcm]
    mov ecx, [rip + mp_samples]
    xor eax, eax
    rep stosq
    jmp .Lmp_frame_reservoir
.Lmp_frame_complete:
    mov dword ptr [rip + mp_granule], 0
.Lgranule_loop:
    lea rdi, [rip + mp_grbuf]
    xor eax, eax
    mov ecx, 1152
    rep stosd
    mov dword ptr [rip + mp_channel], 0
.Lgranule_channel:
    mov eax, [rip + mp_granule]
    add eax, [rip + mp_channel]
    imul eax, GI_SIZE
    lea r12, [rip + mp_info]
    add r12, rax
    mov eax, [rip + mp_bit_pos]
    add eax, [r12 + GI_PART]
    cmp eax, [rip + mp_bit_limit]
    ja .Lmp_frame_bad
    mov [rip + mp_part_limit], eax
    mov rcx, r12
    call mp_scalefactors
    cmp dword ptr [rip + decode_error], 0
    jne .Lmp_frame_bad
    mov eax, [rip + mp_bit_pos]
    cmp eax, [rip + mp_part_limit]
    ja .Lmp_frame_bad
    mov eax, [rip + mp_channel]
    imul eax, 576*4
    lea rdx, [rip + mp_grbuf]
    add rdx, rax
    mov rcx, r12
    call mp_huffman
    cmp dword ptr [rip + decode_error], 0
    jne .Lmp_frame_bad
    inc dword ptr [rip + mp_channel]
    mov eax, [rip + mp_channel]
    cmp eax, [rip + mp_channels]
    jb .Lgranule_channel
    call mp_stereo
    mov dword ptr [rip + mp_channel], 0
.Lgranule_hybrid:
    mov eax, [rip + mp_granule]
    add eax, [rip + mp_channel]
    imul eax, GI_SIZE
    lea rcx, [rip + mp_info]
    add rcx, rax
    mov eax, [rip + mp_channel]
    imul eax, 576*4
    lea rdx, [rip + mp_grbuf]
    add rdx, rax
    call mp_spectral_finish
    inc dword ptr [rip + mp_channel]
    mov eax, [rip + mp_channel]
    cmp eax, [rip + mp_channels]
    jb .Lgranule_hybrid
    mov eax, [rip + mp_granule]
    xor edx, edx
    div dword ptr [rip + mp_channels]
    imul eax, 576*8
    lea rcx, [rip + mp_pcm]
    add rcx, rax
    mov edx, [rip + mp_channels]
    mov r8d, 18
    call mp_synthesis
    mov eax, [rip + mp_channels]
    add [rip + mp_granule], eax
    mov eax, [rip + mp_granule]
    cmp eax, [rip + mp_gr_count]
    jb .Lgranule_loop
.Lmp_frame_reservoir:
    call mp_save_reservoir
    test eax, eax
    jz .Lmp_frame_bad
.Lmp_frame_decoded:
    mov rax, [rip + mp_frame_end]
    mov [rip + mp_cursor], rax
    mov eax, [rip + mp_samples]
    mov [rip + mp_frame_ready], eax
    mov dword ptr [rip + mp_frame_used], 0
    mov eax, 1
    jmp .Lmp_frame_return
.Lmp_frame_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lmp_frame_eof
    mov dword ptr [rip + decode_error], 15
.Lmp_frame_eof:
    xor eax, eax
.Lmp_frame_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp_decode_frame

# Shared by complete decoding and structural index scans. Part lengths fix
# the final bit position independently of Huffman/synthesis work.
LOCALFN mp_save_reservoir
    push rsi
    push rdi
    # Preserve only unused, whole bytes, capped at the MPEG-1 511-byte history.
    mov eax, [rip + mp_bit_pos]
    add eax, 7
    shr eax, 3
    mov ecx, [rip + mp_main_bytes]
    sub ecx, eax
    js .Lmp_save_bad
    cmp ecx, 511
    jbe .Lreservoir_ready
    mov edx, ecx
    sub edx, 511
    add eax, edx
    mov ecx, 511
.Lreservoir_ready:
    mov [rip + mp_reserv_size], ecx
    lea rsi, [rip + mp_main]
    add rsi, rax
    lea rdi, [rip + mp_reserv]
    rep movsb
    mov eax, 1
    jmp .Lmp_save_return
.Lmp_save_bad:
    xor eax, eax
.Lmp_save_return:
    pop rdi
    pop rsi
    ret
ENDFN mp_save_reservoir

# Track mode for MPEG audio frames supplied by a container, one per packet.
# RCX=first frame, EDX=bytes -> EAX=1. Fixes layer, version, rate and channels.
FN mpa_track_open
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov esi, edx
    call mp3_close
    call mpa_track_reset
    mov dword ptr [rip + mp_trim_start], 0
    mov dword ptr [rip + mp_trim_end], 0
    mov qword ptr [rip + mp_emitted], 0
    lea rax, [rbx + rsi]
    mov [rip + mp_end], rax
    mov rcx, rbx
    call mp_parse_header
    test eax, eax
    jz .Lmpa_open_return
    mov eax, [rip + mp_rate]
    mov [rip + sample_rate], eax
    mov eax, [rip + mp_channels]
    mov [rip + source_channels], eax
    mov [rip + mp_initial_channels], eax
    mov eax, [rip + mp_version]
    mov [rip + mp_initial_version], eax
    mov eax, [rip + mp_layer]
    mov [rip + mp_initial_layer], eax
    mov dword ptr [rip + source_bits], 0
    mov dword ptr [rip + mp_track_tolerant], 0
    mov eax, 1
.Lmpa_open_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mpa_track_open

# RCX=frame, EDX=bytes -> EAX=samples, or -1 when the header is invalid or
# changes layer, version, rate or channel count.
FN mpa_track_samples
    sub rsp, 40
    lea rax, [rcx + rdx]
    mov [rip + mp_end], rax
    call mp_parse_header
    test eax, eax
    jz .Lmpa_samples_bad
    mov eax, [rip + mp_version]
    cmp eax, [rip + mp_initial_version]
    jne .Lmpa_samples_bad
    mov eax, [rip + mp_layer]
    cmp eax, [rip + mp_initial_layer]
    jne .Lmpa_samples_bad
    mov eax, [rip + mp_rate]
    cmp eax, [rip + sample_rate]
    jne .Lmpa_samples_bad
    mov eax, [rip + mp_channels]
    cmp eax, [rip + mp_initial_channels]
    jne .Lmpa_samples_bad
    mov eax, [rip + mp_samples]
    jmp .Lmpa_samples_return
.Lmpa_samples_bad:
    mov eax, -1
.Lmpa_samples_return:
    add rsp, 40
    ret
ENDFN mpa_track_samples

# Clears synthesis history and the reservoir before decoding from a seek
# point; pre-roll frames may then lack reservoir data.
FN mpa_track_reset
    push rdi
    lea rdi, [rip + mp_ist]
    xor eax, eax
    mov ecx, 80
    rep stosb
    lea rdi, [rip + mp_overlap]
    mov ecx, 576
    rep stosd
    lea rdi, [rip + mp_qmf]
    mov ecx, 960
    rep stosd
    mov dword ptr [rip + mp_reserv_size], 0
    mov dword ptr [rip + mp_frame_ready], 0
    mov dword ptr [rip + mp_frame_used], 0
    mov dword ptr [rip + mp_track_tolerant], 1
    pop rdi
    ret
ENDFN mpa_track_reset

# RCX=frame, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# or -1 on error.
FN mpa_track_decode
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    mov rdi, r8
    mov ebx, r9d
    mov [rip + mp_cursor], rcx
    lea rax, [rcx + rdx]
    mov [rip + mp_end], rax
    call mp_decode_frame
    test eax, eax
    jz .Lmpa_decode_bad
    mov ecx, [rip + mp_samples]
    cmp ecx, ebx
    ja .Lmpa_decode_bad
    mov eax, ecx
    lea rsi, [rip + mp_pcm]
    rep movsq
    mov dword ptr [rip + mp_frame_used], 0
    mov dword ptr [rip + mp_frame_ready], 0
    jmp .Lmpa_decode_return
.Lmpa_decode_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lmpa_decode_failed
    mov dword ptr [rip + decode_error], 15
.Lmpa_decode_failed:
    mov eax, -1
.Lmpa_decode_return:
    add rsp, 32
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mpa_track_decode

FN mp3_read
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
.Lmp_read_loop:
    cmp ebx, r12d
    jae .Lmp_read_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lmp_read_done
    mov rax, [rip + total_frames]
    test rax, rax
    jz .Lmp_read_available
    cmp [rip + mp_emitted], rax
    jae .Lmp_read_done
.Lmp_read_available:
    mov eax, [rip + mp_frame_used]
    cmp eax, [rip + mp_frame_ready]
    jb .Lmp_read_frame
    call mp_decode_frame
    test eax, eax
    jz .Lmp_read_done
.Lmp_read_frame:
    mov eax, [rip + mp_frame_used]
    cmp dword ptr [rip + mp_trim_start], 0
    je .Lmp_read_emit
    dec dword ptr [rip + mp_trim_start]
    inc dword ptr [rip + mp_frame_used]
    jmp .Lmp_read_loop
.Lmp_read_emit:
    lea rsi, [rip + mp_pcm]
    mov rdx, [rsi + rax*8]
    mov [rdi + rbx*8], rdx
    inc dword ptr [rip + mp_frame_used]
    inc qword ptr [rip + mp_emitted]
    inc ebx
    jmp .Lmp_read_loop
.Lmp_read_done:
    mov eax, ebx
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN mp3_read
