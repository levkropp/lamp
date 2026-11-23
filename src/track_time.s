# Original timestamped PCM presentation map. MIT, see LICENSE.
# Coded samples and codec history remain in track.s; this layer maps its
# trimmed PCM into media time, inserting silence and discarding overlaps.
.include "lamp.inc"
.equ TT_EVENT_CAP, 1 << 24
.equ TT_SPAN_CAP, 1 << 24
.equ TT_COMMIT, 65536
.globl track_time_enabled, track_time_active, track_time_source_frames
.globl track_time_scale_ns, track_time_track_scale
.globl track_time_event_count, track_time_span_count
.data
track_time_enabled: .long 0
track_time_active: .long 0
track_time_source_frames: .quad 0
track_time_scale_ns: .quad 1000000
track_time_track_scale: .double 1.0
track_time_event_count: .long 0
track_time_span_count: .long 0
tt_events: .quad 0
tt_event_committed: .quad 0
tt_spans: .quad 0
tt_span_committed: .quad 0
tt_last_ns: .quad 0
tt_position: .quad 0
tt_source_position: .quad 0
tt_span_index: .long 0
tt_ready: .long 0
tt_drained: .long 0
RODATA
tt_one: .double 1.0
tt_half: .double 0.5
tt_i64_limit: .double 9223372036854775808.0
.bss
.p2align 4
tt_scratch: .zero 32768
.text
FN track_time_close
    sub rsp, 40
    mov rcx, [rip+tt_events]
    test rcx, rcx
    jz .Ltt_close_spans
    call mem_free
.Ltt_close_spans:
    mov rcx, [rip+tt_spans]
    test rcx, rcx
    jz .Ltt_close_clear
    call mem_free
.Ltt_close_clear:
    mov qword ptr [rip+tt_events], 0
    mov qword ptr [rip+tt_event_committed], 0
    mov qword ptr [rip+tt_spans], 0
    mov qword ptr [rip+tt_span_committed], 0
    mov qword ptr [rip+track_time_source_frames], 0
    mov dword ptr [rip+track_time_event_count], 0
    mov dword ptr [rip+track_time_span_count], 0
    mov dword ptr [rip+track_time_enabled], 0
    mov dword ptr [rip+track_time_active], 0
    mov qword ptr [rip+track_time_scale_ns], 1000000
    mov rax, 0x3ff0000000000000
    mov [rip+track_time_track_scale], rax
    mov qword ptr [rip+tt_last_ns], 0
    mov qword ptr [rip+tt_position], 0
    mov qword ptr [rip+tt_source_position], 0
    mov dword ptr [rip+tt_span_index], 0
    mov dword ptr [rip+tt_ready], 0
    mov dword ptr [rip+tt_drained], 0
    add rsp, 40
    ret
ENDFN track_time_close

# RCX=raw sample boundary, RDX=signed sample offset ->1/0.
# Events are sorted; the latest event at an equal boundary replaces it.
FN track_time_event
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    cmp dword ptr [rip+tt_ready], 0
    jne .Ltt_event_bad
    mov eax, [rip+track_time_event_count]
    cmp eax, TT_EVENT_CAP
    jae .Ltt_event_bad
    test eax, eax
    jz .Ltt_event_reserve
    dec eax
    shl rax, 4
    add rax, [rip+tt_events]
    cmp rbx, [rax]
    jb .Ltt_event_bad
    je .Ltt_event_replace
    cmp rsi, [rax+8]
    je .Ltt_event_ok
.Ltt_event_reserve:
    cmp qword ptr [rip+tt_events], 0
    jne .Ltt_event_commit
    mov ecx, TT_EVENT_CAP*16
    call mem_reserve
    test rax, rax
    jz .Ltt_event_bad
    mov [rip+tt_events], rax
