# Standard CELT decoder state, 18,272 bytes, fixed mono/stereo storage.
.equ SD_MAGIC, 0
.equ SD_CHANNELS, 4
.equ SD_DOWNSAMPLE, 8
.equ SD_RNG, 12
.equ SD_ERROR, 16
.equ SD_PERIOD, 20
.equ SD_PERIOD_OLD, 24
.equ SD_GAIN, 28
.equ SD_GAIN_OLD, 32
.equ SD_TAP, 36
.equ SD_TAP_OLD, 40
.equ SD_DEEMPH, 44
.equ SD_LAST_PITCH, 52
.equ SD_LOSS, 56
.equ SD_DECODE, 64
.equ SD_DECODE_STRIDE, 8672       # (2048+120)*4
.equ SD_LPC, 17408               # two 24-float loss-concealment LPC histories
.equ SD_OLD_E, 17600
.equ SD_OLD_LOG, 17768
.equ SD_OLD_LOG2, 17936
.equ SD_BACKGROUND, 18104
.equ SD_SIZE, 18272
.equ SD_MAGIC_VALUE, 0x31544c43    # CLT1
# Frame request, 72 bytes. All capacities are bytes except PCM float capacity.
.equ DF_STATE, 0
.equ DF_DATA, 8
.equ DF_PCM, 16
.equ DF_EC, 24                   # optional already-primed 64-byte entropy context
.equ DF_WORK, 32
.equ DF_LEN, 40
.equ DF_CHANNELS, 44             # bitstream channels, output channels in state
.equ DF_LM, 48
.equ DF_START, 52
.equ DF_END, 56
.equ DF_PCM_CAP, 60
.equ DF_WORK_CAP, 64
.equ DF_STATE_CAP, 68
# Bounded caller-owned per-frame workspace, 44,048 bytes.
.equ DW_EC, 0
.equ DW_CONTROLS, 64
.equ DW_TF, 208
.equ DW_OFFSETS, 292
.equ DW_CAPS, 376
.equ DW_BITS, 460
.equ DW_FINE, 544
.equ DW_PRIORITY, 628
.equ DW_MASKS, 720
.equ DW_GAINS, 768
.equ DW_X, 944
.equ DW_FREQ, 8624
.equ DW_NORM, 16304
.equ DW_BAND_SCRATCH, 22704
.equ DW_SYNTH_SCRATCH, 23408
.equ DW_TIME, 35408
.equ DW_OVERLAP, 43088
.equ DW_SIZE, 44048
