# Original stateful Speex narrowband coded-frame decoder. MIT.
# BSD Speex 1.2.1 nb_celp.c, modes.c and filters.c reference; see notices.
# Coded modes 0..8, DTX, lost-packet synthesis and recovery.
# No reference C or libm is runtime-linked.
.include "lamp.inc"
.include "speex_packet.inc"
.include "speex_excitation.inc"
.include "speex_nb.inc"
RODATA
.include "speex_nb_tables.inc"
.p2align 3
spxn_point1: .double .1
spxn_point4: .double .4
spxn_point07: .double .07
spxn_1point72: .double 1.72
spxn_half64: .double .5
spxn_point6: .double .6
spxn_point7: .double .7
spxn_point3: .double .3
spxn_negpoint2: .double -.2
spxn_one64: .double 1.
spxn_div64: .double .015625
spxn_point85: .double .85
spxn_point67: .double .67
spxn_one: .float 1.
spxn_two: .float 2.
spxn_thousand: .float 1000.
spxn_clip: .float 32000.
spxn_neg_clip: .float -32000.
spxn_margin: .float .002
spxn_point25f: .float .25
spxn_point7f: .float .7
spxn_point3f: .float .3
spxn_point6f: .float .6
spxn_point8f: .float .8
spxn_point2f: .float .2
spxn_point85f: .float .85
spxn_point15f: .float .15
spxn_1point5f: .float 1.5
spxn_point93f: .float .93
spxn_point98f: .float .98
spxn_tiny: .float 1e-15
spxn_point99f: .float .99
spxn_1point01f: .float 1.01
spxn_second: .float .454545
spxn_subgain3: .float .061130, .163546, .310413, .428220, .555887, .719055, .938694, 1.326874
spxn_subgain1: .float .70469, 1.05127
spxn_wb_bits: .long 4, 36, 112, 192, 352
spxn_control_bits: .long 1,1,4,4,4,4,4,4,8,8,16,16,32,32,64,64
spxn_attenuation: .float 1., .961, .852, .698, .527, .368, .237, .141, .077, .039
.p2align 4
spxn_abs: .long 0x7fffffff, 0, 0, 0
spxn_shift_filter:
    .float -.011915, .046995, -.152373, .614108, .614108, -.152373, .046995
    .float -.0324855, .0859768, -.2042986, .9640297, .2086420, -.0302054, -.0063646
    .float -.0063646, -.0302054, .2086420, .9640297, -.2042986, .0859768, -.0324855
# Frame bits, LSP kind, pitch kind, low-rate pitch, forced gain, gain bits,
# double codebook, innovation kind (-1=noise), float comb gain. 36 bytes.
spxn_modes:
    .long 5,1,3,0,0,0,0,-1
    .float -1.
    .long 43,1,3,0,1,0,0,-1
    .float -1.
    .long 119,1,2,0,0,0,0,0
    .float .6
    .long 160,1,1,-1,0,1,0,2
    .float .55
    .long 220,1,1,-1,0,1,0,4
    .float .45
    .long 300,0,0,-1,0,3,0,3
    .float .25
    .long 364,0,0,-1,0,3,0,5
    .float .15
    .long 492,0,0,-1,0,3,1,3
    .float .05
    .long 79,1,3,0,1,0,0,1
    .float .5
.text
.include "speex_nb_math.inc"

# RCX=arena, EDX=capacity -> 1/0. Clears 8192 bytes only after validation.
FN spx_nb_init
    test rcx, rcx
    jz .Lspxn_init_bad
    cmp edx, SPXN_SIZE
    jb .Lspxn_init_bad
    mov rax, rcx
    add rax, SPXN_SIZE
    jc .Lspxn_init_bad
    xor eax, eax
.Lspxn_init_zero:
    mov qword ptr [rcx+rax], 0
    add eax, 8
    cmp eax, SPXN_SIZE
    jb .Lspxn_init_zero
    mov dword ptr [rcx], SPXN_MAGIC
    mov dword ptr [rcx+SPXN_FIRST], 1
    mov dword ptr [rcx+SPXN_MODE], 5
    mov dword ptr [rcx+SPXN_FLAGS], 3
    mov dword ptr [rcx+SPXN_SEED], 1000
    mov dword ptr [rcx+SPXN_LAST_PITCH], 40
    mov dword ptr [rcx+SPXN_STEREO_CODE], -1
    mov eax, 1
    ret
.Lspxn_init_bad:
    xor eax, eax
    ret
ENDFN spx_nb_init

# RCX=initialized arena, EDX=flags (enhance=1, high-pass=2, embedded WB=4).
FN spx_nb_set_flags
    test rcx, rcx
    jz .Lspxn_flags_bad
    cmp dword ptr [rcx], SPXN_MAGIC
    jne .Lspxn_flags_bad
    cmp edx, 7
    ja .Lspxn_flags_bad
    mov [rcx+SPXN_FLAGS], edx
    mov eax, 1
    ret
.Lspxn_flags_bad:
    xor eax, eax
    ret
ENDFN spx_nb_set_flags

# Private pairwise-disjoint four-range validation. RCX=[begin,end)*4.
LOCALFN spxn_ranges
    push rbx
    xor r8d, r8d
.Lspxn_ranges_outer:
    mov eax, r8d
    shl eax, 4
    mov r10, [rcx+rax]
    mov r11, [rcx+rax+8]
    cmp r10, r11
    ja .Lspxn_ranges_bad
    je .Lspxn_ranges_next
    lea r9d, [r8+1]
