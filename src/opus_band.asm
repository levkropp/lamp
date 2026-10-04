; Handwritten x86-64 CELT recursive band reconstruction, folding and stereo.
; Normative RFC6716 bands.c/rate.h algorithms and mode data (BSD).
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
; Gregory Maxwell. See THIRD_PARTY_NOTICES. Reference C is test-only.
option casemap:none
include opus_band_layout.inc
include opus_theta_layout.inc
EXTERN op_celt_theta:PROC, op_celt_bits2pulses:PROC, op_celt_pulses2bits:PROC
EXTERN op_celt_unquant:PROC, op_celt_renormalize:PROC
EXTERN op_celt_haar:PROC, op_celt_reorder:PROC, op_ec_bits:PROC
PUBLIC op_celt_band
.const
include opus_celt_tables.inc
ob_one real4 1.0
ob_q15 real4 0.000030517578125
ob_dither real4 0.00390625
ob_merge_floor real4 0.0006
ob_interleave db 0,1,1,1,2,3,3,3,2,3,3,3,2,3,3,3
ob_deinterleave db 00h,03h,0ch,0fh,30h,33h,3ch,3fh,0c0h,0c3h,0cch,0cfh,0f0h,0f3h,0fch,0ffh
.code
; RCX=request. EAX=1 success, 0 invalid/helper failure; collapse mask at +108.
; Normal-mode dimensions and all public guards are checked before decoding.
; Finite lowband data has |value|<=32 (normal folding output is <=sqrt(N)).
; Caller buffers must not overlap except that X/Y may be adjacent. A lowband
; requires distinct scratch. Existing PVQ/reorder kernels use one decode owner.
op_celt_band PROC
    test rcx,rcx
    jz ob_public_bad
    cmp qword ptr [rcx+OB_X],0
    je ob_public_bad
    cmp qword ptr [rcx+OB_REMAIN],0
    je ob_public_bad
    cmp qword ptr [rcx+OB_SEED],0
    je ob_public_bad
    cmp dword ptr [rcx+OB_LEVEL],0
    jne ob_public_bad
    cmp dword ptr [rcx+OB_BUDGET],16383
    ja ob_public_bad
    mov eax,[rcx+OB_GAIN]
    cmp eax,3f800000h
    ja ob_public_bad
    cmp dword ptr [rcx+OB_SPREAD],3
    ja ob_public_bad
    cmp dword ptr [rcx+OB_INTENSITY],21
    ja ob_public_bad
    mov edx,[rcx+OB_LM]
    cmp edx,3
    ja ob_public_bad
    mov r8d,[rcx+OB_BAND]
    cmp r8d,20
    ja ob_public_bad
    lea r9,op_celt_ebands
    movzx eax,word ptr [r9+r8*2+2]
    movzx r8d,word ptr [r9+r8*2]
    sub eax,r8d
    mov r10,rcx
    mov ecx,edx
    shl eax,cl
    mov rcx,r10
    cmp eax,[rcx+OB_N]
    jne ob_public_bad
    mov r8d,[rcx+OB_BLOCKS]
    test r8d,r8d
    jz ob_public_bad
    lea r9d,[r8-1]
    test r8d,r9d
    jnz ob_public_bad
    mov r9d,1
    mov r10,rcx
    mov ecx,edx
    shl r9d,cl
    mov rcx,r10
    cmp r8d,r9d
    ja ob_public_bad
    xor edx,edx
    div r8d
    test edx,edx
    jnz ob_public_bad
    ; Limit time resolution to the normative maximum of sixteen blocks.
    mov r9d,[rcx+OB_TF]
    cmp r9d,-3
    jl ob_public_bad
    cmp r9d,3
    jg ob_public_bad
    cmp dword ptr [rcx+OB_N],1
    je ob_public_tf_done
    test r9d,r9d
    jle ob_public_time
    bsr edx,r8d
    cmp r9d,edx
    jg ob_public_bad
    jmp ob_public_tf_done
ob_public_time:
    test r9d,r9d
    jz ob_public_tf_done
    test eax,1
    jnz ob_public_tf_done
    shr eax,1
    shl r8d,1
    cmp r8d,16
    ja ob_public_bad
    inc r9d
    jmp ob_public_time
ob_public_tf_done:
    mov r10,rcx
    mov ecx,[r10+OB_BLOCKS]
    mov eax,1
    shl eax,cl
    dec eax
    mov rcx,r10
    cmp [rcx+OB_FILL],eax
    ja ob_public_bad
    mov r8,[rcx+OB_REMAIN]
    cmp dword ptr [r8],-81600
    jl ob_public_bad
    cmp dword ptr [r8],81600
    jg ob_public_bad
    mov r8,[rcx+OB_LOW]
    test r8,r8
    jz ob_public_ec
    cmp qword ptr [rcx+OB_SCRATCH],0
    je ob_public_bad
    xor edx,edx
