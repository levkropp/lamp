# Original playlist reader in x86-64 assembly. MIT, see LICENSE.
# playlist_expand replaces M3U/M3U8 and PLS playlists in a list of paths by
# their entries, for the queue (src/queue.s). A playlist is recognized by its
# extension (.m3u, .m3u8, .pls, any case). M3U: one entry per line; lines
# starting with "#" (#EXTM3U, #EXTINF and others) and empty lines are
# skipped. PLS: "FileN=entry" lines in file order; other lines are skipped.
# Text is UTF-8 (a byte order mark is skipped); lines that are not valid
# UTF-8 are read as Latin-1. Entries relative to the playlist resolve against
# its directory; "file://" URIs are percent-decoded; other URLs pass through
# unchanged (and are skipped as unplayable). Playlists inside playlists
# expand to a depth of four. Paths are UTF-8 on Linux and UTF-16 on Windows.
.include "lamp.inc"
.globl playlist_expand

.equ PL_ENTRIES, 65536
.equ PL_ARENA, 1 << 22              # path characters
.equ PL_DEPTH, 4
.equ PL_ENTRY_MAX, 16384            # bytes of one entry
.ifdef WINDOWS
.equ PL_CHAR, 2
.else
.equ PL_CHAR, 1
.endif

# EAX=character -> [dst].
.macro PUTC dst
.ifdef WINDOWS
    mov word ptr \dst, ax
.else
    mov byte ptr \dst, al
.endif
.endm
# [src] -> 32-bit register.
.macro GETC reg, src
.ifdef WINDOWS
    movzx \reg, word ptr \src
.else
    movzx \reg, byte ptr \src
.endif
.endm

.data
pl_list: .quad 0                    # path pointers
pl_count: .long 0
pl_arena: .quad 0
pl_used: .quad 0                    # arena characters used

.bss
pl_bytes: .zero PL_ENTRY_MAX

.text
# RCX=paths, EDX=count -> RAX=paths with playlists expanded, EDX=count. The
# original list returns when memory is short. Each call frees the list the
# previous call returned.
FN playlist_expand
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov edi, edx
    xor ecx, ecx                          # an earlier expansion's list
    xchg rcx, [rip + pl_list]
    call mem_free
    xor ecx, ecx
    xchg rcx, [rip + pl_arena]
    call mem_free
    mov ecx, PL_ENTRIES*8
    call mem_alloc
    test rax, rax
    jz .Lpl_expand_original
    mov [rip + pl_list], rax
    mov ecx, PL_ARENA*PL_CHAR
    call mem_alloc
    test rax, rax
    jz .Lpl_expand_original
    mov [rip + pl_arena], rax
    mov dword ptr [rip + pl_count], 0
    mov qword ptr [rip + pl_used], 0
    xor ebx, ebx
.Lpl_expand_item:
    cmp ebx, edi
    jae .Lpl_expand_done
    mov r12, [rsi + rbx*8]
    mov rcx, r12
    call pl_kind
    test eax, eax
    jz .Lpl_expand_path
    mov rcx, r12
    mov edx, eax
    xor r8d, r8d
    call pl_read
    jmp .Lpl_expand_next
.Lpl_expand_path:
    mov rcx, r12
    call pl_append
.Lpl_expand_next:
    inc ebx
    jmp .Lpl_expand_item
.Lpl_expand_done:
    mov rax, [rip + pl_list]
    mov edx, [rip + pl_count]
    jmp .Lpl_expand_return
.Lpl_expand_original:
    mov rax, rsi
    mov edx, edi
.Lpl_expand_return:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN playlist_expand

# RCX=path pointer: added to the list (dropped when it is full).
LOCALFN pl_append
    mov eax, [rip + pl_count]
    cmp eax, PL_ENTRIES
    jae .Lpl_append_full
    mov rdx, [rip + pl_list]
    mov [rdx + rax*8], rcx
    inc dword ptr [rip + pl_count]
.Lpl_append_full:
    ret
ENDFN pl_append

# RCX=path -> EAX=1 for an M3U playlist, 2 for PLS, 0 otherwise (by the
# extension after the last dot of the last component).
LOCALFN pl_kind
    xor r8, r8                            # last dot
    mov rdx, rcx
.Lpl_kind_char:
    GETC eax, [rdx]
    test eax, eax
    jz .Lpl_kind_end
    cmp eax, '.'
    jne .Lpl_kind_separator
    mov r8, rdx
.Lpl_kind_separator:
    cmp eax, '/'
    je .Lpl_kind_component
.ifdef WINDOWS
    cmp eax, 92
    je .Lpl_kind_component
.endif
    add rdx, PL_CHAR
    jmp .Lpl_kind_char
.Lpl_kind_component:
    xor r8, r8
    add rdx, PL_CHAR
    jmp .Lpl_kind_char
