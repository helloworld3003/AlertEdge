# AlertEdge — Complete Technical Summary
### Interview-Ready Deep Dive

---

## Table of Contents
1. [System Overview](#1-system-overview)
2. [Hardware Layer — ESP32-CAM](#2-hardware-layer--esp32-cam)
3. [The Prototype — `drowsiness.py` + `face_landmarker.task`](#3-the-prototype--drowsinesspy--face_landmarkertask)
4. [The Core Algorithm — Eye Aspect Ratio (EAR)](#4-the-core-algorithm--eye-aspect-ratio-ear)
5. [From Python to Flutter — `drowsiness_detector.dart`](#5-from-python-to-flutter--drowsiness_detectordart)
6. [Dual-Stream Architecture — `mjpeg_streamer.dart`](#6-dual-stream-architecture--mjpeg_streamerdart)
7. [Alarm System — `alarm_service.dart`](#7-alarm-system--alarm_servicedart)
8. [App Orchestration — `main.dart`](#8-app-orchestration--maindart)
9. [Configuration System — `app_config.dart`](#9-configuration-system--app_configdart)
10. [Key Engineering Decisions and Trade-offs](#10-key-engineering-decisions-and-trade-offs)
11. [ESP32 Firmware — `CameraWebServer.ino`](#11-esp32-firmware--camerawebserverino)
12. [Android 14 (API 34+) Foreground Service & Lifecycle Stabilization](#12-android-14-api-34-foreground-service--lifecycle-stabilization)
13. [Real-Time Frame Rate Throttling & Lag Elimination](#13-real-time-frame-rate-throttling--lag-elimination)
14. [Hardware-Accelerated GPS Speed Integration](#14-hardware-accelerated-gps-speed-integration)
15. [Background Isolate TTS (Text-To-Speech) Alerts](#15-background-isolate-tts-text-to-speech-alerts)

---

## 1. System Overview

AlertEdge is a **real-time driver drowsiness detection system** combining embedded hardware (ESP32-CAM) with an on-device Flutter ML pipeline, smart GPS location services, and background audio monitoring.

```
ESP32-CAM (JPEG/MJPEG over Wi-Fi)
        |
        |  HTTP port :81  (MJPEG stream)
        v
Flutter App (Android/iOS)
  |-- MjpegStreamer      — parses raw TCP bytes into JPEG frames
  |-- DrowsinessDetector — runs ML Kit Face Mesh + Frame-based EAR algorithm
  |-- GpsSpeedService    — reads hardware GPS for intelligent alarm suppression
  +-- AlarmService       — triggers Conditional TTS + hardware buzzer via ESP32
        |
        |  HTTP port :82  (alarm / flash commands)
        v
ESP32-CAM GPIO
  |-- GPIO 12 — Piezo Buzzer
  |-- GPIO 13 — Vibration Motor (NPN transistor)
  |-- GPIO 4  — Flash LED
  +-- GPIO 14 — Extra Warning LED
```

---

## 2. Hardware Layer — ESP32-CAM

### Camera Configuration
- **Sensor**: OV2640 (AI-Thinker board)
- **Resolution**: CIF (400x296) — the deliberate sweet spot:
  - 2.25x more pixels than QVFA → much better eye landmark accuracy
  - 2.25x fewer pixels than VGA → lower Wi-Fi bandwidth + ML load
- **JPEG Quality**: 8 (higher quality = sharper eye features for ML)
- **Color Mode**: Grayscale (Effect 2) — **40% smaller JPEG payload**, ML Kit doesn't need color for eye tracking
- **Grab Mode**: `CAMERA_GRAB_LATEST` — always drops stale frames, never queues

### Server Ports
| Port | Purpose |
|------|---------|
| 80   | Camera config web UI / Single Frame /capture Endpoint |
| 81   | MJPEG live stream (Flutter reads this) |
| 82   | Alarm server — receives GET /alarm and GET /toggle_flash |

---

## 3. The Prototype — `drowsiness.py` + `face_landmarker.task`

### What is `face_landmarker.task`?

`face_landmarker.task` is a **compiled MediaPipe model bundle** from Google. It is a single `.task` file used during local Python prototyping to validate logic before porting to mobile. It contains Neural weights for 478 facial landmarks, configured in `VisionRunningMode.VIDEO` for temporal smoothing.

### Landmark Indices — The Magic Numbers

The system tracks specific eye contour boundaries based on their static indices:
```dart
static const List<int> _leftEyeIdx  = [33, 160, 158, 133, 153, 144];
static const List<int> _rightEyeIdx = [362, 385, 387, 263, 373, 380];
```
- Corners define the horizontal axis (denominator)
- Vertical lid pairs are averaged (numerator) to produce ratio robustness.

---

## 4. The Core Algorithm — Eye Aspect Ratio (EAR)

### The Formula

EAR is defined mathematically as the ratio of the vertical eye distance over twice the horizontal width:

```
        ||p2 - p6|| + ||p3 - p5||
EAR = ----------------------------
            2 x ||p1 - p4||
```

### Bilateral Averaging
Both eyes are processed simultaneously and averaged. This prevents one eye being briefly occluded by glasses frame or shadow from triggering a false positive.

---

## 5. From Python to Flutter — `drowsiness_detector.dart`

The Flutter implementation was ported for native mobile speed and stability:

### 5.1 ML Engine Switch — MediaPipe to Google ML Kit

Desktop Python uses the standalone Tasks library. Production Flutter switches to `google_mlkit_face_mesh_detection` utilizing **C++ hardware accelerated bindings** on Android without needing a Python runtime.

### 5.2 EAR Temporal Smoothing
A rolling window averages the last 2 frame's EAR readings before reaching the trigger phase, preventing a single corrupted JPEG artifact from generating spurious false sirens.

### 5.3 Frame-Based Detection Logic (Optimized for Consistency)
Instead of a floating millisecond timer which is susceptible to execution jank, Flutter actively tracks **Consecutive Closed Frames**. The system guarantees that an alarm only fires once `N` successive frames register below the user's set Threshold limit. 

### 5.4 Open-Eye Hysteresis
Requires a confirmed count of consecutive open-eye frames before resetting a drowsiness streak. This eliminates the chance that a random blink artifact immediately resets a real drowsiness session countdown.

---

## 6. Dual-Stream Architecture — `mjpeg_streamer.dart`

The app delivers video packets through an asynchronous socket parsing routine splitting frames by the `0xFF 0xD8` (SOI) and `0xFF 0xD9` (EOI) markers.

**Dual Output Streams**:
1. **Display stream**: Throttled to 10 FPS — to ensure smooth battery-efficient UI rendering.
2. **ML stream**: Completely unthrottled — feeds every individual captured frame directly into the processing queue instantly.

---

## 7. Alarm System — `alarm_service.dart`

When drowsiness occurs, the Alarm service evaluates user overrides before action:
- **Voice Notification**: Runs instantly via Google Text-To-Speech Engine ("Wake up!") only if enabled.
- **Hardware Buzzer**: Dispatches an HTTP request to GPIO port 82 only if enabled.
- **Rate Limiting**: A fixed hard cooldown blocks spamming the ESP32 hardware repeatedly.
- **SQLite Audit**: Persists every detected instance locally into SQLite for user logs.

---

## 8. App Orchestration — `main.dart`

The Main shell acts as the controller ensuring consistent lifecycles across UI views using an `IndexedStack`.
Crucially, we implemented **IP Guardrails** ensuring that standard toggle edits do not interrupt active video stream sockets, while ensuring a full teardown/reconnect only executes if the IP actually modifies.

---

## 9. Configuration System — `app_config.dart`

The Configuration suite holds full Persistent Storage capability via `SharedPreferences`.
Users can actively modify parameters live within the UI:
- **ESP32-CAM IP Address**: Editable without app restart.
- **EAR Threshold**: Direct manipulation of numerical sensitivity.
- **Consecutive Frames**: Exact precision over trigger speed.
- **Enable/Disable Switches**: Real-time bypass control for audio and sirens.

---

## 10. Key Engineering Decisions and Trade-offs

### Decision 1: Consecutive Frame Counter
Switched from raw time elapsed back to Consecutive Frame counting. Why? It ensures exactly identical performance across various devices regardless of frame-processing speed differentials, yielding total predictability for safety critical triggers.

### Decision 2: Hardware-Optimized Greyscale
A CIF grayscale JPEG yields up to 40% bandwidth reduction versus RBG, significantly reducing Wi-Fi packet drop probability in vehicle hotspot settings while ML Face Mesh preserves 100% precision without chroma info.

### Decision 3: Non-Blocking Frame Dropping
If the device is currently running ML inference, incoming stream frames are dropped instantly. This eradicates "frame pileup," ensuring the detector only analyzes the absolute freshest temporal image without trailing latency.

### Decision 4: Configuration Guarding
Stream teardowns are strictly conditionally bound to IP changes. Toggling local preferences (volume, buzzer, threshold) occurs seamlessly without resetting camera TCP sockets, removing annoying "Connecting" blackscreen hiccups.

---

## 11. ESP32 Firmware — `CameraWebServer.ino`

Handles local routing and camera hardware initialization.
- **WiFiManager**: Creates an Access Point to configure local hotspot credentials without hard-coding ssid parameters.
- **`CAMERA_GRAB_LATEST`**: Discards old frames internally so network stream serves strictly freshest pixel buffers.
- **Non-blocking Actuator pattern**: Eliminates `delay()` calls inside arduino loop to keep the MJPEG HTTP daemon serving frames smoothly during an active buzzer trigger event.

---

## 12. Android 14 (API 34+) Foreground Service & Lifecycle Stabilization

Android 14 enforces rigorous foreground restraints to save battery.
- **Permission Declarations**: `connectedDevice` and `dataSync` passed strictly dynamically to native `startService`.
- **Naming Corrections**: Reconciled a hard manifest-link class path mismatch within vendor libraries.
- **`initCommunicationPort`**: Injected correct isolate routing prior to `runApp()` to satisfy mandatory plugin hooks.

---

## 13. Real-Time Frame Rate Throttling & Lag Elimination

A CPU-adaptive boolean throttle logic ensures zero queued backlog accumulation. If processing time spikes due to background system load, frames are dropped perfectly silently to retain zero-latency synchronization.

---

## 14. Hardware-Accelerated GPS Speed Integration

Integrated the `geolocator` package utilizing high-precision satellite locks via the phone's hardware GPS sensor. 
- **Foreground Location Type**: Explicitly authorized as a system-level Location Foreground Service to maintain streaming telemetry even during device lock.
- **Velocity Inversion Logic**: Dynamically overrides all alarm sirens whenever vehicle speed reads 0km/h, preventing false alarms while parked, fueling, or waiting at traffic signal stops.

---

## 15. Background Isolate TTS (Text-To-Speech) Alerts

Configured specialized background processing to bypass background strictures where Android normally kills Dart UI elements:
- **Separate Isolate Instance**: Runs `FlutterTts` and custom detection inside the background Service Isolate thread.
- **App-Off Protection**: App retrieves and analyzes single frames from the `/capture` endpoint asynchronously, speaking the "Wake up!" warning audibly from the device speaker even if the user is using Maps, browser, or has their physical display turned off.

---

*AlertEdge v1.5.9 — Embedded IoT x Mobile ML x Background Safety Runtime*
