# Original WavPack decoder in x86-64 assembly. MIT, see LICENSE.
# WavPack 4 and 5 blocks (versions 0x402-0x410): lossless and hybrid lossy
# integer audio of 1-32 bits, 32-bit float, extra-bit streams, shifted and
# "and/or" padded integers, false stereo and multichannel frames of mono and
# stereo blocks. Decorrelation, entropy decoding and output conversion follow
# FFmpeg's decoder, which the tests compare against; the exp2/log2 tables
# are src/wavpack_tables.inc. Track mode: native .wv files (frames of blocks
# from an initial to a final block) and Matroska A_WAVPACK4 frames (block
# headers reduced to sample count, flags and CRC) give one frame per packet.
# A failed CRC stops decoding. DSD blocks and correction (.wvc) data are not
# decoded.
.include "lamp.inc"
.globl wv_probe, wv_open, wv_track_open, wv_track_samples, wv_track_decode, wv_track_reset, wv_track_close

.equ WV_MALFORMED, 100
.equ WV_UNSUPPORTED, 101
.equ WV_MAX_SAMPLES, 150000         # per block (FFmpeg's limit)
.equ WV_STRIDE, 150016*4            # bytes per decoded channel
.equ WV_CHANNELS, 8
.equ TK_WAVPACK, 9
.equ CODEC_WAVPACK, 12
.equ F_MONO, 4
.equ F_HYBRID, 8
.equ F_JOINT, 0x10
.equ F_FLOAT, 0x80
.equ F_HYBRID_BITRATE, 0x200
.equ F_INITIAL, 0x800
.equ F_FINAL, 0x1000
.equ F_FALSE_STEREO, 0x40000000
.equ F_DSD, 0x80000000
# Decorrelation pass.
.equ DC_VALUE, 0
.equ DC_DELTA, 4
.equ DC_WA, 8
.equ DC_WB, 12
.equ DC_SA, 16                      # 8 dwords
.equ DC_SB, 48
.equ DC_SIZE, 80
# Entropy state per channel.
.equ CH_MEDIAN, 0                   # 3 dwords
.equ CH_SLOW, 12
.equ CH_ACC, 16
.equ CH_DELTA, 20
.equ CH_LIMIT, 24
.equ CH_SIZE, 32
# Bit reader: data, size in bits, position.
.equ BR_DATA, 0
.equ BR_BITS, 8
.equ BR_POS, 12
# Metadata seen in a block.
.equ GOT_TERMS, 1
.equ GOT_WEIGHTS, 2
.equ GOT_SAMPLES, 4
.equ GOT_ENTROPY, 8
.equ GOT_HYBRID, 16
.equ GOT_FLOAT, 32
.equ GOT_DATA, 64

RODATA
.include "wavpack_tables.inc"
.p2align 2
wv_rates: .long 6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000
    .long 64000, 88200, 96000, 192000
wv_scale16: .float 3.0517578125e-5        # 2^-15
wv_scale32: .float 4.656612873077393e-10  # 2^-31

.data
wv_buffers: .quad 0                 # WV_CHANNELS decoded channels (int32 or float)
wv_matroska: .long 0                # packets in the Matroska layout
wv_channels: .long 0
wv_format: .long 0                  # 0 16-bit domain, 1 32-bit, 2 float
wv_key: .long 0                     # sample format bits of the first block's flags

.bss
.p2align 4
wv_main: .zero 16                   # bit readers
wv_extra: .zero 16
wv_decorr: .zero 16*DC_SIZE
wv_ch: .zero 2*CH_SIZE
wv_terms: .zero 4
wv_flags: .zero 4
wv_samples: .zero 4
wv_crc: .zero 4
wv_stereo: .zero 4
wv_stereo_in: .zero 4
wv_hybrid: .zero 4
wv_bitrate: .zero 4                 # hybrid bitrate mode
wv_extra_bits: .zero 4
wv_and: .zero 4
wv_or: .zero 4
wv_shift: .zero 4
wv_post_shift: .zero 4
wv_maxclip: .zero 4
wv_minclip: .zero 4
wv_got_extra: .zero 4
wv_crc_extra: .zero 4
wv_crc_extra_want: .zero 4
wv_float_flag: .zero 4
wv_float_shift: .zero 4
wv_float_exp: .zero 4
wv_one: .zero 4
wv_zero: .zero 4
wv_zeroes: .zero 4
wv_got: .zero 4
wv_block_rate: .zero 4              # ID_SAMPLE_RATE
wv_block_chan: .zero 4              # ID_CHANNEL_INFO
wv_block_mask: .zero 4
wv_iter: .zero 32                   # block iterator: position, end, frame samples
wv_out: .zero 16                    # left and right output channels

.text
# ECX=signed 16-bit value -> EAX=FFmpeg wp_exp2. Clobbers RCX, RDX, R8.
LOCALFN wv_exp2
    movsx ecx, cx
    xor r8d, r8d
    test ecx, ecx
    jns .Lwv_exp2_positive
    neg ecx
    mov r8d, 1
.Lwv_exp2_positive:
    movzx eax, cl
    lea rdx, [rip + wv_exp2_table]
    movzx eax, byte ptr [rdx + rax]
    or eax, 0x100
    shr ecx, 8
    cmp ecx, 31
    ja .Lwv_exp2_huge
    cmp ecx, 9
    jbe .Lwv_exp2_down
    sub ecx, 9
    shl eax, cl
    jmp .Lwv_exp2_sign
