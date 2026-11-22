# Original bounded native .wv/.wvc association and ownership. MIT.
# The optional companion is the input pathname plus "c", as libwavpack uses.
.equ WVC_MAX_FRAMES, 1048576
.data
wv_file_index: .quad 0              # sorted main-frame pointer, companion pointer, bytes
wv_file_count: .quad 0
wv_file_map: .quad 0
wv_file_bytes: .quad 0
wv_file_token: .quad 0
.bss
wv_companion_path: .zero 65536
.text
FN wv_correction_file_close
    sub rsp, 40
    mov rcx, [rip+wv_file_index]
    test rcx, rcx
    jz .Lwvc_close_map
    call mem_free
.Lwvc_close_map:
    mov qword ptr [rip+wv_file_index], 0
    mov qword ptr [rip+wv_file_count], 0
    mov dword ptr [rip+wv_pair_mode], 0
    mov dword ptr [rip+wv_corr_active], 0
    mov rcx, [rip+wv_file_map]
    test rcx, rcx
    jz .Lwvc_close_done
    mov rdx, [rip+wv_file_bytes]
    mov r8, [rip+wv_file_token]
    call file_unmap
.Lwvc_close_done:
    mov qword ptr [rip+wv_file_map], 0
    mov qword ptr [rip+wv_file_bytes], 0
    mov qword ptr [rip+wv_file_token], 0
    add rsp, 40
    ret
ENDFN wv_correction_file_close

# RCX=cursor, RDX=end -> RAX=next audio frame start, RDX=bytes, R8=next
# cursor, R9D=1 frame, 0 end, -1 malformed/cancelled. Metadata-only blocks
# before frames are skipped. Like native .wv opening, non-wvpk tails end it.
LOCALFN wv_native_frame
    mov r10, rcx
    xor r11d, r11d                      # first audio block in the frame
.Lwvc_native_block:
    mov rax, [rip+ogg_cancel_ptr]
    test rax, rax
    jz .Lwvc_native_continue
    cmp dword ptr [rax], 0
    jne .Lwvc_native_bad
.Lwvc_native_continue:
    mov rax, rdx
    sub rax, r10
    cmp rax, 32
    jb .Lwvc_native_end
    cmp dword ptr [r10], 0x6b707677
    jne .Lwvc_native_end
    mov ecx, [r10+4]
    cmp ecx, 24
    jb .Lwvc_native_bad
    cmp ecx, 1048576
    ja .Lwvc_native_bad
    lea r8, [rcx+8]
    cmp r8, rax
    ja .Lwvc_native_bad
    movzx ecx, word ptr [r10+8]
    sub ecx, 0x402
    cmp ecx, 0xe
    ja .Lwvc_native_bad
    cmp dword ptr [r10+20], 0
    jne .Lwvc_native_audio
    test r11, r11
    jnz .Lwvc_native_audio
    add r10, r8
    jmp .Lwvc_native_block
.Lwvc_native_audio:
    test r11, r11
    cmovz r11, r10
    mov eax, [r10+24]
    add r10, r8
    test eax, F_FINAL
    jz .Lwvc_native_block
    mov rax, r11
    mov rdx, r10
    sub rdx, r11
    mov r8, r10
    mov r9d, 1
    ret
.Lwvc_native_end:
    xor eax, eax
    xor edx, edx
    mov r8, r10
    xor r9d, r9d
    test r11, r11
    jz .Lwvc_native_return
.Lwvc_native_bad:
    mov r9d, -1
.Lwvc_native_return:
    ret
ENDFN wv_native_frame

# RCX=native pathname, RDX=main map, R8=end. Called only after the main
# track is opened and indexed. Missing companions retain hybrid lossy mode;
# present but unreadable/empty/mismatched companions fail instead of fallback.
FN wv_correction_file_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    call wv_correction_file_close
    cmp dword ptr [rip+wv_matroska], 0
    jne .Lwvc_file_ok
    mov rcx, rsi
    mov rdx, rdi
    call adts_skip_id3
    mov rsi, rax
    mov rcx, rsi
    mov rdx, rdi
    call wv_native_frame
    cmp r9d, 1
    jne .Lwvc_file_bad
    test dword ptr [rax+24], F_HYBRID
    jz .Lwvc_file_ok
    lea rdx, [rip+wv_companion_path]
    xor ecx, ecx
