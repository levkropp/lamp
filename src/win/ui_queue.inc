# The Windows player's list, included by src/win/ui.s. MIT, see LICENSE.
# Files dropped, opened or named on the command line form a list that plays
# as one gapless queue (engine_play_list); M3U and PLS playlists in it expand
# to their entries, and folders add their audio files, and those of their
# folders, in natural order (as Explorer sorts). As each file of the queue
# opens, the playback or producer thread notes where it starts in the
# output, its length, codec, title and picture in a ring (ui_file_opened);
# the window shows the entry of the file being heard, since files open ahead
# of it.
.globl ui_list_pending, ui_dialog_text
.equ UI_LIST_MAX, 32768             # files in a list
.equ UI_LIST_UNITS, 1 << 21         # their path characters
.equ UI_SCAN_MAX, 32768             # folder entries being sorted
.equ UI_SCAN_UNITS, 1 << 20         # their names, and the folders being read
.equ UI_FOLDER_DEPTH, 8             # folders within a dropped folder
.equ UI_PATH_UNITS, 32768           # a path
.equ UI_RING, 64                    # files opened, the one heard among them
.equ UI_TITLE_UNITS, 1040
.equ UI_CHAPTERS_MAX, 1024
.equ LIST_PATHS, 0                  # a list: path pointers,
.equ LIST_TEXT, 8                   # their characters,
.equ LIST_COUNT, 16                 # the files
.equ LIST_USED, 20                  # and characters used
.equ LIST_SIZE, 24
.equ UE_START, 0                    # ring entry: the output frame where the file starts,
.equ UE_FRAMES, 8                   # its frames at the session rate (0 unknown),
.equ UE_COVER, 16                   # its picture (as ui_cover_copy makes it) until the window takes it,
.equ UE_INDEX, 24                   # its index in the list,
.equ UE_CODEC, 28                   # codec_kind
.equ UE_CHAPTER_COUNT, 32           # heard-file chapter snapshot (no borrowed metadata)
.equ UE_TITLE, 40                   # and title: "Artist - Title", or the file name
.equ UE_CHAPTERS, UE_TITLE + UI_TITLE_UNITS*2
.equ UE_SIZE, UE_CHAPTERS + UI_CHAPTERS_MAX*8

.data
.p2align 3
ui_list_pending: .quad ui_list_a     # filled by a drop, the dialog or the command line
ui_list_current: .quad ui_list_b     # the list playing, as given
ui_paths: .quad 0                    # the list playing, playlists expanded
ui_start_ms: .quad 0                 # where the next launch starts in its file
ui_shown_start: .quad 0              # the file shown: its start in the output,
ui_shown_frames: .quad 0             # its length,
ui_shown_codec: .long 0              # codec,
ui_shown_index: .long 0              # and index
ui_shown: .quad -1                   # the ring entry shown (its number since the launch)
ui_count: .long 0
ui_list_new: .long 0                 # 1: the pending list plays at the next launch
ui_start_index: .long 0
ui_chapter_pending: .long 0         # worker resolves chapters after snapshot eviction
ui_worker_index: .long 0           # launch snapshot, immutable until that worker has stopped
ui_worker_chapter: .long 0
.p2align 3
ui_worker_ms: .quad 0
.p2align 3
ui_heard_count: .quad 0              # ring entries written since the launch
.p2align 3
ui_ring_lock: .quad 0               # SRWLOCK_INIT; only bounded snapshot copies under it
ui_scan_paths: .quad 0
ui_scan_text: .quad 0
ui_scan_count: .long 0
ui_scan_used: .long 0
ui_list_a: .quad 0, 0, 0
ui_list_b: .quad 0, 0, 0
ui_find_all: .short '*', 0
ui_title_tail: .short ' ', '-', ' ', 'L', 'A', 'M', 'P', 0
# Extensions of the audio files a folder adds (the open dialog's types,
# without playlists).
ui_audio_types: .asciz "wav", "aif", "aiff", "aifc", "flac", "mp3", "ogg", "opus", "oga", "mp2", "mp1", "mpa"
    .asciz "mka", "mkv", "webm", "m4a", "m4b", "mp4", "mov", "aac", "loas", "latm", "ac3", "eac3", "ec3", "wv", "ape", "caf", "w64", "avi", "flv"
    .asciz "au", "snd", "gsm", "ts", "m2ts", "mts", "mpg", "mpeg", "vob"
    .byte 0
.bss
.p2align 3
ui_ring: .zero UI_RING*UE_SIZE
ui_open_entry: .zero UE_SIZE        # producer prepares metadata before taking the lock
ui_heard_copy: .zero UE_SIZE        # UI-owned snapshot, never borrowed from the producer
ui_shown_title: .zero UI_TITLE_UNITS*2
ui_window_text: .zero (UI_TITLE_UNITS + 16)*2
ui_join_text: .zero UI_PATH_UNITS*2
ui_drop_text: .zero UI_PATH_UNITS*2
ui_dialog_text: .zero 65536*2

.text
# Engine hook as each file of the queue opens, on the playback thread (the
# first) or the producer thread (later ones): notes it in the ring and tells
# the window.
FN ui_file_opened
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    lea rbx, [rip + ui_open_entry]
    mov rax, [rip + queue_output]
    mov [rbx + UE_START], rax
    mov eax, [rip + queue_index]
    mov [rbx + UE_INDEX], eax
    mov eax, [rip + codec_kind]
    mov [rbx + UE_CODEC], eax
    call queue_frames                   # ceil at the session rate, including one-frame files
    mov [rbx + UE_FRAMES], rax
    call chapters_count
    mov [rbx + UE_CHAPTER_COUNT], eax
    xor esi, esi
