#!/usr/bin/env python3
import argparse
import csv
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
            h2_total = row_int(row, "h2_total_q16")

            if not 0 <= key_id <= 15:
                raise ValueError(f"key_id out of range: {key_id}")

            for name, value in (
                ("h2_s1_q16", h2_s1),
                ("h2_s2_q16", h2_s2),
                ("h2_s3_q16", h2_s3),
                ("h2_total_q16", h2_total),
            ):
                if not 0 <= value <= 0xFFFFFFFF:
                    raise ValueError(f"{name} out of 32-bit range: {value}")

            # 160-bit word:
            # [159:156] key_id, [155:128] reserved,
            # [127:96] S1, [95:64] S2, [63:32] S3, [31:0] total.
            words.append(
                f"{key_id:X}{0:07X}"
                f"{h2_s1:08X}{h2_s2:08X}{h2_s3:08X}{h2_total:08X}"
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
