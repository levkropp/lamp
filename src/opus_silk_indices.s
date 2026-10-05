# Handwritten SILK side-information and NLSF selector unpack decoding.
# RFC6716 decode_indices.c/NLSF_unpack.c. Copyright (c)2006-2012 IETF Trust
# and Skype Limited. BSD conditions in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_silk_indices_layout.inc"
RODATA
.include "opus_silk_indices_tables.inc"
.text
FN op_silk_nlsf_unpack
    push rbx
    push rsi
    push rdi
    mov rbx, rcx
    test rbx, rbx
    jz .Lsu_bad
    mov rsi, [rbx + SU_EC_IX]
    mov rdi, [rbx + SU_PRED]
    test rsi, rsi
    jz .Lsu_bad
    test rdi, rdi
    jz .Lsu_bad
    mov eax, [rbx + SU_FS]
    mov r8d, 10
    lea r9, [rip + si_select_nb]
    lea r10, [rip + si_pred_nb]
    cmp eax, 8
    je .Lsu_rate
    cmp eax, 12
    je .Lsu_rate
    cmp eax, 16
    jne .Lsu_bad
    mov r8d, 16
    lea r9, [rip + si_select_wb]
    lea r10, [rip + si_pred_wb]
.Lsu_rate:
    cmp [rbx + SU_EC_CAP], r8d
    jb .Lsu_bad
    cmp [rbx + SU_PRED_CAP], r8d
    jb .Lsu_bad
    mov eax, [rbx + SU_INDEX]
    cmp eax, 31
    ja .Lsu_bad
    imul eax, r8d
    shr eax, 1
    add r9, rax
    xor ecx, ecx
.Lsu_pair:
    movzx r11d, byte ptr [r9]
    inc r9
    mov eax, r11d
    shr eax, 1
    and eax, 7
    imul eax, 9
    mov [rsi + rcx*2], ax
    mov eax, r11d
    and eax, 1
    mov edx, r8d
    dec edx
    imul eax, edx
    add eax, ecx
    mov al, [r10 + rax]
    mov [rdi + rcx], al
    mov eax, r11d
    shr eax, 5
    imul eax, 9
    mov [rsi + rcx*2 + 2], ax
    shr r11d, 4
    and r11d, 1
    imul r11d, edx
    add r11d, ecx
    mov al, [r10 + r11 + 1]
    mov [rdi + rcx + 1], al
    add ecx, 2
    cmp ecx, r8d
    jb .Lsu_pair
    mov eax, 1
    jmp .Lsu_done
.Lsu_bad:
    xor eax, eax
.Lsu_done:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_nlsf_unpack

.equ SI_IX, 64                   # local16 signed16 selector offsets
.equ SI_PRED, 96                 # local16 predictor bytes
.equ SI_ORDER, 112
# Returns1/0. Validation before entropy/output/state changes. Component
# zero padding is normative; packet/frame layer enforces final bit budgets.
FN op_silk_indices
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 128
    mov rbx, rcx
    test rbx, rbx
    jz .Lsi_bad
    mov rsi, [rbx + SI_EC]
    mov rdi, [rbx + SI_OUT]
    mov r12, [rbx + SI_STATE]
    test rsi, rsi
    jz .Lsi_bad
    test rdi, rdi
    jz .Lsi_bad
    test r12, r12
    jz .Lsi_bad
    cmp dword ptr [rbx + SI_OUT_CAP], 36
    jb .Lsi_bad
    cmp dword ptr [rbx + SI_STATE_CAP], 8
    jb .Lsi_bad
    mov eax, [rbx + SI_FS]
    cmp eax, 8
    je .Lsi_rate
    cmp eax, 12
    je .Lsi_rate
    cmp eax, 16
    jne .Lsi_bad
.Lsi_rate:
    mov ecx, [rbx + SI_SUBFR]
    cmp ecx, 2
    je .Lsi_subfr
    cmp ecx, 4
    jne .Lsi_bad
