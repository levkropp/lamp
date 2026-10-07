# Original Windows audio-track controls. MIT, see LICENSE.
# A bounded, per-list-entry choice applies before each decoder open. The
# decoder-owning worker validates a switch and retains the previous choice
# if it cannot open. No file parsing runs on the window thread.
.equ UI_TRACK_FILES, 65536           # playlist_expand's maximum expanded list
.equ UI_TRACK_MENU_MAX, 64
.equ ID_AUTO_TRACK, 400
.equ ID_AUDIO_TRACK, 401             # Track 1, ..., Track 64

.data
ui_track_pending: .long -1          # index to validate once the previous worker has stopped
ui_track_pending_choice: .long 0
ui_worker_track: .long -1
ui_worker_track_choice: .long 0
ui_track_error_index: .long -1      # UI-owned; failed switch kept the preceding choice
ui_menu_track_index: .long -1       # file named by the currently open menu, -1 outside it
.p2align 3
ui_list_generation: .quad 0
ui_menu_track_generation: .quad 0   # replacing the list invalidates a held track menu
ui_menu_tracks: .short '&','A','u','d','i','o',' ','t','r','a','c','k',0
ui_menu_auto_track: .short 'A','u','t','o','m','a','t','i','c',0
ui_menu_tracks_loading: .short 'A','u','d','i','o',' ','t','r','a','c','k','s',' ','u','n','a','v','a','i','l','a','b','l','e',0
ui_menu_tracks_limit: .short 'F','i','r','s','t',' ','6','4',' ','t','r','a','c','k','s',' ','s','h','o','w','n',0
ui_track_unavailable: .short 'T','R','A','C','K',' ','U','N','A','V','A','I','L','A','B','L','E',0
.bss
.p2align 3
ui_track_choices: .zero UI_TRACK_FILES*4
ui_track_catalog: .zero UI_TRACK_FILES*8   # aligned atomic pair: count (low), selected ordinal (high)
ui_menu_track_label: .zero 32*2

.text
# UI thread, immediately before CreateThread and after the preceding worker
# joined. Only these snapshots are read or adjusted by the playback worker;
# UI commands can stage a replacement without changing a running request.
LOCALFN ui_worker_capture
    mov eax, [rip + ui_start_index]
    mov [rip + ui_worker_index], eax
    mov rax, [rip + ui_start_ms]
    mov [rip + ui_worker_ms], rax
    xor eax, eax
    xchg eax, [rip + ui_chapter_pending]
    mov [rip + ui_worker_chapter], eax
    mov eax, -1
    xchg eax, [rip + ui_track_pending]
    mov [rip + ui_worker_track], eax
    mov eax, [rip + ui_track_pending_choice]
    mov [rip + ui_worker_track_choice], eax
    ret
ENDFN ui_worker_capture

LOCALFN ui_tracks_reset
    push rdi
    inc qword ptr [rip + ui_list_generation]
    lea rdi, [rip + ui_track_choices]
    mov ecx, UI_TRACK_FILES*12/8
    xor eax, eax
    rep stosq
    mov dword ptr [rip + ui_track_pending], -1
    mov dword ptr [rip + ui_track_error_index], -1
    pop rdi
    ret
ENDFN ui_tracks_reset

# Producer hook: only validated file opens publish a pair. Each list entry
# retains this small catalog even when the 64 rich metadata snapshots expire.
LOCALFN ui_track_opened
    mov edx, [rip + queue_index]
    cmp edx, UI_TRACK_FILES
    jae .Lui_track_opened_done
    mov eax, [rip + audio_track_selected]
    shl rax, 32
    mov ecx, [rip + audio_tracks_count]
    or rax, rcx
    lea rcx, [rip + ui_track_catalog]
    mov [rcx + rdx*8], rax
.Lui_track_opened_done:
    ret
ENDFN ui_track_opened

