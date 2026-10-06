# Original cover art reader, included by src/tags.s. MIT, see LICENSE.
# Keeps one embedded picture: the first front cover, or else the first
# picture, among the pictures FFmpeg's demuxers expose as attached pictures,
# in their order:
# - ID3v2 APIC (2.3, 2.4) and PIC (2.2) frames with a known MIME type (any
#   case) and data; type 3 is the front cover.
# - FLAC PICTURE blocks and METADATA_BLOCK_PICTURE comments (base64 FLAC
#   pictures in FLAC and Ogg) with a known MIME type (exact case).
# - MP4 covr data of type 13 (JPEG), 14 (PNG) or 27 (BMP).
# - Matroska attachments whose FileMimeType starts with image/gif,
#   image/jpeg, image/png or image/tiff; a FileName "cover.*" is the front
#   cover.
# - WavPack APEv2 binary items named by an image file name; the item "Cover
#   Art (Front)" is the front cover.
# PNG data is PNG whatever its declared type (but in Matroska and APEv2), and
# MP4 data that is not PNG or BMP is JPEG, as in FFmpeg. The picture points
# into the mapped file, or into cover_owned when it had to be decoded
# (unsynchronised ID3v2 frames, base64 comments).
.equ COVER_JPEG, 1
.equ COVER_PNG, 2
.equ COVER_GIF, 3
.equ COVER_BMP, 4
.equ COVER_TIFF, 5
.equ COVER_WEBP, 6

.data
.p2align 3
cover_data: .quad 0
cover_bytes: .quad 0
cover_owned: .quad 0                # mem_alloc block holding cover_data, or 0
cover_kind: .long 0                 # COVER_*, 0 for none
cover_front: .long 0
mkv_attachments_seen: .long 0
.p2align 3
mkv_attachments_seek: .quad -1      # Attachments position a SeekHead names

RODATA
.p2align 3
cover_mimes:                        # MIME types by COVER_* kind
    .quad 0, cover_mime_jpeg, cover_mime_png, cover_mime_gif, cover_mime_bmp, cover_mime_tiff, cover_mime_webp
cover_mime_jpeg: .asciz "image/jpeg"
cover_mime_png: .asciz "image/png"
cover_mime_gif: .asciz "image/gif"
cover_mime_bmp: .asciz "image/bmp"
cover_mime_tiff: .asciz "image/tiff"
cover_mime_webp: .asciz "image/webp"
cover_mime_jpg: .asciz "image/jpg"
cover_mime_id3_jpg: .asciz "JPG"
cover_mime_id3_png: .asciz "PNG"
# FFmpeg's ff_id3v2_mime_tags, in its order: string, kind.
.p2align 3
cover_id3_mimes:
    .quad cover_mime_gif, COVER_GIF, cover_mime_jpeg, COVER_JPEG, cover_mime_jpg, COVER_JPEG
    .quad cover_mime_png, COVER_PNG, cover_mime_tiff, COVER_TIFF, cover_mime_bmp, COVER_BMP
    .quad cover_mime_webp, COVER_WEBP, cover_mime_id3_jpg, COVER_JPEG, cover_mime_id3_png, COVER_PNG
    .quad 0, 0
# FFmpeg's ff_mkv_image_mime_tags: MIME type prefixes.
cover_mkv_mimes:
    .quad cover_mime_gif, COVER_GIF, cover_mime_jpeg, COVER_JPEG, cover_mime_png, COVER_PNG
    .quad cover_mime_tiff, COVER_TIFF, 0, 0
# Image file name extensions (lower case) for APEv2 items.
cover_extensions:
    .ascii "jpg\0", "jpeg", "png\0", "gif\0", "bmp\0", "tif\0", "tiff", "webp"
    .byte COVER_JPEG, COVER_JPEG, COVER_PNG, COVER_GIF, COVER_BMP, COVER_TIFF, COVER_TIFF, COVER_WEBP
cover_ape_front: .ascii "cover art (front)"
cover_vc_key: .ascii "METADATA_BLOCK_PICTURE"
cover_png_signature: .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10
# Base64 digits: 0-63, 64 for '=' (the end), 255 for others.
cover_base64:
    .fill 43, 1, 255
    .byte 62, 255, 255, 255, 63
    .byte 52, 53, 54, 55, 56, 57, 58, 59, 60, 61
    .byte 255, 255, 255, 64, 255, 255, 255
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25
    .byte 255, 255, 255, 255, 255, 255
    .byte 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51
    .fill 133, 1, 255

