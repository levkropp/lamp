; Handwritten x86-64 MPEG Layer III decoder.
; Codebooks and algorithm reference: dr_mp3 (MIT-0), see THIRD_PARTY_NOTICES.
; No reference implementation is compiled or linked into this module.
option casemap:none
include mp3_layout.inc
EXTERN sample_rate:DWORD, source_channels:DWORD, source_bits:DWORD
EXTERN decode_error:DWORD, total_frames:QWORD
EXTERN mp_hybrid:PROC, mp_synthesis:PROC
EXTERN VirtualAlloc:PROC,VirtualFree:PROC,ogg_cancel_ptr:QWORD
PUBLIC mp3_open, mp3_read, mp3_seek,mp3_close,mp_grbuf, mp_overlap, mp_qmf, mp_syn
PUBLIC mp3_index_count,mp3_index_stride,mp3_seek_headers
PUBLIC mp_aa, mp_twid9, mp_mdct_win, mp_twid3, mp_synth_win, mp_dct9, mp_dct_sec

.const
include mp3_tables.inc
bitrate1 dd 0,32,40,48,56,64,80,96,112,128,160,192,224,256,320
bitrate2 dd 0,8,16,24,32,40,48,56,64,80,96,112,128,144,160
mp_rates dd 44100,48000,32000
sqrt_two dd 3fb504f3h
one_float dd 3f800000h
; A seek point precedes a compressed frame and retains its exact unused
; main-data reservoir. PCM overlap/QMF history is rebuilt by two full frames.
MP_INDEX_POINT EQU 544
MP_INDEX_CAP EQU 2048

.data
mp_cursor dq 0
mp_end dq 0
mp_frame_end dq 0
mp_header dd 0
mp_version dd 0
mp_initial_version dd 0
mp_rate dd 0
mp_channels dd 0
mp_initial_channels dd 0
mp_samples dd 0
mp_frame_bytes dd 0
mp_side_bytes dd 0
mp_crc_bytes dd 0
mp_sr_index dd 0
mp_joint dd 0
mp_ms dd 0
mp_intensity dd 0
mp_reserv_size dd 0
mp_main_begin dd 0
mp_main_bytes dd 0
mp_bit_pos dd 0
mp_bit_limit dd 0
mp_bit_base dq 0
mp_part_limit dd 0
mp_granule dd 0
mp_channel dd 0
mp_gr_count dd 0
mp_frame_used dd 0
mp_frame_ready dd 0
mp_trim_start dd 0
mp_trim_end dd 0
mp_emitted dq 0
mp_scfsi dd 2 dup (0)
mp_scf_sizes dd 4 dup (0)
mp_scf_counts dq 0
mp_scf_shift dd 0
mp_scale_count dd 0
mp_max_band dd 3 dup (-1)
mp_xing_count dd 0
mp_xing_flags dd 0
mp_stream_begin dq 0
mp_initial_trim dd 0
mp_index dq 0
mp3_index_count dd 0
mp3_index_stride dq 32
mp3_seek_headers dq 0

.data?
ALIGN 16
mp_info db GI_SIZE*4 dup (?)
mp_reserv db 511 dup (?)
mp_main db 4096 dup (?)
mp_iscf db 40 dup (?)
mp_ist db 40*2 dup (?)
mp_scales dd 40 dup (?)
mp_temp dd 576 dup (?)
mp_grbuf dd 576*2 dup (?)
mp_overlap dd 288*2 dup (?)
mp_qmf dd 960 dup (?)
mp_syn dd 2112 dup (?)
mp_pcm dq 1152 dup (?)

.code
; RCX=file bytes, RDX=end. Layer III only; known-bitrate MPEG-1/2/2.5.
mp3_open PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    mov rsi,rcx
    mov r12,rdx
    call mp3_close
    mov rcx,rsi
    mov rdx,r12
    mov [mp_cursor],rcx
    mov [mp_end],rdx
    mov dword ptr [mp_reserv_size],0
    mov dword ptr [mp_frame_ready],0
    mov dword ptr [mp_frame_used],0
    mov dword ptr [mp_trim_start],0
    mov dword ptr [mp_trim_end],0
    mov qword ptr [mp_emitted],0
    lea rdi,mp_ist
    xor eax,eax
    mov ecx,80
    rep stosb
    lea rdi,mp_overlap
    mov ecx,576
    rep stosd
    lea rdi,mp_qmf
    mov ecx,960
    rep stosd
    mov rsi,[mp_cursor]
    lea rax,[rsi+10]
    cmp rax,[mp_end]
    ja mp_open_bad
    cmp word ptr [rsi],4449h
    jne mp_no_id3
    cmp byte ptr [rsi+2],'3'
    jne mp_no_id3
    movzx eax,byte ptr [rsi+3]
    cmp eax,2
    jb mp_open_bad
    cmp eax,4
    ja mp_open_bad
    cmp byte ptr [rsi+4],255
    je mp_open_bad
    mov edx,3fh
    cmp eax,2
    je id3_flags
    mov edx,1fh
    cmp eax,3
    je id3_flags
    mov edx,0fh
id3_flags:
    test byte ptr [rsi+5],dl
    jnz mp_open_bad
    mov r12,rsi
    xor ebx,ebx
    mov ecx,6
id3_size:
    movzx edx,byte ptr [rsi+rcx]
    test edx,80h
    jnz mp_open_bad
    shl ebx,7
    or ebx,edx
    inc ecx
    cmp ecx,10
    jb id3_size
    lea rsi,[rsi+rbx+10]
    cmp rsi,[mp_end]
    ja mp_open_bad
    test byte ptr [r12+5],10h
    jz id3_done
    lea rax,[rsi+10]
    cmp rax,[mp_end]
    ja mp_open_bad
    cmp word ptr [rsi],4433h
    jne mp_open_bad
    cmp byte ptr [rsi+2],'I'
    jne mp_open_bad
    mov eax,[rsi+3]
    cmp eax,[r12+3]
    jne mp_open_bad
    mov eax,[rsi+6]
    cmp eax,[r12+6]
    jne mp_open_bad
    add rsi,10
id3_done:
    mov [mp_cursor],rsi
mp_no_id3:
    mov rcx,rsi
    call mp_parse_header
    test eax,eax
    jz mp_open_bad
    mov eax,[mp_rate]
    mov [sample_rate],eax
    mov eax,[mp_channels]
    mov [source_channels],eax
    mov [mp_initial_channels],eax
    mov dword ptr [source_bits],0
    mov eax,[mp_version]
    mov [mp_initial_version],eax
    mov qword ptr [total_frames],0
    ; Detect a Xing/Info metadata frame before resetting synthesis/reservoir.
    mov eax,[mp_crc_bytes]
    add eax,[mp_side_bytes]
    lea rbx,[rsi+rax+4]
    lea rax,[rbx+8]
    cmp rax,[mp_frame_end]
    ja mp_open_ok
    cmp dword ptr [rbx],676e6958h
    je mp_xing
    cmp dword ptr [rbx],6f666e49h
    jne mp_open_ok
mp_xing:
    mov eax,[rbx+4]
    bswap eax
    mov [mp_xing_flags],eax
    mov dword ptr [mp_xing_count],0
    add rbx,8
    test eax,1
    jz xing_bytes
    lea rax,[rbx+4]
    cmp rax,[mp_frame_end]
    ja mp_open_bad
    mov eax,[rbx]
    bswap eax
    mov [mp_xing_count],eax
    add rbx,4
