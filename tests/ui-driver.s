# Drives a running lamp.exe for tests, as a user would, through window
# messages. Each argument is a command:
#   w        wait for the player's window (up to 60 s)
#   kXX      press the key with virtual-key code XX (hexadecimal)
#   aN       send WM_APPCOMMAND N (11 next, 12 previous, 14 play/pause)
#   oN       send WM_COMMAND N, as the context menu's item N does
#   r        open the context menu as the keyboard does
#   eXX      inject native key XX through SendInput (including an active menu)
#   z        print the client area's width and height
#   mX,Y     click the client area at X, Y pixels above its bottom
#   sN       sleep N milliseconds
#   t        print the window's title
#   pN       print the title whenever it changes, for N milliseconds
#   c        close the window and wait until it is gone (up to 20 s)
#   f        print the focused child control's name
#   vXX      press key XX on the focused child control
#   nN       print child N's screen-reader name, role (MSAA), and native class
#   g        print the window's placement (show state and normal rectangle)
#   b        press Shift+Tab through the input queue
#   hN       print trackbar N's current position
#   uN       move the pointer over child N (through its native procedure)
# Titles print in UTF-8, one per line. Exit code 1 when the window is missing.
.include "lamp.inc"
.data
driver_argc: .long 0
driver_written: .long 0
driver_stdout: .quad 0
driver_hwnd: .quad 0
driver_class: .short 'L', 'a', 'm', 'p', 'W', 'i', 'n', 'd', 'o', 'w', 0
driver_newline: .byte 10
driver_iaccessible: .long 0x618736e0
    .short 0x3c3d,0x11cf
    .byte 0x81,0x0c,0x00,0xaa,0x00,0x38,0x9b,0x71
.p2align 3
driver_shift_tab:
    # Four x64 INPUT structures: Shift down, Tab down/up, Shift up.
    .long 1,0
    .short 0x10,0
    .long 0,0,0
    .quad 0,0
    .long 1,0
    .short 9,0
    .long 0,0,0
    .quad 0,0
    .long 1,0
    .short 9,0
    .long 2,0,0
    .quad 0,0
    .long 1,0
    .short 0x10,0
    .long 2,0,0
    .quad 0,0
.bss
driver_rect: .zero 16
driver_title: .zero 2048*2
driver_last: .zero 2048*2
driver_utf8: .zero 8192
driver_digits: .zero 24
driver_gui: .zero 72
driver_accessible: .zero 8
driver_control: .zero 8
driver_bstr: .zero 8
driver_variant: .zero 24
driver_role: .zero 24
driver_placement: .zero 44
.p2align 3
driver_menu_input: .zero 80           # two x64 INPUT records

.text
FN driver_start
    sub rsp, 72
    mov ecx, -11
    call GetStdHandle
    mov [rip + driver_stdout], rax
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + driver_argc]
    call CommandLineToArgvW
    mov rbx, rax
    test rax, rax
    jz .Ldriver_bad
    mov edi, 1
.Ldriver_command:
    cmp edi, [rip + driver_argc]
    jae .Ldriver_done
    mov rsi, [rbx + rdi*8]
    inc edi
    movzx eax, word ptr [rsi]
    add rsi, 2
    cmp eax, 'w'
    je .Ldriver_wait
    cmp eax, 's'
    je .Ldriver_sleep
    cmp qword ptr [rip + driver_hwnd], 0
    je .Ldriver_bad                       # the rest need the window
    cmp eax, 'k'
    je .Ldriver_key
    cmp eax, 'a'
    je .Ldriver_appcommand
    cmp eax, 'o'
    je .Ldriver_menu_command
    cmp eax, 'r'
    je .Ldriver_context
    cmp eax, 'e'
    je .Ldriver_native_key
    cmp eax, 'z'
    je .Ldriver_size
    cmp eax, 'm'
    je .Ldriver_click
    cmp eax, 't'
    je .Ldriver_title
    cmp eax, 'p'
    je .Ldriver_poll
    cmp eax, 'c'
    je .Ldriver_close
    cmp eax, 'f'
    je .Ldriver_focus
    cmp eax, 'v'
    je .Ldriver_focus_key
    cmp eax, 'n'
    je .Ldriver_accessible
    cmp eax, 'g'
    je .Ldriver_placement
    cmp eax, 'b'
    je .Ldriver_shift_tab
    cmp eax, 'h'
    je .Ldriver_slider_position
    cmp eax, 'u'
    je .Ldriver_control_mouse
    jmp .Ldriver_bad
