# GUI resume lifecycle. Original assembly, MIT. Only the UI owns this state.
# Capture the heard file/time before replacing a queue or closing. Its paths
# remain alive until the stopped worker has joined and the record is written.
# Navigation, track/output changes and natural completion do not save a stop.
.data
ui_resume_enabled: .long 0
ui_resume_pending: .long 0
ui_resume_index: .long -1
.p2align 3
ui_resume_ms: .quad 0
.text
LOCALFN ui_resume_capture
    sub rsp, 40
    cmp dword ptr [rip + ui_resume_enabled], 0
    je .Lui_resume_capture_return
    cmp qword ptr [rip + ui_thread], 0
    je .Lui_resume_capture_return
    cmp qword ptr [rip + ui_heard_count], 0
    je .Lui_resume_capture_return
    call ui_actual_position             # ignores a newer pending seek/list target
    test eax, eax
    js .Lui_resume_capture_return
    cmp eax, [rip + ui_count]
    jae .Lui_resume_capture_return
    mov [rip + ui_resume_index], eax
    mov [rip + ui_resume_ms], rdx
    mov dword ptr [rip + ui_resume_pending], 1
.Lui_resume_capture_return:
    add rsp, 40
    ret
ENDFN ui_resume_capture

LOCALFN ui_resume_commit
    cmp dword ptr [rip + ui_resume_pending], 0
    je .Lui_resume_commit_return
    mov dword ptr [rip + ui_resume_pending], 0
    cmp dword ptr [rip + ui_resume_enabled], 0
    je .Lui_resume_commit_return
    mov rcx, [rip + ui_paths]
    mov edx, [rip + ui_count]
    mov r8d, [rip + ui_resume_index]
    mov r9, [rip + ui_resume_ms]
    jmp win_resume_save
.Lui_resume_commit_return:
    ret
ENDFN ui_resume_commit

# A newly expanded list resumes; replay/next/seek use their explicit targets.
LOCALFN ui_resume_lookup
    sub rsp, 40
    cmp dword ptr [rip + ui_resume_enabled], 0
    je .Lui_resume_lookup_return
    mov rcx, [rip + ui_paths]
    mov edx, [rip + ui_count]
    call win_resume_lookup
    test eax, eax
    jz .Lui_resume_lookup_return
    mov [rip + ui_start_index], ecx
    mov [rip + ui_start_ms], rdx
.Lui_resume_lookup_return:
    add rsp, 40
    ret
ENDFN ui_resume_lookup

LOCALFN ui_resume_forget
    cmp dword ptr [rip + ui_resume_enabled], 0
    je .Lui_resume_forget_return
    mov rcx, [rip + ui_paths]
    mov edx, [rip + ui_count]
    mov r8d, -1
    xor r9d, r9d
    jmp win_resume_save
.Lui_resume_forget_return:
    ret
ENDFN ui_resume_forget

LOCALFN ui_resume_toggle
    sub rsp, 40
    xor dword ptr [rip + ui_resume_enabled], 1
    mov dword ptr [rip + ui_resume_pending], 0
    mov ecx, [rip + ui_resume_enabled]
    call win_resume_preference
    add rsp, 40
    ret
ENDFN ui_resume_toggle
