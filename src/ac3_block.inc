# AC-3 audio blocks (included by ac3.s): side information, exponents, bit
# allocation, mantissas, coupling, rematrixing and the transform.

# reg = address of dword element index of array.
.macro AC3_SLOT reg, array, index
    lea \reg, [rip + \array]
    lea \reg, [\reg + \index*4]
.endm

# Raises the bit allocation stage of channel ECX to at least EDX.
LOCALFN ac3_stage
    lea rax, [rip + ac3_stages]
    movzx r8d, byte ptr [rax + rcx]
    cmp r8d, edx
    jae .Lac3_stage_done
    mov byte ptr [rax + rcx], dl
.Lac3_stage_done:
    ret
ENDFN ac3_stage

# ECX=first channel, EDX=stage: raises channels ECX..ac3_channels.
LOCALFN ac3_stage_range
    push rbx
    mov ebx, ecx
    mov r9d, edx
.Lac3_stage_range_next:
    cmp ebx, [rip + ac3_channels]
    ja .Lac3_stage_range_done
    mov ecx, ebx
    mov edx, r9d
    call ac3_stage
    inc ebx
    jmp .Lac3_stage_range_next
.Lac3_stage_range_done:
    pop rbx
    ret
ENDFN ac3_stage_range

# Parse one audio block into coefficients, ECX=block -> EAX=1, or 0 on failure.
# Locals: 32 first channel of the side information loops (0 with coupling).
LOCALFN ac3_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov ebx, ecx                          # block
    mov r12d, [rip + ac3_nf]
    mov r13d, [rip + ac3_channels]
    mov qword ptr [rip + ac3_stages], 0
    # Block switch and dither flags.
    mov esi, 1
.Lac3_block_switch:
    cmp esi, r12d
    ja .Lac3_block_dither
    xor eax, eax
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_switch_read
    cmp dword ptr [rip + eac3_switch_syntax], 0
    je .Lac3_block_switch_store
.Lac3_block_switch_read:
    mov ecx, 1
    call ac3_get
.Lac3_block_switch_store:
    AC3_SLOT rcx, ac3_blksw, rsi
    mov [rcx], eax
    inc esi
    jmp .Lac3_block_switch
.Lac3_block_dither:
    mov esi, 1
.Lac3_block_dither_next:
    cmp esi, r12d
    ja .Lac3_block_range
    mov eax, 1
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_dither_read
    cmp dword ptr [rip + eac3_dither_syntax], 0
    je .Lac3_block_dither_store
.Lac3_block_dither_read:
    mov ecx, 1
    call ac3_get
.Lac3_block_dither_store:
    AC3_SLOT rcx, ac3_dith, rsi
    mov [rcx], eax
    inc esi
    jmp .Lac3_block_dither_next
.Lac3_block_range:
    # Dynamic range words: dual mono sends the first channel's second.
    xor esi, esi
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Lac3_block_range_next
    mov esi, 1
.Lac3_block_range_next:
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lac3_block_range_none
    mov ecx, 8
    call ac3_get
    lea rcx, [rip + ac3_dynrng]
    mov eax, [rcx + rax*4]
    lea rcx, [rip + ac3_dyn]
    mov [rcx + rsi*4], eax
    jmp .Lac3_block_range_done
.Lac3_block_range_none:
    test ebx, ebx
    jnz .Lac3_block_range_done
    mov eax, [rip + ac3_one]
    lea rcx, [rip + ac3_dyn]
    mov [rcx + rsi*4], eax
.Lac3_block_range_done:
    dec esi
    jns .Lac3_block_range_next
    # E-AC-3 spectral extension precedes coupling strategy.
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_read
    mov ecx, ebx
    call eac3_spx_parse
    test eax, eax
    jnz .Lac3_block_fail
.Lac3_block_cpl_frame:
    mov eax, 1
    cmp dword ptr [rip + ac3_acmod], 1
    jbe .Lac3_block_cpl_dispatch
    AC3_SLOT rcx, eac3_cplstre, rbx
    mov eax, [rcx]
    jmp .Lac3_block_cpl_dispatch
.Lac3_block_cpl_read:
    # Coupling strategy.
    mov ecx, 1
    call ac3_get                          # cplstre
.Lac3_block_cpl_dispatch:
    test eax, eax
    jnz .Lac3_block_cpl_new
    test ebx, ebx
    jz .Lac3_block_fail
    jmp .Lac3_block_coords
.Lac3_block_cpl_new:
    mov rax, 0x0303030303030303
    mov [rip + ac3_stages], rax
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_inuse_read
    AC3_SLOT rcx, eac3_cplinu, rbx
    mov eax, [rcx]
    jmp .Lac3_block_cpl_inuse_store
.Lac3_block_cpl_inuse_read:
    mov ecx, 1
    call ac3_get
.Lac3_block_cpl_inuse_store:
    mov [rip + ac3_cplinu], eax
    test eax, eax
    jz .Lac3_block_cpl_off
    cmp dword ptr [rip + ac3_acmod], 2
    jb .Lac3_block_fail
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_channels
    mov ecx, 1
    call ac3_get                          # ecplinu
    test eax, eax
    jnz .Lac3_block_unsupported
.Lac3_block_cpl_channels:
    mov esi, 1
.Lac3_block_cpl_channel:
    cmp esi, r12d
    ja .Lac3_block_cpl_phase
    mov eax, 1
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_channel_read
    cmp dword ptr [rip + ac3_acmod], 2
    je .Lac3_block_cpl_channel_store
.Lac3_block_cpl_channel_read:
    mov ecx, 1
    call ac3_get
.Lac3_block_cpl_channel_store:
    AC3_SLOT rcx, ac3_incpl, rsi
    mov [rcx], eax
    inc esi
    jmp .Lac3_block_cpl_channel
.Lac3_block_cpl_phase:
    cmp dword ptr [rip + ac3_acmod], 2
    jne .Lac3_block_cpl_range
    mov ecx, 1
    call ac3_get
    mov [rip + ac3_phsinu], eax
.Lac3_block_cpl_range:
    mov ecx, 4
    call ac3_get
    mov r14d, eax                         # begin subband
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_end_read
    cmp dword ptr [rip + eac3_spx_active], 0
    je .Lac3_block_cpl_end_read
    mov eax, [rip + eac3_spx_start]
    sub eax, 37
    xor edx, edx
    mov ecx, 12
    div ecx
    mov r15d, eax
    jmp .Lac3_block_cpl_end_valid
.Lac3_block_cpl_end_read:
    mov ecx, 4
    call ac3_get
    lea r15d, [rax + 3]                   # end subband
.Lac3_block_cpl_end_valid:
    cmp r14d, r15d
    jae .Lac3_block_fail
    imul eax, r14d, 12
    add eax, 37
    mov [rip + ac3_start], eax
    imul eax, r15d, 12
    add eax, 37
    mov [rip + ac3_end], eax
    test ebx, ebx
    jnz .Lac3_block_cpl_struct
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_default_ac3
    lea rcx, [rip + ac3_bndstrc]
    lea rdx, [rip + eac3_default_cpl_bands]
    movups xmm0, [rdx]
    movups [rcx], xmm0
    movzx eax, word ptr [rdx + 16]
    mov [rcx + 16], ax
    jmp .Lac3_block_cpl_struct
.Lac3_block_cpl_default_ac3:
    lea rcx, [rip + ac3_bndstrc]
    xorps xmm0, xmm0
    movups [rcx], xmm0
    movups [rcx + 16], xmm0
.Lac3_block_cpl_struct:
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_cpl_struct_read
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Lac3_block_cpl_sizes
.Lac3_block_cpl_struct_read:
    lea esi, [r14 + 1]                    # band structure bits for subbands begin+1..end-1
.Lac3_block_cpl_struct_next:
    cmp esi, r15d
    jae .Lac3_block_cpl_sizes
    mov ecx, 1
    call ac3_get
    lea rcx, [rip + ac3_bndstrc]
    mov [rcx + rsi], al
    inc esi
    jmp .Lac3_block_cpl_struct_next
.Lac3_block_cpl_sizes:
    lea rcx, [rip + ac3_bndstrc]
    lea rdx, [rip + ac3_bndsz]
    xor edi, edi                          # band
    mov byte ptr [rdx], 12
    lea esi, [r14 + 1]
.Lac3_block_cpl_size_next:
    cmp esi, r15d
    jae .Lac3_block_cpl_count
    cmp byte ptr [rcx + rsi], 0
    je .Lac3_block_cpl_size_band
    add byte ptr [rdx + rdi], 12
    jmp .Lac3_block_cpl_size_step
