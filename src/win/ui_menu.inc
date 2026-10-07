# The Windows player's context menu, included by src/win/ui.s. MIT, see
# LICENSE. A right click, Shift+F10 or the menu key opens it: Open files,
# Repeat, chapters, window modes, and Output with each active render
# endpoint (audio_devices). Choosing an output plays on it from the file
# heard at the heard position; the choice applies at the next launch of the
# playback thread, which no other thread then reads.
.equ ID_OPEN, 100
.equ ID_REPEAT, 101
.equ ID_PREVIOUS_CHAPTER, 104
.equ ID_NEXT_CHAPTER, 105
.equ ID_DEFAULT_OUTPUT, 200
.equ ID_OUTPUT, 201                 # and on: the endpoints in the enumerator's order
.equ UI_DEVICES_MAX, 64
.equ UI_DEVICE_UNITS, 512           # an endpoint ID, as device_id holds it

.data
.p2align 3
ui_menu_outputs: .quad 0            # the Output submenu being filled
ui_device_count: .long 0
ui_device_pending: .long 0          # 1: ui_device_choice applies at the next launch
ui_menu_open: .short 'O', 'p', 'e', 'n', ' ', 'f', 'i', 'l', 'e', 's', '.', '.', '.', 9, 'O', 0
ui_menu_repeat: .short 'R', 'e', 'p', 'e', 'a', 't', 9, 'R', 0
ui_menu_previous_chapter: .short 'P','r','e','v','i','o','u','s',' ','c','h','a','p','t','e','r',9,'[',0
ui_menu_next_chapter: .short 'N','e','x','t',' ','c','h','a','p','t','e','r',9,']',0
ui_menu_output: .short 'O', 'u', 't', 'p', 'u', 't', 0
ui_menu_default: .short 'D', 'e', 'f', 'a', 'u', 'l', 't', ' ', 'o', 'u', 't', 'p', 'u', 't', 0
.bss
.p2align 3
ui_menu_point: .zero 8
ui_device_ids: .zero UI_DEVICES_MAX*UI_DEVICE_UNITS*2
ui_device_choice: .zero UI_DEVICE_UNITS*2   # the endpoint chosen, empty for the default

.text
# RCX=lParam of WM_CONTEXTMENU: the menu at that screen point, or at the
# window's centre when it came from the keyboard (-1).
LOCALFN ui_menu
    push rbx
    push rsi
    sub rsp, 72
    mov [rsp + 56], rcx
    call CreatePopupMenu
    test rax, rax
    jz .Lui_menu_return
    mov rbx, rax
    mov rcx, rbx
    xor edx, edx
    mov r8d, ID_OPEN
    lea r9, [rip + ui_menu_open]
    call AppendMenuW
    xor edx, edx
    cmp dword ptr [rip + ui_fullscreen], 0
    je .Lui_menu_fullscreen
    mov edx, 8
.Lui_menu_fullscreen:
    mov rcx, rbx
    mov r8d, ID_FULLSCREEN
    lea r9, [rip + ui_menu_fullscreen]
    call AppendMenuW
    xor edx, edx
    cmp dword ptr [rip + ui_compact], 0
    je .Lui_menu_compact
    mov edx, 8
.Lui_menu_compact:
    mov rcx, rbx
    mov r8d, ID_COMPACT
    lea r9, [rip + ui_menu_compact]
    call AppendMenuW
    xor edx, edx
    cmp dword ptr [rip + queue_repeat], 0
    je .Lui_menu_repeat
    mov edx, 8                            # MF_CHECKED
.Lui_menu_repeat:
    mov rcx, rbx
    mov r8d, ID_REPEAT
    lea r9, [rip + ui_menu_repeat]
    call AppendMenuW
    call ui_heard
    mov edx, 1                          # MF_GRAYED when no heard chapters
    test rax, rax
    jnz .Lui_menu_snapshot
    cmp qword ptr [rip + ui_heard_count], 0
    je .Lui_menu_chapters
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_menu_chapters
    call ui_heard_position
    mov edx, 1
    test eax, eax
    js .Lui_menu_chapters
    xor edx, edx                       # worker can reopen the heard file's metadata
    jmp .Lui_menu_chapters
.Lui_menu_snapshot:
    cmp dword ptr [rax + UE_CHAPTER_COUNT], 0
    je .Lui_menu_chapters
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_menu_chapters
    xor edx, edx