.Lui_opened_chapters:
    cmp esi, [rbx + UE_CHAPTER_COUNT]
    jae .Lui_opened_title
    mov ecx, esi
    call chapters_get
    mov [rbx + rsi*8 + UE_CHAPTERS], rax
    inc esi
    jmp .Lui_opened_chapters
.Lui_opened_title:
    lea rcx, [rbx + UE_TITLE]
    call ui_tag_title
    test rax, rax
    jnz .Lui_opened_cover
    mov eax, [rip + queue_index]          # untagged: the file name
    mov rcx, [rip + queue_paths]
    mov rcx, [rcx + rax*8]
    call ui_basename
    mov rsi, rax
    lea rdi, [rbx + UE_TITLE]
    mov ecx, UI_TITLE_UNITS - 1
.Lui_opened_name:
    movzx eax, word ptr [rsi]
    test eax, eax
    jz .Lui_opened_named
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    dec ecx
    jnz .Lui_opened_name
.Lui_opened_named:
    mov word ptr [rdi], 0
.Lui_opened_cover:
    call ui_track_opened                # publish this file's small ordinal catalog separately
    call ui_cover_copy
    mov [rbx + UE_COVER], rax
    lea rcx, [rip + ui_ring_lock]
    call AcquireSRWLockExclusive
    mov eax, [rip + ui_heard_count]
    and eax, UI_RING - 1
    imul eax, eax, UE_SIZE
    lea rdi, [rip + ui_ring]
    add rdi, rax
    xor r12d, r12d
    xchg r12, [rdi + UE_COVER]          # previously unclaimed cover; free after unlocking
    mov rsi, rbx
    mov ecx, UE_SIZE/8
    rep movsq
    inc qword ptr [rip + ui_heard_count]  # published once written
    lea rcx, [rip + ui_ring_lock]
    call ReleaseSRWLockExclusive
    mov rcx, r12
    call mem_free
    mov rcx, [rip + ui_hwnd]
    test rcx, rcx
    jz .Lui_opened_return
    mov edx, WM_FILE_OPENED
    xor r8d, r8d
    xor r9d, r9d
    call PostMessageW
.Lui_opened_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_file_opened

# RCX=wide path -> RAX=its last component.
LOCALFN ui_basename
    mov rax, rcx
.Lui_basename_char:
    movzx edx, word ptr [rcx]
    test edx, edx
    jz .Lui_basename_done
    add rcx, 2
    cmp edx, 0x5c
    je .Lui_basename_after
    cmp edx, 0x2f
    jne .Lui_basename_char
.Lui_basename_after:
    mov rax, rcx
    jmp .Lui_basename_char
.Lui_basename_done:
    ret
ENDFN ui_basename

# -> RAX=UI-owned copy of the heard entry, 0 if unavailable; RDX=its number,
# R9=the paired position. No caller borrows a ring entry across publication.
LOCALFN ui_heard
    xor ecx, ecx
    jmp ui_heard_snapshot
ENDFN ui_heard

# As ui_heard, additionally transfers the selected cover to the UI copy.
LOCALFN ui_heard_take
    mov ecx, 1
    jmp ui_heard_snapshot
ENDFN ui_heard_take

LOCALFN ui_heard_snapshot
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov ebx, ecx
    lea rcx, [rip + ui_ring_lock]
    call AcquireSRWLockExclusive
    mov r9, [rip + engine_position]
    mov [rsp + 48], r9
    mov rdx, [rip + ui_heard_count]
    test rdx, rdx
    jz .Lui_heard_none
    mov r8, rdx
    sub r8, UI_RING
    jae .Lui_heard_oldest
    xor r8d, r8d
.Lui_heard_oldest:
    lea r10, [rip + ui_ring]
.Lui_heard_entry:
    dec rdx
    mov eax, edx
    and eax, UI_RING - 1
    imul eax, eax, UE_SIZE
    add rax, r10
    cmp [rax + UE_START], r9
    jbe .Lui_heard_found
    cmp rdx, r8
    ja .Lui_heard_entry
    jmp .Lui_heard_none                 # oldest snapshot is still in the future
.Lui_heard_found:
    mov [rsp + 40], rdx
    mov rsi, rax
    xor r12d, r12d
    test ebx, ebx
    jz .Lui_heard_copy
    xchg r12, [rsi + UE_COVER]
.Lui_heard_copy:
    lea rdi, [rip + ui_heard_copy]
    mov ecx, UE_SIZE/8
    rep movsq
    mov [rip + ui_heard_copy + UE_COVER], r12
    lea rcx, [rip + ui_ring_lock]
    call ReleaseSRWLockExclusive
    lea rax, [rip + ui_heard_copy]
    mov rdx, [rsp + 40]
    jmp .Lui_heard_return
.Lui_heard_none:
    lea rcx, [rip + ui_ring_lock]
    call ReleaseSRWLockExclusive
    xor eax, eax
    xor edx, edx
.Lui_heard_return:
    mov r9, [rsp + 48]
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_heard_snapshot