.Lac3_block_cpl_size_band:
    inc edi
    mov byte ptr [rdx + rdi], 12
.Lac3_block_cpl_size_step:
    inc esi
    jmp .Lac3_block_cpl_size_next
.Lac3_block_cpl_count:
    inc edi
    mov [rip + ac3_ncplbnd], edi
    jmp .Lac3_block_coords
.Lac3_block_cpl_off:
    mov esi, 1
.Lac3_block_cpl_off_next:
    cmp esi, r12d
    ja .Lac3_block_cpl_off_done
    AC3_SLOT rcx, ac3_incpl, rsi
    mov dword ptr [rcx], 0
    AC3_SLOT rcx, eac3_first_coords, rsi
    mov dword ptr [rcx], 1
    inc esi
    jmp .Lac3_block_cpl_off_next
.Lac3_block_cpl_off_done:
    mov dword ptr [rip + ac3_phsinu], 0
    mov dword ptr [rip + eac3_first_leak], 1
.Lac3_block_coords:
    # Coupling coordinates and phase flags.
    cmp dword ptr [rip + ac3_cplinu], 0
    je .Lac3_block_remat
    xor edi, edi                          # coordinates sent
    mov esi, 1
.Lac3_block_coord_channel:
    cmp esi, r12d
    ja .Lac3_block_coord_phase
    AC3_SLOT rcx, ac3_incpl, rsi
    cmp dword ptr [rcx], 0
    je .Lac3_block_coord_unused
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_coord_read
    AC3_SLOT rcx, eac3_first_coords, rsi
    cmp dword ptr [rcx], 0
    jne .Lac3_block_coord_new
.Lac3_block_coord_read:
    mov ecx, 1
    call ac3_get                          # cplcoe
    test eax, eax
    jnz .Lac3_block_coord_new
    test ebx, ebx
    jz .Lac3_block_fail
    jmp .Lac3_block_coord_next
.Lac3_block_coord_new:
    AC3_SLOT rcx, eac3_first_coords, rsi
    mov dword ptr [rcx], 0
    mov edi, 1
    mov ecx, 2
    call ac3_get
    lea r14d, [rax + rax*2]               # 3 * mstrcplco
    xor r15d, r15d                        # band
.Lac3_block_coord_band:
    cmp r15d, [rip + ac3_ncplbnd]
    jae .Lac3_block_coord_next
    mov ecx, 4
    call ac3_get
    mov r8d, eax                          # cplcoexp
    mov ecx, 4
    call ac3_get                          # cplcomant
    cmp r8d, 15
    jne .Lac3_block_coord_normal
    shl eax, 22
    jmp .Lac3_block_coord_shift
.Lac3_block_coord_normal:
    add eax, 16
    shl eax, 21
.Lac3_block_coord_shift:
    lea ecx, [r8 + r14]
    sar eax, cl
    mov ecx, esi
    shl ecx, 5
    add ecx, r15d
    lea rdx, [rip + ac3_coords]
    mov [rdx + rcx*4], eax
    inc r15d
    jmp .Lac3_block_coord_band
.Lac3_block_coord_unused:
    AC3_SLOT rcx, eac3_first_coords, rsi
    mov dword ptr [rcx], 1
.Lac3_block_coord_next:
    inc esi
    jmp .Lac3_block_coord_channel
.Lac3_block_coord_phase:
    cmp dword ptr [rip + ac3_acmod], 2
    jne .Lac3_block_remat
    test edi, edi
    jz .Lac3_block_remat
    xor esi, esi
.Lac3_block_phase_next:
    cmp esi, [rip + ac3_ncplbnd]
    jae .Lac3_block_remat
    xor eax, eax
    cmp dword ptr [rip + ac3_phsinu], 0
    je .Lac3_block_phase_store
    mov ecx, 1
    call ac3_get
.Lac3_block_phase_store:
    lea rcx, [rip + ac3_phase]
    mov [rcx + rsi], al
    inc esi
    jmp .Lac3_block_phase_next
.Lac3_block_remat:
    # Rematrixing flags (2/0 mode).
    cmp dword ptr [rip + ac3_acmod], 2
    jne .Lac3_block_first
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_remat_read
    test ebx, ebx
    jz .Lac3_block_remat_new
.Lac3_block_remat_read:
    mov ecx, 1
    call ac3_get                          # rematstr
    test eax, eax
    jnz .Lac3_block_remat_new
    test ebx, ebx
    jnz .Lac3_block_first
    mov dword ptr [rip + ac3_nremat], 0
    jmp .Lac3_block_first
.Lac3_block_remat_new:
    mov edi, 4
    cmp dword ptr [rip + ac3_cplinu], 0
    je .Lac3_block_remat_spx
    mov eax, [rip + ac3_start]
    cmp eax, 61
    ja .Lac3_block_remat_count
    dec edi
    cmp eax, 37
    jne .Lac3_block_remat_count
    dec edi
    jmp .Lac3_block_remat_count
.Lac3_block_remat_spx:
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_remat_count
    cmp dword ptr [rip + eac3_spx_active], 0
    je .Lac3_block_remat_count
    cmp dword ptr [rip + eac3_spx_start], 61
    ja .Lac3_block_remat_count
    dec edi
.Lac3_block_remat_count:
    mov [rip + ac3_nremat], edi
    xor esi, esi
.Lac3_block_remat_flag:
    cmp esi, edi
    jae .Lac3_block_first
    mov ecx, 1
    call ac3_get
    lea rcx, [rip + ac3_remat]
    mov [rcx + rsi*4], eax
    inc esi
    jmp .Lac3_block_remat_flag
.Lac3_block_first:
    xor eax, eax
    cmp dword ptr [rip + ac3_cplinu], 0
    sete al
    mov [rsp + 32], eax                   # first channel: coupling (0) when in use
    # Exponent strategies.
    mov esi, eax
.Lac3_block_expstr:
    cmp esi, r13d
    ja .Lac3_block_bandwidth
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_expstr_ac3
    mov edx, ebx
    shl edx, 3
    add edx, esi
    AC3_SLOT rcx, eac3_expstr, rdx
    mov eax, [rcx]
    jmp .Lac3_block_expstr_store
.Lac3_block_expstr_ac3:
    mov ecx, 2
    cmp esi, [rip + ac3_lfe_ch]
    jne .Lac3_block_expstr_read
    mov ecx, 1
.Lac3_block_expstr_read:
    call ac3_get
.Lac3_block_expstr_store:
    test ebx, ebx
    jnz .Lac3_block_expstr_valid
    test eax, eax
    jz .Lac3_block_fail
.Lac3_block_expstr_valid:
    AC3_SLOT rcx, ac3_expstr, rsi
    mov [rcx], eax
    test eax, eax
    jz .Lac3_block_expstr_next
    lea rcx, [rip + ac3_stages]
    mov byte ptr [rcx + rsi], 3
.Lac3_block_expstr_next:
    inc esi
    jmp .Lac3_block_expstr
.Lac3_block_bandwidth:
    # Channel bandwidths and exponent group counts.
    mov esi, 1
.Lac3_block_bandwidth_next:
    cmp esi, r12d
    ja .Lac3_block_cpl_groups
    AC3_SLOT rcx, ac3_start, rsi
    mov dword ptr [rcx], 0
    AC3_SLOT rcx, ac3_expstr, rsi
    mov edi, [rcx]
    test edi, edi
    jz .Lac3_block_bandwidth_step
    AC3_SLOT rcx, ac3_end, rsi
    mov r14d, [rcx]                       # previous end
    AC3_SLOT rcx, ac3_incpl, rsi
    cmp dword ptr [rcx], 0
    je .Lac3_block_bandwidth_code
    mov eax, [rip + ac3_start]
    jmp .Lac3_block_bandwidth_end
.Lac3_block_bandwidth_code:
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_bandwidth_read
    AC3_SLOT rcx, eac3_spx_ch, rsi
    cmp dword ptr [rcx], 0
    je .Lac3_block_bandwidth_read
    mov eax, [rip + eac3_spx_start]
    jmp .Lac3_block_bandwidth_end
.Lac3_block_bandwidth_read:
    mov ecx, 6
    call ac3_get
    cmp eax, 60
    ja .Lac3_block_fail
    lea eax, [rax + rax*2 + 73]
