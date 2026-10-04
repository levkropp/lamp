; LAMP: original x86-64 assembly decoders. MIT license, see LICENSE.
; ABI: decoder_open(RCX=path W) -> EAX=1 on success; decoder_read(RCX=stereo
; float output, EDX=frame capacity) -> EAX=frames. 0=EOF or error.
; The decoder is single-instance and only called by the producer thread.
option casemap:none
EXTERN CreateFileW:PROC, GetFileSizeEx:PROC, CreateFileMappingW:PROC
EXTERN MapViewOfFile:PROC, UnmapViewOfFile:PROC, CloseHandle:PROC
EXTERN VirtualAlloc:PROC,VirtualFree:PROC
EXTERN mp3_open:PROC, mp3_read:PROC,mp3_seek:PROC,mp3_close:PROC
EXTERN vorbis_open:PROC, vorbis_read:PROC, vorbis_close:PROC, ogg_close:PROC
EXTERN vorbis_seek:PROC
EXTERN opus_open:PROC,opus_read:PROC,opus_close:PROC,opus_seek:PROC
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
wav_kind dd 0                  ; 0 RIFF, 1 RF64, 2 BW64
wav_ds64 dq 0
wav_size_table dq 0
wav_table_count dd 0
wav_table_used dd 0
wav_data_seen dd 0
wav_fact_seen dd 0
wav_fact_frames dq 0
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
wav_container_bits dd 0
wav_valid_bits dd 0
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
flac_extra dq 0
flac_channel_ptrs dq 8 dup (0)
pcm_channel_mask dd 0
pcm_mask_seen dd 0
flac_comments_seen dd 0
pcm_mix dd 0
pcm_ignore_extra dd 0
; Canonical FLAC/WAVE channel order is increasing WAVE speaker bit order.
pcm_default_masks dd 4,3,7,33h,37h,3fh,70fh,63fh
flac_mask_name db 'waveformatextensible_channel_mask='
; Horizontal fronts, center/LFE, rear/side spread, and height folds.
; q=1/sqrt(2), a=sqrt(3)/2. Height speakers use q times their base route.
pcm_speaker_weights real8 1.0,0.0, 0.0,1.0
 real8 0.7071067811865475244,0.7071067811865475244
 real8 0.7071067811865475244,0.7071067811865475244
 real8 0.8660254037844386468,0.5, 0.5,0.8660254037844386468
 real8 0.7071067811865475244,0.0, 0.0,0.7071067811865475244
 real8 0.6123724356957945245,0.6123724356957945245
 real8 0.8660254037844386468,0.5, 0.5,0.8660254037844386468
 real8 0.5,0.5
 real8 0.7071067811865475244,0.0, 0.5,0.5, 0.0,0.7071067811865475244
 real8 0.6123724356957945245,0.3535533905932737622
 real8 0.4330127018922193234,0.4330127018922193234
 real8 0.3535533905932737622,0.6123724356957945245
pcm_mix_one real8 1.0
pcm_mix_two real8 2.0
pcm_mix_coeff real8 16 dup (0.0)
wav_float_max real8 3.4028234663852885981e38
wav_float_min real8 -3.4028234663852885981e38
rate_table dd 0,88200,176400,192000,8000,16000,22050,24000,32000,44100,48000,96000
depth_table dd 0,8,12,0,16,20,24,32

