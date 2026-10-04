; LAMP native Win32 UI. Original x86-64 assembly, MIT.
; Rhun reference: custom pixel buffer + Win32 presentation, compact monospace
; chrome. mpv reference: uncluttered canvas and on-screen playback controls.
option casemap:none
EXTERN GetModuleHandleW:PROC, GetCommandLineW:PROC, CommandLineToArgvW:PROC
EXTERN LocalFree:PROC, ExitProcess:PROC, CreateThread:PROC, CloseHandle:PROC
EXTERN WaitForSingleObject:PROC, GetTickCount64:PROC
EXTERN RegisterClassExW:PROC, CreateWindowExW:PROC, DefWindowProcW:PROC
EXTERN LoadCursorW:PROC, LoadIconW:PROC, ShowWindow:PROC, UpdateWindow:PROC
EXTERN GetMessageW:PROC, TranslateMessage:PROC, DispatchMessageW:PROC
EXTERN BeginPaint:PROC, EndPaint:PROC, GetClientRect:PROC, InvalidateRect:PROC
EXTERN PostQuitMessage:PROC, PostMessageW:PROC, DestroyWindow:PROC
EXTERN SetTimer:PROC, KillTimer:PROC, SetWindowTextW:PROC, SetCursor:PROC
EXTERN SetWindowPos:PROC
EXTERN GetOpenFileNameW:PROC, DragAcceptFiles:PROC, DragQueryFileW:PROC, DragFinish:PROC
EXTERN CreateCompatibleDC:PROC, CreateDIBSection:PROC, SelectObject:PROC
EXTERN DeleteObject:PROC, DeleteDC:PROC, BitBlt:PROC, SetBkMode:PROC
EXTERN SetTextColor:PROC, TextOutW:PROC, DrawTextW:PROC, CreateFontW:PROC
EXTERN GetDpiForWindow:PROC, SetProcessDpiAwarenessContext:PROC
EXTERN engine_play:PROC, engine_stop:PROC, engine_pause:PROC
EXTERN engine_mode:DWORD, engine_stop_requested:DWORD
EXTERN engine_position:QWORD, engine_seek_seconds:DWORD, engine_volume:DWORD
EXTERN pause_requested:DWORD, exit_code:DWORD, underruns:QWORD, endpoint_dry:QWORD
EXTERN engine_ready:DWORD
EXTERN sample_rate:DWORD, source_channels:DWORD, total_frames:QWORD, codec_kind:DWORD
PUBLIC ui_start
PUBLIC ui_draw, ui_width, ui_height, ui_pixels, ui_bmi, ui_state, ui_filename, ui_thread
WM_WORKER_DONE EQU 8001h
.data
ui_class dw 'L','a','m','p','W','i','n','d','o','w',0
ui_title dw 'L','A','M','P',' ','-',' ','L','e','v',39,'s',' ','A','s','s','e','m','b','l','y',' ','M','e','d','i','a',' ','P','l','a','y','e','r',0
ui_brand dw 'l','a','m','p',0
ui_assembly dw 'x','8','6','-','6','4',' ','/',' ','a','s','s','e','m','b','l','y',0
ui_drop dw 'D','r','o','p',' ','a','n',' ','a','u','d','i','o',' ','f','i','l','e',0
ui_open dw 'O','p','e','n',' ','f','i','l','e',0
ui_hint dw 'O',' ','o','p','e','n',' ',' ',' ','S','p','a','c','e',' ','p','a','u','s','e'
    dw ' ',' ',' ','A','r','r','o','w','s',' ','s','e','e','k',' ','/',' ','v','o','l','u','m','e',0
ui_ready dw 'R','E','A','D','Y',0
ui_playing dw 'P','L','A','Y','I','N','G',0
ui_paused dw 'P','A','U','S','E','D',0
ui_loading dw 'L','O','A','D','I','N','G',0
ui_finished dw 'F','I','N','I','S','H','E','D',0
ui_failed dw 'E','R','R','O','R',0
ui_error dw 'C','a','n','n','o','t',' ','p','l','a','y',' ','t','h','i','s',' ','f','i','l','e',0
ui_error_detail dw 'U','n','s','u','p','p','o','r','t','e','d',' ','c','o','d','e','c',',',' ','d','a','m','a','g','e','d',' ','f','i','l','e'
    dw ',',' ','o','r',' ','a','u','d','i','o',' ','d','e','v','i','c','e',' ','u','n','a','v','a','i','l','a','b','l','e',0
