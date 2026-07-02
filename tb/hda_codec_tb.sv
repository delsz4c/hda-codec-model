`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec -Enhanced Parameterized Testbench
//------------------------------------------------------------------------------
// Set CHIP_ID to test different codec models:
//   0 = ALC269, 1 = ALC662, 2 = ALC892, 3 = ALC256
// Override via iverilog: -DCHIP_ID=1
//
// Test groups (ordered for dependency isolation):
//   G0  -Identification & Capability ROM (10 tests)
//   G1  -Widget Capabilities (6 tests)
//   G2  -Converter Control: format, stream, amp (5 tests)
//   G3  -Audio Output Path: HP, mute, pin ctrl, gain (7 tests)
//   G4  -Audio Input Path: ADC conn, stream, proc state (4 tests)
//   G5  -Power Management: states, status signals (6 tests)
//   G6  -SPDIF Output: toggle + silent (2 tests)
//   G7  -BEEP Generator: toggle, disable, readback (3 tests)
//   G8  -Miscellaneous: EAPD, SubsysID, ConfigDef, ConnSel, Unsol, VolKnob (6)
//   G9  -Function Reset (3 tests)
//   G10 -GPIO: Data, Enable, Direction, Wake, UnsolMask (5 tests)
//   G11 -Robustness: invalid NID, unsupported verb, root write (4 tests)
//   G12 -Link Sampling Robustness (7 tests)
//   G13 -Response Field Format (4 tests)
//   G14 -Link Stream Tags: outbound tag filter, inbound tag (6 tests)
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

`ifndef CHIP_ID
`define CHIP_ID 0
`endif