.data?
left_samples dq 65536 dup (?)
right_samples dq 65536 dup (?)
lpc_coeff dq 32 dup (?)
crc8_table db 256 dup (?)
crc16_table dw 256 dup (?)
wav_table_bits dq 64 dup (?)   ; at most 4096 ds64 entries, consumed once

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
    mov dword ptr [wav_kind],0
    mov qword ptr [wav_ds64],0
    mov qword ptr [wav_size_table],0
    mov dword ptr [wav_table_count],0
    mov dword ptr [wav_table_used],0
    mov dword ptr [wav_data_seen],0
    mov dword ptr [wav_fact_seen],0
    mov qword ptr [wav_fact_frames],0
    mov qword ptr [flac_begin],0
    mov qword ptr [flac_seek_table],0
    mov dword ptr [flac_seek_count],0
    mov qword ptr [flac_next_sample],0
    mov dword ptr [flac_seek_probe],0
    mov dword ptr [pcm_mask_seen],0
    mov dword ptr [flac_comments_seen],0
    mov dword ptr [pcm_mix],0
    mov dword ptr [pcm_ignore_extra],0
    mov dword ptr [wav_valid_bits],0
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
    cmp dword ptr [rax],34364652h ; RF64
    je open_rf64
    cmp dword ptr [rax],34365742h ; BW64
    je open_bw64
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
open_rf64:
    mov dword ptr [wav_kind],1
    jmp open_wav
open_bw64:
    mov dword ptr [wav_kind],2
open_wav:
    cmp dword ptr [rax+8],45564157h
    jne open_bad
    cmp dword ptr [wav_kind],0
    je wav_riff_size
    ; RF64/BW64 require ds64 immediately after the twelve-byte header.
    ; Bound its fixed prefix before reading any 64-bit fields or table count.
    lea r8,[rax+48]
    cmp r8,[input_end]
    ja open_bad
    cmp dword ptr [rax+12],34367364h
    jne open_bad
    mov edx,[rax+16]
    cmp edx,28
    jb open_bad
    cmp edx,0ffffffffh
    je open_bad
    lea r9,[rax+20]
    mov [wav_ds64],r9
    mov r8,r9
    add r8,rdx
    jc open_bad
    cmp r8,[input_end]
    ja open_bad
    mov ecx,[r9+24]
    cmp ecx,4096
    ja open_bad
    mov [wav_table_count],ecx
    imul rcx,12
    add rcx,28
    cmp rcx,rdx
    ja open_bad
    lea rcx,[r9+28]
    mov [wav_size_table],rcx
    lea rcx,wav_table_bits
    xor edx,edx
wav_clear_table:
    mov qword ptr [rcx+rdx*8],0
    inc edx
    cmp edx,64
    jb wav_clear_table
    mov edx,[rax+4]
    cmp edx,0ffffffffh
    jne wav_container_size
    mov rdx,[r9]
    jmp wav_container_size
wav_riff_size:
    mov edx,[rax+4]
    lea r8,[rax+12]
wav_container_size:
    cmp rdx,4
    jb open_bad
    add rdx,8
    jc open_bad
    cmp rdx,[file_size]
    ja open_bad
    add rdx,rax
    jc open_bad
    mov [input_end],rdx
    ; Chunk payload padding is relative to the even file base.
    mov r10,r8
    add r10,1
    jc open_bad
    and r10,-2
    cmp r10,rdx
    ja open_bad
    xor r11d,r11d              ; fmt found
wav_chunks:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz wav_chunk_continue
    cmp dword ptr [rax],0
    jne open_bad
wav_chunk_continue:
    cmp r10,[input_end]
    je wav_complete
    lea rax,[r10+8]
    cmp rax,r10
    jb open_bad
    cmp rax,[input_end]
    ja open_bad
    mov edx,[r10+4]
    cmp edx,0ffffffffh
    jne wav_chunk_size
    cmp dword ptr [wav_kind],0
    je open_bad
    cmp dword ptr [r10],61746164h
    jne wav_table_lookup
    mov r9,[wav_ds64]
    mov rdx,[r9+8]
    jmp wav_chunk_size
wav_table_lookup:
    ; Match the first unused entry for this FourCC. Different chunk IDs may
    ; appear in another order; repeated IDs consume their entries in order.
    mov r9,[wav_size_table]
    xor ecx,ecx
wav_table_scan:
    cmp ecx,[wav_table_count]
    jae open_bad
    mov edx,[r9]
    cmp edx,[r10]
    jne wav_table_skip
    lea rdx,wav_table_bits
    bt qword ptr [rdx],rcx
    jc wav_table_skip
    bts qword ptr [rdx],rcx
    inc dword ptr [wav_table_used]
    mov rdx,[r9+4]
    jmp wav_chunk_size
