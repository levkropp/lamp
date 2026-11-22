# Original complete mono/stereo NB/WB/UWB frames. MIT + retained BSD.
# Speex 1.2.1 sb_celp.c and modes_wb.c reference; see THIRD_PARTY_NOTICES.
.include "lamp.inc"
.include "speex_packet.inc"
.include "speex_nb.inc"
.include "speex_qmf.inc"
.include "speex_decoder.inc"
.include "speex_stereo.inc"
RODATA
.include "speex_high_tables.inc"
.p2align 3
spxd_point01: .double .01
spxd_point1: .double .1
spxd_one: .float 1.
spxd_four: .float 4.
spxd_point99: .float .99
spxd_point9: .float .9
spxd_point7: .float .7
spxd_point4: .float .4
spxd_margin: .float .05
spxd_tiny: .float 1e-15
spxd_frame_bits: .long 4,36,112,192,352
.text
# Initialize full opaque arena; mode0=NB/1=WB/2=UWB. Returns160/320/640,0bad.
FN spx_decoder_init
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov esi, r8d
    test rbx, rbx
    jz .Lspxd_init_bad
    cmp edx, SPXD_SIZE
    jb .Lspxd_init_bad
    cmp esi, 2
    ja .Lspxd_init_bad
    mov rax, rbx
    add rax, SPXD_SIZE
    jc .Lspxd_init_bad
    xor eax, eax
.Lspxd_init_zero:
    mov qword ptr [rbx+rax], 0
    add eax, 8
    cmp eax, SPXD_SIZE
    jb .Lspxd_init_zero
    mov edx, SPXN_SIZE
    call spx_nb_init
    test eax, eax
    jz .Lspxd_init_bad
    mov [rbx+SPXD_MODE], esi
    mov dword ptr [rbx+SPXD_CHANNELS], 1
    mov eax, [rip+spxd_one]
    mov [rbx+SPXD_STEREO], eax
    mov [rbx+SPXD_STEREO+8], eax
    mov [rbx+SPXD_STEREO+12], eax
    mov dword ptr [rbx+SPXD_STEREO+4], 0x3f000000
    mov dword ptr [rbx+SPXD_FLAGS], 3
    mov dword ptr [rbx+SPXD_MAGIC], SPXD_MAGIC_VALUE
    mov dword ptr [rbx+SPXD_WB+SPXH_FIRST], 1
    mov dword ptr [rbx+SPXD_WB+SPXH_MODE], 3
    mov dword ptr [rbx+SPXD_WB+SPXH_SEED], 1000
    mov dword ptr [rbx+SPXD_UWB+SPXH_FIRST], 1
    mov dword ptr [rbx+SPXD_UWB+SPXH_MODE], 1
    mov dword ptr [rbx+SPXD_UWB+SPXH_SEED], 1000
    test esi, esi
    jz .Lspxd_init_size
    or dword ptr [rbx+SPXN_FLAGS], 4
.Lspxd_init_size:
    mov ecx, esi
    mov eax, 160
    shl eax, cl
    jmp .Lspxd_init_return
.Lspxd_init_bad:
    xor eax, eax
.Lspxd_init_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN spx_decoder_init

# RCX=arena, EDX=enhancement/highpass flags0..3 ->1/0.
FN spx_decoder_set_flags
    test rcx, rcx
    jz .Lspxd_flags_bad
    cmp dword ptr [rcx+SPXD_MAGIC], SPXD_MAGIC_VALUE
    jne .Lspxd_flags_bad
    cmp dword ptr [rcx+SPXD_MODE], 2
    ja .Lspxd_flags_bad
    cmp edx, 3
    ja .Lspxd_flags_bad
    mov [rcx+SPXD_FLAGS], edx
    cmp dword ptr [rcx+SPXD_MODE], 0
    je .Lspxd_flags_store
    or edx, 4
.Lspxd_flags_store:
    mov [rcx+SPXN_FLAGS], edx
    mov eax, 1
    ret
.Lspxd_flags_bad:
    xor eax, eax
    ret
ENDFN spx_decoder_set_flags

# RCX=initialized decoder, EDX=channels1/2 ->1/0. Preserve stereo smoothing.
FN spx_decoder_set_channels
    test rcx, rcx
    jz .Lspxd_channels_bad
    cmp dword ptr [rcx+SPXD_MAGIC], SPXD_MAGIC_VALUE
    jne .Lspxd_channels_bad
    cmp edx, 1
    jb .Lspxd_channels_bad
    cmp edx, 2
    ja .Lspxd_channels_bad
    mov [rcx+SPXD_CHANNELS], edx
    mov eax, 1
    ret
