# Original ASF audio spreading. MIT, see LICENSE.
# Layout: ASF specification 01.20.03 section 9.1.1. Reassembled objects are
# a chunk matrix stored by column; the codec needs the matrix read by row.
.text
# RCX=bounded Stream Properties, RDX=end -> EAX=available, R8D=span,
# R9D=virtual packet bytes, R10D=chunk bytes, R11D=matrix bytes (0 identity).
# An unavailable layout does not prevent selecting a later supported track.
LOCALFN asf_spread_format
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    lea rcx, [rsi + 40]
    lea rdx, [rip + asf_no_correction]
    call asf_guid
    jnz .Lasf_spread_guid
    # Preserve the old no-correction compatibility: ignored trailing span
    # 0/1 data is common, but a purported multi-packet scheme needs its GUID.
    mov eax, [rsi + 64]
    lea rax, [rsi + rax + 78]
    cmp rax, rdi
    jae .Lasf_spread_identity
    cmp byte ptr [rax], 1
    ja .Lasf_spread_unavailable
    jmp .Lasf_spread_identity
.Lasf_spread_guid:
    lea rcx, [rsi + 40]
    lea rdx, [rip + asf_audio_spread]
    call asf_guid
    jnz .Lasf_spread_unavailable
    mov eax, [rsi + 64]
    lea rcx, [rsi + rax + 78]
    mov rax, rdi
    sub rax, rcx
    mov edx, [rsi + 68]
    test edx, edx
    jz .Lasf_spread_bound
    mov eax, edx                      # earlier object validation bounded it
.Lasf_spread_bound:
    cmp rax, 7
    jb .Lasf_spread_unavailable
    movzx edx, word ptr [rcx + 5]
    add edx, 7
    cmp rax, rdx
    jb .Lasf_spread_unavailable
    movzx r8d, byte ptr [rcx]
    test r8d, r8d
    jz .Lasf_spread_unavailable
    cmp r8d, 1
    je .Lasf_spread_identity
    movzx r9d, word ptr [rcx + 1]
    movzx r10d, word ptr [rcx + 3]
    test r10d, r10d
    jz .Lasf_spread_unavailable
    mov eax, r9d
    xor edx, edx
    div r10d
    test edx, edx
    jnz .Lasf_spread_unavailable
    test eax, eax
    jz .Lasf_spread_unavailable
    cmp eax, 1
    je .Lasf_spread_identity           # a one-row matrix is already ordered
    mov r11d, r9d
    imul r11d, r8d                    # <=255*65535, below ASF_LIMIT
    mov eax, 1
    jmp .Lasf_spread_format_done
.Lasf_spread_identity:
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 1
    jmp .Lasf_spread_format_done
.Lasf_spread_unavailable:
    xor eax, eax
.Lasf_spread_format_done:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN asf_spread_format

# RCX=source, RDX=destination, R8D=capacity of each, R9D=span,
# [rsp+40]=virtual packet bytes, [rsp+48]=chunk bytes -> EAX=1/0.
# Buffers must be disjoint, and capacity must equal span*packet bytes.
# Invalid geometry/pointer wrap rejects before reading/writing either buffer.
# Cancellation can leave partial private output, never a changed source.
FN asf_despread
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12, rcx
    mov r13, rdx
    mov ebx, r9d
    mov r14d, [rsp + 104]
    mov r15d, [rsp + 112]
    test ebx, ebx
    jz .Lasf_despread_bad
    cmp ebx, 255
    ja .Lasf_despread_bad
    test r15d, r15d
    jz .Lasf_despread_bad
    cmp r15d, 65535
    ja .Lasf_despread_bad
    cmp r14d, 65535
    ja .Lasf_despread_bad
    mov eax, r14d
    xor edx, edx
    div r15d
    test edx, edx
    jnz .Lasf_despread_bad
    test eax, eax
    jz .Lasf_despread_bad
    mov ebp, eax
    mov eax, r14d
    imul eax, ebx
    cmp eax, r8d
    jne .Lasf_despread_bad
    mov r11d, eax
    test r12, r12
    jz .Lasf_despread_bad
    test r13, r13
    jz .Lasf_despread_bad
    mov r8, r12
    add r8, r11
    jc .Lasf_despread_bad
    mov r9, r13
    add r9, r11
    jc .Lasf_despread_bad
    cmp r8, r13
    jbe .Lasf_despread_disjoint
    cmp r9, r12
    ja .Lasf_despread_bad
.Lasf_despread_disjoint:
    mov rdi, r13
    mov r13, r12                     # current input row in column zero
    sub r14d, r15d                   # distance after rep movsb to next column
.Lasf_despread_row:
    mov rsi, r13
    mov r10d, ebx
.Lasf_despread_column:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lasf_despread_copy
    cmp dword ptr [rax], 0
    jne .Lasf_despread_bad
.Lasf_despread_copy:
    mov ecx, r15d
    rep movsb
    add rsi, r14
    dec r10d
    jnz .Lasf_despread_column
    add r13, r15
    dec ebp
    jnz .Lasf_despread_row
    mov eax, 1
    jmp .Lasf_despread_return
.Lasf_despread_bad:
    xor eax, eax
.Lasf_despread_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN asf_despread
