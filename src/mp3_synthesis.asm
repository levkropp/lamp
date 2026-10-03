; Handwritten SSE2 hybrid and polyphase synthesis for MP3.
; Reference algorithms/coefficient data: dr_mp3 (MIT-0), notices preserved.
option casemap:none
include mp3_layout.inc
EXTERN mp_grbuf:DWORD, mp_overlap:DWORD, mp_qmf:DWORD, mp_syn:DWORD
EXTERN mp_twid9:DWORD, mp_mdct_win:DWORD, mp_twid3:DWORD
EXTERN mp_synth_win:DWORD, mp_dct9:DWORD, mp_dct_sec:DWORD
PUBLIC mp_hybrid, mp_synthesis

.const
half_f dd 3f000000h
sin60_f dd 3f5db3d7h
ALIGN 16
pcm_scale dd 4 dup (38000000h)
dct_c0 REAL4 4 dup (0.70710677)
dct_c1 REAL4 4 dup (0.198912367)
dct_c2 REAL4 4 dup (0.382683432)
dct_c3 REAL4 4 dup (0.50979561)
dct_c4 REAL4 4 dup (0.54119611)
dct_c5 REAL4 4 dup (0.60134488)
dct_c6 REAL4 4 dup (0.89997619)
dct_c7 REAL4 4 dup (1.30656302)
dct_c8 REAL4 4 dup (2.56291556)
pair_a dd 29,213,459,2037,5153,6574,37489,75038
pair_b dd 104,1567,9727,64019,-9975,-45,146,-5

.data?
dct9_temp dd 9 dup (?)
ALIGN 16
dct32_work dd 32*4 dup (?)

.code
; Nine-point DCT-III, original matrix evaluation with float SSE arithmetic.
mp_dct9_eval PROC
    xor r8d,r8d
    lea r9,mp_dct9
    lea r10,dct9_temp
dct9_row:
    xorps xmm0,xmm0
    xor edx,edx
dct9_sum:
    movss xmm1,dword ptr [rcx+rdx*4]
    mulss xmm1,dword ptr [r9+rdx*4]
    addss xmm0,xmm1
    inc edx
    cmp edx,9
    jb dct9_sum
    movss dword ptr [r10+r8*4],xmm0
    add r9,36
    inc r8d
    cmp r8d,9
    jb dct9_row
    xor edx,edx
dct9_copy:
    mov eax,[r10+rdx*4]
    mov [rcx+rdx*4],eax
    inc edx
    cmp edx,9
    jb dct9_copy
    ret
mp_dct9_eval ENDP

; RCX=18 spectra, RDX=9 overlap, R8=18 window coefficients.
mp_imdct36 PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,144
    mov rsi,rcx
    mov rdi,rdx
    mov r12,r8
    mov eax,[rsi]
    xor eax,80000000h
    mov [rsp+32],eax
    mov eax,[rsi+68]
    mov [rsp+80],eax
    xor ebx,ebx
imdct36_prepare:
    mov eax,ebx
    shl eax,2
    movss xmm0,dword ptr [rsi+rax*4+4]
    movss xmm1,dword ptr [rsi+rax*4+8]
    movaps xmm2,xmm0
    subss xmm0,xmm1
    addss xmm2,xmm1
    mov ecx,8
    sub ecx,ebx
    sub ecx,ebx
    movss dword ptr [rsp+rcx*4+80],xmm0
    lea ecx,[rbx+rbx+1]
    movss dword ptr [rsp+rcx*4+32],xmm2
    movss xmm0,dword ptr [rsi+rax*4+16]
    movss xmm1,dword ptr [rsi+rax*4+12]
    movaps xmm2,xmm0
    subss xmm0,xmm1
    addss xmm2,xmm1
    movd edx,xmm2
    xor edx,80000000h
    mov ecx,7
    sub ecx,ebx
    sub ecx,ebx
    movss dword ptr [rsp+rcx*4+80],xmm0
    lea ecx,[rbx+rbx+2]
    mov [rsp+rcx*4+32],edx
    inc ebx
    cmp ebx,4
    jb imdct36_prepare
    lea rcx,[rsp+32]
    call mp_dct9_eval
    lea rcx,[rsp+80]
    call mp_dct9_eval
    xor dword ptr [rsp+84],80000000h
    xor dword ptr [rsp+92],80000000h
    xor dword ptr [rsp+100],80000000h
    xor dword ptr [rsp+108],80000000h
    xor ebx,ebx
    lea r8,mp_twid9