.Lspxd_channels_bad:
    xor eax, eax
    ret
ENDFN spx_decoder_set_channels

# RCX=4 begin/end pairs ->1 if pairwise disjoint. Empty spans are ignored.
LOCALFN spxd_ranges
    xor r8d, r8d
.Lspxd_ranges_outer:
    mov eax, r8d
    shl eax, 4
    mov r10, [rcx+rax]
    mov r11, [rcx+rax+8]
    cmp r10, r11
    ja .Lspxd_ranges_bad
    je .Lspxd_ranges_next
    lea r9d, [r8+1]
.Lspxd_ranges_inner:
    cmp r9d, 4
    jae .Lspxd_ranges_next
    mov eax, r9d
    shl eax, 4
    mov rdx, [rcx+rax]
    cmp rdx, [rcx+rax+8]
    ja .Lspxd_ranges_bad
    je .Lspxd_ranges_skip
    cmp r10, [rcx+rax+8]
    jae .Lspxd_ranges_skip
    cmp rdx, r11
    jb .Lspxd_ranges_bad
.Lspxd_ranges_skip:
    inc r9d
    jmp .Lspxd_ranges_inner
.Lspxd_ranges_next:
    inc r8d
    cmp r8d, 4
    jb .Lspxd_ranges_outer
    mov eax, 1
    ret
.Lspxd_ranges_bad:
    xor eax, eax
    ret
ENDFN spxd_ranges

# Private variable-size reference RMS (positive count <=320).
LOCALFN spxd_rms
    pxor xmm0, xmm0
    xor eax, eax
.Lspxd_rms_loop:
    movss xmm1, [rcx+rax*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc eax
    cmp eax, edx
    jb .Lspxd_rms_loop
    cvtsi2ss xmm1, edx
    divss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rip+spxd_point1]
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    ret
ENDFN spxd_rms

# RCX=arena, RDX=Bits orNULL(loss/DTX), R8=output, R9D=sample capacity.
# ->160/320/640 success,0 clean end,-1 failure. Live state, output and reader
# position are atomic across all layers; truncation only sets sticky error.
FN spx_decoder_frame
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
    jz .Lspxd_bad_plain
    test rdi, rdi
    jz .Lspxd_bad_plain
    mov rax, rbx
    add rax, SPXD_SIZE
    jc .Lspxd_bad_plain
    mov [rsp+160], rbx
    mov [rsp+168], rax
    cmp dword ptr [rbx+SPXD_MAGIC], SPXD_MAGIC_VALUE
    jne .Lspxd_bad_plain
    mov ecx, [rbx+SPXD_MODE]
    cmp ecx, 2
    ja .Lspxd_bad_plain
    mov eax, 160
    shl eax, cl
    mov [rsp+112], eax                # final sample count
    mov edx, [rbx+SPXD_CHANNELS]
    cmp edx, 1
    jb .Lspxd_bad_plain
    cmp edx, 2
    ja .Lspxd_bad_plain
    imul eax, edx
    cmp r9d, eax
    jb .Lspxd_bad_plain
    mov [rsp+136], eax               # final float count (frames*channels)
    cmp dword ptr [rbx+SPXD_FLAGS], 3
    ja .Lspxd_bad_plain
    lea edx, [rax*4]
    mov rax, rdi
    add rax, rdx
    jc .Lspxd_bad_plain
    mov [rsp+176], rdi
    mov [rsp+184], rax
    xor eax, eax
    mov [rsp+192], rax
    mov [rsp+200], rax
    mov [rsp+208], rax
    mov [rsp+216], rax
    test rsi, rsi
    jz .Lspxd_regions_ready
    mov rax, rsi
    add rax, SPXB_SIZE
    jc .Lspxd_bad_plain
    mov [rsp+192], rsi
    mov [rsp+200], rax
    cmp rsi, [rsp+168]
    jae .Lspxd_reader_separate
    cmp rbx, rax
    jb .Lspxd_bad_plain
