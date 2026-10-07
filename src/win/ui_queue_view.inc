# Native virtual queue view. Original assembly, MIT.
# All row data belongs to the UI thread. Copy requested text into the native
# callback buffer; never lend a pointer across a list replacement.
# https://learn.microsoft.com/en-us/windows/win32/controls/list-view-controls-overview
# https://learn.microsoft.com/en-us/windows/win32/api/commctrl/ns-commctrl-nmlvdispinfow
.equ ID_QUEUE_VIEW, 107
.equ ID_QUEUE_LIST, 120
.data
ui_view_class: .short 'L','a','m','p','Q','u','e','u','e',0
ui_view_title: .short 'Q','u','e','u','e',' ','-',' ','L','A','M','P',0
ui_view_name: .short 'P','l','a','y','b','a','c','k',' ','q','u','e','u','e',0
ui_view_list_class: .short 'S','y','s','L','i','s','t','V','i','e','w','3','2',0
ui_view_menu: .short '&','Q','u','e','u','e',9,'L',0
ui_view_font_name: .short 'S','e','g','o','e',' ','U','I',0
ui_view_number: .short '#',0
ui_view_file: .short 'F','i','l','e',0
ui_view_status: .short 'S','t','a','t','e',0
ui_view_path: .short 'P','a','t','h',0
ui_view_empty: .short 0
ui_view_loading: .short 'L','o','a','d','i','n','g',0
ui_view_playing: .short 'P','l','a','y','i','n','g',0
ui_view_paused: .short 'P','a','u','s','e','d',0
ui_view_finished: .short 'F','i','n','i','s','h','e','d',0
ui_view_error: .short 'E','r','r','o','r',0
.p2align 3
ui_view_labels: .quad ui_view_number, ui_view_file, ui_view_status, ui_view_path
ui_view_states: .quad ui_view_loading, ui_view_playing, ui_view_paused, ui_view_finished, ui_view_error
ui_view_widths: .long 56, 280, 92, 600
ui_view_init: .long 8, 1             # ICC_LISTVIEW_CLASSES
ui_view_registered: .long 0
ui_view_dpi: .long 96
ui_view_index: .long -1
ui_view_state: .long -1
.p2align 3
ui_view_generation: .quad -1
ui_view_hwnd: .quad 0
ui_view_list: .quad 0
ui_view_font: .quad 0
.bss
ui_view_wc: .zero 80
.text

# RCX=LVITEMW. Only LVIF_TEXT is requested here. Invalid rows/generations
# yield an empty string. A truncated buffer never ends in half a surrogate.
LOCALFN ui_view_text
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov rbx, rcx
    test dword ptr [rbx], 1
    jz .Lview_text_return
    mov rdi, [rbx + 24]
    test rdi, rdi
    jz .Lview_text_return
    cmp dword ptr [rbx + 32], 0
    jle .Lview_text_return
    mov word ptr [rdi], 0
    mov rax, [rip + ui_view_generation]
    cmp rax, [rip + ui_list_generation]
    jne .Lview_text_return
    mov eax, [rbx + 4]
    cmp eax, [rip + ui_count]
    jae .Lview_text_return
    cmp qword ptr [rip + ui_paths], 0
    je .Lview_text_return
    mov edx, [rbx + 8]
    test edx, edx
    jz .Lview_text_number
    cmp edx, 2
    je .Lview_text_state
    cmp edx, 3
    ja .Lview_text_return
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rax*8]
    mov rsi, rcx
    cmp edx, 3
    je .Lview_text_copy
    call ui_basename
    mov rsi, rax
    jmp .Lview_text_copy
.Lview_text_number:
    inc eax
    lea rcx, [rsp + 32]
    call ui_number
    mov word ptr [rcx], 0
    lea rsi, [rsp + 32]
    jmp .Lview_text_copy
.Lview_text_state:
    cmp eax, [rip + ui_view_index]
    jne .Lview_text_return
    mov eax, [rip + ui_view_state]
    cmp eax, 4
    ja .Lview_text_return
    lea rcx, [rip + ui_view_states]
    mov rsi, [rcx + rax*8]
