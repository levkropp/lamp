# Original bounded device/submitted-PCM timeline and reader snapshot. MIT.
.equ AC_BYTES, 1664
.equ AC_VERSION, 0
.equ AC_EPOCH, 8
.equ AC_BASE, 16
.equ AC_DEVICE, 24
.equ AC_SUBMITTED, 32
.equ AC_REAL, 40
.equ AC_MEDIA, 48
.equ AC_RATE, 56
.equ AC_STATE, 60
.equ AC_HEAD, 64
.equ AC_TAIL, 72
.equ AC_MODE, 80 #0: submitted-frame map;1: caller's already mapped position.
.equ AC_LIMIT, 88
.equ AC_RECORDS, 128 #64*24 {deviceStart,relativeMediaStart,realFrames}.
.equ AC_RUNNING, 0
.equ AC_PAUSED, 1
.equ AC_STARVED, 2
.equ AC_ENDED, 4
.equ AC_STOPPED, 5
.equ AC_FAILED, 6