.Lsi_subfr:
    cmp dword ptr [rbx + SI_VAD], 1
    ja .Lsi_bad
    cmp dword ptr [rbx + SI_LBRR], 1
    ja .Lsi_bad
    cmp dword ptr [rbx + SI_COND], 2
    ja .Lsi_bad
    cmp dword ptr [r12 + SS_SIGNAL], 2
    ja .Lsi_bad
    mov eax, [r12 + SS_LAG]
    cmp eax, -32768
    jl .Lsi_bad
    cmp eax, 32767
    jg .Lsi_bad
    cmp qword ptr [rsi], 0
    je .Lsi_bad
    cmp dword ptr [rsi + 8], 1275
    ja .Lsi_bad
    mov eax, [rsi + 8]
    cmp [rsi + 12], eax
    ja .Lsi_bad
    cmp [rsi + 28], eax
    ja .Lsi_bad
    cmp dword ptr [rsi + 32], 0x800000
    jbe .Lsi_bad
    cmp dword ptr [rsi + 32], 0x80000000
    ja .Lsi_bad
    mov eax, [rsi + 32]
    cmp [rsi + 36], eax
    jae .Lsi_bad
    cmp dword ptr [rsi + 20], 32
    ja .Lsi_bad
    cmp dword ptr [rsi + 24], 32768
    ja .Lsi_bad
    mov eax, [rbx + SI_VAD]
    or eax, [rbx + SI_LBRR]
    lea rdx, [rip + si_type_no_vad]
    xor r13d, r13d
    test eax, eax
    jz .Lsi_type
    lea rdx, [rip + si_type_vad]
    mov r13d, 2
.Lsi_type:
    mov rcx, rsi
    mov r8d, 8
    call op_ec_icdf
    add eax, r13d
    mov edx, eax
    shr eax, 1
    mov [rdi + SX_SIGNAL], al
    and edx, 1
    mov [rdi + SX_OFFSET], dl
    cmp dword ptr [rbx + SI_COND], 2
    jne .Lsi_gain_absolute
    mov rcx, rsi
    lea rdx, [rip + si_delta_gain]
    mov r8d, 8
    call op_ec_icdf
    mov [rdi + SX_GAINS], al
    jmp .Lsi_gain_rest
.Lsi_gain_absolute:
    movzx eax, byte ptr [rdi + SX_SIGNAL]
    lea rdx, [rip + si_gain]
    lea rdx, [rdx + rax*8]
    mov rcx, rsi
    mov r8d, 8
    call op_ec_icdf
    shl eax, 3
    mov r13d, eax
    mov rcx, rsi
    lea rdx, [rip + si_uniform8]
    mov r8d, 8
    call op_ec_icdf
    add eax, r13d
    mov [rdi + SX_GAINS], al
.Lsi_gain_rest:
    mov r13d, 1
.Lsi_gain_loop:
    mov rcx, rsi
    lea rdx, [rip + si_delta_gain]
    mov r8d, 8
    call op_ec_icdf
    mov byte ptr [rdi + r13 + SX_GAINS], al
    inc r13d
    cmp r13d, [rbx + SI_SUBFR]
    jb .Lsi_gain_loop
    lea r14, [rip + si_cb1_nb]
    lea r15, [rip + si_cb2_nb]
    mov eax, 10
    cmp dword ptr [rbx + SI_FS], 16
    jne .Lsi_codebook
    lea r14, [rip + si_cb1_wb]
    lea r15, [rip + si_cb2_wb]
    mov eax, 16
.Lsi_codebook:
    mov [rsp + SI_ORDER], eax
    movzx eax, byte ptr [rdi + SX_SIGNAL]
    shr eax, 1
    shl eax, 5
    lea rdx, [r14 + rax]
    mov rcx, rsi
    mov r8d, 8
    call op_ec_icdf
    mov [rdi + SX_NLSF], al
    mov [rsp + 32 + SU_INDEX], eax
    lea rax, [rsp + SI_IX]
    mov [rsp + 32 + SU_EC_IX], rax
    lea rax, [rsp + SI_PRED]
    mov [rsp + 32 + SU_PRED], rax
    mov eax, [rbx + SI_FS]
    mov [rsp + 32 + SU_FS], eax
    mov dword ptr [rsp + 32 + SU_EC_CAP], 16
    mov dword ptr [rsp + 32 + SU_PRED_CAP], 16
    lea rcx, [rsp + 32]
    call op_silk_nlsf_unpack
    xor r13d, r13d
.Lsi_nlsf_loop:
    movzx eax, word ptr [rsp + r13*2 + SI_IX]
    lea rdx, [r15 + rax]
    mov rcx, rsi
    mov r8d, 8
    call op_ec_icdf
    test eax, eax
    jz .Lsi_nlsf_low
    cmp eax, 8
    jne .Lsi_nlsf_store
    mov rcx, rsi
    lea rdx, [rip + si_nlsf_ext]
    mov r8d, 8
    call op_ec_icdf
    add eax, 8
    jmp .Lsi_nlsf_store
