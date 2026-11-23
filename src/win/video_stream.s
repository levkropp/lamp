# Original H.264 decode/display-order bridge. Microsoft x64 ABI. MIT.
.include "lamp.inc"
.include "h264.inc"
.include "video.inc"
.include "video_stream.inc"
.text

# RCX=zeroed1536B stream, RDX=ready GPU, R8=preflighted parser metadata.
# Parser may subsequently be closed/reopened in place before the first next.
# Sole owner of HP_HOLD_MASK. No other parser/decode/select caller while active.
FN win_video_stream_open
    cmp dword ptr [rcx+VS_READY], 0
    jne .Lvs_open_busy
    cmp dword ptr [rdx+WV_READY], 1
    jne .Lvs_open_invalid
    mov eax, [r8+HP_MAX_REORDER]
    cmp eax, 16
    ja .Lvs_open_invalid
    cmp eax, [r8+HP_MAX_BUFFER]
    ja .Lvs_open_invalid
    mov r9d, [r8+HP_MAX_BUFFER]
    cmp r9d, 16
    ja .Lvs_open_invalid
    test r9d, r9d
    jnz .Lvs_open_pool
    inc r9d
.Lvs_open_pool:
    add r9d, 2
    cmp [rdx+WV_POOL], r9d
    jb .Lvs_open_invalid
    cmp dword ptr [rdx+WV_POOL], 32
    ja .Lvs_open_invalid
    cmp dword ptr [r8+HP_HOLD_MASK], 0
    jne .Lvs_open_busy
    mov [rcx+VS_GPU], rdx
    mov [rcx+VS_PARSER], r8
    mov [rcx+VS_REORDER], eax
    mov dword ptr [rcx+VS_LAST], -1
    mov dword ptr [rcx+VS_READY], 1
    xor eax, eax
    ret
.Lvs_open_busy:
    mov eax, WV_UNEXPECTED
    ret
.Lvs_open_invalid:
    mov eax, WV_INVALID
    ret
ENDFN win_video_stream_open

# Optional parsed-picture source: fn(context,parser,packet80*) ->1picture,
# 0EOF,-1failure,2cooperative yield. Borrow both; no rebinding an active queue.
# Metadata follows video_mp4_next. Complete all GPU work before another call.
FN win_video_stream_set_source
    cmp dword ptr [rcx+VS_READY], 1
    jne .Lvs_source_invalid
    cmp dword ptr [rcx+VS_ERROR], 0
    jne .Lvs_source_invalid
    cmp dword ptr [rcx+VS_PENDING], 0
    jne .Lvs_source_invalid
    cmp dword ptr [rcx+VS_COUNT], 0
    jne .Lvs_source_invalid
    cmp qword ptr [rcx+VS_DECODED], 0
    jne .Lvs_source_invalid
    cmp qword ptr [rcx+VS_INPUT_FN], 0
    jne .Lvs_source_invalid
    test rdx, rdx
    jz .Lvs_source_invalid
    mov [rcx+VS_INPUT_FN], rdx
    mov [rcx+VS_INPUT_CONTEXT], r8
    xor eax, eax
    ret
.Lvs_source_invalid:
    mov eax, WV_INVALID
    ret
ENDFN win_video_stream_set_source

# Only call after the consumer's readback or presenter fence has completed.
# S_OK selects/retains one output; S_FALSE drains EOF; E_PENDING is retryable.
# Header/decode failures stick until close. At most17 inputs before an output.
FN win_video_stream_next
    mov dword ptr [rcx+VS_PEEK], 0
    jmp vs_next
ENDFN win_video_stream_next

# Same bounded pumping, but retain the old selection and every queue pin.
# S_OK exposes HEAD_PTS/HEAD_DURATION; next consumes this same picture.
FN win_video_stream_peek
    mov dword ptr [rcx+VS_PEEK], 1
    jmp vs_next
ENDFN win_video_stream_peek

LOCALFN vs_next
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov dword ptr [rbx+VS_BUDGET], 0
    cmp dword ptr [rbx+VS_READY], 1
    jne .Lvs_unexpected
    mov eax, [rbx+VS_ERROR]
    test eax, eax
    jnz .Lvs_return
    mov rsi, [rbx+VS_PARSER]
    mov rdi, [rbx+VS_GPU]
    mov rax, [rsi+HP_CANCEL]
    test rax, rax
    jz .Lvs_next
    cmp dword ptr [rax], 0
    jne .Lvs_cancelled
