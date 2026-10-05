# Header setup; scalar trees and vector lookup tables are expanded once.
LOCALFN vb_setup
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 104
    VB_GET 8
    inc eax
    mov [rip + vb_books_count], eax
    xor r12d, r12d
.Lvb_setup_book:
    mov eax, r12d
    shl eax, 6
    lea rsi, [rip + vb_books]
    add rsi, rax
    mov qword ptr [rsi + CB_VECTOR], 0
    mov dword ptr [rsi + 56], 0
    VB_GET 24
    cmp eax, 0x564342
    jne .Lvb_setup_bad
    VB_GET 16
    test eax, eax
    jz .Lvb_setup_bad
    cmp eax, 256
    ja .Lvb_setup_bad
    mov [rsi + CB_DIM], eax
    VB_GET 24
    test eax, eax
    jz .Lvb_setup_bad
    cmp eax, 65536
    ja .Lvb_setup_bad
    mov [rsi + CB_ENTRIES], eax
    call vb_alloc
    test rax, rax
    jz .Lvb_setup_bad
    mov [rsi + CB_LENGTH], rax
    mov rdi, rax
    mov dword ptr [rip + vb_lengths_total], 1
    VB_GET 1
    test eax, eax
    jz .Lvb_setup_unordered
    VB_GET 5
    inc eax
    mov r13d, eax
    xor ebx, ebx
.Lvb_setup_ordered:
    cmp r13d, 32
    ja .Lvb_setup_bad
    mov eax, [rsi + CB_ENTRIES]
    sub eax, ebx
    call vb_ilog
    call vb_bits
    mov edx, [rsi + CB_ENTRIES]
    sub edx, ebx
    cmp eax, edx
    ja .Lvb_setup_bad
    mov edx, eax
.Lvb_setup_ordered_fill:
    test edx, edx
    jz .Lvb_setup_ordered_next
    mov [rdi + rbx], r13b
    add [rip + vb_lengths_total], r13d
    inc ebx
    dec edx
    jmp .Lvb_setup_ordered_fill
.Lvb_setup_ordered_next:
    inc r13d
    cmp ebx, [rsi + CB_ENTRIES]
    jb .Lvb_setup_ordered
    jmp .Lvb_setup_tree
.Lvb_setup_unordered:
    VB_GET 1
    mov r13d, eax
    xor ebx, ebx
.Lvb_setup_length:
    test r13d, r13d
    jz .Lvb_setup_present
    VB_GET 1
    test eax, eax
    jz .Lvb_setup_length_next
.Lvb_setup_present:
    VB_GET 5
    inc eax
    mov [rdi + rbx], al
    add [rip + vb_lengths_total], eax
.Lvb_setup_length_next:
    inc ebx
    cmp ebx, [rsi + CB_ENTRIES]
    jb .Lvb_setup_length
.Lvb_setup_tree:
    mov eax, [rip + vb_lengths_total]
    shl eax, 3
    call vb_alloc
    test rax, rax
    jz .Lvb_setup_bad
    mov [rsi + CB_TREE], rax
    mov r15, rax
    mov dword ptr [rip + vb_tree_used], 1
    lea rdx, [rip + vb_codes_available]
    xor eax, eax
    xor ecx, ecx
.Lvb_setup_clear_codes:
    mov [rdx + rcx*4], eax
    inc ecx
    cmp ecx, 33
    jb .Lvb_setup_clear_codes
    xor ebx, ebx
    xor ebp, ebp              # first nonempty code marker
.Lvb_setup_code:
    movzx r13d, byte ptr [rdi + rbx]
    test r13d, r13d
    jz .Lvb_setup_code_next
    test ebp, ebp
    jnz .Lvb_setup_code_find
    inc ebp
    xor r14d, r14d
    mov ecx, 1
