# LAMP: original x86-64 assembly decoders. MIT license, see LICENSE.
# ABI: decoder_open(RCX=native path) -> EAX=1 on success; decoder_read(RCX=stereo
# float output, EDX=frame capacity) -> EAX=frames. 0=EOF or error.
# The decoder is single-instance and only called by the producer thread.
.include "lamp.inc"
.globl sample_rate, source_channels, source_bits, decode_error, total_frames, codec_kind
.globl decoder_seek_probes, flac_ogg_index_count, flac_ogg_index_stride, flac_declared_frames
.globl maximum_block, pcm_channel_mask, pcm_mask_seen, pcm_ignore_extra, pcm_mix, frame_samples, frame_used
.globl flac_channel_ptrs
.globl pcm_speaker_weights, pcm_mix_coeff
.globl track_choice, track_choice_used

.equ TK_ADPCM, 10                   # track codec of WAVE ADPCM (src/track.s)

.data
sample_rate: .long 0
source_channels: .long 0
source_bits: .long 0
decode_error: .long 0
codec_kind: .long 0                 #1 WAV,2 FLAC,3 MP3,4 Vorbis,5 Opus,6 AIFF/AIFC,...,11 AC-3,12 WavPack,13 CAF,14 AVI,15 FLV,16 AU,17 APE
total_frames: .quad 0
map_token: .quad 0
map_base: .quad 0
file_size: .quad 0
input_cursor: .quad 0
input_end: .quad 0
wav_end: .quad 0
wav_begin: .quad 0
wav_kind: .long 0                  # 0 RIFF, 1 RF64, 2 BW64
wav_layout: .long 0                # chunks: 0 RIFF family, 1 RIFX (big-endian), 2 Wave64 (GUIDs)
wav_codec_kind: .long 1            # codec_kind of an opened WAV reader: 1, or 14 AVI, 15 FLV, 18 LPCM in MPEG-TS/PS
# The audio track to play: 0 for the container's own choice, else the Nth
# audio track (from 1) in the container's order. Containers of several
# tracks set track_choice_used when they honoured it; any other file plays
# only as track 1.
track_choice: .long 0
track_choice_used: .long 0
wav_ds64: .quad 0
wav_size_table: .quad 0
wav_table_count: .long 0
wav_table_used: .long 0
wav_data_seen: .long 0
wav_fact_seen: .long 0
wav_fact_frames: .quad 0
flac_begin: .quad 0
flac_seek_table: .quad 0
flac_seek_count: .long 0
flac_next_sample: .quad 0
flac_bit_end: .quad 0
flac_seek_probe: .long 0
decoder_seek_probes: .long 0
frame_blocking: .long 0
frame_number_bytes: .long 0
frame_number: .quad 0
wav_format: .long 0
wav_align: .long 0
wav_container_bits: .long 0
wav_valid_bits: .long 0
pcm_big_endian: .long 0
pcm_signed8: .long 0
pcm_g711: .long 0                   # 8-bit codes: 1 A-law, 2 mu-law (G.711)
wav_codec: .long 0                  # compressed WAVE format tag, 0 for PCM/float
wav_codec_fmt: .quad 0              # its fmt chunk
wav_codec_fmt_bytes: .long 0
bits_count: .long 0
bits_buf: .quad 0
frame_start: .quad 0
header_end: .quad 0
frame_samples: .long 0
frame_used: .long 0
channel_mode: .long 0
block_code: .long 0
rate_code: .long 0
depth_code: .long 0
frame_bps: .long 0
minimum_block: .long 0
maximum_block: .long 0
sub_bps: .long 0
wasted_bits: .long 0
sub_type: .long 0
predict_order: .long 0
predict_shift: .long 0
rice_bits: .long 0
rice_k: .long 0
partition_count: .long 0
partition_samples: .long 0
crc_ready: .long 0
scale8: .long 0x3c000000
scale16: .long 0x38000000
scale24: .long 0x34000000
scale32: .long 0x30000000
float_scale: .float 0.0
flac_extra: .quad 0
flac_packet_mode: .long 0          # FLAC-in-Ogg: one frame per Ogg packet
flac_packet_final: .long 0
flac_ogg_index: .quad 0
flac_ogg_index_count: .long 0
flac_ogg_index_stride: .quad 1
flac_declared_frames: .quad 0
flac_scan_position: .quad 0
flac_channel_ptrs: .zero 8*8
pcm_channel_mask: .long 0
pcm_mask_seen: .long 0
flac_comments_seen: .long 0
pcm_mix: .long 0
pcm_ignore_extra: .long 0
# Canonical FLAC/WAVE channel order is increasing WAVE speaker bit order.
pcm_default_masks: .long 4, 3, 7, 0x33, 0x37, 0x3f, 0x70f, 0x63f
flac_mask_name: .ascii "waveformatextensible_channel_mask="
.equ FLAC_MASK_NAME_BYTES, 34
.if . - flac_mask_name - FLAC_MASK_NAME_BYTES
.error "FLAC_MASK_NAME_BYTES differs from the tag length"
.endif
# Horizontal fronts, center/LFE, rear/side spread, and height folds.
# q=1/sqrt(2), a=sqrt(3)/2. Height speakers use q times their base route.
pcm_speaker_weights: .double 1.0, 0.0, 0.0, 1.0
 .double 0.7071067811865475244, 0.7071067811865475244
 .double 0.7071067811865475244, 0.7071067811865475244
 .double 0.8660254037844386468, 0.5, 0.5, 0.8660254037844386468
 .double 0.7071067811865475244, 0.0, 0.0, 0.7071067811865475244
 .double 0.6123724356957945245, 0.6123724356957945245
 .double 0.8660254037844386468, 0.5, 0.5, 0.8660254037844386468
 .double 0.5, 0.5
 .double 0.7071067811865475244, 0.0, 0.5, 0.5, 0.0, 0.7071067811865475244
 .double 0.6123724356957945245, 0.3535533905932737622
 .double 0.4330127018922193234, 0.4330127018922193234
 .double 0.3535533905932737622, 0.6123724356957945245
pcm_mix_one: .double 1.0
pcm_mix_two: .double 2.0
pcm_mix_coeff: .zero 16*8
wav_float_max: .double 3.4028234663852885981e38
wav_float_min: .double -3.4028234663852885981e38
rate_table: .long 0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000
depth_table: .long 0, 8, 12, 0, 16, 20, 24, 32

# RIFX fmt fields to reverse: offset and width (8: the GUID's last bytes).
wav_fmt_fields: .byte 0, 2, 2, 2, 4, 4, 8, 4, 12, 2, 14, 2, 16, 2, 18, 2, 20, 4, 24, 4, 28, 2, 30, 2, 32, 8, 0x80

.bss
left_samples: .zero 65536*8
wav_fmt_copy: .zero 48              # RIFX fmt fields, little-endian
right_samples: .zero 65536*8
lpc_coeff: .zero 32*8
crc8_table: .zero 256
crc16_table: .zero 256*2
wav_table_bits: .zero 64*8   # at most 4096 ds64 entries, consumed once
fo_audio_checkpoint: .zero 2*8
fo_scan_checkpoint: .zero 2*8

.text
.include "aiff.inc"
.include "caf.inc"
.include "au.inc"
# RCX=native path -> EAX=1. Publishes output_rate/output_frames, the rate and
# length of the PCM that decoder_read returns; for a chained Ogg stream these
# differ from the current link's sample_rate/total_frames.
FN decoder_open
    sub rsp, 40
    mov dword ptr [rip + output_rate], 0
    mov qword ptr [rip + output_frames], 0
    mov [rsp + 32], rcx
    call tags_clear
    mov dword ptr [rip + track_choice_used], 0
    mov rcx, [rsp + 32]                 # the path
    call decoder_open_format
    test eax, eax
    jz .Lopen_published
    cmp dword ptr [rip + track_choice], 1
    jbe .Lopen_track_ok
    cmp dword ptr [rip + track_choice_used], 0
    jne .Lopen_track_ok
    call decoder_close                  # one track: no Nth
    mov dword ptr [rip + decode_error], 101
    xor eax, eax
    jmp .Lopen_published
.Lopen_track_ok:
    mov rcx, [rip + map_base]           # metadata, from the whole file
    mov rdx, rcx
    add rdx, [rip + file_size]
    call tags_read
    mov eax, 1
    cmp dword ptr [rip + chain_active], 0
    jne .Lopen_published
    mov ecx, [rip + sample_rate]
    mov [rip + output_rate], ecx
    mov rcx, [rip + total_frames]
    mov [rip + output_frames], rcx
.Lopen_published:
    add rsp, 40
    ret
ENDFN decoder_open

LOCALFN decoder_open_format
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov dword ptr [rip + decode_error], 0
    mov dword ptr [rip + codec_kind], 0
    mov qword ptr [rip + total_frames], 0
    mov dword ptr [rip + frame_samples], 0
    mov dword ptr [rip + frame_used], 0
    mov qword ptr [rip + wav_begin], 0
    mov dword ptr [rip + wav_kind], 0
    mov dword ptr [rip + wav_layout], 0
    mov dword ptr [rip + wav_codec_kind], 1
    mov qword ptr [rip + wav_ds64], 0
    mov qword ptr [rip + wav_size_table], 0
    mov dword ptr [rip + wav_table_count], 0
    mov dword ptr [rip + wav_table_used], 0
    mov dword ptr [rip + wav_data_seen], 0
    mov dword ptr [rip + wav_fact_seen], 0
    mov qword ptr [rip + wav_fact_frames], 0
    mov qword ptr [rip + flac_begin], 0
    mov qword ptr [rip + flac_seek_table], 0
    mov dword ptr [rip + flac_seek_count], 0
    mov qword ptr [rip + flac_next_sample], 0
    mov dword ptr [rip + flac_seek_probe], 0
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + flac_comments_seen], 0
    mov dword ptr [rip + pcm_mix], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + wav_valid_bits], 0
    mov dword ptr [rip + pcm_big_endian], 0
    mov dword ptr [rip + pcm_signed8], 0
    mov dword ptr [rip + pcm_g711], 0
    mov dword ptr [rip + wav_codec], 0
    mov dword ptr [rip + flac_packet_mode], 0
    call file_map               # read-only view; empty or unreadable files fail
    mov [rip + map_token], r8
    mov [rip + file_size], rdx
    mov [rip + map_base], rax
    test rax, rax
    jz .Lopen_bad
    cmp qword ptr [rip + file_size], 12
    jb .Lopen_bad
    mov rdx, rax
    add rdx, [rip + file_size]
    jc .Lopen_bad
    mov [rip + input_end], rdx
    mov [rip + input_cursor], rax
    cmp dword ptr [rax], 0x46464952 # RIFF
    je .Lopen_wav
    cmp dword ptr [rax], 0x58464952 # RIFX: big-endian sizes, fields and samples
    je .Lopen_rifx
    cmp dword ptr [rax], 0x66666972 # Wave64 "riff" GUID
    je .Lopen_w64
    cmp dword ptr [rax], 0x34364652 # RF64
    je .Lopen_rf64
    cmp dword ptr [rax], 0x34365742 # BW64
    je .Lopen_bw64
    cmp dword ptr [rax], 0x4d524f46 # FORM AIFF/AIFC
    je .Lopen_aiff
    cmp dword ptr [rax], 0x66666163 # caff: Core Audio Format
    je .Lopen_caf
    cmp dword ptr [rax], 0x646e732e # .snd: Sun/NeXT AU
    je .Lopen_au
    cmp dword ptr [rax], 0x43614c66 # fLaC
    je .Lopen_flac
    cmp dword ptr [rax], 0x5367674f # OggS
    je .Lopen_ogg
    cmp dword ptr [rax], 0xa3df451a # EBML: Matroska/WebM
    je .Lopen_matroska
    cmp dword ptr [rax], 0x01564c46 # FLV version 1
    je .Lopen_flv
    mov ecx, [rax + 4]              # ISO base media / QuickTime top-level box
    cmp ecx, 0x70797466             # ftyp
    je .Lopen_mp4
    cmp ecx, 0x766f6f6d             # moov
    je .Lopen_mp4
    cmp ecx, 0x7461646d             # mdat
    je .Lopen_mp4
    cmp ecx, 0x65646977             # wide
    je .Lopen_mp4
    cmp ecx, 0x65657266             # free
    je .Lopen_mp4
    cmp ecx, 0x70696b73             # skip
    je .Lopen_mp4
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call ape_probe                  # Monkey's Audio ("MAC ")
    test eax, eax
    jnz .Lopen_ape
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call wv_probe                   # WavPack blocks ("wvpk")
    test eax, eax
    jnz .Lopen_wavpack
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mps_probe                  # MPEG program stream (.mpg, .vob)
    test eax, eax
    jnz .Lopen_mps
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mts_probe                  # MPEG transport stream (.ts, .m2ts)
    test eax, eax
    jnz .Lopen_mts
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call loas_probe                 # AAC in LOAS/LATM (sync 0x2B7)
    test eax, eax
    jnz .Lopen_loas
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call adts_probe                 # ADTS AAC; MPEG audio never uses layer 0
    test eax, eax
    jnz .Lopen_adts
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call ac3_probe                  # AC-3 sync frames (0x0B77)
    test eax, eax
    jnz .Lopen_ac3
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call gsm_probe                  # raw GSM 06.10 frames (each a 0xD nibble)
    test eax, eax
    jnz .Lopen_gsm
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mp3_open
    test eax, eax
    jz .Lopen_bad
    mov dword ptr [rip + codec_kind], 3
    leave
    ret
.Lopen_adts:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call adts_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_loas:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call loas_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_ac3:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call ac3_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_gsm:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call gsm_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_wavpack:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call wv_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_ape:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call ape_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_mts:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mts_open
    cmp eax, 1
    jb .Lopen_bad
    ja .Lopen_lpcm_image
    leave
    ret
.Lopen_mps:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mps_open
    cmp eax, 1
    jb .Lopen_bad
    ja .Lopen_lpcm_image
    leave
    ret
.Lopen_lpcm_image:
    # DVD and Blu-ray LPCM, converted into a Wave64 image.
    mov dword ptr [rip + wav_codec_kind], 18
    mov [rip + input_end], rdx
    mov rax, rcx
    jmp .Lopen_w64
.Lopen_caf:
    mov rcx, [rip + map_base]
    mov rdx, [rip + input_end]
    call caf_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_au:
    mov rcx, [rip + map_base]
    mov rdx, [rip + input_end]
    call au_open
    test eax, eax
    jz .Lopen_bad
    cmp eax, 2
    je .Lwav_compressed                 # G.726, G.722
    leave
    ret
.Lopen_aiff:
    mov rcx, [rip + map_base]
    mov rdx, [rip + input_end]
    call aiff_open
    test eax, eax
    jz .Lopen_bad
    mov dword ptr [rip + codec_kind], 6
    leave
    ret
.Lopen_mp4:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mp4_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_matroska:
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call mkv_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_ogg:
    # Chained links and multiplexed streams; each link's codec validates it.
    mov rcx, [rip + input_cursor]
    mov rdx, [rip + input_end]
    call chain_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret
.Lopen_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lopen_failed                   # keep the format's own reason
    mov dword ptr [rip + decode_error], 1
.Lopen_failed:
    xor eax, eax
    leave
    ret
.Lopen_rifx:
    mov dword ptr [rip + wav_layout], 1
    mov dword ptr [rip + pcm_big_endian], 1
    jmp .Lopen_wav
