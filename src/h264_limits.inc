# Original level/VUI DPB defaults, H.264 TablesA-1 and E.2.1 (08/2024).
RODATA
.p2align 2
hp_level_dpb:
    .long 9,396,10,396,11,900,12,2376,13,2376,20,2376,21,4752
    .long 22,8100,30,8100,31,18000,32,20480,40,32768,41,32768
    .long 42,34816,50,110400,51,184320,52,184320
    .long 60,696320,61,696320,62,696320
.text
LOCALFN hp_limits
    mov r8, rcx
    lea r9, [rip+hp_level_dpb]
    xor edx, edx
.Lhp_limits_find:
    mov eax, [r8+HP_LEVEL]
    cmp eax, [r9+rdx*8]
    je .Lhp_limits_level
    inc edx
    cmp edx, 20
    jb .Lhp_limits_find
    mov dword ptr [r8+HP_ERROR], 2
    xor eax, eax
    ret
.Lhp_limits_level:
    mov eax, [r9+rdx*8+4]
    cmp dword ptr [r8+HP_LEVEL], 11
    jne .Lhp_limits_size
    cmp dword ptr [r8+HP_PROFILE], 100
    je .Lhp_limits_size
    test dword ptr [r8+HP_CONSTRAINTS], 16
    jz .Lhp_limits_size
    mov eax, 396
.Lhp_limits_size:
    mov ecx, [r8+HP_WIDTH]
    imul ecx, [r8+HP_HEIGHT]
    shr ecx, 8
    xor edx, edx
    div ecx
    mov edx, 16
    cmp eax, edx
    cmova eax, edx
    test eax, eax
    jz .Lhp_limits_bad
    cmp dword ptr [r8+HP_RESTRICTION], 0
    jne .Lhp_limits_check
    mov [r8+HP_MAX_REORDER], eax
    mov [r8+HP_MAX_BUFFER], eax
    cmp dword ptr [r8+HP_PROFILE], 100
    jne .Lhp_limits_check
    test dword ptr [r8+HP_CONSTRAINTS], 16
    jz .Lhp_limits_check
    mov dword ptr [r8+HP_MAX_REORDER], 0
    mov dword ptr [r8+HP_MAX_BUFFER], 0
.Lhp_limits_check:
    cmp [r8+HP_MAX_BUFFER], eax
    ja .Lhp_limits_bad
    mov eax, [r8+HP_MAX_BUFFER]
    cmp eax, [r8+HP_REFS]
    jb .Lhp_limits_bad
    cmp eax, [r8+HP_MAX_REORDER]
    jb .Lhp_limits_bad
    mov eax, 1
    ret
.Lhp_limits_bad:
    mov dword ptr [r8+HP_ERROR], 1
    xor eax, eax
    ret
ENDFN hp_limits