.Lspxn_ranges_inner:
    cmp r9d, 4
    jae .Lspxn_ranges_next
    mov ebx, r9d
    shl ebx, 4
    mov rax, [rcx+rbx]
    cmp rax, [rcx+rbx+8]
    ja .Lspxn_ranges_bad
    je .Lspxn_ranges_skip
    cmp r10, [rcx+rbx+8]
    jae .Lspxn_ranges_skip
    cmp rax, r11
    jb .Lspxn_ranges_bad
.Lspxn_ranges_skip:
    inc r9d
    jmp .Lspxn_ranges_inner
.Lspxn_ranges_next:
    inc r8d
    cmp r8d, 4
    jb .Lspxn_ranges_outer
    mov eax, 1
    pop rbx
    ret
.Lspxn_ranges_bad:
    xor eax, eax
    pop rbx
    ret
ENDFN spxn_ranges

# RCX=arena, RDX=Bits (NULL for DTX or lost packet), R8=160-float output,
# R9D=capacity -> 160 success, 0 clean packet end, -1 malformed/unsupported.
# Failed frames preserve defined live history, output and bit position;
# truncation sets only original Bits.error. Arena shadow/work is scratch.
FN spx_nb_frame
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 256
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    test rbx, rbx
    jz .Lspxn_bad_plain
    test rdi, rdi
    jz .Lspxn_bad_plain
    cmp r9d, 160
    jb .Lspxn_bad_plain
    mov rax, rbx
    add rax, SPXN_SIZE
    jc .Lspxn_bad_plain
    mov [rsp+160], rbx
    mov [rsp+168], rax
    mov rax, rdi
    add rax, 640
    jc .Lspxn_bad_plain
    mov [rsp+176], rdi
    mov [rsp+184], rax
    xor eax, eax
    mov [rsp+192], rax
    mov [rsp+200], rax
    mov [rsp+208], rax
    mov [rsp+216], rax
    test rsi, rsi
    jz .Lspxn_regions_ready
    mov rax, rsi
    add rax, SPXB_SIZE
    jc .Lspxn_bad_plain
    mov [rsp+192], rsi
    mov [rsp+200], rax
    # Reject an aliased reader before inspecting its fields.
    cmp rsi, [rsp+168]
    jae .Lspxn_reader_not_arena
    cmp rbx, rax
    jb .Lspxn_bad_plain
.Lspxn_reader_not_arena:
    cmp dword ptr [rsi+SPXB_ERROR], 0
    jne .Lspxn_bad_plain
    mov eax, [rsi+SPXB_BITS]
    cmp eax, SPX_MAX_PACKET*8
    ja .Lspxn_bad_plain
    cmp eax, [rsi+SPXB_POS]
    jb .Lspxn_bad_plain
    add eax, 7
    shr eax, 3
    mov rdx, [rsi+SPXB_DATA]
    mov [rsp+208], rdx
    test eax, eax
    jz .Lspxn_empty_source
    test rdx, rdx
    jz .Lspxn_bad_plain
.Lspxn_empty_source:
    add rdx, rax
    jc .Lspxn_bad_plain
    mov [rsp+216], rdx
.Lspxn_regions_ready:
    lea rcx, [rsp+160]
    call spxn_ranges
    test eax, eax
    jz .Lspxn_bad_plain
    cmp dword ptr [rbx], SPXN_MAGIC
    jne .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_FLAGS], 7
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_PGAIN_INDEX], 2
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_VOC_OFFSET], -160
    jl .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_VOC_OFFSET], 144
    jg .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_LOST], 1000000000
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_LAST_PITCH], 17
    jb .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_LAST_PITCH], 144
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_FIRST], 1
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_DTX], 1
    ja .Lspxn_bad_plain
    cmp dword ptr [rbx+SPXN_MODE], 8
    ja .Lspxn_bad_plain
    # The arena is opaque to callers. Reject damaged numeric history before
    # recursive synthesis or the bounded recovery exponential can use it.
    mov ecx, 44
.Lspxn_validate_float:
    mov eax, [rbx+rcx]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxn_bad_plain
    add ecx, 4
    cmp ecx, SPXN_LIVE
    jb .Lspxn_validate_float
    xor ecx, ecx
.Lspxn_validate_lsp:
    mov eax, [rbx+SPXN_OLD_LSP+rcx*4]
    and eax, 0x7fffffff
    cmp eax, 0x41800000                # |angle| <= 16
    ja .Lspxn_bad_plain
    inc ecx
    cmp ecx, 10
    jb .Lspxn_validate_lsp
.Lspxn_copy:
    lea r12, [rbx+SPXN_LIVE]
    lea r13, [rbx+SPXN_BITS]
    lea r14, [rbx+SPXN_OUT]
    xor eax, eax
.Lspxn_copy_live:
    mov rdx, [rbx+rax]
    mov [r12+rax], rdx
    add eax, 8
    cmp eax, SPXN_LIVE
    jb .Lspxn_copy_live
    pxor xmm0, xmm0
    movdqu [r13], xmm0
    movq [r13+16], xmm0
    test rsi, rsi
    jnz .Lspxn_reader_ready
    cmp dword ptr [r12+SPXN_DTX], 1
    je .Lspxn_null_mode
    jmp .Lspxn_lost
