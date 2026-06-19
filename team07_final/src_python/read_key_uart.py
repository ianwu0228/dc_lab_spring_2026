#!/usr/bin/env python3
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    print("Missing dependency: pyserial. Install with: pip install pyserial", file=sys.stderr)
    raise


KEY_RE = re.compile(r"^KEY,75,([0-9]{2}),([01]),45,([0-9]{2}),([01])$")


def parse_notes(notes_text):
    if not notes_text:
        return None

    notes = [note.strip() for note in notes_text.split(",")]
    if not 1 <= len(notes) <= 15 or any(not note for note in notes):
        raise ValueError("--notes must contain 1 to 15 comma-separated note names")
    return notes


def format_note(notes, key_index):
    if notes is None:
        return "--"
    if 0 <= key_index < len(notes):
        return notes[key_index]
    return "OUT"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read FPGA KEY UART frames and optionally map key indices to notes."
    )
    parser.add_argument("port", help="Serial port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument("--baud", "-baud", type=int, default=115200)
    parser.add_argument(
        "--notes",
        help=(
            "Comma-separated note names for global keys starting at 0. "
            "Example: F3,G3,A3,B3,C4,D4,E4,F4,G4,A4,B4,C5,D5,E5"
        ),
    )
    parser.add_argument("--print-hz", type=float, default=20.0)
    args = parser.parse_args()

    try:
        notes = parse_notes(args.notes)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2

    print(f"Reading FPGA key frames from {args.port} at {args.baud} baud.")
    print("Expected frame: KEY,75,xx,p75,45,yy,p45")
    if notes:
        print("Mapping global keys 0..14 to notes:")
        print(", ".join(f"{index}:{note}" for index, note in enumerate(notes)))
    print("Press Ctrl-C to stop.")

    print_period = 1.0 / args.print_hz if args.print_hz > 0 else 0.0
    last_print = 0.0

    try:
        with serial.Serial(args.port, args.baud, timeout=1) as ser:
            while True:
                data = ser.readline()
                if not data:
                    continue

                line = data.decode("ascii", errors="replace").strip()
                match = KEY_RE.match(line)
                if not match:
                    continue

                key75 = int(match.group(1))
                press75 = int(match.group(2))
                key45 = int(match.group(3))
                press45 = int(match.group(4))

                now = time.time()
                if now - last_print >= print_period:
                    print(
                        f"75Hz key={key75:02d} press={press75} "
                        f"note={format_note(notes, key75):>4s} | "
                        f"45Hz key={key45:02d} press={press45} "
                        f"note={format_note(notes, key45):>4s}"
                    )
                    last_print = now

    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
