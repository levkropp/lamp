; Original AIFF/AIFC PCM/IEEE parser and ordered Core Audio speaker mixing.
; Included in decoder.asm; shares its bounded mapped-input PCM reader. MIT.
.data
aiff_kind dd 0
aiff_forced_bits dd 0
aiff_comm dq 0
aiff_sound dq 0
aiff_sound_end dq 0
aiff_chan dq 0
aiff_chan_size dq 0
aiff_version_seen dd 0
aiff_order db 8 dup (255)
; Default AIFF conventions: 4-channel L C R Cs; 6-channel L Lc C R Rc Cs.
; Other untagged counts use the documented conventional speaker fallback.
aiff_defaults db 2,255,255,255,255,255,255,255
 db 0,1,255,255,255,255,255,255
 db 0,1,2,255,255,255,255,255
 db 0,2,1,8,255,255,255,255
 db 0,1,2,4,5,255,255,255
 db 0,6,2,1,7,8,255,255
 db 0,1,2,3,4,5,8,255
 db 0,1,2,3,4,5,9,10
; Each record is a high tag word, count, reserved byte and eight ordered
; zero-based WAVE speaker positions. These are format constants, not code.
aiff_tags label byte
 dw 100
 db 1,0,2,255,255,255,255,255,255,255
 dw 101
 db 2,0,0,1,255,255,255,255,255,255
 dw 102
 db 2,0,0,1,255,255,255,255,255,255
 dw 103
 db 2,0,0,1,255,255,255,255,255,255
 dw 105
 db 2,0,0,1,255,255,255,255,255,255
 dw 106
 db 2,0,0,1,255,255,255,255,255,255
 dw 108
 db 4,0,0,1,4,5,255,255,255,255
 dw 109
 db 5,0,0,1,4,5,2,255,255,255
 dw 110
 db 6,0,0,1,4,5,2,8,255,255
 dw 111
 db 8,0,0,1,4,5,2,8,9,10
 dw 112
 db 8,0,0,1,4,5,12,14,15,17
 dw 113
 db 3,0,0,1,2,255,255,255,255,255
 dw 114
 db 3,0,2,0,1,255,255,255,255,255
 dw 115
 db 4,0,0,1,2,8,255,255,255,255
 dw 116
 db 4,0,2,0,1,8,255,255,255,255
 dw 117
 db 5,0,0,1,2,4,5,255,255,255
 dw 118
 db 5,0,0,1,4,5,2,255,255,255
 dw 119
 db 5,0,0,2,1,4,5,255,255,255
 dw 120
 db 5,0,2,0,1,4,5,255,255,255
 dw 121
 db 6,0,0,1,2,3,4,5,255,255
 dw 122
 db 6,0,0,1,4,5,2,3,255,255
 dw 123
 db 6,0,0,2,1,4,5,3,255,255
 dw 124
 db 6,0,2,0,1,4,5,3,255,255
 dw 125
 db 7,0,0,1,2,3,4,5,8,255
 dw 126
 db 8,0,0,1,2,3,4,5,6,7
 dw 127
 db 8,0,2,6,7,0,1,4,5,3
 dw 128
 db 8,0,0,1,2,3,9,10,4,5
 dw 129
 db 8,0,0,1,4,5,2,3,6,7
 dw 130
 db 8,0,0,1,2,3,4,5,0,1
 dw 131
 db 3,0,0,1,8,255,255,255,255,255
 dw 132
 db 4,0,0,1,4,5,255,255,255,255
 dw 133
 db 3,0,0,1,3,255,255,255,255,255
 dw 134
 db 4,0,0,1,3,8,255,255,255,255
 dw 135
 db 5,0,0,1,3,4,5,255,255,255
 dw 136
 db 4,0,0,1,2,3,255,255,255,255
 dw 137
 db 5,0,0,1,2,3,8,255,255,255
 dw 138
 db 5,0,0,1,4,5,3,255,255,255
 dw 139
 db 6,0,0,1,4,5,2,8,255,255
 dw 140
 db 7,0,0,1,4,5,2,4,5,255
 dw 141
 db 6,0,2,0,1,4,5,8,255,255
 dw 142
 db 7,0,2,0,1,4,5,8,3,255
 dw 143
 db 7,0,2,0,1,4,5,4,5,255
 dw 144
 db 8,0,2,0,1,4,5,4,5,8
 dw 0