.Lspxn_reader_ready:
    movdqu xmm0, [rsi]
    movdqu [r13], xmm0
    mov rax, [rsi+16]
    mov [r13+16], rax
    mov dword ptr [rsp+108], 0          # skipped upper layers
    mov dword ptr [rsp+112], 0          # controls
.Lspxn_header:
    mov rcx, r13
    call spx_bits_remaining
    cmp eax, 5
    jl .Lspxn_packet_end
    mov rcx, r13
    mov edx, 1
    call spx_bits_read
    test eax, eax
    jz .Lspxn_header_mode
    inc dword ptr [rsp+108]
    cmp dword ptr [rsp+108], 2
    ja .Lspxn_bad
    mov rcx, r13
    mov edx, 3
    call spx_bits_read
    cmp eax, 4
    ja .Lspxn_bad
    lea rdx, [rip+spxn_wb_bits]
    mov edx, [rdx+rax*4]
    sub edx, 4
    mov rcx, r13
    call spx_bits_advance
    test eax, eax
    jz .Lspxn_bad
    jmp .Lspxn_header
.Lspxn_header_mode:
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    cmp eax, 8
    jbe .Lspxn_mode
    cmp eax, 15
    je .Lspxn_packet_end
    cmp eax, 13
    jb .Lspxn_bad
    inc dword ptr [rsp+112]
    cmp dword ptr [rsp+112], 1024
    ja .Lspxn_bad
    mov dword ptr [rsp+108], 0
    cmp eax, 14
    je .Lspxn_std_control
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    lea edx, [rax*8+5]
    jmp .Lspxn_skip_control
.Lspxn_std_control:
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    cmp eax, 9
    jne .Lspxn_std_control_size
    mov rcx, r13
    mov edx, 8
    call spx_bits_read
    mov [r12+SPXN_STEREO_CODE], eax
    cmp dword ptr [r13+SPXB_ERROR], 0
    jne .Lspxn_bad
    jmp .Lspxn_header
.Lspxn_std_control_size:
    lea rdx, [rip+spxn_control_bits]
    mov edx, [rdx+rax*4]
.Lspxn_skip_control:
    mov rcx, r13
    call spx_bits_advance
    test eax, eax
    jz .Lspxn_bad
    jmp .Lspxn_header
.Lspxn_null_mode:
    xor eax, eax
.Lspxn_mode:
    mov [r12+SPXN_MODE], eax
    imul eax, eax, 36
    lea r15, [rip+spxn_modes]
    add r15, rax
    mov [rsp+64], r15
    mov edx, [r15]
    sub edx, 5
    mov eax, [r13+SPXB_POS]
    add eax, edx
    mov [rsp+120], eax
    cmp eax, [r13+SPXB_BITS]
    ja .Lspxn_short
    xor eax, eax
.Lspxn_shift_exc:
    mov edx, [r12+SPXN_EXCBUF+640+rax*4]
    mov [r12+SPXN_EXCBUF+rax*4], edx
    inc eax
    cmp eax, 340
    jb .Lspxn_shift_exc
    cmp dword ptr [r12+SPXN_MODE], 0
    jne .Lspxn_active
    lea rcx, [r12+SPXN_LPC]
    lea rdx, [rbx+SPXN_AK]
    mov r8d, 10
    movss xmm3, [rip+spxn_point93f]
    call spx_bw_lpc
    test eax, eax
    jz .Lspxn_bad
    lea rcx, [r12+SPXN_EXC]
    mov edx, 160
    call spxn_rms
    movaps xmm3, xmm0
    lea rcx, [r12+SPXN_EXC]
    mov edx, 160
    lea r8, [r12+SPXN_SEED]
    call spx_noise_decode
    test eax, eax
    jz .Lspxn_bad
    lea rcx, [r12+SPXN_EXC]
    lea rdx, [rbx+SPXN_AK]
    mov r8, r14
    mov r9d, 160
    mov dword ptr [rsp+32], 10
    lea rax, [r12+SPXN_MEM_SP]
    mov [rsp+40], rax
    call spx_iir_mem
    test eax, eax
    jz .Lspxn_bad
    mov dword ptr [r12+SPXN_FIRST], 1
    mov dword ptr [r12+SPXN_LOST], 0
    jmp .Lspxn_finish
.Lspxn_active:
    mov rcx, r13
    lea rdx, [rbx+SPXN_QLSP]
    mov r8d, [r15+4]
    mov r9d, 10
    call spx_lsp_unquant
    cmp eax, 10
    jne .Lspxn_bad
    cmp dword ptr [r12+SPXN_LOST], 0
    je .Lspxn_recovery_memory_ready
    pxor xmm0, xmm0
    xor eax, eax
.Lspxn_lsp_distance:
    movss xmm1, [r12+SPXN_OLD_LSP+rax*4]
    subss xmm1, [rbx+SPXN_QLSP+rax*4]
    andps xmm1, [rip+spxn_abs]
    addss xmm0, xmm1
    inc eax
    cmp eax, 10
    jb .Lspxn_lsp_distance
    call spxn_recovery_factor
    xor eax, eax
.Lspxn_damp_memory:
    movss xmm1, [r12+SPXN_MEM_SP+rax*4]
    mulss xmm1, xmm0
    movss [r12+SPXN_MEM_SP+rax*4], xmm1
    inc eax
    cmp eax, 10
    jb .Lspxn_damp_memory
    jmp .Lspxn_first_lsp_start
