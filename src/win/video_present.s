# Original GPU NV12->BGRA presentation, crop/aspect and SDR range/matrix. MIT.
# No CPU image conversion on the presentation path. Context is single-owner.
.include "lamp.inc"
.include "h264.inc"
.include "video.inc"
.include "video_present.inc"
RODATA
.p2align 4
vp_dxgi_iid: .long 0x54ec77fa; .short 0x1377,0x44e6; .byte 0x8c,0x32,0x88,0xfd,0x5f,0x44,0xc8,0x4c
vp_factory_iid: .long 0x50c83a1c; .short 0xe072,0x4c48; .byte 0x87,0xb0,0x36,0x30,0xfa,0x36,0xa6,0xd0
vp_texture_iid: .long 0x6f15aaf2; .short 0xd208,0x4e89; .byte 0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c
vp_release_order: .byte VP_STAGE,VP_OUTPUT,VP_RGB,VP_BACK,VP_INPUT,VP_PROCESSOR,VP_ENUM,VP_QUERY,VP_SWAP,VP_FACTORY,VP_ADAPTER,VP_DXGI
.text

# RCX=zeroed presenter, RDX=live GPU context, R8=H264 metadata context,
# R9=target {HWND:u64,width:u32,height:u32}. HRESULT. GPU must outlive presenter.
FN win_present_open
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    xor eax, eax
.Lvp_open_owned:
    cmp qword ptr [rbx+rax*8], 0
    jne .Lvp_open_busy
    inc eax
    cmp eax, 12
    jb .Lvp_open_owned
    cmp dword ptr [rsi+WV_READY], 1
    jne .Lvp_open_invalid
    mov [rbx+VP_GPU], rsi
    cmp qword ptr [r12], 0
    je .Lvp_open_invalid_cleanup
    mov rax, [r12]
    mov [rbx+VP_HWND], rax
    mov eax, [r12+8]
    test eax, eax
    jz .Lvp_open_invalid_cleanup
    cmp eax, 4096
    ja .Lvp_open_invalid_cleanup
    mov [rbx+VP_WIDTH], eax
    mov eax, [r12+12]
    test eax, eax
    jz .Lvp_open_invalid_cleanup
    cmp eax, 4096
    ja .Lvp_open_invalid_cleanup
    mov [rbx+VP_HEIGHT], eax
    mov eax, [rdi+HP_WIDTH]
    cmp eax, [rsi+WV_WIDTH]
    jne .Lvp_open_invalid_cleanup
    mov [rbx+VP_CONTENT+12], eax
    mov eax, [rdi+HP_HEIGHT]
    cmp eax, [rsi+WV_HEIGHT]
    jne .Lvp_open_invalid_cleanup
    mov [rbx+VP_CONTENT+16], eax
    mov eax, [rdi+HP_LEFT]
    mov [rbx+VP_SOURCE], eax
    add eax, [rdi+HP_VISIBLE_W]
    jc .Lvp_open_invalid_cleanup
    cmp eax, [rsi+WV_WIDTH]
    ja .Lvp_open_invalid_cleanup
    cmp eax, [rbx+VP_SOURCE]
    jbe .Lvp_open_invalid_cleanup
    mov [rbx+VP_SOURCE+8], eax
    mov edx, eax
    mov eax, [rdi+HP_TOP]
    mov [rbx+VP_SOURCE+4], eax
    add eax, [rdi+HP_VISIBLE_H]
    jc .Lvp_open_invalid_cleanup
    cmp eax, [rsi+WV_HEIGHT]
    ja .Lvp_open_invalid_cleanup
    cmp eax, [rbx+VP_SOURCE+4]
    jbe .Lvp_open_invalid_cleanup
    mov [rbx+VP_SOURCE+12], eax
    or edx, eax
    or edx, [rbx+VP_SOURCE]
    or edx, [rbx+VP_SOURCE+4]
    test edx, 1
    jnz .Lvp_open_invalid_cleanup
    mov eax, [rdi+HP_SAR_W]
    mov edx, [rdi+HP_SAR_H]
    test eax, eax
    jnz .Lvp_open_sar
    test edx, edx
    jnz .Lvp_open_invalid_cleanup
    mov eax, 1
    mov edx, 1
