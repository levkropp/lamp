# Spectral band replication (HE-AAC), included by aac.s. ISO/IEC 14496-3
# 4.6.18: SBR header and data, frequency band tables, the 32-band complex
# analysis and 64-band synthesis QMF banks, HF generation with inverse
# filtering, envelope adjustment with limiter, boost, smoothing, noise and
# sinusoids. tests/sbr_model.py is the stage-by-stage Python model it
# follows. Values are double precision throughout; the core PCM enters at
# +-32768 scale as ISO assumes.

# Channel state.
.equ SC_X, 0                        # 320 doubles: analysis input, oldest first
.equ SC_V, SC_X + 2560              # 1152 + 32 x 128 doubles: synthesis memory
.equ SC_W, SC_V + 41984             # 2 x 32 slots x 32 complex: analysis output
.equ SC_Y, SC_W + 32768             # 2 x 38 slots x 64 complex: adjusted HF
.equ SC_G_TEMP, SC_Y + 77824        # 42 x 48 doubles: gains by slot
.equ SC_Q_TEMP, SC_G_TEMP + 16128   # 42 x 48 doubles: noise levels by slot
.equ SC_ENV, SC_Q_TEMP + 16128      # 6 x 48 doubles: dequantized envelopes
.equ SC_NOISE, SC_ENV + 2304        # 3 x 8 doubles: dequantized noise floors
.equ SC_BW, SC_NOISE + 192          # 8 doubles: chirp factors
.equ SC_ENV_Q, SC_BW + 64           # 6 x 48 bytes
.equ SC_NOISE_Q, SC_ENV_Q + 288     # 3 x 8 bytes
.equ SC_S_INDEX, SC_NOISE_Q + 24    # 8 x 48 bytes: sinusoid index map
.equ SC_HARMONIC, SC_S_INDEX + 384  # 48 bytes
.equ SC_INVF, SC_HARMONIC + 48      # 8 bytes current, 8 previous
.equ SC_FREQ_RES, SC_INVF + 16      # 8 bytes
.equ SC_T_ENV, SC_FREQ_RES + 8      # 8 bytes
.equ SC_T_Q, SC_T_ENV + 8           # 4 bytes
.equ SC_DF_ENV, SC_T_Q + 4          # 8 bytes
.equ SC_DF_NOISE, SC_DF_ENV + 8     # 4 bytes
.equ SC_NUM_ENV, SC_DF_NOISE + 4
.equ SC_NUM_NOISE, SC_NUM_ENV + 4
.equ SC_T_ENV_OLD, SC_NUM_NOISE + 4
.equ SC_E_A0, SC_T_ENV_OLD + 4
.equ SC_E_A1, SC_E_A0 + 4
.equ SC_AMP_RES, SC_E_A1 + 4
.equ SC_CLASS, SC_AMP_RES + 4
.equ SC_HARMONIC_FLAG, SC_CLASS + 4
.equ SC_INDEX_NOISE, SC_HARMONIC_FLAG + 4
.equ SC_INDEX_SINE, SC_INDEX_NOISE + 4
.equ SC_YPOS, SC_INDEX_SINE + 4
.equ SC_SIZE, (SC_YPOS + 4 + 63) & -64

# Element state: header, frequency tables and two channels.
.equ SE_START, 0
.equ SE_READY, 4
.equ SE_PUSHED, 8
.equ SE_RESET, 12
.equ SE_COUPLING, 16
.equ SE_KX0, 24
.equ SE_KX1, 28
.equ SE_M0, 32
.equ SE_M1, 36
.equ SE_AMP_RES, 40
.equ SE_START_FREQ, 44
.equ SE_STOP_FREQ, 48
.equ SE_XOVER, 52
.equ SE_FREQ_SCALE, 56
.equ SE_ALTER, 60
.equ SE_NOISE_BANDS, 64
.equ SE_LIM_BANDS, 68
.equ SE_LIM_GAINS, 72
.equ SE_INTERPOL, 76
.equ SE_SMOOTHING, 80
.equ SE_SPECTRUM, 84                # header spectrum parameters known
.equ SE_TABLES, 88                  # frequency tables valid
.equ SE_K0, 92
.equ SE_K2, 96
.equ SE_N_MASTER, 100
.equ SE_N_LOW, 104
.equ SE_N_HIGH, 108
.equ SE_N_Q, 112
.equ SE_N_LIM, 116
.equ SE_PATCHES, 120
.equ SE_F_MASTER, 128               # 72 bytes
.equ SE_F_HIGH, 200                 # 64 bytes
.equ SE_F_LOW, 264                  # 64 bytes
.equ SE_F_NOISE, 328                # 8 bytes
.equ SE_F_LIM, 336                  # 64 bytes
.equ SE_PATCH_SIZE, 400             # 8 bytes
.equ SE_PATCH_START, 408            # 8 bytes
# Gains, noise and sinusoid levels per envelope (5 x 48 doubles each). They
# persist across frames and channels of the element, as FFmpeg's do: when the
# last patch is dropped the limiter table can end below kx + M, and the top
# subbands then reuse the previous values.
.equ SE_GAIN, 448
.equ SE_Q_M, SE_GAIN + 1920
.equ SE_S_M, SE_Q_M + 1920
.equ SE_CH, SE_S_M + 1920
.equ SE_SIZE, SE_CH + 2*SC_SIZE

# Shared scratch.
.equ SB_X_LOW, 0                    # 32 bands x 40 slots complex
.equ SB_X_HIGH, 20480               # 64 bands x 40 slots complex
.equ SB_X, 61440                    # 32 slots x (64 real, 64 imaginary): synthesis input
.equ SB_ALPHA0, 94208               # 64 complex
.equ SB_ALPHA1, 95232               # 64 complex
.equ SB_E_ORIG, 96256               # 5 x 48 doubles
.equ SB_Q_MAPPED, 98176
.equ SB_E_CURR, 100096
.equ SB_S_MAPPED, 107776            # 5 x 48 bytes
.equ SB_G_FILT, 108032              # 48 doubles
.equ SB_Q_FILT, 108416              # 48 doubles
.equ SB_U, 108800                   # 64 doubles: windowed analysis input
.equ SB_SIZE, 109312

.equ SBR_ELEMENTS, 5

RODATA
.include "sbr_tables.inc"
sbr_ceil_log2: .byte 0, 1, 2, 2, 3, 3
# Rate class of the SBR output rate for the start-frequency offsets.
sbr_rate_list: .long 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000
sbr_rate_rows: .byte 0, 1, 2, 3, 4, 4, 4, 5, 5
.p2align 3
sbr_limiter_warp: .double 1.32715174233856803909, 1.18509277094158210129, 1.11987160404675912501
sbr_limiter_gains: .double 0.70795, 1.0, 1.41254, 10000000000.0
sbr_smooth: .double 0.33333333333333, 0.30150283239582, 0.21816949906249
            .double 0.11516383427084, 0.03183050093751
sbr_bw_table: .double 0.0, 0.75, 0.9, 0.98
sbr_one: .double 1.0
sbr_half: .double 0.5
sbr_ln2: .quad 0x3fe62e42fefa39ef
sbr_log2e: .quad 0x3ff71547652b82fe
sbr_sqrt2: .quad 0x3ff6a09e667f3bcd
sbr_float_min: .double 1.1754943508222875e-38
sbr_float_epsilon: .double 1.1920928955078125e-07
sbr_gain_cap: .double 100000.0
sbr_boost_cap: .double 1.584893192
sbr_dk_scale: .double 1.000001
sbr_sixteen: .double 16.0
sbr_bw_low: .double 0.015625
sbr_alter_warp: .double 1.3
sbr_scale_in: .double 32768.0
sbr_scale_out: .double 3.0517578125e-05      # 1/32768
sbr_bw_new: .double 0.6, 0.75, 0.25, 0.90625, 0.09375
sbr_env_limit: .double 1.0e20

.data
sbr_active: .long 0                 # SBR decoding: output at twice the core rate
sbr_mode: .long -1                  # configuration: -1 implicit, 0 absent, 1 present
sbr_found: .long 0                  # the probed first packet carries SBR data
sbr_tables_ready: .long 0
.bss
.p2align 4
sbr_window: .zero 640*8             # QMF window as doubles
sbr_ana_cos: .zero 32*64*8          # [k][n]: 2 cos(pi/64 (k+1/2)(2n-1/2))
sbr_ana_sin: .zero 32*64*8
sbr_syn_cos: .zero 128*64*8         # [n][k]: cos(pi/128 (k+1/2)(2n-255)) / 64
sbr_syn_sin: .zero 128*64*8
sbr_elements: .zero 8*SBR_ELEMENTS  # element state pointers
sbr_scratch: .quad 0

.text
# One-time QMF tables.
LOCALFN sbr_init_tables
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    cmp dword ptr [rip + sbr_tables_ready], 0
    jne .Lsbr_init_done
    lea rsi, [rip + sbr_qmf_window]
    lea rdi, [rip + sbr_window]
    xor ecx, ecx
.Lsbr_init_window:
    cvtss2sd xmm0, [rsi + rcx*4]
    movsd [rdi + rcx*8], xmm0
    inc ecx
    cmp ecx, 640
    jb .Lsbr_init_window
    # Analysis: theta/pi = (k + 1/2)(2n - 1/2)/64.
    xor ebx, ebx                          # k * 64 + n
.Lsbr_init_analysis:
    mov eax, ebx
    shr eax, 6                            # k
    cvtsi2sd xmm0, eax
    addsd xmm0, [rip + sbr_half]
    mov eax, ebx
    and eax, 63                           # n
    add eax, eax
    cvtsi2sd xmm1, eax
    subsd xmm1, [rip + sbr_half]
    mulsd xmm0, xmm1
    mov eax, 64
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    movsd [rsp + 32], xmm0
    call sin_pi
    addsd xmm0, xmm0
    lea rax, [rip + sbr_ana_sin]
    movsd [rax + rbx*8], xmm0
    movsd xmm0, [rsp + 32]
    addsd xmm0, [rip + sbr_half]
    call sin_pi
    addsd xmm0, xmm0
    lea rax, [rip + sbr_ana_cos]
    movsd [rax + rbx*8], xmm0
    inc ebx
    cmp ebx, 32*64
    jb .Lsbr_init_analysis
    # Synthesis: theta/pi = (k + 1/2)(2n - 255)/128, scaled by 1/64.
    xor ebx, ebx                          # n * 64 + k
.Lsbr_init_synthesis:
    mov eax, ebx
    and eax, 63                           # k
    cvtsi2sd xmm0, eax
    addsd xmm0, [rip + sbr_half]
    mov eax, ebx
    shr eax, 6                            # n
    add eax, eax
    sub eax, 255
    cvtsi2sd xmm1, eax
    mulsd xmm0, xmm1
    mov eax, 128
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    movsd [rsp + 32], xmm0
    call sin_pi
    mov eax, 64
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    lea rax, [rip + sbr_syn_sin]
    movsd [rax + rbx*8], xmm0
    movsd xmm0, [rsp + 32]
    addsd xmm0, [rip + sbr_half]
    call sin_pi
    mov eax, 64
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    lea rax, [rip + sbr_syn_cos]
    movsd [rax + rbx*8], xmm0
    inc ebx
    cmp ebx, 128*64
    jb .Lsbr_init_synthesis
    mov dword ptr [rip + sbr_tables_ready], 1
.Lsbr_init_done:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_init_tables

# Allocates element states and scratch for ECX elements -> EAX=1.
LOCALFN sbr_open
    push rbx
    push rsi
    sub rsp, 40
    mov esi, ecx
    call sbr_close
    call sbr_init_tables
    mov ecx, SB_SIZE
    call mem_alloc
    test rax, rax
    jz .Lsbr_open_bad
    mov [rip + sbr_scratch], rax
    xor ebx, ebx
.Lsbr_open_element:
    cmp ebx, esi
    jae .Lsbr_open_done
    mov ecx, SE_SIZE
    call mem_alloc
    test rax, rax
    jz .Lsbr_open_bad
    lea rcx, [rip + sbr_elements]
    mov [rcx + rbx*8], rax
    mov rcx, rax
    call sbr_element_init
    inc ebx
    jmp .Lsbr_open_element
.Lsbr_open_done:
    mov eax, 1
    jmp .Lsbr_open_return
.Lsbr_open_bad:
    call sbr_close
    xor eax, eax
.Lsbr_open_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN sbr_open

LOCALFN sbr_close
    push rbx
    sub rsp, 32
    xor ebx, ebx
.Lsbr_close_element:
    lea rax, [rip + sbr_elements]
    mov rcx, [rax + rbx*8]
    test rcx, rcx
    jz .Lsbr_close_next
    mov qword ptr [rax + rbx*8], 0
    call mem_free
.Lsbr_close_next:
    inc ebx
    cmp ebx, SBR_ELEMENTS
    jb .Lsbr_close_element
    mov rcx, [rip + sbr_scratch]
    test rcx, rcx
    jz .Lsbr_close_done
    mov qword ptr [rip + sbr_scratch], 0
    call mem_free
.Lsbr_close_done:
    add rsp, 32
    pop rbx
    ret
ENDFN sbr_close

# RCX=element: initial state (a stream start or seek). Memory is zeroed by
# the caller or here for a reset.
LOCALFN sbr_element_init
    push rdi
    mov rdi, rcx
    mov rdx, rcx
    xor eax, eax
    mov ecx, SE_SIZE / 8
    rep stosq
    mov rcx, rdx
    pop rdi
    jmp sbr_turnoff
ENDFN sbr_element_init

# RCX=element: pure upsampling until the next header (FFmpeg sbr_turnoff).
LOCALFN sbr_turnoff
    mov dword ptr [rcx + SE_START], 0
    mov dword ptr [rcx + SE_READY], 0
    mov dword ptr [rcx + SE_KX1], 32
    mov dword ptr [rcx + SE_M1], 0
    mov dword ptr [rcx + SE_CH + SC_E_A1], -1
    mov dword ptr [rcx + SE_CH + SC_SIZE + SC_E_A1], -1
    mov dword ptr [rcx + SE_SPECTRUM], 0
    ret
ENDFN sbr_turnoff

# Resets every element's state (stream start and seeks).
LOCALFN sbr_reset_all
    push rbx
    sub rsp, 32
    xor ebx, ebx
.Lsbr_reset_element:
    lea rax, [rip + sbr_elements]
    mov rcx, [rax + rbx*8]
    test rcx, rcx
    jz .Lsbr_reset_next
    call sbr_element_init
.Lsbr_reset_next:
    inc ebx
    cmp ebx, SBR_ELEMENTS
    jb .Lsbr_reset_element
    add rsp, 32
    pop rbx
    ret
ENDFN sbr_reset_all

# ECX=tree (0-9) -> EAX=signed value. Clobbers RCX, RDX, R8-R11.
LOCALFN sbr_tree
    push rbx
    push rsi
    sub rsp, 40
    lea rax, [rip + sbr_huff_trees]
    movzx esi, word ptr [rax + rcx*2]     # first node
    xor ebx, ebx                          # node
.Lsbr_tree_bit:
    mov ecx, 1
    call aac_get
    lea ecx, [rsi + rbx]
    lea rdx, [rip + sbr_huff_nodes]
    lea rdx, [rdx + rcx*2]
    movsx ebx, byte ptr [rdx + rax]
    test ebx, ebx
    jns .Lsbr_tree_bit
    lea eax, [rbx + 64]
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN sbr_tree

# XMM0=x > 0 -> XMM0=log2(x), about 1e-15 relative.
LOCALFN sbr_log2
    movq rax, xmm0
    mov rcx, rax
    shr rcx, 52
    and ecx, 0x7ff
    sub ecx, 1023                         # exponent
    mov rdx, 0x000fffffffffffff
    and rax, rdx
    mov rdx, 0x3ff0000000000000
    or rax, rdx
    movq xmm0, rax                        # mantissa in [1, 2)
    movsd xmm1, xmm0
    subsd xmm0, [rip + sbr_one]
    addsd xmm1, [rip + sbr_one]
    divsd xmm0, xmm1                      # t = (m - 1)/(m + 1)
    movsd xmm1, xmm0
    mulsd xmm1, xmm1                      # t^2
    movsd xmm2, xmm0                      # term
    movsd xmm3, xmm0                      # sum
    mov edx, 3
.Lsbr_log2_term:
    mulsd xmm2, xmm1
    cvtsi2sd xmm4, edx
    movsd xmm5, xmm2
    divsd xmm5, xmm4
    addsd xmm3, xmm5
    add edx, 2
    cmp edx, 41
    jb .Lsbr_log2_term
    addsd xmm3, xmm3                      # ln(m) = 2 atanh(t)
    mulsd xmm3, [rip + sbr_log2e]
    cvtsi2sd xmm0, ecx
    addsd xmm0, xmm3
    ret
ENDFN sbr_log2

# XMM0=x -> XMM0=2^x (|x| < 1000), about 1e-15 relative.
LOCALFN sbr_exp2
    cvtsd2si rax, xmm0                    # nearest integer
    cvtsi2sd xmm1, rax
    subsd xmm0, xmm1                      # |f| <= 1/2
    mulsd xmm0, [rip + sbr_ln2]
    movsd xmm1, [rip + sbr_one]           # sum
    movsd xmm2, [rip + sbr_one]           # term
    mov edx, 1
.Lsbr_exp2_term:
    mulsd xmm2, xmm0
    cvtsi2sd xmm3, edx
    divsd xmm2, xmm3
    addsd xmm1, xmm2
    inc edx
    cmp edx, 24
    jb .Lsbr_exp2_term
    add rax, 1023
    shl rax, 52
    movq xmm0, rax
    mulsd xmm0, xmm1
    ret
ENDFN sbr_exp2

