# LAMP native Win32 UI. Original x86-64 assembly, MIT.
# Rhun reference: custom pixel buffer + Win32 presentation, compact monospace
# chrome. mpv reference: uncluttered canvas and on-screen playback controls.
.include "lamp.inc"
.globl ui_width, ui_height, ui_pixels, ui_bmi, ui_state, ui_filename, ui_thread, ui_count, ui_layout
.equ WM_WORKER_DONE, 0x8001
.equ WM_FILE_OPENED, 0x8002
.data
ui_class: .short 'L', 'a', 'm', 'p', 'W', 'i', 'n', 'd', 'o', 'w', 0
ui_title: .short 'L', 'A', 'M', 'P', ' ', '-', ' ', 'L', 'e', 'v', 39, 's', ' ', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', ' ', 'M', 'e', 'd', 'i', 'a', ' ', 'P', 'l', 'a', 'y', 'e', 'r', 0
ui_brand: .short 'l', 'a', 'm', 'p', 0
ui_assembly: .short 'x', '8', '6', '-', '6', '4', ' ', '/', ' ', 'a', 's', 's', 'e', 'm', 'b', 'l', 'y', 0
ui_drop: .short 'D', 'r', 'o', 'p', ' ', 'a', 'n', ' ', 'a', 'u', 'd', 'i', 'o', ' ', 'f', 'i', 'l', 'e', 0
ui_open: .short 'O', 'p', 'e', 'n', ' ', 'f', 'i', 'l', 'e', 0
ui_hint: .short 'O', ' ', 'o', 'p', 'e', 'n', ' ', ' ', ' ', 'S', 'p', 'a', 'c', 'e', ' ', 'p', 'a', 'u', 's', 'e', ' ', ' ', ' ', 'A', 'r', 'r', 'o', 'w', 's', ' '
    .short 's', 'e', 'e', 'k', ' ', '/', ' ', 'v', 'o', 'l', 'u', 'm', 'e', ' ', ' ', ' ', 'R', ' ', 'r', 'e', 'p', 'e', 'a', 't', 0
ui_hint_list: .short 'S', 'p', 'a', 'c', 'e', ' ', 'p', 'a', 'u', 's', 'e', ' ', ' ', ' ', 'A', 'r', 'r', 'o', 'w', 's', ' ', 's', 'e', 'e', 'k', ' ', '/', ' ', 'v', 'o'
    .short 'l', 'u', 'm', 'e', ' ', ' ', ' ', 'N', ' ', '/', ' ', 'P', ' ', 't', 'r', 'a', 'c', 'k', ' ', ' ', ' ', 'R', ' ', 'r', 'e', 'p', 'e', 'a', 't', ' '
    .short ' ', ' ', 'O', ' ', 'o', 'p', 'e', 'n', 0
ui_repeat_text: .short 'R', 'E', 'P', 'E', 'A', 'T', 0
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
    .quad ui_codec_ogg_flac, ui_codec_matroska, ui_codec_mp4, ui_codec_aac, ui_codec_ac3, ui_codec_wavpack, ui_codec_caf, ui_codec_avi, ui_codec_flv, ui_codec_au
    .quad ui_codec_ape, ui_codec_lpcm, ui_codec_gsm, ui_codec_eac3