.Lvp_open_sar:
    test edx, edx
    jz .Lvp_open_invalid_cleanup
    cmp eax, 65535
    ja .Lvp_open_invalid_cleanup
    cmp edx, 65535
    ja .Lvp_open_invalid_cleanup
    mov [rbx+VP_SAR_W], eax
    mov [rbx+VP_SAR_H], edx
    # Initial display path is SDR only; no silent HDR/gamut conversion.
    mov eax, [rdi+HP_PRIMARIES]
    cmp eax, 1
    je .Lvp_open_transfer
    cmp eax, 2
    je .Lvp_open_transfer
    cmp eax, 5
    je .Lvp_open_transfer
    cmp eax, 6
    jne .Lvp_open_unsupported
.Lvp_open_transfer:
    mov eax, [rdi+HP_TRANSFER]
    cmp eax, 1
    je .Lvp_open_matrix
    cmp eax, 2
    je .Lvp_open_matrix
    cmp eax, 6
    je .Lvp_open_matrix
    cmp eax, 13
    jne .Lvp_open_unsupported
.Lvp_open_matrix:
    xor ebp, ebp
    mov eax, [rdi+HP_COLOR_MATRIX]
    cmp eax, 1
    je .Lvp_open_709
    cmp eax, 5
    je .Lvp_open_range
    cmp eax, 6
    je .Lvp_open_range
    cmp eax, 2
    jne .Lvp_open_unsupported
    cmp dword ptr [rsi+WV_HEIGHT], 576
    ja .Lvp_open_709
    cmp dword ptr [rsi+WV_WIDTH], 1280
    jb .Lvp_open_range
.Lvp_open_709:
    or ebp, 4
.Lvp_open_range:
    cmp dword ptr [rdi+HP_FULL_RANGE], 0
    je .Lvp_open_limited
    or ebp, 32              # NOMINAL_RANGE_0_255=2
    jmp .Lvp_open_color
.Lvp_open_limited:
    or ebp, 16              # NOMINAL_RANGE_16_235=1
.Lvp_open_color:
    mov [rbx+VP_COLOR], ebp
    mov eax, [rdi+HP_TIME_SCALE]
    mov edx, [rdi+HP_TIME_TICK]
    test eax, eax
    jz .Lvp_open_default_rate
    test edx, edx
    jz .Lvp_open_default_rate
    cmp edx, 0x7fffffff
    ja .Lvp_open_default_rate
    add edx, edx
    jmp .Lvp_open_rate
.Lvp_open_default_rate:
    mov eax, 30
    mov edx, 1
.Lvp_open_rate:
    mov [rbx+VP_CONTENT+4], eax
    mov [rbx+VP_CONTENT+8], edx
    mov [rbx+VP_CONTENT+20], eax
    mov [rbx+VP_CONTENT+24], edx
    mov dword ptr [rbx+VP_BACKGROUND+12], 0x3f800000
    mov rcx, [rsi+WV_DEVICE]
    lea rdx, [rip+vp_dxgi_iid]
    lea r8, [rbx+VP_DXGI]
    mov rax, [rcx]
    call [rax]
    test eax, eax
    js .Lvp_open_fail
    mov rcx, [rbx+VP_DXGI]
    lea rdx, [rbx+VP_ADAPTER]
    mov rax, [rcx]
    call [rax+7*8]
    test eax, eax
    js .Lvp_open_fail
    mov rcx, [rbx+VP_ADAPTER]
    lea rdx, [rip+vp_factory_iid]
    lea r8, [rbx+VP_FACTORY]
    mov rax, [rcx]
    call [rax+6*8]
    test eax, eax
    js .Lvp_open_fail
    mov eax, [rbx+VP_WIDTH]
    mov [rbx+VP_SWAP_DESC], eax
    mov eax, [rbx+VP_HEIGHT]
    mov [rbx+VP_SWAP_DESC+4], eax
    mov dword ptr [rbx+VP_SWAP_DESC+8], 87 # BGRA8_UNORM
    mov dword ptr [rbx+VP_SWAP_DESC+16], 1
    mov dword ptr [rbx+VP_SWAP_DESC+24], 32 # RENDER_TARGET_OUTPUT
    mov dword ptr [rbx+VP_SWAP_DESC+28], 2
    mov dword ptr [rbx+VP_SWAP_DESC+36], 4 # FLIP_DISCARD
    mov rcx, [rbx+VP_FACTORY]
    mov rdx, [rsi+WV_DEVICE]
    mov r8, [rbx+VP_HWND]
    lea r9, [rbx+VP_SWAP_DESC]
    mov qword ptr [rsp+32], 0
    mov qword ptr [rsp+40], 0
    lea rax, [rbx+VP_SWAP]
    mov [rsp+48], rax
    mov rax, [rcx]
    call [rax+15*8]
    test eax, eax
    js .Lvp_open_fail
    mov rcx, [rbx+VP_FACTORY]
    mov rdx, [rbx+VP_HWND]
    mov r8d, 2               # NO_ALT_ENTER: explicit window state only
    mov rax, [rcx]
    call [rax+8*8]
    test eax, eax
    js .Lvp_open_fail
    mov rcx, rbx
    call vp_resources
    test eax, eax
    js .Lvp_open_fail
    mov dword ptr [rbx+VP_READY], 1
    xor eax, eax
    jmp .Lvp_open_return
