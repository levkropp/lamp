# Test-only aliases into an isolated copy of the real rendering engine.
# No endpoint setup is called by this CPU-only fake-client oracle.
.include "win/player.s"
.globl pc_test_begin,pc_test_fill,pc_test_pause,pc_test_ended,pc_test_stopped
.set pc_test_begin,pc_begin
.set pc_test_fill,fill_render
.set pc_test_pause,pc_pause_position
.set pc_test_ended,pc_ended
.set pc_test_stopped,pc_stopped
.globl pc_test_started
.set pc_test_started,pc_started
.globl pc_test_client,pc_test_render,pc_test_buffer_frames,pc_test_done
.set pc_test_client,client_obj
.set pc_test_render,render_obj
.set pc_test_buffer_frames,buffer_frames
.set pc_test_done,producer_done
.globl pc_test_write,pc_test_read,pc_test_pcm,pc_test_seek,pc_test_error,pc_test_clock
.set pc_test_write,write_count
.set pc_test_read,read_count
.set pc_test_pcm,ring_pcm
.set pc_test_seek,engine_seek_frames
.set pc_test_error,audio_hresult
.set pc_test_clock,engine_clock_context
.globl pc_test_start_flag
.set pc_test_start_flag,audio_started
