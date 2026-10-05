; Original bounded Vorbis decoder in x86-64 assembly. MIT, see LICENSE.
; Floor 1, residue 0/1/2, mapping 0, 1..255 channels. Reference: Xiph Vorbis I.
option casemap:none
include vorbis_layout.inc
EXTERN VirtualAlloc:PROC, VirtualFree:PROC
EXTERN ogg_open:PROC, ogg_next:PROC, ogg_close:PROC
EXTERN ogg_checkpoint:PROC,ogg_resume:PROC
EXTERN ogg_granule:QWORD, ogg_total_granule:QWORD, ogg_eos:DWORD
EXTERN ogg_packet_last:DWORD,ogg_packet_page_end:DWORD,ogg_cancel_ptr:QWORD
EXTERN sample_rate:DWORD, source_channels:DWORD, source_bits:DWORD
EXTERN total_frames:QWORD, decode_error:DWORD
EXTERN pcm_speaker_weights:QWORD
EXTERN vb_transform_init:PROC, vb_imdct:PROC, vb_windows:QWORD
PUBLIC vorbis_open, vorbis_read, vorbis_close,vorbis_seek
PUBLIC vorbis_index_count,vorbis_index_stride,vorbis_seek_preroll
PUBLIC vorbis_read_native
VB_INDEX_CAP EQU 2048
VB_INDEX_POINT EQU 32
.data
vb_arena dq 0
vb_allocated dd 0
vb_committed dd 0
vb_ptr dq 0
vb_end dq 0
vb_acc dq 0
vb_count dd 0
vb_bad dd 0
vb_short dd 0
vb_long dd 0
vb_books_count dd 0
vb_floors_count dd 0
vb_residues_count dd 0
vb_maps_count dd 0
vb_modes_count dd 0
vb_mode_bits dd 0
vb_first dd 1
vb_previous dd 0
vb_available dd 0
vb_used dd 0
vb_emitted dq 0
vb_index dq 0
vorbis_index_count dd 0
vorbis_index_stride dq 16
vorbis_seek_preroll dd 0
vb_origin_known dd 0
vb_origin dq 0
vb_initial_skip dd 0
vb_trim_start dd 0
vb_frame_skip dd 0
vb_n dd 0
vb_block dd 0
vb_left dd 0
vb_left_end dd 0
vb_right dd 0
vb_right_end dd 0
vb_current_map dq 0
vb_range_table dd 256,128,86,64
vb_float_mant dd 0
vb_float_exp dd 0
vb_lengths_total dd 0
vb_tree_used dd 0
vb_quant_ptr dq 0
vb_min real4 0.0
vb_delta real4 0.0
vb_rs_ptr dq 0
vb_rs_channels dd 0
vb_rs_groups dd 0
vb_rs_active dd 255 dup (0)
vb_rs_channel dd 255 dup (0)
vb_rs_parts dd 0
vb_rs_words dd 0
vb_rs_begin dd 0
vb_rs_type dd 0
vb_spectrum_ptr dq 0
vb_time_ptr dq 0
vb_tail_ptr dq 0
vb_y_ptr dq 0
vb_active_ptr dq 0
vb_classdata_ptr dq 0
vb_mix_one real8 1.0
vb_mix_two real8 2.0
vb_mix_coeff real8 16 dup (0.0)
; Zero-based WAVE roles, in Vorbis's specified encoded channel order.
vb_channel_roles db 2,255,255,255,255,255,255,255
 db 0,1,255,255,255,255,255,255
 db 0,2,1,255,255,255,255,255
 db 0,1,4,5,255,255,255,255
 db 0,2,1,4,5,255,255,255
 db 0,2,1,4,5,3,255,255
 db 0,2,1,9,10,8,3,255
 db 0,2,1,9,10,4,5,3
