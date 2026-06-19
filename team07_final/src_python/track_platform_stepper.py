#!/usr/bin/env python3
import argparse
import sys
import time
from collections import deque

try:
    import serial
except ImportError:
    print("Missing dependency: pyserial. Install with: pip install pyserial", file=sys.stderr)
    raise

from classify_h2_lut import average_samples, classify, load_lut, parse_z_layers, read_h2_frame


def local_index_from_key_id(key_id, local_center_key_id):
    return key_id - local_center_key_id


def movement_from_center_sum(center_sum, left_threshold, right_threshold):
    if center_sum <= left_threshold:
        return -1
    if center_sum >= right_threshold:
        return 1
    return 0


def drain_serial_lines(ser, max_seconds):
    if ser is None or max_seconds <= 0:
        return

    deadline = time.time() + max_seconds
    while time.time() < deadline:
        line = ser.readline()
        if not line:
            continue
        text = line.decode("ascii", errors="replace").strip()
        if text:
            print(f"Arduino: {text}")


def send_step_command(arduino_ser, steps, enable_motor):
    command = f"s {steps}\n"
    if enable_motor:
        arduino_ser.write(command.encode("ascii"))
        arduino_ser.flush()
        print(f"Sent Arduino command: {command.strip()}")
    else:
        print(f"DRY RUN Arduino command: {command.strip()}")


