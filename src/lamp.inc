# LAMP shared assembler conventions for GNU as (ELF64) and llvm-mc (COFF).
# Code uses the Microsoft x64 calling convention on every platform:
# RCX, RDX, R8, R9, shadow space, and nonvolatile RBX/RBP/RDI/RSI/R12-R15/XMM6-XMM15.
.intel_syntax noprefix

# Global function.
.macro FN name
    .text
    .globl \name
    .ifndef WINDOWS
    .type \name, @function
    .endif
    .p2align 4
\name:
.endm

# File-local function.
.macro LOCALFN name
    .text
    .ifndef WINDOWS
    .type \name, @function
    .endif
    .p2align 4
\name:
.endm

.macro ENDFN name
    .ifndef WINDOWS
    .size \name, . - \name
    .endif
.endm

# Read-only data.
.macro RODATA
    .ifdef WINDOWS
    .section .rdata, "dr"
    .else
    .section .rodata
    .endif
.endm
