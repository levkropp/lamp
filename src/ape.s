# Original Monkey's Audio decoder in x86-64 assembly. MIT, see LICENSE.
# Files of versions 3930-3990 (Monkey's Audio 3.93 and later): mono and
# stereo, 8, 16 and 24 bits, every compression level. A frame is a range
# coded stream of residuals with two adaptive Rice parameters (the 3990
# model, or the 3900 model before it), run through the level's cascade of
# sign-LMS filters and the 3930 or 3950 predictor, then decorrelated from
# mid/side. 24-bit stereo files try the 32-bit and the 64-bit ("interim")
# 3950 predictor until one stays within 24 bits, as FFmpeg does. Arithmetic,
# the 4608-block decoding pass and error handling follow FFmpeg's decoder,
# which the tests compare against. Frames decode independently: a seek
# restarts at the frame holding the target. Each frame's CRC is checked; a
# failed CRC or damaged, cut or missing frame data stops decoding with
# decode_error 100.
.include "lamp.inc"
.globl ape_probe, ape_open, ape_read, ape_seek

.equ APE_MALFORMED, 100
.equ APE_UNSUPPORTED, 101
.equ CODEC_APE, 17
.equ APE_CHUNK, 4608                # blocks per pass (FFmpeg's blocks_per_loop)
.equ HISTORY, 512
.equ PRED_SIZE, 50
.equ YDELAYA, 50
.equ YDELAYB, 42
.equ XDELAYA, 34
.equ XDELAYB, 26
.equ YADAPTA, 18
.equ XADAPTA, 14
.equ YADAPTB, 10
.equ XADAPTB, 5
# Predictor (64-bit fields; the 3930 predictor uses their low halves).
.equ P_BUF, 0                       # index of buf in P_HIST
.equ P_LASTA, 8
.equ P_FILTERA, 24
.equ P_FILTERB, 40
.equ P_COEFFA, 56                   # [2][4]
.equ P_COEFFB, 120                  # [2][5]
.equ P_HIST, 200                    # HISTORY + PRED_SIZE entries
.equ P_SIZE, P_HIST + (HISTORY + PRED_SIZE)*8
# Filter: coefficients, then adaption values and outputs in one history.
.equ F_COEFFS, 0                    # int16 [order]
.equ F_HIST, 2560                   # int16 [order*2 + HISTORY]
.equ F_AVG, 8704
.equ F_POS, 8708                    # adaption index; outputs follow at +order
.equ F_SIZE, 8720
.equ FLAG_SILENCE, 3                # frame flags: 1 left (mono), 2 right silent
.equ FLAG_PSEUDO_STEREO, 4

RODATA
.p2align 1
# Cumulative frequencies of the overflow symbols 0-20 of Monkey's Audio's
# 3.97 and 3.98 models (symbols 21-63 have frequency one from 65493 on).
ape_counts_3970: .short 0, 14824, 28224, 39348, 47855, 53994, 58171, 60926
    .short 62682, 63786, 64463, 64878, 65126, 65276, 65365, 65419
    .short 65450, 65469, 65480, 65487, 65491, 65493
ape_counts_3980: .short 0, 19578, 36160, 48417, 56323, 60899, 63265, 64435
    .short 64971, 65232, 65351, 65416, 65447, 65466, 65476, 65482
    .short 65485, 65488, 65490, 65491, 65492, 65493
# Filter orders and fraction bits of compression levels 1000-5000.
ape_orders: .short 0, 0, 0, 16, 0, 0, 64, 0, 0, 32, 256, 0, 16, 256, 1280
ape_fracbits: .byte 0, 0, 0, 11, 0, 0, 11, 0, 0, 10, 13, 0, 11, 13, 15
.p2align 3
ape_initial: .quad 360, 317, -109, 98   # predictor A coefficients (3930 and later)
ape_scale8: .float 0.0078125            # 2^-7
ape_scale16: .float 3.0517578125e-5     # 2^-15
ape_scale32: .float 4.656612873077393e-10  # 2^-31

.data
ape_interim: .long 0                # 24-bit stereo: -1 undecided, 0 32-bit, 1 64-bit

.bss
.p2align 4
ape_filters: .zero 6*F_SIZE         # [level][channel]
ape_pred: .zero P_SIZE
.p2align 4
ape_pred2: .zero P_SIZE             # the other predictor of an undecided pass
.p2align 4
ape_decoded: .zero 2*APE_CHUNK*4    # left/mid, then right/side
ape_spare: .zero 2*APE_CHUNK*4      # the 64-bit pass of an undecided chunk
ape_out: .zero APE_CHUNK*8          # stereo float
ape_crc_table: .zero 1024
.p2align 3
ape_data: .zero 8                   # word-aligned start of the open frame
ape_table: .zero 8                  # seek table: 32-bit offsets from ape_base
ape_base: .zero 8                   # the "MAC " header (FFmpeg's junk length)
ape_first: .zero 8                  # frame 0
ape_end: .zero 8
ape_rice: .zero 16                  # Y (first channel): k, ksum; then X
ape_version: .zero 4
ape_fset: .zero 4                   # compression level / 1000 - 1
ape_channels: .zero 4
ape_depth: .zero 4
ape_bpf: .zero 4                    # blocks per frame
ape_final: .zero 4                  # blocks of the last frame
ape_frames: .zero 4
ape_tail: .zero 4                   # WAV tail bytes after the last frame
ape_frame: .zero 4                  # next frame to open
ape_left: .zero 4                   # blocks left in the open frame
ape_flags: .zero 4
ape_mono: .zero 4                   # the open frame codes one channel
ape_crc: .zero 4
ape_crc_state: .zero 4
ape_crc_ready: .zero 4
ape_out_frames: .zero 4
ape_out_used: .zero 4
ape_pos: .zero 4                    # coder position in the byte-swapped frame
ape_words: .zero 4                  # bytes of whole words in the frame
ape_avail: .zero 4                  # bytes the coder may read (FFmpeg's data_end)
ape_error: .zero 4
rc_low: .zero 4
rc_range: .zero 4
rc_help: .zero 4
rc_buffer: .zero 4

# x in SRC -> RCX = APESIGN(x): -1 positive, 1 negative, 0. Clobbers R11.
.macro SIGN64 src
    xor ecx, ecx
    xor r11d, r11d
    test \src, \src
    setl cl
    setg r11b
    sub rcx, r11
.endm

.text
# RCX=cursor, RDX=end -> RAX after consecutive ID3v2 tags.
LOCALFN ape_skip_id3
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rdx
.Lape_skip_next:
    mov rbx, rcx
    mov rdx, rsi
    call adts_skip_id3
    mov rcx, rax
    cmp rax, rbx
    jne .Lape_skip_next
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN ape_skip_id3

# RCX=cursor, RDX=end -> EAX=1 when a "MAC " header follows any ID3v2 tags.
FN ape_probe
    push rbx
    sub rsp, 32
    mov rbx, rdx
    call ape_skip_id3
    xor ecx, ecx
    lea rdx, [rax + 6]
    cmp rdx, rbx
    ja .Lape_probe_return
    cmp dword ptr [rax], 0x2043414d       # "MAC "
    sete cl
.Lape_probe_return:
    mov eax, ecx
    add rsp, 32
    pop rbx
    ret
ENDFN ape_probe

# ECX=frame -> RAX=its position (frame 0 follows the headers; the others are
# seek table offsets from the "MAC " header).
LOCALFN ape_frame_pos
    mov rax, [rip + ape_first]
    test ecx, ecx
    jz .Lape_pos_return
    mov rax, [rip + ape_table]
    mov eax, [rax + rcx*4]
    add rax, [rip + ape_base]
.Lape_pos_return:
    ret
ENDFN ape_frame_pos

