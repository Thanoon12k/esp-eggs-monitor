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
| Power LED (always on) | GPIO 16 |
| DHT22 data (10 kΩ pull-up to 3.3 V if the module has none) | GPIO 17 |
| Relay 1 IN → heat lamp | GPIO 21 |
| Relay 2 IN → fan | GPIO 22 |
| DHT22 VCC / relay VCC | 3.3 V / 5 V (VIN) |
| GND | GND |

Pins and relay polarity are in `firmware/config.py`. **The lamp runs on mains power: wire the relay's
COM/NO contacts in the lamp's live wire, keep mains wiring enclosed, and never touch it while plugged in.**
Put the DHT22 at egg height, away from the direct heat of the lamp.

Safety built in: the lamp turns off if the sensor stops answering, and at 39.5 °C whatever the mode.

## Put the program on the ESP32 (no Arduino needed)

The ESP32 runs MicroPython. You need only Python on the computer (python.org, tick "Add python.exe to PATH").

1. Download this repo (Code → Download ZIP) and open the `firmware` folder.
2. Plug the ESP32 with a data USB cable and double-click **`START.bat`**.
3. Optional: type your home Wi-Fi name and password.
4. Press **Install on ESP32**. The first time it downloads about 7 MB in total (tools + MicroPython)
   and takes about 2 minutes. "Failed to connect"? Hold the **BOOT** button and press Install again.

After changing `config.py`, press **Update code only** (a few seconds). **Show board output** prints the
temperature, Wi-Fi and cloud status once a minute.

## First setup

1. If you did not type the Wi-Fi in the installer: power the incubator, join the Wi-Fi called
   **Incubator-xxxx** (password `incubator`) from the phone; a setup page opens. Pick your home Wi-Fi.
2. On the home Wi-Fi, open the app and tap **Find incubator**.

To watch from more phones: on the same Wi-Fi tap **Find incubator**, or copy the **device key** from
Menu → Connection and use **Enter device key** on the other phone. Any number of phones can watch at once.

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
| `firmware/` | ESP32 program (MicroPython), `config.py` = pins and cloud, `START.bat` = installer |
| `lib/` | Flutter app |
| `supabase/incubator.sql` | Cloud tables and functions |
| `tool/make_icon.py` | Draws the app icon and Android launcher icons |
