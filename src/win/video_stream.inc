# Original single-owner decoded-picture output queue. No owned allocations/COM.
.equ VS_BYTES, 1536
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
.equ VS_INPUT_CONTEXT, 88
.equ VS_INPUT_FN, 96
.equ VS_SOURCE_EPOCH, 104
.equ VS_PTS, 112
.equ VS_DURATION, 120
.equ VS_FLAGS, 128
.equ VS_INDEX, 132
.equ VS_EXTERNAL_EPOCH, 136
.equ VS_SHOW_PTS, 144
.equ VS_SHOW_DURATION, 152
.equ VS_HEAD_PTS, 160
.equ VS_HEAD_DURATION, 168
.equ VS_PEEK, 184
.equ VS_BUDGET, 192
.equ VS_HIDDEN, 200
.equ VS_LAST_SHOW_END, 208
.equ VS_HAVE_TIME, 216
.equ VS_PACKET, 224 # Borrowed source callback's80B packet metadata.
.equ VS_QUEUE, 384 #17*64B {codecEpoch,poc/slot,PTS,duration,externalEpoch,
                     # flags/index,showPTS,showDuration}; all scalar64 exceptpairs.
