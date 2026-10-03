; Decode Floor 1 posts. RCX=floor, RDX=post array, R8=active array.
vb_floor_decode PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,104
    mov rsi,rcx
    mov rdi,rdx
    mov r12,r8
    VB_GET 1
    test eax,eax
    jz vb_fd_absent
    mov eax,[rsi+FL_MULT]
    dec eax
    lea rdx,vb_range_table
    mov eax,[rdx+rax*4]
    mov [rsp+32],eax
    dec eax
    call vb_ilog
    call vb_bits
    mov [rdi],eax
    call vb_bits
    mov [rdi+4],eax
    xor ebx,ebx
    mov ebp,2
vb_fd_partition:
    cmp ebx,[rsi+FL_PART]
    jae vb_fd_predict
    mov eax,[rsi+rbx*4+FL_PARTCLASS]
    mov r13d,[rsi+rax*4+FL_DIM]
    mov r14d,[rsi+rax*4+FL_SUB]
    mov r15d,eax
    shl r15d,5
    xor edx,edx
    test r14d,r14d
    jz vb_fd_partition_book
    mov ecx,[rsi+rax*4+FL_MASTER]
    call vb_symbol
    mov edx,eax
vb_fd_partition_book:
    mov ecx,r14d
    mov eax,1
    shl eax,cl
    dec eax
    and eax,edx
    shr edx,cl
    lea eax,[r15+rax*4]
    mov ecx,[rsi+rax+FL_BOOKS]
    xor eax,eax
    test ecx,ecx
    js vb_fd_post
    call vb_symbol
vb_fd_post:
    mov [rdi+rbp*4],eax
    inc ebp
    dec r13d
    jnz vb_fd_partition_book
    inc ebx
    jmp vb_fd_partition
vb_fd_predict:
    mov dword ptr [r12],1
    mov dword ptr [r12+4],1
    mov ebx,2
vb_fd_post_predict:
    cmp ebx,[rsi+FL_COUNT]
    jae vb_fd_present
    mov r13d,[rsi+rbx*4+FL_LOW]
    mov r14d,[rsi+rbx*4+FL_HIGH]
    mov eax,[rdi+r14*4]
    sub eax,[rdi+r13*4]
    mov r15d,eax
    test eax,eax
    jns vb_fd_dy
    neg eax
vb_fd_dy:
    mov ecx,[rsi+rbx*4+FL_X]
    sub ecx,[rsi+r13*4+FL_X]
    imul eax,ecx
    xor edx,edx
    mov ecx,[rsi+r14*4+FL_X]
    sub ecx,[rsi+r13*4+FL_X]
    div ecx
    test r15d,r15d
    jns vb_fd_prediction_positive
    neg eax
vb_fd_prediction_positive:
    add eax,[rdi+r13*4]
    mov r15d,eax             ; prediction / lowroom
    mov ecx,[rsp+32]
    sub ecx,eax             ; highroom
    mov edx,ecx
    cmp edx,eax
    cmova edx,eax
    shl edx,1               ; room
    mov eax,[rdi+rbx*4]
    test eax,eax
    jz vb_fd_predicted_only
    mov dword ptr [r12+r13*4],1
    mov dword ptr [r12+r14*4],1
    mov dword ptr [r12+rbx*4],1
    cmp eax,edx
    jae vb_fd_outside_room
    test eax,1
    jz vb_fd_even
    inc eax
    shr eax,1
    neg eax
    jmp vb_fd_add_prediction
vb_fd_even:
    shr eax,1
    jmp vb_fd_add_prediction
vb_fd_outside_room:
    cmp ecx,r15d
    jbe vb_fd_room_low
    sub eax,r15d
    jmp vb_fd_add_prediction
vb_fd_room_low:
    neg eax
    add eax,ecx
    dec eax
vb_fd_add_prediction:
    add eax,r15d
    cmp eax,[rsp+32]
    jae vb_fd_bad
    mov [rdi+rbx*4],eax
    jmp vb_fd_predict_next
vb_fd_predicted_only:
    mov dword ptr [r12+rbx*4],0
    mov [rdi+rbx*4],r15d
vb_fd_predict_next:
    inc ebx
    jmp vb_fd_post_predict
vb_fd_bad:
    mov dword ptr [vb_bad],1
vb_fd_absent:
    xor eax,eax
    jmp vb_fd_done
vb_fd_present:
    mov eax,1
vb_fd_done:
    add rsp,104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_floor_decode ENDP