# NINT(start * (stop/start)^(k/count)) for EDX=k: ECX=start, R8D=stop,
# R9D=count -> EAX. Preserves RCX, R8, R9.
LOCALFN sbr_band_border
    push rcx
    push r8
    push r9
    sub rsp, 40
    mov [rsp + 32], ecx
    cvtsi2sd xmm0, r8d
    cvtsi2sd xmm1, ecx
    divsd xmm0, xmm1
    mov [rsp + 36], edx
    call sbr_log2
    cvtsi2sd xmm1, dword ptr [rsp + 36]
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, dword ptr [rsp + 40]   # count (saved R9)
    divsd xmm0, xmm1
    call sbr_exp2
    cvtsi2sd xmm1, dword ptr [rsp + 32]
    mulsd xmm0, xmm1
    addsd xmm0, [rip + sbr_half]
    cvttsd2si eax, xmm0                   # positive: truncation is floor
    add rsp, 40
    pop r9
    pop r8
    pop rcx
    ret
ENDFN sbr_band_border

# Band widths between ECX=start and EDX=stop in R8D=count logarithmic steps
# into dwords at R9 (ISO vDk). Preserves nothing but RBX, RSI, RDI, R12+.
LOCALFN sbr_make_bands
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, ecx                         # start
    mov r13d, edx                         # stop
    mov rsi, r9
    mov ebx, ecx                          # previous border
    mov edi, 1                            # k
.Lsbr_bands_step:
    cmp edi, r8d
    jae .Lsbr_bands_last
    mov ecx, r12d
    mov edx, edi
    mov r9d, r8d
    mov r8d, r13d
    call sbr_band_border
    mov r8d, r9d
    mov edx, eax
    sub edx, ebx
    mov [rsi + rdi*4 - 4], edx
    mov ebx, eax
    inc edi
    jmp .Lsbr_bands_step
.Lsbr_bands_last:
    mov eax, r13d
    sub eax, ebx
    mov [rsi + rdi*4 - 4], eax
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_make_bands

# Sorts ECX dwords at RDX in ascending order (insertion sort).
LOCALFN sbr_sort
    mov r8d, 1
.Lsbr_sort_next:
    cmp r8d, ecx
    jae .Lsbr_sort_done
    mov eax, [rdx + r8*4]
    mov r9d, r8d
.Lsbr_sort_shift:
    test r9d, r9d
    jz .Lsbr_sort_place
    cmp [rdx + r9*4 - 4], eax
    jle .Lsbr_sort_place
    mov r10d, [rdx + r9*4 - 4]
    mov [rdx + r9*4], r10d
    dec r9d
    jmp .Lsbr_sort_shift
.Lsbr_sort_place:
    mov [rdx + r9*4], eax
    inc r8d
    jmp .Lsbr_sort_next
.Lsbr_sort_done:
    ret
ENDFN sbr_sort

# XMM0 -> EAX=NINT(XMM0) = floor(x + 1/2).
LOCALFN sbr_nint
    addsd xmm0, [rip + sbr_half]
    cvttsd2si eax, xmm0
    cvtsi2sd xmm1, eax
    ucomisd xmm1, xmm0
    jbe .Lsbr_nint_done
    dec eax                               # negative values truncate upward
.Lsbr_nint_done:
    ret
ENDFN sbr_nint

# Master and derived frequency band tables for element RCX at the SBR output
# rate (sample_rate) -> EAX=1, 0 when the header gives invalid tables.
# Locals: 32 rate, 36 k0, 40 k2, 44 k1, 48 num0, 52 num1, 56 max vk0,
# 64.. 64 dwords vk0, 320.. 64 dwords vk1.
LOCALFN sbr_frequency_tables
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 592
    mov r15, rcx
    mov dword ptr [r15 + SE_TABLES], 0
    mov eax, [rip + sample_rate]
    mov [rsp + 32], eax
    lea rcx, [rip + sbr_rate_list]
    xor edx, edx
.Lsbr_ft_rate:
    cmp edx, 9
    jae .Lsbr_ft_bad
    cmp [rcx + rdx*4], eax
    je .Lsbr_ft_rate_found
    inc edx
    jmp .Lsbr_ft_rate
.Lsbr_ft_rate_found:
    lea rcx, [rip + sbr_rate_rows]
    movzx r12d, byte ptr [rcx + rdx]      # offset row
    mov ebx, 3000
    cmp eax, 32000
    jb .Lsbr_ft_temp
    mov ebx, 4000
    cmp eax, 64000
    jb .Lsbr_ft_temp
    mov ebx, 5000
.Lsbr_ft_temp:
    mov ecx, eax                          # rate
    mov eax, ebx
    shl eax, 7
    mov edx, ecx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ecx
    mov r13d, eax                         # start_min
    mov eax, ebx
    shl eax, 8
    mov edx, ecx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ecx
    mov r14d, eax                         # stop_min
    mov eax, r12d
    shl eax, 4
    add eax, [r15 + SE_START_FREQ]
    lea rcx, [rip + sbr_start_offsets]
    movsx eax, byte ptr [rcx + rax]
    add eax, r13d
    mov [rsp + 36], eax                   # k0
    mov [r15 + SE_K0], eax
    # Stop frequency.
    mov eax, [r15 + SE_STOP_FREQ]
    cmp eax, 14
    jb .Lsbr_ft_stop_table
    mov ecx, [rsp + 36]
    lea edx, [rcx + rcx]
    je .Lsbr_ft_stop_ready
    add edx, ecx
    jmp .Lsbr_ft_stop_ready
.Lsbr_ft_stop_table:
    mov ecx, r14d
    mov edx, 64
    mov r8d, 13
    lea r9, [rsp + 64]
    call sbr_make_bands
    mov ecx, 13
    lea rdx, [rsp + 64]
    call sbr_sort
    mov edx, r14d
    xor ecx, ecx
.Lsbr_ft_stop_sum:
    cmp ecx, [r15 + SE_STOP_FREQ]
    jae .Lsbr_ft_stop_ready
    add edx, [rsp + 64 + rcx*4]
    inc ecx
    jmp .Lsbr_ft_stop_sum
.Lsbr_ft_stop_ready:
    cmp edx, 64
    jbe .Lsbr_ft_k2
    mov edx, 64
.Lsbr_ft_k2:
    mov [rsp + 40], edx                   # k2
    mov [r15 + SE_K2], edx
    mov eax, edx
    sub eax, [rsp + 36]
    mov ecx, 48
    cmp dword ptr [rsp + 32], 32000
    jbe .Lsbr_ft_maximum
    mov ecx, 35
    cmp dword ptr [rsp + 32], 44100
    je .Lsbr_ft_maximum
    mov ecx, 32
.Lsbr_ft_maximum:
    cmp eax, ecx                          # unsigned: k2 below k0 fails too
    ja .Lsbr_ft_bad
    cmp dword ptr [r15 + SE_FREQ_SCALE], 0
    jne .Lsbr_ft_scaled
    # Linear: n_master bands of dk.
    mov ecx, [r15 + SE_ALTER]
    inc ecx                               # dk
    mov eax, [rsp + 40]
    sub eax, [rsp + 36]
    mov edx, ecx
    and edx, 2
    add eax, edx
    sar eax, cl
    add eax, eax                          # n_master
    test eax, eax
    jle .Lsbr_ft_bad
    cmp [r15 + SE_XOVER], eax
    jae .Lsbr_ft_bad
    mov [r15 + SE_N_MASTER], eax
    xor edx, edx
.Lsbr_ft_linear_fill:
    mov [rsp + 64 + rdx*4], ecx
    inc edx
    cmp edx, eax
    jb .Lsbr_ft_linear_fill
    mov edx, [rsp + 40]
    sub edx, [rsp + 36]
    imul ecx, eax
    sub edx, ecx                          # k2 - k0 - n_master*dk
    jz .Lsbr_ft_cumulative_one
    jg .Lsbr_ft_linear_more
    dec dword ptr [rsp + 64]
    cmp edx, -1
    jge .Lsbr_ft_cumulative_one
    dec dword ptr [rsp + 68]
    jmp .Lsbr_ft_cumulative_one
.Lsbr_ft_linear_more:
    inc dword ptr [rsp + 64 + rax*4 - 4]
.Lsbr_ft_cumulative_one:
    mov edx, [rsp + 36]
    mov [r15 + SE_F_MASTER], dl
    xor ecx, ecx
.Lsbr_ft_linear_sum:
    add edx, [rsp + 64 + rcx*4]
    mov [r15 + SE_F_MASTER + rcx + 1], dl
    inc ecx
    cmp ecx, eax
    jb .Lsbr_ft_linear_sum
    jmp .Lsbr_ft_derived
.Lsbr_ft_scaled:
    mov r12d, 7
    sub r12d, [r15 + SE_FREQ_SCALE]       # bands per half octave
    mov eax, [rsp + 40]
    imul eax, eax, 49
    mov ecx, [rsp + 36]
    imul ecx, ecx, 110
    xor r13d, r13d                        # two regions
    mov edx, [rsp + 40]
    cmp eax, ecx
    jle .Lsbr_ft_k1
    mov r13d, 1
    mov edx, [rsp + 36]
    add edx, edx
.Lsbr_ft_k1:
    mov [rsp + 44], edx                   # k1
    cvtsi2sd xmm0, edx
    cvtsi2sd xmm1, dword ptr [rsp + 36]
    divsd xmm0, xmm1
    call sbr_log2
    cvtsi2sd xmm1, r12d
    mulsd xmm0, xmm1
    call sbr_nint
    add eax, eax                          # num0
    test eax, eax
    jle .Lsbr_ft_bad
    cmp eax, 48
    ja .Lsbr_ft_bad
    mov [rsp + 48], eax
    mov ecx, [rsp + 36]
    mov edx, [rsp + 44]
    mov r8d, eax
    lea r9, [rsp + 64]
    call sbr_make_bands
    mov ecx, [rsp + 48]
    lea rdx, [rsp + 64]
    call sbr_sort
    mov eax, [rsp + 48]
    mov eax, [rsp + 64 + rax*4 - 4]
    mov [rsp + 56], eax                   # max vDk0
    cmp dword ptr [rsp + 64], 0
    jle .Lsbr_ft_bad
    mov edx, [rsp + 36]
    mov [r15 + SE_F_MASTER], dl
    xor ecx, ecx
.Lsbr_ft_region0:
    add edx, [rsp + 64 + rcx*4]
    mov [r15 + SE_F_MASTER + rcx + 1], dl
    inc ecx
    cmp ecx, [rsp + 48]
    jb .Lsbr_ft_region0
    mov eax, [rsp + 48]
    test r13d, r13d
    jz .Lsbr_ft_master_count
    # Second region, warped by 1.3 with bs_alter_scale.
    cvtsi2sd xmm0, dword ptr [rsp + 40]
    cvtsi2sd xmm1, dword ptr [rsp + 44]
    divsd xmm0, xmm1
    call sbr_log2
    cvtsi2sd xmm1, r12d
    mulsd xmm0, xmm1
    cmp dword ptr [r15 + SE_ALTER], 0
    je .Lsbr_ft_unwarped
    divsd xmm0, [rip + sbr_alter_warp]
.Lsbr_ft_unwarped:
    call sbr_nint
    add eax, eax                          # num1
    jz .Lsbr_ft_one_region                # FFmpeg: an empty second region
    js .Lsbr_ft_bad
    cmp eax, 48
    ja .Lsbr_ft_bad
    mov [rsp + 52], eax
    mov ecx, [rsp + 44]
    mov edx, [rsp + 40]
    mov r8d, eax
    lea r9, [rsp + 320]
    call sbr_make_bands
    mov ecx, [rsp + 52]                   # minimum of vDk1
    mov eax, [rsp + 320]
    xor edx, edx
.Lsbr_ft_min1:
    cmp [rsp + 320 + rdx*4], eax
    cmovl eax, [rsp + 320 + rdx*4]
    inc edx
    cmp edx, ecx
    jb .Lsbr_ft_min1
    cmp eax, [rsp + 56]
    jge .Lsbr_ft_sort1
    lea rdx, [rsp + 320]
    call sbr_sort
    mov ecx, [rsp + 52]
    mov eax, [rsp + 56]
    sub eax, [rsp + 320]                  # max vDk0 - vDk1[0]
    mov edx, [rsp + 320 + rcx*4 - 4]
    sub edx, [rsp + 320]
    sar edx, 1
    cmp eax, edx
    cmovg eax, edx                        # change
    add [rsp + 320], eax
    sub [rsp + 320 + rcx*4 - 4], eax
.Lsbr_ft_sort1:
    mov ecx, [rsp + 52]
    lea rdx, [rsp + 320]
    call sbr_sort
    cmp dword ptr [rsp + 320], 0
    jle .Lsbr_ft_bad
    mov eax, [rsp + 48]
    movzx edx, byte ptr [r15 + SE_F_MASTER + rax]
    xor ecx, ecx
.Lsbr_ft_region1:
    add edx, [rsp + 320 + rcx*4]
    lea r8d, [rax + rcx + 1]
    mov [r15 + SE_F_MASTER + r8], dl
    inc ecx
    cmp ecx, [rsp + 52]
    jb .Lsbr_ft_region1
    add eax, [rsp + 52]
    jmp .Lsbr_ft_master_count
.Lsbr_ft_one_region:
    mov eax, [rsp + 48]
.Lsbr_ft_master_count:
    cmp eax, 64
    ja .Lsbr_ft_bad
    cmp [r15 + SE_XOVER], eax
    jae .Lsbr_ft_bad
    mov [r15 + SE_N_MASTER], eax
.Lsbr_ft_derived:
    mov eax, [r15 + SE_N_MASTER]
    sub eax, [r15 + SE_XOVER]             # n_high
    mov [r15 + SE_N_HIGH], eax
    lea ecx, [rax + 1]
    shr ecx, 1
    mov [r15 + SE_N_LOW], ecx
    mov edx, [r15 + SE_XOVER]
    xor ecx, ecx
.Lsbr_ft_high:
    lea r8d, [rdx + rcx]
    movzx r9d, byte ptr [r15 + SE_F_MASTER + r8]
    mov [r15 + SE_F_HIGH + rcx], r9b
    inc ecx
    cmp ecx, eax
    jbe .Lsbr_ft_high
    movzx ecx, byte ptr [r15 + SE_F_HIGH]  # kx
    movzx edx, byte ptr [r15 + SE_F_HIGH + rax]
    sub edx, ecx                          # m
    lea r8d, [rcx + rdx]
    cmp r8d, 64
    ja .Lsbr_ft_bad
    cmp ecx, 32
    ja .Lsbr_ft_bad
    test edx, edx
    jle .Lsbr_ft_bad
    mov [r15 + SE_KX1], ecx
    mov [r15 + SE_M1], edx
    mov [r15 + SE_F_LOW], cl
    mov r8d, eax
    and r8d, 1                            # odd
    mov ecx, 1
.Lsbr_ft_low:
    cmp ecx, [r15 + SE_N_LOW]
    ja .Lsbr_ft_noise
    lea r9d, [rcx + rcx]
    sub r9d, r8d
    movzx r9d, byte ptr [r15 + SE_F_HIGH + r9]
    mov [r15 + SE_F_LOW + rcx], r9b
    inc ecx
    jmp .Lsbr_ft_low
.Lsbr_ft_noise:
    cvtsi2sd xmm0, dword ptr [r15 + SE_K2]
    cvtsi2sd xmm1, dword ptr [r15 + SE_KX1]
    divsd xmm0, xmm1
    call sbr_log2
    cvtsi2sd xmm1, dword ptr [r15 + SE_NOISE_BANDS]
    mulsd xmm0, xmm1
    call sbr_nint
    cmp eax, 1
    jge .Lsbr_ft_nq
    mov eax, 1
.Lsbr_ft_nq:
    cmp eax, 5
    ja .Lsbr_ft_bad
    mov [r15 + SE_N_Q], eax
    movzx ecx, byte ptr [r15 + SE_F_LOW]
    mov [r15 + SE_F_NOISE], cl
    xor esi, esi                          # temp
    mov edi, 1                            # k
.Lsbr_ft_noise_band:
    cmp edi, [r15 + SE_N_Q]
    ja .Lsbr_ft_patches
    mov eax, [r15 + SE_N_LOW]
    sub eax, esi
    mov ecx, [r15 + SE_N_Q]
    inc ecx
    sub ecx, edi
    xor edx, edx
    div ecx
    add esi, eax
    movzx eax, byte ptr [r15 + SE_F_LOW + rsi]
    mov [r15 + SE_F_NOISE + rdi], al
    inc edi
    jmp .Lsbr_ft_noise_band
.Lsbr_ft_patches:
    mov rcx, r15
    call sbr_patches
    test eax, eax
    jz .Lsbr_ft_bad
    mov rcx, r15
    call sbr_limiter_table
    mov dword ptr [r15 + SE_TABLES], 1
    mov dword ptr [r15 + SE_CH + SC_INDEX_NOISE], 0
    mov dword ptr [r15 + SE_CH + SC_SIZE + SC_INDEX_NOISE], 0
    mov eax, 1
    jmp .Lsbr_ft_return
.Lsbr_ft_bad:
    xor eax, eax
.Lsbr_ft_return:
    add rsp, 592
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_frequency_tables

# Patch construction (ISO figure 4.46) for element RCX -> EAX=1, 0 when the
# tables admit no valid patches.
LOCALFN sbr_patches
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r15, rcx
    mov r8d, [r15 + SE_K0]
    mov r9d, [r15 + SE_KX1]
    mov r10d, r9d
    add r10d, [r15 + SE_M1]               # kx + M: the last border
    mov r11d, [r15 + SE_N_MASTER]
    mov esi, r8d                          # msb
    mov edi, r9d                          # usb
    mov ecx, [rip + sample_rate]
    mov eax, 1000 << 11
    mov edx, ecx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ecx                               # goal subband
    mov ebx, r11d                         # k
    cmp eax, r10d
    jae .Lsbr_patch_start
    xor ebx, ebx
