# Handwritten SILK loss concealment/recovery from RFC6716 PLC.c,
# sum_sqr_shift.c. Copyright(c)2006-2012 IETF Trust and Skype Limited.
# BSD conditions in THIRD_PARTY_NOTICES. Caller-owned history/workspace.
.include "lamp.inc"
.include "opus_silk_plc_layout.inc"
.include "opus_silk_synthesis_layout.inc"
.include "opus_silk_state_layout.inc"
.include "opus_silk_indices_layout.inc"
.include "opus_silk_lpc_layout.inc"
.include "opus_silk_prediction_layout.inc"
.text
# Internal energy kernel: RCX=int16 input, EDX=0..480; EAX=energy,
# EDX=shift. Preserves nonvolatile registers. The first overflowing
# pair is reprocessed by the second loop, exactly as the reference.
LOCALFN pl_energy
    mov r8, rcx
    lea r9d, [rdx - 1]
    xor r10d, r10d
    xor r11d, r11d
    xor eax, eax
.Lpe_unscaled:
    cmp r10d, r9d
    jge .Lpe_tail
    movsx edx, word ptr [r8 + r10*2]
    imul edx, edx
    add eax, edx
    movsx edx, word ptr [r8 + r10*2 + 2]
    imul edx, edx
    add eax, edx
    test eax, eax
    js .Lpe_first_overflow
    add r10d, 2
    jmp .Lpe_unscaled
.Lpe_first_overflow:
    shr eax, 2
    mov r11d, 2
.Lpe_scaled:
    cmp r10d, r9d
    jge .Lpe_tail
    movsx edx, word ptr [r8 + r10*2]
    imul edx, edx
    movsx ecx, word ptr [r8 + r10*2 + 2]
    imul ecx, ecx
    add edx, ecx
    mov ecx, r11d
    shr edx, cl
    add eax, edx
    test eax, eax
    jns .Lpe_scaled_next
    shr eax, 2
    add r11d, 2
.Lpe_scaled_next:
    add r10d, 2
    jmp .Lpe_scaled
.Lpe_tail:
    cmp r10d, r9d
    jne .Lpe_headroom
    movsx edx, word ptr [r8 + r10*2]
    imul edx, edx
    mov ecx, r11d
    shr edx, cl
    add eax, edx
.Lpe_headroom:
    test eax, 0xc0000000
    jz .Lpe_return
    shr eax, 2
    add r11d, 2
.Lpe_return:
    mov edx, r11d
    ret
ENDFN pl_energy
FN op_silk_sum_sqr
    push rbx
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lpe_bad
    cmp qword ptr [rbx + PE_ENERGY], 0
    je .Lpe_bad
    cmp qword ptr [rbx + PE_SHIFT], 0
    je .Lpe_bad
    mov rcx, [rbx + PE_IN]
    test rcx, rcx
    jz .Lpe_bad
    mov edx, [rbx + PE_N]
    cmp edx, 480
    ja .Lpe_bad
    cmp [rbx + PE_IN_CAP], edx
    jb .Lpe_bad
    call pl_energy
    mov rcx, [rbx + PE_ENERGY]
    mov [rcx], eax
    mov rcx, [rbx + PE_SHIFT]
    mov [rcx], edx
    mov eax, 1
    jmp .Lpe_done
.Lpe_bad:
    xor eax, eax
.Lpe_done:
    add rsp, 32
    pop rbx
    ret
ENDFN op_silk_sum_sqr
FN op_silk_plc_glue
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    test rbx, rbx
    jz .Lpg_bad
    mov rsi, [rbx + PG_STATE]
    mov rdi, [rbx + PG_PCM]
    test rsi, rsi
    jz .Lpg_bad
    test rdi, rdi
    jz .Lpg_bad
    cmp dword ptr [rbx + PG_STATE_CAP], PN_SIZE
    jb .Lpg_bad
    mov r12d, [rbx + PG_N]
    cmp r12d, 1
    jl .Lpg_bad
    cmp r12d, 320
    ja .Lpg_bad
    cmp [rbx + PG_PCM_CAP], r12d
    jb .Lpg_bad
    cmp dword ptr [rbx + PG_LOSS], 0
    jl .Lpg_bad
    jne .Lpg_lost
    cmp dword ptr [rsi + PN_LAST], 1
    ja .Lpg_bad
    je .Lpg_recover
    jmp .Lpg_clear