.Lopen_w64:
    # Sony Wave64: "riff" and "wave" GUIDs, 64-bit sizes counting the
    # 24-byte chunk headers, chunks aligned to 8 bytes.
    mov r8, [rip + input_end]
    sub r8, rax                         # the file, or AVI's gathered image
    cmp r8, 40
    jb .Lopen_bad
    cmp dword ptr [rax + 4], 0x11cf912e
    jne .Lopen_bad
    mov rcx, 0x0000c104db28d6a5
    cmp [rax + 8], rcx
    jne .Lopen_bad
    cmp dword ptr [rax + 24], 0x65766177 # wave
    jne .Lopen_bad
    cmp dword ptr [rax + 28], 0x11d3acf3
    jne .Lopen_bad
    mov rcx, 0x8adb8e4fc000d18c
    cmp [rax + 32], rcx
    jne .Lopen_bad
    mov rdx, [rax + 16]
    cmp rdx, 40
    jb .Lopen_bad
    cmp rdx, r8
    ja .Lopen_bad
    add rdx, rax
    mov [rip + input_end], rdx
    mov dword ptr [rip + wav_layout], 2
    lea r10, [rax + 40]
    xor r11d, r11d
    jmp .Lwav_chunks
.Lopen_rf64:
    mov dword ptr [rip + wav_kind], 1
    jmp .Lopen_wav
.Lopen_bw64:
    mov dword ptr [rip + wav_kind], 2
.Lopen_wav:
    cmp dword ptr [rax + 8], 0x45564157
    je .Lopen_wave
    cmp dword ptr [rax + 8], 0x20495641 # "AVI "
    jne .Lopen_bad
    mov ecx, [rip + wav_kind]
    or ecx, [rip + wav_layout]
    jnz .Lopen_bad                      # RIFF only
    # The audio stream's chunks, gathered behind a Wave64 header (AAC opens
    # its own track).
    mov rcx, rax
    mov rdx, [rip + input_end]
    call avi_open
    cmp eax, 1
    jb .Lopen_bad
    ja .Lopen_avi_image
    leave
    ret
.Lopen_avi_image:
    mov dword ptr [rip + wav_codec_kind], 14
    mov [rip + input_end], rdx
    mov rax, rcx
    jmp .Lopen_w64
.Lopen_flv:
    # As AVI: gathered PCM, G.711 and MP3 open as a Wave64 image.
    mov rcx, rax
    mov rdx, [rip + input_end]
    call flv_open
    cmp eax, 1
    jb .Lopen_bad
    ja .Lopen_flv_image
    leave
    ret
.Lopen_flv_image:
    mov dword ptr [rip + wav_codec_kind], 15
    mov [rip + input_end], rdx
    mov rax, rcx
    jmp .Lopen_w64
.Lopen_wave:
    cmp dword ptr [rip + wav_kind], 0
    je .Lwav_riff_size
    # RF64/BW64 require ds64 immediately after the twelve-byte header.
    # Bound its fixed prefix before reading any 64-bit fields or table count.
    lea r8, [rax + 48]
    cmp r8, [rip + input_end]
    ja .Lopen_bad
    cmp dword ptr [rax + 12], 0x34367364
    jne .Lopen_bad
    mov edx, [rax + 16]
    cmp edx, 28
    jb .Lopen_bad
    cmp edx, 0xffffffff
    je .Lopen_bad
    lea r9, [rax + 20]
    mov [rip + wav_ds64], r9
    mov r8, r9
    add r8, rdx
    jc .Lopen_bad
    cmp r8, [rip + input_end]
    ja .Lopen_bad
    mov ecx, [r9 + 24]
    cmp ecx, 4096
    ja .Lopen_bad
    mov [rip + wav_table_count], ecx
    imul rcx, 12
    add rcx, 28
    cmp rcx, rdx
    ja .Lopen_bad
    lea rcx, [r9 + 28]
    mov [rip + wav_size_table], rcx
    lea rcx, [rip + wav_table_bits]
    xor edx, edx
.Lwav_clear_table:
    mov qword ptr [rcx + rdx*8], 0
    inc edx
    cmp edx, 64
    jb .Lwav_clear_table
    mov edx, [rax + 4]
    cmp edx, 0xffffffff
    jne .Lwav_container_size
    mov rdx, [r9]
    jmp .Lwav_container_size
.Lwav_riff_size:
    mov edx, [rax + 4]
    cmp dword ptr [rip + wav_layout], 1
    jne .Lwav_riff_native
    bswap edx
.Lwav_riff_native:
    lea r8, [rax + 12]
.Lwav_container_size:
    cmp rdx, 4
    jb .Lopen_bad
    add rdx, 8
    jc .Lopen_bad
    cmp rdx, [rip + file_size]
    ja .Lopen_bad
    add rdx, rax
    jc .Lopen_bad
    mov [rip + input_end], rdx
    # Chunk payload padding is relative to the even file base.
    mov r10, r8
    add r10, 1
    jc .Lopen_bad
    and r10, -2
    cmp r10, rdx
    ja .Lopen_bad
    xor r11d, r11d              # fmt found
.Lwav_chunks:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lwav_chunk_continue
    cmp dword ptr [rax], 0
    jne .Lopen_bad
.Lwav_chunk_continue:
    cmp r10, [rip + input_end]
    je .Lwav_complete
    cmp dword ptr [rip + wav_layout], 2
    je .Lw64_chunk
    lea rax, [r10 + 8]
    cmp rax, r10
    jb .Lopen_bad
    cmp rax, [rip + input_end]
    ja .Lopen_bad
    mov edx, [r10 + 4]
    cmp dword ptr [rip + wav_layout], 1
    jne .Lwav_size_ordered
    bswap edx
    jmp .Lwav_chunk_size
.Lwav_size_ordered:
    cmp edx, 0xffffffff
    jne .Lwav_chunk_size
    cmp dword ptr [rip + wav_kind], 0
    je .Lopen_bad
    cmp dword ptr [r10], 0x61746164
    jne .Lwav_table_lookup
    mov r9, [rip + wav_ds64]
    mov rdx, [r9 + 8]
    jmp .Lwav_chunk_size
.Lwav_table_lookup:
    # Match the first unused entry for this FourCC. Different chunk IDs may
    # appear in another order; repeated IDs consume their entries in order.
    mov r9, [rip + wav_size_table]
    xor ecx, ecx
.Lwav_table_scan:
    cmp ecx, [rip + wav_table_count]
    jae .Lopen_bad
    mov edx, [r9]
    cmp edx, [r10]
    jne .Lwav_table_skip
    lea rdx, [rip + wav_table_bits]
    bt qword ptr [rdx], rcx
    jc .Lwav_table_skip
    bts qword ptr [rdx], rcx
    inc dword ptr [rip + wav_table_used]
    mov rdx, [r9 + 4]
    jmp .Lwav_chunk_size
.Lwav_table_skip:
    add r9, 12
    inc ecx
    jmp .Lwav_table_scan
.Lwav_chunk_size:
    mov r8, rax
    add r8, rdx
    jc .Lopen_bad
    cmp r8, [rip + input_end]
    ja .Lopen_bad
    cmp dword ptr [r10], 0x20746d66
    je .Lwav_fmt
    cmp dword ptr [r10], 0x61746164
    je .Lwav_data
    cmp dword ptr [r10], 0x74636166
    je .Lwav_fact
    cmp dword ptr [r10], 0x34367364
    je .Lopen_bad
.Lwav_next:
    cmp dword ptr [rip + wav_layout], 2
    je .Lw64_next
    add r8, 1
    jc .Lopen_bad
    and r8, -2
    cmp r8, [rip + input_end]
    ja .Lopen_bad
    mov r10, r8
    jmp .Lwav_chunks
.Lw64_next:
    # Pad to 8 bytes; the last chunk may end the file unpadded.
    mov r10, [rip + input_end]
    cmp r8, r10
    je .Lwav_chunks
    add r8, 7
    jc .Lopen_bad
    and r8, -8
    cmp r8, r10
    cmova r8, r10
    mov r10, r8
    jmp .Lwav_chunks
.Lw64_chunk:
    # Standard chunk GUIDs are the FourCC and a fixed tail; others skip.
    lea rax, [r10 + 24]
    cmp rax, r10
    jb .Lopen_bad
    cmp rax, [rip + input_end]
    ja .Lopen_bad
    mov rdx, [r10 + 16]
    sub rdx, 24
    jb .Lopen_bad
    mov r8, rax
    add r8, rdx
    jc .Lopen_bad
    cmp r8, [rip + input_end]
    ja .Lopen_bad
    cmp dword ptr [r10 + 4], 0x11d3acf3
    jne .Lwav_next
    mov rcx, 0x8adb8e4fc000d18c
    cmp [r10 + 8], rcx
    jne .Lwav_next
    jmp .Lwav_chunk_size
.Lwav_fmt:
    test r11d, r11d
    jnz .Lopen_bad
    cmp rdx, 16
    jb .Lopen_bad
    cmp dword ptr [rip + wav_layout], 1
    jne .Lwav_fmt_ordered
    # RIFX: a little-endian copy of the fields LAMP reads (40 bytes).
    mov [rsp + 32], rbx                   # nonvolatile in this function's callers
    mov [rsp + 40], rdi
    lea rcx, [rip + wav_fmt_copy]
    xor r9d, r9d
.Lwav_fmt_clear:
    mov qword ptr [rcx + r9], 0
    add r9d, 8
    cmp r9d, 48
    jb .Lwav_fmt_clear
    lea r9, [rip + wav_fmt_fields]
.Lwav_fmt_field:
    movzx r8d, byte ptr [r9]              # offset, width
    test r8d, 0x80
    jnz .Lwav_fmt_copied
    movzx ebx, byte ptr [r9 + 1]
    add r9, 2
    lea rdi, [r8 + rbx]
    cmp rdi, rdx
    ja .Lwav_fmt_copied
    cmp ebx, 2
    je .Lwav_fmt_word
    cmp ebx, 4
    je .Lwav_fmt_dword
    mov rdi, [rax + r8]                   # GUID tail: bytes as stored
    mov [rcx + r8], rdi
    jmp .Lwav_fmt_field
.Lwav_fmt_word:
    mov di, [rax + r8]
    rol di, 8
    mov [rcx + r8], di
    jmp .Lwav_fmt_field
.Lwav_fmt_dword:
    mov edi, [rax + r8]
    bswap edi
    mov [rcx + r8], edi
    jmp .Lwav_fmt_field
.Lwav_fmt_copied:
    mov rbx, [rsp + 32]
    mov rdi, [rsp + 40]
    lea r8, [rax + rdx]                   # the chunk's end, for the next chunk
    mov rax, rcx
.Lwav_fmt_ordered:
    cmp rdx, 16
    je .Lwav_fmt_size_valid
    cmp rdx, 18
    jb .Lopen_bad
    movzx ecx, word ptr [rax + 16]
    add ecx, 18
    cmp rcx, rdx
    ja .Lopen_bad
.Lwav_fmt_size_valid:
    movzx ecx, word ptr [rax]
    cmp ecx, 0xfffe
    jne .Lwav_basic_fmt
    cmp rdx, 40
    jb .Lopen_bad
    cmp word ptr [rax + 16], 22
    jb .Lopen_bad
    # Only PCM / float SubFormat GUIDs, canonical remaining 14 bytes.
    cmp word ptr [rax + 26], 0
    jne .Lopen_bad
    cmp dword ptr [rax + 28], 0x0100000
    jne .Lopen_bad
    mov r9, 0x719b3800aa000080
    cmp qword ptr [rax + 32], r9
    jne .Lopen_bad
    movzx ecx, word ptr [rax + 24]
    movzx r9d, word ptr [rax + 18]
    mov [rip + wav_valid_bits], r9d
    mov r9d, [rax + 20]
    mov [rip + pcm_channel_mask], r9d
    mov dword ptr [rip + pcm_mask_seen], 1
    mov dword ptr [rip + pcm_ignore_extra], 1
    test r9d, r9d
    jnz .Lwav_basic_fmt
    # Direct-out has no speaker positions: present the first two ports as
    # stereo (duplicate a single port), without interpreting extra tracks.
    mov dword ptr [rip + pcm_channel_mask], 3
    cmp word ptr [rax + 2], 1
    jne .Lwav_basic_fmt
    mov dword ptr [rip + pcm_channel_mask], 4
.Lwav_basic_fmt:
    cmp ecx, 1
    je .Lwav_valid_type
    cmp ecx, 3
    je .Lwav_valid_type
    # G.711 reads as 8-bit PCM through its expansion tables.
    cmp ecx, 6
    je .Lwav_alaw
    cmp ecx, 7
    je .Lwav_ulaw
    # Compressed audio (a basic tag or an extensible subformat): IMA and
    # Microsoft ADPCM, G.726 and G.722 (track packets), MPEG audio and AC-3
    # (the data chunk opens as the raw stream).
    cmp ecx, 2
    je .Lwav_codec
    cmp ecx, 0x11
    je .Lwav_codec
    cmp ecx, 0x45                           # G.726, and its other tags
    je .Lwav_codec
    cmp ecx, 0x14
    je .Lwav_codec
    cmp ecx, 0x40
    je .Lwav_codec
    cmp ecx, 0x64
    je .Lwav_codec
    cmp ecx, 0x28f                          # G.722
    je .Lwav_codec
    cmp ecx, 0x31                           # GSM 06.10 (Microsoft's blocks)
    je .Lwav_codec
    cmp ecx, 0x50
    je .Lwav_codec
    cmp ecx, 0x55
    je .Lwav_codec
    cmp ecx, 0x2000
    jne .Lopen_bad
.Lwav_codec:
    cmp dword ptr [rip + wav_layout], 1    # not in RIFX
    je .Lopen_bad
    cmp word ptr [rax + 2], 0
    je .Lopen_bad
    cmp word ptr [rax + 12], 0
    je .Lopen_bad
    mov [rip + wav_codec], ecx
    mov [rip + wav_codec_fmt], rax
    mov [rip + wav_codec_fmt_bytes], edx
    mov r11d, 1
    jmp .Lwav_next
.Lwav_alaw:
    mov dword ptr [rip + pcm_g711], 1
    jmp .Lwav_g711
.Lwav_ulaw:
    mov dword ptr [rip + pcm_g711], 2
.Lwav_g711:
    cmp word ptr [rax + 14], 8
    jne .Lopen_bad
    mov ecx, 1
.Lwav_valid_type:
    mov [rip + wav_format], ecx
    movzx ecx, word ptr [rax + 2]
    cmp ecx, 1
    jb .Lopen_bad
    cmp ecx, 8
    ja .Lopen_bad
    mov [rip + source_channels], ecx
    mov ecx, [rax + 4]
    cmp ecx, 8000
    jb .Lopen_bad
    cmp ecx, 192000
    ja .Lopen_bad
    mov [rip + sample_rate], ecx
    movzx ecx, word ptr [rax + 14]
    mov [rip + wav_container_bits], ecx
    cmp dword ptr [rip + wav_format], 3
    jne .Lwav_pcm_bits
    cmp ecx, 32
    je .Lwav_bits_ok
    cmp ecx, 64
    jne .Lopen_bad
    jmp .Lwav_bits_ok
.Lwav_pcm_bits:
    cmp ecx, 8
    je .Lwav_bits_ok
    cmp ecx, 16
    je .Lwav_bits_ok
    cmp ecx, 24
    je .Lwav_bits_ok
    cmp ecx, 32
    jne .Lopen_bad
.Lwav_bits_ok:
    shr ecx, 3
    imul ecx, [rip + source_channels]
    cmp cx, [rax + 12]
    jne .Lopen_bad
    mov [rip + wav_align], ecx
    imul ecx, [rip + sample_rate]
    cmp ecx, [rax + 8]
    jne .Lopen_bad
    mov ecx, [rip + wav_valid_bits]
    test ecx, ecx
    jnz .Lwav_precision_set
    mov ecx, [rip + wav_container_bits]
