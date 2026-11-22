# Test-only exports from the unchanged shipping UI implementation.
.include "win/ui.s"
.globl ui_output_menu_probe, ui_output_command_probe, ui_output_capture_probe
.globl ui_output_apply_probe, ui_output_error_probe, ui_menu_command_probe
.globl ui_device_apply_probe, ui_worker_capture_probe, ui_reopen_at_probe
.globl ui_test_output_exclusive, ui_test_output_rate, ui_test_worker_exclusive, ui_test_worker_rate
.globl ui_test_output_error, ui_test_start_index, ui_test_start_ms, ui_test_restart
.globl ui_test_chapter_pending, ui_test_track_pending, ui_test_worker_chapter, ui_test_worker_track
.globl ui_test_worker_ms, ui_test_worker_index, ui_test_heard_count
.globl ui_test_device_pending, ui_test_device_choice, ui_test_paths
.globl ui_window_proc_probe, ui_test_instance, ui_test_hwnd, ui_tracks_reset_probe
.set ui_output_menu_probe, ui_output_settings_menu
.set ui_output_command_probe, ui_output_settings_command
.set ui_output_capture_probe, ui_output_capture
.set ui_output_apply_probe, ui_output_worker_apply
.set ui_output_error_probe, ui_output_note_error
.set ui_menu_command_probe, ui_menu_command
.set ui_device_apply_probe, ui_device_apply
.set ui_worker_capture_probe, ui_worker_capture
.set ui_reopen_at_probe, ui_reopen_at
.set ui_test_output_exclusive, ui_output_exclusive
.set ui_test_output_rate, ui_output_rate
.set ui_test_worker_exclusive, ui_worker_exclusive
.set ui_test_worker_rate, ui_worker_rate
.set ui_test_output_error, ui_output_error
.set ui_test_start_index, ui_start_index
.set ui_test_start_ms, ui_start_ms
.set ui_test_restart, ui_restart
.set ui_test_chapter_pending, ui_chapter_pending
.set ui_test_track_pending, ui_track_pending
.set ui_test_worker_chapter, ui_worker_chapter
.set ui_test_worker_track, ui_worker_track
.set ui_test_worker_ms, ui_worker_ms
.set ui_test_worker_index, ui_worker_index
.set ui_test_heard_count, ui_heard_count
.set ui_test_device_pending, ui_device_pending
.set ui_test_device_choice, ui_device_choice
.set ui_test_paths, ui_paths
.set ui_window_proc_probe, ui_window_proc
.set ui_test_instance, ui_instance
.set ui_test_hwnd, ui_hwnd
.set ui_tracks_reset_probe, ui_tracks_reset
.text
FN ui_error_title_probe
    sub rsp, 40
    call ui_output_error_title
    mov rax, rcx
    add rsp, 40
    ret
ENDFN ui_error_title_probe
FN ui_error_detail_probe
    sub rsp, 40
    call ui_output_error_detail
    mov rax, rcx
    add rsp, 40
    ret
ENDFN ui_error_detail_probe
