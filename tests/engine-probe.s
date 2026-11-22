# Native lifecycle test for the same rendering engine used by the UI.
.include "lamp.inc"
.data
probe_argc: .long 0
probe_path: .quad 0
probe_args: .quad 0
probe_thread: .quad 0
probe_tick: .quad 0
probe_pause_position: .quad 0
probe_expected: .quad 0
probe_result: .long 0
probe_start_paused: .long 0
probe_written: .long 0
probe_default_restart: .long 0
probe_restart_ms: .quad 0
probe_pass: .ascii "Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open."
.byte 13, 10
.ifdef PROBE_SILENT
    .ascii "Muted output: lifecycle exercised with volume zero."
    .byte 13, 10
.endif
.ifdef PROBE_DEFAULT_DEVICE
    .ascii "Default-device callback: paused and active restart passed; pending command preserved."
    .byte 13, 10
.endif
.ifdef PROBE_EXCLUSIVE
    .ascii "Exclusive output: 48000 Hz session lifecycle passed."
    .byte 13, 10
.endif
.equ probe_pass_length, . - probe_pass
.text
FN probe_start
    sub rsp, 72
    .ifdef PROBE_SILENT
    mov dword ptr [rip+engine_volume], 0
    .endif
    .ifdef PROBE_EXCLUSIVE
    mov dword ptr [rip + engine_exclusive], 1
    mov dword ptr [rip + queue_target], 48000
    .endif
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + probe_argc]
    call CommandLineToArgvW
    mov [rip + probe_args], rax
    test rax, rax
    jz .Lprobe_bad
    cmp dword ptr [rip + probe_argc], 2
    jne .Lprobe_bad
    mov rax, [rax + 8]
    mov [rip + probe_path], rax
    call probe_launch
    call probe_wait_position
    test eax, eax
    jz .Lprobe_bad
    call engine_pause
    mov rcx, [rip + probe_thread]
    mov edx, 500
    call WaitForSingleObject
    cmp eax, 0x102
    jne .Lprobe_bad
    mov rax, [rip + engine_position]
    mov [rip + probe_pause_position], rax
    mov rcx, [rip + probe_thread]
    mov edx, 400
    call WaitForSingleObject
    mov rax, [rip + engine_position]
    cmp rax, [rip + probe_pause_position]
    jne .Lprobe_bad
    .ifdef PROBE_DEFAULT_DEVICE
    call probe_default_change
    test eax, eax
    jz .Lprobe_bad
    .endif
    call engine_pause
    mov rax, [rip + engine_position]
    mov edx, [rip + queue_rate]
    add rax, rdx
    mov [rip + probe_expected], rax
    call probe_wait_position
    test eax, eax
    jz .Lprobe_bad
    .ifdef PROBE_DEFAULT_DEVICE
    call probe_default_active
    test eax, eax
    jz .Lprobe_bad
    .endif
    call engine_stop
    call probe_join
    test eax, eax
    jz .Lprobe_bad
    mov dword ptr [rip + engine_seek_seconds], 7
    mov dword ptr [rip + probe_start_paused], 1
    mov eax, [rip + queue_rate]
    imul rax, 7
    mov [rip + probe_expected], rax
    call probe_launch
    call probe_wait_position
    test eax, eax
    jz .Lprobe_bad
    mov rax, [rip + engine_position]
    mov [rip + probe_pause_position], rax
    mov rcx, [rip + probe_thread]
    mov edx, 500
    call WaitForSingleObject
    cmp eax, 0x102
    jne .Lprobe_bad
    mov rax, [rip + engine_position]
    cmp rax, [rip + probe_pause_position]
    jne .Lprobe_bad
    call engine_pause
    mov eax, [rip + queue_rate]
    imul rax, 8
    mov [rip + probe_expected], rax
    call probe_wait_position
    test eax, eax
    jz .Lprobe_bad
    call engine_stop
    call probe_join
    test eax, eax
    jz .Lprobe_bad
    mov dword ptr [rip + engine_seek_seconds], 5
    mov dword ptr [rip + probe_start_paused], 0
    mov eax, [rip + queue_rate]
    imul rax, 6
    mov [rip + probe_expected], rax
    call probe_launch
    call probe_wait_position
    test eax, eax
    jz .Lprobe_bad
    call engine_stop
    call probe_join
    test eax, eax
    jz .Lprobe_bad
    cmp qword ptr [rip + underruns], 0
    jne .Lprobe_bad
    cmp qword ptr [rip + endpoint_dry], 0
    jne .Lprobe_bad
    # A stop requested before open must return normally without playback.
    mov dword ptr [rip + engine_stop_requested], 1
    mov rcx, [rip + probe_path]
    call engine_play
    test eax, eax
    jnz .Lprobe_bad
    mov ecx, -11
    call GetStdHandle
    mov rcx, rax
    lea rdx, [rip + probe_pass]
    mov r8d, offset probe_pass_length
    lea r9, [rip + probe_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    xor ecx, ecx
    call ExitProcess
.Lprobe_bad:
    call engine_stop
    call probe_join
    mov ecx, 1
    call ExitProcess
ENDFN probe_start
LOCALFN probe_worker
    sub rsp, 40
    xor eax, eax
    xchg [rip + probe_default_restart], eax
    test eax, eax
    jz .Lprobe_normal_worker
    lea rcx, [rip + probe_path]
    mov edx, 1
    xor r8d, r8d
    mov r9, [rip + probe_restart_ms]
    call engine_play_list
    jmp .Lprobe_worker_done
.Lprobe_normal_worker:
    mov rcx, [rip + probe_path]
    call engine_play
.Lprobe_worker_done:
    mov [rip + probe_result], eax
    add rsp, 40
    ret
ENDFN probe_worker
.ifdef PROBE_DEFAULT_DEVICE
LOCALFN probe_default_active
    sub rsp, 40
    lea rcx, [rip + output_notification_client]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call qword ptr [rax + 48]
    call probe_join
    test eax, eax
    jz .Lprobe_active_bad
    cmp dword ptr [rip + engine_command], 5
    jne .Lprobe_active_bad
    cmp dword ptr [rip + pause_requested], 0
    jne .Lprobe_active_bad
    cmp dword ptr [rip + engine_heard_index], 0
    jne .Lprobe_active_bad
    mov rax, [rip + engine_position]
    imul rax, 1000
    xor edx, edx
    mov ecx, [rip + queue_rate]
    div rcx
    cmp rax, [rip + engine_heard_ms]
    jne .Lprobe_active_bad
    mov [rip + probe_restart_ms], rax
    mov dword ptr [rip + probe_default_restart], 1
    mov dword ptr [rip + probe_start_paused], 0
    imul rax, rcx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov edx, [rip + queue_rate]
    add rax, rdx
    mov [rip + probe_expected], rax
    call probe_launch
    call probe_wait_position
    test eax, eax
    jz .Lprobe_active_bad
    call engine_pause
    mov rcx, [rip + probe_thread]
    mov edx, 500
    call WaitForSingleObject
    cmp eax, 0x102
    jne .Lprobe_active_bad
    # A completed user seek command wins over the next notification. Its
    # paired file/time snapshot must survive without being overwritten.
    mov dword ptr [rip + engine_heard_index], 0
    mov qword ptr [rip + engine_heard_ms], 271
    mov dword ptr [rip + engine_command], 3
    lea rcx, [rip + output_notification_client]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call qword ptr [rax + 48]
    call probe_join
    test eax, eax
    jz .Lprobe_active_bad
    cmp dword ptr [rip + engine_command], 3
    jne .Lprobe_active_bad
    cmp dword ptr [rip + engine_heard_index], 0
    jne .Lprobe_active_bad
    cmp qword ptr [rip + engine_heard_ms], 271
    jne .Lprobe_active_bad
    mov qword ptr [rip + probe_restart_ms], 271
    mov dword ptr [rip + probe_default_restart], 1
    mov dword ptr [rip + probe_start_paused], 1
    mov eax, [rip + queue_rate]
    imul rax, 271
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rip + probe_expected], rax
    call probe_launch
    call probe_wait_position
    jmp .Lprobe_active_return