.Lwvc_file_path:
.ifdef WINDOWS
    cmp ecx, 32766
    jae .Lwvc_file_limit
    movzx eax, word ptr [rbx+rcx*2]
    mov [rdx+rcx*2], ax
.else
    cmp ecx, 65534
    jae .Lwvc_file_limit
    movzx eax, byte ptr [rbx+rcx]
    mov [rdx+rcx], al
.endif
    test eax, eax
    jz .Lwvc_file_path_end
    inc ecx
    jmp .Lwvc_file_path
.Lwvc_file_path_end:
.ifdef WINDOWS
    mov dword ptr [rdx+rcx*2], 'c'
.else
    mov word ptr [rdx+rcx], 'c'
.endif
    lea rcx, [rip+wv_companion_path]
    call file_map
    test rax, rax
    jnz .Lwvc_file_mapped
    cmp r9d, 1
    je .Lwvc_file_ok
    jmp .Lwvc_file_bad
.Lwvc_file_mapped:
    mov [rip+wv_file_map], rax
    mov [rip+wv_file_bytes], rdx
    mov [rip+wv_file_token], r8
    mov r15, rax
    mov r12, [rip+track_count]
    test r12, r12
    jz .Lwvc_file_bad
    cmp r12, WVC_MAX_FRAMES
    ja .Lwvc_file_limit
    imul rcx, r12, 24
    call mem_alloc
    test rax, rax
    jz .Lwvc_file_bad
    mov r13, rax
    mov [rip+wv_file_index], rax
    xor r14d, r14d
.Lwvc_file_frame:
    mov rcx, rsi
    mov rdx, rdi
    call wv_native_frame
    cmp r9d, 1
    jne .Lwvc_file_bad
    mov [rsp+48], rax
    mov rsi, r8
    mov rcx, r15
    mov rdx, [rip+wv_file_map]
    add rdx, [rip+wv_file_bytes]
    call wv_native_frame
    cmp r9d, 1
    jne .Lwvc_file_bad
    mov r15, r8
    mov ecx, -1
    cmp rdx, rcx
    ja .Lwvc_file_limit
    imul rcx, r14, 24
    add rcx, r13
    mov r8, [rsp+48]
    mov [rcx], r8
    mov [rcx+8], rax
    mov [rcx+16], rdx
    inc r14
    cmp r14, r12
    jb .Lwvc_file_frame
    mov rcx, r15
    mov rdx, [rip+wv_file_map]
    add rdx, [rip+wv_file_bytes]
    call wv_native_frame
    test r9d, r9d
    jne .Lwvc_file_bad
    mov [rip+wv_file_count], r12
.Lwvc_file_ok:
    mov eax, 1
    jmp .Lwvc_file_return
.Lwvc_file_limit:
    mov dword ptr [rip+decode_error], WV_UNSUPPORTED
    jmp .Lwvc_file_failed
.Lwvc_file_bad:
    mov dword ptr [rip+decode_error], WV_MALFORMED
.Lwvc_file_failed:
    call wv_correction_file_close
    xor eax, eax
.Lwvc_file_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN wv_correction_file_open

# RCX=main frame pointer -> RAX=companion frame, EDX=its bytes; 0 missing.
LOCALFN wv_correction_lookup
    xor r10d, r10d
    mov r11, [rip+wv_file_count]
    mov r8, [rip+wv_file_index]
.Lwvc_lookup:
    cmp r10, r11
    jae .Lwvc_lookup_missing
    lea r9, [r10+r11]
    shr r9, 1
    imul rax, r9, 24
    add rax, r8
    cmp [rax], rcx
    je .Lwvc_lookup_found
    ja .Lwvc_lookup_before
    lea r10, [r9+1]
    jmp .Lwvc_lookup
.Lwvc_lookup_before:
    mov r11, r9
    jmp .Lwvc_lookup
.Lwvc_lookup_found:
    mov edx, [rax+16]
    mov rax, [rax+8]
    ret
.Lwvc_lookup_missing:
    xor eax, eax
    xor edx, edx
    ret
ENDFN wv_correction_lookup