.Lwav_precision_set:
    cmp ecx, [rip + wav_container_bits]
    ja .Lopen_bad
    cmp dword ptr [rip + wav_format], 3
    jne .Lwav_precision_valid
    cmp ecx, [rip + wav_container_bits]
    jne .Lopen_bad
.Lwav_precision_valid:
    mov [rip + source_bits], ecx
    mov r11d, 1
    jmp .Lwav_next
.Lwav_data:
    test r11d, r11d
    jz .Lopen_bad
    cmp dword ptr [rip + wav_data_seen], 0
    jne .Lopen_bad
    mov dword ptr [rip + wav_data_seen], 1
    mov [rip + input_cursor], rax
    mov [rip + wav_begin], rax
    mov [rip + wav_end], r8
    cmp dword ptr [rip + wav_codec], 0
    jne .Lwav_next
    mov rax, rdx
    xor edx, edx
    mov ecx, [rip + wav_align]
    div rcx
    test edx, edx
    jnz .Lopen_bad
    mov [rip + total_frames], rax
    jmp .Lwav_next
.Lwav_fact:
    cmp dword ptr [rip + wav_fact_seen], 0
    jne .Lopen_bad
    cmp rdx, 4
    jb .Lopen_bad
    mov dword ptr [rip + wav_fact_seen], 1
    mov ecx, [rax]
    cmp dword ptr [rip + wav_layout], 1
    jne .Lwav_fact_w64
    bswap ecx
    jmp .Lwav_fact_count
.Lwav_fact_w64:
    cmp dword ptr [rip + wav_layout], 2
    jne .Lwav_fact_sentinel
    cmp rdx, 8                          # Wave64 counts may be 64-bit
    jb .Lwav_fact_count
    mov rcx, [rax]
    jmp .Lwav_fact_count
.Lwav_fact_sentinel:
    cmp ecx, 0xffffffff
    jne .Lwav_fact_count
    cmp dword ptr [rip + wav_kind], 1
    jne .Lopen_bad
    mov r9, [rip + wav_ds64]
    mov rcx, [r9 + 16]
.Lwav_fact_count:
    mov [rip + wav_fact_frames], rcx
    jmp .Lwav_next
.Lwav_complete:
    cmp dword ptr [rip + wav_data_seen], 0
    je .Lopen_bad
    mov eax, [rip + wav_table_used]
    cmp eax, [rip + wav_table_count]
    jne .Lopen_bad
    cmp dword ptr [rip + wav_codec], 0
    jne .Lwav_compressed
    mov rax, [rip + wav_fact_frames]
    test rax, rax               # zero means unspecified for PCM/float
    jz .Lwav_frame_count_valid
    cmp rax, [rip + total_frames]
    je .Lwav_frame_count_valid
    # Wave64 writers may count the chunk's padding as data: a smaller fact
    # count trims it. RIFF counts must agree.
    cmp dword ptr [rip + wav_layout], 2
    jne .Lopen_bad
    cmp rax, [rip + total_frames]
    ja .Lopen_bad
    mov [rip + total_frames], rax
    mov ecx, [rip + wav_align]
    imul rcx, rax
    add rcx, [rip + wav_begin]
    mov [rip + wav_end], rcx
.Lwav_frame_count_valid:
    call pcm_build_mix
    test eax, eax
    jz .Lopen_bad
    mov eax, 128
    sub eax, [rip + wav_container_bits]
    cmp dword ptr [rip + pcm_g711], 0
    je .Lwav_scale
    mov eax, 128 - 16                   # G.711 expands to 16 bits
.Lwav_scale:
    shl eax, 23
    mov [rip + float_scale], eax
    mov eax, [rip + wav_codec_kind]
    mov [rip + codec_kind], eax
    mov eax, 1
    leave
    ret
.Lwav_compressed:
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov eax, [rip + wav_codec]
    cmp eax, 0x2000
    je .Lwav_ac3
    cmp eax, 0x50
    je .Lwav_mpeg
    cmp eax, 0x55
    je .Lwav_mpeg
    # ADPCM blocks (or G.726/G.722 runs of whole codes) become track
    # packets; a final block too short for its headers is dropped, and a
    # fact count trims the padding of the last.
    mov ecx, TK_ADPCM
    call track_begin
    test eax, eax
    jz .Lopen_bad
.Lwav_adpcm_packets:
    mov rcx, [rip + wav_codec_fmt]
    call adpcm_packet_layout
    mov [rbp - 8], rdx                  # block header bytes
    mov [rbp - 24], rax                 # packet bytes
    mov rax, [rip + wav_begin]
    mov [rbp - 16], rax
.Lwav_adpcm_block:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lwav_adpcm_continue
    cmp dword ptr [rax], 0
    jne .Lwav_adpcm_bad
.Lwav_adpcm_continue:
    mov rcx, [rbp - 16]
    mov rdx, [rip + wav_end]
    sub rdx, rcx
    jbe .Lwav_adpcm_done
    mov rax, [rbp - 24]
    cmp rdx, rax
    cmova rdx, rax
    cmp rdx, [rbp - 8]
    jb .Lwav_adpcm_done
    add [rbp - 16], rdx
    call track_add
    test eax, eax
    jz .Lwav_adpcm_bad
    jmp .Lwav_adpcm_block
.Lwav_adpcm_done:
    mov rax, [rip + wav_codec_fmt]
    mov [rip + track_config], rax
    mov eax, [rip + wav_codec_fmt_bytes]
    mov [rip + track_config_bytes], eax
    mov rax, [rip + wav_fact_frames]
    test rax, rax
    jz .Lwav_adpcm_finish
    mov [rip + track_end_units], rax    # in samples: units at the stream rate
    mov r9, [rip + wav_codec_fmt]
    mov eax, [r9 + 4]
    mov [rip + track_unit_scale], eax
.Lwav_adpcm_finish:
    call track_finish
    test eax, eax
    jz .Lwav_adpcm_bad
    mov eax, [rip + wav_codec_kind]
    mov [rip + codec_kind], eax
    mov eax, 1
    leave
    ret
.Lwav_adpcm_bad:
    call track_close
    jmp .Lopen_bad
.Lwav_mpeg:
    mov rcx, [rip + wav_begin]
    mov rdx, [rip + wav_end]
    call mp3_open
    test eax, eax
    jz .Lopen_bad
    mov dword ptr [rip + codec_kind], 3
    leave
    ret
.Lwav_ac3:
    mov rcx, [rip + wav_begin]
    mov rdx, [rip + wav_end]
    call ac3_open
    test eax, eax
    jz .Lopen_bad
    leave
    ret

.Lopen_flac:
    add rax, 4
    mov r10, rax
    xor r11d, r11d
.Lflac_metadata:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lflac_metadata_continue
    cmp dword ptr [rax], 0
    jne .Lopen_bad
.Lflac_metadata_continue:
    lea rax, [r10 + 4]
    cmp rax, [rip + input_end]
    ja .Lopen_bad
    mov edx, [r10]
    bswap edx
    mov r8d, edx
    and edx, 0x0ffffff
    lea r9, [rax + rdx]
    cmp r9, [rip + input_end]
    ja .Lopen_bad
    mov ecx, r8d
    shr ecx, 24
    and ecx, 0x7f
    cmp r11d, 0
    jne .Lflac_have_streaminfo
    test ecx, ecx
    jnz .Lopen_bad
    cmp edx, 34
    jne .Lopen_bad
    mov rcx, rax
    call flac_streaminfo           # preserves R8-R11
    test eax, eax
    jz .Lopen_bad
    mov r11d, 1
    jmp .Lflac_meta_next
.Lflac_have_streaminfo:
    test ecx, ecx
    jz .Lopen_bad
    cmp ecx, 127
    je .Lopen_bad
    cmp ecx, 4
    je .Lflac_comments
    cmp ecx, 3
    jne .Lflac_meta_next
    cmp qword ptr [rip + flac_seek_table], 0
    jne .Lopen_bad
    mov [rip + flac_seek_table], rax
    mov eax, edx
    xor edx, edx
    mov ecx, 18
    div ecx
    test edx, edx
    jnz .Lopen_bad
    mov [rip + flac_seek_count], eax
    jmp .Lflac_meta_next
.Lflac_comments:
    cmp dword ptr [rip + flac_comments_seen], 0
    jne .Lopen_bad
    mov dword ptr [rip + flac_comments_seen], 1
    mov [rsp + 56], r8
    mov [rsp + 64], r9
    mov [rsp + 72], r11
    mov rcx, rax
    mov rdx, r9
    call flac_parse_comments
    mov r8, [rsp + 56]
    mov r9, [rsp + 64]
    mov r11, [rsp + 72]
    test eax, eax
    jz .Lopen_bad
.Lflac_meta_next:
    mov r10, r9
    test r8d, 0x80000000
    jz .Lflac_metadata
    mov [rip + input_cursor], r10
    mov [rip + flac_begin], r10
    mov rax, [rip + input_end]
    mov [rip + flac_bit_end], rax
    # Validate every table point before enabling indexed seeking. Placeholders
    # are sorted last and their offset/sample-count fields are undefined.
    mov r9, [rip + flac_seek_table]
    mov r8d, [rip + flac_seek_count]
    xor r11d, r11d
    xor edx, edx
.Lflac_seek_validate:
    test r8d, r8d
    jz .Lflac_seek_valid
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lflac_seek_validate_continue
    cmp dword ptr [rax], 0
    jne .Lopen_bad
.Lflac_seek_validate_continue:
    mov rax, [r9]
    bswap rax
    test edx, edx
    jz .Lflac_seek_first
    cmp rax, r11
    jb .Lopen_bad
    cmp rax, -1
    je .Lflac_seek_point_next
    cmp rax, r11
    je .Lopen_bad
.Lflac_seek_first:
    cmp rax, -1
    je .Lflac_seek_point_next
    mov rcx, 0xfffffffff
    cmp rax, rcx
    ja .Lopen_bad
    cmp qword ptr [rip + total_frames], 0
    je .Lflac_seek_sample_valid
    cmp rax, [rip + total_frames]
    jae .Lopen_bad
.Lflac_seek_sample_valid:
    mov rcx, [r9 + 8]
    bswap rcx
    mov r11, [rip + input_end]
    sub r11, r10
    cmp rcx, r11
    jae .Lopen_bad
    movzx ecx, word ptr [r9 + 16]
    rol cx, 8
    test ecx, ecx
    jz .Lopen_bad
    cmp ecx, [rip + maximum_block]
    ja .Lopen_bad
.Lflac_seek_point_next:
    mov r11, rax
    mov edx, 1
    add r9, 18
    dec r8d
    jmp .Lflac_seek_validate
.Lflac_seek_valid:
    call flac_prepare
    test eax, eax
    jz .Lopen_bad
    mov dword ptr [rip + codec_kind], 2
    mov eax, 1
    leave
    ret
ENDFN decoder_open_format

# Stereo mix, extra channel buffers and sample scale for an opened FLAC
# stream -> EAX=1. Native FLAC and FLAC-in-Ogg share it.
FN flac_prepare
    sub rsp, 40
    call pcm_build_mix
    test eax, eax
    jz .Lprepare_return
    lea rax, [rip + left_samples]
    mov [rip + flac_channel_ptrs], rax
    lea rax, [rip + right_samples]
    mov [rip + flac_channel_ptrs + 8], rax
    mov eax, [rip + source_channels]
    cmp eax, 2
    jbe .Lflac_buffers_ready
    sub eax, 2
    imul eax, [rip + maximum_block]
    shl eax, 3
    mov ecx, eax
    call mem_alloc
    test rax, rax
    jz .Lprepare_return
    mov [rip + flac_extra], rax
    mov ecx, 2
    mov edx, [rip + maximum_block]
    shl edx, 3
    lea r8, [rip + flac_channel_ptrs]
.Lflac_buffers_loop:
    mov [r8 + rcx*8], rax
    add rax, rdx
    inc ecx
    cmp ecx, [rip + source_channels]
    jb .Lflac_buffers_loop
.Lflac_buffers_ready:
    # Compute exact reciprocal 2^(1-bits), no library calls.
    mov eax, 128
    sub eax, [rip + source_bits]
    shl eax, 23
    mov [rip + float_scale], eax
    mov eax, 1
.Lprepare_return:
    add rsp, 40
    ret
ENDFN flac_prepare

# Next FLAC frame into the channel buffers -> EAX=1, or 0 at the end/error.
LOCALFN flac_next_frame
    cmp dword ptr [rip + flac_packet_mode], 0
    je decode_frame
    sub rsp, 40
    call ogg_next
    test rax, rax
    jz .Lfo_frame_return
    test edx, edx
    jnz .Lfo_frame_audio
    # FFmpeg's Ogg muxer can terminate FLAC with an empty EOS packet.
    # It is a terminator only after every sample, on the final page.
    cmp dword ptr [rip + ogg_eos], 1
    jne .Lfo_frame_bad
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lfo_frame_bad
    mov rax, [rip + flac_next_sample]
    cmp rax, [rip + total_frames]
    jne .Lfo_frame_bad
    xor eax, eax
    jmp .Lfo_frame_return
.Lfo_frame_audio:
    mov [rip + input_cursor], rax
    add rdx, rax
    mov [rip + input_end], rdx
    mov [rip + flac_bit_end], rdx
    # The final audio frame may precede a separate empty EOS packet. Use
    # the validated frame positions, as the open-time scan does, to allow
    # its short block without relaxing intermediate-frame bounds.
    mov rcx, [rip + input_cursor]
    mov edx, [rip + ogg_packet_length]
    call flac_frame_extent
    add rax, rdx
    cmp rax, [rip + total_frames]
    sete al
    movzx eax, al
    mov [rip + flac_packet_final], eax
    call decode_frame
    jmp .Lfo_frame_return
.Lfo_frame_bad:
    mov dword ptr [rip + decode_error], 3
    xor eax, eax
.Lfo_frame_return:
    add rsp, 40
    ret
ENDFN flac_next_frame

FN flac_ogg_close
    sub rsp, 40
    mov dword ptr [rip + flac_packet_mode], 0
    mov dword ptr [rip + flac_ogg_index_count], 0
    mov rcx, [rip + flac_ogg_index]
    test rcx, rcx
    jz .Lfo_close_extra
    call mem_free
    mov qword ptr [rip + flac_ogg_index], 0
.Lfo_close_extra:
    mov rcx, [rip + flac_extra]
    test rcx, rcx
    jz .Lfo_close_done
    call mem_free
    mov qword ptr [rip + flac_extra], 0
.Lfo_close_done:
    add rsp, 40
    ret
ENDFN flac_ogg_close