.Lpl_kind_end:
    xor eax, eax
    test r8, r8
    jz .Lpl_kind_return
    # The extension, lowercase ASCII, up to five characters.
    xor r9d, r9d                          # packed characters
    xor r10d, r10d                        # count
    lea rdx, [r8 + PL_CHAR]
.Lpl_kind_ext:
    GETC ecx, [rdx]
    test ecx, ecx
    jz .Lpl_kind_compare
    cmp r10d, 4
    jae .Lpl_kind_return
    cmp ecx, 0x80
    jae .Lpl_kind_return
    lea r11d, [rcx - 'A']
    cmp r11d, 25
    ja .Lpl_kind_lower
    add ecx, 32
.Lpl_kind_lower:
    shl r9d, 8
    or r9d, ecx
    inc r10d
    add rdx, PL_CHAR
    jmp .Lpl_kind_ext
.Lpl_kind_compare:
    mov eax, 1
    cmp r9d, 0x6d3375                     # "m3u"
    je .Lpl_kind_return
    cmp r9d, 0x6d337538                   # "m3u8"
    je .Lpl_kind_return
    mov eax, 2
    cmp r9d, 0x706c73                     # "pls"
    je .Lpl_kind_return
    xor eax, eax
.Lpl_kind_return:
    ret
ENDFN pl_kind

# RCX=playlist path, EDX=kind (1 M3U, 2 PLS), R8D=depth: appends its
# entries (or the path itself when it cannot be read).
LOCALFN pl_read
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov r12, rcx                          # playlist path
    mov r13d, edx
    mov r14d, r8d
    call file_map
    test rax, rax
    jz .Lpl_read_unreadable
    mov [rsp + 32], rax                   # view
    mov [rsp + 40], rdx                   # bytes
    mov [rsp + 48], r8                    # token
    mov rsi, rax
    lea rdi, [rax + rdx]                  # end
    lea rax, [rsi + 3]
    cmp rax, rdi
    ja .Lpl_read_line
    cmp word ptr [rsi], 0xbbef            # UTF-8 byte order mark
    jne .Lpl_read_line
    cmp byte ptr [rsi + 2], 0xbf
    jne .Lpl_read_line
    add rsi, 3
.Lpl_read_line:
    cmp rsi, rdi
    jae .Lpl_read_done
    mov rbx, rsi                          # line start
.Lpl_read_eol:
    cmp rsi, rdi
    jae .Lpl_read_have_line
    cmp byte ptr [rsi], 10
    je .Lpl_read_have_line
    inc rsi
    jmp .Lpl_read_eol
.Lpl_read_have_line:
    mov r15, rsi                          # line end
    inc rsi                               # past the newline
    cmp r15, rbx
    je .Lpl_read_line
    cmp byte ptr [r15 - 1], 13
    jne .Lpl_read_trimmed
    dec r15
    cmp r15, rbx
    je .Lpl_read_line
.Lpl_read_trimmed:
    cmp r13d, 2
    je .Lpl_read_pls
    cmp byte ptr [rbx], '#'
    je .Lpl_read_line
    jmp .Lpl_read_entry
