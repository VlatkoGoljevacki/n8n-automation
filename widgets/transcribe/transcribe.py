#!/usr/bin/env python3
"""
Transcribe audio/video files to text using faster-whisper.
Outputs both plain text and VTT subtitle formats.

Prerequisites:
    pipx install faster-whisper --include-deps

Usage:
    # Run via pipx (no venv needed):
    pipx run --spec faster-whisper python scripts/transcribe.py INPUT_FILE

    # Options:
    pipx run --spec faster-whisper python scripts/transcribe.py INPUT_FILE --language hr --model medium --output-dir /path/to/output

    # Examples:
    pipx run --spec faster-whisper python scripts/transcribe.py meeting.m4a
    pipx run --spec faster-whisper python scripts/transcribe.py meeting.mp4 --language hr --model large-v3
    pipx run --spec faster-whisper python scripts/transcribe.py meeting.m4a --output-dir ./transcripts

Supported input formats: m4a, mp3, mp4, wav, webm, ogg, flac (anything ffmpeg supports)

Models (accuracy vs speed on CPU):
    tiny    - fastest, least accurate (~2x realtime)
    base    - fast, decent for clear speech
    small   - good balance
    medium  - recommended for most use cases (~0.3x realtime)
    large-v3 - best accuracy, slowest (~0.15x realtime)

The int8 compute type is used by default for CPU — best speed/memory tradeoff.
"""

import argparse
import sys
import time
from pathlib import Path


def format_timestamp(seconds: float) -> str:
    """Convert seconds to VTT timestamp format (HH:MM:SS.mmm)."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)

    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def transcribe(input_path: str, language: str, model_name: str, output_dir: str | None):
    from faster_whisper import WhisperModel

    input_file = Path(input_path)
    if not input_file.exists():
        print(f"Error: file not found: {input_file}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(output_dir) if output_dir else input_file.parent
    stem = input_file.stem

    txt_path = out_dir / f"{stem}_transcript.txt"
    vtt_path = out_dir / f"{stem}_transcript.vtt"

    print(f"Loading model '{model_name}' (first run downloads the model)...")
    model = WhisperModel(model_name, device="cpu", compute_type="int8")

    print(f"Transcribing: {input_file}")
    print(f"Language: {language}")
    start_time = time.time()

    segments, info = model.transcribe(str(input_file), language=language)

    txt_lines = []
    vtt_lines = ["WEBVTT", ""]
    segment_count = 0

    for segment in segments:
        segment_count += 1
        text = segment.text.strip()

        txt_lines.append(f"[{format_timestamp(segment.start)} -> {format_timestamp(segment.end)}] {text}")

        vtt_lines.append(str(segment_count))
        vtt_lines.append(f"{format_timestamp(segment.start)} --> {format_timestamp(segment.end)}")
        vtt_lines.append(text)
        vtt_lines.append("")

        if segment_count % 50 == 0:
            elapsed = time.time() - start_time
            print(f"  ...{segment_count} segments ({elapsed:.0f}s elapsed)")

    elapsed = time.time() - start_time

    txt_path.write_text("\n".join(txt_lines), encoding="utf-8")
    vtt_path.write_text("\n".join(vtt_lines), encoding="utf-8")

    print(f"\nDone in {elapsed:.0f}s ({segment_count} segments)")
    print(f"  Text: {txt_path}")
    print(f"  VTT:  {vtt_path}")


def main():
    parser = argparse.ArgumentParser(description="Transcribe audio/video to text using faster-whisper")
    parser.add_argument("input", help="Path to audio/video file")
    parser.add_argument("--language", default="hr", help="Language code (default: hr)")
    parser.add_argument("--model", default="large-v3", help="Model size: tiny/base/small/medium/large-v3 (default: large-v3)")
    parser.add_argument("--output-dir", default=None, help="Output directory (default: same as input file)")

    args = parser.parse_args()
    transcribe(args.input, args.language, args.model, args.output_dir)


if __name__ == "__main__":
    main()
