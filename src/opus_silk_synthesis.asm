; Handwritten SILK inverse-NSQ: excitation, LTP/LPC prediction and PCM.
; RFC6716 decode_core.c. Copyright(c)2006-2012 IETF Trust and Skype
; Limited. BSD conditions in THIRD_PARTY_NOTICES. Caller-owned scratch.
option casemap:none
include opus_silk_synthesis_layout.inc
include opus_silk_state_layout.inc
include opus_silk_indices_layout.inc
include opus_silk_prediction_layout.inc
EXTERN op_silk_inverse32:PROC,op_silk_div32:PROC,op_silk_analysis_filter:PROC
PUBLIC op_silk_synthesis
.const
sc_offsets dw 100,240,32,100     ;normative Q10 unvoiced/voiced offsets
.code
op_silk_synthesis PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,192
    mov rbx,rcx
    test rbx,rbx
    jz sc_bad
    mov rsi,[rbx+SC_STATE]
    mov rdi,[rbx+SC_CTRL]
    mov r12,[rbx+SC_WORK]
    mov r13,[rbx+SC_PCM]
    mov r14,[rbx+SC_PULSES]
    mov r15,[rbx+SC_IND]
    test rsi,rsi
    jz sc_bad
    test rdi,rdi
    jz sc_bad
    test r12,r12
    jz sc_bad
    test r13,r13
    jz sc_bad
    test r14,r14
    jz sc_bad
    test r15,r15
    jz sc_bad
    cmp dword ptr [rbx+SC_STATE_CAP],CS_SIZE
    jb sc_bad
    cmp dword ptr [rbx+SC_CTRL_CAP],DC_SIZE
    jb sc_bad
    cmp dword ptr [rbx+SC_WORK_CAP],SW_SIZE
    jb sc_bad
    cmp dword ptr [rbx+SC_IND_CAP],36
    jb sc_bad
    mov eax,[rbx+SC_FS]
    mov ecx,10
    cmp eax,8
    je sc_rate
    cmp eax,12
    je sc_rate
    cmp eax,16
    jne sc_bad
    mov ecx,16
sc_rate:
    mov [rsp+120],ecx          ;LPC order
    imul ecx,eax,5
    mov [rsp+108],ecx          ;subframe length
    imul edx,eax,20
    mov [rsp+112],edx          ;LTP memory
    mov [rsp+100],edx          ;LTP write index
    mov r8d,[rbx+SC_SUBFR]
    cmp r8d,2
    je sc_subfr
    cmp r8d,4
    jne sc_bad
sc_subfr:
    imul ecx,r8d
    mov [rsp+116],ecx          ;frame length
    cmp [rbx+SC_PULSE_CAP],ecx
    jb sc_bad
    cmp [rbx+SC_PCM_CAP],ecx
    jb sc_bad
    cmp dword ptr [rsi+CS_GAIN],0
    jle sc_bad
    cmp dword ptr [rsi+CS_SIGNAL],2
    ja sc_bad
    cmp dword ptr [rsi+CS_LOSS],0
    jl sc_bad
    cmp byte ptr [r15+SX_SIGNAL],2
    ja sc_bad
    cmp byte ptr [r15+SX_OFFSET],1
    ja sc_bad
    cmp byte ptr [r15+SX_INTERP],4
    ja sc_bad
    cmp byte ptr [r15+SX_SEED],3
    ja sc_bad
    cmp dword ptr [rdi+DC_SCALE],16384
    ja sc_bad
    movzx eax,byte ptr [r15+SX_INTERP]
    cmp eax,4
    setb al
    movzx eax,al
    mov [rsp+104],eax
    movzx eax,byte ptr [r15+SX_SIGNAL]
    cmp eax,2
    je sc_voiced_guard
    cmp dword ptr [rsi+CS_LOSS],0
    je sc_gain_guard_start
    cmp dword ptr [rsi+CS_SIGNAL],2
    jne sc_gain_guard_start
    mov edx,[rsi+CS_LAG]
    mov eax,[rbx+SC_FS]
    add eax,eax
    cmp edx,eax
    jl sc_bad
    imul eax,eax,9
    cmp edx,eax
    jg sc_bad
    jmp sc_gain_guard_start
