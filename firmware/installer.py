# Incubator installer: one window to put the incubator program on an ESP32.
# Start it by double-clicking START.bat (Windows) or: python installer.py
# Needs only Python; it installs esptool + mpremote + pyserial (~5 MB) and downloads
# MicroPython (~1.7 MB) the first time.

import importlib.util, json, os, queue, re, subprocess, sys, threading, time, urllib.request
import tkinter as tk
from tkinter import ttk, messagebox

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
SETTINGS = os.path.join(HERE, "installer_settings.json")
FW_PAGE = "https://micropython.org/download/ESP32_GENERIC/"
FW_FALLBACK = "https://micropython.org/resources/firmware/ESP32_GENERIC-20260824-v1.29.0.bin"
BOARD_FILES = ["config.py", "main.py"]

PY = sys.executable
if PY.lower().endswith("pythonw.exe"):
    PY = PY[:-5] + ".exe"
NOWIN = 0x08000000 if sys.platform == "win32" else 0
ENV = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
ORANGE = "#e8833a"


def have(mod):
    return importlib.util.find_spec(mod) is not None


def local_firmware():
    bins = sorted(f for f in os.listdir(HERE) if f.startswith("ESP32_GENERIC") and f.endswith(".bin"))
    return os.path.join(HERE, bins[-1]) if bins else None


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Incubator installer")
        self.geometry("640x560")
        self.minsize(560, 480)
        self.q = queue.Queue()
        self.busy = False
        self.proc = None
        self.serial_on = False
        try:
            self.s = json.load(open(SETTINGS))
        except Exception:
            self.s = {}

        pad = dict(padx=8, pady=6)
        tk.Label(self, text="Egg Incubator", font=("Segoe UI", 18, "bold")).pack(anchor="w", padx=16, pady=(14, 0))
        self.status = tk.Label(self, text="Plug the ESP32 by USB, then press Install.", font=("Segoe UI", 11),
                               fg="#555")
        self.status.pack(anchor="w", padx=16)

        f = ttk.Frame(self)
        f.pack(fill="x", padx=8, pady=(10, 0))
        ttk.Label(f, text="USB port").grid(row=0, column=0, sticky="w", **pad)
        self.port = ttk.Combobox(f, width=38, state="readonly")
        self.port.grid(row=0, column=1, columnspan=2, sticky="we", **pad)
        ttk.Button(f, text="Refresh", command=self.refresh_ports).grid(row=0, column=3, **pad)
        ttk.Label(f, text="Home Wi-Fi").grid(row=1, column=0, sticky="w", **pad)
        self.ssid = tk.StringVar(value=self.s.get("ssid", ""))
        self.pw = tk.StringVar(value=self.s.get("pass", ""))
        ttk.Entry(f, textvariable=self.ssid, width=20).grid(row=1, column=1, sticky="we", **pad)
        ttk.Label(f, text="Password").grid(row=1, column=2, sticky="e", **pad)
        ttk.Entry(f, textvariable=self.pw, width=16, show="•").grid(row=1, column=3, sticky="we", **pad)
        ttk.Label(f, text="Optional. Leave empty to set the Wi-Fi from your phone later.",
                  foreground="#777").grid(row=2, column=1, columnspan=3, sticky="w", padx=8)
        f.columnconfigure(1, weight=1)

        self.install_btn = tk.Button(self, text="Install on ESP32", font=("Segoe UI", 13, "bold"), bg=ORANGE,
                                     fg="white", activebackground="#cf6f2a", relief="flat", height=2,
                                     command=self.install)
        self.install_btn.pack(fill="x", padx=16, pady=(14, 6))
        row = ttk.Frame(self)
        row.pack(fill="x", padx=12)
        self.update_btn = ttk.Button(row, text="Update code only (fast)", command=self.update_code)
        self.update_btn.pack(side="left", expand=True, fill="x", padx=4)
        self.watch_btn = ttk.Button(row, text="Show board output", command=self.toggle_watch)
        self.watch_btn.pack(side="left", expand=True, fill="x", padx=4)
        ttk.Button(row, text="Stop", command=self.stop).pack(side="left", padx=4)

        self.log = tk.Text(self, bg="#14181f", fg="#d8dee9", insertbackground="white", font=("Consolas", 9),
                           wrap="word", relief="flat")
        self.log.pack(fill="both", expand=True, padx=16, pady=12)
        self.log.tag_config("ok", foreground="#7fd47f")
        self.log.tag_config("bad", foreground="#ff7b72")
        self.log.tag_config("head", foreground="#f0b35a")

        self.after(80, self.pump)
        self.refresh_ports()

    # ---------------------------------------------------------------- helpers
    def pump(self):
        try:
            for _ in range(200):  # bounded, so a flood of output cannot freeze the window
                text, tag = self.q.get_nowait()
                parts = text.replace("\r\n", "\n").split("\r")
                self.log.insert("end", parts[0], tag)
                for part in parts[1:]:  # carriage return: esptool rewrites its progress line
                    self.log.delete("end-1c linestart", "end-1c")
                    self.log.insert("end", part, tag)
                self.log.see("end")
        except queue.Empty:
            pass
        self.after(80, self.pump)

    def say(self, text, tag=None):
        self.q.put((text + "\n", tag))

    def set_status(self, text, color="#555"):
        self.after(0, lambda: self.status.config(text=text, fg=color))

    def set_busy(self, b):
        self.busy = b
        self.install_btn.config(state="disabled" if b else "normal")
        self.update_btn.state(["disabled"] if b else ["!disabled"])

    def save(self):
        self.s.update(ssid=self.ssid.get().strip(), port=self.port_dev() or "")
        self.s["pass"] = self.pw.get()
        try:
            json.dump(self.s, open(SETTINGS, "w"))
        except Exception:
            pass

    def port_dev(self):
        v = self.port.get()
        return v.split(" ")[0] if v else None

    def refresh_ports(self):
        try:
            from serial.tools import list_ports
            ports = ["%s  -  %s" % (p.device, p.description) for p in list_ports.comports()]
        except Exception:
            ports = []
            self.say("(port list needs pyserial - it is installed with the first Install)")
        self.port["values"] = ports
        if ports:
            prev = [x for x in ports if x.split(" ")[0] == self.s.get("port")]
            usb = [x for x in ports if any(k in x for k in ("CP210", "CH340", "CH910", "USB"))]
            self.port.set((prev or usb or ports)[0])
        else:
            self.port.set("")

    def run(self, title, cmd):
        """Runs one command, streaming its output to the log. Returns (exit code, output)."""
        self.say("\n>>> " + title, "head")
        out = ""
        try:
            self.proc = subprocess.Popen(cmd, cwd=HERE, env=ENV, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, creationflags=NOWIN)
        except Exception as e:
            self.say("Could not start: %s" % e, "bad")
            return -1, ""
        while True:
            chunk = self.proc.stdout.read1(512) if hasattr(self.proc.stdout, "read1") else self.proc.stdout.read(64)
            if not chunk:
                break
            txt = chunk.decode("utf-8", "replace")
            out += txt
            self.q.put((txt, None))
        rc = self.proc.wait()
        self.proc = None
        return rc, out

    def explain(self, out):
        low = out.lower()
        if "failed to connect" in low or "no serial data" in low:
            self.say("Hold the BOOT button on the ESP32, press Install again, and let go of BOOT when "
                     "you see 'Connecting...'.", "bad")
        elif "could not open port" in low or "permissionerror" in low or "access is denied" in low:
            self.say("The port is busy: close other programs using it, or unplug and plug the board again.", "bad")
        elif "could not enter raw repl" in low:
            self.say("The board did not answer. Press the EN/RST button on the board and try again.", "bad")

    # ---------------------------------------------------------------- steps
    def ensure_tools(self):
        if all(have(m) for m in ("esptool", "mpremote", "serial")):
            return True
        rc, _ = self.run("Installing tools (esptool, mpremote, pyserial - about 5 MB)",
                         [PY, "-m", "pip", "install", "--upgrade", "esptool", "mpremote", "pyserial"])
        importlib.invalidate_caches()
        return rc == 0

    def ensure_firmware(self):
        fw = local_firmware()
        if fw:
            return fw
        self.say("\n>>> Downloading MicroPython for ESP32 (about 1.7 MB)", "head")
        url = FW_FALLBACK
        try:
            html = urllib.request.urlopen(FW_PAGE, timeout=15).read().decode("utf-8", "replace")
            found = re.findall(r"/resources/firmware/(ESP32_GENERIC-(\d{8})-v[\d.]+\.bin)", html)
            if found:
                url = "https://micropython.org/resources/firmware/" + max(found, key=lambda x: x[1])[0]
        except Exception:
            pass
        dest = os.path.join(HERE, url.rsplit("/", 1)[1])
        try:
            urllib.request.urlretrieve(url, dest)
        except Exception as e:
            self.say("Download failed: %s\nDownload the .bin from %s into this folder and press Install again."
                     % (e, FW_PAGE), "bad")
            return None
        self.say("Saved " + os.path.basename(dest), "ok")
        return dest

    def upload(self, p, ssid, pw):
        cmd = [PY, "-m", "mpremote", "connect", p]
        for f in BOARD_FILES:
            cmd += ["cp", f, ":" + f, "+"]
        if ssid:
            cmd += ["exec", "open('wifi.json','w').write(%r)" % json.dumps({"ssid": ssid, "pass": pw}), "+"]
        cmd += ["reset"]
        for attempt in range(3):
            rc, out = self.run("Uploading the incubator program", cmd)
            if rc == 0 or "could not enter raw repl" not in out.lower():
                break
            self.say("Board is starting - trying again in 3 s...")
            time.sleep(3)
        if rc != 0:
            self.explain(out)
        return rc == 0

    def job(self, steps):
        if self.busy:
            return
        p = self.port_dev()
        ssid, pw = self.ssid.get().strip(), self.pw.get()
        if not p and have("serial"):
            messagebox.showwarning("No board", "Plug the ESP32 with a data USB cable and press Refresh.\n\n"
                                   "Nothing shows up? Install the CP210x or CH340 USB driver.")
            return
        self.save()
        self.stop_watch()
        self.set_busy(True)
        self.log.delete("1.0", "end")

        def work():
            try:
                ok = steps(p, ssid, pw)
            except Exception as e:
                self.say("Error: %s" % e, "bad")
                ok = False
            if ok:
                self.say("\nDone! The incubator is running.", "ok")
                self.set_status("Done! " + ("It joins %s now. Open the app and tap Find incubator." % ssid
                                            if ssid else
                                            "On your phone, join the Wi-Fi 'Incubator-...' (password: incubator)."),
                                "#208030")
            else:
                self.set_status("Stopped - read the red lines below.", "#c03030")
            self.after(0, lambda: self.set_busy(False))
        threading.Thread(target=work, daemon=True).start()

    def install(self):
        def steps(p, ssid, pw):
            self.set_status("1/4  Getting tools ready...")
            if not self.ensure_tools():
                return False
            if not p:  # pyserial was just installed: look for the board now
                from serial.tools import list_ports
                found = [x.device for x in list_ports.comports()]
                self.after(0, self.refresh_ports)
                p = found[0] if len(found) == 1 else None
                if not p:
                    self.say("Pick the board's USB port at the top and press Install again.", "bad")
                    return False
            fw = self.ensure_firmware()
            if not fw:
                return False
            self.set_status("2/4  Erasing the ESP32...")
            rc, out = self.run("Erasing the ESP32", [PY, "-m", "esptool", "--chip", "esp32", "--port", p, "erase-flash"])
            if rc != 0:
                self.explain(out)
                return False
            self.set_status("3/4  Installing MicroPython (about 1 minute)...")
            rc, out = self.run("Installing MicroPython", [PY, "-m", "esptool", "--chip", "esp32", "--port", p,
                                                          "--baud", "460800", "write-flash", "-z", "0x1000", fw])
            if rc != 0:
                self.explain(out)
                return False
            self.say("waiting 5 s for the board to start...")
            time.sleep(5)
            self.set_status("4/4  Uploading the incubator program...")
            return self.upload(p, ssid, pw)
        self.job(steps)

    def update_code(self):
        def steps(p, ssid, pw):
            self.set_status("Uploading the incubator program...")
            return self.ensure_tools() and self.upload(p, ssid, pw)
        self.job(steps)

    def stop(self):
        if self.proc:
            self.proc.kill()
            self.say("Stopped.", "bad")
        self.stop_watch()

    # ---------------------------------------------------------------- board output
    def toggle_watch(self):
        if self.serial_on:
            self.stop_watch()
            return
        p = self.port_dev()
        if not p or self.busy:
            return
        try:
            import serial
            ser = serial.Serial()
            ser.port, ser.baudrate, ser.timeout = p, 115200, 0.3
            ser.dtr = False
            ser.rts = False  # do not reset the board
            ser.open()
        except Exception as e:
            self.say("Cannot open %s: %s" % (p, e), "bad")
            return
        self.serial_on = True
        self.watch_btn.config(text="Stop board output")
        self.say("\n>>> Board output (temperature, Wi-Fi, cloud every minute)", "head")

        def work():
            while self.serial_on:
                try:
                    data = ser.read(256)
                except Exception as e:
                    self.say("Serial closed: %s" % e, "bad")
                    break
                if data:
                    self.q.put((data.decode("utf-8", "replace"), None))
            ser.close()
            self.serial_on = False
            self.after(0, lambda: self.watch_btn.config(text="Show board output"))
        threading.Thread(target=work, daemon=True).start()

    def stop_watch(self):
        self.serial_on = False


if __name__ == "__main__":
    App().mainloop()
