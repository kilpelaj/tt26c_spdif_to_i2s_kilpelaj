// ---------------------------------------------------------------------------
// spdif_rx
//
// S/PDIF (AES3 consumer) receiver front-end.
//
// Recovers the embedded clock from a biphase-mark-coded (BMC) S/PDIF stream by
// oversampling the input with a free-running system clock, measures the unit
// interval (UI), decodes the BMC data, detects the B/M/W sub-frame preambles
// and re-assembles the 24-bit L/R audio samples.
//
// The recovered unit-interval length (in system-clock cycles) is exported on
// ui_period so a downstream block can regenerate a rate-matched bit clock.
//
// Timing background (one AES3 sub-frame = 32 time slots = 64 UI):
//   - A logic bit occupies one bit-cell = 2 UI. BMC guarantees a transition at
//     every cell boundary and an extra mid-cell transition for a '1'.
//       -> a '0' produces one 2T interval (M)
//       -> a '1' produces two 1T intervals (S,S)
//   - Preambles violate BMC with a 3T interval (L) which never occurs in data,
//     giving a unique sync marker. Run-length patterns (in UI):
//       Z/B : 3,1,1,3   block start,  sub-frame A (left)
//       X/M : 3,3,1,1                 sub-frame A (left)
//       Y/W : 3,2,1,2                 sub-frame B (right)
//     The second interval alone identifies the preamble: S->B, L->M, M->W.
//
// Clock requirement: the system clock must oversample the UI by a comfortable
// margin (>= ~8x recommended). e.g. 100 MHz supports up to 96 kHz cleanly,
// higher clocks are needed for 192 kHz.
// ---------------------------------------------------------------------------
module spdif_rx #(
    parameter int SAMPLE_W   = 24,  // audio sample width (bits)
    parameter int CNT_W      = 16,  // pulse-width counter width
    parameter int BOOT_TRANS = 64,  // transitions measured to seed the UI
    parameter int GLITCH_MIN = 2,   // pulses shorter than this are ignored
    parameter int ERR_LIMIT  = 4    // consecutive errors before full re-lock
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      spdif_in,

    output logic [SAMPLE_W-1:0]       sample_l,     // left  (sub-frame A)
    output logic [SAMPLE_W-1:0]       sample_r,     // right (sub-frame B)
    output logic                      sample_valid, // 1-cycle strobe, L/R pair
    output logic                      locked,       // decoder is synchronised
    output logic [CNT_W-1:0]          ui_period,    // measured 1T in clk cycles

    output logic                      block_start   // 1-cycle strobe on Z/B
);

    // ---- input synchroniser + edge detector ------------------------------
    logic s0, s1, s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
        end else begin
            s0 <= spdif_in;
            s1 <= s0;
            s2 <= s1;
        end
    end
    wire edge_det = s1 ^ s2;

    // ---- pulse-width counter ----------------------------------------------
    logic [CNT_W-1:0] cnt;
    localparam logic [CNT_W-1:0] CNT_MAX = '1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          cnt <= '0;
        else if (edge_det)   cnt <= 1;                                // start new pulse
        else if (cnt != CNT_MAX) cnt <= cnt + 1'b1;                   // saturate
    end
    // width of the pulse that just ended (valid in the cycle edge_det is high)
    wire [CNT_W-1:0] cur_width = cnt;

    // ---- symbol classification vs the measured UI -------------------------
    logic [CNT_W-1:0] t_est;
    // CNT_W+2 bits: 2.5*t_est must not overflow even when t_est = CNT_MAX
    // (which it is at reset / re-boot before the UI is tracked down).
    wire [CNT_W+1:0] t_ext   = {2'b0, t_est};
    wire [CNT_W+1:0] thr_1_5 = t_ext + (t_ext >> 1);        // 1.5T
    wire [CNT_W+1:0] thr_2_5 = (t_ext << 1) + (t_ext >> 1); // 2.5T
    wire sym_s = ({2'b0, cur_width} <  thr_1_5);           // ~1T
    wire sym_l = ({2'b0, cur_width} >= thr_2_5);           // ~3T
    wire sym_m = ~sym_s & ~sym_l;                         // ~2T
    wire good_width = (cur_width >= GLITCH_MIN[CNT_W-1:0]);

    // ---- decoder FSM ------------------------------------------------------
    typedef enum logic [1:0] {S_BOOT, S_HUNT, S_PRE, S_DATA} state_t;
    state_t state;

    logic [$clog2(BOOT_TRANS+1)-1:0] boot_cnt;
    logic [1:0]              pre_cnt;    // preamble interval index (0..2)
    logic                    is_left;    // current sub-frame is channel A
    logic                    half;       // mid a '1' cell (saw first S)
    logic [4:0]              bit_idx;    // slot index within data (0..27)
    logic [SAMPLE_W-1:0]     sample_sr;  // audio being assembled (LSB first)
    logic [SAMPLE_W-1:0]     sample_l_r; // last completed left sample
    logic                    left_ready; // a left sample is waiting for its right
    logic [$clog2(ERR_LIMIT+1)-1:0] err_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_BOOT;
            t_est        <= CNT_MAX;      // start high, track the minimum down
            boot_cnt     <= BOOT_TRANS[$clog2(BOOT_TRANS+1)-1:0];
            pre_cnt      <= '0;
            is_left      <= 1'b0;
            half         <= 1'b0;
            bit_idx      <= '0;
            sample_sr    <= '0;
            sample_l_r   <= '0;
            left_ready   <= 1'b0;
            sample_valid <= 1'b0;
            locked       <= 1'b0;
            block_start  <= 1'b0;
            err_cnt      <= '0;
        end else begin
            // default: de-assert 1-cycle strobes
            sample_valid <= 1'b0;
            block_start  <= 1'b0;

            if (edge_det) begin
                // --- UI tracking: adapt towards short pulses -------------
                if (state == S_BOOT) begin
                    if (good_width && cur_width < t_est)
                        t_est <= cur_width;                // track minimum
                end else if (sym_s && good_width) begin
                    t_est <= t_est - (t_est >> 3) + (cur_width >> 3); // IIR
                end

                unique case (state)
                    // -------------------------------------------------------
                    S_BOOT: begin
                        if (good_width) begin
                            if (boot_cnt == 0) state <= S_HUNT;
                            else               boot_cnt <= boot_cnt - 1'b1;
                        end
                    end

                    // -------------------------------------------------------
                    S_HUNT: begin
                        if (sym_l) begin        // leading 3T = preamble pulse0
                            pre_cnt <= '0;
                            state   <= S_PRE;
                        end
                    end

                    // -------------------------------------------------------
                    S_PRE: begin
                        if (pre_cnt == 0) begin
                            // second interval identifies the preamble
                            is_left  <= sym_s | sym_l;      // S or L -> chan A
                            if (sym_s) block_start <= 1'b1; // S -> B (block start)
                        end
                        if (pre_cnt == 2) begin
                            // preamble consumed; align to first data cell
                            state     <= S_DATA;
                            half      <= 1'b0;
                            bit_idx   <= '0;
                            sample_sr <= '0;
                        end
                        pre_cnt <= pre_cnt + 1'b1;
                    end

                    // -------------------------------------------------------
                    S_DATA: begin
                        if (half == 1'b0) begin
                            if (sym_m) begin
                                commit_bit(1'b0);
                            end else if (sym_s) begin
                                half <= 1'b1;               // wait for 2nd S
                            end else begin
                                data_error();
                            end
                        end else begin
                            if (sym_s) begin
                                half <= 1'b0;
                                commit_bit(1'b1);
                            end else begin
                                data_error();
                            end
                        end
                    end
                endcase
            end
        end
    end

    // Delivered sample pair: valid during the sample_valid strobe. sample_l_r
    // holds the left sub-frame; sample_sr holds the just-completed right one.
    // Driving these combinationally avoids a second 24-bit register per channel.
    assign sample_l = sample_l_r;
    assign sample_r = sample_sr;

    // recovered UI is just the current estimate -- no extra pipeline register
    assign ui_period = t_est;

    // -- commit one decoded data bit into the current sub-frame -------------
    task automatic commit_bit(input logic b);
        // slots 4..27 : 24-bit audio, LSB first. Shift right, inserting at the
        // MSB, so the first (LSB) bit ends up at bit 0 -- no indexed bit-write.
        if (bit_idx < SAMPLE_W[4:0])
            sample_sr <= {b, sample_sr[SAMPLE_W-1:1]};

        if (bit_idx == 5'd27) begin
            // deliver the completed sub-frame. sample_l/sample_r are driven
            // combinationally (see below) from sample_l_r / sample_sr, which
            // are stable across the sample_valid strobe -- no extra output regs.
            if (is_left) begin
                sample_l_r <= sample_sr;
                left_ready <= 1'b1;
            end else begin
                if (left_ready) sample_valid <= 1'b1;
                left_ready <= 1'b0;
            end
            locked   <= 1'b1;
            err_cnt  <= '0;
            state    <= S_HUNT;             // next preamble follows immediately
            half     <= 1'b0;
        end else begin
            bit_idx <= bit_idx + 1'b1;
        end
    endtask

    // -- unexpected symbol inside data : drop lock / re-hunt ----------------
    task automatic data_error();
        left_ready <= 1'b0;
        half       <= 1'b0;
        if (err_cnt >= ERR_LIMIT[$clog2(ERR_LIMIT+1)-1:0]) begin
            locked   <= 1'b0;
            boot_cnt <= BOOT_TRANS[$clog2(BOOT_TRANS+1)-1:0];
            t_est    <= CNT_MAX;
            state    <= S_BOOT;
        end else begin
            err_cnt <= err_cnt + 1'b1;
            state   <= S_HUNT;
        end
    endtask

endmodule
