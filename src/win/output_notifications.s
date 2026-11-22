# Original IMMNotificationClient for default render/console changes. MIT.
# Callback memory is process-static. Callbacks never wait, allocate or call COM.
# The owner detaches the event, unregisters, then drains in-flight signalers
# before it may close the event. Only the playback owner starts/stops watching.
.include "lamp.inc"
RODATA
.p2align 3
notify_iid: .long 0x7991eec9
    .short 0x7e89,0x4d85
    .byte 0x83,0x90,0x6c,0x70,0x3c,0xec,0x60,0xc0
notify_unknown: .quad 0,0x46000000000000c0
notify_vtable: .quad notify_query,notify_addref,notify_release
    .quad notify_ignore,notify_ignore,notify_ignore,notify_default,notify_ignore
.data
.p2align 3
.globl output_notification_client
output_notification_client: .quad notify_vtable
notify_refs: .long 1
notify_readers: .long 0
notify_pending: .long 0
notify_registered: .long 0
notify_event: .quad 0
notify_enum: .quad 0
.text
LOCALFN notify_query
    test r8, r8
    jz .Lnotify_pointer
    mov qword ptr [r8], 0
    test rdx, rdx
    jz .Lnotify_pointer
    mov r9, [rdx]
    mov r10, [rdx+8]
    cmp r9, [rip+notify_iid]
    jne .Lnotify_unknown
    cmp r10, [rip+notify_iid+8]
    je .Lnotify_supported
.Lnotify_unknown:
    cmp r9, [rip+notify_unknown]
    jne .Lnotify_no_interface
    cmp r10, [rip+notify_unknown+8]
    jne .Lnotify_no_interface
.Lnotify_supported:
    lea rax, [rip+output_notification_client]
    mov [r8], rax
    lock inc dword ptr [rip+notify_refs]
    xor eax, eax
    ret
.Lnotify_pointer:
    mov eax, 0x80004003                 # E_POINTER
    ret
.Lnotify_no_interface:
    mov eax, 0x80004002                 # E_NOINTERFACE
    ret
ENDFN notify_query
LOCALFN notify_addref
    mov eax, 1
    lock xadd [rip+notify_refs], eax
    inc eax
    ret
ENDFN notify_addref
LOCALFN notify_release
    mov eax, -1
    lock xadd [rip+notify_refs], eax
    dec eax
    ret
ENDFN notify_release
LOCALFN notify_ignore
    xor eax, eax
    ret
ENDFN notify_ignore
LOCALFN notify_default
    test edx, edx                      # eRender
    jnz .Lnotify_ignored
    test r8d, r8d                      # eConsole (same role used to open)
    jnz .Lnotify_ignored
    sub rsp, 40
    lock inc dword ptr [rip+notify_readers]
    mov rcx, [rip+notify_event]
    test rcx, rcx
    jz .Lnotify_leave
    cmp qword ptr [rip+device_chosen], 0 # explicit selection stays pinned
    jne .Lnotify_leave
    mov dword ptr [rip+notify_pending], 1
    call SetEvent                     # wakes playback, including paused waits
.Lnotify_leave:
    lock dec dword ptr [rip+notify_readers]
    add rsp, 40
.Lnotify_ignored:
    xor eax, eax
    ret
ENDFN notify_default

# RCX=IMMDeviceEnumerator, RDX=owned audio event (kept valid until stop returns).
# Registration failures leave the previous invalidated-endpoint recovery usable.
FN output_notifications_start
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    call output_notifications_stop
    test rbx, rbx
    jz .Lnotify_invalid
    test rsi, rsi
    jz .Lnotify_invalid
    cmp qword ptr [rip+device_chosen], 0
    jne .Lnotify_skip
    mov rcx, rbx
    mov rax, [rcx]
    call qword ptr [rax+8]             # retain enumerator until stop
    mov [rip+notify_enum], rbx
    mov [rip+notify_event], rsi
    mov rcx, rbx
    lea rdx, [rip+output_notification_client]
    mov rax, [rcx]
    call qword ptr [rax+48]            # RegisterEndpointNotificationCallback
    test eax, eax
    js .Lnotify_start_failed
    mov dword ptr [rip+notify_registered], 1
    xor eax, eax
    jmp .Lnotify_start_return
.Lnotify_start_failed:
    mov ebx, eax
    call output_notifications_stop
    mov eax, ebx
    jmp .Lnotify_start_return
.Lnotify_invalid:
    mov eax, 0x80070057
    jmp .Lnotify_start_return
.Lnotify_skip:
    mov eax, 1                         # S_FALSE: explicit endpoint
.Lnotify_start_return:
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN output_notifications_start

FN output_notifications_stop
    push rbx
    push rsi
    sub rsp, 40
    xor eax, eax
    xchg [rip+notify_event], rax        # no later callback may acquire the handle
    mov rbx, [rip+notify_enum]
    mov qword ptr [rip+notify_enum], 0
    xor esi, esi
    test rbx, rbx
    jz .Lnotify_drain
    cmp dword ptr [rip+notify_registered], 0
    je .Lnotify_drain
    mov dword ptr [rip+notify_registered], 0
    mov rcx, rbx
    lea rdx, [rip+output_notification_client]
    mov rax, [rcx]
    call qword ptr [rax+56]            # outside callback, no synchronization held
    mov esi, eax
.Lnotify_drain:
    cmp dword ptr [rip+notify_readers], 0
    je .Lnotify_drained
    xor ecx, ecx                       # only cleanup waits; callback never does
    call Sleep
    jmp .Lnotify_drain
.Lnotify_drained:
    mov dword ptr [rip+notify_pending], 0
    test rbx, rbx
    jz .Lnotify_stopped
    mov rcx, rbx
    mov rax, [rcx]
    call qword ptr [rax+16]
.Lnotify_stopped:
    mov eax, esi
    add rsp, 40
    pop rsi
    pop rbx
    ret
ENDFN output_notifications_stop
FN output_notifications_take
    xor eax, eax
    xchg [rip+notify_pending], eax
    cmp qword ptr [rip+device_chosen], 0
    je .Lnotify_taken
    xor eax, eax
.Lnotify_taken:
    ret
ENDFN output_notifications_take
