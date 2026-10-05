# Original Apple Lossless (ALAC) decoder in x86-64 assembly. MIT, see LICENSE.
# Algorithm reference: Apple's open-source ALAC decoder (Apache License 2.0)
# and its documented bitstream; see THIRD_PARTY_NOTICES. Track mode only:
# MP4/Matroska supply the 24-byte ALACSpecificConfig and one frame per
# packet. Elements SCE/CPE/LFE with adaptive Golomb-Rice residuals, the
# adaptive FIR predictor, stereo decorrelation and shifted low bits;
# 16/20/24/32-bit, 1-8 channels in ALAC channel order, mixed to stereo with
# the shared WAVE speaker weights.
.include "lamp.inc"
.globl alac_frame_length, alac_wave_index, alac_masks

.equ AL_PB, 4
.equ AL_MB, 5
.equ AL_KB, 6

RODATA
# ALAC channel order -> WAVE order index, per channel count (8 bytes each).
alac_wave_index:
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 1, 0, 0, 0, 0, 0, 0
    .byte 2, 0, 1, 0, 0, 0, 0, 0
    .byte 2, 0, 1, 3, 0, 0, 0, 0
    .byte 2, 0, 1, 3, 4, 0, 0, 0
    .byte 2, 0, 1, 4, 5, 3, 0, 0
    .byte 2, 0, 1, 4, 5, 6, 3, 0
    .byte 2, 6, 7, 0, 1, 4, 5, 3
# WAVE speaker masks of those layouts.
alac_masks: .long 4, 3, 7, 0x107, 0x37, 0x3f, 0x13f, 0xff

.data
alac_frame_length: .long 0
alac_bits: .long 0
alac_channels: .long 0
alac_pb: .long 0
alac_mb: .long 0
alac_kb: .long 0
alac_memory: .quad 0
alac_error: .quad 0                 # two int32 residual/prediction buffers
alac_extra: .quad 0                 # two int32 shifted-bit buffers
alac_ptr: .quad 0                   # bit reader: packet, end, position
alac_end: .quad 0
alac_pos: .quad 0
alac_bad: .long 0
alac_samples: .long 0               # samples in the frame being decoded
alac_shift: .long 0                 # shifted-off low bits (0, 8, 16)
alac_bps: .long 0
alac_coefs: .zero 2*32*2
alac_order: .zero 2*4
alac_quant: .zero 2*4
alac_mode: .zero 2*4
alac_history: .zero 2*4

.text
FN alac_track_close
    sub rsp, 40
    mov rcx, [rip + alac_memory]
    test rcx, rcx
    jz .Lalac_close_done
    call mem_free
    mov qword ptr [rip + alac_memory], 0
.Lalac_close_done:
    add rsp, 40
    ret
ENDFN alac_track_close

# RCX=ALACSpecificConfig, optionally after a 4-byte version/flags field,
# EDX=bytes -> EAX=1. Sets the format globals and stereo mix.
FN alac_track_open
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov ebx, edx
    call alac_track_close
    cmp ebx, 24
    jb .Lalac_open_bad
    cmp ebx, 28
    jb .Lalac_open_config
    cmp dword ptr [rsi], 0                # MP4 'alac' box: version and flags
    jne .Lalac_open_config
    add rsi, 4
.Lalac_open_config:
    mov eax, [rsi]
    bswap eax
    test eax, eax
    jz .Lalac_open_bad
    cmp eax, 65536
    ja .Lalac_open_bad
    mov [rip + alac_frame_length], eax
    mov [rip + maximum_block], eax
    cmp byte ptr [rsi + 4], 0             # compatible version
    jne .Lalac_open_bad
    movzx eax, byte ptr [rsi + 5]
    cmp eax, 16
    je .Lalac_open_depth
    cmp eax, 20
    je .Lalac_open_depth
    cmp eax, 24
    je .Lalac_open_depth
    cmp eax, 32
    jne .Lalac_open_bad
