# USB-C reference implementation

This directory contains the scoped FUSB302B/ESP32-S3/TUSB1046A design described
in [SPEC.md](SPEC.md). It is an integration reference for an ESP-IDF project,
not a replacement for that project's existing USB host/device code.

## Architecture

![Chip-level architecture: FPGA DP lanes and AUX through the TUSB1046A to the
USB-C receptacle; ESP32-S3 + FUSB302B own CC/PD, the crosspoint controls, HPD
reconstruction, USB 2.0, and the 5 V/1 A source switch](docs/architecture.svg)

## Contents

- `include/usb_pd.h`: the PD 2.0 and DP Structured VDM fields used here;
- `include/fusb302.h`, `src/fusb302.c`: portable FUSB302 register/FIFO driver;
- `include/usbc_port.h`, `src/usbc_port.c`: fixed 5 V/1 A DRP and DP-source
  policy (see SPEC.md "Changing the source current budget");
- `examples/esp32s3_integration.[ch]`: board-hook adapter showing the ESP32-S3
  integration boundary and accepting pin assignments from the application;
- `rtl/usbc_dp_control.sv`: optional FPGA reset/HPD bridge;
- `tests/test_pd.c`: host-side checks for PDO, RDO, header, and DP VDO encoding;
- `tests/tb_usbc_hpd.sv`: the optional HPD bridge/decoder integration test.

## Integration contract

The incorporating project supplies callbacks for:

- FUSB302 I2C register and FIFO burst reads/writes;
- a monotonic millisecond clock and microsecond delay;
- VBUS source-switch enable;
- stopping/starting the ESP32-S3 USB device or host stack;
- TUSB1046A `FLIP`, `CTL0`, `CTL1`, and `HPDIN` GPIOs; and
- FPGA DP enable, HPD level, and optionally HPD IRQ.

The I2C callbacks must support a write of one register address followed by a
multi-byte transfer. FUSB302 register `0x43` is a FIFO: all bytes in a burst
read or write access that same register rather than incrementing the address.

Call `usbc_port_task()` from one task at least every millisecond and wake that
task immediately when FUSB302 `INT_N` falls. Do not call it concurrently from
an ISR and a task.

Typical startup is:

```c
usbc_port_config_t config;
usbc_port_t port;

usbc_port_default_config(&config);
usbc_port_init(&port, &config, &hal, &fusb_io,
               FUSB302_I2C_ADDRESS_DEFAULT);
usbc_port_enable(&port);
```

`examples/esp32s3_integration.c` leaves `app_usb_select_role()` to the existing
firmware because ESP32-S3 projects differ in how they stop the USB device
function, release the shared PHY, and start the host stack.

The application declares an `esp32s3_usbc_t`, fills an
`esp32s3_usbc_pins_t`, calls `esp32s3_usbc_init()`, and then calls
`esp32s3_usbc_task()` from the port task. The example header contains no
ESP-IDF types, so GPIO numbers and ESP-IDF configuration remain in the
incorporating project's board/main files.

## TUSB1046A startup

The GPIO adapter must pulse `CTL0` high then low at board initialization while
`CTL1` is low. Thereafter the policy uses only:

- `CTL1=0, CTL0=0`: power down; and
- `CTL1=1, CTL0=0`: four-pair DisplayPort, pin assignment C/E.

USB D+/D- do not pass through the TUSB1046A.

## FPGA connection

No new FPGA logic is required if the ESP32 directly supplies a DP enable/reset
signal and a correctly timed HPD waveform. If using the optional bridge:

```systemverilog
logic usbc_dp_reset, usbc_dp_hpd;

usbc_dp_control #(.CLK_HZ(100_000_000)) i_usbc_dp_control (
    .clk                   (clk100),
    .reset                 (~rst_btn_n),
    .dp_alt_enable_async   (esp_dp_enable),
    .hpd_level_async       (esp_hpd_level),
    .hpd_irq_toggle_async  (esp_hpd_irq_toggle),
    .dp_reset              (usbc_dp_reset),
    .dp_hpd                (usbc_dp_hpd)
);

// Combine usbc_dp_reset with the board/system reset for dp_transmitter.reset.
// Connect usbc_dp_hpd to dp_transmitter.hpd.
```

Toggle `hpd_irq_toggle_async` once for each Attention VDO with `HPD_IRQ=1`.
The bridge produces a 0.75 ms low pulse. The parameterized
`src/auxch/hotplug_decode.v` recognizes it as an IRQ and uses a 2 ms low
threshold for disconnect.

## Local checks

```sh
make -C usb-c check
```

This compiles the portable C with strict warnings, runs the encoding test, and
runs the optional HPD bridge/decoder simulation when Icarus Verilog is
available.

## Alternative: autonomous PD controller

This directory is the recommended approach for this repository. As an
alternative, a stand-alone Alt-Mode-capable PD controller (for example
the TI TPS65987D, configured as a DFP_D DisplayPort source driving the
same TUSB1046A mux and HPD wiring) removes all PD firmware from the MCU
at the cost of an NRND part, an SPI configuration flash, and the vendor
configuration-tool workflow. See `examples/tang_mega/README.md`; the
detailed controller configuration is left as an exercise for the
implementor.
