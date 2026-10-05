# Linux x86-64 system call numbers and ABI constants used by LAMP.
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_open, 2
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_poll, 7
.equ SYS_mmap, 9
.equ SYS_mprotect, 10
.equ SYS_munmap, 11
.equ SYS_rt_sigaction, 13
.equ SYS_rt_sigprocmask, 14
.equ SYS_ioctl, 16
.equ SYS_socket, 41
.equ SYS_connect, 42
.equ SYS_sendto, 44
.equ SYS_recvfrom, 45
.equ SYS_clone, 56
.equ SYS_exit, 60
.equ SYS_getuid, 102
.equ SYS_futex, 202
.equ SYS_clock_gettime, 228
.equ SYS_exit_group, 231
.equ SYS_openat, 257
.equ SYS_eventfd2, 290
.equ SYS_pipe2, 293

.equ O_RDONLY, 0
.equ O_WRONLY, 1
.equ O_RDWR, 2
.equ O_CREAT, 0x40
.equ O_EXCL, 0x80
.equ O_NONBLOCK, 0x800
.equ O_CLOEXEC, 0x80000

.equ PROT_NONE, 0
.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_PRIVATE, 2
.equ MAP_ANONYMOUS, 0x20

# struct stat (x86-64)
.equ STAT_MODE, 24
.equ STAT_SIZE, 48
.equ S_IFMT, 0xf000
.equ S_IFREG, 0x8000

.equ CLOCK_MONOTONIC, 1
.equ CLOCK_PROCESS_CPUTIME_ID, 2

.equ EINTR, 4
.equ EAGAIN, 11