; Multiply spectrum by the specified integer Bresenham floor segment.
; RCX=spectrum, EDX=x0, R8D=y0, R9D=x1, [rsp+40]=y1.
vb_line PROC
    push rbp
    push rbx
    push rsi
    push rdi
    mov rsi,rcx
    mov edi,edx
    mov ebx,r8d
    mov ebp,r9d
    mov ecx,r9d
    sub ecx,edx             ; dx
    mov eax,[rsp+72]
    sub eax,ebx             ; dy
    cdq
    idiv ecx
    mov r8d,eax             ; signed base
    mov r9d,eax
    mov r10d,edx
    test r10d,r10d
    jns vb_line_rise
    neg r10d
    dec r9d
    jmp vb_line_bound
vb_line_rise:
    inc r9d
vb_line_bound:
    mov eax,[vb_n]
    shr eax,1
    cmp ebp,eax
    cmova ebp,eax
    xor r11d,r11d
    lea rbp,[rbp]            ; keeps upper half clean
    cmp edi,ebp
    jae vb_line_done
    lea rdx,vb_inverse_db
vb_line_pixel:
    mov eax,ebx
    and eax,255
    movss xmm0,dword ptr [rdx+rax*4]
    mulss xmm0,dword ptr [rsi+rdi*4]
    movss dword ptr [rsi+rdi*4],xmm0
    add r11d,r10d
    cmp r11d,ecx
    jb vb_line_base
    sub r11d,ecx
    add ebx,r9d
    jmp vb_line_next
vb_line_base:
    add ebx,r8d
vb_line_next:
    inc edi
    cmp edi,ebp
    jb vb_line_pixel
vb_line_done:
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_line ENDP

; RCX=floor, RDX=posts, R8=active, R9=spectrum.
vb_floor_apply PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,48
    mov rsi,rcx
    mov rdi,rdx
    mov r12,r8
    mov r13,r9
    xor r14d,r14d
    mov r15d,[rdi]
    imul r15d,[rsi+FL_MULT]
    mov ebx,1
vb_fa_post:
    cmp ebx,[rsi+FL_COUNT]
    jae vb_fa_tail
    mov eax,[rsi+rbx*4+FL_SORT]
    cmp dword ptr [r12+rax*4],0
    je vb_fa_next
    mov r9d,[rsi+rax*4+FL_X]
    mov eax,[rdi+rax*4]
    imul eax,[rsi+FL_MULT]
    mov [rsp+32],eax
    mov [rsp+40],r9d
    mov rcx,r13
    mov edx,r14d
    mov r8d,r15d
    call vb_line
    mov r14d,[rsp+40]
    mov r15d,[rsp+32]
vb_fa_next:
    inc ebx
    jmp vb_fa_post
vb_fa_tail:
    mov eax,[vb_n]
    shr eax,1
    lea rdx,vb_inverse_db
    movss xmm0,dword ptr [rdx+r15*4]
vb_fa_tail_loop:
    cmp r14d,eax
    jae vb_fa_done
    movss xmm1,dword ptr [r13+r14*4]
    mulss xmm1,xmm0
    movss dword ptr [r13+r14*4],xmm1
    inc r14d
    jmp vb_fa_tail_loop
vb_fa_done:
    add rsp,48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
vb_floor_apply ENDP

; RCX=book index, EDX=partition offset, R8D=partition length,
; R9D=group channel. Adds vectors to one or both spectrum buffers.
vb_residue_vector PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,56
    mov [rsp+32],ecx
    mov r12d,edx
    mov r13d,r8d
    mov r14d,r9d
    mov eax,ecx
    shl eax,6
    lea rsi,vb_books
    add rsi,rax
    mov r15d,[rsi+CB_DIM]
    mov ebp,1
    cmp dword ptr [vb_rs_type],0
    jne vb_rv_sequential
    mov eax,r13d
    xor edx,edx
    div r15d
    mov ebp,eax
    xor ebx,ebx
vb_rv_type0:
    cmp ebx,ebp
    jae vb_rv_done
    mov ecx,[rsp+32]
    call vb_symbol
    imul eax,r15d
    mov rdi,[rsi+CB_VECTOR]
    lea rdi,[rdi+rax*4]
    xor r8d,r8d
vb_rv_type0_component:
    mov eax,r8d
    imul eax,ebp
    add eax,ebx
    add eax,r12d
    lea rdx,vb_rs_channel
    mov edx,[rdx+r14*4]
    shl edx,12
    add eax,edx
    lea rdx,vb_spectrum
    movss xmm0,dword ptr [rdi+r8*4]
    addss xmm0,dword ptr [rdx+rax*4]
    movss dword ptr [rdx+rax*4],xmm0
    inc r8d
    cmp r8d,r15d
    jb vb_rv_type0_component
    inc ebx
    jmp vb_rv_type0
