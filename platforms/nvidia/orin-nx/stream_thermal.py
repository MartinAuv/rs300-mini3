#!/usr/bin/env python3
import glob
import os
import shutil
import subprocess
import sys
import threading
import cv2
import numpy as np

WIDTH = 640
HEIGHT = 512
FPS = 60
DEST_IP = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DEST_IP", "192.168.103.166")
DEST_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("DEST_PORT", "5000"))
STREAM_LAYOUT = os.environ.get("STREAM_LAYOUT", "separate")  # "separate" or "sbs"
PIXEL_FORMAT = "UYVY"
CODEC = "H264"


class GstPipeWriter:
    """Fallback GStreamer writer via gst-launch-1.0 stdin when OpenCV lacks CAP_GSTREAMER."""

    def __init__(self, cmd: list[str], encoder_label: str):
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        self.encoder_label = encoder_label

    def isOpened(self) -> bool:
        return self.proc.poll() is None and self.proc.stdin is not None

    def write(self, frame: np.ndarray) -> None:
        if self.proc.stdin is not None:
            self.proc.stdin.write(frame.tobytes())

    def release(self) -> None:
        if self.proc.stdin is not None:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
        try:
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def gst_has_element(element: str) -> bool:
    gst_inspect = shutil.which("gst-inspect-1.0")
    if not gst_inspect:
        return False
    res = subprocess.run(
        [gst_inspect, element],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return res.returncode == 0


def open_stream_writer(dest_ip: str, dest_port: int, width: int = WIDTH, height: int = HEIGHT):
    has_nvenc = gst_has_element("nvv4l2h264enc") and gst_has_element("nvvidconv")

    # 1. Try OpenCV VideoWriter with hardware encoding (nvv4l2h264enc) if available
    if has_nvenc:
        gst_out_hw = (
            "appsrc ! videoconvert ! video/x-raw,format=I420 ! "
            f"nvvidconv ! nvv4l2h264enc bitrate=4000000 ! h264parse ! "
            f"rtph264pay config-interval=1 pt=96 ! udpsink host={dest_ip} port={dest_port} sync=false async=false"
        )
        writer = cv2.VideoWriter(gst_out_hw, cv2.CAP_GSTREAMER, 0, FPS, (width, height), False)
        if writer.isOpened():
            return writer, "Hardware-Encoding via nvv4l2h264enc (OpenCV GStreamer)"

    # 2. Try OpenCV VideoWriter with software low-latency x264enc
    if gst_has_element("x264enc"):
        gst_out_sw = (
            "appsrc ! videoconvert ! video/x-raw,format=I420 ! "
            "x264enc tune=zerolatency speed-preset=ultrafast bitrate=4000 key-int-max=30 ! h264parse ! "
            f"rtph264pay config-interval=1 pt=96 ! udpsink host={dest_ip} port={dest_port} sync=false async=false"
        )
        writer = cv2.VideoWriter(gst_out_sw, cv2.CAP_GSTREAMER, 0, FPS, (width, height), False)
        if writer.isOpened():
            return writer, "Software-Encoding via x264enc (OpenCV GStreamer)"

    # 3. Fallback when Ubuntu's python3-opencv package is compiled without CAP_GSTREAMER:
    #    pipe raw 8-bit grayscale frames directly into gst-launch-1.0 fdsrc.
    if has_nvenc:
        cmd = [
            "gst-launch-1.0", "-q",
            "fdsrc", "fd=0",
            "!", "rawvideoparse", f"width={width}", f"height={height}", "format=gray8", f"framerate={FPS}/1",
            "!", "videoconvert",
            "!", "video/x-raw,format=I420",
            "!", "nvvidconv",
            "!", "nvv4l2h264enc", "bitrate=4000000",
            "!", "h264parse",
            "!", "rtph264pay", "config-interval=1", "pt=96",
            "!", "udpsink", f"host={dest_ip}", f"port={dest_port}", "sync=false", "async=false",
        ]
        return GstPipeWriter(cmd, "Hardware-Encoding via nvv4l2h264enc (GStreamer pipe)"), "Hardware-Encoding via nvv4l2h264enc"

    if gst_has_element("x264enc"):
        cmd = [
            "gst-launch-1.0", "-q",
            "fdsrc", "fd=0",
            "!", "rawvideoparse", f"width={width}", f"height={height}", "format=gray8", f"framerate={FPS}/1",
            "!", "videoconvert",
            "!", "video/x-raw,format=I420",
            "!", "x264enc", "tune=zerolatency", "speed-preset=ultrafast", "bitrate=4000", "key-int-max=30",
            "!", "h264parse",
            "!", "rtph264pay", "config-interval=1", "pt=96",
            "!", "udpsink", f"host={dest_ip}", f"port={dest_port}", "sync=false", "async=false",
        ]
        return GstPipeWriter(cmd, "Software-Encoding via x264enc (GStreamer pipe)"), "Software-Encoding via x264enc"

    if gst_has_element("openh264enc"):
        cmd = [
            "gst-launch-1.0", "-q",
            "fdsrc", "fd=0",
            "!", "rawvideoparse", f"width={width}", f"height={height}", "format=gray8", f"framerate={FPS}/1",
            "!", "videoconvert",
            "!", "video/x-raw,format=I420",
            "!", "openh264enc", "bitrate=4000000",
            "!", "h264parse",
            "!", "rtph264pay", "config-interval=1", "pt=96",
            "!", "udpsink", f"host={dest_ip}", f"port={dest_port}", "sync=false", "async=false",
        ]
        return GstPipeWriter(cmd, "Software-Encoding via openh264enc (GStreamer pipe)"), "Software-Encoding via openh264enc"

    raise RuntimeError(
        "Kein H264-GStreamer-Encoder gefunden (weder nvv4l2h264enc noch x264enc/openh264enc). "
        "Bitte 'sudo apt-get install -y gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad' ausführen."
    )


def open_camera(dev: str):
    cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*PIXEL_FORMAT))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)
    if not cap.isOpened():
        cap.release()
        return None
    ret, frame = cap.read()
    if not ret or frame is None:
        cap.release()
        return None
    return cap


