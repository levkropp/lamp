# Checks the Windows player's list building without a window: paths named on
# the command line, a drop (an HDROP built here) or the open dialog's result
# become the pending list, printed one path per line in UTF-8.
# usage: ui-list paths PATH...           as lamp.exe's command line names them
#        ui-list drop PATH...            as dropped on the window
#        ui-list dialog FOLDER NAME...   as the dialog returns several files
#        ui-list dialog PATH             as it returns one
.include "lamp.inc"
.data
list_argc: .long 0
list_written: .long 0
list_stdout: .quad 0
list_mode_paths: .short 'p', 'a', 't', 'h', 's', 0
list_mode_drop: .short 'd', 'r', 'o', 'p', 0
list_mode_dialog: .short 'd', 'i', 'a', 'l', 'o', 'g', 0
list_newline: .byte 10
.bss
list_utf8: .zero 131072

.text
FN list_start
    sub rsp, 72
    mov ecx, -11
    call GetStdHandle
    mov [rip + list_stdout], rax
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + list_argc]
    call CommandLineToArgvW
    mov rbx, rax
    test rax, rax
    jz .Llist_bad
    cmp dword ptr [rip + list_argc], 2
    jb .Llist_bad
    mov edi, 2                            # the first path
    mov rcx, [rbx + 8]
    lea rdx, [rip + list_mode_paths]
    call list_equal
    test eax, eax
    jnz .Llist_paths
    mov rcx, [rbx + 8]
    lea rdx, [rip + list_mode_drop]
    call list_equal
    test eax, eax
    jnz .Llist_drop
    mov rcx, [rbx + 8]
    lea rdx, [rip + list_mode_dialog]
    call list_equal
    test eax, eax
    jnz .Llist_dialog
    jmp .Llist_bad
.Llist_paths:
    call ui_list_begin
    test eax, eax
    jz .Llist_bad
.Llist_path:
    cmp edi, [rip + list_argc]
    jae .Llist_paths_done
    mov rcx, [rbx + rdi*8]
    xor edx, edx
    call ui_list_path
    inc edi
    jmp .Llist_path
.Llist_paths_done:
    call ui_list_end
    jmp .Llist_print
.Llist_drop:
    # DROPFILES (pFiles, pt, fNC, fWide), then the paths, then a NUL.
    mov esi, 20 + 2
    mov r12d, edi
.Llist_drop_size:
    cmp r12d, [rip + list_argc]
    jae .Llist_drop_sized
    mov rcx, [rbx + r12*8]
    call list_length
    lea esi, [rsi + rax*2 + 2]
    inc r12d
    jmp .Llist_drop_size
.Llist_drop_sized:
    xor ecx, ecx                          # GMEM_FIXED
    mov edx, esi
    call GlobalAlloc
    test rax, rax
    jz .Llist_bad
    mov r13, rax
    mov dword ptr [r13], 20
    mov qword ptr [r13 + 4], 0
    mov dword ptr [r13 + 12], 0
    mov dword ptr [r13 + 16], 1           # wide
    lea r8, [r13 + 20]
.Llist_drop_path:
    cmp edi, [rip + list_argc]
    jae .Llist_drop_end
    mov rcx, [rbx + rdi*8]
.Llist_drop_char:
    movzx eax, word ptr [rcx]
    mov [r8], ax
    add rcx, 2
    add r8, 2
    test eax, eax
    jnz .Llist_drop_char
    inc edi
    jmp .Llist_drop_path
.Llist_drop_end:
    mov word ptr [r8], 0
    mov rcx, r13
    call ui_list_drop                     # frees it with DragFinish
    jmp .Llist_print
.Llist_dialog:
    lea r8, [rip + ui_dialog_text]
.Llist_dialog_path:
    cmp edi, [rip + list_argc]
    jae .Llist_dialog_end
    mov rcx, [rbx + rdi*8]
.Llist_dialog_char:
    movzx eax, word ptr [rcx]
    mov [r8], ax
    add rcx, 2
    add r8, 2
    test eax, eax
    jnz .Llist_dialog_char
    inc edi
    jmp .Llist_dialog_path
.Llist_dialog_end:
    mov word ptr [r8], 0
    call ui_list_dialog
.Llist_print:
    mov rax, [rip + ui_list_pending]
    mov r12, [rax]                        # its paths
    mov r13d, [rax + 16]                  # and count
    xor esi, esi
.Llist_print_path:
    cmp esi, r13d
    jae .Llist_done
    mov ecx, 65001                        # UTF-8
    xor edx, edx
    mov r8, [r12 + rsi*8]
    mov r9d, -1
    lea rax, [rip + list_utf8]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 131072
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jz .Llist_bad
    lea r8d, [rax - 1]
    mov rcx, [rip + list_stdout]
    lea rdx, [rip + list_utf8]
    lea r9, [rip + list_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov rcx, [rip + list_stdout]
    lea rdx, [rip + list_newline]
    mov r8d, 1
    lea r9, [rip + list_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    inc esi
    jmp .Llist_print_path
.Llist_done:
    xor ecx, ecx
    call ExitProcess
.Llist_bad:
    mov ecx, 1
    call ExitProcess
ENDFN list_start

# RCX, RDX=wide strings -> EAX=1 when equal.
LOCALFN list_equal
.Llist_equal_char:
    movzx eax, word ptr [rcx]
    cmp ax, [rdx]
    jne .Llist_equal_no
    add rcx, 2
    add rdx, 2
    test eax, eax
    jnz .Llist_equal_char
    mov eax, 1
    ret
.Llist_equal_no:
    xor eax, eax
    ret
ENDFN list_equal

# RCX=wide string -> RAX=its characters.
LOCALFN list_length
    xor eax, eax
.Llist_length_char:
    cmp word ptr [rcx + rax*2], 0
    je .Llist_length_done
    inc rax
    jmp .Llist_length_char
.Llist_length_done:
    ret
ENDFN list_length
