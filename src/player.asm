; LAMP original Windows x86-64 assembly playback engine. No CRT.
; Single producer / single consumer queue: x86 TSO publishes complete PCM
; before write_count; consumer publishes read_count after copying. Only the
; producer accesses the file/decoder. Render path has no locks or allocations.
option casemap:none
EXTERN GetCommandLineW:PROC, CommandLineToArgvW:PROC, LocalFree:PROC
EXTERN GetStdHandle:PROC, WriteFile:PROC, ExitProcess:PROC
EXTERN CreateFileW:PROC, CloseHandle:PROC
EXTERN CreateEventW:PROC, SetEvent:PROC, CreateThread:PROC
EXTERN WaitForSingleObject:PROC, WaitForMultipleObjects:PROC
EXTERN SetConsoleCtrlHandler:PROC, GetCurrentThread:PROC
EXTERN GetConsoleMode:PROC, ReadConsoleInputW:PROC, SetConsoleMode:PROC
EXTERN GetCurrentProcess:PROC, GetProcessTimes:PROC, GetTickCount64:PROC
EXTERN CoInitializeEx:PROC, CoUninitialize:PROC, CoCreateInstance:PROC
EXTERN AvSetMmThreadCharacteristicsW:PROC, AvRevertMmThreadCharacteristics:PROC
EXTERN decoder_open:PROC, decoder_read:PROC, decoder_close:PROC
EXTERN decoder_seek:PROC
EXTERN sample_rate:DWORD, source_channels:DWORD, source_bits:DWORD
EXTERN decode_error:DWORD, total_frames:QWORD, codec_kind:DWORD
EXTERN ogg_cancel_ptr:QWORD
PUBLIC start
PUBLIC engine_play, engine_stop, engine_pause, engine_mode, engine_stop_requested
PUBLIC engine_position, engine_seek_seconds, engine_volume, pause_requested
PUBLIC engine_ready
PUBLIC exit_code, underruns, endpoint_dry

RING_FRAMES EQU 262144
RING_MASK EQU RING_FRAMES-1
CHUNK_FRAMES EQU 2048

.data
usage db "LAMP 0.4.0-dev - Lev's Assembly Media Player",13,10
      db 'Handwritten x86-64 assembly WAV / FLAC / MP3 / Ogg Vorbis / Opus',13,10
      db 'Usage: lamp-cli.exe file.mp3',13,10
      db '       lamp-cli.exe --check file.flac',13,10
      db '       lamp-cli.exe --decode file.flac output.f32',13,10
      db 'Playback: Space pauses/resumes; Q or Ctrl+C stops.',13,10
      db 'WAV: PCM 8/16/24/32 or float32; FLAC: 4..24 bit; mono/stereo.',13,10,0
open_error db 'Unsupported, malformed, or inaccessible file. Supports WAV, native FLAC, MP3, Ogg Vorbis and Opus.',13,10,0
audio_error db 'Audio endpoint unavailable or WASAPI failed. Try --check to verify decoding.',13,10,0
output_error db 'Cannot create output file.',13,10,0
play_text db 'Playing. Space: pause / resume. Q or Ctrl+C: stop.',13,10,0
stats_a db 'codec=',0
stats_b db ' rate=',0
stats_c db ' channels=',0
stats_d db ' bits=',0
stats_e db ' frames=',0
stats_f db ' underruns=',0
stats_g db ' decode_error=',0
stats_h db ' audio_error=',0
stats_i db ' elapsed_ms=',0
stats_j db ' cpu_us=',0
stats_k db ' endpoint_dry=',0
newline db 13,10,0
check_arg dw '-','-','c','h','e','c','k',0
decode_arg dw '-','-','d','e','c','o','d','e',0
audio_task dw 'A','u','d','i','o',0
clsid_enumerator dd 0bcde0395h
    dw 0e52fh,467ch
    db 8eh,3dh,0c4h,57h,92h,91h,69h,2eh
iid_enumerator dd 0a95664d2h
    dw 9614h,4f35h
    db 0a7h,46h,0deh,8dh,0b6h,36h,17h,0e6h