ob_public_low:
    mov eax,[r8+rdx*4]
    and eax,7fffffffh
    cmp eax,42000000h
    ja ob_public_bad
    inc edx
    cmp edx,[rcx+OB_N]
    jb ob_public_low
ob_public_ec:
    mov r8,[rcx+OB_EC]
    test r8,r8
    jz ob_public_bad
    cmp dword ptr [r8+8],1275
    ja ob_public_bad
    cmp dword ptr [r8+8],0
    je ob_public_buffer
    cmp qword ptr [r8],0
    je ob_public_bad
ob_public_buffer:
    mov eax,[r8+28]
    cmp eax,[r8+8]
    ja ob_public_bad
    mov eax,[r8+12]
    cmp eax,[r8+8]
    ja ob_public_bad
    cmp dword ptr [r8+32],800000h
    jbe ob_public_bad
    cmp dword ptr [r8+32],80000000h
    ja ob_public_bad
    cmp dword ptr [r8+20],32
    ja ob_public_bad
    cmp dword ptr [r8+24],32768
    ja ob_public_bad
    push rbx
    sub rsp,32
    mov rbx,rcx
    call ob_band_core
    test eax,eax
    js ob_public_failed
    mov [rbx+OB_CM],eax
    mov eax,1
    jmp ob_public_done
ob_public_failed:
    xor eax,eax
ob_public_done:
    add rsp,32
    pop rbx
    ret
ob_public_bad:
    xor eax,eax
    ret
op_celt_band ENDP

; Stack: shadow[32], local request[112], scalar state[96], child[112],
; theta[88], PVQ[40], reorder[24]. Each recursive frame is under one page.
BB_N0 EQU 144
BB_NB EQU 148
BB_NB0 EQU 152
BB_B0 EQU 156
BB_TIME EQU 160
BB_RECOMB EQU 164
BB_LONG EQU 168
BB_STEREO EQU 172
BB_SPLIT EQU 176
BB_CM EQU 180
BB_MID EQU 184
BB_SIDE EQU 188
BB_ANGLE EQU 192
BB_INV EQU 196
BB_MB EQU 200
BB_SB EQU 204
BB_REBAL EQU 208
BB_SHIFT EQU 212
BB_ORIG_FILL EQU 216
BB_ITER EQU 220
BB_Q EQU 224
BB_COST EQU 228
BB_SIGN EQU 232
BB_CHILD EQU 240
BB_THETA EQU 352
BB_VQ EQU 440
BB_ORDER EQU 480

; RCX=internal request. EAX=mask or -1. Input request is immutable.
ob_band_core PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,512
    mov rsi,rcx
    lea rdi,[rsp+32]
    mov ecx,14
    rep movsq
    lea rbx,[rsp+32]
    mov rsi,[rbx+OB_X]
    mov rdi,[rbx+OB_Y]
    mov eax,[rbx+OB_N]
    mov [rsp+BB_N0],eax
    xor edx,edx
    div dword ptr [rbx+OB_BLOCKS]
    mov [rsp+BB_NB],eax
    mov [rsp+BB_NB0],eax
    mov eax,[rbx+OB_BLOCKS]
    mov [rsp+BB_B0],eax
    cmp eax,1
    sete al
    movzx eax,al
    mov [rsp+BB_LONG],eax
    xor eax,eax
    mov [rsp+BB_TIME],eax
    mov [rsp+BB_RECOMB],eax
    mov [rsp+BB_CM],eax
    mov [rsp+BB_INV],eax
    test rdi,rdi
    setnz al
    mov [rsp+BB_STEREO],eax
    mov [rsp+BB_SPLIT],eax
    cmp dword ptr [rbx+OB_N],1
    jne ob_band_transform
    xor r12d,r12d
ob_band_single:
    xor eax,eax
    mov r13,[rbx+OB_REMAIN]
    cmp dword ptr [r13],8
    jl ob_band_single_store
    mov rcx,[rbx+OB_EC]
    mov edx,1
    call op_ec_bits
    sub dword ptr [r13],8
ob_band_single_store:
    shl eax,31
    or eax,3f800000h
    test r12d,r12d
    jnz ob_band_single_y
    mov [rsi],eax
    inc r12d
    cmp dword ptr [rsp+BB_STEREO],0
    jne ob_band_single
    jmp ob_band_single_out
ob_band_single_y:
    mov [rdi],eax
ob_band_single_out:
    mov rax,[rbx+OB_OUT]
    test rax,rax
    jz ob_band_single_done
    mov edx,[rsi]
    mov [rax],edx
ob_band_single_done:
    mov eax,1
    jmp ob_band_done