// Simulation timeout in BCLK cycles (24 MHz * ~5 ms -120k cycles; generous)
`ifndef SIM_TIMEOUT_CYCLES
`define SIM_TIMEOUT_CYCLES 500000
`endif

module hda_codec_tb;

    import hda_codec_pkg::*;

    localparam int CID = `CHIP_ID;

    //--------------------------------------------------------------------------
    // Expected constants per chip (resolved at elaboration)
    //--------------------------------------------------------------------------
    localparam logic [31:0] EXP_VENDOR    = cfg_vendor_id(CID);
    localparam logic [31:0] EXP_REV_ID    = cfg_revision_id(CID);
    localparam logic [31:0] EXP_AFG_SUB   = cfg_afg_subnode_count(CID);
    localparam logic [31:0] EXP_ROOT_SUB  = cfg_root_subnode_count(CID);
    localparam logic [31:0] EXP_AFG_TYPE  = cfg_afg_func_group_type(CID);
    localparam logic [31:0] EXP_AUDIO_CAP = cfg_audio_func_cap(CID);
    localparam logic [31:0] EXP_PCM_RATE  = cfg_pcm_size_rate(CID);
    localparam logic [31:0] EXP_GPIO_CAP  = cfg_gpio_cap(CID);
    localparam logic [31:0] EXP_VOL_CAP   = cfg_vol_knob_cap(CID);
    localparam int          NUM_DAC       = cfg_num_dac(CID);
    localparam int          NUM_ADC       = cfg_num_adc(CID);
    localparam int          NUM_SPDIF     = cfg_num_spdif(CID);
    localparam int          NUM_GPIO      = cfg_num_gpio(CID);
    localparam logic [7:0]  AFG_NID       = nid_afg(CID);
    localparam logic [7:0]  DAC0_NID      = nid_dac(CID, 0);
    localparam logic [7:0]  ADC0_NID      = nid_adc(CID, 0);
    localparam logic [7:0]  HP_NID        = nid_out_pin(CID, 0);
    localparam logic [7:0]  BEEP_NID      = nid_beep(CID);
    localparam logic [7:0]  SPDIF_NID     = nid_spdif_pin(CID, 0);
    localparam logic [7:0]  NID_MAX       = cfg_nid_max(CID);

    //--------------------------------------------------------------------------
    // DUT signals
    //--------------------------------------------------------------------------
    logic sdo, bclk, sync, reset_n, pd_n;
    wire  [MAX_GPIO-1:0] gpio;
    logic dmic_mode_en, dmic_data_in, dmic_clk_out;
    logic [23:0] hp_out_l, hp_out_r;
    logic [23:0] front_out_l, front_out_r;
    logic [23:0] surr_out_l, surr_out_r;
    logic [23:0] clfe_out_l, clfe_out_r;
    logic [23:0] side_out_l, side_out_r;
    logic [23:0] mono_out;
    logic [23:0] mic1_l, mic1_r, mic2_l, mic2_r;
    logic [23:0] line1_l, line1_r, line2_l, line2_r;
    logic [MAX_SPDIF-1:0] spdif_out_sig;
    logic pcbeep_in, beep_out, loopback_en;
    logic codec_ready, afg_powered, dac_powered, adc_powered, spdif_powered;

    // SDI tri-state bus -codec drives during CONNECT & NORMAL,
    // controller drives during ADDRESS frame
    logic codec_sdi, codec_sdi_oe;
    logic bfm_sdi_drv, bfm_sdi_oe;
    wire  sdi_wire;
    assign sdi_wire = bfm_sdi_oe    ? bfm_sdi_drv :
                      codec_sdi_oe  ? codec_sdi    : 1'b0;

    // BFM init done flag
    logic bfm_init_done;

    int errors   = 0;
    int warnings = 0;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------
    // BFM
    //--------------------------------------------------------------------------
    hda_ctrl_bfm u_bfm (
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

    //--------------------------------------------------------------------------
    // Helpers
    //--------------------------------------------------------------------------
    function automatic string chip_name(int c);
        case (c)
            CHIP_ALC269: return "ALC269";
            CHIP_ALC662: return "ALC662";
            CHIP_ALC892: return "ALC892";
            CHIP_ALC256: return "ALC256";
            default:     return "UNKNOWN";
        endcase
    endfunction

    function automatic string pf(logic ok);
        return ok ? "PASS" : "FAIL";
    endfunction

    // Count codec dac_valid[idx] pulses over exactly one HDA frame (§3.3.34):
    // verifies high-sample-rate transfers deliver rate_mult sample blocks/frame.
    task automatic count_dac_valid(input int idx, output int cnt);
        cnt = 0;
        @(posedge bclk iff sync);   // SYNC high
        @(posedge bclk iff !sync);  // Start-of-Frame
        repeat (500) begin
            @(posedge bclk);
            if (u_dut.dac_valid[idx]) cnt = cnt + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // Global timeout watchdog -prevents infinite-hang simulations
    //--------------------------------------------------------------------------
    initial begin
        #(`SIM_TIMEOUT_CYCLES * 41.666ns);
        $display("\n*** FATAL: Simulation timed out after %0d BCLK cycles ***",
                 `SIM_TIMEOUT_CYCLES);
        $display("*** Errors=%0d  Warnings=%0d ***", errors, warnings);
        $finish;
    end

    //--------------------------------------------------------------------------
    // Stimulus
    //--------------------------------------------------------------------------
    initial begin
        logic [31:0] rdata;
        logic        spdif_toggle_ok, beep_toggle_ok;
        logic        beep_sampled0, beep_sampled1;
        automatic int group_start_errors;
        automatic int group_start_warnings;

        // Drive static inputs
        mic1_l  = 24'h00_1234; mic1_r  = 24'h00_5678;
        mic2_l  = 24'h00_9ABC; mic2_r  = 24'h00_DEF0;
        line1_l = 24'h01_1111; line1_r = 24'h02_2222;
        line2_l = 24'h03_3333; line2_r = 24'h04_4444;
        loopback_en  = 1'b0;
        dmic_mode_en = 1'b0;
        dmic_data_in = 1'b0;
        pcbeep_in    = 1'b0;

        $display("\n============================================================");
        $display("=== HDA Codec Enhanced TB -%s (CHIP_ID=%0d) ===",
                 chip_name(CID), CID);
        $display("=== DAC=%0d ADC=%0d SPDIF=%0d GPIO=%0d ===",
                 NUM_DAC, NUM_ADC, NUM_SPDIF, NUM_GPIO);
        $display("============================================================\n");

        wait (reset_n === 1'b1);
        // Wait for HDA link initialization (Connect -Turnaround -Address)
        wait (bfm_init_done === 1'b1);
        repeat (20) @(posedge bclk);

        //======================================================================
        // G0: Identification & Capability ROM
        //======================================================================
        $display("--- G0: Identification & Capability ROM ---");
        group_start_errors = errors;

        // G0.1 -Vendor ID
        u_bfm.read_verb(8'h00, VERB_GET_PARAM, 16'h0000, rdata);
        $display("G0.1 Vendor ID        = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_VENDOR, pf(rdata===EXP_VENDOR));
        if (rdata !== EXP_VENDOR) errors++;

        // G0.2 -Revision ID
        u_bfm.read_verb(8'h00, VERB_GET_PARAM, 16'h0002, rdata);
        $display("G0.2 Revision ID      = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_REV_ID, pf(rdata===EXP_REV_ID));
        if (rdata !== EXP_REV_ID) errors++;

        // G0.3 -Root SubNode Count
        u_bfm.read_verb(8'h00, VERB_GET_PARAM, 16'h0004, rdata);
        $display("G0.3 Root SubNodes    = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_ROOT_SUB, pf(rdata===EXP_ROOT_SUB));
        if (rdata !== EXP_ROOT_SUB) errors++;

        // G0.4 -AFG SubNode Count
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0004, rdata);
        $display("G0.4 AFG SubNodes     = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_AFG_SUB, pf(rdata===EXP_AFG_SUB));
        if (rdata !== EXP_AFG_SUB) errors++;

        // G0.5 -AFG Function Group Type
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0005, rdata);
        $display("G0.5 AFG FG Type      = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_AFG_TYPE, pf(rdata===EXP_AFG_TYPE));
        if (rdata !== EXP_AFG_TYPE) errors++;

        // G0.6 -Audio Function Capabilities
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0008, rdata);
        $display("G0.6 Audio Func Cap   = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_AUDIO_CAP, pf(rdata===EXP_AUDIO_CAP));
        if (rdata !== EXP_AUDIO_CAP) errors++;

        // G0.7 -PCM Size/Rate
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h000A, rdata);
        $display("G0.7 PCM Size/Rate    = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_PCM_RATE, pf(rdata===EXP_PCM_RATE));
        if (rdata !== EXP_PCM_RATE) errors++;

        // G0.8 -Supported Power States
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h000F, rdata);
        $display("G0.8 Supported Pwr    = 0x%08X (exp 0x%08X) %s",
                 rdata, SUPP_PWR_STATES, pf(rdata===SUPP_PWR_STATES));
        if (rdata !== SUPP_PWR_STATES) errors++;

        // G0.9 -GPIO Capabilities (on AFG)
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0011, rdata);
        $display("G0.9 GPIO Cap         = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_GPIO_CAP, pf(rdata===EXP_GPIO_CAP));
        if (rdata !== EXP_GPIO_CAP) errors++;

        // G0.10 -Volume Knob Cap
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0013, rdata);
        $display("G0.10 Vol Knob Cap    = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_VOL_CAP, pf(rdata===EXP_VOL_CAP));
        if (rdata !== EXP_VOL_CAP) errors++;

        $display("G0 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G1: Widget Capabilities
        //======================================================================
        $display("--- G1: Widget Capabilities ---");
        group_start_errors = errors;

        // G1.1 -DAC0 Widget Cap
        u_bfm.read_verb(DAC0_NID, VERB_GET_PARAM, 16'h0009, rdata);
        $display("G1.1 DAC0 Widget Cap  = 0x%08X (exp 0x%08X) %s",
                 rdata, WCAP_DAC, pf(rdata===WCAP_DAC));
        if (rdata !== WCAP_DAC) errors++;

        // G1.2 -ADC0 Widget Cap
        u_bfm.read_verb(ADC0_NID, VERB_GET_PARAM, 16'h0009, rdata);
        $display("G1.2 ADC0 Widget Cap  = 0x%08X (exp 0x%08X) %s",
                 rdata, WCAP_ADC, pf(rdata===WCAP_ADC));
        if (rdata !== WCAP_ADC) errors++;

        // G1.3 -BEEP Widget Cap
        u_bfm.read_verb(BEEP_NID, VERB_GET_PARAM, 16'h0009, rdata);
        $display("G1.3 BEEP Widget Cap  = 0x%08X (exp 0x%08X) %s",
                 rdata, WCAP_BEEP, pf(rdata===WCAP_BEEP));
        if (rdata !== WCAP_BEEP) errors++;

        // G1.4 -HP Pin Widget Cap
        u_bfm.read_verb(HP_NID, VERB_GET_PARAM, 16'h0009, rdata);
        $display("G1.4 HP Pin Widget Cap= 0x%08X (exp 0x%08X) %s",
                 rdata, WCAP_PIN, pf(rdata===WCAP_PIN));
        if (rdata !== WCAP_PIN) errors++;

        // G1.5 -HP Pin Capability (non-zero)
        u_bfm.read_verb(HP_NID, VERB_GET_PARAM, 16'h000C, rdata);
        $display("G1.5 HP Pin Cap       = 0x%08X %s",
                 rdata, pf(rdata != 32'h0));
        if (rdata == 32'h0) errors++;

        // G1.6 -Connection List Length (HP)
        u_bfm.read_verb(HP_NID, VERB_GET_PARAM, 16'h000E, rdata);
        $display("G1.6 HP ConnList Len  = %0d %s",
                 rdata[7:0], pf(rdata[7:0] >= 8'd1));
        if (rdata[7:0] < 8'd1) errors++;

        $display("G1 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G2: Converter Control
        //======================================================================
        $display("--- G2: Converter Control ---");
        group_start_errors = errors;

        // G2.1 -DAC0 Converter Format write + readback
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0011);
        u_bfm.read_verb (DAC0_NID, VERB_GET_CONV_FMT, 16'h0, rdata);
        $display("G2.1 DAC0 Format      = 0x%04X (exp 0x0011) %s",
                 rdata[15:0], pf(rdata[15:0]===16'h0011));
        if (rdata[15:0] !== 16'h0011) errors++;

        // G2.2 -ADC0 Converter Format write + readback
        u_bfm.write_verb(ADC0_NID, VERB_SET_CONV_FMT, 16'h0021);
        u_bfm.read_verb (ADC0_NID, VERB_GET_CONV_FMT, 16'h0, rdata);
        $display("G2.2 ADC0 Format      = 0x%04X (exp 0x0021) %s",
                 rdata[15:0], pf(rdata[15:0]===16'h0021));
        if (rdata[15:0] !== 16'h0021) errors++;

        // G2.3 -DAC0 Stream ID
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0001);
        u_bfm.read_verb (DAC0_NID, VERB_GET_CONV_STREAM, 16'h0, rdata);
        $display("G2.3 DAC0 Stream      = 0x%02X (exp 0x01) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h01));
        if (rdata[7:0] !== 8'h01) errors++;

        // G2.4 -Amplifier Gain/Mute: set gain=+31 (0x3F), read back
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB03F);
        u_bfm.read_verb (DAC0_NID, VERB_GET_AMP_GAIN, 16'h0, rdata);
        $display("G2.4 DAC0 Amp Gain    = 0x%02X (exp 0x3F) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h3F));
        if (rdata[7:0] !== 8'h3F) errors++;

        // G2.5 -Amplifier Mute set/readback
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB080);
        u_bfm.read_verb (DAC0_NID, VERB_GET_AMP_GAIN, 16'h0, rdata);
        $display("G2.5 DAC0 Amp Mute    = 0x%02X (exp 0x80) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h80));
        if (rdata[7:0] !== 8'h80) errors++;
        // Unmute for subsequent tests
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);

        $display("G2 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G3: Audio Output Path
        //======================================================================
        $display("--- G3: Audio Output Path ---");
        group_start_errors = errors;

        // Enable HP output
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h40); // Out Enable
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000); // unmute, gain=0
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0031); // 24-bit stereo 48kHz (full precision)

        // G3.1 -Stereo sample, verify L channel independently
        u_bfm.send_dac_sample(0, 24'h12_3456, 24'h78_9ABC);
        repeat (50) @(posedge bclk);
        $display("G3.1 HP L=0x%06X (exp 0x123456) %s",
                 hp_out_l, pf(hp_out_l===24'h12_3456));
        if (hp_out_l !== 24'h12_3456) errors++;
        $display("G3.1 HP R=0x%06X (exp 0x789ABC) %s",
                 hp_out_r, pf(hp_out_r===24'h78_9ABC));
        if (hp_out_r !== 24'h78_9ABC) errors++;

        // G3.2 -Update sample, verify fresh data
        u_bfm.send_dac_sample(0, 24'hAA_BBCC, 24'hDD_EEFF);
        repeat (50) @(posedge bclk);
        $display("G3.2 HP L=0x%06X (exp 0xAABBCC) %s",
                 hp_out_l, pf(hp_out_l===24'hAA_BBCC));
        if (hp_out_l !== 24'hAA_BBCC) errors++;
        $display("G3.2 HP R=0x%06X (exp 0xDDEEFF) %s",
                 hp_out_r, pf(hp_out_r===24'hDD_EEFF));
        if (hp_out_r !== 24'hDD_EEFF) errors++;

        // G3.3 -VRefEn[2] (bit 2, §7.3.3.13 Fig.67) must NOT enable output
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h04); // VRefEn bit only
        u_bfm.send_dac_sample(0, 24'h11_1111, 24'h22_2222);
        repeat (50) @(posedge bclk);
        $display("G3.3 HP (bad ctl=0x04) L=0x%06X R=0x%06X (exp 0,0) %s",
                 hp_out_l, hp_out_r,
                 pf(hp_out_l===24'h0 && hp_out_r===24'h0));
        if (hp_out_l !== 24'h0 || hp_out_r !== 24'h0) errors++;

        // G3.4 -VRefEn[1] (bit 1, §7.3.3.13 Fig.67) must NOT enable output
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h02);
        u_bfm.send_dac_sample(0, 24'h33_3333, 24'h44_4444);
        repeat (50) @(posedge bclk);
        $display("G3.4 HP (bad ctl=0x02) L=0x%06X R=0x%06X (exp 0,0) %s",
                 hp_out_l, hp_out_r,
                 pf(hp_out_l===24'h0 && hp_out_r===24'h0));
        if (hp_out_l !== 24'h0 || hp_out_r !== 24'h0) errors++;

        // G3.5 -Mute cuts output
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h40); // re-enable
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB080); // mute
        u_bfm.send_dac_sample(0, 24'hCC_CCCC, 24'hDD_DDDD);
        repeat (50) @(posedge bclk);
        $display("G3.5 HP muted L=0x%06X R=0x%06X (exp 0,0) %s",
                 hp_out_l, hp_out_r,
                 pf(hp_out_l===24'h0 && hp_out_r===24'h0));
        if (hp_out_l !== 24'h0 || hp_out_r !== 24'h0) errors++;

        // G3.6 -Unmute restores output
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);
        u_bfm.send_dac_sample(0, 24'h55_1234, 24'h66_5678);
        repeat (50) @(posedge bclk);
        $display("G3.6 HP unmuted L=0x%06X (exp 0x551234) %s",
                 hp_out_l, pf(hp_out_l===24'h55_1234));
        if (hp_out_l !== 24'h55_1234) errors++;
        $display("G3.6 HP unmuted R=0x%06X (exp 0x665678) %s",
                 hp_out_r, pf(hp_out_r===24'h66_5678));
        if (hp_out_r !== 24'h66_5678) errors++;

        // G3.7 -Gain attenuation: gain_idx=0x10 -idx[6:4]=1 ->>1
        //   Input 0x400000 -expected output 0x200000
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB010);
        u_bfm.send_dac_sample(0, 24'h40_0000, 24'h40_0000);
        repeat (50) @(posedge bclk);
        $display("G3.7 HP gain>>1 L=0x%06X (exp 0x200000) %s",
                 hp_out_l, pf(hp_out_l===24'h20_0000));
        if (hp_out_l !== 24'h20_0000) errors++;
        // Reset gain
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);

        $display("G3 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G4: Audio Input Path (ADC)
        //======================================================================
        $display("--- G4: Audio Input Path ---");
        group_start_errors = errors;

        // G4.1 -ADC0 Connection List entry 0 valid (non-zero NID)
        u_bfm.read_verb(ADC0_NID, VERB_GET_CONN_LIST, 16'h0000, rdata);
        $display("G4.1 ADC0 ConnList[0] = 0x%02X %s",
                 rdata[7:0], pf(rdata[7:0] != 8'h00));
        if (rdata[7:0] == 8'h00) errors++;

        // G4.2 -ADC0 Stream ID
        u_bfm.write_verb(ADC0_NID, VERB_SET_CONV_STREAM, 16'h0002);
        u_bfm.read_verb (ADC0_NID, VERB_GET_CONV_STREAM, 16'h0, rdata);
        $display("G4.2 ADC0 Stream      = 0x%02X (exp 0x02) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h02));
        if (rdata[7:0] !== 8'h02) errors++;

        // G4.3 -ADC0 Processing State default = 0
        u_bfm.read_verb(ADC0_NID, VERB_GET_PROC_STATE, 16'h0, rdata);
        $display("G4.3 ADC0 Proc State  = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;

        // G4.4 -MIC1 (first input pin) connection list self-check
        begin
            automatic logic [7:0] mic1_nid = nid_in_pin(CID, 0);
            u_bfm.read_verb(mic1_nid, VERB_GET_CONN_LIST, 16'h0000, rdata);
            $display("G4.4 MIC1(0x%02X) ConnList[0] = 0x%02X (exp 0x%02X) %s",
                     mic1_nid, rdata[7:0], mic1_nid,
                     pf(rdata[7:0] == mic1_nid));
            if (rdata[7:0] != mic1_nid) errors++;
        end

        $display("G4 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G5: Power Management
        //======================================================================
        $display("--- G5: Power Management ---");
        group_start_errors = errors;

        // G5.1 -AFG Power State D3 response format (PS-Set=3, PS-Act=3)
        u_bfm.write_verb(AFG_NID, VERB_SET_PWR_STATE, 16'h0003);
        u_bfm.read_verb (AFG_NID, VERB_GET_PWR_STATE, 16'h0, rdata);
        $display("G5.1 AFG Pwr=D3      = 0x%08X (exp 0x00000033) %s",
                 rdata, pf(rdata===32'h00000033));
        if (rdata !== 32'h00000033) errors++;

        // G5.2 -D3 drops powered signals
        repeat (20) @(posedge bclk);
        $display("G5.2 afg_powered     = %b (exp 0) %s",
                 afg_powered, pf(afg_powered===1'b0));
        if (afg_powered !== 1'b0) errors++;
        $display("G5.2 dac_powered     = %b (exp 0) %s",
                 dac_powered, pf(dac_powered===1'b0));
        if (dac_powered !== 1'b0) errors++;
        $display("G5.2 adc_powered     = %b (exp 0) %s",
                 adc_powered, pf(adc_powered===1'b0));
        if (adc_powered !== 1'b0) errors++;

        // G5.3 -Restore D0, check status signals
        u_bfm.write_verb(AFG_NID, VERB_SET_PWR_STATE, 16'h0000);
        repeat (20) @(posedge bclk);
        $display("G5.3 afg_powered     = %b (exp 1) %s",
                 afg_powered, pf(afg_powered===1'b1));
        if (afg_powered !== 1'b1) errors++;
        $display("G5.3 dac_powered     = %b (exp 1) %s",
                 dac_powered, pf(dac_powered===1'b1));
        if (dac_powered !== 1'b1) errors++;
        $display("G5.3 adc_powered     = %b (exp 1) %s",
                 adc_powered, pf(adc_powered===1'b1));
        if (adc_powered !== 1'b1) errors++;

        // G5.4 -codec_ready tracks reset_n & pd_n
        $display("G5.4 codec_ready     = %b (exp 1) %s",
                 codec_ready, pf(codec_ready===1'b1));
        if (codec_ready !== 1'b1) errors++;

        // G5.5 -spdif_powered during D0
        $display("G5.5 spdif_powered   = %b (exp 1) %s",
                 spdif_powered, pf(spdif_powered===1'b1));
        if (spdif_powered !== 1'b1) errors++;

        // G5.6 -Read D0 power state
        u_bfm.read_verb(AFG_NID, VERB_GET_PWR_STATE, 16'h0, rdata);
        $display("G5.6 AFG Pwr=D0      = 0x%08X (exp 0x00000000) %s",
                 rdata, pf(rdata===32'h00000000));
        if (rdata !== 32'h00000000) errors++;

        $display("G5 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G6: SPDIF Output
        //======================================================================
        $display("--- G6: SPDIF Output ---");
        group_start_errors = errors;

        // G6.1 -Enable SPDIF, verify toggling within 500 cycles
        u_bfm.write_verb(SPDIF_NID, VERB_SET_PIN_WIDGET, 16'h40);
        u_bfm.send_dac_sample(0, 24'hFF_0000, 24'h00_FF00);
        repeat (50) @(posedge bclk);
        spdif_toggle_ok = 1'b0;
        fork
            begin
                logic prev_s, cur_s;
                prev_s = spdif_out_sig[0];
                for (int i = 0; i < 500; i++) begin
                    @(posedge bclk);
                    cur_s = spdif_out_sig[0];
                    if (cur_s !== prev_s) begin
                        spdif_toggle_ok = 1'b1;
                        break;
                    end
                    prev_s = cur_s;
                end
            end
            begin
                repeat (1000) @(posedge bclk);
            end
        join_any
        disable fork;
        $display("G6.1 SPDIF toggled    = %s", pf(spdif_toggle_ok));
        if (!spdif_toggle_ok) errors++;

        // G6.2 -Disable SPDIF, output should stay silent
        u_bfm.write_verb(SPDIF_NID, VERB_SET_PIN_WIDGET, 16'h00);
        repeat (50) @(posedge bclk);
        begin
            logic prv, cur, silent;
            prv = spdif_out_sig[0];
            silent = 1'b1;
            for (int i = 0; i < 200; i++) begin
                @(posedge bclk);
                cur = spdif_out_sig[0];
                if (cur !== prv) silent = 1'b0;
                prv = cur;
            end
            $display("G6.2 SPDIF silent     = %s", pf(silent));
            if (!silent) errors++;
        end

        $display("G6 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G7: BEEP Generator
        //======================================================================
        $display("--- G7: BEEP Generator ---");
        group_start_errors = errors;

        // G7.1 -Enable BEEP at high frequency, verify toggling
        u_bfm.write_verb(BEEP_NID, VERB_SET_BEEP, 16'hFF); // enable + max freq div
        repeat (50) @(posedge bclk);
        beep_toggle_ok = 1'b0;
        beep_sampled0 = beep_out;
        for (int i = 0; i < 300; i++) begin
            @(posedge bclk);
            if (beep_out !== beep_sampled0) begin
                beep_toggle_ok = 1'b1;
                break;
            end
        end
        $display("G7.1 BEEP toggled     = %s",
                 pf(beep_toggle_ok));
        if (!beep_toggle_ok) errors++;

        // G7.2 -Disable BEEP, output should stop
        u_bfm.write_verb(BEEP_NID, VERB_SET_BEEP, 16'h00);
        repeat (100) @(posedge bclk);
        $display("G7.2 BEEP disabled    = %b (exp 0) %s",
                 beep_out, pf(beep_out===1'b0));
        if (beep_out !== 1'b0) errors++;

        // G7.3 -BEEP generator readback
        u_bfm.write_verb(BEEP_NID, VERB_SET_BEEP, 16'h44);
        u_bfm.read_verb (BEEP_NID, VERB_GET_BEEP, 16'h0, rdata);
        $display("G7.3 BEEP readback    = 0x%02X (exp 0x44) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h44));
        if (rdata[7:0] !== 8'h44) errors++;
        u_bfm.write_verb(BEEP_NID, VERB_SET_BEEP, 16'h00);

        $display("G7 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G8: Miscellaneous Verbs
        //======================================================================
        $display("--- G8: Miscellaneous ---");
        group_start_errors = errors;

        // G8.1 -EAPD write/readback
        u_bfm.write_verb(HP_NID, VERB_SET_EAPD, 16'h0002);
        u_bfm.read_verb (HP_NID, VERB_GET_EAPD, 16'h0, rdata);
        $display("G8.1 EAPD             = 0x%02X (exp 0x02) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h02));
        if (rdata[7:0] !== 8'h02) errors++;

        // G8.2 -Subsystem ID write/readback (4-byte assembly)
        for (int b = 0; b < 4; b++) begin
            u_bfm.write_verb(HP_NID,
                (b==0) ? VERB_SET_SUBSYSTEM_ID0 :
                (b==1) ? VERB_SET_SUBSYSTEM_ID1 :
                (b==2) ? VERB_SET_SUBSYSTEM_ID2 :
                         VERB_SET_SUBSYSTEM_ID3,
                16'(8'hAB + b));
        end
        u_bfm.read_verb(HP_NID, VERB_GET_SUBSYSTEM_ID, 16'h0, rdata);
        $display("G8.2 Subsystem ID     = 0x%08X (exp 0xAEADACAB) %s",
                 rdata, pf(rdata === 32'hAEADACAB));
        if (rdata !== 32'hAEADACAB) errors++;

        // G8.3 -Config Default write/readback
        for (int b = 0; b < 4; b++) begin
            u_bfm.write_verb(HP_NID,
                (b==0) ? VERB_SET_CONFIG_DEFAULT0 :
                (b==1) ? VERB_SET_CONFIG_DEFAULT1 :
                (b==2) ? VERB_SET_CONFIG_DEFAULT2 :
                         VERB_SET_CONFIG_DEFAULT3,
                16'(8'h10 + b));
        end
        u_bfm.read_verb(HP_NID, VERB_GET_CONFIG_DEFAULT, 16'h0, rdata);
        $display("G8.3 Config Default   = 0x%08X (exp 0x13121110) %s",
                 rdata, pf(rdata === 32'h13121110));
        if (rdata !== 32'h13121110) errors++;

        // G8.4 -Connection Select on DAC0
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONN_SELECT, 16'h0000);
        u_bfm.read_verb (DAC0_NID, VERB_GET_CONN_SELECT, 16'h0, rdata);
        $display("G8.4 DAC0 ConnSelect  = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;

        // G8.5 -Unsolicited Control enable + tag
        u_bfm.write_verb(HP_NID, VERB_SET_UNSOL_CONTROL, 16'h0080);
        u_bfm.read_verb (HP_NID, VERB_GET_UNSOL_CONTROL, 16'h0, rdata);
        $display("G8.5 Unsol Control    = 0x%02X (exp 0x80) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h80));
        if (rdata[7:0] !== 8'h80) errors++;

        // G8.6 -Volume Knob
        u_bfm.write_verb(AFG_NID, VERB_SET_VOL_KNOB, 16'h0055);
        u_bfm.read_verb (AFG_NID, VERB_GET_VOL_KNOB, 16'h0, rdata);
        $display("G8.6 Vol Knob         = 0x%02X (exp 0x55) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h55));
        if (rdata[7:0] !== 8'h55) errors++;

        $display("G8 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G9: Function Reset
        //======================================================================
        $display("--- G9: Function Reset ---");
        group_start_errors = errors;

        // Set some state, then reset
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h40);
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB03F);
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0005);

        // G9.1 -Function Reset on DAC0 clears amp/stream
        u_bfm.write_verb(DAC0_NID, VERB_FUNCTION_RESET, 16'h0000);
        repeat (10) @(posedge bclk);
        u_bfm.read_verb(DAC0_NID, VERB_GET_AMP_GAIN, 16'h0, rdata);
        $display("G9.1 Amp after reset  = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;
        u_bfm.read_verb(DAC0_NID, VERB_GET_CONV_STREAM, 16'h0, rdata);
        $display("G9.1 Stream aft reset = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;

        // G9.2 -Function Reset on HP pin clears Pin Widget Control
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h40);
        u_bfm.write_verb(HP_NID, VERB_FUNCTION_RESET, 16'h0000);
        repeat (10) @(posedge bclk);
        u_bfm.read_verb(HP_NID, VERB_GET_PIN_WIDGET, 16'h0, rdata);
        $display("G9.2 PinCtl aft reset = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;

        // G9.3 -Function Reset on AFG clears unsol
        u_bfm.write_verb(AFG_NID, VERB_SET_UNSOL_CONTROL, 16'h0080);
        u_bfm.write_verb(AFG_NID, VERB_FUNCTION_RESET, 16'h0000);
        repeat (10) @(posedge bclk);
        u_bfm.read_verb(AFG_NID, VERB_GET_UNSOL_CONTROL, 16'h0, rdata);
        $display("G9.3 Unsol aft reset  = 0x%02X (exp 0x00) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h00));
        if (rdata[7:0] !== 8'h00) errors++;

        $display("G9 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G10: GPIO
        //======================================================================
        $display("--- G10: GPIO ---");
        group_start_errors = errors;

        // G10.1 -GPIO Data write/readback
        u_bfm.write_verb(AFG_NID, VERB_SET_GPIO_DATA, 16'h0055);
        u_bfm.read_verb (AFG_NID, VERB_GET_GPIO_DATA, 16'h0, rdata);
        $display("G10.1 GPIO Data       = 0x%02X (exp 0x55) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h55));
        if (rdata[7:0] !== 8'h55) errors++;

        // G10.2 -GPIO Enable write/readback
        u_bfm.write_verb(AFG_NID, VERB_SET_GPIO_ENABLE, 16'h0003);
        u_bfm.read_verb (AFG_NID, VERB_GET_GPIO_ENABLE, 16'h0, rdata);
        $display("G10.2 GPIO Enable     = 0x%02X (exp 0x03) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h03));
        if (rdata[7:0] !== 8'h03) errors++;

        // G10.3 -GPIO Direction write/readback
        u_bfm.write_verb(AFG_NID, VERB_SET_GPIO_DIRECTION, 16'h000F);
        u_bfm.read_verb (AFG_NID, VERB_GET_GPIO_DIRECTION, 16'h0, rdata);
        $display("G10.3 GPIO Direction  = 0x%02X (exp 0x0F) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h0F));
        if (rdata[7:0] !== 8'h0F) errors++;

        // G10.4 -GPIO Wake write/readback
        u_bfm.write_verb(AFG_NID, VERB_SET_GPIO_WAKE, 16'h0001);
        u_bfm.read_verb (AFG_NID, VERB_GET_GPIO_WAKE, 16'h0, rdata);
        $display("G10.4 GPIO Wake       = 0x%02X (exp 0x01) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h01));
        if (rdata[7:0] !== 8'h01) errors++;

        // G10.5 -GPIO Unsolicited mask write/readback
        u_bfm.write_verb(AFG_NID, VERB_SET_GPIO_UNSOL, 16'h0006);
        u_bfm.read_verb (AFG_NID, VERB_GET_GPIO_UNSOL, 16'h0, rdata);
        $display("G10.5 GPIO UnsolMask  = 0x%02X (exp 0x06) %s",
                 rdata[7:0], pf(rdata[7:0]===8'h06));
        if (rdata[7:0] !== 8'h06) errors++;

        $display("G10 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G11: Robustness -Invalid Access
        //======================================================================
        $display("--- G11: Robustness ---");
        group_start_errors = errors;
        group_start_warnings = warnings;

        // G11.1 -Read from NID beyond NID_MAX should return 0 (not hang)
        u_bfm.read_verb(NID_MAX + 8'h10, VERB_GET_PARAM, 16'h0009, rdata);
        $display("G11.1 Invalid NID     = 0x%08X (exp 0x0) %s",
                 rdata, pf(rdata===32'h0));
        if (rdata !== 32'h0) warnings++;

        // G11.2 -Unsupported verb on DAC0 should return 0 (not hang)
        u_bfm.read_verb(DAC0_NID, VERB_GET_DIGI_CONV1, 16'h0, rdata);
        $display("G11.2 DAC0 DigiConv1  = 0x%08X (exp 0x0) %s",
                 rdata, pf(rdata === 32'h0));
        if (rdata !== 32'h0) warnings++;

        // G11.3 -Write to root NID should not hang, read back should return 0
        u_bfm.write_verb(8'h00, VERB_SET_PIN_WIDGET, 16'h0000);
        u_bfm.read_verb(8'h00, VERB_GET_PIN_WIDGET, 16'h0, rdata);
        $display("G11.3 Root PinWidget  = 0x%08X (exp 0x0) %s",
                 rdata, pf(rdata === 32'h0));
        if (rdata !== 32'h0) warnings++;

        // G11.4 -Write to unmapped NID should not hang
        u_bfm.write_verb(8'h7F, VERB_SET_AMP_GAIN, 16'hB000);
        u_bfm.read_verb(8'h7F, VERB_GET_AMP_GAIN, 16'h0, rdata);
        $display("G11.4 NID 0x7F AmpGn  = 0x%08X (exp 0x0) %s",
                 rdata, pf(rdata === 32'h0));
        if (rdata !== 32'h0) warnings++;

        $display("G11 result: %0d new warning(s)\n", warnings - group_start_warnings);

        //======================================================================
        // G12: Link Sampling Robustness
        //======================================================================
        // Verify that DDR SDO capture is bit-accurate regardless of pattern.
        // Any cmd_shift alignment error (e.g. 4-bit offset) would cause the
        // verb engine to decode the wrong NID/verb and return 0 or wrong data.
        //======================================================================
        $display("--- G12: Link Sampling Robustness ---");
        group_start_errors = errors;

        // G12.1 -Back-to-back reads: verify frame_start clears cmd_shift
        u_bfm.read_verb(AFG_NID, VERB_GET_PARAM, 16'h0000, rdata);
        $display("G12.1 Back2Back #1    = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_VENDOR, pf(rdata===EXP_VENDOR));
        if (rdata !== EXP_VENDOR) errors++;
        u_bfm.read_verb(8'h00, VERB_GET_PARAM, 16'h0002, rdata);
        $display("G12.1 Back2Back #2    = 0x%08X (exp 0x%08X) %s",
                 rdata, EXP_REV_ID, pf(rdata===EXP_REV_ID));
        if (rdata !== EXP_REV_ID) errors++;

        // G12.2 -Write/readback with alternating bit pattern (0xAA)
        //         Tests nibble-boundary alignment in DDR pairs.
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB0AA);
        u_bfm.read_verb(DAC0_NID, VERB_GET_AMP_GAIN, 16'h8000, rdata);
        $display("G12.2 AmpGain 0xAA   = 0x%02X (exp 0xAA) %s",
                 rdata[6:0], pf(rdata[6:0]===7'h2A));
        if (rdata[6:0] !== 7'h2A) errors++;

        // G12.3 -Write/readback with 0x55 (complement of G12.2)
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB055);
        u_bfm.read_verb(DAC0_NID, VERB_GET_AMP_GAIN, 16'h8000, rdata);
        $display("G12.3 AmpGain 0x55   = 0x%02X (exp 0x55) %s",
                 rdata[6:0], pf(rdata[6:0]===7'h55));
        if (rdata[6:0] !== 7'h55) errors++;

        // G12.4 -All-ones payload: stress all DDR bit positions
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB07F);
        u_bfm.read_verb(DAC0_NID, VERB_GET_AMP_GAIN, 16'h8000, rdata);
        $display("G12.4 AmpGain 0x7F   = 0x%02X (exp 0x7F) %s",
                 rdata[6:0], pf(rdata[6:0]===7'h7F));
        if (rdata[6:0] !== 7'h7F) errors++;

        // G12.5 -All-zeros payload after all-ones: verify clean transition
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);
        u_bfm.read_verb(DAC0_NID, VERB_GET_AMP_GAIN, 16'h8000, rdata);
        $display("G12.5 AmpGain 0x00   = 0x%02X (exp 0x00) %s",
                 rdata[6:0], pf(rdata[6:0]===7'h00));
        if (rdata[6:0] !== 7'h00) errors++;

        // G12.6 -Raw 40-bit pattern: NID=0, verb=F, param=0 (Vendor ID)
        //         Bit pattern has 0xF at nibble boundary [19:16].
        //         A 4-bit DDR shift error would move it to [23:20] or [15:12],
        //         causing the codec to decode a wrong verb/NID -return 0.
        begin
            logic [35:0] raw_resp;
            // {8'h00, codec_addr=4'h0, nid=8'h00, verb=4'hF, param=16'h0000}
            u_bfm.send_raw_cmd(40'h00_000F_0000, raw_resp);
            $display("G12.6 Raw Root VID   = 0x%08X (exp 0x%08X) %s",
                     raw_resp[31:0], EXP_VENDOR, pf(raw_resp[31:0]===EXP_VENDOR));
            if (raw_resp[31:0] !== EXP_VENDOR) errors++;
        end

        // G12.7 -Raw pattern with alternating nibbles (0xA5A5...)
        //         cmd = {8'h00, 4'h0, NID=AFG, verb=F, param=0} -Get Vendor
        begin
            logic [35:0] raw_resp;
            logic [39:0] raw_cmd;
            raw_cmd = {8'h00, 4'h0, AFG_NID, 4'hF, 16'h0000};
            u_bfm.send_raw_cmd(raw_cmd, raw_resp);
            $display("G12.7 Raw AFG Vendor = 0x%08X (exp 0x%08X) %s",
                     raw_resp[31:0], EXP_VENDOR, pf(raw_resp[31:0]===EXP_VENDOR));
            if (raw_resp[31:0] !== EXP_VENDOR) errors++;
        end

        $display("G12 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G13: Response Field Format (§7.3.1 / Figure 59)
        //======================================================================
        // A standard controller only accepts a response when the Valid bit
        // (SDI bit 35) is set, and the codec address is NOT carried in the
        // response field.  This guards against a codec that "passes" data-only
        // checks but fails on a real controller because Valid is never set.
        $display("--- G13: Response Field Format ---");
        group_start_errors = errors;
        begin
            logic [35:0] fr;
            u_bfm.send_command(4'h0, AFG_NID, VERB_GET_PARAM, 16'h0000, fr);
            $display("G13.1 Valid bit [35]  = %b (exp 1) %s",
                     fr[35], pf(fr[35]===1'b1));
            if (fr[35] !== 1'b1) errors++;
            $display("G13.2 UnSol bit [34]  = %b (exp 0) %s",
                     fr[34], pf(fr[34]===1'b0));
            if (fr[34] !== 1'b0) errors++;
            $display("G13.3 Reserved [33:32]= %b (exp 00) %s",
                     fr[33:32], pf(fr[33:32]===2'b00));
            if (fr[33:32] !== 2'b00) errors++;
            $display("G13.4 Response  [31:0]= 0x%08X (exp 0x%08X) %s",
                     fr[31:0], EXP_VENDOR, pf(fr[31:0]===EXP_VENDOR));
            if (fr[31:0] !== EXP_VENDOR) errors++;
        end
        $display("G13 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G14: Link Stream Tags (§5.3.2.1 / §5.3.3.1)
        //======================================================================
        $display("--- G14: Link Stream Tags ---");
        group_start_errors = errors;

        // ---- Outbound stream tag filtering (§5.3.2.1) ----

        // G14.1 -No stream tag configured (default): DAC data accepted
        //         (backward compatibility: stream_tag_cfg == 0 -accept all)
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0001);  // tag=0, ch=1
        u_bfm.write_verb(HP_NID, VERB_SET_PIN_WIDGET, 16'h40);  // out enable
        u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);  // unmute
        u_bfm.num_outbound_tags = 0;  // no SYNC tags
        u_bfm.send_dac_sample(0, 24'hAA_0000, 24'hBB_0000);
        repeat (50) @(posedge bclk);
        $display("G14.1 No-tag fallback L=0x%06X (exp 0xAA0000) %s",
                 hp_out_l, pf(hp_out_l===24'hAA_0000));
        if (hp_out_l !== 24'hAA_0000) errors++;

        // G14.2 -Set DAC0 stream tag to 5, send matching tag -data accepted
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0051);  // tag=5, ch=1
        u_bfm.send_dac_sample_tagged(0, 4'd5, 24'hCC_1111, 24'hDD_2222);
        repeat (50) @(posedge bclk);
        $display("G14.2 Tag match   L=0x%06X (exp 0xCC1111) %s",
                 hp_out_l, pf(hp_out_l===24'hCC_1111));
        if (hp_out_l !== 24'hCC_1111) errors++;

        // G14.3 -Send non-matching tag (tag=3) -data rejected (HP holds prev)
        u_bfm.send_dac_sample_tagged(0, 4'd3, 24'hEE_3333, 24'hFF_4444);
        repeat (50) @(posedge bclk);
        $display("G14.3 Tag mismatch L=0x%06X (exp 0xCC1111, prev) %s",
                 hp_out_l, pf(hp_out_l===24'hCC_1111));
        if (hp_out_l !== 24'hCC_1111) errors++;

        // G14.4 -Send matching tag again -new data accepted
        u_bfm.send_dac_sample_tagged(0, 4'd5, 24'h55_AAAA, 24'h66_BBBB);
        repeat (50) @(posedge bclk);
        $display("G14.4 Tag re-match L=0x%06X (exp 0x55AAAA) %s",
                 hp_out_l, pf(hp_out_l===24'h55_AAAA));
        if (hp_out_l !== 24'h55_AAAA) errors++;

        // Clean up: reset DAC0 stream tag to 0 (default, accept all)
        u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0001);
        u_bfm.num_outbound_tags = 0;

        // ---- Inbound stream tags (§5.3.3.1) ----

        // G14.5 -Set ADC0 stream tag, capture inbound tag from SDI
        u_bfm.write_verb(ADC0_NID, VERB_SET_CONV_STREAM, 16'h0032);  // tag=3, ch=2
        begin
            logic [3:0] cap_ids  [0:MAX_ADC-1];
            int         cap_lens [0:MAX_ADC-1];
            int         cap_num;
            // Send idle command to advance one frame, then capture inbound tags
            u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);
            u_bfm.capture_inbound_tags(cap_ids, cap_lens, cap_num);
            $display("G14.5 Inbound tag0 ID=%0d len=%0d (exp ID=3 len=6) %s",
                     cap_ids[0], cap_lens[0],
                     pf(cap_ids[0]==4'd3 && cap_lens[0]==6));
            if (cap_ids[0] != 4'd3 || cap_lens[0] != 6) errors++;
        end

        // G14.6 -ADC0 tag=0 (default) -inbound tag reports stream_id=0
        u_bfm.write_verb(ADC0_NID, VERB_SET_CONV_STREAM, 16'h0002);  // tag=0, ch=2
        begin
            logic [3:0] cap_ids  [0:MAX_ADC-1];
            int         cap_lens [0:MAX_ADC-1];
            int         cap_num;
            u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN, 16'hB000);
            u_bfm.capture_inbound_tags(cap_ids, cap_lens, cap_num);
            $display("G14.6 Inbound tag0 ID=%0d len=%0d (exp ID=0 len=6) %s",
                     cap_ids[0], cap_lens[0],
                     pf(cap_ids[0]==4'd0 && cap_lens[0]==6));
            if (cap_ids[0] != 4'd0 || cap_lens[0] != 6) errors++;
        end

        $display("G14 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // G15: High Sample Rate & Stream Format (conv_format effective)
        //======================================================================
        $display("--- G15: High Sample Rate & Stream Format ---");
        group_start_errors = errors;
        begin : g15_blk
            int vcnt;

            // Common setup: HP enabled, unmuted, stream tag 0 (accept all)
            u_bfm.write_verb(HP_NID,   VERB_SET_PIN_WIDGET,  16'h40);
            u_bfm.write_verb(DAC0_NID, VERB_SET_AMP_GAIN,    16'hB000);
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_STREAM, 16'h0001); // tag=0
            u_bfm.num_outbound_tags = 0;

            // G15.1 -48 kHz (1 block/frame): baseline single dac_valid pulse
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0031); // 48k 24b 2ch
            vcnt = 0;
            fork
                u_bfm.send_dac_sample_hs(0, 1, 24'h11_0000, 24'h12_0000,
                                               24'h0, 24'h0, 24'h0, 24'h0, 24'h0, 24'h0);
                count_dac_valid(0, vcnt);
            join
            $display("G15.1 48kHz blocks/frame = %0d (exp 1), HP L=0x%06X %s",
                     vcnt, hp_out_l, pf(vcnt==1 && hp_out_l===24'h11_0000));
            if (vcnt != 1 || hp_out_l !== 24'h11_0000) errors++;

            // G15.2 -96 kHz (2 blocks/frame): 2 dac_valid pulses, HP = 2nd block
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0831); // mult x2 = 96kHz
            vcnt = 0;
            fork
                u_bfm.send_dac_sample_hs(0, 2, 24'hAA_0000, 24'hAB_0000,
                                               24'hBB_0000, 24'hBC_0000,
                                               24'h0, 24'h0, 24'h0, 24'h0);
                count_dac_valid(0, vcnt);
            join
            $display("G15.2 96kHz blocks/frame = %0d (exp 2), HP L=0x%06X (exp 0xBB0000) %s",
                     vcnt, hp_out_l, pf(vcnt==2 && hp_out_l===24'hBB_0000));
            if (vcnt != 2 || hp_out_l !== 24'hBB_0000) errors++;

            // G15.3 -192 kHz (4 blocks/frame): 4 dac_valid pulses, HP = 4th block
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h1831); // mult x4 = 192kHz
            vcnt = 0;
            fork
                u_bfm.send_dac_sample_hs(0, 4, 24'h10_0000, 24'h11_0000,
                                               24'h20_0000, 24'h21_0000,
                                               24'h30_0000, 24'h31_0000,
                                               24'h40_0000, 24'h41_0000);
                count_dac_valid(0, vcnt);
            join
            $display("G15.3 192kHz blocks/frame= %0d (exp 4), HP L=0x%06X (exp 0x400000) %s",
                     vcnt, hp_out_l, pf(vcnt==4 && hp_out_l===24'h40_0000));
            if (vcnt != 4 || hp_out_l !== 24'h40_0000) errors++;

            // G15.4 -Bit depth: 16-bit format masks the container's low 8 bits
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0011); // 48k 16b 2ch
            u_bfm.send_dac_sample(0, 24'h12_3456, 24'h78_9ABC);
            repeat (60) @(posedge bclk);
            $display("G15.4 16-bit mask L=0x%06X (exp 0x123400) %s",
                     hp_out_l, pf(hp_out_l===24'h12_3400));
            if (hp_out_l !== 24'h12_3400) errors++;

            // G15.5 -20-bit format masks the container's low 4 bits
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0021); // 48k 20b 2ch
            u_bfm.send_dac_sample(0, 24'hAB_CDEF, 24'h12_3456);
            repeat (60) @(posedge bclk);
            $display("G15.5 20-bit mask L=0x%06X (exp 0xABCDE0) %s",
                     hp_out_l, pf(hp_out_l===24'hAB_CDE0));
            if (hp_out_l !== 24'hAB_CDE0) errors++;

            // G15.6 -Mono (1ch): right channel duplicates left
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0030); // 24b 1ch (ch-1=0)
            u_bfm.send_dac_sample(0, 24'h5A_5A5A, 24'hA5_A5A5);
            repeat (60) @(posedge bclk);
            $display("G15.6 Mono R=L  L=0x%06X R=0x%06X (exp both 0x5A5A5A) %s",
                     hp_out_l, hp_out_r,
                     pf(hp_out_l===24'h5A_5A5A && hp_out_r===24'h5A_5A5A));
            if (hp_out_l !== 24'h5A_5A5A || hp_out_r !== 24'h5A_5A5A) errors++;

            // Restore 24-bit stereo 48 kHz
            u_bfm.write_verb(DAC0_NID, VERB_SET_CONV_FMT, 16'h0031);
        end
        $display("G15 result: %0d new error(s)\n", errors - group_start_errors);

        //======================================================================
        // Summary
        //======================================================================
        $display("============================================================");
        $display("=== %s result: %s ===",
                 chip_name(CID),
                 (errors==0) ? "ALL TESTS PASSED" : "TESTS FAILED");
        $display("=== Errors=%0d  Warnings=%0d ===", errors, warnings);
        $display("============================================================\n");
        $finish;
    end

endmodule
