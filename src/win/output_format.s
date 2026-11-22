# Original WASAPI exclusive-format and bounded stereo packing primitives. MIT.
# Used by the optional exclusive path; shared output retains its float32 path.
.include "lamp.inc"
RODATA
fmt_bytes: .byte 4,4,4,3,2,4,4,3,2
fmt_bits: .byte 32,32,24,24,16,32,32,24,16
fmt_guid_tail: .long 0x00100000,0xaa000080,0x719b3800
.p2align 3
fmt_one: .double 1.0
fmt_neg_one: .double -1.0
fmt_half: .double 0.5
.text
# RCX=48-byte descriptor, EDX=rate, R8D=kind, R9=capacity. EAX=1 or 0.
# Windows format occupies bytes 0..39; kind at 40, reserved zero at 44.
# Kinds: extensible float32/PCM32/24-in-32/PCM24/PCM16, then basic
# float32/PCM32/PCM24/PCM16. Exact requested rate, stereo FL/FR.
FN output_format_make
    cmp r9, 48
    jb .Lfmt_invalid
    test rcx, rcx
    jz .Lfmt_invalid
    cmp edx, 8000
    jb .Lfmt_invalid
    cmp edx, 192000
    ja .Lfmt_invalid
    cmp r8d, 9
    jae .Lfmt_invalid
    pxor xmm0, xmm0
    movdqu [rcx], xmm0
    movdqu [rcx+16], xmm0
    movdqu [rcx+32], xmm0
    mov [rcx+40], r8d
    mov word ptr [rcx+2], 2
    mov [rcx+4], edx
    lea r10, [rip+fmt_bytes]
    movzx eax, byte ptr [r10+r8]
    shl eax, 1
    mov [rcx+12], ax
    imul eax, edx
    mov [rcx+8], eax
    lea r10, [rip+fmt_bytes]
    movzx eax, byte ptr [r10+r8]
    shl eax, 3
    mov [rcx+14], ax
    mov eax, 1
    test r8d, r8d
    jz .Lfmt_float
    cmp r8d, 5
    jne .Lfmt_tag
.Lfmt_float:
    mov eax, 3
.Lfmt_tag:
    cmp r8d, 5
    jae .Lfmt_basic
    mov word ptr [rcx], 0xfffe
    mov word ptr [rcx+16], 22
    lea r10, [rip+fmt_bits]
    movzx r9d, byte ptr [r10+r8]
    mov [rcx+18], r9w
    mov dword ptr [rcx+20], 3
    mov [rcx+24], eax
    mov rax, [rip+fmt_guid_tail]
    mov [rcx+28], rax
    mov eax, [rip+fmt_guid_tail+8]
    mov [rcx+36], eax
    jmp .Lfmt_valid
.Lfmt_basic:
    mov [rcx], ax
.Lfmt_valid:
    mov eax, 1
    ret
.Lfmt_invalid:
    xor eax, eax
    ret
ENDFN output_format_make

# RCX=IAudioClient, EDX=rate, R8=descriptor, R9=capacity. EAX=HRESULT.
# Query only: never Initialize/Start or change device settings. S_OK is the
# only acceptance. Other failures abort; unsupported/S_FALSE try next kind.
# On failure, caller's descriptor is untouched.
FN output_format_choose
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 80
    mov rsi, rcx
    mov edi, edx
    mov r12, r8
    test rsi, rsi
    jz .Lchoose_invalid
    test r12, r12
    jz .Lchoose_invalid
    cmp r9, 48
    jb .Lchoose_invalid
    xor ebx, ebx
.Lchoose_next:
    lea rcx, [rsp+32]
    mov edx, edi
    mov r8d, ebx
    mov r9d, 48
    call output_format_make
    test eax, eax
    jz .Lchoose_invalid
    mov rcx, rsi
    mov edx, 1                        # AUDCLNT_SHAREMODE_EXCLUSIVE
    lea r8, [rsp+32]
    xor r9d, r9d                      # exclusive query has no closest-match allocation
    mov rax, [rcx]
    call qword ptr [rax+56]
    test eax, eax
    jz .Lchoose_found
    cmp eax, 0x88890008
    je .Lchoose_unsupported
    cmp eax, 1
    je .Lchoose_unsupported
    test eax, eax
    js .Lchoose_return
    mov eax, 0x8000ffff                 # unexpected positive status is not acceptance
    jmp .Lchoose_return
.Lchoose_unsupported:
    inc ebx
    cmp ebx, 9
    jb .Lchoose_next
    mov eax, 0x88890008
    jmp .Lchoose_return
