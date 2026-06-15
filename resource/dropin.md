# LUT Construction for Magnetic-Sensing Piano

## 1. Purpose of the LUT

The goal of the magnetic-sensing piano is not necessarily to compute an exact continuous 3D position for the first working demo. The more immediate goal is:

```text
magnetic sensor readings → which piano key is being pressed?
```

The lookup table (LUT) is used to learn the relationship between the measured magnetic pattern and the physical key region.

Instead of relying only on a theoretical magnetic-field equation, the LUT stores experimentally measured signatures from the real system. This is important because the real system includes many non-ideal effects:

- sensor-to-sensor offset mismatch
- sensor gain mismatch
- sensor axis misalignment
- imperfect sensor placement
- loose wires or breadboard parasitics
- nearby screws, wires, motor parts, or metal
- coil current variationV
- coil/magnet orientation variation
- temperature drift
- power-up offset differences
- environmental magnetic-field changes

Because of these effects, two physically identical theoretical setups may produce different real sensor values. The LUT lets the system learn the actual behavior of the hardware.

For the piano application, the LUT should initially map:

```text
calibrated magnetic feature → key_id
```

rather than:

```text
calibrated magnetic feature → exact x, y, z
```

This makes the first version much easier and more robust.

---

## 2. System Assumptions

For the LUT method described here, assume:

1. Four magnetometers are fixed in known positions.
2. The keyboard plate is fixed relative to the sensors.
3. The playing height is approximately fixed.
4. The magnetic source is one finger-worn coil or magnet.
5. The system only needs to detect one active key at a time for the first prototype.
6. Small y-direction movement is allowed.
7. The final output is `key_id` and `pressed/released`.

If the playing height, sensor board, or magnetic source changes significantly, the LUT may need to be rebuilt.

---

## 3. Raw Sensor Data

Each magnetometer gives a 3-axis magnetic-field vector:

```text
Sensor 1: B1_raw = (Bx1_raw, By1_raw, Bz1_raw)
Sensor 2: B2_raw = (Bx2_raw, By2_raw, Bz2_raw)
Sensor 3: B3_raw = (Bx3_raw, By3_raw, Bz3_raw)
Sensor 4: B4_raw = (Bx4_raw, By4_raw, Bz4_raw)
```

These raw values include:

```text
Earth magnetic field
+ sensor offset
+ static board/environment magnetic effects
+ useful magnetic source signal
+ noise
```

So the raw values should not be used directly for the LUT.

---

## 4. Startup Baseline Calibration

At every system startup, perform baseline calibration.

### Procedure

1. Power on the FPGA and magnetometers.
2. Wait for readings to stabilize, for example 1–3 seconds.
3. Make sure the finger coil/magnet is away from the sensing area.
4. Record 200–500 samples from each sensor.
5. Average each axis for each sensor.
6. Store the averaged values as the baseline.

For sensor `i`:

```text
Bxi_base = average(Bxi_raw)
Byi_base = average(Byi_raw)
Bzi_base = average(Bzi_raw)
```

During operation:

```text
Bxi = Bxi_raw - Bxi_base
Byi = Byi_raw - Byi_base
Bzi = Bzi_raw - Bzi_base
```

After this subtraction, the remaining signal should mostly represent the magnetic field from the finger coil/magnet.

### Important distinction

Baseline calibration and LUT construction are different:

```text
Baseline calibration: run every startup
LUT construction: run only when hardware geometry changes
```

---

## 5. Magnetic Intensity Computation

After baseline subtraction, each sensor has a calibrated vector:

```text
Bi = (Bxi, Byi, Bzi)
```

Convert this vector into magnetic intensity squared:

```text
Mi = Bxi^2 + Byi^2 + Bzi^2
```

So for four sensors:

```text
M1 = Bx1^2 + By1^2 + Bz1^2
M2 = Bx2^2 + By2^2 + Bz2^2
M3 = Bx3^2 + By3^2 + Bz3^2
M4 = Bx4^2 + By4^2 + Bz4^2
```

Use `M_i` instead of `sqrt(M_i)` because:

1. Square root is unnecessary for classification.
2. FPGA can compute squared intensity more easily.
3. The squared norm still preserves the relative strength information.
4. Many magnetic models naturally involve field-strength squared.

---

## 6. Total Strength

Compute:

```text
M_total = M1 + M2 + M3 + M4
```

`M_total` represents the overall magnetic strength seen by the whole sensor array.

Use `M_total` mainly for:

```text
pressed / not pressed detection
```

For example:

```text
if M_total > press_threshold:
    the finger/magnet is close enough to be considered active

if M_total < release_threshold:
    the key is released
```

Use hysteresis:

```text
press_threshold > release_threshold
```

Example:

```text
press_threshold   = 8000
release_threshold = 5000
```

This prevents flickering when the signal is near the boundary.

---

## 7. Normalized Magnetic Pattern

Absolute values `M1, M2, M3, M4` may change due to coil strength, current drift, height variation, or sensor gain changes. To reduce sensitivity to absolute amplitude, compute normalized features:

```text
F1 = M1 / M_total
F2 = M2 / M_total
F3 = M3 / M_total
F4 = M4 / M_total
```

The vector:

```text
F = [F1, F2, F3, F4]
```

describes the relative distribution of magnetic strength among the four sensors.

This pattern helps identify where the magnetic source is located.

For example:

```text
Key C might produce: F = [0.65, 0.18, 0.11, 0.06]
Key D might produce: F = [0.48, 0.35, 0.11, 0.06]
Key E might produce: F = [0.30, 0.52, 0.11, 0.07]
```

The key is differentiated by the pattern, not only by the total strength.

---

## 8. Why F Alone Is Not Enough

Using only `F1~F4` can cause ambiguity.

Example:

```text
Key A:
M = [1000, 500, 300, 200]
M_total = 2000
F = [0.50, 0.25, 0.15, 0.10]

Key B:
M = [2000, 1000, 600, 400]
M_total = 4000
F = [0.50, 0.25, 0.15, 0.10]
```

These two cases have the same normalized feature but different total strength.

Therefore, the LUT should use both:

```text
F1, F2, F3, F4
```

and:

```text
M_total or log(M_total)
```

A good feature vector is:

```text
feature = [F1, F2, F3, F4, log(M_total)]
```

For classification:

- `F1~F4` are the main key identity features.
- `M_total` or `log(M_total)` is an auxiliary feature.
- `M_total` is also used for pressed/released detection.

---

## 9. Why Use log(M_total)?

Magnetic strength changes very rapidly with distance. If raw `M_total` is used directly, large values can dominate the error calculation.

Using:

```text
G = log(M_total)
```

compresses the dynamic range and makes comparison more balanced.

The LUT entry can store:

```text
key_id
x_label
y_label
F1_avg
F2_avg
F3_avg
F4_avg
log_M_total_avg
```

---

## 10. LUT Construction with Fixed Height and Small Y Movement

Because the playing height is fixed but the finger may move slightly in the y direction, each key should be represented as a small 2D region.

Do not collect only one point per key.

For each key, collect samples at multiple x and y positions.

Recommended first LUT grid per key:

```text
x positions: left, center, right
y positions: front, middle, back
```

This gives:

```text
3 × 3 = 9 LUT entries per key
```

If there are 8 keys:

```text
8 keys × 9 entries/key = 72 LUT entries
```

This is still small and easy to handle in Python or FPGA.

---

## 11. Example LUT Layout

For one key, such as C:

```text
C-left-front
C-center-front
C-right-front

C-left-middle
C-center-middle
C-right-middle

C-left-back
C-center-back
C-right-back
```

All nine entries have the same `key_id = C`, but they represent different allowed positions within the key area.

Example table:

```text
key_id, x_label, y_label, F1, F2, F3, F4, log_M_total

C, left,   front,  0.70, 0.14, 0.11, 0.05, 9.10
C, center, front,  0.62, 0.22, 0.11, 0.05, 9.20
C, right,  front,  0.52, 0.32, 0.11, 0.05, 9.18

C, left,   middle, 0.68, 0.16, 0.11, 0.05, 9.30
C, center, middle, 0.60, 0.24, 0.11, 0.05, 9.40
C, right,  middle, 0.50, 0.34, 0.11, 0.05, 9.36

C, left,   back,   0.65, 0.18, 0.12, 0.05, 9.12
C, center, back,   0.57, 0.26, 0.12, 0.05, 9.21
C, right,  back,   0.47, 0.37, 0.11, 0.05, 9.17
```

Repeat this for all keys.

---

## 12. Detailed Initial LUT Collection Procedure

### Step 1: Fix the hardware

Before recording LUT data:

- solder or secure the sensor wiring
- avoid loose breadboard connections
- fix the four sensors in their final positions
- fix the keyboard plate relative to the sensor board
- fix the playing height
- keep the magnetic source orientation as consistent as possible
- keep motors, steel screws, and high-current wires away from the sensing region

