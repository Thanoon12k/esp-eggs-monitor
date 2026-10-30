#pragma once

// ---- Wiring ---------------------------------------------------------------
#define PIN_DHT 4          // DHT22 data pin (10k pull-up to 3.3V if your module has none)
#define PIN_LAMP 26        // relay 1: heat lamp
#define PIN_FAN 27         // relay 2: fan
#define RELAY_ACTIVE_LOW 1 // most blue relay boards switch ON when the pin is LOW

// ---- Setup Wi-Fi (shown when the incubator is not on your home Wi-Fi) ------
#define SETUP_AP_PASSWORD "incubator"   // at least 8 characters

// ---- Cloud (watch from anywhere) -------------------------------------------
// Public values: the project URL and its publishable key. Leave CLOUD_URL empty for local-only.
#define CLOUD_URL "https://axncazensmjdqpczvzwf.supabase.co"
#define CLOUD_KEY "sb_publishable_7hGIGHFa1mcWPMI8mEZKGw_-wgkkSYT"

// ---- Safety ---------------------------------------------------------------
#define MAX_TEMP 39.5      // lamp is forced off at or above this, whatever the mode
