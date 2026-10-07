# LAMP original Windows x86-64 assembly playback engine. No CRT.
# Single producer / single consumer queue: x86 TSO publishes complete PCM
# before write_count; consumer publishes read_count after copying. Only the
# producer accesses the file/decoder. Render path has no locks or allocations.
.include "lamp.inc"
.globl engine_mode, engine_stop_requested
.globl engine_position, engine_seek_seconds, engine_volume, pause_requested
.globl engine_ready, engine_opened, engine_play_list, engine_command, engine_heard_index, engine_heard_ms
.globl read_count, device_chosen, device_id, devices_callback
.globl exit_code, underruns, endpoint_dry

.equ RING_FRAMES, 262144
.equ RING_MASK, RING_FRAMES - 1
.equ CHUNK_FRAMES, 2048
.equ REFILL_FRAMES, RING_FRAMES*3/4    # a full ring refills once it holds no more
.equ RESUME_PATH, 16384               # UTF-8 bytes of a path
.equ RESUME_WIDE, 4096                # UTF-16 units of a path

.data
usage: .ascii "LAMP 0.4.0-dev - Lev's Assembly Media Player"
.byte 13, 10
      .ascii "Handwritten x86-64 assembly: PCM, FLAC, ALAC, WavPack, Monkey's Audio, MP1/MP2/MP3, AAC-LC/HE-AAC, AC-3/E-AC-3, Vorbis, Opus"
      .byte 13, 10
      .ascii "in WAV/W64, AIFF/AIFC, CAF, AU, FLAC, WavPack, APE, MP3, AAC (ADTS, LOAS), AC-3, Ogg, Matroska/WebM, MP4/MOV, AVI, FLV, ASF and MPEG-TS/PS files."
      .byte 13, 10
      .ascii "Usage: lamp-cli.exe [--start TIME] [--repeat] [--resume] [--device NAME] [--rate HZ|device]"
      .byte 13, 10
      .ascii "                    [--track N] file.mp3 [more files...]"
      .byte 13, 10
      .ascii "       lamp-cli.exe --check [--start TIME] [--rate HZ] [--track N] file.flac [more files...]"
      .byte 13, 10
      .ascii "       lamp-cli.exe --decode [--start TIME] [--rate HZ] [--track N] file.flac [more files...] output.f32"
      .byte 13, 10
      .ascii "       lamp-cli.exe --tags file.mp3"
      .byte 13, 10
      .ascii "       lamp-cli.exe --chapters file.m4b"
      .byte 13, 10
      .ascii "       lamp-cli.exe --cover file.mp3 cover-image"
      .byte 13, 10
      .ascii "       lamp-cli.exe --list-devices"
      .byte 13, 10
      .ascii "Several files play one after another without a gap, at the first file's rate;"
      .byte 13, 10
      .ascii "M3U/M3U8 and PLS playlists add their entries. --rate resamples every file to HZ, or to the"
      .byte 13, 10
      .ascii "output's mix rate, with LAMP's own filter. --track plays each file's Nth audio track, counted"
      .byte 13, 10
      .ascii "in the container's order."
      .byte 13, 10
      .ascii "Playback: Space pauses/resumes; N/P next/previous file; [/] previous/next chapter; Q or Ctrl+C stops."
      .byte 13, 10
      .ascii "RIFF/RF64/BW64 WAV: 1..8 channels, PCM 8/16/24/32 or float32/64."
      .byte 13, 10
      .ascii "AIFF/AIFC: signed PCM 1..32 bits or float32/64, 1..8 channels."
      .byte 13, 10
      .ascii "Native FLAC: 4..32 bit, 1..8 channels, speaker-mask-aware downmix."
      .byte 13, 10
      .ascii "Opus families 0/1; playback and float export output stereo."
      .byte 13, 10, 0
open_error: .ascii "Unsupported, malformed, or inaccessible file. Supports WAV/W64, AIFF/AIFC, CAF, AU, FLAC, WavPack, Monkey's Audio, MP1/MP2/MP3, AAC (LC, HE), AC-3/E-AC-3, Ogg (Vorbis, Opus, FLAC), Matroska/WebM, MP4/MOV, AVI, FLV, ASF and MPEG-TS/PS audio."
.byte 13, 10, 0
audio_error: .ascii "Audio endpoint unavailable or WASAPI failed. Try --check to verify decoding."
.byte 13, 10, 0
output_error: .ascii "Cannot create output file."
.byte 13, 10, 0
play_text: .ascii "Playing. Space: pause / resume. N / P: next / previous file. Left / Right: -5 / +5 s."
.byte 13, 10
    .ascii "Down / Up: -60 / +60 s. [ / ]: previous / next chapter. R: repeat. Q or Ctrl+C: stop."
.byte 13, 10, 0
repeat_on_text: .ascii "Repeat: on"
.byte 13, 10, 0
audio_lost: .ascii "Audio output lost; reopening."
.byte 13, 10, 0
repeat_off_text: .ascii "Repeat: off"
.byte 13, 10, 0
stats_a: .ascii "codec="
.byte 0
stats_b: .ascii " rate="
.byte 0
stats_c: .ascii " channels="
.byte 0
stats_d: .ascii " bits="
.byte 0
stats_e: .ascii " frames="
.byte 0
stats_f: .ascii " underruns="
.byte 0
stats_g: .ascii " decode_error="
.byte 0
stats_h: .ascii " audio_error="
.byte 0
stats_i: .ascii " elapsed_ms="
.byte 0
stats_j: .ascii " cpu_us="
.byte 0
stats_k: .ascii " endpoint_dry="
.byte 0
newline: .byte 13, 10, 0
check_arg: .short '-', '-', 'c', 'h', 'e', 'c', 'k', 0
decode_arg: .short '-', '-', 'd', 'e', 'c', 'o', 'd', 'e', 0
tags_arg: .short '-', '-', 't', 'a', 'g', 's', 0
chapters_arg: .short '-', '-', 'c', 'h', 'a', 'p', 't', 'e', 'r', 's', 0
cover_arg: .short '-', '-', 'c', 'o', 'v', 'e', 'r', 0
repeat_arg: .short '-', '-', 'r', 'e', 'p', 'e', 'a', 't', 0
start_arg: .short '-', '-', 's', 't', 'a', 'r', 't', 0
resume_arg: .short '-', '-', 'r', 'e', 's', 'u', 'm', 'e', 0
device_arg: .short '-', '-', 'd', 'e', 'v', 'i', 'c', 'e', 0
list_devices_arg: .short '-', '-', 'l', 'i', 's', 't', '-', 'd', 'e', 'v', 'i', 'c', 'e', 's', 0
rate_arg: .short '-', '-', 'r', 'a', 't', 'e', 0
rate_device: .short 'd', 'e', 'v', 'i', 'c', 'e', 0
track_arg: .short '-', '-', 't', 'r', 'a', 'c', 'k', 0
unknown_device: .ascii "Unknown audio device."
.byte 13, 10, 0
devices_failed: .ascii "Audio devices unavailable."
.byte 13, 10, 0
tab_text: .asciz "\t"
.p2align 2
pkey_friendly_name: .long 0xa45c254e      # PKEY_Device_FriendlyName
    .short 0xdf1c, 0x4efd
    .byte 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0
    .long 14
resume_local: .short 'L', 'O', 'C', 'A', 'L', 'A', 'P', 'P', 'D', 'A', 'T', 'A', 0
resume_folder_tail: .short 92, 'L', 'A', 'M', 'P', 0
resume_file_tail: .short 92, 'r', 'e', 's', 'u', 'm', 'e', '.', 't', 'x', 't', 0
resume_temp_tail: .short '.', 't', 'm', 'p', 0
resuming_text: .asciz "Resuming at "
.p2align 3
cli_modes: .quad check_arg, 1, decode_arg, 2, tags_arg, 3, chapters_arg, 4, cover_arg, 5, list_devices_arg, 6
    .quad 0, 0
cli_device: .quad 0                  # --device's argument (wide)
device_chosen: .quad 0               # its endpoint ID (device_id), 0 for the default
devices_enum: .quad 0                # audio_devices' enumerator
devices_callback: .quad 0            # audio_devices' ECX=2 callback
cli_start_ms: .quad 0
cli_rate: .long 0                    # --rate: Hz, -1 for the output's, 0 for the first file's
engine_seek_ms: .quad 0              # console: where playback starts in the current file
engine_heard_ms: .quad 0             # position in the heard file at a command
cli_repeat: .long 0
cli_resume: .long 0
cli_count: .long 0
.p2align 3
cli_paths: .quad 0                   # the expanded list
resume_ms: .quad 0
arg_index: .long 0
engine_quit: .long 0                 # Q or Ctrl+C stopped console playback
engine_command: .long 0              # set by a key: 1 next, 2 previous, 3 seek; 4 the list again
engine_seek_delta: .long 0           # seconds
engine_heard_index: .long 0
console_greeted: .long 0
time_text: .zero 64
clock_text: .zero 32
device_text: .zero 1024              # a device's ID or name in UTF-8
no_cover: .ascii "No embedded cover art."
.byte 13, 10, 0
bytes_text: .ascii " bytes"
.byte 13, 10, 0
space_text: .asciz " "
skipped_text: .ascii "Skipped a file that is unsupported, malformed, or inaccessible."
.byte 13, 10, 0
.p2align 3
engine_opened: .quad 0               # hook on the playback thread once engine_play opens its file
input_list: .quad 0                  # the files to play, as argv pointers
input_count: .quad 0
engine_path: .quad 0                 # engine_play's file, a queue of one
equals_text: .asciz "="
line_end: .byte 13, 10, 0
audio_task: .short 'A', 'u', 'd', 'i', 'o', 0
clsid_enumerator: .long 0xbcde0395
    .short 0xe52f, 0x467c
    .byte 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e
