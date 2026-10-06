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
.equ SYS_getcwd, 79
.equ SYS_rename, 82
.equ SYS_mkdir, 83
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
.equ O_TRUNC, 0x200
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

.equ SYS_writev, 20
.equ SYS_rt_sigreturn, 15

.equ AF_UNIX, 1
.equ SOCK_STREAM, 1
.equ SOCK_CLOEXEC, 0x80000
.equ MSG_NOSIGNAL, 0x4000
.equ POLLIN, 1
.equ POLLERR, 8
.equ POLLHUP, 0x10
.equ EFD_NONBLOCK, 0x800
.equ EFD_CLOEXEC, 0x80000

.equ CLONE_VM, 0x100
.equ CLONE_FS, 0x200
.equ CLONE_FILES, 0x400
.equ CLONE_SIGHAND, 0x800
.equ CLONE_THREAD, 0x10000
.equ CLONE_SYSVSEM, 0x40000
.equ CLONE_PARENT_SETTID, 0x100000
.equ CLONE_CHILD_CLEARTID, 0x200000
.equ FUTEX_WAIT, 0

.equ SIGINT, 2
.equ SIGPIPE, 13
.equ SIGTERM, 15
.equ SIG_IGN, 1
.equ SA_RESTORER, 0x04000000
.equ SA_RESTART, 0x10000000

# struct termios (asm-generic, x86-64): c_iflag, c_oflag, c_cflag, c_lflag, ...
.equ TCGETS, 0x5401
.equ TCSETS, 0x5402
.equ TERMIOS_LFLAG, 12
.equ TERMIOS_CC, 17
.equ TERMIOS_SIZE, 36           # kernel struct termios used by TCGETS/TCSETS
.equ ICANON, 2
.equ ECHO, 8
.equ VTIME, 5
.equ VMIN, 6
