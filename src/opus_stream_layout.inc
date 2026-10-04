; Complete normal Opus packet dispatch, up to120ms and48 frames.
; Uses the initialized26880-byte mode state and118944-byte workspace.
; Request56 bytes. Buffers separate and caller-owned; one decode owner.
PK_STATE EQU 0
PK_DATA EQU 8                   ;TOC-prefixed packet,NULL only for loss
PK_PCM EQU 16                   ;interleaved float output
PK_WORK EQU 24
PK_LEN EQU 32                   ;0..4MiB (Ogg packet resource limit)
PK_COUNT EQU 36                 ;sample limit0=automatic,up to120ms
PK_FEC EQU 40                   ;0/1
PK_STATE_CAP EQU 44             ;bytes>=26880
PK_WORK_CAP EQU 48              ;bytes>=118944
PK_PCM_CAP EQU 52               ;float elements
