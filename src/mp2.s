# Handwritten x86-64 MPEG audio Layer I and Layer II decoding. MIT, see LICENSE.
# References: ISO/IEC 11172-3 and 13818-3 (lower sampling frequencies).
# Allocation-table layout and dequantization constants follow minimp3/dr_mp3
# (CC0/MIT-0), see THIRD_PARTY_NOTICES. Framing, indexing, seeking and the
# polyphase synthesis filterbank are shared with Layer III in mp3.s.
.include "lamp.inc"
.globl l12_bands, l12_stereo_bands

RODATA
# Allocation code -> quantizer: 0 none, 2..16 sample bits, 17/18/19 three
# grouped samples of 3/5/9 levels.
l12_code_tab:
    .byte 0, 17, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
    .byte 0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16
    .byte 0, 17, 18, 3, 19, 4, 5, 16
    .byte 0, 17, 18, 16
    .byte 0, 17, 18, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    .byte 0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
    .byte 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
# Rows of (code table offset, allocation bits, subbands).
l12_alloc_l1: .byte 76, 4, 32
l12_alloc_l2m2: .byte 60, 4, 4, 44, 3, 7, 44, 2, 19
l12_alloc_l2m1: .byte 0, 4, 3, 16, 4, 8, 32, 3, 12, 40, 2, 7
l12_alloc_low: .byte 44, 4, 2, 44, 3, 10
.p2align 2
# 2^-20 * 2^(-i/3) / (quantizer levels - 1 or levels), i = 0..2, for each
# allocation 2..19; the scalefactor index adds 2^(21 - index/3).
l12_dequant:
    .long 0x34aaaaab, 0x3487754e, 0x345706cb, 0x34124925, 0x33e836cf, 0x33b84ef7
    .long 0x33888889, 0x3358bbb0, 0x332c056f, 0x33042108, 0x32d1bde4, 0x32a678df
    .long 0x32820821, 0x324e699b, 0x3223d46a, 0x32010204, 0x31ccc988, 0x31a28a2c
    .long 0x31808081, 0x314bfbf1, 0x3121e6ff, 0x31004020, 0x30cb95c0, 0x30a195e3
    .long 0x30802008, 0x304b62ce, 0x30216d73, 0x30001002, 0x2fcb495e, 0x2fa15943
    .long 0x2f800801, 0x2f4b3ca9, 0x2f214f2d, 0x2f000400, 0x2ecb364f, 0x2ea14a22
    .long 0x2e800200, 0x2e4b3322, 0x2e21479d, 0x2e000100, 0x2dcb318b, 0x2da1465b
    .long 0x2d800080, 0x2d4b30c0, 0x2d2145b9, 0x34aaaaab, 0x3487754e, 0x345706cb
    .long 0x344ccccd, 0x34228cc4, 0x34010413, 0x33e38e39, 0x33b49c68, 0x338f59dc

.data
l12_bands: .long 0
l12_stereo_bands: .long 0
.bss
l12_alloc: .zero 64                 # (subband, channel) quantizer
l12_scfcod: .zero 64
.p2align 4
l12_scf: .zero 64*3*4               # (subband, channel) x three parts

.text
# After mp_parse_header for a Layer I/II frame: reads the bit allocation,
# scalefactor selection and scalefactors, and checks the CRC when present.
# EAX=1 when valid. Leaves the bit reader at the first sample.
FN mp_l12_scale_info
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rax, [rip + mp_frame_end]
    mov ecx, [rip + mp_frame_bytes]
    sub rax, rcx
    mov r15, rax                        # frame start
    mov edx, [rip + mp_crc_bytes]
    lea rax, [r15 + rdx + 4]
    mov [rip + mp_bit_base], rax
    sub ecx, 4
    sub ecx, edx
    shl ecx, 3
    mov [rip + mp_bit_limit], ecx
    mov dword ptr [rip + mp_bit_pos], 0
    # Stereo bands: none for mono, the intensity bound for joint stereo.
    mov ebx, [rip + mp_header]
    mov eax, ebx
    shr eax, 6
    and eax, 3
    mov r12d, 32
    cmp eax, 3
    jne .Ll12_not_mono
    xor r12d, r12d
.Ll12_not_mono:
    cmp eax, 1
    jne .Ll12_bound_ready
    mov r12d, ebx
    shr r12d, 4
    and r12d, 3
    lea r12d, [r12*4 + 4]
