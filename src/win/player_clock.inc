# Original shared/exclusive engine clock publication. Included by player.s.
# Shared uses endpoint-consumed SUBMITTED frames, not a physical latency probe.
# Exclusive retains its hardware-position mapping. Neither extrapolates QPC.

# RCX=40B output. First24B matches video_sync's clock layout; see audio_clock.s.
FN engine_clock_snapshot
    mov rdx, rcx
    lea rcx, [rip+engine_clock_context]
    jmp audio_clock_read
ENDFN engine_clock_snapshot

LOCALFN pc_begin
    sub rsp, 72
    lea rcx, [rip+engine_clock_context]
    mov rax, [rcx+AC_EPOCH]
    add rax, 1
    jc .Lpc_begin_bad
    mov [rsp+32], rax
    mov rax, [rip+engine_seek_frames]
    mov [rsp+40], rax
    mov eax, [rip+queue_rate]
    mov [rsp+48], eax
    mov eax, [rip+engine_exclusive]
    test eax, eax
    setne al
    movzx eax, al
    mov [rsp+52], eax
    mov qword ptr [rsp+56], 0
    lea rdx, [rsp+32]
    call audio_clock_begin
    test eax, eax
    jz .Lpc_begin_bad
    xor eax, eax
    jmp .Lpc_begin_return
.Lpc_begin_bad:
    mov eax, 0x8000ffff
.Lpc_begin_return:
    add rsp, 72
    ret
ENDFN pc_begin

# R8D=state, with padding already read on this render thread.
LOCALFN pc_shared_position
    sub rsp, 40
    lea rcx, [rip+engine_clock_context]
    mov rdx, [rcx+AC_SUBMITTED]
    mov eax, [rip+padding]
    sub rdx, rax
    jc .Lpc_shared_bad
    call audio_clock_observe
    test eax, eax
    jz .Lpc_shared_bad
    mov rax, [rip+engine_clock_context+AC_MEDIA]
    mov [rip+engine_position], rax
    xor eax, eax
    jmp .Lpc_shared_return
.Lpc_shared_bad:
    mov eax, 0x8000ffff
.Lpc_shared_return:
    add rsp, 40
    ret
ENDFN pc_shared_position

# A refill at the exact end of the preceding real interval can immediately
# supply its contiguous successor. Refresh state at the SAME observed cursor;
# never subtract the old padding from the newly increased submitted count.
LOCALFN pc_shared_refresh
    cmp dword ptr [rip+audio_started], 0
    je .Lpc_refresh_idle
    sub rsp, 40
    lea rcx, [rip+engine_clock_context]
    mov rdx, [rcx+AC_DEVICE]
    xor r8d, r8d
    call audio_clock_observe
    test eax, eax
    jz .Lpc_refresh_bad
    xor eax, eax
    jmp .Lpc_refresh_return
.Lpc_refresh_bad:
    mov eax, 0x8000ffff
.Lpc_refresh_return:
    add rsp, 40
    ret
.Lpc_refresh_idle:
    xor eax, eax
    ret
ENDFN pc_shared_refresh

LOCALFN pc_started
    mov dword ptr [rip+audio_started], 1
    cmp dword ptr [rip+engine_exclusive], 0
    jne pc_exclusive_refresh
    jmp pc_shared_refresh
ENDFN pc_started

# The exclusive writer also publishes a new successor after reading the device
# cursor. Update availability without advancing that already observed position.
LOCALFN pc_exclusive_refresh
    cmp dword ptr [rip+audio_started], 0
    je .Lpc_refresh_idle
    sub rsp, 40
    mov r8d, AC_STARVED
    mov rax, [rip+exclusive_map_head]
    cmp rax, [rip+exclusive_map_tail]
    je .Lpc_ex_refresh_publish
    and eax, 63
    imul rax, rax, 24
    lea rdx, [rip+exclusive_map]
    add rdx, rax
    mov rax, [rip+exclusive_clock_frame]
    sub rax, [rdx]
    jb .Lpc_ex_refresh_publish
    cmp rax, [rdx+16]
    jae .Lpc_ex_refresh_publish
    mov r8d, AC_RUNNING
.Lpc_ex_refresh_publish:
    lea rcx, [rip+engine_clock_context]
    mov rdx, [rip+engine_position]
    call audio_clock_publish
    test eax, eax
    jz .Lpc_ex_refresh_bad
    xor eax, eax
    jmp .Lpc_ex_refresh_return
.Lpc_ex_refresh_bad:
    mov eax, 0x8000ffff
.Lpc_ex_refresh_return:
    add rsp, 40
    ret
ENDFN pc_exclusive_refresh

# Refresh after Stop, before reporting a frozen/terminal cursor. No second owner
# touches WASAPI; asynchronous readers only inspect the published memory page.
LOCALFN pc_pause_position
    sub rsp, 40
    mov dword ptr [rip+audio_started], 0
    cmp dword ptr [rip+engine_clock_context+AC_STATE], AC_ENDED
    jae .Lpc_pause_ok
    cmp dword ptr [rip+engine_exclusive], 0
    jne .Lpc_pause_exclusive
    mov rcx, [rip+client_obj]
    lea rdx, [rip+padding]
    mov rax, [rcx]
    call qword ptr [rax+48]
    test eax, eax
    js .Lpc_pause_return
    mov r8d, AC_PAUSED
    call pc_shared_position
    jmp .Lpc_pause_return
.Lpc_pause_exclusive:
    call exclusive_update_position
    test eax, eax
    js .Lpc_pause_return
    lea rcx, [rip+engine_clock_context]
    mov edx, AC_PAUSED
    call audio_clock_status
    test eax, eax
    jz .Lpc_pause_bad
.Lpc_pause_ok:
    xor eax, eax
    jmp .Lpc_pause_return
.Lpc_pause_bad:
    mov eax, 0x8000ffff
.Lpc_pause_return:
    add rsp, 40
    ret
ENDFN pc_pause_position

LOCALFN pc_ended
    sub rsp, 40
    cmp dword ptr [rip+engine_exclusive], 0
    jne .Lpc_ended_status
    mov r8d, AC_ENDED
    call pc_shared_position
    jmp .Lpc_ended_return
.Lpc_ended_status:
    lea rcx, [rip+engine_clock_context]
    mov edx, AC_ENDED
    call audio_clock_status
    test eax, eax
    jz .Lpc_ended_bad
    xor eax, eax
    jmp .Lpc_ended_return
.Lpc_ended_bad:
    mov eax, 0x8000ffff
.Lpc_ended_return:
    add rsp, 40
    ret
ENDFN pc_ended

LOCALFN pc_stopped
    sub rsp, 40
    lea rcx, [rip+engine_clock_context]
    cmp qword ptr [rcx+AC_EPOCH], 0
    je .Lpc_stopped_return
    mov edx, AC_FAILED
    cmp dword ptr [rip+audio_hresult], 0
    jne .Lpc_stopped_publish
    cmp dword ptr [rip+decode_error], 0
    jne .Lpc_stopped_publish
    cmp dword ptr [rcx+AC_STATE], AC_ENDED
    jae .Lpc_stopped_return
    mov edx, AC_STOPPED
.Lpc_stopped_publish:
    call audio_clock_status
.Lpc_stopped_return:
    add rsp, 40
    ret
ENDFN pc_stopped
