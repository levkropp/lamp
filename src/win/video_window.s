# Original native video window with nominal video-only clock, pause and step.
# No audio device, software codec, CPU conversion or unbounded busy wait. MIT.
.include "lamp.inc"
.include "h264.inc"
.include "video.inc"
.include "video_stream.inc"
.include "video_present.inc"
.include "video_window.inc"
RODATA
vw_class_name: .short 'L','A','M','P','V','i','d','e','o',0
vw_title: .short 'L','A','M','P',' ','v','i','d','e','o',' ','-',' ','S','p','a','c','e',' ','p','a','u','s','e',',',' ','.',' ','s','t','e','p',',',' ','E','s','c',' ','c','l','o','s','e',0
vw_title_paused: .short 'L','A','M','P',' ','v','i','d','e','o',' ','-',' ','P','a','u','s','e','d',0
vw_title_eof: .short 'L','A','M','P',' ','v','i','d','e','o',' ','-',' ','F','i','n','i','s','h','e','d',' ','(','S','p','a','c','e',' ','r','e','p','l','a','y','s',')',0
.text

# RCX=GPU, RDX=preflighted parser, R8=info56B:
# {data,size,cancelDWORD*,totalFrames:u64,show:u32,reserved:u32,report*,event}.
# report64B (optional): HWND,played:u64,paused/eof/error/width/height/steps:u32,
# media_ns:i64,late:u64. show0 is offscreen hosting; show1/4 normal/no-activate.
# S_OK on own-window close, E_ABORT on external cancellation, error otherwise.
FN win_video_play
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 104
    mov rsi, rcx
    mov rdi, rdx
    mov r12, r8
    mov ecx, VW_BYTES
    call mem_alloc
    test rax, rax
    jz .Lvw_no_memory
    mov rbx, rax
    mov [rbx+VW_GPU], rsi
    mov [rbx+VW_PARSER], rdi
    mov [rbx+VW_INFO], r12
    mov rax, [r12+40]
    mov [rbx+VW_REPORT], rax
    cmp dword ptr [r12+36], 0
    jne .Lvw_invalid
    cmp qword ptr [r12+24], 0
    je .Lvw_invalid
    mov eax, [r12+32]
    cmp eax, 0
    je .Lvw_show_ok
    cmp eax, 1
    je .Lvw_show_ok
    cmp eax, 4
    jne .Lvw_invalid
.Lvw_show_ok:
    mov [rbx+VW_SHOW], eax
    mov eax, [rdi+HP_TIME_TICK]
    mov edx, [rdi+HP_TIME_SCALE]
    test eax, eax
    jz .Lvw_default_rate
    test edx, edx
    jz .Lvw_default_rate
    imul rax, rax, 480
    cmp rdx, rax            # upper bound240fps, no lower-rate busy polling
    ja .Lvw_unsupported
    mov eax, [rdi+HP_TIME_TICK]
    mov ecx, 2000000000
    imul rax, rcx
    mov [rbx+VW_PERIOD_NUM], rax
    mov [rbx+VW_PERIOD_DEN], rdx
    jmp .Lvw_duration
.Lvw_default_rate:
    mov qword ptr [rbx+VW_PERIOD_NUM], 1000000000
    mov qword ptr [rbx+VW_PERIOD_DEN], 24