sc_voiced_guard:
    xor ecx,ecx
    mov eax,[rbx+SC_FS]
    add eax,eax
    imul r9d,eax,9
sc_pitch_guard:
    mov edx,[rdi+DC_PITCH+rcx*4]
    cmp edx,eax
    jl sc_bad
    cmp edx,r9d
    jg sc_bad
    test ecx,ecx
    jz sc_pitch_guard_next
    mov r10d,edx
    sub r10d,[rdi+DC_PITCH+rcx*4-4]
    cmp r10d,[rsp+108]         ;protect initialized LTP history
    jg sc_bad
sc_pitch_guard_next:
    inc ecx
    cmp ecx,r8d
    jb sc_pitch_guard
sc_gain_guard_start:
    xor ecx,ecx
sc_gain_guard:
    cmp dword ptr [rdi+DC_GAINS+rcx*4],0
    jle sc_bad
    inc ecx
    cmp ecx,r8d
    jb sc_gain_guard
    xor ecx,ecx
sc_pulse_guard:
    mov eax,[r14+rcx*4]
    cmp eax,-32768
    jl sc_bad
    cmp eax,32767
    jg sc_bad
    inc ecx
    cmp ecx,[rsp+116]
    jb sc_pulse_guard
    ; Excitation and random sign reconstruction.
    movzx eax,byte ptr [r15+SX_SIGNAL]
    shr eax,1
    add eax,eax
    movzx edx,byte ptr [r15+SX_OFFSET]
    add eax,edx
    lea rcx,sc_offsets
    movsx eax,word ptr [rcx+rax*2]
    shl eax,4
    mov [rsp+124],eax
    movzx r8d,byte ptr [r15+SX_SEED]
    xor ecx,ecx
sc_excitation:
    imul r8d,r8d,196314165
    add r8d,907633515
    mov eax,[r14+rcx*4]
    shl eax,14
    test eax,eax
    jz sc_exc_offset
    js sc_exc_negative
    sub eax,1280
    jmp sc_exc_offset
sc_exc_negative:
    add eax,1280
sc_exc_offset:
    add eax,[rsp+124]
    mov edx,eax
    neg edx
    test r8d,r8d
    cmovs eax,edx
    mov [rsi+CS_EXC+rcx*4],eax
    add r8d,[r14+rcx*4]
    inc ecx
    cmp ecx,[rsp+116]
    jb sc_excitation
    xor ecx,ecx
sc_lpc_load:
    mov eax,[rsi+CS_LPC+rcx*4]
    mov [r12+SW_LPC+rcx*4],eax
    inc ecx
    cmp ecx,16
    jb sc_lpc_load
    mov dword ptr [rsp+128],0  ;subframe
sc_subframe:
    mov eax,[rsp+128]
    mov edx,eax
    shr edx,1
    shl edx,5
    lea r8,[rdi+DC_PRED+rdx]
    mov [rsp+144],r8
    xor ecx,ecx
sc_coef_copy:
    mov dx,[r8+rcx*2]
    mov [r12+SW_COEF+rcx*2],dx
    inc ecx
    cmp ecx,[rsp+120]
    jb sc_coef_copy
    imul edx,eax,10
    lea r8,[rdi+DC_LTP+rdx]
    mov [rsp+152],r8
    movzx edx,byte ptr [r15+SX_SIGNAL]
    mov [rsp+92],edx
    mov ecx,[rdi+DC_GAINS+rax*4]
    mov edx,ecx
    sar edx,6
    mov [rsp+88],edx           ;Gain Q10
    mov edx,47
    call op_silk_inverse32
    mov [rsp+80],eax           ;inverse gain Q31
    mov eax,[rsp+128]
    mov edx,[rdi+DC_GAINS+rax*4]
    mov ecx,[rsi+CS_GAIN]
    cmp edx,ecx
    je sc_same_gain
    mov r8d,16
    call op_silk_div32
    mov [rsp+84],eax
    xor ecx,ecx