The LUT learns the physical geometry. If the geometry changes later, the LUT may become invalid.

---

### Step 2: Run baseline calibration

1. Remove the magnetic source from the sensing area.
2. Record 200–500 samples.
3. Average each sensor axis.
4. Store the baseline.
5. All later readings should use baseline-subtracted values.

---

### Step 3: Choose key positions

For each key, define 9 collection points:

```text
left-front
center-front
right-front
left-middle
center-middle
right-middle
left-back
center-back
right-back
```

If y movement is very small, a 3×3 grid is enough.

If y movement is larger, use more y positions:

```text
front
front-middle
middle
back-middle
back
```

This would give a 3×5 grid per key.

---

### Step 4: Record data at each point

At each point:

1. Place the magnetic source at the target position.
2. Keep the height fixed.
3. Keep the source orientation fixed.
4. Wait briefly for the signal to stabilize.
5. Record 100–300 samples.
6. For each sample, compute:
   - `M1, M2, M3, M4`
   - `M_total`
   - `F1, F2, F3, F4`
   - `log(M_total)`
7. Average the features.
8. Store one LUT entry.

For each LUT entry, store:

```text
key_id
x_label
y_label
F1_avg
F2_avg
F3_avg
F4_avg
log_M_total_avg
optional: F1_std, F2_std, F3_std, F4_std, log_M_total_std
```

The standard deviation values are useful for later reliability analysis.

---

## 13. Runtime Classification

At runtime, the system receives current sensor readings.

### Step 1: Compute calibrated intensity

```text
M1, M2, M3, M4
```

### Step 2: Compute total strength

```text
M_total = M1 + M2 + M3 + M4
```

### Step 3: Check pressed/released

```text
if M_total < release_threshold:
    no key pressed
```

If:

```text
M_total > press_threshold
```

then continue to key classification.

### Step 4: Compute current feature

```text
F1 = M1 / M_total
F2 = M2 / M_total
F3 = M3 / M_total
F4 = M4 / M_total
G  = log(M_total)
```

The current feature is:

```text
feature_now = [F1, F2, F3, F4, G]
```

### Step 5: Compare with LUT

For each LUT entry, compute an error.

Recommended form:

```text
ratio_error =
(F1_now - F1_LUT)^2
+ (F2_now - F2_LUT)^2
+ (F3_now - F3_LUT)^2
+ (F4_now - F4_LUT)^2
```

```text
strength_error =
(G_now - G_LUT)^2
```

```text
total_error =
wF * ratio_error + wG * strength_error
```

A good initial setting is:

```text
wF = 1.0
wG = 0.1 to 0.3
```

This means the normalized magnetic pattern is the main classifier, while total strength helps resolve ambiguity.

### Step 6: Choose key

There are two ways.

#### Method A: nearest LUT entry

Find the LUT entry with the smallest error.

```text
detected_key = key_id of closest LUT entry
```

This is simplest.

#### Method B: key-level nearest match

For each key, find the best entry belonging to that key:

```text
C_error = minimum error among all C entries
D_error = minimum error among all D entries
E_error = minimum error among all E entries
...
```

Then choose the key with the smallest key-level error.

This is usually better, because each key is represented by many allowed x-y positions.

---

## 14. Temporal Smoothing

Magnetic readings can flicker near key boundaries. Add temporal smoothing.

Recommended rule:

```text
Only trigger a key if the same key is detected for 3–5 consecutive frames.
```

Example:

```text
Frame 1: D
Frame 2: D
Frame 3: D
→ trigger D
```

If the classifier alternates:

```text
D, E, D, E
```

then do not trigger until the result stabilizes.

Also add release hysteresis:

```text
press_threshold > release_threshold
```

This prevents repeated false note triggering.

---

## 15. How to Check If the LUT Is Good

After recording the LUT, verify cluster separation.

### Same-key variation

Repeated measurements within the same key should be close.

```text
C-left-front should be close to other C entries
D-center-middle should be close to other D entries
```

### Different-key separation

Different keys should be clearly separated.

```text
C entries should be closer to C than to D
D entries should be closer to D than to C or E
```

A useful test:

```text
For each LUT entry:
    remove it temporarily
    classify it using the remaining LUT
    check whether the predicted key matches the true key
```

If many entries are misclassified, the LUT is not reliable yet.

---

## 16. What If Two Keys Are Ambiguous?

