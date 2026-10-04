; LAMP: original x86-64 assembly decoders. MIT license, see LICENSE.
; ABI: decoder_open(RCX=path W) -> EAX=1 on success; decoder_read(RCX=stereo
; float output, EDX=frame capacity) -> EAX=frames. 0=EOF or error.
; The decoder is single-instance and only called by the producer thread.
option casemap:none
EXTERN CreateFileW:PROC, GetFileSizeEx:PROC, CreateFileMappingW:PROC
EXTERN MapViewOfFile:PROC, UnmapViewOfFile:PROC, CloseHandle:PROC
EXTERN mp3_open:PROC, mp3_read:PROC,mp3_seek:PROC,mp3_close:PROC
EXTERN vorbis_open:PROC, vorbis_read:PROC, vorbis_close:PROC, ogg_close:PROC
EXTERN vorbis_seek:PROC
EXTERN opus_open:PROC,opus_read:PROC,opus_close:PROC
EXTERN ogg_cancel_ptr:QWORD
PUBLIC decoder_open, decoder_read, decoder_close, decoder_seek
PUBLIC sample_rate, source_channels, source_bits, decode_error, total_frames, codec_kind
PUBLIC decoder_seek_probes

.data
sample_rate dd 0
source_channels dd 0
source_bits dd 0
decode_error dd 0
codec_kind dd 0                 ;1 WAV,2 native FLAC,3 MP3 Layer III,4 Vorbis,5 Opus
total_frames dq 0
file_handle dq -1
map_handle dq 0
map_base dq 0
file_size dq 0
input_cursor dq 0
input_end dq 0
wav_end dq 0
wav_begin dq 0
flac_begin dq 0
flac_seek_table dq 0
flac_seek_count dd 0
flac_next_sample dq 0
flac_bit_end dq 0
flac_seek_probe dd 0
decoder_seek_probes dd 0
frame_blocking dd 0
frame_number_bytes dd 0
frame_number dq 0
wav_format dd 0
wav_align dd 0
bits_count dd 0
bits_buf dq 0
frame_start dq 0
header_end dq 0
frame_samples dd 0
frame_used dd 0
channel_mode dd 0
block_code dd 0
rate_code dd 0
depth_code dd 0
frame_bps dd 0
minimum_block dd 0
maximum_block dd 0
sub_bps dd 0
wasted_bits dd 0
sub_type dd 0
predict_order dd 0
predict_shift dd 0
rice_bits dd 0
rice_k dd 0
partition_count dd 0
partition_samples dd 0
crc_ready dd 0
scale8 dd 3c000000h
scale16 dd 38000000h
scale24 dd 34000000h
scale32 dd 30000000h
float_scale real4 0.0
rate_table dd 0,88200,176400,192000,8000,16000,22050,24000,32000,44100,48000,96000
depth_table dd 0,8,12,0,16,20,24,32

.data?
left_samples dq 65536 dup (?)
right_samples dq 65536 dup (?)
lpc_coeff dq 32 dup (?)
crc8_table db 256 dup (?)
crc16_table dw 256 dup (?)

.code
decoder_open PROC
    push rbp
    mov rbp,rsp
    sub rsp,80
    mov dword ptr [decode_error],0
    mov dword ptr [codec_kind],0
    mov qword ptr [total_frames],0
    mov dword ptr [frame_samples],0
    mov dword ptr [frame_used],0
    mov qword ptr [wav_begin],0
    mov qword ptr [flac_begin],0
    mov qword ptr [flac_seek_table],0
    mov dword ptr [flac_seek_count],0
    mov qword ptr [flac_next_sample],0
    mov dword ptr [flac_seek_probe],0
    mov edx,80000000h
    mov r8d,1
    xor r9d,r9d
    mov qword ptr [rsp+32],3
    mov qword ptr [rsp+40],08000000h
    mov qword ptr [rsp+48],0
    call CreateFileW
    mov [file_handle],rax
    cmp rax,-1
    je open_bad
    mov rcx,rax
    lea rdx,file_size
    call GetFileSizeEx
    test eax,eax
    jz open_bad
    cmp qword ptr [file_size],12
    jb open_bad
    mov rcx,[file_handle]
    xor edx,edx
    mov r8d,2
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateFileMappingW
    mov [map_handle],rax
    test rax,rax
    jz open_bad
    mov rcx,rax
    mov edx,4
    xor r8d,r8d
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    call MapViewOfFile
    mov [map_base],rax
    test rax,rax
    jz open_bad
    mov rdx,rax
    add rdx,[file_size]
    jc open_bad
    mov [input_end],rdx
    mov [input_cursor],rax
    cmp dword ptr [rax],46464952h ; RIFF
    je open_wav
    cmp dword ptr [rax],43614c66h ; fLaC
    je open_flac
    cmp dword ptr [rax],5367674fh ; OggS
    je open_ogg
    mov rcx,[input_cursor]
    mov rdx,[input_end]
    call mp3_open
    test eax,eax
    jz open_bad
    mov dword ptr [codec_kind],3
    leave
    ret
open_ogg:
    ; Bounded codec signature probe; each codec validates its full Ogg stream.
    mov rax,[input_cursor]
    lea r8,[rax+27]
    cmp r8,[input_end]
    ja open_bad
    movzx ecx,byte ptr [rax+26]
    lea r8,[rax+rcx+27]
    lea r9,[r8+8]
    cmp r9,[input_end]
    ja open_bad
    mov r9,0646165487375704fh
    cmp [r8],r9
    jne open_vorbis
    mov rcx,[input_cursor]
    mov rdx,[input_end]
    call opus_open
    test eax,eax
    jz open_bad
    mov dword ptr [codec_kind],5
    leave
    ret
open_vorbis:
    mov rcx,[input_cursor]
    mov rdx,[input_end]
    call vorbis_open
    test eax,eax
    jz open_bad
    mov dword ptr [codec_kind],4
    leave
    ret