.Lchoose_found:
    movdqu xmm0, [rsp+32]
    movdqu xmm1, [rsp+48]
    movdqu xmm2, [rsp+64]
    movdqu [r12], xmm0
    movdqu [r12+16], xmm1
    movdqu [r12+32], xmm2
    xor eax, eax
    jmp .Lchoose_return
.Lchoose_invalid:
    mov eax, 0x80070057
.Lchoose_return:
    add rsp, 80
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN output_format_choose

# RCX=destination, RDX=stereo float32 input, R8D=frames, R9D=kind,
# [rsp+40]=destination bytes, [rsp+48]=float32 linear volume (0..1).
# EAX=1/0. At most 262144 frames; invalid requests write nothing. No overlap.
# Nonfinite input -> zero, gain precedes full-scale clipping. Integer output
# rounds nearest with ties away from zero, independently of MXCSR rounding.
FN output_format_pack
    cmp r9d, 9
    jae .Lpack_invalid
    cmp r8d, 262144
    ja .Lpack_invalid
    test r8d, r8d
    jz .Lpack_valid
    test rcx, rcx
    jz .Lpack_invalid
    test rdx, rdx
    jz .Lpack_invalid
    lea r10, [rip+fmt_bytes]
    movzx eax, byte ptr [r10+r9]
    imul eax, r8d
    shl eax, 1
    cmp [rsp+40], rax
    jb .Lpack_invalid
    mov r10, rcx
    add r10, rax
    jc .Lpack_invalid
    mov r11d, r8d
    shl r11, 3
    add r11, rdx
    jc .Lpack_invalid
    cmp rcx, r11
    jae .Lpack_disjoint
    cmp rdx, r10
    jb .Lpack_invalid
.Lpack_disjoint:
    movss xmm5, dword ptr [rsp+48]
    xorps xmm0, xmm0
    ucomiss xmm5, xmm0
    jp .Lpack_invalid
    jb .Lpack_invalid
    cvtss2sd xmm5, xmm5
    ucomisd xmm5, qword ptr [rip+fmt_one]
    ja .Lpack_invalid
    mov r10, rcx
    mov r11, rdx
    shl r8d, 1
    lea rax, [rip+fmt_bits]
    movzx ecx, byte ptr [rax+r9]
    dec ecx
    mov eax, 1
    shl rax, cl
    cvtsi2sd xmm4, rax
    lea rdx, [rax-1]
.Lpack_sample:
    mov eax, [r11]
    mov ecx, eax
    and ecx, 0x7fffffff
    pxor xmm0, xmm0
    cmp ecx, 0x7f800000
    jae .Lpack_scaled
    movd xmm0, eax
    cvtss2sd xmm0, xmm0
    mulsd xmm0, xmm5
    maxsd xmm0, qword ptr [rip+fmt_neg_one]
    minsd xmm0, qword ptr [rip+fmt_one]
.Lpack_scaled:
    test r9d, r9d
    jz .Lpack_float
    cmp r9d, 5
    je .Lpack_float
    mulsd xmm0, xmm4
    pxor xmm1, xmm1
    ucomisd xmm0, xmm1
    jb .Lpack_negative
    addsd xmm0, qword ptr [rip+fmt_half]
    jmp .Lpack_integer
.Lpack_negative:
    subsd xmm0, qword ptr [rip+fmt_half]
.Lpack_integer:
    cvttsd2si rax, xmm0
    cmp rax, rdx
    cmovg rax, rdx
    cmp r9d, 2
    jne .Lpack_width
    shl eax, 8                         # 24 valid bits left aligned in 32
.Lpack_width:
    cmp r9d, 4
    je .Lpack_16
    cmp r9d, 8
    je .Lpack_16
    cmp r9d, 3
    je .Lpack_24
    cmp r9d, 7
    je .Lpack_24
    mov [r10], eax
    add r10, 4
    jmp .Lpack_next
.Lpack_16:
    mov [r10], ax
    add r10, 2
    jmp .Lpack_next
.Lpack_24:
    mov [r10], ax
    shr eax, 16
    mov [r10+2], al
    add r10, 3
    jmp .Lpack_next
.Lpack_float:
    cvtsd2ss xmm0, xmm0
    movss dword ptr [r10], xmm0
    add r10, 4
.Lpack_next:
    add r11, 4
    dec r8d
    jnz .Lpack_sample
.Lpack_valid:
    mov eax, 1
    ret
.Lpack_invalid:
    xor eax, eax
    ret
ENDFN output_format_pack
