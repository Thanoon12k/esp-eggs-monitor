# Egg Incubator

An ESP32 keeps the eggs warm on its own; the phone app shows how they are doing and changes the settings,
on the home Wi-Fi or from anywhere over the internet.

<img src="icon.png" width="96" alt="">

## What it does

- **ESP32** reads a DHT22, switches the heat lamp to hold the target temperature (37.5 °C for chickens)
  and runs the fan. It keeps working with no phone and no internet.
- **App** — one main screen: status, temperature, humidity, incubation day, and a reminder to turn the
  eggs. Everything else (egg type, targets, lamp/fan modes, 24 h chart, connection, language) is under
  the menu. Arabic and English.
- **Connection** — on the home Wi-Fi the app talks to the ESP32 directly (every 3 s). Away from home it
  goes through the cloud (the ESP32 reports every 20 s; changes apply on its next report).

## Parts and wiring

| Part | ESP32 pin |
|---|---|
| DHT22 data (10 kΩ pull-up to 3.3 V if the module has none) | GPIO 4 |
| Relay 1 IN → heat lamp | GPIO 26 |
| Relay 2 IN → fan | GPIO 27 |
| DHT22 VCC / relay VCC | 3.3 V / 5 V (VIN) |
| GND | GND |

Pins and relay polarity are in `firmware/incubator/config.h` (`RELAY_ACTIVE_LOW` is 1 for the usual blue
relay boards). **The lamp runs on mains power: wire the relay's COM/NO contacts in the lamp's live wire,
keep mains wiring enclosed, and never touch it while plugged in.** Put the DHT22 at egg height, away
from the direct heat of the lamp.

Safety built in: the lamp turns off if the sensor stops answering, and at 39.5 °C whatever the mode.

## Flash the ESP32

1. Arduino IDE → Boards Manager → install **esp32** (Espressif, 3.x).
2. Library Manager → install **DHT sensor library** (Adafruit), **Adafruit Unified Sensor**, **ArduinoJson**.
3. Open `firmware/incubator/incubator.ino`, board **ESP32 Dev Module**, upload.

## First setup

1. Power the incubator. It opens a Wi-Fi called **Incubator-xxxx** (password `incubator`).
2. Join it from the phone; a setup page opens. Pick your home Wi-Fi and enter its password.
   (Or open the app and tap **Find** while on that Wi-Fi.)
3. Put the phone back on the home Wi-Fi, open the app, tap **Find incubator**.

To watch from a second phone, copy the **device key** from Menu → Connection and use **Enter device key**
on the other phone.

## Egg presets

| Egg | Days | Temp | Humidity | Last days (no turning) |
|---|---|---|---|---|
| Chicken | 21 | 37.5 °C | 50–55 % | from day 18, 65–70 % |
| Duck | 28 | 37.5 °C | 55–60 % | from day 25, 70–75 % |
| Quail | 18 | 37.5 °C | 45–50 % | from day 15, 65–70 % |
| Goose | 30 | 37.4 °C | 50–55 % | from day 27, 75–80 % |
| Turkey | 28 | 37.5 °C | 50–55 % | from day 25, 65–70 % |

The incubator controls temperature only. Raise humidity with a water tray, lower it by opening a vent.

## Project layout

| Path | What |
|---|---|
| `firmware/incubator/` | ESP32 sketch (`config.h` = pins, cloud) |
| `lib/` | Flutter app |
| `supabase/incubator.sql` | Cloud tables and functions |
| `tool/make_icon.py` | Draws the app icon and Android launcher icons |