.text
# Forgets the picture (freeing a decoded copy).
LOCALFN cover_clear
    sub rsp, 40
    mov rcx, [rip + cover_owned]
    test rcx, rcx
    jz .Lcover_clear_state
    call mem_free
.Lcover_clear_state:
    xor eax, eax
    mov [rip + cover_owned], rax
    mov [rip + cover_data], rax
    mov [rip + cover_bytes], rax
    mov [rip + cover_kind], eax
    mov [rip + cover_front], eax
    mov [rip + mkv_attachments_seen], eax
    mov qword ptr [rip + mkv_attachments_seek], -1
    add rsp, 40
    ret
ENDFN cover_clear

# -> RAX=the picture (0 for none), RDX=bytes, R8D=kind (COVER_*; its MIME
# type is cover_mimes[kind]).
FN cover_get
    mov rax, [rip + cover_data]
    mov rdx, [rip + cover_bytes]
    mov r8d, [rip + cover_kind]
    ret
ENDFN cover_get

# ECX=1 for a front cover -> EAX=1 when such a picture would be kept.
LOCALFN cover_wanted
    xor eax, eax
    cmp dword ptr [rip + cover_kind], 0
    je .Lcover_wanted_yes
    test ecx, ecx
    jz .Lcover_wanted_return
    cmp dword ptr [rip + cover_front], 0
    jne .Lcover_wanted_return
.Lcover_wanted_yes:
    mov eax, 1
.Lcover_wanted_return:
    ret
ENDFN cover_wanted

# RCX=picture, RDX=bytes, R8D=kind, R9D=1 for a front cover, [rsp+40]=its
# mem_alloc block (0 when it lies in the mapped file): keeps it when it is
# the first picture or the first front cover; a block not kept is freed.
LOCALFN cover_offer
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    mov r12d, r9d
    mov r13, [rsp + 112]                  # the fifth argument
    test rsi, rsi
    jz .Lcover_offer_drop
    mov ecx, r12d
    call cover_wanted
    test eax, eax
    jz .Lcover_offer_drop
    mov rcx, [rip + cover_owned]
    test rcx, rcx
    jz .Lcover_offer_keep
    call mem_free
.Lcover_offer_keep:
    mov [rip + cover_owned], r13
    mov [rip + cover_data], rbx
    mov [rip + cover_bytes], rsi
    mov [rip + cover_kind], edi
    mov [rip + cover_front], r12d
    jmp .Lcover_offer_return
.Lcover_offer_drop:
    test r13, r13
    jz .Lcover_offer_return
    mov rcx, r13
    call mem_free
.Lcover_offer_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN cover_offer

# RCX=picture, RDX=bytes, R8D=kind -> EAX=COVER_PNG for data with PNG's
# signature, else the kind.
LOCALFN cover_sniff
    mov eax, r8d
    cmp rdx, 8
    jb .Lcover_sniff_return
    mov r9, [rcx]
    cmp r9, [rip + cover_png_signature]
    jne .Lcover_sniff_return
    mov eax, COVER_PNG
.Lcover_sniff_return:
    ret
ENDFN cover_sniff

# RCX=NUL-terminated text, RDX=table of (string, kind) pairs, R8D=1 to ignore
# ASCII case, R9D=1 to accept the strings as prefixes -> EAX=kind, 0 none.
LOCALFN cover_lookup
    push rbx
    push rsi
    push rdi
    mov rbx, rdx
.Lcover_lookup_entry:
    mov rsi, [rbx]
    test rsi, rsi
    jz .Lcover_lookup_none
    mov rdi, rcx
.Lcover_lookup_char:
    movzx eax, byte ptr [rsi]
    movzx edx, byte ptr [rdi]
    test eax, eax
    jz .Lcover_lookup_end
    test r8d, r8d
    jz .Lcover_lookup_compare
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja .Lcover_lookup_lower
    or eax, 0x20
.Lcover_lookup_lower:
    lea r10d, [rdx - 'A']
    cmp r10d, 25
    ja .Lcover_lookup_compare
    or edx, 0x20
.Lcover_lookup_compare:
    cmp eax, edx
    jne .Lcover_lookup_next
    inc rsi
    inc rdi
    jmp .Lcover_lookup_char
.Lcover_lookup_end:
    test r9d, r9d
    jnz .Lcover_lookup_found
    test edx, edx
    jz .Lcover_lookup_found