# UI thread: when the file heard changes, shows its title, codec and length,
# takes its picture and titles the window after it.
LOCALFN ui_heard_update
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    call ui_heard_take
    test rax, rax
    jz .Lui_update_fallback
    cmp rdx, [rip + ui_shown]
    je .Lui_update_return
    mov [rip + ui_shown], rdx
    mov rbx, rax
    mov rax, [rbx + UE_START]
    mov [rip + ui_shown_start], rax
    mov rax, [rbx + UE_FRAMES]
    mov [rip + ui_shown_frames], rax
    mov eax, [rbx + UE_CODEC]
    mov [rip + ui_shown_codec], eax
    mov eax, [rbx + UE_INDEX]
    mov [rip + ui_shown_index], eax
    lea rsi, [rbx + UE_TITLE]
    lea rdi, [rip + ui_shown_title]
    mov ecx, UI_TITLE_UNITS
    rep movsw
    xor eax, eax
    xchg rax, [rbx + UE_COVER]
    test rax, rax
    jz .Lui_update_title
    xchg [rip + ui_cover_pending], rax
    mov rcx, rax                          # one not shown yet
    call mem_free
.Lui_update_title:
    call ui_window_title
    jmp .Lui_update_return
.Lui_update_fallback:
    cmp qword ptr [rip + ui_heard_count], 0
    je .Lui_update_return               # opening/restarting: no published file yet
    mov rcx, r9
    call queue_heard
    test eax, eax
    js .Lui_update_return
    cmp eax, [rip + ui_count]
    jae .Lui_update_return
    cmp qword ptr [rip + ui_shown], -2
    jne .Lui_update_filename
    cmp eax, [rip + ui_shown_index]
    jne .Lui_update_filename
    cmp rdx, [rip + ui_shown_start]
    je .Lui_update_return
.Lui_update_filename:
    mov qword ptr [rip + ui_shown], -2   # filename without a retained metadata snapshot
    mov [rip + ui_shown_index], eax
    mov [rip + ui_shown_start], rdx
    mov qword ptr [rip + ui_shown_frames], 0
    mov dword ptr [rip + ui_shown_codec], 0
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rax*8]
    call ui_basename
    mov [rip + ui_filename], rax
    mov rsi, rax
    lea rdi, [rip + ui_shown_title]
    mov ecx, UI_TITLE_UNITS - 1
.Lui_update_filename_char:
    lodsw
    stosw
    test ax, ax
    jz .Lui_update_clear_cover
    loop .Lui_update_filename_char
    mov word ptr [rdi], 0
.Lui_update_clear_cover:
    call ui_cover_release
    lea rcx, [rip + ui_cover_pending]
    call ui_cover_free
    jmp .Lui_update_title
.Lui_update_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_heard_update

# The window's title: "<the file shown> - LAMP".
LOCALFN ui_window_title
    push rsi
    push rdi
    sub rsp, 40
    cmp qword ptr [rip + ui_hwnd], 0
    je .Lui_window_title_return
    lea rsi, [rip + ui_shown_title]
    lea rdi, [rip + ui_window_text]
.Lui_window_title_char:
    movzx eax, word ptr [rsi]
    test eax, eax
    jz .Lui_window_title_tail
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    jmp .Lui_window_title_char
.Lui_window_title_tail:
    lea rsi, [rip + ui_title_tail]
