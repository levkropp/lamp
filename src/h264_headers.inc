# Original H.264 Baseline/Main/High 8-bit I/P parsing. Included by h264.s only.
RODATA
.p2align 2
hp_sars: .short 0,0, 1,1, 12,11, 10,11, 16,11, 40,33, 24,11, 20,11
    .short 32,11, 80,33, 18,11, 15,11, 64,33, 160,99, 4,3, 3,2, 2,1
.text

LOCALFN hp_sps
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    lea rdi, [rbx+HP_SPS_MATRIX]
    mov ecx, 224
    mov al, 16
    rep stosb
    mov rcx, rbx
    call hp_header
    HP_BITS 8,HP_PROFILE,255,.Lhp_sps_bad
    cmp eax, 66
    je .Lhp_sps_profile_ok
    cmp eax, 77
    je .Lhp_sps_profile_ok
    cmp eax, 100
    jne .Lhp_sps_unsupported
.Lhp_sps_profile_ok:
    HP_BITS 8,HP_CONSTRAINTS,255,.Lhp_sps_bad
    test eax, 3
    jnz .Lhp_sps_bad
    HP_BITS 8,HP_LEVEL,62,.Lhp_sps_bad
    cmp eax, 9
    jb .Lhp_sps_bad
    HP_UE HP_SPS_ID,31,.Lhp_sps_bad
    cmp dword ptr [rbx+HP_PROFILE], 100
    jne .Lhp_sps_frame_bits
    HP_UE -1,3,.Lhp_sps_bad
    cmp eax, 1
    jne .Lhp_sps_unsupported # NV12 4:2:0 only.
    HP_UE -1,0,.Lhp_sps_unsupported # bit_depth_luma_minus8
    HP_UE -1,0,.Lhp_sps_unsupported # bit_depth_chroma_minus8
    HP_BITS 1,-1,0,.Lhp_sps_unsupported # transform bypass not in native contract
    HP_BITS 1,HP_SEQ_SCALING,1,.Lhp_sps_bad
    test eax, eax
    jz .Lhp_sps_frame_bits
    mov rcx, rbx
    lea rdx, [rbx+HP_SPS_MATRIX]
    mov r8d, 8
    xor r9d, r9d
    call hp_scaling_set
    test eax, eax
    jz .Lhp_sps_return
.Lhp_sps_frame_bits:
    HP_UE HP_FRAME_BITS,12,.Lhp_sps_bad
    add dword ptr [rbx+HP_FRAME_BITS], 4
    HP_UE HP_POC_TYPE,2,.Lhp_sps_bad
    cmp eax, 1
    je .Lhp_sps_unsupported
    test eax, eax
    jnz .Lhp_sps_refs
    HP_UE HP_POC_BITS,12,.Lhp_sps_bad
    add dword ptr [rbx+HP_POC_BITS], 4
.Lhp_sps_refs:
    HP_UE HP_REFS,16,.Lhp_sps_bad
    HP_BITS 1,-1,1,.Lhp_sps_bad # gaps flag parsed; inferred missing pictures reject
    HP_UE HP_WIDTH,255,.Lhp_sps_unsupported
    inc dword ptr [rbx+HP_WIDTH]
    shl dword ptr [rbx+HP_WIDTH], 4
    HP_UE HP_HEIGHT,255,.Lhp_sps_unsupported
    inc dword ptr [rbx+HP_HEIGHT]
    shl dword ptr [rbx+HP_HEIGHT], 4
    HP_BITS 1,-1,1,.Lhp_sps_bad
    cmp eax, 1
    jne .Lhp_sps_unsupported
    HP_BITS 1,HP_DIRECT,1,.Lhp_sps_bad
    HP_BITS 1,-1,1,.Lhp_sps_bad
    test eax, eax
    jz .Lhp_sps_crop_size
    HP_UE HP_LEFT,2047,.Lhp_sps_bad
    HP_UE HP_RIGHT,2047,.Lhp_sps_bad
    HP_UE HP_TOP,2047,.Lhp_sps_bad
    HP_UE HP_BOTTOM,2047,.Lhp_sps_bad
    shl dword ptr [rbx+HP_LEFT], 1
    shl dword ptr [rbx+HP_RIGHT], 1
    shl dword ptr [rbx+HP_TOP], 1
    shl dword ptr [rbx+HP_BOTTOM], 1