.Lspxd_reader_separate:
    cmp dword ptr [rsi+SPXB_ERROR], 0
    jne .Lspxd_bad_plain
    mov eax, [rsi+SPXB_BITS]
    cmp eax, SPX_MAX_PACKET*8
    ja .Lspxd_bad_plain
    cmp eax, [rsi+SPXB_POS]
    jb .Lspxd_bad_plain
    add eax, 7
    shr eax, 3
    mov rdx, [rsi+SPXB_DATA]
    mov [rsp+208], rdx
    test eax, eax
    jz .Lspxd_empty_source
    test rdx, rdx
    jz .Lspxd_bad_plain
.Lspxd_empty_source:
    add rdx, rax
    jc .Lspxd_bad_plain
    mov [rsp+216], rdx
.Lspxd_regions_ready:
    lea rcx, [rsp+160]
    call spxd_ranges
    test eax, eax
    jz .Lspxd_bad_plain
    # Validate active high-band history before any floating-point use.
    mov ecx, 1
.Lspxd_validate_layer:
    cmp ecx, [rbx+SPXD_MODE]
    ja .Lspxd_copy
    imul eax, ecx, 4096
    lea rdx, [rbx+4096+rax]
    cmp dword ptr [rdx+SPXH_FIRST], 1
    ja .Lspxd_bad_plain
    mov eax, 4
    cmp ecx, 1
    je .Lspxd_validate_mode
    mov eax, 1
.Lspxd_validate_mode:
    cmp [rdx+SPXH_MODE], eax
    ja .Lspxd_bad_plain
    mov r8d, 12
.Lspxd_validate_float:
    mov eax, [rdx+r8]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxd_bad_plain
    add r8d, 4
    cmp r8d, 3568
    jb .Lspxd_validate_float
    xor r8d, r8d
.Lspxd_validate_lsp:
    mov eax, [rdx+SPXH_OLD_LSP+r8*4]
    and eax, 0x7fffffff
    cmp eax, 0x41800000
    ja .Lspxd_bad_plain
    inc r8d
    cmp r8d, 8
    jb .Lspxd_validate_lsp
    inc ecx
    jmp .Lspxd_validate_layer
.Lspxd_copy:
    lea r12, [rbx+SPXD_LIVE]
    lea r13, [rbx+SPXD_BITS]
    lea r14, [rbx+SPXD_OUT]
    mov [rsp+128], r14               # selected audio scratch
    xor eax, eax
.Lspxd_copy_live:
    mov rdx, [rbx+rax]
    mov [r12+rax], rdx
    add eax, 8
    cmp eax, SPXD_LIVE
    jb .Lspxd_copy_live
    pxor xmm0, xmm0
    movdqu [r13], xmm0
    movq [r13+16], xmm0
    mov rdx, rsi
    test rsi, rsi
    jz .Lspxd_nb
    movdqu xmm0, [rsi]
    movdqu [r13], xmm0
    mov rax, [rsi+16]
    mov [r13+16], rax
    mov rdx, r13
.Lspxd_nb:
    mov rcx, r12
    mov r8, r14
    mov r9d, 160
    call spx_nb_frame
    test eax, eax
    js .Lspxd_bad
    mov [rsp+116], eax                # zero means clean packet end
    jz .Lspxd_stereo_stage
    mov dword ptr [rsp+64], 1
.Lspxd_layer:
    mov eax, [rsp+64]
    cmp eax, [r12+SPXD_MODE]
    ja .Lspxd_frame_done
    imul eax, eax, 4096
    lea r15, [r12+4096+rax]
    mov ecx, [rsp+64]
    dec ecx
    mov eax, 160
    shl eax, cl
    mov [rsp+68], eax                 # half-rate frame size
    shr eax, 2
    mov [rsp+72], eax                 # half-rate subframe size
    test rsi, rsi
    jz .Lspxd_lost
    mov dword ptr [r15+SPXH_MODE], 0
    mov rcx, r13
    call spx_bits_remaining
    test eax, eax
    jle .Lspxd_mode_ready
    mov rcx, r13
    mov edx, 1
    call spx_bits_peek
    test eax, eax
    jz .Lspxd_mode_ready
    mov rcx, r13
    mov edx, 1
    call spx_bits_advance
    mov rcx, r13
    mov edx, 3
    call spx_bits_read
    cmp dword ptr [r13+SPXB_ERROR], 0
    jne .Lspxd_bad
    mov edx, 4
    cmp dword ptr [rsp+64], 1
    je .Lspxd_check_mode
    mov edx, 1
