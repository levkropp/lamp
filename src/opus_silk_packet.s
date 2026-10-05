# SILK packet VAD/LBRR flags and redundant-frame skipping, RFC6716 dec_API.c.
# Copyright(c)2006-2012 IETF Trust/Skype Limited. BSD in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_silk_packet_layout.inc"
.include "opus_silk_frame_layout.inc"
.include "opus_silk_indices_layout.inc"
.include "opus_silk_stereo_layout.inc"
RODATA
.include "opus_silk_packet_tables.inc"
.text
FN op_silk_packet_header
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 144
    mov rbx, rcx
    test rbx, rbx
    jz .Lph_bad
    mov r12, [rbx + PH_STATE]
    mov rsi, [rbx + PH_META]
    mov rdi, [rbx + PH_EC]
    mov r13, [rbx + PH_WORK]
    test r12, r12
    jz .Lph_bad
    test rsi, rsi
    jz .Lph_bad
    test rdi, rdi
    jz .Lph_bad
    test r13, r13
    jz .Lph_bad
    cmp dword ptr [rbx + PH_FRAMES], 1
    jl .Lph_bad
    cmp dword ptr [rbx + PH_FRAMES], 3
    ja .Lph_bad
    mov eax, [rbx + PH_CHANNELS]
    cmp eax, 1
    jl .Lph_bad
    cmp eax, 2
    ja .Lph_bad
    imul eax, FN_SIZE
    cmp [rbx + PH_STATE_CAP], eax
    jb .Lph_bad
    cmp dword ptr [rbx + PH_META_CAP], PD_SIZE
    jb .Lph_bad
    cmp dword ptr [rbx + PH_EC_CAP], 64
    jb .Lph_bad
    cmp dword ptr [rbx + PH_WORK_CAP], 1280
    jb .Lph_bad
    cmp dword ptr [rbx + PH_MODE], 0
    je .Lph_state_guard_start
    cmp dword ptr [rbx + PH_MODE], 2
    jne .Lph_bad
.Lph_state_guard_start:
    mov r8, r12
    xor ecx, ecx
.Lph_state_guard:
    cmp dword ptr [r8 + FN_TAG], FN_TAG_VALUE
    jne .Lph_bad
    cmp dword ptr [r8 + FN_ERROR], 0
    jne .Lph_bad
    mov eax, [r8 + FN_FS]
    cmp eax, 8
    je .Lph_state_rate
    cmp eax, 12
    je .Lph_state_rate
    cmp eax, 16
    jne .Lph_bad
.Lph_state_rate:
    cmp [r12 + FN_FS], eax
    jne .Lph_bad
    mov eax, [r8 + FN_SUBFR]
    cmp eax, 2
    je .Lph_state_subfr
    cmp eax, 4
    jne .Lph_bad
.Lph_state_subfr:
    cmp [r12 + FN_SUBFR], eax
    jne .Lph_bad
    cmp dword ptr [rbx + PH_FRAMES], 1
    je .Lph_index_guard
    cmp eax, 4
    jne .Lph_bad
.Lph_index_guard:
    cmp dword ptr [r8 + FN_PREVIOUS + SS_SIGNAL], 2
    ja .Lph_bad
    mov eax, [r8 + FN_PREVIOUS + SS_LAG]
    cmp eax, -32768
    jl .Lph_bad
    cmp eax, 32767
    jg .Lph_bad
    add r8, FN_SIZE
    inc ecx
    cmp ecx, [rbx + PH_CHANNELS]
    jb .Lph_state_guard
    cmp qword ptr [rdi], 0
    je .Lph_bad
    cmp dword ptr [rdi + 8], 1275
    ja .Lph_bad
    mov eax, [rdi + 8]
    cmp [rdi + 12], eax
    ja .Lph_bad
    cmp [rdi + 28], eax
    ja .Lph_bad
    cmp dword ptr [rdi + 32], 0x800000
    jbe .Lph_bad
    cmp dword ptr [rdi + 32], 0x80000000
    ja .Lph_bad
    mov eax, [rdi + 32]
    cmp [rdi + 36], eax
    jae .Lph_bad
    cmp dword ptr [rdi + 20], 32
    ja .Lph_bad
    cmp dword ptr [rdi + 24], 32768
    ja .Lph_bad
    mov eax, [rbx + PH_FRAMES]
    mov [rsi + PD_FRAMES], eax
    mov eax, [rbx + PH_CHANNELS]
    mov [rsi + PD_CHANNELS], eax
    xor r15d, r15d
.Lph_vad_channel:
    xor r14d, r14d
.Lph_vad_frame:
    mov rcx, rdi
    mov edx, 1
    call op_ec_logp
    imul ecx, r15d, 3
    add ecx, r14d
    mov [rsi + rcx*4 + PD_VAD], eax
    inc r14d
    cmp r14d, [rbx + PH_FRAMES]
    jb .Lph_vad_frame
    mov rcx, rdi
    mov edx, 1
    call op_ec_logp
    mov [rsi + r15*4 + PD_FLAG], eax
    inc r15d
    cmp r15d, [rbx + PH_CHANNELS]
    jb .Lph_vad_channel
    xor r15d, r15d