.Lwv_exp2_down:
    neg ecx
    add ecx, 9
    shr eax, cl
.Lwv_exp2_sign:
    test r8d, r8d
    jz .Lwv_exp2_done
    neg eax
.Lwv_exp2_done:
    ret
.Lwv_exp2_huge:
    mov eax, 0x80000000
    ret
ENDFN wv_exp2

# ECX=unsigned value -> EAX=FFmpeg wp_log2. Clobbers RCX, RDX, R8.
LOCALFN wv_log2
    xor eax, eax
    test ecx, ecx
    jz .Lwv_log2_done
    mov eax, 256
    cmp ecx, 1
    je .Lwv_log2_done
    mov eax, ecx
    shr eax, 9
    add ecx, eax
    bsr edx, ecx
    inc edx                               # bits
    mov r8d, ecx
    cmp edx, 9
    jae .Lwv_log2_high
    mov ecx, 9
    sub ecx, edx
    shl r8d, cl
    jmp .Lwv_log2_entry
.Lwv_log2_high:
    lea ecx, [rdx - 9]
    shr r8d, cl
.Lwv_log2_entry:
    and r8d, 0xff
    lea rax, [rip + wv_log2_table]
    movzx eax, byte ptr [rax + r8]
    shl edx, 8
    add eax, edx
.Lwv_log2_done:
    ret
ENDFN wv_log2

# RCX=reader, EDX=bits (0-32) -> EAX, least significant bit first, zero past
# the data. Clobbers RCX, RDX, R8-R11.
LOCALFN wv_read
    mov r11, rcx
    mov r8d, [r11 + BR_POS]
    add [r11 + BR_POS], edx
    xor eax, eax
    test edx, edx
    jz .Lwv_read_done
    mov r9d, r8d
    shr r9d, 3                            # byte
    mov r10d, [r11 + BR_BITS]
    shr r10d, 3                           # bytes
    mov rcx, [r11 + BR_DATA]
    lea eax, [r9 + 8]
    cmp eax, r10d
    ja .Lwv_read_slow
    mov rax, [rcx + r9]
    jmp .Lwv_read_shift
.Lwv_read_slow:
    push rbx
    xor eax, eax
    mov ebx, 7
.Lwv_read_slow_byte:
    shl rax, 8
    lea r11d, [r9 + rbx]
    cmp r11d, r10d
    jae .Lwv_read_slow_next
    movzx r11d, byte ptr [rcx + r11]
    or rax, r11
.Lwv_read_slow_next:
    dec ebx
    jns .Lwv_read_slow_byte
    pop rbx
.Lwv_read_shift:
    mov ecx, r8d
    and ecx, 7
    shr rax, cl
    cmp edx, 32
    jae .Lwv_read_full
    mov r9d, 1
    mov ecx, edx
    shl r9, cl
    dec r9
    and rax, r9
    ret
.Lwv_read_full:
    mov eax, eax
.Lwv_read_done:
    ret
ENDFN wv_read

# RCX=reader -> EAX=bits left (signed).
LOCALFN wv_left
    mov eax, [rcx + BR_BITS]
    sub eax, [rcx + BR_POS]
    ret
ENDFN wv_left

# RCX=reader -> EAX=ones before a zero, at most 33 (FFmpeg get_unary_0_33).
LOCALFN wv_unary
    push rbx
    push rsi
    sub rsp, 8
    mov rsi, rcx
    mov ebx, [rsi + BR_POS]
    mov edx, 32
    call wv_read
    not eax
    bsf ecx, eax
    jnz .Lwv_unary_found
    lea eax, [rbx + 32]                   # 32 ones: the 33rd bit decides
    mov [rsi + BR_POS], eax
    mov rcx, rsi
    mov edx, 1
    call wv_read
    add eax, 32
    jmp .Lwv_unary_return
.Lwv_unary_found:
    lea eax, [rbx + rcx + 1]              # ones and the zero
    mov [rsi + BR_POS], eax
    mov eax, ecx
.Lwv_unary_return:
    add rsp, 8
    pop rsi
    pop rbx
    ret
ENDFN wv_unary

# RCX=reader, EDX=maximum k -> EAX=a truncated binary code below k + 1
# (FFmpeg get_tail).
LOCALFN wv_tail
    push rbx
    push rsi
    push rdi
    xor eax, eax
    test edx, edx
    jz .Lwv_tail_return
    mov rsi, rcx
    bsr ecx, edx                          # p
    mov ebx, 2
    shl rbx, cl
    sub rbx, rdx
    dec rbx                               # e
    mov edx, ecx
    mov rcx, rsi
    call wv_read
    mov edi, eax
    cmp rdi, rbx
    jb .Lwv_tail_done
    mov rcx, rsi
    mov edx, 1
    call wv_read
    lea rdi, [rdi*2]
    sub rdi, rbx
    add rdi, rax
.Lwv_tail_done:
    mov eax, edi
.Lwv_tail_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_tail

# Median helpers on the channel state at RBX: GET_MED(n) for EDX=n -> EAX.
.macro WV_MED n
    mov eax, [rbx + CH_MEDIAN + 4*\n]
    sar eax, 4
    inc eax