.Lvs_next:
    mov eax, [rbx+VS_COUNT]
    cmp eax, [rbx+VS_REORDER]
    ja .Lvs_pop
    cmp dword ptr [rbx+VS_EOF], 0
    jne .Lvs_end
    cmp dword ptr [rbx+VS_PENDING], 0
    jne .Lvs_parsed
    cmp dword ptr [rbx+VS_BUDGET], 32
    jae .Lvs_yield
    inc dword ptr [rbx+VS_BUDGET]
    mov eax, [rdi+WV_POOL]
    mov [rsi+HP_SURFACES], eax
    mov rax, [rbx+VS_INPUT_FN]
    test rax, rax
    jz .Lvs_annex_input
    mov rcx, [rbx+VS_INPUT_CONTEXT]
    mov rdx, rsi
    lea r8, [rbx+VS_PACKET]
    call rax
    cmp eax, 2
    je .Lvs_yield
    jmp .Lvs_input_result
.Lvs_annex_input:
    mov rcx, rsi
    call h264_next
.Lvs_input_result:
    test eax, eax
    js .Lvs_invalid
    jnz .Lvs_have_input
    mov dword ptr [rbx+VS_EOF], 1
    jmp .Lvs_end
.Lvs_have_input:
    cmp eax, 1
    jne .Lvs_invalid
    cmp qword ptr [rbx+VS_INPUT_FN], 0
    je .Lvs_input_valid
    mov rax, [rbx+VS_PACKET+40]
    test rax, rax
    jz .Lvs_invalid
    cmp qword ptr [rbx+VS_SOURCE_EPOCH], 0
    je .Lvs_input_epoch
    cmp rax, [rbx+VS_SOURCE_EPOCH]
    jne .Lvs_invalid
.Lvs_input_epoch:
    mov [rbx+VS_SOURCE_EPOCH], rax
    mov rax, [rbx+VS_PACKET+32]
    test rax, rax
    jle .Lvs_invalid
    add rax, [rbx+VS_PACKET+24]
    jo .Lvs_invalid
    mov eax, [rbx+VS_PACKET+48]
    test eax, -8 # EMPTY must already have been skipped by the source.
    jnz .Lvs_invalid
    mov rdx, [rbx+VS_PACKET+56]
    test rdx, rdx
    js .Lvs_invalid
    mov rax, [rbx+VS_PACKET+64]
    test rax, rax
    js .Lvs_invalid
    jnz .Lvs_input_shown
    test dword ptr [rbx+VS_PACKET+48], 2
    jz .Lvs_invalid
    jmp .Lvs_input_valid
.Lvs_input_shown:
    test dword ptr [rbx+VS_PACKET+48], 2
    jnz .Lvs_invalid
    add rax, rdx
    jo .Lvs_invalid
.Lvs_input_valid:
    mov dword ptr [rbx+VS_PENDING], 1
.Lvs_parsed:
    # A parsed new epoch stays intact while old pending pictures drain.
    cmp dword ptr [rbx+VS_COUNT], 0
    je .Lvs_decode
    mov rax, [rsi+HP_EPOCH]
    cmp rax, [rbx+VS_QUEUE]
    je .Lvs_decode
    cmp dword ptr [rsi+HP_FRAME_NAL], 5
    jne .Lvs_pop
    cmp dword ptr [rsi+HP_FRAME_NOOUTPUT], 0
    je .Lvs_pop
    xor ecx, ecx
.Lvs_drop:
    mov eax, ecx
    shl eax, 6
    mov edx, [rbx+rax+VS_QUEUE+12]
    btr [rsi+HP_HOLD_MASK], edx
    inc qword ptr [rbx+VS_DROPPED]
    inc ecx
    cmp ecx, [rbx+VS_COUNT]
    jb .Lvs_drop
    mov dword ptr [rbx+VS_COUNT], 0
.Lvs_decode:
    mov rcx, rdi
    lea rdx, [rsi+HP_DESC]
    call win_video_decode
    cmp eax, WV_PENDING
    je .Lvs_return
    test eax, eax
    js .Lvs_fail
    mov dword ptr [rbx+VS_PENDING], 0
    inc qword ptr [rbx+VS_DECODED]
    mov r12, [rsi+HP_EPOCH]
    mov r13d, [rsi+HP_OUTPUT_POC]
    cmp dword ptr [rbx+VS_HAVE_ORDER], 0
    je .Lvs_unique
    cmp r12, [rbx+VS_LAST_EPOCH]
    jb .Lvs_invalid
    ja .Lvs_unique
    cmp r13d, [rbx+VS_LAST_POC]
    jle .Lvs_invalid