iid_client dd 01cb9ad4ch
    dw 0dbfah,4c32h
    db 0b1h,78h,0c2h,0f5h,68h,0a7h,3h,0b2h
iid_render dd 0f294acfch
    dw 3146h,4483h
    db 0a7h,0bfh,0adh,0dch,0a7h,0c2h,60h,0e2h
wavefmt dw 3,2
    dd 48000,384000
    dw 8,32,0
stdout dq 0
stdin dq 0
output_file dq -1
argv dq 0
argc dd 0
operation dd 0                  ; 0 play, 1 check, 2 decode
exit_code dd 0
stop_event dq 0
data_event dq 0
space_event dq 0
audio_event dq 0
producer_thread dq 0
control_thread dq 0
ALIGN 16
write_count dq 0
    dq 7 dup (0)
read_count dq 0
    dq 7 dup (0)
decoded_count dq 0
underruns dq 0
endpoint_dry dq 0
producer_done dd 0
pause_requested dd 0
was_paused dd 0
audio_hresult dd 0
enum_obj dq 0
device_obj dq 0
client_obj dq 0
render_obj dq 0
mmcss dq 0
task_index dd 0
buffer_frames dd 0
padding dd 0
render_frames dd 0
render_bytes dd 0
render_buffer dq 0
prebuffer_frames dd 0
console_mode dd 0
console_original_mode dd 0
console_changed dd 0
com_initialized dd 0
events dq 0,0
start_tick dq 0
elapsed_ms dq 0
cpu_us dq 0
creation_time dq 0
exit_time dq 0
kernel_time dq 0
user_time dq 0
engine_mode dd 0
engine_stop_requested dd 0
engine_position dq 0
engine_seek_seconds dd 0
engine_ready dd 0
engine_seek_frames dq 0
engine_volume real4 1.0

.data?
ring_pcm dq RING_FRAMES dup (?)
offline_pcm dq CHUNK_FRAMES dup (?)
bytes_written dd ?
input_record db 20 dup (?)
number_buffer db 32 dup (?)

.code
; Called on a dedicated rendering thread by the native UI.
; The same producer/WASAPI engine backs the CLI and window.
engine_play PROC
    sub rsp,136
    mov dword ptr [engine_mode],1
    mov dword ptr [operation],0
    mov dword ptr [exit_code],0
    mov dword ptr [producer_done],0
    mov dword ptr [engine_ready],0
    mov dword ptr [was_paused],0
    mov dword ptr [audio_hresult],0
    mov qword ptr [write_count],0
    mov qword ptr [read_count],0
    mov qword ptr [decoded_count],0
    mov qword ptr [underruns],0
    mov qword ptr [endpoint_dry],0
    mov qword ptr [engine_position],0
    mov eax,[engine_seek_seconds]
    mov [engine_seek_frames],rax
    lea rax,engine_stop_requested
    mov [ogg_cancel_ptr],rax
    call decoder_open
    test eax,eax
    jz bad_input
    mov eax,[sample_rate]
    mul qword ptr [engine_seek_frames]
    cmp qword ptr [total_frames],0
    je engine_seek_limit_ready
    cmp rax,[total_frames]
    cmova rax,[total_frames]
engine_seek_limit_ready:
    mov [engine_seek_frames],rax
    mov [engine_position],rax
    cmp dword ptr [engine_stop_requested],0
    jne cleanup
    jmp start_playback
engine_play ENDP
engine_stop PROC
    sub rsp,40
    mov dword ptr [engine_stop_requested],1
    mov rcx,[stop_event]
    test rcx,rcx
    jz engine_stop_done
    call SetEvent
engine_stop_done:
    add rsp,40
    ret
engine_stop ENDP
engine_pause PROC
    sub rsp,40
    xor dword ptr [pause_requested],1
    mov rcx,[audio_event]
    test rcx,rcx
    jz engine_pause_done
    call SetEvent
engine_pause_done:
    add rsp,40
    ret