wav_table_skip:
    add r9,12
    inc ecx
    jmp wav_table_scan
wav_chunk_size:
    mov r8,rax
    add r8,rdx
    jc open_bad
    cmp r8,[input_end]
    ja open_bad
    cmp dword ptr [r10],20746d66h
    je wav_fmt
    cmp dword ptr [r10],61746164h
    je wav_data
    cmp dword ptr [r10],74636166h
    je wav_fact
    cmp dword ptr [r10],34367364h
    je open_bad
wav_next:
    add r8,1
    jc open_bad
    and r8,-2
    cmp r8,[input_end]
    ja open_bad
    mov r10,r8
    jmp wav_chunks
wav_fmt:
    test r11d,r11d
    jnz open_bad
    cmp rdx,16
    jb open_bad
    cmp rdx,16
    je wav_fmt_size_valid
    cmp rdx,18
    jb open_bad
    movzx ecx,word ptr [rax+16]
    add ecx,18
    cmp rcx,rdx
    ja open_bad
wav_fmt_size_valid:
    movzx ecx,word ptr [rax]
    cmp ecx,0fffeh
    jne wav_basic_fmt
    cmp rdx,40
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
    mov [wav_valid_bits],r9d
    mov r9d,[rax+20]
    mov [pcm_channel_mask],r9d
    mov dword ptr [pcm_mask_seen],1
    mov dword ptr [pcm_ignore_extra],1
    test r9d,r9d
    jnz wav_basic_fmt
    ; Direct-out has no speaker positions: present the first two ports as
    ; stereo (duplicate a single port), without interpreting extra tracks.
    mov dword ptr [pcm_channel_mask],3
    cmp word ptr [rax+2],1
    jne wav_basic_fmt
    mov dword ptr [pcm_channel_mask],4
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
    cmp ecx,8
    ja open_bad
    mov [source_channels],ecx
    mov ecx,[rax+4]
    cmp ecx,8000
    jb open_bad
    cmp ecx,192000
    ja open_bad
    mov [sample_rate],ecx
    movzx ecx,word ptr [rax+14]
    mov [wav_container_bits],ecx
    cmp dword ptr [wav_format],3
    jne wav_pcm_bits
    cmp ecx,32
    je wav_bits_ok
    cmp ecx,64
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
    shr ecx,3
    imul ecx,[source_channels]
    cmp cx,[rax+12]
    jne open_bad
    mov [wav_align],ecx
    imul ecx,[sample_rate]
    cmp ecx,[rax+8]
    jne open_bad
    mov ecx,[wav_valid_bits]
    test ecx,ecx
    jnz wav_precision_set
    mov ecx,[wav_container_bits]
wav_precision_set:
    cmp ecx,[wav_container_bits]
    ja open_bad
    cmp dword ptr [wav_format],3
    jne wav_precision_valid
    cmp ecx,[wav_container_bits]
    jne open_bad
wav_precision_valid:
    mov [source_bits],ecx
    mov r11d,1
    jmp wav_next
wav_data:
    test r11d,r11d
    jz open_bad
    cmp dword ptr [wav_data_seen],0
    jne open_bad
    mov dword ptr [wav_data_seen],1
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
    jmp wav_next
wav_fact:
    cmp dword ptr [wav_fact_seen],0
    jne open_bad
    cmp rdx,4
    jb open_bad
    mov dword ptr [wav_fact_seen],1
    mov ecx,[rax]
    cmp ecx,0ffffffffh
    jne wav_fact_count
    cmp dword ptr [wav_kind],1
    jne open_bad
    mov r9,[wav_ds64]
    mov rcx,[r9+16]
wav_fact_count:
    mov [wav_fact_frames],rcx
    jmp wav_next
wav_complete:
    cmp dword ptr [wav_data_seen],0
    je open_bad
    mov eax,[wav_table_used]
    cmp eax,[wav_table_count]
    jne open_bad
    mov rax,[wav_fact_frames]
    test rax,rax               ; zero means unspecified for PCM/float
    jz wav_frame_count_valid
    cmp rax,[total_frames]
    jne open_bad
