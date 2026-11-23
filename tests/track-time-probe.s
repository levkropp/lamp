# Test-only adapter for the two-register removal iterator.
.include "lamp.inc"
.text
FN track_cut_at
    sub rsp, 40
    call test_time_cut
    mov rdx, [rax+8]
    mov rax, [rax]
    add rsp, 40
    ret
ENDFN track_cut_at
