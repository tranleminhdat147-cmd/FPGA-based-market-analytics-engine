# ============================================================================
# run.do -- compile and run the AXI wrapper testbench
# ----------------------------------------------------------------------------
#   vsim -c -do "do run.do"                  one run of the default test
#   vsim -c -do "do run.do 20"               20 seeds of all 3 tests + coverage
#   vsim -c -do "do run.do 20 overflow"      20 seeds of the overflow test only
#
# One run in detail, after it has compiled once:
#   vsim -c work.tb_top +TEST=overflow +seed=3 -do "run -all; quit -f"
#
# NOTE: needs a LICENSED simulator. randomize() and covergroups are not
# included in the free Questa Starter edition that ships with Quartus.
# ============================================================================

# arguments after "do run.do" arrive as $1, $2 ($argv is Questa's own command line)
if {$argc >= 1} { set num_seeds $1 } else { set num_seeds 1 }
if {$argc >= 2} { set tests [list $2] } else { set tests {smoke backpressure overflow} }

# ---- compile: RTL, then the interface, then the classes, then the top ----
# That order is the dependency order: engine_pkg needs axis_if to exist before
# it can declare a `virtual axis_if` handle.
vlib work
vlog -sv -timescale 1ns/1ps +cover +incdir+. \
     ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv \
     ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv ../analytics_core_axis.sv \
     axis_if.sv engine_pkg.sv tb_top.sv

file mkdir cov

# ---- run ----
set failed {}
set total 0
foreach test $tests {
    for {set seed 1} {$seed <= $num_seeds} {incr seed} {
        incr total
        vsim -quiet -coverage -onfinish stop -voptargs="+acc +cover" \
             work.tb_top +TEST=$test +seed=$seed
        run -all
        # tb_top copies the scoreboard's verdict into a MODULE variable at the
        # end of the run. `examine` cannot walk into a class -- objects live on
        # the heap, not in the elaborated hierarchy -- so /tb_top/e/sb/errors
        # would always fail and every run would be reported as failed.
        if {[catch {examine -radix unsigned /tb_top/test_passed} ok] || $ok != 1} {
            lappend failed "$test/$seed"
        }
        coverage save cov/${test}_${seed}.ucdb
        quit -sim
    }
}

# ---- merge coverage from every run ----
# Delete the old merged file first: otherwise cov/*.ucdb globs it into its own
# input list and vcover reports "multiple test data records with the same name".
file delete -force cov/merged.ucdb
vcover merge cov/merged.ucdb cov/*.ucdb
vcover report -details -cvg cov/merged.ucdb -output cov/coverage.txt
vcover report -html -output cov/html -details cov/merged.ucdb

# ---- summary ----
echo "============================================================"
echo " [expr {$total - [llength $failed]}] / $total runs passed"
if {[llength $failed] > 0} {
    echo " failed: $failed"
    set first [lindex $failed 0]
    set t [lindex [split $first /] 0]
    set s [lindex [split $first /] 1]
    echo " rerun with:"
    echo "   vsim -c work.tb_top +TEST=$t +seed=$s -do \"run -all; quit -f\""
}
echo " merged coverage : cov/coverage.txt"
echo " html report     : cov/html/index.html"
echo "============================================================"

if {[batch_mode]} { quit -f }
