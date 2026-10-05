# LAMP native Win32 UI. Original x86-64 assembly, MIT.
# Rhun reference: custom pixel buffer + Win32 presentation, compact monospace
# chrome. mpv reference: uncluttered canvas and on-screen playback controls.
.include "lamp.inc"
.globl ui_width, ui_height, ui_pixels, ui_bmi, ui_state, ui_filename, ui_thread
.equ WM_WORKER_DONE, 0x8001
.data
ui_class: .short 'L', 'a', 'm', 'p', 'W', 'i', 'n', 'd', 'o', 'w', 0
ui_title: .short 'L', 'A', 'M', 'P', ' ', '-', ' ', 'L', 'e', 'v', 39, 's', ' ', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', ' ', 'M', 'e', 'd', 'i', 'a', ' ', 'P', 'l', 'a', 'y', 'e', 'r', 0
ui_brand: .short 'l', 'a', 'm', 'p', 0
ui_assembly: .short 'x', '8', '6', '-', '6', '4', ' ', '/', ' ', 'a', 's', 's', 'e', 'm', 'b', 'l', 'y', 0
ui_drop: .short 'D', 'r', 'o', 'p', ' ', 'a', 'n', ' ', 'a', 'u', 'd', 'i', 'o', ' ', 'f', 'i', 'l', 'e', 0
ui_open: .short 'O', 'p', 'e', 'n', ' ', 'f', 'i', 'l', 'e', 0
ui_hint: .short 'O', ' ', 'o', 'p', 'e', 'n', ' ', ' ', ' ', 'S', 'p', 'a', 'c', 'e', ' ', 'p', 'a', 'u', 's', 'e'
    .short ' ', ' ', ' ', 'A', 'r', 'r', 'o', 'w', 's', ' ', 's', 'e', 'e', 'k', ' ', '/', ' ', 'v', 'o', 'l', 'u', 'm', 'e', 0
ui_ready: .short 'R', 'E', 'A', 'D', 'Y', 0
ui_playing: .short 'P', 'L', 'A', 'Y', 'I', 'N', 'G', 0
ui_paused: .short 'P', 'A', 'U', 'S', 'E', 'D', 0
ui_loading: .short 'L', 'O', 'A', 'D', 'I', 'N', 'G', 0
ui_finished: .short 'F', 'I', 'N', 'I', 'S', 'H', 'E', 'D', 0
ui_failed: .short 'E', 'R', 'R', 'O', 'R', 0
ui_error: .short 'C', 'a', 'n', 'n', 'o', 't', ' ', 'p', 'l', 'a', 'y', ' ', 't', 'h', 'i', 's', ' ', 'f', 'i', 'l', 'e', 0
ui_error_detail: .short 'U', 'n', 's', 'u', 'p', 'p', 'o', 'r', 't', 'e', 'd', ' ', 'c', 'o', 'd', 'e', 'c', ',', ' ', 'd', 'a', 'm', 'a', 'g', 'e', 'd', ' ', 'f', 'i', 'l', 'e'
    .short ',', ' ', 'o', 'r', ' ', 'a', 'u', 'd', 'i', 'o', ' ', 'd', 'e', 'v', 'i', 'c', 'e', ' ', 'u', 'n', 'a', 'v', 'a', 'i', 'l', 'a', 'b', 'l', 'e', 0
ui_codec_wav: .short 'W', 'A', 'V', 0
ui_codec_flac: .short 'F', 'L', 'A', 'C', 0
ui_codec_mp3: .short 'M', 'P', '3', 0
ui_codec_vorbis: .short 'V', 'O', 'R', 'B', 'I', 'S', 0
ui_codec_opus: .short 'O', 'P', 'U', 'S', 0
ui_codec_aiff: .short 'A', 'I', 'F', 'F', '/', 'A', 'I', 'F', 'C', 0
ui_codec_ogg_flac: .short 'F', 'L', 'A', 'C', '/', 'O', 'G', 'G', 0
ui_codec_matroska: .short 'M', 'A', 'T', 'R', 'O', 'S', 'K', 'A', 0
ui_codec_names: .quad 0, ui_codec_wav, ui_codec_flac, ui_codec_mp3, ui_codec_vorbis, ui_codec_opus, ui_codec_aiff
    .quad ui_codec_ogg_flac, ui_codec_matroska, ui_codec_mp4, ui_codec_aac