.Lvw_duration:
    mov rcx, rbx
    mov rax, [r12+24]
    call vw_frame_ns
    test rax, rax
    js .Lvw_unsupported
    mov [rbx+VW_DURATION], rax
    lea rcx, [rbx+VW_FREQ]
    call QueryPerformanceFrequency
    test eax, eax
    jz .Lvw_unexpected
    cmp qword ptr [rbx+VW_FREQ], 0
    jle .Lvw_unexpected
    xor ecx, ecx
    call GetModuleHandleW
    mov [rbx+VW_INSTANCE], rax
    mov dword ptr [rbx+VW_CLASS], 80
    mov dword ptr [rbx+VW_CLASS+4], 3
    lea rax, [rip+vw_proc]
    mov [rbx+VW_CLASS+8], rax
    mov rax, [rbx+VW_INSTANCE]
    mov [rbx+VW_CLASS+24], rax
    lea rax, [rip+vw_class_name]
    mov [rbx+VW_CLASS+64], rax
    mov rcx, [rbx+VW_INSTANCE]
    mov edx, 101
    call LoadIconW
    mov [rbx+VW_CLASS+32], rax
    mov [rbx+VW_CLASS+72], rax
    xor ecx, ecx
    mov edx, 32512
    call LoadCursorW
    mov [rbx+VW_CLASS+40], rax
    lea rcx, [rbx+VW_CLASS]
    call RegisterClassExW
    test eax, eax
    jnz .Lvw_registered
    call GetLastError
    cmp eax, 1410
    jne .Lvw_unexpected
    jmp .Lvw_create
.Lvw_registered:
    mov dword ptr [rbx+VW_REGISTERED], 1
.Lvw_create:
    mov dword ptr [rbx+VW_RECT+8], 960
    mov dword ptr [rbx+VW_RECT+12], 540
    lea rcx, [rbx+VW_RECT]
    mov edx, 0x00cf0000
    xor r8d, r8d
    xor r9d, r9d
    call AdjustWindowRectEx
    test eax, eax
    jz .Lvw_unexpected
    xor ecx, ecx
    lea rdx, [rip+vw_class_name]
    lea r8, [rip+vw_title]
    mov r9d, 0x00cf0000
    mov qword ptr [rsp+32], -2147483648
    mov qword ptr [rsp+40], -2147483648
    mov eax, [rbx+VW_RECT+8]
    sub eax, [rbx+VW_RECT]
    mov [rsp+48], rax
    mov eax, [rbx+VW_RECT+12]
    sub eax, [rbx+VW_RECT+4]
    mov [rsp+56], rax
    mov qword ptr [rsp+64], 0
    mov qword ptr [rsp+72], 0
    mov rax, [rbx+VW_INSTANCE]
    mov [rsp+80], rax
    mov [rsp+88], rbx
    call CreateWindowExW
    test rax, rax
    jz .Lvw_unexpected
    mov [rbx+VW_HWND], rax
    mov rcx, rax
    lea rdx, [rbx+VW_RECT]
    call GetClientRect
    test eax, eax
    jz .Lvw_unexpected
    mov eax, [rbx+VW_RECT+8]
    mov [rbx+VW_WANTED_W], eax
    mov eax, [rbx+VW_RECT+12]
    mov [rbx+VW_WANTED_H], eax
    mov rcx, rbx
    call vw_target
    lea rcx, [rbx+VW_PRESENT]
    mov rdx, rsi
    mov r8, rdi
    lea r9, [rbx+VW_TARGET]
    call win_present_open
    test eax, eax
    js .Lvw_failed
    mov dword ptr [rbx+VW_RESIZE], 0
    mov rcx, rbx
    call vw_restart
    test eax, eax
    jz .Lvw_unexpected
    mov rcx, [rbx+VW_HWND]
    mov edx, [rbx+VW_SHOW]
    call ShowWindow
    mov rcx, [rbx+VW_HWND]
    call UpdateWindow
.Lvw_loop:
    cmp dword ptr [rbx+VW_CLOSED], 0
    jne .Lvw_normal_close
    mov rax, [r12+16]
    test rax, rax
    jz .Lvw_pump
    cmp dword ptr [rax], 0
    jne .Lvw_cancel
.Lvw_pump:
    lea rcx, [rbx+VW_MSG]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+32], 1
    call PeekMessageW
    test eax, eax
    jz .Lvw_commands
    cmp dword ptr [rbx+VW_MSG+8], 0x12 # host WM_QUIT: do not trap the host loop
    je .Lvw_host_quit
    lea rcx, [rbx+VW_MSG]
    call TranslateMessage
    lea rcx, [rbx+VW_MSG]
    call DispatchMessageW
    jmp .Lvw_loop