.Ltt_event_commit:
    mov eax, [rip+track_time_event_count]
    inc eax
    shl rax, 4
    cmp rax, [rip+tt_event_committed]
    jbe .Ltt_event_store
    mov rcx, [rip+tt_events]
    add rcx, [rip+tt_event_committed]
    mov edx, TT_COMMIT
    call mem_commit
    test rax, rax
    jz .Ltt_event_bad
    add qword ptr [rip+tt_event_committed], TT_COMMIT
.Ltt_event_store:
    mov eax, [rip+track_time_event_count]
    shl rax, 4
    add rax, [rip+tt_events]
    mov [rax], rbx
    inc dword ptr [rip+track_time_event_count]
.Ltt_event_replace:
    mov [rax+8], rsi
.Ltt_event_ok:
    mov eax, 1
    jmp .Ltt_event_return
.Ltt_event_bad:
    xor eax, eax
.Ltt_event_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN track_time_event

# RCX=raw start, RDX=Cluster Timestamp, R8D=signed relative Track Ticks.
# Resolve RFC9559's formula after all Info/Track metadata is available.
# Nanosecond intermediates must fit signed 64-bit; scale must be positive.
# Ignore sub-tick clock quantization, without ignoring sample-sized gaps
# when the container uses a fine timestamp scale.
FN track_time_anchor
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    mov rax, [rip+track_time_scale_ns]
    test rax, rax
    jle .Ltt_anchor_bad
    mov [rsp+48], rax
    movsd xmm0, [rip+track_time_track_scale]
    ucomisd xmm0, [rip+tt_one]
    jbe .Ltt_anchor_quantum_ready
    cvtsi2sd xmm1, rax
    mulsd xmm0, xmm1
    ucomisd xmm0, [rip+tt_i64_limit]
    jae .Ltt_anchor_bad
    cvttsd2si r9, xmm0
    cvtsi2sd xmm1, r9
    ucomisd xmm1, xmm0
    jae .Ltt_anchor_quantum_store
    inc r9
.Ltt_anchor_quantum_store:
    mov [rsp+48], r9
.Ltt_anchor_quantum_ready:
    mov rdx, 0x3ff0000000000000
    cmp [rip+track_time_track_scale], rdx
    jne .Ltt_anchor_scaled
    # Exact integer path, including unsigned Cluster values close to 2^63.
    movsxd rcx, edi
    test rcx, rcx
    js .Ltt_anchor_negative_tick
    mov rdx, 0x7fffffffffffffff
    sub rdx, rcx
    cmp rsi, rdx
    ja .Ltt_anchor_bad
    add rsi, rcx
    jmp .Ltt_anchor_integer_ns
.Ltt_anchor_negative_tick:
    neg rcx
    sub rsi, rcx
    jnc .Ltt_anchor_nonnegative_tick
    # A small negative timestamp before media time zero.
    mov rdx, rsi
    neg rdx
    mov rsi, rdx
    mov dword ptr [rsp+32], 1
    jmp .Ltt_anchor_multiply
.Ltt_anchor_nonnegative_tick:
    test rsi, rsi
    js .Ltt_anchor_bad
.Ltt_anchor_integer_ns:
    mov dword ptr [rsp+32], 0
.Ltt_anchor_multiply:
    mul rsi
    test rdx, rdx
    jnz .Ltt_anchor_bad
    test rax, rax
    js .Ltt_anchor_bad
    cmp dword ptr [rsp+32], 0
    je .Ltt_anchor_ns_ready
    neg rax
    jmp .Ltt_anchor_ns_ready
.Ltt_anchor_scaled:
    # Only the relative Track Tick portion uses the legacy float scale.
    # Its nearest nanosecond is added to the exact Cluster nanoseconds.
    cvtsi2sd xmm0, edi
    mulsd xmm0, [rip+track_time_track_scale]
    cvtsi2sd xmm1, rax
    mulsd xmm0, xmm1
    xorpd xmm2, xmm2
    ucomisd xmm0, xmm2
    jp .Ltt_anchor_bad
    jb .Ltt_anchor_scaled_negative
    addsd xmm0, [rip+tt_half]
    ucomisd xmm0, [rip+tt_i64_limit]
    jae .Ltt_anchor_bad
    cvttsd2si rdi, xmm0
    jmp .Ltt_anchor_cluster_ns
