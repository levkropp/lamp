# Original D3D11 hardware submission/readback backend. MIT.
# SDK ABI and DXVA H.264 specification; no external codec implementation.
.include "lamp.inc"
.include "video.inc"
RODATA
.p2align 4
wv_video_device_iid: .long 0x10ec4d5b; .short 0x975a,0x4689; .byte 0xb9,0xe4,0xd0,0xaa,0xc3,0x0f,0xe3,0x33
wv_video_context_iid: .long 0x61f21c45; .short 0x3c0e,0x4a74; .byte 0x9c,0xea,0x67,0x10,0x0d,0x9a,0xd5,0xe4
wv_h264_profile: .long 0x1b81be68; .short 0xa0c7,0x11d3; .byte 0xb9,0x84,0,0xc0,0x4f,0x2e,0x73,0xc5
wv_no_encrypt: .long 0x1b81bed0; .short 0xa0c7,0x11d3; .byte 0xb9,0x84,0,0xc0,0x4f,0x2e,0x73,0xc5
wv_release_order: .byte WV_VIEW,WV_STAGING,WV_TEXTURE,WV_DECODER,WV_VIDEO_CONTEXT,WV_VIDEO_DEVICE,WV_CONTEXT,WV_DEVICE

# RCX=zeroed/new 1024B context, EDX/R8D=coded width/height (16..4096,
# multiples of16). Default hardware adapter only; never WARP/software fallback.
# HRESULT; all partially acquired resources are released on failure.
FN win_video_open
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 88
    mov rbx, rcx
    mov esi, edx
    mov edi, r8d
    xor eax, eax
.Lwv_open_owned:
    cmp qword ptr [rbx+rax*8], 0
    jne .Lwv_open_busy
    inc eax
    cmp eax, 8
    jb .Lwv_open_owned
    cmp esi, 16
    jb .Lwv_open_invalid
    cmp edi, 16
    jb .Lwv_open_invalid
    cmp esi, 4096
    ja .Lwv_open_invalid
    cmp edi, 4096
    ja .Lwv_open_invalid
    mov eax, esi
    or eax, edi
    test eax, 15
    jnz .Lwv_open_invalid
    mov [rbx+WV_WIDTH], esi
    mov [rbx+WV_HEIGHT], edi
    xor ecx, ecx
    mov edx, 1                 # D3D_DRIVER_TYPE_HARDWARE
    xor r8d, r8d
    mov r9d, 0x820             # VIDEO_SUPPORT | BGRA_SUPPORT
    mov qword ptr [rsp+32], 0
    mov qword ptr [rsp+40], 0
    mov qword ptr [rsp+48], 7  # SDK version
    mov [rsp+56], rbx
    lea rax, [rbx+WV_FEATURE]
    mov [rsp+64], rax
    lea rax, [rbx+WV_CONTEXT]
    mov [rsp+72], rax
    call D3D11CreateDevice
    test eax, eax
    js .Lwv_open_fail
    mov rcx, [rbx+WV_DEVICE]
    mov rax, [rcx]
    lea rdx, [rip+wv_video_device_iid]
    lea r8, [rbx+WV_VIDEO_DEVICE]
    call [rax]
    test eax, eax
    js .Lwv_open_fail
    mov rcx, [rbx+WV_CONTEXT]
    mov rax, [rcx]
    lea rdx, [rip+wv_video_context_iid]
    lea r8, [rbx+WV_VIDEO_CONTEXT]
    call [rax]
    test eax, eax
    js .Lwv_open_fail
    movdqu xmm0, [rip+wv_h264_profile]
    movdqu [rbx+WV_DESC], xmm0
    mov [rbx+WV_DESC+16], esi
    mov [rbx+WV_DESC+20], edi
    mov dword ptr [rbx+WV_DESC+24], 103 # DXGI_FORMAT_NV12
    mov rcx, [rbx+WV_VIDEO_DEVICE]
    lea rdx, [rbx+WV_DESC]
    mov r8d, 103
    lea r9, [rsp+80]
    mov dword ptr [rsp+80], 0
    mov rax, [rcx]
    call [rax+13*8]            # CheckVideoDecoderFormat
    test eax, eax
    js .Lwv_open_fail
    cmp dword ptr [rsp+80], 0
    je .Lwv_open_unsupported
    mov rcx, [rbx+WV_VIDEO_DEVICE]
    lea rdx, [rbx+WV_DESC]
    lea r8, [rsp+80]
    mov rax, [rcx]
    call [rax+14*8]            # GetVideoDecoderConfigCount
    test eax, eax
    js .Lwv_open_fail
    cmp dword ptr [rsp+80], 64
    ja .Lwv_open_unsupported
    xor ebp, ebp