.Lhp_sps_crop_size:
    mov eax, [rbx+HP_WIDTH]
    sub eax, [rbx+HP_LEFT]
    jbe .Lhp_sps_bad
    sub eax, [rbx+HP_RIGHT]
    jbe .Lhp_sps_bad
    mov [rbx+HP_VISIBLE_W], eax
    mov eax, [rbx+HP_HEIGHT]
    sub eax, [rbx+HP_TOP]
    jbe .Lhp_sps_bad
    sub eax, [rbx+HP_BOTTOM]
    jbe .Lhp_sps_bad
    mov [rbx+HP_VISIBLE_H], eax
    mov dword ptr [rbx+HP_PRIMARIES], 2
    mov dword ptr [rbx+HP_TRANSFER], 2
    mov dword ptr [rbx+HP_COLOR_MATRIX], 2
    HP_BITS 1,-1,1,.Lhp_sps_bad
    test eax, eax
    jz .Lhp_sps_trailing
    mov rcx, rbx
    call hp_vui
    test eax, eax
    jz .Lhp_sps_return
.Lhp_sps_trailing:
    mov rcx, rbx
    call hp_trailing
    test eax, eax
    jz .Lhp_sps_return
    mov rcx, rbx
    call hp_limits
    jmp .Lhp_sps_return
.Lhp_sps_unsupported:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_sps_zero
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhp_sps_zero
.Lhp_sps_bad:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_sps_zero
    mov dword ptr [rbx+HP_ERROR], 1
.Lhp_sps_zero:
    xor eax, eax
.Lhp_sps_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_sps

LOCALFN hp_vui
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_overscan
    HP_BITS 8,-1,255,.Lhp_vui_bad
    cmp eax, 255
    je .Lhp_vui_extended_sar
    cmp eax, 16
    ja .Lhp_vui_bad
    lea rdx, [rip+hp_sars]
    movzx ecx, word ptr [rdx+rax*4]
    mov [rbx+HP_SAR_W], ecx
    movzx ecx, word ptr [rdx+rax*4+2]
    mov [rbx+HP_SAR_H], ecx
    jmp .Lhp_vui_overscan
.Lhp_vui_extended_sar:
    HP_BITS 16,HP_SAR_W,65535,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_bad
    HP_BITS 16,HP_SAR_H,65535,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_bad
.Lhp_vui_overscan:
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_video
    HP_BITS 1,-1,1,.Lhp_vui_bad
.Lhp_vui_video:
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_chroma
    HP_BITS 3,-1,5,.Lhp_vui_bad
    HP_BITS 1,HP_FULL_RANGE,1,.Lhp_vui_bad
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_chroma
    HP_BITS 8,HP_PRIMARIES,255,.Lhp_vui_bad
    HP_BITS 8,HP_TRANSFER,255,.Lhp_vui_bad
    HP_BITS 8,HP_COLOR_MATRIX,255,.Lhp_vui_bad
.Lhp_vui_chroma:
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_timing
    HP_UE -1,5,.Lhp_vui_bad
    HP_UE -1,5,.Lhp_vui_bad
.Lhp_vui_timing:
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_hrds
    HP_BITS 32,HP_TIME_TICK,0xffffffff,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_bad
    HP_BITS 32,HP_TIME_SCALE,0xffffffff,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_bad
    HP_BITS 1,HP_FIXED_RATE,1,.Lhp_vui_bad
.Lhp_vui_hrds:
    xor esi, esi
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_vcl
    inc esi
    mov rcx, rbx
    call hp_hrd
    test eax, eax
    jz .Lhp_vui_bad
.Lhp_vui_vcl:
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_delay
    inc esi
    mov rcx, rbx
    call hp_hrd
    test eax, eax
    jz .Lhp_vui_bad
.Lhp_vui_delay:
    test esi, esi
    jz .Lhp_vui_pic_struct
    HP_BITS 1,-1,1,.Lhp_vui_bad