.Lui_window_title_tail_char:
    movzx eax, word ptr [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    test eax, eax
    jnz .Lui_window_title_tail_char
    mov rcx, [rip + ui_hwnd]
    lea rdx, [rip + ui_window_text]
    call SetWindowTextW
.Lui_window_title_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN ui_window_title

# UI thread: arms timer 2 for when the next file opened ahead starts being
# heard, so the title and picture change then while the controls are hidden.
LOCALFN ui_schedule
    sub rsp, 40
    mov rcx, [rip + ui_hwnd]
    mov edx, 2
    call KillTimer
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_schedule_return
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_schedule_return              # resuming schedules again
    lea rcx, [rip + ui_ring_lock]
    call AcquireSRWLockExclusive
    mov rdx, [rip + ui_heard_count]
    mov r8, rdx
    sub r8, UI_RING
    jae .Lui_schedule_oldest
    xor r8d, r8d
.Lui_schedule_oldest:
    mov r9, [rip + engine_position]
    lea r10, [rip + ui_ring]
    cmp rdx, UI_RING
    jbe .Lui_schedule_entry
    mov eax, r8d
    and eax, UI_RING - 1
    imul eax, eax, UE_SIZE
    cmp [r10 + rax + UE_START], r9
    jbe .Lui_schedule_entry
    xor eax, eax                       # metadata evicted: check the shared timeline in 20 ms
    jmp .Lui_schedule_arm
.Lui_schedule_entry:
    cmp r8, rdx
    jae .Lui_schedule_unlock_return       # none ahead
    mov eax, r8d
    and eax, UI_RING - 1
    imul eax, eax, UE_SIZE
    mov rax, [r10 + rax + UE_START]
    inc r8
    sub rax, r9
    jbe .Lui_schedule_entry               # already heard
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Lui_schedule_unlock_return
    div rcx
    cmp rax, 60000
    jbe .Lui_schedule_arm
    mov eax, 60000                        # checked again then
.Lui_schedule_arm:
    mov [rsp + 32], eax
    lea rcx, [rip + ui_ring_lock]
    call ReleaseSRWLockExclusive
    mov eax, [rsp + 32]
    lea r8d, [rax + 20]
    mov rcx, [rip + ui_hwnd]
    mov edx, 2
    xor r9d, r9d
    call SetTimer
    jmp .Lui_schedule_return
.Lui_schedule_unlock_return:
    lea rcx, [rip + ui_ring_lock]
    call ReleaseSRWLockExclusive
.Lui_schedule_return:
    add rsp, 40
    ret
ENDFN ui_schedule

# -> EAX=index of the file heard, RDX=milliseconds into it (where a pending
# launch starts, when one is pending or no file opened yet).
LOCALFN ui_heard_position
    sub rsp, 40
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_position_start
    call ui_heard
    test rax, rax
    jz .Lui_position_fallback
    mov r8, rax
    mov rax, r9                        # position paired with the selected snapshot
    sub rax, [r8 + UE_START]
    mov r8d, [r8 + UE_INDEX]
    jmp .Lui_position_delta
.Lui_position_fallback:
    cmp qword ptr [rip + ui_heard_count], 0
    je .Lui_position_start
    mov [rsp + 32], r9
    mov rcx, r9
    call queue_heard
    mov r8d, eax
    test eax, eax
    js .Lui_position_unknown
    mov rax, [rsp + 32]
    sub rax, rdx
.Lui_position_delta:
    jae .Lui_position_offset
    xor eax, eax
.Lui_position_offset:
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    xor edx, edx
    test ecx, ecx
    jz .Lui_position_found
    div rcx
    mov rdx, rax
.Lui_position_found:
    mov eax, r8d
    jmp .Lui_position_return
.Lui_position_unknown:
    mov eax, -1
    xor edx, edx
    jmp .Lui_position_return
.Lui_position_start:
    mov eax, [rip + ui_start_index]
    mov rdx, [rip + ui_start_ms]
.Lui_position_return:
    add rsp, 40
    ret
ENDFN ui_heard_position

# ECX=index, RDX=milliseconds: plays the list from there.
LOCALFN ui_play_at
    test ecx, ecx
    js .Lui_play_at_unknown
    mov dword ptr [rip + ui_chapter_pending], 0
    mov dword ptr [rip + ui_track_pending], -1
    mov dword ptr [rip + ui_track_error_index], -1
    mov [rip + ui_start_index], ecx
    mov [rip + ui_start_ms], rdx
    mov dword ptr [rip + pause_requested], 0
    jmp ui_request
.Lui_play_at_unknown:
    ret
ENDFN ui_play_at

# N: the file after the one heard (the first again with repeat).
LOCALFN ui_next
    sub rsp, 40
    cmp dword ptr [rip + ui_count], 0
    je .Lui_next_return
    call ui_heard_position
    test eax, eax
    js .Lui_next_return
    inc eax
    cmp eax, [rip + ui_count]
    jb .Lui_next_play
    cmp dword ptr [rip + queue_repeat], 0
    je .Lui_next_return                   # nothing after the last file
    xor eax, eax
.Lui_next_play:
    mov ecx, eax
    xor edx, edx
    call ui_play_at
.Lui_next_return:
    add rsp, 40
    ret
ENDFN ui_next

# P: the file heard from its start after 3 s of it, else the one before
# (the last with repeat).
LOCALFN ui_previous
    sub rsp, 40
    cmp dword ptr [rip + ui_count], 0
    je .Lui_previous_return
    call ui_heard_position
    test eax, eax
    js .Lui_previous_return
    cmp rdx, 3000
    ja .Lui_previous_play
    dec eax
    jns .Lui_previous_play
    xor eax, eax
    cmp dword ptr [rip + queue_repeat], 0
    je .Lui_previous_play
    mov eax, [rip + ui_count]
    dec eax
.Lui_previous_play:
    mov ecx, eax
    xor edx, edx
    call ui_play_at
.Lui_previous_return:
    add rsp, 40
    ret
ENDFN ui_previous

# ECX=6 next / 7 previous chapter. Use the heard ring entry's bounded
# snapshot, since the decoder's chapter table may already belong to the
# next file. Keep pause_requested unchanged through this seek/restart.
LOCALFN ui_chapter
    push rbx
    push rsi
    sub rsp, 56
    mov ebx, ecx
    cmp dword ptr [rip + ui_restart], 0
    jne .Lui_chapter_return
    call ui_heard
    test rax, rax
    jz .Lui_chapter_fallback
    mov rsi, rax
    mov eax, [rsi + UE_INDEX]
    mov [rsp + 40], eax
    mov rax, r9                        # position paired with this entry
    sub rax, [rsi + UE_START]
    jae .Lui_chapter_position
    xor eax, eax
.Lui_chapter_position:
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Lui_chapter_return
    mov edx, 1000
    mul rdx
    div rcx
    mov [rsp + 48], rax
    mov ecx, [rsi + UE_CHAPTER_COUNT]
    test ecx, ecx
    jz .Lui_chapter_return
    mov [rsp + 32], ecx                # fifth argument
    mov rax, [rsi + UE_FRAMES]
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    xor r8d, r8d
    test ecx, ecx
    jz .Lui_chapter_select
    cmp rdx, rcx
    jae .Lui_chapter_select
    div rcx
    mov r8, rax
    test r8, r8
    jnz .Lui_chapter_select
    cmp qword ptr [rsi + UE_FRAMES], 0
    je .Lui_chapter_select
    mov r8d, 1                        # known positive duration below one millisecond
.Lui_chapter_select:
    mov ecx, ebx
    mov rdx, [rsp + 48]
    lea r9, [rsi + UE_CHAPTERS]
    call chapter_target_from
    test edx, edx
    jz .Lui_chapter_return
    cmp rax, [rsp + 48]
    je .Lui_chapter_return
    mov [rip + ui_start_ms], rax
    mov eax, [rsp + 40]
    mov [rip + ui_start_index], eax
    mov dword ptr [rip + ui_chapter_pending], 0
    mov dword ptr [rip + ui_track_pending], -1
    call ui_request
    jmp .Lui_chapter_return
.Lui_chapter_fallback:
    cmp qword ptr [rip + ui_heard_count], 0
    je .Lui_chapter_return
    call ui_heard_position
    test eax, eax
    js .Lui_chapter_return
    mov [rip + ui_start_index], eax
    mov [rip + ui_start_ms], rdx
    mov [rip + ui_chapter_pending], ebx
    mov dword ptr [rip + ui_track_pending], -1
    call ui_request                    # keeps pause; worker owns the decoder once stopped
.Lui_chapter_return:
    add rsp, 56
    pop rsi
    pop rbx
    ret
ENDFN ui_chapter

# ECX=the paired file index, RAX=milliseconds into it. A known displayed
# duration keeps the target up to a second before its end. Never resample
# the heard index here: a short file may have ended since the key/click.
# Preserve pause through the restart, as chapter seeks do.
LOCALFN ui_seek
    sub rsp, 56
    cmp ecx, [rip + ui_count]
    jae .Lui_seek_return
    mov [rsp + 40], ecx
    test rax, rax
    jns .Lui_seek_nonnegative
    xor eax, eax
.Lui_seek_nonnegative:
    mov [rsp + 32], rax
    cmp ecx, [rip + ui_shown_index]
    jne .Lui_seek_target               # displayed length belongs to another file
    mov rax, [rip + ui_shown_frames]
    mov ecx, [rip + queue_rate]
    test rax, rax
    jz .Lui_seek_target
    test ecx, ecx
    jz .Lui_seek_target
    mov edx, 1000
    mul rdx
    div rcx
    sub rax, 1000
    jae .Lui_seek_limit
    xor eax, eax
.Lui_seek_limit:
    cmp rax, [rsp + 32]
    jae .Lui_seek_target
    mov [rsp + 32], rax
.Lui_seek_target:
    mov dword ptr [rip + ui_track_pending], -1
    mov ecx, [rsp + 40]
    mov rdx, [rsp + 32]
    mov [rip + ui_start_index], ecx
    mov [rip + ui_start_ms], rdx
    mov dword ptr [rip + ui_chapter_pending], 0
    call ui_request
.Lui_seek_return:
    add rsp, 56
    ret
ENDFN ui_seek

# Plays the list from ui_start_index at ui_start_ms, the pending list first
# replacing the one playing when ui_list_new is set. A running playback
# thread is stopped first; its end launches the new one.
LOCALFN ui_request
    sub rsp, 56
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_launch
    mov dword ptr [rip + ui_restart], 1
    call engine_stop
    jmp .Lui_request_done
.Lui_launch:
    call ui_device_apply                  # an output chosen meanwhile
    cmp dword ptr [rip + ui_list_new], 0
    je .Lui_launch_file
    mov dword ptr [rip + ui_list_new], 0
    call ui_tracks_reset
    mov rax, [rip + ui_list_pending]
    xchg rax, [rip + ui_list_current]
    mov [rip + ui_list_pending], rax
    mov rax, [rip + ui_list_current]
    mov rcx, [rax + LIST_PATHS]
    mov edx, [rax + LIST_COUNT]
    call playlist_expand                  # M3U and PLS playlists become their entries
    mov [rip + ui_paths], rax
    mov [rip + ui_count], edx
    mov dword ptr [rip + ui_shown_index], -1
.Lui_launch_file:
    mov eax, [rip + ui_start_index]
    cmp eax, [rip + ui_count]
    jae .Lui_launch_empty
    cmp eax, [rip + ui_shown_index]
    je .Lui_launch_same
    # Another file: nothing of the one shown stays while it opens.
    mov [rip + ui_shown_index], eax
    xor ecx, ecx
    mov [rip + ui_shown_codec], ecx
    mov [rip + ui_shown_frames], rcx
    mov word ptr [rip + ui_shown_title], cx
    call ui_cover_release
    lea rcx, [rip + ui_cover_pending]
    call ui_cover_free
.Lui_launch_same:
    call ui_worker_capture             # a newer UI request cannot change this worker's inputs
    mov eax, [rip + ui_start_index]
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rax*8]
    call ui_basename
    mov [rip + ui_filename], rax
    mov qword ptr [rip + ui_shown], -1
    mov qword ptr [rip + ui_heard_count], 0
    mov qword ptr [rip + ui_shown_start], 0
    mov rax, [rip + ui_start_ms]          # shown until the file opens
    mov ecx, [rip + queue_rate]
    mul rcx
    mov ecx, 1000
    div rcx
    mov [rip + engine_position], rax
    mov dword ptr [rip + ui_state], 1
    mov dword ptr [rip + ui_controls], 1
    mov dword ptr [rip + engine_stop_requested], 0
    mov dword ptr [rip + engine_ready], 0
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + ui_audio_thread]
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    mov [rip + ui_thread], rax
    test rax, rax
    jnz .Lui_timer_start
