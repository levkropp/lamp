# Cover art in the Windows player, included by src/win/ui.s. MIT, see LICENSE.
# The playback or producer thread copies each file's picture (cover_get) as
# the file opens, since the mapped file closes with playback; the window
# takes it when that file is heard (ui_queue.inc). The UI thread decodes it
# once through the Windows Imaging Component to premultiplied BGRA (at most
# 1024 pixels a side), box-filters it to the layout's size and blends it
# into the pixel canvas above the title.
.equ COVER_SOURCE_MAX, 1024

# R8D=source pixel, R10D=destination pixel, R9D=255 - alpha -> EAX=the
# blended channel at bit \shift.
.macro BLEND_CHANNEL shift
    mov eax, r10d
    shr eax, \shift
    movzx eax, al
    imul eax, r9d
    add eax, 128                          # / 255, rounded
    mov edx, eax
    shr edx, 8
    add eax, edx
    shr eax, 8
    mov edx, r8d
    shr edx, \shift
    movzx edx, dl
    add eax, edx
    cmp eax, 255
    jbe 1f
    mov eax, 255
1:
.endm

.data
.p2align 3
ui_cover_pending: .quad 0            # taken from the file heard: an 8-byte size, then the bytes
ui_cover_block: .quad 0              # the picture shown, in that form
ui_cover_source: .quad 0             # its decoded pixels
ui_cover_scaled: .quad 0             # resampled to ui_cover_tw x ui_cover_th
ui_wic: .quad 0                      # IWICImagingFactory
ui_cover_sw: .long 0
ui_cover_sh: .long 0
ui_cover_tw: .long 0
ui_cover_th: .long 0
ui_com: .long 0
clsid_wic_factory: .long 0xcacaf262
    .short 0x9370, 0x4615
    .byte 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a
iid_wic_factory: .long 0xec5ec8a9
    .short 0xc395, 0x4314
    .byte 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70
guid_pbgra: .long 0x6fddc324
    .short 0x4e03, 0x4bfe
    .byte 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10

.text
# The opened file's picture -> RAX=a copy (an 8-byte size, 0 without one,
# then the bytes), or 0 when memory is short.
LOCALFN ui_cover_copy
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    call cover_get
    mov rsi, rax
    mov rbx, rdx
    test rax, rax
    jnz .Lui_cover_copy_block
    xor ebx, ebx                          # no picture: size 0
.Lui_cover_copy_block:
    lea rcx, [rbx + 8]
    call mem_alloc
    test rax, rax
    jz .Lui_cover_copy_return
    mov [rax], rbx
    lea rdi, [rax + 8]
    mov rcx, rbx
    rep movsb
.Lui_cover_copy_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_copy

# RCX=address of a block pointer: frees the block and clears the pointer.
LOCALFN ui_cover_free
    sub rsp, 40
    mov rax, rcx
    mov rcx, [rax]
    mov qword ptr [rax], 0
    test rcx, rcx
    jz .Lui_cover_free_done
    call mem_free
.Lui_cover_free_done:
    add rsp, 40
    ret
ENDFN ui_cover_free

LOCALFN ui_cover_release
    sub rsp, 40
    lea rcx, [rip + ui_cover_block]
    call ui_cover_free
    lea rcx, [rip + ui_cover_source]
    call ui_cover_free
    lea rcx, [rip + ui_cover_scaled]
    call ui_cover_free
    xor eax, eax
    mov [rip + ui_cover_sw], eax
    mov [rip + ui_cover_sh], eax
    mov [rip + ui_cover_tw], eax
    mov [rip + ui_cover_th], eax
    add rsp, 40
    ret
ENDFN ui_cover_release

# UI thread: takes a handed-over picture and decodes it unless it is the one
# already shown.
LOCALFN ui_cover_update
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor eax, eax
    xchg [rip + ui_cover_pending], rax
    test rax, rax
    jz .Lui_cover_update_return
    mov rbx, rax
    mov rsi, [rip + ui_cover_block]
    test rsi, rsi
    jz .Lui_cover_update_new
    mov rcx, [rbx]
    cmp rcx, [rsi]
    jne .Lui_cover_update_new
    add rsi, 8
    lea rdi, [rbx + 8]
    repe cmpsb                            # ZF stays set for an empty compare
    jne .Lui_cover_update_new
    mov rcx, rbx                          # the same picture (a seek)
    call mem_free
    jmp .Lui_cover_update_return