open_bad:
    mov dword ptr [decode_error],1
    xor eax,eax
    leave
    ret
open_wav:
    cmp dword ptr [rax+8],45564157h
    jne open_bad
    mov edx,[rax+4]
    add rdx,8
    cmp rdx,[file_size]
    ja open_bad
    add rdx,rax
    mov [input_end],rdx
    add rax,12
    mov r10,rax
    xor r11d,r11d              ; fmt found
wav_chunks:
    lea rax,[r10+8]
    cmp rax,[input_end]
    ja open_bad
    mov edx,[r10+4]
    mov r8,rax
    add r8,rdx
    jc open_bad
    cmp r8,[input_end]
    ja open_bad
    cmp dword ptr [r10],20746d66h
    je wav_fmt
    cmp dword ptr [r10],61746164h
    je wav_data
wav_next:
    add r8,1
    and r8,-2
    mov r10,r8
    jmp wav_chunks
wav_fmt:
    cmp edx,16
    jb open_bad
    movzx ecx,word ptr [rax]
    cmp ecx,0fffeh
    jne wav_basic_fmt
    cmp edx,40
    jb open_bad
    cmp word ptr [rax+16],22
    jb open_bad
    ; Only PCM / float SubFormat GUIDs, canonical remaining 14 bytes.
    cmp word ptr [rax+26],0
    jne open_bad
    cmp dword ptr [rax+28],00100000h
    jne open_bad
    mov r9,0719b3800aa000080h
    cmp qword ptr [rax+32],r9
    jne open_bad
    movzx ecx,word ptr [rax+24]
    movzx r9d,word ptr [rax+18]
    cmp r9w,[rax+14]
    jne open_bad             ; uncommon packed valid-bits layouts deferred
wav_basic_fmt:
    cmp ecx,1
    je wav_valid_type
    cmp ecx,3
    jne open_bad
wav_valid_type:
    mov [wav_format],ecx
    movzx ecx,word ptr [rax+2]
    cmp ecx,1
    jb open_bad
    cmp ecx,2
    ja open_bad
    mov [source_channels],ecx
    mov ecx,[rax+4]
    cmp ecx,8000
    jb open_bad
    cmp ecx,192000
    ja open_bad
    mov [sample_rate],ecx
    movzx ecx,word ptr [rax+14]
    cmp dword ptr [wav_format],3
    jne wav_pcm_bits
    cmp ecx,32
    jne open_bad
    jmp wav_bits_ok
wav_pcm_bits:
    cmp ecx,8
    je wav_bits_ok
    cmp ecx,16
    je wav_bits_ok
    cmp ecx,24
    je wav_bits_ok
    cmp ecx,32
    jne open_bad
wav_bits_ok:
    mov [source_bits],ecx
    shr ecx,3
    imul ecx,[source_channels]
    cmp cx,[rax+12]
    jne open_bad
    mov [wav_align],ecx
    imul ecx,[sample_rate]
    cmp ecx,[rax+8]
    jne open_bad
    mov r11d,1
    jmp wav_next
wav_data:
    test r11d,r11d
    jz open_bad
    mov [input_cursor],rax
    mov [wav_begin],rax
    mov [wav_end],r8
    mov rax,rdx
    xor edx,edx
    mov ecx,[wav_align]
    div rcx
    test edx,edx
    jnz open_bad
    mov [total_frames],rax
    mov dword ptr [codec_kind],1
    mov eax,1
    leave
    ret

open_flac:
    add rax,4
    mov r10,rax
    xor r11d,r11d
flac_metadata:
    lea rax,[r10+4]
    cmp rax,[input_end]
    ja open_bad
    mov edx,[r10]
    bswap edx
    mov r8d,edx
    and edx,00ffffffh
    lea r9,[rax+rdx]
    cmp r9,[input_end]
    ja open_bad
    mov ecx,r8d
    shr ecx,24
    and ecx,7fh
    cmp r11d,0
    jne flac_have_streaminfo
    test ecx,ecx
    jnz open_bad
    cmp edx,34
    jne open_bad
    movzx ecx,word ptr [rax]
    rol cx,8
    cmp ecx,16
    jb open_bad
    mov [minimum_block],ecx
    movzx edx,word ptr [rax+2]
    rol dx,8
    cmp edx,ecx
    jb open_bad
    mov [maximum_block],edx
    mov rdx,[rax+10]
    bswap rdx
    mov rcx,rdx
    shr rcx,44
    mov [sample_rate],ecx
    cmp ecx,8000
    jb open_bad
    cmp ecx,192000
    ja open_bad
    mov rcx,rdx
    shr rcx,41
    and ecx,7
    inc ecx
    cmp ecx,2
    ja open_bad
    mov [source_channels],ecx
    mov rcx,rdx
    shr rcx,36
    and ecx,31
    inc ecx
    cmp ecx,4
    jb open_bad
    cmp ecx,24
    ja open_bad
    mov [source_bits],ecx
    mov rcx,0fffffffffh
    and rdx,rcx
    mov [total_frames],rdx
    mov r11d,1
    jmp flac_meta_next
flac_have_streaminfo:
    test ecx,ecx
    jz open_bad
    cmp ecx,127
    je open_bad
    cmp ecx,3
    jne flac_meta_next
    cmp qword ptr [flac_seek_table],0
    jne open_bad
    mov [flac_seek_table],rax
    mov eax,edx
    xor edx,edx
    mov ecx,18
    div ecx
    test edx,edx
    jnz open_bad
    mov [flac_seek_count],eax
flac_meta_next:
    mov r10,r9
    test r8d,80000000h
    jz flac_metadata
    mov [input_cursor],r10
    mov [flac_begin],r10
    mov rax,[input_end]
    mov [flac_bit_end],rax
    ; Validate every table point before enabling indexed seeking. Placeholders
    ; are sorted last and their offset/sample-count fields are undefined.
    mov r9,[flac_seek_table]
    mov r8d,[flac_seek_count]
    xor r11d,r11d
    xor edx,edx