# RCX=cursor, RDX=end -> EAX=1 with the stream published, else 0 with
# decode_error 100 (malformed) or 101 (unsupported version or format).
FN ape_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rdi, rdx
    mov [rip + ape_end], rdx
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lape_open_start
    cmp dword ptr [rax], 0
    je .Lape_open_start
    mov dword ptr [rip + decode_error], 3  # cancelled
    xor eax, eax
    jmp .Lape_open_return
.Lape_open_start:
    call ape_skip_id3
    mov rsi, rax                          # "MAC "
    mov [rip + ape_base], rax
    mov rax, rdi
    sub rax, rsi
    cmp rax, 32
    jb .Lape_open_malformed
    cmp dword ptr [rsi], 0x2043414d
    jne .Lape_open_malformed
    movzx eax, word ptr [rsi + 4]
    mov [rip + ape_version], eax
    cmp eax, 3930
    jb .Lape_open_unsupported
    cmp eax, 3990
    ja .Lape_open_unsupported
    cmp eax, 3980
    jb .Lape_open_old
    # Descriptor, then the header: R12=header, R13=first frame offset,
    # R14=seek table bytes.
    mov r8d, [rsi + 8]                    # descriptor bytes
    cmp r8d, 52
    jb .Lape_open_malformed
    mov rax, rdi
    sub rax, rsi
    lea rcx, [r8 + 24]
    cmp rcx, rax
    ja .Lape_open_malformed
    lea r12, [rsi + r8]
    mov r13, r8
    mov eax, [rsi + 12]                   # header bytes
    add r13, rax
    mov r14d, [rsi + 16]                  # seek table bytes
    add r13, r14
    mov eax, [rsi + 20]                   # stored WAV header bytes
    add r13, rax
    mov eax, [rsi + 32]
    mov [rip + ape_tail], eax
    movzx eax, word ptr [r12]
    mov ebx, eax                          # compression level
    mov eax, [r12 + 4]
    mov [rip + ape_bpf], eax
    mov eax, [r12 + 8]
    mov [rip + ape_final], eax
    mov eax, [r12 + 12]
    mov [rip + ape_frames], eax
    movzx eax, word ptr [r12 + 16]
    mov [rip + ape_depth], eax
    movzx eax, word ptr [r12 + 18]
    mov [rip + ape_channels], eax
    mov r15d, [r12 + 20]                  # sample rate
    add r12, 24                           # the seek table, where FFmpeg reads it
    jmp .Lape_open_checks
.Lape_open_old:
    # Versions before 3980: one 32-byte header, optional peak level and
    # seek element count, the stored WAV header, then the seek table.
    movzx ebx, word ptr [rsi + 6]         # compression level
    movzx r9d, word ptr [rsi + 8]         # format flags
    movzx eax, word ptr [rsi + 10]
    mov [rip + ape_channels], eax
    mov r15d, [rsi + 12]
    mov r10d, [rsi + 16]                  # stored WAV header bytes
    mov eax, [rsi + 20]
    mov [rip + ape_tail], eax
    mov eax, [rsi + 24]
    mov [rip + ape_frames], eax
    mov eax, [rsi + 28]
    mov [rip + ape_final], eax
    lea r12, [rsi + 32]
    mov r13d, 32                          # header bytes
    test r9d, 4                           # peak level
    jz .Lape_open_old_peak
    add r12, 4
    add r13, 4
.Lape_open_old_peak:
    mov r14d, [rip + ape_frames]
    shl r14, 2
    test r9d, 16                          # seek element count
    jz .Lape_open_old_elements
    lea rax, [r12 + 4]
    cmp rax, rdi
    ja .Lape_open_malformed
    mov r14d, [r12]
    shl r14, 2
    add r12, 4
    add r13, 4
.Lape_open_old_elements:
    mov eax, 16
    mov ecx, 24
    test r9d, 8
    cmovnz eax, ecx
    mov ecx, 8
    test r9d, 1
    cmovnz eax, ecx
    mov [rip + ape_depth], eax
    mov eax, 73728
    mov ecx, 294912
    cmp dword ptr [rip + ape_version], 3950
    cmovae eax, ecx
    mov [rip + ape_bpf], eax
    test r9d, 32                          # the WAV header is not stored
    jnz .Lape_open_old_wav
    add r12, r10
.Lape_open_old_wav:
    add r13, r14
    add r13, r10
.Lape_open_checks:
    mov eax, [rip + ape_frames]
    test eax, eax
    jz .Lape_open_malformed
    mov rcx, r14
    shr rcx, 2
    cmp rcx, rax
    jb .Lape_open_malformed               # fewer seek entries than frames
    lea rcx, [r12 + rax*4]
    cmp rcx, rdi
    ja .Lape_open_malformed
    mov [rip + ape_table], r12
    mov eax, ebx                          # level: 1000-5000 in thousands
    xor edx, edx
    mov ecx, 1000
    div ecx
    test edx, edx
    jnz .Lape_open_malformed
    dec eax
    cmp eax, 4
    ja .Lape_open_malformed
    mov [rip + ape_fset], eax
    mov eax, [rip + ape_channels]
    test eax, eax
    jz .Lape_open_malformed
    cmp eax, 2
    ja .Lape_open_unsupported
    mov eax, [rip + ape_depth]
    cmp eax, 8
    je .Lape_open_bits
    cmp eax, 16
    je .Lape_open_bits
    cmp eax, 24
    jne .Lape_open_unsupported
.Lape_open_bits:
    test r15d, r15d
    jz .Lape_open_malformed
    cmp r15d, 8000
    jb .Lape_open_unsupported
    cmp r15d, 192000
    ja .Lape_open_unsupported
    mov eax, [rip + ape_bpf]
    test eax, eax
    jz .Lape_open_malformed
    mov ecx, [rip + ape_final]
    test ecx, ecx
    jz .Lape_open_malformed
    cmp ecx, eax
    ja .Lape_open_malformed
    # Frame 0 must start in the file; the others in increasing order.
    add r13, rsi
    jc .Lape_open_malformed
    cmp r13, rdi
    jae .Lape_open_malformed
    mov [rip + ape_first], r13
    mov ebx, 1
.Lape_open_order:
    cmp ebx, [rip + ape_frames]
    jae .Lape_open_ordered
    mov ecx, ebx
    call ape_frame_pos
    cmp rax, r13
    jbe .Lape_open_malformed
    mov r13, rax
    inc ebx
    jmp .Lape_open_order
.Lape_open_ordered:
    mov eax, [rip + ape_frames]
    dec rax
    mov ecx, [rip + ape_bpf]
    mul rcx
    mov ecx, [rip + ape_final]
    add rax, rcx
    mov [rip + total_frames], rax
    mov [rip + sample_rate], r15d
    mov eax, [rip + ape_channels]
    mov [rip + source_channels], eax
    mov eax, [rip + ape_depth]
    mov [rip + source_bits], eax
    xor ecx, ecx
    cmp eax, 24
    mov eax, -1
    cmove ecx, eax
    mov [rip + ape_interim], ecx
    mov dword ptr [rip + ape_frame], 0
    mov dword ptr [rip + ape_left], 0
    mov dword ptr [rip + ape_out_frames], 0
    mov dword ptr [rip + ape_out_used], 0
    call ape_crc_init
    mov dword ptr [rip + codec_kind], CODEC_APE
    mov eax, 1
    jmp .Lape_open_return
.Lape_open_unsupported:
    mov dword ptr [rip + decode_error], APE_UNSUPPORTED
    xor eax, eax
    jmp .Lape_open_return
.Lape_open_malformed:
    mov dword ptr [rip + decode_error], APE_MALFORMED
    xor eax, eax
.Lape_open_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_open

# The reflected CRC-32 table (polynomial 0xEDB88320), built once.
LOCALFN ape_crc_init
    cmp dword ptr [rip + ape_crc_ready], 0
    jne .Lape_crc_done
    lea r8, [rip + ape_crc_table]
    xor ecx, ecx
.Lape_crc_entry:
    mov eax, ecx
    mov edx, 8
