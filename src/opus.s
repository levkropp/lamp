# Original bounded Ogg/Opus families0/1 playback bridge. MIT, see LICENSE.
# RFC7845 header placement,48kHz granules,gain,pre-skip and end trimming.
# Connected codec algorithms retain BSD notices in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_mode_layout.inc"
.include "opus_stream_layout.inc"
.globl opus_index_count, opus_index_stride, opus_seek_headers, opus_seek_raw
.equ OB_INDEX_CAP, 2048
.equ OB_INDEX_POINT, 32
.equ OB_PREROLL, 3840
RODATA
ob_db_exp: .double 0.00064881407907956296 #log2(10)/(20*256)
# RFC7845 Figures4-9, exact coefficient formulae rounded to double.
# Family1 uses Vorbis speaker order. Mono duplicates; stereo passes through.
# Double coefficients/accumulators retain accuracy when large finite decoded
# channels cancel. Round to the stereo float ABI only after all streams mix.
# Each128-byte row contains eight pairs of left/right output weights.
ob_matrix:
    .double 1.00000000000000, 1.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #1 channels
    .double 1.00000000000000, 0.00000000000000, 0.00000000000000, 1.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #2 channels
    .double 0.585786437626905, 0.00000000000000, 0.414213562373095, 0.414213562373095, 0.00000000000000, 0.585786437626905, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #3 channels
    .double 0.422649730810374, 0.00000000000000, 0.00000000000000, 0.422649730810374, 0.366025403784439, 0.211324865405187, 0.211324865405187, 0.366025403784439, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #4 channels
    .double 0.650801813791450, 0.00000000000000, 0.460186375740439, 0.460186375740439, 0.00000000000000, 0.650801813791450, 0.563610903572386, 0.325400906895725, 0.325400906895725, 0.563610903572386, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #5 channels
    .double 0.529067082241344, 0.00000000000000, 0.374106921555435, 0.374106921555435, 0.00000000000000, 0.529067082241344, 0.458185533527114, 0.264533541120672, 0.264533541120672, 0.458185533527114, 0.374106921555435, 0.374106921555435, 0.00000000000000, 0.00000000000000, 0.00000000000000, 0.00000000000000 #6 channels
    .double 0.455310023362449, 0.00000000000000, 0.321952805061793, 0.321952805061793, 0.00000000000000, 0.455310023362449, 0.394310046829567, 0.227655011681225, 0.227655011681225, 0.394310046829567, 0.278819308003172, 0.278819308003172, 0.321952805061793, 0.321952805061793, 0.00000000000000, 0.00000000000000 #7 channels
    .double 0.388631414212121, 0.00000000000000, 0.274803908371509, 0.274803908371509, 0.00000000000000, 0.388631414212121, 0.336564677416370, 0.194315707106061, 0.194315707106061, 0.336564677416370, 0.336564677416370, 0.194315707106061, 0.194315707106061, 0.336564677416370, 0.274803908371509, 0.274803908371509 #8 channels
.data
ob_active: .long 0
ob_available: .long 0
ob_used: .long 0
ob_eof: .long 0
ob_gain: .float 1.0
ob_end_sample: .quad 0
ob_decoded: .quad 0
ob_index: .quad 0
ob_states: .quad 0
opus_index_count: .long 0
opus_index_stride: .quad 16
opus_seek_headers: .quad 0
opus_seek_raw: .quad 0
.bss
.p2align 4
ob_audio_checkpoint: .zero 2*8
ob_scan_checkpoint: .zero 2*8
ob_seek_checkpoint: .zero 2*8
ob_state: .zero MO_SIZE
ob_work: .zero MW_SIZE
ob_pcm: .zero 11520*4
ob_mix: .zero 11520*4
ob_mix_acc: .zero 11520*8
ob_coeff: .zero 1020*8 #255 streams * two channels * stereo weights
.text
FN opus_close
    sub rsp, 40
    mov rcx, [rip + ob_states]
    test rcx, rcx
    jz .Lob_close_index
    lea rax, [rip + ob_state]
    cmp rcx, rax
    je .Lob_close_states
    call mem_free
.Lob_close_states:
    mov qword ptr [rip + ob_states], 0
