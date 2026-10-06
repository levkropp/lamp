# Original LOAS/LATM demuxer in x86-64 assembly. MIT, see LICENSE.
# AAC in LATM (ISO/IEC 14496-3, 1.7), framed by LOAS sync words (0x2B7 and
# a 13-bit length), as DVB broadcasts carry it and .loas/.latm files hold
# it. Each frame's AudioMuxElement may carry a StreamMuxConfig (one program
# and layer, frame length type 0) whose AudioSpecificConfig describes the
# stream; its payload follows a byte-length count at any bit. Payloads are
# copied to whole bytes as packets of the track layer, which decodes them
# with the AAC decoder; the configuration, also realigned, opens it.
# Parsing follows FFmpeg's LATM decoder: a frame whose payload lengths
# disagree with its LOAS length is skipped. Frames before the first
# configuration use it, as FFmpeg's command line decodes them (its stream
# probe finds the configuration first). Unlike FFmpeg, every sub-frame's
# payload is read. A frame cut by the end of the data ends the stream, and so does
# a trailing ID3v1 tag; anything else between frames is malformed.
.include "lamp.inc"
.globl loas_probe, loas_open, loas_close

.equ LOAS_MALFORMED, 100
.equ LOAS_UNSUPPORTED, 101
.equ TK_AAC, 7
.equ CODEC_AAC, 10

.data
loas_buffer: .quad 0                # realigned configuration and payloads
loas_used: .quad 0
loas_config_bytes: .long 0
loas_config_bits: .long 0
loas_subframes: .long 0             # numSubFrames: payloads per frame - 1
loas_pending: .quad 0               # the first frame read before any configuration
# Bit reader: data, end bit, position.
loas_data: .quad 0
loas_limit: .long 0
loas_pos: .long 0

.bss
.p2align 3
loas_config: .zero 64               # the first configuration, realigned

.text
FN loas_close
    sub rsp, 40
    mov rcx, [rip + loas_buffer]
    test rcx, rcx
    jz .Lloas_close_done
    call mem_free
    mov qword ptr [rip + loas_buffer], 0
.Lloas_close_done:
    add rsp, 40
    ret
ENDFN loas_close

# RCX=start, RDX=end -> EAX=1 when two LOAS frames follow each other there
# (or one fills the data).
FN loas_probe
    sub rsp, 40
    mov [rsp + 32], rdx
    call adts_skip_id3
    mov rcx, rax
    mov rdx, [rsp + 32]
    add rsp, 40
    xor eax, eax
    lea r8, [rcx + 3]
    cmp r8, rdx
    ja .Lloas_probe_return
    movzx r8d, word ptr [rcx]
    rol r8w, 8
    mov r9d, r8d
    and r9d, 0xffe0
    cmp r9d, 0x56e0
    jne .Lloas_probe_return
    and r8d, 0x1f
    shl r8d, 8
    movzx r9d, byte ptr [rcx + 2]
    or r8d, r9d
    lea r8, [rcx + r8 + 3]                # the next frame
    cmp r8, rdx
    je .Lloas_probe_yes
    lea r9, [r8 + 2]
    cmp r9, rdx
    ja .Lloas_probe_return
    movzx r9d, word ptr [r8]
    rol r9w, 8
    and r9d, 0xffe0
    cmp r9d, 0x56e0
    jne .Lloas_probe_return
.Lloas_probe_yes:
    mov eax, 1
.Lloas_probe_return:
    ret
ENDFN loas_probe

# ECX=bits (1-25) -> EAX, most significant first. It reads four bytes at
# the position, which the caller keeps readable; reading past loas_limit
# leaves loas_pos beyond it, which callers check. Clobbers RCX, RDX, R8, R9.
LOCALFN loas_bits
    mov r8d, [rip + loas_pos]
    mov r9d, ecx
    add [rip + loas_pos], ecx
    mov edx, r8d
    shr edx, 3
    mov rax, [rip + loas_data]
    mov eax, [rax + rdx]
    bswap eax
    mov ecx, r8d
    and ecx, 7
    shl eax, cl
    mov ecx, 32
    sub ecx, r9d
    shr eax, cl
    ret