.Lsbr_patch_goal:
    movzx edx, byte ptr [r15 + SE_F_MASTER + rbx]
    cmp edx, eax
    jae .Lsbr_patch_start
    inc ebx
    jmp .Lsbr_patch_goal
.Lsbr_patch_start:
    mov r12d, -1                          # previous k
    mov r13d, -1                          # previous msb
    xor r14d, r14d                        # patches
.Lsbr_patch_loop:
    cmp ebx, r12d
    jne .Lsbr_patch_new
    cmp esi, r13d
    je .Lsbr_patch_bad
.Lsbr_patch_new:
    mov r12d, ebx
    mov r13d, esi
    mov ecx, ebx
.Lsbr_patch_find:
    movzx eax, byte ptr [r15 + SE_F_MASTER + rcx]   # sb
    lea edx, [rax + r8]
    and edx, 1                            # odd
    lea ebp, [r8 + rsi - 1]
    sub ebp, edx
    cmp eax, ebp
    jle .Lsbr_patch_found
    dec ecx
    jns .Lsbr_patch_find
    jmp .Lsbr_patch_bad
.Lsbr_patch_found:
    cmp r14d, 5
    ja .Lsbr_patch_bad
    mov ebp, eax
    sub ebp, edi                          # sb - usb
    jle .Lsbr_patch_empty
    mov ecx, r8d
    sub ecx, edx
    sub ecx, ebp                          # start subband
    js .Lsbr_patch_bad
    mov [r15 + SE_PATCH_SIZE + r14], bpl
    mov [r15 + SE_PATCH_START + r14], cl
    inc r14d
    mov edi, eax
    mov esi, eax
    jmp .Lsbr_patch_next
.Lsbr_patch_empty:
    mov esi, r9d
.Lsbr_patch_next:
    movzx ecx, byte ptr [r15 + SE_F_MASTER + rbx]
    sub ecx, eax
    cmp ecx, 3
    jge .Lsbr_patch_continue
    mov ebx, r11d
.Lsbr_patch_continue:
    cmp eax, r10d
    jne .Lsbr_patch_loop
    cmp r14d, 1                           # a short last patch is dropped
    jbe .Lsbr_patch_done
    movzx eax, byte ptr [r15 + SE_PATCH_SIZE + r14 - 1]
    cmp eax, 3
    jae .Lsbr_patch_done
    dec r14d
.Lsbr_patch_done:
    mov [r15 + SE_PATCHES], r14d
    mov eax, 1
    jmp .Lsbr_patch_return
.Lsbr_patch_bad:
    xor eax, eax
.Lsbr_patch_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN sbr_patches

# ECX=subband, RDX=patch borders (dwords), R8D=patches -> EAX=1 when ECX is
# one of the R8D+1 borders. Clobbers R9.
LOCALFN sbr_is_border
    xor r9d, r9d
.Lsbr_border_next:
    cmp [rdx + r9*4], ecx
    je .Lsbr_border_yes
    inc r9d
    cmp r9d, r8d
    jbe .Lsbr_border_next
    xor eax, eax
    ret
.Lsbr_border_yes:
    mov eax, 1
    ret
ENDFN sbr_is_border

# Limiter band table (ISO 4.6.18.3.2.3) for element RCX, reduced in place as
# the reference loop walks it. Locals: 32.. 32 dwords table, 160.. 8 dwords
# patch borders.
LOCALFN sbr_limiter_table
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 200
    mov rbx, rcx
    mov eax, [rbx + SE_N_LOW]
    cmp dword ptr [rbx + SE_LIM_BANDS], 0
    jne .Lsbr_lim_bands
    movzx ecx, byte ptr [rbx + SE_F_LOW]
    mov [rbx + SE_F_LIM], cl
    movzx ecx, byte ptr [rbx + SE_F_LOW + rax]
    mov [rbx + SE_F_LIM + 1], cl
    mov dword ptr [rbx + SE_N_LIM], 1
    jmp .Lsbr_lim_return
.Lsbr_lim_bands:
    mov ecx, [rbx + SE_KX1]
    mov [rsp + 160], ecx
    xor edx, edx
.Lsbr_lim_border:
    cmp edx, [rbx + SE_PATCHES]
    jae .Lsbr_lim_low_start
    movzx r8d, byte ptr [rbx + SE_PATCH_SIZE + rdx]
    add ecx, r8d
    mov [rsp + 164 + rdx*4], ecx
    inc edx
    jmp .Lsbr_lim_border
.Lsbr_lim_low_start:
    xor edx, edx
.Lsbr_lim_low:
    movzx ecx, byte ptr [rbx + SE_F_LOW + rdx]
    mov [rsp + 32 + rdx*4], ecx
    inc edx
    cmp edx, eax
    jbe .Lsbr_lim_low
    mov ecx, 1                            # inner patch borders
.Lsbr_lim_inner:
    cmp ecx, [rbx + SE_PATCHES]
    jae .Lsbr_lim_sort
    mov r8d, [rsp + 160 + rcx*4]
    mov [rsp + 32 + rdx*4], r8d
    inc edx
    inc ecx
    jmp .Lsbr_lim_inner
.Lsbr_lim_sort:
    mov r12d, edx
    mov ecx, edx
    lea rdx, [rsp + 32]
    call sbr_sort
    dec r12d                              # n_lim
    xor esi, esi                          # out
    mov edi, 1                            # in
    mov eax, [rbx + SE_LIM_BANDS]
    lea rcx, [rip + sbr_limiter_warp]
    movsd xmm2, [rcx + rax*8 - 8]
.Lsbr_lim_reduce:
    cmp esi, r12d
    jae .Lsbr_lim_store
    mov eax, [rsp + 32 + rdi*4]
    cvtsi2sd xmm0, eax
    cvtsi2sd xmm1, dword ptr [rsp + 32 + rsi*4]
    mulsd xmm1, xmm2
    ucomisd xmm0, xmm1
    jae .Lsbr_lim_keep
    cmp eax, [rsp + 32 + rsi*4]
    je .Lsbr_lim_drop
    mov ecx, eax
    lea rdx, [rsp + 160]
    mov r8d, [rbx + SE_PATCHES]
    call sbr_is_border
    test eax, eax
    jz .Lsbr_lim_drop
    mov ecx, [rsp + 32 + rsi*4]
    lea rdx, [rsp + 160]
    mov r8d, [rbx + SE_PATCHES]
    call sbr_is_border
    test eax, eax
    jnz .Lsbr_lim_keep
    mov eax, [rsp + 32 + rdi*4]           # replace a border-free entry
    mov [rsp + 32 + rsi*4], eax
    inc edi
    dec r12d
    jmp .Lsbr_lim_reduce
.Lsbr_lim_drop:
    inc edi
    dec r12d
    jmp .Lsbr_lim_reduce
.Lsbr_lim_keep:
    mov eax, [rsp + 32 + rdi*4]
    inc esi
    mov [rsp + 32 + rsi*4], eax
    inc edi
    jmp .Lsbr_lim_reduce
.Lsbr_lim_store:
    mov [rbx + SE_N_LIM], r12d
    xor ecx, ecx
.Lsbr_lim_copy:
    mov eax, [rsp + 32 + rcx*4]
    mov [rbx + SE_F_LIM + rcx], al
    inc ecx
    cmp ecx, r12d
    jbe .Lsbr_lim_copy
.Lsbr_lim_return:
    add rsp, 200
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_limiter_table

# SBR header into element RCX (ISO 4.4.2.8 sbr_header).
# Locals: 32.. six dwords of new spectrum parameters.
LOCALFN sbr_header
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rbx, rcx
    mov dword ptr [rbx + SE_START], 1
    mov dword ptr [rbx + SE_READY], 0
    mov ecx, 1
    call aac_get
    mov [rbx + SE_AMP_RES], eax
    mov ecx, 4
    call aac_get
    mov [rsp + 32], eax                   # bs_start_freq
    mov ecx, 4
    call aac_get
    mov [rsp + 36], eax                   # bs_stop_freq
    mov ecx, 3
    call aac_get
    mov [rsp + 40], eax                   # bs_xover_band
    mov ecx, 2
    call aac_get                          # bs_reserved
    mov ecx, 1
    call aac_get
    mov esi, eax                          # bs_header_extra_1
    mov ecx, 1
    call aac_get
    mov edi, eax                          # bs_header_extra_2
    mov dword ptr [rsp + 44], 2           # bs_freq_scale
    mov dword ptr [rsp + 48], 1           # bs_alter_scale
    mov dword ptr [rsp + 52], 2           # bs_noise_bands
    test esi, esi
    jz .Lsbr_header_compare
    mov ecx, 2
    call aac_get
    mov [rsp + 44], eax
    mov ecx, 1
    call aac_get
    mov [rsp + 48], eax
    mov ecx, 2
    call aac_get
    mov [rsp + 52], eax
.Lsbr_header_compare:
    mov r12d, 1                           # spectrum changed
    cmp dword ptr [rbx + SE_SPECTRUM], 0
    je .Lsbr_header_store
    xor ecx, ecx
.Lsbr_header_same:
    mov eax, [rsp + 32 + rcx*4]
    cmp eax, [rbx + SE_START_FREQ + rcx*4]
    jne .Lsbr_header_store
    inc ecx
    cmp ecx, 6
    jb .Lsbr_header_same
    xor r12d, r12d
.Lsbr_header_store:
    xor ecx, ecx
.Lsbr_header_copy:
    mov eax, [rsp + 32 + rcx*4]
    mov [rbx + SE_START_FREQ + rcx*4], eax
    inc ecx
    cmp ecx, 6
    jb .Lsbr_header_copy
    mov dword ptr [rbx + SE_SPECTRUM], 1
    test r12d, r12d
    jz .Lsbr_header_limiter
    mov dword ptr [rbx + SE_RESET], 1
.Lsbr_header_limiter:
    mov esi, [rbx + SE_LIM_BANDS]         # previous limiter bands
    mov dword ptr [rbx + SE_LIM_BANDS], 2
    mov dword ptr [rbx + SE_LIM_GAINS], 2
    mov dword ptr [rbx + SE_INTERPOL], 1
    mov dword ptr [rbx + SE_SMOOTHING], 1
    test edi, edi
    jz .Lsbr_header_rebuild
    mov ecx, 2
    call aac_get
    mov [rbx + SE_LIM_BANDS], eax
    mov ecx, 2
    call aac_get
    mov [rbx + SE_LIM_GAINS], eax
    mov ecx, 1
    call aac_get
    mov [rbx + SE_INTERPOL], eax
    mov ecx, 1
    call aac_get
    mov [rbx + SE_SMOOTHING], eax
.Lsbr_header_rebuild:
    cmp [rbx + SE_LIM_BANDS], esi
    je .Lsbr_header_done
    cmp dword ptr [rbx + SE_RESET], 0
    jne .Lsbr_header_done
    cmp dword ptr [rbx + SE_TABLES], 0
    je .Lsbr_header_done
    mov rcx, rbx
    call sbr_limiter_table
.Lsbr_header_done:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_header

# Time/frequency grid of channel RDX in element RCX (ISO sbr_grid) -> EAX=1,
# 0 for an invalid grid. Locals: 32 relative borders still to read.
LOCALFN sbr_grid
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov r14d, [rsi + SC_NUM_ENV]          # previous envelopes
    movzx eax, byte ptr [rsi + SC_FREQ_RES + r14]
    mov [rsi + SC_FREQ_RES], al
    mov eax, [rbx + SE_AMP_RES]
    mov [rsi + SC_AMP_RES], eax
    movzx eax, byte ptr [rsi + SC_T_ENV + r14]
    mov [rsi + SC_T_ENV_OLD], eax
    xor r13d, r13d                        # bs_pointer
    mov ecx, 2
    call aac_get
    mov r12d, eax                         # frame class
    cmp eax, 1
    je .Lsbr_grid_fixvar
    cmp eax, 2
    je .Lsbr_grid_varfix
    cmp eax, 3
    je .Lsbr_grid_varvar
    # FIXFIX: 1, 2 or 4 equal envelopes.
    mov ecx, 2
    call aac_get
    cmp eax, 2
    ja .Lsbr_grid_bad
    mov edi, 1
    mov ecx, eax
    shl edi, cl
    mov [rsi + SC_NUM_ENV], edi
    cmp edi, 1
    jne .Lsbr_grid_fixfix_borders
    mov dword ptr [rsi + SC_AMP_RES], 0
.Lsbr_grid_fixfix_borders:
    mov byte ptr [rsi + SC_T_ENV], 0
    mov byte ptr [rsi + SC_T_ENV + rdi], 16
    mov eax, edi
    shr eax, 1
    add eax, 16
    xor edx, edx
    div edi
    mov ecx, 1
    mov edx, eax
.Lsbr_grid_fixfix_step:
    cmp ecx, edi
    jae .Lsbr_grid_fixfix_res
    mov [rsi + SC_T_ENV + rcx], dl
    add edx, eax
    inc ecx
    jmp .Lsbr_grid_fixfix_step
.Lsbr_grid_fixfix_res:
    mov ecx, 1
    call aac_get
    mov ecx, 1
.Lsbr_grid_fixfix_fill:
    mov [rsi + SC_FREQ_RES + rcx], al
    inc ecx
    cmp ecx, edi
    jbe .Lsbr_grid_fixfix_fill
    jmp .Lsbr_grid_common
.Lsbr_grid_fixvar:
    mov ecx, 2
    call aac_get
    add eax, 16
    mov r15d, eax                         # trailing border
    mov ecx, 2
    call aac_get
    mov [rsp + 32], eax                   # num_rel_trail
    lea edi, [rax + 1]
    mov [rsi + SC_NUM_ENV], edi
    mov byte ptr [rsi + SC_T_ENV], 0
    mov [rsi + SC_T_ENV + rdi], r15b
    call .Lsbr_grid_trails
    call .Lsbr_grid_pointer
    mov r15d, edi                         # freq_res[num_env - i]
.Lsbr_grid_fixvar_res:
    mov ecx, 1
    call aac_get
    mov [rsi + SC_FREQ_RES + r15], al
    dec r15d
    jnz .Lsbr_grid_fixvar_res
    jmp .Lsbr_grid_common
.Lsbr_grid_varfix:
    mov ecx, 2
    call aac_get
    mov [rsi + SC_T_ENV], al
    mov ecx, 2
    call aac_get
    mov [rsp + 32], eax                   # num_rel_lead
    lea edi, [rax + 1]
    mov [rsi + SC_NUM_ENV], edi
    mov byte ptr [rsi + SC_T_ENV + rdi], 16
    call .Lsbr_grid_leads
    call .Lsbr_grid_pointer
    call .Lsbr_grid_rising_res
    jmp .Lsbr_grid_common
.Lsbr_grid_varvar:
    mov ecx, 2
    call aac_get
    mov [rsi + SC_T_ENV], al
    mov ecx, 2
    call aac_get
    add eax, 16
    mov r15d, eax
    mov ecx, 2
    call aac_get
    mov [rsp + 36], eax                   # num_rel_lead
    mov ecx, 2
    call aac_get
    mov [rsp + 40], eax                   # num_rel_trail
    mov edi, [rsp + 36]
    lea edi, [rdi + rax + 1]
    cmp edi, 5
    ja .Lsbr_grid_bad
    mov [rsi + SC_NUM_ENV], edi
    mov [rsi + SC_T_ENV + rdi], r15b
    mov eax, [rsp + 36]
    mov [rsp + 32], eax
    call .Lsbr_grid_leads
    mov eax, [rsp + 40]
    mov [rsp + 32], eax
    call .Lsbr_grid_trails
    call .Lsbr_grid_pointer
    call .Lsbr_grid_rising_res
.Lsbr_grid_common:
    mov [rsi + SC_CLASS], r12d
    lea eax, [rdi + 1]
    cmp r13d, eax
    ja .Lsbr_grid_bad
    mov ecx, 1
.Lsbr_grid_monotone:
    movzx eax, byte ptr [rsi + SC_T_ENV + rcx - 1]
    movzx edx, byte ptr [rsi + SC_T_ENV + rcx]
    cmp eax, edx
    jae .Lsbr_grid_bad
    inc ecx
    cmp ecx, edi
    jbe .Lsbr_grid_monotone
    mov eax, 1                            # noise floors
    cmp edi, 1
    je .Lsbr_grid_noise
    mov eax, 2
.Lsbr_grid_noise:
    mov [rsi + SC_NUM_NOISE], eax
    movzx ecx, byte ptr [rsi + SC_T_ENV]
    mov [rsi + SC_T_Q], cl
    movzx ecx, byte ptr [rsi + SC_T_ENV + rdi]
    mov [rsi + SC_T_Q + rax], cl
    cmp eax, 1
    je .Lsbr_grid_transient
    mov eax, edi                          # middle noise border
    shr eax, 1
    test r12d, r12d
    jz .Lsbr_grid_middle
    test r12d, 1
    jz .Lsbr_grid_middle_varfix
    lea ecx, [r13 - 1]
    mov edx, 1
    cmp ecx, edx
    cmovl ecx, edx
    mov eax, edi
    sub eax, ecx
    jmp .Lsbr_grid_middle
.Lsbr_grid_middle_varfix:
    mov eax, 1
    test r13d, r13d
    jz .Lsbr_grid_middle
    lea eax, [rdi - 1]
    cmp r13d, 1
    je .Lsbr_grid_middle
    lea eax, [r13 - 1]
.Lsbr_grid_middle:
    movzx ecx, byte ptr [rsi + SC_T_ENV + rax]
    mov [rsi + SC_T_Q + 1], cl
