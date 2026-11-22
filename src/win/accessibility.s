# Original native-control MSAA naming. MIT, see LICENSE.
# Window text alone does not name a native Windows trackbar's accessible object.
.include "lamp.inc"
RODATA
.p2align 4
acc_class: .long 0xb5f8350b
    .short 0x0548, 0x48b1
    .byte 0xa6,0xee,0x88,0xbd,0x00,0xb4,0xa5,0xe7
acc_interface: .long 0x6e26e776
    .short 0x04f0,0x495d
    .byte 0x80,0xe4,0x33,0x30,0x35,0x2e,0x31,0x69
acc_name: .long 0x608d3df8
    .short 0x8128,0x4aa7
    .byte 0xa4,0x28,0xf5,0x5e,0x49,0x26,0x72,0x91
.text
# RCX=control HWND, RDX=UTF-16 name (NULL clears annotation). EAX=HRESULT.
# Balance our own COM initialization; retain an existing different apartment.
FN control_access_name
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov rsi, rcx
    mov rdi, rdx
    xor ebx, ebx
    test rsi, rsi
    jz .Lacc_failed
    xor ecx, ecx
    mov edx, 2                         # COINIT_APARTMENTTHREADED
    call CoInitializeEx
    test eax, eax
    jns .Lacc_initialized
    cmp eax, 0x80010106                 # RPC_E_CHANGED_MODE: already initialized
    jne .Lacc_return
    jmp .Lacc_create
.Lacc_initialized:
    mov ebx, 1
.Lacc_create:
    lea rcx, [rip + acc_class]
    xor edx, edx
    mov r8d, 1                         # CLSCTX_INPROC_SERVER
    lea r9, [rip + acc_interface]
    lea rax, [rsp + 48]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 48], 0
    call CoCreateInstance
    test eax, eax
    js .Lacc_finish_failed
    mov rcx, [rsp + 48]
    mov rdx, rsi
    mov r8d, -4                        # OBJID_CLIENT
    xor r9d, r9d                       # CHILDID_SELF
    lea rax, [rip + acc_name]
    mov [rsp + 32], rax                # GUID passed indirectly on Windows x64
    mov [rsp + 40], rdi
    mov rax, [rcx]
    test rdi, rdi
    jz .Lacc_clear
    call qword ptr [rax + 56]          # IAccPropServices::SetHwndPropStr
    jmp .Lacc_result
.Lacc_clear:
    mov qword ptr [rsp + 40], 1
    call qword ptr [rax + 72]          # IAccPropServices::ClearHwndProps
.Lacc_result:
    mov edi, eax
    mov rcx, [rsp + 48]
    mov rax, [rcx]
    call qword ptr [rax + 16]          # Release
    jmp .Lacc_finish
.Lacc_finish_failed:
    mov edi, eax
.Lacc_finish:
    test ebx, ebx
    jz .Lacc_return_result
    call CoUninitialize
.Lacc_return_result:
    mov eax, edi
    jmp .Lacc_return
.Lacc_failed:
    mov eax, 0x80070057                # E_INVALIDARG
.Lacc_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN control_access_name