.Lalac_open_depth:
    mov [rip + alac_bits], eax
    mov [rip + source_bits], eax
    movzx eax, byte ptr [rsi + 6]
    mov [rip + alac_pb], eax
    movzx eax, byte ptr [rsi + 7]
    mov [rip + alac_mb], eax
    movzx eax, byte ptr [rsi + 8]
    test eax, eax
    jz .Lalac_open_bad
    cmp eax, 32
    ja .Lalac_open_bad
    mov [rip + alac_kb], eax
    movzx eax, byte ptr [rsi + 9]
    cmp eax, 1
    jb .Lalac_open_bad
    cmp eax, 8
    ja .Lalac_open_bad
    mov [rip + alac_channels], eax
    mov [rip + source_channels], eax
    mov eax, [rsi + 20]
    bswap eax
    cmp eax, 8000
    jb .Lalac_open_bad
    cmp eax, 192000
    ja .Lalac_open_bad
    mov [rip + sample_rate], eax
    # Working storage: residual/prediction and shifted bits, two channels each.
    mov ecx, [rip + alac_frame_length]
    shl ecx, 4
    call mem_alloc
    test rax, rax
    jz .Lalac_open_bad
    mov [rip + alac_memory], rax
    mov [rip + alac_error], rax
    mov ecx, [rip + alac_frame_length]
    lea rax, [rax + rcx*8]
    mov [rip + alac_extra], rax
    # Speaker layout for the stereo mix and the FLAC channel buffers.
    mov eax, [rip + alac_channels]
    lea rcx, [rip + alac_masks]
    mov eax, [rcx + rax*4 - 4]
    mov [rip + pcm_channel_mask], eax
    mov dword ptr [rip + pcm_mask_seen], 1
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + pcm_mix], 0
    call flac_prepare
    test eax, eax
    jz .Lalac_open_bad
    mov eax, 1
    jmp .Lalac_open_return
.Lalac_open_bad:
    call alac_track_close
    xor eax, eax
.Lalac_open_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN alac_track_open

# Bit reader. ECX=bits (0-32) -> EAX, MSB first; reading past the packet sets
# alac_bad and yields zeros.
LOCALFN alac_peek
    # RAX=next 64 bits of the stream, left-aligned, zero beyond the end.
    mov r8, [rip + alac_pos]
    mov r9, r8
    shr r9, 3
    add r9, [rip + alac_ptr]
    lea r10, [r9 + 8]
    cmp r10, [rip + alac_end]
    ja .Lalac_peek_tail
    mov rax, [r9]
    bswap rax
    jmp .Lalac_peek_shift
.Lalac_peek_tail:
    xor eax, eax
    mov r10d, 8
.Lalac_peek_byte:
    shl rax, 8
    cmp r9, [rip + alac_end]
    jae .Lalac_peek_zero
    movzx r11d, byte ptr [r9]
    or rax, r11
.Lalac_peek_zero:
    inc r9
    dec r10d
    jnz .Lalac_peek_byte
.Lalac_peek_shift:
    mov r9, rcx
    mov ecx, r8d
    and ecx, 7
    shl rax, cl
    mov rcx, r9
    ret
ENDFN alac_peek

LOCALFN alac_get
    test ecx, ecx
    jz .Lalac_get_zero
    mov edx, ecx
    call alac_peek
    mov ecx, 64
    sub ecx, edx
    shr rax, cl
    add [rip + alac_pos], rdx
    mov r8, [rip + alac_end]
    sub r8, [rip + alac_ptr]
    shl r8, 3
    cmp [rip + alac_pos], r8
    jbe .Lalac_get_done
    mov dword ptr [rip + alac_bad], 1
.Lalac_get_done:
    ret
.Lalac_get_zero:
    xor eax, eax
    ret
ENDFN alac_get