.code
; RCX=FORM base, RDX=mapped end. No allocation, no input writes.
aiff_open PROC
    sub rsp,40
    mov qword ptr [aiff_comm],0
    mov qword ptr [aiff_sound],0
    mov qword ptr [aiff_sound_end],0
    mov qword ptr [aiff_chan],0
    mov dword ptr [aiff_version_seen],0
    mov dword ptr [aiff_kind],0
    mov dword ptr [aiff_forced_bits],0
    mov dword ptr [pcm_big_endian],1
    mov dword ptr [pcm_signed8],1
    mov dword ptr [wav_format],1
    cmp dword ptr [rcx+8],46464941h ; AIFF
    je aiff_form_type
    cmp dword ptr [rcx+8],43464941h ; AIFC
    jne aiff_bad
    mov dword ptr [aiff_kind],1
aiff_form_type:
    mov eax,[rcx+4]
    bswap eax
    cmp eax,4
    jb aiff_bad
    add rax,8
    add rax,rcx
    jc aiff_bad
    cmp rax,rdx
    ja aiff_bad
    mov [input_end],rax
    lea r10,[rcx+12]
aiff_chunks:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz aiff_not_cancelled
    cmp dword ptr [rax],0
    jne aiff_bad
aiff_not_cancelled:
    cmp r10,[input_end]
    je aiff_complete
    lea rax,[r10+8]
    cmp rax,r10
    jb aiff_bad
    cmp rax,[input_end]
    ja aiff_bad
    mov edx,[r10+4]
    bswap edx
    mov r8,rax
    add r8,rdx
    jc aiff_bad
    cmp r8,[input_end]
    ja aiff_bad
    cmp dword ptr [r10],4d4d4f43h ; COMM
    je aiff_read_comm
    cmp dword ptr [r10],444e5353h ; SSND
    je aiff_read_sound
    cmp dword ptr [r10],4e414843h ; CHAN
    je aiff_read_chan
    cmp dword ptr [r10],52455646h ; FVER
    je aiff_read_version
aiff_next:
    add r8,1
    jc aiff_bad
    and r8,-2
    cmp r8,[input_end]
    ja aiff_bad
    mov r10,r8
    jmp aiff_chunks
aiff_read_comm:
    cmp qword ptr [aiff_comm],0
    jne aiff_bad
    cmp edx,18
    jb aiff_bad
    mov [aiff_comm],rax
    cmp dword ptr [aiff_kind],0
    je aiff_next
    cmp edx,23
    jb aiff_bad
    movzx ecx,byte ptr [rax+22]
    add ecx,2
    and ecx,-2
    add ecx,22
    cmp ecx,edx
    ja aiff_bad
    mov ecx,[rax+18]
    cmp ecx,454e4f4eh ; NONE
    je aiff_next
    cmp ecx,736f7774h ; twos
    je aiff_next
    cmp ecx,74776f73h ; sowt
    jne aiff_try_fixed_container
    mov dword ptr [pcm_big_endian],0
    jmp aiff_next
aiff_try_fixed_container:
    cmp ecx,34326e69h ; in24
    je aiff_fixed24
    cmp ecx,32336e69h ; in32
    je aiff_fixed32
    cmp ecx,20776172h ; raw (unsigned 8-bit)
    jne aiff_try_float
    mov dword ptr [aiff_forced_bits],8
    mov dword ptr [pcm_signed8],0
    jmp aiff_next
aiff_fixed24:
    mov dword ptr [aiff_forced_bits],24
    jmp aiff_next
aiff_fixed32:
    mov dword ptr [aiff_forced_bits],32
    jmp aiff_next
aiff_try_float:
    cmp ecx,32336c66h ; fl32
    je aiff_float32
    cmp ecx,32334c46h ; FL32
    je aiff_float32
    cmp ecx,34366c66h ; fl64
    je aiff_float64
    cmp ecx,34364c46h ; FL64
    jne aiff_bad
aiff_float64:
    mov dword ptr [wav_format],3
    cmp word ptr [rax+6],04000h
    jne aiff_bad
    jmp aiff_next
aiff_float32:
    mov dword ptr [wav_format],3
    cmp word ptr [rax+6],02000h
    jne aiff_bad
    jmp aiff_next
aiff_read_sound:
    cmp qword ptr [aiff_sound],0
    jne aiff_bad
    cmp edx,8
    jb aiff_bad
    mov ecx,[rax]
    bswap ecx
    add rax,8
    add rax,rcx
    jc aiff_bad
    cmp rax,r8
    ja aiff_bad
    mov [aiff_sound],rax
    mov [aiff_sound_end],r8
    jmp aiff_next
aiff_read_chan:
    cmp qword ptr [aiff_chan],0
    jne aiff_bad
    cmp edx,12
    jb aiff_bad
    mov [aiff_chan],rax
    mov [aiff_chan_size],rdx
    mov ecx,[rax+8]
    bswap ecx
    imul rcx,20
    add rcx,12
    cmp rcx,rdx
    ja aiff_bad
    jmp aiff_next
