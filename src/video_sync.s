# Original bounded presentation queue and audio-master scheduler. MIT.
# No allocations, callbacks or OS/codec dependencies. Microsoft x64 ABI.
.include "lamp.inc"
.include "video_sync.inc"

# RCX=new/unowned VS_BYTES storage, RDX=late tolerance (0..1 second).
# Returns 1/0. Never reinitialize a context which still owns frame tokens.
FN video_sync_init
    cmp rdx, 1000000000
    ja .Lvs_init_bad
    mov r8, rcx
    xor eax, eax
    mov r9d, VS_BYTES/8
.Lvs_init_zero:
    mov [rcx], rax
    add rcx, 8
    dec r9d
    jnz .Lvs_init_zero
    mov [r8+VS_LATE], rdx
    mov eax, 1
    ret
.Lvs_init_bad:
    xor eax, eax
    ret
ENDFN video_sync_init

# RCX=context, RDX=new nonzero increasing epoch, R8=nonnegative seek target.
# Returns 1/0. Caller must drain/release all owned tokens before changing epoch.
FN video_sync_epoch
    cmp dword ptr [rcx+VS_COUNT], 0
    jne .Lvs_epoch_bad
    test rdx, rdx
    jz .Lvs_epoch_bad
    cmp rdx, [rcx+VS_EPOCH]
    jbe .Lvs_epoch_bad
    test r8, r8
    js .Lvs_epoch_bad
    cmp qword ptr [rcx+VS_LATE], 1000000000
    ja .Lvs_epoch_bad
    mov [rcx+VS_EPOCH], rdx
    mov [rcx+VS_TARGET], r8
    mov qword ptr [rcx+VS_CLOCK], 0
    mov dword ptr [rcx+VS_SEEN], 0
    mov qword ptr [rcx+VS_PRESENTED], 0
    mov qword ptr [rcx+VS_DROPPED], 0
    mov qword ptr [rcx+VS_LAST_PTS], 0
    mov dword ptr [rcx+VS_HAVE_PTS], 0
    mov eax, 1
    ret
.Lvs_epoch_bad:
    xor eax, eax
    ret
ENDFN video_sync_epoch

# RCX=context, RDX=32-byte descriptor {pts,duration,nonzero token,epoch}.
# 1 accepted (ownership transferred), 0 full, -1 invalid/stale/duplicate token.
# Sorted by PTS with stable equal timestamps; bounded insertion (32 entries).
FN video_sync_push
    push rbx
    push rsi
    mov r10, [rdx]
    mov r11, [rdx+8]
    test r11, r11
    jle .Lvs_push_bad
    mov rax, r10
    add rax, r11
    jo .Lvs_push_bad
    mov r8, [rdx+16]
    test r8, r8
    jz .Lvs_push_bad
    mov r9, [rdx+24]
    test r9, r9
    jz .Lvs_push_bad
    cmp r9, [rcx+VS_EPOCH]
    jne .Lvs_push_bad
    mov ebx, [rcx+VS_COUNT]
    cmp ebx, VS_CAPACITY
    ja .Lvs_push_bad
    xor eax, eax
    lea rsi, [rcx+VS_HEADER]
.Lvs_push_duplicate:
    cmp eax, ebx
    jae .Lvs_push_capacity
    cmp r8, [rsi+16]
    je .Lvs_push_bad
    add rsi, 32
    inc eax
    jmp .Lvs_push_duplicate
.Lvs_push_capacity:
    cmp ebx, VS_CAPACITY
    je .Lvs_push_full
    # Find insertion point before changing anything, then shift backwards.
    xor eax, eax
    lea rsi, [rcx+VS_HEADER]
.Lvs_push_find:
    cmp eax, ebx
    jae .Lvs_push_shift
    cmp r10, [rsi]
    jl .Lvs_push_shift
    add rsi, 32
    inc eax
    jmp .Lvs_push_find
.Lvs_push_shift:
    mov eax, ebx
    shl rax, 5
    lea rax, [rcx+rax+VS_HEADER]
.Lvs_push_move:
    cmp rax, rsi
    je .Lvs_push_store
    movdqu xmm0, [rax-32]
    movdqu xmm1, [rax-16]
    movdqu [rax], xmm0
    movdqu [rax+16], xmm1
    sub rax, 32
    jmp .Lvs_push_move
.Lvs_push_store:
    mov [rsi], r10
    mov [rsi+8], r11
    mov [rsi+16], r8
    mov [rsi+24], r9
    inc dword ptr [rcx+VS_COUNT]
    mov eax, 1
    jmp .Lvs_push_return
.Lvs_push_full:
    xor eax, eax
    jmp .Lvs_push_return
.Lvs_push_bad:
    mov eax, VS_ERROR
.Lvs_push_return:
    pop rsi
    pop rbx
    ret
ENDFN video_sync_push

# RCX=context, RDX=32-byte output; 1 transfers earliest frame to caller,
# 0 empty, -1 corrupt count. Used to release surfaces before seek/close.
FN video_sync_drain
    mov eax, [rcx+VS_COUNT]
    cmp eax, VS_CAPACITY
    ja .Lvs_drain_bad
    test eax, eax
    jz .Lvs_drain_return
    movdqu xmm0, [rcx+VS_HEADER]
    movdqu xmm1, [rcx+VS_HEADER+16]
    movdqu [rdx], xmm0
    movdqu [rdx+16], xmm1
    # Shared removal leaf; EAX=count. No retained reference to removed token.
.Lvs_remove:
    dec eax
    mov [rcx+VS_COUNT], eax
    lea r9, [rcx+VS_HEADER]
    mov r10d, eax
    test eax, eax
    jz .Lvs_remove_zero
