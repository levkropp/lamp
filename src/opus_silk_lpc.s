# RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
# Handwritten fixed-point SILK LPC conversion and stability helpers.
# RFC6716 NLSF2A.c,LPC_inv_pred_gain.c,bwexpander[_32].c,Inlines.h.
# Copyright(c)2006-2012 IETF Trust and Skype Limited. BSD conditions
# in THIRD_PARTY_NOTICES. No CRT, heap or runtime reference code.
.include "lamp.inc"
.include "opus_silk_lpc_layout.inc"
RODATA
.include "opus_silk_lpc_tables.inc"
.text
# ECX=nonzero signed denominator except INT_MIN,EDX=result Q1..61.
# Normative approximation; invalid inputs return0.
FN op_silk_inverse32
    test ecx, ecx
    jz .Lsl_inv_bad
    cmp ecx, 0x80000000
    je .Lsl_inv_bad
    cmp edx, 1
    jl .Lsl_inv_bad
    cmp edx, 61
    jg .Lsl_inv_bad
    mov r9d, edx
    mov eax, ecx
    cdq
    xor eax, edx
    sub eax, edx               # abs denominator
    bsr eax, eax
    mov r8d, 30
    sub r8d, eax               # headroom
    mov eax, ecx
    mov ecx, r8d
    shl eax, cl
    mov r10d, eax              # normalized denominator
    sar eax, 16
    mov ecx, eax
    mov eax, 536870911
    cdq
    idiv ecx
    mov r11d, eax              # reciprocal seed (signed16)
    movsxd rax, r10d
    movsx rcx, r11w
    imul rax, rcx
    sar rax, 16
    mov ecx, 536870912
    sub ecx, eax
    shl ecx, 3                 # error Q32, overflow is normative
    movsxd rax, ecx
    movsxd rdx, r11d
    imul rax, rdx
    sar rax, 16                # SMULWW(error,seed)
    shl r11d, 16
    add eax, r11d
    mov ecx, 61
    sub ecx, r8d
    sub ecx, r9d
    jle .Lsl_inv_left
    cmp ecx, 32
    jae .Lsl_inv_bad
    sar eax, cl
    ret
.Lsl_inv_left:
    neg ecx
    mov edx, 0x7fffffff
    sar edx, cl
    cmp eax, edx
    cmovg eax, edx
    mov edx, 0x80000000
    sar edx, cl
    cmp eax, edx
    cmovl eax, edx
    shl eax, cl
    ret
.Lsl_inv_bad:
    xor eax, eax
    ret
ENDFN op_silk_inverse32

FN op_silk_bwexpand
    test rcx, rcx
    jz .Lsl_bw_bad
    mov r10, [rcx + SB_AR]
    test r10, r10
    jz .Lsl_bw_bad
    mov r11d, [rcx + SB_ORDER]
    cmp r11d, 1
    jl .Lsl_bw_bad
    cmp r11d, 16
    ja .Lsl_bw_bad
    cmp [rcx + SB_CAP], r11d
    jb .Lsl_bw_bad
    mov r8d, [rcx + SB_CHIRP]
    cmp r8d, 65536
    ja .Lsl_bw_bad
    mov edx, [rcx + SB_WIDTH]
    cmp edx, 16
    je .Lsl_bw_start
    cmp edx, 32
    jne .Lsl_bw_bad
.Lsl_bw_start:
    sub r11d, 1
    mov r9d, r8d
    sub r9d, 65536
    xor ecx, ecx
    cmp edx, 16
    je .Lsl_bw16
.Lsl_bw32:
    movsxd rax, dword ptr [r10 + rcx*4]
    movsxd rdx, r8d
    imul rax, rdx
    sar rax, 16
    mov [r10 + rcx*4], eax
    cmp ecx, r11d
    je .Lsl_bw_good
    mov eax, r8d
    imul eax, r9d
    sar eax, 15
    inc eax
    sar eax, 1
    add r8d, eax
    inc ecx
    jmp .Lsl_bw32
