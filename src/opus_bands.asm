; RFC8251 updates: Copyright (c) 2017 IETF Trust, Jean-Marc Valin, Koen Vos.
; Handwritten normal-mode CELT spectral frame orchestration.
; Normative BSD RFC6716 quant_all_bands, see THIRD_PARTY_NOTICES.
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
option casemap:none
include opus_bands_layout.inc
include opus_band_layout.inc
EXTERN op_celt_band:PROC, op_ec_frac:PROC
PUBLIC op_celt_bands
.const
oa_ebands dw 0,1,2,3,4,5,6,7,8,10,12,14,16,20,24,28,34,40,48,60,78,100
oa_half real4 0.5
.code
AA_N EQU 144
AA_TELL EQU 148
AA_BUDGET EQU 152
AA_REMAIN EQU 156
AA_BAL EQU 160
AA_LOW_OFF EQU 164
AA_UPDATE EQU 168
AA_EFFECT EQU 172
AA_XCM EQU 176
AA_YCM EQU 180
AA_DUAL EQU 184
AA_BLOCK EQU 188
AA_POS EQU 192
AA_SIZE EQU 196
AA_FEND EQU 200

; RCX=request. EAX=1 success / 0 invalid or band failure.
; Caller buffers are nonoverlapping. Capacity/parameter guards precede writes.
; Reconstructs normalized spectral coefficients only; synthesis is separate.
op_celt_bands PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,208
    mov rbx,rcx
    test rbx,rbx
    jz oa_bad
    cmp qword ptr [rbx+OA_EC],0
    je oa_bad
    mov ecx,3
oa_pointer_guard:
    cmp qword ptr [rbx+rcx*8],0
    je oa_bad
    inc ecx
    cmp ecx,9
    jb oa_pointer_guard
    cmp qword ptr [rbx+OA_X],0
    je oa_bad
    mov r12d,[rbx+OA_START]
    cmp r12d,20
    ja oa_bad
    mov eax,[rbx+OA_END]
    cmp eax,21
    ja oa_bad
    cmp eax,r12d
    jle oa_bad
    cmp dword ptr [rbx+OA_LM],3
    ja oa_bad
    cmp dword ptr [rbx+OA_SHORT],1
    ja oa_bad
    cmp dword ptr [rbx+OA_SPREAD],3
    ja oa_bad
    cmp dword ptr [rbx+OA_DUAL],1
    ja oa_bad
    cmp dword ptr [rbx+OA_INTENSITY],21
    ja oa_bad
    cmp dword ptr [rbx+OA_TOTAL],81600
    ja oa_bad
    cmp dword ptr [rbx+OA_BALANCE],-81600
    jl oa_bad
    cmp dword ptr [rbx+OA_BALANCE],81600
    jg oa_bad
    mov eax,[rbx+OA_CODED]
    cmp eax,r12d
    jl oa_bad
    cmp eax,[rbx+OA_END]
    jg oa_bad
    mov ecx,[rbx+OA_LM]
    mov r13d,1
    shl r13d,cl
    imul eax,r13d,100
    mov [rsp+AA_SIZE],eax
    cmp [rbx+OA_X_CAP],eax
    jb oa_bad
    mov r14d,1
    xor r15d,r15d
    cmp qword ptr [rbx+OA_Y],0
    je oa_mono
    inc r14d
    cmp [rbx+OA_Y_CAP],eax
    jb oa_bad
    lea r15,[rax*4]
    add r15,[rbx+OA_NORM]
    jmp oa_capacities
oa_mono:
    cmp dword ptr [rbx+OA_DUAL],0
    jne oa_bad
oa_capacities:
    imul eax,r14d
    cmp [rbx+OA_NORM_CAP],eax
    jb oa_bad
    imul eax,r13d,22
    cmp [rbx+OA_SCRATCH_CAP],eax
    jb oa_bad
    imul eax,r14d,21
    cmp [rbx+OA_MASK_CAP],eax
    jb oa_bad
    mov eax,1
    cmp dword ptr [rbx+OA_SHORT],0
    cmovne eax,r13d
    mov [rsp+AA_BLOCK],eax
    ; Check all active TF decisions and pulse budgets before any band writes.
    mov r10,[rbx+OA_TF]
    mov r11,[rbx+OA_PULSES]
    mov edx,r12d
oa_array_guard:
    cmp dword ptr [r11+rdx*4],81600
    ja oa_bad
    mov r8d,[r10+rdx*4]
    cmp r8d,-3
    jl oa_bad
    cmp r8d,3
    jg oa_bad
    lea r9,oa_ebands
    movzx eax,word ptr [r9+rdx*2+2]
    movzx ecx,word ptr [r9+rdx*2]
    sub eax,ecx
    imul eax,r13d
    cmp eax,1
    je oa_array_next
    test r8d,r8d
    jle oa_guard_negative
    bsr ecx,dword ptr [rsp+AA_BLOCK]
    cmp r8d,ecx
    jg oa_bad
    jmp oa_array_next
