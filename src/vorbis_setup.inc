; Header setup; scalar trees and vector lookup tables are expanded once.
vb_setup PROC
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp,104
    VB_GET 8
    inc eax
    mov [vb_books_count],eax
    xor r12d,r12d
vb_setup_book:
    mov eax,r12d
    shl eax,6
    lea rsi,vb_books
    add rsi,rax
    mov qword ptr [rsi+CB_VECTOR],0
    mov dword ptr [rsi+56],0
    VB_GET 24
    cmp eax,564342h
    jne vb_setup_bad
    VB_GET 16
    test eax,eax
    jz vb_setup_bad
    cmp eax,256
    ja vb_setup_bad
    mov [rsi+CB_DIM],eax
    VB_GET 24
    test eax,eax
    jz vb_setup_bad
    cmp eax,65536
    ja vb_setup_bad
    mov [rsi+CB_ENTRIES],eax
    call vb_alloc
    test rax,rax
    jz vb_setup_bad
    mov [rsi+CB_LENGTH],rax
    mov rdi,rax
    mov dword ptr [vb_lengths_total],1
    VB_GET 1
    test eax,eax
    jz vb_setup_unordered
    VB_GET 5
    inc eax
    mov r13d,eax
    xor ebx,ebx
vb_setup_ordered:
    cmp r13d,32
    ja vb_setup_bad
    mov eax,[rsi+CB_ENTRIES]
    sub eax,ebx
    call vb_ilog
    call vb_bits
    mov edx,[rsi+CB_ENTRIES]
    sub edx,ebx
    cmp eax,edx
    ja vb_setup_bad
    mov edx,eax
vb_setup_ordered_fill:
    test edx,edx
    jz vb_setup_ordered_next
    mov [rdi+rbx],r13b
    add [vb_lengths_total],r13d
    inc ebx
    dec edx
    jmp vb_setup_ordered_fill
vb_setup_ordered_next:
    inc r13d
    cmp ebx,[rsi+CB_ENTRIES]
    jb vb_setup_ordered
    jmp vb_setup_tree
vb_setup_unordered:
    VB_GET 1
    mov r13d,eax
    xor ebx,ebx
vb_setup_length:
    test r13d,r13d
    jz vb_setup_present
    VB_GET 1
    test eax,eax
    jz vb_setup_length_next
vb_setup_present:
    VB_GET 5
    inc eax
    mov [rdi+rbx],al
    add [vb_lengths_total],eax
vb_setup_length_next:
    inc ebx
    cmp ebx,[rsi+CB_ENTRIES]
    jb vb_setup_length
vb_setup_tree:
    mov eax,[vb_lengths_total]
    shl eax,3
    call vb_alloc
    test rax,rax
    jz vb_setup_bad
    mov [rsi+CB_TREE],rax
    mov r15,rax
    mov dword ptr [vb_tree_used],1
    lea rdx,vb_codes_available
    xor eax,eax
    xor ecx,ecx
vb_setup_clear_codes:
    mov [rdx+rcx*4],eax
    inc ecx
    cmp ecx,33
    jb vb_setup_clear_codes
    xor ebx,ebx
    xor ebp,ebp              ; first nonempty code marker
vb_setup_code:
    movzx r13d,byte ptr [rdi+rbx]
    test r13d,r13d
    jz vb_setup_code_next
    test ebp,ebp
    jnz vb_setup_code_find
    inc ebp
    xor r14d,r14d
    mov ecx,1
vb_setup_code_initial:
    mov eax,80000000h
    mov edx,ecx
    dec ecx
    shr eax,cl
    mov ecx,edx
    lea rdx,vb_codes_available
    mov [rdx+rcx*4],eax
    inc ecx
    cmp ecx,r13d
    jbe vb_setup_code_initial
    jmp vb_setup_insert
vb_setup_code_find:
    mov ecx,r13d
    lea rdx,vb_codes_available
vb_setup_code_search:
    test ecx,ecx
    jz vb_setup_bad
    mov r14d,[rdx+rcx*4]
    test r14d,r14d
    jnz vb_setup_code_found
    dec ecx
    jmp vb_setup_code_search
vb_setup_code_found:
    mov dword ptr [rdx+rcx*4],0
    mov r8d,ecx
    mov ecx,r13d