ui_codec_wav dw 'W','A','V',0
ui_codec_flac dw 'F','L','A','C',0
ui_codec_mp3 dw 'M','P','3',0
ui_codec_vorbis dw 'V','O','R','B','I','S',0
ui_codec_opus dw 'O','P','U','S',0
ui_codec_aiff dw 'A','I','F','F','/','A','I','F','C',0
ui_codec_names dq 0,ui_codec_wav,ui_codec_flac,ui_codec_mp3,ui_codec_vorbis,ui_codec_opus,ui_codec_aiff
ui_font_name dw 'C','o','n','s','o','l','a','s',0
ui_filter dw 'A','u','d','i','o',' ','f','i','l','e','s',0
    dw '*','.','w','a','v',';','*','.','a','i','f',';','*','.','a','i','f','f',';','*','.','a','i','f','c',';'
    dw '*','.','f','l','a','c',';','*','.','m','p','3',';','*','.','o','g','g',';','*','.','o','p','u','s',';','*','.','o','g','a',0
    dw 'A','l','l',' ','f','i','l','e','s',0,'*','.','*',0,0
ui_instance dq 0
ui_hwnd dq 0
ui_thread dq 0
ui_dc dq 0
ui_bitmap dq 0
ui_pixels dq 0
ui_original_bitmap dq 0
ui_font dq 0
ui_big_font dq 0
ui_width dd 0
ui_height dd 0
ui_buffer_width dd 0
ui_buffer_height dd 0
ui_state dd 0               ; 0 ready, 1 playing, 2 finished, 3 error
ui_restart dd 0
ui_closing dd 0
ui_controls dd 1
ui_volume_percent dd 100
ui_last_activity dq 0
ui_argc dd 0
ui_volume_scale real4 0.01
ui_background dd 0015181bh
ui_surface dd 001c2024h
ui_line dd 002f363dh
ui_accent dd 007ed6c4h
ui_text_color dd 00e2e8edh
ui_muted_color dd 00939fa9h
.data?
ui_wc db 80 dup (?)
ui_message db 48 dup (?)
ui_paint db 72 dup (?)
ui_client dd 4 dup (?)
ui_text_rect dd 4 dup (?)
ui_bmi db 40 dup (?)
ui_ofn db 152 dup (?)
ui_pending dw 4096 dup (?)
ui_path dw 4096 dup (?)
ui_filename dq ?
ui_time_text dw 64 dup (?)
ui_volume_text dw 32 dup (?)
.code
ui_start PROC
    sub rsp,136
    mov dword ptr [engine_mode],1
    mov rcx,-4
    call SetProcessDpiAwarenessContext
    xor ecx,ecx
    call GetModuleHandleW
    mov [ui_instance],rax
    mov dword ptr [ui_wc],80
    mov dword ptr [ui_wc+4],3
    lea rax,ui_window_proc
    mov qword ptr [ui_wc+8],rax
    mov rax,[ui_instance]
    mov qword ptr [ui_wc+24],rax
    mov rcx,rax
    mov edx,101
    call LoadIconW
    mov qword ptr [ui_wc+32],rax
    mov qword ptr [ui_wc+72],rax
    xor ecx,ecx
    mov edx,32512
    call LoadCursorW
    mov qword ptr [ui_wc+40],rax
    lea rax,ui_class
    mov qword ptr [ui_wc+64],rax
    lea rcx,ui_wc
    call RegisterClassExW
    test eax,eax
    jz ui_exit
    xor ecx,ecx
    lea rdx,ui_class
    lea r8,ui_title
    mov r9d,00cf0000h
    mov qword ptr [rsp+32],80000000h
    mov qword ptr [rsp+40],80000000h
    mov qword ptr [rsp+48],820
    mov qword ptr [rsp+56],510
    mov qword ptr [rsp+64],0
    mov qword ptr [rsp+72],0
    mov rax,[ui_instance]
    mov [rsp+80],rax
    mov qword ptr [rsp+88],0
    call CreateWindowExW
    test rax,rax
    jz ui_exit
    mov [ui_hwnd],rax
    mov rcx,rax
    mov edx,1
    call DragAcceptFiles
    mov rcx,[ui_hwnd]
    mov edx,5
    call ShowWindow
    mov rcx,[ui_hwnd]
    call UpdateWindow
    call GetCommandLineW
    mov rcx,rax
    lea rdx,ui_argc
    call CommandLineToArgvW
    mov [rsp+96],rax
    test rax,rax
    jz ui_message_loop
    cmp dword ptr [ui_argc],2
    jne ui_free_args
    mov rcx,[rax+8]
    lea rdx,ui_pending
    call ui_copy_path
    mov dword ptr [engine_seek_seconds],0
    call ui_request
