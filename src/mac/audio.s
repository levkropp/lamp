// Native ARM64 Core Audio playback. AudioQueue owns the buffer callback thread;
// AppKit never decodes during playback. Three bounded float PCM buffers.
.include "mac.inc"
.equ FRAMES, 2048
.equ BYTES, FRAMES * 8

FN _lamp_audio_init
    ENTER
    ADR x0, mutex
    mov x1, #0
    bl _pthread_mutex_init
    LEAVE
    ret

FN _lamp_stop
    ENTER
    bl suspend_callbacks
    ADR x19, queue
    ldr x0, [x19]
    cbz x0, 1f
    mov w1, #1
    bl _AudioQueueStop
    ldr x0, [x19]
    mov w1, #1
    bl _AudioQueueDispose
    str xzr, [x19]
1:  bl _decoder_close
    ADR x19, current_path
    ldr x0, [x19]
    cbz x0, 2f
    bl _free
    str xzr, [x19]
2:
    ADR x9, _lamp_state
    str wzr, [x9]
    ADR x9, _lamp_eof
    str wzr, [x9]
    ADR x9, _lamp_position
    str xzr, [x9]
    LEAVE
    ret

FN _lamp_play
    ENTER
    ADR x9, _lamp_error
    str wzr, [x9]
    bl _strdup
    mov x19, x0
    cbz x19, audio_fail
    bl _lamp_stop
    ADR x9, current_path
    str x19, [x9]
    mov x0, x19
    bl _decoder_open
    cbz w0, audio_fail
    ADR x19, format
    ADR x9, output_rate
    ldr w9, [x9]
    ucvtf d0, w9
    str d0, [x19]
    mov x0, x19
    ADR x1, audio_callback
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov w5, #0
    ADR x6, queue
    bl _AudioQueueNewOutput
    cbnz w0, audio_fail
    ADR x20, buffers
    mov x21, #0
