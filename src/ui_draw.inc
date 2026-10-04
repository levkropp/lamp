ui_release_buffer PROC
    sub rsp,40
    mov rcx,[ui_dc]
    test rcx,rcx
    jz ui_release_done
    mov rdx,[ui_original_bitmap]
    call SelectObject
    mov rcx,[ui_bitmap]
    call DeleteObject
    mov rcx,[ui_dc]
    call DeleteDC
    mov qword ptr [ui_dc],0
    mov qword ptr [ui_bitmap],0
    mov qword ptr [ui_pixels],0
ui_release_done:
    add rsp,40
    ret
ui_release_buffer ENDP

; A reusable top-down 32-bit DIB is the custom renderer's pixel canvas.
ui_make_buffer PROC
    sub rsp,136
    mov eax,[ui_width]
    cmp eax,[ui_buffer_width]
    jne ui_resize_buffer
    mov eax,[ui_height]
    cmp eax,[ui_buffer_height]
    je ui_buffer_done
ui_resize_buffer:
    call ui_release_buffer
    cmp dword ptr [ui_width],1
    jb ui_buffer_done
    cmp dword ptr [ui_height],1
    jb ui_buffer_done
    xor ecx,ecx
    call CreateCompatibleDC
    mov [ui_dc],rax
    mov dword ptr [ui_bmi],40
    mov eax,[ui_width]
    mov dword ptr [ui_bmi+4],eax
    mov eax,[ui_height]
    neg eax
    mov dword ptr [ui_bmi+8],eax
    mov word ptr [ui_bmi+12],1
    mov word ptr [ui_bmi+14],32
    mov rcx,[ui_dc]
    lea rdx,ui_bmi
    xor r8d,r8d
    lea r9,ui_pixels
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateDIBSection
    test rax,rax
    jz ui_buffer_done
    mov [ui_bitmap],rax
    mov rdx,rax
    mov rcx,[ui_dc]
    call SelectObject
    mov [ui_original_bitmap],rax
    mov eax,[ui_width]
    mov [ui_buffer_width],eax
    mov eax,[ui_height]
    mov [ui_buffer_height],eax
    mov rcx,[ui_dc]
    mov edx,1
    call SetBkMode
    cmp qword ptr [ui_font],0
    jne ui_buffer_font
    ; System font, no embedded font asset or font licensing dependency.
    mov ecx,-17
    call ui_make_font
    mov [ui_font],rax
    mov ecx,-30
    call ui_make_font
    mov [ui_big_font],rax
ui_buffer_font:
    mov rcx,[ui_dc]
    mov rdx,[ui_font]
    call SelectObject
ui_buffer_done:
    add rsp,136
    ret
ui_make_buffer ENDP
ui_make_font PROC
    sub rsp,120
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    mov qword ptr [rsp+32],400
    mov qword ptr [rsp+40],0
    mov qword ptr [rsp+48],0
    mov qword ptr [rsp+56],0
    mov qword ptr [rsp+64],1
    mov qword ptr [rsp+72],0
    mov qword ptr [rsp+80],0
    mov qword ptr [rsp+88],5
    mov qword ptr [rsp+96],1
    lea rax,ui_font_name
    mov [rsp+104],rax
    call CreateFontW
    add rsp,120
    ret
ui_make_font ENDP

; ECX=x, EDX=y, R8D=width, R9D=height, EAX=0x00RRGGBB.
; Pixel writes are bounded even while a resize invalidates the old geometry.
ui_rect PROC
    push rbx
    push rsi
    push rdi
    mov ebx,eax
    cmp ecx,0
    jl ui_rect_done
    cmp edx,0
    jl ui_rect_done
    cmp ecx,[ui_width]
    jae ui_rect_done
    cmp edx,[ui_height]
    jae ui_rect_done
    mov eax,[ui_width]
    sub eax,ecx
    cmp r8d,eax
    cmova r8d,eax
    mov eax,[ui_height]
    sub eax,edx
    cmp r9d,eax
    cmova r9d,eax
    test r8d,r8d
    jz ui_rect_done
    test r9d,r9d
    jz ui_rect_done
    mov eax,edx
    imul eax,[ui_width]
    add eax,ecx
    mov rdi,[ui_pixels]
    lea rdi,[rdi+rax*4]
    mov esi,[ui_width]
    sub esi,r8d
    shl esi,2
    mov eax,ebx
ui_rect_row:
    mov ecx,r8d
    rep stosd
    add rdi,rsi
    dec r9d
    jnz ui_rect_row
ui_rect_done:
    pop rdi
    pop rsi
    pop rbx
    ret
ui_rect ENDP

; RCX=wide text, EDX=x, R8D=y, R9D=RGB text colour.
ui_text PROC
    sub rsp,72
    mov [rsp+40],rcx
    mov [rsp+48],edx
    mov [rsp+52],r8d
    ; Convert 0xRRGGBB to COLORREF 0xBBGGRR.
    mov eax,r9d
    bswap eax
    shr eax,8
    mov edx,eax
    mov rcx,[ui_dc]
    call SetTextColor
    mov r9,[rsp+40]
    xor eax,eax