.Lvw_commands:
    cmp dword ptr [rbx+VW_STAGE], 0
    jne .Lvw_inflight
    cmp dword ptr [rbx+VW_TOGGLE], 0
    je .Lvw_step_command
    mov dword ptr [rbx+VW_TOGGLE], 0
    cmp dword ptr [rbx+VW_EOF], 0
    je .Lvw_toggle_pause
    mov rcx, rbx
    call vw_restart
    test eax, eax
    jz .Lvw_unexpected
    jmp .Lvw_title_update
.Lvw_toggle_pause:
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_BASE_NS], rax
    xor dword ptr [rbx+VW_PAUSED], 1
    mov rcx, rbx
    call vw_anchor
    test eax, eax
    jz .Lvw_unexpected
.Lvw_title_update:
    mov rcx, rbx
    call vw_title_set
.Lvw_step_command:
    cmp dword ptr [rbx+VW_STEP], 0
    je .Lvw_visibility
    cmp dword ptr [rbx+VW_PAUSED], 0
    jne .Lvw_visibility
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_BASE_NS], rax
    mov dword ptr [rbx+VW_PAUSED], 1
    mov rcx, rbx
    call vw_title_set
.Lvw_visibility:
    cmp dword ptr [rbx+VW_MINIMIZED], 0
    jne .Lvw_suspend
    cmp dword ptr [rbx+VW_PRESENT+VP_OCCLUDED], 0
    je .Lvw_resume_visibility
    cmp dword ptr [rbx+VW_SHOW], 0 # offscreen hosts still render their frames
    je .Lvw_resume_visibility
    lea rcx, [rbx+VW_PRESENT]
    call win_present_visible
    test eax, eax
    js .Lvw_failed
    cmp eax, 0x087a0001
    je .Lvw_suspend
    mov dword ptr [rbx+VW_PRESENT+VP_OCCLUDED], 0
.Lvw_resume_visibility:
    cmp dword ptr [rbx+VW_SUSPENDED], 0
    je .Lvw_resize
    mov dword ptr [rbx+VW_SUSPENDED], 0
    mov rcx, rbx
    call vw_anchor
    test eax, eax
    jz .Lvw_unexpected
    mov dword ptr [rbx+VW_REDRAW], 1
.Lvw_resize:
    cmp dword ptr [rbx+VW_RESIZE], 0
    je .Lvw_redraw
    mov dword ptr [rbx+VW_RESIZE], 0
    mov rcx, rbx
    call vw_target
    lea rcx, [rbx+VW_PRESENT]
    mov edx, [rbx+VW_TARGET+8]
    mov r8d, [rbx+VW_TARGET+12]
    call win_present_resize
    test eax, eax
    js .Lvw_failed
    mov dword ptr [rbx+VW_REDRAW], 1
.Lvw_redraw:
    cmp dword ptr [rbx+VW_REDRAW], 0
    je .Lvw_choose
    mov dword ptr [rbx+VW_REDRAW], 0
    cmp dword ptr [rbx+VW_HAS_FRAME], 0
    je .Lvw_choose
    mov dword ptr [rbx+VW_REDRAW_PENDING], 1
    mov dword ptr [rbx+VW_STAGE], 2
    call GetTickCount64
    add rax, 5000
    mov [rbx+VW_DEADLINE], rax
    jmp .Lvw_render