.Lac3_block_bandwidth_end:
    AC3_SLOT rcx, ac3_end, rsi
    mov [rcx], eax
    mov r15d, eax
    lea ecx, [rdi - 1]
    mov r8d, 3
    shl r8d, cl                           # group size
    lea eax, [r15 + r8 - 4]
    xor edx, edx
    div r8d
    AC3_SLOT rcx, ac3_ngrps, rsi
    mov [rcx], eax
    test ebx, ebx
    jz .Lac3_block_bandwidth_step
    cmp r15d, r14d
    je .Lac3_block_bandwidth_step
    mov rax, 0x0303030303030303
    mov [rip + ac3_stages], rax
.Lac3_block_bandwidth_step:
    inc esi
    jmp .Lac3_block_bandwidth_next
.Lac3_block_cpl_groups:
    cmp dword ptr [rip + ac3_cplinu], 0
    je .Lac3_block_exponents
    mov edi, [rip + ac3_expstr]
    test edi, edi
    jz .Lac3_block_exponents
    lea ecx, [rdi - 1]
    mov r8d, 3
    shl r8d, cl
    mov eax, [rip + ac3_end]
    sub eax, [rip + ac3_start]
    xor edx, edx
    div r8d
    mov [rip + ac3_ngrps], eax
.Lac3_block_exponents:
    mov esi, [rsp + 32]
.Lac3_block_exponents_next:
    cmp esi, r13d
    ja .Lac3_block_allocation_info
    AC3_SLOT rcx, ac3_expstr, rsi
    cmp dword ptr [rcx], 0
    je .Lac3_block_exponents_step
    mov ecx, esi
    call ac3_exponents
    test eax, eax
    jz .Lac3_block_fail
.Lac3_block_exponents_step:
    inc esi
    jmp .Lac3_block_exponents_next
.Lac3_block_allocation_info:
    # Bit allocation parameters.
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_allocation_read
    cmp dword ptr [rip + eac3_ba_syntax], 0
    je .Lac3_block_snr
.Lac3_block_allocation_read:
    mov ecx, 1
    call ac3_get                          # baie
    test eax, eax
    jnz .Lac3_block_allocation_new
    test ebx, ebx
    jz .Lac3_block_fail
    jmp .Lac3_block_snr
.Lac3_block_allocation_new:
    mov ecx, 2
    call ac3_get
    lea rcx, [rip + ac3_slow_decay]
    movzx eax, word ptr [rcx + rax*2]
    mov ecx, [rip + ac3_shift]
    shr eax, cl
    mov [rip + ac3_sdecay], eax
    mov ecx, 2
    call ac3_get
    lea rcx, [rip + ac3_fast_decay]
    movzx eax, word ptr [rcx + rax*2]
    mov ecx, [rip + ac3_shift]
    shr eax, cl
    mov [rip + ac3_fdecay], eax
    mov ecx, 2
    call ac3_get
    lea rcx, [rip + ac3_slow_gain]
    movzx eax, word ptr [rcx + rax*2]
    mov [rip + ac3_sgain], eax
    mov ecx, 2
    call ac3_get
    lea rcx, [rip + ac3_db_per_bit]
    movzx eax, word ptr [rcx + rax*2]
    mov [rip + ac3_dbknee], eax
    mov ecx, 3
    call ac3_get
    lea rcx, [rip + ac3_floor]
    movsx eax, word ptr [rcx + rax*2]
    mov [rip + ac3_floorv], eax
    mov ecx, [rsp + 32]
    mov edx, 2
    call ac3_stage_range
.Lac3_block_snr:
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_snr_ac3
    mov ecx, ebx
    mov edx, [rsp + 32]
    call eac3_block_snr
    cmp eax, AC3_UNSUPPORTED
    je .Lac3_block_unsupported
    jmp .Lac3_block_leak
.Lac3_block_snr_ac3:
    # SNR offsets and fast gains.
    mov ecx, 1
    call ac3_get                          # snroffste
    test eax, eax
    jnz .Lac3_block_snr_new
    test ebx, ebx
    jz .Lac3_block_fail
    jmp .Lac3_block_leak
.Lac3_block_snr_new:
    mov ecx, 6
    call ac3_get
    sub eax, 15
    shl eax, 4
    mov edi, eax                          # coarse offset
    mov esi, [rsp + 32]
.Lac3_block_snr_channel:
    cmp esi, r13d
    ja .Lac3_block_leak
    mov ecx, 4
    call ac3_get
    add eax, edi
    shl eax, 2
    AC3_SLOT rcx, ac3_snr, rsi
    test ebx, ebx
    jz .Lac3_block_snr_store
    cmp [rcx], eax
    je .Lac3_block_snr_store
    mov [rcx], eax
    mov ecx, esi
    mov edx, 1
    call ac3_stage
    jmp .Lac3_block_snr_gain
.Lac3_block_snr_store:
    mov [rcx], eax
.Lac3_block_snr_gain:
    mov ecx, 3
    call ac3_get
    lea rcx, [rip + ac3_fast_gain]
    movzx eax, word ptr [rcx + rax*2]
    AC3_SLOT rcx, ac3_fgain, rsi
    mov edx, [rcx]
    mov [rcx], eax
    test ebx, ebx
    jz .Lac3_block_snr_step
    cmp edx, eax
    je .Lac3_block_snr_step
    mov ecx, esi
    mov edx, 2
    call ac3_stage
.Lac3_block_snr_step:
    inc esi
    jmp .Lac3_block_snr_channel
.Lac3_block_leak:
    # Coupling leak initialization.
    cmp dword ptr [rip + ac3_cplinu], 0
    je .Lac3_block_delta
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_leak_read
    cmp dword ptr [rip + eac3_first_leak], 0
    jne .Lac3_block_leak_new
.Lac3_block_leak_read:
    mov ecx, 1
    call ac3_get                          # cplleake
    test eax, eax
    jnz .Lac3_block_leak_new
    test ebx, ebx
    jz .Lac3_block_fail
    jmp .Lac3_block_delta
.Lac3_block_leak_new:
    mov dword ptr [rip + eac3_first_leak], 0
    mov ecx, 3
    call ac3_get
    mov esi, eax
    mov ecx, 3
    call ac3_get
    mov edi, eax
    test ebx, ebx
    jz .Lac3_block_leak_store
    cmp esi, [rip + ac3_cplfleak]
    jne .Lac3_block_leak_changed
    cmp edi, [rip + ac3_cplsleak]
    je .Lac3_block_leak_store
.Lac3_block_leak_changed:
    xor ecx, ecx
    mov edx, 2
    call ac3_stage
.Lac3_block_leak_store:
    mov [rip + ac3_cplfleak], esi
    mov [rip + ac3_cplsleak], edi
.Lac3_block_delta:
    # Delta bit allocation.
    xor eax, eax
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_delta_read
    cmp dword ptr [rip + eac3_dba_syntax], 0
    je .Lac3_block_delta_dispatch
.Lac3_block_delta_read:
    mov ecx, 1
    call ac3_get                          # deltbaie
.Lac3_block_delta_dispatch:
    test eax, eax
    jnz .Lac3_block_delta_new
    test ebx, ebx
    jnz .Lac3_block_allocate
    lea rcx, [rip + ac3_dbamode]
    xor eax, eax
.Lac3_block_delta_none:
    mov dword ptr [rcx + rax*4], 2
    inc eax
    cmp eax, 8
    jb .Lac3_block_delta_none
    jmp .Lac3_block_allocate
.Lac3_block_delta_new:
    mov esi, [rsp + 32]
.Lac3_block_delta_mode:
    cmp esi, r12d
    ja .Lac3_block_delta_segments
    mov ecx, 2
    call ac3_get
    cmp eax, 3
    je .Lac3_block_fail
    AC3_SLOT rcx, ac3_dbamode, rsi
    mov [rcx], eax
    mov ecx, esi
    mov edx, 2
    call ac3_stage
    inc esi
    jmp .Lac3_block_delta_mode
.Lac3_block_delta_segments:
    mov esi, [rsp + 32]
.Lac3_block_delta_channel:
    cmp esi, r12d
    ja .Lac3_block_allocate
    AC3_SLOT rcx, ac3_dbamode, rsi
    cmp dword ptr [rcx], 1
    jne .Lac3_block_delta_step
    mov ecx, 3
    call ac3_get
    lea edi, [rax + 1]
    AC3_SLOT rcx, ac3_dbansegs, rsi
    mov [rcx], edi
    lea r14d, [rsi*8]                     # segment slot
    add edi, r14d
