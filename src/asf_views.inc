# Original ASF gathered audio-clock views. MIT, see LICENSE.
# Reuse validated native codec packetization, then replay only the bounded
# ASF framing to place its complete media objects. Gathered bytes stay fixed.
.data
asf_view_pcm_align: .long 0
asf_view_last_samples: .long 0
asf_view_packet: .quad 0
asf_view_last_end: .quad 0
asf_view_origin: .quad 0
.text

# RCX=sample duration, RDX=signed ns -> EAX=1, RDX=advanced ns, or 0.
# An object beginning inside an earlier codec frame owns its next frame
# after that full preceding frame's duration, rounded to nearest ns.
LOCALFN asf_view_add_samples
    mov r8, rdx
    mov rax, rcx
    mov ecx, 1000000000
    mul rcx
    mov ecx, [rip + sample_rate]
    test ecx, ecx
    jz .Lasf_view_duration_bad
    mov r9d, ecx
    shr r9d, 1
    add rax, r9
    adc rdx, 0
    cmp rdx, rcx
    jae .Lasf_view_duration_bad
    div rcx
    add rax, r8
    jo .Lasf_view_duration_bad
    mov rdx, rax
    mov eax, 1
    ret
.Lasf_view_duration_bad:
    xor eax, eax
    ret
ENDFN asf_view_add_samples

# A complete object during framing replay -> EAX=1/0. Packet raw starts and
# durations already came from the native codec scanner. Only its first newly
# owned frame gets an anchor; later frames in the object remain consecutive.
LOCALFN asf_view_complete
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov dword ptr [rip + asf_pending], 0
    mov rcx, [rip + asf_object_time]
    call asf_clock_ns
    test eax, eax
    jz .Lasf_view_bad
    mov r13, rdx
    mov rbx, [rip + mts_buffer]
    add rbx, [rip + asf_object_start]
    mov esi, [rip + asf_object_have]
    add rsi, rbx
    cmp dword ptr [rip + asf_view_pcm_align], 0
    jne .Lasf_view_pcm
    mov dword ptr [rsp + 32], 0
    mov r14, [rip + asf_view_packet]
.Lasf_view_packet_next:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_view_bad
    cmp r14, [rip + track_count]
    jae .Lasf_view_ok
    imul rdi, r14, 24
    add rdi, [rip + track_packets]
    mov r15, [rdi]
    cmp dword ptr [rip + asf_mode], 2
    jne .Lasf_view_packet_origin
    mov r15, [rip + asf_view_origin]      # ADTS packet pointer excludes header
.Lasf_view_packet_origin:
    cmp r15, rbx
    jb .Lasf_view_bad
    cmp r15, rsi
    jae .Lasf_view_ok
    cmp dword ptr [rsp + 32], 0
    jne .Lasf_view_packet_advance
    cmp rbx, [rip + asf_view_last_end]
    jae .Lasf_view_packet_anchor
    mov ecx, [rip + asf_view_last_samples]
    mov rdx, r13
    call asf_view_add_samples
    test eax, eax
    jz .Lasf_view_bad
    mov r13, rdx
.Lasf_view_packet_anchor:
    mov rcx, [rdi + 8]
    mov rdx, r13
    call track_time_anchor_ns
    test eax, eax
    jz .Lasf_view_bad
    mov dword ptr [rsp + 32], 1
.Lasf_view_packet_advance:
    mov eax, [rdi + 16]
    add rax, [rdi]
    mov [rip + asf_view_last_end], rax
    mov [rip + asf_view_origin], rax
    mov eax, [rdi + 20]
    mov [rip + asf_view_last_samples], eax
    inc r14
    mov [rip + asf_view_packet], r14
    jmp .Lasf_view_packet_next
.Lasf_view_pcm:
    # PCM objects may split interleaved sample frames. Anchor the first
    # sample whose first byte belongs to this object, not a synthetic packet.
    mov rax, [rip + asf_object_start]
    sub rax, [rip + asf_audio_offset]
    xor edx, edx
    mov ecx, [rip + asf_view_pcm_align]
    div rcx
    mov r12, rax
    test edx, edx
    jz .Lasf_view_pcm_whole
    inc r12
    mov ecx, 1
    mov rdx, r13
    call asf_view_add_samples
    test eax, eax
    jz .Lasf_view_bad
    mov r13, rdx
.Lasf_view_pcm_whole:
    cmp r12, [rip + track_raw_total]
    jae .Lasf_view_ok
    mov eax, [rip + asf_view_pcm_align]
    imul rax, r12
    add rax, [rip + asf_audio_offset]
    add rax, [rip + mts_buffer]
    cmp rax, rsi
    jae .Lasf_view_ok
    mov rcx, r12
    mov rdx, r13
    call track_time_anchor_ns
    jmp .Lasf_view_return
.Lasf_view_ok:
    mov eax, 1
    jmp .Lasf_view_return
.Lasf_view_bad:
    xor eax, eax