.Lvs_unique:
    xor ecx, ecx
.Lvs_unique_next:
    cmp ecx, [rbx+VS_COUNT]
    jae .Lvs_enqueue
    mov eax, ecx
    shl eax, 6
    cmp r12, [rbx+rax+VS_QUEUE]
    jne .Lvs_invalid
    cmp r13d, [rbx+rax+VS_QUEUE+8]
    je .Lvs_invalid
    inc ecx
    jmp .Lvs_unique_next
.Lvs_enqueue:
    cmp ecx, 17
    jae .Lvs_invalid
    shl ecx, 6
    mov [rbx+rcx+VS_QUEUE], r12
    mov [rbx+rcx+VS_QUEUE+8], r13d
    mov eax, [rsi+HP_CURRENT_SLOT]
    cmp eax, [rdi+WV_POOL]
    jae .Lvs_invalid
    mov [rbx+rcx+VS_QUEUE+12], eax
    mov rdx, [rbx+VS_PACKET+24]
    mov [rbx+rcx+VS_QUEUE+16], rdx
    mov rdx, [rbx+VS_PACKET+32]
    mov [rbx+rcx+VS_QUEUE+24], rdx
    mov rdx, [rbx+VS_PACKET+40]
    mov [rbx+rcx+VS_QUEUE+32], rdx
    mov rdx, [rbx+VS_PACKET+48]
    mov [rbx+rcx+VS_QUEUE+40], rdx
    movdqu xmm0, [rbx+VS_PACKET+56]
    movdqu [rbx+rcx+VS_QUEUE+48], xmm0
    bts [rsi+HP_HOLD_MASK], eax
    inc dword ptr [rbx+VS_COUNT]
    jmp .Lvs_next
.Lvs_end:
    cmp dword ptr [rbx+VS_COUNT], 0
    jne .Lvs_pop
    mov eax, 1
    jmp .Lvs_return
.Lvs_pop:
    # Queue contains one epoch; choose signed minimum POC.
    xor r12d, r12d
    xor ecx, ecx
    mov edx, 0x7fffffff
.Lvs_min:
    mov eax, ecx
    shl eax, 6
    cmp edx, [rbx+rax+VS_QUEUE+8]
    jle .Lvs_min_next
    mov edx, [rbx+rax+VS_QUEUE+8]
    mov r12d, ecx
.Lvs_min_next:
    inc ecx
    cmp ecx, [rbx+VS_COUNT]
    jb .Lvs_min
    mov r13d, r12d
    shl r13d, 6
    test dword ptr [rbx+r13+VS_QUEUE+40], 2
    jnz .Lvs_hidden
    mov rax, [rbx+r13+VS_QUEUE+48]
    mov [rbx+VS_HEAD_PTS], rax
    mov rdx, [rbx+r13+VS_QUEUE+56]
    mov [rbx+VS_HEAD_DURATION], rdx
    cmp dword ptr [rbx+VS_PEEK], 0
    jne .Lvs_peek_ready
    cmp qword ptr [rbx+VS_INPUT_FN], 0
    je .Lvs_select
    cmp dword ptr [rbx+VS_HAVE_TIME], 0
    je .Lvs_select
    cmp rax, [rbx+VS_SHOW_PTS]
    jl .Lvs_invalid
.Lvs_select:
    mov edx, [rbx+r13+VS_QUEUE+12]
    mov rcx, rdi
    call win_video_select
    cmp eax, WV_PENDING
    je .Lvs_return
    test eax, eax
    js .Lvs_fail
    mov eax, [rbx+VS_LAST]
    test eax, eax
    js .Lvs_selected
    btr [rsi+HP_HOLD_MASK], eax