xing_bytes:
    test dword ptr [mp_xing_flags],2
    jz xing_toc
    add rbx,4
xing_toc:
    test dword ptr [mp_xing_flags],4
    jz xing_quality
    add rbx,100
xing_quality:
    test dword ptr [mp_xing_flags],8
    jz xing_lame
    add rbx,4
xing_lame:
    cmp rbx,[mp_frame_end]
    ja mp_open_bad
    lea rax,[rbx+36]
    cmp rax,[mp_frame_end]
    ja xing_done
    cmp byte ptr [rbx],0
    je xing_done
    movzx eax,byte ptr [rbx+21]
    shl eax,4
    movzx edx,byte ptr [rbx+22]
    mov ecx,edx
    shr ecx,4
    or eax,ecx
    add eax,529
    mov [mp_trim_start],eax
    and edx,15
    shl edx,8
    movzx eax,byte ptr [rbx+23]
    or edx,eax
    sub edx,529
    jns xing_pad_valid
    xor edx,edx
xing_pad_valid:
    mov [mp_trim_end],edx
xing_done:
    mov eax,[mp_xing_count]
    test eax,eax
    jz xing_skip
    mov ecx,[mp_samples]
    mul rcx
    mov ecx,[mp_trim_start]
    sub rax,rcx
    jc mp_open_bad
    mov ecx,[mp_trim_end]
    sub rax,rcx
    jc mp_open_bad
    mov [total_frames],rax
xing_skip:
    mov rax,[mp_frame_end]
    mov [mp_cursor],rax
mp_open_ok:
    mov rax,[mp_cursor]
    mov [mp_stream_begin],rax
    mov eax,[mp_trim_start]
    mov [mp_initial_trim],eax
    call mp_build_index
    test eax,eax
    jz mp_open_bad
    mov eax,1
    jmp mp_open_return
mp_open_bad:
    xor eax,eax
mp_open_return:
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp3_open ENDP

mp3_close PROC
    sub rsp,40
    mov rcx,[mp_index]
    mov qword ptr [mp_index],0
    mov dword ptr [mp3_index_count],0
    mov qword ptr [mp3_seek_headers],0
    test rcx,rcx
    jz mp_index_closed
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
mp_index_closed:
    add rsp,40
    ret
mp3_close ENDP

; Structural scan only: header/CRC, side information, part lengths and exact
; unused reservoir. Huffman, IMDCT and synthesis are deferred until playback.
; Each point occupies 544 bytes; compact alternate points on reaching the cap.
mp_build_index PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,48
    xor ecx,ecx
    mov edx,MP_INDEX_POINT*MP_INDEX_CAP
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    test rax,rax
    jz mp_index_optional
    mov [mp_index],rax
    mov qword ptr [mp3_index_stride],32
    xor r12d,r12d            ;compressed frame ordinal
    xor r13d,r13d            ;raw PCM sample count before this frame
mp_index_scan:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz mp_index_not_cancelled
    cmp dword ptr [rax],0
    jne mp_index_bad
mp_index_not_cancelled:
    mov rax,[mp_end]
    sub rax,[mp_cursor]
    jz mp_index_complete
    cmp rax,128
    jne mp_index_frame
    mov rax,[mp_cursor]
    cmp word ptr [rax],4154h
    jne mp_index_frame
    cmp byte ptr [rax+2],'G'
    je mp_index_complete
mp_index_frame:
    mov rax,[mp3_index_stride]
    dec rax
    test r12,rax
    jnz mp_index_skip
    cmp dword ptr [mp3_index_count],MP_INDEX_CAP
    jb mp_index_store
    ; Entries are multiples of 16 bytes, and the source always follows its
    ; destination. Keep 0,2,4,... then double the stride without growing memory.
    mov rbx,1
mp_index_compact:
    imul rax,rbx,MP_INDEX_POINT*2
    mov rsi,[mp_index]
    add rsi,rax
    imul rax,rbx,MP_INDEX_POINT
    mov rdi,[mp_index]
    add rdi,rax
    mov ecx,MP_INDEX_POINT/8
    rep movsq
    inc ebx
    cmp ebx,MP_INDEX_CAP/2
    jb mp_index_compact
    mov dword ptr [mp3_index_count],MP_INDEX_CAP/2
    shl qword ptr [mp3_index_stride],1
mp_index_store:
    mov eax,[mp3_index_count]
    imul rax,MP_INDEX_POINT
    add rax,[mp_index]
    mov rcx,[mp_cursor]
    mov [rax],rcx
    mov [rax+8],r13
    mov ecx,[mp_reserv_size]
    mov [rax+16],ecx
    lea rdi,[rax+20]
    lea rsi,mp_reserv
    rep movsb
    inc dword ptr [mp3_index_count]
mp_index_skip:
    call mp_skip_frame
    test eax,eax
    jz mp_index_bad
    mov eax,[mp_samples]
    add r13,rax
    inc r12
    jmp mp_index_scan
mp_index_complete:
    mov eax,[mp_initial_trim]
    sub r13,rax
    jc mp_index_bad
    mov eax,[mp_trim_end]
    sub r13,rax
    jc mp_index_bad
    cmp qword ptr [total_frames],0
    je mp_index_duration
    cmp r13,[total_frames]
    jne mp_index_bad
mp_index_duration:
    mov [total_frames],r13
mp_index_optional:
    mov rax,[mp_stream_begin]
    mov [mp_cursor],rax
    mov dword ptr [mp_reserv_size],0
    mov eax,1
    jmp mp_index_return
mp_index_bad:
    xor eax,eax
mp_index_return:
    add rsp,48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
mp_build_index ENDP

mp_skip_frame PROC
    push rbx
    sub rsp,32
    mov rcx,[mp_cursor]
    call mp_parse_header
    test eax,eax
    jz mp_skip_bad
    mov eax,[mp_version]
    cmp eax,[mp_initial_version]
    jne mp_skip_bad
    mov eax,[mp_rate]
    cmp eax,[sample_rate]
    jne mp_skip_bad
    mov eax,[mp_channels]
    cmp eax,[mp_initial_channels]
    jne mp_skip_bad
    call mp_sideinfo
    test eax,eax
    jz mp_skip_bad
    lea rdx,mp_info
    xor eax,eax
    xor ecx,ecx
mp_skip_parts:
    add eax,[rdx+GI_PART]
    add rdx,GI_SIZE
    inc ecx
    cmp ecx,[mp_gr_count]
    jb mp_skip_parts
    cmp eax,[mp_bit_limit]
    ja mp_skip_bad
    mov [mp_bit_pos],eax
    call mp_save_reservoir
    test eax,eax
    jz mp_skip_bad
    mov rax,[mp_frame_end]
    mov [mp_cursor],rax
    mov eax,1
    jmp mp_skip_return
mp_skip_bad:
    mov dword ptr [decode_error],15
    xor eax,eax
mp_skip_return:
    add rsp,32
    pop rbx
    ret
mp_skip_frame ENDP

