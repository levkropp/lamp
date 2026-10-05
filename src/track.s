# Original packet track layer for container demuxers. MIT, see LICENSE.
# A demuxer (Matroska/WebM, MP4) lists one audio track's packets in file
# order, names the codec and its configuration, and sets start/end trimming.
# track_finish validates every packet's duration with the codec, then
# track_read decodes packets in order, trimming to the presented range, and
# track_seek restarts from an earlier packet with the codec's pre-roll.
# Packets are pointers into the mapped input; nothing is copied at open.
.include "lamp.inc"
.globl track_active, track_codec, track_count, track_final_packet
.globl track_start_trim, track_end_trim, track_end_trim_ns, track_config, track_config_bytes
.globl track_pcm_channels, track_pcm_bits, track_pcm_flags
.globl track_unit_scale, track_start_units, track_end_units, track_edit

.equ TK_PCM, 1
.equ TK_FLAC, 2
.equ TK_MPA, 3
.equ TK_VORBIS, 4
.equ TK_OPUS, 5
.equ TK_ALAC, 6
.equ TK_ENTRY, 24                   # pointer, raw start sample, bytes, samples
.equ TK_POINTER, 0
.equ TK_START, 8
.equ TK_BYTES, 16
.equ TK_SAMPLES, 20
.equ TK_CAP, 1 << 24                # packets
.equ TK_BUFFER, 65536               # stereo frames decoded per packet at most
.equ TK_OPUS_PREROLL, 3840          # 80 ms
.equ TK_MPA_RESERVOIR, 2048         # bytes of earlier frames for main data

.data
track_active: .long 0
track_codec: .long 0
track_count: .quad 0
track_committed: .quad 0
track_packets: .quad 0
track_buffer: .quad 0
track_config: .quad 0                # codec private data, owned by the demuxer
track_config_bytes: .long 0
track_pcm_channels: .long 0
track_pcm_bits: .long 0
track_pcm_flags: .long 0
track_start_trim: .quad 0            # raw samples before the presented start
track_end_trim: .quad 0              # raw samples after the presented end
track_end_trim_ns: .quad 0           # or nanoseconds, rounded at the codec rate
track_raw_total: .quad 0
track_final_packet: .long 0
track_unit_scale: .long 0            # MP4 media timescale, 0 when unused
track_edit: .long 0                  # 1 when an edit places the start
track_start_units: .quad 0           # first presented media unit (edit)
track_end_units: .quad 0             # presentation end in media units, 0 = none
track_end_frames: .quad 0
track_next: .quad 0                  # next packet to decode
track_raw: .quad 0                   # raw sample position of buffer[0]
track_used: .long 0
track_available: .long 0
track_primer: .long 0                # packets still to decode without output

.text
FN track_close
    sub rsp, 40
    mov rcx, [rip + track_packets]
    test rcx, rcx
    jz .Ltk_close_buffer
    call mem_free
    mov qword ptr [rip + track_packets], 0
.Ltk_close_buffer:
    mov rcx, [rip + track_buffer]
    test rcx, rcx
    jz .Ltk_close_codec
    call mem_free
    mov qword ptr [rip + track_buffer], 0
.Ltk_close_codec:
    cmp dword ptr [rip + track_codec], TK_VORBIS
    jne .Ltk_close_opus
    call vorbis_close
.Ltk_close_opus:
    cmp dword ptr [rip + track_codec], TK_OPUS
    jne .Ltk_close_flac
    call opus_close
.Ltk_close_flac:
    cmp dword ptr [rip + track_codec], TK_FLAC
    jne .Ltk_close_mpa
    call flac_ogg_close
.Ltk_close_mpa:
    cmp dword ptr [rip + track_codec], TK_MPA
    jne .Ltk_close_alac
    call mp3_close
.Ltk_close_alac:
    cmp dword ptr [rip + track_codec], TK_ALAC
    jne .Ltk_close_done
    call alac_track_close
    call flac_ogg_close
