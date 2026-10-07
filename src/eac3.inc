# E-AC-3 independent/AC-3-converted substream 0, conventional mantissas.
# Handwritten ATSC A/52:2018 Annex E parser; shared AC-3 DSP and allocation.
# AHT, spectral extension and enhanced coupling report AC3_UNSUPPORTED.
# Numeric tables: normative Tables E2.10 and E2.12, see generator/provenance.
RODATA
.include "eac3_tables.inc"
eac3_block_counts: .byte 1, 2, 3, 6
.data
eac3_type: .long 0
eac3_snr_strategy: .long 0
eac3_switch_syntax: .long 0
eac3_dither_syntax: .long 0
eac3_ba_syntax: .long 0
eac3_gain_syntax: .long 0
eac3_dba_syntax: .long 0
eac3_skip_syntax: .long 0
eac3_first_leak: .long 1
.bss
eac3_expstr: .zero 6*8*4
eac3_cplstre: .zero 6*4
eac3_cplinu: .zero 6*4
eac3_first_coords: .zero 8*4
.text
# Same result as ac3_header, with R11D=blocks and key bit 8 marking E-AC-3.
# Only accepted frame types/rates fit the shared six-channel DSP.
LOCALFN eac3_header
    xor eax, eax
    mov r11d, AC3_UNSUPPORTED
    cmp r10d, 16
    ja .Leac3_header_return
    movzx r8d, byte ptr [rcx + 2]
    mov r9d, r8d
    shr r9d, 6                           # strmtyp
    cmp r9d, 3
    je .Leac3_header_bad
    cmp r9d, 1                           # dependent channels not implemented
    je .Leac3_header_return
    test r8d, 0x38                       # additional independent substream
    jnz .Leac3_header_return
    movzx r9d, byte ptr [rcx + 4]
    mov edx, r9d
    shr edx, 6                           # fscod
    cmp edx, 3                           # reduced rates
    je .Leac3_header_return
    mov r11d, r9d
    shr r11d, 4
    and r11d, 3
    lea rax, [rip + eac3_block_counts]
    movzx r11d, byte ptr [rax + r11]
    and r9d, 15                          # acmod/lfeon
    mov eax, r9d
    shr eax, 1
    shl eax, 4
    or edx, eax
    and r9d, 1
    shl r9d, 7
    or edx, r9d
    or edx, 256
    and r8d, 7
    shl r8d, 8
    movzx eax, byte ptr [rcx + 3]
    or eax, r8d
    lea eax, [rax*2 + 2]
    cmp eax, 8
    jb .Leac3_header_bad
.Leac3_header_return:
    mov ecx, r10d
    ret
.Leac3_header_bad:
    mov r11d, AC3_MALFORMED
    xor eax, eax
    jmp .Leac3_header_return
ENDFN eac3_header

# Frame BSI and audio-frame syntax, after the sync header (bit 40).
# Returns 1, 0 (bad/truncated side information), or AC3_UNSUPPORTED.
LOCALFN eac3_bsi
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    movzx eax, byte ptr [rip + ac3_frame + 2]
    shr eax, 6
    mov [rip + eac3_type], eax
    mov r12d, [rip + ac3_nf]
    mov r13d, [rip + ac3_channels]
    mov r14d, [rip + ac3_blocks]
    mov ecx, 5
    call ac3_get
    mov [rip + ac3_bsid], eax
    mov ebx, 1
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Leac3_bsi_program
    mov ebx, 2
.Leac3_bsi_program:
    add dword ptr [rip + ac3_bitpos], 5   # dialnorm
    mov ecx, 1
    call ac3_get
    shl eax, 3                           # compression word
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_program
    mov ecx, 1
    call ac3_get                          # mixmdate
    test eax, eax
    jz .Leac3_bsi_info
    mov eax, [rip + ac3_acmod]
    cmp eax, 2
    jbe .Leac3_bsi_mix_lfe
    add dword ptr [rip + ac3_bitpos], 2   # preferred downmix
    test eax, 1
    jz .Leac3_bsi_mix_surround
    add dword ptr [rip + ac3_bitpos], 6   # center mix levels