.Lsbr_grid_transient:
    xor eax, eax
    cmp [rsi + SC_E_A1], r14d
    setne al
    neg eax
    mov [rsi + SC_E_A0], eax
    mov dword ptr [rsi + SC_E_A1], -1
    test r13d, r13d
    jz .Lsbr_grid_good
    test r12d, 1
    jz .Lsbr_grid_transient_varfix
    lea eax, [rdi + 1]
    sub eax, r13d
    mov [rsi + SC_E_A1], eax
    jmp .Lsbr_grid_good
.Lsbr_grid_transient_varfix:
    cmp r12d, 2
    jne .Lsbr_grid_good
    cmp r13d, 1
    jbe .Lsbr_grid_good
    lea eax, [r13 - 1]
    mov [rsi + SC_E_A1], eax
.Lsbr_grid_good:
    mov eax, 1
    jmp .Lsbr_grid_return
.Lsbr_grid_bad:
    xor eax, eax
.Lsbr_grid_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# Local subroutines (the caller's frame is 8 bytes deeper).
.Lsbr_grid_leads:                         # t_env[i+1] = t_env[i] + 2 bs_rel_bord + 2
    xor r15d, r15d
.Lsbr_grid_lead:
    cmp r15d, [rsp + 40]
    jae .Lsbr_grid_sub_done
    mov ecx, 2
    call aac_get
    movzx ecx, byte ptr [rsi + SC_T_ENV + r15]
    lea eax, [rcx + rax*2 + 2]
    mov [rsi + SC_T_ENV + r15 + 1], al
    inc r15d
    jmp .Lsbr_grid_lead
.Lsbr_grid_trails:                        # t_env[n-1-i] = t_env[n-i] - 2 bs_rel_bord - 2
    xor r15d, r15d
.Lsbr_grid_trail:
    cmp r15d, [rsp + 40]
    jae .Lsbr_grid_sub_done
    mov ecx, 2
    call aac_get
    mov ecx, edi
    sub ecx, r15d
    movzx edx, byte ptr [rsi + SC_T_ENV + rcx]
    add eax, eax
    sub edx, eax
    sub edx, 2
    mov [rsi + SC_T_ENV + rcx - 1], dl
    inc r15d
    jmp .Lsbr_grid_trail
.Lsbr_grid_pointer:
    lea rax, [rip + sbr_ceil_log2]
    movzx ecx, byte ptr [rax + rdi]
    call aac_get
    mov r13d, eax
.Lsbr_grid_sub_done:
    ret
.Lsbr_grid_rising_res:
    mov r15d, 1
.Lsbr_grid_rising:
    mov ecx, 1
    call aac_get
    mov [rsi + SC_FREQ_RES + r15], al
    inc r15d
    cmp r15d, edi
    jbe .Lsbr_grid_rising
    ret
ENDFN sbr_grid

# Coupled pair: channel RCX takes the grid of channel RDX (FFmpeg
# copy_sbr_grid); the previous-frame values stay its own.
LOCALFN sbr_copy_grid
    mov r8d, [rcx + SC_NUM_ENV]
    movzx eax, byte ptr [rcx + SC_FREQ_RES + r8]
    mov [rcx + SC_FREQ_RES], al
    movzx eax, byte ptr [rcx + SC_T_ENV + r8]
    mov [rcx + SC_T_ENV_OLD], eax
    xor eax, eax
    cmp [rcx + SC_E_A1], r8d
    setne al
    neg eax
    mov [rcx + SC_E_A0], eax
    mov r8d, 1
.Lsbr_copy_res:
    movzx eax, byte ptr [rdx + SC_FREQ_RES + r8]
    mov [rcx + SC_FREQ_RES + r8], al
    inc r8d
    cmp r8d, 8
    jb .Lsbr_copy_res
    mov rax, [rdx + SC_T_ENV]
    mov [rcx + SC_T_ENV], rax
    mov eax, [rdx + SC_T_Q]
    mov [rcx + SC_T_Q], eax
    mov eax, [rdx + SC_NUM_ENV]
    mov [rcx + SC_NUM_ENV], eax
    mov eax, [rdx + SC_AMP_RES]
    mov [rcx + SC_AMP_RES], eax
    mov eax, [rdx + SC_NUM_NOISE]
    mov [rcx + SC_NUM_NOISE], eax
    mov eax, [rdx + SC_CLASS]
    mov [rcx + SC_CLASS], eax
    mov eax, [rdx + SC_E_A1]
    mov [rcx + SC_E_A1], eax
    ret
ENDFN sbr_copy_grid

# Delta coding directions of channel RCX.
LOCALFN sbr_dtdf
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    xor esi, esi
.Lsbr_dtdf_env:
    cmp esi, [rbx + SC_NUM_ENV]
    jae .Lsbr_dtdf_noise_start
    mov ecx, 1
    call aac_get
    mov [rbx + SC_DF_ENV + rsi], al
    inc esi
    jmp .Lsbr_dtdf_env
.Lsbr_dtdf_noise_start:
    xor esi, esi
.Lsbr_dtdf_noise:
    cmp esi, [rbx + SC_NUM_NOISE]
    jae .Lsbr_dtdf_done
    mov ecx, 1
    call aac_get
    mov [rbx + SC_DF_NOISE + rsi], al
    inc esi
    jmp .Lsbr_dtdf_noise
.Lsbr_dtdf_done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN sbr_dtdf

# Inverse filtering modes of channel RDX (element RCX); the previous modes
# move to the second row.
LOCALFN sbr_invf
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rdi, rdx
    mov rax, [rdi + SC_INVF]
    mov [rdi + SC_INVF + 8], rax
    xor esi, esi
.Lsbr_invf_mode:
    cmp esi, [rbx + SE_N_Q]
    jae .Lsbr_invf_done
    mov ecx, 2
    call aac_get
    mov [rdi + SC_INVF + rsi], al
    inc esi
    jmp .Lsbr_invf_mode
.Lsbr_invf_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_invf

# Envelope scalefactors of channel RDX in element RCX; R8D=1 for the balance
# data of a coupled pair's second channel -> EAX=1, 0 out of range.
# Locals: 32 odd, 36 envelope, 40 band, 44 bands, 48 time tree, 52
# frequency tree, 56 start bits.
LOCALFN sbr_envelope
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 72
    mov rbx, rcx
    mov rsi, rdx
    lea r12d, [r8 + 1]                    # delta
    mov eax, [rbx + SE_N_HIGH]
    and eax, 1
    mov [rsp + 32], eax
    cmp dword ptr [rsi + SC_AMP_RES], 0
    jne .Lsbr_env_amp3
    mov dword ptr [rsp + 48], 0           # 1.5 dB: ENV15_T, ENV15_F
    mov dword ptr [rsp + 52], 1
    mov dword ptr [rsp + 56], 7
    test r8d, r8d
    jz .Lsbr_env_start
    mov dword ptr [rsp + 48], 2           # BAL15_T, BAL15_F
    mov dword ptr [rsp + 52], 3
    mov dword ptr [rsp + 56], 6
    jmp .Lsbr_env_start
.Lsbr_env_amp3:
    mov dword ptr [rsp + 48], 4           # 3 dB: ENV30_T, ENV30_F
    mov dword ptr [rsp + 52], 5
    mov dword ptr [rsp + 56], 6
    test r8d, r8d
    jz .Lsbr_env_start
    mov dword ptr [rsp + 48], 6           # BAL30_T, BAL30_F
    mov dword ptr [rsp + 52], 7
    mov dword ptr [rsp + 56], 5
.Lsbr_env_start:
    mov dword ptr [rsp + 36], 0
.Lsbr_env_next:
    mov edi, [rsp + 36]                   # envelope i
    cmp edi, [rsi + SC_NUM_ENV]
    jae .Lsbr_env_finish
    movzx r13d, byte ptr [rsi + SC_FREQ_RES + rdi + 1]
    mov eax, [rbx + SE_N_LOW]
    test r13d, r13d
    jz .Lsbr_env_count
    mov eax, [rbx + SE_N_HIGH]
.Lsbr_env_count:
    mov [rsp + 44], eax
    imul r14d, edi, 48
    lea r14, [rsi + r14 + SC_ENV_Q]       # row i; row i+1 follows at +48
    mov dword ptr [rsp + 40], 0
    cmp byte ptr [rsi + SC_DF_ENV + rdi], 0
    je .Lsbr_env_frequency
.Lsbr_env_time:
    mov edx, [rsp + 40]                   # j
    cmp edx, [rsp + 44]
    jae .Lsbr_env_done
    movzx eax, byte ptr [rsi + SC_FREQ_RES + rdi]
    mov ecx, edx                          # same resolution: k = j
    cmp eax, r13d
    je .Lsbr_env_time_value
    test r13d, r13d
    jz .Lsbr_env_time_low
    add ecx, [rsp + 32]                   # high from low: (j + odd) >> 1
    shr ecx, 1
    jmp .Lsbr_env_time_value
.Lsbr_env_time_low:
    test ecx, ecx                         # low from high: 2j - odd
    jz .Lsbr_env_time_value
    add ecx, ecx
    sub ecx, [rsp + 32]
.Lsbr_env_time_value:
    movzx eax, byte ptr [r14 + rcx]
    mov [rsp + 60], eax
    mov ecx, [rsp + 48]
    call sbr_tree
    imul eax, r12d
    add eax, [rsp + 60]
    and eax, 255
    cmp eax, 127
    ja .Lsbr_env_bad
    mov edx, [rsp + 40]
    mov [r14 + rdx + 48], al
    inc dword ptr [rsp + 40]
    jmp .Lsbr_env_time
.Lsbr_env_frequency:
    mov ecx, [rsp + 56]
    call aac_get
    imul eax, r12d
    mov [r14 + 48], al
    mov dword ptr [rsp + 40], 1
.Lsbr_env_frequency_band:
    mov edx, [rsp + 40]
    cmp edx, [rsp + 44]
    jae .Lsbr_env_done
    movzx eax, byte ptr [r14 + rdx + 47]
    mov [rsp + 60], eax
    mov ecx, [rsp + 52]
    call sbr_tree
    imul eax, r12d
    add eax, [rsp + 60]
    and eax, 255
    cmp eax, 127
    ja .Lsbr_env_bad
    mov edx, [rsp + 40]
    mov [r14 + rdx + 48], al
    inc dword ptr [rsp + 40]
    jmp .Lsbr_env_frequency_band
.Lsbr_env_done:
    inc dword ptr [rsp + 36]
    jmp .Lsbr_env_next
.Lsbr_env_finish:
    imul eax, [rsi + SC_NUM_ENV], 48      # row 0 keeps the last envelope
    lea rdx, [rsi + rax + SC_ENV_Q]
    xor ecx, ecx
.Lsbr_env_keep:
    mov rax, [rdx + rcx]
    mov [rsi + SC_ENV_Q + rcx], rax
    add ecx, 8
    cmp ecx, 48
    jb .Lsbr_env_keep
    mov eax, 1
    jmp .Lsbr_env_return
.Lsbr_env_bad:
    xor eax, eax
.Lsbr_env_return:
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_envelope

# Noise floor scalefactors of channel RDX in element RCX; R8D=1 for balance
# data -> EAX=1, 0 out of range. Locals: 32 floor, 36 band, 40 previous
# value, 44 time tree, 48 frequency tree.
LOCALFN sbr_noise
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    lea r12d, [r8 + 1]                    # delta
    mov dword ptr [rsp + 44], 8           # NOISE30_T, ENV30_F
    mov dword ptr [rsp + 48], 5
    test r8d, r8d
    jz .Lsbr_noise_start
    mov dword ptr [rsp + 44], 9           # NOISEBAL30_T, BAL30_F
    mov dword ptr [rsp + 48], 7
.Lsbr_noise_start:
    mov dword ptr [rsp + 32], 0
.Lsbr_noise_next:
    mov edi, [rsp + 32]
    cmp edi, [rsi + SC_NUM_NOISE]
    jae .Lsbr_noise_finish
    lea r13, [rsi + rdi*8 + SC_NOISE_Q]   # row i; row i+1 at +8
    cmp byte ptr [rsi + SC_DF_NOISE + rdi], 0
    je .Lsbr_noise_frequency
    mov dword ptr [rsp + 36], 0
.Lsbr_noise_time:
    mov edx, [rsp + 36]
    cmp edx, [rbx + SE_N_Q]
    jae .Lsbr_noise_done
    movzx eax, byte ptr [r13 + rdx]
    mov [rsp + 40], eax
    mov ecx, [rsp + 44]
    call sbr_tree
    imul eax, r12d
    add eax, [rsp + 40]
    and eax, 255
    cmp eax, 30
    ja .Lsbr_noise_bad
    mov edx, [rsp + 36]
    mov [r13 + rdx + 8], al
    inc dword ptr [rsp + 36]
    jmp .Lsbr_noise_time
.Lsbr_noise_frequency:
    mov ecx, 5
    call aac_get
    imul eax, r12d
    mov [r13 + 8], al
    mov dword ptr [rsp + 36], 1
.Lsbr_noise_frequency_band:
    mov edx, [rsp + 36]
    cmp edx, [rbx + SE_N_Q]
    jae .Lsbr_noise_done
    movzx eax, byte ptr [r13 + rdx + 7]
    mov [rsp + 40], eax
    mov ecx, [rsp + 48]
    call sbr_tree
    imul eax, r12d
    add eax, [rsp + 40]
    and eax, 255
    cmp eax, 30
    ja .Lsbr_noise_bad
    mov edx, [rsp + 36]
    mov [r13 + rdx + 8], al
    inc dword ptr [rsp + 36]
    jmp .Lsbr_noise_frequency_band
.Lsbr_noise_done:
    inc dword ptr [rsp + 32]
    jmp .Lsbr_noise_next
.Lsbr_noise_finish:
    mov eax, [rsi + SC_NUM_NOISE]
    mov rax, [rsi + rax*8 + SC_NOISE_Q]
    mov [rsi + SC_NOISE_Q], rax
    mov eax, 1
    jmp .Lsbr_noise_return
.Lsbr_noise_bad:
    xor eax, eax
.Lsbr_noise_return:
    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_noise

# Additional sinusoids of channel RDX in element RCX.
LOCALFN sbr_harmonic
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rdi, rdx
    mov ecx, 1
    call aac_get
    mov [rdi + SC_HARMONIC_FLAG], eax
    test eax, eax
    jz .Lsbr_harmonic_done
    xor esi, esi
.Lsbr_harmonic_band:
    cmp esi, [rbx + SE_N_HIGH]
    jae .Lsbr_harmonic_done
    mov ecx, 1
    call aac_get
    mov [rdi + SC_HARMONIC + rsi], al
    inc esi
    jmp .Lsbr_harmonic_band
.Lsbr_harmonic_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_harmonic

# sbr_single_channel_element data for element RCX -> EAX=1, 0 when invalid.
LOCALFN sbr_single
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    lea rsi, [rbx + SE_CH]
    mov ecx, 1
    call aac_get                          # bs_data_extra
    test eax, eax
    jz .Lsbr_single_grid
    add qword ptr [rip + aac_pos], 4
.Lsbr_single_grid:
    mov rcx, rbx
    mov rdx, rsi
    call sbr_grid
    test eax, eax
    jz .Lsbr_single_return
    mov rcx, rsi
    call sbr_dtdf
    mov rcx, rbx
    mov rdx, rsi
    call sbr_invf
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_envelope
    test eax, eax
    jz .Lsbr_single_return
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_noise
    test eax, eax
    jz .Lsbr_single_return
    mov rcx, rbx
    mov rdx, rsi
    call sbr_harmonic
    mov eax, 1
.Lsbr_single_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN sbr_single

# sbr_channel_pair_element data for element RCX -> EAX=1, 0 when invalid.
LOCALFN sbr_pair
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    lea rsi, [rbx + SE_CH]
    lea rdi, [rbx + SE_CH + SC_SIZE]
    mov ecx, 1
    call aac_get                          # bs_data_extra
    test eax, eax
    jz .Lsbr_pair_coupling
    add qword ptr [rip + aac_pos], 8
.Lsbr_pair_coupling:
    mov ecx, 1
    call aac_get
    mov [rbx + SE_COUPLING], eax
    test eax, eax
    jz .Lsbr_pair_independent
    mov rcx, rbx
    mov rdx, rsi
    call sbr_grid
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rdi
    mov rdx, rsi
    call sbr_copy_grid
    mov rcx, rsi
    call sbr_dtdf
    mov rcx, rdi
    call sbr_dtdf
    mov rcx, rbx
    mov rdx, rsi
    call sbr_invf
    mov rax, [rdi + SC_INVF]
    mov [rdi + SC_INVF + 8], rax
    mov rax, [rsi + SC_INVF]
    mov [rdi + SC_INVF], rax
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_envelope
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_noise
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, 1
    call sbr_envelope
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, 1
    call sbr_noise
    test eax, eax
    jz .Lsbr_pair_return
    jmp .Lsbr_pair_harmonic
.Lsbr_pair_independent:
    mov rcx, rbx
    mov rdx, rsi
    call sbr_grid
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rdi
    call sbr_grid
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rsi
    call sbr_dtdf
    mov rcx, rdi
    call sbr_dtdf
    mov rcx, rbx
    mov rdx, rsi
    call sbr_invf
    mov rcx, rbx
    mov rdx, rdi
    call sbr_invf
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_envelope
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rdi
    xor r8d, r8d
    call sbr_envelope
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rsi
    xor r8d, r8d
    call sbr_noise
    test eax, eax
    jz .Lsbr_pair_return
    mov rcx, rbx
    mov rdx, rdi
    xor r8d, r8d
    call sbr_noise
    test eax, eax
    jz .Lsbr_pair_return
