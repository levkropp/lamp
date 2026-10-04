; Handwritten SILK decoder resampling. RFC6716 resampler*.c.
; Copyright(c)2006-2012 IETF Trust and Skype Limited. BSD conditions in
; THIRD_PARTY_NOTICES. No CRT/heap; bounded caller-owned history/scratch.
option casemap:none
include opus_silk_resampler_layout.inc
PUBLIC op_silk_up2,op_silk_ar2,op_silk_resampler_init,op_silk_resampler
.const
include opus_silk_resampler_tables.inc
sr_rates dd 8000,12000,16000,24000,48000
.code
op_silk_up2 PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    test rcx,rcx
    jz sr_up_bad
    mov r13,[rcx+RU_STATE]
    mov rsi,[rcx+RU_OUT]
    mov rdi,[rcx+RU_IN]
    test r13,r13
    jz sr_up_bad
    test rsi,rsi
    jz sr_up_bad
    test rdi,rdi
    jz sr_up_bad
    mov r12d,[rcx+RU_N]
    cmp r12d,960
    ja sr_up_bad
    cmp dword ptr [rcx+RU_STATE_CAP],6
    jb sr_up_bad
    cmp [rcx+RU_IN_CAP],r12d
    jb sr_up_bad
    lea eax,[r12*2]
    cmp [rcx+RU_OUT_CAP],eax
    jb sr_up_bad
    test r12d,r12d
    jz sr_up_good
    lea r14,sr_up0             ;two consecutive three-word tables
    xor ebx,ebx
sr_up_sample:
    movsx r9d,word ptr [rdi+rbx*2]
    shl r9d,10
    xor r8d,r8d               ;even/odd branch
sr_up_branch:
    mov r10d,r9d
    xor ecx,ecx
sr_up_section:
    imul r11d,r8d,3
    add r11d,ecx
    mov eax,r10d
    sub eax,[r13+r11*4]
    mov r15d,eax              ;wrapped Y
    movsxd rax,eax
    movsx rdx,word ptr [r14+r11*2]
    imul rax,rdx
    sar rax,16
    cmp ecx,2
    jne sr_up_product
    add eax,r15d
sr_up_product:
    mov edx,[r13+r11*4]
    add edx,eax               ;output=old state+X
    add eax,r10d              ;new state=input+X
    mov [r13+r11*4],eax
    mov r10d,edx
    inc ecx
    cmp ecx,3
    jb sr_up_section
    mov eax,r10d
    sar eax,9
    inc eax
    sar eax,1
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    lea edx,[rbx*2]
    add edx,r8d
    mov [rsi+rdx*2],ax
    inc r8d
    cmp r8d,2
    jb sr_up_branch
    inc ebx
    cmp ebx,r12d
    jb sr_up_sample
sr_up_good:
    mov eax,1
    jmp sr_up_done
sr_up_bad:
    xor eax,eax
sr_up_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_up2 ENDP

op_silk_ar2 PROC
    push rbx
    push rsi
    push rdi
    push r12
    test rcx,rcx
    jz sr_ar_bad
    mov rbx,[rcx+RA_STATE]
    mov rsi,[rcx+RA_OUT]
    mov rdi,[rcx+RA_IN]
    mov r12,[rcx+RA_COEF]
    test rbx,rbx
    jz sr_ar_bad
    test rsi,rsi
    jz sr_ar_bad
    test rdi,rdi
    jz sr_ar_bad
    test r12,r12
    jz sr_ar_bad
    mov r11d,[rcx+RA_N]
    cmp r11d,480
    ja sr_ar_bad
    cmp dword ptr [rcx+RA_STATE_CAP],2
    jb sr_ar_bad
    cmp dword ptr [rcx+RA_COEF_CAP],2
    jb sr_ar_bad
    cmp [rcx+RA_OUT_CAP],r11d
    jb sr_ar_bad
    cmp [rcx+RA_IN_CAP],r11d
    jb sr_ar_bad
    test r11d,r11d
    jz sr_ar_good
    xor ecx,ecx
sr_ar_sample:
    movsx eax,word ptr [rdi+rcx*2]
    shl eax,8
    add eax,[rbx]
    mov [rsi+rcx*4],eax
    shl eax,2
    movsxd r8,eax
    movsx rdx,word ptr [r12]
    mov rax,r8
    imul rax,rdx
    sar rax,16
    add eax,[rbx+4]
    mov [rbx],eax
    movsx rdx,word ptr [r12+2]
    mov rax,r8
    imul rax,rdx
    sar rax,16
    mov [rbx+4],eax
    inc ecx
    cmp ecx,r11d
    jb sr_ar_sample