.Lwv_open_config:
    cmp ebp, [rsp+80]
    jae .Lwv_open_unsupported
    mov rcx, [rbx+WV_VIDEO_DEVICE]
    lea rdx, [rbx+WV_DESC]
    mov r8d, ebp
    lea r9, [rbx+WV_CONFIG]
    mov rax, [rcx]
    call [rax+15*8]
    test eax, eax
    js .Lwv_open_fail
    cmp dword ptr [rbx+WV_CONFIG+48], 2 # H.264 short-slice raw bitstream
    jne .Lwv_open_next_config
    test word ptr [rbx+WV_CONFIG+98], 0x4000 # array-backed decoder required
    jnz .Lwv_open_next_config
    movdqu xmm0, [rip+wv_no_encrypt]
    movdqu xmm1, [rbx+WV_CONFIG]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    cmp eax, 65535
    jne .Lwv_open_next_config
    movdqu xmm1, [rbx+WV_CONFIG+16]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    cmp eax, 65535
    jne .Lwv_open_next_config
    movdqu xmm1, [rbx+WV_CONFIG+32]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    cmp eax, 65535
    jne .Lwv_open_next_config
    movzx eax, word ptr [rbx+WV_CONFIG+96]
    test eax, eax
    jz .Lwv_open_next_config
    cmp eax, 32
    ja .Lwv_open_next_config
    mov [rbx+WV_POOL], eax
    # Pool plus one readback surface must fit 128MiB of nominal NV12 pixels.
    inc eax
    imul eax, esi
    imul rax, rdi
    lea rax, [rax+rax*2]
    shr rax, 1
    cmp rax, 134217728
    ja .Lwv_open_next_config
    mov [rbx+WV_CONFIG_INDEX], ebp
    jmp .Lwv_open_create
.Lwv_open_next_config:
    inc ebp
    jmp .Lwv_open_config
.Lwv_open_create:
    mov rcx, [rbx+WV_VIDEO_DEVICE]
    lea rdx, [rbx+WV_DESC]
    lea r8, [rbx+WV_CONFIG]
    lea r9, [rbx+WV_DECODER]
    mov rax, [rcx]
    call [rax+3*8]
    test eax, eax
    js .Lwv_open_fail
    mov [rbx+WV_TEX_DESC], esi
    mov [rbx+WV_TEX_DESC+4], edi
    mov dword ptr [rbx+WV_TEX_DESC+8], 1
    mov eax, [rbx+WV_POOL]
    mov [rbx+WV_TEX_DESC+12], eax
    mov dword ptr [rbx+WV_TEX_DESC+16], 103
    mov dword ptr [rbx+WV_TEX_DESC+20], 1
    mov dword ptr [rbx+WV_TEX_DESC+32], 0x200 # BIND_DECODER
    mov rcx, [rbx+WV_DEVICE]
    lea rdx, [rbx+WV_TEX_DESC]
    xor r8d, r8d
    lea r9, [rbx+WV_TEXTURE]
    mov rax, [rcx]
    call [rax+5*8]
    test eax, eax
    js .Lwv_open_fail
    movdqu xmm0, [rip+wv_h264_profile]
    movdqu [rbx+WV_VIEW_DESC], xmm0
    mov dword ptr [rbx+WV_VIEW_DESC+16], 1 # TEXTURE2D, slice0
    mov rcx, [rbx+WV_VIDEO_DEVICE]
    mov rdx, [rbx+WV_TEXTURE]
    lea r8, [rbx+WV_VIEW_DESC]
    lea r9, [rbx+WV_VIEW]
    mov rax, [rcx]
    call [rax+7*8]
    test eax, eax
    js .Lwv_open_fail
    mov dword ptr [rbx+WV_TEX_DESC+12], 1
    mov dword ptr [rbx+WV_TEX_DESC+28], 3 # USAGE_STAGING
    mov dword ptr [rbx+WV_TEX_DESC+32], 0
    mov dword ptr [rbx+WV_TEX_DESC+36], 0x20000 # CPU_ACCESS_READ
    mov rcx, [rbx+WV_DEVICE]
    lea rdx, [rbx+WV_TEX_DESC]
    xor r8d, r8d
    lea r9, [rbx+WV_STAGING]
    mov rax, [rcx]
    call [rax+5*8]
    test eax, eax
    js .Lwv_open_fail
    mov dword ptr [rbx+WV_READY], 1
    xor eax, eax
    mov [rbx+WV_HRESULT], eax
    jmp .Lwv_open_return