iid_enumerator: .long 0xa95664d2
    .short 0x9614, 0x4f35
    .byte 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6
iid_client: .long 0x1cb9ad4c
    .short 0xdbfa, 0x4c32
    .byte 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x3, 0xb2
iid_render: .long 0xf294acfc
    .short 0x3146, 0x4483
    .byte 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2
wavefmt: .short 3, 2
    .long 48000, 384000
    .short 8, 32, 0
stdout: .quad 0
stdin: .quad 0
output_file: .quad -1
argv: .quad 0
argc: .long 0
operation: .long 0                  # 0 play, 1 check, 2 decode, 3 tags, 4 chapters, 5 cover
exit_code: .long 0
stop_event: .quad 0
data_event: .quad 0
space_event: .quad 0
audio_event: .quad 0
producer_thread: .quad 0
control_thread: .quad 0
.p2align 4
write_count: .quad 0
    .zero 7*8
read_count: .quad 0
    .zero 7*8
decoded_count: .quad 0
underruns: .quad 0
endpoint_dry: .quad 0
producer_done: .long 0
pause_requested: .long 0
was_paused: .long 0
audio_hresult: .long 0
enum_obj: .quad 0
device_obj: .quad 0
client_obj: .quad 0
render_obj: .quad 0
mmcss: .quad 0
task_index: .long 0
buffer_frames: .long 0
padding: .long 0
render_frames: .long 0
render_bytes: .long 0
render_buffer: .quad 0
prebuffer_frames: .long 0
console_mode: .long 0
console_original_mode: .long 0
console_changed: .long 0
com_initialized: .long 0
events: .quad 0, 0
start_tick: .quad 0
elapsed_ms: .quad 0
cpu_us: .quad 0
creation_time: .quad 0
exit_time: .quad 0
kernel_time: .quad 0
user_time: .quad 0
engine_mode: .long 0
engine_stop_requested: .long 0
engine_position: .quad 0
engine_seek_seconds: .long 0
engine_ready: .long 0
engine_seek_frames: .quad 0
engine_volume: .float 1.0

.bss
tag_line: .zero 4100
.p2align 3
resume_folder: .zero RESUME_WIDE*2
resume_state: .zero RESUME_WIDE*2
resume_temp: .zero RESUME_WIDE*2
resume_wide: .zero RESUME_WIDE*2
resume_key: .zero RESUME_PATH
resume_heard: .zero RESUME_PATH
resume_found: .zero RESUME_PATH
device_id: .zero 1024                # the chosen endpoint's ID (wide)
device_variant: .zero 24             # PROPVARIANT
device_collection: .quad 0
device_item: .quad 0
device_store: .quad 0
device_string: .quad 0               # an endpoint ID from GetId
ring_pcm: .zero RING_FRAMES*8
offline_pcm: .zero CHUNK_FRAMES*8
bytes_written: .zero 4
input_record: .zero 20
number_buffer: .zero 32

.text
# Called on a dedicated rendering thread by the native UI: RCX=path, played
# from engine_seek_seconds -> EAX=exit code.
FN engine_play
    mov [rip + engine_path], rcx
    lea rcx, [rip + engine_path]
    mov edx, 1
    xor r8d, r8d
    mov eax, [rip + engine_seek_seconds]
    imul r9, rax, 1000
    jmp engine_play_list
ENDFN engine_play

# RCX=path pointers, EDX=count, R8D=index of the first file to play, R9=
# milliseconds into it -> EAX=exit code. The same producer/WASAPI engine
# backs the CLI and window; the files play as one gapless queue.
# engine_opened is called on this thread once the first file opens and on
# the producer thread as each later file opens. A stream that played and
# then lost its endpoint returns with engine_command 5 and the heard file
# and position in engine_heard_index and engine_heard_ms.
FN engine_play_list
    sub rsp, 136
    mov [rsp + 96], r8
    mov [rsp + 104], r9
    mov dword ptr [rip + engine_mode], 1
    xor eax, eax
    mov [rip + operation], eax
    mov [rip + exit_code], eax
    mov [rip + producer_done], eax
    mov [rip + engine_ready], eax
    mov [rip + was_paused], eax
    mov [rip + audio_hresult], eax
    mov [rip + engine_command], eax
    mov [rip + write_count], rax
    mov [rip + read_count], rax
    mov [rip + decoded_count], rax
    mov [rip + underruns], rax
    mov [rip + endpoint_dry], rax
    mov [rip + engine_position], rax
    mov [rip + queue_skipped], rax
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    mov rax, [rip + engine_opened]
    mov [rip + queue_announce], rax
    call queue_open
    test eax, eax
    jz bad_input
    mov rax, [rsp + 104]
    mov ecx, [rsp + 96]
    cmp ecx, [rip + queue_index]
    je .Lengine_list_start
    xor eax, eax                        # a later file opened instead
.Lengine_list_start:
    mov [rip + engine_seek_ms], rax
    mov rax, [rip + engine_opened]
    test rax, rax
    jz .Lengine_opened
    call rax
.Lengine_opened:
    call console_seek
    cmp dword ptr [rip + engine_stop_requested], 0
    jne cleanup
    jmp start_playback
ENDFN engine_play_list
FN engine_stop
    sub rsp, 40
    mov dword ptr [rip + engine_stop_requested], 1
    mov rcx, [rip + stop_event]
    test rcx, rcx
    jz .Lengine_stop_done
    call SetEvent
.Lengine_stop_done:
    add rsp, 40
    ret
ENDFN engine_stop
FN engine_pause
    sub rsp, 40
    xor dword ptr [rip + pause_requested], 1
    mov rcx, [rip + audio_event]
    test rcx, rcx
    jz .Lengine_pause_done
    call SetEvent
.Lengine_pause_done:
    add rsp, 40
    ret
ENDFN engine_pause
FN start
    sub rsp, 136                # entry RSP is 8 mod16 -> aligned for calls
    mov ecx, -11
    call GetStdHandle
    mov [rip + stdout], rax
    call GetTickCount64
    mov [rip + start_tick], rax
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + argc]
    call CommandLineToArgvW
    mov [rip + argv], rax
    test rax, rax
    jz .Lshow_help
    mov dword ptr [rip + arg_index], 1
    # Options before the files: one mode, --start TIME, --repeat, "--".
.Lopt_next:
    mov eax, [rip + arg_index]
    cmp eax, [rip + argc]
    jae .Lopt_files
    mov rcx, [rip + argv]
    mov rcx, [rcx + rax*8]
    cmp dword ptr [rcx], 0x002d002d     # L"--"
    jne .Lopt_files
    inc dword ptr [rip + arg_index]
    cmp word ptr [rcx + 4], 0
    je .Lopt_files                      # "--" ends the options
    mov [rsp + 64], rcx
    lea rax, [rip + cli_modes]
    mov [rsp + 72], rax
.Lopt_mode:
    mov rax, [rsp + 72]
    mov rdx, [rax]
    test rdx, rdx
    jz .Lopt_other
    mov rcx, [rsp + 64]
    call equal_wide
    test eax, eax
    jnz .Lopt_mode_found
    add qword ptr [rsp + 72], 16
    jmp .Lopt_mode
.Lopt_mode_found:
    cmp dword ptr [rip + operation], 0
    jne .Lshow_help                     # one mode
    mov rax, [rsp + 72]
    mov eax, [rax + 8]
    mov [rip + operation], eax
    jmp .Lopt_next
.Lopt_other:
    mov rcx, [rsp + 64]
    lea rdx, [rip + repeat_arg]
    call equal_wide
    test eax, eax
    jz .Lopt_start
    mov dword ptr [rip + cli_repeat], 1
    jmp .Lopt_next
.Lopt_start:
    mov rcx, [rsp + 64]
    lea rdx, [rip + resume_arg]
    call equal_wide
    test eax, eax
    jz .Lopt_start_name
    mov dword ptr [rip + cli_resume], 1
    jmp .Lopt_next
.Lopt_start_name:
    mov rcx, [rsp + 64]
    lea rdx, [rip + device_arg]
    call equal_wide
    test eax, eax
    jz .Lopt_start_time
    mov eax, [rip + arg_index]
    cmp eax, [rip + argc]
    jae .Lshow_help
    inc dword ptr [rip + arg_index]
    mov rcx, [rip + argv]
    mov rcx, [rcx + rax*8]
    mov [rip + cli_device], rcx
    jmp .Lopt_next
.Lopt_start_time:
    mov rcx, [rsp + 64]
    lea rdx, [rip + start_arg]
    call equal_wide
    test eax, eax
    jz .Lopt_rate
    mov eax, [rip + arg_index]
    cmp eax, [rip + argc]
    jae .Lshow_help
    inc dword ptr [rip + arg_index]
    mov rcx, [rip + argv]
    mov rcx, [rcx + rax*8]
    xor edx, edx                        # narrow the time to ASCII
.Lopt_time_char:
    movzx eax, word ptr [rcx + rdx*2]
    cmp eax, 0x7f
    ja .Lshow_help
    cmp edx, 63
    jae .Lshow_help
    lea r8, [rip + time_text]
    mov [r8 + rdx], al
    inc edx
    test eax, eax
    jnz .Lopt_time_char
    lea rcx, [rip + time_text]
    call parse_time
    jc .Lshow_help
    mov [rip + cli_start_ms], rax
    jmp .Lopt_next
