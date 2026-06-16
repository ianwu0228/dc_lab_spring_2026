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


def load_lut(path, frequency):
    entries = []
    with open(path, newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            if str(row.get("frequency_hz", "")).strip() != str(frequency):
                continue

            sensor_count = infer_sensor_count(row)
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


def classify(values, entries, strength_weight):
    matching_entries = [
        entry for entry in entries
        if entry["sensor_count"] == len(values)
    ]
    if not matching_entries:
        raise ValueError(
            f"LUT has no entries for {len(values)}-sensor frames. "
            "Collect a matching LUT or use the matching FPGA sensor mode."
        )

    ratios, total_q16 = ratios_from_h2(values)
    scored = [
        (score_entry(ratios, total_q16, entry, strength_weight), entry)
        for entry in matching_entries
    ]
    scored.sort(key=lambda item: item[0])

    best_score, best_entry = scored[0]
    second_score = scored[1][0] if len(scored) > 1 else float("inf")
    margin = second_score - best_score

    return {
        "key_id": best_entry["key_id"],
        "key_name": best_entry["key_name"],
        "position_label": best_entry["position_label"],
        "score": best_score,
        "second_score": second_score,
        "margin": margin,
        "ratios": ratios,
        "total_q16": total_q16,
        "h2_g2": [value / 65536.0 for value in values],
        "total_g2": total_q16 / 65536.0,
    }


def format_series(values, precision):
    return ",".join(f"{value:.{precision}f}" for value in values)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Classify live FPGA H2 frames using a collected magnetic-key LUT."
    )
    parser.add_argument("port", help="Serial port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument("--lut", required=True, help="CSV generated by collect_h2_lut.py.")
    parser.add_argument("--baud", "-baud", type=int, default=115200)
    parser.add_argument("--frequency", choices=["75", "45"], default="75")
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
        "--min-total-g2",
        type=float,
        default=0.0,
        help="Optional no-signal threshold in Gauss^2. Default disables thresholding.",
    )
    args = parser.parse_args()

    entries = load_lut(args.lut, args.frequency)
    sample_window = deque(maxlen=max(1, args.average))
    key_history = deque(maxlen=max(1, args.stable))
    print_period = 1.0 / args.print_hz if args.print_hz > 0 else 0.0
    last_print = 0.0

    print(f"Loaded {len(entries)} LUT entries from {args.lut}")
    print(f"Classifying {args.frequency} Hz H2 frames from {args.port}")
    print("Sensor count is auto-detected from live frames; LUT entries must match it.")
    print("Press Ctrl-C to stop.")

    try:
        with serial.Serial(args.port, args.baud, timeout=1) as ser:
            while True:
                frame = read_h2_frame(ser)
                sample_window.append(frame[args.frequency])

                if len(sample_window) < sample_window.maxlen:
                    continue

                values = average_samples(sample_window)
                result = classify(values, entries, args.strength_weight)

                if result["total_g2"] < args.min_total_g2:
                    key_history.clear()
                    stable_text = "NO_SIGNAL"
                else:
                    key_history.append(result["key_id"])
                    if (
                        len(key_history) == key_history.maxlen
                        and all(key == result["key_id"] for key in key_history)
                    ):
                        stable_text = result["key_name"]
                    else:
                        stable_text = "..."

                now = time.time()
                if now - last_print >= print_period:
                    ratios = result["ratios"]
                    h2_g2 = result["h2_g2"]
                    print(
                        f"key={result['key_name']:>4s} "
                        f"stable={stable_text:>8s} "
                        f"pos={result['position_label']:<13s} "
                        f"score={result['score']:.6g} "
                        f"margin={result['margin']:.6g} "
                        f"H2=[{format_series(h2_g2, 4)}] "
                        f"F=[{format_series(ratios, 3)}]"
                    )
                    last_print = now

    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