aiff_read_version:
    cmp dword ptr [aiff_version_seen],0
    jne aiff_bad
    cmp edx,4
    jb aiff_bad
    mov dword ptr [aiff_version_seen],1
    ; Known critical chunks have defined layouts regardless of FVER value.
    jmp aiff_next
aiff_complete:
    mov rax,[aiff_comm]
    test rax,rax
    jz aiff_bad
    movzx ecx,word ptr [rax]
    rol cx,8
    cmp ecx,1
    jb aiff_bad
    cmp ecx,8
    ja aiff_bad
    mov [source_channels],ecx
    movzx edx,word ptr [rax+6]
    rol dx,8
    cmp edx,1
    jb aiff_bad
    cmp dword ptr [wav_format],3
    je aiff_depth_valid
    cmp edx,32
    ja aiff_bad
aiff_depth_valid:
    mov [source_bits],edx
    cmp dword ptr [aiff_forced_bits],0
    je aiff_natural_container
    cmp edx,[aiff_forced_bits]
    ja aiff_bad
    mov edx,[aiff_forced_bits]
    jmp aiff_container_width
aiff_natural_container:
    add edx,7
    and edx,-8
aiff_container_width:
    mov [wav_container_bits],edx
    shr edx,3
    imul edx,ecx
    mov [wav_align],edx
    mov edx,[rax+2]
    bswap edx
    mov [total_frames],rdx
    ; Positive normalized IEEE extended rate, rounded to nearest integer Hz.
    ; The supported device-rate interval needs binary exponents 12 through 17.
    movzx ecx,word ptr [rax+8]
    rol cx,8
    sub ecx,16383
    cmp ecx,12
    jb aiff_bad
    cmp ecx,17
    ja aiff_bad
    mov r9,[rax+10]
    bswap r9
    bt r9,63
    jnc aiff_bad
    neg ecx
    add ecx,63
    mov rdx,r9
    shr rdx,cl
    dec ecx
    bt r9,rcx
    adc edx,0
    cmp edx,8000
    jb aiff_bad
    cmp edx,192000
    ja aiff_bad
    mov [sample_rate],edx
    mov rax,[total_frames]
    mov edx,[wav_align]
    imul rax,rdx
    mov r8,[aiff_sound]
    test r8,r8
    jnz aiff_have_sound
    test rax,rax
    jnz aiff_bad
    mov r8,[input_end]
    mov [aiff_sound_end],r8
aiff_have_sound:
    mov [wav_begin],r8
    mov [input_cursor],r8
    add r8,rax
    jc aiff_bad
    cmp r8,[aiff_sound_end]
    ja aiff_bad
    mov [wav_end],r8
    call aiff_build_mix
    test eax,eax
    jz aiff_bad
    mov eax,128
    sub eax,[wav_container_bits]
    shl eax,23
    mov [float_scale],eax
    mov eax,1
    add rsp,40
    ret
aiff_bad:
    xor eax,eax
    add rsp,40
    ret
aiff_open ENDP

aiff_build_mix PROC
    mov eax,[source_channels]
    dec eax
    lea r8,aiff_defaults
    mov rax,[r8+rax*8]
    mov qword ptr [aiff_order],rax
    mov r8,[aiff_chan]
    test r8,r8
    jz aiff_mix_ordered
    mov eax,[r8]
    bswap eax
    test eax,eax
    jz aiff_descriptions
    cmp eax,10000h
    je aiff_bitmap
    movzx ecx,ax
    cmp ecx,[source_channels]
    jne aiff_mix_bad
    shr eax,16
    cmp eax,0ffffh
    je aiff_discrete
    cmp eax,147
    je aiff_discrete
    lea r9,aiff_tags
aiff_find_tag:
    cmp word ptr [r9],0
    je aiff_mix_bad
    cmp ax,[r9]
    je aiff_tag_found
    add r9,12
    jmp aiff_find_tag
aiff_tag_found:
    movzx eax,byte ptr [r9+2]
    cmp eax,[source_channels]
    jne aiff_mix_bad
    mov rax,[r9+4]
    mov qword ptr [aiff_order],rax
    jmp aiff_mix_ordered
aiff_discrete:
    mov rax,-1
    mov qword ptr [aiff_order],rax
    mov byte ptr [aiff_order],0
    mov byte ptr [aiff_order+1],1
    cmp dword ptr [source_channels],1
    jne aiff_mix_ordered
    mov byte ptr [aiff_order],2
    jmp aiff_mix_ordered
aiff_bitmap:
    mov edx,[r8+4]
    bswap edx
    test edx,0fffc0000h
    jnz aiff_mix_bad
    lea r9,aiff_order
    xor ecx,ecx
    xor eax,eax
aiff_bitmap_bit:
    bt edx,ecx
    jnc aiff_bitmap_next
    cmp eax,[source_channels]
    jae aiff_mix_bad
    mov [r9+rax],cl
    inc eax