.Lvw_choose:
    mov rax, [rbx+VW_STREAM+VS_OUTPUTS]
    cmp rax, [r12+24]
    ja .Lvw_invalid
    cmp dword ptr [rbx+VW_SOURCE_EOF], 0
    jne .Lvw_clock_end
    # Preflight counted every input. Once all are decoded and output is drained,
    # a paused last-frame step can reach EOF without requesting another step.
    mov rdx, [rbx+VW_STREAM+VS_DECODED]
    cmp rdx, [r12+24]
    jne .Lvw_frame_available
    cmp dword ptr [rbx+VW_STREAM+VS_COUNT], 0
    jne .Lvw_frame_available
    cmp dword ptr [rbx+VW_STREAM+VS_PENDING], 0
    jne .Lvw_frame_available
    mov dword ptr [rbx+VW_SOURCE_EOF], 1
    mov rcx, rbx
    call vw_frame_ns
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_DURATION], rax
.Lvw_clock_end:
    cmp dword ptr [rbx+VW_EOF], 0
    jne .Lvw_hold
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    cmp dword ptr [rbx+VW_PAUSED], 0
    jne .Lvw_eof
    cmp rax, [rbx+VW_DURATION]
    jb .Lvw_wait_end
    mov rax, [rbx+VW_DURATION]
.Lvw_eof:
    mov rax, [rbx+VW_DURATION]
    mov [rbx+VW_BASE_NS], rax
    mov dword ptr [rbx+VW_EOF], 1
    mov dword ptr [rbx+VW_PAUSED], 1
    mov dword ptr [rbx+VW_STEP], 0
    mov rcx, rbx
    call vw_title_set
    jmp .Lvw_hold
.Lvw_wait_end:
    mov rdx, [rbx+VW_DURATION]
    sub rdx, rax
    jmp .Lvw_wait_delta
.Lvw_frame_available:
    mov rcx, rbx
    call vw_frame_ns
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_DUE], rax
    mov dword ptr [rbx+VW_IS_STEP], 0
    cmp dword ptr [rbx+VW_PAUSED], 0
    je .Lvw_running_due
    cmp dword ptr [rbx+VW_HAS_FRAME], 0
    je .Lvw_parse
    cmp dword ptr [rbx+VW_STEP], 0
    je .Lvw_hold
    mov dword ptr [rbx+VW_IS_STEP], 1
    mov rax, [rbx+VW_DUE]
    mov [rbx+VW_BASE_NS], rax
    jmp .Lvw_parse
.Lvw_running_due:
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    cmp rax, [rbx+VW_DUE]
    jae .Lvw_parse
    mov rdx, [rbx+VW_DUE]
    sub rdx, rax
.Lvw_wait_delta:
    mov rax, rdx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    inc rax
    cmp rax, 250
    jbe .Lvw_wait_set
    mov eax, 250
.Lvw_wait_set:
    mov [rbx+VW_WAIT_MS], eax
    jmp .Lvw_wait
.Lvw_parse:
    mov dword ptr [rbx+VW_STAGE], 1
    call GetTickCount64
    add rax, 5000
    mov [rbx+VW_DEADLINE], rax
.Lvw_inflight:
    cmp dword ptr [rbx+VW_STAGE], 1
    jne .Lvw_render
    lea rcx, [rbx+VW_STREAM]
    call win_video_stream_next
    cmp eax, WV_PENDING
    je .Lvw_retry
    test eax, eax
    js .Lvw_failed
    cmp eax, 1
    je .Lvw_source_end
    mov dword ptr [rbx+VW_STAGE], 2
    call GetTickCount64
    add rax, 5000
    mov [rbx+VW_DEADLINE], rax
.Lvw_render:
    lea rcx, [rbx+VW_PRESENT]
    call win_present_frame
    cmp eax, WV_PENDING
    je .Lvw_retry
    test eax, eax
    js .Lvw_failed
    mov dword ptr [rbx+VW_STAGE], 0
    cmp dword ptr [rbx+VW_REDRAW_PENDING], 0
    jne .Lvw_redrawn
    inc qword ptr [rbx+VW_PRESENTED]
    mov dword ptr [rbx+VW_HAS_FRAME], 1
    cmp dword ptr [rbx+VW_IS_STEP], 0
    je .Lvw_frame_clock
    inc qword ptr [rbx+VW_STEPS]
    mov dword ptr [rbx+VW_STEP], 0
