# Bounded complete Opus packet-to-float PCM dispatch, adapted from RFC6716.
# Copyright(c)2010-2012 IETF Trust,Xiph.Org Foundation,Skype Limited.
# BSD in THIRD_PARTY_NOTICES. Normal opus_decode_native orchestration, with
# explicit capacities and sticky failure handling. One decode owner.
.include "lamp.inc"
.include "opus_stream_layout.inc"
.include "opus_mode_layout.inc"
.text
FN op_opus_decode_packet
    xor edx, edx
    jmp op_opus_decode_packet_ex
ENDFN op_opus_decode_packet

# The existing56-byte request ABI is unchanged. EDX=1 accepts a self-delimited
# prefix for multistream; EDX=0 is ordinary packet framing. Packet bytes are
# reported by the framing parser in op_packet_bytes. Decoder storage is owned
# by the caller and can be separate for each mono/stereo stream.
FN op_opus_decode_packet_ex
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 144
    mov [rsp + 128], edx
    cmp edx, 1
    ja .Lpk_bad
    mov rbx, rcx
    test rbx, rbx
    jz .Lpk_bad
    mov r12, [rbx + PK_STATE]
    mov r13, [rbx + PK_WORK]
    mov r14, [rbx + PK_PCM]
    mov r15, [rbx + PK_DATA]
    test r12, r12
    jz .Lpk_bad
    test r13, r13
    jz .Lpk_bad
    test r14, r14
    jz .Lpk_bad
    cmp dword ptr [rbx + PK_STATE_CAP], MO_SIZE
    jb .Lpk_bad
    cmp dword ptr [rbx + PK_WORK_CAP], MW_SIZE
    jb .Lpk_bad
    cmp dword ptr [r12 + MO_TAG], MO_MAGIC
    jne .Lpk_bad
    cmp dword ptr [r12 + MO_ERROR], 0
    jne .Lpk_bad
    cmp dword ptr [rbx + PK_LEN], 0x400000
    ja .Lpk_bad
    cmp dword ptr [rbx + PK_FEC], 1
    ja .Lpk_bad
    mov eax, [r12 + MO_CHANNELS]
    dec eax
    cmp eax, 1
    ja .Lpk_bad
    mov eax, [r12 + MO_FS]
    cmp eax, 8000
    je .Lpk_rate_valid
    cmp eax, 12000
    je .Lpk_rate_valid
    cmp eax, 16000
    je .Lpk_rate_valid
    cmp eax, 24000
    je .Lpk_rate_valid
    cmp eax, 48000
    jne .Lpk_bad
.Lpk_rate_valid:
    xor edx, edx
    mov ecx, 400
    div ecx
    mov [rsp + 96], eax           #2.5ms samples
    imul eax, 48
    cmp [rbx + PK_COUNT], eax
    ja .Lpk_bad
    mov dword ptr [rsp + 100], 0  #emitted samples
    cmp dword ptr [rbx + PK_LEN], 0
    je .Lpk_loss
    test r15, r15
    jz .Lpk_bad
    mov rcx, r15
    mov edx, [rbx + PK_LEN]
    mov r8d, [rsp + 128]
    call op_opus_packet_parse_ex
    test eax, eax
    jz .Lpk_bad
    mov [rsp + 104], eax          #frames
    mov eax, [rip + op_packet_samples]
    imul eax, [r12 + MO_FS]
    xor edx, edx
    mov ecx, 48000
    div ecx
    mov [rsp + 108], eax          #packet samples
    mov ecx, [rbx + PK_COUNT]
    test ecx, ecx
    jz .Lpk_packet_capacity
    cmp ecx, eax
    jb .Lpk_bad
.Lpk_packet_capacity:
    imul eax, [r12 + MO_CHANNELS]
    cmp [rbx + PK_PCM_CAP], eax
    jb .Lpk_bad
    mov dword ptr [rsp + 112], 0  #frame index
.Lpk_frame:
    mov ecx, [rsp + 112]
    lea rax, [rip + op_frame_ptr]
    mov rax, [rax + rcx*8]
    mov [rsp + 32 + MF_DATA], rax
    lea rax, [rip + op_frame_size]
    mov eax, [rax + rcx*4]
    mov [rsp + 32 + MF_LEN], eax
    mov eax, [rip + op_config]
    mov [rsp + 32 + MF_CONFIG], eax
    mov eax, [rip + op_stereo]
    inc eax
    mov [rsp + 32 + MF_STREAM], eax
    mov eax, [rsp + 108]
    sub eax, [rsp + 100]
    mov [rsp + 32 + MF_COUNT], eax
    mov eax, [rbx + PK_FEC]
    mov [rsp + 32 + MF_FEC], eax
    jmp .Lpk_call
