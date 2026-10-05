# LAMP Linux x86-64 platform services: raw system calls, no C library.
# Same contract as src/win/platform.s; see src/lamp.inc. MIT license.
# Functions follow LAMP's Microsoft x64 convention, so RDI and RSI are saved
# around system calls.
.include "lamp.inc"
.include "linux.inc"

.text
# RCX=bytes -> RAX=zeroed, page-aligned block or 0.
FN mem_alloc
    mov edx, PROT_READ | PROT_WRITE
    jmp mem_map_anonymous
ENDFN mem_alloc

# RCX=bytes -> RAX=reserved address range or 0. Commit pages before use.
FN mem_reserve
    mov edx, PROT_NONE
    jmp mem_map_anonymous
ENDFN mem_reserve

# RCX=bytes, EDX=protection for the caller's pages. One leading page records
# the mapping length so mem_free needs only the block address.
LOCALFN mem_map_anonymous
    push rdi
    push rsi
    push rbx
    mov ebx, edx
    mov rax, rcx
    add rax, 4096 + 4095
    jc .Lmem_map_fail
    and rax, -4096
    mov rsi, rax
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .Lmem_map_fail
    mov [rax], rsi
    test ebx, ebx
    jnz .Lmem_map_done
    push rax
    lea rdi, [rax + 4096]
    sub rsi, 4096
    xor edx, edx               # PROT_NONE until mem_commit
    mov eax, SYS_mprotect
    syscall
    mov rcx, rax
    pop rax
    test rcx, rcx
    jz .Lmem_map_done
    mov rdi, rax
    mov rsi, [rax]
    mov eax, SYS_munmap
    syscall
.Lmem_map_fail:
    xor eax, eax
    jmp .Lmem_map_return
.Lmem_map_done:
    add rax, 4096
.Lmem_map_return:
    pop rbx
    pop rsi
    pop rdi
    ret
ENDFN mem_map_anonymous

# RCX=address inside a reserved range, RDX=bytes -> RAX=address or 0.
# Newly committed pages read as zero.
FN mem_commit
    push rdi
    push rsi
    mov rdi, rcx
    and rdi, -4096
    lea rsi, [rcx + rdx + 4095]
    and rsi, -4096
    sub rsi, rdi
    mov r8, rcx
    mov edx, PROT_READ | PROT_WRITE
    mov eax, SYS_mprotect
    syscall
    test rax, rax
    mov eax, 0
    cmovz rax, r8
    pop rsi
    pop rdi
    ret
ENDFN mem_commit

# RCX=block from mem_alloc/mem_reserve, or 0.
FN mem_free
    test rcx, rcx
    jz .Lmem_free_none
    push rdi
    push rsi
    lea rdi, [rcx - 4096]
    mov rsi, [rdi]
    mov eax, SYS_munmap
    syscall
    pop rsi
    pop rdi
.Lmem_free_none:
    ret
ENDFN mem_free

# RCX=NUL-terminated UTF-8 path -> RAX=read-only view or 0, RDX=bytes, R8=0.
# Only nonempty regular files map. A file truncated by another process while
# mapped raises SIGBUS, as with other mmap readers.
FN file_map
    push rdi
    push rsi
    push rbx
    push r12
    sub rsp, 152               # struct stat
    mov rdi, rcx
    mov esi, O_RDONLY | O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    mov eax, SYS_open
    syscall
    test eax, eax
    js .Lfile_map_fail
    mov ebx, eax
    mov edi, eax
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    test rax, rax
    jnz .Lfile_map_close
    mov eax, [rsp + STAT_MODE]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lfile_map_close
    mov r12, [rsp + STAT_SIZE]
    test r12, r12
    jle .Lfile_map_close
    xor edi, edi
    mov rsi, r12
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    mov r8d, ebx
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .Lfile_map_close
    mov rsi, rax
    mov edi, ebx
    mov eax, SYS_close
    syscall
    mov rax, rsi
    mov rdx, r12
    jmp .Lfile_map_done
.Lfile_map_close:
    mov edi, ebx
    mov eax, SYS_close
    syscall
.Lfile_map_fail:
    xor eax, eax
    xor edx, edx
.Lfile_map_done:
    xor r8d, r8d
    add rsp, 152
    pop r12
    pop rbx
    pop rsi
    pop rdi
    ret
ENDFN file_map

# RCX=view, RDX=bytes, R8=token from file_map.
FN file_unmap
    push rdi
    push rsi
    mov rdi, rcx
    mov rsi, rdx
    mov eax, SYS_munmap
    syscall
    pop rsi
    pop rdi
    ret
ENDFN file_unmap
