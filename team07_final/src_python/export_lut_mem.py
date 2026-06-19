#!/usr/bin/env python3
import argparse
import csv
import math
import sys


def parse_args():
    parser = argparse.ArgumentParser(
        description="Export collect_h2_lut.py CSV data to FPGA $readmemh ROM format."
    )
    parser.add_argument("csv_path", help="Input LUT CSV.")
    parser.add_argument("mem_path", help="Output .mem file.")
    parser.add_argument("--frequency", required=True, choices=["75", "45"])
    parser.add_argument(
        "--sensor-count",
        type=int,
        default=3,
        choices=[3],
        help="Hardware classifier currently supports the three-sensor FPGA build.",
    )
    return parser.parse_args()


def row_int(row, name):
    value = row.get(name, "")
    if value == "":
        raise ValueError(f"missing {name}")
    return int(float(value))


def ratio_from_row(row, index, values, total):
    field_name = f"f{index}"
    try:
        value = row.get(field_name, "")
        if value != "":
            return float(value)
    except (TypeError, ValueError):
        pass

    if total <= 0:
        return 0.0
    return values[index - 1] / total


def clamp_u32(value):
    return max(0, min(0xFFFFFFFF, int(value)))


def ratio_to_q30(value):
    return clamp_u32(round(value * (1 << 30)))


def ln_total_to_q16(total):
    return clamp_u32(round(math.log(max(float(total), 1.0)) * (1 << 16)))


def main() -> int:
    args = parse_args()
    words = []

    with open(args.csv_path, newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            if str(row.get("frequency_hz", "")).strip() != args.frequency:
                continue
            if int(row.get("sensor_count", "0")) != args.sensor_count:
                continue

            key_id = row_int(row, "key_id")
            h2_s1 = row_int(row, "h2_s1_q16")
            h2_s2 = row_int(row, "h2_s2_q16")
            h2_s3 = row_int(row, "h2_s3_q16")
            try:
                h2_total = row_int(row, "h2_total_q16")
            except ValueError:
                h2_total = h2_s1 + h2_s2 + h2_s3

            if not 0 <= key_id <= 15:
                raise ValueError(f"key_id out of range: {key_id}")

            raw_values = [h2_s1, h2_s2, h2_s3]
            for name, value in (
                ("h2_s1_q16", h2_s1),
                ("h2_s2_q16", h2_s2),
                ("h2_s3_q16", h2_s3),
                ("h2_total_q16", h2_total),
            ):
                if not 0 <= value <= 0xFFFFFFFF:
                    raise ValueError(f"{name} out of 32-bit range: {value}")

            f1_q30 = ratio_to_q30(ratio_from_row(row, 1, raw_values, h2_total))
            f2_q30 = ratio_to_q30(ratio_from_row(row, 2, raw_values, h2_total))
            f3_q30 = ratio_to_q30(ratio_from_row(row, 3, raw_values, h2_total))
            ln_total_q16 = ln_total_to_q16(h2_total)

            # 160-bit word:
            # [159:156] key_id, [155:128] reserved,
            # [127:96] f1_q30, [95:64] f2_q30, [63:32] f3_q30,
            # [31:0] ln(total_h2_q16)_q16.
            words.append(
                f"{key_id:X}{0:07X}"
                f"{f1_q30:08X}{f2_q30:08X}{f3_q30:08X}{ln_total_q16:08X}"
            )

    if not words:
        print(
            f"No {args.sensor_count}-sensor {args.frequency} Hz rows found in {args.csv_path}",
            file=sys.stderr,
        )
        return 2

    with open(args.mem_path, "w", encoding="utf-8") as mem_file:
        for word in words:
            mem_file.write(f"{word}\n")

    print(f"Wrote {len(words)} LUT entries to {args.mem_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