.Lcover_lookup_next:
    add rbx, 16
    jmp .Lcover_lookup_entry
.Lcover_lookup_found:
    mov eax, [rbx + 8]
    jmp .Lcover_lookup_return
.Lcover_lookup_none:
    xor eax, eax
.Lcover_lookup_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN cover_lookup

# RCX=APIC (ID3v2.3/2.4) or PIC (ID3v2.2) frame data, EDX=bytes, R8D=1 when
# unsynchronised, R9D=ID3v2 version: offers its picture, read as FFmpeg's
# read_apic reads it (a MIME type to a NUL, or three characters in ID3v2.2,
# the picture type, a description, then at least one byte of data).
LOCALFN id3_picture
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 112
    mov rsi, rcx
    mov ebx, edx
    mov r12d, r9d
    xor r15d, r15d                        # the decoded copy
    cmp ebx, 4
    jbe .Lid3_picture_return
    cmp r12d, 2
    jne .Lid3_picture_sized
    cmp ebx, 6
    jbe .Lid3_picture_return
.Lid3_picture_sized:
    test r8d, r8d
    jz .Lid3_picture_read
    # Undo unsynchronisation (FF 00 -> FF) into a block of its own.
    mov ecx, ebx
    call mem_alloc
    test rax, rax
    jz .Lid3_picture_return
    mov r15, rax
    xor ecx, ecx
    xor edx, edx
.Lid3_picture_unsync:
    cmp ecx, ebx
    jae .Lid3_picture_unsynced
    movzx r8d, byte ptr [rsi + rcx]
    mov [r15 + rdx], r8b
    inc ecx
    inc edx
    cmp r8d, 0xff
    jne .Lid3_picture_unsync
    cmp ecx, ebx
    jae .Lid3_picture_unsynced
    cmp byte ptr [rsi + rcx], 0
    jne .Lid3_picture_unsync
    inc ecx
    jmp .Lid3_picture_unsync
.Lid3_picture_unsynced:
    mov rsi, r15
    mov ebx, edx
.Lid3_picture_read:
    movzx r13d, byte ptr [rsi]            # text encoding
    lea rdi, [rsi + 1]
    dec ebx                               # bytes left after it
    # The MIME type, kept (to 63 characters) NUL-terminated at [rsp+32].
    cmp r12d, 2
    jne .Lid3_picture_mime
    mov eax, [rdi]
    and eax, 0xffffff
    mov [rsp + 32], eax
    add rdi, 3
    sub ebx, 3
    jmp .Lid3_picture_kind
.Lid3_picture_mime:
    xor ecx, ecx
.Lid3_picture_mime_char:
    cmp ecx, ebx
    jae .Lid3_picture_drop                # no NUL
    movzx eax, byte ptr [rdi + rcx]
    cmp ecx, 63
    jae .Lid3_picture_mime_long
    mov [rsp + 32 + rcx], al
.Lid3_picture_mime_long:
    inc ecx
    test eax, eax
    jnz .Lid3_picture_mime_char
    cmp ecx, ebx
    jae .Lid3_picture_drop                # nothing after it
    mov byte ptr [rsp + 32 + 63], 0
    add rdi, rcx
    sub ebx, ecx
.Lid3_picture_kind:
    lea rcx, [rsp + 32]
    lea rdx, [rip + cover_id3_mimes]
    mov r8d, 1
    xor r9d, r9d
    call cover_lookup
    test eax, eax
    jz .Lid3_picture_drop
    mov r14d, eax
    xor eax, eax
    cmp byte ptr [rdi], 3                 # picture type: front cover
    sete al
    mov [rsp + 96], eax
    inc rdi
    dec ebx
    # The description, read as decode_str reads it.
    mov ecx, r13d
    mov rdx, rdi
    mov r8d, ebx
    call id3_consumed
    jc .Lid3_picture_drop
    add rdi, rax
    sub ebx, eax
    jz .Lid3_picture_drop
    mov rcx, rdi
    mov edx, ebx
    mov r8d, r14d
    call cover_sniff
    mov r8d, eax
    mov rcx, rdi
    mov edx, ebx
    mov r9d, [rsp + 96]
    mov [rsp + 32], r15
    call cover_offer
    jmp .Lid3_picture_return
.Lid3_picture_drop:
    test r15, r15
    jz .Lid3_picture_return
    mov rcx, r15
    call mem_free
.Lid3_picture_return:
    add rsp, 112
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN id3_picture