.Lape_crc_bit:
    shr eax, 1
    jnc .Lape_crc_even
    xor eax, 0xedb88320
.Lape_crc_even:
    dec edx
    jnz .Lape_crc_bit
    mov [r8 + rcx*4], eax
    inc ecx
    cmp ecx, 256
    jb .Lape_crc_entry
    mov dword ptr [rip + ape_crc_ready], 1
.Lape_crc_done:
    ret
ENDFN ape_crc_init

# ---------------------------------------------------------------- range coder
# The frame is read as FFmpeg reads it: whole 32-bit words byte-swapped,
# bytes from ape_words to ape_avail as zeros, and none beyond.

# ECX=position -> EAX=byte of the byte-swapped frame.
LOCALFN ape_byte
    xor eax, eax
    cmp ecx, [rip + ape_words]
    jae .Lape_byte_return
    mov eax, ecx
    xor eax, 3
    mov rdx, [rip + ape_data]
    movzx eax, byte ptr [rdx + rax]
.Lape_byte_return:
    ret
ENDFN ape_byte

# Shifts bytes in until the range exceeds 2^23. Clobbers RAX, RDX, R8-R11.
LOCALFN ape_normalize
    mov eax, [rip + rc_range]
    cmp eax, 0x800000
    ja .Lape_norm_return
    mov r8d, [rip + rc_buffer]
    mov r9d, [rip + rc_low]
    mov r10d, [rip + ape_pos]
    mov r11, [rip + ape_data]
.Lape_norm_loop:
    shl r8d, 8
    cmp r10d, [rip + ape_avail]
    jae .Lape_norm_past
    cmp r10d, [rip + ape_words]
    jae .Lape_norm_zero
    mov edx, r10d
    xor edx, 3
    movzx edx, byte ptr [r11 + rdx]
    add r8d, edx
.Lape_norm_zero:
    inc r10d
    jmp .Lape_norm_byte
.Lape_norm_past:
    mov dword ptr [rip + ape_error], 1
.Lape_norm_byte:
    mov edx, r8d
    shr edx, 1
    and edx, 0xff
    shl r9d, 8
    or r9d, edx
    shl eax, 8
    cmp eax, 0x800000
    jbe .Lape_norm_loop
    mov [rip + rc_range], eax
    mov [rip + rc_buffer], r8d
    mov [rip + rc_low], r9d
    mov [rip + ape_pos], r10d
.Lape_norm_return:
    ret
ENDFN ape_normalize

# ECX=total frequency -> EAX=cumulative frequency (no update). Keeps RCX.
LOCALFN ape_culfreq
    call ape_normalize
    mov eax, [rip + rc_range]
    xor edx, edx
    div ecx
    mov [rip + rc_help], eax
    mov r8d, eax
    mov eax, [rip + rc_low]
    xor edx, edx
    div r8d
    ret
ENDFN ape_culfreq

# ECX=shift -> EAX=value of that many bits' total (no update).
LOCALFN ape_culshift
    call ape_normalize
    mov eax, [rip + rc_range]
    shr eax, cl
    mov [rip + rc_help], eax
    mov r8d, eax
    mov eax, [rip + rc_low]
    xor edx, edx
    div r8d
    ret
ENDFN ape_culshift

# ECX=symbol frequency, EDX=frequencies below it. Clobbers RAX, RDX.
LOCALFN ape_update
    mov eax, [rip + rc_help]
    imul edx, eax
    sub [rip + rc_low], edx
    imul eax, ecx
    mov [rip + rc_range], eax
    ret
ENDFN ape_update

# ECX=bits (0-16) -> EAX=their value, uniformly coded. Keeps R9 = EAX.
LOCALFN ape_bits
    call ape_culshift
    mov r9d, eax
    mov edx, eax
    mov ecx, 1
    call ape_update
    mov eax, r9d
    ret
ENDFN ape_bits

# RCX=cumulative frequency table -> EAX=overflow symbol (0-63; larger ones
# are damage and set ape_error).
LOCALFN ape_symbol
    push rbx
    mov rbx, rcx
    mov ecx, 16
    call ape_culshift
    cmp eax, 65492
    ja .Lape_symbol_high
    xor ecx, ecx
.Lape_symbol_search:
    movzx edx, word ptr [rbx + rcx*2 + 2]
    cmp edx, eax
    ja .Lape_symbol_found
    inc ecx
    jmp .Lape_symbol_search
.Lape_symbol_found:
    mov r9d, ecx
    movzx edx, word ptr [rbx + rcx*2]
    movzx ecx, word ptr [rbx + rcx*2 + 2]
    sub ecx, edx
    call ape_update
    mov eax, r9d
    pop rbx
    ret
.Lape_symbol_high:
    lea r9d, [rax - 65472]
    cmp eax, 65535
    jbe .Lape_symbol_valid
    mov dword ptr [rip + ape_error], 1
.Lape_symbol_valid:
    mov edx, eax
    mov ecx, 1
    call ape_update
    mov eax, r9d
    pop rbx
    ret
ENDFN ape_symbol

# RCX=Rice parameters (k, ksum), EDX=value: adapts them. Keeps RDX.
LOCALFN ape_rice_update
    mov r11, rcx
    mov r8d, [r11]
    mov r9d, [r11 + 4]
    lea eax, [rdx + 1]
    shr eax, 1
    lea r10d, [r9 + 16]
    shr r10d, 5
    add r9d, eax
    sub r9d, r10d
    mov [r11 + 4], r9d
    test r8d, r8d
    jz .Lape_rice_up
    lea ecx, [r8 + 4]
    mov eax, 1
    shl eax, cl
    cmp r9d, eax
    jae .Lape_rice_up
    dec r8d
    mov [r11], r8d
    ret
.Lape_rice_up:
    cmp r8d, 24
    jae .Lape_rice_return
    lea ecx, [r8 + 5]
    mov eax, 1
    shl eax, cl
    cmp r9d, eax
    jb .Lape_rice_return
    inc r8d
    mov [r11], r8d
.Lape_rice_return:
    ret
ENDFN ape_rice_update

# RCX=Rice parameters -> EAX=signed residual, version 3990 and later: the
# overflow counts multiples of a pivot from the parameter sum.
LOCALFN ape_value_3990
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rsi, rcx
    mov ebx, [rsi + 4]
    shr ebx, 5
    mov eax, 1
    cmovz ebx, eax                        # pivot
    lea rcx, [rip + ape_counts_3980]
    call ape_symbol
    mov edi, eax                          # overflow
    cmp eax, 63
    jne .Lape_v90_base
    mov ecx, 16
    call ape_bits
    mov edi, eax
    shl edi, 16
    mov ecx, 16
    call ape_bits
    or edi, eax
.Lape_v90_base:
    cmp ebx, 0x10000
    jae .Lape_v90_wide
    mov ecx, ebx
    call ape_culfreq
    mov r12d, eax
    mov edx, eax
    mov ecx, 1
    call ape_update
    jmp .Lape_v90_value
.Lape_v90_wide:
    mov eax, ebx                          # the high part, below 2^16
    xor r12d, r12d                        # its shift
.Lape_v90_shift:
    test eax, 0xffff0000
    jz .Lape_v90_high
    shr eax, 1
    inc r12d
    jmp .Lape_v90_shift
.Lape_v90_high:
    lea ecx, [rax + 1]
    call ape_culfreq
    mov r13d, eax
    mov edx, eax
    mov ecx, 1
    call ape_update
    mov ecx, r12d
    shl r13d, cl
    mov eax, 1
    shl eax, cl
    mov ecx, eax
    call ape_culfreq
    mov r12d, eax
    mov edx, eax
    mov ecx, 1
    call ape_update
    add r12d, r13d
