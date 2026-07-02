# ==============================================================================
# Generic HDA Codec — Timing Constraints
# ==============================================================================
# Target: 24 MHz BCLK (41.666 ns period)
# ==============================================================================

# ---- Primary clock ----
create_clock -period 41.666 -name bclk [get_ports bclk]

# ---- Input delays (relative to bclk) ----
# SDO from HDA controller: setup/hold relative to BCLK rising edge
set_input_delay -clock bclk -max 10.0 [get_ports sdo]
set_input_delay -clock bclk -min  2.0 [get_ports sdo]

# SYNC from HDA controller
set_input_delay -clock bclk -max 10.0 [get_ports sync]
set_input_delay -clock bclk -min  2.0 [get_ports sync]

# Reset / power-down (async, but constrain for analysis)
set_input_delay -clock bclk -max 10.0 [get_ports reset_n]
set_input_delay -clock bclk -min  2.0 [get_ports reset_n]
set_input_delay -clock bclk -max 10.0 [get_ports pd_n]
set_input_delay -clock bclk -min  2.0 [get_ports pd_n]

# Analog audio input stubs
set_input_delay -clock bclk -max 10.0 [get_ports {mic1_* mic2_* line1_* line2_*}]
set_input_delay -clock bclk -min  2.0 [get_ports {mic1_* mic2_* line1_* line2_*}]

# Misc inputs
set_input_delay -clock bclk -max 10.0 [get_ports {dmic_mode_en dmic_data_in pcbeep_in loopback_en}]
set_input_delay -clock bclk -min  2.0 [get_ports {dmic_mode_en dmic_data_in pcbeep_in loopback_en}]

# ---- Output delays ----
set_output_delay -clock bclk -max 10.0 [get_ports sdi]
set_output_delay -clock bclk -min  2.0 [get_ports sdi]

set_output_delay -clock bclk -max 10.0 [get_ports {hp_out_* front_out_* surr_out_* clfe_out_* side_out_* mono_out}]
set_output_delay -clock bclk -min  2.0 [get_ports {hp_out_* front_out_* surr_out_* clfe_out_* side_out_* mono_out}]

set_output_delay -clock bclk -max 10.0 [get_ports {spdif_out* beep_out dmic_clk_out}]
set_output_delay -clock bclk -min  2.0 [get_ports {spdif_out* beep_out dmic_clk_out}]

set_output_delay -clock bclk -max 10.0 [get_ports {codec_ready afg_powered dac_powered adc_powered spdif_powered}]
set_output_delay -clock bclk -min  2.0 [get_ports {codec_ready afg_powered dac_powered adc_powered spdif_powered}]

# ---- Async resets: treat as false path for hold analysis ----
set_false_path -from [get_ports reset_n]
set_false_path -from [get_ports pd_n]

# ---- GPIO is bidirectional, tristate — relax ----
set_false_path -to   [get_ports gpio*]
set_false_path -from [get_ports gpio*]
