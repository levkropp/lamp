# Original AAC-LC decoder in x86-64 assembly. MIT, see LICENSE.
# Reference: ISO/IEC 14496-3 subpart 4 (General Audio) and ISO/IEC 13818-7.
# Huffman codewords, scalefactor band offsets and TNS band limits come from
# src/aac_tables.inc (tests/generate-aac-tables.py). Track mode: MP4,
# Matroska and ADTS supply the AudioSpecificConfig and one raw data block per
# packet. Object type 2 (LC), channel configurations 1-7, SCE/CPE/LFE with
# section data, scalefactors, pulses, TNS, perceptual noise substitution,
# mid/side and intensity stereo, sine/KBD windows and a DCT-IV based IMDCT;
# the output mixes to stereo with the shared WAVE speaker weights. HE-AAC
# spectral band replication (aac_sbr.inc), signalled explicitly, by the
# backward-compatible extension or only in the stream, doubles the rate, and
# parametric stereo (HE-AAC v2) makes mono SBR streams stereo. Coupling
# channels, gain control, prediction and 960-sample frames reject.
.include "lamp.inc"
.globl aac_channels, aac_rate_index, aac_random, aac_features, sbr_active

# aac_features bits, set as decoding meets each tool (for test coverage).
.equ AF_SHORT, 1                    # eight short windows
.equ AF_TRANSITION, 2               # long start/stop windows
.equ AF_KBD, 4                      # Kaiser-Bessel-derived window shape
.equ AF_MS, 8                       # mid/side bands
.equ AF_INTENSITY, 16               # intensity bands
.equ AF_NOISE, 32                   # perceptual noise substitution
.equ AF_TNS, 64                     # temporal noise shaping filters
.equ AF_PULSE, 128                  # pulse data
.equ AF_ESCAPE, 256                 # escape-coded values
.equ AF_GROUPS, 512                 # grouped short windows
.equ AF_SKIPPED, 1024               # data, program config or fill elements

.equ AAC_FRAME, 1024
.equ AAC_MALFORMED, 100
.equ AAC_UNSUPPORTED, 101

# Working memory, one allocation per open track.
.equ AM_OVERLAP, 0                  # 8 x 1024 floats: second window halves
.equ AM_PCM, 32768                  # 8 x 2048 floats: decoded channels (SBR doubles them)
.equ AM_COEF, 98304                 # 2 x 1024 floats: element spectra
.equ AM_QUANT, 106496               # 2 x 1024 int32: quantized values
.equ AM_BUF, 114688                 # 2048 doubles: IMDCT output, KBD scratch
.equ AM_FFT, 131072                 # 512 complex doubles
.equ AM_TIME, 139264                # 2048 doubles: eight short windows
.equ AM_PROBE, 155648               # 2048 stereo floats: first-packet probe
.equ AM_SIZE, 172032

# Channel stream state, one per channel of the current element.
.equ IC_SEQ, 0                      # window sequence 0-3
.equ IC_SHAPE, 4                    # 0 sine, 1 KBD
.equ IC_MAX_SFB, 8
.equ IC_WINDOWS, 12                 # 1 or 8
.equ IC_GROUPS, 16
.equ IC_SWB, 20                     # band table start in aac_swb_offsets
.equ IC_NUM_SWB, 24
.equ IC_TNS_MAX, 28
.equ IC_GROUP_LEN, 32               # 8 bytes
.equ IC_INFO, 40                    # bytes shared by a common window
.equ IC_GAIN, 40
.equ IC_PULSES, 44
.equ IC_TNS, 48
.equ IC_PULSE_POS, 52               # 4 dwords
.equ IC_PULSE_AMP, 68               # 4 dwords
.equ IC_BAND_TYPE, 84               # 128 bytes, group * max_sfb + band
.equ IC_SF, 212                     # 128 dwords: scalefactor, noise or position
.equ IC_TNS_NFILT, 724              # 8 bytes
.equ IC_TNS_RES, 732                # 8 bytes
.equ IC_TNS_LEN, 740                # 24 bytes, window * 3 + filter
.equ IC_TNS_ORDER, 764              # 24 bytes
.equ IC_TNS_DIR, 788                # 24 bytes
.equ IC_TNS_COEF, 812               # 24 x 12 signed bytes
.equ IC_SIZE, 1104

RODATA
.include "aac_tables.inc"
# Elements per channel configuration 1-7 (SCE 0, CPE 1, LFE 3; 255 ends).
aac_layouts:
    .byte 0, 255, 255, 255, 255, 255
    .byte 1, 255, 255, 255, 255, 255
    .byte 0, 1, 255, 255, 255, 255
    .byte 0, 1, 0, 255, 255, 255
    .byte 0, 1, 1, 255, 255, 255
    .byte 0, 1, 1, 3, 255, 255
    .byte 0, 1, 1, 1, 3, 255
aac_config_channels: .byte 0, 1, 2, 3, 4, 5, 6, 8
aac_config_elements: .byte 0, 1, 1, 2, 3, 3, 4, 5
# Two-dimensional books 5-11: values per dimension and the signed offset.
aac_pair_mod: .byte 9, 9, 8, 8, 13, 13, 17
aac_pair_offset: .byte 4, 4, 0, 0, 0, 0, 0
# 2^(r/4), r = 0..3, as floats.
aac_quarter_powers: .long 0x3f800000, 0x3f9837f0, 0x3fb504f3, 0x3fd744fd
.p2align 4
aac_sign_low: .quad 0x8000000000000000, 0
aac_pi: .quad 0x400921fb54442d18
aac_half: .double 0.5
aac_quarter: .double 0.25
aac_one: .double 1.0
aac_long_scale: .quad 0x3e60000000000000     # 2/2048/32768
aac_short_scale: .quad 0x3e90000000000000    # 2/256/32768

.data
aac_memory: .quad 0
aac_ptr: .quad 0                    # bit reader: packet, bytes, bit position
aac_bytes: .quad 0
aac_pos: .quad 0
aac_rate_index: .long 0
aac_config: .long 0                 # channel configuration
aac_channels: .long 0
aac_next: .long 0                   # next output channel in the frame
aac_element: .long 0                # channel elements in the frame
aac_random: .long 0x1f2e3d4c        # noise generator state
aac_common: .long 0                 # current pair shares ics_info
aac_ms_present: .long 0
aac_long_start: .long 0
aac_short_start: .long 0
aac_long_bands: .long 0
aac_short_bands: .long 0
aac_tns_long: .long 0
aac_tns_short: .long 0
aac_tables_ready: .long 0
aac_features: .long 0
aac_ps_flag: .long -1                # parametric stereo signalled: -1 unknown, 0 absent, 1 present
aac_prev_shape: .zero 8
adts_config: .short 0

.bss
.p2align 4
aac_ics: .zero 2*IC_SIZE
aac_ms_mask: .zero 128
.p2align 4
aac_win_long: .zero 2*1024*4        # rising halves: sine, KBD (alpha 4)
aac_win_short: .zero 2*128*4        # rising halves: sine, KBD (alpha 6)
# Twiddles as (wr, wr), (-wi, wi) pairs: a*w = a*(wr,wr) + swap(a)*(-wi,wi).
aac_pre_long: .zero 512*32
aac_post_long: .zero 512*32
aac_pre_short: .zero 64*32
aac_post_short: .zero 64*32
aac_fft_tw: .zero 256*32            # exp(-2 pi i j / 512)
aac_rev512: .zero 512*2
aac_rev64: .zero 64*2
aac_lpc: .zero 16*4                 # TNS direct-form coefficients (floats)

.text
# Bit reader. -> EAX=next 32 bits, zero past the packet. Clobbers RCX, RDX,
# R8, R9.
LOCALFN aac_peek
    mov rcx, [rip + aac_pos]
    mov rdx, rcx
    shr rdx, 3
    lea r8, [rdx + 8]
    cmp r8, [rip + aac_bytes]
    ja .Laac_peek_tail
    mov r8, [rip + aac_ptr]
    mov rax, [r8 + rdx]
    bswap rax
.Laac_peek_shift:
    and ecx, 7
    shl rax, cl
    shr rax, 32
    ret
.Laac_peek_tail:
    xor eax, eax
    mov r8d, 8
.Laac_peek_byte:
    shl rax, 8
    cmp rdx, [rip + aac_bytes]
    jae .Laac_peek_zero
    mov r9, [rip + aac_ptr]
    movzx r9d, byte ptr [r9 + rdx]
    or rax, r9
.Laac_peek_zero:
    inc rdx
    dec r8d
    jnz .Laac_peek_byte
    jmp .Laac_peek_shift
ENDFN aac_peek

# ECX=bits (0-32) -> EAX. Clobbers RCX, RDX, R8-R10.
LOCALFN aac_get
    mov r10d, ecx
    test ecx, ecx
    jz .Laac_get_zero
    call aac_peek
    mov ecx, 32
    sub ecx, r10d
    shr rax, cl
    add [rip + aac_pos], r10
    ret
.Laac_get_zero:
    xor eax, eax
    ret
ENDFN aac_get

# ECX=book (0 scalefactors, 1-11 spectral) -> EAX=codeword index.
# Clobbers RCX, RDX, R8-R11.
LOCALFN aac_huffman
    lea r11, [rip + aac_huff_books]
    movzx r10d, word ptr [r11 + rcx*4]   # first entry
    movzx r11d, word ptr [r11 + rcx*4 + 2]   # first-level bits
    call aac_peek
    lea r8, [rip + aac_huff_table]
    lea r8, [r8 + r10*2]
    mov edx, eax
    mov ecx, 32
    sub ecx, r11d
    shr edx, cl
    movzx edx, word ptr [r8 + rdx*2]
    test dx, dx
    jns .Laac_huffman_leaf
    mov r9d, eax                          # second level: the following bits
    mov ecx, r11d
    shl r9d, cl
    mov ecx, edx
    and ecx, 15
    neg ecx
    add ecx, 32
    shr r9d, cl
    shr edx, 4
    and edx, 0x7ff
    add edx, r9d
    movzx edx, word ptr [r8 + rdx*2]
.Laac_huffman_leaf:
    mov eax, edx
    and edx, 31
    add [rip + aac_pos], rdx
    shr eax, 5
    and eax, 0x1ff
    ret
ENDFN aac_huffman

# EAX=1 while the reader is inside the packet.
LOCALFN aac_inside
    mov rax, [rip + aac_bytes]
    shl rax, 3
    cmp [rip + aac_pos], rax
    setbe al
    movzx eax, al
    ret
ENDFN aac_inside

FN aac_track_close
    sub rsp, 40
    call sbr_close
    mov dword ptr [rip + sbr_active], 0
    mov rcx, [rip + aac_memory]
    test rcx, rcx
    jz .Laac_close_done
    call mem_free
    mov qword ptr [rip + aac_memory], 0
.Laac_close_done:
    add rsp, 40
    ret
ENDFN aac_track_close

# Clears the overlap, window-shape history and SBR state (stream start and
# seeks; SBR resumes with the next SBR header).
FN aac_track_reset
    push rdi
    sub rsp, 32
    mov rdi, [rip + aac_memory]
    test rdi, rdi
    jz .Laac_reset_shapes
    add rdi, AM_OVERLAP
    xor eax, eax
    mov ecx, 8*1024
    rep stosd
.Laac_reset_shapes:
    mov qword ptr [rip + aac_prev_shape], 0
    call sbr_reset_all
    add rsp, 32
    pop rdi
    ret
ENDFN aac_track_reset

# RCX=AudioSpecificConfig, EDX=bytes, R8=first packet, R9D=its bytes -> EAX=1.
# Sets the format globals and the stereo mix. The first packet is decoded once
# so that unsupported tools reject when opening and SBR signalled only inside
# the stream (implicit HE-AAC) doubles the rate before the track is timed.
FN aac_track_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov ebx, edx
    mov rdi, r8
    mov r12d, r9d
    call aac_track_close
    mov dword ptr [rip + sbr_mode], -1
    mov dword ptr [rip + sbr_found], 0
    mov dword ptr [rip + aac_ps_flag], -1
    cmp ebx, 2
    jb .Laac_open_bad
    mov [rip + aac_ptr], rsi
    mov [rip + aac_bytes], rbx
    mov qword ptr [rip + aac_pos], 0
    call .Laac_open_object_type
    mov [rsp + 32], eax
    mov ecx, 4
    call aac_get                          # samplingFrequencyIndex
    cmp eax, 11
    ja .Laac_open_unsupported             # explicit or below 8 kHz
    mov [rip + aac_rate_index], eax
    mov ecx, 4
    call aac_get                          # channelConfiguration
    test eax, eax
    jz .Laac_open_unsupported             # program config element layouts
    cmp eax, 7
    ja .Laac_open_unsupported
    mov [rip + aac_config], eax
    mov eax, [rsp + 32]
    cmp eax, 2
    je .Laac_open_specific
    cmp eax, 29                           # explicit SBR and parametric stereo (HE-AAC v2)
    jne .Laac_open_sbr_object
    mov dword ptr [rip + aac_ps_flag], 1
    jmp .Laac_open_explicit