.Lhp_vui_pic_struct:
    HP_BITS 1,-1,1,.Lhp_vui_bad # pic_struct flag parsed; SEI timing is not applied
    HP_BITS 1,-1,1,.Lhp_vui_bad
    test eax, eax
    jz .Lhp_vui_ok
    mov dword ptr [rbx+HP_RESTRICTION], 1
    HP_BITS 1,-1,1,.Lhp_vui_bad
    HP_UE -1,16,.Lhp_vui_bad
    HP_UE -1,16,.Lhp_vui_bad
    HP_UE -1,16,.Lhp_vui_bad
    HP_UE -1,16,.Lhp_vui_bad
    HP_UE HP_MAX_REORDER,16,.Lhp_vui_bad
    mov esi, eax
    HP_UE HP_MAX_BUFFER,16,.Lhp_vui_bad
    cmp eax, esi
    jb .Lhp_vui_bad
    cmp eax, [rbx+HP_REFS]
    jb .Lhp_vui_bad
.Lhp_vui_ok:
    mov eax, 1
    jmp .Lhp_vui_return
.Lhp_vui_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_vui_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN hp_vui

LOCALFN hp_hrd
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    HP_UE -1,31,.Lhp_hrd_bad
    lea esi, [rax+1]
    HP_BITS 8,-1,255,.Lhp_hrd_bad # scales:4+4
.Lhp_hrd_entry:
    HP_UE -1,0xfffffffe,.Lhp_hrd_bad
    HP_UE -1,0xfffffffe,.Lhp_hrd_bad
    HP_BITS 1,-1,1,.Lhp_hrd_bad
    dec esi
    jnz .Lhp_hrd_entry
    HP_BITS 20,-1,0xfffff,.Lhp_hrd_bad # four5-bit delay lengths
    mov eax, 1
    jmp .Lhp_hrd_return
.Lhp_hrd_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_hrd_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN hp_hrd

LOCALFN hp_pps
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    lea rsi, [rbx+HP_SPS_MATRIX]
    lea rdi, [rbx+HP_MATRIX]
    mov ecx, 224
    rep movsb
    mov rcx, rbx
    call hp_header
    HP_UE HP_PPS_ID,255,.Lhp_pps_bad
    HP_UE -1,31,.Lhp_pps_bad
    cmp eax, [rbx+HP_SPS_ID]
    jne .Lhp_pps_unsupported
    HP_BITS 1,HP_ENTROPY,1,.Lhp_pps_bad
    cmp dword ptr [rbx+HP_PROFILE], 66
    jne .Lhp_pps_entropy_ok
    test eax, eax
    jnz .Lhp_pps_unsupported
.Lhp_pps_entropy_ok:
    HP_BITS 1,-1,0,.Lhp_pps_unsupported # no bottom POC delta
    HP_UE -1,0,.Lhp_pps_unsupported     # no slice groups
    HP_UE HP_L0,31,.Lhp_pps_bad
    HP_UE HP_L1,31,.Lhp_pps_bad
    HP_BITS 1,HP_WEIGHTED,1,.Lhp_pps_bad
    HP_BITS 2,HP_BIPRED,2,.Lhp_pps_bad
    cmp dword ptr [rbx+HP_PROFILE], 66
    jne .Lhp_pps_weight_ok
    or eax, [rbx+HP_WEIGHTED]
    jnz .Lhp_pps_unsupported
.Lhp_pps_weight_ok:
    HP_SE HP_QP,-26,25,.Lhp_pps_bad
    HP_SE HP_QS,-26,25,.Lhp_pps_bad
    HP_SE HP_CHROMA,-12,12,.Lhp_pps_bad
    mov [rbx+HP_CHROMA2], eax
    HP_BITS 1,HP_DEBLOCK,1,.Lhp_pps_bad
    HP_BITS 1,HP_CONSTRAINED,1,.Lhp_pps_bad
    HP_BITS 1,-1,0,.Lhp_pps_unsupported # no redundant pictures
    mov rcx, rbx
    call hp_more
    test eax, eax
    jz .Lhp_pps_trailing
    HP_BITS 1,HP_TRANSFORM8,1,.Lhp_pps_bad
    cmp dword ptr [rbx+HP_PROFILE], 100
    je .Lhp_pps_transform_ok
    test eax, eax
    jnz .Lhp_pps_unsupported
