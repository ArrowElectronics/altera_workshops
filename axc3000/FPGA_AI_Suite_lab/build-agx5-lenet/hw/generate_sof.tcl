# generate_sof.tcl
# Script for compiling the coreDLA Agilex 7 DDR-Free Example Design targeting Altera Agilex 7 I-Series Development Kit.
# is responsible for generating the .sof file
# Is called by dla_build_example_design for building the Quartus project.

# Check if exactly three arguments are provided

proc compile_script {project_name revision_name family_name device_name} {
    qexec "qsys-generate -syn --family=\"$family_name\" --part=$device_name board.qsys 2>&1 | tee qsys_generate.log"
    qexec "qsys-archive --quartus-project=$project_name --rev=top --add-to-project board.qsys 2>&1 | tee qsys_archive.log"
    qexec "quartus_syn --read_settings_files=off --write_settings_files=off $project_name -c $revision_name 2>&1 | tee quartus_syn.log"
    qexec "quartus_fit --read_settings_files=on --write_settings_files=off $project_name -c $revision_name 2>&1 | tee quartus_fit.log"
    qexec "quartus_sta $project_name -c $revision_name --mode=finalize --do_report_timing 2>&1 | tee quartus_sta.log"
    qexec "quartus_cdb -t dla_adjust_pll.tcl 2>&1 | tee dla_adjust_pll.log"
    qexec "quartus_asm --read_settings_files=on --write_settings_files=off $project_name -c $revision_name 2>&1 | tee quartus_asm.log"
}

proc main {} {
    set project_name top
    set revision_name top
    set family_name Agilex
    set device_name AGIB027R29A1E2VR3

    # Compile the project and generate bitstream
    compile_script $project_name $revision_name $family_name $device_name
    
    # Generates QoR JSON
    set project_ip_clock "board_inst|kernel_pll|kernel_pll_outclk0"
    source dla_parse_report.tcl 
    dla_parse_report -project top -ip-clock ${project_ip_clock} -platform-clock ${project_ip_clock}
}

main