ui_text_length:
    cmp word ptr [r9+rax*2],0
    je ui_text_emit
    inc eax
    jmp ui_text_length
ui_text_emit:
    mov [rsp+32],rax
    mov rcx,[ui_dc]
    mov edx,[rsp+48]
    mov r8d,[rsp+52]
    call TextOutW
    add rsp,72
    ret
ui_text ENDP

; RCX=wide text, EDX=y. Centered and ellipsized for long filenames.
ui_center_text PROC
    sub rsp,56
    mov [rsp+40],rcx
    mov dword ptr [ui_text_rect],32
    mov [ui_text_rect+4],edx
    mov eax,[ui_width]
    sub eax,32
    mov [ui_text_rect+8],eax
    add edx,42
    mov [ui_text_rect+12],edx
    mov rcx,[ui_dc]
    mov edx,00ede8e2h
    call SetTextColor
    mov rcx,[ui_dc]
    mov rdx,[rsp+40]
    mov r8d,-1
    lea r9,ui_text_rect
    mov qword ptr [rsp+32],00008821h ; CENTER | SINGLELINE | END_ELLIPSIS | NOPREFIX
    call DrawTextW
    add rsp,56
    ret
ui_center_text ENDP

; RAX=seconds, RCX=destination -> RCX advanced past mm:ss / hh:mm:ss.
ui_format_time PROC
    mov r10,rcx
    xor edx,edx
    mov r8d,3600
    div r8
    mov r9,rdx
    test eax,eax
    jz ui_time_minutes
    call ui_number
    mov word ptr [rcx],':'
    add rcx,2
ui_time_minutes:
    mov rax,r9
    xor edx,edx
    mov r8d,60
    div r8
    mov r9,rdx
    call ui_two_digits
    mov word ptr [rcx],':'
    add rcx,2
    mov rax,r9
    call ui_two_digits
    ret
ui_format_time ENDP
ui_two_digits PROC
    xor edx,edx
    mov r8d,10
    div r8d
    add eax,'0'
    add edx,'0'
    mov [rcx],ax
    mov [rcx+2],dx
    add rcx,4
    ret
ui_two_digits ENDP
ui_number PROC
    push rbx
    sub rsp,64
    lea rbx,[rsp+62]
    mov word ptr [rbx],0
    mov r8d,10
ui_number_digit:
    xor edx,edx
    div r8
    add edx,'0'
    sub rbx,2
    mov [rbx],dx
    test rax,rax
    jnz ui_number_digit
ui_number_copy:
    movzx eax,word ptr [rbx]
    test eax,eax
    jz ui_number_done
    mov [rcx],ax
    add rcx,2
    add rbx,2
    jmp ui_number_copy
ui_number_done:
    add rsp,64
    pop rbx
    ret
ui_number ENDP

ui_draw PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,48
    call ui_make_buffer
    cmp qword ptr [ui_pixels],0
    je ui_draw_done
    mov rdi,[ui_pixels]
    mov eax,[ui_background]
    mov ecx,[ui_width]
    imul ecx,[ui_height]
    rep stosd
    ; Compact editor-style header and status strip.
    xor ecx,ecx
    xor edx,edx
    mov r8d,[ui_width]
    mov r9d,52
    mov eax,[ui_surface]
    call ui_rect
    xor ecx,ecx
    mov edx,[ui_height]
    sub edx,30
    mov r8d,[ui_width]
    mov r9d,30
    mov eax,[ui_surface]
    call ui_rect
    lea rcx,ui_brand
    mov edx,24
    mov r8d,17
    mov r9d,[ui_text_color]
    call ui_text
    lea rcx,ui_assembly
    mov edx,[ui_width]
    sub edx,210
    mov r8d,17
    mov r9d,[ui_muted_color]
    call ui_text
    mov rcx,[ui_dc]
    mov rdx,[ui_big_font]
    call SelectObject
    lea rcx,ui_drop
    cmp dword ptr [ui_state],0
    je ui_draw_title
    mov rcx,[ui_filename]
    cmp dword ptr [ui_state],3
    jne ui_draw_title
    lea rcx,ui_error
ui_draw_title:
    mov edx,[ui_height]
    sub edx,72
    shr edx,1
    call ui_center_text
    mov rcx,[ui_dc]
    mov rdx,[ui_font]
    call SelectObject
    cmp dword ptr [ui_state],3
    jne ui_draw_center_hint
    lea rcx,ui_error_detail
    mov edx,[ui_height]
    shr edx,1
    call ui_center_text
    jmp ui_draw_status
ui_draw_center_hint:
    cmp dword ptr [ui_state],0
    jne ui_draw_status
    lea rcx,ui_open
    mov edx,[ui_height]
    shr edx,1
    call ui_center_text
ui_draw_status:
    lea rcx,ui_ready
    cmp dword ptr [ui_state],0
    je ui_status_ready
    cmp dword ptr [ui_state],3
    jne ui_status_not_error
    lea rcx,ui_failed
    jmp ui_status_ready