vb_rv_sequential:
    xor ebx,ebx
vb_rv_sequential_word:
    cmp ebx,r13d
    jae vb_rv_done
    mov ecx,[rsp+32]
    call vb_symbol
    imul eax,r15d
    mov rdi,[rsi+CB_VECTOR]
    lea rdi,[rdi+rax*4]
    xor r8d,r8d
vb_rv_component:
    cmp ebx,r13d
    jae vb_rv_done
    lea eax,[r12+rbx]
    mov ecx,r14d
    cmp dword ptr [vb_rs_type],2
    jne vb_rv_channel
    xor edx,edx
    div dword ptr [vb_rs_channels]
    mov ecx,edx
vb_rv_channel:
    lea rdx,vb_rs_channel
    mov edx,[rdx+rcx*4]
    shl edx,12
    add eax,edx
    lea rdx,vb_spectrum
    movss xmm0,dword ptr [rdi+r8*4]
    addss xmm0,dword ptr [rdx+rax*4]
    movss dword ptr [rdx+rax*4],xmm0
    inc ebx
    inc r8d
    cmp r8d,r15d
    jb vb_rv_component
    jmp vb_rv_sequential_word
vb_rv_done:
    add rsp,56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_residue_vector ENDP

; RCX=residue, RDX=mapping, R8D=submap. All types, mono/stereo.
vb_residue PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,56
    mov rsi,rcx
    mov [vb_rs_ptr],rcx
    xor ebx,ebx
    xor edi,edi
vb_rs_find_channel:
    cmp ebx,[source_channels]
    jae vb_rs_channels_done
    cmp [rdx+rbx*4+MP_MUX],r8d
    jne vb_rs_find_next
    lea rax,vb_rs_channel
    mov [rax+rdi*4],ebx
    lea rax,vb_zero
    mov eax,[rax+rbx*4]
    xor eax,1
    lea rcx,vb_rs_active
    mov [rcx+rdi*4],eax
    inc edi
vb_rs_find_next:
    inc ebx
    jmp vb_rs_find_channel
vb_rs_channels_done:
    test edi,edi
    jz vb_rs_done
    mov [vb_rs_channels],edi
    mov [vb_rs_groups],edi
    mov eax,[rsi+RS_TYPE]
    mov [vb_rs_type],eax
    cmp eax,2
    jne vb_rs_size
    mov dword ptr [vb_rs_groups],1
    mov eax,[vb_rs_active]
    cmp edi,2
    jne vb_rs_type2_active
    or eax,[vb_rs_active+4]
vb_rs_type2_active:
    mov [vb_rs_active],eax
vb_rs_size:
    mov eax,[vb_n]
    shr eax,1
    cmp dword ptr [vb_rs_type],2
    jne vb_rs_limit
    imul eax,edi
vb_rs_limit:
    mov edx,[rsi+RS_BEGIN]
    cmp edx,eax
    cmova edx,eax
    mov [vb_rs_begin],edx
    mov ecx,[rsi+RS_END]
    cmp ecx,eax
    cmova ecx,eax
    sub ecx,edx
    mov eax,ecx
    xor edx,edx
    div dword ptr [rsi+RS_PART]
    mov [vb_rs_parts],eax
    test eax,eax
    jz vb_rs_done
    mov eax,[rsi+RS_BOOK]
    shl eax,6
    lea rdx,vb_books
    mov eax,[rdx+rax+CB_DIM]
    mov [vb_rs_words],eax
    xor r12d,r12d           ; pass
vb_rs_pass:
    xor r13d,r13d           ; partition base for classword
vb_rs_group:
    cmp r13d,[vb_rs_parts]
    jae vb_rs_pass_next
    test r12d,r12d
    jnz vb_rs_partition_start
    xor r15d,r15d
vb_rs_class_channel:
    lea rax,vb_rs_active
    cmp dword ptr [rax+r15*4],0
    je vb_rs_class_next
    mov ecx,[rsi+RS_BOOK]
    call vb_symbol
    mov ebx,[vb_rs_words]
    dec ebx