ENDFN loas_bits

# -> EAX=LatmGetValue: two bits of byte count, then that many bytes + 1.
LOCALFN loas_value
    push rbx
    push rsi
    mov ecx, 2
    call loas_bits
    lea esi, [rax + 1]
    xor ebx, ebx
.Lloas_value_byte:
    mov ecx, 8
    call loas_bits
    shl ebx, 8
    or ebx, eax
    dec esi
    jnz .Lloas_value_byte
    mov eax, ebx
    pop rsi
    pop rbx
    ret
ENDFN loas_value

# -> EAX=PayloadLengthInfo: bytes summed while each is 255, or -1 when the
# count runs past the frame.
LOCALFN loas_length
    push rbx
    xor ebx, ebx
.Lloas_length_byte:
    mov eax, [rip + loas_pos]
    add eax, 8
    cmp eax, [rip + loas_limit]
    ja .Lloas_length_short
    mov ecx, 8
    call loas_bits
    add ebx, eax
    cmp eax, 255
    je .Lloas_length_byte
    mov eax, ebx
    pop rbx
    ret
.Lloas_length_short:
    mov eax, -1
    pop rbx
    ret
ENDFN loas_length

# RCX=destination, EDX=bits from loas_pos: copied to whole bytes (the last
# padded with zeros), loas_pos advanced. Clobbers RAX, RCX, RDX, R8-R11.
LOCALFN loas_copy
    push rbx
    push rsi
    mov rbx, rcx
    mov esi, edx
.Lloas_copy_byte:
    cmp esi, 8
    jb .Lloas_copy_tail
    mov ecx, 8
    call loas_bits
    mov [rbx], al
    inc rbx
    sub esi, 8
    jmp .Lloas_copy_byte
.Lloas_copy_tail:
    test esi, esi
    jz .Lloas_copy_done
    mov ecx, esi
    call loas_bits
    mov ecx, 8
    sub ecx, esi
    shl eax, cl
    mov [rbx], al
.Lloas_copy_done:
    pop rsi
    pop rbx
    ret
ENDFN loas_copy

# Reads an AudioSpecificConfig at loas_pos -> EAX=1 with loas_config_bits
# set to its length (EAX=2 for an unsupported one, 0 when malformed): AAC
# Main, LC, SSR or LTP (and SBR or PS around them), GASpecificConfig with a
# channel configuration (no program config element).
LOCALFN loas_asc
    push rbx
    push rsi
    push rdi
    mov edi, [rip + loas_pos]
    call loas_object_type
    mov ebx, eax
    mov ecx, 4
    call loas_bits                        # sampling frequency index
    cmp eax, 15
    jne .Lloas_asc_channels
    mov ecx, 24
    call loas_bits
.Lloas_asc_channels:
    mov ecx, 4
    call loas_bits
    mov esi, eax                          # channel configuration
    cmp ebx, 5
    je .Lloas_asc_sbr
    cmp ebx, 29
    jne .Lloas_asc_ga
.Lloas_asc_sbr:
    mov ecx, 4
    call loas_bits                        # extension frequency index
    cmp eax, 15
    jne .Lloas_asc_sbr_type
    mov ecx, 24
    call loas_bits
.Lloas_asc_sbr_type:
    call loas_object_type
    mov ebx, eax
.Lloas_asc_ga:
    cmp ebx, 1
    jb .Lloas_asc_unsupported
    cmp ebx, 4
    ja .Lloas_asc_unsupported
    test esi, esi
    jz .Lloas_asc_unsupported             # a program config element
    mov ecx, 1
    call loas_bits                        # frameLengthFlag
    mov ecx, 1
    call loas_bits                        # dependsOnCoreCoder
    test eax, eax
    jz .Lloas_asc_extension
    mov ecx, 14
    call loas_bits