ui_free_args:
    mov rcx,[rsp+96]
    call LocalFree
ui_message_loop:
    lea rcx,ui_message
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    call GetMessageW
    test eax,eax
    jle ui_exit
    lea rcx,ui_message
    call TranslateMessage
    lea rcx,ui_message
    call DispatchMessageW
    jmp ui_message_loop
ui_exit:
    xor ecx,ecx
    call ExitProcess
ui_start ENDP

; Bounded Unicode copy. RCX=source, RDX=destination.
ui_copy_path PROC
    xor r8d,r8d
ui_copy_char:
    movzx eax,word ptr [rcx+r8*2]
    mov [rdx+r8*2],ax
    test eax,eax
    jz ui_copy_done
    inc r8d
    cmp r8d,4095
    jb ui_copy_char
    mov word ptr [rdx+r8*2],0
ui_copy_done:
    ret
ui_copy_path ENDP

ui_open_dialog PROC
    sub rsp,40
    mov dword ptr [ui_ofn],152
    mov rax,[ui_hwnd]
    mov qword ptr [ui_ofn+8],rax
    lea rax,ui_filter
    mov qword ptr [ui_ofn+24],rax
    mov dword ptr [ui_ofn+44],1
    lea rax,ui_pending
    mov qword ptr [ui_ofn+48],rax
    mov dword ptr [ui_ofn+56],4096
    mov dword ptr [ui_ofn+96],00081008h ; EXPLORER | FILEMUSTEXIST | NOCHANGEDIR
    mov word ptr [ui_pending],0
    lea rcx,ui_ofn
    call GetOpenFileNameW
    test eax,eax
    jz ui_dialog_done
    mov dword ptr [engine_seek_seconds],0
    mov dword ptr [pause_requested],0
    call ui_request
ui_dialog_done:
    add rsp,40
    ret
ui_open_dialog ENDP

ui_request PROC
    sub rsp,56
    cmp qword ptr [ui_thread],0
    je ui_launch
    mov dword ptr [ui_restart],1
    call engine_stop
    jmp ui_request_done
ui_launch:
    lea rcx,ui_pending
    lea rdx,ui_path
    call ui_copy_path
    lea rax,ui_path
    mov [ui_filename],rax
ui_basename:
    movzx ecx,word ptr [rax]
    test ecx,ecx
    jz ui_basename_done
    add rax,2
    cmp ecx,5ch
    je ui_basename_next
    cmp ecx,2fh
    jne ui_basename
ui_basename_next:
    mov [ui_filename],rax
    jmp ui_basename
ui_basename_done:
    mov dword ptr [ui_state],1
    mov dword ptr [ui_controls],1
    mov dword ptr [engine_stop_requested],0
    mov dword ptr [engine_ready],0
    mov qword ptr [engine_position],0
    xor ecx,ecx
    xor edx,edx
    lea r8,ui_audio_thread
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateThread
    mov [ui_thread],rax
    test rax,rax
    jnz ui_timer_start
    mov dword ptr [ui_state],3
    jmp ui_request_done
