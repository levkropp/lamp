LOCALFN ui_release_buffer
    sub rsp, 40
    mov rcx, [rip + ui_dc]
    test rcx, rcx
    jz .Lui_release_done
    mov rdx, [rip + ui_original_bitmap]
    call SelectObject
    mov rcx, [rip + ui_bitmap]
    call DeleteObject
    mov rcx, [rip + ui_dc]
    call DeleteDC
    mov qword ptr [rip + ui_dc], 0
    mov qword ptr [rip + ui_bitmap], 0
    mov qword ptr [rip + ui_pixels], 0
.Lui_release_done:
    add rsp, 40
    ret
ENDFN ui_release_buffer

# A reusable top-down 32-bit DIB is the custom renderer's pixel canvas.
LOCALFN ui_make_buffer
    sub rsp, 136
    mov eax, [rip + ui_width]
    cmp eax, [rip + ui_buffer_width]
    jne .Lui_resize_buffer
    mov eax, [rip + ui_height]
    cmp eax, [rip + ui_buffer_height]
    je .Lui_buffer_done
.Lui_resize_buffer:
    call ui_release_buffer
    cmp dword ptr [rip + ui_width], 1
    jb .Lui_buffer_done
    cmp dword ptr [rip + ui_height], 1
    jb .Lui_buffer_done
    xor ecx, ecx
    call CreateCompatibleDC
    mov [rip + ui_dc], rax
    mov dword ptr [rip + ui_bmi], 40
    mov eax, [rip + ui_width]
    mov dword ptr [rip + ui_bmi + 4], eax
    mov eax, [rip + ui_height]
    neg eax
    mov dword ptr [rip + ui_bmi + 8], eax
    mov word ptr [rip + ui_bmi + 12], 1
    mov word ptr [rip + ui_bmi + 14], 32
    mov rcx, [rip + ui_dc]
    lea rdx, [rip + ui_bmi]
    xor r8d, r8d
    lea r9, [rip + ui_pixels]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateDIBSection
    test rax, rax
    jz .Lui_buffer_done
    mov [rip + ui_bitmap], rax
    mov rdx, rax
    mov rcx, [rip + ui_dc]
    call SelectObject
    mov [rip + ui_original_bitmap], rax
    mov eax, [rip + ui_width]
    mov [rip + ui_buffer_width], eax
    mov eax, [rip + ui_height]
    mov [rip + ui_buffer_height], eax
    mov rcx, [rip + ui_dc]
    mov edx, 1
    call SetBkMode
    cmp qword ptr [rip + ui_font], 0
    jne .Lui_buffer_font
    # System font, no embedded font asset or font licensing dependency.
    mov ecx, [rip + px_font]
    neg ecx
    call ui_make_font
    mov [rip + ui_font], rax
    mov ecx, [rip + px_big_font]
    neg ecx
    call ui_make_font
    mov [rip + ui_big_font], rax
.Lui_buffer_font:
    mov rcx, [rip + ui_dc]
    mov rdx, [rip + ui_font]
    call SelectObject
.Lui_buffer_done:
    add rsp, 136
    ret
ENDFN ui_make_buffer
LOCALFN ui_make_font
    sub rsp, 120
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 400
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    mov qword ptr [rsp + 64], 1
    mov qword ptr [rsp + 72], 0
    mov qword ptr [rsp + 80], 0
    mov qword ptr [rsp + 88], 5
    mov qword ptr [rsp + 96], 1
    lea rax, [rip + ui_font_name]
    mov [rsp + 104], rax
    call CreateFontW
    add rsp, 120
    ret
ENDFN ui_make_font