.Lape_v90_value:
    mov edx, edi
    imul edx, ebx
    add edx, r12d                         # base + overflow * pivot
    mov rcx, rsi
    call ape_rice_update
    mov eax, edx
    shr eax, 1
    and edx, 1
    dec edx
    xor eax, edx
    inc eax
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_value_3990

# RCX=Rice parameters -> EAX=signed residual, versions 3930-3989: the
# overflow above k-1 bits, or an escape sending the bit count.
LOCALFN ape_value_3900
    push rbx
    push rsi
    push rdi
    push r12
    mov rsi, rcx
    lea rcx, [rip + ape_counts_3970]
    call ape_symbol
    mov edi, eax                          # overflow
    cmp eax, 63
    jne .Lape_v39_k
    mov ecx, 5
    call ape_bits
    mov ebx, eax
    xor edi, edi
    jmp .Lape_v39_bits
.Lape_v39_k:
    mov ebx, [rsi]
    test ebx, ebx
    jz .Lape_v39_bits
    dec ebx
.Lape_v39_bits:
    cmp ebx, 16
    ja .Lape_v39_wide
    mov ecx, ebx
    call ape_bits
    jmp .Lape_v39_add
.Lape_v39_wide:
    mov ecx, 16
    call ape_bits
    mov r12d, eax
    lea ecx, [rbx - 16]
    call ape_bits
    shl eax, 16
    or eax, r12d
.Lape_v39_add:
    mov ecx, ebx
    shl edi, cl
    lea edx, [rax + rdi]
    mov rcx, rsi
    call ape_rice_update
    mov eax, edx
    shr eax, 1
    and edx, 1
    dec edx
    xor eax, edx
    inc eax
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_value_3900

# ECX=blocks, EDX=1 for two channels: residuals into ape_decoded, the
# channels interleaved block by block.
LOCALFN ape_entropy
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov ebx, ecx
    mov r12d, edx
    lea rsi, [rip + ape_decoded]
    lea rdi, [rsi + APE_CHUNK*4]
    lea r13, [rip + ape_value_3990]
    lea rax, [rip + ape_value_3900]
    cmp dword ptr [rip + ape_version], 3990
    cmovb r13, rax
.Lape_entropy_block:
    lea rcx, [rip + ape_rice]
    call r13
    mov [rsi], eax
    add rsi, 4
    test r12d, r12d
    jz .Lape_entropy_next
    lea rcx, [rip + ape_rice + 8]
    call r13
    mov [rdi], eax
    add rdi, 4
.Lape_entropy_next:
    dec ebx
    jnz .Lape_entropy_block
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_entropy

# ------------------------------------------------------------------- filters
# RCX=filter, RDX=data, R8D=blocks, R9D=order | fraction bits << 16. One
# sign-LMS filter in place: the output adds the rounded product of the
# coefficients and the last outputs (clipped to 16 bits), and the
# coefficients move by the residual's sign times the recent adaption values.
LOCALFN ape_filter
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rbx, rcx
    mov rsi, rdx
    mov r12d, r8d
    movzx r13d, r9w                       # order
    shr r9d, 16
    mov r14d, r9d                         # fraction bits
    mov r15d, [rbx + F_POS]
    lea ecx, [r14 - 1]
    mov ebp, 1
    shl rbp, cl                           # rounding
    test r12d, r12d
    jz .Lape_filter_return
.Lape_filter_sample:
    mov eax, [rsi]
    xor ecx, ecx
    xor edx, edx
    test eax, eax
    setl cl
    setg dl
    sub ecx, edx                          # APESIGN of the input
    movd xmm5, ecx
    pshuflw xmm5, xmm5, 0
    punpcklqdq xmm5, xmm5
    lea rdi, [rbx + F_HIST + r15*2]       # the last outputs
    mov rdx, rdi
    sub rdx, r13
    sub rdx, r13                          # the last adaption values
    lea r8, [rbx + F_COEFFS]
    mov ecx, r13d
    shr ecx, 4
    pxor xmm4, xmm4
.Lape_filter_dot:
    movdqu xmm0, [rdi]
    movdqu xmm1, [rdi + 16]
    movdqa xmm2, [r8]
    movdqa xmm3, [r8 + 16]
    pmaddwd xmm0, xmm2
    pmaddwd xmm1, xmm3
    paddd xmm4, xmm0
    paddd xmm4, xmm1
    movdqu xmm0, [rdx]
    movdqu xmm1, [rdx + 16]
    pmullw xmm0, xmm5
    pmullw xmm1, xmm5
    paddw xmm2, xmm0
    paddw xmm3, xmm1
    movdqa [r8], xmm2
    movdqa [r8 + 16], xmm3
    add rdi, 32
    add rdx, 32
    add r8, 32
    dec ecx
    jnz .Lape_filter_dot
    pshufd xmm0, xmm4, 0x4e
    paddd xmm4, xmm0
    pshufd xmm0, xmm4, 0xb1
    paddd xmm4, xmm0
    movd eax, xmm4
    add eax, ebp                          # 32-bit, as Monkey's Audio rounds
    mov ecx, r14d
    sar eax, cl
    add eax, [rsi]
    mov [rsi], eax
    add rsi, 4
    mov r8d, eax                          # the output
    mov edx, 32767
    cmp eax, edx
    cmovg eax, edx
    mov edx, -32768
    cmp eax, edx
    cmovl eax, edx
    lea r9, [r15 + r13]
    mov [rbx + F_HIST + r9*2], ax
    lea r10, [rbx + F_HIST + r15*2]       # this block's adaption value
    cmp dword ptr [rip + ape_version], 3980
    jb .Lape_filter_old
    mov edx, r8d                          # |output|, unsigned
    neg edx
    cmovl edx, r8d
    test edx, edx
    jz .Lape_filter_still
    mov r9d, [rbx + F_AVG]
    xor ecx, ecx
    lea r11, [r9 + r9*2]
    cmp rdx, r11
    seta cl                               # above three times the average
    mov eax, r9d
    mov r11d, 0xaaaaaaab
    imul rax, r11
    shr rax, 33
    add eax, r9d
    xor r11d, r11d
    cmp edx, eax
    seta r11b                             # above 4/3 of it
    add ecx, r11d
    mov eax, 8
    shl eax, cl
    mov ecx, eax
    neg ecx
    test r8d, r8d
    cmovg eax, ecx                        # APESIGN: negative for positive output
    mov [r10], ax
    jmp .Lape_filter_average
.Lape_filter_still:
    mov word ptr [r10], 0
.Lape_filter_average:
    mov r9d, [rbx + F_AVG]
    mov eax, edx
    sub eax, r9d
    mov r11d, eax
    sar r11d, 31
    and r11d, 15
    add eax, r11d
    sar eax, 4                            # (int)(|output| - average) / 16
    add eax, r9d
    mov [rbx + F_AVG], eax
    sar word ptr [r10 - 2], 1
    sar word ptr [r10 - 4], 1
    sar word ptr [r10 - 16], 1
    jmp .Lape_filter_advance
.Lape_filter_old:
    xor edx, edx                          # before 3980: -4, 4 or 0
    test r8d, r8d
    jz .Lape_filter_old_store
    mov edx, r8d
    sar edx, 28
    and edx, 8
    sub edx, 4
.Lape_filter_old_store:
    mov [r10], dx
    sar word ptr [r10 - 8], 1
    sar word ptr [r10 - 16], 1
.Lape_filter_advance:
    inc r15d
    lea eax, [r13 + HISTORY]
    cmp r15d, eax
    jne .Lape_filter_next
    push rsi                              # keep the last 2*order values
    lea rdi, [rbx + F_HIST]
    lea rsi, [rbx + F_HIST + HISTORY*2]
    lea ecx, [r13 + r13]
    rep movsw
    pop rsi
    mov r15d, r13d
.Lape_filter_next:
    dec r12d
    jnz .Lape_filter_sample
    mov [rbx + F_POS], r15d
.Lape_filter_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN ape_filter