ob_band_transform:
    cmp dword ptr [rsp+BB_STEREO],0
    jne ob_band_split_test
    cmp dword ptr [rbx+OB_LEVEL],0
    jne ob_band_split_test
    mov eax,[rbx+OB_TF]
    test eax,eax
    jle ob_band_copy_test
    mov [rsp+BB_RECOMB],eax
ob_band_copy_test:
    mov r12,[rbx+OB_LOW]
    test r12,r12
    jz ob_band_recombine
    cmp dword ptr [rsp+BB_RECOMB],0
    jne ob_band_copy_low
    cmp dword ptr [rsp+BB_B0],1
    ja ob_band_copy_low
    test dword ptr [rsp+BB_NB],1
    jnz ob_band_recombine
    cmp dword ptr [rbx+OB_TF],0
    jge ob_band_recombine
ob_band_copy_low:
    mov r13,[rbx+OB_SCRATCH]
    test r13,r13
    jz ob_band_bad
    xor edx,edx
ob_band_copy_loop:
    mov eax,[r12+rdx*4]
    mov [r13+rdx*4],eax
    inc edx
    cmp edx,[rbx+OB_N]
    jb ob_band_copy_loop
    mov [rbx+OB_LOW],r13
ob_band_recombine:
    mov dword ptr [rsp+BB_ITER],0
ob_band_recombine_loop:
    mov ecx,[rsp+BB_ITER]
    cmp ecx,[rsp+BB_RECOMB]
    jae ob_band_recombine_finish
    mov r12,[rbx+OB_LOW]
    test r12,r12
    jz ob_band_recombine_fill
    mov edx,[rbx+OB_N]
    shr edx,cl
    mov r8d,1
    shl r8d,cl
    mov rcx,r12
    call op_celt_haar
    test eax,eax
    jz ob_band_bad
ob_band_recombine_fill:
    mov eax,[rbx+OB_FILL]
    mov edx,eax
    and edx,15
    shr eax,4
    lea r8,ob_interleave
    movzx edx,byte ptr [r8+rdx]
    movzx eax,byte ptr [r8+rax]
    shl eax,2
    or eax,edx
    mov [rbx+OB_FILL],eax
    inc dword ptr [rsp+BB_ITER]
    jmp ob_band_recombine_loop
ob_band_recombine_finish:
    mov ecx,[rsp+BB_RECOMB]
    shr dword ptr [rbx+OB_BLOCKS],cl
    shl dword ptr [rsp+BB_NB],cl
ob_band_time_loop:
    test dword ptr [rsp+BB_NB],1
    jnz ob_band_time_finish
    cmp dword ptr [rbx+OB_TF],0
    jge ob_band_time_finish
    mov rcx,[rbx+OB_LOW]
    test rcx,rcx
    jz ob_band_time_fill
    mov edx,[rsp+BB_NB]
    mov r8d,[rbx+OB_BLOCKS]
    call op_celt_haar
    test eax,eax
    jz ob_band_bad
ob_band_time_fill:
    mov eax,[rbx+OB_FILL]
    mov ecx,[rbx+OB_BLOCKS]
    shl eax,cl
    or [rbx+OB_FILL],eax
    shl dword ptr [rbx+OB_BLOCKS],1
    shr dword ptr [rsp+BB_NB],1
    inc dword ptr [rsp+BB_TIME]
    inc dword ptr [rbx+OB_TF]
    jmp ob_band_time_loop
ob_band_time_finish:
    mov eax,[rbx+OB_BLOCKS]
    mov [rsp+BB_B0],eax
    mov eax,[rsp+BB_NB]
    mov [rsp+BB_NB0],eax
    cmp dword ptr [rsp+BB_B0],1
    jbe ob_band_split_test
    mov rax,[rbx+OB_LOW]
    test rax,rax
    jz ob_band_split_test
    mov [rsp+BB_ORDER],rax
    mov ecx,[rsp+BB_RECOMB]
    mov eax,[rsp+BB_NB]
    shr eax,cl
    mov [rsp+BB_ORDER+8],eax
    mov eax,[rsp+BB_B0]
    shl eax,cl
    mov [rsp+BB_ORDER+12],eax
    mov eax,[rsp+BB_LONG]
    mov [rsp+BB_ORDER+16],eax
    mov dword ptr [rsp+BB_ORDER+20],0
    lea rcx,[rsp+BB_ORDER]
    call op_celt_reorder
    test eax,eax
    jz ob_band_bad

