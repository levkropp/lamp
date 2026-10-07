# Original Ogg physical-stream layer: chained links and multiplexed streams.
# MIT, see LICENSE.
# A physical stream is a sequence of links. Each link starts with the BOS
# pages of its logical streams; a BOS page after any other page starts the next
# link. Each link plays its first Vorbis, Opus or FLAC stream, or the audio
# stream that track_choice numbers (Vorbis, Opus, FLAC, Speex, CELT and OGM
# audio count, in BOS order); other streams (video, metadata, other audio
# tracks) are skipped. A link without the stream rejects the file.
# Every link is opened at chain_open to validate it and learn its duration.
# Output keeps the first link's rate; later links at another rate pass through
# the resampler. One codec instance is open at a time.
.include "lamp.inc"
.globl chain_active, chain_links, chain_count, chain_current
.globl output_rate, output_frames

.equ CH_SIZE, 64
.equ CH_BEGIN, 0
.equ CH_END, 8
.equ CH_START, 16                 # first output frame
.equ CH_FRAMES, 24                # output frames
.equ CH_SOURCE, 32                # frames at the link's own rate
.equ CH_SERIAL, 40
.equ CH_CODEC, 44                 # codec_kind: 4 Vorbis, 5 Opus, 7 FLAC
.equ CH_RATE, 48
.equ CH_CHANNELS, 52
.equ CH_BITS, 56
.equ CH_AUDIO_COUNT, 60             # audio streams in this link, including unsupported mappings
.equ CH_CAP, 65536
.equ CH_STREAMS, 64               # logical streams per link

.data
chain_active: .long 0
chain_count: .long 0
chain_current: .long -1
chain_links: .quad 0
chain_committed: .quad 0
chain_rs_rate: .long 0            # input rate the resampler tables were built for
chain_resampling: .long 0
output_rate: .long 0
output_frames: .quad 0
chain_serial_count: .long 0
chain_audio_index: .long 0        # audio streams begun in the current link
.bss
chain_serials: .zero CH_STREAMS*4       # logical streams of the link being scanned

.text
FN chain_close
    sub rsp, 40
    call chain_codec_close
    call resample_close
    mov dword ptr [rip + chain_rs_rate], 0
    mov dword ptr [rip + chain_resampling], 0
    mov rcx, [rip + chain_links]
    test rcx, rcx
    jz .Lch_close_links
    call mem_free
    mov qword ptr [rip + chain_links], 0
.Lch_close_links:
    mov qword ptr [rip + chain_committed], 0
    mov dword ptr [rip + chain_count], 0
    mov dword ptr [rip + chain_current], -1
    mov dword ptr [rip + chain_active], 0
    mov dword ptr [rip + ogg_select_active], 0
    add rsp, 40
    ret
ENDFN chain_close

# Closes the current link's codec, if any.
LOCALFN chain_codec_close
    sub rsp, 40
    mov eax, [rip + chain_current]
    cmp eax, -1
    je .Lch_codec_close_done
    call vorbis_close
    call opus_close
    call flac_ogg_close
    mov dword ptr [rip + chain_current], -1
.Lch_codec_close_done:
    add rsp, 40
    ret
ENDFN chain_codec_close

# RCX=link record -> EAX=1 when its codec opened. Selects the link's stream.
LOCALFN chain_codec_open
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov eax, [rbx + CH_SERIAL]
    mov [rip + ogg_select], eax
    mov dword ptr [rip + ogg_select_active], 1
    mov rcx, [rbx + CH_BEGIN]
    mov rdx, [rbx + CH_END]
    mov eax, [rbx + CH_CODEC]
    cmp eax, 4
    je .Lch_open_vorbis
    cmp eax, 5
    je .Lch_open_opus
    call flac_ogg_open
    jmp .Lch_codec_open_return
.Lch_open_vorbis:
    call vorbis_open
    jmp .Lch_codec_open_return
.Lch_open_opus:
    call opus_open
.Lch_codec_open_return:
    add rsp, 32
    pop rbx
    ret
ENDFN chain_codec_open

# RCX=stereo float output, EDX=frames -> EAX=frames from the current codec.
LOCALFN chain_codec_read
    sub rsp, 40
    mov eax, [rip + chain_current]
    shl rax, 6
    add rax, [rip + chain_links]
    mov eax, [rax + CH_CODEC]
    cmp eax, 4
    je .Lch_read_vorbis
    cmp eax, 5
    je .Lch_read_opus
    call flac_ogg_read
    jmp .Lch_read_return
.Lch_read_vorbis:
    call vorbis_read
    jmp .Lch_read_return
