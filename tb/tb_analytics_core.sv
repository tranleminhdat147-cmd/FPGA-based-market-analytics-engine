`timescale 1ns/1ps
// ============================================================================
// tb_analytics_core.sv -- a small, self-checking testbench for analytics_core
// ============================================================================
// What it shows:
//   - self-checking: every microprice, fair value, sigma and quote is compared
//     automatically, PASS / FAIL at the end
//   - reference model: the correct answers, computed in plain math
//   - scoreboard: expected results wait in a queue until the DUT produces them
//   - random stimulus: $urandom_range for prices, sizes, crossed books, gaps
//   - an assertion (SVA): every tick must produce a quote exactly 7 cycles later
//
// Run (from the tb folder):
//   vlib work
//   vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv tb_analytics_core.sv
//   vsim -c tb_analytics_core -do "run -all; quit -f"
// ============================================================================
module tb_analytics_core;

    // ---------------- clock, reset, DUT ----------------
    logic clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    logic        rst_n = 0;
    logic        tick_valid = 0;
    logic [31:0] bid = 0, ask = 0, bid_sz = 0, ask_sz = 0;

    logic        quote_valid;
    logic [31:0] quote_bid, quote_ask;
    logic [47:0] fv;                             // Q32.16
    logic [31:0] sigma;                          // Q16.16

    localparam logic [31:0] K = 32'h0002_0000;   // quote width = 2.0 sigma (Q16.16)

    analytics_core dut (
        .clk(clk), .rst_n(rst_n),
        .tick_valid(tick_valid), .bid(bid), .ask(ask), .bid_sz(bid_sz), .ask_sz(ask_sz),
        .fv_k(5'd3), .var_k(5'd3), .quote_k(K), .bar_period(32'd100),
        .quote_valid(quote_valid), .quote_bid(quote_bid), .quote_ask(quote_ask),
        .fv(fv), .sigma(sigma), .ts()
    );

    int checks = 0, errors = 0;

    // ---------------- reference models ----------------
    // microprice = bid + (ask - bid) * bid_sz / (bid_sz + ask_sz), or the mid if both sizes are 0
    function automatic real microprice_model(longint b, longint a, longint bs, longint as_);
        if (bs + as_ == 0) return (b + a) / 2.0;
        return b + (a - b) * real'(bs) / real'(bs + as_);
    endfunction

    // quote = floor(fv - k*sigma) / ceil(fv + k*sigma), ask >= bid + 1, bid >= 0
    // (same integer steps as quote.sv, so the result must match exactly)
    function automatic longint quote_bid_model(longint f, longint s);
        longint lo = f - ((s * K) >>> 16);
        return (lo < 0) ? 0 : (lo >>> 16);
    endfunction
    function automatic longint quote_ask_model(longint f, longint s);
        longint a = (f + ((s * K) >>> 16) + 65535) >>> 16;
        return (a <= quote_bid_model(f, s)) ? quote_bid_model(f, s) + 1 : a;
    endfunction

    // ---------------- scoreboard 1: microprice ----------------
    // a tick goes in -> its expected microprice is queued
    // the DUT's microprice comes out -> compare with the oldest expected one
    real expected_mp[$];                          // [$] = a queue (a list that grows and shrinks)

    always @(posedge clk) begin
        real got, want, allowed;
        if (tick_valid)
            expected_mp.push_back(microprice_model(bid, ask, bid_sz, ask_sz));
        if (dut.mp_valid) begin                   // dut.xxx = an internal signal of the DUT
            got     = dut.mp / 65536.0;
            want    = expected_mp.pop_front();
            allowed = 0.01;                       // LUT accuracy for spreads up to ~20 ticks
            checks++;
            if (got - want > allowed || want - got > allowed) begin
                errors++;
                $display("FAIL microprice: got %.4f, expected %.4f", got, want);
            end
        end
    end

    // ---------------- check: fair value ----------------
    // the same EMA in plain math, fed with the DUT's own microprice:
    //   FV = FV + (microprice - FV) / 8      (fv_k = 3; the first one is loaded directly)
    real fv_model;
    bit  fv_started = 0;

    always @(posedge clk) begin
        if (dut.fv_valid) begin                   // compare last cycle's update first...
            checks++;
            if (fv / 65536.0 - fv_model > 0.001 || fv_model - fv / 65536.0 > 0.001) begin
                errors++;
                $display("FAIL fair value: got %.4f, expected %.4f", fv / 65536.0, fv_model);
            end
        end
        if (dut.mp_valid) begin                   // ...then do this cycle's update
            if (!fv_started) fv_model = dut.mp / 65536.0;
            else             fv_model = fv_model + (dut.mp / 65536.0 - fv_model) / 8.0;
            fv_started = 1;
        end
    end

    // ---------------- check: sigma (the slow path) ----------------
    // on every bar, redo the slow path in plain math:
    //   r = FV now - FV at the last bar,  r^2 (kept with 16 fraction bits like the hardware),
    //   variance = variance + (r^2 - variance) / 8   (var_k = 3; the first one is loaded directly)
    // and whenever the DUT finishes a new sigma, it must equal sqrt(variance)
    real fv_last_bar, var_model;
    bit  have_last_bar = 0, var_started = 0;
    int  sigma_checks = 0;

    always @(posedge clk) begin
        real r, r2, got, want, allowed;
        if (dut.bar_tick && dut.fv_ok) begin      // a bar, after the first tick
            if (have_last_bar) begin
                r  = fv / 65536.0 - fv_last_bar;
                r2 = $floor(r * r * 65536.0) / 65536.0;
                if (!var_started) var_model = r2;
                else              var_model = var_model + (r2 - var_model) / 8.0;
                var_started = 1;
            end
            fv_last_bar   = fv / 65536.0;
            have_last_bar = 1;
        end
        if (dut.u_sigma.out_valid) begin          // the DUT finished a new sigma
            got  = sigma / 65536.0;
            want = $sqrt(var_model);
            // allowed: square-root rounding + the variance's own rounding (both 1/65536 steps)
            allowed = (want > 0.0) ? (2.0 / 65536.0) * (1.0 + 1.0 / want) : 0.01;
            checks++;
            sigma_checks++;
            if (got - want > allowed || want - got > allowed) begin
                errors++;
                $display("FAIL sigma: got %.5f, expected %.5f", got, want);
            end
        end
    end

    // ---------------- scoreboard 2: quote ----------------
    // when fair value updates, the quote block reads fv and sigma: queue them;
    // when the quote comes out 2 cycles later, compare with the model
    longint fv_seen[$], sigma_seen[$];

    always @(posedge clk) begin
        longint f, s;
        if (quote_valid) begin
            f = fv_seen.pop_front();
            s = sigma_seen.pop_front();
            checks++;
            if (quote_bid != quote_bid_model(f, s) || quote_ask != quote_ask_model(f, s)) begin
                errors++;
                $display("FAIL quote: got %0d/%0d, expected %0d/%0d",
                         quote_bid, quote_ask, quote_bid_model(f, s), quote_ask_model(f, s));
            end
        end
        if (dut.fv_valid) begin
            fv_seen.push_back(fv);
            sigma_seen.push_back(sigma);
        end
    end

    // ---------------- assertion: latency ----------------
    // "whenever a tick goes in, a quote comes out exactly 7 cycles later"
    // checked by the simulator on every clock edge, for every tick
    assert property (@(posedge clk) disable iff (!rst_n) tick_valid |-> ##7 quote_valid)
        else begin errors++; $display("FAIL latency: no quote 7 cycles after a tick"); end

    // ---------------- helper task ----------------
    // put a tick on the inputs for one clock cycle
    // (inputs change on the falling edge, so they're stable when the DUT reads them)
    task automatic send_tick(longint b, longint a, longint bs, longint as_);
        @(negedge clk);
        bid = b; ask = a; bid_sz = bs; ask_sz = as_;
        tick_valid = 1;
        @(negedge clk);
        tick_valid = 0;
    endtask

    // ---------------- the tests ----------------
    initial begin
        longint price;

        // reset for 5 cycles
        repeat (5) @(negedge clk);
        rst_n = 1;

        // test 1: hand-picked books (the expected microprice is in the comment)
        $display("test 1: hand-picked books");
        send_tick(1000, 1002, 100, 100);       // equal sizes  -> 1001.0
        send_tick(1000, 1002, 300, 100);       // more on bid  -> 1001.5
        send_tick(1000, 1002, 500, 0);         // all on bid   -> 1002.0
        send_tick(1000, 1002, 0, 0);           // empty book   -> 1001.0
        send_tick(1002, 1000, 300, 100);       // crossed      -> 1000.5
        send_tick(1000, 1000, 300, 100);       // locked       -> 1000.0
        repeat (20) @(negedge clk);

        // test 2: a new tick on every cycle -- nothing may be lost
        $display("test 2: 50 ticks on 50 consecutive cycles");
        for (int i = 0; i < 50; i++) begin
            @(negedge clk);
            bid = 1000 + i % 4;  ask = bid + 2;
            bid_sz = $urandom_range(1, 500);  ask_sz = $urandom_range(1, 500);
            tick_valid = 1;
        end
        @(negedge clk) tick_valid = 0;
        repeat (20) @(negedge clk);

        // test 3: random market -- 2000 ticks, 5% crossed, random gaps
        $display("test 3: 2000 random ticks");
        price = 1000;
        for (int i = 0; i < 2000; i++) begin
            price = price + $urandom_range(0, 2) - 1;             // moves -1, 0 or +1
            if ($urandom_range(1, 20) == 1)
                send_tick(price, price - $urandom_range(1, 3),    // crossed book
                          $urandom_range(0, 5000), $urandom_range(0, 5000));
            else
                send_tick(price, price + $urandom_range(1, 3),
                          $urandom_range(0, 5000), $urandom_range(0, 5000));
            repeat ($urandom_range(0, 8)) @(negedge clk);         // random gap
        end
        repeat (20) @(negedge clk);

        // every expected result must have been matched by a DUT result (nothing lost)
        checks++;
        if (expected_mp.size() != 0 || fv_seen.size() != 0) begin
            errors++;
            $display("FAIL: results still waiting -- the DUT lost some outputs");
        end

        // sigma is only checked when the DUT says a new one is ready:
        // make sure that actually happened, or the sigma check never ran at all
        checks++;
        if (sigma_checks == 0) begin
            errors++;
            $display("FAIL: no sigma was ever produced");
        end

        // summary
        $display("");
        $display("checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
