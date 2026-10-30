# Egg incubator controller (MicroPython on ESP32).
# Keeps the eggs at the target temperature on its own (DHT22, heat lamp and fan relays),
# serves a small JSON API on the home Wi-Fi for the phone app, opens a setup Wi-Fi with a
# captive page when it has no home Wi-Fi, and reports to the cloud so the app works anywhere.

import asyncio
import gc
import json
import os
import socket
import time

import dht
import machine
import network
from machine import Pin

import config

FW = 2

# ---- Outputs: everything off until the first reading ----
Pin(config.PIN_LED, Pin.OUT).value(1)
lamp_pin = Pin(config.PIN_LAMP, Pin.OUT)
fan_pin = Pin(config.PIN_FAN, Pin.OUT)


def relay(pin, on):
    pin.value((not on) if config.RELAY_ACTIVE_LOW else on)


relay(lamp_pin, False)
relay(fan_pin, False)
sensor = dht.DHT22(Pin(config.PIN_DHT))


# ---- Files ----
def load(name, default):
    try:
        with open(name) as f:
            return json.load(f)
    except Exception:
        return default


def save(name, obj):
    with open(name, "w") as f:
        json.dump(obj, f)


cfg = {"species": "chicken", "start": 0, "turned": 0, "t_target": 37.5,
       "h_min": 50, "h_max": 55, "lamp": "auto", "fan": "on"}
cfg.update(load("settings.json", {}))
key = load("key.json", "")
if len(key) < 16:
    key = "".join("%02x" % b for b in os.urandom(16))
    save("key.json", key)
wifi = load("wifi.json", {})

# ---- Live state ----
state = {"t": None, "h": None, "ok": False, "lamp": False, "fan": False}
fails = 0
last_switch = None
cmd_ack = 0
cloud_ok = False
hist_t, hist_h = [], []
HIST_N = 288          # 24 h at one reading per 5 min
reset_at = None


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def apply_patch(p):
    """Partial settings from the app (local or cloud). Unknown keys are ignored."""
    global last_switch
    if not isinstance(p, dict):
        return
    if isinstance(p.get("species"), str):
        cfg["species"] = p["species"][:12]
    for k in ("start", "turned"):
        if is_num(p.get(k)) and p[k] >= 0:
            cfg[k] = int(p[k])
    for k, lo, hi in (("t_target", 30, 39), ("h_min", 20, 90), ("h_max", 20, 95)):
        if is_num(p.get(k)):
            cfg[k] = max(lo, min(hi, float(p[k])))
    for k in ("lamp", "fan"):
        if p.get(k) in ("auto", "on", "off"):
            cfg[k] = p[k]
    save("settings.json", cfg)
    last_switch = None  # react right away


def build_state(with_key):
    ok = state["ok"]
    s = {
        "t": state["t"] if ok else None,
        "h": state["h"] if ok else None,
        "ok": ok,
        "lamp": state["lamp"],
        "fan": state["fan"],
        "ip": sta.ifconfig()[0] if sta.isconnected() else "",
        "rssi": sta.status("rssi") if sta.isconnected() else 0,
        "up": time.ticks_ms() // 1000,
        "cloud": cloud_ok,
        "fw": FW,
        "s": cfg,
    }
    if with_key:
        s["key"] = key
    return s


# ---- Control ----
def read_sensor():
    global fails
    try:
        sensor.measure()
        state["t"] = round(sensor.temperature(), 1)
        state["h"] = round(sensor.humidity(), 1)
        state["ok"] = True
        fails = 0
    except Exception:
        fails += 1
        if fails >= 3:
            state["ok"] = False


def control():
    global last_switch
    ok, t, target = state["ok"], state["t"], cfg["t_target"]
    too_hot = ok and t >= config.MAX_TEMP

    # Lamp: thermostat with a small band so the relay does not chatter.
    lamp = state["lamp"]
    mode = cfg["lamp"]
    if mode == "on":
        lamp = True
    elif mode == "off":
        lamp = False
    elif not ok:
        lamp = False  # no reading: never heat blind
    elif t <= target - 0.2:
        lamp = True
    elif t >= target + 0.2:
        lamp = False
    if too_hot:
        lamp = False
    now = time.ticks_ms()
    if lamp != state["lamp"] and (last_switch is None or time.ticks_diff(now, last_switch) > 5000):
        state["lamp"] = lamp
        last_switch = now

    # Fan: always on / off, or auto = only when too hot.
    fan = state["fan"]
    mode = cfg["fan"]
    if mode == "on":
        fan = True
    elif mode == "off":
        fan = False
    elif ok and t >= target + 0.6:
        fan = True
    elif not ok or t <= target + 0.2:
        fan = False
    if too_hot:
        fan = True
    state["fan"] = fan

    relay(lamp_pin, state["lamp"])
    relay(fan_pin, fan)


