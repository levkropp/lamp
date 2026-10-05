# Decode Floor 1 posts. RCX=floor, RDX=post array, R8=active array.
LOCALFN vb_floor_decode
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 104
    mov rsi, rcx
    mov rdi, rdx
    mov r12, r8
    VB_GET 1
    test eax, eax
    jz .Lvb_fd_absent
    mov eax, [rsi + FL_MULT]
    dec eax
    lea rdx, [rip + vb_range_table]
    mov eax, [rdx + rax*4]
    mov [rsp + 32], eax
    dec eax
    call vb_ilog
    call vb_bits
    mov [rdi], eax
    call vb_bits
    mov [rdi + 4], eax
    xor ebx, ebx
    mov ebp, 2
.Lvb_fd_partition:
    cmp ebx, [rsi + FL_PART]
    jae .Lvb_fd_predict
    mov eax, [rsi + rbx*4 + FL_PARTCLASS]
    mov r13d, [rsi + rax*4 + FL_DIM]
    mov r14d, [rsi + rax*4 + FL_SUB]
    mov r15d, eax
    shl r15d, 5
    xor edx, edx
    test r14d, r14d
    jz .Lvb_fd_partition_book
    mov ecx, [rsi + rax*4 + FL_MASTER]
    call vb_symbol
    mov edx, eax
.Lvb_fd_partition_book:
    mov ecx, r14d
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, edx
    shr edx, cl
    lea eax, [r15 + rax*4]
    mov ecx, [rsi + rax + FL_BOOKS]
    xor eax, eax
    test ecx, ecx
    js .Lvb_fd_post
    call vb_symbol
.Lvb_fd_post:
    mov [rdi + rbp*4], eax
    inc ebp
    dec r13d
    jnz .Lvb_fd_partition_book
    inc ebx
    jmp .Lvb_fd_partition
.Lvb_fd_predict:
    mov dword ptr [r12], 1
    mov dword ptr [r12 + 4], 1
    mov ebx, 2
.Lvb_fd_post_predict:
    cmp ebx, [rsi + FL_COUNT]
    jae .Lvb_fd_present
    mov r13d, [rsi + rbx*4 + FL_LOW]
    mov r14d, [rsi + rbx*4 + FL_HIGH]
    mov eax, [rdi + r14*4]
    sub eax, [rdi + r13*4]
    mov r15d, eax
    test eax, eax
    jns .Lvb_fd_dy
    neg eax
.Lvb_fd_dy:
    mov ecx, [rsi + rbx*4 + FL_X]
    sub ecx, [rsi + r13*4 + FL_X]
    imul eax, ecx
    xor edx, edx
    mov ecx, [rsi + r14*4 + FL_X]
    sub ecx, [rsi + r13*4 + FL_X]
    div ecx
    test r15d, r15d
    jns .Lvb_fd_prediction_positive
    neg eax
.Lvb_fd_prediction_positive:
    add eax, [rdi + r13*4]
    mov r15d, eax             # prediction / lowroom
    mov ecx, [rsp + 32]
    sub ecx, eax             # highroom
    mov edx, ecx
    cmp edx, eax
    cmova edx, eax
    shl edx, 1               # room
    mov eax, [rdi + rbx*4]
    test eax, eax
    jz .Lvb_fd_predicted_only
    mov dword ptr [r12 + r13*4], 1
    mov dword ptr [r12 + r14*4], 1
    mov dword ptr [r12 + rbx*4], 1
    cmp eax, edx
    jae .Lvb_fd_outside_room
    test eax, 1
    jz .Lvb_fd_even
    inc eax
    shr eax, 1
    neg eax
    jmp .Lvb_fd_add_prediction
.Lvb_fd_even:
    shr eax, 1
    jmp .Lvb_fd_add_prediction
.Lvb_fd_outside_room:
    cmp ecx, r15d
    jbe .Lvb_fd_room_low
    sub eax, r15d
    jmp .Lvb_fd_add_prediction
.Lvb_fd_room_low:
    neg eax
    add eax, ecx
    dec eax
.Lvb_fd_add_prediction:
    add eax, r15d
    cmp eax, [rsp + 32]
    jae .Lvb_fd_bad
    mov [rdi + rbx*4], eax
    jmp .Lvb_fd_predict_next
.Lvb_fd_predicted_only:
    mov dword ptr [r12 + rbx*4], 0
    mov [rdi + rbx*4], r15d