include vorbis_tables.inc
.data?
ALIGN 16
vb_books db CB_SIZE*256 dup (?)
vb_floors db FL_SIZE*64 dup (?)
vb_residues db RS_SIZE*64 dup (?)
vb_maps db MP_SIZE*64 dup (?)
vb_modes dd 128 dup (?)
vb_codes_available dd 33 dup (?)
vb_spectrum real4 8192 dup (?)
vb_time real4 16384 dup (?)
vb_tail real4 8192 dup (?)
vb_pcm real4 16384 dup (?)
vb_y dd 512 dup (?)
vb_active dd 512 dup (?)
vb_floor_channel dq 255 dup (?)
vb_zero dd 255 dup (?)
vb_really_zero dd 255 dup (?)
vb_classdata dd 32768 dup (?)
vb_audio_checkpoint dq 2 dup (?)
vb_scan_checkpoint dq 2 dup (?)
.code
; Bounded little-endian bit reader. Only EAX and flags are clobbered.
vb_bits PROC
    push rcx
    push rdx
    push r8
    cmp ecx,32
    ja vb_bits_bad
    test ecx,ecx
    jz vb_bits_zero
    mov r8d,[vb_count]
vb_bits_load:
    cmp r8d,ecx
    jae vb_bits_extract
    mov rdx,[vb_ptr]
    cmp rdx,[vb_end]
    jae vb_bits_bad
    movzx eax,byte ptr [rdx]
    inc rdx
    mov [vb_ptr],rdx
    mov edx,ecx
    mov ecx,r8d
    shl rax,cl
    or [vb_acc],rax
    mov ecx,edx
    add r8d,8
    jmp vb_bits_load
vb_bits_extract:
    mov rax,[vb_acc]
    mov edx,-1
    cmp ecx,32
    je vb_bits_mask
    mov edx,1
    shl edx,cl
    dec edx
vb_bits_mask:
    and eax,edx
    shr qword ptr [vb_acc],cl
    sub r8d,ecx
    mov [vb_count],r8d
    jmp vb_bits_done
vb_bits_bad:
    mov dword ptr [vb_bad],1
vb_bits_zero:
    xor eax,eax
vb_bits_done:
    pop r8
    pop rdx
    pop rcx
    ret
vb_bits ENDP

; EAX=nonnegative integer -> ECX=ilog(integer).
vb_ilog PROC
    xor ecx,ecx
    test eax,eax
    jz vb_ilog_done
    bsr ecx,eax
    inc ecx
vb_ilog_done:
    ret
vb_ilog ENDP

; EAX=bytes, aligned zeroed arena -> RAX. Failures are sticky.
vb_alloc PROC
    push rbx
    push rsi
    sub rsp,40
    add eax,15
    jc vb_alloc_bad
    and eax,-16
    mov edx,[vb_allocated]
    add eax,edx
    jc vb_alloc_bad
    cmp eax,VB_ARENA
    ja vb_alloc_bad
    mov [vb_allocated],eax
    mov esi,edx
    cmp eax,[vb_committed]
    jbe vb_alloc_ready
    add eax,65535
    and eax,-65536
    mov ebx,eax
    mov edx,[vb_committed]
    mov rcx,[vb_arena]
    add rcx,rdx
    mov eax,ebx
    sub eax,edx
    mov edx,eax
    mov r8d,1000h
    mov r9d,4
    call VirtualAlloc
    test rax,rax
    jz vb_alloc_bad
    mov [vb_committed],ebx
vb_alloc_ready:
    mov rax,[vb_arena]
    add rax,rsi
    jmp vb_alloc_return
vb_alloc_bad:
    mov dword ptr [vb_bad],1
    xor eax,eax
vb_alloc_return:
    add rsp,40
    pop rsi
    pop rbx
    ret
vb_alloc ENDP

; Channel working buffers share the bounded setup arena. Mono/stereo retain
; their original static buffers; larger streams allocate only their count.
vb_workspace PROC
    sub rsp,40
    lea rax,vb_spectrum
    mov [vb_spectrum_ptr],rax
    lea rax,vb_time
    mov [vb_time_ptr],rax
    lea rax,vb_tail
    mov [vb_tail_ptr],rax
    lea rax,vb_y
    mov [vb_y_ptr],rax
    lea rax,vb_active
    mov [vb_active_ptr],rax
    lea rax,vb_classdata
    mov [vb_classdata_ptr],rax
    cmp dword ptr [source_channels],2
    jbe vb_workspace_ready
    mov eax,[source_channels]
    shl eax,14
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_spectrum_ptr],rax
    mov eax,[source_channels]
    shl eax,15
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_time_ptr],rax
    mov eax,[source_channels]
    shl eax,14
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_tail_ptr],rax
    mov eax,[source_channels]
    shl eax,10
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_y_ptr],rax
    mov eax,[source_channels]
    shl eax,10
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_active_ptr],rax
    ; Per-group stride remains 16384 classification integers. Residue 2
    ; has one group and can use the whole channel-count-sized allocation.
    mov eax,[source_channels]
    shl eax,16
    call vb_alloc
    test rax,rax
    jz vb_workspace_bad
    mov [vb_classdata_ptr],rax
