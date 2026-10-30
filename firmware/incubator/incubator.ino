// Egg incubator controller for ESP32.
// Keeps the eggs at the target temperature on its own (heat lamp + fan relays, DHT22 sensor),
// serves a small JSON API on the home Wi-Fi for the phone app, and reports to the cloud so the
// app works away from home too.
//
// Libraries (Arduino Library Manager): "DHT sensor library" (Adafruit), "ArduinoJson" (v7).
// Board: ESP32 Dev Module (arduino-esp32 core 3.x).

#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include "config.h"

const int FW_VERSION = 1;

DHT dht(PIN_DHT, DHT22);
WebServer server(80);
DNSServer dns;
Preferences prefs;

// ---- Settings (saved in flash, changed by the app) --------------------------
enum Mode { MODE_AUTO, MODE_ON, MODE_OFF };
const char *MODE_NAMES[] = {"auto", "on", "off"};

struct Settings {
  String species = "chicken";
  uint32_t start = 0;   // unix time the batch started (0 = no batch)
  uint32_t turned = 0;  // unix time eggs were last turned
  float tTarget = 37.5;
  float hMin = 50, hMax = 55;
  Mode lamp = MODE_AUTO;
  Mode fan = MODE_ON;   // fan stirs the air all the time by default
} cfg;

// ---- Live state ---------------------------------------------------------------
String deviceKey;
float temp = NAN, hum = NAN;
bool sensorOk = false;
int sensorFails = 0;
bool lampOn = false, fanOn = false;
bool cloudOk = false;
int64_t cmdAck = 0;
bool apOn = false;

// 24 h of readings, one every 5 minutes, for the app's chart when offline from the cloud.
const int HIST_N = 288;
int16_t histT[HIST_N], histH[HIST_N];
int histCount = 0, histHead = 0;

unsigned long lastRead = 0, lastHist = 0, lastPush = 0, lastWifiCheck = 0, lastLampSwitch = 0;

// ---- Helpers ------------------------------------------------------------------
Mode parseMode(const char *s, Mode def) {
  if (!s) return def;
  for (int i = 0; i < 3; i++)
    if (strcmp(s, MODE_NAMES[i]) == 0) return (Mode)i;
  return def;
}

void setRelay(int pin, bool on) {
  digitalWrite(pin, (on ^ RELAY_ACTIVE_LOW) ? HIGH : LOW);
}

void loadSettings() {
  prefs.begin("inc", true);
  cfg.species = prefs.getString("species", cfg.species);
  cfg.start = prefs.getUInt("start", 0);
  cfg.turned = prefs.getUInt("turned", 0);
  cfg.tTarget = prefs.getFloat("tTarget", cfg.tTarget);
  cfg.hMin = prefs.getFloat("hMin", cfg.hMin);
  cfg.hMax = prefs.getFloat("hMax", cfg.hMax);
  cfg.lamp = (Mode)min<uint8_t>(prefs.getUChar("lamp", cfg.lamp), 2);
  cfg.fan = (Mode)min<uint8_t>(prefs.getUChar("fan", cfg.fan), 2);
  deviceKey = prefs.getString("key", "");
  prefs.end();

  if (deviceKey.length() < 16) {
    char buf[33];
    for (int i = 0; i < 16; i++) sprintf(buf + i * 2, "%02x", (uint8_t)esp_random());
    deviceKey = buf;
    prefs.begin("inc", false);
    prefs.putString("key", deviceKey);
    prefs.end();
  }
}

void saveSettings() {
  prefs.begin("inc", false);
  prefs.putString("species", cfg.species);
  prefs.putUInt("start", cfg.start);
  prefs.putUInt("turned", cfg.turned);
  prefs.putFloat("tTarget", cfg.tTarget);
  prefs.putFloat("hMin", cfg.hMin);
  prefs.putFloat("hMax", cfg.hMax);
  prefs.putUChar("lamp", cfg.lamp);
  prefs.putUChar("fan", cfg.fan);
  prefs.end();
}

