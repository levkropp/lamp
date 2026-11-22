# Original bounded Ogg/Speex playback bridge. MIT, see LICENSE.
# Native three-band mono/stereo frame decoder; retained BSD notices apply.
# Structural duration scan at open; exact decoder snapshots are cached lazily
# at packet boundaries during playback. No full-file PCM allocation or decode.
.include "lamp.inc"
.include "speex_packet.inc"
.include "speex_decoder.inc"
.equ SPB_INDEX_CAP, 64
.equ SPB_INDEX_ITEM, SPXD_LIVE+32
.globl speex_index_count, speex_index_stride, speex_seek_raw
RODATA
spb_normalize: .float .000030517578125
.data
spb_active: .long 0
spb_frames: .long 0
spb_left: .long 0
spb_used: .long 0
spb_available: .long 0
spb_packet_eos: .long 0
spb_eof: .long 0
spb_index: .quad 0
speex_index_count: .long 0
speex_index_stride: .quad 16
speex_seek_raw: .quad 0
spb_raw: .quad 0
spb_skip: .quad 0
spb_end: .quad 0
spb_ordinal: .quad 0
.bss
.p2align 4
spb_header: .zero 32
spb_summary: .zero 32
spb_bits: .zero SPXB_SIZE
spb_audio: .zero 16
spb_checkpoint: .zero 16
spb_state: .zero SPXD_SIZE
spb_pcm: .zero 1280*4
.text
FN speex_close
    sub rsp, 40
    mov rcx, [rip+spb_index]
    test rcx, rcx
    jz .Lspb_close_reset
    call mem_free
.Lspb_close_reset:
    mov qword ptr [rip+spb_index], 0
    mov dword ptr [rip+speex_index_count], 0
    mov qword ptr [rip+speex_index_stride], 16
    mov qword ptr [rip+speex_seek_raw], 0
    mov dword ptr [rip+spb_active], 0
    mov dword ptr [rip+spb_available], 0
    mov dword ptr [rip+spb_used], 0
    mov dword ptr [rip+spb_left], 0
    mov dword ptr [rip+spb_eof], 0
    add rsp, 40
    ret
ENDFN speex_close

# RCX=comment, EDX=bytes. Bounded Vorbis-style vendor and comment strings.
LOCALFN spb_comments
    cmp edx, 8
    jb .Lspb_comments_bad
    lea r9, [rcx+rdx]
    mov eax, [rcx]
    add rcx, 4
    sub edx, 8
    cmp eax, edx
    ja .Lspb_comments_bad
    add rcx, rax
    mov r8d, [rcx]
    add rcx, 4
    cmp r8d, 65536
    ja .Lspb_comments_bad
.Lspb_comment:
    test r8d, r8d
    jz .Lspb_comments_ok
    mov rax, r9
    sub rax, rcx
    cmp rax, 4
    jb .Lspb_comments_bad
    mov edx, [rcx]
    add rcx, 4
    sub rax, 4
    cmp rdx, rax
    ja .Lspb_comments_bad
    add rcx, rdx
    dec r8d
    jmp .Lspb_comment
.Lspb_comments_ok:
    mov eax, 1
    ret
.Lspb_comments_bad:
    xor eax, eax
    ret
ENDFN spb_comments

LOCALFN spb_reset
    sub rsp, 40
    lea rcx, [rip+spb_state]
    mov edx, SPXD_SIZE
    mov r8d, [rip+spb_header+4]
    call spx_decoder_init
    test eax, eax
    jz .Lspb_reset_return
    mov [rip+spb_frames], eax
    lea rcx, [rip+spb_state]
    mov edx, [rip+spb_header+8]
    call spx_decoder_set_channels
.Lspb_reset_return:
    add rsp, 40
    ret
ENDFN spb_reset

# Header then bounded comments and at most64 additional header packets.
LOCALFN spb_headers
    push rbx
    sub rsp, 32
    call ogg_open
    test eax, eax
    jz .Lspb_headers_bad
    call ogg_next
    test rax, rax
    jz .Lspb_headers_bad
    mov rcx, rax
    lea r8, [rip+spb_header]
    call spx_header_parse
    test eax, eax
    jz .Lspb_headers_bad
    cmp dword ptr [rip+ogg_eos], 0
    jne .Lspb_headers_bad
    call ogg_next
    test rax, rax
    jz .Lspb_headers_bad
    mov rcx, rax
    call spb_comments
    test eax, eax
    jz .Lspb_headers_bad
    mov ebx, [rip+spb_header+20]
.Lspb_extra_header:
    cmp dword ptr [rip+ogg_eos], 0
    jne .Lspb_headers_bad
    test ebx, ebx
    jz .Lspb_headers_ready
    call ogg_next
    test rax, rax
    jz .Lspb_headers_bad
    dec ebx
    jmp .Lspb_extra_header
