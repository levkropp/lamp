; Handwritten x86-64 CELT static allocation, band skipping and fine-bit split.
; Algorithm and integer tables: normative RFC6716 rate.c/modes.c (BSD).
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.
; See THIRD_PARTY_NOTICES; reference C is test-only.
option casemap:none
include opus_celt_layout.inc
EXTERN op_ec_logp:PROC, op_ec_uint:PROC
PUBLIC op_celt_allocate, op_celt_init_caps, op_celt_bits2pulses, op_celt_pulses2bits
.const
include opus_celt_tables.inc
op_celt_log2frac db 0,8,13,16,19,21,23,24,26,27,28,29,30,31,32,32,33,34,34,35,36,36,37,37
.code
; RCX=cap[21], EDX=channels (1..2), R8D=LM (0..3). EAX=1/0.
op_celt_init_caps PROC
    test rcx,rcx
    jz op_caps_bad
    cmp edx,1
    jb op_caps_bad
    cmp edx,2
    ja op_caps_bad
    cmp r8d,3
    ja op_caps_bad
    push rbx
    mov ebx,r8d
    mov r9,rcx
    lea eax,[r8*2]
    add eax,edx
    dec eax
    imul eax,21
    lea r10,op_celt_cache_caps
    add r10,rax
    lea r11,op_celt_ebands
    xor ecx,ecx
op_caps_loop:
    movzx eax,word ptr [r11+rcx*2+2]
    movzx r8d,word ptr [r11+rcx*2]
    sub eax,r8d
    imul eax,edx
    mov r8d,ecx
    mov ecx,ebx
    shl eax,cl
    mov ecx,r8d
    movzx r8d,byte ptr [r10+rcx]
    add r8d,64
    imul eax,r8d
    sar eax,2
    mov [r9+rcx*4],eax
    inc ecx
    cmp ecx,21
    jb op_caps_loop
    mov eax,1
    pop rbx
    ret
op_caps_bad:
    xor eax,eax
    ret
op_celt_init_caps ENDP

; ECX=band, EDX=LM (-1..3), R8D=bit budget (0..81600 eighth bits).
; EAX=pseudo pulse index or -1.
op_celt_bits2pulses PROC
    cmp r8d,81600
    ja op_rate_bad
    cmp ecx,20
    ja op_rate_bad
    inc edx
    cmp edx,4
    ja op_rate_bad
    imul edx,21
    add edx,ecx
    lea rax,op_celt_cache_index
    movsx eax,word ptr [rax+rdx*2]
    test eax,eax
    js op_rate_bad
    lea r9,op_celt_cache_bits
    add r9,rax
    xor eax,eax                 ; lo
    movzx edx,byte ptr [r9]      ; hi
    dec r8d
    mov r10d,6
op_rate_search:
    lea ecx,[rax+rdx+1]
    shr ecx,1
    movzx r11d,byte ptr [r9+rcx]
    cmp r11d,r8d
    jge op_rate_hi
    mov eax,ecx
    jmp op_rate_step
op_rate_hi:
    mov edx,ecx
op_rate_step:
    dec r10d
    jnz op_rate_search
    mov r10d,-1
    test eax,eax
    jz op_rate_distance
    movzx r10d,byte ptr [r9+rax]
op_rate_distance:
    mov ecx,r8d
    sub ecx,r10d
    movzx r11d,byte ptr [r9+rdx]
    sub r11d,r8d
    cmp ecx,r11d
    cmovg eax,edx
    ret
op_rate_bad:
    mov eax,-1
    ret
op_celt_bits2pulses ENDP