// Apply a partial settings object from the app (local or cloud). Unknown keys are ignored.
void applyPatch(JsonObjectConst p) {
  if (p["species"].is<const char *>()) cfg.species = String((const char *)p["species"]).substring(0, 12);
  if (p["start"].is<uint32_t>()) cfg.start = p["start"];
  if (p["turned"].is<uint32_t>()) cfg.turned = p["turned"];
  if (p["t_target"].is<float>()) cfg.tTarget = constrain((float)p["t_target"], 30.0f, 39.0f);
  if (p["h_min"].is<float>()) cfg.hMin = constrain((float)p["h_min"], 20.0f, 90.0f);
  if (p["h_max"].is<float>()) cfg.hMax = constrain((float)p["h_max"], 20.0f, 95.0f);
  if (p["lamp"].is<const char *>()) cfg.lamp = parseMode(p["lamp"], cfg.lamp);
  if (p["fan"].is<const char *>()) cfg.fan = parseMode(p["fan"], cfg.fan);
  saveSettings();
  lastLampSwitch = 0;  // react right away
}

void buildState(JsonDocument &doc, bool withKey) {
  if (withKey) doc["key"] = deviceKey;
  if (sensorOk) {
    doc["t"] = roundf(temp * 10) / 10;
    doc["h"] = roundf(hum * 10) / 10;
  } else {
    doc["t"] = nullptr;
    doc["h"] = nullptr;
  }
  doc["ok"] = sensorOk;
  doc["lamp"] = lampOn;
  doc["fan"] = fanOn;
  doc["ip"] = WiFi.isConnected() ? WiFi.localIP().toString() : "";
  doc["rssi"] = WiFi.isConnected() ? WiFi.RSSI() : 0;
  doc["up"] = millis() / 1000;
  doc["cloud"] = cloudOk;
  doc["fw"] = FW_VERSION;
  JsonObject s = doc["s"].to<JsonObject>();
  s["species"] = cfg.species;
  s["start"] = cfg.start;
  s["turned"] = cfg.turned;
  s["t_target"] = cfg.tTarget;
  s["h_min"] = cfg.hMin;
  s["h_max"] = cfg.hMax;
  s["lamp"] = MODE_NAMES[cfg.lamp];
  s["fan"] = MODE_NAMES[cfg.fan];
}

// ---- Control --------------------------------------------------------------------
void readSensor() {
  float t = dht.readTemperature(), h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {
    if (++sensorFails >= 3) sensorOk = false;
    return;
  }
  sensorFails = 0;
  sensorOk = true;
  temp = t;
  hum = h;
}

void control() {
  // Lamp: thermostat with a small band so the relay does not chatter.
  bool lamp = lampOn;
  if (cfg.lamp == MODE_ON) lamp = true;
  else if (cfg.lamp == MODE_OFF) lamp = false;
  else if (!sensorOk) lamp = false;  // no reading: never heat blind
  else if (temp <= cfg.tTarget - 0.2) lamp = true;
  else if (temp >= cfg.tTarget + 0.2) lamp = false;
  if (sensorOk && temp >= MAX_TEMP) lamp = false;
  if (lamp != lampOn && (lastLampSwitch == 0 || millis() - lastLampSwitch > 5000)) {
    lampOn = lamp;
    lastLampSwitch = millis();
  }

  // Fan: always on / off, or auto = only when too hot.
  if (cfg.fan == MODE_ON) fanOn = true;
  else if (cfg.fan == MODE_OFF) fanOn = false;
  else if (sensorOk && temp >= cfg.tTarget + 0.6) fanOn = true;
  else if (!sensorOk || temp <= cfg.tTarget + 0.2) fanOn = false;
  if (sensorOk && temp >= MAX_TEMP) fanOn = true;

  setRelay(PIN_LAMP, lampOn);
  setRelay(PIN_FAN, fanOn);
}