oa_guard_negative:
    mov ecx,[rsp+AA_BLOCK]
    ; B is a power of two, so divide without disturbing the band index.
    bsr r9d,ecx
    xchg ecx,r9d
    shr eax,cl
    mov ecx,r9d
oa_guard_time:
    test r8d,r8d
    jz oa_array_next
    test eax,1
    jnz oa_array_next
    shr eax,1
    shl ecx,1
    cmp ecx,16
    ja oa_bad
    inc r8d
    jmp oa_guard_time
oa_array_next:
    inc edx
    cmp edx,[rbx+OA_END]
    jb oa_array_guard
    mov r8,[rbx+OA_EC]
    cmp dword ptr [r8+8],1275
    ja oa_bad
    cmp dword ptr [r8+8],0
    je oa_buffer_guard
    cmp qword ptr [r8],0
    je oa_bad
oa_buffer_guard:
    mov eax,[r8+28]
    cmp eax,[r8+8]
    ja oa_bad
    mov eax,[r8+12]
    cmp eax,[r8+8]
    ja oa_bad
    cmp dword ptr [r8+32],800000h
    jbe oa_bad
    cmp dword ptr [r8+32],80000000h
    ja oa_bad
    cmp dword ptr [r8+20],32
    ja oa_bad
    cmp dword ptr [r8+24],32768
    ja oa_bad
    ; Seed one immutable-input band request, replacing per-band fields below.
    mov rax,[rbx+OA_EC]
    mov [rsp+32+OB_EC],rax
    lea rax,[rsp+AA_REMAIN]
    mov [rsp+32+OB_REMAIN],rax
    mov rax,[rbx+OA_SEED]
    mov [rsp+32+OB_SEED],rax
    mov rax,[rbx+OA_SCRATCH]
    mov [rsp+32+OB_SCRATCH],rax
    mov eax,[rbx+OA_LM]
    mov [rsp+32+OB_LM],eax
    mov eax,[rbx+OA_SPREAD]
    mov [rsp+32+OB_SPREAD],eax
    mov eax,[rsp+AA_BLOCK]
    mov [rsp+32+OB_BLOCKS],eax
    mov eax,[rbx+OA_INTENSITY]
    mov [rsp+32+OB_INTENSITY],eax
    mov dword ptr [rsp+32+OB_LEVEL],0
    mov dword ptr [rsp+32+OB_GAIN],3f800000h
    mov eax,[rbx+OA_BALANCE]
    mov [rsp+AA_BAL],eax
    mov eax,[rbx+OA_DUAL]
    mov [rsp+AA_DUAL],eax
    mov dword ptr [rsp+AA_LOW_OFF],0
    mov dword ptr [rsp+AA_UPDATE],1
oa_band_loop:
    lea rdx,oa_ebands
    movzx eax,word ptr [rdx+r12*2]
    imul eax,r13d
    mov [rsp+AA_POS],eax
    movzx ecx,word ptr [rdx+r12*2+2]
    imul ecx,r13d
    sub ecx,eax
    mov [rsp+AA_N],ecx
    mov [rsp+32+OB_N],ecx
    mov [rsp+32+OB_BAND],r12d
    lea rsi,[rax*4]
    add rsi,[rbx+OA_X]
    xor edi,edi
    cmp r14d,2
    jne oa_band_pointers
    lea rdi,[rax*4]
    add rdi,[rbx+OA_Y]
oa_band_pointers:
    mov rcx,[rbx+OA_EC]
    call op_ec_frac
    mov [rsp+AA_TELL],eax
    cmp r12d,[rbx+OA_START]
    je oa_band_remaining
    sub [rsp+AA_BAL],eax
oa_band_remaining:
    mov edx,[rbx+OA_TOTAL]
    sub edx,eax
    dec edx
    mov [rsp+AA_REMAIN],edx
    xor eax,eax
    cmp r12d,[rbx+OA_CODED]
    jge oa_band_budget_ready
    mov ecx,[rbx+OA_CODED]
    sub ecx,r12d
    mov eax,3
    cmp ecx,eax
    cmovg ecx,eax
    mov eax,[rsp+AA_BAL]
    cdq
    idiv ecx
    mov rdx,[rbx+OA_PULSES]
    add eax,[rdx+r12*4]
    mov edx,[rsp+AA_REMAIN]
    inc edx
    cmp eax,edx
    cmovg eax,edx
    mov edx,16383
    cmp eax,edx
    cmovg eax,edx
    xor edx,edx
    cmp eax,edx
    cmovl eax,edx