.Lprobe_active_bad:
    xor eax, eax
.Lprobe_active_return:
    add rsp, 40
    ret
ENDFN probe_default_active
LOCALFN probe_default_change
    sub rsp, 40
    lea rcx, [rip + output_notification_client]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call qword ptr [rax + 48]           # OnDefaultDeviceChanged, no system change
    call probe_join
    test eax, eax
    jz .Lprobe_default_bad
    cmp dword ptr [rip + engine_command], 5
    jne .Lprobe_default_bad
    cmp dword ptr [rip + pause_requested], 1
    jne .Lprobe_default_bad
    cmp dword ptr [rip + engine_heard_index], 0
    jne .Lprobe_default_bad
    mov rax, [rip + probe_pause_position]
    imul rax, 1000
    xor edx, edx
    mov ecx, [rip + queue_rate]
    div rcx
    cmp rax, [rip + engine_heard_ms]
    jne .Lprobe_default_bad
    mov [rip + probe_restart_ms], rax
    mov dword ptr [rip + probe_default_restart], 1
    mov dword ptr [rip + probe_start_paused], 1
    imul rax, rcx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rip + probe_expected], rax
    mov [rip + probe_pause_position], rax
    call probe_launch
    call probe_wait_position
    test eax, eax
    jz .Lprobe_default_bad
    mov rcx, [rip + probe_thread]
    mov edx, 500
    call WaitForSingleObject
    cmp eax, 0x102
    jne .Lprobe_default_bad
    mov rax, [rip + probe_pause_position]
    cmp rax, [rip + engine_position]
    jne .Lprobe_default_bad
    cmp dword ptr [rip + pause_requested], 1
    jne .Lprobe_default_bad
    mov eax, 1
    jmp .Lprobe_default_return