.Ltt_anchor_scaled_negative:
    subsd xmm2, xmm0
    addsd xmm2, [rip+tt_half]
    ucomisd xmm2, [rip+tt_i64_limit]
    jae .Ltt_anchor_bad
    cvttsd2si rdi, xmm2
    neg rdi
.Ltt_anchor_cluster_ns:
    mul rsi
    test rdx, rdx
    jnz .Ltt_anchor_bad
    test rax, rax
    js .Ltt_anchor_bad
    add rax, rdi
    jo .Ltt_anchor_bad
.Ltt_anchor_ns_ready:
    mov [rsp+40], rax                    # actual PTS, before codec delay
    # Expected continuous coded time at this sample (nearest nanosecond).
    mov rax, rbx
    mov ecx, 1000000000
    mul rcx
    mov ecx, [rip+sample_rate]
    test ecx, ecx
    jz .Ltt_anchor_bad
    mov r8d, ecx
    shr r8d, 1
    add rax, r8
    adc rdx, 0
    cmp rdx, rcx
    jae .Ltt_anchor_bad
    div rcx
    test rax, rax
    js .Ltt_anchor_bad
    mov rdi, [rsp+40]
    sub rdi, rax                        # signed nanosecond offset
    jo .Ltt_anchor_bad
    mov rax, rdi
    sub rax, [rip+tt_last_ns]
    jo .Ltt_anchor_changed
    test rax, rax
    jns .Ltt_anchor_difference
    neg rax
.Ltt_anchor_difference:
    cmp rax, [rsp+48]
    jbe .Ltt_anchor_ok
.Ltt_anchor_changed:
    # Absolute PTS -> nearest signed sample, then offset from coded start.
    mov rax, [rsp+40]
    mov rsi, rax
    test rax, rax
    jns .Ltt_anchor_sample_multiply
    neg rax
.Ltt_anchor_sample_multiply:
    mov ecx, [rip+sample_rate]
    mul rcx
    add rax, 500000000
    adc rdx, 0
    mov ecx, 1000000000
    cmp rdx, rcx
    jae .Ltt_anchor_bad
    div rcx
    test rax, rax
    js .Ltt_anchor_bad
    test rsi, rsi
    jns .Ltt_anchor_sample_ready
    neg rax
.Ltt_anchor_sample_ready:
    sub rax, rbx
    jo .Ltt_anchor_bad
    mov rcx, rbx
    mov rdx, rax
    call track_time_event
    test eax, eax
    jz .Ltt_anchor_bad
    mov [rip+tt_last_ns], rdi
.Ltt_anchor_ok:
    mov eax, 1
    jmp .Ltt_anchor_return
.Ltt_anchor_bad:
    xor eax, eax
.Ltt_anchor_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_time_anchor

# RCX=source start, RDX=source end, R8=media start, R9=media end ->1/0.
# Adjacent source/media intervals merge. Source and destination lengths agree.
LOCALFN tt_span_add
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    mov eax, [rip+track_time_span_count]
    cmp eax, TT_SPAN_CAP
    jae .Ltt_span_bad
    test eax, eax
    jz .Ltt_span_reserve
    dec eax
    shl rax, 5
    add rax, [rip+tt_spans]
    cmp rbx, [rax+8]
    jne .Ltt_span_reserve
    cmp rdi, [rax+24]
    jne .Ltt_span_reserve
    mov [rax+8], rsi
    mov [rax+24], r12
    jmp .Ltt_span_ok
.Ltt_span_reserve:
    cmp dword ptr [rip+track_time_span_count], TT_SPAN_CAP
    jae .Ltt_span_bad
    cmp qword ptr [rip+tt_spans], 0
    jne .Ltt_span_commit
    mov ecx, TT_SPAN_CAP*32
    call mem_reserve
    test rax, rax
    jz .Ltt_span_bad
    mov [rip+tt_spans], rax