.Lopt_rate:
    mov rcx, [rsp + 64]
    lea rdx, [rip + rate_arg]
    call equal_wide
    test eax, eax
    jz .Lopt_track
    mov eax, [rip + arg_index]
    cmp eax, [rip + argc]
    jae .Lshow_help
    inc dword ptr [rip + arg_index]
    mov rcx, [rip + argv]
    mov rcx, [rcx + rax*8]
    mov [rsp + 64], rcx
    lea rdx, [rip + rate_device]
    call equal_wide
    mov edx, -1
    test eax, eax
    jnz .Lopt_rate_set
    mov rcx, [rsp + 64]
    xor edx, edx
    xor r8d, r8d                        # digits
.Lopt_rate_digit:
    movzx eax, word ptr [rcx]
    test eax, eax
    jz .Lopt_rate_end
    sub eax, '0'
    cmp eax, 9
    ja .Lshow_help
    cmp r8d, 7
    jae .Lshow_help
    imul edx, edx, 10
    add edx, eax
    inc r8d
    add rcx, 2
    jmp .Lopt_rate_digit
.Lopt_rate_end:
    cmp edx, 1000
    jb .Lshow_help
    cmp edx, 768000
    ja .Lshow_help
.Lopt_rate_set:
    mov [rip + cli_rate], edx
    jmp .Lopt_next
.Lopt_track:
    mov rcx, [rsp + 64]
    lea rdx, [rip + track_arg]
    call equal_wide
    test eax, eax
    jz .Lshow_help
    mov eax, [rip + arg_index]
    cmp eax, [rip + argc]
    jae .Lshow_help
    inc dword ptr [rip + arg_index]
    mov rcx, [rip + argv]
    mov rcx, [rcx + rax*8]
    xor edx, edx
    xor r8d, r8d                        # digits
.Lopt_track_digit:
    movzx eax, word ptr [rcx]
    test eax, eax
    jz .Lopt_track_end
    sub eax, '0'
    cmp eax, 9
    ja .Lshow_help
    cmp r8d, 4
    jae .Lshow_help
    imul edx, edx, 10
    add edx, eax
    inc r8d
    add rcx, 2
    jmp .Lopt_track_digit
.Lopt_track_end:
    test edx, edx
    jz .Lshow_help                      # tracks count from 1
    mov [rip + track_choice], edx
    jmp .Lopt_next
.Lopt_files:
    mov eax, [rip + argc]
    sub eax, [rip + arg_index]
    mov [rip + input_count], rax
    mov ecx, [rip + arg_index]
    mov rax, [rip + argv]
    lea rax, [rax + rcx*8]
    mov [rip + input_list], rax
    mov eax, [rip + operation]
    mov ecx, [rip + cli_repeat]
    or ecx, [rip + cli_resume]
    or rcx, [rip + cli_device]
    jz .Lopt_repeat_checked
    test eax, eax
    jnz .Lshow_help                     # --repeat, --resume and --device play
.Lopt_repeat_checked:
    cmp dword ptr [rip + cli_rate], 0
    je .Lopt_rate_checked
    cmp eax, 3
    jae .Lshow_help                     # --rate decodes or plays
    test eax, eax
    jz .Lopt_rate_checked
    cmp dword ptr [rip + cli_rate], -1
    je .Lshow_help                      # the output's rate is playback's
.Lopt_rate_checked:
    cmp eax, 6
    jne .Lopt_not_list
    cmp qword ptr [rip + input_count], 0
    jne .Lshow_help
    cmp qword ptr [rip + cli_start_ms], 0
    jne .Lshow_help
    xor ecx, ecx
    call audio_devices
    jmp cleanup
.Lopt_not_list:
    cmp eax, 3
    jb .Lopt_queue_mode
    cmp qword ptr [rip + cli_start_ms], 0
    jne .Lshow_help                     # --start decodes or plays
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    cmp dword ptr [rip + operation], 5
    je .Lopt_cover
    cmp qword ptr [rip + input_count], 1
    jne .Lshow_help
    mov rax, [rip + input_list]
    mov rcx, [rax]
    call decoder_open
    test eax, eax
    jz bad_input
    jmp .Ltags_only
