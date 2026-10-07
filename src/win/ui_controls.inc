# Native child controls keep Win32 accessibility names, roles and values.
# Owner-drawn buttons copy the assembly canvas; trackbars provide native
# slider semantics. The message loop handles Tab; standard controls retain
# their own Space/arrow/Home/End behavior. Original assembly, MIT.
.equ UI_CONTROL_COUNT, 7
.data
ui_button_class: .short 'B','U','T','T','O','N',0
ui_slider_class: .short 'm','s','c','t','l','s','_','t','r','a','c','k','b','a','r','3','2',0
ui_control_open: .short 'O','p','e','n',' ','f','i','l','e','s',0
ui_control_previous: .short 'P','r','e','v','i','o','u','s',' ','t','r','a','c','k',0
ui_control_play: .short 'P','l','a','y',0
ui_control_pause: .short 'P','a','u','s','e',0
ui_control_next: .short 'N','e','x','t',' ','t','r','a','c','k',0
ui_control_repeat: .short 'R','e','p','e','a','t',' ','o','f','f',0
ui_control_repeat_on: .short 'R','e','p','e','a','t',' ','o','n',0
ui_control_seek: .short 'P','l','a','y','b','a','c','k',' ','p','o','s','i','t','i','o','n',0
ui_control_volume: .short 'V','o','l','u','m','e',0
.p2align 3
ui_control_names: .quad ui_control_open, ui_control_previous, ui_control_play, ui_control_next
    .quad ui_control_repeat, ui_control_seek, ui_control_volume
ui_control_ids: .long 100, 110, 111, 112, 101, 113, 114
ui_control_init: .long 8, 4             # INITCOMMONCONTROLSEX, ICC_BAR_CLASSES
ui_control_play_state: .long -1
ui_control_repeat_state: .long -1
.bss
.p2align 3
ui_control_hwnds: .zero UI_CONTROL_COUNT*8
ui_control_procs: .zero UI_CONTROL_COUNT*8
ui_keyboard_focus: .zero 4
ui_control_rects: .zero UI_CONTROL_COUNT*16  # x,y,width,height
ui_control_text: .zero 64*2
.text
LOCALFN ui_controls_create
    push rbx
    push rsi
    sub rsp, 104
    lea rcx, [rip + ui_control_init]
    call InitCommonControlsEx
    xor ebx, ebx
.Lui_control_create:
    xor ecx, ecx
    lea rdx, [rip + ui_button_class]
    mov r9d, 0x5001000b                  # CHILD | VISIBLE | TABSTOP | BS_OWNERDRAW
    cmp ebx, 5
    jb .Lui_control_button
    lea rdx, [rip + ui_slider_class]
    mov r9d, 0x50010010                  # TBS_NOTICKS
.Lui_control_button:
    lea rax, [rip + ui_control_names]
    mov r8, [rax + rbx*8]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 1
    mov qword ptr [rsp + 56], 1
    mov rax, [rip + ui_hwnd]
    mov [rsp + 64], rax
    lea rax, [rip + ui_control_ids]
    mov eax, [rax + rbx*4]
    mov [rsp + 72], rax
    mov rax, [rip + ui_instance]
    mov [rsp + 80], rax
    mov qword ptr [rsp + 88], 0
    call CreateWindowExW
    lea rsi, [rip + ui_control_hwnds]
    mov [rsi + rbx*8], rax
    mov rcx, rax
    mov edx, -4                          # GWLP_WNDPROC: observe pointer activity
    lea r8, [rip + ui_control_proc]
    call SetWindowLongPtrW
    lea rdx, [rip + ui_control_procs]
    mov [rdx + rbx*8], rax
    cmp ebx, 5
    jb .Lui_control_created
    mov rcx, [rsi + rbx*8]
    mov edx, 0x408                       # TBM_SETRANGEMAX
    xor r8d, r8d
    mov r9d, 100
    cmp ebx, 6
    je .Lui_control_range
    mov r9d, 10000                       # hundredths of presentation percent
.Lui_control_range:
    call SendMessageW
    mov rcx, [rsi + rbx*8]
    mov edx, 0x417                       # TBM_SETLINESIZE
    xor r8d, r8d
    mov r9d, 1
    cmp ebx, 6
    je .Lui_control_line_size
    mov r9d, 100                         # seek by one percent with arrows