.Lac3_block_delta_segment:
    cmp r14d, edi
    jae .Lac3_block_delta_step
    mov ecx, 5
    call ac3_get
    lea rcx, [rip + ac3_dbaoffst]
    mov [rcx + r14], al
    mov ecx, 4
    call ac3_get
    lea rcx, [rip + ac3_dbalen]
    mov [rcx + r14], al
    mov ecx, 3
    call ac3_get
    lea rcx, [rip + ac3_dbaval]
    mov [rcx + r14], al
    inc r14d
    jmp .Lac3_block_delta_segment
.Lac3_block_delta_step:
    inc esi
    jmp .Lac3_block_delta_channel
.Lac3_block_allocate:
    # Run each channel's bit allocation from the earliest stage that changed.
    mov esi, [rsp + 32]
.Lac3_block_allocate_channel:
    cmp esi, r13d
    ja .Lac3_block_skip
    lea rcx, [rip + ac3_stages]
    movzx edi, byte ptr [rcx + rsi]
    cmp edi, 2
    jbe .Lac3_block_allocate_mask
    mov ecx, esi
    call ac3_calc_psd
.Lac3_block_allocate_mask:
    cmp edi, 1
    jbe .Lac3_block_allocate_bap
    mov ecx, esi
    call ac3_calc_mask
    test eax, eax
    jz .Lac3_block_fail
.Lac3_block_allocate_bap:
    test edi, edi
    jz .Lac3_block_allocate_step
    mov ecx, esi
    call ac3_calc_bap
.Lac3_block_allocate_step:
    inc esi
    jmp .Lac3_block_allocate_channel
.Lac3_block_skip:
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_skip_read
    cmp dword ptr [rip + eac3_skip_syntax], 0
    je .Lac3_block_coefficients
.Lac3_block_skip_read:
    mov ecx, 1
    call ac3_get                          # skiple
    test eax, eax
    jz .Lac3_block_coefficients
    mov ecx, 9
    call ac3_get
    shl eax, 3
    add [rip + ac3_bitpos], eax
.Lac3_block_coefficients:
    mov [rip + eac3_current_block], ebx
    call ac3_coefficients
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_block_coefficients_valid
    mov eax, [rip + ac3_bitlimit]
    lea eax, [rax*8 - 16]
    cmp [rip + ac3_bitpos], eax
    ja .Lac3_block_fail
.Lac3_block_coefficients_valid:
    cmp dword ptr [rip + ac3_acmod], 2
    jne .Lac3_block_transform
    call ac3_rematrix
.Lac3_block_transform:
    mov eax, 1
    jmp .Lac3_block_return
.Lac3_block_unsupported:
    mov eax, AC3_UNSUPPORTED
    jmp .Lac3_block_return
.Lac3_block_fail:
    xor eax, eax
.Lac3_block_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_block

# Exponents of channel ECX (absolute exponent, groups, then gain range for
# full-bandwidth channels) -> EAX=1, or 0 for a group code above 124 or an
# exponent outside 0..24. All groups are read before any is applied.
LOCALFN ac3_exponents
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov ebx, ecx
    mov ecx, 4
    call ac3_get
    test ebx, ebx
    jnz .Lac3_exp_absolute
    add eax, eax                          # coupling: in steps of two
.Lac3_exp_absolute:
    mov r12d, eax
    mov edx, ebx
    shl edx, 8
    lea rdi, [rip + ac3_dexps]
    add rdi, rdx                          # this channel's exponents
    mov [rdi], al
    AC3_SLOT rcx, ac3_ngrps, rbx
    mov r13d, [rcx]
    xor esi, esi
.Lac3_exp_read:
    cmp esi, r13d
    jae .Lac3_exp_apply
    mov ecx, 7
    call ac3_get
    cmp eax, 125
    jae .Lac3_exp_fail
    lea rcx, [rip + ac3_groups]
    mov [rcx + rsi], al
    inc esi
    jmp .Lac3_exp_read
.Lac3_exp_apply:
    AC3_SLOT rcx, ac3_start, rbx
    mov r8d, [rcx]
    test ebx, ebx
    setnz al
    movzx eax, al
    add r8d, eax                          # first exponent written
    AC3_SLOT rcx, ac3_expstr, rbx
    mov r9d, [rcx]
    cmp r9d, 3
    jne .Lac3_exp_group_size
    inc r9d                               # D45: four exponents per value
.Lac3_exp_group_size:
    xor esi, esi
.Lac3_exp_group:
    cmp esi, r13d
    jae .Lac3_exp_gain
    lea rcx, [rip + ac3_groups]
    movzx eax, byte ptr [rcx + rsi]
    imul r10d, eax, 41
    shr r10d, 10                          # first delta + 2 (code / 25)
    imul r11d, r10d, 25
    sub eax, r11d                         # code % 25
    imul r11d, eax, 52
    shr r11d, 8                           # second (code % 25 / 5)
    lea ecx, [r11 + r11*4]
    sub eax, ecx                          # third
    mov ecx, r10d
    call .Lac3_exp_value
    jc .Lac3_exp_fail
    mov ecx, r11d
    call .Lac3_exp_value
    jc .Lac3_exp_fail
    mov ecx, eax
    call .Lac3_exp_value
    jc .Lac3_exp_fail
    inc esi
    jmp .Lac3_exp_group
.Lac3_exp_gain:
    test ebx, ebx
    jz .Lac3_exp_done
    cmp ebx, [rip + ac3_lfe_ch]
    je .Lac3_exp_done
    add dword ptr [rip + ac3_bitpos], 2   # gainrng
.Lac3_exp_done:
    mov eax, 1
    jmp .Lac3_exp_return
.Lac3_exp_fail:
    xor eax, eax
.Lac3_exp_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# ECX=delta + 2: R12D += delta, written R9D times at RDI + R8 -> CF on range error.
.Lac3_exp_value:
    lea r12d, [r12 + rcx - 2]
    cmp r12d, 24
    ja .Lac3_exp_value_bad
    mov ecx, r9d
.Lac3_exp_value_store:
    mov [rdi + r8], r12b
    inc r8d
    dec ecx
    jnz .Lac3_exp_value_store
    clc
    ret
.Lac3_exp_value_bad:
    stc
    ret
ENDFN ac3_exponents

# Power spectral densities of channel ECX and their per-band log sums.
LOCALFN ac3_calc_psd
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov ebx, ecx
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]                        # start
    AC3_SLOT rax, ac3_end, rbx
    mov edi, [rax]                        # end
    mov eax, ebx
    shl eax, 8
    lea r8, [rip + ac3_dexps]
    add r8, rax
    lea r9, [rip + ac3_psd]
    lea r9, [r9 + rax*2]
    mov eax, ebx
    shl eax, 7
    lea r10, [rip + ac3_band_psd]
    add r10, rax
    mov ecx, esi
.Lac3_psd_bin:
    cmp ecx, edi
    jae .Lac3_psd_bands
    movzx eax, byte ptr [r8 + rcx]
    shl eax, 7
    neg eax
    add eax, 3072
    mov [r9 + rcx*2], ax
    inc ecx
    jmp .Lac3_psd_bin
.Lac3_psd_bands:
    lea r11, [rip + ac3_bin_band]
    movzx r12d, byte ptr [r11 + rsi]      # band
    lea r11, [rip + ac3_band_start]
    lea r13, [rip + ac3_latab]
    mov ecx, esi                          # bin
.Lac3_psd_band:
    movsx eax, word ptr [r9 + rcx*2]      # v
    inc ecx
    movzx edx, byte ptr [r11 + r12 + 1]
    cmp edx, edi
    cmova edx, edi                        # band end
.Lac3_psd_add:
    cmp ecx, edx
    jae .Lac3_psd_store
    movsx ebx, word ptr [r9 + rcx*2]
    lea esi, [rax + rbx + 1]
    sar esi, 1
    cmp ebx, eax
    cmovl ebx, eax                        # max
    neg esi
    add esi, ebx                          # max - average
    cmp esi, 255
    jbe .Lac3_psd_address
    mov esi, 255
.Lac3_psd_address:
    movzx eax, byte ptr [r13 + rsi]
    add eax, ebx
    inc ecx
    jmp .Lac3_psd_add
.Lac3_psd_store:
    mov [r10 + r12*2], ax
    inc r12d
    movzx edx, byte ptr [r11 + r12]
    cmp edi, edx
    ja .Lac3_psd_band
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_calc_psd

# A/52 low-frequency compensation step: EAX=lowcomp, R8D=band_psd[b],
# R9D=band_psd[b + 1], R10D=reset value -> EAX.
LOCALFN ac3_lowcomp
    lea r11d, [r8 + 256]
    cmp r11d, r9d
    jne .Lac3_lowcomp_fall
    mov eax, r10d
    ret
