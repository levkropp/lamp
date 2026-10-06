# Original metadata tag reader in x86-64 assembly. MIT, see LICENSE.
# After a successful open, tags_read reads the opened file's tags into ten
# normalized keys (title, artist, album, album_artist, date, track, disc,
# genre, comment, composer) as UTF-8:
# - ID3v2.2/2.3/2.4 at the start of raw streams and in WAVE and AIFF chunks:
#   text frames and COMM without a description, Latin-1, UTF-16 and UTF-8,
#   unsynchronisation, extended headers, data length indicators; compressed
#   and encrypted frames are skipped. APEv2 at the end of raw streams (and
#   before an ID3v1 tag) fills keys ID3v2 left empty; ID3v1/1.1 is read only when
#   nothing else was, its fields as UTF-8 when valid, else as Latin-1.
#   Numeric genres use the ID3v1 genre list; ID3v2.3 TYER, TDAT and TIME
#   merge into the date.
# - Vorbis comments in native FLAC and in Ogg Vorbis, Opus and FLAC (the
#   first stream LAMP decodes); repeated keys join with ";".
# - MP4/MOV ilst items, RIFF INFO (WAVE, AVI), AIFF NAME/AUTH/ANNO, CAF info
#   Matroska Info title and untargeted SimpleTags, and AU annotations.
# Key mappings and precedence follow FFmpeg's demuxers. Values are cut at
# their first NUL and at TAG_VALUE_MAX bytes; empty values are not stored.
.include "lamp.inc"
.globl tags_read, tags_clear, tags_get, tag_names, chapters_count, chapters_get, chapter_line

.equ TAG_KEYS, 10
.equ TAG_TITLE, 0
.equ TAG_ARTIST, 1
.equ TAG_ALBUM, 2
.equ TAG_ALBUM_ARTIST, 3
.equ TAG_DATE, 4
.equ TAG_TRACK, 5
.equ TAG_DISC, 6
.equ TAG_GENRE, 7
.equ TAG_COMMENT, 8
.equ TAG_COMPOSER, 9
.equ TAG_COMMENT_DESCRIBED, 10      # ID3 frame table: COMM
.equ TAG_USER, 11                   # ID3 frame table: TXXX (its description names the key)
.equ TAG_YEAR, 12                   # ID3 frame table: TYER, TDAT, TIME (merged into the date)
.equ TAG_DAY, 13
.equ TAG_TIME, 14
.equ TAG_CHAPTER, 15                # ID3 frame table: CHAP
.equ TAG_ARENA, 1 << 17
.equ TAG_VALUE_MAX, 4096
.equ TAG_KEEP, 0                    # first value wins
.equ TAG_REPLACE, 1
.equ TAG_APPEND, 2                  # "old;new"
.equ TAG_FRAME_MAX, 1 << 16         # unsynchronised frame data decoded
.equ TAG_GATHER_MAX, 1 << 24        # Ogg comment packet bytes

RODATA
tag_name_title: .asciz "title"
tag_name_artist: .asciz "artist"
tag_name_album: .asciz "album"
tag_name_album_artist: .asciz "album_artist"
tag_name_date: .asciz "date"
tag_name_track: .asciz "track"
tag_name_disc: .asciz "disc"
tag_name_genre: .asciz "genre"
tag_name_comment: .asciz "comment"
tag_name_composer: .asciz "composer"
.p2align 3
tag_names: .quad tag_name_title, tag_name_artist, tag_name_album, tag_name_album_artist, tag_name_date
    .quad tag_name_track, tag_name_disc, tag_name_genre, tag_name_comment, tag_name_composer

# ID3v2.3/2.4 and ID3v2.2 frame IDs and their keys.
.p2align 2
id3_frames4:
    .ascii "TIT2"
    .long TAG_TITLE
    .ascii "TPE1"
    .long TAG_ARTIST
    .ascii "TALB"
    .long TAG_ALBUM
    .ascii "TPE2"
    .long TAG_ALBUM_ARTIST
    .ascii "TDRC"
    .long TAG_DATE
    .ascii "TYER"
    .long TAG_YEAR
    .ascii "TDAT"
    .long TAG_DAY
    .ascii "TIME"
    .long TAG_TIME
    .ascii "TRCK"
    .long TAG_TRACK
    .ascii "TPOS"
    .long TAG_DISC
    .ascii "TCON"
    .long TAG_GENRE
    .ascii "TCOM"
    .long TAG_COMPOSER
    .ascii "COMM"
    .long TAG_COMMENT_DESCRIBED
    .ascii "TXXX"
    .long TAG_USER
    .ascii "CHAP"
    .long TAG_CHAPTER
    .long 0, 0
id3_frames3:
    .ascii "TT2\0"
    .long TAG_TITLE
    .ascii "TP1\0"
    .long TAG_ARTIST
    .ascii "TAL\0"
    .long TAG_ALBUM
    .ascii "TP2\0"
    .long TAG_ALBUM_ARTIST
    .ascii "TYE\0"
    .long TAG_YEAR
    .ascii "TDA\0"
    .long TAG_DAY
    .ascii "TIM\0"
    .long TAG_TIME
    .ascii "TRK\0"
    .long TAG_TRACK
    .ascii "TPA\0"
    .long TAG_DISC
    .ascii "TCO\0"
    .long TAG_GENRE
    .ascii "TCM\0"
    .long TAG_COMPOSER
    .ascii "COM\0"
    .long TAG_COMMENT_DESCRIBED
    .ascii "TXX\0"
    .long TAG_USER
    .long 0, 0
# RIFF INFO and AIFF text chunks.
riff_info_ids:
    .ascii "INAM"
    .long TAG_TITLE
    .ascii "IART"
    .long TAG_ARTIST
    .ascii "IPRD"
    .long TAG_ALBUM
    .ascii "ICRD"
    .long TAG_DATE
    .ascii "IGNR"
    .long TAG_GENRE
    .ascii "ICMT"
    .long TAG_COMMENT
    .ascii "ITRK"
    .long TAG_TRACK
    .ascii "IPRT"
    .long TAG_TRACK
    .long 0, 0
# AVI: IPRD is the product (FFmpeg's reading), not the album.
avi_info_ids:
    .ascii "INAM"
    .long TAG_TITLE
    .ascii "IART"
    .long TAG_ARTIST
    .ascii "ICRD"
    .long TAG_DATE
    .ascii "IGNR"
    .long TAG_GENRE
    .ascii "ICMT"
    .long TAG_COMMENT
    .ascii "ITRK"
    .long TAG_TRACK
    .ascii "IPRT"
    .long TAG_TRACK
    .long 0, 0
aiff_text_ids:
    .ascii "NAME"
    .long TAG_TITLE
    .ascii "AUTH"
    .long TAG_ARTIST
    .ascii "ANNO"
    .long TAG_COMMENT
    .long 0, 0
# MP4 ilst item types (0xA9 is the copyright sign).
mp4_items:
    .byte 0xa9
    .ascii "nam"
    .long TAG_TITLE
    .byte 0xa9
    .ascii "ART"
    .long TAG_ARTIST
    .byte 0xa9
    .ascii "alb"
    .long TAG_ALBUM
    .ascii "aART"
    .long TAG_ALBUM_ARTIST
    .byte 0xa9
    .ascii "day"
    .long TAG_DATE
    .ascii "trkn"
    .long TAG_TRACK
    .ascii "disk"
    .long TAG_DISC
    .byte 0xa9
    .ascii "gen"
    .long TAG_GENRE
    .ascii "gnre"
    .long TAG_GENRE
    .byte 0xa9
    .ascii "cmt"
    .long TAG_COMMENT
    .byte 0xa9
    .ascii "wrt"
    .long TAG_COMPOSER
    .long 0, 0

# Text keys (case-insensitive): length, key, name. Every format's table
# falls back to the canonical names, as FFmpeg exposes those keys unchanged.
tag_canonical:
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 12, TAG_ALBUM_ARTIST
    .ascii "ALBUM_ARTIST"
    .byte 4, TAG_DATE
    .ascii "DATE"
    .byte 5, TAG_TRACK
    .ascii "TRACK"
    .byte 4, TAG_DISC
    .ascii "DISC"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 7, TAG_COMMENT
    .ascii "COMMENT"
    .byte 8, TAG_COMPOSER
    .ascii "COMPOSER"
    .byte 0
vc_keys:
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 11, TAG_ALBUM_ARTIST
    .ascii "ALBUMARTIST"
    .byte 4, TAG_DATE
    .ascii "DATE"
    .byte 11, TAG_TRACK
    .ascii "TRACKNUMBER"
    .byte 10, TAG_DISC
    .ascii "DISCNUMBER"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 7, TAG_COMMENT
    .ascii "COMMENT"
    .byte 11, TAG_COMMENT
    .ascii "DESCRIPTION"
    .byte 8, TAG_COMPOSER
    .ascii "COMPOSER"
    .byte 0
ape_keys:
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 12, TAG_ALBUM_ARTIST
    .ascii "ALBUM ARTIST"
    .byte 11, TAG_ALBUM_ARTIST
    .ascii "ALBUMARTIST"
    .byte 4, TAG_DATE
    .ascii "YEAR"
    .byte 5, TAG_TRACK
    .ascii "TRACK"
    .byte 4, TAG_DISC
    .ascii "DISC"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 7, TAG_COMMENT
    .ascii "COMMENT"
    .byte 8, TAG_COMPOSER
    .ascii "COMPOSER"
    .byte 0
caf_keys:
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 12, TAG_ALBUM_ARTIST
    .ascii "ALBUM_ARTIST"
    .byte 4, TAG_DATE
    .ascii "YEAR"
    .byte 4, TAG_DATE
    .ascii "DATE"
    .byte 12, TAG_TRACK
    .ascii "TRACK NUMBER"
    .byte 5, TAG_TRACK
    .ascii "TRACK"
    .byte 4, TAG_DISC
    .ascii "DISC"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 8, TAG_COMMENT
    .ascii "COMMENTS"
    .byte 7, TAG_COMMENT
    .ascii "COMMENT"
    .byte 8, TAG_COMPOSER
    .ascii "COMPOSER"
    .byte 0
au_keys:                            # the keys FFmpeg reads from AU annotations
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 5, TAG_TRACK
    .ascii "TRACK"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 0
mkv_keys:
    .byte 5, TAG_TITLE
    .ascii "TITLE"
    .byte 6, TAG_ARTIST
    .ascii "ARTIST"
    .byte 5, TAG_ALBUM
    .ascii "ALBUM"
    .byte 12, TAG_ALBUM_ARTIST
    .ascii "ALBUM_ARTIST"
    .byte 4, TAG_DATE
    .ascii "DATE"
    .byte 11, TAG_TRACK
    .ascii "PART_NUMBER"
    .byte 5, TAG_TRACK
    .ascii "TRACK"
    .byte 4, TAG_DISC
    .ascii "DISC"
    .byte 5, TAG_GENRE
    .ascii "GENRE"
    .byte 7, TAG_COMMENT
    .ascii "COMMENT"
    .byte 8, TAG_COMPOSER
    .ascii "COMPOSER"
    .byte 0
.include "tags_genres.inc"