.Lui_control_line_size:
    call SendMessageW
.Lui_control_created:
    inc ebx
    cmp ebx, UI_CONTROL_COUNT
    jb .Lui_control_create
    call ui_controls_sync
    add rsp, 104
    pop rsi
    pop rbx
    ret
ENDFN ui_controls_create

# Called after rendering. Rectangles and names follow DPI/mode/list state.
LOCALFN ui_controls_sync
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    cmp qword ptr [rip + ui_control_hwnds], 0
    je .Lui_controls_synced
    xor ebx, ebx
.Lui_controls_place:
    lea rsi, [rip + ui_control_rects]
    mov eax, ebx
    shl eax, 4
    add rsi, rax
    # Default transport geometry (the painted play/pause and skip icons).
    mov ecx, 32
    call ui_px
    mov [rsi + 8], eax
    mov [rsi + 12], eax
    mov ecx, 86
    call ui_px
    mov edx, [rip + ui_height]
    sub edx, eax
    mov [rsi + 4], edx
    cmp ebx, 0
    je .Lui_control_open_rect
    cmp ebx, 4
    je .Lui_control_repeat_rect
    cmp ebx, 5
    jae .Lui_control_slider_rect
    mov ecx, 20
    cmp ebx, 1
    je .Lui_control_transport_rect
    mov ecx, 82
    cmp ebx, 3
    je .Lui_control_transport_rect
    mov ecx, 38
    cmp dword ptr [rip + ui_count], 2
    jb .Lui_control_transport_rect
    add ecx, 10
.Lui_control_transport_rect:
    call ui_px
    mov [rsi], eax
    cmp ebx, 1
    jne .Lui_control_place
    mov ecx, 24                          # leave a gap before Play's focus outline
    call ui_px
    mov [rsi + 8], eax
    jmp .Lui_control_place
.Lui_control_open_rect:
    mov ecx, 148
    call ui_px
    mov edx, [rip + ui_width]
    sub edx, eax
    mov [rsi], edx
    mov ecx, 124
    jmp .Lui_control_header_rect
.Lui_control_repeat_rect:
    mov ecx, 252
    call ui_px
    mov edx, [rip + ui_width]
    sub edx, eax
    mov [rsi], edx
    mov ecx, 96
.Lui_control_header_rect:
    call ui_px
    mov [rsi + 8], eax
    mov ecx, 12
    call ui_px
    mov [rsi + 4], eax
    mov ecx, 28
    call ui_px
    mov [rsi + 12], eax
    jmp .Lui_control_place
.Lui_control_slider_rect:
    mov eax, [rip + px_side]
    mov [rsi], eax
    mov edx, [rip + ui_width]
    sub edx, eax
    sub edx, eax
    mov [rsi + 8], edx
    mov ecx, 120
    cmp ebx, 5
    je .Lui_control_slider_height
    mov eax, [rip + ui_width]
    sub eax, [rip + px_volume_x]
    mov [rsi], eax
    mov eax, [rip + px_volume_w]
    mov [rsi + 8], eax
    mov ecx, 63
.Lui_control_slider_height:
    call ui_px
    mov edx, [rip + ui_height]
    sub edx, eax
    mov [rsi + 4], edx
    mov ecx, 28
    call ui_px
    mov [rsi + 12], eax
.Lui_control_place:
    lea rdi, [rip + ui_control_hwnds]
    mov rcx, [rdi + rbx*8]
    xor edx, edx
    mov r8d, [rsi]
    mov r9d, [rsi + 4]
    mov eax, [rsi + 8]
    mov [rsp + 32], rax
    mov eax, [rsi + 12]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x1c       # NOZORDER | NOREDRAW | NOACTIVATE
    call SetWindowPos
    mov edx, 5                           # show unless inactive/hidden
    cmp ebx, 0
    je .Lui_control_show
    cmp ebx, 4
    je .Lui_control_show
    cmp dword ptr [rip + ui_controls], 0
    jne .Lui_control_list_visibility
    cmp dword ptr [rip + ui_state], 1
    jne .Lui_control_list_visibility
    xor edx, edx