.Lopt_cover:
    cmp qword ptr [rip + input_count], 2
    jne .Lshow_help
    mov rax, [rip + input_list]
    mov rcx, [rax]
    call decoder_open
    test eax, eax
    jz bad_input
    call cover_get
    test rax, rax
    jz .Lcover_none
    mov rax, [rip + input_list]
    mov rcx, [rax + 8]                  # the output
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1 # CREATE_NEW: never truncate existing output
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    mov [rip + output_file], rax
    cmp rax, -1
    je .Lbad_output
    call cover_get
    mov [rip + render_bytes], edx
    mov rcx, [rip + output_file]
    mov r8d, edx
    mov rdx, rax
    lea r9, [rip + bytes_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    test eax, eax
    jz .Lbad_output
    mov eax, [rip + bytes_written]
    cmp eax, [rip + render_bytes]
    jne .Lbad_output
    call cover_get
    mov [rsp + 56], rdx
    lea rax, [rip + cover_mimes]
    mov rcx, [rax + r8*8]
    call print_text
    lea rcx, [rip + space_text]
    call print_text
    mov rcx, [rsp + 56]
    call print_number
    lea rcx, [rip + bytes_text]
    call print_text
    jmp cleanup
.Lcover_none:
    mov dword ptr [rip + exit_code], 2
    lea rcx, [rip + no_cover]
    call print_text
    jmp cleanup
.Lopt_queue_mode:
    cmp qword ptr [rip + input_count], 0
    je .Lshow_help
    cmp eax, 2
    jne .Lopen_input
    cmp qword ptr [rip + input_count], 2
    jb .Lshow_help
    dec qword ptr [rip + input_count]
    mov rax, [rip + input_list]
    mov rcx, [rip + input_count]
    mov rcx, [rax + rcx*8]              # the last argument
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1 # CREATE_NEW: never truncate existing output
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    mov [rip + output_file], rax
    cmp rax, -1
    je .Lbad_output
.Lopen_input:
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    lea rax, [rip + report_skipped]
    mov [rip + queue_skipped], rax
    mov rcx, [rip + input_list]
    mov edx, [rip + input_count]
    call playlist_expand                # M3U and PLS playlists become their entries
    mov [rip + cli_paths], rax
    mov [rip + cli_count], edx
    mov eax, [rip + cli_rate]           # --rate HZ: the session rate
    cmp eax, -1
    jne .Lopen_rate
    xor eax, eax
.Lopen_rate:
    mov [rip + queue_target], eax
    cmp dword ptr [rip + operation], 0
    jne .Lopen_queue
    cmp qword ptr [rip + cli_device], 0
    je .Lopen_device_rate
    mov ecx, 1
    call audio_devices                  # find --device
    test eax, eax
    jz cleanup                          # exit code 3, reported
.Lopen_device_rate:
    cmp dword ptr [rip + cli_rate], -1
    jne .Lopen_queue
    call audio_mix_rate                 # --rate device: the endpoint's mix rate
    mov [rip + queue_target], eax       # (0, the first file's, when unknown)
.Lopen_queue:
    mov rcx, [rip + cli_paths]
    mov edx, [rip + cli_count]
    call queue_begin                    # files play one after another
    test eax, eax
    jz bad_input
    cmp dword ptr [rip + operation], 0
    jne .Loffline_start
.Lconsole_device:
    mov rax, [rip + cli_start_ms]
    mov [rip + engine_seek_ms], rax
    cmp dword ptr [rip + cli_resume], 0
    je .Lconsole_tags
    test rax, rax
    jnz .Lconsole_tags                  # --start wins over --resume
    mov rcx, [rip + cli_paths]
    mov edx, [rip + cli_count]
    call win_resume_lookup
    test eax, eax
    jz .Lconsole_tags
    mov [rip + engine_seek_ms], rdx
    cmp ecx, [rip + queue_index]
    je .Lconsole_resuming
    mov [rsp + 80], ecx
    call queue_goto                     # a later file of the list
    test eax, eax
    jz bad_input
    mov ecx, [rsp + 80]
    cmp ecx, [rip + queue_index]
    je .Lconsole_resuming
    mov qword ptr [rip + engine_seek_ms], 0   # it did not open; the next did
    jmp .Lconsole_tags
.Lconsole_resuming:
    lea rcx, [rip + resuming_text]
    call print_text
    mov rcx, [rip + engine_seek_ms]
    lea rdx, [rip + clock_text]
    call format_clock
    mov rcx, rax
    call print_text
    lea rcx, [rip + line_end]
    call print_text
.Lconsole_tags:
    call print_tags
    lea rax, [rip + announce_next]
    mov [rip + queue_announce], rax
    mov eax, [rip + cli_repeat]
    mov [rip + queue_repeat], eax
    call console_seek
    jmp start_playback
.Loffline_start:
    mov rcx, [rip + cli_start_ms]       # --start, read exactly
    call queue_start
    jmp .Loffline_loop
.Ltags_only:
    cmp dword ptr [rip + operation], 4
    je .Lchapters_only
    call print_tags
    jmp cleanup
.Lchapters_only:
    call print_chapters
    jmp cleanup
.Loffline_loop:
    lea rcx, [rip + offline_pcm]
    mov edx, CHUNK_FRAMES
    call queue_read
    test eax, eax
    jz .Loffline_finished
    add [rip + decoded_count], rax
    cmp dword ptr [rip + operation], 2
    jne .Loffline_loop
    shl eax, 3
    mov [rip + render_bytes], eax
    mov rcx, [rip + output_file]
    lea rdx, [rip + offline_pcm]
    mov r8d, eax
    lea r9, [rip + bytes_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    test eax, eax
    jz .Lbad_output
    mov eax, [rip + bytes_written]
    cmp eax, [rip + render_bytes]
    jne .Lbad_output
    jmp .Loffline_loop
.Loffline_finished:
    cmp dword ptr [rip + decode_error], 0   # the queue checks each file's length
    jne .Ldecoding_failed
    jmp .Lreport_finish
.Ldecoding_failed:
    mov dword ptr [rip + exit_code], 2
    jmp .Lreport_finish
start_playback:
    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventW
    mov [rip + stop_event], rax
    test rax, rax
    jz .Lbad_audio
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventW
    mov [rip + data_event], rax
    test rax, rax
    jz .Lbad_audio
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventW
    mov [rip + space_event], rax
    test rax, rax
    jz .Lbad_audio
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventW
    mov [rip + audio_event], rax
    test rax, rax
    jz .Lbad_audio
    cmp dword ptr [rip + engine_mode], 0
    jne .Lskip_console_handler
    cmp dword ptr [rip + console_greeted], 0
    jne .Lskip_console_handler          # registered on the first start
    lea rcx, [rip + ctrl_handler]
    mov edx, 1
    call SetConsoleCtrlHandler
.Lskip_console_handler:
    cmp dword ptr [rip + engine_stop_requested], 0
    je .Laudio_start_not_cancelled
    mov rcx, [rip + stop_event]
    call SetEvent
    jmp .Lplayback_stopped
.Laudio_start_not_cancelled:
    xor ecx, ecx
    mov edx, 2                 # COINIT_APARTMENTTHREADED for initial IAudioClient
    call CoInitializeEx
    test eax, eax
    js .Lbad_audio
    mov dword ptr [rip + com_initialized], 1
    lea rcx, [rip + clsid_enumerator]
    xor edx, edx
    mov r8d, 1
    lea r9, [rip + iid_enumerator]
    lea rax, [rip + enum_obj]
    mov [rsp + 32], rax
    call CoCreateInstance
    test eax, eax
    js .Lbad_audio
    mov rcx, [rip + enum_obj]
    mov rdx, [rip + device_chosen]
    test rdx, rdx
    jz .Laudio_default_device
    lea r8, [rip + device_obj]
    mov rax, [rcx]
    call qword ptr [rax + 40]           # GetDevice: --device's endpoint
    test eax, eax
    jns .Laudio_device_opened
    mov qword ptr [rip + device_chosen], 0   # gone: the default from now on
    mov rcx, [rip + enum_obj]
.Laudio_default_device:
    xor edx, edx
    xor r8d, r8d
    lea r9, [rip + device_obj]
    mov rax, [rcx]
    call qword ptr [rax + 32]           # GetDefaultAudioEndpoint
.Laudio_device_opened:
    test eax, eax
    js .Lbad_audio
    mov rcx, [rip + device_obj]
    lea rdx, [rip + iid_client]
    mov r8d, 1
    xor r9d, r9d
    lea rax, [rip + client_obj]
    mov [rsp + 32], rax
    mov rax, [rcx]
    call qword ptr [rax + 24]
    test eax, eax
    js .Laudio_device_failed
    mov eax, [rip + queue_rate]            # the session rate; later files may differ
    mov dword ptr [rip + wavefmt + 4], eax
    shl eax, 3
    mov dword ptr [rip + wavefmt + 8], eax
    mov rcx, [rip + client_obj]
    xor edx, edx
    mov r8d, 0x88040000         # AUTOCONVERTPCM | SRC_DEFAULT_QUALITY | EVENTCALLBACK
    mov r9d, 2000000          # 200 ms render buffer; favor robustness over latency
    mov qword ptr [rsp + 32], 0
    lea rax, [rip + wavefmt]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    mov rax, [rcx]
    call qword ptr [rax + 24]
    test eax, eax
    js .Laudio_device_failed
    mov rcx, [rip + client_obj]
    lea rdx, [rip + buffer_frames]
    mov rax, [rcx]
    call qword ptr [rax + 32]
    test eax, eax
    js .Lbad_audio
    mov rcx, [rip + client_obj]
    mov rdx, [rip + audio_event]
    mov rax, [rcx]
    call qword ptr [rax + 104]
    test eax, eax
    js .Lbad_audio
    mov rcx, [rip + client_obj]
    lea rdx, [rip + iid_render]
    lea r8, [rip + render_obj]
    mov rax, [rcx]
    call qword ptr [rax + 112]
    test eax, eax
    js .Lbad_audio
    # Start decoder worker before joining MMCSS on this rendering thread.
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + producer]
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    mov [rip + producer_thread], rax
    test rax, rax
    jz .Lbad_audio
    mov eax, [rip + queue_rate]
    mov ecx, 3
    mul ecx
    shr eax, 2
    cmp eax, RING_FRAMES/2
    jbe .Lprebuffer_set
    mov eax, RING_FRAMES/2
.Lprebuffer_set:
    mov [rip + prebuffer_frames], eax
    mov rax, [rip + stop_event]
    mov [rip + events], rax
    mov rax, [rip + data_event]
    mov [rip + events + 8], rax
.Lprebuffer_wait:
    mov rax, [rip + write_count]
    cmp eax, [rip + prebuffer_frames]
    jae .Lprebuffer_ready
    cmp dword ptr [rip + producer_done], 0
    jne .Lprebuffer_ready
    mov ecx, 2
    lea rdx, [rip + events]
    xor r8d, r8d
    mov r9d, -1
    call WaitForMultipleObjects
    cmp eax, 1
    je .Lprebuffer_wait
    jmp .Lplayback_stopped
.Lprebuffer_ready:
    mov dword ptr [rip + engine_ready], 1
    cmp qword ptr [rip + write_count], 0
    je .Lplayback_stopped
    lea rcx, [rip + audio_task]
    lea rdx, [rip + task_index]
    call AvSetMmThreadCharacteristicsW
    mov [rip + mmcss], rax
    cmp dword ptr [rip + engine_mode], 0
    jne .Lno_keyboard
    cmp dword ptr [rip + console_greeted], 0
    jne .Lconsole_greeted
    mov dword ptr [rip + console_greeted], 1
    lea rcx, [rip + play_text]
    call print_text
.Lconsole_greeted:
    # Keyboard thread waits on input or stop; no periodic polling.
    mov ecx, -10
    call GetStdHandle
    mov [rip + stdin], rax
    mov rcx, rax
    lea rdx, [rip + console_mode]
    call GetConsoleMode
    test eax, eax
    jz .Lno_keyboard
    mov eax, [rip + console_mode]
    cmp dword ptr [rip + console_changed], 0
    jne .Lconsole_mode_saved            # a restart: the original is kept
    mov [rip + console_original_mode], eax
.Lconsole_mode_saved:
    and eax, 0xffffffbf       # disable QuickEdit so selecting console won't hang audio
    or eax, 0x80
    mov rcx, [rip + stdin]
    mov edx, eax
    call SetConsoleMode
    test eax, eax
    jz .Lno_keyboard
    mov dword ptr [rip + console_changed], 1
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + keyboard]
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    mov [rip + control_thread], rax
.Lno_keyboard:
    call fill_render
    cmp dword ptr [rip + audio_hresult], 0
    jne .Lbad_audio_saved
    mov rax, [rip + audio_event]
    mov [rip + events + 8], rax
    cmp dword ptr [rip + pause_requested], 0
    je .Linitial_audio_start
    # A seek while paused must never start the new endpoint before resume.
    mov dword ptr [rip + was_paused], 1
    jmp .Lpause_wait
.Linitial_audio_start:
    mov rcx, [rip + client_obj]
    mov rax, [rcx]
    call qword ptr [rax + 80]
    test eax, eax
    js .Lbad_audio
.Laudio_wait:
    mov ecx, 2
    lea rdx, [rip + events]
    xor r8d, r8d
    mov r9d, 2000
    call WaitForMultipleObjects
    cmp eax, 0
    je .Lplayback_stopped
    cmp eax, 1
    jne .Lbad_audio_timeout
    cmp dword ptr [rip + pause_requested], 0
    je .Lresume_check
    cmp dword ptr [rip + was_paused], 0
    jne .Lpause_wait
    mov rcx, [rip + client_obj]
    mov rax, [rcx]
    call qword ptr [rax + 88]
    test eax, eax
    js .Lbad_audio
    mov dword ptr [rip + was_paused], 1
.Lpause_wait:
    # keyboard signals audio_event on each pause/resume, so wait has no polling.
    mov ecx, 2
    lea rdx, [rip + events]
    xor r8d, r8d
    mov r9d, -1
    call WaitForMultipleObjects
    test eax, eax
    jz .Lplayback_stopped
    jmp .Lresume_check
.Lresume_check:
    cmp dword ptr [rip + pause_requested], 0
    jne .Lpause_wait
    cmp dword ptr [rip + was_paused], 0
    je .Laudio_fill
    mov rcx, [rip + client_obj]
    mov rax, [rcx]
    call qword ptr [rax + 80]
    test eax, eax
    js .Lbad_audio
    mov dword ptr [rip + was_paused], 0
