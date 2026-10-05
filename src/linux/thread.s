# LAMP Linux threads, events and signals: raw system calls, no C library.
# Threads share the address space, files and signal handlers (CLONE_THREAD).
# Events are nonblocking eventfds, so a thread can wait on several with poll.
# MIT license.
.include "lamp.inc"
.include "linux.inc"

.equ THREAD_STACK, 4 * 1024 * 1024     # matches the decoder's Windows stack reserve
.equ THREAD_TID, THREAD_STACK - 16      # tid word, cleared by the kernel at thread exit

.text
# RCX=function(RCX=argument) using the Microsoft x64 convention, RDX=argument
# -> RAX=thread handle or 0. The lowest stack page stays inaccessible as a guard.
FN thread_create
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12, rcx
    mov r13, rdx
    mov ecx, THREAD_STACK
    call mem_reserve
    test rax, rax
    jz .Lthread_create_done
    mov rbx, rax
    lea rcx, [rax + 4096]
    mov edx, THREAD_STACK - 4096
    call mem_commit
    test rax, rax
    jz .Lthread_create_fail
    lea rsi, [rbx + THREAD_TID - 48]   # child stack: function and argument on top
    mov [rsi], r12
    mov [rsi + 8], r13
    mov edi, CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID
    lea rdx, [rbx + THREAD_TID]
    mov r10, rdx
    xor r8d, r8d
    mov eax, SYS_clone
    syscall
    test rax, rax
    jz .Lthread_child
    js .Lthread_create_fail
    mov rax, rbx
    jmp .Lthread_create_done
.Lthread_child:
    mov rax, [rsp]
    mov rcx, [rsp + 8]
    and rsp, -16
    sub rsp, 32
    call rax
    mov edi, eax
    mov eax, SYS_exit                 # this thread only
    syscall
.Lthread_create_fail:
    mov rcx, rbx
    call mem_free
    xor eax, eax
.Lthread_create_done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN thread_create

# RCX=thread handle or 0. Waits for the thread to exit, then frees its stack.
FN thread_join
    test rcx, rcx
    jz .Lthread_join_none
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
.Lthread_join_wait:
    mov edx, [rbx + THREAD_TID]
    test edx, edx
    jz .Lthread_join_free
    lea rdi, [rbx + THREAD_TID]
    mov esi, FUTEX_WAIT
    xor r10d, r10d
    mov eax, SYS_futex
    syscall
    jmp .Lthread_join_wait
.Lthread_join_free:
    mov rcx, rbx
    call mem_free
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
.Lthread_join_none:
    ret
ENDFN thread_join

# -> EAX=event descriptor (nonblocking eventfd) or -1.
FN event_create
    push rdi
    push rsi
    xor edi, edi
    mov esi, EFD_NONBLOCK | EFD_CLOEXEC
    mov eax, SYS_eventfd2
    syscall
    test eax, eax
    jns .Levent_create_done
    mov eax, -1
.Levent_create_done:
    pop rsi
    pop rdi
    ret
ENDFN event_create

# ECX=event descriptor. Safe from signal handlers and other threads.
FN event_signal
    push rdi
    push rsi
    sub rsp, 16
    mov qword ptr [rsp], 1
    mov edi, ecx
    mov rsi, rsp
    mov edx, 8
    mov eax, SYS_write
    syscall
    add rsp, 16
    pop rsi
    pop rdi
    ret
ENDFN event_signal

# ECX=event descriptor. Consumes pending signals without blocking.
FN event_clear
    push rdi
    push rsi
    sub rsp, 16
    mov edi, ecx
    mov rsi, rsp
    mov edx, 8
    mov eax, SYS_read
    syscall
    add rsp, 16
    pop rsi
    pop rdi
    ret
ENDFN event_clear

# ECX=event descriptor or -1.
FN event_close
    test ecx, ecx
    js .Levent_close_none
    push rdi
    mov edi, ecx
    mov eax, SYS_close
    syscall
    pop rdi
.Levent_close_none:
    ret
ENDFN event_close

# RCX=pollfd array, EDX=count, R8D=timeout ms (-1 waits) -> EAX=ready count, or
# negative errno. EINTR returns so callers can observe signal-handler flags.
FN poll_wait
    push rdi
    push rsi
    mov rdi, rcx
    mov esi, edx
    mov edx, r8d
    mov eax, SYS_poll
    syscall
    pop rsi
    pop rdi
    ret
ENDFN poll_wait

# ECX=signal, RDX=handler(RDI=signal; System V entry, may clobber registers),
# or SIG_IGN -> EAX=0 on success.
FN signal_set
    push rdi
    push rsi
    sub rsp, 40
    mov [rsp], rdx
    mov qword ptr [rsp + 8], SA_RESTORER
    lea rax, [rip + signal_restorer]
    mov [rsp + 16], rax
    mov qword ptr [rsp + 24], 0        # mask
    mov edi, ecx
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, SYS_rt_sigaction
    syscall
    add rsp, 40
    pop rsi
    pop rdi
    ret
ENDFN signal_set

LOCALFN signal_restorer
    mov eax, SYS_rt_sigreturn
    syscall
ENDFN signal_restorer