ui_codec_mp4: .short 'M', 'P', '4', 0
ui_codec_aac: .short 'A', 'A', 'C', 0
ui_codec_ac3: .short 'A', 'C', '-', '3', 0
ui_codec_eac3: .short 'E', '-', 'A', 'C', '-', '3', 0
ui_codec_wavpack: .short 'W', 'A', 'V', 'P', 'A', 'C', 'K', 0
ui_codec_caf: .short 'C', 'A', 'F', 0
ui_codec_avi: .short 'A', 'V', 'I', 0
ui_codec_flv: .short 'F', 'L', 'V', 0
ui_codec_au: .short 'A', 'U', 0
ui_codec_ape: .short 'A', 'P', 'E', 0
ui_codec_lpcm: .short 'L', 'P', 'C', 'M', 0
ui_codec_gsm: .short 'G', 'S', 'M', 0
ui_font_name: .short 'C', 'o', 'n', 's', 'o', 'l', 'a', 's', 0
ui_filter: .short 'A', 'u', 'd', 'i', 'o', ' ', 'f', 'i', 'l', 'e', 's', 0
    .short '*', '.', 'w', 'a', 'v', ';', '*', '.', 'a', 'i', 'f', ';', '*', '.', 'a', 'i', 'f', 'f', ';', '*', '.', 'a', 'i', 'f', 'c', ';'
    .short '*', '.', 'f', 'l', 'a', 'c', ';', '*', '.', 'm', 'p', '3', ';', '*', '.', 'o', 'g', 'g', ';', '*', '.', 'o', 'p', 'u', 's', ';', '*', '.', 'o', 'g', 'a', ';'
    .short '*', '.', 'm', 'p', '2', ';', '*', '.', 'm', 'p', '1', ';', '*', '.', 'm', 'p', 'a', ';', '*', '.', 'm', 'k', 'a', ';', '*', '.', 'm', 'k', 'v', ';', '*', '.', 'w', 'e', 'b', 'm', ';', '*', '.', 'm', '4', 'a', ';', '*', '.', 'm', '4', 'b', ';', '*', '.', 'm', 'p', '4', ';', '*', '.', 'm', 'o', 'v', ';', '*', '.', 'a', 'a', 'c', ';', '*', '.', 'l', 'o', 'a', 's', ';', '*', '.', 'l', 'a', 't', 'm', ';', '*', '.', 'a', 'c', '3', ';', '*', '.', 'e', 'a', 'c', '3', ';', '*', '.', 'e', 'c', '3', ';', '*', '.', 'w', 'v', ';', '*', '.', 'a', 'p', 'e', ';', '*', '.', 'c', 'a', 'f', ';', '*', '.', 'w', '6', '4', ';', '*', '.', 'a', 'v', 'i', ';', '*', '.', 'f', 'l', 'v', ';', '*', '.', 'a', 'u', ';', '*', '.', 's', 'n', 'd', ';'
    .short '*', '.', 't', 's', ';', '*', '.', 'm', '2', 't', 's', ';', '*', '.', 'm', 't', 's', ';', '*', '.', 'm', 'p', 'g', ';', '*', '.', 'm', 'p', 'e', 'g', ';', '*', '.', 'v', 'o', 'b', ';'
    .short '*', '.', 'm', '3', 'u', ';', '*', '.', 'm', '3', 'u', '8', ';', '*', '.', 'p', 'l', 's', 0
    .short 'A', 'l', 'l', ' ', 'f', 'i', 'l', 'e', 's', 0, '*', '.', '*', 0, 0
# Layout in pixels: at the window's DPI, then at 96 DPI (ui_layout scales
# the first from the second).
.p2align 2
ui_layout_start:
px_header: .long 52, 52             # header height
px_strip: .long 30, 30              # status strip height
px_margin: .long 24, 24             # left and right text margin; the previous button
px_brand_y: .long 17, 17            # header text
px_assembly: .long 210, 210         # the assembly label, from the right
px_status_y: .long 23, 23           # status text, from the bottom
px_codec: .long 134, 134            # codec label
px_hint_y: .long 164, 164           # hints, from the bottom
px_side: .long 32, 32               # timeline, hint and title margins
px_timeline_y: .long 106, 106       # timeline, from the bottom
px_timeline_h: .long 4, 4
px_time_x: .long 96, 96             # position text
px_time_y: .long 71, 71             # position text, from the bottom
px_list_shift: .long 10, 10         # play/pause moves right with a list
px_next_x: .long 86, 86             # the next button
px_icon_y: .long 70, 70             # previous/next buttons, from the bottom
px_pause_x: .long 42, 42            # pause bars
px_pause_x2: .long 54, 54
px_bar_w: .long 5, 5
px_bar_h: .long 20, 20
px_play_y: .long 73, 73             # play/pause, from the bottom
px_triangle_x: .long 44, 44         # play triangle
px_volume_text_x: .long 178, 178    # volume text, from the right
px_volume_text_y: .long 78, 78      # volume text, from the bottom
px_volume_x: .long 180, 180         # volume bar, from the right
px_volume_y: .long 49, 49           # volume bar, from the bottom
px_volume_w: .long 148, 148
px_volume_h: .long 3, 3
px_title_h: .long 42, 42            # title line
px_text_h: .long 24, 24             # other lines
px_title_y: .long 36, 36            # title without a picture: above the middle by this
px_cover_max: .long 360, 360        # cover art side
px_cover_min: .long 48, 48
px_cover_gap: .long 12, 12          # between the picture and the title
px_controls: .long 130, 130         # clicks: the controls, from the bottom
px_row: .long 42, 42                # clicks: the timeline row
px_click_play: .long 95, 95         # clicks: play/pause without a list
px_click_previous: .long 47, 47     # clicks with a list
px_click_pause: .long 79, 79
px_click_next: .long 112, 112
px_window_w: .long 820, 820         # the window
px_window_h: .long 510, 510
px_min_w: .long 480, 480
px_min_h: .long 330, 330
px_font: .long 17, 17               # font heights
px_big_font: .long 30, 30
ui_layout_end:
ui_dpi: .long 96
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
ui_filename: .zero 8                    # the name of the file opening
ui_time_text: .zero 64*2
ui_list_text: .zero 64*2
ui_volume_text: .zero 32*2
.text
FN ui_start
    sub rsp, 136
    mov dword ptr [rip + engine_mode], 1
    lea rax, [rip + ui_file_opened]
    mov [rip + engine_opened], rax
    mov rcx, -4                           # per-monitor DPI awareness, version 2
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
    mov r9d, 0x02cf0000                   # OVERLAPPEDWINDOW | CLIPCHILDREN
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
    call GetDpiForWindow                  # the layout, and the window, at its DPI
    mov ecx, eax
    call ui_layout
    cmp dword ptr [rip + ui_dpi], 96
    je .Lui_sized
    mov rcx, [rip + ui_hwnd]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, [rip + px_window_w]
    mov [rsp + 32], rax
    mov eax, [rip + px_window_h]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x16        # NOMOVE | NOZORDER | NOACTIVATE
    call SetWindowPos
