# Original AIFF/AIFC PCM/IEEE parser and ordered Core Audio speaker mixing.
# Included in decoder.asm; shares its bounded mapped-input PCM reader. MIT.
.data
aiff_kind: .long 0
aiff_forced_bits: .long 0
aiff_comm: .quad 0
aiff_sound: .quad 0
aiff_sound_end: .quad 0
aiff_chan: .quad 0
aiff_chan_size: .quad 0
aiff_version_seen: .long 0
aiff_order: .fill 8, 1, 255
# Default AIFF conventions: 4-channel L C R Cs; 6-channel L Lc C R Rc Cs.
# Other untagged counts use the documented conventional speaker fallback.
aiff_defaults: .byte 2, 255, 255, 255, 255, 255, 255, 255
 .byte 0, 1, 255, 255, 255, 255, 255, 255
 .byte 0, 1, 2, 255, 255, 255, 255, 255
 .byte 0, 2, 1, 8, 255, 255, 255, 255
 .byte 0, 1, 2, 4, 5, 255, 255, 255
 .byte 0, 6, 2, 1, 7, 8, 255, 255
 .byte 0, 1, 2, 3, 4, 5, 8, 255
 .byte 0, 1, 2, 3, 4, 5, 9, 10
# Each record is a high tag word, count, reserved byte and eight ordered
# zero-based WAVE speaker positions. These are format constants, not code.
aiff_tags:
 .short 100
 .byte 1, 0, 2, 255, 255, 255, 255, 255, 255, 255
 .short 101
 .byte 2, 0, 0, 1, 255, 255, 255, 255, 255, 255
 .short 102
 .byte 2, 0, 0, 1, 255, 255, 255, 255, 255, 255
 .short 103
 .byte 2, 0, 0, 1, 255, 255, 255, 255, 255, 255
 .short 105
 .byte 2, 0, 0, 1, 255, 255, 255, 255, 255, 255
 .short 106
 .byte 2, 0, 0, 1, 255, 255, 255, 255, 255, 255
 .short 108
 .byte 4, 0, 0, 1, 4, 5, 255, 255, 255, 255
 .short 109
 .byte 5, 0, 0, 1, 4, 5, 2, 255, 255, 255
 .short 110
 .byte 6, 0, 0, 1, 4, 5, 2, 8, 255, 255
 .short 111
 .byte 8, 0, 0, 1, 4, 5, 2, 8, 9, 10
 .short 112
 .byte 8, 0, 0, 1, 4, 5, 12, 14, 15, 17
 .short 113
 .byte 3, 0, 0, 1, 2, 255, 255, 255, 255, 255
 .short 114
 .byte 3, 0, 2, 0, 1, 255, 255, 255, 255, 255
 .short 115
 .byte 4, 0, 0, 1, 2, 8, 255, 255, 255, 255
 .short 116
 .byte 4, 0, 2, 0, 1, 8, 255, 255, 255, 255
 .short 117
 .byte 5, 0, 0, 1, 2, 4, 5, 255, 255, 255
 .short 118
 .byte 5, 0, 0, 1, 4, 5, 2, 255, 255, 255
 .short 119
 .byte 5, 0, 0, 2, 1, 4, 5, 255, 255, 255
 .short 120
 .byte 5, 0, 2, 0, 1, 4, 5, 255, 255, 255
 .short 121
 .byte 6, 0, 0, 1, 2, 3, 4, 5, 255, 255
 .short 122
 .byte 6, 0, 0, 1, 4, 5, 2, 3, 255, 255
 .short 123
 .byte 6, 0, 0, 2, 1, 4, 5, 3, 255, 255
 .short 124
 .byte 6, 0, 2, 0, 1, 4, 5, 3, 255, 255
 .short 125
 .byte 7, 0, 0, 1, 2, 3, 4, 5, 8, 255
 .short 126
 .byte 8, 0, 0, 1, 2, 3, 4, 5, 6, 7
 .short 127
 .byte 8, 0, 2, 6, 7, 0, 1, 4, 5, 3
 .short 128
 .byte 8, 0, 0, 1, 2, 3, 9, 10, 4, 5
 .short 129
 .byte 8, 0, 0, 1, 4, 5, 2, 3, 6, 7
 .short 130
 .byte 8, 0, 0, 1, 2, 3, 4, 5, 0, 1
 .short 131
 .byte 3, 0, 0, 1, 8, 255, 255, 255, 255, 255
 .short 132
 .byte 4, 0, 0, 1, 4, 5, 255, 255, 255, 255
 .short 133
 .byte 3, 0, 0, 1, 3, 255, 255, 255, 255, 255
 .short 134
 .byte 4, 0, 0, 1, 3, 8, 255, 255, 255, 255
 .short 135
 .byte 5, 0, 0, 1, 3, 4, 5, 255, 255, 255
 .short 136
 .byte 4, 0, 0, 1, 2, 3, 255, 255, 255, 255
 .short 137
 .byte 5, 0, 0, 1, 2, 3, 8, 255, 255, 255
 .short 138
 .byte 5, 0, 0, 1, 4, 5, 3, 255, 255, 255
 .short 139
 .byte 6, 0, 0, 1, 4, 5, 2, 8, 255, 255
 .short 140
 .byte 7, 0, 0, 1, 4, 5, 2, 4, 5, 255
 .short 141
 .byte 6, 0, 2, 0, 1, 4, 5, 8, 255, 255
 .short 142
 .byte 7, 0, 2, 0, 1, 4, 5, 8, 3, 255
 .short 143
 .byte 7, 0, 2, 0, 1, 4, 5, 4, 5, 255
 .short 144
 .byte 8, 0, 2, 0, 1, 4, 5, 4, 5, 8
 .short 0