.Lob_close_index:
    mov rcx, [rip + ob_index]
    test rcx, rcx
    jz .Lob_close_reset
    call mem_free
    mov qword ptr [rip + ob_index], 0
.Lob_close_reset:
    mov dword ptr [rip + opus_index_count], 0
    mov qword ptr [rip + opus_seek_headers], 0
    mov qword ptr [rip + opus_seek_raw], 0
    mov dword ptr [rip + ob_active], 0
    mov dword ptr [rip + ob_available], 0
    mov dword ptr [rip + ob_used], 0
    mov dword ptr [rip + ob_eof], 0
    mov qword ptr [rip + ob_decoded], 0
    add rsp, 40
    ret
ENDFN opus_close

# RCX=mapped start,RDX=end. Complete structural/duration scan before output.
FN opus_open
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
    call opus_close
    mov rcx, rsi
    mov rdx, rdi
    call opus_headers
    test eax, eax
    jz .Lob_open_bad
    lea rcx, [rip + ob_audio_checkpoint]
    call ogg_checkpoint
    mov ecx, OB_INDEX_CAP*OB_INDEX_POINT
    call mem_alloc
    mov [rip + ob_index], rax       #allocation failure retains sequential decoding
    mov qword ptr [rip + opus_index_stride], 16
    xor ebx, ebx             #first completed audio page seen
    xor r12d, r12d           #raw samples in complete packets
    xor r13d, r13d           #initial granule offset
    xor r14d, r14d           #audio packet ordinal
.Lob_scan_packet:
    lea rcx, [rip + ob_scan_checkpoint]
    call ogg_checkpoint
    call ogg_next
    test rax, rax
    jz .Lob_open_bad          #EOS must belong to a completed audio packet
    mov rcx, rax
    call op_opus_multistream_parse
    test eax, eax
    jz .Lob_open_bad
    cmp qword ptr [rip + ob_index], 0
    je .Lob_scan_duration
    mov rax, [rip + opus_index_stride]
    dec rax
    test r14, rax
    jnz .Lob_scan_duration
    cmp dword ptr [rip + opus_index_count], OB_INDEX_CAP
    jb .Lob_scan_store
    mov r15d, 1
.Lob_scan_compact:
    mov rsi, r15
    shl rsi, 6
    add rsi, [rip + ob_index]
    mov rdi, r15
    shl rdi, 5
    add rdi, [rip + ob_index]
    mov ecx, 4
    rep movsq
    inc r15d
    cmp r15d, OB_INDEX_CAP/2
    jb .Lob_scan_compact
    mov dword ptr [rip + opus_index_count], OB_INDEX_CAP/2
    shl qword ptr [rip + opus_index_stride], 1
.Lob_scan_store:
    mov eax, [rip + opus_index_count]
    shl eax, 5
    add rax, [rip + ob_index]
    mov rcx, [rip + ob_scan_checkpoint]
    mov [rax], rcx
    mov rcx, [rip + ob_scan_checkpoint + 8]
    mov [rax + 8], rcx
    mov [rax + 16], r12
    mov [rax + 24], r14
    inc dword ptr [rip + opus_index_count]
.Lob_scan_duration:
    inc r14
    mov eax, [rip + op_packet_samples]
    add r12, rax
    jo .Lob_open_bad
    cmp dword ptr [rip + ogg_packet_last], 1
    jne .Lob_scan_packet
    mov rax, [rip + ogg_granule]
    test rax, rax
    js .Lob_open_bad
    test ebx, ebx
    jnz .Lob_scan_later_page
    inc ebx
    cmp rax, r12
    jae .Lob_scan_initial_offset
    cmp dword ptr [rip + ogg_eos], 1
    jne .Lob_open_bad
    jmp .Lob_scan_end         #single final page can trim below decoded count
.Lob_scan_initial_offset:
    mov r13, rax
    sub r13, r12
    jmp .Lob_scan_page_ready
.Lob_scan_later_page:
    mov rcx, r12
    add rcx, r13
    jo .Lob_open_bad
    cmp dword ptr [rip + ogg_eos], 1
    je .Lob_scan_final_page
    cmp rax, rcx
    jne .Lob_open_bad
    jmp .Lob_scan_packet
.Lob_scan_final_page:
    cmp rax, rcx
    ja .Lob_open_bad
