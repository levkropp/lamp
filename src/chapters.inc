# Original chapter reader, included by src/tags.s. MIT, see LICENSE.
# Chapters are start times (nanoseconds) with optional titles, created as
# FFmpeg's demuxers create them: each source numbers its chapters, and a
# chapter whose number was already seen moves that chapter (which loses its
# title) instead of adding another.
# - Vorbis comments: CHAPTERnnn=HH:MM:SS.mmm is chapter nnn; a later
#   CHAPTERnnnNAME titles it.
# - FLAC CUESHEET blocks: a chapter per track but the lead-out, numbered by
#   the track and titled by its ISRC.
# - ID3v2.3/2.4 CHAP frames: the start in milliseconds, titled by the first
#   TIT2 sub-frame or else the element ID.
# - Matroska: the ChapterAtoms of every EditionEntry (see mkv_chapters),
#   numbered by their ChapterUID.
# - MP4/MOV: the Nero chpl box (100 ns units), then the text tracks the last
#   tref/chap box names (QuickTime chapters: one sample per chapter, a 16-bit
#   length then UTF-8 or UTF-16 text). Both number their chapters from 0, so
#   a track's chapters replace chpl's.
.equ CHAP_MAX, 1024
.equ CHAP_TEXT, 1 << 18
.equ CHAP_TITLE_MAX, 1024
.equ CHAP_LINE, CHAP_TITLE_MAX + 40       # chapter_line's buffer
.equ CHAP_TRACKS, 16                     # tref/chap track IDs kept

.data
chap_count: .long 0
chap_text_used: .long 0
chap_id3_next: .long 0              # the next CHAP frame's number
mkv_chapters_seen: .long 0          # a Chapters element was read
mkv_cluster_seen: .long 0
mp4_chapter_count: .long 0          # track IDs the last tref/chap names

.p2align 3
mkv_last_start: .quad 0             # of the last atom that became a chapter
mkv_chapters_seek: .quad -1         # Chapters position a SeekHead names

.bss
.p2align 3
chap_start: .zero CHAP_MAX*8
chap_id: .zero CHAP_MAX*8
chap_title_off: .zero CHAP_MAX*4
chap_title_len: .zero CHAP_MAX*4
chap_text: .zero CHAP_TEXT
mp4_chapter_tracks: .zero CHAP_TRACKS*4

RODATA
mp4_mdhd_path: .ascii "mdiamdhd"
    .long 0, 0
mp4_stbl_path: .ascii "mdiaminfstbl"
    .long 0
mp4_hdlr_path: .ascii "mdiahdlr"
    .long 0, 0

.text
LOCALFN chap_clear
    xor eax, eax
    mov [rip + chap_count], eax
    mov [rip + chap_text_used], eax
    mov [rip + chap_id3_next], eax
    mov [rip + mkv_chapters_seen], eax
    mov [rip + mkv_cluster_seen], eax
    mov [rip + mp4_chapter_count], eax
    mov [rip + mkv_last_start], rax
    mov qword ptr [rip + mkv_chapters_seek], -1
    ret
ENDFN chap_clear

# -> EAX=chapters.
FN chapters_count
    mov eax, [rip + chap_count]
    ret
ENDFN chapters_count

# ECX=chapter -> RAX=start in nanoseconds, RDX=UTF-8 title (0 for none),
# R8D=its bytes.
FN chapters_get
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
    cmp ecx, [rip + chap_count]
    jae .Lchapters_get_return
    lea rax, [rip + chap_start]
    mov rax, [rax + rcx*8]
    lea r9, [rip + chap_title_len]
    mov r8d, [r9 + rcx*4]
    test r8d, r8d
    jz .Lchapters_get_return
    lea r9, [rip + chap_title_off]
    mov edx, [r9 + rcx*4]
    lea r9, [rip + chap_text]
    add rdx, r9
.Lchapters_get_return:
    ret
ENDFN chapters_get

# ECX=6 next / 7 previous, RDX=heard milliseconds, R8=duration milliseconds
# (0 unknown) -> RAX=target milliseconds, EDX=1 if a boundary was found.
FN chapter_target
    sub rsp, 40
    lea r9, [rip + chap_start]
    mov eax, [rip + chap_count]
    mov [rsp + 32], eax
    call chapter_target_from
    add rsp, 40
    ret
ENDFN chapter_target

# Same arguments, R9=nanosecond start table, fifth argument=count. Scan
# without sorting: printed chapter order stays intact, duplicate starts
# form one boundary. Ignore starts at/past the known end. Previous restarts
# the current chapter after 3 s, otherwise chooses the preceding boundary;
# the beginning of the file is an implicit boundary. No usable chapters or
# no next boundary leaves the position unchanged (EDX=0).
FN chapter_target_from
    push rbx
    push rsi
    push rdi
    mov ebx, ecx
    mov rsi, rdx
    mov ecx, [rsp + 64]                 # fifth argument before our pushes
    cmp ecx, CHAP_MAX
    ja .Lchapter_target_none
    test ecx, ecx
    jz .Lchapter_target_none
    test r9, r9
    jz .Lchapter_target_none
    mov r10, -1                        # nearest start strictly after position
    xor r11d, r11d                     # current boundary (implicit zero)
    xor edi, edi                       # at least one usable chapter
.Lchapter_target_scan:
    mov rax, [r9]
    xor edx, edx
    push rcx
    mov ecx, 1000000
    div rcx
    pop rcx
    test r8, r8
    jz .Lchapter_target_usable
    cmp rax, r8
    jae .Lchapter_target_advance
.Lchapter_target_usable:
    mov edi, 1
    cmp rax, rsi
    ja .Lchapter_target_next
    cmp rax, r11
    cmova r11, rax
    jmp .Lchapter_target_advance
.Lchapter_target_next:
    cmp rax, r10
    cmovb r10, rax
.Lchapter_target_advance:
    add r9, 8
    dec ecx
    jnz .Lchapter_target_scan
    test edi, edi
    jz .Lchapter_target_none
    cmp ebx, 6
    jne .Lchapter_target_previous
    cmp r10, -1
    je .Lchapter_target_none
    mov rax, r10
    jmp .Lchapter_target_found
