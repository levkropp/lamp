# Original selected-video headers, edit list and sample-entry reader.
RODATA
.p2align 2
vm_table_types:
    .long VM_STSZ_TYPE,VM_STSZ, VM_STZ2_TYPE,VM_STSZ
    .long VM_STSC_TYPE,VM_STSC, VM_STCO_TYPE,VM_STCO
    .long VM_CO64_TYPE,VM_STCO, VM_STTS_TYPE,VM_STTS
    .long VM_CTTS_TYPE,VM_CTTS, VM_STSS_TYPE,VM_STSS, VM_STSD_TYPE,VM_STSD
.text

LOCALFN vm_headers
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rdx, [rbx+VM_MOOV]
    mov r8, [rbx+VM_MOOV_END]
    mov r9d, VM_MVHD_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_headers_bad
    mov rcx, rdx
    sub rcx, rax
    cmp rcx, 16
    jb .Lvm_headers_bad
    test dword ptr [rax], 0xffffff00
    jnz .Lvm_headers_bad
    cmp byte ptr [rax], 0
    je .Lvm_headers_scale0
    cmp byte ptr [rax], 1
    jne .Lvm_headers_bad
    cmp rcx, 24
    jb .Lvm_headers_bad
    add rax, 8
.Lvm_headers_scale0:
    mov eax, [rax+12]
    bswap eax
    test eax, eax
    jz .Lvm_headers_bad
    mov [rbx+VM_MOVIE_SCALE], eax
    mov rsi, [rbx+VM_MOOV]
    mov rdi, [rbx+VM_MOOV_END]
.Lvm_headers_tracks:
    cmp rsi, rdi
    je .Lvm_headers_selected
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call vm_box
    test eax, eax
    jz .Lvm_headers_zero
    mov rsi, r8
    cmp eax, VM_TRAK_TYPE
    jne .Lvm_headers_tracks
    mov rcx, rbx
    call vm_trak
    test eax, eax
    jz .Lvm_headers_zero
    jmp .Lvm_headers_tracks
.Lvm_headers_selected:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_headers_zero
    cmp dword ptr [rbx+VM_SELECTED], 1
    jne .Lvm_headers_unsupported
    mov rcx, rbx
    call vm_edits
    jmp .Lvm_headers_return
.Lvm_headers_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_headers_zero
.Lvm_headers_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_headers_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_headers_zero:
    xor eax, eax
.Lvm_headers_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_headers

# RCX=ctx,RDX/R8=trak payload/end. Count all video tracks; select one clear AVC.
LOCALFN vm_trak
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r9d, VM_TKHD_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_trak_bad
    sub rdx, rax
    cmp rdx, 20
    jb .Lvm_trak_bad
    movzx ecx, byte ptr [rax+3]
    and ecx, 1
    mov [rsp+36], ecx
    cmp byte ptr [rax], 0
    je .Lvm_trak_id0
    cmp byte ptr [rax], 1
    jne .Lvm_trak_bad
    cmp rdx, 32
    jb .Lvm_trak_bad
    add rax, 8
.Lvm_trak_id0:
    mov edx, [rax+12]
    bswap edx
    test edx, edx
    jz .Lvm_trak_bad
    mov [rsp+32], edx
    xor ecx, ecx
    mov eax, [rbx+VM_TRACK_COUNT]
    cmp eax, 256
    jae .Lvm_trak_limit
.Lvm_trak_unique:
    cmp ecx, eax
    jae .Lvm_trak_store
    cmp edx, [rbx+rcx*4+VM_TRACK_IDS]
    je .Lvm_trak_bad
    inc ecx
    jmp .Lvm_trak_unique