sr_ar_good:
    mov eax,1
    jmp sr_ar_done
sr_ar_bad:
    xor eax,eax
sr_ar_done:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_ar2 ENDP

op_silk_resampler_init PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rbx,rcx
    test rbx,rbx
    jz sr_init_bad
    mov rsi,[rbx+RI_STATE]
    test rsi,rsi
    jz sr_init_bad
    cmp dword ptr [rbx+RI_CAP],RS_SIZE
    jb sr_init_bad
    lea rdx,sr_rates
    xor r14d,r14d
sr_init_in_rate:
    mov eax,[rdx+r14*4]
    cmp eax,[rbx+RI_IN]
    je sr_init_in_ok
    inc r14d
    cmp r14d,3
    jb sr_init_in_rate
    jmp sr_init_bad
sr_init_in_ok:
    xor r15d,r15d
sr_init_out_rate:
    mov eax,[rdx+r15*4]
    cmp eax,[rbx+RI_OUT]
    je sr_init_rates_ok
    inc r15d
    cmp r15d,5
    jb sr_init_out_rate
    jmp sr_init_bad
sr_init_rates_ok:
    mov eax,[rbx+RI_IN]
    xor edx,edx
    mov ecx,1000
    div ecx
    mov r12d,eax
    mov eax,[rbx+RI_OUT]
    xor edx,edx
    div ecx
    mov r13d,eax
    ; No state mutation until pointer/capacity/rate checks pass.
    mov rdi,rsi
    xor eax,eax
    mov ecx,RS_SIZE/8
    rep stosq
    mov [rsi+RS_IN],r12d
    mov [rsi+RS_OUT],r13d
    imul eax,r12d,10
    mov [rsi+RS_BATCH],eax
    imul eax,r14d,5
    add eax,r15d
    lea rdx,sr_delay
    movzx eax,byte ptr [rdx+rax]
    mov [rsi+RS_INPUT_DELAY],eax
    xor r8d,r8d               ;extra2x input factor
    cmp r13d,r12d
    je sr_init_ratio
    jb sr_init_down
    lea eax,[r12*2]
    cmp r13d,eax
    jne sr_init_up_fir
    mov dword ptr [rsi+RS_FUNC],1
    jmp sr_init_ratio
sr_init_up_fir:
    mov dword ptr [rsi+RS_FUNC],2
    mov r8d,1
    jmp sr_init_ratio
sr_init_down:
    mov dword ptr [rsi+RS_FUNC],3
    mov dword ptr [rsi+RS_ORDER],18
    cmp r12d,12
    je sr_init_down23
    cmp r13d,12
    je sr_init_down34
    lea rax,sr_down12
    mov dword ptr [rsi+RS_ORDER],24
    mov dword ptr [rsi+RS_FRACS],1
    jmp sr_init_coef
sr_init_down23:
    lea rax,sr_down23
    mov dword ptr [rsi+RS_FRACS],2
    jmp sr_init_coef
sr_init_down34:
    lea rax,sr_down34
    mov dword ptr [rsi+RS_FRACS],3
sr_init_coef:
    mov [rsi+RS_COEF],rax
sr_init_ratio:
    lea ecx,[r8+14]
    mov eax,r12d
    shl eax,cl
    xor edx,edx
    div r13d
    shl eax,2
    mov r9d,eax
    mov r10d,[rbx+RI_IN]
    mov ecx,r8d
    shl r10d,cl
    mov r11d,[rbx+RI_OUT]
sr_init_round_ratio:
    mov eax,r9d
    imul rax,r11
    sar rax,16
    cmp eax,r10d
    jge sr_init_ratio_ok
    inc r9d
    jmp sr_init_round_ratio
sr_init_ratio_ok:
    mov [rsi+RS_RATIO],r9d
    mov eax,1
    jmp sr_init_done
sr_init_bad:
    xor eax,eax
sr_init_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_resampler_init ENDP

; Internal validated block request: state/out/input/work pointers,N at32.
; Returns final output pointer; zero-length calls preserve active history.
sr_run PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,112
    mov rbx,[rcx]
    mov rsi,[rcx+8]
    mov rdi,[rcx+16]
    mov r12,[rcx+24]
    mov r13d,[rcx+32]
    test r13d,r13d
    jz sr_run_done
    mov eax,[rbx+RS_FUNC]
    test eax,eax
    jz sr_run_copy
    cmp eax,1
    je sr_run_up2
    cmp eax,3
    je sr_run_down
    ; Up-FIR needs eight int16 history samples. The normative extra eight
    ; copied scratch samples are unused/uninitialized; preserve unused state.
    xor ecx,ecx