.Ll12_bound_ready:
    lea r13, [rip + l12_alloc_l1]
    mov r14d, 32
    cmp dword ptr [rip + mp_layer], 1
    je .Ll12_table_ready
    lea r13, [rip + l12_alloc_l2m2]
    mov r14d, 30
    cmp dword ptr [rip + mp_version], 3
    jne .Ll12_table_ready
    lea r13, [rip + l12_alloc_l2m1]
    mov r14d, 27
    mov ecx, [rip + mp_kbps]           # bitrate per channel selects the table
    cmp eax, 3
    je .Ll12_per_channel
    shr ecx, 1
.Ll12_per_channel:
    mov edx, ebx
    shr edx, 10
    and edx, 3                          # 0 44.1 kHz, 1 48 kHz, 2 32 kHz
    cmp ecx, 56
    jae .Ll12_not_low
    lea r13, [rip + l12_alloc_low]
    mov r14d, 8
    cmp edx, 2
    jne .Ll12_table_ready
    mov r14d, 12
    jmp .Ll12_table_ready
.Ll12_not_low:
    cmp ecx, 96
    jb .Ll12_table_ready
    cmp edx, 1
    je .Ll12_table_ready
    mov r14d, 30
.Ll12_table_ready:
    cmp r12d, r14d
    cmova r12d, r14d
    mov [rip + l12_bands], r14d
    mov [rip + l12_stereo_bands], r12d
    # Allocation: both channels below the bound, then one shared code.
    xor ebx, ebx                        # subband
    xor esi, esi                        # next table row starts here
    xor edi, edi                        # code bits
    lea rax, [rip + l12_code_tab]
    mov [rsp + 32], rax
.Ll12_alloc_band:
    cmp ebx, r14d
    jae .Ll12_alloc_done
    cmp ebx, esi
    jne .Ll12_alloc_read
    movzx eax, byte ptr [r13]
    lea rcx, [rip + l12_code_tab]
    add rax, rcx
    mov [rsp + 32], rax
    movzx edi, byte ptr [r13 + 1]
    movzx eax, byte ptr [r13 + 2]
    add esi, eax
    add r13, 3
.Ll12_alloc_read:
    mov ecx, edi
    call mp_bits
    mov rcx, [rsp + 32]
    movzx eax, byte ptr [rcx + rax]
    lea rdx, [rip + l12_alloc]
    mov [rdx + rbx*2], al
    cmp ebx, r12d
    jae .Ll12_alloc_shared
    mov ecx, edi
    call mp_bits
    mov rcx, [rsp + 32]
    movzx eax, byte ptr [rcx + rax]
.Ll12_alloc_shared:
    test r12d, r12d
    jnz .Ll12_alloc_second
    xor eax, eax
.Ll12_alloc_second:
    lea rdx, [rip + l12_alloc]
    mov [rdx + rbx*2 + 1], al
    inc ebx
    jmp .Ll12_alloc_band
.Ll12_alloc_done:
    # Scalefactor selection: Layer I always one; Layer II two bits.
    xor ebx, ebx
.Ll12_scfsi:
    lea eax, [r14 + r14]
    cmp ebx, eax
    jae .Ll12_scfsi_done
    lea rdx, [rip + l12_alloc]
    mov eax, 6
    cmp byte ptr [rdx + rbx], 0
    je .Ll12_scfsi_store
    mov eax, 2
    cmp dword ptr [rip + mp_layer], 1
    je .Ll12_scfsi_store
    mov ecx, 2
    call mp_bits
.Ll12_scfsi_store:
    lea rdx, [rip + l12_scfcod]
    mov [rdx + rbx], al
    inc ebx
    jmp .Ll12_scfsi
.Ll12_scfsi_done:
    cmp dword ptr [rip + decode_error], 0
    jne .Ll12_scale_bad
    cmp dword ptr [rip + mp_crc_bytes], 0
    je .Ll12_scalefactors
    # CRC-16 (x^16+x^15+x^2+1, initial FFFF) over header bits 16..31 and the
    # allocation and selection bits, MSB first.
    mov eax, 0xffff
    lea r8, [r15 + 2]
    mov r9d, 16
    call l12_crc_bits
    mov r8, [rip + mp_bit_base]
    mov r9d, [rip + mp_bit_pos]
    call l12_crc_bits
    movzx edx, word ptr [r15 + 4]
    rol dx, 8
    cmp eax, edx
    jne .Ll12_scale_bad
.Ll12_scalefactors:
    xor ebx, ebx                        # (subband, channel)