.Leac3_bsi_mix_surround:
    test eax, 4
    jz .Leac3_bsi_mix_lfe
    add dword ptr [rip + ac3_bitpos], 6   # surround mix levels
.Leac3_bsi_mix_lfe:
    cmp dword ptr [rip + ac3_lfe], 0
    je .Leac3_bsi_mix_independent
    mov ecx, 1
    call ac3_get
    imul eax, eax, 5
    add [rip + ac3_bitpos], eax
.Leac3_bsi_mix_independent:
    cmp dword ptr [rip + eac3_type], 0
    jne .Leac3_bsi_info
    mov ebx, 2                           # program + external scale
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Leac3_bsi_scale
    inc ebx
.Leac3_bsi_scale:
    mov ecx, 1
    call ac3_get
    imul eax, eax, 6
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_scale
    mov ecx, 2
    call ac3_get                          # mixdef
    test eax, eax
    jz .Leac3_bsi_pan
    cmp eax, 3
    je .Leac3_bsi_mix_extended
    mov ecx, 5
    cmp eax, 1
    je .Leac3_bsi_mix_skip
    mov ecx, 12
    jmp .Leac3_bsi_mix_skip
.Leac3_bsi_mix_extended:
    mov ecx, 5
    call ac3_get
    lea ecx, [rax*8 + 16]
.Leac3_bsi_mix_skip:
    add [rip + ac3_bitpos], ecx
.Leac3_bsi_pan:
    cmp dword ptr [rip + ac3_acmod], 2
    jae .Leac3_bsi_mix_config
    mov ebx, 1
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Leac3_bsi_pan_next
    inc ebx
.Leac3_bsi_pan_next:
    mov ecx, 1
    call ac3_get
    imul eax, eax, 14
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_pan_next
.Leac3_bsi_mix_config:
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_info
    xor ebx, ebx
.Leac3_bsi_mix_block:
    cmp r14d, 1
    je .Leac3_bsi_mix_block_skip
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_mix_block_next
.Leac3_bsi_mix_block_skip:
    add dword ptr [rip + ac3_bitpos], 5
.Leac3_bsi_mix_block_next:
    inc ebx
    cmp ebx, r14d
    jb .Leac3_bsi_mix_block
.Leac3_bsi_info:
    mov ecx, 1
    call ac3_get                          # infomdate
    test eax, eax
    jz .Leac3_bsi_converter
    add dword ptr [rip + ac3_bitpos], 5   # bsmod, copyright, original
    cmp dword ptr [rip + ac3_acmod], 2
    jne .Leac3_bsi_info_surround
    add dword ptr [rip + ac3_bitpos], 4   # surround/headphone modes
.Leac3_bsi_info_surround:
    cmp dword ptr [rip + ac3_acmod], 6
    jb .Leac3_bsi_production
    add dword ptr [rip + ac3_bitpos], 2
.Leac3_bsi_production:
    mov ebx, 1
    cmp dword ptr [rip + ac3_acmod], 0
    jne .Leac3_bsi_production_next
    inc ebx
.Leac3_bsi_production_next:
    mov ecx, 1
    call ac3_get
    shl eax, 3                           # production info
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_production_next
    inc dword ptr [rip + ac3_bitpos]     # source sample rate
.Leac3_bsi_converter:
    cmp dword ptr [rip + eac3_type], 0
    jne .Leac3_bsi_converted
    cmp r14d, 6
    je .Leac3_bsi_additional
    inc dword ptr [rip + ac3_bitpos]     # convsync
    jmp .Leac3_bsi_additional
.Leac3_bsi_converted:
    cmp r14d, 6
    je .Leac3_bsi_frame_size
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_additional
.Leac3_bsi_frame_size:
    add dword ptr [rip + ac3_bitpos], 6   # original frame size
.Leac3_bsi_additional:
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_flags
    mov ecx, 6
    call ac3_get
    lea eax, [rax*8 + 8]
    add [rip + ac3_bitpos], eax
