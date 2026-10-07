# Test-only aliases and return-value thunks. The included queue is the
# shipping source; no test branches or replacement timeline implementation.
.include "queue.s"
.globl queue_test_count, queue_test_marks, queue_test_capacity
.set queue_test_count, queue_mark_count
.set queue_test_marks, queue_marks
.set queue_test_capacity, QUEUE_MARKS
.text
.globl queue_heard_probe, queue_navigate_probe
FN queue_heard_probe
    sub rsp, 40
    mov [rsp + 32], rdx
    call queue_heard
    mov rcx, [rsp + 32]
    mov [rcx], rdx
    add rsp, 40
    ret
ENDFN queue_heard_probe
FN queue_navigate_probe
    sub rsp, 40
    call queue_navigate
    test eax, eax
    jz .Ltimeline_navigation_failed
    mov rax, rdx
    jmp .Ltimeline_navigation_return
.Ltimeline_navigation_failed:
    mov rax, -1
.Ltimeline_navigation_return:
    add rsp, 40
    ret
ENDFN queue_navigate_probe
.ifndef WINDOWS
.section .note.GNU-stack,"",@progbits
.endif
