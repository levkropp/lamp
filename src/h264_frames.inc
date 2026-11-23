# Original Annex B frame assembly and DXVA metadata. Included by h264.s.

# RCX=context ->1 frame (HP_DESC),0 EOF,-1 sticky error.
FN h264_next
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 40
    mov rbx, rcx
    cmp qword ptr [rbx+HP_DATA], 0
    je .Lhp_next_bad
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_next_error
    mov rax, [rbx+HP_CANCEL]
    test rax, rax
    jz .Lhp_next_begin
    cmp dword ptr [rax], 0
    jne .Lhp_next_cancel
.Lhp_next_begin:
    mov dword ptr [rbx+HP_FRAME_BYTES], 0
    mov dword ptr [rbx+HP_SLICES], 0
.Lhp_next_nal:
    mov rcx, rbx
    call hp_nal
    test eax, eax
    js .Lhp_next_error
    jz .Lhp_next_end
    mov rsi, [rbx+HP_NAL_PTR]
    movzx ebp, byte ptr [rsi]
    and ebp, 31
    cmp ebp, 5
    je .Lhp_next_slice
    cmp ebp, 1
    je .Lhp_next_slice
    cmp dword ptr [rbx+HP_SLICES], 0
    jne .Lhp_next_rewind
    cmp ebp, 7
    je .Lhp_next_parameter
    cmp ebp, 8
    je .Lhp_next_parameter
    cmp ebp, 10
    je .Lhp_next_nal
    cmp ebp, 11
    je .Lhp_next_nal
    cmp ebp, 6
    je .Lhp_next_opaque
    cmp ebp, 9
    je .Lhp_next_opaque
    cmp ebp, 12
    jne .Lhp_next_unsupported
.Lhp_next_opaque:
    test byte ptr [rsi], 0x60
    jnz .Lhp_next_bad
    cmp qword ptr [rbx+HP_NAL_BYTES], 2
    jb .Lhp_next_bad
    jmp .Lhp_next_nal
.Lhp_next_parameter:
    test byte ptr [rsi], 0x60
    jz .Lhp_next_bad
    cmp qword ptr [rbx+HP_NAL_BYTES], 4096
    ja .Lhp_next_limit
    cmp ebp, 7
    jne .Lhp_next_pps
    test dword ptr [rbx+HP_STATE], 1
    jz .Lhp_next_sps_new
    mov eax, [rbx+HP_SPS_BYTES]
    cmp rax, [rbx+HP_NAL_BYTES]
    jne .Lhp_next_unsupported
    mov ecx, eax
    lea rdi, [rbx+HP_SPS_RAW]
    repe cmpsb
    jne .Lhp_next_unsupported
    jmp .Lhp_next_nal
.Lhp_next_sps_new:
    mov rcx, rbx
    call hp_sps
    test eax, eax
    jz .Lhp_next_error
    lea rdi, [rbx+HP_SPS_RAW]
    mov eax, [rbx+HP_NAL_BYTES]
    mov [rbx+HP_SPS_BYTES], eax
    or dword ptr [rbx+HP_STATE], 1
    jmp .Lhp_next_parameter_copy
.Lhp_next_pps:
    test dword ptr [rbx+HP_STATE], 1
    jz .Lhp_next_unsupported
    test dword ptr [rbx+HP_STATE], 2
    jz .Lhp_next_pps_new
    mov eax, [rbx+HP_PPS_BYTES]
    cmp rax, [rbx+HP_NAL_BYTES]
    jne .Lhp_next_unsupported
    mov ecx, eax
    lea rdi, [rbx+HP_PPS_RAW]
    repe cmpsb
    jne .Lhp_next_unsupported
    jmp .Lhp_next_nal
.Lhp_next_pps_new:
    mov rcx, rbx
    call hp_pps
    test eax, eax
    jz .Lhp_next_error
    lea rdi, [rbx+HP_PPS_RAW]
    mov eax, [rbx+HP_NAL_BYTES]
    mov [rbx+HP_PPS_BYTES], eax
    or dword ptr [rbx+HP_STATE], 2
.Lhp_next_parameter_copy:
    mov rsi, [rbx+HP_NAL_PTR]
    mov ecx, eax
    rep movsb
    jmp .Lhp_next_nal