.Ldriver_wait:
    mov r12d, 1200
.Ldriver_wait_poll:
    lea rcx, [rip + driver_class]
    xor edx, edx
    call FindWindowW
    mov [rip + driver_hwnd], rax
    test rax, rax
    jnz .Ldriver_command
    mov ecx, 50
    call Sleep
    dec r12d
    jnz .Ldriver_wait_poll
    jmp .Ldriver_bad
.Ldriver_sleep:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov ecx, eax
    call Sleep
    jmp .Ldriver_command
.Ldriver_key:
    mov rcx, rsi
    mov edx, 16
    call driver_number
    mov r8d, eax
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x100                        # WM_KEYDOWN
    mov r9d, 1
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_focus:
    call driver_focus_window
    test rax, rax
    jz .Ldriver_bad
    mov rcx, rax
    lea rdx, [rip + driver_title]
    mov r8d, 2048
    call GetWindowTextW
    lea rcx, [rip + driver_title]
    call driver_print_title
    jmp .Ldriver_command
.Ldriver_shift_tab:
    mov rcx, [rip + driver_hwnd]
    call SetForegroundWindow
    mov ecx, 4
    lea rdx, [rip + driver_shift_tab]
    mov r8d, 40
    call SendInput
    cmp eax, 4
    jne .Ldriver_bad
    jmp .Ldriver_command
.Ldriver_slider_position:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov edx, eax
    mov rcx, [rip + driver_hwnd]
    call GetDlgItem
    test rax, rax
    jz .Ldriver_bad
    mov rcx, rax
    mov edx, 0x400                       # TBM_GETPOS
    xor r8d, r8d
    xor r9d, r9d
    call SendMessageW
    call driver_print_number
    jmp .Ldriver_command
.Ldriver_control_mouse:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov edx, eax
    mov rcx, [rip + driver_hwnd]
    call GetDlgItem
    test rax, rax
    jz .Ldriver_bad
    mov rcx, rax
    mov edx, 0x200                       # WM_MOUSEMOVE
    xor r8d, r8d
    xor r9d, r9d
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_placement:
    mov dword ptr [rip + driver_placement], 44
    mov rcx, [rip + driver_hwnd]
    lea rdx, [rip + driver_placement]
    call GetWindowPlacement
    test eax, eax
    jz .Ldriver_bad
    mov eax, [rip + driver_placement + 8]
    call driver_print_number
    xor r12d, r12d
.Ldriver_placement_rect:
    lea rax, [rip + driver_placement + 28]
    mov eax, [rax + r12*4]
    call driver_print_number
    inc r12d
    cmp r12d, 4
    jb .Ldriver_placement_rect
    jmp .Ldriver_command
.Ldriver_focus_key:
    mov rcx, rsi
    mov edx, 16
    call driver_number
    mov r12d, eax
    call driver_focus_window
    test rax, rax
    jz .Ldriver_bad
    mov rcx, rax
    mov edx, 0x100
    mov r8d, r12d
    mov r9d, 1
    call PostMessageW
    call driver_focus_window
    mov rcx, rax
    mov edx, 0x101                       # buttons activate on Space key-up
    mov r8d, r12d
    mov r9d, 0xc0000001
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_accessible:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov edx, eax
    mov rcx, [rip + driver_hwnd]
    call GetDlgItem
    test rax, rax
    jz .Ldriver_bad
    mov [rip + driver_control], rax
    mov rcx, rax
    mov edx, -4                         # OBJID_CLIENT
    lea r8, [rip + driver_iaccessible]
    lea r9, [rip + driver_accessible]
    call AccessibleObjectFromWindow
    test eax, eax
    js .Ldriver_bad
    mov word ptr [rip + driver_variant], 3 # VT_I4, CHILDID_SELF = 0
    mov dword ptr [rip + driver_variant + 8], 0
    mov rcx, [rip + driver_accessible]
    mov rax, [rcx]
    lea rdx, [rip + driver_variant]
    lea r8, [rip + driver_bstr]
    call qword ptr [rax + 10*8]          # get_accName
    test eax, eax
    js .Ldriver_bad
    mov rcx, [rip + driver_bstr]
    test rcx, rcx
    jz .Ldriver_bad
    xor eax, eax
    lea rdx, [rip + driver_title]
.Ldriver_accessible_name:
    movzx r8d, word ptr [rcx + rax*2]
    mov [rdx + rax*2], r8w
    test r8d, r8d
    jz .Ldriver_accessible_print
    inc eax
    cmp eax, 2047
    jb .Ldriver_accessible_name
    mov word ptr [rdx + 2047*2], 0
