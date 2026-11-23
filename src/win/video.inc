# Original D3D11 H.264 I/P submission backend. See docs/windows-video.md.
.equ WV_BYTES, 1024
.equ WV_DEVICE, 0
.equ WV_CONTEXT, 8
.equ WV_VIDEO_DEVICE, 16
.equ WV_VIDEO_CONTEXT, 24
.equ WV_DECODER, 32
.equ WV_TEXTURE, 40
.equ WV_VIEW, 48
.equ WV_STAGING, 56
.equ WV_WIDTH, 64
.equ WV_HEIGHT, 68
.equ WV_READY, 72
.equ WV_HRESULT, 76
.equ WV_POOL, 80
.equ WV_CONFIG_INDEX, 84
.equ WV_FEATURE, 88
.equ WV_HAVE_FRAME, 92
.equ WV_COPY_PENDING, 96
.equ WV_CURRENT, 100
.equ WV_DECODED_MASK, 104
.equ WV_REQUIRED, 108
.equ WV_SELECT, 112
.equ WV_INITIALIZED, 116     # Successful surfaces across IDR, for held output.
.equ WV_DESC, 128
.equ WV_CONFIG, 160
.equ WV_VIEW_DESC, 272
.equ WV_TEX_DESC, 304
.equ WV_MAP, 352
.equ WV_BUFFERS, 384
.equ WV_BUFFER_SIZE, 704
.equ WV_BUFFER_PTR, 712
.equ WV_VIEWS, 768           # 32 array-slice output views; entry0 aliases WV_VIEW.
.equ WV_INVALID, 0x80070057
.equ WV_UNEXPECTED, 0x8000ffff
.equ WV_UNSUPPORTED, 0x887a0004
.equ WV_PENDING, 0x8000000a