.Lhp_pps_transform_ok:
    HP_BITS 1,-1,1,.Lhp_pps_bad
    test eax, eax
    jz .Lhp_pps_chroma2
    cmp dword ptr [rbx+HP_PROFILE], 100
    jne .Lhp_pps_unsupported
    mov rcx, rbx
    lea rdx, [rbx+HP_MATRIX]
    mov r8d, [rbx+HP_TRANSFORM8]
    lea r8d, [r8+r8+6]
    mov r9d, 1
    call hp_scaling_set
    test eax, eax
    jz .Lhp_pps_return
.Lhp_pps_chroma2:
    HP_SE HP_CHROMA2,-12,12,.Lhp_pps_bad
.Lhp_pps_trailing:
    mov rcx, rbx
    call hp_trailing
    jmp .Lhp_pps_return
.Lhp_pps_unsupported:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_pps_zero
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhp_pps_zero
.Lhp_pps_bad:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_pps_zero
    mov dword ptr [rbx+HP_ERROR], 1
.Lhp_pps_zero:
    xor eax, eax
.Lhp_pps_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_pps

LOCALFN hp_slice
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    call hp_header
    HP_UE HP_TEMP_MB,65535,.Lhp_slice_bad
    mov edx, [rbx+HP_WIDTH]
    imul edx, [rbx+HP_HEIGHT]
    shr edx, 8
    cmp eax, edx
    jae .Lhp_slice_bad
    HP_UE -1,9,.Lhp_slice_bad
    cmp eax, 5
    jb .Lhp_slice_type
    sub eax, 5
.Lhp_slice_type:
    mov [rbx+HP_TEMP_TYPE], eax
    test eax, eax
    jz .Lhp_slice_type_ok
    cmp eax, 1
    jne .Lhp_slice_intra_type
    cmp dword ptr [rbx+HP_PROFILE], 66
    je .Lhp_slice_unsupported
    jmp .Lhp_slice_type_ok
.Lhp_slice_intra_type:
    cmp eax, 2
    jne .Lhp_slice_unsupported
.Lhp_slice_type_ok:
    cmp dword ptr [rbx+HP_TEMP_NAL], 5
    jne .Lhp_slice_pps
    cmp dword ptr [rbx+HP_TEMP_REF], 0
    je .Lhp_slice_bad
    cmp eax, 2
    jne .Lhp_slice_bad
.Lhp_slice_pps:
    HP_UE HP_TEMP_PPS,255,.Lhp_slice_bad
    cmp eax, [rbx+HP_PPS_ID]
    jne .Lhp_slice_unsupported
    mov rcx, rbx
    mov edx, [rbx+HP_FRAME_BITS]
    call hp_bits
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_slice_bad
    mov [rbx+HP_TEMP_NUM], eax
    mov dword ptr [rbx+HP_TEMP_IDR], 0
    cmp dword ptr [rbx+HP_TEMP_NAL], 5
    jne .Lhp_slice_poc
    test eax, eax
    jnz .Lhp_slice_bad         # IDR frame_num must0
    HP_UE HP_TEMP_IDR,65535,.Lhp_slice_bad
.Lhp_slice_poc:
    mov dword ptr [rbx+HP_TEMP_POC], 0
    cmp dword ptr [rbx+HP_POC_TYPE], 0
    jne .Lhp_slice_prediction
    mov rcx, rbx
    mov edx, [rbx+HP_POC_BITS]
    call hp_bits
    mov [rbx+HP_TEMP_POC], eax
.Lhp_slice_prediction:
    cmp dword ptr [rbx+HP_TEMP_TYPE], 2
    je .Lhp_slice_marking
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_slice_ref_counts
    HP_BITS 1,-1,1,.Lhp_slice_bad # direct_spatial_mv_pred_flag
.Lhp_slice_ref_counts:
    mov eax, [rbx+HP_L0]
    mov [rbx+HP_TEMP_ACTIVE], eax
    mov eax, [rbx+HP_L1]
    mov [rbx+HP_TEMP_ACTIVE1], eax
    HP_BITS 1,-1,1,.Lhp_slice_bad
    test eax, eax
    jz .Lhp_slice_active
    HP_UE HP_TEMP_ACTIVE,15,.Lhp_slice_bad
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_slice_active
    HP_UE HP_TEMP_ACTIVE1,15,.Lhp_slice_bad
