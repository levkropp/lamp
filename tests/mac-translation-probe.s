# Test-only instruction semantics used by the expanded decoder tree.
.include "lamp.inc"
FN mac_translation_probe
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
    movdqa xmm0, [rsi]
    pmaddwd xmm0, [rsi + 16]
    paddd xmm0, [rsi + 32]
    movdqu [rdi], xmm0
    movsd xmm0, [rsi + 48]
    stc
    cvtsd2si rax, xmm0
    mov [rdi + 16], rax
    setc byte ptr [rdi + 64]
    cvttsd2si rax, xmm0
    mov [rdi + 24], rax
    cvtsd2si eax, xmm0
    mov [rdi + 32], eax
    cvttsd2si eax, xmm0
    mov [rdi + 36], eax
    mov rax, [rsi + 56]
    bt dword ptr [rsi + 72], 0
    sbb rax, [rsi + 64]
    mov [rdi + 40], rax
    setc byte ptr [rdi + 65]
    seto byte ptr [rdi + 66]
    setz byte ptr [rdi + 67]
    mov ecx, [rsi + 76]
    xor eax, eax
    stc
.Lprobe_loop:
    lea rax, [rax + 1]
    loop .Lprobe_loop
    mov [rdi + 48], rax
    setc byte ptr [rdi + 68]
    setz byte ptr [rdi + 69]
    lea rax, [rip + probe_quad]
    lea rcx, [rip + probe_data]
    sub rax, rcx
    mov [rdi + 56], rax
    pause
    pop rdi
    pop rsi
    ret
ENDFN mac_translation_probe
RODATA
probe_data: .byte 42
probe_quad: .quad 0x123456789abcdef0
.equ PROBE_SIZE, . - probe_data
.if . - probe_data - 9
.error "test packed data size"
.endif