ui_codec_mp4: .short 'M', 'P', '4', 0
ui_codec_aac: .short 'A', 'A', 'C', 0
ui_font_name: .short 'C', 'o', 'n', 's', 'o', 'l', 'a', 's', 0
ui_filter: .short 'A', 'u', 'd', 'i', 'o', ' ', 'f', 'i', 'l', 'e', 's', 0
    .short '*', '.', 'w', 'a', 'v', ';', '*', '.', 'a', 'i', 'f', ';', '*', '.', 'a', 'i', 'f', 'f', ';', '*', '.', 'a', 'i', 'f', 'c', ';'
    .short '*', '.', 'f', 'l', 'a', 'c', ';', '*', '.', 'm', 'p', '3', ';', '*', '.', 'o', 'g', 'g', ';', '*', '.', 'o', 'p', 'u', 's', ';', '*', '.', 'o', 'g', 'a', ';'
    .short '*', '.', 'm', 'p', '2', ';', '*', '.', 'm', 'p', '1', ';', '*', '.', 'm', 'p', 'a', ';', '*', '.', 'm', 'k', 'a', ';', '*', '.', 'm', 'k', 'v', ';', '*', '.', 'w', 'e', 'b', 'm', ';', '*', '.', 'm', '4', 'a', ';', '*', '.', 'm', '4', 'b', ';', '*', '.', 'm', 'p', '4', ';', '*', '.', 'm', 'o', 'v', ';', '*', '.', 'a', 'a', 'c', 0
    .short 'A', 'l', 'l', ' ', 'f', 'i', 'l', 'e', 's', 0, '*', '.', '*', 0, 0
ui_instance: .quad 0
ui_hwnd: .quad 0
ui_thread: .quad 0
ui_dc: .quad 0
ui_bitmap: .quad 0
ui_pixels: .quad 0
ui_original_bitmap: .quad 0
ui_font: .quad 0
ui_big_font: .quad 0
ui_width: .long 0
ui_height: .long 0
ui_buffer_width: .long 0
ui_buffer_height: .long 0
ui_state: .long 0               # 0 ready, 1 playing, 2 finished, 3 error
ui_restart: .long 0
ui_closing: .long 0
ui_controls: .long 1
ui_volume_percent: .long 100
ui_last_activity: .quad 0
ui_argc: .long 0
ui_volume_scale: .float 0.01
ui_background: .long 0x015181b
ui_surface: .long 0x01c2024
ui_line: .long 0x02f363d
ui_accent: .long 0x07ed6c4
ui_text_color: .long 0x0e2e8ed
ui_muted_color: .long 0x0939fa9
.bss
ui_wc: .zero 80
ui_message: .zero 48
ui_paint: .zero 72
ui_client: .zero 4*4
ui_text_rect: .zero 4*4
ui_bmi: .zero 40
ui_ofn: .zero 152
ui_pending: .zero 4096*2
ui_path: .zero 4096*2
ui_filename: .zero 8
ui_time_text: .zero 64*2
ui_volume_text: .zero 32*2
.text
FN ui_start
    sub rsp, 136
    mov dword ptr [rip + engine_mode], 1
    mov rcx, -4
    call SetProcessDpiAwarenessContext
    xor ecx, ecx
    call GetModuleHandleW
    mov [rip + ui_instance], rax
    mov dword ptr [rip + ui_wc], 80
    mov dword ptr [rip + ui_wc + 4], 3
    lea rax, [rip + ui_window_proc]
    mov qword ptr [rip + ui_wc + 8], rax
    mov rax, [rip + ui_instance]
    mov qword ptr [rip + ui_wc + 24], rax
    mov rcx, rax
    mov edx, 101
    call LoadIconW
    mov qword ptr [rip + ui_wc + 32], rax
    mov qword ptr [rip + ui_wc + 72], rax
    xor ecx, ecx
    mov edx, 32512
    call LoadCursorW
    mov qword ptr [rip + ui_wc + 40], rax
    lea rax, [rip + ui_class]
    mov qword ptr [rip + ui_wc + 64], rax
    lea rcx, [rip + ui_wc]
    call RegisterClassExW
    test eax, eax
    jz .Lui_exit
    xor ecx, ecx
    lea rdx, [rip + ui_class]
    lea r8, [rip + ui_title]
    mov r9d, 0x0cf0000
    mov qword ptr [rsp + 32], -0x80000000
    mov qword ptr [rsp + 40], -0x80000000
    mov qword ptr [rsp + 48], 820
    mov qword ptr [rsp + 56], 510
    mov qword ptr [rsp + 64], 0
    mov qword ptr [rsp + 72], 0
    mov rax, [rip + ui_instance]
    mov [rsp + 80], rax
    mov qword ptr [rsp + 88], 0
    call CreateWindowExW
    test rax, rax
    jz .Lui_exit
    mov [rip + ui_hwnd], rax
    mov rcx, rax
    mov edx, 1
    call DragAcceptFiles
    mov rcx, [rip + ui_hwnd]
    mov edx, 5
    call ShowWindow
    mov rcx, [rip + ui_hwnd]
    call UpdateWindow
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + ui_argc]
    call CommandLineToArgvW
    mov [rsp + 96], rax
    test rax, rax
    jz .Lui_message_loop
    cmp dword ptr [rip + ui_argc], 2
    jne .Lui_free_args
    mov rcx, [rax + 8]
    lea rdx, [rip + ui_pending]
    call ui_copy_path
    mov dword ptr [rip + engine_seek_seconds], 0
    call ui_request