# ECX=x, EDX=y, R8D=width, R9D=height, EAX=0x00RRGGBB.
# Pixel writes are bounded even while a resize invalidates the old geometry.
LOCALFN ui_rect
    push rbx
    push rsi
    push rdi
    mov ebx, eax
    cmp ecx, 0
    jl .Lui_rect_done
    cmp edx, 0
    jl .Lui_rect_done
    cmp ecx, [rip + ui_width]
    jae .Lui_rect_done
    cmp edx, [rip + ui_height]
    jae .Lui_rect_done
    mov eax, [rip + ui_width]
    sub eax, ecx
    cmp r8d, eax
    cmova r8d, eax
    mov eax, [rip + ui_height]
    sub eax, edx
    cmp r9d, eax
    cmova r9d, eax
    test r8d, r8d
    jz .Lui_rect_done
    test r9d, r9d
    jz .Lui_rect_done
    mov eax, edx
    imul eax, [rip + ui_width]
    add eax, ecx
    mov rdi, [rip + ui_pixels]
    lea rdi, [rdi + rax*4]
    mov esi, [rip + ui_width]
    sub esi, r8d
    shl esi, 2
    mov eax, ebx
.Lui_rect_row:
    mov ecx, r8d
    rep stosd
    add rdi, rsi
    dec r9d
    jnz .Lui_rect_row
.Lui_rect_done:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_rect

# RCX=wide text, EDX=x, R8D=y, R9D=RGB text colour.
LOCALFN ui_text
    sub rsp, 72
    mov [rsp + 40], rcx
    mov [rsp + 48], edx
    mov [rsp + 52], r8d
    # Convert 0xRRGGBB to COLORREF 0xBBGGRR.
    mov eax, r9d
    bswap eax
    shr eax, 8
    mov edx, eax
    mov rcx, [rip + ui_dc]
    call SetTextColor
    mov r9, [rsp + 40]
    xor eax, eax
.Lui_text_length:
    cmp word ptr [r9 + rax*2], 0
    je .Lui_text_emit
    inc eax
    jmp .Lui_text_length
.Lui_text_emit:
    mov [rsp + 32], rax
    mov rcx, [rip + ui_dc]
    mov edx, [rsp + 48]
    mov r8d, [rsp + 52]
    call TextOutW
    add rsp, 72
    ret
ENDFN ui_text

# RCX=wide text, EDX=y. Centered and ellipsized for long filenames.
LOCALFN ui_center_text
    sub rsp, 56
    mov [rsp + 40], rcx
    mov eax, [rip + px_side]
    mov [rip + ui_text_rect], eax
    mov [rip + ui_text_rect + 4], edx
    mov eax, [rip + ui_width]
    sub eax, [rip + px_side]
    mov [rip + ui_text_rect + 8], eax
    add edx, [rip + px_title_h]
    mov [rip + ui_text_rect + 12], edx
    mov rcx, [rip + ui_dc]
    mov edx, 0x0ede8e2
    call SetTextColor
    mov rcx, [rip + ui_dc]
    mov rdx, [rsp + 40]
    mov r8d, -1
    lea r9, [rip + ui_text_rect]
    mov qword ptr [rsp + 32], 0x0008821 # CENTER | SINGLELINE | END_ELLIPSIS | NOPREFIX
    call DrawTextW
    add rsp, 56
    ret
ENDFN ui_center_text

# RAX=seconds, RCX=destination -> RCX advanced past mm:ss / hh:mm:ss.
LOCALFN ui_format_time
    mov r10, rcx
    xor edx, edx
    mov r8d, 3600
    div r8
    mov r9, rdx
    test eax, eax
    jz .Lui_time_minutes
    call ui_number
    mov word ptr [rcx], ':'
    add rcx, 2
.Lui_time_minutes:
    mov rax, r9
    xor edx, edx
    mov r8d, 60
    div r8
    mov r9, rdx
    call ui_two_digits
    mov word ptr [rcx], ':'
    add rcx, 2
    mov rax, r9
    call ui_two_digits
    ret
ENDFN ui_format_time
LOCALFN ui_two_digits
    xor edx, edx
    mov r8d, 10
    div r8d
    add eax, '0'
    add edx, '0'
    mov [rcx], ax
    mov [rcx + 2], dx
    add rcx, 4
    ret
ENDFN ui_two_digits
LOCALFN ui_number
    push rbx
    sub rsp, 64
    lea rbx, [rsp + 62]
    mov word ptr [rbx], 0
    mov r8d, 10
