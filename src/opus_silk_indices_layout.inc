# SILK side-information request, 56 bytes. Buffers separate, caller-owned.
.equ SI_EC, 0                    # 64-byte primed range context
.equ SI_STATE, 8                 # 8-byte prior-index state
.equ SI_OUT, 16                  # 36-byte normative SideInfoIndices layout
.equ SI_FS, 24                   # internal rate8/12/16 kHz
.equ SI_SUBFR, 28                # 2/4 five-millisecond subframes
.equ SI_VAD, 32                  # current frame VAD0/1
.equ SI_LBRR, 36                 # redundant-frame flag0/1
.equ SI_COND, 40                 # 0 independent,1 noLTPscale,2 conditional
.equ SI_OUT_CAP, 44              # bytes, >=36
.equ SI_STATE_CAP, 48            # bytes, >=8
.equ SS_LAG, 0                   # signed previous lag index, -32768..32767
.equ SS_SIGNAL, 4                # previous entropy signal type0..2
.equ SX_GAINS, 0                 # four signed bytes
.equ SX_LTP, 4                   # four signed bytes
.equ SX_NLSF, 8                  # seventeen signed bytes
.equ SX_LAG, 26                  # signed16, padding byte25 untouched
.equ SX_CONTOUR, 28
.equ SX_SIGNAL, 29
.equ SX_OFFSET, 30
.equ SX_INTERP, 31
.equ SX_PER, 32
.equ SX_SCALE, 33
.equ SX_SEED, 34                 # trailing padding byte35 untouched
# NLSF entropy-selector/predictor unpack request, 32 bytes.
.equ SU_EC_IX, 0                 # int16 array,10/16 elements
.equ SU_PRED, 8                  # uint8 array,10/16 elements
.equ SU_FS, 16
.equ SU_INDEX, 20                # first-stage vector0..31
.equ SU_EC_CAP, 24               # int16 count
.equ SU_PRED_CAP, 28             # uint8 count