.Lch_read_opus:
    call opus_read
.Lch_read_return:
    add rsp, 40
    ret
ENDFN chain_codec_read

# RCX=frame at the link's own rate -> RAX=resume frame from the fresh codec.
LOCALFN chain_codec_seek
    sub rsp, 40
    mov eax, [rip + chain_current]
    shl rax, 6
    add rax, [rip + chain_links]
    mov eax, [rax + CH_CODEC]
    cmp eax, 4
    je .Lch_seek_vorbis
    cmp eax, 5
    je .Lch_seek_opus
    call flac_ogg_seek
    jmp .Lch_codec_seek_return
.Lch_seek_vorbis:
    call vorbis_seek
    jmp .Lch_codec_seek_return
.Lch_seek_opus:
    call opus_seek
.Lch_codec_seek_return:
    add rsp, 40
    ret
ENDFN chain_codec_seek

# RCX=page, RDX=range end -> RAX=next page or zero.
LOCALFN chain_page_end
    lea rax, [rcx + 27]
    cmp rax, rdx
    ja .Lch_page_bad
    cmp dword ptr [rcx], 0x5367674f
    jne .Lch_page_bad
    cmp byte ptr [rcx + 4], 0
    jne .Lch_page_bad
    movzx r8d, byte ptr [rcx + 26]
    add rax, r8
    cmp rax, rdx
    ja .Lch_page_bad
.Lch_page_lace:
    test r8d, r8d
    jz .Lch_page_body
    movzx r9d, byte ptr [rcx + r8 + 26]
    add rax, r9
    dec r8d
    jmp .Lch_page_lace
.Lch_page_body:
    cmp rax, rdx
    ja .Lch_page_bad
    ret
.Lch_page_bad:
    xor eax, eax
    ret
ENDFN chain_page_end

# ECX=serial -> EAX=its index among the scanned link's streams, or -1.
LOCALFN chain_serial_find
    lea rdx, [rip + chain_serials]
    xor eax, eax
.Lch_find_next:
    cmp eax, [rip + chain_serial_count]
    jae .Lch_find_none
    cmp [rdx + rax*4], ecx
    je .Lch_find_return
    inc eax
    jmp .Lch_find_next
.Lch_find_none:
    mov eax, -1
.Lch_find_return:
    ret
ENDFN chain_serial_find

# RCX=BOS page -> EAX=codec_kind of its first packet (4, 5, 7) or zero.
# Every supported mapping places its whole identification packet first on
# the BOS page.
LOCALFN chain_probe
    movzx r8d, byte ptr [rcx + 26]
    lea r9, [rcx + r8 + 27]          # first packet
    xor edx, edx                     # packet length
    xor r10d, r10d
.Lch_probe_lace:
    cmp r10d, r8d
    jae .Lch_probe_none              # continues past the page
    movzx eax, byte ptr [rcx + r10 + 27]
    add edx, eax
    inc r10d
    cmp eax, 255
    je .Lch_probe_lace
    cmp edx, 9
    jb .Lch_probe_none
    cmp dword ptr [r9], 0x726f7601   # 01 'vor'
    jne .Lch_probe_opus
    cmp word ptr [r9 + 4], 0x6962
    jne .Lch_probe_none
    cmp byte ptr [r9 + 6], 0x73
    jne .Lch_probe_none
    mov eax, 4
    ret
.Lch_probe_opus:
    mov rax, 0x646165487375704f      # OpusHead
    cmp [r9], rax
    jne .Lch_probe_flac
    mov eax, 5
    ret
.Lch_probe_flac:
    cmp dword ptr [r9], 0x414c467f   # 7f 'FLA'
    jne .Lch_probe_none
    cmp byte ptr [r9 + 4], 0x43      # 'C'
    jne .Lch_probe_none
    mov eax, 7
    ret
.Lch_probe_none:
    xor eax, eax
    ret
ENDFN chain_probe

# RCX=BOS page -> EAX=1 when its first packet begins an audio stream LAMP
# does not decode: Speex, CELT or OGM audio (counted by track_choice).
LOCALFN chain_other_audio
    xor eax, eax
    cmp byte ptr [rcx + 26], 0
    je .Lch_other_return
    cmp byte ptr [rcx + 27], 8            # the first lace: a header of 8 bytes or more
    jb .Lch_other_return
    movzx r8d, byte ptr [rcx + 26]
    lea r9, [rcx + r8 + 27]
    mov rdx, 0x2020207865657053           # "Speex   "
    cmp [r9], rdx
    je .Lch_other_yes
    mov rdx, 0x202020205443454c           # "CELT    "
    cmp [r9], rdx
    je .Lch_other_yes
    cmp dword ptr [r9], 0x64756101        # OGM: 01 "audio"
    jne .Lch_other_return
    cmp word ptr [r9 + 4], 0x6f69
    jne .Lch_other_return