.Lui_number_digit:
    xor edx, edx
    div r8
    add edx, '0'
    sub rbx, 2
    mov [rbx], dx
    test rax, rax
    jnz .Lui_number_digit
.Lui_number_copy:
    movzx eax, word ptr [rbx]
    test eax, eax
    jz .Lui_number_done
    mov [rcx], ax
    add rcx, 2
    add rbx, 2
    jmp .Lui_number_copy
.Lui_number_done:
    add rsp, 64
    pop rbx
    ret
ENDFN ui_number

# RSI=UTF-8, ECX=bytes, RDI=UTF-16 destination, EDX=units at most -> RDI
# advanced. Malformed sequences become U+FFFD.
LOCALFN ui_wide_text
    push rbx
    lea r10, [rsi + rcx]                  # end
    lea r11, [rdi + rdx*2]                # destination limit
.Lui_wide_char:
    cmp rsi, r10
    jae .Lui_wide_done
    lea rax, [rdi + 4]
    cmp rax, r11
    ja .Lui_wide_done
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp eax, 0x80
    jb .Lui_wide_store
    mov ebx, 1
    and eax, 0x1f
    cmp byte ptr [rsi - 1], 0xe0
    jb .Lui_wide_lead
    mov ebx, 2
    and eax, 0x0f
    cmp byte ptr [rsi - 1], 0xf0
    jb .Lui_wide_lead
    mov ebx, 3
    and eax, 0x07
    cmp byte ptr [rsi - 1], 0xf5
    jae .Lui_wide_bad
.Lui_wide_lead:
    cmp byte ptr [rsi - 1], 0xc2
    jb .Lui_wide_bad
.Lui_wide_continue:
    cmp rsi, r10
    jae .Lui_wide_bad
    movzx ecx, byte ptr [rsi]
    mov edx, ecx
    and edx, 0xc0
    cmp edx, 0x80
    jne .Lui_wide_bad
    inc rsi
    shl eax, 6
    and ecx, 0x3f
    or eax, ecx
    dec ebx
    jnz .Lui_wide_continue
    cmp eax, 0x10000
    jb .Lui_wide_store
    sub eax, 0x10000                      # a surrogate pair
    mov ecx, eax
    shr ecx, 10
    add ecx, 0xd800
    mov [rdi], cx
    add rdi, 2
    and eax, 0x3ff
    add eax, 0xdc00
    jmp .Lui_wide_store
.Lui_wide_bad:
    mov eax, 0xfffd
.Lui_wide_store:
    mov [rdi], ax
    add rdi, 2
    jmp .Lui_wide_char
.Lui_wide_done:
    pop rbx
    ret
ENDFN ui_wide_text

# RCX=destination of 1040 units -> RAX=it, holding "Artist - Title" (or the
# title alone) when the opened file has a title tag; 0 otherwise.
LOCALFN ui_tag_title
    push rsi
    push rdi
    push rbx
    push r12
    sub rsp, 40
    mov r12, rcx
    xor ecx, ecx                          # title
    call tags_get
    test rax, rax
    jz .Lui_tag_none
    mov rbx, rax
    mov [rsp + 32], edx
    mov rdi, r12
    mov ecx, 1                            # artist
    call tags_get
    test rax, rax
    jz .Lui_tag_title
    mov rsi, rax
    mov ecx, edx
    mov edx, 512
    call ui_wide_text
    mov word ptr [rdi], 0x20              # " - " (an en dash)
    mov word ptr [rdi + 2], 0x2013
    mov word ptr [rdi + 4], 0x20
    add rdi, 6
.Lui_tag_title:
    mov rsi, rbx
    mov ecx, [rsp + 32]
    mov edx, 512
    call ui_wide_text
    mov word ptr [rdi], 0
    mov rax, r12
    jmp .Lui_tag_return
.Lui_tag_none:
    xor eax, eax
.Lui_tag_return:
    add rsp, 40
    pop r12
    pop rbx
    pop rdi
    pop rsi
    ret
