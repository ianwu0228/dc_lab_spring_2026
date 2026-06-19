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

### Piano Press Buttons

The two external press buttons are active-high digital inputs. Each button module should share ground with the DE2-115 and must output 3.3 V logic to the FPGA signal pin.

| Button | DE2 GPIO | FPGA Pin | Meaning |
| --- | --- | --- | --- |
| Button 0 signal | GPIO[11] | PIN_AF16 | Press state for the 75 Hz tracked note |
| Button 1 signal | GPIO[12] | PIN_AD19 | Press state for the 45 Hz tracked note |

Required wiring per button:

```text
Button VDD    -> 3.3 V
Button GND    -> DE2 GND
Button SIGNAL -> assigned GPIO input
```

The FPGA debounces these inputs for `10 ms` before sending them to the PC.

## Board Interfaces

| Interface | Signal(s) | Usage |
| --- | --- | --- |
| RS232 | `UART_TXD` | Streams `H2,75,...,45,...` and `KEY,75,xx,p75,45,yy,p45` frames to PC |
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

## UART Frames

The FPGA sends compact ASCII UART frames. The current FPGA build alternates between the three-sensor H2 frame and a key/press frame. The Python H2 tools ignore non-H2 lines, so the extra key frame does not break LUT collection or plotting.

```text
H2,75,H75S1,H75S2,H75S3,45,H45S1,H45S2,H45S3
H2,75,H75S1,H75S2,H75S3,H75S4,45,H45S1,H45S2,H45S3,H45S4
KEY,75,KEY75,PRESS75,45,KEY45,PRESS45
```

Each H2 value is unsigned 32-bit Q16 hex, representing `H^2` in Gauss squared with Q16 scaling. `KEY75` and `KEY45` are two-digit decimal global key indices, `00` through `14`. `PRESS75` and `PRESS45` are debounced active-high button states, `0` or `1`.

To read only the FPGA key and press state on the PC:

```bash
python3 src_python/read_key_uart.py COM5
```

To map global keys to note names:

```bash
python3 src_python/read_key_uart.py COM5 --notes F3,G3,A3,B3,C4,D4,E4,F4,G4,A4,B4,C5,D5,E5,F5
```

To show a live piano-key window and play notes while the press buttons are held, install `pygame` first. This is the recommended backend because it supports low-latency note start and exact note stop on button release:

```bash
pip install pygame
```

Recommended low-latency run command:

```bash
python3 src_python/piano_key_monitor.py COM5 --notes F3,G3,A3,B3,C4,D4,E4,F4,G4,A4,B4,C5,D5,E5,F5 --buffer-size 64 --poll-ms 2 --volume 0.6
```

The monitor starts the note when the FPGA press bit becomes `1` and stops it when the press bit returns to `0`. It updates audio before redrawing the Tk keyboard display, so the sound path does not wait for GUI rendering.

Basic run command, using default latency settings:

```bash
python3 src_python/piano_key_monitor.py COM5 --notes F3,G3,A3,B3,C4,D4,E4,F4,G4,A4,B4,C5,D5,E5,F5
```

On Windows, if `pygame` is not installed, `piano_key_monitor.py` falls back to the built-in `winsound` beep backend. That fallback is only for quick testing; it cannot stop a note exactly on button release, so it will feel less synchronized than `pygame`.

The FPGA reports global key indices `0..14`, so provide 15 note names if all global keys are used. The software maps key `0` to the first note in the list, key `1` to the second note, and so on. Replace the example with your exact physical key mapping if it differs.

## Python LUT and Classification Workflow

Install the PC-side dependency first:

```bash
pip install pyserial
```

Collect a LUT from one selected excitation frequency. Each command collects exactly one z layer. The first command creates or overwrites the CSV; later layer commands must use `--append` so all layers for the same frequency are saved into the same LUT file.

For five keys, one layer contains `5 keys x 3 points = 15` entries. Collect the layers separately like this:

```bash
# Layer 0: key press plane. This creates h75_lut.csv.
python3 src_python/collect_h2_lut.py COM5 --frequency 75 --output h75_lut.csv --key-names K0,K1,K2,K3,K4 --z-layer-id 0 --z-layer-name press

# Layer 1: lower hover plane. This appends to h75_lut.csv.
python3 src_python/collect_h2_lut.py COM5 --frequency 75 --output h75_lut.csv --key-names K0,K1,K2,K3,K4 --z-layer-id 1 --z-layer-name hover-low --append

# Layer 2: upper hover plane. This appends to h75_lut.csv.
python3 src_python/collect_h2_lut.py COM5 --frequency 75 --output h75_lut.csv --key-names K0,K1,K2,K3,K4 --z-layer-id 2 --z-layer-name hover-high --append
```