.Lhp_next_slice:
    cmp dword ptr [rbx+HP_STATE], 3
    jne .Lhp_next_unsupported
    movzx eax, byte ptr [rsi]
    shr eax, 5
    and eax, 3
    test eax, eax
    setnz al
    movzx eax, al
    mov [rbx+HP_TEMP_REF], eax
    mov [rbx+HP_TEMP_NAL], ebp
    mov rcx, rbx
    call hp_slice
    test eax, eax
    jz .Lhp_next_error
    cmp dword ptr [rbx+HP_SLICES], 0
    je .Lhp_next_first
    mov eax, [rbx+HP_TEMP_MB]
    test eax, eax
    jz .Lhp_next_rewind
    cmp eax, [rbx+HP_LAST_MB]
    jbe .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_IDR]
    cmp eax, [rbx+HP_FRAME_IDR]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_PPS]
    cmp eax, [rbx+HP_FRAME_PPS]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_POC]
    cmp eax, [rbx+HP_FRAME_POC]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_REF]
    cmp eax, [rbx+HP_FRAME_REF]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_NUM]
    cmp eax, [rbx+HP_FRAME_NUM]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_NAL]
    cmp eax, [rbx+HP_FRAME_NAL]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_ADAPT]
    cmp eax, [rbx+HP_FRAME_ADAPT]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_LONG]
    cmp eax, [rbx+HP_FRAME_LONG]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_NOOUTPUT]
    cmp eax, [rbx+HP_FRAME_NOOUTPUT]
    jne .Lhp_next_bad
    mov eax, [rbx+HP_TEMP_MMCO_COUNT]
    cmp eax, [rbx+HP_FRAME_MMCO_COUNT]
    jne .Lhp_next_bad
    lea ecx, [rax+rax*2]
    shl ecx, 2
    lea rsi, [rbx+HP_TEMP_MMCO]
    lea rdi, [rbx+HP_FRAME_MMCO]
    repe cmpsb
    jne .Lhp_next_bad
    cmp dword ptr [rbx+HP_TEMP_TYPE], 2
    je .Lhp_next_append
    mov eax, [rbx+HP_TEMP_TYPE]
    mov [rbx+HP_FRAME_TYPE], eax
    jmp .Lhp_next_append
.Lhp_next_first:
    cmp dword ptr [rbx+HP_TEMP_MB], 0
    jne .Lhp_next_unsupported
    mov eax, [rbx+HP_TEMP_IDR]
    mov [rbx+HP_FRAME_IDR], eax
    mov eax, [rbx+HP_TEMP_PPS]
    mov [rbx+HP_FRAME_PPS], eax
    mov eax, [rbx+HP_TEMP_POC]
    mov [rbx+HP_FRAME_POC], eax
    mov eax, [rbx+HP_TEMP_REF]
    mov [rbx+HP_FRAME_REF], eax
    mov eax, [rbx+HP_TEMP_NUM]
    mov [rbx+HP_FRAME_NUM], eax
    mov eax, [rbx+HP_TEMP_TYPE]
    mov [rbx+HP_FRAME_TYPE], eax
    mov eax, [rbx+HP_TEMP_NAL]
    mov [rbx+HP_FRAME_NAL], eax
    mov eax, [rbx+HP_TEMP_ADAPT]
    mov [rbx+HP_FRAME_ADAPT], eax
    mov eax, [rbx+HP_TEMP_LONG]
    mov [rbx+HP_FRAME_LONG], eax
    mov eax, [rbx+HP_TEMP_NOOUTPUT]
    mov [rbx+HP_FRAME_NOOUTPUT], eax
    mov eax, [rbx+HP_TEMP_MMCO_COUNT]
    mov [rbx+HP_FRAME_MMCO_COUNT], eax
    lea ecx, [rax+rax*2]
    shl ecx, 2
    lea rsi, [rbx+HP_TEMP_MMCO]
    lea rdi, [rbx+HP_FRAME_MMCO]
    rep movsb
.Lhp_next_append:
    mov eax, [rbx+HP_TEMP_MB]
    mov [rbx+HP_LAST_MB], eax
    mov rcx, rbx
    call hp_append
    test eax, eax
    jz .Lhp_next_error
    jmp .Lhp_next_nal
.Lhp_next_rewind:
    mov rax, [rbx+HP_NAL_START]
    mov [rbx+HP_CURSOR], rax
    jmp .Lhp_next_finish
