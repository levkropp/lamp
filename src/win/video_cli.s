# Original Windows H.264 I/P playback/check/export. No CRT/external decoder.
.include "lamp.inc"
.include "h264.inc"
.include "video.inc"
RODATA
vc_check: .short '-','-','v','i','d','e','o','-','c','h','e','c','k',0
vc_decode: .short '-','-','v','i','d','e','o','-','d','e','c','o','d','e',0
vc_play: .short '-','-','v','i','d','e','o','-','p','l','a','y',0
vc_usage: .asciz "Usage: --video-play file.h264 | --video-check file.h264 | --video-decode file.h264 output.nv12\r\n"
vc_input_error: .asciz "Unsupported, malformed or inaccessible H.264 file.\r\n"
vc_gpu_error: .asciz "H.264 hardware decode failed or timed out on this adapter.\r\n"
vc_output_error: .asciz "Cannot create or write video output; existing files are preserved.\r\n"
vc_cancel_error: .asciz "Video operation cancelled.\r\n"
vc_stat: .asciz "video=h264 backend=d3d11 format=nv12 width="
vc_height: .asciz " height="
vc_coded_w: .asciz " coded_width="
vc_coded_h: .asciz " coded_height="
vc_frames_text: .asciz " frames="
vc_newline: .asciz "\r\n"
.data
vc_view: .quad 0
vc_size: .quad 0
vc_token: .quad 0
vc_pixels: .quad 0
vc_capacity: .quad 0
vc_output: .quad -1
vc_output_path: .quad 0
vc_count: .quad 0
vc_cancel: .long 0
vc_written: .long 0
.bss
.p2align 6
vc_parser: .zero HP_BYTES
vc_gpu: .zero WV_BYTES
vc_play_info: .zero 56
.text

# RCX=argv, EDX=argc ->-1 not video, otherwise process exit code0/1/2.
FN win_video_cli
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 64
    mov rbx, rcx
    mov ebp, edx
    cmp ebp, 2
    jb .Lvc_not_video
    mov rcx, [rbx+8]
    lea rdx, [rip+vc_check]
    call equal_wide
    mov esi, 3
    test eax, eax
    jnz .Lvc_mode
    mov rcx, [rbx+8]
    lea rdx, [rip+vc_decode]
    call equal_wide
    test eax, eax
    jnz .Lvc_decode_mode
    mov rcx, [rbx+8]
    lea rdx, [rip+vc_play]
    call equal_wide
    test eax, eax
    jz .Lvc_not_video
    mov esi, 5
    cmp ebp, 3
    jne .Lvc_bad_usage
    jmp .Lvc_initialize
.Lvc_decode_mode:
    mov esi, 4
.Lvc_mode:
    cmp ebp, esi
    jne .Lvc_bad_usage
.Lvc_initialize:
    mov dword ptr [rip+vc_cancel], 0
    mov qword ptr [rip+vc_output], -1
    mov qword ptr [rip+vc_output_path], 0
    mov qword ptr [rip+vc_count], 0
    cmp esi, 4
    jne .Lvc_handler
    mov rax, [rbx+24]
    mov [rip+vc_output_path], rax
.Lvc_handler:
    lea rcx, [rip+vc_control]
    mov edx, 1
    call SetConsoleCtrlHandler
    mov rcx, [rbx+16]
    call file_map
    mov [rip+vc_view], rax
    test rax, rax
    jz .Lvc_input_error
    mov [rip+vc_size], rdx
    mov [rip+vc_token], r8
    call vc_open_parser
    test eax, eax
    jz .Lvc_input_error
    # Complete header/framing preflight before creating an output file.
.Lvc_preflight:
    lea rcx, [rip+vc_parser]
    call h264_next
    test eax, eax
    js .Lvc_input_error
    jnz .Lvc_preflight
    lea rax, [rip+vc_parser]
    mov rdx, [rax+HP_FRAMES]
    mov [rip+vc_count], rdx
    lea rcx, [rip+vc_gpu]
    mov edx, [rax+HP_WIDTH]
    mov r8d, [rax+HP_HEIGHT]
    mov r9d, [rax+HP_REFS]
    call win_video_open_refs
    test eax, eax
    js .Lvc_gpu_error
    cmp esi, 5
    je .Lvc_play_window
    lea rax, [rip+vc_parser]
    mov ecx, [rax+HP_WIDTH]
    imul ecx, [rax+HP_HEIGHT]
    lea ecx, [rcx+rcx*2]
    shr ecx, 1
    mov [rip+vc_capacity], rcx
    call mem_alloc
    mov [rip+vc_pixels], rax
    test rax, rax
    jz .Lvc_gpu_error
    lea rcx, [rip+vc_parser]
    call h264_close
    call vc_open_parser
    test eax, eax
    jz .Lvc_input_error
    mov rcx, [rip+vc_output_path]
    test rcx, rcx
    jz .Lvc_next
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+32], 1 # CREATE_NEW
    mov qword ptr [rsp+40], 0x80
    mov qword ptr [rsp+48], 0
    call CreateFileW
    mov [rip+vc_output], rax
    cmp rax, -1
    je .Lvc_output_error