.Leac3_bsi_flags:
    mov eax, 1
    mov dword ptr [rsp + 36], 0          # ahte
    cmp r14d, 6
    jne .Leac3_bsi_exp_syntax
    mov ecx, 1
    call ac3_get
    mov [rsp + 32], eax                  # expstre
    mov ecx, 1
    call ac3_get
    mov [rsp + 36], eax
    mov eax, [rsp + 32]
.Leac3_bsi_exp_syntax:
    mov [rsp + 32], eax
    mov ecx, 2
    call ac3_get
    cmp eax, 3                          # reserved SNR strategy
    je .Leac3_bsi_bad
    mov [rip + eac3_snr_strategy], eax
    mov ecx, 1
    call ac3_get
    mov [rsp + 40], eax                 # transproce
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_switch_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_dither_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_ba_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_gain_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_dba_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rip + eac3_skip_syntax], eax
    mov ecx, 1
    call ac3_get
    mov [rsp + 44], eax                 # spxattene
    mov dword ptr [rip + ac3_sdecay], 19
    mov dword ptr [rip + ac3_fdecay], 83
    mov dword ptr [rip + ac3_sgain], 1240
    mov dword ptr [rip + ac3_dbknee], 2304
    mov dword ptr [rip + ac3_floorv], -2048
    xor ebx, ebx
    xor r15d, r15d                      # number of coupled blocks
    xor edi, edi                        # preceding cplinu
.Leac3_bsi_cpl:
    xor eax, eax
    cmp dword ptr [rip + ac3_acmod], 1
    jbe .Leac3_bsi_cpl_store
    mov eax, 1
    test ebx, ebx
    jz .Leac3_bsi_cpl_strategy
    mov ecx, 1
    call ac3_get
.Leac3_bsi_cpl_strategy:
    AC3_SLOT rcx, eac3_cplstre, rbx
    mov [rcx], eax
    test eax, eax
    jz .Leac3_bsi_cpl_previous
    mov ecx, 1
    call ac3_get
    mov edi, eax
.Leac3_bsi_cpl_previous:
    mov eax, edi
.Leac3_bsi_cpl_store:
    AC3_SLOT rcx, eac3_cplinu, rbx
    mov [rcx], eax
    add r15d, eax
    inc ebx
    cmp ebx, r14d
    jb .Leac3_bsi_cpl
    # Block-0 offset packing cannot initialize a coupling channel that
    # first starts later. Reject rather than inheriting older-frame state
    # that a one-packet seek primer cannot reconstruct.
    cmp dword ptr [rip + eac3_cplinu], 0
    jne .Leac3_bsi_cpl_initialized
    test r15d, r15d
    jnz .Leac3_bsi_unsupported
.Leac3_bsi_cpl_initialized:
    cmp dword ptr [rsp + 32], 0
    je .Leac3_bsi_exp_lut
    xor ebx, ebx
.Leac3_bsi_exp_block:
    AC3_SLOT rcx, eac3_cplinu, rbx
    xor esi, esi
    cmp dword ptr [rcx], 0
    sete sil
.Leac3_bsi_exp_channel:
    mov ecx, 2
    call ac3_get
    mov edx, ebx
    shl edx, 3
    add edx, esi
    AC3_SLOT rcx, eac3_expstr, rdx
    mov [rcx], eax
    inc esi
    cmp esi, r12d
    jbe .Leac3_bsi_exp_channel
    inc ebx
    cmp ebx, r14d
    jb .Leac3_bsi_exp_block
    jmp .Leac3_bsi_exp_lfe
.Leac3_bsi_exp_lut:
    xor esi, esi
    test r15d, r15d
    setz sil
.Leac3_bsi_exp_lut_channel:
    mov ecx, 5
    call ac3_get
    imul eax, eax, 6
    lea rdi, [rip + eac3_frame_expstr]
    add rdi, rax
    xor ebx, ebx
.Leac3_bsi_exp_lut_block:
    movzx eax, byte ptr [rdi + rbx]
    mov edx, ebx
    shl edx, 3
    add edx, esi
    AC3_SLOT rcx, eac3_expstr, rdx
    mov [rcx], eax
    inc ebx
    cmp ebx, 6
    jb .Leac3_bsi_exp_lut_block
    inc esi
    cmp esi, r12d
    jbe .Leac3_bsi_exp_lut_channel