.Lpk_loss:
    mov dword ptr [rip + op_packet_bytes], 0 #PLC consumes no encoded bytes
    mov eax, [r12 + MO_FRAME]
    cmp eax, [rsp + 96]
    jb .Lpk_bad
    mov ecx, [rsp + 96]
    imul ecx, 24
    cmp eax, ecx
    ja .Lpk_bad
    mov ecx, [rbx + PK_COUNT]
    test ecx, ecx
    jz .Lpk_loss_count
    cmp eax, ecx
    cmova eax, ecx
.Lpk_loss_count:
    cmp eax, [rsp + 96]
    jb .Lpk_bad
    mov [rsp + 108], eax
    imul eax, [r12 + MO_CHANNELS]
    cmp [rbx + PK_PCM_CAP], eax
    jb .Lpk_bad
    mov eax, [r12 + MO_PREV]
    cmp eax, 3
    ja .Lpk_bad
    cmp eax, 1
    jb .Lpk_loss_shape_valid
    je .Lpk_silk_loss_shape
    mov eax, [rsp + 96]
    mov ecx, [rsp + 108]
    cmp ecx, eax
    je .Lpk_loss_shape_valid
    shl eax, 1
    cmp ecx, eax
    je .Lpk_loss_shape_valid
    shl eax, 1
    cmp ecx, eax
    je .Lpk_loss_shape_valid
    shl eax, 1
    cmp ecx, eax
    jbe .Lpk_loss_exact_20
    xchg eax, ecx
    xor edx, edx
    div ecx
    test edx, edx
    jnz .Lpk_bad
    jmp .Lpk_loss_shape_valid
.Lpk_loss_exact_20:
    jne .Lpk_bad
    jmp .Lpk_loss_shape_valid
.Lpk_silk_loss_shape:
    mov eax, [rsp + 96]
    shl eax, 3
    cmp [rsp + 108], eax
    jbe .Lpk_loss_shape_valid
    shl eax, 1
    cmp [rsp + 108], eax
    je .Lpk_loss_shape_valid
    mov eax, [rsp + 96]
    imul eax, 24
    cmp [rsp + 108], eax
    jne .Lpk_bad
.Lpk_loss_shape_valid:
    mov dword ptr [rsp + 104], 1
    mov dword ptr [rsp + 112], 0
    mov qword ptr [rsp + 32 + MF_DATA], 0
    mov dword ptr [rsp + 32 + MF_LEN], 0
    mov dword ptr [rsp + 32 + MF_CONFIG], 0
    mov eax, [r12 + MO_STREAM]
    mov [rsp + 32 + MF_STREAM], eax
    mov eax, [rsp + 108]
    mov [rsp + 32 + MF_COUNT], eax
    mov dword ptr [rsp + 32 + MF_FEC], 0
.Lpk_call:
    mov [rsp + 32 + MF_STATE], r12
    mov [rsp + 32 + MF_WORK], r13
    mov eax, [rsp + 100]
    imul eax, [r12 + MO_CHANNELS]
    lea rdx, [r14 + rax*4]
    mov [rsp + 32 + MF_PCM], rdx
    mov edx, [rbx + PK_PCM_CAP]
    sub edx, eax
    mov [rsp + 32 + MF_PCM_CAP], edx
    mov dword ptr [rsp + 32 + MF_STATE_CAP], MO_SIZE
    mov dword ptr [rsp + 32 + MF_WORK_CAP], MW_SIZE
    lea rcx, [rsp + 32]
    call op_opus_decode_frame
    test eax, eax
    jle .Lpk_failed
    add [rsp + 100], eax
    inc dword ptr [rsp + 112]
    mov eax, [rsp + 112]
    cmp eax, [rsp + 104]
    jb .Lpk_frame
    mov eax, [rsp + 100]
    jmp .Lpk_done
.Lpk_failed:
    mov dword ptr [r12 + MO_ERROR], 1
    mov eax, -1
    jmp .Lpk_done
.Lpk_bad:
    xor eax, eax
.Lpk_done:
    add rsp, 144
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN op_opus_decode_packet_ex