.Laac_open_sbr_object:
    cmp eax, 5                            # explicit SBR (HE-AAC)
    jne .Laac_open_unsupported            # Main, SSR, LTP, ...
.Laac_open_explicit:
    mov ecx, 4
    call aac_get                          # extensionSamplingFrequencyIndex
    cmp eax, [rip + aac_rate_index]       # a higher rate: SBR doubles it
    jae .Laac_open_unsupported            # downsampled SBR, explicit rates
    call .Laac_open_object_type
    cmp eax, 2
    jne .Laac_open_unsupported
    mov dword ptr [rip + sbr_mode], 1
.Laac_open_specific:
    mov ecx, 3                            # GASpecificConfig
    call aac_get
    test eax, eax                         # 960 frames, core coder, extension
    jnz .Laac_open_unsupported
    cmp dword ptr [rip + sbr_mode], 1
    je .Laac_open_format
    # Backward-compatible extension: SBR present, absent or (equal rate) implicit.
    mov rax, [rip + aac_bytes]
    shl rax, 3
    sub rax, [rip + aac_pos]
    cmp rax, 16
    jb .Laac_open_format
    mov ecx, 11
    call aac_get
    cmp eax, 0x2b7
    jne .Laac_open_format
    call .Laac_open_object_type
    cmp eax, 5
    jne .Laac_open_format
    mov ecx, 1
    call aac_get                          # sbrPresentFlag
    mov [rip + sbr_mode], eax
    test eax, eax
    jz .Laac_open_format
    mov ecx, 4
    call aac_get
    cmp eax, [rip + aac_rate_index]
    ja .Laac_open_unsupported             # downsampled SBR, explicit rates
    jb .Laac_open_ps
    mov dword ptr [rip + sbr_mode], -1    # equal rates: decided by the stream
.Laac_open_ps:
    mov rax, [rip + aac_bytes]
    shl rax, 3
    sub rax, [rip + aac_pos]
    cmp rax, 11
    jbe .Laac_open_format
    mov ecx, 11
    call aac_get
    cmp eax, 0x548
    jne .Laac_open_format
    mov ecx, 1
    call aac_get                          # psPresentFlag
    mov [rip + aac_ps_flag], eax
.Laac_open_format:
    call aac_inside
    test eax, eax
    jz .Laac_open_bad
    mov eax, [rip + aac_rate_index]
    imul eax, eax, 12
    lea rcx, [rip + aac_rate_info]
    add rcx, rax
    mov eax, [rcx]
    mov [rip + sample_rate], eax
    movzx eax, word ptr [rcx + 4]
    mov [rip + aac_long_start], eax
    movzx eax, word ptr [rcx + 6]
    mov [rip + aac_short_start], eax
    movzx eax, byte ptr [rcx + 8]
    mov [rip + aac_long_bands], eax
    movzx eax, byte ptr [rcx + 9]
    mov [rip + aac_short_bands], eax
    movzx eax, byte ptr [rcx + 10]
    mov [rip + aac_tns_long], eax
    movzx eax, byte ptr [rcx + 11]
    mov [rip + aac_tns_short], eax
    mov eax, [rip + aac_config]
    lea rcx, [rip + aac_config_channels]
    movzx eax, byte ptr [rcx + rax]
    mov [rip + aac_channels], eax
    mov [rip + source_channels], eax
    mov dword ptr [rip + source_bits], 0
    mov ecx, AM_SIZE
    call mem_alloc
    test rax, rax
    jz .Laac_open_bad
    mov [rip + aac_memory], rax
    call aac_init_tables
    # Speaker layout for the stereo mix (ALAC and AAC share channel orders).
    mov eax, [rip + aac_channels]
    lea rcx, [rip + alac_masks]
    mov eax, [rcx + rax*4 - 4]
    mov [rip + pcm_channel_mask], eax
    mov dword ptr [rip + pcm_mask_seen], 1
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + pcm_mix], 0
    call pcm_build_mix
    test eax, eax
    jz .Laac_open_bad
    mov dword ptr [rip + aac_features], 0
    cmp dword ptr [rip + sbr_mode], 1
    jne .Laac_open_probe
    call .Laac_open_sbr
    test eax, eax
    jz .Laac_open_failed
.Laac_open_probe:
    call .Laac_open_decode_first
    test eax, eax
    jz .Laac_open_failed
    cmp dword ptr [rip + sbr_active], 0
    jne .Laac_open_ready
    cmp dword ptr [rip + sbr_found], 0
    je .Laac_open_ready
    call .Laac_open_sbr                   # implicit SBR: decode again with it
    test eax, eax
    jz .Laac_open_failed
    call .Laac_open_decode_first
    test eax, eax
    jz .Laac_open_failed
.Laac_open_ready:
    mov eax, 1
    jmp .Laac_open_return
.Laac_open_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
.Laac_open_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Laac_open_failed
    mov dword ptr [rip + decode_error], AAC_MALFORMED
.Laac_open_failed:
    call aac_track_close
    xor eax, eax
.Laac_open_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
# Local subroutines (the caller's frame is 8 bytes deeper).
.Laac_open_object_type:                   # audioObjectType with its escape
    mov ecx, 5
    call aac_get
    cmp eax, 31
    jne .Laac_open_object_done
    mov ecx, 6
    call aac_get
    add eax, 32
.Laac_open_object_done:
    ret
.Laac_open_sbr:                           # SBR output at twice the core rate
    sub rsp, 40
    xor eax, eax
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
    cmp dword ptr [rip + aac_rate_index], 3
    jb .Laac_open_sbr_done                # a core above 48 kHz
    mov dword ptr [rip + decode_error], 0
    mov eax, [rip + aac_config]
    lea rcx, [rip + aac_config_elements]
    movzx ecx, byte ptr [rcx + rax]
    xor edx, edx                          # mono: parametric stereo unless signalled absent
    cmp eax, 1
    jne .Laac_open_sbr_state
    cmp dword ptr [rip + aac_ps_flag], 0
    setne dl
.Laac_open_sbr_state:
    call sbr_open
    test eax, eax
    jz .Laac_open_sbr_done
    mov dword ptr [rip + sbr_active], 1
    shl dword ptr [rip + sample_rate], 1
    cmp qword ptr [rip + sbr_ps], 0
    je .Laac_open_sbr_ready
    mov dword ptr [rip + source_channels], 2
.Laac_open_sbr_ready:
    mov eax, 1
.Laac_open_sbr_done:
    add rsp, 40
    ret
.Laac_open_decode_first:                  # -> EAX=1 when the first packet decodes
    sub rsp, 40
    xor eax, eax
    test r12d, r12d
    jz .Laac_open_first_done
    call aac_track_reset
    mov dword ptr [rip + aac_random], 0x1f2e3d4c
    mov rcx, rdi
    mov edx, r12d
    mov r8, [rip + aac_memory]
    add r8, AM_PROBE
    mov r9d, 2*AAC_FRAME
    call aac_track_decode
    mov [rsp + 32], eax
    call aac_track_reset
    mov dword ptr [rip + aac_random], 0x1f2e3d4c
    mov eax, [rsp + 32]
.Laac_open_first_done:
    add rsp, 40
    ret
ENDFN aac_track_open

# RCX=packet, EDX=bytes -> EAX=1024 frames, 2048 with SBR, or -1.
FN aac_track_samples
    mov eax, -1
    test edx, edx
    jz .Laac_samples_return
    mov eax, AAC_FRAME
    cmp dword ptr [rip + sbr_active], 0
    je .Laac_samples_return
    add eax, eax
.Laac_samples_return:
    ret
ENDFN aac_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=1024
# frames (2048 with SBR), or 0 with decode_error set.
FN aac_track_decode
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov [rsp + 32], r8
    mov eax, AAC_FRAME
    cmp dword ptr [rip + sbr_active], 0
    je .Laac_decode_capacity
    add eax, eax
.Laac_decode_capacity:
    mov [rsp + 40], eax                   # frames
    cmp r9d, eax
    jb .Laac_decode_bad
    mov [rip + aac_ptr], rcx
    mov edx, edx
    mov [rip + aac_bytes], rdx
    mov qword ptr [rip + aac_pos], 0
    mov dword ptr [rip + aac_next], 0
    mov dword ptr [rip + aac_element], 0
.Laac_decode_element:
    mov ecx, 3
    call aac_get
    mov ebx, eax
    cmp ebx, 7
    je .Laac_decode_end
    cmp ebx, 1
    jbe .Laac_decode_channels
    cmp ebx, 3
    je .Laac_decode_channels
    cmp ebx, 4
    je .Laac_decode_dse
    cmp ebx, 5
    je .Laac_decode_pce
    cmp ebx, 6
    je .Laac_decode_fil
    jmp .Laac_decode_unsupported          # coupling channel element
.Laac_decode_channels:
    # The element must be the next one of the configured layout.
    mov eax, [rip + aac_config]
    dec eax
    imul eax, eax, 6
    lea rcx, [rip + aac_layouts]
    add rcx, rax
    mov edx, [rip + aac_element]
    cmp edx, 5
    jae .Laac_decode_bad
    movzx eax, byte ptr [rcx + rdx]
    cmp eax, ebx
    jne .Laac_decode_bad
    inc dword ptr [rip + aac_element]
    cmp ebx, 1
    je .Laac_decode_pair
    call aac_single
    jmp .Laac_decode_checked
.Laac_decode_pair:
    call aac_pair
    jmp .Laac_decode_checked
.Laac_decode_dse:
    or dword ptr [rip + aac_features], AF_SKIPPED
    call aac_data_element
    jmp .Laac_decode_checked
.Laac_decode_pce:
    or dword ptr [rip + aac_features], AF_SKIPPED
    call aac_program_config
    jmp .Laac_decode_checked
.Laac_decode_fil:
    or dword ptr [rip + aac_features], AF_SKIPPED
    call aac_fill
.Laac_decode_checked:
    test eax, eax
    jz .Laac_decode_bad
    call aac_inside
    test eax, eax
    jz .Laac_decode_bad
    jmp .Laac_decode_element
.Laac_decode_end:
    call aac_inside
    test eax, eax
    jz .Laac_decode_bad
    mov eax, [rip + aac_next]
    cmp eax, [rip + aac_channels]
    jne .Laac_decode_bad
    cmp dword ptr [rip + sbr_active], 0
    je .Laac_decode_emit
    # SBR per channel element, in layout order.
    mov eax, [rip + aac_config]
    dec eax
    imul eax, eax, 6
    lea rsi, [rip + aac_layouts]
    add rsi, rax
    xor edi, edi                          # element
    xor r12d, r12d                        # first channel
.Laac_decode_sbr:
    cmp edi, [rip + aac_element]
    jae .Laac_decode_emit
    movzx ebx, byte ptr [rsi + rdi]
    mov ecx, edi
    mov edx, ebx
    mov r8d, r12d
    call sbr_apply
    inc r12d
    cmp ebx, 1
    jne .Laac_decode_sbr_next
    inc r12d
.Laac_decode_sbr_next:
    inc edi
    jmp .Laac_decode_sbr
.Laac_decode_emit:
    mov rcx, [rsp + 32]
    call aac_emit
    mov eax, [rsp + 40]
    jmp .Laac_decode_return
.Laac_decode_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
.Laac_decode_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Laac_decode_failed
    mov dword ptr [rip + decode_error], AAC_MALFORMED
.Laac_decode_failed:
    xor eax, eax
.Laac_decode_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_track_decode

# Single channel or LFE element -> EAX=1.
LOCALFN aac_single
    sub rsp, 40
    mov ecx, 4
    call aac_get                          # element_instance_tag
    mov dword ptr [rip + aac_common], 0
    mov dword ptr [rip + aac_ms_present], 0
    xor ecx, ecx
    call aac_channel_stream
    test eax, eax
    jz .Laac_single_return
    xor ecx, ecx
    mov edx, [rip + aac_next]
    call aac_finish_channel
    inc dword ptr [rip + aac_next]
    mov eax, 1
.Laac_single_return:
    add rsp, 40
    ret
ENDFN aac_single

# Channel pair element -> EAX=1.
LOCALFN aac_pair
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ecx, 4
    call aac_get                          # element_instance_tag
    mov ecx, 1
    call aac_get
    mov [rip + aac_common], eax
    mov dword ptr [rip + aac_ms_present], 0
    test eax, eax
    jz .Laac_pair_streams
    lea rcx, [rip + aac_ics]
    call aac_ics_info
    test eax, eax
    jz .Laac_pair_bad
    lea rsi, [rip + aac_ics]
    lea rdi, [rsi + IC_SIZE]
    mov ecx, IC_INFO
    rep movsb
    mov ecx, 2
    call aac_get
    cmp eax, 3
    je .Laac_pair_bad
    mov [rip + aac_ms_present], eax
    lea rsi, [rip + aac_ics]
    mov ebx, [rsi + IC_GROUPS]
    imul ebx, [rsi + IC_MAX_SFB]          # mask entries
    lea rdi, [rip + aac_ms_mask]
    cmp eax, 1
    jne .Laac_pair_mask_all
    xor esi, esi