ob_band_split_test:
    cmp dword ptr [rsp+BB_STEREO],0
    jne ob_band_theta
    cmp dword ptr [rbx+OB_LM],-1
    je ob_band_leaf
    cmp dword ptr [rbx+OB_N],2
    jbe ob_band_leaf
    mov eax,[rbx+OB_LM]
    inc eax
    imul eax,21
    add eax,[rbx+OB_BAND]
    lea rdx,op_celt_cache_index
    movsx eax,word ptr [rdx+rax*2]
    lea rdx,op_celt_cache_bits
    add rdx,rax
    movzx eax,byte ptr [rdx]
    movzx eax,byte ptr [rdx+rax]
    add eax,12
    cmp [rbx+OB_BUDGET],eax
    jle ob_band_leaf
    shr dword ptr [rbx+OB_N],1
    mov eax,[rbx+OB_N]
    lea rdi,[rsi+rax*4]
    mov [rbx+OB_Y],rdi
    mov dword ptr [rsp+BB_SPLIT],1
    dec dword ptr [rbx+OB_LM]
    cmp dword ptr [rbx+OB_BLOCKS],1
    jne ob_band_split_blocks
    mov eax,[rbx+OB_FILL]
    lea edx,[rax+rax]
    and eax,1
    or eax,edx
    mov [rbx+OB_FILL],eax
ob_band_split_blocks:
    inc dword ptr [rbx+OB_BLOCKS]
    shr dword ptr [rbx+OB_BLOCKS],1
ob_band_theta:
    mov rax,[rbx+OB_EC]
    mov [rsp+BB_THETA+OTT_EC],rax
    mov rax,[rbx+OB_REMAIN]
    mov [rsp+BB_THETA+OTT_REMAINING],rax
    mov eax,[rbx+OB_N]
    mov [rsp+BB_THETA+OTT_N],eax
    mov eax,[rbx+OB_BUDGET]
    mov [rsp+BB_THETA+OTT_BUDGET],eax
    mov eax,[rbx+OB_BAND]
    mov [rsp+BB_THETA+OTT_BAND],eax
    mov eax,[rbx+OB_LM]
    mov [rsp+BB_THETA+OTT_LM],eax
    mov eax,[rsp+BB_STEREO]
    mov [rsp+BB_THETA+OTT_STEREO],eax
    mov eax,[rbx+OB_BLOCKS]
    mov [rsp+BB_THETA+OTT_BLOCKS],eax
    mov eax,[rsp+BB_B0]
    mov [rsp+BB_THETA+OTT_ORIGINAL_BLOCKS],eax
    mov eax,[rbx+OB_INTENSITY]
    mov [rsp+BB_THETA+OTT_INTENSITY],eax
    mov eax,[rbx+OB_FILL]
    mov [rsp+BB_THETA+OTT_FILL],eax
    mov [rsp+BB_ORIG_FILL],eax
    lea rcx,[rsp+BB_THETA]
    call op_celt_theta
    test eax,eax
    jz ob_band_bad
    mov eax,[rsp+BB_THETA+OTT_ANGLE]
    mov [rsp+BB_ANGLE],eax
    cvtsi2ss xmm0,dword ptr [rsp+BB_THETA+OTT_MID]
    mulss xmm0,dword ptr [ob_q15]
    movss dword ptr [rsp+BB_MID],xmm0
    cvtsi2ss xmm0,dword ptr [rsp+BB_THETA+OTT_SIDE]
    mulss xmm0,dword ptr [ob_q15]
    movss dword ptr [rsp+BB_SIDE],xmm0
    mov eax,[rsp+BB_THETA+OTT_INVERT]
    mov [rsp+BB_INV],eax
    mov eax,[rsp+BB_THETA+OTT_OUTPUT_FILL]
    mov [rbx+OB_FILL],eax
    mov eax,[rsp+BB_THETA+OTT_COST]
    sub [rbx+OB_BUDGET],eax
    cmp dword ptr [rsp+BB_STEREO],0
    je ob_band_normal_split
    cmp dword ptr [rbx+OB_N],2
    jne ob_band_normal_split
    ; Orthogonal N=2 stereo side uses just one raw sign bit.
    mov r12,rsi
    mov r13,rdi
    cmp dword ptr [rsp+BB_ANGLE],8192
    jle ob_band_two_pointers
    xchg r12,r13
ob_band_two_pointers:
    mov eax,[rbx+OB_BUDGET]
    mov [rsp+BB_MB],eax
    mov dword ptr [rsp+BB_SIGN],1
    mov r14,[rbx+OB_REMAIN]
    mov eax,[rsp+BB_THETA+OTT_COST]
    sub [r14],eax
    cmp dword ptr [rsp+BB_ANGLE],0
    je ob_band_two_child
    cmp dword ptr [rsp+BB_ANGLE],16384
    je ob_band_two_child
    sub dword ptr [r14],8
    sub dword ptr [rsp+BB_MB],8
    mov rcx,[rbx+OB_EC]
    mov edx,1
    call op_ec_bits
    lea eax,[rax+rax]
    neg eax
    inc eax
    mov [rsp+BB_SIGN],eax