.Lui_free_args:
    mov rcx, [rsp + 96]
    call LocalFree
.Lui_message_loop:
    lea rcx, [rip + ui_message]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call GetMessageW
    test eax, eax
    jle .Lui_exit
    lea rcx, [rip + ui_message]
    call TranslateMessage
    lea rcx, [rip + ui_message]
    call DispatchMessageW
    jmp .Lui_message_loop
.Lui_exit:
    xor ecx, ecx
    call ExitProcess
ENDFN ui_start

# Bounded Unicode copy. RCX=source, RDX=destination.
LOCALFN ui_copy_path
    xor r8d, r8d
.Lui_copy_char:
    movzx eax, word ptr [rcx + r8*2]
    mov [rdx + r8*2], ax
    test eax, eax
    jz .Lui_copy_done
    inc r8d
    cmp r8d, 4095
    jb .Lui_copy_char
    mov word ptr [rdx + r8*2], 0
.Lui_copy_done:
    ret
ENDFN ui_copy_path

LOCALFN ui_open_dialog
    sub rsp, 40
    mov dword ptr [rip + ui_ofn], 152
    mov rax, [rip + ui_hwnd]
    mov qword ptr [rip + ui_ofn + 8], rax
    lea rax, [rip + ui_filter]
    mov qword ptr [rip + ui_ofn + 24], rax
    mov dword ptr [rip + ui_ofn + 44], 1
    lea rax, [rip + ui_pending]
    mov qword ptr [rip + ui_ofn + 48], rax
    mov dword ptr [rip + ui_ofn + 56], 4096
    mov dword ptr [rip + ui_ofn + 96], 0x0081008 # EXPLORER | FILEMUSTEXIST | NOCHANGEDIR
    mov word ptr [rip + ui_pending], 0
    lea rcx, [rip + ui_ofn]
    call GetOpenFileNameW
    test eax, eax
    jz .Lui_dialog_done
    mov dword ptr [rip + engine_seek_seconds], 0
    mov dword ptr [rip + pause_requested], 0
    call ui_request
.Lui_dialog_done:
    add rsp, 40
    ret
ENDFN ui_open_dialog

LOCALFN ui_request
    sub rsp, 56
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_launch
    mov dword ptr [rip + ui_restart], 1
    call engine_stop
    jmp .Lui_request_done
.Lui_launch:
    lea rcx, [rip + ui_pending]
    lea rdx, [rip + ui_path]
    call ui_copy_path
    lea rax, [rip + ui_path]
    mov [rip + ui_filename], rax
.Lui_basename:
    movzx ecx, word ptr [rax]
    test ecx, ecx
    jz .Lui_basename_done
    add rax, 2
    cmp ecx, 0x5c
    je .Lui_basename_next
    cmp ecx, 0x2f
    jne .Lui_basename
.Lui_basename_next:
    mov [rip + ui_filename], rax
    jmp .Lui_basename