.Lui_cover_update_new:
    call ui_cover_release
    cmp qword ptr [rbx], 0
    jne .Lui_cover_update_decode
    mov rcx, rbx
    call mem_free
    jmp .Lui_cover_update_return
.Lui_cover_update_decode:
    mov [rip + ui_cover_block], rbx
    call ui_cover_decode
.Lui_cover_update_return:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_update

# RCX=address of a COM object pointer: releases it and clears the pointer.
LOCALFN ui_com_release
    sub rsp, 40
    mov rax, rcx
    mov rcx, [rax]
    mov qword ptr [rax], 0
    test rcx, rcx
    jz .Lui_com_release_done
    mov rax, [rcx]
    call qword ptr [rax + 16]             # IUnknown::Release
.Lui_com_release_done:
    add rsp, 40
    ret
ENDFN ui_com_release

# ui_cover_block -> ui_cover_source (sw x sh premultiplied BGRA), or nothing
# when the Windows Imaging Component cannot decode it.
LOCALFN ui_cover_decode
    push rbx
    push rsi
    sub rsp, 120
    # Locals: [rsp+64] stream, [rsp+72] decoder, [rsp+80] frame, [rsp+88]
    # scaler, [rsp+96] converter, [rsp+104] width, [rsp+108] height.
    xor eax, eax
    mov [rsp + 64], rax
    mov [rsp + 72], rax
    mov [rsp + 80], rax
    mov [rsp + 88], rax
    mov [rsp + 96], rax
    cmp dword ptr [rip + ui_com], 0
    jne .Lui_cover_factory
    mov dword ptr [rip + ui_com], 1
    xor ecx, ecx
    mov edx, 2                            # COINIT_APARTMENTTHREADED
    call CoInitializeEx
.Lui_cover_factory:
    cmp qword ptr [rip + ui_wic], 0
    jne .Lui_cover_stream
    lea rcx, [rip + clsid_wic_factory]
    xor edx, edx
    mov r8d, 1                            # CLSCTX_INPROC_SERVER
    lea r9, [rip + iid_wic_factory]
    lea rax, [rip + ui_wic]
    mov [rsp + 32], rax
    call CoCreateInstance
    test eax, eax
    js .Lui_cover_failed
.Lui_cover_stream:
    mov rcx, [rip + ui_wic]
    lea rdx, [rsp + 64]
    mov rax, [rcx]
    call qword ptr [rax + 14*8]           # CreateStream
    test eax, eax
    js .Lui_cover_failed
    mov rbx, [rip + ui_cover_block]
    mov rcx, [rsp + 64]
    lea rdx, [rbx + 8]
    mov r8, [rbx]
    mov rax, r8
    shr rax, 32                           # a DWORD size
    jnz .Lui_cover_failed
    mov rax, [rcx]
    call qword ptr [rax + 16*8]           # InitializeFromMemory
    test eax, eax
    js .Lui_cover_failed
    mov rcx, [rip + ui_wic]
    mov rdx, [rsp + 64]
    xor r8d, r8d
    xor r9d, r9d                          # WICDecodeMetadataCacheOnDemand
    lea rax, [rsp + 72]
    mov [rsp + 32], rax
    mov rax, [rcx]
    call qword ptr [rax + 4*8]            # CreateDecoderFromStream
    test eax, eax
    js .Lui_cover_failed
    mov rcx, [rsp + 72]
    xor edx, edx
    lea r8, [rsp + 80]
    mov rax, [rcx]
    call qword ptr [rax + 13*8]           # GetFrame
    test eax, eax
    js .Lui_cover_failed
    mov rcx, [rsp + 80]
    lea rdx, [rsp + 104]
    lea r8, [rsp + 108]
    mov rax, [rcx]
    call qword ptr [rax + 3*8]            # GetSize
    test eax, eax
    js .Lui_cover_failed
    mov eax, [rsp + 104]
    mov ecx, [rsp + 108]
    test eax, eax
    jz .Lui_cover_failed
    test ecx, ecx
    jz .Lui_cover_failed
    # Fit within COVER_SOURCE_MAX, keeping the aspect ratio.
    mov rsi, [rsp + 80]                   # the source for the converter
    cmp eax, COVER_SOURCE_MAX
    ja .Lui_cover_shrink
    cmp ecx, COVER_SOURCE_MAX
    jbe .Lui_cover_sized