ENDFN ui_tag_title

# RCX=wide text, EDX=x where it ends, R8D=y, R9D=RGB colour.
LOCALFN ui_right_text
    sub rsp, 56
    mov [rsp + 40], rcx
    mov dword ptr [rip + ui_text_rect], 0
    mov [rip + ui_text_rect + 4], r8d
    mov [rip + ui_text_rect + 8], edx
    add r8d, [rip + px_text_h]
    mov [rip + ui_text_rect + 12], r8d
    mov eax, r9d
    bswap eax
    shr eax, 8
    mov edx, eax
    mov rcx, [rip + ui_dc]
    call SetTextColor
    mov rcx, [rip + ui_dc]
    mov rdx, [rsp + 40]
    mov r8d, -1
    lea r9, [rip + ui_text_rect]
    mov qword ptr [rsp + 32], 0x0000822   # RIGHT | SINGLELINE | NOPREFIX
    call DrawTextW
    add rsp, 56
    ret
ENDFN ui_right_text

# RCX=wide text, R8D=y: muted, between the side margins, ellipsized.
LOCALFN ui_hint_text
    sub rsp, 56
    mov [rsp + 40], rcx
    mov eax, [rip + px_side]
    mov [rip + ui_text_rect], eax
    mov [rip + ui_text_rect + 4], r8d
    mov eax, [rip + ui_width]
    sub eax, [rip + px_side]
    mov [rip + ui_text_rect + 8], eax
    add r8d, [rip + px_text_h]
    mov [rip + ui_text_rect + 12], r8d
    mov eax, [rip + ui_muted_color]
    bswap eax
    shr eax, 8
    mov edx, eax
    mov rcx, [rip + ui_dc]
    call SetTextColor
    mov rcx, [rip + ui_dc]
    mov rdx, [rsp + 40]
    mov r8d, -1
    lea r9, [rip + ui_text_rect]
    mov qword ptr [rsp + 32], 0x0008820   # SINGLELINE | END_ELLIPSIS | NOPREFIX
    call DrawTextW
    add rsp, 56
    ret
ENDFN ui_hint_text

# ECX=x, EDX=top, R8D=0 for next (a triangle, then a bar) or 1 for previous
# (a bar, then a triangle): a 13 by 15 pixel button at 96 DPI, its rows
# drawn from those of that size.
LOCALFN ui_skip_icon
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov esi, ecx
    mov edi, edx
    mov r12d, r8d
    mov ecx, 15
    call ui_px
    mov r13d, eax                         # rows
    mov ecx, 13
    call ui_px
    mov r14d, eax                         # width
    mov ecx, 3
    call ui_px
    mov r8d, eax                          # the bar
    mov ecx, esi
    test r12d, r12d
    jnz .Lui_skip_bar
    add ecx, r14d
    sub ecx, eax
.Lui_skip_bar:
    mov edx, edi
    mov r9d, r13d
    mov eax, [rip + ui_text_color]
    call ui_rect
    xor ebx, ebx
.Lui_skip_row:
    mov eax, ebx                          # its row at 96 DPI
    imul eax, eax, 15
    xor edx, edx
    div r13d
    sub eax, 7                            # width there: 1 at the ends, 8 in the middle
    jns .Lui_skip_width
    neg eax
.Lui_skip_width:
    mov ecx, 8
    sub ecx, eax
    call ui_px
    mov r8d, eax
    mov ecx, esi
    test r12d, r12d
    jz .Lui_skip_place
    add ecx, r14d                         # previous: the triangle ends at the right
    sub ecx, r8d
.Lui_skip_place:
    lea edx, [rdi + rbx]
    mov r9d, 1
    mov eax, [rip + ui_text_color]
    call ui_rect
    inc ebx
    cmp ebx, r13d
    jb .Lui_skip_row
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_skip_icon

FN ui_draw
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    call ui_make_buffer
    cmp qword ptr [rip + ui_pixels], 0
    je .Lui_draw_done
    call ui_heard_update                  # the file being heard
    xor r12d, r12d                        # play/pause moves right with a list
    cmp dword ptr [rip + ui_count], 2
    jb .Lui_draw_single
    mov r12d, [rip + px_list_shift]