.Lloas_asc_extension:
    mov ecx, 1
    call loas_bits                        # extensionFlag
    test eax, eax
    jz .Lloas_asc_done
    mov ecx, 1
    call loas_bits                        # extensionFlag3
.Lloas_asc_done:
    mov eax, [rip + loas_pos]
    cmp eax, [rip + loas_limit]
    ja .Lloas_asc_malformed
    sub eax, edi
    mov [rip + loas_config_bits], eax
    mov eax, 1
    jmp .Lloas_asc_return
.Lloas_asc_unsupported:
    mov eax, 2
    jmp .Lloas_asc_return
.Lloas_asc_malformed:
    xor eax, eax
.Lloas_asc_return:
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN loas_asc

# -> EAX=audio object type (5 bits, 31 escaping to 32 + 6 bits).
LOCALFN loas_object_type
    mov ecx, 5
    call loas_bits
    cmp eax, 31
    jne .Lloas_type_return
    mov ecx, 6
    call loas_bits
    add eax, 32
.Lloas_type_return:
    ret
ENDFN loas_object_type

# A StreamMuxConfig at loas_pos -> EAX=1 with the configuration read (the
# first one kept in loas_config), 2 when unsupported or different from the
# first, 0 when malformed.
LOCALFN loas_mux_config
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov ecx, 1
    call loas_bits                        # audioMuxVersion
    mov ebx, eax
    test ebx, ebx
    jz .Lloas_mux_version
    mov ecx, 1
    call loas_bits                        # audioMuxVersionA
    test eax, eax
    jnz .Lloas_mux_unsupported
    call loas_value                       # taraBufferFullness
.Lloas_mux_version:
    mov ecx, 7
    call loas_bits                        # allStreamsSameTimeFraming, numSubFrames
    and eax, 0x3f
    mov [rip + loas_subframes], eax
    mov ecx, 4
    call loas_bits                        # numProgram
    test eax, eax
    jnz .Lloas_mux_unsupported
    mov ecx, 3
    call loas_bits                        # numLayer
    test eax, eax
    jnz .Lloas_mux_unsupported
    xor esi, esi                          # ascLen (version 1)
    test ebx, ebx
    jz .Lloas_mux_asc
    call loas_value
    mov esi, eax
.Lloas_mux_asc:
    mov edi, [rip + loas_pos]             # the configuration's first bit
    call loas_asc
    cmp eax, 1
    jne .Lloas_mux_return
    test esi, esi
    jz .Lloas_mux_asc_copy
    mov eax, [rip + loas_config_bits]
    cmp esi, eax
    jb .Lloas_mux_malformed
    mov [rip + loas_config_bits], esi
    add esi, edi
    mov [rip + loas_pos], esi             # skip the rest of ascLen
.Lloas_mux_asc_copy:
    mov eax, [rip + loas_pos]
    mov [rsp + 56], eax
    mov [rip + loas_pos], edi
    lea rcx, [rsp]                        # this configuration, realigned
    mov edx, [rip + loas_config_bits]
    cmp edx, 8*48
    ja .Lloas_mux_malformed
    call loas_copy
    mov eax, [rsp + 56]
    mov [rip + loas_pos], eax
    mov ecx, [rip + loas_config_bits]
    add ecx, 7
    shr ecx, 3
    cmp dword ptr [rip + loas_config_bytes], 0
    jne .Lloas_mux_compare
    mov [rip + loas_config_bytes], ecx
    lea rsi, [rsp]
    lea rdi, [rip + loas_config]
    rep movsb
    jmp .Lloas_mux_frame_length
.Lloas_mux_compare:
    cmp ecx, [rip + loas_config_bytes]
    jne .Lloas_mux_unsupported            # a configuration change
    lea rsi, [rsp]
    lea rdi, [rip + loas_config]
    repe cmpsb
    jne .Lloas_mux_unsupported