.Lui_launch_empty:
    mov dword ptr [rip + ui_state], 3
    jmp .Lui_request_done
.Lui_timer_start:
    call GetTickCount64
    mov [rip + ui_last_activity], rax
    mov rcx, [rip + ui_hwnd]
    mov edx, 1
    mov r8d, 250
    xor r9d, r9d
    call SetTimer
.Lui_request_done:
    call ui_invalidate
    add rsp, 56
    ret
ENDFN ui_request

LOCALFN ui_audio_thread
    sub rsp, 40
    lea rax, [rip + ui_track_for_file]
    mov [rip + queue_track_choice], rax
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    call ui_track_apply_pending
    mov eax, [rip + ui_worker_chapter]
    test eax, eax
    jz .Lui_audio_play
    mov [rsp + 32], eax
    mov eax, [rip + ui_worker_index]
    cmp eax, [rip + ui_count]
    jae .Lui_audio_play
    mov ecx, eax
    call queue_select_track
    mov eax, [rip + ui_worker_index]
    mov rcx, [rip + ui_paths]
    mov rcx, [rcx + rax*8]
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax      # the metadata reopen remains cancellable
    call decoder_open
    test eax, eax
    jz .Lui_audio_chapter_close
    mov ecx, [rsp + 32]
    mov rdx, [rip + ui_worker_ms]
    call queue_chapter_target
    mov [rip + ui_worker_ms], rax
