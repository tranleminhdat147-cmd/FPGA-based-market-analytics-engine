// Free-running cycle counter, the time base for latency measurements.
// 64 bits at 50 MHz wraps after ~11,000 years.
module timestamp #(
    parameter int TS_W = 64
)(
    input  logic            clk,
    input  logic            rst_n,
    output logic [TS_W-1:0] ts
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 1'b1;
    end

endmodule
