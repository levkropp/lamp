# Original bounded video scheduling ABI. MIT; see docs/video-sync.md.
# Caller-owned, single-owner context; all times are signed nanoseconds.
.equ VS_CAPACITY, 32
.equ VS_HEADER, 128
.equ VS_BYTES, VS_HEADER + VS_CAPACITY*32
.equ VS_EPOCH, 0
.equ VS_TARGET, 8
.equ VS_CLOCK, 16
.equ VS_SEEN, 24
.equ VS_COUNT, 28
.equ VS_LATE, 32
.equ VS_PRESENTED, 40
.equ VS_DROPPED, 48
.equ VS_LAST_PTS, 56
.equ VS_HAVE_PTS, 64
# Clock: epoch:u64, media_ns:i64, state:u32, reserved:u32 (must be zero).
.equ VS_RUNNING, 0
.equ VS_PAUSED, 1
.equ VS_STARVED, 2
.equ VS_STEP, 3
# select result: frame {pts:i64,duration:u64,token:u64,epoch:u64}, wait_ns:i64.
.equ VS_WAIT, 0
.equ VS_PRESENT, 1
.equ VS_DROP, 2
.equ VS_EMPTY, 3
.equ VS_HOLD, 4
.equ VS_ERROR, -1