.data
tag_used: .long 0
.p2align 2
tag_offset: .zero TAG_KEYS*4
tag_length: .zero TAG_KEYS*4        # 0: no value
tag_any: .long 0                    # a value was stored
tag_gather: .quad 0                 # Ogg comment packet buffer
id3_version: .long 0                # of the tag being read
# ID3v2.3 date parts (TYER, TDAT, TIME): the first frame of each, its four
# characters and whether they are all digits.
id3_date_seen: .zero 3
id3_date_valid: .zero 3
.p2align 2
id3_date_text: .zero 12
id3_date: .zero 20

.bss
.p2align 4
tag_arena: .zero TAG_ARENA
tag_scratch: .zero 4*TAG_VALUE_MAX
tag_frame: .zero TAG_FRAME_MAX
tag_number: .zero 32

.text
FN tags_clear
    call chap_clear
    xor eax, eax
    mov [rip + tag_used], eax
    mov [rip + tag_any], eax
    mov word ptr [rip + id3_date_seen], ax
    mov byte ptr [rip + id3_date_seen + 2], al
    lea rcx, [rip + tag_length]
.Ltags_clear_key:
    mov dword ptr [rcx + rax*4], 0
    inc eax
    cmp eax, TAG_KEYS
    jb .Ltags_clear_key
    ret
ENDFN tags_clear

# ECX=key -> RAX=UTF-8 value, EDX=bytes; RAX=0 when the key has none.
FN tags_get
    xor eax, eax
    xor edx, edx
    cmp ecx, TAG_KEYS
    jae .Ltags_get_return
    lea r8, [rip + tag_length]
    mov edx, [r8 + rcx*4]
    test edx, edx
    jz .Ltags_get_return
    lea r8, [rip + tag_offset]
    mov eax, [r8 + rcx*4]
    lea r8, [rip + tag_arena]
    add rax, r8
.Ltags_get_return:
    ret
ENDFN tags_get

# ECX=key, RDX=UTF-8 value, R8D=bytes, R9D=TAG_KEEP/REPLACE/APPEND: stores
# the value up to its first NUL, at most TAG_VALUE_MAX bytes in all.
LOCALFN tag_store
    push rbx
    push rsi
    push rdi
    push r12
    cmp ecx, TAG_KEYS
    jae .Ltag_store_return
    xor eax, eax
.Ltag_store_nul:
    cmp eax, r8d
    jae .Ltag_store_cut
    cmp byte ptr [rdx + rax], 0
    je .Ltag_store_cut
    inc eax
    jmp .Ltag_store_nul
.Ltag_store_cut:
    mov r8d, eax
    test r8d, r8d
    jz .Ltag_store_return
    mov ebx, ecx
    lea r10, [rip + tag_length]
    mov r11d, [r10 + rbx*4]               # existing bytes
    xor r12d, r12d                        # kept prefix: old value and ";"
    test r11d, r11d
    jz .Ltag_store_room
    cmp r9d, TAG_KEEP
    je .Ltag_store_return
    cmp r9d, TAG_APPEND
    jne .Ltag_store_room
    lea r12d, [r11 + 1]
.Ltag_store_room:
    mov eax, TAG_VALUE_MAX
    sub eax, r12d
    jle .Ltag_store_return
    cmp r8d, eax
    jbe .Ltag_store_space
    mov r8d, eax                          # cut at a character boundary
.Ltag_store_boundary:
    test r8d, r8d
    jz .Ltag_store_return
    movzx eax, byte ptr [rdx + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Ltag_store_space
    dec r8d
    jmp .Ltag_store_boundary
.Ltag_store_space:
    mov eax, [rip + tag_used]
    lea ecx, [rax + r12 + 0]
    add ecx, r8d
    cmp ecx, TAG_ARENA
    ja .Ltag_store_return
    lea rdi, [rip + tag_arena]
    add rdi, rax
    test r12d, r12d
    jz .Ltag_store_new
    lea rsi, [rip + tag_offset]
    mov esi, [rsi + rbx*4]
    lea r10, [rip + tag_arena]
    add rsi, r10
    mov ecx, r11d
    rep movsb
    mov byte ptr [rdi], ';'
    inc rdi
.Ltag_store_new:
    mov rsi, rdx
    mov ecx, r8d
    rep movsb
    lea r10, [rip + tag_offset]
    mov [r10 + rbx*4], eax
    lea ecx, [r12 + r8]
    lea r10, [rip + tag_length]
    mov [r10 + rbx*4], ecx
    add eax, ecx
    mov [rip + tag_used], eax
    mov dword ptr [rip + tag_any], 1
.Ltag_store_return:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN tag_store

# RCX=table of (length, key, name) entries, RDX=name, R8D=bytes -> EAX=key
# (ASCII case-insensitive match), -1 for none.
LOCALFN tag_match
    push rbx
    push rsi
.Ltag_match_entry:
    movzx r9d, byte ptr [rcx]
    test r9d, r9d
    jz .Ltag_match_none
    lea rsi, [rcx + 2]
    cmp r9d, r8d
    jne .Ltag_match_next
    xor r10d, r10d
.Ltag_match_char:
    cmp r10d, r9d
    jae .Ltag_match_found
    movzx eax, byte ptr [rdx + r10]
    lea r11d, [rax - 'a']
    cmp r11d, 25
    ja .Ltag_match_upper
    sub eax, 32
.Ltag_match_upper:
    movzx ebx, byte ptr [rsi + r10]
    cmp eax, ebx
    jne .Ltag_match_next
    inc r10d
    jmp .Ltag_match_char
.Ltag_match_found:
    movzx eax, byte ptr [rcx + 1]
    jmp .Ltag_match_return
.Ltag_match_next:
    lea rcx, [rsi + r9]
    jmp .Ltag_match_entry
.Ltag_match_none:
    mov eax, -1
.Ltag_match_return:
    pop rsi
    pop rbx
    ret
ENDFN tag_match

# RCX=table, RDX=name, R8D=bytes -> EAX=key from the table or the canonical
# names, -1 for none.
LOCALFN tag_lookup
    push rdx
    push r8
    call tag_match
    pop r8
    pop rdx
    cmp eax, -1
    jne .Ltag_lookup_return
    lea rcx, [rip + tag_canonical]
    call tag_match
.Ltag_lookup_return:
    ret
ENDFN tag_lookup

# RCX=table of (FourCC, key) pairs, EDX=FourCC -> EAX=key, -1 for none.
LOCALFN tag_fourcc
.Ltag_fourcc_entry:
    mov eax, [rcx]
    test eax, eax
    jz .Ltag_fourcc_none
    cmp eax, edx
    je .Ltag_fourcc_found
    add rcx, 8
    jmp .Ltag_fourcc_entry
.Ltag_fourcc_found:
    mov eax, [rcx + 4]
    ret
.Ltag_fourcc_none:
    mov eax, -1
    ret
ENDFN tag_fourcc

# ECX=genre number -> RAX=its ID3v1 name, EDX=bytes; RAX=0 above the list.
LOCALFN tag_genre_name
    xor eax, eax
    xor edx, edx
    cmp ecx, GENRE_COUNT
    jae .Ltag_genre_return
    lea r8, [rip + genre_offsets]
    movzx eax, word ptr [r8 + rcx*2]
    movzx edx, word ptr [r8 + rcx*2 + 2]
    sub edx, eax
    lea r8, [rip + genre_names]
    add rax, r8
.Ltag_genre_return:
    ret
ENDFN tag_genre_name

# EAX=value -> RAX=tag_number holding its decimal digits, EDX=bytes.
# Preserves RCX, R8-R11.
LOCALFN tag_decimal
    push rcx
    push rbx
    lea rbx, [rip + tag_number + 31]
    mov ecx, 10
.Ltag_decimal_digit:
    xor edx, edx
    div ecx
    add edx, '0'
    mov [rbx], dl
    dec rbx
    test eax, eax
    jnz .Ltag_decimal_digit
    lea rax, [rbx + 1]
    lea rdx, [rip + tag_number + 32]
    sub rdx, rax
    pop rbx
    pop rcx
    ret
ENDFN tag_decimal

# ---------------------------------------------------------------- text
# RCX=Latin-1 text, EDX=bytes -> RAX=tag_scratch, EDX=UTF-8 bytes, R8D=input
# consumed (through a NUL terminator).
LOCALFN tag_latin1
    push rsi
    push rdi
    mov rsi, rcx
    lea rdi, [rip + tag_scratch]
    xor r8d, r8d
    cmp edx, TAG_VALUE_MAX
    jbe .Ltag_latin1_char
    mov edx, TAG_VALUE_MAX
.Ltag_latin1_char:
    cmp r8d, edx
    jae .Ltag_latin1_done
    movzx eax, byte ptr [rsi + r8]
    inc r8d
    test eax, eax
    jz .Ltag_latin1_done
    cmp eax, 0x80
    jae .Ltag_latin1_two
    mov [rdi], al
    inc rdi
    jmp .Ltag_latin1_char
.Ltag_latin1_two:
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xc0
    mov [rdi], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdi + 1], al
    add rdi, 2
    jmp .Ltag_latin1_char
.Ltag_latin1_done:
    lea rax, [rip + tag_scratch]
    mov rdx, rdi
    sub rdx, rax
    pop rdi
    pop rsi
    ret
ENDFN tag_latin1

# RCX=UTF-16 text, EDX=bytes, R8D=1 big-endian, 0 little-endian -> RAX=
# tag_scratch, EDX=UTF-8 bytes, R8D=input consumed (through a zero unit).
# An unpaired surrogate ends the text.
LOCALFN tag_utf16
    push rbx
    push rsi
    push rdi
    push r12
    mov rsi, rcx
    lea rdi, [rip + tag_scratch]
    mov r12d, r8d
    xor r8d, r8d
    cmp edx, 2*TAG_VALUE_MAX
    jbe .Ltag_utf16_unit
    mov edx, 2*TAG_VALUE_MAX
.Ltag_utf16_unit:
    lea eax, [r8 + 2]
    cmp eax, edx
    ja .Ltag_utf16_done
    movzx eax, word ptr [rsi + r8]
    add r8d, 2
    test r12d, r12d
    jz .Ltag_utf16_ordered
    rol ax, 8
.Ltag_utf16_ordered:
    test eax, eax
    jz .Ltag_utf16_done
    lea ecx, [rax - 0xd800]
    cmp ecx, 0x800
    jae .Ltag_utf16_point
    cmp ecx, 0x400
    jae .Ltag_utf16_done                  # a low surrogate first
    lea ebx, [r8 + 2]
    cmp ebx, edx
    ja .Ltag_utf16_done
    movzx ebx, word ptr [rsi + r8]
    add r8d, 2
    test r12d, r12d
    jz .Ltag_utf16_low
    rol bx, 8
.Ltag_utf16_low:
    sub ebx, 0xdc00
    cmp ebx, 0x3ff
    ja .Ltag_utf16_done
    shl ecx, 10
    lea eax, [rcx + rbx + 0x10000]
.Ltag_utf16_point:
    cmp eax, 0x80
    jae .Ltag_utf16_two
    mov [rdi], al
    inc rdi
    jmp .Ltag_utf16_unit
.Ltag_utf16_two:
    cmp eax, 0x800
    jae .Ltag_utf16_three
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xc0
    mov [rdi], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdi + 1], al
    add rdi, 2
    jmp .Ltag_utf16_unit
.Ltag_utf16_three:
    cmp eax, 0x10000
    jae .Ltag_utf16_four
    mov ecx, eax
    shr ecx, 12
    or ecx, 0xe0
    mov [rdi], cl
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdi + 1], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdi + 2], al
    add rdi, 3
    jmp .Ltag_utf16_unit
