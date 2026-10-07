# Windows resume storage, shared by the console and GUI. Original assembly, MIT.
# A 16 MiB state limit bounds scanning, allocation and DWORD writes. Oversized
# state is ignored on lookup and replaced on the next valid save.
.equ RESUME_BYTES, 16 << 20
# --resume: RCX=address of the expanded list's paths, EDX=their count ->
# EAX=1 when the list's key has a saved position in one of its files:
# ECX=that file's index, RDX=milliseconds.
FN win_resume_lookup
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov edi, edx
    test rcx, rcx
    jz .Lresume_lookup_none
    test edx, edx
    jz .Lresume_lookup_none
    call resume_state_path
    test eax, eax
    jz .Lresume_lookup_none
    mov rcx, [rsi]
    lea rdx, [rip + resume_key]
    call absolute_utf8
    test eax, eax
    jz .Lresume_lookup_none
    lea rcx, [rip + resume_state]
    call file_map
    test rax, rax
    jz .Lresume_lookup_none
    mov [rsp + 32], rax                 # view, bytes, token
    mov rbx, rdx
    mov r12, r8
    cmp rbx, RESUME_BYTES
    ja .Lresume_lookup_unmap
    mov rcx, rax
    lea rdx, [rax + rdx]
    lea r8, [rip + resume_key]
    call resume_find
    test eax, eax
    jz .Lresume_lookup_unmap
    mov [rip + resume_ms], rdx
    cmp r9d, RESUME_PATH - 1
    jae .Lresume_lookup_unmap
    lea r10, [rip + resume_found]      # the heard file, NUL-terminated
    xor ecx, ecx
.Lresume_lookup_copy:
    cmp ecx, r9d
    jae .Lresume_lookup_copied
    mov al, [r8 + rcx]
    mov [r10 + rcx], al
    inc ecx
    jmp .Lresume_lookup_copy
.Lresume_lookup_copied:
    mov byte ptr [r10 + rcx], 0
    mov rcx, [rsp + 32]
    mov rdx, rbx
    mov r8, r12
    call file_unmap
    xor ebx, ebx                        # find it in the list
.Lresume_lookup_file:
    cmp ebx, edi
    jae .Lresume_lookup_none
    mov rcx, [rsi + rbx*8]
    lea rdx, [rip + resume_heard]
    call absolute_utf8
    test eax, eax
    jz .Lresume_lookup_next
    lea rcx, [rip + resume_heard]
    lea rdx, [rip + resume_found]
.Lresume_lookup_compare:
    mov al, [rcx]
    cmp al, [rdx]
    jne .Lresume_lookup_next
    inc rcx
    inc rdx
    test al, al
    jnz .Lresume_lookup_compare
    mov ecx, ebx
    mov rdx, [rip + resume_ms]
    mov eax, 1
    jmp .Lresume_lookup_return
.Lresume_lookup_next:
    inc ebx
    jmp .Lresume_lookup_file
.Lresume_lookup_unmap:
    mov rcx, [rsp + 32]
    mov rdx, rbx
    mov r8, r12
    call file_unmap
.Lresume_lookup_none:
    xor eax, eax
.Lresume_lookup_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN win_resume_lookup

# Console compatibility: EDX=save/forget, paths in RCX.
LOCALFN resume_save
    mov r8d, -1
    test edx, edx
    jz .Lresume_console_forget
    mov r8d, [rip + engine_heard_index]
    test r8d, r8d
    js .Lresume_console_return
.Lresume_console_forget:
    mov edx, [rip + cli_count]
    mov r9, [rip + engine_heard_ms]
    jmp win_resume_save
.Lresume_console_return:
    ret
ENDFN resume_save

# RCX=wide path pointers, EDX=count, R8D=heard index (-1 to forget),
# R9=milliseconds. UI/console callers supply a paired snapshot; this function
# never samples a running engine. Calls are serialized by their owner.
# Rewrites through a temporary file; failures are silent.
FN win_resume_save
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 72
    mov rsi, rcx
    mov r13d, r8d
    mov [rsp + 56], r9
    test rcx, rcx
    jz .Lresume_save_return
    test edx, edx
    jz .Lresume_save_return
    cmp r8d, -1
    je .Lresume_save_input
    cmp r8d, edx
    jae .Lresume_save_return