.Laac_pair_mask:
    cmp esi, ebx
    jae .Laac_pair_streams
    mov ecx, 1
    call aac_get
    mov [rdi + rsi], al
    inc esi
    jmp .Laac_pair_mask
.Laac_pair_mask_all:
    mov ecx, ebx
    mov al, 1
    rep stosb
.Laac_pair_streams:
    xor ecx, ecx
    call aac_channel_stream
    test eax, eax
    jz .Laac_pair_bad
    mov ecx, 1
    call aac_channel_stream
    test eax, eax
    jz .Laac_pair_bad
    cmp dword ptr [rip + aac_common], 0
    je .Laac_pair_finish
    call aac_stereo
.Laac_pair_finish:
    xor ecx, ecx
    mov edx, [rip + aac_next]
    call aac_finish_channel
    mov ecx, 1
    mov edx, [rip + aac_next]
    inc edx
    call aac_finish_channel
    add dword ptr [rip + aac_next], 2
    mov eax, 1
    jmp .Laac_pair_return
.Laac_pair_bad:
    xor eax, eax
.Laac_pair_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_pair

# Data stream element: skipped -> EAX=1.
LOCALFN aac_data_element
    push rbx
    sub rsp, 48
    mov ecx, 4
    call aac_get                          # element_instance_tag
    mov ecx, 1
    call aac_get
    mov ebx, eax                          # data_byte_align_flag
    mov ecx, 8
    call aac_get
    mov [rsp + 32], eax
    cmp eax, 255
    jne .Laac_dse_count
    mov ecx, 8
    call aac_get
    add [rsp + 32], eax
.Laac_dse_count:
    test ebx, ebx
    jz .Laac_dse_skip
    mov rax, [rip + aac_pos]
    add rax, 7
    and rax, -8
    mov [rip + aac_pos], rax
.Laac_dse_skip:
    mov eax, [rsp + 32]
    shl rax, 3
    add [rip + aac_pos], rax
    mov eax, 1
    add rsp, 48
    pop rbx
    ret
ENDFN aac_data_element

# Program config element inside a frame: parsed and skipped -> EAX=1.
LOCALFN aac_program_config
    push rbx
    push rsi
    sub rsp, 40
    mov ecx, 10
    call aac_get                          # tag, object type, frequency index
    mov ecx, 12
    call aac_get                          # front, side and back elements
    mov ebx, eax
    shr eax, 8
    mov esi, eax
    mov eax, ebx
    shr eax, 4
    and eax, 15
    add esi, eax
    and ebx, 15
    add esi, ebx
    imul esi, esi, 5                      # is_cpe and tag each
    mov ecx, 2
    call aac_get                          # LFE elements: tag each
    lea esi, [rsi + rax*4]
    mov ecx, 3
    call aac_get                          # associated data elements: tag each
    lea esi, [rsi + rax*4]
    mov ecx, 4
    call aac_get                          # coupling elements: flag and tag
    lea eax, [rax + rax*4]
    add esi, eax
    mov ecx, 1
    call aac_get                          # mono mixdown element number
    shl eax, 2
    mov ecx, eax
    call aac_get
    mov ecx, 1
    call aac_get                          # stereo mixdown element number
    shl eax, 2
    mov ecx, eax
    call aac_get
    mov ecx, 1
    call aac_get                          # matrix mixdown index, pseudo surround
    lea ecx, [rax + rax*2]
    call aac_get
    add [rip + aac_pos], rsi              # the element lists
    mov rax, [rip + aac_pos]              # byte alignment
    add rax, 7
    and rax, -8
    mov [rip + aac_pos], rax
    mov ecx, 8
    call aac_get                          # comment bytes
    shl rax, 3
    add [rip + aac_pos], rax
    mov eax, 1
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN aac_program_config

# Fill element: SBR data for the previous channel element when SBR is on,
# otherwise skipped (implicit SBR is noted while the first packet is probed).
LOCALFN aac_fill
    push rbx
    push rsi
    sub rsp, 40
    mov ecx, 4
    call aac_get
    mov ebx, eax
    cmp eax, 15
    jne .Laac_fill_count
    mov ecx, 8
    call aac_get
    lea ebx, [rbx + rax - 1]
.Laac_fill_count:
    test ebx, ebx
    jz .Laac_fill_done
    call aac_peek
    shr eax, 28                           # extension_type
    cmp eax, 13                           # EXT_SBR_DATA
    je .Laac_fill_sbr
    cmp eax, 14                           # EXT_SBR_DATA_CRC
    je .Laac_fill_sbr
    shl rbx, 3
    add [rip + aac_pos], rbx
.Laac_fill_done:
    mov eax, 1
    jmp .Laac_fill_return
.Laac_fill_sbr:
    mov esi, eax
    cmp dword ptr [rip + aac_element], 0
    je .Laac_fill_skip                    # before the first channel element
    cmp dword ptr [rip + sbr_active], 0
    jne .Laac_fill_decode
    cmp dword ptr [rip + sbr_mode], -1
    jne .Laac_fill_skip
    mov dword ptr [rip + sbr_found], 1
.Laac_fill_skip:
    shl rbx, 3
    add [rip + aac_pos], rbx
    jmp .Laac_fill_done
.Laac_fill_decode:
    add qword ptr [rip + aac_pos], 4      # extension_type
    mov eax, [rip + aac_element]
    dec eax
    lea rcx, [rip + sbr_elements]
    mov rcx, [rcx + rax*8]
    mov edx, [rip + aac_config]
    dec edx
    imul edx, edx, 6
    add edx, eax
    lea rax, [rip + aac_layouts]
    movzx edx, byte ptr [rax + rdx]       # element type
    xor r8d, r8d
    cmp esi, 14                           # EXT_SBR_DATA_CRC
    sete r8b
    mov r9d, ebx
    call sbr_extension
    jmp .Laac_fill_return
.Laac_fill_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN aac_fill

# ics_info into RCX -> EAX=1.
LOCALFN aac_ics_info
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov ecx, 1
    call aac_get                          # ics_reserved_bit
    test eax, eax
    jnz .Laac_info_bad
    mov ecx, 2
    call aac_get
    mov [rbx + IC_SEQ], eax
    mov ecx, 1
    call aac_get
    mov [rbx + IC_SHAPE], eax
    test eax, eax
    jz .Laac_info_flags
    or dword ptr [rip + aac_features], AF_KBD
.Laac_info_flags:
    mov eax, [rbx + IC_SEQ]
    test eax, 1
    jz .Laac_info_sequence
    or dword ptr [rip + aac_features], AF_TRANSITION
.Laac_info_sequence:
    mov qword ptr [rbx + IC_GROUP_LEN], 0
    cmp dword ptr [rbx + IC_SEQ], 2
    jne .Laac_info_long
    mov ecx, 4
    call aac_get
    mov [rbx + IC_MAX_SFB], eax
    mov ecx, 7
    call aac_get                          # scale_factor_grouping
    mov dword ptr [rbx + IC_WINDOWS], 8
    mov byte ptr [rbx + IC_GROUP_LEN], 1
    mov edx, 1                            # groups
    mov ecx, 6
.Laac_info_group:
    bt eax, ecx
    jnc .Laac_info_new_group
    inc byte ptr [rbx + IC_GROUP_LEN + rdx - 1]
    jmp .Laac_info_group_next
.Laac_info_new_group:
    mov byte ptr [rbx + IC_GROUP_LEN + rdx], 1
    inc edx
.Laac_info_group_next:
    dec ecx
    jns .Laac_info_group
    mov [rbx + IC_GROUPS], edx
    or dword ptr [rip + aac_features], AF_SHORT
    cmp edx, 8
    je .Laac_info_ungrouped
    or dword ptr [rip + aac_features], AF_GROUPS
.Laac_info_ungrouped:
    mov eax, [rip + aac_short_start]
    mov [rbx + IC_SWB], eax
    mov eax, [rip + aac_short_bands]
    mov [rbx + IC_NUM_SWB], eax
    mov eax, [rip + aac_tns_short]
    mov [rbx + IC_TNS_MAX], eax
    jmp .Laac_info_check
.Laac_info_long:
    mov ecx, 6
    call aac_get
    mov [rbx + IC_MAX_SFB], eax
    mov ecx, 1
    call aac_get                          # predictor_data_present
    test eax, eax
    jnz .Laac_info_unsupported
    mov dword ptr [rbx + IC_WINDOWS], 1
    mov dword ptr [rbx + IC_GROUPS], 1
    mov byte ptr [rbx + IC_GROUP_LEN], 1
    mov eax, [rip + aac_long_start]
    mov [rbx + IC_SWB], eax
    mov eax, [rip + aac_long_bands]
    mov [rbx + IC_NUM_SWB], eax
    mov eax, [rip + aac_tns_long]
    mov [rbx + IC_TNS_MAX], eax
.Laac_info_check:
    mov eax, [rbx + IC_MAX_SFB]
    cmp eax, [rbx + IC_NUM_SWB]
    ja .Laac_info_bad
    mov eax, 1
    jmp .Laac_info_return
.Laac_info_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
.Laac_info_bad:
    xor eax, eax
.Laac_info_return:
    add rsp, 32
    pop rbx
    ret
ENDFN aac_ics_info

# individual_channel_stream for element channel ECX (0/1) -> EAX=1; leaves
# the dequantized spectrum in the channel's coefficient buffer.
LOCALFN aac_channel_stream
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov r12d, ecx
    imul ebx, ecx, IC_SIZE
    lea rax, [rip + aac_ics]
    add rbx, rax
    mov ecx, 8
    call aac_get
    mov [rbx + IC_GAIN], eax
    cmp dword ptr [rip + aac_common], 0
    jne .Laac_stream_info
    mov rcx, rbx
    call aac_ics_info
    test eax, eax
    jz .Laac_stream_bad
.Laac_stream_info:
    mov rcx, rbx
    mov edx, r12d
    call aac_section
    test eax, eax
    jz .Laac_stream_bad
    mov rcx, rbx
    call aac_scalefactors
    test eax, eax
    jz .Laac_stream_bad
    mov dword ptr [rbx + IC_PULSES], 0
    mov ecx, 1
    call aac_get
    test eax, eax
    jz .Laac_stream_tns
    cmp dword ptr [rbx + IC_WINDOWS], 8
    je .Laac_stream_bad                   # no pulses with short windows
    mov rcx, rbx
    call aac_pulse_data
    test eax, eax
    jz .Laac_stream_bad
.Laac_stream_tns:
    mov ecx, 1
    call aac_get
    mov [rbx + IC_TNS], eax
    test eax, eax
    jz .Laac_stream_gain
    mov rcx, rbx
    call aac_tns_data
    test eax, eax
    jz .Laac_stream_bad
.Laac_stream_gain:
    mov ecx, 1
    call aac_get                          # gain_control_data_present
    test eax, eax
    jnz .Laac_stream_unsupported
    mov rcx, rbx
    mov edx, r12d
    call aac_spectral
    test eax, eax
    jz .Laac_stream_bad
    mov rcx, rbx
    mov edx, r12d
    call aac_dequantize
    mov eax, 1
    jmp .Laac_stream_return
.Laac_stream_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
.Laac_stream_bad:
    xor eax, eax
.Laac_stream_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_channel_stream

# section_data: RCX=channel stream, EDX=element channel -> EAX=1.
LOCALFN aac_section
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov r14d, edx
    mov r12d, 5                           # section length bits
    cmp dword ptr [rbx + IC_WINDOWS], 8
    jne .Laac_section_bits
    mov r12d, 3
.Laac_section_bits:
    xor esi, esi                          # band index of the group's first band
    xor edi, edi                          # group
.Laac_section_group:
    cmp edi, [rbx + IC_GROUPS]
    jae .Laac_section_done
    xor r13d, r13d                        # band
.Laac_section_next:
    cmp r13d, [rbx + IC_MAX_SFB]
    jae .Laac_section_group_done
    call aac_inside
    test eax, eax
    jz .Laac_section_bad
    mov ecx, 4
    call aac_get
    mov [rsp + 32], eax                   # sect_cb
    cmp eax, 12
    je .Laac_section_bad                  # reserved
    jb .Laac_section_length
    cmp eax, 14
    jb .Laac_section_length
    # Intensity stereo only in the second channel of a common window.
    cmp r14d, 1
    jne .Laac_section_bad
    cmp dword ptr [rip + aac_common], 0
    je .Laac_section_bad
.Laac_section_length:
    mov [rsp + 36], r13d                  # section end