; Fresh-open only. Resume at least two compressed frames before the target so
; ordinary reads reconstruct overlap/QMF exactly before returning target PCM.
mp3_seek PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,40
    xor eax,eax
    mov qword ptr [mp3_seek_headers],0
    test rcx,rcx
    jz mp_seek_return
    cmp dword ptr [mp3_index_count],0
    je mp_seek_return
    cmp rcx,[total_frames]
    cmova rcx,[total_frames]
    mov eax,[mp_initial_trim]
    add rcx,rax
    mov r12,rcx
    mov eax,[mp_samples]
    add rax,rax
    sub r12,rax
    jae mp_seek_warm_target
    xor r12d,r12d
mp_seek_warm_target:
    xor r8d,r8d
    mov r9d,[mp3_index_count]
mp_seek_search:
    cmp r8d,r9d
    jae mp_seek_found
    mov edx,r9d
    sub edx,r8d
    shr edx,1
    add edx,r8d
    imul eax,edx,MP_INDEX_POINT
    add rax,[mp_index]
    cmp [rax+8],r12
    ja mp_seek_upper
    lea r8d,[rdx+1]
    jmp mp_seek_search
mp_seek_upper:
    mov r9d,edx
    jmp mp_seek_search
mp_seek_found:
    dec r8d                 ;point zero always exists and is at raw sample0
    imul eax,r8d,MP_INDEX_POINT
    add rax,[mp_index]
    mov rcx,[rax]
    mov [mp_cursor],rcx
    mov rbx,[rax+8]
    mov ecx,[rax+16]
    mov [mp_reserv_size],ecx
    lea rsi,[rax+20]
    lea rdi,mp_reserv
    rep movsb
mp_seek_skip:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz mp_seek_not_cancelled
    cmp dword ptr [rax],0
    jne mp_seek_cancelled
mp_seek_not_cancelled:
    mov eax,[mp_samples]
    add rax,rbx
    cmp rax,r12
    ja mp_seek_position
    call mp_skip_frame
    test eax,eax
    jz mp_seek_cancelled
    mov eax,[mp_samples]
    add rbx,rax
    inc qword ptr [mp3_seek_headers]
    jmp mp_seek_skip
mp_seek_position:
    mov dword ptr [mp_frame_ready],0
    mov dword ptr [mp_frame_used],0
    mov eax,[mp_initial_trim]
    mov dword ptr [mp_trim_start],0
    cmp rbx,rax
    jae mp_seek_emitted
    sub eax,ebx
    mov [mp_trim_start],eax
    xor ebx,ebx
    jmp mp_seek_ready
mp_seek_emitted:
    sub rbx,rax
mp_seek_ready:
    mov [mp_emitted],rbx
    mov rax,rbx
    jmp mp_seek_return
mp_seek_cancelled:
    xor eax,eax
mp_seek_return:
    add rsp,40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
mp3_seek ENDP

; Header inspection. State is only committed after bounds/field validation.
mp_parse_header PROC
    push rbx
    sub rsp,32
    lea rax,[rcx+4]
    cmp rax,[mp_end]
    ja header_bad
    mov ebx,[rcx]
    bswap ebx
    mov eax,ebx
    and eax,0ffe00000h
    cmp eax,0ffe00000h
    jne header_bad
    mov eax,ebx
    shr eax,17
    and eax,3
    cmp eax,1
    jne header_bad
    mov eax,ebx
    shr eax,19
    and eax,3
    cmp eax,1
    je header_bad
    mov [mp_version],eax
    mov edx,ebx
    shr edx,10
    and edx,3
    cmp edx,3
    je header_bad
    lea r8,mp_rates
    mov r8d,[r8+rdx*4]
    cmp eax,3
    je header_mpeg1
    shr r8d,1
    cmp eax,2
    je header_mpeg2
    shr r8d,1
    cmp edx,0
    je header_sr_ready
    dec edx
    jmp header_sr_ready
header_mpeg2:
    add edx,2
    jmp header_sr_ready
header_mpeg1:
    add edx,5
header_sr_ready:
    mov [mp_sr_index],edx
    mov [mp_rate],r8d
    mov edx,ebx
    shr edx,12
    and edx,15
    test edx,edx
    jz header_bad          ; free format intentionally unsupported
    cmp edx,15
    je header_bad
    lea r9,bitrate2
    mov eax,72000
    mov dword ptr [mp_samples],576
    cmp dword ptr [mp_version],3
    jne header_bitrate
    lea r9,bitrate1
    mov eax,144000
    mov dword ptr [mp_samples],1152
header_bitrate:
    imul eax,[r9+rdx*4]
    xor edx,edx
    div r8d
    mov edx,ebx
    shr edx,9
    and edx,1
    add eax,edx
    mov [mp_frame_bytes],eax
    lea rax,[rcx+rax]
    cmp rax,[mp_end]
    ja header_bad
    mov [mp_frame_end],rax
    mov eax,ebx
    shr eax,6
    and eax,3
    mov dword ptr [mp_channels],2
    cmp eax,3
    jne header_stereo
    mov dword ptr [mp_channels],1
header_stereo:
    mov dword ptr [mp_ms],0
    mov dword ptr [mp_intensity],0
    cmp eax,1
    jne header_mode_done
    mov eax,ebx
    shr eax,4
    and eax,1
    mov [mp_intensity],eax
    mov eax,ebx
    shr eax,5
    and eax,1
    mov [mp_ms],eax
header_mode_done:
    mov eax,ebx
    shr eax,16
    and eax,1
    xor eax,1
    shl eax,1
    mov [mp_crc_bytes],eax
    mov edx,17
    cmp dword ptr [mp_version],3
    jne header_lsf_side
    cmp dword ptr [mp_channels],2
    jne header_side_ready
    mov edx,32
    jmp header_side_ready
header_lsf_side:
    cmp dword ptr [mp_channels],2
    je header_side_ready
    mov edx,9
header_side_ready:
    mov [mp_side_bytes],edx
    add eax,edx
    add eax,4
    cmp eax,[mp_frame_bytes]
    jae header_bad
    cmp dword ptr [mp_crc_bytes],0
    je header_crc_valid
    ; Layer III CRC: the final 16 header bits and complete side information.
    ; MSB first, initial FFFF, polynomial x^16+x^15+x^2+1.
    mov eax,0ffffh
    mov r8d,2
    mov r9d,4
header_crc_byte:
    movzx edx,byte ptr [rcx+r8]
    shl edx,8
    xor eax,edx
    mov r11d,8
header_crc_bit:
    mov edx,eax
    shl eax,1
    test edx,8000h
    jz header_crc_no_xor
    xor eax,8005h
header_crc_no_xor:
    dec r11d
    jnz header_crc_bit
    inc r8d
    cmp r8d,r9d
    jb header_crc_byte
    cmp r9d,4
    jne header_crc_compare
    mov r8d,6
    mov r9d,[mp_side_bytes]
    add r9d,6
    jmp header_crc_byte
header_crc_compare:
    movzx edx,word ptr [rcx+4]
    rol dx,8
    and eax,0ffffh
    cmp eax,edx
    jne header_bad
header_crc_valid:
    mov [mp_header],ebx
    mov eax,1
    jmp header_return
header_bad:
    xor eax,eax
header_return:
    add rsp,32
    pop rbx
    ret
mp_parse_header ENDP