imdct36_window:
    movss xmm0,dword ptr [rdi+rbx*4]
    movss xmm1,dword ptr [rsp+rbx*4+32]
    movss xmm2,dword ptr [rsp+rbx*4+80]
    movaps xmm3,xmm1
    movaps xmm4,xmm2
    mulss xmm1,dword ptr [r8+rbx*4+36]
    mulss xmm2,dword ptr [r8+rbx*4]
    addss xmm1,xmm2       ; sum
    mulss xmm3,dword ptr [r8+rbx*4]
    mulss xmm4,dword ptr [r8+rbx*4+36]
    subss xmm3,xmm4
    movss dword ptr [rdi+rbx*4],xmm3
    movaps xmm2,xmm0
    movaps xmm3,xmm1
    mulss xmm0,dword ptr [r12+rbx*4]
    mulss xmm1,dword ptr [r12+rbx*4+36]
    subss xmm0,xmm1
    mulss xmm2,dword ptr [r12+rbx*4+36]
    mulss xmm3,dword ptr [r12+rbx*4]
    addss xmm2,xmm3
    movss dword ptr [rsi+rbx*4],xmm0
    mov eax,17
    sub eax,ebx
    movss dword ptr [rsi+rax*4],xmm2
    inc ebx
    cmp ebx,9
    jb imdct36_window
    add rsp,144
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_imdct36 ENDP

; RCX=destination; XMM0..2 are x0,x1,x2.
mp_idct3 PROC
    mulss xmm1,dword ptr [sin60_f]
    movaps xmm3,xmm2
    mulss xmm3,dword ptr [half_f]
    movaps xmm4,xmm0
    subss xmm4,xmm3
    addss xmm0,xmm2
    movss dword ptr [rcx+4],xmm0
    movaps xmm0,xmm4
    addss xmm0,xmm1
    subss xmm4,xmm1
    movss dword ptr [rcx],xmm0
    movss dword ptr [rcx+8],xmm4
    ret
mp_idct3 ENDP

mp_imdct12 PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,80
    mov rsi,rcx
    mov rdi,rdx
    mov r12,r8
    mov eax,[rsi]
    xor eax,80000000h
    movd xmm0,eax
    movss xmm1,dword ptr [rsi+24]
    addss xmm1,dword ptr [rsi+12]
    movss xmm2,dword ptr [rsi+48]
    addss xmm2,dword ptr [rsi+36]
    lea rcx,[rsp+32]
    call mp_idct3
    movss xmm0,dword ptr [rsi+60]
    movss xmm1,dword ptr [rsi+48]
    subss xmm1,dword ptr [rsi+36]
    movss xmm2,dword ptr [rsi+24]
    subss xmm2,dword ptr [rsi+12]
    lea rcx,[rsp+48]
    call mp_idct3
    xor dword ptr [rsp+52],80000000h
    xor ebx,ebx
    lea r8,mp_twid3
imdct12_window:
    movss xmm0,dword ptr [r12+rbx*4]
    movss xmm1,dword ptr [rsp+rbx*4+32]
    movss xmm2,dword ptr [rsp+rbx*4+48]
    movaps xmm3,xmm1
    movaps xmm4,xmm2
    mulss xmm1,dword ptr [r8+rbx*4+12]
    mulss xmm2,dword ptr [r8+rbx*4]
    addss xmm1,xmm2
    mulss xmm3,dword ptr [r8+rbx*4]
    mulss xmm4,dword ptr [r8+rbx*4+12]
    subss xmm3,xmm4
    movss dword ptr [r12+rbx*4],xmm3
    mov eax,2
    sub eax,ebx
    movaps xmm2,xmm0
    movaps xmm3,xmm1
    mulss xmm0,dword ptr [r8+rax*4]
    mulss xmm1,dword ptr [r8+rax*4+12]
    subss xmm0,xmm1
    mulss xmm2,dword ptr [r8+rax*4+12]
    mulss xmm3,dword ptr [r8+rax*4]
    addss xmm2,xmm3
    movss dword ptr [rdi+rbx*4],xmm0
    mov eax,5
    sub eax,ebx
    movss dword ptr [rdi+rax*4],xmm2
    inc ebx
    cmp ebx,3
    jb imdct12_window
    add rsp,80
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_imdct12 ENDP