.endm
# median[n] -= ((median[n] + d - 2) / d) * 2, d = 128 >> n (C division).
.macro WV_DEC n
    mov eax, [rbx + CH_MEDIAN + 4*\n]
    add eax, (128 >> \n) - 2
    cdq
    and edx, (128 >> \n) - 1
    add eax, edx
    sar eax, 7 - \n
    add eax, eax
    sub [rbx + CH_MEDIAN + 4*\n], eax
.endm
# median[n] += ((median[n] + d) / d) * 5.
.macro WV_INC n
    mov eax, [rbx + CH_MEDIAN + 4*\n]
    add eax, 128 >> \n
    cdq
    and edx, (128 >> \n) - 1
    add eax, edx
    sar eax, 7 - \n
    lea eax, [rax + rax*4]
    add [rbx + CH_MEDIAN + 4*\n], eax
.endm

# EDX=channel -> EAX=next residual; EDX=1 at the end of the data or on a
# coding error (FFmpeg wv_get_value).
LOCALFN wv_get_value
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, edx
    imul eax, edx, CH_SIZE
    lea rbx, [rip + wv_ch]
    add rbx, rax                          # channel state
    # Runs of zeros while both channels' first medians are below 2.
    cmp dword ptr [rip + wv_ch + CH_MEDIAN], 2
    jae .Lwv_value_normal
    cmp dword ptr [rip + wv_ch + CH_SIZE + CH_MEDIAN], 2
    jae .Lwv_value_normal
    cmp dword ptr [rip + wv_zero], 0
    jne .Lwv_value_normal
    cmp dword ptr [rip + wv_one], 0
    jne .Lwv_value_normal
    mov eax, [rip + wv_zeroes]
    test eax, eax
    jz .Lwv_value_read_zeroes
    dec eax
    mov [rip + wv_zeroes], eax
    jz .Lwv_value_normal
    jmp .Lwv_value_zero
.Lwv_value_read_zeroes:
    lea rcx, [rip + wv_main]
    call wv_unary
    mov r13d, eax
    lea rcx, [rip + wv_main]
    call wv_left
    cmp r13d, 2
    jae .Lwv_value_zeroes_long
    test eax, eax
    js .Lwv_value_error
    mov eax, r13d
    jmp .Lwv_value_zeroes_set
.Lwv_value_zeroes_long:
    cmp r13d, 32
    jae .Lwv_value_error
    lea ecx, [r13 - 1]
    cmp eax, ecx
    jl .Lwv_value_error
    lea rcx, [rip + wv_main]
    lea edx, [r13 - 1]
    call wv_read
    lea ecx, [r13 - 1]
    mov edx, 1
    shl edx, cl
    or eax, edx
.Lwv_value_zeroes_set:
    mov [rip + wv_zeroes], eax
    test eax, eax
    jz .Lwv_value_normal
    lea rcx, [rip + wv_ch]
    xor eax, eax
    mov [rcx + CH_MEDIAN], eax
    mov [rcx + CH_MEDIAN + 4], eax
    mov [rcx + CH_MEDIAN + 8], eax
    mov [rcx + CH_SIZE + CH_MEDIAN], eax
    mov [rcx + CH_SIZE + CH_MEDIAN + 4], eax
    mov [rcx + CH_SIZE + CH_MEDIAN + 8], eax
.Lwv_value_zero:
    mov eax, [rbx + CH_SLOW]              # slow_level -= LEVEL_DECAY
    add eax, 0x80
    sar eax, 8
    sub [rbx + CH_SLOW], eax
    xor eax, eax
    xor edx, edx
    jmp .Lwv_value_return
.Lwv_value_normal:
    # Count of ones, with the holding one/zero state.
    xor esi, esi
    cmp dword ptr [rip + wv_zero], 0
    je .Lwv_value_ones
    mov dword ptr [rip + wv_zero], 0
    jmp .Lwv_value_hybrid
.Lwv_value_ones:
    lea rcx, [rip + wv_main]
    call wv_unary
    mov esi, eax
    lea rcx, [rip + wv_main]
    call wv_left
    test eax, eax
    js .Lwv_value_error
    cmp esi, 16
    jne .Lwv_value_hold
    lea rcx, [rip + wv_main]
    call wv_unary
    mov edi, eax
    lea rcx, [rip + wv_main]
    call wv_left
    cmp edi, 2
    jae .Lwv_value_escape_long
    test eax, eax
    js .Lwv_value_error
    add esi, edi
    jmp .Lwv_value_hold
.Lwv_value_escape_long:
    cmp edi, 32
    jae .Lwv_value_error
    lea ecx, [rdi - 1]
    cmp eax, ecx
    jl .Lwv_value_error
    lea rcx, [rip + wv_main]
    lea edx, [rdi - 1]
    call wv_read
    lea ecx, [rdi - 1]
    mov edx, 1
    shl edx, cl
    or eax, edx
    add esi, eax
.Lwv_value_hold:
    mov eax, esi
    and eax, 1
    cmp dword ptr [rip + wv_one], 0
    mov [rip + wv_one], eax
    je .Lwv_value_hold_clear
    shr esi, 1
    inc esi
    jmp .Lwv_value_hold_done
.Lwv_value_hold_clear:
    shr esi, 1
.Lwv_value_hold_done:
    xor eax, eax
    cmp dword ptr [rip + wv_one], 0
    sete al
    mov [rip + wv_zero], eax
.Lwv_value_hybrid:
    cmp dword ptr [rip + wv_hybrid], 0
    je .Lwv_value_medians
    test r12d, r12d
    jnz .Lwv_value_medians
    call wv_update_error_limit
    test eax, eax
    jz .Lwv_value_error