.Lwv_open_busy:
    mov eax, WV_UNEXPECTED
    jmp .Lwv_open_return
.Lwv_open_invalid:
    mov eax, WV_INVALID
    jmp .Lwv_open_return
.Lwv_open_unsupported:
    mov eax, WV_UNSUPPORTED
.Lwv_open_fail:
    mov ebp, eax
    mov rcx, rbx
    call win_video_close
    mov [rbx+WV_HRESULT], ebp
    mov eax, ebp
.Lwv_open_return:
    add rsp, 88
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_video_open

# RCX=context; idempotent, single owner, no call in progress.
FN win_video_close
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    xor esi, esi
.Lwv_close_next:
    lea rax, [rip+wv_release_order]
    movzx edi, byte ptr [rax+rsi]
    mov rcx, [rbx+rdi]
    test rcx, rcx
    jz .Lwv_close_skip
    mov qword ptr [rbx+rdi], 0
    mov rax, [rcx]
    call [rax+16]
.Lwv_close_skip:
    inc esi
    cmp esi, 8
    jb .Lwv_close_next
    mov rdi, rbx
    xor eax, eax
    mov ecx, WV_BYTES/8
    rep stosq
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN win_video_close

# RCX=context, RDX=frame descriptor (48B): picture pointer, matrix pointer,
# bitstream pointer, padded bytes:u32,reserved:u32,slices pointer,count:u32,
# reserved:u32. Caller supplies valid storage; all slices are DXVA short10B.
# First backend profile: single IDR picture, NV12 8-bit420 progressive,
# no reference surfaces. Actual H.264 parsing belongs to the assembly frontend.
FN win_video_decode
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rbx, rcx
    mov r12, rdx
    cmp dword ptr [rbx+WV_READY], 1
    jne .Lwv_decode_unexpected
    cmp dword ptr [rbx+WV_COPY_PENDING], 0
    jne .Lwv_decode_pending
    mov rsi, [r12]
    test rsi, rsi
    jz .Lwv_decode_invalid
    cmp qword ptr [r12+8], 0
    je .Lwv_decode_invalid
    mov rdi, [r12+16]
    test rdi, rdi
    jz .Lwv_decode_invalid
    mov eax, [r12+24]
    test eax, eax
    jz .Lwv_decode_invalid
    cmp eax, 16777216
    ja .Lwv_decode_invalid
    test eax, 127
    jnz .Lwv_decode_invalid
    cmp dword ptr [r12+28], 0
    jne .Lwv_decode_invalid
    cmp dword ptr [r12+44], 0
    jne .Lwv_decode_invalid
    mov ecx, [r12+40]
    test ecx, ecx
    jz .Lwv_decode_invalid
    cmp ecx, 256
    ja .Lwv_decode_invalid
    mov rdx, [r12+32]
    test rdx, rdx
    jz .Lwv_decode_invalid
    xor r8d, r8d
.Lwv_decode_slice:
    cmp [rdx], r8d          # contiguous slices, first offset0
    jne .Lwv_decode_invalid
    mov r9d, [rdx+4]
    cmp r9d, 4
    jbe .Lwv_decode_invalid
    add r9d, r8d
    jc .Lwv_decode_invalid
    cmp r9d, eax
    ja .Lwv_decode_invalid
    cmp word ptr [rdx+8], 0
    jne .Lwv_decode_invalid
    cmp word ptr [rdi+r8], 0
    jne .Lwv_decode_invalid
    cmp byte ptr [rdi+r8+2], 1
    jne .Lwv_decode_invalid
    movzx r10d, byte ptr [rdi+r8+3]
    and r10d, 0x9f
    cmp r10d, 5
    jne .Lwv_decode_invalid
    test byte ptr [rdi+r8+3], 0x60
    jz .Lwv_decode_invalid
    mov r8d, r9d
    add rdx, 10
    dec ecx
    jnz .Lwv_decode_slice
    cmp r8d, eax
    jne .Lwv_decode_invalid
    movzx eax, word ptr [rsi]
    inc eax
    shl eax, 4
    cmp eax, [rbx+WV_WIDTH]
    jne .Lwv_decode_invalid
    movzx eax, word ptr [rsi+2]
    inc eax
    shl eax, 4
    cmp eax, [rbx+WV_HEIGHT]
    jne .Lwv_decode_invalid
    cmp byte ptr [rsi+4], 0  # CurrPic index0, not bottom field
    jne .Lwv_decode_invalid
    cmp byte ptr [rsi+8], 0
    jne .Lwv_decode_invalid
    cmp byte ptr [rsi+9], 0
    jne .Lwv_decode_invalid
    movzx eax, word ptr [rsi+6]
    and eax, 0xb83f         # progressive,420,intra,consecutive;8x8 transform off
    cmp eax, 0x9810
    jne .Lwv_decode_invalid
    cmp byte ptr [rsi+171], 1 # remaining syntax fields must be present
    jne .Lwv_decode_invalid
    xor ecx, ecx