aiff_bitmap_next:
    inc ecx
    cmp ecx,18
    jb aiff_bitmap_bit
    cmp eax,[source_channels]
    jne aiff_mix_bad
    jmp aiff_mix_ordered
aiff_descriptions:
    mov eax,[r8+8]
    bswap eax
    cmp eax,[source_channels]
    jne aiff_mix_bad
    add r8,12
    lea r9,aiff_order
    xor edx,edx
aiff_description:
    mov eax,[r8]
    bswap eax
    cmp eax,1
    jb aiff_label_silent
    cmp eax,18
    jbe aiff_label_position
    cmp eax,33
    je aiff_label_rear_left
    cmp eax,34
    je aiff_label_rear_right
    cmp eax,37
    je aiff_label_lfe
    cmp eax,38
    je aiff_label_left
    cmp eax,39
    je aiff_label_right
    cmp eax,42
    je aiff_label_center
    cmp eax,44
    je aiff_label_rear_center
    cmp eax,301
    je aiff_label_left
    cmp eax,302
    je aiff_label_right
    cmp eax,-1
    je aiff_label_silent
    cmp eax,400
    je aiff_label_discrete
    cmp eax,10000h
    jb aiff_mix_bad
    cmp eax,1ffffh
    ja aiff_mix_bad
aiff_label_discrete:
    mov eax,edx
    inc eax
    cmp eax,2
    ja aiff_label_silent
    cmp dword ptr [source_channels],1
    jne aiff_label_position
    mov eax,3
    jmp aiff_label_position
aiff_label_rear_left:
    mov eax,5
    jmp aiff_label_position
aiff_label_rear_right:
    mov eax,6
    jmp aiff_label_position
aiff_label_left:
    mov eax,1
    jmp aiff_label_position
aiff_label_right:
    mov eax,2
    jmp aiff_label_position
aiff_label_center:
    mov eax,3
    jmp aiff_label_position
aiff_label_lfe:
    mov eax,4
    jmp aiff_label_position
aiff_label_rear_center:
    mov eax,9
aiff_label_position:
    dec eax
    jmp aiff_label_save
aiff_label_silent:
    mov eax,255
aiff_label_save:
    mov [r9+rdx],al
    add r8,20
    inc edx
    cmp edx,[source_channels]
    jb aiff_description
aiff_mix_ordered:
    lea r8,pcm_mix_coeff
    lea r9,aiff_order
    lea r10,pcm_speaker_weights
    xor edx,edx
    xor r11d,r11d
    xorpd xmm0,xmm0
    xorpd xmm1,xmm1
aiff_mix_channel:
    xorpd xmm2,xmm2
    xorpd xmm3,xmm3
    movzx ecx,byte ptr [r9+rdx]
    cmp ecx,18
    jae aiff_mix_save
    shl ecx,4
    movsd xmm2,qword ptr [r10+rcx]
    movsd xmm3,qword ptr [r10+rcx+8]
    inc r11d
aiff_mix_save:
    movsd qword ptr [r8],xmm2
    movsd qword ptr [r8+8],xmm3
    addsd xmm0,xmm2
    addsd xmm1,xmm3
    add r8,16
    inc edx
    cmp edx,[source_channels]
    jb aiff_mix_channel
    maxsd xmm0,xmm1
    test r11d,r11d
    jz aiff_mix_enable
    movsd xmm2,[pcm_mix_one]
    cmp r11d,4
    jbe aiff_mix_scale
    movsd xmm2,[pcm_mix_two]
aiff_mix_scale:
    divsd xmm2,xmm0
    lea r8,pcm_mix_coeff
    mov ecx,[source_channels]
aiff_mix_normalize:
    movsd xmm0,qword ptr [r8]
    movsd xmm1,qword ptr [r8+8]
    mulsd xmm0,xmm2
    mulsd xmm1,xmm2
    movsd qword ptr [r8],xmm0
    movsd qword ptr [r8+8],xmm1
    add r8,16
    dec ecx
    jnz aiff_mix_normalize
aiff_mix_enable:
    mov dword ptr [pcm_mix],1
    cmp dword ptr [source_channels],1
    jne aiff_mix_stereo
    cmp byte ptr [aiff_order],2
    jne aiff_mix_ok
    mov dword ptr [pcm_mix],0
    jmp aiff_mix_ok
aiff_mix_stereo:
    cmp dword ptr [source_channels],2
    jne aiff_mix_ok
    cmp word ptr [aiff_order],0100h
    jne aiff_mix_ok
    mov dword ptr [pcm_mix],0
aiff_mix_ok:
    mov eax,1
    ret
aiff_mix_bad:
    xor eax,eax
    ret
aiff_build_mix ENDP