.Lvc_next:
    lea rcx, [rip+vc_parser]
    call h264_next
    test eax, eax
    js .Lvc_input_error
    jz .Lvc_success
    call GetTickCount64
    lea r12, [rax+5000]
.Lvc_decode_try:
    cmp dword ptr [rip+vc_cancel], 0
    jne .Lvc_cancelled
    lea rcx, [rip+vc_gpu]
    lea rdx, [rip+vc_parser+HP_DESC]
    call win_video_decode
    cmp eax, WV_PENDING
    jne .Lvc_decoded
    call vc_wait
    test eax, eax
    jz .Lvc_gpu_error
    jmp .Lvc_decode_try
.Lvc_decoded:
    test eax, eax
    js .Lvc_gpu_error
    call GetTickCount64
    lea r12, [rax+5000]
.Lvc_read_try:
    cmp dword ptr [rip+vc_cancel], 0
    jne .Lvc_cancelled
    lea rcx, [rip+vc_gpu]
    mov rdx, [rip+vc_pixels]
    mov r8, [rip+vc_capacity]
    call win_video_readback
    cmp eax, WV_PENDING
    jne .Lvc_read_done
    call vc_wait
    test eax, eax
    jz .Lvc_gpu_error
    jmp .Lvc_read_try
.Lvc_read_done:
    test eax, eax
    js .Lvc_gpu_error
    cmp qword ptr [rip+vc_output], -1
    je .Lvc_next
    call vc_crop
    mov r8d, eax
    mov [rsp+56], eax
    mov rcx, [rip+vc_output]
    mov rdx, [rip+vc_pixels]
    lea r9, [rip+vc_written]
    mov qword ptr [rsp+32], 0
    call WriteFile
    test eax, eax
    jz .Lvc_output_error
    mov eax, [rsp+56]
    cmp eax, [rip+vc_written]
    jne .Lvc_output_error
    jmp .Lvc_next
.Lvc_play_window:
    mov rcx, -4              # Per-monitor V2 awareness for this CLI process.
    call SetProcessDpiAwarenessContext
    lea r8, [rip+vc_play_info]
    mov rax, [rip+vc_view]
    mov [r8], rax
    mov rax, [rip+vc_size]
    mov [r8+8], rax
    lea rax, [rip+vc_cancel]
    mov [r8+16], rax
    mov rax, [rip+vc_count]
    mov [r8+24], rax
    mov dword ptr [r8+32], 1
    # No event: the window checks the Ctrl+C flag at most every250ms at rest.
    lea rcx, [rip+vc_gpu]
    lea rdx, [rip+vc_parser]
    call win_video_play
    cmp dword ptr [rip+vc_cancel], 0
    jne .Lvc_cancelled
    test eax, eax
    js .Lvc_gpu_error
    xor ebp, ebp
    jmp .Lvc_cleanup
.Lvc_success:
    lea rbx, [rip+vc_parser]
    mov rax, [rbx+HP_FRAMES]
    cmp rax, [rip+vc_count]
    jne .Lvc_input_error
    lea rcx, [rip+vc_stat]
    call print_text
    mov ecx, [rbx+HP_VISIBLE_W]
    call print_number
    lea rcx, [rip+vc_height]
    call print_text
    mov ecx, [rbx+HP_VISIBLE_H]
    call print_number
    lea rcx, [rip+vc_coded_w]
    call print_text
    mov ecx, [rbx+HP_WIDTH]
    call print_number
    lea rcx, [rip+vc_coded_h]
    call print_text
    mov ecx, [rbx+HP_HEIGHT]
    call print_number
    lea rcx, [rip+vc_frames_text]
    call print_text
    mov rcx, [rbx+HP_FRAMES]
    call print_number
    lea rcx, [rip+vc_newline]
    call print_text
    xor ebp, ebp
    jmp .Lvc_cleanup