; ECX=band, EDX=LM (-1..3), R8D=pseudo pulse index. EAX=eighth bits or -1.
op_celt_pulses2bits PROC
    cmp ecx,20
    ja op_cost_bad
    inc edx
    cmp edx,4
    ja op_cost_bad
    imul edx,21
    add edx,ecx
    lea rax,op_celt_cache_index
    movsx eax,word ptr [rax+rdx*2]
    test eax,eax
    js op_cost_bad
    lea r9,op_celt_cache_bits
    add r9,rax
    movzx edx,byte ptr [r9]
    cmp r8d,edx
    ja op_cost_bad
    xor eax,eax
    test r8d,r8d
    jz op_rate_cost_done
    movzx eax,byte ptr [r9+r8]
    inc eax
op_rate_cost_done:
    ret
op_cost_bad:
    mov eax,-1
    ret
op_celt_pulses2bits ENDP

B1 EQU 32
B2 EQU 116
TH EQU 200
TR EQU 284
TOT EQU 368
SKIP EQU 372
INT_R EQU 376
DUAL_R EQU 380
SKIP_START EQU 384
LO EQU 388
HI EQU 392
MID EQU 396
FLOOR_BITS EQU 400
PSUM EQU 404
BAL EQU 408
CODED EQU 412
LEFT_BITS EQU 416
PER EQU 420
BAND_BITS EQU 424
DIM EQU 428
DEN EQU 432
NLOG EQU 436
OFF EQU 440
EXCESS EQU 444
STEREO EQU 448
ITER EQU 452
TEMP EQU 456

; RCX=request -> EAX=coded bands, or -1 for invalid scalar/buffer parameters.
; Invalid parameters are rejected before writes or entropy consumption.
op_celt_allocate PROC
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,552
    mov rbx,rcx
    test rbx,rbx
    jz op_alloc_bad
    mov rsi,[rbx+OC_OFFSETS]
    mov rdi,[rbx+OC_CAPS]
    mov r12,[rbx+OC_BITS]
    mov r13,[rbx+OC_FINE]
    mov r14,[rbx+OC_PRIORITY]
    cmp qword ptr [rbx+OC_EC],0
    je op_alloc_bad
    test rsi,rsi
    jz op_alloc_bad
    test rdi,rdi
    jz op_alloc_bad
    test r12,r12
    jz op_alloc_bad
    test r13,r13
    jz op_alloc_bad
    test r14,r14
    jz op_alloc_bad
    mov eax,[rbx+OC_START]
    cmp eax,20
    ja op_alloc_bad
    mov edx,[rbx+OC_END]
    cmp edx,eax
    jle op_alloc_bad
    cmp edx,21
    ja op_alloc_bad
    mov r15d,[rbx+OC_CHANNELS]
    cmp r15d,1
    jb op_alloc_bad
    cmp r15d,2
    ja op_alloc_bad
    cmp dword ptr [rbx+OC_LM],3
    ja op_alloc_bad
    cmp dword ptr [rbx+OC_TRIM],10
    ja op_alloc_bad
    cmp dword ptr [rbx+OC_TOTAL],81600
    jg op_alloc_bad
    mov ebp,eax
op_alloc_validate:
    cmp dword ptr [rsi+rbp*4],32768
    ja op_alloc_bad
    cmp dword ptr [rdi+rbp*4],65536
    ja op_alloc_bad
    inc ebp
    cmp ebp,edx
    jb op_alloc_validate
    mov eax,r15d
    dec eax
    mov [rsp+STEREO],eax
    mov eax,r15d
    shl eax,3
    mov [rsp+FLOOR_BITS],eax
    mov eax,[rbx+OC_TOTAL]
    xor edx,edx
    test eax,eax
    cmovs eax,edx
    xor edx,edx
    cmp eax,8
    jl op_alloc_no_skip_reserve
    mov edx,8
op_alloc_no_skip_reserve:
    mov [rsp+SKIP],edx
    sub eax,edx
    mov [rsp+TOT],eax
    mov dword ptr [rsp+INT_R],0
    mov dword ptr [rsp+DUAL_R],0
    cmp r15d,2
    jne op_alloc_setup
    mov ecx,[rbx+OC_END]
    sub ecx,[rbx+OC_START]
    lea rdx,op_celt_log2frac
    movzx edx,byte ptr [rdx+rcx]
    cmp edx,eax
    jg op_alloc_setup
    mov [rsp+INT_R],edx
    sub eax,edx
    xor edx,edx
    cmp eax,8
    jl op_alloc_dual_reserved
    mov edx,8
