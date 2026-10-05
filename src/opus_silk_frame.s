# Stateful SILK channel initialization, rate configuration and frame PCM.
# RFC6716 init_decoder.c/decoder_set_fs.c/decode_frame.c, Copyright(c)
# 2006-2012 IETF Trust/Skype Limited. BSD in THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "opus_silk_frame_layout.inc"
.include "opus_silk_indices_layout.inc"
.include "opus_silk_state_layout.inc"
.include "opus_silk_synthesis_layout.inc"
.include "opus_silk_plc_layout.inc"
.include "opus_silk_cng_layout.inc"
.text
# Validate init/config request; EAX=1/0, R8=state, EDX=fs, R9D=subframes.
LOCALFN fi_validate
    test rcx, rcx
    jz .Lfi_invalid
    mov r8, [rcx + FI_STATE]
    test r8, r8
    jz .Lfi_invalid
    cmp dword ptr [rcx + FI_STATE_CAP], FN_SIZE
    jb .Lfi_invalid
    mov edx, [rcx + FI_FS]
    cmp edx, 8
    je .Lfi_rate
    cmp edx, 12
    je .Lfi_rate
    cmp edx, 16
    jne .Lfi_invalid
.Lfi_rate:
    mov r9d, [rcx + FI_SUBFR]
    cmp r9d, 2
    je .Lfi_valid
    cmp r9d, 4
    jne .Lfi_invalid
.Lfi_valid:
    mov eax, 1
    ret
.Lfi_invalid:
    xor eax, eax
    ret
ENDFN fi_validate
FN op_silk_frame_init
    push rdi
    sub rsp, 32
    call fi_validate
    test eax, eax
    jz .Lfi_init_done
    mov rdi, r8
    mov ecx, FN_SIZE/4
    xor eax, eax
    rep stosd
    mov dword ptr [r8 + FN_CORE + CS_GAIN], 65536
    mov dword ptr [r8 + FN_CNG + CN_RNG], 3176576
    mov dword ptr [r8 + FN_PLC + PN_GAINS], 65536
    mov dword ptr [r8 + FN_PLC + PN_GAINS + 4], 65536
    mov dword ptr [r8 + FN_PLC + PN_SUBLEN], 20
    mov dword ptr [r8 + FN_PLC + PN_SUBFR], 2
    mov [r8 + FN_FS], edx
    mov [r8 + FN_SUBFR], r9d
    mov dword ptr [r8 + FN_CORE + CS_LAG], 100
    mov byte ptr [r8 + FN_PARAM + DS_GAIN], 10
    mov dword ptr [r8 + FN_PARAM + DS_FIRST], 1
    mov dword ptr [r8 + FN_TAG], FN_TAG_VALUE
    mov eax, 1
.Lfi_init_done:
    add rsp, 32
    pop rdi
    ret
ENDFN op_silk_frame_init
FN op_silk_frame_config
    push rdi
    sub rsp, 32
    call fi_validate
    test eax, eax
    jz .Lfi_config_done
    cmp dword ptr [r8 + FN_TAG], FN_TAG_VALUE
    jne .Lfi_config_bad
    cmp dword ptr [r8 + FN_ERROR], 0
    jne .Lfi_config_bad
    mov eax, [r8 + FN_FS]
    cmp eax, 8
    je .Lfi_current_rate
    cmp eax, 12
    je .Lfi_current_rate
    cmp eax, 16
    jne .Lfi_config_bad
.Lfi_current_rate:
    cmp dword ptr [r8 + FN_SUBFR], 2
    je .Lfi_current_subfr
    cmp dword ptr [r8 + FN_SUBFR], 4
    jne .Lfi_config_bad
.Lfi_current_subfr:
    cmp [r8 + FN_FS], edx
    je .Lfi_config_subfr
    # Normative internal-rate reset preserves excitation, gain, indices,
    # previous NLSFs and PLC/CNG until their next frame-rate checks.
    lea rdi, [r8 + FN_CORE + CS_LPC]
    mov ecx, 16
    xor eax, eax
    rep stosd
    lea rdi, [r8 + FN_CORE + CS_OUT]
    mov ecx, 240
    rep stosd
    mov dword ptr [r8 + FN_CORE + CS_LAG], 100
    mov dword ptr [r8 + FN_CORE + CS_SIGNAL], 0
    mov byte ptr [r8 + FN_PARAM + DS_GAIN], 10
    mov dword ptr [r8 + FN_PARAM + DS_FIRST], 1
    mov [r8 + FN_FS], edx
.Lfi_config_subfr:
    mov [r8 + FN_SUBFR], r9d
    mov eax, 1
    jmp .Lfi_config_done
.Lfi_config_bad:
    xor eax, eax