# ECX=blocks, EDX=1 for two channels: the level's filters, first to last.
LOCALFN ape_filters_run
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, ecx
    mov r13d, edx
    xor ebx, ebx                          # level
.Lape_filters_level:
    cmp ebx, 3
    jae .Lape_filters_return
    imul eax, [rip + ape_fset], 3
    add eax, ebx
    lea rcx, [rip + ape_orders]
    movzx esi, word ptr [rcx + rax*2]
    test esi, esi
    jz .Lape_filters_return
    lea rcx, [rip + ape_fracbits]
    movzx edi, byte ptr [rcx + rax]
    shl edi, 16
    or edi, esi
    imul ecx, ebx, 2*F_SIZE
    lea rsi, [rip + ape_filters]
    add rsi, rcx
    mov rcx, rsi
    lea rdx, [rip + ape_decoded]
    mov r8d, r12d
    mov r9d, edi
    call ape_filter
    test r13d, r13d
    jz .Lape_filters_next
    lea rcx, [rsi + F_SIZE]
    lea rdx, [rip + ape_decoded + APE_CHUNK*4]
    mov r8d, r12d
    mov r9d, edi
    call ape_filter
.Lape_filters_next:
    inc ebx
    jmp .Lape_filters_level
.Lape_filters_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_filters_run

# ---------------------------------------------------------------- predictors
# RBX=predictor: after a full history, keep its last PRED_SIZE entries.
.macro HISTORY_WRAP
    lea rcx, [rbx + P_HIST + HISTORY*8]
    cmp r13, rcx
    jne 9f
    lea r13, [rbx + P_HIST]
    mov edx, PRED_SIZE
8:
    mov rax, [r13 + HISTORY*8]
    mov [r13], rax
    add r13, 8
    dec edx
    jnz 8b
    lea r13, [rbx + P_HIST]
9:
.endm

# 3950 stereo filter step: RBX=predictor, R13=buf, R8D=input, R14D=1 for
# 64-bit arithmetic -> EAX=output.
.macro UPDATE_3950 f, dA, dB, adA, adB
    mov rax, [rbx + P_LASTA + \f*8]
    mov [r13 + \dA*8], rax
    SIGN64 rax
    mov [r13 + \adA*8], rcx
    mov rdx, rax
    sub rdx, [r13 + (\dA-1)*8]
    mov [r13 + (\dA-1)*8], rdx
    SIGN64 rdx
    mov [r13 + (\adA-1)*8], rcx
    imul rax, [rbx + P_COEFFA + \f*32]
    imul rdx, [rbx + P_COEFFA + \f*32 + 8]
    add rax, rdx
    mov rdx, [r13 + (\dA-2)*8]
    imul rdx, [rbx + P_COEFFA + \f*32 + 16]
    add rax, rdx
    mov rdx, [r13 + (\dA-3)*8]
    imul rdx, [rbx + P_COEFFA + \f*32 + 24]
    add rax, rdx
    mov r9, rax                           # prediction A
    mov rax, [rbx + P_FILTERB + \f*8]
    imul rax, rax, 31
    sar rax, 5
    mov rdx, [rbx + P_FILTERA + (1-\f)*8]
    mov [rbx + P_FILTERB + \f*8], rdx
    sub rdx, rax
    mov [r13 + \dB*8], rdx
    SIGN64 rdx
    mov [r13 + \adB*8], rcx
    mov rax, rdx
    sub rax, [r13 + (\dB-1)*8]
    mov [r13 + (\dB-1)*8], rax
    SIGN64 rax
    mov [r13 + (\adB-1)*8], rcx
    imul rdx, [rbx + P_COEFFB + \f*40]
    imul rax, [rbx + P_COEFFB + \f*40 + 8]
    add rdx, rax
    mov rax, [r13 + (\dB-2)*8]
    imul rax, [rbx + P_COEFFB + \f*40 + 16]
    add rdx, rax
    mov rax, [r13 + (\dB-3)*8]
    imul rax, [rbx + P_COEFFB + \f*40 + 24]
    add rdx, rax
    mov rax, [r13 + (\dB-4)*8]
    imul rax, [rbx + P_COEFFB + \f*40 + 32]
    add rdx, rax                          # prediction B
    test r14d, r14d
    jnz 1f
    sar edx, 1                            # 32-bit: both predictions truncated
    add r9d, edx
    sar r9d, 10
    add r9d, r8d
    movsxd r9, r9d
    jmp 2f
1:
    sar rdx, 1
    add r9, rdx
    sar r9, 10
    movsxd rax, r8d
    add r9, rax
2:
    mov [rbx + P_LASTA + \f*8], r9
    mov rax, [rbx + P_FILTERA + \f*8]
    imul rax, rax, 31
    sar rax, 5
    add rax, r9
    mov [rbx + P_FILTERA + \f*8], rax
    test r8d, r8d
    jz 4f
    jg 3f
    mov rcx, [r13 + \adA*8]               # negative input: add the signs
    add [rbx + P_COEFFA + \f*32], rcx
    mov rcx, [r13 + (\adA-1)*8]
    add [rbx + P_COEFFA + \f*32 + 8], rcx
    mov rcx, [r13 + (\adA-2)*8]
    add [rbx + P_COEFFA + \f*32 + 16], rcx
    mov rcx, [r13 + (\adA-3)*8]
    add [rbx + P_COEFFA + \f*32 + 24], rcx
    mov rcx, [r13 + \adB*8]
    add [rbx + P_COEFFB + \f*40], rcx
    mov rcx, [r13 + (\adB-1)*8]
    add [rbx + P_COEFFB + \f*40 + 8], rcx
    mov rcx, [r13 + (\adB-2)*8]
    add [rbx + P_COEFFB + \f*40 + 16], rcx
    mov rcx, [r13 + (\adB-3)*8]
    add [rbx + P_COEFFB + \f*40 + 24], rcx
    mov rcx, [r13 + (\adB-4)*8]
    add [rbx + P_COEFFB + \f*40 + 32], rcx
    jmp 4f
3:
    mov rcx, [r13 + \adA*8]               # positive input: subtract them
    sub [rbx + P_COEFFA + \f*32], rcx
    mov rcx, [r13 + (\adA-1)*8]
    sub [rbx + P_COEFFA + \f*32 + 8], rcx
    mov rcx, [r13 + (\adA-2)*8]
    sub [rbx + P_COEFFA + \f*32 + 16], rcx
    mov rcx, [r13 + (\adA-3)*8]
    sub [rbx + P_COEFFA + \f*32 + 24], rcx
    mov rcx, [r13 + \adB*8]
    sub [rbx + P_COEFFB + \f*40], rcx
    mov rcx, [r13 + (\adB-1)*8]
    sub [rbx + P_COEFFB + \f*40 + 8], rcx
    mov rcx, [r13 + (\adB-2)*8]
    sub [rbx + P_COEFFB + \f*40 + 16], rcx
    mov rcx, [r13 + (\adB-3)*8]
    sub [rbx + P_COEFFB + \f*40 + 24], rcx
    mov rcx, [r13 + (\adB-4)*8]
    sub [rbx + P_COEFFB + \f*40 + 32], rcx
4:
.endm

# ECX=blocks: filters, then the 3950 predictor on both channels. An
# undecided 24-bit stream runs the 32-bit and the 64-bit predictor on copies
# and keeps the first whose mid/side output stays within 24 bits.
LOCALFN ape_predict_stereo_3950
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov ebp, ecx                          # blocks
    mov edx, 1
    call ape_filters_run
    mov r15d, 1                           # passes
    cmp dword ptr [rip + ape_interim], -1
    jne .Lape_ps_passes
    mov r15d, 2
    lea rsi, [rip + ape_pred]
    lea rdi, [rip + ape_pred2]
    mov ecx, P_SIZE/8
    rep movsq
    lea rsi, [rip + ape_decoded]
    lea rdi, [rip + ape_spare]
    mov ecx, APE_CHUNK*2
    rep movsd