.Lvc_input_error:
    cmp dword ptr [rip+vc_cancel], 0
    jne .Lvc_cancelled
    lea rcx, [rip+vc_input_error]
    jmp .Lvc_failed
.Lvc_gpu_error:
    lea rcx, [rip+vc_gpu_error]
    jmp .Lvc_failed
.Lvc_output_error:
    lea rcx, [rip+vc_output_error]
    jmp .Lvc_failed
.Lvc_cancelled:
    lea rcx, [rip+vc_cancel_error]
.Lvc_failed:
    call print_text
    mov ebp, 1
.Lvc_cleanup:
    mov rcx, [rip+vc_output]
    cmp rcx, -1
    je .Lvc_cleanup_gpu
    call CloseHandle
    mov qword ptr [rip+vc_output], -1
    test ebp, ebp
    jz .Lvc_cleanup_gpu
    mov rcx, [rip+vc_output_path]
    call DeleteFileW             # only a file created by this invocation
.Lvc_cleanup_gpu:
    lea rcx, [rip+vc_gpu]
    call win_video_close
    lea rcx, [rip+vc_parser]
    call h264_close
    mov rcx, [rip+vc_pixels]
    test rcx, rcx
    jz .Lvc_cleanup_map
    call mem_free
    mov qword ptr [rip+vc_pixels], 0
.Lvc_cleanup_map:
    mov rcx, [rip+vc_view]
    test rcx, rcx
    jz .Lvc_cleanup_handler
    mov rdx, [rip+vc_size]
    mov r8, [rip+vc_token]
    call file_unmap
    mov qword ptr [rip+vc_view], 0
.Lvc_cleanup_handler:
    lea rcx, [rip+vc_control]
    xor edx, edx
    call SetConsoleCtrlHandler
    mov eax, ebp
    jmp .Lvc_return
.Lvc_bad_usage:
    lea rcx, [rip+vc_usage]
    call print_text
    mov eax, 2
    jmp .Lvc_return
.Lvc_not_video:
    mov eax, -1
.Lvc_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_video_cli

LOCALFN vc_open_parser
    lea rcx, [rip+vc_parser]
    mov rdx, [rip+vc_view]
    mov r8, [rip+vc_size]
    lea r9, [rip+vc_cancel]
    jmp h264_open
ENDFN vc_open_parser

# R12=deadline; no unbounded busy-wait. Ctrl+C checked by caller each retry.
LOCALFN vc_wait
    sub rsp, 40
    call GetTickCount64
    cmp rax, r12
    jae .Lvc_wait_expired
    mov ecx, 1
    call Sleep
    mov eax, 1
    jmp .Lvc_wait_return
.Lvc_wait_expired:
    xor eax, eax
.Lvc_wait_return:
    add rsp, 40
    ret
ENDFN vc_wait

# Compact valid even 4:2:0 crop in-place; every source row is >= destination.
LOCALFN vc_crop
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    lea rbx, [rip+vc_parser]
    mov rdi, [rip+vc_pixels]
    mov ebp, [rbx+HP_WIDTH]
    mov r12d, [rbx+HP_VISIBLE_W]
    mov eax, [rbx+HP_TOP]
    imul eax, ebp
    add eax, [rbx+HP_LEFT]
    lea rsi, [rdi+rax]
    mov r13d, [rbx+HP_VISIBLE_H]
.Lvc_crop_y:
    mov rdx, rsi
    mov ecx, r12d
    rep movsb
    lea rsi, [rdx+rbp]
    dec r13d
    jnz .Lvc_crop_y
    mov eax, [rbx+HP_HEIGHT]
    imul eax, ebp
    mov ecx, [rbx+HP_TOP]
    shr ecx, 1
    imul ecx, ebp
    add eax, ecx
    add eax, [rbx+HP_LEFT]
    mov rsi, [rip+vc_pixels]
    add rsi, rax
    mov r13d, [rbx+HP_VISIBLE_H]
    shr r13d, 1
.Lvc_crop_uv:
    mov rdx, rsi
    mov ecx, r12d
    rep movsb
    lea rsi, [rdx+rbp]
    dec r13d
    jnz .Lvc_crop_uv
    mov eax, [rbx+HP_VISIBLE_H]
    imul eax, r12d
    lea eax, [rax+rax*2]
    shr eax, 1
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vc_crop

LOCALFN vc_control
    mov dword ptr [rip+vc_cancel], 1
    mov eax, 1
    ret
ENDFN vc_control