.Lprobe_default_bad:
    xor eax, eax
.Lprobe_default_return:
    add rsp, 40
    ret
ENDFN probe_default_change
.endif
LOCALFN probe_launch
    sub rsp, 56
    mov dword ptr [rip + engine_stop_requested], 0
    mov eax, [rip + probe_start_paused]
    mov [rip + pause_requested], eax
    mov dword ptr [rip + probe_result], 0
    mov qword ptr [rip + engine_position], 0
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + probe_worker]
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    mov [rip + probe_thread], rax
    add rsp, 56
    ret
ENDFN probe_launch
LOCALFN probe_wait_position
    sub rsp, 40
    call GetTickCount64
    mov [rip + probe_tick], rax
.Lprobe_position_loop:
    mov rcx, [rip + probe_thread]
    mov edx, 100
    call WaitForSingleObject
    cmp eax, 0x102
    jne .Lprobe_position_bad
    mov rax, [rip + probe_expected]
    test rax, rax
    jnz .Lprobe_position_target
    mov eax, [rip + queue_rate]
    test eax, eax
    jz .Lprobe_position_timeout
.Lprobe_position_target:
    cmp [rip + engine_position], rax
    jae .Lprobe_position_good
.Lprobe_position_timeout:
    call GetTickCount64
    sub rax, [rip + probe_tick]
    cmp rax, 10000
    jb .Lprobe_position_loop
.Lprobe_position_bad:
    xor eax, eax
    jmp .Lprobe_position_return
.Lprobe_position_good:
    mov eax, 1
.Lprobe_position_return:
    add rsp, 40
    ret
ENDFN probe_wait_position
LOCALFN probe_join
    sub rsp, 40
    mov rcx, [rip + probe_thread]
    test rcx, rcx
    jz .Lprobe_join_bad
    mov edx, 10000
    call WaitForSingleObject
    test eax, eax
    jnz .Lprobe_join_bad
    mov rcx, [rip + probe_thread]
    call CloseHandle
    mov qword ptr [rip + probe_thread], 0
    xor eax, eax
    cmp dword ptr [rip + probe_result], 0
    sete al
    jmp .Lprobe_join_return
.Lprobe_join_bad:
    xor eax, eax
.Lprobe_join_return:
    add rsp, 40
    ret
ENDFN probe_join