.Lview_text_copy:
    mov ecx, [rbx + 32]
    dec ecx
    xor edx, edx
.Lview_text_char:
    cmp edx, ecx
    jae .Lview_text_end
    movzx eax, word ptr [rsi + rdx*2]
    test eax, eax
    jz .Lview_text_end
    mov [rdi + rdx*2], ax
    inc edx
    jmp .Lview_text_char
.Lview_text_end:
    test edx, edx
    jz .Lview_text_zero
    movzx eax, word ptr [rdi + rdx*2 - 2]
    and eax, 0xfc00
    cmp eax, 0xd800
    jne .Lview_text_zero
    dec edx
.Lview_text_zero:
    mov word ptr [rdi + rdx*2], 0
.Lview_text_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_view_text

# RCX=NMLVFINDITEMW. Bounded Unicode filename search, wrapping at most once.
# LVFI_STRING exact and LVFI_PARTIAL prefix requests are supported. Ordinal
# case folding uses Windows' Unicode table, independent of UI locale.
LOCALFN ui_view_find
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov rax, [rip + ui_view_generation]
    cmp rax, [rip + ui_list_generation]
    jne .Lview_find_none
    test dword ptr [rbx + 32], 0x0a     # STRING | PARTIAL
    jz .Lview_find_none
    mov rsi, [rbx + 40]
    test rsi, rsi
    jz .Lview_find_none
    xor r12d, r12d
.Lview_find_length:
    cmp word ptr [rsi + r12*2], 0
    je .Lview_find_start
    inc r12d
    cmp r12d, UI_PATH_UNITS
    jb .Lview_find_length
    jmp .Lview_find_none
.Lview_find_start:
    test r12d, r12d
    jz .Lview_find_none
    mov edi, [rbx + 24]
    test edi, edi
    jns .Lview_find_nonnegative
    xor edi, edi
.Lview_find_nonnegative:
    mov r13d, [rip + ui_count]
    test r13d, r13d
    jz .Lview_find_none
    cmp edi, r13d
    jb .Lview_find_range
    test dword ptr [rbx + 32], 0x20     # LVFI_WRAP
    jz .Lview_find_none
    xor edi, edi
.Lview_find_range:
    mov r14d, r13d
    test dword ptr [rbx + 32], 0x20
    jnz .Lview_find_next
    sub r14d, edi
.Lview_find_next:
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rdi*8]
    call ui_basename
    mov rcx, rax
    # Do not read a short filename past its terminating zero.
    xor edx, edx
.Lview_find_prefix_length:
    cmp edx, r12d
    jae .Lview_find_compare
    cmp word ptr [rcx + rdx*2], 0
    je .Lview_find_miss
    inc edx
    jmp .Lview_find_prefix_length
.Lview_find_compare:
    test dword ptr [rbx + 32], 8        # LVFI_PARTIAL
    jnz .Lview_find_fold
    cmp word ptr [rcx + r12*2], 0
    jne .Lview_find_miss
.Lview_find_fold:
    mov edx, r12d
    mov r8, rsi
    mov r9d, r12d
    mov qword ptr [rsp + 32], 1
    call CompareStringOrdinal
    cmp eax, 2
    je .Lview_find_found
.Lview_find_miss:
    inc edi
    cmp edi, r13d
    jb .Lview_find_count
    xor edi, edi
.Lview_find_count:
    dec r14d
    jnz .Lview_find_next
.Lview_find_none:
    mov eax, -1
    jmp .Lview_find_return
.Lview_find_found:
    mov eax, edi
.Lview_find_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_view_find

# ECX=row, RDX=generation captured with it. Keep pause and track choices.
LOCALFN ui_view_choose
    cmp rdx, [rip + ui_list_generation]
    jne .Lview_choose_return
    cmp ecx, [rip + ui_count]
    jae .Lview_choose_return
    cmp dword ptr [rip + ui_list_new], 0
    jne .Lview_choose_return
    cmp dword ptr [rip + ui_closing], 0
    jne .Lview_choose_return
    xor eax, eax
    jmp ui_seek