vb_setup_code_split:
    cmp ecx,r8d
    jbe vb_setup_insert
    cmp dword ptr [rdx+rcx*4],0
    jne vb_setup_bad
    mov eax,80000000h
    dec ecx
    shr eax,cl
    inc ecx
    add eax,r14d
    mov [rdx+rcx*4],eax
    dec ecx
    jmp vb_setup_code_split
vb_setup_insert:
    mov [rsi+60],ebx
    inc dword ptr [rsi+56]
    xor edx,edx
    mov ecx,r13d
vb_setup_insert_bit:
    xor eax,eax
    shl r14d,1
    setc al
    lea r8,[rax+rdx*2]
    dec ecx
    jz vb_setup_insert_leaf
    mov edx,[r15+r8*4]
    test edx,edx
    js vb_setup_bad
    jnz vb_setup_insert_bit
    mov edx,[vb_tree_used]
    inc dword ptr [vb_tree_used]
    cmp edx,[vb_lengths_total]
    jae vb_setup_bad
    mov [r15+r8*4],edx
    jmp vb_setup_insert_bit
vb_setup_insert_leaf:
    cmp dword ptr [r15+r8*4],0
    jne vb_setup_bad
    mov eax,ebx
    not eax
    mov [r15+r8*4],eax
vb_setup_code_next:
    inc ebx
    cmp ebx,[rsi+CB_ENTRIES]
    jb vb_setup_code
    test ebp,ebp
    jz vb_setup_bad
    cmp dword ptr [rsi+56],1
    jne vb_setup_complete_tree
    mov eax,[rsi+60]
    cmp byte ptr [rdi+rax],1
    jne vb_setup_bad
    mov eax,[r15]
    mov [r15+4],eax         ; Vorbis single-entry books sink either bit.
    jmp vb_setup_lookup
vb_setup_complete_tree:
    lea rdx,vb_codes_available
    mov ecx,1
vb_setup_complete_check:
    cmp dword ptr [rdx+rcx*4],0
    jne vb_setup_bad
    inc ecx
    cmp ecx,33
    jb vb_setup_complete_check
vb_setup_lookup:
    VB_GET 4
    cmp eax,2
    ja vb_setup_bad
    mov [rsi+CB_LOOKUP],eax
    test eax,eax
    jz vb_setup_book_next
    VB_GET 32
    call vb_unpack
    movss dword ptr [rsi+CB_MIN],xmm0
    VB_GET 32
    call vb_unpack
    movss dword ptr [rsi+CB_DELTA],xmm0
    VB_GET 4
    inc eax
    mov [rsi+CB_BITS],eax
    VB_GET 1
    mov [rsi+CB_SEQUENCE],eax
    mov eax,[rsi+CB_ENTRIES]
    imul eax,[rsi+CB_DIM]
    cmp eax,400000h
    ja vb_setup_bad
    mov [rsp+32],eax         ; vector component count
    cmp dword ptr [rsi+CB_LOOKUP],2
    je vb_setup_quant_count
    mov r13d,1
vb_setup_root_trial:
    lea r14d,[r13+1]
    mov ecx,[rsi+CB_DIM]
    mov eax,1
vb_setup_root_power:
    mul r14d
    test edx,edx
    jnz vb_setup_root_done
    cmp eax,[rsi+CB_ENTRIES]
    ja vb_setup_root_done
    dec ecx
    jnz vb_setup_root_power
    inc r13d
    jmp vb_setup_root_trial
vb_setup_root_done:
    mov eax,r13d
vb_setup_quant_count:
    mov [rsi+CB_QUANTS],eax
    shl eax,2
    call vb_alloc
    test rax,rax
    jz vb_setup_bad
    mov [vb_quant_ptr],rax
    mov rdi,rax
    xor ebx,ebx
vb_setup_quant_read:
    mov ecx,[rsi+CB_BITS]
    call vb_bits
    mov [rdi+rbx*4],eax
    inc ebx
    cmp ebx,[rsi+CB_QUANTS]
    jb vb_setup_quant_read
    mov eax,[rsp+32]
    shl eax,2
    call vb_alloc
    test rax,rax
    jz vb_setup_bad
    mov [rsi+CB_VECTOR],rax
    mov r15,rax
    xor ebx,ebx
