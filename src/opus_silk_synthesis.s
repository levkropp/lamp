# Handwritten SILK inverse-NSQ: excitation, LTP/LPC prediction and PCM.
# RFC6716 decode_core.c. Copyright(c)2006-2012 IETF Trust and Skype
# Limited. BSD conditions in THIRD_PARTY_NOTICES. Caller-owned scratch.
.include "lamp.inc"
.include "opus_silk_synthesis_layout.inc"
.include "opus_silk_state_layout.inc"
.include "opus_silk_indices_layout.inc"
.include "opus_silk_prediction_layout.inc"
RODATA
sc_offsets: .short 100, 240, 32, 100     #normative Q10 unvoiced/voiced offsets
.text
FN op_silk_synthesis
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 192
    mov rbx, rcx
    test rbx, rbx
    jz .Lsc_bad
    mov rsi, [rbx + SC_STATE]
    mov rdi, [rbx + SC_CTRL]
    mov r12, [rbx + SC_WORK]
    mov r13, [rbx + SC_PCM]
    mov r14, [rbx + SC_PULSES]
    mov r15, [rbx + SC_IND]
    test rsi, rsi
    jz .Lsc_bad
    test rdi, rdi
    jz .Lsc_bad
    test r12, r12
    jz .Lsc_bad
    test r13, r13
    jz .Lsc_bad
    test r14, r14
    jz .Lsc_bad
    test r15, r15
    jz .Lsc_bad
    cmp dword ptr [rbx + SC_STATE_CAP], CS_SIZE
    jb .Lsc_bad
    cmp dword ptr [rbx + SC_CTRL_CAP], DC_SIZE
    jb .Lsc_bad
    cmp dword ptr [rbx + SC_WORK_CAP], SW_SIZE
    jb .Lsc_bad
    cmp dword ptr [rbx + SC_IND_CAP], 36
    jb .Lsc_bad
    mov eax, [rbx + SC_FS]
    mov ecx, 10
    cmp eax, 8
    je .Lsc_rate
    cmp eax, 12
    je .Lsc_rate
    cmp eax, 16
    jne .Lsc_bad
    mov ecx, 16
.Lsc_rate:
    mov [rsp + 120], ecx          #LPC order
    imul ecx, eax, 5
    mov [rsp + 108], ecx          #subframe length
    imul edx, eax, 20
    mov [rsp + 112], edx          #LTP memory
    mov [rsp + 100], edx          #LTP write index
    mov r8d, [rbx + SC_SUBFR]
    cmp r8d, 2
    je .Lsc_subfr
    cmp r8d, 4
    jne .Lsc_bad
.Lsc_subfr:
    imul ecx, r8d
    mov [rsp + 116], ecx          #frame length
    cmp [rbx + SC_PULSE_CAP], ecx
    jb .Lsc_bad
    cmp [rbx + SC_PCM_CAP], ecx
    jb .Lsc_bad
    cmp dword ptr [rsi + CS_GAIN], 0
    jle .Lsc_bad
    cmp dword ptr [rsi + CS_SIGNAL], 2
    ja .Lsc_bad
    cmp dword ptr [rsi + CS_LOSS], 0
    jl .Lsc_bad
    cmp byte ptr [r15 + SX_SIGNAL], 2
    ja .Lsc_bad
    cmp byte ptr [r15 + SX_OFFSET], 1
    ja .Lsc_bad
    cmp byte ptr [r15 + SX_INTERP], 4
    ja .Lsc_bad
    cmp byte ptr [r15 + SX_SEED], 3
    ja .Lsc_bad
    cmp dword ptr [rdi + DC_SCALE], 16384
    ja .Lsc_bad
    movzx eax, byte ptr [r15 + SX_INTERP]
    cmp eax, 4
    setb al
    movzx eax, al
    mov [rsp + 104], eax
    movzx eax, byte ptr [r15 + SX_SIGNAL]
    cmp eax, 2
    je .Lsc_voiced_guard
    cmp dword ptr [rsi + CS_LOSS], 0
    je .Lsc_gain_guard_start
    cmp dword ptr [rsi + CS_SIGNAL], 2
    jne .Lsc_gain_guard_start
    mov edx, [rsi + CS_LAG]
    mov eax, [rbx + SC_FS]
    add eax, eax
    cmp edx, eax
    jl .Lsc_bad
    imul eax, eax, 9
    cmp edx, eax
    jg .Lsc_bad
    jmp .Lsc_gain_guard_start