.Ll12_scf_entry:
    lea eax, [r14 + r14]
    cmp ebx, eax
    jae .Ll12_scf_done
    lea rdx, [rip + l12_alloc]
    movzx esi, byte ptr [rdx + rbx]     # quantizer
    xor edi, edi                        # mask of parts read: 4, 2, 1
    test esi, esi
    jz .Ll12_scf_mask
    lea rdx, [rip + l12_scfcod]
    movzx ecx, byte ptr [rdx + rbx]
    mov edi, 19
    shr edi, cl
    and edi, 3
    add edi, 4
.Ll12_scf_mask:
    xorps xmm0, xmm0
    movss [rsp + 40], xmm0
    mov r13d, 4
    xor r12d, r12d                      # part
.Ll12_scf_part:
    test edi, r13d
    jz .Ll12_scf_store
    mov ecx, 6
    call mp_bits
    xor edx, edx
    mov ecx, 3
    div ecx                             # EAX=index/3, EDX=index%3
    lea ecx, [rsi + rsi*2 - 6]
    add ecx, edx
    lea rdx, [rip + l12_dequant]
    movss xmm0, [rdx + rcx*4]
    mov ecx, eax
    mov eax, 1 << 21
    shr eax, cl
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm1
    movss [rsp + 40], xmm0
.Ll12_scf_store:
    movss xmm0, [rsp + 40]
    lea eax, [rbx + rbx*2]
    add eax, r12d
    lea rdx, [rip + l12_scf]
    movss [rdx + rax*4], xmm0
    inc r12d
    shr r13d, 1
    jnz .Ll12_scf_part
    inc ebx
    jmp .Ll12_scf_entry
.Ll12_scf_done:
    # Above the bound the second channel shares the first channel's samples.
    mov ebx, [rip + l12_stereo_bands]
    lea rdx, [rip + l12_alloc]
.Ll12_shared_clear:
    cmp ebx, r14d
    jae .Ll12_shared_done
    mov byte ptr [rdx + rbx*2 + 1], 0
    inc ebx
    jmp .Ll12_shared_clear
.Ll12_shared_done:
    cmp dword ptr [rip + decode_error], 0
    jne .Ll12_scale_bad
    mov eax, 1
    jmp .Ll12_scale_return
.Ll12_scale_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Ll12_scale_failed
    mov dword ptr [rip + decode_error], 16
.Ll12_scale_failed:
    xor eax, eax
.Ll12_scale_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp_l12_scale_info

# EAX=CRC state, R8=bytes, R9D=bit count -> EAX=updated CRC (16 bits).
LOCALFN l12_crc_bits
    test r9d, r9d
    jz .Ll12_crc_done
    xor r10d, r10d                      # bit index
.Ll12_crc_bit:
    mov ecx, r10d
    shr ecx, 3
    movzx edx, byte ptr [r8 + rcx]
    mov ecx, r10d
    and ecx, 7
    shl edx, cl
    shr edx, 7
    and edx, 1                          # next message bit
    mov ecx, eax
    shr ecx, 15
    xor edx, ecx
    shl eax, 1
    and eax, 0xffff
    test edx, edx
    jz .Ll12_crc_next
    xor eax, 0x8005
.Ll12_crc_next:
    inc r10d
    cmp r10d, r9d
    jb .Ll12_crc_bit
.Ll12_crc_done:
    ret
ENDFN l12_crc_bits

# Decodes the current Layer I/II frame into mp_pcm: 384 or 1152 stereo
# frames. EAX=1 on success.
FN mp_l12_frame
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    call mp_l12_scale_info
    test eax, eax
    jz .Ll12_frame_bad
    xor r15d, r15d                      # part
.Ll12_part:
    lea rdi, [rip + mp_grbuf]
    xor eax, eax
    mov ecx, 1152
    rep stosd
    # Layer I: twelve groups of one sample; Layer II: four groups of three.
    mov dword ptr [rsp + 32], 1
    mov dword ptr [rsp + 36], 12
    cmp dword ptr [rip + mp_layer], 1
    je .Ll12_group_shape
    mov dword ptr [rsp + 32], 3
    mov dword ptr [rsp + 36], 4
.Ll12_group_shape:
    xor r14d, r14d                      # group
.Ll12_group:
    cmp r14d, [rsp + 36]
    jae .Ll12_scale
    xor ebx, ebx                        # (subband, channel)