.Lvm_trak_store:
    mov [rbx+rax*4+VM_TRACK_IDS], edx
    inc dword ptr [rbx+VM_TRACK_COUNT]
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    mov r9d, VM_MDIA_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_trak_bad
    mov r12, rax
    mov r13, rdx
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    mov r9d, VM_HDLR_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_trak_bad
    sub rdx, rax
    cmp rdx, 12
    jb .Lvm_trak_bad
    cmp dword ptr [rax+8], VM_VIDE_TYPE
    jne .Lvm_trak_ok
    inc dword ptr [rbx+VM_VIDEO_COUNT]
    cmp dword ptr [rbx+VM_SELECTED], 0
    jne .Lvm_trak_ok
    mov eax, [rbx+VM_CHOICE]
    test eax, eax
    jz .Lvm_trak_default
    cmp eax, [rbx+VM_VIDEO_COUNT]
    jne .Lvm_trak_ok
    jmp .Lvm_trak_candidate
.Lvm_trak_default:
    cmp dword ptr [rsp+36], 0
    je .Lvm_trak_ok
.Lvm_trak_candidate:
    mov [rbx+VM_TRAK], rsi
    mov [rbx+VM_TRAK_END], rdi
    mov [rbx+VM_MDIA], r12
    mov [rbx+VM_MDIA_END], r13
    mov eax, [rsp+32]
    mov [rbx+VM_TRACK_ID], eax
    mov rcx, rbx
    call vm_candidate
    test eax, eax
    jnz .Lvm_trak_chosen
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_trak_zero
    cmp dword ptr [rbx+VM_CHOICE], 0
    je .Lvm_trak_ok
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_trak_zero
.Lvm_trak_chosen:
    mov dword ptr [rbx+VM_SELECTED], 1
.Lvm_trak_ok:
    mov eax, 1
    jmp .Lvm_trak_return
.Lvm_trak_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_trak_zero
.Lvm_trak_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_trak_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_trak_zero:
    xor eax, eax
.Lvm_trak_return:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_trak

LOCALFN vm_candidate
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov rdx, [rbx+VM_MDIA]
    mov r8, [rbx+VM_MDIA_END]
    mov r9d, VM_MDHD_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    sub rdx, rax
    cmp rdx, 24
    jb .Lvm_candidate_bad
    test dword ptr [rax], 0xffffff00
    jnz .Lvm_candidate_bad
    cmp byte ptr [rax], 0
    je .Lvm_candidate_scale0
    cmp byte ptr [rax], 1
    jne .Lvm_candidate_bad
    cmp rdx, 36
    jb .Lvm_candidate_bad
    add rax, 8
.Lvm_candidate_scale0:
    mov eax, [rax+12]
    bswap eax
    test eax, eax
    jz .Lvm_candidate_bad
    mov [rbx+VM_MEDIA_SCALE], eax
    mov rcx, rbx
    mov rdx, [rbx+VM_MDIA]
    mov r8, [rbx+VM_MDIA_END]
    mov r9d, VM_MINF_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    mov rsi, rax
    mov rdi, rdx
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    mov r9d, VM_DINF_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    mov rcx, rbx
    mov r8, rdx
    mov rdx, rax
    mov r9d, VM_DREF_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    mov rcx, rdx
    sub rcx, rax
    cmp rcx, 8
    jb .Lvm_candidate_bad
    cmp dword ptr [rax], 0
    jne .Lvm_candidate_bad
    cmp dword ptr [rax+4], 0x01000000
    jne .Lvm_candidate_unsupported
    mov rcx, rbx
    mov r8, rdx
    lea rdx, [rax+8]
    mov r12, r8
    call vm_box
    test eax, eax
    jz .Lvm_candidate_zero
    cmp r8, r12
    jne .Lvm_candidate_bad
    cmp eax, VM_URL_TYPE
    jne .Lvm_candidate_unsupported
    sub r8, rdx
    cmp r8, 4
    jne .Lvm_candidate_unsupported
    cmp dword ptr [rdx], 0x01000000 # Self-contained version0 URL, no pathname.
    jne .Lvm_candidate_unsupported
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    mov r9d, VM_STBL_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    mov [rbx+VM_STBL], rax
    mov [rbx+VM_STBL_END], rdx
    mov r12, rax
    mov r13, rdx
    lea rdi, [rbx+VM_STSZ]
    mov ecx, 12
    xor eax, eax
    rep stosq
    mov qword ptr [rbx+VM_STSD], 0
    mov qword ptr [rbx+VM_STSD_END], 0
    mov qword ptr [rbx+VM_STZ2], 0