.Lpg_recover:
    cmp dword ptr [rsi + PN_ENERGY], 0
    jl .Lpg_bad
    cmp dword ptr [rsi + PN_SHIFT], 31
    ja .Lpg_bad
    mov rcx, rdi
    mov edx, r12d
    call pl_energy
    mov ecx, edx
    sub ecx, [rsi + PN_SHIFT]
    jle .Lpg_shift_decoded
    sar dword ptr [rsi + PN_ENERGY], cl
    jmp .Lpg_energy_compare
.Lpg_shift_decoded:
    neg ecx
    sar eax, cl
.Lpg_energy_compare:
    cmp eax, [rsi + PN_ENERGY]
    jle .Lpg_clear
    mov r13d, eax
    mov eax, [rsi + PN_ENERGY]
    test eax, eax
    jz .Lpg_zero_energy
    bsr ecx, eax
    mov edx, 30
    sub edx, ecx
    jmp .Lpg_normalize
.Lpg_zero_energy:
    mov edx, 31
.Lpg_normalize:
    mov ecx, edx
    shl eax, cl
    mov [rsi + PN_ENERGY], eax
    mov ecx, 24
    sub ecx, edx
    jns .Lpg_normalize_shift
    xor ecx, ecx
.Lpg_normalize_shift:
    sar r13d, cl
    mov ecx, 1
    test r13d, r13d
    cmovle r13d, ecx
    cdq
    idiv r13d
    mov ecx, eax
    call op_silk_sqrt_approx
    shl eax, 4
    mov r13d, eax                 #Q16 fade gain
    mov eax, 65536
    sub eax, r13d
    cdq
    idiv r12d
    shl eax, 2
    mov r12d, eax                 #Q16 fade slope
    xor r8d, r8d
.Lpg_fade:
    movsx rax, word ptr [rdi + r8*2]
    movsxd rcx, r13d
    imul rax, rcx
    sar rax, 16
    mov [rdi + r8*2], ax
    add r13d, r12d
    cmp r13d, 65536
    jg .Lpg_clear
    inc r8d
    cmp r8d, [rbx + PG_N]
    jb .Lpg_fade
.Lpg_clear:
    mov dword ptr [rsi + PN_LAST], 0
    jmp .Lpg_good
.Lpg_lost:
    mov rcx, rdi
    mov edx, r12d
    call pl_energy
    mov [rsi + PN_ENERGY], eax
    mov [rsi + PN_SHIFT], edx
    mov dword ptr [rsi + PN_LAST], 1
.Lpg_good:
    mov eax, 1
    jmp .Lpg_done
.Lpg_bad:
    xor eax, eax
.Lpg_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_plc_glue
FN op_silk_plc
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160
    mov rbx, rcx
    test rbx, rbx
    jz .Lpl_bad
    mov rsi, [rbx + PL_STATE]
    mov rdi, [rbx + PL_CORE]
    mov r12, [rbx + PL_CTRL]
    mov r13, [rbx + PL_PCM]
    mov r14, [rbx + PL_WORK]
    test rsi, rsi
    jz .Lpl_bad
    test rdi, rdi
    jz .Lpl_bad
    test r12, r12
    jz .Lpl_bad
    test r13, r13
    jz .Lpl_bad
    test r14, r14
    jz .Lpl_bad
    cmp qword ptr [rbx + PL_PARAM], 0
    je .Lpl_bad
    cmp qword ptr [rbx + PL_IND], 0
    je .Lpl_bad
    cmp dword ptr [rbx + PL_STATE_CAP], PN_SIZE
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_CORE_CAP], CS_SIZE
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_PARAM_CAP], DS_SIZE
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_CTRL_CAP], DC_SIZE
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_IND_CAP], 36
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_WORK_CAP], PW_SIZE
    jb .Lpl_bad
    mov eax, [rbx + PL_FS]
    mov r15d, 10
    cmp eax, 8
    je .Lpl_rate
    cmp eax, 12
    je .Lpl_rate
    cmp eax, 16
    jne .Lpl_bad
    mov r15d, 16
