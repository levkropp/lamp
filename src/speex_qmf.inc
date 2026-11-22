# Fixed Speex 64-tap QMF synthesis arena. First 512 bytes are live history.
# Odd slots in each 64-float history are used; even slots are preserved.
.equ SPXQ_SIZE, 6144
.equ SPXQ_LIVE, 512
.equ SPXQ_LOW, 512
.equ SPXQ_HIGH, 1920
.equ SPXQ_OUT, 3328