.Lvb_fd_predict_next:
    inc ebx
    jmp .Lvb_fd_post_predict
.Lvb_fd_bad:
    mov dword ptr [rip + vb_bad], 1
.Lvb_fd_absent:
    xor eax, eax
    jmp .Lvb_fd_done
.Lvb_fd_present:
    mov eax, 1
.Lvb_fd_done:
    add rsp, 104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_floor_decode

# Multiply spectrum by the specified integer Bresenham floor segment.
# RCX=spectrum, EDX=x0, R8D=y0, R9D=x1, [rsp+40]=y1.
LOCALFN vb_line
    push rbp
    push rbx
    push rsi
    push rdi
    mov rsi, rcx
    mov edi, edx
    mov ebx, r8d
    mov ebp, r9d
    mov ecx, r9d
    sub ecx, edx             # dx
    mov eax, [rsp + 72]
    sub eax, ebx             # dy
    cdq
    idiv ecx
    mov r8d, eax             # signed base
    mov r9d, eax
    mov r10d, edx
    test r10d, r10d
    jns .Lvb_line_rise
    neg r10d
    dec r9d
    jmp .Lvb_line_bound
.Lvb_line_rise:
    inc r9d
.Lvb_line_bound:
    mov eax, [rip + vb_n]
    shr eax, 1
    cmp ebp, eax
    cmova ebp, eax
    xor r11d, r11d
    lea rbp, [rbp]            # keeps upper half clean
    cmp edi, ebp
    jae .Lvb_line_done
    lea rdx, [rip + vb_inverse_db]
.Lvb_line_pixel:
    mov eax, ebx
    and eax, 255
    movss xmm0, dword ptr [rdx + rax*4]
    mulss xmm0, dword ptr [rsi + rdi*4]
    movss dword ptr [rsi + rdi*4], xmm0
    add r11d, r10d
    cmp r11d, ecx
    jb .Lvb_line_base
    sub r11d, ecx
    add ebx, r9d
    jmp .Lvb_line_next
.Lvb_line_base:
    add ebx, r8d
.Lvb_line_next:
    inc edi
    cmp edi, ebp
    jb .Lvb_line_pixel
.Lvb_line_done:
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_line

# RCX=floor, RDX=posts, R8=active, R9=spectrum.
LOCALFN vb_floor_apply
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
    mov r12, r8
    mov r13, r9
    xor r14d, r14d
    mov r15d, [rdi]
    imul r15d, [rsi + FL_MULT]
    mov ebx, 1
.Lvb_fa_post:
    cmp ebx, [rsi + FL_COUNT]
    jae .Lvb_fa_tail
    mov eax, [rsi + rbx*4 + FL_SORT]
    cmp dword ptr [r12 + rax*4], 0
    je .Lvb_fa_next
    mov r9d, [rsi + rax*4 + FL_X]
    mov eax, [rdi + rax*4]
    imul eax, [rsi + FL_MULT]
    mov [rsp + 32], eax
    mov [rsp + 40], r9d
    mov rcx, r13
    mov edx, r14d
    mov r8d, r15d
    call vb_line
    mov r14d, [rsp + 40]
    mov r15d, [rsp + 32]
.Lvb_fa_next:
    inc ebx
    jmp .Lvb_fa_post
.Lvb_fa_tail:
    mov eax, [rip + vb_n]
    shr eax, 1
    lea rdx, [rip + vb_inverse_db]
    movss xmm0, dword ptr [rdx + r15*4]
.Lvb_fa_tail_loop:
    cmp r14d, eax
    jae .Lvb_fa_done
    movss xmm1, dword ptr [r13 + r14*4]
    mulss xmm1, xmm0
    movss dword ptr [r13 + r14*4], xmm1
    inc r14d
    jmp .Lvb_fa_tail_loop
.Lvb_fa_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vb_floor_apply

# RCX=book index, EDX=partition offset, R8D=partition length,
# R9D=group channel. Adds vectors to the mapped spectrum buffers.
LOCALFN vb_residue_vector
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov [rsp + 32], ecx
    mov r12d, edx
    mov r13d, r8d
    mov r14d, r9d
    mov eax, ecx
    shl eax, 6
    lea rsi, [rip + vb_books]
    add rsi, rax
    mov r15d, [rsi + CB_DIM]
    mov ebp, 1
    cmp dword ptr [rip + vb_rs_type], 0
    jne .Lvb_rv_sequential
    mov eax, r13d
    xor edx, edx
    div r15d
    mov ebp, eax
    xor ebx, ebx