.Lui_cover_shrink:
    cmp eax, ecx
    jb .Lui_cover_shrink_tall
    imul ecx, ecx, COVER_SOURCE_MAX       # height x max / width
    xchg eax, ecx
    xor edx, edx
    div ecx
    mov ecx, eax
    mov eax, COVER_SOURCE_MAX
    jmp .Lui_cover_shrunk
.Lui_cover_shrink_tall:
    imul eax, eax, COVER_SOURCE_MAX       # width x max / height
    xor edx, edx
    div ecx
    mov ecx, COVER_SOURCE_MAX
.Lui_cover_shrunk:
    test eax, eax
    jnz .Lui_cover_width
    mov eax, 1
.Lui_cover_width:
    test ecx, ecx
    jnz .Lui_cover_height
    mov ecx, 1
.Lui_cover_height:
    mov [rsp + 104], eax
    mov [rsp + 108], ecx
    mov rcx, [rip + ui_wic]
    lea rdx, [rsp + 88]
    mov rax, [rcx]
    call qword ptr [rax + 11*8]           # CreateBitmapScaler
    test eax, eax
    js .Lui_cover_failed
    mov rcx, [rsp + 88]
    mov rdx, [rsp + 80]
    mov r8d, [rsp + 104]
    mov r9d, [rsp + 108]
    mov qword ptr [rsp + 32], 3           # WICBitmapInterpolationModeFant
    mov rax, [rcx]
    call qword ptr [rax + 8*8]            # IWICBitmapScaler::Initialize
    test eax, eax
    js .Lui_cover_failed
    mov rsi, [rsp + 88]
.Lui_cover_sized:
    mov rcx, [rip + ui_wic]
    lea rdx, [rsp + 96]
    mov rax, [rcx]
    call qword ptr [rax + 10*8]           # CreateFormatConverter
    test eax, eax
    js .Lui_cover_failed
    mov rcx, [rsp + 96]
    mov rdx, rsi
    lea r8, [rip + guid_pbgra]
    xor r9d, r9d                          # WICBitmapDitherTypeNone
    mov qword ptr [rsp + 32], 0           # no palette
    mov qword ptr [rsp + 40], 0           # alpha threshold 0.0
    mov qword ptr [rsp + 48], 0           # WICBitmapPaletteTypeCustom
    mov rax, [rcx]
    call qword ptr [rax + 8*8]            # IWICFormatConverter::Initialize
    test eax, eax
    js .Lui_cover_failed
    mov ecx, [rsp + 104]
    imul ecx, [rsp + 108]
    shl rcx, 2
    call mem_alloc
    test rax, rax
    jz .Lui_cover_failed
    mov [rip + ui_cover_source], rax
    mov rcx, [rsp + 96]
    xor edx, edx                          # the whole image
    mov r8d, [rsp + 104]
    shl r8d, 2                            # stride
    mov r9d, r8d
    imul r9d, [rsp + 108]
    mov [rsp + 32], rax
    mov rax, [rcx]
    call qword ptr [rax + 7*8]            # CopyPixels
    test eax, eax
    js .Lui_cover_failed
    mov eax, [rsp + 104]
    mov [rip + ui_cover_sw], eax
    mov eax, [rsp + 108]
    mov [rip + ui_cover_sh], eax
    jmp .Lui_cover_cleanup
.Lui_cover_failed:
    lea rcx, [rip + ui_cover_source]
    call ui_cover_free
    mov dword ptr [rip + ui_cover_sw], 0
    mov dword ptr [rip + ui_cover_sh], 0
.Lui_cover_cleanup:
    lea rcx, [rsp + 96]
    call ui_com_release
    lea rcx, [rsp + 88]
    call ui_com_release
    lea rcx, [rsp + 80]
    call ui_com_release
    lea rcx, [rsp + 72]
    call ui_com_release
    lea rcx, [rsp + 64]
    call ui_com_release
    add rsp, 120
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_decode

