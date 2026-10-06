# Original resume list in x86-64 assembly. MIT, see LICENSE.
# The players keep where playback stopped in a small text file of lines
# "<milliseconds>\t<list key>\t<heard file>\n", newest first: the list key
# is the absolute path of the list's first file (so a list resumes in any of
# its files) and the heard file the absolute path of the file playing when
# it stopped. Paths are UTF-8; lines that do not have this form are dropped
# when the file is rewritten. The platforms find, read and write the file.
.include "lamp.inc"
.globl resume_find, resume_write

.equ RESUME_MAX, 256                # lines kept

.text
# RSI=line, RDI=end -> CF for no line left; else RAX=milliseconds, R8=key,
# R9=its end (the tab), R10=heard file, R11=its end, RSI=the next line, and
# EDX=1 when the line has the form.
LOCALFN resume_line
    cmp rsi, rdi
    jae .Lresume_line_none
    xor eax, eax
    xor edx, edx                          # well formed
    xor r8d, r8d                          # digits
.Lresume_line_digit:
    cmp rsi, rdi
    jae .Lresume_line_end
    movzx ecx, byte ptr [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lresume_line_key
    cmp r8d, 18                           # at most 18 digits
    jae .Lresume_line_skip
    imul rax, rax, 10
    add rax, rcx
    inc r8d
    inc rsi
    jmp .Lresume_line_digit
.Lresume_line_key:
    test r8d, r8d
    jz .Lresume_line_skip
    cmp byte ptr [rsi], 9                 # tab
    jne .Lresume_line_skip
    inc rsi
    mov r8, rsi
.Lresume_line_key_char:
    cmp rsi, rdi
    jae .Lresume_line_end
    movzx ecx, byte ptr [rsi]
    cmp ecx, 10
    je .Lresume_line_end
    cmp ecx, 9
    je .Lresume_line_heard
    inc rsi
    jmp .Lresume_line_key_char
.Lresume_line_heard:
    mov r9, rsi
    cmp r9, r8
    je .Lresume_line_skip                 # an empty key
    inc rsi
    mov r10, rsi
.Lresume_line_heard_char:
    cmp rsi, rdi
    jae .Lresume_line_heard_end
    movzx ecx, byte ptr [rsi]
    cmp ecx, 10
    je .Lresume_line_heard_end
    cmp ecx, 9
    je .Lresume_line_skip
    inc rsi
    jmp .Lresume_line_heard_char
.Lresume_line_heard_end:
    mov r11, rsi
    cmp r11, r10
    je .Lresume_line_end                  # an empty heard file
    mov edx, 1
    jmp .Lresume_line_end
.Lresume_line_skip:
    xor edx, edx
.Lresume_line_end:
    cmp rsi, rdi                          # past the newline
    jae .Lresume_line_done
    cmp byte ptr [rsi], 10
    je .Lresume_line_newline
    inc rsi
    jmp .Lresume_line_end
.Lresume_line_newline:
    inc rsi
.Lresume_line_done:
    clc
    ret
.Lresume_line_none:
    stc
    ret
ENDFN resume_line

# R8=start, R9=end, RCX=NUL-terminated text -> ZF when they are equal.
LOCALFN resume_equal
    push rbx
.Lresume_equal_char:
    cmp r8, r9
    je .Lresume_equal_end
    movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lresume_equal_done                # shorter text: not equal (ZF clear)
    cmp al, [r8]
    jne .Lresume_equal_done
    inc r8
    inc rcx
    jmp .Lresume_equal_char
.Lresume_equal_end:
    cmp byte ptr [rcx], 0
.Lresume_equal_done:
    pop rbx
    ret
ENDFN resume_equal

# RCX=file text, RDX=its end, R8=list key (NUL-terminated) -> EAX=1 when the
# key has a line: RDX=milliseconds, R8=its heard file, R9D=bytes; else 0.
FN resume_find
    push rsi
    push rdi
    push rbx
    push r12
    mov rsi, rcx
    mov rdi, rdx
    mov r12, r8
.Lresume_find_line:
    call resume_line
    jc .Lresume_find_none
    test edx, edx
    jz .Lresume_find_line
    mov rbx, rax
    push r10
    push r11
    mov rcx, r12
    call resume_equal
    pop r11
    pop r10
    jne .Lresume_find_line
    mov eax, 1
    mov rdx, rbx
    mov r8, r10
    mov r9, r11
    sub r9, r10
    jmp .Lresume_find_return
.Lresume_find_none:
    xor eax, eax
.Lresume_find_return:
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN resume_find

# RCX=old file text, RDX=its end, R8=list key, R9=heard file (both
# NUL-terminated; R9=0 to forget the key), fifth argument=milliseconds,
# sixth=output (room for the old bytes, both paths and 32) -> RAX=new bytes:
# the key's new line first, then the other well-formed lines, RESUME_MAX in
# all. Keys or files holding a tab or a newline are not kept.
FN resume_write
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rsi, rcx
    mov r15, rdx                          # old end
    mov r12, r8                           # key
    mov r13, r9                           # heard file
    mov rdi, [rsp + 48 + 56]              # output
    mov r14, rdi
    xor ebx, ebx                          # lines written
    test r13, r13
    jz .Lresume_write_old
    mov rcx, r12
    call resume_clean
    jc .Lresume_write_old
    mov rcx, r13
    call resume_clean
    jc .Lresume_write_old
    # The new line.
    mov rax, [rsp + 40 + 56]
    lea r8, [rdi + 20]                    # digits, backwards
    mov r9, r8
    mov ecx, 10
.Lresume_write_digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .Lresume_write_digit
.Lresume_write_digits:
    movzx eax, byte ptr [r9]
    mov [rdi], al
    inc rdi
    inc r9
    cmp r9, r8
    jb .Lresume_write_digits
    mov byte ptr [rdi], 9
    inc rdi
    mov rcx, r12
    call resume_copy
    mov byte ptr [rdi], 9
    inc rdi
    mov rcx, r13
    call resume_copy
    mov byte ptr [rdi], 10
    inc rdi
    inc ebx
.Lresume_write_old:
    xchg rdi, r15                         # RDI=old end for resume_line, R15=output
.Lresume_write_line:
    cmp ebx, RESUME_MAX
    jae .Lresume_write_done
    mov rax, rsi                          # this line's start
    push rax
    call resume_line
    pop rax
    jc .Lresume_write_done
    test edx, edx
    jz .Lresume_write_line
    push rax
    push rsi
    mov rcx, r12
    call resume_equal
    pop rsi
    pop rax
    je .Lresume_write_line                # the key's old line
    mov rcx, rsi                          # copy the line, ending it with a newline
    sub rcx, rax
.Lresume_write_copy:
    test rcx, rcx
    jz .Lresume_write_copied
    mov dl, [rax]
    mov [r15], dl
    inc rax
    inc r15
    dec rcx
    jmp .Lresume_write_copy
.Lresume_write_copied:
    cmp byte ptr [r15 - 1], 10
    je .Lresume_write_counted
    mov byte ptr [r15], 10
    inc r15
.Lresume_write_counted:
    inc ebx
    jmp .Lresume_write_line
.Lresume_write_done:
    mov rax, r15
    sub rax, r14
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN resume_write

# RCX=NUL-terminated text -> CF when it is empty or holds a tab or newline.
LOCALFN resume_clean
    cmp byte ptr [rcx], 0
    je .Lresume_clean_bad
.Lresume_clean_char:
    movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lresume_clean_ok
    cmp eax, 9
    je .Lresume_clean_bad
    cmp eax, 10
    je .Lresume_clean_bad
    inc rcx
    jmp .Lresume_clean_char
.Lresume_clean_ok:
    clc
    ret
.Lresume_clean_bad:
    stc
    ret
ENDFN resume_clean

# RCX=NUL-terminated text, RDI=destination -> RDI past the copy.
LOCALFN resume_copy
.Lresume_copy_char:
    movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lresume_copy_done
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .Lresume_copy_char
.Lresume_copy_done:
    ret
ENDFN resume_copy