op_alloc_dual_reserved:
    mov [rsp+DUAL_R],edx
    sub eax,edx
    mov [rsp+TOT],eax
op_alloc_setup:
    mov ebp,[rbx+OC_START]
    mov [rsp+SKIP_START],ebp
op_alloc_thresholds:
    lea r8,op_celt_ebands
    movzx eax,word ptr [r8+rbp*2+2]
    movzx edx,word ptr [r8+rbp*2]
    sub eax,edx               ; N0
    mov r9d,eax
    mov ecx,[rbx+OC_LM]
    shl r9d,cl               ; N
    lea edx,[r9+r9*2]
    shl edx,3
    sar edx,4
    cmp edx,[rsp+FLOOR_BITS]
    cmovl edx,[rsp+FLOOR_BITS]
    mov [rsp+rbp*4+TH],edx
    imul eax,r15d
    mov edx,[rbx+OC_TRIM]
    sub edx,5
    sub edx,ecx
    imul eax,edx
    mov edx,[rbx+OC_END]
    sub edx,ebp
    dec edx
    imul eax,edx
    add ecx,3
    shl eax,cl
    sar eax,6
    cmp r9d,1
    jne op_alloc_trim_saved
    sub eax,[rsp+FLOOR_BITS]
op_alloc_trim_saved:
    mov [rsp+rbp*4+TR],eax
    inc ebp
    cmp ebp,[rbx+OC_END]
    jb op_alloc_thresholds

    mov dword ptr [rsp+LO],1
    mov dword ptr [rsp+HI],10
op_alloc_vector_search:
    mov eax,[rsp+LO]
    add eax,[rsp+HI]
    sar eax,1
    mov [rsp+MID],eax
    mov dword ptr [rsp+PSUM],0
    mov dword ptr [rsp+TEMP],0 ; done
    mov ebp,[rbx+OC_END]
op_alloc_vector_band:
    dec ebp
    mov ecx,ebp
    mov edx,[rsp+MID]
    call op_alloc_base
    test eax,eax
    jle op_alloc_vector_offset
    add eax,[rsp+rbp*4+TR]
    xor edx,edx
    test eax,eax
    cmovs eax,edx
op_alloc_vector_offset:
    add eax,[rsi+rbp*4]
    cmp eax,[rsp+rbp*4+TH]
    jge op_alloc_vector_active
    cmp dword ptr [rsp+TEMP],0
    jne op_alloc_vector_active
    cmp eax,[rsp+FLOOR_BITS]
    jl op_alloc_vector_next
    mov eax,[rsp+FLOOR_BITS]
    jmp op_alloc_vector_sum
op_alloc_vector_active:
    mov dword ptr [rsp+TEMP],1
    cmp eax,[rdi+rbp*4]
    cmovg eax,[rdi+rbp*4]
op_alloc_vector_sum:
    add [rsp+PSUM],eax
op_alloc_vector_next:
    cmp ebp,[rbx+OC_START]
    ja op_alloc_vector_band
    mov eax,[rsp+PSUM]
    cmp eax,[rsp+TOT]
    jle op_alloc_vector_low
    mov eax,[rsp+MID]
    dec eax
    mov [rsp+HI],eax
    jmp op_alloc_vector_again
op_alloc_vector_low:
    mov eax,[rsp+MID]
    inc eax
    mov [rsp+LO],eax
op_alloc_vector_again:
    mov eax,[rsp+LO]
    cmp eax,[rsp+HI]
    jle op_alloc_vector_search
    mov [rsp+HI],eax
    dec eax
    mov [rsp+LO],eax
    mov ebp,[rbx+OC_START]
