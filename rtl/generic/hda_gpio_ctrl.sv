`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — GPIO Control
//------------------------------------------------------------------------------
// Parameterized for NUM_GPIO pins.  Supports DMIC override on GPIO[0:1].
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_gpio_ctrl #(
    parameter int NUM_GPIO = 2
) (
    input  logic clk,
    input  logic rst_n,
    inout  wire  [hda_codec_pkg::MAX_GPIO-1:0] gpio,
    input  logic dmic_mode_en,
    output logic dmic_clk_out,
    input  logic dmic_data_in,
    input  logic [7:0] gpio_enable,
    input  logic [7:0] gpio_direction,
    input  logic [7:0] gpio_wake,
    input  logic [7:0] gpio_unsol_en,
    input  logic [7:0] gpio_data_out,
    output logic [7:0] gpio_data_in,
    output logic        unsol_valid,
    output logic [31:0] unsol_data
);

    logic [NUM_GPIO-1:0] gpio_oe;
    logic [NUM_GPIO-1:0] gpio_out_val;
    logic [NUM_GPIO-1:0] gpio_in_sync;
    logic [NUM_GPIO-1:0] gpio_in_d;

    // Simple DMIC clock: divide bclk by 8 (~3 MHz from 24 MHz)
    logic [2:0] dmic_div;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dmic_div <= '0;
        else        dmic_div <= dmic_div + 1'b1;
    end
    assign dmic_clk_out = dmic_div[2];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_GPIO; gi++) begin : g_gpio
            // OE: output when enabled + direction=1, DMIC overrides GPIO0/1
            assign gpio_oe[gi] = gpio_enable[gi] & gpio_direction[gi] &
                                 ~(dmic_mode_en & (gi < 2));
            // Output value; GPIO0 can be DMIC_CLK
            assign gpio_out_val[gi] = (gi == 0 && dmic_mode_en) ? dmic_clk_out
                                                                 : gpio_data_out[gi];
            assign gpio[gi] = gpio_oe[gi] ? gpio_out_val[gi] : 1'bz;
        end
        // Tie off unused physical pins
        for (gi = NUM_GPIO; gi < hda_codec_pkg::MAX_GPIO; gi++) begin : g_gpio_tie
            assign gpio[gi] = 1'bz;
        end
    endgenerate

    // Synchronise inputs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_in_sync <= '0;
            gpio_in_d    <= '0;
        end else begin
            for (int i = 0; i < NUM_GPIO; i++) begin
                gpio_in_sync[i] <= gpio[i];
                gpio_in_d[i]    <= gpio_in_sync[i];
            end
        end
    end

    always_comb begin
        gpio_data_in = 8'h00;
        for (int i = 0; i < NUM_GPIO; i++)
            gpio_data_in[i] = gpio_in_sync[i];
    end

    // Unsolicited event on edge
    logic edge_detect;
    always_comb begin
        edge_detect = 1'b0;
        for (int i = 0; i < NUM_GPIO; i++)
            edge_detect |= gpio_unsol_en[i] & (gpio_in_sync[i] ^ gpio_in_d[i]);
    end
    assign unsol_valid = edge_detect;
    assign unsol_data  = {24'h0, gpio_data_in};

endmodule
