# Speex packet foundation ABI. Original assembly; BSD reference attribution
# is in THIRD_PARTY_NOTICES. No reference C is part of the runtime link.
.equ SPXB_DATA, 0
.equ SPXB_BITS, 8
.equ SPXB_POS, 12
.equ SPXB_ERROR, 16
.equ SPXB_SIZE, 24
.equ SPX_MAX_PACKET, 1048576
.equ SPX_MAX_FRAMES, 64
.equ SPX_MAX_CONTROLS, 1024
# Header summary: rate, mode, channels, frame size, frames/packet,
# extra headers, VBR flag, signed bitrate. Eight uint32 values (32 bytes).
.equ SPXH_SIZE, 32
# Packet summary: frames, samples, coded bits (without final padding),
# controls, wideband layers, ultra-wideband layers, stereo controls, reserved.
.equ SPXP_SIZE, 32
