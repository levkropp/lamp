# Complete normal Opus packet dispatch, up to120ms and48 frames.
# Uses the initialized26880-byte mode state and118944-byte workspace.
# Request56 bytes. Buffers separate and caller-owned; one decode owner.
.equ PK_STATE, 0
.equ PK_DATA, 8                   #TOC-prefixed packet,NULL only for loss
.equ PK_PCM, 16                   #interleaved float output
.equ PK_WORK, 24
.equ PK_LEN, 32                   #0..4MiB (Ogg packet resource limit)
.equ PK_COUNT, 36                 #sample limit0=automatic,up to120ms
.equ PK_FEC, 40                   #0/1
.equ PK_STATE_CAP, 44             #bytes>=26880
.equ PK_WORK_CAP, 48              #bytes>=118944
.equ PK_PCM_CAP, 52               #float elements
