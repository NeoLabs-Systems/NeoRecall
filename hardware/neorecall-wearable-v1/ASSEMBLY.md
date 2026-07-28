# Assembly and bring-up

## Required method

This board is self-assemblable with a stencil, solder paste, microscope, tweezers, and a controlled hot plate/reflow oven. It is not realistically buildable with only a conventional soldering iron: the T5848 land grid, BQ24074 exposed pad, TPS63021 VSON, and USB-C contacts require reflow. Passives are 0603/0805 except R1, R2, R28, and C23, which are common 0402 parts; most can be reworked by hand under magnification.

Order a 0.10–0.12 mm stainless stencil. Populate the front first. Populate the rear MEM2085 in the second cycle using a lower peak alloy or mechanically support the first-side components. Follow the lowest permitted reflow limit among the selected parts; do not exceed the MEM2085 255 °C peak specification.

## Inspection before power

1. Verify J2 pin 1 to `BAT_PLUS`, pin 2 to `BQ_TS`, and pin 3 to `GND`; verify the mating pack measures about 10 kΩ from pin 2 to pin 3 at 25 °C.
2. Verify no short between `VBUS_USB`, `BAT_PLUS`, `SYS_RAW`, `3V3`, `1V85`, and ground.
3. Inspect every exposed-pad device for bridges and alignment under magnification.
4. Inspect both microphone acoustic holes from the rear; they must be completely clear.
5. Confirm USB shell continuity to ground and isolation of CC1/CC2 from adjacent contacts.
6. Insert no battery and no microSD for the first power test.

## Current-limited bring-up

1. Feed 5.0 V through USB from a current-limited source set initially to 100 mA.
2. Confirm `SYS_RAW` is present and `3V3` rises without oscillation; then raise the current limit to 500 mA.
3. Confirm `BUCK_PG_N`, `CHARGER_PGOOD_N`, and `ESP_EN` reach a valid high state.
4. Enter ROM download mode by holding the center button while applying/resetting power, then enumerate native USB.
5. Build and flash `firmware/manufacturing-test`; it checks regulator/status GPIO, card detect, a synchronized SPI write/read/verify cycle, both I²S slots, battery ADC, safe card-power isolation, the button, and deep-sleep wake.
6. Attach a protected 1S LiPo with known polarity. Measure charge current and cell temperature for a full cycle before using any final enclosure.
7. Record simultaneous left/right audio, check for swapped channels, clipping, clock noise, and cross-channel leakage.
8. Run a Wi-Fi upload while repeatedly writing the microSD. There must be no brownout; log `BUCK_PG_N` and reset reason.

## Battery safety

- Use only a reputable protected 1S LiPo pack with the exact keyed three-pole JST-SH wiring and qualified 10 kΩ NTC curve.
- Never assume cable color establishes polarity; measure it.
- The charger is configured around 201 mA. Select a cell whose manufacturer explicitly permits at least that charge current.
- Confirm cold/hot thermistor cutoff behavior as well as charge testing inside the intended enclosure.
- Do not charge an inflated, punctured, hot, wet, or mechanically stressed cell.
- Add strain relief so movement cannot load J2 or abrade the pouch cell.

## Release gate

Do not call the hardware production-ready until a human PCB review and these measurements pass on at least three prototypes: USB signal integrity/enumeration, regulator transient response, charger thermal behavior, microphone noise/SNR, Wi-Fi/BLE enclosure range, microSD power-loss recovery, 24-hour recording stability, and sleep/wake current.