.Lui_draw_single:
    mov rdi, [rip + ui_pixels]
    mov eax, [rip + ui_background]
    mov ecx, [rip + ui_width]
    imul ecx, [rip + ui_height]
    rep stosd
    # Compact editor-style header and status strip.
    xor ecx, ecx
    xor edx, edx
    mov r8d, [rip + ui_width]
    mov r9d, [rip + px_header]
    mov eax, [rip + ui_surface]
    call ui_rect
    xor ecx, ecx
    mov edx, [rip + ui_height]
    sub edx, [rip + px_strip]
    mov r8d, [rip + ui_width]
    mov r9d, [rip + px_strip]
    mov eax, [rip + ui_surface]
    call ui_rect
    lea rcx, [rip + ui_brand]
    mov edx, [rip + px_margin]
    mov r8d, [rip + px_brand_y]
    mov r9d, [rip + ui_text_color]
    call ui_text
    lea rcx, [rip + ui_assembly]
    mov edx, [rip + ui_width]
    sub edx, [rip + px_assembly]
    mov r8d, [rip + px_brand_y]
    mov r9d, [rip + ui_muted_color]
    call ui_text
    mov rcx, [rip + ui_dc]
    mov rdx, [rip + ui_big_font]
    call SelectObject
    lea rcx, [rip + ui_drop]
    cmp dword ptr [rip + ui_state], 0
    je .Lui_draw_title
    lea rcx, [rip + ui_error]
    cmp dword ptr [rip + ui_state], 3
    je .Lui_draw_title
    lea rcx, [rip + ui_shown_title]       # "Artist - Title" or its name
    cmp word ptr [rcx], 0
    jne .Lui_draw_title
    mov rcx, [rip + ui_filename]          # opening
.Lui_draw_title:
    mov [rsp + 40], rcx
    call ui_cover_place                   # the cover art, above the title
    mov edx, eax
    mov rcx, [rsp + 40]
    call ui_center_text
    mov rcx, [rip + ui_dc]
    mov rdx, [rip + ui_font]
    call SelectObject
    cmp dword ptr [rip + ui_state], 3
    jne .Lui_draw_center_hint
    lea rcx, [rip + ui_error_detail]
    mov edx, [rip + ui_height]
    shr edx, 1
    call ui_center_text
    jmp .Lui_draw_status
.Lui_draw_center_hint:
    cmp dword ptr [rip + ui_state], 0
    jne .Lui_draw_status
    lea rcx, [rip + ui_open]
    mov edx, [rip + ui_height]
    shr edx, 1
    call ui_center_text
.Lui_draw_status:
    lea rcx, [rip + ui_ready]
    cmp dword ptr [rip + ui_state], 0
    je .Lui_status_ready
    cmp dword ptr [rip + ui_state], 3
    jne .Lui_status_not_error
    lea rcx, [rip + ui_failed]
    jmp .Lui_status_ready
.Lui_status_not_error:
    lea rcx, [rip + ui_finished]
    cmp dword ptr [rip + ui_state], 1
    jne .Lui_status_ready
    lea rcx, [rip + ui_playing]
    cmp dword ptr [rip + engine_ready], 0
    jne .Lui_status_running
    lea rcx, [rip + ui_loading]
    jmp .Lui_status_ready
.Lui_status_running:
    cmp dword ptr [rip + pause_requested], 0
    je .Lui_status_ready
    lea rcx, [rip + ui_paused]
.Lui_status_ready:
    mov edx, [rip + px_margin]
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_status_y]
    mov r9d, [rip + ui_accent]
    call ui_text
    # The list's state at the right: repeat, and the file heard among them.
    lea rcx, [rip + ui_list_text]
    cmp dword ptr [rip + queue_repeat], 0
    je .Lui_status_position
    lea rdx, [rip + ui_repeat_text]