To append the second physical layer after layer 0 is already collected, use the layer 1 command with `--append`:

```bash
python3 src_python/collect_h2_lut.py COM5 --frequency 75 --output h75_lut.csv --key-names K0,K1,K2,K3,K4 --z-layer-id 1 --z-layer-name hover-low --append
```

The important part is `--append`. Without it, `h75_lut.csv` is opened as a new file and the layer 0 data is replaced.

During collection, the script prompts for each key and each sample position. Each key is sampled at three centered vertical points: `top`, `middle`, and `bottom`. Move the electromagnet/finger to the requested point, hold it still, then press Enter to collect that LUT entry.
The script auto-detects whether the FPGA is sending three or four sensor values and records that in the CSV `sensor_count` column.
After all three runs, the CSV contains `5 keys x 3 points x 3 z layers = 45` LUT entries per frequency. If you restart the first layer without `--append`, the old CSV is intentionally replaced.

The intended z layers are:

- `z_layer_id=0`, `press`: key plane, used later when the pressure sensor confirms a real press.
- `z_layer_id=1`, `hover-low`: lower hover plane, used for platform tracking.
- `z_layer_id=2`, `hover-high`: upper hover plane, used for platform tracking.

After collecting the LUT, classify live UART data on the press plane:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv --z-layers 0
```

Classify hover position for platform tracking using the two hover layers:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv --z-layers 1,2
```

Classify the key across both pressed and hovering heights using all three layers:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv --z-layers 0,1,2 --key-score min
```

This still reports only the key, for example `K0` through `K4`. The z layer is not treated as a separate class; it only provides extra LUT samples so the same key can be recognized when the finger is on the key plane or hovering above it.

To classify both 75 Hz and 45 Hz components from the same UART stream:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency both --lut-75 h75_lut.csv --lut-45 h45_lut.csv --z-layers 0,1,2
```

To show a simple live key animation:

```bash
python3 src_python/animate_h2_keys.py COM5 --frequency 75 --lut h75_lut.csv --z-layers 0,1,2
```

Useful classifier options:

```bash
python3 src_python/classify_h2_lut.py COM5 --frequency 75 --lut h75_lut.csv --average 10 --stable 3 --print-hz 10
```

- `--average` controls how many recent H2 frames are averaged before scoring.
- `--stable` controls how many consecutive same-key results are required before the `stable=` field reports the key.
- `--strength-weight 0` classifies only by the normalized H2 pattern.
- `--key-score min|sum` controls how the sampled point errors are combined into one key score. Default is `min`.
- `--z-layers 0` uses only the press layer.
- `--z-layers 1,2` uses both hover layers.
- `--z-layers 0,1,2` uses all layers to classify the key regardless of press/hover height.
- `--min-total-g2` can reject very weak/no-signal frames.

Key score modes:

- `min`: use only the nearest sampled point error for each key.
- `sum`: add all selected sampled point errors for each key.

The classifier compares the live normalized H2 distribution:

```text
F = [S1_H2, S2_H2, ...] / (S1_H2 + S2_H2 + ...)
```

against the LUT entries. It first computes errors to each sampled point and selected z layer, then groups those errors by `key_id` and reports the lowest-score key.
The live FPGA sensor count must match the LUT entry sensor count.
The `key=` field is the current best key match, `z=` and `pos=` show the nearest sampled z layer and point for debugging, and `stable=` reports a key only after the same key has been detected for the configured number of consecutive classifications.

## Python Platform Tracking With Arduino Stepper

After both `h75_lut.csv` and `h45_lut.csv` are collected, the PC can classify the two electromagnets and command the sliding platform through an Arduino connected to the DRV8825 driver.

The tracker assumes the local five-key sensing window is:

```text
K0 K1 K2 K3 K4
-2 -1  0 +1 +2
```

The current global keyboard has 15 keys. The platform center is allowed to move from global key `2` to global key `12`. The default starting center is global key `12`, so it cannot move farther right at startup. One key movement is `100` motor steps by default.

First run in dry-run mode. This reads the FPGA COM port and prints the Arduino command that would be sent, but does not move the motor:

```bash
python3 src_python/track_platform_stepper.py COM5 --lut-75 h75_lut.csv --lut-45 h45_lut.csv
```