; RCX=spectrum, RDX=granule info, R8=9*32 overlap, R9D=mixed long bands.
mp_hybrid PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,128
    mov rsi,rcx
    mov rdi,r8
    mov r12,rdx
    mov [rsp+112],r9d
    xor ebx,ebx
hybrid_band:
    cmp dword ptr [r12+GI_BLOCK],2
    jne hybrid_long
    cmp ebx,[rsp+112]
    jb hybrid_long
    mov rdx,rsi
    xor eax,eax
hybrid_short_save:
    mov ecx,[rdx+rax*4]
    mov [rsp+rax*4+32],ecx
    inc eax
    cmp eax,18
    jb hybrid_short_save
    xor eax,eax
hybrid_short_overlap:
    mov ecx,[rdi+rax*4]
    mov [rsi+rax*4],ecx
    inc eax
    cmp eax,6
    jb hybrid_short_overlap
    lea rcx,[rsp+32]
    lea rdx,[rsi+24]
    lea r8,[rdi+24]
    call mp_imdct12
    lea rcx,[rsp+36]
    lea rdx,[rsi+48]
    lea r8,[rdi+24]
    call mp_imdct12
    lea rcx,[rsp+40]
    mov rdx,rdi
    lea r8,[rdi+24]
    call mp_imdct12
    jmp hybrid_next
hybrid_long:
    mov rcx,rsi
    mov rdx,rdi
    lea r8,mp_mdct_win
    cmp dword ptr [r12+GI_BLOCK],3
    jne hybrid_long_window
    cmp ebx,[rsp+112]
    jb hybrid_long_window
    add r8,72
hybrid_long_window:
    call mp_imdct36
hybrid_next:
    add rsi,72
    add rdi,36
    inc ebx
    cmp ebx,32
    jb hybrid_band
    add rsp,128
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_hybrid ENDP

; RCX=576 subband/time samples. Factored DCT-II over four time slots at once.
; The final vector has two live lanes; its other lanes are loaded as zero.
mp_dct32_eval PROC
    push rbx
    push rsi
    push rdi
    sub rsp,64
    movaps [rsp],xmm6
    movaps [rsp+16],xmm7
    movaps [rsp+32],xmm8
    movaps [rsp+48],xmm9
    mov rsi,rcx
    xor ebx,ebx
dct32_time:
    lea rdx,[rsi+rbx*4]
    lea r8,dct32_work
    lea r9,mp_dct_sec
    xor r10d,r10d
dct32_split:
    imul eax,r10d,72
    mov r11d,15
    sub r11d,r10d
    imul r11d,72
    cmp ebx,16
    jae dct32_load_two_a
    movups xmm0,[rdx+rax]
    movups xmm1,[rdx+r11]
    jmp dct32_load_b
dct32_load_two_a:
    movq xmm0,qword ptr [rdx+rax]
    movq xmm1,qword ptr [rdx+r11]
dct32_load_b:
    lea eax,[r10+16]
    imul eax,72
    mov r11d,31
    sub r11d,r10d
    imul r11d,72
    cmp ebx,16
    jae dct32_load_two_b
    movups xmm2,[rdx+rax]
    movups xmm3,[rdx+r11]
    jmp dct32_split_math
dct32_load_two_b:
    movq xmm2,qword ptr [rdx+rax]
    movq xmm3,qword ptr [rdx+r11]