; Safe bit reads, at most 24 bits per call. Peek zero-pads beyond the byte end
; for Huffman lookahead; actual consumed bits are checked against part limits.
mp_peek PROC
    mov r9d,ecx
    test ecx,ecx
    jz bits_zero
    mov r8d,[mp_bit_pos]
    mov r10d,r8d
    shr r10d,3
    and r8d,7
    mov r11,[mp_bit_base]
    mov eax,[mp_bit_limit]
    add eax,7
    shr eax,3
    mov edx,eax
    xor eax,eax
    mov ecx,4
peek_bytes:
    shl eax,8
    cmp r10d,edx
    jae peek_padding
    movzx r8d,byte ptr [r11+r10]
    or eax,r8d
peek_padding:
    inc r10d
    dec ecx
    jnz peek_bytes
    mov ecx,[mp_bit_pos]
    and ecx,7
    shl eax,cl
    mov ecx,32
    sub ecx,r9d
    shr eax,cl
    ret
bits_zero:
    xor eax,eax
    ret
mp_peek ENDP

mp_bits PROC
    sub rsp,40
    mov [rsp+32],ecx
    call mp_peek
    mov ecx,[rsp+32]
    add [mp_bit_pos],ecx
    mov ecx,[mp_bit_pos]
    cmp ecx,[mp_bit_limit]
    jbe bits_valid
    mov dword ptr [decode_error],11
bits_valid:
    add rsp,40
    ret
mp_bits ENDP

; Parse one complete side-information section and assemble main-data history.
mp_sideinfo PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    lea rdi,mp_info
    xor eax,eax
    mov ecx,GI_SIZE
    rep stosd
    mov rax,[mp_cursor]
    mov ecx,[mp_crc_bytes]
    lea rax,[rax+rcx+4]
    mov [mp_bit_base],rax
    mov eax,[mp_side_bytes]
    shl eax,3
    mov [mp_bit_limit],eax
    mov dword ptr [mp_bit_pos],0
    mov ecx,8
    mov eax,[mp_channels]
    mov [mp_gr_count],eax
    cmp dword ptr [mp_version],3
    jne side_lsf_begin
    inc ecx
    shl dword ptr [mp_gr_count],1
side_lsf_begin:
    call mp_bits
    mov [mp_main_begin],eax
    cmp dword ptr [mp_version],3
    jne side_lsf_private
    mov ecx,3
    cmp dword ptr [mp_channels],1
    jne side_private_read
    mov ecx,5
side_private_read:
    call mp_bits
    xor ebx,ebx
side_scfsi:
    mov ecx,4
    call mp_bits
    lea rdx,mp_scfsi
    mov [rdx+rbx*4],eax
    inc ebx
    cmp ebx,[mp_channels]
    jb side_scfsi
    jmp side_gr_start
side_lsf_private:
    mov ecx,[mp_channels]
    call mp_bits
side_gr_start:
    xor ebx,ebx
    lea rsi,mp_info
side_gr_loop:
    mov ecx,12
    call mp_bits
    mov [rsi+GI_PART],eax
    mov ecx,9
    call mp_bits
    cmp eax,288
    ja side_bad
    mov [rsi+GI_BIG],eax
    mov ecx,8
    call mp_bits
    mov [rsi+GI_GAIN],eax
    mov ecx,9
    cmp dword ptr [mp_version],3
    jne side_sfc_read
    mov ecx,4
side_sfc_read:
    call mp_bits
    mov [rsi+GI_SFC],eax
    mov dword ptr [rsi+GI_LONG],22
    mov eax,[mp_sr_index]
    imul eax,23
    lea rdx,mp_sfb_long
    add rdx,rax
    mov [rsi+GI_SFB],rdx
    mov ecx,1
    call mp_bits
    test eax,eax
    jz side_long
    mov ecx,2
    call mp_bits
    test eax,eax
    jz side_bad
    mov [rsi+GI_BLOCK],eax
    mov ecx,1
    call mp_bits
    mov [rsi+GI_MIX],eax
    mov byte ptr [rsi+GI_REGION],7
    mov byte ptr [rsi+GI_REGION+1],255
    cmp dword ptr [rsi+GI_BLOCK],2
    jne side_switch_tables
    mov eax,[mp_sr_index]
    imul eax,40
    lea rdx,mp_sfb_short
    mov dword ptr [rsi+GI_LONG],0
    mov dword ptr [rsi+GI_SHORT],39
    mov byte ptr [rsi+GI_REGION],8
    cmp dword ptr [rsi+GI_MIX],0
    je side_short_ready
    lea rdx,mp_sfb_mixed
    mov dword ptr [rsi+GI_LONG],6
    cmp dword ptr [mp_version],3
    jne side_mixed_lsf
    mov dword ptr [rsi+GI_LONG],8
side_mixed_lsf:
    mov dword ptr [rsi+GI_SHORT],30
    mov byte ptr [rsi+GI_REGION],7
side_short_ready:
    add rdx,rax
    mov [rsi+GI_SFB],rdx
side_switch_tables:
    mov ecx,5
    call mp_bits
    cmp eax,4
    je side_bad
    cmp eax,14
    je side_bad
    mov [rsi+GI_TABLE],al
    mov ecx,5
    call mp_bits
    cmp eax,4
    je side_bad
    cmp eax,14
    je side_bad
    mov [rsi+GI_TABLE+1],al
    xor edi,edi
side_subgain:
    mov ecx,3
    call mp_bits
    mov [rsi+rdi+GI_SUBGAIN],al
    inc edi
    cmp edi,3
    jb side_subgain
    jmp side_preflag
side_long:
    xor edi,edi
side_tables:
    mov ecx,5
    call mp_bits
    cmp eax,4
    je side_bad
    cmp eax,14
    je side_bad
    mov [rsi+rdi+GI_TABLE],al
    inc edi
    cmp edi,3
    jb side_tables
    mov ecx,4
    call mp_bits
    mov [rsi+GI_REGION],al
    mov ecx,3
    call mp_bits
    mov [rsi+GI_REGION+1],al
    mov byte ptr [rsi+GI_REGION+2],255
side_preflag:
    mov eax,[rsi+GI_SFC]
    cmp eax,500
    setae al
    movzx eax,al
    cmp dword ptr [mp_version],3
    jne side_pre_ready
    mov ecx,1
    call mp_bits
side_pre_ready:
    mov [rsi+GI_PRE],eax
    mov ecx,1
    call mp_bits
    mov [rsi+GI_SCALE],eax
    mov ecx,1
    call mp_bits
    mov [rsi+GI_COUNT],eax
    cmp dword ptr [mp_version],3
    jne side_no_scfsi
    cmp ebx,[mp_channels]
    jb side_next
    cmp dword ptr [rsi+GI_BLOCK],2
    je side_next
    mov eax,ebx
    sub eax,[mp_channels]
    lea rdx,mp_scfsi
    mov eax,[rdx+rax*4]
    mov [rsi+GI_SCFSI],eax
    jmp side_next
side_no_scfsi:
    mov dword ptr [rsi+GI_SCFSI],-16