.Lfi_config_done:
    add rsp, 32
    pop rdi
    ret
ENDFN op_silk_frame_config
# Returns source-rate sample count,0 on failure. Public request/header
# errors reject before writes. A later component error marks sticky
# failure; discard that frame's PCM/state and reinitialize before reuse.
FN op_silk_decode_frame
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
    jz .Lff_bad
    mov rsi, [rbx + FF_STATE]
    mov r12, [rbx + FF_PCM]
    mov r13, [rbx + FF_WORK]
    mov r14, [rbx + FF_EC]
    test rsi, rsi
    jz .Lff_bad
    test r12, r12
    jz .Lff_bad
    test r13, r13
    jz .Lff_bad
    cmp dword ptr [rbx + FF_STATE_CAP], FN_SIZE
    jb .Lff_bad
    cmp dword ptr [rbx + FF_WORK_CAP], FW_SIZE
    jb .Lff_bad
    cmp dword ptr [rsi + FN_TAG], FN_TAG_VALUE
    jne .Lff_bad
    cmp dword ptr [rsi + FN_ERROR], 0
    jne .Lff_bad
    mov eax, [rsi + FN_FS]
    cmp eax, 8
    je .Lff_rate
    cmp eax, 12
    je .Lff_rate
    cmp eax, 16
    jne .Lff_bad
.Lff_rate:
    mov ecx, [rsi + FN_SUBFR]
    cmp ecx, 2
    je .Lff_subfr
    cmp ecx, 4
    jne .Lff_bad
.Lff_subfr:
    imul eax, ecx
    imul r15d, eax, 5
    cmp [rbx + FF_PCM_CAP], r15d
    jb .Lff_bad
    cmp dword ptr [rbx + FF_MODE], 2
    ja .Lff_bad
    cmp dword ptr [rbx + FF_VAD], 1
    ja .Lff_bad
    cmp dword ptr [rbx + FF_LBRR], 1
    ja .Lff_bad
    cmp dword ptr [rbx + FF_COND], 2
    ja .Lff_bad
    cmp dword ptr [rsi + FN_CORE + CS_GAIN], 0
    jle .Lff_bad
    cmp dword ptr [rsi + FN_CORE + CS_SIGNAL], 2
    ja .Lff_bad
    cmp dword ptr [rsi + FN_CORE + CS_LOSS], 0
    jl .Lff_bad
    cmp dword ptr [rsi + FN_PARAM + DS_FIRST], 1
    ja .Lff_bad
    cmp byte ptr [rsi + FN_PARAM + DS_GAIN], 63
    ja .Lff_bad
    mov dword ptr [rsp + 128], 0    #actual loss branch
    cmp dword ptr [rbx + FF_MODE], 0
    je .Lff_entropy_guard
    cmp dword ptr [rbx + FF_MODE], 1
    je .Lff_loss_guard
    cmp dword ptr [rbx + FF_LBRR], 1
    je .Lff_entropy_guard
.Lff_loss_guard:
    mov dword ptr [rsp + 128], 1
    cmp dword ptr [rsi + FN_CORE + CS_LOSS], 0x7fffffff
    je .Lff_bad
    jmp .Lff_start
.Lff_entropy_guard:
    test r14, r14
    jz .Lff_bad
    cmp dword ptr [rbx + FF_EC_CAP], 64
    jb .Lff_bad
    cmp qword ptr [r14], 0
    je .Lff_bad
    cmp dword ptr [r14 + 8], 1275
    ja .Lff_bad
    mov eax, [r14 + 8]
    cmp [r14 + 12], eax
    ja .Lff_bad
    cmp [r14 + 28], eax
    ja .Lff_bad
    cmp dword ptr [r14 + 32], 0x800000
    jbe .Lff_bad
    cmp dword ptr [r14 + 32], 0x80000000
    ja .Lff_bad
    mov eax, [r14 + 32]
    cmp [r14 + 36], eax
    jae .Lff_bad
    cmp dword ptr [r14 + 20], 32
    ja .Lff_bad
    cmp dword ptr [r14 + 24], 32768
    ja .Lff_bad
    cmp dword ptr [rsi + FN_PREVIOUS + SS_SIGNAL], 2
    ja .Lff_bad
    mov eax, [rsi + FN_PREVIOUS + SS_LAG]
    cmp eax, -32768
    jl .Lff_bad
    cmp eax, 32767
    jg .Lff_bad