# RCX=packet, EDX=bytes -> EAX=samples in the frame, or -1.
FN alac_track_samples
    sub rsp, 40
    mov [rip + alac_ptr], rcx
    add rdx, rcx
    mov [rip + alac_end], rdx
    mov qword ptr [rip + alac_pos], 0
    mov dword ptr [rip + alac_bad], 0
    mov ecx, 3
    call alac_get
    cmp eax, 1
    ja .Lalac_samples_check_lfe
    jmp .Lalac_samples_header
.Lalac_samples_check_lfe:
    cmp eax, 3
    jne .Lalac_samples_bad                # frames begin with an audio element
.Lalac_samples_header:
    mov ecx, 16                           # instance tag and unused bits
    call alac_get
    mov ecx, 1
    call alac_get
    test eax, eax
    jz .Lalac_samples_full
    mov ecx, 3
    call alac_get
    mov ecx, 32
    call alac_get
    test eax, eax
    jz .Lalac_samples_bad
    cmp eax, [rip + alac_frame_length]
    ja .Lalac_samples_bad
    jmp .Lalac_samples_return
.Lalac_samples_full:
    mov eax, [rip + alac_frame_length]
.Lalac_samples_return:
    cmp dword ptr [rip + alac_bad], 0
    jne .Lalac_samples_bad
    add rsp, 40
    ret
.Lalac_samples_bad:
    mov eax, -1
    add rsp, 40
    ret
ENDFN alac_track_samples

# Adaptive Golomb-Rice residuals. RCX=int32 output, EDX=samples,
# R8D=history multiplier, R9D=escape bits (bps). Returns EAX=1.
LOCALFN alac_rice
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rdi, rcx
    mov esi, edx
    mov r12d, r8d                         # multiplier
    mov r13d, r9d                         # escape bits
    mov r14d, [rip + alac_mb]             # history
    xor r15d, r15d                        # sign modifier
    xor ebx, ebx
.Lalac_rice_sample:
    cmp ebx, esi
    jae .Lalac_rice_done
    cmp dword ptr [rip + alac_bad], 0
    jne .Lalac_rice_bad
    # k = min(log2((history >> 9) + 3), kb)
    mov eax, r14d
    shr eax, 9
    add eax, 3
    bsr ecx, eax
    cmp ecx, [rip + alac_kb]
    cmova ecx, [rip + alac_kb]
    mov edx, r13d
    call alac_scalar
    add eax, r15d
    xor r15d, r15d
    # output = (x >> 1) ^ -(x & 1)
    mov edx, eax
    shr edx, 1
    mov ecx, eax
    and ecx, 1
    neg ecx
    xor edx, ecx
    mov [rdi + rbx*4], edx
    inc ebx
    # history update, clamped for large values
    cmp eax, 0xffff
    jbe .Lalac_rice_history
    mov r14d, 0xffff
    jmp .Lalac_rice_zero_check
.Lalac_rice_history:
    # history += x * mult - ((history * mult) >> 9)
    imul eax, r12d
    mov ecx, r14d
    imul ecx, r12d
    shr ecx, 9
    sub eax, ecx
    add r14d, eax
.Lalac_rice_zero_check:
    cmp r14d, 128
    jae .Lalac_rice_sample
    cmp ebx, esi
    jae .Lalac_rice_sample
    # A run of zeros: k = min(7 - log2(history) + ((history + 16) >> 6), kb)
    mov ecx, 7
    test r14d, r14d
    jz .Lalac_rice_run_log
    bsr eax, r14d
    sub ecx, eax
.Lalac_rice_run_log:
    lea eax, [r14 + 16]
    shr eax, 6
    add ecx, eax
    cmp ecx, [rip + alac_kb]
    cmova ecx, [rip + alac_kb]
    mov edx, 16
    call alac_scalar
    test eax, eax
    jz .Lalac_rice_run_done
    mov ecx, esi
    sub ecx, ebx
    cmp eax, ecx
    ja .Lalac_rice_bad                    # a run may not pass the frame end
    mov ecx, eax
    push rdi
    lea rdi, [rdi + rbx*4]
    mov edx, eax
    xor eax, eax
    rep stosd
    pop rdi
    add ebx, edx
    mov eax, edx