# RCX=FLAC picture structure, RDX=end, R8=its mem_alloc block (0 when it lies
# in the mapped file, freed when no picture is kept): offers the picture as
# FFmpeg's ff_flac_parse_picture reads it.
LOCALFN flac_picture
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 112
    mov rsi, rcx
    mov rdi, rdx
    mov r13, r8
    mov rax, rdi
    sub rax, rsi
    cmp rax, 34
    jb .Lflac_picture_drop
    mov ebx, [rsi]
    bswap ebx                             # picture type
    xor r12d, r12d
    cmp ebx, 3
    sete r12b
    mov ecx, [rsi + 4]
    bswap ecx                             # MIME type bytes
    test ecx, ecx
    jz .Lflac_picture_drop
    cmp ecx, 64
    jae .Lflac_picture_drop
    add rsi, 8
    mov rax, rdi
    sub rax, rsi
    lea rdx, [rcx + 24]
    cmp rdx, rax
    ja .Lflac_picture_drop
    xor edx, edx
.Lflac_picture_mime:
    movzx eax, byte ptr [rsi + rdx]
    mov [rsp + 32 + rdx], al
    inc edx
    cmp edx, ecx
    jb .Lflac_picture_mime
    mov byte ptr [rsp + 32 + rcx], 0
    add rsi, rcx
    lea rcx, [rsp + 32]
    lea rdx, [rip + cover_id3_mimes]
    xor r8d, r8d
    xor r9d, r9d
    call cover_lookup
    test eax, eax
    jz .Lflac_picture_drop
    mov ebx, eax                          # kind
    mov ecx, [rsi]
    bswap ecx                             # description bytes
    add rsi, 4
    mov rax, rdi
    sub rax, rsi
    sub rax, 20
    cmp rcx, rax
    ja .Lflac_picture_drop
    lea rsi, [rsi + rcx + 16]             # past width, height, depth, colours
    mov ecx, [rsi]
    bswap ecx                             # data bytes
    add rsi, 4
    test ecx, ecx
    jz .Lflac_picture_drop
    mov rax, rdi
    sub rax, rsi
    cmp rcx, rax
    ja .Lflac_picture_drop                # FFmpeg's 16 MiB workaround aside
    mov rdi, rcx
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, ebx
    call cover_sniff
    mov r8d, eax
    mov rcx, rsi
    mov rdx, rdi
    mov r9d, r12d
    mov [rsp + 32], r13
    call cover_offer
    jmp .Lflac_picture_return
.Lflac_picture_drop:
    test r13, r13
    jz .Lflac_picture_return
    mov rcx, r13
    call mem_free
.Lflac_picture_return:
    add rsp, 112
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_picture

# RCX=comment key, EDX=its bytes, R8=value, R9D=its bytes -> EAX=1 when the
# key is METADATA_BLOCK_PICTURE (any case). Its value is base64 (decoded as
# av_base64_decode decodes it: digits up to an '=', a NUL or the end;
# anything else rejects it) of a FLAC picture, which is offered.
LOCALFN vc_picture
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    xor eax, eax
    cmp edx, 22
    jne .Lvc_picture_return
    lea r10, [rip + cover_vc_key]
.Lvc_picture_key:
    movzx r11d, byte ptr [rcx + rax]
    lea edx, [r11 - 'a']
    cmp edx, 25
    ja .Lvc_picture_key_case
    sub r11d, 0x20                        # upper case
.Lvc_picture_key_case:
    cmp r11b, [r10 + rax]
    jne .Lvc_picture_not
    inc eax
    cmp eax, 22
    jb .Lvc_picture_key
    mov rsi, r8
    mov ebx, r9d
    mov ecx, 1                            # worth decoding only when it could be kept
    call cover_wanted
    test eax, eax
    jz .Lvc_picture_yes
    mov ecx, ebx
    shr ecx, 2
    lea ecx, [rcx + rcx*2 + 3]
    call mem_alloc
    test rax, rax
    jz .Lvc_picture_yes
    mov r12, rax
    mov rdi, rax
    lea r8, [rip + cover_base64]
    xor r10d, r10d                        # input
    xor edx, edx                          # bits held
    xor r9d, r9d                          # accumulator
