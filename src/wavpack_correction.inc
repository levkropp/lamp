# WavPack hybrid correction reconstruction. See THIRD_PARTY_NOTICES for
# David Bryant's BSD reference (WavPack 5.9.0, read_words/unpack/decorr_utils).
# Main adaptive histories always follow lossy samples. Corrected samples
# are a separate prediction path and are never fed back into those histories.
.text
# Paired block metadata; wv_block_header is the main block just parsed.
LOCALFN wv_correction_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, [rip+wv_pair_cursor]
    mov rdi, [rip+wv_pair_end]
    mov rax, rdi
    sub rax, rsi
    cmp rax, 32
    jb .Lwvc_block_bad
    cmp dword ptr [rsi], 0x6b707677
    jne .Lwvc_block_bad
    mov edx, [rsi+4]
    cmp edx, 24
    jb .Lwvc_block_bad
    cmp edx, 1048576
    ja .Lwvc_block_bad
    add rdx, 8
    cmp rdx, rax
    ja .Lwvc_block_bad
    mov rbx, [rip+wv_block_header]
    movzx eax, word ptr [rsi+8]
    cmp ax, [rbx+8]
    jne .Lwvc_block_bad
    mov al, [rsi+10]
    cmp al, [rbx+10]
    jne .Lwvc_block_bad
    mov eax, [rsi+16]
    cmp eax, [rbx+16]
    jne .Lwvc_block_bad
    mov eax, [rsi+20]
    cmp eax, [rbx+20]
    jne .Lwvc_block_bad
    mov eax, [rsi+24]
    cmp eax, [rbx+24]
    jne .Lwvc_block_bad
    mov eax, [rsi+28]
    mov [rip+wv_crc], eax
    lea rdi, [rsi+rdx]
    mov [rip+wv_pair_cursor], rdi
    add rsi, 32
    pxor xmm0, xmm0
    movdqu [rip+wv_corr_bits], xmm0
    movq [rip+wv_shape_error], xmm0
    movq [rip+wv_shape_acc], xmm0
    movq [rip+wv_shape_delta], xmm0
.Lwvc_metadata:
    cmp rsi, rdi
    je .Lwvc_metadata_end
    mov rax, rdi
    sub rax, rsi
    cmp rax, 2
    jb .Lwvc_block_bad
    movzx r14d, byte ptr [rsi]
    movzx r12d, byte ptr [rsi+1]
    add rsi, 2
    test r14d, 0x80
    jz .Lwvc_metadata_size
    cmp rax, 4
    jb .Lwvc_block_bad
    movzx eax, word ptr [rsi]
    shl eax, 8
    or r12d, eax
    add rsi, 2
.Lwvc_metadata_size:
    shl r12d, 1
    mov r13d, r12d
    test r14d, 0x40
    jz .Lwvc_metadata_fits
    test r12d, r12d
    jz .Lwvc_block_bad
    dec r13d
.Lwvc_metadata_fits:
    mov rax, rdi
    sub rax, rsi
    cmp r12, rax
    ja .Lwvc_block_bad
    mov eax, r14d
    and eax, 0x3f
    cmp eax, 7
    je .Lwvc_metadata_shape
    cmp eax, 0xb
    je .Lwvc_metadata_residual
    cmp eax, 0xc
    je .Lwvc_metadata_extra
    test eax, eax                         # DUMMY
    jz .Lwvc_metadata_next
    test eax, 0x20                        # optional metadata
    jnz .Lwvc_metadata_next
    jmp .Lwvc_block_bad
.Lwvc_metadata_residual:
    test r13d, r13d
    jz .Lwvc_block_bad
    test r13d, 1
    jnz .Lwvc_block_bad
    mov [rip+wv_corr_bits+BR_DATA], rsi
    lea eax, [r13*8]
    mov [rip+wv_corr_bits+BR_BITS], eax
    mov dword ptr [rip+wv_corr_bits+BR_POS], 0
    jmp .Lwvc_metadata_next
.Lwvc_metadata_extra:
    cmp r13d, 4
    jb .Lwvc_block_bad
    mov [rip+wv_extra+BR_DATA], rsi
    lea eax, [r13*8]
    mov [rip+wv_extra+BR_BITS], eax
    mov dword ptr [rip+wv_extra+BR_POS], 32
    mov eax, [rsi]
    mov [rip+wv_crc_extra_want], eax
    mov dword ptr [rip+wv_got_extra], 1
    jmp .Lwvc_metadata_next