dct32_split_math:
    movaps xmm4,xmm0
    addps xmm4,xmm3
    movaps xmm5,xmm1
    addps xmm5,xmm2
    subps xmm1,xmm2
    movss xmm8,dword ptr [r9]
    shufps xmm8,xmm8,0
    mulps xmm1,xmm8
    subps xmm0,xmm3
    movss xmm8,dword ptr [r9+4]
    shufps xmm8,xmm8,0
    mulps xmm0,xmm8
    movaps xmm2,xmm4
    addps xmm2,xmm5
    movaps [r8],xmm2
    subps xmm4,xmm5
    movss xmm8,dword ptr [r9+8]
    shufps xmm8,xmm8,0
    mulps xmm4,xmm8
    movaps [r8+128],xmm4
    movaps xmm2,xmm0
    addps xmm2,xmm1
    movaps [r8+256],xmm2
    subps xmm0,xmm1
    mulps xmm0,xmm8
    movaps [r8+384],xmm0
    add r8,16
    add r9,12
    inc r10d
    cmp r10d,8
    jb dct32_split
    lea r8,dct32_work
    mov edi,4
dct32_eight:
    movaps xmm0,[r8]
    movaps xmm1,[r8+16]
    movaps xmm2,[r8+32]
    movaps xmm3,[r8+48]
    movaps xmm4,[r8+64]
    movaps xmm5,[r8+80]
    movaps xmm6,[r8+96]
    movaps xmm7,[r8+112]
    movaps xmm8,xmm0
    subps xmm8,xmm7
    addps xmm0,xmm7
    movaps xmm9,xmm1
    subps xmm9,xmm6
    addps xmm1,xmm6
    movaps xmm7,xmm9
    movaps xmm9,xmm2
    subps xmm9,xmm5
    addps xmm2,xmm5
    movaps xmm6,xmm9
    movaps xmm9,xmm3
    subps xmm9,xmm4
    addps xmm3,xmm4
    movaps xmm5,xmm9
    movaps xmm9,xmm0
    subps xmm9,xmm3
    addps xmm0,xmm3
    movaps xmm4,xmm9
    movaps xmm9,xmm1
    subps xmm9,xmm2
    addps xmm1,xmm2
    movaps xmm3,xmm9
    movaps xmm9,xmm0
    addps xmm9,xmm1
    movaps [r8],xmm9
    subps xmm0,xmm1
    mulps xmm0,[dct_c0]
    movaps [r8+64],xmm0
    addps xmm5,xmm6
    addps xmm6,xmm7
    mulps xmm6,[dct_c0]
    addps xmm7,xmm8
    addps xmm3,xmm4
    mulps xmm3,[dct_c0]
    movaps xmm9,xmm7
    mulps xmm9,[dct_c1]
    subps xmm5,xmm9
    movaps xmm9,xmm5
    mulps xmm9,[dct_c2]
    addps xmm7,xmm9
    movaps xmm9,xmm7
    mulps xmm9,[dct_c1]
    subps xmm5,xmm9
    movaps xmm0,xmm8
    subps xmm0,xmm6
    addps xmm8,xmm6
    movaps xmm9,xmm8
    addps xmm9,xmm7
    mulps xmm9,[dct_c3]
    movaps [r8+16],xmm9
    movaps xmm9,xmm4
    addps xmm9,xmm3
    mulps xmm9,[dct_c4]
    movaps [r8+32],xmm9
    movaps xmm9,xmm0
    subps xmm9,xmm5
    mulps xmm9,[dct_c5]
    movaps [r8+48],xmm9
    addps xmm0,xmm5
    mulps xmm0,[dct_c6]
    movaps [r8+80],xmm0
    subps xmm4,xmm3
    mulps xmm4,[dct_c7]
    movaps [r8+96],xmm4
    subps xmm8,xmm7
    mulps xmm8,[dct_c8]
    movaps [r8+112],xmm8
    add r8,128
    dec edi
    jnz dct32_eight
    lea r8,dct32_work
    lea rdx,[rsi+rbx*4]
    mov edi,7
dct32_merge:
    movaps xmm0,[r8+384]
    addps xmm0,[r8+400]
    movaps xmm1,[r8+256]
    addps xmm1,xmm0
    movaps xmm2,[r8+128]
    addps xmm2,[r8+144]
    movaps xmm3,[r8+272]
    addps xmm3,xmm0
    movaps xmm4,[r8]
    cmp ebx,16
    jae dct32_store_two
    movups [rdx],xmm4
    movups [rdx+72],xmm1
    movups [rdx+144],xmm2
    movups [rdx+216],xmm3
    jmp dct32_merge_next
