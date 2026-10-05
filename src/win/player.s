# LAMP original Windows x86-64 assembly playback engine. No CRT.
# Single producer / single consumer queue: x86 TSO publishes complete PCM
# before write_count; consumer publishes read_count after copying. Only the
# producer accesses the file/decoder. Render path has no locks or allocations.
.include "lamp.inc"
.globl engine_mode, engine_stop_requested
.globl engine_position, engine_seek_seconds, engine_volume, pause_requested
.globl engine_ready
.globl exit_code, underruns, endpoint_dry

.equ RING_FRAMES, 262144
.equ RING_MASK, RING_FRAMES - 1
.equ CHUNK_FRAMES, 2048

.data
usage: .ascii "LAMP 0.4.0-dev - Lev's Assembly Media Player"
.byte 13, 10
      .ascii "Handwritten x86-64 assembly: PCM, FLAC, ALAC, MP1/MP2/MP3, Vorbis, Opus"
      .byte 13, 10
      .ascii "in WAV, AIFF/AIFC, FLAC, MP3, Ogg, Matroska/WebM and MP4/MOV files."
      .byte 13, 10
      .ascii "Usage: lamp-cli.exe file.mp3"
      .byte 13, 10
      .ascii "       lamp-cli.exe --check file.flac"
      .byte 13, 10
      .ascii "       lamp-cli.exe --decode file.flac output.f32"
      .byte 13, 10
      .ascii "Playback: Space pauses/resumes; Q or Ctrl+C stops."
      .byte 13, 10
      .ascii "RIFF/RF64/BW64 WAV: 1..8 channels, PCM 8/16/24/32 or float32/64."
      .byte 13, 10
      .ascii "AIFF/AIFC: signed PCM 1..32 bits or float32/64, 1..8 channels."
      .byte 13, 10
      .ascii "Native FLAC: 4..32 bit, 1..8 channels, speaker-mask-aware downmix."
      .byte 13, 10
      .ascii "Opus families 0/1; playback and float export output stereo."
      .byte 13, 10, 0
open_error: .ascii "Unsupported, malformed, or inaccessible file. Supports WAV, AIFF/AIFC, FLAC, MP1/MP2/MP3, Ogg (Vorbis, Opus, FLAC), Matroska/WebM and MP4/MOV audio."
.byte 13, 10, 0
audio_error: .ascii "Audio endpoint unavailable or WASAPI failed. Try --check to verify decoding."
.byte 13, 10, 0
output_error: .ascii "Cannot create output file."
.byte 13, 10, 0
play_text: .ascii "Playing. Space: pause / resume. Q or Ctrl+C: stop."
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
operation: .long 0                  # 0 play, 1 check, 2 decode
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
ring_pcm: .zero RING_FRAMES*8
offline_pcm: .zero CHUNK_FRAMES*8
bytes_written: .zero 4
input_record: .zero 20
number_buffer: .zero 32

.text
# Called on a dedicated rendering thread by the native UI.
# The same producer/WASAPI engine backs the CLI and window.
FN engine_play
    sub rsp, 136
    mov dword ptr [rip + engine_mode], 1
    mov dword ptr [rip + operation], 0
    mov dword ptr [rip + exit_code], 0
    mov dword ptr [rip + producer_done], 0
    mov dword ptr [rip + engine_ready], 0
    mov dword ptr [rip + was_paused], 0
    mov dword ptr [rip + audio_hresult], 0
    mov qword ptr [rip + write_count], 0
    mov qword ptr [rip + read_count], 0
    mov qword ptr [rip + decoded_count], 0
    mov qword ptr [rip + underruns], 0
    mov qword ptr [rip + endpoint_dry], 0
    mov qword ptr [rip + engine_position], 0
    mov eax, [rip + engine_seek_seconds]
    mov [rip + engine_seek_frames], rax
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    call decoder_open
    test eax, eax
    jz bad_input
    mov eax, [rip + output_rate]
    mul qword ptr [rip + engine_seek_frames]
    cmp qword ptr [rip + output_frames], 0
    je .Lengine_seek_limit_ready
    cmp rax, [rip + output_frames]
    cmova rax, [rip + output_frames]
