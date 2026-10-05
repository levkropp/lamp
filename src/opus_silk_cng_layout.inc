# SILK comfort-noise request,88 bytes. All writable buffers separate.
.equ CG_STATE, 0                 #1388-byte normative CNG state below
.equ CG_CORE, 8                  #read-only2320-byte core history
.equ CG_PARAM, 16                #read-only48-byte parameter history
.equ CG_CTRL, 24                 #read-only140-byte decoder controls
.equ CG_PCM, 32                  #in-place int16 source-rate PCM
.equ CG_WORK, 40                 #1376-byte workspace
.equ CG_FS, 48                   #8/12/16 kHz
.equ CG_SUBFR, 52                #2/4
.equ CG_N, 56                    #1..frame length
.equ CG_STATE_CAP, 60            #bytes
.equ CG_CORE_CAP, 64             #bytes
.equ CG_PARAM_CAP, 68            #bytes
.equ CG_CTRL_CAP, 72             #bytes
.equ CG_PCM_CAP, 76              #int16 count
.equ CG_WORK_CAP, 80             #bytes
.equ CN_EXC, 0                   #320 int32 Q14 excitation samples
.equ CN_NLSF, 1280               #16 smoothed int16 Q15 NLSFs
.equ CN_SYN, 1312                #16 int32 Q10 synthesis history
.equ CN_GAIN, 1376               #nonnegative smoothed int32 Q16 gain
.equ CN_RNG, 1380                #int32 random seed
.equ CN_FS, 1384                 #previous internal kHz
.equ CN_SIZE, 1388
.equ CW_SIG, 0                   #336 int32 Q10 samples
.equ CW_COEF, 1344               #16 int16 Q12 coefficients
.equ CW_SIZE, 1376
