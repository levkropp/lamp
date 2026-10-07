# Window modes, included by ui.s. Original assembly, MIT.
# Fullscreen keeps the exact WINDOWPLACEMENT and style of its source mode.
# Compact mode has its own saved normal placement; neither stops playback.
.equ ID_FULLSCREEN, 102
.equ ID_COMPACT, 103
.data
ui_fullscreen: .long 0
ui_compact: .long 0
ui_saved_style: .quad 0
ui_menu_fullscreen: .short 'F','u','l','l','s','c','r','e','e','n',9,'F','1','1',0
ui_menu_compact: .short 'C','o','m','p','a','c','t',' ','m','o','d','e',9,'C',0
.bss
.p2align 3
ui_full_placement: .zero 44
ui_compact_placement: .zero 44
ui_monitor: .zero 40
.text
LOCALFN ui_fullscreen_toggle
    sub rsp, 72
    cmp dword ptr [rip + ui_fullscreen], 0
    jne .Lui_full_restore
    mov dword ptr [rip + ui_full_placement], 44
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_full_placement]
    call GetWindowPlacement
    test eax, eax
    jz .Lui_full_return
    mov rcx, [rip + ui_hwnd]
    mov edx, -16                         # GWL_STYLE
    call GetWindowLongPtrW
    mov [rip + ui_saved_style], rax
    mov rcx, [rip + ui_hwnd]
    mov edx, 2                           # MONITOR_DEFAULTTONEAREST
    call MonitorFromWindow
    mov rcx, rax
    mov dword ptr [rip + ui_monitor], 40
    lea rdx, [rip + ui_monitor]
    call GetMonitorInfoW
    test eax, eax
    jz .Lui_full_return
    mov dword ptr [rip + ui_fullscreen], 1
    mov rcx, [rip + ui_hwnd]
    mov edx, -16
    mov r8, [rip + ui_saved_style]
    and r8d, ~0x00cf0000                 # border, caption, sizing frame
    call SetWindowLongPtrW
    mov rcx, [rip + ui_hwnd]
    xor edx, edx                         # HWND_TOP, without topmost
    mov r8d, [rip + ui_monitor + 4]
    mov r9d, [rip + ui_monitor + 8]
    mov eax, [rip + ui_monitor + 12]
    sub eax, r8d
    mov [rsp + 32], rax
    mov eax, [rip + ui_monitor + 16]
    sub eax, r9d
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x20       # SWP_FRAMECHANGED
    call SetWindowPos
    jmp .Lui_full_repaint
.Lui_full_restore:
    mov dword ptr [rip + ui_fullscreen], 0
    mov rcx, [rip + ui_hwnd]
    mov edx, -16
    mov r8, [rip + ui_saved_style]
    call SetWindowLongPtrW
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_full_placement]
    call SetWindowPlacement
    mov rcx, [rip + ui_hwnd]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0x37       # FRAMECHANGED | NOMOVE | NOSIZE | NOZORDER | NOACTIVATE
    call SetWindowPos
.Lui_full_repaint:
    call ui_activity
    call ui_invalidate
.Lui_full_return:
    add rsp, 72
    ret
ENDFN ui_fullscreen_toggle

LOCALFN ui_compact_toggle
    sub rsp, 72
    cmp dword ptr [rip + ui_fullscreen], 0
    je .Lui_compact_windowed
    call ui_fullscreen_toggle
.Lui_compact_windowed:
    cmp dword ptr [rip + ui_compact], 0
    jne .Lui_compact_restore
    mov dword ptr [rip + ui_compact_placement], 44
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_compact_placement]
    call GetWindowPlacement
    test eax, eax
    jz .Lui_compact_return
    mov dword ptr [rip + ui_compact], 1
    call ui_mode_layout
    mov rcx, [rip + ui_hwnd]
    mov edx, 9                           # SW_RESTORE before sizing a maximized window
    call ShowWindow
    mov ecx, 640
    call ui_px
    mov [rsp + 32], rax
    mov ecx, 260
    call ui_px
    mov [rsp + 40], rax
    mov rcx, [rip + ui_hwnd]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 48], 0x16       # NOMOVE | NOZORDER | NOACTIVATE
    call SetWindowPos
    jmp .Lui_compact_repaint
.Lui_compact_restore:
    mov dword ptr [rip + ui_compact], 0
    call ui_mode_layout
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_compact_placement]
    call SetWindowPlacement
.Lui_compact_repaint:
    call ui_activity
    call ui_invalidate
.Lui_compact_return:
    add rsp, 72
    ret
ENDFN ui_compact_toggle

LOCALFN ui_mode_layout
    mov ecx, [rip + ui_dpi]
    jmp ui_layout
ENDFN ui_mode_layout
