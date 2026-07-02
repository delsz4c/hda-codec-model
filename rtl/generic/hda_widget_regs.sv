`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Widget Registers & Capability ROM
//------------------------------------------------------------------------------
// Parameterized by CHIP_ID.  All per-chip widget capabilities, connection
// lists, and pin capabilities are selected at elaboration time through
// generate-if blocks so only one chip's ROM remains after synthesis.
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_widget_regs #(
    parameter int CHIP_ID = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid,      // command accepted (gate writes)
    input  logic [7:0]  nid,
    input  logic        read,
    input  logic [11:0] verb_id,
    input  logic [15:0] payload,
    output logic [31:0] rdata,
    output logic        ack,
    output hda_codec_pkg::widget_state_t state_out [0:hda_codec_pkg::WS_SIZE-1]
);

    import hda_codec_pkg::*;

    widget_state_t state [0:WS_SIZE-1];

    //--------------------------------------------------------------------------
    // Connection list ROM (per-chip)
    //--------------------------------------------------------------------------
    function automatic logic [63:0] conn_list(logic [7:0] n);
        if (CHIP_ID == CHIP_ALC269) begin
            case (n)
                8'h07:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h24}; // ADC1→SUM
                8'h08:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h23}; // ADC2→MUX
                8'h02:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C};
                8'h03:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C};
                8'h0C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C}; // SPDIF1
                8'h10:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h10}; // SPDIF2
                8'h0D:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0D}; // HP
                8'h0E:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // LOUT1→DAC1
                8'h0F:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h03}; // LOUT2→DAC2
                8'h12:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // SPK+
                8'h13:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // SPK-
                8'h16:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // MONO
                8'h14:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1B,8'h1A}; // LINE2_SEL
                8'h15:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0D,8'h0C}; // LINE1_SEL
                8'h18:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h18}; // MIC2
                8'h19:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h19}; // MIC1
                8'h1A:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1A}; // LINE1
                8'h1B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1B}; // LINE2
                8'h1C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1C}; // BEEP
                8'h1D:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1D}; // PCBEEP
                8'h1E:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1E}; // DMIC
                8'h23:  return {8'h00,8'h0B,8'h12,8'h1D,8'h1B,8'h1A,8'h19,8'h18}; // MUX
                8'h24:  return {8'h00,8'h00,8'h0B,8'h1B,8'h1A,8'h19,8'h18,8'h23}; // SUM
                8'h0B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0B}; // MIXER
                default: return '0;
            endcase
        end else if (CHIP_ID == CHIP_ALC662) begin
            case (n)
                8'h08:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h22}; // ADC1→MUX
                8'h09:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C}; // ADC2→MIXER2
                8'h06:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // SPDIF1→DAC1
                8'h14:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // HP→DAC1
                8'h15:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // FRONT→DAC1
                8'h16:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h03}; // SURR→DAC2
                8'h17:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h04}; // CLFE→DAC3
                8'h0B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0B}; // MIXER
                8'h0C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C}; // MIXER2
                8'h22:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h0B,8'h1A,8'h18}; // MUX
                8'h18:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h18}; // MIC1
                8'h19:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h19}; // MIC2
                8'h1A:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1A}; // LINE1
                8'h1C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1C}; // BEEP
                default: return '0;
            endcase
        end else if (CHIP_ID == CHIP_ALC892) begin
            case (n)
                8'h08:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h22}; // ADC1→MUX1
                8'h09:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h23}; // ADC2→MUX2
                8'h0A:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h24}; // ADC3→SUM
                8'h06:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // SPDIF1→DAC1
                8'h14:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // HP→DAC1
                8'h15:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // FRONT→DAC1
                8'h16:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h03}; // SURR→DAC2
                8'h17:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h04}; // CLFE→DAC3
                8'h1E:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h05}; // SIDE→DAC4
                8'h0B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0B}; // MIXER
                8'h0C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h0C}; // MIXER2
                8'h22:  return {8'h00,8'h00,8'h00,8'h00,8'h0B,8'h1A,8'h19,8'h18}; // MUX1
                8'h23:  return {8'h00,8'h00,8'h00,8'h00,8'h0B,8'h1B,8'h1A,8'h18}; // MUX2
                8'h24:  return {8'h00,8'h00,8'h0B,8'h1B,8'h1A,8'h19,8'h18,8'h22}; // SUM
                8'h18:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h18};
                8'h19:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h19};
                8'h1A:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1A};
                8'h1B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1B};
                8'h1C:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h1C};
                default: return '0;
            endcase
        end else begin // CHIP_ALC256
            case (n)
                8'h07:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h24}; // DMIC conv → MUX
                8'h08:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h23}; // ADC0 → SUM23
                8'h09:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h22}; // ADC1 → SUM22
                8'h14:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h02}; // SPK-OUT → DAC0
                8'h1B:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h03,8'h02}; // LINE2 → DAC0/1
                8'h21:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h03,8'h02}; // HP-OUT → DAC0/1
                8'h1E:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h06}; // SPDIF-OUT → SPDIF conv
                8'h22:  return {8'h00,8'h00,8'h00,8'h1D,8'h1B,8'h1A,8'h19,8'h18}; // SUM22: 18,19,1A,1B,1D
                8'h23:  return {8'h00,8'h00,8'h1D,8'h12,8'h1B,8'h1A,8'h19,8'h18}; // SUM23: 18,19,1A,1B,12,1D
                8'h24:  return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h13,8'h12}; // DMIC MUX → DMIC12/13
                8'h12,8'h13,8'h18,8'h19,8'h1A,8'h1C,8'h1D,8'h20:
                        return {8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,n[7:0]};
                default: return '0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Connection list length
    //--------------------------------------------------------------------------
    function automatic logic [7:0] conn_list_len(logic [7:0] n);
        if (CHIP_ID == CHIP_ALC269) begin
            case (n)
                8'h07,8'h08,8'h0D,8'h0E,8'h0F,8'h12,8'h13,8'h16,
                8'h18,8'h19,8'h1A,8'h1B,8'h1C,8'h1D,8'h1E,
                8'h02,8'h03,8'h0C,8'h10,8'h0B: return 8'd1;
                8'h14,8'h15:                     return 8'd2;
                8'h23,8'h24:                     return 8'd7;
                default:                         return 8'd0;
            endcase
        end else if (CHIP_ID == CHIP_ALC662) begin
            case (n)
                8'h08,8'h09,8'h06,8'h14,8'h15,8'h16,8'h17,
                8'h18,8'h19,8'h1A,8'h1C,8'h0B,8'h0C: return 8'd1;
                8'h22:                                  return 8'd3;
                default:                                return 8'd0;
            endcase
        end else if (CHIP_ID == CHIP_ALC892) begin
            case (n)
                8'h08,8'h09,8'h0A,8'h06,8'h14,8'h15,8'h16,8'h17,8'h1E,
                8'h18,8'h19,8'h1A,8'h1B,8'h1C,8'h0B,8'h0C: return 8'd1;
                8'h22,8'h23:                                  return 8'd4;
                8'h24:                                        return 8'd6;
                default:                                      return 8'd0;
            endcase
        end else begin // CHIP_ALC256
            case (n)
                8'h07,8'h08,8'h09,8'h14,8'h1E,
                8'h12,8'h13,8'h18,8'h19,8'h1A,8'h1C,8'h1D,8'h20: return 8'd1;
                8'h1B,8'h21,8'h24:                                 return 8'd2;
                8'h22:                                             return 8'd5;
                8'h23:                                             return 8'd6;
                default:                                           return 8'd0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Widget capabilities ROM
    //--------------------------------------------------------------------------
    function automatic logic [31:0] get_widget_cap(logic [7:0] n);
        if (CHIP_ID == CHIP_ALC269) begin
            case (n)
                8'h02,8'h03:                return WCAP_DAC;
                8'h07,8'h08:                return WCAP_ADC;
                8'h0C,8'h10:                return WCAP_SPDIF;
                8'h0B:                       return WCAP_MIXER;
                8'h14,8'h15,8'h23:          return WCAP_SEL;
                8'h0D,8'h0E,8'h0F,8'h12,8'h13,8'h16,
                8'h18,8'h19,8'h1A,8'h1B:   return WCAP_PIN;
                8'h1C:                       return WCAP_BEEP;
                8'h1D,8'h1E:                 return WCAP_VENDOR;
                8'h24:                       return WCAP_SEL;
                default:                     return 32'h0;
            endcase
        end else if (CHIP_ID == CHIP_ALC662) begin
            case (n)
                8'h02,8'h03,8'h04:          return WCAP_DAC;
                8'h08,8'h09:                return WCAP_ADC;
                8'h06:                       return WCAP_SPDIF;
                8'h0B,8'h0C:                return WCAP_MIXER;
                8'h22:                       return WCAP_SEL;
                8'h14,8'h15,8'h16,8'h17,
                8'h18,8'h19,8'h1A:          return WCAP_PIN;
                8'h1C:                       return WCAP_BEEP;
                default:                     return 32'h0;
            endcase
        end else if (CHIP_ID == CHIP_ALC892) begin
            case (n)
                8'h02,8'h03,8'h04,8'h05:   return WCAP_DAC;
                8'h08,8'h09,8'h0A:          return WCAP_ADC;
                8'h06:                       return WCAP_SPDIF;
                8'h0B,8'h0C:                return WCAP_MIXER;
                8'h22,8'h23,8'h24:          return WCAP_SEL;
                8'h14,8'h15,8'h16,8'h17,8'h1E,
                8'h18,8'h19,8'h1A,8'h1B:   return WCAP_PIN;
                8'h1C:                       return WCAP_BEEP;
                default:                     return 32'h0;
            endcase
        end else begin // CHIP_ALC256
            case (n)
                8'h02,8'h03:                return WCAP_DAC;
                8'h06:                       return WCAP_SPDIF;
                8'h07:                       return WCAP_DMIC;
                8'h08,8'h09:                return WCAP_ADC;
                8'h22,8'h23:                return WCAP_MIXER;
                8'h24:                       return WCAP_SEL;
                8'h12,8'h13,8'h14,8'h18,8'h19,8'h1A,8'h1B,8'h1D,8'h1E,8'h21:
                                             return WCAP_PIN;
                8'h1C:                       return WCAP_BEEP;
                8'h20:                       return WCAP_VENDOR;
                default:                     return 32'h0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Pin capabilities ROM
    //--------------------------------------------------------------------------
    function automatic logic [31:0] get_pin_cap(logic [7:0] n);
        if (CHIP_ID == CHIP_ALC269) begin
            case (n)
                8'h0D:                     return PIN_CAP_HP;
                8'h18,8'h19:              return PIN_CAP_MIC;
                8'h1A,8'h1B,8'h0E,8'h0F: return PIN_CAP_LINE;
                8'h0C,8'h10:              return PIN_CAP_SPDIF;
                8'h12,8'h13,8'h16:        return PIN_CAP_OUT;
                default:                   return 32'h0;
            endcase
        end else if (CHIP_ID == CHIP_ALC662) begin
            case (n)
                8'h14:                     return PIN_CAP_HP;
                8'h18,8'h19:              return PIN_CAP_MIC;
                8'h1A,8'h15:              return PIN_CAP_LINE;
                8'h06:                     return PIN_CAP_SPDIF;
                8'h16,8'h17:              return PIN_CAP_OUT;
                default:                   return 32'h0;
            endcase
        end else if (CHIP_ID == CHIP_ALC892) begin
            case (n)
                8'h14:                     return PIN_CAP_HP;
                8'h18,8'h19:              return PIN_CAP_MIC;
                8'h1A,8'h1B,8'h15:        return PIN_CAP_LINE;
                8'h06:                     return PIN_CAP_SPDIF;
                8'h16,8'h17,8'h1E:        return PIN_CAP_OUT;
                default:                   return 32'h0;
            endcase
        end else begin // CHIP_ALC256
            case (n)
                8'h21:                     return PIN_CAP_HP;
                8'h19:                     return PIN_CAP_MIC;
                8'h18,8'h1A,8'h1B:        return PIN_CAP_LINE;
                8'h1D:                     return PIN_CAP_MIC;
                8'h1E:                     return PIN_CAP_SPDIF;
                8'h14:                     return PIN_CAP_OUT;
                default:                   return 32'h0;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Full parameter ROM
    //--------------------------------------------------------------------------
    function automatic logic [31:0] get_param(logic [7:0] n, logic [7:0] p);
        case (p)
            PARAM_VENDOR_ID:           return cfg_vendor_id(CHIP_ID);
            PARAM_REVISION_ID:         return cfg_revision_id(CHIP_ID);
            PARAM_SUB_NODE_COUNT:      return (n == 8'h00) ? cfg_root_subnode_count(CHIP_ID) :
                                              (n == 8'h01) ? cfg_afg_subnode_count(CHIP_ID) : 32'h0;
            PARAM_FUNCTION_GROUP_TYPE: return (n == 8'h01) ? cfg_afg_func_group_type(CHIP_ID) : 32'h0;
            PARAM_AUDIO_FUNC_CAP:      return (n == 8'h01) ? cfg_audio_func_cap(CHIP_ID) : 32'h0;
            PARAM_WIDGET_CAP:          return get_widget_cap(n);
            PARAM_PCM_SIZE_RATE:       return cfg_pcm_size_rate(CHIP_ID);
            PARAM_STREAM_FORMATS:      return STREAM_FORMATS;
            PARAM_PIN_CAP:             return get_pin_cap(n);
            PARAM_INPUT_AMP_CAP,
            PARAM_OUTPUT_AMP_CAP:      return cfg_amp_cap(CHIP_ID);
            PARAM_CONN_LIST_LEN:       return {24'h0, conn_list_len(n)};
            PARAM_SUPPORTED_PWR:       return SUPP_PWR_STATES;
            PARAM_PROCESSING_CAP:      return 32'h0;
            PARAM_GPIO_CAP:            return (n == 8'h01) ? cfg_gpio_cap(CHIP_ID) : 32'h0;
            PARAM_VOLUME_KNOB_CAP:     return (n == 8'h01) ? cfg_vol_knob_cap(CHIP_ID) : 32'h0;
            default:                   return 32'h0;
        endcase
    endfunction

    //--------------------------------------------------------------------------
    // Output
    //--------------------------------------------------------------------------
    assign state_out = state;
    assign ack = 1'b1;

    //--------------------------------------------------------------------------
    // Read
    //--------------------------------------------------------------------------
    logic [63:0] conn_list_val;  // avoid part-select on function call (XSim crash)
    logic [7:0]  nid_bounded;
    assign nid_bounded   = (nid < WS_SIZE) ? nid : 8'h0;
    assign conn_list_val = conn_list(nid);

    always_comb begin
        rdata = 32'h0;
        if (read) begin
            case (verb_id)
                VERB_GET_PARAM:          rdata = get_param(nid, payload[7:0]);
                VERB_GET_CONN_SELECT:    rdata = {24'h0, state[nid_bounded].conn_select};
                VERB_GET_CONN_LIST:      rdata = {24'h0, conn_list_val[payload[2:0]*8 +: 8]};
                VERB_GET_PROC_STATE:     rdata = {24'h0, state[nid_bounded].proc_state};
                VERB_GET_COEF_INDEX:     rdata = {16'h0, state[nid_bounded].coef_index};
                VERB_GET_PROC_COEF:      rdata = state[nid_bounded].proc_coef;
                VERB_GET_AMP_GAIN:       rdata = {24'h0, state[nid_bounded].amp_gain_mute};
                VERB_GET_CONV_FMT:       rdata = {16'h0, state[nid_bounded].conv_format};
                // Power State response: PS-Set[3:0], PS-Act[7:4], PS-Error[8],
                // PS-ClkStopOk[9], PS-SettingsReset[10].
                VERB_GET_PWR_STATE:      rdata = {21'h0, 1'b0, 1'b0, 1'b0,
                                                   state[nid_bounded].power_state,
                                                   state[nid_bounded].power_state};
                VERB_GET_CONV_STREAM:    rdata = {24'h0, state[nid_bounded].conv_stream};
                VERB_GET_PIN_WIDGET:     rdata = {24'h0, state[nid_bounded].pin_widget_ctrl};
                VERB_GET_UNSOL_CONTROL:  rdata = {24'h0, state[nid_bounded].unsolicited_ctrl};
                VERB_GET_PIN_SENSE:      rdata = 32'h0;
                VERB_GET_BEEP:           rdata = {24'h0, state[nid_bounded].beep_gen};
                VERB_GET_EAPD:           rdata = {24'h0, state[nid_bounded].eapd};
                VERB_GET_DIGI_CONV1:     rdata = {24'h0, state[nid_bounded].digi_conv1};
                VERB_GET_DIGI_CONV2:     rdata = {24'h0, state[nid_bounded].digi_conv2};
                VERB_GET_VOL_KNOB:       rdata = {24'h0, state[nid_bounded].vol_knob};
                VERB_GET_GPIO_DATA:      rdata = {24'h0, state[8'h01].gpio_data};
                VERB_GET_GPIO_ENABLE:    rdata = {24'h0, state[8'h01].gpio_enable};
                VERB_GET_GPIO_DIRECTION: rdata = {24'h0, state[8'h01].gpio_direction};
                VERB_GET_GPIO_WAKE:      rdata = {24'h0, state[8'h01].gpio_wake};
                VERB_GET_GPIO_UNSOL:     rdata = {24'h0, state[8'h01].gpio_unsol_mask};
                VERB_GET_SUBSYSTEM_ID:   rdata = state[nid_bounded].subsystem_id;
                VERB_GET_CONFIG_DEFAULT: rdata = state[nid_bounded].config_default;
                default:                 rdata = 32'h0;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Write + Reset
    //--------------------------------------------------------------------------
    localparam logic [7:0] NID_BEEP = nid_beep(CHIP_ID);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < WS_SIZE; i++) state[i] <= '0;


            // Per-chip reset defaults — DAC formats
            for (int d = 0; d < cfg_num_dac(CHIP_ID); d++)
                state[nid_dac(CHIP_ID, d)].conv_format <= 16'h0011;
            // ADC formats
            for (int a = 0; a < cfg_num_adc(CHIP_ID); a++)
                state[nid_adc(CHIP_ID, a)].conv_format <= 16'h0011;

            // Power D0 defaults
            state[8'h01].power_state <= PWR_D0;   // AFG
            for (int d = 0; d < cfg_num_dac(CHIP_ID); d++)
                state[nid_dac(CHIP_ID, d)].power_state <= PWR_D0;
            for (int a = 0; a < cfg_num_adc(CHIP_ID); a++)
                state[nid_adc(CHIP_ID, a)].power_state <= PWR_D0;
            for (int s = 0; s < cfg_num_spdif(CHIP_ID); s++)
                state[nid_spdif(CHIP_ID, s)].power_state <= PWR_D0;

            // Pin power defaults
            for (int p = 0; p < 6; p++) begin
                if (nid_out_pin(CHIP_ID, p) != 8'h00)
                    state[nid_out_pin(CHIP_ID, p)].power_state <= PWR_D0;
            end
            for (int p = 0; p < 4; p++) begin
                if (nid_in_pin(CHIP_ID, p) != 8'h00)
                    state[nid_in_pin(CHIP_ID, p)].power_state <= PWR_D0;
            end

            state[NID_BEEP].beep_gen <= 8'h00;
            state[8'h01].subsystem_id <= cfg_vendor_id(CHIP_ID);

        end else if (valid && !read) begin
            case (verb_id)
                VERB_SET_CONN_SELECT:    state[nid_bounded].conn_select      <= payload[7:0];
                VERB_SET_PROC_STATE:     state[nid_bounded].proc_state       <= payload[7:0];
                VERB_SET_COEF_INDEX:     state[nid_bounded].coef_index       <= payload[15:0];
                VERB_SET_PROC_COEF:      state[nid_bounded].proc_coef        <= {16'h0, payload};
                // Amplifier Gain/Mute Set payload: [15]=OutAmp, [14]=InAmp,
                // [13]=Left, [12]=Right, [11:8]=Index, [7]=Mute, [6:0]=Gain.
                // If any of the Set bits are asserted, update stored {Mute, Gain}.
                VERB_SET_AMP_GAIN:       if (|payload[15:12])
                                             state[nid_bounded].amp_gain_mute <= payload[7:0];
                VERB_SET_CONV_FMT:       state[nid_bounded].conv_format      <= payload;
                VERB_SET_PWR_STATE:      state[nid_bounded].power_state      <= payload[3:0];
                VERB_SET_CONV_STREAM:    state[nid_bounded].conv_stream      <= payload[7:0];
                VERB_SET_PIN_WIDGET:     state[nid_bounded].pin_widget_ctrl  <= payload[7:0];
                VERB_SET_UNSOL_CONTROL:  state[nid_bounded].unsolicited_ctrl <= payload[7:0];
                VERB_SET_BEEP:           state[NID_BEEP].beep_gen            <= payload[7:0];
                VERB_SET_EAPD:           state[nid_bounded].eapd             <= payload[7:0];
                VERB_SET_DIGI_CONV1:     state[nid_bounded].digi_conv1       <= payload[7:0];
                VERB_SET_DIGI_CONV2:     state[nid_bounded].digi_conv2       <= payload[7:0];
                VERB_SET_VOL_KNOB:       state[8'h01].vol_knob               <= payload[7:0];
                VERB_SET_GPIO_DATA:      state[8'h01].gpio_data              <= payload[7:0];
                VERB_SET_GPIO_ENABLE:    state[8'h01].gpio_enable            <= payload[7:0];
                VERB_SET_GPIO_DIRECTION: state[8'h01].gpio_direction         <= payload[7:0];
                VERB_SET_GPIO_WAKE:      state[8'h01].gpio_wake              <= payload[7:0];
                VERB_SET_GPIO_UNSOL:     state[8'h01].gpio_unsol_mask        <= payload[7:0];
                VERB_SET_SUBSYSTEM_ID0:  state[nid_bounded].subsystem_id[7:0]    <= payload[7:0];
                VERB_SET_SUBSYSTEM_ID1:  state[nid_bounded].subsystem_id[15:8]   <= payload[7:0];
                VERB_SET_SUBSYSTEM_ID2:  state[nid_bounded].subsystem_id[23:16]  <= payload[7:0];
                VERB_SET_SUBSYSTEM_ID3:  state[nid_bounded].subsystem_id[31:24]  <= payload[7:0];
                VERB_SET_CONFIG_DEFAULT0: state[nid_bounded].config_default[7:0]   <= payload[7:0];
                VERB_SET_CONFIG_DEFAULT1: state[nid_bounded].config_default[15:8]  <= payload[7:0];
                VERB_SET_CONFIG_DEFAULT2: state[nid_bounded].config_default[23:16] <= payload[7:0];
                VERB_SET_CONFIG_DEFAULT3: state[nid_bounded].config_default[31:24] <= payload[7:0];
                VERB_FUNCTION_RESET: begin
                    state[nid_bounded].conn_select      <= '0;
                    state[nid_bounded].amp_gain_mute    <= '0;
                    state[nid_bounded].conv_stream      <= '0;
                    state[nid_bounded].pin_widget_ctrl  <= '0;
                    state[nid_bounded].unsolicited_ctrl <= '0;
                    state[nid_bounded].eapd             <= '0;
                end
                default: ;
            endcase
        end
    end

endmodule