engine_pause ENDP
start PROC
    sub rsp,136                ; entry RSP is 8 mod16 -> aligned for calls
    mov ecx,-11
    call GetStdHandle
    mov [stdout],rax
    call GetTickCount64
    mov [start_tick],rax
    call GetCommandLineW
    mov rcx,rax
    lea rdx,argc
    call CommandLineToArgvW
    mov [argv],rax
    test rax,rax
    jz show_help
    cmp dword ptr [argc],2
    jb show_help
    mov rcx,[rax+8]
    lea rdx,check_arg
    call equal_wide
    test eax,eax
    jz try_decode
    cmp dword ptr [argc],3
    jne show_help
    mov dword ptr [operation],1
    mov rax,[argv]
    mov rcx,[rax+16]
    jmp open_input
try_decode:
    mov rax,[argv]
    mov rcx,[rax+8]
    lea rdx,decode_arg
    call equal_wide
    test eax,eax
    jz play_args
    cmp dword ptr [argc],4
    jne show_help
    mov dword ptr [operation],2
    mov rax,[argv]
    mov rcx,[rax+24]
    mov edx,40000000h
    xor r8d,r8d
    xor r9d,r9d
    mov qword ptr [rsp+32],1 ; CREATE_NEW: never truncate existing output
    mov qword ptr [rsp+40],80h
    mov qword ptr [rsp+48],0
    call CreateFileW
    mov [output_file],rax
    cmp rax,-1
    je bad_output
    mov rax,[argv]
    mov rcx,[rax+16]
    jmp open_input
play_args:
    cmp dword ptr [argc],2
    jne show_help
    mov rax,[argv]
    mov rcx,[rax+8]
open_input:
    lea rax,engine_stop_requested
    mov [ogg_cancel_ptr],rax
    call decoder_open
    test eax,eax
    jz bad_input
    cmp dword ptr [operation],0
    je start_playback
offline_loop:
    lea rcx,offline_pcm
    mov edx,CHUNK_FRAMES
    call decoder_read
    test eax,eax
    jz offline_finished
    add [decoded_count],rax
    cmp dword ptr [operation],2
    jne offline_loop
    shl eax,3
    mov [render_bytes],eax
    mov rcx,[output_file]
    lea rdx,offline_pcm
    mov r8d,eax
    lea r9,bytes_written
    mov qword ptr [rsp+32],0
    call WriteFile
    test eax,eax
    jz bad_output
    mov eax,[bytes_written]
    cmp eax,[render_bytes]
    jne bad_output
    jmp offline_loop
offline_finished:
    cmp dword ptr [decode_error],0
    jne decoding_failed
    mov rax,[total_frames]
    test rax,rax
    jz report_finish
    cmp rax,[decoded_count]
    jne decoding_failed
    jmp report_finish
decoding_failed:
    mov dword ptr [exit_code],2
    jmp report_finish
start_playback::
    xor ecx,ecx
    mov edx,1
    xor r8d,r8d
    xor r9d,r9d
    call CreateEventW
    mov [stop_event],rax
    test rax,rax
    jz bad_audio
    xor ecx,ecx
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    call CreateEventW
    mov [data_event],rax
    test rax,rax
    jz bad_audio
    xor ecx,ecx
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    call CreateEventW
    mov [space_event],rax
    test rax,rax
    jz bad_audio
    xor ecx,ecx
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    call CreateEventW
    mov [audio_event],rax
    test rax,rax
    jz bad_audio
    cmp dword ptr [engine_mode],0
    jne skip_console_handler
    lea rcx,ctrl_handler
    mov edx,1
    call SetConsoleCtrlHandler
skip_console_handler:
    cmp dword ptr [engine_stop_requested],0
    je audio_start_not_cancelled
    mov rcx,[stop_event]
    call SetEvent
    jmp playback_stopped
