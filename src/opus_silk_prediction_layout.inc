# Zero-state LPC analysis request,48 bytes. All buffers separate.
.equ SF_OUT, 0                   #int16 output
.equ SF_IN, 8                    #int16 input,unchanged
.equ SF_COEF, 16                 #int16 Q12 filter,unchanged
.equ SF_N, 24                    #order..480 samples
.equ SF_ORDER, 28                #even6..16
.equ SF_OUT_CAP, 32              #int16 count
.equ SF_IN_CAP, 36               #int16 count
.equ SF_COEF_CAP, 40             #int16 count
