; Handwritten x86-64 CELT frame decisions and dynamic allocation.
; Algorithm reference: normative RFC6716 celt.c (BSD).
; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation,
; Gregory Maxwell. See THIRD_PARTY_NOTICES. No reference C runtime.
option casemap:none
include opus_controls_layout.inc
EXTERN op_ec_tell:PROC, op_ec_frac:PROC, op_ec_logp:PROC
EXTERN op_ec_bits:PROC, op_ec_uint:PROC, op_ec_icdf:PROC
EXTERN op_celt_coarse:PROC, op_celt_fine:PROC
EXTERN op_celt_init_caps:PROC, op_celt_allocate:PROC
PUBLIC op_celt_tf_decode, op_celt_controls
.const
op_control_tf db 0,-1,0,-1,0,-1,0,-1
    db 0,-1,0,-2,1,0,1,-1
    db 0,-2,0,-3,2,0,1,-1
    db 0,-2,0,-3,3,0,1,-1
op_control_trim db 126,124,119,109,87,41,19,9,4,2,0
op_control_spread db 25,23,2,0
op_control_tapset db 2,1,0
op_control_ebands dw 0,1,2,3,4,5,6,7,8,10,12,14,16,20,24,28,34,40,48,60,78,100
op_control_gain real4 0.09375
.code
; Nonmutating guard for an initialized, normalized 64-byte entropy context.
op_control_ec_valid PROC
    test rcx,rcx
    jz op_control_ec_bad
    cmp dword ptr [rcx+8],1275
    ja op_control_ec_bad
    cmp dword ptr [rcx+8],0
    je op_control_ec_buffer_ok
    cmp qword ptr [rcx],0
    je op_control_ec_bad
op_control_ec_buffer_ok:
    mov eax,[rcx+28]
    cmp eax,[rcx+8]
    ja op_control_ec_bad
    mov eax,[rcx+12]
    cmp eax,[rcx+8]
    ja op_control_ec_bad
    cmp dword ptr [rcx+32],800000h
    jbe op_control_ec_bad
    cmp dword ptr [rcx+32],80000000h
    ja op_control_ec_bad
    cmp dword ptr [rcx+20],32
    ja op_control_ec_bad
    cmp dword ptr [rcx+24],32768
    ja op_control_ec_bad
    mov eax,1
    ret
op_control_ec_bad:
    xor eax,eax
    ret
op_control_ec_valid ENDP

; RCX=request. Decode TF symbols using start/end, LM and transient fields.
; EAX=1 on success, 0 for invalid requests, before output/entropy writes.
op_celt_tf_decode PROC
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,72
    mov rbx,rcx
    test rbx,rbx
    jz op_tf_bad
    mov rsi,[rbx+OCT_EC]
    mov rdi,[rbx+OCT_TF]
    test rdi,rdi
    jz op_tf_bad
    mov r12d,[rbx+OCT_START]
    cmp r12d,20
    ja op_tf_bad
    mov r13d,[rbx+OCT_END]
    cmp r13d,r12d
    jle op_tf_bad
    cmp r13d,21
    ja op_tf_bad
    cmp dword ptr [rbx+OCT_LM],3
    ja op_tf_bad
    cmp dword ptr [rbx+OCT_TRANSIENT],1
    ja op_tf_bad
    mov rcx,rsi
    call op_control_ec_valid
    test eax,eax
    jz op_tf_bad
    mov ebp,[rsi+8]
    shl ebp,3
    mov rcx,rsi
    call op_ec_tell
    mov [rsp+32],eax
    mov r14d,4
    cmp dword ptr [rbx+OCT_TRANSIENT],0
    je op_tf_reserve
    mov r14d,2
op_tf_reserve:
    mov dword ptr [rsp+36],0
    cmp dword ptr [rbx+OCT_LM],0
    je op_tf_loop_start
    lea edx,[rax+r14+1]
    cmp edx,ebp
    ja op_tf_loop_start
    mov dword ptr [rsp+36],1
    dec ebp
op_tf_loop_start:
    xor r15d,r15d
    mov dword ptr [rsp+40],0
op_tf_loop:
    mov eax,[rsp+32]
    add eax,r14d
    cmp eax,ebp
    ja op_tf_store
    mov rcx,rsi
    mov edx,r14d
    call op_ec_logp
    xor r15d,eax
    mov rcx,rsi
    call op_ec_tell
    mov [rsp+32],eax
    or [rsp+40],r15d
op_tf_store:
    mov [rdi+r12*4],r15d
    mov r14d,5
    cmp dword ptr [rbx+OCT_TRANSIENT],0
    je op_tf_next
    mov r14d,4