.Lch_other_yes:
    mov eax, 1
.Lch_other_return:
    ret
ENDFN chain_other_audio

# RCX=mapped start, RDX=end -> EAX=1 when every link validated. Sets
# output_rate/output_frames, codec_kind and the link-0 format globals.
FN chain_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    call chain_close
    mov ecx, CH_CAP*CH_SIZE
    call mem_reserve
    test rax, rax
    jz .Lch_open_bad
    mov [rip + chain_links], rax
    mov r12, rax                     # current record
    xor r13d, r13d                   # links
    xor r14d, r14d                   # inside a BOS group
.Lch_scan:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lch_scan_continue
    cmp dword ptr [rax], 0
    jne .Lch_open_bad
.Lch_scan_continue:
    cmp rsi, rdi
    jae .Lch_scan_done
    mov rcx, rsi
    mov rdx, rdi
    call chain_page_end
    test rax, rax
    jz .Lch_open_bad
    mov r15, rax
    test byte ptr [rsi + 5], 2
    jz .Lch_scan_other
    test r14d, r14d
    jnz .Lch_scan_bos
    # A new link: close the previous record and commit room for this one.
    cmp r13d, CH_CAP
    jae .Lch_open_bad
    test r13d, r13d
    jz .Lch_scan_record
    mov [r12 + CH_END], rsi
    add r12, CH_SIZE
.Lch_scan_record:
    lea rax, [r12 + CH_SIZE]
    sub rax, [rip + chain_links]
    cmp rax, [rip + chain_committed]
    jbe .Lch_scan_committed
    mov rcx, [rip + chain_links]
    add rcx, [rip + chain_committed]
    mov edx, 65536
    call mem_commit
    test rax, rax
    jz .Lch_open_bad
    add qword ptr [rip + chain_committed], 65536
.Lch_scan_committed:
    inc r13d
    mov r14d, 1
    mov [r12 + CH_BEGIN], rsi
    mov dword ptr [r12 + CH_CODEC], 0
    mov dword ptr [r12 + CH_AUDIO_COUNT], 0
    mov dword ptr [rip + chain_serial_count], 0
    mov dword ptr [rip + chain_audio_index], 0
.Lch_scan_bos:
    # Each logical stream begins once per link.
    mov ecx, [rsi + 14]
    call chain_serial_find
    test eax, eax
    jns .Lch_open_bad
    mov eax, [rip + chain_serial_count]
    cmp eax, CH_STREAMS
    jae .Lch_open_bad
    lea rdx, [rip + chain_serials]
    mov ecx, [rsi + 14]
    mov [rdx + rax*4], ecx
    inc dword ptr [rip + chain_serial_count]
.Lch_scan_choice:
    mov rcx, rsi
    call chain_probe
    test eax, eax
    jnz .Lch_scan_audio
    mov rcx, rsi
    call chain_other_audio
    test eax, eax
    jz .Lch_scan_next
    xor eax, eax                     # audio LAMP does not decode
.Lch_scan_audio:
    inc dword ptr [rip + chain_audio_index]
    mov ecx, [rip + chain_audio_index]
    mov [r12 + CH_AUDIO_COUNT], ecx
    cmp dword ptr [rip + track_choice], 0
    jne .Lch_scan_numbered
    cmp dword ptr [r12 + CH_CODEC], 0
    jne .Lch_scan_next
    test eax, eax
    jz .Lch_scan_next
    jmp .Lch_scan_select
.Lch_scan_numbered:
    cmp ecx, [rip + track_choice]
    jne .Lch_scan_next
    mov dword ptr [rip + track_choice_used], 1
    test eax, eax
    jz .Lch_scan_next
.Lch_scan_select:
    cmp r13d, 1
    jne .Lch_scan_selected_ordinal
    mov ecx, [rip + chain_audio_index]
    mov [rip + audio_track_selected], ecx
.Lch_scan_selected_ordinal:
    mov [r12 + CH_CODEC], eax
    mov eax, [rsi + 14]
    mov [r12 + CH_SERIAL], eax
    jmp .Lch_scan_next
.Lch_scan_other:
    test r13d, r13d
    jz .Lch_open_bad                 # the stream must begin with a BOS page
    xor r14d, r14d
    mov ecx, [rsi + 14]
    call chain_serial_find
    test eax, eax
    js .Lch_open_bad                 # a page of a stream that never began
