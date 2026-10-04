; Original bounded Ogg/Opus families0/1 playback bridge. MIT, see LICENSE.
; RFC7845 header placement,48kHz granules,gain,pre-skip and end trimming.
; Connected codec algorithms retain BSD notices in THIRD_PARTY_NOTICES.
option casemap:none
include opus_mode_layout.inc
include opus_stream_layout.inc
EXTERN opus_headers:PROC,op_opus_multistream_parse:PROC,op_opus_decoder_init:PROC
EXTERN op_opus_decode_packet:PROC,op_opus_decode_packet_ex:PROC,op_celt_exp2:PROC
EXTERN ogg_next:PROC
EXTERN ogg_checkpoint:PROC,ogg_resume:PROC,ogg_cancel_ptr:QWORD
EXTERN VirtualAlloc:PROC,VirtualFree:PROC
EXTERN ogg_packet_last:DWORD,ogg_eos:DWORD,ogg_granule:QWORD
EXTERN op_preskip:DWORD,op_gain:DWORD,op_packet_samples:DWORD
EXTERN op_mapping:DWORD,op_streams:DWORD,op_coupled:DWORD,op_channel_map:BYTE,op_packet_bytes:DWORD
EXTERN sample_rate:DWORD,source_channels:DWORD,source_bits:DWORD
EXTERN total_frames:QWORD,decode_error:DWORD
PUBLIC opus_open,opus_read,opus_close,opus_seek
PUBLIC opus_index_count,opus_index_stride,opus_seek_headers,opus_seek_raw
OB_INDEX_CAP EQU 2048
OB_INDEX_POINT EQU 32
OB_PREROLL EQU 3840
.const
ob_db_exp real8 0.00064881407907956296 ;log2(10)/(20*256)
; RFC7845 Figures4-9, exact coefficient formulae rounded to double.
; Family1 uses Vorbis speaker order. Mono duplicates; stereo passes through.
; Double coefficients/accumulators retain accuracy when large finite decoded
; channels cancel. Round to the stereo float ABI only after all streams mix.
; Each128-byte row contains eight pairs of left/right output weights.
ob_matrix LABEL REAL8
    real8 1.00000000000000,1.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;1 channels
    real8 1.00000000000000,0.00000000000000,0.00000000000000,1.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;2 channels
    real8 0.585786437626905,0.00000000000000,0.414213562373095,0.414213562373095,0.00000000000000,0.585786437626905,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;3 channels
    real8 0.422649730810374,0.00000000000000,0.00000000000000,0.422649730810374,0.366025403784439,0.211324865405187,0.211324865405187,0.366025403784439,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;4 channels
    real8 0.650801813791450,0.00000000000000,0.460186375740439,0.460186375740439,0.00000000000000,0.650801813791450,0.563610903572386,0.325400906895725,0.325400906895725,0.563610903572386,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;5 channels
    real8 0.529067082241344,0.00000000000000,0.374106921555435,0.374106921555435,0.00000000000000,0.529067082241344,0.458185533527114,0.264533541120672,0.264533541120672,0.458185533527114,0.374106921555435,0.374106921555435,0.00000000000000,0.00000000000000,0.00000000000000,0.00000000000000 ;6 channels
    real8 0.455310023362449,0.00000000000000,0.321952805061793,0.321952805061793,0.00000000000000,0.455310023362449,0.394310046829567,0.227655011681225,0.227655011681225,0.394310046829567,0.278819308003172,0.278819308003172,0.321952805061793,0.321952805061793,0.00000000000000,0.00000000000000 ;7 channels
    real8 0.388631414212121,0.00000000000000,0.274803908371509,0.274803908371509,0.00000000000000,0.388631414212121,0.336564677416370,0.194315707106061,0.194315707106061,0.336564677416370,0.336564677416370,0.194315707106061,0.194315707106061,0.336564677416370,0.274803908371509,0.274803908371509 ;8 channels
