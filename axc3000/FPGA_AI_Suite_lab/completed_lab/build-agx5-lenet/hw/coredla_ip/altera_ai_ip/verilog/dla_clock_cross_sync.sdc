# timing constraints related to dla_clock_cross_full_sync.sv, dla_clock_cross_half_sync.sv, and dla_cdc_sync_resetn.sv

# cut the path to the first stage inside each synchronizer

# The pins should be |q to |d instead of |* to |*, but Quartus 19.2 cannot match that constraint style for some reason.
set_false_path -from [get_pins -compatibility_mode -nocase {*|dla_clock_cross_full_sync_special_name_for_sdc_wildcard_matching|dla_cdc_src_data_reg[*]|*}] \
               -to   [get_pins -compatibility_mode -nocase {*|dla_clock_cross_full_sync_special_name_for_sdc_wildcard_matching|dla_cdc_sync_head[*]|*}]

# The pin below should be |d
set_false_path -to   [get_pins -compatibility_mode -nocase {*|dla_clock_cross_half_sync_special_name_for_sdc_wildcard_matching|dla_cdc_sync_head[*]|*}]


set_false_path -to [get_pins -compatibility_mode -nocase {*|dla_areset_clock_cross_sync_special_name_for_sdc_wildcard_matching|dla_cdc_sync_head[*]|clrn}]
set_false_path -to [get_pins -compatibility_mode -nocase {*|dla_areset_clock_cross_sync_special_name_for_sdc_wildcard_matching|dla_cdc_sync_body[*][*]|clrn}]