.Lvb_setup_code_initial:
    mov eax, 0x80000000
    mov edx, ecx
    dec ecx
    shr eax, cl
    mov ecx, edx
    lea rdx, [rip + vb_codes_available]
    mov [rdx + rcx*4], eax
    inc ecx
    cmp ecx, r13d
    jbe .Lvb_setup_code_initial
    jmp .Lvb_setup_insert
.Lvb_setup_code_find:
    mov ecx, r13d
    lea rdx, [rip + vb_codes_available]
.Lvb_setup_code_search:
    test ecx, ecx
    jz .Lvb_setup_bad
    mov r14d, [rdx + rcx*4]
    test r14d, r14d
    jnz .Lvb_setup_code_found
    dec ecx
    jmp .Lvb_setup_code_search
.Lvb_setup_code_found:
    mov dword ptr [rdx + rcx*4], 0
    mov r8d, ecx
    mov ecx, r13d
.Lvb_setup_code_split:
    cmp ecx, r8d
    jbe .Lvb_setup_insert
    cmp dword ptr [rdx + rcx*4], 0
    jne .Lvb_setup_bad
    mov eax, 0x80000000
    dec ecx
    shr eax, cl
    inc ecx
    add eax, r14d
    mov [rdx + rcx*4], eax
    dec ecx
    jmp .Lvb_setup_code_split
.Lvb_setup_insert:
    mov [rsi + 60], ebx
    inc dword ptr [rsi + 56]
    xor edx, edx
    mov ecx, r13d
.Lvb_setup_insert_bit:
    xor eax, eax
    shl r14d, 1
    setc al
    lea r8, [rax + rdx*2]
    dec ecx
    jz .Lvb_setup_insert_leaf
    mov edx, [r15 + r8*4]
    test edx, edx
    js .Lvb_setup_bad
    jnz .Lvb_setup_insert_bit
    mov edx, [rip + vb_tree_used]
    inc dword ptr [rip + vb_tree_used]
    cmp edx, [rip + vb_lengths_total]
    jae .Lvb_setup_bad
    mov [r15 + r8*4], edx
    jmp .Lvb_setup_insert_bit
.Lvb_setup_insert_leaf:
    cmp dword ptr [r15 + r8*4], 0
    jne .Lvb_setup_bad
    mov eax, ebx
    not eax
    mov [r15 + r8*4], eax
.Lvb_setup_code_next:
    inc ebx
    cmp ebx, [rsi + CB_ENTRIES]
    jb .Lvb_setup_code
    test ebp, ebp
    jz .Lvb_setup_bad
    cmp dword ptr [rsi + 56], 1
    jne .Lvb_setup_complete_tree
    mov eax, [rsi + 60]
    cmp byte ptr [rdi + rax], 1
    jne .Lvb_setup_bad
    mov eax, [r15]
    mov [r15 + 4], eax         # Vorbis single-entry books sink either bit.
    jmp .Lvb_setup_lookup
.Lvb_setup_complete_tree:
    lea rdx, [rip + vb_codes_available]
    mov ecx, 1
.Lvb_setup_complete_check:
    cmp dword ptr [rdx + rcx*4], 0
    jne .Lvb_setup_bad
    inc ecx
    cmp ecx, 33
    jb .Lvb_setup_complete_check
.Lvb_setup_lookup:
    VB_GET 4
    cmp eax, 2
    ja .Lvb_setup_bad
    mov [rsi + CB_LOOKUP], eax
    test eax, eax
    jz .Lvb_setup_book_next
    VB_GET 32
    call vb_unpack
    movss dword ptr [rsi + CB_MIN], xmm0
    VB_GET 32
    call vb_unpack
    movss dword ptr [rsi + CB_DELTA], xmm0
    VB_GET 4
    inc eax
    mov [rsi + CB_BITS], eax
    VB_GET 1
    mov [rsi + CB_SEQUENCE], eax
    mov eax, [rsi + CB_ENTRIES]
    imul eax, [rsi + CB_DIM]
    cmp eax, 0x400000
    ja .Lvb_setup_bad
    mov [rsp + 32], eax         # vector component count
    cmp dword ptr [rsi + CB_LOOKUP], 2
    je .Lvb_setup_quant_count
    mov r13d, 1