.Lspxn_recovery_memory_ready:
    cmp dword ptr [r12+SPXN_FIRST], 0
    je .Lspxn_old_ready
.Lspxn_first_lsp_start:
    xor eax, eax
.Lspxn_first_lsp:
    mov edx, [rbx+SPXN_QLSP+rax*4]
    mov [r12+SPXN_OLD_LSP+rax*4], edx
    inc eax
    cmp eax, 10
    jb .Lspxn_first_lsp
.Lspxn_old_ready:
    mov dword ptr [rsp+80], 0
    mov dword ptr [rsp+84], 0
    cmp dword ptr [r15+12], -1
    je .Lspxn_pitch_ready
    mov rcx, r13
    mov edx, 7
    call spx_bits_read
    add eax, 17
    mov [rsp+80], eax
.Lspxn_pitch_ready:
    cmp dword ptr [r15+16], 0
    je .Lspxn_coef_ready
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    lea rdx, [rip+spxn_ol_coef]
    mov eax, [rdx+rax*4]
    mov [rsp+84], eax
.Lspxn_coef_ready:
    mov rcx, r13
    mov edx, 5
    call spx_bits_read
    lea rdx, [rip+spxn_ol_gain]
    mov eax, [rdx+rax*4]
    mov [rsp+88], eax
    cmp dword ptr [r12+SPXN_MODE], 1
    jne .Lspxn_dtx_not_mode1
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    xor edx, edx
    cmp eax, 15
    sete dl
    mov [r12+SPXN_DTX], edx
    jmp .Lspxn_subframes
.Lspxn_dtx_not_mode1:
    mov dword ptr [r12+SPXN_DTX], 0
.Lspxn_subframes:
    mov dword ptr [rsp+72], 0
    mov dword ptr [rsp+96], 0
    mov dword ptr [rsp+100], 40
    mov dword ptr [rsp+104], 0
.Lspxn_subframe:
    mov eax, [rsp+72]
    imul eax, eax, 40
    mov [rsp+76], eax
    lea rdx, [r12+SPXN_EXC+rax*4]
    xor ecx, ecx
.Lspxn_clear_exc:
    mov dword ptr [rdx+rcx*4], 0
    inc ecx
    cmp ecx, 40
    jb .Lspxn_clear_exc
    lea r8, [rbx+SPXN_PITCH_JOB]
    mov [r8+SPXE_EXC], rdx
    lea rax, [rbx+SPXN_EXC32]
    mov [r8+SPXE_OUT], rax
    mov dword ptr [r8+SPXE_HISTORY], 145
    mov dword ptr [r8+SPXE_SAMPLES], 40
    mov eax, 17
    mov edx, 144
    cmp dword ptr [r15+12], -1
    je .Lspxn_request_range
    mov eax, [rsp+80]
    mov edx, eax
.Lspxn_request_range:
    mov [r8+SPXE_START], eax
    mov [r8+SPXE_END], edx
    mov eax, [r15+8]
    mov [r8+SPXE_KIND], eax
    mov eax, [r12+SPXN_LOST]
    mov [r8+SPXE_LOST], eax
    mov eax, [rsp+76]
    mov [r8+SPXE_OFFSET], eax
    mov eax, [r12+SPXN_LAST_PGAIN]
    mov [r8+SPXE_LAST_GAIN], eax
    mov eax, [rsp+84]
    mov [r8+SPXE_COEF], eax
    mov dword ptr [r8+SPXE_CAPACITY], 40
    mov rcx, r13
    mov rdx, r8
    call spx_pitch_decode
    test eax, eax
    jz .Lspxn_bad
    # Sanitize adaptive excitation before adding the scaled innovation.
    xor ecx, ecx
.Lspxn_clip_exc32:
    movss xmm0, [rbx+SPXN_EXC32+rcx*4]
    ucomiss xmm0, [rip+spxn_neg_clip]
    jae .Lspxn_clip_upper
    movss xmm0, [rip+spxn_neg_clip]
.Lspxn_clip_upper:
    ucomiss xmm0, [rip+spxn_clip]
    jbe .Lspxn_clip_store
    movss xmm0, [rip+spxn_clip]
.Lspxn_clip_store:
    movss [rbx+SPXN_EXC32+rcx*4], xmm0
    inc ecx
    cmp ecx, 40
    jb .Lspxn_clip_exc32
    movss xmm0, [rbx+SPXN_PITCH_JOB+SPXE_GAIN_SUM]
    movss xmm1, [rsp+96]
    addss xmm1, xmm0
    movss [rsp+96], xmm1
    # Preserve the reference's integer pitch-multiple tests and double
    # .6/.67 thresholds when choosing a frame's strongest pitch.
    mov r9d, [rbx+SPXN_PITCH_JOB+SPXE_PITCH]
    xor r10d, r10d                     # far from existing pitch multiples
    mov r11d, 1
    mov ecx, 2
.Lspxn_best_far:
    mov eax, [rsp+100]
    imul eax, ecx
    sub eax, r9d
    cdq
    xor eax, edx
    sub eax, edx
    lea edx, [rcx+1]
    cmp eax, edx
    jae .Lspxn_best_far_next
    xor r11d, r11d
.Lspxn_best_far_next:
    inc ecx
    cmp ecx, 4
    jbe .Lspxn_best_far
    mov r10d, r11d
    xor r11d, r11d                     # near a new pitch's multiples
    mov ecx, 2