ob_band_two_child:
    call ob_child_copy
    mov [rsp+BB_CHILD+OB_X],r12
    mov qword ptr [rsp+BB_CHILD+OB_Y],0
    mov eax,[rsp+BB_MB]
    mov [rsp+BB_CHILD+OB_BUDGET],eax
    mov eax,[rsp+BB_ORIG_FILL]
    mov [rsp+BB_CHILD+OB_FILL],eax
    lea rcx,[rsp+BB_CHILD]
    call ob_band_core
    test eax,eax
    js ob_band_bad
    mov [rsp+BB_CM],eax
    cvtsi2ss xmm2,dword ptr [rsp+BB_SIGN]
    movss xmm0,dword ptr [r12+4]
    mulss xmm0,xmm2
    movd eax,xmm0
    xor eax,80000000h
    mov [r13],eax
    movss xmm0,dword ptr [r12]
    mulss xmm0,xmm2
    movss dword ptr [r13+4],xmm0
    xor ecx,ecx
ob_band_two_mix:
    movss xmm0,dword ptr [rsi+rcx*4]
    mulss xmm0,dword ptr [rsp+BB_MID]
    movss xmm1,dword ptr [rdi+rcx*4]
    mulss xmm1,dword ptr [rsp+BB_SIDE]
    movaps xmm2,xmm0
    subss xmm0,xmm1
    addss xmm2,xmm1
    movss dword ptr [rsi+rcx*4],xmm0
    movss dword ptr [rdi+rcx*4],xmm2
    inc ecx
    cmp ecx,2
    jb ob_band_two_mix
    jmp ob_band_finish

ob_band_normal_split:
    mov edx,[rsp+BB_THETA+OTT_DELTA]
    cmp dword ptr [rsp+BB_B0],1
    jbe ob_band_split_budget
    cmp dword ptr [rsp+BB_STEREO],0
    jne ob_band_split_budget
    test dword ptr [rsp+BB_ANGLE],3fffh
    jz ob_band_split_budget
    cmp dword ptr [rsp+BB_ANGLE],8192
    jle ob_band_forward_mask
    mov ecx,4
    sub ecx,[rbx+OB_LM]
    mov eax,edx
    sar eax,cl
    sub edx,eax
    jmp ob_band_split_budget
ob_band_forward_mask:
    mov eax,[rbx+OB_N]
    shl eax,3
    mov ecx,5
    sub ecx,[rbx+OB_LM]
    sar eax,cl
    add edx,eax
    xor eax,eax
    cmp edx,eax
    cmovg edx,eax
ob_band_split_budget:
    mov eax,[rbx+OB_BUDGET]
    sub eax,edx
    ; Signed /2 truncates toward zero, unlike an arithmetic shift alone.
    mov edx,eax
    shr edx,31
    add eax,edx
    sar eax,1
    cmp eax,[rbx+OB_BUDGET]
    cmovg eax,[rbx+OB_BUDGET]
    xor edx,edx
    cmp eax,edx
    cmovl eax,edx
    mov [rsp+BB_MB],eax
    mov edx,[rbx+OB_BUDGET]
    sub edx,eax
    mov [rsp+BB_SB],edx
    mov r12,[rbx+OB_REMAIN]
    mov eax,[rsp+BB_THETA+OTT_COST]
    sub [r12],eax
    mov eax,[r12]
    mov [rsp+BB_REBAL],eax
    mov eax,[rsp+BB_STEREO]
    dec eax
    mov edx,[rsp+BB_B0]
    shr edx,1
    and eax,edx
    mov [rsp+BB_SHIFT],eax
    mov eax,[rsp+BB_MB]
    cmp eax,[rsp+BB_SB]
    jl ob_band_side_first
    call ob_decode_mid
    test eax,eax
    js ob_band_bad
    mov [rsp+BB_CM],eax
    mov eax,[rsp+BB_REBAL]
    sub eax,[r12]
    mov edx,[rsp+BB_MB]
    sub edx,eax
    cmp edx,24
    jle ob_band_mid_rebalanced
    cmp dword ptr [rsp+BB_ANGLE],0
    je ob_band_mid_rebalanced
    sub edx,24
    add [rsp+BB_SB],edx
ob_band_mid_rebalanced:
    call ob_decode_side
    test eax,eax
    js ob_band_bad
    mov ecx,[rsp+BB_SHIFT]
    shl eax,cl
    or [rsp+BB_CM],eax
    jmp ob_band_finish
ob_band_side_first:
    call ob_decode_side
    test eax,eax
    js ob_band_bad
    mov ecx,[rsp+BB_SHIFT]
    shl eax,cl
    mov [rsp+BB_CM],eax
    mov eax,[rsp+BB_REBAL]
    sub eax,[r12]
    mov edx,[rsp+BB_SB]
    sub edx,eax
    cmp edx,24
    jle ob_band_side_rebalanced
    cmp dword ptr [rsp+BB_ANGLE],16384
    je ob_band_side_rebalanced
    sub edx,24
    add [rsp+BB_MB],edx