flac_seek_validate:
    test r8d,r8d
    jz flac_seek_valid
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz flac_seek_validate_continue
    cmp dword ptr [rax],0
    jne open_bad
flac_seek_validate_continue:
    mov rax,[r9]
    bswap rax
    test edx,edx
    jz flac_seek_first
    cmp rax,r11
    jb open_bad
    cmp rax,-1
    je flac_seek_point_next
    cmp rax,r11
    je open_bad
flac_seek_first:
    cmp rax,-1
    je flac_seek_point_next
    mov rcx,0fffffffffh
    cmp rax,rcx
    ja open_bad
    cmp qword ptr [total_frames],0
    je flac_seek_sample_valid
    cmp rax,[total_frames]
    jae open_bad
flac_seek_sample_valid:
    mov rcx,[r9+8]
    bswap rcx
    mov r11,[input_end]
    sub r11,r10
    cmp rcx,r11
    jae open_bad
    movzx ecx,word ptr [r9+16]
    rol cx,8
    test ecx,ecx
    jz open_bad
    cmp ecx,[maximum_block]
    ja open_bad
flac_seek_point_next:
    mov r11,rax
    mov edx,1
    add r9,18
    dec r8d
    jmp flac_seek_validate
flac_seek_valid:
    mov dword ptr [codec_kind],2
    ; Compute exact reciprocal 2^(1-bits), no library calls.
    mov eax,128
    sub eax,[source_bits]
    shl eax,23
    mov [float_scale],eax
    mov eax,1
    leave
    ret
decoder_open ENDP

decoder_close PROC
    push rbp
    mov rbp,rsp
    sub rsp,32
    call mp3_close
    call opus_close
    call vorbis_close
    call ogg_close
    mov rcx,[map_base]
    test rcx,rcx
    jz close_mapping
    call UnmapViewOfFile
    mov qword ptr [map_base],0
close_mapping:
    mov rcx,[map_handle]
    test rcx,rcx
    jz close_file
    call CloseHandle
    mov qword ptr [map_handle],0
close_file:
    mov rcx,[file_handle]
    cmp rcx,-1
    je closed
    call CloseHandle
    mov qword ptr [file_handle],-1
closed:
    mov qword ptr [wav_begin],0
    mov qword ptr [flac_begin],0
    mov qword ptr [flac_seek_table],0
    mov dword ptr [flac_seek_count],0
    leave
    ret
decoder_close ENDP

; RCX=absolute requested frame. Call once on a newly opened stream.
; RAX=resume frame <= target; caller decodes/discards the remaining distance.
; WAV seeks exactly; native FLAC uses a table or bounded frame binary search.
; MP3 restores an indexed reservoir before two-frame PCM pre-roll.
; Vorbis restores a packet checkpoint and primes its preceding overlap.
; Opus returns0 without changing its fresh decoder state.
decoder_seek PROC
    push rbx
    push rsi
    sub rsp,40
    mov dword ptr [decoder_seek_probes],0
    xor eax,eax
    cmp qword ptr [map_base],0
    je seek_return
    cmp dword ptr [decode_error],0
    jne seek_return
    cmp dword ptr [codec_kind],1
    je seek_wav
    cmp dword ptr [codec_kind],3
    je seek_mp3
    cmp dword ptr [codec_kind],4
    je seek_vorbis
    cmp dword ptr [codec_kind],2
    jne seek_return
    test rcx,rcx
    jz seek_return
    mov rsi,rcx
    mov rbx,[flac_seek_table]
    xor r8d,r8d             ;lower bound, exclusive upper bound
    mov r9d,[flac_seek_count]
    test r9d,r9d
    jz seek_flac_without_table
seek_flac_search:
    cmp r8d,r9d
    jae seek_flac_found
    mov edx,r9d
    sub edx,r8d
    shr edx,1
    add edx,r8d
    imul r10d,edx,18
    mov rax,[rbx+r10]
    bswap rax
    cmp rax,-1
    je seek_flac_upper
    cmp rax,rsi
    ja seek_flac_upper
    lea r8d,[rdx+1]
    jmp seek_flac_search
seek_flac_upper:
    mov r9d,edx
    jmp seek_flac_search
seek_flac_found:
    xor eax,eax
    test r8d,r8d
    jz seek_flac_without_table
    dec r8d
    imul r8d,r8d,18
    add rbx,r8
    mov rsi,[rbx]
    bswap rsi
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz seek_flac_not_cancelled
    cmp dword ptr [rax],0
    jne seek_cancelled
seek_flac_not_cancelled:
    mov rax,[rbx+8]
    bswap rax
    add rax,[flac_begin]    ;validated relative offset stays in mapped input
    mov [input_cursor],rax
    mov [flac_next_sample],rsi
    inc dword ptr [decoder_seek_probes]
    call decode_frame      ;selected frame header and complete PCM CRC checks
    test eax,eax
    jz seek_failed
    movzx eax,word ptr [rbx+16]
    rol ax,8
    cmp eax,[frame_samples]
    jne seek_failed
    mov rax,[frame_number]
    cmp dword ptr [frame_blocking],0
    jne seek_flac_position
    mov ecx,[maximum_block]
    mul rcx
seek_flac_position:
    cmp rax,rsi
    jne seek_failed
    mov rax,rsi
    jmp seek_return
seek_flac_without_table:
    mov rcx,rsi
    call flac_seek_search
    jmp seek_return
seek_mp3:
    call mp3_seek
    jmp seek_return
seek_vorbis:
    call vorbis_seek
    jmp seek_return
seek_wav:
    cmp rcx,[total_frames]
    cmova rcx,[total_frames]
    mov rax,rcx
    mov edx,[wav_align]
    imul rdx,rcx
    add rdx,[wav_begin]
    mov [input_cursor],rdx
    jmp seek_return
seek_failed:
    mov dword ptr [decode_error],28
    xor eax,eax
    jmp seek_return
seek_cancelled:
    xor eax,eax