.Lsbr_pair_harmonic:
    mov rcx, rbx
    mov rdx, rsi
    call sbr_harmonic
    mov rcx, rbx
    mov rdx, rdi
    call sbr_harmonic
    mov eax, 1
.Lsbr_pair_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_pair

# SBR extension payload of a fill element (ISO sbr_extension_data, FFmpeg
# ff_decode_sbr_extension) for element RCX of type EDX (0 SCE, 1 CPE, 3 LFE);
# R8D=1 with a CRC, R9D=payload bytes counting the extension type nibble,
# which the reader has passed. -> EAX=1, 0 for parametric stereo in a mono
# stream (unsupported; elsewhere it is skipped, as FFmpeg does).
# The reader ends after the payload whatever the SBR data used.
LOCALFN sbr_extension
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov esi, edx
    mov r12d, r9d
    mov r13, [rip + aac_pos]
    mov dword ptr [rbx + SE_RESET], 0
    test r8d, r8d
    jz .Lsbr_ext_push
    add qword ptr [rip + aac_pos], 10     # bs_sbr_crc_bits (not checked)
.Lsbr_ext_push:
    mov eax, [rbx + SE_KX1]
    mov [rbx + SE_KX0], eax
    mov eax, [rbx + SE_M1]
    mov [rbx + SE_M0], eax
    mov dword ptr [rbx + SE_PUSHED], 1
    mov ecx, 1
    call aac_get                          # bs_header_flag
    test eax, eax
    jz .Lsbr_ext_reset
    mov rcx, rbx
    call sbr_header
.Lsbr_ext_reset:
    cmp dword ptr [rbx + SE_RESET], 0
    je .Lsbr_ext_data
    mov rcx, rbx
    call sbr_frequency_tables
    test eax, eax
    jnz .Lsbr_ext_data
    mov rcx, rbx
    call sbr_turnoff
.Lsbr_ext_data:
    cmp dword ptr [rbx + SE_START], 0
    je .Lsbr_ext_end
    mov dword ptr [rbx + SE_READY], 1
    mov rcx, rbx
    test esi, esi
    jz .Lsbr_ext_single
    cmp esi, 1
    jne .Lsbr_ext_off
    call sbr_pair
    jmp .Lsbr_ext_checked
.Lsbr_ext_single:
    call sbr_single
.Lsbr_ext_checked:
    test eax, eax
    jz .Lsbr_ext_off
    mov ecx, 1
    call aac_get                          # bs_extended_data
    test eax, eax
    jz .Lsbr_ext_end
    mov ecx, 4
    call aac_get
    mov edi, eax
    cmp eax, 15
    jne .Lsbr_ext_size
    mov ecx, 8
    call aac_get
    add edi, eax
.Lsbr_ext_size:
    shl edi, 3                            # bits left
.Lsbr_ext_payload:
    cmp edi, 7
    jle .Lsbr_ext_skip
    sub edi, 2
    mov ecx, 2
    call aac_get                          # bs_extension_id
    cmp eax, 2                            # EXTENSION_ID_PS: applies to mono streams
    jne .Lsbr_ext_skip
    cmp dword ptr [rip + aac_config], 1
    je .Lsbr_ext_unsupported
.Lsbr_ext_skip:
    add [rip + aac_pos], rdi              # other extensions and fill bits
    jmp .Lsbr_ext_end
.Lsbr_ext_off:
    mov rcx, rbx
    call sbr_turnoff
.Lsbr_ext_end:
    mov rax, [rip + aac_pos]              # read past the payload: pure upsampling
    sub rax, r13
    add rax, 4
    mov ecx, r12d
    shl rcx, 3
    cmp rax, rcx
    jbe .Lsbr_ext_position
    mov rcx, rbx
    call sbr_turnoff
.Lsbr_ext_position:
    mov eax, r12d
    lea rax, [r13 + rax*8 - 4]
    mov [rip + aac_pos], rax
    mov eax, 1
    jmp .Lsbr_ext_return
.Lsbr_ext_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
    xor eax, eax
.Lsbr_ext_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_extension

# ECX=x -> XMM0=2^(x/2), exact. Clobbers RAX.
LOCALFN sbr_pow2_half
    mov eax, ecx
    sar eax, 1
    add eax, 1023
    shl rax, 52
    movq xmm0, rax
    test ecx, 1
    jz .Lsbr_pow2_done
    mulsd xmm0, [rip + sbr_sqrt2]
.Lsbr_pow2_done:
    ret
ENDFN sbr_pow2_half

# Envelope and noise floor dequantization (ISO 4.6.18.3.5) for element RCX of
# channel element type EDX. Locals: 32 envelope, 36 band, 40 pan offset,
# 48 temp2.
LOCALFN sbr_dequant
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 72
    mov rbx, rcx
    mov r14d, edx
    lea rsi, [rbx + SE_CH]
    lea rdi, [rbx + SE_CH + SC_SIZE]
    cmp edx, 1
    jne .Lsbr_dq_independent
    cmp dword ptr [rbx + SE_COUPLING], 0
    je .Lsbr_dq_independent
    # Coupled pair: level and balance.
    mov eax, 24
    cmp dword ptr [rsi + SC_AMP_RES], 0
    je .Lsbr_dq_pan
    mov eax, 12
.Lsbr_dq_pan:
    mov [rsp + 40], eax
    mov r12d, 1                           # envelope e
.Lsbr_dq_cenv:
    cmp r12d, [rsi + SC_NUM_ENV]
    ja .Lsbr_dq_cnoise_start
    movzx eax, byte ptr [rsi + SC_FREQ_RES + r12]
    mov r13d, [rbx + SE_N_LOW]
    test eax, eax
    jz .Lsbr_dq_cenv_count
    mov r13d, [rbx + SE_N_HIGH]
.Lsbr_dq_cenv_count:
    mov dword ptr [rsp + 36], 0
.Lsbr_dq_cenv_band:
    mov edx, [rsp + 36]
    cmp edx, r13d
    jae .Lsbr_dq_cenv_next
    imul eax, r12d, 48
    add eax, edx                          # q index
    mov [rsp + 32], eax
    movzx ecx, byte ptr [rdi + SC_ENV_Q + rax]
    neg ecx
    add ecx, [rsp + 40]                   # pan - q1
    cmp dword ptr [rsi + SC_AMP_RES], 0
    je .Lsbr_dq_c15
    add ecx, ecx
.Lsbr_dq_c15:
    call sbr_pow2_half
    movsd [rsp + 48], xmm0                # temp2
    mov eax, [rsp + 32]
    movzx ecx, byte ptr [rsi + SC_ENV_Q + rax]
    cmp dword ptr [rsi + SC_AMP_RES], 0
    je .Lsbr_dq_c15_level
    add ecx, 7
    add ecx, ecx
    jmp .Lsbr_dq_clevel
.Lsbr_dq_c15_level:
    add ecx, 14
.Lsbr_dq_clevel:
    call sbr_pow2_half                    # temp1
    ucomisd xmm0, [rip + sbr_env_limit]
    jbe .Lsbr_dq_cfac
    movsd xmm0, [rip + sbr_one]
.Lsbr_dq_cfac:
    movsd xmm1, [rsp + 48]
    addsd xmm1, [rip + sbr_one]
    divsd xmm0, xmm1                      # fac
    mov eax, [rsp + 32]
    movsd [rsi + SC_ENV + rax*8], xmm0
    mulsd xmm0, [rsp + 48]
    movsd [rdi + SC_ENV + rax*8], xmm0
    inc dword ptr [rsp + 36]
    jmp .Lsbr_dq_cenv_band
.Lsbr_dq_cenv_next:
    inc r12d
    jmp .Lsbr_dq_cenv
.Lsbr_dq_cnoise_start:
    mov r12d, 1
.Lsbr_dq_cnoise:
    cmp r12d, [rsi + SC_NUM_NOISE]
    ja .Lsbr_dq_return
    xor r13d, r13d
.Lsbr_dq_cnoise_band:
    cmp r13d, [rbx + SE_N_Q]
    jae .Lsbr_dq_cnoise_next
    lea eax, [r13 + r12*8]
    mov [rsp + 32], eax
    movzx ecx, byte ptr [rdi + SC_NOISE_Q + rax]
    neg ecx
    add ecx, 12
    add ecx, ecx
    call sbr_pow2_half
    movsd [rsp + 48], xmm0                # temp2
    mov eax, [rsp + 32]
    movzx ecx, byte ptr [rsi + SC_NOISE_Q + rax]
    neg ecx
    add ecx, 7                            # NOISE_FLOOR_OFFSET + 1
    add ecx, ecx
    call sbr_pow2_half
    movsd xmm1, [rsp + 48]
    addsd xmm1, [rip + sbr_one]
    divsd xmm0, xmm1
    mov eax, [rsp + 32]
    movsd [rsi + SC_NOISE + rax*8], xmm0
    mulsd xmm0, [rsp + 48]
    movsd [rdi + SC_NOISE + rax*8], xmm0
    inc r13d
    jmp .Lsbr_dq_cnoise_band
.Lsbr_dq_cnoise_next:
    inc r12d
    jmp .Lsbr_dq_cnoise
.Lsbr_dq_independent:
    mov rdi, rsi
    call .Lsbr_dq_channel
    cmp r14d, 1
    jne .Lsbr_dq_return
    lea rdi, [rbx + SE_CH + SC_SIZE]
    call .Lsbr_dq_channel
.Lsbr_dq_return:
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# Channel RDI on its own (the caller's locals are 8 bytes deeper).
.Lsbr_dq_channel:
    mov r12d, 1
.Lsbr_dq_env:
    cmp r12d, [rdi + SC_NUM_ENV]
    ja .Lsbr_dq_noise_start
    movzx eax, byte ptr [rdi + SC_FREQ_RES + r12]
    mov r13d, [rbx + SE_N_LOW]
    test eax, eax
    jz .Lsbr_dq_env_count
    mov r13d, [rbx + SE_N_HIGH]
.Lsbr_dq_env_count:
    imul esi, r12d, 48
.Lsbr_dq_env_band:
    test r13d, r13d
    jz .Lsbr_dq_env_next
    movzx ecx, byte ptr [rdi + SC_ENV_Q + rsi]
    cmp dword ptr [rdi + SC_AMP_RES], 0
    je .Lsbr_dq_env15
    add ecx, ecx
.Lsbr_dq_env15:
    add ecx, 12
    call sbr_pow2_half
    ucomisd xmm0, [rip + sbr_env_limit]
    jbe .Lsbr_dq_env_store
    movsd xmm0, [rip + sbr_one]
.Lsbr_dq_env_store:
    movsd [rdi + SC_ENV + rsi*8], xmm0
    inc esi
    dec r13d
    jmp .Lsbr_dq_env_band
.Lsbr_dq_env_next:
    inc r12d
    jmp .Lsbr_dq_env
.Lsbr_dq_noise_start:
    mov r12d, 1
.Lsbr_dq_noise:
    cmp r12d, [rdi + SC_NUM_NOISE]
    ja .Lsbr_dq_channel_done
    xor r13d, r13d
.Lsbr_dq_noise_band:
    cmp r13d, [rbx + SE_N_Q]
    jae .Lsbr_dq_noise_next
    lea esi, [r13 + r12*8]
    movzx ecx, byte ptr [rdi + SC_NOISE_Q + rsi]
    neg ecx
    add ecx, 6
    add ecx, ecx
    call sbr_pow2_half
    movsd [rdi + SC_NOISE + rsi*8], xmm0
    inc r13d
    jmp .Lsbr_dq_noise_band
.Lsbr_dq_noise_next:
    inc r12d
    jmp .Lsbr_dq_noise
.Lsbr_dq_channel_done:
    ret
ENDFN sbr_dequant

# Dot product of R8D doubles (a multiple of 4) at RCX and RDX -> XMM0.
# Clobbers RCX, RDX, R8, XMM1-XMM3.
LOCALFN sbr_dot
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
.Lsbr_dot_loop:
    movupd xmm2, [rcx]
    movupd xmm3, [rdx]
    mulpd xmm2, xmm3
    addpd xmm0, xmm2
    movupd xmm2, [rcx + 16]
    movupd xmm3, [rdx + 16]
    mulpd xmm2, xmm3
    addpd xmm1, xmm2
    add rcx, 32
    add rdx, 32
    sub r8d, 4
    jnz .Lsbr_dot_loop
    addpd xmm0, xmm1
    movapd xmm1, xmm0
    unpckhpd xmm1, xmm1
    addsd xmm0, xmm1
    ret
ENDFN sbr_dot

# Analysis QMF bank (ISO 4.6.18.4.1) of channel RCX: 1024 core floats at RDX
# -> W[Ypos], 32 slots of 32 complex subbands, the input scaled to +-32768.
LOCALFN sbr_analysis
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    mov eax, [rbx + SC_YPOS]
    shl eax, 14
    lea r13, [rbx + rax + SC_W]
    mov r14, [rip + sbr_scratch]
    add r14, SB_U
    xor r15d, r15d
.Lsbr_ana_slot:
    lea rdi, [rbx + SC_X]
    lea rsi, [rbx + SC_X + 256]
    mov ecx, 288
    rep movsq
    xor ecx, ecx
.Lsbr_ana_input:
    cvtss2sd xmm0, [r12 + rcx*4]
    mulsd xmm0, [rip + sbr_scale_in]
    movsd [rbx + SC_X + 2304 + rcx*8], xmm0
    inc ecx
    cmp ecx, 32
    jb .Lsbr_ana_input
    add r12, 128
    lea r8, [rip + sbr_window]
    xor ecx, ecx                          # u[j] = sum x[319 - n] c[2n], n = j mod 64
.Lsbr_ana_u:
    xorpd xmm0, xmm0
    mov edx, ecx
.Lsbr_ana_u_term:
    mov eax, 319
    sub eax, edx
    movsd xmm1, [rbx + SC_X + rax*8]
    lea eax, [rdx + rdx]
    mulsd xmm1, [r8 + rax*8]
    addsd xmm0, xmm1
    add edx, 64
    cmp edx, 320
    jb .Lsbr_ana_u_term
    movsd [r14 + rcx*8], xmm0
    inc ecx
    cmp ecx, 64
    jb .Lsbr_ana_u
    xor esi, esi                          # 2 x subband k
.Lsbr_ana_band:
    mov rcx, r14
    mov eax, esi
    shl eax, 8
    lea rdx, [rip + sbr_ana_cos]
    add rdx, rax
    mov r8d, 64
    call sbr_dot
    movsd [r13 + rsi*8], xmm0
    mov rcx, r14
    mov eax, esi
    shl eax, 8
    lea rdx, [rip + sbr_ana_sin]
    add rdx, rax
    mov r8d, 64
    call sbr_dot
    movsd [r13 + rsi*8 + 8], xmm0
    add esi, 2
    cmp esi, 64
    jb .Lsbr_ana_band
    add r13, 512
    inc r15d
    cmp r15d, 32
    jb .Lsbr_ana_slot
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_analysis

# Synthesis QMF bank (ISO 4.6.18.4.2) of channel RCX from the scratch X ->
# 2048 floats at RDX. The memory V runs downwards through a 5248-double
# buffer; the newest 1152 values move back to its end after each frame.
LOCALFN sbr_synthesis
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    mov r13, [rip + sbr_scratch]
    add r13, SB_X
    lea r14, [rbx + SC_V + (4096 - 128)*8]
    xor r15d, r15d
.Lsbr_syn_slot:
    xor esi, esi                          # v[n] = Re sum X[k] e^(i theta(n, k)) / 64
.Lsbr_syn_value:
    mov rcx, r13
    mov eax, esi
    shl eax, 9
    lea rdx, [rip + sbr_syn_cos]
    add rdx, rax
    mov r8d, 64
    call sbr_dot
    movsd [r14 + rsi*8], xmm0
    lea rcx, [r13 + 512]
    mov eax, esi
    shl eax, 9
    lea rdx, [rip + sbr_syn_sin]
    add rdx, rax
    mov r8d, 64
    call sbr_dot
    movsd xmm1, [r14 + rsi*8]
    subsd xmm1, xmm0
    movsd [r14 + rsi*8], xmm1
    inc esi
    cmp esi, 128
    jb .Lsbr_syn_value
    lea r8, [rip + sbr_window]
    xor ecx, ecx                          # output sample j
.Lsbr_syn_out:
    xorpd xmm0, xmm0
    mov eax, ecx                          # 256 i + j
    mov r9d, ecx                          # 128 i + j
    mov edx, 5
.Lsbr_syn_term:
    movsd xmm1, [r14 + rax*8]
    mulsd xmm1, [r8 + r9*8]
    addsd xmm0, xmm1
    movsd xmm1, [r14 + rax*8 + 192*8]
    mulsd xmm1, [r8 + r9*8 + 64*8]
    addsd xmm0, xmm1
    add eax, 256
    add r9d, 128
    dec edx
    jnz .Lsbr_syn_term
    mulsd xmm0, [rip + sbr_scale_out]
    cvtsd2ss xmm0, xmm0
    movss [r12 + rcx*4], xmm0
    inc ecx
    cmp ecx, 64
    jb .Lsbr_syn_out
    add r12, 256
    add r13, 1024
    sub r14, 1024
    inc r15d
    cmp r15d, 32
    jb .Lsbr_syn_slot
    lea rsi, [rbx + SC_V]
    lea rdi, [rbx + SC_V + 4096*8]
    mov ecx, 1152
    rep movsq
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_synthesis