dct32_store_two:
    movq qword ptr [rdx],xmm4
    movq qword ptr [rdx+72],xmm1
    movq qword ptr [rdx+144],xmm2
    movq qword ptr [rdx+216],xmm3
dct32_merge_next:
    add r8,16
    add rdx,288
    dec edi
    jnz dct32_merge
    movaps xmm0,[r8]
    movaps xmm1,[r8+256]
    addps xmm1,[r8+384]
    movaps xmm2,[r8+128]
    movaps xmm3,[r8+384]
    cmp ebx,16
    jae dct32_last_two
    movups [rdx],xmm0
    movups [rdx+72],xmm1
    movups [rdx+144],xmm2
    movups [rdx+216],xmm3
    jmp dct32_next_time
dct32_last_two:
    movq qword ptr [rdx],xmm0
    movq qword ptr [rdx+72],xmm1
    movq qword ptr [rdx+144],xmm2
    movq qword ptr [rdx+216],xmm3
dct32_next_time:
    add ebx,4
    cmp ebx,18
    jb dct32_time
    movaps xmm6,[rsp]
    movaps xmm7,[rsp+16]
    movaps xmm8,[rsp+32]
    movaps xmm9,[rsp+48]
    add rsp,64
    pop rdi
    pop rsi
    pop rbx
    ret
mp_dct32_eval ENDP

; RCX=linear filter state at subband 15, RDX=stereo PCM sample 0 or 32.
mp_synth_pair PROC
    lea r8,pair_a
    mov r9,rcx
    xorps xmm0,xmm0
    xor r10d,r10d
pair_a_loop:
    mov eax,14
    sub eax,r10d
    shl eax,8
    movq xmm1,qword ptr [r9+rax]
    cmp r10d,7
    je pair_a_weight
    mov eax,r10d
    shl eax,8
    movq xmm2,qword ptr [r9+rax]
    test r10d,1
    jnz pair_a_add
    subps xmm1,xmm2
    jmp pair_a_weight
pair_a_add:
    addps xmm1,xmm2
pair_a_weight:
    cvtsi2ss xmm3,dword ptr [r8+r10*4]
    shufps xmm3,xmm3,0
    mulps xmm1,xmm3
    addps xmm0,xmm1
    inc r10d
    cmp r10d,8
    jb pair_a_loop
    mulps xmm0,xmmword ptr [pcm_scale]
    movq qword ptr [rdx],xmm0
    lea r8,pair_b
    xorps xmm0,xmm0
    xor r10d,r10d
pair_b_loop:
    mov eax,14
    sub eax,r10d
    sub eax,r10d
    shl eax,8
    movq xmm1,qword ptr [r9+rax+8]
    cvtsi2ss xmm3,dword ptr [r8+r10*4]
    shufps xmm3,xmm3,0
    mulps xmm1,xmm3
    addps xmm0,xmm1
    inc r10d
    cmp r10d,8
    jb pair_b_loop
    mulps xmm0,xmmword ptr [pcm_scale]
    movq qword ptr [rdx+128],xmm0
    ret
mp_synth_pair ENDP

; RCX=two successive time samples, RDX=64 stereo PCM frames, R8=history.
mp_synth_two PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    mov rsi,rcx
    mov rdi,rdx
    mov rbx,r8
    lea r12,[rbx+15*64*4]
    mov eax,[rsi+16*18*4]
    mov [r12+60*4],eax
    mov eax,[rsi+576*4+16*18*4]
    mov [r12+61*4],eax
    mov eax,[rsi]
    mov [r12+62*4],eax
    mov eax,[rsi+576*4]
    mov [r12+63*4],eax
    mov eax,[rsi+16*18*4+4]
    mov [r12+124*4],eax
    mov eax,[rsi+576*4+16*18*4+4]
    mov [r12+125*4],eax
    mov eax,[rsi+4]
    mov [r12+126*4],eax
    mov eax,[rsi+576*4+4]
    mov [r12+127*4],eax
    lea rcx,[rbx+60*4]
    mov rdx,rdi
    call mp_synth_pair
    lea rcx,[rbx+124*4]
    lea rdx,[rdi+256]
    call mp_synth_pair
    mov ebx,14
    lea r8,mp_synth_win