.Lpl_rate:
    imul ecx, eax, 5
    mov [rsp + 84], ecx             #current subframe samples
    imul eax, eax, 20
    mov [rsp + 92], eax             #LTP memory samples
    mov edx, [rbx + PL_SUBFR]
    cmp edx, 2
    je .Lpl_subfr
    cmp edx, 4
    jne .Lpl_bad
.Lpl_subfr:
    imul ecx, edx
    mov [rsp + 88], ecx             #frame samples
    cmp [rbx + PL_PCM_CAP], ecx
    jb .Lpl_bad
    cmp dword ptr [rbx + PL_LOST], 1
    ja .Lpl_bad
    cmp dword ptr [rdi + CS_LOSS], 0
    jl .Lpl_bad
    cmp dword ptr [rbx + PL_LOST], 0
    je .Lpl_update_guard
    cmp dword ptr [rdi + CS_LOSS], 0x7fffffff
    je .Lpl_bad
    cmp dword ptr [rdi + CS_SIGNAL], 2
    ja .Lpl_bad
    mov r8, [rbx + PL_PARAM]
    cmp dword ptr [r8 + DS_FIRST], 1
    ja .Lpl_bad
    mov eax, [rbx + PL_FS]
    cmp eax, [rsi + PN_FS]
    jne .Lpl_reset_guard
    cmp dword ptr [rsi + PN_GAINS], 0
    jle .Lpl_bad
    cmp dword ptr [rsi + PN_GAINS + 4], 0
    jle .Lpl_bad
    mov ecx, [rsi + PN_SUBLEN]
    cmp ecx, 1
    jl .Lpl_bad
    cmp ecx, 80
    ja .Lpl_bad
    mov edx, [rsi + PN_SUBFR]
    cmp edx, 2
    je .Lpl_previous_subfr
    cmp edx, 4
    jne .Lpl_bad
.Lpl_previous_subfr:
    imul ecx, edx
    cmp ecx, 320
    ja .Lpl_bad
    mov ecx, [rsi + PN_PITCH]
    cmp ecx, 0
    jle .Lpl_bad
    sar ecx, 7
    inc ecx
    sar ecx, 1
    jmp .Lpl_pitch_guard
.Lpl_reset_guard:
    mov ecx, [rsp + 88]
    shr ecx, 1
.Lpl_pitch_guard:
    imul edx, dword ptr [rbx + PL_FS], 2
    cmp ecx, edx
    jl .Lpl_bad
    imul edx, dword ptr [rbx + PL_FS], 18
    cmp ecx, edx
    jg .Lpl_bad
    mov edx, [rsp + 92]
    sub edx, ecx
    sub edx, r15d
    sub edx, 2
    jle .Lpl_bad
    cmp dword ptr [rdi + CS_LOSS], 0
    jne .Lpl_reset_check
    cmp dword ptr [rdi + CS_SIGNAL], 2
    jne .Lpl_reset_check
    cmp word ptr [rsi + PN_LTP_SCALE], 16384
    ja .Lpl_bad
    jmp .Lpl_reset_check
.Lpl_update_guard:
    mov r8, [rbx + PL_IND]
    cmp byte ptr [r8 + SX_SIGNAL], 2
    ja .Lpl_bad
    mov ecx, [rbx + PL_SUBFR]
    sub ecx, 2
    cmp dword ptr [r12 + rcx*4 + DC_GAINS], 0
    jle .Lpl_bad
    cmp dword ptr [r12 + rcx*4 + DC_GAINS + 4], 0
    jle .Lpl_bad
    cmp dword ptr [r12 + DC_SCALE], 16384
    ja .Lpl_bad
    cmp byte ptr [r8 + SX_SIGNAL], 2
    jne .Lpl_reset_check
    xor ecx, ecx
    imul r8d, dword ptr [rbx + PL_FS], 2
    imul r9d, dword ptr [rbx + PL_FS], 18
.Lpl_control_pitch_guard:
    mov eax, [r12 + rcx*4 + DC_PITCH]
    cmp eax, r8d
    jl .Lpl_bad
    cmp eax, r9d
    jg .Lpl_bad
    inc ecx
    cmp ecx, [rbx + PL_SUBFR]
    jb .Lpl_control_pitch_guard
