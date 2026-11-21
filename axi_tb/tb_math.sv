`timescale 1ns/1ps
module tb_math;
    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    int errors = 0;
    real max_rel = 0.0;

    // ---------------- microprice ----------------
    logic mp_iv, mp_ov;
    logic [31:0] bid, ask; logic [31:0] bsz, asz;
    logic [47:0] mp;
    microprice u_mp(.clk, .rst_n, .in_valid(mp_iv), .bid, .ask, .bid_sz(bsz), .ask_sz(asz), .out_valid(mp_ov), .mp);

    task automatic run_mp(input longint b, input longint a, input longint bs, input longint as_, output real got);
        @(negedge clk); bid = b; ask = a; bsz = bs; asz = as_; mp_iv = 1;
        @(negedge clk); mp_iv = 0;
        repeat (3) @(negedge clk);
        got = real'(mp) / 65536.0;
    endtask

    task automatic check_mp(input longint b, input longint a, input longint bs, input longint as_, input real expected);
        real got, err, sp;
        run_mp(b, a, bs, as_, got);
        sp = real'(a - b); if (sp < 0) sp = -sp;              // |spread|, works for crossed books too
        err = got - expected; if (err < 0) err = -err;
        if (sp > 0 && err / sp > max_rel) max_rel = err / sp;
        if (err > sp / 1024.0 + 1.0/32768.0) begin errors++; $display("MP FAIL b=%0d a=%0d bs=%0d as=%0d got=%f exp=%f", b, a, bs, as_, got, expected); end
    endtask

    // garbage-input check: whatever happens, mp must stay between bid and ask (no wrap-around)
    task automatic check_mp_in_range(input longint b, input longint a, input longint bs, input longint as_);
        real got, lo, hi;
        run_mp(b, a, bs, as_, got);
        lo = (a < b) ? real'(a) : real'(b); hi = (a < b) ? real'(b) : real'(a);
        if (got < lo - 0.001 || got > hi + 0.001) begin errors++; $display("MP RANGE FAIL b=%0d a=%0d got=%f", b, a, got); end
    endtask

    // ---------------- sigma_sqrt ----------------
    logic sq_iv, sq_ov; logic [63:0] sq_x; logic [31:0] sq_root;
    sigma_sqrt u_sq(.clk, .rst_n, .in_valid(sq_iv), .x(sq_x), .out_valid(sq_ov), .root(sq_root));

    // check one square root: its VALUE and its LATENCY (34 edges)
    task automatic check_sqrt(input logic [63:0] x);
        logic [127:0] r, r1;
        int cycles;
        @(negedge clk); sq_x = x; sq_iv = 1;
        @(posedge clk); cycles = 1;                        // edge 1: the block takes the input
        @(negedge clk); sq_iv = 0;
        while (sq_ov !== 1'b1) begin                       // count edges until the block says "done"
            @(posedge clk); cycles++;
            #1;                                            // look just after the edge
        end
        @(negedge clk);
        if (cycles != 34) begin errors++; $display("SQRT LATENCY FAIL x=%0d: %0d edges, expected 34", x, cycles); end
        r = sq_root; r1 = r + 1;
        if (!(r*r <= x && r1*r1 > x)) begin errors++; $display("SQRT FAIL x=%0d root=%0d", x, sq_root); end
    endtask

    // latency guard (SVA): every input the block accepts must give out_valid
    // exactly 34 edges later -- 0 for 34 edges in a row, then 1 (not early, not late)
    assert property (@(posedge clk) disable iff (!rst_n)
        (sq_iv && !u_sq.busy) |-> (!sq_ov)[*34] ##1 sq_ov)
        else begin errors++; $display("SQRT LATENCY FAIL (assertion)"); end

    // ---------------- quote ----------------
    logic q_iv, q_ov; logic [47:0] q_fv; logic [31:0] q_sig; logic [31:0] q_k; logic [31:0] q_bid, q_ask;
    quote u_q(.clk, .rst_n, .in_valid(q_iv), .fv(q_fv), .sigma(q_sig), .k(q_k), .out_valid(q_ov), .bid_px(q_bid), .ask_px(q_ask));

    task automatic check_quote(input real fvr, input real sigr, input real kr, input int eb, input int ea);
        @(negedge clk); q_fv = 48'(longint'(fvr*65536.0)); q_sig = 32'(longint'(sigr*65536.0)); q_k = 32'(longint'(kr*65536.0)); q_iv = 1;
        @(negedge clk); q_iv = 0;
        @(negedge clk);
        if (q_bid !== eb || q_ask !== ea) begin errors++; $display("QUOTE FAIL fv=%f sig=%f k=%f got %0d/%0d exp %0d/%0d", fvr, sigr, kr, q_bid, q_ask, eb, ea); end
    endtask

    // ---------------- ema ----------------
    logic e_iv, e_ov; logic signed [48:0] e_x, e_y;
    ema u_e(.clk, .rst_n, .in_valid(e_iv), .x(e_x), .k(5'd3), .out_valid(e_ov), .y(e_y));

    initial begin
        mp_iv = 0; sq_iv = 0; q_iv = 0; e_iv = 0;
        repeat (3) @(negedge clk); rst_n = 1;

        // microprice
        check_mp(1000, 1002, 100, 100, 1001.0);
        check_mp(1000, 1002, 300, 100, 1001.5);
        check_mp(1000, 1002, 100, 300, 1000.5);
        check_mp(1000, 1002, 500, 0,   1002.0);
        check_mp(1000, 1002, 0,   500, 1000.0);
        check_mp(1000, 1002, 0,   0,   1001.0);
        check_mp(1000, 1002, 65535, 65535, 1001.0);
        check_mp(1000, 1001, 1, 2, 1000.0 + 1.0/3.0);
        for (int i = 0; i < 2000; i++) begin
            longint b, s, bs, as_;
            b = $urandom_range(1, 2000000000); s = $urandom_range(0, 20);
            if (i % 2) begin bs = $urandom; as_ = $urandom; end else begin bs = $urandom_range(0, 65535); as_ = $urandom_range(0, 65535); end
            if (bs + as_ == 0) bs = 1;
            check_mp(b, b + s, bs, as_, real'(b) + real'(s) * real'(bs) / real'(bs + as_));
        end
        // crossed book (ask < bid): signed spread, mp walks down from bid toward ask
        check_mp(1002, 1000, 300, 100, 1000.5);
        check_mp(1002, 1000, 100, 300, 1001.5);
        check_mp(1002, 1000, 100, 100, 1001.0);
        check_mp(1002, 1000, 500, 0,   1000.0);   // w = 1 -> at the ask
        check_mp(1002, 1000, 0,   500, 1002.0);   // w = 0 -> at the bid
        check_mp(1002, 1000, 0,   0,   1001.0);   // empty book -> mid
        check_mp(1000, 1000, 300, 100, 1000.0);   // locked book
        for (int i = 0; i < 2000; i++) begin
            longint b, a, bs, as_;
            b = $urandom_range(1, 2000000000); a = b - $urandom_range(1, 20);
            if (i % 2) begin bs = $urandom; as_ = $urandom; end else begin bs = $urandom_range(0, 65535); as_ = $urandom_range(0, 65535); end
            if (bs + as_ == 0) bs = 1;
            check_mp(b, a, bs, as_, real'(b) + real'(a - b) * real'(bs) / real'(bs + as_));
        end
        // extreme prices: full 32-bit range, both directions (exercises the spread clamp)
        check_mp_in_range(0, 64'hFFFF_FFFF, 300, 100);
        check_mp_in_range(64'hFFFF_FFFF, 0, 300, 100);
        check_mp_in_range(64'hFFFF_FFFF, 0, 500, 0);
        check_mp_in_range(0, 64'hFFFF_FFFF, 500, 0);
        check_mp(64'hFFFF_FFF0, 64'hFFFF_FFFF, 1, 1, 4294967287.5);   // top of range, normal spread
        check_mp(64'hFFFF_FFFF, 64'hFFFF_FFF0, 1, 1, 4294967287.5);   // top of range, crossed
        // 32-bit sizes: beyond the old 16-bit limit, and the very top of the range
        check_mp(1000, 1002, 70000, 70000, 1001.0);
        check_mp(1000, 1002, 300000, 100000, 1001.5);
        check_mp(1000, 1002, 64'hFFFF_FFFF, 64'hFFFF_FFFF, 1001.0);
        check_mp(1000, 1002, 64'hFFFF_FFFF, 0, 1002.0);                // w = 1 with the biggest size (clamp)
        check_mp(1000, 1002, 0, 64'hFFFF_FFFF, 1000.0);
        for (int i = 0; i < 2000; i++) begin                          // nearly all size on the bid: w just under 1
            longint bs, as_;
            bs = $urandom; as_ = $urandom_range(0, 100);
            if (bs == 0) bs = 1;
            check_mp(1000, 1020, bs, as_, 1000.0 + 20.0 * real'(bs) / real'(bs + as_));
        end
        $display("microprice done, max error = %f %% of spread", max_rel*100.0);

        // sqrt
        check_sqrt(0); check_sqrt(1); check_sqrt(2); check_sqrt(4); check_sqrt(64'hFFFF_FFFF_FFFF_FFFF);
        check_sqrt(64'd1 << 32);   // 1.0 in Q32.32 -> 1.0 in Q16.16
        for (int i = 0; i < 500; i++) check_sqrt({$urandom, $urandom} >> $urandom_range(0, 63));
        $display("sqrt done");

        // quote: fv 1001.5, sigma 0.5, k 2 -> [1000.5, 1002.5] -> 1000 / 1003
        check_quote(1001.5, 0.5, 2.0, 1000, 1003);
        check_quote(1001.0, 0.0, 2.0, 1001, 1002);    // sigma 0: ask forced to bid+1
        check_quote(1001.25, 0.0, 2.0, 1001, 1002);
        check_quote(1.0, 10.0, 2.0, 0, 21);            // bid clamps at 0
        $display("quote done");

        // ema step: x 0 -> 1000, k = 3
        @(negedge clk); e_x = 0; e_iv = 1; @(negedge clk);
        e_x = 49'sd1000 <<< 16;
        repeat (200) @(negedge clk);
        e_iv = 0; @(negedge clk);
        if (e_y < ((49'sd1000 <<< 16) - 49'sd2) || e_y > (49'sd1000 <<< 16)) begin errors++; $display("EMA FAIL y=%f", real'(e_y)/65536.0); end
        $display("ema settled at %f (target 1000)", real'(e_y)/65536.0);

        if (errors == 0) $display("ALL PASS"); else $display("FAILURES: %0d", errors);
        $finish;
    end
endmodule