.Lhp_slice_active:
    cmp dword ptr [rbx+HP_TEMP_ACTIVE], 15
    ja .Lhp_slice_unsupported
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_slice_lists
    cmp dword ptr [rbx+HP_TEMP_ACTIVE1], 15
    ja .Lhp_slice_unsupported
.Lhp_slice_lists:
    xor edi, edi
.Lhp_slice_list_flag:
    HP_BITS 1,-1,1,.Lhp_slice_bad # ref_pic_list_modification_flag_l0
    test eax, eax
    jz .Lhp_slice_next_list
    xor r12d, r12d
.Lhp_slice_list_mod:
    HP_UE -1,3,.Lhp_slice_bad
    cmp eax, 3
    je .Lhp_slice_next_list
    inc r12d
    cmp r12d, 32
    ja .Lhp_slice_unsupported
    cmp eax, 2
    je .Lhp_slice_list_long
    HP_UE -1,65535,.Lhp_slice_bad
    mov edx, eax
    mov ecx, [rbx+HP_FRAME_BITS]
    mov eax, 1
    shl eax, cl
    cmp edx, eax
    jae .Lhp_slice_bad
    jmp .Lhp_slice_list_mod
.Lhp_slice_list_long:
    HP_UE -1,15,.Lhp_slice_bad
    jmp .Lhp_slice_list_mod
.Lhp_slice_next_list:
    test edi, edi
    jnz .Lhp_slice_weights
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_slice_weights
    inc edi
    jmp .Lhp_slice_list_flag
.Lhp_slice_weights:
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_slice_p_weights
    cmp dword ptr [rbx+HP_BIPRED], 1
    jne .Lhp_slice_marking
    jmp .Lhp_slice_read_weights
.Lhp_slice_p_weights:
    cmp dword ptr [rbx+HP_WEIGHTED], 0
    je .Lhp_slice_marking
.Lhp_slice_read_weights:
    mov rcx, rbx
    call hp_weights
    test eax, eax
    jz .Lhp_slice_return
.Lhp_slice_marking:
    mov dword ptr [rbx+HP_TEMP_NOOUTPUT], 0
    mov dword ptr [rbx+HP_TEMP_MMCO_COUNT], 0
    mov dword ptr [rbx+HP_TEMP_ADAPT], 0
    mov dword ptr [rbx+HP_TEMP_LONG], 0
    cmp dword ptr [rbx+HP_TEMP_REF], 0
    je .Lhp_slice_qp
    cmp dword ptr [rbx+HP_TEMP_NAL], 5
    jne .Lhp_slice_adaptive
    HP_BITS 1,HP_TEMP_NOOUTPUT,1,.Lhp_slice_bad
    HP_BITS 1,HP_TEMP_LONG,1,.Lhp_slice_bad
    jmp .Lhp_slice_qp
.Lhp_slice_adaptive:
    HP_BITS 1,HP_TEMP_ADAPT,1,.Lhp_slice_bad
    test eax, eax
    jz .Lhp_slice_qp
    xor edi, edi
    lea rsi, [rbx+HP_TEMP_MMCO]
.Lhp_slice_mmco:
    HP_UE -1,6,.Lhp_slice_bad
    test eax, eax
    jz .Lhp_slice_mmco_done
    cmp edi, 64
    jae .Lhp_slice_unsupported
    mov r12d, eax
    mov [rsi], eax
    mov qword ptr [rsi+4], 0
    cmp eax, 1
    je .Lhp_slice_difference
    cmp eax, 3
    jne .Lhp_slice_long_pic
.Lhp_slice_difference:
    HP_UE -1,65535,.Lhp_slice_bad
    mov [rsi+4], eax
    mov edx, eax
    mov ecx, [rbx+HP_FRAME_BITS]
    mov eax, 1
    shl eax, cl
    cmp edx, eax
    jae .Lhp_slice_bad
.Lhp_slice_long_pic:
    cmp r12d, 2
    jne .Lhp_slice_max_long
    HP_UE -1,15,.Lhp_slice_bad
    mov [rsi+4], eax
.Lhp_slice_max_long:
    cmp r12d, 4
    jne .Lhp_slice_long_index
    HP_UE -1,16,.Lhp_slice_bad
    mov [rsi+4], eax
.Lhp_slice_long_index:
    cmp r12d, 3
    je .Lhp_slice_index
    cmp r12d, 6
    jne .Lhp_slice_mmco_next
