// sigma = sqrt(variance), digit-by-digit (shift and subtract), one result
// bit per cycle:
//
//   for each pair of input bits, MSB first:
//     rem   = (rem << 2) | next_two_bits
//     trial = (root << 2) | 1
//     if (rem >= trial) { rem -= trial; root = (root << 1) | 1; }
//     else              {               root =  root << 1;      }
//
// Gives exactly floor(sqrt(x)). A square root HALVES the fraction bits:
// a Q32.32 input comes out as Q16.16. So the caller shifts a Q32.16
// variance left by 16 first (the mirror of "multiply, then >> 16"):
//     variance Q32.16  -> << 16 -> Q32.32 -> sqrt -> sigma Q16.16
//
// Iterative is fine because the variance only changes once per bar,
// thousands of cycles apart. A start while busy is ignored.
// `root` holds the last result until the next one is done.
// Latency: IN_W/2 + 2 cycles.
module sigma_sqrt #(
    parameter int IN_W = 64   // must be even
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic              in_valid,
    input  logic [IN_W-1:0]   x,

    output logic              out_valid,
    output logic [IN_W/2-1:0] root
);

    localparam int OW = IN_W / 2;
    localparam int RM = OW + 3;          // remainder width, rem <= 2*root fits OW+1 bits, plus 2 shifted-in bits
    localparam int CW = $clog2(OW + 1);

    logic          busy;
    logic [CW-1:0] cnt;
    logic [IN_W-1:0] xs;                 // remaining input bits, MSB first
    logic [RM-1:0] rem;
    logic [OW-1:0] q;

    logic [RM-1:0] rem_sh, trial;

    assign rem_sh = {rem[RM-3:0], xs[IN_W-1 -: 2]};
    assign trial  = {q, 2'b01};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            cnt       <= '0;
            xs        <= '0;
            rem       <= '0;
            q         <= '0;
            out_valid <= 1'b0;
            root      <= '0;
        end else begin
            out_valid <= 1'b0;
            if (!busy) begin
                if (in_valid) begin
                    busy <= 1'b1;
                    cnt  <= CW'(OW);
                    xs   <= x;
                    rem  <= '0;
                    q    <= '0;
                end
            end else if (cnt != 0) begin
                xs  <= xs << 2;
                cnt <= cnt - 1'b1;
                if (rem_sh >= trial) begin
                    rem <= rem_sh - trial;
                    q   <= {q[OW-2:0], 1'b1};
                end else begin
                    rem <= rem_sh;
                    q   <= {q[OW-2:0], 1'b0};
                end
            end else begin
                busy      <= 1'b0;
                out_valid <= 1'b1;
                root      <= q;
            end
        end
    end

endmodule