def record_history():
    if not state["ok"]:
        return
    hist_t.append(state["t"])
    hist_h.append(state["h"])
    if len(hist_t) > HIST_N:
        hist_t.pop(0)
        hist_h.pop(0)


# ---- Wi-Fi ----
try:
    network.hostname("incubator")
except Exception:
    pass
sta = network.WLAN(network.STA_IF)
ap = network.WLAN(network.AP_IF)
sta.active(True)
retry = 0


def start_ap():
    if ap.active():
        return
    ap.active(True)
    name = "Incubator-" + key[:4]
    try:
        ap.config(ssid=name, key=config.SETUP_AP_PASSWORD, security=3)
    except Exception:
        ap.config(essid=name, password=config.SETUP_AP_PASSWORD, authmode=3)
    print("Setup Wi-Fi:", name, "password:", config.SETUP_AP_PASSWORD)


def connect_wifi():
    if wifi.get("ssid"):
        try:
            sta.connect(wifi["ssid"], wifi.get("pass", ""))
        except Exception as e:
            print("wifi:", e)
    else:
        start_ap()


def check_wifi():
    """Every 10 s: open the setup Wi-Fi while the home Wi-Fi is down, close it once connected."""
    global retry
    if not wifi.get("ssid"):
        return
    if sta.isconnected():
        if ap.active() and not ap.status("stations"):
            ap.active(False)
    else:
        if time.ticks_ms() > 20000:
            start_ap()
        retry += 1
        if retry % 3 == 0:  # give each attempt ~30 s
            try:
                sta.disconnect()
                sta.connect(wifi["ssid"], wifi.get("pass", ""))
            except Exception:
                pass


# ---- Cloud ----
def push_cloud():
    global cloud_ok, cmd_ack
    if not config.CLOUD_URL or not sta.isconnected():
        cloud_ok = False
        return
    try:
        import requests
        body = json.dumps({"p_key": key, "p_ack": cmd_ack, "p_state": build_state(False)})
        r = requests.post(config.CLOUD_URL + "/rest/v1/rpc/incubator_push", data=body, timeout=8,
                          headers={"Content-Type": "application/json", "apikey": config.CLOUD_KEY})
        cloud_ok = r.status_code == 200
        if cloud_ok:
            res = r.json()
            cid = res.get("cmd_id", 0)
            if cid > cmd_ack:
                if isinstance(res.get("cmd"), dict):
                    apply_patch(res["cmd"])
                cmd_ack = cid
        r.close()
    except Exception as e:
        print("cloud:", e)
        cloud_ok = False
    gc.collect()


# ---- Captive-portal DNS: every name points at the setup page ----
def dns_reply(q):
    end = 12
    while end < len(q) and q[end] != 0:
        end += q[end] + 1
    question = q[12:end + 5]
    ip = bytes(int(x) for x in ap.ifconfig()[0].split("."))
    return (q[:2] + b"\x81\x80" + b"\x00\x01\x00\x01\x00\x00\x00\x00" + question
            + b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + ip)


async def dns_task():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", 53))
    s.setblocking(False)
    while True:
        await asyncio.sleep_ms(50)
        try:
            data, addr = s.recvfrom(512)
            if ap.active() and len(data) > 12:
                s.sendto(dns_reply(data), addr)
        except OSError:
            pass


# ---- Web server ----
def unquote(s):
    s = s.replace("+", " ")
    out = bytearray()
    i = 0
    b = s.encode()
    while i < len(b):
        if b[i] == 37 and i + 2 < len(b):  # %
            out.append(int(b[i + 1:i + 3], 16))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return out.decode()


def form(body):
    d = {}
    for part in body.decode().split("&"):
        if "=" in part:
            k, v = part.split("=", 1)
            d[unquote(k)] = unquote(v)
    return d


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")