.Lspb_headers_ready:
    lea rcx, [rip+spb_audio]
    call ogg_checkpoint
    mov eax, 1
    jmp .Lspb_headers_return
.Lspb_headers_bad:
    xor eax, eax
.Lspb_headers_return:
    add rsp, 32
    pop rbx
    ret
ENDFN spb_headers

# Validate one whole packet; result count1..64, -1 otherwise. A shorter final
# packet may terminate before the declared frames/packet; other packets may not.
LOCALFN spb_packet
    sub rsp, 40
    mov r8d, [rip+spb_header+4]
    lea r9, [rip+spb_summary]
    call spx_packet_scan
    test eax, eax
    jle .Lspb_packet_bad
    cmp eax, [rip+spb_header+16]
    ja .Lspb_packet_bad
    je .Lspb_packet_return
    cmp dword ptr [rip+ogg_eos], 1
    je .Lspb_packet_return
.Lspb_packet_bad:
    mov eax, -1
.Lspb_packet_return:
    add rsp, 40
    ret
ENDFN spb_packet

# RCX=mapped beginning, RDX=end. Scan structure and granules; leave fresh
# decoder at the first audio packet. PCM is decoded only when requested.
FN speex_open
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
    call speex_close
    mov rcx, rsi
    mov rdx, rdi
    call spb_headers
    test eax, eax
    jz .Lspb_open_bad
    xor r12d, r12d                    # cumulative decoded samples
    xor r13d, r13d                    # positive granule origin
    xor r14d, r14d                    # inferred encoder priming
    xor ebx, ebx                      # first completed nonfinal audio page
.Lspb_scan:
    call ogg_next
    test rax, rax
    jz .Lspb_open_bad
    mov rcx, rax
    call spb_packet
    test eax, eax
    jle .Lspb_open_bad
    mov eax, [rip+spb_summary+4]
    add r12, rax
    jo .Lspb_open_bad
    cmp dword ptr [rip+ogg_packet_last], 1
    jne .Lspb_scan
    mov r15, [rip+ogg_granule]
    test r15, r15
    js .Lspb_open_bad
    test ebx, ebx
    jnz .Lspb_later_page
    cmp dword ptr [rip+ogg_eos], 1
    je .Lspb_single_final
    mov ebx, 1
    cmp r15, r12
    jb .Lspb_infer_skip
    mov r13, r15
    sub r13, r12
    jmp .Lspb_scan
.Lspb_infer_skip:
    mov r14, r12
    sub r14, r15
    jmp .Lspb_scan
.Lspb_later_page:
    mov rax, r12
    add rax, r13
    jo .Lspb_open_bad
    sub rax, r14
    jc .Lspb_open_bad
    cmp dword ptr [rip+ogg_eos], 1
    je .Lspb_final_page
    cmp r15, rax
    jne .Lspb_open_bad
    jmp .Lspb_scan
.Lspb_final_page:
    cmp r15, rax
    ja .Lspb_open_bad
    jmp .Lspb_scan_done
.Lspb_single_final:
    # A final-only page cannot distinguish encoder priming from final pad.
    # Use the standard encoder lookahead: NB40, WB143, UWB349 samples.
    cmp r15, r12
    jae .Lspb_single_origin
    mov r14d, 40
    mov ecx, [rip+spb_header+4]
.Lspb_single_delay:
    test ecx, ecx
    jz .Lspb_scan_done
    lea r14d, [r14*2+63]
    dec ecx
    jmp .Lspb_single_delay
.Lspb_single_origin:
    mov r13, r15
    sub r13, r12
.Lspb_scan_done:
    mov ecx, [rip+spb_header+4]
    mov eax, 40
    shl eax, cl                       # decoder lookahead
    add r14, rax
    jo .Lspb_open_bad
    mov [rip+spb_skip], r14
    mov rax, r15
    sub rax, r13
    jc .Lspb_open_bad
    add rax, r14
    jo .Lspb_open_bad
    cmp rax, r12
    cmova rax, r12                    # never manufacture unavailable tail
    mov [rip+spb_end], rax
    sub rax, r14
    jae .Lspb_total_ready
    xor eax, eax
.Lspb_total_ready:
    mov [rip+total_frames], rax
    mov eax, [rip+spb_header]
    mov [rip+sample_rate], eax
    mov eax, [rip+spb_header+8]
    mov [rip+source_channels], eax
    mov dword ptr [rip+source_bits], 0
    lea rcx, [rip+spb_audio]
    call ogg_resume
    test eax, eax
    jz .Lspb_open_bad
    call spb_reset
    test eax, eax
    jz .Lspb_open_bad
    mov qword ptr [rip+spb_raw], 0
    mov qword ptr [rip+spb_ordinal], 0
    mov ecx, SPB_INDEX_CAP*SPB_INDEX_ITEM
    call mem_alloc
    mov [rip+spb_index], rax           # optional; exact sequential seeks remain
    mov dword ptr [rip+spb_active], 1
    call spb_cache
    mov eax, 1
    jmp .Lspb_open_return