.Lwv_decode_no_refs:
    cmp byte ptr [rsi+rcx+16], 255
    jne .Lwv_decode_invalid
    inc ecx
    cmp ecx, 16
    jb .Lwv_decode_no_refs
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov r8, [rbx+WV_VIEW]
    xor r9d, r9d
    mov qword ptr [rsp+32], 0
    mov rax, [rcx]
    call [rax+9*8]
    cmp eax, WV_PENDING
    je .Lwv_decode_pending
    cmp eax, 0x8876021c      # D3DERR_WASSTILLDRAWING
    je .Lwv_decode_pending
    cmp eax, 0x887a000a
    je .Lwv_decode_pending
    test eax, eax
    js .Lwv_decode_gpu_error
    mov dword ptr [rbx+WV_HAVE_FRAME], 0
    # Each successfully acquired driver buffer is released even when too small.
    xor ebp, ebp
.Lwv_decode_buffer:
    cmp ebp, 0
    jne .Lwv_decode_matrix
    xor edi, edi
    mov rsi, [r12]
    mov r9d, 1040
    jmp .Lwv_decode_copy
.Lwv_decode_matrix:
    cmp ebp, 1
    jne .Lwv_decode_bitstream
    mov edi, 4
    mov rsi, [r12+8]
    mov r9d, 224
    jmp .Lwv_decode_copy
.Lwv_decode_bitstream:
    cmp ebp, 2
    jne .Lwv_decode_slices
    mov edi, 6
    mov rsi, [r12+16]
    mov r9d, [r12+24]
    jmp .Lwv_decode_copy
.Lwv_decode_slices:
    mov edi, 5
    mov rsi, [r12+32]
    imul r9d, [r12+40], 10
.Lwv_decode_copy:
    mov eax, ebp
    imul eax, eax, 72
    mov [rbx+rax+WV_BUFFERS], edi
    mov [rbx+rax+WV_BUFFERS+12], r9d
    cmp edi, 5
    jb .Lwv_decode_mb_count_done
    mov ecx, [rbx+WV_WIDTH]
    imul ecx, [rbx+WV_HEIGHT]
    shr ecx, 8
    mov [rbx+rax+WV_BUFFERS+20], ecx
.Lwv_decode_mb_count_done:
    mov [rsp+40], r9d
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov r8d, edi
    lea r9, [rbx+WV_BUFFER_SIZE]
    lea rax, [rbx+WV_BUFFER_PTR]
    mov [rsp+32], rax
    mov rax, [rcx]
    call [rax+7*8]
    test eax, eax
    js .Lwv_decode_end_error
    mov eax, [rsp+40]
    cmp [rbx+WV_BUFFER_SIZE], eax
    jb .Lwv_decode_short
    cmp qword ptr [rbx+WV_BUFFER_PTR], 0
    je .Lwv_decode_short
    mov r10d, edi
    mov rdi, [rbx+WV_BUFFER_PTR]
    mov ecx, eax
    rep movsb
    mov edi, r10d
    xor eax, eax
    jmp .Lwv_decode_release
.Lwv_decode_short:
    mov eax, WV_INVALID
.Lwv_decode_release:
    mov [rsp+40], eax
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov r8d, edi
    mov rax, [rcx]
    call [rax+8*8]
    cmp dword ptr [rsp+40], 0
    jne .Lwv_decode_copy_error
    test eax, eax
    js .Lwv_decode_end_error
    inc ebp
    cmp ebp, 4
    jb .Lwv_decode_buffer
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov r8d, 4
    lea r9, [rbx+WV_BUFFERS]
    mov rax, [rcx]
    call [rax+11*8]
    test eax, eax
    js .Lwv_decode_end_error
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov rax, [rcx]
    call [rax+10*8]
    test eax, eax
    js .Lwv_decode_gpu_error
    mov dword ptr [rbx+WV_HAVE_FRAME], 1
    xor eax, eax
    jmp .Lwv_decode_return
.Lwv_decode_copy_error:
    mov eax, [rsp+40]
.Lwv_decode_end_error:
    mov ebp, eax
    mov rcx, [rbx+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+WV_DECODER]
    mov rax, [rcx]
    call [rax+10*8]
    mov eax, ebp