# ECX=width, EDX=height: ui_cover_scaled holds the source box-filtered to it
# (each output pixel the mean of the source pixels it covers).
LOCALFN ui_cover_resample
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    cmp ecx, [rip + ui_cover_tw]
    jne .Lui_resample_new
    cmp edx, [rip + ui_cover_th]
    jne .Lui_resample_new
    cmp qword ptr [rip + ui_cover_scaled], 0
    jne .Lui_resample_return
.Lui_resample_new:
    mov [rsp + 32], ecx                   # target width
    mov [rsp + 36], edx                   # target height
    lea rcx, [rip + ui_cover_scaled]
    call ui_cover_free
    mov dword ptr [rip + ui_cover_tw], 0
    mov dword ptr [rip + ui_cover_th], 0
    mov ecx, [rsp + 32]
    imul ecx, [rsp + 36]
    shl rcx, 2
    call mem_alloc
    test rax, rax
    jz .Lui_resample_return
    mov [rip + ui_cover_scaled], rax
    mov rdi, rax                          # output
    mov rsi, [rip + ui_cover_source]
    xor r12d, r12d                        # target row
.Lui_resample_row:
    cmp r12d, [rsp + 36]
    jae .Lui_resample_done
    mov eax, r12d
    mul dword ptr [rip + ui_cover_sh]
    div dword ptr [rsp + 36]
    mov [rsp + 40], eax                   # first source row
    lea eax, [r12 + 1]
    mul dword ptr [rip + ui_cover_sh]
    div dword ptr [rsp + 36]
    cmp eax, [rsp + 40]
    ja .Lui_resample_rows
    mov eax, [rsp + 40]
    inc eax
.Lui_resample_rows:
    mov [rsp + 44], eax                   # end source row
    xor r13d, r13d                        # target column
.Lui_resample_column:
    cmp r13d, [rsp + 32]
    jae .Lui_resample_next_row
    mov eax, r13d
    mul dword ptr [rip + ui_cover_sw]
    div dword ptr [rsp + 32]
    mov [rsp + 48], eax                   # first source column
    lea eax, [r13 + 1]
    mul dword ptr [rip + ui_cover_sw]
    div dword ptr [rsp + 32]
    cmp eax, [rsp + 48]
    ja .Lui_resample_columns
    mov eax, [rsp + 48]
    inc eax
.Lui_resample_columns:
    mov [rsp + 52], eax                   # end source column
    xor r8d, r8d                          # blue, green, red, alpha sums
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov r14d, [rsp + 40]
.Lui_resample_sum_row:
    cmp r14d, [rsp + 44]
    jae .Lui_resample_mean
    mov eax, r14d
    imul eax, [rip + ui_cover_sw]
    mov r15d, [rsp + 48]
.Lui_resample_sum:
    cmp r15d, [rsp + 52]
    jae .Lui_resample_sum_next
    lea ebx, [rax + r15]
    mov ebx, [rsi + rbx*4]
    movzx ecx, bl
    add r8d, ecx
    movzx ecx, bh
    add r9d, ecx
    shr ebx, 16
    movzx ecx, bl
    add r10d, ecx
    movzx ecx, bh
    add r11d, ecx
    inc r15d
    jmp .Lui_resample_sum
.Lui_resample_sum_next:
    inc r14d
    jmp .Lui_resample_sum_row
.Lui_resample_mean:
    mov ecx, [rsp + 44]
    sub ecx, [rsp + 40]
    mov ebx, [rsp + 52]
    sub ebx, [rsp + 48]
    imul ecx, ebx                         # pixels summed
    mov eax, r11d
    xor edx, edx
    div ecx
    mov ebx, eax                          # alpha
    shl ebx, 8
    mov eax, r10d
    xor edx, edx
    div ecx
    or ebx, eax
    shl ebx, 8
    mov eax, r9d
    xor edx, edx
    div ecx
    or ebx, eax
    shl ebx, 8
    mov eax, r8d
    xor edx, edx
    div ecx
    or ebx, eax
    mov [rdi], ebx
    add rdi, 4
    inc r13d
    jmp .Lui_resample_column
.Lui_resample_next_row:
    inc r12d
    jmp .Lui_resample_row
.Lui_resample_done:
    mov eax, [rsp + 32]
    mov [rip + ui_cover_tw], eax
    mov eax, [rsp + 36]
    mov [rip + ui_cover_th], eax
