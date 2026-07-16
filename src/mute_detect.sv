// ---------------------------------------------------------------------------
// mute_detect
//
// Drives the `mute` output used for amplifier enable/standby
// (amp_enable = ~mute). Mute is asserted when either:
//   * the decoder is not locked (no valid S/PDIF stream, e.g. cable removed);
//   * the audio is digital silence (both channels exactly zero).
//
// Silence is evaluated per audio frame with no timer and no hysteresis: the
// mute delay and the de-bounce between tracks are handled off-chip by an
// analog comparator on the recovered audio, so only the instantaneous
// silence/lock condition is produced here.
// ---------------------------------------------------------------------------
module mute_detect #(
    parameter int SAMPLE_W = 24    // audio sample width
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                locked,
    input  logic [SAMPLE_W-1:0] sample_l,
    input  logic [SAMPLE_W-1:0] sample_r,
    input  logic                sample_valid,
    output logic                mute
);

    // latch the current frame's silence (both channels exactly zero)
    logic silent;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)            silent <= 1'b1;
        else if (sample_valid) silent <= (sample_l == '0) && (sample_r == '0);
    end

    assign mute = ~locked | silent;

endmodule
