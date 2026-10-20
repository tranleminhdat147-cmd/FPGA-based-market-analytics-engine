// First-order IIR low-pass filter (EMA) with alpha = 2^-k:
//
//   y[n] = y[n-1] + (x[n] - y[n-1]) * 2^-k
//
// The multiply by alpha is a shift. G guard bits below the output LSB keep
// the truncation bias of that shift negligible. The first sample is loaded
// directly so the output doesn't ramp up from 0.
// Effective window is about 2^k samples (k = 4 -> ~16 samples).
//
// Used twice: fair value (x = microprice, every tick) and variance
// (x = squared return, every bar).
// Latency: 1 cycle.
module ema #(
    parameter int W = 49,   // signed data width
    parameter int G = 8     // guard bits
)(
    input  logic                clk,
    input  logic                rst_n,

    input  logic                in_valid,
    input  logic signed [W-1:0] x,
    input  logic [4:0]          k,

    output logic                out_valid,
    output logic signed [W-1:0] y
);

    logic signed [W+G-1:0] acc;      // y with G extra fraction bits
    logic signed [W+G-1:0] x_ext;
    logic signed [W+G:0]   diff;
    logic                  primed;

    assign x_ext = {x, {G{1'b0}}};
    assign diff  = x_ext - acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= '0;
            primed    <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                // acc + diff * 2^-k always lies between acc and x_ext, so it fits W+G bits
                acc    <= primed ? acc + (diff >>> k) : x_ext;
                primed <= 1'b1;
            end
        end
    end

    assign y = acc[W+G-1:G];

endmodule
