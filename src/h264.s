# Original bounded Annex B H.264 I/P frontend. MIT. No software codec library.
# Syntax: ITU-T H.264 (08/2024); native DXVA metadata layout: Windows SDK.
.include "lamp.inc"
.include "h264.inc"

# RCX=new/closed zeroed context, RDX=bytes, R8=size, R9=optional cancel DWORD*.
# The caller keeps the read-only input alive through close. Returns1/0.
FN h264_open
    push rbx
    push rsi
    push rdi
    mov rbx, rcx
    cmp qword ptr [rbx+HP_DATA], 0
    jne .Lhp_open_bad
    cmp qword ptr [rbx+HP_BITS_BUFFER], 0
    jne .Lhp_open_bad
    test rdx, rdx
    jz .Lhp_open_bad
    cmp r8, 4
    jb .Lhp_open_bad
    test r8, r8
    js .Lhp_open_bad
    mov rsi, rdx
    add r8, rdx
    jc .Lhp_open_bad
    xor eax, eax
    mov rdi, rbx
    mov ecx, HP_BYTES/8
    rep stosq
    mov [rbx+HP_DATA], rsi
    mov [rbx+HP_CURSOR], rsi
    mov [rbx+HP_END], r8
    mov [rbx+HP_CANCEL], r9
    lea rdi, [rbx+HP_MATRIX]
    mov ecx, 224
    mov al, 16
    rep stosb
    mov eax, 1
    jmp .Lhp_open_return
.Lhp_open_bad:
    xor eax, eax
.Lhp_open_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN h264_open

FN h264_close
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rcx, [rbx+HP_BITS_BUFFER]
    test rcx, rcx
    jz .Lhp_close_clear
    call mem_free
.Lhp_close_clear:
    mov rdi, rbx
    xor eax, eax
    mov ecx, HP_BYTES/8
    rep stosq
    add rsp, 40
    pop rdi
    pop rbx
    ret
ENDFN h264_close

# RCX=context, EDX=0..32 bits -> EAX. Sticky bounded-reader error.
# Emulation prevention is checked while reading EBSP header bytes.
LOCALFN hp_bits
    xor eax, eax
    cmp dword ptr [rcx+HP_ERROR], 0
    jne .Lhp_bits_return
    cmp edx, 32
    ja .Lhp_bits_bad
    mov r8d, edx
    xor r9d, r9d
.Lhp_bits_loop:
    test r8d, r8d
    jz .Lhp_bits_done
    cmp dword ptr [rcx+HP_BR_BITS], 0
    jne .Lhp_bits_take
    mov r10, [rcx+HP_BR_PTR]
    cmp r10, [rcx+HP_BR_END]
    jae .Lhp_bits_bad
    movzx eax, byte ptr [r10]
    inc r10
    cmp dword ptr [rcx+HP_BR_ZEROS], 2
    jne .Lhp_bits_byte
    cmp eax, 3
    jne .Lhp_bits_escape_missing
    cmp r10, [rcx+HP_BR_END]
    jae .Lhp_bits_bad
    movzx eax, byte ptr [r10]
    cmp eax, 3
    ja .Lhp_bits_bad
    inc r10
    mov dword ptr [rcx+HP_BR_ZEROS], 0
    jmp .Lhp_bits_byte
.Lhp_bits_escape_missing:
    cmp eax, 2
    jbe .Lhp_bits_bad
.Lhp_bits_byte:
    mov [rcx+HP_BR_PTR], r10
    mov [rcx+HP_BR_BYTE], eax
    mov dword ptr [rcx+HP_BR_BITS], 8
    test eax, eax
    jnz .Lhp_bits_nonzero
    inc dword ptr [rcx+HP_BR_ZEROS]
    jmp .Lhp_bits_take
.Lhp_bits_nonzero:
    mov dword ptr [rcx+HP_BR_ZEROS], 0