.Lalac_rice_run_done:
    cmp eax, 0xffff
    ja .Lalac_rice_run_reset
    mov r15d, 1
.Lalac_rice_run_reset:
    xor r14d, r14d
    jmp .Lalac_rice_sample
.Lalac_rice_done:
    mov eax, 1
    cmp dword ptr [rip + alac_bad], 0
    je .Lalac_rice_return
.Lalac_rice_bad:
    mov dword ptr [rip + alac_bad], 1
    xor eax, eax
.Lalac_rice_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN alac_rice

# ECX=k (>= 1), EDX=escape bits -> EAX=value. Up to nine leading ones; nine
# select an escaped value of EDX bits.
LOCALFN alac_scalar
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, ecx
    mov esi, edx
    call alac_peek
    not rax
    mov ecx, 9
    test rax, rax
    jz .Lalac_scalar_ones
    bsr rdx, rax
    mov ecx, 63
    sub ecx, edx                          # leading ones
    cmp ecx, 9
    jb .Lalac_scalar_prefix
    mov ecx, 9
.Lalac_scalar_ones:
    add qword ptr [rip + alac_pos], 9
    mov ecx, esi
    call alac_get
    jmp .Lalac_scalar_return
.Lalac_scalar_prefix:
    mov eax, ecx                          # prefix x
    lea rdx, [rcx + 1]
    add [rip + alac_pos], rdx
    cmp ebx, 1
    je .Lalac_scalar_check
    mov edx, eax
    mov ecx, ebx
    shl edx, cl
    sub edx, eax                          # x * (2^k - 1)
    mov [rsp + 32], edx
    mov ecx, ebx
    call alac_peek
    mov ecx, 64
    sub ecx, ebx
    shr rax, cl                           # next k bits
    cmp eax, 1
    jbe .Lalac_scalar_short
    lea edx, [rax - 1]
    add edx, [rsp + 32]
    add [rip + alac_pos], rbx
    mov eax, edx
    jmp .Lalac_scalar_check
.Lalac_scalar_short:
    lea rdx, [rbx - 1]
    add [rip + alac_pos], rdx
    mov eax, [rsp + 32]
.Lalac_scalar_check:
    mov r8, [rip + alac_end]
    sub r8, [rip + alac_ptr]
    shl r8, 3
    cmp [rip + alac_pos], r8
    jbe .Lalac_scalar_return
    mov dword ptr [rip + alac_bad], 1
.Lalac_scalar_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN alac_scalar

# Adaptive FIR prediction, in place on alac_error for one channel.
# RCX=int32 samples (residuals in, samples out), EDX=channel (0/1).
LOCALFN alac_predict
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov r15d, edx
    lea rax, [rip + alac_mode]
    cmp dword ptr [rax + r15*4], 15
    jne .Lalac_predict_main
    # Mode 15: a first-order pass before the coded predictor.
    mov r12d, 31
    xor r13d, r13d
    call alac_lpc
.Lalac_predict_main:
    lea rax, [rip + alac_order]
    mov r12d, [rax + r15*4]
    lea rax, [rip + alac_quant]
    mov r13d, [rax + r15*4]
    call alac_lpc
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN alac_predict

# RSI=samples, R12D=order (0-31; 31 = first order), R13D=quantization,
# R15D=channel (coefficients). Uses RBX, RDI, R8-R11, R14.
LOCALFN alac_lpc
    mov r14d, [rip + alac_samples]
    cmp r14d, 1
    jbe .Lalac_lpc_done
    mov ecx, 32
    sub ecx, [rip + alac_bps]             # sign-extension shift
    test r12d, r12d
    jz .Lalac_lpc_done                    # order 0: samples are the residuals
    cmp r12d, 31
    jne .Lalac_lpc_warm
    mov ebx, 1