.Lui_control_list_visibility:
    cmp ebx, 1
    je .Lui_control_skip_visibility
    cmp ebx, 3
    jne .Lui_control_show
.Lui_control_skip_visibility:
    cmp dword ptr [rip + ui_count], 2
    jae .Lui_control_show
    xor edx, edx
.Lui_control_show:
    mov rcx, [rdi + rbx*8]
    call ShowWindow
    mov rcx, [rdi + rbx*8]
    xor edx, edx
    xor r8d, r8d
    call InvalidateRect
    inc ebx
    cmp ebx, UI_CONTROL_COUNT
    jb .Lui_controls_place
    # Change accessible names only with playback/repeat state, not each paint.
    xor edi, edi
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_control_play_state
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_control_play_state
    mov edi, 1
.Lui_control_play_state:
    cmp edi, [rip + ui_control_play_state]
    je .Lui_control_repeat_state
    mov [rip + ui_control_play_state], edi
    lea rdx, [rip + ui_control_play]
    test edi, edi
    jz .Lui_control_play_name
    lea rdx, [rip + ui_control_pause]
.Lui_control_play_name:
    mov rcx, [rip + ui_control_hwnds + 2*8]
    call SetWindowTextW
.Lui_control_repeat_state:
    mov edi, [rip + queue_repeat]
    cmp edi, [rip + ui_control_repeat_state]
    je .Lui_control_names_synced
    mov [rip + ui_control_repeat_state], edi
    lea rdx, [rip + ui_control_repeat]
    test edi, edi
    jz .Lui_control_repeat_name
    lea rdx, [rip + ui_control_repeat_on]
.Lui_control_repeat_name:
    mov rcx, [rip + ui_control_hwnds + 4*8]
    call SetWindowTextW
.Lui_control_names_synced:
    call GetCapture
    cmp rax, [rip + ui_control_hwnds + 5*8]
    je .Lui_control_volume_sync
    mov rcx, [rip + ui_control_hwnds + 5*8]
    mov rax, [rip + engine_position]
    sub rax, [rip + ui_shown_start]
    jae .Lui_control_position
    xor eax, eax
.Lui_control_position:
    xor r9d, r9d
    mov r8, [rip + ui_shown_frames]
    test r8, r8
    jz .Lui_control_position_set
    cmp rax, r8
    cmova rax, r8
    mov edx, 10000
    mul rdx
    div r8
    mov r9, rax
.Lui_control_position_set:
    mov edx, 0x405                       # TBM_SETPOS
    mov r8d, 1
    call SendMessageW
.Lui_control_volume_sync:
    mov rcx, [rip + ui_control_hwnds + 6*8]
    mov edx, 0x405
    mov r8d, 1
    mov r9d, [rip + ui_volume_percent]
    call SendMessageW
.Lui_controls_synced:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_controls_sync

# RCX=MSG -> EAX=1 if dispatched here. Native controls retain their keys;
# global shortcuts reach the parent even while a child owns keyboard focus.
LOCALFN ui_controls_key
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    xor eax, eax
    cmp dword ptr [rsi + 8], 0x100
    jne .Lui_controls_key_return
    mov ebx, [rsi + 16]
    cmp ebx, 9
    je .Lui_controls_tab
    cmp qword ptr [rsi], 0
    je .Lui_controls_key_return
    mov rcx, [rip + ui_hwnd]
    mov rdx, [rsi]
    call IsChild
    test eax, eax
    jz .Lui_controls_key_return
    mov dword ptr [rip + ui_keyboard_focus], 1
    cmp ebx, 0x20                       # standard buttons activate on Space
    je .Lui_controls_native
    cmp ebx, 0x0d
    je .Lui_controls_enter
    cmp ebx, 0x21                       # PageUp through Down: native sliders
    jb .Lui_controls_forward
    cmp ebx, 0x28
    ja .Lui_controls_forward
    mov rax, [rsi]
    cmp rax, [rip + ui_control_hwnds + 5*8]
    je .Lui_controls_native
    cmp rax, [rip + ui_control_hwnds + 6*8]
    je .Lui_controls_native
.Lui_controls_forward:
    mov rcx, [rip + ui_hwnd]
    mov edx, 0x100
    mov r8d, ebx
    mov r9, [rsi + 24]
    call SendMessageW
    jmp .Lui_controls_consumed
