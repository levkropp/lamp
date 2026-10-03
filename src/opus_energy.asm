; Original x86-64 CELT Laplace and coarse/fine energy reconstruction.
; Reference algorithms and probability data: RFC6716 laplace.c/quant_bands.c.
; BSD reference notice: THIRD_PARTY_NOTICES. No C runtime dependencies.
option casemap:none
EXTERN op_ec_bin:PROC, op_ec_update:PROC, op_ec_icdf:PROC
EXTERN op_ec_logp:PROC, op_ec_bits:PROC, op_ec_tell:PROC
PUBLIC op_laplace_decode, op_celt_coarse, op_celt_fine, op_celt_final
; Energy context (64 bytes): ec*q0, oldE*q8, fine*q16, priority*q24,
; start d32, end d36, channels d40, LM d44, intra d48, bits_left d52,
; number_of_bands d56. All parameters are validated by the packet decoder.
.const
op_energy_pred real4 0.8984375,0.796875,0.6484375,0.5
op_energy_beta real4 0.920013427734375,0.67999267578125,0.3699951171875,0.20001220703125
op_energy_intra real4 0.149993896484375
op_energy_floor real4 -9.0
op_energy_half real4 0.5
op_small_energy db 2,1,0
op_energy_prob db 72,127,65,129,66,128,65,128,64,128,62,128,64,128
    db 64,128,92,78,92,79,92,78,90,79,116,41,115,40
    db 114,40,132,26,132,26,145,17,161,12,176,10,177,11
    db 24,179,48,138,54,135,54,132,53,134,56,133,55,132
    db 55,132,61,114,70,96,74,88,75,88,87,74,89,66
    db 91,67,100,59,108,50,120,40,122,37,97,43,78,50
    db 83,78,84,81,88,75,86,74,87,71,90,73,93,74
    db 93,74,109,40,114,36,117,34,117,34,143,17,145,18
    db 146,19,162,12,165,10,178,7,189,6,190,8,177,9
    db 23,178,54,115,63,102,66,98,69,99,74,89,71,91
    db 73,91,78,89,86,80,92,66,93,64,102,59,103,60
    db 104,60,117,52,123,44,138,35,133,31,97,38,77,45
    db 61,90,93,60,105,42,107,41,110,45,116,38,113,38
    db 112,38,124,26,132,27,136,19,140,20,155,14,159,16
    db 158,18,170,13,177,10,187,8,192,6,175,9,159,10
    db 21,178,59,110,71,86,75,85,84,83,91,66,88,73
    db 87,72,92,75,98,72,105,58,107,54,115,52,114,55
    db 112,56,129,51,132,40,150,33,140,29,98,35,77,42
    db 42,121,96,66,108,43,111,40,117,44,123,32,120,36
    db 119,33,127,33,134,34,139,21,147,23,152,20,158,25
    db 154,26,166,21,173,16,184,13,184,10,150,13,139,15
    db 22,178,63,114,74,82,84,83,92,82,103,62,96,72
    db 96,67,101,73,107,72,113,55,118,52,125,52,118,52
    db 117,55,135,49,137,39,157,32,145,29,97,33,77,40
.code
; RCX=ec_dec, EDX=frequency of zero, R8D=decay -> signed energy delta.
op_laplace_decode PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp,40
    mov rbx,rcx
    mov esi,edx
    mov edi,r8d
    mov edx,15
    call op_ec_bin
    mov r12d,eax
    xor r13d,r13d
    xor r14d,r14d
    cmp r12d,esi
    jb op_laplace_update
    mov r14d,1
    mov r13d,esi
    mov eax,32736
    sub eax,esi
    mov ecx,16384
    sub ecx,edi
    imul eax,ecx
    shr eax,15
    lea esi,[rax+1]
op_laplace_decay:
    cmp esi,1
    jbe op_laplace_tail
    lea eax,[r13+rsi*2]
    cmp r12d,eax
    jb op_laplace_sign
    shl esi,1
    add r13d,esi
    sub esi,2
    imul esi,edi
    shr esi,15
    inc esi
    inc r14d
    jmp op_laplace_decay
op_laplace_tail:
    mov eax,r12d
    sub eax,r13d
    shr eax,1
    add r14d,eax
    lea r13d,[r13+rax*2]
op_laplace_sign:
    lea eax,[r13+rsi]
    cmp r12d,eax
    jae op_laplace_positive
    neg r14d
    jmp op_laplace_update
op_laplace_positive:
    add r13d,esi
op_laplace_update:
    mov rcx,rbx
    mov edx,r13d
    lea r8d,[r13+rsi]
    mov r9d,32768
    cmp r8d,r9d
    cmova r8d,r9d
    call op_ec_update
    mov eax,r14d
    add rsp,40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_laplace_decode ENDP

op_celt_coarse PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,96
    mov rbx,rcx
    mov rsi,[rbx]
    mov rdi,[rbx+8]
    mov r12d,[rbx+32]
    mov r13d,[rbx+36]
    mov r14d,[rbx+40]
    mov r15d,[rbx+56]
    mov qword ptr [rsp+64],0 ; predictors for the two channels
    mov eax,[rbx+44]
    cmp dword ptr [rbx+48],0
    jne op_coarse_intra
    lea rcx,op_energy_pred
    mov edx,[rcx+rax*4]
    mov [rsp+72],edx
    lea rcx,op_energy_beta
    mov edx,[rcx+rax*4]
    mov [rsp+76],edx
    imul eax,84
    jmp op_coarse_model
op_coarse_intra:
    mov dword ptr [rsp+72],0
    mov edx,[op_energy_intra]
    mov [rsp+76],edx
    imul eax,84
    add eax,42