.Ltt_span_commit:
    mov eax, [rip+track_time_span_count]
    inc eax
    shl rax, 5
    cmp rax, [rip+tt_span_committed]
    jbe .Ltt_span_store
    mov rcx, [rip+tt_spans]
    add rcx, [rip+tt_span_committed]
    mov edx, TT_COMMIT
    call mem_commit
    test rax, rax
    jz .Ltt_span_bad
    add qword ptr [rip+tt_span_committed], TT_COMMIT
.Ltt_span_store:
    mov eax, [rip+track_time_span_count]
    shl rax, 5
    add rax, [rip+tt_spans]
    mov [rax], rbx
    mov [rax+8], rsi
    mov [rax+16], rdi
    mov [rax+24], r12
    inc dword ptr [rip+track_time_span_count]
.Ltt_span_ok:
    mov eax, 1
    jmp .Ltt_span_return
.Ltt_span_bad:
    xor eax, eax
.Ltt_span_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN tt_span_add

# RCX=raw total after track/cut duration scanning ->1/0.
# Sweep raw clock changes and already-resolved removals into media spans.
FN track_time_finish
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    cmp dword ptr [rip+tt_ready], 0
    jne .Ltt_finish_bad
    mov dword ptr [rip+tt_ready], 2
    cmp dword ptr [rip+track_time_enabled], 0
    je .Ltt_finish_identity
    mov r12, rcx
    sub r12, [rip+track_end_trim]
    jc .Ltt_finish_bad
    test r12, r12
    js .Ltt_finish_bad
    mov rbx, [rip+track_start_trim]       # raw cursor
    cmp rbx, r12
    ja .Ltt_finish_bad
    xor esi, esi                       # event index
    xor edi, edi                       # cut index
    xor r13d, r13d                     # signed clock offset
    xor r14d, r14d                     # source PCM position
    xor r15d, r15d                     # media end
.Ltt_finish_loop:
    cmp rbx, r12
    jae .Ltt_finish_done
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Ltt_finish_events
    cmp dword ptr [rax], 0
    jne .Ltt_finish_bad
.Ltt_finish_events:
    cmp esi, [rip+track_time_event_count]
    jae .Ltt_finish_cut
    mov eax, esi
    shl rax, 4
    add rax, [rip+tt_events]
    cmp [rax], rbx
    ja .Ltt_finish_cut
    mov r13, [rax+8]
    inc esi
    jmp .Ltt_finish_events
.Ltt_finish_cut:
    mov ecx, edi
    call track_cut_at
    mov [rsp+32], rax                   # next cut start
    mov [rsp+40], rdx                   # next cut end
    cmp rax, -1
    je .Ltt_finish_boundary
    cmp rdx, rbx
    jbe .Ltt_finish_next_cut
    cmp rax, rbx
    ja .Ltt_finish_boundary
    mov rbx, rdx                       # no source output in a cut
    jmp .Ltt_finish_loop
.Ltt_finish_next_cut:
    inc edi
    jmp .Ltt_finish_cut
.Ltt_finish_boundary:
    mov rax, r12
    cmp esi, [rip+track_time_event_count]
    jae .Ltt_finish_cut_boundary
    mov ecx, esi
    shl rcx, 4
    add rcx, [rip+tt_events]
    cmp rax, [rcx]
    cmova rax, [rcx]
.Ltt_finish_cut_boundary:
    cmp rax, [rsp+32]
    cmova rax, [rsp+32]
    cmp rax, rbx
    jbe .Ltt_finish_bad
    mov [rsp+48], rax                   # next raw boundary
    sub rax, rbx
    mov [rsp+56], rax                   # original source length
    mov rdx, r14
    add rdx, rax                       # source end before clipping
    jc .Ltt_finish_bad
    mov [rsp+64], rdx
    mov rcx, r14                       # source start
    mov r8, rbx
    sub r8, [rip+track_start_trim]
    add r8, r13                        # requested media start
    jo .Ltt_finish_bad
    test r8, r8
    jns .Ltt_finish_overlap
    neg r8                             # unsigned negative prefix length
    cmp r8, rax
    cmova r8, rax
    add rcx, r8
    sub rax, r8
    xor r8d, r8d
