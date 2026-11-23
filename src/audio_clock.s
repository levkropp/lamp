# Original bounded PCM clock mapping, exact integer time and coherent snapshots.
# Single serialized writer, concurrent readers. No OS/callbacks/allocation. MIT.
.include "lamp.inc"
.include "audio_clock.inc"
.text

# RCX=context,RDX=config32 {epoch,baseFrames,rate:u32,mode:u32,reserved:u64}.
# Monotonic nonzero epoch. Initialized context remains live for bounded readers.
FN audio_clock_begin
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    mov rbx, rcx
    mov rsi, [rdx]
    test rsi, rsi
    jz .Lac_begin_bad
    cmp rsi, [rbx+AC_EPOCH]
    jbe .Lac_begin_bad
    mov r12, [rdx+8]
    mov ebp, [rdx+16]
    test ebp, ebp
    jz .Lac_begin_bad
    cmp ebp, 768000
    ja .Lac_begin_bad
    mov r9d, [rdx+20]
    cmp r9d, 1
    ja .Lac_begin_bad
    cmp qword ptr [rdx+24], 0
    jne .Lac_begin_bad
    mov rax, 0x7fffffffffffffff
    mul rbp
    mov ecx, 1000000000
    div rcx
    cmp r12, rax
    ja .Lac_begin_bad
    mov r10, [rbx+AC_VERSION]
    test r10b, 1
    jnz .Lac_begin_bad
    mov r11, -3
    cmp r10, r11
    ja .Lac_begin_bad
    inc qword ptr [rbx+AC_VERSION]
    mfence
    lea rdi, [rbx+8]
    mov r11, rax
    xor eax, eax
    mov ecx, (AC_BYTES-8)/8
    rep stosq
    mov [rbx+AC_EPOCH], rsi
    mov [rbx+AC_BASE], r12
    mov [rbx+AC_MEDIA], r12
    mov [rbx+AC_RATE], ebp
    mov dword ptr [rbx+AC_STATE], AC_STARVED
    mov [rbx+AC_MODE], r9d
    mov [rbx+AC_LIMIT], r11
    mfence
    inc qword ptr [rbx+AC_VERSION]
    mov eax, 1
    jmp .Lac_begin_return
.Lac_begin_bad:
    xor eax, eax
.Lac_begin_return:
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN audio_clock_begin

# RCX=mapped context,RDX=total packet frames,R8=real PREFIX frames.
# Can-submit is read-only. R9=merge record or0 for the internal submit caller.
FN audio_clock_can_submit
    cmp qword ptr [rcx+AC_EPOCH], 0
    je .Lac_submit_bad
    cmp dword ptr [rcx+AC_MODE], 0
    jne .Lac_submit_bad
    cmp dword ptr [rcx+AC_STATE], AC_STARVED
    ja .Lac_submit_bad
    test rdx, rdx
    jz .Lac_submit_bad
    cmp r8, rdx
    ja .Lac_submit_bad
    mov rax, [rcx+AC_SUBMITTED]
    add rax, rdx
    jc .Lac_submit_bad
    mov rax, [rcx+AC_REAL]
    add rax, r8
    jc .Lac_submit_bad
    add rax, [rcx+AC_BASE]
    jc .Lac_submit_bad
    cmp rax, [rcx+AC_LIMIT]
    ja .Lac_submit_bad
    mov r10, [rcx+AC_TAIL]
    mov r11, r10
    sub r11, [rcx+AC_HEAD]
    jc .Lac_submit_bad
    cmp r11, 64
    ja .Lac_submit_bad
    xor r9d, r9d
    test r8, r8
    jz .Lac_submit_ok
    test r11, r11
    jz .Lac_submit_new
    lea rax, [r10-1]
    and eax, 63
    imul rax, rax, 24
    lea r9, [rcx+rax+AC_RECORDS]
    mov rax, [r9]
    add rax, [r9+16]
    cmp rax, [rcx+AC_SUBMITTED]
    jne .Lac_submit_new
    mov rax, [r9+8]
    add rax, [r9+16]
    cmp rax, [rcx+AC_REAL]
    je .Lac_submit_ok
