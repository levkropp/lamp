// Owned UTF-8 path arrays for native callers. The count is stored 16 bytes
// before the returned array; every string is copied before replacing a list.
.include "mac.inc"

FN _lamp_copy_paths
    ENTER
    mov x19, x0
    mov w20, w1
    cbz w20, 4f
    mov w9, #65536
    cmp w20, w9
    b.hi 4f
    mov w0, #1
    lsl x1, x20, #3
    add x1, x1, #16
    bl _calloc
    cbz x0, 4f
    str w20, [x0]
    add x21, x0, #16
    mov x22, #0
1:  ldr x0, [x19, x22, lsl #3]
    cbz x0, 3f
    bl _strdup
    cbz x0, 3f
    str x0, [x21, x22, lsl #3]
    add x22, x22, #1
    cmp x22, x20
    b.lo 1b
    mov x0, x21
    b 5f
3:  mov x0, x21
    bl _lamp_free_paths
4:  mov x0, #0
5:  LEAVE
    ret

FN _lamp_free_paths
    ENTER
    cbz x0, 3f
    mov x19, x0
    ldr w20, [x19, #-16]
    mov x21, #0
1:  cmp x21, x20
    b.hs 2f
    ldr x0, [x19, x21, lsl #3]
    bl _free
    add x21, x21, #1
    b 1b
2:  sub x0, x19, #16
    bl _free
3:  LEAVE
    ret

// Expands playlists and copies the result. Requires exclusive decoder-stack
// ownership; the returned native array outlives the shared playlist arena.
FN _lamp_prepare_paths
    ENTER 16
    mov x2, sp
    bl _lamp_playlist_expand
    ldr w1, [sp]
    bl _lamp_copy_paths
    mov x19, x0
    bl _playlist_clear
    mov x0, x19
    LEAVE
    ret
