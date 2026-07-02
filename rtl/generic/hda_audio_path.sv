`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Audio Data Path
//------------------------------------------------------------------------------
// Parameterized by CHIP_ID.  Per-chip DAC→output-pin routing and ADC-mux
// selection are selected via generate-if so only the target chip's logic
// is synthesized.
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_audio_path #(
    parameter int CHIP_ID = 0
) (
    input  logic clk,
    input  logic rst_n,
    // DAC samples (up to MAX_DAC pairs)
    input  logic [hda_codec_pkg::MAX_DAC-1:0]  dac_valid,
    input  logic [23:0] dac_sample_l [0:hda_codec_pkg::MAX_DAC-1],
    input  logic [23:0] dac_sample_r [0:hda_codec_pkg::MAX_DAC-1],
    // ADC samples (up to MAX_ADC pairs)
    output logic [hda_codec_pkg::MAX_ADC-1:0]  adc_valid_out,
    output logic [23:0] adc_sample_l [0:hda_codec_pkg::MAX_ADC-1],
    output logic [23:0] adc_sample_r [0:hda_codec_pkg::MAX_ADC-1],
    // Widget state
    input  hda_codec_pkg::widget_state_t state [0:hda_codec_pkg::WS_SIZE-1],
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
    input  logic        loopback_en
);

    import hda_codec_pkg::*;

    //--------------------------------------------------------------------------
    // Volume attenuation (shared across all chips)
    //--------------------------------------------------------------------------
    // Frame strobe: one pulse every 500 BCLK cycles (48 kHz frame rate).
    localparam int FRAME_LEN = 500;
    logic [$clog2(FRAME_LEN)-1:0] adc_div;
    logic                         adc_frame_tick;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_div        <= '0;
            adc_frame_tick <= 1'b0;
        end else begin
            adc_frame_tick <= (adc_div == FRAME_LEN-1);
            if (adc_div == FRAME_LEN-1)
                adc_div <= '0;
            else
                adc_div <= adc_div + 1'b1;
        end
    end

    function automatic logic [23:0] apply_gain(logic [23:0] sample,
                                               logic [6:0] gain_idx,
                                               logic mute);
        logic [23:0] r;
        if (mute) return 24'h0;
        case (gain_idx[6:4])
            3'd0: r = sample;
            3'd1: r = sample >>> 1;
            3'd2: r = sample >>> 2;
            3'd3: r = sample >>> 3;
            3'd4: r = sample >>> 4;
            3'd5: r = sample >>> 5;
            3'd6: r = sample >>> 6;
            default: r = sample >>> 7;
        endcase
        return r;
    endfunction

    // Bit-depth alignment (§3.7.1 conv_format[6:4]): mask the 24-bit container's
    // low bits below the format's effective precision so the sample reflects the
    // negotiated sample size.  24/32-bit keep the full container.
    function automatic logic [23:0] fmt_align(logic [23:0] sample, logic [15:0] fmt);
        case (fmt[6:4])
            3'b000:  return {sample[23:16], 16'h0};  // 8-bit
            3'b001:  return {sample[23:8],  8'h0};   // 16-bit
            3'b010:  return {sample[23:4],  4'h0};   // 20-bit
            default: return sample;                   // 24/32-bit
        endcase
    endfunction

    //--------------------------------------------------------------------------
    // DAC gain registers
    //--------------------------------------------------------------------------
    logic [23:0] dac_l_g [0:MAX_DAC-1];
    logic [23:0] dac_r_g [0:MAX_DAC-1];

    genvar gd;
    generate
        for (gd = 0; gd < cfg_num_dac(CHIP_ID); gd++) begin : g_dac_gain
            localparam logic [7:0] DNID = nid_dac(CHIP_ID, gd);
            always_ff @(posedge clk or negedge rst_n) begin : dac_gain_proc
                logic [23:0] sl, sr;
                if (!rst_n) begin
                    dac_l_g[gd] <= '0;
                    dac_r_g[gd] <= '0;
                end else if (dac_valid[gd]) begin
                    // Bit-depth alignment per conv_format[6:4].
                    sl = fmt_align(dac_sample_l[gd], state[DNID].conv_format);
                    // Channel count (conv_format[3:0]): mono (1ch) duplicates L to R.
                    sr = (fmt_channels(state[DNID].conv_format) == 1)
                         ? sl
                         : fmt_align(dac_sample_r[gd], state[DNID].conv_format);
                    dac_l_g[gd] <= apply_gain(sl,
                                              state[DNID].amp_gain_mute[6:0],
                                              state[DNID].amp_gain_mute[7]);
                    dac_r_g[gd] <= apply_gain(sr,
                                              state[DNID].amp_gain_mute[6:0],
                                              state[DNID].amp_gain_mute[7]);
                end
            end
        end
        // Tie off unused DAC gain regs
        for (gd = cfg_num_dac(CHIP_ID); gd < MAX_DAC; gd++) begin : g_dac_tie
            assign dac_l_g[gd] = 24'h0;
            assign dac_r_g[gd] = 24'h0;
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Output routing helper
    //--------------------------------------------------------------------------
    function automatic logic pin_enabled(logic [7:0] nid_pin);
        // HDA spec: Pin Widget Control bit 6 = Out Enable.
        return state[nid_pin].pin_widget_ctrl[6]
               & (state[nid_pin].power_state == PWR_D0);
    endfunction

    //--------------------------------------------------------------------------
    // Per-chip output routing
    //--------------------------------------------------------------------------
    generate
        if (CHIP_ID == CHIP_ALC269) begin : g_out_269
            // DAC0→HP(0x0D), LOUT1(0x0E); DAC1→SPK(0x12/0x13), LOUT2(0x0F), MONO(0x16)
            always_comb begin
                hp_out_l    = pin_enabled(8'h0D) ? dac_l_g[0] : '0;
                hp_out_r    = pin_enabled(8'h0D) ? dac_r_g[0] : '0;
                front_out_l = pin_enabled(8'h0E) ? dac_l_g[0] : '0;
                front_out_r = pin_enabled(8'h0E) ? dac_r_g[0] : '0;
                surr_out_l  = pin_enabled(8'h12) ? dac_l_g[1] : '0;
                surr_out_r  = pin_enabled(8'h13) ? dac_r_g[1] : '0;
                clfe_out_l  = pin_enabled(8'h0F) ? dac_l_g[1] : '0;
                clfe_out_r  = pin_enabled(8'h0F) ? dac_r_g[1] : '0;
                side_out_l  = '0;
                side_out_r  = '0;
                mono_out    = pin_enabled(8'h16) ? ((dac_l_g[1] + dac_r_g[1]) >>> 1) : '0;
            end
        end else if (CHIP_ID == CHIP_ALC662) begin : g_out_662
            // DAC0→HP(0x14)/FRONT(0x15); DAC1→SURR(0x16); DAC2→CLFE(0x17)
            always_comb begin
                hp_out_l    = pin_enabled(8'h14) ? dac_l_g[0] : '0;
                hp_out_r    = pin_enabled(8'h14) ? dac_r_g[0] : '0;
                front_out_l = pin_enabled(8'h15) ? dac_l_g[0] : '0;
                front_out_r = pin_enabled(8'h15) ? dac_r_g[0] : '0;
                surr_out_l  = pin_enabled(8'h16) ? dac_l_g[1] : '0;
                surr_out_r  = pin_enabled(8'h16) ? dac_r_g[1] : '0;
                clfe_out_l  = pin_enabled(8'h17) ? dac_l_g[2] : '0;
                clfe_out_r  = pin_enabled(8'h17) ? dac_r_g[2] : '0;
                side_out_l  = '0;
                side_out_r  = '0;
                mono_out    = '0;
            end
        end else if (CHIP_ID == CHIP_ALC892) begin : g_out_892
            // DAC0→HP(0x14)/FRONT(0x15); DAC1→SURR(0x16); DAC2→CLFE(0x17); DAC3→SIDE(0x1E)
            always_comb begin
                hp_out_l    = pin_enabled(8'h14) ? dac_l_g[0] : '0;
                hp_out_r    = pin_enabled(8'h14) ? dac_r_g[0] : '0;
                front_out_l = pin_enabled(8'h15) ? dac_l_g[0] : '0;
                front_out_r = pin_enabled(8'h15) ? dac_r_g[0] : '0;
                surr_out_l  = pin_enabled(8'h16) ? dac_l_g[1] : '0;
                surr_out_r  = pin_enabled(8'h16) ? dac_r_g[1] : '0;
                clfe_out_l  = pin_enabled(8'h17) ? dac_l_g[2] : '0;
                clfe_out_r  = pin_enabled(8'h17) ? dac_r_g[2] : '0;
                side_out_l  = pin_enabled(8'h1E) ? dac_l_g[3] : '0;
                side_out_r  = pin_enabled(8'h1E) ? dac_r_g[3] : '0;
                mono_out    = '0;
            end
        end else begin : g_out_256
            // ALC256: DAC0→SPK(0x14); DAC0/1→HP(0x21)/LINE2(0x1B) via conn_select
            always_comb begin
                hp_out_l    = pin_enabled(8'h21) ?
                                 (state[8'h21].conn_select[0] ? dac_l_g[1] : dac_l_g[0]) : '0;
                hp_out_r    = pin_enabled(8'h21) ?
                                 (state[8'h21].conn_select[0] ? dac_r_g[1] : dac_r_g[0]) : '0;
                front_out_l = pin_enabled(8'h14) ? dac_l_g[0] : '0;
                front_out_r = pin_enabled(8'h14) ? dac_r_g[0] : '0;
                surr_out_l  = pin_enabled(8'h1B) ?
                                 (state[8'h1B].conn_select[0] ? dac_l_g[1] : dac_l_g[0]) : '0;
                surr_out_r  = pin_enabled(8'h1B) ?
                                 (state[8'h1B].conn_select[0] ? dac_r_g[1] : dac_r_g[0]) : '0;
                clfe_out_l  = '0;
                clfe_out_r  = '0;
                side_out_l  = '0;
                side_out_r  = '0;
                mono_out    = '0;
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // ADC mux and gain (per-chip)
    //--------------------------------------------------------------------------
    generate
        if (CHIP_ID == CHIP_ALC269) begin : g_adc_269
            // ADC0(0x07): 0=MIC1,1=LINE1,2=MIC2,3=LINE2,4=loopback DAC0
            // ADC1(0x08): 0=MIC2,1=LINE2,2=MIC1,3=LINE1,4=loopback DAC1
            logic [23:0] a0_ls, a0_rs, a1_ls, a1_rs;
            always_comb begin
                case (state[8'h07].conn_select[2:0])
                    3'd0: begin a0_ls = mic1_l;  a0_rs = mic1_r;  end
                    3'd1: begin a0_ls = line1_l; a0_rs = line1_r; end
                    3'd2: begin a0_ls = mic2_l;  a0_rs = mic2_r;  end
                    3'd3: begin a0_ls = line2_l; a0_rs = line2_r; end
                    default: begin
                        a0_ls = loopback_en ? dac_l_g[0] : mic1_l;
                        a0_rs = loopback_en ? dac_r_g[0] : mic1_r;
                    end
                endcase
                case (state[8'h08].conn_select[2:0])
                    3'd0: begin a1_ls = mic2_l;  a1_rs = mic2_r;  end
                    3'd1: begin a1_ls = line2_l; a1_rs = line2_r; end
                    3'd2: begin a1_ls = mic1_l;  a1_rs = mic1_r;  end
                    3'd3: begin a1_ls = line1_l; a1_rs = line1_r; end
                    default: begin
                        a1_ls = loopback_en ? dac_l_g[1] : mic2_l;
                        a1_rs = loopback_en ? dac_r_g[1] : mic2_r;
                    end
                endcase
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_valid_out <= '0;
                    for (int i = 0; i < MAX_ADC; i++) begin
                        adc_sample_l[i] <= '0; adc_sample_r[i] <= '0;
                    end
                end else begin
                    adc_valid_out <= '0;
                    if (adc_frame_tick) begin
                        adc_valid_out[0] <= 1'b1;
                        adc_sample_l[0] <= apply_gain(a0_ls, state[8'h07].amp_gain_mute[6:0],
                                                      state[8'h07].amp_gain_mute[7]);
                        adc_sample_r[0] <= apply_gain(a0_rs, state[8'h07].amp_gain_mute[6:0],
                                                      state[8'h07].amp_gain_mute[7]);
                    end
                    if (adc_frame_tick) begin
                        adc_valid_out[1] <= 1'b1;
                        adc_sample_l[1] <= apply_gain(a1_ls, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                        adc_sample_r[1] <= apply_gain(a1_rs, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                    end
                end
            end
        end else if (CHIP_ID == CHIP_ALC662) begin : g_adc_662
            // ADC0(0x08): 0=MIC1,1=MIC2,2=LINE1
            // ADC1(0x09): 0=MIC2,1=LINE1,2=MIC1
            logic [23:0] a0_ls, a0_rs, a1_ls, a1_rs;
            always_comb begin
                case (state[8'h08].conn_select[1:0])
                    2'd0: begin a0_ls = mic1_l;  a0_rs = mic1_r;  end
                    2'd1: begin a0_ls = mic2_l;  a0_rs = mic2_r;  end
                    default: begin a0_ls = line1_l; a0_rs = line1_r; end
                endcase
                case (state[8'h09].conn_select[1:0])
                    2'd0: begin a1_ls = mic2_l;  a1_rs = mic2_r;  end
                    2'd1: begin a1_ls = line1_l; a1_rs = line1_r; end
                    default: begin a1_ls = mic1_l; a1_rs = mic1_r; end
                endcase
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_valid_out <= '0;
                    for (int i = 0; i < MAX_ADC; i++) begin
                        adc_sample_l[i] <= '0; adc_sample_r[i] <= '0;
                    end
                end else begin
                    adc_valid_out <= '0;
                    if (adc_frame_tick) begin
                        adc_valid_out[0] <= 1'b1;
                        adc_sample_l[0] <= apply_gain(a0_ls, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                        adc_sample_r[0] <= apply_gain(a0_rs, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                    end
                    if (adc_frame_tick) begin
                        adc_valid_out[1] <= 1'b1;
                        adc_sample_l[1] <= apply_gain(a1_ls, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                        adc_sample_r[1] <= apply_gain(a1_rs, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                    end
                end
            end
        end else if (CHIP_ID == CHIP_ALC892) begin : g_adc_892
            // ADC0(0x08): 0=MIC1,1=MIC2,2=LINE1,3=LINE2
            // ADC1(0x09): 0=MIC2,1=LINE2,2=MIC1,3=LINE1
            // ADC2(0x0A): 0=MIC1,1=LINE1,2=MIC2,3=LINE2
            logic [23:0] a0_ls,a0_rs, a1_ls,a1_rs, a2_ls,a2_rs;
            always_comb begin
                case (state[8'h08].conn_select[1:0])
                    2'd0: begin a0_ls=mic1_l;  a0_rs=mic1_r;  end
                    2'd1: begin a0_ls=mic2_l;  a0_rs=mic2_r;  end
                    2'd2: begin a0_ls=line1_l; a0_rs=line1_r; end
                    default: begin a0_ls=line2_l; a0_rs=line2_r; end
                endcase
                case (state[8'h09].conn_select[1:0])
                    2'd0: begin a1_ls=mic2_l;  a1_rs=mic2_r;  end
                    2'd1: begin a1_ls=line2_l; a1_rs=line2_r; end
                    2'd2: begin a1_ls=mic1_l;  a1_rs=mic1_r;  end
                    default: begin a1_ls=line1_l; a1_rs=line1_r; end
                endcase
                case (state[8'h0A].conn_select[1:0])
                    2'd0: begin a2_ls=mic1_l;  a2_rs=mic1_r;  end
                    2'd1: begin a2_ls=line1_l; a2_rs=line1_r; end
                    2'd2: begin a2_ls=mic2_l;  a2_rs=mic2_r;  end
                    default: begin a2_ls=line2_l; a2_rs=line2_r; end
                endcase
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_valid_out <= '0;
                    for (int i = 0; i < MAX_ADC; i++) begin
                        adc_sample_l[i] <= '0; adc_sample_r[i] <= '0;
                    end
                end else begin
                    adc_valid_out <= '0;
                    if (adc_frame_tick) begin
                        adc_valid_out[0] <= 1'b1;
                        adc_sample_l[0] <= apply_gain(a0_ls, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                        adc_sample_r[0] <= apply_gain(a0_rs, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                    end
                    if (adc_frame_tick) begin
                        adc_valid_out[1] <= 1'b1;
                        adc_sample_l[1] <= apply_gain(a1_ls, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                        adc_sample_r[1] <= apply_gain(a1_rs, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                    end
                    if (adc_frame_tick) begin
                        adc_valid_out[2] <= 1'b1;
                        adc_sample_l[2] <= apply_gain(a2_ls, state[8'h0A].amp_gain_mute[6:0],
                                                      state[8'h0A].amp_gain_mute[7]);
                        adc_sample_r[2] <= apply_gain(a2_rs, state[8'h0A].amp_gain_mute[6:0],
                                                      state[8'h0A].amp_gain_mute[7]);
                    end
                end
            end
        end else begin : g_adc_256
            // ALC256:
            // ADC0(0x08)←SUM23: 0=RESERVED,1=MIC2,2=LINE1,3=LINE2,4=DMIC12,5=PCBEEP
            // ADC1(0x09)←SUM22: 0=RESERVED,1=MIC2,2=LINE1,3=LINE2,4=PCBEEP
            logic [23:0] a0_ls,a0_rs, a1_ls,a1_rs;
            always_comb begin
                case (state[8'h08].conn_select[2:0])
                    3'd0: begin a0_ls = mic2_l;  a0_rs = mic2_r;  end
                    3'd1: begin a0_ls = mic1_l;  a0_rs = mic1_r;  end
                    3'd2: begin a0_ls = line1_l; a0_rs = line1_r; end
                    3'd3: begin a0_ls = line2_l; a0_rs = line2_r; end
                    default: begin
                        a0_ls = loopback_en ? dac_l_g[0] : mic1_l;
                        a0_rs = loopback_en ? dac_r_g[0] : mic1_r;
                    end
                endcase
                case (state[8'h09].conn_select[2:0])
                    3'd0: begin a1_ls = mic2_l;  a1_rs = mic2_r;  end
                    3'd1: begin a1_ls = mic1_l;  a1_rs = mic1_r;  end
                    3'd2: begin a1_ls = line1_l; a1_rs = line1_r; end
                    3'd3: begin a1_ls = line2_l; a1_rs = line2_r; end
                    default: begin
                        a1_ls = loopback_en ? dac_l_g[1] : mic2_l;
                        a1_rs = loopback_en ? dac_r_g[1] : mic2_r;
                    end
                endcase
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    adc_valid_out <= '0;
                    for (int i = 0; i < MAX_ADC; i++) begin
                        adc_sample_l[i] <= '0; adc_sample_r[i] <= '0;
                    end
                end else begin
                    adc_valid_out <= '0;
                    if (adc_frame_tick) begin
                        adc_valid_out[0] <= 1'b1;
                        adc_sample_l[0] <= apply_gain(a0_ls, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                        adc_sample_r[0] <= apply_gain(a0_rs, state[8'h08].amp_gain_mute[6:0],
                                                      state[8'h08].amp_gain_mute[7]);
                    end
                    if (adc_frame_tick) begin
                        adc_valid_out[1] <= 1'b1;
                        adc_sample_l[1] <= apply_gain(a1_ls, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                        adc_sample_r[1] <= apply_gain(a1_rs, state[8'h09].amp_gain_mute[6:0],
                                                      state[8'h09].amp_gain_mute[7]);
                    end
                end
            end
        end
    endgenerate

endmodule