.Lview_choose_return:
    ret
ENDFN ui_view_choose

LOCALFN ui_view_activate
    sub rsp, 40
    mov rax, [rip + ui_view_generation]
    mov [rsp + 32], rax
    mov rcx, [rip + ui_view_list]
    mov edx, 0x100c                    # LVM_GETNEXTITEM, LVNI_SELECTED
    mov r8, -1
    mov r9d, 2
    call SendMessageW
    mov ecx, eax
    mov rdx, [rsp + 32]
    call ui_view_choose
    add rsp, 40
    ret
ENDFN ui_view_activate

# Forget native selections before playlist_expand frees/replaces its storage.
LOCALFN ui_view_clear
    sub rsp, 40
    mov qword ptr [rip + ui_view_generation], -1
    mov dword ptr [rip + ui_view_index], -1
    mov dword ptr [rip + ui_view_state], -1
    mov rcx, [rip + ui_view_list]
    test rcx, rcx
    jz .Lview_clear_return
    mov edx, 0x102f                    # LVM_SETITEMCOUNT
    xor r8d, r8d
    xor r9d, r9d
    call SendMessageW
.Lview_clear_return:
    add rsp, 40
    ret
ENDFN ui_view_clear

# ECX=initial selection: heard entry on open, requested start on replacement.
LOCALFN ui_view_reload
    sub rsp, 88
    mov [rsp + 72], ecx
    mov rcx, [rip + ui_view_list]
    test rcx, rcx
    jz .Lview_reload_return
    mov rax, [rip + ui_list_generation]
    mov [rip + ui_view_generation], rax
    mov edx, 0x102f
    mov r8d, [rip + ui_count]
    xor r9d, r9d
    call SendMessageW
    cmp dword ptr [rip + ui_count], 0
    je .Lview_reload_return
    mov eax, [rsp + 72]
    cmp eax, [rip + ui_count]
    jb .Lview_reload_selected
    xor eax, eax
.Lview_reload_selected:
    mov [rsp + 72], eax
    # LVITEM state/stateMask at 12/16; other fields unused for SETITEMSTATE.
    mov dword ptr [rsp + 44], 3
    mov dword ptr [rsp + 48], 3
    mov rcx, [rip + ui_view_list]
    mov edx, 0x102b
    mov r8d, eax
    lea r9, [rsp + 32]
    call SendMessageW
    mov rcx, [rip + ui_view_list]
    mov edx, 0x1013                    # LVM_ENSUREVISIBLE
    mov r8d, [rsp + 72]
    xor r9d, r9d
    call SendMessageW
.Lview_reload_return:
    add rsp, 88
    ret
ENDFN ui_view_reload

# Called after the player's heard snapshot update. No extra playback timer;
# repaint the view only when the heard index or playback state changes.
LOCALFN ui_view_sync
    push rbx
    push rsi
    sub rsp, 40
    cmp qword ptr [rip + ui_view_list], 0
    je .Lview_sync_return
    mov ebx, [rip + ui_shown_index]
    xor esi, esi                      # loading
    cmp dword ptr [rip + ui_state], 3
    je .Lview_sync_error
    cmp qword ptr [rip + ui_thread], 0
    je .Lview_sync_finished
    cmp dword ptr [rip + engine_ready], 0
    je .Lview_sync_changed
    mov esi, 1
    cmp dword ptr [rip + pause_requested], 0
    je .Lview_sync_changed
    mov esi, 2
    jmp .Lview_sync_changed
.Lview_sync_error:
    mov esi, 4
    jmp .Lview_sync_changed
.Lview_sync_finished:
    mov esi, 3
.Lview_sync_changed:
    cmp ebx, [rip + ui_view_index]
    jne .Lview_sync_invalidate
    cmp esi, [rip + ui_view_state]
    je .Lview_sync_return