audio_start_not_cancelled:
    xor ecx,ecx
    mov edx,2                 ; COINIT_APARTMENTTHREADED for initial IAudioClient
    call CoInitializeEx
    test eax,eax
    js bad_audio
    mov dword ptr [com_initialized],1
    lea rcx,clsid_enumerator
    xor edx,edx
    mov r8d,1
    lea r9,iid_enumerator
    lea rax,enum_obj
    mov [rsp+32],rax
    call CoCreateInstance
    test eax,eax
    js bad_audio
    mov rcx,[enum_obj]
    xor edx,edx
    xor r8d,r8d
    lea r9,device_obj
    mov rax,[rcx]
    call qword ptr [rax+32]
    test eax,eax
    js bad_audio
    mov rcx,[device_obj]
    lea rdx,iid_client
    mov r8d,1
    xor r9d,r9d
    lea rax,client_obj
    mov [rsp+32],rax
    mov rax,[rcx]
    call qword ptr [rax+24]
    test eax,eax
    js bad_audio
    mov eax,[sample_rate]
    mov dword ptr [wavefmt+4],eax
    shl eax,3
    mov dword ptr [wavefmt+8],eax
    mov rcx,[client_obj]
    xor edx,edx
    mov r8d,88040000h         ; AUTOCONVERTPCM | SRC_DEFAULT_QUALITY | EVENTCALLBACK
    mov r9d,2000000          ; 200 ms render buffer; favor robustness over latency
    mov qword ptr [rsp+32],0
    lea rax,wavefmt
    mov [rsp+40],rax
    mov qword ptr [rsp+48],0
    mov rax,[rcx]
    call qword ptr [rax+24]
    test eax,eax
    js bad_audio
    mov rcx,[client_obj]
    lea rdx,buffer_frames
    mov rax,[rcx]
    call qword ptr [rax+32]
    test eax,eax
    js bad_audio
    mov rcx,[client_obj]
    mov rdx,[audio_event]
    mov rax,[rcx]
    call qword ptr [rax+104]
    test eax,eax
    js bad_audio
    mov rcx,[client_obj]
    lea rdx,iid_render
    lea r8,render_obj
    mov rax,[rcx]
    call qword ptr [rax+112]
    test eax,eax
    js bad_audio
    ; Start decoder worker before joining MMCSS on this rendering thread.
    xor ecx,ecx
    xor edx,edx
    lea r8,producer
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateThread
    mov [producer_thread],rax
    test rax,rax
    jz bad_audio
    mov eax,[sample_rate]
    mov ecx,3
    mul ecx
    shr eax,2
    cmp eax,RING_FRAMES/2
    jbe prebuffer_set
    mov eax,RING_FRAMES/2
prebuffer_set:
    mov [prebuffer_frames],eax
    mov rax,[stop_event]
    mov [events],rax
    mov rax,[data_event]
    mov [events+8],rax
prebuffer_wait:
    mov rax,[write_count]
    cmp eax,[prebuffer_frames]
    jae prebuffer_ready
    cmp dword ptr [producer_done],0
    jne prebuffer_ready
    mov ecx,2
    lea rdx,events
    xor r8d,r8d
    mov r9d,-1
    call WaitForMultipleObjects
    cmp eax,1
    je prebuffer_wait
    jmp playback_stopped
prebuffer_ready:
    mov dword ptr [engine_ready],1
    cmp qword ptr [write_count],0
    je playback_stopped
    lea rcx,audio_task
    lea rdx,task_index
    call AvSetMmThreadCharacteristicsW
    mov [mmcss],rax
    cmp dword ptr [engine_mode],0
    jne no_keyboard
    lea rcx,play_text
    call print_text
    ; Keyboard thread waits on input or stop; no periodic polling.
    mov ecx,-10
    call GetStdHandle
    mov [stdin],rax
    mov rcx,rax
    lea rdx,console_mode
    call GetConsoleMode
    test eax,eax
    jz no_keyboard
    mov eax,[console_mode]
    mov [console_original_mode],eax
    and eax,0ffffffbfh       ; disable QuickEdit so selecting console won't hang audio
    or eax,80h
    mov rcx,[stdin]
    mov edx,eax
    call SetConsoleMode
    test eax,eax
    jz no_keyboard
    mov dword ptr [console_changed],1
    xor ecx,ecx
    xor edx,edx
    lea r8,keyboard
    xor r9d,r9d
    mov qword ptr [rsp+32],0
    mov qword ptr [rsp+40],0
    call CreateThread
    mov [control_thread],rax