.Lui_audio_chapter_close:
    call decoder_close
.Lui_audio_play:
    mov rcx, [rip + ui_paths]
    mov edx, [rip + ui_count]
    mov r8d, [rip + ui_worker_index]
    mov r9, [rip + ui_worker_ms]
    call engine_play_list
    mov rcx, [rip + ui_hwnd]
    mov edx, WM_WORKER_DONE
    mov r8d, eax
    xor r9d, r9d
    call PostMessageW
    xor eax, eax
    add rsp, 40
    ret
ENDFN ui_audio_thread

# Empties the pending list -> EAX=1 when it can be filled.
FN ui_list_begin
    push rbx
    sub rsp, 32
    mov rbx, [rip + ui_list_pending]
    xor eax, eax
    mov [rbx + LIST_COUNT], eax
    mov [rbx + LIST_USED], eax
    mov eax, 1
    cmp qword ptr [rbx + LIST_PATHS], 0
    jne .Lui_list_begin_return
    mov ecx, UI_LIST_MAX*8 + UI_LIST_UNITS*2
    call mem_alloc
    test rax, rax
    jz .Lui_list_begin_return             # EAX=0
    mov [rbx + LIST_PATHS], rax
    add rax, UI_LIST_MAX*8
    mov [rbx + LIST_TEXT], rax
    mov eax, 1
.Lui_list_begin_return:
    add rsp, 32
    pop rbx
    ret
ENDFN ui_list_begin

# The pending list plays next, from its first file, unpaused.
FN ui_list_end
    mov dword ptr [rip + ui_track_pending], -1
    mov dword ptr [rip + ui_chapter_pending], 0
    mov dword ptr [rip + ui_list_new], 1
    mov dword ptr [rip + pause_requested], 0
    xor eax, eax
    mov [rip + ui_start_index], eax
    mov [rip + ui_start_ms], rax
    ret
ENDFN ui_list_end

# RCX=wide path: appended to the pending list (left out when it is full).
LOCALFN ui_list_file
    mov r8, [rip + ui_list_pending]
    cmp qword ptr [r8 + LIST_PATHS], 0
    je .Lui_list_file_return
    xor edx, edx
.Lui_list_file_length:
    cmp word ptr [rcx + rdx*2], 0
    je .Lui_list_file_measured
    inc edx
    cmp edx, UI_PATH_UNITS
    jb .Lui_list_file_length
    ret
.Lui_list_file_measured:
    test edx, edx
    jz .Lui_list_file_return
    mov eax, [r8 + LIST_COUNT]
    cmp eax, UI_LIST_MAX
    jae .Lui_list_file_return
    mov r9d, [r8 + LIST_USED]
    lea r10d, [r9 + rdx + 1]
    cmp r10d, UI_LIST_UNITS
    ja .Lui_list_file_return
    mov [r8 + LIST_USED], r10d
    mov r10, [r8 + LIST_TEXT]
    lea r10, [r10 + r9*2]                 # its copy
    mov r11, [r8 + LIST_PATHS]
    mov [r11 + rax*8], r10
    inc eax
    mov [r8 + LIST_COUNT], eax
.Lui_list_file_copy:
    movzx eax, word ptr [rcx]
    mov [r10], ax
    add rcx, 2
    add r10, 2
    test eax, eax
    jnz .Lui_list_file_copy
.Lui_list_file_return:
    ret
ENDFN ui_list_file

# RCX=wide path, EDX=folders it is in (0 for one given): a folder adds its
# audio files, anything else is added as named.
FN ui_list_path
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov esi, edx
    call GetFileAttributesW
    cmp eax, -1
    je .Lui_list_path_file
    test eax, 0x10                        # FILE_ATTRIBUTE_DIRECTORY
    jz .Lui_list_path_file
    mov rcx, rbx
    mov edx, esi
    call ui_list_folder
    jmp .Lui_list_path_return
.Lui_list_path_file:
    mov rcx, rbx
    call ui_list_file
.Lui_list_path_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN ui_list_path

# RCX=folder, EDX=its depth: adds its audio files and, UI_FOLDER_DEPTH deep,
# its folders' (hidden and system entries aside), files and folders together
# in natural order.
LOCALFN ui_list_folder
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 640                          # WIN32_FIND_DATAW at rsp+48
    mov rbx, rcx
    mov r12d, edx
    cmp qword ptr [rip + ui_scan_text], 0
    jne .Lui_folder_scratch
    mov ecx, UI_SCAN_MAX*8 + UI_SCAN_UNITS*2
    call mem_alloc
    test rax, rax
    jz .Lui_folder_return
    mov [rip + ui_scan_paths], rax
    add rax, UI_SCAN_MAX*8
    mov [rip + ui_scan_text], rax
