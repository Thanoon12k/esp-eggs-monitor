# Incubator settings. Edit, then press "Update code" in the installer.

# ---- Wiring (ESP32 GPIO numbers) ----
PIN_LED = 16            # power indicator, always on
PIN_DHT = 17            # DHT22 data
PIN_LAMP = 21           # relay 1: heat lamp
PIN_FAN = 22            # relay 2: fan
RELAY_ACTIVE_LOW = True # relay switches ON when the pin is LOW

# ---- Setup Wi-Fi (opens when the incubator is not on your home Wi-Fi) ----
SETUP_AP_PASSWORD = "incubator"   # at least 8 characters

# ---- Cloud (watch from anywhere). Public values; set CLOUD_URL = "" for home Wi-Fi only ----
CLOUD_URL = "https://axncazensmjdqpczvzwf.supabase.co"
CLOUD_KEY = "sb_publishable_7hGIGHFa1mcWPMI8mEZKGw_-wgkkSYT"

# ---- Safety ----
MAX_TEMP = 39.5         # lamp is forced off at or above this, whatever the mode
