# Test-only exports; compiles the shipping Windows UI source unchanged.
.include "win/ui.s"
.globl ui_test_count, ui_test_ring, ui_snapshot_probe, ui_seek_probe
.globl ui_test_start_index, ui_test_start_ms, ui_test_shown_index, ui_test_shown_frames
.globl ui_chapter_probe
.set ui_chapter_probe, ui_chapter
.globl ui_tracks_menu_probe, ui_choose_track_probe, ui_track_apply_probe, ui_track_for_file_probe
.globl ui_tracks_reset_probe, ui_track_opened_probe
.globl ui_test_track_choices, ui_test_track_catalog, ui_test_track_pending, ui_test_track_menu_index
.globl ui_test_paths, ui_test_restart
.globl ui_worker_capture_probe, ui_test_worker_ms, ui_test_worker_index, ui_test_worker_track
.globl ui_test_worker_chapter, ui_test_chapter_pending
.set ui_worker_capture_probe, ui_worker_capture
.set ui_test_worker_ms, ui_worker_ms
.set ui_test_worker_index, ui_worker_index
.set ui_test_worker_track, ui_worker_track
.set ui_test_worker_chapter, ui_worker_chapter
.set ui_test_chapter_pending, ui_chapter_pending
.set ui_tracks_menu_probe, ui_tracks_menu
.set ui_choose_track_probe, ui_choose_track
.set ui_track_apply_probe, ui_track_apply_pending
.set ui_track_for_file_probe, ui_track_for_file
.set ui_tracks_reset_probe, ui_tracks_reset
.set ui_track_opened_probe, ui_track_opened
.set ui_test_track_choices, ui_track_choices
.set ui_test_track_catalog, ui_track_catalog
.set ui_test_track_pending, ui_track_pending
.set ui_test_track_menu_index, ui_menu_track_index
.set ui_test_paths, ui_paths
.set ui_test_restart, ui_restart
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