.Lspxd_check_mode:
    cmp eax, edx
    ja .Lspxd_bad
    mov [r15+SPXH_MODE], eax
.Lspxd_mode_ready:
    cmp dword ptr [r15+SPXH_MODE], 0
    jne .Lspxd_active
    cmp dword ptr [r12+SPXN_DTX], 0
    jne .Lspxd_lost
    mov dword ptr [r15+SPXH_FIRST], 1
    mov ecx, [rsp+68]
    lea rdx, [r14+rcx*4]
    xor eax, eax
    mov r8d, [rip+spxd_tiny]
.Lspxd_null_fill:
    mov [rdx+rax*4], r8d
    inc eax
    cmp eax, ecx
    jb .Lspxd_null_fill
    jmp .Lspxd_null_synthesis
.Lspxd_lost:
    mov dword ptr [r15+SPXH_FIRST], 1
    cmp dword ptr [r12+SPXN_DTX], 0
    jne .Lspxd_lost_noise
    lea rcx, [r15+SPXH_LPC]
    mov rdx, rcx
    mov r8d, 8
    movss xmm3, [rip+spxd_point99]
    call spx_bw_lpc
    test eax, eax
    jz .Lspxd_bad
    movss xmm0, [r15+SPXH_ENERGY]
    mulss xmm0, [rip+spxd_point9]
    movss [r15+SPXH_ENERGY], xmm0
.Lspxd_lost_noise:
    mov edx, [rsp+68]
    lea rcx, [r14+rdx*4]
    lea r8, [r15+SPXH_SEED]
    movss xmm3, [r15+SPXH_ENERGY]
    call spx_noise_decode
    test eax, eax
    jz .Lspxd_bad
.Lspxd_null_synthesis:
    mov eax, [rsp+68]
    lea rcx, [r14+rax*4]
    lea rdx, [r15+SPXH_LPC]
    mov r8, rcx
    mov r9d, eax
    mov dword ptr [rsp+32], 8
    lea rax, [r15+SPXH_MEM]
    mov [rsp+40], rax
    call spx_iir_mem
    test eax, eax
    jz .Lspxd_bad
    jmp .Lspxd_qmf
.Lspxd_active:
    mov eax, [r15+SPXH_MODE]
    lea rdx, [rip+spxd_frame_bits]
    mov edx, [rdx+rax*4]
    sub edx, 4
    mov eax, [r13+SPXB_POS]
    add eax, edx
    mov [rsp+80], eax
    cmp eax, [r13+SPXB_BITS]
    ja .Lspxd_short
    # Low-band gain/RMS and innovation side channels.
    xor ecx, ecx
.Lspxd_low_side:
    mov eax, [r12+SPXN_PI_GAIN+rcx*4]
    cmp dword ptr [rsp+64], 1
    je .Lspxd_low_pi_store
    mov eax, [r12+SPXD_WB+SPXH_PI+rcx*4]
.Lspxd_low_pi_store:
    mov [rbx+SPXD_PI+rcx*4], eax
    inc ecx
    cmp ecx, 4
    jb .Lspxd_low_side
    cmp dword ptr [rsp+64], 1
    jne .Lspxd_low_wb_rms
    mov dword ptr [rsp+76], 0
.Lspxd_low_nb_rms:
    mov eax, [rsp+76]
    imul eax, eax, 160
    lea rcx, [r12+SPXN_EXC+rax]
    mov edx, 40
    call spxd_rms
    mov eax, [rsp+76]
    movss [rbx+SPXD_RMS+rax*4], xmm0
    inc dword ptr [rsp+76]
    cmp dword ptr [rsp+76], 4
    jb .Lspxd_low_nb_rms
    lea rax, [r12+SPXN_INNOVATION]
    jmp .Lspxd_low_ready
.Lspxd_low_wb_rms:
    movups xmm0, [r12+SPXD_WB+SPXH_RMS]
    movups [rbx+SPXD_RMS], xmm0
    lea rax, [r12+SPXD_WB+SPXH_INNOV]
.Lspxd_low_ready:
    mov [rsp+120], rax
    mov rcx, r13
    lea rdx, [rbx+SPXD_QLSP]
    mov r8d, 2
    mov r9d, 8
    call spx_lsp_unquant
    cmp eax, 8
    jne .Lspxd_bad
    cmp dword ptr [r15+SPXH_FIRST], 0
    je .Lspxd_subframes
    movups xmm0, [rbx+SPXD_QLSP]
    movups xmm1, [rbx+SPXD_QLSP+16]
    movups [r15+SPXH_OLD_LSP], xmm0
    movups [r15+SPXH_OLD_LSP+16], xmm1