.text
# RCX=FORM base, RDX=mapped end. No allocation, no input writes.
LOCALFN aiff_open
    sub rsp, 40
    mov qword ptr [rip + aiff_comm], 0
    mov qword ptr [rip + aiff_sound], 0
    mov qword ptr [rip + aiff_sound_end], 0
    mov qword ptr [rip + aiff_chan], 0
    mov dword ptr [rip + aiff_version_seen], 0
    mov dword ptr [rip + aiff_kind], 0
    mov dword ptr [rip + aiff_forced_bits], 0
    mov dword ptr [rip + pcm_big_endian], 1
    mov dword ptr [rip + pcm_signed8], 1
    mov dword ptr [rip + wav_format], 1
    cmp dword ptr [rcx + 8], 0x46464941 # AIFF
    je .Laiff_form_type
    cmp dword ptr [rcx + 8], 0x43464941 # AIFC
    jne .Laiff_bad
    mov dword ptr [rip + aiff_kind], 1
.Laiff_form_type:
    mov eax, [rcx + 4]
    bswap eax
    cmp eax, 4
    jb .Laiff_bad
    add rax, 8
    add rax, rcx
    jc .Laiff_bad
    cmp rax, rdx
    ja .Laiff_bad
    mov [rip + input_end], rax
    lea r10, [rcx + 12]
.Laiff_chunks:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Laiff_not_cancelled
    cmp dword ptr [rax], 0
    jne .Laiff_bad
.Laiff_not_cancelled:
    cmp r10, [rip + input_end]
    je .Laiff_complete
    lea rax, [r10 + 8]
    cmp rax, r10
    jb .Laiff_bad
    cmp rax, [rip + input_end]
    ja .Laiff_bad
    mov edx, [r10 + 4]
    bswap edx
    mov r8, rax
    add r8, rdx
    jc .Laiff_bad
    cmp r8, [rip + input_end]
    ja .Laiff_bad
    cmp dword ptr [r10], 0x4d4d4f43 # COMM
    je .Laiff_read_comm
    cmp dword ptr [r10], 0x444e5353 # SSND
    je .Laiff_read_sound
    cmp dword ptr [r10], 0x4e414843 # CHAN
    je .Laiff_read_chan
    cmp dword ptr [r10], 0x52455646 # FVER
    je .Laiff_read_version
.Laiff_next:
    add r8, 1
    jc .Laiff_bad
    and r8, -2
    cmp r8, [rip + input_end]
    ja .Laiff_bad
    mov r10, r8
    jmp .Laiff_chunks
.Laiff_read_comm:
    cmp qword ptr [rip + aiff_comm], 0
    jne .Laiff_bad
    cmp edx, 18
    jb .Laiff_bad
    mov [rip + aiff_comm], rax
    cmp dword ptr [rip + aiff_kind], 0
    je .Laiff_next
    cmp edx, 23
    jb .Laiff_bad
    movzx ecx, byte ptr [rax + 22]
    add ecx, 2
    and ecx, -2
    add ecx, 22
    cmp ecx, edx
    ja .Laiff_bad
    mov ecx, [rax + 18]
    cmp ecx, 0x454e4f4e # NONE
    je .Laiff_next
    cmp ecx, 0x736f7774 # twos
    je .Laiff_next
    cmp ecx, 0x74776f73 # sowt
    jne .Laiff_try_fixed_container
    mov dword ptr [rip + pcm_big_endian], 0
    jmp .Laiff_next
