// ---------------------------------------------------------------------------
// spdif_to_i2s_tb
//
// Self-checking testbench for the Tiny Tapeout wrapped design. It drives the
// tt_um_kilpelaj_spdif2i2s top through its chip pins (exactly as the template
// tb.v wraps it), so it verifies what actually reaches silicon:
//   * a behavioural S/PDIF (biphase-mark) encoder drives spdif_in = ui_in[0]
//     with known stereo samples (correct B/M/W preambles, parity, block start);
//   * a behavioural I2S receiver decodes uo_out[2:0] (bclk/ws/sd) back into
//     samples and the decoded stream is aligned and compared;
//   * mute (uo_out[3]), locked (uo_out[4]) and block_start (uo_out[5]) are
//     checked on the observable pins.
//
// Timing: system clk = 50 MHz (20 ns, the Tiny Tapeout default); S/PDIF
// UI = 160 ns (8 clk cycles), i.e. Fs = 1/(128*160ns) ~= 48.8 kHz -- an
// integer UI (bit-exact) at ~8x oversampling, the real on-chip operating point.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module spdif_to_i2s_tb;

    localparam int  SAMPLE_W = 24;
    localparam int  SLOT_W   = 32;
    localparam real CLK_NS   = 20.0;    // 50 MHz Tiny Tapeout clock
    localparam real UI_NS    = 160.0;   // 8 clk cycles per unit interval
    localparam int  NFRAMES  = 300;

    // preamble selector
    localparam int PRE_B = 0;   // block start, channel A (left)
    localparam int PRE_M = 1;   // channel A (left)
    localparam int PRE_W = 2;   // channel B (right)

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic spdif_in = 1'b0;

    always #(CLK_NS/2.0) clk = ~clk;

    // ---- DUT: the Tiny Tapeout wrapped top, driven through its pins --------
    logic [7:0] uo_out;
    logic [7:0] uio_out, uio_oe;