no_keyboard:
    call fill_render
    cmp dword ptr [audio_hresult],0
    jne bad_audio_saved
    mov rax,[audio_event]
    mov [events+8],rax
    cmp dword ptr [pause_requested],0
    je initial_audio_start
    ; A seek while paused must never start the new endpoint before resume.
    mov dword ptr [was_paused],1
    jmp pause_wait
initial_audio_start:
    mov rcx,[client_obj]
    mov rax,[rcx]
    call qword ptr [rax+80]
    test eax,eax
    js bad_audio
audio_wait:
    mov ecx,2
    lea rdx,events
    xor r8d,r8d
    mov r9d,2000
    call WaitForMultipleObjects
    cmp eax,0
    je playback_stopped
    cmp eax,1
    jne bad_audio_timeout
    cmp dword ptr [pause_requested],0
    je resume_check
    cmp dword ptr [was_paused],0
    jne pause_wait
    mov rcx,[client_obj]
    mov rax,[rcx]
    call qword ptr [rax+88]
    test eax,eax
    js bad_audio
    mov dword ptr [was_paused],1
pause_wait:
    ; keyboard signals audio_event on each pause/resume, so wait has no polling.
    mov ecx,2
    lea rdx,events
    xor r8d,r8d
    mov r9d,-1
    call WaitForMultipleObjects
    test eax,eax
    jz playback_stopped
    jmp resume_check
resume_check:
    cmp dword ptr [pause_requested],0
    jne pause_wait
    cmp dword ptr [was_paused],0
    je audio_fill
    mov rcx,[client_obj]
    mov rax,[rcx]
    call qword ptr [rax+80]
    test eax,eax
    js bad_audio
    mov dword ptr [was_paused],0
audio_fill:
    ; At EOF, drain queued PCM and the endpoint padding before exiting.
    cmp dword ptr [producer_done],0
    je audio_more
    mov rax,[read_count]
    cmp rax,[write_count]
    jne audio_more
    mov rcx,[client_obj]
    lea rdx,padding
    mov rax,[rcx]
    call qword ptr [rax+48]
    test eax,eax
    js bad_audio
    cmp dword ptr [padding],0
    je playback_stopped
    jmp audio_wait
audio_more:
    call fill_render
    cmp dword ptr [audio_hresult],0
    jne bad_audio_saved
    jmp audio_wait
bad_audio_timeout:
    mov eax,800705b4h
bad_audio:
    mov [audio_hresult],eax
bad_audio_saved:
    mov dword ptr [exit_code],3
    lea rcx,audio_error
    call print_text
playback_stopped:
    mov rcx,[stop_event]
    test rcx,rcx
    jz stopped_no_event
    call SetEvent
stopped_no_event:
    mov rcx,[client_obj]
    test rcx,rcx
    jz stopped_no_client
    mov rax,[rcx]
    call qword ptr [rax+88]
stopped_no_client:
    mov rcx,[producer_thread]
    test rcx,rcx
    jz joined_producer
    mov edx,-1
    call WaitForSingleObject
joined_producer:
    mov rcx,[control_thread]
    test rcx,rcx
    jz joined_keyboard
    mov edx,-1
    call WaitForSingleObject
joined_keyboard:
    mov rcx,[mmcss]
    test rcx,rcx
    jz no_mmcss
    call AvRevertMmThreadCharacteristics
no_mmcss:
    mov qword ptr [mmcss],0
    cmp dword ptr [decode_error],0
    je report_finish
    mov dword ptr [exit_code],2
report_finish:
    call report_stats
    jmp cleanup
bad_input::
    cmp dword ptr [engine_stop_requested],0
    jne cleanup              ;cancelled open is a normal engine stop
    mov dword ptr [exit_code],2
    lea rcx,open_error
    call print_text
    jmp cleanup
bad_output:
    mov dword ptr [exit_code],4
    lea rcx,output_error
    call print_text
    jmp cleanup
show_help:
    lea rcx,usage
    call print_text
cleanup::
    call decoder_close
    cmp dword ptr [console_changed],0
    je cleanup_console
    mov rcx,[stdin]
    mov edx,[console_original_mode]
    call SetConsoleMode