.Laiff_try_fixed_container:
    cmp ecx, 0x34326e69 # in24
    je .Laiff_fixed24
    cmp ecx, 0x32336e69 # in32
    je .Laiff_fixed32
    cmp ecx, 0x20776172 # raw (unsigned 8-bit)
    jne .Laiff_try_float
    mov dword ptr [rip + aiff_forced_bits], 8
    mov dword ptr [rip + pcm_signed8], 0
    jmp .Laiff_next
.Laiff_fixed24:
    mov dword ptr [rip + aiff_forced_bits], 24
    jmp .Laiff_next
.Laiff_fixed32:
    mov dword ptr [rip + aiff_forced_bits], 32
    jmp .Laiff_next
.Laiff_try_float:
    cmp ecx, 0x32336c66 # fl32
    je .Laiff_float32
    cmp ecx, 0x32334c46 # FL32
    je .Laiff_float32
    cmp ecx, 0x34366c66 # fl64
    je .Laiff_float64
    cmp ecx, 0x34364c46 # FL64
    jne .Laiff_bad
.Laiff_float64:
    mov dword ptr [rip + wav_format], 3
    cmp word ptr [rax + 6], 0x4000
    jne .Laiff_bad
    jmp .Laiff_next
.Laiff_float32:
    mov dword ptr [rip + wav_format], 3
    cmp word ptr [rax + 6], 0x2000
    jne .Laiff_bad
    jmp .Laiff_next
.Laiff_read_sound:
    cmp qword ptr [rip + aiff_sound], 0
    jne .Laiff_bad
    cmp edx, 8
    jb .Laiff_bad
    mov ecx, [rax]
    bswap ecx
    add rax, 8
    add rax, rcx
    jc .Laiff_bad
    cmp rax, r8
    ja .Laiff_bad
    mov [rip + aiff_sound], rax
    mov [rip + aiff_sound_end], r8
    jmp .Laiff_next
.Laiff_read_chan:
    cmp qword ptr [rip + aiff_chan], 0
    jne .Laiff_bad
    cmp edx, 12
    jb .Laiff_bad
    mov [rip + aiff_chan], rax
    mov [rip + aiff_chan_size], rdx
    mov ecx, [rax + 8]
    bswap ecx
    imul rcx, 20
    add rcx, 12
    cmp rcx, rdx
    ja .Laiff_bad
    jmp .Laiff_next
.Laiff_read_version:
    cmp dword ptr [rip + aiff_version_seen], 0
    jne .Laiff_bad
    cmp edx, 4
    jb .Laiff_bad
    mov dword ptr [rip + aiff_version_seen], 1
    # Known critical chunks have defined layouts regardless of FVER value.
    jmp .Laiff_next
.Laiff_complete:
    mov rax, [rip + aiff_comm]
    test rax, rax
    jz .Laiff_bad
    movzx ecx, word ptr [rax]
    rol cx, 8
    cmp ecx, 1
    jb .Laiff_bad
    cmp ecx, 8
    ja .Laiff_bad
    mov [rip + source_channels], ecx
    movzx edx, word ptr [rax + 6]
    rol dx, 8
    cmp edx, 1
    jb .Laiff_bad
    cmp dword ptr [rip + wav_format], 3
    je .Laiff_depth_valid
    cmp edx, 32
    ja .Laiff_bad
.Laiff_depth_valid:
    mov [rip + source_bits], edx
    cmp dword ptr [rip + aiff_forced_bits], 0
    je .Laiff_natural_container
    cmp edx, [rip + aiff_forced_bits]
    ja .Laiff_bad
    mov edx, [rip + aiff_forced_bits]
    jmp .Laiff_container_width
.Laiff_natural_container:
    add edx, 7
    and edx, -8
