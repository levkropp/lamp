# Original progressive H.264 reference-picture marking and DXVA surface map.
# Normative H.264 8.2.1/8.2.4/8.2.5; bounded16 references,64 MMCO commands.

# RCX=context,EAX=index: remove compact DPB record. No allocation.
LOCALFN hp_dpb_remove
    mov r10d, eax
    mov r11d, [rcx+HP_DPB_COUNT]
    dec r11d
    mov [rcx+HP_DPB_COUNT], r11d
.Lhp_remove_move:
    cmp r10d, r11d
    jae .Lhp_remove_return
    mov eax, r10d
    shl eax, 4
    movdqu xmm1, [rcx+rax+HP_DPB+16]
    movdqu [rcx+rax+HP_DPB], xmm1
    inc r10d
    jmp .Lhp_remove_move
.Lhp_remove_return:
    ret
ENDFN hp_dpb_remove

# RCX=context,EDX=signed PicNum -> EAX=short-term record index or-1.
LOCALFN hp_dpb_short
    mov r9d, edx
    mov r8, rcx
    mov ecx, [r8+HP_FRAME_BITS]
    mov r11d, 1
    shl r11d, cl
    xor r10d, r10d
.Lhp_short_next:
    cmp r10d, [r8+HP_DPB_COUNT]
    jae .Lhp_short_absent
    mov eax, r10d
    shl eax, 4
    cmp dword ptr [r8+rax+HP_DPB+12], -1
    jne .Lhp_short_advance
    mov edx, [r8+rax+HP_DPB+4]
    cmp edx, [r8+HP_FRAME_NUM]
    jbe .Lhp_short_wrap
    sub edx, r11d
.Lhp_short_wrap:
    cmp edx, r9d
    je .Lhp_short_found
.Lhp_short_advance:
    inc r10d
    jmp .Lhp_short_next
.Lhp_short_found:
    mov eax, r10d
    ret
.Lhp_short_absent:
    mov eax, -1
    ret
ENDFN hp_dpb_short

# RCX=context,EDX=long-term index ->EAX=index or-1.
LOCALFN hp_dpb_long
    xor eax, eax
.Lhp_long_next:
    cmp eax, [rcx+HP_DPB_COUNT]
    jae .Lhp_long_absent
    mov r8d, eax
    shl r8d, 4
    cmp [rcx+r8+HP_DPB+12], edx
    je .Lhp_long_return
    inc eax
    jmp .Lhp_long_next
.Lhp_long_absent:
    mov eax, -1
.Lhp_long_return:
    ret
ENDFN hp_dpb_long

# RCX=parser ->1 or0/sticky error. Picture structure was cleared by hp_finish.
# Snapshot references before marking current picture, then update next-picture DPB.
LOCALFN hp_dpb
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov dword ptr [rbx+HP_MMCO5], 0
    mov dword ptr [rbx+HP_MMCO_HAS123], 0
    mov dword ptr [rbx+HP_CURRENT_LONG], -1
    cmp dword ptr [rbx+HP_FRAME_NAL], 5
    jne .Lhp_dpb_non_idr
    inc qword ptr [rbx+HP_EPOCH]
    jz .Lhp_dpb_limit
    mov dword ptr [rbx+HP_DPB_COUNT], 0
    mov dword ptr [rbx+HP_SEEN_IDR], 1
    mov dword ptr [rbx+HP_PREV_NUM], 0
    mov dword ptr [rbx+HP_PREV_REF_NUM], 0
    mov qword ptr [rbx+HP_FRAME_OFFSET], 0
    mov qword ptr [rbx+HP_PREV_POC_MSB], 0
    mov qword ptr [rbx+HP_PREV_POC_LSB], 0
    mov dword ptr [rbx+HP_MAX_LONG], -1
    cmp dword ptr [rbx+HP_FRAME_LONG], 0
    je .Lhp_dpb_poc
    mov dword ptr [rbx+HP_CURRENT_LONG], 0
    mov dword ptr [rbx+HP_MAX_LONG], 0
    jmp .Lhp_dpb_poc
.Lhp_dpb_non_idr:
    cmp dword ptr [rbx+HP_SEEN_IDR], 1
    jne .Lhp_dpb_unsupported
    # Frame-number gaps need explicit non-existing pictures; currently reject.
    mov eax, [rbx+HP_FRAME_NUM]
    cmp eax, [rbx+HP_PREV_REF_NUM]
    jne .Lhp_dpb_gap_next
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    jne .Lhp_dpb_bad
    jmp .Lhp_dpb_offset
.Lhp_dpb_gap_next:
    mov ecx, [rbx+HP_FRAME_BITS]
    mov edx, 1
    shl edx, cl
    dec edx
    mov eax, [rbx+HP_PREV_REF_NUM]
    inc eax
    and eax, edx
    cmp eax, [rbx+HP_FRAME_NUM]
    jne .Lhp_dpb_unsupported