.Lui_sized:
    call ui_controls_create
    mov rcx, [rip + ui_hwnd]
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
    jb .Lui_free_args
    call ui_list_begin                    # the files and folders named: a list
    test eax, eax
    jz .Lui_free_args
    mov dword ptr [rsp + 104], 1
.Lui_argument:
    mov eax, [rsp + 104]
    cmp eax, [rip + ui_argc]
    jae .Lui_arguments_listed
    mov rcx, [rsp + 96]
    mov rcx, [rcx + rax*8]
    xor edx, edx
    call ui_list_path
    inc dword ptr [rsp + 104]
    jmp .Lui_argument
.Lui_arguments_listed:
    call ui_list_end
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
    call ui_controls_key
    test eax, eax
    jnz .Lui_message_loop
    lea rcx, [rip + ui_message]
    call TranslateMessage
    lea rcx, [rip + ui_message]
    call DispatchMessageW
    jmp .Lui_message_loop
.Lui_exit:
    xor ecx, ecx
    call ExitProcess
ENDFN ui_start

# O: files chosen in the open dialog (several at once) become the list.
LOCALFN ui_open_dialog
    sub rsp, 40
    mov dword ptr [rip + ui_ofn], 152
    mov rax, [rip + ui_hwnd]
    mov qword ptr [rip + ui_ofn + 8], rax
    lea rax, [rip + ui_filter]
    mov qword ptr [rip + ui_ofn + 24], rax
    mov dword ptr [rip + ui_ofn + 44], 1
    lea rax, [rip + ui_dialog_text]
    mov qword ptr [rip + ui_ofn + 48], rax
    mov dword ptr [rip + ui_ofn + 56], 65536
    mov dword ptr [rip + ui_ofn + 96], 0x0081208 # EXPLORER | FILEMUSTEXIST | ALLOWMULTISELECT | NOCHANGEDIR
    mov word ptr [rip + ui_dialog_text], 0
    lea rcx, [rip + ui_ofn]
    call GetOpenFileNameW
    test eax, eax
    jz .Lui_dialog_done
    call ui_list_dialog
    call ui_request
.Lui_dialog_done:
    add rsp, 40
    ret
ENDFN ui_open_dialog

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

# ECX=DPI: the layout at it; the fonts are made again at the next paint.
FN ui_layout
    sub rsp, 40
    test ecx, ecx
    jnz .Lui_layout_dpi
    mov ecx, 96
.Lui_layout_dpi:
    mov [rip + ui_dpi], ecx
    lea r8, [rip + ui_layout_start]
    lea r9, [rip + ui_layout_end]
.Lui_layout_entry:
    cmp r8, r9
    jae .Lui_layout_fonts
    mov ecx, [r8 + 4]
    call ui_px
    mov [r8], eax
    add r8, 8
    jmp .Lui_layout_entry
.Lui_layout_fonts:
    cmp dword ptr [rip + ui_compact], 0
    je .Lui_layout_release
    mov ecx, 220
    call ui_px
    mov [rip + px_min_h], eax
    mov ecx, 20
    call ui_px
    mov [rip + px_big_font], eax
