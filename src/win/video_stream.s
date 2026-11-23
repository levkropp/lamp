# Original H.264 decode/display-order bridge. Microsoft x64 ABI. MIT.
.include "lamp.inc"
.include "h264.inc"
.include "video.inc"
.include "video_stream.inc"
.text

# RCX=zeroed512B stream, RDX=ready GPU, R8=preflighted parser metadata.
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

# Only call after the consumer's readback or presenter fence has completed.
# S_OK selects/retains one output; S_FALSE drains EOF; E_PENDING is retryable.
# Header/decode failures stick until close. At most17 inputs before an output.
FN win_video_stream_next
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
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
    mov eax, [rdi+WV_POOL]
    mov [rsi+HP_SURFACES], eax
    mov rcx, rsi
    call h264_next
    test eax, eax
    js .Lvs_invalid
    jnz .Lvs_have_input
    mov dword ptr [rbx+VS_EOF], 1
    jmp .Lvs_end
.Lvs_have_input:
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
    shl eax, 4
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
    shl eax, 4
    cmp r12, [rbx+rax+VS_QUEUE]
    jne .Lvs_invalid
    cmp r13d, [rbx+rax+VS_QUEUE+8]
    je .Lvs_invalid
    inc ecx
    jmp .Lvs_unique_next
.Lvs_enqueue:
    cmp ecx, 17
    jae .Lvs_invalid
    shl ecx, 4
    mov [rbx+rcx+VS_QUEUE], r12
    mov [rbx+rcx+VS_QUEUE+8], r13d
    mov eax, [rsi+HP_CURRENT_SLOT]
    cmp eax, [rdi+WV_POOL]
    jae .Lvs_invalid
    mov [rbx+rcx+VS_QUEUE+12], eax
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
    shl eax, 4
    cmp edx, [rbx+rax+VS_QUEUE+8]
    jle .Lvs_min_next
    mov edx, [rbx+rax+VS_QUEUE+8]
    mov r12d, ecx
.Lvs_min_next:
    inc ecx
    cmp ecx, [rbx+VS_COUNT]
    jb .Lvs_min
    mov r13d, r12d
    shl r13d, 4
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
    dec dword ptr [rbx+VS_COUNT]
    mov eax, [rbx+VS_COUNT]
    shl eax, 4
    movdqu xmm0, [rbx+rax+VS_QUEUE]
    movdqu [rbx+r13+VS_QUEUE], xmm0
    inc qword ptr [rbx+VS_OUTPUTS]
    xor eax, eax
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
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN win_video_stream_next

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
