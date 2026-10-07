# Original ASF metadata reader, included by tags.s. MIT, see LICENSE.
# All reads stay inside the Header Object and each nested object/descriptor.
# Global attributes are read first; attributes for the selected ASF stream
# then replace them. Other streams and nonzero language indices are skipped.
# Fixed per-key staging keeps the last value without exhausting tag_arena on
# duplicate attributes. Invalid optional objects do not fail audio playback.
.equ ASF_TAG_OBJECTS, 4096
.equ ASF_TAG_RECORDS, 65536
.equ ASF_TAG_SLOT, TAG_VALUE_MAX + 1

RODATA
astag_header: .quad 0x11cf668e75b22630, 0x6cce6200aa00d9a6
astag_extension: .quad 0x11cfa92e5fbf03b5, 0x6553200cc000e38e
astag_content: .quad 0x11cf668e75b22633, 0x6cce6200aa00d9a6
astag_extended: .quad 0x11d2e307d2d0a440, 0x50a85ec9a000f097
astag_metadata: .quad 0x48775bafc5f8cbea, 0xca4cfa448caa6784
astag_library: .quad 0x49d1949844231c94, 0x5470454e131d41a1
astag_basic_keys: .byte TAG_TITLE, TAG_ARTIST, 255, TAG_COMMENT, 255
astag_keys:
    .byte 6, TAG_ARTIST
    .ascii "AUTHOR"
    .byte 11, TAG_COMMENT
    .ascii "DESCRIPTION"
    .byte 11, TAG_COMMENT
    .ascii "WM/COMMENTS"
    .byte 14, TAG_ALBUM_ARTIST
    .ascii "WM/ALBUMARTIST"
    .byte 13, TAG_ALBUM
    .ascii "WM/ALBUMTITLE"
    .byte 11, TAG_COMPOSER
    .ascii "WM/COMPOSER"
    .byte 8, TAG_GENRE
    .ascii "WM/GENRE"
    .byte 12, TAG_DISC
    .ascii "WM/PARTOFSET"
    .byte 14, TAG_TRACK
    .ascii "WM/TRACKNUMBER"
    .byte 7, TAG_DATE
    .ascii "WM/YEAR"
    .byte 10, TAG_PICTURE
    .ascii "WM/PICTURE"
    .byte 0

.data
astag_scope: .long 0                 # 0 global, 1 selected stream
astag_objects_left: .long 0
astag_records_left: .long 0
astag_cover_local: .long 0
astag_lengths: .zero TAG_KEYS*4
.bss
.p2align 4
astag_values: .zero TAG_KEYS*ASF_TAG_SLOT

.text
# RCX=object bytes, RDX=GUID -> ZF=1 for equality (16 bytes already bounded).
LOCALFN astag_guid
    mov rax, [rcx]
    xor rax, [rdx]
    mov r8, [rcx + 8]
    xor r8, [rdx + 8]
    or rax, r8
    ret
ENDFN astag_guid

# ECX=key, RDX=UTF-8, R8D=bytes. Stage the last nonempty value, up to 4096
# bytes at a UTF-8 boundary. Only ten final copies enter the shared arena.
LOCALFN astag_store
    push rsi
    push rdi
    cmp ecx, TAG_KEYS
    jae .Lastag_store_done
    test r8d, r8d
    jz .Lastag_store_done
    cmp r8d, TAG_VALUE_MAX
    jbe .Lastag_store_copy
    mov r8d, TAG_VALUE_MAX
