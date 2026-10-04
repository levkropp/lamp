; Handwritten float CELT PLC pitch downsample and two-pass search.
; RFC6716 pitch.c, BSD conditions in THIRD_PARTY_NOTICES.
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
; Jean-Marc Valin. Standard-mode history2048, pitch interval100..720.
option casemap:none
include opus_pitch_layout.inc
include opus_lpc_layout.inc
EXTERN op_celt_autocorr:PROC, op_celt_lpc:PROC, op_celt_fir:PROC
PUBLIC op_celt_pitch
.const
pp_half real4 0.5
pp_noise real4 1.0001
pp_lag real4 0.008
pp_damping real4 0.9
pp_emphasis real4 0.8
pp_one real4 1.0
pp_minus_one real4 -1.0
pp_interp real4 0.7
.code
; Internal exact best-two correlation/energy-ratio scan.
; RCX=xcorr, RDX=y, R8D=len, R9D=max_pitch -> EAX=best0, EDX=best1.
pp_find PROC
    sub rsp,56
    movups [rsp],xmm6
    movups [rsp+16],xmm7
    movups [rsp+32],xmm8
    movss xmm0,dword ptr [pp_minus_one]
    movaps xmm1,xmm0
    xorps xmm2,xmm2
    xorps xmm3,xmm3
    movss xmm4,dword ptr [pp_one]
    xor r10d,r10d
    mov r11d,1
    xor eax,eax
pp_find_energy:
    movss xmm5,dword ptr [rdx+rax*4]
    mulss xmm5,xmm5
    addss xmm4,xmm5
    inc eax
    cmp eax,r8d
    jb pp_find_energy
    xor eax,eax
pp_find_lag:
    xorps xmm5,xmm5
    comiss xmm5,dword ptr [rcx+rax*4]
    jae pp_find_slide
    movss xmm5,dword ptr [rcx+rax*4]
    mulss xmm5,xmm5            ; numerator
    movaps xmm6,xmm5
    mulss xmm6,xmm3
    movaps xmm7,xmm1
    mulss xmm7,xmm4
    comiss xmm6,xmm7
    jbe pp_find_slide
    movaps xmm6,xmm5
    mulss xmm6,xmm2
    movaps xmm7,xmm0
    mulss xmm7,xmm4
    comiss xmm6,xmm7
    jbe pp_find_second
    movaps xmm1,xmm0
    movaps xmm3,xmm2
    mov r11d,r10d
    movaps xmm0,xmm5
    movaps xmm2,xmm4
    mov r10d,eax
    jmp pp_find_slide
pp_find_second:
    movaps xmm1,xmm5
    movaps xmm3,xmm4
    mov r11d,eax
pp_find_slide:
    ; Syy += y[i+len]^2-y[i]^2, then max(1,Syy).
    movss xmm5,dword ptr [rdx+rax*4]
    mulss xmm5,xmm5
    ; Form index i+len without consuming the two best-index registers.
    movd xmm8,eax
    add eax,r8d
    movss xmm6,dword ptr [rdx+rax*4]
    mulss xmm6,xmm6
    subss xmm6,xmm5
    addss xmm4,xmm6
    maxss xmm4,dword ptr [pp_one]
    movd eax,xmm8
    inc eax
    cmp eax,r9d
    jb pp_find_lag
    mov eax,r10d
    mov edx,r11d
    movups xmm6,[rsp]
    movups xmm7,[rsp+16]
    movups xmm8,[rsp+32]
    add rsp,56
    ret
pp_find ENDP

; Request buffers immutable except workspace. EAX=pitch100..720 or0.
; All sample magnitude <=2^50; capacity/finite guards before writes.
op_celt_pitch PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,112
    mov rbx,rcx
    test rbx,rbx
    jz pp_bad
    mov rsi,[rbx+PP_LEFT]
    mov rdi,[rbx+PP_RIGHT]
    mov r12,[rbx+PP_WORK]
    test rsi,rsi
    jz pp_bad
    test r12,r12
    jz pp_bad
    cmp dword ptr [rbx+PP_INPUT_CAP],2048
    jb pp_bad
    cmp dword ptr [rbx+PP_WORK_CAP],PP_SIZE
    jb pp_bad
    mov eax,[rbx+PP_CHANNELS]
    cmp eax,1
    jb pp_bad
    cmp eax,2
    ja pp_bad
    jne pp_guard_left
    test rdi,rdi
    jz pp_bad
    xor ecx,ecx