.Ltag_utf16_four:
    mov ecx, eax
    shr ecx, 18
    or ecx, 0xf0
    mov [rdi], cl
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdi + 1], cl
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdi + 2], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdi + 3], al
    add rdi, 4
    jmp .Ltag_utf16_unit
.Ltag_utf16_done:
    lea rax, [rip + tag_scratch]
    mov rdx, rdi
    sub rdx, rax
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN tag_utf16

# ECX=ID3v2 text encoding, RDX=text, R8D=bytes -> RAX=UTF-8 (0 for an
# invalid encoding or byte order mark), EDX=bytes, R8D=input consumed.
LOCALFN id3_string
    sub rsp, 40
    mov eax, ecx
    mov rcx, rdx
    mov edx, r8d
    test eax, eax
    jz .Lid3_string_latin1
    cmp eax, 3
    je .Lid3_string_utf8
    cmp eax, 2
    je .Lid3_string_be
    cmp eax, 1
    jne .Lid3_string_bad
    cmp edx, 2
    jb .Lid3_string_bad
    movzx eax, word ptr [rcx]
    add rcx, 2
    sub edx, 2
    xor r8d, r8d
    cmp eax, 0xfeff                       # bytes FF FE: little-endian
    je .Lid3_string_bom
    mov r8d, 1
    cmp eax, 0xfffe                       # bytes FE FF: big-endian
    jne .Lid3_string_bad
.Lid3_string_bom:
    call tag_utf16
    add r8d, 2
    jmp .Lid3_string_return
.Lid3_string_be:
    mov r8d, 1
    call tag_utf16
    jmp .Lid3_string_return
.Lid3_string_latin1:
    call tag_latin1
    jmp .Lid3_string_return
.Lid3_string_utf8:
    xor r8d, r8d                          # the text itself, to its NUL
.Lid3_string_utf8_byte:
    cmp r8d, edx
    jae .Lid3_string_utf8_done
    cmp byte ptr [rcx + r8], 0
    je .Lid3_string_utf8_nul
    inc r8d
    jmp .Lid3_string_utf8_byte
.Lid3_string_utf8_nul:
    mov rax, rcx
    mov edx, r8d
    inc r8d
    jmp .Lid3_string_return
.Lid3_string_utf8_done:
    mov rax, rcx
    mov edx, r8d
    jmp .Lid3_string_return
.Lid3_string_bad:
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
.Lid3_string_return:
    add rsp, 40
    ret
ENDFN id3_string

# RAX=genre text, EDX=bytes -> RAX/EDX replaced by the ID3v1 name of "(N)" or
# "N" (after white space and a sign, as FFmpeg's sscanf reads it).
LOCALFN id3_genre
    push rbx
    push rsi
    mov rsi, rax
    mov ebx, edx
    xor ecx, ecx                          # position
    test ebx, ebx
    jz .Lid3_genre_keep
    cmp byte ptr [rsi], '('
    jne .Lid3_genre_parse
    mov ecx, 1
    call .Lid3_genre_number
    test r8d, r8d
    jnz .Lid3_genre_found
    xor ecx, ecx
.Lid3_genre_parse:
    call .Lid3_genre_number
    test r8d, r8d
    jz .Lid3_genre_keep
.Lid3_genre_found:
    test r9d, r9d
    jnz .Lid3_genre_keep                  # negative
    cmp r10d, GENRE_COUNT
    jae .Lid3_genre_keep
    mov ecx, r10d
    call tag_genre_name
    jmp .Lid3_genre_return
.Lid3_genre_keep:
    mov rax, rsi
    mov edx, ebx
.Lid3_genre_return:
    pop rsi
    pop rbx
    ret
# ECX=position -> R8D=digits read, R9D=1 when negative, R10D=value (capped).
.Lid3_genre_number:
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
.Lid3_genre_space:
    cmp ecx, ebx
    jae .Lid3_genre_number_return
    movzx eax, byte ptr [rsi + rcx]
    cmp eax, ' '
    je .Lid3_genre_skip
    lea edx, [rax - 9]                    # \t \n \v \f \r
    cmp edx, 4
    ja .Lid3_genre_sign
.Lid3_genre_skip:
    inc ecx
    jmp .Lid3_genre_space
.Lid3_genre_sign:
    cmp eax, '+'
    je .Lid3_genre_signed
    cmp eax, '-'
    jne .Lid3_genre_digit
    mov r9d, 1
.Lid3_genre_signed:
    inc ecx