# Low band X_low (ISO 4.6.18.5, t_HFGen 8) for element RCX, channel RDX:
# this frame's slots for kx' subbands and the previous frame's last eight
# slots for kx.
LOCALFN sbr_lf_gen
    push rbx
    push rsi
    push rdi
    mov r9, rcx
    mov r10, rdx
    mov rbx, [rip + sbr_scratch]
    mov rdi, rbx
    xor eax, eax
    mov ecx, 32*40*2
    rep stosq
    mov eax, [r10 + SC_YPOS]
    shl eax, 14
    lea r11, [r10 + rax + SC_W]           # current
    xor eax, 1 << 14
    lea r8, [r10 + rax + SC_W]            # previous
    xor ecx, ecx                          # k
.Lsbr_lf_current:
    cmp ecx, [r9 + SE_KX1]
    jae .Lsbr_lf_previous_start
    imul esi, ecx, 640
    add rsi, rbx
    mov eax, ecx
    shl eax, 4
    lea rdx, [r11 + rax]
    mov edi, 32
.Lsbr_lf_current_slot:
    movups xmm0, [rdx]
    movups [rsi + 8*16], xmm0
    add rdx, 512
    add rsi, 16
    dec edi
    jnz .Lsbr_lf_current_slot
    inc ecx
    jmp .Lsbr_lf_current
.Lsbr_lf_previous_start:
    xor ecx, ecx
.Lsbr_lf_previous:
    cmp ecx, [r9 + SE_KX0]
    jae .Lsbr_lf_done
    imul esi, ecx, 640
    add rsi, rbx
    mov eax, ecx
    shl eax, 4
    lea rdx, [r8 + rax + 24*512]
    mov edi, 8
.Lsbr_lf_previous_slot:
    movups xmm0, [rdx]
    movups [rsi], xmm0
    add rdx, 512
    add rsi, 16
    dec edi
    jnz .Lsbr_lf_previous_slot
    inc ecx
    jmp .Lsbr_lf_previous
.Lsbr_lf_done:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_lf_gen

# Inverse filtering coefficients (ISO 4.6.18.6.2, covariance method) for the
# k0 low subbands of element RCX -> scratch alpha0, alpha1.
# XMM6-XMM13 accumulate phi(0,1), phi(0,2), phi(1,1), phi(1,2), phi(2,2).
LOCALFN sbr_inverse_filter
    push rbx
    push rsi
    sub rsp, 152
    movdqu [rsp + 16], xmm6
    movdqu [rsp + 32], xmm7
    movdqu [rsp + 48], xmm8
    movdqu [rsp + 64], xmm9
    movdqu [rsp + 80], xmm10
    movdqu [rsp + 96], xmm11
    movdqu [rsp + 112], xmm12
    movdqu [rsp + 128], xmm13
    mov r9, rcx
    mov r10, [rip + sbr_scratch]
    xor ebx, ebx                          # k
.Lsbr_inv_band:
    cmp ebx, [r9 + SE_K0]
    jae .Lsbr_inv_done
    imul eax, ebx, 640
    lea rsi, [r10 + rax + SB_X_LOW]
    xorpd xmm6, xmm6
    xorpd xmm7, xmm7
    xorpd xmm8, xmm8
    xorpd xmm9, xmm9
    xorpd xmm10, xmm10
    xorpd xmm11, xmm11
    xorpd xmm12, xmm12
    xorpd xmm13, xmm13
    mov ecx, 38
.Lsbr_inv_sum:
    movsd xmm2, [rsi + 16]                # b = x[n + 1]
    movsd xmm3, [rsi + 24]
    movsd xmm4, [rsi]                     # c = x[n]
    movsd xmm5, [rsi + 8]
    movsd xmm0, [rsi + 32]                # a = x[n + 2]: a conj(b), a conj(c)
    mulsd xmm0, xmm2
    addsd xmm6, xmm0
    movsd xmm0, [rsi + 40]
    mulsd xmm0, xmm3
    addsd xmm6, xmm0
    movsd xmm0, [rsi + 40]
    mulsd xmm0, xmm2
    addsd xmm7, xmm0
    movsd xmm0, [rsi + 32]
    mulsd xmm0, xmm3
    subsd xmm7, xmm0
    movsd xmm0, [rsi + 32]
    mulsd xmm0, xmm4
    addsd xmm8, xmm0
    movsd xmm0, [rsi + 40]
    mulsd xmm0, xmm5
    addsd xmm8, xmm0
    movsd xmm0, [rsi + 40]
    mulsd xmm0, xmm4
    addsd xmm9, xmm0
    movsd xmm0, [rsi + 32]
    mulsd xmm0, xmm5
    subsd xmm9, xmm0
    movsd xmm0, xmm2                      # |b|^2
    mulsd xmm0, xmm2
    addsd xmm10, xmm0
    movsd xmm0, xmm3
    mulsd xmm0, xmm3
    addsd xmm10, xmm0
    movsd xmm0, xmm2                      # b conj(c)
    mulsd xmm0, xmm4
    addsd xmm11, xmm0
    movsd xmm0, xmm3
    mulsd xmm0, xmm5
    addsd xmm11, xmm0
    movsd xmm0, xmm3
    mulsd xmm0, xmm4
    addsd xmm12, xmm0
    movsd xmm0, xmm2
    mulsd xmm0, xmm5
    subsd xmm12, xmm0
    movsd xmm0, xmm4                      # |c|^2
    mulsd xmm0, xmm4
    addsd xmm13, xmm0
    movsd xmm0, xmm5
    mulsd xmm0, xmm5
    addsd xmm13, xmm0
    add rsi, 16
    dec ecx
    jnz .Lsbr_inv_sum
    # d = phi22 phi11 - |phi12|^2 / 1.000001
    movsd xmm0, xmm11
    mulsd xmm0, xmm11
    movsd xmm1, xmm12
    mulsd xmm1, xmm12
    addsd xmm0, xmm1
    divsd xmm0, [rip + sbr_dk_scale]
    movsd xmm1, xmm13
    mulsd xmm1, xmm10
    subsd xmm1, xmm0                      # d
    xorpd xmm2, xmm2                      # alpha1
    xorpd xmm3, xmm3
    xorpd xmm0, xmm0
    ucomisd xmm1, xmm0
    jne .Lsbr_inv_alpha1
    jnp .Lsbr_inv_alpha0
.Lsbr_inv_alpha1:
    movsd xmm2, xmm6                      # (phi01 phi12 - phi02 phi11) / d
    mulsd xmm2, xmm11
    movsd xmm0, xmm7
    mulsd xmm0, xmm12
    subsd xmm2, xmm0
    movsd xmm0, xmm8
    mulsd xmm0, xmm10
    subsd xmm2, xmm0
    divsd xmm2, xmm1
    movsd xmm3, xmm6
    mulsd xmm3, xmm12
    movsd xmm0, xmm7
    mulsd xmm0, xmm11
    addsd xmm3, xmm0
    movsd xmm0, xmm9
    mulsd xmm0, xmm10
    subsd xmm3, xmm0
    divsd xmm3, xmm1
.Lsbr_inv_alpha0:
    xorpd xmm4, xmm4                      # alpha0
    xorpd xmm5, xmm5
    xorpd xmm0, xmm0
    ucomisd xmm10, xmm0
    jne .Lsbr_inv_alpha0_value
    jnp .Lsbr_inv_check
.Lsbr_inv_alpha0_value:
    movsd xmm4, xmm2                      # -(phi01 + alpha1 conj(phi12)) / phi11
    mulsd xmm4, xmm11
    movsd xmm0, xmm3
    mulsd xmm0, xmm12
    addsd xmm4, xmm0
    addsd xmm4, xmm6
    divsd xmm4, xmm10
    movsd xmm5, xmm3
    mulsd xmm5, xmm11
    movsd xmm0, xmm2
    mulsd xmm0, xmm12
    subsd xmm5, xmm0
    addsd xmm5, xmm7
    divsd xmm5, xmm10
    xorpd xmm0, xmm0
    movsd xmm1, xmm0
    subsd xmm0, xmm4
    movsd xmm4, xmm0
    subsd xmm1, xmm5
    movsd xmm5, xmm1
.Lsbr_inv_check:
    movsd xmm0, xmm2
    mulsd xmm0, xmm2
    movsd xmm1, xmm3
    mulsd xmm1, xmm3
    addsd xmm0, xmm1
    ucomisd xmm0, [rip + sbr_sixteen]
    jae .Lsbr_inv_zero
    movsd xmm0, xmm4
    mulsd xmm0, xmm4
    movsd xmm1, xmm5
    mulsd xmm1, xmm5
    addsd xmm0, xmm1
    ucomisd xmm0, [rip + sbr_sixteen]
    jb .Lsbr_inv_store
.Lsbr_inv_zero:
    xorpd xmm2, xmm2
    xorpd xmm3, xmm3
    xorpd xmm4, xmm4
    xorpd xmm5, xmm5
.Lsbr_inv_store:
    mov eax, ebx
    shl eax, 4
    movsd [r10 + rax + SB_ALPHA0], xmm4
    movsd [r10 + rax + SB_ALPHA0 + 8], xmm5
    movsd [r10 + rax + SB_ALPHA1], xmm2
    movsd [r10 + rax + SB_ALPHA1 + 8], xmm3
    inc ebx
    jmp .Lsbr_inv_band
.Lsbr_inv_done:
    movdqu xmm6, [rsp + 16]
    movdqu xmm7, [rsp + 32]
    movdqu xmm8, [rsp + 48]
    movdqu xmm9, [rsp + 64]
    movdqu xmm10, [rsp + 80]
    movdqu xmm11, [rsp + 96]
    movdqu xmm12, [rsp + 112]
    movdqu xmm13, [rsp + 128]
    add rsp, 152
    pop rsi
    pop rbx
    ret
ENDFN sbr_inverse_filter

# Chirp factors (ISO 4.6.18.6.2) of channel RDX in element RCX.
LOCALFN sbr_chirp
    xor r8d, r8d
.Lsbr_chirp_band:
    cmp r8d, [rcx + SE_N_Q]
    jae .Lsbr_chirp_done
    movzx eax, byte ptr [rdx + SC_INVF + r8]
    movzx r9d, byte ptr [rdx + SC_INVF + 8 + r8]
    add r9d, eax
    movsd xmm0, [rip + sbr_bw_new]        # 0.6 when the modes are 0 and 1
    cmp r9d, 1
    je .Lsbr_chirp_smooth
    lea r9, [rip + sbr_bw_table]
    movsd xmm0, [r9 + rax*8]
.Lsbr_chirp_smooth:
    movsd xmm1, [rdx + SC_BW + r8*8]
    ucomisd xmm0, xmm1
    jae .Lsbr_chirp_rising
    mulsd xmm0, [rip + sbr_bw_new + 8]
    mulsd xmm1, [rip + sbr_bw_new + 16]
    jmp .Lsbr_chirp_sum
.Lsbr_chirp_rising:
    mulsd xmm0, [rip + sbr_bw_new + 24]
    mulsd xmm1, [rip + sbr_bw_new + 32]
.Lsbr_chirp_sum:
    addsd xmm0, xmm1
    ucomisd xmm0, [rip + sbr_bw_low]
    jae .Lsbr_chirp_store
    xorpd xmm0, xmm0
.Lsbr_chirp_store:
    movsd [rdx + SC_BW + r8*8], xmm0
    inc r8d
    jmp .Lsbr_chirp_band
.Lsbr_chirp_done:
    ret
ENDFN sbr_chirp

# HF generation (ISO 4.6.18.6.3) for element RCX, channel RDX: the patches
# copy low subbands up, filtered with the chirped prediction coefficients.
# Subbands the patches leave out up to kx' + M are zeroed.
LOCALFN sbr_hf_gen
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    movdqu [rsp + 32], xmm6
    movdqu [rsp + 48], xmm7
    movdqu [rsp + 64], xmm8
    mov rbx, rcx
    mov r15, rdx
    mov r14, [rip + sbr_scratch]
    movzx eax, byte ptr [r15 + SC_T_ENV]
    lea r12d, [rax*2 + 2]                 # first slot
    mov eax, [r15 + SC_NUM_ENV]
    movzx eax, byte ptr [r15 + SC_T_ENV + rax]
    lea r13d, [rax*2 + 2]                 # end slot
    mov edi, [rbx + SE_KX1]               # k
    xor esi, esi                          # noise band g
    mov dword ptr [rsp + 80], 0           # patch
.Lsbr_hf_patch:
    mov eax, [rsp + 80]
    cmp eax, [rbx + SE_PATCHES]
    jae .Lsbr_hf_clear
    mov dword ptr [rsp + 84], 0           # x
.Lsbr_hf_band:
    mov eax, [rsp + 80]
    movzx ecx, byte ptr [rbx + SE_PATCH_SIZE + rax]
    cmp [rsp + 84], ecx
    jae .Lsbr_hf_patch_next
    movzx r8d, byte ptr [rbx + SE_PATCH_START + rax]
    add r8d, [rsp + 84]                   # p
.Lsbr_hf_noise_band:
    cmp esi, [rbx + SE_N_Q]
    ja .Lsbr_hf_noise_found
    movzx eax, byte ptr [rbx + SE_F_NOISE + rsi]
    cmp edi, eax
    jb .Lsbr_hf_noise_found
    inc esi
    jmp .Lsbr_hf_noise_band
.Lsbr_hf_noise_found:
    dec esi
    movsd xmm0, [r15 + SC_BW + rsi*8]     # bw
    mov eax, r8d
    shl eax, 4
    movsd xmm2, [r14 + rax + SB_ALPHA0]
    movsd xmm3, [r14 + rax + SB_ALPHA0 + 8]
    mulsd xmm2, xmm0
    mulsd xmm3, xmm0
    mulsd xmm0, xmm0
    movsd xmm4, [r14 + rax + SB_ALPHA1]
    movsd xmm5, [r14 + rax + SB_ALPHA1 + 8]
    mulsd xmm4, xmm0
    mulsd xmm5, xmm0
    imul eax, r8d, 640
    lea r9, [r14 + rax + SB_X_LOW]
    imul eax, edi, 640
    lea r10, [r14 + rax + SB_X_HIGH]
    mov ecx, r12d
.Lsbr_hf_slot:
    cmp ecx, r13d
    jae .Lsbr_hf_band_next
    mov eax, ecx
    shl eax, 4
    movsd xmm0, [r9 + rax]                # re
    movsd xmm1, [r9 + rax + 8]            # im
    movsd xmm6, [r9 + rax - 16]           # x[i - 1]
    movsd xmm7, [r9 + rax - 8]
    movsd xmm8, xmm6
    mulsd xmm8, xmm2
    addsd xmm0, xmm8
    movsd xmm8, xmm7
    mulsd xmm8, xmm3
    subsd xmm0, xmm8
    movsd xmm8, xmm7
    mulsd xmm8, xmm2
    addsd xmm1, xmm8
    movsd xmm8, xmm6
    mulsd xmm8, xmm3
    addsd xmm1, xmm8
    movsd xmm6, [r9 + rax - 32]           # x[i - 2]
    movsd xmm7, [r9 + rax - 24]
    movsd xmm8, xmm6
    mulsd xmm8, xmm4
    addsd xmm0, xmm8
    movsd xmm8, xmm7
    mulsd xmm8, xmm5
    subsd xmm0, xmm8
    movsd xmm8, xmm7
    mulsd xmm8, xmm4
    addsd xmm1, xmm8
    movsd xmm8, xmm6
    mulsd xmm8, xmm5
    addsd xmm1, xmm8
    movsd [r10 + rax], xmm0
    movsd [r10 + rax + 8], xmm1
    inc ecx
    jmp .Lsbr_hf_slot
.Lsbr_hf_band_next:
    inc edi
    inc dword ptr [rsp + 84]
    jmp .Lsbr_hf_band
.Lsbr_hf_patch_next:
    inc dword ptr [rsp + 80]
    jmp .Lsbr_hf_patch
.Lsbr_hf_clear:
    mov ecx, [rbx + SE_KX1]
    add ecx, [rbx + SE_M1]
    sub ecx, edi
    jle .Lsbr_hf_done
    imul ecx, ecx, 640/8
    imul eax, edi, 640
    lea rdi, [r14 + rax + SB_X_HIGH]
    xor eax, eax
    rep stosq
.Lsbr_hf_done:
    movdqu xmm6, [rsp + 32]
    movdqu xmm7, [rsp + 48]
    movdqu xmm8, [rsp + 64]
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_hf_gen

# Mapping (ISO 4.6.18.7.2) for element RCX, channel RDX: envelopes, noise
# floors and sinusoids per QMF subband -> EAX=1, 0 when kx' disagrees with
# the tables. Locals: 32 envelope e, 36 bands, 40 table offset, 44 band i.
LOCALFN sbr_mapping
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov r14, [rip + sbr_scratch]
    mov r15d, [rbx + SE_KX1]
    lea rdi, [rsi + SC_S_INDEX + 48]
    xor eax, eax
    mov ecx, 7*48/8
    rep stosq
    mov dword ptr [rsp + 32], 0
.Lsbr_map_env:
    mov r12d, [rsp + 32]
    cmp r12d, [rsi + SC_NUM_ENV]
    jae .Lsbr_map_done
    movzx eax, byte ptr [rsi + SC_FREQ_RES + r12 + 1]
    mov ecx, SE_F_LOW
    mov edx, [rbx + SE_N_LOW]
    test eax, eax
    jz .Lsbr_map_table
    mov ecx, SE_F_HIGH
    mov edx, [rbx + SE_N_HIGH]
.Lsbr_map_table:
    mov [rsp + 40], ecx
    mov [rsp + 36], edx
    lea r13, [rbx + rcx]                  # band table
    movzx eax, byte ptr [r13]
    cmp eax, r15d
    jne .Lsbr_map_bad
    # Envelope per subband.
    imul eax, r12d, 384
    lea rdi, [r14 + rax + SB_E_ORIG]
    lea r8, [rsi + rax + 384 + SC_ENV]    # envelope e + 1
    xor ecx, ecx