To actually command the Arduino, pass the Arduino COM port and `--enable-motor`:

```bash
python3 src_python/track_platform_stepper.py COM5 COM6 --lut-75 h75_lut.csv --lut-45 h45_lut.csv --enable-motor
```

The control rule is:

```text
local_center_sum = local_75Hz + local_45Hz

if local_center_sum <= -2: move left  one key = -100 steps
if local_center_sum >= +2: move right one key = +100 steps
otherwise: stay
```

The script requires the same nonzero movement request for `--move-stable` consecutive classifications before moving. After a move, it waits for the estimated motor motion time plus `--move-cooldown`, clears old FPGA samples, and continues from the new platform center.

Useful options:

```bash
python3 src_python/track_platform_stepper.py COM5 COM6 --lut-75 h75_lut.csv --lut-45 h45_lut.csv --enable-motor --z-layers 1,2 --move-stable 3 --steps-per-key 100
```

- `--z-layers 1,2` uses only hover layers for platform tracking.
- `--z-layers 0,1,2` uses all collected layers. This is the default.
- `--initial-center-key 12` sets the starting global platform center.
- `--min-center-key 2` and `--max-center-key 12` clamp the allowed platform travel.
- `--steps-per-key 100` sets the motor distance for one key shift.
- `--enable-motor` is required before any Arduino command is actually sent.

## FPGA LUT Classification and Direct Stepper Control

The current HDL can also perform the live classification and platform movement directly on the FPGA, without Python in the runtime loop.

Runtime data path:

```text
QMC sensors
-> FPGA 75 Hz / 45 Hz H2 extraction
-> FPGA LUT classifiers
-> FPGA platform tracker
-> GPIO[8:10] directly drive DRV8825 STEP/DIR/ENABLE_N
```

The FPGA LUT ROM files are:

```text
src/h75_lut_3sensor.mem
src/h45_lut_3sensor.mem
```

They are generated from the collected CSV LUTs. After recollecting a LUT, regenerate the ROM contents before compiling Quartus:

```bash
python3 src_python/export_lut_mem.py src_python/h75_lut.csv src/h75_lut_3sensor.mem --frequency 75
python3 src_python/export_lut_mem.py src_python/h45_lut.csv src/h45_lut_3sensor.mem --frequency 45
```

The exported ROM stores the same features used by `src_python/classify_h2_lut.py`:

```text
f1 = H2_sensor1 / (H2_sensor1 + H2_sensor2 + H2_sensor3)
f2 = H2_sensor2 / (H2_sensor1 + H2_sensor2 + H2_sensor3)
f3 = H2_sensor3 / (H2_sensor1 + H2_sensor2 + H2_sensor3)
strength = ln(H2_sensor1 + H2_sensor2 + H2_sensor3)
```

Before classification, the FPGA averages the latest 10 complete H2 frames for each frequency, matching the Python default `--average 10`.

The FPGA classifier then uses the Python default scoring method:

```text
ratio_error = (live_f1 - lut_f1)^2 + (live_f2 - lut_f2)^2 + (live_f3 - lut_f3)^2
strength_error = (ln(live_total_H2) - ln(lut_total_H2))^2
entry_score = ratio_error + 0.05 * strength_error
```

For each key, the classifier keeps the minimum entry score among all sampled points and z layers, then reports the key with the lowest score. The current FPGA classifier is for the three-sensor build.

FPGA stepper controls:

```text
GPIO[8]  -> DRV8825 STEP
GPIO[9]  -> DRV8825 DIR
GPIO[10] -> DRV8825 ENABLE_N / nENBL
```

Switches:

- `SW[17]`: master stepper enable.
- `SW[14]`: enable FPGA automatic platform tracking.
- `SW[13]`: direction level that means "move platform right"; flip this if left/right motion is reversed.
- `SW[16]`: manual direction when `SW[14]=0`.
- `SW[15]`: manual continuous stepping when `SW[14]=0`.
- `KEY[2]`: manual one-key move when `SW[14]=0`.

The FPGA automatic platform tracker uses the same rule as the Python prototype:

```text
K0 K1 K2 K3 K4
-2 -1  0 +1 +2

local_center_sum = local_75Hz + local_45Hz

if local_center_sum <= -2: move left  one key = 100 steps
if local_center_sum >= +2: move right one key = 100 steps
otherwise: stay
```

The platform center starts at global key `12` and is clamped to global keys `2..12`. The step generator is set to `800 steps/s`, `100 steps` per one-key move, and a `5 us` STEP high pulse.
