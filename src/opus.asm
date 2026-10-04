; Original bounded Ogg/Opus family0 playback bridge. MIT, see LICENSE.
; RFC7845 header placement,48kHz granules,gain,pre-skip and end trimming.
; Connected codec algorithms retain BSD notices in THIRD_PARTY_NOTICES.
option casemap:none
include opus_mode_layout.inc
include opus_stream_layout.inc
EXTERN opus_headers:PROC,op_opus_packet_parse:PROC,op_opus_decoder_init:PROC
EXTERN op_opus_decode_packet:PROC,op_celt_exp2:PROC
EXTERN ogg_next:PROC,ogg_rewind:PROC
EXTERN ogg_packet_last:DWORD,ogg_eos:DWORD,ogg_granule:QWORD
EXTERN op_preskip:DWORD,op_gain:DWORD,op_packet_samples:DWORD
EXTERN sample_rate:DWORD,source_channels:DWORD,source_bits:DWORD
EXTERN total_frames:QWORD,decode_error:DWORD
PUBLIC opus_open,opus_read,opus_close
.const
ob_db_exp real8 0.00064881407907956296 ;log2(10)/(20*256)
.data
ob_active dd 0
ob_available dd 0
ob_used dd 0
ob_eof dd 0
ob_gain real4 1.0
ob_end_sample dq 0
ob_decoded dq 0
.data?
ALIGN 16
ob_state db MO_SIZE dup (?)
ob_work db MW_SIZE dup (?)
ob_pcm real4 11520 dup (?)
.code
opus_close PROC
    mov dword ptr [ob_active],0
    mov dword ptr [ob_available],0
    mov dword ptr [ob_used],0
    mov dword ptr [ob_eof],0
    mov qword ptr [ob_decoded],0
    ret
opus_close ENDP

; RCX=mapped start,RDX=end. Complete structural/duration scan before output.
opus_open PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,64
    mov rsi,rcx
    mov rdi,rdx
    call opus_close
    mov rcx,rsi
    mov rdx,rdi
    call opus_headers
    test eax,eax
    jz ob_open_bad
    xor ebx,ebx             ;first completed audio page seen
    xor r12d,r12d           ;raw samples in complete packets
    xor r13d,r13d           ;initial granule offset
ob_scan_packet:
    call ogg_next
    test rax,rax
    jz ob_open_bad          ;EOS must belong to a completed audio packet
    mov rcx,rax
    call op_opus_packet_parse
    test eax,eax
    jz ob_open_bad
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
    call ogg_rewind
    call ogg_next           ;validated identification header
    test rax,rax
    jz ob_open_bad
    call ogg_next           ;validated comment header
    test rax,rax
    jz ob_open_bad
    lea rax,ob_state
    mov [rsp+32+MI_STATE],rax
    mov dword ptr [rsp+32+MI_FS],48000
    mov eax,[source_channels]
    mov [rsp+32+MI_CHANNELS],eax
    mov dword ptr [rsp+32+MI_CAP],MO_SIZE
    lea rcx,[rsp+32]
    call op_opus_decoder_init
    test eax,eax
    jz ob_open_bad
    cvtsi2sd xmm0,dword ptr [op_gain]
    mulsd xmm0,qword ptr [ob_db_exp]
    cvtsd2ss xmm0,xmm0
    call op_celt_exp2
    movss dword ptr [ob_gain],xmm0
    mov dword ptr [ob_active],1
    mov eax,1
    jmp ob_open_done
ob_open_bad:
    mov dword ptr [decode_error],26
    mov qword ptr [total_frames],0
    xor eax,eax
ob_open_done:
    add rsp,64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
opus_open ENDP

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
    mov [rsp+32+PK_DATA],rax
    mov [rsp+32+PK_LEN],edx
    lea rax,ob_state
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
    cmp dword ptr [source_channels],1
    je ob_emit_mono
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
END
