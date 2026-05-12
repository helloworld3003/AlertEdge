#include "esp_camera.h"
#include <WiFi.h>
#include <WiFiManager.h>  // By tzapu - handles captive portal setup
#include <ESPmDNS.h>      // Lets phone find ESP32 at "alertedge.local"
#include "driver/gpio.h"  // For gpio_set_drive_capability

// ===========================
// Select camera model
// ===========================
#define CAMERA_MODEL_AI_THINKER // Has PSRAM
#include "camera_pins.h"

// ===========================
// Alarm Server on port 82 (port 80 is used by the camera httpd)
// ===========================
WiFiServer alarmServer(82);

void startCameraServer(); // Function prototype from the other tabs

// ===========================
// Sensor Profile Functions
// ===========================
// These can be called at any time to switch sensor registers WITHOUT
// reinitializing the camera. The OV2640 registers are live-updated.

void applyNightMode() {
  sensor_t *sensor = esp_camera_sensor_get();
  if (sensor == NULL) return;

  // --- NIGHT MODE: Maximum low-light sensitivity ---
  sensor->set_exposure_ctrl(sensor, 1);    // AEC on
  sensor->set_aec2(sensor, 1);             // AEC2 on (advanced)
  sensor->set_ae_level(sensor, 2);         // +2 = max overexposure bias
  sensor->set_aec_value(sensor, 1200);     // Max integration time (0-1200)

  sensor->set_gain_ctrl(sensor, 1);        // AGC on
  sensor->set_agc_gain(sensor, 30);        // Max manual gain boost (0-30)
  sensor->set_gainceiling(sensor, (gainceiling_t)6);  // GAINCEILING_128X

  sensor->set_brightness(sensor, 2);       // Max brightness (+2)
  sensor->set_contrast(sensor, 1);         // Slight contrast boost
  // Denoising ON at 1 — at 128X gain, denoise=0 creates extreme color noise.
  // Level 1 reduces chroma noise while preserving eyelid edges for EAR detection.
  sensor->set_denoise(sensor, 1);
  sensor->set_whitebal(sensor, 0);         // WB off
  sensor->set_awb_gain(sensor, 0);         // AWB off

  // *** MUST be LAST: GAINCEILING_128X register write resets special_effect ***
  // Without this ordering, night mode images show full color chroma noise
  // even though the camera is supposed to output grayscale.
  sensor->set_special_effect(sensor, 2);   // 2 = Grayscale (always set LAST)

  Serial.println(">>> Night mode sensor profile applied.");
}

void setup() {
  Serial.begin(115200);
  // Serial.setDebugOutput(true) removed — it floods the monitor with
  // all internal WiFi/camera logs, causing crashes. Only our println() calls show now.

  // Initialize Actuator Pins
  // Maximize drive strength on output pins (40mA max per GPIO on ESP32)
  gpio_set_drive_capability((gpio_num_t)12, GPIO_DRIVE_CAP_3); // Buzzer
  gpio_set_drive_capability((gpio_num_t)14, GPIO_DRIVE_CAP_3); // Motor (direct, 68Ω)

  // GPIO 14 — motor driven directly with a 68Ω series resistor (no transistor).
  // We use LEDC PWM on this pin to deliver a high-current kick-start pulse
  // that overcomes motor static inertia, then hold at steady run speed.
  // ESP32 Arduino core 3.x API: ledcAttach(pin, freq, bits) + ledcWrite(pin, duty)
  ledcAttach(14, 5000, 8);      // GPIO 14: 5 kHz PWM, 8-bit resolution (0-255)
  ledcWrite(14, 0);             // Start with motor off

  pinMode(12, OUTPUT); // Piezo Buzzer
  pinMode(4,  OUTPUT); // Flash LED
  digitalWrite(12, LOW);
  digitalWrite(4,  LOW);

  // ===========================
  // Camera Initialization
  // ===========================
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  // XCLK at 10MHz: lower read noise, acceptable for 5fps target.
  // This is kept for both day/night since 5fps doesn't need fast readout.
  config.xclk_freq_hz = 20000000; // 20MHz for faster sensor readout at CIF
  // CIF (400x296): sweet spot between QVGA accuracy and VGA speed
  // 2.25x more pixels than QVGA = much better eye detection
  // 2.25x fewer pixels than VGA = far less network/ML Kit load
  config.frame_size = FRAMESIZE_CIF;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode = CAMERA_GRAB_LATEST; // Always grab newest frame, drop stale ones
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 8;  // Higher quality (lower number) for sharper eye features
  config.fb_count = 2;  // Double buffering

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);
    return;
  }

  // ===========================
  // Force Grayscale Mode
  // ===========================
  // Grayscale JPEGs are ~40% smaller than colour — less WiFi bandwidth,
  // faster phone decoding, and ML Kit doesn't need colour for eye tracking.
  // We set this here (after init) AND in applyDayMode/applyNightMode to
  // ensure it always sticks, even after sensor re-config.
  {
    sensor_t *s = esp_camera_sensor_get();
    if (s) s->set_special_effect(s, 2); // 2 = Grayscale
  }

  // ===========================
  // Apply Night Mode sensor profile on boot — works for all conditions.
  applyNightMode();

  // ===========================
  // WiFiManager - Station Mode
  // ===========================
  // On first boot (or if saved Wi-Fi fails), the ESP32 will broadcast
  // a setup hotspot called "AlertEdge_Setup". Connect your phone to it,
  // then open a browser — a captive portal lets you enter your hotspot credentials.
  // Those credentials are saved to flash and used on every future boot.
  WiFiManager wifiManager;
  wifiManager.setConfigPortalTimeout(180); // 3 minutes to configure, then reboot

  Serial.println("Connecting to Wi-Fi via WiFiManager...");
  if (!wifiManager.autoConnect("AlertEdge_Setup")) {
    Serial.println("Failed to connect. Rebooting...");
    delay(3000);
    ESP.restart();
  }

  Serial.println("Connected to Wi-Fi!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // ===========================
  // mDNS - Hostname Registration
  // ===========================
  // This gives the ESP32 a permanent hostname on the local network.
  // The Flutter app and Python script can now always reach it at "alertedge.local"
  // regardless of what dynamic IP the phone hotspot assigned.
  if (!MDNS.begin("alertedge")) {
    Serial.println("Error starting mDNS responder!");
  } else {
    Serial.println("mDNS started. Reachable at: http://alertedge.local");
  }

  // Register our services with mDNS for discovery
  MDNS.addService("http", "tcp", 81);   // Camera stream
  MDNS.addService("http", "tcp", 80);   // Camera config UI
  MDNS.addService("http", "tcp", 82);   // Alarm + mode switch + flash endpoint

  // Start Servers
  startCameraServer();
  alarmServer.begin();
  Serial.println("Camera server (port 80/81) and Alarm server (port 82) are running!");
}