.Lvw_frame_clock:
    cmp dword ptr [rbx+VW_STARTED], 0
    jne .Lvw_frame_late
    mov dword ptr [rbx+VW_STARTED], 1
    mov rcx, rbx
    call vw_anchor
    test eax, eax
    jz .Lvw_unexpected
    jmp .Lvw_sync_again
.Lvw_frame_late:
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    sub rax, [rbx+VW_DUE]
    jle .Lvw_sync_again
    mov rbp, rax
    mov rcx, rbx
    mov eax, 1
    call vw_frame_ns
    cmp rbp, rax
    jbe .Lvw_sync_again
    inc qword ptr [rbx+VW_LATE]
    jmp .Lvw_sync_again
.Lvw_redrawn:
    mov dword ptr [rbx+VW_REDRAW_PENDING], 0
.Lvw_sync_again:
    mov rcx, rbx
    call vw_sync
    jmp .Lvw_loop
.Lvw_source_end:
    mov dword ptr [rbx+VW_STAGE], 0
    mov dword ptr [rbx+VW_SOURCE_EOF], 1
    mov rcx, rbx
    mov rax, [rbx+VW_STREAM+VS_OUTPUTS]
    call vw_frame_ns
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_DURATION], rax
    jmp .Lvw_choose
.Lvw_retry:
    call GetTickCount64
    cmp rax, [rbx+VW_DEADLINE]
    jae .Lvw_unexpected
    mov dword ptr [rbx+VW_WAIT_MS], 1
    jmp .Lvw_wait
.Lvw_suspend:
    cmp dword ptr [rbx+VW_SUSPENDED], 0
    jne .Lvw_hold_poll
    mov rcx, rbx
    call vw_now
    test rax, rax
    js .Lvw_unexpected
    mov [rbx+VW_BASE_NS], rax
    mov dword ptr [rbx+VW_SUSPENDED], 1
.Lvw_hold_poll:
    mov dword ptr [rbx+VW_WAIT_MS], 250
    cmp dword ptr [rbx+VW_MINIMIZED], 0
    je .Lvw_wait
    cmp qword ptr [r12+48], 0
    je .Lvw_wait
    mov dword ptr [rbx+VW_WAIT_MS], -1
    jmp .Lvw_wait
.Lvw_hold:
    mov dword ptr [rbx+VW_WAIT_MS], 250
    cmp qword ptr [r12+48], 0
    je .Lvw_wait
    mov dword ptr [rbx+VW_WAIT_MS], -1
.Lvw_wait:
    mov rcx, rbx
    call vw_sync
    xor ecx, ecx
    xor edx, edx
    cmp qword ptr [r12+48], 0
    je .Lvw_wait_call
    mov ecx, 1
    lea rdx, [r12+48]
.Lvw_wait_call:
    mov r8d, [rbx+VW_WAIT_MS]
    mov r9d, 0x4ff          # QS_ALLINPUT
    mov qword ptr [rsp+32], 4 # INPUTAVAILABLE
    call MsgWaitForMultipleObjectsEx
    cmp eax, -1
    je .Lvw_unexpected
    jmp .Lvw_loop
.Lvw_host_quit:
    mov ecx, [rbx+VW_MSG+16]
    call PostQuitMessage
.Lvw_normal_close:
    xor r13d, r13d
    jmp .Lvw_cleanup
.Lvw_cancel:
    mov r13d, 0x80004004
    jmp .Lvw_cleanup
.Lvw_invalid:
    mov eax, WV_INVALID
    jmp .Lvw_failed
.Lvw_unsupported:
    mov eax, WV_UNSUPPORTED
    jmp .Lvw_failed