.Lch_scan_next:
    mov rsi, r15
    jmp .Lch_scan
.Lch_scan_done:
    test r13d, r13d
    jz .Lch_open_bad
    mov [r12 + CH_END], rdi
    mov [rip + chain_count], r13d
    # An explicit ordinal must exist in every link of the file. Publish
    # the minimum link count; the automatic ordinal describes link 0.
    mov eax, -1
    xor ecx, ecx
    mov rdx, [rip + chain_links]
.Lch_audio_count:
    cmp ecx, r13d
    jae .Lch_audio_counted
    cmp eax, [rdx + CH_AUDIO_COUNT]
    jbe .Lch_audio_count_next
    mov eax, [rdx + CH_AUDIO_COUNT]
.Lch_audio_count_next:
    add rdx, CH_SIZE
    inc ecx
    jmp .Lch_audio_count
.Lch_audio_counted:
    mov [rip + audio_tracks_count], eax
    # Open links last to first, so link 0 remains open. Each open validates
    # the whole link, including CRCs and timing.
    mov ebx, r13d
.Lch_open_link:
    test ebx, ebx
    jz .Lch_links_open
    dec ebx
    mov r12d, ebx
    shl r12, 6
    add r12, [rip + chain_links]
    cmp dword ptr [r12 + CH_CODEC], 0
    jne .Lch_open_codec
    cmp dword ptr [rip + track_choice], 0
    je .Lch_open_bad
    mov dword ptr [rip + decode_error], 101   # the chosen track is missing or unsupported
    jmp .Lch_open_bad
.Lch_open_codec:
    call chain_codec_close
    mov rcx, r12
    call chain_codec_open
    test eax, eax
    jz .Lch_open_bad
    mov [rip + chain_current], ebx
    mov rax, [rip + total_frames]
    mov [r12 + CH_SOURCE], rax
    mov eax, [rip + sample_rate]
    mov [r12 + CH_RATE], eax
    mov eax, [rip + source_channels]
    mov [r12 + CH_CHANNELS], eax
    mov eax, [rip + source_bits]
    mov [r12 + CH_BITS], eax
    jmp .Lch_open_link
.Lch_links_open:
    # Output frames per link: the source count, or ceil(N*out/in) resampled.
    mov r12, [rip + chain_links]
    mov r14d, [r12 + CH_RATE]
    mov [rip + output_rate], r14d
    xor r15d, r15d                   # running start
    xor ebx, ebx
.Lch_layout:
    cmp ebx, [rip + chain_count]
    jae .Lch_layout_done
    mov [r12 + CH_START], r15
    mov rax, [r12 + CH_SOURCE]
    mov ecx, [r12 + CH_RATE]
    cmp ecx, r14d
    je .Lch_layout_frames
    mul r14
    add rax, rcx
    adc rdx, 0
    sub rax, 1
    sbb rdx, 0
    cmp rdx, rcx
    jae .Lch_open_bad
    div rcx
.Lch_layout_frames:
    mov [r12 + CH_FRAMES], rax
    add r15, rax
    jc .Lch_open_bad
    add r12, CH_SIZE
    inc ebx
    jmp .Lch_layout
.Lch_layout_done:
    mov [rip + output_frames], r15
    mov rax, [rip + chain_links]
    mov eax, [rax + CH_CODEC]
    mov [rip + codec_kind], eax
    mov dword ptr [rip + chain_active], 1
    mov eax, 1
    jmp .Lch_open_return
.Lch_open_bad:
    call chain_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lch_open_failed
    mov dword ptr [rip + decode_error], 40
.Lch_open_failed:
    xor eax, eax
.Lch_open_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN chain_open

# ECX=link -> EAX=1 when it is open and ready at its start. The link must
# reproduce the duration and rate recorded at chain_open.
LOCALFN chain_switch
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, ecx
    call chain_codec_close
    mov esi, ebx
    shl rsi, 6
    add rsi, [rip + chain_links]
    mov rcx, rsi
    call chain_codec_open
    test eax, eax
    jz .Lch_switch_bad
    mov [rip + chain_current], ebx
    mov rax, [rip + total_frames]
    cmp rax, [rsi + CH_SOURCE]
    jne .Lch_switch_bad
    mov eax, [rip + sample_rate]
    cmp eax, [rsi + CH_RATE]
    jne .Lch_switch_bad
    mov eax, [rsi + CH_CODEC]
    mov [rip + codec_kind], eax
    mov dword ptr [rip + chain_resampling], 0
    mov ecx, [rsi + CH_RATE]
    cmp ecx, [rip + output_rate]
    je .Lch_switch_ready
    cmp ecx, [rip + chain_rs_rate]
    je .Lch_switch_reset
    mov dword ptr [rip + chain_rs_rate], 0
    mov edx, [rip + output_rate]
    lea r8, [rip + chain_codec_read]
    call resample_open
    test eax, eax
    jz .Lch_switch_bad
    mov eax, [rsi + CH_RATE]
    mov [rip + chain_rs_rate], eax
