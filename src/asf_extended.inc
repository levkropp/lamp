# Original ASF Extended Stream Properties. MIT, see LICENSE.
# ASF specification 01.20.03 section 4.1: counted names and extension
# information can precede one embedded ordinary Stream Properties object.
.text
# RCX=object, RDX=exact end -> EAX=1/0. Entire lists are preflighted before
# any audio is published. The shared budgets belong to asf_open.
FN asf_extended_stream_properties
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    cmp rdx, rcx
    jb .Lasf_extended_bad
    mov rax, rdx
    sub rax, rcx
    cmp rax, 88
    jb .Lasf_extended_bad
    cmp rax, [rsi + 16]
    jne .Lasf_extended_bad
    movzx ebx, word ptr [rsi + 72]
    test ebx, ebx
    jz .Lasf_extended_bad
    cmp ebx, 127
    ja .Lasf_extended_bad
    movzx r12d, word ptr [rsi + 84]
    movzx r13d, word ptr [rsi + 86]
    lea eax, [r12 + r13]
    cmp eax, [rip + asf_extended_budget]
    ja .Lasf_extended_limit
    sub [rip + asf_extended_budget], eax
    add rsi, 88
.Lasf_extended_name:
    test r12d, r12d
    jz .Lasf_extended_system
    call asf_cancelled
    test eax, eax
    jnz .Lasf_extended_bad
    mov rax, rdi
    sub rax, rsi
    cmp rax, 4
    jb .Lasf_extended_bad
    movzx edx, word ptr [rsi + 2]
    test dl, 1                        # names are counted UTF-16 bytes
    jnz .Lasf_extended_bad
    add edx, 4
    cmp rax, rdx
    jb .Lasf_extended_bad
    add rsi, rdx
    dec r12d
    jmp .Lasf_extended_name
.Lasf_extended_system:
    test r13d, r13d
    jz .Lasf_extended_child
    call asf_cancelled
    test eax, eax
    jnz .Lasf_extended_bad
    mov rax, rdi
    sub rax, rsi
    cmp rax, 22
    jb .Lasf_extended_bad
    mov edx, [rsi + 18]
    add rdx, 22                      # DWORD length plus fixed prefix in 64 bits
    cmp rax, rdx
    jb .Lasf_extended_bad
    add rsi, rdx
    dec r13d
    jmp .Lasf_extended_system
.Lasf_extended_child:
    call asf_cancelled
    test eax, eax
    jnz .Lasf_extended_bad
    cmp rsi, rdi
    je .Lasf_extended_ok             # ordinary standalone stream may exist
    mov rax, rdi
    sub rax, rsi
    cmp rax, 78
    jb .Lasf_extended_bad
    cmp rax, [rsi + 16]
    jne .Lasf_extended_bad           # one complete child consumes the tail
    mov rcx, rsi
    lea rdx, [rip + asf_stream_guid]
    call asf_guid
    jnz .Lasf_extended_bad
    movzx eax, word ptr [rsi + 72]
    and eax, 127
    cmp eax, ebx
    jne .Lasf_extended_bad
    inc dword ptr [rip + asf_all_objects]
    cmp dword ptr [rip + asf_all_objects], ASF_HEADER_OBJECTS
    ja .Lasf_extended_limit
    mov rcx, rsi
    mov rdx, rdi
    call asf_stream_properties
    test eax, eax
    jz .Lasf_extended_bad
.Lasf_extended_ok:
    mov eax, 1
    jmp .Lasf_extended_return
.Lasf_extended_limit:
    mov dword ptr [rip + decode_error], ASF_UNSUPPORTED
.Lasf_extended_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lasf_extended_failed
    mov dword ptr [rip + decode_error], ASF_MALFORMED
.Lasf_extended_failed:
    xor eax, eax
.Lasf_extended_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_extended_stream_properties