.Lspxn_best_near:
    imul eax, r9d, 1
    imul eax, ecx
    sub eax, [rsp+100]
    cdq
    xor eax, edx
    sub eax, edx
    lea edx, [rcx+1]
    cmp eax, edx
    jae .Lspxn_best_near_next
    mov r11d, 1
.Lspxn_best_near_next:
    inc ecx
    cmp ecx, 4
    jbe .Lspxn_best_near
    movss xmm1, [rsp+104]
    ucomiss xmm0, xmm1
    jbe .Lspxn_best_second
    test r10d, r10d
    jnz .Lspxn_best_update
.Lspxn_best_second:
    test r11d, r11d
    jz .Lspxn_best_third
    cvtss2sd xmm2, xmm1
    mulsd xmm2, [rip+spxn_point6]
    cvtss2sd xmm3, xmm0
    ucomisd xmm3, xmm2
    ja .Lspxn_best_update
.Lspxn_best_third:
    test r10d, r10d
    jnz .Lspxn_best_done
    cvtss2sd xmm2, xmm0
    mulsd xmm2, [rip+spxn_point67]
    cvtss2sd xmm3, xmm1
    ucomisd xmm2, xmm3
    jbe .Lspxn_best_done
.Lspxn_best_update:
    mov [rsp+100], r9d
    ucomiss xmm0, xmm1
    jbe .Lspxn_best_done
    movss [rsp+104], xmm0
.Lspxn_best_done:
    movss xmm0, [rsp+88]
    movss [rsp+92], xmm0
    mov edx, [r15+20]
    test edx, edx
    jz .Lspxn_energy_ready
    mov rcx, r13
    call spx_bits_read
    lea rdx, [rip+spxn_subgain1]
    cmp dword ptr [r15+20], 3
    jne .Lspxn_energy_table
    lea rdx, [rip+spxn_subgain3]
.Lspxn_energy_table:
    movss xmm0, [rdx+rax*4]
    mulss xmm0, [rsp+88]
    movss [rsp+92], xmm0
.Lspxn_energy_ready:
    xor eax, eax
.Lspxn_clear_innov:
    mov dword ptr [rbx+SPXN_INNOV+rax*4], 0
    inc eax
    cmp eax, 40
    jb .Lspxn_clear_innov
    cmp dword ptr [r15+28], -1
    jne .Lspxn_shape_innov
    lea rcx, [rbx+SPXN_INNOV]
    mov edx, 40
    lea r8, [r12+SPXN_SEED]
    movss xmm3, [rip+spxn_one]
    call spx_noise_decode
    test eax, eax
    jz .Lspxn_bad
    jmp .Lspxn_scale_innov
.Lspxn_shape_innov:
    mov rcx, r13
    lea rdx, [rbx+SPXN_INNOV]
    mov r8d, [r15+28]
    mov r9d, 40
    call spx_innovation_decode
    cmp eax, 40
    jne .Lspxn_bad
.Lspxn_scale_innov:
    xor eax, eax
    movss xmm1, [rsp+92]
.Lspxn_scale_innov_loop:
    movss xmm0, [rbx+SPXN_INNOV+rax*4]
    mulss xmm0, xmm1
    movss [rbx+SPXN_INNOV+rax*4], xmm0
    inc eax
    cmp eax, 40
    jb .Lspxn_scale_innov_loop
    cmp dword ptr [r15+24], 0
    je .Lspxn_combine_exc
    xor eax, eax
.Lspxn_clear_innov2:
    mov dword ptr [rbx+SPXN_INNOV2+rax*4], 0
    inc eax
    cmp eax, 40
    jb .Lspxn_clear_innov2
    mov rcx, r13
    lea rdx, [rbx+SPXN_INNOV2]
    mov r8d, [r15+28]
    mov r9d, 40
    call spx_innovation_decode
    cmp eax, 40
    jne .Lspxn_bad
    movss xmm1, [rsp+92]
    mulss xmm1, [rip+spxn_second]
    xor eax, eax
.Lspxn_add_innov2:
    movss xmm0, [rbx+SPXN_INNOV2+rax*4]
    mulss xmm0, xmm1
    addss xmm0, [rbx+SPXN_INNOV+rax*4]
    movss [rbx+SPXN_INNOV+rax*4], xmm0
    inc eax
    cmp eax, 40
    jb .Lspxn_add_innov2
.Lspxn_combine_exc:
    mov edx, [rsp+76]
    lea r8, [r12+SPXN_EXC+rdx*4]
    lea r9, [r12+SPXN_INNOVATION+rdx*4]
    xor eax, eax
.Lspxn_combine_loop:
    movss xmm0, [rbx+SPXN_EXC32+rax*4]
    addss xmm0, [rbx+SPXN_INNOV+rax*4]
    movss [r8+rax*4], xmm0
    mov edx, [rbx+SPXN_INNOV+rax*4]
    mov [r9+rax*4], edx
    inc eax
    cmp eax, 40
    jb .Lspxn_combine_loop
    cmp dword ptr [r12+SPXN_MODE], 1
    jne .Lspxn_next_subframe
    movss xmm0, [rsp+84]
    subss xmm0, [rip+spxn_point2f]
    mulss xmm0, [rip+spxn_1point5f]
    pxor xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, [rip+spxn_one]
    movss xmm1, [rip+spxn_point85f]
    mulss xmm1, xmm0
    movss xmm2, [rip+spxn_one]
    subss xmm2, xmm1
    movss [rsp+124], xmm2
    movss xmm1, [rip+spxn_point15f]
    mulss xmm1, xmm0
    movss [rsp+128], xmm1
    mulss xmm0, [rsp+88]
    cvtsi2sd xmm1, dword ptr [rsp+80]
    addsd xmm1, xmm1
    sqrtsd xmm1, xmm1
    cvtsd2ss xmm1, xmm1
    mulss xmm0, xmm1
    movss [rsp+132], xmm0               # pulse amplitude
    xor eax, eax