.Lhp_dpb_offset:
    mov eax, [rbx+HP_FRAME_NUM]
    cmp eax, [rbx+HP_PREV_NUM]
    jae .Lhp_dpb_poc
    mov ecx, [rbx+HP_FRAME_BITS]
    mov eax, 1
    shl eax, cl
    add [rbx+HP_FRAME_OFFSET], rax
    jc .Lhp_dpb_limit
.Lhp_dpb_poc:
    cmp dword ptr [rbx+HP_POC_TYPE], 0
    je .Lhp_dpb_poc0
    mov rax, [rbx+HP_FRAME_OFFSET]
    mov edx, [rbx+HP_FRAME_NUM]
    add rax, rdx
    jc .Lhp_dpb_limit
    add rax, rax
    jo .Lhp_dpb_limit
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    jne .Lhp_dpb_poc_store
    dec rax
    jmp .Lhp_dpb_poc_store
.Lhp_dpb_poc0:
    mov rax, [rbx+HP_PREV_POC_MSB]
    mov edx, [rbx+HP_FRAME_POC]
    mov r8, [rbx+HP_PREV_POC_LSB]
    mov ecx, [rbx+HP_POC_BITS]
    mov r9d, 1
    shl r9d, cl
    mov r10d, r9d
    shr r10d, 1
    cmp rdx, r8
    jae .Lhp_dpb_poc0_upper
    sub r8, rdx
    cmp r8, r10
    jb .Lhp_dpb_poc0_add
    add rax, r9
    jo .Lhp_dpb_limit
    jmp .Lhp_dpb_poc0_add
.Lhp_dpb_poc0_upper:
    sub rdx, r8
    cmp rdx, r10
    jbe .Lhp_dpb_poc0_add
    sub rax, r9
    jo .Lhp_dpb_limit
.Lhp_dpb_poc0_add:
    mov [rbx+HP_CURRENT_MSB], rax
    mov edx, [rbx+HP_FRAME_POC]
    add rax, rdx
    jo .Lhp_dpb_limit
.Lhp_dpb_poc_store:
    movsxd rdx, eax
    cmp rax, rdx
    jne .Lhp_dpb_limit
    mov [rbx+HP_CURRENT_POC], eax
    mov [rbx+HP_PICTURE+32], eax
    mov [rbx+HP_PICTURE+36], eax
    mov eax, [rbx+HP_FRAME_NUM]
    mov [rbx+HP_PICTURE+214], ax
    # Free destination slot excludes every pre-marking reference, including one
    # which MMCO/sliding will remove after this picture has decoded.
    xor edi, edi
    xor esi, esi
.Lhp_dpb_snapshot:
    cmp edi, [rbx+HP_DPB_COUNT]
    jae .Lhp_dpb_slot
    mov eax, edi
    shl eax, 4
    lea rdx, [rbx+rax+HP_DPB]
    mov eax, [rdx]
    bts esi, eax
    mov ecx, [rdx+12]
    test ecx, ecx
    js .Lhp_dpb_snapshot_short
    or eax, 128
    jmp .Lhp_dpb_snapshot_frame
.Lhp_dpb_snapshot_short:
    mov ecx, [rdx+4]
.Lhp_dpb_snapshot_frame:
    mov [rbx+rdi+HP_PICTURE+16], al
    mov [rbx+rdi*2+HP_PICTURE+176], cx
    mov eax, [rdx+8]
    mov [rbx+rdi*8+HP_PICTURE+40], eax
    mov [rbx+rdi*8+HP_PICTURE+44], eax
    lea ecx, [rdi+rdi]
    mov eax, 3
    shl eax, cl
    or [rbx+HP_PICTURE+208], eax
    inc edi
    jmp .Lhp_dpb_snapshot
.Lhp_dpb_slot:
    or esi, [rbx+HP_HOLD_MASK]
    xor eax, eax
.Lhp_dpb_slot_next:
    bt esi, eax
    jnc .Lhp_dpb_slot_found
    inc eax
    cmp eax, [rbx+HP_SURFACES]
    jb .Lhp_dpb_slot_next
    jmp .Lhp_dpb_limit
.Lhp_dpb_slot_found:
    mov [rbx+HP_CURRENT_SLOT], eax
    mov [rbx+HP_PICTURE+4], al
    cmp dword ptr [rbx+HP_FRAME_NAL], 5
    je .Lhp_dpb_insert
    cmp dword ptr [rbx+HP_FRAME_TYPE], 2
    je .Lhp_dpb_mark
    cmp dword ptr [rbx+HP_DPB_COUNT], 0
    je .Lhp_dpb_bad