.Lac3_lowcomp_fall:
    cmp r8d, r9d
    jle .Lac3_lowcomp_done
    sub eax, 64
    jns .Lac3_lowcomp_done
    xor eax, eax
.Lac3_lowcomp_done:
    ret
ENDFN ac3_lowcomp

# Excitation and masking curve of channel ECX, with delta bit allocation ->
# EAX=1, or 0 for an empty range or a delta segment outside the 50 bands.
# Registers: R12 band_psd, R13 excitation, R14D fast leak, R15D slow leak.
LOCALFN ac3_calc_mask
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov ebx, ecx
    AC3_SLOT rax, ac3_end, rbx
    mov edi, [rax]                        # end
    test edi, edi
    jle .Lac3_mask_fail
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]
    lea rax, [rip + ac3_bin_band]
    movzx ecx, byte ptr [rax + rsi]
    mov [rsp + 32], ecx                   # band start
    movzx ecx, byte ptr [rax + rdi - 1]
    inc ecx
    mov [rsp + 36], ecx                   # band end
    AC3_SLOT rax, ac3_fgain, rbx
    mov eax, [rax]
    mov [rsp + 40], eax                   # fast gain
    xor eax, eax
    cmp ebx, [rip + ac3_lfe_ch]
    sete al
    mov [rsp + 44], eax                   # LFE
    mov eax, ebx
    shl eax, 7
    lea r12, [rip + ac3_band_psd]
    add r12, rax
    lea r13, [rip + ac3_excite]
    cmp dword ptr [rsp + 32], 0
    jne .Lac3_mask_coupling
    # Bands 0 and 1, then 2..6 until the spectrum stops falling.
    movsx r8d, word ptr [r12]
    movsx r9d, word ptr [r12 + 2]
    xor eax, eax
    mov r10d, 384
    call ac3_lowcomp
    mov edx, r8d
    sub edx, [rsp + 40]
    sub edx, eax
    mov [r13], edx
    movsx r8d, word ptr [r12 + 2]
    movsx r9d, word ptr [r12 + 4]
    call ac3_lowcomp
    mov edx, r8d
    sub edx, [rsp + 40]
    sub edx, eax
    mov [r13 + 4], edx
    mov esi, eax                          # lowcomp
    mov edi, 7                            # begin
    mov ecx, 2
.Lac3_mask_low:
    cmp ecx, 7
    jae .Lac3_mask_middle
    movsx r8d, word ptr [r12 + rcx*2]
    movsx r9d, word ptr [r12 + rcx*2 + 2]
    cmp dword ptr [rsp + 44], 0
    je .Lac3_mask_low_lowcomp
    cmp ecx, 6
    je .Lac3_mask_low_leak
.Lac3_mask_low_lowcomp:
    mov eax, esi
    mov r10d, 384
    call ac3_lowcomp
    mov esi, eax
.Lac3_mask_low_leak:
    mov r14d, r8d
    sub r14d, [rsp + 40]                  # fast leak
    mov r15d, r8d
    sub r15d, [rip + ac3_sgain]           # slow leak
    mov eax, r14d
    sub eax, esi
    mov [r13 + rcx*4], eax
    cmp dword ptr [rsp + 44], 0
    je .Lac3_mask_low_turn
    cmp ecx, 6
    je .Lac3_mask_low_next
.Lac3_mask_low_turn:
    cmp r8d, r9d
    jg .Lac3_mask_low_next
    lea edi, [rcx + 1]
    jmp .Lac3_mask_middle
.Lac3_mask_low_next:
    inc ecx
    jmp .Lac3_mask_low
.Lac3_mask_middle:
    mov edx, [rsp + 36]
    cmp edx, 22
    jbe .Lac3_mask_middle_end
    mov edx, 22
.Lac3_mask_middle_end:
    mov [rsp + 32], edx                   # (band start is 0 here) loop end
    mov ecx, edi
.Lac3_mask_middle_band:
    cmp ecx, [rsp + 32]
    jae .Lac3_mask_middle_done
    movsx r8d, word ptr [r12 + rcx*2]
    cmp dword ptr [rsp + 44], 0
    je .Lac3_mask_middle_lowcomp
    cmp ecx, 6
    je .Lac3_mask_middle_leak
.Lac3_mask_middle_lowcomp:
    movsx r9d, word ptr [r12 + rcx*2 + 2]
    mov eax, esi
    cmp ecx, 7
    jb .Lac3_mask_middle_384
    cmp ecx, 20
    jb .Lac3_mask_middle_320
    sub eax, 128
    jns .Lac3_mask_middle_lowcomp_done
    xor eax, eax
    jmp .Lac3_mask_middle_lowcomp_done
.Lac3_mask_middle_384:
    mov r10d, 384
    call ac3_lowcomp
    jmp .Lac3_mask_middle_lowcomp_done
.Lac3_mask_middle_320:
    mov r10d, 320
    call ac3_lowcomp
.Lac3_mask_middle_lowcomp_done:
    mov esi, eax
.Lac3_mask_middle_leak:
    sub r14d, [rip + ac3_fdecay]
    mov eax, r8d
    sub eax, [rsp + 40]
    cmp r14d, eax
    cmovl r14d, eax
    sub r15d, [rip + ac3_sdecay]
    mov eax, r8d
    sub eax, [rip + ac3_sgain]
    cmp r15d, eax
    cmovl r15d, eax
    mov eax, r14d
    sub eax, esi
    cmp eax, r15d
    cmovl eax, r15d
    mov [r13 + rcx*4], eax
    inc ecx
    jmp .Lac3_mask_middle_band
.Lac3_mask_middle_done:
    mov dword ptr [rsp + 32], 0           # band start again
    mov edi, 22
    jmp .Lac3_mask_upper
.Lac3_mask_coupling:
    mov edi, [rsp + 32]                   # begin
    mov r14d, [rip + ac3_cplfleak]
    shl r14d, 8
    add r14d, 768
    mov r15d, [rip + ac3_cplsleak]
    shl r15d, 8
    add r15d, 768
.Lac3_mask_upper:
    mov ecx, edi
.Lac3_mask_upper_band:
    cmp ecx, [rsp + 36]
    jae .Lac3_mask_curve
    movsx r8d, word ptr [r12 + rcx*2]
    sub r14d, [rip + ac3_fdecay]
    mov eax, r8d
    sub eax, [rsp + 40]
    cmp r14d, eax
    cmovl r14d, eax
    sub r15d, [rip + ac3_sdecay]
    mov eax, r8d
    sub eax, [rip + ac3_sgain]
    cmp r15d, eax
    cmovl r15d, eax
    mov eax, r14d
    cmp eax, r15d
    cmovl eax, r15d
    mov [r13 + rcx*4], eax
    inc ecx
    jmp .Lac3_mask_upper_band
.Lac3_mask_curve:
    # Masking curve: excitation raised for low levels, at least the threshold.
    mov eax, ebx
    shl eax, 7
    lea rsi, [rip + ac3_mask]
    add rsi, rax
    imul edx, dword ptr [rip + ac3_fscod], 100
    lea rdi, [rip + ac3_hth]
    add rdi, rdx                          # this rate's thresholds (shorts)
    mov ecx, [rsp + 32]
.Lac3_mask_curve_band:
    cmp ecx, [rsp + 36]
    jae .Lac3_mask_delta
    movsx r8d, word ptr [r12 + rcx*2]
    mov eax, [r13 + rcx*4]
    mov edx, [rip + ac3_dbknee]
    sub edx, r8d
    jle .Lac3_mask_curve_threshold
    sar edx, 2
    add eax, edx
.Lac3_mask_curve_threshold:
    mov r9d, ecx
    push rcx
    mov ecx, [rip + ac3_shift]
    shr r9d, cl
    pop rcx
    movzx edx, word ptr [rdi + r9*2]
    cmp eax, edx
    cmovl eax, edx
    mov [rsi + rcx*2], ax
    inc ecx
    jmp .Lac3_mask_curve_band
.Lac3_mask_delta:
    AC3_SLOT rax, ac3_dbamode, rbx
    cmp dword ptr [rax], 1
    ja .Lac3_mask_done                    # none or reserved
    AC3_SLOT rax, ac3_dbansegs, rbx
    mov edi, [rax]
    cmp edi, 8
    ja .Lac3_mask_fail
    lea r8d, [rbx*8]                      # segment slot
    add edi, r8d
    mov ecx, [rsp + 32]                   # band
