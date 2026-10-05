# LAMP Windows platform services for the shared decoders. MIT license.
# Same contract as src/linux/platform.s; see src/lamp.inc.
.include "lamp.inc"

.text
# RCX=bytes -> RAX=zeroed, page-aligned block or 0.
FN mem_alloc
    sub rsp, 40
    mov rdx, rcx
    xor ecx, ecx
    mov r8d, 0x3000            # MEM_COMMIT | MEM_RESERVE
    mov r9d, 4                 # PAGE_READWRITE
    call VirtualAlloc
    add rsp, 40
    ret
ENDFN mem_alloc

# RCX=bytes -> RAX=reserved address range or 0. Commit pages before use.
FN mem_reserve
    sub rsp, 40
    mov rdx, rcx
    xor ecx, ecx
    mov r8d, 0x2000            # MEM_RESERVE
    mov r9d, 4
    call VirtualAlloc
    add rsp, 40
    ret
ENDFN mem_reserve

# RCX=address inside a reserved range, RDX=bytes -> RAX=address or 0.
# Newly committed pages read as zero.
FN mem_commit
    sub rsp, 40
    mov r8d, 0x1000            # MEM_COMMIT
    mov r9d, 4
    call VirtualAlloc
    add rsp, 40
    ret
ENDFN mem_commit

# RCX=block from mem_alloc/mem_reserve, or 0.
FN mem_free
    test rcx, rcx
    jz .Lmem_free_none
    sub rsp, 40
    xor edx, edx
    mov r8d, 0x8000            # MEM_RELEASE
    call VirtualFree
    add rsp, 40
.Lmem_free_none:
    ret
ENDFN mem_free

# RCX=UTF-16 path -> RAX=read-only view or 0, RDX=bytes, R8=token for file_unmap.
# The read-shared file handle stays open as the token, so other processes cannot
# open the file for writing while it plays. Empty files fail.
FN file_map
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 72
    mov rbx, -1
    xor r12d, r12d
    mov edx, 0x80000000        # GENERIC_READ
    mov r8d, 1                 # FILE_SHARE_READ
    xor r9d, r9d
    mov qword ptr [rsp + 32], 3            # OPEN_EXISTING
    mov qword ptr [rsp + 40], 0x8000000    # FILE_FLAG_SEQUENTIAL_SCAN
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, -1
    je .Lfile_map_fail
    mov rbx, rax
    mov rcx, rax
    lea rdx, [rsp + 56]
    call GetFileSizeEx
    test eax, eax
    jz .Lfile_map_fail
    mov rdi, [rsp + 56]
    test rdi, rdi
    jle .Lfile_map_fail
    mov rcx, rbx
    xor edx, edx
    mov r8d, 2                 # PAGE_READONLY
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateFileMappingW
    test rax, rax
    jz .Lfile_map_fail
    mov r12, rax
    mov rcx, rax
    mov edx, 4                 # FILE_MAP_READ
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    call MapViewOfFile
    mov rsi, rax
    mov rcx, r12
    call CloseHandle           # the view keeps its section alive
    test rsi, rsi
    jz .Lfile_map_fail
    mov rax, rsi
    mov rdx, rdi
    mov r8, rbx
    jmp .Lfile_map_done
.Lfile_map_fail:
    cmp rbx, -1
    je .Lfile_map_failed
    mov rcx, rbx
    call CloseHandle
.Lfile_map_failed:
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
.Lfile_map_done:
    add rsp, 72
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN file_map

# RCX=view, RDX=bytes, R8=token from file_map.
FN file_unmap
    push rbx
    sub rsp, 32
    mov rbx, r8
    call UnmapViewOfFile
    test rbx, rbx
    jz .Lfile_unmap_done
    mov rcx, rbx
    call CloseHandle
.Lfile_unmap_done:
    add rsp, 32
    pop rbx
    ret
ENDFN file_unmap