.Laudio_fill:
    # At EOF, drain queued PCM and the endpoint padding before exiting.
    cmp dword ptr [rip + producer_done], 0
    je .Laudio_more
    mov rax, [rip + read_count]
    cmp rax, [rip + write_count]
    jne .Laudio_more
    mov rcx, [rip + client_obj]
    lea rdx, [rip + padding]
    mov rax, [rcx]
    call qword ptr [rax + 48]
    test eax, eax
    js .Lbad_audio
    cmp dword ptr [rip + padding], 0
    je .Laudio_drained
    jmp .Laudio_wait
.Laudio_drained:
    # Repeat turned on after the producer read the last file: play the list
    # again from its first file (when this run played anything).
    cmp dword ptr [rip + engine_mode], 0
    jne .Lplayback_stopped
    cmp dword ptr [rip + queue_repeat], 0
    je .Lplayback_stopped
    cmp qword ptr [rip + read_count], 0
    je .Lplayback_stopped
    cmp dword ptr [rip + engine_command], 0
    jne .Lplayback_stopped
    mov dword ptr [rip + engine_command], 4
    jmp .Lplayback_stopped
.Laudio_more:
    call fill_render
    cmp dword ptr [rip + audio_hresult], 0
    jne .Lbad_audio_saved
    jmp .Laudio_wait
.Laudio_device_failed:
    # --device's endpoint would not activate or initialize (it may have gone
    # since it was chosen): the default endpoint from now on.
    cmp qword ptr [rip + device_chosen], 0
    je .Lbad_audio
    mov qword ptr [rip + device_chosen], 0
    lea rcx, [rip + client_obj]
    call release_com
    lea rcx, [rip + device_obj]
    call release_com
    mov rcx, [rip + enum_obj]
    jmp .Laudio_default_device
.Lbad_audio_timeout:
    mov eax, 0x800705b4
.Lbad_audio:
    mov [rip + audio_hresult], eax
.Lbad_audio_saved:
    # A stream that played and then lost its endpoint (invalidated, or
    # silent past the timeout): reopen the heard file where it was (the
    # console here, the window on return).
    cmp dword ptr [rip + engine_ready], 0
    je .Lbad_audio_report
    cmp qword ptr [rip + read_count], 0
    je .Lbad_audio_report
    cmp dword ptr [rip + engine_command], 0
    jne .Lbad_audio_report
    mov eax, [rip + audio_hresult]
    cmp eax, 0x88890004                 # AUDCLNT_E_DEVICE_INVALIDATED
    je .Lbad_audio_lost
    cmp eax, 0x800705b4                 # no callback within 2 s
    jne .Lbad_audio_report
.Lbad_audio_lost:
    call console_note_heard
    mov dword ptr [rip + engine_command], 5
    mov dword ptr [rip + audio_hresult], 0
    lea rcx, [rip + audio_lost]
    call print_text
    jmp .Lplayback_stopped
.Lbad_audio_report:
    mov dword ptr [rip + exit_code], 3
    lea rcx, [rip + audio_error]
    call print_text
.Lplayback_stopped:
    mov rcx, [rip + stop_event]
    test rcx, rcx
    jz .Lstopped_no_event
    call SetEvent
.Lstopped_no_event:
    mov rcx, [rip + client_obj]
    test rcx, rcx
    jz .Lstopped_no_client
    mov rax, [rcx]
    call qword ptr [rax + 88]
.Lstopped_no_client:
    mov rcx, [rip + producer_thread]
    test rcx, rcx
    jz .Ljoined_producer
    mov edx, -1
    call WaitForSingleObject
.Ljoined_producer:
    mov rcx, [rip + control_thread]
    test rcx, rcx
    jz .Ljoined_keyboard
    mov edx, -1
    call WaitForSingleObject
.Ljoined_keyboard:
    mov rcx, [rip + mmcss]
    test rcx, rcx
    jz .Lno_mmcss
    call AvRevertMmThreadCharacteristics
.Lno_mmcss:
    mov qword ptr [rip + mmcss], 0
    cmp dword ptr [rip + engine_mode], 0
    jne .Lstopped_report
    cmp dword ptr [rip + exit_code], 3
    je .Lstopped_report
    cmp dword ptr [rip + engine_command], 0
    je .Lstopped_report
    call console_restart
    test eax, eax
    jnz start_playback
.Lstopped_report:
    cmp dword ptr [rip + engine_mode], 0
    jne .Lstopped_decode
    cmp dword ptr [rip + cli_resume], 0
    je .Lstopped_decode
    cmp dword ptr [rip + exit_code], 3
    je .Lstopped_decode
    xor edx, edx                        # the list ended: forget it
    cmp dword ptr [rip + engine_quit], 0
    je .Lstopped_resume
    call console_note_heard             # stopped: keep where
    mov edx, 1
.Lstopped_resume:
    mov rcx, [rip + cli_paths]
    call resume_save
.Lstopped_decode:
    cmp dword ptr [rip + decode_error], 0
    je .Lreport_finish
    mov dword ptr [rip + exit_code], 2
.Lreport_finish:
    call report_stats
    jmp cleanup
bad_input:
    cmp dword ptr [rip + engine_stop_requested], 0
    jne cleanup              #cancelled open is a normal engine stop
    mov dword ptr [rip + exit_code], 2
    lea rcx, [rip + open_error]
    call print_text
    jmp cleanup
.Lbad_output:
    mov dword ptr [rip + exit_code], 4
    lea rcx, [rip + output_error]
    call print_text
    jmp cleanup
.Lshow_help:
    lea rcx, [rip + usage]
    call print_text
cleanup:
    call decoder_close
    cmp dword ptr [rip + console_changed], 0
    je .Lcleanup_console
    mov rcx, [rip + stdin]
    mov edx, [rip + console_original_mode]
    call SetConsoleMode
.Lcleanup_console:
    lea rcx, [rip + render_obj]
    call release_com
    lea rcx, [rip + client_obj]
    call release_com
    lea rcx, [rip + device_obj]
    call release_com
    lea rcx, [rip + enum_obj]
    call release_com
    cmp dword ptr [rip + com_initialized], 0
    je .Lcleanup_no_com
    call CoUninitialize
.Lcleanup_no_com:
    lea rcx, [rip + producer_thread]
    call close_pointer
    lea rcx, [rip + control_thread]
    call close_pointer
    lea rcx, [rip + stop_event]
    call close_pointer
    lea rcx, [rip + data_event]
    call close_pointer
    lea rcx, [rip + space_event]
    call close_pointer
    lea rcx, [rip + audio_event]
    call close_pointer
    mov rcx, [rip + output_file]
    cmp rcx, -1
    je .Lcleanup_args
    call CloseHandle
.Lcleanup_args:
    mov rcx, [rip + argv]
    mov qword ptr [rip + argv], 0
    test rcx, rcx
    jz .Lexit_now
    call LocalFree
.Lexit_now:
    cmp dword ptr [rip + engine_mode], 0
    je .Lexit_console
    mov qword ptr [rip + output_file], -1
    mov dword ptr [rip + com_initialized], 0
    mov eax, [rip + exit_code]
    add rsp, 136
    ret
.Lexit_console:
    mov ecx, [rip + exit_code]
    call ExitProcess
ENDFN start

LOCALFN producer
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 64
    mov rcx, [rip + engine_seek_frames]
    test rcx, rcx
    jz .Lproducer_loop
    call queue_seek
    mov [rip + decoded_count], rax
.Lproducer_seek:
    mov rcx, [rip + stop_event]
    xor edx, edx
    call WaitForSingleObject
    test eax, eax
    jz .Lproducer_exit
    mov rax, [rip + engine_seek_frames]
    sub rax, [rip + decoded_count]
    jbe .Lproducer_loop
    mov edx, CHUNK_FRAMES
    cmp rax, rdx
    cmovb edx, eax
    lea rcx, [rip + offline_pcm]
    call queue_read
    test eax, eax
    jz .Lproducer_eof
    add [rip + decoded_count], rax
    jmp .Lproducer_seek
.Lproducer_loop:
    mov rcx, [rip + stop_event]
    xor edx, edx
    call WaitForSingleObject
    test eax, eax
    jz .Lproducer_exit
    mov rbx, [rip + write_count]
    mov rax, rbx
    sub rax, [rip + read_count]
    cmp rax, RING_FRAMES
    jae .Lproducer_wait
    mov edx, RING_FRAMES
    sub edx, eax
    cmp edx, CHUNK_FRAMES
    jbe .Lproducer_chunk
    mov edx, CHUNK_FRAMES
.Lproducer_chunk:
    mov rsi, rbx
    and esi, RING_MASK
    mov eax, RING_FRAMES
    sub eax, esi
    cmp edx, eax
    jbe .Lproducer_contiguous
    mov edx, eax
.Lproducer_contiguous:
    lea rcx, [rip + ring_pcm]
    lea rcx, [rcx + rsi*8]
    call queue_read
    test eax, eax
    jz .Lproducer_eof
    add [rip + decoded_count], rax
    add rbx, rax
    mov [rip + write_count], rbx     # publish after all float samples are written
    mov rcx, [rip + data_event]
    call SetEvent
    jmp .Lproducer_loop