.Lwv_value_medians:
    # base (EDI) and range (R13D) from the medians, which adapt.
    test esi, esi
    jnz .Lwv_value_one
    xor edi, edi
    WV_MED 0
    lea r13d, [rax - 1]
    WV_DEC 0
    jmp .Lwv_value_code
.Lwv_value_one:
    cmp esi, 1
    jne .Lwv_value_more
    WV_MED 0
    mov edi, eax
    WV_MED 1
    lea r13d, [rax - 1]
    WV_INC 0
    WV_DEC 1
    jmp .Lwv_value_code
.Lwv_value_more:
    WV_MED 0
    mov edi, eax
    WV_MED 1
    add edi, eax
    WV_INC 0
    WV_INC 1
    cmp esi, 2
    jne .Lwv_value_many
    WV_MED 2
    lea r13d, [rax - 1]
    WV_DEC 2
    jmp .Lwv_value_code
.Lwv_value_many:
    WV_MED 2
    lea ecx, [rsi - 2]
    imul ecx, eax
    add edi, ecx
    lea r13d, [rax - 1]
    WV_INC 2
.Lwv_value_code:
    cmp dword ptr [rbx + CH_LIMIT], 0
    jne .Lwv_value_bisect
    cmp r13d, 0x2000000
    jae .Lwv_value_error
    lea rcx, [rip + wv_main]
    mov edx, r13d
    call wv_tail
    add edi, eax
    lea rcx, [rip + wv_main]
    call wv_left
    test eax, eax
    jle .Lwv_value_error
    jmp .Lwv_value_sign
.Lwv_value_bisect:
    # Hybrid: halve the range until it is within the error limit.
    lea eax, [rdi*2 + 1]
    add eax, r13d
    shr eax, 1
    mov esi, eax                          # mid
.Lwv_value_bisect_step:
    cmp r13d, [rbx + CH_LIMIT]            # signed, as in FFmpeg
    jle .Lwv_value_bisect_done
    lea rcx, [rip + wv_main]
    call wv_left
    test eax, eax
    jle .Lwv_value_error
    lea rcx, [rip + wv_main]
    mov edx, 1
    call wv_read
    test eax, eax
    jz .Lwv_value_bisect_low
    mov eax, esi
    sub eax, edi
    sub r13d, eax
    mov edi, esi
    jmp .Lwv_value_bisect_mid
.Lwv_value_bisect_low:
    mov r13d, esi
    sub r13d, edi
    dec r13d
.Lwv_value_bisect_mid:
    lea eax, [rdi*2 + 1]
    add eax, r13d
    shr eax, 1
    mov esi, eax
    jmp .Lwv_value_bisect_step
.Lwv_value_bisect_done:
    mov edi, esi
.Lwv_value_sign:
    lea rcx, [rip + wv_main]
    mov edx, 1
    call wv_read
    mov esi, eax
    cmp dword ptr [rip + wv_bitrate], 0
    je .Lwv_value_signed
    mov ecx, edi
    call wv_log2
    mov ecx, [rbx + CH_SLOW]
    add ecx, 0x80
    sar ecx, 8
    sub eax, ecx
    add [rbx + CH_SLOW], eax
.Lwv_value_signed:
    mov eax, edi
    test esi, esi
    jz .Lwv_value_done
    not eax
.Lwv_value_done:
    xor edx, edx
    jmp .Lwv_value_return
.Lwv_value_error:
    xor eax, eax
    mov edx, 1
.Lwv_value_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_get_value

# Hybrid error limits from the bit rate accumulators -> EAX=1, or 0 when an
# accumulator overflows (FFmpeg update_error_limit). Locals: 0 br[2], 8 sl[2].
LOCALFN wv_update_error_limit
    push rbx
    push rsi
    sub rsp, 40
    xor esi, esi
.Lwv_limit_rate:
    cmp esi, [rip + wv_stereo_in]
    ja .Lwv_limit_balance
    imul eax, esi, CH_SIZE
    lea rbx, [rip + wv_ch]
    add rbx, rax
    mov eax, [rbx + CH_ACC]
    mov ecx, [rbx + CH_DELTA]
    add eax, ecx
    jc .Lwv_limit_fail
    mov [rbx + CH_ACC], eax
    shr eax, 16
    mov [rsp + rsi*4], eax                # br
    mov eax, [rbx + CH_SLOW]
    add eax, 0x80
    sar eax, 8
    mov [rsp + 8 + rsi*4], eax            # sl
    inc esi
    jmp .Lwv_limit_rate
.Lwv_limit_balance:
    cmp dword ptr [rip + wv_stereo_in], 0
    je .Lwv_limit_set
    cmp dword ptr [rip + wv_bitrate], 0
    je .Lwv_limit_set
    mov eax, [rsp + 12]
    sub eax, [rsp + 8]
    add eax, [rsp + 4]
    inc eax
    sar eax, 1                            # balance
    mov ecx, [rsp]                        # br[0]
    cmp eax, ecx
    jle .Lwv_limit_negative
    add ecx, ecx
    mov [rsp + 4], ecx
    mov dword ptr [rsp], 0
    jmp .Lwv_limit_set