wav_frame_count_valid:
    call pcm_build_mix
    test eax,eax
    jz open_bad
    mov eax,128
    sub eax,[wav_container_bits]
    shl eax,23
    mov [float_scale],eax
    mov dword ptr [codec_kind],1
    mov eax,1
    leave
    ret

open_flac:
    add rax,4
    mov r10,rax
    xor r11d,r11d
flac_metadata:
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz flac_metadata_continue
    cmp dword ptr [rax],0
    jne open_bad
flac_metadata_continue:
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
    mov [source_channels],ecx
    mov rcx,rdx
    shr rcx,36
    and ecx,31
    inc ecx
    cmp ecx,4
    jb open_bad
    cmp ecx,32
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
    cmp ecx,4
    je flac_comments
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
    jmp flac_meta_next
flac_comments:
    cmp dword ptr [flac_comments_seen],0
    jne open_bad
    mov dword ptr [flac_comments_seen],1
    mov [rsp+56],r8
    mov [rsp+64],r9
    mov [rsp+72],r11
    mov rcx,rax
    mov rdx,r9
    call flac_parse_comments
    mov r8,[rsp+56]
    mov r9,[rsp+64]
    mov r11,[rsp+72]
    test eax,eax
    jz open_bad
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
    call pcm_build_mix
    test eax,eax
    jz open_bad
    lea rax,left_samples
    mov [flac_channel_ptrs],rax
    lea rax,right_samples
    mov [flac_channel_ptrs+8],rax
    mov eax,[source_channels]
    cmp eax,2
    jbe flac_buffers_ready
    sub eax,2
    imul eax,[maximum_block]
    shl eax,3
    mov edx,eax
    xor ecx,ecx
    mov r8d,3000h
    mov r9d,4
    call VirtualAlloc
    test rax,rax
    jz open_bad
    mov [flac_extra],rax
    mov ecx,2
    mov edx,[maximum_block]
    shl edx,3
    lea r8,flac_channel_ptrs
flac_buffers_loop:
    mov [r8+rcx*8],rax
    add rax,rdx
    inc ecx
    cmp ecx,[source_channels]
    jb flac_buffers_loop
flac_buffers_ready:
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

; RCX=comment payload, RDX=bounded end. Little-endian lengths, no framing bit.
; Conflicting repeated masks are rejected; identical repeats are harmless.
flac_parse_comments PROC
    push rbx
    push rsi
    push rdi
    push r12
    mov rsi,rcx
    mov r12,rdx
    lea rax,[rsi+4]
    cmp rax,r12
    ja comments_bad
    mov ecx,[rsi]
    lea rsi,[rax+rcx]
    cmp rsi,r12
    ja comments_bad
    cmp rsi,r12
    je comments_ok
    lea rax,[rsi+4]
    cmp rax,r12
    ja comments_bad
    mov ebx,[rsi]
    mov rsi,rax
comments_field:
    test ebx,ebx
    jz comments_end
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz comments_not_cancelled
    cmp dword ptr [rax],0
    jne comments_bad
comments_not_cancelled:
    lea rax,[rsi+4]
    cmp rax,r12
    ja comments_bad
    mov ecx,[rsi]
    lea rdi,[rax+rcx]
    cmp rdi,r12
    ja comments_bad
    mov rsi,rdi
    cmp ecx,SIZEOF flac_mask_name
    jb comments_next
    xor edx,edx
    lea r8,flac_mask_name
comments_key:
    movzx ecx,byte ptr [rax+rdx]
    cmp ecx,'A'
    jb comments_key_compare
    cmp ecx,'Z'
    ja comments_key_compare
    add ecx,32
comments_key_compare:
    cmp cl,[r8+rdx]
    jne comments_next
    inc edx
    cmp edx,SIZEOF flac_mask_name
    jb comments_key
    add rax,SIZEOF flac_mask_name
    lea r8,[rax+3]
    cmp r8,rdi
    ja comments_bad
    cmp byte ptr [rax],'0'
    jne comments_bad
    movzx ecx,byte ptr [rax+1]
    or ecx,20h
    cmp ecx,'x'
    jne comments_bad
    add rax,2
    xor r9d,r9d