# RCX=mapped link start, RDX=end -> EAX=1. FLAC-in-Ogg mapping 1.0: a 0x7F
# "FLAC" packet carrying STREAMINFO, one packet per further metadata block,
# then one frame per packet. The whole stream is scanned for frame positions
# and an index of packet checkpoints; frames are decoded and CRC-checked when
# read. Frame headers carry exact sample positions, so page granules are not
# used: remuxers often round them from millisecond timestamps.
FN flac_ogg_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    call flac_ogg_close
    mov qword ptr [rip + flac_seek_table], 0
    mov dword ptr [rip + flac_seek_count], 0
    mov qword ptr [rip + flac_next_sample], 0
    mov dword ptr [rip + flac_seek_probe], 0
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + flac_comments_seen], 0
    mov dword ptr [rip + pcm_mix], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + frame_samples], 0
    mov dword ptr [rip + frame_used], 0
    mov qword ptr [rip + total_frames], 0
    mov rcx, rsi
    mov rdx, rdi
    call ogg_open
    test eax, eax
    jz .Lfo_open_bad
    call ogg_next
    test rax, rax
    jz .Lfo_open_bad
    cmp edx, 51
    jne .Lfo_open_bad
    cmp dword ptr [rax], 0x414c467f      # 7f "FLA"
    jne .Lfo_open_bad
    cmp byte ptr [rax + 4], 0x43         # "C"
    jne .Lfo_open_bad
    cmp byte ptr [rax + 5], 1            # mapping major version
    jne .Lfo_open_bad
    movzx r13d, word ptr [rax + 7]
    rol r13w, 8                          # declared header packets, 0 = unknown
    cmp dword ptr [rax + 9], 0x43614c66  # "fLaC"
    jne .Lfo_open_bad
    movzx r14d, byte ptr [rax + 13]
    mov ecx, r14d
    and ecx, 0x7f
    jnz .Lfo_open_bad                    # STREAMINFO
    mov ecx, [rax + 13]
    bswap ecx
    and ecx, 0xffffff
    cmp ecx, 34
    jne .Lfo_open_bad
    lea rcx, [rax + 17]
    call flac_streaminfo
    test eax, eax
    jz .Lfo_open_bad
    mov rax, [rip + total_frames]
    mov [rip + flac_declared_frames], rax
    mov qword ptr [rip + total_frames], 0
    xor r12d, r12d                       # metadata packets after the first
.Lfo_header:
    test r14d, 0x80
    jnz .Lfo_headers_done
    call ogg_next
    test rax, rax
    jz .Lfo_open_bad
    cmp edx, 4
    jb .Lfo_open_bad
    inc r12d
    cmp r12d, 65535
    ja .Lfo_open_bad
    movzx r14d, byte ptr [rax]
    mov ecx, [rax]
    bswap ecx
    and ecx, 0xffffff
    add ecx, 4
    cmp ecx, edx
    jne .Lfo_open_bad
    mov ecx, r14d
    and ecx, 0x7f
    jz .Lfo_open_bad                     # a second STREAMINFO
    cmp ecx, 127
    je .Lfo_open_bad
    cmp ecx, 4
    jne .Lfo_header
    cmp dword ptr [rip + flac_comments_seen], 0
    jne .Lfo_open_bad
    mov dword ptr [rip + flac_comments_seen], 1
    lea rcx, [rax + 4]
    lea rdx, [rax + rdx]
    call flac_parse_comments
    test eax, eax
    jz .Lfo_open_bad
    jmp .Lfo_header
.Lfo_headers_done:
    test r13d, r13d
    jz .Lfo_header_count_ok
    cmp r13d, r12d
    jne .Lfo_open_bad
.Lfo_header_count_ok:
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lfo_open_bad                    # audio begins on a fresh page
    call flac_prepare
    test eax, eax
    jz .Lfo_open_bad
    lea rcx, [rip + fo_audio_checkpoint]
    call ogg_checkpoint
    mov ecx, 2048*32
    call mem_alloc
    mov [rip + flac_ogg_index], rax      # allocation failure keeps sequential decoding
    mov qword ptr [rip + flac_ogg_index_stride], 1
    xor r12d, r12d                       # sample position of the next frame
    xor r14d, r14d                       # audio packet ordinal
.Lfo_scan:
    lea rcx, [rip + fo_scan_checkpoint]
    call ogg_checkpoint
    call ogg_next
    test rax, rax
    jz .Lfo_scan_end
    test edx, edx
    jnz .Lfo_scan_audio
    cmp dword ptr [rip + ogg_eos], 1
    jne .Lfo_open_bad
    cmp dword ptr [rip + ogg_packet_page_end], 1
    jne .Lfo_open_bad
    cmp r12, [rip + ogg_granule]
    jne .Lfo_open_bad
    jmp .Lfo_scan_end
.Lfo_scan_audio:
    mov rcx, rax
    call flac_frame_extent               # RAX=position, RDX=block size
    test rdx, rdx
    jz .Lfo_open_bad
    cmp rax, r12
    jne .Lfo_open_bad
    mov r15, rdx
    cmp qword ptr [rip + flac_ogg_index], 0
    je .Lfo_scan_advance
    mov rax, [rip + flac_ogg_index_stride]
    dec rax
    test r14, rax
    jnz .Lfo_scan_advance
    cmp dword ptr [rip + flac_ogg_index_count], 2048
    jb .Lfo_scan_store
    mov ebx, 1                           # keep every other point
.Lfo_scan_compact:
    mov r8, rbx
    shl r8, 6
    add r8, [rip + flac_ogg_index]
    mov r9, rbx
    shl r9, 5
    add r9, [rip + flac_ogg_index]
    movups xmm0, [r8]
    movups xmm1, [r8 + 16]
    movups [r9], xmm0
    movups [r9 + 16], xmm1
    inc ebx
    cmp ebx, 1024
    jb .Lfo_scan_compact
    mov dword ptr [rip + flac_ogg_index_count], 1024
    shl qword ptr [rip + flac_ogg_index_stride], 1
    mov rax, [rip + flac_ogg_index_stride]
    dec rax
    test r14, rax
    jnz .Lfo_scan_advance
.Lfo_scan_store:
    mov eax, [rip + flac_ogg_index_count]
    shl rax, 5
    add rax, [rip + flac_ogg_index]
    movups xmm0, [rip + fo_scan_checkpoint]
    movups [rax], xmm0
    mov [rax + 16], r12
    inc dword ptr [rip + flac_ogg_index_count]
.Lfo_scan_advance:
    add r12, r15
    inc r14
    jmp .Lfo_scan
.Lfo_scan_end:
    cmp dword ptr [rip + decode_error], 0
    jne .Lfo_open_bad
    test r14, r14
    jz .Lfo_open_bad
    mov rax, [rip + flac_declared_frames]
    test rax, rax
    jz .Lfo_scan_total
    cmp rax, r12
    jne .Lfo_open_bad
.Lfo_scan_total:
    mov [rip + total_frames], r12
    lea rcx, [rip + fo_audio_checkpoint]
    call ogg_resume
    test eax, eax
    jz .Lfo_open_bad
    mov dword ptr [rip + flac_packet_mode], 1
    mov qword ptr [rip + flac_next_sample], 0
    mov dword ptr [rip + codec_kind], 7
    mov eax, 1
    jmp .Lfo_open_return
.Lfo_open_bad:
    call flac_ogg_close
    mov qword ptr [rip + total_frames], 0
    cmp dword ptr [rip + decode_error], 0
    jne .Lfo_open_failed
    mov dword ptr [rip + decode_error], 50
.Lfo_open_failed:
    xor eax, eax
.Lfo_open_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_ogg_open

# RCX=FLAC frame packet, EDX=length -> RAX=first sample, RDX=block size, or
# RDX=0 when the header is malformed. Only the fields that place the frame;
# decode_frame checks the rest, including both CRCs.
LOCALFN flac_frame_extent
    cmp edx, 6
    jb .Lextent_bad
    cmp byte ptr [rcx], 0xff
    jne .Lextent_bad
    movzx eax, byte ptr [rcx + 1]
    and eax, 0xfe
    cmp eax, 0xf8
    jne .Lextent_bad
    mov r10d, edx                        # length
    movzx r11d, byte ptr [rcx + 1]
    and r11d, 1                          # variable blocking
    movzx eax, byte ptr [rcx + 4]        # UTF-8 style coded number
    mov r8d, 1
    cmp eax, 0x80
    jb .Lextent_number
    cmp eax, 0xc0
    jb .Lextent_bad
    mov r8d, 2
    and eax, 0x1f
    cmp byte ptr [rcx + 4], 0xe0
    jb .Lextent_number
    mov r8d, 3
    movzx eax, byte ptr [rcx + 4]
    and eax, 0x0f
    cmp byte ptr [rcx + 4], 0xf0
    jb .Lextent_number
    mov r8d, 4
    movzx eax, byte ptr [rcx + 4]
    and eax, 0x07
    cmp byte ptr [rcx + 4], 0xf8
    jb .Lextent_number
    mov r8d, 5
    movzx eax, byte ptr [rcx + 4]
    and eax, 0x03
    cmp byte ptr [rcx + 4], 0xfc
    jb .Lextent_number
    mov r8d, 6
    movzx eax, byte ptr [rcx + 4]
    and eax, 0x01
    cmp byte ptr [rcx + 4], 0xfe
    jb .Lextent_number
    cmp byte ptr [rcx + 4], 0xff
    je .Lextent_bad
    mov r8d, 7
    xor eax, eax
.Lextent_number:
    lea r9d, [r8 + 6]
    cmp r9d, r10d
    ja .Lextent_bad
    mov r9d, 1
.Lextent_continuation:
    cmp r9d, r8d
    jae .Lextent_number_done
    movzx edx, byte ptr [rcx + r9 + 4]
    mov r10b, dl
    and r10b, 0xc0
    cmp r10b, 0x80
    jne .Lextent_bad
    shl rax, 6
    and edx, 0x3f
    or rax, rdx
    inc r9d
    jmp .Lextent_continuation
.Lextent_number_done:
    lea r9d, [r8 + 4]                    # offset after the number
    movzx r10d, byte ptr [rcx + 2]
    shr r10d, 4
    jz .Lextent_bad
    cmp r10d, 1
    je .Lextent_192
    cmp r10d, 6
    jb .Lextent_576
    je .Lextent_8bit
    cmp r10d, 7
    je .Lextent_16bit
    lea ecx, [r10 - 8]
    mov edx, 256
    shl edx, cl
    jmp .Lextent_place
.Lextent_192:
    mov edx, 192
    jmp .Lextent_place
.Lextent_576:
    lea ecx, [r10 - 2]
    mov edx, 576
    shl edx, cl
    jmp .Lextent_place
.Lextent_8bit:
    movzx edx, byte ptr [rcx + r9]
    inc edx
    jmp .Lextent_place
.Lextent_16bit:
    movzx edx, word ptr [rcx + r9]
    rol dx, 8
    inc edx
.Lextent_place:
    test r11d, r11d
    jnz .Lextent_return                  # variable blocking codes the sample
    mov ecx, [rip + maximum_block]
    imul rax, rcx
    ret
.Lextent_bad:
    xor edx, edx
.Lextent_return:
    ret
ENDFN flac_frame_extent

# RCX=frame on a freshly opened FLAC-in-Ogg stream -> RAX=resume frame at a
# frame boundary at or before it. FLAC frames decode independently.
FN flac_ogg_seek
    push rbx
    sub rsp, 32
    xor eax, eax
    cmp dword ptr [rip + flac_packet_mode], 0
    je .Lfo_seek_return
    cmp dword ptr [rip + flac_ogg_index_count], 0
    je .Lfo_seek_return
    test rcx, rcx
    jz .Lfo_seek_return
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lfo_seek_not_cancelled
    cmp dword ptr [rax], 0
    mov eax, 0
    jne .Lfo_seek_return
.Lfo_seek_not_cancelled:
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    xor r8d, r8d
    mov r9d, [rip + flac_ogg_index_count]
.Lfo_seek_search:
    mov edx, r9d
    sub edx, r8d
    cmp edx, 1
    jbe .Lfo_seek_found
    shr edx, 1
    add edx, r8d
    mov eax, edx
    shl rax, 5
    add rax, [rip + flac_ogg_index]
    cmp [rax + 16], rcx
    ja .Lfo_seek_upper
    mov r8d, edx
    jmp .Lfo_seek_search
.Lfo_seek_upper:
    mov r9d, edx
    jmp .Lfo_seek_search
.Lfo_seek_found:
    mov eax, r8d
    shl rax, 5
    add rax, [rip + flac_ogg_index]
    mov rbx, [rax + 16]
    mov rcx, rax
    call ogg_resume
    test eax, eax
    jz .Lfo_seek_bad
    mov [rip + flac_next_sample], rbx
    mov dword ptr [rip + frame_samples], 0
    mov dword ptr [rip + frame_used], 0
    inc dword ptr [rip + decoder_seek_probes]
    mov rax, rbx
    jmp .Lfo_seek_return
.Lfo_seek_bad:
    mov dword ptr [rip + decode_error], 51
    xor eax, eax
.Lfo_seek_return:
    add rsp, 32
    pop rbx
    ret
ENDFN flac_ogg_seek

# RCX=stereo float output, EDX=frame capacity -> EAX=frames.
FN flac_ogg_read
    xor eax, eax
    cmp dword ptr [rip + flac_packet_mode], 0
    je .Lfo_read_return
    cmp dword ptr [rip + decode_error], 0
    jne .Lfo_read_return
    jmp flac_read
.Lfo_read_return:
    ret
ENDFN flac_ogg_read

# Track mode for container PCM: ECX=channels (1-8), EDX=bits (8/16/24/32,
# or 32/64 float), R8D=flags (1 big-endian, 2 float, 4 signed 8-bit,
# 8 A-law, 16 mu-law, both stored in 8-bit containers) -> EAX=1.
FN pcm_track_open
    sub rsp, 40
    xor eax, eax
    cmp ecx, 1
    jb .Lpcm_track_return
    cmp ecx, 8
    ja .Lpcm_track_return
    mov [rip + source_channels], ecx
    mov dword ptr [rip + wav_format], 1
    test r8d, 2
    jz .Lpcm_track_integer
    mov dword ptr [rip + wav_format], 3
    cmp edx, 32
    je .Lpcm_track_bits
    cmp edx, 64
    je .Lpcm_track_bits
    jmp .Lpcm_track_return
.Lpcm_track_integer:
    cmp edx, 8
    je .Lpcm_track_bits
    cmp edx, 16
    je .Lpcm_track_bits
    cmp edx, 24
    je .Lpcm_track_bits
    cmp edx, 32
    jne .Lpcm_track_return
.Lpcm_track_bits:
    mov [rip + wav_container_bits], edx
    mov [rip + source_bits], edx
    mov eax, r8d
    and eax, 1
    mov [rip + pcm_big_endian], eax
    mov eax, r8d
    shr eax, 2
    and eax, 1
    mov [rip + pcm_signed8], eax
    mov dword ptr [rip + pcm_g711], 0
    test r8d, 24
    jz .Lpcm_track_align
    xor eax, eax
    cmp edx, 8
    jne .Lpcm_track_return
    mov eax, r8d
    shr eax, 3
    and eax, 3
    cmp eax, 2
    ja .Lpcm_track_bad_g711
    mov [rip + pcm_g711], eax
    mov dword ptr [rip + source_bits], 16
.Lpcm_track_align:
    mov eax, edx
    shr eax, 3
    imul eax, ecx
    mov [rip + wav_align], eax
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + pcm_mix], 0
    call pcm_build_mix
    test eax, eax
    jz .Lpcm_track_return
    mov eax, 128
    sub eax, [rip + wav_container_bits]
    cmp dword ptr [rip + pcm_g711], 0
    je .Lpcm_track_scale
    mov eax, 128 - 16
.Lpcm_track_scale:
    shl eax, 23
    mov [rip + float_scale], eax
    mov eax, 1
    jmp .Lpcm_track_return
.Lpcm_track_bad_g711:
    xor eax, eax
.Lpcm_track_return:
    add rsp, 40
    ret
ENDFN pcm_track_open

# RCX=packet, EDX=bytes -> EAX=frames, or -1 for a partial frame.
FN pcm_track_samples
    mov eax, edx
    xor edx, edx
    div dword ptr [rip + wav_align]
    test edx, edx
    jz .Lpcm_samples_return
    mov eax, -1
.Lpcm_samples_return:
    ret
ENDFN pcm_track_samples

