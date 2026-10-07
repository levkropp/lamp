# Test-only ABI thunk; never linked into a shipping executable.
.include "lamp.inc"
.globl chapter_navigate_probe
.text
FN chapter_navigate_probe
    sub rsp, 40
    call queue_navigate
    test eax, eax
    jz .Lchapter_probe_failed
    mov rax, rdx
    jmp .Lchapter_probe_done
.Lchapter_probe_failed:
    mov rax, -1
.Lchapter_probe_done:
    add rsp, 40
    ret
ENDFN chapter_navigate_probe
.ifndef WINDOWS
.section .note.GNU-stack,"",@progbits
.endif