.Lac_submit_new:
    xor r9d, r9d
    cmp r11, 64
    jae .Lac_submit_bad
    cmp r10, -1
    je .Lac_submit_bad
.Lac_submit_ok:
    mov eax, 1
    ret
.Lac_submit_bad:
    xor eax, eax
    ret
ENDFN audio_clock_can_submit

# Commit only after the device successfully accepted the complete packet.
FN audio_clock_submit
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    call audio_clock_can_submit
    test eax, eax
    jz .Lac_commit_return
    test rdi, rdi
    jz .Lac_commit_counts
    test r9, r9
    jnz .Lac_commit_merge
    mov rax, [rbx+AC_TAIL]
    and eax, 63
    imul rax, rax, 24
    lea r9, [rbx+rax+AC_RECORDS]
    mov rax, [rbx+AC_SUBMITTED]
    mov [r9], rax
    mov rax, [rbx+AC_REAL]
    mov [r9+8], rax
    mov [r9+16], rdi
    inc qword ptr [rbx+AC_TAIL]
    jmp .Lac_commit_counts
.Lac_commit_merge:
    add [r9+16], rdi
.Lac_commit_counts:
    add [rbx+AC_SUBMITTED], rsi
    add [rbx+AC_REAL], rdi
    mov eax, 1
.Lac_commit_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN audio_clock_submit

# RCX=context,RDX=new absolute media frame,R8D=state. Internal page publication.
LOCALFN ac_publish
    cmp r8d, AC_FAILED
    ja .Lac_publish_bad
    cmp r8d, 3
    je .Lac_publish_bad
    cmp dword ptr [rcx+AC_STATE], AC_ENDED
    jb .Lac_publish_version
    cmp r8d, [rcx+AC_STATE]
    jb .Lac_publish_bad
.Lac_publish_version:
    mov r9, [rcx+AC_VERSION]
    test r9b, 1
    jnz .Lac_publish_bad
    mov rax, -3
    cmp r9, rax
    ja .Lac_publish_bad
    inc qword ptr [rcx+AC_VERSION]
    mfence
    mov [rcx+AC_MEDIA], rdx
    mov [rcx+AC_STATE], r8d
    mfence
    inc qword ptr [rcx+AC_VERSION]
    mov eax, 1
    ret
.Lac_publish_bad:
    xor eax, eax
    ret
ENDFN ac_publish

# RCX=context,RDX=consumed SUBMITTED frames,R8D=state(0=auto real/gap).
# This counter must count frames accepted by submit, including explicit silence;
# hardware counters which include other gaps must be mapped by their adapter.
FN audio_clock_observe
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    cmp qword ptr [rbx+AC_EPOCH], 0
    je .Lac_observe_bad
    cmp dword ptr [rbx+AC_MODE], 0
    jne .Lac_observe_bad
    cmp rsi, [rbx+AC_DEVICE]
    jb .Lac_observe_bad
    cmp rsi, [rbx+AC_SUBMITTED]
    ja .Lac_observe_bad
    mov rbp, [rbx+AC_HEAD]
    mov rax, [rbx+AC_TAIL]
    sub rax, rbp
    jc .Lac_observe_bad
    cmp rax, 64
    ja .Lac_observe_bad
    mov rdx, [rbx+AC_MEDIA]
    mov r8d, AC_STARVED
.Lac_observe_next:
    cmp rbp, [rbx+AC_TAIL]
    je .Lac_observe_state
    mov eax, ebp
    and eax, 63
    imul rax, rax, 24
    lea r10, [rbx+rax+AC_RECORDS]
    mov rax, rsi
    sub rax, [r10]
    jb .Lac_observe_state
    cmp rax, [r10+16]
    jb .Lac_observe_partial
    mov rdx, [r10+8]
    add rdx, [r10+16]
    add rdx, [rbx+AC_BASE]
    inc rbp
    jmp .Lac_observe_next
