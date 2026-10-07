# Test-only aliases; include the shipping UI source unchanged.
.include "win/ui.s"
.globl view_text, view_find, view_choose, view_toggle, view_clear, view_reload, view_sync
.set view_text, ui_view_text
.set view_find, ui_view_find
.set view_choose, ui_view_choose
.set view_toggle, ui_view_toggle
.set view_clear, ui_view_clear
.set view_reload, ui_view_reload
.set view_sync, ui_view_sync
.globl view_paths, view_generation, view_list_generation, view_list_new, view_closing
.set view_paths, ui_paths
.set view_generation, ui_view_generation
.set view_list_generation, ui_list_generation
.set view_list_new, ui_list_new
.set view_closing, ui_closing
.globl view_index, view_state, view_start_index, view_start_ms, view_shown_index
.set view_index, ui_view_index
.set view_state, ui_view_state
.set view_start_index, ui_start_index
.set view_start_ms, ui_start_ms
.set view_shown_index, ui_shown_index
.globl view_hwnd, view_list, view_instance, view_track_choices
.set view_hwnd, ui_view_hwnd
.set view_list, ui_view_list
.set view_instance, ui_instance
.set view_track_choices, ui_track_choices

.globl view_key
.set view_key, ui_view_key

.globl view_main_window
.set view_main_window, ui_hwnd