.Lhp_dpb_mark:
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    je .Lhp_dpb_history
    cmp dword ptr [rbx+HP_FRAME_ADAPT], 0
    je .Lhp_dpb_sliding
    lea rsi, [rbx+HP_FRAME_MMCO]
    mov r12d, [rbx+HP_FRAME_MMCO_COUNT]
.Lhp_dpb_mmco:
    test r12d, r12d
    jz .Lhp_dpb_insert
    mov r13d, [rsi]
    cmp r13d, 3
    ja .Lhp_dpb_mmco_dispatch
    cmp dword ptr [rbx+HP_MMCO5], 0
    jne .Lhp_dpb_bad
    mov dword ptr [rbx+HP_MMCO_HAS123], 1
.Lhp_dpb_mmco_dispatch:
    cmp r13d, 1
    je .Lhp_dpb_mmco_short
    cmp r13d, 2
    je .Lhp_dpb_mmco_long
    cmp r13d, 3
    je .Lhp_dpb_mmco_assign
    cmp r13d, 4
    je .Lhp_dpb_mmco_max
    cmp r13d, 5
    je .Lhp_dpb_mmco_reset
    cmp r13d, 6
    jne .Lhp_dpb_bad
    mov edx, [rsi+8]
    cmp edx, [rbx+HP_MAX_LONG]
    jg .Lhp_dpb_bad
    cmp dword ptr [rbx+HP_CURRENT_LONG], -1
    jne .Lhp_dpb_bad
    mov [rbx+HP_CURRENT_LONG], edx
    mov rcx, rbx
    call hp_dpb_long
    test eax, eax
    js .Lhp_dpb_mmco_next
    mov rcx, rbx
    call hp_dpb_remove
    jmp .Lhp_dpb_mmco_next
.Lhp_dpb_mmco_assign:
    mov edx, [rsi+8]
    cmp edx, [rbx+HP_CURRENT_LONG]
    je .Lhp_dpb_bad
    cmp edx, [rbx+HP_MAX_LONG]
    jg .Lhp_dpb_bad
    mov rcx, rbx
    call hp_dpb_long
    test eax, eax
    js .Lhp_dpb_mmco_short
    mov rcx, rbx
    call hp_dpb_remove
.Lhp_dpb_mmco_short:
    mov edx, [rbx+HP_FRAME_NUM]
    sub edx, [rsi+4]
    dec edx
    mov rcx, rbx
    call hp_dpb_short
    test eax, eax
    js .Lhp_dpb_bad
    cmp r13d, 3
    jne .Lhp_dpb_mmco_remove
    shl eax, 4
    mov edx, [rsi+8]
    mov [rbx+rax+HP_DPB+12], edx
    jmp .Lhp_dpb_mmco_next
.Lhp_dpb_mmco_long:
    mov rcx, rbx
    mov edx, [rsi+4]
    cmp edx, [rbx+HP_CURRENT_LONG]
    je .Lhp_dpb_bad
    call hp_dpb_long
    test eax, eax
    js .Lhp_dpb_bad
.Lhp_dpb_mmco_remove:
    mov rcx, rbx
    call hp_dpb_remove
    jmp .Lhp_dpb_mmco_next
.Lhp_dpb_mmco_max:
    mov eax, [rsi+4]
    cmp eax, [rbx+HP_REFS]
    ja .Lhp_dpb_bad
    dec eax
    cmp eax, [rbx+HP_CURRENT_LONG]
    jl .Lhp_dpb_bad
    mov [rbx+HP_MAX_LONG], eax
    mov edi, [rbx+HP_DPB_COUNT]
.Lhp_dpb_mmco_max_next:
    dec edi
    js .Lhp_dpb_mmco_next
    mov eax, edi
    shl eax, 4
    mov eax, [rbx+rax+HP_DPB+12]
    cmp eax, [rbx+HP_MAX_LONG]
    jle .Lhp_dpb_mmco_max_next
    mov rcx, rbx
    mov eax, edi
    call hp_dpb_remove
    jmp .Lhp_dpb_mmco_max_next
.Lhp_dpb_mmco_reset:
    cmp dword ptr [rbx+HP_MMCO5], 0
    jne .Lhp_dpb_bad
    cmp dword ptr [rbx+HP_MMCO_HAS123], 0
    jne .Lhp_dpb_bad
    cmp dword ptr [rbx+HP_CURRENT_LONG], -1
    jne .Lhp_dpb_bad
    mov dword ptr [rbx+HP_DPB_COUNT], 0
    mov dword ptr [rbx+HP_MAX_LONG], -1
    mov dword ptr [rbx+HP_MMCO5], 1
    inc qword ptr [rbx+HP_EPOCH]
    jz .Lhp_dpb_limit