.Lvc_picture_char:
    cmp r10d, ebx
    jae .Lvc_picture_done
    movzx eax, byte ptr [rsi + r10]
    inc r10d
    test eax, eax
    jz .Lvc_picture_done
    movzx eax, byte ptr [r8 + rax]
    cmp eax, 64
    je .Lvc_picture_done
    ja .Lvc_picture_bad
    shl r9d, 6
    or r9d, eax
    add edx, 6
    cmp edx, 8
    jb .Lvc_picture_char
    sub edx, 8
    mov ecx, edx
    mov eax, r9d
    shr eax, cl
    mov [rdi], al
    inc rdi
    jmp .Lvc_picture_char
.Lvc_picture_done:
    mov rcx, r12
    mov rdx, rdi
    mov r8, r12
    call flac_picture
    jmp .Lvc_picture_yes
.Lvc_picture_bad:
    mov rcx, r12
    call mem_free
.Lvc_picture_yes:
    mov eax, 1
    jmp .Lvc_picture_return
.Lvc_picture_not:
    xor eax, eax
.Lvc_picture_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vc_picture

# RCX=covr payload, RDX=end: each data box of type 13, 14 or 27.
LOCALFN mp4_covr
    push rsi
    push rdi
    push rbx
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
.Lmp4_covr_box:
    mov rcx, rsi
    mov rdx, rdi
    call mp4_box
    test rax, rax
    jz .Lmp4_covr_return
    mov rsi, rax
    cmp edx, 0x61746164                   # data
    jne .Lmp4_covr_box
    sub rax, rcx
    cmp rax, 8
    jbe .Lmp4_covr_box
    lea rdx, [rax - 8]                    # picture bytes
    mov eax, [rcx]
    bswap eax                             # data type
    add rcx, 8
    mov r8d, COVER_BMP
    cmp eax, 27
    je .Lmp4_covr_offer
    mov r8d, COVER_JPEG
    cmp eax, 13
    je .Lmp4_covr_typed
    mov r8d, COVER_PNG
    cmp eax, 14
    jne .Lmp4_covr_box
.Lmp4_covr_typed:
    cmp rdx, 8
    jb .Lmp4_covr_offer
    mov r8d, COVER_JPEG                   # FFmpeg: PNG by signature, else JPEG
    call cover_sniff
    mov r8d, eax
.Lmp4_covr_offer:
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    call cover_offer
    jmp .Lmp4_covr_box
.Lmp4_covr_return:
    add rsp, 48
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN mp4_covr

# RSI=Attachments payload, RDI=end: AttachedFiles with a FileName, an image
# FileMimeType and FileData (FFmpeg's attached pictures).
LOCALFN mkv_attachments
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 112
    mov dword ptr [rip + mkv_attachments_seen], 1
.Lmkv_attachments_file:
    call mkv_element
    test rax, rax
    jz .Lmkv_attachments_return
    mov rsi, rax
    cmp edx, 0x61a7                       # AttachedFile
    jne .Lmkv_attachments_file
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rax
    xor ebx, ebx                          # FileName
    xor r12d, r12d
    xor r13d, r13d                        # FileMimeType
    xor r14d, r14d
    xor r15d, r15d                        # FileData
    mov qword ptr [rsp + 16 + 32], 0
.Lmkv_attachments_field:
    call mkv_element
    test rax, rax
    jz .Lmkv_attachments_done
    mov rsi, rax
    sub rax, rcx
    cmp edx, 0x466e                       # FileName
    jne .Lmkv_attachments_mime
    mov rbx, rcx
    mov r12, rax
    jmp .Lmkv_attachments_field
.Lmkv_attachments_mime:
    cmp edx, 0x4660                       # FileMimeType
    jne .Lmkv_attachments_data
    mov r13, rcx
    mov r14, rax
    jmp .Lmkv_attachments_field
.Lmkv_attachments_data:
    cmp edx, 0x465c                       # FileData
    jne .Lmkv_attachments_field
    mov r15, rcx
    mov [rsp + 16 + 32], rax
    jmp .Lmkv_attachments_field
.Lmkv_attachments_done:
    pop rdi
    pop rsi
    test rbx, rbx
    jz .Lmkv_attachments_file
    test r13, r13
    jz .Lmkv_attachments_file
    cmp qword ptr [rsp + 32], 0
    je .Lmkv_attachments_file
    # The MIME type to a NUL (at most 63 bytes) at [rsp+40].
    cmp r14, 63
    jbe .Lmkv_attachments_copy
    mov r14d, 63
.Lmkv_attachments_copy:
    xor ecx, ecx