1:  ADR x9, queue
    ldr x0, [x9]
    mov w1, #BYTES
    add x2, x20, x21, lsl #3
    bl _AudioQueueAllocateBuffer
    cbnz w0, audio_fail
    ldr x0, [x20, x21, lsl #3]
    bl fill_buffer
    cbnz w0, audio_fail
    add x21, x21, #1
    cmp x21, #3
    b.lo 1b
    ADR x9, queue
    ldr x0, [x9]
    mov w1, #1 // kAudioQueueParam_Volume
    ADR x9, _lamp_volume
    ldr s0, [x9]
    bl _AudioQueueSetParameter
    cbnz w0, audio_fail
    ldr x9, [x20]
    ldr w10, [x9, #16]
    cbz w10, audio_empty
    ADR x9, transport_reset
    str wzr, [x9]
    ADR x9, queue
    ldr x0, [x9]
    mov x1, #0
    bl _AudioQueueStart
    cbnz w0, audio_fail
    ADR x9, _lamp_state
    mov w10, #1
    str w10, [x9]
    mov w0, #1
    b 2f
audio_empty:
    ADR x9, _lamp_state
    mov w10, #3
    str w10, [x9]
    mov w0, #1
    b 2f
audio_fail:
    ADR x9, _lamp_error
    cmp w0, #0
    mov w10, #-1
    csel w0, w0, w10, ne
    str w0, [x9]
    bl _lamp_stop
    ADR x9, _lamp_state
    mov w10, #4
    str w10, [x9]
    mov w0, #0
2:  LEAVE
    ret

// fill_buffer(buffer) -> OSStatus, including a sticky decode error.
fill_buffer:
    ENTER
    mov x19, x0
    ldr x0, [x19, #8] // mAudioData
    mov w1, #FRAMES
    bl _decoder_read
    cbz w0, 1f
    lsl w9, w0, #3
    str w9, [x19, #16] // mAudioDataByteSize
    ADR x9, queue
    ldr x0, [x9]
    mov x1, x19
    mov w2, #0
    mov x3, #0
    bl _AudioQueueEnqueueBuffer
    b 3f
1:  str wzr, [x19, #16]
    ADR x9, _lamp_eof
    mov w10, #1
    str w10, [x9]
    ADR x9, decode_error
    ldr w0, [x9]
    cbz w0, 2f
    mov w0, #-1
    b 3f
2:  mov w0, #0
3:  LEAVE
    ret

audio_callback:
    ENTER
    mov x19, x2
    ADR x0, mutex
    bl _pthread_mutex_lock
    ADR x9, transport_reset
    ldr w9, [x9]
    cbnz w9, 3f
    ldr w9, [x19, #16]
    lsr x9, x9, #3
    ADR x10, _lamp_position
    ldr x11, [x10]
    add x11, x11, x9
    str x11, [x10]
    mov x0, x19
    bl fill_buffer
    cbz w0, 1f
    ADR x9, _lamp_error
    str w0, [x9]
    ADR x9, _lamp_state
    mov w10, #4
    str w10, [x9]
1:  ADR x9, _lamp_eof
    ldr w20, [x9]
    ADR x0, mutex
    bl _pthread_mutex_unlock
    cbz w20, 2f
    ADR x9, queue
    ldr x0, [x9]
    mov w1, #0 // drain queued buffers; never dispose from the callback
    bl _AudioQueueStop
    b 2f
3:  ADR x0, mutex
    bl _pthread_mutex_unlock
2:  LEAVE
    ret

// Stop/reset returns discarded buffers through the callback. They must not
// advance the cursor or enqueue new PCM during a transport transition.
suspend_callbacks:
    ENTER
    ADR x0, mutex
    bl _pthread_mutex_lock
    ADR x9, transport_reset
    mov w10, #1
    str w10, [x9]
    ADR x0, mutex
    bl _pthread_mutex_unlock
    LEAVE
    ret

FN _lamp_pause
    ENTER
    ADR x19, _lamp_state
    ldr w20, [x19]
    ADR x9, queue
    ldr x0, [x9]
    cbz x0, 3f
    cmp w20, #1
    b.ne 1f
    bl _AudioQueuePause
    cbnz w0, 3f
    mov w20, #2
    b 2f
1:  cmp w20, #2
    b.ne 3f
    mov x1, #0
    bl _AudioQueueStart
    cbnz w0, 3f
    mov w20, #1
2:  str w20, [x19]
3:  LEAVE
    ret

FN _lamp_set_volume
    ENTER
    fmov s1, wzr
    fmov s2, #1.0
    fmax s0, s0, s1
    fmin s0, s0, s2
    ADR x9, _lamp_volume
    str s0, [x9]
    ADR x9, queue
    ldr x0, [x9]
    cbz x0, 1f
    mov w1, #1
    bl _AudioQueueSetParameter
1:  LEAVE
    ret

FN _lamp_seek
    ENTER
    ADR x9, _lamp_error
    str wzr, [x9]
    mov x19, x0
    ADR x9, output_frames
    ldr x9, [x9]
    cbz x9, 7f
    cmp x19, x9
    csel x19, x19, x9, lo
7:
    ADR x9, queue
    ldr x0, [x9]
    cbz x0, 4f
    ADR x9, _lamp_state
    ldr w20, [x9]
    bl suspend_callbacks
    ADR x9, queue
    ldr x0, [x9]
    mov w1, #1
    bl _AudioQueueStop
    cbnz w0, 11f
    ADR x9, queue
    ldr x0, [x9]
    bl _AudioQueueReset
    cbnz w0, 11f
    ADR x0, mutex
    bl _pthread_mutex_lock
    bl _decoder_close
    ADR x9, current_path
    ldr x0, [x9]
    bl _decoder_open
    cbz w0, 9f
    mov x0, x19
    bl _decoder_seek
    mov x23, x0
5:  subs x24, x19, x23
    b.ls 6f
    mov x1, #FRAMES
    cmp x24, x1
    csel x1, x24, x1, lo
    ADR x0, seek_pcm
    bl _decoder_read
    cbz w0, 9f
    add x23, x23, x0
    b 5b
6:
    ADR x9, _lamp_position
    str x19, [x9]
    ADR x9, _lamp_eof
    str wzr, [x9]
    ADR x21, buffers
    mov x22, #0
1:  ldr x0, [x21, x22, lsl #3]
    bl fill_buffer
    cbnz w0, 10f
    add x22, x22, #1
    cmp x22, #3
    b.lo 1b
    ADR x9, transport_reset
    str wzr, [x9]
    ADR x0, mutex
    bl _pthread_mutex_unlock
    ldr x9, [x21]
    ldr w9, [x9, #16]
    cbz w9, 12f
    ADR x9, output_frames
    ldr x9, [x9]
    cbz x9, 8f
    cmp x19, x9
    b.lo 8f
12:
    ADR x9, _lamp_state
    mov w10, #3
    str w10, [x9]
    b 4f
8:
    cmp w20, #2
    b.eq 4f
    ADR x9, queue
    ldr x0, [x9]
    mov x1, #0
    bl _AudioQueueStart
    cbnz w0, 11f
    ADR x9, _lamp_state
    mov w10, #1
    str w10, [x9]
    b 4f
9:  mov w0, #-1
10: ADR x9, _lamp_error
    str w0, [x9]
3:  ADR x0, mutex
    bl _pthread_mutex_unlock
    bl _lamp_stop
    ADR x9, _lamp_state
    mov w10, #4
    str w10, [x9]
    b 4f
11: ADR x9, _lamp_error
    str w0, [x9]
    bl _lamp_stop
    ADR x9, _lamp_state
    mov w10, #4
    str w10, [x9]
4:  LEAVE
    ret

FN _lamp_tick
    ENTER 32
    ADR x9, _lamp_state
    ldr w9, [x9]
    cmp w9, #1
    b.ne 2f // A paused queue is also not running; it has not finished.
    ADR x9, queue
    ldr x0, [x9]
    cbz x0, 2f
    ADR x9, _lamp_eof
    ldr w9, [x9]
    cbz w9, 2f
    mov w1, #0x726e
    movk w1, #0x6171, lsl #16 // kAudioQueueProperty_IsRunning = 'aqrn'
    mov x2, sp
    add x3, sp, #8
    mov w9, #4
    str w9, [x3]
    bl _AudioQueueGetProperty
    cbnz w0, 2f
    ldr w9, [sp]
    cbnz w9, 2f
    ADR x9, _lamp_state
    ldr w10, [x9]
    cmp w10, #4
    b.eq 2f
    mov w10, #3
    str w10, [x9]
2:  ADR x9, _lamp_state
    ldr w0, [x9]
    LEAVE
    ret

.data
.p2align 3
format:
    .double 48000
    .long 0x6c70636d, 9, 8, 1, 8, 2, 32, 0
queue: .quad 0
buffers: .quad 0, 0, 0
current_path: .quad 0
.globl _lamp_position, _lamp_state, _lamp_eof, _lamp_volume, _lamp_error
_lamp_position: .quad 0
_lamp_state: .long 0
_lamp_eof: .long 0
_lamp_volume: .float 0.7
_lamp_error: .long 0
transport_reset: .long 1
.bss
.p2align 3
mutex: .zero 64
.p2align 4
seek_pcm: .zero BYTES