.Lsl_bw16:
    movsx eax, word ptr [r10 + rcx*2]
    imul eax, r8d
    sar eax, 15
    inc eax
    sar eax, 1
    mov [r10 + rcx*2], ax
    cmp ecx, r11d
    je .Lsl_bw_good
    mov eax, r8d
    imul eax, r9d
    sar eax, 15
    inc eax
    sar eax, 1
    add r8d, eax
    inc ecx
    jmp .Lsl_bw16
.Lsl_bw_good:
    mov eax, 1
    ret
.Lsl_bw_bad:
    xor eax, eax
    ret
ENDFN op_silk_bwexpand

FN op_silk_lpc_inverse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 192
    test rcx, rcx
    jz .Lsl_lpc_bad
    mov rsi, [rcx + SL_AR]
    test rsi, rsi
    jz .Lsl_lpc_bad
    mov edi, [rcx + SL_ORDER]
    cmp edi, 10
    je .Lsl_lpc_order
    cmp edi, 16
    jne .Lsl_lpc_bad
.Lsl_lpc_order:
    cmp [rcx + SL_CAP], edi
    jb .Lsl_lpc_bad
    lea r14, [rsp + 32]           # even-order first coefficient plane
    xor ecx, ecx
    xor edx, edx
.Lsl_lpc_load:
    movsx eax, word ptr [rsi + rcx*2]
    add edx, eax
    shl eax, 12
    mov [r14 + rcx*4], eax
    inc ecx
    cmp ecx, edi
    jb .Lsl_lpc_load
    cmp edx, 4096
    jge .Lsl_lpc_bad
    mov r13d, 0x40000000
    lea r12d, [rdi - 1]
.Lsl_lpc_stage:
    mov eax, [r14 + r12*4]
    cmp eax, 16773022           # round(.99975*2^24)
    jg .Lsl_lpc_bad
    cmp eax, -16773022
    jl .Lsl_lpc_bad
    shl eax, 7
    neg eax
    mov [rsp + 160], eax          # RC Q31
    movsxd rax, eax
    imul rax, rax
    sar rax, 32
    mov ecx, 0x40000000
    sub ecx, eax
    mov [rsp + 164], ecx          # multiplier1 Q30
    test r12d, r12d
    jz .Lsl_lpc_last
    bsr edx, ecx
    inc edx
    mov [rsp + 168], edx          # multiplier2 Q
    add edx, 30
    call op_silk_inverse32
    mov [rsp + 172], eax
    movsxd rax, r13d
    movsxd rdx, dword ptr [rsp + 164]
    imul rax, rdx
    sar rax, 32
    shl eax, 2
    mov r13d, eax
    mov r15, r14
    lea r14, [rsp + 32]
    test r12d, 1
    jz .Lsl_lpc_update
    lea r14, [rsp + 96]
.Lsl_lpc_update:
    xor ebx, ebx
.Lsl_lpc_coef:
    mov ecx, r12d
    sub ecx, ebx
    dec ecx
    movsxd rax, dword ptr [r15 + rcx*4]
    movsxd rdx, dword ptr [rsp + 160]
    imul rax, rdx
    sar rax, 30
    inc rax
    sar rax, 1                 # round product>>31
    mov edx, [r15 + rbx*4]
    sub edx, eax
    jno .Lsl_lpc_subtract_ready
    # Signed subtraction overflow: sign of the original minuend selects cap.
    mov edx, [r15 + rbx*4]
    sar edx, 31
    xor edx, 0x7fffffff
.Lsl_lpc_subtract_ready:
    movsxd rax, edx
    movsxd rdx, dword ptr [rsp + 172]
    imul rax, rdx
    mov ecx, [rsp + 168]
    dec ecx
    sar rax, cl
    inc rax
    sar rax, 1
    movsxd rdx, eax
    cmp rax, rdx
    jne .Lsl_lpc_bad            #RFC8251 rejects rounded 64-bit overflow
    mov [r14 + rbx*4], eax
    inc ebx
    cmp ebx, r12d
    jb .Lsl_lpc_coef
    dec r12d
    jmp .Lsl_lpc_stage