.Lui_menu_chapters:
    mov [rsp + 64], edx
    mov rcx, rbx
    mov r8d, ID_PREVIOUS_CHAPTER
    lea r9, [rip + ui_menu_previous_chapter]
    call AppendMenuW
    mov edx, [rsp + 64]
    mov rcx, rbx
    mov r8d, ID_NEXT_CHAPTER
    lea r9, [rip + ui_menu_next_chapter]
    call AppendMenuW
    call CreatePopupMenu
    test rax, rax
    jz .Lui_menu_place
    mov rsi, rax
    xor edx, edx
    cmp qword ptr [rip + device_chosen], 0
    jne .Lui_menu_default
    mov edx, 8
.Lui_menu_default:
    mov rcx, rsi
    mov r8d, ID_DEFAULT_OUTPUT
    lea r9, [rip + ui_menu_default]
    call AppendMenuW
    mov rcx, rsi
    mov edx, 0x800                        # MF_SEPARATOR
    xor r8d, r8d
    xor r9d, r9d
    call AppendMenuW
    mov rcx, rsi
    call ui_devices
    mov rcx, rbx
    mov edx, 0x10                         # MF_POPUP
    mov r8, rsi
    lea r9, [rip + ui_menu_output]
    call AppendMenuW
.Lui_menu_place:
    mov rax, [rsp + 56]
    cmp eax, -1
    jne .Lui_menu_at
    mov eax, [rip + ui_width]             # from the keyboard: the centre
    shr eax, 1
    mov [rip + ui_menu_point], eax
    mov eax, [rip + ui_height]
    shr eax, 1
    mov [rip + ui_menu_point + 4], eax
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_menu_point]
    call ClientToScreen
    mov r8d, [rip + ui_menu_point]
    mov r9d, [rip + ui_menu_point + 4]
    jmp .Lui_menu_show
.Lui_menu_at:
    movsx r8d, ax
    shr eax, 16
    movsx r9d, ax
.Lui_menu_show:
    mov rcx, rbx
    mov edx, 2                            # TPM_RIGHTBUTTON; the choice comes as WM_COMMAND
    mov qword ptr [rsp + 32], 0
    mov rax, [rip + ui_hwnd]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    call TrackPopupMenu
    mov rcx, rbx
    call DestroyMenu                      # and its submenu
.Lui_menu_return:
    add rsp, 72
    pop rsi
    pop rbx
    ret
ENDFN ui_menu

# RCX=Output submenu to fill, or 0: lists the active endpoints in
# ui_device_ids (and the submenu, the one playing checked).
LOCALFN ui_devices
    sub rsp, 40
    mov [rip + ui_menu_outputs], rcx
    mov dword ptr [rip + ui_device_count], 0
    lea rax, [rip + ui_device_found]
    mov [rip + devices_callback], rax
    mov ecx, 2
    call audio_devices
    add rsp, 40
    ret
ENDFN ui_devices

# audio_devices callback: ECX=number, RDX=endpoint ID, R8=friendly name or 0.
LOCALFN ui_device_found
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, r8
    mov rsi, rdx
    mov eax, [rip + ui_device_count]
    cmp eax, UI_DEVICES_MAX
    jae .Lui_found_return
    imul eax, eax, UI_DEVICE_UNITS*2
    lea rdi, [rip + ui_device_ids]
    add rdi, rax
    xor ecx, ecx
.Lui_found_copy:
    movzx eax, word ptr [rsi + rcx*2]
    mov [rdi + rcx*2], ax
    test eax, eax
    jz .Lui_found_copied
    inc ecx
    cmp ecx, UI_DEVICE_UNITS - 1
    jb .Lui_found_copy
    jmp .Lui_found_return                 # too long to choose
.Lui_found_copied:
    mov eax, [rip + ui_device_count]
    inc dword ptr [rip + ui_device_count]
    mov rcx, [rip + ui_menu_outputs]
    test rcx, rcx
    jz .Lui_found_return
    lea r8d, [rax + ID_OUTPUT]
    xor edx, edx
    cmp qword ptr [rip + device_chosen], 0
    je .Lui_found_item
    lea r9, [rip + device_id]             # the endpoint playing: checked
    xor eax, eax
.Lui_found_compare:
    movzx r10d, word ptr [rdi + rax*2]
    cmp r10w, [r9 + rax*2]
    jne .Lui_found_item
    inc eax
    test r10d, r10d
    jnz .Lui_found_compare
    mov edx, 8                            # MF_CHECKED
