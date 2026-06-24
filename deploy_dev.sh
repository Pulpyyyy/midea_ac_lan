#!/usr/bin/env bash
# Midea DEV deploy — installs all in-progress features (E2 Memo U/Sterilization,
# FR, AC min/max + B5 auto-capabilities) from the `dev` branches, then restarts HA.
# Run inside the SSH add-on terminal (Protection mode OFF for the midealocal part).
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
AC_RAW="https://raw.githubusercontent.com/Pulpyyyy/midea_ac_lan/dev/custom_components/midea_ac_lan"
LIB_RAW="https://raw.githubusercontent.com/Pulpyyyy/midea-local/dev/midealocal/devices"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32mOK\033[0m %s\n' "$*"; }
ko()  { printf '  \033[31mKO\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
say "1) Integration files (/config)"
CC="/config/custom_components/midea_ac_lan"
if [ ! -d "$CC" ]; then
  CC="$(find / -type d -path '*/custom_components/midea_ac_lan' 2>/dev/null | head -n1 || true)"
fi
[ -d "$CC" ] || { ko "midea_ac_lan custom_component not found"; exit 1; }
echo "  dir: $CC"

put() {  # url dest
  if [ -f "$2" ]; then cp -a "$2" "$2.bak.$TS"; fi
  curl -fsSL "$1" -o "$2" && ok "$(basename "$2")"
}
put "$AC_RAW/midea_devices.py"      "$CC/midea_devices.py"
put "$AC_RAW/climate.py"            "$CC/climate.py"
put "$AC_RAW/translations/en.json"  "$CC/translations/en.json"
put "$AC_RAW/translations/fr.json"  "$CC/translations/fr.json"

if python3 -c "import json,sys;[json.load(open(p)) for p in sys.argv[1:]]" \
     "$CC/translations/en.json" "$CC/translations/fr.json" 2>/dev/null; then
  ok "translations JSON valid"
else
  ko "translations JSON invalid — check files"; exit 1
fi

# ---------------------------------------------------------------------------
say "2) midea-local library (homeassistant core container)"
if ! command -v docker >/dev/null 2>&1 || \
   ! docker exec homeassistant python3 -c "import midealocal" >/dev/null 2>&1; then
  ko "docker / core container not reachable."
  echo "  -> Enable 'Protection mode = OFF' on the SSH add-on, then re-run."
  echo "  -> Integration files are already deployed; lib part skipped."
  exit 1
fi

VER="$(docker exec homeassistant python3 -c \
  'from importlib.metadata import version;print(version("midea-local"))' | tr -d '\r')"
echo "  midea-local installed: $VER"
if [ "$VER" != "6.8.0" ]; then
  ko "expected 6.8.0, found $VER — aborting to avoid version mismatch."
  exit 1
fi

LIB="$(docker exec homeassistant python3 -c \
  'import midealocal,os;print(os.path.dirname(midealocal.__file__))' | tr -d '\r')"
echo "  lib dir: $LIB"

putlib() {  # url rel
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp"
  docker exec homeassistant sh -c "cp -a '$LIB/$2' '$LIB/$2.bak.$TS' 2>/dev/null || true"
  docker cp "$tmp" "homeassistant:$LIB/$2"
  rm -f "$tmp"
  ok "$2"
}
putlib "$LIB_RAW/e2/__init__.py" "devices/e2/__init__.py"
putlib "$LIB_RAW/e2/message.py"  "devices/e2/message.py"
putlib "$LIB_RAW/ac/__init__.py" "devices/ac/__init__.py"
putlib "$LIB_RAW/ac/message.py"  "devices/ac/message.py"

# ---------------------------------------------------------------------------
say "3) Restart Home Assistant"
if command -v ha >/dev/null 2>&1; then
  ha core restart
else
  docker restart homeassistant
fi

printf '\n\033[1;32mDONE\033[0m — backups: *.bak.%s\n' "$TS"
echo "After restart: E2 -> tick 'Sterilization' + 'Memo U' in Configure."
echo "PAC -> hvac_modes auto = [off, cool, dry, fan_only], no swing, 17-30 (no customize needed)."
