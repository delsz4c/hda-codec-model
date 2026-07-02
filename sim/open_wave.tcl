# Open xsim GUI with key SDO capture signals pre-loaded
# Usage: xsim sim_debug -gui -t open_wave.tcl

# Add key signals for SDO capture timing analysis
add_wave /hda_codec_tb/bclk
add_wave /hda_codec_tb/sync
add_wave /hda_codec_tb/sdo
add_wave /hda_codec_tb/sdi_wire

add_wave /hda_codec_tb/u_dut/u_link/frame_start
add_wave /hda_codec_tb/u_dut/u_link/bit_cnt
add_wave /hda_codec_tb/u_dut/u_link/link_state
add_wave /hda_codec_tb/u_dut/u_link/sdo_neg
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_shift
add_wave /hda_codec_tb/u_dut/u_link/cmd_valid_raw
add_wave /hda_codec_tb/u_dut/u_link/cmd_valid
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_data
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_data_r
add_wave /hda_codec_tb/u_dut/u_link/sdi_normal
add_wave /hda_codec_tb/u_dut/u_link/resp_loaded
add_wave -radix hex /hda_codec_tb/u_dut/u_link/resp_pending

# Run enough to cover init + first command
run 200us