.Lvb_setup_root_trial:
    lea r14d, [r13 + 1]
    mov ecx, [rsi + CB_DIM]
    mov eax, 1
.Lvb_setup_root_power:
    mul r14d
    test edx, edx
    jnz .Lvb_setup_root_done
    cmp eax, [rsi + CB_ENTRIES]
    ja .Lvb_setup_root_done
    dec ecx
    jnz .Lvb_setup_root_power
    inc r13d
    jmp .Lvb_setup_root_trial
.Lvb_setup_root_done:
    mov eax, r13d
.Lvb_setup_quant_count:
    mov [rsi + CB_QUANTS], eax
    shl eax, 2
    call vb_alloc
    test rax, rax
    jz .Lvb_setup_bad
    mov [rip + vb_quant_ptr], rax
    mov rdi, rax
    xor ebx, ebx
.Lvb_setup_quant_read:
    mov ecx, [rsi + CB_BITS]
    call vb_bits
    mov [rdi + rbx*4], eax
    inc ebx
    cmp ebx, [rsi + CB_QUANTS]
    jb .Lvb_setup_quant_read
    mov eax, [rsp + 32]
    shl eax, 2
    call vb_alloc
    test rax, rax
    jz .Lvb_setup_bad
    mov [rsi + CB_VECTOR], rax
    mov r15, rax
    xor ebx, ebx
.Lvb_setup_vector:
    xor r13d, r13d
    mov r14d, ebx
    pxor xmm2, xmm2
.Lvb_setup_component:
    cmp dword ptr [rsi + CB_LOOKUP], 1
    jne .Lvb_setup_component_direct
    mov eax, r14d
    xor edx, edx
    div dword ptr [rsi + CB_QUANTS]
    mov r14d, eax
    mov eax, edx
    jmp .Lvb_setup_component_value
.Lvb_setup_component_direct:
    mov eax, ebx
    imul eax, [rsi + CB_DIM]
    add eax, r13d
.Lvb_setup_component_value:
    cvtsi2ss xmm0, dword ptr [rdi + rax*4]
    mulss xmm0, dword ptr [rsi + CB_DELTA]
    addss xmm0, dword ptr [rsi + CB_MIN]
    addss xmm0, xmm2
    cmp dword ptr [rsi + CB_SEQUENCE], 0
    je .Lvb_setup_component_save
    movss xmm2, xmm0
.Lvb_setup_component_save:
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .Lvb_setup_bad
    movss dword ptr [r15], xmm0
    add r15, 4
    inc r13d
    cmp r13d, [rsi + CB_DIM]
    jb .Lvb_setup_component
    inc ebx
    cmp ebx, [rsi + CB_ENTRIES]
    jb .Lvb_setup_vector
.Lvb_setup_book_next:
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_setup_bad
    inc r12d
    cmp r12d, [rip + vb_books_count]
    jb .Lvb_setup_book
    VB_GET 6
    inc eax
    mov ebx, eax
.Lvb_setup_time:
    VB_GET 16
    test eax, eax
    jnz .Lvb_setup_bad
    dec ebx
    jnz .Lvb_setup_time
    VB_GET 6
    inc eax
    mov [rip + vb_floors_count], eax
    xor r12d, r12d
.Lvb_setup_floor:
    mov eax, r12d
    imul eax, FL_SIZE
    lea rsi, [rip + vb_floors]
    add rsi, rax
    VB_GET 16
    cmp eax, 1
    jne .Lvb_setup_bad        # Floor 0 is an obsolete, separate LSP algorithm.
    VB_GET 5
    mov [rsi + FL_PART], eax
    xor ebx, ebx
    mov r13d, -1