.data
ob_active dd 0
ob_available dd 0
ob_used dd 0
ob_eof dd 0
ob_gain real4 1.0
ob_end_sample dq 0
ob_decoded dq 0
ob_index dq 0
ob_states dq 0
opus_index_count dd 0
opus_index_stride dq 16
opus_seek_headers dq 0
opus_seek_raw dq 0
.data?
ALIGN 16
ob_audio_checkpoint dq 2 dup (?)
ob_scan_checkpoint dq 2 dup (?)
ob_seek_checkpoint dq 2 dup (?)
ob_state db MO_SIZE dup (?)
ob_work db MW_SIZE dup (?)
ob_pcm real4 11520 dup (?)
ob_mix real4 11520 dup (?)
ob_mix_acc real8 11520 dup (?)
ob_coeff real8 1020 dup (?) ;255 streams * two channels * stereo weights
.code
opus_close PROC
    sub rsp,40
    mov rcx,[ob_states]
    test rcx,rcx
    jz ob_close_index
    lea rax,ob_state
    cmp rcx,rax
    je ob_close_states
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
ob_close_states:
    mov qword ptr [ob_states],0
ob_close_index:
    mov rcx,[ob_index]
    test rcx,rcx
    jz ob_close_reset
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
    mov qword ptr [ob_index],0
ob_close_reset:
    mov dword ptr [opus_index_count],0
    mov qword ptr [opus_seek_headers],0
    mov qword ptr [opus_seek_raw],0
    mov dword ptr [ob_active],0
    mov dword ptr [ob_available],0
    mov dword ptr [ob_used],0
    mov dword ptr [ob_eof],0
    mov qword ptr [ob_decoded],0
    add rsp,40
    ret
opus_close ENDP

; RCX=mapped start,RDX=end. Complete structural/duration scan before output.
opus_open PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,64
    mov rsi,rcx
    mov rdi,rdx
    call opus_close
    mov rcx,rsi
    mov rdx,rdi
    call opus_headers
    test eax,eax
    jz ob_open_bad
    lea rcx,ob_audio_checkpoint
    call ogg_checkpoint
    xor ecx,ecx
    mov edx,OB_INDEX_CAP*OB_INDEX_POINT
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    mov [ob_index],rax       ;allocation failure retains sequential decoding
    mov qword ptr [opus_index_stride],16
    xor ebx,ebx             ;first completed audio page seen
    xor r12d,r12d           ;raw samples in complete packets
    xor r13d,r13d           ;initial granule offset
    xor r14d,r14d           ;audio packet ordinal
ob_scan_packet:
    lea rcx,ob_scan_checkpoint
    call ogg_checkpoint
    call ogg_next
    test rax,rax
    jz ob_open_bad          ;EOS must belong to a completed audio packet
    mov rcx,rax
    call op_opus_multistream_parse
    test eax,eax
    jz ob_open_bad
    cmp qword ptr [ob_index],0
    je ob_scan_duration
    mov rax,[opus_index_stride]
    dec rax
    test r14,rax
    jnz ob_scan_duration
    cmp dword ptr [opus_index_count],OB_INDEX_CAP
    jb ob_scan_store
    mov r15d,1
ob_scan_compact:
    mov rsi,r15
    shl rsi,6
    add rsi,[ob_index]
    mov rdi,r15
    shl rdi,5
    add rdi,[ob_index]
    mov ecx,4
    rep movsq
    inc r15d
    cmp r15d,OB_INDEX_CAP/2
    jb ob_scan_compact
    mov dword ptr [opus_index_count],OB_INDEX_CAP/2
    shl qword ptr [opus_index_stride],1
ob_scan_store:
    mov eax,[opus_index_count]
    shl eax,5
    add rax,[ob_index]
    mov rcx,[ob_scan_checkpoint]
    mov [rax],rcx
    mov rcx,[ob_scan_checkpoint+8]
    mov [rax+8],rcx
    mov [rax+16],r12
    mov [rax+24],r14
    inc dword ptr [opus_index_count]