.Lwv_limit_negative:
    mov edx, eax
    neg edx
    cmp edx, ecx
    jle .Lwv_limit_split
    add ecx, ecx
    mov [rsp], ecx
    mov dword ptr [rsp + 4], 0
    jmp .Lwv_limit_set
.Lwv_limit_split:
    lea edx, [rcx + rax]
    mov [rsp + 4], edx
    sub ecx, eax
    mov [rsp], ecx
.Lwv_limit_set:
    xor esi, esi
.Lwv_limit_channel:
    cmp esi, [rip + wv_stereo_in]
    ja .Lwv_limit_done
    imul eax, esi, CH_SIZE
    lea rbx, [rip + wv_ch]
    add rbx, rax
    cmp dword ptr [rip + wv_bitrate], 0
    je .Lwv_limit_plain
    mov ecx, [rsp + 8 + rsi*4]
    sub ecx, [rsp + rsi*4]                # sl - br
    xor eax, eax
    cmp ecx, -0x100
    jle .Lwv_limit_store
    add ecx, 0x100
    call wv_exp2
    jmp .Lwv_limit_store
.Lwv_limit_plain:
    mov ecx, [rsp + rsi*4]
    call wv_exp2
.Lwv_limit_store:
    mov [rbx + CH_LIMIT], eax
    inc esi
    jmp .Lwv_limit_channel
.Lwv_limit_done:
    mov eax, 1
    jmp .Lwv_limit_return
.Lwv_limit_fail:
    xor eax, eax
.Lwv_limit_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN wv_update_error_limit

# EAX=decoded value S -> EAX=output sample in the 16- or 32-bit domain:
# extra bits, the and/or shift, hybrid clipping and the post shift.
LOCALFN wv_integer
    push rbx
    mov ebx, eax
    mov ecx, [rip + wv_extra_bits]
    test ecx, ecx
    jz .Lwv_int_shift
    shl ebx, cl
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_int_shift
    lea rcx, [rip + wv_extra]
    call wv_left
    cmp eax, [rip + wv_extra_bits]
    jl .Lwv_int_shift
    lea rcx, [rip + wv_extra]
    mov edx, [rip + wv_extra_bits]
    call wv_read
    or ebx, eax
    mov eax, [rip + wv_crc_extra]         # crc = crc * 9 + (S & 0xffff) * 3 + (S >> 16)
    lea eax, [rax + rax*8]
    movzx ecx, bx
    lea ecx, [rcx + rcx*2]
    add eax, ecx
    mov ecx, ebx
    shr ecx, 16
    add eax, ecx
    mov [rip + wv_crc_extra], eax
.Lwv_int_shift:
    mov eax, ebx
    and eax, [rip + wv_and]
    or eax, [rip + wv_or]                 # bit
    lea edx, [rbx + rax]
    mov ecx, [rip + wv_shift]
    shl edx, cl
    sub edx, eax
    cmp dword ptr [rip + wv_hybrid], 0
    je .Lwv_int_post
    cmp edx, [rip + wv_maxclip]
    cmovg edx, [rip + wv_maxclip]
    cmp edx, [rip + wv_minclip]
    cmovl edx, [rip + wv_minclip]
.Lwv_int_post:
    mov ecx, [rip + wv_post_shift]
    shl edx, cl
    mov eax, edx
    pop rbx
    ret
ENDFN wv_integer

# EAX=decoded value S -> EAX=float bits, with extra bits for the mantissa,
# exponent or sign where the block sends them (FFmpeg wv_get_value_float).
LOCALFN wv_float_value
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, eax                          # S
    mov esi, [rip + wv_float_exp]         # exp
    xor edi, edi                          # sign
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_float_value
    lea rcx, [rip + wv_extra]
    call wv_left
    add eax, 8*64
    cmp eax, 1 + 23 + 8 + 1
    jge .Lwv_float_value
    xor eax, eax                          # too few extra bits: 0.0
    jmp .Lwv_float_return
.Lwv_float_value:
    test ebx, ebx
    jz .Lwv_float_zero
    mov ecx, [rip + wv_float_shift]
    shl ebx, cl
    test ebx, ebx
    jns .Lwv_float_magnitude
    mov edi, 1
    neg ebx
.Lwv_float_magnitude:
    cmp ebx, 0x1000000
    jb .Lwv_float_normal
    xor ebx, ebx
    mov esi, 255
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_float_mantissa
    lea rcx, [rip + wv_extra]
    mov edx, 1
    call wv_read
    test eax, eax
    jz .Lwv_float_mantissa
    lea rcx, [rip + wv_extra]
    mov edx, 23
    call wv_read
    mov ebx, eax
    jmp .Lwv_float_mantissa
.Lwv_float_normal:
    test esi, esi
    jz .Lwv_float_mantissa                # exp stays float_max_exp (0)
    xor ecx, ecx                          # av_log2(0) = 0 when the shift cleared S
    test ebx, ebx
    jz .Lwv_float_log
    bsr ecx, ebx
.Lwv_float_log:
    mov eax, 23
    sub eax, ecx                          # shift
    cmp esi, eax
    jg .Lwv_float_exponent
    dec esi
    mov eax, esi