.Lvb_setup_floor_part:
    cmp ebx, [rsi + FL_PART]
    jae .Lvb_setup_floor_classes
    VB_GET 4
    mov [rsi + rbx*4 + FL_PARTCLASS], eax
    cmp eax, r13d
    jle .Lvb_setup_floor_part_next
    mov r13d, eax
.Lvb_setup_floor_part_next:
    inc ebx
    jmp .Lvb_setup_floor_part
.Lvb_setup_floor_classes:
    xor ebx, ebx
.Lvb_setup_floor_class:
    cmp ebx, r13d
    jg .Lvb_setup_floor_points
    VB_GET 3
    inc eax
    mov [rsi + rbx*4 + FL_DIM], eax
    VB_GET 2
    mov [rsi + rbx*4 + FL_SUB], eax
    mov ecx, eax
    mov r14d, 1
    shl r14d, cl
    test eax, eax
    jz .Lvb_setup_floor_sub
    VB_GET 8
    cmp eax, [rip + vb_books_count]
    jae .Lvb_setup_bad
    mov [rsi + rbx*4 + FL_MASTER], eax
.Lvb_setup_floor_sub:
    xor edi, edi
    mov r15d, ebx
    shl r15d, 5
.Lvb_setup_floor_sub_book:
    VB_GET 8
    dec eax
    cmp eax, -1
    je .Lvb_setup_floor_sub_valid
    cmp eax, [rip + vb_books_count]
    jae .Lvb_setup_bad
.Lvb_setup_floor_sub_valid:
    lea edx, [r15 + rdi*4]
    mov [rsi + rdx + FL_BOOKS], eax
    inc edi
    cmp edi, r14d
    jb .Lvb_setup_floor_sub_book
    inc ebx
    jmp .Lvb_setup_floor_class
.Lvb_setup_floor_points:
    VB_GET 2
    inc eax
    mov [rsi + FL_MULT], eax
    VB_GET 4
    mov [rsi + FL_RANGE], eax
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    mov dword ptr [rsi + FL_X], 0
    mov [rsi + FL_X + 4], eax
    mov edi, 2
    xor ebx, ebx
.Lvb_setup_floor_x_part:
    cmp ebx, [rsi + FL_PART]
    jae .Lvb_setup_floor_sort
    mov eax, [rsi + rbx*4 + FL_PARTCLASS]
    mov r13d, [rsi + rax*4 + FL_DIM]
.Lvb_setup_floor_x:
    mov ecx, [rsi + FL_RANGE]
    call vb_bits
    mov [rsi + rdi*4 + FL_X], eax
    inc edi
    dec r13d
    jnz .Lvb_setup_floor_x
    inc ebx
    jmp .Lvb_setup_floor_x_part
.Lvb_setup_floor_sort:
    mov [rsi + FL_COUNT], edi
    xor ebx, ebx
.Lvb_setup_floor_sort_point:
    mov eax, [rsi + rbx*4 + FL_X]
    xor ecx, ecx
    xor edx, edx
.Lvb_setup_floor_rank:
    cmp ecx, edi
    jae .Lvb_setup_floor_rank_done
    cmp ecx, ebx
    je .Lvb_setup_floor_rank_next
    cmp eax, [rsi + rcx*4 + FL_X]
    je .Lvb_setup_bad
    jb .Lvb_setup_floor_rank_next
    inc edx
.Lvb_setup_floor_rank_next:
    inc ecx
    jmp .Lvb_setup_floor_rank
.Lvb_setup_floor_rank_done:
    mov [rsi + rdx*4 + FL_SORT], ebx
    cmp ebx, 2
    jb .Lvb_setup_floor_sort_next
    xor r13d, r13d
    mov r14d, 1
    xor ecx, ecx