.Lvp_open_busy:
    mov eax, WV_UNEXPECTED
    jmp .Lvp_open_return
.Lvp_open_invalid:
    mov eax, WV_INVALID
    jmp .Lvp_open_return
.Lvp_open_invalid_cleanup:
    mov eax, WV_INVALID
    jmp .Lvp_open_fail
.Lvp_open_unsupported:
    mov eax, WV_UNSUPPORTED
.Lvp_open_fail:
    mov ebp, eax
    mov rcx, rbx
    call win_present_close
    mov [rbx+VP_HRESULT], ebp
    mov eax, ebp
.Lvp_open_return:
    add rsp, 64
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_present_open

# Allocate output-size-dependent resources. Existing device/swap chain retained.
LOCALFN vp_resources
    push rbx
    push rsi
    sub rsp, 56
    mov rbx, rcx
    mov rsi, [rbx+VP_GPU]
    mov eax, [rbx+VP_WIDTH]
    mov [rbx+VP_CONTENT+28], eax
    mov eax, [rbx+VP_HEIGHT]
    mov [rbx+VP_CONTENT+32], eax
    mov rcx, [rsi+WV_VIDEO_DEVICE]
    lea rdx, [rbx+VP_CONTENT]
    lea r8, [rbx+VP_ENUM]
    mov rax, [rcx]
    call [rax+10*8]
    test eax, eax
    js .Lvp_resources_return
    mov rcx, [rbx+VP_ENUM]
    mov edx, 103
    lea r8, [rbx+VP_SUPPORT]
    mov rax, [rcx]
    call [rax+8*8]
    test eax, eax
    js .Lvp_resources_return
    test dword ptr [rbx+VP_SUPPORT], 1
    jz .Lvp_resources_unsupported
    mov rcx, [rbx+VP_ENUM]
    mov edx, 87
    lea r8, [rbx+VP_SUPPORT]
    mov rax, [rcx]
    call [rax+8*8]
    test eax, eax
    js .Lvp_resources_return
    test dword ptr [rbx+VP_SUPPORT], 2
    jz .Lvp_resources_unsupported
    mov rcx, [rbx+VP_ENUM]
    lea rdx, [rbx+VP_CAPS]
    mov rax, [rcx]
    call [rax+9*8]
    test eax, eax
    js .Lvp_resources_return
    test dword ptr [rbx+VP_CAPS], 16 # NOMINAL_RANGE support
    jz .Lvp_resources_unsupported
    cmp dword ptr [rbx+VP_CAPS+28], 1
    jb .Lvp_resources_unsupported
    cmp dword ptr [rbx+VP_CAPS+32], 1
    jb .Lvp_resources_unsupported
    mov rcx, [rsi+WV_VIDEO_DEVICE]
    mov rdx, [rbx+VP_ENUM]
    xor r8d, r8d
    lea r9, [rbx+VP_PROCESSOR]
    mov rax, [rcx]
    call [rax+4*8]
    test eax, eax
    js .Lvp_resources_return
    mov dword ptr [rbx+VP_INPUT_DESC+4], 1
    mov rcx, [rsi+WV_VIDEO_DEVICE]
    mov rdx, [rsi+WV_TEXTURE]
    mov r8, [rbx+VP_ENUM]
    lea r9, [rbx+VP_INPUT_DESC]
    lea rax, [rbx+VP_INPUT]
    mov [rsp+32], rax
    mov rax, [rcx]
    call [rax+8*8]
    test eax, eax
    js .Lvp_resources_return
    mov rcx, [rbx+VP_SWAP]
    xor edx, edx
    lea r8, [rip+vp_texture_iid]
    lea r9, [rbx+VP_BACK]
    mov rax, [rcx]
    call [rax+9*8]
    test eax, eax
    js .Lvp_resources_return
    mov eax, [rbx+VP_WIDTH]
    mov [rbx+VP_TEX_DESC], eax
    mov eax, [rbx+VP_HEIGHT]
    mov [rbx+VP_TEX_DESC+4], eax
    mov dword ptr [rbx+VP_TEX_DESC+8], 1
    mov dword ptr [rbx+VP_TEX_DESC+12], 1
    mov dword ptr [rbx+VP_TEX_DESC+16], 87
    mov dword ptr [rbx+VP_TEX_DESC+20], 1
    mov dword ptr [rbx+VP_TEX_DESC+28], 0
    mov dword ptr [rbx+VP_TEX_DESC+32], 32 # BIND_RENDER_TARGET
    mov dword ptr [rbx+VP_TEX_DESC+36], 0
    mov rcx, [rsi+WV_DEVICE]
    lea rdx, [rbx+VP_TEX_DESC]
    xor r8d, r8d
    lea r9, [rbx+VP_RGB]
    mov rax, [rcx]
    call [rax+5*8]
    test eax, eax
    js .Lvp_resources_return
    mov dword ptr [rbx+VP_OUTPUT_DESC], 1
    mov rcx, [rsi+WV_VIDEO_DEVICE]
    mov rdx, [rbx+VP_RGB]
    mov r8, [rbx+VP_ENUM]
    lea r9, [rbx+VP_OUTPUT_DESC]
    lea rax, [rbx+VP_OUTPUT]
    mov [rsp+32], rax
    mov rax, [rcx]
    call [rax+9*8]
    test eax, eax
    js .Lvp_resources_return
    mov rcx, [rsi+WV_DEVICE]
    lea rdx, [rbx+VP_QUERY_DESC] # QUERY_EVENT=0
    lea r8, [rbx+VP_QUERY]
    mov rax, [rcx]
    call [rax+24*8]
    test eax, eax
    js .Lvp_resources_return
    mov rcx, rbx
    call vp_rect
    # Disable automatic enhancements; one progressive sample, no temporal refs.
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call [rax+37*8]
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call [rax+27*8]
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    lea r9, [rbx+VP_COLOR]
    mov rax, [rcx]
    call [rax+28*8]
    mov dword ptr [rbx+VP_SUPPORT], 0 # full-range RGB output
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    lea r8, [rbx+VP_SUPPORT]
    mov rax, [rcx]
    call [rax+15*8]
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [rcx]
    call [rax+16*8]          # opaque alpha
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    lea r9, [rbx+VP_BACKGROUND]
    mov rax, [rcx]
    call [rax+14*8]
    mov dword ptr [rbx+VP_TARGET], 0
    mov dword ptr [rbx+VP_TARGET+4], 0
    mov eax, [rbx+VP_WIDTH]
    mov [rbx+VP_TARGET+8], eax
    mov eax, [rbx+VP_HEIGHT]
    mov [rbx+VP_TARGET+12], eax
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    mov r8d, 1
    lea r9, [rbx+VP_TARGET]
    mov rax, [rcx]
    call [rax+13*8]
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    mov r9d, 1
    lea rax, [rbx+VP_SOURCE]
    mov [rsp+32], rax
    mov rax, [rcx]
    call [rax+30*8]
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    xor r8d, r8d
    mov r9d, 1
    lea rax, [rbx+VP_DEST]
    mov [rsp+32], rax
    mov rax, [rcx]
    call [rax+31*8]
    mov dword ptr [rbx+VP_STREAM], 1
    mov rax, [rbx+VP_INPUT]
    mov [rbx+VP_STREAM+32], rax
    xor eax, eax
    jmp .Lvp_resources_return