ui_status_not_error:
    lea rcx,ui_finished
    cmp dword ptr [ui_state],1
    jne ui_status_ready
    lea rcx,ui_playing
    cmp dword ptr [engine_ready],0
    jne ui_status_running
    lea rcx,ui_loading
    jmp ui_status_ready
ui_status_running:
    cmp dword ptr [pause_requested],0
    je ui_status_ready
    lea rcx,ui_paused
ui_status_ready:
    mov edx,24
    mov r8d,[ui_height]
    sub r8d,23
    mov r9d,[ui_accent]
    call ui_text
    mov eax,[codec_kind]
    test eax,eax
    jz ui_draw_hints
    cmp eax,5
    ja ui_draw_hints
    lea rcx,ui_codec_names
    mov rcx,[rcx+rax*8]
    mov edx,134
    mov r8d,[ui_height]
    sub r8d,23
    mov r9d,[ui_muted_color]
    call ui_text
ui_draw_hints:
    cmp dword ptr [ui_state],1
    jne ui_draw_controls
    cmp dword ptr [ui_controls],0
    je ui_draw_done
ui_draw_controls:
    lea rcx,ui_hint
    mov edx,32
    mov r8d,[ui_height]
    sub r8d,164
    mov r9d,[ui_muted_color]
    call ui_text
    ; Timeline and current position.
    mov ecx,32
    mov edx,[ui_height]
    sub edx,106
    mov r8d,[ui_width]
    sub r8d,64
    mov r9d,4
    mov eax,[ui_line]
    call ui_rect
    mov rax,[engine_position]
    cmp qword ptr [total_frames],0
    je ui_draw_time
    cmp rax,[total_frames]
    jbe ui_draw_progress
    mov rax,[total_frames]
ui_draw_progress:
    mov ecx,[ui_width]
    sub ecx,64
    mul rcx
    div qword ptr [total_frames]
    mov r8d,eax
    mov ecx,32
    mov edx,[ui_height]
    sub edx,106
    mov r9d,4
    mov eax,[ui_accent]
    call ui_rect
ui_draw_time:
    lea rcx,ui_time_text
    xor eax,eax
    mov r8d,[sample_rate]
    test r8d,r8d
    jz ui_draw_time_current
    mov rax,[engine_position]
    xor edx,edx
    div r8
ui_draw_time_current:
    call ui_format_time
    mov word ptr [rcx],' '
    mov word ptr [rcx+2],'/'
    mov word ptr [rcx+4],' '
    add rcx,6
    mov rax,[total_frames]
    mov r8d,[sample_rate]
    test r8d,r8d
    jz ui_draw_time_total_zero
    xor edx,edx
    div r8
    jmp ui_draw_time_total
ui_draw_time_total_zero:
    xor eax,eax
ui_draw_time_total:
    call ui_format_time
    mov word ptr [rcx],0
    lea rcx,ui_time_text
    mov edx,96
    mov r8d,[ui_height]
    sub r8d,71
    mov r9d,[ui_text_color]
    call ui_text
    ; Play triangle or two pause bars, rasterized directly in assembly.
    cmp qword ptr [ui_thread],0
    je ui_draw_play
    cmp dword ptr [pause_requested],0
    jne ui_draw_play
    mov ecx,42
    mov edx,[ui_height]
    sub edx,73
    mov r8d,5
    mov r9d,20
    mov eax,[ui_text_color]
    call ui_rect
    mov ecx,54
    mov edx,[ui_height]
    sub edx,73
    mov r8d,5
    mov r9d,20
    mov eax,[ui_text_color]
    call ui_rect
    jmp ui_draw_volume
ui_draw_play:
    xor ebx,ebx
ui_draw_triangle:
    mov eax,ebx
    sub eax,10
    jns ui_triangle_width
    neg eax
ui_triangle_width:
    mov r8d,14
    sub r8d,eax
    mov ecx,44
    mov edx,[ui_height]
    sub edx,73
    add edx,ebx
    mov r9d,1
    mov eax,[ui_text_color]
    call ui_rect
    inc ebx
    cmp ebx,21
    jb ui_draw_triangle
ui_draw_volume:
    lea rcx,ui_volume_text
    mov eax,[ui_volume_percent]
    call ui_number
    mov word ptr [rcx],'%'
    mov word ptr [rcx+2],0
    lea rcx,ui_volume_text
    mov edx,[ui_width]
    sub edx,178
    mov r8d,[ui_height]
    sub r8d,78
    mov r9d,[ui_muted_color]
    call ui_text
    mov ecx,[ui_width]
    sub ecx,180
    mov edx,[ui_height]
    sub edx,49
    mov r8d,148
    mov r9d,3
    mov eax,[ui_line]
    call ui_rect
    mov eax,[ui_volume_percent]
    imul eax,148
    xor edx,edx
    mov ecx,100
    div ecx
    mov r8d,eax
    mov ecx,[ui_width]
    sub ecx,180
    mov edx,[ui_height]
    sub edx,49
    mov r9d,3
    mov eax,[ui_accent]
    call ui_rect
ui_draw_done:
    add rsp,48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ui_draw ENDP