comments_hex:
    mov r10,[ogg_cancel_ptr]
    test r10,r10
    jz comments_hex_continue
    cmp dword ptr [r10],0
    jne comments_bad
comments_hex_continue:
    movzx ecx,byte ptr [rax]
    sub ecx,'0'
    cmp ecx,9
    jbe comments_digit
    add ecx,'0'
    or ecx,20h
    sub ecx,'a'
    cmp ecx,5
    ja comments_bad
    add ecx,10
comments_digit:
    test r9d,0f0000000h
    jnz comments_bad
    shl r9d,4
    or r9d,ecx
    inc rax
    cmp rax,rdi
    jb comments_hex
    cmp dword ptr [pcm_mask_seen],0
    je comments_save_mask
    cmp r9d,[pcm_channel_mask]
    jne comments_bad
comments_save_mask:
    mov [pcm_channel_mask],r9d
    mov dword ptr [pcm_mask_seen],1
comments_next:
    dec ebx
    jmp comments_field
comments_end:
    cmp rsi,r12
    jne comments_bad
comments_ok:
    mov eax,1
    jmp comments_return
comments_bad:
    xor eax,eax
comments_return:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
flac_parse_comments ENDP

; Original stereo rendering policy. Canonical layouts match RFC 7845 gains,
; reordered into FLAC/WAVE order. Unassigned channels have zero coefficients.
; Normalize the larger row sum to 1 (<=4 speakers) or 2 (>=5 speakers).
pcm_build_mix PROC
    cmp dword ptr [pcm_mask_seen],0
    jne mix_mask_ready
    mov eax,[source_channels]
    dec eax
    lea rcx,pcm_default_masks
    mov eax,[rcx+rax*4]
    mov [pcm_channel_mask],eax
mix_mask_ready:
    mov r11d,[pcm_channel_mask]
    test r11d,0fffc0000h
    jnz mix_bad
    lea r8,pcm_mix_coeff
    xorpd xmm0,xmm0
    xor eax,eax
mix_zero:
    movupd [r8+rax],xmm0
    add eax,16
    cmp eax,128
    jb mix_zero
    xorpd xmm1,xmm1
    xor ecx,ecx
    xor edx,edx
    lea r10,pcm_speaker_weights
mix_speaker:
    bt r11d,ecx
    jnc mix_next_speaker
    cmp edx,[source_channels]
    jb mix_assign_speaker
    cmp dword ptr [pcm_ignore_extra],0
    je mix_bad
    jmp mix_next_speaker
mix_assign_speaker:
    movsd xmm2,qword ptr [r10]
    movsd xmm3,qword ptr [r10+8]
    movsd qword ptr [r8],xmm2
    movsd qword ptr [r8+8],xmm3
    addsd xmm0,xmm2
    addsd xmm1,xmm3
    add r8,16
    inc edx
mix_next_speaker:
    add r10,16
    inc ecx
    cmp ecx,18
    jb mix_speaker
    maxsd xmm0,xmm1
    test edx,edx
    jz mix_enable
    movsd xmm2,[pcm_mix_one]
    cmp edx,4
    jbe mix_normalize
    movsd xmm2,[pcm_mix_two]
mix_normalize:
    divsd xmm2,xmm0
    lea r8,pcm_mix_coeff
    mov ecx,[source_channels]
mix_scale:
    movsd xmm0,qword ptr [r8]
    movsd xmm1,qword ptr [r8+8]
    mulsd xmm0,xmm2
    mulsd xmm1,xmm2
    movsd qword ptr [r8],xmm0
    movsd qword ptr [r8+8],xmm1
    add r8,16
    dec ecx
    jnz mix_scale
mix_enable:
    mov dword ptr [pcm_mix],1
    cmp dword ptr [source_channels],2
    jne mix_check_mono
    cmp r11d,3
    jne mix_ok
    mov dword ptr [pcm_mix],0
    jmp mix_ok