ob_scan_duration:
    inc r14
    mov eax,[op_packet_samples]
    add r12,rax
    jo ob_open_bad
    cmp dword ptr [ogg_packet_last],1
    jne ob_scan_packet
    mov rax,[ogg_granule]
    test rax,rax
    js ob_open_bad
    test ebx,ebx
    jnz ob_scan_later_page
    inc ebx
    cmp rax,r12
    jae ob_scan_initial_offset
    cmp dword ptr [ogg_eos],1
    jne ob_open_bad
    jmp ob_scan_end         ;single final page can trim below decoded count
ob_scan_initial_offset:
    mov r13,rax
    sub r13,r12
    jmp ob_scan_page_ready
ob_scan_later_page:
    mov rcx,r12
    add rcx,r13
    jo ob_open_bad
    cmp dword ptr [ogg_eos],1
    je ob_scan_final_page
    cmp rax,rcx
    jne ob_open_bad
    jmp ob_scan_packet
ob_scan_final_page:
    cmp rax,rcx
    ja ob_open_bad
ob_scan_page_ready:
    cmp dword ptr [ogg_eos],1
    jne ob_scan_packet
ob_scan_end:
    sub rax,r13
    jc ob_open_bad
    mov [ob_end_sample],rax
    mov ecx,[op_preskip]
    sub rax,rcx
    jc ob_open_bad
    mov [total_frames],rax
    lea rcx,ob_audio_checkpoint
    call ogg_resume
    test eax,eax
    jz ob_open_bad
    lea rax,ob_state
    mov [ob_states],rax
    cmp dword ptr [op_streams],1
    je ob_open_states
    xor ecx,ecx
    mov edx,[op_streams]
    imul edx,MO_SIZE
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    mov [ob_states],rax
    test rax,rax
    jz ob_open_bad
ob_open_states:
    call ob_reset_states
    test eax,eax
    jz ob_open_bad
    call ob_make_mix
    cvtsi2sd xmm0,dword ptr [op_gain]
    mulsd xmm0,qword ptr [ob_db_exp]
    cvtsd2ss xmm0,xmm0
    call op_celt_exp2
    movss dword ptr [ob_gain],xmm0
    mov dword ptr [ob_active],1
    mov eax,1
    jmp ob_open_done
ob_open_bad:
    call opus_close
    mov dword ptr [decode_error],26
    mov qword ptr [total_frames],0
    xor eax,eax
ob_open_done:
    add rsp,64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
opus_open ENDP

; Fresh stream only. Restore a packet boundary at least80ms before the target,
; reset codec history, and return its PCM position for worker decode/discard.
; Skim fewer than one index stride of packet headers to minimize pre-roll.
; Near the beginning, retain ordinary pre-skip and decode from raw sample0.
opus_seek PROC
    push rbx
    push rsi
    push rdi
    sub rsp,64
    xor eax,eax
    mov qword ptr [opus_seek_headers],0
    mov qword ptr [opus_seek_raw],0
    cmp dword ptr [ob_active],1
    jne ob_seek_return
    cmp dword ptr [opus_index_count],0
    je ob_seek_return
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz ob_seek_not_cancelled
    cmp dword ptr [rax],0
    jne ob_seek_zero
ob_seek_not_cancelled:
    cmp rcx,[total_frames]
    cmova rcx,[total_frames]
    cmp rcx,OB_PREROLL
    jb ob_seek_zero
    mov eax,[op_preskip]
    add rcx,rax
    sub rcx,OB_PREROLL
    mov rsi,rcx             ;latest permissible raw starting sample
    xor r8d,r8d
    mov r9d,[opus_index_count]
ob_seek_search:
    cmp r8d,r9d
    jae ob_seek_found
    mov edx,r9d
    sub edx,r8d
    shr edx,1
    add edx,r8d
    mov eax,edx
    shl eax,5
    add rax,[ob_index]
    cmp [rax+16],rsi
    ja ob_seek_upper
    lea r8d,[rdx+1]
    jmp ob_seek_search
ob_seek_upper:
    mov r9d,edx
    jmp ob_seek_search
