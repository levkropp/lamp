; Native lifecycle test for the same rendering engine used by the UI.
option casemap:none
EXTERN engine_play:PROC, engine_stop:PROC, engine_pause:PROC
EXTERN engine_stop_requested:DWORD, engine_seek_seconds:DWORD
EXTERN engine_position:QWORD, pause_requested:DWORD, sample_rate:DWORD
EXTERN underruns:QWORD, endpoint_dry:QWORD
EXTERN GetCommandLineW:PROC, CommandLineToArgvW:PROC, LocalFree:PROC
EXTERN CreateThread:PROC, WaitForSingleObject:PROC, CloseHandle:PROC
EXTERN ExitProcess:PROC, GetTickCount64:PROC, GetStdHandle:PROC, WriteFile:PROC
PUBLIC probe_start
.data
probe_argc dd 0
probe_path dq 0
probe_args dq 0
probe_thread dq 0
probe_tick dq 0
probe_pause_position dq 0
probe_expected dq 0
probe_result dd 0
probe_start_paused dd 0
probe_written dd 0
probe_pass db 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.',13,10
probe_pass_length EQU $-probe_pass
.code
probe_start PROC
    sub rsp,72
    call GetCommandLineW
    mov rcx,rax
    lea rdx,probe_argc
    call CommandLineToArgvW
    mov [probe_args],rax
    test rax,rax
    jz probe_bad
    cmp dword ptr [probe_argc],2
    jne probe_bad
    mov rax,[rax+8]
    mov [probe_path],rax
    call probe_launch
    call probe_wait_position
    test eax,eax
    jz probe_bad
    call engine_pause
    mov rcx,[probe_thread]
    mov edx,500
    call WaitForSingleObject
    cmp eax,102h
    jne probe_bad
    mov rax,[engine_position]
    mov [probe_pause_position],rax
    mov rcx,[probe_thread]
    mov edx,400
    call WaitForSingleObject
    mov rax,[engine_position]
    cmp rax,[probe_pause_position]
    jne probe_bad
    call engine_pause
    mov rax,[engine_position]
    mov edx,[sample_rate]
    add rax,rdx
    mov [probe_expected],rax
    call probe_wait_position
    test eax,eax
    jz probe_bad
    call engine_stop
    call probe_join
    test eax,eax
    jz probe_bad
    mov dword ptr [engine_seek_seconds],7
    mov dword ptr [probe_start_paused],1
    mov eax,[sample_rate]
    imul rax,7
    mov [probe_expected],rax
    call probe_launch
    call probe_wait_position
    test eax,eax
    jz probe_bad
    mov rax,[engine_position]
    mov [probe_pause_position],rax
    mov rcx,[probe_thread]
    mov edx,500
    call WaitForSingleObject
    cmp eax,102h
    jne probe_bad
    mov rax,[engine_position]
    cmp rax,[probe_pause_position]
    jne probe_bad
    call engine_pause
    mov eax,[sample_rate]
    imul rax,8
    mov [probe_expected],rax
    call probe_wait_position
    test eax,eax
    jz probe_bad
    call engine_stop
    call probe_join
    test eax,eax
    jz probe_bad
    mov dword ptr [engine_seek_seconds],5
    mov dword ptr [probe_start_paused],0
    mov eax,[sample_rate]
    imul rax,6
    mov [probe_expected],rax
    call probe_launch
    call probe_wait_position
    test eax,eax
    jz probe_bad
    call engine_stop
    call probe_join
    test eax,eax
    jz probe_bad
    cmp qword ptr [underruns],0
    jne probe_bad
    cmp qword ptr [endpoint_dry],0
    jne probe_bad
    ; A stop requested before open must return normally without playback.
    mov dword ptr [engine_stop_requested],1
    mov rcx,[probe_path]
    call engine_play
    test eax,eax
    jnz probe_bad
    mov ecx,-11
    call GetStdHandle
    mov rcx,rax
    lea rdx,probe_pass
    mov r8d,probe_pass_length
    lea r9,probe_written
    mov qword ptr [rsp+32],0
    call WriteFile
    xor ecx,ecx
    call ExitProcess
probe_bad:
    call engine_stop
    call probe_join
    mov ecx,1
    call ExitProcess
probe_start ENDP
probe_worker PROC
    sub rsp,40
    mov rcx,[probe_path]
    call engine_play
    mov [probe_result],eax
    add rsp,40
    ret
probe_worker ENDP
probe_launch PROC
    sub rsp,56
    mov dword ptr [engine_stop_requested],0
    mov eax,[probe_start_paused]
    mov [pause_requested],eax
    mov dword ptr [probe_result],0
    mov qword ptr [engine_position],0
    xor ecx,ecx
    xor edx,edx
    lea r8,probe_worker
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateThread
    mov [probe_thread],rax
    add rsp,56
    ret
probe_launch ENDP
probe_wait_position PROC
    sub rsp,40
    call GetTickCount64
    mov [probe_tick],rax
probe_position_loop:
    mov rcx,[probe_thread]
    mov edx,100
    call WaitForSingleObject
    cmp eax,102h
    jne probe_position_bad
    mov rax,[probe_expected]
    test rax,rax
    jnz probe_position_target
    mov eax,[sample_rate]
    test eax,eax
    jz probe_position_timeout
probe_position_target:
    cmp [engine_position],rax
    jae probe_position_good
probe_position_timeout:
    call GetTickCount64
    sub rax,[probe_tick]
    cmp rax,10000
    jb probe_position_loop
probe_position_bad:
    xor eax,eax
    jmp probe_position_return
probe_position_good:
    mov eax,1
probe_position_return:
    add rsp,40
    ret
probe_wait_position ENDP
probe_join PROC
    sub rsp,40
    mov rcx,[probe_thread]
    test rcx,rcx
    jz probe_join_bad
    mov edx,10000
    call WaitForSingleObject
    test eax,eax
    jnz probe_join_bad
    mov rcx,[probe_thread]
    call CloseHandle
    mov qword ptr [probe_thread],0
    xor eax,eax
    cmp dword ptr [probe_result],0
    sete al
    jmp probe_join_return
probe_join_bad:
    xor eax,eax
probe_join_return:
    add rsp,40
    ret
probe_join ENDP
END