synth_band:
    mov r9d,ebx
    shl r9d,4
    lea r9,[r12+r9]
    mov eax,31
    sub eax,ebx
    imul eax,72
    mov ecx,[rsi+rax]
    mov [r9],ecx
    mov ecx,[rsi+rax+576*4]
    mov [r9+4],ecx
    mov ecx,[rsi+rax+4]
    mov [r9+8],ecx
    mov ecx,[rsi+rax+576*4+4]
    mov [r9+12],ecx
    mov eax,ebx
    inc eax
    imul eax,72
    mov ecx,[rsi+rax+4]
    mov [r9+256],ecx
    mov ecx,[rsi+rax+576*4+4]
    mov [r9+260],ecx
    mov ecx,[rsi+rax]
    mov [r9-256+8],ecx
    mov ecx,[rsi+rax+576*4]
    mov [r9-256+12],ecx
    xorps xmm0,xmm0       ; a
    xorps xmm1,xmm1       ; b
    xor r9d,r9d
    mov eax,ebx
    shl eax,4
    lea r10,[r12+rax]
    lea r11,[r10-15*256]
synth_weights:
    movups xmm2,[r10]
    movups xmm3,[r11]
    movss xmm4,dword ptr [r8]
    shufps xmm4,xmm4,0
    movss xmm5,dword ptr [r8+4]
    shufps xmm5,xmm5,0
    movups [rsp+32],xmm2
    movups [rsp+48],xmm3
    mulps xmm2,xmm5
    mulps xmm3,xmm4
    addps xmm2,xmm3
    addps xmm1,xmm2
    movups xmm2,[rsp+32]
    movups xmm3,[rsp+48]
    mulps xmm2,xmm4
    mulps xmm3,xmm5
    test r9d,1
    jnz synth_odd_weight
    subps xmm2,xmm3
    addps xmm0,xmm2
    jmp synth_next_weight
synth_odd_weight:
    subps xmm3,xmm2
    addps xmm0,xmm3
synth_next_weight:
    sub r10,256
    add r11,256
    add r8,8
    inc r9d
    cmp r9d,8
    jb synth_weights
    mulps xmm0,xmmword ptr [pcm_scale]
    mulps xmm1,xmmword ptr [pcm_scale]
    mov eax,15
    sub eax,ebx
    movq qword ptr [rdi+rax*8],xmm0
    mov eax,17
    add eax,ebx
    movq qword ptr [rdi+rax*8],xmm1
    movhlps xmm2,xmm0
    movhlps xmm3,xmm1
    mov eax,47
    sub eax,ebx
    movq qword ptr [rdi+rax*8],xmm2
    mov eax,49
    add eax,ebx
    movq qword ptr [rdi+rax*8],xmm3
    dec ebx
    jns synth_band
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_synth_two ENDP

; RCX=576 stereo PCM destination, EDX=source channels.
mp_synthesis PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,48
    mov r12,rcx
    mov [rsp+32],edx
    lea rcx,mp_grbuf
    call mp_dct32_eval
    cmp dword ptr [rsp+32],1
    je synthesis_mono
    lea rcx,mp_grbuf+576*4
    call mp_dct32_eval
    jmp synthesis_filter
synthesis_mono:
    lea rsi,mp_grbuf
    lea rdi,mp_grbuf+576*4
    mov ecx,576
    rep movsd
synthesis_filter:
    lea rsi,mp_qmf
    lea rdi,mp_syn
    mov ecx,960
    rep movsd
    xor ebx,ebx
synthesis_times:
    lea rcx,mp_grbuf
    lea rcx,[rcx+rbx*4]
    mov eax,ebx
    shl eax,8
    lea rdx,[r12+rax]
    lea r8,mp_syn
    add r8,rax
    call mp_synth_two
    add ebx,2
    cmp ebx,18
    jb synthesis_times
    lea rsi,mp_syn+18*64*4
    lea rdi,mp_qmf
    mov ecx,960
    rep movsd
    add rsp,48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_synthesis ENDP
END
