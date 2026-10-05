# NLSF reconstruction request,40 bytes. All buffers separate, caller-owned.
.equ SN_IND, 0                   # first-stage and10/16 residual signed bytes
.equ SN_OUT, 8                   # 10/16 int16 Q15 NLSF output
.equ SN_WORK, 16                 #112-byte workspace below
.equ SN_FS, 24                   #8/12/16 kHz
.equ SN_IND_CAP, 28              #byte count >=order+1
.equ SN_OUT_CAP, 32              #int16 count >=order
.equ SN_WORK_CAP, 36             #byte count >=112
.equ NW_IX, 0                    #16 int16 entropy-selector offsets
.equ NW_PRED, 32                 #16 predictor bytes
.equ NW_RES, 48                  #16 int16 Q10 residuals
.equ NW_WEIGHT, 80               #16 int16 Q2 Laroia weights
.equ NW_SIZE, 112
# In-place fixed-codebook stabilization request,16 bytes.
.equ NS_OUT, 0
.equ NS_FS, 8
.equ NS_CAP, 12                  #int16 count >=order
