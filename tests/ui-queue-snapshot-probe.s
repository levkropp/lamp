# Test-only exports; compiles the shipping Windows UI source unchanged.
.include "win/ui.s"
.globl ui_test_count, ui_test_ring, ui_snapshot_probe, ui_seek_probe
.globl ui_test_start_index, ui_test_start_ms, ui_test_shown_index, ui_test_shown_frames
.globl ui_chapter_probe
.set ui_chapter_probe, ui_chapter
.set ui_test_count, ui_heard_count
.set ui_test_ring, ui_ring
.set ui_test_start_index, ui_start_index
.set ui_test_start_ms, ui_start_ms
.set ui_test_shown_index, ui_shown_index
.set ui_test_shown_frames, ui_shown_frames
.text
FN ui_snapshot_probe
    sub rsp, 40
    mov [rsp + 32], rdx
    test ecx, ecx
    jnz .Lsnapshot_take
    call ui_heard
    jmp .Lsnapshot_result
.Lsnapshot_take:
    call ui_heard_take
.Lsnapshot_result:
    mov rcx, [rsp + 32]
    mov [rcx], rdx
    add rsp, 40
    ret
ENDFN ui_snapshot_probe
FN ui_seek_probe
    sub rsp, 40
    mov rax, rdx
    call ui_seek
    add rsp, 40
    ret
ENDFN ui_seek_probe