vb_workspace_ready:
    mov eax,1
    add rsp,40
    ret
vb_workspace_bad:
    xor eax,eax
    add rsp,40
    ret
vb_workspace ENDP

; Standard 1..8-channel roles use the shared stereo weights/headroom policy.
; Larger channel layouts are application-defined: output ports 0/1 directly.
vb_build_mix PROC
    mov ecx,[source_channels]
    cmp ecx,2
    jbe vb_mix_done
    cmp ecx,8
    ja vb_mix_done
    mov eax,ecx
    dec eax
    lea r9,vb_channel_roles
    lea r9,[r9+rax*8]
    lea r8,vb_mix_coeff
    lea r10,pcm_speaker_weights
    xorpd xmm0,xmm0
    xorpd xmm1,xmm1
    xor edx,edx
vb_mix_role:
    movzx eax,byte ptr [r9+rdx]
    shl eax,4
    movsd xmm2,qword ptr [r10+rax]
    movsd xmm3,qword ptr [r10+rax+8]
    movsd qword ptr [r8],xmm2
    movsd qword ptr [r8+8],xmm3
    addsd xmm0,xmm2
    addsd xmm1,xmm3
    add r8,16
    inc edx
    cmp edx,ecx
    jb vb_mix_role
    maxsd xmm0,xmm1
    movsd xmm2,[vb_mix_one]
    cmp ecx,4
    jbe vb_mix_normalize
    movsd xmm2,[vb_mix_two]
vb_mix_normalize:
    divsd xmm2,xmm0
    lea r8,vb_mix_coeff
vb_mix_scale:
    movsd xmm0,qword ptr [r8]
    movsd xmm1,qword ptr [r8+8]
    mulsd xmm0,xmm2
    mulsd xmm1,xmm2
    movsd qword ptr [r8],xmm0
    movsd qword ptr [r8+8],xmm1
    add r8,16
    dec ecx
    jnz vb_mix_scale
vb_mix_done:
    ret
vb_build_mix ENDP

; EAX=Vorbis packed float -> XMM0; x87 handles signed binary exponent.
vb_unpack PROC
    mov edx,eax
    and edx,1fffffh
    test eax,80000000h
    jz vb_unpack_positive
    neg edx
vb_unpack_positive:
    mov [vb_float_mant],edx
    shr eax,21
    and eax,3ffh
    sub eax,788
    mov [vb_float_exp],eax
    fild dword ptr [vb_float_exp]
    fild dword ptr [vb_float_mant]
    fscale
    fstp dword ptr [vb_float_mant]
    fstp st(0)
    movss xmm0,dword ptr [vb_float_mant]
    ret
vb_unpack ENDP

; ECX=codebook index -> EAX=symbol. Simple tree, maximum 32 bits.
vb_symbol PROC
    push rdx
    push r8
    push r9
    cmp ecx,[vb_books_count]
    jae vb_symbol_bad
    mov eax,ecx
    shl eax,6
    lea r8,vb_books
    mov r8,[r8+rax+CB_TREE]
    xor r9d,r9d
    xor edx,edx
vb_symbol_bit:
    VB_GET 1
    lea rax,[rax+rdx*2]
    mov edx,[r8+rax*4]
    test edx,edx
    js vb_symbol_leaf
    test edx,edx
    jz vb_symbol_bad
    inc r9d
    cmp r9d,32
    jb vb_symbol_bit
vb_symbol_bad:
    mov dword ptr [vb_bad],1
    xor eax,eax
    jmp vb_symbol_done
vb_symbol_leaf:
    mov eax,edx
    not eax
vb_symbol_done:
    pop r9
    pop r8
    pop rdx
    ret
vb_symbol ENDP

vorbis_close PROC
    sub rsp,40
    mov rcx,[vb_index]
    mov qword ptr [vb_index],0
    mov dword ptr [vorbis_index_count],0
    mov dword ptr [vorbis_seek_preroll],0
    test rcx,rcx
    jz vb_close_arena
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
vb_close_arena:
    mov rcx,[vb_arena]
    test rcx,rcx
    jz vb_close_done
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
    mov qword ptr [vb_arena],0