.Ltt_finish_overlap:
    cmp r8, r15
    jae .Ltt_finish_append
    mov r9, r15
    sub r9, r8
    cmp r9, rax
    cmova r9, rax
    add rcx, r9
    sub rax, r9
    mov r8, r15
.Ltt_finish_append:
    test rax, rax
    jz .Ltt_finish_advance
    lea rdx, [rcx+rax]
    mov r9, r8
    add r9, rax
    jo .Ltt_finish_bad
    mov [rsp+72], r9
    call tt_span_add
    test eax, eax
    jz .Ltt_finish_bad
    mov r15, [rsp+72]
.Ltt_finish_advance:
    mov r14, [rsp+64]
    mov rbx, [rsp+48]
    jmp .Ltt_finish_loop
.Ltt_finish_done:
    cmp r14, [rip+total_frames]
    jne .Ltt_finish_bad
    mov [rip+track_time_source_frames], r14
    cmp r15, r14
    jne .Ltt_finish_mapped
    cmp dword ptr [rip+track_time_span_count], 0
    je .Ltt_finish_identity
    cmp dword ptr [rip+track_time_span_count], 1
    jne .Ltt_finish_mapped
    mov rax, [rip+tt_spans]
    cmp qword ptr [rax], 0
    jne .Ltt_finish_mapped
    cmp qword ptr [rax+16], 0
    jne .Ltt_finish_mapped
    cmp r14, [rax+8]
    jne .Ltt_finish_mapped
    cmp r14, [rax+24]
    je .Ltt_finish_identity
.Ltt_finish_mapped:
    mov [rip+total_frames], r15
    mov dword ptr [rip+track_time_active], 1
    mov rcx, [rip+tt_events]
    test rcx, rcx
    jz .Ltt_finish_ready
    call mem_free
    mov qword ptr [rip+tt_events], 0
    mov qword ptr [rip+tt_event_committed], 0
    mov dword ptr [rip+track_time_event_count], 0
    jmp .Ltt_finish_ready
.Ltt_finish_identity:
    call track_time_close               # ordinary files retain no extra map
.Ltt_finish_ready:
    mov dword ptr [rip+tt_ready], 1
    mov eax, 1
    jmp .Ltt_finish_return
.Ltt_finish_bad:
    xor eax, eax
.Ltt_finish_return:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_time_finish

# RCX=media sample target -> exact media position. Codec pre-roll stays
# pending in the source decoder and is consumed before the first real PCM.
FN track_time_seek
    cmp dword ptr [rip+track_time_active], 0
    je track_seek
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Ltt_seek_search_begin
    cmp dword ptr [rax], 0
    jne .Ltt_seek_cancelled
.Ltt_seek_search_begin:
    cmp rbx, [rip+total_frames]
    cmova rbx, [rip+total_frames]
    xor r8d, r8d
    mov r9d, [rip+track_time_span_count]
.Ltt_seek_search:
    cmp r8d, r9d
    jae .Ltt_seek_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    mov eax, edx
    shl rax, 5
    add rax, [rip+tt_spans]
    cmp [rax+24], rbx
    ja .Ltt_seek_upper
    lea r8d, [rdx+1]
    jmp .Ltt_seek_search
.Ltt_seek_upper:
    mov r9d, edx
    jmp .Ltt_seek_search
.Ltt_seek_found:
    mov esi, r8d
    mov rcx, [rip+track_time_source_frames]
    cmp esi, [rip+track_time_span_count]
    jae .Ltt_seek_restart
    mov eax, esi
    shl rax, 5
    add rax, [rip+tt_spans]
    mov rcx, [rax]
    cmp rbx, [rax+16]
    jbe .Ltt_seek_restart
    add rcx, rbx
    sub rcx, [rax+16]