.Lui_status_repeat:
    movzx eax, word ptr [rdx]
    test eax, eax
    jz .Lui_status_repeated
    mov [rcx], ax
    add rdx, 2
    add rcx, 2
    jmp .Lui_status_repeat
.Lui_status_repeated:
    cmp dword ptr [rip + ui_count], 2
    jb .Lui_status_list
    mov dword ptr [rcx], 0x00200020
    mov word ptr [rcx + 4], 0x20
    add rcx, 6
.Lui_status_position:
    cmp dword ptr [rip + ui_count], 2
    jb .Lui_status_list
    cmp dword ptr [rip + ui_state], 0
    je .Lui_status_list
    mov eax, [rip + ui_shown_index]
    inc eax
    call ui_number
    mov word ptr [rcx], ' '
    mov word ptr [rcx + 2], '/'
    mov word ptr [rcx + 4], ' '
    add rcx, 6
    mov eax, [rip + ui_count]
    call ui_number
.Lui_status_list:
    mov word ptr [rcx], 0
    lea rcx, [rip + ui_list_text]
    cmp word ptr [rcx], 0
    je .Lui_status_codec
    mov edx, [rip + ui_width]
    sub edx, [rip + px_margin]
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_status_y]
    mov r9d, [rip + ui_muted_color]
    call ui_right_text
.Lui_status_codec:
    mov eax, [rip + ui_shown_codec]
    test eax, eax
    jz .Lui_draw_hints
    cmp eax, 19
    ja .Lui_draw_hints
    lea rcx, [rip + ui_codec_names]
    mov rcx, [rcx + rax*8]
    mov edx, [rip + px_codec]
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_status_y]
    mov r9d, [rip + ui_muted_color]
    call ui_text
.Lui_draw_hints:
    cmp dword ptr [rip + ui_state], 1
    jne .Lui_draw_controls
    cmp dword ptr [rip + ui_controls], 0
    je .Lui_draw_done
.Lui_draw_controls:
    lea rcx, [rip + ui_hint]
    test r12d, r12d
    jz .Lui_draw_hint
    lea rcx, [rip + ui_hint_list]
.Lui_draw_hint:
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_hint_y]
    call ui_hint_text
    # Timeline and current position.
    mov ecx, [rip + px_side]
    mov edx, [rip + ui_height]
    sub edx, [rip + px_timeline_y]
    mov r8d, [rip + ui_width]
    sub r8d, ecx
    sub r8d, ecx
    mov r9d, [rip + px_timeline_h]
    mov eax, [rip + ui_line]
    call ui_rect
    mov rax, [rip + engine_position]      # within the file heard
    sub rax, [rip + ui_shown_start]
    jae .Lui_draw_offset
    xor eax, eax
.Lui_draw_offset:
    mov rbx, rax
    cmp qword ptr [rip + ui_shown_frames], 0
    je .Lui_draw_time
    cmp rax, [rip + ui_shown_frames]
    jbe .Lui_draw_progress
    mov rax, [rip + ui_shown_frames]
.Lui_draw_progress:
    mov ecx, [rip + ui_width]
    sub ecx, [rip + px_side]
    sub ecx, [rip + px_side]
    mul rcx
    div qword ptr [rip + ui_shown_frames]
    mov r8d, eax
    mov ecx, [rip + px_side]
    mov edx, [rip + ui_height]
    sub edx, [rip + px_timeline_y]
    mov r9d, [rip + px_timeline_h]
    mov eax, [rip + ui_accent]
    call ui_rect
.Lui_draw_time:
    lea rcx, [rip + ui_time_text]
    xor eax, eax
    mov r8d, [rip + queue_rate]
    test r8d, r8d
    jz .Lui_draw_time_current
    mov rax, rbx
    xor edx, edx
    div r8
.Lui_draw_time_current:
    call ui_format_time
    mov word ptr [rcx], ' '
    mov word ptr [rcx + 2], '/'
    mov word ptr [rcx + 4], ' '
    add rcx, 6
    mov rax, [rip + ui_shown_frames]
    mov r8d, [rip + queue_rate]
    test r8d, r8d
    jz .Lui_draw_time_total_zero
    xor edx, edx
    div r8
    jmp .Lui_draw_time_total