.Lastag_store_boundary:
    movzx eax, byte ptr [rdx + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Lastag_store_copy
    dec r8d
    jmp .Lastag_store_boundary
.Lastag_store_copy:
    lea rax, [rip + astag_lengths]
    mov [rax + rcx*4], r8d
    imul edi, ecx, ASF_TAG_SLOT
    lea rax, [rip + astag_values]
    add rdi, rax
    mov rsi, rdx
    mov ecx, r8d
    rep movsb
    mov byte ptr [rdi], 0
.Lastag_store_done:
    pop rdi
    pop rsi
    ret
ENDFN astag_store

# RCX=Content Description body, RDX=end. Validate all five counted UTF-16
# fields before storing any of this optional object's attributes.
LOCALFN astag_basic
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov rdi, rdx
    sub rdx, rcx
    cmp rdx, 10
    jb .Lastag_basic_done
    lea rsi, [rcx + 10]
    xor r12d, r12d
    xor r13d, r13d
.Lastag_basic_bound:
    movzx eax, word ptr [rbx + r12*2]
    test al, 1
    jnz .Lastag_basic_done
    add r13d, eax
    inc r12d
    cmp r12d, 5
    jb .Lastag_basic_bound
    mov rax, rdi
    sub rax, rsi
    cmp rax, r13
    jb .Lastag_basic_done
    xor r12d, r12d
.Lastag_basic_field:
    movzx r13d, word ptr [rbx + r12*2]
    lea rax, [rip + astag_basic_keys]
    movzx edi, byte ptr [rax + r12]
    cmp edi, TAG_KEYS
    jae .Lastag_basic_next
    mov rcx, rsi
    mov edx, r13d
    xor r8d, r8d
    call tag_utf16
    mov r8d, edx
    mov rdx, rax
    mov ecx, edi
    call astag_store
.Lastag_basic_next:
    add rsi, r13
    inc r12d
    cmp r12d, 5
    jb .Lastag_basic_field
.Lastag_basic_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN astag_basic

# RCX=descriptor cursor, RDX=end, R8D=0 Extended Content, 1 Metadata/Library.
# -> RAX=next descriptor, R9=name, R10D=name bytes, R11=value,
# EDX=value bytes, ECX=type, R8D=stream id (0 global), or RAX=0.
# Clobbers only volatile registers. This is also the object's preflight.
LOCALFN astag_record
    mov rax, rdx
    sub rax, rcx
    test r8d, r8d
    jnz .Lastag_record_metadata
    cmp rax, 2
    jb .Lastag_record_bad
    movzx r10d, word ptr [rcx]
    lea r9, [rcx + 2]
    lea rax, [r10 + 6]
    mov r11, rdx
    sub r11, rcx
    cmp rax, r11
    ja .Lastag_record_bad
    lea r11, [r9 + r10]
    movzx ecx, word ptr [r11]
    movzx eax, word ptr [r11 + 2]
    add r11, 4
    xor r8d, r8d
    jmp .Lastag_record_value
.Lastag_record_metadata:
    cmp rax, 12
    jb .Lastag_record_bad
    movzx r10d, word ptr [rcx + 4]
    lea r9, [rcx + 12]
    mov eax, [rcx + 8]
    movzx r8d, word ptr [rcx + 2]
    # Nonzero language indices are not silently mistaken for default text.
    cmp word ptr [rcx], 0
    je .Lastag_record_language
    mov r8d, 128
.Lastag_record_language:
    movzx ecx, word ptr [rcx + 6]
    mov r11, rdx
    sub r11, r9
    cmp r10, r11
    ja .Lastag_record_bad
    lea r11, [r9 + r10]
.Lastag_record_value:
    sub rdx, r11
    cmp rax, rdx
    ja .Lastag_record_bad
    mov edx, eax
    add rax, r11
    ret
.Lastag_record_bad:
    xor eax, eax
    ret
ENDFN astag_record

# RCX=typed value, EDX=bytes, R8D=type, R9D=normalized key,
# [rsp+40]=1 for Metadata's WORD boolean, 0 for Extended's DWORD boolean.
# Unicode or unsigned WORD/DWORD/QWORD/BOOL; byte arrays only WM/Picture.
LOCALFN astag_value
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, r9d
    cmp r8d, 1
    je .Lastag_value_binary
    cmp ebx, TAG_KEYS
    jae .Lastag_value_done
    test r8d, r8d
    jz .Lastag_value_text
    cmp r8d, 2
    je .Lastag_value_bool
    cmp r8d, 3
    je .Lastag_value_dword
    cmp r8d, 4
    je .Lastag_value_qword
    cmp r8d, 5
    jne .Lastag_value_done
.Lastag_value_word:
    cmp edx, 2
    jne .Lastag_value_done
    movzx eax, word ptr [rcx]
    jmp .Lastag_value_number
.Lastag_value_bool:
    cmp dword ptr [rsp + 96], 0
    jne .Lastag_value_word
.Lastag_value_dword:
    cmp edx, 4
    jne .Lastag_value_done
    mov eax, [rcx]
    jmp .Lastag_value_number
.Lastag_value_qword:
    cmp edx, 8
    jne .Lastag_value_done
    mov rax, [rcx]
.Lastag_value_number:
    # Full unsigned 64-bit conversion; tag_decimal is intentionally 32-bit.
    lea rsi, [rip + tag_number + 31]
    mov ecx, 10
.Lastag_value_digit:
    xor edx, edx
    div rcx
    add edx, '0'
    mov [rsi], dl
    dec rsi
    test rax, rax
    jnz .Lastag_value_digit
    lea rax, [rsi + 1]
    lea rdx, [rip + tag_number + 32]
    sub rdx, rax
    jmp .Lastag_value_store
.Lastag_value_text:
    test dl, 1
    jnz .Lastag_value_done
    xor r8d, r8d
    call tag_utf16
.Lastag_value_store:
    mov r8d, edx
    mov rdx, rax
    mov ecx, ebx
    call astag_store
    jmp .Lastag_value_done
.Lastag_value_binary:
    cmp ebx, TAG_PICTURE
    jne .Lastag_value_done
    call astag_picture
.Lastag_value_done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN astag_value

# RCX=descriptor object body, RDX=end, R8D=layout. Preflight the whole
# object so an invalid trailing descriptor cannot leave partial tags/art.
LOCALFN astag_descriptors
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 72
    mov rdi, rdx
    mov r13d, r8d
    sub rdx, rcx
    cmp rdx, 2
    jb .Lastag_desc_done
    movzx ebx, word ptr [rcx]
    cmp ebx, [rip + astag_records_left]
    ja .Lastag_desc_done
    sub [rip + astag_records_left], ebx
    lea r14, [rcx + 2]
    mov rsi, r14
    mov r12d, ebx
.Lastag_desc_preflight:
    test r12d, r12d
    jz .Lastag_desc_read_start
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, r13d
    call astag_record
    test rax, rax
    jz .Lastag_desc_done
    mov rsi, rax
    dec r12d
    jmp .Lastag_desc_preflight
.Lastag_desc_read_start:
    mov rsi, r14
.Lastag_desc_read:
    test ebx, ebx
    jz .Lastag_desc_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lastag_desc_continue
    cmp dword ptr [rax], 0
    jne .Lastag_desc_done
.Lastag_desc_continue:
    mov rcx, rsi
    mov rdx, rdi
    mov r8d, r13d
    call astag_record
    mov rsi, rax
    cmp dword ptr [rip + astag_scope], 0
    jne .Lastag_desc_local
    test r8d, r8d
    jnz .Lastag_desc_next
    jmp .Lastag_desc_name
.Lastag_desc_local:
    cmp r8d, [rip + asf_stream]
    jne .Lastag_desc_next
.Lastag_desc_name:
    test r10b, 1
    jnz .Lastag_desc_next
    cmp r10d, 2*TAG_VALUE_MAX
    ja .Lastag_desc_next
    mov [rsp + 40], r11
    mov [rsp + 48], edx
    mov [rsp + 52], ecx
    # Every recognized name is ASCII. Match the complete UTF-16 name,
    # allowing one final NUL; malformed surrogates/early NULs cannot turn
    # an unrelated name into a recognized prefix.
    lea rdx, [rip + tag_scratch]
    xor r8d, r8d
    xor ecx, ecx
.Lastag_desc_name_unit:
    cmp ecx, r10d
    jae .Lastag_desc_lookup
    movzx eax, word ptr [r9 + rcx]
    add ecx, 2
    cmp eax, 127
    ja .Lastag_desc_next
    test eax, eax
    jnz .Lastag_desc_name_ascii
    cmp ecx, r10d
    jne .Lastag_desc_next
    jmp .Lastag_desc_lookup
.Lastag_desc_name_ascii:
    mov [rdx + r8], al
    inc r8d
    jmp .Lastag_desc_name_unit
.Lastag_desc_lookup:
    lea rcx, [rip + astag_keys]
    call tag_lookup
    cmp eax, -1
    je .Lastag_desc_next
    mov r9d, eax
    mov rcx, [rsp + 40]
    mov edx, [rsp + 48]
    mov r8d, [rsp + 52]
    mov [rsp + 32], r13d
    call astag_value
.Lastag_desc_next:
    dec ebx
    jmp .Lastag_desc_read
.Lastag_desc_done:
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN astag_descriptors

# RCX=children, RDX=end, R8D=depth. Unknown objects skipped in O(1).
LOCALFN astag_objects
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    cmp r12d, 4
    ja .Lastag_objects_done
.Lastag_objects_next:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lastag_objects_continue
    cmp dword ptr [rax], 0
    jne .Lastag_objects_done
.Lastag_objects_continue:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 24
    jb .Lastag_objects_done
    cmp dword ptr [rip + astag_objects_left], 0
    je .Lastag_objects_done
    dec dword ptr [rip + astag_objects_left]
    mov rbx, [rsi + 16]
    cmp rbx, 24
    jb .Lastag_objects_done
    cmp rbx, rax
    ja .Lastag_objects_done
    lea r13, [rsi + rbx]
    mov rcx, rsi
    lea rdx, [rip + astag_extension]
    call astag_guid
    jz .Lastag_objects_extension
    mov rcx, rsi
    lea rdx, [rip + astag_metadata]
    call astag_guid
    jz .Lastag_objects_metadata
    mov rcx, rsi
    lea rdx, [rip + astag_library]
    call astag_guid
    jz .Lastag_objects_metadata
    cmp dword ptr [rip + astag_scope], 0
    jne .Lastag_objects_advance
    mov rcx, rsi
    lea rdx, [rip + astag_content]
    call astag_guid
    jz .Lastag_objects_basic
    mov rcx, rsi
    lea rdx, [rip + astag_extended]
    call astag_guid
    jnz .Lastag_objects_advance
    xor r8d, r8d
    jmp .Lastag_objects_descriptors
.Lastag_objects_metadata:
    mov r8d, 1
.Lastag_objects_descriptors:
    lea rcx, [rsi + 24]
    mov rdx, r13
    call astag_descriptors
    jmp .Lastag_objects_advance
.Lastag_objects_basic:
    lea rcx, [rsi + 24]
    mov rdx, r13
    call astag_basic
    jmp .Lastag_objects_advance
.Lastag_objects_extension:
    cmp rbx, 46
    jb .Lastag_objects_advance
    mov edx, [rsi + 42]
    lea rax, [rdx + 46]
    cmp rax, rbx
    jne .Lastag_objects_advance
    lea rcx, [rsi + 46]
    add rdx, rcx
    lea r8d, [r12 + 1]
    call astag_objects
.Lastag_objects_advance:
    mov rsi, r13
    jmp .Lastag_objects_next
.Lastag_objects_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN astag_objects

# RCX=ASF file, RDX=mapped end. The full GUID/size is checked here, so this
# entry is safe independently of asf_open. asf_stream is the opened choice.
LOCALFN asf_tags
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    sub rdx, rcx
    cmp rdx, 30
    jb .Lastag_done
    lea rdx, [rip + astag_header]
    call astag_guid
    jnz .Lastag_done
    mov rax, rdi
    sub rax, rsi
    mov rbx, [rsi + 16]
    cmp rbx, 30
    jb .Lastag_done
    cmp rbx, rax
    ja .Lastag_done
    add rbx, rsi
    xor eax, eax
    lea rdi, [rip + astag_lengths]
    mov ecx, TAG_KEYS
    rep stosd
    mov dword ptr [rip + astag_cover_local], 0
    mov dword ptr [rip + astag_scope], 0
.Lastag_pass:
    mov dword ptr [rip + astag_objects_left], ASF_TAG_OBJECTS
    mov dword ptr [rip + astag_records_left], ASF_TAG_RECORDS
    lea rcx, [rsi + 30]
    mov rdx, rbx
    xor r8d, r8d
    call astag_objects
    cmp dword ptr [rip + astag_scope], 0
    jne .Lastag_flush_start
    cmp dword ptr [rip + asf_stream], 0
    je .Lastag_flush_start
    inc dword ptr [rip + astag_scope]
    jmp .Lastag_pass
.Lastag_flush_start:
    xor ebx, ebx
.Lastag_flush:
    lea rax, [rip + astag_lengths]
    mov r8d, [rax + rbx*4]
    imul edx, ebx, ASF_TAG_SLOT
    lea rax, [rip + astag_values]
    add rdx, rax
    mov ecx, ebx
    mov r9d, TAG_REPLACE
    call tag_store
    inc ebx
    cmp ebx, TAG_KEYS
    jb .Lastag_flush
.Lastag_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN asf_tags

# RCX=WM/Picture value, EDX=bytes. The packed layout is BYTE type, DWORD
# image bytes, UTF-16LE MIME and description (both terminated), then image.
# UTF-16 string scanning is bounded by the record, not tag_scratch's cap.
LOCALFN astag_picture
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    cmp edx, 9
    jb .Lastag_picture_done
    movzx r12d, byte ptr [rcx]
    mov ebx, [rcx + 1]
    test ebx, ebx
    jz .Lastag_picture_done
    lea rdi, [rcx + rdx]
    lea r13, [rcx + 5]
    mov rsi, r13
    mov r8d, 128
.Lastag_picture_mime:
    test r8d, r8d
    jz .Lastag_picture_done
    mov rax, rdi
    sub rax, rsi
    cmp rax, 2
    jb .Lastag_picture_done
    movzx eax, word ptr [rsi]
    add rsi, 2
    sub r8d, 2
    cmp eax, 127
    ja .Lastag_picture_done
    test eax, eax
    jnz .Lastag_picture_mime
    mov rdx, rsi
    sub rdx, r13
    cmp rdx, 128                      # MIME bounded to 63 units plus NUL
    ja .Lastag_picture_done
    mov rcx, r13
    xor r8d, r8d
    call tag_utf16
    mov byte ptr [rax + rdx], 0
    mov rcx, rax
    lea rdx, [rip + cover_id3_mimes]
    xor r8d, r8d                     # ASF MIME comparison is case sensitive
    xor r9d, r9d
    call cover_lookup
    test eax, eax
    jz .Lastag_picture_done
    mov r13d, eax
    mov r8d, 2*TAG_VALUE_MAX
.Lastag_picture_description:
    test r8d, r8d
    jz .Lastag_picture_done
    mov rax, rdi
    sub rax, rsi
    cmp rax, 2
    jb .Lastag_picture_done
    movzx eax, word ptr [rsi]
    add rsi, 2
    sub r8d, 2
    test eax, eax
    jnz .Lastag_picture_description
    sub rdi, rsi
    cmp rbx, rdi
    ja .Lastag_picture_done
    # A valid local picture takes precedence over any global picture.
    cmp dword ptr [rip + astag_scope], 0
    je .Lastag_picture_offer
    cmp dword ptr [rip + astag_cover_local], 0
    jne .Lastag_picture_offer
    call cover_clear
    mov dword ptr [rip + astag_cover_local], 1
.Lastag_picture_offer:
    xor r9d, r9d
    cmp r12d, 3
    sete r9b
    mov rcx, rsi
    mov edx, ebx
    mov r8d, r13d
    mov qword ptr [rsp + 32], 0
    call cover_offer
.Lastag_picture_done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN astag_picture