.Lvb_rv_type0:
    cmp ebx, ebp
    jae .Lvb_rv_done
    mov ecx, [rsp + 32]
    call vb_symbol
    imul eax, r15d
    mov rdi, [rsi + CB_VECTOR]
    lea rdi, [rdi + rax*4]
    xor r8d, r8d
.Lvb_rv_type0_component:
    mov eax, r8d
    imul eax, ebp
    add eax, ebx
    add eax, r12d
    lea rdx, [rip + vb_rs_channel]
    mov edx, [rdx + r14*4]
    shl edx, 12
    add eax, edx
    mov rdx, [rip + vb_spectrum_ptr]
    movss xmm0, dword ptr [rdi + r8*4]
    addss xmm0, dword ptr [rdx + rax*4]
    movss dword ptr [rdx + rax*4], xmm0
    inc r8d
    cmp r8d, r15d
    jb .Lvb_rv_type0_component
    inc ebx
    jmp .Lvb_rv_type0
.Lvb_rv_sequential:
    xor ebx, ebx
.Lvb_rv_sequential_word:
    cmp ebx, r13d
    jae .Lvb_rv_done
    mov ecx, [rsp + 32]
    call vb_symbol
    imul eax, r15d
    mov rdi, [rsi + CB_VECTOR]
    lea rdi, [rdi + rax*4]
    xor r8d, r8d
.Lvb_rv_component:
    cmp ebx, r13d
    jae .Lvb_rv_done
    lea eax, [r12 + rbx]
    mov ecx, r14d
    cmp dword ptr [rip + vb_rs_type], 2
    jne .Lvb_rv_channel
    xor edx, edx
    div dword ptr [rip + vb_rs_channels]
    mov ecx, edx
.Lvb_rv_channel:
    lea rdx, [rip + vb_rs_channel]
    mov edx, [rdx + rcx*4]
    shl edx, 12
    add eax, edx
    mov rdx, [rip + vb_spectrum_ptr]
    movss xmm0, dword ptr [rdi + r8*4]
    addss xmm0, dword ptr [rdx + rax*4]
    movss dword ptr [rdx + rax*4], xmm0
    inc ebx
    inc r8d
    cmp r8d, r15d
    jb .Lvb_rv_component
    jmp .Lvb_rv_sequential_word
.Lvb_rv_done:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_residue_vector

# RCX=residue, RDX=mapping, R8D=submap. All types, 1..255 channels.
LOCALFN vb_residue
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov rsi, rcx
    mov [rip + vb_rs_ptr], rcx
    xor ebx, ebx
    xor edi, edi
.Lvb_rs_find_channel:
    cmp ebx, [rip + source_channels]
    jae .Lvb_rs_channels_done
    cmp [rdx + rbx*4 + MP_MUX], r8d
    jne .Lvb_rs_find_next
    lea rax, [rip + vb_rs_channel]
    mov [rax + rdi*4], ebx
    lea rax, [rip + vb_zero]
    mov eax, [rax + rbx*4]
    xor eax, 1
    lea rcx, [rip + vb_rs_active]
    mov [rcx + rdi*4], eax
    inc edi
.Lvb_rs_find_next:
    inc ebx
    jmp .Lvb_rs_find_channel
.Lvb_rs_channels_done:
    test edi, edi
    jz .Lvb_rs_done
    mov [rip + vb_rs_channels], edi
    mov [rip + vb_rs_groups], edi
    mov eax, [rsi + RS_TYPE]
    mov [rip + vb_rs_type], eax
    cmp eax, 2
    jne .Lvb_rs_size
    mov dword ptr [rip + vb_rs_groups], 1
    xor eax, eax
    xor ecx, ecx
    lea rdx, [rip + vb_rs_active]
.Lvb_rs_type2_active:
    or eax, [rdx + rcx*4]
    inc ecx
    cmp ecx, edi
    jb .Lvb_rs_type2_active
    mov [rip + vb_rs_active], eax
.Lvb_rs_size:
    mov eax, [rip + vb_n]
    shr eax, 1
    cmp dword ptr [rip + vb_rs_type], 2
    jne .Lvb_rs_limit
    imul eax, edi
