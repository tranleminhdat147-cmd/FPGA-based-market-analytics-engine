`timescale 1ns/1ps
// quick check: 40 ticks in, slow receiver (ready 1 cycle in 5), FIFO depth 16
// -> every quote must come out in order, matching a direct analytics_core run
module tb_axis;
    logic clk = 0, rst_n = 0; always #10 clk = ~clk;
    logic [127:0] s_tdata; logic s_tvalid = 0, s_tready;
    logic [63:0] m_tdata; logic m_tvalid, m_tready = 0;
    logic [31:0] dropped;
    analytics_core_axis #(.FIFO_DEPTH(64)) dut (.aclk(clk), .aresetn(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .fv_k(5'd2), .var_k(5'd2), .quote_k(32'h0002_0000), .bar_period(32'd50), .dropped_quotes(dropped));

    logic [63:0] expected [$];
    always @(posedge clk) if (dut.quote_valid) expected.push_back({dut.quote_bid, dut.quote_ask});

    int got = 0, errs = 0;
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            if (m_tdata !== expected[got]) errs++;
            got++;
        end
    end
    int c = 0; always @(negedge clk) begin c++; m_tready <= (c % 5 == 0); end

    initial begin
        automatic int px = 1000;
        repeat (3) @(negedge clk); rst_n = 1;
        for (int i = 0; i < 40; i++) begin
            px += $urandom_range(0, 2) - 1;
            @(negedge clk); s_tdata = {32'(px), 32'(px + 2), 32'($urandom_range(1, 500)), 32'($urandom_range(1, 500))}; s_tvalid = 1;
            @(negedge clk); s_tvalid = 0;
            repeat (2) @(negedge clk);
        end
        repeat (400) @(negedge clk);
        $display("quotes produced %0d, received %0d, mismatches %0d, dropped %0d -> %s",
                 expected.size(), got, errs, dropped, (got == expected.size() && errs == 0 && dropped == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