.Lengine_seek_limit_ready:
    mov [rip + engine_seek_frames], rax
    mov [rip + engine_position], rax
    cmp dword ptr [rip + engine_stop_requested], 0
    jne cleanup
    jmp start_playback
ENDFN engine_play
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
    cmp dword ptr [rip + argc], 2
    jb .Lshow_help
    mov rcx, [rax + 8]
    lea rdx, [rip + check_arg]
    call equal_wide
    test eax, eax
    jz .Ltry_decode
    cmp dword ptr [rip + argc], 3
    jne .Lshow_help
    mov dword ptr [rip + operation], 1
    mov rax, [rip + argv]
    mov rcx, [rax + 16]
    jmp .Lopen_input
.Ltry_decode:
    mov rax, [rip + argv]
    mov rcx, [rax + 8]
    lea rdx, [rip + decode_arg]
    call equal_wide
    test eax, eax
    jz .Lplay_args
    cmp dword ptr [rip + argc], 4
    jne .Lshow_help
    mov dword ptr [rip + operation], 2
    mov rax, [rip + argv]
    mov rcx, [rax + 24]
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
    mov rax, [rip + argv]
    mov rcx, [rax + 16]
    jmp .Lopen_input
.Lplay_args:
    cmp dword ptr [rip + argc], 2
    jne .Lshow_help
    mov rax, [rip + argv]
    mov rcx, [rax + 8]
.Lopen_input:
    lea rax, [rip + engine_stop_requested]
    mov [rip + ogg_cancel_ptr], rax
    call decoder_open
    test eax, eax
    jz bad_input
    cmp dword ptr [rip + operation], 0
    je start_playback
.Loffline_loop:
    lea rcx, [rip + offline_pcm]
    mov edx, CHUNK_FRAMES
    call decoder_read
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
    cmp dword ptr [rip + decode_error], 0
    jne .Ldecoding_failed
    mov rax, [rip + output_frames]
    test rax, rax
    jz .Lreport_finish
    cmp rax, [rip + decoded_count]
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
    xor edx, edx
    xor r8d, r8d
    lea r9, [rip + device_obj]
    mov rax, [rcx]
    call qword ptr [rax + 32]
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
    js .Lbad_audio
    mov eax, [rip + output_rate]
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
    js .Lbad_audio
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
    mov eax, [rip + output_rate]
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
    lea rcx, [rip + play_text]
    call print_text
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
    mov [rip + console_original_mode], eax
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
    je .Lplayback_stopped
    jmp .Laudio_wait
.Laudio_more:
    call fill_render
    cmp dword ptr [rip + audio_hresult], 0
    jne .Lbad_audio_saved
    jmp .Laudio_wait
.Lbad_audio_timeout:
    mov eax, 0x800705b4
.Lbad_audio:
    mov [rip + audio_hresult], eax
.Lbad_audio_saved:
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
    cmp dword ptr [rip + engine_mode], 0
    je .Lproducer_loop
    mov rcx, [rip + engine_seek_frames]
    call decoder_seek
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
    call decoder_read
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
    call decoder_read
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
.Lproducer_eof:
    mov rax, [rip + output_frames]
    test rax, rax
    jz .Lproducer_exit
    cmp rax, [rip + decoded_count]
    je .Lproducer_exit
    mov dword ptr [rip + decode_error], 5
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
    cmp word ptr [rip + input_record + 10], 0x20
    je .Lkeyboard_pause
    cmp word ptr [rip + input_record + 10], 0x51
    jne .Lkeyboard_wait
    mov rcx, [rip + stop_event]
    call SetEvent
    jmp .Lkeyboard_exit
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

LOCALFN ctrl_handler
    sub rsp, 40
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
    mov ecx, [rip + output_rate]
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
