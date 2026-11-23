# Original borrowed MP4-to-H264 parsed-picture source. Microsoft ABI. MIT.
.include "lamp.inc"
.include "video_mp4.inc"
.include "h264.inc"
.text

# RCX=ready MP4 index,RDX=new/closed parser ->1configured/0failure.
# A greater external epoch identifies every replay; input/config remain borrowed.
# Old GPU submissions and parser output ownership must already be released.
FN video_mp4_h264_reset
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rdx, [rbx+VM_EPOCH]
    add rdx, 1
    jc .Lvmh_reset_zero
    call video_mp4_rewind
    test eax, eax
    jz .Lvmh_reset_return
    mov rcx, rsi
    call h264_close
    mov rcx, rsi
    mov rdx, [rbx+VM_CONFIG]
    mov r8d, [rbx+VM_CONFIG_BYTES]
    mov r9, [rbx+VM_CANCEL]
    call h264_packet_open
    jmp .Lvmh_reset_return
.Lvmh_reset_zero:
    xor eax, eax
.Lvmh_reset_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN video_mp4_h264_reset

# RCX=MP4,RDX=parser,R8=80B descriptor ->1parsed picture,0EOF,-1error,
# 2cooperative yield after128 empty samples. Nonempty hidden preroll/postroll
# are parsed and decoded normally so later pictures retain reference history.
FN video_mp4_h264_next
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov ebp, 128
.Lvmh_next:
    mov rcx, rbx
    mov rdx, rdi
    call video_mp4_next
    cmp eax, 1
    jne .Lvmh_return
    test dword ptr [rdi+48], VM_EMPTY
    jz .Lvmh_picture
    dec ebp
    jnz .Lvmh_next
    mov eax, 2
    jmp .Lvmh_return
.Lvmh_picture:
    mov rcx, rsi
    mov rdx, rdi
    call h264_packet_next
.Lvmh_return:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN video_mp4_h264_next