.Lsc_voiced_guard:
    xor ecx, ecx
    mov eax, [rbx + SC_FS]
    add eax, eax
    imul r9d, eax, 9
.Lsc_pitch_guard:
    mov edx, [rdi + rcx*4 + DC_PITCH]
    cmp edx, eax
    jl .Lsc_bad
    cmp edx, r9d
    jg .Lsc_bad
    test ecx, ecx
    jz .Lsc_pitch_guard_next
    mov r10d, edx
    sub r10d, [rdi + rcx*4 + DC_PITCH - 4]
    cmp r10d, [rsp + 108]         #protect initialized LTP history
    jg .Lsc_bad
.Lsc_pitch_guard_next:
    inc ecx
    cmp ecx, r8d
    jb .Lsc_pitch_guard
.Lsc_gain_guard_start:
    xor ecx, ecx
.Lsc_gain_guard:
    cmp dword ptr [rdi + rcx*4 + DC_GAINS], 0
    jle .Lsc_bad
    inc ecx
    cmp ecx, r8d
    jb .Lsc_gain_guard
    xor ecx, ecx
.Lsc_pulse_guard:
    mov eax, [r14 + rcx*4]
    cmp eax, -32768
    jl .Lsc_bad
    cmp eax, 32767
    jg .Lsc_bad
    inc ecx
    cmp ecx, [rsp + 116]
    jb .Lsc_pulse_guard
    # Excitation and random sign reconstruction.
    movzx eax, byte ptr [r15 + SX_SIGNAL]
    shr eax, 1
    add eax, eax
    movzx edx, byte ptr [r15 + SX_OFFSET]
    add eax, edx
    lea rcx, [rip + sc_offsets]
    movsx eax, word ptr [rcx + rax*2]
    shl eax, 4
    mov [rsp + 124], eax
    movzx r8d, byte ptr [r15 + SX_SEED]
    xor ecx, ecx
.Lsc_excitation:
    imul r8d, r8d, 196314165
    add r8d, 907633515
    mov eax, [r14 + rcx*4]
    shl eax, 14
    test eax, eax
    jz .Lsc_exc_offset
    js .Lsc_exc_negative
    sub eax, 1280
    jmp .Lsc_exc_offset
.Lsc_exc_negative:
    add eax, 1280
.Lsc_exc_offset:
    add eax, [rsp + 124]
    mov edx, eax
    neg edx
    test r8d, r8d
    cmovs eax, edx
    mov [rsi + rcx*4 + CS_EXC], eax
    add r8d, [r14 + rcx*4]
    inc ecx
    cmp ecx, [rsp + 116]
    jb .Lsc_excitation
    xor ecx, ecx
.Lsc_lpc_load:
    mov eax, [rsi + rcx*4 + CS_LPC]
    mov [r12 + rcx*4 + SW_LPC], eax
    inc ecx
    cmp ecx, 16
    jb .Lsc_lpc_load
    mov dword ptr [rsp + 128], 0  #subframe
.Lsc_subframe:
    mov eax, [rsp + 128]
    mov edx, eax
    shr edx, 1
    shl edx, 5
    lea r8, [rdi + rdx + DC_PRED]
    mov [rsp + 144], r8
    xor ecx, ecx
.Lsc_coef_copy:
    mov dx, [r8 + rcx*2]
    mov [r12 + rcx*2 + SW_COEF], dx
    inc ecx
    cmp ecx, [rsp + 120]
    jb .Lsc_coef_copy
    imul edx, eax, 10
    lea r8, [rdi + rdx + DC_LTP]
    mov [rsp + 152], r8
    movzx edx, byte ptr [r15 + SX_SIGNAL]
    mov [rsp + 92], edx
    mov ecx, [rdi + rax*4 + DC_GAINS]
    mov edx, ecx
    sar edx, 6
    mov [rsp + 88], edx           #Gain Q10
    mov edx, 47
    call op_silk_inverse32
    mov [rsp + 80], eax           #inverse gain Q31
    mov eax, [rsp + 128]
    mov edx, [rdi + rax*4 + DC_GAINS]
    mov ecx, [rsi + CS_GAIN]
    cmp edx, ecx
    je .Lsc_same_gain
    mov r8d, 16
    call op_silk_div32
    mov [rsp + 84], eax
    xor ecx, ecx