.Lloas_mux_frame_length:
    mov ecx, 3
    call loas_bits                        # frameLengthType
    test eax, eax
    jnz .Lloas_mux_unsupported
    mov ecx, 8
    call loas_bits                        # latmBufferFullness
    mov ecx, 1
    call loas_bits                        # otherDataPresent
    test eax, eax
    jz .Lloas_mux_crc
    test ebx, ebx
    jz .Lloas_mux_other_escape
    call loas_value                       # otherDataLenBits
    jmp .Lloas_mux_crc
.Lloas_mux_other_escape:
    mov eax, [rip + loas_pos]
    add eax, 9
    cmp eax, [rip + loas_limit]
    ja .Lloas_mux_malformed
    mov ecx, 9
    call loas_bits
    test eax, 0x100                       # escape
    jnz .Lloas_mux_other_escape
.Lloas_mux_crc:
    mov ecx, 1
    call loas_bits                        # crcCheckPresent
    test eax, eax
    jz .Lloas_mux_done
    mov ecx, 8
    call loas_bits
.Lloas_mux_done:
    mov eax, [rip + loas_pos]
    cmp eax, [rip + loas_limit]
    ja .Lloas_mux_malformed
    mov eax, 1
    jmp .Lloas_mux_return
.Lloas_mux_unsupported:
    mov eax, 2
    jmp .Lloas_mux_return
.Lloas_mux_malformed:
    xor eax, eax
.Lloas_mux_return:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN loas_mux_config

# RCX=start, RDX=end -> EAX=1 with the AAC track open (codec_kind 10), else
# 0 with decode_error 100 or 101.
FN loas_open
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rdi, rdx
    call adts_skip_id3
    mov rsi, rax
    call loas_close
    mov dword ptr [rip + loas_config_bytes], 0
    mov qword ptr [rip + loas_pending], 0
    mov ecx, TK_AAC
    call track_begin
    test eax, eax
    jz .Lloas_open_malformed
    mov rcx, rdi
    sub rcx, rsi
    add rcx, 20480
    call mem_alloc                        # payloads, and a padded copy of a frame
    test rax, rax
    jz .Lloas_open_malformed
    mov [rip + loas_buffer], rax
    mov qword ptr [rip + loas_used], 0
.Lloas_open_frame:
    mov rax, [rip + ogg_cancel_ptr]
    test rax, rax
    jz .Lloas_open_continue
    cmp dword ptr [rax], 0
    jne .Lloas_open_malformed
.Lloas_open_continue:
    lea rax, [rsi + 3]
    cmp rax, rdi
    ja .Lloas_open_done
    mov rax, rdi
    sub rax, rsi
    cmp rax, 128
    jne .Lloas_open_sync
    cmp word ptr [rsi], 0x4154            # trailing ID3v1 "TAG"
    jne .Lloas_open_sync
    cmp byte ptr [rsi + 2], 'G'
    je .Lloas_open_done
.Lloas_open_sync:
    movzx eax, word ptr [rsi]
    rol ax, 8
    mov ecx, eax
    and ecx, 0xffe0
    cmp ecx, 0x56e0
    jne .Lloas_open_malformed
    and eax, 0x1f
    shl eax, 8
    movzx ecx, byte ptr [rsi + 2]
    or eax, ecx
    lea r12, [rsi + 3]                    # AudioMuxElement
    lea r13, [r12 + rax]                  # next frame
    cmp r13, rdi
    ja .Lloas_open_done                   # a cut frame
    # The bit reader reads up to four bytes past a position, and a
    # StreamMuxConfig is checked against the frame's end once read, up to
    # 40 bytes past it: a frame within 64 bytes of the end is read from a
    # copy padded with zeros.
    mov [rip + loas_data], r12
    shl eax, 3
    mov [rip + loas_limit], eax
    mov dword ptr [rip + loas_pos], 0
    lea rcx, [r13 + 64]
    cmp rcx, rdi
    jbe .Lloas_open_element
    mov rcx, [rip + loas_buffer]
    add rcx, [rip + loas_used]
    add rcx, 8192
    mov [rip + loas_data], rcx
    mov rdx, r12