.Lvw_unexpected:
    mov eax, WV_UNEXPECTED
.Lvw_failed:
    mov r13d, eax
.Lvw_cleanup:
    mov rcx, rbx
    call vw_sync
    mov rax, [rbx+VW_REPORT]
    test rax, rax
    jz .Lvw_cleanup_present
    mov [rax+24], r13d
.Lvw_cleanup_present:
    lea rcx, [rbx+VW_PRESENT]
    call win_present_close
    lea rcx, [rbx+VW_STREAM]
    call win_video_stream_close
    mov rcx, [rbx+VW_HWND]
    test rcx, rcx
    jz .Lvw_cleanup_class
    call DestroyWindow
.Lvw_cleanup_class:
    cmp dword ptr [rbx+VW_REGISTERED], 0
    je .Lvw_cleanup_report
    lea rcx, [rip+vw_class_name]
    mov rdx, [rbx+VW_INSTANCE]
    call UnregisterClassW
.Lvw_cleanup_report:
    mov rax, [rbx+VW_REPORT]
    test rax, rax
    jz .Lvw_cleanup_free
    mov qword ptr [rax], 0
.Lvw_cleanup_free:
    mov rcx, rbx
    call mem_free
    mov eax, r13d
    jmp .Lvw_return
.Lvw_no_memory:
    mov eax, 0x8007000e
.Lvw_return:
    add rsp, 104
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_video_play

LOCALFN vw_restart
    push rbx
    sub rsp, 32
    mov rbx, rcx
    lea rcx, [rbx+VW_STREAM]
    call win_video_stream_close
    lea rcx, [rbx+VW_STREAM]
    mov rdx, [rbx+VW_GPU]
    mov r8, [rbx+VW_PARSER]
    call win_video_stream_open
    test eax, eax
    js .Lvw_restart_failed
    mov rcx, [rbx+VW_PARSER]
    call h264_close
    mov rax, [rbx+VW_INFO]
    mov rcx, [rbx+VW_PARSER]
    mov rdx, [rax]
    mov r8, [rax+8]
    mov r9, [rax+16]
    call h264_open
    test eax, eax
    jz .Lvw_restart_return
    mov dword ptr [rbx+VW_PAUSED], 0
    mov dword ptr [rbx+VW_EOF], 0
    mov dword ptr [rbx+VW_SOURCE_EOF], 0
    mov dword ptr [rbx+VW_STEP], 0
    mov dword ptr [rbx+VW_HAS_FRAME], 0
    mov dword ptr [rbx+VW_STARTED], 0
    mov qword ptr [rbx+VW_BASE_NS], 0
    mov rcx, rbx
    call vw_anchor
    jmp .Lvw_restart_return
.Lvw_restart_failed:
    xor eax, eax
.Lvw_restart_return:
    add rsp, 32
    pop rbx
    ret
ENDFN vw_restart

LOCALFN vw_anchor
    add rcx, VW_ANCHOR
    jmp QueryPerformanceCounter
ENDFN vw_anchor

LOCALFN vw_now
    push rbx
    sub rsp, 48
    mov rbx, rcx
    mov rax, [rbx+VW_BASE_NS]
    cmp dword ptr [rbx+VW_PAUSED], 0
    jne .Lvw_now_return
    cmp dword ptr [rbx+VW_SUSPENDED], 0
    jne .Lvw_now_return
    lea rcx, [rsp+32]
    call QueryPerformanceCounter
    test eax, eax
    jz .Lvw_now_bad
    mov rax, [rsp+32]
    sub rax, [rbx+VW_ANCHOR]
    js .Lvw_now_bad
    mov ecx, 1000000000
    mul rcx
    cmp rdx, [rbx+VW_FREQ]
    jae .Lvw_now_bad
    div qword ptr [rbx+VW_FREQ]
    add rax, [rbx+VW_BASE_NS]
    jo .Lvw_now_bad
    test rax, rax
    js .Lvw_now_bad
    jmp .Lvw_now_return
