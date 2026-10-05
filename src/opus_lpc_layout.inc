# Float CELT prediction kernels. Capacities count floats, requests immutable.
# Autocorrelation request, 64 bytes. Separate scratch requires N floats.
.equ LA_X, 0
.equ LA_AC, 8
.equ LA_WINDOW, 16               # NULL only when overlap=0
.equ LA_SCRATCH, 24
.equ LA_N, 32                    # 1..2048
.equ LA_LAG, 36                  # 0..24 and <N
.equ LA_OVERLAP, 40              # 0..120 and <=N/2
.equ LA_X_CAP, 44
.equ LA_AC_CAP, 48
.equ LA_WINDOW_CAP, 52
.equ LA_SCRATCH_CAP, 56
# Levinson-Durbin request, 32 bytes. AC has order+1 values, output order.
.equ LL_OUT, 0
.equ LL_AC, 8
.equ LL_ORDER, 16                # 1..24
.equ LL_OUT_CAP, 20
.equ LL_AC_CAP, 24
# FIR/IIR request, 56 bytes. Out may equal X; other buffers separate.
.equ LF_X, 0
.equ LF_COEF, 8
.equ LF_OUT, 16
.equ LF_MEM, 24
.equ LF_N, 32                    # 1..1200
.equ LF_ORDER, 36                # 1..24
.equ LF_X_CAP, 40
.equ LF_COEF_CAP, 44
.equ LF_OUT_CAP, 48
.equ LF_MEM_CAP, 52