sc_scale_lpc:
    movsxd rax,dword ptr [r12+SW_LPC+rcx*4]
    movsxd rdx,dword ptr [rsp+84]
    imul rax,rdx
    sar rax,16
    mov [r12+SW_LPC+rcx*4],eax
    inc ecx
    cmp ecx,16
    jb sc_scale_lpc
    jmp sc_save_gain
sc_same_gain:
    mov dword ptr [rsp+84],65536
sc_save_gain:
    mov eax,[rsp+128]
    mov edx,[rdi+DC_GAINS+rax*4]
    mov [rsi+CS_GAIN],edx
    cmp dword ptr [rsi+CS_LOSS],0
    je sc_signal_ready
    cmp dword ptr [rsi+CS_SIGNAL],2
    jne sc_signal_ready
    cmp byte ptr [r15+SX_SIGNAL],2
    je sc_signal_ready
    cmp eax,2
    jae sc_signal_ready
    mov r8,[rsp+152]
    mov qword ptr [r8],0
    mov word ptr [r8+8],0
    mov word ptr [r8+4],4096
    mov dword ptr [rsp+92],2
    mov edx,[rsi+CS_LAG]
    mov [rdi+DC_PITCH+rax*4],edx
sc_signal_ready:
    cmp dword ptr [rsp+92],2
    jne sc_no_ltp
    mov eax,[rsp+128]
    mov edx,[rdi+DC_PITCH+rax*4]
    mov [rsp+96],edx           ;lag
    test eax,eax
    jz sc_rewhiten
    cmp eax,2
    jne sc_adjust_ltp
    cmp dword ptr [rsp+104],0
    je sc_adjust_ltp
    mov edx,[rsp+112]
    lea r8,[rsi+CS_OUT+rdx*2]
    mov ecx,[rsp+108]
    add ecx,ecx
    xor eax,eax
sc_copy_half_pcm:
    mov dx,[r13+rax*2]
    mov [r8+rax*2],dx
    inc eax
    cmp eax,ecx
    jb sc_copy_half_pcm
sc_rewhiten:
    mov eax,[rsp+112]
    sub eax,[rsp+96]
    sub eax,[rsp+120]
    sub eax,2                 ;start index>0 guaranteed by pitch limits
    lea rdx,[r12+SW_LTP+rax*2]
    mov [rsp+32+SF_OUT],rdx
    mov edx,[rsp+128]
    imul edx,[rsp+108]
    add edx,eax
    lea rdx,[rsi+CS_OUT+rdx*2]
    mov [rsp+32+SF_IN],rdx
    mov rdx,[rsp+144]
    mov [rsp+32+SF_COEF],rdx
    mov edx,[rsp+112]
    sub edx,eax
    mov [rsp+32+SF_N],edx
    mov [rsp+32+SF_OUT_CAP],edx
    mov [rsp+32+SF_IN_CAP],edx
    mov eax,[rsp+120]
    mov [rsp+32+SF_ORDER],eax
    mov [rsp+32+SF_COEF_CAP],eax
    lea rcx,[rsp+32]
    call op_silk_analysis_filter
    cmp dword ptr [rsp+128],0
    jne sc_seed_ltp
    movsxd rax,dword ptr [rsp+80]
    movsx rdx,word ptr [rdi+DC_SCALE]
    imul rax,rdx
    sar rax,16
    shl eax,2
    mov [rsp+80],eax
sc_seed_ltp:
    xor ecx,ecx
sc_seed_ltp_sample:
    mov edx,[rsp+112]
    sub edx,ecx
    dec edx
    movsx rdx,word ptr [r12+SW_LTP+rdx*2]
    movsxd rax,dword ptr [rsp+80]
    imul rax,rdx
    sar rax,16
    mov edx,[rsp+100]
    sub edx,ecx
    dec edx
    mov [r12+SW_Q15+rdx*4],eax
    inc ecx
    mov eax,[rsp+96]
    add eax,2
    cmp ecx,eax
    jb sc_seed_ltp_sample
    jmp sc_ltp_predict