.Lhp_dpb_mmco_next:
    add rsi, 12
    dec r12d
    jmp .Lhp_dpb_mmco
.Lhp_dpb_sliding:
    mov eax, [rbx+HP_REFS]
    mov edx, 1
    test eax, eax
    cmovz eax, edx
    cmp [rbx+HP_DPB_COUNT], eax
    jb .Lhp_dpb_insert
    jne .Lhp_dpb_bad
    # Select smallest FrameNumWrap among short-term references.
    xor edi, edi
    mov ebp, -1
    mov r12d, 0x7fffffff
    mov ecx, [rbx+HP_FRAME_BITS]
    mov r13d, 1
    shl r13d, cl
.Lhp_dpb_oldest:
    cmp edi, [rbx+HP_DPB_COUNT]
    jae .Lhp_dpb_oldest_found
    mov eax, edi
    shl eax, 4
    cmp dword ptr [rbx+rax+HP_DPB+12], -1
    jne .Lhp_dpb_oldest_next
    mov eax, [rbx+rax+HP_DPB+4]
    cmp eax, [rbx+HP_FRAME_NUM]
    jbe .Lhp_dpb_oldest_compare
    sub eax, r13d
.Lhp_dpb_oldest_compare:
    cmp eax, r12d
    jge .Lhp_dpb_oldest_next
    mov r12d, eax
    mov ebp, edi
.Lhp_dpb_oldest_next:
    inc edi
    jmp .Lhp_dpb_oldest
.Lhp_dpb_oldest_found:
    test ebp, ebp
    js .Lhp_dpb_bad
    mov rcx, rbx
    mov eax, ebp
    call hp_dpb_remove
.Lhp_dpb_insert:
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    je .Lhp_dpb_history
    mov eax, [rbx+HP_REFS]
    mov edx, 1
    test eax, eax
    cmovz eax, edx
    cmp [rbx+HP_DPB_COUNT], eax
    jae .Lhp_dpb_bad
    mov eax, [rbx+HP_DPB_COUNT]
    shl eax, 4
    lea rdx, [rbx+rax+HP_DPB]
    mov eax, [rbx+HP_CURRENT_SLOT]
    mov [rdx], eax
    mov eax, [rbx+HP_FRAME_NUM]
    mov [rdx+4], eax
    mov eax, [rbx+HP_CURRENT_POC]
    mov [rdx+8], eax
    mov eax, [rbx+HP_CURRENT_LONG]
    mov [rdx+12], eax
    cmp dword ptr [rbx+HP_MMCO5], 0
    je .Lhp_dpb_insert_count
    mov qword ptr [rdx+4], 0 # post-MMCO5 stored FrameNum/POC become0.
.Lhp_dpb_insert_count:
    inc dword ptr [rbx+HP_DPB_COUNT]
.Lhp_dpb_history:
    cmp dword ptr [rbx+HP_MMCO5], 0
    jne .Lhp_dpb_history_reset
.Lhp_dpb_history_store:
    mov eax, [rbx+HP_CURRENT_POC]
    mov [rbx+HP_LAST_POC], eax
    mov [rbx+HP_OUTPUT_POC], eax
    mov eax, [rbx+HP_FRAME_NUM]
    mov [rbx+HP_PREV_NUM], eax
    cmp dword ptr [rbx+HP_FRAME_REF], 0
    je .Lhp_dpb_ok
    mov [rbx+HP_PREV_REF_NUM], eax
    mov rax, [rbx+HP_CURRENT_MSB]
    mov [rbx+HP_PREV_POC_MSB], rax
    mov eax, [rbx+HP_FRAME_POC]
    mov [rbx+HP_PREV_POC_LSB], rax
    jmp .Lhp_dpb_ok
.Lhp_dpb_history_reset:
    mov dword ptr [rbx+HP_OUTPUT_POC], 0
    mov dword ptr [rbx+HP_LAST_POC], 0
    mov dword ptr [rbx+HP_PREV_NUM], 0
    mov dword ptr [rbx+HP_PREV_REF_NUM], 0
    mov qword ptr [rbx+HP_FRAME_OFFSET], 0
    mov qword ptr [rbx+HP_PREV_POC_MSB], 0
    mov qword ptr [rbx+HP_PREV_POC_LSB], 0
.Lhp_dpb_ok:
    mov eax, 1
    jmp .Lhp_dpb_return
.Lhp_dpb_limit:
    mov dword ptr [rbx+HP_ERROR], 3
    jmp .Lhp_dpb_zero
.Lhp_dpb_unsupported:
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhp_dpb_zero
.Lhp_dpb_bad:
    mov dword ptr [rbx+HP_ERROR], 1
.Lhp_dpb_zero:
    xor eax, eax
.Lhp_dpb_return:
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN hp_dpb
