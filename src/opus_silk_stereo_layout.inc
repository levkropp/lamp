# Stereo entropy request,32 bytes. Outputs/entropy separate.
.equ ST_EC, 0                    #64-byte primed range context
.equ ST_OUT, 8                   #int32 predictor pair or mid-only flag
.equ ST_KIND, 16                 #0 predictors/1 mid-only
.equ ST_OUT_CAP, 20              #int32 count>=2/1
.equ ST_EC_CAP, 24               #bytes>=64
# Stereo reconstruction request,56 bytes. Buffers separate.
.equ SM_STATE, 0                 #12-byte normative history
.equ SM_MID, 8                   #int16 length+2,output left at1..length
.equ SM_SIDE, 16                 #int16 length+2,output right at1..length
.equ SM_PRED, 24                 #2 immutable int32 Q13 predictors
.equ SM_FS, 32                   #8/12/16 kHz
.equ SM_N, 36                    #fs*10 orfs*20 samples
.equ SM_STATE_CAP, 40            #bytes>=12
.equ SM_MID_CAP, 44              #int16 count>=N+2
.equ SM_SIDE_CAP, 48             #int16 count>=N+2
.equ SM_PRED_CAP, 52             #int32 count>=2
.equ SN_PRED, 0                  #2 int16 prior Q13 predictors
.equ SN_MID, 4                   #2 int16 mid history
.equ SN_SIDE, 8                  #2 int16 side history