.Lpl_reset_check:
    mov eax, [rbx + PL_FS]
    cmp eax, [rsi + PN_FS]
    je .Lpl_mode
    mov [rsi + PN_FS], eax
    mov eax, [rsp + 88]
    shl eax, 7
    mov [rsi + PN_PITCH], eax
    mov dword ptr [rsi + PN_GAINS], 65536
    mov dword ptr [rsi + PN_GAINS + 4], 65536
    mov dword ptr [rsi + PN_SUBLEN], 20
    mov dword ptr [rsi + PN_SUBFR], 2
.Lpl_mode:
    cmp dword ptr [rbx + PL_LOST], 0
    jne .Lpl_conceal
    mov r8, [rbx + PL_IND]
    movzx eax, byte ptr [r8 + SX_SIGNAL]
    mov [rdi + CS_SIGNAL], eax
    cmp eax, 2
    jne .Lpl_unvoiced_update
    xor r10d, r10d               #best LTP gain
    xor r11d, r11d               #backward subframe number
    mov ecx, [rbx + PL_SUBFR]
    dec ecx
    mov r9d, [r12 + rcx*4 + DC_PITCH]
.Lpl_find_pitch:
    cmp r11d, [rbx + PL_SUBFR]
    jae .Lpl_update_taps
    mov eax, r11d
    imul eax, [rsp + 84]
    cmp eax, r9d
    jge .Lpl_update_taps
    mov ecx, [rbx + PL_SUBFR]
    dec ecx
    sub ecx, r11d
    imul edx, ecx, 5
    xor eax, eax
    movsx r8d, word ptr [r12 + rdx*2 + DC_LTP]
    add eax, r8d
    movsx r8d, word ptr [r12 + rdx*2 + DC_LTP + 2]
    add eax, r8d
    movsx r8d, word ptr [r12 + rdx*2 + DC_LTP + 4]
    add eax, r8d
    movsx r8d, word ptr [r12 + rdx*2 + DC_LTP + 6]
    add eax, r8d
    movsx r8d, word ptr [r12 + rdx*2 + DC_LTP + 8]
    add eax, r8d
    cmp eax, r10d
    jle .Lpl_find_next
    mov r10d, eax
    mov eax, [r12 + rcx*4 + DC_PITCH]
    shl eax, 8
    mov [rsi + PN_PITCH], eax
.Lpl_find_next:
    inc r11d
    jmp .Lpl_find_pitch
.Lpl_update_taps:
    mov qword ptr [rsi + PN_LTP], 0
    mov word ptr [rsi + PN_LTP + 8], 0
    mov [rsi + PN_LTP + 4], r10w
    cmp r10d, 11469
    jge .Lpl_limit_high_gain
    mov ecx, 1
    cmp r10d, ecx
    cmovg ecx, r10d
    mov eax, 11744256             #11469<<10
    xor edx, edx
    div ecx
    movsx eax, ax
    movsx ecx, word ptr [rsi + PN_LTP + 4]
    imul eax, ecx
    sar eax, 10
    mov [rsi + PN_LTP + 4], ax
    jmp .Lpl_save_update
.Lpl_limit_high_gain:
    cmp r10d, 15565
    jle .Lpl_save_update
    mov eax, 255016960            #15565<<14
    xor edx, edx
    div r10d
    movsx eax, ax
    movsx ecx, word ptr [rsi + PN_LTP + 4]
    imul eax, ecx
    sar eax, 14
    mov [rsi + PN_LTP + 4], ax
    jmp .Lpl_save_update
.Lpl_unvoiced_update:
    imul eax, dword ptr [rbx + PL_FS], 18
    shl eax, 8
    mov [rsi + PN_PITCH], eax
    mov qword ptr [rsi + PN_LTP], 0
    mov word ptr [rsi + PN_LTP + 8], 0
.Lpl_save_update:
    xor ecx, ecx
.Lpl_save_coefficients:
    mov ax, [r12 + rcx*2 + DC_PRED + 32]
    mov [rsi + rcx*2 + PN_LPC], ax
    inc ecx
    cmp ecx, r15d
    jb .Lpl_save_coefficients
    mov eax, [r12 + DC_SCALE]
    mov [rsi + PN_LTP_SCALE], ax
    mov ecx, [rbx + PL_SUBFR]
    mov [rsi + PN_SUBFR], ecx
    sub ecx, 2
    mov rax, [r12 + rcx*4 + DC_GAINS]
    mov [rsi + PN_GAINS], rax
    mov eax, [rsp + 84]
    mov [rsi + PN_SUBLEN], eax
    jmp .Lpl_good