.Lalac_lpc_first:
    mov eax, [rsi + rbx*4 - 4]
    add eax, [rsi + rbx*4]
    shl eax, cl
    sar eax, cl
    mov [rsi + rbx*4], eax
    inc ebx
    cmp ebx, r14d
    jb .Lalac_lpc_first
    jmp .Lalac_lpc_done
.Lalac_lpc_warm:
    # Warm-up: the first order samples accumulate their residuals.
    mov ebx, 1
.Lalac_lpc_warm_sample:
    cmp ebx, r12d
    ja .Lalac_lpc_body
    cmp ebx, r14d
    jae .Lalac_lpc_done
    mov eax, [rsi + rbx*4 - 4]
    add eax, [rsi + rbx*4]
    shl eax, cl
    sar eax, cl
    mov [rsi + rbx*4], eax
    inc ebx
    jmp .Lalac_lpc_warm_sample
.Lalac_lpc_body:
    lea rdi, [rip + alac_coefs]
    mov eax, r15d
    shl eax, 6
    add rdi, rax                          # int16 coefficients, reversed order
.Lalac_lpc_sample:
    cmp ebx, r14d
    jae .Lalac_lpc_done
    # d = s[i - order - 1]; pred[j] = s[i - order + j]
    mov eax, ebx
    sub eax, r12d
    lea r8, [rsi + rax*4]                 # pred
    mov r9d, [r8 - 4]                     # d
    xor r10d, r10d                        # val
    xor r11d, r11d
.Lalac_lpc_tap:
    mov eax, [r8 + r11*4]
    sub eax, r9d
    movsx edx, word ptr [rdi + r11*2]
    imul eax, edx
    add r10d, eax
    inc r11d
    cmp r11d, r12d
    jb .Lalac_lpc_tap
    # val = (val + 2^(quant-1)) >> quant in 64 bits, then + d + residual
    movsxd rax, r10d
    push rcx
    mov ecx, r13d
    dec ecx
    mov edx, 1
    shl rdx, cl
    add rax, rdx
    inc ecx
    sar rax, cl
    pop rcx
    mov r10d, [rsi + rbx*4]               # residual (error_val)
    add eax, r9d
    add eax, r10d
    shl eax, cl
    sar eax, cl
    mov [rsi + rbx*4], eax
    # Adapt the coefficients toward the residual's sign.
    test r10d, r10d
    jz .Lalac_lpc_next
    mov edx, 1
    jg .Lalac_lpc_sign_ready
    mov edx, -1
.Lalac_lpc_sign_ready:                     # EDX=error_sign
    xor r11d, r11d
.Lalac_lpc_adapt:
    cmp r11d, r12d
    jae .Lalac_lpc_next
    mov eax, r10d
    imul eax, edx
    test eax, eax
    jle .Lalac_lpc_next
    mov eax, r9d
    sub eax, [r8 + r11*4]                 # d - pred[j]
    push rcx
    xor ecx, ecx
    test eax, eax
    jz .Lalac_lpc_sign
    mov ecx, 1
    jg .Lalac_lpc_sign
    mov ecx, -1
.Lalac_lpc_sign:
    imul ecx, edx                         # sign
    sub word ptr [rdi + r11*2], cx
    imul eax, ecx
    mov ecx, r13d
    sar eax, cl
    lea ecx, [r11 + 1]
    imul eax, ecx
    sub r10d, eax
    pop rcx
    inc r11d
    jmp .Lalac_lpc_adapt
.Lalac_lpc_next:
    inc ebx
    jmp .Lalac_lpc_sample
.Lalac_lpc_done:
    ret
ENDFN alac_lpc