.Lob_scan_page_ready:
    cmp dword ptr [rip + ogg_eos], 1
    jne .Lob_scan_packet
.Lob_scan_end:
    sub rax, r13
    jc .Lob_open_bad
    mov [rip + ob_end_sample], rax
    mov ecx, [rip + op_preskip]
    sub rax, rcx
    jc .Lob_open_bad
    mov [rip + total_frames], rax
    lea rcx, [rip + ob_audio_checkpoint]
    call ogg_resume
    test eax, eax
    jz .Lob_open_bad
    lea rax, [rip + ob_state]
    mov [rip + ob_states], rax
    cmp dword ptr [rip + op_streams], 1
    je .Lob_open_states
    mov ecx, [rip + op_streams]
    imul ecx, MO_SIZE
    call mem_alloc
    mov [rip + ob_states], rax
    test rax, rax
    jz .Lob_open_bad
.Lob_open_states:
    call ob_reset_states
    test eax, eax
    jz .Lob_open_bad
    call ob_make_mix
    cvtsi2sd xmm0, dword ptr [rip + op_gain]
    mulsd xmm0, qword ptr [rip + ob_db_exp]
    cvtsd2ss xmm0, xmm0
    call op_celt_exp2
    movss dword ptr [rip + ob_gain], xmm0
    mov dword ptr [rip + ob_active], 1
    mov eax, 1
    jmp .Lob_open_done
.Lob_open_bad:
    call opus_close
    mov dword ptr [rip + decode_error], 26
    mov qword ptr [rip + total_frames], 0
    xor eax, eax
.Lob_open_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN opus_open

# Fresh stream only. Restore a packet boundary at least80ms before the target,
# reset codec history, and return its PCM position for worker decode/discard.
# Skim fewer than one index stride of packet headers to minimize pre-roll.
# Near the beginning, retain ordinary pre-skip and decode from raw sample0.
FN opus_seek
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    xor eax, eax
    mov qword ptr [rip + opus_seek_headers], 0
    mov qword ptr [rip + opus_seek_raw], 0
    cmp dword ptr [rip + ob_active], 1
    jne .Lob_seek_return
    cmp dword ptr [rip + opus_index_count], 0
    je .Lob_seek_return
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lob_seek_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lob_seek_zero
.Lob_seek_not_cancelled:
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    cmp rcx, OB_PREROLL
    jb .Lob_seek_zero
    mov eax, [rip + op_preskip]
    add rcx, rax
    sub rcx, OB_PREROLL
    mov rsi, rcx             #latest permissible raw starting sample
    xor r8d, r8d
    mov r9d, [rip + opus_index_count]
.Lob_seek_search:
    cmp r8d, r9d
    jae .Lob_seek_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    mov eax, edx
    shl eax, 5
    add rax, [rip + ob_index]
    cmp [rax + 16], rsi
    ja .Lob_seek_upper
    lea r8d, [rdx + 1]
    jmp .Lob_seek_search
.Lob_seek_upper:
    mov r9d, edx
    jmp .Lob_seek_search
.Lob_seek_found:
    dec r8d                #point0 is raw0, so a preceding point always exists
    mov eax, r8d
    shl eax, 5
    add rax, [rip + ob_index]
    mov rbx, [rax + 16]
    mov rcx, [rax]
    mov [rip + ob_seek_checkpoint], rcx
    mov rcx, [rax + 8]
    mov [rip + ob_seek_checkpoint + 8], rcx
    lea rcx, [rip + ob_seek_checkpoint]
    call ogg_resume
    test eax, eax
    jz .Lob_seek_bad
.Lob_seek_skim:
    lea rcx, [rip + ob_scan_checkpoint]
    call ogg_checkpoint
    call ogg_next
    test rax, rax
    jz .Lob_seek_bad
    mov rcx, rax
    call op_opus_multistream_parse
    test eax, eax
    jz .Lob_seek_bad
    mov eax, [rip + op_packet_samples]
    add rax, rbx
    cmp rax, rsi
    ja .Lob_seek_ready
    mov rbx, rax
    inc qword ptr [rip + opus_seek_headers]
    jmp .Lob_seek_skim