.Lsbr_map_env_band:
    cmp ecx, [rsp + 36]
    jae .Lsbr_map_noise
    movsd xmm0, [r8 + rcx*8]
    movzx eax, byte ptr [r13 + rcx]
    movzx edx, byte ptr [r13 + rcx + 1]
.Lsbr_map_env_fill:
    cmp eax, edx
    jae .Lsbr_map_env_band_next
    mov r9d, eax
    sub r9d, r15d
    movsd [rdi + r9*8], xmm0
    inc eax
    jmp .Lsbr_map_env_fill
.Lsbr_map_env_band_next:
    inc ecx
    jmp .Lsbr_map_env_band
.Lsbr_map_noise:
    xor eax, eax                          # second noise floor from t_Q[1]
    cmp dword ptr [rsi + SC_NUM_NOISE], 1
    jbe .Lsbr_map_noise_row
    movzx ecx, byte ptr [rsi + SC_T_ENV + r12]
    movzx edx, byte ptr [rsi + SC_T_Q + 1]
    cmp ecx, edx
    setae al
.Lsbr_map_noise_row:
    shl eax, 6
    lea r8, [rsi + rax + 64 + SC_NOISE]   # noise floor kq + 1
    imul eax, r12d, 384
    lea rdi, [r14 + rax + SB_Q_MAPPED]
    xor ecx, ecx
.Lsbr_map_noise_band:
    cmp ecx, [rbx + SE_N_Q]
    jae .Lsbr_map_harmonic
    movsd xmm0, [r8 + rcx*8]
    movzx eax, byte ptr [rbx + SE_F_NOISE + rcx]
    movzx edx, byte ptr [rbx + SE_F_NOISE + rcx + 1]
.Lsbr_map_noise_fill:
    cmp eax, edx
    jae .Lsbr_map_noise_next
    mov r9d, eax
    sub r9d, r15d
    movsd [rdi + r9*8], xmm0
    inc eax
    jmp .Lsbr_map_noise_fill
.Lsbr_map_noise_next:
    inc ecx
    jmp .Lsbr_map_noise_band
.Lsbr_map_harmonic:
    imul eax, r12d, 48
    lea rdi, [rsi + rax + 48 + SC_S_INDEX]   # row e + 1
    cmp dword ptr [rsi + SC_HARMONIC_FLAG], 0
    je .Lsbr_map_sines
    xor ecx, ecx
.Lsbr_map_harmonic_band:
    cmp ecx, [rbx + SE_N_HIGH]
    jae .Lsbr_map_sines
    movzx eax, byte ptr [rbx + SE_F_HIGH + rcx]
    movzx edx, byte ptr [rbx + SE_F_HIGH + rcx + 1]
    add eax, edx
    shr eax, 1
    sub eax, r15d                         # midpoint - kx'
    xor edx, edx
    cmp byte ptr [rsi + SC_HARMONIC + rcx], 0
    je .Lsbr_map_harmonic_store
    cmp r12d, [rsi + SC_E_A1]
    jge .Lsbr_map_harmonic_on
    cmp byte ptr [rsi + SC_S_INDEX + rax], 1
    jne .Lsbr_map_harmonic_store
.Lsbr_map_harmonic_on:
    mov edx, 1
.Lsbr_map_harmonic_store:
    mov [rdi + rax], dl
    inc ecx
    jmp .Lsbr_map_harmonic_band
.Lsbr_map_sines:
    imul eax, r12d, 48
    lea r8, [r14 + rax + SB_S_MAPPED]
    xor ecx, ecx
.Lsbr_map_sine_band:
    cmp ecx, [rsp + 36]
    jae .Lsbr_map_env_next
    movzx eax, byte ptr [r13 + rcx]
    movzx edx, byte ptr [r13 + rcx + 1]
    xor r9d, r9d                          # any sinusoid in the band
    mov r10d, eax
.Lsbr_map_sine_any:
    cmp r10d, edx
    jae .Lsbr_map_sine_fill
    mov r11d, r10d
    sub r11d, r15d
    or r9b, [rdi + r11]
    inc r10d
    jmp .Lsbr_map_sine_any
.Lsbr_map_sine_fill:
    test r9b, r9b
    setnz r9b
.Lsbr_map_sine_set:
    cmp eax, edx
    jae .Lsbr_map_sine_next
    mov r11d, eax
    sub r11d, r15d
    mov [r8 + r11], r9b
    inc eax
    jmp .Lsbr_map_sine_set
.Lsbr_map_sine_next:
    inc ecx
    jmp .Lsbr_map_sine_band
.Lsbr_map_env_next:
    inc dword ptr [rsp + 32]
    jmp .Lsbr_map_env
.Lsbr_map_done:
    imul eax, [rsi + SC_NUM_ENV], 48      # row 0 keeps the last envelope's map
    lea rdx, [rsi + rax + SC_S_INDEX]
    xor ecx, ecx
.Lsbr_map_keep:
    mov rax, [rdx + rcx]
    mov [rsi + SC_S_INDEX + rcx], rax
    add ecx, 8
    cmp ecx, 48
    jb .Lsbr_map_keep
    mov eax, 1
    jmp .Lsbr_map_return
.Lsbr_map_bad:
    xor eax, eax
.Lsbr_map_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_mapping

# Current envelope estimation (ISO 4.6.18.7.3) for element RCX, channel RDX:
# mean energy per subband (bs_interpol_freq) or per band.
# Locals: 32 bands.
LOCALFN sbr_estimate
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov r14, [rip + sbr_scratch]
    mov r15d, [rbx + SE_KX1]
    xor r12d, r12d
.Lsbr_est_env:
    cmp r12d, [rsi + SC_NUM_ENV]
    jae .Lsbr_est_done
    movzx eax, byte ptr [rsi + SC_T_ENV + r12]
    lea r8d, [rax*2 + 2]                  # first slot
    movzx eax, byte ptr [rsi + SC_T_ENV + r12 + 1]
    lea r9d, [rax*2 + 2]                  # end slot
    imul eax, r12d, 384
    lea rdi, [r14 + rax + SB_E_CURR]
    cmp dword ptr [rbx + SE_INTERPOL], 0
    je .Lsbr_est_bands
    mov eax, r9d
    sub eax, r8d
    cvtsi2sd xmm2, eax
    xor ecx, ecx                          # m
.Lsbr_est_subband:
    cmp ecx, [rbx + SE_M1]
    jae .Lsbr_est_next
    lea eax, [rcx + r15]
    imul eax, eax, 640
    lea r10, [r14 + rax + SB_X_HIGH]
    xorpd xmm0, xmm0
    mov edx, r8d
.Lsbr_est_subband_slot:
    cmp edx, r9d
    jae .Lsbr_est_subband_store
    mov eax, edx
    shl eax, 4
    movsd xmm1, [r10 + rax]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movsd xmm1, [r10 + rax + 8]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc edx
    jmp .Lsbr_est_subband_slot
.Lsbr_est_subband_store:
    divsd xmm0, xmm2
    movsd [rdi + rcx*8], xmm0
    inc ecx
    jmp .Lsbr_est_subband
.Lsbr_est_bands:
    movzx eax, byte ptr [rsi + SC_FREQ_RES + r12 + 1]
    lea r13, [rbx + SE_F_LOW]
    mov edx, [rbx + SE_N_LOW]
    test eax, eax
    jz .Lsbr_est_band_table
    lea r13, [rbx + SE_F_HIGH]
    mov edx, [rbx + SE_N_HIGH]
.Lsbr_est_band_table:
    mov [rsp + 32], edx
    xor r11d, r11d                        # band p
.Lsbr_est_band:
    cmp r11d, [rsp + 32]
    jae .Lsbr_est_next
    xorpd xmm0, xmm0
    movzx ecx, byte ptr [r13 + r11]       # k
.Lsbr_est_band_subband:
    movzx eax, byte ptr [r13 + r11 + 1]
    cmp ecx, eax
    jae .Lsbr_est_band_store
    imul eax, ecx, 640
    lea r10, [r14 + rax + SB_X_HIGH]
    mov edx, r8d
.Lsbr_est_band_slot:
    cmp edx, r9d
    jae .Lsbr_est_band_subband_next
    mov eax, edx
    shl eax, 4
    movsd xmm1, [r10 + rax]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movsd xmm1, [r10 + rax + 8]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc edx
    jmp .Lsbr_est_band_slot
.Lsbr_est_band_subband_next:
    inc ecx
    jmp .Lsbr_est_band_subband
.Lsbr_est_band_store:
    movzx ecx, byte ptr [r13 + r11]
    movzx eax, byte ptr [r13 + r11 + 1]
    mov edx, eax
    sub edx, ecx
    mov r10d, r9d
    sub r10d, r8d
    imul edx, r10d
    cvtsi2sd xmm1, edx
    divsd xmm0, xmm1
.Lsbr_est_band_fill:
    cmp ecx, eax
    jae .Lsbr_est_band_next
    mov edx, ecx
    sub edx, r15d
    movsd [rdi + rdx*8], xmm0
    inc ecx
    jmp .Lsbr_est_band_fill
.Lsbr_est_band_next:
    inc r11d
    jmp .Lsbr_est_band
.Lsbr_est_next:
    inc r12d
    jmp .Lsbr_est_env
.Lsbr_est_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_estimate

# Gains, noise and sinusoid levels with limiter and boost (ISO 4.6.18.7.4)
# for element RCX, channel RDX. Locals: 64 delta, 68 limiter band, 72 first
# subband, 76 end subband; XMM6 gain_max, XMM7 sum of the original energy.
LOCALFN sbr_gains
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    movdqu [rsp + 32], xmm6
    movdqu [rsp + 48], xmm7
    mov rbx, rcx
    mov rsi, rdx
    mov r14, [rip + sbr_scratch]
    mov r15d, [rbx + SE_KX1]
    xor r12d, r12d
.Lsbr_gain_env:
    cmp r12d, [rsi + SC_NUM_ENV]
    jae .Lsbr_gain_done
    xor eax, eax
    cmp r12d, [rsi + SC_E_A0]
    je .Lsbr_gain_delta
    cmp r12d, [rsi + SC_E_A1]
    je .Lsbr_gain_delta
    mov eax, 1
.Lsbr_gain_delta:
    mov [rsp + 64], eax
    imul r13d, r12d, 384                  # row offset
    lea r11, [rbx + r13]                  # element rows (gains and levels)
    add r13, r14
    imul eax, r12d, 48
    lea rdi, [r14 + rax + SB_S_MAPPED]
    lea r10, [rsi + rax + 48 + SC_S_INDEX]   # sinusoids of envelope e + 1
    mov dword ptr [rsp + 68], 0
.Lsbr_gain_band:
    mov eax, [rsp + 68]
    cmp eax, [rbx + SE_N_LIM]
    jae .Lsbr_gain_env_next
    movzx ecx, byte ptr [rbx + SE_F_LIM + rax]
    sub ecx, r15d
    mov [rsp + 72], ecx
    movzx ecx, byte ptr [rbx + SE_F_LIM + rax + 1]
    sub ecx, r15d
    mov [rsp + 76], ecx
    xorpd xmm7, xmm7                      # sum E_orig
    xorpd xmm6, xmm6                      # sum E_curr
    mov ecx, [rsp + 72]
.Lsbr_gain_first:
    cmp ecx, [rsp + 76]
    jae .Lsbr_gain_limit
    movsd xmm0, [r13 + rcx*8 + SB_E_ORIG]
    movsd xmm1, [r13 + rcx*8 + SB_Q_MAPPED]
    movsd xmm2, [r13 + rcx*8 + SB_E_CURR]
    addsd xmm7, xmm0
    addsd xmm6, xmm2
    movsd xmm3, [rip + sbr_one]
    addsd xmm3, xmm1                      # 1 + Q
    movsd xmm4, xmm0
    divsd xmm4, xmm3                      # temp = E_orig / (1 + Q)
    movsd xmm5, xmm4
    mulsd xmm5, xmm1
    sqrtsd xmm5, xmm5
    movsd [r11 + rcx*8 + SE_Q_M], xmm5
    xorpd xmm5, xmm5
    cmp byte ptr [r10 + rcx], 0
    je .Lsbr_gain_sine
    sqrtsd xmm5, xmm4
.Lsbr_gain_sine:
    movsd [r11 + rcx*8 + SE_S_M], xmm5
    addsd xmm2, [rip + sbr_one]           # 1 + E_curr
    cmp byte ptr [rdi + rcx], 0
    jne .Lsbr_gain_mapped
    cmp dword ptr [rsp + 64], 0
    je .Lsbr_gain_plain
    mulsd xmm2, xmm3                      # (1 + E_curr)(1 + Q delta)
.Lsbr_gain_plain:
    divsd xmm0, xmm2
    jmp .Lsbr_gain_root
.Lsbr_gain_mapped:
    mulsd xmm0, xmm1
    mulsd xmm2, xmm3
    divsd xmm0, xmm2
.Lsbr_gain_root:
    sqrtsd xmm0, xmm0
    addsd xmm0, [rip + sbr_float_min]
    movsd [r11 + rcx*8 + SE_GAIN], xmm0
    inc ecx
    jmp .Lsbr_gain_first
.Lsbr_gain_limit:
    movsd xmm0, [rip + sbr_float_epsilon]
    addsd xmm0, xmm7
    movsd xmm1, [rip + sbr_float_epsilon]
    addsd xmm1, xmm6
    divsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    mov eax, [rbx + SE_LIM_GAINS]
    lea rdx, [rip + sbr_limiter_gains]
    mulsd xmm0, [rdx + rax*8]
    minsd xmm0, [rip + sbr_gain_cap]
    movsd xmm6, xmm0                      # gain_max
    xorpd xmm5, xmm5                      # sum after limiting
    mov ecx, [rsp + 72]
.Lsbr_gain_second:
    cmp ecx, [rsp + 76]
    jae .Lsbr_gain_boost
    movsd xmm0, [r11 + rcx*8 + SE_GAIN]
    movsd xmm1, [r11 + rcx*8 + SE_Q_M]
    movsd xmm2, xmm1
    mulsd xmm2, xmm6
    divsd xmm2, xmm0
    minsd xmm1, xmm2
    movsd [r11 + rcx*8 + SE_Q_M], xmm1
    minsd xmm0, xmm6
    movsd [r11 + rcx*8 + SE_GAIN], xmm0
    mulsd xmm0, xmm0
    mulsd xmm0, [r13 + rcx*8 + SB_E_CURR]
    addsd xmm5, xmm0
    movsd xmm0, [r11 + rcx*8 + SE_S_M]
    movsd xmm3, xmm0
    mulsd xmm3, xmm3
    addsd xmm5, xmm3
    cmp dword ptr [rsp + 64], 0
    je .Lsbr_gain_second_next
    xorpd xmm3, xmm3
    ucomisd xmm0, xmm3
    jne .Lsbr_gain_second_next
    jp .Lsbr_gain_second_next
    mulsd xmm1, xmm1
    addsd xmm5, xmm1
.Lsbr_gain_second_next:
    inc ecx
    jmp .Lsbr_gain_second
.Lsbr_gain_boost:
    movsd xmm0, [rip + sbr_float_epsilon]
    addsd xmm0, xmm7
    movsd xmm1, [rip + sbr_float_epsilon]
    addsd xmm1, xmm5
    divsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    minsd xmm0, [rip + sbr_boost_cap]
    mov ecx, [rsp + 72]
.Lsbr_gain_third:
    cmp ecx, [rsp + 76]
    jae .Lsbr_gain_band_next
    movsd xmm1, [r11 + rcx*8 + SE_GAIN]
    mulsd xmm1, xmm0
    movsd [r11 + rcx*8 + SE_GAIN], xmm1
    movsd xmm1, [r11 + rcx*8 + SE_Q_M]
    mulsd xmm1, xmm0
    movsd [r11 + rcx*8 + SE_Q_M], xmm1
    movsd xmm1, [r11 + rcx*8 + SE_S_M]
    mulsd xmm1, xmm0
    movsd [r11 + rcx*8 + SE_S_M], xmm1
    inc ecx
    jmp .Lsbr_gain_third
.Lsbr_gain_band_next:
    inc dword ptr [rsp + 68]
    jmp .Lsbr_gain_band
.Lsbr_gain_env_next:
    inc r12d
    jmp .Lsbr_gain_env
.Lsbr_gain_done:
    movdqu xmm6, [rsp + 32]
    movdqu xmm7, [rsp + 48]
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_gains

# Copies 48 doubles from R9 to R8. Clobbers RAX, XMM0.
LOCALFN sbr_copy48
    xor eax, eax
.Lsbr_copy48_next:
    movups xmm0, [r9 + rax]
    movups [r8 + rax], xmm0
    add eax, 16
    cmp eax, 384
    jb .Lsbr_copy48_next
    ret
ENDFN sbr_copy48

# HF assembly (ISO 4.6.18.7.5) for element RCX, channel RDX into Y[Ypos]:
# smoothed gains on X_high plus noise or sinusoids. Locals: 32 h_SL,
# 36 noise index, 40 sine index, 44 envelope is a transient (e_a), 48 slot,
# 52 slot end, 56 envelope.
LOCALFN sbr_assemble
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov r14, [rip + sbr_scratch]
    mov r15d, [rbx + SE_KX1]
    imul eax, [rsi + SC_YPOS], 38*64*16
    lea r13, [rsi + rax + SC_Y]
    xor eax, eax
    cmp dword ptr [rbx + SE_SMOOTHING], 0
    jne .Lsbr_asm_hsl
    mov eax, 4
.Lsbr_asm_hsl:
    mov [rsp + 32], eax
    movzx edi, byte ptr [rsi + SC_T_ENV]
    add edi, edi                          # 2 t_E(0)
    cmp dword ptr [rbx + SE_RESET], 0
    je .Lsbr_asm_history
    xor r12d, r12d
