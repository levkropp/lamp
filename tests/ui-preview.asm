; Test the exact assembly UI renderer without desktop automation.
option casemap:none
IFNDEF PREVIEW_CODEC
PREVIEW_CODEC EQU 2
ENDIF
EXTERN ui_draw:PROC, ui_width:DWORD, ui_height:DWORD, ui_state:DWORD
EXTERN ui_pixels:QWORD, ui_bmi:BYTE, ui_filename:QWORD, ui_thread:QWORD
EXTERN sample_rate:DWORD, total_frames:QWORD, codec_kind:DWORD
EXTERN engine_position:QWORD
EXTERN engine_ready:DWORD
EXTERN CreateFileW:PROC, WriteFile:PROC, CloseHandle:PROC, ExitProcess:PROC
PUBLIC preview_start
.data
preview_name dw 'l','a','m','p','-','u','i','-','p','r','e','v','i','e','w','.','b','m','p',0
IF PREVIEW_CODEC EQ 6
preview_track dw 'A','I','F','F',' ','r','e','f','e','r','e','n','c','e','.','a','i','f','f',0
ELSE
preview_track dw 'A','u','r','o','r','a',' ','-',' ','N','i','g','h','t',' ','D','r','i','v','e','.','f','l','a','c',0
ENDIF
preview_header db 'B','M'
    dd 1440054
    dw 0,0
    dd 54
preview_file dq 0
preview_written dd 0
.code
preview_start PROC
    sub rsp,72
    mov dword ptr [ui_width],800
    mov dword ptr [ui_height],450
    mov dword ptr [ui_state],1
    mov dword ptr [engine_ready],1
    lea rax,preview_track
    mov [ui_filename],rax
    mov qword ptr [ui_thread],1
    mov dword ptr [sample_rate],48000
    mov qword ptr [total_frames],5760000
    mov qword ptr [engine_position],1776000
    mov dword ptr [codec_kind],PREVIEW_CODEC
    call ui_draw
    cmp qword ptr [ui_pixels],0
    je preview_bad
    lea rcx,preview_name
    mov edx,40000000h
    xor r8d,r8d
    xor r9d,r9d
    mov qword ptr [rsp+32],2
    mov qword ptr [rsp+40],80h
    mov qword ptr [rsp+48],0
    call CreateFileW
    cmp rax,-1
    je preview_bad
    mov [preview_file],rax
    mov rcx,rax
    lea rdx,preview_header
    mov r8d,14
    lea r9,preview_written
    mov qword ptr [rsp+32],0
    call WriteFile
    mov rcx,[preview_file]
    lea rdx,ui_bmi
    mov r8d,40
    lea r9,preview_written
    call WriteFile
    mov rcx,[preview_file]
    mov rdx,[ui_pixels]
    mov r8d,1440000
    lea r9,preview_written
    call WriteFile
    mov rcx,[preview_file]
    call CloseHandle
    xor ecx,ecx
    call ExitProcess
preview_bad:
    mov ecx,1
    call ExitProcess
preview_start ENDP
END
