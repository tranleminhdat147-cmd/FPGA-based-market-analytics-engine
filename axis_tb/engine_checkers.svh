// ============================================================================
// engine_checkers.svh -- the scoreboard
// ============================================================================
// The scoreboard says whether the DUT was RIGHT.
// Coverage says whether the test was WORTH RUNNING. (Coverage lives in the
// monitors in this testbench, next to the variables it samples.)
//
// Like tick_sequence, this class has no `vif` handle -- it is pure software
// and never touches a pin or a clock. It is driven entirely by two mailboxes.
// ============================================================================


// A FIFO is in-order by construction, so comparing head to head is the right
// check: it catches corruption, duplication AND reordering in one comparison.
class scoreboard;
    mailbox #(quote_item) expected_mb;
    mailbox #(quote_item) actual_mb;

    bit [63:0] expected [$];

    int unsigned n_produced    = 0;   // quotes the core made
    int unsigned n_dropped_exp = 0;   // ...of which we expect the DUT to drop
    int unsigned n_received    = 0;   // quotes seen on m_axis
    int unsigned n_matched     = 0;
    int unsigned errors        = 0;

    function new(mailbox #(quote_item) expected_mb,
                 mailbox #(quote_item) actual_mb);
        this.expected_mb = expected_mb;
        this.actual_mb   = actual_mb;
    endfunction

    task run();
        fork
            collect_expected();
            check_actual();
        join_none
    endtask

    // One end of the comparison: remember what should come out.
    task collect_expected();
        quote_item q;
        forever begin
            expected_mb.get(q);
            n_produced++;
            if (q.dropped) n_dropped_exp++;             // never coming out
            else           expected.push_back(q.pack()); // must come out, in order
        end
    endtask

    // The other end: check what did.
    //
    // These two tasks race at every clock edge and it does not matter: a
    // quote written into the FIFO this cycle cannot also be read out this
    // cycle, so anything arriving here was pushed on an earlier edge and is
    // already in the queue. push_back at the tail never disturbs pop_front
    // at the head.
    task check_actual();
        quote_item q;
        bit [63:0] exp;
        forever begin
            actual_mb.get(q);
            n_received++;

            if (expected.size() == 0) begin
                errors++;
                $display("FAIL: m_axis produced %0d/%0d, but the core never made it",
                         q.bid, q.ask);
            end
            else begin
                exp = expected.pop_front();
                if (q.pack() !== exp) begin
                    errors++;
                    $display("FAIL: wrong quote on m_axis");
                    $display("        expected %0d / %0d", exp[63:32], exp[31:0]);
                    $display("        got      %0d / %0d", q.bid, q.ask);
                end
                else n_matched++;
            end
        end
    endtask

    // The last two checks, once everything has drained.
    function void final_check(bit [31:0] dut_dropped);
        if (expected.size() != 0) begin
            errors++;
            $display("FAIL: %0d quotes went into the FIFO and never came out",
                     expected.size());
        end
        if (n_dropped_exp !== dut_dropped) begin
            errors++;
            $display("FAIL: dropped-quote count: DUT says %0d, we counted %0d",
                     dut_dropped, n_dropped_exp);
        end
    endfunction
endclass