.Lsl_lpc_last:
    movsxd rax, r13d
    movsxd rdx, ecx
    imul rax, rdx
    sar rax, 32
    shl eax, 2
    jmp .Lsl_lpc_done
.Lsl_lpc_bad:
    xor eax, eax
.Lsl_lpc_done:
    add rsp, 192
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_lpc_inverse

# Internal polynomial convolution. RCX=out, RDX=interleaved cosine,R8D=half order.
LOCALFN sl_find_poly
    mov r11d, r8d
    mov r8, rdx
    mov rdx, rcx
    mov dword ptr [rdx], 65536
    mov eax, [r8]
    neg eax
    mov [rdx + 4], eax
    mov r9d, 1
.Lsl_poly_stage:
    movsxd rcx, dword ptr [r8 + r9*8]
    movsxd rax, dword ptr [rdx + r9*4]
    imul rax, rcx
    sar rax, 15
    inc rax
    sar rax, 1
    mov r10d, [rdx + r9*4 - 4]
    add r10d, r10d
    sub r10d, eax
    mov [rdx + r9*4 + 4], r10d
    mov r10d, r9d
.Lsl_poly_inner:
    cmp r10d, 1
    jle .Lsl_poly_first
    movsxd rax, dword ptr [rdx + r10*4 - 4]
    imul rax, rcx
    sar rax, 15
    inc rax
    sar rax, 1
    neg eax
    add eax, [rdx + r10*4 - 8]
    add [rdx + r10*4], eax
    dec r10d
    jmp .Lsl_poly_inner
.Lsl_poly_first:
    sub [rdx + 4], ecx
    inc r9d
    cmp r9d, r11d
    jb .Lsl_poly_stage
    ret
ENDFN sl_find_poly

FN op_silk_nlsf2a
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 352
    mov rbx, rcx
    test rbx, rbx
    jz .Lsl_a_bad
    mov rsi, [rbx + SA_NLSF]
    mov rdi, [rbx + SA_OUT]
    test rsi, rsi
    jz .Lsl_a_bad
    test rdi, rdi
    jz .Lsl_a_bad
    mov r12d, [rbx + SA_ORDER]
    lea r13, [rip + sl_order10]
    cmp r12d, 10
    je .Lsl_a_order
    cmp r12d, 16
    jne .Lsl_a_bad
    lea r13, [rip + sl_order16]
.Lsl_a_order:
    cmp [rbx + SA_IN_CAP], r12d
    jb .Lsl_a_bad
    cmp [rbx + SA_OUT_CAP], r12d
    jb .Lsl_a_bad
    xor ecx, ecx
.Lsl_a_guard:
    cmp word ptr [rsi + rcx*2], 32767
    ja .Lsl_a_bad
    inc ecx
    cmp ecx, r12d
    jb .Lsl_a_guard
    xor ecx, ecx
    lea r15, [rip + sl_cos]
.Lsl_a_cosines:
    movzx eax, word ptr [rsi + rcx*2]
    mov edx, eax
    shr edx, 8
    and eax, 255
    movsx r8d, word ptr [r15 + rdx*2]
    movsx edx, word ptr [r15 + rdx*2 + 2]
    sub edx, r8d
    imul eax, edx
    shl r8d, 8
    add eax, r8d
    sar eax, 3
    inc eax
    sar eax, 1
    movzx edx, byte ptr [r13 + rcx]
    mov [rsp + rdx*4 + 64], eax
    inc ecx
    cmp ecx, r12d
    jb .Lsl_a_cosines
    mov r13d, r12d
    shr r13d, 1
    lea rcx, [rsp + 128]
    lea rdx, [rsp + 64]
    mov r8d, r13d
    call sl_find_poly
    lea rcx, [rsp + 168]
    lea rdx, [rsp + 68]
    mov r8d, r13d
    call sl_find_poly
    xor ecx, ecx