.Lui_layout_release:
    call ui_release_buffer                # fonts and canvas again
    mov dword ptr [rip + ui_buffer_width], 0
    xor ecx, ecx
    xchg rcx, [rip + ui_font]
    call DeleteObject
    xor ecx, ecx
    xchg rcx, [rip + ui_big_font]
    call DeleteObject
    add rsp, 40
    ret
ENDFN ui_layout

# ECX=pixels at 96 DPI -> EAX=at the window's DPI, rounded.
LOCALFN ui_px
    mov eax, ecx
    imul eax, [rip + ui_dpi]
    add eax, 48
    cdq
    mov ecx, 96
    idiv ecx
    ret
ENDFN ui_px

# Space: pauses or resumes; with nothing playing, plays the list again
# from its first file (or opens files when there is none).
LOCALFN ui_toggle
    sub rsp, 40
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_toggle_replay
    call engine_pause
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_toggle_paused
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    mov r8d, 250
    xor r9d, r9d
    call SetTimer
.Lui_toggle_paused:
    call ui_schedule
    mov dword ptr [rip + ui_controls], 1
    call ui_invalidate
    jmp .Lui_toggle_return
.Lui_toggle_replay:
    cmp dword ptr [rip + ui_count], 0
    jne .Lui_toggle_list
    cmp dword ptr [rip + ui_list_new], 0
    jne .Lui_toggle_list
    call ui_open_dialog
    jmp .Lui_toggle_return
.Lui_toggle_list:
    mov dword ptr [rip + pause_requested], 0
    xor ecx, ecx
    xor edx, edx
    call ui_play_at
.Lui_toggle_return:
    add rsp, 40
    ret
ENDFN ui_toggle

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
    cmp edx, WM_FILE_OPENED
    je .Lui_wm_opened
    cmp edx, 0x319
    je .Lui_wm_command
    cmp edx, 0x7b
    je .Lui_wm_context
    cmp edx, 0x111
    je .Lui_wm_menu
    cmp edx, 0x2b                        # WM_DRAWITEM
    je .Lui_wm_draw_control
    cmp edx, 0x114                       # WM_HSCROLL
    je .Lui_wm_slider
    cmp edx, 0x4e                        # WM_NOTIFY, native trackbar painting
    je .Lui_wm_notify
    cmp edx, 0x10
    je .Lui_wm_close
    cmp edx, 2
    je .Lui_wm_destroy
    call DefWindowProcW
    jmp .Lui_wm_return
.Lui_wm_minmax:
    mov eax, [rip + px_min_w]
    mov [r9 + 24], eax
    mov eax, [rip + px_min_h]
    mov [r9 + 28], eax
    jmp .Lui_handled
.Lui_wm_dpi:
    # Another DPI: the layout and fonts at it, and Windows' recommended
    # rectangle.
    movzx ecx, r8w
    call ui_layout
    mov rcx, [rip + ui_hwnd]
    mov rax, [rsp + 120]
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
    mov dword ptr [rip + ui_keyboard_focus], 0
    call ui_activity
    jmp .Lui_handled
.Lui_wm_timer:
    cmp r8d, 2
    je .Lui_timer_heard
    cmp dword ptr [rip + ui_closing], 0
    jne .Lui_timer_quiet
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_timer_paused
    cmp dword ptr [rip + ui_keyboard_focus], 0
    je .Lui_timer_mouse_focus
    call GetFocus
    mov rdx, rax
    mov rcx, [rip + ui_hwnd]
    call IsChild
    test eax, eax
    jnz .Lui_timer_quiet                 # keyboard controls remain visible
.Lui_timer_mouse_focus:
    call GetTickCount64
    sub rax, [rip + ui_last_activity]
    cmp rax, 2500
    jb .Lui_timer_quiet
    cmp dword ptr [rip + engine_ready], 0
    je .Lui_timer_quiet
    mov dword ptr [rip + ui_controls], 0
    call GetFocus
    mov rdx, rax
    mov rcx, [rip + ui_hwnd]
    call IsChild
    test eax, eax
    jz .Lui_timer_hidden
    mov rcx, [rip + ui_hwnd]             # a hidden slider must not retain focus
    call SetFocus
.Lui_timer_hidden:
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
.Lui_timer_heard:
    call ui_invalidate                    # the next file is heard now
    call ui_schedule
    jmp .Lui_handled
.Lui_wm_opened:
    call ui_invalidate
    call ui_schedule
    jmp .Lui_handled