.Lob_seek_ready:
    lea rcx, [rip + ob_scan_checkpoint]
    call ogg_resume         #rewind the first packet which crosses pre-roll
    test eax, eax
    jz .Lob_seek_bad
    call ob_reset_states
    test eax, eax
    jz .Lob_seek_bad
    mov dword ptr [rip + ob_available], 0
    mov dword ptr [rip + ob_used], 0
    mov dword ptr [rip + ob_eof], 0
    mov [rip + ob_decoded], rbx
    mov [rip + opus_seek_raw], rbx
    mov eax, [rip + op_preskip]
    cmp rbx, rax
    jb .Lob_seek_zero
    mov rax, rbx
    mov ecx, [rip + op_preskip]    #return raw sample minus original pre-skip
    sub rax, rcx
    jmp .Lob_seek_return
.Lob_seek_bad:
    mov dword ptr [rip + decode_error], 28
    mov dword ptr [rip + ob_active], 0
.Lob_seek_zero:
    xor eax, eax
.Lob_seek_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN opus_seek

# RCX=caller stereo float buffer,EDX=frame capacity. 0=EOF/error.
# No per-packet allocation. Decode every packet, including fully trimmed ones.
FN opus_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 96
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    test rdi, rdi
    jz .Lob_read_done
    test r12d, r12d
    jz .Lob_read_done
    cmp dword ptr [rip + ob_active], 1
    jne .Lob_read_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lob_read_done
.Lob_read_loop:
    cmp ebx, r12d
    jae .Lob_read_done
    mov eax, [rip + ob_used]
    cmp eax, [rip + ob_available]
    jb .Lob_emit
    cmp dword ptr [rip + ob_eof], 1
    je .Lob_read_done
    call ogg_next
    test rax, rax
    jz .Lob_read_bad
    cmp dword ptr [rip + op_mapping], 1
    jne .Lob_read_family0
    mov rcx, rax
    call ob_decode_multi
    jmp .Lob_read_decoded
.Lob_read_family0:
    mov [rsp + 32 + PK_DATA], rax
    mov [rsp + 32 + PK_LEN], edx
    mov rax, [rip + ob_states]
    mov [rsp + 32 + PK_STATE], rax
    lea rax, [rip + ob_work]
    mov [rsp + 32 + PK_WORK], rax
    lea rax, [rip + ob_pcm]
    mov [rsp + 32 + PK_PCM], rax
    mov dword ptr [rsp + 32 + PK_COUNT], 0
    mov dword ptr [rsp + 32 + PK_FEC], 0
    mov dword ptr [rsp + 32 + PK_STATE_CAP], MO_SIZE
    mov dword ptr [rsp + 32 + PK_WORK_CAP], MW_SIZE
    mov dword ptr [rsp + 32 + PK_PCM_CAP], 11520
    lea rcx, [rsp + 32]
    call op_opus_decode_packet
.Lob_read_decoded:
    test eax, eax
    jle .Lob_read_bad
    mov r13d, eax
    mov rsi, [rip + ob_decoded]   #raw start of this packet,without origin offset
    add [rip + ob_decoded], rax
    mov [rip + ob_available], eax
    mov dword ptr [rip + ob_used], 0
    mov eax, [rip + op_preskip]
    cmp rsi, rax
    jae .Lob_packet_trim
    sub rax, rsi
    cmp eax, r13d
    cmova eax, r13d
    mov [rip + ob_used], eax
.Lob_packet_trim:
    mov rax, [rip + ob_end_sample]
    cmp rax, rsi
    ja .Lob_packet_keep
    xor eax, eax
    jmp .Lob_packet_available
.Lob_packet_keep:
    sub rax, rsi
    cmp rax, r13
    cmova rax, r13
.Lob_packet_available:
    mov [rip + ob_available], eax
    cmp [rip + ob_used], eax
    jbe .Lob_packet_end
    mov [rip + ob_used], eax
.Lob_packet_end:
    mov eax, [rip + ogg_eos]
    mov [rip + ob_eof], eax
    jmp .Lob_read_loop
.Lob_emit:
    lea rsi, [rip + ob_pcm]
    cmp dword ptr [rip + op_mapping], 1
    jne .Lob_emit_family0
    lea rsi, [rip + ob_mix]
    jmp .Lob_emit_stereo