.Lwvc_metadata_shape:
    mov rcx, rsi
    mov edx, r13d
    call wv_correction_shaping_info
    test eax, eax
    jz .Lwvc_block_bad
.Lwvc_metadata_next:
    add rsi, r12
    jmp .Lwvc_metadata
.Lwvc_metadata_end:
    cmp dword ptr [rip+wv_format], 2
    je .Lwvc_block_ok
    mov eax, [rip+wv_extra_bits]
    test eax, eax
    jz .Lwvc_block_ok
    cmp dword ptr [rip+wv_got_extra], 0
    je .Lwvc_block_bad
    mov ecx, [rip+wv_samples]
    imul rax, rcx
    mov ecx, [rip+wv_stereo_in]
    shl rax, cl
    mov ecx, [rip+wv_extra+BR_BITS]
    sub ecx, [rip+wv_extra+BR_POS]
    cmp rcx, rax
    jb .Lwvc_block_bad
.Lwvc_block_ok:
    mov dword ptr [rip+wv_corr_active], 1
    mov eax, 1
    jmp .Lwvc_block_return
.Lwvc_block_bad:
    xor eax, eax
.Lwvc_block_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_correction_block

# RCX=SHAPING_WEIGHTS payload, EDX=bytes. Legacy byte weights or signed
# logarithmic error/accumulator words, with optional per-sample deltas.
LOCALFN wv_correction_shaping_info
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov edi, edx
    cmp edx, 2
    jne .Lwvc_shape_words
    movsx eax, byte ptr [rsi]
    WV_WEIGHT
    shl eax, 16
    mov [rip+wv_shape_acc], eax
    movsx eax, byte ptr [rsi+1]
    WV_WEIGHT
    shl eax, 16
    mov [rip+wv_shape_acc+4], eax
    jmp .Lwvc_shape_info_ok
.Lwvc_shape_words:
    mov ebx, [rip+wv_stereo_in]
    inc ebx
    lea eax, [rbx*4]
    cmp edi, eax
    jb .Lwvc_shape_info_bad
    xor r12d, r12d
.Lwvc_shape_channel:
    movsx ecx, word ptr [rsi+r12*4]
    call wv_exp2
    lea rdx, [rip+wv_shape_error]
    mov [rdx+r12*4], eax
    movsx ecx, word ptr [rsi+r12*4+2]
    call wv_exp2
    lea rdx, [rip+wv_shape_acc]
    mov [rdx+r12*4], eax
    inc r12d
    cmp r12d, ebx
    jb .Lwvc_shape_channel
    lea eax, [rbx+rbx*2]
    shl eax, 1
    cmp edi, eax
    jne .Lwvc_shape_info_ok
    lea rsi, [rsi+rbx*4]
    xor r12d, r12d
.Lwvc_shape_deltas:
    movsx ecx, word ptr [rsi+r12*2]
    call wv_exp2
    lea rdx, [rip+wv_shape_delta]
    mov [rdx+r12*4], eax
    inc r12d
    cmp r12d, ebx
    jb .Lwvc_shape_deltas
.Lwvc_shape_info_ok:
    mov eax, 1
    jmp .Lwvc_shape_info_return
.Lwvc_shape_info_bad:
    xor eax, eax
.Lwvc_shape_info_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_correction_shaping_info

# ECX=channel 0/1, EDX=lossy reconstructed sample, R8D=corrected sample.
# Return final shaped sample, updating only the correction noise history.
LOCALFN wv_correction_shape
    mov eax, r8d
    test dword ptr [rip+wv_flags], F_SHAPE
    jz .Lwvc_shape_return
    mov r10d, r8d
    sub r10d, edx
    lea rax, [rip+wv_shape_acc]
    lea rdx, [rip+wv_shape_delta]
    mov r9d, [rax+rcx*4]
    add r9d, [rdx+rcx*4]
    mov [rax+rcx*4], r9d
    sar r9d, 16
    mov r11d, r9d
    movsxd rax, r9d
    lea rdx, [rip+wv_shape_error]
    movsxd rdx, dword ptr [rdx+rcx*4]
    imul rax, rdx
    add rax, 512
    sar rax, 10
    neg eax
    test dword ptr [rip+wv_flags], F_NEW_SHAPE
    jz .Lwvc_shape_old
    test r11d, r11d
    jns .Lwvc_shape_old
    test eax, eax
    jz .Lwvc_shape_old
    cmp eax, edx
    jne .Lwvc_shape_adjusted
    test eax, eax
    js .Lwvc_shape_negative
    dec eax
    jmp .Lwvc_shape_adjusted