ob_band_side_rebalanced:
    call ob_decode_mid
    test eax,eax
    js ob_band_bad
    or [rsp+BB_CM],eax
    jmp ob_band_finish

ob_band_leaf:
    mov ecx,[rbx+OB_BAND]
    mov edx,[rbx+OB_LM]
    mov r8d,[rbx+OB_BUDGET]
    xor eax,eax
    test r8d,r8d
    cmovs r8d,eax
    call op_celt_bits2pulses
    test eax,eax
    js ob_band_bad
    mov [rsp+BB_Q],eax
ob_band_leaf_cost:
    mov r8d,[rsp+BB_Q]
    mov ecx,[rbx+OB_BAND]
    mov edx,[rbx+OB_LM]
    call op_celt_pulses2bits
    test eax,eax
    js ob_band_bad
    mov [rsp+BB_COST],eax
    mov r12,[rbx+OB_REMAIN]
    sub [r12],eax
    cmp dword ptr [r12],0
    jge ob_band_leaf_ready
    cmp dword ptr [rsp+BB_Q],0
    je ob_band_leaf_ready
    add [r12],eax
    dec dword ptr [rsp+BB_Q]
    jmp ob_band_leaf_cost
ob_band_leaf_ready:
    mov eax,[rsp+BB_Q]
    test eax,eax
    jz ob_band_fold
    cmp eax,8
    jl ob_band_pulses_ready
    mov ecx,eax
    shr ecx,3
    dec ecx
    and eax,7
    add eax,8
    shl eax,cl
ob_band_pulses_ready:
    mov [rsp+BB_VQ+20],eax
    mov [rsp+BB_VQ],rsi
    mov rax,[rbx+OB_EC]
    mov [rsp+BB_VQ+8],rax
    mov eax,[rbx+OB_N]
    mov [rsp+BB_VQ+16],eax
    mov eax,[rbx+OB_SPREAD]
    mov [rsp+BB_VQ+24],eax
    mov eax,[rbx+OB_BLOCKS]
    mov [rsp+BB_VQ+28],eax
    mov eax,[rbx+OB_GAIN]
    mov [rsp+BB_VQ+32],eax
    lea rcx,[rsp+BB_VQ]
    call op_celt_unquant
    test eax,eax
    jz ob_band_bad
    mov eax,[rsp+BB_VQ+36]
    mov [rsp+BB_CM],eax
    jmp ob_band_finish
ob_band_fold:
    mov ecx,[rbx+OB_BLOCKS]
    mov eax,1
    shl eax,cl
    dec eax
    mov r13d,eax
    and [rbx+OB_FILL],eax
    cmp dword ptr [rbx+OB_FILL],0
    jne ob_band_fold_nonzero
    xor ecx,ecx
ob_band_zero_loop:
    mov dword ptr [rsi+rcx*4],0
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_zero_loop
    jmp ob_band_finish
ob_band_fold_nonzero:
    mov r12,[rbx+OB_SEED]
    mov r14,[rbx+OB_LOW]
    mov eax,[r12]
    xor ecx,ecx
    test r14,r14
    jnz ob_band_dither_loop
    mov [rsp+BB_CM],r13d
ob_band_noise_loop:
    imul eax,eax,1664525
    add eax,1013904223
    mov edx,eax
    sar edx,20
    cvtsi2ss xmm0,edx
    movss dword ptr [rsi+rcx*4],xmm0
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_noise_loop
    jmp ob_band_fold_norm
ob_band_dither_loop:
    imul eax,eax,1664525
    add eax,1013904223
    mov edx,3b800000h
    test eax,8000h
    jnz ob_band_dither_value
    or edx,80000000h
ob_band_dither_value:
    movd xmm0,edx
    addss xmm0,dword ptr [r14+rcx*4]
    movss dword ptr [rsi+rcx*4],xmm0
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_dither_loop
    mov edx,[rbx+OB_FILL]
    mov [rsp+BB_CM],edx
ob_band_fold_norm:
    mov [r12],eax
    mov rcx,rsi
    mov edx,[rbx+OB_N]
    movss xmm2,dword ptr [rbx+OB_GAIN]
    call op_celt_renormalize
    test eax,eax
    jz ob_band_bad

ob_band_finish:
    cmp dword ptr [rsp+BB_STEREO],0
    je ob_band_undo
    cmp dword ptr [rbx+OB_N],2
    je ob_band_invert
    ; Accumulate in scalar reference order, then normalize left/right.
    xorps xmm0,xmm0
    xorps xmm1,xmm1
    xor ecx,ecx