.Lob_emit_family0:
    cmp dword ptr [rip + source_channels], 1
    je .Lob_emit_mono
.Lob_emit_stereo:
    movq xmm0, qword ptr [rsi + rax*8]
    movss xmm1, dword ptr [rip + ob_gain]
    shufps xmm1, xmm1, 0
    mulps xmm0, xmm1
    movq qword ptr [rdi + rbx*8], xmm0
    jmp .Lob_emit_next
.Lob_emit_mono:
    movss xmm0, dword ptr [rsi + rax*4]
    mulss xmm0, dword ptr [rip + ob_gain]
    unpcklps xmm0, xmm0
    movq qword ptr [rdi + rbx*8], xmm0
.Lob_emit_next:
    inc dword ptr [rip + ob_used]
    inc ebx
    jmp .Lob_read_loop
.Lob_read_bad:
    mov dword ptr [rip + decode_error], 27
    mov dword ptr [rip + ob_active], 0
    xor ebx, ebx           #caller discards partial output on error
.Lob_read_done:
    mov eax, ebx
    add rsp, 96
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN opus_read

# Track mode for Matroska/MP4 packets. The container supplies OpusHead and
# whole packets; the track layer applies pre-skip, end trimming and seeking.
# RCX=OpusHead, EDX=bytes -> EAX=1.
FN opus_track_open
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov esi, edx
    call opus_close
    mov rcx, rbx
    mov edx, esi
    call opus_head_parse
    test eax, eax
    jz .Lob_track_bad
    lea rax, [rip + ob_state]
    mov [rip + ob_states], rax
    cmp dword ptr [rip + op_streams], 1
    je .Lob_track_states
    mov ecx, [rip + op_streams]
    imul ecx, MO_SIZE
    call mem_alloc
    mov [rip + ob_states], rax
    test rax, rax
    jz .Lob_track_bad
.Lob_track_states:
    call ob_reset_states
    test eax, eax
    jz .Lob_track_bad
    call ob_make_mix
    cvtsi2sd xmm0, dword ptr [rip + op_gain]
    mulsd xmm0, qword ptr [rip + ob_db_exp]
    cvtsd2ss xmm0, xmm0
    call op_celt_exp2
    movss dword ptr [rip + ob_gain], xmm0
    mov dword ptr [rip + ob_active], 1
    mov eax, 1
    jmp .Lob_track_return
.Lob_track_bad:
    call opus_close
    mov dword ptr [rip + decode_error], 26
    xor eax, eax
.Lob_track_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN opus_track_open

# RCX=packet, EDX=bytes -> EAX=48 kHz samples, or 0 when malformed.
FN opus_track_samples
    sub rsp, 40
    call op_opus_multistream_parse
    test eax, eax
    jz .Lob_track_samples_done
    mov eax, [rip + op_packet_samples]
.Lob_track_samples_done:
    add rsp, 40
    ret
ENDFN opus_track_samples

# Clears decoder history before decoding from a seek point.
FN opus_track_reset
    sub rsp, 40
    call ob_reset_states
    add rsp, 40
    ret
ENDFN opus_track_reset

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# 0 on error. Header gain is applied; mono is duplicated.
FN opus_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 96
    mov rdi, r8
    mov r12d, r9d
    cmp dword ptr [rip + ob_active], 1
    jne .Lob_track_decode_bad
    cmp dword ptr [rip + op_mapping], 1
    jne .Lob_track_family0
    call ob_decode_multi
    jmp .Lob_track_decoded
.Lob_track_family0:
    mov [rsp + 32 + PK_DATA], rcx
    mov [rsp + 32 + PK_LEN], edx
    mov rax, [rip + ob_states]
    mov [rsp + 32 + PK_STATE], rax
    lea rax, [rip + ob_work]
    mov [rsp + 32 + PK_WORK], rax
    lea rax, [rip + ob_pcm]
    mov [rsp + 32 + PK_PCM], rax
    mov dword ptr [rsp + 32 + PK_COUNT], 0
    mov dword ptr [rsp + 32 + PK_FEC], 0
    mov dword ptr [rsp + 32 + PK_STATE_CAP], MO_SIZE
    mov dword ptr [rsp + 32 + PK_WORK_CAP], MW_SIZE
    mov dword ptr [rsp + 32 + PK_PCM_CAP], 11520
    lea rcx, [rsp + 32]
    call op_opus_decode_packet