.Laiff_container_width:
    mov [rip + wav_container_bits], edx
    shr edx, 3
    imul edx, ecx
    mov [rip + wav_align], edx
    mov edx, [rax + 2]
    bswap edx
    mov [rip + total_frames], rdx
    # Positive normalized IEEE extended rate, rounded to nearest integer Hz.
    # The supported device-rate interval needs binary exponents 12 through 17.
    movzx ecx, word ptr [rax + 8]
    rol cx, 8
    sub ecx, 16383
    cmp ecx, 12
    jb .Laiff_bad
    cmp ecx, 17
    ja .Laiff_bad
    mov r9, [rax + 10]
    bswap r9
    bt r9, 63
    jnc .Laiff_bad
    neg ecx
    add ecx, 63
    mov rdx, r9
    shr rdx, cl
    dec ecx
    bt r9, rcx
    adc edx, 0
    cmp edx, 8000
    jb .Laiff_bad
    cmp edx, 192000
    ja .Laiff_bad
    mov [rip + sample_rate], edx
    mov rax, [rip + total_frames]
    mov edx, [rip + wav_align]
    imul rax, rdx
    mov r8, [rip + aiff_sound]
    test r8, r8
    jnz .Laiff_have_sound
    test rax, rax
    jnz .Laiff_bad
    mov r8, [rip + input_end]
    mov [rip + aiff_sound_end], r8
.Laiff_have_sound:
    mov [rip + wav_begin], r8
    mov [rip + input_cursor], r8
    add r8, rax
    jc .Laiff_bad
    cmp r8, [rip + aiff_sound_end]
    ja .Laiff_bad
    mov [rip + wav_end], r8
    call aiff_build_mix
    test eax, eax
    jz .Laiff_bad
    mov eax, 128
    sub eax, [rip + wav_container_bits]
    shl eax, 23
    mov [rip + float_scale], eax
    mov eax, 1
    add rsp, 40
    ret
.Laiff_bad:
    xor eax, eax
    add rsp, 40
    ret
ENDFN aiff_open

LOCALFN aiff_build_mix
    mov eax, [rip + source_channels]
    dec eax
    lea r8, [rip + aiff_defaults]
    mov rax, [r8 + rax*8]
    mov qword ptr [rip + aiff_order], rax
    mov r8, [rip + aiff_chan]
    test r8, r8
    jz .Laiff_mix_ordered
    mov eax, [r8]
    bswap eax
    test eax, eax
    jz .Laiff_descriptions
    cmp eax, 0x10000
    je .Laiff_bitmap
    movzx ecx, ax
    cmp ecx, [rip + source_channels]
    jne .Laiff_mix_bad
    shr eax, 16
    cmp eax, 0xffff
    je .Laiff_discrete
    cmp eax, 147
    je .Laiff_discrete
    lea r9, [rip + aiff_tags]
.Laiff_find_tag:
    cmp word ptr [r9], 0
    je .Laiff_mix_bad
    cmp ax, [r9]
    je .Laiff_tag_found
    add r9, 12
    jmp .Laiff_find_tag
.Laiff_tag_found:
    movzx eax, byte ptr [r9 + 2]
    cmp eax, [rip + source_channels]
    jne .Laiff_mix_bad
    mov rax, [r9 + 4]
    mov qword ptr [rip + aiff_order], rax
    jmp .Laiff_mix_ordered
.Laiff_discrete:
    mov rax, -1
    mov qword ptr [rip + aiff_order], rax
    mov byte ptr [rip + aiff_order], 0
    mov byte ptr [rip + aiff_order + 1], 1
    cmp dword ptr [rip + source_channels], 1
    jne .Laiff_mix_ordered
    mov byte ptr [rip + aiff_order], 2
    jmp .Laiff_mix_ordered
.Laiff_bitmap:
    mov edx, [r8 + 4]
    bswap edx
    test edx, 0xfffc0000
    jnz .Laiff_mix_bad
    lea r9, [rip + aiff_order]
    xor ecx, ecx
    xor eax, eax
.Laiff_bitmap_bit:
    bt edx, ecx
    jnc .Laiff_bitmap_next
    cmp eax, [rip + source_channels]
    jae .Laiff_mix_bad
    mov [r9 + rax], cl
    inc eax
.Laiff_bitmap_next:
    inc ecx
    cmp ecx, 18
    jb .Laiff_bitmap_bit
    cmp eax, [rip + source_channels]
    jne .Laiff_mix_bad
    jmp .Laiff_mix_ordered
.Laiff_descriptions:
    mov eax, [r8 + 8]
    bswap eax
    cmp eax, [rip + source_channels]
    jne .Laiff_mix_bad
    add r8, 12
    lea r9, [rip + aiff_order]
    xor edx, edx
