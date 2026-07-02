`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Verb Engine
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_verb_engine #(
    parameter int CHIP_ID = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]                        codec_addr,
    input  logic                              cmd_valid,
    input  logic [hda_codec_pkg::HDA_CMD_BITS-1:0]  cmd_data,
    output logic                              resp_valid,
    output logic [hda_codec_pkg::HDA_RESP_BITS-1:0] resp_data,
    output hda_codec_pkg::widget_state_t widget_state [0:hda_codec_pkg::WS_SIZE-1],
    input  logic        gpio_unsol_valid,
    input  logic [31:0] gpio_unsol_data,
    input  logic        pin_sense_valid,
    input  logic [31:0] pin_sense_data
);

    import hda_codec_pkg::*;

    logic [3:0]  codec_addr_field;
    logic [7:0]  nid;
    logic [11:0] verb_id;
    logic [15:0] payload;
    logic        read_cmd;
    logic [31:0] reg_rdata;
    logic        reg_ack;

    assign codec_addr_field = cmd_data[31:28];
    assign nid              = cmd_data[27:20];

    // Decode 4-bit vs 12-bit verb format per HDA spec:
    // All 12-bit verbs in our model start with 0x7xx or 0xFxx.
    // Check bits [19:16]: if 0x7 or 0xF, it's a 12-bit verb.
    // Otherwise it's a 4-bit verb with 16-bit payload.
    always_comb begin
        if (cmd_data[19:16] == 4'h7 || cmd_data[19:16] == 4'hF) begin
            // 12-bit verb format: verb[11:0] in [19:8], payload[7:0] in [7:0]
            verb_id = cmd_data[19:8];
            payload = {8'h00, cmd_data[7:0]};
        end else begin
            // 4-bit verb format: verb[3:0] in [19:16], payload[15:0] in [15:0]
            verb_id = {8'h00, cmd_data[19:16]};
            payload = cmd_data[15:0];
        end
    end

    // Read vs write classification
    always_comb begin
        case (verb_id)
            VERB_GET_PARAM, VERB_GET_CONN_SELECT, VERB_GET_CONN_LIST,
            VERB_GET_PROC_STATE, VERB_GET_COEF_INDEX, VERB_GET_PROC_COEF,
            VERB_GET_AMP_GAIN, VERB_GET_CONV_FMT, VERB_GET_PWR_STATE,
            VERB_GET_CONV_STREAM, VERB_GET_PIN_WIDGET, VERB_GET_UNSOL_CONTROL,
            VERB_GET_PIN_SENSE, VERB_GET_BEEP, VERB_GET_EAPD,
            VERB_GET_DIGI_CONV1, VERB_GET_DIGI_CONV2, VERB_GET_VOL_KNOB,
            VERB_GET_GPIO_DATA, VERB_GET_GPIO_ENABLE, VERB_GET_GPIO_DIRECTION,
            VERB_GET_GPIO_WAKE, VERB_GET_GPIO_UNSOL, VERB_GET_SUBSYSTEM_ID,
            VERB_GET_CONFIG_DEFAULT: read_cmd = 1'b1;
            default: read_cmd = 1'b0;
        endcase
    end

    // Only act on commands addressed to this codec (dynamic address)
    logic cmd_accepted;
    assign cmd_accepted = cmd_valid && (codec_addr_field == codec_addr);

    hda_widget_regs #(.CHIP_ID(CHIP_ID)) u_widget_regs (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid    (cmd_accepted),
        .nid      (nid),
        .read     (read_cmd),
        .verb_id  (verb_id),
        .payload  (payload),
        .rdata    (reg_rdata),
        .ack      (reg_ack),
        .state_out(widget_state)
    );

    // One-cycle response pipeline
    logic        resp_vld_pipe;
    logic [31:0] resp_dat_pipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_vld_pipe <= 1'b0;
            resp_dat_pipe <= '0;
        end else begin
            if (cmd_valid && (codec_addr_field == codec_addr)) begin
                resp_vld_pipe <= 1'b1;
                resp_dat_pipe <= reg_rdata;
            end else begin
                resp_vld_pipe <= 1'b0;
            end
        end
    end

    assign resp_valid = resp_vld_pipe;
    // HDA Response Field (36-bit) — §7.3.1 / Figure 59:
    //   [35] Valid, [34] UnSol, [33:32] Reserved, [31:0] Response data.
    // A solicited response MUST assert Valid=1; a real controller discards the
    // response (writes nothing to the RIRB) when Valid=0.  The codec address is
    // NOT part of the response field — the controller infers it from which SDI
    // line carried the response.  UnSol=0 here (this model returns only
    // solicited responses).
    assign resp_data  = {1'b1, 1'b0, 2'b00, resp_dat_pipe};

endmodule