seek_return:
    add rsp,40
    pop rsi
    pop rbx
    ret
decoder_seek ENDP

; Search independent FLAC frames without allocating an index. Byte bounds
; shrink on every iteration, and decoded sample bounds must agree with them.
; Full header, subframe, sample-range and CRC validation precedes selection;
; a following frame must also validate with consecutive sample numbering.
; Cap speculative work at 64 probes, 64 MiB scanning, 1 MiB per frame. A cap
; falls back to frame zero; cancellation stops speculation before more reads.
flac_seek_search PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,96
    mov rbx,rcx
    mov r14,[flac_begin]
    xor r15d,r15d
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz seek_search_first
    cmp dword ptr [rax],0
    jne seek_search_cancel
seek_search_first:
    inc dword ptr [decoder_seek_probes]
    call decode_frame
    test eax,eax
    jz seek_search_bad
    mov rax,[flac_next_sample]
    cmp rbx,rax
    jb seek_search_zero
    mov [rsp+32],rax          ;smallest sample at the lower byte bound
    mov rax,[total_frames]
    test rax,rax
    jnz seek_search_total
    mov rax,-1
seek_search_total:
    mov [rsp+40],rax          ;sample boundary belonging to the upper bound
    mov dword ptr [rsp+48],64
    mov dword ptr [rsp+56],04000000h
    mov rsi,[input_cursor]
    mov rdi,[input_end]
    mov dword ptr [flac_seek_probe],1
seek_search_loop:
    cmp rsi,rdi
    jae seek_search_selected
    mov r12,rdi
    sub r12,rsi
    shr r12,1
    add r12,rsi
    mov r13,r12
seek_search_scan:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz seek_search_scan_continue
    cmp dword ptr [rax],0
    jne seek_search_cancel
seek_search_scan_continue:
    cmp r13,rdi
    jae seek_search_upper
    lea rax,[r13+2]
    cmp rax,[input_end]
    ja seek_search_upper
    cmp dword ptr [rsp+56],0
    je seek_search_fallback
    dec dword ptr [rsp+56]
    cmp byte ptr [r13],0ffh
    jne seek_search_next
    movzx eax,byte ptr [r13+1]
    and eax,0feh
    cmp eax,0f8h
    jne seek_search_next
    cmp dword ptr [rsp+48],0
    je seek_search_fallback
    dec dword ptr [rsp+48]
    mov [input_cursor],r13
    lea rax,[r13+0100000h]
    cmp rax,[input_end]
    cmova rax,[input_end]
    mov [flac_bit_end],rax
    mov dword ptr [decode_error],0
    inc dword ptr [decoder_seek_probes]
    call decode_frame
    test eax,eax
    jz seek_search_next
    mov rax,[flac_next_sample]
    mov ecx,[frame_samples]
    sub rax,rcx
    mov [rsp+72],rax         ;candidate start sample, before neighbor decode
    mov eax,[frame_samples]
    mov [rsp+80],eax
    mov rax,[input_cursor]
    mov [rsp+64],rax
    cmp rax,[input_end]
    jae seek_search_candidate
    cmp dword ptr [rsp+48],0
    je seek_search_fallback
    dec dword ptr [rsp+48]
    lea rax,[rax+0100000h]
    cmp rax,[input_end]
    cmova rax,[input_end]
    mov [flac_bit_end],rax
    mov dword ptr [flac_seek_probe],0
    inc dword ptr [decoder_seek_probes]
    call decode_frame        ;reject CRC-valid sync patterns inside payloads
    mov dword ptr [flac_seek_probe],1
    test eax,eax
    jz seek_search_next
seek_search_candidate:
    mov eax,[rsp+80]
    add rax,[rsp+72]
    mov [flac_next_sample],rax
    mov rcx,[rsp+64]
    mov [input_cursor],rcx
    cmp rax,[rsp+40]
    ja seek_search_bad
    mov rax,[rsp+72]         ;absolute start of fully validated candidate
    cmp rax,[rsp+32]
    jb seek_search_bad
    cmp rax,rbx
    ja seek_search_upper_sample
    mov r14,r13
    mov r15,rax
    cmp rbx,[flac_next_sample]
    jb seek_search_selected
    mov rax,[flac_next_sample]
    mov [rsp+32],rax
    mov rsi,[input_cursor]    ;strict progress past the decoded frame
    jmp seek_search_loop
seek_search_upper_sample:
    mov [rsp+40],rax
seek_search_upper:
    mov rdi,r12              ;strictly shrink even when mid-frame
    jmp seek_search_loop
seek_search_next:
    inc r13
    jmp seek_search_scan
seek_search_fallback:
    mov r14,[flac_begin]
    xor r15d,r15d
seek_search_selected:
    mov dword ptr [flac_seek_probe],0
    mov rax,[input_end]
    mov [flac_bit_end],rax
    mov dword ptr [decode_error],0
    mov [input_cursor],r14
    mov [flac_next_sample],r15
    inc dword ptr [decoder_seek_probes]
    call decode_frame        ;restore selected PCM and ordinary chronology
    test eax,eax
    jz seek_search_bad
    mov rax,r15
    jmp seek_search_return
seek_search_zero:
    xor eax,eax              ;first frame is already decoded and buffered
    jmp seek_search_return
seek_search_bad:
    mov dword ptr [decode_error],28
    xor eax,eax
    jmp seek_search_return
seek_search_cancel:
    mov dword ptr [decode_error],0
    xor eax,eax
seek_search_return:
    mov dword ptr [flac_seek_probe],0
    mov rdx,[input_end]
    mov [flac_bit_end],rdx
    add rsp,96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
flac_seek_search ENDP

; Bounds-checked MSB-first reservoir. Width <=32, result unsigned in RAX.
get_bits PROC
    mov r9d,ecx
    mov rdx,[bits_buf]
    mov r8d,[bits_count]