def open_arduino(args):
    if not args.enable_motor:
        if args.arduino_port:
            print("Dry-run mode: Arduino port argument is ignored until --enable-motor is set.")
        return None

    if not args.arduino_port:
        print("arduino_port is required when --enable-motor is used.", file=sys.stderr)
        return None

    arduino_ser = serial.Serial(args.arduino_port, args.arduino_baud, timeout=0.05)
    print(f"Opened Arduino stepper port {args.arduino_port} at {args.arduino_baud} baud.")
    if args.arduino_ready_delay > 0:
        time.sleep(args.arduino_ready_delay)
        drain_serial_lines(arduino_ser, 0.2)
    return arduino_ser


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Track two magnetic fingers from FPGA H2 UART data and move a "
            "DRV8825 stepper platform through an Arduino serial command port."
        )
    )
    parser.add_argument("fpga_port", help="FPGA UART port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument(
        "arduino_port",
        nargs="?",
        help="Arduino serial port for stepper commands. Required with --enable-motor.",
    )
    parser.add_argument("--lut-75", required=True, help="75 Hz LUT CSV.")
    parser.add_argument("--lut-45", required=True, help="45 Hz LUT CSV.")
    parser.add_argument("--fpga-baud", type=int, default=115200)
    parser.add_argument("--arduino-baud", type=int, default=115200)
    parser.add_argument("--average", type=int, default=10)
    parser.add_argument("--strength-weight", type=float, default=0.05)
    parser.add_argument(
        "--key-score",
        choices=["sum", "min"],
        default="min",
        help="How to combine per-sample errors into one key score.",
    )
    parser.add_argument(
        "--z-layers",
        default="0,1,2",
        help="Comma-separated LUT z layers used for tracking, e.g. 1,2 or 0,1,2.",
    )
    parser.add_argument(
        "--min-total-g2",
        type=float,
        default=0.0,
        help="Reject a frequency when its total H2 is below this Gauss^2 value.",
    )
    parser.add_argument("--local-center-key-id", type=int, default=2)
    parser.add_argument("--initial-center-key", type=int, default=12)
    parser.add_argument("--min-center-key", type=int, default=2)
    parser.add_argument("--max-center-key", type=int, default=12)
    parser.add_argument("--steps-per-key", type=int, default=100)
    parser.add_argument("--steps-per-second", type=float, default=800.0)
    parser.add_argument("--left-threshold", type=int, default=-2)
    parser.add_argument("--right-threshold", type=int, default=2)
    parser.add_argument(
        "--move-stable",
        type=int,
        default=3,
        help="Consecutive same nonzero movement decisions required before moving.",
    )
    parser.add_argument(
        "--move-cooldown",
        type=float,
        default=0.5,
        help="Extra seconds to wait after a one-key movement.",
    )
    parser.add_argument(
        "--print-hz",
        type=float,
        default=10.0,
        help="Maximum terminal status print rate.",
    )
    parser.add_argument(
        "--enable-motor",
        action="store_true",
        help="Actually send stepper commands to Arduino. Default is dry-run.",
    )
    parser.add_argument(
        "--no-order-check",
        action="store_true",
        help="Do not require the 75 Hz finger to be left of the 45 Hz finger.",
    )
    parser.add_argument(
        "--arduino-ready-delay",
        type=float,
        default=2.0,
        help="Seconds to wait after opening Arduino serial, because many boards reset.",
    )
    args = parser.parse_args()

    if args.min_center_key > args.max_center_key:
        print("--min-center-key must be <= --max-center-key", file=sys.stderr)
        return 2
    if not (args.min_center_key <= args.initial_center_key <= args.max_center_key):
        print("Initial platform center is outside the allowed range.", file=sys.stderr)
        return 2
    if args.steps_per_key <= 0:
        print("--steps-per-key must be positive", file=sys.stderr)
        return 2
    if args.steps_per_second <= 0:
        print("--steps-per-second must be positive", file=sys.stderr)
        return 2
    if args.enable_motor and not args.arduino_port:
        print("arduino_port is required when --enable-motor is used.", file=sys.stderr)
        return 2

    z_layers = parse_z_layers(args.z_layers)
    entries_75 = load_lut(args.lut_75, "75")
    entries_45 = load_lut(args.lut_45, "45")

    platform_center_key = args.initial_center_key
    sample_windows = {
        "75": deque(maxlen=max(1, args.average)),
        "45": deque(maxlen=max(1, args.average)),
    }
    move_history = deque(maxlen=max(1, args.move_stable))
    print_period = 1.0 / args.print_hz if args.print_hz > 0 else 0.0
    last_print = 0.0

    print("=== Magnetic Platform Tracker ===")
    print(f"FPGA port: {args.fpga_port} @ {args.fpga_baud}")
    print(f"Arduino port: {args.arduino_port if args.arduino_port else '(none)'}")
    print(f"Motor output: {'ENABLED' if args.enable_motor else 'DRY RUN'}")
    print(f"Loaded {len(entries_75)} LUT entries for 75 Hz from {args.lut_75}")
    print(f"Loaded {len(entries_45)} LUT entries for 45 Hz from {args.lut_45}")
    print(f"Using z layers: {sorted(z_layers)}")
    print(
        "Platform center range: "
        f"{args.min_center_key}..{args.max_center_key}, "
        f"initial={platform_center_key}, steps/key={args.steps_per_key}"
    )
    print("Local key ids are mapped by local_index = key_id - local_center_key_id.")
    print("Press Ctrl-C to stop.")

    arduino_ser = None
    try:
        arduino_ser = open_arduino(args)
        with serial.Serial(args.fpga_port, args.fpga_baud, timeout=1) as fpga_ser:
            print(f"Opened FPGA H2 port {args.fpga_port} at {args.fpga_baud} baud.")

            while True:
                frame = read_h2_frame(fpga_ser)
                sample_windows["75"].append(frame["75"])
                sample_windows["45"].append(frame["45"])

                if any(
                    len(window) < window.maxlen
                    for window in sample_windows.values()
                ):
                    continue

                values_75 = average_samples(sample_windows["75"])
                values_45 = average_samples(sample_windows["45"])
                result_75 = classify(
                    values_75,
                    entries_75,
                    args.strength_weight,
                    args.key_score,
                    z_layers,
                )
                result_45 = classify(
                    values_45,
                    entries_45,
                    args.strength_weight,
                    args.key_score,
                    z_layers,
                )

                local_75 = local_index_from_key_id(
                    result_75["key_id"],
                    args.local_center_key_id,
                )
                local_45 = local_index_from_key_id(
                    result_45["key_id"],
                    args.local_center_key_id,
                )
                global_75 = platform_center_key + local_75
                global_45 = platform_center_key + local_45

                valid_signal = (
                    result_75["total_g2"] >= args.min_total_g2
                    and result_45["total_g2"] >= args.min_total_g2
                )
                valid_order = args.no_order_check or local_75 <= local_45
                center_sum = local_75 + local_45
                requested_move = movement_from_center_sum(
                    center_sum,
                    args.left_threshold,
                    args.right_threshold,
                )

                move_allowed = False
                blocked_reason = ""
                if not valid_signal:
                    blocked_reason = "weak-signal"
                    move_history.clear()
                elif not valid_order:
                    blocked_reason = "finger-order"
                    move_history.clear()
                elif requested_move == 0:
                    blocked_reason = "centered"
                    move_history.clear()
                else:
                    next_center = platform_center_key + requested_move
                    if next_center < args.min_center_key:
                        blocked_reason = "left-limit"
                        move_history.clear()
                    elif next_center > args.max_center_key:
                        blocked_reason = "right-limit"
                        move_history.clear()
                    else:
                        move_allowed = True
                        move_history.append(requested_move)

                move_ready = (
                    move_allowed
                    and len(move_history) == move_history.maxlen
                    and all(move == requested_move for move in move_history)
                )

                if move_ready:
                    motor_steps = requested_move * args.steps_per_key
                    direction_text = "RIGHT" if requested_move > 0 else "LEFT"
                    print(
                        f"Move {direction_text}: center {platform_center_key} -> "
                        f"{platform_center_key + requested_move}, steps={motor_steps}"
                    )
                    send_step_command(arduino_ser, motor_steps, args.enable_motor)
                    platform_center_key += requested_move
                    move_history.clear()
                    sample_windows["75"].clear()
                    sample_windows["45"].clear()

                    move_seconds = (
                        abs(motor_steps) / args.steps_per_second
                        + args.move_cooldown
                    )
                    time.sleep(move_seconds)
                    drain_serial_lines(arduino_ser, 0.2)
                    fpga_ser.reset_input_buffer()
                    continue

                now = time.time()
                if now - last_print >= print_period:
                    if requested_move < 0:
                        request_text = "LEFT"
                    elif requested_move > 0:
                        request_text = "RIGHT"
                    else:
                        request_text = "STAY"

                    stable_text = (
                        f"{len(move_history)}/{move_history.maxlen}"
                        if move_allowed
                        else blocked_reason
                    )
                    print(
                        f"center={platform_center_key:2d} "
                        f"75={result_75['key_name']}({local_75:+d},G{global_75}) "
                        f"45={result_45['key_name']}({local_45:+d},G{global_45}) "
                        f"sum={center_sum:+d} request={request_text:<5s} "
                        f"state={stable_text} "
                        f"H2=({result_75['total_g2']:.3f},{result_45['total_g2']:.3f})"
                    )
                    last_print = now

    except KeyboardInterrupt:
        print("\nStopped.")
        return 0
    finally:
        if arduino_ser is not None:
            arduino_ser.close()


if __name__ == "__main__":
    raise SystemExit(main())
