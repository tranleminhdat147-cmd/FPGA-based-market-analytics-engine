// Squared fair-value return per time bar:
//
//   r = FV(bar n) - FV(bar n-1),     r2 = r^2
//
// Sampling on fixed time bars instead of every tick makes the variance a
// per-unit-of-time measure, so a burst of ticks doesn't inflate it.
//
// Formats (every fractional value has FRAC = 16 fraction bits):
//     fv     Q32.16  ticks
//     |r|    Q16.16  ticks      saturates at 65,536 ticks per bar
//     r2     Q32.16  ticks^2    |r| * |r| = Q32.32, then >> 16 (the usual "multiply, then >> 16")
//
// The first bar only primes FV(bar n-1).
// Latency: 2 cycles after bar_tick.
module return_sq #(
    parameter int FV_W  = 48,
    parameter int RET_W = 32,    // |r| width, Q16.16
    parameter int FRAC  = 16
)(
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       bar_tick,
    input  logic                       fv_ok,     // fv holds a real value (at least one tick seen)
    input  logic [FV_W-1:0]            fv,

    output logic                       out_valid,
    output logic [2*RET_W-FRAC-1:0]    r2         // Q32.16
);

    logic [FV_W-1:0]     fv_last;
    logic                have_last;

    logic signed [FV_W:0] r;
    logic [FV_W:0]        r_mag;
    logic [RET_W-1:0]     r_sat;

    assign r     = $signed({1'b0, fv}) - $signed({1'b0, fv_last});
    assign r_mag = r[FV_W] ? -r : r;
    assign r_sat = (|r_mag[FV_W:RET_W]) ? '1 : r_mag[RET_W-1:0];

    logic             s1_valid;
    logic [RET_W-1:0] s1_mag;

    logic [2*RET_W-1:0] r2_full;     // Q32.32
    assign r2_full = s1_mag * s1_mag;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fv_last   <= '0;
            have_last <= 1'b0;
            s1_valid  <= 1'b0;
            s1_mag    <= '0;
            out_valid <= 1'b0;
            r2        <= '0;
        end else begin
            // stage 1: return magnitude
            s1_valid <= 1'b0;
            if (bar_tick && fv_ok) begin
                fv_last   <= fv;
                have_last <= 1'b1;
                s1_valid  <= have_last;
                s1_mag    <= r_sat;
            end

            // stage 2: square, then >> 16 back to 16 fraction bits
            out_valid <= s1_valid;
            if (s1_valid) r2 <= r2_full[2*RET_W-1:FRAC];
        end
    end

endmodule