.Laac_section_increment:
    mov ecx, r12d
    call aac_get
    add [rsp + 36], eax
    mov edx, [rsp + 36]
    cmp edx, [rbx + IC_MAX_SFB]
    ja .Laac_section_bad
    mov ecx, r12d
    mov edx, 1
    shl edx, cl
    dec edx
    cmp eax, edx
    jne .Laac_section_fill
    call aac_inside
    test eax, eax
    jz .Laac_section_bad
    jmp .Laac_section_increment
.Laac_section_fill:
    mov eax, [rsp + 32]
.Laac_section_band:
    cmp r13d, [rsp + 36]
    jae .Laac_section_next
    lea ecx, [rsi + r13]
    mov [rbx + IC_BAND_TYPE + rcx], al
    inc r13d
    jmp .Laac_section_band
.Laac_section_group_done:
    add esi, [rbx + IC_MAX_SFB]
    inc edi
    jmp .Laac_section_group
.Laac_section_done:
    mov eax, 1
    jmp .Laac_section_return
.Laac_section_bad:
    xor eax, eax
.Laac_section_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_section

# scale_factor_data: RCX=channel stream -> EAX=1. Stores scalefactors,
# noise energies and intensity positions per band.
LOCALFN aac_scalefactors
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov r12d, [rbx + IC_GAIN]             # scalefactor
    lea r13d, [r12 - 90]                  # noise energy
    xor r14d, r14d                        # intensity position
    mov dword ptr [rsp + 32], 1           # next noise band is the first
    mov edi, [rbx + IC_GROUPS]
    imul edi, [rbx + IC_MAX_SFB]
    xor esi, esi
.Laac_sf_band:
    cmp esi, edi
    jae .Laac_sf_done
    movzx eax, byte ptr [rbx + IC_BAND_TYPE + rsi]
    test eax, eax
    jz .Laac_sf_zero
    cmp eax, 13
    je .Laac_sf_noise
    ja .Laac_sf_intensity
    xor ecx, ecx
    call aac_huffman
    lea r12d, [r12 + rax - 60]
    cmp r12d, 255
    ja .Laac_sf_bad
    mov [rbx + IC_SF + rsi*4], r12d
    jmp .Laac_sf_next
.Laac_sf_zero:
    mov dword ptr [rbx + IC_SF + rsi*4], 0
    jmp .Laac_sf_next
.Laac_sf_noise:
    cmp dword ptr [rsp + 32], 0
    je .Laac_sf_noise_delta
    mov dword ptr [rsp + 32], 0
    mov ecx, 9
    call aac_get
    lea r13d, [r13 + rax - 256]
    jmp .Laac_sf_noise_store
.Laac_sf_noise_delta:
    xor ecx, ecx
    call aac_huffman
    lea r13d, [r13 + rax - 60]
.Laac_sf_noise_store:
    mov [rbx + IC_SF + rsi*4], r13d
    jmp .Laac_sf_next
.Laac_sf_intensity:
    xor ecx, ecx
    call aac_huffman
    lea r14d, [r14 + rax - 60]
    mov [rbx + IC_SF + rsi*4], r14d
.Laac_sf_next:
    inc esi
    jmp .Laac_sf_band
.Laac_sf_done:
    mov eax, 1
    jmp .Laac_sf_return
.Laac_sf_bad:
    xor eax, eax
.Laac_sf_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_scalefactors

# pulse_data: RCX=channel stream -> EAX=1.
LOCALFN aac_pulse_data
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    or dword ptr [rip + aac_features], AF_PULSE
    mov ecx, 2
    call aac_get
    inc eax
    mov [rbx + IC_PULSES], eax
    mov ecx, 6
    call aac_get                          # pulse_start_sfb
    cmp eax, [rbx + IC_NUM_SWB]
    jae .Laac_pulse_bad
    add eax, [rbx + IC_SWB]
    lea rcx, [rip + aac_swb_offsets]
    movzx edi, word ptr [rcx + rax*2]     # position
    xor esi, esi
.Laac_pulse_next:
    cmp esi, [rbx + IC_PULSES]
    jae .Laac_pulse_done
    mov ecx, 5
    call aac_get
    add edi, eax
    cmp edi, 1023
    ja .Laac_pulse_bad
    mov [rbx + IC_PULSE_POS + rsi*4], edi
    mov ecx, 4
    call aac_get
    mov [rbx + IC_PULSE_AMP + rsi*4], eax
    inc esi
    jmp .Laac_pulse_next
.Laac_pulse_done:
    mov eax, 1
    jmp .Laac_pulse_return
.Laac_pulse_bad:
    xor eax, eax
.Laac_pulse_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_pulse_data

# tns_data: RCX=channel stream -> EAX=1. Locals: 32 window, 36 filters,
# 40 filter, 44 coefficient bits.
LOCALFN aac_tns_data
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rbx, rcx
    mov dword ptr [rsp + 32], 0
.Laac_tns_window:
    mov eax, [rsp + 32]
    cmp eax, [rbx + IC_WINDOWS]
    jae .Laac_tns_done
    mov ecx, 2
    cmp dword ptr [rbx + IC_WINDOWS], 8
    jne .Laac_tns_nfilt
    mov ecx, 1
.Laac_tns_nfilt:
    call aac_get
    mov ecx, [rsp + 32]
    mov [rbx + IC_TNS_NFILT + rcx], al
    mov [rsp + 36], eax
    test eax, eax
    jz .Laac_tns_window_next
    mov ecx, 1
    call aac_get
    mov ecx, [rsp + 32]
    mov [rbx + IC_TNS_RES + rcx], al
    mov dword ptr [rsp + 40], 0
.Laac_tns_filter:
    mov eax, [rsp + 40]
    cmp eax, [rsp + 36]
    jae .Laac_tns_window_next
    mov esi, [rsp + 32]
    lea esi, [rsi + rsi*2]
    add esi, eax                          # window * 3 + filter
    mov ecx, 6
    cmp dword ptr [rbx + IC_WINDOWS], 8
    jne .Laac_tns_length
    mov ecx, 4
.Laac_tns_length:
    call aac_get
    mov [rbx + IC_TNS_LEN + rsi], al
    mov ecx, 5
    mov edi, 12                           # maximum order
    cmp dword ptr [rbx + IC_WINDOWS], 8
    jne .Laac_tns_order
    mov ecx, 3
    mov edi, 7
.Laac_tns_order:
    call aac_get
    cmp eax, edi
    ja .Laac_tns_bad
    mov [rbx + IC_TNS_ORDER + rsi], al
    mov byte ptr [rbx + IC_TNS_DIR + rsi], 0
    test eax, eax
    jz .Laac_tns_filter_next
    mov edi, eax                          # order
    mov ecx, 1
    call aac_get
    mov [rbx + IC_TNS_DIR + rsi], al
    mov ecx, 1
    call aac_get                          # coef_compress
    mov ecx, [rsp + 32]
    movzx ecx, byte ptr [rbx + IC_TNS_RES + rcx]
    add ecx, 3
    sub ecx, eax
    mov [rsp + 44], ecx                   # coefficient bits
    imul esi, esi, 12
    lea rsi, [rbx + IC_TNS_COEF + rsi]
    xor r12d, r12d
.Laac_tns_coef:
    cmp r12d, edi
    jae .Laac_tns_filter_next
    mov ecx, [rsp + 44]
    call aac_get
    mov ecx, 32                           # sign-extend from the field width
    sub ecx, [rsp + 44]
    shl eax, cl
    sar eax, cl
    mov [rsi + r12], al
    inc r12d
    jmp .Laac_tns_coef
.Laac_tns_filter_next:
    inc dword ptr [rsp + 40]
    jmp .Laac_tns_filter
.Laac_tns_window_next:
    inc dword ptr [rsp + 32]
    jmp .Laac_tns_window
.Laac_tns_done:
    mov eax, 1
    jmp .Laac_tns_return
.Laac_tns_bad:
    xor eax, eax
.Laac_tns_return:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_tns_data

# spectral_data: RCX=channel stream, EDX=element channel -> EAX=1. Quantized
# values land in natural order, window * 128 + coefficient for short windows.
LOCALFN aac_spectral
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov r15, [rip + aac_memory]
    shl edx, 12
    lea r15, [r15 + rdx + AM_QUANT]
    mov rdi, r15
    xor eax, eax
    mov ecx, 1024
    rep stosd
    xor r12d, r12d                        # group
    xor r13d, r13d                        # first window of the group
    mov dword ptr [rsp + 32], 0           # band index of the group's first band
.Laac_spectral_group:
    cmp r12d, [rbx + IC_GROUPS]
    jae .Laac_spectral_done
    xor r14d, r14d                        # band
.Laac_spectral_band:
    cmp r14d, [rbx + IC_MAX_SFB]
    jae .Laac_spectral_group_next
    mov eax, [rsp + 32]
    add eax, r14d
    movzx eax, byte ptr [rbx + IC_BAND_TYPE + rax]
    test eax, eax
    jz .Laac_spectral_band_next
    cmp eax, 11
    ja .Laac_spectral_band_next
    mov [rsp + 36], eax                   # book
    mov ecx, [rbx + IC_SWB]
    add ecx, r14d
    lea rdx, [rip + aac_swb_offsets]
    movzx eax, word ptr [rdx + rcx*2]
    mov [rsp + 40], eax                   # band start
    movzx eax, word ptr [rdx + rcx*2 + 2]
    mov [rsp + 44], eax                   # band end
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    mov [rsp + 48], eax                   # windows left in the group
    mov [rsp + 52], r13d                  # window
.Laac_spectral_window:
    cmp dword ptr [rsp + 48], 0
    je .Laac_spectral_band_next
    call aac_inside
    test eax, eax
    jz .Laac_spectral_bad
    mov esi, [rsp + 52]
    shl esi, 7
    mov edi, esi
    add esi, [rsp + 40]
    add edi, [rsp + 44]
.Laac_spectral_tuple:
    cmp esi, edi
    jae .Laac_spectral_window_next
    mov ecx, [rsp + 36]
    lea rdx, [r15 + rsi*4]
    call aac_tuple
    test eax, eax
    jz .Laac_spectral_bad
    add esi, eax
    jmp .Laac_spectral_tuple
.Laac_spectral_window_next:
    inc dword ptr [rsp + 52]
    dec dword ptr [rsp + 48]
    jmp .Laac_spectral_window
.Laac_spectral_band_next:
    inc r14d
    jmp .Laac_spectral_band
.Laac_spectral_group_next:
    mov eax, [rbx + IC_MAX_SFB]
    add [rsp + 32], eax
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    add r13d, eax
    inc r12d
    jmp .Laac_spectral_group
.Laac_spectral_done:
    mov eax, 1
    jmp .Laac_spectral_return
.Laac_spectral_bad:
    xor eax, eax
.Laac_spectral_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_spectral

# One codeword of book ECX (1-11) into RDX -> EAX=values written (4 or 2),
# 0 for an invalid escape.
LOCALFN aac_tuple
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov ebx, ecx
    mov rdi, rdx
    call aac_huffman
    cmp ebx, 4
    ja .Laac_tuple_pair
    xor edx, edx                          # four values, three levels each
    mov ecx, 27
    div ecx
    mov [rsp + 32], eax
    mov eax, edx
    xor edx, edx
    mov ecx, 9
    div ecx
    mov [rsp + 36], eax
    mov eax, edx
    xor edx, edx
    mov ecx, 3
    div ecx
    mov [rsp + 40], eax
    mov [rsp + 44], edx
    mov esi, 4
    cmp ebx, 2
    ja .Laac_tuple_unsigned
    mov ecx, 1                            # signed books 1-2: -1..1
    jmp .Laac_tuple_offset
.Laac_tuple_pair:
    lea rcx, [rip + aac_pair_mod]
    movzx r8d, byte ptr [rcx + rbx - 5]
    xor edx, edx
    div r8d
    mov [rsp + 32], eax
    mov [rsp + 36], edx
    mov esi, 2
    cmp ebx, 6
    ja .Laac_tuple_unsigned
    mov ecx, 4                            # signed books 5-6: -4..4
.Laac_tuple_offset:
    xor edx, edx
.Laac_tuple_offset_value:
    sub [rsp + 32 + rdx*4], ecx
    inc edx
    cmp edx, esi
    jb .Laac_tuple_offset_value
    jmp .Laac_tuple_store
.Laac_tuple_unsigned:
    # Sign bits follow the codeword, one per nonzero value.
    xor r12d, r12d                        # negative-value mask
    xor eax, eax
    mov [rsp + 48], eax                   # value
.Laac_tuple_sign:
    mov eax, [rsp + 48]
    cmp eax, esi
    jae .Laac_tuple_escape
    cmp dword ptr [rsp + 32 + rax*4], 0
    je .Laac_tuple_sign_next
    mov ecx, 1
    call aac_get
    mov ecx, [rsp + 48]
    shl eax, cl
    or r12d, eax
.Laac_tuple_sign_next:
    inc dword ptr [rsp + 48]
    jmp .Laac_tuple_sign
