#------------------------------------------------------------------------------
# Generic HDA Codec — Vivado Synthesis Script
#------------------------------------------------------------------------------
# Usage:
#   vivado -mode batch -source synth_hda_codec.tcl -tclargs <CHIP_ID>|all [PART]
#
#   CHIP_ID: 0=ALC269, 1=ALC662, 2=ALC892, 3=ALC256
#   PART:    Xilinx part (default: xc7a35tcpg236-1, Artix-7)
#
# Examples:
#   vivado -mode batch -source synth_hda_codec.tcl -tclargs 0
#   vivado -mode batch -source synth_hda_codec.tcl -tclargs 2 xc7k325tffg900-2
#   vivado -mode batch -source synth_hda_codec.tcl -tclargs all
#------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize "$script_dir/../rtl/generic"]

# Parse arguments
set chip_arg 0
set part      "xc7a35tcpg236-1"

if {[llength $argv] > 0} { set chip_arg [lindex $argv 0] }
if {[llength $argv] > 1} { set part      [lindex $argv 1] }

set names [dict create 0 "ALC269" 1 "ALC662" 2 "ALC892" 3 "ALC256"]

proc run_synth {chip_id chip_name part script_dir rtl_dir} {
    puts "============================================================"
    puts " Synthesizing HDA Codec: $chip_name (CHIP_ID=$chip_id)"
    puts " Target FPGA: $part"
    puts "============================================================"

    # Create project
    set proj_name "hda_synth_${chip_name}"
    create_project -force $proj_name $script_dir/$proj_name -part $part

    # Add RTL sources
    set rtl_files [list \
        "$rtl_dir/hda_codec_pkg.sv" \
        "$rtl_dir/hda_link.sv" \
        "$rtl_dir/hda_widget_regs.sv" \
        "$rtl_dir/hda_verb_engine.sv" \
        "$rtl_dir/hda_audio_path.sv" \
        "$rtl_dir/hda_gpio_ctrl.sv" \
        "$rtl_dir/hda_beep_gen.sv" \
        "$rtl_dir/hda_spdif_out.sv" \
        "$rtl_dir/hda_pwr_mgmt.sv" \
        "$rtl_dir/hda_codec_top.sv" \
    ]
    add_files -fileset sources_1 $rtl_files
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]

    # Add timing constraints
    add_files -fileset constrs_1 "$script_dir/hda_codec.xdc"

    # Set include path, synthesis macro, and top-level generic parameter
    set_property include_dirs $rtl_dir [get_filesets sources_1]
    set_property verilog_define "SYNTHESIS=1" [get_filesets sources_1]

    # Set top module with generic parameter
    set_property top hda_codec_top [current_fileset]
    set_property generic "CHIP_ID=$chip_id" [current_fileset]

    # Update compile order
    update_compile_order -fileset sources_1

    # Run synthesis
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1

    # Report results
    open_run synth_1
    puts "\n============================================================"
    puts " Synthesis Results: $chip_name"
    puts "============================================================"

    report_utilization -file $script_dir/${proj_name}/utilization_${chip_name}.rpt
    report_timing_summary -file $script_dir/${proj_name}/timing_${chip_name}.rpt
    report_timing -nworst 10 -sort_by slack -file $script_dir/${proj_name}/timing_detail_${chip_name}.rpt

    puts "\nTiming summary:"
    report_timing_summary -return_string

    puts "\nUtilization summary:"
    report_utilization -return_string

    puts "\n============================================================"
    puts " Synthesis $chip_name COMPLETE"
    puts " Reports: $script_dir/${proj_name}/"
    puts "============================================================"

    close_project
}

if {$chip_arg eq "all"} {
    run_synth 0 "ALC269" $part $script_dir $rtl_dir
    run_synth 1 "ALC662" $part $script_dir $rtl_dir
    run_synth 2 "ALC892" $part $script_dir $rtl_dir
    run_synth 3 "ALC256" $part $script_dir $rtl_dir
} else {
    if {[dict exists $names $chip_arg]} {
        set chip_name [dict get $names $chip_arg]
    } else {
        set chip_name "ALC269"
        set chip_arg 0
    }
    run_synth $chip_arg $chip_name $part $script_dir $rtl_dir
}
