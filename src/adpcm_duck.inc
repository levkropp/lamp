# Original Duck DK3/DK4 block decoding. MIT, see LICENSE.
# DK4: signed predictor and signed step index per channel, then high-first
# interleaved IMA codes. DK3: a 16-byte header with sum/difference predictors
# at 10/12 and byte indices at 14/15, then low-first sum/difference/sum codes
# for each pair of stereo frames. Sum/difference output wraps to int16,
# matching the established decoder behavior. No state crosses block boundaries.
# Format/PCM comparators: FFmpeg n5.1.9 and n9.0.1 libavcodec/adpcm.c.

# RCX=8-byte predictor/index state, EAX=4-bit IMA code -> EAX=updated sample.
# The same combined-product reconstruction as the existing 4-bit WAVE path.
LOCALFN duck_ima_step
    mov r8d, eax
    and r8d, 15
    mov r9d, [rcx + 4]
    lea r10, [rip + ima_steps]
    movzx edx, word ptr [r10 + r9*2]
    and eax, 7
    lea eax, [rax*2 + 1]
    imul eax, edx
    shr eax, 3
    mov edx, [rcx]
    test r8d, 8
    jnz .Lduck_step_sub
    add edx, eax
    jmp .Lduck_step_clip
.Lduck_step_sub:
    sub edx, eax
.Lduck_step_clip:
    mov eax, -32768
    cmp edx, eax
    cmovl edx, eax
    mov eax, 32767
    cmp edx, eax
    cmovg edx, eax
    mov [rcx], edx
    lea r10, [rip + ima_index]
    movsx eax, byte ptr [r10 + r8]
    add r9d, eax
    xor eax, eax
    test r9d, r9d
    cmovs r9d, eax
    mov eax, 88
    cmp r9d, eax
    cmovg r9d, eax
    mov [rcx + 4], r9d
    mov eax, edx
    ret
ENDFN duck_ima_step

# RCX=block, EDX=frames. Complete headers have already been bounded.
LOCALFN dk4_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov r12d, edx
    mov r13d, [rip + adpcm_channels]
    lea r8, [rip + adpcm_state]
    xor ebx, ebx
.Ldk4_header:
    movsx eax, word ptr [rsi + rbx*4]
    movsx edx, word ptr [rsi + rbx*4 + 2]
    cmp edx, 88
    ja .Ldk4_bad
    mov [r8 + rbx*8], eax
    mov [r8 + rbx*8 + 4], edx
    mov ecx, [rip + adpcm_stride]
    imul ecx, ebx
    mov rdi, [rip + adpcm_planes]
    mov [rdi + rcx], ax
    inc ebx
    cmp ebx, r13d
    jb .Ldk4_header
    lea rsi, [rsi + r13*4]
    dec r12d
    imul r12d, r13d                     # codes after the first sample
    xor ebx, ebx
.Ldk4_code:
    cmp ebx, r12d
    jae .Ldk4_done
    lea ecx, [r13 - 1]
    and ecx, ebx                        # channel 0, or alternating 0/1
    mov eax, [rip + adpcm_stride]
    imul eax, ecx
    mov rdi, [rip + adpcm_planes]
    add rdi, rax
    mov eax, ebx
    cmp r13d, 2
    jne .Ldk4_frame
    shr eax, 1
.Ldk4_frame:
    lea rdi, [rdi + rax*2 + 2]
    lea rax, [rip + adpcm_state]
    lea rcx, [rax + rcx*8]
    mov edx, ebx
    shr edx, 1
    movzx eax, byte ptr [rsi + rdx]
    test bl, 1
    jnz .Ldk4_low
    shr eax, 4
.Ldk4_low:
    and eax, 15
    call duck_ima_step
    mov [rdi], ax
    inc ebx
    jmp .Ldk4_code
.Ldk4_bad:
    xor eax, eax
    jmp .Ldk4_return
.Ldk4_done:
    mov eax, 1
.Ldk4_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN dk4_block

# RSI=payload, EBX=code index (advanced), -> EAX=next low-first nibble.
# Clobbers EDX only in addition to the named input/output registers.
LOCALFN dk3_next_code
    mov edx, ebx
    shr edx, 1
    movzx eax, byte ptr [rsi + rdx]
    test bl, 1
    jz .Ldk3_next_low
    shr eax, 4
.Ldk3_next_low:
    and eax, 15
    inc ebx
    ret
ENDFN dk3_next_code

LOCALFN dk3_block
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov r12d, edx
    shr r12d, 1                         # three codes produce two frames
    lea rcx, [rip + adpcm_state]
    movsx eax, word ptr [rsi + 10]
    mov [rcx], eax
    movsx eax, word ptr [rsi + 12]
    mov [rcx + 8], eax
    movzx eax, byte ptr [rsi + 14]
    cmp eax, 88
    ja .Ldk3_bad
    mov [rcx + 4], eax
    movzx eax, byte ptr [rsi + 15]
    cmp eax, 88
    ja .Ldk3_bad
    mov [rcx + 12], eax
    add rsi, 16
    mov rdi, [rip + adpcm_planes]
    mov eax, [rip + adpcm_stride]
    lea r13, [rdi + rax]
    xor ebx, ebx
.Ldk3_pair:
    call dk3_next_code
    lea rcx, [rip + adpcm_state]
    call duck_ima_step
    call dk3_next_code
    lea rcx, [rip + adpcm_state + 8]
    call duck_ima_step
    mov edx, [rip + adpcm_state]
    mov ecx, edx
    add edx, eax
    sub ecx, eax
    mov [rdi], dx
    mov [r13], cx
    call dk3_next_code
    lea rcx, [rip + adpcm_state]
    call duck_ima_step
    mov edx, [rip + adpcm_state + 8]
    mov ecx, eax
    add eax, edx
    sub ecx, edx
    mov [rdi + 2], ax
    mov [r13 + 2], cx
    add rdi, 4
    add r13, 4
    dec r12d
    jnz .Ldk3_pair
    mov eax, 1
    jmp .Ldk3_return
.Ldk3_bad:
    xor eax, eax
.Ldk3_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN dk3_block