ob_seek_found:
    dec r8d                ;point0 is raw0, so a preceding point always exists
    mov eax,r8d
    shl eax,5
    add rax,[ob_index]
    mov rbx,[rax+16]
    mov rcx,[rax]
    mov [ob_seek_checkpoint],rcx
    mov rcx,[rax+8]
    mov [ob_seek_checkpoint+8],rcx
    lea rcx,ob_seek_checkpoint
    call ogg_resume
    test eax,eax
    jz ob_seek_bad
ob_seek_skim:
    lea rcx,ob_scan_checkpoint
    call ogg_checkpoint
    call ogg_next
    test rax,rax
    jz ob_seek_bad
    mov rcx,rax
    call op_opus_multistream_parse
    test eax,eax
    jz ob_seek_bad
    mov eax,[op_packet_samples]
    add rax,rbx
    cmp rax,rsi
    ja ob_seek_ready
    mov rbx,rax
    inc qword ptr [opus_seek_headers]
    jmp ob_seek_skim
ob_seek_ready:
    lea rcx,ob_scan_checkpoint
    call ogg_resume         ;rewind the first packet which crosses pre-roll
    test eax,eax
    jz ob_seek_bad
    call ob_reset_states
    test eax,eax
    jz ob_seek_bad
    mov dword ptr [ob_available],0
    mov dword ptr [ob_used],0
    mov dword ptr [ob_eof],0
    mov [ob_decoded],rbx
    mov [opus_seek_raw],rbx
    mov eax,[op_preskip]
    cmp rbx,rax
    jb ob_seek_zero
    mov rax,rbx
    mov ecx,[op_preskip]    ;return raw sample minus original pre-skip
    sub rax,rcx
    jmp ob_seek_return
ob_seek_bad:
    mov dword ptr [decode_error],28
    mov dword ptr [ob_active],0
ob_seek_zero:
    xor eax,eax
ob_seek_return:
    add rsp,64
    pop rdi
    pop rsi
    pop rbx
    ret
opus_seek ENDP

; RCX=caller stereo float buffer,EDX=frame capacity. 0=EOF/error.
; No per-packet allocation. Decode every packet, including fully trimmed ones.
opus_read PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,96
    mov rdi,rcx
    mov r12d,edx
    xor ebx,ebx
    test rdi,rdi
    jz ob_read_done
    test r12d,r12d
    jz ob_read_done
    cmp dword ptr [ob_active],1
    jne ob_read_done
    cmp dword ptr [decode_error],0
    jne ob_read_done
ob_read_loop:
    cmp ebx,r12d
    jae ob_read_done
    mov eax,[ob_used]
    cmp eax,[ob_available]
    jb ob_emit
    cmp dword ptr [ob_eof],1
    je ob_read_done
    call ogg_next
    test rax,rax
    jz ob_read_bad
    cmp dword ptr [op_mapping],1
    jne ob_read_family0
    mov rcx,rax
    call ob_decode_multi
    jmp ob_read_decoded
ob_read_family0:
    mov [rsp+32+PK_DATA],rax
    mov [rsp+32+PK_LEN],edx
    mov rax,[ob_states]
    mov [rsp+32+PK_STATE],rax
    lea rax,ob_work
    mov [rsp+32+PK_WORK],rax
    lea rax,ob_pcm
    mov [rsp+32+PK_PCM],rax
    mov dword ptr [rsp+32+PK_COUNT],0
    mov dword ptr [rsp+32+PK_FEC],0
    mov dword ptr [rsp+32+PK_STATE_CAP],MO_SIZE
    mov dword ptr [rsp+32+PK_WORK_CAP],MW_SIZE
    mov dword ptr [rsp+32+PK_PCM_CAP],11520
    lea rcx,[rsp+32]
    call op_opus_decode_packet
ob_read_decoded:
    test eax,eax
    jle ob_read_bad
    mov r13d,eax
    mov rsi,[ob_decoded]   ;raw start of this packet,without origin offset
    add [ob_decoded],rax
    mov [ob_available],eax
    mov dword ptr [ob_used],0
    mov eax,[op_preskip]
    cmp rsi,rax
    jae ob_packet_trim
    sub rax,rsi
    cmp eax,r13d
    cmova eax,r13d
    mov [ob_used],eax