# One SCE/LFE (EDX=1) or CPE (EDX=2) element into channel buffers starting at
# WAVE-mapped ALAC channel ECX. EAX=1 on success.
LOCALFN alac_element
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12d, ecx                         # first ALAC channel
    mov r13d, edx                         # channels in element
    mov ecx, 16                           # instance tag, unused bits
    call alac_get
    test eax, 0xfff
    jnz .Lalac_element_bad
    mov ecx, 1
    call alac_get
    mov ebx, eax                          # has sample count
    mov ecx, 2
    call alac_get
    shl eax, 3
    mov [rip + alac_shift], eax
    mov ecx, [rip + alac_bits]
    sub ecx, eax
    add ecx, r13d
    dec ecx
    cmp ecx, 32
    ja .Lalac_element_bad
    mov [rip + alac_bps], ecx
    mov ecx, 1
    call alac_get
    mov r14d, eax                         # uncompressed
    mov eax, [rip + alac_frame_length]
    test ebx, ebx
    jz .Lalac_element_count
    mov ecx, 32
    call alac_get
    test eax, eax
    jz .Lalac_element_bad
    cmp eax, [rip + alac_frame_length]
    ja .Lalac_element_bad
.Lalac_element_count:
    cmp dword ptr [rip + alac_samples], 0
    je .Lalac_element_first
    cmp eax, [rip + alac_samples]
    jne .Lalac_element_bad                # every element has the same length
.Lalac_element_first:
    mov [rip + alac_samples], eax
    test r14d, r14d
    jnz .Lalac_element_raw
    mov ecx, 8
    call alac_get
    mov [rsp + 32], eax                   # decorrelation shift
    mov ecx, 8
    call alac_get
    mov [rsp + 36], eax                   # left weight
    cmp r13d, 2
    jne .Lalac_element_predictors
    test eax, eax
    jz .Lalac_element_predictors
    cmp dword ptr [rsp + 32], 31
    ja .Lalac_element_bad
.Lalac_element_predictors:
    xor r15d, r15d
.Lalac_element_predictor:
    mov ecx, 4
    call alac_get
    lea rdx, [rip + alac_mode]
    mov [rdx + r15*4], eax
    mov ecx, 4
    call alac_get
    test eax, eax
    jz .Lalac_element_bad
    lea rdx, [rip + alac_quant]
    mov [rdx + r15*4], eax
    mov ecx, 3
    call alac_get
    imul eax, [rip + alac_pb]
    shr eax, 2
    lea rdx, [rip + alac_history]
    mov [rdx + r15*4], eax
    mov ecx, 5
    call alac_get
    cmp eax, [rip + alac_frame_length]
    jae .Lalac_element_bad
    lea rdx, [rip + alac_order]
    mov [rdx + r15*4], eax
    mov ebx, eax                          # read coefficients in reverse order
.Lalac_element_coef:
    test ebx, ebx
    jz .Lalac_element_coefs_done
    dec ebx
    mov ecx, 16
    call alac_get
    lea rdx, [rip + alac_coefs]
    mov ecx, r15d
    shl ecx, 5
    add ecx, ebx
    mov [rdx + rcx*2], ax
    jmp .Lalac_element_coef
.Lalac_element_coefs_done:
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_predictor
    # Shifted-off low bits, interleaved per sample.
    cmp dword ptr [rip + alac_shift], 0
    je .Lalac_element_residuals
    xor ebx, ebx
.Lalac_element_extra:
    cmp ebx, [rip + alac_samples]
    jae .Lalac_element_residuals
    xor r15d, r15d
.Lalac_element_extra_channel:
    mov ecx, [rip + alac_shift]
    call alac_get
    mov rdx, [rip + alac_extra]
    mov ecx, r15d
    imul ecx, [rip + alac_frame_length]
    add ecx, ebx
    mov [rdx + rcx*4], eax
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_extra_channel
    inc ebx
    jmp .Lalac_element_extra
.Lalac_element_residuals:
    xor r15d, r15d
