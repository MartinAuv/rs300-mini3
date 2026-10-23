#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import cv2
import numpy as np

DEVICE = os.environ.get("RS300_DEVICE", "/dev/video0")
WIDTH = 640
HEIGHT = 512
FPS = 60
DEST_IP = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DEST_IP", "192.168.103.166")
DEST_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("DEST_PORT", "5000"))
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


def open_stream_writer(dest_ip: str, dest_port: int):
    has_nvenc = gst_has_element("nvv4l2h264enc") and gst_has_element("nvvidconv")

    # 1. Try OpenCV VideoWriter with hardware encoding (nvv4l2h264enc) if available
    if has_nvenc:
        gst_out_hw = (
            "appsrc ! videoconvert ! video/x-raw,format=I420 ! "
            f"nvvidconv ! nvv4l2h264enc bitrate=4000000 ! h264parse ! "
            f"rtph264pay config-interval=1 pt=96 ! udpsink host={dest_ip} port={dest_port} sync=false async=false"
        )
        writer = cv2.VideoWriter(gst_out_hw, cv2.CAP_GSTREAMER, 0, FPS, (WIDTH, HEIGHT), False)
        if writer.isOpened():
            return writer, "Hardware-Encoding via nvv4l2h264enc (OpenCV GStreamer)"

    # 2. Try OpenCV VideoWriter with software low-latency x264enc
    if gst_has_element("x264enc"):
        gst_out_sw = (
            "appsrc ! videoconvert ! video/x-raw,format=I420 ! "
            "x264enc tune=zerolatency speed-preset=ultrafast bitrate=4000 key-int-max=30 ! h264parse ! "
            f"rtph264pay config-interval=1 pt=96 ! udpsink host={dest_ip} port={dest_port} sync=false async=false"
        )
        writer = cv2.VideoWriter(gst_out_sw, cv2.CAP_GSTREAMER, 0, FPS, (WIDTH, HEIGHT), False)
        if writer.isOpened():
            return writer, "Software-Encoding via x264enc (OpenCV GStreamer)"

    # 3. Fallback when Ubuntu's python3-opencv package is compiled without CAP_GSTREAMER:
    #    pipe raw 8-bit grayscale frames directly into gst-launch-1.0 fdsrc.
    if has_nvenc:
        cmd = [
            "gst-launch-1.0", "-q",
            "fdsrc", "fd=0",
            "!", "rawvideoparse", f"width={WIDTH}", f"height={HEIGHT}", "format=gray8", f"framerate={FPS}/1",
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
            "!", "rawvideoparse", f"width={WIDTH}", f"height={HEIGHT}", "format=gray8", f"framerate={FPS}/1",
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
            "!", "rawvideoparse", f"width={WIDTH}", f"height={HEIGHT}", "format=gray8", f"framerate={FPS}/1",
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


def main() -> None:
    cap = cv2.VideoCapture(DEVICE, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*PIXEL_FORMAT))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)

    if not cap.isOpened():
        raise RuntimeError(f"Kamera ({DEVICE}) konnte nicht geöffnet werden.")

    out, encoder_info = open_stream_writer(DEST_IP, DEST_PORT)

    print("=" * 60)
    print("Thermal-Stream gestartet")
    print(f"Quelle:        {DEVICE} (Format: {PIXEL_FORMAT}, {WIDTH}x{HEIGHT} @ {FPS}fps)")
    print(f"Ziel:          udp://{DEST_IP}:{DEST_PORT}")
    print(f"Codec:         {CODEC} ({encoder_info})")
    print("Beenden mit:   Strg+C")
    print("=" * 60)

    alpha = 0.1
    smoothed_min = None
    smoothed_max = None

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                print("Stream abgebrochen.")
                break

            raw_16bit = np.ascontiguousarray(frame).reshape(-1).view(np.uint16).reshape((HEIGHT, WIDTH))

            cur_min = float(raw_16bit.min())
            cur_max = float(raw_16bit.max())

            if smoothed_min is None:
                smoothed_min, smoothed_max = cur_min, cur_max
            else:
                smoothed_min = alpha * cur_min + (1 - alpha) * smoothed_min
                smoothed_max = alpha * cur_max + (1 - alpha) * smoothed_max

            frame_8bit = np.clip(
                (raw_16bit.astype(np.float32) - smoothed_min) / max(smoothed_max - smoothed_min, 1) * 255,
                0, 255
            ).astype(np.uint8)

            out.write(frame_8bit)

    except KeyboardInterrupt:
        print("\nStream manuell beendet.")

    finally:
        cap.release()
        out.release()
        print("Kamera und Stream-Pipeline freigegeben.")


if __name__ == "__main__":
    main()
