# Original bounded H.264 Annex B I/P frontend ABI; Microsoft x64 convention.
.equ HP_BYTES, 16384
.equ HP_DATA, 0
.equ HP_END, 8
.equ HP_CURSOR, 16
.equ HP_BITS_BUFFER, 24
.equ HP_COMMITTED, 32
.equ HP_FRAME_BYTES, 40
.equ HP_SLICES, 44
.equ HP_FRAMES, 48
.equ HP_ERROR, 56
.equ HP_STATE, 60
.equ HP_CANCEL, 64
.equ HP_NALS, 72
.equ HP_BR_PTR, 80
.equ HP_BR_END, 88
.equ HP_BR_BYTE, 96
.equ HP_BR_BITS, 100
.equ HP_BR_ZEROS, 104
.equ HP_NAL_START, 112
.equ HP_NAL_PTR, 120
.equ HP_NAL_BYTES, 128
.equ HP_WIDTH, 136
.equ HP_HEIGHT, 140
.equ HP_VISIBLE_W, 144
.equ HP_VISIBLE_H, 148
.equ HP_LEFT, 152
.equ HP_TOP, 156
.equ HP_SPS_ID, 160
.equ HP_PPS_ID, 164
.equ HP_FRAME_BITS, 168
.equ HP_POC_TYPE, 172
.equ HP_POC_BITS, 176
.equ HP_REFS, 180
.equ HP_DIRECT, 184
.equ HP_LEVEL, 188
.equ HP_QP, 192
.equ HP_QS, 196
.equ HP_CHROMA, 200
.equ HP_CHROMA2, 204
.equ HP_L0, 208
.equ HP_L1, 212
.equ HP_DEBLOCK, 216
.equ HP_CONSTRAINED, 220
.equ HP_SAR_W, 228
.equ HP_SAR_H, 232
.equ HP_FULL_RANGE, 236
.equ HP_PRIMARIES, 240
.equ HP_TRANSFER, 244
.equ HP_COLOR_MATRIX, 248
.equ HP_FIXED_RATE, 252
.equ HP_TIME_TICK, 256
.equ HP_TIME_SCALE, 260
.equ HP_RIGHT, 268
.equ HP_BOTTOM, 272
.equ HP_SPS_BYTES, 280
.equ HP_PPS_BYTES, 284
.equ HP_FRAME_IDR, 288
.equ HP_FRAME_PPS, 292
.equ HP_FRAME_POC, 296
.equ HP_LAST_MB, 300
.equ HP_FRAME_REF, 304
.equ HP_TEMP_MB, 308
.equ HP_TEMP_IDR, 312
.equ HP_TEMP_PPS, 316
.equ HP_TEMP_POC, 320
.equ HP_TEMP_REF, 324
.equ HP_DESC, 328
.equ HP_PICTURE, 384
.equ HP_MATRIX, 1424
.equ HP_SHORTS, 1648
.equ HP_SPS_RAW, 4224
.equ HP_PPS_RAW, 8320
.equ HP_MAX_FRAME, 16777216
.equ HP_FRAME_NUM, 12416
.equ HP_TEMP_NUM, 12420
.equ HP_FRAME_TYPE, 12424
.equ HP_TEMP_TYPE, 12428
.equ HP_FRAME_NAL, 12432
.equ HP_TEMP_NAL, 12436
.equ HP_FRAME_ADAPT, 12440
.equ HP_TEMP_ADAPT, 12444
.equ HP_FRAME_LONG, 12448
.equ HP_TEMP_LONG, 12452
.equ HP_FRAME_MMCO_COUNT, 12456
.equ HP_TEMP_MMCO_COUNT, 12460
.equ HP_DPB_COUNT, 12464
.equ HP_SEEN_IDR, 12468
.equ HP_PREV_NUM, 12472
.equ HP_PREV_REF_NUM, 12476
.equ HP_FRAME_OFFSET, 12480
.equ HP_PREV_POC_MSB, 12488
.equ HP_PREV_POC_LSB, 12496
.equ HP_CURRENT_POC, 12504
.equ HP_CURRENT_SLOT, 12508
.equ HP_CURRENT_LONG, 12512
.equ HP_MAX_LONG, 12516
.equ HP_MMCO5, 12520
.equ HP_TEMP_ACTIVE, 12524
.equ HP_CURRENT_MSB, 12528
.equ HP_LAST_POC, 12536
.equ HP_MMCO_HAS123, 12540
.equ HP_FRAME_MMCO, 12672
.equ HP_TEMP_MMCO, 13440
.equ HP_DPB, 14208       # 16 compact records {surface,frame_num,poc,long_index}; -1 short.
.equ HP_PROFILE, 14464
.equ HP_ENTROPY, 14468
.equ HP_WEIGHTED, 14472
.equ HP_BIPRED, 14476
.equ HP_TRANSFORM8, 14480
.equ HP_SEQ_SCALING, 14484
.equ HP_SPS_MATRIX, 14592   # Preserved224B sequence-level scaling lists.
.equ HP_HOLD_MASK, 14816    # Client-owned output pins; excluded from free slots.
.equ HP_SURFACES, 14820     # 1..32 slot limit; default17 for packet-only callers.
.equ HP_MAX_REORDER, 14824
.equ HP_MAX_BUFFER, 14828
.equ HP_EPOCH, 14832        # IDR/MMCO5 output-order generation, u64.
.equ HP_CONSTRAINTS, 14840
.equ HP_TEMP_ACTIVE1, 14844
.equ HP_RESTRICTION, 14848
.equ HP_FRAME_NOOUTPUT, 14852
.equ HP_TEMP_NOOUTPUT, 14856
.equ HP_OUTPUT_POC, 14860

# Checked syntax readers used by the original SPS/PPS/slice implementation.
.macro HP_BITS n, field, maximum, bad
    mov rcx, rbx
    mov edx, \n
    call hp_bits
    cmp dword ptr [rbx+HP_ERROR], 0
    jne \bad
    cmp eax, \maximum
    ja \bad
    .if \field >= 0
    mov [rbx+\field], eax
    .endif
.endm
.macro HP_UE field, maximum, bad
    mov rcx, rbx
    call hp_ue
    cmp dword ptr [rbx+HP_ERROR], 0
    jne \bad
    cmp eax, \maximum
    ja \bad
    .if \field >= 0
    mov [rbx+\field], eax
    .endif
.endm
.macro HP_SE field, minimum, maximum, bad
    mov rcx, rbx
    call hp_se
    cmp dword ptr [rbx+HP_ERROR], 0
    jne \bad
    cmp eax, \minimum
    jl \bad
    cmp eax, \maximum
    jg \bad
    .if \field >= 0
    mov [rbx+\field], eax
    .endif
.endm