.Laac_tuple_escape:
    cmp ebx, 11
    jne .Laac_tuple_signs
    mov dword ptr [rsp + 48], 0
.Laac_tuple_escape_value:
    mov eax, [rsp + 48]
    cmp eax, 2
    jae .Laac_tuple_signs
    cmp dword ptr [rsp + 32 + rax*4], 16
    jne .Laac_tuple_escape_next
    or dword ptr [rip + aac_features], AF_ESCAPE
    mov dword ptr [rsp + 52], 4           # escape word bits
.Laac_tuple_prefix:
    mov ecx, 1
    call aac_get
    test eax, eax
    jz .Laac_tuple_word
    inc dword ptr [rsp + 52]
    cmp dword ptr [rsp + 52], 13
    jae .Laac_tuple_bad
    jmp .Laac_tuple_prefix
.Laac_tuple_word:
    mov ecx, [rsp + 52]
    call aac_get
    mov ecx, [rsp + 52]
    mov edx, 1
    shl edx, cl
    add eax, edx
    mov ecx, [rsp + 48]
    mov [rsp + 32 + rcx*4], eax
.Laac_tuple_escape_next:
    inc dword ptr [rsp + 48]
    jmp .Laac_tuple_escape_value
.Laac_tuple_signs:
    xor edx, edx
.Laac_tuple_sign_apply:
    bt r12d, edx
    jnc .Laac_tuple_sign_apply_next
    neg dword ptr [rsp + 32 + rdx*4]
.Laac_tuple_sign_apply_next:
    inc edx
    cmp edx, esi
    jb .Laac_tuple_sign_apply
.Laac_tuple_store:
    xor edx, edx
.Laac_tuple_store_value:
    mov eax, [rsp + 32 + rdx*4]
    mov [rdi + rdx*4], eax
    inc edx
    cmp edx, esi
    jb .Laac_tuple_store_value
    mov eax, esi
    jmp .Laac_tuple_return
.Laac_tuple_bad:
    xor eax, eax
.Laac_tuple_return:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_tuple

# ECX=quarter-step exponent e -> XMM0=2^(e/4) as a float (|e| <= 152).
LOCALFN aac_power
    mov eax, ecx
    and eax, 3
    lea rdx, [rip + aac_quarter_powers]
    mov eax, [rdx + rax*4]
    sar ecx, 2
    shl ecx, 23
    add eax, ecx
    movd xmm0, eax
    ret
ENDFN aac_power

# RCX=channel stream, EDX=element channel. Applies pulses and dequantizes:
# regular bands sign(q)|q|^(4/3) 2^((sf-100)/4); noise bands draw the noise
# generator, normalized to the band energy; intensity bands wait for the
# stereo stage.
LOCALFN aac_dequantize
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    movdqu [rsp + 64], xmm6
    mov rbx, rcx
    mov [rsp + 56], edx
    mov r15, [rip + aac_memory]
    shl edx, 12
    lea r14, [r15 + rdx + AM_COEF]
    lea r15, [r15 + rdx + AM_QUANT]
    mov rdi, r14
    xor eax, eax
    mov ecx, 1024
    rep stosd
    # Pulses add to regular bands of a long window: |q| grows by the amplitude.
    xor esi, esi
.Laac_deq_pulse:
    cmp esi, [rbx + IC_PULSES]
    jae .Laac_deq_bands
    mov eax, [rbx + IC_PULSE_POS + rsi*4]
    mov ecx, [rbx + IC_SWB]
    lea rdx, [rip + aac_swb_offsets]
    xor r8d, r8d                          # band holding the pulse
.Laac_deq_pulse_band:
    lea r9d, [rcx + r8 + 1]
    movzx r9d, word ptr [rdx + r9*2]
    cmp eax, r9d
    jb .Laac_deq_pulse_found
    inc r8d
    cmp r8d, [rbx + IC_NUM_SWB]
    jb .Laac_deq_pulse_band
    jmp .Laac_deq_pulse_next
.Laac_deq_pulse_found:
    cmp r8d, [rbx + IC_MAX_SFB]
    jae .Laac_deq_pulse_next
    movzx r8d, byte ptr [rbx + IC_BAND_TYPE + r8]
    test r8d, r8d
    jz .Laac_deq_pulse_next
    cmp r8d, 11
    ja .Laac_deq_pulse_next
    mov ecx, [r15 + rax*4]
    mov edx, [rbx + IC_PULSE_AMP + rsi*4]
    test ecx, ecx
    jg .Laac_deq_pulse_add
    neg edx
.Laac_deq_pulse_add:
    add ecx, edx
    mov [r15 + rax*4], ecx
.Laac_deq_pulse_next:
    inc esi
    jmp .Laac_deq_pulse
.Laac_deq_bands:
    xor r12d, r12d                        # group
    xor r13d, r13d                        # first window of the group
    mov dword ptr [rsp + 32], 0           # band index of the group's first band
.Laac_deq_group:
    cmp r12d, [rbx + IC_GROUPS]
    jae .Laac_deq_done
    xor esi, esi                          # band
.Laac_deq_band:
    cmp esi, [rbx + IC_MAX_SFB]
    jae .Laac_deq_group_next
    mov eax, [rsp + 32]
    add eax, esi
    mov [rsp + 36], eax                   # band index
    movzx edi, byte ptr [rbx + IC_BAND_TYPE + rax]
    test edi, edi
    jz .Laac_deq_band_next
    cmp edi, 13
    ja .Laac_deq_band_next                # intensity
    mov ecx, [rbx + IC_SWB]
    add ecx, esi
    lea rdx, [rip + aac_swb_offsets]
    movzx eax, word ptr [rdx + rcx*2]
    mov [rsp + 40], eax                   # band start
    movzx eax, word ptr [rdx + rcx*2 + 2]
    mov [rsp + 44], eax                   # band end
    mov eax, [rsp + 36]
    mov ecx, [rbx + IC_SF + rax*4]
    cmp edi, 13
    je .Laac_deq_noise
    sub ecx, 100
    call aac_power
    movss xmm6, xmm0                      # band scale
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    mov [rsp + 48], eax
    mov [rsp + 52], r13d
.Laac_deq_window:
    cmp dword ptr [rsp + 48], 0
    je .Laac_deq_band_next
    mov ecx, [rsp + 52]
    shl ecx, 7
    mov edx, ecx
    add ecx, [rsp + 40]
    add edx, [rsp + 44]
    lea r8, [rip + mp_pow43]
.Laac_deq_value:
    cmp ecx, edx
    jae .Laac_deq_window_next
    mov eax, [r15 + rcx*4]
    mov r9d, eax
    neg r9d
    cmovs r9d, eax                        # |q|
    movss xmm0, [r8 + r9*4]
    mulss xmm0, xmm6
    test eax, eax
    jns .Laac_deq_store
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movss xmm0, xmm1
.Laac_deq_store:
    movss [r14 + rcx*4], xmm0
    inc ecx
    jmp .Laac_deq_value
.Laac_deq_window_next:
    inc dword ptr [rsp + 52]
    dec dword ptr [rsp + 48]
    jmp .Laac_deq_window
.Laac_deq_noise:
    or dword ptr [rip + aac_features], AF_NOISE
    cmp ecx, -100
    jge .Laac_deq_noise_low
    mov ecx, -100
.Laac_deq_noise_low:
    cmp ecx, 155
    jle .Laac_deq_noise_high
    mov ecx, 155
.Laac_deq_noise_high:
    call aac_power
    cvtss2sd xmm6, xmm0                   # band energy scale
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    mov [rsp + 48], eax
    mov [rsp + 52], r13d
    # In a pair with an explicit M/S mask, a band that is noise in both
    # channels and marked M/S reuses the first channel's noise vector.
    cmp dword ptr [rsp + 56], 1
    jne .Laac_deq_noise_window
    cmp dword ptr [rip + aac_ms_present], 1
    jne .Laac_deq_noise_window
    mov eax, [rsp + 36]
    lea rcx, [rip + aac_ms_mask]
    cmp byte ptr [rcx + rax], 0
    je .Laac_deq_noise_window
    lea rcx, [rip + aac_ics]
    cmp byte ptr [rcx + IC_BAND_TYPE + rax], 13
    jne .Laac_deq_noise_window
    mov ecx, [rcx + IC_SF + rax*4]
    cmp ecx, -100
    jge .Laac_deq_shared_low
    mov ecx, -100
.Laac_deq_shared_low:
    cmp ecx, 155
    jle .Laac_deq_shared_high
    mov ecx, 155
.Laac_deq_shared_high:
    call aac_power
    cvtss2sd xmm0, xmm0
    movapd xmm1, xmm6
    divsd xmm1, xmm0                      # this channel's energy / the first's
    mov r9, [rip + aac_memory]
    add r9, AM_COEF                       # first channel's spectrum
.Laac_deq_shared_window:
    cmp dword ptr [rsp + 48], 0
    je .Laac_deq_band_next
    mov ecx, [rsp + 52]
    shl ecx, 7
    mov edx, ecx
    add ecx, [rsp + 40]
    add edx, [rsp + 44]
.Laac_deq_shared_value:
    cmp ecx, edx
    jae .Laac_deq_shared_window_next
    cvtss2sd xmm0, [r9 + rcx*4]
    mulsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [r14 + rcx*4], xmm0
    inc ecx
    jmp .Laac_deq_shared_value
.Laac_deq_shared_window_next:
    inc dword ptr [rsp + 52]
    dec dword ptr [rsp + 48]
    jmp .Laac_deq_shared_window
.Laac_deq_noise_window:
    cmp dword ptr [rsp + 48], 0
    je .Laac_deq_band_next
    mov ecx, [rsp + 52]
    shl ecx, 7
    mov edx, ecx
    add ecx, [rsp + 40]
    add edx, [rsp + 44]
    mov r9d, ecx
    xorpd xmm2, xmm2                      # energy
    mov eax, [rip + aac_random]
.Laac_deq_noise_draw:
    cmp ecx, edx
    jae .Laac_deq_noise_scale
    imul eax, eax, 1664525
    add eax, 1013904223
    cvtsi2sd xmm0, eax
    cvtsi2ss xmm1, eax
    movss [r14 + rcx*4], xmm1
    mulsd xmm0, xmm0
    addsd xmm2, xmm0
    inc ecx
    jmp .Laac_deq_noise_draw
.Laac_deq_noise_scale:
    mov [rip + aac_random], eax
    sqrtsd xmm2, xmm2
    movapd xmm0, xmm6
    divsd xmm0, xmm2
    mov ecx, r9d
.Laac_deq_noise_value:
    cmp ecx, edx
    jae .Laac_deq_noise_window_next
    cvtss2sd xmm1, [r14 + rcx*4]
    mulsd xmm1, xmm0
    cvtsd2ss xmm1, xmm1
    movss [r14 + rcx*4], xmm1
    inc ecx
    jmp .Laac_deq_noise_value
.Laac_deq_noise_window_next:
    inc dword ptr [rsp + 52]
    dec dword ptr [rsp + 48]
    jmp .Laac_deq_noise_window
.Laac_deq_band_next:
    inc esi
    jmp .Laac_deq_band
.Laac_deq_group_next:
    mov eax, [rbx + IC_MAX_SFB]
    add [rsp + 32], eax
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    add r13d, eax
    inc r12d
    jmp .Laac_deq_group
.Laac_deq_done:
    movdqu xmm6, [rsp + 64]
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_dequantize

# Mid/side and intensity stereo for a common-window pair.
LOCALFN aac_stereo
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    lea rbx, [rip + aac_ics]
    mov r14, [rip + aac_memory]
    lea r15, [r14 + AM_COEF + 4096]       # second channel
    add r14, AM_COEF
    xor r12d, r12d                        # group
    xor r13d, r13d                        # first window of the group
    mov dword ptr [rsp + 32], 0
.Laac_stereo_group:
    cmp r12d, [rbx + IC_GROUPS]
    jae .Laac_stereo_done
    xor esi, esi
.Laac_stereo_band:
    cmp esi, [rbx + IC_MAX_SFB]
    jae .Laac_stereo_group_next
    mov edi, [rsp + 32]
    add edi, esi                          # band index
    mov ecx, [rbx + IC_SWB]
    add ecx, esi
    lea rdx, [rip + aac_swb_offsets]
    movzx eax, word ptr [rdx + rcx*2]
    mov [rsp + 40], eax
    movzx eax, word ptr [rdx + rcx*2 + 2]
    mov [rsp + 44], eax
    movzx eax, byte ptr [rbx + IC_SIZE + IC_BAND_TYPE + rdi]
    cmp eax, 14
    jae .Laac_stereo_intensity
    cmp dword ptr [rip + aac_ms_present], 0
    je .Laac_stereo_band_next
    lea rcx, [rip + aac_ms_mask]
    cmp byte ptr [rcx + rdi], 0
    je .Laac_stereo_band_next
    cmp eax, 13
    je .Laac_stereo_band_next             # noise bands keep their noise
    cmp byte ptr [rbx + IC_BAND_TYPE + rdi], 13
    jae .Laac_stereo_band_next
    or dword ptr [rip + aac_features], AF_MS
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    mov r8d, r13d
.Laac_stereo_ms_window:
    test eax, eax
    jz .Laac_stereo_band_next
    mov ecx, r8d
    shl ecx, 7
    mov edx, ecx
    add ecx, [rsp + 40]
    add edx, [rsp + 44]