.Lspxd_subframes:
    mov dword ptr [rsp+76], 0
    mov dword ptr [rsp+88], 0
.Lspxd_sub:
    lea rcx, [r15+SPXH_OLD_LSP]
    lea rdx, [rbx+SPXD_QLSP]
    lea r8, [rbx+SPXD_INTERP]
    mov r9d, 8
    mov eax, [rsp+76]
    mov [rsp+32], eax
    mov dword ptr [rsp+40], 4
    mov eax, [rip+spxd_margin]
    mov [rsp+48], eax
    call spx_lsp_interpolate
    test eax, eax
    jz .Lspxd_bad
    lea rcx, [rbx+SPXD_INTERP]
    lea rdx, [rbx+SPXD_AK]
    mov r8d, 8
    mov r9d, 8
    call spx_lsp_to_lpc
    test eax, eax
    jz .Lspxd_bad
    movss xmm0, [rip+spxd_one]
    movaps xmm1, xmm0
    xor ecx, ecx
.Lspxd_response:
    movss xmm2, [rbx+SPXD_AK+rcx*4+4]
    subss xmm2, [rbx+SPXD_AK+rcx*4]
    addss xmm0, xmm2
    movss xmm2, [rbx+SPXD_AK+rcx*4]
    addss xmm2, [rbx+SPXD_AK+rcx*4+4]
    addss xmm1, xmm2
    add ecx, 2
    cmp ecx, 8
    jb .Lspxd_response
    mov eax, [rsp+76]
    movss [r15+SPXH_PI+rax*4], xmm1
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rip+spxd_point01]
    movss xmm1, [rbx+SPXD_PI+rax*4]
    cvtss2sd xmm1, xmm1
    addsd xmm1, [rip+spxd_point01]
    divsd xmm1, xmm0
    cvtsd2ss xmm1, xmm1
    movss [rsp+92], xmm1
    mov eax, [rsp+76]
    imul eax, [rsp+72]
    mov [rsp+108], eax                # offset in half-rate frame
    # Clear complete innovation output for this subframe (zero odd slots).
    lea rdx, [r15+SPXH_INNOV+rax*8]
    mov ecx, [rsp+72]
    add ecx, ecx
    xor eax, eax
.Lspxd_clear_innov:
    mov dword ptr [rdx+rax*4], 0
    inc eax
    cmp eax, ecx
    jb .Lspxd_clear_innov
    cmp dword ptr [r15+SPXH_MODE], 1
    jne .Lspxd_codebook
    mov rcx, r13
    mov edx, 5
    call spx_bits_read
    lea rdx, [rip+spxh_fold_gain]
    movss xmm0, [rdx+rax*4]
    divss xmm0, [rsp+92]
    movss xmm1, [rip+spxd_point9]
    cmp dword ptr [rsp+64], 1
    je .Lspxd_fold_gain
    movss xmm1, [rip+spxd_point7]
.Lspxd_fold_gain:
    mov rdx, [rsp+120]
    mov eax, [rsp+108]
    lea rdx, [rdx+rax*4]
    xor ecx, ecx
.Lspxd_fold:
    movss xmm2, [rdx+rcx*4]
    mulss xmm2, xmm1
    mulss xmm2, xmm0
    test ecx, 1
    jz .Lspxd_fold_store
    movd eax, xmm2
    xor eax, 0x80000000
    movd xmm2, eax
.Lspxd_fold_store:
    movss [rbx+SPXD_EXC+rcx*4], xmm2
    inc ecx
    cmp ecx, [rsp+72]
    jb .Lspxd_fold
    jmp .Lspxd_exc_ready
.Lspxd_codebook:
    mov rcx, r13
    mov edx, 4
    call spx_bits_read
    lea rdx, [rip+spxh_code_gain]
    movss xmm0, [rdx+rax*4]
    mov eax, [rsp+76]
    mulss xmm0, [rbx+SPXD_RMS+rax*4]
    divss xmm0, [rsp+92]
    movss [rsp+96], xmm0
    xor eax, eax