ob_band_merge_energy:
    movss xmm2,dword ptr [rsi+rcx*4]
    movss xmm3,dword ptr [rdi+rcx*4]
    mulss xmm2,xmm3
    mulss xmm3,xmm3
    addss xmm0,xmm2
    addss xmm1,xmm3
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_merge_energy
    movss xmm2,dword ptr [rsp+BB_MID]
    mulss xmm0,xmm2
    addss xmm0,xmm0
    mulss xmm2,xmm2
    addss xmm2,xmm1
    movaps xmm3,xmm2
    subss xmm2,xmm0
    addss xmm3,xmm0
    comiss xmm2,dword ptr [ob_merge_floor]
    jb ob_band_merge_copy
    comiss xmm3,dword ptr [ob_merge_floor]
    jb ob_band_merge_copy
    sqrtss xmm2,xmm2
    sqrtss xmm3,xmm3
    movss xmm4,dword ptr [ob_one]
    movaps xmm5,xmm4
    divss xmm4,xmm2
    divss xmm5,xmm3
    xor ecx,ecx
ob_band_merge_loop:
    movss xmm0,dword ptr [rsi+rcx*4]
    mulss xmm0,dword ptr [rsp+BB_MID]
    movss xmm1,dword ptr [rdi+rcx*4]
    movaps xmm2,xmm0
    subss xmm0,xmm1
    addss xmm2,xmm1
    mulss xmm0,xmm4
    mulss xmm2,xmm5
    movss dword ptr [rsi+rcx*4],xmm0
    movss dword ptr [rdi+rcx*4],xmm2
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_merge_loop
    jmp ob_band_invert
ob_band_merge_copy:
    xor ecx,ecx
ob_band_merge_copy_loop:
    mov eax,[rsi+rcx*4]
    mov [rdi+rcx*4],eax
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_merge_copy_loop
ob_band_invert:
    cmp dword ptr [rsp+BB_INV],0
    je ob_band_result
    xor ecx,ecx
ob_band_invert_loop:
    xor dword ptr [rdi+rcx*4],80000000h
    inc ecx
    cmp ecx,[rbx+OB_N]
    jb ob_band_invert_loop
    jmp ob_band_result

ob_band_undo:
    cmp dword ptr [rbx+OB_LEVEL],0
    jne ob_band_result
    cmp dword ptr [rsp+BB_B0],1
    jbe ob_band_undo_time_init
    mov [rsp+BB_ORDER],rsi
    mov ecx,[rsp+BB_RECOMB]
    mov eax,[rsp+BB_NB]
    shr eax,cl
    mov [rsp+BB_ORDER+8],eax
    mov eax,[rsp+BB_B0]
    shl eax,cl
    mov [rsp+BB_ORDER+12],eax
    mov eax,[rsp+BB_LONG]
    mov [rsp+BB_ORDER+16],eax
    mov dword ptr [rsp+BB_ORDER+20],1
    lea rcx,[rsp+BB_ORDER]
    call op_celt_reorder
    test eax,eax
    jz ob_band_bad
ob_band_undo_time_init:
    mov eax,[rsp+BB_NB0]
    mov [rsp+BB_NB],eax
    mov eax,[rsp+BB_B0]
    mov [rbx+OB_BLOCKS],eax
    mov dword ptr [rsp+BB_ITER],0
ob_band_undo_time:
    mov eax,[rsp+BB_ITER]
    cmp eax,[rsp+BB_TIME]
    jae ob_band_undo_recomb_init
    shr dword ptr [rbx+OB_BLOCKS],1
    shl dword ptr [rsp+BB_NB],1
    mov ecx,[rbx+OB_BLOCKS]
    mov eax,[rsp+BB_CM]
    shr eax,cl
    or [rsp+BB_CM],eax
    mov rcx,rsi
    mov edx,[rsp+BB_NB]
    mov r8d,[rbx+OB_BLOCKS]
    call op_celt_haar
    test eax,eax
    jz ob_band_bad
    inc dword ptr [rsp+BB_ITER]
    jmp ob_band_undo_time
ob_band_undo_recomb_init:
    mov dword ptr [rsp+BB_ITER],0
ob_band_undo_recomb:
    mov ecx,[rsp+BB_ITER]
    cmp ecx,[rsp+BB_RECOMB]
    jae ob_band_output
    mov eax,[rsp+BB_CM]
    lea rdx,ob_deinterleave
    movzx eax,byte ptr [rdx+rax]
    mov [rsp+BB_CM],eax
    mov edx,[rsp+BB_N0]
    shr edx,cl
    mov r8d,1
    shl r8d,cl
    mov rcx,rsi
    call op_celt_haar
    test eax,eax
    jz ob_band_bad
    inc dword ptr [rsp+BB_ITER]
    jmp ob_band_undo_recomb
