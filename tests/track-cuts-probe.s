# Test-only wrapper for the internal two-register buffer result.
.include "lamp.inc"
.text
FN track_cut_probe_buffer
    sub rsp, 40
    call track_cut_buffer
    shl rdx, 32
    or rax, rdx
    add rsp, 40
    ret
ENDFN track_cut_probe_buffer
