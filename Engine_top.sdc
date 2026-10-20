# ============================================================================
# Engine_top.sdc -- timing constraints for the Quartus Timing Analyzer
# ============================================================================
# Used by Quartus only (not by Questa). It tells the Timing Analyzer how fast
# the clock runs, so it can check that every path fits in one clock cycle.
#
# The current top level is analytics_core_axis, whose clock port is "aclk".
# When Engine_top exists, change [get_ports aclk] to the board's clock pin
# (e.g. [get_ports CLOCK_50]).
# ============================================================================

# 50 MHz system clock: one cycle = 20 ns
create_clock -name clk50 -period 20.000 [get_ports aclk]

# add realistic clock jitter / uncertainty margins
derive_clock_uncertainty
