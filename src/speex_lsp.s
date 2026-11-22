# Original assembly Speex spectral codebook reconstruction. MIT.
# Adapted from Jean-Marc Valin's Speex 1.2.1 quant_lsp.c (BSD), with
# original codebook data in speex_lsp_tables.inc. See THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "speex_packet.inc"
RODATA
.include "speex_lsp_tables.inc"
.p2align 3
spx_lsp_nb_base: .float .25, .5, .75, 1., 1.25, 1.5, 1.75, 2., 2.25, 2.5
spx_lsp_high_base: .float .75, 1.0625, 1.375, 1.6875, 2., 2.3125, 2.625, 2.9375
# book pointer, width, output coefficient offset, double-precision scale.
# The reference uses these DECIMAL double constants rather than exact powers
# of two. Each stage adds in double then rounds back to float independently.
.p2align 3
spx_lsp_nb_books:
    .quad spx_cdbk_nb
    .long 10, 0
    .double 0.0039062
    .quad spx_cdbk_nb_low1
    .long 5, 0
    .double 0.0019531
    .quad spx_cdbk_nb_low2
    .long 5, 0
    .double 0.00097656
    .quad spx_cdbk_nb_high1
    .long 5, 5
    .double 0.0019531
    .quad spx_cdbk_nb_high2
    .long 5, 5
    .double 0.00097656
spx_lsp_lbr_books:
    .quad spx_cdbk_nb
    .long 10, 0
    .double 0.0039062
    .quad spx_cdbk_nb_low1
    .long 5, 0
    .double 0.0019531
    .quad spx_cdbk_nb_high1
    .long 5, 5
    .double 0.0019531
spx_lsp_high_books:
    .quad spx_high_lsp_cdbk
    .long 8, 0
    .double 0.0039062
    .quad spx_high_lsp_cdbk2
    .long 8, 0
    .double 0.0019531
.text
# RCX=Bits, RDX=float output, R8D=kind (0 NB30/1 NB18/2 high12),
# R9D=output coefficient capacity. Returns 10/10/8 coefficients, or 0.
# Truncated input sets the bit reader's sticky error without advancing;
# other invalid arguments leave it unchanged. Output commits on success only.
# Output must not overlap the state or its complete source buffer.
FN spx_lsp_unquant
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 80
    mov rsi, rcx
    mov rdi, rdx
    test rcx, rcx
    jz .Lspxl_bad
    test rdx, rdx
    jz .Lspxl_bad
    cmp r8d, 2
    ja .Lspxl_bad
    lea rbx, [rip+spx_lsp_nb_books]
    lea r10, [rip+spx_lsp_nb_base]
    mov r12d, 5
    mov r13d, 10
    test r8d, r8d
    jz .Lspxl_kind_ready
    lea rbx, [rip+spx_lsp_lbr_books]
    mov r12d, 3
    cmp r8d, 1
    je .Lspxl_kind_ready
    lea rbx, [rip+spx_lsp_high_books]
    lea r10, [rip+spx_lsp_high_base]
    mov r12d, 2
    mov r13d, 8
.Lspxl_kind_ready:
    cmp r9d, r13d
    jb .Lspxl_bad
    lea rax, [r13*4]
    add rax, rdi
    jc .Lspxl_bad
    mov r11, rsi
    add r11, SPXB_SIZE
    jc .Lspxl_bad
    cmp rdi, r11
    jae .Lspxl_state_disjoint
    cmp rsi, rax
    jb .Lspxl_bad
.Lspxl_state_disjoint:
    mov r8d, [rsi+SPXB_BITS]
    add r8, 7
    shr r8, 3
    mov r9, [rsi+SPXB_DATA]
    add r8, r9
    jc .Lspxl_bad
    cmp rdi, r8
    jae .Lspxl_data_disjoint
    cmp r9, rax
    jb .Lspxl_bad
.Lspxl_data_disjoint:
    xor eax, eax
.Lspxl_initialize:
    mov edx, [r10+rax*4]
    mov [rsp+32+rax*4], edx
    inc eax
    cmp eax, r13d
    jb .Lspxl_initialize
    mov rcx, rsi
    call spx_bits_remaining
    test eax, eax
    js .Lspxl_bad
    imul edx, r12d, 6
    cmp eax, edx
    jae .Lspxl_book
    mov rcx, rsi
    call spx_bits_advance              # atomically marks a truncated source
    jmp .Lspxl_bad
.Lspxl_book:
    mov rcx, rsi
    mov edx, 6
    call spx_bits_read
    mov r8d, [rbx+8]
    imul eax, r8d
    mov rdx, [rbx]
    add rdx, rax
    mov r9d, [rbx+12]
    lea r9, [rsp+32+r9*4]
    movsd xmm2, [rbx+16]
.Lspxl_coefficient:
    movsx eax, byte ptr [rdx]
    cvtsi2sd xmm0, eax
    mulsd xmm0, xmm2
    movss xmm1, [r9]
    cvtss2sd xmm1, xmm1
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [r9], xmm0
    inc rdx
    add r9, 4
    dec r8d
    jnz .Lspxl_coefficient
    add rbx, 24
    dec r12d
    jnz .Lspxl_book
    xor eax, eax
.Lspxl_commit:
    mov edx, [rsp+32+rax*4]
    mov [rdi+rax*4], edx
    inc eax
    cmp eax, r13d
    jb .Lspxl_commit
    mov eax, r13d
    jmp .Lspxl_return
.Lspxl_bad:
    xor eax, eax
.Lspxl_return:
    add rsp, 80
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_lsp_unquant