.Lvb_setup_floor_neighbor:
    cmp ecx, ebx
    jae .Lvb_setup_floor_neighbor_done
    mov edx, [rsi + rcx*4 + FL_X]
    cmp edx, eax
    ja .Lvb_setup_floor_high
    cmp edx, [rsi + r13*4 + FL_X]
    jbe .Lvb_setup_floor_neighbor_next
    mov r13d, ecx
    jmp .Lvb_setup_floor_neighbor_next
.Lvb_setup_floor_high:
    cmp edx, [rsi + r14*4 + FL_X]
    jae .Lvb_setup_floor_neighbor_next
    mov r14d, ecx
.Lvb_setup_floor_neighbor_next:
    inc ecx
    jmp .Lvb_setup_floor_neighbor
.Lvb_setup_floor_neighbor_done:
    mov [rsi + rbx*4 + FL_LOW], r13d
    mov [rsi + rbx*4 + FL_HIGH], r14d
.Lvb_setup_floor_sort_next:
    inc ebx
    cmp ebx, edi
    jb .Lvb_setup_floor_sort_point
    inc r12d
    cmp r12d, [rip + vb_floors_count]
    jb .Lvb_setup_floor
    VB_GET 6
    inc eax
    mov [rip + vb_residues_count], eax
    xor r12d, r12d
.Lvb_setup_residue:
    mov eax, r12d
    imul eax, RS_SIZE
    lea rsi, [rip + vb_residues]
    add rsi, rax
    VB_GET 16
    cmp eax, 2
    ja .Lvb_setup_bad
    mov [rsi + RS_TYPE], eax
    VB_GET 24
    mov [rsi + RS_BEGIN], eax
    VB_GET 24
    cmp eax, [rsi + RS_BEGIN]
    jb .Lvb_setup_bad
    mov [rsi + RS_END], eax
    VB_GET 24
    inc eax
    mov [rsi + RS_PART], eax
    VB_GET 6
    inc eax
    mov [rsi + RS_CLASSES], eax
    VB_GET 8
    cmp eax, [rip + vb_books_count]
    jae .Lvb_setup_bad
    mov [rsi + RS_BOOK], eax
    xor ebx, ebx
.Lvb_setup_cascade:
    VB_GET 3
    mov r13d, eax
    VB_GET 1
    test eax, eax
    jz .Lvb_setup_cascade_save
    VB_GET 5
    shl eax, 3
    or r13d, eax
.Lvb_setup_cascade_save:
    mov [rsi + rbx*4 + RS_CASCADE], r13d
    inc ebx
    cmp ebx, [rsi + RS_CLASSES]
    jb .Lvb_setup_cascade
    xor ebx, ebx
.Lvb_setup_residue_class:
    xor edi, edi
    mov r13d, [rsi + rbx*4 + RS_CASCADE]
    mov r14d, ebx
    shl r14d, 5
.Lvb_setup_residue_book:
    mov eax, -1
    test r13d, 1
    jz .Lvb_setup_residue_book_save
    VB_GET 8
    cmp eax, [rip + vb_books_count]
    jae .Lvb_setup_bad
    mov edx, eax
    shl edx, 6
    lea rcx, [rip + vb_books]
    cmp qword ptr [rcx + rdx + CB_VECTOR], 0
    je .Lvb_setup_bad
.Lvb_setup_residue_book_save:
    lea edx, [r14 + rdi*4]
    mov [rsi + rdx + RS_BOOKS], eax
    shr r13d, 1
    inc edi
    cmp edi, 8
    jb .Lvb_setup_residue_book
    inc ebx
    cmp ebx, [rsi + RS_CLASSES]
    jb .Lvb_setup_residue_class
    inc r12d
    cmp r12d, [rip + vb_residues_count]
    jb .Lvb_setup_residue
    VB_GET 6
    inc eax
    mov [rip + vb_maps_count], eax
    xor r12d, r12d
