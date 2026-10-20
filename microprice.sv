// ============================================================================
// Microprice
// ============================================================================
// Formula:
//     mp = bid + (ask - bid) * w
//     w  = bid_sz / T              where T = bid_sz + ask_sz
//
// The division trick:
//     write T = m * 2^p            (1 <= m < 2, p = position of T's leading 1)
//     so    1/T = (1/m) * 2^(-p)
//     -> 1/m comes from a lookup table (LUT)
//     -> 2^(-p) is just a right shift by p
//
// Fixed point, "Qa.b" = a whole bits, b fraction bits, real value = stored / 2^b.
// Everything with a fraction uses 16 fraction bits (stored = real * 65536):
//     bid, ask        Q32.0   whole ticks
//     spread          Q32.0   ask - bid, SIGNED (negative = crossed book)
//     bid_sz, ask_sz  Q32.0   whole units
//     R  (LUT)        Q0.16   1/m              e.g. 41,930 = 0.6398
//     w               Q1.16   bid_sz / T       e.g. 49,152 = 0.75  (1 whole bit only so 1.0 = 65,536 fits)
//     mp              Q32.16  ticks            e.g. 65,634,304 = 1001.5
//
// Pipeline, one stage per clock cycle (latency 4, a new tick can enter every cycle):
//     stage 1: T, p, LUT index, spread
//     stage 2: read the LUT -> R = 1/m
//     stage 3: w  = (bid_sz * R) >> p
//     stage 4: mp = bid + spread * w
// ============================================================================
module microprice (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [31:0] bid,         // Q32.0
    input  logic [31:0] ask,         // Q32.0
    input  logic [31:0] bid_sz,      // Q32.0
    input  logic [31:0] ask_sz,      // Q32.0

    output logic        out_valid,
    output logic [47:0] mp           // Q32.16
);

    // ------------------------------------------------------------------------
    // The lookup table: 1024 slots covering m from 1.0 to 2.0
    //
    //   slot i covers m = 1 + i/1024  up to  1 + (i+1)/1024
    //   it stores 1/m at the MIDDLE of the slot, in Q0.16 (times 2^16):
    //
    //       R[i] = 2^16 / (1 + (i + 0.5)/1024)
    //            = 2^27 / (2049 + 2*i)          <- same value, integer math only
    //
    //   R goes from 65,504 (m near 1, 1/m near 1.0) down to 32,776 (m near 2,
    //   1/m near 0.5): 16 bits. This runs once when the design is built.
    // ------------------------------------------------------------------------
    logic [15:0] recip_lut [0:1023];     // Q0.16

    initial begin
        for (int i = 0; i < 1024; i++)
            recip_lut[i] = ((1 << 27) + (2049 + 2*i) / 2) / (2049 + 2*i);   // "+ d/2" rounds to nearest
    end

    // ------------------------------------------------------------------------
    // valid travels down the pipeline alongside the data, one stage per cycle
    // ------------------------------------------------------------------------
    logic s1_valid, s2_valid, s3_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            s3_valid  <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            s1_valid  <= in_valid;
            s2_valid  <= s1_valid;
            s3_valid  <= s2_valid;
            out_valid <= s3_valid;
        end
    end

    // ========================================================================
    // STAGE 1: T, p, LUT index, spread
    // ========================================================================

    // T needs 33 bits: two 32-bit sizes can add up to 2^33 - 2
    logic [32:0] T;                      // Q33.0
    assign T = bid_sz + ask_sz;

    // p = position of T's leading 1 (0 .. 32), a "priority encoder".
    // The loop goes from bit 0 up, so the HIGHEST 1 is the last one to write p.
    // In hardware the loop becomes parallel logic: all 33 bits are checked at
    // the same time, not one per cycle.
    logic [5:0] p;
    always_comb begin
        p = 6'd0;                        // T = 1, or T = 0 (handled separately below)
        for (int i = 0; i < 33; i++)
            if (T[i]) p = i;
    end

    // Slide T left so its leading 1 lands on bit 32.
    // Zeros come in from the right: that's the "padding", it doesn't change m.
    //   e.g. T = 400 (leading 1 at bit 8): shift left by 32 - 8 = 24
    logic [32:0] T_shifted;
    assign T_shifted = T << (6'd32 - p);

    // The 10 bits right below the leading 1 are m's fraction = the LUT slot.
    //   e.g. T = 400 = 1_1001_0000 -> bits after the leading 1: 1001_0000, padded
    //        to 10 bits: 10_0100_0000 = 576
    logic [9:0] lut_index;
    assign lut_index = T_shifted[31:22];

    // spread = ask - bid, SIGNED: negative when the book is crossed (ask < bid).
    // The formula still works then: mp walks DOWN from bid toward ask.
    //   e.g. bid 1002, ask 1000, w 0.75 -> mp = 1002 + (-2)(0.75) = 1000.5
    //
    // Step 1: subtract in 33 bits. Two 32-bit prices can differ by up to
    //         +-(2^32 - 1), which doesn't fit 32 bits signed. {1'b0, x} adds a
    //         0 on top so the prices are read as positive numbers.
    logic signed [32:0] diff;
    assign diff = $signed({1'b0, ask}) - $signed({1'b0, bid});

    // Step 2: clamp to 32 bits signed. Real spreads are a few ticks, so this
    //         only ever triggers on garbage input, but it can't flip the sign.
    logic signed [31:0] spread;          // Q32.0, signed
    always_comb begin
        if      (diff > 33'sd2147483647)  spread = 32'sh7FFF_FFFF;   // +2^31 - 1
        else if (diff < -33'sd2147483648) spread = 32'sh8000_0000;   // -2^31
        else                              spread = diff[31:0];
    end

    // stage 1 registers
    logic [31:0]        s1_bid;
    logic signed [31:0] s1_spread;
    logic [31:0]        s1_bid_sz;
    logic [5:0]         s1_p;
    logic [9:0]         s1_lut_index;
    logic               s1_T_is_zero;

    always_ff @(posedge clk) begin
        s1_bid       <= bid;
        s1_spread    <= spread;
        s1_bid_sz    <= bid_sz;
        s1_p         <= p;
        s1_lut_index <= lut_index;
        s1_T_is_zero <= (T == 33'd0);
    end

    // ========================================================================
    // STAGE 2: read the LUT, R = 1/m
    // ========================================================================

    // Kept in its own block with no reset so Quartus puts the LUT in block RAM.
    logic [15:0] s2_R;                   // Q0.16

    always_ff @(posedge clk) begin
        s2_R <= recip_lut[s1_lut_index];
    end

    // pass the other values along to stay in step with s2_R
    logic [31:0]        s2_bid;
    logic signed [31:0] s2_spread;
    logic [31:0]        s2_bid_sz;
    logic [5:0]         s2_p;
    logic               s2_T_is_zero;

    always_ff @(posedge clk) begin
        s2_bid       <= s1_bid;
        s2_spread    <= s1_spread;
        s2_bid_sz    <= s1_bid_sz;
        s2_p         <= s1_p;
        s2_T_is_zero <= s1_T_is_zero;
    end

    // ========================================================================
    // STAGE 3: w = bid_sz / T = (bid_sz * R) >> p
    // ========================================================================
    //   bid_sz * R       = bid_sz * (1/m)            (Q32.0 * Q0.16 = Q32.16)
    //   >> p             = * 2^(-p), so bid_sz * (1/m) * 2^(-p) = bid_sz / T
    //   the 16 fraction bits from R stay, so w comes out in Q1.16
    //
    //   e.g. bid_sz 300, ask_sz 100: T = 400, p = 8, R = 41,930
    //        300 * 41,930 = 12,579,000, >> 8 = 49,136 -> 49,136 / 65,536 = 0.7498

    logic [47:0] bid_sz_times_R;         // Q32.16 (32 bits * 16 bits = 48 bits)
    assign bid_sz_times_R = s2_bid_sz * s2_R;

    logic [47:0] w_calc;                 // Q32.16, but always <= ~1.0 here
    assign w_calc = bid_sz_times_R >> s2_p;

    logic [31:0]        s3_bid;
    logic signed [31:0] s3_spread;
    logic [16:0]        s3_w;            // Q1.16

    always_ff @(posedge clk) begin
        s3_bid    <= s2_bid;
        s3_spread <= s2_spread;

        if (s2_T_is_zero)
            s3_w <= 17'd32768;           // empty book: w = 0.5 -> plain mid price
        else if (w_calc > 48'd65536)
            s3_w <= 17'd65536;           // "clamp": the LUT can round w a hair above 1.0
                                         //   when nearly all size is on the bid; cut it to 1.0
        else
            s3_w <= w_calc[16:0];
    end

    // ========================================================================
    // STAGE 4: mp = bid + spread * w
    // ========================================================================
    //   spread * w       Q32.0 * Q1.16 = Q.16      (already 16 fraction bits)
    //   {bid, 16'd0}     bid with 16 zeros appended = bid * 65536 = Q32.16
    //   both have 16 fraction bits, so they can be added directly.
    //
    //   spread is signed, so the multiply must be signed too. w is always
    //   positive, but a signed 17-bit number with its top bit set reads as
    //   negative (65536 = 1.0 would become -65536), so {1'b0, w} adds a 0
    //   sign bit first.

    logic signed [49:0] spread_times_w;  // Q34.16, signed (32 bits * 18 bits = 50 bits)
    assign spread_times_w = s3_spread * $signed({1'b0, s3_w});

    logic signed [49:0] mp_calc;         // Q34.16, signed
    assign mp_calc = $signed({2'b00, s3_bid, 16'd0}) + spread_times_w;

    always_ff @(posedge clk) begin
        // mp always lies between bid and ask, so it's >= 0 and fits Q32.16
        mp <= mp_calc[47:0];
    end

endmodule