.Lac3_mask_segment:
    cmp r8d, edi
    jae .Lac3_mask_done
    lea rax, [rip + ac3_dbaoffst]
    movzx edx, byte ptr [rax + r8]
    add ecx, edx
    cmp ecx, 50
    jae .Lac3_mask_fail
    lea rax, [rip + ac3_dbalen]
    movzx r9d, byte ptr [rax + r8]
    mov edx, 50
    sub edx, ecx
    cmp r9d, edx
    ja .Lac3_mask_fail
    lea rax, [rip + ac3_dbaval]
    movzx edx, byte ptr [rax + r8]
    lea eax, [rdx - 3]
    cmp edx, 4
    jae .Lac3_mask_segment_delta
    lea eax, [rdx - 4]
.Lac3_mask_segment_delta:
    shl eax, 7
.Lac3_mask_segment_band:
    test r9d, r9d
    jz .Lac3_mask_segment_next
    add [rsi + rcx*2], ax
    inc ecx
    dec r9d
    jmp .Lac3_mask_segment_band
.Lac3_mask_segment_next:
    inc r8d
    jmp .Lac3_mask_segment
.Lac3_mask_done:
    mov eax, 1
    jmp .Lac3_mask_return
.Lac3_mask_fail:
    xor eax, eax
.Lac3_mask_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_calc_mask

# Bit allocation pointers of channel ECX from its masking curve and SNR offset.
LOCALFN ac3_calc_bap
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov ebx, ecx
    mov eax, ebx
    shl eax, 8
    lea rdi, [rip + ac3_bap]
    add rdi, rax
    AC3_SLOT rax, ac3_snr, rbx
    mov r12d, [rax]                       # SNR offset
    cmp r12d, -960
    jne .Lac3_bap_compute
    xor eax, eax
    mov ecx, 64
.Lac3_bap_clear:
    mov [rdi + rcx*4 - 4], eax
    dec ecx
    jnz .Lac3_bap_clear
    jmp .Lac3_bap_return
.Lac3_bap_compute:
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]                        # bin
    AC3_SLOT rax, ac3_end, rbx
    mov r13d, [rax]                       # end
    mov eax, ebx
    shl eax, 9
    lea r8, [rip + ac3_psd]
    add r8, rax
    mov eax, ebx
    shl eax, 7
    lea r9, [rip + ac3_mask]
    add r9, rax
    lea r10, [rip + ac3_bin_band]
    movzx r11d, byte ptr [r10 + rsi]      # band
    lea r10, [rip + ac3_band_start]
    lea r14, [rip + ac3_baptab]
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_bap_band
    AC3_SLOT rcx, eac3_aht_ch, rbx
    cmp dword ptr [rcx], 0
    je .Lac3_bap_band
    lea r14, [rip + eac3_hebap]
.Lac3_bap_band:
    movsx eax, word ptr [r9 + r11*2]
    sub eax, r12d
    sub eax, [rip + ac3_floorv]
    jns .Lac3_bap_masked
    xor eax, eax
.Lac3_bap_masked:
    and eax, 0x1fe0
    add eax, [rip + ac3_floorv]           # m
    inc r11d
    movzx edx, byte ptr [r10 + r11]
    cmp edx, r13d
    cmova edx, r13d                       # band end
.Lac3_bap_bin:
    cmp esi, edx
    jae .Lac3_bap_next_band
    movsx ecx, word ptr [r8 + rsi*2]
    sub ecx, eax
    sar ecx, 5
    jns .Lac3_bap_positive
    xor ecx, ecx
.Lac3_bap_positive:
    cmp ecx, 63
    jbe .Lac3_bap_lookup
    mov ecx, 63
.Lac3_bap_lookup:
    movzx ecx, byte ptr [r14 + rcx]
    mov [rdi + rsi], cl
    inc esi
    jmp .Lac3_bap_bin
.Lac3_bap_next_band:
    cmp r13d, edx
    ja .Lac3_bap_band
.Lac3_bap_return:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_calc_bap

# Mantissas of every channel; the coupling channel follows the first coupled
# channel and is uncoupled at once. Dither for coupled channels with dither
# off is removed afterwards, as in FFmpeg.
LOCALFN ac3_coefficients
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    xorps xmm0, xmm0
    movups [rip + ac3_mant], xmm0
    movups [rip + ac3_mant + 16], xmm0
    xor r12d, r12d                        # coupling channel decoded
    mov esi, 1
.Lac3_coef_channel:
    cmp esi, [rip + ac3_channels]
    ja .Lac3_coef_dither
    mov ecx, esi
    call ac3_mantissas
    AC3_SLOT rax, ac3_incpl, rsi
    cmp dword ptr [rax], 0
    je .Lac3_coef_own_end
    test r12d, r12d
    jnz .Lac3_coef_coupled_end
    xor ecx, ecx
    call ac3_mantissas
    call ac3_uncouple
    mov r12d, 1
.Lac3_coef_coupled_end:
    mov eax, [rip + ac3_end]
    jmp .Lac3_coef_zero
.Lac3_coef_own_end:
    AC3_SLOT rax, ac3_end, rsi
    mov eax, [rax]
.Lac3_coef_zero:
    mov edx, esi
    shl edx, 10
    lea rdi, [rip + ac3_fixed]
    add rdi, rdx
.Lac3_coef_zero_bin:
    cmp eax, 256
    jae .Lac3_coef_next
    mov dword ptr [rdi + rax*4], 0
    inc eax
    jmp .Lac3_coef_zero_bin
.Lac3_coef_next:
    inc esi
    jmp .Lac3_coef_channel
.Lac3_coef_dither:
    mov esi, 1
.Lac3_coef_dither_channel:
    cmp esi, [rip + ac3_nf]
    ja .Lac3_coef_return
    AC3_SLOT rax, ac3_dith, rsi
    cmp dword ptr [rax], 0
    jne .Lac3_coef_dither_next
    AC3_SLOT rax, ac3_incpl, rsi
    cmp dword ptr [rax], 0
    je .Lac3_coef_dither_next
    mov edx, esi
    shl edx, 10
    lea rdi, [rip + ac3_fixed]
    add rdi, rdx
    lea r8, [rip + ac3_bap]               # coupling channel's pointers
    mov eax, [rip + ac3_start]
.Lac3_coef_dither_bin:
    cmp eax, [rip + ac3_end]
    jae .Lac3_coef_dither_next
    cmp byte ptr [r8 + rax], 0
    jne .Lac3_coef_dither_step
    mov dword ptr [rdi + rax*4], 0
.Lac3_coef_dither_step:
    inc eax
    jmp .Lac3_coef_dither_bin
.Lac3_coef_dither_next:
    inc esi
    jmp .Lac3_coef_dither_channel
.Lac3_coef_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_coefficients

# Mantissas of channel ECX into its fixed-point coefficients: grouped
# quantizers for bap 1, 2 and 4 (groups shared across the block's channels),
# dither for bap 0 where enabled, two's complement for bap 6..15.
LOCALFN ac3_mantissas
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_mant_ordinary
    AC3_SLOT rax, eac3_aht_ch, rcx
    cmp dword ptr [rax], 0
    jne eac3_aht_mantissas
.Lac3_mant_ordinary:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov ebx, ecx
    mov eax, ebx
    shl eax, 8
    lea r12, [rip + ac3_bap]
    add r12, rax
    lea r13, [rip + ac3_dexps]
    add r13, rax
    lea r14, [rip + ac3_fixed]
    lea r14, [r14 + rax*4]
    AC3_SLOT rax, ac3_start, rbx
    mov esi, [rax]
    AC3_SLOT rax, ac3_end, rbx
    mov edi, [rax]
    mov r15d, 1                           # dither: always for the coupling channel
    test ebx, ebx
    jz .Lac3_mant_bin
    AC3_SLOT rax, ac3_dith, rbx
    mov r15d, [rax]
.Lac3_mant_bin:
    cmp esi, edi
    jae .Lac3_mant_return
    movzx eax, byte ptr [r12 + rsi]
    cmp eax, 5
    ja .Lac3_mant_linear
    cmp eax, 3
    je .Lac3_mant_b3
    ja .Lac3_mant_high
    cmp eax, 1
    je .Lac3_mant_b1
    ja .Lac3_mant_b2