vb_rs_class_digit:
    xor edx,edx
    div dword ptr [rsi+RS_CLASSES]
    mov ecx,r15d
    shl ecx,14
    add ecx,r13d
    add ecx,ebx
    lea rdi,vb_classdata
    mov [rdi+rcx*4],edx
    dec ebx
    jns vb_rs_class_digit
vb_rs_class_next:
    inc r15d
    cmp r15d,[vb_rs_groups]
    jb vb_rs_class_channel
vb_rs_partition_start:
    xor r14d,r14d
vb_rs_partition:
    lea eax,[r13+r14]
    cmp eax,[vb_rs_parts]
    jae vb_rs_group_next
    xor r15d,r15d
vb_rs_partition_channel:
    lea rax,vb_rs_active
    cmp dword ptr [rax+r15*4],0
    je vb_rs_partition_next_channel
    mov eax,r15d
    shl eax,14
    add eax,r13d
    add eax,r14d
    lea rdi,vb_classdata
    mov eax,[rdi+rax*4]
    shl eax,5
    lea eax,[rax+r12*4]
    mov ecx,[rsi+rax+RS_BOOKS]
    test ecx,ecx
    js vb_rs_partition_next_channel
    lea edx,[r13+r14]
    imul edx,[rsi+RS_PART]
    add edx,[vb_rs_begin]
    mov r8d,[rsi+RS_PART]
    mov r9d,r15d
    call vb_residue_vector
vb_rs_partition_next_channel:
    inc r15d
    cmp r15d,[vb_rs_groups]
    jb vb_rs_partition_channel
    inc r14d
    cmp r14d,[vb_rs_words]
    jb vb_rs_partition
vb_rs_group_next:
    add r13d,[vb_rs_words]
    cmp dword ptr [vb_bad],0
    jne vb_rs_done
    jmp vb_rs_group
vb_rs_pass_next:
    inc r12d
    cmp r12d,8
    jb vb_rs_pass
vb_rs_done:
    add rsp,56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_residue ENDP

; Decode one complete packet into a fixed interleaved stereo PCM buffer.
vb_frame PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,56
    call ogg_next
    test rax,rax
    jz vb_frame_eof
    lea rcx,[rax+rdx]
    mov [vb_end],rcx
    mov [vb_ptr],rax
    mov qword ptr [vb_acc],0
    mov dword ptr [vb_count],0
    mov dword ptr [vb_bad],0
    VB_GET 1
    test eax,eax
    jnz vb_frame_bad
    mov ecx,[vb_mode_bits]
    call vb_bits
    cmp eax,[vb_modes_count]
    jae vb_frame_bad
    lea rdx,vb_modes
    mov ecx,[rdx+rax*8+4]
    mov eax,[rdx+rax*8]
    mov [vb_block],eax
    imul ecx,MP_SIZE
    lea rsi,vb_maps
    add rsi,rcx
    mov [vb_current_map],rsi
    mov ebx,[vb_short]
    xor r13d,r13d
    xor r14d,r14d
    test eax,eax
    jz vb_frame_window
    mov ebx,[vb_long]
    VB_GET 1
    mov r13d,eax
    VB_GET 1
    mov r14d,eax
vb_frame_window:
    mov [vb_n],ebx
    mov eax,ebx
    shr eax,1
    mov dword ptr [vb_left],0
    mov [vb_left_end],eax
    mov [vb_right],eax
    mov [vb_right_end],ebx
    cmp dword ptr [vb_block],0
    je vb_frame_clear
    test r13d,r13d
    jnz vb_frame_right_window
    mov eax,ebx
    sub eax,[vb_short]
    shr eax,2
    mov [vb_left],eax
    mov eax,ebx
    add eax,[vb_short]
    shr eax,2
    mov [vb_left_end],eax
vb_frame_right_window:
    test r14d,r14d
    jnz vb_frame_clear
    lea eax,[rbx+rbx*2]
    sub eax,[vb_short]
    shr eax,2
    mov [vb_right],eax
    lea eax,[rbx+rbx*2]
    add eax,[vb_short]
    shr eax,2
    mov [vb_right_end],eax
vb_frame_clear:
    lea rdi,vb_spectrum
    xor eax,eax
    mov ecx,4096
    rep stosq
    xor r12d,r12d
