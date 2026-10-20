// Time-bar trigger: one-cycle pulse every `period` clock cycles.
// e.g. 50 MHz clock, period = 50_000 -> one bar per millisecond.
// period = 0 disables it.
module bar_trigger #(
    parameter int CNT_W = 32
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic [CNT_W-1:0] period,
    output logic             bar_tick
);

    logic [CNT_W-1:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt      <= '0;
            bar_tick <= 1'b0;
        end else begin
            bar_tick <= 1'b0;
            if (period == '0) begin
                cnt <= '0;
            end else if (cnt >= period - 1'b1) begin   // >= so lowering period at runtime can't skip a wrap
                cnt      <= '0;
                bar_tick <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