mix_check_mono:
    cmp dword ptr [source_channels],1
    jne mix_ok
    cmp r11d,4
    jne mix_ok
    mov dword ptr [pcm_mix],0
mix_ok:
    mov eax,1
    ret
mix_bad:
    xor eax,eax
    ret
pcm_build_mix ENDP

decoder_close PROC
    push rbp
    mov rbp,rsp
    sub rsp,32
    call mp3_close
    call opus_close
    call vorbis_close
    call ogg_close
    mov rcx,[flac_extra]
    test rcx,rcx
    jz close_flac_buffers
    xor edx,edx
    mov r8d,8000h
    call VirtualFree
    mov qword ptr [flac_extra],0
close_flac_buffers:
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
; Opus restores a packet checkpoint before at least80ms PCM pre-roll.
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
    cmp dword ptr [codec_kind],5
    je seek_opus
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
seek_opus:
    call opus_seek
    jmp seek_return
seek_wav:
    mov rdx,[ogg_cancel_ptr]
    test rdx,rdx
    jz seek_wav_continue
    cmp dword ptr [rdx],0
    jne seek_return
seek_wav_continue:
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

; Bounds-checked MSB-first reservoir. Width <=33, result unsigned in RAX.
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
    mov r12d,2
additional_subframes:
    cmp r12d,[source_channels]
    jae subframes_done
    lea rax,flac_channel_ptrs
    mov rcx,[rax+r12*8]
    mov edx,[frame_bps]
    call decode_subframe
    test eax,eax
    jz frame_bad
    inc r12d
    jmp additional_subframes
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
    jae additional_range_start
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
additional_range_start:
    mov r12d,2
additional_range_channel:
    cmp r12d,[source_channels]
    jae frame_ok
    lea rax,flac_channel_ptrs
    mov rsi,[rax+r12*8]
    xor ebx,ebx
    mov ecx,64
    sub ecx,[source_bits]
additional_range_sample:
    cmp ebx,[frame_samples]
    jae additional_range_next
    mov rax,[rsi+rbx*8]
    mov rdx,rax
    shl rdx,cl
    sar rdx,cl
    cmp rax,rdx
    jne frame_bad
    inc ebx
    jmp additional_range_sample
additional_range_next:
    inc r12d
    jmp additional_range_channel
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
    mov edx,0fffffffeh     ; RFC 9639 excludes INT_MIN residuals
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
    add rax,[rsi+rbx*8]
    ; Reject an out-of-range prediction before it can enter LPC history.
    ; Valid history bounds every later 32-tap accumulator to 53 bits.
    mov ecx,64
    sub ecx,[sub_bps]
    mov rdx,rax
    shl rdx,cl
    sar rdx,cl
    cmp rax,rdx
    jne sub_bad
    mov [rsi+rbx*8],rax
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
    test r12d,r12d
    jz read_done
    mov rax,[ogg_cancel_ptr]
    test rax,rax
    jz read_existing_dispatch
    cmp dword ptr [rax],0
    je read_existing_dispatch
    mov dword ptr [decode_error],3
    jmp read_done
read_existing_dispatch:
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
    cmp dword ptr [pcm_mix],0
    jne flac_emit_mix
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
    jmp flac_emit_done
flac_emit_mix:
    xor r9d,r9d
    lea r10,flac_channel_ptrs
    lea r11,pcm_mix_coeff
    xorpd xmm0,xmm0
    xorpd xmm1,xmm1
flac_emit_channel:
    mov rax,[r10+r9*8]
    cvtsi2sd xmm2,qword ptr [rax+rcx*8]
    movapd xmm3,xmm2
    mulsd xmm2,qword ptr [r11]
    mulsd xmm3,qword ptr [r11+8]
    addsd xmm0,xmm2
    addsd xmm1,xmm3
    add r11,16
    inc r9d
    cmp r9d,[source_channels]
    jb flac_emit_channel
    cvtss2sd xmm2,[float_scale]
    mulsd xmm0,xmm2
    mulsd xmm1,xmm2
    cvtsd2ss xmm0,xmm0
    cvtsd2ss xmm1,xmm1
    movss dword ptr [rdi+rbx*8],xmm0
    movss dword ptr [rdi+rbx*8+4],xmm1