ui_timer_start:
    call GetTickCount64
    mov [ui_last_activity],rax
    mov rcx,[ui_hwnd]
    mov edx,1
    mov r8d,250
    xor r9d,r9d
    call SetTimer
ui_request_done:
    call ui_invalidate
    add rsp,56
    ret
ui_request ENDP

ui_audio_thread PROC
    sub rsp,40
    lea rcx,ui_path
    call engine_play
    mov rcx,[ui_hwnd]
    mov edx,WM_WORKER_DONE
    mov r8d,eax
    xor r9d,r9d
    call PostMessageW
    xor eax,eax
    add rsp,40
    ret
ui_audio_thread ENDP

ui_invalidate PROC
    sub rsp,40
    mov rcx,[ui_hwnd]
    xor edx,edx
    xor r8d,r8d
    call InvalidateRect
    add rsp,40
    ret
ui_invalidate ENDP

; Reveal controls and restart their timer only when previously hidden.
ui_activity PROC
    sub rsp,40
    call GetTickCount64
    mov [ui_last_activity],rax
    cmp dword ptr [ui_controls],0
    jne ui_activity_done
    mov dword ptr [ui_controls],1
    cmp qword ptr [ui_thread],0
    je ui_activity_repaint
    cmp dword ptr [pause_requested],0
    jne ui_activity_repaint
    mov rcx,[ui_hwnd]
    mov edx,1
    mov r8d,250
    xor r9d,r9d
    call SetTimer
ui_activity_repaint:
    call ui_invalidate
ui_activity_done:
    add rsp,40
    ret
ui_activity ENDP

; EAX=absolute seek seconds, clamped before requesting a decoder restart.
ui_seek PROC
    sub rsp,40
    cmp word ptr [ui_path],0
    je ui_seek_done
    test eax,eax
    jns ui_seek_nonnegative
    xor eax,eax
ui_seek_nonnegative:
    mov [rsp+32],eax
    mov ecx,[sample_rate]
    test ecx,ecx
    jz ui_seek_done
    mov rax,[total_frames]
    xor edx,edx
    div rcx
    test eax,eax
    jz ui_seek_done
    dec eax
    cmp eax,[rsp+32]
    cmova eax,dword ptr [rsp+32]
    mov [engine_seek_seconds],eax
    lea rcx,ui_path
    lea rdx,ui_pending
    call ui_copy_path
    call ui_request
ui_seek_done:
    add rsp,40
    ret
ui_seek ENDP

ui_window_proc PROC
    sub rsp,136
    mov [ui_hwnd],rcx
    mov [rsp+96],rcx
    mov [rsp+104],rdx
    mov [rsp+112],r8
    mov [rsp+120],r9
    cmp edx,0fh
    je ui_wm_paint
    cmp edx,14h
    je ui_handled
    cmp edx,5
    je ui_wm_size
    cmp edx,24h
    je ui_wm_minmax
    cmp edx,2e0h
    je ui_wm_dpi
    cmp edx,100h
    je ui_wm_key
    cmp edx,201h
    je ui_wm_click
    cmp edx,200h
    je ui_wm_mouse
    cmp edx,113h
    je ui_wm_timer
    cmp edx,233h
    je ui_wm_drop
    cmp edx,WM_WORKER_DONE
    je ui_wm_done
    cmp edx,10h
    je ui_wm_close
    cmp edx,2
    je ui_wm_destroy
    call DefWindowProcW
    jmp ui_wm_return
ui_wm_minmax:
    mov dword ptr [r9+24],480
    mov dword ptr [r9+28],330
    jmp ui_handled
ui_wm_dpi:
    ; Adopt Windows' recommended rectangle when moving between DPI domains.
    mov rax,r9
    xor edx,edx
    mov r8d,[rax]
    mov r9d,[rax+4]
    mov r10d,[rax+8]
    sub r10d,r8d
    mov [rsp+32],r10
    mov r10d,[rax+12]
    sub r10d,r9d
    mov [rsp+40],r10
    mov qword ptr [rsp+48],14h
    call SetWindowPos
    jmp ui_handled
