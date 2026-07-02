`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Beep Generator  (chip-independent)
//------------------------------------------------------------------------------
// Timing-optimized: the division (BASE_DIV / divider) is replaced by a
// compile-time lookup table ROM.  beep_ctrl[6:0] indexes 128 entries.
// This eliminates the ~50-level combinational carry chain entirely.
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_beep_gen (
    input  logic clk,
    input  logic rst_n,
    input  logic [7:0] beep_ctrl,
    output logic beep_out
);
    localparam int BASE_DIV = 24_000_000 / 1000 / 2;  // 12000

    // Pre-computed period ROM: period_rom[i] = BASE_DIV / i  (i=0 maps to BASE_DIV)
    logic [13:0] period_rom [0:127];
    initial begin
        period_rom[0] = BASE_DIV[13:0];
        for (int i = 1; i < 128; i++)
            period_rom[i] = (BASE_DIV / i);
    end

    logic [31:0] period;
    logic [31:0] counter;

    // Registered period from ROM — single LUT read, no division
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            period <= BASE_DIV;
        else
            period <= {18'd0, period_rom[beep_ctrl[6:0]]};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter  <= '0;
            beep_out <= 1'b0;
        end else if (!beep_ctrl[7]) begin
            beep_out <= 1'b0;
            counter  <= '0;
        end else begin
            if (counter >= period) begin
                counter  <= '0;
                beep_out <= ~beep_out;
            end else begin
                counter <= counter + 1'b1;
            end
        end
    end
endmodule