.Lvp_resources_unsupported:
    mov eax, WV_UNSUPPORTED
.Lvp_resources_return:
    add rsp, 56
    pop rsi
    pop rbx
    ret
ENDFN vp_resources

# Integer aspect fit, including non-square samples; no overflowing products.
LOCALFN vp_rect
    mov r8d, [rcx+VP_SOURCE+8]
    sub r8d, [rcx+VP_SOURCE]
    mov eax, [rcx+VP_SAR_W]
    imul r8, rax
    mov r9d, [rcx+VP_SOURCE+12]
    sub r9d, [rcx+VP_SOURCE+4]
    mov eax, [rcx+VP_SAR_H]
    imul r9, rax
    mov r10d, [rcx+VP_WIDTH]
    imul r10, r9
    mov r11d, [rcx+VP_HEIGHT]
    imul r11, r8
    cmp r10, r11
    ja .Lvp_rect_height
    mov rax, r10
    xor edx, edx
    div r8
    test eax, eax
    jnz .Lvp_rect_width_nonzero
    inc eax
.Lvp_rect_width_nonzero:
    mov r9d, eax
    mov r8d, [rcx+VP_WIDTH]
    jmp .Lvp_rect_store
.Lvp_rect_height:
    mov rax, r11
    xor edx, edx
    div r9
    test eax, eax
    jnz .Lvp_rect_height_nonzero
    inc eax