.Lview_sync_invalidate:
    mov [rip + ui_view_index], ebx
    mov [rip + ui_view_state], esi
    mov rcx, [rip + ui_view_list]
    xor edx, edx
    xor r8d, r8d
    call InvalidateRect
.Lview_sync_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN ui_view_sync

# Scale this window independently of the player's monitor.
LOCALFN ui_view_px
    mov eax, ecx
    imul eax, [rip + ui_view_dpi]
    add eax, 48
    xor edx, edx
    mov ecx, 96
    div ecx
    ret
ENDFN ui_view_px

LOCALFN ui_view_layout
    sub rsp, 72
    mov rcx, [rip + ui_view_hwnd]
    lea rdx, [rsp + 56]
    call GetClientRect
    mov rcx, [rip + ui_view_list]
    test rcx, rcx
    jz .Lview_layout_return
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, [rsp + 64]
    mov [rsp + 32], rax
    mov eax, [rsp + 68]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x14      # NOZORDER | NOACTIVATE
    call SetWindowPos
.Lview_layout_return:
    add rsp, 72
    ret
ENDFN ui_view_layout

# Recreate only the queue font; the main window can be on another monitor.
LOCALFN ui_view_scale
    push rbx
    sub rsp, 112
    mov ecx, 16
    call ui_view_px
    neg eax
    mov ecx, eax
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 400
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    mov qword ptr [rsp + 64], 1
    mov qword ptr [rsp + 72], 0
    mov qword ptr [rsp + 80], 0
    mov qword ptr [rsp + 88], 5
    mov qword ptr [rsp + 96], 0
    lea rax, [rip + ui_view_font_name]
    mov [rsp + 104], rax
    call CreateFontW
    test rax, rax
    jz .Lview_scale_columns
    xchg rax, [rip + ui_view_font]
    mov rbx, rax
    mov rcx, [rip + ui_view_list]
    mov edx, 0x30                      # WM_SETFONT
    mov r8, [rip + ui_view_font]
    mov r9d, 1
    call SendMessageW
    mov rcx, rbx
    call DeleteObject
.Lview_scale_columns:
    xor ebx, ebx
.Lview_scale_column:
    lea rax, [rip + ui_view_widths]
    mov ecx, [rax + rbx*4]
    call ui_view_px
    mov r9d, eax
    mov rcx, [rip + ui_view_list]
    mov edx, 0x101e                    # LVM_SETCOLUMNWIDTH
    mov r8d, ebx
    call SendMessageW
    inc ebx
    cmp ebx, 4
    jb .Lview_scale_column
    call ui_view_layout
    add rsp, 112
    pop rbx
    ret
ENDFN ui_view_scale

LOCALFN ui_view_toggle
    push rbx
    sub rsp, 160
    mov rcx, [rip + ui_view_hwnd]
    test rcx, rcx
    jz .Lview_create
    call DestroyWindow
    jmp .Lview_toggle_return
.Lview_create:
    cmp dword ptr [rip + ui_view_registered], 0
    jne .Lview_registered
    mov dword ptr [rip + ui_view_wc], 80
    lea rax, [rip + ui_view_proc]
    mov [rip + ui_view_wc + 8], rax
    mov rax, [rip + ui_instance]
    mov [rip + ui_view_wc + 24], rax
    lea rax, [rip + ui_view_class]
    mov [rip + ui_view_wc + 64], rax
    xor ecx, ecx
    mov edx, 32512
    call LoadCursorW
    mov [rip + ui_view_wc + 40], rax
    lea rcx, [rip + ui_view_wc]
    call RegisterClassExW
    test eax, eax
    jz .Lview_toggle_return
    mov dword ptr [rip + ui_view_registered], 1