.Ll12_entry:
    mov eax, [rip + l12_bands]
    add eax, eax
    cmp ebx, eax
    jae .Ll12_group_next
    lea rdx, [rip + l12_alloc]
    movzx esi, byte ptr [rdx + rbx]
    test esi, esi
    jz .Ll12_entry_next
    # Destination: channel*576 + subband*18 + first slot of this group.
    mov eax, ebx
    and eax, 1
    imul eax, eax, 576
    mov ecx, ebx
    shr ecx, 1
    imul ecx, ecx, 18
    add eax, ecx
    mov ecx, r14d
    imul ecx, [rsp + 32]
    add eax, ecx
    lea rdi, [rip + mp_grbuf]
    lea rdi, [rdi + rax*4]
    cmp esi, 17
    jae .Ll12_grouped
    mov ecx, esi
    dec ecx
    mov r12d, 1
    shl r12d, cl
    dec r12d                            # midpoint
    xor r13d, r13d
.Ll12_plain:
    mov ecx, esi
    call mp_bits
    sub eax, r12d
    cvtsi2ss xmm0, eax
    movss [rdi + r13*4], xmm0
    inc r13d
    cmp r13d, [rsp + 32]
    jb .Ll12_plain
    jmp .Ll12_entry_next
.Ll12_grouped:
    # Three samples in one code word: 3, 5 or 9 levels in 5, 7 or 10 bits.
    lea ecx, [rsi - 17]
    mov r12d, 2
    shl r12d, cl
    inc r12d                            # levels
    mov ecx, r12d
    shr ecx, 3
    neg ecx
    lea ecx, [r12 + rcx + 2]
    call mp_bits
    mov r13d, r12d
    shr r13d, 1                         # midpoint
    xor ecx, ecx
.Ll12_grouped_sample:
    xor edx, edx
    div r12d
    mov r8d, edx
    sub r8d, r13d
    cvtsi2ss xmm0, r8d
    movss [rdi + rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jb .Ll12_grouped_sample
.Ll12_entry_next:
    inc ebx
    jmp .Ll12_entry
.Ll12_group_next:
    inc r14d
    jmp .Ll12_group
.Ll12_scale:
    cmp dword ptr [rip + decode_error], 0
    jne .Ll12_frame_bad
    # Shared subbands copy their samples to the second channel, then each
    # channel takes its own scalefactor for this part.
    xor ebx, ebx
.Ll12_scale_band:
    cmp ebx, [rip + l12_bands]
    jae .Ll12_synthesize
    lea rsi, [rip + mp_grbuf]
    imul eax, ebx, 18*4
    add rsi, rax
    cmp ebx, [rip + l12_stereo_bands]
    jb .Ll12_scale_own
    cmp dword ptr [rip + mp_channels], 2
    jne .Ll12_scale_own
    xor ecx, ecx
.Ll12_scale_copy:
    mov eax, [rsi + rcx*4]
    mov [rsi + rcx*4 + 576*4], eax
    inc ecx
    cmp ecx, 12
    jb .Ll12_scale_copy
.Ll12_scale_own:
    lea eax, [rbx*2]
    lea eax, [rax + rax*2]
    add eax, r15d
    lea rdx, [rip + l12_scf]
    movss xmm1, [rdx + rax*4]           # channel 0, this part
    movss xmm2, [rdx + rax*4 + 12]      # channel 1
    shufps xmm1, xmm1, 0
    shufps xmm2, xmm2, 0
    movups xmm0, [rsi]
    mulps xmm0, xmm1
    movups [rsi], xmm0
    movups xmm0, [rsi + 16]
    mulps xmm0, xmm1
    movups [rsi + 16], xmm0
    movups xmm0, [rsi + 32]
    mulps xmm0, xmm1
    movups [rsi + 32], xmm0
    movups xmm0, [rsi + 576*4]
    mulps xmm0, xmm2
    movups [rsi + 576*4], xmm0
    movups xmm0, [rsi + 576*4 + 16]
    mulps xmm0, xmm2
    movups [rsi + 576*4 + 16], xmm0
    movups xmm0, [rsi + 576*4 + 32]
    mulps xmm0, xmm2
    movups [rsi + 576*4 + 32], xmm0
    inc ebx
    jmp .Ll12_scale_band
.Ll12_synthesize:
    imul eax, r15d, 384*8
    lea rcx, [rip + mp_pcm]
    add rcx, rax
    mov edx, [rip + mp_channels]
    mov r8d, 12
    call mp_synthesis
    inc r15d
    cmp dword ptr [rip + mp_layer], 1
    je .Ll12_frame_done
    cmp r15d, 3
    jb .Ll12_part
.Ll12_frame_done:
    mov eax, 1
    jmp .Ll12_frame_return
.Ll12_frame_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Ll12_frame_failed
    mov dword ptr [rip + decode_error], 16
.Ll12_frame_failed:
    xor eax, eax
.Ll12_frame_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN mp_l12_frame