.Lvp_rect_height_nonzero:
    mov r8d, eax
    mov r9d, [rcx+VP_HEIGHT]
.Lvp_rect_store:
    mov eax, [rcx+VP_WIDTH]
    sub eax, r8d
    shr eax, 1
    mov [rcx+VP_DEST], eax
    add eax, r8d
    mov [rcx+VP_DEST+8], eax
    mov eax, [rcx+VP_HEIGHT]
    sub eax, r9d
    shr eax, 1
    mov [rcx+VP_DEST+4], eax
    add eax, r9d
    mov [rcx+VP_DEST+12], eax
    ret
ENDFN vp_rect

# RCX=context ->S_OK/S_FALSE(occluded)/E_PENDING/error. One GPU blit/copy per
# completed call, no CPU pixel traffic. Event query protects source-surface reuse.
FN win_present_frame
    push rbx
    push rsi
    sub rsp, 56
    mov rbx, rcx
    cmp dword ptr [rbx+VP_READY], 1
    jne .Lvp_frame_unexpected
    cmp dword ptr [rbx+VP_CAPTURE_PENDING], 0
    jne .Lvp_frame_pending
    mov rsi, [rbx+VP_GPU]
    cmp dword ptr [rsi+WV_READY], 1
    jne .Lvp_frame_unexpected
    cmp dword ptr [rsi+WV_HAVE_FRAME], 1
    jne .Lvp_frame_unexpected
    cmp dword ptr [rbx+VP_DRAW_PENDING], 0
    jne .Lvp_frame_query
    mov rcx, [rsi+WV_VIDEO_CONTEXT]
    mov rdx, [rbx+VP_PROCESSOR]
    mov r8, [rbx+VP_OUTPUT]
    xor r9d, r9d
    mov qword ptr [rsp+32], 1
    lea rax, [rbx+VP_STREAM]
    mov [rsp+40], rax
    mov rax, [rcx]
    call [rax+53*8]
    test eax, eax
    js .Lvp_frame_gpu_error
    mov rcx, [rsi+WV_CONTEXT]
    mov rdx, [rbx+VP_BACK]
    mov r8, [rbx+VP_RGB]
    mov rax, [rcx]
    call [rax+47*8]
    mov rcx, [rsi+WV_CONTEXT]
    mov rdx, [rbx+VP_QUERY]
    mov rax, [rcx]
    call [rax+28*8]
    mov rcx, [rsi+WV_CONTEXT]
    mov rax, [rcx]
    call [rax+111*8]
    mov dword ptr [rbx+VP_DRAW_PENDING], 1
    mov dword ptr [rbx+VP_PRESENT_DONE], 0
.Lvp_frame_query:
    mov rcx, [rsi+WV_CONTEXT]
    mov rdx, [rbx+VP_QUERY]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+32], 1 # ASYNC_GETDATA_DONOTFLUSH
    mov rax, [rcx]
    call [rax+29*8]
    cmp eax, 1
    je .Lvp_frame_pending
    test eax, eax
    js .Lvp_frame_gpu_error
    mov rcx, [rbx+VP_SWAP]
    xor edx, edx
    mov r8d, 8              # PRESENT_DO_NOT_WAIT
    mov rax, [rcx]
    call [rax+8*8]
    cmp eax, 0x887a000a
    je .Lvp_frame_pending
    test eax, eax
    js .Lvp_frame_gpu_error
    mov dword ptr [rbx+VP_DRAW_PENDING], 0
    mov dword ptr [rbx+VP_OCCLUDED], 0
    inc qword ptr [rbx+VP_PRESENTED]
    cmp eax, 0x087a0001
    jne .Lvp_frame_ok
    mov dword ptr [rbx+VP_OCCLUDED], 1
    mov eax, 1
    jmp .Lvp_frame_return