# queue callback; choices remain immutable until the producer has stopped.
LOCALFN ui_track_for_file
    xor eax, eax
    cmp ecx, UI_TRACK_FILES
    jae .Lui_track_choice_done
    lea rdx, [rip + ui_track_choices]
    mov eax, [rdx + rcx*4]
.Lui_track_choice_done:
    ret
ENDFN ui_track_for_file

# ECX=ordinal, 0 automatic. Capture one heard index/position, keep pause,
# and defer changing its preference until the old decoder owner has stopped.
LOCALFN ui_choose_track
    push rbx
    sub rsp, 32
    mov ebx, ecx
    cmp ecx, UI_TRACK_MENU_MAX
    ja .Lui_choose_track_done
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_choose_track_done
    cmp dword ptr [rip + engine_ready], 0
    je .Lui_choose_track_done
    call ui_heard_position
    test eax, eax
    js .Lui_choose_track_done
    cmp eax, [rip + ui_count]
    jae .Lui_choose_track_done
    cmp eax, UI_TRACK_FILES
    jae .Lui_choose_track_done
    cmp dword ptr [rip + ui_menu_track_index], -1
    je .Lui_choose_track_paired
    mov rcx, [rip + ui_list_generation]
    cmp rcx, [rip + ui_menu_track_generation]
    jne .Lui_choose_track_done
    cmp eax, [rip + ui_menu_track_index]
    jne .Lui_choose_track_done            # playback crossed a file boundary while its menu was open
.Lui_choose_track_paired:
    lea rcx, [rip + ui_track_catalog]
    mov rcx, [rcx + rax*8]
    test ecx, ecx
    jz .Lui_choose_track_done
    cmp ebx, ecx
    ja .Lui_choose_track_done
    lea rcx, [rip + ui_track_choices]
    cmp [rcx + rax*4], ebx
    je .Lui_choose_track_done
    mov [rip + ui_track_pending], eax
    mov [rip + ui_start_index], eax
    mov [rip + ui_start_ms], rdx
    mov [rip + ui_track_pending_choice], ebx
    mov dword ptr [rip + ui_track_error_index], -1
    mov dword ptr [rip + ui_chapter_pending], 0
    call ui_request
.Lui_choose_track_done:
    add rsp, 32
    pop rbx
    ret
ENDFN ui_choose_track

# Playback worker: preflight a requested choice. An unsupported track must
# retain the heard file, position and old preference instead of skipping it.
LOCALFN ui_track_apply_pending
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, -1
    xchg ebx, [rip + ui_worker_track]
    cmp ebx, [rip + ui_worker_index]
    jne .Lui_track_apply_done
    cmp ebx, [rip + ui_count]
    jae .Lui_track_apply_done
    cmp ebx, UI_TRACK_FILES
    jae .Lui_track_apply_done
    lea rdi, [rip + ui_track_choices]
    mov esi, [rdi + rbx*4]
    mov eax, [rip + ui_worker_track_choice]
    mov [rdi + rbx*4], eax
    mov ecx, ebx
    call queue_select_track
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rbx*8]
    call decoder_open
    test eax, eax
    jz .Lui_track_apply_reject
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Lui_track_apply_cancel
    # Tracks may end at different times. Keep the old time where possible,
    # otherwise start in the last representable millisecond of the new one.
    mov rax, [rip + output_frames]
    test rax, rax
    jz .Lui_track_apply_close
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + output_rate]
    test ecx, ecx
    jz .Lui_track_apply_close
    cmp rdx, rcx
    jae .Lui_track_apply_close
    div rcx
    test rax, rax
    jnz .Lui_track_apply_duration
    mov eax, 1
.Lui_track_apply_duration:
    cmp [rip + ui_worker_ms], rax
    jb .Lui_track_apply_close
    dec rax
    mov [rip + ui_worker_ms], rax
    jmp .Lui_track_apply_close
