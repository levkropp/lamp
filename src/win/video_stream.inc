# Original single-owner decoded-picture output queue. No owned allocations/COM.
.equ VS_BYTES, 512
.equ VS_GPU, 0
.equ VS_PARSER, 8
.equ VS_READY, 16
.equ VS_ERROR, 20
.equ VS_PENDING, 24
.equ VS_EOF, 28
.equ VS_COUNT, 32
.equ VS_REORDER, 36
.equ VS_LAST, 40
.equ VS_HAVE_ORDER, 44
.equ VS_OUTPUTS, 48
.equ VS_DECODED, 56
.equ VS_DROPPED, 64
.equ VS_LAST_EPOCH, 72
.equ VS_LAST_POC, 80
.equ VS_QUEUE, 96 # 17 records {epoch:u64,poc:i32,slot:u32}.