side_next:
    inc ebx
    add rsi,GI_SIZE
    cmp ebx,[mp_gr_count]
    jb side_gr_loop
    cmp dword ptr [decode_error],0
    jne side_bad
    mov eax,[mp_main_begin]
    cmp eax,[mp_reserv_size]
    ja side_bad
    mov ecx,eax
    mov eax,[mp_reserv_size]
    sub eax,ecx
    lea rsi,mp_reserv
    add rsi,rax
    lea rdi,mp_main
    rep movsb
    mov rsi,[mp_bit_base]
    mov eax,[mp_side_bytes]
    add rsi,rax
    mov rax,[mp_frame_end]
    sub rax,rsi
    mov ecx,eax
    add eax,[mp_main_begin]
    cmp eax,4096
    ja side_bad
    mov [mp_main_bytes],eax
    rep movsb
    lea rax,mp_main
    mov [mp_bit_base],rax
    mov eax,[mp_main_bytes]
    shl eax,3
    mov [mp_bit_limit],eax
    mov dword ptr [mp_bit_pos],0
    mov eax,1
    jmp side_return
side_bad:
    mov dword ptr [decode_error],12
    xor eax,eax
side_return:
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_sideinfo ENDP

; RCX=granule info. Read and reuse scalefactors; create per-band gains.
mp_scalefactors PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp,64
    mov rsi,rcx
    mov eax,[rsi+GI_SCALE]
    inc eax
    mov [mp_scf_shift],eax
    mov eax,[rsi+GI_LONG]
    add eax,[rsi+GI_SHORT]
    mov [mp_scale_count],eax
    lea rdi,mp_iscf
    xor eax,eax
    mov ecx,40
    rep stosb
    mov eax,[mp_channel]
    imul eax,40
    lea r12,mp_ist
    add r12,rax
    mov ebx,[rsi+GI_SCFSI]
    mov eax,0
    cmp dword ptr [rsi+GI_SHORT],0
    setne al
    cmp dword ptr [rsi+GI_LONG],0
    jne sf_part_row
    inc eax
sf_part_row:
    imul eax,28
    lea r13,mp_partitions
    add r13,rax
    lea r14,mp_scf_sizes
    cmp dword ptr [mp_version],3
    jne sf_lsf
    mov eax,[rsi+GI_SFC]
    lea rdx,mp_scfc
    movzx eax,byte ptr [rdx+rax]
    mov ecx,eax
    shr eax,2
    and ecx,3
    mov [r14],eax
    mov [r14+4],eax
    mov [r14+8],ecx
    mov [r14+12],ecx
    jmp sf_read_groups
sf_lsf:
    mov r10d,[rsi+GI_SFC]
    xor r11d,r11d
    cmp dword ptr [mp_channel],0
    je lsf_mod_loop
    cmp dword ptr [mp_intensity],0
    je lsf_mod_loop
    shr r10d,1
    mov r11d,12
lsf_mod_loop:
    lea r8,mp_mod
    add r8,r11
    mov r9d,1
    mov edi,3
lsf_mod_digit:
    mov eax,r10d
    xor edx,edx
    div r9d
    movzx ecx,byte ptr [r8+rdi]
    xor edx,edx
    div ecx
    mov [r14+rdi*4],edx
    imul r9d,ecx
    dec edi
    jns lsf_mod_digit
    sub r10d,r9d
    add r11d,4
    test r10d,r10d
    jns lsf_mod_loop
    add r13,r11
sf_read_groups:
    lea rdi,mp_iscf
    xor r14d,r14d
sf_group:
    cmp r14d,4
    jae sf_post
    movzx eax,byte ptr [r13+r14]
    test eax,eax
    jz sf_post
    mov [rsp+32],eax
    test ebx,8
    jnz sf_reuse
    lea rdx,mp_scf_sizes
    mov eax,[rdx+r14*4]
    mov [rsp+36],eax
    xor r9d,r9d
sf_values:
    mov [rsp+40],r9d
    mov ecx,[rsp+36]
    call mp_bits
    mov r9d,[rsp+40]
    mov [rdi+r9],al
    mov edx,eax
    cmp ebx,0
    jge sf_ist_store
    cmp dword ptr [rsp+36],0
    je sf_ist_store
    mov ecx,[rsp+36]
    mov eax,1
    shl eax,cl
    dec eax
    cmp edx,eax
    jne sf_ist_store
    mov edx,255
sf_ist_store:
    mov [r12+r9],dl
    inc r9d
    cmp r9d,[rsp+32]
    jb sf_values
    jmp sf_group_done
sf_reuse:
    xor eax,eax
sf_reuse_loop:
    mov dl,[r12+rax]
    mov [rdi+rax],dl
    inc eax
    cmp eax,[rsp+32]
    jb sf_reuse_loop
sf_group_done:
    mov eax,[rsp+32]
    add rdi,rax
    add r12,rax
    shl ebx,1
    inc r14d
    jmp sf_group
sf_post:
    cmp dword ptr [rsi+GI_SHORT],0
    je sf_preemphasis
    mov ebx,[rsi+GI_LONG]
    mov edi,[rsi+GI_SHORT]
    add edi,ebx
    lea r12,mp_iscf
sf_subblocks:
    cmp ebx,edi
    jae sf_gain_start
    xor r13d,r13d
sf_subblock_gain:
    movzx eax,byte ptr [rsi+r13+GI_SUBGAIN]
    mov ecx,3
    sub ecx,[mp_scf_shift]
    shl eax,cl
    add [r12+rbx],al
    inc ebx
    inc r13d
    cmp r13d,3
    jb sf_subblock_gain
    jmp sf_subblocks
sf_preemphasis:
    cmp dword ptr [rsi+GI_PRE],0
    je sf_gain_start
    lea r12,mp_iscf
    lea r13,mp_preamp
    xor ebx,ebx
sf_preloop:
    mov al,[r13+rbx]
    add [r12+rbx+11],al
    inc ebx
    cmp ebx,10
    jb sf_preloop
sf_gain_start:
    xor ebx,ebx
    lea r12,mp_iscf
    lea r13,mp_scales
    lea r14,mp_gain
sf_gain_loop:
    cmp ebx,[mp_scale_count]
    jae sf_done
    movzx edx,byte ptr [r12+rbx]
    mov ecx,[mp_scf_shift]
    shl edx,cl
    mov eax,[rsi+GI_GAIN]
    sub eax,214
    sub eax,edx
    mov edx,[mp_ms]
    shl edx,1
    sub eax,edx
    add eax,800
    cmp eax,mp_gain_count
    jae sf_bad
    mov eax,[r14+rax*4]
    mov [r13+rbx*4],eax
    inc ebx
    jmp sf_gain_loop
sf_bad:
    mov dword ptr [decode_error],13
sf_done:
    add rsp,64
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_scalefactors ENDP

; RCX=granule info, RDX=spectrum. Bounds-checked Huffman pairs and quads.
mp_huffman PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp,96
    mov rsi,rcx
    mov rdi,rdx
    mov r12,[rsi+GI_SFB]
    xor ebx,ebx               ; spectral sample index
    xor r13d,r13d             ; scale band index
    xor r14d,r14d             ; region index
    mov dword ptr [rsp+32],0 ; pair index
    mov dword ptr [rsp+36],0 ; band sample end
    movzx eax,byte ptr [rsi+GI_REGION]
    inc eax
    mov [rsp+40],eax         ; exclusive region end in scale bands
