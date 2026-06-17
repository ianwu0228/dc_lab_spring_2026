#!/usr/bin/env python3
import argparse
import math
import queue
import re
import struct
import sys
import threading
import tkinter as tk

try:
    import serial
except ImportError:
    print("Missing dependency: pyserial. Install with: pip install pyserial", file=sys.stderr)
    raise


KEY_RE = re.compile(r"^KEY,75,([0-9]{2}),([01]),45,([0-9]{2}),([01])$")


NOTE_INDEX = {
    "C": 0,
    "C#": 1,
    "DB": 1,
    "D": 2,
    "D#": 3,
    "EB": 3,
    "E": 4,
    "F": 5,
    "F#": 6,
    "GB": 6,
    "G": 7,
    "G#": 8,
    "AB": 8,
    "A": 9,
    "A#": 10,
    "BB": 10,
    "B": 11,
}


def parse_notes(notes_text):
    notes = [note.strip() for note in notes_text.split(",")]
    if not 1 <= len(notes) <= 15 or any(not note for note in notes):
        raise ValueError("--notes must contain 1 to 15 comma-separated note names")
    return notes


def note_frequency(note):
    match = re.fullmatch(r"([A-Ga-g])([#bB]?)(-?\d+)", note.strip())
    if not match:
        raise ValueError(f"Invalid note name: {note}")

    name = match.group(1).upper() + match.group(2).upper()
    octave = int(match.group(3))
    if name not in NOTE_INDEX:
        raise ValueError(f"Invalid note name: {note}")

    midi = (octave + 1) * 12 + NOTE_INDEX[name]
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


class TonePlayer:
    def __init__(self, notes, enabled):
        self.enabled = enabled
        self.sounds = {}
        self.pygame = None
        if not enabled:
            return

        try:
            import pygame
        except ImportError:
            print("Missing dependency: pygame. Install with: pip install pygame", file=sys.stderr)
            self.enabled = False
            return

        self.pygame = pygame
        pygame.mixer.pre_init(44100, -16, 1, 512)
        pygame.mixer.init()
        for note in notes:
            self.sounds[note] = pygame.mixer.Sound(buffer=self._make_tone(note))

    def _make_tone(self, note):
        sample_rate = 44100
        duration = 0.45
        frequency = note_frequency(note)
        sample_count = int(sample_rate * duration)
        samples = bytearray()

        for index in range(sample_count):
            t = index / sample_rate
            envelope = min(1.0, index / 800.0)
            release_start = int(sample_count * 0.70)
            if index > release_start:
                envelope *= max(
                    0.0,
                    1.0 - (index - release_start) / (sample_count - release_start),
                )

            value = (
                math.sin(2.0 * math.pi * frequency * t)
                + 0.35 * math.sin(2.0 * math.pi * frequency * 2.0 * t)
                + 0.15 * math.sin(2.0 * math.pi * frequency * 3.0 * t)
            )
            sample = int(max(-1.0, min(1.0, value * envelope * 0.45)) * 32767)
            samples.extend(struct.pack("<h", sample))

        return bytes(samples)

    def play(self, note):
        if not self.enabled:
            return
        sound = self.sounds.get(note)
        if sound is not None:
            sound.play()


def serial_reader(port, baud, output_queue, stop_event):
    try:
        with serial.Serial(port, baud, timeout=0.2) as ser:
            while not stop_event.is_set():
                line = ser.readline().decode("ascii", errors="replace").strip()
                match = KEY_RE.match(line)
                if not match:
                    continue

                output_queue.put(
                    {
                        "key75": int(match.group(1)),
                        "press75": bool(int(match.group(2))),
                        "key45": int(match.group(3)),
                        "press45": bool(int(match.group(4))),
                    }
                )
    except serial.SerialException as exc:
        output_queue.put({"error": str(exc)})


