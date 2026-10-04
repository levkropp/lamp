; SILK comfort-noise request,88 bytes. All writable buffers separate.
CG_STATE EQU 0                 ;1388-byte normative CNG state below
CG_CORE EQU 8                  ;read-only2320-byte core history
CG_PARAM EQU 16                ;read-only48-byte parameter history
CG_CTRL EQU 24                 ;read-only140-byte decoder controls
CG_PCM EQU 32                  ;in-place int16 source-rate PCM
CG_WORK EQU 40                 ;1376-byte workspace
CG_FS EQU 48                   ;8/12/16 kHz
CG_SUBFR EQU 52                ;2/4
CG_N EQU 56                    ;1..frame length
CG_STATE_CAP EQU 60            ;bytes
CG_CORE_CAP EQU 64             ;bytes
CG_PARAM_CAP EQU 68            ;bytes
CG_CTRL_CAP EQU 72             ;bytes
CG_PCM_CAP EQU 76              ;int16 count
CG_WORK_CAP EQU 80             ;bytes
CN_EXC EQU 0                   ;320 int32 Q14 excitation samples
CN_NLSF EQU 1280               ;16 smoothed int16 Q15 NLSFs
CN_SYN EQU 1312                ;16 int32 Q10 synthesis history
CN_GAIN EQU 1376               ;nonnegative smoothed int32 Q16 gain
CN_RNG EQU 1380                ;int32 random seed
CN_FS EQU 1384                 ;previous internal kHz
CN_SIZE EQU 1388
CW_SIG EQU 0                   ;336 int32 Q10 samples
CW_COEF EQU 1344               ;16 int16 Q12 coefficients
CW_SIZE EQU 1376