.Leac3_bsi_exp_lfe:
    cmp dword ptr [rip + ac3_lfe], 0
    je .Leac3_bsi_exp_converter
    xor ebx, ebx
.Leac3_bsi_exp_lfe_block:
    mov ecx, 1
    call ac3_get
    mov edx, ebx
    shl edx, 3
    add edx, r13d
    AC3_SLOT rcx, eac3_expstr, rdx
    mov [rcx], eax
    inc ebx
    cmp ebx, r14d
    jb .Leac3_bsi_exp_lfe_block
.Leac3_bsi_exp_converter:
    cmp dword ptr [rip + eac3_type], 0
    jne .Leac3_bsi_aht
    cmp r14d, 6
    je .Leac3_bsi_exp_converter_skip
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_aht
.Leac3_bsi_exp_converter_skip:
    imul eax, r12d, 5
    add [rip + ac3_bitpos], eax
.Leac3_bsi_aht:
    cmp dword ptr [rsp + 36], 0
    je .Leac3_bsi_snr
    xor esi, esi
    cmp r15d, 6
    setne sil
.Leac3_bsi_aht_channel:
    mov ebx, 1
.Leac3_bsi_aht_eligible:
    mov edx, ebx
    shl edx, 3
    add edx, esi
    AC3_SLOT rcx, eac3_expstr, rdx
    cmp dword ptr [rcx], 0
    jne .Leac3_bsi_aht_next
    test esi, esi
    jnz .Leac3_bsi_aht_eligible_next
    AC3_SLOT rcx, eac3_cplstre, rbx
    cmp dword ptr [rcx], 0
    jne .Leac3_bsi_aht_next
.Leac3_bsi_aht_eligible_next:
    inc ebx
    cmp ebx, 6
    jb .Leac3_bsi_aht_eligible
    mov ecx, 1
    call ac3_get
    test eax, eax
    jnz .Leac3_bsi_unsupported
.Leac3_bsi_aht_next:
    inc esi
    cmp esi, r13d
    jbe .Leac3_bsi_aht_channel
.Leac3_bsi_snr:
    cmp dword ptr [rip + eac3_snr_strategy], 0
    jne .Leac3_bsi_transient
    mov ecx, 6
    call ac3_get
    sub eax, 15
    shl eax, 4
    mov ebx, eax
    mov ecx, 4
    call ac3_get
    add eax, ebx
    shl eax, 2
    xor edx, edx
    lea rcx, [rip + ac3_snr]
.Leac3_bsi_snr_channel:
    mov [rcx + rdx*4], eax
    inc edx
    cmp edx, r13d
    jbe .Leac3_bsi_snr_channel
.Leac3_bsi_transient:
    cmp dword ptr [rsp + 40], 0
    je .Leac3_bsi_attenuation
    mov ebx, r12d
.Leac3_bsi_transient_channel:
    mov ecx, 1
    call ac3_get
    imul eax, eax, 18
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_transient_channel
.Leac3_bsi_attenuation:
    cmp dword ptr [rsp + 44], 0
    je .Leac3_bsi_block_start
    mov ebx, r12d
.Leac3_bsi_attenuation_channel:
    mov ecx, 1
    call ac3_get
    imul eax, eax, 5
    add [rip + ac3_bitpos], eax
    dec ebx
    jnz .Leac3_bsi_attenuation_channel
.Leac3_bsi_block_start:
    cmp r14d, 1
    je .Leac3_bsi_init
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_bsi_init
    mov eax, [rip + ac3_bitlimit]
    sub eax, 2
    bsr ecx, eax
    add ecx, 4
    lea eax, [r14 - 1]
    imul eax, ecx
    add [rip + ac3_bitpos], eax
.Leac3_bsi_init:
    mov dword ptr [rip + eac3_first_leak], 1
    lea rcx, [rip + eac3_first_coords]
    xor edx, edx