.Lwv_float_exponent:
    sub esi, eax
    test eax, eax
    jz .Lwv_float_mantissa
    mov ecx, eax
    shl ebx, cl
    mov edx, 1
    shl edx, cl
    dec edx                               # (1 << shift) - 1
    test dword ptr [rip + wv_float_flag], 1
    jnz .Lwv_float_ones
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_float_mantissa
    test dword ptr [rip + wv_float_flag], 2
    jz .Lwv_float_sent
    push rdx
    push rcx
    lea rcx, [rip + wv_extra]
    mov edx, 1
    call wv_read
    pop rcx
    pop rdx
    test eax, eax
    jnz .Lwv_float_ones
    jmp .Lwv_float_mantissa
.Lwv_float_sent:
    test dword ptr [rip + wv_float_flag], 4
    jz .Lwv_float_mantissa
    mov edx, ecx
    lea rcx, [rip + wv_extra]
    call wv_read
    or ebx, eax
    jmp .Lwv_float_mantissa
.Lwv_float_ones:
    or ebx, edx
.Lwv_float_mantissa:
    and ebx, 0x7fffff
    jmp .Lwv_float_crc
.Lwv_float_zero:
    xor esi, esi
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_float_crc
    test dword ptr [rip + wv_float_flag], 8
    jz .Lwv_float_crc
    lea rcx, [rip + wv_extra]
    mov edx, 1
    call wv_read
    test eax, eax
    jz .Lwv_float_zero_sign
    lea rcx, [rip + wv_extra]
    mov edx, 23
    call wv_read
    mov ebx, eax
    cmp dword ptr [rip + wv_float_exp], 25
    jb .Lwv_float_zero_signed
    lea rcx, [rip + wv_extra]
    mov edx, 8
    call wv_read
    mov esi, eax
.Lwv_float_zero_signed:
    lea rcx, [rip + wv_extra]
    mov edx, 1
    call wv_read
    mov edi, eax
    jmp .Lwv_float_crc
.Lwv_float_zero_sign:
    test dword ptr [rip + wv_float_flag], 0x10
    jz .Lwv_float_crc
    lea rcx, [rip + wv_extra]
    mov edx, 1
    call wv_read
    mov edi, eax
.Lwv_float_crc:
    # crc = crc * 27 + S * 9 + exp * 3 + sign
    mov eax, [rip + wv_crc_extra]
    imul eax, eax, 27
    lea ecx, [rbx + rbx*8]
    add eax, ecx
    lea ecx, [rsi + rsi*2]
    add eax, ecx
    add eax, edi
    mov [rip + wv_crc_extra], eax
    mov eax, edi
    shl eax, 31
    shl esi, 23
    or eax, esi
    or eax, ebx
.Lwv_float_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_float_value

# R8D=weight, R9D=history sample, R10D=input -> EAX=input + weighted
# prediction (32-bit wrap for 16-bit output, 64-bit products otherwise).
.macro WV_APPLY
    cmp dword ptr [rip + wv_format], 0
    jne 1f
    mov eax, r8d
    imul eax, r9d
    add eax, 512
    sar eax, 10
    add eax, r10d
    jmp 2f
1:
    movsxd rax, r8d
    movsxd rcx, r9d
    imul rax, rcx
    add rax, 512
    sar rax, 10
    add eax, r10d
2:
.endm

# Weight update with clipping at +-1024: R8D=weight, R11D=delta, R9D=sample,
# R10D=input -> R8D.
.macro WV_CLIP_UPDATE
    test r9d, r9d
    jz 3f
    test r10d, r10d
    jz 3f
    mov eax, r9d
    xor eax, r10d
    js 4f
    add r8d, r11d
    cmp r8d, 1024
    jle 3f
    mov r8d, 1024
    jmp 3f
4:
    sub r8d, r11d
    cmp r8d, -1024
    jge 3f
    mov r8d, -1024
3:
.endm

# Stereo decode of the block into the output pointers -> EAX=1, or 0 on an
# error. Registers: R12D sample count, R13D position, R14D CRC, R15D/RBX L/R.
LOCALFN wv_unpack_stereo
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    xor r12d, r12d
    xor r13d, r13d
    mov r14d, -1
    mov qword ptr [rip + wv_one], 0       # one, zero
    mov dword ptr [rip + wv_zeroes], 0
.Lwv_st_sample:
    cmp r12d, [rip + wv_samples]
    jae .Lwv_st_done
    xor edx, edx
    call wv_get_value
    test edx, edx
    jnz .Lwv_st_last
    mov r15d, eax                         # L
    mov edx, 1
    call wv_get_value
    test edx, edx
    jnz .Lwv_st_last
    mov ebx, eax                          # R
    lea rsi, [rip + wv_decorr]
    xor edi, edi
.Lwv_st_term:
    cmp edi, [rip + wv_terms]
    jae .Lwv_st_terms_done
    mov eax, [rsi + DC_VALUE]
    test eax, eax
    jle .Lwv_st_negative
    cmp eax, 8
    jle .Lwv_st_history
    # Terms 17 and 18: extrapolated from two samples.
    mov ecx, [rsi + DC_SA]
    mov edx, [rsi + DC_SA + 4]
    test eax, 1
    jz .Lwv_st_even
    lea r9d, [rcx*2]
    sub r9d, edx                          # A
    mov ecx, [rsi + DC_SB]
    mov edx, [rsi + DC_SB + 4]
    lea r10d, [rcx*2]
    sub r10d, edx                         # B
    jmp .Lwv_st_extrapolated
.Lwv_st_even:
    lea r9d, [rcx + rcx*2]
    sub r9d, edx
    sar r9d, 1
    mov ecx, [rsi + DC_SB]
    mov edx, [rsi + DC_SB + 4]
    lea r10d, [rcx + rcx*2]
    sub r10d, edx
    sar r10d, 1