.Lproducer_wait:
    mov rax, [rip + stop_event]
    mov [rsp + 32], rax
    mov rax, [rip + space_event]
    mov [rsp + 40], rax
    mov ecx, 2
    lea rdx, [rsp + 32]
    xor r8d, r8d
    mov r9d, -1
    call WaitForMultipleObjects
    cmp eax, 1
    je .Lproducer_loop
    jmp .Lproducer_exit
.Lproducer_eof:                         # the queue checked each file's length
.Lproducer_exit:
    mov dword ptr [rip + producer_done], 1
    mov rcx, [rip + data_event]
    call SetEvent
    xor eax, eax
    add rsp, 64
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN producer

LOCALFN fill_render
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rcx, [rip + client_obj]
    lea rdx, [rip + padding]
    mov rax, [rcx]
    call qword ptr [rax + 48]
    test eax, eax
    js .Lfill_bad
    cmp dword ptr [rip + padding], 0
    jne .Lfill_padding_ok
    cmp qword ptr [rip + read_count], 0
    je .Lfill_padding_ok
    inc qword ptr [rip + endpoint_dry] # endpoint emptied before this refill
.Lfill_padding_ok:
    mov rax, [rip + read_count]
    mov edx, [rip + padding]
    cmp rax, rdx
    jb .Lfill_position_done
    sub rax, rdx
    add rax, [rip + engine_seek_frames]
    mov [rip + engine_position], rax
.Lfill_position_done:
    mov eax, [rip + buffer_frames]
    sub eax, [rip + padding]
    jz .Lfill_done
    mov rbx, [rip + read_count]
    mov rdx, [rip + write_count]
    sub rdx, rbx
    cmp rdx, rax
    jae .Lfill_size
    # EOF: submit only the real tail, then drain it without adding silence.
    cmp dword ptr [rip + producer_done], 0
    je .Lfill_starved
    mov eax, edx
    test eax, eax
    jz .Lfill_done
    jmp .Lfill_size
.Lfill_starved:
    inc qword ptr [rip + underruns]
.Lfill_size:
    mov [rip + render_frames], eax
    mov r12d, eax
    mov rcx, [rip + render_obj]
    mov edx, eax
    lea r8, [rip + render_buffer]
    mov rax, [rcx]
    call qword ptr [rax + 24]
    test eax, eax
    js .Lfill_bad
    mov rdi, [rip + render_buffer]
    mov rdx, [rip + write_count]
    sub rdx, rbx
    cmp rdx, r12
    jbe .Lfill_have
    mov rdx, r12
.Lfill_have:
    mov [rsp + 32], rdx
    mov r8, rdx
    and ebx, RING_MASK
    lea rsi, [rip + ring_pcm]
    lea rsi, [rsi + rbx*8]
    mov ecx, RING_FRAMES
    sub ecx, ebx
    cmp rcx, rdx
    jbe .Lcopy_first
    mov rcx, rdx
.Lcopy_first:
    sub r8, rcx
    rep movsq
    mov rcx, r8
    lea rsi, [rip + ring_pcm]
    rep movsq
    mov rcx, r12
    sub rcx, [rsp + 32]
    xor eax, eax
    rep stosq                 # explicit silence only on actual starvation
    cmp dword ptr [rip + engine_volume], 0x3f800000
    je .Lfill_volume_done
    movss xmm0, dword ptr [rip + engine_volume]
    shufps xmm0, xmm0, 0
    mov rdx, [rip + render_buffer]
    mov ecx, [rip + render_frames]
    shl ecx, 1
.Lfill_volume:
    cmp ecx, 4
    jb .Lfill_volume_tail
    movups xmm1, [rdx]
    mulps xmm1, xmm0
    movups [rdx], xmm1
    add rdx, 16
    sub ecx, 4
    jmp .Lfill_volume
.Lfill_volume_tail:
    test ecx, ecx
    jz .Lfill_volume_done
    movss xmm1, dword ptr [rdx]
    mulss xmm1, xmm0
    movss dword ptr [rdx], xmm1
    add rdx, 4
    dec ecx
    jmp .Lfill_volume_tail
.Lfill_volume_done:
    mov rcx, [rip + render_obj]
    mov edx, [rip + render_frames]
    xor r8d, r8d
    mov rax, [rcx]
    call qword ptr [rax + 32]
    test eax, eax
    js .Lfill_bad
    mov rax, [rsp + 32]
    add [rip + read_count], rax      # publish consumed PCM after copy and ReleaseBuffer
    mov rax, [rip + write_count]     # wake the producer only once it can refill
    sub rax, [rip + read_count]
    cmp rax, REFILL_FRAMES
    ja .Lfill_done
    mov rcx, [rip + space_event]
    call SetEvent
    jmp .Lfill_done
.Lfill_bad:
    mov [rip + audio_hresult], eax
.Lfill_done:
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN fill_render

# Console keys: Space pauses, Q stops, R toggles repeat; N or >, P or <
# and the arrow/bracket keys stop playback with an engine_command, noting the file
# heard and the position in it.
LOCALFN keyboard
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov rax, [rip + stop_event]
    mov [rsp + 32], rax
    mov rax, [rip + stdin]
    mov [rsp + 40], rax
.Lkeyboard_wait:
    mov ecx, 2
    lea rdx, [rsp + 32]
    xor r8d, r8d
    mov r9d, -1
    call WaitForMultipleObjects
    cmp eax, 1
    jne .Lkeyboard_exit
    mov rcx, [rip + stdin]
    lea rdx, [rip + input_record]
    mov r8d, 1
    lea r9, [rip + bytes_written]
    call ReadConsoleInputW
    test eax, eax
    jz .Lkeyboard_exit
    cmp word ptr [rip + input_record], 1
    jne .Lkeyboard_wait
    cmp dword ptr [rip + input_record + 4], 0
    je .Lkeyboard_wait
    movzx eax, word ptr [rip + input_record + 10]   # virtual key
    movzx ecx, word ptr [rip + input_record + 14]   # character
    mov edx, 6
    cmp ecx, ']'
    je .Lkeyboard_command
    mov edx, 7
    cmp ecx, '['
    je .Lkeyboard_command
    cmp eax, 0x20
    je .Lkeyboard_pause
    cmp eax, 0x52                       # R
    je .Lkeyboard_repeat
    mov edx, 1
    cmp eax, 0x4e                       # N
    je .Lkeyboard_command
    cmp ecx, '>'
    je .Lkeyboard_command
    mov edx, 2
    cmp eax, 0x50                       # P
    je .Lkeyboard_command
    cmp ecx, '<'
    je .Lkeyboard_command
    mov edx, 3
    mov r8d, 5
    cmp eax, 0x27                       # right
    je .Lkeyboard_seek
    mov r8d, -5
    cmp eax, 0x25                       # left
    je .Lkeyboard_seek
    mov r8d, 60
    cmp eax, 0x26                       # up
    je .Lkeyboard_seek
    mov r8d, -60
    cmp eax, 0x28                       # down
    je .Lkeyboard_seek
    cmp eax, 0x51                       # Q
    jne .Lkeyboard_wait
    mov dword ptr [rip + engine_quit], 1
    mov rcx, [rip + stop_event]
    call SetEvent
    jmp .Lkeyboard_exit
.Lkeyboard_seek:
    mov [rip + engine_seek_delta], r8d
.Lkeyboard_command:
    mov [rip + engine_command], edx
    call console_note_heard
    cmp dword ptr [rip + engine_heard_index], 0
    jns .Lkeyboard_known
    mov dword ptr [rip + engine_command], 0
    jmp .Lkeyboard_wait
.Lkeyboard_known:
    mov rcx, [rip + stop_event]
    call SetEvent
    jmp .Lkeyboard_exit
.Lkeyboard_repeat:
    xor dword ptr [rip + queue_repeat], 1
    lea rcx, [rip + repeat_on_text]
    jnz .Lkeyboard_repeat_text
    lea rcx, [rip + repeat_off_text]
.Lkeyboard_repeat_text:
    call print_text
    jmp .Lkeyboard_wait
.Lkeyboard_pause:
    xor dword ptr [rip + pause_requested], 1
    mov rcx, [rip + audio_event]
    call SetEvent
    jmp .Lkeyboard_wait
.Lkeyboard_exit:
    xor eax, eax
    leave
    ret
ENDFN keyboard

# engine_heard_index and engine_heard_ms <- the file at engine_position.
LOCALFN console_note_heard
    sub rsp, 40
    mov rcx, [rip + engine_position]
    mov [rsp + 32], rcx
    call queue_heard
    mov [rip + engine_heard_index], eax
    test eax, eax
    js .Lheard_none
    mov rax, [rsp + 32]
    sub rax, rdx
    jae .Lheard_offset
    xor eax, eax
.Lheard_offset:
    mov ecx, 1000
    mul rcx
    mov ecx, [rip + queue_rate]
    test ecx, ecx
    jz .Lheard_none
    div rcx
    jmp .Lheard_store
.Lheard_none:
    xor eax, eax
.Lheard_store:
    mov [rip + engine_heard_ms], rax
    add rsp, 40
    ret
ENDFN console_note_heard

# engine_seek_frames and engine_position <- engine_seek_ms at the session
# rate, at most the current file's frames.
LOCALFN console_seek
    mov rax, [rip + engine_seek_ms]
    mov ecx, [rip + queue_rate]
    mul rcx
    mov ecx, 1000
    cmp rdx, rcx
    jae .Lconsole_seek_far
    div rcx
    jmp .Lconsole_seek_frames
.Lconsole_seek_far:
    mov rax, -1