.Lvb_rs_limit:
    mov edx, [rsi + RS_BEGIN]
    cmp edx, eax
    cmova edx, eax
    mov [rip + vb_rs_begin], edx
    mov ecx, [rsi + RS_END]
    cmp ecx, eax
    cmova ecx, eax
    sub ecx, edx
    mov eax, ecx
    xor edx, edx
    div dword ptr [rsi + RS_PART]
    mov [rip + vb_rs_parts], eax
    test eax, eax
    jz .Lvb_rs_done
    mov eax, [rsi + RS_BOOK]
    shl eax, 6
    lea rdx, [rip + vb_books]
    mov eax, [rdx + rax + CB_DIM]
    mov [rip + vb_rs_words], eax
    xor r12d, r12d           # pass
.Lvb_rs_pass:
    xor r13d, r13d           # partition base for classword
.Lvb_rs_group:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lvb_rs_not_cancelled
    cmp dword ptr [rax], 0
    je .Lvb_rs_not_cancelled
    mov dword ptr [rip + vb_bad], 1
    jmp .Lvb_rs_done
.Lvb_rs_not_cancelled:
    cmp r13d, [rip + vb_rs_parts]
    jae .Lvb_rs_pass_next
    test r12d, r12d
    jnz .Lvb_rs_partition_start
    xor r15d, r15d
.Lvb_rs_class_channel:
    lea rax, [rip + vb_rs_active]
    cmp dword ptr [rax + r15*4], 0
    je .Lvb_rs_class_next
    mov ecx, [rsi + RS_BOOK]
    call vb_symbol
    mov ebx, [rip + vb_rs_words]
    dec ebx
.Lvb_rs_class_digit:
    xor edx, edx
    div dword ptr [rsi + RS_CLASSES]
    mov ecx, r15d
    shl ecx, 14
    add ecx, r13d
    add ecx, ebx
    mov rdi, [rip + vb_classdata_ptr]
    mov [rdi + rcx*4], edx
    dec ebx
    jns .Lvb_rs_class_digit
.Lvb_rs_class_next:
    inc r15d
    cmp r15d, [rip + vb_rs_groups]
    jb .Lvb_rs_class_channel
.Lvb_rs_partition_start:
    xor r14d, r14d
.Lvb_rs_partition:
    lea eax, [r13 + r14]
    cmp eax, [rip + vb_rs_parts]
    jae .Lvb_rs_group_next
    xor r15d, r15d
.Lvb_rs_partition_channel:
    lea rax, [rip + vb_rs_active]
    cmp dword ptr [rax + r15*4], 0
    je .Lvb_rs_partition_next_channel
    mov eax, r15d
    shl eax, 14
    add eax, r13d
    add eax, r14d
    mov rdi, [rip + vb_classdata_ptr]
    mov eax, [rdi + rax*4]
    shl eax, 5
    lea eax, [rax + r12*4]
    mov ecx, [rsi + rax + RS_BOOKS]
    test ecx, ecx
    js .Lvb_rs_partition_next_channel
    lea edx, [r13 + r14]
    imul edx, [rsi + RS_PART]
    add edx, [rip + vb_rs_begin]
    mov r8d, [rsi + RS_PART]
    mov r9d, r15d
    call vb_residue_vector
.Lvb_rs_partition_next_channel:
    inc r15d
    cmp r15d, [rip + vb_rs_groups]
    jb .Lvb_rs_partition_channel
    inc r14d
    cmp r14d, [rip + vb_rs_words]
    jb .Lvb_rs_partition
.Lvb_rs_group_next:
    add r13d, [rip + vb_rs_words]
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_rs_done
    jmp .Lvb_rs_group
.Lvb_rs_pass_next:
    inc r12d
    cmp r12d, 8
    jb .Lvb_rs_pass
.Lvb_rs_done:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_residue