.Lch_switch_reset:
    xor ecx, ecx
    call resample_reset
    mov dword ptr [rip + chain_resampling], 1
.Lch_switch_ready:
    mov eax, 1
    jmp .Lch_switch_return
.Lch_switch_bad:
    call chain_codec_close
    cmp dword ptr [rip + decode_error], 0
    jne .Lch_switch_failed
    mov dword ptr [rip + decode_error], 41
.Lch_switch_failed:
    xor eax, eax
.Lch_switch_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN chain_switch

# RCX=stereo float output, EDX=frame capacity -> EAX=frames; 0 at the end of
# the last link or on error. Crosses link boundaries within one call.
FN chain_read
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    mov esi, edx
    xor ebx, ebx
.Lch_read_next:
    cmp ebx, esi
    jae .Lch_read_done
    cmp dword ptr [rip + chain_current], -1
    je .Lch_read_done
    lea rcx, [rdi + rbx*8]
    mov edx, esi
    sub edx, ebx
    cmp dword ptr [rip + chain_resampling], 0
    jne .Lch_read_resampled
    call chain_codec_read
    jmp .Lch_read_count
.Lch_read_resampled:
    call resample_read
.Lch_read_count:
    add ebx, eax
    test eax, eax
    jnz .Lch_read_next
    cmp dword ptr [rip + decode_error], 0
    jne .Lch_read_done
    mov ecx, [rip + chain_current]
    inc ecx
    cmp ecx, [rip + chain_count]
    jae .Lch_read_done
    call chain_switch
    test eax, eax
    jnz .Lch_read_next
.Lch_read_done:
    mov eax, ebx
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN chain_read

# RCX=output frame, on a freshly opened chain -> RAX=resume frame <= target.
FN chain_seek
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor eax, eax
    cmp dword ptr [rip + chain_current], 0
    jne .Lch_seek_return
    cmp rcx, [rip + output_frames]
    cmova rcx, [rip + output_frames]
    mov rdi, rcx
    # Last link whose start is at or before the target.
    xor r8d, r8d
    mov r9d, [rip + chain_count]
.Lch_seek_search:
    mov edx, r9d
    sub edx, r8d
    cmp edx, 1
    jbe .Lch_seek_found
    shr edx, 1
    add edx, r8d
    mov eax, edx
    shl rax, 6
    add rax, [rip + chain_links]
    cmp [rax + CH_START], rdi
    ja .Lch_seek_upper
    mov r8d, edx
    jmp .Lch_seek_search
.Lch_seek_upper:
    mov r9d, edx
    jmp .Lch_seek_search
.Lch_seek_found:
    mov ebx, r8d
    mov esi, ebx
    shl rsi, 6
    add rsi, [rip + chain_links]
    test ebx, ebx
    jz .Lch_seek_link_open
    mov ecx, ebx
    call chain_switch
    test eax, eax
    jz .Lch_seek_return
.Lch_seek_link_open:
    sub rdi, [rsi + CH_START]        # target within the link
    cmp dword ptr [rip + chain_resampling], 0
    jne .Lch_seek_resampled
    mov rcx, rdi
    call chain_codec_seek
    add rax, [rsi + CH_START]
    jmp .Lch_seek_return
.Lch_seek_resampled:
    # Seek the source a filter half-width before the target's input span.
    mov rax, rdi
    mov ecx, [rsi + CH_RATE]
    mul rcx
    mov ecx, [rip + output_rate]
    div rcx
    mov ecx, [rip + resample_half]
    inc rcx
    xor edx, edx
    sub rax, rcx
    cmovb rax, rdx
    test rax, rax
    jz .Lch_seek_reset
    mov rcx, rax
    call chain_codec_seek
    cmp dword ptr [rip + decode_error], 0
    jne .Lch_seek_failed
.Lch_seek_reset:
    mov rcx, rax
    call resample_reset
    add rax, [rsi + CH_START]
    jmp .Lch_seek_return
.Lch_seek_failed:
    xor eax, eax
.Lch_seek_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN chain_seek