.Lresume_save_input:
    call resume_state_path
    test eax, eax
    jz .Lresume_save_return
    mov rcx, [rsi]
    lea rdx, [rip + resume_key]
    call absolute_utf8
    test eax, eax
    jz .Lresume_save_return
    xor r14d, r14d                      # the heard file, or 0 to forget
    cmp r13d, -1
    je .Lresume_save_old
    mov eax, r13d
    mov rcx, [rsi + rax*8]
    lea rdx, [rip + resume_heard]
    call absolute_utf8
    test eax, eax
    jz .Lresume_save_return
    lea r14, [rip + resume_heard]
.Lresume_save_old:
    xor ebx, ebx                        # the old file (none)
    xor r12d, r12d
    mov qword ptr [rsp + 64], 0
    lea rcx, [rip + resume_state]
    call file_map
    test rax, rax
    jz .Lresume_save_buffer
    mov rbx, rax
    mov r12, rdx
    mov [rsp + 64], r8
    cmp r12, RESUME_BYTES
    jbe .Lresume_save_buffer
    mov rcx, rbx
    mov rdx, r12
    call file_unmap
    xor ebx, ebx
    xor r12d, r12d
.Lresume_save_buffer:
    lea rcx, [r12 + 2*RESUME_PATH + 64]
    call mem_alloc
    test rax, rax
    jz .Lresume_save_unmap
    mov rdi, rax
    mov rcx, rbx
    lea rdx, [rbx + r12]
    lea r8, [rip + resume_key]
    mov r9, r14
    mov rax, [rsp + 56]
    mov [rsp + 32], rax
    mov [rsp + 40], rdi
    call resume_write
    mov r13, rax                        # new bytes
    test rbx, rbx
    jz .Lresume_save_write
    mov rcx, rbx
    mov rdx, r12
    mov r8, [rsp + 64]
    call file_unmap
    xor ebx, ebx