.Lalac_element_channel:
    mov rcx, [rip + alac_error]
    mov eax, r15d
    imul eax, [rip + alac_frame_length]
    lea rcx, [rcx + rax*4]
    mov rsi, rcx
    mov edx, [rip + alac_samples]
    lea rax, [rip + alac_history]
    mov r8d, [rax + r15*4]
    mov r9d, [rip + alac_bps]
    call alac_rice
    test eax, eax
    jz .Lalac_element_bad
    mov rcx, rsi
    mov edx, r15d
    call alac_predict
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_channel
    # Stereo: undo the weighted mid/side, then append the low bits.
    cmp r13d, 2
    jne .Lalac_element_append
    mov eax, [rsp + 36]
    test eax, eax
    jz .Lalac_element_append
    mov rsi, [rip + alac_error]
    mov edi, [rip + alac_frame_length]
    xor ebx, ebx
.Lalac_element_decorrelate:
    cmp ebx, [rip + alac_samples]
    jae .Lalac_element_append
    movsxd rax, dword ptr [rsi + rdi*4]   # b
    movsxd rdx, dword ptr [rsp + 36]
    imul rax, rdx
    mov ecx, [rsp + 32]
    sar rax, cl
    mov edx, [rsi]                        # a
    sub edx, eax
    mov eax, [rsi + rdi*4]
    add eax, edx                          # b += a
    mov [rsi], eax
    mov [rsi + rdi*4], edx
    add rsi, 4
    inc ebx
    jmp .Lalac_element_decorrelate
.Lalac_element_raw:
    # Uncompressed: interleaved samples of the full depth.
    mov dword ptr [rip + alac_shift], 0
    xor ebx, ebx
.Lalac_element_raw_sample:
    cmp ebx, [rip + alac_samples]
    jae .Lalac_element_store
    xor r15d, r15d
.Lalac_element_raw_channel:
    mov ecx, [rip + alac_bits]
    call alac_get
    mov ecx, 32
    sub ecx, [rip + alac_bits]
    shl eax, cl
    sar eax, cl
    mov rdx, [rip + alac_error]
    mov ecx, r15d
    imul ecx, [rip + alac_frame_length]
    add ecx, ebx
    mov [rdx + rcx*4], eax
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_raw_channel
    inc ebx
    jmp .Lalac_element_raw_sample
.Lalac_element_append:
    cmp dword ptr [rip + alac_shift], 0
    je .Lalac_element_store
    xor r15d, r15d
.Lalac_element_append_channel:
    mov eax, r15d
    imul eax, [rip + alac_frame_length]
    mov rsi, [rip + alac_error]
    lea rsi, [rsi + rax*4]
    mov rdi, [rip + alac_extra]
    lea rdi, [rdi + rax*4]
    mov ecx, [rip + alac_shift]
    xor ebx, ebx
.Lalac_element_append_sample:
    cmp ebx, [rip + alac_samples]
    jae .Lalac_element_append_next
    mov eax, [rsi + rbx*4]
    shl eax, cl
    or eax, [rdi + rbx*4]
    mov [rsi + rbx*4], eax
    inc ebx
    jmp .Lalac_element_append_sample
.Lalac_element_append_next:
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_append_channel
.Lalac_element_store:
    # Widen into the WAVE-ordered int64 channel buffers.
    xor r15d, r15d
.Lalac_element_store_channel:
    lea eax, [r12 + r15]
    cmp eax, [rip + alac_channels]
    jae .Lalac_element_bad
    mov ecx, [rip + alac_channels]
    lea rdx, [rip + alac_wave_index]
    lea rdx, [rdx + rcx*8 - 8]
    movzx eax, byte ptr [rdx + rax]
    lea rdx, [rip + flac_channel_ptrs]
    mov rdi, [rdx + rax*8]
    mov eax, r15d
    imul eax, [rip + alac_frame_length]
    mov rsi, [rip + alac_error]
    lea rsi, [rsi + rax*4]
    xor ebx, ebx