.Lspb_open_bad:
    call speex_close
    cmp dword ptr [rip+decode_error], 0
    jne .Lspb_open_error
    mov dword ptr [rip+decode_error], 110
.Lspb_open_error:
    mov qword ptr [rip+total_frames], 0
    xor eax, eax
.Lspb_open_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN speex_open

# Cache state BEFORE a packet. Forward-only insertion keeps points ordered
# through back-seeks. Compact even entries when full; preserve initial point.
LOCALFN spb_cache
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, [rip+spb_index]
    test rbx, rbx
    jz .Lspb_cache_done
    mov rax, [rip+speex_index_stride]
    dec rax
    test rax, [rip+spb_ordinal]
    jnz .Lspb_cache_done
    mov eax, [rip+speex_index_count]
    test eax, eax
    jz .Lspb_cache_room
    dec eax
    imul eax, eax, SPB_INDEX_ITEM
    mov rdx, [rip+spb_ordinal]
    cmp rdx, [rbx+rax+24]
    jbe .Lspb_cache_done
.Lspb_cache_room:
    cmp dword ptr [rip+speex_index_count], SPB_INDEX_CAP
    jb .Lspb_cache_store
    mov r12d, 1
.Lspb_cache_compact:
    imul eax, r12d, SPB_INDEX_ITEM*2
    lea rsi, [rbx+rax]
    imul eax, r12d, SPB_INDEX_ITEM
    lea rdi, [rbx+rax]
    mov ecx, SPB_INDEX_ITEM/8
    rep movsq
    inc r12d
    cmp r12d, SPB_INDEX_CAP/2
    jb .Lspb_cache_compact
    mov dword ptr [rip+speex_index_count], SPB_INDEX_CAP/2
    shl qword ptr [rip+speex_index_stride], 1
.Lspb_cache_store:
    mov eax, [rip+speex_index_count]
    imul eax, eax, SPB_INDEX_ITEM
    lea rdi, [rbx+rax]
    mov rcx, rdi
    call ogg_checkpoint
    mov rax, [rip+spb_raw]
    mov [rdi+16], rax
    mov rax, [rip+spb_ordinal]
    mov [rdi+24], rax
    add rdi, 32
    lea rsi, [rip+spb_state]
    mov ecx, SPXD_LIVE/8
    rep movsq
    inc dword ptr [rip+speex_index_count]
.Lspb_cache_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spb_cache

# RCX=presented target. Restore latest cached exact history <= raw target.
# Return presented resume position; caller discards to the requested sample.
FN speex_seek
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor eax, eax
    cmp dword ptr [rip+spb_active], 1
    jne .Lspb_seek_return
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Lspb_seek_continue
    cmp dword ptr [rax], 0
    jne .Lspb_seek_zero
.Lspb_seek_continue:
    cmp rcx, [rip+total_frames]
    cmova rcx, [rip+total_frames]
    add rcx, [rip+spb_skip]
    mov rbx, [rip+spb_index]
    test rbx, rbx
    jz .Lspb_seek_initial
    xor r8d, r8d
    mov r9d, [rip+speex_index_count]
.Lspb_seek_search:
    cmp r8d, r9d
    jae .Lspb_seek_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    imul eax, edx, SPB_INDEX_ITEM
    cmp [rbx+rax+16], rcx
    ja .Lspb_seek_upper
    lea r8d, [rdx+1]
    jmp .Lspb_seek_search
.Lspb_seek_upper:
    mov r9d, edx
    jmp .Lspb_seek_search
.Lspb_seek_found:
    test r8d, r8d
    jz .Lspb_seek_initial
    dec r8d
    imul eax, r8d, SPB_INDEX_ITEM
    add rbx, rax
    mov rcx, rbx
    call ogg_resume
    test eax, eax
    jz .Lspb_seek_bad
    mov rax, [rbx+16]
    mov [rip+spb_raw], rax
    mov rax, [rbx+24]
    mov [rip+spb_ordinal], rax
    lea rsi, [rbx+32]
    lea rdi, [rip+spb_state]
    mov ecx, SPXD_LIVE/8
    rep movsq
    jmp .Lspb_seek_ready
.Lspb_seek_initial:
    lea rcx, [rip+spb_audio]
    call ogg_resume
    test eax, eax
    jz .Lspb_seek_bad
    call spb_reset
    test eax, eax
    jz .Lspb_seek_bad
    mov qword ptr [rip+spb_raw], 0
    mov qword ptr [rip+spb_ordinal], 0