.Lvb_setup_map:
    mov eax, r12d
    imul eax, MP_SIZE
    lea rsi, [rip + vb_maps]
    add rsi, rax
    VB_GET 16
    test eax, eax
    jnz .Lvb_setup_bad
    VB_GET 1
    test eax, eax
    jz .Lvb_setup_one_submap
    VB_GET 4
.Lvb_setup_one_submap:
    inc eax
    mov [rsi + MP_SUBMAPS], eax
    VB_GET 1
    test eax, eax
    jz .Lvb_setup_no_couple
    VB_GET 8
    inc eax
.Lvb_setup_no_couple:
    mov [rsi + MP_COUPLE], eax
    xor ebx, ebx
.Lvb_setup_couple:
    cmp ebx, [rsi + MP_COUPLE]
    jae .Lvb_setup_mux
    mov eax, [rip + source_channels]
    dec eax
    call vb_ilog
    call vb_bits
    cmp eax, [rip + source_channels]
    jae .Lvb_setup_bad
    mov [rsi + rbx*4 + MP_MAG], eax
    mov eax, [rip + source_channels]
    dec eax
    call vb_ilog
    call vb_bits
    cmp eax, [rip + source_channels]
    jae .Lvb_setup_bad
    cmp eax, [rsi + rbx*4 + MP_MAG]
    je .Lvb_setup_bad
    mov [rsi + rbx*4 + MP_ANGLE], eax
    inc ebx
    jmp .Lvb_setup_couple
.Lvb_setup_mux:
    VB_GET 2
    test eax, eax
    jnz .Lvb_setup_bad
    xor ebx, ebx
.Lvb_setup_channel_mux:
    xor eax, eax
    cmp dword ptr [rsi + MP_SUBMAPS], 1
    je .Lvb_setup_mux_save
    VB_GET 4
    cmp eax, [rsi + MP_SUBMAPS]
    jae .Lvb_setup_bad
.Lvb_setup_mux_save:
    mov [rsi + rbx*4 + MP_MUX], eax
    inc ebx
    cmp ebx, [rip + source_channels]
    jb .Lvb_setup_channel_mux
    xor ebx, ebx
.Lvb_setup_submap:
    VB_GET 8
    VB_GET 8
    cmp eax, [rip + vb_floors_count]
    jae .Lvb_setup_bad
    mov [rsi + rbx*4 + MP_FLOOR], eax
    VB_GET 8
    cmp eax, [rip + vb_residues_count]
    jae .Lvb_setup_bad
    mov [rsi + rbx*4 + MP_RESIDUE], eax
    inc ebx
    cmp ebx, [rsi + MP_SUBMAPS]
    jb .Lvb_setup_submap
    inc r12d
    cmp r12d, [rip + vb_maps_count]
    jb .Lvb_setup_map
    VB_GET 6
    inc eax
    mov [rip + vb_modes_count], eax
    dec eax
    call vb_ilog
    mov [rip + vb_mode_bits], ecx
    xor ebx, ebx
    lea rsi, [rip + vb_modes]
.Lvb_setup_mode:
    VB_GET 1
    mov [rsi + rbx*8], eax
    VB_GET 16
    test eax, eax
    jnz .Lvb_setup_bad
    VB_GET 16
    test eax, eax
    jnz .Lvb_setup_bad
    VB_GET 8
    cmp eax, [rip + vb_maps_count]
    jae .Lvb_setup_bad
    mov [rsi + rbx*8 + 4], eax
    inc ebx
    cmp ebx, [rip + vb_modes_count]
    jb .Lvb_setup_mode
    VB_GET 1
    cmp eax, 1
    jne .Lvb_setup_bad
    cmp dword ptr [rip + vb_bad], 0
    jne .Lvb_setup_bad
    mov eax, 1
    jmp .Lvb_setup_done
.Lvb_setup_bad:
    xor eax, eax
.Lvb_setup_done:
    add rsp, 104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
ENDFN vb_setup
