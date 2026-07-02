`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// HDA Address-Test Controller BFM
//------------------------------------------------------------------------------
// Extended BFM for HDA codec address configuration testing.
// Differences from hda_codec_bfm.sv:
//   • Parameterisable TARGET_CODEC_ADDR for init
//   • Runtime set_codec_addr() to change the address field in commands
//   • send_cmd_to() — send a verb to an arbitrary codec address
//   • send_cmd_expect_nak() — send and verify NO response (wrong address)
//   • init_assign_addr() — re-run address-assignment sequence at runtime
//   • reset_link() / cold_reset_link() — reset control for persistence tests
//   • Exposes init-phase state for testbench observability
//------------------------------------------------------------------------------
`include "hda_codec_pkg.sv"

module hda_addr_ctrl_bfm #(
    parameter logic [3:0] TARGET_CODEC_ADDR = 4'h0,
    parameter int         BCLK_HZ           = 24_000_000,
    parameter int         FRAME_HZ          = 48_000,
    parameter int         SYNC_WIDTH        = 4
) (
    output logic clk,
    output logic rst_n,
    output logic sdo,
    input  logic sdi,
    output logic sdi_drv,
    output logic sdi_drv_oe,
    output logic sync,
    output logic pd_n,
    output logic link_init_done
);

    import hda_codec_pkg::*;

    localparam int BCLK_PER_FRAME = BCLK_HZ / FRAME_HZ;  // 500

    //==========================================================================
    // Internal State
    //==========================================================================
    logic [3:0]  active_codec_addr;   // address field used in send_cmd_to
    logic        init_running;        // flag: init sequence in progress
    logic        cmd_in_flight;       // flag: wait_for_response active

    //==========================================================================
    // Clock: 24 MHz
    //==========================================================================
    initial begin clk = 1'b0; forever #20.833ns clk = ~clk; end

    //==========================================================================
    // Reset, Power & Initialization
    //==========================================================================
    initial begin
        rst_n = 1'b0; pd_n = 1'b0; sdo = 1'b0; sync = 1'b0;
        sdi_drv = 1'b0; sdi_drv_oe = 1'b0; link_init_done = 1'b0;
        active_codec_addr = TARGET_CODEC_ADDR;
        init_running = 1'b1;
        cmd_in_flight = 1'b0;

        repeat (20) @(posedge clk);          // power ramp
        rst_n = 1'b1; pd_n = 1'b1;

        //==========================================================================
        // §5.5.3: standard init — lock onto codec's init request.
        // The init_req_q pulse occurs on the last BCLK of Frame Sync in the
        // Connect Frame, which coincides with the sof_predict / frame_start
        // edge that transitions Connect→Turnaround.
        //==========================================================================
        @(posedge clk iff (sdi === 1'b1));   // 1. Connect→Turnaround frame_start

        // 2. Wait for Address frame's SYNC, set up SDI drive BEFORE frame_start
        //    so the codec's posedge sampler sees the correct value at the
        //    Address frame_start edge (the codec pipelines sdi_in by 1 cycle).
        @(posedge clk iff sync);             // Address frame SYNC goes high
        sdi_drv_oe = 1'b1;
        sdi_drv    = (TARGET_CODEC_ADDR != 0);
        @(posedge clk iff !sync);            // Address frame_start — sdi stable
        // Hold sdi high for TARGET_CODEC_ADDR BCLK after frame_start
        for (int n = 0; n < TARGET_CODEC_ADDR; n++) @(posedge clk);
        sdi_drv = 1'b0;
        repeat (2) @(posedge clk);
        sdi_drv_oe = 1'b0;

        wait_frame_start();                  // 3. Address→Normal frame_start

        // ---- Prime the response pipeline (same as reinit_assign_addr) ----
        begin
            logic [35:0] dummy_resp;
            logic [39:0] dummy_cmd;
            dummy_cmd = {8'h00, TARGET_CODEC_ADDR, 8'h01, VERB_GET_PARAM, 8'h00};
            wait_frame_start();
            drive_sdo_ddr({8'h0, dummy_cmd}, 40, 1);
            @(posedge clk); #1; sdo = 1'b0;
            wait_frame_start();
            for (int i = 35; i >= 0; i--) begin
                dummy_resp[i] = sdi;
                @(posedge clk);
            end
        end

        link_init_done = 1'b1;
        init_running  = 1'b0;
        $display("[ADDR_BFM] Init done — codec address = %0d", TARGET_CODEC_ADDR);
    end

    //==========================================================================
    // SYNC Generation — 4-BCLK Frame Sync (§5.3)
    //==========================================================================
    initial begin
        sync = 1'b0;
        wait (rst_n === 1'b1);
        @(posedge clk);
        forever begin
            #1 sync = 1'b1;
            repeat (SYNC_WIDTH) @(posedge clk);
            #1 sync = 1'b0;
            repeat (BCLK_PER_FRAME - SYNC_WIDTH) @(posedge clk);
        end
    end

    //==========================================================================
    // Helpers
    //==========================================================================
    task automatic wait_frame_start();
        @(posedge clk iff sync);   // wait for SYNC high
        @(posedge clk iff !sync);  // SYNC falls = frame start
    endtask

    //--------------------------------------------------------------------------
    // Drive SDI bus during Address Frame (§5.5.3.2)
    //   assert SDI high for `addr` BCLK cycles after Frame-Sync falling edge,
    //   then drop low → codec latches address = addr.
    //--------------------------------------------------------------------------
    task automatic drive_address(input logic [3:0] addr);
        sdi_drv_oe = 1'b1;
        sdi_drv    = (addr != 0);
        for (int n = 0; n < addr; n++) @(posedge clk);
        sdi_drv = 1'b0;
        repeat (2) @(posedge clk);
        sdi_drv_oe = 1'b0;
    endtask

    //--------------------------------------------------------------------------
    // DDR SDO drive — MSB-first, 2 bits per BCLK
    //--------------------------------------------------------------------------
    task automatic drive_sdo_ddr(
        input logic [47:0] data, input int len, input bit first_in_frame = 0
    );
        for (int i = len-1; i >= 0; i -= 2) begin
            if (i != len-1 || !first_in_frame) @(posedge clk);
            #1; sdo = data[i];
            @(negedge clk); #1; sdo = data[i-1];
        end
    endtask

    task automatic drive_sdo_zero_ddr(input int len, input bit first_in_frame = 0);
        for (int i = 0; i < len; i += 2) begin
            if (i != 0 || !first_in_frame) @(posedge clk);
            #1; sdo = 1'b0;
            @(negedge clk); #1; sdo = 1'b0;
        end
    endtask

    //==========================================================================
    // Public Tasks — Address Testing API
    //==========================================================================

    //--------------------------------------------------------------------------
    // set_codec_addr: change the active address field for subsequent commands.
    //   Does NOT re-init the link; only changes the 4-bit field in the 40-bit
    //   command word (§7.3).  The link-layer address assigned at init is
    //   unchanged.
    //--------------------------------------------------------------------------
    task automatic set_codec_addr(input logic [3:0] a);
        active_codec_addr = a;
        $display("[ADDR_BFM] set_codec_addr -> %0d", a);
    endtask

    //--------------------------------------------------------------------------
    // send_cmd_to: send a 40-bit command with explicit codec_addr field
    //   and capture the 36-bit response.
    //   Returns response[35] (Valid bit) for pass/fail decisions.
    //--------------------------------------------------------------------------
    task automatic send_cmd_to(
        input  logic [3:0]  codec_addr,
        input  logic [7:0]  nid,
        input  logic [11:0] verb,
        input  logic [15:0] payload,
        output logic [35:0] resp
    );
        logic [39:0] cmd;
        logic        is_4bit;
        is_4bit = (verb <= 12'h00F);
        if (is_4bit)
            cmd = {8'h00, codec_addr, nid, verb[3:0], payload};
        else
            cmd = {8'h00, codec_addr, nid, verb, payload[7:0]};

        cmd_in_flight = 1'b1;
        wait_frame_start();

        // synthesis translate_off
        $display("[ADDR_BFM] send_cmd_to addr=%0d NID=0x%02X verb=0x%03X raw=%010X",
                 codec_addr, nid, verb, cmd);
        // synthesis translate_on

        drive_sdo_ddr({8'h0, cmd}, 40, 1);
        @(posedge clk); #1; sdo = 1'b0;

        // Response frame: codec drives MSB at Start-of-Frame (zero-latency load)
        wait_frame_start();
        for (int i = 35; i >= 0; i--) begin
            resp[i] = sdi;
            @(posedge clk);
        end
        cmd_in_flight = 1'b0;
    endtask

    //--------------------------------------------------------------------------
    // send_cmd_expect_nak: send to a wrong address and verify the codec
    //   does NOT respond (Valid bit = 0).  Returns 1 if correctly ignored.
    //--------------------------------------------------------------------------
    task automatic send_cmd_expect_nak(
        input logic [3:0]  codec_addr,
        input logic [7:0]  nid,
        input logic [11:0] verb,
        input logic [15:0] payload,
        output logic        nak_ok
    );
        logic [35:0] resp;
        send_cmd_to(codec_addr, nid, verb, payload, resp);
        nak_ok = (resp[35] === 1'b0);
        if (nak_ok)
            $display("[ADDR_BFM]   -> NAK as expected (Valid=0)");
        else
            $display("[ADDR_BFM]   -> UNEXPECTED RESPONSE! Valid=1 data=0x%08X",
                     resp[31:0]);
    endtask

    //--------------------------------------------------------------------------
    // send_verb: convenience wrapper using active_codec_addr
    //--------------------------------------------------------------------------
    task automatic send_verb(
        input  logic [7:0]  nid,
        input  logic [11:0] verb,
        input  logic [15:0] payload,
        output logic [35:0] resp
    );
        send_cmd_to(active_codec_addr, nid, verb, payload, resp);
    endtask

    //--------------------------------------------------------------------------
    // write_verb / read_verb: standard verb access using active_codec_addr
    //--------------------------------------------------------------------------
    task automatic write_verb(
        input logic [7:0]  nid,
        input logic [11:0] verb,
        input logic [15:0] payload
    );
        logic [35:0] r;
        send_cmd_to(active_codec_addr, nid, verb, payload, r);
    endtask

    task automatic read_verb(
        input  logic [7:0]  nid,
        input  logic [11:0] verb,
        input  logic [15:0] payload,
        output logic [31:0] data
    );
        logic [35:0] r;
        send_cmd_to(active_codec_addr, nid, verb, payload, r);
        if (r[35] !== 1'b1)
            $display("[ADDR_BFM] WARNING: response Valid bit not set, resp=%09X", r);
        data = r[31:0];
    endtask

    //--------------------------------------------------------------------------
    // reinit_assign_addr: re-run the full address-assignment sequence at
    //   runtime.  Used for testing address reassignment after reset.
    //   The codec must be in or entering the init sequence.
    //
    //   CRITICAL TIMING: the codec pipelines sdi_in by one BCLK (posedge
    //   sampler → sdi_in_r).  The BFM must set up sdi_drv DURING the Address
    //   frame's SYNC-high period so that the first sdi_in sample at the
    //   Address frame_start edge already reflects the intended address value.
    //--------------------------------------------------------------------------
    task automatic reinit_assign_addr(input logic [3:0] new_addr);
        $display("[ADDR_BFM] reinit_assign_addr -> %0d", new_addr);
        init_running = 1'b1;
        link_init_done = 1'b0;

        // 1. Wait for codec init request (Connect→Turnaround frame_start)
        @(posedge clk iff (sdi === 1'b1));

        // 2. Address frame with pre-frame_start SDI drive
        @(posedge clk iff sync);             // Address frame SYNC high
        sdi_drv_oe = 1'b1;
        sdi_drv    = (new_addr != 0);
        @(posedge clk iff !sync);            // Address frame_start
        for (int n = 0; n < new_addr; n++) @(posedge clk);
        sdi_drv = 1'b0;
        repeat (2) @(posedge clk);
        sdi_drv_oe = 1'b0;

        // 3. Address→Normal frame_start
        wait_frame_start();

        // ---- Prime the response pipeline ----
        // The codec's first response frame after init carries a stale SDI
        // shift register (all zeros).  Send one no-op command and consume
        // its response so the link is fully primed before any real traffic.
        begin
            logic [35:0] dummy_resp;
            logic [39:0] dummy_cmd;
            dummy_cmd = {8'h00, new_addr, 8'h01, VERB_GET_PARAM, 8'h00};
            wait_frame_start();
            drive_sdo_ddr({8'h0, dummy_cmd}, 40, 1);
            @(posedge clk); #1; sdo = 1'b0;
            wait_frame_start();
            for (int i = 35; i >= 0; i--) begin
                dummy_resp[i] = sdi;
                @(posedge clk);
            end
        end

        active_codec_addr = new_addr;
        link_init_done = 1'b1;
        init_running  = 1'b0;
        $display("[ADDR_BFM] Re-init done — new address = %0d", new_addr);
    endtask

    //--------------------------------------------------------------------------
    // cold_reset_link: assert rst_n low for N cycles → full link reset.
    //   Codec loses address, must re-init.
    //--------------------------------------------------------------------------
    task automatic cold_reset_link(input int cycles = 50);
        $display("[ADDR_BFM] Cold reset — rst_n low for %0d cycles", cycles);
        link_init_done = 1'b0;
        init_running  = 1'b0;
        rst_n = 1'b0;
        repeat (cycles) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
    endtask

    //--------------------------------------------------------------------------
    // warm_reset_link: pulse rst_n briefly (simulates link reset without
    //   full power cycle).  Address may or may not be preserved depending
    //   on implementation.
    //--------------------------------------------------------------------------
    task automatic warm_reset_link(input int cycles = 10);
        $display("[ADDR_BFM] Warm reset — rst_n low for %0d cycles", cycles);
        link_init_done = 1'b0;
        init_running  = 1'b0;
        rst_n = 1'b0;
        repeat (cycles) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    //--------------------------------------------------------------------------
    // wait_ready: block until link_init_done and not in init
    //--------------------------------------------------------------------------
    task automatic wait_ready();
        wait (link_init_done === 1'b1 && init_running === 1'b0);
    endtask

    //--------------------------------------------------------------------------
    // send_raw_cmd: send arbitrary 40-bit command (for link-layer testing)
    //--------------------------------------------------------------------------
    task automatic send_raw_cmd(
        input  logic [39:0] raw,
        output logic [35:0] resp
    );
        logic [35:0] captured;
        wait_frame_start();
        drive_sdo_ddr({8'h0, raw}, 40, 1);
        @(posedge clk); #1; sdo = 1'b0;
        wait_frame_start();
        for (int i = 35; i >= 0; i--) begin
            captured[i] = sdi;
            @(posedge clk);
        end
        resp = captured;
    endtask

endmodule