vb_close_done:
    add rsp,40
    ret
vorbis_close ENDP

vorbis_open PROC
    push rbx
    push rsi
    push rdi
    sub rsp,32
    call ogg_open
    test eax,eax
    jz vb_open_bad
    call vorbis_close
    mov dword ptr [vb_bad],0
    mov dword ptr [vb_allocated],0
    mov dword ptr [vb_committed],0
    mov dword ptr [vb_first],1
    mov dword ptr [vb_previous],0
    mov dword ptr [vb_available],0
    mov dword ptr [vb_used],0
    mov qword ptr [vb_emitted],0
    mov dword ptr [vb_initial_skip],0
    mov dword ptr [vb_trim_start],0
    call ogg_next
    test rax,rax
    jz vb_open_bad
    cmp edx,30
    jne vb_open_bad
    cmp dword ptr [rax],726f7601h
    jne vb_open_bad
    cmp word ptr [rax+4],6962h
    jne vb_open_bad
    cmp byte ptr [rax+6],73h
    jne vb_open_bad
    cmp dword ptr [rax+7],0
    jne vb_open_bad
    movzx ecx,byte ptr [rax+11]
    cmp ecx,1
    jb vb_open_bad
    mov [source_channels],ecx
    mov ecx,[rax+12]
    cmp ecx,8000
    jb vb_open_bad
    cmp ecx,192000
    ja vb_open_bad
    mov [sample_rate],ecx
    movzx ecx,byte ptr [rax+28]
    mov edx,ecx
    and ecx,15
    shr edx,4
    cmp ecx,6
    jb vb_open_bad
    cmp edx,13
    ja vb_open_bad
    cmp edx,ecx
    jb vb_open_bad
    mov ebx,1
    shl ebx,cl
    mov [vb_short],ebx
    mov ecx,edx
    mov ebx,1
    shl ebx,cl
    mov [vb_long],ebx
    cmp byte ptr [rax+29],1
    jne vb_open_bad
    mov dword ptr [source_bits],32
    mov rax,[ogg_total_granule]
    mov [total_frames],rax
    call ogg_next
    test rax,rax
    jz vb_open_bad
    cmp edx,16
    jb vb_open_bad
    cmp dword ptr [rax],726f7603h
    jne vb_open_bad
    cmp word ptr [rax+4],6962h
    jne vb_open_bad
    cmp byte ptr [rax+6],73h
    jne vb_open_bad
    ; Validate bounded vendor and comment strings without allocating them.
    mov rsi,rax
    lea rdi,[rax+rdx]
    add rsi,7
    mov eax,[rsi]
    add rsi,4
    add rsi,rax
    lea rax,[rsi+4]
    cmp rax,rdi
    ja vb_open_bad
    mov ebx,[rsi]
    add rsi,4
vb_comment:
    test ebx,ebx
    jz vb_comment_end
    lea rax,[rsi+4]
    cmp rax,rdi
    ja vb_open_bad
    mov eax,[rsi]
    add rsi,4
    add rsi,rax
    cmp rsi,rdi
    ja vb_open_bad
    dec ebx
    jmp vb_comment
vb_comment_end:
    cmp rsi,rdi
    jae vb_open_bad
    test byte ptr [rsi],1
    jz vb_open_bad
    xor ecx,ecx
    mov edx,VB_ARENA
    mov r8d,2000h          ; reserve address space; commit setup pages as needed
    mov r9d,4
    call VirtualAlloc
    test rax,rax
    jz vb_open_bad
    mov [vb_arena],rax
    call ogg_next
    test rax,rax
    jz vb_open_bad
    cmp edx,8
    jb vb_open_bad
    cmp dword ptr [rax],726f7605h
    jne vb_open_bad
    cmp word ptr [rax+4],6962h
    jne vb_open_bad
    cmp byte ptr [rax+6],73h
    jne vb_open_bad
    lea rcx,[rax+rdx]
    mov [vb_end],rcx
    add rax,7
    mov [vb_ptr],rax
    mov qword ptr [vb_acc],0
    mov dword ptr [vb_count],0
    call vb_setup
    test eax,eax
    jz vb_open_bad
    call vb_workspace
    test eax,eax
    jz vb_open_bad
    call vb_build_mix
    mov ecx,[vb_short]
    mov edx,[vb_long]
    call vb_transform_init
    cmp dword ptr [ogg_packet_page_end],1
    jne vb_open_bad
    call vb_build_index
    test eax,eax
    jz vb_open_bad
    mov eax,1
    jmp vb_open_done