.Lui_controls_enter:
    mov rcx, [rsi]
    mov edx, 0xf5                        # BM_CLICK; sliders ignore it
    xor r8d, r8d
    xor r9d, r9d
    call SendMessageW
    jmp .Lui_controls_consumed
.Lui_controls_tab:
    mov dword ptr [rip + ui_keyboard_focus], 1
    call ui_activity
    call GetFocus
    lea rdx, [rip + ui_control_hwnds]
    mov ebx, -1
.Lui_controls_focus_find:
    inc ebx
    cmp ebx, UI_CONTROL_COUNT
    jae .Lui_controls_focus_default
    cmp rax, [rdx + rbx*8]
    jne .Lui_controls_focus_find
    jmp .Lui_controls_focus_shift
.Lui_controls_focus_default:
    mov ebx, -1
.Lui_controls_focus_shift:
    mov ecx, 0x10                       # Shift
    call GetKeyState
    mov esi, 1
    test ax, 0x8000
    jz .Lui_controls_focus_next
    mov esi, -1
.Lui_controls_focus_next:
    add ebx, esi
    cmp ebx, 0
    jge .Lui_controls_focus_upper
    mov ebx, UI_CONTROL_COUNT - 1
.Lui_controls_focus_upper:
    cmp ebx, UI_CONTROL_COUNT
    jb .Lui_controls_focus_skip
    xor ebx, ebx
.Lui_controls_focus_skip:
    cmp dword ptr [rip + ui_count], 2
    jae .Lui_controls_focus_set
    cmp ebx, 1
    je .Lui_controls_focus_next
    cmp ebx, 3
    je .Lui_controls_focus_next
.Lui_controls_focus_set:
    lea rax, [rip + ui_control_hwnds]
    mov rcx, [rax + rbx*8]
    call SetFocus
.Lui_controls_consumed:
    mov eax, 1
    jmp .Lui_controls_key_return
.Lui_controls_native:
    xor eax, eax
.Lui_controls_key_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN ui_controls_key

# Mouse use resumes auto-hiding; keyboard focus keeps controls visible.
# Forward every message to the original native procedure, retaining its
# pointer, keyboard and accessibility behavior.
LOCALFN ui_control_proc
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 56
    mov rbx, rcx
    mov esi, edx
    mov r12, r8
    mov r13, r9
    cmp edx, 0x200                      # WM_MOUSEMOVE
    je .Lui_control_mouse
    cmp edx, 0x201                      # WM_LBUTTONDOWN
    jne .Lui_control_forward
.Lui_control_mouse:
    mov dword ptr [rip + ui_keyboard_focus], 0
    call ui_activity
.Lui_control_forward:
    xor eax, eax
    lea rdx, [rip + ui_control_hwnds]
.Lui_control_proc_find:
    cmp rbx, [rdx + rax*8]
    je .Lui_control_proc_found
    inc eax
    cmp eax, UI_CONTROL_COUNT
    jb .Lui_control_proc_find
    mov rcx, rbx
    mov edx, esi
    mov r8, r12
    mov r9, r13
    call DefWindowProcW
    jmp .Lui_control_proc_return
.Lui_control_proc_found:
    lea rcx, [rip + ui_control_procs]
    mov rcx, [rcx + rax*8]
    mov rdx, rbx
    mov r8d, esi
    mov r9, r12
    mov [rsp + 32], r13
    call CallWindowProcW
.Lui_control_proc_return:
    add rsp, 56
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
ENDFN ui_control_proc

# RCX=DRAWITEMSTRUCT, EAX=handled. Only our owner-drawn buttons.
LOCALFN ui_control_draw
    push rbx
    push rsi
    sub rsp, 88
    mov rbx, rcx
    mov eax, [rbx + 4]
    xor esi, esi
.Lui_control_draw_find:
    lea rdx, [rip + ui_control_ids]
    cmp eax, [rdx + rsi*4]
    je .Lui_control_draw_found
    inc esi
    cmp esi, 5
    jb .Lui_control_draw_find
    xor eax, eax
    jmp .Lui_control_draw_return