.Lvw_now_bad:
    mov rax, -1
.Lvw_now_return:
    add rsp, 48
    pop rbx
    ret
ENDFN vw_now

# RCX=state,RAX=frame index ->floor(index*periodNum/periodDen) or-1.
LOCALFN vw_frame_ns
    mul qword ptr [rcx+VW_PERIOD_NUM]
    cmp rdx, [rcx+VW_PERIOD_DEN]
    jae .Lvw_frame_ns_bad
    div qword ptr [rcx+VW_PERIOD_DEN]
    test rax, rax
    js .Lvw_frame_ns_bad
    ret
.Lvw_frame_ns_bad:
    mov rax, -1
    ret
ENDFN vw_frame_ns

LOCALFN vw_target
    mov rax, [rcx+VW_HWND]
    mov [rcx+VW_TARGET], rax
    mov r8d, [rcx+VW_WANTED_W]
    mov r9d, [rcx+VW_WANTED_H]
    mov r10d, r8d
    cmp r10d, r9d
    cmovb r10d, r9d
    cmp r10d, 4096
    jbe .Lvw_target_store
    mov eax, r8d
    shl rax, 12
    xor edx, edx
    div r10
    mov r8d, eax
    mov eax, r9d
    shl rax, 12
    xor edx, edx
    div r10
    mov r9d, eax
.Lvw_target_store:
    test r8d, r8d
    jnz .Lvw_target_w
    inc r8d
.Lvw_target_w:
    test r9d, r9d
    jnz .Lvw_target_h
    inc r9d
.Lvw_target_h:
    mov [rcx+VW_TARGET+8], r8d
    mov [rcx+VW_TARGET+12], r9d
    ret
ENDFN vw_target

LOCALFN vw_title_set
    mov r8, rcx
    mov rcx, [r8+VW_HWND]
    lea rdx, [rip+vw_title]
    cmp dword ptr [r8+VW_PAUSED], 0
    je .Lvw_title_eof
    lea rdx, [rip+vw_title_paused]
.Lvw_title_eof:
    cmp dword ptr [r8+VW_EOF], 0
    je .Lvw_title_call
    lea rdx, [rip+vw_title_eof]
.Lvw_title_call:
    jmp SetWindowTextW
ENDFN vw_title_set

LOCALFN vw_sync
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov rax, [rbx+VW_REPORT]
    test rax, rax
    jz .Lvw_sync_return
    call vw_now
    mov rdx, [rbx+VW_REPORT]
    mov [rdx+40], rax
    mov rax, [rbx+VW_HWND]
    mov [rdx], rax
    mov rax, [rbx+VW_PRESENTED]
    mov [rdx+8], rax
    mov eax, [rbx+VW_PAUSED]
    mov [rdx+16], eax
    mov eax, [rbx+VW_EOF]
    mov [rdx+20], eax
    mov eax, [rbx+VW_PRESENT+VP_WIDTH]
    mov [rdx+28], eax
    mov eax, [rbx+VW_PRESENT+VP_HEIGHT]
    mov [rdx+32], eax
    mov eax, [rbx+VW_STEPS]
    mov [rdx+36], eax
    mov rax, [rbx+VW_LATE]
    mov [rdx+48], rax
.Lvw_sync_return:
    add rsp, 32
    pop rbx
    ret
ENDFN vw_sync

LOCALFN vw_proc
    push rbx
    push rsi
    push rdi
    sub rsp, 128
    mov rbx, rcx
    mov edi, edx
    mov [rsp+32], r8
    mov [rsp+40], r9
    cmp edi, 0x81
    jne .Lvw_proc_state
    mov r8, [r9]
    test r8, r8
    jz .Lvw_proc_zero
    mov edx, -21
    call SetWindowLongPtrW
    mov eax, 1
    jmp .Lvw_proc_return
