package require cmdline
package require json::write
package require ::quartus::misc
package require ::quartus::project
package require ::quartus::report

namespace eval DLA {

    set COMPILE_REPORT_JSON "dla_compile_report.json"
    # Default name for JSON file generated after parsing Quartus reports.

    proc check_param { params_arr name } {
    #
    # Description: Check that a user-provided option was set correctly and not
    #              equal to "?".  This will error out if the parameter is not
    #              set.
    #
    # Parameters:
    #    params_arr - name of the hashmap storing the provided options
    #    name       - parameter name
    #
    # Returns: The parameter value, if valid.
    #
    # --------------------------------------------------------------------------
        upvar $params_arr params
        set value $params($name)

        if { $value eq "?" } {
            post_message -type error "Missing value for '-$name'."
            qexit -error
        }

        return $value
    }

    proc json_number { number } {
    #
    # Description: Cleans up a numerical string, just as "  1,234,567" and
    #              converts it into a JSON number, such as "1234567".
    #
    # Parameters:
    #    number - numerical string
    #
    # Returns: number formatted as a JSON string
    #
    # --------------------------------------------------------------------------

        set trimmed [string trim $number]
        set parts [split $trimmed ","]
        return [join $parts ""]
    }

    proc json_fraction { frac } {
    #
    # Description: Parse a string formatted as "x / y" and return as the json
    #              array [x, y].  The numerator and denominator are both
    #              converted into JSON numbers.
    #
    # Parameters:
    #    frac - fraction string
    #
    # Returns: JSON array containing the numerator and denomenator
    #
    # --------------------------------------------------------------------------
        set parts   [split $frac "/"]
        set size    [llength $parts]

        if {$size != 2} {
            error "Expected '$frac' to be formatted as 'x / y'."
        }

        set x [json_number [lindex $parts 0]]
        set y [json_number [lindex $parts 1]]
        return [json::write array $x $y]
    }

    proc find_row { id col pattern } {
    #
    # Description: Find the row ID using the value in a particular column.
    #
    # Parameters:
    #    id         - the panel/table ID from get_report_panel_id
    #    col        - column index
    #    pattern    - the pattern or value to search for; if this is a regex
    #                 then the first matching value is returned
    #
    # Returns: The row index or '-1' if it cannot be found.
    #
    # --------------------------------------------------------------------------
        set num_rows [get_number_of_rows -id $id]
        set row_id -1

        for {set i 0} {$i < $num_rows} {incr i} {
            set row [get_report_panel_row -id $id -row $i]
            set value [lindex $row $col]

            if {[string match $pattern $value]} {
                set row_id $i
                break
            }
        }

        return $row_id
    }

    proc find_row_and_get_value { id search_col fetch_col pattern } {
        set col_id [get_report_panel_column_index -id $id $search_col]
        set row_id [find_row $id $col_id $pattern]

        if {$row_id < 0} {
            post_message -type error "Could not find '$pattern' in '$search_col' column."
            qexit -error
        }

        set col_id [get_report_panel_column_index -id $id $fetch_col]
        set row    [get_report_panel_row -id $id -row $row_id]
        set value  [lindex $row $col_id]

        return $value
    }

    proc parse_report_value { type value } {
    #
    # Description: Parse a row from the given table.
    #
    # Parameters:
    #    type   - the column type ('number', 'fraction', or 'string')
    #    name   - the row name, which can be a regular expression
    #
    # Returns: The JSON-equivalent value for "Usage", which is either a number,
    #          string, or an array of numbers or strings.
    #
    # --------------------------------------------------------------------------
        switch $type {
            "number" {
                return [json_number $value]
            }
            "fraction" {
                return [json_fraction $value]
            }
            "string" {
                return [json::write string $value]
            }
            default {
                post_message -type error "Unknown column type '$type'."
                qexit -error
            }
        }
    }

    proc get_row_value_by_name { id col type name } {
    #
    # Description: Parse a row from the given table.
    #
    # Parameters:
    #    id     - the panel/table ID from get_report_panel_id
    #    col    - column index
    #    type   - the column type ('number', 'fraction', or 'string')
    #    name   - the row name, which can be a regular expression
    #
    # Returns: The JSON-equivalent value for "Usage", which is either a number,
    #          string, or an array of numbers or strings.
    #
    # --------------------------------------------------------------------------
        set row   [get_report_panel_row -id $id -row_name $name]
        set value [lindex $row $col]
        return [parse_report_value $type $value]
    }

    proc extractClockFrequency {filename} {
        # Read the file contents
        set fileId [open $filename r]
        set fileContents [read $fileId]
        close $fileId

        # Extract the clock refrequency
        set pattern {clock-frequency-low:(\d+)}
        set extractedValue ""
        if {[regexp $pattern $fileContents match value]} {
            set extractedValue $value
        }

        return $extractedValue
    }