cleanup_console:
    lea rcx,render_obj
    call release_com
    lea rcx,client_obj
    call release_com
    lea rcx,device_obj
    call release_com
    lea rcx,enum_obj
    call release_com
    cmp dword ptr [com_initialized],0
    je cleanup_no_com
    call CoUninitialize
cleanup_no_com:
    lea rcx,producer_thread
    call close_pointer
    lea rcx,control_thread
    call close_pointer
    lea rcx,stop_event
    call close_pointer
    lea rcx,data_event
    call close_pointer
    lea rcx,space_event
    call close_pointer
    lea rcx,audio_event
    call close_pointer
    mov rcx,[output_file]
    cmp rcx,-1
    je cleanup_args
    call CloseHandle
cleanup_args:
    mov rcx,[argv]
    mov qword ptr [argv],0
    test rcx,rcx
    jz exit_now
    call LocalFree
exit_now:
    cmp dword ptr [engine_mode],0
    je exit_console
    mov qword ptr [output_file],-1
    mov dword ptr [com_initialized],0
    mov eax,[exit_code]
    add rsp,136
    ret
exit_console:
    mov ecx,[exit_code]
    call ExitProcess
start ENDP

producer PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    sub rsp,64
    cmp dword ptr [engine_mode],0
    je producer_loop
    mov rcx,[engine_seek_frames]
    call decoder_seek
    mov [decoded_count],rax
producer_seek:
    mov rcx,[stop_event]
    xor edx,edx
    call WaitForSingleObject
    test eax,eax
    jz producer_exit
    mov rax,[engine_seek_frames]
    sub rax,[decoded_count]
    jbe producer_loop
    mov edx,CHUNK_FRAMES
    cmp rax,rdx
    cmovb edx,eax
    lea rcx,offline_pcm
    call decoder_read
    test eax,eax
    jz producer_eof
    add [decoded_count],rax
    jmp producer_seek
producer_loop:
    mov rcx,[stop_event]
    xor edx,edx
    call WaitForSingleObject
    test eax,eax
    jz producer_exit
    mov rbx,[write_count]
    mov rax,rbx
    sub rax,[read_count]
    cmp rax,RING_FRAMES
    jae producer_wait
    mov edx,RING_FRAMES
    sub edx,eax
    cmp edx,CHUNK_FRAMES
    jbe producer_chunk
    mov edx,CHUNK_FRAMES
producer_chunk:
    mov rsi,rbx
    and esi,RING_MASK
    mov eax,RING_FRAMES
    sub eax,esi
    cmp edx,eax
    jbe producer_contiguous
    mov edx,eax
producer_contiguous:
    lea rcx,ring_pcm
    lea rcx,[rcx+rsi*8]
    call decoder_read
    test eax,eax
    jz producer_eof
    add [decoded_count],rax
    add rbx,rax
    mov [write_count],rbx     ; publish after all float samples are written
    mov rcx,[data_event]
    call SetEvent
    jmp producer_loop
producer_wait:
    mov rax,[stop_event]
    mov [rsp+32],rax
    mov rax,[space_event]
    mov [rsp+40],rax
    mov ecx,2
    lea rdx,[rsp+32]
    xor r8d,r8d
    mov r9d,-1
    call WaitForMultipleObjects
    cmp eax,1
    je producer_loop
    jmp producer_exit
producer_eof:
    mov rax,[total_frames]
    test rax,rax
    jz producer_exit
    cmp rax,[decoded_count]
    je producer_exit
    mov dword ptr [decode_error],5
producer_exit:
    mov dword ptr [producer_done],1
    mov rcx,[data_event]
    call SetEvent
    xor eax,eax
    add rsp,64
    pop rsi
    pop rbx
    pop rbp
    ret
producer ENDP

fill_render PROC
    push rbp
    mov rbp,rsp
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp,48
    mov rcx,[client_obj]
    lea rdx,padding
    mov rax,[rcx]
    call qword ptr [rax+48]
    test eax,eax
    js fill_bad
    cmp dword ptr [padding],0
    jne fill_padding_ok
    cmp qword ptr [read_count],0
    je fill_padding_ok
    inc qword ptr [endpoint_dry] ; endpoint emptied before this refill