.Lui_folder_scratch:
    mov r13d, [rip + ui_scan_used]        # this folder's scratch, given back at the end
    mov r14d, [rip + ui_scan_count]
    mov rcx, rbx
    call ui_scan_copy                     # the folder, kept while its entries are added
    test rax, rax
    jz .Lui_folder_restore
    mov rbx, rax
    mov rcx, rbx
    lea rdx, [rip + ui_find_all]
    call ui_join
    test rax, rax
    jz .Lui_folder_restore
    mov rcx, rax
    lea rdx, [rsp + 48]
    call FindFirstFileW
    cmp rax, -1
    je .Lui_folder_restore
    mov rsi, rax
.Lui_folder_entry:
    mov edi, [rsp + 48]                   # attributes
    test edi, 6                           # hidden or system
    jnz .Lui_folder_next
    lea rcx, [rsp + 48 + 44]              # its name
    cmp word ptr [rcx], '.'
    jne .Lui_folder_named
    cmp word ptr [rcx + 2], 0
    je .Lui_folder_next                   # "."
    cmp word ptr [rcx + 2], '.'
    jne .Lui_folder_named
    cmp word ptr [rcx + 4], 0
    je .Lui_folder_next                   # ".."
.Lui_folder_named:
    and edi, 0x10
    jnz .Lui_folder_keep
    call ui_audio_name
    test eax, eax
    jz .Lui_folder_next
.Lui_folder_keep:
    lea rcx, [rsp + 48 + 44]
    mov edx, edi
    call ui_scan_entry
.Lui_folder_next:
    mov rcx, rsi
    lea rdx, [rsp + 48]
    call FindNextFileW
    test eax, eax
    jnz .Lui_folder_entry
    mov rcx, rsi
    call FindClose
    mov r15d, [rip + ui_scan_count]
    mov ecx, r14d
    mov edx, r15d
    call ui_scan_sort
    mov esi, r14d
.Lui_folder_add:
    cmp esi, r15d
    jae .Lui_folder_restore
    mov rax, [rip + ui_scan_paths]
    mov rdx, [rax + rsi*8]                # a folder flag, then the name
    movzx edi, word ptr [rdx]
    add rdx, 2
    mov rcx, rbx
    call ui_join
    test rax, rax
    jz .Lui_folder_added
    mov rcx, rax
    test edi, edi
    jnz .Lui_folder_inner
    call ui_list_file
    jmp .Lui_folder_added
.Lui_folder_inner:
    lea edx, [r12 + 1]
    cmp edx, UI_FOLDER_DEPTH
    ja .Lui_folder_added
    call ui_list_folder
.Lui_folder_added:
    inc esi
    jmp .Lui_folder_add
.Lui_folder_restore:
    mov [rip + ui_scan_used], r13d
    mov [rip + ui_scan_count], r14d
.Lui_folder_return:
    add rsp, 640
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_list_folder

# RCX=folder, RDX=name -> RAX=ui_join_text holding "folder\name", or 0 when
# it is too long.
LOCALFN ui_join
    lea r8, [rip + ui_join_text]
    xor r9d, r9d
.Lui_join_folder:
    movzx eax, word ptr [rcx]
    test eax, eax
    jz .Lui_join_separator
    mov [r8 + r9*2], ax
    add rcx, 2
    inc r9d
    cmp r9d, UI_PATH_UNITS - 2
    jb .Lui_join_folder
    jmp .Lui_join_long
.Lui_join_separator:
    test r9d, r9d
    jz .Lui_join_name
    movzx eax, word ptr [r8 + r9*2 - 2]
    cmp eax, 0x5c
    je .Lui_join_name
    cmp eax, 0x2f
    je .Lui_join_name
    mov word ptr [r8 + r9*2], 0x5c
    inc r9d
.Lui_join_name:
    movzx eax, word ptr [rdx]
    mov [r8 + r9*2], ax
    test eax, eax
    jz .Lui_join_done
    add rdx, 2
    inc r9d
    cmp r9d, UI_PATH_UNITS - 1
    jb .Lui_join_name
.Lui_join_long:
    xor eax, eax
    ret
.Lui_join_done:
    mov rax, r8
    ret
ENDFN ui_join

# RCX=wide text -> RAX=its copy in the folder scratch, or 0 when full.
LOCALFN ui_scan_copy
    xor edx, edx
.Lui_scan_copy_length:
    cmp word ptr [rcx + rdx*2], 0
    je .Lui_scan_copy_measured
    inc edx
    cmp edx, UI_PATH_UNITS
    jb .Lui_scan_copy_length
    xor eax, eax
    ret
.Lui_scan_copy_measured:
    mov r8d, [rip + ui_scan_used]
    lea r9d, [r8 + rdx + 1]
    cmp r9d, UI_SCAN_UNITS
    ja .Lui_scan_copy_full
    mov [rip + ui_scan_used], r9d
    mov rax, [rip + ui_scan_text]
    lea rax, [rax + r8*2]
    mov r8, rax
.Lui_scan_copy_char:
    movzx edx, word ptr [rcx]
    mov [r8], dx
    add rcx, 2
    add r8, 2
    test edx, edx
    jnz .Lui_scan_copy_char
    ret
.Lui_scan_copy_full:
    xor eax, eax
    ret
ENDFN ui_scan_copy

# RCX=name, EDX=nonzero for a folder: a folder entry being read.
LOCALFN ui_scan_entry
    push rbx
    sub rsp, 32
    mov ebx, edx
    cmp dword ptr [rip + ui_scan_count], UI_SCAN_MAX
    jae .Lui_scan_entry_return
    mov eax, [rip + ui_scan_used]
    inc eax                               # the flag first
    cmp eax, UI_SCAN_UNITS
    jae .Lui_scan_entry_return
    mov [rip + ui_scan_used], eax
    call ui_scan_copy
    test rax, rax
    jz .Lui_scan_entry_undo
    sub rax, 2
    mov [rax], bx
    mov ecx, [rip + ui_scan_count]
    mov rdx, [rip + ui_scan_paths]
    mov [rdx + rcx*8], rax
    inc ecx
    mov [rip + ui_scan_count], ecx
    jmp .Lui_scan_entry_return