.Lvp_frame_ok:
    xor eax, eax
    jmp .Lvp_frame_return
.Lvp_frame_gpu_error:
    mov dword ptr [rbx+VP_READY], 0
    jmp .Lvp_frame_return
.Lvp_frame_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lvp_frame_return
.Lvp_frame_pending:
    mov eax, WV_PENDING
.Lvp_frame_return:
    mov [rbx+VP_HRESULT], eax
    add rsp, 56
    pop rsi
    pop rbx
    ret
ENDFN win_present_frame

# Test visibility without scheduling another decoded image.
FN win_present_visible
    cmp dword ptr [rcx+VP_READY], 1
    jne .Lvp_visible_bad
    mov rcx, [rcx+VP_SWAP]
    xor edx, edx
    mov r8d, 1
    mov rax, [rcx]
    sub rsp, 40
    call [rax+8*8]
    add rsp, 40
    ret
.Lvp_visible_bad:
    mov eax, WV_UNEXPECTED
    ret
ENDFN win_present_visible

# Release first EDX handles from scoped/full reverse ownership order.
LOCALFN vp_release
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12d, edx
    xor esi, esi
.Lvp_release_next:
    lea rax, [rip+vp_release_order]
    movzx edi, byte ptr [rax+rsi]
    mov rcx, [rbx+rdi]
    mov qword ptr [rbx+rdi], 0
    test rcx, rcx
    jz .Lvp_release_skip
    mov rax, [rcx]
    call [rax+16]
.Lvp_release_skip:
    inc esi
    cmp esi, r12d
    jb .Lvp_release_next
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN vp_release

FN win_present_close
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov rcx, [rbx+VP_GPU]
    test rcx, rcx
    jz .Lvp_close_release
    mov rcx, [rcx+WV_CONTEXT]
    test rcx, rcx
    jz .Lvp_close_release
    mov rax, [rcx]
    call [rax+111*8]
.Lvp_close_release:
    mov rcx, rbx
    mov edx, 12
    call vp_release
    mov rdi, rbx
    xor eax, eax
    mov ecx, VP_BYTES/8
    rep stosq
    add rsp, 40
    pop rdi
    pop rbx
    ret
ENDFN win_present_close

# Resize only after outstanding draw/capture completes; zero sizes are not used.
FN win_present_resize
    push rbx
    push rbp
    sub rsp, 56
    mov rbx, rcx
    cmp dword ptr [rbx+VP_READY], 1
    jne .Lvp_resize_unexpected
    cmp dword ptr [rbx+VP_DRAW_PENDING], 0
    jne .Lvp_resize_pending
    cmp dword ptr [rbx+VP_CAPTURE_PENDING], 0
    jne .Lvp_resize_pending
    test edx, edx
    jz .Lvp_resize_invalid
    test r8d, r8d
    jz .Lvp_resize_invalid
    cmp edx, 4096
    ja .Lvp_resize_invalid
    cmp r8d, 4096
    ja .Lvp_resize_invalid
    mov [rbx+VP_WIDTH], edx
    mov [rbx+VP_HEIGHT], r8d
    mov edx, 8
    call vp_release
    mov rcx, [rbx+VP_SWAP]
    mov edx, 2
    mov r8d, [rbx+VP_WIDTH]
    mov r9d, [rbx+VP_HEIGHT]
    mov qword ptr [rsp+32], 87
    mov qword ptr [rsp+40], 0
    mov rax, [rcx]
    call [rax+13*8]
    test eax, eax
    js .Lvp_resize_error
    mov rcx, rbx
    call vp_resources
    test eax, eax
    js .Lvp_resize_error
    xor eax, eax
    jmp .Lvp_resize_return
.Lvp_resize_error:
    mov dword ptr [rbx+VP_READY], 0
    jmp .Lvp_resize_return
.Lvp_resize_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lvp_resize_return
.Lvp_resize_pending:
    mov eax, WV_PENDING
    jmp .Lvp_resize_return
.Lvp_resize_invalid:
    mov eax, WV_INVALID
