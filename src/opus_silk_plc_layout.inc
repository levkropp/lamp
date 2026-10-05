# SILK packet-loss update/concealment request,96 bytes. Buffers separate.
.equ PL_STATE, 0                 #92-byte normative PLC state below
.equ PL_CORE, 8                  #mutable2320-byte core history
.equ PL_PARAM, 16                #read-only48-byte parameter history
.equ PL_CTRL, 24                 #mutable140-byte controls
.equ PL_IND, 32                  #read-only36-byte indices
.equ PL_PCM, 40                  #int16 source-rate output
.equ PL_WORK, 48                 #3552-byte workspace
.equ PL_FS, 56                   #8/12/16 kHz
.equ PL_SUBFR, 60                #2/4 five-ms subframes
.equ PL_LOST, 64                 #0 update/1 conceal
.equ PL_STATE_CAP, 68            #bytes
.equ PL_CORE_CAP, 72             #bytes
.equ PL_PARAM_CAP, 76            #bytes
.equ PL_CTRL_CAP, 80             #bytes
.equ PL_IND_CAP, 84              #bytes
.equ PL_PCM_CAP, 88              #int16 count>=full frame
.equ PL_WORK_CAP, 92             #bytes
.equ PN_PITCH, 0                 #int32 Q8 lag
.equ PN_LTP, 4                   #5 int16 Q14 taps
.equ PN_LPC, 14                  #16 int16 Q12 taps
.equ PN_LAST, 48                 #int32 last-frame-lost
.equ PN_RNG, 52                  #int32 seed
.equ PN_SCALE, 56                #int16 Q14 random gain
.equ PN_ENERGY, 60               #nonnegative int32 concealment energy
.equ PN_SHIFT, 64                #int32 energy shift
.equ PN_LTP_SCALE, 68            #int16 Q14 prior LTP scale
.equ PN_GAINS, 72                #2 positive int32 Q16 gains
.equ PN_FS, 80                   #prior internal kHz
.equ PN_SUBFR, 84                #prior subframe count
.equ PN_SUBLEN, 88               #prior subframe length
.equ PN_SIZE, 92
.equ PW_EXC, 0                   #160 int16 scaled excitation samples
.equ PW_COEF, 320                #16 int16 Q12 coefficients
.equ PW_LTP, 352                 #320 int16 rewhitened history samples
.equ PW_Q14, 992                 #640 int32 LTP/LPC samples
.equ PW_SIZE, 3552
# Concealment/recovery glue request,32 bytes.
.equ PG_STATE, 0                 #92-byte mutable PLC state
.equ PG_PCM, 8                   #in-place int16 PCM
.equ PG_N, 16                    #1..320 samples
.equ PG_LOSS, 20                 #current nonnegative loss count
.equ PG_STATE_CAP, 24            #bytes
.equ PG_PCM_CAP, 28              #int16 count
# Energy request,32 bytes. Separate outputs/input.
.equ PE_ENERGY, 0                #int32 output
.equ PE_SHIFT, 8                 #int32 output
.equ PE_IN, 16                   #immutable int16 samples
.equ PE_N, 24                    #0..480 samples
.equ PE_IN_CAP, 28               #int16 count
