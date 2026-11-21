`timescale 1ns/1ps
// ============================================================================
// tb_math_chain.sv -- end-to-end testbench for analytics_core
// ============================================================================
// Checks the FINAL OUTPUT only. Every quote is predicted from the ticks that
// went in, and compared with the quote that comes out. No probes inside the
// DUT: if any stage is wrong, the quote is wrong, and this catches it.
//
//   ticks ──► [ DUT   ] ──► quote
//   ticks ──► [ model ] ──► expected quote        must match within 1 tick
//
// The model is plain real-number maths, so it cannot match the hardware's
// fixed-point rounding to the last bit: a quote passes if its bid and ask are
// each within 1 tick of the model. (The exact rounding of each block is
// checked by tb_math.sv.)
//
// Also:
//   - constrained random stimulus in test 3 (class tick_c)
//   - functional coverage (cg_tick), printed at the end
//   - an assertion: every tick gives a quote exactly 7 cycles later
//
// Run (from the tb folder):
//   vlib work
//   vlog -sv ../microprice.sv ../ema.sv ../return_sq.sv ../sigma_sqrt.sv ../quote.sv ../bar_trigger.sv ../timestamp.sv ../analytics_core.sv tb_math_chain.sv
//   vsim -c tb_math_chain -do "run -all; quit -f"
//   vsim -c tb_math_chain -sv_seed 7 -do "run -all; quit -f"     (another seed)
//
// NOTE: randomize() and covergroups need a LICENSED Questa -- the free Starter
// edition that ships with Quartus will compile this but refuse to run it.
// ============================================================================
module tb_math_chain;

    // ---------------- clock, reset, DUT ----------------
    logic clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    logic        rst_n = 0;
    logic        tick_valid = 0;
    logic [31:0] bid = 0, ask = 0, bid_sz = 0, ask_sz = 0;

    logic        quote_valid;
    logic [31:0] quote_bid, quote_ask;

    localparam int  BAR = 100;                   // bar_period: one bar every 100 cycles
    localparam real K   = 2.0;                   // quote half-width in sigmas

    analytics_core dut (
        .clk(clk), .rst_n(rst_n),
        .tick_valid(tick_valid), .bid(bid), .ask(ask), .bid_sz(bid_sz), .ask_sz(ask_sz),
        .fv_k(5'd3), .var_k(5'd3), .quote_k(32'h0002_0000), .bar_period(BAR),
        .quote_valid(quote_valid), .quote_bid(quote_bid), .quote_ask(quote_ask),
        .fv(), .sigma(), .ts()
    );

    // ---------------- reference model: the whole core in plain maths ----------------
    //   microprice = bid + (ask - bid) * bid_sz / (bid_sz + ask_sz)   (the mid if both sizes are 0)
    //   fair value = EMA of microprice, alpha 1/8                     (first one loaded directly)
    //   each bar:    r        = fair value now - fair value at the last bar
    //                variance = EMA of r^2, alpha 1/8                 (first one loaded directly)
    //                sigma    = sqrt(variance)
    //   quote      = floor(fv - K*sigma) / ceil(fv + K*sigma), ask >= bid + 1, bid >= 0
    function automatic real microprice(longint b, longint a, longint bs, longint as_);
        if (bs + as_ == 0) return (b + a) / 2.0;
        return b + (a - b) * real'(bs) / real'(bs + as_);
    endfunction

    // The maths alone is not enough: the model must also know WHICH sigma each
    // quote used, because a new sigma takes time to compute. From the RTL:
    //   - a tick seen at clock edge T reaches fair value at edge T+4, and its
    //     quote reads fair value and sigma at edge T+5 (it comes out at T+7)
    //   - the core sees a bar at edges BAR+1, 2*BAR+1, ... and uses fair value
    //     as it stood just before that edge
    //   - the new sigma is used by quotes from 37 edges after the bar
    //     (2 return + 1 variance EMA + 34 square root)
    typedef struct { int edge_no; real fv; } fv_at_t;

    fv_at_t fv_pipe[$];          // fair value on its way into the core's register
    fv_at_t quote_pipe[$];       // ticks whose quote has not read sigma yet
    longint exp_bid[$], exp_ask[$];

    int  cyc        = 0;         // clock edges since reset
    int  first_tick = -1;        // edge of the first tick
    real fv         = 0;         // fair value after every tick so far
    real fv_core    = 0;         // fair value as the core's register holds it
    bit  fv_started = 0;
    real fv_last_bar = 0, variance = 0, sigma = 0, sigma_new = 0;
    bit  have_last_bar = 0, var_started = 0;
    int  sigma_from = -1;        // edge from which sigma_new is used

    int  n_quotes = 0, errors = 0, quotes_with_sigma = 0;

    always @(posedge clk) if (rst_n) begin
        fv_at_t q;
        real    lo, hi, r2;
        longint eb, ea;
        cyc++;

        // 1. a quote came out -> compare it with the oldest prediction
        if (quote_valid) begin
            n_quotes++;
            if (exp_bid.size() == 0) begin
                errors++;
                $display("FAIL: quote %0d/%0d came out, but none was expected", quote_bid, quote_ask);
            end
            else begin
                eb = exp_bid.pop_front();
                ea = exp_ask.pop_front();
                if (longint'(quote_bid) - eb > 1 || eb - longint'(quote_bid) > 1 ||
                    longint'(quote_ask) - ea > 1 || ea - longint'(quote_ask) > 1) begin
                    errors++;
                    $display("FAIL quote: got %0d/%0d, expected %0d/%0d (+/- 1)",
                             quote_bid, quote_ask, eb, ea);
                end
            end
        end

        // 2. a new sigma becomes usable
        if (sigma_from != -1 && cyc >= sigma_from) begin
            sigma      = sigma_new;
            sigma_from = -1;
        end

        // 3. ticks whose quote reads fair value and sigma now -> predict the quote
        while (quote_pipe.size() != 0 && quote_pipe[0].edge_no == cyc) begin
            q  = quote_pipe.pop_front();
            lo = q.fv - K * sigma;
            hi = q.fv + K * sigma;
            eb = (lo < 0.0) ? 0 : longint'($floor(lo));
            ea = longint'($ceil(hi));
            if (ea <= eb) ea = eb + 1;
            exp_bid.push_back(eb);
            exp_ask.push_back(ea);
            if (sigma > 0.0) quotes_with_sigma++;
        end

        // 4. fair value that reached the core's register before this edge
        while (fv_pipe.size() != 0 && fv_pipe[0].edge_no < cyc) begin
            q       = fv_pipe.pop_front();
            fv_core = q.fv;
        end

        // 5. a bar -> new return, new variance, new sigma
        //    (the core ignores bars until fair value exists: 6 edges after the first tick)
        if (cyc > 1 && (cyc - 1) % BAR == 0 && first_tick != -1 && cyc - first_tick >= 6) begin
            if (have_last_bar) begin
                r2          = fv_core - fv_last_bar;
                r2          = $floor(r2 * r2 * 65536.0) / 65536.0;    // kept to 16 fraction bits, like the hardware
                variance    = var_started ? variance + (r2 - variance) / 8.0 : r2;
                var_started = 1;
                sigma_new   = $sqrt(variance);
                sigma_from  = cyc + 37;
            end
            fv_last_bar   = fv_core;
            have_last_bar = 1;
        end

        // 6. a tick went in -> update fair value, and remember it for steps 3 and 4
        if (tick_valid) begin
            fv = fv_started ? fv + (microprice(bid, ask, bid_sz, ask_sz) - fv) / 8.0
                            : microprice(bid, ask, bid_sz, ask_sz);
            fv_started = 1;
            if (first_tick == -1) first_tick = cyc;
            q.fv      = fv;
            q.edge_no = cyc + 4;  fv_pipe.push_back(q);
            q.edge_no = cyc + 5;  quote_pipe.push_back(q);
        end
    end

    // ---------------- assertion: latency ----------------
    // "whenever a tick goes in, a quote comes out exactly 7 cycles later"
    assert property (@(posedge clk) disable iff (!rst_n) tick_valid |-> ##7 quote_valid)
        else begin errors++; $display("FAIL latency: no quote 7 cycles after a tick"); end

    // ---------------- constrained-random tick (used by test 3) ----------------
    typedef enum {NORMAL, CROSSED, LOCKED} book_e;

    class tick_c;
        rand int    step;         // price move: -1, 0 or +1
        rand book_e book;
        rand int    spread;       // ticks between bid and ask
        rand int    bs, as_;      // sizes
        rand int    gap;          // idle cycles after the tick

        constraint c_step { step inside {[-1:1]}; }
        constraint c_book { book dist {NORMAL := 90, CROSSED := 5, LOCKED := 5};
                            spread inside {[1:3]}; }
        // size 0 is the microprice fallback case, so give it a real weight.
        // `:/` spreads the 90 across the range; `:=` would give EACH value 90
        // and zero would almost never come out.
        constraint c_size { bs  dist {0 := 10, [1:5000] :/ 90};
                            as_ dist {0 := 10, [1:5000] :/ 90}; }
        constraint c_gap  { gap inside {[0:8]}; }
    endclass

    // ---------------- functional coverage ----------------
    // sampled on every tick that goes in, in all three tests
    covergroup cg_tick;
        cp_book: coverpoint ((ask > bid) ? 2'd0 : (ask == bid) ? 2'd1 : 2'd2) {
            bins normal  = {0};
            bins locked  = {1};
            bins crossed = {2};
        }
        cp_bid_sz: coverpoint bid_sz { bins zero = {0}; bins nonzero = {[1:$]}; }
        cp_ask_sz: coverpoint ask_sz { bins zero = {0}; bins nonzero = {[1:$]}; }
        x_sizes:   cross cp_bid_sz, cp_ask_sz;     // both zero = the mid-price fallback
    endgroup

    cg_tick cov = new();

    always @(posedge clk) if (rst_n && tick_valid) cov.sample();

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
        tick_c  t;

        // reset for 5 cycles
        repeat (5) @(negedge clk);
        rst_n = 1;

        // test 1: hand-picked books
        $display("test 1: hand-picked books");
        send_tick(1000, 1002, 100, 100);       // equal sizes
        send_tick(1000, 1002, 300, 100);       // more on bid
        send_tick(1000, 1002, 500, 0);         // all on bid
        send_tick(1000, 1002, 0, 0);           // empty book -> mid
        send_tick(1002, 1000, 300, 100);       // crossed
        send_tick(1000, 1000, 300, 100);       // locked
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

        // test 3: random market -- 2000 constrained-random ticks
        $display("test 3: 2000 random ticks");
        t     = new();
        price = 1000;
        for (int i = 0; i < 2000; i++) begin
            if (!t.randomize()) $fatal(1, "tick randomize() failed");
            price = price + t.step;
            case (t.book)
                CROSSED: send_tick(price, price - t.spread, t.bs, t.as_);
                LOCKED:  send_tick(price, price,            t.bs, t.as_);
                default: send_tick(price, price + t.spread, t.bs, t.as_);
            endcase
            repeat (t.gap) @(negedge clk);
        end
        repeat (20) @(negedge clk);

        // every predicted quote must have come out
        if (exp_bid.size() != 0 || quote_pipe.size() != 0) begin
            errors++;
            $display("FAIL: %0d predicted quotes never came out", exp_bid.size() + quote_pipe.size());
        end

        // the volatility path must actually have been used, or the sigma
        // part of every quote went untested
        if (quotes_with_sigma == 0) begin
            errors++;
            $display("FAIL: sigma never became non-zero -- the volatility path was not exercised");
        end

        // summary
        $display("");
        $display("quotes compared: %0d   (%0d used a non-zero sigma)", n_quotes, quotes_with_sigma);
        $display("errors: %0d", errors);
        $display("functional coverage: %0.2f %%", cov.get_coverage());
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