.Lhp_slice_index:
    HP_UE -1,15,.Lhp_slice_bad
    mov [rsi+8], eax
.Lhp_slice_mmco_next:
    inc edi
    add rsi, 12
    jmp .Lhp_slice_mmco
.Lhp_slice_mmco_done:
    mov [rbx+HP_TEMP_MMCO_COUNT], edi
.Lhp_slice_qp:
    cmp dword ptr [rbx+HP_ENTROPY], 0
    je .Lhp_slice_qp_delta
    cmp dword ptr [rbx+HP_TEMP_TYPE], 2
    je .Lhp_slice_qp_delta
    HP_UE -1,2,.Lhp_slice_bad # cabac_init_idc, P pictures only.
.Lhp_slice_qp_delta:
    HP_SE -1,-51,51,.Lhp_slice_bad
    add eax, [rbx+HP_QP]
    add eax, 26
    cmp eax, 51
    ja .Lhp_slice_bad
    cmp dword ptr [rbx+HP_DEBLOCK], 0
    je .Lhp_slice_alignment
    HP_UE -1,2,.Lhp_slice_bad
    cmp eax, 1
    je .Lhp_slice_alignment
    HP_SE -1,-6,6,.Lhp_slice_bad
    HP_SE -1,-6,6,.Lhp_slice_bad
.Lhp_slice_alignment:
    cmp dword ptr [rbx+HP_ENTROPY], 0
    je .Lhp_slice_payload
.Lhp_slice_align_bit:
    cmp dword ptr [rbx+HP_BR_BITS], 0
    je .Lhp_slice_payload
    HP_BITS 1,-1,1,.Lhp_slice_bad
    test eax, eax
    jz .Lhp_slice_bad
    jmp .Lhp_slice_align_bit
.Lhp_slice_payload:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_slice_bad
    mov rax, [rbx+HP_BR_PTR]
    cmp rax, [rbx+HP_BR_END]
    jb .Lhp_slice_ok
    cmp dword ptr [rbx+HP_BR_BITS], 0
    je .Lhp_slice_bad
.Lhp_slice_ok:
    mov eax, 1
    jmp .Lhp_slice_return
.Lhp_slice_unsupported:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_slice_zero
    mov dword ptr [rbx+HP_ERROR], 2
    jmp .Lhp_slice_zero
.Lhp_slice_bad:
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_slice_zero
    mov dword ptr [rbx+HP_ERROR], 1
.Lhp_slice_zero:
    xor eax, eax
.Lhp_slice_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_slice

# Parse bounded explicit P prediction weights. Raw-slice driver uses the values.
LOCALFN hp_weights
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    HP_UE -1,7,.Lhp_weights_bad
    HP_UE -1,7,.Lhp_weights_bad
    xor esi, esi
    xor edi, edi
.Lhp_weights_ref:
    HP_BITS 1,-1,1,.Lhp_weights_bad
    test eax, eax
    jz .Lhp_weights_chroma
    HP_SE -1,-128,127,.Lhp_weights_bad
    HP_SE -1,-128,127,.Lhp_weights_bad
.Lhp_weights_chroma:
    HP_BITS 1,-1,1,.Lhp_weights_bad
    test eax, eax
    jz .Lhp_weights_next
    HP_SE -1,-128,127,.Lhp_weights_bad
    HP_SE -1,-128,127,.Lhp_weights_bad
    HP_SE -1,-128,127,.Lhp_weights_bad
    HP_SE -1,-128,127,.Lhp_weights_bad
.Lhp_weights_next:
    inc esi
    test edi, edi
    jnz .Lhp_weights_last
    cmp esi, [rbx+HP_TEMP_ACTIVE]
    jbe .Lhp_weights_ref
    cmp dword ptr [rbx+HP_TEMP_TYPE], 1
    jne .Lhp_weights_done
    inc edi
    xor esi, esi
    jmp .Lhp_weights_ref
.Lhp_weights_last:
    cmp esi, [rbx+HP_TEMP_ACTIVE1]
    jbe .Lhp_weights_ref
.Lhp_weights_done:
    mov eax, 1
    jmp .Lhp_weights_return
.Lhp_weights_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_weights_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN hp_weights