vb_frame_floor:
    mov eax,[rsi+r12*4+MP_MUX]
    mov eax,[rsi+rax*4+MP_FLOOR]
    imul eax,FL_SIZE
    lea rcx,vb_floors
    add rcx,rax
    lea rdx,vb_floor_channel
    mov [rdx+r12*8],rcx
    mov eax,r12d
    shl eax,10
    lea rdx,vb_y
    add rdx,rax
    lea r8,vb_active
    add r8,rax
    call vb_floor_decode
    xor eax,1
    lea rdx,vb_zero
    mov [rdx+r12*4],eax
    lea rdx,vb_really_zero
    mov [rdx+r12*4],eax
    inc r12d
    cmp r12d,[source_channels]
    jb vb_frame_floor
    xor ebx,ebx
vb_frame_activate:
    cmp ebx,[rsi+MP_COUPLE]
    jae vb_frame_residue_start
    mov eax,[rsi+rbx*4+MP_MAG]
    mov edx,[rsi+rbx*4+MP_ANGLE]
    lea rcx,vb_zero
    cmp dword ptr [rcx+rax*4],0
    je vb_frame_pair_active
    cmp dword ptr [rcx+rdx*4],0
    jne vb_frame_activate_next
vb_frame_pair_active:
    mov dword ptr [rcx+rax*4],0
    mov dword ptr [rcx+rdx*4],0
vb_frame_activate_next:
    inc ebx
    jmp vb_frame_activate
vb_frame_residue_start:
    xor ebx,ebx
vb_frame_residue:
    mov eax,[rsi+rbx*4+MP_RESIDUE]
    imul eax,RS_SIZE
    lea rcx,vb_residues
    add rcx,rax
    mov rdx,rsi
    mov r8d,ebx
    call vb_residue
    cmp dword ptr [vb_bad],0
    jne vb_frame_bad
    inc ebx
    cmp ebx,[rsi+MP_SUBMAPS]
    jb vb_frame_residue
    mov ebx,[rsi+MP_COUPLE]
    pxor xmm5,xmm5
vb_frame_couple:
    dec ebx
    js vb_frame_apply_start
    mov eax,[rsi+rbx*4+MP_MAG]
    mov edx,[rsi+rbx*4+MP_ANGLE]
    shl eax,14
    shl edx,14
    lea rdi,vb_spectrum
    lea rcx,[rdi+rax]
    add rdi,rdx
    xor r8d,r8d
    mov r9d,[vb_n]
    shr r9d,1
vb_frame_couple_bin:
    movss xmm0,dword ptr [rcx+r8*4]
    movss xmm1,dword ptr [rdi+r8*4]
    movss xmm2,xmm0
    movss xmm3,xmm0
    comiss xmm0,xmm5
    jbe vb_frame_negative_m
    comiss xmm1,xmm5
    jbe vb_frame_positive_m_negative_a
    subss xmm3,xmm1
    jmp vb_frame_pair_store
vb_frame_positive_m_negative_a:
    addss xmm2,xmm1
    jmp vb_frame_pair_store
vb_frame_negative_m:
    comiss xmm1,xmm5
    jbe vb_frame_both_negative
    addss xmm3,xmm1
    jmp vb_frame_pair_store
vb_frame_both_negative:
    subss xmm2,xmm1
vb_frame_pair_store:
    movss dword ptr [rcx+r8*4],xmm2
    movss dword ptr [rdi+r8*4],xmm3
    inc r8d
    cmp r8d,r9d
    jb vb_frame_couple_bin
    jmp vb_frame_couple
vb_frame_apply_start:
    xor r12d,r12d
vb_frame_apply:
    mov eax,r12d
    shl eax,14
    lea r13,vb_spectrum
    add r13,rax
    lea rdx,vb_really_zero
    cmp dword ptr [rdx+r12*4],0
    jne vb_frame_zero_channel
    lea rcx,vb_floor_channel
    mov rcx,[rcx+r12*8]
    mov eax,r12d
    shl eax,10
    lea rdx,vb_y
    add rdx,rax
    lea r8,vb_active
    add r8,rax
    mov r9,r13
    call vb_floor_apply
    jmp vb_frame_transform
vb_frame_zero_channel:
    mov rdi,r13
    xor eax,eax
    mov ecx,[vb_n]
    shr ecx,2
    rep stosq
vb_frame_transform:
    mov eax,r12d
    shl eax,15
    lea rdx,vb_time
    add rdx,rax
    mov rcx,r13
    mov r8d,[vb_n]
    mov r9d,[vb_block]
    call vb_imdct
    inc r12d
    cmp r12d,[source_channels]
    jb vb_frame_apply
    cmp dword ptr [vb_bad],0
    jne vb_frame_bad
    mov r13d,[vb_previous]
    mov r14d,[vb_right]
    sub r14d,[vb_left]
    mov dword ptr [vb_available],0
    mov dword ptr [vb_used],0
    test r13d,r13d
    jz vb_frame_save_tail
    mov eax,[vb_left_end]
    sub eax,[vb_left]
    cmp eax,r13d
    jne vb_frame_bad
    ; Select the half-window matching the overlap width.
    lea r15,vb_windows
    mov eax,r13d
    shl eax,1
    cmp eax,[vb_short]
    je vb_frame_window_ready
    cmp eax,[vb_long]
    jne vb_frame_bad
    add r15,65536