huff_pair:
    mov eax,[rsp+32]
    cmp eax,[rsi+GI_BIG]
    jae huff_quads
    cmp ebx,[rsp+36]
    jb huff_band_ready
    cmp r13d,[mp_scale_count]
    jae huff_bad
    movzx eax,byte ptr [r12+r13]
    test eax,eax
    jz huff_bad
    add [rsp+36],eax
    cmp r13d,[rsp+40]
    jb huff_same_region
    inc r14d
    cmp r14d,3
    jae huff_bad
    movzx eax,byte ptr [rsi+r14+GI_REGION]
    inc eax
    add [rsp+40],eax
huff_same_region:
    lea rax,mp_scales
    mov eax,[rax+r13*4]
    mov [rsp+44],eax
    inc r13d
huff_band_ready:
    movzx eax,byte ptr [rsi+r14+GI_TABLE]
    lea rdx,mp_huff_linbits
    movzx edx,byte ptr [rdx+rax]
    mov [rsp+48],edx
    lea rdx,mp_huff_index
    movzx eax,word ptr [rdx+rax*2]
    lea rdx,mp_huff_tabs
    lea rdx,[rdx+rax*2]
    mov [rsp+56],rdx
    mov dword ptr [rsp+64],5
    mov ecx,5
    call mp_peek
    mov rdx,[rsp+56]
    movsx eax,word ptr [rdx+rax*2]
huff_tree:
    test eax,eax
    jns huff_leaf
    mov [rsp+68],eax
    mov ecx,[rsp+64]
    call mp_bits
    mov eax,[rsp+68]
    mov ecx,eax
    and ecx,7
    mov [rsp+64],ecx
    sar eax,3
    neg eax
    mov [rsp+72],eax
    call mp_peek
    add eax,[rsp+72]
    mov rdx,[rsp+56]
    lea rdx,[rdx+rax*2]
    lea rax,mp_huff_index
    cmp rdx,rax
    jae huff_bad
    movsx eax,word ptr [rdx]
    jmp huff_tree
huff_leaf:
    mov [rsp+68],eax
    mov ecx,eax
    shr ecx,8
    call mp_bits
    mov dword ptr [rsp+76],0
huff_pair_values:
    mov eax,[rsp+68]
    and eax,15
    mov [rsp+80],eax
    cmp eax,15
    jne huff_sign
    mov ecx,[rsp+48]
    call mp_bits
    add [rsp+80],eax
huff_sign:
    mov dword ptr [rsp+84],0
    cmp dword ptr [rsp+80],0
    je huff_dequant
    mov ecx,1
    call mp_bits
    shl eax,31
    mov [rsp+84],eax
huff_dequant:
    mov eax,[rsp+80]
    cmp eax,mp_pow43_count
    jae huff_bad
    lea rdx,mp_pow43
    movss xmm0,dword ptr [rdx+rax*4]
    mulss xmm0,dword ptr [rsp+44]
    movd eax,xmm0
    xor eax,[rsp+84]
    mov [rdi+rbx*4],eax
    inc ebx
    shr dword ptr [rsp+68],4
    inc dword ptr [rsp+76]
    cmp dword ptr [rsp+76],2
    jb huff_pair_values
    mov eax,[mp_bit_pos]
    cmp eax,[mp_part_limit]
    ja huff_bad
    inc dword ptr [rsp+32]
    jmp huff_pair
huff_quads:
    cmp ebx,572
    ja huff_done
    mov eax,[mp_bit_pos]
    cmp eax,[mp_part_limit]
    jae huff_done
    mov [rsp+88],eax
    lea rdx,mp_count32
    cmp dword ptr [rsi+GI_COUNT],0
    je quad_table
    lea rdx,mp_count33
quad_table:
    mov [rsp+56],rdx
    mov ecx,4
    call mp_peek
    mov rdx,[rsp+56]
    movzx eax,byte ptr [rdx+rax]
    test eax,8
    jnz quad_leaf
    mov [rsp+68],eax
    mov ecx,4
    call mp_peek             ; consume 4-bit prefix for extended table lookup
    mov eax,[mp_bit_pos]
    add eax,4
    mov [mp_bit_pos],eax
    mov ecx,[rsp+68]
    and ecx,3
    call mp_peek
    sub dword ptr [mp_bit_pos],4
    mov ecx,[rsp+68]
    shr ecx,3
    add eax,ecx
    mov rdx,[rsp+56]
    movzx eax,byte ptr [rdx+rax]
quad_leaf:
    mov [rsp+68],eax
    mov ecx,eax
    and ecx,7
    call mp_bits
    mov eax,[mp_bit_pos]
    cmp eax,[mp_part_limit]
    ja huff_quad_abort
    mov dword ptr [rsp+76],0
quad_values:
    cmp ebx,[rsp+36]
    jb quad_band_ready
    cmp r13d,[mp_scale_count]
    jae huff_quad_abort
    movzx eax,byte ptr [r12+r13]
    add [rsp+36],eax
    lea rdx,mp_scales
    mov eax,[rdx+r13*4]
    mov [rsp+44],eax
    inc r13d
quad_band_ready:
    mov ecx,[rsp+76]
    mov eax,128
    shr eax,cl
    test eax,[rsp+68]
    jz quad_zero
    mov ecx,1
    call mp_bits
    shl eax,31
    xor eax,[rsp+44]
    jmp quad_store
quad_zero:
    xor eax,eax
quad_store:
    mov [rdi+rbx*4],eax
    inc ebx
    inc dword ptr [rsp+76]
    cmp dword ptr [rsp+76],4
    jb quad_values
    mov eax,[mp_bit_pos]
    cmp eax,[mp_part_limit]
    jbe huff_quads
    ; Incomplete terminal quad is stuffing, discard all four values.
    sub ebx,4
    xor eax,eax
    mov [rdi+rbx*4],eax
    mov [rdi+rbx*4+4],eax
    mov [rdi+rbx*4+8],eax
    mov [rdi+rbx*4+12],eax
huff_quad_abort:
    mov dword ptr [decode_error],0
huff_done:
    mov eax,[mp_part_limit]
    mov [mp_bit_pos],eax
    jmp huff_return
huff_bad:
    mov dword ptr [decode_error],14
huff_return:
    add rsp,96
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_huffman ENDP

; Joint stereo processing, including MPEG-1 and LSF intensity bands.
mp_stereo PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    cmp dword ptr [mp_channels],2
    jne stereo_done
    cmp dword ptr [mp_intensity],0
    jne stereo_intensity
    cmp dword ptr [mp_ms],0
    je stereo_done
    lea rsi,mp_grbuf
    lea rdi,mp_grbuf+576*4
    mov ecx,144
stereo_ms_loop:
    movups xmm0,[rsi]
    movups xmm1,[rdi]
    movaps xmm2,xmm0
    addps xmm0,xmm1
    subps xmm2,xmm1
    movups [rsi],xmm0
    movups [rdi],xmm2
    add rsi,16
    add rdi,16
    dec ecx
    jnz stereo_ms_loop
    jmp stereo_done
