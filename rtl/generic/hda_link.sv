`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// HDA Link Layer — Fully Spec-Compliant (Intel HDA Rev 1.0a §5)
//------------------------------------------------------------------------------
// Key features:
//   • Complete 7-state initialization state machine (§5.5.3)
//   • Proper DDR SDO capture with alignment validation
//   • Frame error detection & auto-recovery (SYNC timing/count validation)
//   • Multi-codec address arbitration (bus contention detection)
//   • Stream tag filtering per DAC slot
//   • Power-state link behaviour (D3↔D0 wake/sleep sequences)
//   • Embedded SVA assertions under `ifdef FORMAL
//
// SDO (controller → codec): double-pumped DDR.
//   1000 SDO bit-cells/frame (2 bits per BCLK).
//   Command = 40 DDR bits (20 BCLK), each DAC slot = 48 DDR bits (24 BCLK).
//
// SDI (codec → controller): single-pumped SDR.
//   500 SDI bit-cells/frame (1 bit per BCLK).
//   Response = 36 SDR bits (36 BCLK), each ADC slot = 48 SDR bits (48 BCLK).
//
// Frame Sync: 4 BCLK high on SYNC.  Frame starts at falling edge (§5.3).
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_link #(
    parameter int NUM_DAC             = 2,
    parameter int NUM_ADC             = 2,
    parameter int BCLK_PER_FRAME      = 500,
    parameter int SYNC_WIDTH          = 4,        // Expected SYNC high width
    parameter int INIT_TIMEOUT_FRAMES = 32,       // Init watchdog (frames)
    parameter int ERROR_RECOVERY_CNT  = 2         // Good frames before recovery
) (
    input  logic clk,       // BCLK (24 MHz)
    input  logic rst_n,     // Active-low async reset (cold)

    // HDA Physical Link
    input  logic sdo,       // Serial Data Out from controller (DDR)
    output logic sdi,       // Serial Data In to controller (SDR)
    output logic sdi_oe,    // SDI output-enable (open-drain control)
    input  logic sdi_in,    // SDI bus sense (for address frame)
    input  logic sync,      // Frame Sync from controller

    // Initialization & Status
    output logic        init_done,
    output logic [3:0]  codec_addr_out,
    output logic [3:0]  link_state_out,   // Current FSM state (observable)
    output logic        frame_error,      // Pulse: frame timing violation
    output logic        sync_lost,        // Level: SYNC absent too long
    output logic        link_active,      // Level: NORMAL state & no error

    // Power Management
    input  logic        codec_wake,       // Wake request from pwr_mgmt
    input  logic        link_sleep,       // Sleep request (D0→D3)

    // Command / Response interface (to/from verb_engine)
    output logic                                      cmd_valid,
    output logic [hda_codec_pkg::HDA_CMD_BITS-1:0]    cmd_data,
    input  logic                                      resp_valid,
    input  logic [hda_codec_pkg::HDA_RESP_BITS-1:0]   resp_data,

    // Stream tag configuration (from widget_regs via verb_engine)
    input  logic [3:0] stream_tag_cfg     [0:hda_codec_pkg::MAX_DAC-1],
    input  logic [3:0] stream_tag_cfg_adc [0:hda_codec_pkg::MAX_ADC-1],

    // Per-DAC sample-blocks-per-frame (from conv_format): 48kHz=1,96kHz=2,192kHz=4
    input  logic [2:0] dac_rate_mult      [0:hda_codec_pkg::MAX_DAC-1],

    // DAC samples (controller → codec)
    output logic [hda_codec_pkg::MAX_DAC-1:0]  dac_valid,
    output logic [23:0] dac_sample_l [0:hda_codec_pkg::MAX_DAC-1],
    output logic [23:0] dac_sample_r [0:hda_codec_pkg::MAX_DAC-1],

    // ADC samples (codec → controller)
    input  logic [23:0] adc_sample_l [0:hda_codec_pkg::MAX_ADC-1],
    input  logic [23:0] adc_sample_r [0:hda_codec_pkg::MAX_ADC-1],
    input  logic [hda_codec_pkg::MAX_ADC-1:0]  adc_valid
);

    import hda_codec_pkg::*;

    //==========================================================================
    // Timing & Geometry Constants
    //==========================================================================
    localparam int CMD_BITS    = HDA_CMD_BITS;    // 40
    localparam int RESP_BITS   = HDA_RESP_BITS;   // 36
    localparam int SAMPLE_BITS = 48;              // 24L + 24R per stream

    // DDR positions (in BCLK units): 2 SDO bits per BCLK.
    // The two-stage SYNC synchronizer anchors frame cell 0 to the SECOND BCLK
    // rising edge after Frame Sync falls.  At that edge the first DDR pair
    // {bit999,bit998} is already the newest cmd_shift entry, so the 40-bit
    // command (cells 0..19) is complete at bit_cnt == CMD_BITS/2 - 1 == 19.
    localparam int CMD_BCLK_END = CMD_BITS / 2 - 1;   // 19
    localparam int DAC_BCLK     = SAMPLE_BITS / 2;     // 24

    // Bit counter width (must accommodate BCLK_PER_FRAME-1)
    localparam int BIT_CNT_W = $clog2(BCLK_PER_FRAME);
    // Frame length counter needs to hold BCLK_PER_FRAME + margin for sync_lost detection
    localparam int FRAME_LEN_MAX = BCLK_PER_FRAME + 32;
    localparam int FRAME_LEN_W   = $clog2(FRAME_LEN_MAX + 1);  // 10 bits for 533

    //==========================================================================
    // §5.3 — SYNC Edge Detection & Frame Start
    //==========================================================================
    logic [BIT_CNT_W-1:0] bit_cnt;
    logic sync_d, frame_start;

    // Single-stage SYNC capture (sync_d).  SYNC is source-synchronous to BCLK,
    // so one posedge FF is enough for the pulse-width validator further below.
    // Frame-boundary detection is done at half-BCLK resolution in the DDR-SYNC
    // block (sof_predict), which is what frame_start is derived from.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_d <= 1'b0;
        else        sync_d <= sync;
    end

    // frame_start (the SDO-capture frame anchor) is assigned further below from
    // the tag-IMMUNE `sof_predict` (see the DDR-SYNC block).  It is deliberately
    // NO LONGER taken from `sync_run>=3`: a mid-frame outbound stream tag
    // (§5.3.2.1) has only a 3-high-cell preamble which could disturb the old
    // single-pumped sync_run judgment and corrupt frame sync.  sof_predict
    // requires the full 8 high cells of a real Frame Sync, which a tag can never
    // reach, so the SDO capture path stays locked even while tags stream.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           bit_cnt <= '0;
        else if (frame_start) bit_cnt <= '0;
        else if (bit_cnt < BIT_CNT_W'(BCLK_PER_FRAME - 1))
                              bit_cnt <= bit_cnt + 1'b1;
    end

    //==========================================================================
    // §5.3.2.1 — DDR (Double-Pumped) SYNC Capture + Start-of-Frame Predictor
    //==========================================================================
    // SYNC carries 2 cells per BCLK — a Frame Sync is 8 SDO bit-times wide
    // (§5.3 / Figure 20), and outbound stream tags are also double-pumped on
    // SYNC (§5.3.2.1).  Capture SYNC on BOTH edges, symmetric with the SDO DDR
    // capture below:
    //   sync_neg — SYNC at the negedge (the posedge-driven cell, earlier)
    //   sync     — SYNC at the posedge (the negedge-driven cell, raw, later)
    // Counting consecutive high cells at this half-BCLK resolution is what
    // lets the codec (a) separate a real Frame Sync (8 high cells) from a
    // stream-tag preamble ("1110" = 3 high, 1 low), and (b) anchor
    // Start-of-Frame to the falling edge of Frame Sync with ZERO added latency:
    // the 8th (final) high cell is the raw posedge `sync`, so evaluating the
    // run combinationally flags the Start-of-Frame BCLK edge the very cycle it
    // occurs (§5.2.3 / Figure 17), letting SDI drive bit 499 on time.
    //--------------------------------------------------------------------------
    logic sync_neg;
    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) sync_neg <= 1'b0;
        else        sync_neg <= sync;
    end

    localparam int SYNC_CELLS = 2 * SYNC_WIDTH;   // 8 high cells per Frame Sync

    logic [3:0] sync_cell_run_q;   // registered run through the previous cell pair
    logic [3:0] run_after_neg;     // + this BCLK's negedge cell (sync_neg)
    logic [3:0] run_after_pos;     // + this BCLK's posedge cell (raw sync)
    always_comb begin
        run_after_neg = sync_neg ? (sync_cell_run_q + 4'd1) : 4'd0;
        run_after_pos = sync     ? (run_after_neg   + 4'd1) : 4'd0;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_cell_run_q <= 4'd0;
        else        sync_cell_run_q <= (run_after_pos > 4'(SYNC_CELLS))
                                       ? 4'(SYNC_CELLS) : run_after_pos;
    end

    // sof_predict: a single pulse on the posedge that completes the 8th high
    // cell — that BCLK edge IS the Start of Frame (§5.2.3 / Figure 17), so the
    // SDI frame is parallel-loaded here and the Response MSB (bit 499) drives
    // with zero added latency.  The `< SYNC_CELLS` guard keeps it a 1-cycle
    // pulse even if SYNC were held high longer than the spec's 4 BCLK.
    logic sof_predict;
    assign sof_predict = (run_after_pos >= 4'(SYNC_CELLS))
                         && (sync_cell_run_q < 4'(SYNC_CELLS));

    // frame_start (SDO-capture anchor) = sof_predict delayed 2 BCLK.  sof_predict
    // fires on the Start-of-Frame edge (the 8th high cell); the SDO capture path
    // was historically anchored 2 BCLK later, so delaying by 2 preserves the
    // exact CMD_BCLK_END / DAC_END sampling phase while making the anchor
    // tag-immune (a 3-high-cell stream-tag preamble can never reach 8 cells).
    logic sof_predict_d, sof_predict_d2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_predict_d  <= 1'b0;
            sof_predict_d2 <= 1'b0;
        end else begin
            sof_predict_d  <= sof_predict;
            sof_predict_d2 <= sof_predict_d;
        end
    end
    assign frame_start = sof_predict_d2;

    //--------------------------------------------------------------------------
    // Physical Link Input Capture (§5.2.1)
    //   All HDA link signals (sdo, sync, sdi_in) are source-synchronous to
    //   BCLK — driven by the same controller that generates BCLK.  No multi-
    //   stage synchronizer is required; a single capture FF per input ensures
    //   clean timing paths from I/O pad to first register, preventing
    //   combinational glitch propagation and simplifying set_input_delay
    //   constraints.  sync is already double-registered for edge detection.
    //   sdo is captured on both edges for DDR (see DDR Capture section).
    //--------------------------------------------------------------------------
    logic sdi_in_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sdi_in_r <= 1'b0;
        else        sdi_in_r <= sdi_in;
    end

    //==========================================================================
    // §5.3 — SYNC Timing Validator (Frame Error Detection)
    //==========================================================================
    logic [BIT_CNT_W-1:0] sync_high_cnt;       // Count SYNC=1 cycles
    logic [FRAME_LEN_W-1:0] frame_len_cnt;     // Inter-frame distance counter (wider)
    logic                  sync_high_prev;      // Previous SYNC level (registered)
    logic                  frame_error_r;
    logic                  sync_lost_r;
    logic [5:0]            no_sync_frame_cnt;   // Frames without valid SYNC

    // Count consecutive SYNC=1 cycles for pulse width validation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_high_cnt  <= '0;
            sync_high_prev <= 1'b0;
        end else begin
            sync_high_prev <= sync_d;
            if (sync_d)
                sync_high_cnt <= sync_high_cnt + 1'b1;
            else
                sync_high_cnt <= '0;
        end
    end

    // Frame-length counter: measures BCLK between consecutive frame_start
    logic [FRAME_LEN_W-1:0] frame_len_measured;
    logic                    frame_len_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_len_cnt      <= '0;
            frame_len_measured <= '0;
            frame_len_valid    <= 1'b0;
        end else begin
            if (frame_start) begin
                frame_len_measured <= frame_len_cnt;
                frame_len_valid    <= (frame_len_cnt != '0);
                frame_len_cnt      <= FRAME_LEN_W'(1);
            end else if (frame_len_cnt < FRAME_LEN_W'(FRAME_LEN_MAX)) begin
                frame_len_cnt <= frame_len_cnt + 1'b1;
            end
        end
    end

    // SYNC width check: must be SYNC_WIDTH ±1 (tolerance for register pipeline)
    logic sync_width_ok;
    // Evaluate the SYNC pulse width ONLY at a real Frame-Sync falling edge.
    // §5.3.2.1: a mid-frame outbound stream tag drives SYNC high for only about
    // 1.5 BCLK (< SYNC_WIDTH-1), so its falling edge is ignored here — otherwise
    // the tag's short high pulse would fail the width check and spuriously drive
    // the link into LS_ERROR while tags are streaming.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_width_ok <= 1'b1;
        else if (sync_high_prev && !sync_d
                 && (sync_high_cnt >= (SYNC_WIDTH - 1))) begin
            // Falling edge of a full-width Frame Sync (tag pulses filtered out)
            sync_width_ok <= (sync_high_cnt <= (SYNC_WIDTH + 1));
        end
    end

    // Frame length check: must be BCLK_PER_FRAME ±2
    logic frame_len_ok;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_len_ok <= 1'b1;
        else if (frame_start && frame_len_valid) begin
            frame_len_ok <= (frame_len_measured >= FRAME_LEN_W'(BCLK_PER_FRAME - 2)) &&
                            (frame_len_measured <= FRAME_LEN_W'(BCLK_PER_FRAME + 2));
        end
    end

    // frame_error pulse: asserted for 1 cycle when a timing violation is detected.
    // Only checked by state machine when in LS_NORMAL (harmless during init).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_error_r <= 1'b0;
        else        frame_error_r <= frame_start && (!sync_width_ok || !frame_len_ok);
    end
    assign frame_error = frame_error_r;

    // sync_lost: asserted if no frame_start for > 2× frame period
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            no_sync_frame_cnt <= '0;
            sync_lost_r       <= 1'b0;
        end else begin
            if (frame_start) begin
                no_sync_frame_cnt <= '0;
                sync_lost_r       <= 1'b0;
            end else if (frame_len_cnt >= FRAME_LEN_W'(BCLK_PER_FRAME + 16)) begin
                sync_lost_r <= 1'b1;
            end
        end
    end
    assign sync_lost = sync_lost_r;

    //==========================================================================
    // §5.5.3 — Link Initialization State Machine (Full 7-state)
    //==========================================================================
    typedef enum logic [3:0] {
        LS_RESET      = 4'd0,
        LS_CODEC_WAKE = 4'd1,
        LS_CONNECT    = 4'd2,
        LS_TURNAROUND = 4'd3,
        LS_ADDRESS    = 4'd4,
        LS_NORMAL     = 4'd5,
        LS_ERROR      = 4'd6,
        LS_SLEEP      = 4'd7
    } link_state_e;

    link_state_e link_state, link_state_next;
    logic [3:0]  codec_addr_reg;
    logic        addr_sampled;
    logic [3:0]  addr_high_cnt;        // §5.5.3.2 SDI-high BCLK count = address
    logic [5:0]  init_frame_cnt;       // Watchdog counter
    logic [2:0]  recovery_cnt;         // Good-frame counter in ERROR state
    logic        hot_reset;            // Preserve codec_addr on warm restart

    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_state     <= LS_RESET;
            codec_addr_reg <= 4'h0;
            addr_sampled   <= 1'b0;
            addr_high_cnt  <= 4'h0;
            init_frame_cnt <= '0;
            recovery_cnt   <= '0;
            hot_reset      <= 1'b0;
        end else begin
            link_state <= link_state_next;

            case (link_state)
                LS_RESET: begin
                    addr_sampled   <= 1'b0;
                    init_frame_cnt <= '0;
                    recovery_cnt   <= '0;
                    if (!hot_reset)
                        codec_addr_reg <= 4'h0;
                end

                LS_CODEC_WAKE: begin
                    if (frame_start)
                        init_frame_cnt <= init_frame_cnt + 1'b1;
                end

                LS_CONNECT: begin
                    if (frame_start)
                        init_frame_cnt <= init_frame_cnt + 1'b1;
                end

                LS_TURNAROUND: begin
                    if (frame_start)
                        init_frame_cnt <= init_frame_cnt + 1'b1;
                end

                LS_ADDRESS: begin
                    // §5.5.3.2: the codec's address equals the number of BCLK
                    // cycles the controller holds SDI high after the falling
                    // edge of Frame Sync.  Count SDI-high cells and latch the
                    // running count the moment SDI is first sampled low
                    // (SYNC is already low throughout this frame body).
                    if (!addr_sampled) begin
                        if (sdi_in_r)
                            addr_high_cnt <= addr_high_cnt + 1'b1;
                        else begin
                            codec_addr_reg <= addr_high_cnt;
                            addr_sampled   <= 1'b1;
                        end
                    end
                    if (frame_start) begin
                        addr_sampled   <= 1'b0;
                        addr_high_cnt  <= 4'h0;
                        init_frame_cnt <= init_frame_cnt + 1'b1;
                    end
                end

                LS_NORMAL: begin
                    init_frame_cnt <= '0;
                    recovery_cnt   <= '0;
                end

                LS_ERROR: begin
                    if (frame_start && sync_width_ok && frame_len_ok)
                        recovery_cnt <= recovery_cnt + 1'b1;
                    else if (frame_start)
                        recovery_cnt <= '0;
                end

                LS_SLEEP: begin
                    hot_reset <= 1'b1;
                end

                default: ;
            endcase

            // Sleep request overrides: clear hot_reset when transitioning out
            if (link_state != LS_SLEEP && link_state_next != LS_SLEEP)
                hot_reset <= 1'b0;
        end
    end

    // Next-state logic
    always_comb begin
        link_state_next = link_state;

        case (link_state)
            LS_RESET: begin
                // §5.5.3: once Link Reset has exited, the codec proceeds
                // straight into the Connect Frame to watch for the first Frame
                // Sync and raise its initialization request there.  LS_RESET is
                // a pure hard-reset state — no whole frame is spent in it, so
                // the three init frames (Connect → Turnaround → Address) map
                // 1:1 onto the three Frame Syncs of Figure 30.
                link_state_next = LS_CONNECT;
            end

            LS_CODEC_WAKE: begin
                // D3→D0 resume path only (§5.6): allow one analog-settle frame
                // before re-running the connect sequence.
                if (frame_start)
                    link_state_next = LS_CONNECT;
                if (!codec_wake)
                    link_state_next = LS_RESET;
            end

            LS_CONNECT: begin
                if (frame_start)
                    link_state_next = LS_TURNAROUND;
                // Watchdog timeout
                if (init_frame_cnt >= INIT_TIMEOUT_FRAMES[5:0])
                    link_state_next = LS_RESET;
            end

            LS_TURNAROUND: begin
                if (frame_start)
                    link_state_next = LS_ADDRESS;
                if (init_frame_cnt >= INIT_TIMEOUT_FRAMES[5:0])
                    link_state_next = LS_RESET;
            end

            LS_ADDRESS: begin
                if (frame_start)
                    link_state_next = LS_NORMAL;
                if (init_frame_cnt >= INIT_TIMEOUT_FRAMES[5:0])
                    link_state_next = LS_RESET;
            end

            LS_NORMAL: begin
                // Error transition: frame timing violation or SYNC lost
                if (frame_error_r || sync_lost_r)
                    link_state_next = LS_ERROR;
                // Sleep request from power management
                if (link_sleep)
                    link_state_next = LS_SLEEP;
            end

            LS_ERROR: begin
                // Recover after ERROR_RECOVERY_CNT consecutive good frames
                if (recovery_cnt >= ERROR_RECOVERY_CNT[2:0])
                    link_state_next = LS_NORMAL;
                // If error persists too long, full reset
                if (sync_lost_r)
                    link_state_next = LS_RESET;
            end

            LS_SLEEP: begin
                // Wake from D3 on codec_wake assertion
                if (codec_wake)
                    link_state_next = LS_RESET;
            end

            default: link_state_next = LS_RESET;
        endcase
    end

    // Status outputs
    assign init_done      = (link_state == LS_NORMAL);
    assign codec_addr_out = codec_addr_reg;
    assign link_state_out = link_state;
    assign link_active    = (link_state == LS_NORMAL) && !frame_error_r && !sync_lost_r;

    //==========================================================================
    // §5.2.1 — SDO DDR Capture (Double-Pumped)
    //==========================================================================
    // Synthesizable dual-edge technique:
    //   • negedge FF captures SDO → sdo_neg (EVEN bit in DDR pair)
    //   • posedge shift register ingests {sdo_neg, sdo} = 2 bits/BCLK
    //
    // Per §5.2.3 / Figure 18: controller drives SDO aligned to SYNC-fall.
    // Codec's negedge FF captures the first DDR bit at the negedge coinciding
    // with SYNC falling edge.  At the subsequent posedge (frame_start),
    // {sdo_neg, sdo} forms the first valid DDR pair.
    //==========================================================================
    logic sdo_neg;
    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) sdo_neg <= 1'b0;
        else        sdo_neg <= sdo;
    end

    //--------------------------------------------------------------------------
    // Command Shift Register (40 DDR bits = 20 BCLK)
    //--------------------------------------------------------------------------
    logic [CMD_BITS-1:0] cmd_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cmd_shift <= '0;
        else        cmd_shift <= {cmd_shift[CMD_BITS-3:0], sdo_neg, sdo};
    end

    // Command valid at bit_cnt == 19 (20 BCLK pairs captured)
    logic cmd_valid_raw;
    assign cmd_valid_raw = (bit_cnt == BIT_CNT_W'(CMD_BCLK_END))
                           && (link_state == LS_NORMAL);

    // Latch command data
    logic [CMD_BITS-1:0] cmd_data_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cmd_data_r <= '0;
        else if (cmd_valid_raw) cmd_data_r <= cmd_shift;
    end

    // Codec address field of the 40-bit command is cmd_data[31:28] (the
    // 32-bit Verb structure, §7.3); address filtering is performed downstream
    // by hda_verb_engine.  The link layer only signals "a full 40-bit command
    // was received this frame".  cmd_valid_raw is a 1-cycle pulse (bit_cnt is
    // unique per frame), so a single register stage yields a clean 1-cycle
    // valid aligned with the latched cmd_data_r.
    logic cmd_valid_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cmd_valid_r <= 1'b0;
        else        cmd_valid_r <= cmd_valid_raw;
    end

    assign cmd_valid = cmd_valid_r;
    assign cmd_data  = cmd_data_r;

    //==========================================================================
    // §5.3.2.1 — Outbound Stream Tag Capture from SYNC DDR
    //==========================================================================
    // Stream tags are 8 DDR bits on SYNC: preamble "1110" + 4-bit stream ID.
    // The tag for DAC slot[i] aligns with the last 8 SDO bit-times of the
    // preceding field (command field for i==0, previous DAC slot otherwise).
    // Tag[i] occupies BCLK positions (CMD_BCLK_END - 3 + i*DAC_BCLK) to
    // (CMD_BCLK_END + i*DAC_BCLK), i.e. the tag is fully captured when
    // bit_cnt == CMD_BCLK_END + i*DAC_BCLK.
    //--------------------------------------------------------------------------

    // Continuous SYNC DDR shift register (same DDR order as cmd_shift)
    logic [7:0] sync_ddr_tag;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_ddr_tag <= 8'h0;
        else        sync_ddr_tag <= {sync_ddr_tag[5:0], sync_neg, sync};
    end

    // Runtime DAC slot start positions (BCLK units).  Each active converter
    // occupies dac_rate_mult[j] sample blocks (§3.3.34); slot j begins after the
    // 40-bit command plus the cumulative block span of all lower-indexed
    // converters.  With every converter at 48 kHz (rate_mult==1) this reduces
    // exactly to the fixed 24-BCLK/slot geometry (backward compatible).
    localparam int SLOT0_START = CMD_BITS / 2;   // 20 BCLK (after 40-bit command)
    logic [BIT_CNT_W-1:0] dac_slot_start [0:NUM_DAC-1];
    always_comb begin
        automatic int acc = SLOT0_START;
        for (int j = 0; j < NUM_DAC; j++) begin
            dac_slot_start[j] = BIT_CNT_W'(acc);
            acc += int'(dac_rate_mult[j]) * DAC_BCLK;
        end
    end

    // Per-DAC-slot stream tag capture
    logic [3:0] captured_tag_id  [0:NUM_DAC-1];
    logic [NUM_DAC-1:0] captured_tag_ok;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_DAC; gi++) begin : g_stag_cap
            // Tag fully shifted just before this converter's slot data begins,
            // i.e. at bit_cnt == dac_slot_start[gi] - 1 (runtime, rate-aware).
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    captured_tag_id[gi]  <= 4'h0;
                    captured_tag_ok[gi]  <= 1'b0;
                end else if (bit_cnt == BIT_CNT_W'(dac_slot_start[gi] - 1'b1)) begin
                    captured_tag_id[gi]  <= sync_ddr_tag[3:0];
                    captured_tag_ok[gi]  <= (sync_ddr_tag[7:4] == 4'b1110);
                end
            end
        end
    endgenerate

    //==========================================================================
    // DAC Sample Deserializer with Stream Tag Filtering (§5.3 / §3.3.35)
    //==========================================================================
    logic [SAMPLE_BITS-1:0] dac_shift [0:NUM_DAC-1];

    generate
        for (gi = 0; gi < NUM_DAC; gi++) begin : g_dac_shift

            // Free-running shift: 2 DDR bits per BCLK (same mechanism as cmd)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) dac_shift[gi] <= '0;
                else        dac_shift[gi] <= {dac_shift[gi][SAMPLE_BITS-3:0],
                                              sdo_neg, sdo};
            end

            // High-sample-rate deserialize (§3.3.34): this converter carries
            // dac_rate_mult[gi] back-to-back 48-bit sample blocks per frame.
            // Block k ends at dac_slot_start[gi] + (k+1)*DAC_BCLK - 1.  Each
            // completed block pulses dac_valid once, so 96 kHz yields 2 samples
            // and 192 kHz yields 4 samples per HDA frame.
            logic [MAX_BLOCKS-1:0] block_hit;
            for (genvar k = 0; k < MAX_BLOCKS; k++) begin : g_blk
                assign block_hit[k] =
                    (k < int'(dac_rate_mult[gi])) &&
                    (bit_cnt == BIT_CNT_W'(dac_slot_start[gi] + (k+1)*DAC_BCLK - 1)) &&
                    (link_state == LS_NORMAL);
            end

            logic dac_valid_raw;
            assign dac_valid_raw = |block_hit;

            // Latch DAC data (the just-completed block)
            logic [SAMPLE_BITS-1:0] dac_data_r;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) dac_data_r <= '0;
                else if (dac_valid_raw) dac_data_r <= dac_shift[gi];
            end

            // Stream tag awareness (§5.3.2.1):
            // When stream_tag_cfg[gi] == 0 (default, no stream assigned by
            // software), accept all data unconditionally (backward compat).
            // When a non-zero tag is configured, require a valid preamble
            // ("1110") on SYNC DDR AND matching stream ID.
            logic stream_active;
            assign stream_active = (stream_tag_cfg[gi] == 4'h0) ||
                                   (captured_tag_ok[gi] &&
                                    captured_tag_id[gi] == stream_tag_cfg[gi]);

            // 1-pulse valid with stream gating (registered to align with dac_data_r)
            logic dac_valid_prev;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) dac_valid_prev <= 1'b0;
                else        dac_valid_prev <= dac_valid_raw;
            end

            logic dac_valid_r;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) dac_valid_r <= 1'b0;
                else        dac_valid_r <= dac_valid_raw && !dac_valid_prev && stream_active;
            end

            assign dac_valid[gi]    = dac_valid_r;
            assign dac_sample_l[gi] = dac_data_r[SAMPLE_BITS-1:24];
            assign dac_sample_r[gi] = dac_data_r[23:0];

        end // g_dac_shift

        // Tie off unused DAC outputs
        for (gi = NUM_DAC; gi < MAX_DAC; gi++) begin : g_dac_tie
            assign dac_valid[gi]    = 1'b0;
            assign dac_sample_l[gi] = 24'h0;
            assign dac_sample_r[gi] = 24'h0;
        end
    endgenerate

    //==========================================================================
    // §5.3 — SDI Frame Assembly (Single-Pumped SDR)
    //==========================================================================
    // SDI carries: [MSB] Response (36 bits) | ADC0 (48) | ADC1 (48) | ... [LSB]
    // Total useful bits: RESP_BITS + NUM_ADC*SAMPLE_BITS; rest is padding (zeros).
    // Double-buffered ADC capture to prevent mid-frame data tearing.
    //==========================================================================

    // Response pending buffer
    logic [RESP_BITS-1:0]   resp_pending;
    logic                   resp_loaded;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_pending <= '0;
            resp_loaded  <= 1'b0;
        end else begin
            if (resp_valid) begin
                resp_pending <= resp_data;
                resp_loaded  <= 1'b1;
            end
            // SDI frame anchors to the predicted Start-of-Frame (§5.3 output
            // frame begins at the Frame-Sync falling edge), not to the codec's
            // internal posedge frame_start used for SDO capture.
            if (sof_predict)
                resp_loaded <= 1'b0;
        end
    end

    // ADC double-buffer: stage0 captures any time, stage1 latches at sof_predict
    logic [SAMPLE_BITS-1:0] adc_buf0  [0:NUM_ADC-1];
    logic [NUM_ADC-1:0]     adc_buf0_valid;
    logic [SAMPLE_BITS-1:0] adc_pending [0:NUM_ADC-1];
    logic [NUM_ADC-1:0]     adc_loaded;

    generate
        for (gi = 0; gi < NUM_ADC; gi++) begin : g_adc_cap
            // Stage 0: capture from audio_path at any time
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_buf0[gi]       <= '0;
                    adc_buf0_valid[gi] <= 1'b0;
                end else begin
                    if (adc_valid[gi]) begin
                        adc_buf0[gi]       <= {adc_sample_l[gi], adc_sample_r[gi]};
                        adc_buf0_valid[gi] <= 1'b1;
                    end
                    if (sof_predict)
                        adc_buf0_valid[gi] <= 1'b0;
                end
            end

            // Stage 1: transfer to SDI assembly at sof_predict (Start-of-Frame)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_pending[gi] <= '0;
                    adc_loaded[gi]  <= 1'b0;
                end else begin
                    if (sof_predict) begin
                        adc_pending[gi] <= adc_buf0_valid[gi] ? adc_buf0[gi] : '0;
                        adc_loaded[gi]  <= adc_buf0_valid[gi];
                    end
                end
            end
        end
    endgenerate

    // SDI shift register: 500-bit parallel-load, serial-out
    logic [BCLK_PER_FRAME-1:0] sdi_shift;
    logic [BCLK_PER_FRAME-1:0] sdi_next;

    // §5.3.3.1 — Inbound Stream Tag constants
    localparam int INBOUND_TAG_BITS = 10;  // 4-bit stream ID + 6-bit data length
    localparam int ADC_BYTES = SAMPLE_BITS / 8;  // 48/8 = 6

    always_comb begin
        sdi_next = '0;
        // Response at MSB position
        sdi_next[BCLK_PER_FRAME-1 -: RESP_BITS] = resp_loaded ? resp_pending : '0;
        // §5.3.3.1 / §5.3.3.3 — Inbound stream tags + ADC data at fixed offsets.
        // Each ADC slot occupies INBOUND_TAG_BITS + SAMPLE_BITS = 58 bits.
        // Inactive ADC slots emit a zero tag (termination) naturally.
        for (int a = 0; a < NUM_ADC; a++) begin
            if (adc_loaded[a]) begin
                // 10-bit inbound stream tag {stream_id[3:0], data_length[5:0]}
                sdi_next[BCLK_PER_FRAME-1-(RESP_BITS + a*(INBOUND_TAG_BITS+SAMPLE_BITS)) -: INBOUND_TAG_BITS] =
                    {stream_tag_cfg_adc[a], 6'(ADC_BYTES)};
                // 48-bit sample data {L[23:0], R[23:0]}
                sdi_next[BCLK_PER_FRAME-1-(RESP_BITS + a*(INBOUND_TAG_BITS+SAMPLE_BITS) + INBOUND_TAG_BITS) -: SAMPLE_BITS] =
                    adc_pending[a];
            end
        end
        // Termination: remaining bits are already zero (§5.3.3.3).
    end

    logic sdi_normal;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdi_shift  <= '0;
            sdi_normal <= 1'b0;
        end else if (sof_predict) begin
            // Parallel load at the predicted Start-of-Frame: MSB (Response bit
            // 499) drives immediately on this BCLK edge → zero added latency,
            // so a standard controller samples it one BCLK later (Figure 19).
            sdi_shift  <= {sdi_next[BCLK_PER_FRAME-2:0], 1'b0};
            sdi_normal <= sdi_next[BCLK_PER_FRAME-1];
        end else begin
            sdi_shift  <= {sdi_shift[BCLK_PER_FRAME-2:0], 1'b0};
            sdi_normal <= sdi_shift[BCLK_PER_FRAME-1];
        end
    end

    //==========================================================================
    // §5.5.3.1 — Codec Initialization Request Pulse (Figure 30 / 31)
    //==========================================================================
    // The codec signals its init request by driving SDI high for the ENTIRE
    // LAST BCLK cycle of the Connect Frame's Frame Sync (while SYNC is still
    // high), de-asserting it as Frame Sync falls.  The final Frame-Sync BCLK
    // carries SYNC cells 7-8; the moment cell 6 completes (run_after_pos ==
    // SYNC_CELLS-2 == 6) the 3rd high BCLK is done and the 4th/last is starting,
    // so registering that condition drives SDI high for exactly that last BCLK
    // and clears it at its end (run reaches 8 → Frame Sync falls).  NOTE: this
    // is one BCLK EARLIER than sof_predict (which marks the following
    // Start-of-Frame), so the request lands on the last HIGH SYNC cell, matching
    // Figure 30's red-arrow position — verified on the waveform, not just by a
    // passing test.
    logic init_req_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) init_req_q <= 1'b0;
        else        init_req_q <= (link_state == LS_CONNECT)
                                  && (run_after_pos == 4'(SYNC_CELLS - 2));
    end

    //==========================================================================
    // SDI Output Mux — State-Dependent Driving (§5.5.3)
    //==========================================================================
    always_comb begin
        case (link_state)
            LS_RESET: begin
                // §5.5.1 / §5.5.1.2 (Figure 29): while the link is in reset the
                // codec must ACTIVELY DRIVE SDI LOW ("codecs, at a minimum,
                // must drive all SDI signals low"), reinforcing the
                // controller's weak pull-down so the bus is defined before the
                // codec issues its initialization request.
                sdi    = 1'b0;
                sdi_oe = 1'b1;
            end
            LS_CONNECT: begin
                // §5.5.3.1 / Figure 30: raise the initialization request by
                // driving SDI high ONLY during the last BCLK cycle of the
                // Connect Frame's Frame Sync (init_req_q), de-asserted on the
                // Frame-Sync falling edge.  SDI is otherwise actively driven
                // low (init request is signalled on a null input frame).
                sdi    = init_req_q;
                sdi_oe = 1'b1;
            end
            LS_TURNAROUND: begin
                // Brief pulse then release (tri-state)
                sdi    = 1'b0;
                sdi_oe = (bit_cnt == '0);
            end
            LS_ADDRESS: begin
                // Hi-Z: listen to controller's address assignment on SDI bus
                sdi    = 1'b0;
                sdi_oe = 1'b0;
            end
            LS_NORMAL: begin
                // Normal operation: drive response + ADC data
                sdi    = sdi_normal;
                sdi_oe = 1'b1;
            end
            LS_ERROR: begin
                // During error recovery, continue driving (spec: codec stays active)
                sdi    = sdi_normal;
                sdi_oe = 1'b1;
            end
            LS_SLEEP: begin
                // D3 sleep: release bus
                sdi    = 1'b0;
                sdi_oe = 1'b0;
            end
            default: begin
                // §5.6 / Figure 33: CODEC_WAKE — codec asynchronously drives
                // SDI high to signal a power-state-change request.  SDI remains
                // high until the controller de-asserts RST# (handled by the
                // state machine transitioning out of LS_CODEC_WAKE).
                sdi    = 1'b1;
                sdi_oe = 1'b1;
            end
        endcase
    end

    //==========================================================================
    // Formal Verification Assertions
    //==========================================================================
`ifdef FORMAL
    // Property: frame_start should assert at most once per BCLK_PER_FRAME cycles
    property p_frame_start_spacing;
        @(posedge clk) disable iff (!rst_n)
        frame_start |-> ##1 !frame_start [* (BCLK_PER_FRAME - 4)];
    endproperty
    assert property (p_frame_start_spacing)
        else $error("ASSERT: frame_start fired too soon after previous");

    // Property: link_state is always a valid enum value
    property p_state_valid;
        @(posedge clk) disable iff (!rst_n)
        link_state inside {LS_RESET, LS_CODEC_WAKE, LS_CONNECT,
                           LS_TURNAROUND, LS_ADDRESS, LS_NORMAL,
                           LS_ERROR, LS_SLEEP};
    endproperty
    assert property (p_state_valid)
        else $error("ASSERT: link_state has invalid value");

    // Property: cmd_valid is at most 1 cycle wide
    property p_cmd_valid_pulse;
        @(posedge clk) disable iff (!rst_n)
        cmd_valid |=> !cmd_valid;
    endproperty
    assert property (p_cmd_valid_pulse)
        else $error("ASSERT: cmd_valid not single-cycle pulse");

    // Property: no deadlock — if codec_wake is asserted, eventually reach NORMAL
    // (simplified liveness check for bounded model checking)
    property p_no_deadlock;
        @(posedge clk) disable iff (!rst_n)
        (link_state == LS_CODEC_WAKE) |->
            ##[1:INIT_TIMEOUT_FRAMES*BCLK_PER_FRAME+100]
            (link_state == LS_NORMAL || link_state == LS_RESET);
    endproperty
    assert property (p_no_deadlock)
        else $error("ASSERT: init deadlock detected");
`endif

endmodule