.Ldriver_accessible_print:
    call driver_print_title
    mov rcx, [rip + driver_bstr]
    call SysFreeString
    mov rcx, [rip + driver_accessible]
    mov rax, [rcx]
    lea rdx, [rip + driver_variant]
    lea r8, [rip + driver_role]
    call qword ptr [rax + 13*8]          # get_accRole
    test eax, eax
    js .Ldriver_bad
    cmp word ptr [rip + driver_role], 3
    jne .Ldriver_bad
    mov rcx, [rip + driver_accessible]
    mov rax, [rcx]
    call qword ptr [rax + 2*8]           # Release
    mov eax, [rip + driver_role + 8]
    call driver_print_number
    mov rcx, [rip + driver_control]
    lea rdx, [rip + driver_title]
    mov r8d, 2048
    call GetClassNameW
    test eax, eax
    jz .Ldriver_bad
    call driver_print_title
    jmp .Ldriver_command
.Ldriver_appcommand:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    shl eax, 16
    mov r9d, eax
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x319                        # WM_APPCOMMAND
    mov r8, rcx
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_menu_command:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov r8d, eax
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x111                        # WM_COMMAND
    xor r9d, r9d
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_context:
    mov rcx, [rip + driver_hwnd]
    call SetForegroundWindow
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x7b                         # WM_CONTEXTMENU, from the keyboard
    mov r8, rcx
    mov r9, -1
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_native_key:
    mov rcx, rsi
    mov edx, 16
    call driver_number
    lea rdx, [rip + driver_menu_input]
    mov dword ptr [rdx], 1
    mov word ptr [rdx + 8], ax
    mov dword ptr [rdx + 40], 1
    mov word ptr [rdx + 48], ax
    mov dword ptr [rdx + 56], 2         # KEYEVENTF_KEYUP
    mov ecx, 2
    mov r8d, 40
    call SendInput
    cmp eax, 2
    jne .Ldriver_bad
    jmp .Ldriver_command