.Lui_basename_done:
    mov dword ptr [rip + ui_state], 1
    mov dword ptr [rip + ui_controls], 1
    mov dword ptr [rip + engine_stop_requested], 0
    mov dword ptr [rip + engine_ready], 0
    mov qword ptr [rip + engine_position], 0
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + ui_audio_thread]
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    mov [rip + ui_thread], rax
    test rax, rax
    jnz .Lui_timer_start
    mov dword ptr [rip + ui_state], 3
    jmp .Lui_request_done
.Lui_timer_start:
    call GetTickCount64
    mov [rip + ui_last_activity], rax
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    mov r8d, 250
    xor r9d, r9d
    call SetTimer
.Lui_request_done:
    call ui_invalidate
    add rsp, 56
    ret
ENDFN ui_request

LOCALFN ui_audio_thread
    sub rsp, 40
    lea rcx, [rip + ui_path]
    call engine_play
    mov rcx, [rip + ui_hwnd]
    mov edx, WM_WORKER_DONE
    mov r8d, eax
    xor r9d, r9d
    call PostMessageW
    xor eax, eax
    add rsp, 40
    ret
ENDFN ui_audio_thread

LOCALFN ui_invalidate
    sub rsp, 40
    mov rcx, [rip + ui_hwnd]
    xor edx, edx
    xor r8d, r8d
    call InvalidateRect
    add rsp, 40
    ret
ENDFN ui_invalidate

# Reveal controls and restart their timer only when previously hidden.
LOCALFN ui_activity
    sub rsp, 40
    call GetTickCount64
    mov [rip + ui_last_activity], rax
    cmp dword ptr [rip + ui_controls], 0
    jne .Lui_activity_done
    mov dword ptr [rip + ui_controls], 1
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_activity_repaint
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_activity_repaint
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    mov r8d, 250
    xor r9d, r9d
    call SetTimer
.Lui_activity_repaint:
    call ui_invalidate
.Lui_activity_done:
    add rsp, 40
    ret
ENDFN ui_activity

# EAX=absolute seek seconds, clamped before requesting a decoder restart.
LOCALFN ui_seek
    sub rsp, 40
    cmp word ptr [rip + ui_path], 0
    je .Lui_seek_done
    test eax, eax
    jns .Lui_seek_nonnegative
    xor eax, eax
.Lui_seek_nonnegative:
    mov [rsp + 32], eax
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lui_seek_done
    mov rax, [rip + output_frames]
    xor edx, edx
    div rcx
    test eax, eax
    jz .Lui_seek_done
    dec eax
    cmp eax, [rsp + 32]
    cmova eax, dword ptr [rsp + 32]
    mov [rip + engine_seek_seconds], eax
    lea rcx, [rip + ui_path]
    lea rdx, [rip + ui_pending]
    call ui_copy_path
    call ui_request
.Lui_seek_done:
    add rsp, 40
    ret
ENDFN ui_seek

LOCALFN ui_window_proc
    sub rsp, 136
    mov [rip + ui_hwnd], rcx
    mov [rsp + 96], rcx
    mov [rsp + 104], rdx
    mov [rsp + 112], r8
    mov [rsp + 120], r9
    cmp edx, 0xf
    je .Lui_wm_paint
    cmp edx, 0x14
    je .Lui_handled
    cmp edx, 5
    je .Lui_wm_size
    cmp edx, 0x24
    je .Lui_wm_minmax
    cmp edx, 0x2e0
    je .Lui_wm_dpi
    cmp edx, 0x100
    je .Lui_wm_key
    cmp edx, 0x201
    je .Lui_wm_click
    cmp edx, 0x200
    je .Lui_wm_mouse
    cmp edx, 0x113
    je .Lui_wm_timer
    cmp edx, 0x233
    je .Lui_wm_drop
    cmp edx, WM_WORKER_DONE
    je .Lui_wm_done
    cmp edx, 0x10
    je .Lui_wm_close
    cmp edx, 2
    je .Lui_wm_destroy
    call DefWindowProcW
    jmp .Lui_wm_return
.Lui_wm_minmax:
    mov dword ptr [r9 + 24], 480
    mov dword ptr [r9 + 28], 330
    jmp .Lui_handled