.Lui_resample_return:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_resample

# ECX=x, EDX=y: blends ui_cover_scaled (premultiplied) into the canvas,
# clipped to it: d = s + d x (255 - alpha) / 255 per channel.
LOCALFN ui_cover_blit
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12d, ecx
    mov r13d, edx
    mov rsi, [rip + ui_cover_scaled]
    test rsi, rsi
    jz .Lui_blit_return
    xor r14d, r14d                        # row
.Lui_blit_row:
    cmp r14d, [rip + ui_cover_th]
    jae .Lui_blit_return
    lea eax, [r13 + r14]
    cmp eax, [rip + ui_height]
    jae .Lui_blit_return
    imul eax, [rip + ui_width]
    mov rdi, [rip + ui_pixels]
    lea rdi, [rdi + rax*4]
    mov eax, [rip + ui_cover_tw]
    imul eax, r14d
    lea rbx, [rsi + rax*4]
    xor ecx, ecx                          # column
.Lui_blit_pixel:
    cmp ecx, [rip + ui_cover_tw]
    jae .Lui_blit_next
    lea r15d, [r12 + rcx]
    cmp r15d, [rip + ui_width]
    jae .Lui_blit_next
    mov r8d, [rbx + rcx*4]                # source
    mov r9d, r8d
    shr r9d, 24
    xor r9d, 255                          # 255 - alpha
    jz .Lui_blit_store
    mov r10d, [rdi + r15*4]               # destination
    BLEND_CHANNEL 0
    mov r11d, eax
    BLEND_CHANNEL 8
    shl eax, 8
    or r11d, eax
    BLEND_CHANNEL 16
    shl eax, 16
    or r11d, eax
    mov r8d, r11d
.Lui_blit_store:
    and r8d, 0xffffff
    mov [rdi + r15*4], r8d
    inc ecx
    jmp .Lui_blit_pixel
.Lui_blit_next:
    inc r14d
    jmp .Lui_blit_row
.Lui_blit_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_blit

# -> EAX=the title's y. With a decoded picture and room for it (a side of 48
# pixels or more), the picture and the title are centred together between
# the header and the controls; otherwise the title takes its usual place.
LOCALFN ui_cover_place
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    call ui_cover_update
    cmp qword ptr [rip + ui_cover_source], 0
    je .Lui_place_title
    mov eax, [rip + ui_state]
    dec eax
    cmp eax, 1                            # playing or finished
    ja .Lui_place_title
    mov ebx, [rip + ui_height]
    sub ebx, 164 + 52 + 24 + 12 + 42      # the side's room
    mov eax, [rip + ui_width]
    sub eax, 64
    cmp ebx, eax
    cmovg ebx, eax
    cmp ebx, 360
    jle .Lui_place_side
    mov ebx, 360
.Lui_place_side:
    cmp ebx, 48
    jl .Lui_place_title
    # Fit the picture in a square of that side.
    mov esi, [rip + ui_cover_sw]
    mov edi, [rip + ui_cover_sh]
    cmp esi, edi
    jb .Lui_place_tall
    mov eax, edi
    mul ebx
    div esi
    mov edi, eax                          # height
    mov esi, ebx
    jmp .Lui_place_fitted
.Lui_place_tall:
    mov eax, esi
    mul ebx
    div edi
    mov esi, eax                          # width
    mov edi, ebx
.Lui_place_fitted:
    test esi, esi
    jz .Lui_place_title
    test edi, edi
    jz .Lui_place_title
    mov ecx, esi
    mov edx, edi
    call ui_cover_resample
    cmp qword ptr [rip + ui_cover_scaled], 0
    je .Lui_place_title
    # The group: picture, 12 pixels, title (42).
    mov ebx, [rip + ui_height]
    sub ebx, 164 + 52
    sub ebx, edi
    sub ebx, 12 + 42
    sar ebx, 1
    add ebx, 52                           # its top
    mov ecx, [rip + ui_width]
    sub ecx, esi
    shr ecx, 1
    mov edx, ebx
    call ui_cover_blit
    lea eax, [rbx + rdi + 12]
    jmp .Lui_place_return
.Lui_place_title:
    mov eax, [rip + ui_height]
    sub eax, 72
    shr eax, 1
.Lui_place_return:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_cover_place