.Lvm_candidate_tables:
    cmp r12, r13
    je .Lvm_candidate_entry
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    call vm_box
    test eax, eax
    jz .Lvm_candidate_zero
    mov r12, r8
    cmp eax, VM_SENC_TYPE
    je .Lvm_candidate_unsupported
    cmp eax, VM_SAIZ_TYPE
    je .Lvm_candidate_unsupported
    cmp eax, VM_SAIO_TYPE
    je .Lvm_candidate_unsupported
    lea r9, [rip+vm_table_types]
    mov ecx, 9
.Lvm_candidate_type:
    cmp eax, [r9]
    je .Lvm_candidate_table
    add r9, 8
    dec ecx
    jnz .Lvm_candidate_type
    jmp .Lvm_candidate_tables
.Lvm_candidate_table:
    mov r10d, [r9+4]
    cmp qword ptr [rbx+r10], 0
    jne .Lvm_candidate_bad
    mov [rbx+r10], rdx
    mov [rbx+r10+8], r8
    cmp eax, VM_STZ2_TYPE
    jne .Lvm_candidate_co64
    mov dword ptr [rbx+VM_STZ2], 1
.Lvm_candidate_co64:
    cmp eax, VM_CO64_TYPE
    jne .Lvm_candidate_tables
    mov dword ptr [rbx+VM_CO64], 1
    jmp .Lvm_candidate_tables
.Lvm_candidate_entry:
    mov rdx, [rbx+VM_STSD]
    test rdx, rdx
    jz .Lvm_candidate_bad
    mov r8, [rbx+VM_STSD_END]
    mov rax, r8
    sub rax, rdx
    cmp rax, 8
    jb .Lvm_candidate_bad
    cmp dword ptr [rdx], 0
    jne .Lvm_candidate_bad
    cmp dword ptr [rdx+4], 0x01000000
    jne .Lvm_candidate_unsupported
    mov r13, r8
    add rdx, 8
    mov rcx, rbx
    call vm_box
    test eax, eax
    jz .Lvm_candidate_zero
    cmp r8, r13
    jne .Lvm_candidate_bad
    cmp eax, VM_AVC1_TYPE
    je .Lvm_candidate_avc
    cmp eax, VM_AVC3_TYPE
    jne .Lvm_candidate_unsupported
.Lvm_candidate_avc:
    mov rax, r8
    sub rax, rdx
    cmp rax, 78
    jb .Lvm_candidate_bad
    cmp word ptr [rdx+6], 0x0100
    jne .Lvm_candidate_unsupported
    add rdx, 78
    mov r12, rdx
    mov r13, r8
    mov rcx, rbx
    mov r9d, VM_SINF_TYPE
    call vm_child
    test rax, rax
    jnz .Lvm_candidate_unsupported
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_candidate_zero
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    mov r9d, VM_AVCC_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_candidate_bad
    sub rdx, rax
    cmp rdx, 7
    jb .Lvm_candidate_bad
    cmp rdx, 8207
    ja .Lvm_candidate_limit
    mov [rbx+VM_CONFIG], rax
    mov [rbx+VM_CONFIG_BYTES], edx
    mov dword ptr [rbx+VM_CODEC], 1
    mov eax, 1
    jmp .Lvm_candidate_return
.Lvm_candidate_unsupported:
.Lvm_candidate_zero:
    xor eax, eax
    jmp .Lvm_candidate_return
.Lvm_candidate_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_candidate_zero
.Lvm_candidate_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_candidate_zero
    mov dword ptr [rbx+VM_ERROR], 1
    jmp .Lvm_candidate_zero
.Lvm_candidate_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vm_candidate