sr_run_up_history:
    mov eax,[rbx+RS_FIR+rcx*4]
    mov [r12+rcx*4],eax
    inc ecx
    cmp ecx,4
    jb sr_run_up_history
sr_run_up_batch:
    mov r14d,r13d
    cmp r14d,[rbx+RS_BATCH]
    cmovg r14d,[rbx+RS_BATCH]
    mov [rsp+32+RU_STATE],rbx
    lea rax,[r12+16]
    mov [rsp+32+RU_OUT],rax
    mov [rsp+32+RU_IN],rdi
    mov [rsp+32+RU_N],r14d
    mov dword ptr [rsp+32+RU_STATE_CAP],6
    lea eax,[r14*2]
    mov [rsp+32+RU_OUT_CAP],eax
    mov [rsp+32+RU_IN_CAP],r14d
    lea rcx,[rsp+32]
    call op_silk_up2
    mov r15d,r14d
    shl r15d,17               ;maximum indexQ16
    xor r8d,r8d               ;indexQ16
    lea r10,sr_frac
    mov dword ptr [rsp+100],0
sr_run_up_interpolate:
    mov eax,r8d
    shr eax,16
    lea r9,[r12+rax*2]
    mov eax,r8d
    and eax,65535
    imul eax,12
    shr eax,16
    lea r11,[r10+rax*8]
    mov edx,11
    sub edx,eax
    lea rdx,[r10+rdx*8]
    mov [rsp+88],rdx
    xor ecx,ecx
    xor edx,edx
sr_run_up_first_taps:
    movsx eax,word ptr [r9+rcx*2]
    movsx rdx,word ptr [r11+rcx*2]
    imul eax,edx
    add [rsp+100],eax
    inc ecx
    cmp ecx,4
    jb sr_run_up_first_taps
    mov r11,[rsp+88]
    xor ecx,ecx
sr_run_up_last_taps:
    lea eax,[rcx+4]
    movsx edx,word ptr [r9+rax*2]
    mov eax,3
    sub eax,ecx
    movsx eax,word ptr [r11+rax*2]
    imul eax,edx
    add [rsp+100],eax
    inc ecx
    cmp ecx,4
    jb sr_run_up_last_taps
    mov eax,[rsp+100]
    sar eax,14
    inc eax
    sar eax,1
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov [rsi],ax
    add rsi,2
    add r8d,[rbx+RS_RATIO]
    mov dword ptr [rsp+100],0
    cmp r8d,r15d
    jb sr_run_up_interpolate
    ; Copy the eight defined tail samples to the next batch/history.
    lea r9,[r12+r14*4]
    xor ecx,ecx
sr_run_up_tail:
    mov eax,[r9+rcx*4]
    mov [r12+rcx*4],eax
    inc ecx
    cmp ecx,4
    jb sr_run_up_tail
    lea rdi,[rdi+r14*2]
    sub r13d,r14d
    test r13d,r13d
    jg sr_run_up_batch
    xor ecx,ecx
sr_run_up_save:
    mov eax,[r12+rcx*4]
    mov [rbx+RS_FIR+rcx*4],eax
    inc ecx
    cmp ecx,4
    jb sr_run_up_save
    jmp sr_run_done
sr_run_copy:
    xor ecx,ecx
sr_run_copy_sample:
    mov ax,[rdi+rcx*2]
    mov [rsi+rcx*2],ax
    inc ecx
    cmp ecx,r13d
    jb sr_run_copy_sample
    lea rsi,[rsi+r13*2]
    jmp sr_run_done
sr_run_up2:
    mov [rsp+32+RU_STATE],rbx
    mov [rsp+32+RU_OUT],rsi
    mov [rsp+32+RU_IN],rdi
    mov [rsp+32+RU_N],r13d
    mov dword ptr [rsp+32+RU_STATE_CAP],6
    lea eax,[r13*2]
    mov [rsp+32+RU_OUT_CAP],eax
    mov [rsp+32+RU_IN_CAP],r13d
    lea rcx,[rsp+32]
    call op_silk_up2
    lea rsi,[rsi+r13*4]
    jmp sr_run_done