op_tf_next:
    inc r12d
    cmp r12d,r13d
    jb op_tf_loop
    mov eax,[rbx+OCT_LM]
    shl eax,3
    mov edx,[rbx+OCT_TRANSIENT]
    lea eax,[rax+rdx*4]
    lea r14,op_control_tf
    add r14,rax
    xor r15d,r15d
    cmp dword ptr [rsp+36],0
    je op_tf_map_start
    mov edx,[rsp+40]
    mov al,[r14+rdx]
    cmp al,[r14+rdx+2]
    je op_tf_map_start
    mov rcx,rsi
    mov edx,1
    call op_ec_logp
    lea r15d,[rax*2]
op_tf_map_start:
    mov r12d,[rbx+OCT_START]
    add r14,r15
op_tf_map:
    mov eax,[rdi+r12*4]
    movsx eax,byte ptr [r14+rax]
    mov [rdi+r12*4],eax
    inc r12d
    cmp r12d,r13d
    jb op_tf_map
    mov eax,1
    jmp op_tf_done
op_tf_bad:
    xor eax,eax
op_tf_done:
    add rsp,72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
op_celt_tf_decode ENDP

; Stack-local allocation request at 32, energy request at 128.
CT_TOTAL EQU 192
CT_TELL EQU 196
CT_DYNAMIC_BUDGET EQU 200
CT_DYNAMIC_LOGP EQU 204
CT_QUANTA EQU 208
CT_BOOST EQU 212
CT_LOOP_LOGP EQU 216

; RCX=request -> EAX=coded bands, or -1 for invalid input.
; Consumes frame flags, coarse energy, TF, boosts, allocation and fine energy.
; It stops at normalized shape decoding; it does not claim audio playback.
op_celt_controls PROC
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,280
    mov rbx,rcx
    test rbx,rbx
    jz op_controls_bad
    xor eax,eax
op_controls_pointers:
    cmp qword ptr [rbx+rax*8],0
    je op_controls_bad
    inc eax
    cmp eax,8
    jb op_controls_pointers
    mov r12d,[rbx+OCT_START]
    cmp r12d,20
    ja op_controls_bad
    mov r13d,[rbx+OCT_END]
    cmp r13d,r12d
    jle op_controls_bad
    cmp r13d,21
    ja op_controls_bad
    mov eax,[rbx+OCT_CHANNELS]
    dec eax
    cmp eax,1
    ja op_controls_bad
    cmp dword ptr [rbx+OCT_LM],3
    ja op_controls_bad
    mov rsi,[rbx+OCT_EC]
    mov rcx,rsi
    call op_control_ec_valid
    test eax,eax
    jz op_controls_bad
    mov rdi,[rbx+OCT_OLD]
    xor ecx,ecx
op_controls_finite:
    mov eax,[rdi+rcx*4]
    and eax,7f800000h
    cmp eax,7f800000h
    je op_controls_bad
    inc ecx
    cmp ecx,42
    jb op_controls_finite
    ; Validation is complete; writes and entropy consumption begin here.
    cmp dword ptr [rbx+OCT_CHANNELS],1
    jne op_controls_zero_outputs
    xor ecx,ecx
op_controls_mono_merge:
    movss xmm0,dword ptr [rdi+rcx*4]
    maxss xmm0,dword ptr [rdi+rcx*4+84]
    movss dword ptr [rdi+rcx*4],xmm0
    inc ecx
    cmp ecx,21
    jb op_controls_mono_merge
op_controls_zero_outputs:
    xor eax,eax
    mov ecx,80
op_controls_zero_loop:
    mov [rbx+rcx],eax
    add ecx,4
    cmp ecx,136
    jb op_controls_zero_loop
    mov eax,[rsi+8]
    shl eax,3
    mov [rsp+CT_TOTAL],eax
    mov rcx,rsi
    call op_ec_tell
    mov [rsp+CT_TELL],eax
    cmp eax,[rsp+CT_TOTAL]
    jae op_controls_silence
    cmp eax,1
    jne op_controls_postfilter
    mov rcx,rsi
    mov edx,15
    call op_ec_logp
    test eax,eax
    jz op_controls_postfilter
op_controls_silence:
    mov dword ptr [rbx+OCT_SILENCE],1
    mov rcx,rsi
    call op_ec_tell
    mov edx,[rsp+CT_TOTAL]
    sub edx,eax
    add [rsi+24],edx
    mov eax,[rsp+CT_TOTAL]
    mov [rsp+CT_TELL],eax