# RCX=packet, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames.
FN pcm_track_decode
    push rbx
    sub rsp, 32
    mov [rip + input_cursor], rcx
    mov eax, edx
    xor edx, edx
    div dword ptr [rip + wav_align]
    mov ebx, eax
    mov eax, -1
    cmp ebx, r9d
    ja .Lpcm_decode_return
    imul eax, ebx, 1
    imul eax, [rip + wav_align]
    add rax, rcx
    mov [rip + wav_end], rax
    mov rcx, r8
    mov edx, ebx
    call wav_emit
.Lpcm_decode_return:
    add rsp, 32
    pop rbx
    ret
ENDFN pcm_track_decode

# Track mode for FLAC frames in Matroska/MP4: RCX=metadata blocks, optionally
# after "fLaC", EDX=bytes -> EAX=1. STREAMINFO must come first; a
# VORBIS_COMMENT channel mask is honored as in native FLAC.
FN flac_track_open
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    lea rdi, [rcx + rdx]
    call flac_ogg_close
    mov qword ptr [rip + flac_seek_table], 0
    mov dword ptr [rip + flac_seek_count], 0
    mov qword ptr [rip + flac_next_sample], 0
    mov dword ptr [rip + flac_seek_probe], 0
    mov dword ptr [rip + pcm_mask_seen], 0
    mov dword ptr [rip + flac_comments_seen], 0
    mov dword ptr [rip + pcm_mix], 0
    mov dword ptr [rip + pcm_ignore_extra], 0
    mov dword ptr [rip + frame_samples], 0
    mov dword ptr [rip + frame_used], 0
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lflac_track_bad
    cmp dword ptr [rsi], 0x43614c66      # "fLaC"
    jne .Lflac_track_blocks
    add rsi, 4
.Lflac_track_blocks:
    xor ebx, ebx                         # STREAMINFO seen
.Lflac_track_block:
    lea rax, [rsi + 4]
    cmp rax, rdi
    ja .Lflac_track_bad
    mov r12d, [rsi]
    bswap r12d                           # flags/type and 24-bit length
    mov edx, r12d
    and edx, 0xffffff
    lea rcx, [rax + rdx]
    cmp rcx, rdi
    ja .Lflac_track_bad
    mov ecx, r12d
    shr ecx, 24
    and ecx, 0x7f
    test ebx, ebx
    jnz .Lflac_track_later
    test ecx, ecx
    jnz .Lflac_track_bad
    cmp edx, 34
    jne .Lflac_track_bad
    mov rcx, rax
    call flac_streaminfo
    test eax, eax
    jz .Lflac_track_bad
    mov ebx, 1
    jmp .Lflac_track_next
.Lflac_track_later:
    test ecx, ecx
    jz .Lflac_track_bad
    cmp ecx, 127
    je .Lflac_track_bad
    cmp ecx, 4
    jne .Lflac_track_next
    cmp dword ptr [rip + flac_comments_seen], 0
    jne .Lflac_track_bad
    mov dword ptr [rip + flac_comments_seen], 1
    lea rcx, [rsi + 4]
    lea rdx, [rcx + rdx]
    call flac_parse_comments
    test eax, eax
    jz .Lflac_track_bad
.Lflac_track_next:
    mov eax, r12d
    and eax, 0xffffff
    lea rsi, [rsi + rax + 4]
    test r12d, 0x80000000
    jnz .Lflac_track_metadata_done
    cmp rsi, rdi
    jb .Lflac_track_block
.Lflac_track_metadata_done:
    test ebx, ebx
    jz .Lflac_track_bad
    mov rax, [rip + total_frames]
    mov [rip + flac_declared_frames], rax
    mov qword ptr [rip + total_frames], 0
    call flac_prepare
    test eax, eax
    jz .Lflac_track_bad
    mov dword ptr [rip + flac_packet_mode], 1
    mov qword ptr [rip + flac_scan_position], 0
    mov eax, 1
    jmp .Lflac_track_return
.Lflac_track_bad:
    call flac_ogg_close
    xor eax, eax
.Lflac_track_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_track_open

# RCX=frame, EDX=bytes -> EAX=block size, or -1 when the header is malformed
# or the frame does not start where the previous scanned frame ended.
FN flac_track_samples
    sub rsp, 40
    call flac_frame_extent
    test rdx, rdx
    jz .Lflac_track_samples_bad
    cmp rax, [rip + flac_scan_position]
    jne .Lflac_track_samples_bad
    add [rip + flac_scan_position], rdx
    mov eax, edx
    jmp .Lflac_track_samples_return
.Lflac_track_samples_bad:
    mov eax, -1
.Lflac_track_samples_return:
    add rsp, 40
    ret
ENDFN flac_track_samples

# RCX=sample position of the next frame to decode.
FN flac_track_reset
    mov [rip + flac_next_sample], rcx
    mov dword ptr [rip + frame_samples], 0
    mov dword ptr [rip + frame_used], 0
    ret
ENDFN flac_track_reset

# RCX=frame, EDX=bytes, R8=stereo float output, R9D=capacity -> EAX=frames,
# or -1 on error. track_final_packet relaxes the minimum block size.
FN flac_track_decode
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, r8
    mov ebx, r9d
    mov [rip + input_cursor], rcx
    add rdx, rcx
    mov [rip + input_end], rdx
    mov [rip + flac_bit_end], rdx
    mov eax, [rip + track_final_packet]
    mov [rip + flac_packet_final], eax
    cmp rcx, rdx
    jae .Lflac_track_decode_bad
    call decode_frame
    test eax, eax
    jz .Lflac_track_decode_bad
    mov edx, [rip + frame_samples]
    cmp edx, ebx
    ja .Lflac_track_decode_bad
    mov dword ptr [rip + frame_used], 0
    mov rcx, rsi
    call flac_read
    jmp .Lflac_track_decode_return
.Lflac_track_decode_bad:
    cmp dword ptr [rip + decode_error], 0
    jne .Lflac_track_decode_failed
    mov dword ptr [rip + decode_error], 3
.Lflac_track_decode_failed:
    mov eax, -1
.Lflac_track_decode_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN flac_track_decode

# RCX=34-byte STREAMINFO block -> EAX=1 when supported. Sets block limits,
# rate, channels, depth and the declared frame count (0 = unknown).
# Preserves R8-R11 for the metadata walk.
LOCALFN flac_streaminfo
    xor eax, eax
    movzx edx, word ptr [rcx]
    rol dx, 8
    cmp edx, 16
    jb .Lstreaminfo_return
    mov [rip + minimum_block], edx
    movzx edx, word ptr [rcx + 2]
    rol dx, 8
    cmp edx, [rip + minimum_block]
    jb .Lstreaminfo_return
    mov [rip + maximum_block], edx
    mov rdx, [rcx + 10]
    bswap rdx
    mov rcx, rdx
    shr rcx, 44
    mov [rip + sample_rate], ecx
    cmp ecx, 8000
    jb .Lstreaminfo_return
    cmp ecx, 192000
    ja .Lstreaminfo_return
    mov rcx, rdx
    shr rcx, 41
    and ecx, 7
    inc ecx
    mov [rip + source_channels], ecx
    mov rcx, rdx
    shr rcx, 36
    and ecx, 31
    inc ecx
    cmp ecx, 4
    jb .Lstreaminfo_return
    cmp ecx, 32
    ja .Lstreaminfo_return
    mov [rip + source_bits], ecx
    mov rcx, 0xfffffffff
    and rdx, rcx
    mov [rip + total_frames], rdx
    mov eax, 1
.Lstreaminfo_return:
    ret
ENDFN flac_streaminfo

# RCX=comment payload, RDX=bounded end. Little-endian lengths, no framing bit.
# Conflicting repeated masks are rejected; identical repeats are harmless.
LOCALFN flac_parse_comments
    push rbx
    push rsi
    push rdi
    push r12
    mov rsi, rcx
    mov r12, rdx
    lea rax, [rsi + 4]
    cmp rax, r12
    ja .Lcomments_bad
    mov ecx, [rsi]
    lea rsi, [rax + rcx]
    cmp rsi, r12
    ja .Lcomments_bad
    cmp rsi, r12
    je .Lcomments_ok
    lea rax, [rsi + 4]
    cmp rax, r12
    ja .Lcomments_bad
    mov ebx, [rsi]
    mov rsi, rax
.Lcomments_field:
    test ebx, ebx
    jz .Lcomments_end
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lcomments_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lcomments_bad
.Lcomments_not_cancelled:
    lea rax, [rsi + 4]
    cmp rax, r12
    ja .Lcomments_bad
    mov ecx, [rsi]
    lea rdi, [rax + rcx]
    cmp rdi, r12
    ja .Lcomments_bad
    mov rsi, rdi
    cmp ecx, FLAC_MASK_NAME_BYTES
    jb .Lcomments_next
    xor edx, edx
    lea r8, [rip + flac_mask_name]
.Lcomments_key:
    movzx ecx, byte ptr [rax + rdx]
    cmp ecx, 'A'
    jb .Lcomments_key_compare
    cmp ecx, 'Z'
    ja .Lcomments_key_compare
    add ecx, 32
.Lcomments_key_compare:
    cmp cl, [r8 + rdx]
    jne .Lcomments_next
    inc edx
    cmp edx, FLAC_MASK_NAME_BYTES
    jb .Lcomments_key
    add rax, FLAC_MASK_NAME_BYTES
    lea r8, [rax + 3]
    cmp r8, rdi
    ja .Lcomments_bad
    cmp byte ptr [rax], '0'
    jne .Lcomments_bad
    movzx ecx, byte ptr [rax + 1]
    or ecx, 0x20
    cmp ecx, 'x'
    jne .Lcomments_bad
    add rax, 2
    xor r9d, r9d
.Lcomments_hex:
    mov r10, [rip + ogg_cancel_ptr]
    test r10, r10
    jz .Lcomments_hex_continue
    cmp dword ptr [r10], 0
    jne .Lcomments_bad
.Lcomments_hex_continue:
    movzx ecx, byte ptr [rax]
    sub ecx, '0'
    cmp ecx, 9
    jbe .Lcomments_digit
    add ecx, '0'
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 5
    ja .Lcomments_bad
    add ecx, 10
.Lcomments_digit:
    test r9d, 0xf0000000
    jnz .Lcomments_bad
    shl r9d, 4
    or r9d, ecx
    inc rax
    cmp rax, rdi
    jb .Lcomments_hex
    cmp dword ptr [rip + pcm_mask_seen], 0
    je .Lcomments_save_mask
    cmp r9d, [rip + pcm_channel_mask]
    jne .Lcomments_bad
.Lcomments_save_mask:
    mov [rip + pcm_channel_mask], r9d
    mov dword ptr [rip + pcm_mask_seen], 1
.Lcomments_next:
    dec ebx
    jmp .Lcomments_field
.Lcomments_end:
    cmp rsi, r12
    jne .Lcomments_bad
.Lcomments_ok:
    mov eax, 1
    jmp .Lcomments_return
.Lcomments_bad:
    xor eax, eax
.Lcomments_return:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_parse_comments

# Original stereo rendering policy. Canonical layouts match RFC 7845 gains,
# reordered into FLAC/WAVE order. Unassigned channels have zero coefficients.
# Normalize the larger row sum to 1 (<=4 speakers) or 2 (>=5 speakers).
FN pcm_build_mix
    cmp dword ptr [rip + pcm_mask_seen], 0
    jne .Lmix_mask_ready
    mov eax, [rip + source_channels]
    dec eax
    lea rcx, [rip + pcm_default_masks]
    mov eax, [rcx + rax*4]
    mov [rip + pcm_channel_mask], eax
.Lmix_mask_ready:
    mov r11d, [rip + pcm_channel_mask]
    test r11d, 0xfffc0000
    jnz .Lmix_bad
    lea r8, [rip + pcm_mix_coeff]
    xorpd xmm0, xmm0
    xor eax, eax
.Lmix_zero:
    movupd [r8 + rax], xmm0
    add eax, 16
    cmp eax, 128
    jb .Lmix_zero
    xorpd xmm1, xmm1
    xor ecx, ecx
    xor edx, edx
    lea r10, [rip + pcm_speaker_weights]
.Lmix_speaker:
    bt r11d, ecx
    jnc .Lmix_next_speaker
    cmp edx, [rip + source_channels]
    jb .Lmix_assign_speaker
    cmp dword ptr [rip + pcm_ignore_extra], 0
    je .Lmix_bad
    jmp .Lmix_next_speaker
.Lmix_assign_speaker:
    movsd xmm2, qword ptr [r10]
    movsd xmm3, qword ptr [r10 + 8]
    movsd qword ptr [r8], xmm2
    movsd qword ptr [r8 + 8], xmm3
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r8, 16
    inc edx
.Lmix_next_speaker:
    add r10, 16
    inc ecx
    cmp ecx, 18
    jb .Lmix_speaker
    maxsd xmm0, xmm1
    test edx, edx
    jz .Lmix_enable
    movsd xmm2, [rip + pcm_mix_one]
    cmp edx, 4
    jbe .Lmix_normalize
    movsd xmm2, [rip + pcm_mix_two]
.Lmix_normalize:
    divsd xmm2, xmm0
    lea r8, [rip + pcm_mix_coeff]
    mov ecx, [rip + source_channels]
.Lmix_scale:
    movsd xmm0, qword ptr [r8]
    movsd xmm1, qword ptr [r8 + 8]
    mulsd xmm0, xmm2
    mulsd xmm1, xmm2
    movsd qword ptr [r8], xmm0
    movsd qword ptr [r8 + 8], xmm1
    add r8, 16
    dec ecx
    jnz .Lmix_scale
.Lmix_enable:
    mov dword ptr [rip + pcm_mix], 1
    cmp dword ptr [rip + source_channels], 2
    jne .Lmix_check_mono
    cmp r11d, 3
    jne .Lmix_ok
    mov dword ptr [rip + pcm_mix], 0
    jmp .Lmix_ok
.Lmix_check_mono:
    cmp dword ptr [rip + source_channels], 1
    jne .Lmix_ok
    cmp r11d, 4
    jne .Lmix_ok
    mov dword ptr [rip + pcm_mix], 0
.Lmix_ok:
    mov eax, 1
    ret
.Lmix_bad:
    xor eax, eax
    ret
ENDFN pcm_build_mix

FN decoder_close
    push rbp
    mov rbp, rsp
    sub rsp, 32
    call chain_close
    call track_close
    call loas_close                 # after the track reading its packets
    call mp3_close
    call opus_close
    call vorbis_close
    call flac_ogg_close
    call ogg_close
    call mts_close                  # after the decoders reading its buffer
    mov rcx, [rip + flac_extra]
    test rcx, rcx
    jz .Lclose_flac_buffers
    call mem_free
    mov qword ptr [rip + flac_extra], 0
.Lclose_flac_buffers:
    mov rcx, [rip + map_base]
    test rcx, rcx
    jz .Lclosed
    mov rdx, [rip + file_size]
    mov r8, [rip + map_token]
    call file_unmap
    mov qword ptr [rip + map_base], 0
    mov qword ptr [rip + map_token], 0
.Lclosed:
    mov qword ptr [rip + wav_begin], 0
    mov qword ptr [rip + flac_begin], 0
    mov qword ptr [rip + flac_seek_table], 0
    mov dword ptr [rip + flac_seek_count], 0
    leave
    ret
ENDFN decoder_close