.Lape_ps_passes:
    mov dword ptr [rsp + 32], 0           # pass
.Lape_ps_pass:
    mov eax, [rsp + 32]
    cmp eax, r15d
    jae .Lape_ps_choose
    xor r14d, r14d
    cmp dword ptr [rip + ape_interim], 0
    setg r14b
    or r14d, eax                          # 64-bit in the second pass
    lea rbx, [rip + ape_pred]
    lea rsi, [rip + ape_decoded]
    test eax, eax
    jz .Lape_ps_buffers
    lea rbx, [rip + ape_pred2]
    lea rsi, [rip + ape_spare]
.Lape_ps_buffers:
    lea rdi, [rsi + APE_CHUNK*4]
    lea r13, [rbx + P_HIST]               # each pass restarts the history pointer
    mov r12d, ebp
    test r12d, r12d
    jz .Lape_ps_pass_done
.Lape_ps_block:
    mov r8d, [rsi]
    UPDATE_3950 0, YDELAYA, YDELAYB, YADAPTA, YADAPTB
    mov eax, [rbx + P_FILTERA]
    mov [rsi], eax
    mov r8d, [rdi]
    UPDATE_3950 1, XDELAYA, XDELAYB, XADAPTA, XADAPTB
    mov eax, [rbx + P_FILTERA + 8]
    mov [rdi], eax
    cmp r15d, 2
    jne .Lape_ps_advance
    mov eax, [rsi]                        # a0
    mov edx, [rdi]                        # a1
    mov ecx, eax
    shr ecx, 31
    add ecx, eax
    sar ecx, 1
    mov r8d, edx
    sub r8d, ecx                          # left
    lea r9d, [r8 + rax]                   # right
    mov r10d, r8d
    neg r10d
    cmovl r10d, r8d
    mov r11d, r9d
    neg r11d
    cmovl r11d, r9d
    cmp r10d, r11d
    cmovl r10d, r11d
    cmp r10d, 0x800000
    jle .Lape_ps_advance
    xor eax, eax                          # beyond 24 bits: try the other one
    test r14d, r14d
    sete al
    mov [rip + ape_interim], eax
    jmp .Lape_ps_pass_done
.Lape_ps_advance:
    add r13, 8
    HISTORY_WRAP
    add rsi, 4
    add rdi, 4
    dec r12d
    jnz .Lape_ps_block
.Lape_ps_pass_done:
    lea rax, [rbx + P_HIST]
    sub r13, rax
    shr r13, 3
    mov [rbx + P_BUF], r13
    inc dword ptr [rsp + 32]
    jmp .Lape_ps_pass
.Lape_ps_choose:
    cmp r15d, 2
    jne .Lape_ps_return
    cmp dword ptr [rip + ape_interim], 0
    jle .Lape_ps_return
    lea rsi, [rip + ape_spare]
    lea rdi, [rip + ape_decoded]
    mov ecx, APE_CHUNK*2
    rep movsd
    lea rsi, [rip + ape_pred2]
    lea rdi, [rip + ape_pred]
    mov ecx, P_SIZE/8
    rep movsq
    mov qword ptr [rip + ape_pred + P_BUF], 0
.Lape_ps_return:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN ape_predict_stereo_3950

# ECX=blocks: filters, then the 3950 predictor on one channel.
LOCALFN ape_predict_mono_3950
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov r12d, ecx
    xor edx, edx
    call ape_filters_run
    lea rbx, [rip + ape_pred]
    lea rsi, [rip + ape_decoded]
    mov r13, [rbx + P_BUF]
    lea r13, [rbx + P_HIST + r13*8]
    mov r14d, [rbx + P_LASTA]             # current A
    test r12d, r12d
    jz .Lape_pm_done
.Lape_pm_block:
    mov r8d, [rsi]
    movsxd rax, r14d
    mov [r13 + YDELAYA*8], rax
    mov rdx, rax
    sub rdx, [r13 + (YDELAYA-1)*8]
    mov [r13 + (YDELAYA-1)*8], rdx
    mov r9, rax
    imul r9, [rbx + P_COEFFA]
    mov r10, rdx
    imul r10, [rbx + P_COEFFA + 8]
    add r9, r10
    mov r10, [r13 + (YDELAYA-2)*8]
    imul r10, [rbx + P_COEFFA + 16]
    add r9, r10
    mov r10, [r13 + (YDELAYA-3)*8]
    imul r10, [rbx + P_COEFFA + 24]
    add r9, r10
    sar r9d, 10                           # 32-bit prediction
    add r9d, r8d
    mov r14d, r9d
    SIGN64 rax
    mov [r13 + YADAPTA*8], rcx
    SIGN64 rdx
    mov [r13 + (YADAPTA-1)*8], rcx
    test r8d, r8d
    jz .Lape_pm_adapted
    jg .Lape_pm_positive
    mov rcx, [r13 + YADAPTA*8]
    add [rbx + P_COEFFA], rcx
    mov rcx, [r13 + (YADAPTA-1)*8]
    add [rbx + P_COEFFA + 8], rcx
    mov rcx, [r13 + (YADAPTA-2)*8]
    add [rbx + P_COEFFA + 16], rcx
    mov rcx, [r13 + (YADAPTA-3)*8]
    add [rbx + P_COEFFA + 24], rcx
    jmp .Lape_pm_adapted
.Lape_pm_positive:
    mov rcx, [r13 + YADAPTA*8]
    sub [rbx + P_COEFFA], rcx
    mov rcx, [r13 + (YADAPTA-1)*8]
    sub [rbx + P_COEFFA + 8], rcx
    mov rcx, [r13 + (YADAPTA-2)*8]
    sub [rbx + P_COEFFA + 16], rcx
    mov rcx, [r13 + (YADAPTA-3)*8]
    sub [rbx + P_COEFFA + 24], rcx
.Lape_pm_adapted:
    add r13, 8
    HISTORY_WRAP
    mov rax, [rbx + P_FILTERA]
    imul rax, rax, 31
    sar rax, 5
    movsxd rcx, r14d
    add rax, rcx
    mov [rbx + P_FILTERA], rax
    mov [rsi], eax
    add rsi, 4
    dec r12d
    jnz .Lape_pm_block
.Lape_pm_done:
    movsxd rax, r14d
    mov [rbx + P_LASTA], rax
    lea rax, [rbx + P_HIST]
    sub r13, rax
    shr r13, 3
    mov [rbx + P_BUF], r13
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
ENDFN ape_predict_mono_3950

# 3930 step on 32-bit values: RBX=predictor, R13=buf, R8D=input -> EAX.
.macro UPDATE_3930 f, dA
    mov eax, [rbx + P_LASTA + \f*8]
    mov [r13 + \dA*8], eax
    mov r9d, eax                          # d0
    mov r10d, eax
    sub r10d, [r13 + (\dA-1)*8]           # d1
    mov r11d, [r13 + (\dA-1)*8]
    sub r11d, [r13 + (\dA-2)*8]           # d2
    mov edx, [r13 + (\dA-2)*8]
    sub edx, [r13 + (\dA-3)*8]            # d3
    imul eax, [rbx + P_COEFFA + \f*32]
    mov ecx, r10d
    imul ecx, [rbx + P_COEFFA + \f*32 + 8]
    add eax, ecx
    mov ecx, r11d
    imul ecx, [rbx + P_COEFFA + \f*32 + 16]
    add eax, ecx
    mov ecx, edx
    imul ecx, [rbx + P_COEFFA + \f*32 + 24]
    add eax, ecx
    sar eax, 9
    add eax, r8d
    mov [rbx + P_LASTA + \f*8], eax
    mov ecx, [rbx + P_FILTERA + \f*8]
    imul ecx, ecx, 31
    sar ecx, 5
    add eax, ecx
    mov [rbx + P_FILTERA + \f*8], eax
    test r8d, r8d
    jz 1f
    xor r9d, r8d                          # same signs: +1, else -1
    sar r9d, 31
    lea r9d, [r9*2 + 1]
    add [rbx + P_COEFFA + \f*32], r9d
    xor r10d, r8d
    sar r10d, 31
    lea r10d, [r10*2 + 1]
    add [rbx + P_COEFFA + \f*32 + 8], r10d
    xor r11d, r8d
    sar r11d, 31
    lea r11d, [r11*2 + 1]
    add [rbx + P_COEFFA + \f*32 + 16], r11d
    xor edx, r8d
    sar edx, 31
    lea edx, [rdx*2 + 1]
    add [rbx + P_COEFFA + \f*32 + 24], edx