.Lvw_proc_state:
    mov edx, -21
    call GetWindowLongPtrW
    mov rsi, rax
    test rsi, rsi
    jz .Lvw_proc_default
    cmp edi, 0x10          # close request; owner releases swap chain first
    je .Lvw_proc_close
    cmp edi, 2
    je .Lvw_proc_close
    cmp edi, 0x82
    je .Lvw_proc_nc_destroy
    cmp edi, 5
    je .Lvw_proc_size
    cmp edi, 0xf
    je .Lvw_proc_paint
    cmp edi, 0x14
    je .Lvw_proc_one
    cmp edi, 0x100
    je .Lvw_proc_key
    cmp edi, 0x2e0
    je .Lvw_proc_dpi
    jmp .Lvw_proc_default
.Lvw_proc_close:
    mov dword ptr [rsi+VW_CLOSED], 1
    cmp edi, 2
    jne .Lvw_proc_zero
    mov qword ptr [rsi+VW_HWND], 0
    jmp .Lvw_proc_zero
.Lvw_proc_nc_destroy:
    mov rcx, rbx
    mov edx, -21
    xor r8d, r8d
    call SetWindowLongPtrW
    jmp .Lvw_proc_default
.Lvw_proc_size:
    mov dword ptr [rsi+VW_MINIMIZED], 1
    cmp qword ptr [rsp+32], 1
    je .Lvw_proc_zero
    mov rax, [rsp+40]
    movzx edx, ax
    shr rax, 16
    and eax, 65535
    test edx, edx
    jz .Lvw_proc_zero
    test eax, eax
    jz .Lvw_proc_zero
    mov [rsi+VW_WANTED_W], edx
    mov [rsi+VW_WANTED_H], eax
    mov dword ptr [rsi+VW_MINIMIZED], 0
    mov dword ptr [rsi+VW_RESIZE], 1
    jmp .Lvw_proc_zero
.Lvw_proc_paint:
    mov rcx, rbx
    lea rdx, [rsp+48]
    call BeginPaint
    mov rcx, rbx
    lea rdx, [rsp+48]
    call EndPaint
    mov dword ptr [rsi+VW_REDRAW], 1
    jmp .Lvw_proc_zero
.Lvw_proc_key:
    mov rax, [rsp+40]
    test eax, 0x40000000 # ignore autorepeat for pause/step/close
    jnz .Lvw_proc_zero
    mov rax, [rsp+32]
    cmp eax, 27
    je .Lvw_proc_close
    cmp eax, 'Q'
    je .Lvw_proc_close
    cmp eax, 32
    je .Lvw_proc_toggle
    cmp eax, 0xbe
    jne .Lvw_proc_zero
    mov dword ptr [rsi+VW_STEP], 1
    jmp .Lvw_proc_zero
.Lvw_proc_toggle:
    xor dword ptr [rsi+VW_TOGGLE], 1
    jmp .Lvw_proc_zero
.Lvw_proc_dpi:
    mov rax, [rsp+40]
    mov rcx, rbx
    xor edx, edx
    mov r8d, [rax]
    mov r9d, [rax+4]
    mov r10d, [rax+8]
    sub r10d, r8d
    mov [rsp+32], r10
    mov r10d, [rax+12]
    sub r10d, r9d
    mov [rsp+40], r10
    mov qword ptr [rsp+48], 20
    call SetWindowPos
    jmp .Lvw_proc_zero
.Lvw_proc_default:
    mov rcx, rbx
    mov edx, edi
    mov r8, [rsp+32]
    mov r9, [rsp+40]
    call DefWindowProcW
    jmp .Lvw_proc_return
.Lvw_proc_one:
    mov eax, 1
    jmp .Lvw_proc_return
.Lvw_proc_zero:
    xor eax, eax
.Lvw_proc_return:
    add rsp, 128
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vw_proc
