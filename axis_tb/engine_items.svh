// ============================================================================
// engine_items.svh -- the transactions
// ============================================================================
// What gets carried around between classes. A tick is generated (so it is
// randomizable); a quote is observed (so it is plain data).
// ============================================================================


// One randomizable tick. It has to be a class: constraints and randomize()
// only exist on classes.
class tick_item;
    rand book_e     book;
    rand bit [31:0] bid, ask;
    rand bit [31:0] bid_sz, ask_sz;
    rand int        gap;             // idle cycles before this tick

    // set by the test before randomizing
    int crossed_pct = 10;
    int max_gap     = 8;

    // crossed_pct is a knob because the overflow test wants more of them;
    // a locked book just has to turn up sometimes, so its weight is fixed.
    constraint c_book {
        book dist { BOOK_NORMAL  := 100 - crossed_pct,
                    BOOK_CROSSED := crossed_pct,
                    BOOK_LOCKED  := 5 };
    }

    // Prices stay in a narrow band so the EMA inside the core settles and
    // sigma becomes non-zero. Fully random 32-bit prices would look like
    // noise and never exercise the quote path properly.
    constraint c_prices {
        bid inside {[32'd900 : 32'd1100]};
        if      (book == BOOK_NORMAL) ask inside {[bid + 1 : bid + 3]};
        else if (book == BOOK_LOCKED) ask == bid;
        else                          ask inside {[bid - 3 : bid - 1]};
    }

    // Size zero is a special case in the microprice block (it falls back
    // to the mid price), so it gets its own weight.
    //
    // `:/` not `:=` on the range. `:=` gives its weight to EVERY value in a
    // range, so `[1:5000] := 90` was 5000 x 90 = 450,000 against zero's 10,
    // and zero came out about once in 45,000 ticks -- 0 times in 800.
    // `:/` divides the weight across the range: zero really is 10%.
    // (Found by the coverage report: cp_bid_sz.zero and cp_ask_sz.zero at 0.)
    constraint c_sizes {
        bid_sz dist { 0 := 10, [1:5000] :/ 90 };
        ask_sz dist { 0 := 10, [1:5000] :/ 90 };
    }

    // gap == 0 means back-to-back ticks, which is what fills the FIFO.
    // `inside` sets the legal range; `dist` only biases within it.
    // `:/` for the same reason as c_sizes: zero gaps are really 60%.
    constraint c_gap {
        gap inside {[0 : max_gap]};
        gap dist { 0 := 60, [1:8] :/ 40 };
    }

    function bit [127:0] pack();
        return {bid, ask, bid_sz, ask_sz};
    endfunction

    // The reverse, used by the monitor to rebuild a tick from the bus.
    function void unpack(bit [127:0] d);
        bid    = d[127:96];
        ask    = d[95:64];
        bid_sz = d[63:32];
        ask_sz = d[31:0];
        if      (ask >  bid) book = BOOK_NORMAL;
        else if (ask == bid) book = BOOK_LOCKED;
        else                 book = BOOK_CROSSED;
    endfunction
endclass


// One quote. Plain data, nothing random -- quotes are observed, never
// generated.
class quote_item;
    bit [31:0] bid, ask;

    // only filled in by core_monitor, which can see the FIFO
    bit        dropped;      // the FIFO was full, so the DUT threw it away
    int        fifo_count;

    function bit [63:0] pack();
        return {bid, ask};
    endfunction
endclass