vb_open_bad:
    mov dword ptr [decode_error],23
    xor eax,eax
vb_open_done:
    add rsp,32
    pop rdi
    pop rsi
    pop rbx
    ret
vorbis_open ENDP

; Packet-mode/window scan only. Points capture a packet boundary and the raw
; sample position after that packet. Decode it once to prime exact overlap.
; Limit memory to 64 KiB and compact alternate points at the 2048-point cap.
vb_build_index PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,48
    lea rcx,vb_audio_checkpoint
    call ogg_checkpoint
    xor ecx,ecx
    mov edx,VB_INDEX_CAP*VB_INDEX_POINT
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    mov [vb_index],rax       ;allocation failure keeps correct sequential use
    mov qword ptr [vorbis_index_stride],16
    mov dword ptr [vb_origin_known],0
    mov qword ptr [vb_origin],0
    xor ebx,ebx             ;audio packet ordinal
    xor r12d,r12d           ;untrimmed emitted PCM after this packet
    xor r13d,r13d           ;previous packet's right overlap width
vb_index_packet:
    lea rcx,vb_scan_checkpoint
    call ogg_checkpoint
    call ogg_next
    test rax,rax
    jz vb_index_complete
    call vb_packet_header
    test eax,eax
    jz vb_index_bad
    mov r14d,[vb_right]
    sub r14d,[vb_left]
    test r13d,r13d
    jnz vb_index_following
    mov eax,[vb_n]
    shr eax,1
    mov ecx,[vb_right]
    sub ecx,eax
    add r12,rcx             ;first long-to-short packet's unwindowed prefix
    jmp vb_index_first
vb_index_following:
    mov eax,[vb_left_end]
    sub eax,[vb_left]
    cmp eax,r13d
    jne vb_index_bad
    add r12,r14
vb_index_first:
    mov r13d,[vb_right_end]
    sub r13d,[vb_right]
    cmp dword ptr [ogg_packet_last],1
    jne vb_index_point
    mov r15,r12
    mov eax,[vb_n]
    shr eax,1
    sub eax,[vb_right]       ;granule is the center, before next-short lookahead
    movsxd rax,eax
    add r15,rax
    mov rax,[ogg_granule]
    test rax,rax
    js vb_index_bad
    cmp dword ptr [vb_origin_known],0
    jne vb_index_granule
    cmp dword ptr [ogg_eos],1
    je vb_index_origin_ready ;first/final page only trims its end
    test rbx,rbx
    jz vb_index_point        ;first packet primes overlap but returns no PCM
    sub rax,r15
    jz vb_index_origin_ready
    cmp rbx,1               ;nonzero origins require the second packet flush
    jne vb_index_bad
    test rax,rax
    jns vb_index_origin_positive
    mov rcx,rax
    neg rcx
    cmp rcx,r15
    ja vb_index_bad
    mov [vb_initial_skip],ecx
vb_index_origin_positive:
    mov [vb_origin],rax
vb_index_origin_ready:
    mov dword ptr [vb_origin_known],1
vb_index_granule:
    mov rax,r15
    add rax,[vb_origin]
    jo vb_index_bad
    cmp dword ptr [ogg_eos],1
    je vb_index_final_granule
    cmp rax,[ogg_granule]
    jne vb_index_bad
    jmp vb_index_point
vb_index_final_granule:
    cmp rax,[ogg_granule]
    jb vb_index_bad
vb_index_point:
    cmp qword ptr [vb_index],0
    je vb_index_next
    mov rax,[vorbis_index_stride]
    dec rax
    test rbx,rax
    jnz vb_index_next
    cmp dword ptr [vorbis_index_count],VB_INDEX_CAP
    jb vb_index_store
    mov r15,1
vb_index_compact:
    mov rsi,r15
    shl rsi,6
    add rsi,[vb_index]
    mov rdi,r15
    shl rdi,5
    add rdi,[vb_index]
    mov ecx,4
    rep movsq
    inc r15d
    cmp r15d,VB_INDEX_CAP/2
    jb vb_index_compact
    mov dword ptr [vorbis_index_count],VB_INDEX_CAP/2
    shl qword ptr [vorbis_index_stride],1