.Lmkv_attachments_mime_char:
    cmp rcx, r14
    jae .Lmkv_attachments_mime_end
    movzx eax, byte ptr [r13 + rcx]
    mov [rsp + 40 + rcx], al
    inc ecx
    jmp .Lmkv_attachments_mime_char
.Lmkv_attachments_mime_end:
    mov byte ptr [rsp + 40 + rcx], 0
    lea rcx, [rsp + 40]
    lea rdx, [rip + cover_mkv_mimes]
    xor r8d, r8d
    mov r9d, 1
    call cover_lookup
    test eax, eax
    jz .Lmkv_attachments_file
    mov r13d, eax
    # A FileName "cover.*" (any case) is the front cover.
    xor r9d, r9d
    cmp r12, 6
    jb .Lmkv_attachments_offer
    mov eax, [rbx]
    or eax, 0x20202020
    cmp eax, 0x65766f63                   # "cove"
    jne .Lmkv_attachments_offer
    movzx eax, word ptr [rbx + 4]
    or eax, 0x0020
    cmp eax, 0x2e72                       # "r."
    sete r9b
.Lmkv_attachments_offer:
    mov rcx, r15
    mov rdx, [rsp + 32]
    mov r8d, r13d
    mov qword ptr [rsp + 32], 0
    call cover_offer
    jmp .Lmkv_attachments_file
.Lmkv_attachments_return:
    add rsp, 112
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
ENDFN mkv_attachments

# RCX=APEv2 item key, EDX=its bytes, R8=binary value, R9D=its bytes: a file
# name, a NUL and the data; the name's extension decides whether it is a
# picture (FFmpeg's ff_guess_image2_codec, for the image types LAMP knows).
LOCALFN ape_picture
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12d, edx
    mov rsi, r8
    mov edi, r9d
    xor ecx, ecx                          # the name, to its NUL
    xor r10d, r10d                        # after its last dot
.Lape_picture_name:
    cmp ecx, edi
    jae .Lape_picture_return
    movzx eax, byte ptr [rsi + rcx]
    inc ecx
    test eax, eax
    jz .Lape_picture_named
    cmp eax, '.'
    jne .Lape_picture_name
    mov r10d, ecx
    jmp .Lape_picture_name
.Lape_picture_named:
    cmp ecx, edi
    jae .Lape_picture_return              # no data
    test r10d, r10d
    jz .Lape_picture_return
    # The extension, lower case and zero-padded to four bytes.
    mov edx, ecx
    sub edx, r10d
    dec edx                               # its bytes
    cmp edx, 4
    ja .Lape_picture_return
    test edx, edx
    jz .Lape_picture_return
    mov dword ptr [rsp + 32], 0
    xor r9d, r9d
.Lape_picture_extension:
    cmp r9d, edx
    jae .Lape_picture_match
    lea eax, [r10 + r9]
    movzx eax, byte ptr [rsi + rax]
    lea r11d, [rax - 'A']
    cmp r11d, 25
    ja .Lape_picture_lower
    or eax, 0x20
.Lape_picture_lower:
    mov [rsp + 32 + r9], al
    inc r9d
    jmp .Lape_picture_extension
.Lape_picture_match:
    mov r8d, [rsp + 32]
    lea r11, [rip + cover_extensions]
    xor eax, eax
.Lape_picture_entry:
    cmp eax, 8
    jae .Lape_picture_return
    cmp [r11 + rax*4], r8d
    je .Lape_picture_kind
    inc eax
    jmp .Lape_picture_entry
.Lape_picture_kind:
    movzx r8d, byte ptr [r11 + 32 + rax]
    lea rax, [rsi + rcx]                  # the data
    mov edx, edi
    sub edx, ecx
    mov rsi, rax
    mov edi, edx
    # "Cover Art (Front)" (any case) is the front cover.
    xor r9d, r9d
    cmp r12d, 17
    jne .Lape_picture_offer
    xor ecx, ecx
    lea r10, [rip + cover_ape_front]
.Lape_picture_key:
    movzx eax, byte ptr [rbx + rcx]
    lea r11d, [rax - 'A']
    cmp r11d, 25
    ja .Lape_picture_key_lower
    or eax, 0x20
.Lape_picture_key_lower:
    cmp al, [r10 + rcx]
    jne .Lape_picture_offer
    inc ecx
    cmp ecx, 17
    jb .Lape_picture_key
    mov r9d, 1
.Lape_picture_offer:
    mov rcx, rsi
    mov edx, edi
    mov qword ptr [rsp + 32], 0
    call cover_offer
.Lape_picture_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_picture