.Lac3_mant_zero:
    xor eax, eax
    test r15d, r15d
    jz .Lac3_mant_store
    # FFmpeg's lagged Fibonacci dither, about -0.707 .. 0.707.
    mov ecx, [rip + ac3_lfg_index]
    lea r8d, [rcx - 24]
    and r8d, 63
    lea r9d, [rcx - 55]
    and r9d, 63
    lea r10, [rip + ac3_lfg]
    mov eax, [r10 + r8*4]
    add eax, [r10 + r9*4]
    mov r8d, ecx
    and r8d, 63
    mov [r10 + r8*4], eax
    inc ecx
    mov [rip + ac3_lfg_index], ecx
    shr eax, 8
    imul eax, eax, 181
    shr eax, 8
    sub eax, 5931008
    jmp .Lac3_mant_store
.Lac3_mant_b1:
    mov ecx, [rip + ac3_mant]
    test ecx, ecx
    jz .Lac3_mant_b1_read
    dec ecx
    mov [rip + ac3_mant], ecx
    lea rax, [rip + ac3_mant + 4]
    mov eax, [rax + rcx*4]
    jmp .Lac3_mant_store
.Lac3_mant_b1_read:
    mov ecx, 5
    call ac3_get
    lea rax, [rax + rax*2]
    lea rcx, [rip + ac3_b1]
    mov edx, [rcx + rax*4 + 4]
    mov [rip + ac3_mant + 8], edx
    mov edx, [rcx + rax*4 + 8]
    mov [rip + ac3_mant + 4], edx
    mov dword ptr [rip + ac3_mant], 2
    mov eax, [rcx + rax*4]
    jmp .Lac3_mant_store
.Lac3_mant_b2:
    mov ecx, [rip + ac3_mant + 12]
    test ecx, ecx
    jz .Lac3_mant_b2_read
    dec ecx
    mov [rip + ac3_mant + 12], ecx
    lea rax, [rip + ac3_mant + 16]
    mov eax, [rax + rcx*4]
    jmp .Lac3_mant_store
.Lac3_mant_b2_read:
    mov ecx, 7
    call ac3_get
    lea rax, [rax + rax*2]
    lea rcx, [rip + ac3_b2]
    mov edx, [rcx + rax*4 + 4]
    mov [rip + ac3_mant + 20], edx
    mov edx, [rcx + rax*4 + 8]
    mov [rip + ac3_mant + 16], edx
    mov dword ptr [rip + ac3_mant + 12], 2
    mov eax, [rcx + rax*4]
    jmp .Lac3_mant_store
.Lac3_mant_b3:
    mov ecx, 3
    call ac3_get
    lea rcx, [rip + ac3_b3]
    mov eax, [rcx + rax*4]
    jmp .Lac3_mant_store
.Lac3_mant_high:
    cmp eax, 5
    je .Lac3_mant_b5
.Lac3_mant_b4:
    cmp dword ptr [rip + ac3_mant + 24], 0
    je .Lac3_mant_b4_read
    mov dword ptr [rip + ac3_mant + 24], 0
    mov eax, [rip + ac3_mant + 28]
    jmp .Lac3_mant_store
.Lac3_mant_b4_read:
    mov ecx, 7
    call ac3_get
    lea rcx, [rip + ac3_b4]
    mov edx, [rcx + rax*8 + 4]
    mov [rip + ac3_mant + 28], edx
    mov dword ptr [rip + ac3_mant + 24], 1
    mov eax, [rcx + rax*8]
    jmp .Lac3_mant_store
.Lac3_mant_b5:
    mov ecx, 4
    call ac3_get
    lea rcx, [rip + ac3_b5]
    mov eax, [rcx + rax*4]
    jmp .Lac3_mant_store
.Lac3_mant_linear:
    lea rcx, [rip + ac3_quant_bits]
    movzx r8d, byte ptr [rcx + rax]
    mov ecx, r8d
    call ac3_get_signed
    mov ecx, 24
    sub ecx, r8d
    shl eax, cl
.Lac3_mant_store:
    movzx ecx, byte ptr [r13 + rsi]
    sar eax, cl
    mov [r14 + rsi*4], eax
    inc esi
    jmp .Lac3_mant_bin
.Lac3_mant_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_mantissas

# Coupled channels from the coupling channel: coordinates scale each band
# in 24-bit fixed point; phase flags negate the right channel (2/0 only).
LOCALFN ac3_uncouple
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov ebx, [rip + ac3_start]            # bin
    xor r12d, r12d                        # band
.Lac3_uncouple_band:
    cmp r12d, [rip + ac3_ncplbnd]
    jae .Lac3_uncouple_return
    lea rax, [rip + ac3_bndsz]
    movzx r13d, byte ptr [rax + r12]
    add r13d, ebx                         # band end
    mov esi, 1
.Lac3_uncouple_channel:
    cmp esi, [rip + ac3_nf]
    ja .Lac3_uncouple_next
    AC3_SLOT rax, ac3_incpl, rsi
    cmp dword ptr [rax], 0
    je .Lac3_uncouple_channel_next
    mov eax, esi
    shl eax, 5
    add eax, r12d
    lea rcx, [rip + ac3_coords]
    mov eax, [rcx + rax*4]
    shl eax, 5
    movsxd r8, eax                        # coordinate
    mov eax, esi
    shl eax, 10
    lea rdi, [rip + ac3_fixed]
    add rdi, rax
    lea r9, [rip + ac3_fixed]             # coupling channel
    mov ecx, ebx
.Lac3_uncouple_bin:
    cmp ecx, r13d
    jae .Lac3_uncouple_phase
    mov eax, [r9 + rcx*4]
    shl eax, 4
    movsxd rax, eax
    imul rax, r8
    sar rax, 32
    mov [rdi + rcx*4], eax
    inc ecx
    jmp .Lac3_uncouple_bin
.Lac3_uncouple_phase:
    cmp esi, 2
    jne .Lac3_uncouple_channel_next
    lea rax, [rip + ac3_phase]
    cmp byte ptr [rax + r12], 0
    je .Lac3_uncouple_channel_next
    mov ecx, ebx
.Lac3_uncouple_negate:
    cmp ecx, r13d
    jae .Lac3_uncouple_channel_next
    neg dword ptr [rdi + rcx*4]
    inc ecx
    jmp .Lac3_uncouple_negate
.Lac3_uncouple_channel_next:
    inc esi
    jmp .Lac3_uncouple_channel
.Lac3_uncouple_next:
    mov ebx, r13d
    inc r12d
    jmp .Lac3_uncouple_band
.Lac3_uncouple_return:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_uncouple

# Rematrixing (2/0): left = sum, right = difference, per flagged band below
# both channels' ends.
LOCALFN ac3_rematrix
    push rbx
    push rsi
    push rdi
    mov r8d, [rip + ac3_end + 4]
    mov eax, [rip + ac3_end + 8]
    cmp r8d, eax
    cmova r8d, eax                        # end
    lea rsi, [rip + ac3_fixed + 1024]
    lea rdi, [rip + ac3_fixed + 2048]
    xor ebx, ebx
.Lac3_remat_band:
    cmp ebx, [rip + ac3_nremat]
    jae .Lac3_remat_return
    lea rax, [rip + ac3_remat]
    cmp dword ptr [rax + rbx*4], 0
    je .Lac3_remat_next
    lea rax, [rip + ac3_remat_tab]
    movzx ecx, word ptr [rax + rbx*2]
    movzx edx, word ptr [rax + rbx*2 + 2]
    cmp edx, r8d
    cmova edx, r8d
.Lac3_remat_bin:
    cmp ecx, edx
    jae .Lac3_remat_next
    mov eax, [rsi + rcx*4]
    mov r9d, [rdi + rcx*4]
    lea r10d, [rax + r9]
    sub eax, r9d
    mov [rsi + rcx*4], r10d
    mov [rdi + rcx*4], eax
    inc ecx
    jmp .Lac3_remat_bin
.Lac3_remat_next:
    inc ebx
    jmp .Lac3_remat_band
.Lac3_remat_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_rematrix

# Scaling, IMDCT, windowing and overlap of every channel into block ECX of
# ac3_pcm. Coefficients become floats times the dynamic range gain, as in
# FFmpeg; the transform runs in double precision.
LOCALFN ac3_transform
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, ecx                         # block
    mov ebx, 1                            # channel
.Lac3_transform_channel:
    cmp ebx, [rip + ac3_channels]
    ja .Lac3_transform_return
    xor eax, eax                          # dynamic range word
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Lac3_transform_gain
    cmp ebx, 2
    ja .Lac3_transform_gain
    mov eax, 2
    sub eax, ebx