.Lhp_next_end:
    cmp dword ptr [rbx+HP_SLICES], 0
    jne .Lhp_next_finish
    cmp qword ptr [rbx+HP_FRAMES], 0
    je .Lhp_next_bad
    xor eax, eax
    jmp .Lhp_next_return
.Lhp_next_finish:
    mov rcx, rbx
    call hp_finish
    jmp .Lhp_next_return
.Lhp_next_limit:
    mov dword ptr [rbx+HP_ERROR], 3
    jmp .Lhp_next_error
.Lhp_next_unsupported:
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhp_next_error
.Lhp_next_cancel:
    mov dword ptr [rbx+HP_ERROR], 61
    jmp .Lhp_next_error
.Lhp_next_bad:
    mov dword ptr [rbx+HP_ERROR], 1
.Lhp_next_error:
    mov eax, -1
.Lhp_next_return:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN h264_next

LOCALFN hp_append
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    cmp dword ptr [rbx+HP_SLICES], 256
    jae .Lhp_append_limit
    mov r12d, [rbx+HP_FRAME_BYTES]
    add r12, [rbx+HP_NAL_BYTES]
    add r12, 3
    cmp r12, HP_MAX_FRAME
    ja .Lhp_append_limit
    add r12, 65535
    and r12, -65536          # includes all possible128-byte final padding
    cmp r12, HP_MAX_FRAME
    ja .Lhp_append_limit
    cmp qword ptr [rbx+HP_BITS_BUFFER], 0
    jne .Lhp_append_commit
    mov ecx, HP_MAX_FRAME
    call mem_reserve
    test rax, rax
    jz .Lhp_append_alloc
    mov [rbx+HP_BITS_BUFFER], rax
.Lhp_append_commit:
    cmp r12, [rbx+HP_COMMITTED]
    jbe .Lhp_append_copy
    mov rcx, [rbx+HP_BITS_BUFFER]
    add rcx, [rbx+HP_COMMITTED]
    mov rdx, r12
    sub rdx, [rbx+HP_COMMITTED]
    call mem_commit
    test rax, rax
    jz .Lhp_append_alloc
    mov [rbx+HP_COMMITTED], r12
.Lhp_append_copy:
    mov eax, [rbx+HP_SLICES]
    imul eax, eax, 10
    lea rdx, [rbx+rax+HP_SHORTS]
    mov eax, [rbx+HP_FRAME_BYTES]
    mov [rdx], eax
    mov rdi, [rbx+HP_BITS_BUFFER]
    add rdi, rax
    mov ecx, [rbx+HP_NAL_BYTES]
    add ecx, 3
    mov [rdx+4], ecx
    mov word ptr [rdx+8], 0
    add [rbx+HP_FRAME_BYTES], ecx
    mov word ptr [rdi], 0
    mov byte ptr [rdi+2], 1
    add rdi, 3
    mov rsi, [rbx+HP_NAL_PTR]
    mov rcx, [rbx+HP_NAL_BYTES]
    rep movsb
    inc dword ptr [rbx+HP_SLICES]
    mov eax, 1
    jmp .Lhp_append_return
.Lhp_append_limit:
    mov dword ptr [rbx+HP_ERROR], 3
    jmp .Lhp_append_zero
.Lhp_append_alloc:
    mov dword ptr [rbx+HP_ERROR], 4
.Lhp_append_zero:
    xor eax, eax
.Lhp_append_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_append

LOCALFN hp_finish
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov eax, [rbx+HP_FRAME_BYTES]
    mov edx, eax
    neg edx
    and edx, 127
    lea ecx, [rax+rdx]
    cmp ecx, HP_MAX_FRAME
    ja .Lhp_finish_bad
    mov [rbx+HP_FRAME_BYTES], ecx
    mov rdi, [rbx+HP_BITS_BUFFER]
    add rdi, rax
    mov ecx, edx
    xor eax, eax
    rep stosb
    mov eax, [rbx+HP_SLICES]
    dec eax
    imul eax, eax, 10
    add [rbx+rax+HP_SHORTS+4], edx
    inc qword ptr [rbx+HP_FRAMES]
    lea rdi, [rbx+HP_PICTURE]
    mov ecx, 1040/8
    xor eax, eax
    rep stosq
    mov eax, [rbx+HP_WIDTH]
    shr eax, 4
    dec eax
    mov [rbx+HP_PICTURE], ax
    mov eax, [rbx+HP_HEIGHT]
    shr eax, 4
    dec eax
    mov [rbx+HP_PICTURE+2], ax
    mov eax, [rbx+HP_REFS]
    mov [rbx+HP_PICTURE+5], al
    mov eax, [rbx+HP_CONSTRAINED]
    shl eax, 7
    or eax, 0x1810
    cmp dword ptr [rbx+HP_FRAME_TYPE], 2
    jne .Lhp_finish_ref_flag
    or eax, 0x8000