.Lpl_conceal:
    mov eax, [rsi + PN_GAINS]
    sar eax, 6
    mov [rsp + 140], eax
    mov eax, [rsi + PN_GAINS + 4]
    sar eax, 6
    mov [rsp + 144], eax
    mov r8, [rbx + PL_PARAM]
    cmp dword ptr [r8 + DS_FIRST], 0
    je .Lpl_scale_excitation
    mov qword ptr [rsi + PN_LPC], 0
    mov qword ptr [rsi + PN_LPC + 8], 0
    mov qword ptr [rsi + PN_LPC + 16], 0
    mov qword ptr [rsi + PN_LPC + 24], 0
.Lpl_scale_excitation:
    mov ecx, [rsi + PN_SUBFR]
    sub ecx, 2
    imul ecx, [rsi + PN_SUBLEN]
    lea r8, [rdi + rcx*4 + CS_EXC]
    lea r9, [r14 + PW_EXC]
    xor r10d, r10d
.Lpl_excitation_subframe:
    movsxd r11, dword ptr [rsp + r10*4 + 140]
    xor ecx, ecx
.Lpl_excitation_sample:
    movsxd rax, dword ptr [r8 + rcx*4]
    imul rax, r11
    sar rax, 16
    sar eax, 8
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [r9 + rcx*2], ax
    inc ecx
    cmp ecx, [rsi + PN_SUBLEN]
    jb .Lpl_excitation_sample
    lea r8, [r8 + rcx*4]
    lea r9, [r9 + rcx*2]
    inc r10d
    cmp r10d, 2
    jb .Lpl_excitation_subframe
    lea rcx, [r14 + PW_EXC]
    mov edx, [rsi + PN_SUBLEN]
    call pl_energy
    mov [rsp + 120], eax
    mov [rsp + 124], edx
    mov ecx, [rsi + PN_SUBLEN]
    lea rcx, [r14 + rcx*2 + PW_EXC]
    mov edx, [rsi + PN_SUBLEN]
    call pl_energy
    mov [rsp + 128], eax
    mov [rsp + 132], edx
    mov ecx, edx
    mov edx, [rsp + 120]
    sar edx, cl
    mov ecx, [rsp + 124]
    sar eax, cl
    mov ecx, [rsi + PN_SUBFR]
    cmp edx, eax
    jge .Lpl_random_last
    dec ecx
.Lpl_random_last:
    imul ecx, [rsi + PN_SUBLEN]
    sub ecx, 128
    xor eax, eax
    test ecx, ecx
    cmovl ecx, eax
    mov [rsp + 96], ecx             #excitation random-window start
    movsx eax, word ptr [rsi + PN_SCALE]
    mov [rsp + 108], eax            #random Q14 scale
    mov ecx, [rdi + CS_LOSS]
    test ecx, ecx
    mov eax, 32440
    mov edx, 31130
    cmovnz eax, edx
    mov [rsp + 104], eax            #harmonic Q15 attenuation
    cmp dword ptr [rdi + CS_SIGNAL], 2
    jne .Lpl_unvoiced_attenuation
    mov eax, 31130
    mov edx, 26214
    jmp .Lpl_choose_attenuation
.Lpl_unvoiced_attenuation:
    mov eax, 32440
    mov edx, 29491
.Lpl_choose_attenuation:
    test ecx, ecx
    cmovnz eax, edx
    mov [rsp + 100], eax            #random Q15 attenuation
    lea rax, [rsi + PN_LPC]
    mov [rsp + 32 + SB_AR], rax
    mov [rsp + 32 + SB_ORDER], r15d
    mov dword ptr [rsp + 32 + SB_CHIRP], 64881
    mov [rsp + 32 + SB_CAP], r15d
    mov dword ptr [rsp + 32 + SB_WIDTH], 16
    lea rcx, [rsp + 32]
    call op_silk_bwexpand
    xor ecx, ecx
