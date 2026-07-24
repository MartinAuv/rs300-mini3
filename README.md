# mini3-thermal-driver

Linux kernel driver for the Mini3 thermal camera module (Infisense RS300). Supports Orin NX/Nano on JNX120x Carrier CSI-1

> **Imaging only.** This camera produces thermal video for visualization. It does not support radiometric temperature measurement. Pixel values represent relative heat intensity, not absolute temperatures.


## Quick Start

Navigate to "rs300-mini3/platforms/nvidia/orin-nx" run the install script with "--set-default" parameter as superuser: "sudo ./install.sh --set-default" .
After finishing the installer procedure, cam is reachable as device: "/dev/video*"



## Driver Architecture

The driver (`src/rs300.c`) is a V4L2 camera sensor subdevice. It communicates with the camera over I2C for control and receives video over MIPI CSI-2 (2 lanes, 80 MHz). All SoC-specific routing is handled by the platform's device tree overlay.


## Camera Specifications

- **Sensor:** RS300 (Infisense)
- **Interface:** I2C (0x3c) + MIPI CSI-2 (2 lanes, 80 MHz)
- **Pixel format:** UYVY

On NVIDIA Jetson Orin, the tested WN2640-like 640x512 module is exposed to
Tegra as `UYVY`, while the useful display luma is interpreted as `YUY2` in
GStreamer.

In the validated 16-bit thermal mode, Jetson still transports and reports the
stream as `UYVY`. Treat each 640x512 frame as 2 bytes per pixel and reinterpret
the payload as little-endian `uint16` when raw thermal samples are required.

### Modules

| Module | Resolution | FPS |
|-|-|-|
| Mini3 256 | 256×192 | 25 / 50 fps |
| Mini3 384 | 384×288 | 30 / 60 fps |
| Mini3 640 | 640×512 | 30 / 60 fps |

Resolution is fixed per physical module and set at driver load time via the `mode` parameter. Runtime switching is not supported.

> **Hardware variation notice.** The Mini3 module is sold by multiple vendors. Units from different sources may contain different internal processing chips or firmware versions. This driver is developed and tested against specific hardware. If you experience issues, please note your vendor, firmware version, and module resolution when reporting.