.Lui_wm_context:
    mov rcx, r9                           # WM_CONTEXTMENU: its screen point
    call ui_menu
    jmp .Lui_handled
.Lui_wm_menu:
    test r9, r9
    jz .Lui_wm_menu_activate
    mov eax, r8d
    shr eax, 16
    test eax, eax                        # only BN_CLICKED activates
    jnz .Lui_handled
.Lui_wm_menu_activate:
    movzx ecx, r8w                        # WM_COMMAND: a menu item
    call ui_menu_command
    jmp .Lui_handled
.Lui_wm_draw_control:
    mov rcx, r9
    call ui_control_draw
    jmp .Lui_wm_return
.Lui_wm_notify:
    mov rcx, r9
    call ui_slider_draw
    jmp .Lui_wm_return
.Lui_wm_slider:
    cmp r9, [rip + ui_control_hwnds + 5*8]
    je .Lui_wm_seek_slider
    cmp r9, [rip + ui_control_hwnds + 6*8]
    jne .Lui_handled
    mov rcx, r9
    mov edx, 0x400                       # TBM_GETPOS
    xor r8d, r8d
    xor r9d, r9d
    call SendMessageW
    jmp .Lui_set_volume
.Lui_wm_seek_slider:
    mov rcx, r9
    mov edx, 0x400
    xor r8d, r8d
    xor r9d, r9d
    call SendMessageW
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Lui_handled
    mov r8, [rip + ui_shown_frames]
    test r8, r8
    jz .Lui_handled
    # Convert the slider's 0-10000 position to presentation milliseconds.
    mul r8
    mov ecx, 10000
    div rcx
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    div rcx
    call ui_seek
    jmp .Lui_handled
.Lui_wm_command:
    # WM_APPCOMMAND from media keys and remotes.
    mov eax, r9d
    shr eax, 16
    and eax, 0x0fff
    cmp eax, 11                           # APPCOMMAND_MEDIA_NEXTTRACK
    je .Lui_command_next
    cmp eax, 12                           # APPCOMMAND_MEDIA_PREVIOUSTRACK
    je .Lui_command_previous
    cmp eax, 14                           # APPCOMMAND_MEDIA_PLAY_PAUSE
    je .Lui_command_pause
    call DefWindowProcW
    jmp .Lui_wm_return
.Lui_command_next:
    call ui_next
    jmp .Lui_command_done
.Lui_command_previous:
    call ui_previous
    jmp .Lui_command_done
.Lui_command_pause:
    call ui_toggle
.Lui_command_done:
    mov eax, 1
    jmp .Lui_wm_return
.Lui_wm_key:
    call ui_activity
    mov r8, [rsp + 112]
    cmp r8d, 0x7a                        # F11
    je .Lui_fullscreen_key
    cmp r8d, 0x46                        # F
    je .Lui_fullscreen_key
    cmp r8d, 0x43                        # C
    je .Lui_compact_key
    cmp r8d, 0x1b                        # Escape restores a windowed mode
    je .Lui_escape_key
    cmp r8d, 0x20
    je .Lui_toggle_pause
    cmp r8d, 0xb3                         # VK_MEDIA_PLAY_PAUSE
    je .Lui_toggle_pause
    cmp r8d, 0x4e                         # N
    je .Lui_next_key
    cmp r8d, 0xb0                         # VK_MEDIA_NEXT_TRACK
    je .Lui_next_key
    cmp r8d, 0x50                         # P
    je .Lui_previous_key
    cmp r8d, 0xb1                         # VK_MEDIA_PREV_TRACK
    je .Lui_previous_key
    cmp r8d, 0x52                         # R
    je .Lui_repeat_key
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
.Lui_fullscreen_key:
    call ui_fullscreen_toggle
    jmp .Lui_handled
.Lui_compact_key:
    call ui_compact_toggle
    jmp .Lui_handled
.Lui_escape_key:
    cmp dword ptr [rip + ui_fullscreen], 0
    jne .Lui_fullscreen_key
    cmp dword ptr [rip + ui_compact], 0
    jne .Lui_compact_key
    jmp .Lui_handled
.Lui_open_key:
    call ui_open_dialog
    jmp .Lui_handled
.Lui_next_key:
    call ui_next
    jmp .Lui_handled
.Lui_previous_key:
    call ui_previous
    jmp .Lui_handled
.Lui_repeat_key:
    xor dword ptr [rip + queue_repeat], 1  # read by the queue at the list's end
    call ui_invalidate
    jmp .Lui_handled
