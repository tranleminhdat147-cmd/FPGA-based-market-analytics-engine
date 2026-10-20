// Math core of the market-analytics engine: everything in the diagram
// between the deframer (UART RX) and UART TX.
//
//   tick -> microprice -> fair value EMA -------------------> quote -> out
//                              |                                ^
//                              v                                |
//              bar -> return^2 -> variance EMA -> sigma sqrt ---+
//
// Fixed-point formats: EVERY fractional value has FRAC = 16 fraction bits.
//   bid, ask, sizes     Q32.0   integer ticks / units
//   microprice, fv      Q32.16  ticks
//   |return|            Q16.16  ticks     (saturates at 65,536 ticks per bar)
//   r2, variance        Q32.16  ticks^2
//   sigma               Q16.16  ticks
//   quote_k             Q16.16  sigmas
//   quote bid/ask out   Q32.0   integer ticks
//
// Two rules keep it that way:
//   after a multiply      >> 16   (16 + 16 = 32 fraction bits -> back to 16)
//   before a square root  << 16   (sqrt halves the fraction bits: 32 -> 16)
//
// Tick-to-quote latency: 4 (microprice) + 1 (EMA) + 2 (quote) = 7 cycles.
module analytics_core #(
    parameter int PX_W = 32,
    parameter int SZ_W = 32,   // must match microprice (32-bit sizes)
    parameter int FRAC = 16,
    parameter int TS_W = 64
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // one top-of-book update from the deframer
    input  logic                 tick_valid,
    input  logic [PX_W-1:0]      bid,
    input  logic [PX_W-1:0]      ask,
    input  logic [SZ_W-1:0]      bid_sz,
    input  logic [SZ_W-1:0]      ask_sz,

    // config
    input  logic [4:0]           fv_k,        // fair-value EMA alpha = 2^-fv_k
    input  logic [4:0]           var_k,       // variance EMA alpha = 2^-var_k
    input  logic [31:0]          quote_k,     // quote half-width in sigmas, Q16.16 (2.0 = 32'h0002_0000)
    input  logic [31:0]          bar_period,  // cycles per time bar, 0 = off

    // results, toward UART TX
    output logic                 quote_valid,
    output logic [PX_W-1:0]      quote_bid,
    output logic [PX_W-1:0]      quote_ask,
    output logic [PX_W+FRAC-1:0] fv,
    output logic [2*FRAC-1:0]    sigma,
    output logic [TS_W-1:0]      ts
);

    localparam int FV_W  = PX_W + FRAC;
    localparam int RET_W = 2 * FRAC;      // return magnitude width, Q(FRAC).(FRAC)

    timestamp #(.TS_W(TS_W)) u_ts (.clk(clk), .rst_n(rst_n), .ts(ts));

    // ---- fair-value path ----
    logic            mp_valid;
    logic [FV_W-1:0] mp;

    microprice u_mp (   // fixed 32-bit prices, 32-bit sizes, 16 fraction bits
        .clk(clk), .rst_n(rst_n),
        .in_valid(tick_valid), .bid(bid), .ask(ask), .bid_sz(bid_sz), .ask_sz(ask_sz),
        .out_valid(mp_valid), .mp(mp)
    );

    logic                fv_valid;
    logic signed [FV_W:0] fv_s;

    ema #(.W(FV_W + 1)) u_fv_ema (
        .clk(clk), .rst_n(rst_n),
        .in_valid(mp_valid), .x({1'b0, mp}), .k(fv_k),
        .out_valid(fv_valid), .y(fv_s)
    );

    assign fv = fv_s[FV_W-1:0];

    logic fv_ok;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        fv_ok <= 1'b0;
        else if (fv_valid) fv_ok <= 1'b1;
    end

    // ---- volatility path ----
    logic bar_tick;

    bar_trigger u_bar (.clk(clk), .rst_n(rst_n), .period(bar_period), .bar_tick(bar_tick));

    localparam int VAR_W = 2*RET_W - FRAC;    // 48 bits, Q32.16 -- same width as fv

    logic             r2_valid;
    logic [VAR_W-1:0] r2;                     // Q32.16

    return_sq #(.FV_W(FV_W), .RET_W(RET_W), .FRAC(FRAC)) u_ret (
        .clk(clk), .rst_n(rst_n),
        .bar_tick(bar_tick), .fv_ok(fv_ok), .fv(fv),
        .out_valid(r2_valid), .r2(r2)
    );

    // same EMA, same width as the fair-value one
    logic                  var_valid;
    logic signed [VAR_W:0] var_s;             // Q32.16 plus a sign bit

    ema #(.W(VAR_W + 1)) u_var_ema (
        .clk(clk), .rst_n(rst_n),
        .in_valid(r2_valid), .x({1'b0, r2}), .k(var_k),
        .out_valid(var_valid), .y(var_s)
    );

    // sqrt halves the fraction bits, so << 16 first: Q32.16 -> Q32.32 -> sqrt -> Q16.16
    sigma_sqrt #(.IN_W(VAR_W + FRAC)) u_sigma (
        .clk(clk), .rst_n(rst_n),
        .in_valid(var_valid), .x({var_s[VAR_W-1:0], {FRAC{1'b0}}}),
        .out_valid(), .root(sigma)
    );

    // ---- quote: uses the newest fair value with the latest sigma ----
    quote #(.PX_W(PX_W), .FRAC(FRAC), .SIG_W(2*FRAC)) u_quote (
        .clk(clk), .rst_n(rst_n),
        .in_valid(fv_valid), .fv(fv), .sigma(sigma), .k(quote_k),
        .out_valid(quote_valid), .bid_px(quote_bid), .ask_px(quote_ask)
    );

endmodule