unsigned long buzzerEndTime = 0;
bool buzzerActive = false;
bool manualFlashOn = false;
unsigned long lastBlinkMillis = 0;
bool flashBlinkState = false;

// ===========================
// Motor Kick-Start via PWM
// ===========================
// The motor is connected directly to GPIO 14 through a 68Ω series resistor
// (no transistor). At 3.3V the steady-state current is only ~34mA — enough
// to sustain rotation but often not enough to overcome the motor's starting
// inertia (which needs ~2–3× run current). The kick-start solves this:
//
//  Phase 1 — KICK (120ms, duty 255/255 = 100%): GPIO switches at 5kHz PWM.
//    The high-frequency switching creates a magnetic "hammer" effect that
//    breaks static friction and spins up the eccentric weight.
//  Phase 2 — RUN (duty 200/255 = ~78%): once spinning, less energy is needed.
//    This also reduces average GPIO dissipation once the motor is running.
//
// kickMotor() is non-blocking — the duty ramp is managed by a millis() timer
// so it doesn't stall the loop or interfere with the MJPEG server.

unsigned long motorKickEndMs = 0;  // When to transition from KICK → RUN duty

void kickMotor() {
  ledcWrite(14, 255);                      // 100% duty — maximum kick force
  motorKickEndMs = millis() + 120;         // Hold kick for 120ms
  Serial.println("[Motor] KICK START 100% duty");
}

void stopMotor() {
  ledcWrite(14, 0);                        // 0% duty — motor fully off
  motorKickEndMs = 0;
  Serial.println("[Motor] OFF");
}


void loop() {
  unsigned long now = millis();

  // === NON-BLOCKING ACTUATOR MANAGEMENT ===
  if (buzzerActive) {
    // --- Motor kick → run transition ---
    if (motorKickEndMs != 0 && now >= motorKickEndMs) {
      ledcWrite(14, 200);         // Ramp down to 78% run duty after kick
      motorKickEndMs = 0;         // Only transition once
      Serial.println("[Motor] RUN duty 78%");
    }

    if (now > buzzerEndTime) {
      // Alarm done — turn everything off
      digitalWrite(12, LOW);      // Buzzer off
      stopMotor();                // Motor off (PWM → 0)
      if (!manualFlashOn) digitalWrite(4, LOW);
      flashBlinkState = false;
      buzzerActive = false;
    } else if (!manualFlashOn) {
      // Blink flash every 100ms using explicit state tracker
      // (avoids breaking when loop is stalled by client reads)
      if (now - lastBlinkMillis >= 100) {
        lastBlinkMillis = now;
        flashBlinkState = !flashBlinkState;
        digitalWrite(4, flashBlinkState ? HIGH : LOW);
      }
    }
  }


  // === HTTP REQUEST HANDLING (Port 82) ===
  WiFiClient client = alarmServer.available();

  if (client) {
    // 500ms: enough for hotspot WiFi headers to arrive even under camera stream load.
    // 100ms was too short — caused empty reads and silent GPIO failures.
    client.setTimeout(500);
    String request = client.readStringUntil('\r');
    Serial.println("[Port82] Got: '" + request + "'");

    String responseBody = "OK";

    // --- ALARM ENDPOINT ---
    if (request.indexOf("GET /alarm") != -1) {
      Serial.println("DROWSINESS DETECTED: Firing Alarms!");

      digitalWrite(12, HIGH); // Buzzer on
      kickMotor();             // GPIO 14 — kick-start motor via PWM (100% → 78%)

      buzzerEndTime = millis() + 2000;
      buzzerActive = true;
      lastBlinkMillis = millis();
      flashBlinkState = true;
      if (!manualFlashOn) digitalWrite(4, HIGH);

      responseBody = "Alarm executed";
    }
    // --- MANUAL FLASH TOGGLE ---
    else if (request.indexOf("GET /toggle_flash") != -1) {
      manualFlashOn = !manualFlashOn;
      if (!buzzerActive) {
        digitalWrite(4, manualFlashOn ? HIGH : LOW);
      }
      responseBody = manualFlashOn ? "Flash ON" : "Flash OFF";
    }
    // --- NIGHT MODE ENDPOINT (kept for future use) ---
    else if (request.indexOf("GET /nightmode") != -1) {
      applyNightMode();
      responseBody = "Night mode active";
    }

    // Send HTTP 200 response
    client.flush();
    client.println("HTTP/1.1 200 OK");
    client.println("Content-type:text/plain");
    client.println();
    client.println(responseBody);
    client.stop();
  }
}