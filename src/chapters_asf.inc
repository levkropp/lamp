# Original ASF Marker Object reader. MIT, see LICENSE.
# The documented Entry Length excludes Offset/Presentation Time/itself;
# Name Length is bytes, Description Length is UTF-16 units. Preroll is ms.
# First structurally valid Marker Object wins. Preflight precedes publication.
RODATA
aschap_file: .quad 0x11cfa9478cabdca1, 0x6553200cc000e48e
.data
aschap_seen: .long 0
aschap_time_valid: .long 0
aschap_records_left: .long 0
.p2align 3
aschap_preroll: .quad 0             # 100 ns units, checked multiplication

.text
# RCX=Header children, RDX=end. Discover the top-level File Properties
# first, independently of header order. Unknown objects skip in O(1).
LOCALFN aschap_setup
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ebx, ASF_TAG_OBJECTS
    mov dword ptr [rip + aschap_seen], 0
    mov dword ptr [rip + aschap_time_valid], 1
    mov dword ptr [rip + aschap_records_left], ASF_TAG_RECORDS
    mov qword ptr [rip + aschap_preroll], 0
.Laschap_setup_next:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Laschap_setup_bound
    cmp dword ptr [rax], 0
    jne .Laschap_setup_done
.Laschap_setup_bound:
    mov rax, rdi
    sub rax, rsi
    cmp rax, 24
    jb .Laschap_setup_done
    test ebx, ebx
    jz .Laschap_setup_done
    dec ebx
    mov r9, [rsi + 16]
    cmp r9, 24
    jb .Laschap_setup_done
    cmp r9, rax
    ja .Laschap_setup_done
    mov rcx, rsi
    lea rdx, [rip + aschap_file]
    call astag_guid
    jnz .Laschap_setup_advance
    cmp r9, 104
    jb .Laschap_setup_advance
    mov rax, [rsi + 80]
    mov ecx, 10000
    mul rcx
    test rdx, rdx
    jnz .Laschap_setup_overflow
    mov [rip + aschap_preroll], rax
    jmp .Laschap_setup_done
.Laschap_setup_overflow:
    mov dword ptr [rip + aschap_time_valid], 0
    jmp .Laschap_setup_done
.Laschap_setup_advance:
    add rsi, r9
    jmp .Laschap_setup_next
.Laschap_setup_done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aschap_setup

# RCX=entry, RDX=end -> RAX=next or 0, R9=presentation (100 ns),
# R10=description, R11D=description bytes. Only volatile registers changed.
LOCALFN aschap_record
    mov rax, rdx
    sub rax, rcx
    cmp rax, 30
    jb .Laschap_record_bad
    mov r11d, [rcx + 26]
    shl r11, 1
    lea r8, [r11 + 30]
    cmp r8, rax
    ja .Laschap_record_bad
    lea rax, [r11 + 12]
    movzx r9d, word ptr [rcx + 16]
    cmp rax, r9
    jne .Laschap_record_bad
    mov r9, [rcx + 8]
    lea r10, [rcx + 30]
    lea rax, [r10 + r11]
    ret
.Laschap_record_bad:
    xor eax, eax
    ret
ENDFN aschap_record

# RCX=Marker Object body, RDX=end. Invalid optional fields leave chapters,
# tags, cover and audio untouched. A separate marker budget bounds all
# preflight work; CHAP_MAX bounds publication and the existing title arena.
LOCALFN aschap_markers
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    cmp dword ptr [rip + aschap_seen], 0
    jne .Laschap_markers_done
    mov rdi, rdx
    sub rdx, rcx
    cmp rdx, 24
    jb .Laschap_markers_done
    mov ebx, [rcx + 16]
    cmp ebx, [rip + aschap_records_left]
    ja .Laschap_markers_done
    sub [rip + aschap_records_left], ebx
    movzx eax, word ptr [rcx + 22]
    test al, 1
    jnz .Laschap_markers_done
    add rax, 24
    cmp rax, rdx
    ja .Laschap_markers_done
    lea r12, [rcx + rax]
    mov rsi, r12
    mov r13d, ebx
.Laschap_preflight:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Laschap_preflight_count
    cmp dword ptr [rax], 0
    jne .Laschap_markers_done
.Laschap_preflight_count:
    test r13d, r13d
    jz .Laschap_preflight_end
    mov rcx, rsi
    mov rdx, rdi
    call aschap_record
    test rax, rax
    jz .Laschap_markers_done
    mov rsi, rax
    dec r13d
    jmp .Laschap_preflight
.Laschap_preflight_end:
    cmp rsi, rdi
    jne .Laschap_markers_done
    mov dword ptr [rip + aschap_seen], 1
    cmp dword ptr [rip + aschap_time_valid], 0
    je .Laschap_markers_done
    mov rsi, r12
    xor r12d, r12d
.Laschap_publish:
    cmp r12d, ebx
    jae .Laschap_markers_done
    cmp dword ptr [rip + chap_count], CHAP_MAX
    jae .Laschap_markers_done
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Laschap_publish_entry
    cmp dword ptr [rax], 0
    jne .Laschap_markers_done
.Laschap_publish_entry:
    mov rcx, rsi
    mov rdx, rdi
    call aschap_record                 # all entries already bounded
    mov rsi, rax
    mov [rsp + 32], r10
    mov [rsp + 40], r11d
    mov rax, r9
    sub rax, [rip + aschap_preroll]
    jc .Laschap_publish_next           # before the presented timeline
    mov ecx, 100
    mul rcx
    test rdx, rdx
    jnz .Laschap_publish_next          # nanoseconds cannot be represented
    mov rcx, rax
    mov edx, r12d
    call chap_new
    cmp eax, -1
    je .Laschap_markers_done
    mov r13d, eax
    mov rcx, [rsp + 32]
    mov edx, [rsp + 40]
    xor r8d, r8d
    call tag_utf16
    mov ecx, r13d
    mov r8d, edx
    mov rdx, rax
    call chap_set_title
.Laschap_publish_next:
    inc r12d
    jmp .Laschap_publish
.Laschap_markers_done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aschap_markers