sr_run_down:
    mov r15d,[rbx+RS_ORDER]
    xor ecx,ecx
sr_run_down_history:
    mov eax,[rbx+RS_FIR+rcx*4]
    mov [r12+rcx*4],eax
    inc ecx
    cmp ecx,r15d
    jb sr_run_down_history
sr_run_down_batch:
    mov r14d,r13d
    cmp r14d,[rbx+RS_BATCH]
    cmovg r14d,[rbx+RS_BATCH]
    mov [rsp+32+RA_STATE],rbx
    lea rax,[r12+r15*4]
    mov [rsp+32+RA_OUT],rax
    mov [rsp+32+RA_IN],rdi
    mov rax,[rbx+RS_COEF]
    mov [rsp+32+RA_COEF],rax
    mov [rsp+32+RA_N],r14d
    mov dword ptr [rsp+32+RA_STATE_CAP],2
    mov [rsp+32+RA_OUT_CAP],r14d
    mov [rsp+32+RA_IN_CAP],r14d
    mov dword ptr [rsp+32+RA_COEF_CAP],2
    lea rcx,[rsp+32]
    call op_silk_ar2
    xor r8d,r8d
    mov dword ptr [rsp+100],0
sr_run_down_interpolate:
    mov eax,r8d
    shr eax,16
    lea r9,[r12+rax*4]
    mov r10,[rbx+RS_COEF]
    add r10,4
    cmp r15d,18
    jne sr_run_down_pairs
    mov eax,r8d
    and eax,65535
    imul eax,[rbx+RS_FRACS]
    shr eax,16
    imul edx,eax,18
    lea r11,[r10+rdx]
    mov edx,[rbx+RS_FRACS]
    dec edx
    sub edx,eax
    imul edx,18
    add r10,rdx
    xor ecx,ecx
sr_run_down_first_taps:
    movsxd rax,dword ptr [r9+rcx*4]
    movsx rdx,word ptr [r11+rcx*2]
    imul rax,rdx
    sar rax,16
    add [rsp+100],eax
    inc ecx
    cmp ecx,9
    jb sr_run_down_first_taps
    xor ecx,ecx
sr_run_down_last_taps:
    mov eax,17
    sub eax,ecx
    movsxd rax,dword ptr [r9+rax*4]
    movsx rdx,word ptr [r10+rcx*2]
    imul rax,rdx
    sar rax,16
    add [rsp+100],eax
    inc ecx
    cmp ecx,9
    jb sr_run_down_last_taps
    jmp sr_run_down_output
sr_run_down_pairs:
    xor ecx,ecx
sr_run_down_pair_taps:
    mov eax,23
    sub eax,ecx
    mov edx,[r9+rax*4]
    add edx,[r9+rcx*4]
    movsxd rax,edx            ;wrapped symmetric sum
    movsx rdx,word ptr [r10+rcx*2]
    imul rax,rdx
    sar rax,16
    add [rsp+100],eax
    inc ecx
    cmp ecx,12
    jb sr_run_down_pair_taps
sr_run_down_output:
    mov eax,[rsp+100]
    sar eax,5
    inc eax
    sar eax,1
    mov edx,32767
    cmp eax,edx
    cmovg eax,edx
    mov edx,-32768
    cmp eax,edx
    cmovl eax,edx
    mov [rsi],ax
    add rsi,2
    mov dword ptr [rsp+100],0
    add r8d,[rbx+RS_RATIO]
    mov eax,r14d
    shl eax,16
    cmp r8d,eax
    jb sr_run_down_interpolate
    lea r9,[r12+r14*4]
    xor ecx,ecx
sr_run_down_tail:
    mov eax,[r9+rcx*4]
    mov [r12+rcx*4],eax
    inc ecx
    cmp ecx,r15d
    jb sr_run_down_tail
    lea rdi,[rdi+r14*2]
    sub r13d,r14d
    test r13d,r13d
    jg sr_run_down_batch
    xor ecx,ecx
sr_run_down_save:
    mov eax,[r12+rcx*4]
    mov [rbx+RS_FIR+rcx*4],eax
    inc ecx
    cmp ecx,r15d
    jb sr_run_down_save
sr_run_done:
    mov rax,rsi
    add rsp,112
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
sr_run ENDP