# RCX=absolute requested frame. Call once on a newly opened stream.
# RAX=resume frame <= target; caller decodes/discards the remaining distance.
# WAV seeks exactly; native FLAC uses a table or bounded frame binary search.
# MP3 restores an indexed reservoir before two-frame PCM pre-roll.
# Vorbis restores a packet checkpoint and primes its preceding overlap.
# Opus restores a packet checkpoint before at least80ms PCM pre-roll.
FN decoder_seek
    push rbx
    push rsi
    sub rsp, 40
    mov dword ptr [rip + decoder_seek_probes], 0
    xor eax, eax
    cmp qword ptr [rip + map_base], 0
    je .Lseek_return
    cmp dword ptr [rip + decode_error], 0
    jne .Lseek_return
    cmp dword ptr [rip + chain_active], 0
    jne .Lseek_chain
    cmp dword ptr [rip + track_active], 0
    jne .Lseek_track
    cmp dword ptr [rip + codec_kind], 1
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 6
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 13
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 14
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 15
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 16
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 18
    je .Lseek_wav
    cmp dword ptr [rip + codec_kind], 3
    je .Lseek_mp3
    cmp dword ptr [rip + codec_kind], 17
    je .Lseek_ape
    cmp dword ptr [rip + codec_kind], 2
    jne .Lseek_return
    test rcx, rcx
    jz .Lseek_return
    mov rsi, rcx
    mov rbx, [rip + flac_seek_table]
    xor r8d, r8d             #lower bound, exclusive upper bound
    mov r9d, [rip + flac_seek_count]
    test r9d, r9d
    jz .Lseek_flac_without_table
.Lseek_flac_search:
    cmp r8d, r9d
    jae .Lseek_flac_found
    mov edx, r9d
    sub edx, r8d
    shr edx, 1
    add edx, r8d
    imul r10d, edx, 18
    mov rax, [rbx + r10]
    bswap rax
    cmp rax, -1
    je .Lseek_flac_upper
    cmp rax, rsi
    ja .Lseek_flac_upper
    lea r8d, [rdx + 1]
    jmp .Lseek_flac_search
.Lseek_flac_upper:
    mov r9d, edx
    jmp .Lseek_flac_search
.Lseek_flac_found:
    xor eax, eax
    test r8d, r8d
    jz .Lseek_flac_without_table
    dec r8d
    imul r8d, r8d, 18
    add rbx, r8
    mov rsi, [rbx]
    bswap rsi
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lseek_flac_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lseek_cancelled
.Lseek_flac_not_cancelled:
    mov rax, [rbx + 8]
    bswap rax
    add rax, [rip + flac_begin]    #validated relative offset stays in mapped input
    mov [rip + input_cursor], rax
    mov [rip + flac_next_sample], rsi
    inc dword ptr [rip + decoder_seek_probes]
    call decode_frame      #selected frame header and complete PCM CRC checks
    test eax, eax
    jz .Lseek_failed
    movzx eax, word ptr [rbx + 16]
    rol ax, 8
    cmp eax, [rip + frame_samples]
    jne .Lseek_failed
    mov rax, [rip + frame_number]
    cmp dword ptr [rip + frame_blocking], 0
    jne .Lseek_flac_position
    mov ecx, [rip + maximum_block]
    mul rcx
.Lseek_flac_position:
    cmp rax, rsi
    jne .Lseek_failed
    mov rax, rsi
    jmp .Lseek_return
.Lseek_flac_without_table:
    mov rcx, rsi
    call flac_seek_search
    jmp .Lseek_return
.Lseek_mp3:
    call mp3_seek
    jmp .Lseek_return
.Lseek_ape:
    call ape_seek
    jmp .Lseek_return
.Lseek_chain:
    call chain_seek
    jmp .Lseek_return
.Lseek_track:
    call track_seek
    jmp .Lseek_return
.Lseek_wav:
    mov rdx, [rip + ogg_cancel_ptr]
    test rdx, rdx
    jz .Lseek_wav_continue
    cmp dword ptr [rdx], 0
    jne .Lseek_return
.Lseek_wav_continue:
    cmp rcx, [rip + total_frames]
    cmova rcx, [rip + total_frames]
    mov rax, rcx
    mov edx, [rip + wav_align]
    imul rdx, rcx
    add rdx, [rip + wav_begin]
    mov [rip + input_cursor], rdx
    jmp .Lseek_return
.Lseek_failed:
    mov dword ptr [rip + decode_error], 28
    xor eax, eax
    jmp .Lseek_return
.Lseek_cancelled:
    xor eax, eax
.Lseek_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN decoder_seek

# Search independent FLAC frames without allocating an index. Byte bounds
# shrink on every iteration, and decoded sample bounds must agree with them.
# Full header, subframe, sample-range and CRC validation precedes selection;
# a following frame must also validate with consecutive sample numbering.
# Cap speculative work at 64 probes, 64 MiB scanning, 1 MiB per frame. A cap
# falls back to frame zero; cancellation stops speculation before more reads.
LOCALFN flac_seek_search
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov rbx, rcx
    mov r14, [rip + flac_begin]
    xor r15d, r15d
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lseek_search_first
    cmp dword ptr [rax], 0
    jne .Lseek_search_cancel
.Lseek_search_first:
    inc dword ptr [rip + decoder_seek_probes]
    call decode_frame
    test eax, eax
    jz .Lseek_search_bad
    mov rax, [rip + flac_next_sample]
    cmp rbx, rax
    jb .Lseek_search_zero
    mov [rsp + 32], rax          #smallest sample at the lower byte bound
    mov rax, [rip + total_frames]
    test rax, rax
    jnz .Lseek_search_total
    mov rax, -1
.Lseek_search_total:
    mov [rsp + 40], rax          #sample boundary belonging to the upper bound
    mov dword ptr [rsp + 48], 64
    mov dword ptr [rsp + 56], 0x4000000
    mov rsi, [rip + input_cursor]
    mov rdi, [rip + input_end]
    mov dword ptr [rip + flac_seek_probe], 1
.Lseek_search_loop:
    cmp rsi, rdi
    jae .Lseek_search_selected
    mov r12, rdi
    sub r12, rsi
    shr r12, 1
    add r12, rsi
    mov r13, r12
.Lseek_search_scan:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lseek_search_scan_continue
    cmp dword ptr [rax], 0
    jne .Lseek_search_cancel
.Lseek_search_scan_continue:
    cmp r13, rdi
    jae .Lseek_search_upper
    lea rax, [r13 + 2]
    cmp rax, [rip + input_end]
    ja .Lseek_search_upper
    cmp dword ptr [rsp + 56], 0
    je .Lseek_search_fallback
    dec dword ptr [rsp + 56]
    cmp byte ptr [r13], 0xff
    jne .Lseek_search_next
    movzx eax, byte ptr [r13 + 1]
    and eax, 0xfe
    cmp eax, 0xf8
    jne .Lseek_search_next
    cmp dword ptr [rsp + 48], 0
    je .Lseek_search_fallback
    dec dword ptr [rsp + 48]
    mov [rip + input_cursor], r13
    lea rax, [r13 + 0x100000]
    cmp rax, [rip + input_end]
    cmova rax, [rip + input_end]
    mov [rip + flac_bit_end], rax
    mov dword ptr [rip + decode_error], 0
    inc dword ptr [rip + decoder_seek_probes]
    call decode_frame
    test eax, eax
    jz .Lseek_search_next
    mov rax, [rip + flac_next_sample]
    mov ecx, [rip + frame_samples]
    sub rax, rcx
    mov [rsp + 72], rax         #candidate start sample, before neighbor decode
    mov eax, [rip + frame_samples]
    mov [rsp + 80], eax
    mov rax, [rip + input_cursor]
    mov [rsp + 64], rax
    cmp rax, [rip + input_end]
    jae .Lseek_search_candidate
    cmp dword ptr [rsp + 48], 0
    je .Lseek_search_fallback
    dec dword ptr [rsp + 48]
    lea rax, [rax + 0x100000]
    cmp rax, [rip + input_end]
    cmova rax, [rip + input_end]
    mov [rip + flac_bit_end], rax
    mov dword ptr [rip + flac_seek_probe], 0
    inc dword ptr [rip + decoder_seek_probes]
    call decode_frame        #reject CRC-valid sync patterns inside payloads
    mov dword ptr [rip + flac_seek_probe], 1
    test eax, eax
    jz .Lseek_search_next
.Lseek_search_candidate:
    mov eax, [rsp + 80]
    add rax, [rsp + 72]
    mov [rip + flac_next_sample], rax
    mov rcx, [rsp + 64]
    mov [rip + input_cursor], rcx
    cmp rax, [rsp + 40]
    ja .Lseek_search_bad
    mov rax, [rsp + 72]         #absolute start of fully validated candidate
    cmp rax, [rsp + 32]
    jb .Lseek_search_bad
    cmp rax, rbx
    ja .Lseek_search_upper_sample
    mov r14, r13
    mov r15, rax
    cmp rbx, [rip + flac_next_sample]
    jb .Lseek_search_selected
    mov rax, [rip + flac_next_sample]
    mov [rsp + 32], rax
    mov rsi, [rip + input_cursor]    #strict progress past the decoded frame
    jmp .Lseek_search_loop
.Lseek_search_upper_sample:
    mov [rsp + 40], rax
.Lseek_search_upper:
    mov rdi, r12              #strictly shrink even when mid-frame
    jmp .Lseek_search_loop
.Lseek_search_next:
    inc r13
    jmp .Lseek_search_scan
.Lseek_search_fallback:
    mov r14, [rip + flac_begin]
    xor r15d, r15d
.Lseek_search_selected:
    mov dword ptr [rip + flac_seek_probe], 0
    mov rax, [rip + input_end]
    mov [rip + flac_bit_end], rax
    mov dword ptr [rip + decode_error], 0
    mov [rip + input_cursor], r14
    mov [rip + flac_next_sample], r15
    inc dword ptr [rip + decoder_seek_probes]
    call decode_frame        #restore selected PCM and ordinary chronology
    test eax, eax
    jz .Lseek_search_bad
    mov rax, r15
    jmp .Lseek_search_return
.Lseek_search_zero:
    xor eax, eax              #first frame is already decoded and buffered
    jmp .Lseek_search_return
.Lseek_search_bad:
    mov dword ptr [rip + decode_error], 28
    xor eax, eax
    jmp .Lseek_search_return
.Lseek_search_cancel:
    mov dword ptr [rip + decode_error], 0
    xor eax, eax
.Lseek_search_return:
    mov dword ptr [rip + flac_seek_probe], 0
    mov rdx, [rip + input_end]
    mov [rip + flac_bit_end], rdx
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_seek_search

# Bounds-checked MSB-first reservoir. Width <=33, result unsigned in RAX.
LOCALFN get_bits
    mov r9d, ecx
    mov rdx, [rip + bits_buf]
    mov r8d, [rip + bits_count]
.Lgb_fill:
    cmp r8d, r9d
    jae .Lgb_extract
    mov r10, [rip + input_cursor]
    cmp r10, [rip + flac_bit_end]
    jae .Lgb_bad
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lgb_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lgb_bad
.Lgb_not_cancelled:
    shl rdx, 8
    movzx eax, byte ptr [r10]
    or rdx, rax
    inc r10
    mov [rip + input_cursor], r10
    add r8d, 8
    jmp .Lgb_fill
.Lgb_extract:
    sub r8d, r9d
    mov ecx, r8d
    mov rax, rdx
    shr rax, cl
    mov ecx, r9d
    mov r10, 1
    shl r10, cl
    dec r10
    and rax, r10
    mov [rip + bits_buf], rdx
    mov [rip + bits_count], r8d
    ret
.Lgb_bad:
    mov dword ptr [rip + decode_error], 2
    xor eax, eax
    ret
ENDFN get_bits

LOCALFN get_signed
    push rbx
    sub rsp, 32
    mov ebx, ecx
    call get_bits
    mov ecx, 64
    sub ecx, ebx
    shl rax, cl
    sar rax, cl
    add rsp, 32
    pop rbx
    ret
ENDFN get_signed

# Count unary prefixes a byte at a time using BSR; no per-bit Rice calls.
LOCALFN get_unary
    xor r11d, r11d
.Lunary_chunk:
    mov ecx, [rip + bits_count]
    test ecx, ecx
    jnz .Lunary_scan
    mov r10, [rip + input_cursor]
    cmp r10, [rip + flac_bit_end]
    jae .Lunary_bad
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lunary_not_cancelled
    cmp dword ptr [rax], 0
    jne .Lunary_bad
.Lunary_not_cancelled:
    movzx edx, byte ptr [r10]
    inc r10
    mov [rip + input_cursor], r10
    mov [rip + bits_buf], rdx
    mov ecx, 8
    mov [rip + bits_count], ecx
.Lunary_scan:
    mov rdx, [rip + bits_buf]
    mov r8, 1
    shl r8, cl
    dec r8
    and rdx, r8
    bsr r8, rdx
    jnz .Lunary_found
    add r11d, ecx
    cmp r11d, 0x1000000
    jae .Lunary_bad
    mov dword ptr [rip + bits_count], 0
    jmp .Lunary_chunk
.Lunary_found:
    sub ecx, r8d
    dec ecx
    add r11d, ecx
    mov [rip + bits_count], r8d
    mov eax, r11d
    ret
.Lunary_bad:
    mov dword ptr [rip + decode_error], 2
    xor eax, eax
    ret
ENDFN get_unary

LOCALFN init_crc_tables
    xor r11d, r11d
.Lcrc_init_byte:
    mov eax, r11d
    mov edx, r11d
    shl edx, 8
    mov ecx, 8
.Lcrc_init_bit:
    shl eax, 1
    test eax, 0x100
    jz .Lcrc_init_16
    xor eax, 7
.Lcrc_init_16:
    shl edx, 1
    test edx, 0x10000
    jz .Lcrc_init_next
    xor edx, 0x8005
.Lcrc_init_next:
    dec ecx
    jnz .Lcrc_init_bit
    lea r8, [rip + crc8_table]
    mov [r8 + r11], al
    lea r8, [rip + crc16_table]
    mov [r8 + r11*2], dx
    inc r11d
    cmp r11d, 256
    jb .Lcrc_init_byte
    mov dword ptr [rip + crc_ready], 1
    ret
ENDFN init_crc_tables

# Reflected-free FLAC CRC: RCX=start, RDX=end, R8D=8 or 16.
LOCALFN flac_crc
    xor eax, eax
    cmp r8d, 8
    je .Lcrc8_fast
    lea r10, [rip + crc16_table]
.Lcrc_byte:
    cmp rcx, rdx
    jae .Lcrc_done
    mov r8d, eax
    shr r8d, 8
    movzx r9d, byte ptr [rcx]
    inc rcx
    xor r8d, r9d
    movzx r9d, word ptr [r10 + r8*2]
    shl eax, 8
    xor eax, r9d
    and eax, 0xffff
    jmp .Lcrc_byte
.Lcrc8_fast:
    lea r10, [rip + crc8_table]
.Lcrc8_byte:
    cmp rcx, rdx
    jae .Lcrc_done
    movzx r9d, byte ptr [rcx]
    inc rcx
    xor eax, r9d
    movzx eax, byte ptr [r10 + rax]
    jmp .Lcrc8_byte
.Lcrc_done:
    ret
ENDFN flac_crc

LOCALFN decode_frame
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 64
    cmp dword ptr [rip + crc_ready], 0
    jne .Lcrc_tables_ready
    call init_crc_tables
.Lcrc_tables_ready:
    mov rax, [rip + input_cursor]
    cmp rax, [rip + input_end]
    jae .Lframe_eof
    mov [rip + frame_start], rax
    mov dword ptr [rip + bits_count], 0
    mov qword ptr [rip + bits_buf], 0
    mov ecx, 14
    call get_bits
    cmp eax, 0x3ffe
    jne .Lframe_bad
    mov ecx, 1
    call get_bits
    test eax, eax
    jnz .Lframe_bad
    mov ecx, 1
    call get_bits             # fixed / variable blocking
    mov [rip + frame_blocking], eax
    mov ecx, 4
    call get_bits
    mov [rip + block_code], eax
    mov ecx, 4
    call get_bits
    mov [rip + rate_code], eax
    mov ecx, 4
    call get_bits
    cmp eax, 10
    ja .Lframe_bad
    mov [rip + channel_mode], eax
    mov ecx, eax
    cmp ecx, 8
    jae .Lframe_stereo
    inc ecx
    jmp .Lframe_ch_check
