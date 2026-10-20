// AXI4-Stream wrapper around analytics_core.
//
//   ticks in  : AXI4-Stream slave   s_axis_*   tdata = {bid, ask, bid_sz, ask_sz}
//   quotes out: AXI4-Stream master  m_axis_*   tdata = {quote_bid, quote_ask}
//
// Input:  tready is always 1, the engine can take a tick every cycle.
// Output: a small FIFO holds quotes until the receiver is ready
//         (if the FIFO is full, new quotes are dropped and counted).
module analytics_core_axis #(
    parameter int FIFO_DEPTH = 16          // power of 2
)(
    input  logic         aclk,
    input  logic         aresetn,

    // AXI4-Stream slave: ticks in
    input  logic [127:0] s_axis_tdata,     // [127:96] bid, [95:64] ask, [63:32] bid_sz, [31:0] ask_sz
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,

    // AXI4-Stream master: quotes out
    output logic [63:0]  m_axis_tdata,     // [63:32] quote_bid, [31:0] quote_ask
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,

    // settings (plain wires for now)
    input  logic [4:0]   fv_k,
    input  logic [4:0]   var_k,
    input  logic [31:0]  quote_k,          // Q16.16, 2.0 = 32'h0002_0000
    input  logic [31:0]  bar_period,

    output logic [31:0]  dropped_quotes    // quotes lost because the FIFO was full
);

    // ---------------- input side ----------------
    assign s_axis_tready = 1'b1;           // always ready

    logic        quote_valid;
    logic [31:0] quote_bid, quote_ask;

    analytics_core u_core (
        .clk(aclk), .rst_n(aresetn),
        .tick_valid(s_axis_tvalid && s_axis_tready),     // AXI rule: transfer = tvalid AND tready
        .bid   (s_axis_tdata[127:96]),
        .ask   (s_axis_tdata[95:64]),
        .bid_sz(s_axis_tdata[63:32]),
        .ask_sz(s_axis_tdata[31:0]),
        .fv_k(fv_k), .var_k(var_k), .quote_k(quote_k), .bar_period(bar_period),
        .quote_valid(quote_valid), .quote_bid(quote_bid), .quote_ask(quote_ask),
        .fv(), .sigma(), .ts()
    );

    // ---------------- output side: FIFO ----------------
    localparam int AW = $clog2(FIFO_DEPTH);

    logic [63:0] mem [0:FIFO_DEPTH-1];
    logic [AW:0] wr_ptr, rd_ptr;           // one extra bit tells "full" apart from "empty"
    logic        empty, full;

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

    // write: every new quote goes in, unless the FIFO is full
    always_ff @(posedge aclk)
        if (quote_valid && !full) mem[wr_ptr[AW-1:0]] <= {quote_bid, quote_ask};

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_ptr         <= '0;
            dropped_quotes <= '0;
        end else if (quote_valid) begin
            if (!full) wr_ptr         <= wr_ptr + 1'b1;
            else       dropped_quotes <= dropped_quotes + 1'b1;
        end
    end

    // read: the oldest quote is shown on m_axis until the receiver takes it
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn)                           rd_ptr <= '0;
        else if (m_axis_tvalid && m_axis_tready) rd_ptr <= rd_ptr + 1'b1;
    end

    assign m_axis_tvalid = !empty;
    assign m_axis_tdata  = mem[rd_ptr[AW-1:0]];

endmodule