.Lsbr_asm_reset:
    cmp r12d, [rsp + 32]
    jae .Lsbr_asm_rows
    lea eax, [rdi + r12]
    imul eax, eax, 384
    lea r8, [rsi + rax + SC_G_TEMP]
    lea r9, [rbx + SE_GAIN]
    call sbr_copy48
    lea eax, [rdi + r12]
    imul eax, eax, 384
    lea r8, [rsi + rax + SC_Q_TEMP]
    lea r9, [rbx + SE_Q_M]
    call sbr_copy48
    inc r12d
    jmp .Lsbr_asm_reset
.Lsbr_asm_history:
    cmp dword ptr [rsp + 32], 0
    je .Lsbr_asm_rows
    xor r12d, r12d
.Lsbr_asm_history_row:
    mov ecx, [rsi + SC_T_ENV_OLD]
    lea ecx, [rcx*2 + r12]
    imul ecx, ecx, 384
    lea eax, [rdi + r12]
    imul eax, eax, 384
    lea r8, [rsi + rax + SC_G_TEMP]
    lea r9, [rsi + rcx + SC_G_TEMP]
    call sbr_copy48
    mov ecx, [rsi + SC_T_ENV_OLD]
    lea ecx, [rcx*2 + r12]
    imul ecx, ecx, 384
    lea eax, [rdi + r12]
    imul eax, eax, 384
    lea r8, [rsi + rax + SC_Q_TEMP]
    lea r9, [rsi + rcx + SC_Q_TEMP]
    call sbr_copy48
    inc r12d
    cmp r12d, 4
    jb .Lsbr_asm_history_row
.Lsbr_asm_rows:
    xor r12d, r12d                        # envelope
.Lsbr_asm_rows_env:
    cmp r12d, [rsi + SC_NUM_ENV]
    jae .Lsbr_asm_slots
    movzx edi, byte ptr [rsi + SC_T_ENV + r12]
    add edi, edi
.Lsbr_asm_rows_slot:
    movzx eax, byte ptr [rsi + SC_T_ENV + r12 + 1]
    add eax, eax
    cmp edi, eax
    jae .Lsbr_asm_rows_next
    mov eax, edi
    add eax, [rsp + 32]
    imul eax, eax, 384
    imul ecx, r12d, 384
    lea r8, [rsi + rax + SC_G_TEMP]
    lea r9, [rbx + rcx + SE_GAIN]
    call sbr_copy48
    mov eax, edi
    add eax, [rsp + 32]
    imul eax, eax, 384
    imul ecx, r12d, 384
    lea r8, [rsi + rax + SC_Q_TEMP]
    lea r9, [rbx + rcx + SE_Q_M]
    call sbr_copy48
    inc edi
    jmp .Lsbr_asm_rows_slot
.Lsbr_asm_rows_next:
    inc r12d
    jmp .Lsbr_asm_rows_env
.Lsbr_asm_slots:
    mov eax, [rsi + SC_INDEX_NOISE]
    mov [rsp + 36], eax
    mov eax, [rsi + SC_INDEX_SINE]
    mov [rsp + 40], eax
    mov dword ptr [rsp + 56], 0
.Lsbr_asm_env:
    mov r12d, [rsp + 56]
    cmp r12d, [rsi + SC_NUM_ENV]
    jae .Lsbr_asm_done
    mov eax, 1
    cmp r12d, [rsi + SC_E_A0]
    je .Lsbr_asm_transient
    cmp r12d, [rsi + SC_E_A1]
    je .Lsbr_asm_transient
    xor eax, eax
.Lsbr_asm_transient:
    mov [rsp + 44], eax
    movzx eax, byte ptr [rsi + SC_T_ENV + r12]
    add eax, eax
    mov [rsp + 48], eax
    movzx eax, byte ptr [rsi + SC_T_ENV + r12 + 1]
    add eax, eax
    mov [rsp + 52], eax
.Lsbr_asm_slot:
    mov edi, [rsp + 48]                   # slot i
    cmp edi, [rsp + 52]
    jae .Lsbr_asm_env_next
    # Gain and noise level rows: smoothed or as they are.
    mov eax, edi
    add eax, [rsp + 32]
    imul eax, eax, 384
    lea r8, [rsi + rax + SC_G_TEMP]       # g_temp[i + h_SL]
    imul eax, edi, 384
    lea r9, [rsi + rax + SC_Q_TEMP]       # q_temp[i]
    cmp dword ptr [rsp + 32], 0
    je .Lsbr_asm_gains
    cmp dword ptr [rsp + 44], 0
    jne .Lsbr_asm_gains
    xor ecx, ecx                          # subband m
.Lsbr_asm_smooth:
    cmp ecx, [rbx + SE_M1]
    jae .Lsbr_asm_smoothed
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    xor edx, edx                          # j
    lea r10, [rip + sbr_smooth]
.Lsbr_asm_smooth_tap:
    lea eax, [rdi + 4]
    sub eax, edx
    imul eax, eax, 384
    lea r11, [rsi + rax + SC_G_TEMP]
    movsd xmm2, [r11 + rcx*8]
    mulsd xmm2, [r10 + rdx*8]
    addsd xmm0, xmm2
    lea r11, [rsi + rax + SC_Q_TEMP]
    movsd xmm2, [r11 + rcx*8]
    mulsd xmm2, [r10 + rdx*8]
    addsd xmm1, xmm2
    inc edx
    cmp edx, 5
    jb .Lsbr_asm_smooth_tap
    movsd [r14 + rcx*8 + SB_G_FILT], xmm0
    movsd [r14 + rcx*8 + SB_Q_FILT], xmm1
    inc ecx
    jmp .Lsbr_asm_smooth
.Lsbr_asm_smoothed:
    lea r8, [r14 + SB_G_FILT]
    lea r9, [r14 + SB_Q_FILT]
.Lsbr_asm_gains:
    # Y[i][kx + m] = X_high[kx + m][i + 2] g_filt[m]
    mov eax, edi
    shl eax, 10
    lea r10, [r13 + rax]
    mov eax, r15d
    shl eax, 4
    add r10, rax                          # Y row at kx
    imul eax, r15d, 640
    lea r11, [r14 + rax + SB_X_HIGH + 32]
    mov eax, edi
    shl eax, 4
    add r11, rax                          # X_high[kx][i + 2]
    xor ecx, ecx
.Lsbr_asm_gain:
    cmp ecx, [rbx + SE_M1]
    jae .Lsbr_asm_add
    movsd xmm0, [r8 + rcx*8]
    imul eax, ecx, 640
    movsd xmm1, [r11 + rax]
    mulsd xmm1, xmm0
    movsd xmm2, [r11 + rax + 8]
    mulsd xmm2, xmm0
    mov eax, ecx
    shl eax, 4
    movsd [r10 + rax], xmm1
    movsd [r10 + rax + 8], xmm2
    inc ecx
    jmp .Lsbr_asm_gain
.Lsbr_asm_add:
    imul eax, r12d, 384
    lea r11, [rbx + rax + SE_S_M]         # s_m[e]
    lea rdx, [rip + sbr_noise_table]
    xor ecx, ecx
.Lsbr_asm_component:
    cmp ecx, [rbx + SE_M1]
    jae .Lsbr_asm_slot_next
    mov eax, ecx
    shl eax, 4
    movsd xmm0, [r11 + rcx*8]             # s_m
    cmp dword ptr [rsp + 44], 0
    jne .Lsbr_asm_sine
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jne .Lsbr_asm_sine
    jp .Lsbr_asm_sine
    mov r8d, [rsp + 36]                   # noise: q_filt[m] V[(index + m + 1) & 511]
    add r8d, ecx
    inc r8d
    and r8d, 511
    movsd xmm2, [r9 + rcx*8]
    cvtss2sd xmm1, [rdx + r8*8]
    mulsd xmm1, xmm2
    addsd xmm1, [r10 + rax]
    movsd [r10 + rax], xmm1
    cvtss2sd xmm1, [rdx + r8*8 + 4]
    mulsd xmm1, xmm2
    addsd xmm1, [r10 + rax + 8]
    movsd [r10 + rax + 8], xmm1
    jmp .Lsbr_asm_component_next
.Lsbr_asm_sine:
    # phi_sin: +1, +j(-1)^k, -1, -j(-1)^k for sine index 0-3, k = kx + m.
    mov r8d, [rsp + 40]
    test r8d, 2
    jz .Lsbr_asm_sine_sign
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movsd xmm0, xmm1
.Lsbr_asm_sine_sign:
    test r8d, 1
    jz .Lsbr_asm_sine_real
    lea r8d, [rcx + r15]
    test r8d, 1
    jz .Lsbr_asm_sine_imaginary
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movsd xmm0, xmm1
.Lsbr_asm_sine_imaginary:
    addsd xmm0, [r10 + rax + 8]
    movsd [r10 + rax + 8], xmm0
    jmp .Lsbr_asm_component_next
.Lsbr_asm_sine_real:
    addsd xmm0, [r10 + rax]
    movsd [r10 + rax], xmm0
.Lsbr_asm_component_next:
    inc ecx
    jmp .Lsbr_asm_component
.Lsbr_asm_slot_next:
    mov eax, [rsp + 36]
    add eax, [rbx + SE_M1]
    and eax, 511
    mov [rsp + 36], eax
    mov eax, [rsp + 40]
    inc eax
    and eax, 3
    mov [rsp + 40], eax
    inc dword ptr [rsp + 48]
    jmp .Lsbr_asm_slot
.Lsbr_asm_env_next:
    inc dword ptr [rsp + 56]
    jmp .Lsbr_asm_env
.Lsbr_asm_done:
    mov eax, [rsp + 36]
    mov [rsi + SC_INDEX_NOISE], eax
    mov eax, [rsp + 40]
    mov [rsi + SC_INDEX_SINE], eax
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_assemble

# Synthesis input X (ISO 4.6.18.8) for element RCX, channel RDX: low band
# and adjusted HF, the first slots continuing the previous frame's grid.
LOCALFN sbr_x_gen
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov rbx, rcx
    mov rsi, rdx
    mov r14, [rip + sbr_scratch]
    lea rdi, [r14 + SB_X]
    xor eax, eax
    mov ecx, 32*128
    rep stosq
    mov r12d, [rsi + SC_T_ENV_OLD]
    add r12d, r12d
    sub r12d, 32
    jge .Lsbr_x_temp
    xor r12d, r12d                        # i_Temp
.Lsbr_x_temp:
    imul eax, [rsi + SC_YPOS], 38*64*16
    lea r13, [rsi + rax + SC_Y]           # Y new
    lea r11, [rsi + SC_Y]
    mov ecx, [rsi + SC_YPOS]
    xor ecx, 1
    imul ecx, ecx, 38*64*16
    add r11, rcx                          # Y old
    # Slots before i_Temp: the previous frame's subband split.
    xor ecx, ecx                          # k
.Lsbr_x_old_low:
    cmp ecx, [rbx + SE_KX0]
    jae .Lsbr_x_old_high
    imul r8d, ecx, 640
    lea r8, [r14 + r8 + SB_X_LOW + 32]
    xor edx, edx
.Lsbr_x_old_low_slot:
    cmp edx, r12d
    jae .Lsbr_x_old_low_next
    mov eax, edx
    shl eax, 4
    movsd xmm0, [r8 + rax]
    movsd xmm1, [r8 + rax + 8]
    mov eax, edx
    shl eax, 10
    lea r9, [r14 + rax + SB_X]
    movsd [r9 + rcx*8], xmm0
    movsd [r9 + rcx*8 + 512], xmm1
    inc edx
    jmp .Lsbr_x_old_low_slot
.Lsbr_x_old_low_next:
    inc ecx
    jmp .Lsbr_x_old_low
.Lsbr_x_old_high:
    mov r10d, [rbx + SE_KX0]
    add r10d, [rbx + SE_M0]
.Lsbr_x_old_high_band:
    cmp ecx, r10d
    jae .Lsbr_x_new_low_start
    xor edx, edx
.Lsbr_x_old_high_slot:
    cmp edx, r12d
    jae .Lsbr_x_old_high_next
    lea eax, [rdx + 32]
    shl eax, 6
    add eax, ecx
    shl eax, 4
    movsd xmm0, [r11 + rax]
    movsd xmm1, [r11 + rax + 8]
    mov eax, edx
    shl eax, 10
    lea r9, [r14 + rax + SB_X]
    movsd [r9 + rcx*8], xmm0
    movsd [r9 + rcx*8 + 512], xmm1
    inc edx
    jmp .Lsbr_x_old_high_slot
.Lsbr_x_old_high_next:
    inc ecx
    jmp .Lsbr_x_old_high_band
.Lsbr_x_new_low_start:
    xor ecx, ecx
.Lsbr_x_new_low:
    cmp ecx, [rbx + SE_KX1]
    jae .Lsbr_x_new_high
    imul r8d, ecx, 640
    lea r8, [r14 + r8 + SB_X_LOW + 32]
    mov edx, r12d
.Lsbr_x_new_low_slot:
    cmp edx, 32
    jae .Lsbr_x_new_low_next
    mov eax, edx
    shl eax, 4
    movsd xmm0, [r8 + rax]
    movsd xmm1, [r8 + rax + 8]
    mov eax, edx
    shl eax, 10
    lea r9, [r14 + rax + SB_X]
    movsd [r9 + rcx*8], xmm0
    movsd [r9 + rcx*8 + 512], xmm1
    inc edx
    jmp .Lsbr_x_new_low_slot
.Lsbr_x_new_low_next:
    inc ecx
    jmp .Lsbr_x_new_low
.Lsbr_x_new_high:
    mov r10d, [rbx + SE_KX1]
    add r10d, [rbx + SE_M1]
.Lsbr_x_new_high_band:
    cmp ecx, r10d
    jae .Lsbr_x_done
    mov edx, r12d
.Lsbr_x_new_high_slot:
    cmp edx, 32
    jae .Lsbr_x_new_high_next
    mov eax, edx
    shl eax, 6
    add eax, ecx
    shl eax, 4
    movsd xmm0, [r13 + rax]
    movsd xmm1, [r13 + rax + 8]
    mov eax, edx
    shl eax, 10
    lea r9, [r14 + rax + SB_X]
    movsd [r9 + rcx*8], xmm0
    movsd [r9 + rcx*8 + 512], xmm1
    inc edx
    jmp .Lsbr_x_new_high_slot
.Lsbr_x_new_high_next:
    inc ecx
    jmp .Lsbr_x_new_high_band
.Lsbr_x_done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_x_gen

# SBR for channel element ECX of type EDX (0 SCE, 1 CPE, 3 LFE) whose core
# output channels start at R8D: each 1024-sample channel in AM_PCM becomes
# 2048 samples at twice the rate (FFmpeg ff_sbr_apply).
LOCALFN sbr_apply
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    lea rax, [rip + sbr_elements]
    mov rbx, [rax + rcx*8]
    mov r12d, edx
    mov r13d, r8d
    cmp dword ptr [rbx + SE_START], 0
    je .Lsbr_apply_push
    cmp dword ptr [rbx + SE_READY], 0
    jne .Lsbr_apply_push
    mov rcx, rbx                          # no data for the header: pure upsampling
    call sbr_turnoff
.Lsbr_apply_push:
    cmp dword ptr [rbx + SE_PUSHED], 0
    jne .Lsbr_apply_pushed
    mov eax, [rbx + SE_KX1]
    mov [rbx + SE_KX0], eax
    mov eax, [rbx + SE_M1]
    mov [rbx + SE_M0], eax
    jmp .Lsbr_apply_dequant
.Lsbr_apply_pushed:
    mov dword ptr [rbx + SE_PUSHED], 0
.Lsbr_apply_dequant:
    cmp dword ptr [rbx + SE_START], 0
    je .Lsbr_apply_channels
    mov rcx, rbx
    mov edx, r12d
    call sbr_dequant
    mov dword ptr [rbx + SE_READY], 0
.Lsbr_apply_channels:
    mov edi, 1
    cmp r12d, 1
    jne .Lsbr_apply_count
    mov edi, 2
.Lsbr_apply_count:
    xor esi, esi
.Lsbr_apply_channel:
    imul eax, esi, SC_SIZE
    lea r14, [rbx + rax + SE_CH]
    lea eax, [r13 + rsi]
    shl eax, 13
    mov rdx, [rip + aac_memory]
    lea rdx, [rdx + rax + AM_PCM]
    mov [rsp + 32], rdx
    mov rcx, r14
    call sbr_analysis
    mov rcx, rbx
    mov rdx, r14
    call sbr_lf_gen
    xor dword ptr [r14 + SC_YPOS], 1
    cmp dword ptr [rbx + SE_START], 0
    je .Lsbr_apply_synthesis
    mov rcx, rbx
    call sbr_inverse_filter
    mov rcx, rbx
    mov rdx, r14
    call sbr_chirp
    mov rcx, rbx
    mov rdx, r14
    call sbr_hf_gen
    mov rcx, rbx
    mov rdx, r14
    call sbr_mapping
    test eax, eax
    jnz .Lsbr_apply_adjust
    mov rcx, rbx
    call sbr_turnoff
    jmp .Lsbr_apply_synthesis
.Lsbr_apply_adjust:
    mov rcx, rbx
    mov rdx, r14
    call sbr_estimate
    mov rcx, rbx
    mov rdx, r14
    call sbr_gains
    mov rcx, rbx
    mov rdx, r14
    call sbr_assemble
.Lsbr_apply_synthesis:
    mov rcx, rbx
    mov rdx, r14
    call sbr_x_gen
    mov rcx, r14
    mov rdx, [rsp + 32]
    call sbr_synthesis
    inc esi
    cmp esi, edi
    jb .Lsbr_apply_channel
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN sbr_apply
