// Two-sided quote around fair value:
//
//   bid_px = floor(FV - k * sigma)
//   ask_px = ceil (FV + k * sigma)
//
// Rounding outward keeps the quote on the integer tick grid and never
// narrower than asked. ask_px >= bid_px + 1 is enforced so the two sides
// never touch (e.g. when sigma is still 0). bid_px clamps at 0.
//
// Formats (every fractional value has FRAC = 16 fraction bits):
//     fv      Q32.16  ticks
//     sigma   Q16.16  ticks
//     k       Q16.16  sigmas   (k = 2.0 -> 32'h0002_0000)
//     bid_px/ask_px   integer ticks
// Latency: 2 cycles.
module quote #(
    parameter int PX_W  = 32,
    parameter int FRAC  = 16,
    parameter int SIG_W = 32
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 in_valid,
    input  logic [PX_W+FRAC-1:0] fv,
    input  logic [SIG_W-1:0]     sigma,
    input  logic [31:0]          k,          // Q16.16

    output logic                 out_valid,
    output logic [PX_W-1:0]      bid_px,
    output logic [PX_W-1:0]      ask_px
);

    localparam int FV_W = PX_W + FRAC;
    localparam int KS_W = SIG_W + 16;          // k*sigma after dropping the extra 16 fraction bits
    localparam int SW   = FV_W + 3;            // signed working width: fv + ks + 0xFFFF can reach ~2^49, plus a sign bit
    localparam int TW   = SW - FRAC;           // integer-tick working width

    // ---- stage 1: half-width k * sigma ----
    //   sigma (Q16.16) * k (Q16.16) = Q32.32   (multiplying adds the fraction bits)
    //   >> 16 brings it back to Q.16, the same as fv, so the two can be added
    logic [SIG_W+31:0] ks_full;          // Q32.32
    assign ks_full = sigma * k;

    logic            s1_valid;
    logic [FV_W-1:0] s1_fv;
    logic [KS_W-1:0] s1_ks;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_fv    <= '0;
            s1_ks    <= '0;
        end else begin
            s1_valid <= in_valid;
            s1_fv    <= fv;
            s1_ks    <= ks_full[SIG_W+31:16];     // >> 16 -> Q.16
        end
    end

    // ---- stage 2: FV -/+ k*sigma, round outward, saturate ----
    logic signed [SW-1:0] lo, hi;
    logic [TW-1:0]        bid_t, ask_t;
    logic [PX_W-1:0]      bid_n, ask_n;

    always_comb begin
        lo = $signed({2'b00, s1_fv}) - $signed({{(SW-KS_W){1'b0}}, s1_ks});
        hi = $signed({2'b00, s1_fv}) + $signed({{(SW-KS_W){1'b0}}, s1_ks})
           + $signed({{(SW-FRAC){1'b0}}, {FRAC{1'b1}}});      // + (1 - LSB) -> ceil

        bid_t = lo[SW-1] ? '0 : lo[SW-1:FRAC];                // floor, clamp at 0
        ask_t = hi[SW-1:FRAC];
        if (ask_t <= bid_t) ask_t = bid_t + 1'b1;

        bid_n = (|bid_t[TW-1:PX_W]) ? '1 : bid_t[PX_W-1:0];
        ask_n = (|ask_t[TW-1:PX_W]) ? '1 : ask_t[PX_W-1:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            bid_px    <= '0;
            ask_px    <= '0;
        end else begin
            out_valid <= s1_valid;
            if (s1_valid) begin
                bid_px <= bid_n;
                ask_px <= ask_n;
            end
        end
    end

endmodule
