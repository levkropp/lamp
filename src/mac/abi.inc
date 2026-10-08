// Shared private-machine preservation for native service/callback adapters.
// Preserve Windows nonvolatile registers, the SIMD machine, and x87 temporaries
// around libSystem. Return in x8 and consume Rhun's private return slot.
.macro WIN_ENTER
    ENTER 448
    stp x0, x1, [sp]
    stp q0, q1, [sp, #32]
    stp q2, q3, [sp, #64]
    stp q4, q5, [sp, #96]
    stp q6, q7, [sp, #128]
    stp q8, q9, [sp, #160]
    stp q10, q11, [sp, #192]
    stp q12, q13, [sp, #224]
    stp q14, q15, [sp, #256]
    stp q16, q17, [sp, #288]
    stp q18, q19, [sp, #320]
    stp q20, q21, [sp, #352]
    stp q22, q23, [sp, #384]
.endm
.macro WIN_LEAVE
    mov x8, x0
    ldp x0, x1, [sp]
    ldp q0, q1, [sp, #32]
    ldp q2, q3, [sp, #64]
    ldp q4, q5, [sp, #96]
    ldp q6, q7, [sp, #128]
    ldp q8, q9, [sp, #160]
    ldp q10, q11, [sp, #192]
    ldp q12, q13, [sp, #224]
    ldp q14, q15, [sp, #256]
    ldp q16, q17, [sp, #288]
    ldp q18, q19, [sp, #320]
    ldp q20, q21, [sp, #352]
    ldp q22, q23, [sp, #384]
    LEAVE
    XRET
.endm