void recordHistory() {
  if (!sensorOk) return;
  histT[histHead] = (int16_t)roundf(temp * 10);
  histH[histHead] = (int16_t)roundf(hum * 10);
  histHead = (histHead + 1) % HIST_N;
  if (histCount < HIST_N) histCount++;
}

// ---- Wi-Fi ------------------------------------------------------------------------
String savedSsid, savedPass;
int wifiRetry = 0;

void startAp() {
  if (apOn) return;
  String name = "Incubator-" + deviceKey.substring(0, 4);
  WiFi.mode(WIFI_AP_STA);  // STA side stays up so we can scan and keep retrying the home Wi-Fi
  WiFi.softAP(name.c_str(), SETUP_AP_PASSWORD);
  dns.start(53, "*", WiFi.softAPIP());  // captive portal: every name points to us
  apOn = true;
}

void stopAp() {
  if (!apOn) return;
  dns.stop();
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  apOn = false;
}

void startWifi() {
  prefs.begin("wifi", true);
  savedSsid = prefs.getString("ssid", "");
  savedPass = prefs.getString("pass", "");
  prefs.end();
  WiFi.setHostname("incubator");
  if (savedSsid.length()) {
    WiFi.mode(WIFI_STA);
    WiFi.begin(savedSsid.c_str(), savedPass.c_str());
  } else {
    startAp();
  }
}

// Every 10 s: open the setup hotspot while the home Wi-Fi is down, close it once connected.
void checkWifi() {
  if (!savedSsid.length()) return;
  if (WiFi.isConnected()) {
    if (apOn && WiFi.softAPgetStationNum() == 0) stopAp();
  } else {
    if (!apOn && millis() > 20000) startAp();
    if (++wifiRetry % 3 == 0) {  // give each attempt ~30 s before starting over
      WiFi.disconnect();
      WiFi.begin(savedSsid.c_str(), savedPass.c_str());
    }
  }
}

// ---- Cloud ------------------------------------------------------------------------
void pushCloud() {
  if (!strlen(CLOUD_URL) || !WiFi.isConnected()) {
    cloudOk = false;
    return;
  }
  JsonDocument body;
  body["p_key"] = deviceKey;
  body["p_ack"] = cmdAck;
  JsonDocument st;
  buildState(st, false);
  body["p_state"] = st;
  String out;
  serializeJson(body, out);

  WiFiClientSecure tls;
  tls.setInsecure();  // low-value data; avoids shipping a CA bundle that expires
  HTTPClient http;
  http.setTimeout(6000);
  if (!http.begin(tls, String(CLOUD_URL) + "/rest/v1/rpc/incubator_push")) {
    cloudOk = false;
    return;
  }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", CLOUD_KEY);
  int code = http.POST(out);
  cloudOk = code == 200;
  if (cloudOk) {
    JsonDocument res;
    if (!deserializeJson(res, http.getString())) {
      int64_t id = res["cmd_id"] | (int64_t)0;
      if (id > cmdAck && res["cmd"].is<JsonObjectConst>()) applyPatch(res["cmd"].as<JsonObjectConst>());
      if (id > cmdAck) cmdAck = id;
    }
  }
  http.end();
}

// ---- Web server ---------------------------------------------------------------------
void sendJson(JsonDocument &doc, int code = 200) {
  String out;
  serializeJson(doc, out);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "application/json", out);
}

void handleState() {
  JsonDocument doc;
  buildState(doc, true);
  sendJson(doc);
}

void handleSettings() {
  JsonDocument p;
  if (deserializeJson(p, server.arg("plain")) || !p.is<JsonObject>()) {
    server.send(400, "text/plain", "bad json");
    return;
  }
  applyPatch(p.as<JsonObjectConst>());
  control();
  handleState();
}

void handleHistory() {
  JsonDocument doc;
  doc["step"] = 300;
  JsonArray t = doc["t"].to<JsonArray>(), h = doc["h"].to<JsonArray>();
  for (int i = 0; i < histCount; i++) {
    int idx = (histHead - histCount + i + HIST_N) % HIST_N;
    t.add(histT[idx] / 10.0);
    h.add(histH[idx] / 10.0);
  }
  sendJson(doc);
}

