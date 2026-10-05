# Test the exact assembly UI renderer without desktop automation.
.include "lamp.inc"
.ifndef PREVIEW_CODEC
.equ PREVIEW_CODEC, 2
.endif
.data
preview_name: .short 'l', 'a', 'm', 'p', '-', 'u', 'i', '-', 'p', 'r', 'e', 'v', 'i', 'e', 'w', '.', 'b', 'm', 'p', 0
.if PREVIEW_CODEC == 6
preview_track: .short 'A', 'I', 'F', 'F', ' ', 'r', 'e', 'f', 'e', 'r', 'e', 'n', 'c', 'e', '.', 'a', 'i', 'f', 'f', 0
.else
preview_track: .short 'A', 'u', 'r', 'o', 'r', 'a', ' ', '-', ' ', 'N', 'i', 'g', 'h', 't', ' ', 'D', 'r', 'i', 'v', 'e', '.', 'f', 'l', 'a', 'c', 0
.endif
preview_header: .byte 'B', 'M'
    .long 1440054
    .short 0, 0
    .long 54
preview_file: .quad 0
preview_written: .long 0
.text
FN preview_start
    sub rsp, 72
    mov dword ptr [rip + ui_width], 800
    mov dword ptr [rip + ui_height], 450
    mov dword ptr [rip + ui_state], 1
    mov dword ptr [rip + engine_ready], 1
    lea rax, [rip + preview_track]
    mov [rip + ui_filename], rax
    mov qword ptr [rip + ui_thread], 1
    mov dword ptr [rip + output_rate], 48000
    mov qword ptr [rip + output_frames], 5760000
    mov qword ptr [rip + engine_position], 1776000
    mov dword ptr [rip + codec_kind], PREVIEW_CODEC
    call ui_draw
    cmp qword ptr [rip + ui_pixels], 0
    je .Lpreview_bad
    lea rcx, [rip + preview_name]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, -1
    je .Lpreview_bad
    mov [rip + preview_file], rax
    mov rcx, rax
    lea rdx, [rip + preview_header]
    mov r8d, 14
    lea r9, [rip + preview_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    mov rcx, [rip + preview_file]
    lea rdx, [rip + ui_bmi]
    mov r8d, 40
    lea r9, [rip + preview_written]
    call WriteFile
    mov rcx, [rip + preview_file]
    mov rdx, [rip + ui_pixels]
    mov r8d, 1440000
    lea r9, [rip + preview_written]
    call WriteFile
    mov rcx, [rip + preview_file]
    call CloseHandle
    xor ecx, ecx
    call ExitProcess
.Lpreview_bad:
    mov ecx, 1
    call ExitProcess
ENDFN preview_start