ui_wm_size:
    mov eax,r9d
    and eax,0ffffh
    mov [ui_width],eax
    shr r9d,16
    mov [ui_height],r9d
    call ui_invalidate
    jmp ui_handled
ui_wm_mouse:
    call ui_activity
    jmp ui_handled
ui_wm_timer:
    cmp dword ptr [ui_closing],0
    jne ui_timer_quiet
    cmp dword ptr [pause_requested],0
    jne ui_timer_paused
    call GetTickCount64
    sub rax,[ui_last_activity]
    cmp rax,2500
    jb ui_timer_quiet
    cmp dword ptr [engine_ready],0
    je ui_timer_quiet
    mov dword ptr [ui_controls],0
    mov rcx,[ui_hwnd]
    mov edx,1
    call KillTimer
ui_timer_quiet:
    call ui_invalidate
    jmp ui_handled
ui_timer_paused:
    cmp dword ptr [engine_ready],0
    je ui_timer_quiet
    mov rcx,[ui_hwnd]
    mov edx,1
    call KillTimer
    mov dword ptr [ui_controls],1
    call ui_invalidate
    jmp ui_handled
ui_wm_key:
    call ui_activity
    mov r8,[rsp+112]
    cmp r8d,20h
    je ui_toggle_pause
    cmp r8d,4fh
    je ui_open_key
    cmp r8d,27h
    je ui_seek_forward
    cmp r8d,25h
    je ui_seek_backward
    cmp r8d,24h
    je ui_seek_home
    cmp r8d,26h
    je ui_volume_up
    cmp r8d,28h
    je ui_volume_down
    cmp r8d,4dh
    je ui_mute
    cmp r8d,51h
    je ui_wm_close
    jmp ui_handled
ui_open_key:
    call ui_open_dialog
    jmp ui_handled
ui_seek_forward:
    mov rax,[engine_position]
    xor edx,edx
    mov ecx,[sample_rate]
    test ecx,ecx
    jz ui_handled
    div rcx
    add eax,5
    call ui_seek
    jmp ui_handled
ui_seek_backward:
    mov rax,[engine_position]
    xor edx,edx
    mov ecx,[sample_rate]
    test ecx,ecx
    jz ui_handled
    div rcx
    sub eax,5
    call ui_seek
    jmp ui_handled
ui_seek_home:
    xor eax,eax
    call ui_seek
    jmp ui_handled
ui_volume_up:
    mov eax,[ui_volume_percent]
    add eax,5
    cmp eax,100
    jbe ui_set_volume
    mov eax,100
    jmp ui_set_volume
ui_volume_down:
    mov eax,[ui_volume_percent]
    sub eax,5
    jns ui_set_volume
    xor eax,eax
    jmp ui_set_volume
ui_mute:
    mov eax,100
    cmp dword ptr [ui_volume_percent],0
    je ui_set_volume
    xor eax,eax
ui_set_volume:
    mov [ui_volume_percent],eax
    cvtsi2ss xmm0,eax
    mulss xmm0,[ui_volume_scale]
    movss [engine_volume],xmm0
    call ui_invalidate
    jmp ui_handled
ui_toggle_pause:
    cmp qword ptr [ui_thread],0
    je ui_replay
    call engine_pause
    cmp dword ptr [pause_requested],0
    jne ui_pause_no_timer
    mov rcx,[ui_hwnd]
    mov edx,1
    mov r8d,250
    xor r9d,r9d
    call SetTimer
ui_pause_no_timer:
    mov dword ptr [ui_controls],1
    call ui_invalidate
    jmp ui_handled
ui_replay:
    cmp word ptr [ui_path],0
    je ui_open_key
    mov dword ptr [engine_seek_seconds],0
    mov dword ptr [pause_requested],0
    lea rcx,ui_path
    lea rdx,ui_pending
    call ui_copy_path
    call ui_request
    jmp ui_handled