vb_index_store:
    mov eax,[vorbis_index_count]
    shl eax,5
    add rax,[vb_index]
    mov rcx,[vb_scan_checkpoint]
    mov [rax],rcx
    mov rcx,[vb_scan_checkpoint+8]
    mov [rax+8],rcx
    mov [rax+16],r12
    mov [rax+24],rbx
    inc dword ptr [vorbis_index_count]
vb_index_next:
    inc rbx
    jmp vb_index_packet
vb_index_complete:
    cmp dword ptr [decode_error],0
    jne vb_index_bad
    mov rax,[ogg_total_granule]
    sub rax,[vb_origin]
    jo vb_index_bad
    test rax,rax
    js vb_index_bad
    cmp rax,r12
    ja vb_index_bad
    mov rdx,rax             ;raw end before start cropping
    mov ecx,[vb_initial_skip]
    sub rax,rcx
    jc vb_index_bad
    mov [total_frames],rax
vb_index_trim_points:
    mov eax,[vorbis_index_count]
    test eax,eax
    jz vb_index_reset
    dec eax
    shl eax,5
    add rax,[vb_index]
    cmp [rax+16],rdx
    jbe vb_index_reset
    dec dword ptr [vorbis_index_count]
    jmp vb_index_trim_points
vb_index_reset:
    mov eax,[vb_initial_skip]
    mov [vb_trim_start],eax
    test rbx,rbx
    jz vb_index_empty
    lea rcx,vb_audio_checkpoint
    call ogg_resume
    test eax,eax
    jz vb_index_bad
vb_index_empty:
    mov eax,1
    jmp vb_index_return
vb_index_bad:
    xor eax,eax
vb_index_return:
    add rsp,48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
vb_build_index ENDP

vorbis_seek PROC
    push rbx
    push rsi
    sub rsp,40
    xor eax,eax
    mov dword ptr [vorbis_seek_preroll],0
    cmp dword ptr [vorbis_index_count],0
    je vb_seek_return
    test rcx,rcx
    jz vb_seek_return
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz vb_seek_not_cancelled
    cmp dword ptr [rax],0
    jne vb_seek_zero
vb_seek_not_cancelled:
    cmp rcx,[total_frames]
    cmova rcx,[total_frames]
    mov eax,[vb_initial_skip]
    add rcx,rax
    mov rsi,rcx
    xor r8d,r8d
    mov r9d,[vorbis_index_count]
vb_seek_search:
    cmp r8d,r9d
    jae vb_seek_found
    mov edx,r9d
    sub edx,r8d
    shr edx,1
    add edx,r8d
    mov eax,edx
    shl eax,5
    add rax,[vb_index]
    cmp [rax+16],rsi
    ja vb_seek_upper
    lea r8d,[rdx+1]
    jmp vb_seek_search
vb_seek_upper:
    mov r9d,edx
    jmp vb_seek_search
vb_seek_found:
    test r8d,r8d
    jz vb_seek_zero         ;target precedes the first packet's optional prefix
    dec r8d
    mov eax,r8d
    shl eax,5
    add rax,[vb_index]
    mov rbx,[rax+16]
    mov rcx,rax
    call ogg_resume
    test eax,eax
    jz vb_seek_bad
    mov dword ptr [vb_previous],0
    mov dword ptr [vb_first],0
    mov dword ptr [vb_available],0
    mov dword ptr [vb_used],0
    mov dword ptr [vb_trim_start],0
    mov eax,[vb_initial_skip]
    cmp rbx,rax
    jae vb_seek_emitted
    sub eax,ebx
    mov [vb_trim_start],eax
    xor ebx,ebx
    jmp vb_seek_prime
vb_seek_emitted:
    sub rbx,rax
vb_seek_prime:
    mov [vb_emitted],rbx
    inc dword ptr [vorbis_seek_preroll]
    call vb_frame           ;only reconstruct the preceding packet's tail
    test eax,eax
    jz vb_seek_bad
    mov rax,rbx
    jmp vb_seek_return
vb_seek_bad:
    mov dword ptr [decode_error],24
vb_seek_zero:
    xor eax,eax
vb_seek_return:
    add rsp,40
    pop rsi
    pop rbx
    ret
vorbis_seek ENDP
include vorbis_setup.inc
include vorbis_decode.inc
END