op_coarse_model:
    lea rcx,op_energy_prob
    add rcx,rax
    mov [rsp+80],rcx
    mov eax,[rsi+8]
    shl eax,3
    mov [rsp+88],eax
op_coarse_band:
    cmp r12d,r13d
    jae op_coarse_done
    mov dword ptr [rsp+56],0
op_coarse_channel:
    mov rcx,rsi
    call op_ec_tell
    mov edx,[rsp+88]
    sub edx,eax
    cmp edx,15
    jl op_coarse_small
    mov eax,r12d
    mov ecx,20
    cmp eax,ecx
    cmova eax,ecx
    mov rcx,[rsp+80]
    movzx edx,byte ptr [rcx+rax*2]
    movzx r8d,byte ptr [rcx+rax*2+1]
    shl edx,7
    shl r8d,6
    mov rcx,rsi
    call op_laplace_decode
    jmp op_coarse_reconstruct
op_coarse_small:
    cmp edx,2
    jl op_coarse_bit
    mov rcx,rsi
    lea rdx,op_small_energy
    mov r8d,2
    call op_ec_icdf
    mov edx,eax
    and edx,1
    neg edx
    shr eax,1
    xor eax,edx
    jmp op_coarse_reconstruct
op_coarse_bit:
    cmp edx,1
    jl op_coarse_no_bits
    mov rcx,rsi
    mov edx,1
    call op_ec_logp
    neg eax
    jmp op_coarse_reconstruct
op_coarse_no_bits:
    mov eax,-1
op_coarse_reconstruct:
    cvtsi2ss xmm0,eax
    mov edx,[rsp+56]
    mov eax,edx
    imul eax,r15d
    add eax,r12d
    movss xmm1,dword ptr [rdi+rax*4]
    maxss xmm1,[op_energy_floor]
    mulss xmm1,dword ptr [rsp+72]
    addss xmm1,dword ptr [rsp+rdx*4+64]
    addss xmm1,xmm0
    movss dword ptr [rdi+rax*4],xmm1
    movaps xmm2,xmm0
    mulss xmm2,dword ptr [rsp+76]
    addss xmm0,dword ptr [rsp+rdx*4+64]
    subss xmm0,xmm2
    movss dword ptr [rsp+rdx*4+64],xmm0
    inc edx
    mov [rsp+56],edx
    cmp edx,r14d
    jb op_coarse_channel
    inc r12d
    jmp op_coarse_band
op_coarse_done:
    add rsp,96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_coarse ENDP

op_celt_fine PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,64
    mov rbx,rcx
    mov rsi,[rbx]
    mov rdi,[rbx+8]
    mov r12d,[rbx+32]
    mov r13d,[rbx+36]
    mov r14d,[rbx+40]
    mov r15d,[rbx+56]
op_fine_band:
    cmp r12d,r13d
    jae op_fine_done
    mov rax,[rbx+16]
    mov edx,[rax+r12*4]
    test edx,edx
    jle op_fine_next
    mov [rsp+48],edx
    mov eax,127
    sub eax,edx
    shl eax,23
    mov [rsp+52],eax         ; exact 2^-fine_bits
    mov dword ptr [rsp+56],0
op_fine_channel:
    mov rcx,rsi
    mov edx,[rsp+48]
    call op_ec_bits
    cvtsi2ss xmm0,eax
    addss xmm0,[op_energy_half]
    mulss xmm0,dword ptr [rsp+52]
    subss xmm0,[op_energy_half]
    mov eax,[rsp+56]
    imul eax,r15d
    add eax,r12d
    addss xmm0,dword ptr [rdi+rax*4]
    movss dword ptr [rdi+rax*4],xmm0
    inc dword ptr [rsp+56]
    mov eax,[rsp+56]
    cmp eax,r14d
    jb op_fine_channel
op_fine_next:
    inc r12d
    jmp op_fine_band
op_fine_done:
    add rsp,64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_fine ENDP

op_celt_final PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,64
    mov rbx,rcx
    mov rsi,[rbx]
    mov rdi,[rbx+8]
    mov r13d,[rbx+36]
    mov r14d,[rbx+40]
    mov r15d,[rbx+56]
    mov dword ptr [rsp+60],0
op_final_priority:
    mov r12d,[rbx+32]
op_final_band:
    cmp r12d,r13d
    jae op_final_next_priority
    cmp [rbx+52],r14d
    jl op_final_done
    mov rax,[rbx+16]
    mov edx,[rax+r12*4]
    cmp edx,8
    jae op_final_next
    mov rax,[rbx+24]
    mov eax,[rax+r12*4]
    cmp eax,[rsp+60]
    jne op_final_next
    mov eax,126
    sub eax,edx
    shl eax,23
    mov [rsp+52],eax
    mov dword ptr [rsp+56],0
op_final_channel:
    mov rcx,rsi
    mov edx,1
    call op_ec_bits
    cvtsi2ss xmm0,eax
    subss xmm0,[op_energy_half]
    mulss xmm0,dword ptr [rsp+52]
    mov eax,[rsp+56]
    imul eax,r15d
    add eax,r12d
    addss xmm0,dword ptr [rdi+rax*4]
    movss dword ptr [rdi+rax*4],xmm0
    dec dword ptr [rbx+52]
    inc dword ptr [rsp+56]
    mov eax,[rsp+56]
    cmp eax,r14d
    jb op_final_channel
op_final_next:
    inc r12d
    jmp op_final_band
op_final_next_priority:
    inc dword ptr [rsp+60]
    cmp dword ptr [rsp+60],2
    jb op_final_priority
op_final_done:
    add rsp,64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_final ENDP
END