op_alloc_vectors:
    mov ecx,ebp
    mov edx,[rsp+LO]
    call op_alloc_base
    mov [rsp+TEMP],eax
    mov eax,[rdi+rbp*4]
    cmp dword ptr [rsp+HI],11
    jge op_alloc_upper_ready
    mov ecx,ebp
    mov edx,[rsp+HI]
    call op_alloc_base
op_alloc_upper_ready:
    mov edx,[rsp+TEMP]
    test edx,edx
    jle op_alloc_lower_ready
    add edx,[rsp+rbp*4+TR]
    xor ecx,ecx
    test edx,edx
    cmovs edx,ecx
op_alloc_lower_ready:
    test eax,eax
    jle op_alloc_both_ready
    add eax,[rsp+rbp*4+TR]
    xor ecx,ecx
    test eax,eax
    cmovs eax,ecx
op_alloc_both_ready:
    cmp dword ptr [rsp+LO],0
    jle op_alloc_boost_upper
    add edx,[rsi+rbp*4]
op_alloc_boost_upper:
    add eax,[rsi+rbp*4]
    cmp dword ptr [rsi+rbp*4],0
    jle op_alloc_boost_saved
    mov [rsp+SKIP_START],ebp
op_alloc_boost_saved:
    sub eax,edx
    xor ecx,ecx
    test eax,eax
    cmovs eax,ecx
    mov [rsp+rbp*4+B1],edx
    mov [rsp+rbp*4+B2],eax
    inc ebp
    cmp ebp,[rbx+OC_END]
    jb op_alloc_vectors

    mov dword ptr [rsp+LO],0
    mov dword ptr [rsp+HI],64
    mov dword ptr [rsp+ITER],6
op_alloc_interpolate_search:
    mov eax,[rsp+LO]
    add eax,[rsp+HI]
    sar eax,1
    mov [rsp+MID],eax
    mov dword ptr [rsp+PSUM],0
    mov dword ptr [rsp+TEMP],0
    mov ebp,[rbx+OC_END]
op_alloc_interpolate_band:
    dec ebp
    mov eax,[rsp+rbp*4+B2]
    imul eax,[rsp+MID]
    sar eax,6
    add eax,[rsp+rbp*4+B1]
    cmp eax,[rsp+rbp*4+TH]
    jge op_alloc_interpolate_active
    cmp dword ptr [rsp+TEMP],0
    jne op_alloc_interpolate_active
    cmp eax,[rsp+FLOOR_BITS]
    jl op_alloc_interpolate_next
    mov eax,[rsp+FLOOR_BITS]
    jmp op_alloc_interpolate_sum
op_alloc_interpolate_active:
    mov dword ptr [rsp+TEMP],1
    cmp eax,[rdi+rbp*4]
    cmovg eax,[rdi+rbp*4]
op_alloc_interpolate_sum:
    add [rsp+PSUM],eax
op_alloc_interpolate_next:
    cmp ebp,[rbx+OC_START]
    ja op_alloc_interpolate_band
    mov eax,[rsp+PSUM]
    cmp eax,[rsp+TOT]
    jle op_alloc_interpolate_lo
    mov eax,[rsp+MID]
    mov [rsp+HI],eax
    jmp op_alloc_interpolate_again
op_alloc_interpolate_lo:
    mov eax,[rsp+MID]
    mov [rsp+LO],eax
op_alloc_interpolate_again:
    dec dword ptr [rsp+ITER]
    jnz op_alloc_interpolate_search
    mov dword ptr [rsp+PSUM],0
    mov dword ptr [rsp+TEMP],0
    mov ebp,[rbx+OC_END]
op_alloc_initial_bits:
    dec ebp
    mov eax,[rsp+rbp*4+B2]
    imul eax,[rsp+LO]
    sar eax,6
    add eax,[rsp+rbp*4+B1]
    cmp eax,[rsp+rbp*4+TH]
    jge op_alloc_initial_active
    cmp dword ptr [rsp+TEMP],0
    jne op_alloc_initial_active
    cmp eax,[rsp+FLOOR_BITS]
    jge op_alloc_initial_floor
    xor eax,eax
    jmp op_alloc_initial_cap
