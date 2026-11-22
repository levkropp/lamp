# Opaque complete mono Speex frame decoder arena, all three bands.
# First 16384 bytes are live; the rest is shadow and bounded scratch.
.equ SPXD_SIZE, 65536
.equ SPXD_LIVE, 16384
.equ SPXD_MAGIC_VALUE, 0x44585053
.equ SPXD_MODE, 16368
.equ SPXD_FLAGS, 16372
.equ SPXD_MAGIC, 16376
.equ SPXD_WB, 8192
.equ SPXD_UWB, 12288
# Each high-band live record occupies 4096 bytes.
.equ SPXH_FIRST, 0
.equ SPXH_MODE, 4
.equ SPXH_SEED, 8
.equ SPXH_ENERGY, 12
.equ SPXH_OLD_LSP, 16
.equ SPXH_LPC, 48
.equ SPXH_MEM, 80
.equ SPXH_PI, 144
.equ SPXH_RMS, 160
.equ SPXH_EXC, 176
.equ SPXH_QMF, 496
.equ SPXH_INNOV, 1008
# Working storage, relative to whole arena; not persistent state.
.equ SPXD_BITS, 32768
.equ SPXD_OUT, 32832
.equ SPXD_PI, 36736
.equ SPXD_RMS, 36752
.equ SPXD_QLSP, 36800
.equ SPXD_INTERP, 36832
.equ SPXD_AK, 36864
.equ SPXD_EXC, 36928
.equ SPXD_INNOV2, 37248
.equ SPXD_QMF, 37632