.Lui_scan_entry_undo:
    dec dword ptr [rip + ui_scan_used]
.Lui_scan_entry_return:
    add rsp, 32
    pop rbx
    ret
ENDFN ui_scan_entry

# ECX=first entry, EDX=end: sorts those entries by name in natural order
# (StrCmpLogicalW), a Shell sort.
LOCALFN ui_scan_sort
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, [rip + ui_scan_paths]
    mov eax, ecx
    lea r12, [r12 + rax*8]
    mov r13d, edx
    sub r13d, ecx
    jbe .Lui_sort_return
    mov r14d, r13d
.Lui_sort_gap:
    shr r14d, 1
    jz .Lui_sort_return
    mov esi, r14d
.Lui_sort_item:
    cmp esi, r13d
    jae .Lui_sort_gap
    mov r15, [r12 + rsi*8]                # the entry being placed
    mov edi, esi
.Lui_sort_shift:
    cmp edi, r14d
    jb .Lui_sort_place
    mov eax, edi
    sub eax, r14d
    mov rbx, [r12 + rax*8]
    lea rcx, [rbx + 2]
    lea rdx, [r15 + 2]
    call StrCmpLogicalW
    test eax, eax
    jle .Lui_sort_place
    mov [r12 + rdi*8], rbx
    sub edi, r14d
    jmp .Lui_sort_shift
.Lui_sort_place:
    mov [r12 + rdi*8], r15
    inc esi
    jmp .Lui_sort_item
.Lui_sort_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_scan_sort

# RCX=file name -> EAX=1 when its extension is one of ui_audio_types (any
# case).
LOCALFN ui_audio_name
    xor r8d, r8d
    mov rax, rcx
.Lui_audio_char:
    movzx edx, word ptr [rax]
    test edx, edx
    jz .Lui_audio_end
    add rax, 2
    cmp edx, '.'
    jne .Lui_audio_char
    mov r8, rax                           # after the last dot
    jmp .Lui_audio_char
.Lui_audio_end:
    test r8, r8
    jz .Lui_audio_no
    lea r9, [rip + ui_audio_types]
.Lui_audio_type:
    cmp byte ptr [r9], 0
    je .Lui_audio_no
    xor r10d, r10d
.Lui_audio_compare:
    movzx eax, byte ptr [r9 + r10]
    movzx edx, word ptr [r8 + r10*2]
    lea ecx, [rdx - 'A']
    cmp ecx, 25
    ja .Lui_audio_lower
    add edx, 32
.Lui_audio_lower:
    cmp eax, edx
    jne .Lui_audio_skip
    test eax, eax
    jz .Lui_audio_yes
    inc r10d
    jmp .Lui_audio_compare
.Lui_audio_skip:
    inc r9
    cmp byte ptr [r9 - 1], 0
    jne .Lui_audio_skip
    jmp .Lui_audio_type
.Lui_audio_yes:
    mov eax, 1
    ret
.Lui_audio_no:
    xor eax, eax
    ret
ENDFN ui_audio_name

# RCX=HDROP: the dropped files and folders become the pending list.
FN ui_list_drop
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    call ui_list_begin
    test eax, eax
    jz .Lui_drop_finish
    mov rcx, rbx
    mov edx, -1
    xor r8d, r8d
    xor r9d, r9d
    call DragQueryFileW
    mov esi, eax
    xor edi, edi
.Lui_drop_file:
    cmp edi, esi
    jae .Lui_drop_listed
    mov rcx, rbx
    mov edx, edi
    lea r8, [rip + ui_drop_text]
    mov r9d, UI_PATH_UNITS
    call DragQueryFileW
    inc edi
    test eax, eax
    jz .Lui_drop_file
    lea rcx, [rip + ui_drop_text]
    xor edx, edx
    call ui_list_path
    jmp .Lui_drop_file
.Lui_drop_listed:
    call ui_list_end
.Lui_drop_finish:
    mov rcx, rbx
    call DragFinish
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_list_drop

# The open dialog's choice in ui_dialog_text (a path, or with several files
# a folder and their names, each ending with a NUL, then another NUL)
# becomes the pending list.
FN ui_list_dialog
    push rsi
    push rdi
    sub rsp, 40
    call ui_list_begin
    test eax, eax
    jz .Lui_dialog_list_return
    lea rsi, [rip + ui_dialog_text]
    mov rdi, rsi
.Lui_dialog_folder:
    add rdi, 2
    cmp word ptr [rdi - 2], 0
    jne .Lui_dialog_folder
    cmp word ptr [rdi], 0
    jne .Lui_dialog_name
    mov rcx, rsi                          # one file
    xor edx, edx
    call ui_list_path
    jmp .Lui_dialog_listed
.Lui_dialog_name:
    cmp word ptr [rdi], 0
    je .Lui_dialog_listed
    mov rcx, rsi
    mov rdx, rdi
    call ui_join
    test rax, rax
    jz .Lui_dialog_skip
    mov rcx, rax
    xor edx, edx
    call ui_list_path
.Lui_dialog_skip:
    add rdi, 2
    cmp word ptr [rdi - 2], 0
    jne .Lui_dialog_skip
    jmp .Lui_dialog_name
.Lui_dialog_listed:
    call ui_list_end
.Lui_dialog_list_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN ui_list_dialog