.Lsi_nlsf_low:
    mov rcx, rsi
    lea rdx, [rip + si_nlsf_ext]
    mov r8d, 8
    call op_ec_icdf
    neg eax
.Lsi_nlsf_store:
    sub eax, 4
    mov byte ptr [rdi + r13 + SX_NLSF + 1], al
    inc r13d
    cmp r13d, [rsp + SI_ORDER]
    jb .Lsi_nlsf_loop
    mov eax, 4
    cmp dword ptr [rbx + SI_SUBFR], 4
    jne .Lsi_interp_store
    mov rcx, rsi
    lea rdx, [rip + si_nlsf_interp]
    mov r8d, 8
    call op_ec_icdf
.Lsi_interp_store:
    mov [rdi + SX_INTERP], al
    cmp byte ptr [rdi + SX_SIGNAL], 2
    jne .Lsi_signal_seed
    cmp dword ptr [rbx + SI_COND], 2
    jne .Lsi_pitch_absolute
    cmp dword ptr [r12 + SS_SIGNAL], 2
    jne .Lsi_pitch_absolute
    mov rcx, rsi
    lea rdx, [rip + si_pitch_delta]
    mov r8d, 8
    call op_ec_icdf
    test eax, eax
    jz .Lsi_pitch_absolute
    sub eax, 9
    add eax, [r12 + SS_LAG]
    jmp .Lsi_pitch_store
.Lsi_pitch_absolute:
    mov rcx, rsi
    lea rdx, [rip + si_pitch_lag]
    mov r8d, 8
    call op_ec_icdf
    mov r13d, [rbx + SI_FS]
    shr r13d, 1
    imul r13d, eax
    mov rcx, rsi
    lea rdx, [rip + si_uniform4]
    cmp dword ptr [rbx + SI_FS], 8
    je .Lsi_pitch_low
    lea rdx, [rip + si_uniform6]
    cmp dword ptr [rbx + SI_FS], 12
    je .Lsi_pitch_low
    lea rdx, [rip + si_uniform8]
.Lsi_pitch_low:
    mov r8d, 8
    call op_ec_icdf
    add eax, r13d
.Lsi_pitch_store:
    mov [rdi + SX_LAG], ax
    movsx eax, ax
    mov [r12 + SS_LAG], eax
    lea rdx, [rip + si_contour]
    cmp dword ptr [rbx + SI_SUBFR], 4
    jne .Lsi_choose_contour10
    cmp dword ptr [rbx + SI_FS], 8
    jne .Lsi_contour_decode
    lea rdx, [rip + si_contour_nb]
    jmp .Lsi_contour_decode
.Lsi_choose_contour10:
    lea rdx, [rip + si_contour10]
    cmp dword ptr [rbx + SI_FS], 8
    jne .Lsi_contour_decode
    lea rdx, [rip + si_contour10_nb]
.Lsi_contour_decode:
    mov rcx, rsi
    mov r8d, 8
    call op_ec_icdf
    mov [rdi + SX_CONTOUR], al
    mov rcx, rsi
    lea rdx, [rip + si_ltp_per]
    mov r8d, 8
    call op_ec_icdf
    mov [rdi + SX_PER], al
    lea rdx, [rip + si_ltp_ptr]
    mov r14, [rdx + rax*8]
    xor r13d, r13d
.Lsi_ltp_loop:
    mov rcx, rsi
    mov rdx, r14
    mov r8d, 8
    call op_ec_icdf
    mov byte ptr [rdi + r13 + SX_LTP], al
    inc r13d
    cmp r13d, [rbx + SI_SUBFR]
    jb .Lsi_ltp_loop
    xor eax, eax
    cmp dword ptr [rbx + SI_COND], 0
    jne .Lsi_scale_store
    mov rcx, rsi
    lea rdx, [rip + si_ltp_scale]
    mov r8d, 8
    call op_ec_icdf
.Lsi_scale_store:
    mov [rdi + SX_SCALE], al
.Lsi_signal_seed:
    movzx eax, byte ptr [rdi + SX_SIGNAL]
    mov [r12 + SS_SIGNAL], eax
    mov rcx, rsi
    lea rdx, [rip + si_uniform4]
    mov r8d, 8
    call op_ec_icdf
    mov [rdi + SX_SEED], al
    mov eax, 1
    jmp .Lsi_done
.Lsi_bad:
    xor eax, eax
.Lsi_done:
    add rsp, 128
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_indices