.Laiff_description:
    mov eax, [r8]
    bswap eax
    cmp eax, 1
    jb .Laiff_label_silent
    cmp eax, 18
    jbe .Laiff_label_position
    cmp eax, 33
    je .Laiff_label_rear_left
    cmp eax, 34
    je .Laiff_label_rear_right
    cmp eax, 37
    je .Laiff_label_lfe
    cmp eax, 38
    je .Laiff_label_left
    cmp eax, 39
    je .Laiff_label_right
    cmp eax, 42
    je .Laiff_label_center
    cmp eax, 44
    je .Laiff_label_rear_center
    cmp eax, 301
    je .Laiff_label_left
    cmp eax, 302
    je .Laiff_label_right
    cmp eax, -1
    je .Laiff_label_silent
    cmp eax, 400
    je .Laiff_label_discrete
    cmp eax, 0x10000
    jb .Laiff_mix_bad
    cmp eax, 0x1ffff
    ja .Laiff_mix_bad
.Laiff_label_discrete:
    mov eax, edx
    inc eax
    cmp eax, 2
    ja .Laiff_label_silent
    cmp dword ptr [rip + source_channels], 1
    jne .Laiff_label_position
    mov eax, 3
    jmp .Laiff_label_position
.Laiff_label_rear_left:
    mov eax, 5
    jmp .Laiff_label_position
.Laiff_label_rear_right:
    mov eax, 6
    jmp .Laiff_label_position
.Laiff_label_left:
    mov eax, 1
    jmp .Laiff_label_position
.Laiff_label_right:
    mov eax, 2
    jmp .Laiff_label_position
.Laiff_label_center:
    mov eax, 3
    jmp .Laiff_label_position
.Laiff_label_lfe:
    mov eax, 4
    jmp .Laiff_label_position
.Laiff_label_rear_center:
    mov eax, 9
.Laiff_label_position:
    dec eax
    jmp .Laiff_label_save
.Laiff_label_silent:
    mov eax, 255
.Laiff_label_save:
    mov [r9 + rdx], al
    add r8, 20
    inc edx
    cmp edx, [rip + source_channels]
    jb .Laiff_description
.Laiff_mix_ordered:
    lea r8, [rip + pcm_mix_coeff]
    lea r9, [rip + aiff_order]
    lea r10, [rip + pcm_speaker_weights]
    xor edx, edx
    xor r11d, r11d
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
.Laiff_mix_channel:
    xorpd xmm2, xmm2
    xorpd xmm3, xmm3
    movzx ecx, byte ptr [r9 + rdx]
    cmp ecx, 18
    jae .Laiff_mix_save
    shl ecx, 4
    movsd xmm2, qword ptr [r10 + rcx]
    movsd xmm3, qword ptr [r10 + rcx + 8]
    inc r11d
.Laiff_mix_save:
    movsd qword ptr [r8], xmm2
    movsd qword ptr [r8 + 8], xmm3
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r8, 16
    inc edx
    cmp edx, [rip + source_channels]
    jb .Laiff_mix_channel
    maxsd xmm0, xmm1
    test r11d, r11d
    jz .Laiff_mix_enable
    movsd xmm2, [rip + pcm_mix_one]
    cmp r11d, 4
    jbe .Laiff_mix_scale
    movsd xmm2, [rip + pcm_mix_two]
.Laiff_mix_scale:
    divsd xmm2, xmm0
    lea r8, [rip + pcm_mix_coeff]
    mov ecx, [rip + source_channels]
.Laiff_mix_normalize:
    movsd xmm0, qword ptr [r8]
    movsd xmm1, qword ptr [r8 + 8]
    mulsd xmm0, xmm2
    mulsd xmm1, xmm2
    movsd qword ptr [r8], xmm0
    movsd qword ptr [r8 + 8], xmm1
    add r8, 16
    dec ecx
    jnz .Laiff_mix_normalize
.Laiff_mix_enable:
    mov dword ptr [rip + pcm_mix], 1
    cmp dword ptr [rip + source_channels], 1
    jne .Laiff_mix_stereo
    cmp byte ptr [rip + aiff_order], 2
    jne .Laiff_mix_ok
    mov dword ptr [rip + pcm_mix], 0
    jmp .Laiff_mix_ok
.Laiff_mix_stereo:
    cmp dword ptr [rip + source_channels], 2
    jne .Laiff_mix_ok
    cmp word ptr [rip + aiff_order], 0x100
    jne .Laiff_mix_ok
    mov dword ptr [rip + pcm_mix], 0
.Laiff_mix_ok:
    mov eax, 1
    ret
.Laiff_mix_bad:
    xor eax, eax
    ret
ENDFN aiff_build_mix