1:
.endm

# ECX=blocks, EDX=1 for two channels: filters, then the 3930 predictor.
LOCALFN ape_predict_3930
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12d, ecx
    mov r15d, edx
    call ape_filters_run
    lea rbx, [rip + ape_pred]
    lea rsi, [rip + ape_decoded]
    lea rdi, [rsi + APE_CHUNK*4]
    mov r13, [rbx + P_BUF]
    lea r13, [rbx + P_HIST + r13*8]
    test r12d, r12d
    jz .Lape_p30_done
.Lape_p30_block:
    test r15d, r15d
    jnz .Lape_p30_stereo
    mov r8d, [rsi]
    UPDATE_3930 0, YDELAYA
    mov [rsi], eax
    jmp .Lape_p30_advance
.Lape_p30_stereo:
    mov r14d, [rsi]                       # X; Y is the second channel
    mov r8d, [rdi]
    UPDATE_3930 0, YDELAYA
    mov [rsi], eax
    mov r8d, r14d
    UPDATE_3930 1, XDELAYA
    mov [rdi], eax
.Lape_p30_advance:
    add r13, 8
    HISTORY_WRAP
    add rsi, 4
    add rdi, 4
    dec r12d
    jnz .Lape_p30_block
.Lape_p30_done:
    lea rax, [rbx + P_HIST]
    sub r13, rax
    shr r13, 3
    mov [rbx + P_BUF], r13
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_predict_3930

# ------------------------------------------------------------------- frames
# Opens frame ape_frame: its data as FFmpeg's demuxer cuts it (from the word
# holding its start to the next frame's, the last one to the file end less
# the WAV tail), the CRC and flags, the coder and fresh filter and predictor
# state. EAX=1, or 0 when the data is too short.
LOCALFN ape_start_frame
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ebx, [rip + ape_frame]
    mov ecx, ebx
    call ape_frame_pos
    mov rsi, rax
    lea ecx, [rbx + 1]
    cmp ecx, [rip + ape_frames]
    jae .Lape_start_last
    call ape_frame_pos
    mov rdi, rax
    sub rdi, rsi
    jmp .Lape_start_sized
.Lape_start_last:
    mov rdi, [rip + ape_end]
    sub rdi, rsi
    mov eax, [rip + ape_tail]
    sub rdi, rax
    and rdi, -4
    test rdi, rdi
    jg .Lape_start_sized
    mov edi, [rip + ape_final]
    shl rdi, 3
.Lape_start_sized:
    mov rax, rsi
    sub rax, [rip + ape_first]
    and eax, 3
    mov r12d, eax                         # skip within the first word
    sub rsi, r12
    add rdi, r12
    add rdi, 3
    and rdi, -4
    mov rax, [rip + ape_end]
    sub rax, rsi
    jae .Lape_start_inside
    xor eax, eax
.Lape_start_inside:
    cmp rdi, rax
    cmova rdi, rax
    mov eax, 0x7ffffffc
    cmp rdi, rax
    cmova rdi, rax
    and edi, -4
    mov [rip + ape_data], rsi
    mov [rip + ape_words], edi
    cmp dword ptr [rip + ape_version], 3950
    jae .Lape_start_avail
    add edi, 2                            # earlier versions read two zeros more
.Lape_start_avail:
    mov [rip + ape_avail], edi
    mov eax, edi
    sub eax, r12d
    jb .Lape_start_short
    cmp eax, 6
    jl .Lape_start_short
    mov ecx, r12d
    call ape_be32
    mov [rip + ape_crc], eax
    add r12d, 4
    mov dword ptr [rip + ape_flags], 0
    test eax, eax
    jns .Lape_start_coder
    and eax, 0x7fffffff
    mov [rip + ape_crc], eax
    mov eax, edi
    sub eax, r12d
    cmp eax, 6
    jl .Lape_start_short
    mov ecx, r12d
    call ape_be32
    mov [rip + ape_flags], eax
    add r12d, 4
.Lape_start_coder:
    inc r12d                              # the first byte is unused
    mov ecx, r12d
    call ape_byte
    inc r12d
    mov [rip + rc_buffer], eax
    shr eax, 1
    mov [rip + rc_low], eax
    mov dword ptr [rip + rc_range], 128
    mov [rip + ape_pos], r12d
    mov dword ptr [rip + ape_rice], 10
    mov dword ptr [rip + ape_rice + 4], 16384
    mov dword ptr [rip + ape_rice + 8], 10
    mov dword ptr [rip + ape_rice + 12], 16384
    lea rdi, [rip + ape_pred]
    xor eax, eax
    mov ecx, P_SIZE/8
    rep stosq
    lea rsi, [rip + ape_initial]
    lea rdi, [rip + ape_pred + P_COEFFA]
    mov ecx, 4
    rep movsq
    lea rsi, [rip + ape_initial]
    mov ecx, 4
    rep movsq
    call ape_filters_reset
    mov dword ptr [rip + ape_crc_state], -1
    mov eax, [rip + ape_bpf]
    mov ecx, [rip + ape_frames]
    dec ecx
    cmp ebx, ecx
    cmove eax, [rip + ape_final]
    mov [rip + ape_left], eax
    xor eax, eax
    cmp dword ptr [rip + ape_channels], 1
    sete al
    test dword ptr [rip + ape_flags], FLAG_PSEUDO_STEREO
    setnz cl
    or al, cl
    mov [rip + ape_mono], eax
    inc dword ptr [rip + ape_frame]
    mov eax, 1
    jmp .Lape_start_return
.Lape_start_short:
    xor eax, eax
.Lape_start_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_start_frame

# ECX=position -> EAX=big-endian 32 bits of the byte-swapped frame.
LOCALFN ape_be32
    push rbx
    push rsi
    push rdi
    mov esi, ecx
    xor ebx, ebx
    mov edi, 4
.Lape_be32_byte:
    mov ecx, esi
    call ape_byte
    shl ebx, 8
    or ebx, eax
    inc esi
    dec edi
    jnz .Lape_be32_byte
    mov eax, ebx
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_be32

# Clears every filter of the compression level.
LOCALFN ape_filters_reset
    push rdi
    push rsi
    push rbx
    xor ebx, ebx
.Lape_reset_level:
    cmp ebx, 3
    jae .Lape_reset_return
    imul eax, [rip + ape_fset], 3
    add eax, ebx
    lea rcx, [rip + ape_orders]
    movzx esi, word ptr [rcx + rax*2]     # order
    test esi, esi
    jz .Lape_reset_return
    imul edx, ebx, 2*F_SIZE
    lea r8, [rip + ape_filters]
    add r8, rdx
    mov r9d, 2
.Lape_reset_channel:
    lea rdi, [r8 + F_COEFFS]
    mov ecx, esi
    xor eax, eax
    rep stosw
    lea rdi, [r8 + F_HIST]
    lea ecx, [rsi + rsi]
    rep stosw
    mov dword ptr [r8 + F_AVG], 0
    mov [r8 + F_POS], esi
    add r8, F_SIZE
    dec r9d
    jnz .Lape_reset_channel
    inc ebx
    jmp .Lape_reset_level