.Lob_track_decoded:
    test eax, eax
    jle .Lob_track_decode_bad
    cmp eax, r12d
    ja .Lob_track_decode_bad
    mov r13d, eax
    lea rsi, [rip + ob_pcm]
    cmp dword ptr [rip + op_mapping], 1
    jne .Lob_track_family0_emit
    lea rsi, [rip + ob_mix]
    jmp .Lob_track_stereo
.Lob_track_family0_emit:
    cmp dword ptr [rip + source_channels], 1
    je .Lob_track_mono
.Lob_track_stereo:
    movss xmm1, dword ptr [rip + ob_gain]
    shufps xmm1, xmm1, 0
    xor ebx, ebx
.Lob_track_stereo_frame:
    movq xmm0, qword ptr [rsi + rbx*8]
    mulps xmm0, xmm1
    movq qword ptr [rdi + rbx*8], xmm0
    inc ebx
    cmp ebx, r13d
    jb .Lob_track_stereo_frame
    jmp .Lob_track_decode_done
.Lob_track_mono:
    xor ebx, ebx
.Lob_track_mono_frame:
    movss xmm0, dword ptr [rsi + rbx*4]
    mulss xmm0, dword ptr [rip + ob_gain]
    unpcklps xmm0, xmm0
    movq qword ptr [rdi + rbx*8], xmm0
    inc ebx
    cmp ebx, r13d
    jb .Lob_track_mono_frame
.Lob_track_decode_done:
    mov eax, r13d
    jmp .Lob_track_decode_return
.Lob_track_decode_bad:
    mov dword ptr [rip + decode_error], 27
    xor eax, eax
.Lob_track_decode_return:
    add rsp, 96
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN opus_track_decode

# Reset every separately owned mono/stereo history; share only scratch space.
LOCALFN ob_reset_states
    push rbx
    push rsi
    sub rsp, 56
    mov rsi, [rip + ob_states]
    test rsi, rsi
    jz .Lob_reset_bad
    xor ebx, ebx
.Lob_reset_stream:
    mov [rsp + 32 + MI_STATE], rsi
    mov dword ptr [rsp + 32 + MI_FS], 48000
    xor eax, eax
    cmp ebx, [rip + op_coupled]
    setb al
    inc eax
    mov [rsp + 32 + MI_CHANNELS], eax
    mov dword ptr [rsp + 32 + MI_CAP], MO_SIZE
    lea rcx, [rsp + 32]
    call op_opus_decoder_init
    test eax, eax
    jz .Lob_reset_bad
    add rsi, MO_SIZE
    inc ebx
    cmp ebx, [rip + op_streams]
    jb .Lob_reset_stream
    mov eax, 1
    jmp .Lob_reset_done
.Lob_reset_bad:
    xor eax, eax
.Lob_reset_done:
    add rsp, 56
    pop rsi
    pop rbx
    ret
ENDFN ob_reset_states

# Compose the channel map and downmix once at open, including repeated mapped
# channels and255 (silence). Coefficients for unmapped streams remain zero.
LOCALFN ob_make_mix
    push rsi
    push rdi
    lea rdi, [rip + ob_coeff]
    xor eax, eax
    mov ecx, 2040
    rep stosd
    mov eax, [rip + source_channels]
    dec eax
    shl eax, 7
    lea rsi, [rip + ob_matrix]
    add rsi, rax
    lea rdi, [rip + ob_coeff]
    lea r9, [rip + op_channel_map]
    mov r10d, [rip + op_coupled]
    shl r10d, 1
    xor ecx, ecx
.Lob_mix_channel:
    movzx eax, byte ptr [r9 + rcx]
    cmp eax, 255
    je .Lob_mix_next
    cmp eax, r10d
    jae .Lob_mix_uncoupled
    shl eax, 4
    jmp .Lob_mix_weight
.Lob_mix_uncoupled:
    sub eax, [rip + op_coupled]
    shl eax, 5
.Lob_mix_weight:
    mov rdx, rcx
    shl rdx, 4
    movupd xmm0, xmmword ptr [rsi + rdx]
    movupd xmm1, xmmword ptr [rdi + rax]
    addpd xmm0, xmm1
    movupd xmmword ptr [rdi + rax], xmm0