.Lui_track_apply_reject:
    mov [rdi + rbx*4], esi
    cmp dword ptr [rip + engine_stop_requested], 0
    jne .Lui_track_apply_close          # cancellation superseded the request
    mov rcx, [rip + ui_hwnd]
    mov edx, WM_TRACK_REJECTED
    mov r8d, ebx
    xor r9d, r9d
    call PostMessageW
    jmp .Lui_track_apply_close
.Lui_track_apply_cancel:
    mov [rdi + rbx*4], esi
.Lui_track_apply_close:
    call decoder_close
.Lui_track_apply_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_track_apply_pending

# RCX=top-level menu: Audio track submenu of the heard file. Menu item
# numbers match --track; language/title/codec labels are future work.
LOCALFN ui_tracks_menu
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov dword ptr [rip + ui_menu_track_index], -1
    cmp dword ptr [rip + engine_ready], 0
    je .Lui_tracks_menu_unknown
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_tracks_menu_unknown
    call ui_heard_position
    test eax, eax
    js .Lui_tracks_menu_unknown
    cmp eax, [rip + ui_count]
    jae .Lui_tracks_menu_unknown
    cmp eax, UI_TRACK_FILES
    jae .Lui_tracks_menu_unknown
    mov [rip + ui_menu_track_index], eax
    mov rcx, [rip + ui_list_generation]
    mov [rip + ui_menu_track_generation], rcx
    lea rcx, [rip + ui_track_catalog]
    mov r12, [rcx + rax*8]
    test r12d, r12d
    jz .Lui_tracks_menu_unknown
    lea rcx, [rip + ui_track_choices]
    mov r13d, [rcx + rax*4]
    call CreatePopupMenu
    test rax, rax
    jz .Lui_tracks_menu_done
    mov rsi, rax
    xor edx, edx
    test r13d, r13d
    jnz .Lui_tracks_menu_auto
    mov edx, 8
.Lui_tracks_menu_auto:
    mov rcx, rsi
    mov r8d, ID_AUTO_TRACK
    lea r9, [rip + ui_menu_auto_track]
    call AppendMenuW
    mov edi, 1
.Lui_tracks_menu_next:
    cmp edi, r12d
    ja .Lui_tracks_menu_limit
    cmp edi, UI_TRACK_MENU_MAX
    ja .Lui_tracks_menu_limit
    lea rcx, [rip + ui_menu_track_label]
    mov dword ptr [rcx], 0x00720054       # Tr
    mov dword ptr [rcx + 4], 0x00630061   # ac
    mov dword ptr [rcx + 8], 0x0020006b   # k<space>
    add rcx, 12
    mov eax, edi
    call ui_number
    mov word ptr [rcx], 0
    xor edx, edx
    cmp edi, r13d
    jne .Lui_tracks_menu_item
    mov edx, 8
.Lui_tracks_menu_item:
    mov rcx, rsi
    lea r8d, [rdi + ID_AUDIO_TRACK - 1]
    lea r9, [rip + ui_menu_track_label]
    call AppendMenuW
    inc edi
    jmp .Lui_tracks_menu_next
.Lui_tracks_menu_limit:
    cmp r12d, UI_TRACK_MENU_MAX
    jbe .Lui_tracks_menu_attach
    mov rcx, rsi
    mov edx, 1
    xor r8d, r8d
    lea r9, [rip + ui_menu_tracks_limit]
    call AppendMenuW
.Lui_tracks_menu_attach:
    mov rcx, rbx
    mov edx, 0x10
    mov r8, rsi
    lea r9, [rip + ui_menu_tracks]
    call AppendMenuW
    jmp .Lui_tracks_menu_done
.Lui_tracks_menu_unknown:
    mov rcx, rbx
    mov edx, 1
    xor r8d, r8d
    lea r9, [rip + ui_menu_tracks_loading]
    call AppendMenuW
.Lui_tracks_menu_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_tracks_menu
