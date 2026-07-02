#------------------------------------------------------------------------------
# Generic HDA Codec — Vivado Simulation Script
#------------------------------------------------------------------------------
# Usage:
#   vivado -mode batch -source sim_hda_codec.tcl -tclargs <CHIP_ID>
#   CHIP_ID: 0=ALC269 (default), 1=ALC662, 2=ALC892, 3=ALC256
#
# Or run all three:
#   vivado -mode batch -source sim_hda_codec.tcl -tclargs all
#------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize "$script_dir/../rtl/generic"]
set tb_dir     [file normalize "$script_dir/../tb"]

# Parse chip argument
if {[llength $argv] > 0} {
    set chip_arg [lindex $argv 0]
} else {
    set chip_arg "0"
}

proc run_sim {chip_id chip_name} {
    global rtl_dir tb_dir script_dir

    puts "============================================================"
    puts " Simulating $chip_name (CHIP_ID=$chip_id)"
    puts "============================================================"

    # Create project in memory
    set proj_name "hda_sim_${chip_name}"
    create_project -force $proj_name $script_dir/$proj_name -part xc7a35tcpg236-1

    # Set to simulation-only
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]

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

    # Add TB sources
    set tb_files [list \
        "$tb_dir/hda_codec_bfm.sv" \
        "$tb_dir/hda_codec_tb.sv" \
    ]
    add_files -fileset sim_1 $tb_files
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1]]

    # Set include path
    set_property verilog_define "CHIP_ID=$chip_id" [get_filesets sim_1]
    set_property include_dirs $rtl_dir [get_filesets sim_1]
    set_property include_dirs $rtl_dir [get_filesets sources_1]

    # Set top module
    set_property top hda_codec_tb [get_filesets sim_1]

    # Update compile order
    update_compile_order -fileset sim_1

    # Launch simulation
    launch_simulation -mode behavioral

    # Override Vivado's default 1000ns run — run until $finish
    run all

    puts "============================================================"
    puts " Simulation $chip_name COMPLETE"
    puts "============================================================"

    close_sim
    close_project
}

# Execute
if {$chip_arg eq "all"} {
    run_sim 0 "ALC269"
    run_sim 1 "ALC662"
    run_sim 2 "ALC892"
    run_sim 3 "ALC256"
} else {
    set names [dict create 0 "ALC269" 1 "ALC662" 2 "ALC892" 3 "ALC256"]
    if {[dict exists $names $chip_arg]} {
        set cname [dict get $names $chip_arg]
    } else {
        set cname "ALC269"
        set chip_arg 0
    }
    run_sim $chip_arg $cname
}

puts "\nDone."