.Lframe_stereo:
    mov ecx, 2
.Lframe_ch_check:
    cmp ecx, [rip + source_channels]
    jne .Lframe_bad
    mov ecx, 3
    call get_bits
    mov [rip + depth_code], eax
    mov ecx, 1
    call get_bits
    test eax, eax
    jnz .Lframe_bad
    # UTF-8 encoded frame / sample number; validate prefix and continuations.
    mov ecx, 8
    call get_bits
    mov [rip + frame_number], rax
    mov dword ptr [rip + frame_number_bytes], 1
    cmp eax, 0x80
    jb .Lframe_number_done
    cmp eax, 0xc0
    jb .Lframe_bad
    cmp eax, 0xff
    je .Lframe_bad
    mov ebx, 0
    mov edx, eax
.Lnumber_prefix:
    test edx, 0x80
    jz .Lnumber_counted
    inc ebx
    shl edx, 1
    jmp .Lnumber_prefix
.Lnumber_counted:
    mov [rip + frame_number_bytes], ebx
    mov ecx, ebx
    mov eax, 127
    shr eax, cl
    and [rip + frame_number], rax
    dec ebx
.Lnumber_cont:
    mov ecx, 8
    call get_bits
    mov edx, eax
    and edx, 0xc0
    cmp edx, 0x80
    jne .Lframe_bad
    and eax, 0x3f
    mov rdx, [rip + frame_number]
    shl rdx, 6
    or rdx, rax
    mov [rip + frame_number], rdx
    dec ebx
    jnz .Lnumber_cont
.Lframe_number_done:
    mov rax, [rip + frame_number]
    mov ecx, [rip + frame_number_bytes]
    cmp ecx, 1
    je .Lframe_number_limit
    imul ecx, 5
    sub ecx, 4
    cmp ecx, 6
    jne .Lframe_number_minimum
    mov ecx, 7
.Lframe_number_minimum:
    mov rdx, 1
    shl rdx, cl
    cmp rax, rdx
    jb .Lframe_bad              #reject noncanonical extended UTF-8 encodings
.Lframe_number_limit:
    mov rdx, 0xfffffffff
    cmp dword ptr [rip + frame_blocking], 0
    jne .Lframe_number_check
    mov edx, 0x7fffffff
.Lframe_number_check:
    cmp rax, rdx
    ja .Lframe_bad
    mov eax, [rip + block_code]
    test eax, eax
    jz .Lframe_bad
    cmp eax, 1
    je .Lblock192
    cmp eax, 5
    jbe .Lblock576
    cmp eax, 6
    je .Lblock8
    cmp eax, 7
    je .Lblock16
    mov ecx, eax
    sub ecx, 8
    mov eax, 256
    shl eax, cl
    jmp .Lblock_done
.Lblock192:
    mov eax, 192
    jmp .Lblock_done
.Lblock576:
    mov ecx, eax
    sub ecx, 2
    mov eax, 576
    shl eax, cl
    jmp .Lblock_done
.Lblock8:
    mov ecx, 8
    call get_bits
    inc eax
    jmp .Lblock_done
.Lblock16:
    mov ecx, 16
    call get_bits
    inc eax
.Lblock_done:
    cmp eax, 65535
    ja .Lframe_bad
    cmp eax, [rip + maximum_block]
    ja .Lframe_bad
    mov [rip + frame_samples], eax
    mov dword ptr [rip + frame_used], 0
    mov eax, [rip + rate_code]
    test eax, eax
    jz .Lrate_done
    cmp eax, 12
    je .Lrate8
    cmp eax, 14
    je .Lrate16x10
    cmp eax, 13
    je .Lrate16
    cmp eax, 15
    je .Lframe_bad
    lea rdx, [rip + rate_table]
    mov eax, [rdx + rax*4]
    jmp .Lrate_check
.Lrate8:
    mov ecx, 8
    call get_bits
    imul eax, 1000
    jmp .Lrate_check
.Lrate16x10:
    mov ecx, 16
    call get_bits
    imul eax, 10
    jmp .Lrate_check
.Lrate16:
    mov ecx, 16
    call get_bits
.Lrate_check:
    cmp eax, [rip + sample_rate]
    jne .Lframe_bad
.Lrate_done:
    mov eax, [rip + depth_code]
    test eax, eax
    jz .Linherited_depth
    lea rdx, [rip + depth_table]
    mov eax, [rdx + rax*4]
    cmp eax, [rip + source_bits]
    jne .Lframe_bad
    jmp .Ldepth_done
.Linherited_depth:
    mov eax, [rip + source_bits]
.Ldepth_done:
    mov [rip + frame_bps], eax
    # Header CRC byte is the next aligned byte.
    mov rax, [rip + input_cursor]
    mov [rip + header_end], rax
    mov ecx, 8
    call get_bits
    mov ebx, eax
    mov rcx, [rip + frame_start]
    mov rdx, [rip + header_end]
    mov r8d, 8
    call flac_crc
    cmp eax, ebx
    jne .Lframe_bad
    mov rax, [rip + frame_number]
    cmp dword ptr [rip + frame_blocking], 0
    jne .Lframe_position_check
    mov ecx, [rip + maximum_block]
    mul rcx
.Lframe_position_check:
    cmp dword ptr [rip + flac_seek_probe], 0
    je .Lframe_position_ordinary
    mov [rip + flac_next_sample], rax
.Lframe_position_ordinary:
    cmp rax, [rip + flac_next_sample]
    jne .Lframe_bad
    mov ecx, [rip + frame_samples]
    add rax, rcx
    cmp qword ptr [rip + total_frames], 0
    je .Lframe_position_valid
    cmp rax, [rip + total_frames]
    ja .Lframe_bad
.Lframe_position_valid:
    lea rcx, [rip + left_samples]
    mov edx, [rip + frame_bps]
    cmp dword ptr [rip + channel_mode], 9
    jne .Lleft_depth_done
    inc edx
.Lleft_depth_done:
    call decode_subframe
    test eax, eax
    jz .Lframe_bad
    cmp dword ptr [rip + source_channels], 1
    je .Lsubframes_done
    lea rcx, [rip + right_samples]
    mov edx, [rip + frame_bps]
    cmp dword ptr [rip + channel_mode], 8
    je .Lright_extra
    cmp dword ptr [rip + channel_mode], 10
    jne .Lright_depth_done
.Lright_extra:
    inc edx
.Lright_depth_done:
    call decode_subframe
    test eax, eax
    jz .Lframe_bad
    mov r12d, 2
.Ladditional_subframes:
    cmp r12d, [rip + source_channels]
    jae .Lsubframes_done
    lea rax, [rip + flac_channel_ptrs]
    mov rcx, [rax + r12*8]
    mov edx, [rip + frame_bps]
    call decode_subframe
    test eax, eax
    jz .Lframe_bad
    inc r12d
    jmp .Ladditional_subframes
.Lsubframes_done:
    mov ecx, [rip + bits_count]
    test ecx, ecx
    jz .Laligned_frame
    call get_bits
    test eax, eax
    jnz .Lframe_bad
.Laligned_frame:
    mov rcx, [rip + frame_start]
    mov rdx, [rip + input_cursor]
    mov r8d, 16
    call flac_crc
    mov ebx, eax
    mov ecx, 16
    call get_bits
    cmp eax, ebx
    jne .Lframe_bad
    cmp dword ptr [rip + decode_error], 0
    jne .Lframe_bad
    mov rax, [rip + input_cursor]
    cmp dword ptr [rip + flac_packet_mode], 0
    je .Lframe_native_end
    cmp rax, [rip + input_end]
    jne .Lframe_bad             # an Ogg packet holds exactly one frame
    cmp dword ptr [rip + flac_packet_final], 0
    jne .Llast_block_valid
    jmp .Lframe_minimum
.Lframe_native_end:
    cmp rax, [rip + input_end]
    jae .Llast_block_valid
.Lframe_minimum:
    mov eax, [rip + frame_samples]
    cmp eax, [rip + minimum_block]
    jb .Lframe_bad
.Llast_block_valid:
    # Restore left/right channels, using 64-bit intermediates.
    xor ebx, ebx
    lea rsi, [rip + left_samples]
    lea rdi, [rip + right_samples]
.Ldecorrelate:
    cmp ebx, [rip + frame_samples]
    jae .Ladditional_range_start
    mov rax, [rsi + rbx*8]
    mov rdx, [rdi + rbx*8]
    cmp dword ptr [rip + channel_mode], 8
    je .Lleft_side
    cmp dword ptr [rip + channel_mode], 9
    je .Lside_right
    cmp dword ptr [rip + channel_mode], 10
    jne .Ldecor_next
    shl rax, 1
    mov rcx, rdx
    and ecx, 1
    or rax, rcx
    mov rcx, rax
    add rax, rdx
    sub rcx, rdx
    sar rax, 1
    sar rcx, 1
    mov [rsi + rbx*8], rax
    mov [rdi + rbx*8], rcx
    jmp .Ldecor_next
.Lleft_side:
    sub rax, rdx
    mov [rdi + rbx*8], rax
    jmp .Ldecor_next
.Lside_right:
    add rax, rdx
    mov [rsi + rbx*8], rax
.Ldecor_next:
    mov ecx, 64
    sub ecx, [rip + source_bits]
    mov rax, [rsi + rbx*8]
    mov rdx, rax
    shl rdx, cl
    sar rdx, cl
    cmp rax, rdx
    jne .Lframe_bad
    cmp dword ptr [rip + source_channels], 1
    je .Ldecor_range_valid
    mov rax, [rdi + rbx*8]
    mov rdx, rax
    shl rdx, cl
    sar rdx, cl
    cmp rax, rdx
    jne .Lframe_bad
.Ldecor_range_valid:
    inc ebx
    jmp .Ldecorrelate
.Ladditional_range_start:
    mov r12d, 2
.Ladditional_range_channel:
    cmp r12d, [rip + source_channels]
    jae .Lframe_ok
    lea rax, [rip + flac_channel_ptrs]
    mov rsi, [rax + r12*8]
    xor ebx, ebx
    mov ecx, 64
    sub ecx, [rip + source_bits]
.Ladditional_range_sample:
    cmp ebx, [rip + frame_samples]
    jae .Ladditional_range_next
    mov rax, [rsi + rbx*8]
    mov rdx, rax
    shl rdx, cl
    sar rdx, cl
    cmp rax, rdx
    jne .Lframe_bad
    inc ebx
    jmp .Ladditional_range_sample
.Ladditional_range_next:
    inc r12d
    jmp .Ladditional_range_channel
.Lframe_ok:
    mov eax, [rip + frame_samples]
    add [rip + flac_next_sample], rax
    mov eax, 1
    jmp .Lframe_return
.Lframe_bad:
    mov dword ptr [rip + decode_error], 3
.Lframe_eof:
    xor eax, eax
.Lframe_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN decode_frame

LOCALFN decode_subframe
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 64
    mov rsi, rcx
    mov [rip + sub_bps], edx
    mov dword ptr [rip + wasted_bits], 0
    mov ecx, 1
    call get_bits
    test eax, eax
    jnz .Lsub_bad
    mov ecx, 6
    call get_bits
    mov [rip + sub_type], eax
    mov ecx, 1
    call get_bits
    test eax, eax
    jz .Lsub_header_done
    call get_unary
    inc eax
    mov [rip + wasted_bits], eax
    cmp eax, [rip + sub_bps]
    jae .Lsub_bad
    sub [rip + sub_bps], eax
.Lsub_header_done:
    mov eax, [rip + sub_type]
    test eax, eax
    jz .Lsub_constant
    cmp eax, 1
    je .Lsub_verbatim
    cmp eax, 8
    jb .Lsub_bad
    cmp eax, 12
    jbe .Lsub_fixed
    cmp eax, 32
    jb .Lsub_bad
    sub eax, 31
    mov [rip + predict_order], eax
    jmp .Lsub_warmup
.Lsub_fixed:
    sub eax, 8
    mov [rip + predict_order], eax
.Lsub_warmup:
    mov eax, [rip + predict_order]
    cmp eax, [rip + frame_samples]
    ja .Lsub_bad
    xor ebx, ebx
.Lwarmup_loop:
    cmp ebx, [rip + predict_order]
    jae .Lwarmup_done
    mov ecx, [rip + sub_bps]
    call get_signed
    mov [rsi + rbx*8], rax
    inc ebx
    jmp .Lwarmup_loop
.Lwarmup_done:
    cmp dword ptr [rip + sub_type], 32
    jb .Lresidual_start
    mov ecx, 4
    call get_bits
    cmp eax, 15
    je .Lsub_bad
    inc eax
    mov r12d, eax
    mov ecx, 5
    call get_signed
    test eax, eax
    js .Lsub_bad
    mov [rip + predict_shift], eax
    xor ebx, ebx
.Lcoeff_loop:
    cmp ebx, [rip + predict_order]
    jae .Lresidual_start
    mov ecx, r12d
    call get_signed
    lea rdx, [rip + lpc_coeff]
    mov [rdx + rbx*8], rax
    inc ebx
    jmp .Lcoeff_loop
.Lresidual_start:
    mov ecx, 2
    call get_bits
    cmp eax, 1
    ja .Lsub_bad
    add eax, 4
    mov [rip + rice_bits], eax
    mov ecx, 4
    call get_bits
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    mov [rip + partition_count], eax
    mov ecx, eax
    mov eax, [rip + frame_samples]
    xor edx, edx
    div ecx
    test edx, edx
    jnz .Lsub_bad
    mov [rip + partition_samples], eax
    cmp eax, [rip + predict_order]
    jb .Lsub_bad
    xor r12d, r12d
    mov ebx, [rip + predict_order]
.Lpartition_loop:
    mov r13d, [rip + partition_samples]
    test r12d, r12d
    jnz .Lpartition_full
    sub r13d, [rip + predict_order]
.Lpartition_full:
    mov ecx, [rip + rice_bits]
    call get_bits
    mov [rip + rice_k], eax
    mov ecx, [rip + rice_bits]
    mov edx, 1
    shl edx, cl
    dec edx
    cmp eax, edx
    je .Lresidual_escape
.Lrice_samples:
    test r13d, r13d
    jz .Lpartition_done
    call get_unary
    mov r14, rax
    cmp dword ptr [rip + decode_error], 0
    jne .Lsub_bad
.Lrice_remainder:
    mov ecx, [rip + rice_k]
    call get_bits
    mov ecx, [rip + rice_k]
    shl r14, cl
    or rax, r14
    mov edx, 0xfffffffe     # RFC 9639 excludes INT_MIN residuals
    cmp rax, rdx
    ja .Lsub_bad
    mov rdx, rax
    and edx, 1
    neg rdx
    shr rax, 1
    xor rax, rdx
    mov [rsi + rbx*8], rax
    inc ebx
    dec r13d
    jmp .Lrice_samples
.Lresidual_escape:
    mov ecx, 5
    call get_bits
    mov r14d, eax
.Lescape_samples:
    test r13d, r13d
    jz .Lpartition_done
    xor eax, eax
    test r14d, r14d
    jz .Lescape_zero
    mov ecx, r14d
    call get_signed
.Lescape_zero:
    mov [rsi + rbx*8], rax
    inc ebx
    dec r13d
    jmp .Lescape_samples
