// ---------------------------------------------------------------------------
// pwm_audio
//
// Simple PWM audio DAC: turns a signed audio sample into a 1-bit pulse-width-
// modulated output whose duty cycle is proportional to the sample amplitude.
// Feed the pin through an RC low-pass (e.g. 1 kOhm + 100 nF) to recover analog
// audio, optionally into a small amplifier.
//
// The top PWM_W bits of the sample drive the duty cycle in offset-binary form
// (the sign bit is inverted), so digital silence (0) maps to mid-scale (50%
// duty) -- no DC step on mute/silence.
//
// A prescaler advances the PWM every 2**CLK_DIV_LOG2 clocks, so the output's
// minimum pulse width is 2**CLK_DIV_LOG2 clocks and its fastest edge rate is
// f_clk / 2**(CLK_DIV_LOG2+1). This keeps the pin within a slower GPIO pad's
// maximum toggle frequency. At 50 MHz with CLK_DIV_LOG2=1 the edge rate is
// <= 25 MHz (pad-safe for f_max ~33 MHz) and the carrier is f_clk /
// 2**(CLK_DIV_LOG2+PWM_W) ~= 98 kHz -- still well above the audio band.
// ---------------------------------------------------------------------------
module pwm_audio #(
    parameter int SAMPLE_W     = 24,   // input sample width
    parameter int PWM_W        = 8,    // PWM resolution
    parameter int CLK_DIV_LOG2 = 1     // advance PWM every 2**this clocks
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic [SAMPLE_W-1:0] sample,       // signed 2's complement
    input  logic                sample_valid, // latch a new sample
    output logic                pwm
);

    // Duty level: invert the sign bit (signed -> offset binary) and keep the
    // top PWM_W bits. Latched per audio frame (any clock), held between updates.
    logic [PWM_W-1:0] level;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            level <= {1'b1, {(PWM_W-1){1'b0}}};        // mid-scale = silence
        else if (sample_valid)
            level <= {~sample[SAMPLE_W-1], sample[SAMPLE_W-2 -: (PWM_W-1)]};
    end

    // prescaler: one tick every 2**CLK_DIV_LOG2 clocks (caps the edge rate)
    logic tick;
    generate if (CLK_DIV_LOG2 <= 0) begin : g_notick
        assign tick = 1'b1;
    end else begin : g_pre
        logic [CLK_DIV_LOG2-1:0] pre;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) pre <= '0;
            else        pre <= pre + 1'b1;
        end
        assign tick = (pre == '1);
    end endgenerate

    // free-running carrier counter, advanced on the tick
    logic [PWM_W-1:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      cnt <= '0;
        else if (tick)   cnt <= cnt + 1'b1;
    end

    // duty proportional to level; output changes only on ticks so every pulse
    // is at least 2**CLK_DIV_LOG2 clocks wide (glitch-free, pad-rate limited).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)     pwm <= 1'b0;
        else if (tick)  pwm <= (cnt < level);
    end

endmodule