# Decode one complete packet into a fixed interleaved stereo PCM buffer.
# Shared packet mode/window prefix for decoding and structural seek indexing.
LOCALFN vb_packet_header
    push rbx
    push rsi
    push r13
    push r14
    sub rsp, 40
    lea rcx, [rax + rdx]
    mov [rip + vb_end], rcx
    mov [rip + vb_ptr], rax
    mov qword ptr [rip + vb_acc], 0
    mov dword ptr [rip + vb_count], 0
    mov dword ptr [rip + vb_bad], 0
    VB_GET 1
    test eax, eax
    jnz .Lvb_packet_bad
    mov ecx, [rip + vb_mode_bits]
    call vb_bits
    cmp eax, [rip + vb_modes_count]
    jae .Lvb_packet_bad
    lea rdx, [rip + vb_modes]
    mov ecx, [rdx + rax*8 + 4]
    mov eax, [rdx + rax*8]
    mov [rip + vb_block], eax
    imul ecx, MP_SIZE
    lea rsi, [rip + vb_maps]
    add rsi, rcx
    mov [rip + vb_current_map], rsi
    mov ebx, [rip + vb_short]
    xor r13d, r13d
    xor r14d, r14d
    test eax, eax
    jz .Lvb_packet_window
    mov ebx, [rip + vb_long]
    VB_GET 1
    mov r13d, eax
    VB_GET 1
    mov r14d, eax
.Lvb_packet_window:
    mov [rip + vb_n], ebx
    mov eax, ebx
    shr eax, 1
    mov dword ptr [rip + vb_left], 0
    mov [rip + vb_left_end], eax
    mov [rip + vb_right], eax
    mov [rip + vb_right_end], ebx
    cmp dword ptr [rip + vb_block], 0
    je .Lvb_packet_ready
    test r13d, r13d
    jnz .Lvb_packet_right_window
    mov eax, ebx
    sub eax, [rip + vb_short]
    shr eax, 2
    mov [rip + vb_left], eax
    mov eax, ebx
    add eax, [rip + vb_short]
    shr eax, 2
    mov [rip + vb_left_end], eax
.Lvb_packet_right_window:
    test r14d, r14d
    jnz .Lvb_packet_ready
    lea eax, [rbx + rbx*2]
    sub eax, [rip + vb_short]
    shr eax, 2
    mov [rip + vb_right], eax
    lea eax, [rbx + rbx*2]
    add eax, [rip + vb_short]
    shr eax, 2
    mov [rip + vb_right_end], eax
.Lvb_packet_ready:
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_packet_bad
    mov eax, 1
    jmp .Lvb_packet_return
.Lvb_packet_bad:
    xor eax, eax
.Lvb_packet_return:
    add rsp, 40
    pop r14
    pop r13
    pop rsi
    pop rbx
    ret
ENDFN vb_packet_header

LOCALFN vb_frame
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    call ogg_next
    test rax, rax
    jz .Lvb_frame_eof
    call vb_packet_header
    test eax, eax
    jz .Lvb_frame_bad
    mov rsi, [rip + vb_current_map]
.Lvb_frame_clear:
    mov rdi, [rip + vb_spectrum_ptr]
    xor eax, eax
    mov ecx, [rip + source_channels]
    shl ecx, 11
    rep stosq
    xor r12d, r12d
.Lvb_frame_floor:
    mov eax, [rsi + r12*4 + MP_MUX]
    mov eax, [rsi + rax*4 + MP_FLOOR]
    imul eax, FL_SIZE
    lea rcx, [rip + vb_floors]
    add rcx, rax
    lea rdx, [rip + vb_floor_channel]
    mov [rdx + r12*8], rcx
    mov eax, r12d
    shl eax, 10
    mov rdx, [rip + vb_y_ptr]
    add rdx, rax
    mov r8, [rip + vb_active_ptr]
    add r8, rax
    call vb_floor_decode
    xor eax, 1
    lea rdx, [rip + vb_zero]
    mov [rdx + r12*4], eax
    lea rdx, [rip + vb_really_zero]
    mov [rdx + r12*4], eax
    inc r12d
    cmp r12d, [rip + source_channels]
    jb .Lvb_frame_floor
    xor ebx, ebx
.Lvb_frame_activate:
    cmp ebx, [rsi + MP_COUPLE]
    jae .Lvb_frame_residue_start
    mov eax, [rsi + rbx*4 + MP_MAG]
    mov edx, [rsi + rbx*4 + MP_ANGLE]
    lea rcx, [rip + vb_zero]
    cmp dword ptr [rcx + rax*4], 0
    je .Lvb_frame_pair_active
    cmp dword ptr [rcx + rdx*4], 0
    jne .Lvb_frame_activate_next
.Lvb_frame_pair_active:
    mov dword ptr [rcx + rax*4], 0
    mov dword ptr [rcx + rdx*4], 0
.Lvb_frame_activate_next:
    inc ebx
    jmp .Lvb_frame_activate
.Lvb_frame_residue_start:
    xor ebx, ebx