     proc get_clock_info { clocks_arr user_clock_file_path } {
    #
    # Description: Extracts clock information from the timing analyzer report.
    #
    # Parameters:
    #    clocks_arr - name of the hash map with the clock names
    #    user_clock_file_path  - path to the file containing the user clock frequency (optional)
    #
    # Returns: A hash map containing the IP Fmax and platform clock.
    #
    # --------------------------------------------------------------------------
        post_message "Getting clock info from the timing report."

        upvar $clocks_arr clocks

        # Get the platform (i.e. "true") clock.
        set clocks_table_id  [get_report_panel_id "Timing Analyzer||Clocks"]
        set platform_clock   [find_row_and_get_value $clocks_table_id "Clock Name" "Frequency" $clocks(platform)]

        # Get the IP Fmax.
        set fmax_summary_id [get_report_panel_id "Timing Analyzer||Fmax Summary"]
        set ip_fmax_clock   [find_row_and_get_value $fmax_summary_id "Clock Name" "Restricted Fmax" $clocks(ip)]

        # Get the IP clock.
        set ip_clock        [find_row_and_get_value $clocks_table_id "Clock Name" "Frequency" $clocks(ip)]

        # Package for output
        set frequencies(platform) [parse_report_value "string" $platform_clock]
        set frequencies(ip_fmax)  [parse_report_value "string" $ip_fmax_clock]
        set frequencies(ip_freq)  [parse_report_value "string" $ip_clock]

        # Conditionally extract clock frequency from the file if provided to overwrite the true clock
        if {$user_clock_file_path ne ""} {
            set extractedClockFrequency [extractClockFrequency $user_clock_file_path]
            post_message "Extracted clock frequency from file: $extractedClockFrequency"
            set frequencies(ip_freq) [parse_report_value "string" "${extractedClockFrequency} MHz"]
        }

        return [array get frequencies]
    }

    proc get_resource_usage {} {
    #
    # Description: Extracts the resource usage from the fitter's resource usage
    #              summary table.  All values are converted into their JSON
    #              equivalents.
    #
    # Returns: A hash map containing the resource usage fields.
    #
    # --------------------------------------------------------------------------
        post_message "Getting resource usage from fitter report."

        set id [get_report_panel_id "Fitter||Place Stage||Fitter Resource Usage Summary"]
        set col [get_report_panel_column_index -id $id "Usage"]

        set resources(alms)              [get_row_value_by_name $id $col "fraction" "Logic utilization*"]
        set resources(aluts)             [get_row_value_by_name $id $col "number"   "Combinational ALUT usage*"]
        set resources(dsp_blocks)        [get_row_value_by_name $id $col "fraction" "DSP Blocks*"]
        set resources(block_memory_bits) [get_row_value_by_name $id $col "fraction" "Total block memory bits"]
        set resources(m20ks)             [get_row_value_by_name $id $col "fraction" "M20K blocks"]
        set resources(memory_labs)       [get_row_value_by_name $id $col "number"   "*Memory LABs*"]

        return [array get resources]
    }

    proc write_json_report { project_name revision_name clocks_arr user_clock_file_path output_file } {
    #
    # Description: Write the JSON resource usage report for the given project.
    #
    # Parameters:
    #    project_name  - project name (usually, but not always, 'top')
    #    revision_name - revision name; a value of '-' will use the default
    #                    revision
    #    clocks        - name of array containing the different clocks
    #    user_clock_file_path     - path to the file containing the user clock frequency (optional)
    #    output_file   - location of the output JSON file
    #
    # --------------------------------------------------------------------------
        post_message "Opening project '$project_name'."

        upvar $clocks_arr clocks
        post_message "Clocks:"
        post_message "  Platform - $clocks(platform)"
        post_message "  IP       - $clocks(ip)"

        if { $revision_name eq "-" } {
            project_open $project_name
        } else {
            project_open -revision $revision_name $project_name
        }
        load_report

        # Get the various reports
        array set resource_usage [get_resource_usage]
        array set clock_info [get_clock_info clocks $user_clock_file_path]

        set qor_report(resources) [json::write object {*}[array get resource_usage]]
        set qor_report(clocks)    [json::write object {*}[array get clock_info]]

        # Save them to a JSON file
        post_message "Writing report to '$output_file'."
        set fh [open $output_file w]

        puts $fh [json::write object {*}[array get qor_report]]
        close $fh

        unload_report
        project_close
    }

}

# -- Main Script -- #

proc dla_parse_report { args } {
#
# Description: Run the DLA report parsing script.
#
# Parameters:
#    args - command line arguments
#
# ------------------------------------------------------------------------------

    set options {
        {"project.arg" "top" "Project name"}
        {"revision.arg" "-" "Revision name"}
        {"ip-clock.arg" "?" "IP clock name"}
        {"platform-clock.arg" "?" "Platform clock name"}
        {"user-clock-file.arg" "" "Path to the user clock frequency file (optional)"}
    }

    set usage "[info script] \[options] \n\
        Parse Quartus reports to obtain an example's QoR metrics. \n\
        \n\
        Any option with a default value of \"?\" must be provided.\n\
        \n\
        options:"

    # Parse the input arguments
    array set params [::cmdline::getoptions args $options $usage]

    set project_name          [::DLA::check_param params "project"]
    set revision_name         [::DLA::check_param params "revision"]
    set clocks(ip)            [::DLA::check_param params "ip-clock"]
    set clocks(platform)      [::DLA::check_param params "platform-clock"]
    set user_clock_file       [::DLA::check_param params "user-clock-file"]

    # Generate the report JSON
    post_message "Running dla_parse_report.tcl"
    ::DLA::write_json_report $project_name $revision_name clocks $user_clock_file $::DLA::COMPILE_REPORT_JSON
}

if {[info script] eq $::argv0} {
    set args $::quartus(args)
    dla_parse_report {*}$args
}