.Lui_draw_time_total_zero:
    xor eax, eax
.Lui_draw_time_total:
    call ui_format_time
    mov word ptr [rcx], 0
    lea rcx, [rip + ui_time_text]
    mov edx, [rip + px_time_x]
    lea edx, [rdx + r12*2]
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_time_y]
    mov r9d, [rip + ui_text_color]
    call ui_text
    test r12d, r12d
    jz .Lui_draw_pause
    mov ecx, [rip + px_margin]            # previous and next around play/pause
    mov edx, [rip + ui_height]
    sub edx, [rip + px_icon_y]
    mov r8d, 1
    call ui_skip_icon
    mov ecx, [rip + px_next_x]
    mov edx, [rip + ui_height]
    sub edx, [rip + px_icon_y]
    xor r8d, r8d
    call ui_skip_icon
.Lui_draw_pause:
    # Play triangle or two pause bars, rasterized directly in assembly.
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_draw_play
    cmp dword ptr [rip + pause_requested], 0
    jne .Lui_draw_play
    mov ecx, [rip + px_pause_x]
    add ecx, r12d
    mov edx, [rip + ui_height]
    sub edx, [rip + px_play_y]
    mov r8d, [rip + px_bar_w]
    mov r9d, [rip + px_bar_h]
    mov eax, [rip + ui_text_color]
    call ui_rect
    mov ecx, [rip + px_pause_x2]
    add ecx, r12d
    mov edx, [rip + ui_height]
    sub edx, [rip + px_play_y]
    mov r8d, [rip + px_bar_w]
    mov r9d, [rip + px_bar_h]
    mov eax, [rip + ui_text_color]
    call ui_rect
    jmp .Lui_draw_volume
.Lui_draw_play:
    # Rows from those of the 21-row triangle at 96 DPI: 4 to 14 pixels wide.
    mov ecx, 21
    call ui_px
    mov r13d, eax
    xor ebx, ebx
.Lui_draw_triangle:
    mov eax, ebx
    imul eax, eax, 21
    xor edx, edx
    div r13d
    sub eax, 10
    jns .Lui_triangle_width
    neg eax
.Lui_triangle_width:
    mov ecx, 14
    sub ecx, eax
    call ui_px
    mov r8d, eax
    mov ecx, [rip + px_triangle_x]
    add ecx, r12d
    mov edx, [rip + ui_height]
    sub edx, [rip + px_play_y]
    add edx, ebx
    mov r9d, 1
    mov eax, [rip + ui_text_color]
    call ui_rect
    inc ebx
    cmp ebx, r13d
    jb .Lui_draw_triangle
.Lui_draw_volume:
    lea rcx, [rip + ui_volume_text]
    mov eax, [rip + ui_volume_percent]
    call ui_number
    mov word ptr [rcx], '%'
    mov word ptr [rcx + 2], 0
    lea rcx, [rip + ui_volume_text]
    mov edx, [rip + ui_width]
    sub edx, [rip + px_volume_text_x]
    mov r8d, [rip + ui_height]
    sub r8d, [rip + px_volume_text_y]
    mov r9d, [rip + ui_muted_color]
    call ui_text
    mov ecx, [rip + ui_width]
    sub ecx, [rip + px_volume_x]
    mov edx, [rip + ui_height]
    sub edx, [rip + px_volume_y]
    mov r8d, [rip + px_volume_w]
    mov r9d, [rip + px_volume_h]
    mov eax, [rip + ui_line]
    call ui_rect
    mov eax, [rip + ui_volume_percent]
    imul eax, [rip + px_volume_w]
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r8d, eax
    mov ecx, [rip + ui_width]
    sub ecx, [rip + px_volume_x]
    mov edx, [rip + ui_height]
    sub edx, [rip + px_volume_y]
    mov r9d, [rip + px_volume_h]
    mov eax, [rip + ui_accent]
    call ui_rect
.Lui_draw_done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_draw