.Lui_wm_dpi:
    # Adopt Windows' recommended rectangle when moving between DPI domains.
    mov rax, r9
    xor edx, edx
    mov r8d, [rax]
    mov r9d, [rax + 4]
    mov r10d, [rax + 8]
    sub r10d, r8d
    mov [rsp + 32], r10
    mov r10d, [rax + 12]
    sub r10d, r9d
    mov [rsp + 40], r10
    mov qword ptr [rsp + 48], 0x14
    call SetWindowPos
    jmp .Lui_handled
.Lui_wm_size:
    mov eax, r9d
    and eax, 0xffff
    mov [rip + ui_width], eax
    shr r9d, 16
    mov [rip + ui_height], r9d
    call ui_invalidate
    jmp .Lui_handled
.Lui_wm_mouse:
    call ui_activity
    jmp .Lui_handled
.Lui_wm_timer:
    cmp dword ptr [rip + ui_closing], 0
    jne .Lui_timer_quiet
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_timer_paused
    call GetTickCount64
    sub rax, [rip + ui_last_activity]
    cmp rax, 2500
    jb .Lui_timer_quiet
    cmp dword ptr [rip + engine_ready], 0
    je .Lui_timer_quiet
    mov dword ptr [rip + ui_controls], 0
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    call KillTimer
.Lui_timer_quiet:
    call ui_invalidate
    jmp .Lui_handled
.Lui_timer_paused:
    cmp dword ptr [rip + engine_ready], 0
    je .Lui_timer_quiet
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    call KillTimer
    mov dword ptr [rip + ui_controls], 1
    call ui_invalidate
    jmp .Lui_handled
.Lui_wm_key:
    call ui_activity
    mov r8, [rsp + 112]
    cmp r8d, 0x20
    je .Lui_toggle_pause
    cmp r8d, 0x4f
    je .Lui_open_key
    cmp r8d, 0x27
    je .Lui_seek_forward
    cmp r8d, 0x25
    je .Lui_seek_backward
    cmp r8d, 0x24
    je .Lui_seek_home
    cmp r8d, 0x26
    je .Lui_volume_up
    cmp r8d, 0x28
    je .Lui_volume_down
    cmp r8d, 0x4d
    je .Lui_mute
    cmp r8d, 0x51
    je .Lui_wm_close
    jmp .Lui_handled
.Lui_open_key:
    call ui_open_dialog
    jmp .Lui_handled
.Lui_seek_forward:
    mov rax, [rip + engine_position]
    xor edx, edx
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lui_handled
    div rcx
    add eax, 5
    call ui_seek
    jmp .Lui_handled
.Lui_seek_backward:
    mov rax, [rip + engine_position]
    xor edx, edx
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lui_handled
    div rcx
    sub eax, 5
    call ui_seek
    jmp .Lui_handled
.Lui_seek_home:
    xor eax, eax
    call ui_seek
    jmp .Lui_handled
.Lui_volume_up:
    mov eax, [rip + ui_volume_percent]
    add eax, 5
    cmp eax, 100
    jbe .Lui_set_volume
    mov eax, 100
    jmp .Lui_set_volume
.Lui_volume_down:
    mov eax, [rip + ui_volume_percent]
    sub eax, 5
    jns .Lui_set_volume
    xor eax, eax
    jmp .Lui_set_volume
.Lui_mute:
    mov eax, 100
    cmp dword ptr [rip + ui_volume_percent], 0
    je .Lui_set_volume
    xor eax, eax
.Lui_set_volume:
    mov [rip + ui_volume_percent], eax
    cvtsi2ss xmm0, eax
    mulss xmm0, [rip + ui_volume_scale]
    movss [rip + engine_volume], xmm0
    call ui_invalidate
    jmp .Lui_handled
.Lui_toggle_pause:
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_replay
    call engine_pause
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_pause_no_timer
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    mov r8d, 250
    xor r9d, r9d
    call SetTimer
.Lui_pause_no_timer:
    mov dword ptr [rip + ui_controls], 1
    call ui_invalidate
    jmp .Lui_handled
.Lui_replay:
    cmp word ptr [rip + ui_path], 0
    je .Lui_open_key
    mov dword ptr [rip + engine_seek_seconds], 0
    mov dword ptr [rip + pause_requested], 0
    lea rcx, [rip + ui_path]
    lea rdx, [rip + ui_pending]
    call ui_copy_path
    call ui_request
    jmp .Lui_handled