.Lpartition_done:
    inc r12d
    cmp r12d, [rip + partition_count]
    jb .Lpartition_loop
    cmp ebx, [rip + frame_samples]
    jne .Lsub_bad
    # Prediction. qword samples avoid overflow for 24-bit stereo side data.
    mov ebx, [rip + predict_order]
.Lprediction_loop:
    cmp ebx, [rip + frame_samples]
    jae .Lrestore_wasted
    cmp dword ptr [rip + sub_type], 32
    jae .Llpc_predict
    mov ecx, [rip + predict_order]
    xor eax, eax
    test ecx, ecx
    jz .Lpredicted
    mov rax, [rsi + rbx*8 - 8]
    cmp ecx, 1
    je .Lpredicted
    shl rax, 1
    sub rax, [rsi + rbx*8 - 16]
    cmp ecx, 2
    je .Lpredicted
    mov rax, [rsi + rbx*8 - 8]
    imul rax, 3
    mov rdx, [rsi + rbx*8 - 16]
    imul rdx, 3
    sub rax, rdx
    add rax, [rsi + rbx*8 - 24]
    cmp ecx, 3
    je .Lpredicted
    mov rax, [rsi + rbx*8 - 8]
    shl rax, 2
    mov rdx, [rsi + rbx*8 - 16]
    imul rdx, 6
    sub rax, rdx
    mov rdx, [rsi + rbx*8 - 24]
    shl rdx, 2
    add rax, rdx
    sub rax, [rsi + rbx*8 - 32]
    jmp .Lpredicted
.Llpc_predict:
    xor eax, eax
    xor edi, edi
    lea r12, [rip + lpc_coeff]
    lea r13, [rsi + rbx*8 - 8]
.Llpc_sum:
    cmp edi, [rip + predict_order]
    jae .Llpc_shift
    mov rdx, [r13]
    imul rdx, [r12 + rdi*8]
    add rax, rdx
    sub r13, 8
    inc edi
    jmp .Llpc_sum
.Llpc_shift:
    mov ecx, [rip + predict_shift]
    sar rax, cl
.Lpredicted:
    add rax, [rsi + rbx*8]
    # Reject an out-of-range prediction before it can enter LPC history.
    # Valid history bounds every later 32-tap accumulator to 53 bits.
    mov ecx, 64
    sub ecx, [rip + sub_bps]
    mov rdx, rax
    shl rdx, cl
    sar rdx, cl
    cmp rax, rdx
    jne .Lsub_bad
    mov [rsi + rbx*8], rax
    inc ebx
    jmp .Lprediction_loop
.Lsub_constant:
    mov ecx, [rip + sub_bps]
    call get_signed
    xor ebx, ebx
.Lconstant_loop:
    cmp ebx, [rip + frame_samples]
    jae .Lrestore_wasted
    mov [rsi + rbx*8], rax
    inc ebx
    jmp .Lconstant_loop
.Lsub_verbatim:
    xor ebx, ebx
.Lverbatim_loop:
    cmp ebx, [rip + frame_samples]
    jae .Lrestore_wasted
    mov ecx, [rip + sub_bps]
    call get_signed
    mov [rsi + rbx*8], rax
    inc ebx
    jmp .Lverbatim_loop
.Lrestore_wasted:
    cmp dword ptr [rip + decode_error], 0
    jne .Lsub_bad
    # Validate reconstructed samples before exposing any decoded frame.
    xor ebx, ebx
.Lrange_loop:
    cmp ebx, [rip + frame_samples]
    jae .Lsub_ok
    mov rax, [rsi + rbx*8]
    mov ecx, 64
    sub ecx, [rip + sub_bps]
    mov rdx, rax
    shl rdx, cl
    sar rdx, cl
    cmp rax, rdx
    jne .Lsub_bad
    mov ecx, [rip + wasted_bits]
    shl rax, cl
    mov [rsi + rbx*8], rax
    inc ebx
    jmp .Lrange_loop
.Lsub_ok:
    mov eax, 1
    jmp .Lsub_return
.Lsub_bad:
    mov dword ptr [rip + decode_error], 4
    xor eax, eax
.Lsub_return:
    add rsp, 64
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN decode_subframe

FN decoder_read
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    cmp qword ptr [rip + map_base], 0
    je .Lread_done
    cmp dword ptr [rip + decode_error], 0
    jne .Lread_done
    cmp dword ptr [rip + chain_active], 0
    je .Lread_track
    mov rcx, rdi
    mov edx, r12d
    call chain_read
    mov ebx, eax
    jmp .Lread_done
.Lread_track:
    cmp dword ptr [rip + track_active], 0
    je .Lread_single
    mov rcx, rdi
    mov edx, r12d
    call track_read
    mov ebx, eax
    jmp .Lread_done
.Lread_single:
    cmp dword ptr [rip + codec_kind], 17  # Monkey's Audio
    jne .Lread_not_ape
    mov rcx, rdi
    mov edx, r12d
    call ape_read
    mov ebx, eax
    jmp .Lread_done
.Lread_not_ape:
    cmp dword ptr [rip + codec_kind], 13  # CAF linear PCM and G.711
    je .Lread_existing
    cmp dword ptr [rip + codec_kind], 14  # AVI and FLV PCM and G.711
    je .Lread_existing
    cmp dword ptr [rip + codec_kind], 15
    je .Lread_existing
    cmp dword ptr [rip + codec_kind], 16  # AU
    je .Lread_existing
    cmp dword ptr [rip + codec_kind], 18  # LPCM in MPEG-TS/PS
    je .Lread_existing
    cmp dword ptr [rip + codec_kind], 1
    jb .Lread_done
    cmp dword ptr [rip + codec_kind], 6
    ja .Lread_done
    cmp dword ptr [rip + codec_kind], 3
    jne .Lread_existing
    mov rcx, rdi
    mov edx, r12d
    call mp3_read
    mov ebx, eax
    jmp .Lread_done
.Lread_existing:
    test r12d, r12d
    jz .Lread_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lread_existing_dispatch
    cmp dword ptr [rax], 0
    je .Lread_existing_dispatch
    mov dword ptr [rip + decode_error], 3
    jmp .Lread_done
.Lread_existing_dispatch:
    cmp dword ptr [rip + codec_kind], 1
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 6
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 13
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 14
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 15
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 16
    je .Lread_wav
    cmp dword ptr [rip + codec_kind], 18
    je .Lread_wav
.Lread_flac:
    mov rcx, rdi
    mov edx, r12d
    call flac_read
    mov ebx, eax
    jmp .Lread_done
.Lread_wav:
    mov rcx, rdi
    mov edx, r12d
    call wav_emit
    mov ebx, eax
.Lread_done:
    mov eax, ebx
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN decoder_read

# RCX=stereo float output, EDX=frames -> EAX=frames from the int64 channel
# buffers (flac_channel_ptrs) of a decoded frame; frame_samples and
# frame_used describe it. Shared with ALAC.
FN flac_emit
    jmp flac_read
ENDFN flac_emit

# RCX=stereo float output, EDX=frame capacity -> EAX=frames, for native FLAC
# and FLAC-in-Ogg.
LOCALFN flac_read
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
.Lflac_read_next:
    cmp ebx, r12d
    jae .Lflac_read_done
    mov eax, [rip + frame_used]
    cmp eax, [rip + frame_samples]
    jb .Lflac_emit
    call flac_next_frame
    test eax, eax
    jz .Lflac_read_done
.Lflac_emit:
    mov ecx, [rip + frame_used]
    cmp dword ptr [rip + pcm_mix], 0
    jne .Lflac_emit_mix
    lea rsi, [rip + left_samples]
    cvtsi2ss xmm0, qword ptr [rsi + rcx*8]
    mulss xmm0, [rip + float_scale]
    movss dword ptr [rdi + rbx*8], xmm0
    cmp dword ptr [rip + source_channels], 1
    je .Lflac_mono
    lea rsi, [rip + right_samples]
    cvtsi2ss xmm0, qword ptr [rsi + rcx*8]
    mulss xmm0, [rip + float_scale]
.Lflac_mono:
    movss dword ptr [rdi + rbx*8 + 4], xmm0
    jmp .Lflac_emit_done
.Lflac_emit_mix:
    xor r9d, r9d
    lea r10, [rip + flac_channel_ptrs]
    lea r11, [rip + pcm_mix_coeff]
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
.Lflac_emit_channel:
    mov rax, [r10 + r9*8]
    cvtsi2sd xmm2, qword ptr [rax + rcx*8]
    movapd xmm3, xmm2
    mulsd xmm2, qword ptr [r11]
    mulsd xmm3, qword ptr [r11 + 8]
    addsd xmm0, xmm2
    addsd xmm1, xmm3
    add r11, 16
    inc r9d
    cmp r9d, [rip + source_channels]
    jb .Lflac_emit_channel
    cvtss2sd xmm2, [rip + float_scale]
    mulsd xmm0, xmm2
    mulsd xmm1, xmm2
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss dword ptr [rdi + rbx*8], xmm0
    movss dword ptr [rdi + rbx*8 + 4], xmm1
.Lflac_emit_done:
    inc dword ptr [rip + frame_used]
    inc ebx
    jmp .Lflac_read_next
.Lflac_read_done:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN flac_read

# RCX=stereo float output, EDX=frame capacity -> EAX=frames of interleaved
# PCM from input_cursor up to wav_end (WAV, AIFF/AIFC and track PCM).
LOCALFN wav_emit
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rcx
    mov r12d, edx
    xor ebx, ebx
    mov rsi, [rip + input_cursor]
.Lwav_emit:
    cmp ebx, r12d
    jae .Lwav_read_done
    cmp rsi, [rip + wav_end]
    jae .Lwav_read_done
    cmp dword ptr [rip + pcm_mix], 0
    jne .Lwav_emit_mix
    call wav_sample
    movss dword ptr [rdi + rbx*8], xmm0
    cmp dword ptr [rip + source_channels], 1
    je .Lwav_mono
    call wav_sample
.Lwav_mono:
    movss dword ptr [rdi + rbx*8 + 4], xmm0
    jmp .Lwav_emit_done
.Lwav_emit_mix:
    xor r9d, r9d
    lea r10, [rip + pcm_mix_coeff]
    xorpd xmm4, xmm4
    xorpd xmm5, xmm5
.Lwav_mix_channel:
    call wav_sample_double
    movapd xmm1, xmm0
    mulsd xmm0, qword ptr [r10]
    mulsd xmm1, qword ptr [r10 + 8]
    addsd xmm4, xmm0
    addsd xmm5, xmm1
    add r10, 16
    inc r9d
    cmp r9d, [rip + source_channels]
    jb .Lwav_mix_channel
    minsd xmm4, [rip + wav_float_max]
    maxsd xmm4, [rip + wav_float_min]
    minsd xmm5, [rip + wav_float_max]
    maxsd xmm5, [rip + wav_float_min]
    cvtsd2ss xmm0, xmm4
    cvtsd2ss xmm1, xmm5
    movss dword ptr [rdi + rbx*8], xmm0
    movss dword ptr [rdi + rbx*8 + 4], xmm1
.Lwav_emit_done:
    inc ebx
    jmp .Lwav_emit
.Lwav_read_done:
    mov [rip + input_cursor], rsi
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wav_emit

LOCALFN wav_sample
    sub rsp, 40
    call wav_sample_double
    cvtsd2ss xmm0, xmm0
    add rsp, 40
    ret
ENDFN wav_sample

# RSI advances by the physical container width. Caller accumulation uses
# XMM4/5 and R9/10; this helper preserves them. Finite float64 inputs clamp
# to the representable float32 range before mixing; NaN/Inf become silence.
LOCALFN wav_sample_double
    cmp dword ptr [rip + wav_format], 3
    je .Lsample_float
    sub rsp, 40
    call wav_integer_sample
    cvtsi2sd xmm0, rax
    cvtss2sd xmm1, [rip + float_scale]
    mulsd xmm0, xmm1
    add rsp, 40
    ret
.Lsample_float:
    cmp dword ptr [rip + wav_container_bits], 64
    je .Lsample_float64
    mov eax, [rsi]
    add rsi, 4
    cmp dword ptr [rip + pcm_big_endian], 0
    je .Lsample_float32_ordered
    bswap eax
.Lsample_float32_ordered:
    mov edx, eax
    and edx, 0x7f800000
    cmp edx, 0x7f800000
    je .Lsample_float_bad
    movd xmm0, eax
    cvtss2sd xmm0, xmm0
    ret
.Lsample_float64:
    mov rax, [rsi]
    add rsi, 8
    cmp dword ptr [rip + pcm_big_endian], 0
    je .Lsample_float64_ordered
    bswap rax
.Lsample_float64_ordered:
    mov rdx, 0x7ff0000000000000
    and rdx, rax
    mov rcx, 0x7ff0000000000000
    cmp rdx, rcx
    je .Lsample_float_bad
    movq xmm0, rax
    minsd xmm0, [rip + wav_float_max]
    maxsd xmm0, [rip + wav_float_min]
    ret
.Lsample_float_bad:
    xorpd xmm0, xmm0
    ret
ENDFN wav_sample_double

LOCALFN wav_integer_sample
    cmp dword ptr [rip + pcm_big_endian], 0
    jne .Lsample_big_integer
    mov eax, [rip + wav_container_bits]
    cmp eax, 8
    je .Lsample8
    cmp eax, 16
    je .Lsample16
    cmp eax, 24
    je .Lsample24
    movsxd rax, dword ptr [rsi]
    add rsi, 4
    jmp .Lsample_padding
.Lsample8:
    cmp dword ptr [rip + pcm_g711], 0
    jne .Lsample_g711
    cmp dword ptr [rip + pcm_signed8], 0
    jne .Lsample_signed8
    movzx eax, byte ptr [rsi]
    sub eax, 128
    movsxd rax, eax
    inc rsi
    jmp .Lsample_padding
.Lsample_signed8:
    movsx rax, byte ptr [rsi]
    inc rsi
    jmp .Lsample_padding
.Lsample16:
    movsx rax, word ptr [rsi]
    add rsi, 2
    jmp .Lsample_padding
.Lsample24:
    movzx eax, word ptr [rsi]
    movsx edx, byte ptr [rsi + 2]
    shl edx, 16
    or eax, edx
    movsxd rax, eax
    add rsi, 3
    jmp .Lsample_padding
.Lsample_big_integer:
    mov eax, [rip + wav_container_bits]
    cmp eax, 8
    je .Lsample8
    cmp eax, 16
    je .Lsample_big16
    cmp eax, 24
    je .Lsample_big24
    mov eax, [rsi]
    bswap eax
    movsxd rax, eax
    add rsi, 4
    jmp .Lsample_padding
.Lsample_big16:
    mov ax, [rsi]
    rol ax, 8
    movsx rax, ax
    add rsi, 2
    jmp .Lsample_padding
.Lsample_big24:
    movsx eax, byte ptr [rsi]
    shl eax, 16
    movzx edx, word ptr [rsi + 1]
    rol dx, 8
    or eax, edx
    movsxd rax, eax
    add rsi, 3
.Lsample_padding:
    mov ecx, [rip + wav_container_bits]
    sub ecx, [rip + source_bits]
    sar rax, cl
    shl rax, cl
    ret
.Lsample_g711:
    movzx eax, byte ptr [rsi]
    inc rsi
    lea rdx, [rip + g711_alaw]
    cmp dword ptr [rip + pcm_g711], 1
    je .Lsample_g711_table
    lea rdx, [rip + g711_ulaw]
.Lsample_g711_table:
    movsx rax, word ptr [rdx + rax*2]
    ret
ENDFN wav_integer_sample