stereo_intensity:
    mov eax,[mp_granule]
    imul eax,GI_SIZE
    lea r12,mp_info
    add r12,rax
    mov rsi,[r12+GI_SFB]
    mov eax,[r12+GI_LONG]
    add eax,[r12+GI_SHORT]
    mov [rsp+32],eax
    mov dword ptr [mp_max_band],-1
    mov dword ptr [mp_max_band+4],-1
    mov dword ptr [mp_max_band+8],-1
    lea rdi,mp_grbuf+576*4
    xor ebx,ebx
stereo_scan_band:
    cmp ebx,[rsp+32]
    jae stereo_scan_done
    movzx ecx,byte ptr [rsi+rbx]
    xor eax,eax
stereo_scan_samples:
    cmp eax,ecx
    jae stereo_scan_next
    mov edx,[rdi+rax*4]
    and edx,7fffffffh
    jnz stereo_band_nonzero
    inc eax
    jmp stereo_scan_samples
stereo_band_nonzero:
    mov eax,ebx
    xor edx,edx
    mov r8d,3
    div r8d
    lea rax,mp_max_band
    mov [rax+rdx*4],ebx
stereo_scan_next:
    lea rdi,[rdi+rcx*4]
    inc ebx
    jmp stereo_scan_band
stereo_scan_done:
    cmp dword ptr [r12+GI_LONG],0
    je stereo_top_short
    mov eax,[mp_max_band]
    cmp eax,[mp_max_band+4]
    cmovl eax,[mp_max_band+4]
    cmp eax,[mp_max_band+8]
    cmovl eax,[mp_max_band+8]
    mov [mp_max_band],eax
    mov [mp_max_band+4],eax
    mov [mp_max_band+8],eax
stereo_top_short:
    mov edi,1
    cmp dword ptr [r12+GI_SHORT],0
    je stereo_top_count
    mov edi,3
stereo_top_count:
    xor ebx,ebx
stereo_top_loop:
    mov ecx,[rsp+32]
    sub ecx,edi
    add ecx,ebx
    mov eax,ecx
    sub eax,edi
    lea rdx,mp_max_band
    cmp [rdx+rbx*4],eax
    jge stereo_top_default
    lea rdx,mp_ist+40
    mov al,[rdx+rax]
    jmp stereo_top_set
stereo_top_default:
    xor eax,eax
    cmp dword ptr [mp_version],3
    jne stereo_top_set
    mov eax,3
stereo_top_set:
    lea rdx,mp_ist+40
    mov [rdx+rcx],al
    inc ebx
    cmp ebx,edi
    jb stereo_top_loop
    xor ebx,ebx
    lea rdi,mp_grbuf
stereo_process_band:
    cmp ebx,[rsp+32]
    jae stereo_done
    movzx eax,byte ptr [rsi+rbx]
    mov [rsp+36],eax
    mov eax,ebx
    xor edx,edx
    mov ecx,3
    div ecx
    lea rax,mp_max_band
    cmp ebx,[rax+rdx*4]
    jle stereo_band_ms
    lea rax,mp_ist+40
    movzx eax,byte ptr [rax+rbx]
    mov ecx,64
    cmp dword ptr [mp_version],3
    jne stereo_position_check
    mov ecx,7
stereo_position_check:
    cmp eax,ecx
    jae stereo_band_ms
    movss xmm0,dword ptr [one_float]
    movss xmm1,dword ptr [one_float]
    cmp dword ptr [mp_version],3
    jne stereo_lsf_pan
    lea rdx,mp_pan
    movss xmm0,dword ptr [rdx+rax*8]
    movss xmm1,dword ptr [rdx+rax*8+4]
    jmp stereo_pan_scale
stereo_lsf_pan:
    mov ecx,eax
    inc ecx
    shr ecx,1
    mov edx,[r12+GI_SIZE+GI_SFC]
    and edx,1
    xchg ecx,edx
    shl edx,cl
    mov ecx,800
    sub ecx,edx
    lea rdx,mp_gain
    movss xmm1,dword ptr [rdx+rcx*4]
    test eax,1
    jz stereo_pan_scale
    movaps xmm0,xmm1
    movss xmm1,dword ptr [one_float]
stereo_pan_scale:
    cmp dword ptr [mp_ms],0
    je stereo_pan_loop_start
    mulss xmm0,dword ptr [sqrt_two]
    mulss xmm1,dword ptr [sqrt_two]
stereo_pan_loop_start:
    xor ecx,ecx
stereo_pan_loop:
    cmp ecx,[rsp+36]
    jae stereo_band_next
    movss xmm2,dword ptr [rdi+rcx*4]
    movaps xmm3,xmm2
    mulss xmm2,xmm0
    mulss xmm3,xmm1
    movss dword ptr [rdi+rcx*4],xmm2
    movss dword ptr [rdi+rcx*4+576*4],xmm3
    inc ecx
    jmp stereo_pan_loop
stereo_band_ms:
    cmp dword ptr [mp_ms],0
    je stereo_band_next
    xor ecx,ecx
stereo_ms_band:
    cmp ecx,[rsp+36]
    jae stereo_band_next
    movss xmm0,dword ptr [rdi+rcx*4]
    movss xmm1,dword ptr [rdi+rcx*4+576*4]
    movaps xmm2,xmm0
    addss xmm0,xmm1
    subss xmm2,xmm1
    movss dword ptr [rdi+rcx*4],xmm0
    movss dword ptr [rdi+rcx*4+576*4],xmm2
    inc ecx
    jmp stereo_ms_band
stereo_band_next:
    mov eax,[rsp+36]
    lea rdi,[rdi+rax*4]
    inc ebx
    jmp stereo_process_band
stereo_done:
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_stereo ENDP

mp_spectral_finish PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    mov r12,rcx            ; granule info
    mov rbx,rdx           ; spectrum
    mov eax,0
    cmp dword ptr [r12+GI_MIX],0
    je finish_long_count
    mov eax,2
    cmp dword ptr [mp_sr_index],1
    jne finish_long_count
    mov eax,4
finish_long_count:
    mov [rsp+32],eax
    mov dword ptr [rsp+36],31
    cmp dword ptr [r12+GI_SHORT],0
    je finish_alias
    dec eax
    mov [rsp+36],eax
    mov eax,[rsp+32]
    imul eax,18*4
    lea rsi,[rbx+rax]
    mov [rsp+40],rsi
    lea rdi,mp_temp
    mov r8,[r12+GI_SFB]
    mov eax,[r12+GI_LONG]
    add r8,rax
reorder_band:
    movzx ecx,byte ptr [r8]
    test ecx,ecx
    jz reorder_copy
    xor eax,eax
reorder_samples:
    mov edx,[rsi+rax*4]
    mov [rdi],edx
    mov r9d,eax
    add r9d,ecx
    mov edx,[rsi+r9*4]
    mov [rdi+4],edx
    add r9d,ecx
    mov edx,[rsi+r9*4]
    mov [rdi+8],edx
    add rdi,12
    inc eax
    cmp eax,ecx
    jb reorder_samples
    imul ecx,12
    add rsi,rcx
    add r8,3
    jmp reorder_band
reorder_copy:
    lea rsi,mp_temp
    sub rdi,rsi
    mov rcx,rdi
    shr rcx,2
    mov rdi,[rsp+40]
    rep movsd
finish_alias:
    mov rsi,rbx
    mov edx,[rsp+36]
alias_band:
    test edx,edx
    jle finish_hybrid
    xor ecx,ecx
    lea r8,mp_aa