.Lasf_view_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_view_complete

# Convert the already opened native MPEG stream to frame views, retaining
# its existing metadata/Xing/encoder trim policy rather than rescanning tags.
LOCALFN asf_mpa_packets
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    call mp3_stream_layout
    mov rsi, rax
    mov rdi, rdx
    mov r12d, r8d
    mov r13d, r9d
    call mp3_close
    mov ecx, 3                         # TK_MPA
    call track_begin
    test eax, eax
    jz .Lasf_mpa_return
    mov [rip + track_start_trim], r12
    mov [rip + track_end_trim], r13
.Lasf_mpa_next:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_mpa_bad
    cmp rsi, rdi
    jae .Lasf_mpa_finish
    mov rax, rdi
    sub rax, rsi
    cmp rax, 128
    jne .Lasf_mpa_frame
    cmp word ptr [rsi], 0x4154          # native ID3v1 trailer, not a frame
    jne .Lasf_mpa_frame
    cmp byte ptr [rsi + 2], 'G'
    je .Lasf_mpa_finish
.Lasf_mpa_frame:
    mov rcx, rsi
    mov rdx, rdi
    call mpa_frame_bytes
    test eax, eax
    jz .Lasf_mpa_bad
    mov ebx, eax
    mov rcx, rsi
    mov edx, ebx
    call track_add
    test eax, eax
    jz .Lasf_mpa_bad
    add rsi, rbx
    jmp .Lasf_mpa_next
.Lasf_mpa_finish:
    call track_finish
    jmp .Lasf_mpa_return
.Lasf_mpa_bad:
    xor eax, eax
.Lasf_mpa_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_mpa_packets

# -> EAX=1/0. Called after the gathered WAVE/ADTS reader has validated and
# opened the codec, before any reads or seeks. Replays packet framing only;
# the original gather allocation and spreading scratch ownership stay intact.
FN asf_gathered_finish
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov dword ptr [rip + asf_view_pcm_align], 0
    mov dword ptr [rip + asf_view_last_samples], 0
    mov qword ptr [rip + asf_view_last_end], 0
    mov qword ptr [rip + asf_view_packet], 0
    cmp dword ptr [rip + track_active], 0
    jne .Lasf_gathered_track
    cmp dword ptr [rip + codec_kind], 3
    je .Lasf_gathered_mpa
    cmp dword ptr [rip + codec_kind], 21
    jne .Lasf_gathered_bad
    call wav_track_packetize
    test eax, eax
    jz .Lasf_gathered_bad
    mov [rip + asf_view_pcm_align], edx
    jmp .Lasf_gathered_track
.Lasf_gathered_mpa:
    call asf_mpa_packets
    test eax, eax
    jz .Lasf_gathered_bad
.Lasf_gathered_track:
    call track_time_close              # native open finalized an identity map
    mov dword ptr [rip + track_time_enabled], 1
    mov qword ptr [rip + track_time_scale_ns], 1000000
    mov rax, [rip + asf_audio_offset]
    mov [rip + asf_view_position], rax
    cmp dword ptr [rip + asf_mode], 2
    jne .Lasf_gathered_replay
    mov rcx, [rip + mts_buffer]
    mov rdx, rcx
    add rdx, [rip + mts_bytes]
    call adts_skip_id3
    mov [rip + asf_view_origin], rax
.Lasf_gathered_replay:
    mov dword ptr [rip + asf_revisit], 1
    mov dword ptr [rip + asf_pending], 0
    mov rsi, [rip + asf_data_begin]
    mov rdi, [rip + asf_data_end]
.Lasf_gathered_packet:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_gathered_bad
    cmp rsi, rdi
    je .Lasf_gathered_done
    mov rcx, rsi
    mov rdx, rdi
    call asf_packet
    test rax, rax
    jz .Lasf_gathered_bad
    mov rsi, rax
    jmp .Lasf_gathered_packet
.Lasf_gathered_done:
    cmp dword ptr [rip + asf_pending], 0
    jne .Lasf_gathered_bad
    mov rax, [rip + asf_audio_offset]
    add rax, [rip + asf_audio_bytes]
    cmp rax, [rip + asf_view_position]
    jne .Lasf_gathered_bad
    cmp dword ptr [rip + asf_view_pcm_align], 0
    jne .Lasf_gathered_finish
    mov rax, [rip + asf_view_packet]
    cmp rax, [rip + track_count]
    jne .Lasf_gathered_bad
.Lasf_gathered_finish:
    mov rcx, [rip + track_raw_total]
    call track_time_finish
    test eax, eax
    jz .Lasf_gathered_bad
    jmp .Lasf_gathered_return
.Lasf_gathered_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lasf_gathered_fail
    mov dword ptr [rip + decode_error], ASF_MALFORMED
.Lasf_gathered_fail:
    xor eax, eax
.Lasf_gathered_return:
    mov dword ptr [rip + asf_revisit], 0
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_gathered_finish
