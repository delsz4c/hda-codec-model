`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Parameterized Top Level
//------------------------------------------------------------------------------
// Instantiate with CHIP_ID to select codec model:
//   0 = ALC269  (laptop/mobile,  2 DAC + 2 ADC, 2 SPDIF, 2 GPIO)
//   1 = ALC662  (desktop 5.1,    3 DAC + 2 ADC, 1 SPDIF, 2 GPIO)
//   2 = ALC892  (desktop 7.1,    4 DAC + 3 ADC, 1 SPDIF, 4 GPIO)
//   3 = ALC256  (ultrabook/tablet, 2 DAC + 2 ADC, 1 SPDIF, 3 GPIO)
//
// Audio output mapping (active channels depend on CHIP_ID):
//   hp_out      — Headphone          (all chips)
//   front_out   — Front / Line-Out1  (all chips)
//   surr_out    — Surround / SPK     (all chips)
//   clfe_out    — Center+LFE / LOUT2 (ALC662/892 true CLFE; ALC269 = LOUT2)
//   side_out    — Side speakers      (ALC892 only)
//   mono_out    — Mono mix-down      (ALC269 only)
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_codec_top #(
    parameter int CHIP_ID = 0
) (
    // HDA serial link
    input  logic sdo,
    output logic sdi,
    output logic sdi_oe,           // SDI output-enable (tristate)
    input  logic sdi_in,           // SDI input (controller drives during address frame)
    input  logic bclk,
    input  logic sync,
    input  logic reset_n,
    input  logic pd_n,
    // GPIO (active count = cfg_num_gpio)
    inout  wire  [hda_codec_pkg::MAX_GPIO-1:0] gpio,
    input  logic dmic_mode_en,
    input  logic dmic_data_in,
    output logic dmic_clk_out,
    // Audio output stubs
    output logic [23:0] hp_out_l,    hp_out_r,
    output logic [23:0] front_out_l, front_out_r,
    output logic [23:0] surr_out_l,  surr_out_r,
    output logic [23:0] clfe_out_l,  clfe_out_r,
    output logic [23:0] side_out_l,  side_out_r,
    output logic [23:0] mono_out,
    // Audio input stubs
    input  logic [23:0] mic1_l,  mic1_r,
    input  logic [23:0] mic2_l,  mic2_r,
    input  logic [23:0] line1_l, line1_r,
    input  logic [23:0] line2_l, line2_r,
    // S/PDIF outputs
    output logic [hda_codec_pkg::MAX_SPDIF-1:0] spdif_out,
    // Beep
    input  logic pcbeep_in,
    output logic beep_out,
    // Test
    input  logic loopback_en,
    // Status
    output logic codec_ready,
    output logic afg_powered,
    output logic dac_powered,
    output logic adc_powered,
    output logic spdif_powered
);

    import hda_codec_pkg::*;

    // Derived constants (resolved at elaboration)
    localparam int NUM_DAC   = cfg_num_dac(CHIP_ID);
    localparam int NUM_ADC   = cfg_num_adc(CHIP_ID);
    localparam int NUM_SPDIF = cfg_num_spdif(CHIP_ID);
    localparam int NUM_GPIO  = cfg_num_gpio(CHIP_ID);

    // Link initialization
    logic        link_init_done;
    logic [3:0]  link_codec_addr;
    logic        codec_ready_pwr;

    // Link v2 extended status
    logic [3:0]  link_state_out;
    logic        link_frame_error;
    logic        link_sync_lost;
    logic        link_active;

    // Link v2 power management interface
    logic        codec_wake_sig;
    logic        link_sleep_sig /* synthesis syn_keep = 1 */;

    // Stream tag configuration for DAC/ADC slots (from widget conv_stream registers)
    logic [3:0]  stream_tag_cfg     [0:MAX_DAC-1];
    logic [3:0]  stream_tag_cfg_adc [0:MAX_ADC-1];

    // Per-DAC sample-blocks-per-frame (from widget conv_format): 48kHz=1,96kHz=2,192kHz=4
    logic [2:0]  dac_rate_mult      [0:MAX_DAC-1];

    // Internal buses
    logic                     cmd_valid;
    logic [HDA_CMD_BITS-1:0]  cmd_data;
    logic                     resp_valid;
    logic [HDA_RESP_BITS-1:0] resp_data;

    logic [MAX_DAC-1:0] dac_valid;
    logic [23:0] dac_sample_l [0:MAX_DAC-1];
    logic [23:0] dac_sample_r [0:MAX_DAC-1];
    logic [MAX_ADC-1:0] adc_valid;
    logic [23:0] adc_sample_l [0:MAX_ADC-1];
    logic [23:0] adc_sample_r [0:MAX_ADC-1];

    widget_state_t widget_state [0:WS_SIZE-1];

    logic        gpio_unsol_valid;
    logic [31:0] gpio_unsol_data;
    logic [7:0]  gpio_data_in;

    // ---- Codec wake / sleep derivation ----
    // codec_wake: asserted when power is applied (pd_n rising) or on D3→D0 transition
    assign codec_wake_sig = pd_n & reset_n;
    // link_sleep: HDA link stays active regardless of AFG power state (§5.4.3).
    // The link clock is controller-driven; codec D3 only affects internal audio
    // processing, not link-layer communication.  Physical power-down uses rst_n.
    assign link_sleep_sig = 1'b0;

    // ---- Stream tag extraction from widget conv_stream registers ----
    // conv_stream format: {stream_tag[7:4], channel[3:0]}
    generate
        for (genvar si = 0; si < MAX_DAC; si++) begin : g_stag
            if (si < NUM_DAC) begin : g_active
                localparam logic [7:0] DAC_NID = nid_dac(CHIP_ID, si);
                assign stream_tag_cfg[si] = widget_state[DAC_NID].conv_stream[7:4];
            end else begin : g_tie
                assign stream_tag_cfg[si] = 4'h0;
            end
        end
        for (genvar ai = 0; ai < MAX_ADC; ai++) begin : g_stag_adc
            if (ai < NUM_ADC) begin : g_active
                localparam logic [7:0] ADC_NID = nid_adc(CHIP_ID, ai);
                assign stream_tag_cfg_adc[ai] = widget_state[ADC_NID].conv_stream[7:4];
            end else begin : g_tie
                assign stream_tag_cfg_adc[ai] = 4'h0;
            end
        end
    endgenerate

    // ---- Sample-rate multiple extraction from widget conv_format registers ----
    // High sample rates transfer multiple sample blocks per 48 kHz frame
    // (§3.3.34): 48kHz=1, 96kHz=2, 192kHz=4 blocks per frame.
    generate
        for (genvar si = 0; si < MAX_DAC; si++) begin : g_ratem
            if (si < NUM_DAC) begin : g_active
                localparam logic [7:0] DAC_NID = nid_dac(CHIP_ID, si);
                assign dac_rate_mult[si] = 3'(fmt_rate_mult(widget_state[DAC_NID].conv_format));
            end else begin : g_tie
                assign dac_rate_mult[si] = 3'd1;
            end
        end
    endgenerate

    // ---- HDA Link ----
    hda_link #(
        .NUM_DAC (NUM_DAC),
        .NUM_ADC (NUM_ADC)
    ) u_hda_link (
        .clk            (bclk),
        .rst_n          (reset_n & pd_n),
        .sdo            (sdo),
        .sdi            (sdi),
        .sdi_oe         (sdi_oe),
        .sdi_in         (sdi_in),
        .sync           (sync),
        .init_done      (link_init_done),
        .codec_addr_out (link_codec_addr),
        .link_state_out (link_state_out),
        .frame_error    (link_frame_error),
        .sync_lost      (link_sync_lost),
        .link_active    (link_active),
        .codec_wake     (codec_wake_sig),
        .link_sleep     (link_sleep_sig),
        .cmd_valid      (cmd_valid),
        .cmd_data       (cmd_data),
        .resp_valid     (resp_valid),
        .resp_data      (resp_data),
        .stream_tag_cfg     (stream_tag_cfg),
        .stream_tag_cfg_adc (stream_tag_cfg_adc),
        .dac_rate_mult      (dac_rate_mult),
        .dac_valid      (dac_valid),
        .dac_sample_l   (dac_sample_l),
        .dac_sample_r   (dac_sample_r),
        .adc_valid      (adc_valid),
        .adc_sample_l   (adc_sample_l),
        .adc_sample_r   (adc_sample_r)
    );

    // ---- Verb Engine (includes widget register file) ----
    hda_verb_engine #(.CHIP_ID(CHIP_ID)) u_verb_engine (
        .clk             (bclk),
        .rst_n           (reset_n & pd_n),
        .codec_addr      (link_codec_addr),
        .cmd_valid       (cmd_valid),
        .cmd_data        (cmd_data),
        .resp_valid      (resp_valid),
        .resp_data       (resp_data),
        .widget_state    (widget_state),
        .gpio_unsol_valid(gpio_unsol_valid),
        .gpio_unsol_data (gpio_unsol_data),
        .pin_sense_valid (1'b0),
        .pin_sense_data  (32'h0)
    );

    // ---- Audio Path ----
    hda_audio_path #(.CHIP_ID(CHIP_ID)) u_audio_path (
        .clk          (bclk),
        .rst_n        (reset_n & pd_n),
        .dac_valid    (dac_valid),
        .dac_sample_l (dac_sample_l),
        .dac_sample_r (dac_sample_r),
        .adc_valid_out(adc_valid),
        .adc_sample_l (adc_sample_l),
        .adc_sample_r (adc_sample_r),
        .state        (widget_state),
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
        .loopback_en  (loopback_en)
    );

    // ---- GPIO ----
    hda_gpio_ctrl #(.NUM_GPIO(NUM_GPIO)) u_gpio_ctrl (
        .clk            (bclk),
        .rst_n          (reset_n & pd_n),
        .gpio           (gpio),
        .dmic_mode_en   (dmic_mode_en),
        .dmic_clk_out   (dmic_clk_out),
        .dmic_data_in   (dmic_data_in),
        .gpio_enable    (widget_state[8'h01].gpio_enable),
        .gpio_direction (widget_state[8'h01].gpio_direction),
        .gpio_wake      (widget_state[8'h01].gpio_wake),
        .gpio_unsol_en  (widget_state[8'h01].gpio_unsol_mask),
        .gpio_data_out  (widget_state[8'h01].gpio_data),
        .gpio_data_in   (gpio_data_in),
        .unsol_valid    (gpio_unsol_valid),
        .unsol_data     (gpio_unsol_data)
    );

    // ---- Beep Generator ----
    localparam logic [7:0] NID_BEEP_L = nid_beep(CHIP_ID);

    hda_beep_gen u_beep_gen (
        .clk       (bclk),
        .rst_n     (reset_n & pd_n),
        .beep_ctrl (widget_state[NID_BEEP_L].beep_gen),
        .beep_out  (beep_out)
    );

    // ---- S/PDIF ----
    localparam logic [7:0] NID_SPDIF0    = nid_spdif(CHIP_ID, 0);
    localparam logic [7:0] NID_SPDIF_PIN = nid_spdif_pin(CHIP_ID, 0);
    localparam logic [7:0] NID_SPDIF1    = (NUM_SPDIF >= 2) ? nid_spdif(CHIP_ID, 1) : 8'h00;

    hda_spdif_out #(.NUM_SPDIF(NUM_SPDIF)) u_spdif_out (
        .clk          (bclk),
        .rst_n        (reset_n & pd_n),
        .ch0_en       (widget_state[NID_SPDIF_PIN].pin_widget_ctrl[6] & spdif_powered),
        .ch0_sample_l (dac_sample_l[0]),
        .ch0_sample_r (dac_sample_r[0]),
        .ch0_spdif    (spdif_out[0]),
        .ch1_en       ((NUM_SPDIF >= 2) ?
                        (widget_state[NID_SPDIF1].pin_widget_ctrl[6] & spdif_powered) : 1'b0),
        .ch1_sample_l ((NUM_SPDIF >= 2) ? dac_sample_l[1] : 24'h0),
        .ch1_sample_r ((NUM_SPDIF >= 2) ? dac_sample_r[1] : 24'h0),
        .ch1_spdif    (spdif_out[1])
    );

    // ---- Power Management ----
    hda_pwr_mgmt #(.CHIP_ID(CHIP_ID)) u_pwr_mgmt (
        .rst_n         (reset_n),
        .pd_n          (pd_n),
        .state         (widget_state),
        .codec_ready   (codec_ready_pwr),
        .afg_powered   (afg_powered),
        .dac_powered   (dac_powered),
        .adc_powered   (adc_powered),
        .spdif_powered (spdif_powered)
    );

    // codec_ready requires both power-up and link initialization
    assign codec_ready = codec_ready_pwr && link_init_done;

endmodule