oa_band_budget_ready:
    mov [rsp+AA_BUDGET],eax
    mov [rsp+32+OB_BUDGET],eax
    lea rdx,oa_ebands
    mov ecx,[rbx+OA_START]
    movzx ecx,word ptr [rdx+rcx*2]
    imul ecx,r13d
    mov eax,[rsp+AA_POS]
    sub eax,[rsp+AA_N]
    cmp eax,ecx
    jge oa_lowband_candidate
    mov eax,[rbx+OA_START]
    inc eax
    cmp r12d,eax
    jne oa_lowband_selected
oa_lowband_candidate:
    cmp dword ptr [rsp+AA_UPDATE],0
    jne oa_lowband_update
    cmp dword ptr [rsp+AA_LOW_OFF],0
    jne oa_lowband_selected
oa_lowband_update:
    mov [rsp+AA_LOW_OFF],r12d
oa_lowband_selected:
    ; RFC8251: duplicate the tail of the first hybrid band for folding into
    ; the wider second band. CELT-only bands have equal widths and copy zero.
    mov ecx,[rbx+OA_START]
    lea eax,[rcx+1]
    cmp r12d,eax
    jne oa_fold_duplicate_done
    lea rdx,oa_ebands
    movzx r8d,word ptr [rdx+rcx*2]       ;offset / M
    movzx r9d,word ptr [rdx+rcx*2+2]
    movzx r10d,word ptr [rdx+rcx*2+4]
    sub r10d,r9d                      ;n2 / M
    sub r9d,r8d                       ;n1 / M
    imul r8d,r13d
    imul r9d,r13d
    imul r10d,r13d
    sub r10d,r9d                      ;copy count n2-n1
    lea ecx,[r8+r9]                    ;destination offset+n1
    mov eax,ecx
    sub eax,r10d                      ;source offset+2*n1-n2
    mov rdx,[rbx+OA_NORM]
oa_fold_duplicate:
    test r10d,r10d
    jle oa_fold_duplicate_done
    mov r8d,[rdx+rax*4]
    mov [rdx+rcx*4],r8d
    cmp r14d,2
    jne oa_fold_duplicate_next
    mov r8d,[r15+rax*4]
    mov [r15+rcx*4],r8d
oa_fold_duplicate_next:
    inc eax
    inc ecx
    dec r10d
    jmp oa_fold_duplicate
oa_fold_duplicate_done:
    mov rdx,[rbx+OA_TF]
    mov eax,[rdx+r12*4]
    mov [rsp+32+OB_TF],eax
    mov dword ptr [rsp+AA_EFFECT],-1
    mov ecx,[rsp+AA_BLOCK]
    mov eax,1
    shl eax,cl
    dec eax
    mov [rsp+AA_XCM],eax
    mov [rsp+AA_YCM],eax
    cmp dword ptr [rsp+AA_LOW_OFF],0
    je oa_fold_ready
    cmp dword ptr [rbx+OA_SPREAD],3
    jne oa_fold_masks
    cmp dword ptr [rsp+AA_BLOCK],1
    ja oa_fold_masks
    cmp dword ptr [rsp+32+OB_TF],0
    jge oa_fold_ready
oa_fold_masks:
    lea rdx,oa_ebands
    mov ecx,[rbx+OA_START]
    movzx eax,word ptr [rdx+rcx*2]
    imul eax,r13d
    mov ecx,[rsp+AA_LOW_OFF]
    movzx r8d,word ptr [rdx+rcx*2]
    imul r8d,r13d
    sub r8d,[rsp+AA_N]
    cmp r8d,eax
    cmovl r8d,eax
    mov [rsp+AA_EFFECT],r8d
oa_fold_start:
    dec ecx
    movzx eax,word ptr [rdx+rcx*2]
    imul eax,r13d
    cmp eax,r8d
    jg oa_fold_start
    mov r9d,[rsp+AA_LOW_OFF]
    dec r9d
    add r8d,[rsp+AA_N]
oa_fold_end:
    inc r9d
    cmp r9d,r12d
    jge oa_fold_end_ready
    movzx eax,word ptr [rdx+r9*2]
    imul eax,r13d
    cmp eax,r8d
    jl oa_fold_end
oa_fold_end_ready:
    mov rdx,[rbx+OA_MASKS]
    xor r8d,r8d
    xor r10d,r10d