.Lspb_seek_ready:
    mov dword ptr [rip+spb_left], 0
    mov dword ptr [rip+spb_available], 0
    mov dword ptr [rip+spb_used], 0
    mov dword ptr [rip+spb_eof], 0
    mov rax, [rip+spb_raw]
    mov [rip+speex_seek_raw], rax
    sub rax, [rip+spb_skip]
    jae .Lspb_seek_return
.Lspb_seek_zero:
    xor eax, eax
    jmp .Lspb_seek_return
.Lspb_seek_bad:
    mov dword ptr [rip+decode_error], 112
    xor eax, eax
.Lspb_seek_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN speex_seek

# RCX=stereo normalized float output, EDX=frame capacity ->frames,0 EOF/error.
FN speex_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    test rdi, rdi
    jz .Lspb_read_return
    cmp dword ptr [rip+spb_active], 1
    jne .Lspb_read_return
    cmp dword ptr [rip+decode_error], 0
    jne .Lspb_read_return
.Lspb_read_loop:
    cmp ebx, r12d
    jae .Lspb_read_return
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Lspb_read_continue
    cmp dword ptr [rax], 0
    jne .Lspb_read_bad
.Lspb_read_continue:
    mov eax, [rip+spb_used]
    cmp eax, [rip+spb_available]
    jb .Lspb_emit
    cmp dword ptr [rip+spb_eof], 1
    je .Lspb_read_return
    cmp dword ptr [rip+spb_left], 0
    jne .Lspb_decode
    call spb_cache
    call ogg_next
    test rax, rax
    jz .Lspb_read_bad
    mov [rsp+32], rax
    mov [rsp+40], edx
    mov rcx, rax
    call spb_packet
    test eax, eax
    jle .Lspb_read_bad
    mov [rip+spb_left], eax
    mov eax, [rip+ogg_eos]
    mov [rip+spb_packet_eos], eax
    lea rcx, [rip+spb_bits]
    mov rdx, [rsp+32]
    mov r8d, [rsp+40]
    call spx_bits_init
    test eax, eax
    jz .Lspb_read_bad
    inc qword ptr [rip+spb_ordinal]
.Lspb_decode:
    lea rcx, [rip+spb_state]
    lea rdx, [rip+spb_bits]
    lea r8, [rip+spb_pcm]
    mov r9d, 1280
    call spx_decoder_frame
    cmp eax, [rip+spb_frames]
    jne .Lspb_read_bad
    mov r13, [rip+spb_raw]
    add [rip+spb_raw], rax
    mov [rip+spb_available], eax
    mov dword ptr [rip+spb_used], 0
    dec dword ptr [rip+spb_left]
    jnz .Lspb_read_trim
    cmp dword ptr [rip+spb_packet_eos], 1
    jne .Lspb_read_trim
    mov dword ptr [rip+spb_eof], 1
.Lspb_read_trim:
    mov rax, [rip+spb_skip]
    cmp r13, rax
    jae .Lspb_read_trim_end
    sub rax, r13
    mov ecx, [rip+spb_frames]
    cmp rax, rcx
    cmova rax, rcx
    mov [rip+spb_used], eax
.Lspb_read_trim_end:
    mov rax, [rip+spb_end]
    cmp rax, r13
    jbe .Lspb_read_trim_empty
    sub rax, r13
    mov ecx, [rip+spb_frames]
    cmp rax, rcx
    cmova rax, rcx
    jmp .Lspb_read_trim_count
.Lspb_read_trim_empty:
    xor eax, eax
.Lspb_read_trim_count:
    mov [rip+spb_available], eax
    cmp [rip+spb_used], eax
    jbe .Lspb_read_loop
    mov [rip+spb_used], eax
    jmp .Lspb_read_loop
.Lspb_emit:
    lea rsi, [rip+spb_pcm]
    cmp dword ptr [rip+spb_header+8], 1
    je .Lspb_emit_mono
    movq xmm0, [rsi+rax*8]
    movss xmm1, [rip+spb_normalize]
    shufps xmm1, xmm1, 0
    mulps xmm0, xmm1
    jmp .Lspb_emit_store
.Lspb_emit_mono:
    movss xmm0, [rsi+rax*4]
    mulss xmm0, [rip+spb_normalize]
    unpcklps xmm0, xmm0
.Lspb_emit_store:
    movq [rdi+rbx*8], xmm0
    inc dword ptr [rip+spb_used]
    inc ebx
    jmp .Lspb_read_loop
.Lspb_read_bad:
    cmp dword ptr [rip+decode_error], 0
    jne .Lspb_read_failed
    mov dword ptr [rip+decode_error], 111
.Lspb_read_failed:
    xor ebx, ebx                      # caller discards partial output on error
.Lspb_read_return:
    mov eax, ebx
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN speex_read