def setup_page():
    try:
        names = sorted(set(n[0].decode() for n in sta.scan() if n[0]))[:15]
    except Exception:
        names = []
    opts = "".join('<option value="%s">' % esc(n) for n in names)
    t = "%.1f &deg;C &middot; %d %%" % (state["t"], state["h"]) if state["ok"] else "Sensor not found"
    return ("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>Incubator</title><style>body{font:16px system-ui;max-width:420px;margin:24px auto;padding:0 16px}"
            "input,button{width:100%;padding:12px;margin:6px 0;box-sizing:border-box;font-size:16px}"
            "button{background:#e8833a;color:#fff;border:0;border-radius:8px}.big{font-size:32px;margin:8px 0 24px}</style>"
            "<h2>Incubator</h2><div class=big>" + t + "</div>"
            "<form method=post action=/wifi><b>Home Wi-Fi</b>"
            "<input name=ssid list=n placeholder='Wi-Fi name' value=\"" + esc(wifi.get("ssid", "")) + "\">"
            "<datalist id=n>" + opts + "</datalist>"
            "<input name=pass type=password placeholder='Password'><button>Connect</button></form>")


def save_wifi(ssid, pw):
    global reset_at
    save("wifi.json", {"ssid": ssid, "pass": pw})
    reset_at = time.ticks_add(time.ticks_ms(), 1500)


def route(method, path, body):
    """Returns (status, content type, body text)."""
    if path == "/api/state":
        return 200, "application/json", json.dumps(build_state(True))
    if path == "/api/settings" and method == "POST":
        try:
            apply_patch(json.loads(body))
        except ValueError:
            return 400, "text/plain", "bad json"
        control()
        return 200, "application/json", json.dumps(build_state(True))
    if path == "/api/history":
        return 200, "application/json", json.dumps({"step": 300, "t": hist_t, "h": hist_h})
    if path == "/api/wifi" and method == "POST":
        try:
            p = json.loads(body)
            save_wifi(p["ssid"], p.get("pass", ""))
        except Exception:
            return 400, "text/plain", "bad json"
        return 200, "application/json", '{"ok":true}'
    if path == "/wifi" and method == "POST":
        f = form(body)
        save_wifi(f.get("ssid", ""), f.get("pass", ""))
        return 200, "text/html", ("<meta name=viewport content='width=device-width'>"
                                  "<p style='font:18px system-ui;padding:24px'>Saved. The incubator is joining your Wi-Fi."
                                  "<br><br>Reconnect your phone to your home Wi-Fi and open the app.")
    if path == "/":
        return 200, "text/html", setup_page()
    if ap.active():  # captive portal: send phones to the setup page
        return 302, "text/plain", ""
    return 404, "text/plain", "not found"


async def handle(reader, writer):
    try:
        line = await reader.readline()
        method, path, _ = line.decode().split(" ", 2)
        length = 0
        while True:
            h = await reader.readline()
            if h in (b"\r\n", b""):
                break
            if h.lower().startswith(b"content-length:"):
                length = int(h[15:])
        body = await reader.readexactly(min(length, 2048)) if length else b""
        status, ctype, out = route(method, path.split("?")[0], body)
        head = "HTTP/1.0 %d OK\r\nContent-Type: %s\r\nAccess-Control-Allow-Origin: *\r\n" % (status, ctype)
        if status == 302:
            head += "Location: http://192.168.4.1/\r\n"
        data = out.encode()
        writer.write((head + "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(data)).encode())
        writer.write(data)
        await writer.drain()
    except Exception as e:
        print("http:", e)
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass
        gc.collect()


# ---- Main ----
async def main():
    print("Incubator fw %d, device key %s" % (FW, key))
    connect_wifi()
    asyncio.create_task(dns_task())
    await asyncio.start_server(handle, "0.0.0.0", 80)
    n = 0
    while True:
        try:
            read_sensor()
            control()
            if n % 120 == 0:      # every 5 min (loop runs every 2.5 s)
                record_history()
            if n % 4 == 0:        # 10 s
                check_wifi()
            if n % 8 == 0:        # 20 s
                push_cloud()
            if reset_at is not None and time.ticks_diff(time.ticks_ms(), reset_at) > 0:
                machine.reset()
            if n % 24 == 0:
                print("t=%s h=%s lamp=%s fan=%s wifi=%s cloud=%s" % (
                    state["t"], state["h"], state["lamp"], state["fan"],
                    sta.ifconfig()[0] if sta.isconnected() else "-", cloud_ok))
        except Exception as e:
            print("loop:", e)
        n += 1
        await asyncio.sleep_ms(2500)


try:
    asyncio.run(main())
except KeyboardInterrupt:
    relay(lamp_pin, False)  # stopped from the computer: leave everything safe
    relay(fan_pin, False)
    raise
except Exception as e:
    print("crash:", e)
    relay(lamp_pin, False)
    time.sleep(5)
    machine.reset()