class PianoMonitor:
    def __init__(self, root, notes, player):
        self.root = root
        self.notes = notes
        self.player = player
        self.previous_press75 = False
        self.previous_press45 = False
        self.last_key75 = 0
        self.last_key45 = 0

        self.status = tk.StringVar(value="Waiting for FPGA KEY frames...")
        tk.Label(root, textvariable=self.status, font=("Arial", 16)).pack(pady=10)

        self.canvas = tk.Canvas(root, width=900, height=180, bg="white")
        self.canvas.pack(padx=10, pady=10)
        self.key_rects = []

        key_width = 58
        for index, note in enumerate(notes):
            x0 = 10 + index * key_width
            x1 = x0 + key_width - 4
            rect = self.canvas.create_rectangle(
                x0,
                20,
                x1,
                145,
                fill="#eeeeee",
                outline="black",
                width=2,
            )
            self.canvas.create_text(
                (x0 + x1) // 2,
                95,
                text=f"{index}\n{note}",
                font=("Arial", 11, "bold"),
            )
            self.key_rects.append(rect)

        self.detail = tk.StringVar(value="")
        tk.Label(root, textvariable=self.detail, font=("Arial", 13)).pack(pady=6)

    def update(self, event):
        if "error" in event:
            self.status.set(f"Serial error: {event['error']}")
            return

        self.last_key75 = event["key75"]
        self.last_key45 = event["key45"]
        press75 = event["press75"]
        press45 = event["press45"]

        if press75 and not self.previous_press75 and 0 <= self.last_key75 < len(self.notes):
            self.player.play(self.notes[self.last_key75])
        if press45 and not self.previous_press45 and 0 <= self.last_key45 < len(self.notes):
            self.player.play(self.notes[self.last_key45])

        self.previous_press75 = press75
        self.previous_press45 = press45

        for index, rect in enumerate(self.key_rects):
            is75 = press75 and index == self.last_key75
            is45 = press45 and index == self.last_key45
            if is75 and is45:
                color = "#ff9933"
            elif is75:
                color = "#66a3ff"
            elif is45:
                color = "#66cc66"
            else:
                color = "#eeeeee"
            self.canvas.itemconfig(rect, fill=color)

        note75 = self.notes[self.last_key75] if 0 <= self.last_key75 < len(self.notes) else "OUT"
        note45 = self.notes[self.last_key45] if 0 <= self.last_key45 < len(self.notes) else "OUT"
        self.status.set(
            f"75Hz: key {self.last_key75:02d} {note75} press={int(press75)}    "
            f"45Hz: key {self.last_key45:02d} {note45} press={int(press45)}"
        )
        self.detail.set("Blue = 75 Hz finger, green = 45 Hz finger, orange = both")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Show FPGA piano key presses and play simple synthesized notes."
    )
    parser.add_argument("port", help="Serial port, e.g. COM5 or /dev/ttyUSB0.")
    parser.add_argument("--baud", "-baud", type=int, default=115200)
    parser.add_argument(
        "--notes",
        required=True,
        help="Comma-separated note names for global keys starting at 0.",
    )
    parser.add_argument(
        "--no-sound",
        action="store_true",
        help="Show the window but do not play synthesized tones.",
    )
    args = parser.parse_args()

    try:
        notes = parse_notes(args.notes)
        for note in notes:
            note_frequency(note)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2

    events = queue.Queue()
    stop_event = threading.Event()
    reader = threading.Thread(
        target=serial_reader,
        args=(args.port, args.baud, events, stop_event),
        daemon=True,
    )
    reader.start()

    root = tk.Tk()
    root.title("FPGA Magnetic Piano Monitor")
    player = TonePlayer(notes, not args.no_sound)
    monitor = PianoMonitor(root, notes, player)

    def poll_events():
        while True:
            try:
                event = events.get_nowait()
            except queue.Empty:
                break
            monitor.update(event)
        root.after(20, poll_events)

    def on_close():
        stop_event.set()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    poll_events()
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