.Lchapter_target_previous:
    cmp ebx, 7
    jne .Lchapter_target_none
    mov rax, rsi
    sub rax, r11
    cmp rax, 3000
    ja .Lchapter_target_current
    # Second bounded scan finds the nearest boundary before the current.
    mov ecx, [rsp + 64]
    mov eax, ecx
    shl eax, 3
    sub r9, rax
    xor r10d, r10d
.Lchapter_target_prior:
    mov rax, [r9]
    xor edx, edx
    push rcx
    mov ecx, 1000000
    div rcx
    pop rcx
    cmp rax, r11
    jae .Lchapter_target_prior_advance
    cmp rax, r10
    cmova r10, rax
.Lchapter_target_prior_advance:
    add r9, 8
    dec ecx
    jnz .Lchapter_target_prior
    mov rax, r10
    jmp .Lchapter_target_found
.Lchapter_target_current:
    mov rax, r11
.Lchapter_target_found:
    mov edx, 1
    jmp .Lchapter_target_return
.Lchapter_target_none:
    mov rax, rsi
    xor edx, edx
.Lchapter_target_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN chapter_target_from

# ECX=chapter, RDX=buffer of CHAP_LINE bytes -> EAX=bytes of its
# "HH:MM:SS.mmm title" line (NUL-terminated; no title, no space after the
# time; control characters become spaces).
FN chapter_line
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rdx
    mov rbx, rdx
    call chapters_get
    mov rsi, rdx
    mov r12d, r8d
    xor edx, edx
    mov ecx, 1000000
    div rcx                                 # milliseconds, rounded down
    xor edx, edx
    mov ecx, 3600000
    div rcx
    mov [rsp + 32], rdx
    mov ecx, 2
    call chap_digits                        # hours
    mov byte ptr [rdi], ':'
    inc rdi
    mov rax, [rsp + 32]
    xor edx, edx
    mov ecx, 60000
    div rcx
    mov [rsp + 32], rdx
    mov ecx, 2
    call chap_digits                        # minutes
    mov byte ptr [rdi], ':'
    inc rdi
    mov rax, [rsp + 32]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rsp + 32], rdx
    mov ecx, 2
    call chap_digits                        # seconds
    mov byte ptr [rdi], '.'
    inc rdi
    mov rax, [rsp + 32]
    mov ecx, 3
    call chap_digits                        # milliseconds
    test r12d, r12d
    jz .Lchapter_line_end
    mov byte ptr [rdi], ' '
    inc rdi
.Lchapter_line_title:
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp eax, 0x20
    jae .Lchapter_line_store
    mov eax, 0x20
.Lchapter_line_store:
    mov [rdi], al
    inc rdi
    dec r12d
    jnz .Lchapter_line_title
.Lchapter_line_end:
    mov byte ptr [rdi], 0
    mov rax, rdi
    sub rax, rbx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN chapter_line

# RAX=value, ECX=minimum digits, RDI=destination -> RDI past the digits.
LOCALFN chap_digits
    sub rsp, 24
    lea r9, [rsp + 24]
    mov r8d, 10
.Lchap_digit:
    xor edx, edx
    div r8
    add dl, '0'
    dec r9
    mov [r9], dl
    dec ecx
    test rax, rax
    jnz .Lchap_digit
    test ecx, ecx
    jg .Lchap_digit                         # zero padding
    lea rcx, [rsp + 24]
.Lchap_copy:
    mov al, [r9]
    mov [rdi], al
    inc r9
    inc rdi
    cmp r9, rcx
    jb .Lchap_copy
    add rsp, 24
    ret
ENDFN chap_digits

# RCX=start (ns), RDX=chapter number -> EAX=its chapter: the chapter with
# that number moves there and loses its title, or a new one is added (as
# avpriv_new_chapter does); -1 when full.
LOCALFN chap_new
    call chap_find
    cmp eax, -1
    jne .Lchap_new_set
    mov eax, [rip + chap_count]
    cmp eax, CHAP_MAX
    jae .Lchap_new_full
    inc dword ptr [rip + chap_count]
    lea r8, [rip + chap_id]
    mov [r8 + rax*8], rdx
.Lchap_new_set:
    lea r8, [rip + chap_start]
    mov [r8 + rax*8], rcx
    lea r8, [rip + chap_title_len]
    mov dword ptr [r8 + rax*4], 0
    ret
.Lchap_new_full:
    mov eax, -1
    ret
ENDFN chap_new

# RDX=chapter number -> EAX=its chapter, -1 for none.
LOCALFN chap_find
    xor eax, eax
    lea r8, [rip + chap_id]
.Lchap_find_next:
    cmp eax, [rip + chap_count]
    jae .Lchap_find_none
    cmp [r8 + rax*8], rdx
    je .Lchap_find_return
    inc eax
    jmp .Lchap_find_next
.Lchap_find_none:
    mov eax, -1
.Lchap_find_return:
    ret
ENDFN chap_find

# RAX=time in units, RCX=units per second -> RAX=nanoseconds, rounded down
# (wrapping past 2^64).
LOCALFN chap_ns
    xor edx, edx
    div rcx
    imul r8, rax, 1000000000
    mov rax, rdx
    mov r9d, 1000000000
    mul r9
    div rcx
    add rax, r8
    ret
ENDFN chap_ns

# ECX=chapter, RDX=UTF-8 title, R8D=bytes: sets its title (to a NUL, at most
# CHAP_TITLE_MAX bytes at a character boundary).
LOCALFN chap_set_title
    push rsi
    push rdi
    cmp ecx, [rip + chap_count]
    jae .Lchap_title_return
    xor eax, eax
.Lchap_title_nul:
    cmp eax, r8d
    jae .Lchap_title_cut
    cmp byte ptr [rdx + rax], 0
    je .Lchap_title_cut
    inc eax
    jmp .Lchap_title_nul