oa_fold_mask_loop:
    mov eax,ecx
    imul eax,r14d
    movzx r11d,byte ptr [rdx+rax]
    or r8d,r11d
    add eax,r14d
    dec eax
    movzx r11d,byte ptr [rdx+rax]
    or r10d,r11d
    inc ecx
    cmp ecx,r9d
    jl oa_fold_mask_loop
    mov [rsp+AA_XCM],r8d
    mov [rsp+AA_YCM],r10d
oa_fold_ready:
    cmp dword ptr [rsp+AA_DUAL],0
    je oa_setup_band
    cmp r12d,[rbx+OA_INTENSITY]
    jne oa_setup_band
    mov dword ptr [rsp+AA_DUAL],0
    lea rdx,oa_ebands
    mov ecx,[rbx+OA_START]
    movzx ecx,word ptr [rdx+rcx*2]
    imul ecx,r13d
    mov rdx,[rbx+OA_NORM]
oa_mix_norm:
    cmp ecx,[rsp+AA_POS]
    jae oa_setup_band
    movss xmm0,dword ptr [rdx+rcx*4]
    addss xmm0,dword ptr [r15+rcx*4]
    mulss xmm0,dword ptr [oa_half]
    movss dword ptr [rdx+rcx*4],xmm0
    inc ecx
    jmp oa_mix_norm
oa_setup_band:
    mov [rsp+32+OB_X],rsi
    mov rax,[rbx+OA_NORM]
    mov edx,[rsp+AA_POS]
    lea rax,[rax+rdx*4]
    mov [rsp+32+OB_OUT],rax
    xor eax,eax
    mov edx,[rsp+AA_EFFECT]
    test edx,edx
    js oa_setup_low
    mov rax,[rbx+OA_NORM]
    lea rax,[rax+rdx*4]
oa_setup_low:
    mov [rsp+32+OB_LOW],rax
    cmp dword ptr [rsp+AA_DUAL],0
    jne oa_dual_bands
    mov [rsp+32+OB_Y],rdi
    mov eax,[rsp+AA_XCM]
    or eax,[rsp+AA_YCM]
    mov [rsp+32+OB_FILL],eax
    lea rcx,[rsp+32]
    call op_celt_band
    test eax,eax
    jz oa_bad
    mov eax,[rsp+32+OB_CM]
    mov [rsp+AA_XCM],eax
    mov [rsp+AA_YCM],eax
    jmp oa_band_masks
oa_dual_bands:
    mov qword ptr [rsp+32+OB_Y],0
    sar dword ptr [rsp+32+OB_BUDGET],1
    mov eax,[rsp+AA_XCM]
    mov [rsp+32+OB_FILL],eax
    lea rcx,[rsp+32]
    call op_celt_band
    test eax,eax
    jz oa_bad
    mov eax,[rsp+32+OB_CM]
    mov [rsp+AA_XCM],eax
    mov [rsp+32+OB_X],rdi
    mov edx,[rsp+AA_POS]
    lea rax,[r15+rdx*4]
    mov [rsp+32+OB_OUT],rax
    xor eax,eax
    mov edx,[rsp+AA_EFFECT]
    test edx,edx
    js oa_dual_low
    lea rax,[r15+rdx*4]
oa_dual_low:
    mov [rsp+32+OB_LOW],rax
    mov eax,[rsp+AA_YCM]
    mov [rsp+32+OB_FILL],eax
    lea rcx,[rsp+32]
    call op_celt_band
    test eax,eax
    jz oa_bad
    mov eax,[rsp+32+OB_CM]
    mov [rsp+AA_YCM],eax
oa_band_masks:
    mov rdx,[rbx+OA_MASKS]
    mov eax,r12d
    imul eax,r14d
    mov ecx,[rsp+AA_XCM]
    mov [rdx+rax],cl
    add eax,r14d
    dec eax
    mov ecx,[rsp+AA_YCM]
    mov [rdx+rax],cl
    mov rdx,[rbx+OA_PULSES]
    mov eax,[rdx+r12*4]
    add eax,[rsp+AA_TELL]
    add [rsp+AA_BAL],eax
    mov eax,[rsp+AA_N]
    shl eax,3
    cmp [rsp+AA_BUDGET],eax
    setg al
    movzx eax,al
    mov [rsp+AA_UPDATE],eax
    inc r12d
    cmp r12d,[rbx+OA_END]
    jl oa_band_loop
    mov eax,[rsp+AA_BAL]
    mov [rbx+OA_BALANCE_OUT],eax
    mov eax,[rsp+AA_REMAIN]
    mov [rbx+OA_REMAIN_OUT],eax
    mov eax,1
    jmp oa_done
oa_bad:
    xor eax,eax
oa_done:
    add rsp,208
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
op_celt_bands ENDP
END