gb_fill:
    cmp r8d,r9d
    jae gb_extract
    mov r10,[input_cursor]
    cmp r10,[flac_bit_end]
    jae gb_bad
    cmp dword ptr [flac_seek_probe],0
    je gb_not_cancelled
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz gb_not_cancelled
    cmp dword ptr [rax],0
    jne gb_bad
gb_not_cancelled:
    shl rdx,8
    movzx eax,byte ptr [r10]
    or rdx,rax
    inc r10
    mov [input_cursor],r10
    add r8d,8
    jmp gb_fill
gb_extract:
    sub r8d,r9d
    mov ecx,r8d
    mov rax,rdx
    shr rax,cl
    mov ecx,r9d
    mov r10,1
    shl r10,cl
    dec r10
    and rax,r10
    mov [bits_buf],rdx
    mov [bits_count],r8d
    ret
gb_bad:
    mov dword ptr [decode_error],2
    xor eax,eax
    ret
get_bits ENDP

get_signed PROC
    push rbx
    sub rsp,32
    mov ebx,ecx
    call get_bits
    mov ecx,64
    sub ecx,ebx
    shl rax,cl
    sar rax,cl
    add rsp,32
    pop rbx
    ret
get_signed ENDP

; Count unary prefixes a byte at a time using BSR; no per-bit Rice calls.
get_unary PROC
    xor r11d,r11d
unary_chunk:
    mov ecx,[bits_count]
    test ecx,ecx
    jnz unary_scan
    mov r10,[input_cursor]
    cmp r10,[flac_bit_end]
    jae unary_bad
    cmp dword ptr [flac_seek_probe],0
    je unary_not_cancelled
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz unary_not_cancelled
    cmp dword ptr [rax],0
    jne unary_bad
unary_not_cancelled:
    movzx edx,byte ptr [r10]
    inc r10
    mov [input_cursor],r10
    mov [bits_buf],rdx
    mov ecx,8
    mov [bits_count],ecx
unary_scan:
    mov rdx,[bits_buf]
    mov r8,1
    shl r8,cl
    dec r8
    and rdx,r8
    bsr r8,rdx
    jnz unary_found
    add r11d,ecx
    cmp r11d,01000000h
    jae unary_bad
    mov dword ptr [bits_count],0
    jmp unary_chunk
unary_found:
    sub ecx,r8d
    dec ecx
    add r11d,ecx
    mov [bits_count],r8d
    mov eax,r11d
    ret
unary_bad:
    mov dword ptr [decode_error],2
    xor eax,eax
    ret
get_unary ENDP

init_crc_tables PROC
    xor r11d,r11d
crc_init_byte:
    mov eax,r11d
    mov edx,r11d
    shl edx,8
    mov ecx,8
crc_init_bit:
    shl eax,1
    test eax,100h
    jz crc_init_16
    xor eax,7
crc_init_16:
    shl edx,1
    test edx,10000h
    jz crc_init_next
    xor edx,8005h
crc_init_next:
    dec ecx
    jnz crc_init_bit
    lea r8,crc8_table
    mov [r8+r11],al
    lea r8,crc16_table
    mov [r8+r11*2],dx
    inc r11d
    cmp r11d,256
    jb crc_init_byte
    mov dword ptr [crc_ready],1
    ret
init_crc_tables ENDP

; Reflected-free FLAC CRC: RCX=start, RDX=end, R8D=8 or 16.
flac_crc PROC
    xor eax,eax
    cmp r8d,8
    je crc8_fast
    lea r10,crc16_table
crc_byte:
    cmp rcx,rdx
    jae crc_done
    mov r8d,eax
    shr r8d,8
    movzx r9d,byte ptr [rcx]
    inc rcx
    xor r8d,r9d
    movzx r9d,word ptr [r10+r8*2]
    shl eax,8
    xor eax,r9d
    and eax,0ffffh
    jmp crc_byte
crc8_fast:
    lea r10,crc8_table
crc8_byte:
    cmp rcx,rdx
    jae crc_done
    movzx r9d,byte ptr [rcx]
    inc rcx
    xor eax,r9d
    movzx eax,byte ptr [r10+rax]
    jmp crc8_byte
crc_done:
    ret
flac_crc ENDP

decode_frame PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,64
    cmp dword ptr [crc_ready],0
    jne crc_tables_ready
    call init_crc_tables
crc_tables_ready:
    mov rax,[input_cursor]
    cmp rax,[input_end]
    jae frame_eof
    mov [frame_start],rax
    mov dword ptr [bits_count],0
    mov qword ptr [bits_buf],0
    mov ecx,14
    call get_bits
    cmp eax,3ffeh
    jne frame_bad
    mov ecx,1
    call get_bits
    test eax,eax
    jnz frame_bad
    mov ecx,1
    call get_bits             ; fixed / variable blocking
    mov [frame_blocking],eax
    mov ecx,4
    call get_bits
    mov [block_code],eax
    mov ecx,4
    call get_bits
    mov [rate_code],eax
    mov ecx,4
    call get_bits
    cmp eax,10
    ja frame_bad
    mov [channel_mode],eax
    mov ecx,eax
    cmp ecx,8
    jae frame_stereo
    inc ecx
    jmp frame_ch_check
frame_stereo:
    mov ecx,2
frame_ch_check:
    cmp ecx,[source_channels]
    jne frame_bad
    mov ecx,3
    call get_bits
    mov [depth_code],eax
    mov ecx,1
    call get_bits
    test eax,eax
    jnz frame_bad
    ; UTF-8 encoded frame / sample number; validate prefix and continuations.
    mov ecx,8
    call get_bits
    mov [frame_number],rax
    mov dword ptr [frame_number_bytes],1
    cmp eax,80h
    jb frame_number_done
    cmp eax,0c0h
    jb frame_bad
    cmp eax,0ffh
    je frame_bad
    mov ebx,0
    mov edx,eax
number_prefix:
    test edx,80h
    jz number_counted
    inc ebx
    shl edx,1
    jmp number_prefix