.Lff_start:
    lea rdi, [r13 + FW_CTRL]
    xor eax, eax
    mov ecx, 35
    rep stosd
    cmp dword ptr [rsp + 128], 0
    jne .Lff_plc
    mov [rsp + 32 + SI_EC], r14
    lea rax, [rsi + FN_PREVIOUS]
    mov [rsp + 32 + SI_STATE], rax
    lea rax, [rsi + FN_IND]
    mov [rsp + 32 + SI_OUT], rax
    mov eax, [rsi + FN_FS]
    mov [rsp + 32 + SI_FS], eax
    mov eax, [rsi + FN_SUBFR]
    mov [rsp + 32 + SI_SUBFR], eax
    mov eax, [rbx + FF_VAD]
    mov [rsp + 32 + SI_VAD], eax
    xor eax, eax
    cmp dword ptr [rbx + FF_MODE], 2
    sete al
    mov [rsp + 32 + SI_LBRR], eax
    mov eax, [rbx + FF_COND]
    mov [rsp + 32 + SI_COND], eax
    mov dword ptr [rsp + 32 + SI_OUT_CAP], 36
    mov dword ptr [rsp + 32 + SI_STATE_CAP], 8
    lea rcx, [rsp + 32]
    call op_silk_indices
    test eax, eax
    jz .Lff_failed
    mov rcx, r14
    lea rdx, [r13 + FW_PULSES]
    movzx r8d, byte ptr [rsi + FN_IND + SX_SIGNAL]
    movzx r9d, byte ptr [rsi + FN_IND + SX_OFFSET]
    mov [rsp + 32], r15d
    call op_silk_pulses
    test eax, eax
    jz .Lff_failed
    mov eax, [rsi + FN_CORE + CS_LOSS]
    mov [rsi + FN_PARAM + DS_LOSS], eax
    lea rax, [rsi + FN_IND]
    mov [rsp + 32 + SD_IND], rax
    lea rax, [rsi + FN_PARAM]
    mov [rsp + 32 + SD_STATE], rax
    lea rax, [r13 + FW_CTRL]
    mov [rsp + 32 + SD_OUT], rax
    mov eax, [rsi + FN_FS]
    mov [rsp + 32 + SD_FS], eax
    mov eax, [rsi + FN_SUBFR]
    mov [rsp + 32 + SD_SUBFR], eax
    mov eax, [rbx + FF_COND]
    mov [rsp + 32 + SD_COND], eax
    mov dword ptr [rsp + 32 + SD_IND_CAP], 36
    mov dword ptr [rsp + 32 + SD_STATE_CAP], DS_SIZE
    mov dword ptr [rsp + 32 + SD_OUT_CAP], DC_SIZE
    lea rcx, [rsp + 32]
    call op_silk_decode_parameters
    test eax, eax
    jz .Lff_failed
    lea rax, [rsi + FN_CORE]
    mov [rsp + 32 + SC_STATE], rax
    lea rax, [r13 + FW_CTRL]
    mov [rsp + 32 + SC_CTRL], rax
    lea rax, [rsi + FN_IND]
    mov [rsp + 32 + SC_IND], rax
    lea rax, [r13 + FW_PULSES]
    mov [rsp + 32 + SC_PULSES], rax
    mov [rsp + 32 + SC_PCM], r12
    lea rax, [r13 + FW_TEMP]
    mov [rsp + 32 + SC_WORK], rax
    mov eax, [rsi + FN_FS]
    mov [rsp + 32 + SC_FS], eax
    mov eax, [rsi + FN_SUBFR]
    mov [rsp + 32 + SC_SUBFR], eax
    mov dword ptr [rsp + 32 + SC_STATE_CAP], CS_SIZE
    mov dword ptr [rsp + 32 + SC_CTRL_CAP], DC_SIZE
    mov [rsp + 32 + SC_PULSE_CAP], r15d
    mov [rsp + 32 + SC_PCM_CAP], r15d
    mov dword ptr [rsp + 32 + SC_WORK_CAP], SW_SIZE
    mov dword ptr [rsp + 32 + SC_IND_CAP], 36
    lea rcx, [rsp + 32]
    call op_silk_synthesis
    test eax, eax
    jz .Lff_failed