.Ltk_close_done:
    mov dword ptr [rip + track_active], 0
    mov dword ptr [rip + track_codec], 0
    mov qword ptr [rip + track_count], 0
    mov qword ptr [rip + track_committed], 0
    mov qword ptr [rip + track_config], 0
    mov dword ptr [rip + track_config_bytes], 0
    mov qword ptr [rip + track_start_trim], 0
    mov qword ptr [rip + track_end_trim], 0
    mov qword ptr [rip + track_end_trim_ns], 0
    mov dword ptr [rip + track_unit_scale], 0
    mov qword ptr [rip + track_start_units], 0
    mov dword ptr [rip + track_edit], 0
    mov qword ptr [rip + track_end_units], 0
    mov qword ptr [rip + track_end_frames], 0
    add rsp, 40
    ret
ENDFN track_close

# ECX=codec -> EAX=1. Starts an empty packet list.
FN track_begin
    push rbx
    sub rsp, 32
    mov ebx, ecx
    call track_close
    mov [rip + track_codec], ebx
    mov ecx, TK_CAP*TK_ENTRY
    call mem_reserve
    mov [rip + track_packets], rax
    test rax, rax
    setnz al
    movzx eax, al
    add rsp, 32
    pop rbx
    ret
ENDFN track_begin

# RCX=packet in the mapping, EDX=bytes -> EAX=1. Empty packets are rejected.
FN track_add
    push rbx
    push rsi
    sub rsp, 40
    xor eax, eax
    test edx, edx
    jz .Ltk_add_return
    mov rbx, rcx
    mov esi, edx
    mov rax, [rip + track_count]
    cmp rax, TK_CAP
    jae .Ltk_add_full
    imul rax, rax, TK_ENTRY
    lea rcx, [rax + TK_ENTRY]
    cmp rcx, [rip + track_committed]
    jbe .Ltk_add_store
    mov rcx, [rip + track_packets]
    add rcx, [rip + track_committed]
    mov edx, 65536*TK_ENTRY/8
    call mem_commit
    test rax, rax
    jz .Ltk_add_full
    add qword ptr [rip + track_committed], 65536*TK_ENTRY/8
    mov rax, [rip + track_count]
    imul rax, rax, TK_ENTRY
.Ltk_add_store:
    add rax, [rip + track_packets]
    mov [rax + TK_POINTER], rbx
    mov [rax + TK_BYTES], esi
    inc qword ptr [rip + track_count]
    mov eax, 1
    jmp .Ltk_add_return
.Ltk_add_full:
    xor eax, eax
.Ltk_add_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN track_add

# RCX=data, EDX=bytes, R8D=limit -> EAX=1. Extends the previous packet when
# the data follows it directly and the total stays within the limit (PCM).
FN track_append
    mov rax, [rip + track_count]
    test rax, rax
    jz track_add
    dec rax
    imul rax, rax, TK_ENTRY
    add rax, [rip + track_packets]
    mov r9d, [rax + TK_BYTES]
    mov r10, [rax + TK_POINTER]
    add r10, r9
    cmp r10, rcx
    jne track_add
    add r9d, edx
    cmp r9d, r8d
    ja track_add
    mov [rax + TK_BYTES], r9d
    mov eax, 1
    ret
ENDFN track_append

# RCX=packet entry -> EAX=samples or -1 (codec duration scan).
LOCALFN track_samples
    sub rsp, 40
    mov edx, [rcx + TK_BYTES]
    mov rcx, [rcx + TK_POINTER]
    mov eax, [rip + track_codec]
    cmp eax, TK_OPUS
    je .Ltk_samples_opus
    cmp eax, TK_VORBIS
    je .Ltk_samples_vorbis
    cmp eax, TK_FLAC
    je .Ltk_samples_flac
    cmp eax, TK_MPA
    je .Ltk_samples_mpa
    cmp eax, TK_ALAC
    je .Ltk_samples_alac
    call pcm_track_samples
    jmp .Ltk_samples_return
.Ltk_samples_opus:
    call opus_track_samples
    test eax, eax
    jnz .Ltk_samples_return
    mov eax, -1
    jmp .Ltk_samples_return
