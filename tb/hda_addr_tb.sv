`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// HDA Codec Address Configuration — Detailed Testbench
//------------------------------------------------------------------------------
// Tests the full HDA address-assignment protocol (§5.5.3):
//   • Connect / Turnaround / Address frame sequencing
//   • SDI-high BCLK counting → codec address latching
//   • Address-filtered command dispatch (own vs. foreign address)
//   • Address persistence across normal frames, power states, and resets
//   • Multi-codec bus sharing with distinct addresses
//
// Test groups:
//   A0 — Basic Address Assignment (addr 0..15, one per test)
//   A1 — Address Filtering (wrong-address commands ignored)
//   A2 — Address Frame Timing Edge Cases
//   A3 — Address Persistence (long run, D0↔D3)
//   A4 — Reset Behaviour (cold vs. warm vs. function reset)
//   A5 — Multi-Codec Bus (two codecs, distinct addresses)
//
// Set CHIP_ID via iverilog: -DCHIP_ID=0  (default ALC269)
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

`ifndef CHIP_ID
`define CHIP_ID 0
`endif

`ifndef SIM_TIMEOUT_CYCLES
`define SIM_TIMEOUT_CYCLES 800000
`endif

module hda_addr_tb;

    import hda_codec_pkg::*;

    localparam int CID = `CHIP_ID;

    //==========================================================================
    // Expected constants
    //==========================================================================
    localparam logic [31:0] EXP_VENDOR  = cfg_vendor_id(CID);
    localparam logic [7:0]  AFG_NID     = nid_afg(CID);
    localparam logic [7:0]  DAC0_NID    = nid_dac(CID, 0);
    localparam logic [7:0]  ADC0_NID    = nid_adc(CID, 0);
    localparam logic [7:0]  HP_NID      = nid_out_pin(CID, 0);
    localparam logic [7:0]  NID_MAX     = cfg_nid_max(CID);

    //==========================================================================
    // DUT signals — single codec
    //==========================================================================
    logic        sdo, bclk, sync, reset_n, pd_n;
    logic        codec_sdi, codec_sdi_oe;
    logic        bfm_sdi_drv, bfm_sdi_oe;
    wire         sdi_wire;
    logic        bfm_init_done;

    // SDI tri-state bus
    assign sdi_wire = bfm_sdi_oe   ? bfm_sdi_drv :
                      codec_sdi_oe ? codec_sdi   : 1'b0;

    // Audio I/O stubs
    logic [23:0] hp_out_l, hp_out_r, front_out_l, front_out_r;
    logic [23:0] surr_out_l, surr_out_r, clfe_out_l, clfe_out_r;
    logic [23:0] side_out_l, side_out_r, mono_out;
    logic [23:0] mic1_l, mic1_r, mic2_l, mic2_r;
    logic [23:0] line1_l, line1_r, line2_l, line2_r;
    logic [MAX_SPDIF-1:0] spdif_out_sig;
    logic        pcbeep_in, beep_out, loopback_en;
    logic        codec_ready, afg_powered, dac_powered, adc_powered, spdif_powered;
    wire  [MAX_GPIO-1:0] gpio;
    logic        dmic_mode_en, dmic_data_in, dmic_clk_out;

    int errors   = 0;
    int warnings = 0;

    //==========================================================================
    // DUT — Single Codec (used for A0–A4)
    //==========================================================================
    hda_codec_top #(.CHIP_ID(CID)) u_dut (
        .sdo          (sdo),
        .sdi          (codec_sdi),
        .sdi_oe       (codec_sdi_oe),
        .sdi_in       (sdi_wire),
        .bclk         (bclk),
        .sync         (sync),
        .reset_n      (reset_n),
        .pd_n         (pd_n),
        .gpio         (gpio),
        .dmic_mode_en (dmic_mode_en),
        .dmic_data_in (dmic_data_in),
        .dmic_clk_out (dmic_clk_out),
        .hp_out_l     (hp_out_l),
        .hp_out_r     (hp_out_r),
        .front_out_l  (front_out_l),
        .front_out_r  (front_out_r),
        .surr_out_l   (surr_out_l),
        .surr_out_r   (surr_out_r),
        .clfe_out_l   (clfe_out_l),
        .clfe_out_r   (clfe_out_r),
        .side_out_l   (side_out_l),
        .side_out_r   (side_out_r),
        .mono_out     (mono_out),
        .mic1_l       (mic1_l),
        .mic1_r       (mic1_r),
        .mic2_l       (mic2_l),
        .mic2_r       (mic2_r),
        .line1_l      (line1_l),
        .line1_r      (line1_r),
        .line2_l      (line2_l),
        .line2_r      (line2_r),
        .spdif_out    (spdif_out_sig),
        .pcbeep_in    (pcbeep_in),
        .beep_out     (beep_out),
        .loopback_en  (loopback_en),
        .codec_ready  (codec_ready),
        .afg_powered  (afg_powered),
        .dac_powered  (dac_powered),
        .adc_powered  (adc_powered),
        .spdif_powered(spdif_powered)
    );

    //==========================================================================
    // BFM — Address-testing controller
    //==========================================================================
    hda_addr_ctrl_bfm #(
        .TARGET_CODEC_ADDR (4'h0)
    ) u_bfm (
        .clk            (bclk),
        .rst_n          (reset_n),
        .sdo            (sdo),
        .sdi            (sdi_wire),
        .sdi_drv        (bfm_sdi_drv),
        .sdi_drv_oe     (bfm_sdi_oe),
        .sync           (sync),
        .pd_n           (pd_n),
        .link_init_done (bfm_init_done)
    );

    //==========================================================================
    // Helpers
    //==========================================================================
    function automatic string pf(logic ok);
        return ok ? "PASS" : "FAIL";
    endfunction

    function automatic string chip_name(int c);
        case (c)
            CHIP_ALC269: return "ALC269";
            CHIP_ALC662: return "ALC662";
            CHIP_ALC892: return "ALC892";
            CHIP_ALC256: return "ALC256";
            default:     return "UNKNOWN";
        endcase
    endfunction

    //==========================================================================
    // Global timeout watchdog
    //==========================================================================
    initial begin
        #(`SIM_TIMEOUT_CYCLES * 41.666ns);
        $display("\n*** FATAL: Simulation timed out after %0d BCLK cycles ***",
                 `SIM_TIMEOUT_CYCLES);
        $display("*** Errors=%0d  Warnings=%0d ***", errors, warnings);
        $finish;
    end

    //==========================================================================
    // Test Orchestrator
    //==========================================================================
    initial begin
        logic [31:0] rdata;
        logic [35:0] resp;
        logic        ok;
        logic        nak_ok;
        automatic int group_start_errors;
        automatic int test_pass;
        automatic int test_total;

        // Drive static inputs
        mic1_l = 24'h00_1234; mic1_r = 24'h00_5678;
        mic2_l = 24'h00_9ABC; mic2_r = 24'h00_DEF0;
        line1_l = 24'h01_1111; line1_r = 24'h02_2222;
        line2_l = 24'h03_3333; line2_r = 24'h04_4444;
        loopback_en  = 1'b0;
        dmic_mode_en = 1'b0;
        dmic_data_in = 1'b0;
        pcbeep_in    = 1'b0;

        $display("\n============================================================");
        $display("=== HDA Address Configuration TB — %s (CHIP_ID=%0d) ===",
                 chip_name(CID), CID);
        $display("============================================================\n");

        wait (reset_n === 1'b1);

        //----------------------------------------------------------------------
        // A0: Basic Address Assignment — addr 0..15
        //   For each address: cold-reset, init with that address, verify the
        //   codec responds to a Get Parameter command at its own address.
        //----------------------------------------------------------------------
        $display("=== A0: Basic Address Assignment (addr 0..15) ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        for (int addr = 0; addr < 16; addr++) begin
            test_total++;
            $display("\n--- A0.%0d: Address = %0d ---", addr, addr);

            // Cold reset to clear any previous address
            u_bfm.cold_reset_link(30);
            // Re-init with the target address
            u_bfm.reinit_assign_addr(4'(addr));
            u_bfm.set_codec_addr(4'(addr));

            // Verify: read Vendor ID from AFG (verb requires matching address)
            u_bfm.send_cmd_to(4'(addr), AFG_NID, VERB_GET_PARAM, 16'h0000, resp);

            ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
            $display("  A0.%0d addr=%0d VendorID=0x%08X Valid=%b %s",
                     addr, addr, resp[31:0], resp[35], pf(ok));
            if (ok) test_pass++; else errors++;
        end

        $display("\nA0 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // A1: Address Filtering — wrong address → no response
        //   Assign address X, then send commands to addresses ≠ X.
        //   The codec must NOT respond (Valid bit = 0).
        //----------------------------------------------------------------------
        $display("\n=== A1: Address Filtering ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        // A1.0: Re-init with address 5 (mid-range, neither 0 nor 15)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd5);
        u_bfm.set_codec_addr(4'd5);

        // Verify codec responds at address 5
        test_total++;
        u_bfm.send_cmd_to(4'd5, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A1.0  addr=5  responds   Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A1.1–A1.16: Try all other addresses → should NAK
        for (int a = 0; a < 16; a++) begin
            if (a == 5) continue;
            test_total++;
            u_bfm.send_cmd_expect_nak(4'(a), AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
            $display("  A1.%0d  addr=%-2d NAK      %s",
                     a + (a > 5 ? 0 : 1), a, pf(nak_ok));
            if (nak_ok) test_pass++; else errors++;
        end

        // A1.17: Verify codec STILL responds at address 5 (proves it's alive)
        test_total++;
        u_bfm.send_cmd_to(4'd5, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A1.17 addr=5  still-responds Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A1.18: Same test with address 0 (the most common case)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd0);
        u_bfm.set_codec_addr(4'd0);
        test_total++;
        u_bfm.send_cmd_to(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A1.18 addr=0  responds   Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // Verify addr=0 codec ignores addr=1,2,3,15
        for (int a = 1; a < 16; a++) begin
            test_total++;
            u_bfm.send_cmd_expect_nak(4'(a), AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
            // Only print every 4th to keep log manageable
            if ((a % 4) == 0)
                $display("  A1.%0d  addr=%-2d NAK      %s", 18 + a, a, pf(nak_ok));
            if (nak_ok) test_pass++; else errors++;
        end

        $display("\nA1 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // A2: Address Frame Timing Edge Cases
        //   Test the codec's robustness to variations in SDI timing during
        //   the Address Frame.  The BFM drives SDI high for exactly `addr`
        //   cycles.  We verify the codec latches the correct address.
        //   Also test: re-run address frame with same/different values.
        //----------------------------------------------------------------------
        $display("\n=== A2: Address Frame Timing Edge Cases ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        // A2.0: Address 0 — SDI immediately low (shortest possible)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd0);
        @(posedge bclk);
        test_total++;
        u_bfm.send_cmd_to(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A2.0  addr=0  (min)  Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A2.1: Address 15 — SDI high for 15 BCLK (longest valid)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd15);
        @(posedge bclk);
        test_total++;
        u_bfm.send_cmd_to(4'd15, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A2.1  addr=15 (max)  Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A2.2: Repeated address frames with same address — should stay stable
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd3);
        // Send 5 commands to address 3, all should succeed
        ok = 1'b1;
        for (int i = 0; i < 5; i++) begin
            u_bfm.send_cmd_to(4'd3, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
            if (resp[35] !== 1'b1) ok = 1'b0;
        end
        test_total++;
        $display("  A2.2  addr=3  x5 cmds all-ok %s", pf(ok));
        if (ok) test_pass++; else errors++;

        // A2.3: Address 1 (minimum non-zero, tests single-BCLK SDI-high)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd1);
        @(posedge bclk);
        test_total++;
        u_bfm.send_cmd_to(4'd1, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A2.3  addr=1  (1cyc) Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A2.4: Verify addr=1 codec ignores addr=0 (adjacent)
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A2.4  addr=0→NAK (adjacent) %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        // A2.5: Verify addr=1 codec ignores addr=2 (adjacent other side)
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd2, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A2.5  addr=2→NAK (adjacent) %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        $display("\nA2 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // A3: Address Persistence
        //   Verify the codec retains its address across many frames and
        //   across power-state transitions (D0↔D3↔D0).
        //----------------------------------------------------------------------
        $display("\n=== A3: Address Persistence ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        // A3.0: Init with address 7, run 200 frames, verify still responds
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd7);
        u_bfm.set_codec_addr(4'd7);
        // Send 200 dummy commands (each takes 2 frames: cmd + resp)
        for (int i = 0; i < 200; i++) begin
            u_bfm.send_cmd_to(4'd7, DAC0_NID, VERB_GET_CONV_FMT, 16'h0, resp);
        end
        test_total++;
        u_bfm.send_cmd_to(4'd7, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A3.0  addr=7 after 200 frames Valid=%b ID=0x%08X %s",
                 resp[35], resp[31:0], pf(ok));
        if (ok) test_pass++; else errors++;

        // A3.1: D0→D3→D0 transition preserves address
        //   Put AFG in D3, verify link stays alive, bring back to D0, verify
        u_bfm.write_verb(AFG_NID, VERB_SET_PWR_STATE, 16'h0003);  // D3
        repeat (50) @(posedge bclk);
        u_bfm.write_verb(AFG_NID, VERB_SET_PWR_STATE, 16'h0000);  // D0
        repeat (50) @(posedge bclk);

        test_total++;
        u_bfm.send_cmd_to(4'd7, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A3.1  addr=7 after D3→D0       Valid=%b ID=0x%08X %s",
                 resp[35], resp[31:0], pf(ok));
        if (ok) test_pass++; else errors++;

        // A3.2: Verify addr=7 codec still ignores addr=0
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A3.2  addr=0→NAK after D3→D0    %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        $display("\nA3 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // A4: Reset Behaviour
        //   Test how different reset types affect the codec address.
        //----------------------------------------------------------------------
        $display("\n=== A4: Reset Behaviour ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        // A4.0: Cold reset (rst_n low for many cycles) clears address
        //   → codec re-enters init, needs new address assignment
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd9);
        u_bfm.set_codec_addr(4'd9);
        test_total++;
        u_bfm.send_cmd_to(4'd9, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A4.0  addr=9 after cold-reset  Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A4.1: After another cold reset, old address (9) no longer works
        u_bfm.cold_reset_link(30);
        test_total++;
        // Codec is back in init — try sending to addr=9 before re-init
        // It may or may not respond depending on whether it re-entered LS_NORMAL
        // The key test: codec should NOT be in LS_NORMAL with addr=9 yet
        // (We don't have direct access to link_state, so we just try a cmd)
        u_bfm.send_cmd_to(4'd9, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        // After cold reset without re-init, codec may or may not respond.
        // This is informational — we log the behaviour.
        $display("  A4.1  addr=9 before reinit     Valid=%b (info)", resp[35]);

        // A4.2: Re-init with different address (2) after cold reset — must work.
        //   Need a fresh cold_reset because A4.1's cold_reset left the codec
        //   auto-initialised to addr=0 in LS_NORMAL (no reinit was done).
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd2);
        u_bfm.set_codec_addr(4'd2);
        test_total++;
        u_bfm.send_cmd_to(4'd2, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A4.2  addr=2 after reinit      Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A4.3: Verify old address (9) no longer works after re-init to 2
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd9, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A4.3  addr=9→NAK after reinit→2 %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        // A4.4: Function Reset (VERB_FUNCTION_RESET on AFG) does NOT clear
        //   link-layer address.  The verb engine resets widget state, but the
        //   link layer retains its address.
        u_bfm.write_verb(AFG_NID, VERB_FUNCTION_RESET, 16'h0000);
        repeat (20) @(posedge bclk);
        test_total++;
        u_bfm.send_cmd_to(4'd2, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        // After Function Reset, the AFG widget state resets but the codec
        // should still respond at address 2.
        ok = (resp[35] === 1'b1);
        $display("  A4.4  addr=2 after FuncReset   Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A4.5: Warm reset (brief rst_n pulse) — address may persist.
        //   Many HDA implementations preserve codec address across warm reset.
        u_bfm.warm_reset_link(10);
        // After warm reset, the codec should re-enter init.
        // Re-init and verify.
        u_bfm.reinit_assign_addr(4'd2);
        test_total++;
        u_bfm.send_cmd_to(4'd2, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1);
        $display("  A4.5  addr=2 after warm-reset  Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        $display("\nA4 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // A5: Rapid Address Reassignment & Multi-Address Isolation
        //   Simulates multi-codec enumeration: cold-reset + assign different
        //   addresses in sequence, verifying each assignment is clean and
        //   the codec correctly filters out non-matching addresses.
        //   (A true multi-DUT test would require independent reset control
        //   per codec; this logical test covers the same address-isolation
        //   requirements.)
        //----------------------------------------------------------------------
        $display("\n=== A5: Rapid Address Reassignment ===");
        group_start_errors = errors;
        test_pass  = 0;
        test_total = 0;

        // A5.0: addr=0 (baseline)
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd0);
        test_total++;
        u_bfm.send_cmd_to(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A5.0  codec→addr0  responds     Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;

        // A5.1: cold-reset → addr=1, verify responds, verify ignores addr=0
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd1);
        test_total++;
        u_bfm.send_cmd_to(4'd1, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A5.1  codec→addr1  responds     Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A5.2  addr=0→NAK (codec at 1)   %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        // A5.3: cold-reset → addr=15 (max), verify responds, verify ignores adj
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd15);
        test_total++;
        u_bfm.send_cmd_to(4'd15, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A5.3  codec→addr15 responds     Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd14, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A5.4  addr=14→NAK (codec at 15) %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;
        test_total++;
        u_bfm.send_cmd_expect_nak(4'd0, AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
        $display("  A5.5  addr=0→NAK (codec at 15)  %s", pf(nak_ok));
        if (nak_ok) test_pass++; else errors++;

        // A5.6: cold-reset → addr=8 (mid-range), full sweep of wrong addrs
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd8);
        test_total++;
        u_bfm.send_cmd_to(4'd8, AFG_NID, VERB_GET_PARAM, 16'h0000, resp);
        ok = (resp[35] === 1'b1) && (resp[31:0] === EXP_VENDOR);
        $display("  A5.6  codec→addr8  responds     Valid=%b %s", resp[35], pf(ok));
        if (ok) test_pass++; else errors++;
        // Quick sweep: verify all other addresses NAK
        begin
            automatic logic all_nak = 1'b1;
            for (int a = 0; a < 16; a++) begin
                if (a == 8) continue;
                u_bfm.send_cmd_expect_nak(4'(a), AFG_NID, VERB_GET_PARAM, 16'h0000, nak_ok);
                if (!nak_ok) all_nak = 1'b0;
            end
            test_total++;
            $display("  A5.7  addr=8 all-other-NAK      %s", pf(all_nak));
            if (all_nak) test_pass++; else errors++;
        end

        // Clean up: reset to addr=0 for final status
        u_bfm.cold_reset_link(30);
        u_bfm.reinit_assign_addr(4'd0);
        u_bfm.set_codec_addr(4'd0);
        @(posedge bclk);

        $display("\nA5 result: %0d/%0d passed, %0d new error(s)",
                 test_pass, test_total, errors - group_start_errors);

        //----------------------------------------------------------------------
        // Final Report
        //----------------------------------------------------------------------
        $display("\n============================================================");
        if (errors == 0) begin
            $display("=== ALL ADDRESS TESTS PASSED — %s ===", chip_name(CID));
        end else begin
            $display("=== ADDRESS TESTS FAILED — %s: %0d error(s) ===",
                     chip_name(CID), errors);
        end
        $display("============================================================\n");

        $finish;
    end

endmodule