.Lconsole_seek_frames:
    mov r8, rax
    call queue_frames                  # the file's length at the session rate
    mov rcx, rax
    mov rax, r8
    test rcx, rcx
    jz .Lconsole_seek_store
    cmp rax, rcx
    cmova rax, rcx
.Lconsole_seek_store:
    mov [rip + engine_seek_frames], rax
    mov [rip + engine_position], rax
    ret
ENDFN console_seek

# Console playback stopped with an engine_command: releases the stream, its
# threads and events, reopens the queue there (queue_navigate) and resets
# the engine for start_playback -> EAX=1 to play again, 0 to finish.
LOCALFN console_restart
    sub rsp, 40
    lea rcx, [rip + render_obj]
    call release_com
    lea rcx, [rip + client_obj]
    call release_com
    lea rcx, [rip + device_obj]
    call release_com
    lea rcx, [rip + enum_obj]
    call release_com
    cmp dword ptr [rip + com_initialized], 0
    je .Lrestart_threads
    call CoUninitialize
    mov dword ptr [rip + com_initialized], 0
.Lrestart_threads:
    lea rcx, [rip + producer_thread]
    call close_pointer
    lea rcx, [rip + control_thread]
    call close_pointer
    lea rcx, [rip + stop_event]
    call close_pointer
    lea rcx, [rip + data_event]
    call close_pointer
    lea rcx, [rip + space_event]
    call close_pointer
    lea rcx, [rip + audio_event]
    call close_pointer
    mov ecx, [rip + engine_command]
    mov edx, [rip + engine_heard_index]
    mov r8, [rip + engine_heard_ms]
    mov r9d, [rip + engine_seek_delta]
    cmp ecx, 5
    jne .Lrestart_list
    mov ecx, 3                          # reopen: a seek by 0
    xor r9d, r9d
    jmp .Lrestart_navigate
.Lrestart_list:
    cmp ecx, 4
    jne .Lrestart_navigate
    mov dword ptr [rip + engine_heard_index], -1   # the list again: its tags
.Lrestart_navigate:
    call queue_navigate
    test eax, eax
    jz .Lrestart_return
    mov [rip + engine_seek_ms], rdx
    mov eax, [rip + queue_index]
    cmp eax, [rip + engine_heard_index]
    je .Lrestart_reset
    call announce_next                  # another file: its tags
.Lrestart_reset:
    xor eax, eax
    mov [rip + write_count], rax
    mov [rip + read_count], rax
    mov [rip + decoded_count], rax
    mov [rip + producer_done], eax
    mov [rip + engine_ready], eax
    mov [rip + engine_stop_requested], eax
    mov [rip + was_paused], eax
    mov [rip + audio_hresult], eax
    mov [rip + engine_command], eax
    call console_seek
    mov eax, 1
.Lrestart_return:
    add rsp, 40
    ret
ENDFN console_restart

LOCALFN ctrl_handler
    sub rsp, 40
    mov dword ptr [rip + engine_quit], 1
    mov rcx, [rip + stop_event]
    test rcx, rcx
    jz .Lctrl_done
    call SetEvent
.Lctrl_done:
    mov eax, 1
    add rsp, 40
    ret
ENDFN ctrl_handler

LOCALFN equal_wide
.Lequal_loop:
    movzx eax, word ptr [rcx]
    cmp ax, [rdx]
    jne .Lequal_no
    add rcx, 2
    add rdx, 2
    test eax, eax
    jnz .Lequal_loop
    mov eax, 1
    ret
.Lequal_no:
    xor eax, eax
    ret
ENDFN equal_wide

LOCALFN print_text
    cmp dword ptr [rip + engine_mode], 0
    je .Lprint_console_text
    ret
.Lprint_console_text:
    sub rsp, 56
    mov rdx, rcx
    xor r8d, r8d
.Ltext_length:
    cmp byte ptr [rdx + r8], 0
    je .Ltext_write
    inc r8d
    jmp .Ltext_length