flac_emit_done:
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
    cmp dword ptr [pcm_mix],0
    jne wav_emit_mix
    call wav_sample
    movss dword ptr [rdi+rbx*8],xmm0
    cmp dword ptr [source_channels],1
    je wav_mono
    call wav_sample
wav_mono:
    movss dword ptr [rdi+rbx*8+4],xmm0
    jmp wav_emit_done
wav_emit_mix:
    xor r9d,r9d
    lea r10,pcm_mix_coeff
    xorpd xmm4,xmm4
    xorpd xmm5,xmm5
wav_mix_channel:
    call wav_sample_double
    movapd xmm1,xmm0
    mulsd xmm0,qword ptr [r10]
    mulsd xmm1,qword ptr [r10+8]
    addsd xmm4,xmm0
    addsd xmm5,xmm1
    add r10,16
    inc r9d
    cmp r9d,[source_channels]
    jb wav_mix_channel
    minsd xmm4,[wav_float_max]
    maxsd xmm4,[wav_float_min]
    minsd xmm5,[wav_float_max]
    maxsd xmm5,[wav_float_min]
    cvtsd2ss xmm0,xmm4
    cvtsd2ss xmm1,xmm5
    movss dword ptr [rdi+rbx*8],xmm0
    movss dword ptr [rdi+rbx*8+4],xmm1
wav_emit_done:
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
    sub rsp,40
    call wav_sample_double
    cvtsd2ss xmm0,xmm0
    add rsp,40
    ret
wav_sample ENDP

; RSI advances by the physical container width. Caller accumulation uses
; XMM4/5 and R9/10; this helper preserves them. Finite float64 inputs clamp
; to the representable float32 range before mixing; NaN/Inf become silence.
wav_sample_double PROC
    cmp dword ptr [wav_format],3
    je sample_float
    sub rsp,40
    call wav_integer_sample
    cvtsi2sd xmm0,rax
    cvtss2sd xmm1,[float_scale]
    mulsd xmm0,xmm1
    add rsp,40
    ret
sample_float:
    cmp dword ptr [wav_container_bits],64
    je sample_float64
    mov eax,[rsi]
    add rsi,4
    mov edx,eax
    and edx,7f800000h
    cmp edx,7f800000h
    je sample_float_bad
    movd xmm0,eax
    cvtss2sd xmm0,xmm0
    ret
sample_float64:
    mov rax,[rsi]
    add rsi,8
    mov rdx,07ff0000000000000h
    and rdx,rax
    mov rcx,07ff0000000000000h
    cmp rdx,rcx
    je sample_float_bad
    movq xmm0,rax
    minsd xmm0,[wav_float_max]
    maxsd xmm0,[wav_float_min]
    ret
sample_float_bad:
    xorpd xmm0,xmm0
    ret
wav_sample_double ENDP

wav_integer_sample PROC
    mov eax,[wav_container_bits]
    cmp eax,8
    je sample8
    cmp eax,16
    je sample16
    cmp eax,24
    je sample24
    movsxd rax,dword ptr [rsi]
    add rsi,4
    jmp sample_padding
sample8:
    movzx eax,byte ptr [rsi]
    sub eax,128
    movsxd rax,eax
    inc rsi
    jmp sample_padding
sample16:
    movsx rax,word ptr [rsi]
    add rsi,2
    jmp sample_padding
sample24:
    movzx eax,word ptr [rsi]
    movsx edx,byte ptr [rsi+2]
    shl edx,16
    or eax,edx
    movsxd rax,eax
    add rsi,3
sample_padding:
    mov ecx,[wav_container_bits]
    sub ecx,[source_bits]
    sar rax,cl
    shl rax,cl
    ret
wav_integer_sample ENDP
END