.Lid3_genre_digit:
    cmp ecx, ebx
    jae .Lid3_genre_number_return
    movzx eax, byte ptr [rsi + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lid3_genre_number_return
    inc r8d
    imul r10d, r10d, 10
    add r10d, eax
    cmp r10d, 1000000
    jb .Lid3_genre_next
    mov r10d, 1000000
.Lid3_genre_next:
    inc ecx
    jmp .Lid3_genre_digit
.Lid3_genre_number_return:
    ret
ENDFN id3_genre

# ECX=key (or TAG_COMMENT_DESCRIBED), RDX=frame data, R8D=bytes: an ID3v2
# text frame's first string, or a COMM frame without a description.
LOCALFN id3_frame
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov ebx, ecx
    mov rsi, rdx
    mov edi, r8d
    cmp ebx, TAG_COMMENT_DESCRIBED
    je .Lid3_frame_comment
    cmp ebx, TAG_USER
    je .Lid3_frame_user
    cmp ebx, TAG_CHAPTER
    je .Lid3_frame_chapter
    test edi, edi
    jz .Lid3_frame_return
    movzx ecx, byte ptr [rsi]
    lea rdx, [rsi + 1]
    lea r8d, [rdi - 1]
    call id3_string
    test rax, rax
    jz .Lid3_frame_return
    cmp ebx, TAG_YEAR
    jae .Lid3_frame_date
    cmp ebx, TAG_GENRE
    jne .Lid3_frame_store
    call id3_genre
.Lid3_frame_store:
    mov ecx, ebx
    mov r8d, edx
    mov rdx, rax
    mov r9d, TAG_KEEP
    call tag_store
    jmp .Lid3_frame_return
.Lid3_frame_comment:
    cmp edi, 4                            # encoding, language
    jb .Lid3_frame_return
    movzx ecx, byte ptr [rsi]
    mov [rsp + 32], ecx
    lea rdx, [rsi + 4]
    lea r8d, [rdi - 4]
    call id3_string                       # the description
    test rax, rax
    jz .Lid3_frame_return
    test edx, edx
    jnz .Lid3_frame_return                # described comments keep their own keys
    lea rdx, [rsi + 4 + r8]
    lea eax, [rdi - 4]
    sub eax, r8d
    jbe .Lid3_frame_return
    mov r8d, eax
    mov ecx, [rsp + 32]
    call id3_string
    test rax, rax
    jz .Lid3_frame_return
    mov ecx, TAG_COMMENT
    mov r8d, edx
    mov rdx, rax
    mov r9d, TAG_KEEP
    call tag_store
    jmp .Lid3_frame_return
.Lid3_frame_date:
    # The first TYER, TDAT or TIME: four digits, or it spoils its part.
    lea ecx, [rbx - TAG_YEAR]
    lea r8, [rip + id3_date_seen]
    cmp byte ptr [r8 + rcx], 0
    jne .Lid3_frame_return
    mov byte ptr [r8 + rcx], 1
    cmp edx, 4
    jne .Lid3_frame_return
    xor r9d, r9d
.Lid3_frame_digit:
    movzx r10d, byte ptr [rax + r9]
    sub r10d, '0'
    cmp r10d, 9
    ja .Lid3_frame_return
    inc r9d
    cmp r9d, 4
    jb .Lid3_frame_digit
    mov r10d, [rax]
    lea r8, [rip + id3_date_text]
    mov [r8 + rcx*4], r10d
    lea r8, [rip + id3_date_valid]
    mov byte ptr [r8 + rcx], 1
    jmp .Lid3_frame_return
.Lid3_frame_chapter:
    mov rdx, rsi
    mov r8d, edi
    mov r9d, [rip + id3_version]
    cmp r9d, 3
    jb .Lid3_frame_return
    call id3_chapter
    jmp .Lid3_frame_return
.Lid3_frame_user:
    # TXXX: a description naming one of the keys, then the value.
    test edi, edi
    jz .Lid3_frame_return
    movzx ecx, byte ptr [rsi]
    mov [rsp + 32], ecx
    lea rdx, [rsi + 1]
    lea r8d, [rdi - 1]
    call id3_string
    test rax, rax
    jz .Lid3_frame_return
    mov [rsp + 36], r8d                   # consumed
    lea rcx, [rip + tag_canonical]
    mov r8d, edx
    mov rdx, rax
    call tag_match
    cmp eax, -1
    je .Lid3_frame_return
    mov ebx, eax
    mov r8d, [rsp + 36]
    lea rdx, [rsi + 1 + r8]
    lea eax, [rdi - 1]
    sub eax, r8d
    jbe .Lid3_frame_return
    mov r8d, eax
    mov ecx, [rsp + 32]
    call id3_string
    test rax, rax
    jz .Lid3_frame_return
    jmp .Lid3_frame_store
.Lid3_frame_return:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN id3_frame

# After ID3v2 tags: a four-digit TYER becomes the date "YYYY", with a
# four-digit TDAT (DDMM) "YYYY-MM-DD" and then a TIME (HHMM) " HH:MM" (as
# FFmpeg merges them).
LOCALFN id3_finish
    sub rsp, 40
    cmp byte ptr [rip + id3_date_valid], 0
    je .Lid3_finish_return
    lea rdx, [rip + id3_date]
    mov eax, [rip + id3_date_text]
    mov [rdx], eax
    mov r8d, 4
    cmp byte ptr [rip + id3_date_valid + 1], 0
    je .Lid3_finish_store
    mov byte ptr [rdx + 4], '-'
    mov ax, [rip + id3_date_text + 6]     # MM
    mov [rdx + 5], ax
    mov byte ptr [rdx + 7], '-'
    mov ax, [rip + id3_date_text + 4]     # DD
    mov [rdx + 8], ax
    mov r8d, 10
    cmp byte ptr [rip + id3_date_valid + 2], 0
    je .Lid3_finish_store
    mov byte ptr [rdx + 10], ' '
    mov ax, [rip + id3_date_text + 8]     # HH
    mov [rdx + 11], ax
    mov byte ptr [rdx + 13], ':'
    mov ax, [rip + id3_date_text + 10]    # MM
    mov [rdx + 14], ax
    mov r8d, 16
.Lid3_finish_store:
    mov ecx, TAG_DATE
    mov r9d, TAG_REPLACE
    call tag_store
.Lid3_finish_return:
    xor eax, eax
    mov word ptr [rip + id3_date_seen], ax
    mov byte ptr [rip + id3_date_seen + 2], al
    mov word ptr [rip + id3_date_valid], ax
    mov byte ptr [rip + id3_date_valid + 2], al
    add rsp, 40
    ret
ENDFN id3_finish

# RCX=four synchsafe bytes -> EAX=value (high bits ignored).
LOCALFN id3_synchsafe
    xor eax, eax
    xor edx, edx
.Lid3_synchsafe_byte:
    shl eax, 7
    movzx r8d, byte ptr [rcx + rdx]
    and r8d, 0x7f
    or eax, r8d
    inc edx
    cmp edx, 4
    jb .Lid3_synchsafe_byte
    ret
ENDFN id3_synchsafe

# RCX=tag ("ID3"), RDX=end -> EAX=the tag's bytes (header, frames, footer),
# 0 when no ID3v2 tag starts there. Stores its frames.
LOCALFN id3_parse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    mov rax, rdi
    sub rax, rsi
    cmp rax, 10
    jb .Lid3_none
    cmp word ptr [rsi], 0x4449            # "ID"
    jne .Lid3_none
    cmp byte ptr [rsi + 2], '3'
    jne .Lid3_none
    movzx r12d, byte ptr [rsi + 3]        # version
    mov [rip + id3_version], r12d
    cmp r12d, 2
    jb .Lid3_none
    cmp r12d, 4
    ja .Lid3_none
    cmp byte ptr [rsi + 4], 0xff
    je .Lid3_none
    movzx r13d, byte ptr [rsi + 5]        # flags
    mov eax, [rsi + 6]
    test eax, 0x80808080
    jnz .Lid3_none
    lea rcx, [rsi + 6]
    call id3_synchsafe
    lea r14, [rsi + 10]                   # frames
    lea r15, [r14 + rax]                  # their end
    cmp r15, rdi
    jbe .Lid3_sized
    mov r15, rdi
.Lid3_sized:
    add eax, 10
    cmp r12d, 4
    jne .Lid3_total
    test r13d, 0x10
    jz .Lid3_total
    add eax, 10                           # footer
.Lid3_total:
    mov [rsp + 40], eax
    cmp r12d, 2
    jne .Lid3_extended
    test r13d, 0x40
    jnz .Lid3_done                        # a compressed ID3v2.2 tag
    jmp .Lid3_frame
.Lid3_extended:
    test r13d, 0x40
    jz .Lid3_frame
    lea rax, [r14 + 4]
    cmp rax, r15
    ja .Lid3_done
    cmp r12d, 3
    jne .Lid3_extended4
    mov eax, [r14]
    bswap eax
    lea r14, [r14 + rax + 4]              # its size excludes itself
    jmp .Lid3_extended_end
.Lid3_extended4:
    mov rcx, r14
    call id3_synchsafe
    cmp eax, 6
    jb .Lid3_done
    add r14, rax
.Lid3_extended_end:
    cmp r14, r15
    ja .Lid3_done
.Lid3_frame:
    mov rax, r15
    sub rax, r14
    cmp r12d, 2
    jne .Lid3_frame4
    cmp rax, 6
    jb .Lid3_done
    cmp byte ptr [r14], 0
    je .Lid3_done                         # padding
    movzx edx, word ptr [r14]
    movzx eax, byte ptr [r14 + 2]
    shl eax, 16
    or edx, eax                           # the three-character ID
    mov eax, [r14 + 2]
    bswap eax
    and eax, 0xffffff                     # size
    lea rbx, [r14 + 6]                    # data
    xor r8d, r8d                          # format flags
    jmp .Lid3_frame_sized
.Lid3_frame4:
    cmp rax, 10
    jb .Lid3_done
    cmp byte ptr [r14], 0
    je .Lid3_done
    mov edx, [r14]
    cmp r12d, 3
    jne .Lid3_frame_synchsafe
    mov eax, [r14 + 4]
    bswap eax
    jmp .Lid3_frame_flags
.Lid3_frame_synchsafe:
    mov [rsp + 32], edx
    lea rcx, [r14 + 4]
    call id3_synchsafe
    mov edx, [rsp + 32]
.Lid3_frame_flags:
    movzx r8d, byte ptr [r14 + 9]
    lea rbx, [r14 + 10]
.Lid3_frame_sized:
    mov r9, r15
    sub r9, rbx
    cmp rax, r9
    ja .Lid3_done                         # beyond the tag
    lea r14, [rbx + rax]                  # next frame
    mov [rsp + 32], eax                   # data bytes
    mov [rsp + 36], r8d
    lea rcx, [rip + id3_frames4]
    cmp r12d, 2
    jne .Lid3_frame_lookup
    lea rcx, [rip + id3_frames3]
.Lid3_frame_lookup:
    call tag_fourcc
    cmp eax, -1
    je .Lid3_frame
    mov r9d, eax                          # key
    mov r8d, [rsp + 36]
    mov eax, [rsp + 32]
    xor r10d, r10d                        # unsynchronised
    test r13d, 0x80
    setnz r10b
    cmp r12d, 3
    jne .Lid3_frame_v4
    test r8d, 0xc0                        # compressed, encrypted
    jnz .Lid3_frame
    test r8d, 0x20                        # grouping identity
    jz .Lid3_frame_read
    test eax, eax
    jz .Lid3_frame
    inc rbx
    dec eax
    jmp .Lid3_frame_read
.Lid3_frame_v4:
    cmp r12d, 4
    jne .Lid3_frame_read
    test r8d, 0x0c                        # compressed, encrypted
    jnz .Lid3_frame
    test r8d, 0x02
    jz .Lid3_frame_group
    mov r10d, 1
.Lid3_frame_group:
    test r8d, 0x40
    jz .Lid3_frame_length
    test eax, eax
    jz .Lid3_frame
    inc rbx
    dec eax
.Lid3_frame_length:
    test r8d, 0x01                        # data length indicator
    jz .Lid3_frame_read
    cmp eax, 4
    jb .Lid3_frame
    add rbx, 4
    sub eax, 4
.Lid3_frame_read:
    mov rdx, rbx
    test r10d, r10d
    jz .Lid3_frame_text
    # Undo unsynchronisation (FF 00 -> FF) into tag_frame.
    lea r11, [rip + tag_frame]
    xor ecx, ecx                          # in
    xor edx, edx                          # out
.Lid3_unsync_byte:
    cmp ecx, eax
    jae .Lid3_unsync_done
    cmp edx, TAG_FRAME_MAX
    jae .Lid3_unsync_done
    movzx r8d, byte ptr [rbx + rcx]
    mov [r11 + rdx], r8b
    inc ecx
    inc edx
    cmp r8d, 0xff
    jne .Lid3_unsync_byte
    cmp ecx, eax
    jae .Lid3_unsync_done
    cmp byte ptr [rbx + rcx], 0
    jne .Lid3_unsync_byte
    inc ecx
    jmp .Lid3_unsync_byte
.Lid3_unsync_done:
    mov eax, edx
    mov rdx, r11
.Lid3_frame_text:
    mov ecx, r9d
    mov r8d, eax
    call id3_frame
    jmp .Lid3_frame
.Lid3_done:
    mov eax, [rsp + 40]
    jmp .Lid3_return
.Lid3_none:
    xor eax, eax
.Lid3_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN id3_parse

# RCX=text, EDX=bytes -> EAX=1 when it is valid UTF-8 (to a NUL).
LOCALFN tag_utf8_valid
    xor r8d, r8d
.Ltag_utf8_char:
    cmp r8d, edx
    jae .Ltag_utf8_yes
    movzx eax, byte ptr [rcx + r8]
    test eax, eax
    jz .Ltag_utf8_yes
    inc r8d
    cmp eax, 0x80
    jb .Ltag_utf8_char
    xor r9d, r9d
    cmp eax, 0xc2
    jb .Ltag_utf8_no
    mov r9d, 1
    cmp eax, 0xe0
    jb .Ltag_utf8_continue
    mov r9d, 2
    cmp eax, 0xf0
    jb .Ltag_utf8_continue
    mov r9d, 3
    cmp eax, 0xf4
    ja .Ltag_utf8_no
.Ltag_utf8_continue:
    cmp r8d, edx
    jae .Ltag_utf8_no
    movzx eax, byte ptr [rcx + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Ltag_utf8_no
    inc r8d
    dec r9d
    jnz .Ltag_utf8_continue
    jmp .Ltag_utf8_char
.Ltag_utf8_yes:
    mov eax, 1
    ret
.Ltag_utf8_no:
    xor eax, eax
    ret
ENDFN tag_utf8_valid

# RCX=field, EDX=bytes, R8D=key: an ID3v1 field to a NUL, trailing spaces
# removed; kept as it is when it is valid UTF-8 (as FFmpeg keeps every field),
# otherwise read as Latin-1.
LOCALFN id3v1_field
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, r8d
    mov rsi, rcx
    mov edi, edx
    call tag_utf8_valid
    test eax, eax
    jz .Lid3v1_latin1
    mov rax, rsi
    xor edx, edx
.Lid3v1_length:
    cmp edx, edi
    jae .Lid3v1_trim
    cmp byte ptr [rsi + rdx], 0
    je .Lid3v1_trim
    inc edx
    jmp .Lid3v1_length
.Lid3v1_latin1:
    mov rcx, rsi
    mov edx, edi
    call tag_latin1
.Lid3v1_trim:
    test edx, edx
    jz .Lid3v1_field_return
    cmp byte ptr [rax + rdx - 1], ' '
    jne .Lid3v1_store
    dec edx
    jmp .Lid3v1_trim
.Lid3v1_store:
    mov ecx, ebx
    mov r8d, edx
    mov rdx, rax
    mov r9d, TAG_KEEP
    call tag_store
.Lid3v1_field_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN id3v1_field

# RCX=128-byte ID3v1 tag ("TAG").
LOCALFN id3v1_parse
    push rsi
    sub rsp, 32
    mov rsi, rcx
    lea rcx, [rsi + 3]
    mov edx, 30
    mov r8d, TAG_TITLE
    call id3v1_field
    lea rcx, [rsi + 33]
    mov edx, 30
    mov r8d, TAG_ARTIST
    call id3v1_field
    lea rcx, [rsi + 63]
    mov edx, 30
    mov r8d, TAG_ALBUM
    call id3v1_field
    lea rcx, [rsi + 93]
    mov edx, 4
    mov r8d, TAG_DATE
    call id3v1_field
    lea rcx, [rsi + 97]
    mov edx, 30
    mov r8d, TAG_COMMENT
    call id3v1_field
    cmp byte ptr [rsi + 125], 0           # ID3v1.1 track number
    jne .Lid3v1_genre
    movzx eax, byte ptr [rsi + 126]
    test eax, eax
    jz .Lid3v1_genre
    call tag_decimal
    mov r8d, edx
    mov rdx, rax
    mov ecx, TAG_TRACK
    mov r9d, TAG_KEEP
    call tag_store
.Lid3v1_genre:
    movzx ecx, byte ptr [rsi + 127]
    call tag_genre_name
    test rax, rax
    jz .Lid3v1_return
    mov r8d, edx
    mov rdx, rax
    mov ecx, TAG_GENRE
    mov r9d, TAG_KEEP
    call tag_store
.Lid3v1_return:
    add rsp, 32
    pop rsi
    ret
ENDFN id3v1_parse

# RCX=footer ("APETAGEX"), RDX=file start: an APEv2 (or v1) tag's text
# items fill keys ID3v2 left empty.
LOCALFN ape_parse
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rdi, rcx                          # items end at the footer
    mov rax, 0x5845474154455041           # "APETAGEX"
    cmp [rdi], rax
    jne .Lape_return
    mov eax, [rdi + 12]                   # items and footer
    cmp eax, 32
    jb .Lape_return
    mov rsi, rdi
    add rsi, 32
    sub rsi, rax                          # first item
    cmp rsi, rdx
    jb .Lape_return
    mov r12d, [rdi + 16]                  # items
.Lape_item:
    test r12d, r12d
    jz .Lape_return
    dec r12d
    mov rax, rdi
    sub rax, rsi
    cmp rax, 9
    jb .Lape_return
    mov r13d, [rsi]                       # value bytes
    mov ebx, [rsi + 4]                    # flags
    lea rcx, [rsi + 8]                    # key, to a NUL
    mov rdx, rcx
.Lape_key:
    cmp rdx, rdi
    jae .Lape_return
    cmp byte ptr [rdx], 0
    je .Lape_value
    inc rdx
    jmp .Lape_key
.Lape_value:
    lea r8, [rdx + 1]                     # value
    mov rax, rdi
    sub rax, r8
    cmp r13, rax
    ja .Lape_return
    lea rsi, [r8 + r13]                   # next item
    shr ebx, 1
    and ebx, 3
    jnz .Lape_item                        # binary or a link
    mov [rsp + 32], r8
    mov r8, rdx
    sub r8, rcx                           # key bytes
    mov rdx, rcx
    lea rcx, [rip + ape_keys]
    call tag_lookup
    cmp eax, -1
    je .Lape_item
    mov ecx, eax
    mov rdx, [rsp + 32]
    mov r8d, r13d
    mov r9d, TAG_KEEP
    call tag_store
    jmp .Lape_item
.Lape_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_parse

# RCX=Vorbis comment header (after any packet prefix), RDX=end.
LOCALFN vc_parse
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jb .Lvc_return
    mov eax, [rsi]                        # vendor
    lea rsi, [rsi + rax + 4]
    mov rax, rdi
    sub rax, rsi
    cmp rax, 4
    jl .Lvc_return
    mov r12d, [rsi]                       # comments
    add rsi, 4
.Lvc_comment:
    test r12d, r12d
    jz .Lvc_return
    dec r12d
    mov rax, rdi
    sub rax, rsi
    cmp rax, 4
    jb .Lvc_return
    mov ebx, [rsi]
    add rsi, 4
    sub rax, 4
    cmp rbx, rax
    ja .Lvc_return
    xor edx, edx                          # "KEY=value"
.Lvc_equals:
    cmp edx, ebx
    jae .Lvc_next
    cmp byte ptr [rsi + rdx], '='
    je .Lvc_key
    inc edx
    jmp .Lvc_equals
.Lvc_key:
    mov [rsp + 32], edx
    mov rcx, rsi                          # CHAPTERnnn comments are chapters
    lea r8, [rsi + rdx + 1]
    mov r9d, ebx
    sub r9d, edx
    dec r9d
    call vc_chapter
    test eax, eax
    jnz .Lvc_next
    mov edx, [rsp + 32]
    mov r8d, edx
    mov rdx, rsi
    lea rcx, [rip + vc_keys]
    call tag_lookup
    cmp eax, -1
    je .Lvc_next
    mov ecx, eax
    mov edx, [rsp + 32]
    mov r8d, ebx
    sub r8d, edx
    dec r8d
    lea rdx, [rsi + rdx + 1]
    mov r9d, TAG_APPEND
    call tag_store
.Lvc_next:
    add rsi, rbx
    jmp .Lvc_comment
.Lvc_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vc_parse

# RCX=native FLAC file ("fLaC"), RDX=end: the first VORBIS_COMMENT block and
# CUESHEET chapters.
LOCALFN flac_tags
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    lea rsi, [rcx + 4]
    mov rdi, rdx
    xor ebx, ebx                          # sample rate (STREAMINFO)
    xor r12d, r12d                        # comments read
.Lflac_tags_block:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 4
    jl .Lflac_tags_return
    mov eax, [rsi]
    bswap eax
    mov ecx, eax
    and eax, 0xffffff                     # length
    shr ecx, 24                           # last flag, type
    lea rdx, [rsi + 4]
    lea rsi, [rdx + rax]
    cmp rsi, rdi
    ja .Lflac_tags_return
    mov [rsp + 32], ecx
    and ecx, 0x7f
    jz .Lflac_tags_info
    cmp ecx, 5
    je .Lflac_tags_cuesheet
    cmp ecx, 4
    jne .Lflac_tags_next
    test r12d, r12d
    jnz .Lflac_tags_next
    inc r12d
    mov rcx, rdx
    mov rdx, rsi
    call vc_parse
    jmp .Lflac_tags_next
.Lflac_tags_info:
    cmp eax, 13
    jb .Lflac_tags_next
    mov ebx, [rdx + 10]
    bswap ebx
    shr ebx, 12                           # 20-bit sample rate
    jmp .Lflac_tags_next
.Lflac_tags_cuesheet:
    test ebx, ebx
    jz .Lflac_tags_next
    mov rcx, rdx
    mov rdx, rsi
    mov r8d, ebx
    call flac_cuesheet
.Lflac_tags_next:
    test dword ptr [rsp + 32], 0x80
    jz .Lflac_tags_block
.Lflac_tags_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_tags

# RCX=Ogg page, RDX=end -> EAX=page bytes (0 when no whole page is there),
# RCX=its data, EDX=segments.
LOCALFN ogg_page
    mov rax, rdx
    sub rax, rcx
    cmp rax, 27
    jl .Logg_page_none
    cmp dword ptr [rcx], 0x5367674f       # OggS
    jne .Logg_page_none
    movzx r8d, byte ptr [rcx + 26]
    lea r9, [r8 + 27]
    cmp r9, rax
    ja .Logg_page_none
    xor r10d, r10d                        # data bytes
    xor r11d, r11d
.Logg_page_lace:
    cmp r11d, r8d
    jae .Logg_page_sized
    movzx edx, byte ptr [rcx + r11 + 27]
    add r10d, edx
    inc r11d
    jmp .Logg_page_lace
.Logg_page_sized:
    lea rdx, [r9 + r10]
    cmp rdx, rax
    ja .Logg_page_none
    mov eax, edx
    mov edx, r8d
    lea rcx, [rcx + r9]
    ret
.Logg_page_none:
    xor eax, eax
    ret
ENDFN ogg_page

# RCX=file ("OggS"), RDX=end: the comment packet of the first Vorbis, Opus
# or FLAC stream.
LOCALFN ogg_tags
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    # The first beginning-of-stream page with a known identification header.
.Logg_tags_bos:
    mov rcx, rsi
    mov rdx, rdi
    call ogg_page
    test eax, eax
    jz .Logg_tags_return
    test byte ptr [rsi + 5], 2
    jz .Logg_tags_return                  # past the beginning pages
    mov r8, rsi
    add rsi, rax
    test edx, edx
    jz .Logg_tags_bos
    movzx eax, byte ptr [r8 + 27]         # first packet's first segment
    cmp eax, 8
    jb .Logg_tags_bos
    mov rax, [rcx]
    mov r9, 0x736962726f7601              # "\1vorbis"
    mov r10, 0x00ffffffffffffff
    and r10, rax
    cmp r10, r9
    mov r12d, 1
    je .Logg_tags_found
    mov r9, 0x646165487375704f            # "OpusHead"
    cmp rax, r9
    mov r12d, 2
    je .Logg_tags_found
    mov r9d, 0x43414c46                   # "\x7fFLAC"
    cmp byte ptr [rcx], 0x7f
    jne .Logg_tags_bos
    cmp [rcx + 1], r9d
    mov r12d, 3
    jne .Logg_tags_bos
.Logg_tags_found:
    mov r13d, [r8 + 14]                   # serial
    mov rsi, r8
    # Two passes over the stream's pages: measure packet 1, then copy it.
    xor r15d, r15d                        # pass
    mov qword ptr [rsp + 32], 0           # bytes
.Logg_tags_pass:
    mov rbx, rsi                          # page
    xor r14d, r14d                        # packet index
    mov dword ptr [rsp + 40], 0           # copied
.Logg_tags_page:
    mov rcx, rbx
    mov rdx, rdi
    call ogg_page
    test eax, eax
    jz .Logg_tags_measured
    mov r8, rbx
    add rbx, rax
    cmp [r8 + 14], r13d
    jne .Logg_tags_page
    # rcx = data, edx = segments
    xor r9d, r9d
.Logg_tags_segment:
    cmp r9d, edx
    jae .Logg_tags_page
    movzx r10d, byte ptr [r8 + r9 + 27]
    cmp r14d, 1
    jne .Logg_tags_segment_done
    test r15d, r15d
    jnz .Logg_tags_copy
    add [rsp + 32], r10
    cmp qword ptr [rsp + 32], TAG_GATHER_MAX
    ja .Logg_tags_return
    jmp .Logg_tags_segment_done
.Logg_tags_copy:
    push rsi
    push rdi
    push rcx
    mov rsi, rcx
    mov rdi, [rip + tag_gather]
    mov eax, [rsp + 24 + 40]
    add rdi, rax
    add [rsp + 24 + 40], r10d
    mov ecx, r10d
    rep movsb
    pop rcx
    pop rdi
    pop rsi
.Logg_tags_segment_done:
    add rcx, r10
    inc r9d
    cmp r10d, 255
    je .Logg_tags_segment
    inc r14d                              # a packet ends
    cmp r14d, 2
    jae .Logg_tags_measured
    jmp .Logg_tags_segment
.Logg_tags_measured:
    cmp r14d, 2
    jb .Logg_tags_return                  # no whole comment packet
    test r15d, r15d
    jnz .Logg_tags_parse
    mov rcx, [rsp + 32]
    test rcx, rcx
    jz .Logg_tags_return
    call mem_alloc
    test rax, rax
    jz .Logg_tags_return
    mov [rip + tag_gather], rax
    mov r15d, 1
    jmp .Logg_tags_pass
.Logg_tags_parse:
    mov rcx, [rip + tag_gather]
    mov rdx, rcx
    add rdx, [rsp + 32]
    mov rax, rdx
    sub rax, rcx
    cmp r12d, 1
    jne .Logg_tags_opus
    cmp rax, 8
    jb .Logg_tags_free
    mov r8, 0x736962726f7603              # "\3vorbis"
    mov r9, 0x00ffffffffffffff
    and r9, [rcx]
    cmp r9, r8
    jne .Logg_tags_free
    add rcx, 7
    jmp .Logg_tags_comments
.Logg_tags_opus:
    cmp r12d, 2
    jne .Logg_tags_flac
    cmp rax, 8
    jb .Logg_tags_free
    mov r8, 0x736761547375704f            # "OpusTags"
    cmp [rcx], r8
    jne .Logg_tags_free
    add rcx, 8
    jmp .Logg_tags_comments
.Logg_tags_flac:
    cmp rax, 4
    jb .Logg_tags_free
    movzx eax, byte ptr [rcx]
    and eax, 0x7f
    cmp eax, 4                            # VORBIS_COMMENT
    jne .Logg_tags_free
    add rcx, 4
.Logg_tags_comments:
    call vc_parse
.Logg_tags_free:
.Logg_tags_return:
    mov rcx, [rip + tag_gather]
    test rcx, rcx
    jz .Logg_tags_freed
    call mem_free
    mov qword ptr [rip + tag_gather], 0
.Logg_tags_freed:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ogg_tags

# RCX=box, RDX=end of its parent -> RAX=payload end (the parent's end for
# size 0 or a box running past it), RCX=payload, EDX=type; RAX=0 when no box
# header fits.
LOCALFN mp4_box
    mov rax, rdx
    sub rax, rcx
    cmp rax, 8
    jl .Lmp4_box_none
    mov r8d, [rcx]
    bswap r8d
    mov r9d, [rcx + 4]
    cmp r8d, 1
    jne .Lmp4_box_short
    cmp rax, 16
    jl .Lmp4_box_none
    mov r8, [rcx + 8]
    bswap r8
    cmp r8, 16
    jb .Lmp4_box_none
    lea r10, [rcx + 16]
    jmp .Lmp4_box_end
.Lmp4_box_short:
    lea r10, [rcx + 8]
    test r8d, r8d
    jnz .Lmp4_box_sized
    mov r8, rax                           # to the parent's end
.Lmp4_box_sized:
    cmp r8, 8
    jb .Lmp4_box_none
.Lmp4_box_end:
    cmp r8, rax
    jbe .Lmp4_box_within
    mov r8, rax
.Lmp4_box_within:
    lea rax, [rcx + r8]
    mov rcx, r10
    mov edx, r9d
    ret
.Lmp4_box_none:
    xor eax, eax
    ret
ENDFN mp4_box

# RCX=children, RDX=end, R8D=type -> RAX=the first such box's payload end,
# RCX=its payload; RAX=0 when there is none.
LOCALFN mp4_find
    push rsi
    push rdi
    push rbx
    mov rsi, rcx
    mov rdi, rdx
    mov ebx, r8d
.Lmp4_find_box:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_find_return
    mov rsi, rax
    cmp edx, ebx
    jne .Lmp4_find_box
.Lmp4_find_return:
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mp4_find

# RCX=meta payload, RDX=end: its ilst items.
LOCALFN mp4_meta
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rsi, rcx
    mov rdi, rdx
    lea rax, [rsi + 8]
    cmp rax, rdi
    ja .Lmp4_meta_return
    cmp dword ptr [rsi + 4], 0x726c6468   # hdlr: QuickTime meta without version
    je .Lmp4_meta_children
    add rsi, 4                            # ISO full box
.Lmp4_meta_children:
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, 0x74736c69                   # ilst
    call mp4_find
    test rax, rax
    jz .Lmp4_meta_return
    mov rsi, rcx
    mov rdi, rax
.Lmp4_meta_item:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_meta_return
    mov rsi, rax
    mov r12d, edx                         # item type
    mov rdx, rax
    mov r8d, 0x61746164                   # data
    call mp4_find
    test rax, rax
    jz .Lmp4_meta_item
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 8
    jb .Lmp4_meta_item
    mov ebx, [rcx]
    bswap ebx
    and ebx, 0xffffff                     # well-known type
    lea r8, [rcx + 8]                     # value
    sub edx, 8
    mov [rsp + 32], r8
    mov [rsp + 40], edx
    mov edx, r12d
    lea rcx, [rip + mp4_items]
    call tag_fourcc
    cmp eax, -1
    je .Lmp4_meta_item
    mov r9d, eax                          # key
    mov r8, [rsp + 32]
    mov edx, [rsp + 40]
    cmp r12d, 0x6e6b7274                  # trkn
    je .Lmp4_meta_number
    cmp r12d, 0x6b736964                  # disk
    je .Lmp4_meta_number
    cmp r12d, 0x65726e67                  # gnre
    je .Lmp4_meta_genre
    cmp ebx, 1                            # UTF-8
    jne .Lmp4_meta_item
    mov ecx, r9d
    mov rdx, r8
    mov r8d, [rsp + 40]
    mov r9d, TAG_REPLACE
    call tag_store
    jmp .Lmp4_meta_item
.Lmp4_meta_number:
    # "number" or "number/total" (FFmpeg's form).
    cmp edx, 6
    jb .Lmp4_meta_item
    movzx eax, word ptr [r8 + 2]
    rol ax, 8
    movzx ebx, word ptr [r8 + 4]
    rol bx, 8
    movzx ebx, bx
    mov [rsp + 44], r9d
    call tag_decimal
    lea rcx, [rip + tag_scratch]
    xor r10d, r10d
.Lmp4_meta_digits:
    cmp r10d, edx
    jae .Lmp4_meta_total
    movzx r11d, byte ptr [rax + r10]
    mov [rcx + r10], r11b
    inc r10d
    jmp .Lmp4_meta_digits
.Lmp4_meta_total:
    test ebx, ebx
    jz .Lmp4_meta_number_store
    mov byte ptr [rcx + r10], '/'
    inc r10d
    mov eax, ebx
    call tag_decimal
    xor r11d, r11d
.Lmp4_meta_total_digits:
    cmp r11d, edx
    jae .Lmp4_meta_number_store
    movzx r8d, byte ptr [rax + r11]
    mov [rcx + r10], r8b
    inc r10d
    inc r11d
    jmp .Lmp4_meta_total_digits
.Lmp4_meta_number_store:
    mov rdx, rcx
    mov r8d, r10d
    mov ecx, [rsp + 44]
    mov r9d, TAG_REPLACE
    call tag_store
    jmp .Lmp4_meta_item
.Lmp4_meta_genre:
    cmp edx, 2
    jb .Lmp4_meta_item
    movzx ecx, byte ptr [r8 + 1]
    dec ecx
    js .Lmp4_meta_item
    cmp ecx, GENRE_COUNT - 1              # 1-191 (FFmpeg's bound)
    jae .Lmp4_meta_item
    call tag_genre_name
    test rax, rax
    jz .Lmp4_meta_item
    mov r8d, edx
    mov rdx, rax
    mov ecx, TAG_GENRE
    mov r9d, TAG_REPLACE
    call tag_store
    jmp .Lmp4_meta_item
.Lmp4_meta_return:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_meta

# RCX=udta payload, RDX=end: its meta boxes and QuickTime text atoms (a
# 16-bit length, a language code, then text: UTF-8 for packed ISO-639
# codes; Macintosh language codes only with ASCII text).
LOCALFN mp4_udta
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
.Lmp4_udta_box:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_udta_return
    mov rsi, rax
    cmp edx, 0x6174656d                   # meta
    jne .Lmp4_udta_chpl
    mov rdx, rax
    call mp4_meta
    jmp .Lmp4_udta_box
.Lmp4_udta_chpl:
    cmp edx, 0x6c706863                   # chpl: Nero chapters
    jne .Lmp4_udta_text
    mov rdx, rax
    call mp4_chpl
    jmp .Lmp4_udta_box
.Lmp4_udta_text:
    cmp dl, 0xa9
    jne .Lmp4_udta_box
    mov rbx, rcx
    lea rcx, [rip + mp4_items]
    call tag_fourcc
    cmp eax, -1
    je .Lmp4_udta_box
    mov r9, rsi
    sub r9, rbx
    cmp r9, 4
    jb .Lmp4_udta_box
    movzx r8d, word ptr [rbx]
    rol r8w, 8
    sub r9, 4
    cmp r8, r9
    ja .Lmp4_udta_box
    movzx r10d, word ptr [rbx + 2]
    rol r10w, 8
    lea rdx, [rbx + 4]
    cmp r10d, 0x400
    jae .Lmp4_udta_store
    xor r11d, r11d                        # Macintosh text: ASCII only
.Lmp4_udta_ascii:
    cmp r11d, r8d
    jae .Lmp4_udta_store
    cmp byte ptr [rdx + r11], 0x80
    jae .Lmp4_udta_box
    inc r11d
    jmp .Lmp4_udta_ascii
.Lmp4_udta_store:
    mov ecx, eax
    mov r9d, TAG_REPLACE
    call tag_store
    jmp .Lmp4_udta_box
.Lmp4_udta_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_udta

# RCX=file, RDX=end: moov's udta and meta boxes in file order (later values
# replace earlier ones, as in FFmpeg), then the chapter tracks the last
# tref/chap box names, in its order (a video track's chapter images give
# no chapters).
LOCALFN mp4_tags
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, rcx                          # file
    mov r13, rdx
    mov r8d, 0x766f6f6d                   # moov
    call mp4_find
    test rax, rax
    jz .Lmp4_tags_return
    mov rsi, rcx
    mov rdi, rax
    mov rbx, rcx                          # moov's children
.Lmp4_tags_box:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_tags_chapters
    mov rsi, rax
    cmp edx, 0x61746475                   # udta
    je .Lmp4_tags_udta
    cmp edx, 0x6b617274                   # trak
    je .Lmp4_tags_trak
    cmp edx, 0x6174656d                   # meta
    jne .Lmp4_tags_box
    mov rdx, rax
    call mp4_meta
    jmp .Lmp4_tags_box
.Lmp4_tags_udta:
    mov rdx, rax
    call mp4_udta
    jmp .Lmp4_tags_box
.Lmp4_tags_trak:
    mov rdx, rax
    mov r8d, 1
    call mp4_trak_ids
    jmp .Lmp4_tags_box
.Lmp4_tags_chapters:
    xor r14d, r14d                        # the tref/chap entry
.Lmp4_tags_chapter_next:
    cmp r14d, [rip + mp4_chapter_count]
    jae .Lmp4_tags_return
    lea rax, [rip + mp4_chapter_tracks]
    mov r15d, [rax + r14*4]
    inc r14d
    mov rsi, rbx
.Lmp4_tags_chapter_trak:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_tags_chapter_next            # no such track
    mov rsi, rax
    cmp edx, 0x6b617274                   # trak
    jne .Lmp4_tags_chapter_trak
    mov [rsp + 32], rcx
    mov rdx, rax
    xor r8d, r8d
    call mp4_trak_ids
    cmp eax, r15d
    jne .Lmp4_tags_chapter_trak
    mov rcx, [rsp + 32]                   # the first track with that ID
    mov rdx, rsi
    lea r9, [rip + mp4_hdlr_path]
    call mp4_path
    test rax, rax
    jz .Lmp4_tags_chapter_text
    sub rax, rcx
    cmp rax, 12
    jb .Lmp4_tags_chapter_text
    cmp dword ptr [rcx + 8], 0x65646976   # vide
    je .Lmp4_tags_chapter_next
.Lmp4_tags_chapter_text:
    mov rcx, [rsp + 32]
    mov rdx, rsi
    mov r8, r12
    mov r9, r13
    call mp4_chapter_samples
    jmp .Lmp4_tags_chapter_next
.Lmp4_tags_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp4_tags

# RCX=text chunk value, EDX=bytes, R8=table, R9D=chunk ID: RIFF INFO and AIFF
# text values are stored as they are.
LOCALFN tag_chunk_text
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov esi, edx
    mov rcx, r8
    mov edx, r9d
    call tag_fourcc
    cmp eax, -1
    je .Ltag_chunk_text_return
    mov ecx, eax
    mov rdx, rbx
    mov r8d, esi
    mov r9d, TAG_KEEP
    call tag_store
.Ltag_chunk_text_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN tag_chunk_text

# RCX=RIFF file (WAVE or AVI), RDX=end, R8=its INFO table: LIST INFO and
# id3 chunks.
LOCALFN riff_tags
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r13, r8
    mov eax, [rcx + 4]
    lea rdi, [rcx + rax + 8]
    cmp rdi, rdx
    jbe .Lriff_tags_sized
    mov rdi, rdx
.Lriff_tags_sized:
    lea rsi, [rcx + 12]
.Lriff_tags_chunk:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jl .Lriff_tags_return
    mov ebx, [rsi]
    mov eax, [rsi + 4]
    lea r12, [rsi + 8]                    # payload
    lea rsi, [r12 + rax]
    cmp rsi, rdi
    jbe .Lriff_tags_within
    mov rsi, rdi
.Lriff_tags_within:
    cmp ebx, 0x5453494c                   # LIST
    je .Lriff_tags_list
    cmp ebx, 0x20336469                   # "id3 "
    je .Lriff_tags_id3
    cmp ebx, 0x20334449                   # "ID3 "
    jne .Lriff_tags_next
.Lriff_tags_id3:
    mov rcx, r12
    mov rdx, rsi
    call id3_parse
    call id3_finish
    jmp .Lriff_tags_next
.Lriff_tags_list:
    lea rax, [r12 + 4]
    cmp rax, rsi
    ja .Lriff_tags_next
    cmp dword ptr [r12], 0x4f464e49       # INFO
    jne .Lriff_tags_next
    add r12, 4
.Lriff_tags_info:
    mov rax, rsi
    sub rax, r12
    cmp rax, 8
    jl .Lriff_tags_next
    mov r9d, [r12]
    mov edx, [r12 + 4]
    sub rax, 8
    cmp rdx, rax
    jbe .Lriff_tags_info_sized
    mov edx, eax
.Lriff_tags_info_sized:
    lea rcx, [r12 + 8]
    lea r12, [rcx + rdx + 1]
    and r12, -2
    mov r8, r13
    call tag_chunk_text
    jmp .Lriff_tags_info
.Lriff_tags_next:
    inc rsi
    and rsi, -2
    jmp .Lriff_tags_chunk
.Lriff_tags_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN riff_tags

# RCX=FORM file (AIFF, AIFC), RDX=end: NAME, AUTH, ANNO and ID3 chunks.
LOCALFN aiff_tags
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov eax, [rcx + 4]
    bswap eax
    lea rdi, [rcx + rax + 8]
    cmp rdi, rdx
    jbe .Laiff_tags_sized
    mov rdi, rdx
.Laiff_tags_sized:
    lea rsi, [rcx + 12]
.Laiff_tags_chunk:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 8
    jl .Laiff_tags_return
    mov ebx, [rsi]
    mov eax, [rsi + 4]
    bswap eax
    lea r12, [rsi + 8]
    lea rsi, [r12 + rax]
    cmp rsi, rdi
    jbe .Laiff_tags_within
    mov rsi, rdi
.Laiff_tags_within:
    cmp ebx, 0x20334449                   # "ID3 "
    jne .Laiff_tags_text
    mov rcx, r12
    mov rdx, rsi
    call id3_parse
    call id3_finish
    jmp .Laiff_tags_next
.Laiff_tags_text:
    mov rcx, r12
    mov rdx, rsi
    sub rdx, r12
    lea r8, [rip + aiff_text_ids]
    mov r9d, ebx
    call tag_chunk_text
.Laiff_tags_next:
    inc rsi
    and rsi, -2
    jmp .Laiff_tags_chunk
.Laiff_tags_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aiff_tags

# RCX=CAF file, RDX=end: the info chunk's key/value strings.
LOCALFN caf_tags
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64
    lea rsi, [rcx + 8]
    mov rdi, rdx
.Lcaf_tags_chunk:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 12
    jl .Lcaf_tags_return
    mov ebx, [rsi]
    mov rax, [rsi + 4]
    bswap rax
    lea r12, [rsi + 12]
    mov rcx, rdi
    sub rcx, r12
    cmp rax, rcx
    ja .Lcaf_tags_return                  # -1 or past the end
    lea rsi, [r12 + rax]
    cmp ebx, 0x6f666e69                   # info
    jne .Lcaf_tags_chunk
    mov rax, rsi
    sub rax, r12
    cmp rax, 4
    jb .Lcaf_tags_chunk
    mov r13d, [r12]
    bswap r13d                            # entries
    add r12, 4
.Lcaf_tags_entry:
    test r13d, r13d
    jz .Lcaf_tags_chunk
    dec r13d
    mov rcx, r12                          # key
    call .Lcaf_tags_string
    jc .Lcaf_tags_chunk
    mov [rsp + 32], rcx
    mov [rsp + 40], edx
    mov rcx, r12                          # value
    call .Lcaf_tags_string
    jc .Lcaf_tags_chunk
    mov [rsp + 48], rcx
    mov [rsp + 56], edx
    mov rdx, [rsp + 32]
    mov r8d, [rsp + 40]
    lea rcx, [rip + caf_keys]
    call tag_lookup
    cmp eax, -1
    je .Lcaf_tags_entry
    mov ecx, eax
    mov rdx, [rsp + 48]
    mov r8d, [rsp + 56]
    mov r9d, TAG_KEEP
    call tag_store
    jmp .Lcaf_tags_entry
.Lcaf_tags_return:
    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# R12=string, RSI=chunk end -> RCX=string, EDX=bytes, R12 past its NUL; CF
# when it has no NUL.
.Lcaf_tags_string:
    mov rcx, r12
.Lcaf_tags_string_byte:
    cmp r12, rsi
    jae .Lcaf_tags_string_bad
    cmp byte ptr [r12], 0
    je .Lcaf_tags_string_end
    inc r12
    jmp .Lcaf_tags_string_byte
.Lcaf_tags_string_end:
    mov rdx, r12
    sub rdx, rcx
    inc r12
    clc
    ret
.Lcaf_tags_string_bad:
    stc
    ret
ENDFN caf_tags

# RSI=element, RDI=end -> RAX=payload end, RCX=payload, EDX=ID; RAX=0 when
# no element header fits. Unknown and oversized sizes run to the end.
LOCALFN mkv_element
    mov rax, rdi
    sub rax, rsi
    jle .Lmkv_element_none
    movzx r8d, byte ptr [rsi]
    test r8d, r8d
    jz .Lmkv_element_none
    bsr r9d, r8d
    mov r10d, 8
    sub r10d, r9d                         # ID bytes, 1-8
    cmp r10d, 4
    ja .Lmkv_element_none
    cmp r10, rax
    jae .Lmkv_element_none
    xor edx, edx
    xor r11d, r11d
.Lmkv_element_id:
    shl edx, 8
    movzx r8d, byte ptr [rsi + r11]
    or edx, r8d
    inc r11d
    cmp r11d, r10d
    jb .Lmkv_element_id
    movzx r8d, byte ptr [rsi + r11]       # size
    test r8d, r8d
    jz .Lmkv_element_none
    bsr r9d, r8d                          # marker bit: 8 - length
    mov r10d, 8
    sub r10d, r9d                         # size bytes
    lea rcx, [r11 + r10]
    cmp rcx, rax
    ja .Lmkv_element_none
    push rbx
    mov ecx, r9d
    mov ebx, 1
    shl ebx, cl
    dec ebx                               # the first byte's value bits
    and r8d, ebx
    cmp r8d, ebx
    sete r9b                              # all value bits set so far: unknown
    movzx r9d, r9b
    mov ebx, r8d
    inc r11d
    dec r10d
.Lmkv_element_size:
    test r10d, r10d
    jz .Lmkv_element_sized
    shl rbx, 8
    movzx r8d, byte ptr [rsi + r11]
    or rbx, r8
    cmp r8d, 0xff
    je .Lmkv_element_ones
    xor r9d, r9d
.Lmkv_element_ones:
    inc r11d
    dec r10d
    jmp .Lmkv_element_size
.Lmkv_element_sized:
    lea rcx, [rsi + r11]
    mov rax, rdi
    sub rax, rcx
    test r9d, r9d
    jnz .Lmkv_element_rest
    cmp rbx, rax
    ja .Lmkv_element_rest
    lea rax, [rcx + rbx]
    pop rbx
    ret
.Lmkv_element_rest:
    mov rax, rdi
    pop rbx
    ret
.Lmkv_element_none:
    xor eax, eax
    ret
ENDFN mkv_element

# RCX=SimpleTag payload, RDX=end: TagName and TagString (TagLanguage other
# than "und" gives FFmpeg another key; skipped).
LOCALFN mkv_simple
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    xor r12d, r12d                        # name
    xor r13d, r13d                        # value
    xor ebx, ebx
    mov [rsp + 32], ebx
.Lmkv_simple_element:
    call mkv_element
    test rax, rax
    jz .Lmkv_simple_done
    mov rsi, rax
    sub rax, rcx
    cmp edx, 0x45a3                       # TagName
    jne .Lmkv_simple_string
    mov r12, rcx
    mov ebx, eax
    jmp .Lmkv_simple_element
.Lmkv_simple_string:
    cmp edx, 0x4487                       # TagString
    jne .Lmkv_simple_language
    mov r13, rcx
    mov [rsp + 32], eax
    jmp .Lmkv_simple_element
.Lmkv_simple_language:
    cmp edx, 0x447a                       # TagLanguage
    jne .Lmkv_simple_element
    cmp eax, 3
    jne .Lmkv_simple_return
    cmp word ptr [rcx], 0x6e75            # "un"
    jne .Lmkv_simple_return
    cmp byte ptr [rcx + 2], 'd'
    jne .Lmkv_simple_return
    jmp .Lmkv_simple_element
.Lmkv_simple_done:
    test r12, r12
    jz .Lmkv_simple_return
    test r13, r13
    jz .Lmkv_simple_return
    lea rcx, [rip + mkv_keys]
    mov rdx, r12
    mov r8d, ebx
    call tag_lookup
    cmp eax, -1
    je .Lmkv_simple_return
    mov ecx, eax
    mov rdx, r13
    mov r8d, [rsp + 32]
    mov r9d, TAG_REPLACE
    call tag_store
.Lmkv_simple_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mkv_simple

# RCX=EBML file, RDX=end: Segment Info Title, global Tags and Chapters.
LOCALFN mkv_tags
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    call mkv_element                      # EBML header
    test rax, rax
    jz .Lmkv_tags_return
    mov rsi, rax
.Lmkv_tags_segment:
    call mkv_element
    test rax, rax
    jz .Lmkv_tags_return
    mov rsi, rax
    cmp edx, 0x18538067                   # Segment
    jne .Lmkv_tags_segment
    mov rsi, rcx
    mov rdi, rax
    mov [rsp + 40], rcx                   # the Segment's payload
.Lmkv_tags_child:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lmkv_tags_continue
    cmp dword ptr [rax], 0
    jne .Lmkv_tags_return
.Lmkv_tags_continue:
    mov [rsp + 32], rsi                   # this element
    call mkv_element
    test rax, rax
    jz .Lmkv_tags_return
    mov rsi, rax
    cmp edx, 0x1549a966                   # Info
    je .Lmkv_tags_info
    cmp edx, 0x1043a770                   # Chapters
    je .Lmkv_tags_chapters
    cmp edx, 0x114d9b74                   # SeekHead
    je .Lmkv_tags_seekhead
    cmp edx, 0x1f43b675                   # Cluster
    je .Lmkv_tags_cluster
    cmp edx, 0x1254c367                   # Tags
    jne .Lmkv_tags_child
    # Tag elements.
    mov r12, rsi
    mov r13, rdi
    mov rsi, rcx
    mov rdi, rax
.Lmkv_tags_tag:
    call mkv_element
    test rax, rax
    jz .Lmkv_tags_tags_done
    mov rsi, rax
    cmp edx, 0x7373                       # Tag
    jne .Lmkv_tags_tag
    mov rbx, rcx
    mov rdx, rax
    call mkv_targeted
    test eax, eax
    jnz .Lmkv_tags_tag
    # Its SimpleTags.
    push rsi
    push rdi
    mov rdi, rsi
    mov rsi, rbx
.Lmkv_tags_simple:
    call mkv_element
    test rax, rax
    jz .Lmkv_tags_simple_done
    mov rsi, rax
    cmp edx, 0x67c8                       # SimpleTag
    jne .Lmkv_tags_simple
    push rsi
    push rdi
    sub rsp, 32
    mov rdx, rax
    call mkv_simple
    add rsp, 32
    pop rdi
    pop rsi
    jmp .Lmkv_tags_simple
.Lmkv_tags_simple_done:
    pop rdi
    pop rsi
    jmp .Lmkv_tags_tag
.Lmkv_tags_tags_done:
    mov rsi, r12
    mov rdi, r13
    jmp .Lmkv_tags_child
.Lmkv_tags_cluster:
    mov dword ptr [rip + mkv_cluster_seen], 1
    jmp .Lmkv_tags_child
.Lmkv_tags_seekhead:
    cmp dword ptr [rip + mkv_cluster_seen], 0
    jne .Lmkv_tags_child
    mov r12, rsi
    mov r13, rdi
    mov rsi, rcx
    mov rdi, rax
    call mkv_seek_chapters
    mov rsi, r12
    mov rdi, r13
    jmp .Lmkv_tags_child
.Lmkv_tags_chapters:
    # As FFmpeg reads them: every Chapters element before the first Cluster;
    # after it, only the one a SeekHead names, when none came before.
    cmp dword ptr [rip + mkv_cluster_seen], 0
    je .Lmkv_tags_chapters_read
    cmp dword ptr [rip + mkv_chapters_seen], 0
    jne .Lmkv_tags_child
    mov r8, [rsp + 32]
    sub r8, [rsp + 40]
    cmp r8, [rip + mkv_chapters_seek]
    jne .Lmkv_tags_child
.Lmkv_tags_chapters_read:
    mov r12, rsi
    mov r13, rdi
    mov rsi, rcx
    mov rdi, rax
    call mkv_chapters
    mov rsi, r12
    mov rdi, r13
    jmp .Lmkv_tags_child
.Lmkv_tags_info:
    mov r12, rsi
    mov r13, rdi
    mov rsi, rcx
    mov rdi, rax
.Lmkv_tags_info_element:
    call mkv_element
    test rax, rax
    jz .Lmkv_tags_info_done
    mov rsi, rax
    cmp edx, 0x7ba9                       # Title
    jne .Lmkv_tags_info_element
    mov rdx, rcx
    mov r8, rax
    sub r8, rcx
    mov ecx, TAG_TITLE
    mov r9d, TAG_KEEP
    call tag_store
.Lmkv_tags_info_done:
    mov rsi, r12
    mov rdi, r13
    jmp .Lmkv_tags_child
.Lmkv_tags_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mkv_tags

# RCX=Tag payload, RDX=end -> EAX=1 when its Targets name a track, edition,
# chapter or attachment UID (other than 0).
LOCALFN mkv_targeted
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
.Lmkv_targeted_element:
    call mkv_element
    test rax, rax
    jz .Lmkv_targeted_none
    mov rsi, rax
    cmp edx, 0x63c0                       # Targets
    jne .Lmkv_targeted_element
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
.Lmkv_targeted_uid:
    call mkv_element
    test rax, rax
    jz .Lmkv_targeted_next
    mov rsi, rax
    cmp edx, 0x63c5                       # TagTrackUID
    je .Lmkv_targeted_value
    cmp edx, 0x63c9                       # TagEditionUID
    je .Lmkv_targeted_value
    cmp edx, 0x63c4                       # TagChapterUID
    je .Lmkv_targeted_value
    cmp edx, 0x63c6                       # TagAttachmentUID
    jne .Lmkv_targeted_uid
.Lmkv_targeted_value:
    cmp rcx, rax
    jae .Lmkv_targeted_uid
    cmp byte ptr [rcx], 0
    jne .Lmkv_targeted_yes
    inc rcx
    jmp .Lmkv_targeted_value
.Lmkv_targeted_yes:
    pop rdi
    pop rsi
    mov eax, 1
    jmp .Lmkv_targeted_return
.Lmkv_targeted_next:
    pop rdi
    pop rsi
    jmp .Lmkv_targeted_element
.Lmkv_targeted_none:
    xor eax, eax
.Lmkv_targeted_return:
    pop rdi
    pop rsi
    ret
ENDFN mkv_targeted

# RCX=AU file (".snd"), RDX=end: "Key=value" lines of the annotation between
# the header and the data.
LOCALFN au_tags
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rax, rdx
    sub rax, rcx
    cmp rax, 24
    jb .Lau_tags_return
    mov eax, [rcx + 4]
    bswap eax
    lea rdi, [rcx + rax]                  # annotation end
    cmp rdi, rdx
    ja .Lau_tags_return
    lea rsi, [rcx + 24]
.Lau_tags_line:
    cmp rsi, rdi
    jae .Lau_tags_return
    mov rbx, rsi                          # line start
.Lau_tags_eol:
    cmp rsi, rdi
    jae .Lau_tags_have
    movzx eax, byte ptr [rsi]
    cmp eax, 10
    je .Lau_tags_have
    test eax, eax
    je .Lau_tags_have
    inc rsi
    jmp .Lau_tags_eol
.Lau_tags_have:
    mov r12, rsi                          # line end
    inc rsi
    mov rdx, rbx
.Lau_tags_equals:
    cmp rdx, r12
    jae .Lau_tags_line
    cmp byte ptr [rdx], '='
    je .Lau_tags_key
    inc rdx
    jmp .Lau_tags_equals
.Lau_tags_key:
    mov [rsp + 32], rdx
    mov r8, rdx
    sub r8, rbx
    mov rdx, rbx
    lea rcx, [rip + au_keys]
    call tag_match
    cmp eax, -1
    je .Lau_tags_line
    mov ecx, eax
    mov rdx, [rsp + 32]
    inc rdx
    mov r8, r12
    sub r8, rdx
    mov r9d, TAG_KEEP
    call tag_store
    jmp .Lau_tags_line
.Lau_tags_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN au_tags

# RCX=raw stream, RDX=end: ID3v2 tags at the start, an APEv2 tag at the end
# (or before an ID3v1 tag), then ID3v1 when nothing was found.
LOCALFN raw_tags
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov rbx, rcx
.Lraw_tags_id3:
    mov rcx, rbx
    mov rdx, rdi
    call id3_parse
    test eax, eax
    jz .Lraw_tags_end
    add rbx, rax                          # consecutive ID3v2 tags
    cmp rbx, rdi
    jb .Lraw_tags_id3
.Lraw_tags_end:
    mov eax, [rip + codec_kind]           # FFmpeg reads ID3v2 chapters only
    cmp eax, 3                            # before MPEG audio and ADTS AAC
    je .Lraw_tags_chapters
    cmp eax, 10
    je .Lraw_tags_chapters
    call chap_clear
.Lraw_tags_chapters:
    call id3_finish
    xor ebx, ebx                          # an ID3v1 tag at the end
    mov rax, rdi
    sub rax, rsi
    cmp rax, 128
    jb .Lraw_tags_ape
    cmp word ptr [rdi - 128], 0x4154      # "TA"
    jne .Lraw_tags_ape
    cmp byte ptr [rdi - 126], 'G'
    jne .Lraw_tags_ape
    mov ebx, 128
.Lraw_tags_ape:
    mov rcx, rdi
    sub rcx, rbx
    sub rcx, 32
    mov rax, rcx
    sub rax, rsi
    jl .Lraw_tags_v1
    mov rdx, rsi
    call ape_parse
.Lraw_tags_v1:
    test ebx, ebx
    jz .Lraw_tags_return
    cmp dword ptr [rip + tag_any], 0
    jne .Lraw_tags_return
    lea rcx, [rdi - 128]
    call id3v1_parse
.Lraw_tags_return:
    add rsp, 32
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN raw_tags

# RCX=mapped file, RDX=its end: reads the file's tags (never fails).
FN tags_read
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    call tags_clear
    mov rax, rdi
    sub rax, rsi
    cmp rax, 12
    jb .Ltags_read_return
    mov eax, [rsi]
    mov rcx, rsi
    mov rdx, rdi
    cmp eax, 0x46464952                   # RIFF
    jne .Ltags_read_form
    mov eax, [rsi + 8]
    lea r8, [rip + riff_info_ids]
    cmp eax, 0x45564157                   # WAVE
    je .Ltags_read_riff
    lea r8, [rip + avi_info_ids]
    cmp eax, 0x20495641                   # "AVI "
    jne .Ltags_read_return
.Ltags_read_riff:
    call riff_tags
    jmp .Ltags_read_return
.Ltags_read_form:
    cmp eax, 0x4d524f46                   # FORM
    jne .Ltags_read_caf
    call aiff_tags
    jmp .Ltags_read_return
.Ltags_read_caf:
    cmp eax, 0x66666163                   # caff
    jne .Ltags_read_au
    call caf_tags
    jmp .Ltags_read_return
.Ltags_read_au:
    cmp eax, 0x646e732e                   # .snd
    jne .Ltags_read_flac
    call au_tags
    jmp .Ltags_read_return
.Ltags_read_flac:
    cmp eax, 0x43614c66                   # fLaC
    jne .Ltags_read_ogg
    call flac_tags
    jmp .Ltags_read_return
.Ltags_read_ogg:
    cmp eax, 0x5367674f                   # OggS
    jne .Ltags_read_mkv
    call ogg_tags
    jmp .Ltags_read_return
.Ltags_read_mkv:
    cmp eax, 0xa3df451a                   # EBML
    jne .Ltags_read_mp4
    call mkv_tags
    jmp .Ltags_read_return
.Ltags_read_mp4:
    mov r8d, [rsi + 4]
    cmp r8d, 0x70797466                   # ftyp
    je .Ltags_read_iso
    cmp r8d, 0x766f6f6d                   # moov
    je .Ltags_read_iso
    cmp r8d, 0x7461646d                   # mdat
    je .Ltags_read_iso
    cmp r8d, 0x65646977                   # wide
    je .Ltags_read_iso
    cmp r8d, 0x65657266                   # free
    je .Ltags_read_iso
    cmp r8d, 0x70696b73                   # skip
    jne .Ltags_read_other
.Ltags_read_iso:
    call mp4_tags
    jmp .Ltags_read_return
.Ltags_read_other:
    # Other containers carry no tags LAMP reads: RIFX, RF64, BW64, Wave64,
    # FLV, MPEG-TS/PS.
    cmp eax, 0x58464952                   # RIFX
    je .Ltags_read_return
    cmp eax, 0x34364652                   # RF64
    je .Ltags_read_return
    cmp eax, 0x34365742                   # BW64
    je .Ltags_read_return
    cmp eax, 0x66666972                   # Wave64
    je .Ltags_read_return
    cmp eax, 0x01564c46                   # FLV
    je .Ltags_read_return
    cmp eax, 0xba010000                   # MPEG-PS pack
    je .Ltags_read_return
    cmp al, 0x47                          # MPEG-TS sync
    je .Ltags_read_return
    call raw_tags
.Ltags_read_return:
    add rsp, 40
    pop rdi
    pop rsi
    ret
ENDFN tags_read

.include "chapters.inc"
