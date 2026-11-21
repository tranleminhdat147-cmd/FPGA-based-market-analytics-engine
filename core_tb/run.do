# ============================================================================
# run.do -- compile and run the maths testbenches
# ----------------------------------------------------------------------------
#   vsim -c -do "do run.do"              both: tb_math, then tb_math_chain
#   vsim -c -do "do run.do math"         tb_math only
#   vsim -c -do "do run.do chain"        tb_math_chain only
#   vsim -c -do "do run.do chain 7"      tb_math_chain with seed 7
#
# Save the output:  vsim -c -l run.log -do "do run.do"
# Coverage report:  cov/coverage.txt   (written after tb_math_chain runs)
#
# NOTE: tb_math_chain needs a LICENSED Questa (randomize + covergroups).
# tb_math runs on the free Questa Starter edition too.
# ============================================================================

# arguments after "do run.do" arrive as $1, $2 ($argv is Questa's own command line)
if {$argc >= 1} { set which $1 } else { set which both }
if {$argc >= 2} { set seed  $2 } else { set seed 1 }

if {[lsearch {both math chain} $which] < 0} {
    echo "unknown option '$which' -- use: math, chain, or nothing for both"
    if {[batch_mode]} { quit -f } else { return }
}

# ---- compile: every design file in the folder above, then both testbenches ----
vlib work
vlog -sv {*}[glob ../*.sv] tb_math.sv tb_math_chain.sv

# ---- run ----
# -onfinish stop: $finish stops the testbench instead of closing Questa,
# so the second testbench can still run after the first.
if {$which eq "math" || $which eq "both"} {
    vsim -quiet -onfinish stop work.tb_math
    run -all
    quit -sim
}

if {$which eq "chain" || $which eq "both"} {
    file mkdir cov
    vsim -quiet -coverage -onfinish stop -sv_seed $seed work.tb_math_chain
    run -all
    coverage save cov/chain_seed$seed.ucdb
    quit -sim
    # the coverage report (tb_math has no covergroups, so only tb_math_chain)
    vcover report -details -cvg cov/chain_seed$seed.ucdb -output cov/coverage.txt
    echo "coverage report: cov/coverage.txt"
}

if {[batch_mode]} { quit -f }