.Lvp_resize_return:
    mov [rbx+VP_HRESULT], eax
    add rsp, 56
    pop rbp
    pop rbx
    ret
ENDFN win_present_resize

# Optional packed BGRA readback for reference checks/future screenshots.
# No capture resource is allocated by normal presentation.
FN win_present_capture
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rbx, rcx
    mov rdi, rdx
    mov r12, [rbx+VP_GPU]
    cmp dword ptr [rbx+VP_READY], 1
    jne .Lvp_capture_unexpected
    cmp dword ptr [rbx+VP_DRAW_PENDING], 0
    jne .Lvp_capture_pending
    test rdi, rdi
    jz .Lvp_capture_invalid
    mov eax, [rbx+VP_WIDTH]
    imul eax, [rbx+VP_HEIGHT]
    shl eax, 2
    cmp r8, rax
    jb .Lvp_capture_invalid
    cmp qword ptr [rbx+VP_STAGE], 0
    jne .Lvp_capture_copy
    mov dword ptr [rbx+VP_TEX_DESC+28], 3
    mov dword ptr [rbx+VP_TEX_DESC+32], 0
    mov dword ptr [rbx+VP_TEX_DESC+36], 0x20000
    mov rcx, [r12+WV_DEVICE]
    lea rdx, [rbx+VP_TEX_DESC]
    xor r8d, r8d
    lea r9, [rbx+VP_STAGE]
    mov rax, [rcx]
    call [rax+5*8]
    test eax, eax
    js .Lvp_capture_error
.Lvp_capture_copy:
    cmp dword ptr [rbx+VP_CAPTURE_PENDING], 0
    jne .Lvp_capture_map
    mov rcx, [r12+WV_CONTEXT]
    mov rdx, [rbx+VP_STAGE]
    mov r8, [rbx+VP_RGB]
    mov rax, [rcx]
    call [rax+47*8]
    mov rcx, [r12+WV_CONTEXT]
    mov rax, [rcx]
    call [rax+111*8]
    mov dword ptr [rbx+VP_CAPTURE_PENDING], 1
.Lvp_capture_map:
    mov rcx, [r12+WV_CONTEXT]
    mov rdx, [rbx+VP_STAGE]
    xor r8d, r8d
    mov r9d, 1
    mov qword ptr [rsp+32], 0x100000
    lea rax, [rbx+VP_MAP]
    mov [rsp+40], rax
    mov rax, [rcx]
    call [rax+14*8]
    cmp eax, 0x887a000a
    je .Lvp_capture_pending
    test eax, eax
    js .Lvp_capture_error
    mov rsi, [rbx+VP_MAP]
    mov ebp, [rbx+VP_MAP+8]
    test rsi, rsi
    jz .Lvp_capture_bad_pitch
    mov eax, [rbx+VP_WIDTH]
    shl eax, 2
    cmp ebp, eax
    jb .Lvp_capture_bad_pitch
    cmp ebp, 65536
    ja .Lvp_capture_bad_pitch
    mov eax, [rbx+VP_HEIGHT]
    mov [rsp+32], eax
.Lvp_capture_row:
    mov rdx, rsi
    mov ecx, [rbx+VP_WIDTH]
    shl ecx, 2
    rep movsb
    lea rsi, [rdx+rbp]
    dec dword ptr [rsp+32]
    jnz .Lvp_capture_row
    xor ebp, ebp
    jmp .Lvp_capture_unmap
.Lvp_capture_bad_pitch:
    mov ebp, WV_INVALID
.Lvp_capture_unmap:
    mov rcx, [r12+WV_CONTEXT]
    mov rdx, [rbx+VP_STAGE]
    xor r8d, r8d
    mov rax, [rcx]
    call [rax+15*8]
    mov dword ptr [rbx+VP_CAPTURE_PENDING], 0
    mov eax, ebp
    test eax, eax
    js .Lvp_capture_error
    jmp .Lvp_capture_return
.Lvp_capture_error:
    mov dword ptr [rbx+VP_READY], 0
    jmp .Lvp_capture_return
.Lvp_capture_unexpected:
    mov eax, WV_UNEXPECTED
    jmp .Lvp_capture_return
.Lvp_capture_invalid:
    mov eax, WV_INVALID
    jmp .Lvp_capture_return
.Lvp_capture_pending:
    mov eax, WV_PENDING
.Lvp_capture_return:
    mov [rbx+VP_HRESULT], eax
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDFN win_present_capture