vb_setup_vector:
    xor r13d,r13d
    mov r14d,ebx
    pxor xmm2,xmm2
vb_setup_component:
    cmp dword ptr [rsi+CB_LOOKUP],1
    jne vb_setup_component_direct
    mov eax,r14d
    xor edx,edx
    div dword ptr [rsi+CB_QUANTS]
    mov r14d,eax
    mov eax,edx
    jmp vb_setup_component_value
vb_setup_component_direct:
    mov eax,ebx
    imul eax,[rsi+CB_DIM]
    add eax,r13d
vb_setup_component_value:
    cvtsi2ss xmm0,dword ptr [rdi+rax*4]
    mulss xmm0,dword ptr [rsi+CB_DELTA]
    addss xmm0,dword ptr [rsi+CB_MIN]
    addss xmm0,xmm2
    cmp dword ptr [rsi+CB_SEQUENCE],0
    je vb_setup_component_save
    movss xmm2,xmm0
vb_setup_component_save:
    movd eax,xmm0
    and eax,7f800000h
    cmp eax,7f800000h
    je vb_setup_bad
    movss dword ptr [r15],xmm0
    add r15,4
    inc r13d
    cmp r13d,[rsi+CB_DIM]
    jb vb_setup_component
    inc ebx
    cmp ebx,[rsi+CB_ENTRIES]
    jb vb_setup_vector
vb_setup_book_next:
    cmp dword ptr [vb_bad],0
    jne vb_setup_bad
    inc r12d
    cmp r12d,[vb_books_count]
    jb vb_setup_book
    VB_GET 6
    inc eax
    mov ebx,eax
vb_setup_time:
    VB_GET 16
    test eax,eax
    jnz vb_setup_bad
    dec ebx
    jnz vb_setup_time
    VB_GET 6
    inc eax
    mov [vb_floors_count],eax
    xor r12d,r12d
vb_setup_floor:
    mov eax,r12d
    imul eax,FL_SIZE
    lea rsi,vb_floors
    add rsi,rax
    VB_GET 16
    cmp eax,1
    jne vb_setup_bad        ; Floor 0 is an obsolete, separate LSP algorithm.
    VB_GET 5
    mov [rsi+FL_PART],eax
    xor ebx,ebx
    mov r13d,-1
vb_setup_floor_part:
    cmp ebx,[rsi+FL_PART]
    jae vb_setup_floor_classes
    VB_GET 4
    mov [rsi+rbx*4+FL_PARTCLASS],eax
    cmp eax,r13d
    jle vb_setup_floor_part_next
    mov r13d,eax
vb_setup_floor_part_next:
    inc ebx
    jmp vb_setup_floor_part
vb_setup_floor_classes:
    xor ebx,ebx
vb_setup_floor_class:
    cmp ebx,r13d
    jg vb_setup_floor_points
    VB_GET 3
    inc eax
    mov [rsi+rbx*4+FL_DIM],eax
    VB_GET 2
    mov [rsi+rbx*4+FL_SUB],eax
    mov ecx,eax
    mov r14d,1
    shl r14d,cl
    test eax,eax
    jz vb_setup_floor_sub
    VB_GET 8
    cmp eax,[vb_books_count]
    jae vb_setup_bad
    mov [rsi+rbx*4+FL_MASTER],eax
vb_setup_floor_sub:
    xor edi,edi
    mov r15d,ebx
    shl r15d,5
vb_setup_floor_sub_book:
    VB_GET 8
    dec eax
    cmp eax,-1
    je vb_setup_floor_sub_valid
    cmp eax,[vb_books_count]
    jae vb_setup_bad
vb_setup_floor_sub_valid:
    lea edx,[r15+rdi*4]
    mov [rsi+rdx+FL_BOOKS],eax
    inc edi
    cmp edi,r14d
    jb vb_setup_floor_sub_book
    inc ebx
    jmp vb_setup_floor_class
vb_setup_floor_points:
    VB_GET 2
    inc eax
    mov [rsi+FL_MULT],eax
    VB_GET 4
    mov [rsi+FL_RANGE],eax
    mov ecx,eax
    mov eax,1
    shl eax,cl
    mov dword ptr [rsi+FL_X],0
    mov [rsi+FL_X+4],eax
    mov edi,2
    xor ebx,ebx