.Lac3_transform_gain:
    lea rcx, [rip + ac3_dyn]
    movss xmm1, [rcx + rax*4]
    mulss xmm1, [rip + ac3_gain_scale]
    mov eax, ebx
    shl eax, 10
    lea rsi, [rip + ac3_fixed]
    add rsi, rax
    lea rdi, [rip + ac3_coef]
    xor ecx, ecx
.Lac3_transform_scale:
    cvtsi2ss xmm0, dword ptr [rsi + rcx*4]
    mulss xmm0, xmm1
    movss [rdi + rcx*4], xmm0
    inc ecx
    cmp ecx, 256
    jb .Lac3_transform_scale
    cmp dword ptr [rip + ac3_enhanced], 0
    je .Lac3_transform_spx_done
    AC3_SLOT rax, eac3_spx_ch, rbx
    cmp dword ptr [rax], 0
    je .Lac3_transform_spx_done
    mov ecx, ebx
    call eac3_spx_apply
.Lac3_transform_spx_done:
    lea eax, [rbx - 1]
    shl eax, 10
    lea r13, [rip + ac3_delay]
    add r13, rax                          # delay (128 doubles)
    imul eax, ebx, AC3_FRAME*4
    lea rsi, [rip + ac3_pcm - AC3_FRAME*4]
    add rsi, rax
    mov eax, r12d
    shl eax, 10
    add rsi, rax                          # output (256 floats)
    AC3_SLOT rax, ac3_blksw, rbx
    cmp dword ptr [rax], 0
    jne .Lac3_transform_short
    lea rcx, [rip + ac3_coef]
    mov edx, 4
    mov r8d, 256
    lea r9, [rip + ac3_y]
    call ac3_dct4
    lea rdx, [rip + ac3_y + 128*8]        # current half, as y4[128 + k]
    call .Lac3_transform_overlap
    jmp .Lac3_transform_delay
.Lac3_transform_short:
    lea rcx, [rip + ac3_coef]
    mov edx, 8
    mov r8d, 128
    lea r9, [rip + ac3_y]
    call ac3_dct4
    lea rdx, [rip + ac3_y]                # first transform, as y4[k]
    call .Lac3_transform_overlap
    lea rcx, [rip + ac3_coef + 4]
    mov edx, 8
    mov r8d, 128
    lea r9, [rip + ac3_y]
    call ac3_dct4
.Lac3_transform_delay:
    # New delay: delay[j] = y4[127 - j].
    lea rcx, [rip + ac3_y]
    xor eax, eax
.Lac3_transform_delay_value:
    mov edx, 127
    sub edx, eax
    movsd xmm0, [rcx + rdx*8]
    movsd [r13 + rax*8], xmm0
    inc eax
    cmp eax, 128
    jb .Lac3_transform_delay_value
    inc ebx
    jmp .Lac3_transform_channel
.Lac3_transform_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# RDX=current half c[k] (k < 128), R13=delay d, RSI=output floats:
# out[k] = d[k] w[255-k] - c[k] w[k], out[255-k] = d[k] w[k] + c[k] w[255-k].
.Lac3_transform_overlap:
    lea rcx, [rip + ac3_window]
    xor eax, eax
.Lac3_transform_overlap_value:
    mov r8d, 255
    sub r8d, eax
    cvtss2sd xmm2, [rcx + rax*4]          # w[k]
    cvtss2sd xmm3, [rcx + r8*4]           # w[255 - k]
    movsd xmm0, [r13 + rax*8]             # d
    movsd xmm1, [rdx + rax*8]             # c
    movsd xmm4, xmm0
    mulsd xmm4, xmm3
    movsd xmm5, xmm1
    mulsd xmm5, xmm2
    subsd xmm4, xmm5
    cvtsd2ss xmm4, xmm4
    movss [rsi + rax*4], xmm4
    mulsd xmm0, xmm2
    mulsd xmm1, xmm3
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rsi + r8*4], xmm0
    inc eax
    cmp eax, 128
    jb .Lac3_transform_overlap_value
    ret
ENDFN ac3_transform

# DCT-IV: RCX=floats x (stride EDX bytes), R8D=M (256 or 128), R9=doubles y:
# y[k] = sum x[n] cos(pi/M (n + 1/2)(k + 1/2)), through an M/2-point complex
# FFT with pre- and post-twiddles.
LOCALFN ac3_dct4
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    push r9                               # output
    mov rsi, rcx
    mov edi, edx                          # stride
    mov r12d, r8d
    shr r12d, 1                           # h
    lea r13, [rip + ac3_pre_long]
    lea r14, [rip + ac3_post_long]
    lea rbx, [rip + ac3_rev128]
    cmp r8d, 256
    je .Lac3_dct4_sizes
    lea r13, [rip + ac3_pre_short]
    lea r14, [rip + ac3_post_short]
    lea rbx, [rip + ac3_rev64]
.Lac3_dct4_sizes:
    lea r15, [rip + ac3_fft]
    # z[n] = (x[2n] + i x[M-1-2n]) pre[n], stored bit-reversed.
    lea r10d, [r8 - 1]                    # M - 1
    xor ecx, ecx
.Lac3_dct4_pre:
    lea eax, [rcx*2]
    imul eax, edi
    cvtss2sd xmm0, [rsi + rax]
    lea eax, [rcx*2]
    mov edx, r10d
    sub edx, eax
    imul edx, edi
    cvtss2sd xmm1, [rsi + rdx]
    unpcklpd xmm0, xmm1
    mov eax, ecx
    shl eax, 5
    movapd xmm1, xmm0
    shufpd xmm1, xmm1, 1
    mulpd xmm0, [r13 + rax]
    mulpd xmm1, [r13 + rax + 16]
    addpd xmm0, xmm1
    movzx eax, word ptr [rbx + rcx*2]
    shl eax, 4
    movapd [r15 + rax], xmm0
    inc ecx
    cmp ecx, r12d
    jb .Lac3_dct4_pre
    # Radix-2 decimation in time; the twiddle exp(-2 pi i k / size) is entry
    # k * 128 / size of the 64-entry table.
    lea r10, [rip + ac3_fft_tw]
    mov r8d, 2                            # size
.Lac3_dct4_stage:
    cmp r8d, r12d
    ja .Lac3_dct4_post
    mov r9d, r8d
    shr r9d, 1                            # half
    mov eax, 128
    xor edx, edx
    div r8d
    shl eax, 5
    mov r11d, eax                         # twiddle stride in bytes
    mov edi, r9d
    shl edi, 4                            # half in bytes
    xor ecx, ecx                          # block start
.Lac3_dct4_block:
    cmp ecx, r12d
    jae .Lac3_dct4_stage_next
    mov eax, ecx
    shl eax, 4
    lea rsi, [r15 + rax]                  # a[start + k]
    lea rbx, [rsi + rdi]                  # a[start + k + half]
    xor edx, edx
    mov eax, r9d
.Lac3_dct4_butterfly:
    movapd xmm0, [rbx]
    movapd xmm1, xmm0
    shufpd xmm1, xmm1, 1
    mulpd xmm0, [r10 + rdx]
    mulpd xmm1, [r10 + rdx + 16]
    addpd xmm0, xmm1                      # t
    movapd xmm1, [rsi]
    movapd xmm2, xmm1
    subpd xmm2, xmm0
    addpd xmm1, xmm0
    movapd [rsi], xmm1
    movapd [rbx], xmm2
    add rsi, 16
    add rbx, 16
    add edx, r11d
    dec eax
    jnz .Lac3_dct4_butterfly
    add ecx, r8d
    jmp .Lac3_dct4_block
.Lac3_dct4_stage_next:
    shl r8d, 1
    jmp .Lac3_dct4_stage
.Lac3_dct4_post:
    # c[k] = Z[k] post[k]; y[2k] = Re c[k], y[M-1-2k] = -Im c[k].
    pop r9
    lea r10d, [r12*2 - 1]                 # M - 1
    xor ecx, ecx
.Lac3_dct4_post_value:
    mov eax, ecx
    shl eax, 4
    movapd xmm0, [r15 + rax]
    mov eax, ecx
    shl eax, 5
    movapd xmm1, xmm0
    shufpd xmm1, xmm1, 1
    mulpd xmm0, [r14 + rax]
    mulpd xmm1, [r14 + rax + 16]
    addpd xmm0, xmm1
    lea eax, [rcx*2]
    movsd [r9 + rax*8], xmm0
    mov edx, r10d
    sub edx, eax
    unpckhpd xmm0, xmm0
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movsd [r9 + rdx*8], xmm1
    inc ecx
    cmp ecx, r12d
    jb .Lac3_dct4_post_value
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ac3_dct4