.Lsc_scale_lpc:
    movsxd rax, dword ptr [r12 + rcx*4 + SW_LPC]
    movsxd rdx, dword ptr [rsp + 84]
    imul rax, rdx
    sar rax, 16
    mov [r12 + rcx*4 + SW_LPC], eax
    inc ecx
    cmp ecx, 16
    jb .Lsc_scale_lpc
    jmp .Lsc_save_gain
.Lsc_same_gain:
    mov dword ptr [rsp + 84], 65536
.Lsc_save_gain:
    mov eax, [rsp + 128]
    mov edx, [rdi + rax*4 + DC_GAINS]
    mov [rsi + CS_GAIN], edx
    cmp dword ptr [rsi + CS_LOSS], 0
    je .Lsc_signal_ready
    cmp dword ptr [rsi + CS_SIGNAL], 2
    jne .Lsc_signal_ready
    cmp byte ptr [r15 + SX_SIGNAL], 2
    je .Lsc_signal_ready
    cmp eax, 2
    jae .Lsc_signal_ready
    mov r8, [rsp + 152]
    mov qword ptr [r8], 0
    mov word ptr [r8 + 8], 0
    mov word ptr [r8 + 4], 4096
    mov dword ptr [rsp + 92], 2
    mov edx, [rsi + CS_LAG]
    mov [rdi + rax*4 + DC_PITCH], edx
.Lsc_signal_ready:
    cmp dword ptr [rsp + 92], 2
    jne .Lsc_no_ltp
    mov eax, [rsp + 128]
    mov edx, [rdi + rax*4 + DC_PITCH]
    mov [rsp + 96], edx           #lag
    test eax, eax
    jz .Lsc_rewhiten
    cmp eax, 2
    jne .Lsc_adjust_ltp
    cmp dword ptr [rsp + 104], 0
    je .Lsc_adjust_ltp
    mov edx, [rsp + 112]
    lea r8, [rsi + rdx*2 + CS_OUT]
    mov ecx, [rsp + 108]
    add ecx, ecx
    xor eax, eax
.Lsc_copy_half_pcm:
    mov dx, [r13 + rax*2]
    mov [r8 + rax*2], dx
    inc eax
    cmp eax, ecx
    jb .Lsc_copy_half_pcm
.Lsc_rewhiten:
    mov eax, [rsp + 112]
    sub eax, [rsp + 96]
    sub eax, [rsp + 120]
    sub eax, 2                 #start index>0 guaranteed by pitch limits
    lea rdx, [r12 + rax*2 + SW_LTP]
    mov [rsp + 32 + SF_OUT], rdx
    mov edx, [rsp + 128]
    imul edx, [rsp + 108]
    add edx, eax
    lea rdx, [rsi + rdx*2 + CS_OUT]
    mov [rsp + 32 + SF_IN], rdx
    mov rdx, [rsp + 144]
    mov [rsp + 32 + SF_COEF], rdx
    mov edx, [rsp + 112]
    sub edx, eax
    mov [rsp + 32 + SF_N], edx
    mov [rsp + 32 + SF_OUT_CAP], edx
    mov [rsp + 32 + SF_IN_CAP], edx
    mov eax, [rsp + 120]
    mov [rsp + 32 + SF_ORDER], eax
    mov [rsp + 32 + SF_COEF_CAP], eax
    lea rcx, [rsp + 32]
    call op_silk_analysis_filter
    cmp dword ptr [rsp + 128], 0
    jne .Lsc_seed_ltp
    movsxd rax, dword ptr [rsp + 80]
    movsx rdx, word ptr [rdi + DC_SCALE]
    imul rax, rdx
    sar rax, 16
    shl eax, 2
    mov [rsp + 80], eax
.Lsc_seed_ltp:
    xor ecx, ecx
.Lsc_seed_ltp_sample:
    mov edx, [rsp + 112]
    sub edx, ecx
    dec edx
    movsx rdx, word ptr [r12 + rdx*2 + SW_LTP]
    movsxd rax, dword ptr [rsp + 80]
    imul rax, rdx
    sar rax, 16
    mov edx, [rsp + 100]
    sub edx, ecx
    dec edx
    mov [r12 + rdx*4 + SW_Q15], eax
    inc ecx
    mov eax, [rsp + 96]
    add eax, 2
    cmp ecx, eax
    jb .Lsc_seed_ltp_sample
    jmp .Lsc_ltp_predict
.Lsc_adjust_ltp:
    cmp dword ptr [rsp + 84], 65536
    je .Lsc_ltp_predict
    xor ecx, ecx