.Lspxd_zero_code:
    mov dword ptr [rbx+SPXD_EXC+rax*4], 0
    mov dword ptr [rbx+SPXD_INNOV2+rax*4], 0
    inc eax
    cmp eax, 40
    jb .Lspxd_zero_code
    mov rcx, r13
    lea rdx, [rbx+SPXD_EXC]
    mov r8d, 7
    cmp dword ptr [r15+SPXH_MODE], 2
    jne .Lspxd_code_kind
    mov r8d, 6
.Lspxd_code_kind:
    mov r9d, 40
    call spx_innovation_decode
    cmp eax, 40
    jne .Lspxd_bad
    xor ecx, ecx
    movss xmm0, [rsp+96]
.Lspxd_scale_code:
    movss xmm1, [rbx+SPXD_EXC+rcx*4]
    mulss xmm1, xmm0
    movss [rbx+SPXD_EXC+rcx*4], xmm1
    inc ecx
    cmp ecx, 40
    jb .Lspxd_scale_code
    cmp dword ptr [r15+SPXH_MODE], 4
    jne .Lspxd_exc_ready
    mov rcx, r13
    lea rdx, [rbx+SPXD_INNOV2]
    mov r8d, 7
    mov r9d, 40
    call spx_innovation_decode
    cmp eax, 40
    jne .Lspxd_bad
    movss xmm0, [rsp+96]
    mulss xmm0, [rip+spxd_point4]
    xor ecx, ecx
.Lspxd_double_code:
    movss xmm1, [rbx+SPXD_INNOV2+rcx*4]
    mulss xmm1, xmm0
    addss xmm1, [rbx+SPXD_EXC+rcx*4]
    movss [rbx+SPXD_EXC+rcx*4], xmm1
    inc ecx
    cmp ecx, 40
    jb .Lspxd_double_code
.Lspxd_exc_ready:
    mov eax, [rsp+108]
    lea rdx, [r15+SPXH_INNOV+rax*8]
    xor ecx, ecx
.Lspxd_save_innov:
    mov eax, [rbx+SPXD_EXC+rcx*4]
    mov [rdx+rcx*8], eax
    inc ecx
    cmp ecx, [rsp+72]
    jb .Lspxd_save_innov
    mov eax, [rsp+68]
    add eax, [rsp+108]
    lea r8, [r14+rax*4]
    lea rcx, [r15+SPXH_EXC]
    lea rdx, [r15+SPXH_LPC]
    mov r9d, [rsp+72]
    mov dword ptr [rsp+32], 8
    lea rax, [r15+SPXH_MEM]
    mov [rsp+40], rax
    call spx_iir_mem
    test eax, eax
    jz .Lspxd_bad
    xor ecx, ecx
.Lspxd_install_exc:
    mov eax, [rbx+SPXD_EXC+rcx*4]
    mov [r15+SPXH_EXC+rcx*4], eax
    inc ecx
    cmp ecx, [rsp+72]
    jb .Lspxd_install_exc
    movups xmm0, [rbx+SPXD_AK]
    movups xmm1, [rbx+SPXD_AK+16]
    movups [r15+SPXH_LPC], xmm0
    movups [r15+SPXH_LPC+16], xmm1
    lea rcx, [r15+SPXH_EXC]
    mov edx, [rsp+72]
    call spxd_rms
    mov eax, [rsp+76]
    movss [r15+SPXH_RMS+rax*4], xmm0
    mulss xmm0, xmm0
    divss xmm0, [rip+spxd_four]
    addss xmm0, [rsp+88]
    movss [rsp+88], xmm0
    inc dword ptr [rsp+76]
    cmp dword ptr [rsp+76], 4
    jb .Lspxd_sub
    mov eax, [r13+SPXB_POS]
    cmp eax, [rsp+80]
    jne .Lspxd_bad
    cmp dword ptr [r13+SPXB_ERROR], 0
    jne .Lspxd_bad
    movss xmm0, [rsp+88]
    cvtss2sd xmm0, xmm0
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss [r15+SPXH_ENERGY], xmm0
    movups xmm0, [rbx+SPXD_QLSP]
    movups xmm1, [rbx+SPXD_QLSP+16]
    movups [r15+SPXH_OLD_LSP], xmm0
    movups [r15+SPXH_OLD_LSP+16], xmm1
    mov dword ptr [r15+SPXH_FIRST], 0