.Lpl_copy_coefficients:
    mov ax, [rsi + rcx*2 + PN_LPC]
    mov [r14 + rcx*2 + PW_COEF], ax
    inc ecx
    cmp ecx, r15d
    jb .Lpl_copy_coefficients
    cmp dword ptr [rdi + CS_LOSS], 0
    jne .Lpl_rewhite
    mov dword ptr [rsp + 108], 16384
    cmp dword ptr [rdi + CS_SIGNAL], 2
    jne .Lpl_unvoiced_first
    xor ecx, ecx
    mov eax, 16384
.Lpl_initial_random_scale:
    sub ax, [rsi + rcx*2 + PN_LTP]
    inc ecx
    cmp ecx, 5
    jb .Lpl_initial_random_scale
    movsx eax, ax
    mov edx, 3277
    cmp eax, edx
    cmovl eax, edx
    movsx edx, word ptr [rsi + PN_LTP_SCALE]
    imul eax, edx
    sar eax, 14
    movsx eax, ax
    mov [rsp + 108], eax
    jmp .Lpl_rewhite
.Lpl_unvoiced_first:
    lea rax, [rsi + PN_LPC]
    mov [rsp + 32 + SL_AR], rax
    mov [rsp + 32 + SL_ORDER], r15d
    mov [rsp + 32 + SL_CAP], r15d
    lea rcx, [rsp + 32]
    call op_silk_lpc_inverse
    mov ecx, 134217728
    cmp eax, ecx
    cmovg eax, ecx
    mov ecx, 4194304
    cmp eax, ecx
    cmovl eax, ecx
    shl eax, 3
    movsxd rax, eax
    movsx rcx, word ptr [rsp + 100]
    imul rax, rcx
    sar rax, 16
    sar eax, 14
    mov [rsp + 100], eax
.Lpl_rewhite:
    mov eax, [rsi + PN_RNG]
    mov [rsp + 112], eax
    mov eax, [rsi + PN_PITCH]
    sar eax, 7
    inc eax
    sar eax, 1
    mov [rsp + 116], eax            #current integer lag
    mov ecx, [rsp + 92]
    sub ecx, eax
    sub ecx, r15d
    sub ecx, 2
    mov [rsp + 136], ecx            #rewhitening start index
    lea rax, [r14 + rcx*2 + PW_LTP]
    mov [rsp + 32 + SF_OUT], rax
    lea rax, [rdi + rcx*2 + CS_OUT]
    mov [rsp + 32 + SF_IN], rax
    lea rax, [r14 + PW_COEF]
    mov [rsp + 32 + SF_COEF], rax
    mov eax, [rsp + 92]
    sub eax, ecx
    mov [rsp + 32 + SF_N], eax
    mov [rsp + 32 + SF_ORDER], r15d
    mov [rsp + 32 + SF_OUT_CAP], eax
    mov [rsp + 32 + SF_IN_CAP], eax
    mov [rsp + 32 + SF_COEF_CAP], r15d
    lea rcx, [rsp + 32]
    call op_silk_analysis_filter
    mov ecx, [rsi + PN_GAINS + 4]
    mov edx, 46
    call op_silk_inverse32
    mov ecx, 0x3fffffff
    cmp eax, ecx
    cmovg eax, ecx
    movsxd r8, eax
    mov ecx, [rsp + 136]
    add ecx, r15d
.Lpl_scale_rewhitened:
    movsx rax, word ptr [r14 + rcx*2 + PW_LTP]
    imul rax, r8
    sar rax, 16
    mov [r14 + rcx*4 + PW_Q14], eax
    inc ecx
    cmp ecx, [rsp + 92]
    jb .Lpl_scale_rewhitened
    mov dword ptr [rsp + 148], 0
    mov r10d, [rsp + 92]            #Q14 write position
    mov r11d, [rsp + 112]           #random seed
.Lpl_ltp_subframe:
    mov r9d, r10d
    sub r9d, [rsp + 116]
    add r9d, 2
    xor r8d, r8d
.Lpl_ltp_sample:
    mov edx, 2
    xor ecx, ecx