.Lvs_selected:
    mov eax, [rbx+r13+VS_QUEUE+12]
    mov [rbx+VS_LAST], eax
    mov rax, [rbx+r13+VS_QUEUE]
    mov [rbx+VS_LAST_EPOCH], rax
    mov eax, [rbx+r13+VS_QUEUE+8]
    mov [rbx+VS_LAST_POC], eax
    mov dword ptr [rbx+VS_HAVE_ORDER], 1
    mov rax, [rbx+r13+VS_QUEUE+16]
    mov [rbx+VS_PTS], rax
    mov rax, [rbx+r13+VS_QUEUE+24]
    mov [rbx+VS_DURATION], rax
    mov rax, [rbx+r13+VS_QUEUE+32]
    mov [rbx+VS_EXTERNAL_EPOCH], rax
    mov rax, [rbx+r13+VS_QUEUE+40]
    mov [rbx+VS_FLAGS], rax # flags and index pair.
    mov rax, [rbx+r13+VS_QUEUE+48]
    mov [rbx+VS_SHOW_PTS], rax
    mov rdx, [rbx+r13+VS_QUEUE+56]
    mov [rbx+VS_SHOW_DURATION], rdx
    add rax, rdx
    cmp rax, [rbx+VS_LAST_SHOW_END]
    cmovb rax, [rbx+VS_LAST_SHOW_END]
    mov [rbx+VS_LAST_SHOW_END], rax
    mov dword ptr [rbx+VS_HAVE_TIME], 1
    inc qword ptr [rbx+VS_OUTPUTS]
.Lvs_remove:
    dec dword ptr [rbx+VS_COUNT]
    mov eax, [rbx+VS_COUNT]
    shl eax, 6
    movdqu xmm0, [rbx+rax+VS_QUEUE]
    movdqu [rbx+r13+VS_QUEUE], xmm0
    movdqu xmm0, [rbx+rax+VS_QUEUE+16]
    movdqu [rbx+r13+VS_QUEUE+16], xmm0
    movdqu xmm0, [rbx+rax+VS_QUEUE+32]
    movdqu [rbx+r13+VS_QUEUE+32], xmm0
    movdqu xmm0, [rbx+rax+VS_QUEUE+48]
    movdqu [rbx+r13+VS_QUEUE+48], xmm0
    test dword ptr [rbx+VS_PEEK], 2
    jz .Lvs_peek_ready
    and dword ptr [rbx+VS_PEEK], 1
    jmp .Lvs_next
.Lvs_peek_ready:
    xor eax, eax
    jmp .Lvs_return
.Lvs_hidden:
    mov eax, [rbx+r13+VS_QUEUE+12]
    btr [rsi+HP_HOLD_MASK], eax
    mov rax, [rbx+r13+VS_QUEUE]
    mov [rbx+VS_LAST_EPOCH], rax
    mov eax, [rbx+r13+VS_QUEUE+8]
    mov [rbx+VS_LAST_POC], eax
    mov dword ptr [rbx+VS_HAVE_ORDER], 1
    inc qword ptr [rbx+VS_HIDDEN]
    # Preserve whether the caller requested peek across hidden removals.
    or dword ptr [rbx+VS_PEEK], 2
    jmp .Lvs_remove
.Lvs_yield:
    mov eax, WV_PENDING
    jmp .Lvs_return
.Lvs_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lvs_return
.Lvs_invalid:
    mov eax, WV_INVALID
    jmp .Lvs_fail
.Lvs_cancelled:
    mov eax, 0x80004004
.Lvs_fail:
    mov [rbx+VS_ERROR], eax
.Lvs_return:
    # A successful decode changes the backend's current slice. Peek must leave
    # the retained displayed slice selected, including cooperative-yield/EOF.
    cmp dword ptr [rbx+VS_PEEK], 0
    je .Lvs_return_regs
    test eax, eax
    jns .Lvs_restore_selection
    cmp eax, WV_PENDING
    jne .Lvs_return_regs
.Lvs_restore_selection:
    mov edx, [rbx+VS_LAST]
    test edx, edx
    js .Lvs_return_regs
    mov rcx, [rbx+VS_GPU]
    cmp dword ptr [rcx+WV_READY], 1
    jne .Lvs_return_regs
    mov [rcx+WV_CURRENT], edx
    mov dword ptr [rcx+WV_HAVE_FRAME], 1
.Lvs_return_regs:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vs_next

# Consumer must finish all GPU reads first. Borrowed GPU/parser remain alive.
FN win_video_stream_close
    cmp dword ptr [rcx+VS_READY], 1
    jne .Lvs_close_zero
    mov rax, [rcx+VS_PARSER]
    mov dword ptr [rax+HP_HOLD_MASK], 0
.Lvs_close_zero:
    mov rdx, rcx
    xor eax, eax
    mov ecx, VS_BYTES/8
.Lvs_zero:
    mov [rdx], rax
    add rdx, 8
    dec ecx
    jnz .Lvs_zero
    ret
ENDFN win_video_stream_close