.Laac_stereo_ms_value:
    cmp ecx, edx
    jae .Laac_stereo_ms_window_next
    movss xmm0, [r14 + rcx*4]
    movss xmm1, [r15 + rcx*4]
    movss xmm2, xmm0
    addss xmm0, xmm1
    subss xmm2, xmm1
    movss [r14 + rcx*4], xmm0
    movss [r15 + rcx*4], xmm2
    inc ecx
    jmp .Laac_stereo_ms_value
.Laac_stereo_ms_window_next:
    inc r8d
    dec eax
    jmp .Laac_stereo_ms_window
.Laac_stereo_intensity:
    # Right = left * 2^(-position/4), in phase for book 15, inverted for 14
    # and by the M/S flag when the mask is transmitted.
    or dword ptr [rip + aac_features], AF_INTENSITY
    mov r9d, 1
    cmp eax, 15
    je .Laac_stereo_is_phase
    neg r9d
.Laac_stereo_is_phase:
    cmp dword ptr [rip + aac_ms_present], 1
    jne .Laac_stereo_is_scale
    lea rcx, [rip + aac_ms_mask]
    cmp byte ptr [rcx + rdi], 0
    je .Laac_stereo_is_scale
    neg r9d
.Laac_stereo_is_scale:
    mov ecx, [rbx + IC_SIZE + IC_SF + rdi*4]
    cmp ecx, -155
    jge .Laac_stereo_is_low
    mov ecx, -155
.Laac_stereo_is_low:
    cmp ecx, 100
    jle .Laac_stereo_is_high
    mov ecx, 100
.Laac_stereo_is_high:
    neg ecx
    call aac_power
    test r9d, r9d
    jns .Laac_stereo_is_sign
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movss xmm0, xmm1
.Laac_stereo_is_sign:
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    mov r8d, r13d
.Laac_stereo_is_window:
    test eax, eax
    jz .Laac_stereo_band_next
    mov ecx, r8d
    shl ecx, 7
    mov edx, ecx
    add ecx, [rsp + 40]
    add edx, [rsp + 44]
.Laac_stereo_is_value:
    cmp ecx, edx
    jae .Laac_stereo_is_window_next
    movss xmm1, [r14 + rcx*4]
    mulss xmm1, xmm0
    movss [r15 + rcx*4], xmm1
    inc ecx
    jmp .Laac_stereo_is_value
.Laac_stereo_is_window_next:
    inc r8d
    dec eax
    jmp .Laac_stereo_is_window
.Laac_stereo_band_next:
    inc esi
    jmp .Laac_stereo_band
.Laac_stereo_group_next:
    mov eax, [rbx + IC_MAX_SFB]
    add [rsp + 32], eax
    movzx eax, byte ptr [rbx + IC_GROUP_LEN + r12]
    add r13d, eax
    inc r12d
    jmp .Laac_stereo_group
.Laac_stereo_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_stereo

# ECX=element channel, EDX=output channel: TNS, then the filterbank.
LOCALFN aac_finish_channel
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov esi, ecx
    mov edi, edx
    imul ebx, ecx, IC_SIZE
    lea rax, [rip + aac_ics]
    add rbx, rax
    cmp dword ptr [rbx + IC_TNS], 0
    je .Laac_finish_filterbank
    mov rcx, rbx
    mov edx, esi
    call aac_apply_tns
.Laac_finish_filterbank:
    mov rcx, rbx
    mov edx, esi
    mov r8d, edi
    call aac_filterbank
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_finish_channel

# Temporal noise shaping in single precision, as the filtered spectrum is
# stored: RCX=channel stream, EDX=element channel. Locals:
# 32 band limit, 36 bottom, 40 top, 44 2^coef_res_bits, 48 reflection
# coefficient, 56 window, 60 filter, 64 filter slot.
LOCALFN aac_apply_tns
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    mov rbx, rcx
    mov r15, [rip + aac_memory]
    shl edx, 12
    lea r15, [r15 + rdx + AM_COEF]
    lea rdi, [rip + aac_lpc]
    mov eax, [rbx + IC_TNS_MAX]           # filters stop at min(TNS bands, max_sfb)
    cmp eax, [rbx + IC_MAX_SFB]
    cmova eax, [rbx + IC_MAX_SFB]
    mov [rsp + 32], eax
    mov dword ptr [rsp + 56], 0
.Laac_atns_window:
    mov eax, [rsp + 56]
    cmp eax, [rbx + IC_WINDOWS]
    jae .Laac_atns_done
    mov eax, [rbx + IC_NUM_SWB]
    mov [rsp + 36], eax                   # bottom
    mov dword ptr [rsp + 60], 0
.Laac_atns_filter:
    mov esi, [rsp + 56]
    movzx eax, byte ptr [rbx + IC_TNS_NFILT + rsi]
    cmp [rsp + 60], eax
    jae .Laac_atns_window_next
    lea r12d, [rsi + rsi*2]
    add r12d, [rsp + 60]                  # window * 3 + filter
    mov [rsp + 64], r12d
    mov eax, [rsp + 36]
    mov [rsp + 40], eax                   # top
    movzx ecx, byte ptr [rbx + IC_TNS_LEN + r12]
    sub eax, ecx
    jns .Laac_atns_bottom
    xor eax, eax
.Laac_atns_bottom:
    mov [rsp + 36], eax
    movzx r13d, byte ptr [rbx + IC_TNS_ORDER + r12]
    test r13d, r13d
    jz .Laac_atns_filter_next
    # Reflection coefficients sin(c / iqfac) to direct-form LPC (ISO 4.6.9.3):
    # c / iqfac = pi c / (2^bits - 1), or pi c / (2^bits + 1) for c < 0.
    movzx eax, byte ptr [rbx + IC_TNS_RES + rsi]
    mov ecx, 8
    test eax, eax
    jz .Laac_atns_res
    mov ecx, 16
.Laac_atns_res:
    mov [rsp + 44], ecx
    imul r14d, r12d, 12
    lea r14, [rbx + IC_TNS_COEF + r14]
    xor r12d, r12d                        # m - 1
.Laac_atns_parcor:
    cmp r12d, r13d
    jae .Laac_atns_range
    movsx eax, byte ptr [r14 + r12]
    cvtsi2sd xmm0, eax
    mov ecx, [rsp + 44]
    dec ecx
    test eax, eax
    jns .Laac_atns_denominator
    add ecx, 2
.Laac_atns_denominator:
    cvtsi2sd xmm1, ecx
    divsd xmm0, xmm1
    call sin_pi
    cvtsd2ss xmm0, xmm0                   # single precision from here on
    movss [rsp + 48], xmm0
    # a[i] += k a[m - i] for 1 <= i < m, in place by symmetric pairs.
    mov ecx, 1                            # i
.Laac_atns_update:
    mov edx, r12d
    inc edx
    sub edx, ecx                          # m - i
    cmp ecx, edx
    ja .Laac_atns_update_done
    movss xmm1, [rdi + rcx*4]
    movss xmm2, [rdi + rdx*4]
    je .Laac_atns_update_middle
    movss xmm3, xmm2
    mulss xmm3, xmm0
    addss xmm3, xmm1
    mulss xmm1, xmm0
    addss xmm1, xmm2
    movss [rdi + rcx*4], xmm3
    movss [rdi + rdx*4], xmm1
    inc ecx
    jmp .Laac_atns_update
.Laac_atns_update_middle:
    mulss xmm2, xmm0
    addss xmm1, xmm2
    movss [rdi + rcx*4], xmm1
.Laac_atns_update_done:
    lea eax, [r12 + 1]
    movss [rdi + rax*4], xmm0             # a[m] = k
    inc r12d
    jmp .Laac_atns_parcor
.Laac_atns_range:
    mov ecx, [rbx + IC_SWB]
    lea rdx, [rip + aac_swb_offsets]
    mov eax, [rsp + 36]
    cmp eax, [rsp + 32]
    cmova eax, [rsp + 32]
    add eax, ecx
    movzx r8d, word ptr [rdx + rax*2]     # start
    mov eax, [rsp + 40]
    cmp eax, [rsp + 32]
    cmova eax, [rsp + 32]
    add eax, ecx
    movzx r9d, word ptr [rdx + rax*2]     # end
    mov r10d, r9d
    sub r10d, r8d                         # size
    jle .Laac_atns_filter_next
    or dword ptr [rip + aac_features], AF_TNS
    mov r11, 1                            # direction
    mov eax, [rsp + 64]
    cmp byte ptr [rbx + IC_TNS_DIR + rax], 0
    je .Laac_atns_up
    mov r11, -1
    lea r8d, [r9 - 1]
.Laac_atns_up:
    mov eax, [rsp + 56]
    shl eax, 7
    add r8d, eax
    lea r12, [r15 + r8*4]                 # first coefficient
    shl r11, 2                            # byte step
    xor ecx, ecx                          # m
.Laac_atns_sample:
    cmp ecx, r10d
    jae .Laac_atns_filter_next
    movss xmm0, [r12]
    mov edx, r13d
    cmp edx, ecx
    cmova edx, ecx                        # taps available
    mov r8, r12
    mov eax, 1
.Laac_atns_tap:
    cmp eax, edx
    ja .Laac_atns_tap_done
    sub r8, r11
    movss xmm1, [r8]
    mulss xmm1, [rdi + rax*4]
    subss xmm0, xmm1
    inc eax
    jmp .Laac_atns_tap
.Laac_atns_tap_done:
    movss [r12], xmm0
    add r12, r11
    inc ecx
    jmp .Laac_atns_sample
.Laac_atns_filter_next:
    inc dword ptr [rsp + 60]
    jmp .Laac_atns_filter
.Laac_atns_window_next:
    inc dword ptr [rsp + 56]
    jmp .Laac_atns_window
.Laac_atns_done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_apply_tns

# Filterbank: RCX=channel stream, EDX=element channel, R8D=output channel.
# IMDCT, windowing with the previous frame's shape on the left half, and
# overlap-add into the channel's output.
LOCALFN aac_filterbank
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov r12d, r8d                         # output channel
    mov r15, [rip + aac_memory]
    shl edx, 12
    lea r13, [r15 + rdx + AM_COEF]        # spectrum
    mov eax, r12d
    shl eax, 12
    lea r14, [r15 + rax + AM_OVERLAP]     # overlap (floats)
    lea rdi, [r15 + rax*2 + AM_PCM]       # output (floats)
    lea rcx, [rip + aac_prev_shape]
    movzx eax, byte ptr [rcx + r12]
    mov [rsp + 32], eax                   # previous shape
    mov eax, [rbx + IC_SHAPE]
    mov [rsp + 36], eax                   # current shape
    mov byte ptr [rcx + r12], al
    cmp dword ptr [rbx + IC_SEQ], 2
    je .Laac_fb_short
    # Long windows: one 2048-point IMDCT.
    mov rcx, r13
    xor edx, edx
    lea r8, [r15 + AM_BUF]
    call aac_imdct
    lea rsi, [r15 + AM_BUF]               # doubles
    mov eax, [rsp + 32]
    shl eax, 12
    lea r8, [rip + aac_win_long]
    add r8, rax                           # previous long window (rising)
    mov eax, [rsp + 32]
    shl eax, 9
    lea r9, [rip + aac_win_short]
    add r9, rax                           # previous short window (rising)
    xor ecx, ecx
.Laac_fb_left:
    cmp ecx, 1024
    jae .Laac_fb_right
    cvtsd2ss xmm0, [rsi + rcx*8]
    cmp dword ptr [rbx + IC_SEQ], 3
    je .Laac_fb_left_stop
    mulss xmm0, [r8 + rcx*4]
    jmp .Laac_fb_left_add
.Laac_fb_left_stop:
    cmp ecx, 448
    jb .Laac_fb_left_zero
    cmp ecx, 576
    jae .Laac_fb_left_add
    mulss xmm0, [r9 + rcx*4 - 448*4]
    jmp .Laac_fb_left_add
.Laac_fb_left_zero:
    xorps xmm0, xmm0
.Laac_fb_left_add:
    addss xmm0, [r14 + rcx*4]
    movss [rdi + rcx*4], xmm0
    inc ecx
    jmp .Laac_fb_left
.Laac_fb_right:
    mov eax, [rsp + 36]
    shl eax, 12
    lea r8, [rip + aac_win_long]
    add r8, rax                           # current long window
    mov eax, [rsp + 36]
    shl eax, 9
    lea r9, [rip + aac_win_short]
    add r9, rax                           # current short window
    xor ecx, ecx
