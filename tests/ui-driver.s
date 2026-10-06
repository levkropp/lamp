# Drives a running lamp.exe for tests, as a user would, through window
# messages. Each argument is a command:
#   w        wait for the player's window (up to 30 s)
#   kXX      press the key with virtual-key code XX (hexadecimal)
#   aN       send WM_APPCOMMAND N (11 next, 12 previous, 14 play/pause)
#   oN       send WM_COMMAND N, as the context menu's item N does
#   r        open the context menu as the keyboard does
#   mX,Y     click the client area at X, Y pixels above its bottom
#   sN       sleep N milliseconds
#   t        print the window's title
#   pN       print the title whenever it changes, for N milliseconds
#   c        close the window and wait until it is gone (up to 20 s)
# Titles print in UTF-8, one per line. Exit code 1 when the window is missing.
.include "lamp.inc"
.data
driver_argc: .long 0
driver_written: .long 0
driver_stdout: .quad 0
driver_hwnd: .quad 0
driver_class: .short 'L', 'a', 'm', 'p', 'W', 'i', 'n', 'd', 'o', 'w', 0
driver_newline: .byte 10
.bss
driver_rect: .zero 16
driver_title: .zero 2048*2
driver_last: .zero 2048*2
driver_utf8: .zero 8192

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
    cmp eax, 'm'
    je .Ldriver_click
    cmp eax, 't'
    je .Ldriver_title
    cmp eax, 'p'
    je .Ldriver_poll
    cmp eax, 'c'
    je .Ldriver_close
    jmp .Ldriver_bad
.Ldriver_wait:
    mov r12d, 600
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
    mov edx, 0x7b                         # WM_CONTEXTMENU, from the keyboard
    mov r8, rcx
    mov r9, -1
    call PostMessageW
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
