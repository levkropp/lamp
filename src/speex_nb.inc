# Caller-owned Speex narrowband decoder arena. Defined state is the first
# SPXN_LIVE bytes; shadow/work bytes may change on a failed frame.
.equ SPXN_MAGIC, 0x424e5053
.equ SPXN_SIZE, 8192
.equ SPXN_LIVE, 2912
.equ SPXN_FIRST, 4
.equ SPXN_LOST, 8
.equ SPXN_MODE, 12
.equ SPXN_FLAGS, 16                  # enhancement=1, high-pass=2, embedded WB=4
.equ SPXN_SEED, 20
.equ SPXN_LAST_PITCH, 24
.equ SPXN_PGAIN_INDEX, 28
.equ SPXN_DTX, 32
.equ SPXN_VOC_OFFSET, 36
.equ SPXN_STEREO_CODE, 40           # last in-band stereo byte; -1 initially
.equ SPXN_LAST_OL_GAIN, 44
.equ SPXN_LAST_PGAIN, 48
.equ SPXN_LEVEL, 52
.equ SPXN_MAX_LEVEL, 56
.equ SPXN_MIN_LEVEL, 60
.equ SPXN_VOC_M1, 64
.equ SPXN_VOC_M2, 68
.equ SPXN_VOC_MEAN, 72
.equ SPXN_OLD_LSP, 80
.equ SPXN_LPC, 128
.equ SPXN_MEM_SP, 176
.equ SPXN_MEM_HP, 224
.equ SPXN_PI_GAIN, 240
.equ SPXN_PGAIN_BUF, 256
.equ SPXN_EXCBUF, 272               # 500 float samples
.equ SPXN_EXC, 1608                 # excBuf + 334 floats
.equ SPXN_INNOVATION, 2272          # 160 float samples, before vocoder processing
# Work offsets relative to arena start, after the complete live shadow.
.equ SPXN_OUT, 5824
.equ SPXN_QLSP, 6464
.equ SPXN_INTERP, 6512
.equ SPXN_AK, 6560
.equ SPXN_INNOV, 6608
.equ SPXN_INNOV2, 6768
.equ SPXN_EXC32, 6928
.equ SPXN_PITCH_JOB, 7088
.equ SPXN_BITS, 7168