op_silk_resampler PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,448
    mov rbx,rcx
    test rbx,rbx
    jz sr_resample_bad
    mov rsi,[rbx+RR_STATE]
    mov r12,[rbx+RR_OUT]
    mov rdi,[rbx+RR_IN]
    mov r13,[rbx+RR_WORK]
    test rsi,rsi
    jz sr_resample_bad
    test r12,r12
    jz sr_resample_bad
    test rdi,rdi
    jz sr_resample_bad
    test r13,r13
    jz sr_resample_bad
    cmp dword ptr [rbx+RR_STATE_CAP],RS_SIZE
    jb sr_resample_bad
    cmp dword ptr [rbx+RR_WORK_CAP],RR_WORK_SIZE
    jb sr_resample_bad
    mov eax,[rsi+RS_IN]
    cmp eax,8
    je sr_resample_in_ok
    cmp eax,12
    je sr_resample_in_ok
    cmp eax,16
    jne sr_resample_bad
sr_resample_in_ok:
    imul eax,1000
    mov [rsp+32+RI_IN],eax
    mov eax,[rsi+RS_OUT]
    cmp eax,8
    je sr_resample_out_ok
    cmp eax,12
    je sr_resample_out_ok
    cmp eax,16
    je sr_resample_out_ok
    cmp eax,24
    je sr_resample_out_ok
    cmp eax,48
    jne sr_resample_bad
sr_resample_out_ok:
    imul eax,1000
    mov [rsp+32+RI_OUT],eax
    lea rax,[rsp+128]
    mov [rsp+32+RI_STATE],rax
    mov dword ptr [rsp+32+RI_CAP],RS_SIZE
    lea rcx,[rsp+32]
    call op_silk_resampler_init
    ; Validate every immutable descriptor, including table identity, before
    ; following the state's coefficient pointer or changing caller buffers.
    xor ecx,ecx
sr_resample_descriptor:
    mov rax,[rsp+128+RS_FUNC+rcx*8]
    cmp rax,[rsi+RS_FUNC+rcx*8]
    jne sr_resample_bad
    inc ecx
    cmp ecx,5
    jb sr_resample_descriptor
    mov r14d,[rbx+RR_N]
    cmp [rbx+RR_IN_CAP],r14d
    jb sr_resample_bad
    mov eax,r14d
    xor edx,edx
    div dword ptr [rsi+RS_IN]
    test edx,edx
    jnz sr_resample_bad
    cmp eax,1
    jl sr_resample_bad
    cmp eax,60
    ja sr_resample_bad
    imul eax,[rsi+RS_OUT]
    mov r15d,eax
    cmp [rbx+RR_OUT_CAP],eax
    jb sr_resample_bad
    ; Prefix1 ms combines the prior delay with the new input.
    mov r8d,[rsi+RS_INPUT_DELAY]
    mov r9d,[rsi+RS_IN]
    sub r9d,r8d
    test r9d,r9d
    jz sr_resample_first_block
    lea r10,[rsi+RS_DELAY+r8*2]
    xor ecx,ecx
sr_resample_delay_fill:
    mov ax,[rdi+rcx*2]
    mov [r10+rcx*2],ax
    inc ecx
    cmp ecx,r9d
    jb sr_resample_delay_fill
sr_resample_first_block:
    mov [rsp+96],r9d
    mov [rsp+56],rsi
    mov [rsp+64],r12
    lea rax,[rsi+RS_DELAY]
    mov [rsp+72],rax
    mov [rsp+80],r13
    mov eax,[rsi+RS_IN]
    mov [rsp+88],eax
    lea rcx,[rsp+56]
    call sr_run
    mov ecx,[rsi+RS_OUT]
    lea rax,[r12+rcx*2]
    mov [rsp+64],rax
    mov ecx,[rsp+96]
    lea rax,[rdi+rcx*2]
    mov [rsp+72],rax
    mov eax,r14d
    sub eax,[rsi+RS_IN]
    mov [rsp+88],eax
    lea rcx,[rsp+56]
    call sr_run
    mov r8d,[rsi+RS_INPUT_DELAY]
    test r8d,r8d
    jz sr_resample_good
    mov eax,r14d
    sub eax,r8d
    lea r9,[rdi+rax*2]
    xor ecx,ecx
sr_resample_delay_save:
    mov ax,[r9+rcx*2]
    mov [rsi+RS_DELAY+rcx*2],ax
    inc ecx
    cmp ecx,r8d
    jb sr_resample_delay_save
sr_resample_good:
    mov eax,r15d
    jmp sr_resample_done
sr_resample_bad:
    xor eax,eax
sr_resample_done:
    add rsp,448
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_silk_resampler ENDP
END