.Lape_reset_return:
    pop rbx
    pop rsi
    pop rdi
    ret
ENDFN ape_filters_reset

# Decodes the next pass of the open frame into ape_out. EAX=1, or 0 when it
# is damaged (data overread, a symbol out of range, or the frame's CRC).
LOCALFN ape_decode_chunk
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov ebx, [rip + ape_left]
    mov eax, APE_CHUNK
    cmp ebx, eax
    cmova ebx, eax                        # blocks
    lea rdi, [rip + ape_decoded]
    xor eax, eax
    mov ecx, APE_CHUNK*2
    rep stosd
    mov dword ptr [rip + ape_error], 0
    mov eax, [rip + ape_flags]
    cmp dword ptr [rip + ape_mono], 0
    je .Lape_chunk_stereo
    test eax, FLAG_SILENCE
    jnz .Lape_chunk_copy
    mov ecx, ebx
    xor edx, edx
    call ape_entropy
    cmp dword ptr [rip + ape_error], 0
    jne .Lape_chunk_bad
    mov ecx, ebx
    xor edx, edx
    cmp dword ptr [rip + ape_version], 3950
    jb .Lape_chunk_mono_3930
    call ape_predict_mono_3950
    jmp .Lape_chunk_copy
.Lape_chunk_mono_3930:
    call ape_predict_3930
.Lape_chunk_copy:
    cmp dword ptr [rip + ape_channels], 2
    jne .Lape_chunk_output
    lea rsi, [rip + ape_decoded]          # pseudo-stereo: the channel twice
    lea rdi, [rsi + APE_CHUNK*4]
    mov ecx, ebx
    rep movsd
    jmp .Lape_chunk_output
.Lape_chunk_stereo:
    and eax, FLAG_SILENCE
    cmp eax, FLAG_SILENCE
    je .Lape_chunk_output
    mov ecx, ebx
    mov edx, 1
    call ape_entropy
    cmp dword ptr [rip + ape_error], 0
    jne .Lape_chunk_bad
    mov ecx, ebx
    cmp dword ptr [rip + ape_version], 3950
    jb .Lape_chunk_stereo_3930
    call ape_predict_stereo_3950
    jmp .Lape_chunk_decorrelate
.Lape_chunk_stereo_3930:
    mov edx, 1
    call ape_predict_3930
.Lape_chunk_decorrelate:
    lea rsi, [rip + ape_decoded]
    mov ecx, ebx
.Lape_chunk_side:
    mov eax, [rsi]                        # mid difference, side
    mov edx, eax
    shr edx, 31
    add edx, eax
    sar edx, 1
    mov r8d, [rsi + APE_CHUNK*4]
    sub r8d, edx                          # left
    add eax, r8d                          # right
    mov [rsi], r8d
    mov [rsi + APE_CHUNK*4], eax
    add rsi, 4
    dec ecx
    jnz .Lape_chunk_side
.Lape_chunk_output:
    # Samples as FFmpeg presents them (8-bit unsigned, 16-bit, 24-bit in
    # 32), their bytes into the CRC, and stereo floats.
    lea rsi, [rip + ape_decoded]
    lea rdi, [rip + ape_out]
    lea r12, [rip + ape_crc_table]
    mov r13d, [rip + ape_crc_state]
    mov r14d, ebx
.Lape_chunk_frame:
    mov ecx, [rsi]
    call ape_sample
    movss [rdi], xmm0
    movss [rdi + 4], xmm0
    cmp dword ptr [rip + ape_channels], 2
    jne .Lape_chunk_frame_next
    mov ecx, [rsi + APE_CHUNK*4]
    call ape_sample
    movss [rdi + 4], xmm0
.Lape_chunk_frame_next:
    add rsi, 4
    add rdi, 8
    dec r14d
    jnz .Lape_chunk_frame
    mov [rip + ape_crc_state], r13d
    sub [rip + ape_left], ebx
    jnz .Lape_chunk_done
    not r13d
    shr r13d, 1
    cmp r13d, [rip + ape_crc]
    jne .Lape_chunk_bad
.Lape_chunk_done:
    mov [rip + ape_out_frames], ebx
    mov dword ptr [rip + ape_out_used], 0
    mov eax, 1
    jmp .Lape_chunk_return
.Lape_chunk_bad:
    xor eax, eax
.Lape_chunk_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_decode_chunk

# ECX=decoded sample, R12=CRC table, R13D=CRC -> XMM0=float, R13D updated.
# Clobbers RAX, RCX, RDX, R8.
LOCALFN ape_sample
    mov eax, [rip + ape_depth]
    cmp eax, 16
    je .Lape_sample_16
    ja .Lape_sample_24
    lea edx, [rcx + 0x80]                 # 8 bits: unsigned in the CRC
    movsx ecx, cl
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rip + ape_scale8]
    mov r8d, 1
    jmp .Lape_sample_crc
.Lape_sample_16:
    mov edx, ecx
    movsx ecx, cx
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rip + ape_scale16]
    mov r8d, 2
    jmp .Lape_sample_crc
.Lape_sample_24:
    mov edx, ecx
    shl ecx, 8
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rip + ape_scale32]
    mov r8d, 3
.Lape_sample_crc:
    mov eax, r13d
    xor al, dl
    movzx eax, al
    shr r13d, 8
    xor r13d, [r12 + rax*4]
    shr edx, 8
    dec r8d
    jnz .Lape_sample_crc
    ret
ENDFN ape_sample

# RCX=stereo float output, EDX=frame capacity -> EAX=frames; 0 at the end or
# with decode_error set.
FN ape_read
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lape_read_next
    cmp dword ptr [rax], 0
    je .Lape_read_next
    mov dword ptr [rip + decode_error], 3
    jmp .Lape_read_done
.Lape_read_next:
    cmp ebx, r12d
    jae .Lape_read_done
    mov eax, [rip + ape_out_used]
    cmp eax, [rip + ape_out_frames]
    jb .Lape_read_copy
    cmp dword ptr [rip + ape_left], 0
    jne .Lape_read_chunk
    mov eax, [rip + ape_frame]
    cmp eax, [rip + ape_frames]
    jae .Lape_read_done
    call ape_start_frame
    test eax, eax
    jz .Lape_read_damaged
.Lape_read_chunk:
    call ape_decode_chunk
    test eax, eax
    jz .Lape_read_damaged
    jmp .Lape_read_next
.Lape_read_copy:
    mov ecx, [rip + ape_out_frames]
    sub ecx, eax
    mov edx, r12d
    sub edx, ebx
    cmp ecx, edx
    cmova ecx, edx
    add [rip + ape_out_used], ecx
    add ebx, ecx
    lea rsi, [rip + ape_out]
    lea rsi, [rsi + rax*8]
    rep movsq
    jmp .Lape_read_next
.Lape_read_damaged:
    mov dword ptr [rip + ape_left], 0
    mov dword ptr [rip + decode_error], APE_MALFORMED
.Lape_read_done:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ape_read

# RCX=requested frame -> RAX=the start of the APE frame holding it, where
# decoding resumes.
FN ape_seek
    xor eax, eax
    mov rdx, [rip + ogg_cancel_ptr]
    test rdx, rdx
    jz .Lape_seek_continue
    cmp dword ptr [rdx], 0
    jne .Lape_seek_return
.Lape_seek_continue:
    mov rax, rcx
    cmp rax, [rip + total_frames]
    cmova rax, [rip + total_frames]
    mov r8d, [rip + ape_bpf]
    xor edx, edx
    div r8
    mov ecx, [rip + ape_frames]
    dec ecx
    cmp rax, rcx
    cmova rax, rcx
    mov [rip + ape_frame], eax
    mov dword ptr [rip + ape_left], 0
    mov dword ptr [rip + ape_out_frames], 0
    mov dword ptr [rip + ape_out_used], 0
    mul r8
.Lape_seek_return:
    ret
ENDFN ape_seek