.Lspxn_voc_zero:
    mov dword ptr [r8+rax*4], 0
    inc eax
    cmp eax, 40
    jb .Lspxn_voc_zero
    mov ecx, [r12+SPXN_VOC_OFFSET]
.Lspxn_voc_pulse:
    cmp ecx, 40
    jge .Lspxn_voc_offset
    test ecx, ecx
    js .Lspxn_voc_skip
    mov eax, [rsp+132]
    mov [r8+rcx*4], eax
.Lspxn_voc_skip:
    add ecx, [rsp+80]
    jmp .Lspxn_voc_pulse
.Lspxn_voc_offset:
    sub ecx, 40
    mov [r12+SPXN_VOC_OFFSET], ecx
    xor eax, eax
.Lspxn_voc_sample:
    movss xmm0, [r8+rax*4]             # original pulse
    movaps xmm1, xmm0
    mulss xmm1, [rip+spxn_point7f]
    movss xmm2, [r12+SPXN_VOC_M1]
    mulss xmm2, [rip+spxn_point3f]
    addss xmm1, xmm2
    movss xmm2, [rbx+SPXN_INNOV+rax*4]
    mulss xmm2, [rsp+124]
    movss xmm3, [r12+SPXN_VOC_M2]
    mulss xmm3, [rsp+128]
    subss xmm2, xmm3
    addss xmm1, xmm2
    movss [r12+SPXN_VOC_M1], xmm0
    mov edx, [rbx+SPXN_INNOV+rax*4]
    mov [r12+SPXN_VOC_M2], edx
    movss xmm0, [r12+SPXN_VOC_MEAN]
    mulss xmm0, [rip+spxn_point8f]
    movaps xmm2, xmm1
    mulss xmm2, [rip+spxn_point2f]
    addss xmm0, xmm2
    movss [r12+SPXN_VOC_MEAN], xmm0
    subss xmm1, xmm0
    movss [r8+rax*4], xmm1
    inc eax
    cmp eax, 40
    jb .Lspxn_voc_sample
.Lspxn_next_subframe:
    inc dword ptr [rsp+72]
    cmp dword ptr [rsp+72], 4
    jb .Lspxn_subframe
    cmp dword ptr [r12+SPXN_LOST], 0
    jne .Lspxn_recovery_exc
    test dword ptr [r12+SPXN_FLAGS], 1
    jz .Lspxn_plain_exc
    movss xmm0, [r15+32]
    pxor xmm1, xmm1
    ucomiss xmm0, xmm1
    jbe .Lspxn_plain_exc
    lea rcx, [r12+SPXN_EXC-160]
    mov rdx, r14
    mov r8d, [rsp+100]
    movss xmm3, [r15+32]
    call spxn_comb80
    test eax, eax
    jz .Lspxn_bad
    lea rcx, [r12+SPXN_EXC+160]
    lea rdx, [r14+320]
    mov r8d, [rsp+100]
    movss xmm3, [r15+32]
    call spxn_comb80
    test eax, eax
    jz .Lspxn_bad
    jmp .Lspxn_synthesis
.Lspxn_recovery_exc:
    lea rcx, [r12+SPXN_EXC]
    mov edx, 160
    call spxn_rms
    addss xmm0, [rip+spxn_one]
    movss xmm1, [rsp+88]
    divss xmm1, xmm0
    minss xmm1, [rip+spxn_two]
    xor eax, eax
.Lspxn_recovery_scale:
    movss xmm0, [r12+SPXN_EXC+rax*4]
    mulss xmm0, xmm1
    movss [r12+SPXN_EXC+rax*4], xmm0
    # Preserve the reference's sequential scale/read of the delayed frame.
    mov edx, [r12+SPXN_EXC-160+rax*4]
    mov [r14+rax*4], edx
    inc eax
    cmp eax, 160
    jb .Lspxn_recovery_scale
    jmp .Lspxn_synthesis
.Lspxn_plain_exc:
    xor eax, eax
.Lspxn_plain_copy:
    mov edx, [r12+SPXN_EXC-160+rax*4]
    mov [r14+rax*4], edx
    inc eax
    cmp eax, 160
    jb .Lspxn_plain_copy
.Lspxn_synthesis:
    mov dword ptr [rsp+72], 0
.Lspxn_synth_sub:
    lea rcx, [r12+SPXN_OLD_LSP]
    lea rdx, [rbx+SPXN_QLSP]
    lea r8, [rbx+SPXN_INTERP]
    mov r9d, 10
    mov eax, [rsp+72]
    mov [rsp+32], eax
    mov dword ptr [rsp+40], 4
    mov eax, [rip+spxn_margin]
    mov [rsp+48], eax
    call spx_lsp_interpolate
    test eax, eax
    jz .Lspxn_bad
    lea rcx, [rbx+SPXN_INTERP]
    lea rdx, [rbx+SPXN_AK]
    mov r8d, 10
    mov r9d, 10
    call spx_lsp_to_lpc
    test eax, eax
    jz .Lspxn_bad
    movss xmm0, [rip+spxn_one]
    xor eax, eax
