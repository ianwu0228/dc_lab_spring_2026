#!/usr/bin/env python3
import argparse
import csv
import math
import re
import sys
import time
from collections import deque

try:
    import serial
except ImportError:
    print("Missing dependency: pyserial. Install with: pip install pyserial", file=sys.stderr)
    raise


HEX32_RE = re.compile(r"^[0-9A-Fa-f]{8}$")


def parse_h2_line(line: str):
    parts = line.split(",")
    if len(parts) not in (9, 11):
        return None
    if parts[0] != "H2" or parts[1] != "75":
        return None

    try:
        freq45_index = parts.index("45", 2)
    except ValueError:
        return None

    h75_hex = parts[2:freq45_index]
    h45_hex = parts[freq45_index + 1:]
    sensor_count = len(h75_hex)

    if sensor_count not in (3, 4) or len(h45_hex) != sensor_count:
        return None
    if not all(HEX32_RE.match(value) for value in h75_hex + h45_hex):
        return None

    return {
        "75": [int(value, 16) for value in h75_hex],
        "45": [int(value, 16) for value in h45_hex],
        "sensor_count": sensor_count,
    }


def read_h2_frame(ser):
    while True:
        data = ser.readline()
        if not data:
            continue

        line = data.decode("ascii", errors="replace").strip()
        if not line:
            continue

        parsed = parse_h2_line(line)
        if parsed is not None:
            return parsed


def ratios_from_h2(values):
    total = sum(values)
    if total <= 0:
        return [0.0 for _ in values], 0.0
    return [value / total for value in values], total


def average_samples(samples):
    if not samples:
        return []
    sensor_count = len(samples[0])
    return [
        sum(sample[index] for sample in samples) / len(samples)
        for index in range(sensor_count)
    ]


def infer_sensor_count(row):
    try:
        sensor_count = int(row.get("sensor_count", ""))
        if sensor_count in (3, 4):
            return sensor_count
    except (TypeError, ValueError):
        pass

    s4_value = str(row.get("h2_s4_q16", "")).strip()
    return 4 if s4_value else 3


def infer_z_layer(row):
    try:
        z_layer_id = int(row.get("z_layer_id", ""))
    except (TypeError, ValueError):
        z_layer_id = 0

    z_layer_name = row.get("z_layer_name", "")
    if not z_layer_name:
        z_layer_name = "press" if z_layer_id == 0 else f"z{z_layer_id}"

    return z_layer_id, z_layer_name