vb_setup_floor_x_part:
    cmp ebx,[rsi+FL_PART]
    jae vb_setup_floor_sort
    mov eax,[rsi+rbx*4+FL_PARTCLASS]
    mov r13d,[rsi+rax*4+FL_DIM]
vb_setup_floor_x:
    mov ecx,[rsi+FL_RANGE]
    call vb_bits
    mov [rsi+rdi*4+FL_X],eax
    inc edi
    dec r13d
    jnz vb_setup_floor_x
    inc ebx
    jmp vb_setup_floor_x_part
vb_setup_floor_sort:
    mov [rsi+FL_COUNT],edi
    xor ebx,ebx
vb_setup_floor_sort_point:
    mov eax,[rsi+rbx*4+FL_X]
    xor ecx,ecx
    xor edx,edx
vb_setup_floor_rank:
    cmp ecx,edi
    jae vb_setup_floor_rank_done
    cmp ecx,ebx
    je vb_setup_floor_rank_next
    cmp eax,[rsi+rcx*4+FL_X]
    je vb_setup_bad
    jb vb_setup_floor_rank_next
    inc edx
vb_setup_floor_rank_next:
    inc ecx
    jmp vb_setup_floor_rank
vb_setup_floor_rank_done:
    mov [rsi+rdx*4+FL_SORT],ebx
    cmp ebx,2
    jb vb_setup_floor_sort_next
    xor r13d,r13d
    mov r14d,1
    xor ecx,ecx
vb_setup_floor_neighbor:
    cmp ecx,ebx
    jae vb_setup_floor_neighbor_done
    mov edx,[rsi+rcx*4+FL_X]
    cmp edx,eax
    ja vb_setup_floor_high
    cmp edx,[rsi+r13*4+FL_X]
    jbe vb_setup_floor_neighbor_next
    mov r13d,ecx
    jmp vb_setup_floor_neighbor_next
vb_setup_floor_high:
    cmp edx,[rsi+r14*4+FL_X]
    jae vb_setup_floor_neighbor_next
    mov r14d,ecx
vb_setup_floor_neighbor_next:
    inc ecx
    jmp vb_setup_floor_neighbor
vb_setup_floor_neighbor_done:
    mov [rsi+rbx*4+FL_LOW],r13d
    mov [rsi+rbx*4+FL_HIGH],r14d
vb_setup_floor_sort_next:
    inc ebx
    cmp ebx,edi
    jb vb_setup_floor_sort_point
    inc r12d
    cmp r12d,[vb_floors_count]
    jb vb_setup_floor
    VB_GET 6
    inc eax
    mov [vb_residues_count],eax
    xor r12d,r12d
vb_setup_residue:
    mov eax,r12d
    imul eax,RS_SIZE
    lea rsi,vb_residues
    add rsi,rax
    VB_GET 16
    cmp eax,2
    ja vb_setup_bad
    mov [rsi+RS_TYPE],eax
    VB_GET 24
    mov [rsi+RS_BEGIN],eax
    VB_GET 24
    cmp eax,[rsi+RS_BEGIN]
    jb vb_setup_bad
    mov [rsi+RS_END],eax
    VB_GET 24
    inc eax
    mov [rsi+RS_PART],eax
    VB_GET 6
    inc eax
    mov [rsi+RS_CLASSES],eax
    VB_GET 8
    cmp eax,[vb_books_count]
    jae vb_setup_bad
    mov [rsi+RS_BOOK],eax
    xor ebx,ebx
vb_setup_cascade:
    VB_GET 3
    mov r13d,eax
    VB_GET 1
    test eax,eax
    jz vb_setup_cascade_save
    VB_GET 5
    shl eax,3
    or r13d,eax
vb_setup_cascade_save:
    mov [rsi+rbx*4+RS_CASCADE],r13d
    inc ebx
    cmp ebx,[rsi+RS_CLASSES]
    jb vb_setup_cascade
    xor ebx,ebx
vb_setup_residue_class:
    xor edi,edi
    mov r13d,[rsi+rbx*4+RS_CASCADE]
    mov r14d,ebx
    shl r14d,5