.Lspxd_qmf:
    # A new last-subframe excitation/energy may not reach synthesis until
    # the next call. Reject nonfinite new history before it can commit.
    mov ecx, 12
.Lspxd_validate_new_history:
    mov eax, [r15+rcx]
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    jae .Lspxd_bad
    add ecx, 4
    cmp ecx, 3568
    jb .Lspxd_validate_new_history
    xor ecx, ecx
.Lspxd_qmf_load:
    mov rax, [r15+SPXH_QMF+rcx]
    mov [rbx+SPXD_QMF+rcx], rax
    add ecx, 8
    cmp ecx, 512
    jb .Lspxd_qmf_load
    lea rcx, [rbx+SPXD_QMF]
    mov rdx, r14
    mov eax, [rsp+68]
    lea r8, [r14+rax*4]
    mov r9, r14
    add eax, eax
    mov [rsp+32], eax
    mov [rsp+40], eax
    call spx_qmf_synth
    test eax, eax
    jz .Lspxd_bad
    xor ecx, ecx
.Lspxd_qmf_save:
    mov rax, [rbx+SPXD_QMF+rcx]
    mov [r15+SPXH_QMF+rcx], rax
    add ecx, 8
    cmp ecx, 512
    jb .Lspxd_qmf_save
    inc dword ptr [rsp+64]
    jmp .Lspxd_layer
.Lspxd_frame_done:
    mov eax, [rsp+112]
    mov [rsp+116], eax
.Lspxd_stereo_stage:
    movups xmm0, [r12+SPXD_STEREO]
    movups [rbx+SPXD_STEREO_WORK], xmm0
    mov rax, [r12+SPXD_STEREO+16]
    mov [rbx+SPXD_STEREO_WORK+16], rax
    mov edx, [r12+SPXN_STEREO_CODE]
    cmp edx, -1
    je .Lspxd_stereo_control_ready
    lea rcx, [rbx+SPXD_STEREO_WORK]
    call spx_stereo_control
    test eax, eax
    jz .Lspxd_bad
.Lspxd_stereo_control_ready:
    cmp dword ptr [rsp+116], 0
    je .Lspxd_stereo_save
    cmp dword ptr [r12+SPXD_CHANNELS], 2
    jne .Lspxd_stereo_save
    lea rcx, [rbx+SPXD_STEREO_WORK]
    mov rdx, r14
    lea r8, [rbx+SPXD_STEREO_OUT]
    mov r9d, [rsp+112]
    mov eax, [rsp+136]
    mov [rsp+32], eax
    call spx_stereo_apply
    cmp eax, [rsp+112]
    jne .Lspxd_bad
    lea rax, [rbx+SPXD_STEREO_OUT]
    mov [rsp+128], rax
.Lspxd_stereo_save:
    movups xmm0, [rbx+SPXD_STEREO_WORK]
    movups [r12+SPXD_STEREO], xmm0
    mov rax, [rbx+SPXD_STEREO_WORK+16]
    mov [r12+SPXD_STEREO+16], rax
.Lspxd_commit:
    xor eax, eax
.Lspxd_commit_live:
    mov rdx, [r12+rax]
    mov [rbx+rax], rdx
    add eax, 8
    cmp eax, SPXD_LIVE
    jb .Lspxd_commit_live
    test rsi, rsi
    jz .Lspxd_commit_audio
    mov eax, [r13+SPXB_POS]
    mov [rsi+SPXB_POS], eax
.Lspxd_commit_audio:
    cmp dword ptr [rsp+116], 0
    jz .Lspxd_success
    mov edx, [rsp+136]
    mov r8, [rsp+128]
    xor eax, eax
.Lspxd_commit_output:
    mov ecx, [r8+rax*4]
    mov [rdi+rax*4], ecx
    inc eax
    cmp eax, edx
    jb .Lspxd_commit_output
.Lspxd_success:
    mov eax, [rsp+116]
    jmp .Lspxd_return
.Lspxd_short:
    mov dword ptr [r13+SPXB_ERROR], 1
.Lspxd_bad:
    test rsi, rsi
    jz .Lspxd_bad_plain
    cmp dword ptr [r13+SPXB_ERROR], 0
    je .Lspxd_bad_plain
    mov dword ptr [rsi+SPXB_ERROR], 1
.Lspxd_bad_plain:
    mov eax, -1
.Lspxd_return:
    add rsp, 256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN spx_decoder_frame