op_alloc_initial_floor:
    mov eax,[rsp+FLOOR_BITS]
    jmp op_alloc_initial_cap
op_alloc_initial_active:
    mov dword ptr [rsp+TEMP],1
op_alloc_initial_cap:
    cmp eax,[rdi+rbp*4]
    cmovg eax,[rdi+rbp*4]
    mov [r12+rbp*4],eax
    add [rsp+PSUM],eax
    cmp ebp,[rbx+OC_START]
    ja op_alloc_initial_bits

    mov eax,[rbx+OC_END]
    mov [rsp+CODED],eax
op_alloc_skip_loop:
    mov ebp,[rsp+CODED]
    dec ebp
    cmp ebp,[rsp+SKIP_START]
    jg op_alloc_skip_check
    mov eax,[rsp+SKIP]
    add [rsp+TOT],eax
    jmp op_alloc_stereo
op_alloc_skip_check:
    call op_alloc_remainder
    ; EAX=left remainder, EDX=percoeff; R8=ebands, R9=start coefficient.
    movzx ecx,word ptr [r8+rbp*2]
    sub ecx,r9d
    sub eax,ecx
    xor ecx,ecx
    test eax,eax
    cmovs eax,ecx
    movzx ecx,word ptr [r8+rbp*2+2]
    movzx r10d,word ptr [r8+rbp*2]
    sub ecx,r10d
    imul ecx,edx
    add eax,ecx
    add eax,[r12+rbp*4]
    mov [rsp+BAND_BITS],eax
    mov edx,[rsp+FLOOR_BITS]
    add edx,8
    cmp edx,[rsp+rbp*4+TH]
    cmovl edx,[rsp+rbp*4+TH]
    cmp eax,edx
    jl op_alloc_skip_reclaim
    mov rcx,[rbx+OC_EC]
    mov edx,1
    call op_ec_logp
    test eax,eax
    jnz op_alloc_stereo
    add dword ptr [rsp+PSUM],8
    sub dword ptr [rsp+BAND_BITS],8
op_alloc_skip_reclaim:
    mov eax,[r12+rbp*4]
    add eax,[rsp+INT_R]
    sub [rsp+PSUM],eax
    cmp dword ptr [rsp+INT_R],0
    jle op_alloc_skip_new_reserve
    mov eax,ebp
    sub eax,[rbx+OC_START]
    lea rdx,op_celt_log2frac
    movzx eax,byte ptr [rdx+rax]
    mov [rsp+INT_R],eax
op_alloc_skip_new_reserve:
    mov eax,[rsp+INT_R]
    add [rsp+PSUM],eax
    xor eax,eax
    mov edx,[rsp+BAND_BITS]
    cmp edx,[rsp+FLOOR_BITS]
    jl op_alloc_skip_save
    mov eax,[rsp+FLOOR_BITS]
    add [rsp+PSUM],eax
op_alloc_skip_save:
    mov [r12+rbp*4],eax
    dec dword ptr [rsp+CODED]
    jmp op_alloc_skip_loop

op_alloc_stereo:
    xor eax,eax
    cmp dword ptr [rsp+INT_R],0
    jle op_alloc_intensity_ready
    mov edx,[rsp+CODED]
    inc edx
    sub edx,[rbx+OC_START]
    mov rcx,[rbx+OC_EC]
    call op_ec_uint
    add eax,[rbx+OC_START]
op_alloc_intensity_ready:
    mov [rbx+OC_INTENSITY],eax
    cmp eax,[rbx+OC_START]
    jg op_alloc_dual
    mov eax,[rsp+DUAL_R]
    add [rsp+TOT],eax
    mov dword ptr [rsp+DUAL_R],0