.Lui_seek_forward:
    call ui_heard_position
    lea rax, [rdx + 5000]
    call ui_seek
    jmp .Lui_handled
.Lui_seek_backward:
    call ui_heard_position
    lea rax, [rdx - 5000]
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
    call ui_toggle
    jmp .Lui_handled
.Lui_wm_click:
    mov dword ptr [rip + ui_keyboard_focus], 0
    call ui_activity
    mov r9, [rsp + 120]
    mov eax, r9d
    shr eax, 16
    mov ecx, [rip + ui_height]
    sub ecx, [rip + px_controls]
    cmp eax, ecx
    jb .Lui_canvas_click
    add ecx, [rip + px_row]
    cmp eax, ecx
    ja .Lui_transport_click
    # The timeline spans the width but its side margins.
    mov eax, r9d
    and eax, 0xffff
    sub eax, [rip + px_side]
    js .Lui_handled
    mov ecx, [rip + ui_width]
    sub ecx, [rip + px_side]
    sub ecx, [rip + px_side]
    cmp eax, ecx
    ja .Lui_handled
    mov r8, [rip + ui_shown_frames]
    test r8, r8
    jz .Lui_handled
    mul r8
    div rcx
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Lui_handled
    mov edx, 1000
    mul rdx
    div rcx
    call ui_seek
    jmp .Lui_handled
.Lui_transport_click:
    mov eax, r9d
    and eax, 0xffff
    cmp dword ptr [rip + ui_count], 2
    jb .Lui_transport_single
    cmp eax, [rip + px_click_previous]
    jb .Lui_previous_key
    cmp eax, [rip + px_click_pause]
    jb .Lui_toggle_pause
    cmp eax, [rip + px_click_next]
    jb .Lui_next_key
.Lui_transport_single:
    cmp eax, [rip + px_click_play]
    jb .Lui_toggle_pause
    mov ecx, [rip + ui_width]
    sub ecx, [rip + px_volume_x]
    sub eax, ecx
    js .Lui_handled
    mov ecx, [rip + px_volume_w]
    cmp eax, ecx
    ja .Lui_handled
    imul eax, 100
    xor edx, edx
    div ecx
    jmp .Lui_set_volume
.Lui_canvas_click:
    cmp qword ptr [rip + ui_thread], 0
    jne .Lui_toggle_pause
    jmp .Lui_open_key
.Lui_wm_drop:
    mov rcx, r8
    call ui_list_drop                     # the dropped files become the list
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
    mov rcx, [rip + ui_hwnd]
    mov edx, 2
    call KillTimer
    cmp dword ptr [rip + ui_restart], 0
    je .Lui_done_lost
    mov dword ptr [rip + ui_restart], 0
    call ui_request
    jmp .Lui_handled
.Lui_done_lost:
    cmp dword ptr [rip + engine_command], 5
    jne .Lui_done_repeat
    mov ecx, [rip + engine_heard_index]   # the endpoint was lost: reopen there
    mov rdx, [rip + engine_heard_ms]
    call ui_play_at
    jmp .Lui_handled
.Lui_done_repeat:
    # Repeat turned on after the queue read the last file: the list again.
    cmp dword ptr [rsp + 112], 0
    jne .Lui_done_state
    cmp dword ptr [rip + queue_repeat], 0
    je .Lui_done_state
    cmp qword ptr [rip + read_count], 0
    je .Lui_done_state
    xor ecx, ecx
    xor edx, edx
    call ui_play_at
    jmp .Lui_handled
.Lui_done_state:
    call ui_heard_update
    mov dword ptr [rip + ui_controls], 1
    mov dword ptr [rip + ui_state], 2
    cmp dword ptr [rsp + 112], 0
    je .Lui_done_position
    cmp dword ptr [rsp + 112], 2          # files skipped or failing in a list that played
    jne .Lui_done_error
    cmp qword ptr [rip + read_count], 0
    jne .Lui_done_position
.Lui_done_error:
    mov dword ptr [rip + ui_state], 3
    jmp .Lui_done_repaint
.Lui_done_position:
    mov rax, [rip + ui_shown_frames]      # the last file shown at its end
    test rax, rax
    jz .Lui_done_repaint
    add rax, [rip + ui_shown_start]
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
    call ui_controls_sync
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
.include "ui_cover.inc"
.include "ui_queue.inc"
.include "ui_modes.inc"
.include "ui_menu.inc"
.include "ui_controls.inc"