fill_padding_ok:
    mov rax,[read_count]
    mov edx,[padding]
    cmp rax,rdx
    jb fill_position_done
    sub rax,rdx
    add rax,[engine_seek_frames]
    mov [engine_position],rax
fill_position_done:
    mov eax,[buffer_frames]
    sub eax,[padding]
    jz fill_done
    mov rbx,[read_count]
    mov rdx,[write_count]
    sub rdx,rbx
    cmp rdx,rax
    jae fill_size
    ; EOF: submit only the real tail, then drain it without adding silence.
    cmp dword ptr [producer_done],0
    je fill_starved
    mov eax,edx
    test eax,eax
    jz fill_done
    jmp fill_size
fill_starved:
    inc qword ptr [underruns]
fill_size:
    mov [render_frames],eax
    mov r12d,eax
    mov rcx,[render_obj]
    mov edx,eax
    lea r8,render_buffer
    mov rax,[rcx]
    call qword ptr [rax+24]
    test eax,eax
    js fill_bad
    mov rdi,[render_buffer]
    mov rdx,[write_count]
    sub rdx,rbx
    cmp rdx,r12
    jbe fill_have
    mov rdx,r12
fill_have:
    mov [rsp+32],rdx
    mov r8,rdx
    and ebx,RING_MASK
    lea rsi,ring_pcm
    lea rsi,[rsi+rbx*8]
    mov ecx,RING_FRAMES
    sub ecx,ebx
    cmp rcx,rdx
    jbe copy_first
    mov rcx,rdx
copy_first:
    sub r8,rcx
    rep movsq
    mov rcx,r8
    lea rsi,ring_pcm
    rep movsq
    mov rcx,r12
    sub rcx,[rsp+32]
    xor eax,eax
    rep stosq                 ; explicit silence only on actual starvation
    cmp dword ptr [engine_volume],3f800000h
    je fill_volume_done
    movss xmm0,dword ptr [engine_volume]
    shufps xmm0,xmm0,0
    mov rdx,[render_buffer]
    mov ecx,[render_frames]
    shl ecx,1
fill_volume:
    cmp ecx,4
    jb fill_volume_tail
    movups xmm1,[rdx]
    mulps xmm1,xmm0
    movups [rdx],xmm1
    add rdx,16
    sub ecx,4
    jmp fill_volume
fill_volume_tail:
    test ecx,ecx
    jz fill_volume_done
    movss xmm1,dword ptr [rdx]
    mulss xmm1,xmm0
    movss dword ptr [rdx],xmm1
    add rdx,4
    dec ecx
    jmp fill_volume_tail
fill_volume_done:
    mov rcx,[render_obj]
    mov edx,[render_frames]
    xor r8d,r8d
    mov rax,[rcx]
    call qword ptr [rax+32]
    test eax,eax
    js fill_bad
    mov rax,[rsp+32]
    add [read_count],rax      ; publish consumed PCM after copy and ReleaseBuffer
    mov rcx,[space_event]
    call SetEvent
    jmp fill_done
fill_bad:
    mov [audio_hresult],eax
fill_done:
    add rsp,48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
fill_render ENDP

keyboard PROC
    push rbp
    mov rbp,rsp
    sub rsp,64
    mov rax,[stop_event]
    mov [rsp+32],rax
    mov rax,[stdin]
    mov [rsp+40],rax
keyboard_wait:
    mov ecx,2
    lea rdx,[rsp+32]
    xor r8d,r8d
    mov r9d,-1
    call WaitForMultipleObjects
    cmp eax,1
    jne keyboard_exit
    mov rcx,[stdin]
    lea rdx,input_record
    mov r8d,1
    lea r9,bytes_written
    call ReadConsoleInputW
    test eax,eax
    jz keyboard_exit
    cmp word ptr [input_record],1
    jne keyboard_wait
    cmp dword ptr [input_record+4],0
    je keyboard_wait
    cmp word ptr [input_record+10],20h
    je keyboard_pause
    cmp word ptr [input_record+10],51h
    jne keyboard_wait
    mov rcx,[stop_event]
    call SetEvent
    jmp keyboard_exit