pp_guard_right:
    mov eax,[rdi+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja pp_bad
    inc ecx
    cmp ecx,2048
    jb pp_guard_right
pp_guard_left:
    xor ecx,ecx
pp_guard_left_loop:
    mov eax,[rsi+rcx*4]
    and eax,7fffffffh
    cmp eax,58800000h
    ja pp_bad
    inc ecx
    cmp ecx,2048
    jb pp_guard_left_loop
    xor r13d,r13d
pp_downsample_channel:
    mov r14,rsi
    test r13d,r13d
    jz pp_downsample_first
    mov r14,rdi
pp_downsample_first:
    movss xmm0,dword ptr [r14+4]
    mulss xmm0,dword ptr [pp_half]
    addss xmm0,dword ptr [r14]
    mulss xmm0,dword ptr [pp_half]
    test r13d,r13d
    jz pp_lp_zero_store
    addss xmm0,dword ptr [r12+PW_LP]
pp_lp_zero_store:
    movss dword ptr [r12+PW_LP],xmm0
    mov ecx,1
pp_downsample:
    lea eax,[rcx+rcx]
    movss xmm0,dword ptr [r14+rax*4-4]
    addss xmm0,dword ptr [r14+rax*4+4]
    mulss xmm0,dword ptr [pp_half]
    addss xmm0,dword ptr [r14+rax*4]
    mulss xmm0,dword ptr [pp_half]
    test r13d,r13d
    jz pp_lp_store
    addss xmm0,dword ptr [r12+PW_LP+rcx*4]
pp_lp_store:
    movss dword ptr [r12+PW_LP+rcx*4],xmm0
    inc ecx
    cmp ecx,1024
    jb pp_downsample
    inc r13d
    cmp r13d,[rbx+PP_CHANNELS]
    jb pp_downsample_channel
    lea rax,[r12+PW_LP]
    mov [rsp+32+LA_X],rax
    lea rax,[r12+PW_AC]
    mov [rsp+32+LA_AC],rax
    mov qword ptr [rsp+32+LA_WINDOW],0
    lea rax,[r12+PW_AC_SCRATCH]
    mov [rsp+32+LA_SCRATCH],rax
    mov dword ptr [rsp+32+LA_N],1024
    mov dword ptr [rsp+32+LA_LAG],4
    mov dword ptr [rsp+32+LA_OVERLAP],0
    mov dword ptr [rsp+32+LA_X_CAP],1024
    mov dword ptr [rsp+32+LA_AC_CAP],5
    mov dword ptr [rsp+32+LA_WINDOW_CAP],0
    mov dword ptr [rsp+32+LA_SCRATCH_CAP],1024
    lea rcx,[rsp+32]
    call op_celt_autocorr
    test eax,eax
    jz pp_bad
    movss xmm0,dword ptr [r12+PW_AC]
    mulss xmm0,dword ptr [pp_noise]
    movss dword ptr [r12+PW_AC],xmm0
    mov ecx,1
pp_lag_window:
    cvtsi2ss xmm0,ecx
    mulss xmm0,dword ptr [pp_lag]
    movss xmm1,dword ptr [r12+PW_AC+rcx*4]
    movaps xmm2,xmm1
    mulss xmm2,xmm0
    mulss xmm2,xmm0
    subss xmm1,xmm2
    movss dword ptr [r12+PW_AC+rcx*4],xmm1
    inc ecx
    cmp ecx,4
    jbe pp_lag_window
    lea rax,[r12+PW_LPC]
    mov [rsp+32+LL_OUT],rax
    lea rax,[r12+PW_AC]
    mov [rsp+32+LL_AC],rax
    mov dword ptr [rsp+32+LL_ORDER],4
    mov dword ptr [rsp+32+LL_OUT_CAP],4
    mov dword ptr [rsp+32+LL_AC_CAP],5
    lea rcx,[rsp+32]
    call op_celt_lpc
    test eax,eax
    jz pp_bad
    movss xmm0,dword ptr [pp_one]
    xor ecx,ecx
pp_damp:
    mulss xmm0,dword ptr [pp_damping]
    movss xmm1,dword ptr [r12+PW_LPC+rcx*4]
    mulss xmm1,xmm0
    movss dword ptr [r12+PW_LPC+rcx*4],xmm1
    mov dword ptr [r12+PW_MEM+rcx*4],0
    inc ecx
    cmp ecx,4
    jb pp_damp
    lea rax,[r12+PW_LP]
    mov [rsp+32+LF_X],rax
    mov [rsp+32+LF_OUT],rax
    lea rax,[r12+PW_LPC]
    mov [rsp+32+LF_COEF],rax
    lea rax,[r12+PW_MEM]
    mov [rsp+32+LF_MEM],rax
    mov dword ptr [rsp+32+LF_N],1024
    mov dword ptr [rsp+32+LF_ORDER],4
    mov dword ptr [rsp+32+LF_X_CAP],1024
    mov dword ptr [rsp+32+LF_COEF_CAP],4
    mov dword ptr [rsp+32+LF_OUT_CAP],1024
    mov dword ptr [rsp+32+LF_MEM_CAP],4
    lea rcx,[rsp+32]
    call op_celt_fir
    test eax,eax
    jz pp_bad
    mov eax,dword ptr [pp_emphasis]
    mov [r12+PW_LPC],eax
    mov dword ptr [r12+PW_MEM],0
    mov dword ptr [rsp+32+LF_ORDER],1
    lea rcx,[rsp+32]
    call op_celt_fir
    test eax,eax
    jz pp_bad
    xor ecx,ecx
pp_decimate_x:
    lea eax,[rcx+rcx]
    mov eax,[r12+PW_LP+1440+rax*4]
    mov [r12+PW_X4+rcx*4],eax
    inc ecx
    cmp ecx,332
    jb pp_decimate_x
    xor ecx,ecx
pp_decimate_y:
    lea eax,[rcx+rcx]
    mov eax,[r12+PW_LP+rax*4]
    mov [r12+PW_Y4+rcx*4],eax
    inc ecx
    cmp ecx,487
    jb pp_decimate_y
    xor r13d,r13d
pp_coarse_lag:
    xorps xmm0,xmm0
    xor ecx,ecx
    lea r14,[r12+PW_Y4]
    lea r14,[r14+r13*4]
pp_coarse_sum:
    movss xmm1,dword ptr [r12+PW_X4+rcx*4]
    mulss xmm1,dword ptr [r14+rcx*4]
    addss xmm0,xmm1
    inc ecx
    cmp ecx,332
    jb pp_coarse_sum
    maxss xmm0,dword ptr [pp_minus_one]
    movss dword ptr [r12+PW_CORR+r13*4],xmm0
    inc r13d
    cmp r13d,155
    jb pp_coarse_lag
    lea rcx,[r12+PW_CORR]
    lea rdx,[r12+PW_Y4]
    mov r8d,332
    mov r9d,155
    call pp_find
    lea r14d,[rax+rax]
    lea r15d,[rdx+rdx]
    xor r13d,r13d
pp_fine_lag:
    mov dword ptr [r12+PW_CORR+r13*4],0
    mov eax,r13d
    sub eax,r14d
    add eax,2
    cmp eax,4
    jbe pp_fine_compute
    mov eax,r13d
    sub eax,r15d
    add eax,2
    cmp eax,4
    ja pp_fine_next
pp_fine_compute:
    xorps xmm0,xmm0
    xor ecx,ecx
    lea rdx,[r12+PW_LP]
    lea rdx,[rdx+r13*4]
pp_fine_sum:
    movss xmm1,dword ptr [r12+PW_LP+1440+rcx*4]
    mulss xmm1,dword ptr [rdx+rcx*4]
    addss xmm0,xmm1
    inc ecx
    cmp ecx,664
    jb pp_fine_sum
    maxss xmm0,dword ptr [pp_minus_one]
    movss dword ptr [r12+PW_CORR+r13*4],xmm0
pp_fine_next:
    inc r13d
    cmp r13d,310
    jb pp_fine_lag
    lea rcx,[r12+PW_CORR]
    lea rdx,[r12+PW_LP]
    mov r8d,664
    mov r9d,310
    call pp_find
    xor edx,edx
    test eax,eax
    jz pp_result
    cmp eax,309
    jae pp_result
    movss xmm0,dword ptr [r12+PW_CORR+rax*4-4] ; a
    movss xmm1,dword ptr [r12+PW_CORR+rax*4]   ; b
    movss xmm2,dword ptr [r12+PW_CORR+rax*4+4] ; c
    movaps xmm3,xmm2
    subss xmm3,xmm0
    movaps xmm4,xmm1
    subss xmm4,xmm0
    mulss xmm4,dword ptr [pp_interp]
    comiss xmm3,xmm4
    ja pp_offset_plus
    subss xmm0,xmm2
    subss xmm1,xmm2
    mulss xmm1,dword ptr [pp_interp]
    comiss xmm0,xmm1
    jbe pp_result
    mov edx,-1
    jmp pp_result
pp_offset_plus:
    mov edx,1
pp_result:
    add eax,eax
    sub eax,edx
    mov edx,720
    sub edx,eax
    mov eax,edx
    jmp pp_done
pp_bad:
    xor eax,eax
pp_done:
    add rsp,112
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_pitch ENDP
END