.Leac3_bsi_init_coords:
    mov dword ptr [rcx + rdx*4], 1
    inc edx
    cmp edx, 8
    jb .Leac3_bsi_init_coords
    mov ecx, [rip + ac3_lfe_ch]
    test ecx, ecx
    js .Leac3_bsi_bounds
    AC3_SLOT rax, ac3_start, rcx
    mov dword ptr [rax], 0
    AC3_SLOT rax, ac3_end, rcx
    mov dword ptr [rax], 7
    AC3_SLOT rax, ac3_ngrps, rcx
    mov dword ptr [rax], 2
    AC3_SLOT rax, ac3_incpl, rcx
    mov dword ptr [rax], 0
.Leac3_bsi_bounds:
    mov eax, [rip + ac3_bitlimit]
    lea eax, [rax*8 - 16]
    cmp [rip + ac3_bitpos], eax
    ja .Leac3_bsi_bad
    mov eax, 1
    jmp .Leac3_bsi_return
.Leac3_bsi_bad:
    xor eax, eax
    jmp .Leac3_bsi_return
.Leac3_bsi_unsupported:
    mov eax, AC3_UNSUPPORTED
.Leac3_bsi_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_bsi

# FFmpeg-compatible block-0 SNR packing and per-block fast-gain syntax.
# Published per-block SNR updates are outside profile v1 (docs/eac3.md).
# ECX=block, EDX=first channel. Returns 1 or AC3_UNSUPPORTED.
LOCALFN eac3_block_snr
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov ebx, ecx
    mov r12d, edx
    mov r13d, [rip + ac3_channels]
    test ebx, ebx
    jnz .Leac3_snr_gain
    cmp dword ptr [rip + eac3_snr_strategy], 0
    je .Leac3_snr_gain
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_snr_unsupported
    mov ecx, 6
    call ac3_get
    sub eax, 15
    shl eax, 4
    mov edi, eax
    mov esi, r12d
.Leac3_snr_channel:
    cmp esi, r12d
    je .Leac3_snr_fine
    cmp dword ptr [rip + eac3_snr_strategy], 2
    jne .Leac3_snr_store
.Leac3_snr_fine:
    mov ecx, 4
    call ac3_get
    add eax, edi
    shl eax, 2
    mov r8d, eax
.Leac3_snr_store:
    AC3_SLOT rcx, ac3_snr, rsi
    mov [rcx], r8d
    inc esi
    cmp esi, r13d
    jbe .Leac3_snr_channel
.Leac3_snr_gain:
    cmp dword ptr [rip + eac3_gain_syntax], 0
    je .Leac3_snr_default
    mov ecx, 1
    call ac3_get
    test eax, eax
    jz .Leac3_snr_default
    mov esi, r12d
.Leac3_snr_gain_channel:
    mov ecx, 3
    call ac3_get
    lea rcx, [rip + ac3_fast_gain]
    movzx eax, word ptr [rcx + rax*2]
    AC3_SLOT rcx, ac3_fgain, rsi
    mov edx, [rcx]
    mov [rcx], eax
    cmp eax, edx
    je .Leac3_snr_gain_next
    mov ecx, esi
    mov edx, 2
    call ac3_stage
.Leac3_snr_gain_next:
    inc esi
    cmp esi, r13d
    jbe .Leac3_snr_gain_channel
    jmp .Leac3_snr_converter
.Leac3_snr_default:
    test ebx, ebx
    jnz .Leac3_snr_converter
    mov esi, r12d
.Leac3_snr_default_channel:
    AC3_SLOT rcx, ac3_fgain, rsi
    mov dword ptr [rcx], 640
    inc esi
    cmp esi, r13d
    jbe .Leac3_snr_default_channel
.Leac3_snr_converter:
    cmp dword ptr [rip + eac3_type], 0
    jne .Leac3_snr_done
    mov ecx, 1
    call ac3_get
    imul eax, eax, 10
    add [rip + ac3_bitpos], eax
.Leac3_snr_done:
    mov eax, 1
    jmp .Leac3_snr_return
.Leac3_snr_unsupported:
    # Reusing older-frame offsets also defeats the one-packet seek primer.
    mov eax, AC3_UNSUPPORTED
.Leac3_snr_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN eac3_block_snr