.Lwv_decode_gpu_error:
    mov dword ptr [rbx+WV_READY], 0 # close/reopen after any driver failure
    jmp .Lwv_decode_return
.Lwv_decode_invalid:
    mov eax, WV_INVALID
    jmp .Lwv_decode_return
.Lwv_decode_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lwv_decode_return
.Lwv_decode_pending:
    mov eax, WV_PENDING
.Lwv_decode_return:
    mov [rbx+WV_HRESULT], eax
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_video_decode

# RCX=context, RDX=packed NV12 destination, R8=capacity in bytes.
# Nonblocking Map: E_PENDING means retry on a later bounded/cancellable wake.
# No output writes until mapping and pitch validation succeed.
FN win_video_readback
    push rbx
    push rbp
    push rsi
    push rdi
    sub rsp, 72
    mov rbx, rcx
    mov rdi, rdx
    cmp dword ptr [rbx+WV_READY], 1
    jne .Lwv_read_unexpected
    cmp dword ptr [rbx+WV_HAVE_FRAME], 1
    jne .Lwv_read_unexpected
    test rdi, rdi
    jz .Lwv_read_invalid
    mov eax, [rbx+WV_WIDTH]
    imul eax, [rbx+WV_HEIGHT]
    lea eax, [rax+rax*2]
    shr eax, 1
    cmp r8, rax
    jb .Lwv_read_invalid
    cmp dword ptr [rbx+WV_COPY_PENDING], 0
    jne .Lwv_read_map
    mov rcx, [rbx+WV_CONTEXT]
    mov rdx, [rbx+WV_STAGING]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+32], 0
    mov qword ptr [rsp+40], 0
    mov rax, [rbx+WV_TEXTURE]
    mov [rsp+48], rax
    mov qword ptr [rsp+56], 0
    mov qword ptr [rsp+64], 0
    mov rax, [rcx]
    call [rax+46*8]
    mov dword ptr [rbx+WV_COPY_PENDING], 1
    mov rcx, [rbx+WV_CONTEXT]
    mov rax, [rcx]
    call [rax+111*8]         # submit copy once; never busy-wait on a driver map
.Lwv_read_map:
    mov rcx, [rbx+WV_CONTEXT]
    mov rdx, [rbx+WV_STAGING]
    xor r8d, r8d
    mov r9d, 1               # MAP_READ
    mov qword ptr [rsp+32], 0x100000 # DO_NOT_WAIT
    lea rax, [rbx+WV_MAP]
    mov [rsp+40], rax
    mov rax, [rcx]
    call [rax+14*8]
    cmp eax, 0x887a000a      # DXGI_ERROR_WAS_STILL_DRAWING
    je .Lwv_read_pending
    test eax, eax
    js .Lwv_read_gpu_error
    mov rsi, [rbx+WV_MAP]
    mov ebp, [rbx+WV_MAP+8]
    test rsi, rsi
    jz .Lwv_read_bad_pitch
    cmp ebp, [rbx+WV_WIDTH]
    jb .Lwv_read_bad_pitch
    cmp ebp, 65536
    ja .Lwv_read_bad_pitch
    mov eax, [rbx+WV_HEIGHT]
    lea eax, [rax+rax*2]
    shr eax, 1
    mov [rsp+48], eax
.Lwv_read_row:
    mov rdx, rsi
    mov ecx, [rbx+WV_WIDTH]
    rep movsb
    mov rsi, rdx
    add rsi, rbp
    dec dword ptr [rsp+48]
    jnz .Lwv_read_row
    xor ebp, ebp
    jmp .Lwv_read_unmap
.Lwv_read_bad_pitch:
    mov ebp, WV_INVALID
.Lwv_read_unmap:
    mov rcx, [rbx+WV_CONTEXT]
    mov rdx, [rbx+WV_STAGING]
    xor r8d, r8d
    mov rax, [rcx]
    call [rax+15*8]
    mov dword ptr [rbx+WV_COPY_PENDING], 0
    mov eax, ebp
    test eax, eax
    js .Lwv_read_gpu_error
    jmp .Lwv_read_return
.Lwv_read_gpu_error:
    mov dword ptr [rbx+WV_READY], 0
    jmp .Lwv_read_return
.Lwv_read_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lwv_read_return
.Lwv_read_invalid:
    mov eax, WV_INVALID
    jmp .Lwv_read_return
.Lwv_read_pending:
    mov eax, WV_PENDING
.Lwv_read_return:
    mov [rbx+WV_HRESULT], eax
    add rsp, 72
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_video_readback