.Lpl_read_pls:
    # "File" (any case), digits, "=".
    mov rax, r15
    sub rax, rbx
    cmp rax, 6
    jb .Lpl_read_line
    mov eax, [rbx]
    or eax, 0x20202020
    cmp eax, 0x656c6966                   # "file"
    jne .Lpl_read_line
    lea rdx, [rbx + 4]
    movzx eax, byte ptr [rdx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpl_read_line
.Lpl_read_digits:
    inc rdx
    cmp rdx, r15
    jae .Lpl_read_line
    movzx eax, byte ptr [rdx]
    sub eax, '0'
    cmp eax, 9
    jbe .Lpl_read_digits
    cmp byte ptr [rdx], '='
    jne .Lpl_read_line
    lea rbx, [rdx + 1]
    cmp rbx, r15
    je .Lpl_read_line
.Lpl_read_entry:
    mov rcx, rbx
    mov rdx, r15
    sub rdx, rbx
    mov r8, r12
    call pl_path                          # -> RAX=path in the arena, or 0
    test rax, rax
    jz .Lpl_read_line
    mov rbx, rax
    mov rcx, rax
    call pl_kind
    test eax, eax
    jz .Lpl_read_add
    lea r8d, [r14 + 1]
    cmp r8d, PL_DEPTH
    jae .Lpl_read_line                    # too deep: dropped
    mov rcx, rbx
    mov edx, eax
    call pl_read
    jmp .Lpl_read_line
.Lpl_read_add:
    mov rcx, rbx
    call pl_append
    jmp .Lpl_read_line
.Lpl_read_done:
    mov rcx, [rsp + 32]
    mov rdx, [rsp + 40]
    mov r8, [rsp + 48]
    call file_unmap
    jmp .Lpl_read_return
.Lpl_read_unreadable:
    mov rcx, r12                          # the queue reports it
    call pl_append
.Lpl_read_return:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pl_read

# RCX=entry text (UTF-8, or Latin-1 when invalid), RDX=bytes, R8=playlist
# path -> RAX=NUL-terminated path in the arena (relative entries joined to
# the playlist's directory; file:// URIs decoded), 0 when it does not fit.
LOCALFN pl_path
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    lea r12, [rcx + rdx]                  # entry end
    mov r13, r8
    # First the entry's bytes into pl_bytes: file:// URIs lose the scheme and
    # host and are percent-decoded; other text is copied.
    cmp rdx, PL_ENTRY_MAX
    ja .Lpl_path_full
    lea rdi, [rip + pl_bytes]
    xor r9d, r9d                          # a file:// URI
    cmp rdx, 7
    jb .Lpl_path_bytes
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x656c6966                   # "file"
    jne .Lpl_path_bytes
    cmp dword ptr [rsi + 3], 0x2f2f3a65   # "e://"
    jne .Lpl_path_bytes
    add rsi, 7
    mov r9d, 1
.Lpl_path_host:
    cmp rsi, r12                          # skip a host name (localhost)
    jae .Lpl_path_bytes
    cmp byte ptr [rsi], '/'
    je .Lpl_path_drive
    inc rsi
    jmp .Lpl_path_host
.Lpl_path_drive:
.ifdef WINDOWS
    lea rax, [rsi + 3]                    # "/C:/..." -> "C:/..."
    cmp rax, r12
    ja .Lpl_path_bytes
    cmp byte ptr [rsi + 2], ':'
    jne .Lpl_path_bytes
    inc rsi
.endif
.Lpl_path_bytes:
    cmp rsi, r12
    jae .Lpl_path_decoded
    movzx eax, byte ptr [rsi]
    inc rsi
    test r9d, r9d
    jz .Lpl_path_byte
    cmp eax, '%'
    jne .Lpl_path_byte
    lea rcx, [rsi + 2]
    cmp rcx, r12
    ja .Lpl_path_byte
    movzx ecx, byte ptr [rsi]
    call pl_hex
    js .Lpl_path_percent
    mov edx, ecx
    movzx ecx, byte ptr [rsi + 1]
    call pl_hex
    js .Lpl_path_percent
    shl edx, 4
    lea eax, [rcx + rdx]
    add rsi, 2
    jmp .Lpl_path_byte
.Lpl_path_percent:
    mov eax, '%'
.Lpl_path_byte:
    mov [rdi], al
    inc rdi
    jmp .Lpl_path_bytes
.Lpl_path_decoded:
    lea rsi, [rip + pl_bytes]
    mov r12, rdi                          # decoded end
    # Room in the arena: the directory, two characters per byte and a NUL.
    mov rax, r12
    sub rax, rsi
    lea rax, [rax*2 + 4096 + 1]
    add rax, [rip + pl_used]
    cmp rax, PL_ARENA
    ja .Lpl_path_full
    mov rdi, [rip + pl_arena]
    mov rax, [rip + pl_used]
    imul rax, rax, PL_CHAR
    add rdi, rax
    mov rbx, rdi                          # result
    test r9d, r9d
    jnz .Lpl_path_copy                    # file:// paths are absolute
    # Other URLs ("scheme://") and absolute paths stay as they are.
    mov rdx, rsi
.Lpl_path_scan:
    lea rax, [rdx + 3]
    cmp rax, r12
    ja .Lpl_path_absolute
    cmp byte ptr [rdx], ':'
    jne .Lpl_path_scan_next
    cmp word ptr [rdx + 1], 0x2f2f        # "//"
    je .Lpl_path_copy
.Lpl_path_scan_next:
    inc rdx
    jmp .Lpl_path_scan
.Lpl_path_absolute:
    cmp rsi, r12
    je .Lpl_path_full                     # an empty entry
    cmp byte ptr [rsi], '/'
    je .Lpl_path_copy
.ifdef WINDOWS
    cmp byte ptr [rsi], 92
    je .Lpl_path_copy
    lea rax, [rsi + 2]
    cmp rax, r12
    ja .Lpl_path_relative
    cmp byte ptr [rsi + 1], ':'
    je .Lpl_path_copy
.Lpl_path_relative:
.endif
    # The playlist's directory: up to its last separator.
    xor r8, r8
    mov rdx, r13
.Lpl_path_dir:
    GETC eax, [rdx]
    test eax, eax
    jz .Lpl_path_dir_end
    cmp eax, '/'
    je .Lpl_path_dir_mark
.ifdef WINDOWS
    cmp eax, 92
    je .Lpl_path_dir_mark
.endif
    add rdx, PL_CHAR
    jmp .Lpl_path_dir
.Lpl_path_dir_mark:
    add rdx, PL_CHAR
    mov r8, rdx
    jmp .Lpl_path_dir
.Lpl_path_dir_end:
    test r8, r8
    jz .Lpl_path_copy
    mov rdx, r13
    sub r8, r13
    cmp r8, 4096*PL_CHAR
    ja .Lpl_path_full
.Lpl_path_dir_copy:
    test r8, r8
    jz .Lpl_path_copy
    GETC eax, [rdx]
    PUTC [rdi]
    add rdx, PL_CHAR
    add rdi, PL_CHAR
    sub r8, PL_CHAR
    jmp .Lpl_path_dir_copy
.Lpl_path_copy:
    # The entry: UTF-8 when valid, else Latin-1.
    mov rcx, rsi
    mov rdx, r12
    sub rdx, rsi
    call pl_utf8_valid
    mov r10d, eax
.Lpl_path_char:
    cmp rsi, r12
    jae .Lpl_path_end
    movzx eax, byte ptr [rsi]
    inc rsi
.ifdef WINDOWS
    test r10d, r10d
    jz .Lpl_path_unit
    cmp eax, 0x80
    jb .Lpl_path_unit
    mov ecx, 1
    and eax, 0x1f
    cmp byte ptr [rsi - 1], 0xe0
    jb .Lpl_path_more
    mov ecx, 2
    and eax, 0x0f
    cmp byte ptr [rsi - 1], 0xf0
    jb .Lpl_path_more
    mov ecx, 3
    and eax, 0x07
.Lpl_path_more:
    movzx edx, byte ptr [rsi]             # valid: the continuation is there
    inc rsi
    and edx, 0x3f
    shl eax, 6
    or eax, edx
    dec ecx
    jnz .Lpl_path_more
    cmp eax, 0x10000
    jb .Lpl_path_unit
    sub eax, 0x10000
    mov ecx, eax
    shr ecx, 10
    add ecx, 0xd800
    mov [rdi], cx
    add rdi, 2
    and eax, 0x3ff
    add eax, 0xdc00
.Lpl_path_unit:
    mov [rdi], ax
    add rdi, 2
.else
    test r10d, r10d                       # Linux paths are bytes: Latin-1 to UTF-8
    jnz .Lpl_path_raw
    cmp eax, 0x80
    jb .Lpl_path_raw
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xc0
    mov [rdi], cl
    inc rdi
    and eax, 0x3f
    or eax, 0x80
.Lpl_path_raw:
    mov [rdi], al
    inc rdi
.endif
    jmp .Lpl_path_char
.Lpl_path_end:
    xor eax, eax
    PUTC [rdi]
    add rdi, PL_CHAR
    mov rax, rdi
    sub rax, [rip + pl_arena]
.ifdef WINDOWS
    shr rax, 1
.endif
    mov [rip + pl_used], rax
    mov rax, rbx
    jmp .Lpl_path_return
.Lpl_path_full:
    xor eax, eax
.Lpl_path_return:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN pl_path

# ECX=ASCII character -> ECX=hex digit value, SF set when it is none.
# Preserves EDX.
LOCALFN pl_hex
    lea eax, [rcx - '0']
    cmp eax, 9
    jbe .Lpl_hex_value
    or ecx, 0x20
    lea eax, [rcx - 'a']
    cmp eax, 5
    ja .Lpl_hex_none
    add eax, 10
.Lpl_hex_value:
    mov ecx, eax
    test ecx, ecx                         # clears SF (0-15)
    ret
.Lpl_hex_none:
    or eax, -1                            # sets SF
    ret
ENDFN pl_hex

# RCX=bytes, RDX=count -> EAX=1 when they are valid UTF-8.
LOCALFN pl_utf8_valid
    xor r8, r8
.Lpl_utf8_char:
    cmp r8, rdx
    jae .Lpl_utf8_yes
    movzx eax, byte ptr [rcx + r8]
    inc r8
    cmp eax, 0x80
    jb .Lpl_utf8_char
    mov r9d, 1
    cmp eax, 0xc2
    jb .Lpl_utf8_no
    cmp eax, 0xe0
    jb .Lpl_utf8_continue
    mov r9d, 2
    cmp eax, 0xf0
    jb .Lpl_utf8_continue
    mov r9d, 3
    cmp eax, 0xf4
    ja .Lpl_utf8_no
.Lpl_utf8_continue:
    cmp r8, rdx
    jae .Lpl_utf8_no
    movzx eax, byte ptr [rcx + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne .Lpl_utf8_no
    inc r8
    dec r9d
    jnz .Lpl_utf8_continue
    jmp .Lpl_utf8_char
.Lpl_utf8_yes:
    mov eax, 1
    ret
.Lpl_utf8_no:
    xor eax, eax
    ret
ENDFN pl_utf8_valid