.Ltk_samples_vorbis:
    call vorbis_track_samples
    jmp .Ltk_samples_return
.Ltk_samples_flac:
    call flac_track_samples
    jmp .Ltk_samples_return
.Ltk_samples_mpa:
    call mpa_track_samples
    jmp .Ltk_samples_return
.Ltk_samples_alac:
    call alac_track_samples
.Ltk_samples_return:
    add rsp, 40
    ret
ENDFN track_samples

# RCX=packet entry -> EAX=frames decoded into track_buffer, or -1.
LOCALFN track_decode
    sub rsp, 40
    mov edx, [rcx + TK_BYTES]
    mov rcx, [rcx + TK_POINTER]
    mov r8, [rip + track_buffer]
    mov r9d, TK_BUFFER
    mov eax, [rip + track_codec]
    cmp eax, TK_OPUS
    je .Ltk_decode_opus
    cmp eax, TK_VORBIS
    je .Ltk_decode_vorbis
    cmp eax, TK_FLAC
    je .Ltk_decode_flac
    cmp eax, TK_MPA
    je .Ltk_decode_mpa
    cmp eax, TK_ALAC
    je .Ltk_decode_alac
    call pcm_track_decode
    jmp .Ltk_decode_return
.Ltk_decode_opus:
    call opus_track_decode
    test eax, eax
    jnz .Ltk_decode_return
    mov eax, -1
    jmp .Ltk_decode_return
.Ltk_decode_vorbis:
    call vorbis_track_decode
    jmp .Ltk_decode_return
.Ltk_decode_flac:
    call flac_track_decode
    jmp .Ltk_decode_return
.Ltk_decode_mpa:
    call mpa_track_decode
    jmp .Ltk_decode_return
.Ltk_decode_alac:
    call alac_track_decode
.Ltk_decode_return:
    add rsp, 40
    ret
ENDFN track_decode

# RCX=raw position of the packet decoded next. Clears codec history.
LOCALFN track_reset_codec
    sub rsp, 40
    mov eax, [rip + track_codec]
    cmp eax, TK_OPUS
    je .Ltk_reset_opus
    cmp eax, TK_VORBIS
    je .Ltk_reset_vorbis
    cmp eax, TK_FLAC
    je .Ltk_reset_flac
    cmp eax, TK_MPA
    jne .Ltk_reset_return
    call mpa_track_reset
    jmp .Ltk_reset_return
.Ltk_reset_opus:
    call opus_track_reset
    jmp .Ltk_reset_return
.Ltk_reset_vorbis:
    call vorbis_track_reset
    jmp .Ltk_reset_return
.Ltk_reset_flac:
    call flac_track_reset
.Ltk_reset_return:
    add rsp, 40
    ret
ENDFN track_reset_codec

# Opens the codec from track_config (or the first packet), scans every
# packet's duration and publishes sample_rate, total_frames and the format.
# EAX=1 on success.
FN track_finish
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    cmp qword ptr [rip + track_count], 0
    je .Ltk_finish_bad
    mov ecx, TK_BUFFER*8
    call mem_alloc
    mov [rip + track_buffer], rax
    test rax, rax
    jz .Ltk_finish_bad
    mov rcx, [rip + track_config]
    mov edx, [rip + track_config_bytes]
    mov eax, [rip + track_codec]
    cmp eax, TK_OPUS
    je .Ltk_open_opus
    cmp eax, TK_VORBIS
    je .Ltk_open_vorbis
    cmp eax, TK_FLAC
    je .Ltk_open_flac
    cmp eax, TK_MPA
    je .Ltk_open_mpa
    cmp eax, TK_ALAC
    je .Ltk_open_alac
    mov ecx, [rip + track_pcm_channels]
    mov edx, [rip + track_pcm_bits]
    mov r8d, [rip + track_pcm_flags]
    call pcm_track_open
    jmp .Ltk_opened
.Ltk_open_alac:
    call alac_track_open
    jmp .Ltk_opened
