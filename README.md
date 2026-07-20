# Collecting Wi-Fi/BT diagnostics on a broken MLP1 — stock OS, no ADB, no Wi-Fi

Goal: get a broken unit (Wi-Fi scans but won't connect, BT discovers but
won't pair) to run a diagnostic script and hand us the output — **without needing ADB,
Wi-Fi, or any modification to the console's internal firmware.**


## What you need

- The console (any firmware; a first-batch broken unit is the target).
- The **games microSD card** (FAT32) you already use, or any FAT32 card.
- A computer with an SD reader to drop the script and later read the report.
- Nothing else. No solder, no ADB, no internet on the console.

- `WiFi-Diagnostic.sh` — the diagnostic (required)
- `wifi-test.txt` — optional; only if no network is saved yet (see below)

## Steps

1. **Insert the FAT32 SD card into the computer.** (Not exFAT, not NTFS — stock only
   reliably reads FAT32.)

2. **Create the folder** if it doesn't exist:

   ```
   <SD>/Roms/PORTS/
   ```

   (A top-level `<SD>/PORTS/` also works — both are valid stock scan paths. Use
   `Roms/PORTS` to match the standard layout.)

3. **Copy `WiFi-Diagnostic.sh` into that folder.** Do not rename the `.sh` extension.
   The visible name in the launcher will be `WiFi-Diagnostic`.

4. **(Optional) Reproduce the failure first.** In the stock **Settings → Wi-Fi** menu,
   select your 2.4 GHz network and enter the password as normal. On a broken unit this
   will fail to connect — that's fine and expected. Doing it means the network is now
   *saved*, and the diagnostic will replay that exact failed attempt and capture why.

   Only if you can't or don't want to do that: copy `wifi-test.txt` into the same
   `Roms/PORTS/` folder and edit `SSID=` and `PSK=` with your 2.4 GHz network details.

5. **Put the SD card back in the console and power on.**

6. **Open the PORTS system** in the launcher (it appears once a `.sh` is present) and
   **launch `WiFi-Diagnostic`.** The screen may go dark or show a few lines of text.
   It runs for a few seconds, or about 40 seconds if it is doing the connection test.
   When it finishes it prints:

   ```
   DONE. Power the console off and remove the SD card.
   ```

7. **Power the console off, take the SD card out, and put it back in the computer.**

8. **Send us the whole output folder:**

   ```
   <SD>/Roms/PORTS/wifi-diag-<timestamp>/
   ```

   It contains `report.txt` and `dmesg-full.txt` (plus copies of the wpa/messages logs).
   That folder is all we need.

## What the script collects (and why)

The report is structured so we can pin down which failure hypothesis holds — see
`findings.md` for the hypothesis ranking. Sections:

1. **System identity** — firmware version, kernel, cmdline. Tells us the exact
   first-batch build so we can compare against the fixed OTAs (1.2.0.98 / 1.3.0.32).
2. **Hardware + driver** — which combo chip (`024c:d723` = RTL8723DS, `024c:b733` =
   RTL8733BS), the driver's embedded **`version=` and BT-COEX** strings, firmware files
   present. The COEX snapshot is the prime suspect for "scans but won't connect + BT
   won't pair" and this is where we'd see if a bad build is loaded.
3. **RF-kill + interface state** — confirms power/rfkill isn't the blocker.
4. **Wi-Fi scan** — proves the radio sees APs.
5. **Connect attempt (the key test)** — forces a fresh association through the running
   `wpa_supplicant` with debug logging, then polls `wpa_state` every 2 s for 40 s and
   tries DHCP. This shows exactly where it dies: never associates vs. associates then
   fails the WPA2 4-way handshake (EAPOL timeout) vs. associates but DHCP never
   completes — three different root causes. It also captures the **dmesg produced
   during the attempt**, which is where coex/firmware errors surface.
6. **Bluetooth** — whether `rtk_hciattach` loaded the BT firmware and `hci0` came up;
   the mirror-image half of a shared-chip coex problem.
7. **Filtered + full kernel log** — everything wifi/bt/coex/sdio for offline analysis.

## Safety / reversibility

- The script only **reads** state. Its one active step is a one-shot Wi-Fi
  re-association to capture the failure; if it had to add a temporary network from
  `wifi-test.txt`, it removes it and runs `wpa_cli reconfigure` afterward, restoring the
  saved config. Nothing persists on internal storage except an optional convenience copy
  under `/userdata/wifi-diag-*` that a normal reboot leaves untouched and which can be
  ignored or deleted.
- All output lands on the removable SD card. Removing `WiFi-Diagnostic.sh` removes the
  launcher entry — the console returns to exactly its prior state.
- No ADB is enabled, no USB gadget mode is changed, no `/oem` or database edits are made.
  This is strictly less invasive than the ADB-unlock or `loong_upgrade` paths documented
  in `../../../Miniloong research/miniloong-pocket-1-sd-boot-hooks.md`.

## If the PORTS entry doesn't appear

- Confirm the card is FAT32 and the file is at `Roms/PORTS/WiFi-Diagnostic.sh` with a
  real `.sh` extension (Windows may hide it and save `WiFi-Diagnostic.sh.txt`).
- Some builds only rescan on boot — power-cycle with the card inserted.
- As a fallback the same script can be delivered through the stock `loong_upgrade`
  SD-update `otaCommand` path, but that is gated by version/hash checks and is much more
  fiddly; PORTS should be tried first.