.Lview_registered:
    lea rcx, [rip + ui_view_init]
    call InitCommonControlsEx
    xor ecx, ecx
    lea rdx, [rip + ui_view_class]
    lea r8, [rip + ui_view_title]
    mov r9d, 0x02cf0000                # OVERLAPPEDWINDOW | CLIPCHILDREN
    mov qword ptr [rsp + 32], -0x80000000
    mov qword ptr [rsp + 40], -0x80000000
    mov qword ptr [rsp + 48], 740
    mov qword ptr [rsp + 56], 430
    mov rax, [rip + ui_hwnd]
    mov [rsp + 64], rax                # owned window, closes with the player
    mov qword ptr [rsp + 72], 0
    mov rax, [rip + ui_instance]
    mov [rsp + 80], rax
    mov qword ptr [rsp + 88], 0
    call CreateWindowExW
    test rax, rax
    jz .Lview_toggle_return
    mov [rip + ui_view_hwnd], rax
    mov rcx, rax
    call GetDpiForWindow
    test eax, eax
    jnz .Lview_create_dpi
    mov eax, 96
.Lview_create_dpi:
    mov [rip + ui_view_dpi], eax
    mov ecx, 0x200                     # WS_EX_CLIENTEDGE
    lea rdx, [rip + ui_view_list_class]
    lea r8, [rip + ui_view_name]
    mov r9d, 0x5001100d                # CHILD/VISIBLE/TABSTOP, REPORT/SINGLESEL/SHOWSELALWAYS/OWNERDATA
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 1
    mov qword ptr [rsp + 56], 1
    mov rax, [rip + ui_view_hwnd]
    mov [rsp + 64], rax
    mov qword ptr [rsp + 72], ID_QUEUE_LIST
    mov rax, [rip + ui_instance]
    mov [rsp + 80], rax
    mov qword ptr [rsp + 88], 0
    call CreateWindowExW
    test rax, rax
    jz .Lview_create_fail
    mov [rip + ui_view_list], rax
    mov rcx, rax
    mov edx, 0x2005                    # CCM_SETUNICODEFORMAT
    mov r8d, 1
    xor r9d, r9d
    call SendMessageW
    mov rcx, [rip + ui_view_list]
    mov edx, 0x1036                    # LVM_SETEXTENDEDLISTVIEWSTYLE
    mov r8d, 0x4020                    # DOUBLEBUFFER | FULLROWSELECT
    mov r9d, r8d
    call SendMessageW
    # LVCOLUMNW, valid fields: mask, pszText, iSubItem. Widths set below.
    mov dword ptr [rsp + 104], 0x0c
    xor ebx, ebx
.Lview_create_column:
    lea rax, [rip + ui_view_labels]
    mov rax, [rax + rbx*8]
    mov [rsp + 120], rax
    mov [rsp + 132], ebx
    mov rcx, [rip + ui_view_list]
    mov edx, 0x1061                    # LVM_INSERTCOLUMNW
    mov r8d, ebx
    lea r9, [rsp + 104]
    call SendMessageW
    inc ebx
    cmp ebx, 4
    jb .Lview_create_column
    call ui_view_scale
    mov ecx, 740
    call ui_view_px
    mov [rsp + 32], rax
    mov ecx, 430
    call ui_view_px
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x16
    mov rcx, [rip + ui_view_hwnd]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call SetWindowPos
    call ui_heard_position
    mov ecx, eax
    call ui_view_reload
    call ui_view_sync
    mov rcx, [rip + ui_view_hwnd]
    mov edx, 5
    call ShowWindow
    mov rcx, [rip + ui_view_list]
    call SetFocus
    jmp .Lview_toggle_return
.Lview_create_fail:
    mov rcx, [rip + ui_view_hwnd]
    call DestroyWindow
.Lview_toggle_return:
    add rsp, 160
    pop rbx
    ret
ENDFN ui_view_toggle

# Called before the main player's Tab/shortcut handler. Native arrows,
# Home/End/Page keys and Unicode type-ahead stay with the list view.
LOCALFN ui_view_key
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov rax, [rip + ui_view_list]
    test rax, rax
    jz .Lview_key_native
    cmp [rbx], rax
    je .Lview_key_window
    mov rax, [rip + ui_view_hwnd]
    cmp [rbx], rax
    jne .Lview_key_native