.Lspxn_pi_gain:
    movss xmm1, [rbx+SPXN_AK+rax*4+4]
    subss xmm1, [rbx+SPXN_AK+rax*4]
    addss xmm0, xmm1
    add eax, 2
    cmp eax, 10
    jb .Lspxn_pi_gain
    mov eax, [rsp+72]
    movss [r12+SPXN_PI_GAIN+rax*4], xmm0
    imul eax, eax, 160
    lea rcx, [r14+rax]
    lea rdx, [r12+SPXN_LPC]
    mov r8, rcx
    mov r9d, 40
    mov dword ptr [rsp+32], 10
    lea rax, [r12+SPXN_MEM_SP]
    mov [rsp+40], rax
    call spx_iir_mem
    test eax, eax
    jz .Lspxn_bad
    xor eax, eax
.Lspxn_install_lpc:
    mov edx, [rbx+SPXN_AK+rax*4]
    mov [r12+SPXN_LPC+rax*4], edx
    inc eax
    cmp eax, 10
    jb .Lspxn_install_lpc
    inc dword ptr [rsp+72]
    cmp dword ptr [rsp+72], 4
    jb .Lspxn_synth_sub
    test dword ptr [r12+SPXN_FLAGS], 2
    jz .Lspxn_track_level
    mov rcx, r14
    mov rdx, r14
    mov r8d, 160
    mov r9d, 1
    test dword ptr [r12+SPXN_FLAGS], 4
    jz .Lspxn_hp_id
    mov r9d, 3
.Lspxn_hp_id:
    lea rax, [r12+SPXN_MEM_HP]
    mov [rsp+32], rax
    call spx_highpass
    test eax, eax
    jz .Lspxn_bad
.Lspxn_track_level:
    movss xmm0, [rsp+88]
    addss xmm0, [rip+spxn_one]
    movss [r12+SPXN_LEVEL], xmm0
    movss xmm1, [r12+SPXN_MAX_LEVEL]
    mulss xmm1, [rip+spxn_point99f]
    maxss xmm1, xmm0
    movss [r12+SPXN_MAX_LEVEL], xmm1
    movss xmm2, [r12+SPXN_MIN_LEVEL]
    mulss xmm2, [rip+spxn_1point01f]
    addss xmm2, [rip+spxn_one]
    minss xmm2, xmm0
    movss [r12+SPXN_MIN_LEVEL], xmm2
    addss xmm2, [rip+spxn_one]
    ucomiss xmm1, xmm2
    jae .Lspxn_level_ready
    movss [r12+SPXN_MAX_LEVEL], xmm2
.Lspxn_level_ready:
    xor eax, eax
.Lspxn_save_lsp:
    mov edx, [rbx+SPXN_QLSP+rax*4]
    mov [r12+SPXN_OLD_LSP+rax*4], edx
    inc eax
    cmp eax, 10
    jb .Lspxn_save_lsp
    mov dword ptr [r12+SPXN_FIRST], 0
    mov dword ptr [r12+SPXN_LOST], 0
    mov eax, [rsp+100]
    mov [r12+SPXN_LAST_PITCH], eax
    movss xmm0, [rsp+96]
    mulss xmm0, [rip+spxn_point25f]
    movss [r12+SPXN_LAST_PGAIN], xmm0
    mov eax, [r12+SPXN_PGAIN_INDEX]
    movss [r12+SPXN_PGAIN_BUF+rax*4], xmm0
    inc eax
    xor edx, edx
    cmp eax, 3
    cmove eax, edx
    mov [r12+SPXN_PGAIN_INDEX], eax
    mov eax, [rsp+88]
    mov [r12+SPXN_LAST_OL_GAIN], eax
    jmp .Lspxn_finish
.Lspxn_lost:
    mov dword ptr [rsp+120], 0
    mov eax, [r12+SPXN_LOST]
    pxor xmm0, xmm0
    cmp eax, 10
    jae .Lspxn_lost_fact
    lea rdx, [rip+spxn_attenuation]
    movss xmm0, [rdx+rax*4]
.Lspxn_lost_fact:
    movss [rsp+88], xmm0
    # Median of the last three frame pitch gains.
    movss xmm0, [r12+SPXN_PGAIN_BUF]
    movss xmm1, [r12+SPXN_PGAIN_BUF+4]
    movss xmm2, [r12+SPXN_PGAIN_BUF+8]
    movaps xmm3, xmm0
    minss xmm0, xmm1
    maxss xmm1, xmm3
    maxss xmm0, xmm2
    minss xmm0, xmm1
    movss xmm1, [r12+SPXN_LAST_PGAIN]
    ucomiss xmm0, xmm1
    jae .Lspxn_lost_median
    movss [r12+SPXN_LAST_PGAIN], xmm0
    movaps xmm1, xmm0
.Lspxn_lost_median:
    # .85 is an unsuffixed double literal in the reference.
    cvtss2sd xmm0, xmm1
    ucomisd xmm0, [rip+spxn_point85]
    jbe .Lspxn_lost_pitch_gain
    movss xmm1, [rip+spxn_point85f]