.Ltk_open_opus:
    call opus_track_open
    test eax, eax
    jz .Ltk_finish_bad
    cmp dword ptr [rip + track_edit], 0
    jne .Ltk_open_opus_edit               # an MP4 edit already places the start
    mov eax, [rip + op_preskip]          # OpusHead pre-skip trims the start
    mov [rip + track_start_trim], rax
.Ltk_open_opus_edit:
    mov eax, 1
    jmp .Ltk_opened
.Ltk_open_vorbis:
    call vorbis_track_open
    jmp .Ltk_opened
.Ltk_open_flac:
    call flac_track_open
    jmp .Ltk_opened
.Ltk_open_mpa:
    mov rax, [rip + track_packets]
    mov rcx, [rax + TK_POINTER]
    mov edx, [rax + TK_BYTES]
    call mpa_track_open
.Ltk_opened:
    test eax, eax
    jz .Ltk_finish_bad
    # MP4 timing: media units -> samples at the codec rate, rounded.
    mov ecx, [rip + track_unit_scale]
    test ecx, ecx
    jz .Ltk_units_ready
    mov r8d, [rip + sample_rate]
    mov r9, rcx
    shr r9, 1
    cmp dword ptr [rip + track_edit], 0
    je .Ltk_units_end
    mov rax, [rip + track_start_units]
    mul r8
    add rax, r9
    adc rdx, 0
    cmp rdx, rcx
    jae .Ltk_finish_bad
    div rcx
    mov [rip + track_start_trim], rax
.Ltk_units_end:
    mov rax, [rip + track_end_units]
    mul r8
    add rax, r9
    adc rdx, 0
    cmp rdx, rcx
    jae .Ltk_finish_bad
    div rcx
    mov [rip + track_end_frames], rax
.Ltk_units_ready:
    mov rax, [rip + track_end_trim_ns]
    test rax, rax
    jz .Ltk_trim_ready
    mov ecx, [rip + sample_rate]         # round(ns * rate / 1e9)
    mul rcx
    add rax, 500000000
    adc rdx, 0
    mov ecx, 1000000000
    cmp rdx, rcx
    jae .Ltk_finish_bad
    div rcx
    mov [rip + track_end_trim], rax
.Ltk_trim_ready:
    # Every packet's duration, from the codec; raw starts accumulate.
    mov rsi, [rip + track_packets]
    xor ebx, ebx                         # packet
    xor edi, edi                         # raw position
.Ltk_scan:
    cmp rbx, [rip + track_count]
    jae .Ltk_scan_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Ltk_scan_continue
    cmp dword ptr [rax], 0
    jne .Ltk_finish_bad
.Ltk_scan_continue:
    mov [rsi + TK_START], rdi
    mov rcx, rsi
    call track_samples
    cmp eax, -1
    je .Ltk_finish_bad
    cmp eax, TK_BUFFER
    ja .Ltk_finish_bad
    mov [rsi + TK_SAMPLES], eax
    add rdi, rax
    add rsi, TK_ENTRY
    inc rbx
    jmp .Ltk_scan
.Ltk_scan_done:
    mov [rip + track_raw_total], rdi
    # A presentation end trims whatever decodes after it.
    mov rax, [rip + track_end_frames]
    test rax, rax
    jz .Ltk_scan_total
    cmp rax, [rip + track_start_trim]
    jbe .Ltk_finish_bad                  # nothing presented
    mov rcx, rdi
    sub rcx, rax
    jbe .Ltk_scan_total
    mov [rip + track_end_trim], rcx
.Ltk_scan_total:
    mov rax, rdi
    sub rax, [rip + track_start_trim]
    jc .Ltk_finish_bad
    sub rax, [rip + track_end_trim]
    jc .Ltk_finish_bad
    mov [rip + total_frames], rax
    cmp dword ptr [rip + track_codec], TK_FLAC
    jne .Ltk_finish_declared
    mov rcx, [rip + flac_declared_frames]   # STREAMINFO total, when declared
    test rcx, rcx
    jz .Ltk_finish_declared
    cmp rcx, rdi
    jne .Ltk_finish_bad
.Ltk_finish_declared:
    xor ecx, ecx
    call track_restart
    mov dword ptr [rip + track_active], 1
    mov eax, 1
    jmp .Ltk_finish_return