.Ltext_write:
    mov rcx, [rip + stdout]
    lea r9, [rip + bytes_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 56
    ret
ENDFN print_text

# Queue hook: RCX=path (wide) of a file that does not play.
LOCALFN report_skipped
    sub rsp, 40
    lea rcx, [rip + skipped_text]
    call print_text
    add rsp, 40
    ret
ENDFN report_skipped

# Queue hook during playback: the next file's tags after a blank line.
LOCALFN announce_next
    sub rsp, 40
    lea rcx, [rip + line_end]
    call print_text
    call print_tags
    add rsp, 40
    ret
ENDFN announce_next

# Writes the opened file's tags as "key=value" lines (UTF-8); control
# characters in values print as spaces.
LOCALFN print_tags
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    xor ebx, ebx
.Ltags_key:
    mov ecx, ebx
    call tags_get
    test rax, rax
    jz .Ltags_next
    mov rsi, rax
    mov edi, edx
    lea rax, [rip + tag_names]
    mov rcx, [rax + rbx*8]
    call print_text
    lea rcx, [rip + equals_text]
    call print_text
    lea rdx, [rip + tag_line]
    xor ecx, ecx
.Ltags_char:
    cmp ecx, edi
    jae .Ltags_end
    cmp ecx, 4096
    jae .Ltags_end
    movzx eax, byte ptr [rsi + rcx]
    cmp eax, 0x20
    jae .Ltags_store
    mov eax, 0x20
.Ltags_store:
    mov [rdx + rcx], al
    inc ecx
    jmp .Ltags_char
.Ltags_end:
    mov byte ptr [rdx + rcx], 0
    lea rcx, [rip + tag_line]
    call print_text
    lea rcx, [rip + line_end]
    call print_text
.Ltags_next:
    inc ebx
    cmp ebx, 10
    jb .Ltags_key
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN print_tags

# Writes the opened file's chapters as "HH:MM:SS.mmm title" lines (UTF-8).
LOCALFN print_chapters
    push rbx
    push rsi
    sub rsp, 40
    call chapters_count
    mov esi, eax
    xor ebx, ebx
.Lchapters_next:
    cmp ebx, esi
    jae .Lchapters_done
    mov ecx, ebx
    lea rdx, [rip + tag_line]
    call chapter_line
    lea rcx, [rip + tag_line]
    call print_text
    lea rcx, [rip + line_end]
    call print_text
    inc ebx
    jmp .Lchapters_next
.Lchapters_done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN print_chapters

LOCALFN print_number
    sub rsp, 56
    mov rax, rcx
    lea r9, [rip + number_buffer + 31]
    mov byte ptr [r9], 0
    mov r8d, 10
.Lnumber_digit:
    xor edx, edx
    div r8
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .Lnumber_digit
    mov rcx, r9
    call print_text
    add rsp, 56
    ret
ENDFN print_number

LOCALFN report_stats
    push rbp
    mov rbp, rsp
    sub rsp, 48
    call GetTickCount64
    sub rax, [rip + start_tick]
    mov [rip + elapsed_ms], rax
    call GetCurrentProcess
    mov rcx, rax
    lea rdx, [rip + creation_time]
    lea r8, [rip + exit_time]
    lea r9, [rip + kernel_time]
    lea rax, [rip + user_time]
    mov [rsp + 32], rax
    call GetProcessTimes
    mov rax, [rip + kernel_time]
    add rax, [rip + user_time]
    xor edx, edx
    mov ecx, 10
    div rcx
    mov [rip + cpu_us], rax
    lea rcx, [rip + stats_a]
    call print_text
    mov ecx, [rip + codec_kind]
    call print_number
    lea rcx, [rip + stats_b]
    call print_text
    mov ecx, [rip + queue_rate]
    call print_number
    lea rcx, [rip + stats_c]
    call print_text
    mov ecx, [rip + source_channels]
    call print_number
    lea rcx, [rip + stats_d]
    call print_text
    mov ecx, [rip + source_bits]
    call print_number
    lea rcx, [rip + stats_e]
    call print_text
    mov rcx, [rip + decoded_count]
    call print_number
    lea rcx, [rip + stats_f]
    call print_text
    mov rcx, [rip + underruns]
    call print_number
    lea rcx, [rip + stats_g]
    call print_text
    mov ecx, [rip + decode_error]
    call print_number
    lea rcx, [rip + stats_h]
    call print_text
    mov ecx, [rip + audio_hresult]
    call print_number
    lea rcx, [rip + stats_i]
    call print_text
    mov rcx, [rip + elapsed_ms]
    call print_number
    lea rcx, [rip + stats_j]
    call print_text
    mov rcx, [rip + cpu_us]
    call print_number
    lea rcx, [rip + stats_k]
    call print_text
    mov rcx, [rip + endpoint_dry]
    call print_number
    lea rcx, [rip + newline]
    call print_text
    leave
    ret
ENDFN report_stats

LOCALFN release_com
    sub rsp, 40
    mov rax, [rcx]
    mov qword ptr [rcx], 0
    mov rcx, rax
    test rcx, rcx
    jz .Lrelease_done
    mov rax, [rcx]
    call qword ptr [rax + 16]
.Lrelease_done:
    add rsp, 40
    ret
ENDFN release_com

LOCALFN close_pointer
    sub rsp, 40
    mov rax, [rcx]
    mov qword ptr [rcx], 0
    mov rcx, rax
    test rcx, rcx
    jz .Lclose_done
    call CloseHandle
.Lclose_done:
    add rsp, 40
    ret
ENDFN close_pointer

.include "resume_state.inc"

# -> EAX=the shared-mode mix rate of the endpoint playback opens
# (device_chosen or the default), 0 when it cannot be read.
LOCALFN audio_mix_rate
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    xor esi, esi                        # the rate
    xor ecx, ecx
    mov edx, 2                          # COINIT_APARTMENTTHREADED
    call CoInitializeEx
    mov ebx, eax
    lea rcx, [rip + clsid_enumerator]
    xor edx, edx
    mov r8d, 1
    lea r9, [rip + iid_enumerator]
    lea rax, [rip + devices_enum]
    mov [rsp + 32], rax
    call CoCreateInstance
    test eax, eax
    js .Lmix_release
    mov rcx, [rip + devices_enum]
    mov rdx, [rip + device_chosen]
    lea r8, [rip + device_item]
    test rdx, rdx
    jz .Lmix_default
    mov rax, [rcx]
    call qword ptr [rax + 40]           # GetDevice
    test eax, eax
    jns .Lmix_device
    mov rcx, [rip + devices_enum]
.Lmix_default:
    xor edx, edx
    xor r8d, r8d
    lea r9, [rip + device_item]
    mov rax, [rcx]
    call qword ptr [rax + 32]           # GetDefaultAudioEndpoint
    test eax, eax
    js .Lmix_release
.Lmix_device:
    mov rcx, [rip + device_item]
    lea rdx, [rip + iid_client]
    mov r8d, 1
    xor r9d, r9d
    lea rax, [rsp + 40]
    mov qword ptr [rax], 0
    mov [rsp + 32], rax
    mov rax, [rcx]
    call qword ptr [rax + 24]           # Activate an IAudioClient
    test eax, eax
    js .Lmix_release
    mov rcx, [rsp + 40]                 # the client
    lea rdx, [rsp + 32]                 # its mix format
    mov qword ptr [rdx], 0
    mov rax, [rcx]
    call qword ptr [rax + 64]           # GetMixFormat
    test eax, eax
    js .Lmix_client
    mov rcx, [rsp + 32]
    mov esi, [rcx + 4]                  # nSamplesPerSec
    call CoTaskMemFree
.Lmix_client:
    lea rcx, [rsp + 40]
    call release_com
.Lmix_release:
    lea rcx, [rip + device_item]
    call release_com
    lea rcx, [rip + devices_enum]
    call release_com
    test ebx, ebx
    js .Lmix_return
    call CoUninitialize
.Lmix_return:
    mov eax, esi
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN audio_mix_rate

# Active render endpoints, in the enumerator's order. ECX=0 prints each as
# "number<TAB>endpoint ID<TAB>friendly name" (UTF-8); ECX=1 finds the one
# whose ID, friendly name or number equals cli_device and makes it
# device_chosen; ECX=2 calls devices_callback with ECX=number, RDX=endpoint
# ID and R8=friendly name (or 0) for each. -> EAX=1; else reports the
# failure, exit code 3, EAX=0. Its own enumerator leaves a playing stream's
# alone.
FN audio_devices
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov r12d, ecx
    xor ecx, ecx
    mov edx, 2                          # COINIT_APARTMENTTHREADED
    call CoInitializeEx
    mov ebx, eax                        # uninitialize after a success
    lea rcx, [rip + clsid_enumerator]
    xor edx, edx
    mov r8d, 1
    lea r9, [rip + iid_enumerator]
    lea rax, [rip + devices_enum]
    mov [rsp + 32], rax
    call CoCreateInstance
    test eax, eax
    js .Ldevices_failed
    mov rcx, [rip + devices_enum]
    xor edx, edx                        # eRender
    mov r8d, 1                          # DEVICE_STATE_ACTIVE
    lea r9, [rip + device_collection]
    mov rax, [rcx]
    call qword ptr [rax + 24]           # EnumAudioEndpoints
    test eax, eax
    js .Ldevices_failed
    mov rcx, [rip + device_collection]
    lea rdx, [rsp + 48]
    mov rax, [rcx]
    call qword ptr [rax + 24]           # GetCount
    test eax, eax
    js .Ldevices_failed
    xor esi, esi                        # endpoint number
.Ldevices_next:
    cmp esi, [rsp + 48]
    jae .Ldevices_end
    mov rcx, [rip + device_collection]
    mov edx, esi
    lea r8, [rip + device_item]
    mov rax, [rcx]
    call qword ptr [rax + 32]           # Item
    test eax, eax
    js .Ldevices_skip
    mov rcx, [rip + device_item]
    lea rdx, [rip + device_string]
    mov rax, [rcx]
    call qword ptr [rax + 40]           # GetId
    test eax, eax
    js .Ldevices_release
    mov rcx, [rip + device_item]
    xor edx, edx                        # STGM_READ
    lea r8, [rip + device_store]
    mov rax, [rcx]
    call qword ptr [rax + 32]           # OpenPropertyStore
    test eax, eax
    js .Ldevices_free_id
    lea rdi, [rip + device_variant]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov rcx, [rip + device_store]
    lea rdx, [rip + pkey_friendly_name]
    mov r8, rdi
    mov rax, [rcx]
    call qword ptr [rax + 40]           # GetValue
    xor edi, edi                        # its name (VT_LPWSTR), or none
    test eax, eax
    js .Ldevices_named
    cmp word ptr [rip + device_variant], 31
    jne .Ldevices_named
    mov rdi, [rip + device_variant + 8]
.Ldevices_named:
    cmp r12d, 1
    je .Ldevices_match
    ja .Ldevices_callback
    mov ecx, esi                        # print it
    call print_number
    lea rcx, [rip + tab_text]
    call print_text
    mov rcx, [rip + device_string]
    call print_wide
    lea rcx, [rip + tab_text]
    call print_text
    test rdi, rdi
    jz .Ldevices_printed
    mov rcx, rdi
    call print_wide
.Ldevices_printed:
    lea rcx, [rip + line_end]
    call print_text
    jmp .Ldevices_close
.Ldevices_callback:
    mov ecx, esi
    mov rdx, [rip + device_string]
    mov r8, rdi
    call qword ptr [rip + devices_callback]
    jmp .Ldevices_close
.Ldevices_match:
    cmp qword ptr [rip + device_chosen], 0
    jne .Ldevices_close
    mov rcx, [rip + cli_device]
    mov rdx, [rip + device_string]
    call equal_wide
    test eax, eax
    jnz .Ldevices_chosen
    test rdi, rdi
    jz .Ldevices_number
    mov rcx, [rip + cli_device]
    mov rdx, rdi
    call equal_wide
    test eax, eax
    jnz .Ldevices_chosen
.Ldevices_number:
    mov rcx, [rip + cli_device]
    xor eax, eax
    xor edx, edx
.Ldevices_digit:
    movzx r8d, word ptr [rcx]
    test r8d, r8d
    jz .Ldevices_digits
    sub r8d, '0'
    cmp r8d, 9
    ja .Ldevices_close
    cmp eax, 100000
    jae .Ldevices_close
    imul eax, eax, 10
    add eax, r8d
    add rcx, 2
    inc edx
    jmp .Ldevices_digit
.Ldevices_digits:
    test edx, edx
    jz .Ldevices_close
    cmp eax, esi
    jne .Ldevices_close
.Ldevices_chosen:
    mov rcx, [rip + device_string]      # keep its ID
    lea rdx, [rip + device_id]
    xor eax, eax
.Ldevices_copy:
    movzx r8d, word ptr [rcx + rax*2]
    mov [rdx + rax*2], r8w
    test r8d, r8d
    jz .Ldevices_copied
    inc eax
    cmp eax, 511
    jb .Ldevices_copy
    jmp .Ldevices_close                 # too long to keep
.Ldevices_copied:
    mov [rip + device_chosen], rdx
.Ldevices_close:
    lea rcx, [rip + device_variant]
    call PropVariantClear
    lea rcx, [rip + device_store]
    call release_com
.Ldevices_free_id:
    mov rcx, [rip + device_string]
    call CoTaskMemFree
    mov qword ptr [rip + device_string], 0
.Ldevices_release:
    lea rcx, [rip + device_item]
    call release_com
.Ldevices_skip:
    inc esi
    jmp .Ldevices_next
.Ldevices_end:
    mov eax, 1
    cmp r12d, 1
    jne .Ldevices_done
    cmp qword ptr [rip + device_chosen], 0
    jne .Ldevices_done
    lea rcx, [rip + unknown_device]
    call print_text
    jmp .Ldevices_error
.Ldevices_failed:
    xor eax, eax
    cmp r12d, 2
    je .Ldevices_done                   # the window's menu: nothing to report
    lea rcx, [rip + devices_failed]
    call print_text
.Ldevices_error:
    mov dword ptr [rip + exit_code], 3
    xor eax, eax
.Ldevices_done:
    mov [rsp + 48], eax
    lea rcx, [rip + device_collection]
    call release_com
    lea rcx, [rip + devices_enum]
    call release_com
    test ebx, ebx
    js .Ldevices_return
    call CoUninitialize
.Ldevices_return:
    mov eax, [rsp + 48]
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN audio_devices

# RCX=wide text: written in UTF-8.
LOCALFN print_wide
    sub rsp, 72
    mov r8, rcx
    mov ecx, 65001                      # CP_UTF8
    xor edx, edx
    mov r9d, -1
    lea rax, [rip + device_text]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 1024
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jz .Lprint_wide_done
    lea rcx, [rip + device_text]
    call print_text
.Lprint_wide_done:
    add rsp, 72
    ret
ENDFN print_wide
