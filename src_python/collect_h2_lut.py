#!/usr/bin/env python3
import argparse
import csv
import re
import statistics
import sys
import time

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
        "raw_line": line,
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


def collect_samples(ser, frequency: str, sample_count: int, settle_seconds: float):
    deadline = time.time() + settle_seconds
    while time.time() < deadline:
        read_h2_frame(ser)

    samples = []
    while len(samples) < sample_count:
        frame = read_h2_frame(ser)
        samples.append(frame[frequency])
        if len(samples) % max(1, sample_count // 10) == 0:
            print(f"  collected {len(samples)}/{sample_count}", end="\r", flush=True)

    print(f"  collected {sample_count}/{sample_count}")
    return samples


def summarize_samples(samples):
    sensor_count = len(samples[0])
    columns = [[sample[i] for sample in samples] for i in range(sensor_count)]
    means_q16 = [sum(col) / len(col) for col in columns]
    std_q16 = [
        statistics.pstdev(col) if len(col) > 1 else 0.0
        for col in columns
    ]
    total_q16 = sum(means_q16)

    if total_q16 > 0:
        ratios = [value / total_q16 for value in means_q16]
    else:
        ratios = [0.0 for _ in range(sensor_count)]

    return {
        "h2_mean_q16": means_q16,
        "h2_std_q16": std_q16,
        "h2_total_q16": total_q16,
        "ratios": ratios,
        "h2_mean_g2": [value / 65536.0 for value in means_q16],
        "h2_total_g2": total_q16 / 65536.0,
    }


def default_key_names(count: int):
    return [f"K{i}" for i in range(count)]


def build_positions():
    # Key dimensions are 2 cm x 4 cm. These coordinates are local to each key:
    # x is across the key width, y is from front/player side toward the back.
    return [
        ("left-front", -0.7, 0.7),
        ("center-front", 0.0, 0.7),
        ("right-front", 0.7, 0.7),
        ("left-middle", -0.7, 2.0),
        ("center-middle", 0.0, 2.0),
        ("right-middle", 0.7, 2.0),
        ("left-back", -0.7, 3.3),
        ("center-back", 0.0, 3.3),
        ("right-back", 0.7, 3.3),
    ]


def write_header(writer):
    writer.writeheader()


def sensor_list_text(values, fmt):
    return " ".join(
        f"S{index + 1}={format(value, fmt)}"
        for index, value in enumerate(values)
    )


def padded_value(values, index, default=""):
    return values[index] if index < len(values) else default


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Guided LUT collection for FPGA H2 magnetic key detection."
    )
    parser.add_argument("port", help="Serial port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument("--baud", "-baud", type=int, default=115200)
    parser.add_argument("--frequency", choices=["75", "45"], default="75")
    parser.add_argument("--output", default="h2_key_lut.csv")
    parser.add_argument("--samples", type=int, default=200)
    parser.add_argument("--settle", type=float, default=0.2)
    parser.add_argument("--keys", type=int, default=5)
    parser.add_argument(
        "--key-names",
        help="Comma-separated key labels. Example: C,D,E,F,G",
    )
    parser.add_argument(
        "--accept-all",
        action="store_true",
        help="Save each entry without asking for confirmation.",
    )
    args = parser.parse_args()

    if args.key_names:
        key_names = [name.strip() for name in args.key_names.split(",") if name.strip()]
        if len(key_names) != args.keys:
            print("--key-names length must match --keys", file=sys.stderr)
            return 2
    else:
        key_names = default_key_names(args.keys)

    positions = build_positions()
    total_entries = len(key_names) * len(positions)

    fieldnames = [
        "entry_index",
        "key_id",
        "key_name",
        "position_label",
        "local_x_cm",
        "local_y_cm",
        "frequency_hz",
        "sample_count",
        "sensor_count",
        "h2_s1_q16",
        "h2_s2_q16",
        "h2_s3_q16",
        "h2_s4_q16",
        "h2_total_q16",
        "f1",
        "f2",
        "f3",
        "f4",
        "h2_s1_g2",
        "h2_s2_g2",
        "h2_s3_g2",
        "h2_s4_g2",
        "h2_total_g2",
        "std_s1_q16",
        "std_s2_q16",
        "std_s3_q16",
        "std_s4_q16",
    ]

    print("=== H2 LUT Collection ===")
    print(f"Frequency: {args.frequency} Hz")
    print(f"Keys: {', '.join(key_names)}")
    print(f"Grid: {len(positions)} positions/key, {total_entries} entries total")
    print(f"Samples/entry: {args.samples}")
    print("Sensor count: auto-detected from the FPGA UART frame, supports 3 or 4 sensors.")
    print()
    print("During each prompt, place the electromagnet at the requested point,")
    print("press the physical key fully down so height is fixed, then hold still.")
    print()

    entry_index = 0
    try:
        with serial.Serial(args.port, args.baud, timeout=1) as ser:
            print(f"Opened {args.port} at {args.baud} baud.")
            input("Press Enter once the FPGA H2 stream is running...")

            with open(args.output, "w", newline="", encoding="utf-8") as csv_file:
                writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
                write_header(writer)

                for key_id, key_name in enumerate(key_names):
                    for position_label, local_x_cm, local_y_cm in positions:
                        while True:
                            print()
                            print(f"Entry {entry_index + 1}/{total_entries}")
                            print(f"Key: {key_name} (id {key_id})")
                            print(f"Position: {position_label}")
                            print(f"Local coordinate: x={local_x_cm:+.1f} cm, y={local_y_cm:.1f} cm")
                            input("Place, press, hold still, then press Enter to collect...")

                            samples = collect_samples(
                                ser,
                                args.frequency,
                                args.samples,
                                args.settle,
                            )
                            summary = summarize_samples(samples)

                            h2_q16 = summary["h2_mean_q16"]
                            h2_g2 = summary["h2_mean_g2"]
                            ratios = summary["ratios"]
                            std_q16 = summary["h2_std_q16"]

                            print(
                                "Mean H2 G^2: "
                                f"{sensor_list_text(h2_g2, '.6f')} "
                                f"total={summary['h2_total_g2']:.6f}"
                            )
                            print(
                                "Normalized F: "
                                f"[{', '.join(f'{ratio:.4f}' for ratio in ratios)}]"
                            )
                            print(
                                "Std Q16: "
                                f"[{', '.join(f'{std:.1f}' for std in std_q16)}]"
                            )

                            if args.accept_all:
                                accept = "y"
                            else:
                                accept = input("Accept this entry? [Y/n/r retry] ").strip().lower()

                            if accept in ("", "y", "yes"):
                                writer.writerow(
                                    {
                                        "entry_index": entry_index,
                                        "key_id": key_id,
                                        "key_name": key_name,
                                        "position_label": position_label,
                                        "local_x_cm": local_x_cm,
                                        "local_y_cm": local_y_cm,
                                        "frequency_hz": int(args.frequency),
                                        "sample_count": args.samples,
                                        "sensor_count": len(h2_q16),
                                        "h2_s1_q16": round(padded_value(h2_q16, 0, 0)),
                                        "h2_s2_q16": round(padded_value(h2_q16, 1, 0)),
                                        "h2_s3_q16": round(padded_value(h2_q16, 2, 0)),
                                        "h2_s4_q16": round(h2_q16[3]) if len(h2_q16) > 3 else "",
                                        "h2_total_q16": round(summary["h2_total_q16"]),
                                        "f1": padded_value(ratios, 0),
                                        "f2": padded_value(ratios, 1),
                                        "f3": padded_value(ratios, 2),
                                        "f4": padded_value(ratios, 3),
                                        "h2_s1_g2": padded_value(h2_g2, 0),
                                        "h2_s2_g2": padded_value(h2_g2, 1),
                                        "h2_s3_g2": padded_value(h2_g2, 2),
                                        "h2_s4_g2": padded_value(h2_g2, 3),
                                        "h2_total_g2": summary["h2_total_g2"],
                                        "std_s1_q16": padded_value(std_q16, 0),
                                        "std_s2_q16": padded_value(std_q16, 1),
                                        "std_s3_q16": padded_value(std_q16, 2),
                                        "std_s4_q16": padded_value(std_q16, 3),
                                    }
                                )
                                csv_file.flush()
                                entry_index += 1
                                print(f"Saved to {args.output}.")
                                break

                            if accept in ("r", "retry", "n", "no"):
                                print("Retrying this entry.")
                            else:
                                print("Unrecognized answer; retrying this entry.")

    except KeyboardInterrupt:
        print("\nStopped by user.")
        return 1

    print()
    print(f"Completed {entry_index} LUT entries.")
    print(f"Output: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