.Laac_fb_right_value:
    cmp ecx, 1024
    jae .Laac_fb_done
    cvtsd2ss xmm0, [rsi + rcx*8 + 8192]
    mov eax, 1023
    sub eax, ecx
    cmp dword ptr [rbx + IC_SEQ], 1
    je .Laac_fb_right_start
    mulss xmm0, [r8 + rax*4]
    jmp .Laac_fb_right_store
.Laac_fb_right_start:
    cmp ecx, 448
    jb .Laac_fb_right_store
    cmp ecx, 576
    jae .Laac_fb_right_zero
    mov eax, 575
    sub eax, ecx
    mulss xmm0, [r9 + rax*4]
    jmp .Laac_fb_right_store
.Laac_fb_right_zero:
    xorps xmm0, xmm0
.Laac_fb_right_store:
    movss [r14 + rcx*4], xmm0
    inc ecx
    jmp .Laac_fb_right_value
.Laac_fb_short:
    # Eight short windows overlap at 448 + 128 w inside the 2048-sample frame.
    lea rsi, [r15 + AM_TIME]
    push rdi
    mov rdi, rsi
    xor eax, eax
    mov ecx, 2048*2
    rep stosd
    pop rdi
    mov dword ptr [rsp + 40], 0           # window
.Laac_fb_short_window:
    cmp dword ptr [rsp + 40], 8
    jae .Laac_fb_short_add
    mov eax, [rsp + 40]
    shl eax, 9
    lea rcx, [r13 + rax]                  # 128 coefficients
    mov edx, 1
    lea r8, [r15 + AM_BUF]
    call aac_imdct
    mov eax, [rsp + 36]
    cmp dword ptr [rsp + 40], 0
    jne .Laac_fb_short_shape
    mov eax, [rsp + 32]
.Laac_fb_short_shape:
    shl eax, 9
    lea r8, [rip + aac_win_short]
    add r8, rax                           # rising half
    mov eax, [rsp + 36]
    shl eax, 9
    lea r9, [rip + aac_win_short]
    add r9, rax                           # falling half (current shape)
    mov eax, [rsp + 40]
    shl eax, 7
    add eax, 448
    lea r10, [rsi + rax*8]                # time position
    lea r11, [r15 + AM_BUF]
    xor ecx, ecx
.Laac_fb_short_rise:
    cvtss2sd xmm1, [r8 + rcx*4]
    mulsd xmm1, [r11 + rcx*8]
    addsd xmm1, [r10 + rcx*8]
    movsd [r10 + rcx*8], xmm1
    inc ecx
    cmp ecx, 128
    jb .Laac_fb_short_rise
    xor ecx, ecx
.Laac_fb_short_fall:
    mov eax, 127
    sub eax, ecx
    cvtss2sd xmm1, [r9 + rax*4]
    mulsd xmm1, [r11 + rcx*8 + 1024]
    addsd xmm1, [r10 + rcx*8 + 1024]
    movsd [r10 + rcx*8 + 1024], xmm1
    inc ecx
    cmp ecx, 128
    jb .Laac_fb_short_fall
    inc dword ptr [rsp + 40]
    jmp .Laac_fb_short_window
.Laac_fb_short_add:
    xor ecx, ecx
.Laac_fb_short_out:
    cvtsd2ss xmm0, [rsi + rcx*8]
    addss xmm0, [r14 + rcx*4]
    movss [rdi + rcx*4], xmm0
    cvtsd2ss xmm0, [rsi + rcx*8 + 8192]
    movss [r14 + rcx*4], xmm0
    inc ecx
    cmp ecx, 1024
    jb .Laac_fb_short_out
.Laac_fb_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_filterbank

# IMDCT: RCX=coefficients (floats), EDX=0 for 1024 or 1 for 128, R8=output
# doubles (2048 or 256), scaled by 2/N/32768. DCT-IV of the coefficients by a
# half-length complex FFT with pre- and post-twiddles, then unfolded.
LOCALFN aac_imdct
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    mov rdi, r8
    mov r15, [rip + aac_memory]
    add r15, AM_FFT
    mov r12d, 512                         # h = M / 2
    lea r13, [rip + aac_pre_long]
    lea r14, [rip + aac_post_long]
    lea rbx, [rip + aac_rev512]
    test edx, edx
    jz .Laac_imdct_sizes
    mov r12d, 64
    lea r13, [rip + aac_pre_short]
    lea r14, [rip + aac_post_short]
    lea rbx, [rip + aac_rev64]
.Laac_imdct_sizes:
    # z[n] = (x[2n] + i x[M-1-2n]) * pre[n], stored bit-reversed.
    lea r9d, [r12*2 - 1]                  # M - 1
    xor ecx, ecx
.Laac_imdct_pre:
    lea eax, [rcx*2]
    cvtss2sd xmm0, [rsi + rax*4]
    mov edx, r9d
    sub edx, eax
    cvtss2sd xmm1, [rsi + rdx*4]
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
    jb .Laac_imdct_pre
    # Radix-2 decimation in time; twiddle exp(-2 pi i k / size) is entry
    # k * 512 / size of the 512-point table.
    lea r10, [rip + aac_fft_tw]
    mov r8d, 2                            # size
.Laac_imdct_stage:
    cmp r8d, r12d
    ja .Laac_imdct_post
    mov r9d, r8d
    shr r9d, 1                            # half
    mov eax, 512
    xor edx, edx
    div r8d
    shl eax, 5
    mov r11d, eax                         # twiddle stride in bytes
    mov r13d, r9d
    shl r13d, 4                           # half in bytes
    xor ecx, ecx                          # block start
.Laac_imdct_block:
    cmp ecx, r12d
    jae .Laac_imdct_stage_next
    mov eax, ecx
    shl eax, 4
    lea rsi, [r15 + rax]                  # a[start + k]
    lea rbx, [rsi + r13]                  # a[start + k + half]
    xor edx, edx                          # twiddle offset
    mov eax, r9d                          # butterflies
.Laac_imdct_butterfly:
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
    jnz .Laac_imdct_butterfly
    add ecx, r8d
    jmp .Laac_imdct_block
.Laac_imdct_stage_next:
    shl r8d, 1
    jmp .Laac_imdct_stage
.Laac_imdct_post:
    # c[k] = Z[k] post[k]; y[2k] = Re c[k], y[M-1-2k] = -Im c[k]. Pairs k and
    # j = h-1-k are rewritten in place as the real sequence y.
    xor ecx, ecx
.Laac_imdct_post_pair:
    mov eax, r12d
    shr eax, 1
    cmp ecx, eax
    jae .Laac_imdct_unfold
    mov eax, ecx
    shl eax, 4
    movapd xmm0, [r15 + rax]
    mov eax, ecx
    shl eax, 5
    movapd xmm1, xmm0
    shufpd xmm1, xmm1, 1
    mulpd xmm0, [r14 + rax]
    mulpd xmm1, [r14 + rax + 16]
    addpd xmm0, xmm1                      # c[k]
    lea edx, [r12 - 1]
    sub edx, ecx                          # j
    mov eax, edx
    shl eax, 4
    movapd xmm2, [r15 + rax]
    mov eax, edx
    shl eax, 5
    movapd xmm3, xmm2
    shufpd xmm3, xmm3, 1
    mulpd xmm2, [r14 + rax]
    mulpd xmm3, [r14 + rax + 16]
    addpd xmm2, xmm3                      # c[j]
    # Doubles 2k, 2k+1 = Re c[k], -Im c[j]; doubles 2j, 2j+1 = Re c[j], -Im c[k].
    xorpd xmm4, xmm4
    xorpd xmm5, xmm5
    subpd xmm4, xmm2
    subpd xmm5, xmm0
    unpckhpd xmm4, xmm4
    unpckhpd xmm5, xmm5
    mov eax, ecx
    shl eax, 4
    movsd [r15 + rax], xmm0
    movsd [r15 + rax + 8], xmm4
    mov eax, edx
    shl eax, 4
    movsd [r15 + rax], xmm2
    movsd [r15 + rax + 8], xmm5
    inc ecx
    jmp .Laac_imdct_post_pair
.Laac_imdct_unfold:
    # out[n] = y[h+n], out[h+n] = -y[M-1-n], out[2h+n] = -y[h-1-n],
    # out[3h+n] = -y[n], n < h (N = 4h).
    movapd xmm5, [rip + aac_sign_low]
    lea r9d, [r12*2 - 1]                  # M - 1
    lea r10, [rdi + r12*8]                # out + h
    lea r11, [r10 + r12*8]                # out + 2h
    lea r13, [r11 + r12*8]                # out + 3h
    xor ecx, ecx
.Laac_imdct_unfold_value:
    lea eax, [r12 + rcx]
    movsd xmm0, [r15 + rax*8]
    movsd [rdi + rcx*8], xmm0
    mov eax, r9d
    sub eax, ecx
    movsd xmm0, [r15 + rax*8]
    xorpd xmm0, xmm5
    movsd [r10 + rcx*8], xmm0
    lea eax, [r12 - 1]
    sub eax, ecx
    movsd xmm0, [r15 + rax*8]
    xorpd xmm0, xmm5
    movsd [r11 + rcx*8], xmm0
    movsd xmm0, [r15 + rcx*8]
    xorpd xmm0, xmm5
    movsd [r13 + rcx*8], xmm0
    inc ecx
    cmp ecx, r12d
    jb .Laac_imdct_unfold_value
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_imdct

# RCX=stereo float output: mixes the decoded channels.
LOCALFN aac_emit
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    mov rsi, [rip + aac_memory]
    add rsi, AM_PCM
    mov ebx, [rip + aac_channels]
    mov r11d, AAC_FRAME
    cmp dword ptr [rip + sbr_active], 0
    je .Laac_emit_count
    add r11d, r11d
    cmp qword ptr [rip + sbr_ps], 0       # parametric stereo: channel 1 holds the right
    je .Laac_emit_count
    mov ebx, 2
.Laac_emit_count:
    cmp dword ptr [rip + pcm_mix], 0
    jne .Laac_emit_mix
    xor ecx, ecx
    cmp ebx, 2
    je .Laac_emit_stereo
.Laac_emit_mono:
    movss xmm0, [rsi + rcx*4]
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm0
    inc ecx
    cmp ecx, r11d
    jb .Laac_emit_mono
    jmp .Laac_emit_done
.Laac_emit_stereo:
    movss xmm0, [rsi + rcx*4]
    movss xmm1, [rsi + rcx*4 + 8192]
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    cmp ecx, r11d
    jb .Laac_emit_stereo
    jmp .Laac_emit_done
.Laac_emit_mix:
    lea r8, [rip + alac_wave_index]
    lea eax, [rbx - 1]
    lea r8, [r8 + rax*8]                  # AAC channel -> WAVE position
    lea r9, [rip + pcm_mix_coeff]
    xor ecx, ecx
.Laac_emit_frame:
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    xor edx, edx
.Laac_emit_channel:
    movzx eax, byte ptr [r8 + rdx]
    shl eax, 4
    mov r10d, edx
    shl r10d, 13
    add r10, rsi
    cvtss2sd xmm2, [r10 + rcx*4]
    movsd xmm3, xmm2
    mulsd xmm2, [r9 + rax]
    mulsd xmm3, [r9 + rax + 8]
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    inc edx
    cmp edx, ebx
    jb .Laac_emit_channel
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss [rdi + rcx*8], xmm0
    movss [rdi + rcx*8 + 4], xmm1
    inc ecx
    cmp ecx, r11d
    jb .Laac_emit_frame
.Laac_emit_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_emit

# Windows, transform twiddles and bit-reversal tables, computed once.
LOCALFN aac_init_tables
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    movdqu [rsp + 32], xmm6
    movdqu [rsp + 48], xmm7
    cmp dword ptr [rip + aac_tables_ready], 0
    jne .Laac_init_done
    # Sine windows: sin(pi (n + 1/2) / N).
    lea rdi, [rip + aac_win_long]
    mov ebx, 1024
    call aac_sine_window
    lea rdi, [rip + aac_win_short]
    mov ebx, 128
    call aac_sine_window
    # Kaiser-Bessel-derived windows: alpha 4 (long), 6 (short).
    lea rcx, [rip + aac_win_long + 4096]
    mov edx, 1024
    mov r8d, 4
    call aac_kbd_window
    lea rcx, [rip + aac_win_short + 512]
    mov edx, 128
    mov r8d, 6
    call aac_kbd_window
    # Pre-twiddles s exp(-i pi (n + 1/4) / M) and post-twiddles exp(-i pi k / M).
    lea rcx, [rip + aac_pre_long]
    mov edx, 512
    mov r8d, 1024
    movsd xmm2, [rip + aac_quarter]
    movsd xmm3, [rip + aac_long_scale]
    call aac_twiddles
    lea rcx, [rip + aac_post_long]
    mov edx, 512
    mov r8d, 1024
    xorpd xmm2, xmm2
    movsd xmm3, [rip + aac_one]
    call aac_twiddles
    lea rcx, [rip + aac_pre_short]
    mov edx, 64
    mov r8d, 128
    movsd xmm2, [rip + aac_quarter]
    movsd xmm3, [rip + aac_short_scale]
    call aac_twiddles
    lea rcx, [rip + aac_post_short]
    mov edx, 64
    mov r8d, 128
    xorpd xmm2, xmm2
    movsd xmm3, [rip + aac_one]
    call aac_twiddles
    lea rcx, [rip + aac_fft_tw]           # exp(-i pi j / 256)
    mov edx, 256
    mov r8d, 256
    xorpd xmm2, xmm2
    movsd xmm3, [rip + aac_one]
    call aac_twiddles
    # Bit reversal of 9 and 6 bits.
    lea rdi, [rip + aac_rev512]
    mov ebx, 9
    call aac_reverse_table
    lea rdi, [rip + aac_rev64]
    mov ebx, 6
    call aac_reverse_table
    mov dword ptr [rip + aac_tables_ready], 1
