`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — S/PDIF Output (up to 2 channels, chip-independent)
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_spdif_out #(
    parameter int NUM_SPDIF = 2
) (
    input  logic clk,
    input  logic rst_n,
    // Channel 0
    input  logic        ch0_en,
    input  logic [23:0] ch0_sample_l,
    input  logic [23:0] ch0_sample_r,
    output logic        ch0_spdif,
    // Channel 1
    input  logic        ch1_en,
    input  logic [23:0] ch1_sample_l,
    input  logic [23:0] ch1_sample_r,
    output logic        ch1_spdif
);

    localparam logic [7:0] PRE_B = 8'b1110_1000;
    localparam logic [7:0] PRE_M = 8'b1110_0010;

    logic [31:0] subframe0;
    logic [31:0] next_subframe0;
    logic [5:0]  bit_cnt0;

    // Combinational subframe update (load / shift)
    always_comb begin
        next_subframe0 = {subframe0[30:0], 1'b0};
        if (bit_cnt0 == 6'd0)       next_subframe0 = {PRE_B, ch0_sample_l, 4'b0001};
        else if (bit_cnt0 == 6'd32) next_subframe0 = {PRE_M, ch0_sample_r, 4'b0001};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            subframe0 <= '0;
            bit_cnt0  <= '0;
            ch0_spdif <= 1'b0;
        end else if (ch0_en) begin
            ch0_spdif <= next_subframe0[31];
            subframe0 <= next_subframe0;
            bit_cnt0  <= (bit_cnt0 >= 6'd63) ? 6'd0 : bit_cnt0 + 1'b1;
        end else begin
            ch0_spdif <= 1'b0;
            bit_cnt0  <= '0;
        end
    end

    generate
        if (NUM_SPDIF >= 2) begin : g_ch1
            logic [31:0] subframe1;
            logic [31:0] next_subframe1;
            logic [5:0]  bit_cnt1;

            always_comb begin
                next_subframe1 = {subframe1[30:0], 1'b0};
                if (bit_cnt1 == 6'd0)       next_subframe1 = {PRE_B, ch1_sample_l, 4'b0001};
                else if (bit_cnt1 == 6'd32) next_subframe1 = {PRE_M, ch1_sample_r, 4'b0001};
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    subframe1 <= '0;
                    bit_cnt1  <= '0;
                    ch1_spdif <= 1'b0;
                end else if (ch1_en) begin
                    ch1_spdif <= next_subframe1[31];
                    subframe1 <= next_subframe1;
                    bit_cnt1  <= (bit_cnt1 >= 6'd63) ? 6'd0 : bit_cnt1 + 1'b1;
                end else begin
                    ch1_spdif <= 1'b0;
                    bit_cnt1  <= '0;
                end
            end
        end else begin : g_ch1_tie
            assign ch1_spdif = 1'b0;
        end
    endgenerate

endmodule