ob_band_output:
    mov ecx,[rsp+BB_RECOMB]
    shl dword ptr [rbx+OB_BLOCKS],cl
    mov r12,[rbx+OB_OUT]
    test r12,r12
    jz ob_band_mask
    cvtsi2ss xmm1,dword ptr [rsp+BB_N0]
    sqrtss xmm1,xmm1
    xor ecx,ecx
ob_band_output_loop:
    movss xmm0,dword ptr [rsi+rcx*4]
    mulss xmm0,xmm1
    movss dword ptr [r12+rcx*4],xmm0
    inc ecx
    cmp ecx,[rsp+BB_N0]
    jb ob_band_output_loop
ob_band_mask:
    mov ecx,[rbx+OB_BLOCKS]
    mov eax,1
    shl eax,cl
    dec eax
    and [rsp+BB_CM],eax
ob_band_result:
    mov eax,[rsp+BB_CM]
    jmp ob_band_done
ob_band_bad:
    mov eax,-1
ob_band_done:
    add rsp,512
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ob_band_core ENDP

; Internal local helpers are entered by call, so their caller's locals are +8.
; They reserve separate shadow space before calling the recursive core.
ob_child_copy PROC
    xor ecx,ecx
ob_child_copy_loop:
    mov rax,[rbx+rcx*8]
    mov [rsp+8+BB_CHILD+rcx*8],rax
    inc ecx
    cmp ecx,14
    jb ob_child_copy_loop
    ret
ob_child_copy ENDP

ob_decode_mid PROC
    call ob_child_copy_offset
    mov qword ptr [rsp+8+BB_CHILD+OB_Y],0
    mov eax,[rsp+8+BB_MB]
    mov [rsp+8+BB_CHILD+OB_BUDGET],eax
    cmp dword ptr [rsp+8+BB_STEREO],0
    je ob_mid_mono
    mov dword ptr [rsp+8+BB_CHILD+OB_LEVEL],0
    mov dword ptr [rsp+8+BB_CHILD+OB_GAIN],3f800000h
    jmp ob_mid_ready
ob_mid_mono:
    mov qword ptr [rsp+8+BB_CHILD+OB_OUT],0
    inc dword ptr [rsp+8+BB_CHILD+OB_LEVEL]
    movss xmm0,dword ptr [rbx+OB_GAIN]
    mulss xmm0,dword ptr [rsp+8+BB_MID]
    movss dword ptr [rsp+8+BB_CHILD+OB_GAIN],xmm0
ob_mid_ready:
    lea rcx,[rsp+8+BB_CHILD]
    sub rsp,40
    call ob_band_core
    add rsp,40
    ret
ob_decode_mid ENDP

ob_decode_side PROC
    call ob_child_copy_offset
    mov [rsp+8+BB_CHILD+OB_X],rdi
    mov qword ptr [rsp+8+BB_CHILD+OB_Y],0
    mov qword ptr [rsp+8+BB_CHILD+OB_OUT],0
    mov qword ptr [rsp+8+BB_CHILD+OB_SCRATCH],0
    mov eax,[rsp+8+BB_SB]
    mov [rsp+8+BB_CHILD+OB_BUDGET],eax
    movss xmm0,dword ptr [rbx+OB_GAIN]
    mulss xmm0,dword ptr [rsp+8+BB_SIDE]
    movss dword ptr [rsp+8+BB_CHILD+OB_GAIN],xmm0
    mov ecx,[rbx+OB_BLOCKS]
    mov eax,[rbx+OB_FILL]
    shr eax,cl
    mov [rsp+8+BB_CHILD+OB_FILL],eax
    cmp dword ptr [rsp+8+BB_STEREO],0
    je ob_side_mono
    mov qword ptr [rsp+8+BB_CHILD+OB_LOW],0
    mov dword ptr [rsp+8+BB_CHILD+OB_LEVEL],0
    jmp ob_side_ready
ob_side_mono:
    inc dword ptr [rsp+8+BB_CHILD+OB_LEVEL]
    mov rax,[rbx+OB_LOW]
    test rax,rax
    jz ob_side_ready
    mov edx,[rbx+OB_N]
    lea rax,[rax+rdx*4]
    mov [rsp+8+BB_CHILD+OB_LOW],rax
ob_side_ready:
    lea rcx,[rsp+8+BB_CHILD]
    sub rsp,40
    call ob_band_core
    add rsp,40
    ret
ob_decode_side ENDP

; Called through decode_mid/side, with an additional return address.
ob_child_copy_offset PROC
    xor ecx,ecx
ob_child_copy_offset_loop:
    mov rax,[rbx+rcx*8]
    mov [rsp+16+BB_CHILD+rcx*8],rax
    inc ecx
    cmp ecx,14
    jb ob_child_copy_offset_loop
    ret
ob_child_copy_offset ENDP
END
