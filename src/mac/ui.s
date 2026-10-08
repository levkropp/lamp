// LAMP's AppKit desktop shell, written in native ARM64 assembly.
// Selectors/classes use Objective-C runtime services directly, like Rhun.
.include "mac.inc"
.macro SEL reg, name
    ADR \reg, sel_\name
    ldr \reg, [\reg]
.endm
.macro CLS reg, name
    ADR \reg, cls_\name
    ldr \reg, [\reg]
.endm
.macro MSG name
    SEL x1, \name
    bl _objc_msgSend
.endm
.macro LOAD reg, name
    ADR x16, \name
    ldr \reg, [x16]
.endm
.macro SAVE reg, name
    ADR x16, \name
    str \reg, [x16]
.endm
.macro STRING name
    CLS x0, NSString
    ADR x2, \name
    MSG stringWithUTF8String_
.endm
.macro METHOD selector, imp, encoding=type_action
    mov x0, x19
    SEL x1, \selector
    ADR x2, \imp
    ADR x3, \encoding
    bl _class_addMethod
.endm

FN _main
    ENTER
    mov x23, x0
    mov x24, x1
    bl _objc_autoreleasePoolPush
    mov x25, x0
    bl _lamp_init
    cbz w0, ui_failed
    bl _lamp_audio_init
    CLS x0, NSApplication
    MSG sharedApplication
    SAVE x0, app
    mov x2, #0
    MSG setActivationPolicy_
    bl make_classes
    LOAD x0, delegate_class
    MSG new
    SAVE x0, delegate
    mov x2, x0
    LOAD x0, app
    MSG setDelegate_
    bl make_menu
    CLS x0, NSWindow
    MSG alloc
    fmov d0, xzr
    fmov d1, xzr
    LOAD d2, width
    LOAD d3, height
    mov x2, #15
    mov x3, #2
    mov x4, #0
    MSG initWithContentRect_styleMask_backing_defer_
    SAVE x0, window
    mov x19, x0
    mov x2, #0
    MSG setReleasedWhenClosed_
    STRING title
    mov x2, x0
    mov x0, x19
    MSG setTitle_
    mov x0, x19
    LOAD d0, min_width
    LOAD d1, min_height
    MSG setContentMinSize_
    mov x0, x19
    LOAD x2, delegate
    MSG setDelegate_
    CLS x0, NSAppearance
    STRING dark_aqua
    mov x2, x0
    CLS x0, NSAppearance
    MSG appearanceNamed_
    mov x2, x0
    mov x0, x19
    MSG setAppearance_
    LOAD x0, view_class
    MSG alloc
    fmov d0, xzr
    fmov d1, xzr
    LOAD d2, width
    LOAD d3, height
    MSG initWithFrame_
    SAVE x0, view
    mov x2, #18 // width/height sizable
    MSG setAutoresizingMask_
    LOAD x2, view
    mov x0, x19
    MSG setContentView_
    bl make_controls
    STRING pasteboard_type
    mov x2, x0
    CLS x0, NSArray
    MSG arrayWithObject_
    mov x2, x0
    LOAD x0, view
    MSG registerForDraggedTypes_
    LOAD x0, window
    MSG center
    LOAD x0, window
    mov x2, #0
    MSG makeKeyAndOrderFront_
    LOAD x0, window
    LOAD x2, view
    MSG makeFirstResponder_
    LOAD x0, app
    MSG finishLaunching
    LOAD x0, app
    mov x2, #1
    MSG activateIgnoringOtherApps_
    CLS x0, NSTimer
    LOAD d0, interval
    LOAD x2, delegate
    SEL x3, tick_
    mov x4, #0
    mov x5, #1
    MSG scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_
    SAVE x0, timer
    cmp x23, #2
    b.lo 2f
    ldr x0, [x24, #8]
    ADR x1, smoke_option
    bl _strcmp
    cbnz w0, 1f
    ADR x9, smoke_ticks
    mov w10, #15
    str w10, [x9]
    cmp x23, #3
    b.lo 2f
    ldr x2, [x24, #16]
    b 3f
1:  ldr x2, [x24, #8]
3:  CLS x0, NSString
    MSG stringWithUTF8String_
    bl play_path
    cbnz w0, 2f
    ADR x9, smoke_ticks
    ldr w9, [x9]
    cbz w9, 2f
    bl _lamp_stop
    mov w0, #1
    bl _exit // Smoke checks must report failed native audio startup.
2:  LOAD x0, app
    MSG run
    bl _lamp_stop
    mov x0, x25
    bl _objc_autoreleasePoolPop
    mov w0, #0
    b 4f
ui_failed:
    mov w0, #1
4:  LEAVE
    ret

make_classes:
    ENTER
    CLS x0, NSObject
    ADR x1, delegate_name
    mov x2, #0
    bl _objc_allocateClassPair
    mov x19, x0
    SAVE x0, delegate_class
    METHOD open_, on_open
    METHOD pause_, on_pause
    METHOD stop_, on_stop
    METHOD seek_, on_seek
    METHOD volume_, on_volume
    METHOD tick_, on_tick
    METHOD windowWillClose_, on_quit
    METHOD applicationWillTerminate_, on_terminate
    METHOD applicationShouldTerminateAfterLastWindowClosed_, return_yes, type_bool
    METHOD application_openFile_, on_file, type_open_file
    METHOD application_openFiles_, on_files, type_open_files
    mov x0, x19
    bl _objc_registerClassPair
    CLS x0, NSView
    ADR x1, view_name
    mov x2, #0
    bl _objc_allocateClassPair
    mov x19, x0
    SAVE x0, view_class
    METHOD acceptsFirstResponder, return_yes, type_bool0
    METHOD keyDown_, on_key
    METHOD draggingEntered_, drag_enter, type_drag
    METHOD performDragOperation_, on_drop, type_bool
    mov x0, x19
    bl _objc_registerClassPair
    LEAVE
    ret

// Create a text field at rect d0-d3, UTF-8 title x0; return label x0.
label:
    ENTER 48
    mov x19, x0
    stp d0, d1, [sp]
    stp d2, d3, [sp, #16]
    CLS x0, NSTextField
    MSG alloc
    ldp d0, d1, [sp]
    ldp d2, d3, [sp, #16]
    MSG initWithFrame_
    mov x20, x0
    mov x2, #0
    MSG setEditable_
    mov x0, x20
    mov x2, #0
    MSG setSelectable_
    mov x0, x20
    mov x2, #0
    MSG setBezeled_
    mov x0, x20
    mov x2, #0
    MSG setDrawsBackground_
    mov x0, x20
    mov x2, #34 // bottom-anchored: top margin and width sizable
    MSG setAutoresizingMask_
    CLS x0, NSString
    mov x2, x19
    MSG stringWithUTF8String_
    mov x2, x0
    mov x0, x20
    MSG setStringValue_
    LOAD x0, view
    mov x2, x20
    MSG addSubview_
    mov x0, x20
    LEAVE
    ret

top_label:
    ENTER
    bl label
    mov x19, x0
    mov x2, #10 // top-anchored: bottom margin and width sizable
    MSG setAutoresizingMask_
    mov x0, x19
    LEAVE
    ret

// Button rect d0-d3, UTF-8 x0, action selector x1.
button:
    ENTER 48
    mov x19, x0
    mov x21, x1
    stp d0, d1, [sp]
    stp d2, d3, [sp, #16]
    CLS x0, NSButton
    MSG alloc
    ldp d0, d1, [sp]
    ldp d2, d3, [sp, #16]
    MSG initWithFrame_
    mov x20, x0
    mov x2, #1
    MSG setBezelStyle_
    CLS x0, NSString
    mov x2, x19
    MSG stringWithUTF8String_
    mov x2, x0
    mov x0, x20
    MSG setTitle_
    mov x0, x20
    LOAD x2, delegate
    MSG setTarget_
    mov x0, x20
    mov x2, x21
    MSG setAction_
    LOAD x0, view
    mov x2, x20
    MSG addSubview_
    mov x0, x20
    LEAVE
    ret

// Slider rect d0-d3, action selector x0, starting value d4.
slider:
    ENTER 48
    mov x21, x0
    stp d0, d1, [sp]
    stp d2, d3, [sp, #16]
    str d4, [sp, #32]
    CLS x0, NSSlider
    MSG alloc
    ldp d0, d1, [sp]
    ldp d2, d3, [sp, #16]
    MSG initWithFrame_
    mov x20, x0
    fmov d0, xzr
    MSG setMinValue_
    mov x0, x20
    fmov d0, #1.0
    MSG setMaxValue_
    mov x0, x20
    ldr d0, [sp, #32]
    MSG setDoubleValue_
    mov x0, x20
    mov x2, #0
    MSG setContinuous_
    mov x0, x20
    LOAD x2, delegate
    MSG setTarget_
    mov x0, x20
    mov x2, x21
    MSG setAction_
    LOAD x0, view
    mov x2, x20
    MSG addSubview_
    mov x0, x20
    LEAVE
    ret

.macro RECT x, y, w, h
    mov x9, #\x
    ucvtf d0, x9
    mov x9, #\y
    ucvtf d1, x9
    mov x9, #\w
    ucvtf d2, x9
    mov x9, #\h
    ucvtf d3, x9
.endm
make_controls:
    ENTER
    RECT 28, 235, 564, 34
    ADR x0, title
    bl top_label
    mov x19, x0
    CLS x0, NSFont
    fmov d0, #26.0
    MSG boldSystemFontOfSize_
    mov x2, x0
    mov x0, x19
    MSG setFont_
    RECT 28, 200, 564, 24
    ADR x0, prompt
    bl top_label
    SAVE x0, filename_label
    RECT 28, 165, 564, 24
    ADR x0, ready_text
    bl top_label
    SAVE x0, status_label
    RECT 24, 120, 572, 24
    SEL x0, seek_
    fmov d4, xzr
    bl slider
    SAVE x0, seek_slider
    mov x2, #2
    MSG setAutoresizingMask_
    STRING timeline_accessibility
    mov x2, x0
    LOAD x0, seek_slider
    MSG setAccessibilityLabel_
    RECT 28, 94, 564, 24
    ADR x0, empty_time
    bl label
    SAVE x0, time_label
    RECT 24, 34, 100, 36
    ADR x0, open_text
    SEL x1, open_
    bl button
    RECT 134, 34, 110, 36
    ADR x0, play_text
    SEL x1, pause_
    bl button
    SAVE x0, play_button
    RECT 254, 34, 90, 36
    ADR x0, stop_text
    SEL x1, stop_
    bl button
    RECT 370, 62, 220, 22
    ADR x0, volume_text
    bl label
    RECT 366, 34, 228, 28
    SEL x0, volume_
    LOAD d4, initial_volume
    bl slider
    SAVE x0, volume_slider
    STRING volume_text
    mov x2, x0
    LOAD x0, volume_slider
    MSG setAccessibilityLabel_
    LEAVE
    ret

make_menu:
    ENTER
    CLS x0, NSMenu
    MSG new
    mov x19, x0
    CLS x0, NSMenuItem
    MSG new
    mov x20, x0
    mov x2, x0
    mov x0, x19
    MSG addItem_
    CLS x0, NSMenu
    MSG new
    mov x21, x0
    mov x2, x0
    mov x0, x20
    MSG setSubmenu_
    STRING quit_text
    mov x20, x0
    STRING q_key
    mov x22, x0
    CLS x0, NSMenuItem
    MSG alloc
    mov x2, x20
    SEL x3, terminate_
    mov x4, x22
    MSG initWithTitle_action_keyEquivalent_
    mov x2, x0
    mov x0, x21
    MSG addItem_
    STRING open_text
    mov x20, x0
    STRING o_key
    mov x22, x0
    CLS x0, NSMenuItem
    MSG alloc
    mov x2, x20
    SEL x3, open_
    mov x4, x22
    MSG initWithTitle_action_keyEquivalent_
    mov x20, x0
    LOAD x2, delegate
    MSG setTarget_
    mov x2, x20
    mov x0, x21
    MSG addItem_
    LOAD x0, app
    mov x2, x19
    MSG setMainMenu_
    LEAVE
    ret

play_path:
    ENTER
    MSG copy // Retain the incoming path before releasing a possibly equal one.
    mov x19, x0
    LOAD x0, current_file
    cbz x0, 1f
    MSG release
1:  mov x0, x19
    SAVE x0, current_file
    MSG UTF8String
    bl _lamp_play
    mov w20, w0
    LOAD x0, current_file
    MSG lastPathComponent
    mov x19, x0
    mov x2, x19
    LOAD x0, filename_label
    MSG setStringValue_
    mov x2, x19
    LOAD x0, window
    MSG setTitle_
    bl on_tick
    mov w0, w20
    LEAVE
    ret

on_open:
    ENTER
    CLS x0, NSOpenPanel
    MSG openPanel
    mov x19, x0
    mov x2, #1
    MSG setCanChooseFiles_
    mov x0, x19
    mov x2, #0
    MSG setCanChooseDirectories_
    mov x0, x19
    mov x2, #0
    MSG setAllowsMultipleSelection_
    mov x0, x19
    MSG runModal
    cmp x0, #1
    b.ne 1f
    mov x0, x19
    MSG URL
    MSG path
    bl play_path
1:  LEAVE
    ret

on_pause:
    ENTER
    ADR x9, _lamp_state
    ldr w9, [x9]
    cmp w9, #1
    b.eq 1f
    cmp w9, #2
    b.eq 1f
    LOAD x0, current_file
    cbz x0, 2f
    MSG UTF8String
    bl _lamp_play
    b 2f
1:  bl _lamp_pause
2:  bl on_tick
    LEAVE
    ret
on_stop:
    ENTER
    bl _lamp_stop
    bl on_tick
    LEAVE
    ret
on_seek:
    ENTER
    mov x0, x2
    MSG doubleValue
    ADR x9, _lamp_frames
    ldr x9, [x9]
    ucvtf d1, x9
    fmul d0, d0, d1
    fcvtzu x0, d0
    bl _lamp_seek
    bl on_tick
    LEAVE
    ret
on_volume:
    ENTER
    mov x0, x2
    MSG doubleValue
    fcvt s0, d0
    bl _lamp_set_volume
    LEAVE
    ret
on_file:
    ENTER
    mov x0, x3
    bl play_path
    LEAVE
    ret
on_files:
    ENTER
    mov w20, #0
    mov x0, x3
    MSG firstObject
    cbz x0, 1f
    bl play_path
    mov w20, w0
1:  LOAD x0, app
    cmp w20, #0
    cset w2, eq
    lsl w2, w2, #1 // NSApplicationDelegateReplyFailure / Success
    MSG replyToOpenOrPrint_
    LEAVE
    ret
on_terminate:
    ENTER
    bl _lamp_stop
    LEAVE
    ret
on_quit:
    ENTER
    bl _lamp_stop
    LOAD x0, app
    mov x2, #0
    MSG terminate_
    LEAVE
    ret
return_yes:
    mov w0, #1
    ret
drag_enter:
    mov w0, #1
    ret
on_drop:
    ENTER
    mov x0, x2
    MSG draggingPasteboard
    mov x19, x0
    STRING pasteboard_type
    mov x2, x0
    mov x0, x19
    MSG propertyListForType_
    MSG firstObject
    cbz x0, 1f
    bl play_path
1:  LEAVE
    ret

on_key:
    ENTER
    mov x0, x2
    MSG keyCode
    cmp w0, #49
    b.eq 1f
    cmp w0, #31
    b.eq 2f
    cmp w0, #12
    b.eq 3f
    cmp w0, #123
    b.eq 4f
    cmp w0, #124
    b.eq 5f
    cmp w0, #115
    b.eq 6f
    cmp w0, #126
    b.eq 7f
    cmp w0, #125
    b.eq 8f
    cmp w0, #3
    b.eq 9f
    cmp w0, #46 // M
    b.eq 13f
    cmp w0, #53 // Escape
    b.eq 14f
    b 10f
1:  bl on_pause
    b 10f
2:  bl on_open
    b 10f
3:  bl on_quit
    b 10f
4:  mov x20, #-5
    b 11f
5:  mov x20, #5
11: ADR x9, _lamp_rate
    ldr w9, [x9]
    ADR x10, _lamp_position
    ldr x10, [x10]
    madd x0, x9, x20, x10
    cmp x0, #0
    csel x0, x0, xzr, ge
    ADR x9, _lamp_frames
    ldr x9, [x9]
    cmp x0, x9
    csel x0, x0, x9, lo
    bl _lamp_seek
    b 10f
6:  mov x0, #0
    bl _lamp_seek
    b 10f
7:  LOAD s1, volume_step
    b 12f
8:  LOAD s1, volume_down
12: ADR x9, _lamp_volume
    ldr s0, [x9]
    fadd s0, s0, s1
    bl _lamp_set_volume
    b 10f
9:  LOAD x0, window
    mov x2, #0
    MSG toggleFullScreen_
    b 10f
13: ADR x9, _lamp_volume
    ldr s0, [x9]
    fcmp s0, #0.0
    b.eq 15f
    fmov s0, wzr
    b 16f
15: fmov s0, #1.0
16: bl _lamp_set_volume
    b 10f
14: LOAD x0, window
    MSG styleMask
    tbz x0, #14, 10f // NSWindowStyleMaskFullScreen
    LOAD x0, window
    mov x2, #0
    MSG toggleFullScreen_
10: bl on_tick
    LEAVE
    ret

on_tick:
    ENTER 128
    bl _lamp_tick
    mov w19, w0
    // Decoding may already be in a later file. Name the retained path of the
    // entry actually heard, just as the timeline uses its cached duration.
    ADR x9, _lamp_paths
    ldr x9, [x9]
    cbz x9, 9f
    ADR x10, _lamp_index
    ldr w10, [x10]
    tbnz w10, #31, 9f
    ldr x2, [x9, x10, lsl #3]
    CLS x0, NSString
    MSG stringWithUTF8String_
    MSG lastPathComponent
    mov x20, x0
    mov x2, x20
    LOAD x0, filename_label
    MSG setStringValue_
    mov x2, x20
    LOAD x0, window
    MSG setTitle_
9:
    ADR x9, smoke_ticks
    ldr w10, [x9]
    cbz w10, 1f
    sub w10, w10, #1
    str w10, [x9]
    cbnz w10, 1f
    bl on_quit
1:  ADR x9, _lamp_position
    ldr x20, [x9]
    ADR x9, _lamp_frames
    ldr x21, [x9]
    cbz x21, 2f
    ucvtf d0, x20
    ucvtf d1, x21
    fdiv d0, d0, d1
    b 3f
2:  fmov d0, xzr
3:  LOAD x0, seek_slider
    MSG setDoubleValue_
    ADR x9, _lamp_volume
    ldr s0, [x9]
    fcvt d0, s0
    LOAD x0, volume_slider
    MSG setDoubleValue_
    ADR x9, _lamp_rate
    ldr w9, [x9]
    cbz w9, 4f
    udiv x20, x20, x9
    udiv x21, x21, x9
4:  mov x9, #60
    udiv x10, x20, x9
    msub x11, x10, x9, x20
    udiv x12, x21, x9
    msub x13, x12, x9, x21
    stp x10, x11, [sp]
    stp x12, x13, [sp, #16]
    add x0, sp, #32
    mov x1, #80
    ADR x2, time_format
    bl _snprintf
    add x2, sp, #32
    CLS x0, NSString
    MSG stringWithUTF8String_
    mov x2, x0
    LOAD x0, time_label
    MSG setStringValue_
    ADR x9, status_strings
    ldr x2, [x9, x19, lsl #3]
    CLS x0, NSString
    MSG stringWithUTF8String_
    mov x2, x0
    LOAD x0, status_label
    MSG setStringValue_
    cmp w19, #1
    b.ne 5f
    STRING pause_text
    b 6f
5:  STRING play_text
6:  mov x2, x0
    LOAD x0, play_button
    MSG setTitle_
    LEAVE
    ret

.section __TEXT,__cstring,cstring_literals
delegate_name: .asciz "LAMPDelegate"
view_name: .asciz "LAMPView"
type_action: .asciz "v@:@"
type_bool: .asciz "B@:@"
type_bool0: .asciz "B@:"
type_drag: .asciz "Q@:@"
type_open_file: .asciz "B@:@@"
type_open_files: .asciz "v@:@@"
title: .asciz "LAMP"
prompt: .asciz "Drop an audio file here, or choose Open."
ready_text: .asciz "Ready"
playing_text: .asciz "Playing"
paused_text: .asciz "Paused"
finished_text: .asciz "Finished"
error_text: .asciz "Unable to play this file. Choose a supported audio file."
open_text: .asciz "Open…"
play_text: .asciz "Play"
pause_text: .asciz "Pause"
stop_text: .asciz "Stop"
volume_text: .asciz "Volume"
timeline_accessibility: .asciz "Playback position"
empty_time: .asciz "0:00 / 0:00"
time_format: .asciz "%llu:%02llu / %llu:%02llu"
quit_text: .asciz "Quit LAMP"
q_key: .asciz "q"
o_key: .asciz "o"
dark_aqua: .asciz "NSAppearanceNameDarkAqua"
pasteboard_type: .asciz "NSFilenamesPboardType"
smoke_option: .asciz "--ui-smoke"
.data
.p2align 3
width: .double 620
height: .double 300
min_width: .double 620
min_height: .double 300
interval: .double 0.2
initial_volume: .double 0.7
volume_step: .float 0.05
volume_down: .float -0.05
status_strings: .quad ready_text, playing_text, paused_text, finished_text, error_text
app: .quad 0
window: .quad 0
view: .quad 0
delegate: .quad 0
delegate_class: .quad 0
view_class: .quad 0
filename_label: .quad 0
status_label: .quad 0
time_label: .quad 0
play_button: .quad 0
seek_slider: .quad 0
volume_slider: .quad 0
current_file: .quad 0
timer: .quad 0
smoke_ticks: .long 0

.section __TEXT,__objc_methname,cstring_literals
name_URL: .asciz "URL"
name_UTF8String: .asciz "UTF8String"
name_acceptsFirstResponder: .asciz "acceptsFirstResponder"
name_activateIgnoringOtherApps_: .asciz "activateIgnoringOtherApps:"
name_addItem_: .asciz "addItem:"
name_addSubview_: .asciz "addSubview:"
name_alloc: .asciz "alloc"
name_appearanceNamed_: .asciz "appearanceNamed:"
name_applicationShouldTerminateAfterLastWindowClosed_: .asciz "applicationShouldTerminateAfterLastWindowClosed:"
name_applicationWillTerminate_: .asciz "applicationWillTerminate:"
name_application_openFile_: .asciz "application:openFile:"
name_application_openFiles_: .asciz "application:openFiles:"
name_arrayWithObject_: .asciz "arrayWithObject:"
name_boldSystemFontOfSize_: .asciz "boldSystemFontOfSize:"
name_center: .asciz "center"
name_copy: .asciz "copy"
name_doubleValue: .asciz "doubleValue"
name_draggingEntered_: .asciz "draggingEntered:"
name_draggingPasteboard: .asciz "draggingPasteboard"
name_finishLaunching: .asciz "finishLaunching"
name_firstObject: .asciz "firstObject"
name_initWithContentRect_styleMask_backing_defer_: .asciz "initWithContentRect:styleMask:backing:defer:"
name_initWithFrame_: .asciz "initWithFrame:"
name_initWithTitle_action_keyEquivalent_: .asciz "initWithTitle:action:keyEquivalent:"
name_keyCode: .asciz "keyCode"
name_keyDown_: .asciz "keyDown:"
name_styleMask: .asciz "styleMask"
name_lastPathComponent: .asciz "lastPathComponent"
name_makeFirstResponder_: .asciz "makeFirstResponder:"
name_makeKeyAndOrderFront_: .asciz "makeKeyAndOrderFront:"
name_new: .asciz "new"
name_openPanel: .asciz "openPanel"
name_open_: .asciz "open:"
name_path: .asciz "path"
name_pause_: .asciz "pause:"
name_performDragOperation_: .asciz "performDragOperation:"
name_propertyListForType_: .asciz "propertyListForType:"
name_registerForDraggedTypes_: .asciz "registerForDraggedTypes:"
name_release: .asciz "release"
name_replyToOpenOrPrint_: .asciz "replyToOpenOrPrint:"
name_run: .asciz "run"
name_runModal: .asciz "runModal"
name_scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_: .asciz "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
name_seek_: .asciz "seek:"
name_setAccessibilityLabel_: .asciz "setAccessibilityLabel:"
name_setAction_: .asciz "setAction:"
name_setActivationPolicy_: .asciz "setActivationPolicy:"
name_setAllowsMultipleSelection_: .asciz "setAllowsMultipleSelection:"
name_setAppearance_: .asciz "setAppearance:"
name_setAutoresizingMask_: .asciz "setAutoresizingMask:"
name_setBezelStyle_: .asciz "setBezelStyle:"
name_setBezeled_: .asciz "setBezeled:"
name_setCanChooseDirectories_: .asciz "setCanChooseDirectories:"
name_setCanChooseFiles_: .asciz "setCanChooseFiles:"
name_setContentMinSize_: .asciz "setContentMinSize:"
name_setContentView_: .asciz "setContentView:"
name_setContinuous_: .asciz "setContinuous:"
name_setDelegate_: .asciz "setDelegate:"
name_setDoubleValue_: .asciz "setDoubleValue:"
name_setDrawsBackground_: .asciz "setDrawsBackground:"
name_setEditable_: .asciz "setEditable:"
name_setFont_: .asciz "setFont:"
name_setMainMenu_: .asciz "setMainMenu:"
name_setMaxValue_: .asciz "setMaxValue:"
name_setMinValue_: .asciz "setMinValue:"
name_setReleasedWhenClosed_: .asciz "setReleasedWhenClosed:"
name_setSelectable_: .asciz "setSelectable:"
name_setStringValue_: .asciz "setStringValue:"
name_setSubmenu_: .asciz "setSubmenu:"
name_setTarget_: .asciz "setTarget:"
name_setTitle_: .asciz "setTitle:"
name_sharedApplication: .asciz "sharedApplication"
name_stop_: .asciz "stop:"
name_stringWithUTF8String_: .asciz "stringWithUTF8String:"
name_terminate_: .asciz "terminate:"
name_tick_: .asciz "tick:"
name_toggleFullScreen_: .asciz "toggleFullScreen:"
name_volume_: .asciz "volume:"
name_windowWillClose_: .asciz "windowWillClose:"

.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
.p2align 3
sel_URL: .quad name_URL
sel_UTF8String: .quad name_UTF8String
sel_acceptsFirstResponder: .quad name_acceptsFirstResponder
sel_activateIgnoringOtherApps_: .quad name_activateIgnoringOtherApps_
sel_addItem_: .quad name_addItem_
sel_addSubview_: .quad name_addSubview_
sel_alloc: .quad name_alloc
sel_appearanceNamed_: .quad name_appearanceNamed_
sel_applicationShouldTerminateAfterLastWindowClosed_: .quad name_applicationShouldTerminateAfterLastWindowClosed_
sel_applicationWillTerminate_: .quad name_applicationWillTerminate_
sel_application_openFile_: .quad name_application_openFile_
sel_application_openFiles_: .quad name_application_openFiles_
sel_arrayWithObject_: .quad name_arrayWithObject_
sel_boldSystemFontOfSize_: .quad name_boldSystemFontOfSize_
sel_center: .quad name_center
sel_copy: .quad name_copy
sel_doubleValue: .quad name_doubleValue
sel_draggingEntered_: .quad name_draggingEntered_
sel_draggingPasteboard: .quad name_draggingPasteboard
sel_finishLaunching: .quad name_finishLaunching
sel_firstObject: .quad name_firstObject
sel_initWithContentRect_styleMask_backing_defer_: .quad name_initWithContentRect_styleMask_backing_defer_
sel_initWithFrame_: .quad name_initWithFrame_
sel_initWithTitle_action_keyEquivalent_: .quad name_initWithTitle_action_keyEquivalent_
sel_keyCode: .quad name_keyCode
sel_keyDown_: .quad name_keyDown_
sel_styleMask: .quad name_styleMask
sel_lastPathComponent: .quad name_lastPathComponent
sel_makeFirstResponder_: .quad name_makeFirstResponder_
sel_makeKeyAndOrderFront_: .quad name_makeKeyAndOrderFront_
sel_new: .quad name_new
sel_openPanel: .quad name_openPanel
sel_open_: .quad name_open_
sel_path: .quad name_path
sel_pause_: .quad name_pause_
sel_performDragOperation_: .quad name_performDragOperation_
sel_propertyListForType_: .quad name_propertyListForType_
sel_registerForDraggedTypes_: .quad name_registerForDraggedTypes_
sel_release: .quad name_release
sel_replyToOpenOrPrint_: .quad name_replyToOpenOrPrint_
sel_run: .quad name_run
sel_runModal: .quad name_runModal
sel_scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_: .quad name_scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_
sel_seek_: .quad name_seek_
sel_setAccessibilityLabel_: .quad name_setAccessibilityLabel_
sel_setAction_: .quad name_setAction_
sel_setActivationPolicy_: .quad name_setActivationPolicy_
sel_setAllowsMultipleSelection_: .quad name_setAllowsMultipleSelection_
sel_setAppearance_: .quad name_setAppearance_
sel_setAutoresizingMask_: .quad name_setAutoresizingMask_
sel_setBezelStyle_: .quad name_setBezelStyle_
sel_setBezeled_: .quad name_setBezeled_
sel_setCanChooseDirectories_: .quad name_setCanChooseDirectories_
sel_setCanChooseFiles_: .quad name_setCanChooseFiles_
sel_setContentMinSize_: .quad name_setContentMinSize_
sel_setContentView_: .quad name_setContentView_
sel_setContinuous_: .quad name_setContinuous_
sel_setDelegate_: .quad name_setDelegate_
sel_setDoubleValue_: .quad name_setDoubleValue_
sel_setDrawsBackground_: .quad name_setDrawsBackground_
sel_setEditable_: .quad name_setEditable_
sel_setFont_: .quad name_setFont_
sel_setMainMenu_: .quad name_setMainMenu_
sel_setMaxValue_: .quad name_setMaxValue_
sel_setMinValue_: .quad name_setMinValue_
sel_setReleasedWhenClosed_: .quad name_setReleasedWhenClosed_
sel_setSelectable_: .quad name_setSelectable_
sel_setStringValue_: .quad name_setStringValue_
sel_setSubmenu_: .quad name_setSubmenu_
sel_setTarget_: .quad name_setTarget_
sel_setTitle_: .quad name_setTitle_
sel_sharedApplication: .quad name_sharedApplication
sel_stop_: .quad name_stop_
sel_stringWithUTF8String_: .quad name_stringWithUTF8String_
sel_terminate_: .quad name_terminate_
sel_tick_: .quad name_tick_
sel_toggleFullScreen_: .quad name_toggleFullScreen_
sel_volume_: .quad name_volume_
sel_windowWillClose_: .quad name_windowWillClose_

.section __DATA,__objc_classrefs,regular,no_dead_strip
.p2align 3
cls_NSAppearance: .quad _OBJC_CLASS_$_NSAppearance
cls_NSApplication: .quad _OBJC_CLASS_$_NSApplication
cls_NSArray: .quad _OBJC_CLASS_$_NSArray
cls_NSButton: .quad _OBJC_CLASS_$_NSButton
cls_NSFont: .quad _OBJC_CLASS_$_NSFont
cls_NSMenu: .quad _OBJC_CLASS_$_NSMenu
cls_NSMenuItem: .quad _OBJC_CLASS_$_NSMenuItem
cls_NSObject: .quad _OBJC_CLASS_$_NSObject
cls_NSOpenPanel: .quad _OBJC_CLASS_$_NSOpenPanel
cls_NSSlider: .quad _OBJC_CLASS_$_NSSlider
cls_NSString: .quad _OBJC_CLASS_$_NSString
cls_NSTextField: .quad _OBJC_CLASS_$_NSTextField
cls_NSTimer: .quad _OBJC_CLASS_$_NSTimer
cls_NSView: .quad _OBJC_CLASS_$_NSView
cls_NSWindow: .quad _OBJC_CLASS_$_NSWindow
.section __DATA,__objc_imageinfo,regular,no_dead_strip
    .long 0, 64