keyboard_pause:
    xor dword ptr [pause_requested],1
    mov rcx,[audio_event]
    call SetEvent
    jmp keyboard_wait
keyboard_exit:
    xor eax,eax
    leave
    ret
keyboard ENDP

ctrl_handler PROC
    sub rsp,40
    mov rcx,[stop_event]
    test rcx,rcx
    jz ctrl_done
    call SetEvent
ctrl_done:
    mov eax,1
    add rsp,40
    ret
ctrl_handler ENDP

equal_wide PROC
equal_loop:
    movzx eax,word ptr [rcx]
    cmp ax,[rdx]
    jne equal_no
    add rcx,2
    add rdx,2
    test eax,eax
    jnz equal_loop
    mov eax,1
    ret
equal_no:
    xor eax,eax
    ret
equal_wide ENDP

print_text PROC
    cmp dword ptr [engine_mode],0
    je print_console_text
    ret
print_console_text:
    sub rsp,56
    mov rdx,rcx
    xor r8d,r8d
text_length:
    cmp byte ptr [rdx+r8],0
    je text_write
    inc r8d
    jmp text_length
text_write:
    mov rcx,[stdout]
    lea r9,bytes_written
    mov qword ptr [rsp+32],0
    call WriteFile
    add rsp,56
    ret
print_text ENDP

print_number PROC
    sub rsp,56
    mov rax,rcx
    lea r9,number_buffer+31
    mov byte ptr [r9],0
    mov r8d,10
number_digit:
    xor edx,edx
    div r8
    add dl,'0'
    dec r9
    mov [r9],dl
    test rax,rax
    jnz number_digit
    mov rcx,r9
    call print_text
    add rsp,56
    ret
print_number ENDP

report_stats PROC
    push rbp
    mov rbp,rsp
    sub rsp,48
    call GetTickCount64
    sub rax,[start_tick]
    mov [elapsed_ms],rax
    call GetCurrentProcess
    mov rcx,rax
    lea rdx,creation_time
    lea r8,exit_time
    lea r9,kernel_time
    lea rax,user_time
    mov [rsp+32],rax
    call GetProcessTimes
    mov rax,[kernel_time]
    add rax,[user_time]
    xor edx,edx
    mov ecx,10
    div rcx
    mov [cpu_us],rax
    lea rcx,stats_a
    call print_text
    mov ecx,[codec_kind]
    call print_number
    lea rcx,stats_b
    call print_text
    mov ecx,[sample_rate]
    call print_number
    lea rcx,stats_c
    call print_text
    mov ecx,[source_channels]
    call print_number
    lea rcx,stats_d
    call print_text
    mov ecx,[source_bits]
    call print_number
    lea rcx,stats_e
    call print_text
    mov rcx,[decoded_count]
    call print_number
    lea rcx,stats_f
    call print_text
    mov rcx,[underruns]
    call print_number
    lea rcx,stats_g
    call print_text
    mov ecx,[decode_error]
    call print_number
    lea rcx,stats_h
    call print_text
    mov ecx,[audio_hresult]
    call print_number
    lea rcx,stats_i
    call print_text
    mov rcx,[elapsed_ms]
    call print_number
    lea rcx,stats_j
    call print_text
    mov rcx,[cpu_us]
    call print_number
    lea rcx,stats_k
    call print_text
    mov rcx,[endpoint_dry]
    call print_number
    lea rcx,newline
    call print_text
    leave
    ret
report_stats ENDP

release_com PROC
    sub rsp,40
    mov rax,[rcx]
    mov qword ptr [rcx],0
    mov rcx,rax
    test rcx,rcx
    jz release_done
    mov rax,[rcx]
    call qword ptr [rax+16]
release_done:
    add rsp,40
    ret
release_com ENDP

close_pointer PROC
    sub rsp,40
    mov rax,[rcx]
    mov qword ptr [rcx],0
    mov rcx,rax
    test rcx,rcx
    jz close_done
    call CloseHandle
close_done:
    add rsp,40
    ret
close_pointer ENDP
END