.Lac_observe_partial:
    mov rdx, [r10+8]
    add rdx, rax
    add rdx, [rbx+AC_BASE]
    mov r8d, AC_RUNNING
.Lac_observe_state:
    test edi, edi
    cmovnz r8d, edi
    cmp r8d, AC_ENDED
    jne .Lac_observe_commit
    mov rax, [rbx+AC_BASE]
    add rax, [rbx+AC_REAL]
    cmp rax, rdx
    jne .Lac_observe_bad
.Lac_observe_commit:
    mov rcx, rbx
    call ac_publish
    test eax, eax
    jz .Lac_observe_return
    mov [rbx+AC_DEVICE], rsi
    mov [rbx+AC_HEAD], rbp
    jmp .Lac_observe_return
.Lac_observe_bad:
    xor eax, eax
.Lac_observe_return:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN audio_clock_observe

# Direct mode: caller already mapped the hardware cursor onto real media frames.
FN audio_clock_publish
    cmp qword ptr [rcx+AC_EPOCH], 0
    je .Lac_direct_bad
    cmp dword ptr [rcx+AC_MODE], 1
    jne .Lac_direct_bad
    cmp rdx, [rcx+AC_MEDIA]
    jb .Lac_direct_bad
    cmp rdx, [rcx+AC_LIMIT]
    ja .Lac_direct_bad
    jmp ac_publish
.Lac_direct_bad:
    xor eax, eax
    ret
ENDFN audio_clock_publish

# Freeze/change state without advancing media. EOF requires all real data heard.
FN audio_clock_status
    cmp qword ptr [rcx+AC_EPOCH], 0
    je .Lac_status_bad
    mov r8d, edx
    mov rdx, [rcx+AC_MEDIA]
    cmp r8d, AC_ENDED
    jne ac_publish
    cmp dword ptr [rcx+AC_MODE], 1
    je ac_publish
    mov rax, [rcx+AC_BASE]
    add rax, [rcx+AC_REAL]
    cmp rax, rdx
    je ac_publish
.Lac_status_bad:
    xor eax, eax
    ret
ENDFN audio_clock_status

# RCX=context,RDX=out40 {epoch,ns,state:u32,reserved0,frames,rate:u32,reserved0}.
# At most8 seqlock attempts; failure leaves output untouched. Explicit ordering
# fences also become DMB barriers in the Apple Silicon translation.
FN audio_clock_read
    push rbx
    push rbp
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
    mov ebp, 8
.Lac_read_retry:
    mov rbx, [rsi+AC_VERSION]
    test bl, 1
    jnz .Lac_read_again
    mfence
    mov r9, [rsi+AC_EPOCH]
    mov r10, [rsi+AC_MEDIA]
    mov r11d, [rsi+AC_STATE]
    mov r8d, [rsi+AC_RATE]
    mfence
    cmp rbx, [rsi+AC_VERSION]
    jne .Lac_read_again
    test r9, r9
    jz .Lac_read_bad
    test r8d, r8d
    jz .Lac_read_bad
    cmp r8d, 768000
    ja .Lac_read_bad
    mov rax, r10
    mov ecx, 1000000000
    mul rcx
    cmp rdx, r8
    jae .Lac_read_bad
    div r8
    test rax, rax
    js .Lac_read_bad
    mov [rdi], r9
    mov [rdi+8], rax
    mov [rdi+16], r11d
    mov dword ptr [rdi+20], 0
    mov [rdi+24], r10
    mov [rdi+32], r8d
    mov dword ptr [rdi+36], 0
    mov eax, 1
    jmp .Lac_read_return
.Lac_read_again:
    pause
    dec ebp
    jnz .Lac_read_retry
.Lac_read_bad:
    xor eax, eax
.Lac_read_return:
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN audio_clock_read