.Lvb_frame_residue:
    mov eax, [rsi + rbx*4 + MP_RESIDUE]
    imul eax, RS_SIZE
    lea rcx, [rip + vb_residues]
    add rcx, rax
    mov rdx, rsi
    mov r8d, ebx
    call vb_residue
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_frame_bad
    inc ebx
    cmp ebx, [rsi + MP_SUBMAPS]
    jb .Lvb_frame_residue
    mov ebx, [rsi + MP_COUPLE]
    pxor xmm5, xmm5
.Lvb_frame_couple:
    dec ebx
    js .Lvb_frame_apply_start
    mov eax, [rsi + rbx*4 + MP_MAG]
    mov edx, [rsi + rbx*4 + MP_ANGLE]
    shl eax, 14
    shl edx, 14
    mov rdi, [rip + vb_spectrum_ptr]
    lea rcx, [rdi + rax]
    add rdi, rdx
    xor r8d, r8d
    mov r9d, [rip + vb_n]
    shr r9d, 1
.Lvb_frame_couple_bin:
    movss xmm0, dword ptr [rcx + r8*4]
    movss xmm1, dword ptr [rdi + r8*4]
    movss xmm2, xmm0
    movss xmm3, xmm0
    comiss xmm0, xmm5
    jbe .Lvb_frame_negative_m
    comiss xmm1, xmm5
    jbe .Lvb_frame_positive_m_negative_a
    subss xmm3, xmm1
    jmp .Lvb_frame_pair_store
.Lvb_frame_positive_m_negative_a:
    addss xmm2, xmm1
    jmp .Lvb_frame_pair_store
.Lvb_frame_negative_m:
    comiss xmm1, xmm5
    jbe .Lvb_frame_both_negative
    addss xmm3, xmm1
    jmp .Lvb_frame_pair_store
.Lvb_frame_both_negative:
    subss xmm2, xmm1
.Lvb_frame_pair_store:
    movss dword ptr [rcx + r8*4], xmm2
    movss dword ptr [rdi + r8*4], xmm3
    inc r8d
    cmp r8d, r9d
    jb .Lvb_frame_couple_bin
    jmp .Lvb_frame_couple
.Lvb_frame_apply_start:
    xor r12d, r12d
.Lvb_frame_apply:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lvb_frame_apply_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lvb_frame_bad
.Lvb_frame_apply_not_cancelled:
    mov eax, r12d
    shl eax, 14
    mov r13, [rip + vb_spectrum_ptr]
    add r13, rax
    lea rdx, [rip + vb_really_zero]
    cmp dword ptr [rdx + r12*4], 0
    jne .Lvb_frame_zero_channel
    lea rcx, [rip + vb_floor_channel]
    mov rcx, [rcx + r12*8]
    mov eax, r12d
    shl eax, 10
    mov rdx, [rip + vb_y_ptr]
    add rdx, rax
    mov r8, [rip + vb_active_ptr]
    add r8, rax
    mov r9, r13
    call vb_floor_apply
    jmp .Lvb_frame_transform
.Lvb_frame_zero_channel:
    mov rdi, r13
    xor eax, eax
    mov ecx, [rip + vb_n]
    shr ecx, 2
    rep stosq
.Lvb_frame_transform:
    mov eax, r12d
    shl eax, 15
    mov rdx, [rip + vb_time_ptr]
    add rdx, rax
    mov rcx, r13
    mov r8d, [rip + vb_n]
    mov r9d, [rip + vb_block]
    call vb_imdct
    inc r12d
    cmp r12d, [rip + source_channels]
    jb .Lvb_frame_apply
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_frame_bad
    mov r13d, [rip + vb_previous]
    mov r14d, [rip + vb_right]
    sub r14d, [rip + vb_left]
    mov dword ptr [rip + vb_available], 0
    mov dword ptr [rip + vb_used], 0
    test r13d, r13d
    jnz .Lvb_frame_with_overlap
    cmp dword ptr [rip + vb_first], 1
    jne .Lvb_frame_save_tail
    mov eax, [rip + vb_n]
    shr eax, 1
    mov [rip + vb_left], eax
    mov r14d, [rip + vb_right]
    sub r14d, eax
    jz .Lvb_frame_save_tail
    jmp .Lvb_frame_post_overlap