.Lhp_bits_take:
    dec dword ptr [rcx+HP_BR_BITS]
    mov r11d, [rcx+HP_BR_BITS]
    mov eax, [rcx+HP_BR_BYTE]
    # Preserve the context register while using CL as a variable shift count.
    mov r10, rcx
    mov ecx, r11d
    shr eax, cl
    mov rcx, r10
    and eax, 1
    lea r9d, [rax+r9*2]
    dec r8d
    jmp .Lhp_bits_loop
.Lhp_bits_done:
    mov eax, r9d
.Lhp_bits_return:
    ret
.Lhp_bits_bad:
    mov dword ptr [rcx+HP_ERROR], 1
    xor eax, eax
    ret
ENDFN hp_bits

LOCALFN hp_ue
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    xor esi, esi
.Lhp_ue_prefix:
    mov rcx, rbx
    mov edx, 1
    call hp_bits
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_ue_bad
    test eax, eax
    jnz .Lhp_ue_suffix
    inc esi
    cmp esi, 31
    jbe .Lhp_ue_prefix
    mov dword ptr [rbx+HP_ERROR], 1
    jmp .Lhp_ue_bad
.Lhp_ue_suffix:
    mov rcx, rbx
    mov edx, esi
    call hp_bits
    mov ecx, esi
    mov edx, 1
    shl edx, cl
    dec edx
    add eax, edx
    jmp .Lhp_ue_return
.Lhp_ue_bad:
    xor eax, eax
.Lhp_ue_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN hp_ue

LOCALFN hp_se
    sub rsp, 40
    call hp_ue
    mov edx, eax
    shr eax, 1
    test dl, 1
    jz .Lhp_se_negative
    inc eax
    jmp .Lhp_se_return
.Lhp_se_negative:
    neg eax
.Lhp_se_return:
    add rsp, 40
    ret
ENDFN hp_se

# Start a header reader at current NAL payload, without copying it.
LOCALFN hp_header
    mov rax, [rcx+HP_NAL_PTR]
    mov rdx, rax
    add rdx, [rcx+HP_NAL_BYTES]
    inc rax
    mov [rcx+HP_BR_PTR], rax
    mov [rcx+HP_BR_END], rdx
    mov qword ptr [rcx+HP_BR_BYTE], 0
    mov dword ptr [rcx+HP_BR_ZEROS], 0
    ret
ENDFN hp_header

# Strict rbsp_trailing_bits, after a fully interpreted parameter set.
LOCALFN hp_trailing
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov edx, 1
    call hp_bits
    cmp eax, 1
    jne .Lhp_trailing_bad
.Lhp_trailing_zero:
    cmp dword ptr [rbx+HP_BR_BITS], 0
    je .Lhp_trailing_end
    mov rcx, rbx
    mov edx, 1
    call hp_bits
    test eax, eax
    jnz .Lhp_trailing_bad
    jmp .Lhp_trailing_zero
.Lhp_trailing_end:
    mov rax, [rbx+HP_BR_PTR]
    cmp rax, [rbx+HP_BR_END]
    jne .Lhp_trailing_bad
    cmp dword ptr [rbx+HP_ERROR], 0
    jne .Lhp_trailing_bad
    mov eax, 1
    jmp .Lhp_trailing_return
.Lhp_trailing_bad:
    mov dword ptr [rbx+HP_ERROR], 1
    xor eax, eax
.Lhp_trailing_return:
    add rsp, 32
    pop rbx
    ret
ENDFN hp_trailing

# Parameter-set more_rbsp_data: only the stop bit and byte padding remain?
LOCALFN hp_more
    mov rdx, [rcx+HP_BR_PTR]
    mov eax, [rcx+HP_BR_BITS]
    cmp rdx, [rcx+HP_BR_END]
    je .Lhp_more_bits
    test eax, eax
    jnz .Lhp_more_yes
    lea r8, [rdx+1]
    cmp r8, [rcx+HP_BR_END]
    jne .Lhp_more_yes
    cmp byte ptr [rdx], 128
    jne .Lhp_more_yes
    xor eax, eax
    ret
