`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Controller BFM (testbench-only)
//------------------------------------------------------------------------------
// Drives BCLK, SYNC, SDO; captures SDI.
//
// HDA Spec compliance:
//   SDO  — double-pumped (DDR): BFM drives a new bit on every BCLK edge.
//          Data launched with #1 delay after each edge so the DUT's opposite-
//          edge FF always captures the previous value (half-cycle setup).
//   SDI  — single-pumped (SDR): BFM samples on posedge only.
//   SYNC — Frame Sync = 4 BCLK high (§5.3).  Frame starts at falling edge.
//          Outbound stream tags (§5.3.2.1) driven DDR on SYNC during frame body.
//   Init — Connect / Turnaround / Address frames (§5.5.3).
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_ctrl_bfm #(
    parameter logic [3:0] TARGET_CODEC_ADDR = 4'h0
) (
    output logic clk,
    output logic rst_n,
    output logic sdo,
    input  logic sdi,
    output logic sdi_drv,
    output logic sdi_drv_oe,
    output logic sync,
    output logic pd_n,
    output logic link_init_done
);

    import hda_codec_pkg::*;

    localparam int BCLK_HZ        = 24_000_000;
    localparam int FRAME_HZ       = 48_000;
    localparam int BCLK_PER_FRAME = BCLK_HZ / FRAME_HZ;  // 500
    localparam int SYNC_BCLK      = 4;  // Frame Sync width (§5.3)

    //--------------------------------------------------------------------------
    // §5.3.2.1 — Outbound Stream Tag configuration
    //--------------------------------------------------------------------------
    // Set by test tasks before sending DAC data.  The SYNC driver reads these
    // to modulate SYNC DDR with stream tags during the frame body.
    logic [3:0] outbound_tag_id  [0:MAX_DAC-1];
    int         num_outbound_tags;

    initial begin
        num_outbound_tags = 0;
        for (int i = 0; i < MAX_DAC; i++) outbound_tag_id[i] = 4'h0;
    end

    // Clock: 24 MHz
    initial begin clk = 1'b0; forever #20.833ns clk = ~clk; end

    // Reset / power / initialization sequencing
    initial begin
        rst_n = 1'b0; pd_n = 1'b0; sdo = 1'b0; sync = 1'b0;
        sdi_drv = 1'b0; sdi_drv_oe = 1'b0; link_init_done = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1; pd_n = 1'b1;

        //--------------------------------------------------------------
        // HDA Codec Initialization (§5.5.3) — standard controller side
        //--------------------------------------------------------------
        @(posedge clk iff (sdi === 1'b1));   // Connect Frame: codec init request

        wait_frame_start();   // Connect  → Turnaround frame
        wait_frame_start();   // Turnaround → Address frame

        // Address Frame (§5.5.3.2)
        sdi_drv_oe = 1'b1;
        sdi_drv    = (TARGET_CODEC_ADDR != 0);
        for (int n = 0; n < TARGET_CODEC_ADDR; n++) @(posedge clk);
        sdi_drv = 1'b0;
        repeat (2) @(posedge clk);
        sdi_drv_oe = 1'b0;

        wait_frame_start();   // Address → Normal frame
        link_init_done = 1'b1;
        $display("[BFM] Link init done - codec address = %0d", TARGET_CODEC_ADDR);
    end

    //--------------------------------------------------------------------------
    // SYNC generation with outbound stream tag support (§5.3.2.1)
    //--------------------------------------------------------------------------
    // Tag positions (BCLK offset within the 496-BCLK frame body, 0-indexed):
    //   Tag[t] occupies 4 BCLK starting at body_bclk = 12 + t*24.
    //   (The first tag aligns with the last 8 SDO bit-times of the 40-bit
    //    command field; each DAC slot is 48 DDR bits = 24 BCLK.)
    // Empirically determined offset accounts for codec's sync_d + sync_run
    // pipeline: body_bclk 12-15 → codec captures tag at bit_cnt 16-19.
    //--------------------------------------------------------------------------
    localparam int TAG_BODY_BASE = 17;  // body BCLK offset of first tag start
    localparam int DAC_BCLK_SPAN = 24;  // 48 DDR bits / 2

    initial begin
        sync = 1'b0;
        wait (rst_n === 1'b1);
        @(posedge clk);
        forever begin
            // Frame Sync: 4 BCLK high (driven at posedge with #1 Tco)
            #1 sync = 1'b1;
            repeat (SYNC_BCLK) @(posedge clk);

            // Frame body: 496 BCLK.  Normally low, with optional stream tags.
            for (int bk = 0; bk < BCLK_PER_FRAME - SYNC_BCLK; bk++) begin
                // Check if this BCLK is inside a stream tag window
                bit in_tag;
                in_tag = 0;
                for (int t = 0; t < num_outbound_tags && !in_tag; t++) begin
                    int tstart;
                    tstart = TAG_BODY_BASE + t * DAC_BCLK_SPAN;
                    if (bk >= tstart && bk < tstart + 4) begin
                        logic [7:0] tag;
                        int toff;
                        int hi;
                        tag  = {4'b1110, outbound_tag_id[t]};  // preamble + ID
                        toff = bk - tstart;
                        hi   = 7 - toff * 2;
                        // Drive DDR pair on SYNC (same protocol as SDO DDR)
                        #1 sync = tag[hi];
                        @(negedge clk);
                        #1 sync = tag[hi - 1];
                        @(posedge clk);
                        in_tag = 1;
                    end
                end
                if (!in_tag) begin
                    #1 sync = 1'b0;
                    @(posedge clk);
                end
            end
        end
    end

    // Helper: wait for frame start (SYNC falling edge)
    task automatic wait_frame_start();
        @(posedge clk iff sync);   // wait for SYNC high
        @(posedge clk iff !sync);  // SYNC falls = frame start
    endtask

    //--------------------------------------------------------------------------
    // DDR SDO drive helpers
    //--------------------------------------------------------------------------
    // Drive a vector of `len` DDR bits MSB-first.
    // #1 delay models the controller's T_co (§5.2.3 / Figure 18).
    // first_in_frame: skip initial @(posedge clk) — caller is already at
    //   the posedge where sync was first detected low; drive immediately.
    //--------------------------------------------------------------------------
    task automatic drive_sdo_ddr(input logic [47:0] data, input int len,
                                 input bit first_in_frame = 0);
        for (int i = len-1; i >= 0; i -= 2) begin
            if (i != len-1 || !first_in_frame) @(posedge clk);
            #1; sdo = data[i];
            @(negedge clk); #1; sdo = data[i-1];
        end
    endtask

    task automatic drive_sdo_zero_ddr(input int len,
                                      input bit first_in_frame = 0);
        for (int i = 0; i < len; i += 2) begin
            if (i != 0 || !first_in_frame) @(posedge clk);
            #1; sdo = 1'b0;
            @(negedge clk); #1; sdo = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Command / Response
    //--------------------------------------------------------------------------
    task automatic send_command(
        input  logic [3:0]  codec_addr,
        input  logic [7:0]  nid,
        input  logic [11:0] verb,
        input  logic [15:0] payload,
        output logic [35:0] resp
    );
        logic [39:0] cmd;
        logic [35:0] captured;
        logic        is_4bit;
        is_4bit = (verb <= 12'h00F);
        if (is_4bit) cmd = {8'h00, codec_addr, nid, verb[3:0], payload};
        else         cmd = {8'h00, codec_addr, nid, verb, payload[7:0]};

        // Wait for frame start (SYNC falling edge detected by BFM)
        wait_frame_start();

        // synthesis translate_off
        $display("[BFM] send raw=%010X", cmd);
        // synthesis translate_on

        // Drive 40-bit command DDR (20 BCLK), first_in_frame=1
        drive_sdo_ddr({8'h0, cmd}, 40, 1);
        @(posedge clk); #1; sdo = 1'b0;

        // Wait for the response frame, then sample SDI.
        // §5.3.3 / Figure 19: the 36-bit Response Field occupies SDI bit-cells
        // 499..464 (MSB first).  The codec now drives bit 499 exactly at the
        // Start-of-Frame BCLK edge (DDR-SYNC zero-latency load), so a standard
        // controller samples the MSB on the first rising edge after it detects
        // the Frame-Sync fall — which is exactly where wait_frame_start
        // returns.  No extra skip: the former +2 was compensating the codec's
        // old two-stage-sync + register latency, which no longer exists.
        wait_frame_start();

        // Capture 36-bit response from SDI (SDR, posedge)
        for (int i = 35; i >= 0; i--) begin
            captured[i] = sdi;
            @(posedge clk);
        end
        resp = captured;
    endtask

    task automatic write_verb(input logic [7:0] nid, input logic [11:0] verb,
                              input logic [15:0] payload);
        logic [35:0] r; send_command(4'h0, nid, verb, payload, r);
    endtask

    task automatic read_verb(input logic [7:0] nid, input logic [11:0] verb,
                             input logic [15:0] payload, output logic [31:0] data);
        logic [35:0] r; send_command(4'h0, nid, verb, payload, r);
        // §7.3.1: a standard controller only consumes the response when the
        // Valid bit (SDI bit 35) is set, otherwise nothing is written to the
        // RIRB.  Flag a non-compliant codec that fails to assert Valid.
        if (r[35] !== 1'b1)
            $display("[BFM] WARNING: response Valid bit (bit35) not set, resp=%09X", r);
        data = r[31:0];
    endtask

    //--------------------------------------------------------------------------
    // Raw 40-bit command — for link-layer testing
    //--------------------------------------------------------------------------
    task automatic send_raw_cmd(input logic [39:0] raw, output logic [35:0] resp);
        logic [35:0] captured;
        wait_frame_start();
        drive_sdo_ddr({8'h0, raw}, 40, 1);
        @(posedge clk); #1; sdo = 1'b0;
        wait_frame_start();  // codec drives Response MSB at Start-of-Frame (Fig.19)
        for (int i = 35; i >= 0; i--) begin
            captured[i] = sdi;
            @(posedge clk);
        end
        resp = captured;
    endtask

    //--------------------------------------------------------------------------
    // DAC sample drive (DDR)
    //--------------------------------------------------------------------------
    task automatic send_dac_sample(input int dac_idx,
                                   input logic [23:0] l, input logic [23:0] r);
        wait_frame_start();
        // Command field = 40 DDR bits (20 BCLK), first_in_frame=1
        drive_sdo_zero_ddr(40, 1);
        // Skip earlier DAC slots (each 48 DDR bits = 24 BCLK)
        for (int d = 0; d < dac_idx; d++)
            drive_sdo_zero_ddr(48);
        // Drive target DAC sample DDR: L[23:0] then R[23:0] = 48 DDR bits
        drive_sdo_ddr({l, r}, 48);
    endtask

    //--------------------------------------------------------------------------
    // §5.3.2.1 — DAC sample drive with outbound stream tag on SYNC
    //--------------------------------------------------------------------------
    // Before calling, set outbound_tag_id[] and num_outbound_tags so the SYNC
    // driver inserts the stream tag DDR preamble + ID aligned with the command
    // field / preceding DAC slot tail.
    //--------------------------------------------------------------------------
    task automatic send_dac_sample_tagged(input int dac_idx,
                                          input logic [3:0] tag_id,
                                          input logic [23:0] l,
                                          input logic [23:0] r);
        // Configure the tag for this slot (tag[dac_idx])
        outbound_tag_id[dac_idx] = tag_id;
        if (dac_idx >= num_outbound_tags) num_outbound_tags = dac_idx + 1;
        // Drive the same SDO data as the untagged version
        send_dac_sample(dac_idx, l, r);
    endtask

    //--------------------------------------------------------------------------
    // §3.3.34 — High-sample-rate DAC drive: multiple back-to-back 48-bit sample
    // blocks per frame (96 kHz = 2 blocks, 192 kHz = 4 blocks).  Blocks beyond
    // num_blocks are not driven.  Assumes lower-indexed DAC slots run at 48 kHz
    // (one block each), matching the codec's rate-aware slot geometry.
    //--------------------------------------------------------------------------
    task automatic send_dac_sample_hs(
        input int dac_idx, input int num_blocks,
        input logic [23:0] l0, input logic [23:0] r0,
        input logic [23:0] l1, input logic [23:0] r1,
        input logic [23:0] l2, input logic [23:0] r2,
        input logic [23:0] l3, input logic [23:0] r3);
        logic [23:0] bl [0:3];
        logic [23:0] br [0:3];
        bl[0]=l0; br[0]=r0; bl[1]=l1; br[1]=r1;
        bl[2]=l2; br[2]=r2; bl[3]=l3; br[3]=r3;
        wait_frame_start();
        drive_sdo_zero_ddr(40, 1);
        for (int d = 0; d < dac_idx; d++)
            drive_sdo_zero_ddr(48);
        for (int b = 0; b < num_blocks; b++)
            drive_sdo_ddr({bl[b], br[b]}, 48);
    endtask

    //--------------------------------------------------------------------------
    // §5.3.3.1 — Capture inbound stream tags from SDI
    //--------------------------------------------------------------------------
    // After the 36-bit Response field, the codec transmits 10-bit stream tags
    // {stream_id[3:0], data_length[5:0]} inline on SDI before each ADC packet.
    //--------------------------------------------------------------------------
    task automatic capture_inbound_tags(
        output logic [3:0] stream_ids [0:MAX_ADC-1],
        output int         data_lens  [0:MAX_ADC-1],
        output int         num_streams
    );
        logic [9:0] tag;
        int idx;
        wait_frame_start();
        // Skip 36-bit Response field
        repeat (36) @(posedge clk);
        // Scan for stream tags
        idx = 0;
        for (int s = 0; s < MAX_ADC; s++) begin
            // Capture 10-bit tag (SDR, MSB first)
            for (int b = 9; b >= 0; b--) begin
                tag[b] = sdi;
                @(posedge clk);
            end
            stream_ids[s] = tag[9:6];
            data_lens[s]  = int'(tag[5:0]);
            if (tag[5:0] == 6'h0) begin
                // Zero-length tag = termination (§5.3.3.3)
                idx = s;
                break;
            end
            // Skip sample data (data_lens[s] bytes = data_lens[s]*8 bits)
            repeat (int'(tag[5:0]) * 8) @(posedge clk);
            idx = s + 1;
        end
        num_streams = idx;
    endtask

endmodule