`ifdef GL_TEST
    // Power pins are inout in the gate netlist, so they must be driven from
    // nets (continuous assignment), not tied to literals.
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
`endif

    tt_um_kilpelaj_spdif2i2s dut (
`ifdef GL_TEST
        .VPWR    (VPWR),
        .VGND    (VGND),
`endif
        .ui_in   ({7'b0, spdif_in}),
        .uo_out  (uo_out),
        .uio_in  (8'b0),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .ena     (1'b1),
        .clk     (clk),
        .rst_n   (rst_n)
    );

    // named views of the output pins (see the pin map in src/project.v)
    wire i2s_bclk    = uo_out[0];
    wire i2s_ws      = uo_out[1];
    wire i2s_sd      = uo_out[2];
    wire mute        = uo_out[3];
    wire locked      = uo_out[4];
    wire block_start = uo_out[5];
    wire pwm         = uo_out[7];

    // =======================================================================
    // S/PDIF biphase-mark encoder
    // =======================================================================
    logic tx_level = 1'b0;

    // toggle the line and hold the new level for n unit intervals
    task automatic hold_run(input int n);
        tx_level = ~tx_level;
        spdif_in = tx_level;
        #(n * UI_NS);
    endtask

    // one BMC data bit: '0' = one 2T interval, '1' = two 1T intervals
    task automatic send_bit(input logic b);
        if (b) begin
            hold_run(1);
            hold_run(1);
        end else begin
            hold_run(2);
        end
    endtask

    // one 32-slot sub-frame: preamble + 24b audio (LSB first) + V,U,C,P
    task automatic send_sub(input int pre,
                            input logic [SAMPLE_W-1:0] audio,
                            input logic v, input logic u, input logic c);
        logic p;
        int   k;
        case (pre)
            PRE_B: begin hold_run(3); hold_run(1); hold_run(1); hold_run(3); end
            PRE_M: begin hold_run(3); hold_run(3); hold_run(1); hold_run(1); end
            default: begin hold_run(3); hold_run(2); hold_run(1); hold_run(2); end
        endcase
        for (k = 0; k < SAMPLE_W; k++) send_bit(audio[k]);
        send_bit(v);
        send_bit(u);
        send_bit(c);
        p = (^audio) ^ v ^ u ^ c;   // even parity over slots 4..31
        send_bit(p);
    endtask

    // reference of what was transmitted
    logic [SAMPLE_W-1:0] sent_l [$];
    logic [SAMPLE_W-1:0] sent_r [$];

    // global frame index (drives the block-start preamble every 192 frames)
    int fi = 0;

    // send one stereo frame (A/left + B/right sub-frames) and log it
    task automatic send_audio_frame(input logic [SAMPLE_W-1:0] lv,
                                    input logic [SAMPLE_W-1:0] rv);
        int preL;
        preL = (fi % 192 == 0) ? PRE_B : PRE_M;
        send_sub(preL,  lv, 1'b0, 1'b0, fi[0]);
        send_sub(PRE_W, rv, 1'b0, 1'b0, 1'b0);
        sent_l.push_back(lv);
        sent_r.push_back(rv);
        fi++;
    endtask

    // mute checker
    int mute_fails = 0;
    task automatic check_mute(input logic exp, input string tag);
        if (mute !== exp) begin
            mute_fails++;
            $display("  MUTE FAIL [%s]: mute=%b expected=%b", tag, mute, exp);
        end else begin
            $display("  mute OK   [%s]: mute=%b", tag, mute);
        end
    endtask

    // =======================================================================
    // I2S receiver (decodes DUT output back to samples)
    // =======================================================================
    logic [SLOT_W-1:0]   sh = '0;
    logic                ws_d = 1'b0;
    logic                got_l = 1'b0;
    logic [SAMPLE_W-1:0] last_l = '0;
    logic [SAMPLE_W-1:0] dec_l [$];
    logic [SAMPLE_W-1:0] dec_r [$];

    always @(posedge i2s_bclk) begin
        logic [SAMPLE_W-1:0] smp;
        sh = {sh[SLOT_W-2:0], i2s_sd};       // MSB first
        if (i2s_ws !== ws_d) begin           // word-select edge: finalize channel
            smp = sh[SLOT_W-1 -: SAMPLE_W];  // top bits = left-justified sample
            if (ws_d == 1'b0) begin          // just finished the left slot
                last_l = smp;
                got_l  = 1'b1;
            end else begin                   // just finished the right slot
                if (got_l) begin
                    dec_l.push_back(last_l);
                    dec_r.push_back(smp);
                    got_l = 1'b0;
                end
            end
            ws_d = i2s_ws;
        end
    end

    int block_starts = 0;
    always @(posedge clk) if (block_start) block_starts++;

    // =======================================================================
    // Stimulus + checks
    // =======================================================================
    int i, off, j;
    bit found;
    int mismatches;
    int pwm_high;

    initial begin
        $dumpfile("tb.fst");
        $dumpvars(0, spdif_to_i2s_tb);

        rst_n = 1'b0;
        spdif_in = 1'b0;
        #(20 * CLK_NS);
        rst_n = 1'b1;
        #3;                                  // de-align edges from the clock grid

        // before any stream is decoded the output must be muted (amp off)
        check_mute(1'b1, "pre-lock / no signal");

        // ---- audio present -----------------------------------------------
        for (i = 0; i < NFRAMES; i++)
            send_audio_frame(24'h100000 + i[SAMPLE_W-1:0],
                             24'h200000 + i[SAMPLE_W-1:0]);
        #(10 * UI_NS);
        check_mute(1'b0, "audio present");

        // ---- PWM audio check: hold a known DC level, measure the duty ----
        // L=R=0x400000 -> (L+R)/2=0x400000 -> offset-binary top 8 bits = 0xC0,
        // i.e. 75% duty. With the /2 prescaler the PWM period is 512 clocks, so
        // over 2048 clocks (4 periods) the pin is high 0.75*2048 = 1536.
        for (i = 0; i < 16; i++) send_audio_frame(24'h400000, 24'h400000);
        pwm_high = 0;
        for (i = 0; i < 2048; i++) begin @(posedge clk); if (pwm) pwm_high++; end
        $display("PWM duty          = %0d/2048 (expected 1536 = 75%%)", pwm_high);
        if (pwm_high < 1528 || pwm_high > 1544)
            $fatal(1, "FAIL: PWM duty %0d/2048 out of range (expected ~1536)", pwm_high);

        #(200 * UI_NS);                      // flush the I2S pipeline

        // ---- report ------------------------------------------------------
        $display("--------------------------------------------------------");
        $display("locked            = %0d", locked);
        $display("frames sent       = %0d", sent_l.size());
        $display("frames decoded    = %0d", dec_l.size());
        $display("block_start count = %0d (expected ~%0d)",
                 block_starts, NFRAMES / 192);
        $display("mute check fails  = %0d", mute_fails);

        if (!locked)              $fatal(1, "FAIL: decoder never locked");
        if (mute_fails != 0)      $fatal(1, "FAIL: mute output misbehaved");
        if (dec_l.size() < 64)    $fatal(1, "FAIL: too few decoded frames");
        if (block_starts < 1)     $fatal(1, "FAIL: no block_start seen");

        // ---- align decoded stream to the sent stream ---------------------
        // skip the first few (startup) decoded frames, then find the sent
        // index that matches, and verify a run of consecutive frames.
        found = 1'b0;
        for (off = 0; off < sent_l.size() - 40 && !found; off++) begin
            if (dec_l[8] == sent_l[off] && dec_r[8] == sent_r[off])
                found = 1'b1;
        end
        if (!found) $fatal(1, "FAIL: could not align decoded stream to sent");
        off = off - 1;
        $display("alignment: decoded[8] == sent[%0d]", off);

        mismatches = 0;
        for (j = 0; j < 32; j++) begin
            if (dec_l[8+j] !== sent_l[off+j] || dec_r[8+j] !== sent_r[off+j]) begin
                mismatches++;
                $display("  MISMATCH j=%0d  dec=(%h,%h)  sent=(%h,%h)",
                         j, dec_l[8+j], dec_r[8+j], sent_l[off+j], sent_r[off+j]);
            end
        end

        if (mismatches != 0)
            $fatal(1, "FAIL: %0d/32 sample mismatches", mismatches);

        $display("PASS: 32 consecutive L/R samples decoded correctly");
        $display("--------------------------------------------------------");
        $finish;
    end

    // watchdog
    initial begin
        #(NFRAMES * 300 * UI_NS + 100000);
        $fatal(1, "FAIL: timeout");
    end

endmodule