.Lpl_ltp_tap:
    mov eax, r9d
    sub eax, ecx
    movsxd rax, dword ptr [r14 + rax*4 + PW_Q14]
    movsx r11, word ptr [rsi + rcx*2 + PN_LTP]
    imul rax, r11
    sar rax, 16
    add edx, eax
    inc ecx
    cmp ecx, 5
    jb .Lpl_ltp_tap
    mov r11d, [rsp + 112]
    imul r11d, r11d, 196314165
    add r11d, 907633515
    mov [rsp + 112], r11d
    mov eax, r11d
    sar eax, 25
    and eax, 127
    add eax, [rsp + 96]
    movsxd rax, dword ptr [rdi + rax*4 + CS_EXC]
    movsxd r11, dword ptr [rsp + 108]
    imul rax, r11
    sar rax, 16
    add edx, eax
    shl edx, 2
    mov [r14 + r10*4 + PW_Q14], edx
    inc r9d
    inc r10d
    inc r8d
    cmp r8d, [rsp + 84]
    jb .Lpl_ltp_sample
    xor ecx, ecx
.Lpl_attenuate_harmonic:
    movsx eax, word ptr [rsi + rcx*2 + PN_LTP]
    imul eax, [rsp + 104]
    sar eax, 15
    mov [rsi + rcx*2 + PN_LTP], ax
    inc ecx
    cmp ecx, 5
    jb .Lpl_attenuate_harmonic
    mov eax, [rsp + 108]
    imul eax, [rsp + 100]
    sar eax, 15
    movsx eax, ax
    mov [rsp + 108], eax
    movsxd rax, dword ptr [rsi + PN_PITCH]
    imul rax, 655
    sar rax, 16
    add eax, [rsi + PN_PITCH]
    imul edx, dword ptr [rbx + PL_FS], 18*256
    cmp eax, edx
    cmovg eax, edx
    mov [rsi + PN_PITCH], eax
    sar eax, 7
    inc eax
    sar eax, 1
    mov [rsp + 116], eax
    inc dword ptr [rsp + 148]
    mov ecx, [rsp + 148]
    cmp ecx, [rbx + PL_SUBFR]
    jb .Lpl_ltp_subframe
    mov eax, [rsp + 92]
    sub eax, 16
    lea r9, [r14 + rax*4 + PW_Q14]
    xor ecx, ecx
.Lpl_copy_lpc_history:
    mov eax, [rdi + rcx*4 + CS_LPC]
    mov [r9 + rcx*4], eax
    inc ecx
    cmp ecx, 16
    jb .Lpl_copy_lpc_history
    movsxd r10, dword ptr [rsp + 144]
    xor r8d, r8d
.Lpl_lpc_sample:
    mov r11d, r15d
    shr r11d, 1
    xor ecx, ecx
.Lpl_lpc_tap:
    lea edx, [r8 + 15]
    sub edx, ecx
    movsxd rax, dword ptr [r9 + rdx*4]
    movsx rdx, word ptr [r14 + rcx*2 + PW_COEF]
    imul rax, rdx
    sar rax, 16
    add r11d, eax
    inc ecx
    cmp ecx, r15d
    jb .Lpl_lpc_tap
    mov eax, r11d
    shl eax, 4
    add eax, [r9 + r8*4 + 64]
    mov [r9 + r8*4 + 64], eax
    movsxd rax, eax
    imul rax, r10
    sar rax, 16
    sar eax, 7
    inc eax
    sar eax, 1
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov [r13 + r8*2], ax
    inc r8d
    cmp r8d, [rsp + 88]
    jb .Lpl_lpc_sample
    mov r8d, [rsp + 88]
    xor ecx, ecx
.Lpl_save_lpc_history:
    mov eax, [r9 + r8*4]
    mov [rdi + rcx*4 + CS_LPC], eax
    inc r8d
    inc ecx
    cmp ecx, 16
    jb .Lpl_save_lpc_history
    mov eax, [rsp + 112]
    mov [rsi + PN_RNG], eax
    mov eax, [rsp + 108]
    mov [rsi + PN_SCALE], ax
    mov eax, [rsp + 116]
    mov [r12 + DC_PITCH], eax
    mov [r12 + DC_PITCH + 4], eax
    mov [r12 + DC_PITCH + 8], eax
    mov [r12 + DC_PITCH + 12], eax
    inc dword ptr [rdi + CS_LOSS]
.Lpl_good:
    mov eax, 1
    jmp .Lpl_done
.Lpl_bad:
    xor eax, eax
.Lpl_done:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_plc