ob_packet_trim:
    mov rax,[ob_end_sample]
    cmp rax,rsi
    ja ob_packet_keep
    xor eax,eax
    jmp ob_packet_available
ob_packet_keep:
    sub rax,rsi
    cmp rax,r13
    cmova rax,r13
ob_packet_available:
    mov [ob_available],eax
    cmp [ob_used],eax
    jbe ob_packet_end
    mov [ob_used],eax
ob_packet_end:
    mov eax,[ogg_eos]
    mov [ob_eof],eax
    jmp ob_read_loop
ob_emit:
    lea rsi,ob_pcm
    cmp dword ptr [op_mapping],1
    jne ob_emit_family0
    lea rsi,ob_mix
    jmp ob_emit_stereo
ob_emit_family0:
    cmp dword ptr [source_channels],1
    je ob_emit_mono
ob_emit_stereo:
    movq xmm0,qword ptr [rsi+rax*8]
    movss xmm1,dword ptr [ob_gain]
    shufps xmm1,xmm1,0
    mulps xmm0,xmm1
    movq qword ptr [rdi+rbx*8],xmm0
    jmp ob_emit_next
ob_emit_mono:
    movss xmm0,dword ptr [rsi+rax*4]
    mulss xmm0,dword ptr [ob_gain]
    unpcklps xmm0,xmm0
    movq qword ptr [rdi+rbx*8],xmm0
ob_emit_next:
    inc dword ptr [ob_used]
    inc ebx
    jmp ob_read_loop
ob_read_bad:
    mov dword ptr [decode_error],27
    mov dword ptr [ob_active],0
    xor ebx,ebx           ;caller discards partial output on error
ob_read_done:
    mov eax,ebx
    add rsp,96
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
opus_read ENDP

; Reset every separately owned mono/stereo history; share only scratch space.
ob_reset_states PROC
    push rbx
    push rsi
    sub rsp,56
    mov rsi,[ob_states]
    test rsi,rsi
    jz ob_reset_bad
    xor ebx,ebx
ob_reset_stream:
    mov [rsp+32+MI_STATE],rsi
    mov dword ptr [rsp+32+MI_FS],48000
    xor eax,eax
    cmp ebx,[op_coupled]
    setb al
    inc eax
    mov [rsp+32+MI_CHANNELS],eax
    mov dword ptr [rsp+32+MI_CAP],MO_SIZE
    lea rcx,[rsp+32]
    call op_opus_decoder_init
    test eax,eax
    jz ob_reset_bad
    add rsi,MO_SIZE
    inc ebx
    cmp ebx,[op_streams]
    jb ob_reset_stream
    mov eax,1
    jmp ob_reset_done
ob_reset_bad:
    xor eax,eax
ob_reset_done:
    add rsp,56
    pop rsi
    pop rbx
    ret
ob_reset_states ENDP

; Compose the channel map and downmix once at open, including repeated mapped
; channels and255 (silence). Coefficients for unmapped streams remain zero.
ob_make_mix PROC
    push rsi
    push rdi
    lea rdi,ob_coeff
    xor eax,eax
    mov ecx,2040
    rep stosd
    mov eax,[source_channels]
    dec eax
    shl eax,7
    lea rsi,ob_matrix
    add rsi,rax
    lea rdi,ob_coeff
    lea r9,op_channel_map
    mov r10d,[op_coupled]
    shl r10d,1
    xor ecx,ecx
ob_mix_channel:
    movzx eax,byte ptr [r9+rcx]
    cmp eax,255
    je ob_mix_next
    cmp eax,r10d
    jae ob_mix_uncoupled
    shl eax,4
    jmp ob_mix_weight
ob_mix_uncoupled:
    sub eax,[op_coupled]
    shl eax,5
ob_mix_weight:
    mov rdx,rcx
    shl rdx,4
    movupd xmm0,xmmword ptr [rsi+rdx]
    movupd xmm1,xmmword ptr [rdi+rax]
    addpd xmm0,xmm1
    movupd xmmword ptr [rdi+rax],xmm0
