# Original AAC program-configuration reader and channel map. MIT.
# PCE syntax: ISO/IEC 14496-3 tables 4.1/4.2. Element tags identify channels;
# packet order never changes their overlap/SBR history or speaker positions.
# The existing decoder supports up to eight channels, mixed to stereo.
.equ AP_COUNT, 0
.equ AP_CHANNELS, 4
.equ AP_MASK, 8
.equ AP_TAG, 12
.equ AP_TYPES, 16                    # eight element types
.equ AP_FIRST, 24                    # first channel of each element
.equ AP_SPEAKERS, 32                 # WAVE speaker bit for each channel
.equ AP_WAVE, 40                     # channel -> rank in WAVE mask
.equ AP_LOOKUP, 48                   # type*16 + tag -> element, 255 absent
.equ AP_SIZE, 112
.bss
.p2align 4
aac_map: .zero AP_SIZE
aac_pce_temp: .zero AP_SIZE
aac_seen_elements: .zero 4
aac_current_element: .zero 4
.text
# Initialize the same indexed layouts as before; their tags remain implicit.
LOCALFN aac_default_map
    lea r8, [rip + aac_map]
    xor ecx, ecx
    xor eax, eax
.Laac_default_clear:
    mov [r8 + rcx], rax
    add ecx, 8
    cmp ecx, AP_SIZE
    jb .Laac_default_clear
    mov eax, [rip + aac_config]
    lea r9, [rip + aac_config_channels]
    movzx edx, byte ptr [r9 + rax]
    mov [r8 + AP_CHANNELS], edx
    lea r9, [rip + alac_masks]
    mov ecx, [r9 + rdx*4 - 4]
    mov [r8 + AP_MASK], ecx
    lea r9, [rip + alac_wave_index]
    mov rcx, [r9 + rdx*8 - 8]
    mov [r8 + AP_WAVE], rcx
    lea r9, [rip + aac_config_elements]
    movzx edx, byte ptr [r9 + rax]
    mov [r8 + AP_COUNT], edx
    dec eax
    imul eax, eax, 6
    lea r9, [rip + aac_layouts]
    add r9, rax
    xor ecx, ecx
    xor r10d, r10d
.Laac_default_element:
    movzx eax, byte ptr [r9 + rcx]
    mov [r8 + AP_TYPES + rcx], al
    mov [r8 + AP_FIRST + rcx], r10b
    inc r10d
    cmp eax, 1
    jne .Laac_default_next
    inc r10d
.Laac_default_next:
    inc ecx
    cmp ecx, edx
    jb .Laac_default_element
    ret
ENDFN aac_default_map

LOCALFN aac_pce_commit
    lea rcx, [rip + aac_pce_temp]
    lea rdx, [rip + aac_map]
    xor r8d, r8d
.Laac_pce_commit_copy:
    mov rax, [rcx + r8]
    mov [rdx + r8], rax
    add r8d, 8
    cmp r8d, AP_SIZE
    jb .Laac_pce_commit_copy
    ret
ENDFN aac_pce_commit

# Read into scratch. A failure or unsupported replacement leaves the active
# map intact. No allocation, unbounded list or borrowed input pointer.
LOCALFN aac_pce_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    lea rdi, [rip + aac_pce_temp]
    xor eax, eax
    mov ecx, AP_LOOKUP/8
    rep stosq
    mov rax, -1
    mov ecx, 8
    rep stosq
    lea rbx, [rip + aac_pce_temp]
    mov ecx, 4
    call aac_get
    mov [rbx + AP_TAG], eax
    mov ecx, 2
    call aac_get
    cmp eax, 1                       # object_type: AAC-LC
    jne .Laac_pce_unsupported
    mov ecx, 4
    call aac_get
    cmp eax, [rip + aac_rate_index]
    jne .Laac_pce_bad
    xor esi, esi
.Laac_pce_counts:
    mov ecx, 4
    cmp esi, 3
    jb .Laac_pce_count_bits
    mov ecx, 2
.Laac_pce_count_bits:
    call aac_get
    mov [rsp + rsi*4 + 32], eax       # front, side, back, LFE element counts
    inc esi
    cmp esi, 4
    jb .Laac_pce_counts
    mov ecx, 3
    call aac_get
    mov [rsp + 48], eax              # associated-data tags to skip
    mov ecx, 4
    call aac_get
    test eax, eax
    jnz .Laac_pce_unsupported         # coupling remains unsupported
    mov ecx, 1
    call aac_get
    shl eax, 2
    mov ecx, eax
    call aac_get                     # mono_mixdown_element_number
    mov ecx, 1
    call aac_get
    shl eax, 2
    mov ecx, eax
    call aac_get                     # stereo_mixdown_element_number
    mov ecx, 1
    call aac_get
    lea ecx, [rax + rax*2]
    call aac_get                     # matrix_mixdown_idx / pseudo_surround
    xor r12d, r12d                   # element slot
    xor r13d, r13d                   # channel slot
    xor r14d, r14d                   # speaker group