ui_wm_click:
    call ui_activity
    mov r9,[rsp+120]
    mov eax,r9d
    shr eax,16
    mov ecx,[ui_height]
    sub ecx,130
    cmp eax,ecx
    jb ui_canvas_click
    add ecx,42
    cmp eax,ecx
    ja ui_transport_click
    ; Seek bar extends from x=32 to width-32.
    mov eax,r9d
    and eax,0ffffh
    sub eax,32
    js ui_handled
    mov ecx,[ui_width]
    sub ecx,64
    cmp eax,ecx
    ja ui_handled
    mov rdx,[total_frames]
    mul rdx
    div rcx
    mov ecx,[sample_rate]
    test ecx,ecx
    jz ui_handled
    xor edx,edx
    div rcx
    call ui_seek
    jmp ui_handled
ui_transport_click:
    mov eax,r9d
    and eax,0ffffh
    cmp eax,95
    jb ui_toggle_pause
    mov ecx,[ui_width]
    sub ecx,180
    sub eax,ecx
    js ui_handled
    cmp eax,148
    ja ui_handled
    imul eax,100
    xor edx,edx
    mov ecx,148
    div ecx
    jmp ui_set_volume
ui_canvas_click:
    cmp qword ptr [ui_thread],0
    jne ui_toggle_pause
    jmp ui_open_key
ui_wm_drop:
    mov rcx,r8
    xor edx,edx
    lea r8,ui_pending
    mov r9d,4096
    call DragQueryFileW
    mov rcx,[rsp+112]
    call DragFinish
    mov dword ptr [engine_seek_seconds],0
    mov dword ptr [pause_requested],0
    call ui_request
    jmp ui_handled
ui_wm_done:
    mov rcx,[ui_thread]
    mov edx,-1
    call WaitForSingleObject
    mov rcx,[ui_thread]
    call CloseHandle
    mov qword ptr [ui_thread],0
    mov rcx,[ui_hwnd]
    mov edx,1
    call KillTimer
    cmp dword ptr [ui_closing],0
    jne ui_destroy_now
    cmp dword ptr [ui_restart],0
    je ui_done_state
    mov dword ptr [ui_restart],0
    call ui_request
    jmp ui_handled
ui_done_state:
    mov dword ptr [ui_controls],1
    mov dword ptr [ui_state],2
    cmp dword ptr [rsp+112],0
    je ui_done_position
    mov dword ptr [ui_state],3
    jmp ui_done_repaint
ui_done_position:
    mov rax,[total_frames]
    mov [engine_position],rax
ui_done_repaint:
    call ui_invalidate
    jmp ui_handled
ui_wm_close:
    cmp qword ptr [ui_thread],0
    je ui_destroy_now
    mov dword ptr [ui_closing],1
    mov dword ptr [ui_restart],0
    call engine_stop
    jmp ui_handled
ui_destroy_now:
    mov rcx,[ui_hwnd]
    call DestroyWindow
    jmp ui_handled
ui_wm_destroy:
    call ui_release_buffer
    mov rcx,[ui_font]
    call DeleteObject
    mov rcx,[ui_big_font]
    call DeleteObject
    xor ecx,ecx
    call PostQuitMessage
    jmp ui_handled
ui_wm_paint:
    mov [ui_hwnd],rcx
    lea rdx,ui_paint
    call BeginPaint
    mov [rsp+128],rax
    call ui_draw
    mov rcx,[rsp+128]
    xor edx,edx
    xor r8d,r8d
    mov r9d,[ui_width]
    mov eax,[ui_height]
    mov [rsp+32],rax
    mov rax,[ui_dc]
    mov [rsp+40],rax
    mov qword ptr [rsp+48],0
    mov qword ptr [rsp+56],0
    mov qword ptr [rsp+64],00cc0020h
    call BitBlt
    mov rcx,[ui_hwnd]
    lea rdx,ui_paint
    call EndPaint
ui_handled:
    xor eax,eax
ui_wm_return:
    add rsp,136
    ret
ui_window_proc ENDP
include ui_draw.inc
END