.Lvb_frame_with_overlap:
    mov eax, [rip + vb_left_end]
    sub eax, [rip + vb_left]
    cmp eax, r13d
    jne .Lvb_frame_bad
    # Select the half-window matching the overlap width.
    lea r15, [rip + vb_windows]
    mov eax, r13d
    shl eax, 1
    cmp eax, [rip + vb_short]
    je .Lvb_frame_window_ready
    cmp eax, [rip + vb_long]
    jne .Lvb_frame_bad
    add r15, 65536
.Lvb_frame_window_ready:
    xor r12d, r12d
.Lvb_frame_overlap_channel:
    mov eax, r12d
    shl eax, 15
    mov rsi, [rip + vb_time_ptr]
    add rsi, rax
    mov eax, r12d
    shl eax, 14
    mov rdi, [rip + vb_tail_ptr]
    add rdi, rax
    xor ebx, ebx
.Lvb_frame_overlap_sample:
    mov eax, [rip + vb_left]
    add eax, ebx
    cvtss2sd xmm0, dword ptr [rsi + rax*4]
    mulsd xmm0, qword ptr [r15 + rbx*8]
    mov edx, r13d
    sub edx, ebx
    dec edx
    cvtss2sd xmm1, dword ptr [rdi + rbx*4]
    mulsd xmm1, qword ptr [r15 + rdx*8]
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss dword ptr [rsi + rax*4], xmm0
    inc ebx
    cmp ebx, r13d
    jb .Lvb_frame_overlap_sample
    inc r12d
    cmp r12d, [rip + source_channels]
    jb .Lvb_frame_overlap_channel
.Lvb_frame_post_overlap:
    # Initial negative granule origin crops at most the first overlap span.
    mov eax, [rip + vb_trim_start]
    cmp eax, r14d
    cmova eax, r14d
    sub [rip + vb_trim_start], eax
    mov [rip + vb_frame_skip], eax
    sub r14d, eax
    # End granule trims encoder padding. No unsigned wrap on malformed totals.
    mov rax, [rip + total_frames]
    sub rax, [rip + vb_emitted]
    jc .Lvb_frame_bad
    cmp rax, r14
    jae .Lvb_frame_output_count
    mov r14d, eax
.Lvb_frame_output_count:
    mov [rip + vb_available], r14d
    add [rip + vb_emitted], r14
    mov rsi, [rip + vb_time_ptr]
    mov eax, [rip + vb_left]
    add eax, [rip + vb_frame_skip]
    lea rsi, [rsi + rax*4]
    lea rdi, [rip + vb_pcm]
    xor ebx, ebx
.Lvb_frame_interleave:
    cmp ebx, r14d
    jae .Lvb_frame_save_tail
    # Validate all native channels, including application-defined ports that
    # are not included in stereo output. No corrupt channel is silently lost.
    mov r8, rsi
    xor ecx, ecx
.Lvb_frame_validate_channel:
    mov edx, [r8 + rbx*4]
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lvb_frame_bad
    add r8, 32768
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lvb_frame_validate_channel
    cmp dword ptr [rip + source_channels], 2
    jbe .Lvb_frame_ports
    cmp dword ptr [rip + source_channels], 8
    ja .Lvb_frame_ports
    lea r9, [rip + vb_mix_coeff]
    mov r8, rsi
    xor ecx, ecx
    xorpd xmm4, xmm4
    xorpd xmm5, xmm5
.Lvb_frame_mix_channel:
    cvtss2sd xmm0, dword ptr [r8 + rbx*4]
    movapd xmm1, xmm0
    mulsd xmm0, qword ptr [r9]
    mulsd xmm1, qword ptr [r9 + 8]
    addsd xmm4, xmm0
    addsd xmm5, xmm1
    add r8, 32768
    add r9, 16
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lvb_frame_mix_channel
    cvtsd2ss xmm4, xmm4
    cvtsd2ss xmm5, xmm5
    movd eax, xmm4
    movd edx, xmm5
    mov ecx, eax
    and ecx, 0x7fffffff
    cmp ecx, 0x7f800000
    jae .Lvb_frame_bad
    mov ecx, edx
    and ecx, 0x7fffffff
    cmp ecx, 0x7f800000
    jae .Lvb_frame_bad
    mov [rdi + rbx*8], eax
    mov [rdi + rbx*8 + 4], edx
    jmp .Lvb_frame_interleave_next