.Lalac_element_widen:
    cmp ebx, [rip + alac_samples]
    jae .Lalac_element_store_next
    movsxd rax, dword ptr [rsi + rbx*4]
    mov [rdi + rbx*8], rax
    inc ebx
    jmp .Lalac_element_widen
.Lalac_element_store_next:
    inc r15d
    cmp r15d, r13d
    jb .Lalac_element_store_channel
    mov eax, 1
    cmp dword ptr [rip + alac_bad], 0
    je .Lalac_element_return
.Lalac_element_bad:
    xor eax, eax
.Lalac_element_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN alac_element

# RCX=frame, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# or -1 on error.
FN alac_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, r8
    mov r12d, r9d
    mov [rip + alac_ptr], rcx
    add rdx, rcx
    mov [rip + alac_end], rdx
    mov qword ptr [rip + alac_pos], 0
    mov dword ptr [rip + alac_bad], 0
    mov dword ptr [rip + alac_samples], 0
    xor ebx, ebx                          # channels decoded
.Lalac_frame_element:
    cmp dword ptr [rip + alac_bad], 0
    jne .Lalac_frame_bad
    mov ecx, 3
    call alac_get
    cmp eax, 7
    je .Lalac_frame_end
    cmp eax, 1
    je .Lalac_frame_pair
    test eax, eax
    jz .Lalac_frame_single
    cmp eax, 3
    je .Lalac_frame_single
    cmp eax, 4
    je .Lalac_frame_data
    cmp eax, 6
    je .Lalac_frame_fill
    jmp .Lalac_frame_bad                  # coupling channels and PCE unsupported
.Lalac_frame_single:
    mov ecx, ebx
    mov edx, 1
    call alac_element
    test eax, eax
    jz .Lalac_frame_bad
    inc ebx
    jmp .Lalac_frame_element
.Lalac_frame_pair:
    mov ecx, ebx
    mov edx, 2
    call alac_element
    test eax, eax
    jz .Lalac_frame_bad
    add ebx, 2
    jmp .Lalac_frame_element
.Lalac_frame_data:
    # Data stream element: tag, alignment flag, count, optional byte alignment.
    mov ecx, 4
    call alac_get
    mov ecx, 1
    call alac_get
    mov esi, eax
    mov ecx, 8
    call alac_get
    cmp eax, 255
    jne .Lalac_frame_data_count
    mov ecx, 8
    call alac_get
    add eax, 255
.Lalac_frame_data_count:
    test esi, esi
    jz .Lalac_frame_data_skip
    mov rcx, [rip + alac_pos]
    add rcx, 7
    and rcx, -8
    mov [rip + alac_pos], rcx
.Lalac_frame_data_skip:
    shl rax, 3
    add [rip + alac_pos], rax
    jmp .Lalac_frame_element
.Lalac_frame_fill:
    mov ecx, 4
    call alac_get
    cmp eax, 15
    jne .Lalac_frame_fill_skip
    mov ecx, 8
    call alac_get
    add eax, 14
.Lalac_frame_fill_skip:
    shl rax, 3
    add [rip + alac_pos], rax
    jmp .Lalac_frame_element
.Lalac_frame_end:
    cmp ebx, [rip + alac_channels]
    jne .Lalac_frame_bad
    cmp dword ptr [rip + alac_bad], 0
    jne .Lalac_frame_bad
    mov eax, [rip + alac_samples]
    cmp eax, r12d
    ja .Lalac_frame_bad
    mov [rip + frame_samples], eax
    mov dword ptr [rip + frame_used], 0
    mov rcx, rdi
    mov edx, eax
    call flac_emit
    jmp .Lalac_frame_return
.Lalac_frame_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lalac_frame_failed
    mov dword ptr [rip + decode_error], 80
.Lalac_frame_failed:
    mov eax, -1
.Lalac_frame_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN alac_track_decode
