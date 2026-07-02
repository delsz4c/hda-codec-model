`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Package
//------------------------------------------------------------------------------
// Configurable HDA codec model supporting multiple Realtek chip variants.
// All HDA-spec constants are universal; chip-specific parameters are
// dispatched via CHIP_ID functions resolved at elaboration time.
//
// Supported chips:
//   CHIP_ALC269  — Laptop/mobile, 2 DAC + 2 ADC, 2ch stereo
//   CHIP_ALC662  — Desktop 5.1,   3 DAC + 2 ADC, 6ch surround
//   CHIP_ALC892  — Desktop 7.1,   4 DAC + 3 ADC, 8ch surround
//   CHIP_ALC256  — Ultrabook/tablet, 2 DAC + 2 ADC, 1 SPDIF, 3 GPIO
//------------------------------------------------------------------------------
`ifndef HDA_CODEC_PKG_SV
`define HDA_CODEC_PKG_SV

package hda_codec_pkg;

    //==========================================================================
    // Chip Model Identifiers
    //==========================================================================
    localparam int CHIP_ALC269 = 0;
    localparam int CHIP_ALC662 = 1;
    localparam int CHIP_ALC892 = 2;
    localparam int CHIP_ALC256 = 3;

    //==========================================================================
    // Maximum Configuration Dimensions
    //==========================================================================
    localparam int MAX_DAC    = 4;
    localparam int MAX_ADC    = 3;
    localparam int MAX_SPDIF  = 2;
    localparam int MAX_GPIO   = 4;
    localparam int MAX_BLOCKS = 4;    // Max sample blocks/frame (192kHz = 4 @ 48k base)
    localparam int WS_SIZE    = 64;   // Widget-state array slots (NID 0..63)

    //==========================================================================
    // HDA Link Protocol Constants (Intel HDA Spec — universal)
    //==========================================================================
    localparam int HDA_CMD_BITS   = 40;
    localparam int HDA_RESP_BITS  = 36;
    localparam int HDA_CODEC_ADDR = 4'h0;
    localparam int PCM_BITS       = 24;

    //==========================================================================
    // Verb IDs (Intel HDA Spec 7.3 — universal)
    //==========================================================================
    typedef enum logic [11:0] {
        VERB_GET_PARAM           = 12'hF00,
        VERB_GET_CONN_SELECT     = 12'hF01,
        VERB_SET_CONN_SELECT     = 12'h701,
        VERB_GET_CONN_LIST       = 12'hF02,
        VERB_GET_PROC_STATE      = 12'hF03,
        VERB_SET_PROC_STATE      = 12'h703,
        VERB_GET_COEF_INDEX      = 12'h00D,
        VERB_SET_COEF_INDEX      = 12'h005,
        VERB_GET_PROC_COEF       = 12'h00C,
        VERB_SET_PROC_COEF       = 12'h004,
        VERB_GET_AMP_GAIN        = 12'h00B,
        VERB_SET_AMP_GAIN        = 12'h003,
        VERB_GET_CONV_FMT        = 12'h00A,
        VERB_SET_CONV_FMT        = 12'h002,
        VERB_GET_PWR_STATE       = 12'hF05,
        VERB_SET_PWR_STATE       = 12'h705,
        VERB_GET_CONV_STREAM     = 12'hF06,
        VERB_SET_CONV_STREAM     = 12'h706,
        VERB_GET_PIN_WIDGET      = 12'hF07,
        VERB_SET_PIN_WIDGET      = 12'h707,
        VERB_GET_UNSOL_CONTROL   = 12'hF08,
        VERB_SET_UNSOL_CONTROL   = 12'h708,
        VERB_GET_PIN_SENSE       = 12'hF09,
        VERB_EXECUTE_PIN_SENSE   = 12'h709,
        VERB_GET_BEEP            = 12'hF0A,
        VERB_SET_BEEP            = 12'h70A,
        VERB_GET_EAPD            = 12'hF0C,
        VERB_SET_EAPD            = 12'h70C,
        VERB_GET_DIGI_CONV1      = 12'hF0D,
        VERB_SET_DIGI_CONV1      = 12'h70D,
        VERB_GET_DIGI_CONV2      = 12'hF0E,
        VERB_SET_DIGI_CONV2      = 12'h70E,
        VERB_GET_VOL_KNOB        = 12'hF0F,
        VERB_SET_VOL_KNOB        = 12'h70F,
        VERB_GET_GPIO_DATA       = 12'hF15,
        VERB_SET_GPIO_DATA       = 12'h715,
        VERB_GET_GPIO_ENABLE     = 12'hF16,
        VERB_SET_GPIO_ENABLE     = 12'h716,
        VERB_GET_GPIO_DIRECTION  = 12'hF17,
        VERB_SET_GPIO_DIRECTION  = 12'h717,
        VERB_GET_GPIO_WAKE       = 12'hF18,
        VERB_SET_GPIO_WAKE       = 12'h718,
        VERB_GET_GPIO_UNSOL      = 12'hF19,
        VERB_SET_GPIO_UNSOL      = 12'h719,
        VERB_GET_SUBSYSTEM_ID    = 12'hF20,
        VERB_SET_SUBSYSTEM_ID0   = 12'h720,
        VERB_SET_SUBSYSTEM_ID1   = 12'h721,
        VERB_SET_SUBSYSTEM_ID2   = 12'h722,
        VERB_SET_SUBSYSTEM_ID3   = 12'h723,
        VERB_GET_CONFIG_DEFAULT  = 12'hF1C,
        VERB_SET_CONFIG_DEFAULT0 = 12'h71C,
        VERB_SET_CONFIG_DEFAULT1 = 12'h71D,
        VERB_SET_CONFIG_DEFAULT2 = 12'h71E,
        VERB_SET_CONFIG_DEFAULT3 = 12'h71F,
        VERB_FUNCTION_RESET      = 12'h7FF
    } verb_e;

    //==========================================================================
    // Parameter IDs (Intel HDA Spec 7.3.4 — universal)
    //==========================================================================
    typedef enum logic [7:0] {
        PARAM_VENDOR_ID           = 8'h00,
        PARAM_REVISION_ID         = 8'h02,
        PARAM_SUB_NODE_COUNT      = 8'h04,
        PARAM_FUNCTION_GROUP_TYPE = 8'h05,
        PARAM_AUDIO_FUNC_CAP      = 8'h08,
        PARAM_WIDGET_CAP          = 8'h09,
        PARAM_PCM_SIZE_RATE       = 8'h0A,
        PARAM_STREAM_FORMATS      = 8'h0B,
        PARAM_PIN_CAP             = 8'h0C,
        PARAM_INPUT_AMP_CAP       = 8'h0D,
        PARAM_CONN_LIST_LEN       = 8'h0E,
        PARAM_SUPPORTED_PWR       = 8'h0F,
        PARAM_PROCESSING_CAP      = 8'h10,
        PARAM_GPIO_CAP            = 8'h11,
        PARAM_OUTPUT_AMP_CAP      = 8'h12,
        PARAM_VOLUME_KNOB_CAP     = 8'h13
    } param_e;

    //==========================================================================
    // Widget Types (bits [23:20] of Widget Cap)
    //==========================================================================
    localparam logic [3:0] WTYPE_AUDIO_OUTPUT = 4'h0;
    localparam logic [3:0] WTYPE_AUDIO_INPUT  = 4'h1;
    localparam logic [3:0] WTYPE_MIXER        = 4'h2;
    localparam logic [3:0] WTYPE_SELECTOR     = 4'h3;
    localparam logic [3:0] WTYPE_PIN_COMPLEX  = 4'h4;
    localparam logic [3:0] WTYPE_BEEP_GEN     = 4'h7;
    localparam logic [3:0] WTYPE_VENDOR       = 4'hF;

    //==========================================================================
    // Widget Capability Builder
    //==========================================================================
    function automatic logic [31:0] wcap(
        logic [3:0] typ, logic [3:0] delay,
        logic pwr, logic digital, logic connlist, logic unsol,
        logic proc, logic fmt_ovr, logic amp_ovr,
        logic out_amp, logic in_amp, logic stereo
    );
        return {8'h00, typ, delay, 5'b0, pwr, digital, connlist, unsol, proc,
                1'b0, fmt_ovr, amp_ovr, out_amp, in_amp, stereo};
    endfunction

    // Standard widget capabilities (shared across chips)
    localparam logic [31:0] WCAP_DAC    = wcap(WTYPE_AUDIO_OUTPUT,4'd1,1,0,0,0,0,0,0,1,1,1);
    localparam logic [31:0] WCAP_ADC    = wcap(WTYPE_AUDIO_INPUT, 4'd1,1,0,0,0,0,0,0,1,1,1);
    localparam logic [31:0] WCAP_SPDIF  = wcap(WTYPE_AUDIO_OUTPUT,4'd0,1,1,0,0,0,0,0,1,1,1);
    localparam logic [31:0] WCAP_MIXER  = wcap(WTYPE_MIXER,       4'd0,0,0,1,0,0,0,0,0,0,1);
    localparam logic [31:0] WCAP_SEL    = wcap(WTYPE_SELECTOR,    4'd0,0,0,1,0,0,0,0,0,0,1);
    localparam logic [31:0] WCAP_PIN    = wcap(WTYPE_PIN_COMPLEX, 4'd0,1,0,1,1,0,0,0,1,1,1);
    localparam logic [31:0] WCAP_VENDOR = wcap(WTYPE_VENDOR,      4'd0,0,0,0,0,0,0,0,0,0,1);
    localparam logic [31:0] WCAP_DMIC   = wcap(WTYPE_AUDIO_INPUT, 4'd0,1,0,0,0,0,0,0,1,1,1);
    localparam logic [31:0] WCAP_BEEP   = wcap(WTYPE_BEEP_GEN,    4'd0,1,0,0,0,0,0,1,1,1,1);

    // Pin capabilities
    // VRef field always includes Hi-Z (bit0) when Output Capable is set (HDA spec requirement).
    localparam logic [31:0] PIN_CAP_HP    = 32'h0001_8D3F;  // HP drive + Hi-Z
    localparam logic [31:0] PIN_CAP_LINE  = 32'h0001_8D39;  // Hi-Z
    localparam logic [31:0] PIN_CAP_MIC   = 32'h0001_8D37;  // Hi-Z, keep Output for retask
    localparam logic [31:0] PIN_CAP_SPDIF = 32'h0001_0010;
    localparam logic [31:0] PIN_CAP_OUT   = 32'h0001_0010;

    // Stream formats (PCM only)
    localparam logic [31:0] STREAM_FORMATS = 32'h0000_0001;

    // Supported power states (D0–D3)
    localparam logic [31:0] SUPP_PWR_STATES = 32'h0000_000F;

    //==========================================================================
    // Widget State Structure
    //==========================================================================
    typedef struct packed {
        logic [7:0]  conn_select;
        logic [7:0]  amp_gain_mute;   // {Mute[7], Gain[6:0]}
        logic [15:0] conv_format;
        logic [7:0]  conv_stream;
        logic [3:0]  power_state;
        logic [7:0]  pin_widget_ctrl;
        logic [31:0] config_default;
        logic [7:0]  unsolicited_ctrl;
        logic [7:0]  beep_gen;
        logic [7:0]  eapd;
        logic [7:0]  digi_conv1;
        logic [7:0]  digi_conv2;
        logic [7:0]  vol_knob;
        logic [31:0] subsystem_id;
        logic [15:0] coef_index;
        logic [31:0] proc_coef;
        logic [7:0]  proc_state;
        logic [7:0]  gpio_data;
        logic [7:0]  gpio_enable;
        logic [7:0]  gpio_direction;
        logic [7:0]  gpio_wake;
        logic [7:0]  gpio_unsol_mask;
    } widget_state_t;

    //==========================================================================
    // Power State Encodings
    //==========================================================================
    typedef enum logic [3:0] {
        PWR_D0 = 4'h0,
        PWR_D1 = 4'h1,
        PWR_D2 = 4'h2,
        PWR_D3 = 4'h3
    } pwr_state_e;

    //==========================================================================
    //  Per-Chip Configuration Functions
    //  (All resolved at elaboration time when CHIP_ID is a localparam)
    //==========================================================================

    // ---- Scalar configuration ----

    function automatic logic [31:0] cfg_vendor_id(int c);
        case (c)
            CHIP_ALC269: return 32'h10EC_0269;
            CHIP_ALC662: return 32'h10EC_0662;
            CHIP_ALC892: return 32'h10EC_0892;
            CHIP_ALC256: return 32'h10EC_0256;
            default:     return 32'h10EC_0269;
        endcase
    endfunction

    function automatic logic [31:0] cfg_revision_id(int c);
        case (c)
            CHIP_ALC269: return 32'h0010_0001;
            CHIP_ALC662: return 32'h0010_0002;
            CHIP_ALC892: return 32'h0010_0003;
            CHIP_ALC256: return 32'h0010_0001;
            default:     return 32'h0010_0001;
        endcase
    endfunction

    function automatic int cfg_num_dac(int c);
        case (c) CHIP_ALC269: return 2; CHIP_ALC662: return 3; CHIP_ALC892: return 4; CHIP_ALC256: return 2; default: return 2; endcase
    endfunction

    function automatic int cfg_num_adc(int c);
        case (c) CHIP_ALC269: return 2; CHIP_ALC662: return 2; CHIP_ALC892: return 3; CHIP_ALC256: return 2; default: return 2; endcase
    endfunction

    function automatic int cfg_num_spdif(int c);
        case (c) CHIP_ALC269: return 2; CHIP_ALC662: return 1; CHIP_ALC892: return 1; CHIP_ALC256: return 1; default: return 2; endcase
    endfunction

    function automatic int cfg_num_gpio(int c);
        case (c) CHIP_ALC269: return 2; CHIP_ALC662: return 2; CHIP_ALC892: return 4; CHIP_ALC256: return 3; default: return 2; endcase
    endfunction

    // NID_MAX: highest addressable NID
    function automatic logic [7:0] cfg_nid_max(int c);
        case (c) CHIP_ALC269: return 8'h24; CHIP_ALC662: return 8'h22; CHIP_ALC892: return 8'h24; CHIP_ALC256: return 8'h24; default: return 8'h24; endcase
    endfunction

    // AFG subnode count: {start_nid[15:0], total[15:0]}
    function automatic logic [31:0] cfg_afg_subnode_count(int c);
        // Total must cover every widget NID (software enumerates start .. start+total-1).
        // start=2; highest NID for ALC269/892/256 = 0x24 -> total=35 (0x23).
        // highest NID for ALC662 = 0x22 -> total=33 (0x21).
        case (c)
            CHIP_ALC269: return 32'h0002_0023;  // start=2, total=35
            CHIP_ALC662: return 32'h0002_0021;  // start=2, total=33
            CHIP_ALC892: return 32'h0002_0023;  // start=2, total=35
            CHIP_ALC256: return 32'h0002_0023;  // start=2, total=35
            default:     return 32'h0002_0023;
        endcase
    endfunction

    function automatic logic [31:0] cfg_audio_func_cap(int c);
        case (c)
            CHIP_ALC269: return 32'h0001_0111;
            CHIP_ALC662: return 32'h0001_0111;
            CHIP_ALC892: return 32'h0001_0111;
            CHIP_ALC256: return 32'h0001_0111;
            default:     return 32'h0001_0111;
        endcase
    endfunction

    // PCM size/rates
    function automatic logic [31:0] cfg_pcm_size_rate(int c);
        case (c)
            // PCM Size/Rate caps (§7.3.4.7): bits[20:16]=bit-depths, bits[11:0]=rates.
            // 0x000E_0560 = 16/20/24-bit (b17/b18/b19) + 44.1/48/96/192kHz
            // (b5/b6/b8/b10) — the standard Realtek ALC HD-audio set.
            CHIP_ALC269: return 32'h000E_0560;
            CHIP_ALC662: return 32'h000E_0560;
            CHIP_ALC892: return 32'h000E_0560;
            CHIP_ALC256: return 32'h000E_0560;
            default:     return 32'h000E_0560;
        endcase
    endfunction

    //==========================================================================
    // Stream Format Decode (§3.7.1 / verb 0x2) — runtime, chip-independent
    //==========================================================================
    // conv_format[14]    : base rate (0 = 48 kHz, 1 = 44.1 kHz)
    // conv_format[13:11] : base-rate multiple (000=x1 .. 111=x8)
    // conv_format[10:8]  : base-rate divisor  (000=/1 .. 111=/8)
    // conv_format[6:4]   : bits/sample (000=8,001=16,010=20,011=24,100=32)
    // conv_format[3:0]   : channels-1 (0000=1ch .. 1111=16ch)

    // Sample blocks transferred per 48 kHz HDA frame (§3.3.34 Block Multiple):
    //   48kHz -> 1, 96kHz -> 2, 192kHz -> 4.  Clamped to [1, MAX_BLOCKS].
    // 44.1k-base fractional rates are approximated to the same integer multiple.
    function automatic int fmt_rate_mult(logic [15:0] fmt);
        automatic int mult   = int'(fmt[13:11]) + 1;   // x1..x8
        automatic int divv   = int'(fmt[10:8])  + 1;   // /1../8
        automatic int blocks = mult / divv;
        if (blocks < 1)          blocks = 1;
        if (blocks > MAX_BLOCKS) blocks = MAX_BLOCKS;
        return blocks;
    endfunction

    // Effective bits per sample (conv_format[6:4]).
    function automatic int fmt_bits(logic [15:0] fmt);
        case (fmt[6:4])
            3'b000:  return 8;
            3'b001:  return 16;
            3'b010:  return 20;
            3'b011:  return 24;
            3'b100:  return 32;
            default: return 24;
        endcase
    endfunction

    // Channel count (conv_format[3:0] = channels-1), 1..16.
    function automatic int fmt_channels(logic [15:0] fmt);
        return int'(fmt[3:0]) + 1;
    endfunction

    // Amplifier capabilities
    function automatic logic [31:0] cfg_amp_cap(int c);
        case (c)
            CHIP_ALC269: return 32'h8004_3F00;
            CHIP_ALC662: return 32'h8004_3F00;
            CHIP_ALC892: return 32'h8004_3F00;
            CHIP_ALC256: return 32'h8004_3F00;
            default:     return 32'h8004_3F00;
        endcase
    endfunction

    // GPIO capabilities
    // [31]=GPIWake, [30]=GPIUnsol, [23:16]=NumGPIs, [15:8]=NumGPOs, [7:0]=NumGPIOs
    function automatic logic [31:0] cfg_gpio_cap(int c);
        case (c)
            // ALC269: no wake, unsolicited, 2 GPIOs
            CHIP_ALC269: return 32'h4000_0002;
            // ALC662: no wake, unsolicited, 2 GPIOs
            CHIP_ALC662: return 32'h4000_0002;
            // ALC892: no wake, unsolicited, 4 GPIOs
            CHIP_ALC892: return 32'h4000_0004;
            // ALC256: no wake, unsolicited, 0 GPI/GPO, 3 GPIOs
            CHIP_ALC256: return 32'h4000_0003;
            default:     return 32'h4000_0002;
        endcase
    endfunction

    function automatic logic [31:0] cfg_vol_knob_cap(int c);
        return 32'h0000_7F01;
    endfunction

    // AFG function group type
    function automatic logic [31:0] cfg_afg_func_group_type(int c);
        return 32'h0000_0100;  // Unsol=1, NodeType=Audio (0x00)
    endfunction

    // Root subnode count (always 1 AFG)
    function automatic logic [31:0] cfg_root_subnode_count(int c);
        return 32'h0001_0001;
    endfunction

    // ---- NID Helpers (for DAC/ADC/SPDIF/BEEP) ----

    // DACs: consecutive starting from NID 0x02
    function automatic logic [7:0] nid_dac(int c, int i);
        return 8'h02 + i[7:0];
    endfunction

    // ADCs
    function automatic logic [7:0] nid_adc(int c, int i);
        case (c)
            CHIP_ALC269: return 8'h07 + i[7:0];  // 0x07, 0x08
            default:     return 8'h08 + i[7:0];  // 0x08, 0x09, [0x0A]
        endcase
    endfunction

    // SPDIF converter NID
    function automatic logic [7:0] nid_spdif(int c, int i);
        case (c)
            CHIP_ALC269: return (i == 0) ? 8'h0C : 8'h10;
            default:     return 8'h06;  // single SPDIF converter at NID 0x06
        endcase
    endfunction

    // SPDIF output pin NID (may differ from converter, e.g. ALC256)
    function automatic logic [7:0] nid_spdif_pin(int c, int i);
        case (c)
            CHIP_ALC269: return (i == 0) ? 8'h0C : 8'h10;
            CHIP_ALC256: return 8'h1E;
            default:     return 8'h06;  // pin same as converter
        endcase
    endfunction

    // BEEP generator NID
    function automatic logic [7:0] nid_beep(int c);
        return 8'h1C;  // same for all chips
    endfunction

    // DMIC converter NID (ALC256 only)
    function automatic logic [7:0] nid_dmic_conv(int c);
        return (c == CHIP_ALC256) ? 8'h07 : 8'h00;
    endfunction

    // AFG NID (always 0x01)
    function automatic logic [7:0] nid_afg(int c);
        return 8'h01;
    endfunction

    //--------------------------------------------------------------------------
    // Output Pin NIDs per chip
    //   idx 0: HP,  1: FRONT/LOUT1,  2: SURR/SPK,  3: CLFE/LOUT2
    //   idx 4: SIDE, 5: MONO
    //--------------------------------------------------------------------------
    function automatic logic [7:0] nid_out_pin(int c, int i);
        case (c)
            CHIP_ALC269: case (i)
                0: return 8'h0D;  // HP
                1: return 8'h0E;  // LOUT1
                2: return 8'h12;  // SPK_OUTP
                3: return 8'h0F;  // LOUT2
                4: return 8'h13;  // SPK_OUTN
                5: return 8'h16;  // MONO
                default: return 8'h00;
            endcase
            CHIP_ALC662: case (i)
                0: return 8'h14;  // HP
                1: return 8'h15;  // FRONT
                2: return 8'h16;  // SURROUND
                3: return 8'h17;  // CLFE
                default: return 8'h00;
            endcase
            CHIP_ALC892: case (i)
                0: return 8'h14;  // HP
                1: return 8'h15;  // FRONT
                2: return 8'h16;  // SURROUND
                3: return 8'h17;  // CLFE
                4: return 8'h1E;  // SIDE
                default: return 8'h00;
            endcase
            CHIP_ALC256: case (i)
                0: return 8'h21;  // HP-OUT
                1: return 8'h14;  // SPK-OUT / FRONT
                2: return 8'h1B;  // LINE2 (re-tasking IO)
                3: return 8'h1E;  // SPDIF-OUT pin
                default: return 8'h00;
            endcase
            default: return 8'h00;
        endcase
    endfunction

    // Input Pin NIDs per chip
    function automatic logic [7:0] nid_in_pin(int c, int i);
        case (c)
            CHIP_ALC269: case (i)
                0: return 8'h19;  // MIC1
                1: return 8'h18;  // MIC2
                2: return 8'h1A;  // LINE1
                3: return 8'h1B;  // LINE2
                default: return 8'h00;
            endcase
            CHIP_ALC662: case (i)
                0: return 8'h18;  // MIC1
                1: return 8'h19;  // MIC2
                2: return 8'h1A;  // LINE1
                default: return 8'h00;
            endcase
            CHIP_ALC892: case (i)
                0: return 8'h18;  // MIC1
                1: return 8'h19;  // MIC2
                2: return 8'h1A;  // LINE1
                3: return 8'h1B;  // LINE2
                default: return 8'h00;
            endcase
            CHIP_ALC256: case (i)
                0: return 8'h19;  // MIC2
                1: return 8'h1A;  // LINE1
                2: return 8'h1B;  // LINE2 (re-tasking IO)
                3: return 8'h1D;  // PCBEEP
                default: return 8'h00;
            endcase
            default: return 8'h00;
        endcase
    endfunction

endpackage

`endif