.Laac_pce_group:
    mov [rsp + 52], r12d             # first element of this group
    mov r15d, r13d                   # first channel of this group
    mov esi, [rsp + r14*4 + 32]
.Laac_pce_element:
    test esi, esi
    jz .Laac_pce_group_done
    cmp r12d, 8
    jae .Laac_pce_unsupported
    cmp r13d, 8
    jae .Laac_pce_unsupported
    mov edi, 3
    cmp r14d, 3
    je .Laac_pce_lfe
    mov ecx, 1
    call aac_get
    mov edi, eax
.Laac_pce_lfe:
    mov ecx, 4
    call aac_get
    mov edx, edi
    shl edx, 4
    add edx, eax
    cmp byte ptr [rbx + AP_LOOKUP + rdx], 255
    jne .Laac_pce_bad                 # duplicate tag within its element type
    mov [rbx + AP_LOOKUP + rdx], r12b
    mov [rbx + AP_TYPES + r12], dil
    mov [rbx + AP_FIRST + r12], r13b
    inc r13d
    cmp edi, 1
    jne .Laac_pce_element_next
    inc r13d
    cmp r13d, 8
    ja .Laac_pce_unsupported
.Laac_pce_element_next:
    inc r12d
    dec esi
    jmp .Laac_pce_element
.Laac_pce_group_done:
    mov eax, r13d
    sub eax, r15d                    # channels in this group
    test eax, eax
    jz .Laac_pce_group_next
    cmp r14d, 1
    je .Laac_pce_side
    cmp r14d, 2
    je .Laac_pce_back
    cmp r14d, 3
    je .Laac_pce_lfe_position
    cmp eax, 5
    ja .Laac_pce_unsupported
    jmp .Laac_pce_horizontal
.Laac_pce_side:
    cmp eax, 2
    jne .Laac_pce_unsupported
    mov word ptr [rbx + AP_SPEAKERS + r15], 0x0a09
    jmp .Laac_pce_group_next
.Laac_pce_back:
    cmp eax, 3
    ja .Laac_pce_unsupported
.Laac_pce_horizontal:
    mov esi, eax                     # channel count in front/back group
    mov edx, -1                      # unpaired SCE: center channel
    mov r8d, [rsp + 52]
    xor r10d, r10d                   # length of the current SCE run
.Laac_pce_center_scan:
    cmp r8d, r12d
    jae .Laac_pce_center_boundary
    cmp byte ptr [rbx + AP_TYPES + r8], 1
    je .Laac_pce_center_boundary
    movzx eax, byte ptr [rbx + AP_FIRST + r8]
    test r10d, r10d
    jnz .Laac_pce_center_run
    mov r9d, eax
.Laac_pce_center_run:
    mov r11d, eax
    inc r10d
    jmp .Laac_pce_center_next
.Laac_pce_center_boundary:
    test r10d, 1
    jz .Laac_pce_center_even
    cmp edx, -1
    jne .Laac_pce_unsupported         # two unpaired SCE runs straddle a CPE
    mov edx, r9d                     # front: first unpaired single
    test r14d, r14d
    jz .Laac_pce_center_even
    mov edx, r11d                    # back: last unpaired single
.Laac_pce_center_even:
    xor r10d, r10d
.Laac_pce_center_next:
    inc r8d
    cmp r8d, r12d
    jbe .Laac_pce_center_scan
    cmp edx, -1
    je .Laac_pce_horizontal_pairs
    dec esi
.Laac_pce_horizontal_pairs:
    xor r8d, r8d                     # position among paired channels
.Laac_pce_horizontal_channel:
    cmp r15d, edx
    je .Laac_pce_horizontal_center
    mov eax, r8d
    test r14d, r14d
    jnz .Laac_pce_horizontal_back
    cmp esi, 4
    jne .Laac_pce_horizontal_store
    add eax, 6                       # two front pairs: Lc/Rc then L/R
    cmp r8d, 2
    jb .Laac_pce_horizontal_store
    sub eax, 8
    jmp .Laac_pce_horizontal_store
.Laac_pce_horizontal_back:
    add eax, 4
.Laac_pce_horizontal_store:
    inc r8d
    jmp .Laac_pce_horizontal_write