.Lspxn_lost_pitch_gain:
    mulss xmm1, [rsp+88]
    addss xmm1, [rip+spxn_tiny]
    movss [rsp+92], xmm1
    lea rcx, [r12+SPXN_EXC]
    mov edx, 160
    call spxn_rms
    movss xmm1, [rsp+92]
    mulss xmm1, xmm1
    movss xmm2, [rip+spxn_one]
    subss xmm2, xmm1
    mulss xmm2, [rsp+88]
    mulss xmm0, xmm2
    movss [rsp+96], xmm0
    xor eax, eax
.Lspxn_lost_shift:
    mov edx, [r12+SPXN_EXCBUF+640+rax*4]
    mov [r12+SPXN_EXCBUF+rax*4], edx
    inc eax
    cmp eax, 340
    jb .Lspxn_lost_shift
    lea rcx, [rbx+SPXN_INNOV]
    mov edx, 1
    lea r8, [r12+SPXN_SEED]
    mov eax, [r12+SPXN_LOST]
    inc eax
    cvtsi2ss xmm3, eax
    call spx_noise_decode
    test eax, eax
    jz .Lspxn_bad
    cvttss2si eax, [rbx+SPXN_INNOV]
    add eax, [r12+SPXN_LAST_PITCH]
    mov edx, 144
    cmp eax, edx
    cmovg eax, edx
    mov edx, 17
    cmp eax, edx
    cmovl eax, edx
    mov [rsp+100], eax
    lea rcx, [rbx+SPXN_OUT]
    mov edx, 160
    lea r8, [r12+SPXN_SEED]
    movss xmm3, [rsp+96]
    call spx_noise_decode
    test eax, eax
    jz .Lspxn_bad
    xor ecx, ecx
.Lspxn_lost_sample:
    mov eax, ecx
    sub eax, [rsp+100]
    movsxd rax, eax
    movss xmm0, [r12+SPXN_EXC+rax*4]
    addss xmm0, [rip+spxn_tiny]
    mulss xmm0, [rsp+92]
    addss xmm0, [r14+rcx*4]
    movss [r12+SPXN_EXC+rcx*4], xmm0
    inc ecx
    cmp ecx, 160
    jb .Lspxn_lost_sample
    lea rcx, [r12+SPXN_LPC]
    mov rdx, rcx
    mov r8d, 10
    movss xmm3, [rip+spxn_point98f]
    call spx_bw_lpc
    test eax, eax
    jz .Lspxn_bad
    lea rcx, [r12+SPXN_EXC-160]
    lea rdx, [r12+SPXN_LPC]
    mov r8, r14
    mov r9d, 160
    mov dword ptr [rsp+32], 10
    lea rax, [r12+SPXN_MEM_SP]
    mov [rsp+40], rax
    call spx_iir_mem
    test eax, eax
    jz .Lspxn_bad
    mov rcx, r14
    mov rdx, r14
    mov r8d, 160
    mov r9d, 1
    lea rax, [r12+SPXN_MEM_HP]
    mov [rsp+32], rax
    call spx_highpass
    test eax, eax
    jz .Lspxn_bad
    mov dword ptr [r12+SPXN_FIRST], 0
    inc dword ptr [r12+SPXN_LOST]
    mov eax, [r12+SPXN_PGAIN_INDEX]
    mov edx, [rsp+92]
    mov [r12+SPXN_PGAIN_BUF+rax*4], edx
    inc eax
    xor edx, edx
    cmp eax, 3
    cmove eax, edx
    mov [r12+SPXN_PGAIN_INDEX], eax
.Lspxn_finish:
    mov eax, [r13+SPXB_POS]
    cmp eax, [rsp+120]
    jne .Lspxn_bad
    cmp dword ptr [r13+SPXB_ERROR], 0
    jne .Lspxn_bad
    xor eax, eax
.Lspxn_commit_live:
    mov rdx, [r12+rax]
    mov [rbx+rax], rdx
    add eax, 8
    cmp eax, SPXN_LIVE
    jb .Lspxn_commit_live
    xor eax, eax
.Lspxn_commit_output:
    mov edx, [r14+rax*4]
    mov [rdi+rax*4], edx
    inc eax
    cmp eax, 160
    jb .Lspxn_commit_output
    test rsi, rsi
    jz .Lspxn_success
    mov eax, [r13+SPXB_POS]
    mov [rsi+SPXB_POS], eax
.Lspxn_success:
    mov eax, 160
    jmp .Lspxn_frame_return
.Lspxn_packet_end:
    cmp dword ptr [r13+SPXB_ERROR], 0
    jne .Lspxn_bad
    mov eax, [r12+SPXN_STEREO_CODE]
    mov [rbx+SPXN_STEREO_CODE], eax
    mov eax, [r13+SPXB_POS]
    mov [rsi+SPXB_POS], eax
    xor eax, eax
    jmp .Lspxn_frame_return
.Lspxn_short:
    mov dword ptr [r13+SPXB_ERROR], 1
.Lspxn_bad:
    test rsi, rsi
    jz .Lspxn_bad_plain
    cmp dword ptr [r13+SPXB_ERROR], 0
    je .Lspxn_bad_plain
    mov dword ptr [rsi+SPXB_ERROR], 1
.Lspxn_bad_plain:
    mov eax, -1
.Lspxn_frame_return:
    add rsp, 256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_nb_frame
