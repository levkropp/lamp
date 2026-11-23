# Original bounded scaling-list syntax and fallback A/B. H.264 7.3.2/7.4.2.
# Normative default list values, in DXVA zig-zag order (H.264 Tables7-3/7-4).
# Constants verified against Chromium135.0.7049.84 media/parsers/h264_parser.cc,
# Copyright2014 The Chromium Authors, BSD3-Clause; see THIRD_PARTY_NOTICES.
RODATA
hp_default4_intra: .byte 6,13,13,20,20,20,28,28,28,28,32,32,32,37,37,42
hp_default4_inter: .byte 10,14,14,20,20,20,24,24,24,24,27,27,27,30,30,34
hp_default8_intra:
    .byte 6,10,10,13,11,13,16,16,16,16,18,18,18,18,18,23
    .byte 23,23,23,23,23,25,25,25,25,25,25,25,27,27,27,27
    .byte 27,27,27,27,29,29,29,29,29,29,29,31,31,31,31,31
    .byte 31,33,33,33,33,33,36,36,36,36,38,38,38,40,40,42
hp_default8_inter:
    .byte 9,13,13,15,13,15,17,17,17,17,19,19,19,19,19,21
    .byte 21,21,21,21,21,22,22,22,22,22,22,22,24,24,24,24
    .byte 24,24,24,24,25,25,25,25,25,25,25,27,27,27,27,27
    .byte 27,28,28,28,28,28,30,30,30,30,32,32,32,33,33,35
.text

# RCX=context,RDX=destination,R8D=16/64 ->1 list,2 use default,0 error.
LOCALFN hp_scaling_list
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    mov rdi, rdx
    mov esi, r8d
    xor r12d, r12d
    mov r13d, 8
    mov dword ptr [rsp+32], 8
.Lhp_scaling_value:
    cmp dword ptr [rsp+32], 0
    je .Lhp_scaling_repeat
    HP_SE -1,-128,127,.Lhp_scaling_bad
    add eax, r13d
    and eax, 255
    mov [rsp+32], eax
    test r12d, r12d
    jnz .Lhp_scaling_next_value
    test eax, eax
    jz .Lhp_scaling_default
.Lhp_scaling_next_value:
    test eax, eax
    jz .Lhp_scaling_repeat
    mov r13d, eax
.Lhp_scaling_repeat:
    mov eax, r13d
    mov [rdi+r12], al
    inc r12d
    cmp r12d, esi
    jb .Lhp_scaling_value
    mov eax, 1
    jmp .Lhp_scaling_return
.Lhp_scaling_default:
    mov eax, 2
    jmp .Lhp_scaling_return
.Lhp_scaling_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_scaling_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_scaling_list

# RCX=context,RDX=destination224B,R8D=listCount6/8,R9D=0SPS/1PPS ->1/0.
LOCALFN hp_scaling_set
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov r12d, r8d
    mov ebp, r9d
    xor r13d, r13d
.Lhp_scaling_set_next:
    mov eax, r13d
    mov r14d, 16
    cmp eax, 6
    jae .Lhp_scaling_set_large
    shl eax, 4
    jmp .Lhp_scaling_set_pointer
.Lhp_scaling_set_large:
    sub eax, 6
    shl eax, 6
    add eax, 96
    mov r14d, 64
.Lhp_scaling_set_pointer:
    lea rdi, [rsi+rax]
    HP_BITS 1,-1,1,.Lhp_scaling_set_bad
    test eax, eax
    jz .Lhp_scaling_set_absent
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, r14d
    call hp_scaling_list
    test eax, eax
    jz .Lhp_scaling_set_bad
    cmp eax, 2
    je .Lhp_scaling_set_default
    jmp .Lhp_scaling_set_advance
.Lhp_scaling_set_absent:
    cmp r13d, 0
    je .Lhp_scaling_set_boundary
    cmp r13d, 3
    je .Lhp_scaling_set_boundary
    cmp r13d, 6
    jae .Lhp_scaling_set_boundary
    lea rdx, [rdi-16]
    jmp .Lhp_scaling_set_copy
.Lhp_scaling_set_boundary:
    test ebp, ebp
    jz .Lhp_scaling_set_default
    cmp dword ptr [rbx+HP_SEQ_SCALING], 0
    je .Lhp_scaling_set_default
    mov rdx, rdi
    sub rdx, rsi
    lea rdx, [rbx+rdx+HP_SPS_MATRIX]
    jmp .Lhp_scaling_set_copy
.Lhp_scaling_set_default:
    lea rdx, [rip+hp_default4_intra]
    cmp r13d, 3
    jb .Lhp_scaling_set_copy
    lea rdx, [rip+hp_default4_inter]
    cmp r13d, 6
    jb .Lhp_scaling_set_copy
    lea rdx, [rip+hp_default8_intra]
    cmp r13d, 6
    je .Lhp_scaling_set_copy
    lea rdx, [rip+hp_default8_inter]
.Lhp_scaling_set_copy:
    xor eax, eax
.Lhp_scaling_set_byte:
    mov cl, [rdx+rax]
    mov [rdi+rax], cl
    inc eax
    cmp eax, r14d
    jb .Lhp_scaling_set_byte
.Lhp_scaling_set_advance:
    inc r13d
    cmp r13d, r12d
    jb .Lhp_scaling_set_next
    mov eax, 1
    jmp .Lhp_scaling_set_return
.Lhp_scaling_set_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_scaling_set_return:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN hp_scaling_set