.Ltt_seek_restart:
    mov [rsp+32], rcx
    call track_seek
    cmp rax, [rsp+32]
    ja .Ltt_seek_bad
    mov [rip+tt_source_position], rax
    mov [rip+tt_position], rbx
    mov [rip+tt_span_index], esi
    mov dword ptr [rip+tt_drained], 0
    mov rax, rbx
    jmp .Ltt_seek_return
.Ltt_seek_bad:
    mov dword ptr [rip+decode_error], 60
.Ltt_seek_cancelled:
    xor eax, eax
.Ltt_seek_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN track_time_seek

# RCX=stereo float output, EDX=capacity -> frames. Gaps consume bounded
# output buffers; dropped source and pre-roll still decode for DSP history.
FN track_time_read
    cmp dword ptr [rip+track_time_active], 0
    je track_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
.Ltt_read_loop:
    cmp ebx, r12d
    jae .Ltt_read_return
    cmp dword ptr [rip+decode_error], 0
    jne .Ltt_read_return
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Ltt_read_span
    cmp dword ptr [rax], 0
    je .Ltt_read_span
    mov dword ptr [rip+decode_error], 61
    jmp .Ltt_read_return
.Ltt_read_span:
    mov eax, [rip+tt_span_index]
    cmp eax, [rip+track_time_span_count]
    jae .Ltt_read_drain
    shl rax, 5
    add rax, [rip+tt_spans]
    mov rsi, rax
    mov rax, [rip+tt_position]
    cmp rax, [rsi+16]
    jae .Ltt_read_source
    mov rcx, [rsi+16]
    sub rcx, rax
    mov edx, r12d
    sub edx, ebx
    cmp rcx, rdx
    cmova rcx, rdx
    add [rip+tt_position], rcx
    add ebx, ecx
    xor eax, eax
    rep stosq
    jmp .Ltt_read_loop
.Ltt_read_source:
    sub rax, [rsi+16]
    add rax, [rsi]
    cmp [rip+tt_source_position], rax
    jb .Ltt_read_discard
    ja .Ltt_read_bad
    mov r13, [rsi+24]
    sub r13, [rip+tt_position]
    mov eax, r12d
    sub eax, ebx
    cmp r13, rax
    cmova r13, rax
    mov rcx, rdi
    mov edx, r13d
    call track_read
    add [rip+tt_source_position], rax
    add [rip+tt_position], rax
    add ebx, eax
    lea rdi, [rdi+rax*8]
    cmp eax, r13d
    jne .Ltt_read_bad
    mov rax, [rip+tt_position]
    cmp rax, [rsi+24]
    jb .Ltt_read_loop
    inc dword ptr [rip+tt_span_index]
    jmp .Ltt_read_loop
.Ltt_read_discard:
    sub rax, [rip+tt_source_position]
    jmp .Ltt_read_scratch
.Ltt_read_drain:
    mov rax, [rip+track_time_source_frames]
    sub rax, [rip+tt_source_position]
    jb .Ltt_read_bad
    jz .Ltt_read_tail
.Ltt_read_scratch:
    mov r13d, 4096
    cmp rax, r13
    cmovb r13, rax
    lea rcx, [rip+tt_scratch]
    mov edx, r13d
    call track_read
    add [rip+tt_source_position], rax
    cmp eax, r13d
    jne .Ltt_read_bad
    jmp .Ltt_read_loop
.Ltt_read_tail:
    cmp dword ptr [rip+tt_drained], 0
    jne .Ltt_read_return
    lea rcx, [rip+tt_scratch]
    mov edx, 4096
    call track_read                    # decode any completely trimmed tail
    test eax, eax
    jnz .Ltt_read_bad
    mov dword ptr [rip+tt_drained], 1
    jmp .Ltt_read_return
.Ltt_read_bad:
    cmp dword ptr [rip+decode_error], 0
    jne .Ltt_read_return
    mov dword ptr [rip+decode_error], 60
.Ltt_read_return:
    mov eax, ebx
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_time_read