.Lvb_frame_ports:
    mov eax, [rsi + rbx*4]
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lvb_frame_bad
    mov [rdi + rbx*8], eax
    cmp dword ptr [rip + source_channels], 1
    je .Lvb_frame_mono
    mov eax, [rsi + rbx*4 + 32768]
.Lvb_frame_mono:
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    jae .Lvb_frame_bad
    mov [rdi + rbx*8 + 4], eax
.Lvb_frame_interleave_next:
    inc ebx
    jmp .Lvb_frame_interleave
.Lvb_frame_save_tail:
    mov eax, [rip + vb_right_end]
    sub eax, [rip + vb_right]
    mov [rip + vb_previous], eax
    mov r14d, eax
    xor r12d, r12d
.Lvb_frame_tail_channel:
    mov eax, r12d
    shl eax, 15
    mov rsi, [rip + vb_time_ptr]
    add rsi, rax
    mov eax, [rip + vb_right]
    lea rsi, [rsi + rax*4]
    mov eax, r12d
    shl eax, 14
    mov rdi, [rip + vb_tail_ptr]
    add rdi, rax
    mov ecx, r14d
    rep movsd
    inc r12d
    cmp r12d, [rip + source_channels]
    jb .Lvb_frame_tail_channel
    mov dword ptr [rip + vb_first], 0
    mov eax, 1
    jmp .Lvb_frame_done
.Lvb_frame_bad:
    mov dword ptr [rip + decode_error], 24
.Lvb_frame_eof:
    xor eax, eax
.Lvb_frame_done:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_frame

FN vorbis_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
.Lvb_read_more:
    cmp ebx, r12d
    jae .Lvb_read_done
    cmp qword ptr [rip + vb_arena], 0
    je .Lvb_read_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lvb_read_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lvb_read_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lvb_read_cancelled
.Lvb_read_not_cancelled:
    mov eax, [rip + vb_used]
    cmp eax, [rip + vb_available]
    jb .Lvb_read_copy
    call vb_frame
    test eax, eax
    jz .Lvb_read_done
    jmp .Lvb_read_more
.Lvb_read_copy:
    mov r13d, [rip + vb_available]
    sub r13d, eax
    mov edx, r12d
    sub edx, ebx
    cmp r13d, edx
    cmova r13d, edx
    lea rsi, [rip + vb_pcm]
    lea rsi, [rsi + rax*8]
    mov ecx, r13d
    rep movsq
    add [rip + vb_used], r13d
    add ebx, r13d
    jmp .Lvb_read_more
.Lvb_read_cancelled:
    mov dword ptr [rip + decode_error], 24
.Lvb_read_done:
    mov eax, ebx
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vorbis_read

# RCX=interleaved native-channel float32 destination; EDX=frame capacity.
# Shares the stereo reader's cursor and validated frame cache. Channels retain
# encoded Vorbis order; no duplicate multichannel PCM allocation is needed.
FN vorbis_read_native
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
.Lvb_native_more:
    cmp ebx, r12d
    jae .Lvb_native_done
    cmp qword ptr [rip + vb_arena], 0
    je .Lvb_native_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lvb_native_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lvb_native_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lvb_native_cancelled
.Lvb_native_not_cancelled:
    mov eax, [rip + vb_used]
    cmp eax, [rip + vb_available]
    jb .Lvb_native_copy
    call vb_frame
    test eax, eax
    jz .Lvb_native_done
    jmp .Lvb_native_more
.Lvb_native_copy:
    mov r13d, [rip + vb_available]
    sub r13d, eax
    mov edx, r12d
    sub edx, ebx
    cmp r13d, edx
    cmova r13d, edx
    add eax, [rip + vb_left]
    add eax, [rip + vb_frame_skip]
    mov rsi, [rip + vb_time_ptr]
    lea rsi, [rsi + rax*4]
    xor r9d, r9d
.Lvb_native_frame:
    mov r8, rsi
    xor ecx, ecx
.Lvb_native_channel:
    mov eax, [r8 + r9*4]
    mov [rdi], eax
    add rdi, 4
    add r8, 32768
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lvb_native_channel
    inc r9d
    cmp r9d, r13d
    jb .Lvb_native_frame
    add [rip + vb_used], r13d
    add ebx, r13d
    jmp .Lvb_native_more
.Lvb_native_cancelled:
    mov dword ptr [rip + decode_error], 24
.Lvb_native_done:
    mov eax, ebx
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vorbis_read_native