.Laac_init_done:
    movdqu xmm6, [rsp + 32]
    movdqu xmm7, [rsp + 48]
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_init_tables

# RDI=floats, EBX=half length n: sin(pi (i + 1/2) / (2n)), i < n.
LOCALFN aac_sine_window
    push rsi
    sub rsp, 32
    xor esi, esi
.Laac_sine_value:
    cvtsi2sd xmm0, esi
    addsd xmm0, [rip + aac_half]
    lea eax, [rbx*2]
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    call sin_pi
    cvtsd2ss xmm0, xmm0
    movss [rdi + rsi*4], xmm0
    inc esi
    cmp esi, ebx
    jb .Laac_sine_value
    add rsp, 32
    pop rsi
    ret
ENDFN aac_sine_window

# RCX=floats, EDX=half length n, R8D=alpha: Kaiser-Bessel-derived rising half,
# sqrt(sum_{j<=i} I0(2 pi alpha sqrt(j (n - j)) / n) / (sum_{j<=n} ...)).
LOCALFN aac_kbd_window
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rcx
    mov ebx, edx
    mov rsi, [rip + aac_memory]
    add rsi, AM_BUF                       # running sums (doubles)
    cvtsi2sd xmm4, r8d
    mulsd xmm4, [rip + aac_pi]
    cvtsi2sd xmm5, ebx
    divsd xmm4, xmm5
    mulsd xmm4, xmm4                      # (alpha pi / n)^2
    xorpd xmm5, xmm5                      # sum
    xor ecx, ecx
.Laac_kbd_term:
    mov eax, ebx
    sub eax, ecx
    imul eax, ecx
    cvtsi2sd xmm0, eax
    mulsd xmm0, xmm4                      # (x/2)^2 for I0(x)
    movsd xmm1, [rip + aac_one]           # 50-term series, innermost first
    mov edx, 50
.Laac_kbd_series:
    mulsd xmm1, xmm0
    mov eax, edx
    imul eax, edx
    cvtsi2sd xmm2, eax
    divsd xmm1, xmm2
    addsd xmm1, [rip + aac_one]
    dec edx
    jnz .Laac_kbd_series
    addsd xmm5, xmm1
    movsd [rsi + rcx*8], xmm5
    inc ecx
    cmp ecx, ebx
    jb .Laac_kbd_term
    addsd xmm5, [rip + aac_one]           # j = n: I0(0)
    xor ecx, ecx
.Laac_kbd_value:
    movsd xmm0, [rsi + rcx*8]
    divsd xmm0, xmm5
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    movss [rdi + rcx*4], xmm0
    inc ecx
    cmp ecx, ebx
    jb .Laac_kbd_value
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_kbd_window

# RCX=table, EDX=entries, R8D=M, XMM2=phase offset, XMM3=scale: entry i is
# s exp(-i pi (i + offset) / M) as (wr, wr), (-wi, wi).
LOCALFN aac_twiddles
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    movdqu [rsp + 32], xmm6
    movdqu [rsp + 48], xmm7
    mov rdi, rcx
    mov ebx, edx
    mov esi, r8d
    movapd xmm6, xmm2
    movapd xmm7, xmm3
    xor eax, eax
.Laac_twiddle_value:
    cmp eax, ebx
    jae .Laac_twiddle_done
    push rax
    sub rsp, 8
    cvtsi2sd xmm0, eax
    addsd xmm0, xmm6
    cvtsi2sd xmm1, esi
    divsd xmm0, xmm1                      # theta / pi
    movsd [rsp], xmm0
    call sin_pi
    mulsd xmm0, xmm7
    movsd xmm2, xmm0                      # s sin
    movsd xmm0, [rsp]
    addsd xmm0, [rip + aac_half]
    movsd [rsp], xmm2
    call sin_pi
    mulsd xmm0, xmm7                      # s cos
    movsd xmm2, [rsp]
    add rsp, 8
    pop rax
    mov ecx, eax
    shl ecx, 5
    movsd [rdi + rcx], xmm0
    movsd [rdi + rcx + 8], xmm0           # (wr, wr)
    movsd [rdi + rcx + 16], xmm2          # -wi = s sin
    xorpd xmm2, [rip + aac_sign_low]
    movsd [rdi + rcx + 24], xmm2          # wi = -s sin
    inc eax
    jmp .Laac_twiddle_value
.Laac_twiddle_done:
    movdqu xmm6, [rsp + 32]
    movdqu xmm7, [rsp + 48]
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_twiddles

# RDI=16-bit table, EBX=bits: entry i is i with its EBX low bits reversed.
LOCALFN aac_reverse_table
    mov r10d, 1
    mov ecx, ebx
    shl r10d, cl                          # entries
    xor ecx, ecx
.Laac_reverse_value:
    xor eax, eax
    mov edx, ecx
    mov r8d, ebx
.Laac_reverse_bit:
    shl eax, 1
    mov r9d, edx
    and r9d, 1
    or eax, r9d
    shr edx, 1
    dec r8d
    jnz .Laac_reverse_bit
    mov [rdi + rcx*2], ax
    inc ecx
    cmp ecx, r10d
    jb .Laac_reverse_value
    ret
ENDFN aac_reverse_table

# ADTS (.aac) streams: an optional leading ID3v2 tag, then ADTS frames with
# identical fixed headers and one raw data block each, optionally followed
# by a 128-byte ID3v1 tag. The CRC, when present, is skipped unchecked.

# RCX=data, RDX=end -> RAX=data after a leading ID3v2 tag (or RCX).
LOCALFN adts_skip_id3
    mov rax, rcx
    lea r8, [rcx + 10]
    cmp r8, rdx
    ja .Ladts_id3_none
    mov r8d, [rcx]
    and r8d, 0xffffff
    cmp r8d, 0x334449                     # "ID3"
    jne .Ladts_id3_none
    xor r8d, r8d                          # syncsafe size
    mov r9d, 6
.Ladts_id3_size:
    movzx r10d, byte ptr [rcx + r9]
    test r10d, 0x80
    jnz .Ladts_id3_none
    shl r8d, 7
    or r8d, r10d
    inc r9d
    cmp r9d, 10
    jb .Ladts_id3_size
    add r8, 10
    test byte ptr [rcx + 5], 0x10         # footer
    jz .Ladts_id3_end
    add r8, 10
.Ladts_id3_end:
    lea r9, [rcx + r8]
    cmp r9, rdx
    ja .Ladts_id3_none
    mov rax, r9
.Ladts_id3_none:
    ret
ENDFN adts_skip_id3

# RCX=header, RDX=end -> EAX=frame bytes (0 when invalid), ECX=header bytes,
# EDX=profile/frequency/channel key of the fixed header.
LOCALFN adts_header
    xor eax, eax
    lea r8, [rcx + 7]
    cmp r8, rdx
    ja .Ladts_header_return
    cmp byte ptr [rcx], 0xff
    jne .Ladts_header_return
    movzx r8d, byte ptr [rcx + 1]
    mov r9d, r8d
    and r9d, 0xf6                         # sync and layer 0
    cmp r9d, 0xf0
    jne .Ladts_header_return
    mov r9d, 9                            # with CRC
    test r8d, 1
    jz .Ladts_header_size
    mov r9d, 7
.Ladts_header_size:
    test byte ptr [rcx + 6], 3            # one raw data block per frame
    jnz .Ladts_header_return
    movzx r10d, byte ptr [rcx + 3]
    movzx r11d, byte ptr [rcx + 4]
    mov eax, r10d
    and eax, 3
    shl eax, 8
    or eax, r11d
    shl eax, 3
    movzx r11d, byte ptr [rcx + 5]
    shr r11d, 5
    or eax, r11d                          # frame length
    cmp eax, r9d
    jbe .Ladts_header_bad
    lea r11, [rcx + rax]
    cmp r11, rdx
    ja .Ladts_header_bad
    movzx edx, byte ptr [rcx + 2]
    and edx, 0xfd                         # profile, frequency, high channel bit
    shl edx, 8
    and r10d, 0xc0                        # low channel bits
    or edx, r10d
    mov ecx, r9d
    ret
.Ladts_header_bad:
    xor eax, eax
.Ladts_header_return:
    ret
ENDFN adts_header

# RCX=mapped start, RDX=end -> EAX=1 when the data begins with an ADTS frame
# followed by another with the same fixed header, an ID3v1 tag or the end.
FN adts_probe
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    mov rcx, rsi
    mov rdx, rdi
    call adts_header
    test eax, eax
    jz .Ladts_probe_return
    mov ebx, edx
    add rsi, rax
    mov eax, 1
    cmp rsi, rdi
    je .Ladts_probe_return
    mov rcx, rdi
    sub rcx, rsi
    cmp rcx, 128
    jne .Ladts_probe_next
    cmp word ptr [rsi], 0x4154            # "TA"
    jne .Ladts_probe_next
    cmp byte ptr [rsi + 2], 'G'
    je .Ladts_probe_return
.Ladts_probe_next:
    # The next header only: a truncated frame still identifies the stream.
    xor eax, eax
    lea rcx, [rsi + 7]
    cmp rcx, rdi
    ja .Ladts_probe_return
    mov rcx, rsi
    lea rdx, [rsi + 8192]
    call adts_header
    test eax, eax
    jz .Ladts_probe_return
    xor eax, eax
    cmp edx, ebx
    sete al
.Ladts_probe_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN adts_probe

# RCX=mapped start, RDX=end -> EAX=1 with every frame listed as a track
# packet and the decoder opened.
FN adts_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    mov rcx, rsi
    mov rdx, rdi
    call adts_header
    test eax, eax
    jz .Ladts_open_bad
    mov r12d, edx                         # fixed header key
    # AudioSpecificConfig: object type = profile + 1, frequency, channels.
    movzx eax, byte ptr [rsi + 2]
    mov ecx, eax
    shr ecx, 6
    inc ecx
    shl ecx, 11                           # object type
    mov edx, eax
    and edx, 0x3c
    shl edx, 5                            # frequency index << 7
    or ecx, edx
    and eax, 1
    shl eax, 2
    movzx edx, byte ptr [rsi + 3]
    shr edx, 6
    or eax, edx
    shl eax, 3                            # channel configuration << 3
    or ecx, eax
    xchg cl, ch
    mov [rip + adts_config], cx
    mov ecx, 7                            # TK_AAC
    call track_begin
    test eax, eax
    jz .Ladts_open_bad
.Ladts_open_frame:
    cmp rsi, rdi
    jae .Ladts_open_frames_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Ladts_open_continue
    cmp dword ptr [rax], 0
    jne .Ladts_open_bad
.Ladts_open_continue:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 128
    jne .Ladts_open_header
    cmp word ptr [rsi], 0x4154            # trailing ID3v1 "TAG"
    jne .Ladts_open_header
    cmp byte ptr [rsi + 2], 'G'
    je .Ladts_open_frames_done
.Ladts_open_header:
    mov rcx, rsi
    mov rdx, rdi
    call adts_header
    test eax, eax
    jz .Ladts_open_bad
    cmp edx, r12d
    jne .Ladts_open_bad
    mov ebx, eax
    lea rax, [rsi + rcx]
    mov edx, ebx
    sub edx, ecx
    mov rcx, rax
    call track_add
    test eax, eax
    jz .Ladts_open_bad
    add rsi, rbx
    jmp .Ladts_open_frame
.Ladts_open_frames_done:
    lea rax, [rip + adts_config]
    mov [rip + track_config], rax
    mov dword ptr [rip + track_config_bytes], 2
    call track_finish
    test eax, eax
    jz .Ladts_open_bad
    mov dword ptr [rip + codec_kind], 10
    mov eax, 1
    jmp .Ladts_open_return
.Ladts_open_bad:
    call track_close
    cmp dword ptr [rip + decode_error], 0
    jne .Ladts_open_failed
    mov dword ptr [rip + decode_error], AAC_MALFORMED
.Ladts_open_failed:
    xor eax, eax
.Ladts_open_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN adts_open

.include "aac_sbr.inc"