alias_pair:
    mov eax,17
    sub eax,ecx
    movss xmm0,dword ptr [rsi+rcx*4+72]
    movss xmm1,dword ptr [rsi+rax*4]
    movaps xmm2,xmm0
    movaps xmm3,xmm1
    mulss xmm0,dword ptr [r8+rcx*4]
    mulss xmm1,dword ptr [r8+rcx*4+32]
    subss xmm0,xmm1
    mulss xmm2,dword ptr [r8+rcx*4+32]
    mulss xmm3,dword ptr [r8+rcx*4]
    addss xmm2,xmm3
    movss dword ptr [rsi+rcx*4+72],xmm0
    movss dword ptr [rsi+rax*4],xmm2
    inc ecx
    cmp ecx,8
    jb alias_pair
    add rsi,72
    dec edx
    jmp alias_band
finish_hybrid:
    mov rcx,rbx
    mov rdx,r12
    mov eax,[mp_channel]
    imul eax,288*4
    lea r8,mp_overlap
    add r8,rax
    mov r9d,[rsp+32]
    call mp_hybrid
    ; Frequency inversion in odd subbands at odd time samples.
    mov edx,1
invert_band:
    imul eax,edx,72
    lea rsi,[rbx+rax]
    mov ecx,1
invert_time:
    xor dword ptr [rsi+rcx*4],80000000h
    add ecx,2
    cmp ecx,18
    jb invert_time
    add edx,2
    cmp edx,32
    jb invert_band
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_spectral_finish ENDP

mp_decode_frame PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    mov rcx,[mp_cursor]
    cmp rcx,[mp_end]
    jae mp_frame_eof
    mov rax,[mp_end]
    sub rax,rcx
    cmp rax,128
    jne mp_frame_header
    cmp word ptr [rcx],4154h
    jne mp_frame_header
    cmp byte ptr [rcx+2],'G'
    je mp_frame_eof
mp_frame_header:
    call mp_parse_header
    test eax,eax
    jz mp_frame_bad
    mov eax,[mp_version]
    cmp eax,[mp_initial_version]
    jne mp_frame_bad
    mov eax,[mp_rate]
    cmp eax,[sample_rate]
    jne mp_frame_bad
    mov eax,[mp_channels]
    cmp eax,[mp_initial_channels]
    jne mp_frame_bad
    call mp_sideinfo
    test eax,eax
    jz mp_frame_bad
    mov dword ptr [mp_granule],0
granule_loop:
    lea rdi,mp_grbuf
    xor eax,eax
    mov ecx,1152
    rep stosd
    mov dword ptr [mp_channel],0
granule_channel:
    mov eax,[mp_granule]
    add eax,[mp_channel]
    imul eax,GI_SIZE
    lea r12,mp_info
    add r12,rax
    mov eax,[mp_bit_pos]
    add eax,[r12+GI_PART]
    cmp eax,[mp_bit_limit]
    ja mp_frame_bad
    mov [mp_part_limit],eax
    mov rcx,r12
    call mp_scalefactors
    cmp dword ptr [decode_error],0
    jne mp_frame_bad
    mov eax,[mp_bit_pos]
    cmp eax,[mp_part_limit]
    ja mp_frame_bad
    mov eax,[mp_channel]
    imul eax,576*4
    lea rdx,mp_grbuf
    add rdx,rax
    mov rcx,r12
    call mp_huffman
    cmp dword ptr [decode_error],0
    jne mp_frame_bad
    inc dword ptr [mp_channel]
    mov eax,[mp_channel]
    cmp eax,[mp_channels]
    jb granule_channel
    call mp_stereo
    mov dword ptr [mp_channel],0
granule_hybrid:
    mov eax,[mp_granule]
    add eax,[mp_channel]
    imul eax,GI_SIZE
    lea rcx,mp_info
    add rcx,rax
    mov eax,[mp_channel]
    imul eax,576*4
    lea rdx,mp_grbuf
    add rdx,rax
    call mp_spectral_finish
    inc dword ptr [mp_channel]
    mov eax,[mp_channel]
    cmp eax,[mp_channels]
    jb granule_hybrid
    mov eax,[mp_granule]
    xor edx,edx
    div dword ptr [mp_channels]
    imul eax,576*8
    lea rcx,mp_pcm
    add rcx,rax
    mov edx,[mp_channels]
    call mp_synthesis
    mov eax,[mp_channels]
    add [mp_granule],eax
    mov eax,[mp_granule]
    cmp eax,[mp_gr_count]
    jb granule_loop
    call mp_save_reservoir
    test eax,eax
    jz mp_frame_bad
    mov rax,[mp_frame_end]
    mov [mp_cursor],rax
    mov eax,[mp_samples]
    mov [mp_frame_ready],eax
    mov dword ptr [mp_frame_used],0
    mov eax,1
    jmp mp_frame_return
mp_frame_bad:
    cmp dword ptr [decode_error],0
    jne mp_frame_eof
    mov dword ptr [decode_error],15
mp_frame_eof:
    xor eax,eax
mp_frame_return:
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp_decode_frame ENDP

; Shared by complete decoding and structural index scans. Part lengths fix
; the final bit position independently of Huffman/synthesis work.
mp_save_reservoir PROC
    push rsi
    push rdi
    ; Preserve only unused, whole bytes, capped at the MPEG-1 511-byte history.
    mov eax,[mp_bit_pos]
    add eax,7
    shr eax,3
    mov ecx,[mp_main_bytes]
    sub ecx,eax
    js mp_save_bad
    cmp ecx,511
    jbe reservoir_ready
    mov edx,ecx
    sub edx,511
    add eax,edx
    mov ecx,511
reservoir_ready:
    mov [mp_reserv_size],ecx
    lea rsi,mp_main
    add rsi,rax
    lea rdi,mp_reserv
    rep movsb
    mov eax,1
    jmp mp_save_return
mp_save_bad:
    xor eax,eax
mp_save_return:
    pop rdi
    pop rsi
    ret
mp_save_reservoir ENDP

mp3_read PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,48
    mov rdi,rcx
    mov r12d,edx
    xor ebx,ebx
mp_read_loop:
    cmp ebx,r12d
    jae mp_read_done
    cmp dword ptr [decode_error],0
    jne mp_read_done
    mov rax,[total_frames]
    test rax,rax
    jz mp_read_available
    cmp [mp_emitted],rax
    jae mp_read_done
mp_read_available:
    mov eax,[mp_frame_used]
    cmp eax,[mp_frame_ready]
    jb mp_read_frame
    call mp_decode_frame
    test eax,eax
    jz mp_read_done
mp_read_frame:
    mov eax,[mp_frame_used]
    cmp dword ptr [mp_trim_start],0
    je mp_read_emit
    dec dword ptr [mp_trim_start]
    inc dword ptr [mp_frame_used]
    jmp mp_read_loop
mp_read_emit:
    lea rsi,mp_pcm
    mov rdx,[rsi+rax*8]
    mov [rdi+rbx*8],rdx
    inc dword ptr [mp_frame_used]
    inc qword ptr [mp_emitted]
    inc ebx
    jmp mp_read_loop
mp_read_done:
    mov eax,ebx
    add rsp,48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
mp3_read ENDP
END
