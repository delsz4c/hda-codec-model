#------------------------------------------------------------------------------
# Generic HDA Codec — Address Configuration Simulation Script
#------------------------------------------------------------------------------
# Usage:
#   vivado -mode batch -source sim_hda_addr.tcl -tclargs <CHIP_ID>
#   CHIP_ID: 0=ALC269 (default), 1=ALC662, 2=ALC892, 3=ALC256
#
# Or run all chips:
#   vivado -mode batch -source sim_hda_addr.tcl -tclargs all
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
    puts " Address TB: $chip_name (CHIP_ID=$chip_id)"
    puts "============================================================"

    set proj_name "hda_sim_addr_${chip_name}"
    create_project -force $proj_name $script_dir/$proj_name -part xc7a35tcpg236-1

    set_property target_language    Verilog [current_project]
    set_property simulator_language Mixed   [current_project]

    # RTL sources
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
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets sources_1]]

    # TB sources
    set tb_files [list \
        "$tb_dir/hda_addr_ctrl_bfm.sv" \
        "$tb_dir/hda_addr_tb.sv" \
    ]
    add_files -fileset sim_1 $tb_files
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets sim_1]]

    # Macro define + include path
    set_property verilog_define "CHIP_ID=$chip_id" [get_filesets sim_1]
    set_property include_dirs $rtl_dir [get_filesets sim_1]
    set_property include_dirs $rtl_dir [get_filesets sources_1]

    set_property top hda_addr_tb [get_filesets sim_1]
    update_compile_order -fileset sim_1

    launch_simulation -mode behavioral
    run all

    puts "============================================================"
    puts " Address TB $chip_name COMPLETE"
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