sc_adjust_ltp:
    cmp dword ptr [rsp+84],65536
    je sc_ltp_predict
    xor ecx,ecx
sc_adjust_ltp_sample:
    mov edx,[rsp+100]
    sub edx,ecx
    dec edx
    movsxd rax,dword ptr [r12+SW_Q15+rdx*4]
    movsxd r8,dword ptr [rsp+84]
    imul rax,r8
    sar rax,16
    mov [r12+SW_Q15+rdx*4],eax
    inc ecx
    mov eax,[rsp+96]
    add eax,2
    cmp ecx,eax
    jb sc_adjust_ltp_sample
sc_ltp_predict:
    mov eax,[rsp+128]
    imul eax,[rsp+108]
    lea rax,[rsi+CS_EXC+rax*4]
    mov [rsp+160],rax
    xor r8d,r8d
sc_ltp_sample:
    mov eax,[rsp+100]
    sub eax,[rsp+96]
    add eax,2
    lea r9,[r12+SW_Q15+rax*4]
    mov r10,[rsp+152]
    mov r11d,2
    xor ecx,ecx
sc_ltp_tap:
    movsxd rax,dword ptr [r9]
    movsx rdx,word ptr [r10+rcx*2]
    imul rax,rdx
    sar rax,16
    add r11d,eax
    sub r9,4
    inc ecx
    cmp ecx,5
    jb sc_ltp_tap
    mov r9,[rsp+160]
    mov eax,[r9+r8*4]
    add r11d,r11d
    add eax,r11d
    mov [r12+SW_RES+r8*4],eax
    shl eax,1
    mov ecx,[rsp+100]
    mov [r12+SW_Q15+rcx*4],eax
    inc dword ptr [rsp+100]
    inc r8d
    cmp r8d,[rsp+108]
    jb sc_ltp_sample
    lea rax,[r12+SW_RES]
    jmp sc_short_term
sc_no_ltp:
    mov eax,[rsp+128]
    imul eax,[rsp+108]
    lea rax,[rsi+CS_EXC+rax*4]
sc_short_term:
    mov [rsp+168],rax
    xor r8d,r8d
sc_lpc_sample:
    mov r11d,[rsp+120]
    shr r11d,1
    xor ecx,ecx
sc_lpc_tap:
    lea edx,[r8+15]
    sub edx,ecx
    movsxd rax,dword ptr [r12+SW_LPC+rdx*4]
    movsx rdx,word ptr [r12+SW_COEF+rcx*2]
    imul rax,rdx
    sar rax,16
    add r11d,eax
    inc ecx
    cmp ecx,[rsp+120]
    jb sc_lpc_tap
    mov r9,[rsp+168]
    mov eax,[r9+r8*4]
    shl r11d,4
    add eax,r11d
    mov [r12+SW_LPC+64+r8*4],eax
    movsxd rax,eax
    movsxd rdx,dword ptr [rsp+88]
    imul rax,rdx
    sar rax,16
    ; SMULWW returns int32 before the rounded Q8 conversion.
    sar eax,7
    inc eax
    sar eax,1
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov ecx,[rsp+128]
    imul ecx,[rsp+108]
    add ecx,r8d
    mov [r13+rcx*2],ax
    inc r8d
    cmp r8d,[rsp+108]
    jb sc_lpc_sample
    xor ecx,ecx
    mov r8d,[rsp+108]
sc_lpc_history:
    mov eax,[r12+SW_LPC+r8*4]
    mov [r12+SW_LPC+rcx*4],eax
    inc r8d
    inc ecx
    cmp ecx,16
    jb sc_lpc_history
    inc dword ptr [rsp+128]
    mov eax,[rsp+128]
    cmp eax,[rbx+SC_SUBFR]
    jb sc_subframe
    xor ecx,ecx
sc_save_lpc:
    mov eax,[r12+SW_LPC+rcx*4]
    mov [rsi+CS_LPC+rcx*4],eax
    inc ecx
    cmp ecx,16
    jb sc_save_lpc
    mov eax,1
    jmp sc_done
sc_bad:
    xor eax,eax
sc_done:
    add rsp,192
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_synthesis ENDP
END
