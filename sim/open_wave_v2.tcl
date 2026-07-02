# Waveform for SDO capture timing verification
# Shows the same signals as the user's real-controller screenshot
# Focus: sync fall → frame_start → cmd_shift → cmd_data_r → cmd_valid

# --- Top-level link signals (match user's screenshot layout) ---
add_wave /hda_codec_tb/u_dut/u_link/clk
add_wave /hda_codec_tb/sync
add_wave /hda_codec_tb/sdo
add_wave /hda_codec_tb/u_dut/u_link/sdo_neg

add_wave /hda_codec_tb/u_dut/u_link/frame_start
add_wave -radix unsigned /hda_codec_tb/u_dut/u_link/bit_cnt
add_wave /hda_codec_tb/u_dut/u_link/link_state

# --- SDO capture chain ---
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_shift
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_data_r
add_wave /hda_codec_tb/u_dut/u_link/cmd_valid_raw
add_wave /hda_codec_tb/u_dut/u_link/cmd_valid
add_wave -radix hex /hda_codec_tb/u_dut/u_link/cmd_data

# --- Downstream verb engine ---
add_wave -radix hex /hda_codec_tb/u_dut/u_verb/cmd_data
add_wave /hda_codec_tb/u_dut/u_verb/resp_valid
add_wave -radix hex /hda_codec_tb/u_dut/u_verb/resp_data

# --- SDI response ---
add_wave /hda_codec_tb/u_dut/u_link/sdi_normal
add_wave /hda_codec_tb/u_dut/u_link/resp_loaded
add_wave -radix hex /hda_codec_tb/u_dut/u_link/resp_pending

# Run through init + first 2 commands (~200us)
run 200us