.Lchap_title_cut:
    mov r8d, eax
    cmp r8d, CHAP_TITLE_MAX
    jbe .Lchap_title_room
    mov r8d, CHAP_TITLE_MAX
.Lchap_title_boundary:
    movzx eax, byte ptr [rdx + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Lchap_title_room
    dec r8d
    jnz .Lchap_title_boundary
.Lchap_title_room:
    mov eax, [rip + chap_text_used]
    lea r9d, [rax + r8]
    cmp r9d, CHAP_TEXT
    ja .Lchap_title_return
    lea rdi, [rip + chap_text]
    add rdi, rax
    lea r9, [rip + chap_title_off]
    mov [r9 + rcx*4], eax
    lea r9, [rip + chap_title_len]
    mov [r9 + rcx*4], r8d
    add [rip + chap_text_used], r8d
    mov rsi, rdx
    mov ecx, r8d
    rep movsb
.Lchap_title_return:
    pop rdi
    pop rsi
    ret
ENDFN chap_set_title

# RSI=text, RDI=end, ECX=width -> EAX=decimal value of up to ECX characters
# (with an optional +) after white space, as sscanf's %0Nd reads it; RSI
# advanced; CF when there is none. A minus sign reads as no number.
LOCALFN chap_number
    xor eax, eax
.Lchap_number_space:
    cmp rsi, rdi
    jae .Lchap_number_none
    movzx edx, byte ptr [rsi]
    cmp edx, ' '
    je .Lchap_number_skip
    sub edx, 9
    cmp edx, 4                            # tab, LF, VT, FF, CR
    ja .Lchap_number_digits
.Lchap_number_skip:
    inc rsi
    jmp .Lchap_number_space
.Lchap_number_digits:
    xor edx, edx                          # characters read
    xor r10d, r10d                        # digits read
    cmp byte ptr [rsi], '+'
    jne .Lchap_number_digit
    inc rsi
    inc edx
.Lchap_number_digit:
    cmp edx, ecx
    jae .Lchap_number_done
    cmp rsi, rdi
    jae .Lchap_number_done
    movzx r8d, byte ptr [rsi]
    sub r8d, '0'
    cmp r8d, 9
    ja .Lchap_number_done
    imul eax, eax, 10
    add eax, r8d
    inc rsi
    inc edx
    inc r10d
    jmp .Lchap_number_digit
.Lchap_number_done:
    test r10d, r10d
    jz .Lchap_number_none
    clc
    ret
.Lchap_number_none:
    stc
    ret
ENDFN chap_number

# RCX=comment key, EDX=its bytes, R8=value, R9D=its bytes -> EAX=1 when it is
# a chapter comment (FFmpeg's ogm_chapter rules).
LOCALFN vc_chapter
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    xor eax, eax
    cmp edx, 9
    jb .Lvc_chapter_return
    mov r10d, [rcx]
    or r10d, 0x20202020
    cmp r10d, 0x70616863                  # "chap"
    jne .Lvc_chapter_return
    mov r10d, [rcx + 3]
    or r10d, 0x20202020
    cmp r10d, 0x72657470                  # "pter"
    jne .Lvc_chapter_return
    mov r12, r8                           # value
    mov r13d, r9d
    mov ebx, edx                          # key bytes
    lea rsi, [rcx + 7]
    lea rdi, [rcx + rdx]
    mov [rsp + 24], rcx
    mov ecx, 3
    call chap_number                      # the chapter number
    jc .Lvc_chapter_no
    mov r11d, eax
    cmp ebx, 10
    ja .Lvc_chapter_name
    # CHAPTERnnn=HH:MM:SS.mmm
    mov rsi, r12
    lea rdi, [r12 + r13]
    mov ecx, 2
    call chap_number
    jc .Lvc_chapter_no
    mov r9d, eax                          # hours
    cmp rsi, rdi
    jae .Lvc_chapter_no
    cmp byte ptr [rsi], ':'
    jne .Lvc_chapter_no
    inc rsi
    mov ecx, 2
    call chap_number
    jc .Lvc_chapter_no
    imul r9d, r9d, 60
    add r9d, eax                          # minutes
    cmp rsi, rdi
    jae .Lvc_chapter_no
    cmp byte ptr [rsi], ':'
    jne .Lvc_chapter_no
    inc rsi
    mov ecx, 2
    call chap_number
    jc .Lvc_chapter_no
    imul r9d, r9d, 60
    add r9d, eax                          # seconds
    cmp rsi, rdi
    jae .Lvc_chapter_no
    cmp byte ptr [rsi], '.'
    jne .Lvc_chapter_no
    inc rsi
    mov ecx, 3
    call chap_number
    jc .Lvc_chapter_no
    imul r9, r9, 1000
    add r9, rax                           # milliseconds
    imul r9, r9, 1000000
    mov rcx, r9
    mov edx, r11d
    call chap_new
    jmp .Lvc_chapter_yes
.Lvc_chapter_name:
    # CHAPTERnnn...NAME titles an existing chapter.
    mov rcx, [rsp + 24]
    mov r10d, [rcx + rbx - 4]
    or r10d, 0x20202020
    cmp r10d, 0x656d616e                  # "name"
    jne .Lvc_chapter_no
    mov edx, r11d
    call chap_find
    cmp eax, -1
    je .Lvc_chapter_no
    mov ecx, eax
    mov rdx, r12
    mov r8d, r13d
    call chap_set_title
.Lvc_chapter_yes:
    mov eax, 1
    jmp .Lvc_chapter_return
.Lvc_chapter_no:
    xor eax, eax
.Lvc_chapter_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vc_chapter

# RDX=CHAP frame data, R8D=bytes, R9D=ID3v2 version (3, 4): a chapter (ID
# chap_id3_next) at its start in milliseconds, titled by its first TIT2
# sub-frame that decodes or else by its element ID. As in FFmpeg, a
# sub-frame running past the frame drops the chapter, and an end before the
# start drops it but uses up its ID. Sub-frame sizes are synchsafe in
# ID3v2.4 (FFmpeg reads them as plain integers).
LOCALFN id3_chapter
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rdx
    lea rdi, [rdx + r8]
    mov r12d, r9d
    mov r14, rdx                          # element ID
.Lid3_chapter_element:
    cmp rsi, rdi                          # to its NUL
    jae .Lid3_chapter_return
    inc rsi
    cmp byte ptr [rsi - 1], 0
    jne .Lid3_chapter_element
    mov r15, rsi
    sub r15, r14
    mov rax, rdi
    sub rax, rsi
    cmp rax, 16
    jb .Lid3_chapter_return
    mov ebx, [rsi]
    bswap ebx                             # start
    mov r13d, [rsi + 4]
    bswap r13d                            # end
    add rsi, 16
    mov [rsp + 32], rsi                   # the sub-frames
    xor ecx, ecx
    call id3_chapter_frames
    jc .Lid3_chapter_return
    mov edx, [rip + chap_id3_next]
    inc dword ptr [rip + chap_id3_next]
    cmp r13d, ebx
    jb .Lid3_chapter_return
    mov ecx, ebx
    imul rcx, rcx, 1000000
    call chap_new
    cmp eax, -1
    je .Lid3_chapter_return
    mov [rsp + 40], eax
    mov rsi, [rsp + 32]
    mov ecx, 1
    call id3_chapter_frames
    test rax, rax
    jnz .Lid3_chapter_title
    mov rcx, r14
    mov edx, r15d
    call tag_latin1
.Lid3_chapter_title:
    mov ecx, [rsp + 40]
    mov r8d, edx
    mov rdx, rax
    call chap_set_title
.Lid3_chapter_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN id3_chapter

# RSI=CHAP sub-frames, RDI=end, R12D=ID3v2 version; ECX=0 -> CF when a
# sub-frame runs past the end; ECX=1 -> RAX=the first nonempty TIT2, as
# UTF-8 (0 for none), EDX=bytes. As FFmpeg reads them: sub-frames are read
# while more than a 10-byte header is left, and a text sub-frame ("T...") is
# left where its first string (and a TXXX value) ends, so the next header is
# read from there.
LOCALFN id3_chapter_frames
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 40
    mov ebx, ecx
    mov r14, rdi
    sub r14, rsi                          # bytes left as FFmpeg counts them
.Lid3_chapter_frame:
    cmp r14, 10
    jbe .Lid3_chapter_frames_end
    mov r13d, [rsi]                       # sub-frame ID
    cmp r12d, 4
    jne .Lid3_chapter_size3
    lea rcx, [rsi + 4]
    call id3_synchsafe
    jmp .Lid3_chapter_sized
.Lid3_chapter_size3:
    mov eax, [rsi + 4]
    bswap eax
.Lid3_chapter_sized:
    add rsi, 10
    sub r14, 10
    cmp rax, r14
    ja .Lid3_chapter_frames_past
    sub r14, rax
    mov r15d, eax
    cmp r13b, 'T'
    jne .Lid3_chapter_skip
    test r15d, r15d
    jz .Lid3_chapter_frame
    test ebx, ebx
    jz .Lid3_chapter_consume
    cmp r13d, 0x32544954                  # TIT2
    jne .Lid3_chapter_consume
    movzx ecx, byte ptr [rsi]
    lea rdx, [rsi + 1]
    lea r8d, [r15 - 1]
    call id3_string
    test rax, rax
    jz .Lid3_chapter_consume
    test edx, edx
    jnz .Lid3_chapter_frames_return       # CF clear
.Lid3_chapter_consume:
    movzx ecx, byte ptr [rsi]
    mov [rsp + 32], ecx                   # encoding
    lea rdx, [rsi + 1]
    lea r8d, [r15 - 1]
    call id3_consumed
    jc .Lid3_chapter_consumed
    cmp r13d, 0x58585854                  # TXXX: its value is read too
    jne .Lid3_chapter_consumed
    mov [rsp + 36], eax
    mov ecx, [rsp + 32]
    lea rdx, [rsi + rax + 1]
    mov r8d, r15d
    sub r8d, eax
    dec r8d
    call id3_consumed
    add eax, [rsp + 36]
.Lid3_chapter_consumed:
    lea rsi, [rsi + rax + 1]
    jmp .Lid3_chapter_frame
.Lid3_chapter_skip:
    add rsi, r15
    jmp .Lid3_chapter_frame
.Lid3_chapter_frames_end:
    xor eax, eax                          # clears CF
    jmp .Lid3_chapter_frames_return
.Lid3_chapter_frames_past:
    xor eax, eax
    stc
.Lid3_chapter_frames_return:
    lea rsp, [rsp + 40]                   # keeps CF
    pop r15
    pop r14
    pop r13
    pop rbx
    ret
ENDFN id3_chapter_frames

# ECX=ID3v2 text encoding, RDX=text, R8D=bytes -> EAX=the bytes FFmpeg's
# decode_str reads for a string: through a NUL (Latin-1, UTF-8) or a zero
# unit (UTF-16, a byte order mark first), stopping after an invalid
# surrogate pair; nothing for other encodings. CF when decode_str fails
# (no room for a byte order mark, or a bad one, which it has read).
LOCALFN id3_consumed
    xor eax, eax
    test ecx, ecx
    jz .Lid3_consumed_byte
    cmp ecx, 3
    je .Lid3_consumed_byte
    mov r10d, 1                           # big-endian
    cmp ecx, 2
    je .Lid3_consumed_unit
    cmp ecx, 1
    jne .Lid3_consumed_done
    cmp r8d, 2
    jb .Lid3_consumed_failed
    mov eax, 2
    movzx r9d, word ptr [rdx]
    cmp r9d, 0xfffe                       # FE FF
    je .Lid3_consumed_unit
    xor r10d, r10d
    cmp r9d, 0xfeff                       # FF FE
    jne .Lid3_consumed_failed
.Lid3_consumed_unit:
    mov r9d, r8d
    sub r9d, eax
    cmp r9d, 1
    jle .Lid3_consumed_done
    call .Lid3_consumed_get
    test r9d, r9d
    jz .Lid3_consumed_done
    lea r11d, [r9 - 0xd800]
    cmp r11d, 0x800
    jae .Lid3_consumed_unit
    mov r9d, r8d                          # a surrogate: the next unit is read
    sub r9d, eax
    cmp r9d, 2
    jl .Lid3_consumed_done
    call .Lid3_consumed_get
    cmp r11d, 0x3ff
    ja .Lid3_consumed_done
    sub r9d, 0xdc00
    cmp r9d, 0x3ff
    ja .Lid3_consumed_done
    jmp .Lid3_consumed_unit
.Lid3_consumed_byte:
    cmp eax, r8d
    jae .Lid3_consumed_done
    inc eax
    cmp byte ptr [rdx + rax - 1], 0
    jne .Lid3_consumed_byte
.Lid3_consumed_done:
    clc
    ret
.Lid3_consumed_failed:
    stc
    ret
# The unit at RDX+RAX -> R9D, RAX past it.
.Lid3_consumed_get:
    movzx r9d, word ptr [rdx + rax]
    add eax, 2
    test r10d, r10d
    jz .Lid3_consumed_got
    rol r9w, 8
.Lid3_consumed_got:
    ret
ENDFN id3_consumed

# RSI=Chapters payload, RDI=end: the top-level ChapterAtoms of every
# EditionEntry, as FFmpeg reads them. An atom needs a nonzero ChapterUID (its
# ID) and a ChapterTimeStart later than the previous such atom's, in this or
# an earlier Chapters element (unless that one started at 0); one ending
# before its start is dropped. Its title is the last ChapString of its
# ChapterDisplays.
LOCALFN mkv_chapters
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov dword ptr [rip + mkv_chapters_seen], 1
    mov rbp, [rip + mkv_last_start]
.Lmkv_chapters_edition:
    call mkv_element
    test rax, rax
    jz .Lmkv_chapters_return
    mov rsi, rax
    cmp edx, 0x45b9                       # EditionEntry
    jne .Lmkv_chapters_edition
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
.Lmkv_chapters_atom:
    call mkv_element
    test rax, rax
    jz .Lmkv_chapters_edition_done
    mov rsi, rax
    cmp edx, 0xb6                         # ChapterAtom
    jne .Lmkv_chapters_atom
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
    xor ebx, ebx                          # UID
    mov r12, 0x8000000000000000           # start (none)
    mov r15, r12                          # end (none)
    xor r13d, r13d                        # title
    xor r14d, r14d
.Lmkv_chapters_field:
    call mkv_element
    test rax, rax
    jz .Lmkv_chapters_atom_done
    mov rsi, rax
    cmp edx, 0x73c4                       # ChapterUID
    je .Lmkv_chapters_uid
    cmp edx, 0x91                         # ChapterTimeStart
    je .Lmkv_chapters_start
    cmp edx, 0x92                         # ChapterTimeEnd
    je .Lmkv_chapters_end
    cmp edx, 0x80                         # ChapterDisplay
    jne .Lmkv_chapters_field
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
.Lmkv_chapters_display:
    call mkv_element
    test rax, rax
    jz .Lmkv_chapters_display_done
    mov rsi, rax
    cmp edx, 0x85                         # ChapString: the last one counts
    jne .Lmkv_chapters_display
    mov r13, rcx
    mov r14, rax
    sub r14, rcx
    jmp .Lmkv_chapters_display
.Lmkv_chapters_display_done:
    pop rdi
    pop rsi
    jmp .Lmkv_chapters_field
.Lmkv_chapters_uid:
    xor r9d, r9d
    call mkv_chapter_uint
    jc .Lmkv_chapters_field
    mov rbx, rax
    jmp .Lmkv_chapters_field
.Lmkv_chapters_start:
    mov r9, 0x8000000000000000
    call mkv_chapter_uint
    jc .Lmkv_chapters_field
    mov r12, rax
    jmp .Lmkv_chapters_field
.Lmkv_chapters_end:
    mov r9, 0x8000000000000000
    call mkv_chapter_uint
    jc .Lmkv_chapters_field
    mov r15, rax
    jmp .Lmkv_chapters_field
.Lmkv_chapters_atom_done:
    pop rdi
    pop rsi
    mov rax, 0x8000000000000000
    cmp r12, rax
    je .Lmkv_chapters_atom
    test rbx, rbx
    jz .Lmkv_chapters_atom
    test rbp, rbp
    jz .Lmkv_chapters_later
    cmp r12, rbp
    jbe .Lmkv_chapters_atom
.Lmkv_chapters_later:
    mov rbp, r12
    cmp r15, rax
    je .Lmkv_chapters_new
    cmp r12, r15
    jg .Lmkv_chapters_atom                # ends before it starts
.Lmkv_chapters_new:
    mov rcx, r12
    mov rdx, rbx
    call chap_new
    cmp eax, -1
    je .Lmkv_chapters_atom
    test r13, r13
    jz .Lmkv_chapters_atom
    mov ecx, eax
    mov rdx, r13
    mov r8d, r14d
    call chap_set_title
    jmp .Lmkv_chapters_atom
.Lmkv_chapters_edition_done:
    pop rdi
    pop rsi
    jmp .Lmkv_chapters_edition
.Lmkv_chapters_return:
    mov [rip + mkv_last_start], rbp
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
ENDFN mkv_chapters

# RSI=SeekHead payload, RDI=end: notes the positions (in the Segment) of the
# first Seeks naming a Chapters and an Attachments element.
LOCALFN mkv_seek_chapters
    push rbx
    push r12
    sub rsp, 40
.Lmkv_seek_entry:
    call mkv_element
    test rax, rax
    jz .Lmkv_seek_return
    mov rsi, rax
    cmp edx, 0x4dbb                       # Seek
    jne .Lmkv_seek_entry
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
    xor ebx, ebx                          # its SeekID: 1 Chapters, 2 Attachments
    mov r12, -1                           # SeekPosition
.Lmkv_seek_field:
    call mkv_element
    test rax, rax
    jz .Lmkv_seek_done
    mov rsi, rax
    cmp edx, 0x53ac                       # SeekPosition
    je .Lmkv_seek_position
    cmp edx, 0x53ab                       # SeekID
    jne .Lmkv_seek_field
    sub rax, rcx
    xor ebx, ebx
    cmp rax, 4
    jne .Lmkv_seek_field
    mov ebx, 1
    cmp dword ptr [rcx], 0x70a74310       # 10 43 A7 70
    je .Lmkv_seek_field
    mov ebx, 2
    cmp dword ptr [rcx], 0x69a44119       # 19 41 A4 69
    je .Lmkv_seek_field
    xor ebx, ebx
    jmp .Lmkv_seek_field
.Lmkv_seek_position:
    mov r9, -1
    call mkv_chapter_uint
    jc .Lmkv_seek_field
    mov r12, rax
    jmp .Lmkv_seek_field
.Lmkv_seek_done:
    pop rdi
    pop rsi
    lea rax, [rip + mkv_chapters_seek]
    cmp ebx, 1
    je .Lmkv_seek_note
    lea rax, [rip + mkv_attachments_seek]
    cmp ebx, 2
    jne .Lmkv_seek_entry
.Lmkv_seek_note:
    cmp qword ptr [rax], -1
    jne .Lmkv_seek_entry
    mov [rax], r12
    jmp .Lmkv_seek_entry
.Lmkv_seek_return:
    add rsp, 40
    pop r12
    pop rbx
    ret
ENDFN mkv_seek_chapters

# RCX=payload, RAX=its end, R9=default -> RAX=the unsigned value (the
# default when it is empty); CF when it has more than 8 bytes.
LOCALFN mkv_chapter_uint
    mov r8, rax
    sub r8, rcx
    cmp r8, 8
    ja .Lmkv_chapter_uint_long
    mov rax, r9
    test r8, r8
    jz .Lmkv_chapter_uint_return
    xor eax, eax
.Lmkv_chapter_uint_byte:
    shl rax, 8
    movzx r9d, byte ptr [rcx]
    or rax, r9
    inc rcx
    dec r8
    jnz .Lmkv_chapter_uint_byte
.Lmkv_chapter_uint_return:
    clc
    ret
.Lmkv_chapter_uint_long:
    stc
    ret
ENDFN mkv_chapter_uint

# RCX=chpl payload, RDX=end: Nero chapters (100 ns units), numbered from 0.
LOCALFN mp4_chpl
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov rax, rdi
    sub rax, rsi
    cmp rax, 5
    jb .Lmp4_chpl_return
    movzx eax, byte ptr [rsi]             # version
    add rsi, 4
    test eax, eax
    jz .Lmp4_chpl_count
    add rsi, 4
.Lmp4_chpl_count:
    cmp rsi, rdi
    jae .Lmp4_chpl_return
    movzx ebx, byte ptr [rsi]
    inc rsi
    xor r13d, r13d                        # chapter number
.Lmp4_chpl_entry:
    cmp r13d, ebx
    jae .Lmp4_chpl_return
    mov rax, rdi
    sub rax, rsi
    cmp rax, 9
    jb .Lmp4_chpl_return
    mov rcx, [rsi]
    bswap rcx
    imul rcx, rcx, 100
    movzx r12d, byte ptr [rsi + 8]
    add rsi, 9
    sub rax, 9
    cmp r12, rax
    ja .Lmp4_chpl_return
    mov edx, r13d
    inc r13d
    call chap_new
    cmp eax, -1
    je .Lmp4_chpl_return
    mov ecx, eax
    mov rdx, rsi
    mov r8d, r12d
    call chap_set_title
    add rsi, r12
    jmp .Lmp4_chpl_entry
.Lmp4_chpl_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_chpl

# RCX=trak payload, RDX=end, R8D=1 to note the tracks its tref/chap box
# names (the last such box counts) -> EAX=its track ID (tkhd), 0 when absent.
LOCALFN mp4_trak_ids
    push rsi
    push rdi
    push rbx
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    xor ebx, ebx
.Lmp4_trak_ids_box:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_trak_ids_return
    mov rsi, rax
    cmp edx, 0x64686b74                   # tkhd
    je .Lmp4_trak_ids_tkhd
    cmp edx, 0x66657274                   # tref
    jne .Lmp4_trak_ids_box
    test r12d, r12d
    jz .Lmp4_trak_ids_box
    mov rdx, rax
    mov r8d, 0x70616863                   # chap
    call mp4_find
    test rax, rax
    jz .Lmp4_trak_ids_box
    sub rax, rcx
    shr rax, 2                            # its track IDs
    cmp rax, CHAP_TRACKS
    jbe .Lmp4_trak_ids_chap
    mov eax, CHAP_TRACKS
.Lmp4_trak_ids_chap:
    mov [rip + mp4_chapter_count], eax
    lea r8, [rip + mp4_chapter_tracks]
    xor edx, edx
.Lmp4_trak_ids_chap_next:
    cmp edx, eax
    jae .Lmp4_trak_ids_box
    mov r9d, [rcx + rdx*4]
    bswap r9d
    mov [r8 + rdx*4], r9d
    inc edx
    jmp .Lmp4_trak_ids_chap_next
.Lmp4_trak_ids_tkhd:
    sub rax, rcx
    mov r8d, 12                           # version 0: ID after the times
    cmp byte ptr [rcx], 0
    je .Lmp4_trak_ids_field
    mov r8d, 20
.Lmp4_trak_ids_field:
    lea r9, [r8 + 4]
    cmp rax, r9
    jb .Lmp4_trak_ids_box
    mov ebx, [rcx + r8]
    bswap ebx
    jmp .Lmp4_trak_ids_box
.Lmp4_trak_ids_return:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mp4_trak_ids

# RCX=box, RDX=end, R8D=path of up to four FourCCs (zero-padded in the
# 16 bytes at R9) -> RAX=the last box's payload end, RCX=its payload.
LOCALFN mp4_path
    push rsi
    push rdi
    push rbx
    mov rbx, r9
    xor esi, esi
.Lmp4_path_step:
    cmp esi, 4
    jae .Lmp4_path_found
    mov r8d, [rbx + rsi*4]
    test r8d, r8d
    jz .Lmp4_path_found
    call mp4_find
    test rax, rax
    jz .Lmp4_path_none
    mov rdx, rax
    inc esi
    jmp .Lmp4_path_step
.Lmp4_path_found:
    mov rax, rdx
    jmp .Lmp4_path_return
.Lmp4_path_none:
    xor eax, eax
.Lmp4_path_return:
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mp4_path

# RCX=chapter text trak payload, RDX=end, R8=file start, R9=file end ->
# EAX=1 when its samples became chapters (QuickTime chapters): sample N is
# chapter N, timed by stts in the mdhd timescale (edit lists are not
# applied) and located by stsc, stsz and stco/co64. As in FFmpeg, a sample
# whose text length runs past it is skipped.
LOCALFN mp4_chapter_samples
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 176
    mov [rsp + 32], rcx
    mov [rsp + 40], rdx
    mov [rsp + 48], r8
    mov [rsp + 56], r9
    lea r9, [rip + mp4_mdhd_path]
    call mp4_path
    test rax, rax
    jz .Lmcs_none
    sub rax, rcx
    mov r8d, 12                           # timescale, version 0
    cmp byte ptr [rcx], 0
    je .Lmcs_scale
    mov r8d, 20
.Lmcs_scale:
    lea r9, [r8 + 4]
    cmp rax, r9
    jb .Lmcs_none
    mov eax, [rcx + r8]
    bswap eax
    test eax, eax
    jz .Lmcs_none
    mov [rsp + 64], rax                   # timescale
    mov rcx, [rsp + 32]
    mov rdx, [rsp + 40]
    lea r9, [rip + mp4_stbl_path]
    call mp4_path
    test rax, rax
    jz .Lmcs_none
    mov [rsp + 72], rcx                   # stbl
    mov [rsp + 80], rax
    # stsz: R12D constant size, R13D samples, R14 sizes.
    mov rdx, rax
    mov r8d, 0x7a737473                   # stsz
    call mp4_find
    test rax, rax
    jz .Lmcs_none
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 12
    jb .Lmcs_none
    mov r12d, [rcx + 4]
    bswap r12d
    mov r13d, [rcx + 8]
    bswap r13d
    lea r14, [rcx + 12]
    test r13d, r13d
    jz .Lmcs_none
    cmp r13d, CHAP_MAX
    ja .Lmcs_none
    test r12d, r12d
    jnz .Lmcs_stts
    lea rax, [r13*4 + 12]
    cmp rax, rdx
    ja .Lmcs_none
.Lmcs_stts:
    # stts entries (count, delta) at [rsp+88], entries left at [rsp+96].
    mov rcx, [rsp + 72]
    mov rdx, [rsp + 80]
    mov r8d, 0x73747473                   # stts
    call mp4_find
    test rax, rax
    jz .Lmcs_none
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 8
    jb .Lmcs_none
    mov eax, [rcx + 4]
    bswap eax
    lea r8, [rax*8 + 8]
    cmp r8, rdx
    ja .Lmcs_none
    lea rcx, [rcx + 8]
    mov [rsp + 88], rcx
    mov [rsp + 96], eax
    # stsc entries (first chunk, samples per chunk, description) at
    # [rsp+104], entries at [rsp+112].
    mov rcx, [rsp + 72]
    mov rdx, [rsp + 80]
    mov r8d, 0x63737473                   # stsc
    call mp4_find
    test rax, rax
    jz .Lmcs_none
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 8
    jb .Lmcs_none
    mov eax, [rcx + 4]
    bswap eax
    test eax, eax
    jz .Lmcs_none
    imul r8, rax, 12
    add r8, 8
    cmp r8, rdx
    ja .Lmcs_none
    lea rcx, [rcx + 8]
    mov [rsp + 104], rcx
    mov [rsp + 112], eax
    # Chunk offsets: stco (32-bit) or co64; R15=table, [rsp+116] count,
    # [rsp+120] 8 for co64.
    mov rcx, [rsp + 72]
    mov rdx, [rsp + 80]
    mov r8d, 0x6f637473                   # stco
    call mp4_find
    mov dword ptr [rsp + 120], 4
    test rax, rax
    jnz .Lmcs_chunks
    mov rcx, [rsp + 72]
    mov rdx, [rsp + 80]
    mov r8d, 0x34366f63                   # co64
    call mp4_find
    test rax, rax
    jz .Lmcs_none
    mov dword ptr [rsp + 120], 8
.Lmcs_chunks:
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 8
    jb .Lmcs_none
    mov eax, [rcx + 4]
    bswap eax
    test eax, eax
    jz .Lmcs_none
    mov r8d, [rsp + 120]
    imul r8, rax
    add r8, 8
    cmp r8, rdx
    ja .Lmcs_none
    lea r15, [rcx + 8]
    mov [rsp + 116], eax
    # State: EBX sample (and chapter number); [rsp+124] chunk (0-based); RSI
    # offset in the file; EDI samples left in this chunk; [rsp+152] stsc
    # entry; R9 time (units); stts: [rsp+148] entry, [rsp+144] samples left
    # in it.
    xor ebx, ebx
    xor r9d, r9d
    mov [rsp + 124], ebx
    mov [rsp + 152], ebx
    mov [rsp + 148], ebx
    mov [rsp + 144], ebx
    mov rax, [rsp + 104]
    mov edi, [rax + 4]
    bswap edi                             # the first entry's samples per chunk
    call .Lmcs_chunk_offset
    mov rsi, rax
.Lmcs_sample:
    cmp ebx, r13d
    jae .Lmcs_done
    test edi, edi
    jnz .Lmcs_in_chunk
    # The next chunk: its offset and its stsc entry.
    inc dword ptr [rsp + 124]
    mov eax, [rsp + 124]
    cmp eax, [rsp + 116]
    jae .Lmcs_done
    call .Lmcs_chunk_offset
    mov rsi, rax
.Lmcs_entry:
    mov eax, [rsp + 152]
    inc eax
    cmp eax, [rsp + 112]
    jae .Lmcs_entry_found
    imul rcx, rax, 12
    add rcx, [rsp + 104]
    mov ecx, [rcx]
    bswap ecx                             # its first chunk (1-based)
    mov edx, [rsp + 124]
    inc edx
    cmp ecx, edx
    ja .Lmcs_entry_found
    mov [rsp + 152], eax
    jmp .Lmcs_entry
.Lmcs_entry_found:
    mov eax, [rsp + 152]
    imul rcx, rax, 12
    add rcx, [rsp + 104]
    mov edi, [rcx + 4]
    bswap edi
    jmp .Lmcs_sample
.Lmcs_in_chunk:
    mov r8d, r12d                         # this sample's size
    test r12d, r12d
    jnz .Lmcs_sized
    mov r8d, [r14 + rbx*4]
    bswap r8d
.Lmcs_sized:
    mov [rsp + 136], r8
    mov [rsp + 128], r9
    cmp r8, 2
    jb .Lmcs_advance                      # no room for a length: skipped
    xor eax, eax                          # past the file's end: untitled
    mov rcx, rsi
    add rcx, r8
    jc .Lmcs_length
    mov rdx, [rsp + 56]
    sub rdx, [rsp + 48]
    cmp rcx, rdx
    ja .Lmcs_length
    mov rdx, [rsp + 48]
    movzx eax, word ptr [rdx + rsi]
    rol ax, 8                             # text bytes
.Lmcs_length:
    lea rcx, [r8 - 2]
    cmp rax, rcx
    ja .Lmcs_advance                      # longer than the sample: skipped
    mov [rsp + 160], eax
    mov rax, [rsp + 128]
    mov rcx, [rsp + 64]
    call chap_ns
    mov rcx, rax
    mov edx, ebx
    call chap_new
    cmp eax, -1
    je .Lmcs_done
    mov [rsp + 156], eax
    mov r8d, [rsp + 160]
    test r8d, r8d
    jz .Lmcs_advance
    mov rdx, [rsp + 48]
    lea rdx, [rdx + rsi + 2]              # the text
    cmp r8d, 2
    jb .Lmcs_title
    cmp word ptr [rdx], 0xfffe            # FE FF: UTF-16BE
    je .Lmcs_utf16be
    cmp word ptr [rdx], 0xfeff            # FF FE: UTF-16LE
    jne .Lmcs_title
    lea rcx, [rdx + 2]
    lea edx, [r8 - 2]
    xor r8d, r8d
    call tag_utf16
    jmp .Lmcs_converted
.Lmcs_utf16be:
    lea rcx, [rdx + 2]
    lea edx, [r8 - 2]
    mov r8d, 1
    call tag_utf16
.Lmcs_converted:
    mov r8d, edx
    mov rdx, rax
.Lmcs_title:
    mov ecx, [rsp + 156]
    call chap_set_title
.Lmcs_advance:
    add rsi, [rsp + 136]
    dec edi
    mov r9, [rsp + 128]
    # Its duration from stts.
    mov eax, [rsp + 144]
    test eax, eax
    jnz .Lmcs_delta
.Lmcs_stts_next:
    mov eax, [rsp + 148]
    cmp eax, [rsp + 96]
    jae .Lmcs_counted                     # no more entries: duration 0
    mov rcx, [rsp + 88]
    mov edx, [rcx + rax*8]
    bswap edx
    inc dword ptr [rsp + 148]
    mov [rsp + 144], edx
    test edx, edx
    jz .Lmcs_stts_next
.Lmcs_delta:
    dec dword ptr [rsp + 144]
    mov eax, [rsp + 148]
    dec eax
    mov rcx, [rsp + 88]
    mov eax, [rcx + rax*8 + 4]
    bswap eax
    add r9, rax
.Lmcs_counted:
    inc ebx
    jmp .Lmcs_sample
.Lmcs_done:
    mov eax, 1
    jmp .Lmcs_return
.Lmcs_none:
    xor eax, eax
.Lmcs_return:
    add rsp, 176
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# [rsp+8 in the caller]: chunk [rsp+124] -> RAX=its file offset.
.Lmcs_chunk_offset:
    mov eax, [rsp + 8 + 124]
    cmp dword ptr [rsp + 8 + 120], 8
    je .Lmcs_chunk_64
    mov eax, [r15 + rax*4]
    bswap eax
    ret
.Lmcs_chunk_64:
    mov rax, [r15 + rax*8]
    bswap rax
    ret
ENDFN mp4_chapter_samples

# RCX=CUESHEET block, RDX=end, R8D=sample rate: a chapter per track but the
# last (the lead-out) at the track's offset in samples, numbered by the track
# and titled by its ISRC, as FFmpeg's FLAC demuxer reads them. Reading stops
# where FFmpeg rejects the file.
LOCALFN flac_cuesheet
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    mov rax, rdi
    sub rax, rsi
    cmp rax, 431
    jb .Lflac_cuesheet_return
    movzx ebx, byte ptr [rsi + 395]
    dec ebx                               # tracks but the lead-out
    jle .Lflac_cuesheet_return
    add rsi, 396
.Lflac_cuesheet_track:
    lea rax, [rsi + 36]
    cmp rax, rdi
    ja .Lflac_cuesheet_return
    movzx eax, byte ptr [rsi + 35]        # index points
    test eax, eax
    jz .Lflac_cuesheet_return
    imul eax, eax, 12
    lea r13, [rsi + rax + 36]             # the next track
    mov rax, [rsi]
    bswap rax                             # its offset in samples
    mov ecx, r12d
    call chap_ns
    mov rcx, rax
    movzx edx, byte ptr [rsi + 8]         # track number
    call chap_new
    cmp eax, -1
    je .Lflac_cuesheet_return
    mov ecx, eax
    lea rdx, [rsi + 9]                    # ISRC
    mov r8d, 12
    call chap_set_title
    mov rsi, r13
    dec ebx
    jnz .Lflac_cuesheet_track
.Lflac_cuesheet_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_cuesheet