def load_lut(path, frequency):
    entries = []
    with open(path, newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            if str(row.get("frequency_hz", "")).strip() != str(frequency):
                continue

            sensor_count = infer_sensor_count(row)
            z_layer_id, z_layer_name = infer_z_layer(row)
            h2 = [
                float(row[f"h2_s{index}_q16"])
                for index in range(1, sensor_count + 1)
            ]
            ratios, total = ratios_from_h2(h2)

            try:
                ratios = [float(row[f"f{i}"]) for i in range(1, sensor_count + 1)]
            except (KeyError, TypeError, ValueError):
                pass

            try:
                total = float(row["h2_total_q16"])
            except (KeyError, TypeError, ValueError):
                pass

            entries.append(
                {
                    "key_id": int(row["key_id"]),
                    "key_name": row.get("key_name", str(row["key_id"])),
                    "position_label": row.get("position_label", ""),
                    "z_layer_id": z_layer_id,
                    "z_layer_name": z_layer_name,
                    "sensor_count": sensor_count,
                    "ratios": ratios,
                    "total_q16": max(total, 1.0),
                }
            )

    if not entries:
        raise ValueError(f"No LUT entries for {frequency} Hz in {path}")

    return entries


def score_entry(ratios, total_q16, entry, strength_weight):
    ratio_error = sum(
        (ratios[index] - entry["ratios"][index]) ** 2
        for index in range(len(ratios))
    )

    if strength_weight <= 0:
        return ratio_error

    strength_error = (
        math.log(max(total_q16, 1.0)) - math.log(entry["total_q16"])
    ) ** 2
    return ratio_error + strength_weight * strength_error


def combine_key_errors(errors, key_score_mode):
    if key_score_mode == "sum":
        return sum(errors)
    if key_score_mode == "min":
        return min(errors)
    raise ValueError(f"Unsupported key score mode: {key_score_mode}")


def parse_z_layers(z_layers_text):
    layers = []
    for part in z_layers_text.split(","):
        part = part.strip()
        if not part:
            continue
        layers.append(int(part))

    if not layers:
        raise ValueError("--z-layers must include at least one layer id")

    return set(layers)


def classify(values, entries, strength_weight, key_score_mode="min", z_layers=None):
    if z_layers is None:
        z_layers = {0}

    matching_entries = [
        entry for entry in entries
        if entry["sensor_count"] == len(values)
        and entry["z_layer_id"] in z_layers
    ]
    if not matching_entries:
        raise ValueError(
            f"LUT has no entries for {len(values)}-sensor frames "
            f"and z layers {sorted(z_layers)}. Collect a matching LUT "
            "or use matching --z-layers/FPGA sensor mode."
        )

    ratios, total_q16 = ratios_from_h2(values)
    key_groups = {}
    for entry in matching_entries:
        key_groups.setdefault(entry["key_id"], []).append(entry)

    scored = []
    for key_id, key_entries in key_groups.items():
        entry_errors = [
            (score_entry(ratios, total_q16, entry, strength_weight), entry)
            for entry in key_entries
        ]
        entry_errors.sort(key=lambda item: item[0])
        key_score = combine_key_errors(
            [error for error, _entry in entry_errors],
            key_score_mode,
        )
        representative_entry = entry_errors[0][1]
        scored.append((key_score, representative_entry, entry_errors))

    scored.sort(key=lambda item: item[0])

    best_score, best_entry, best_entry_errors = scored[0]
    second_score = scored[1][0] if len(scored) > 1 else float("inf")
    margin = second_score - best_score

    return {
        "key_id": best_entry["key_id"],
        "key_name": best_entry["key_name"],
        "position_label": best_entry["position_label"],
        "z_layer_id": best_entry["z_layer_id"],
        "z_layer_name": best_entry["z_layer_name"],
        "score": best_score,
        "nearest_sample_score": best_entry_errors[0][0],
        "second_score": second_score,
        "margin": margin,
        "ratios": ratios,
        "total_q16": total_q16,
        "h2_g2": [value / 65536.0 for value in values],
        "total_g2": total_q16 / 65536.0,
        "key_score_mode": key_score_mode,
    }


def format_series(values, precision):
    return ",".join(f"{value:.{precision}f}" for value in values)


def resolve_lut_path(args, frequency):
    if frequency == "75" and args.lut_75:
        return args.lut_75
    if frequency == "45" and args.lut_45:
        return args.lut_45
    if args.lut:
        return args.lut
    raise ValueError(
        f"No LUT path provided for {frequency} Hz. "
        "Use --lut for a combined LUT or --lut-75/--lut-45 for separate LUTs."
    )


def stable_label(result, key_history, stable_count, min_total_g2):
    if result["total_g2"] < min_total_g2:
        key_history.clear()
        return "NO_SIGNAL"

    key_history.append(result["key_id"])
    if (
        len(key_history) == stable_count
        and all(key == result["key_id"] for key in key_history)
    ):
        return result["key_name"]

    return "..."


def format_result_line(frequency, result, stable_text):
    return (
        f"{frequency}Hz "
        f"key={result['key_name']:>4s} "
        f"stable={stable_text:>8s} "
        f"z={result['z_layer_name']:<9s} "
        f"pos={result['position_label']:<8s} "
        f"score={result['score']:.6g} "
        f"near={result['nearest_sample_score']:.6g} "
        f"margin={result['margin']:.6g} "
        f"H2=[{format_series(result['h2_g2'], 4)}] "
        f"F=[{format_series(result['ratios'], 3)}]"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Classify live FPGA H2 frames using a collected magnetic-key LUT."
    )
    parser.add_argument("port", help="Serial port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument(
        "--lut",
        help="CSV generated by collect_h2_lut.py. Can be used for one frequency or a combined LUT.",
    )
    parser.add_argument("--lut-75", help="Optional 75 Hz LUT CSV.")
    parser.add_argument("--lut-45", help="Optional 45 Hz LUT CSV.")
    parser.add_argument("--baud", "-baud", type=int, default=115200)
    parser.add_argument("--frequency", choices=["75", "45", "both"], default="75")
    parser.add_argument(
        "--average",
        type=int,
        default=10,
        help="Number of recent H2 frames averaged before classification.",
    )
    parser.add_argument(
        "--print-hz",
        type=float,
        default=10.0,
        help="Maximum terminal print rate.",
    )
    parser.add_argument(
        "--stable",
        type=int,
        default=3,
        help="Consecutive same-key classifications required before reporting stable key.",
    )
    parser.add_argument(
        "--strength-weight",
        type=float,
        default=0.05,
        help="Weight for log(total H2) error. Use 0 to classify only by normalized pattern.",
    )
    parser.add_argument(
        "--key-score",
        choices=["sum", "min"],
        default="min",
        help="How to combine per-sample errors into a per-key score.",
    )
    parser.add_argument(
        "--z-layers",
        default="0",
        help="Comma-separated z layer ids to use, e.g. 0 for press or 1,2 for hover.",
    )
    parser.add_argument(
        "--min-total-g2",
        type=float,
        default=0.0,
        help="Optional no-signal threshold in Gauss^2. Default disables thresholding.",
    )
    args = parser.parse_args()

    frequencies = ["75", "45"] if args.frequency == "both" else [args.frequency]
    z_layers = parse_z_layers(args.z_layers)
    entries_by_frequency = {}
    for frequency in frequencies:
        lut_path = resolve_lut_path(args, frequency)
        entries_by_frequency[frequency] = load_lut(lut_path, frequency)

    sample_windows = {
        frequency: deque(maxlen=max(1, args.average))
        for frequency in frequencies
    }
    key_histories = {
        frequency: deque(maxlen=max(1, args.stable))
        for frequency in frequencies
    }
    print_period = 1.0 / args.print_hz if args.print_hz > 0 else 0.0
    last_print = 0.0

    for frequency in frequencies:
        print(
            f"Loaded {len(entries_by_frequency[frequency])} LUT entries "
            f"for {frequency} Hz"
        )
    print(f"Classifying {', '.join(frequencies)} Hz H2 frames from {args.port}")
    print(f"Using z layers: {sorted(z_layers)}")
    print("Sensor count is auto-detected from live frames; LUT entries must match it.")
    print("Press Ctrl-C to stop.")

    try:
        with serial.Serial(args.port, args.baud, timeout=1) as ser:
            while True:
                frame = read_h2_frame(ser)

                for frequency in frequencies:
                    sample_windows[frequency].append(frame[frequency])

                if any(
                    len(sample_windows[frequency]) < sample_windows[frequency].maxlen
                    for frequency in frequencies
                ):
                    continue

                results = {}
                stable_texts = {}
                for frequency in frequencies:
                    values = average_samples(sample_windows[frequency])
                    result = classify(
                        values,
                        entries_by_frequency[frequency],
                        args.strength_weight,
                        args.key_score,
                        z_layers,
                    )
                    stable_text = stable_label(
                        result,
                        key_histories[frequency],
                        key_histories[frequency].maxlen,
                        args.min_total_g2,
                    )
                    results[frequency] = result
                    stable_texts[frequency] = stable_text

                now = time.time()
                if now - last_print >= print_period:
                    print(
                        " | ".join(
                            format_result_line(
                                frequency,
                                results[frequency],
                                stable_texts[frequency],
                            )
                            for frequency in frequencies
                        )
                    )
                    last_print = now

    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