op_alloc_dual:
    xor eax,eax
    cmp dword ptr [rsp+DUAL_R],0
    jle op_alloc_dual_ready
    mov rcx,[rbx+OC_EC]
    mov edx,1
    call op_ec_logp
op_alloc_dual_ready:
    mov [rbx+OC_DUAL],eax
    call op_alloc_remainder
    mov [rsp+LEFT_BITS],eax
    mov [rsp+PER],edx
    mov ebp,[rbx+OC_START]
op_alloc_distribute:
    lea r8,op_celt_ebands
    movzx eax,word ptr [r8+rbp*2+2]
    movzx edx,word ptr [r8+rbp*2]
    sub eax,edx
    mov edx,eax
    imul eax,[rsp+PER]
    add [r12+rbp*4],eax
    mov eax,[rsp+LEFT_BITS]
    cmp eax,edx
    cmovg eax,edx
    add [r12+rbp*4],eax
    sub [rsp+LEFT_BITS],eax
    inc ebp
    cmp ebp,[rsp+CODED]
    jb op_alloc_distribute

    mov dword ptr [rsp+BAL],0
    mov ebp,[rbx+OC_START]
op_alloc_fine_band:
    lea r8,op_celt_ebands
    movzx eax,word ptr [r8+rbp*2+2]
    movzx edx,word ptr [r8+rbp*2]
    sub eax,edx
    mov ecx,[rbx+OC_LM]
    shl eax,cl
    mov [rsp+DIM],eax
    mov edx,[rsp+BAL]
    add [r12+rbp*4],edx
    cmp eax,1
    jle op_alloc_single
    mov eax,[r12+rbp*4]
    sub eax,[rdi+rbp*4]
    xor edx,edx
    test eax,eax
    cmovs eax,edx
    mov [rsp+EXCESS],eax
    sub [r12+rbp*4],eax
    mov eax,[rsp+DIM]
    imul eax,r15d
    cmp r15d,2
    jne op_alloc_den_ready
    cmp dword ptr [rsp+DIM],2
    jle op_alloc_den_ready
    cmp dword ptr [rbx+OC_DUAL],0
    jne op_alloc_den_ready
    cmp ebp,[rbx+OC_INTENSITY]
    jge op_alloc_den_ready
    inc eax
op_alloc_den_ready:
    mov [rsp+DEN],eax
    lea r8,op_celt_logn
    movsx edx,word ptr [r8+rbp*2]
    mov ecx,[rbx+OC_LM]
    shl ecx,3
    add edx,ecx
    imul edx,eax
    mov [rsp+NLOG],edx
    sar edx,1
    imul ecx,eax,21
    sub edx,ecx
    cmp dword ptr [rsp+DIM],2
    jne op_alloc_fine_offset
    lea ecx,[rax*2]
    add edx,ecx
op_alloc_fine_offset:
    mov ecx,[r12+rbp*4]
    add ecx,edx
    mov r8d,eax
    shl r8d,4
    cmp ecx,r8d
    jge op_alloc_fine_third
    mov ecx,[rsp+NLOG]
    sar ecx,2
    add edx,ecx
    jmp op_alloc_fine_divide
op_alloc_fine_third:
    imul r8d,eax,24
    cmp ecx,r8d
    jge op_alloc_fine_divide
    mov ecx,[rsp+NLOG]
    sar ecx,3
    add edx,ecx
op_alloc_fine_divide:
    mov [rsp+OFF],edx
    mov ecx,[rsp+DEN]
    shl ecx,2
    mov eax,[r12+rbp*4]
    add eax,edx
    add eax,ecx
    mov ecx,[rsp+DEN]
    shl ecx,3
    cdq
    idiv ecx
    xor edx,edx
    test eax,eax
    cmovs eax,edx
    mov edx,eax
    imul edx,r15d
    mov ecx,[r12+rbp*4]
    sar ecx,3
    cmp edx,ecx
    jle op_alloc_fine_cap
    mov eax,ecx
    mov ecx,[rsp+STEREO]
    sar eax,cl
