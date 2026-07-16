// SPDX-License-Identifier: MIT
// Optional ESP32-to-dp_transmitter bridge. The USB-C design does not require
// FPGA-side PD logic; this block only converts an HPD IRQ event into the timed
// low pulse expected by the existing hotplug_decode module and supplies a
// convenient active-high DP reset.
`timescale 1ns / 1ps

module usbc_dp_control #(
    parameter longint CLK_HZ = 100_000_000,
    parameter int IRQ_PULSE_US = 750
) (
    input  logic clk,
    input  logic reset,

    // Asynchronous GPIOs from the ESP32. Toggle hpd_irq_toggle once per IRQ.
    input  logic dp_alt_enable_async,
    input  logic hpd_level_async,
    input  logic hpd_irq_toggle_async,

    output logic dp_reset,
    output logic dp_hpd
);

    localparam longint IRQ_CYCLES_LONG =
        (CLK_HZ * IRQ_PULSE_US + 999_999) / 1_000_000;
    localparam int IRQ_CYCLES = int'(IRQ_CYCLES_LONG);
    localparam int COUNTER_WIDTH = $clog2(IRQ_CYCLES + 1);

    logic [1:0] enable_sync;
    logic [1:0] hpd_sync;
    logic [1:0] irq_toggle_sync;
    logic       irq_toggle_seen;
    logic [COUNTER_WIDTH-1:0] irq_count;

    always_ff @(posedge clk) begin
        if (reset) begin
            enable_sync     <= 2'b00;
            hpd_sync        <= 2'b00;
            irq_toggle_sync <= 2'b00;
            irq_toggle_seen <= 1'b0;
            irq_count       <= '0;
        end else begin
            enable_sync     <= {enable_sync[0], dp_alt_enable_async};
            hpd_sync        <= {hpd_sync[0], hpd_level_async};
            irq_toggle_sync <= {irq_toggle_sync[0], hpd_irq_toggle_async};

            if (irq_toggle_sync[1] != irq_toggle_seen) begin
                irq_toggle_seen <= irq_toggle_sync[1];
                if (enable_sync[1] && hpd_sync[1])
                    irq_count <= COUNTER_WIDTH'(IRQ_CYCLES);
            end else if (irq_count != '0) begin
                irq_count <= irq_count - 1'b1;
            end

            if (!enable_sync[1] || !hpd_sync[1])
                irq_count <= '0;
        end
    end

    assign dp_reset = reset || !enable_sync[1];
    assign dp_hpd   = enable_sync[1] && hpd_sync[1] && (irq_count == '0);

endmodule
