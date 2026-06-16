# Digital Circuit Lab Final Project

Magnetic-field sensing and localization demo on the DE2-115 FPGA board.

The current design reads three QMC5883P magnetometers, computes calibrated magnetic values and AC `H^2` lock-in magnitudes at 75 Hz and 45 Hz, streams `H^2` data over RS232 for LUT construction, renders values on VGA/LCD, and provides a first DRV8825 stepper-motor test interface.

## External GPIO Connections

All GPIO signals are 3.3 V logic. Connect external module grounds to the DE2-115 ground.

### Magnetometers

Three magnetometers use independent I2C-style GPIO pairs:

| Sensor | Signal | DE2 GPIO | FPGA Pin |
| --- | --- | --- | --- |
| Sensor 1 | SCL | GPIO[0] | PIN_AB22 |
| Sensor 1 | SDA | GPIO[1] | PIN_AC15 |
| Sensor 2 | SCL | GPIO[2] | PIN_AB21 |
| Sensor 2 | SDA | GPIO[3] | PIN_Y17 |
| Sensor 3 | SCL | GPIO[4] | PIN_AC21 |
| Sensor 3 | SDA | GPIO[5] | PIN_Y16 |

Notes:

- SDA is driven open-drain style by the FPGA.
- Use 3.3 V pull-ups on SCL/SDA if the sensor breakout does not already include them.
- Power the magnetometers from a suitable 3.3 V supply unless the breakout explicitly supports another voltage.

### DRV8825 Stepper Driver

| DRV8825 Signal | DE2 GPIO | FPGA Pin | Meaning |
| --- | --- | --- | --- |
| STEP | GPIO[8] | PIN_AD15 | Rising edge advances one step/microstep |
| DIR | GPIO[9] | PIN_AE15 | Motor direction |
| ENABLE / nENBL | GPIO[10] | PIN_AC19 | Active-low driver enable |

Required wiring:

```text
DE2 GPIO[8]   -> DRV8825 STEP
DE2 GPIO[9]   -> DRV8825 DIR
DE2 GPIO[10]  -> DRV8825 ENABLE / nENBL
DE2 GND       -> DRV8825 GND
External PSU+ -> DRV8825 VMOT
External GND  -> DRV8825 GND
Motor coil A  -> DRV8825 A1/A2
Motor coil B  -> DRV8825 B1/B2
```

Important:

- Do not power the stepper motor from the FPGA.
- Put a capacitor near `VMOT` and `GND`, typically at least `100 uF`.
- Ensure `SLEEP` and `RESET` are high on the DRV8825 carrier board.
- Set the DRV8825 current limit before long tests.

## Board Interfaces

| Interface | Signal(s) | Usage |
| --- | --- | --- |
| RS232 | `UART_TXD` | Streams `H2,75,...,45,...` frames to PC |
| VGA | `VGA_R/G/B`, `VGA_HS`, `VGA_VS`, `VGA_CLK` | Displays sensor values and `H75/H45` |
| LCD | `LCD_DATA`, `LCD_RS`, `LCD_RW`, `LCD_EN` | Displays selected axis value |
| HEX7 | `HEX7` | Displays selected sensor number 1-3 |
| LEDR[17:0] | red LEDs | Selected-axis magnitude bar |
| LEDG[8:0] | green LEDs | Status indicators |

## Switch and Key Controls

### Magnetometer Display and Calibration

| Control | Meaning |
| --- | --- |
| KEY[0] | Start calibration collection |
| KEY[1] | Finish calibration collection and calculate coefficients |
| KEY[3] | Reset |
| SW[4] | Show calibrated values when calibration is done |
| SW[3:2] | Select sensor: `00` S1, `01` S2, `10` S3, `11` also maps to S3 |
| SW[1:0] | Select axis: `00` X, `01` Y, `10` Z |

### Stepper Motor Test

| Control | Meaning |
| --- | --- |
| SW[17] | Enable DRV8825 output, active high at switch |
| SW[16] | Direction command |
| SW[15] | Continuous stepping while enabled |
| KEY[2] | Move fixed 200 steps once |

Current FPGA stepper settings:

```text
STEP_RATE_HZ     = 500 steps/s
STEP_PULSE_US    = 5 us
FIXED_MOVE_STEPS = 200
```

For a first hardware test, keep `SW[17] = 0`, power the motor driver, then enable briefly with `SW[17] = 1`.

## LED Status

| LED | Meaning |
| --- | --- |
| LEDG[0] | All active magnetometers initialized |
| LEDG[1] | Calibration collecting |
| LEDG[2] | Calibration calculating |
| LEDG[3] | Calibration done |
| LEDG[4] | Lock-in result valid pulse |
| LEDG[5] | Calibration error |
| LEDG[6] | Stepper controller busy |
| LEDG[7] | DRV8825 enabled |
| LEDG[8] | Continuous stepper run command active |
| LEDR[17:0] | Selected-axis magnitude bar |

## UART H2 Frame

The FPGA sends one compact ASCII frame per UART update. The current FPGA build sends the three-sensor frame; the Python tools can still parse older four-sensor logs.

```text
H2,75,H75S1,H75S2,H75S3,45,H45S1,H45S2,H45S3
H2,75,H75S1,H75S2,H75S3,H75S4,45,H45S1,H45S2,H45S3,H45S4
```

Each value is unsigned 32-bit Q16 hex, representing `H^2` in Gauss squared with Q16 scaling.

## Python LUT and Classification Workflow

Install the PC-side dependency first:

```bash
pip install pyserial
```

Collect a LUT from one selected excitation frequency:

```bash
python3 src_python/collect_h2_lut.py COM5 --frequency 75 --output h75_lut.csv --key-names K0,K1,K2,K3,K4
```

During collection, the script prompts for each key and each sample position. Move the electromagnet/finger to the requested key location, hold it still, then press Enter to collect that LUT entry.
The script auto-detects whether the FPGA is sending three or four sensor values and records that in the CSV `sensor_count` column.

After collecting the LUT, classify live UART data:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv
```

Useful classifier options:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv --average 10 --stable 3 --print-hz 10
```

- `--average` controls how many recent H2 frames are averaged before scoring.
- `--stable` controls how many consecutive same-key results are required before the `stable=` field reports the key.
- `--strength-weight 0` classifies only by the normalized H2 pattern.
- `--min-total-g2` can reject very weak/no-signal frames.

The classifier compares the live normalized H2 distribution:

```text
F = [S1_H2, S2_H2, ...] / (S1_H2 + S2_H2 + ...)
```

against every LUT entry, then reports the lowest-score key and sampled position.
The live FPGA sensor count must match the LUT entry sensor count.
The `key=` field is the current best match, and the `stable=` field reports a key only after the same key has been detected for the configured number of consecutive classifications.