number_counted:
    mov [frame_number_bytes],ebx
    mov ecx,ebx
    mov eax,127
    shr eax,cl
    and [frame_number],rax
    dec ebx
number_cont:
    mov ecx,8
    call get_bits
    mov edx,eax
    and edx,0c0h
    cmp edx,80h
    jne frame_bad
    and eax,3fh
    mov rdx,[frame_number]
    shl rdx,6
    or rdx,rax
    mov [frame_number],rdx
    dec ebx
    jnz number_cont
frame_number_done:
    mov rax,[frame_number]
    mov ecx,[frame_number_bytes]
    cmp ecx,1
    je frame_number_limit
    imul ecx,5
    sub ecx,4
    cmp ecx,6
    jne frame_number_minimum
    mov ecx,7
frame_number_minimum:
    mov rdx,1
    shl rdx,cl
    cmp rax,rdx
    jb frame_bad              ;reject noncanonical extended UTF-8 encodings
frame_number_limit:
    mov rdx,0fffffffffh
    cmp dword ptr [frame_blocking],0
    jne frame_number_check
    mov edx,7fffffffh
frame_number_check:
    cmp rax,rdx
    ja frame_bad
    mov eax,[block_code]
    test eax,eax
    jz frame_bad
    cmp eax,1
    je block192
    cmp eax,5
    jbe block576
    cmp eax,6
    je block8
    cmp eax,7
    je block16
    mov ecx,eax
    sub ecx,8
    mov eax,256
    shl eax,cl
    jmp block_done
block192:
    mov eax,192
    jmp block_done
block576:
    mov ecx,eax
    sub ecx,2
    mov eax,576
    shl eax,cl
    jmp block_done
block8:
    mov ecx,8
    call get_bits
    inc eax
    jmp block_done
block16:
    mov ecx,16
    call get_bits
    inc eax
block_done:
    cmp eax,65535
    ja frame_bad
    cmp eax,[maximum_block]
    ja frame_bad
    mov [frame_samples],eax
    mov dword ptr [frame_used],0
    mov eax,[rate_code]
    test eax,eax
    jz rate_done
    cmp eax,12
    je rate8
    cmp eax,14
    je rate16x10
    cmp eax,13
    je rate16
    cmp eax,15
    je frame_bad
    lea rdx,rate_table
    mov eax,[rdx+rax*4]
    jmp rate_check
rate8:
    mov ecx,8
    call get_bits
    imul eax,1000
    jmp rate_check
rate16x10:
    mov ecx,16
    call get_bits
    imul eax,10
    jmp rate_check
rate16:
    mov ecx,16
    call get_bits
rate_check:
    cmp eax,[sample_rate]
    jne frame_bad
rate_done:
    mov eax,[depth_code]
    test eax,eax
    jz inherited_depth
    lea rdx,depth_table
    mov eax,[rdx+rax*4]
    cmp eax,[source_bits]
    jne frame_bad
    jmp depth_done
inherited_depth:
    mov eax,[source_bits]
depth_done:
    mov [frame_bps],eax
    ; Header CRC byte is the next aligned byte.
    mov rax,[input_cursor]
    mov [header_end],rax
    mov ecx,8
    call get_bits
    mov ebx,eax
    mov rcx,[frame_start]
    mov rdx,[header_end]
    mov r8d,8
    call flac_crc
    cmp eax,ebx
    jne frame_bad
    mov rax,[frame_number]
    cmp dword ptr [frame_blocking],0
    jne frame_position_check
    mov ecx,[maximum_block]
    mul rcx
frame_position_check:
    cmp dword ptr [flac_seek_probe],0
    je frame_position_ordinary
    mov [flac_next_sample],rax
frame_position_ordinary:
    cmp rax,[flac_next_sample]
    jne frame_bad
    mov ecx,[frame_samples]
    add rax,rcx
    cmp qword ptr [total_frames],0
    je frame_position_valid
    cmp rax,[total_frames]
    ja frame_bad
frame_position_valid:
    lea rcx,left_samples
    mov edx,[frame_bps]
    cmp dword ptr [channel_mode],9
    jne left_depth_done
    inc edx
left_depth_done:
    call decode_subframe
    test eax,eax
    jz frame_bad
    cmp dword ptr [source_channels],1
    je subframes_done
    lea rcx,right_samples
    mov edx,[frame_bps]
    cmp dword ptr [channel_mode],8
    je right_extra
    cmp dword ptr [channel_mode],10
    jne right_depth_done
right_extra:
    inc edx
right_depth_done:
    call decode_subframe
    test eax,eax
    jz frame_bad
subframes_done:
    mov ecx,[bits_count]
    test ecx,ecx
    jz aligned_frame
    call get_bits
    test eax,eax
    jnz frame_bad
aligned_frame:
    mov rcx,[frame_start]
    mov rdx,[input_cursor]
    mov r8d,16
    call flac_crc
    mov ebx,eax
    mov ecx,16
    call get_bits
    cmp eax,ebx
    jne frame_bad
    cmp dword ptr [decode_error],0
    jne frame_bad
    mov rax,[input_cursor]
    cmp rax,[input_end]
    jae last_block_valid
    mov eax,[frame_samples]
    cmp eax,[minimum_block]
    jb frame_bad
last_block_valid:
    ; Restore left/right channels, using 64-bit intermediates.
    xor ebx,ebx
    lea rsi,left_samples
    lea rdi,right_samples
decorrelate:
    cmp ebx,[frame_samples]
    jae frame_ok
    mov rax,[rsi+rbx*8]
    mov rdx,[rdi+rbx*8]
    cmp dword ptr [channel_mode],8
    je left_side
    cmp dword ptr [channel_mode],9
    je side_right
    cmp dword ptr [channel_mode],10
    jne decor_next
    shl rax,1
    mov rcx,rdx
    and ecx,1
    or rax,rcx
    mov rcx,rax
    add rax,rdx
    sub rcx,rdx
    sar rax,1
    sar rcx,1
    mov [rsi+rbx*8],rax
    mov [rdi+rbx*8],rcx
    jmp decor_next
