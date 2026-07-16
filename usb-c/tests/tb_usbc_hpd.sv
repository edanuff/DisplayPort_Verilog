// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps

module tb_usbc_hpd;
    localparam integer CLK_HZ = 1_000_000;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic dp_alt_enable = 1'b0;
    logic hpd_level = 1'b0;
    logic hpd_irq_toggle = 1'b0;
    logic dp_reset;
    logic dp_hpd;
    wire hpd_irq;
    wire hpd_present;
    integer irq_count = 0;

    always #500 clk = ~clk;

    always @(posedge clk) begin
        if (hpd_irq)
            irq_count <= irq_count + 1;
    end

    usbc_dp_control #(
        .CLK_HZ(CLK_HZ),
        .IRQ_PULSE_US(750)
    ) bridge (
        .clk(clk),
        .reset(reset),
        .dp_alt_enable_async(dp_alt_enable),
        .hpd_level_async(hpd_level),
        .hpd_irq_toggle_async(hpd_irq_toggle),
        .dp_reset(dp_reset),
        .dp_hpd(dp_hpd)
    );

    hotplug_decode #(
        .CLK_HZ(CLK_HZ),
        .IRQ_MIN_US(500),
        .IRQ_MAX_US(1000),
        .DISCONNECT_US(2000),
        .PRESENT_US(2000)
    ) decoder (
        .clk(clk),
        .hpd(dp_hpd),
        .irq(hpd_irq),
        .present(hpd_present)
    );

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;
        dp_alt_enable = 1'b1;
        hpd_level = 1'b1;

        repeat (2100) @(posedge clk);
        #1;
        if (dp_reset || !hpd_present)
            $fatal(1, "HPD did not become present");

        hpd_irq_toggle = ~hpd_irq_toggle;
        repeat (1000) @(posedge clk);
        #1;
        if (irq_count != 1 || !hpd_present)
            $fatal(1, "750 us HPD IRQ was not decoded exactly once");

        hpd_level = 1'b0;
        repeat (1500) @(posedge clk);
        hpd_level = 1'b1;
        repeat (100) @(posedge clk);
        #1;
        if (irq_count != 1 || !hpd_present)
            $fatal(1, "invalid 1.5 ms low interval was misdecoded");

        hpd_level = 1'b0;
        repeat (2100) @(posedge clk);
        #1;
        if (hpd_present)
            $fatal(1, "2 ms HPD low interval did not disconnect");

        $display("USB-C HPD bridge test passed");
        $finish;
    end
endmodule