.Lhp_more_bits:
    test eax, eax
    jz .Lhp_more_yes
    mov r8d, [rcx+HP_BR_BYTE]
    mov ecx, eax
    mov edx, 1
    shl edx, cl
    dec edx
    and r8d, edx
    inc edx
    shr edx, 1
    xor eax, eax
    cmp r8d, edx
    setne al
    ret
.Lhp_more_yes:
    mov eax, 1
    ret
ENDFN hp_more

# Find one bounded byte-stream NAL. Leading/trailing_zero_8bits are excluded.
# Returns1 NAL,0 EOF,-1 malformed/limit/cancel. Poll cancellation every4096B.
LOCALFN hp_nal
    mov r8, [rcx+HP_CURSOR]
    mov r10, [rcx+HP_END]
    cmp r8, r10
    je .Lhp_nal_eof
    ja .Lhp_nal_bad
    mov [rcx+HP_NAL_START], r8
    mov rdx, [rcx+HP_CANCEL]
    xor r11d, r11d
    xor eax, eax
.Lhp_nal_prefix:
    test eax, 4095
    jnz .Lhp_nal_prefix_byte
    test rdx, rdx
    jz .Lhp_nal_prefix_byte
    cmp dword ptr [rdx], 0
    jne .Lhp_nal_cancel
.Lhp_nal_prefix_byte:
    cmp r8, r10
    jae .Lhp_nal_bad
    movzx r9d, byte ptr [r8]
    inc r8
    inc eax
    test r9d, r9d
    jnz .Lhp_nal_one
    inc r11
    jmp .Lhp_nal_prefix
.Lhp_nal_one:
    cmp r9d, 1
    jne .Lhp_nal_bad
    cmp r11, 2
    jb .Lhp_nal_bad
    mov [rcx+HP_NAL_PTR], r8
    mov r9, r8
    xor r11d, r11d
    xor eax, eax
.Lhp_nal_scan:
    test eax, 4095
    jnz .Lhp_nal_scan_byte
    test rdx, rdx
    jz .Lhp_nal_scan_byte
    cmp dword ptr [rdx], 0
    jne .Lhp_nal_cancel
.Lhp_nal_scan_byte:
    cmp r8, r10
    je .Lhp_nal_end
    cmp eax, HP_MAX_FRAME
    ja .Lhp_nal_limit
    cmp byte ptr [r8], 0
    jne .Lhp_nal_nonzero
    inc r11
    jmp .Lhp_nal_advance
.Lhp_nal_nonzero:
    cmp byte ptr [r8], 1
    jne .Lhp_nal_reset
    cmp r11, 2
    jae .Lhp_nal_found
.Lhp_nal_reset:
    xor r11d, r11d
.Lhp_nal_advance:
    inc r8
    inc eax
    jmp .Lhp_nal_scan
.Lhp_nal_found:
    sub r8, r11
    mov [rcx+HP_CURSOR], r8
    jmp .Lhp_nal_size
.Lhp_nal_end:
    mov [rcx+HP_CURSOR], r8
    sub r8, r11
.Lhp_nal_size:
    sub r8, r9
    cmp r8, 1
    jb .Lhp_nal_bad
    cmp r8, HP_MAX_FRAME
    ja .Lhp_nal_limit
    mov [rcx+HP_NAL_BYTES], r8
    test byte ptr [r9], 0x80
    jnz .Lhp_nal_bad
    inc qword ptr [rcx+HP_NALS]
    mov eax, 1
    ret
.Lhp_nal_limit:
    mov dword ptr [rcx+HP_ERROR], 3
    jmp .Lhp_nal_error
.Lhp_nal_cancel:
    mov dword ptr [rcx+HP_ERROR], 61
    jmp .Lhp_nal_error
.Lhp_nal_bad:
    mov dword ptr [rcx+HP_ERROR], 1
.Lhp_nal_error:
    mov eax, -1
    ret
.Lhp_nal_eof:
    xor eax, eax
    ret
ENDFN hp_nal

.include "h264_scaling.inc"
.include "h264_headers.inc"
.include "h264_dpb.inc"
.include "h264_frames.inc"