left_side:
    sub rax,rdx
    mov [rdi+rbx*8],rax
    jmp decor_next
side_right:
    add rax,rdx
    mov [rsi+rbx*8],rax
decor_next:
    mov ecx,64
    sub ecx,[source_bits]
    mov rax,[rsi+rbx*8]
    mov rdx,rax
    shl rdx,cl
    sar rdx,cl
    cmp rax,rdx
    jne frame_bad
    cmp dword ptr [source_channels],1
    je decor_range_valid
    mov rax,[rdi+rbx*8]
    mov rdx,rax
    shl rdx,cl
    sar rdx,cl
    cmp rax,rdx
    jne frame_bad
decor_range_valid:
    inc ebx
    jmp decorrelate
frame_ok:
    mov eax,[frame_samples]
    add [flac_next_sample],rax
    mov eax,1
    jmp frame_return
frame_bad:
    mov dword ptr [decode_error],3
frame_eof:
    xor eax,eax
frame_return:
    add rsp,64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
decode_frame ENDP

decode_subframe PROC
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
    mov [sub_bps],edx
    mov dword ptr [wasted_bits],0
    mov ecx,1
    call get_bits
    test eax,eax
    jnz sub_bad
    mov ecx,6
    call get_bits
    mov [sub_type],eax
    mov ecx,1
    call get_bits
    test eax,eax
    jz sub_header_done
    call get_unary
    inc eax
    mov [wasted_bits],eax
    cmp eax,[sub_bps]
    jae sub_bad
    sub [sub_bps],eax
sub_header_done:
    mov eax,[sub_type]
    test eax,eax
    jz sub_constant
    cmp eax,1
    je sub_verbatim
    cmp eax,8
    jb sub_bad
    cmp eax,12
    jbe sub_fixed
    cmp eax,32
    jb sub_bad
    sub eax,31
    mov [predict_order],eax
    jmp sub_warmup
sub_fixed:
    sub eax,8
    mov [predict_order],eax
sub_warmup:
    mov eax,[predict_order]
    cmp eax,[frame_samples]
    ja sub_bad
    xor ebx,ebx
warmup_loop:
    cmp ebx,[predict_order]
    jae warmup_done
    mov ecx,[sub_bps]
    call get_signed
    mov [rsi+rbx*8],rax
    inc ebx
    jmp warmup_loop
warmup_done:
    cmp dword ptr [sub_type],32
    jb residual_start
    mov ecx,4
    call get_bits
    cmp eax,15
    je sub_bad
    inc eax
    mov r12d,eax
    mov ecx,5
    call get_signed
    test eax,eax
    js sub_bad
    mov [predict_shift],eax
    xor ebx,ebx
coeff_loop:
    cmp ebx,[predict_order]
    jae residual_start
    mov ecx,r12d
    call get_signed
    lea rdx,lpc_coeff
    mov [rdx+rbx*8],rax
    inc ebx
    jmp coeff_loop
residual_start:
    mov ecx,2
    call get_bits
    cmp eax,1
    ja sub_bad
    add eax,4
    mov [rice_bits],eax
    mov ecx,4
    call get_bits
    mov ecx,eax
    mov eax,1
    shl eax,cl
    mov [partition_count],eax
    mov ecx,eax
    mov eax,[frame_samples]
    xor edx,edx
    div ecx
    test edx,edx
    jnz sub_bad
    mov [partition_samples],eax
    cmp eax,[predict_order]
    jb sub_bad
    xor r12d,r12d
    mov ebx,[predict_order]
partition_loop:
    mov r13d,[partition_samples]
    test r12d,r12d
    jnz partition_full
    sub r13d,[predict_order]
partition_full:
    mov ecx,[rice_bits]
    call get_bits
    mov [rice_k],eax
    mov ecx,[rice_bits]
    mov edx,1
    shl edx,cl
    dec edx
    cmp eax,edx
    je residual_escape
rice_samples:
    test r13d,r13d
    jz partition_done
    call get_unary
    mov r14,rax
    cmp dword ptr [decode_error],0
    jne sub_bad
rice_remainder:
    mov ecx,[rice_k]
    call get_bits
    mov ecx,[rice_k]
    shl r14,cl
    or rax,r14
    mov edx,0ffffffffh
    cmp rax,rdx
    ja sub_bad
    mov rdx,rax
    and edx,1
    neg rdx
    shr rax,1
    xor rax,rdx
    mov [rsi+rbx*8],rax
    inc ebx
    dec r13d
    jmp rice_samples
residual_escape:
    mov ecx,5
    call get_bits
    mov r14d,eax
escape_samples:
    test r13d,r13d
    jz partition_done
    xor eax,eax
    test r14d,r14d
    jz escape_zero
    mov ecx,r14d
    call get_signed
escape_zero:
    mov [rsi+rbx*8],rax
    inc ebx
    dec r13d
    jmp escape_samples
partition_done:
    inc r12d
    cmp r12d,[partition_count]
    jb partition_loop
    cmp ebx,[frame_samples]
    jne sub_bad
    ; Prediction. qword samples avoid overflow for 24-bit stereo side data.
    mov ebx,[predict_order]
prediction_loop:
    cmp ebx,[frame_samples]
    jae restore_wasted
    cmp dword ptr [sub_type],32
    jae lpc_predict
    mov ecx,[predict_order]
    xor eax,eax
    test ecx,ecx
    jz predicted
    mov rax,[rsi+rbx*8-8]
    cmp ecx,1
    je predicted
    shl rax,1
    sub rax,[rsi+rbx*8-16]
    cmp ecx,2
    je predicted
    mov rax,[rsi+rbx*8-8]
    imul rax,3
    mov rdx,[rsi+rbx*8-16]
    imul rdx,3
    sub rax,rdx
    add rax,[rsi+rbx*8-24]
    cmp ecx,3
    je predicted
    mov rax,[rsi+rbx*8-8]
    shl rax,2
    mov rdx,[rsi+rbx*8-16]
    imul rdx,6
    sub rax,rdx
    mov rdx,[rsi+rbx*8-24]
    shl rdx,2
    add rax,rdx
    sub rax,[rsi+rbx*8-32]
    jmp predicted