.Lui_found_item:
    mov r9, rbx                           # its friendly name, else its ID
    test r9, r9
    jnz .Lui_found_append
    mov r9, rdi
.Lui_found_append:
    call AppendMenuW
.Lui_found_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_device_found

# ECX=menu command (WM_COMMAND's identifier).
LOCALFN ui_menu_command
    sub rsp, 40
    cmp ecx, 110
    jne .Lui_command_play
    call ui_previous
    jmp .Lui_menu_command_return
.Lui_command_play:
    cmp ecx, 111
    jne .Lui_command_next_button
    call ui_toggle
    jmp .Lui_menu_command_return
.Lui_command_next_button:
    cmp ecx, 112
    jne .Lui_command_mode
    call ui_next
    jmp .Lui_menu_command_return
.Lui_command_mode:
    cmp ecx, ID_FULLSCREEN
    jne .Lui_command_compact
    call ui_fullscreen_toggle
    jmp .Lui_menu_command_return
.Lui_command_compact:
    cmp ecx, ID_COMPACT
    jne .Lui_command_open
    call ui_compact_toggle
    jmp .Lui_menu_command_return
.Lui_command_open:
    cmp ecx, ID_OPEN
    jne .Lui_command_repeat
    call ui_open_dialog
    jmp .Lui_menu_command_return
.Lui_command_repeat:
    cmp ecx, ID_REPEAT
    jne .Lui_command_previous_chapter
    xor dword ptr [rip + queue_repeat], 1
    call ui_invalidate
    jmp .Lui_menu_command_return
.Lui_command_previous_chapter:
    cmp ecx, ID_PREVIOUS_CHAPTER
    jne .Lui_command_next_chapter
    mov ecx, 7
    call ui_chapter
    jmp .Lui_menu_command_return
.Lui_command_next_chapter:
    cmp ecx, ID_NEXT_CHAPTER
    jne .Lui_command_default
    mov ecx, 6
    call ui_chapter
    jmp .Lui_menu_command_return
.Lui_command_default:
    cmp ecx, ID_DEFAULT_OUTPUT
    jne .Lui_command_output
    mov word ptr [rip + ui_device_choice], 0
    call ui_output
    jmp .Lui_menu_command_return
.Lui_command_output:
    sub ecx, ID_OUTPUT
    cmp ecx, UI_DEVICES_MAX
    jae .Lui_menu_command_return
    mov [rsp + 32], ecx
    cmp ecx, [rip + ui_device_count]
    jb .Lui_command_listed
    xor ecx, ecx                          # not listed by a menu: list them now
    call ui_devices
    mov ecx, [rsp + 32]
    cmp ecx, [rip + ui_device_count]
    jae .Lui_menu_command_return
.Lui_command_listed:
    imul ecx, ecx, UI_DEVICE_UNITS*2
    lea rdx, [rip + ui_device_ids]
    add rdx, rcx
    lea r8, [rip + ui_device_choice]
.Lui_command_copy:
    movzx eax, word ptr [rdx]
    mov [r8], ax
    add rdx, 2
    add r8, 2
    test eax, eax
    jnz .Lui_command_copy
    call ui_output
.Lui_menu_command_return:
    add rsp, 40
    ret
ENDFN ui_menu_command

# The output chosen: playing, playback continues on it from the file heard
# at the heard position; otherwise the next launch uses it.
LOCALFN ui_output
    sub rsp, 40
    mov dword ptr [rip + ui_device_pending], 1
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_output_return
    call ui_heard_position
    mov ecx, eax
    call ui_play_at
.Lui_output_return:
    add rsp, 40
    ret
ENDFN ui_output

# At a launch, with no playback thread: a chosen output becomes the one the
# engine opens (device_chosen; the default when it is empty).
LOCALFN ui_device_apply
    cmp dword ptr [rip + ui_device_pending], 0
    je .Lui_apply_return
    mov dword ptr [rip + ui_device_pending], 0
    mov qword ptr [rip + device_chosen], 0
    cmp word ptr [rip + ui_device_choice], 0
    je .Lui_apply_return
    lea rcx, [rip + ui_device_choice]
    lea rdx, [rip + device_id]
.Lui_apply_copy:
    movzx eax, word ptr [rcx]
    mov [rdx], ax
    add rcx, 2
    add rdx, 2
    test eax, eax
    jnz .Lui_apply_copy
    lea rax, [rip + device_id]
    mov [rip + device_chosen], rax
.Lui_apply_return:
    ret
ENDFN ui_device_apply