.Lwv_st_extrapolated:
    mov eax, [rsi + DC_SA]
    mov [rsi + DC_SA + 4], eax
    mov eax, [rsi + DC_SB]
    mov [rsi + DC_SB + 4], eax
    xor eax, eax                          # j
    jmp .Lwv_st_positive
.Lwv_st_history:
    mov r9d, [rsi + DC_SA + r13*4]
    mov r10d, [rsi + DC_SB + r13*4]
    add eax, r13d
    and eax, 7
.Lwv_st_positive:
    mov [rsp + 32], eax                   # j
    mov [rsp + 36], r10d                  # B
    mov [rsp + 40], r9d                   # A
    mov r8d, [rsi + DC_WA]
    mov r10d, r15d
    WV_APPLY
    mov [rsp + 44], eax                   # L2
    mov r8d, [rsi + DC_WB]
    mov r9d, [rsp + 36]
    mov r10d, ebx
    WV_APPLY
    mov ecx, eax                          # R2
    # weight -= ((((x ^ A) >> 30) & 2) - 1) * delta when both are nonzero.
    mov r9d, [rsp + 40]
    test r9d, r9d
    jz .Lwv_st_weight_b
    test r15d, r15d
    jz .Lwv_st_weight_b
    mov eax, r15d
    xor eax, r9d
    sar eax, 30
    and eax, 2
    dec eax
    imul eax, [rsi + DC_DELTA]
    sub [rsi + DC_WA], eax
.Lwv_st_weight_b:
    mov r9d, [rsp + 36]
    test r9d, r9d
    jz .Lwv_st_store
    test ebx, ebx
    jz .Lwv_st_store
    mov eax, ebx
    xor eax, r9d
    sar eax, 30
    and eax, 2
    dec eax
    imul eax, [rsi + DC_DELTA]
    sub [rsi + DC_WB], eax
.Lwv_st_store:
    mov eax, [rsp + 32]
    mov r15d, [rsp + 44]
    mov ebx, ecx
    mov [rsi + DC_SA + rax*4], r15d
    mov [rsi + DC_SB + rax*4], ebx
    jmp .Lwv_st_next
.Lwv_st_negative:
    cmp eax, -1
    jne .Lwv_st_cross
    # Term -1: left from A's history, right from the new left.
    mov r8d, [rsi + DC_WA]
    mov r9d, [rsi + DC_SA]
    mov r10d, r15d
    WV_APPLY
    mov [rsp + 44], eax                   # L2
    mov r8d, [rsi + DC_WA]
    mov r11d, [rsi + DC_DELTA]
    mov r9d, [rsi + DC_SA]
    mov r10d, r15d
    WV_CLIP_UPDATE
    mov [rsi + DC_WA], r8d
    mov r15d, [rsp + 44]
    mov r8d, [rsi + DC_WB]
    mov r9d, r15d
    mov r10d, ebx
    WV_APPLY
    mov [rsp + 40], eax                   # R2
    mov r8d, [rsi + DC_WB]
    mov r11d, [rsi + DC_DELTA]
    mov r9d, r15d
    mov r10d, ebx
    WV_CLIP_UPDATE
    mov [rsi + DC_WB], r8d
    mov ebx, [rsp + 40]
    mov [rsi + DC_SA], ebx
    jmp .Lwv_st_next
.Lwv_st_cross:
    # Terms -2 and -3: right from B's history, left from the new right
    # (term -3: from A's history, which takes the new right).
    mov [rsp + 32], eax
    mov r8d, [rsi + DC_WB]
    mov r9d, [rsi + DC_SB]
    mov r10d, ebx
    WV_APPLY
    mov [rsp + 44], eax                   # R2
    mov r8d, [rsi + DC_WB]
    mov r11d, [rsi + DC_DELTA]
    mov r9d, [rsi + DC_SB]
    mov r10d, ebx
    WV_CLIP_UPDATE
    mov [rsi + DC_WB], r8d
    mov ebx, [rsp + 44]                   # R
    mov ecx, ebx                          # R2 for the left prediction
    cmp dword ptr [rsp + 32], -3
    jne .Lwv_st_cross_left
    mov ecx, [rsi + DC_SA]
    mov [rsi + DC_SA], ebx
.Lwv_st_cross_left:
    mov [rsp + 40], ecx
    mov r8d, [rsi + DC_WA]
    mov r9d, ecx
    mov r10d, r15d
    WV_APPLY
    mov [rsp + 44], eax                   # L2
    mov r8d, [rsi + DC_WA]
    mov r11d, [rsi + DC_DELTA]
    mov r9d, [rsp + 40]
    mov r10d, r15d
    WV_CLIP_UPDATE
    mov [rsi + DC_WA], r8d
    mov r15d, [rsp + 44]
    mov [rsi + DC_SB], r15d
.Lwv_st_next:
    add rsi, DC_SIZE
    inc edi
    jmp .Lwv_st_term
.Lwv_st_terms_done:
    cmp dword ptr [rip + wv_format], 0
    jne .Lwv_st_position
    mov eax, r15d                         # |L| + |R| above 2^19 is invalid at 16 bits
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, ebx
    sar ecx, 31
    mov edx, ebx
    xor edx, ecx
    sub edx, ecx
    add rax, rdx
    cmp rax, 1 << 19
    ja .Lwv_st_fail