lpc_predict:
    xor eax,eax
    xor edi,edi
    lea r12,lpc_coeff
    lea r13,[rsi+rbx*8-8]
lpc_sum:
    cmp edi,[predict_order]
    jae lpc_shift
    mov rdx,[r13]
    imul rdx,[r12+rdi*8]
    add rax,rdx
    sub r13,8
    inc edi
    jmp lpc_sum
lpc_shift:
    mov ecx,[predict_shift]
    sar rax,cl
predicted:
    add [rsi+rbx*8],rax
    inc ebx
    jmp prediction_loop
sub_constant:
    mov ecx,[sub_bps]
    call get_signed
    xor ebx,ebx
constant_loop:
    cmp ebx,[frame_samples]
    jae restore_wasted
    mov [rsi+rbx*8],rax
    inc ebx
    jmp constant_loop
sub_verbatim:
    xor ebx,ebx
verbatim_loop:
    cmp ebx,[frame_samples]
    jae restore_wasted
    mov ecx,[sub_bps]
    call get_signed
    mov [rsi+rbx*8],rax
    inc ebx
    jmp verbatim_loop
restore_wasted:
    cmp dword ptr [decode_error],0
    jne sub_bad
    ; Validate reconstructed samples before exposing any decoded frame.
    xor ebx,ebx
range_loop:
    cmp ebx,[frame_samples]
    jae sub_ok
    mov rax,[rsi+rbx*8]
    mov ecx,64
    sub ecx,[sub_bps]
    mov rdx,rax
    shl rdx,cl
    sar rdx,cl
    cmp rax,rdx
    jne sub_bad
    mov ecx,[wasted_bits]
    shl rax,cl
    mov [rsi+rbx*8],rax
    inc ebx
    jmp range_loop
sub_ok:
    mov eax,1
    jmp sub_return
sub_bad:
    mov dword ptr [decode_error],4
    xor eax,eax
sub_return:
    add rsp,64
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
decode_subframe ENDP

decoder_read PROC
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
    cmp qword ptr [map_base],0
    je read_done
    cmp dword ptr [decode_error],0
    jne read_done
    cmp dword ptr [codec_kind],1
    jb read_done
    cmp dword ptr [codec_kind],5
    ja read_done
    cmp dword ptr [codec_kind],5
    jne read_try_vorbis
    mov rcx,rdi
    mov edx,r12d
    call opus_read
    mov ebx,eax
    jmp read_done
read_try_vorbis:
    cmp dword ptr [codec_kind],4
    jne read_try_mp3
    mov rcx,rdi
    mov edx,r12d
    call vorbis_read
    mov ebx,eax
    jmp read_done
read_try_mp3:
    cmp dword ptr [codec_kind],3
    jne read_existing
    mov rcx,rdi
    mov edx,r12d
    call mp3_read
    mov ebx,eax
    jmp read_done
read_existing:
    cmp dword ptr [codec_kind],1
    je read_wav
read_flac:
    cmp ebx,r12d
    jae read_done
    mov eax,[frame_used]
    cmp eax,[frame_samples]
    jb flac_emit
    call decode_frame
    test eax,eax
    jz read_done
flac_emit:
    mov ecx,[frame_used]
    lea rsi,left_samples
    cvtsi2ss xmm0,qword ptr [rsi+rcx*8]
    mulss xmm0,[float_scale]
    movss dword ptr [rdi+rbx*8],xmm0
    cmp dword ptr [source_channels],1
    je flac_mono
    lea rsi,right_samples
    cvtsi2ss xmm0,qword ptr [rsi+rcx*8]
    mulss xmm0,[float_scale]
flac_mono:
    movss dword ptr [rdi+rbx*8+4],xmm0
    inc dword ptr [frame_used]
    inc ebx
    jmp read_flac
read_wav:
    mov rsi,[input_cursor]
wav_emit:
    cmp ebx,r12d
    jae wav_read_done
    cmp rsi,[wav_end]
    jae wav_read_done
    call wav_sample
    movss dword ptr [rdi+rbx*8],xmm0
    cmp dword ptr [source_channels],1
    je wav_mono
    call wav_sample
wav_mono:
    movss dword ptr [rdi+rbx*8+4],xmm0
    inc ebx
    jmp wav_emit
wav_read_done:
    mov [input_cursor],rsi
read_done:
    mov eax,ebx
    add rsp,48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
decoder_read ENDP

wav_sample PROC
    cmp dword ptr [wav_format],3
    je sample_float
    mov eax,[source_bits]
    cmp eax,8
    je sample8
    cmp eax,16
    je sample16
    cmp eax,24
    je sample24
    movsxd rax,dword ptr [rsi]
    cvtsi2ss xmm0,rax
    mulss xmm0,[scale32]
    add rsi,4
    ret
sample8:
    movzx eax,byte ptr [rsi]
    sub eax,128
    cvtsi2ss xmm0,eax
    mulss xmm0,[scale8]
    inc rsi
    ret
sample16:
    movsx eax,word ptr [rsi]
    cvtsi2ss xmm0,eax
    mulss xmm0,[scale16]
    add rsi,2
    ret
sample24:
    movzx eax,word ptr [rsi]
    movsx edx,byte ptr [rsi+2]
    shl edx,16
    or eax,edx
    cvtsi2ss xmm0,eax
    mulss xmm0,[scale24]
    add rsi,3
    ret
sample_float:
    mov eax,[rsi]
    mov edx,eax
    and edx,7f800000h
    cmp edx,7f800000h
    jne sample_float_ok
    xor eax,eax             ; NaN / Infinity sanitized to silence
sample_float_ok:
    movd xmm0,eax
    add rsi,4
    ret
wav_sample ENDP
END