op_controls_postfilter:
    cmp dword ptr [rbx+OCT_START],0
    jne op_controls_transient
    mov eax,[rsp+CT_TELL]
    add eax,16
    cmp eax,[rsp+CT_TOTAL]
    ja op_controls_transient
    mov rcx,rsi
    mov edx,1
    call op_ec_logp
    test eax,eax
    jz op_controls_postfilter_tell
    mov rcx,rsi
    mov edx,6
    call op_ec_uint
    mov ebp,eax
    lea edx,[rax+4]
    mov rcx,rsi
    call op_ec_bits
    mov ecx,ebp
    mov edx,16
    shl edx,cl
    lea eax,[rax+rdx-1]
    mov [rbx+OCT_PITCH],eax
    mov rcx,rsi
    mov edx,3
    call op_ec_bits
    inc eax
    cvtsi2ss xmm0,eax
    mulss xmm0,[op_control_gain]
    movss dword ptr [rbx+OCT_GAIN],xmm0
    mov rcx,rsi
    call op_ec_tell
    add eax,2
    cmp eax,[rsp+CT_TOTAL]
    ja op_controls_postfilter_tell
    mov rcx,rsi
    lea rdx,op_control_tapset
    mov r8d,2
    call op_ec_icdf
    mov [rbx+OCT_TAPSET],eax
op_controls_postfilter_tell:
    mov rcx,rsi
    call op_ec_tell
    mov [rsp+CT_TELL],eax
op_controls_transient:
    cmp dword ptr [rbx+OCT_LM],0
    je op_controls_intra
    mov eax,[rsp+CT_TELL]
    add eax,3
    cmp eax,[rsp+CT_TOTAL]
    ja op_controls_intra
    mov rcx,rsi
    mov edx,3
    call op_ec_logp
    mov [rbx+OCT_TRANSIENT],eax
    mov rcx,rsi
    call op_ec_tell
    mov [rsp+CT_TELL],eax
op_controls_intra:
    mov eax,[rsp+CT_TELL]
    add eax,3
    cmp eax,[rsp+CT_TOTAL]
    ja op_controls_energy
    mov rcx,rsi
    mov edx,3
    call op_ec_logp
    mov [rbx+OCT_INTRA],eax
op_controls_energy:
    mov [rsp+128],rsi
    mov [rsp+136],rdi
    mov rax,[rbx+OCT_FINE]
    mov [rsp+144],rax
    mov rax,[rbx+OCT_PRIORITY]
    mov [rsp+152],rax
    mov eax,[rbx+OCT_START]
    mov [rsp+160],eax
    mov eax,[rbx+OCT_END]
    mov [rsp+164],eax
    mov eax,[rbx+OCT_CHANNELS]
    mov [rsp+168],eax
    mov eax,[rbx+OCT_LM]
    mov [rsp+172],eax
    mov eax,[rbx+OCT_INTRA]
    mov [rsp+176],eax
    mov dword ptr [rsp+180],0
    mov dword ptr [rsp+184],21
    lea rcx,[rsp+128]
    call op_celt_coarse
    mov rcx,rbx
    call op_celt_tf_decode
    mov dword ptr [rbx+OCT_SPREAD],2
    mov rcx,rsi
    call op_ec_tell
    add eax,4
    cmp eax,[rsp+CT_TOTAL]
    ja op_controls_caps
    mov rcx,rsi
    lea rdx,op_control_spread
    mov r8d,5
    call op_ec_icdf
    mov [rbx+OCT_SPREAD],eax
op_controls_caps:
    mov rcx,[rbx+OCT_CAPS]
    mov edx,[rbx+OCT_CHANNELS]
    mov r8d,[rbx+OCT_LM]
    call op_celt_init_caps
    mov eax,[rsp+CT_TOTAL]
    shl eax,3
    mov [rsp+CT_DYNAMIC_BUDGET],eax
    mov dword ptr [rsp+CT_DYNAMIC_LOGP],6
    mov rcx,rsi
    call op_ec_frac
    mov [rsp+CT_TELL],eax
    mov r12d,[rbx+OCT_START]
    mov r13d,[rbx+OCT_END]
    mov r14,[rbx+OCT_CAPS]
    mov r15,[rbx+OCT_OFFSETS]