.Lui_control_draw_found:
    cmp qword ptr [rip + ui_dc], 0
    je .Lui_control_draw_done
    lea rax, [rip + ui_control_rects]
    mov edx, esi
    shl edx, 4
    add rax, rdx
    mov rcx, [rbx + 32]                  # hDC
    xor edx, edx
    xor r8d, r8d
    mov r9d, [rax + 8]
    mov r10d, [rax + 12]
    mov [rsp + 32], r10
    mov r10, [rip + ui_dc]
    mov [rsp + 40], r10
    mov r10d, [rax]
    mov [rsp + 48], r10
    mov r10d, [rax + 4]
    mov [rsp + 56], r10
    mov qword ptr [rsp + 64], 0xcc0020
    call BitBlt
    cmp esi, 0
    je .Lui_control_draw_label
    cmp esi, 4
    jne .Lui_control_draw_focus
.Lui_control_draw_label:
    mov rcx, [rbx + 24]                  # hwndItem
    lea rdx, [rip + ui_control_text]
    mov r8d, 64
    call GetWindowTextW
    mov rcx, [rbx + 32]
    mov rdx, [rip + ui_font]
    call SelectObject
    mov rcx, [rbx + 32]
    mov edx, 1
    call SetBkMode
    mov rcx, [rbx + 32]
    mov edx, 0xede8e2
    call SetTextColor
    mov rcx, [rbx + 32]
    lea rdx, [rip + ui_control_text]
    mov r8d, -1
    lea r9, [rbx + 40]                  # rcItem
    mov qword ptr [rsp + 32], 0x825      # CENTER | VCENTER | SINGLELINE | NOPREFIX
    call DrawTextW
.Lui_control_draw_focus:
    test dword ptr [rbx + 16], 0x10      # ODS_FOCUS
    jz .Lui_control_draw_done
    mov rcx, [rbx + 32]
    lea rdx, [rbx + 40]
    call DrawFocusRect
.Lui_control_draw_done:
    mov eax, 1
.Lui_control_draw_return:
    add rsp, 88
    pop rsi
    pop rbx
    ret
ENDFN ui_control_draw

# NM_CUSTOMDRAW keeps the existing assembly bars while the real trackbars
# provide keyboard, pointer and accessibility behavior. The parent clips
# child windows so a timer repaint cannot erase their focus indicators.
LOCALFN ui_slider_draw
    push rbx
    push rsi
    sub rsp, 88
    mov rbx, rcx
    xor eax, eax
    cmp dword ptr [rbx + 16], -12        # NM_CUSTOMDRAW
    jne .Lui_slider_draw_return
    cmp dword ptr [rbx + 24], 1          # CDDS_PREPAINT
    jne .Lui_slider_draw_return
    mov esi, 5
    mov rcx, [rbx]
    cmp rcx, [rip + ui_control_hwnds + 5*8]
    je .Lui_slider_draw_found
    inc esi
    cmp rcx, [rip + ui_control_hwnds + 6*8]
    jne .Lui_slider_draw_return
.Lui_slider_draw_found:
    cmp qword ptr [rip + ui_dc], 0
    je .Lui_slider_draw_return
    lea rax, [rip + ui_control_rects]
    mov edx, esi
    shl edx, 4
    add rax, rdx
    mov rcx, [rbx + 32]                  # NMCUSTOMDRAW.hdc
    xor edx, edx
    xor r8d, r8d
    mov r9d, [rax + 8]
    mov r10d, [rax + 12]
    mov [rsp + 32], r10
    mov r10, [rip + ui_dc]
    mov [rsp + 40], r10
    mov r10d, [rax]
    mov [rsp + 48], r10
    mov r10d, [rax + 4]
    mov [rsp + 56], r10
    mov qword ptr [rsp + 64], 0xcc0020
    call BitBlt
    call GetFocus
    cmp rax, [rbx]
    jne .Lui_slider_draw_done
    mov rcx, [rbx + 32]
    lea rdx, [rbx + 40]                  # NMCUSTOMDRAW.rc
    call DrawFocusRect
.Lui_slider_draw_done:
    mov eax, 4                          # CDRF_SKIPDEFAULT
.Lui_slider_draw_return:
    add rsp, 88
    pop rsi
    pop rbx
    ret
ENDFN ui_slider_draw