.Lui_wm_click:
    call ui_activity
    mov r9, [rsp + 120]
    mov eax, r9d
    shr eax, 16
    mov ecx, [rip + ui_height]
    sub ecx, 130
    cmp eax, ecx
    jb .Lui_canvas_click
    add ecx, 42
    cmp eax, ecx
    ja .Lui_transport_click
    # Seek bar extends from x=32 to width-32.
    mov eax, r9d
    and eax, 0xffff
    sub eax, 32
    js .Lui_handled
    mov ecx, [rip + ui_width]
    sub ecx, 64
    cmp eax, ecx
    ja .Lui_handled
    mov rdx, [rip + output_frames]
    mul rdx
    div rcx
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lui_handled
    xor edx, edx
    div rcx
    call ui_seek
    jmp .Lui_handled
.Lui_transport_click:
    mov eax, r9d
    and eax, 0xffff
    cmp eax, 95
    jb .Lui_toggle_pause
    mov ecx, [rip + ui_width]
    sub ecx, 180
    sub eax, ecx
    js .Lui_handled
    cmp eax, 148
    ja .Lui_handled
    imul eax, 100
    xor edx, edx
    mov ecx, 148
    div ecx
    jmp .Lui_set_volume
.Lui_canvas_click:
    cmp qword ptr [rip + ui_thread], 0
    jne .Lui_toggle_pause
    jmp .Lui_open_key
.Lui_wm_drop:
    mov rcx, r8
    xor edx, edx
    lea r8, [rip + ui_pending]
    mov r9d, 4096
    call DragQueryFileW
    mov rcx, [rsp + 112]
    call DragFinish
    mov dword ptr [rip + engine_seek_seconds], 0
    mov dword ptr [rip + pause_requested], 0
    call ui_request
    jmp .Lui_handled
.Lui_wm_done:
    mov rcx, [rip + ui_thread]
    mov edx, -1
    call WaitForSingleObject
    mov rcx, [rip + ui_thread]
    call CloseHandle
    mov qword ptr [rip + ui_thread], 0
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    call KillTimer
    cmp dword ptr [rip + ui_closing], 0
    jne .Lui_destroy_now
    cmp dword ptr [rip + ui_restart], 0
    je .Lui_done_state
    mov dword ptr [rip + ui_restart], 0
    call ui_request
    jmp .Lui_handled
.Lui_done_state:
    mov dword ptr [rip + ui_controls], 1
    mov dword ptr [rip + ui_state], 2
    cmp dword ptr [rsp + 112], 0
    je .Lui_done_position
    mov dword ptr [rip + ui_state], 3
    jmp .Lui_done_repaint
.Lui_done_position:
    mov rax, [rip + output_frames]
    mov [rip + engine_position], rax
.Lui_done_repaint:
    call ui_invalidate
    jmp .Lui_handled
.Lui_wm_close:
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_destroy_now
    mov dword ptr [rip + ui_closing], 1
    mov dword ptr [rip + ui_restart], 0
    call engine_stop
    jmp .Lui_handled
.Lui_destroy_now:
    mov rcx, [rip + ui_hwnd]
    call DestroyWindow
    jmp .Lui_handled
.Lui_wm_destroy:
    call ui_release_buffer
    mov rcx, [rip + ui_font]
    call DeleteObject
    mov rcx, [rip + ui_big_font]
    call DeleteObject
    xor ecx, ecx
    call PostQuitMessage
    jmp .Lui_handled
.Lui_wm_paint:
    mov [rip + ui_hwnd], rcx
    lea rdx, [rip + ui_paint]
    call BeginPaint
    mov [rsp + 128], rax
    call ui_draw
    mov rcx, [rsp + 128]
    xor edx, edx
    xor r8d, r8d
    mov r9d, [rip + ui_width]
    mov eax, [rip + ui_height]
    mov [rsp + 32], rax
    mov rax, [rip + ui_dc]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    mov qword ptr [rsp + 64], 0x0cc0020
    call BitBlt
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_paint]
    call EndPaint
.Lui_handled:
    xor eax, eax
.Lui_wm_return:
    add rsp, 136
    ret
ENDFN ui_window_proc
.include "ui_draw.inc"