op_controls_dynamic_band:
    lea rdx,op_control_ebands
    movzx eax,word ptr [rdx+r12*2+2]
    movzx ecx,word ptr [rdx+r12*2]
    sub eax,ecx
    imul eax,[rbx+OCT_CHANNELS]
    mov ecx,[rbx+OCT_LM]
    shl eax,cl
    mov edx,48
    cmp edx,eax
    cmovl edx,eax
    shl eax,3
    cmp edx,eax
    cmovg edx,eax
    mov [rsp+CT_QUANTA],edx
    mov eax,[rsp+CT_DYNAMIC_LOGP]
    mov [rsp+CT_LOOP_LOGP],eax
    mov dword ptr [rsp+CT_BOOST],0
op_controls_dynamic_loop:
    mov eax,[rsp+CT_LOOP_LOGP]
    shl eax,3
    add eax,[rsp+CT_TELL]
    cmp eax,[rsp+CT_DYNAMIC_BUDGET]
    jge op_controls_dynamic_store
    mov eax,[rsp+CT_BOOST]
    cmp eax,[r14+r12*4]
    jge op_controls_dynamic_store
    mov rcx,rsi
    mov edx,[rsp+CT_LOOP_LOGP]
    call op_ec_logp
    mov ebp,eax
    mov rcx,rsi
    call op_ec_frac
    mov [rsp+CT_TELL],eax
    test ebp,ebp
    jz op_controls_dynamic_store
    mov eax,[rsp+CT_QUANTA]
    add [rsp+CT_BOOST],eax
    sub [rsp+CT_DYNAMIC_BUDGET],eax
    mov dword ptr [rsp+CT_LOOP_LOGP],1
    jmp op_controls_dynamic_loop
op_controls_dynamic_store:
    mov eax,[rsp+CT_BOOST]
    mov [r15+r12*4],eax
    test eax,eax
    jz op_controls_dynamic_next
    mov eax,[rsp+CT_DYNAMIC_LOGP]
    dec eax
    mov edx,2
    cmp eax,edx
    cmovl eax,edx
    mov [rsp+CT_DYNAMIC_LOGP],eax
op_controls_dynamic_next:
    inc r12d
    cmp r12d,r13d
    jb op_controls_dynamic_band
    mov dword ptr [rbx+OCT_TRIM],5
    mov eax,[rsp+CT_TELL]
    add eax,48
    cmp eax,[rsp+CT_DYNAMIC_BUDGET]
    jg op_controls_shape_budget
    mov rcx,rsi
    lea rdx,op_control_trim
    mov r8d,7
    call op_ec_icdf
    mov [rbx+OCT_TRIM],eax
op_controls_shape_budget:
    mov rcx,rsi
    call op_ec_frac
    mov edx,[rsp+CT_TOTAL]
    shl edx,3
    sub edx,eax
    dec edx
    cmp dword ptr [rbx+OCT_TRANSIENT],0
    je op_controls_allocate
    mov eax,[rbx+OCT_LM]
    cmp eax,2
    jl op_controls_allocate
    add eax,2
    shl eax,3
    cmp edx,eax
    jl op_controls_allocate
    mov dword ptr [rbx+OCT_ANTI],8
    sub edx,8
op_controls_allocate:
    mov [rbx+OCT_BUDGET],edx
    mov [rsp+32],rsi
    mov rax,[rbx+OCT_OFFSETS]
    mov [rsp+40],rax
    mov rax,[rbx+OCT_CAPS]
    mov [rsp+48],rax
    mov rax,[rbx+OCT_BITS]
    mov [rsp+56],rax
    mov rax,[rbx+OCT_FINE]
    mov [rsp+64],rax
    mov rax,[rbx+OCT_PRIORITY]
    mov [rsp+72],rax
    mov eax,[rbx+OCT_START]
    mov [rsp+80],eax
    mov eax,[rbx+OCT_END]
    mov [rsp+84],eax
    mov eax,[rbx+OCT_CHANNELS]
    mov [rsp+88],eax
    mov eax,[rbx+OCT_LM]
    mov [rsp+92],eax
    mov eax,[rbx+OCT_TRIM]
    mov [rsp+96],eax
    mov [rsp+100],edx
    lea rcx,[rsp+32]
    call op_celt_allocate
    mov [rbx+OCT_CODED],eax
    mov eax,[rsp+104]
    mov [rbx+OCT_INTENSITY],eax
    mov eax,[rsp+108]
    mov [rbx+OCT_DUAL],eax
    mov eax,[rsp+112]
    mov [rbx+OCT_BALANCE],eax
    lea rcx,[rsp+128]
    call op_celt_fine
    mov eax,[rbx+OCT_CODED]
    jmp op_controls_done
op_controls_bad:
    mov eax,-1
op_controls_done:
    add rsp,280
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
op_celt_controls ENDP
END
