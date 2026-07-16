// ---------------------------------------------------------------------------
// spdif_to_i2s
//
// Top-level IP: converts an S/PDIF (AES3 consumer) input stream into an I2S
// master output. A single free-running system clock oversamples the incoming
// stream; all recovered timing is derived from it, so no external audio clock
// or PLL is required.
//
//   spdif_in --> [spdif_rx] --L/R samples + recovered UI--> [i2s_tx] --> I2S
//
// The I2S bit clock is regenerated from the recovered unit interval, keeping
// the output frame rate matched to the incoming sample rate across the
// supported range (32/44.1/48/88.2/96 kHz with a >=100 MHz system clock).
// ---------------------------------------------------------------------------
module spdif_to_i2s #(
    parameter int SAMPLE_W        = 24,   // audio sample width
    parameter int SLOT_W          = 32,   // I2S slot width (bits per channel)
    parameter int CNT_W           = 16,   // internal timing-counter width
    parameter int DFLT_UI          = 16,  // divider used before the decoder locks
    parameter bit EN_PWM           = 1'b1, // generate the mono PWM audio output
    parameter int PWM_W            = 8     // PWM resolution
) (
    input  logic                clk,        // free-running oversampling clock
    input  logic                rst_n,

    input  logic                spdif_in,   // S/PDIF serial input

    output logic                i2s_bclk,    // I2S bit clock
    output logic                i2s_ws,      // I2S word select (LRCK)
    output logic                i2s_sd,      // I2S serial data

    output logic                mute,        // high when silent/no signal (amp standby)
    output logic                locked,      // decoder synchronised to stream
    output logic                block_start, // AES3 channel-status block start
    output logic                pwm_out      // mono (L+R)/2 PWM audio (RC-filter to analog)
);

    logic [SAMPLE_W-1:0] sample_l;
    logic [SAMPLE_W-1:0] sample_r;
    logic                sample_valid;
    logic [CNT_W-1:0]    ui_period;

    spdif_rx #(
        .SAMPLE_W  (SAMPLE_W),
        .CNT_W     (CNT_W)
    ) u_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .spdif_in     (spdif_in),
        .sample_l     (sample_l),
        .sample_r     (sample_r),
        .sample_valid (sample_valid),
        .locked       (locked),
        .ui_period    (ui_period),
        .block_start  (block_start)
    );

    i2s_tx #(
        .SAMPLE_W (SAMPLE_W),
        .SLOT_W   (SLOT_W),
        .CNT_W    (CNT_W),
        .DFLT_UI  (DFLT_UI)
    ) u_tx (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_l     (sample_l),
        .sample_r     (sample_r),
        .sample_valid (sample_valid),
        .locked       (locked),
        .ui_period    (ui_period),
        .i2s_bclk     (i2s_bclk),
        .i2s_ws       (i2s_ws),
        .i2s_sd       (i2s_sd)
    );

    mute_detect #(
        .SAMPLE_W (SAMPLE_W)
    ) u_mute (
        .clk          (clk),
        .rst_n        (rst_n),
        .locked       (locked),
        .sample_l     (sample_l),
        .sample_r     (sample_r),
        .sample_valid (sample_valid),
        .mute         (mute)
    );

    // ---- mono PWM audio output --------------------------------------------
    generate if (EN_PWM) begin : g_pwm
        // (L+R)/2 downmix: signed add (SAMPLE_W+1 bits) then drop the LSB.
        wire signed [SAMPLE_W:0] pwm_sum = $signed(sample_l) + $signed(sample_r);
        wire _unused_pwm_lsb = &{1'b0, pwm_sum[0]};   // LSB intentionally discarded by /2
        pwm_audio #(
            .SAMPLE_W (SAMPLE_W),
            .PWM_W    (PWM_W)
        ) u_pwm (
            .clk          (clk),
            .rst_n        (rst_n),
            .sample       (pwm_sum[SAMPLE_W:1]),
            .sample_valid (sample_valid),
            .pwm          (pwm_out)
        );
    end else begin : g_no_pwm
        assign pwm_out = 1'b0;
    end endgenerate

endmodule