.Lvs_remove_move:
    movdqu xmm0, [r9+32]
    movdqu xmm1, [r9+48]
    movdqu [r9], xmm0
    movdqu [r9+16], xmm1
    add r9, 32
    dec r10d
    jnz .Lvs_remove_move
.Lvs_remove_zero:
    pxor xmm0, xmm0
    movdqu [r9], xmm0
    movdqu [r9+16], xmm0
    mov eax, 1
.Lvs_drain_return:
    ret
.Lvs_drain_bad:
    mov eax, VS_ERROR
    ret
ENDFN video_sync_drain

# RCX=context, RDX=24-byte clock, R8=40-byte result.
# ERROR leaves context/result unchanged. Otherwise result is fully initialized.
# WAIT has positive wait_ns; EMPTY/HOLD have -1. PRESENT/DROP transfer ownership.
FN video_sync_select
    push rbx
    sub rsp, 32
    mov eax, [rcx+VS_COUNT]
    cmp eax, VS_CAPACITY
    ja .Lvs_select_bad
    mov r9, [rdx]
    test r9, r9
    jz .Lvs_select_bad
    cmp r9, [rcx+VS_EPOCH]
    jne .Lvs_select_bad
    mov r10, [rdx+8]
    test r10, r10
    js .Lvs_select_bad
    mov r11d, [rdx+16]
    cmp r11d, VS_STEP
    ja .Lvs_select_bad
    cmp dword ptr [rdx+20], 0
    jne .Lvs_select_bad
    cmp qword ptr [rcx+VS_LATE], 1000000000
    ja .Lvs_select_bad
    cmp dword ptr [rcx+VS_SEEN], 0
    je .Lvs_select_valid
    cmp r10, [rcx+VS_CLOCK]
    jl .Lvs_select_bad
.Lvs_select_valid:
    mov [rcx+VS_CLOCK], r10
    mov dword ptr [rcx+VS_SEEN], 1
    pxor xmm0, xmm0
    movdqu [r8], xmm0
    movdqu [r8+16], xmm0
    mov qword ptr [r8+32], -1
    cmp r11d, VS_PAUSED
    je .Lvs_select_hold
    cmp r11d, VS_STARVED
    je .Lvs_select_hold
    test eax, eax
    jz .Lvs_select_empty
    mov r9, [rcx+VS_HEADER]
    cmp dword ptr [rcx+VS_HAVE_PTS], 0
    je .Lvs_select_endpoint
    cmp r9, [rcx+VS_LAST_PTS]
    jl .Lvs_select_drop      # a delayed completion must never reverse the picture
.Lvs_select_endpoint:
    mov rdx, r9
    add rdx, [rcx+VS_HEADER+8] # validated end (exclusive) at insertion
    cmp rdx, [rcx+VS_TARGET]
    jle .Lvs_select_drop      # expired seek preroll, including negative PTS
    cmp r11d, VS_STEP
    je .Lvs_select_present   # exactly one remaining frame per step request
    cmp r9, r10
    jg .Lvs_select_wait
    cmp eax, 1
    jbe .Lvs_select_present  # retain/present last available frame, even if late
    cmp r10, [rcx+VS_HEADER+32]
    jl .Lvs_select_present   # do not drop into a gap before the next frame
    cmp r10, rdx
    jle .Lvs_select_present
    sub r10, rdx            # unsigned difference, may exceed INT64_MAX
    cmp r10, [rcx+VS_LATE]
    ja .Lvs_select_drop
.Lvs_select_present:
    mov ebx, VS_PRESENT
    mov [rcx+VS_LAST_PTS], r9
    mov dword ptr [rcx+VS_HAVE_PTS], 1
    cmp qword ptr [rcx+VS_PRESENTED], -1
    je .Lvs_select_transfer
    inc qword ptr [rcx+VS_PRESENTED]
    jmp .Lvs_select_transfer
.Lvs_select_drop:
    mov ebx, VS_DROP
    cmp qword ptr [rcx+VS_DROPPED], -1
    je .Lvs_select_transfer
    inc qword ptr [rcx+VS_DROPPED]
.Lvs_select_transfer:
    movdqu xmm0, [rcx+VS_HEADER]
    movdqu xmm1, [rcx+VS_HEADER+16]
    movdqu [r8], xmm0
    movdqu [r8+16], xmm1
    mov qword ptr [r8+32], 0
    call .Lvs_remove
    mov eax, ebx
    jmp .Lvs_select_return
.Lvs_select_wait:
    sub r9, r10             # both nonnegative here; cannot overflow
    mov [r8+32], r9
    xor eax, eax
    jmp .Lvs_select_return
.Lvs_select_empty:
    mov eax, VS_EMPTY
    jmp .Lvs_select_return
.Lvs_select_hold:
    mov eax, VS_HOLD
    jmp .Lvs_select_return
.Lvs_select_bad:
    mov eax, VS_ERROR
.Lvs_select_return:
    add rsp, 32
    pop rbx
    ret
ENDFN video_sync_select

# RCX=audible media sample position (u64), EDX=sample rate (1..768000).
# Floor(sample*1e9/rate), or -1 if invalid/outside signed nanoseconds.
# Includes neither queued/unheard PCM nor wall-clock extrapolation.
FN video_sync_sample_ns
    test edx, edx
    jz .Lvs_sample_bad
    cmp edx, 768000
    ja .Lvs_sample_bad
    mov r8d, edx
    mov rax, rcx
    mov r9d, 1000000000
    mul r9
    cmp rdx, r8
    jae .Lvs_sample_bad
    div r8
    test rax, rax
    js .Lvs_sample_bad
    ret
.Lvs_sample_bad:
    mov rax, -1
    ret
ENDFN video_sync_sample_ns