.Ltk_finish_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Ltk_finish_failed
    mov dword ptr [rip + decode_error], 60
.Ltk_finish_failed:
    xor eax, eax
.Ltk_finish_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_finish

# RCX=packet to decode next, after a codec reset. Vorbis decodes one primer
# packet first, which yields no output.
LOCALFN track_restart
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov [rip + track_next], rbx
    mov dword ptr [rip + track_used], 0
    mov dword ptr [rip + track_available], 0
    mov dword ptr [rip + track_primer], 0
    imul rax, rbx, TK_ENTRY
    add rax, [rip + track_packets]
    mov rcx, [rax + TK_START]
    mov [rip + track_raw], rcx
    call track_reset_codec
    add rsp, 32
    pop rbx
    ret
ENDFN track_restart

# RCX=stereo float output, EDX=frame capacity -> EAX=frames; 0 at the end or
# on error (decode_error set).
FN track_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    cmp dword ptr [rip + track_active], 0
    je .Ltk_read_done
.Ltk_read_next:
    cmp ebx, r12d
    jae .Ltk_read_done
    cmp dword ptr [rip + decode_error], 0
    jne .Ltk_read_done
    mov eax, [rip + track_used]
    cmp eax, [rip + track_available]
    jb .Ltk_read_copy
    # Decode the next packet.
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Ltk_read_not_cancelled
    cmp dword ptr [rax], 0
    je .Ltk_read_not_cancelled
    mov dword ptr [rip + decode_error], 61
    jmp .Ltk_read_done
.Ltk_read_not_cancelled:
    mov rax, [rip + track_next]
    cmp rax, [rip + track_count]
    jae .Ltk_read_done
    mov rcx, [rip + track_count]
    dec rcx
    cmp rax, rcx
    sete cl
    movzx ecx, cl
    mov [rip + track_final_packet], ecx
    imul rsi, rax, TK_ENTRY
    add rsi, [rip + track_packets]
    mov rcx, rsi
    call track_decode
    cmp eax, -1
    je .Ltk_read_bad
    inc qword ptr [rip + track_next]
    mov rcx, [rsi + TK_START]
    mov [rip + track_raw], rcx
    cmp dword ptr [rip + track_primer], 0
    je .Ltk_read_counted
    dec dword ptr [rip + track_primer]
    mov dword ptr [rip + track_used], 0
    mov dword ptr [rip + track_available], 0
    jmp .Ltk_read_next
.Ltk_read_counted:
    cmp eax, [rsi + TK_SAMPLES]
    jne .Ltk_read_bad                    # decoding must match the scan
    # Present only raw positions in [start trim, raw total - end trim).
    mov r13d, eax
    mov rax, [rip + track_start_trim]
    sub rax, rcx
    jbe .Ltk_read_head_done
    cmp rax, r13
    cmova rax, r13
    jmp .Ltk_read_head
.Ltk_read_head_done:
    xor eax, eax
.Ltk_read_head:
    mov [rip + track_used], eax
    mov rax, [rip + track_raw_total]
    sub rax, [rip + track_end_trim]
    sub rax, rcx
    jbe .Ltk_read_tail_empty
    cmp rax, r13
    cmova rax, r13
    jmp .Ltk_read_tail
.Ltk_read_tail_empty:
    xor eax, eax
.Ltk_read_tail:
    mov [rip + track_available], eax
    cmp [rip + track_used], eax
    jbe .Ltk_read_next
    mov [rip + track_used], eax
    jmp .Ltk_read_next
.Ltk_read_copy:
    mov ecx, [rip + track_available]
    sub ecx, eax
    mov edx, r12d
    sub edx, ebx
    cmp ecx, edx
    cmova ecx, edx
    mov rsi, [rip + track_buffer]
    lea rsi, [rsi + rax*8]
    add [rip + track_used], ecx
    add ebx, ecx
    rep movsq
    jmp .Ltk_read_next
.Ltk_read_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Ltk_read_done
    mov dword ptr [rip + decode_error], 62
