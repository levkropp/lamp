# Original Windows output mode/rate controls. Included by ui.s. MIT.
# Desired UI choices are captured only after the old worker has joined.
# The playback owner applies them and resolves the device rate off the UI.
.equ ID_SHARED_MODE, 500
.equ ID_EXCLUSIVE_MODE, 501
.equ ID_OUTPUT_RATE, 520
.equ UI_OUTPUT_RATES, 15
.data
ui_output_exclusive: .long 0
ui_output_rate: .long 0             # first opened file, -1 device mix rate, or Hz
ui_worker_exclusive: .long 0
ui_worker_rate: .long 0
ui_output_error: .long 0            # 0 generic/file, 1 exclusive, 2 shared output
ui_output_rates: .long 0,-1,8000,11025,12000,16000,22050,24000,32000,44100,48000,88200,96000,176400,192000
ui_menu_output_mode: .short 'O','u','t','p','u','t',' ','m','o','d','e',0
ui_menu_shared_mode: .short 'S','h','a','r','e','d',' ','(','o','t','h','e','r',' ','a','p','p','s',' ','c','a','n',' ','p','l','a','y',')',0
ui_menu_exclusive_mode: .short 'E','x','c','l','u','s','i','v','e',' ','(','r','e','s','e','r','v','e',' ','t','h','i','s',' ','o','u','t','p','u','t',')',0
ui_menu_output_rate: .short 'O','u','t','p','u','t',' ','s','a','m','p','l','e',' ','r','a','t','e',0
ui_menu_first_rate: .short 'F','i','r','s','t',' ','o','p','e','n','e','d',' ','f','i','l','e',0
ui_menu_device_rate: .short 'D','e','v','i','c','e',' ','m','i','x',' ','r','a','t','e',0
ui_exclusive_error_title: .short 'E','x','c','l','u','s','i','v','e',' ','o','u','t','p','u','t',' ','f','a','i','l','e','d',0
ui_exclusive_error_hint: .short 'T','r','y',' ','S','h','a','r','e','d',' ','m','o','d','e',' ','o','r',' ','a','n','o','t','h','e','r',' ','o','u','t','p','u','t',' ','r','a','t','e','.',0
ui_shared_error_title: .short 'A','u','d','i','o',' ','o','u','t','p','u','t',' ','f','a','i','l','e','d',0
ui_shared_error_hint: .short 'C','h','o','o','s','e',' ','a','n','o','t','h','e','r',' ','o','u','t','p','u','t',' ','o','r',' ','t','r','y',' ','a','g','a','i','n','.',0
.bss
ui_output_rate_label: .zero 24*2
.text
LOCALFN ui_output_settings_menu
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    test rbx, rbx
    jz .Lui_output_menu_done
    call CreatePopupMenu
    test rax, rax
    jz .Lui_output_rate_menu
    mov rsi, rax
    mov rcx, rsi
    xor edx, edx
    cmp dword ptr [rip+ui_output_exclusive], 0
    jne .Lui_output_menu_shared
    mov edx, 8
.Lui_output_menu_shared:
    mov r8d, ID_SHARED_MODE
    lea r9, [rip+ui_menu_shared_mode]
    call AppendMenuW
    mov rcx, rsi
    xor edx, edx
    cmp dword ptr [rip+ui_output_exclusive], 1
    jne .Lui_output_menu_exclusive
    mov edx, 8
.Lui_output_menu_exclusive:
    mov r8d, ID_EXCLUSIVE_MODE
    lea r9, [rip+ui_menu_exclusive_mode]
    call AppendMenuW
    mov rcx, rbx
    mov edx, 0x10
    mov r8, rsi
    lea r9, [rip+ui_menu_output_mode]
    call AppendMenuW
    test eax, eax
    jnz .Lui_output_rate_menu
    mov rcx, rsi
    call DestroyMenu
.Lui_output_rate_menu:
    call CreatePopupMenu
    test rax, rax
    jz .Lui_output_menu_done
    mov rdi, rax
    xor r12d, r12d
.Lui_output_rate_item:
    lea rcx, [rip+ui_output_rates]
    mov esi, [rcx+r12*4]
    lea r9, [rip+ui_menu_first_rate]
    test r12d, r12d
    jz .Lui_output_rate_append
    lea r9, [rip+ui_menu_device_rate]
    cmp r12d, 1
    je .Lui_output_rate_append
    mov eax, esi
    lea rcx, [rip+ui_output_rate_label]
    call ui_number
    mov dword ptr [rcx], 0x00480020      # " H"
    mov dword ptr [rcx+4], 'z'
    lea r9, [rip+ui_output_rate_label]
.Lui_output_rate_append:
    xor edx, edx
    cmp esi, [rip+ui_output_rate]
    jne .Lui_output_rate_unchecked
    mov edx, 8