ob_mix_next:
    inc ecx
    cmp ecx,[source_channels]
    jb ob_mix_channel
    pop rdi
    pop rsi
    ret
ob_make_mix ENDP

; RCX=packed Ogg payload,EDX=length -> EAX=stereo frames or0 on failure.
; No packet allocation; decode even unmapped streams to validate their entropy
; and maintain history. Cancellation is checked between elementary streams.
ob_decode_multi PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,96
    mov rsi,rcx
    mov [rsp+88],edx
    lea rdi,ob_mix_acc
    xor eax,eax
    mov ecx,11520
    rep stosq
    mov edi,[rsp+88]
    mov r12,[ob_states]
    lea r14,ob_coeff
    xor ebx,ebx
    xor r13d,r13d
ob_decode_stream:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz ob_decode_not_cancelled
    cmp dword ptr [rax],0
    jne ob_decode_bad
ob_decode_not_cancelled:
    mov [rsp+32+PK_STATE],r12
    mov [rsp+32+PK_DATA],rsi
    lea rax,ob_pcm
    mov [rsp+32+PK_PCM],rax
    lea rax,ob_work
    mov [rsp+32+PK_WORK],rax
    mov [rsp+32+PK_LEN],edi
    mov dword ptr [rsp+32+PK_COUNT],0
    mov dword ptr [rsp+32+PK_FEC],0
    mov dword ptr [rsp+32+PK_STATE_CAP],MO_SIZE
    mov dword ptr [rsp+32+PK_WORK_CAP],MW_SIZE
    mov dword ptr [rsp+32+PK_PCM_CAP],11520
    lea eax,[rbx+1]
    xor edx,edx
    cmp eax,[op_streams]
    setb dl
    lea rcx,[rsp+32]
    call op_opus_decode_packet_ex
    test eax,eax
    jle ob_decode_bad
    test ebx,ebx
    jz ob_decode_duration
    cmp eax,r13d
    jne ob_decode_bad
ob_decode_duration:
    mov r13d,eax
    mov eax,[op_packet_bytes]
    test eax,eax
    jz ob_decode_bad
    cmp eax,edi
    ja ob_decode_bad
    add rsi,rax
    sub edi,eax
    lea rdx,ob_pcm
    lea r15,ob_mix_acc
    movupd xmm4,xmmword ptr [r14]
    movupd xmm5,xmmword ptr [r14+16]
    xor ecx,ecx
ob_decode_mix:
    movss xmm0,dword ptr [rdx]
    cvtss2sd xmm0,xmm0
    unpcklpd xmm0,xmm0
    mulpd xmm0,xmm4
    add rdx,4
    cmp dword ptr [r12+MO_CHANNELS],2
    jne ob_decode_accumulate
    movss xmm1,dword ptr [rdx]
    cvtss2sd xmm1,xmm1
    unpcklpd xmm1,xmm1
    mulpd xmm1,xmm5
    addpd xmm0,xmm1
    add rdx,4
ob_decode_accumulate:
    movupd xmm2,xmmword ptr [r15]
    addpd xmm0,xmm2
    movupd xmmword ptr [r15],xmm0
    add r15,16
    inc ecx
    cmp ecx,r13d
    jb ob_decode_mix
    add r12,MO_SIZE
    add r14,32
    inc ebx
    cmp ebx,[op_streams]
    jb ob_decode_stream
    test edi,edi
    jnz ob_decode_bad
    lea rsi,ob_mix_acc
    lea rdi,ob_mix
    mov ecx,r13d
ob_decode_round:
    movupd xmm0,xmmword ptr [rsi]
    cvtpd2ps xmm0,xmm0
    movq qword ptr [rdi],xmm0
    add rsi,16
    add rdi,8
    dec ecx
    jnz ob_decode_round
    mov eax,r13d
    jmp ob_decode_done
ob_decode_bad:
    xor eax,eax
ob_decode_done:
    add rsp,96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ob_decode_multi ENDP
END