If two keys have similar `F1~F4` and similar `M_total`, software cannot reliably separate them.

Possible fixes:

1. Move sensors closer to the playing surface.
2. Increase spacing between sensors.
3. Add y-direction sensor spread if y variation is important.
4. Make one sensor non-coplanar.
5. Increase magnetic source strength.
6. Fix the source orientation more rigidly.
7. Increase key spacing.
8. Reduce allowed y movement with a physical guide.
9. Add one more sensor.
10. Improve signal extraction using AC filtering or lock-in detection.

The LUT can only classify differences that are present in the measurements.

---

## 17. Do We Need to Rebuild the LUT Every Time?

Usually, no.

Every time the system powers on:

```text
run baseline calibration
```

But the LUT only needs to be rebuilt when the hardware or sensing condition changes significantly.

### Reuse the same LUT if these remain fixed:

- sensor positions
- keyboard plate position
- playing height
- magnetic source shape
- magnetic source orientation
- coil drive frequency
- coil current amplitude approximately
- filtering algorithm
- sensor configuration
- wiring and mechanical environment

### Rebuild the LUT if any of these change:

- sensors are moved
- keyboard plate is moved
- playing height changes
- coil/magnet is redesigned
- coil current amplitude changes a lot
- coil frequency changes
- filtering method changes
- one sensor is replaced
- breadboard wiring is replaced by soldered wiring and the magnetic environment changes
- metal parts are added near the sensors
- sensor board is redesigned

In the final system:

```text
baseline calibration = every startup
LUT construction = only after hardware/geometry change
```

During development, because hardware is still changing, the LUT will probably need to be rebuilt several times. After mechanical and electrical design are fixed, it should be reusable.

---

## 18. Recommended First LUT Size

For the first working prototype:

```text
8 keys
3 x positions per key
3 y positions per key
100–300 samples per point
```

This gives:

```text
8 × 3 × 3 = 72 LUT entries
```

This is a good balance between accuracy and data collection effort.

If the system is stable, this should be enough for a first piano demo.

If adjacent keys flicker, increase density:

```text
5 x positions × 3 y positions per key
```

or:

```text
3 x positions × 5 y positions per key
```

---

## 19. Suggested CSV Format

Use a CSV file like this:

```text
key_id,x_label,y_label,F1,F2,F3,F4,log_M_total,M_total_avg,M_total_std
C,left,front,0.70,0.14,0.11,0.05,9.10,8950,420
C,center,front,0.62,0.22,0.11,0.05,9.20,9900,390
C,right,front,0.52,0.32,0.11,0.05,9.18,9700,410
...
```

Optional extra fields:

```text
sample_count
timestamp
coil_frequency
sensor_layout_version
keyboard_version
height_mm
```

These help track which LUT belongs to which hardware setup.

---

## 20. Final Recommended Pipeline

### LUT construction mode

```text
1. Power on system.
2. Wait for sensors to stabilize.
3. Remove magnetic source.
4. Run baseline calibration.
5. For each key:
       for each x position:
           for each y position:
               place source at known point
               record samples
               compute averaged feature
               save LUT entry
6. Save LUT as CSV.
```

### Runtime mode

```text
1. Power on system.
2. Wait for sensors to stabilize.
3. Remove magnetic source.
4. Run baseline calibration.
5. Load saved LUT.
6. Continuously read M1~M4.
7. Use M_total to detect press/release.
8. If pressed:
       compute [F1,F2,F3,F4,log(M_total)]
       compare with LUT
       choose key with minimum key-level error
       apply temporal smoothing
       output note
9. If released:
       stop note or allow next trigger
```

---

## 21. Summary

The LUT is needed because the real magnetic system is not ideal enough to rely only on a clean theoretical equation. It learns the actual magnetic signature of each key region.

The LUT should not use raw sensor values. It should use:

```text
F1, F2, F3, F4, log(M_total)
```

where:

```text
Fi = Mi / (M1 + M2 + M3 + M4)
```

and:

```text
Mi = Bxi^2 + Byi^2 + Bzi^2
```

For fixed height and small y movement, construct a small 2D LUT for each key:

```text
3 x positions × 3 y positions = 9 entries per key
```

At runtime:

```text
M_total detects pressed/released
F1~F4 classify the key
log(M_total) helps resolve ambiguity
temporal smoothing prevents flicker
```

You do not rebuild the LUT every time. You only run baseline calibration every startup. Rebuild the LUT only when the geometry, magnetic source, sensor configuration, or filtering method changes.