.Lui_output_rate_unchecked:
    mov rcx, rdi
    lea r8d, [r12+ID_OUTPUT_RATE]
    call AppendMenuW
    inc r12d
    cmp r12d, UI_OUTPUT_RATES
    jb .Lui_output_rate_item
    mov rcx, rbx
    mov edx, 0x10
    mov r8, rdi
    lea r9, [rip+ui_menu_output_rate]
    call AppendMenuW
    test eax, eax
    jnz .Lui_output_menu_done
    mov rcx, rdi
    call DestroyMenu
.Lui_output_menu_done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN ui_output_settings_menu

# ECX=command; EAX=1 handled, 0 unrelated. Repeated selections are no-ops.
LOCALFN ui_output_settings_command
    sub rsp, 40
    lea eax, [rcx-ID_SHARED_MODE]
    cmp eax, 1
    ja .Lui_output_command_rate
    cmp eax, [rip+ui_output_exclusive]
    je .Lui_output_command_handled
    mov [rip+ui_output_exclusive], eax
    jmp .Lui_output_command_restart
.Lui_output_command_rate:
    sub ecx, ID_OUTPUT_RATE
    cmp ecx, UI_OUTPUT_RATES
    jae .Lui_output_command_other
    lea rax, [rip+ui_output_rates]
    mov eax, [rax+rcx*4]
    cmp eax, [rip+ui_output_rate]
    je .Lui_output_command_handled
    mov [rip+ui_output_rate], eax
.Lui_output_command_restart:
    call ui_output_restart
.Lui_output_command_handled:
    mov eax, 1
    jmp .Lui_output_command_done
.Lui_output_command_other:
    xor eax, eax
.Lui_output_command_done:
    add rsp, 40
    ret
ENDFN ui_output_settings_command

# Keep an already pending seek/chapter/track/list request. Otherwise reopen
# the heard file/time, preserving pause. An output error can be retried here.
LOCALFN ui_output_restart
    sub rsp, 40
    cmp dword ptr [rip+ui_restart], 0
    jne .Lui_output_restart_done
    cmp qword ptr [rip+ui_thread], 0
    jne .Lui_output_restart_active
    cmp dword ptr [rip+ui_state], 3
    jne .Lui_output_restart_done
    cmp dword ptr [rip+ui_count], 0
    je .Lui_output_restart_done
.Lui_output_restart_active:
    call ui_heard_position
    test eax, eax
    js .Lui_output_restart_done
    cmp eax, [rip+ui_count]
    jae .Lui_output_restart_done
    mov ecx, eax
    call ui_reopen_at
.Lui_output_restart_done:
    add rsp, 40
    ret
ENDFN ui_output_restart

LOCALFN ui_output_capture
    cmp qword ptr [rip+ui_thread], 0
    jne .Lui_output_capture_done
    mov eax, [rip+ui_output_exclusive]
    mov [rip+ui_worker_exclusive], eax
    mov eax, [rip+ui_output_rate]
    mov [rip+ui_worker_rate], eax
.Lui_output_capture_done:
    ret
ENDFN ui_output_capture

# On the decoder-owning worker, before any queue opens. No UI preferences
# are read here; a new command can stage the next launch independently.
LOCALFN ui_output_worker_apply
    sub rsp, 40
    mov eax, [rip+ui_worker_exclusive]
    mov [rip+engine_exclusive], eax
    mov eax, [rip+ui_worker_rate]
    cmp eax, -1
    jne .Lui_output_apply_rate
    call audio_mix_rate
.Lui_output_apply_rate:
    mov [rip+queue_target], eax
    add rsp, 40
    ret
ENDFN ui_output_worker_apply

LOCALFN ui_output_note_error
    mov dword ptr [rip+ui_output_error], 0
    cmp ecx, 3
    jne .Lui_output_note_done
    mov eax, 2
    cmp dword ptr [rip+engine_exclusive], 0
    je .Lui_output_note_store
    mov eax, 1
.Lui_output_note_store:
    mov [rip+ui_output_error], eax
.Lui_output_note_done:
    ret
ENDFN ui_output_note_error

LOCALFN ui_output_error_title
    lea rcx, [rip+ui_error]
    cmp dword ptr [rip+ui_output_error], 0
    je .Lui_output_title_done
    lea rcx, [rip+ui_exclusive_error_title]
    cmp dword ptr [rip+ui_output_error], 1
    je .Lui_output_title_done
    lea rcx, [rip+ui_shared_error_title]
.Lui_output_title_done:
    ret
ENDFN ui_output_error_title

LOCALFN ui_output_error_detail
    lea rcx, [rip+ui_error_detail]
    cmp dword ptr [rip+ui_output_error], 0
    je .Lui_output_detail_done
    lea rcx, [rip+ui_exclusive_error_hint]
    cmp dword ptr [rip+ui_output_error], 1
    je .Lui_output_detail_done
    lea rcx, [rip+ui_shared_error_hint]
.Lui_output_detail_done:
    ret
ENDFN ui_output_error_detail