.Lhp_finish_ref_flag:
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    je .Lhp_finish_level_flag
    or eax, 0x40
.Lhp_finish_level_flag:
    mov edx, [rbx+HP_WEIGHTED]
    shl edx, 8
    or eax, edx
    mov edx, [rbx+HP_BIPRED]
    shl edx, 9
    or eax, edx
    mov edx, [rbx+HP_TRANSFORM8]
    shl edx, 13
    or eax, edx
    cmp dword ptr [rbx+HP_LEVEL], 31
    jb .Lhp_finish_flags
    or eax, 0x4000
.Lhp_finish_flags:
    mov [rbx+HP_PICTURE+6], ax
    mov word ptr [rbx+HP_PICTURE+10], 3
    mov eax, [rbx+HP_FRAMES]
    test eax, eax
    jnz .Lhp_finish_feedback
    inc eax
.Lhp_finish_feedback:
    mov [rbx+HP_PICTURE+12], eax
    pcmpeqb xmm0, xmm0
    movdqu [rbx+HP_PICTURE+16], xmm0
    mov eax, [rbx+HP_FRAME_POC]
    mov [rbx+HP_PICTURE+32], eax
    mov [rbx+HP_PICTURE+36], eax
    mov eax, [rbx+HP_QS]
    mov [rbx+HP_PICTURE+168], al
    mov eax, [rbx+HP_CHROMA]
    mov [rbx+HP_PICTURE+169], al
    mov eax, [rbx+HP_CHROMA2]
    mov [rbx+HP_PICTURE+170], al
    mov byte ptr [rbx+HP_PICTURE+171], 1
    mov eax, [rbx+HP_QP]
    mov [rbx+HP_PICTURE+172], al
    mov eax, [rbx+HP_L0]
    mov [rbx+HP_PICTURE+173], al
    mov eax, [rbx+HP_L1]
    mov [rbx+HP_PICTURE+174], al
    mov eax, [rbx+HP_FRAME_BITS]
    sub eax, 4
    mov [rbx+HP_PICTURE+216], al
    mov eax, [rbx+HP_POC_TYPE]
    mov [rbx+HP_PICTURE+217], al
    mov eax, [rbx+HP_POC_BITS]
    test eax, eax
    jz .Lhp_finish_poc_bits
    sub eax, 4
.Lhp_finish_poc_bits:
    mov [rbx+HP_PICTURE+218], al
    mov eax, [rbx+HP_DIRECT]
    mov [rbx+HP_PICTURE+220], al
    mov eax, [rbx+HP_ENTROPY]
    mov [rbx+HP_PICTURE+221], al
    mov eax, [rbx+HP_DEBLOCK]
    mov [rbx+HP_PICTURE+225], al
    mov rcx, rbx
    call hp_dpb
    test eax, eax
    jz .Lhp_finish_dpb_bad
    lea rax, [rbx+HP_PICTURE]
    mov [rbx+HP_DESC], rax
    lea rax, [rbx+HP_MATRIX]
    mov [rbx+HP_DESC+8], rax
    mov rax, [rbx+HP_BITS_BUFFER]
    mov [rbx+HP_DESC+16], rax
    mov eax, [rbx+HP_FRAME_BYTES]
    mov [rbx+HP_DESC+24], eax
    mov dword ptr [rbx+HP_DESC+28], 0
    lea rax, [rbx+HP_SHORTS]
    mov [rbx+HP_DESC+32], rax
    mov eax, [rbx+HP_SLICES]
    mov [rbx+HP_DESC+40], eax
    mov dword ptr [rbx+HP_DESC+44], 0
    mov eax, 1
    jmp .Lhp_finish_return
.Lhp_finish_dpb_bad:
    mov eax, -1
    jmp .Lhp_finish_return
.Lhp_finish_bad:
    mov dword ptr [rbx+HP_ERROR], 3
    mov eax, -1
.Lhp_finish_return:
    add rsp, 40
    pop rdi
    pop rbx
    ret
ENDFN hp_finish