void saveWifi(const String &ssid, const String &pass) {
  prefs.begin("wifi", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
}

void handleWifiApi() {
  JsonDocument p;
  if (deserializeJson(p, server.arg("plain")) || !p["ssid"].is<const char *>()) {
    server.send(400, "text/plain", "bad json");
    return;
  }
  saveWifi(p["ssid"].as<String>(), p["pass"] | "");
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", "{\"ok\":true}");
  delay(500);
  ESP.restart();
}

// Setup page for the captive portal: pick the home Wi-Fi from a browser.
void handleRoot() {
  String opts;
  int n = WiFi.scanNetworks();
  for (int i = 0; i < n && i < 15; i++) {
    String s = WiFi.SSID(i);
    s.replace("\"", "&quot;");
    opts += "<option value=\"" + s + "\">";
  }
  String t = sensorOk ? String(temp, 1) + " &deg;C &middot; " + String(hum, 0) + " %" : "Sensor not found";
  String html =
      "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
      "<title>Incubator</title><style>body{font:16px system-ui;max-width:420px;margin:24px auto;padding:0 16px}"
      "input,button{width:100%;padding:12px;margin:6px 0;box-sizing:border-box;font-size:16px}"
      "button{background:#e8833a;color:#fff;border:0;border-radius:8px}.big{font-size:32px;margin:8px 0 24px}</style>"
      "<h2>Incubator</h2><div class=big>" + t + "</div>"
      "<form method=post action=/wifi><b>Home Wi-Fi</b>"
      "<input name=ssid list=n placeholder='Wi-Fi name' value=\"" + savedSsid + "\"><datalist id=n>" + opts + "</datalist>"
      "<input name=pass type=password placeholder='Password'><button>Connect</button></form>";
  server.send(200, "text/html", html);
}

void handleWifiForm() {
  saveWifi(server.arg("ssid"), server.arg("pass"));
  server.send(200, "text/html",
              "<meta name=viewport content='width=device-width'><p style='font:18px system-ui;padding:24px'>"
              "Saved. The incubator is joining your Wi-Fi.<br><br>Reconnect your phone to your home Wi-Fi and open the app.");
  delay(800);
  ESP.restart();
}

void setupServer() {
  server.on("/", HTTP_GET, handleRoot);
  server.on("/wifi", HTTP_POST, handleWifiForm);
  server.on("/api/state", HTTP_GET, handleState);
  server.on("/api/settings", HTTP_POST, handleSettings);
  server.on("/api/history", HTTP_GET, handleHistory);
  server.on("/api/wifi", HTTP_POST, handleWifiApi);
  server.onNotFound([] {
    if (apOn) {  // captive portal: send phones to the setup page
      server.sendHeader("Location", "http://192.168.4.1/");
      server.send(302, "text/plain", "");
    } else {
      server.send(404, "text/plain", "not found");
    }
  });
  server.begin();
}

// ---- Main ---------------------------------------------------------------------------
void setup() {
  pinMode(PIN_LAMP, OUTPUT);
  pinMode(PIN_FAN, OUTPUT);
  setRelay(PIN_LAMP, false);
  setRelay(PIN_FAN, false);
  Serial.begin(115200);
  dht.begin();
  loadSettings();
  Serial.printf("\nIncubator fw %d, device key %s\n", FW_VERSION, deviceKey.c_str());
  startWifi();
  setupServer();
}

void loop() {
  server.handleClient();
  if (apOn) dns.processNextRequest();
  unsigned long now = millis();

  if (now - lastRead >= 2500) {
    lastRead = now;
    readSensor();
    control();
  }
  if (now - lastHist >= 300000UL || lastHist == 0) {
    lastHist = now;
    recordHistory();
  }
  if (now - lastWifiCheck >= 10000) {
    lastWifiCheck = now;
    checkWifi();
  }
  if (now - lastPush >= 20000 || lastPush == 0) {
    lastPush = now;
    pushCloud();
  }
}