op_alloc_fine_cap:
    mov edx,8
    cmp eax,edx
    cmovg eax,edx
    mov [r13+rbp*4],eax
    mov edx,[rsp+DEN]
    shl edx,3
    imul edx,eax
    mov ecx,[r12+rbp*4]
    add ecx,[rsp+OFF]
    cmp edx,ecx
    setge dl
    movzx edx,dl
    mov [r14+rbp*4],edx
    imul eax,r15d
    shl eax,3
    sub [r12+rbp*4],eax
    jmp op_alloc_extra_fine
op_alloc_single:
    mov eax,[r12+rbp*4]
    sub eax,[rsp+FLOOR_BITS]
    xor edx,edx
    test eax,eax
    cmovs eax,edx
    mov [rsp+EXCESS],eax
    sub [r12+rbp*4],eax
    mov dword ptr [r13+rbp*4],0
    mov dword ptr [r14+rbp*4],1
op_alloc_extra_fine:
    mov edx,[rsp+EXCESS]
    test edx,edx
    jle op_alloc_fine_balance
    mov eax,edx
    mov ecx,[rsp+STEREO]
    add ecx,3
    sar eax,cl
    mov ecx,8
    sub ecx,[r13+rbp*4]
    cmp eax,ecx
    cmovg eax,ecx
    add [r13+rbp*4],eax
    imul eax,r15d
    shl eax,3
    mov ecx,edx
    sub ecx,[rsp+BAL]
    cmp eax,ecx
    setge cl
    movzx ecx,cl
    mov [r14+rbp*4],ecx
    sub edx,eax
op_alloc_fine_balance:
    mov [rsp+BAL],edx
    inc ebp
    cmp ebp,[rsp+CODED]
    jb op_alloc_fine_band
    mov eax,[rsp+BAL]
    mov [rbx+OC_BALANCE],eax
op_alloc_skipped_fine:
    cmp ebp,[rbx+OC_END]
    jae op_alloc_success
    mov eax,[r12+rbp*4]
    mov ecx,[rsp+STEREO]
    sar eax,cl
    sar eax,3
    mov [r13+rbp*4],eax
    mov dword ptr [r12+rbp*4],0
    cmp eax,1
    setl dl
    movzx edx,dl
    mov [r14+rbp*4],edx
    inc ebp
    jmp op_alloc_skipped_fine
op_alloc_success:
    mov eax,[rsp+CODED]
    mov [rbx+OC_CODED],eax
    jmp op_alloc_done
op_alloc_bad:
    mov eax,-1
op_alloc_done:
    add rsp,552
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
op_celt_allocate ENDP

; Private leaf: ECX=band, EDX=allocation vector, RBX=request, R15D=C.
op_alloc_base PROC
    lea r8,op_celt_ebands
    movzx eax,word ptr [r8+rcx*2+2]
    movzx r9d,word ptr [r8+rcx*2]
    sub eax,r9d
    imul eax,r15d
    imul edx,21
    add edx,ecx
    lea r8,op_celt_alloc_vectors
    movzx edx,byte ptr [r8+rdx]
    imul eax,edx
    mov ecx,[rbx+OC_LM]
    shl eax,cl
    sar eax,2
    ret
op_alloc_base ENDP

; Private leaf: parent frame begins at RSP+8; EAX=remainder, EDX=quotient.
op_alloc_remainder PROC
    lea r8,op_celt_ebands
    mov ecx,[rbx+OC_START]
    movzx r9d,word ptr [r8+rcx*2]
    mov ecx,[rsp+8+CODED]
    movzx r10d,word ptr [r8+rcx*2]
    sub r10d,r9d
    mov eax,[rsp+8+TOT]
    sub eax,[rsp+8+PSUM]
    cdq
    idiv r10d
    mov ecx,eax
    mov eax,edx
    mov edx,ecx
    ret
op_alloc_remainder ENDP
END