.Lob_mix_next:
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lob_mix_channel
    pop rdi
    pop rsi
    ret
ENDFN ob_make_mix

# RCX=packed Ogg payload,EDX=length -> EAX=stereo frames or0 on failure.
# No packet allocation; decode even unmapped streams to validate their entropy
# and maintain history. Cancellation is checked between elementary streams.
LOCALFN ob_decode_multi
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov rsi, rcx
    mov [rsp + 88], edx
    lea rdi, [rip + ob_mix_acc]
    xor eax, eax
    mov ecx, 11520
    rep stosq
    mov edi, [rsp + 88]
    mov r12, [rip + ob_states]
    lea r14, [rip + ob_coeff]
    xor ebx, ebx
    xor r13d, r13d
.Lob_decode_stream:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lob_decode_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lob_decode_bad
.Lob_decode_not_cancelled:
    mov [rsp + 32 + PK_STATE], r12
    mov [rsp + 32 + PK_DATA], rsi
    lea rax, [rip + ob_pcm]
    mov [rsp + 32 + PK_PCM], rax
    lea rax, [rip + ob_work]
    mov [rsp + 32 + PK_WORK], rax
    mov [rsp + 32 + PK_LEN], edi
    mov dword ptr [rsp + 32 + PK_COUNT], 0
    mov dword ptr [rsp + 32 + PK_FEC], 0
    mov dword ptr [rsp + 32 + PK_STATE_CAP], MO_SIZE
    mov dword ptr [rsp + 32 + PK_WORK_CAP], MW_SIZE
    mov dword ptr [rsp + 32 + PK_PCM_CAP], 11520
    lea eax, [rbx + 1]
    xor edx, edx
    cmp eax, [rip + op_streams]
    setb dl
    lea rcx, [rsp + 32]
    call op_opus_decode_packet_ex
    test eax, eax
    jle .Lob_decode_bad
    test ebx, ebx
    jz .Lob_decode_duration
    cmp eax, r13d
    jne .Lob_decode_bad
.Lob_decode_duration:
    mov r13d, eax
    mov eax, [rip + op_packet_bytes]
    test eax, eax
    jz .Lob_decode_bad
    cmp eax, edi
    ja .Lob_decode_bad
    add rsi, rax
    sub edi, eax
    lea rdx, [rip + ob_pcm]
    lea r15, [rip + ob_mix_acc]
    movupd xmm4, xmmword ptr [r14]
    movupd xmm5, xmmword ptr [r14 + 16]
    xor ecx, ecx
.Lob_decode_mix:
    movss xmm0, dword ptr [rdx]
    cvtss2sd xmm0, xmm0
    unpcklpd xmm0, xmm0
    mulpd xmm0, xmm4
    add rdx, 4
    cmp dword ptr [r12 + MO_CHANNELS], 2
    jne .Lob_decode_accumulate
    movss xmm1, dword ptr [rdx]
    cvtss2sd xmm1, xmm1
    unpcklpd xmm1, xmm1
    mulpd xmm1, xmm5
    addpd xmm0, xmm1
    add rdx, 4
.Lob_decode_accumulate:
    movupd xmm2, xmmword ptr [r15]
    addpd xmm0, xmm2
    movupd xmmword ptr [r15], xmm0
    add r15, 16
    inc ecx
    cmp ecx, r13d
    jb .Lob_decode_mix
    add r12, MO_SIZE
    add r14, 32
    inc ebx
    cmp ebx, [rip + op_streams]
    jb .Lob_decode_stream
    test edi, edi
    jnz .Lob_decode_bad
    lea rsi, [rip + ob_mix_acc]
    lea rdi, [rip + ob_mix]
    mov ecx, r13d
.Lob_decode_round:
    movupd xmm0, xmmword ptr [rsi]
    cvtpd2ps xmm0, xmm0
    movq qword ptr [rdi], xmm0
    add rsi, 16
    add rdi, 8
    dec ecx
    jnz .Lob_decode_round
    mov eax, r13d
    jmp .Lob_decode_done
.Lob_decode_bad:
    xor eax, eax
.Lob_decode_done:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ob_decode_multi