.Ldriver_size:
    mov r13d, edi                         # the next argument's index
    mov rcx, [rip + driver_hwnd]
    lea rdx, [rip + driver_rect]
    call GetClientRect
    lea rdi, [rip + driver_utf8]
    mov eax, [rip + driver_rect + 8]
    call driver_decimal
    mov byte ptr [rdi], ' '
    inc rdi
    mov eax, [rip + driver_rect + 12]
    call driver_decimal
    mov byte ptr [rdi], 10
    inc rdi
    mov rcx, [rip + driver_stdout]
    lea rdx, [rip + driver_utf8]
    mov r8, rdi
    sub r8, rdx
    lea r9, [rip + driver_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov edi, r13d
    jmp .Ldriver_command
.Ldriver_click:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov r12d, eax                         # x
    lea rcx, [rcx + 2]                    # past the comma
    mov edx, 10
    call driver_number
    mov r13d, eax
    mov rcx, [rip + driver_hwnd]
    lea rdx, [rip + driver_rect]
    call GetClientRect
    mov r9d, [rip + driver_rect + 12]
    sub r9d, r13d                         # y
    shl r9d, 16
    or r9d, r12d
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x201                        # WM_LBUTTONDOWN
    mov r8d, 1
    call PostMessageW
    jmp .Ldriver_command
.Ldriver_title:
    call driver_read_title
    call driver_print_title
    jmp .Ldriver_command
.Ldriver_poll:
    mov rcx, rsi
    mov edx, 10
    call driver_number
    mov r12d, eax
    call GetTickCount64
    add r12, rax                          # the end
    mov word ptr [rip + driver_last], 0
.Ldriver_poll_title:
    call driver_read_title
    lea rcx, [rip + driver_title]
    lea rdx, [rip + driver_last]
.Ldriver_poll_compare:
    movzx eax, word ptr [rcx]
    cmp ax, [rdx]
    jne .Ldriver_poll_changed
    add rcx, 2
    add rdx, 2
    test eax, eax
    jnz .Ldriver_poll_compare
    jmp .Ldriver_poll_wait
.Ldriver_poll_changed:
    call driver_print_title
    lea rcx, [rip + driver_title]
    lea rdx, [rip + driver_last]
.Ldriver_poll_copy:
    movzx eax, word ptr [rcx]
    mov [rdx], ax
    add rcx, 2
    add rdx, 2
    test eax, eax
    jnz .Ldriver_poll_copy
.Ldriver_poll_wait:
    mov ecx, 50
    call Sleep
    call GetTickCount64
    cmp rax, r12
    jb .Ldriver_poll_title
    jmp .Ldriver_command
.Ldriver_close:
    mov rcx, [rip + driver_hwnd]
    mov edx, 0x10                         # WM_CLOSE
    xor r8d, r8d
    xor r9d, r9d
    call PostMessageW
    mov r12d, 400
.Ldriver_close_poll:
    mov ecx, 50
    call Sleep
    lea rcx, [rip + driver_class]
    xor edx, edx
    call FindWindowW
    test rax, rax
    jz .Ldriver_command
    dec r12d
    jnz .Ldriver_close_poll
    jmp .Ldriver_bad
.Ldriver_done:
    xor ecx, ecx
    call ExitProcess
.Ldriver_bad:
    mov ecx, 1
    call ExitProcess
ENDFN driver_start

LOCALFN driver_focus_window
    sub rsp, 40
    mov dword ptr [rip + driver_gui], 72
    xor ecx, ecx
    lea rdx, [rip + driver_gui]
    call GetGUIThreadInfo
    test eax, eax
    jz .Ldriver_focus_missing
    mov rax, [rip + driver_gui + 16]
    jmp .Ldriver_focus_found
.Ldriver_focus_missing:
    xor eax, eax
.Ldriver_focus_found:
    add rsp, 40
    ret
ENDFN driver_focus_window

LOCALFN driver_print_number
    push rdi
    sub rsp, 48
    lea rdi, [rip + driver_utf8]
    call driver_decimal
    mov byte ptr [rdi], 10
    inc rdi
    mov rcx, [rip + driver_stdout]
    lea rdx, [rip + driver_utf8]
    mov r8, rdi
    sub r8, rdx
    lea r9, [rip + driver_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 48
    pop rdi
    ret
ENDFN driver_print_number

# EAX=value, RDI=destination -> its decimal digits, RDI past them.
LOCALFN driver_decimal
    lea r8, [rip + driver_digits + 24]    # digits backwards
    mov r9, r8
    mov ecx, 10
.Ldriver_decimal_digit:
    xor edx, edx
    div ecx
    add dl, '0'
    dec r8
    mov [r8], dl
    test eax, eax
    jnz .Ldriver_decimal_digit
.Ldriver_decimal_copy:
    mov al, [r8]
    mov [rdi], al
    inc rdi
    inc r8
    cmp r8, r9
    jb .Ldriver_decimal_copy
    ret
ENDFN driver_decimal

# RCX=wide digits, EDX=base -> EAX=value, RCX past the digits.
LOCALFN driver_number
    xor eax, eax
.Ldriver_digit:
    movzx r8d, word ptr [rcx]
    lea r9d, [r8 - '0']
    cmp r9d, 9
    jbe .Ldriver_digit_value
    or r8d, 0x20
    lea r9d, [r8 - 'a' + 10]
    cmp r8d, 'a'
    jb .Ldriver_number_done
    cmp r9d, edx
    jae .Ldriver_number_done
.Ldriver_digit_value:
    cmp r9d, edx
    jae .Ldriver_number_done
    imul eax, edx
    add eax, r9d
    add rcx, 2
    jmp .Ldriver_digit
.Ldriver_number_done:
    ret
ENDFN driver_number

LOCALFN driver_read_title
    sub rsp, 40
    mov rcx, [rip + driver_hwnd]
    lea rdx, [rip + driver_title]
    mov r8d, 2048
    call GetWindowTextW
    lea rcx, [rip + driver_title]
    mov word ptr [rcx + rax*2], 0
    add rsp, 40
    ret
ENDFN driver_read_title

LOCALFN driver_print_title
    sub rsp, 72
    mov ecx, 65001                        # UTF-8
    xor edx, edx
    lea r8, [rip + driver_title]
    mov r9d, -1
    lea rax, [rip + driver_utf8]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 8192
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jz .Ldriver_print_done
    lea r8d, [rax - 1]
    mov rcx, [rip + driver_stdout]
    lea rdx, [rip + driver_utf8]
    lea r9, [rip + driver_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov rcx, [rip + driver_stdout]
    lea rdx, [rip + driver_newline]
    mov r8d, 1
    lea r9, [rip + driver_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
.Ldriver_print_done:
    add rsp, 72
    ret
ENDFN driver_print_title