.Lwvc_shape_negative:
    inc eax
.Lwvc_shape_adjusted:
    mov r9d, eax
    sub r9d, r10d
    jmp .Lwvc_shape_store
.Lwvc_shape_old:
    mov r9d, r10d
    neg r9d
.Lwvc_shape_store:
    lea r11, [rip+wv_shape_error]
    mov [r11+rcx*4], r9d
    sub r8d, eax
    mov eax, r8d
.Lwvc_shape_return:
    ret
ENDFN wv_correction_shape

# Corrected prediction with CROSS_DECORR must run BEFORE the lossy adaptive
# pass mutates weights/history. ECX=L, EDX=R, R8D=ring position; EAX=L, EDX=R.
LOCALFN wv_correction_preview
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12d, ecx
    add r12d, [rip+wv_corr_values]
    mov r13d, edx
    add r13d, [rip+wv_corr_values+4]
    mov r14d, r8d
    lea rsi, [rip+wv_decorr]
    xor r15d, r15d
.Lwvc_preview_term:
    cmp r15d, [rip+wv_terms]
    jae .Lwvc_preview_joint
    mov eax, [rsi+DC_VALUE]
    test eax, eax
    jle .Lwvc_preview_cross
    cmp eax, 8
    jle .Lwvc_preview_history
    mov r9d, [rsi+DC_SA]
    mov r11d, [rsi+DC_SB]
    test eax, 1
    jz .Lwvc_preview_even
    shl r9d, 1
    sub r9d, [rsi+DC_SA+4]
    shl r11d, 1
    sub r11d, [rsi+DC_SB+4]
    jmp .Lwvc_preview_positive
.Lwvc_preview_even:
    lea r9d, [r9+r9*2]
    sub r9d, [rsi+DC_SA+4]
    sar r9d, 1
    lea r11d, [r11+r11*2]
    sub r11d, [rsi+DC_SB+4]
    sar r11d, 1
    jmp .Lwvc_preview_positive
.Lwvc_preview_history:
    mov r9d, [rsi+DC_SA+r14*4]
    mov r11d, [rsi+DC_SB+r14*4]
.Lwvc_preview_positive:
    mov [rsp+32], r11d
    mov r8d, [rsi+DC_WA]
    mov r10d, r12d
    WV_APPLY
    mov r12d, eax
    mov r9d, [rsp+32]
    mov r8d, [rsi+DC_WB]
    mov r10d, r13d
    WV_APPLY
    mov r13d, eax
    jmp .Lwvc_preview_next
.Lwvc_preview_cross:
    cmp eax, -1
    jne .Lwvc_preview_cross_right
    mov r9d, [rsi+DC_SA]
    mov r8d, [rsi+DC_WA]
    mov r10d, r12d
    WV_APPLY
    mov r12d, eax
    mov r9d, eax
    mov r8d, [rsi+DC_WB]
    mov r10d, r13d
    WV_APPLY
    mov r13d, eax
    jmp .Lwvc_preview_next
.Lwvc_preview_cross_right:
    mov edi, eax
    mov r9d, [rsi+DC_SB]
    mov r8d, [rsi+DC_WB]
    mov r10d, r13d
    WV_APPLY
    mov r13d, eax
    mov r9d, eax
    cmp edi, -3
    jne .Lwvc_preview_cross_left
    mov r9d, [rsi+DC_SA]
.Lwvc_preview_cross_left:
    mov r8d, [rsi+DC_WA]
    mov r10d, r12d
    WV_APPLY
    mov r12d, eax
.Lwvc_preview_next:
    add rsi, DC_SIZE
    inc r15d
    jmp .Lwvc_preview_term
.Lwvc_preview_joint:
    test dword ptr [rip+wv_flags], F_JOINT
    jz .Lwvc_preview_done
    mov eax, r12d
    sar eax, 1
    sub r13d, eax
    add r12d, r13d
.Lwvc_preview_done:
    mov eax, r12d
    mov edx, r13d
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_correction_preview
