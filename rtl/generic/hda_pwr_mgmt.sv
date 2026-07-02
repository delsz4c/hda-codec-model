`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Generic HDA Codec — Power Management
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_pwr_mgmt #(
    parameter int CHIP_ID = 0
) (
    input  logic rst_n,
    input  logic pd_n,
    input  hda_codec_pkg::widget_state_t state [0:hda_codec_pkg::WS_SIZE-1],
    output logic codec_ready,
    output logic afg_powered,
    output logic dac_powered,
    output logic adc_powered,
    output logic spdif_powered
);

    import hda_codec_pkg::*;

    assign codec_ready = rst_n & pd_n;
    assign afg_powered = codec_ready && (state[8'h01].power_state != PWR_D3);

    // DAC powered: all DACs not in D3
    always_comb begin
        dac_powered = afg_powered;
        for (int d = 0; d < cfg_num_dac(CHIP_ID); d++)
            dac_powered &= (state[nid_dac(CHIP_ID, d)].power_state != PWR_D3);
    end

    // ADC powered: all ADCs not in D3
    always_comb begin
        adc_powered = afg_powered;
        for (int a = 0; a < cfg_num_adc(CHIP_ID); a++)
            adc_powered &= (state[nid_adc(CHIP_ID, a)].power_state != PWR_D3);
    end

    // SPDIF powered
    always_comb begin
        spdif_powered = afg_powered;
        for (int s = 0; s < cfg_num_spdif(CHIP_ID); s++)
            spdif_powered &= (state[nid_spdif(CHIP_ID, s)].power_state != PWR_D3);
    end

endmodule