.Lff_plc:
    lea rax, [rsi + FN_PLC]
    mov [rsp + 32 + PL_STATE], rax
    lea rax, [rsi + FN_CORE]
    mov [rsp + 32 + PL_CORE], rax
    lea rax, [rsi + FN_PARAM]
    mov [rsp + 32 + PL_PARAM], rax
    lea rax, [r13 + FW_CTRL]
    mov [rsp + 32 + PL_CTRL], rax
    lea rax, [rsi + FN_IND]
    mov [rsp + 32 + PL_IND], rax
    mov [rsp + 32 + PL_PCM], r12
    lea rax, [r13 + FW_TEMP]
    mov [rsp + 32 + PL_WORK], rax
    mov eax, [rsi + FN_FS]
    mov [rsp + 32 + PL_FS], eax
    mov eax, [rsi + FN_SUBFR]
    mov [rsp + 32 + PL_SUBFR], eax
    mov eax, [rsp + 128]
    mov [rsp + 32 + PL_LOST], eax
    mov dword ptr [rsp + 32 + PL_STATE_CAP], PN_SIZE
    mov dword ptr [rsp + 32 + PL_CORE_CAP], CS_SIZE
    mov dword ptr [rsp + 32 + PL_PARAM_CAP], DS_SIZE
    mov dword ptr [rsp + 32 + PL_CTRL_CAP], DC_SIZE
    mov dword ptr [rsp + 32 + PL_IND_CAP], 36
    mov [rsp + 32 + PL_PCM_CAP], r15d
    mov dword ptr [rsp + 32 + PL_WORK_CAP], PW_SIZE
    lea rcx, [rsp + 32]
    call op_silk_plc
    test eax, eax
    jz .Lff_failed
    cmp dword ptr [rsp + 128], 0
    jne .Lff_history
    mov dword ptr [rsi + FN_CORE + CS_LOSS], 0
    mov dword ptr [rsi + FN_PARAM + DS_FIRST], 0
.Lff_history:
    # Maintain unmodified output history before glue/CNG, as decode_frame.c.
    imul r8d, dword ptr [rsi + FN_FS], 20
    sub r8d, r15d
    xor ecx, ecx
.Lff_move_history:
    cmp ecx, r8d
    jae .Lff_copy_start
    lea edx, [rcx + r15]
    mov ax, [rsi + rdx*2 + FN_CORE + CS_OUT]
    mov [rsi + rcx*2 + FN_CORE + CS_OUT], ax
    inc ecx
    jmp .Lff_move_history
.Lff_copy_start:
    xor ecx, ecx
.Lff_copy_history:
    mov ax, [r12 + rcx*2]
    lea edx, [rcx + r8]
    mov [rsi + rdx*2 + FN_CORE + CS_OUT], ax
    inc ecx
    cmp ecx, r15d
    jb .Lff_copy_history
    lea rax, [rsi + FN_PLC]
    mov [rsp + 32 + PG_STATE], rax
    mov [rsp + 32 + PG_PCM], r12
    mov [rsp + 32 + PG_N], r15d
    mov eax, [rsi + FN_CORE + CS_LOSS]
    mov [rsp + 32 + PG_LOSS], eax
    mov dword ptr [rsp + 32 + PG_STATE_CAP], PN_SIZE
    mov [rsp + 32 + PG_PCM_CAP], r15d
    lea rcx, [rsp + 32]
    call op_silk_plc_glue
    test eax, eax
    jz .Lff_failed
    lea rax, [rsi + FN_CNG]
    mov [rsp + 32 + CG_STATE], rax
    lea rax, [rsi + FN_CORE]
    mov [rsp + 32 + CG_CORE], rax
    lea rax, [rsi + FN_PARAM]
    mov [rsp + 32 + CG_PARAM], rax
    lea rax, [r13 + FW_CTRL]
    mov [rsp + 32 + CG_CTRL], rax
    mov [rsp + 32 + CG_PCM], r12
    lea rax, [r13 + FW_TEMP]
    mov [rsp + 32 + CG_WORK], rax
    mov eax, [rsi + FN_FS]
    mov [rsp + 32 + CG_FS], eax
    mov eax, [rsi + FN_SUBFR]
    mov [rsp + 32 + CG_SUBFR], eax
    mov [rsp + 32 + CG_N], r15d
    mov dword ptr [rsp + 32 + CG_STATE_CAP], CN_SIZE
    mov dword ptr [rsp + 32 + CG_CORE_CAP], CS_SIZE
    mov dword ptr [rsp + 32 + CG_PARAM_CAP], DS_SIZE
    mov dword ptr [rsp + 32 + CG_CTRL_CAP], DC_SIZE
    mov [rsp + 32 + CG_PCM_CAP], r15d
    mov dword ptr [rsp + 32 + CG_WORK_CAP], CW_SIZE
    lea rcx, [rsp + 32]
    call op_silk_cng
    test eax, eax
    jz .Lff_failed
    mov ecx, [rsi + FN_SUBFR]
    dec ecx
    mov eax, [r13 + rcx*4 + FW_CTRL + DC_PITCH]
    mov [rsi + FN_CORE + CS_LAG], eax
    mov eax, [rsi + FN_CORE + CS_LOSS]
    mov [rsi + FN_PARAM + DS_LOSS], eax
    mov eax, r15d
    jmp .Lff_done
.Lff_failed:
    mov dword ptr [rsi + FN_ERROR], 1
.Lff_bad:
    xor eax, eax
.Lff_done:
    add rsp, 144
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_silk_decode_frame