.Laac_pce_horizontal_center:
    mov eax, 2
    test r14d, r14d
    jz .Laac_pce_horizontal_write
    mov eax, 8
.Laac_pce_horizontal_write:
    mov [rbx + AP_SPEAKERS + r15], al
    inc r15d
    cmp r15d, r13d
    jb .Laac_pce_horizontal_channel
    jmp .Laac_pce_group_next
.Laac_pce_lfe_position:
    cmp eax, 1
    jne .Laac_pce_unsupported
    mov byte ptr [rbx + AP_SPEAKERS + r15], 3
.Laac_pce_group_next:
    inc r14d
    cmp r14d, 4
    jb .Laac_pce_group
    test r13d, r13d
    jz .Laac_pce_bad
    mov [rbx + AP_COUNT], r12d
    mov [rbx + AP_CHANNELS], r13d
    # A CPE must occupy a whole left/right pair, never straddle groups or a
    # center/LFE position. Two adjacent SCEs may form the same stereo pair.
    xor esi, esi
.Laac_pce_check_pairs:
    cmp byte ptr [rbx + AP_TYPES + rsi], 1
    jne .Laac_pce_pair_next
    movzx eax, byte ptr [rbx + AP_FIRST + rsi]
    movzx edx, byte ptr [rbx + AP_SPEAKERS + rax]
    cmp edx, 0
    je .Laac_pce_pair_right
    cmp edx, 4
    je .Laac_pce_pair_right
    cmp edx, 6
    je .Laac_pce_pair_right
    cmp edx, 9
    jne .Laac_pce_unsupported
.Laac_pce_pair_right:
    inc edx
    cmp dl, [rbx + AP_SPEAKERS + rax + 1]
    jne .Laac_pce_unsupported
.Laac_pce_pair_next:
    inc esi
    cmp esi, r12d
    jb .Laac_pce_check_pairs
    xor esi, esi
    xor edi, edi
.Laac_pce_mask:
    movzx eax, byte ptr [rbx + AP_SPEAKERS + rsi]
    bts edi, eax
    jc .Laac_pce_bad
    inc esi
    cmp esi, r13d
    jb .Laac_pce_mask
    mov [rbx + AP_MASK], edi
    xor esi, esi
.Laac_pce_wave:
    movzx ecx, byte ptr [rbx + AP_SPEAKERS + rsi]
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, edi
    xor edx, edx
.Laac_pce_rank:
    test eax, eax
    jz .Laac_pce_ranked
    lea ecx, [rax - 1]
    and eax, ecx
    inc edx
    jmp .Laac_pce_rank
.Laac_pce_ranked:
    mov [rbx + AP_WAVE + rsi], dl
    inc esi
    cmp esi, r13d
    jb .Laac_pce_wave
    mov eax, [rsp + 48]
    shl eax, 2
    add [rip + aac_pos], rax          # associated-data elements
    mov rax, [rip + aac_pos]
    add rax, 7
    and rax, -8
    mov [rip + aac_pos], rax          # relative to ASC or raw_data_block start
    mov ecx, 8
    call aac_get
    shl eax, 3
    add [rip + aac_pos], rax          # comment bytes
    call aac_inside
    test eax, eax
    jz .Laac_pce_bad
    mov eax, 1
    jmp .Laac_pce_return
.Laac_pce_unsupported:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
    jmp .Laac_pce_failed
.Laac_pce_bad:
    mov dword ptr [rip + decode_error], AAC_MALFORMED
.Laac_pce_failed:
    xor eax, eax
.Laac_pce_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN aac_pce_read

# Repeated PCEs may alter comments/mixdown hints, but changing the program's
# topology or tags requires a new track. Parse fully before comparing.
LOCALFN aac_program_config
    sub rsp, 40
    cmp dword ptr [rip + aac_config], 0
    jne .Laac_pce_skip_fixed
    call aac_pce_read
    test eax, eax
    jz .Laac_program_return
    lea rcx, [rip + aac_map]
    lea rdx, [rip + aac_pce_temp]
    xor r8d, r8d
.Laac_program_compare:
    mov rax, [rcx + r8]
    cmp rax, [rdx + r8]
    jne .Laac_program_changed
    add r8d, 8
    cmp r8d, AP_SIZE
    jb .Laac_program_compare
    mov eax, 1
    jmp .Laac_program_return
.Laac_program_changed:
    mov dword ptr [rip + decode_error], AAC_UNSUPPORTED
    xor eax, eax
    jmp .Laac_program_return
.Laac_pce_skip_fixed:
    call aac_skip_program_config
.Laac_program_return:
    add rsp, 40
    ret
ENDFN aac_program_config
