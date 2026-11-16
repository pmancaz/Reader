"""Offline EBU R128 loudness measurement and two-pass speech normalization."""
from pathlib import Path
import json
import math
import signal
import subprocess
import tempfile

FFMPEG = Path(__file__).resolve().parent / "bin" / "ffmpeg"
ACTIVE = None


def stop(signum, frame):
    if ACTIVE is not None and ACTIVE.poll() is None:
        ACTIVE.kill()
        ACTIVE.wait(timeout=5)
    raise SystemExit(128 + signum)


def run(arguments, report=None, duration=0):
    global ACTIVE
    previous = signal.signal(signal.SIGTERM, stop)
    try:
        with tempfile.TemporaryFile() as error_log:
            options = ["-progress", "pipe:1"] if report else []
            ACTIVE = subprocess.Popen([str(FFMPEG), "-hide_banner", "-nostdin", "-nostats", "-y",
                                       *options, *map(str, arguments)], stdout=subprocess.PIPE if report else subprocess.DEVNULL,
                                      stderr=error_log, text=True)
            if report:
                for line in ACTIVE.stdout:
                    key, _, value = line.strip().partition("=")
                    if key == "out_time_us" and duration > 0:
                        try:
                            fraction = min(1.0, max(0.0, int(value) / (duration * 1_000_000)))
                        except ValueError:
                            continue
                        report(fraction)
            ACTIVE.wait()
            error_log.seek(0)
            log = error_log.read().decode(errors="replace")
            if ACTIVE.returncode:
                raise ValueError("Audio processing failed. " + log[-1000:])
            return log
    finally:
        # Progress reporting can fail (for example if a job folder is removed or
        # its disk fills). Do not leave an encoder running after its worker exits.
        if ACTIVE is not None:
            if ACTIVE.poll() is None:
                ACTIVE.kill()
            ACTIVE.wait(timeout=5)
            if ACTIVE.stdout is not None:
                ACTIVE.stdout.close()
        ACTIVE = None
        signal.signal(signal.SIGTERM, previous)


def measure(source, peak=-1, report=None):
    import soundfile as sf
    duration = sf.info(source).duration
    log = run(["-i", source, "-af", f"loudnorm=I=-19:TP={peak}:LRA=11:print_format=json", "-f", "null", "-"], report, duration)
    start = log.rfind("{")
    return json.loads(log[start:log.index("}", start) + 1])



def normalize(source, target, progress, mp3=False, report=None):
    def update(message, fraction):
        progress(message)
        if report: report(message, fraction)
    progress("Measuring audio loudness…")
    peak = -1.8 if mp3 else -1.2
    measured = measure(source, peak, lambda f:update("Measuring audio loudness…",f * 0.25))
    silent = not math.isfinite(float(measured["input_i"]))
    offset = float(measured["target_offset"]) if not silent else 0.0
    codec = ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "32000"] if mp3 else ["-c:a", "pcm_s16le", "-ar", "48000"]
    for attempt in range(3):
        if silent:
            tp = float(measured["input_tp"])
            # Very short clips have no integrated LUFS reading, but still need peak protection.
            gain = min(0.0, (-2.0 if mp3 else -1.3) - tp) if math.isfinite(tp) else 0.0
            filters = f"volume={gain}dB"
        else:
            filters = (f"loudnorm=I=-19:TP={peak}:LRA=11:"
                       f"measured_I={measured['input_i']}:measured_TP={measured['input_tp']}:"
                       f"measured_LRA={measured['input_lra']}:measured_thresh={measured['input_thresh']}:"
                       f"offset={offset}:linear=false:print_format=json")
        progress("Normalizing and exporting MP3…" if mp3 else "Normalizing playback loudness…")
        import soundfile as sf
        message = "Normalizing and exporting MP3…" if mp3 else "Normalizing playback loudness…"
        run(["-i", source, "-map", "0:a:0", "-af", filters, *codec, target],
            lambda f:update(message,0.25+f * 0.50), sf.info(source).duration)
        progress("Checking finished audio loudness…")
        finished = measure(target, report=lambda f:update("Checking finished audio loudness…",min(0.98,0.75+f*0.23)))
        if silent:
            tp = float(finished["input_tp"])
            if tp > -1:
                raise ValueError("The short clip exceeded the peak ceiling.")
            if report: report("Audio ready", 1.0)
            return finished
        loudness, true_peak = float(finished["input_i"]), float(finished["input_tp"])
        if abs(loudness + 19) <= 0.2 and true_peak <= -1:
            if report: report("Audio ready", 1.0)
            return finished
        offset += -19 - loudness
        if true_peak > -1:
            peak -= true_peak + 1.15
    raise ValueError("The audio could not meet the loudness target. Try a longer passage.")
