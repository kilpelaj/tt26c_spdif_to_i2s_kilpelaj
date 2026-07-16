// ---------------------------------------------------------------------------
// i2s_tx
//
// I2S (Philips standard) master transmitter.
//
// Generates a continuous bit clock (BCLK) and word-select (WS/LRCK) and shifts
// out left/right samples, MSB first, with the customary one-BCLK delay between
// a WS edge and the MSB of the corresponding channel. Data changes on the
// falling edge of BCLK and is sampled by the receiver on the rising edge.
//
// The bit clock is produced by a divider whose half-period equals the recovered
// S/PDIF unit interval (ui_period, in system-clock cycles). With SLOT_W = 32
// there are 64 BCLKs per audio frame; an S/PDIF frame spans 128 UI, so
//   BCLK period = 2 * UI  ->  BCLK half-period = 1 UI = ui_period cycles.
// This keeps the I2S frame rate matched to the incoming audio rate.
//
// Sample hand-off uses a one-deep double buffer: sample_valid latches the new
// pair, which is adopted at the next frame boundary. If the average UI estimate
// drifts slightly, a frame is occasionally repeated (under-run) rather than
// producing torn data.
// ---------------------------------------------------------------------------
module i2s_tx #(
    parameter int SAMPLE_W = 24,          // input sample width
    parameter int SLOT_W   = 32,          // I2S slot width (bits per channel)
    parameter int CNT_W    = 16,          // ui_period width
    parameter int DFLT_UI  = 16           // divider used before lock
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [SAMPLE_W-1:0]   sample_l,
    input  logic [SAMPLE_W-1:0]   sample_r,
    input  logic                  sample_valid,
    input  logic                  locked,
    input  logic [CNT_W-1:0]      ui_period,

    output logic                  i2s_bclk,
    output logic                  i2s_ws,
    output logic                  i2s_sd
);

    localparam int FRAME_W = 2 * SLOT_W;                // bits per stereo frame
    localparam int BCW     = $clog2(FRAME_W);
    localparam logic [BCW-1:0] LAST_BIT = BCW'(FRAME_W - 1); // last bit index

    // ---- double buffer ----------------------------------------------------
    logic [SAMPLE_W-1:0] next_l, next_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_l <= '0;
            next_r <= '0;
        end else if (sample_valid) begin
            next_l <= sample_l;
            next_r <= sample_r;
        end
    end

    // ---- bit-clock divider ------------------------------------------------
    // half-period (in clk cycles) = the recovered UI once locked, else the safe
    // pre-lock default. DFLT_UI is only a pre-lock divider: it must not clamp a
    // legitimately small locked UI (that would run BCLK too slow and drop
    // samples at high rates, e.g. 96 kHz where ui_period < DFLT_UI). The only
    // constraint while locked is a non-zero divider.
    wire [CNT_W-1:0] half_period =
        (locked && ui_period != '0) ? ui_period : DFLT_UI[CNT_W-1:0];

    logic [CNT_W-1:0] div_cnt;
    logic             bclk;
    logic             fall_tick;          // pulses when BCLK goes high->low
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= '0;
            bclk      <= 1'b0;
            fall_tick <= 1'b0;
        end else begin
            fall_tick <= 1'b0;
            if (div_cnt >= half_period - 1'b1) begin
                div_cnt <= '0;
                bclk    <= ~bclk;
                if (bclk) fall_tick <= 1'b1;   // was high -> now falling
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    // ---- shift / word-select generation -----------------------------------
    localparam int AUD_W  = 2 * SAMPLE_W;              // audio bits per frame
    localparam int SLOT_BW = $clog2(SLOT_W);          // slot-position width

    logic [BCW-1:0]     bcnt;              // bit index within frame (0..63)
    logic [AUD_W-1:0]   frame_word;        // {left_audio, right_audio}, MSB first

    // audio bits occupy the top SAMPLE_W of each SLOT_W slot; the rest is pad.
    wire in_audio = (bcnt[SLOT_BW-1:0] < SAMPLE_W[SLOT_BW-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bcnt       <= '0;
            frame_word <= '0;
            i2s_sd     <= 1'b0;
            i2s_ws     <= 1'b0;
        end else if (fall_tick) begin
            // Serialise the 48 audio bits with a shift register, emitting the
            // left-justified pad zeros without storing them. Output the audio
            // MSB during the audio phase (else 0); shift only on audio bits so
            // the register pauses across the pad; reload at the wrap point.
            i2s_sd <= in_audio ? frame_word[AUD_W-1] : 1'b0;
            if (bcnt == LAST_BIT)
                frame_word <= {next_l, next_r};
            else if (in_audio)
                frame_word <= {frame_word[AUD_W-2:0], 1'b0};

            // WS leads the data MSB by one BCLK: assert for the slot that
            // *starts* next. (bcnt+1) mod FRAME_W >= SLOT_W  -> right channel.
            i2s_ws <= (((bcnt + 1'b1) & LAST_BIT) >= SLOT_W[BCW-1:0]);

            bcnt <= bcnt + 1'b1;            // wraps naturally at FRAME_W
        end
    end

    assign i2s_bclk = bclk;

endmodule