.Lwv_st_position:
    inc r13d
    and r13d, 7
    test dword ptr [rip + wv_flags], F_JOINT
    jz .Lwv_st_crc
    mov eax, r15d
    sar eax, 1
    sub ebx, eax
    add r15d, ebx
.Lwv_st_crc:
    lea eax, [r14 + r14*2]
    add eax, r15d
    lea eax, [rax + rax*2]
    add eax, ebx
    mov r14d, eax
    mov eax, r15d
    call .Lwv_st_convert
    mov rcx, [rip + wv_out]
    mov [rcx + r12*4], eax
    mov eax, ebx
    call .Lwv_st_convert
    mov rcx, [rip + wv_out + 8]
    mov [rcx + r12*4], eax
    inc r12d
    jmp .Lwv_st_sample
.Lwv_st_last:
    cmp r12d, [rip + wv_samples]
    jb .Lwv_st_fail
.Lwv_st_done:
    cmp r14d, [rip + wv_crc]
    jne .Lwv_st_fail
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_st_ok
    mov eax, [rip + wv_crc_extra]
    cmp eax, [rip + wv_crc_extra_want]
    jne .Lwv_st_fail
.Lwv_st_ok:
    mov eax, 1
    jmp .Lwv_st_return
.Lwv_st_fail:
    xor eax, eax
.Lwv_st_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.Lwv_st_convert:                          # EAX -> output sample (callee frame + 8)
    cmp dword ptr [rip + wv_format], 2
    je wv_float_value
    jmp wv_integer
ENDFN wv_unpack_stereo

# Mono decode of the block into the left output pointer -> EAX=1, or 0 on
# an error. Registers: R12D count, R13D position, R14D CRC, R15D S.
LOCALFN wv_unpack_mono
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    xor r12d, r12d
    xor r13d, r13d
    mov r14d, -1
    mov qword ptr [rip + wv_one], 0
    mov dword ptr [rip + wv_zeroes], 0
.Lwv_mono_sample:
    cmp r12d, [rip + wv_samples]
    jae .Lwv_mono_done
    xor edx, edx
    call wv_get_value
    test edx, edx
    jnz .Lwv_mono_last
    mov ebx, eax                          # T
    mov r15d, eax                         # S when there are no terms
    lea rsi, [rip + wv_decorr]
    xor edi, edi
.Lwv_mono_term:
    cmp edi, [rip + wv_terms]
    jae .Lwv_mono_terms_done
    mov eax, [rsi + DC_VALUE]
    cmp eax, 8
    jle .Lwv_mono_history
    mov ecx, [rsi + DC_SA]
    mov edx, [rsi + DC_SA + 4]
    test eax, 1
    jz .Lwv_mono_even
    lea r9d, [rcx*2]
    sub r9d, edx
    jmp .Lwv_mono_extrapolated
.Lwv_mono_even:
    lea r9d, [rcx + rcx*2]
    sub r9d, edx
    sar r9d, 1
.Lwv_mono_extrapolated:
    mov [rsi + DC_SA + 4], ecx
    xor eax, eax
    jmp .Lwv_mono_apply
.Lwv_mono_history:
    mov r9d, [rsi + DC_SA + r13*4]
    add eax, r13d
    and eax, 7
.Lwv_mono_apply:
    mov [rsp + 32], eax                   # j
    mov [rsp + 36], r9d                   # A
    mov r8d, [rsi + DC_WA]
    mov r10d, ebx
    WV_APPLY
    mov r15d, eax                         # S
    mov r9d, [rsp + 36]
    test r9d, r9d
    jz .Lwv_mono_store
    test ebx, ebx
    jz .Lwv_mono_store
    mov eax, ebx
    xor eax, r9d
    sar eax, 30
    and eax, 2
    dec eax
    imul eax, [rsi + DC_DELTA]
    sub [rsi + DC_WA], eax
.Lwv_mono_store:
    mov eax, [rsp + 32]
    mov [rsi + DC_SA + rax*4], r15d
    mov ebx, r15d
    add rsi, DC_SIZE
    inc edi
    jmp .Lwv_mono_term
.Lwv_mono_terms_done:
    inc r13d
    and r13d, 7
    lea eax, [r14 + r14*2]
    add eax, r15d
    mov r14d, eax
    mov eax, r15d
    cmp dword ptr [rip + wv_format], 2
    je .Lwv_mono_float
    call wv_integer
    jmp .Lwv_mono_store_out
.Lwv_mono_float:
    call wv_float_value
.Lwv_mono_store_out:
    mov rcx, [rip + wv_out]
    mov [rcx + r12*4], eax
    inc r12d
    jmp .Lwv_mono_sample
.Lwv_mono_last:
    cmp r12d, [rip + wv_samples]
    jb .Lwv_mono_fail
.Lwv_mono_done:
    cmp r14d, [rip + wv_crc]
    jne .Lwv_mono_fail
    cmp dword ptr [rip + wv_got_extra], 0
    je .Lwv_mono_ok
    mov eax, [rip + wv_crc_extra]
    cmp eax, [rip + wv_crc_extra_want]
    jne .Lwv_mono_fail
.Lwv_mono_ok:
    mov eax, 1
    jmp .Lwv_mono_return
.Lwv_mono_fail:
    xor eax, eax
.Lwv_mono_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_unpack_mono

.include "wavpack_block.inc"