vb_frame_window_ready:
    xor r12d,r12d
vb_frame_overlap_channel:
    mov eax,r12d
    shl eax,15
    lea rsi,vb_time
    add rsi,rax
    mov eax,r12d
    shl eax,14
    lea rdi,vb_tail
    add rdi,rax
    xor ebx,ebx
vb_frame_overlap_sample:
    mov eax,[vb_left]
    add eax,ebx
    cvtss2sd xmm0,dword ptr [rsi+rax*4]
    mulsd xmm0,qword ptr [r15+rbx*8]
    mov edx,r13d
    sub edx,ebx
    dec edx
    cvtss2sd xmm1,dword ptr [rdi+rbx*4]
    mulsd xmm1,qword ptr [r15+rdx*8]
    addsd xmm0,xmm1
    cvtsd2ss xmm0,xmm0
    movss dword ptr [rsi+rax*4],xmm0
    inc ebx
    cmp ebx,r13d
    jb vb_frame_overlap_sample
    inc r12d
    cmp r12d,[source_channels]
    jb vb_frame_overlap_channel
    ; End granule trims encoder padding. No unsigned wrap on malformed totals.
    mov rax,[total_frames]
    sub rax,[vb_emitted]
    jc vb_frame_bad
    cmp rax,r14
    jae vb_frame_output_count
    mov r14d,eax
vb_frame_output_count:
    mov [vb_available],r14d
    add [vb_emitted],r14
    lea rsi,vb_time
    mov eax,[vb_left]
    lea rsi,[rsi+rax*4]
    lea rdi,vb_pcm
    xor ebx,ebx
vb_frame_interleave:
    cmp ebx,r14d
    jae vb_frame_save_tail
    mov eax,[rsi+rbx*4]
    mov edx,eax
    and edx,7fffffffh
    cmp edx,7f800000h
    jae vb_frame_bad
    mov [rdi+rbx*8],eax
    cmp dword ptr [source_channels],1
    je vb_frame_mono
    mov eax,[rsi+rbx*4+32768]
vb_frame_mono:
    mov edx,eax
    and edx,7fffffffh
    cmp edx,7f800000h
    jae vb_frame_bad
    mov [rdi+rbx*8+4],eax
    inc ebx
    jmp vb_frame_interleave
vb_frame_save_tail:
    mov eax,[vb_right_end]
    sub eax,[vb_right]
    mov [vb_previous],eax
    mov r14d,eax
    xor r12d,r12d
vb_frame_tail_channel:
    mov eax,r12d
    shl eax,15
    lea rsi,vb_time
    add rsi,rax
    mov eax,[vb_right]
    lea rsi,[rsi+rax*4]
    mov eax,r12d
    shl eax,14
    lea rdi,vb_tail
    add rdi,rax
    mov ecx,r14d
    rep movsd
    inc r12d
    cmp r12d,[source_channels]
    jb vb_frame_tail_channel
    mov eax,1
    jmp vb_frame_done
vb_frame_bad:
    mov dword ptr [decode_error],24
vb_frame_eof:
    xor eax,eax
vb_frame_done:
    add rsp,56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_frame ENDP

vorbis_read PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,32
    mov rdi,rcx
    mov r12d,edx
    xor ebx,ebx
vb_read_more:
    cmp ebx,r12d
    jae vb_read_done
    mov eax,[vb_used]
    cmp eax,[vb_available]
    jb vb_read_copy
    call vb_frame
    test eax,eax
    jz vb_read_done
    jmp vb_read_more
vb_read_copy:
    mov r13d,[vb_available]
    sub r13d,eax
    mov edx,r12d
    sub edx,ebx
    cmp r13d,edx
    cmova r13d,edx
    lea rsi,vb_pcm
    lea rsi,[rsi+rax*8]
    mov ecx,r13d
    rep movsq
    add [vb_used],r13d
    add ebx,r13d
    jmp vb_read_more
vb_read_done:
    mov eax,ebx
    add rsp,32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
vorbis_read ENDP