.Lview_key_window:
    cmp dword ptr [rbx + 8], 0x100
    jne .Lview_key_native
    mov eax, [rbx + 16]
    cmp eax, 0x1b
    je .Lview_key_close
    cmp eax, 0x0d
    je .Lview_key_activate
    cmp eax, 0x20
    je .Lview_key_pause
    cmp eax, 9
    je .Lview_key_focus
    jmp .Lview_key_native
.Lview_key_close:
    mov rcx, [rip + ui_view_hwnd]
    call DestroyWindow
    jmp .Lview_key_consumed
.Lview_key_activate:
    call ui_view_activate
    jmp .Lview_key_consumed
.Lview_key_pause:
    call ui_toggle
    jmp .Lview_key_consumed
.Lview_key_focus:
    mov rcx, [rip + ui_view_list]
    call SetFocus
.Lview_key_consumed:
    mov eax, 1
    jmp .Lview_key_return
.Lview_key_native:
    xor eax, eax
.Lview_key_return:
    add rsp, 32
    pop rbx
    ret
ENDFN ui_view_key

LOCALFN ui_view_proc
    push rbx
    push rsi
    sub rsp, 72
    mov rbx, rcx
    mov rsi, r9
    cmp edx, 0x4e                     # WM_NOTIFY
    je .Lview_notify
    cmp edx, 5                        # WM_SIZE
    je .Lview_size
    cmp edx, 7                        # WM_SETFOCUS
    je .Lview_focus
    cmp edx, 0x2e0                    # WM_DPICHANGED
    je .Lview_dpi
    cmp edx, 0x24                     # WM_GETMINMAXINFO
    je .Lview_minmax
    cmp edx, 2                        # WM_DESTROY
    je .Lview_destroy
    call DefWindowProcW
    jmp .Lview_proc_return
.Lview_notify:
    mov rax, [rip + ui_view_list]
    cmp [rsi], rax
    jne .Lview_proc_zero
    mov eax, [rsi + 16]
    cmp eax, -177                     # LVN_GETDISPINFOW
    je .Lview_dispinfo
    cmp eax, -179                     # LVN_ODFINDITEMW
    je .Lview_find
    cmp eax, -114                     # LVN_ITEMACTIVATE (double click)
    je .Lview_activate
    jmp .Lview_proc_zero
.Lview_dispinfo:
    lea rcx, [rsi + 24]
    call ui_view_text
    jmp .Lview_proc_zero
.Lview_find:
    mov rcx, rsi
    call ui_view_find
    jmp .Lview_proc_return
.Lview_activate:
    call ui_view_activate
    jmp .Lview_proc_zero
.Lview_size:
    call ui_view_layout
    jmp .Lview_proc_zero
.Lview_focus:
    mov rcx, [rip + ui_view_list]
    test rcx, rcx
    jz .Lview_proc_zero
    call SetFocus
    jmp .Lview_proc_zero
.Lview_dpi:
    movzx eax, r8w
    test eax, eax
    jz .Lview_proc_zero
    mov [rip + ui_view_dpi], eax
    call ui_view_scale
    mov rcx, rbx
    xor edx, edx
    mov r8d, [rsi]
    mov r9d, [rsi + 4]
    mov eax, [rsi + 8]
    sub eax, r8d
    mov [rsp + 32], rax
    mov eax, [rsi + 12]
    sub eax, r9d
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x14
    call SetWindowPos
    jmp .Lview_proc_zero
.Lview_minmax:
    mov ecx, 360
    call ui_view_px
    mov [rsi + 24], eax
    mov ecx, 180
    call ui_view_px
    mov [rsi + 28], eax
    jmp .Lview_proc_zero
.Lview_destroy:
    mov qword ptr [rip + ui_view_hwnd], 0
    mov qword ptr [rip + ui_view_list], 0
    mov qword ptr [rip + ui_view_generation], -1
    xor ecx, ecx
    xchg rcx, [rip + ui_view_font]
    call DeleteObject
.Lview_proc_zero:
    xor eax, eax
.Lview_proc_return:
    add rsp, 72
    pop rsi
    pop rbx
    ret
ENDFN ui_view_proc