.Lsl_a_combine:
    mov eax, [rsp + rcx*4 + 128]
    add eax, [rsp + rcx*4 + 132]     # Ptmp
    mov edx, [rsp + rcx*4 + 172]
    sub edx, [rsp + rcx*4 + 168]     # Qtmp
    mov r8d, edx
    neg r8d
    sub r8d, eax
    mov [rsp + rcx*4 + 208], r8d
    sub edx, eax
    mov r8d, r12d
    sub r8d, ecx
    dec r8d
    mov [rsp + r8*4 + 208], edx
    inc ecx
    cmp ecx, r13d
    jb .Lsl_a_combine
    lea rax, [rsp + 208]
    mov [rsp + 304 + SB_AR], rax
    mov [rsp + 304 + SB_ORDER], r12d
    mov [rsp + 304 + SB_CAP], r12d
    mov dword ptr [rsp + 304 + SB_WIDTH], 32
    xor r14d, r14d
    xor r15d, r15d
.Lsl_a_limit:
    xor edx, edx
    xor ecx, ecx
.Lsl_a_max:
    mov eax, [rsp + rcx*4 + 208]
    mov r8d, eax
    neg r8d
    test eax, eax
    cmovs eax, r8d
    cmp eax, edx
    jle .Lsl_a_max_next
    mov edx, eax
    mov r15d, ecx
.Lsl_a_max_next:
    inc ecx
    cmp ecx, r12d
    jb .Lsl_a_max
    sar edx, 4
    inc edx
    sar edx, 1
    cmp edx, 32767
    jle .Lsl_a_convert
    mov eax, 163838
    cmp edx, eax
    cmovg edx, eax
    lea ecx, [r15 + 1]
    imul ecx, edx
    sar ecx, 2
    sub edx, 32767
    mov eax, edx
    shl eax, 14
    cdq
    idiv ecx
    mov ecx, 65470             # SILK_FIX_CONST(.999,16)
    sub ecx, eax
    mov [rsp + 304 + SB_CHIRP], ecx
    lea rcx, [rsp + 304]
    call op_silk_bwexpand
    inc r14d
    cmp r14d, 10
    jb .Lsl_a_limit
.Lsl_a_convert:
    xor ecx, ecx
.Lsl_a_round:
    mov eax, [rsp + rcx*4 + 208]
    sar eax, 4
    inc eax
    sar eax, 1
    cmp r14d, 10
    jne .Lsl_a_store
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov edx, eax
    shl edx, 5
    mov [rsp + rcx*4 + 208], edx
.Lsl_a_store:
    mov [rdi + rcx*2], ax
    inc ecx
    cmp ecx, r12d
    jb .Lsl_a_round
    mov [rsp + 288 + SL_AR], rdi
    mov [rsp + 288 + SL_ORDER], r12d
    mov [rsp + 288 + SL_CAP], r12d
    xor r14d, r14d
.Lsl_a_stability:
    lea rcx, [rsp + 288]
    call op_silk_lpc_inverse
    cmp eax, 107374            # round((1/10000)*2^30)
    jge .Lsl_a_good
    mov ecx, r14d
    mov eax, 2
    shl eax, cl
    mov ecx, 65536
    sub ecx, eax
    mov [rsp + 304 + SB_CHIRP], ecx
    lea rcx, [rsp + 304]
    call op_silk_bwexpand
    xor ecx, ecx
.Lsl_a_stable_round:
    mov eax, [rsp + rcx*4 + 208]
    sar eax, 4
    inc eax
    sar eax, 1
    mov [rdi + rcx*2], ax
    inc ecx
    cmp ecx, r12d
    jb .Lsl_a_stable_round
    inc r14d
    cmp r14d, 16
    jb .Lsl_a_stability
.Lsl_a_good:
    mov eax, 1
    jmp .Lsl_a_done
.Lsl_a_bad:
    xor eax, eax
.Lsl_a_done:
    add rsp, 352
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_nlsf2a