.Lsc_adjust_ltp_sample:
    mov edx, [rsp + 100]
    sub edx, ecx
    dec edx
    movsxd rax, dword ptr [r12 + rdx*4 + SW_Q15]
    movsxd r8, dword ptr [rsp + 84]
    imul rax, r8
    sar rax, 16
    mov [r12 + rdx*4 + SW_Q15], eax
    inc ecx
    mov eax, [rsp + 96]
    add eax, 2
    cmp ecx, eax
    jb .Lsc_adjust_ltp_sample
.Lsc_ltp_predict:
    mov eax, [rsp + 128]
    imul eax, [rsp + 108]
    lea rax, [rsi + rax*4 + CS_EXC]
    mov [rsp + 160], rax
    xor r8d, r8d
.Lsc_ltp_sample:
    mov eax, [rsp + 100]
    sub eax, [rsp + 96]
    add eax, 2
    lea r9, [r12 + rax*4 + SW_Q15]
    mov r10, [rsp + 152]
    mov r11d, 2
    xor ecx, ecx
.Lsc_ltp_tap:
    movsxd rax, dword ptr [r9]
    movsx rdx, word ptr [r10 + rcx*2]
    imul rax, rdx
    sar rax, 16
    add r11d, eax
    sub r9, 4
    inc ecx
    cmp ecx, 5
    jb .Lsc_ltp_tap
    mov r9, [rsp + 160]
    mov eax, [r9 + r8*4]
    add r11d, r11d
    add eax, r11d
    mov [r12 + r8*4 + SW_RES], eax
    shl eax, 1
    mov ecx, [rsp + 100]
    mov [r12 + rcx*4 + SW_Q15], eax
    inc dword ptr [rsp + 100]
    inc r8d
    cmp r8d, [rsp + 108]
    jb .Lsc_ltp_sample
    lea rax, [r12 + SW_RES]
    jmp .Lsc_short_term
.Lsc_no_ltp:
    mov eax, [rsp + 128]
    imul eax, [rsp + 108]
    lea rax, [rsi + rax*4 + CS_EXC]
.Lsc_short_term:
    mov [rsp + 168], rax
    xor r8d, r8d
.Lsc_lpc_sample:
    mov r11d, [rsp + 120]
    shr r11d, 1
    xor ecx, ecx
.Lsc_lpc_tap:
    lea edx, [r8 + 15]
    sub edx, ecx
    movsxd rax, dword ptr [r12 + rdx*4 + SW_LPC]
    movsx rdx, word ptr [r12 + rcx*2 + SW_COEF]
    imul rax, rdx
    sar rax, 16
    add r11d, eax
    inc ecx
    cmp ecx, [rsp + 120]
    jb .Lsc_lpc_tap
    mov r9, [rsp + 168]
    mov eax, [r9 + r8*4]
    shl r11d, 4
    add eax, r11d
    mov [r12 + r8*4 + SW_LPC + 64], eax
    movsxd rax, eax
    movsxd rdx, dword ptr [rsp + 88]
    imul rax, rdx
    sar rax, 16
    # SMULWW returns int32 before the rounded Q8 conversion.
    sar eax, 7
    inc eax
    sar eax, 1
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    mov ecx, [rsp + 128]
    imul ecx, [rsp + 108]
    add ecx, r8d
    mov [r13 + rcx*2], ax
    inc r8d
    cmp r8d, [rsp + 108]
    jb .Lsc_lpc_sample
    xor ecx, ecx
    mov r8d, [rsp + 108]
.Lsc_lpc_history:
    mov eax, [r12 + r8*4 + SW_LPC]
    mov [r12 + rcx*4 + SW_LPC], eax
    inc r8d
    inc ecx
    cmp ecx, 16
    jb .Lsc_lpc_history
    inc dword ptr [rsp + 128]
    mov eax, [rsp + 128]
    cmp eax, [rbx + SC_SUBFR]
    jb .Lsc_subframe
    xor ecx, ecx
.Lsc_save_lpc:
    mov eax, [r12 + rcx*4 + SW_LPC]
    mov [rsi + rcx*4 + CS_LPC], eax
    inc ecx
    cmp ecx, 16
    jb .Lsc_save_lpc
    mov eax, 1
    jmp .Lsc_done
.Lsc_bad:
    xor eax, eax
.Lsc_done:
    add rsp, 192
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_synthesis