.Lloas_open_pad:
    cmp rdx, r13
    jae .Lloas_open_pad_zero
    movzx r8d, byte ptr [rdx]
    mov [rcx], r8b
    inc rdx
    inc rcx
    jmp .Lloas_open_pad
.Lloas_open_pad_zero:
    xor eax, eax
    mov edx, 8
.Lloas_open_pad_tail:
    mov [rcx], rax
    add rcx, 8
    dec edx
    jnz .Lloas_open_pad_tail
.Lloas_open_element:
    mov ecx, 1
    call loas_bits                        # useSameStreamMux
    test eax, eax
    jnz .Lloas_open_same
    call loas_mux_config
    cmp eax, 2
    je .Lloas_open_unsupported
    test eax, eax
    jz .Lloas_open_malformed
    mov rax, [rip + loas_pending]
    test rax, rax
    jz .Lloas_open_length
    mov qword ptr [rip + loas_pending], 0
    mov rsi, rax                          # the first configuration found: back
    jmp .Lloas_open_frame                 # to the frames before it
.Lloas_open_same:
    cmp dword ptr [rip + loas_config_bytes], 0
    jne .Lloas_open_length
    cmp qword ptr [rip + loas_pending], 0
    jne .Lloas_open_next
    mov [rip + loas_pending], rsi         # no configuration yet
    jmp .Lloas_open_next
.Lloas_open_length:
    # Each sub-frame's PayloadLengthInfo and payload. A frame is skipped,
    # as FFmpeg skips it, when a payload runs past the frame or more than
    # 256 bits follow the last (a length that is not the frame's).
    mov r12d, [rip + loas_pos]
    mov r14d, [rip + loas_subframes]
.Lloas_open_check:
    call loas_length
    test eax, eax
    js .Lloas_open_next
    shl eax, 3
    mov ecx, [rip + loas_limit]
    sub ecx, [rip + loas_pos]
    cmp eax, ecx
    ja .Lloas_open_next                   # incomplete
    add [rip + loas_pos], eax
    dec r14d
    jns .Lloas_open_check
    mov eax, [rip + loas_limit]
    sub eax, [rip + loas_pos]
    cmp eax, 256
    ja .Lloas_open_next                   # far shorter than the frame
    mov [rip + loas_pos], r12d
    mov r14d, [rip + loas_subframes]
.Lloas_open_payload:
    call loas_length
    mov ebx, eax
    test ebx, ebx
    jz .Lloas_open_payload_next           # empty
    mov rcx, [rip + loas_buffer]
    add rcx, [rip + loas_used]
    lea edx, [rbx*8]
    call loas_copy
    mov rcx, [rip + loas_buffer]
    add rcx, [rip + loas_used]
    mov edx, ebx
    add [rip + loas_used], rbx
    call track_add
    test eax, eax
    jz .Lloas_open_malformed
.Lloas_open_payload_next:
    dec r14d
    jns .Lloas_open_payload
.Lloas_open_next:
    mov rsi, r13
    jmp .Lloas_open_frame
.Lloas_open_done:
    cmp qword ptr [rip + track_count], 0
    je .Lloas_open_malformed
    lea rax, [rip + loas_config]
    mov [rip + track_config], rax
    mov eax, [rip + loas_config_bytes]
    mov [rip + track_config_bytes], eax
    call track_finish
    test eax, eax
    jz .Lloas_open_failed
    mov dword ptr [rip + codec_kind], CODEC_AAC
    mov eax, 1
    jmp .Lloas_open_return
.Lloas_open_unsupported:
    mov dword ptr [rip + decode_error], LOAS_UNSUPPORTED
    jmp .Lloas_open_failed
.Lloas_open_malformed:
    cmp dword ptr [rip + decode_error], 0
    jne .Lloas_open_failed
    mov dword ptr [rip + decode_error], LOAS_MALFORMED
.Lloas_open_failed:
    call track_close
    call loas_close
    xor eax, eax
.Lloas_open_return:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ENDFN loas_open