.Ltk_read_done:
    mov eax, ebx
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_read

# RCX=presented frame, on a freshly finished track -> RAX=resume frame at or
# before it. Restarts at the packet holding the target, moved back by the
# codec's pre-roll: Opus 80 ms, MPEG audio two frames (Layer III also earlier
# frames holding up to 2 KiB of reservoir data), Vorbis one primer packet whose
# output is skipped. FLAC and PCM packets decode independently.
FN track_seek
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor eax, eax
    cmp dword ptr [rip + track_active], 0
    je .Ltk_seek_return
    test rcx, rcx
    jz .Ltk_seek_return
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Ltk_seek_not_cancelled
    cmp dword ptr [rax], 0
    mov eax, 0
    jne .Ltk_seek_return
.Ltk_seek_not_cancelled:
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    add rcx, [rip + track_start_trim]    # raw target
    mov rdi, rcx
    # Last packet whose raw start is at or before the target.
    xor r8d, r8d
    mov r9, [rip + track_count]
.Ltk_seek_search:
    mov rdx, r9
    sub rdx, r8
    cmp rdx, 1
    jbe .Ltk_seek_found
    shr rdx, 1
    add rdx, r8
    imul rax, rdx, TK_ENTRY
    add rax, [rip + track_packets]
    cmp [rax + TK_START], rdi
    ja .Ltk_seek_upper
    mov r8, rdx
    jmp .Ltk_seek_search
.Ltk_seek_upper:
    mov r9, rdx
    jmp .Ltk_seek_search
.Ltk_seek_found:
    mov rbx, r8                          # packet holding the target
    mov eax, [rip + track_codec]
    cmp eax, TK_OPUS
    je .Ltk_seek_opus
    cmp eax, TK_MPA
    je .Ltk_seek_mpa
    cmp eax, TK_VORBIS
    je .Ltk_seek_vorbis
    jmp .Ltk_seek_restart
.Ltk_seek_opus:
    # Back up until at least 80 ms precede the target.
    mov rsi, rdi
    sub rsi, TK_OPUS_PREROLL
    jbe .Ltk_seek_from_zero
.Ltk_seek_opus_back:
    test rbx, rbx
    jz .Ltk_seek_restart
    imul rax, rbx, TK_ENTRY
    add rax, [rip + track_packets]
    cmp [rax + TK_START], rsi
    jbe .Ltk_seek_restart
    dec rbx
    jmp .Ltk_seek_opus_back
.Ltk_seek_mpa:
    # Two whole frames rebuild synthesis/overlap history; frames before
    # them refill the bit reservoir.
    sub rbx, 2
    jbe .Ltk_seek_from_zero
    cmp dword ptr [rip + mp_layer], 3
    jne .Ltk_seek_restart                # Layers I/II have no reservoir
    xor esi, esi
.Ltk_seek_mpa_back:
    test rbx, rbx
    jz .Ltk_seek_restart
    cmp esi, TK_MPA_RESERVOIR
    jae .Ltk_seek_restart
    dec rbx
    imul rax, rbx, TK_ENTRY
    add rax, [rip + track_packets]
    add esi, [rax + TK_BYTES]
    jmp .Ltk_seek_mpa_back
.Ltk_seek_vorbis:
    test rbx, rbx
    jz .Ltk_seek_restart
    lea rcx, [rbx - 1]
    call track_restart                   # resets the codec
    mov dword ptr [rip + track_primer], 1
    imul rax, rbx, TK_ENTRY
    add rax, [rip + track_packets]
    mov rax, [rax + TK_START]
    jmp .Ltk_seek_position
.Ltk_seek_from_zero:
    xor ebx, ebx
.Ltk_seek_restart:
    mov rcx, rbx
    call track_restart
    imul rax, rbx, TK_ENTRY
    add rax, [rip + track_packets]
    mov rax, [rax + TK_START]
.Ltk_seek_position:
    sub rax, [rip + track_start_trim]    # presented position of that packet
    jae .Ltk_seek_return
    xor eax, eax
.Ltk_seek_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN track_seek