.Lresume_save_write:
    cmp r13, RESUME_BYTES
    ja .Lresume_save_free
    lea rcx, [rip + resume_folder]
    xor edx, edx
    call CreateDirectoryW               # it may exist
    lea rcx, [rip + resume_temp]
    mov edx, 0x40000000                 # GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2         # CREATE_ALWAYS
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, -1
    je .Lresume_save_free
    mov [rsp + 64], rax
    mov rcx, rax
    mov rdx, rdi
    mov r8d, r13d
    lea r9, [rip + bytes_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov r12d, eax
    mov eax, [rip + bytes_written]
    cmp eax, r13d
    je .Lresume_save_close
    xor r12d, r12d
.Lresume_save_close:
    mov rcx, [rsp + 64]
    call CloseHandle
    test r12d, r12d
    jz .Lresume_save_free
    lea rcx, [rip + resume_temp]
    lea rdx, [rip + resume_state]
    mov r8d, 1                          # MOVEFILE_REPLACE_EXISTING
    call MoveFileExW
.Lresume_save_free:
    mov rcx, rdi
    call mem_free
.Lresume_save_unmap:
    test rbx, rbx
    jz .Lresume_save_return
    mov rcx, rbx
    mov rdx, r12
    mov r8, [rsp + 64]
    call file_unmap
.Lresume_save_return:
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN win_resume_save

# -> EAX=1 with resume_folder = %LOCALAPPDATA%\LAMP, resume_state = its
# resume.txt and resume_temp = resume.txt.tmp (wide).
LOCALFN resume_state_path
    push rsi
    push rdi
    sub rsp, 40
    lea rcx, [rip + resume_local]
    lea rdx, [rip + resume_folder]
    mov r8d, RESUME_WIDE - 64
    call GetEnvironmentVariableW
    test eax, eax
    jz .Lresume_state_none
    cmp eax, RESUME_WIDE - 64
    jae .Lresume_state_none
    lea rdi, [rip + resume_folder]
    lea rdi, [rdi + rax*2]
    lea rsi, [rip + resume_folder_tail]
    call resume_append                  # \LAMP
    lea rsi, [rip + resume_folder]      # \LAMP\resume.txt and .tmp
    lea rdi, [rip + resume_state]
    call resume_append
    lea rsi, [rip + resume_file_tail]
    call resume_append
    lea rsi, [rip + resume_state]
    lea rdi, [rip + resume_temp]
    call resume_append
    lea rsi, [rip + resume_temp_tail]
    call resume_append
    mov eax, 1
    jmp .Lresume_state_return
.Lresume_state_none:
    xor eax, eax
.Lresume_state_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN resume_state_path

# RSI=wide text, RDI=destination -> RDI at the copy's terminating zero.
LOCALFN resume_append
.Lresume_append_char:
    movzx eax, word ptr [rsi]
    mov [rdi], ax
    test eax, eax
    jz .Lresume_append_done
    add rsi, 2
    add rdi, 2
    jmp .Lresume_append_char
.Lresume_append_done:
    ret
ENDFN resume_append

# RCX=wide path, RDX=destination of RESUME_PATH bytes -> EAX=1 with its
# full path in UTF-8, 0 when it does not fit.
LOCALFN absolute_utf8
    push rbx
    sub rsp, 64
    mov rbx, rdx
    mov edx, RESUME_WIDE
    lea r8, [rip + resume_wide]
    xor r9d, r9d
    call GetFullPathNameW
    test eax, eax
    jz .Labsolute_fail
    cmp eax, RESUME_WIDE
    jae .Labsolute_fail
    mov ecx, 65001                      # CP_UTF8
    xor edx, edx
    lea r8, [rip + resume_wide]
    mov r9d, -1
    mov [rsp + 32], rbx
    mov qword ptr [rsp + 40], RESUME_PATH
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jz .Labsolute_fail
    mov eax, 1
    jmp .Labsolute_return
.Labsolute_fail:
    xor eax, eax
.Labsolute_return:
    add rsp, 64
    pop rbx
    ret
ENDFN absolute_utf8

# ECX=-1: read the GUI's opt-in preference (EAX=0 or 1). ECX=0/1: persist it
# (EAX=success). Exactly "0\n" or "1\n" is accepted; missing/corrupt data
# defaults to off. This file is separate from the shared position records.
FN win_resume_preference
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov ebx, ecx
    call resume_state_path
    test eax, eax
    jz .Lresume_pref_none
    lea rsi, [rip + resume_folder]
    lea rdi, [rip + resume_preference_path]
    call resume_append
    lea rsi, [rip + resume_preference_tail]
    call resume_append
    cmp ebx, -1
    jne .Lresume_pref_write
    lea rcx, [rip + resume_preference_path]
    call file_map
    test rax, rax
    jz .Lresume_pref_none
    mov rcx, rax
    xor ebx, ebx
    cmp rdx, 2
    jne .Lresume_pref_unmap
    cmp word ptr [rax], 0x0a31          # exact "1\n"
    sete bl
.Lresume_pref_unmap:
    call file_unmap                     # RDX=bytes, R8=token still paired
    mov eax, ebx
    jmp .Lresume_pref_return
.Lresume_pref_write:
    cmp ebx, 1
    ja .Lresume_pref_none
    add ebx, '0'
    mov byte ptr [rsp + 56], bl
    mov byte ptr [rsp + 57], 10
    lea rsi, [rip + resume_preference_path]
    lea rdi, [rip + resume_preference_temp]
    call resume_append
    lea rsi, [rip + resume_temp_tail]
    call resume_append
    lea rcx, [rip + resume_folder]
    xor edx, edx
    call CreateDirectoryW
    lea rcx, [rip + resume_preference_temp]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2         # CREATE_ALWAYS
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, -1
    je .Lresume_pref_none
    mov rsi, rax
    mov rcx, rax
    lea rdx, [rsp + 56]
    mov r8d, 2
    lea r9, [rip + bytes_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov ebx, eax
    cmp dword ptr [rip + bytes_written], 2
    je .Lresume_pref_close
    xor ebx, ebx
.Lresume_pref_close:
    mov rcx, rsi
    call CloseHandle
    test ebx, ebx
    jz .Lresume_pref_none
    lea rcx, [rip + resume_preference_temp]
    lea rdx, [rip + resume_preference_path]
    mov r8d, 1
    call MoveFileExW
    jmp .Lresume_pref_return
.Lresume_pref_none:
    xor eax, eax
.Lresume_pref_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN win_resume_preference

.data
resume_preference_tail: .short 92, 'p','l','a','y','e','r','-','r','e','s','u','m','e','.','t','x','t',0
.bss
resume_preference_path: .zero RESUME_WIDE*2
resume_preference_temp: .zero RESUME_WIDE*2
.text