LOCALFN vm_edits
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rdx, [rbx+VM_TRAK]
    mov r8, [rbx+VM_TRAK_END]
    mov r9d, VM_EDTS_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_edits_optional
    mov rcx, rbx
    mov r8, rdx
    mov rdx, rax
    mov r9d, VM_ELST_TYPE
    call vm_child
    test rax, rax
    jz .Lvm_edits_optional
    mov rdi, rdx
    sub rdx, rax
    cmp rdx, 8
    jb .Lvm_edits_bad
    test dword ptr [rax], 0xffffff00
    jnz .Lvm_edits_bad
    movzx ebp, byte ptr [rax]
    cmp ebp, 1
    ja .Lvm_edits_unsupported
    mov ecx, [rax+4]
    bswap ecx
    cmp ecx, 4096
    ja .Lvm_edits_limit
    mov esi, ecx
    mov edx, 12
    test ebp, ebp
    jz .Lvm_edits_size
    mov edx, 20
.Lvm_edits_size:
    imul rcx, rdx
    lea rdx, [rax+rcx+8]
    cmp rdx, rdi
    jne .Lvm_edits_bad
    lea rdi, [rax+8]
    test esi, esi
    jz .Lvm_edits_optional
.Lvm_edits_next:
    mov rax, [rbx+VM_CANCEL]
    test rax, rax
    jz .Lvm_edits_entry
    cmp dword ptr [rax], 0
    jne .Lvm_edits_cancel
.Lvm_edits_entry:
    test ebp, ebp
    jnz .Lvm_edits64
    mov r8d, [rdi]
    bswap r8d
    mov edx, [rdi+4]
    bswap edx
    movsxd rdx, edx
    mov ecx, [rdi+8]
    add rdi, 12
    jmp .Lvm_edits_rate
.Lvm_edits64:
    mov r8, [rdi]
    bswap r8
    mov rdx, [rdi+8]
    bswap rdx
    mov ecx, [rdi+16]
    add rdi, 20
.Lvm_edits_rate:
    cmp ecx, 0x00000100
    jne .Lvm_edits_unsupported
    cmp dword ptr [rbx+VM_EDIT_FOUND], 0
    jne .Lvm_edits_unsupported
    cmp rdx, -1
    jne .Lvm_edits_media
    add [rbx+VM_GAP_UNITS], r8
    jc .Lvm_edits_limit
    jmp .Lvm_edits_advance
.Lvm_edits_media:
    test rdx, rdx
    js .Lvm_edits_unsupported
    mov [rbx+VM_MEDIA_START], rdx
    mov [rbx+VM_EDIT_DURATION], r8
    mov dword ptr [rbx+VM_EDIT_FOUND], 1
.Lvm_edits_advance:
    dec esi
    jnz .Lvm_edits_next
    #1=active segment,2=empty edits only. Active duration0 spans subsequent media.
    cmp dword ptr [rbx+VM_EDIT_FOUND], 0
    jne .Lvm_edits_optional
    mov dword ptr [rbx+VM_EDIT_FOUND], 2
.Lvm_edits_optional:
    xor eax, eax
    cmp dword ptr [rbx+VM_ERROR], 0
    sete al
    jmp .Lvm_edits_return
.Lvm_edits_cancel:
    mov dword ptr [rbx+VM_ERROR], 61
    jmp .Lvm_edits_zero
.Lvm_edits_limit:
    mov dword ptr [rbx+VM_ERROR], 3
    jmp .Lvm_edits_zero
.Lvm_edits_unsupported:
    mov dword ptr [rbx+VM_ERROR], 2
    jmp .Lvm_edits_zero
.Lvm_edits_bad:
    cmp dword ptr [rbx+VM_ERROR], 0
    jne .Lvm_edits_zero
    mov dword ptr [rbx+VM_ERROR], 1
.Lvm_edits_zero:
    xor eax, eax
.Lvm_edits_return:
    add rsp, 40
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN vm_edits
