# Bandwidth expansion request,24 bytes. In-place caller-owned filter.
.equ SB_AR, 0                    # int16/int32 coefficient pointer
.equ SB_ORDER, 8                 # 1..16
.equ SB_CHIRP, 12                # Q16,0..65536
.equ SB_CAP, 16                  # coefficient count
.equ SB_WIDTH, 20                # 16 or32 bits
# LPC inverse prediction gain request,16 bytes. Input unchanged.
.equ SL_AR, 0                    # int16 Q12 coefficients
.equ SL_ORDER, 8                 # 10/16
.equ SL_CAP, 12                  # int16 count
# NLSF-to-LPC request,32 bytes. Separate buffers, input unchanged.
.equ SA_NLSF, 0                  # int16 Q15,0..32767
.equ SA_OUT, 8                   # int16 Q12 prediction coefficients
.equ SA_ORDER, 16                # 10/16
.equ SA_IN_CAP, 20               # int16 count
.equ SA_OUT_CAP, 24              # int16 count
