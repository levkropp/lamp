; Float CELT prediction kernels. Capacities count floats, requests immutable.
; Autocorrelation request, 64 bytes. Separate scratch requires N floats.
LA_X EQU 0
LA_AC EQU 8
LA_WINDOW EQU 16               ; NULL only when overlap=0
LA_SCRATCH EQU 24
LA_N EQU 32                    ; 1..2048
LA_LAG EQU 36                  ; 0..24 and <N
LA_OVERLAP EQU 40              ; 0..120 and <=N/2
LA_X_CAP EQU 44
LA_AC_CAP EQU 48
LA_WINDOW_CAP EQU 52
LA_SCRATCH_CAP EQU 56
; Levinson-Durbin request, 32 bytes. AC has order+1 values, output order.
LL_OUT EQU 0
LL_AC EQU 8
LL_ORDER EQU 16                ; 1..24
LL_OUT_CAP EQU 20
LL_AC_CAP EQU 24
; FIR/IIR request, 56 bytes. Out may equal X; other buffers separate.
LF_X EQU 0
LF_COEF EQU 8
LF_OUT EQU 16
LF_MEM EQU 24
LF_N EQU 32                    ; 1..1200
LF_ORDER EQU 36                ; 1..24
LF_X_CAP EQU 40
LF_COEF_CAP EQU 44
LF_OUT_CAP EQU 48
LF_MEM_CAP EQU 52