vb_setup_residue_book:
    mov eax,-1
    test r13d,1
    jz vb_setup_residue_book_save
    VB_GET 8
    cmp eax,[vb_books_count]
    jae vb_setup_bad
    mov edx,eax
    shl edx,6
    lea rcx,vb_books
    cmp qword ptr [rcx+rdx+CB_VECTOR],0
    je vb_setup_bad
vb_setup_residue_book_save:
    lea edx,[r14+rdi*4]
    mov [rsi+rdx+RS_BOOKS],eax
    shr r13d,1
    inc edi
    cmp edi,8
    jb vb_setup_residue_book
    inc ebx
    cmp ebx,[rsi+RS_CLASSES]
    jb vb_setup_residue_class
    inc r12d
    cmp r12d,[vb_residues_count]
    jb vb_setup_residue
    VB_GET 6
    inc eax
    mov [vb_maps_count],eax
    xor r12d,r12d
vb_setup_map:
    mov eax,r12d
    imul eax,MP_SIZE
    lea rsi,vb_maps
    add rsi,rax
    VB_GET 16
    test eax,eax
    jnz vb_setup_bad
    VB_GET 1
    test eax,eax
    jz vb_setup_one_submap
    VB_GET 4
vb_setup_one_submap:
    inc eax
    mov [rsi+MP_SUBMAPS],eax
    VB_GET 1
    test eax,eax
    jz vb_setup_no_couple
    VB_GET 8
    inc eax
vb_setup_no_couple:
    mov [rsi+MP_COUPLE],eax
    xor ebx,ebx
vb_setup_couple:
    cmp ebx,[rsi+MP_COUPLE]
    jae vb_setup_mux
    mov eax,[source_channels]
    dec eax
    call vb_ilog
    call vb_bits
    cmp eax,[source_channels]
    jae vb_setup_bad
    mov [rsi+rbx*4+MP_MAG],eax
    mov eax,[source_channels]
    dec eax
    call vb_ilog
    call vb_bits
    cmp eax,[source_channels]
    jae vb_setup_bad
    cmp eax,[rsi+rbx*4+MP_MAG]
    je vb_setup_bad
    mov [rsi+rbx*4+MP_ANGLE],eax
    inc ebx
    jmp vb_setup_couple
vb_setup_mux:
    VB_GET 2
    test eax,eax
    jnz vb_setup_bad
    xor ebx,ebx
vb_setup_channel_mux:
    xor eax,eax
    cmp dword ptr [rsi+MP_SUBMAPS],1
    je vb_setup_mux_save
    VB_GET 4
    cmp eax,[rsi+MP_SUBMAPS]
    jae vb_setup_bad
vb_setup_mux_save:
    mov [rsi+rbx*4+MP_MUX],eax
    inc ebx
    cmp ebx,[source_channels]
    jb vb_setup_channel_mux
    xor ebx,ebx
vb_setup_submap:
    VB_GET 8
    VB_GET 8
    cmp eax,[vb_floors_count]
    jae vb_setup_bad
    mov [rsi+rbx*4+MP_FLOOR],eax
    VB_GET 8
    cmp eax,[vb_residues_count]
    jae vb_setup_bad
    mov [rsi+rbx*4+MP_RESIDUE],eax
    inc ebx
    cmp ebx,[rsi+MP_SUBMAPS]
    jb vb_setup_submap
    inc r12d
    cmp r12d,[vb_maps_count]
    jb vb_setup_map
    VB_GET 6
    inc eax
    mov [vb_modes_count],eax
    dec eax
    call vb_ilog
    mov [vb_mode_bits],ecx
    xor ebx,ebx
    lea rsi,vb_modes
vb_setup_mode:
    VB_GET 1
    mov [rsi+rbx*8],eax
    VB_GET 16
    test eax,eax
    jnz vb_setup_bad
    VB_GET 16
    test eax,eax
    jnz vb_setup_bad
    VB_GET 8
    cmp eax,[vb_maps_count]
    jae vb_setup_bad
    mov [rsi+rbx*8+4],eax
    inc ebx
    cmp ebx,[vb_modes_count]
    jb vb_setup_mode
    VB_GET 1
    cmp eax,1
    jne vb_setup_bad
    cmp dword ptr [vb_bad],0
    jne vb_setup_bad
    mov eax,1
    jmp vb_setup_done
vb_setup_bad:
    xor eax,eax
vb_setup_done:
    add rsp,104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret
vb_setup ENDP
