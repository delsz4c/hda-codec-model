# Quick waveform dump for SDO/cmd_shift timing debug
# Usage: xsim sim_snap -t run_wave.tcl

# Log only the relevant signals for the SDO capture timing investigation
log_wave -r /hda_codec_tb/u_dut/u_link/*
log_wave /hda_codec_tb/bclk
log_wave /hda_codec_tb/sync
log_wave /hda_codec_tb/sdo
log_wave /hda_codec_tb/sdi_wire

# Only run ~6 frames to cover init + first 2 commands (enough for timing check)
# 1 frame = 500 BCLK = 500 * 41.666ns ≈ 20833ns
# Init = 4 frames, then 2 cmd frames = 6 frames ≈ 125000ns
run 200us
quit