.Lph_lbrr_channel:
    imul ecx, r15d, 3
    mov qword ptr [rsi + rcx*4 + PD_LBRR], 0
    mov dword ptr [rsi + rcx*4 + PD_LBRR + 8], 0
    cmp dword ptr [rsi + r15*4 + PD_FLAG], 0
    je .Lph_lbrr_next
    cmp dword ptr [rbx + PH_FRAMES], 1
    jne .Lph_lbrr_multiple
    mov dword ptr [rsi + rcx*4 + PD_LBRR], 1
    jmp .Lph_lbrr_next
.Lph_lbrr_multiple:
    lea rdx, [rip + ph_lbrr2]
    cmp dword ptr [rbx + PH_FRAMES], 2
    je .Lph_lbrr_decode
    lea rdx, [rip + ph_lbrr3]
.Lph_lbrr_decode:
    mov rcx, rdi
    mov r8d, 8
    call op_ec_icdf
    inc eax
    imul r8d, r15d, 3
    xor ecx, ecx
.Lph_lbrr_bit:
    mov edx, eax
    shr edx, cl
    and edx, 1
    lea r9d, [r8 + rcx]
    mov [rsi + r9*4 + PD_LBRR], edx
    inc ecx
    cmp ecx, [rbx + PH_FRAMES]
    jb .Lph_lbrr_bit
.Lph_lbrr_next:
    inc r15d
    cmp r15d, [rbx + PH_CHANNELS]
    jb .Lph_lbrr_channel
    cmp dword ptr [rbx + PH_MODE], 2
    je .Lph_good
    xor r14d, r14d
.Lph_skip_frame:
    xor r15d, r15d
.Lph_skip_channel:
    imul eax, r15d, 3
    add eax, r14d
    cmp dword ptr [rsi + rax*4 + PD_LBRR], 0
    je .Lph_skip_next
    cmp dword ptr [rbx + PH_CHANNELS], 2
    jne .Lph_skip_indices
    test r15d, r15d
    jnz .Lph_skip_indices
    mov [rsp + 32 + ST_EC], rdi
    lea rax, [rsp + 128]
    mov [rsp + 32 + ST_OUT], rax
    mov dword ptr [rsp + 32 + ST_KIND], 0
    mov dword ptr [rsp + 32 + ST_OUT_CAP], 2
    mov dword ptr [rsp + 32 + ST_EC_CAP], 64
    lea rcx, [rsp + 32]
    call op_silk_stereo_indices
    test eax, eax
    jz .Lph_failed
    cmp dword ptr [rsi + r14*4 + PD_LBRR + 12], 0
    jne .Lph_skip_indices
    mov dword ptr [rsp + 32 + ST_KIND], 1
    mov dword ptr [rsp + 32 + ST_OUT_CAP], 1
    lea rcx, [rsp + 32]
    call op_silk_stereo_indices
    test eax, eax
    jz .Lph_failed
.Lph_skip_indices:
    imul eax, r15d, FN_SIZE
    lea r8, [r12 + rax]
    mov [rsp + 136], r8             #current channel state
    mov [rsp + 32 + SI_EC], rdi
    lea rax, [r8 + FN_PREVIOUS]
    mov [rsp + 32 + SI_STATE], rax
    lea rax, [r8 + FN_IND]
    mov [rsp + 32 + SI_OUT], rax
    mov eax, [r8 + FN_FS]
    mov [rsp + 32 + SI_FS], eax
    mov eax, [r8 + FN_SUBFR]
    mov [rsp + 32 + SI_SUBFR], eax
    mov dword ptr [rsp + 32 + SI_VAD], 0
    mov dword ptr [rsp + 32 + SI_LBRR], 1
    xor eax, eax
    test r14d, r14d
    jz .Lph_skip_conditional
    imul ecx, r15d, 3
    add ecx, r14d
    cmp dword ptr [rsi + rcx*4 + PD_LBRR - 4], 0
    je .Lph_skip_conditional
    mov eax, 2
.Lph_skip_conditional:
    mov [rsp + 32 + SI_COND], eax
    mov dword ptr [rsp + 32 + SI_OUT_CAP], 36
    mov dword ptr [rsp + 32 + SI_STATE_CAP], 8
    lea rcx, [rsp + 32]
    call op_silk_indices
    test eax, eax
    jz .Lph_failed
    mov r8, [rsp + 136]
    mov eax, [r8 + FN_FS]
    imul eax, [r8 + FN_SUBFR]
    imul eax, 5
    mov [rsp + 32], eax
    mov rcx, rdi
    mov rdx, r13
    movzx r9d, byte ptr [r8 + FN_IND + SX_OFFSET]
    movzx r8d, byte ptr [r8 + FN_IND + SX_SIGNAL]
    call op_silk_pulses
    test eax, eax
    jz .Lph_failed
.Lph_skip_next:
    inc r15d
    cmp r15d, [rbx + PH_CHANNELS]
    jb .Lph_skip_channel
    inc r14d
    cmp r14d, [rbx + PH_FRAMES]
    jb .Lph_skip_frame
.Lph_good:
    mov eax, 1
    jmp .Lph_done
.Lph_failed:
    xor ecx, ecx
    mov r8, r12
.Lph_mark_failure:
    mov dword ptr [r8 + FN_ERROR], 1
    add r8, FN_SIZE
    inc ecx
    cmp ecx, [rbx + PH_CHANNELS]
    jb .Lph_mark_failure
.Lph_bad:
    xor eax, eax
.Lph_done:
    add rsp, 144
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_packet_header