def discover_active_cameras() -> list[tuple[str, cv2.VideoCapture]]:
    env_devs = os.environ.get("RS300_DEVICES", "").strip()
    if env_devs:
        candidates = env_devs.split()
    elif os.environ.get("RS300_DEVICE"):
        candidates = [os.environ["RS300_DEVICE"]]
    else:
        candidates = sorted(glob.glob("/dev/video*"))

    active = []
    for dev in candidates:
        cap = open_camera(dev)
        if cap is not None:
            active.append((dev, cap))
    return active


class ThermalNormalizer:
    def __init__(self, alpha: float = 0.1):
        self.alpha = alpha
        self.smoothed_min = None
        self.smoothed_max = None

    def normalize(self, frame: np.ndarray) -> np.ndarray:
        raw_16bit = np.ascontiguousarray(frame).reshape(-1).view(np.uint16).reshape((HEIGHT, WIDTH))
        cur_min = float(raw_16bit.min())
        cur_max = float(raw_16bit.max())

        if self.smoothed_min is None:
            self.smoothed_min, self.smoothed_max = cur_min, cur_max
        else:
            self.smoothed_min = self.alpha * cur_min + (1.0 - self.alpha) * self.smoothed_min
            self.smoothed_max = self.alpha * cur_max + (1.0 - self.alpha) * self.smoothed_max

        return np.clip(
            (raw_16bit.astype(np.float32) - self.smoothed_min)
            / max(self.smoothed_max - self.smoothed_min, 1.0)
            * 255.0,
            0,
            255,
        ).astype(np.uint8)


def stream_single_camera(dev: str, cap: cv2.VideoCapture, dest_ip: str, dest_port: int, stop_event: threading.Event):
    out, _ = open_stream_writer(dest_ip, dest_port, WIDTH, HEIGHT)
    norm = ThermalNormalizer(alpha=0.1)
    try:
        while not stop_event.is_set():
            ret, frame = cap.read()
            if not ret:
                print(f"[{dev}] Stream abgebrochen.")
                stop_event.set()
                break
            out.write(norm.normalize(frame))
    finally:
        cap.release()
        out.release()


def main() -> None:
    active_cams = discover_active_cameras()
    if not active_cams:
        raise RuntimeError("Keine aktive RS300/WN2640 Kamera konnte geöffnet werden.")

    stop_event = threading.Event()

    # Side-by-side combined mode when 2 cameras are active and STREAM_LAYOUT=sbs
    if len(active_cams) == 2 and STREAM_LAYOUT == "sbs":
        (dev0, cap0), (dev1, cap1) = active_cams
        out, encoder_info = open_stream_writer(DEST_IP, DEST_PORT, WIDTH * 2, HEIGHT)
        norm0 = ThermalNormalizer(alpha=0.1)
        norm1 = ThermalNormalizer(alpha=0.1)

        print("=" * 65)
        print("Dual Thermal-Stream gestartet (Side-by-Side 1280x512)")
        print(f"Quellen:       {dev0} + {dev1} (Format: {PIXEL_FORMAT}, 2x {WIDTH}x{HEIGHT} @ {FPS}fps)")
        print(f"Ziel:          udp://{DEST_IP}:{DEST_PORT}")
        print(f"Codec:         {CODEC} ({encoder_info})")
        print("Beenden mit:   Strg+C")
        print("=" * 65)

        try:
            while True:
                ret0, frame0 = cap0.read()
                ret1, frame1 = cap1.read()
                if not ret0 or not ret1:
                    print("Stream abgebrochen.")
                    break
                combined = np.hstack((norm0.normalize(frame0), norm1.normalize(frame1)))
                out.write(combined)
        except KeyboardInterrupt:
            print("\nStream manuell beendet.")
        finally:
            cap0.release()
            cap1.release()
            out.release()
            print("Kameras und Stream-Pipeline freigegeben.")
        return

    # Single camera or parallel multi-port streaming (Cam 0 -> DEST_PORT, Cam 1 -> DEST_PORT + 1)
    _, encoder_info = open_stream_writer(DEST_IP, DEST_PORT, WIDTH, HEIGHT)
    _.release()

    print("=" * 65)
    if len(active_cams) == 1:
        print("Thermal-Stream gestartet (1 Kamera)")
    else:
        print(f"Parallel Thermal-Stream gestartet ({len(active_cams)} Kameras)")
    for idx, (dev, _) in enumerate(active_cams):
        port = DEST_PORT + idx
        print(f"Kamera {idx}:      {dev} ({WIDTH}x{HEIGHT} @ {FPS}fps) -> udp://{DEST_IP}:{port}")
    print(f"Codec:         {CODEC} ({encoder_info})")
    print("Beenden mit:   Strg+C")
    print("=" * 65)

    threads = []
    for idx, (dev, cap) in enumerate(active_cams):
        port = DEST_PORT + idx
        t = threading.Thread(
            target=stream_single_camera,
            args=(dev, cap, DEST_IP, port, stop_event),
            daemon=True,
        )
        t.start()
        threads.append(t)

    try:
        while not stop_event.is_set():
            stop_event.wait(timeout=0.5)
    except KeyboardInterrupt:
        print("\nStream manuell beendet.")
        stop_event.set()
    finally:
        for t in threads:
            t.join(timeout=3.0)
        print("Kamera(s) und Stream-Pipeline(s) freigegeben.")


if __name__ == "__main__":
    main()
