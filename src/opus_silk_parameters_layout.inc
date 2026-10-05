# Gain reconstruction request, 48 bytes. All writable buffers separate.
.equ SG_IND, 0                   # signed-byte indices,2/4 entries
.equ SG_OUT, 8                   # positive int32 Q16 gains
.equ SG_PREV, 16                 # one signed-byte last gain index0..63
.equ SG_SUBFR, 24                # 2/4
.equ SG_CONDITIONAL, 28          # 0 independent,1 conditional
.equ SG_IND_CAP, 32              # bytes
.equ SG_OUT_CAP, 36              # int32 count
.equ SG_PREV_CAP, 40             # bytes
# Pitch/LTP reconstruction request,56 bytes. Input SideInfoIndices immutable.
.equ SP_IND, 0                   # 36-byte layout in opus_silk_indices_layout
.equ SP_PITCH, 8                 # 2/4 int32 lags
.equ SP_LTP, 16                  # 10/20 int16 Q14 taps
.equ SP_SCALE, 24                # one int32 Q14 scale
.equ SP_FS, 32                   # 8/12/16 kHz
.equ SP_SUBFR, 36                # 2/4
.equ SP_PITCH_CAP, 40            # int32 count
.equ SP_LTP_CAP, 44              # int16 count
.equ SP_SCALE_CAP, 48            # int32 count
