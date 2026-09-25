# shellcheck shell=bash
# Every upstream fact this tool depends on, in one place. When upstream moves,
# this is the file to change — and `omarchy-bootstrap sources --check` is how
# to find out that it has. Nothing here is switched automatically.

SOURCES_VERIFIED_ON="2026-09-24"

# --- Asahi Alarm (macOS side) ------------------------------------------------
ASAHI_ALARM_INSTALLER_URL="https://asahi-alarm.org/installer-bootstrap.sh"
ASAHI_ALARM_VERSION_URL="https://asahi-alarm.org/latest"
ASAHI_ALARM_DATA_URL="https://asahi-alarm.org/installer_data.json"
ASAHI_ALARM_HOME="https://asahi-alarm.org/"
ASAHI_ALARM_OS_CHOICE="Asahi Alarm Minimal (BTRFS)"
ASAHI_ALARM_FIRST_LOGIN="root / root"
ASAHI_INSTALLER_VERIFIED="v0.9.2"
ASAHI_MIN_MACOS="13.5"

# asahi-installer src/main.py (v0.9.2)
ASAHI_MIN_FREE_OS_BYTES=38000000000   # MIN_FREE_OS: kept free for macOS upgrades
ASAHI_STUB_BYTES=2500000000           # STUB_SIZE: the boot "stub macOS" container
ASAHI_EFI_BYTES=524288000             # EFI partition in the Alarm templates
ASAHI_MIN_INSTALL_FREE_BYTES=10000000000
ASAHI_OVERHEAD_WARN_BYTES=16000000000 # installer warns above this overhead
ASAHI_PART_ALIGN=1048576

# --- Asahi documentation --------------------------------------------------------
ASAHI_DOCS_FAQ="https://asahilinux.org/docs/project/faq/"
ASAHI_DOCS_FAQ_RAW="https://raw.githubusercontent.com/AsahiLinux/docs/main/docs/project/faq.md"
ASAHI_DOCS_PARTITIONING="https://asahilinux.org/docs/sw/partitioning-cheatsheet/"
ASAHI_DOCS_DEVICES="https://asahilinux.org/docs/hw/devices/device-list/"
ASAHI_TM_CLEANUP="https://alx.sh/tmcleanup"

# --- Omarchy Mac (Linux side) -----------------------------------------------------
OMARCHY_MAC_REPO="omarchy-mac/omarchy-mac"       # as upstream documents it
OMARCHY_MAC_CANONICAL="omacom/omarchy-mac"       # where GitHub resolves it
OMARCHY_MAC_BRANCH="quattro"
OMARCHY_MAC_RAW="https://raw.githubusercontent.com/$OMARCHY_MAC_REPO/$OMARCHY_MAC_BRANCH"
OMARCHY_MAC_SETUP_URL="$OMARCHY_MAC_RAW/bin/omarchy-mac-setup"
OMARCHY_MAC_VERSION_URL="$OMARCHY_MAC_RAW/version"
OMARCHY_MAC_README_URL="$OMARCHY_MAC_RAW/README.md"
OMARCHY_MAC_API_URL="https://api.github.com/repos/$OMARCHY_MAC_REPO"
OMARCHY_MAC_HOME="https://github.com/$OMARCHY_MAC_CANONICAL"
OMARCHY_MAC_VERIFIED="4.0.3rc4"
OMARCHY_EXPECTED_MAJOR="4"
# Flags this tool passes to omarchy-mac-setup; each must appear in its
# "# omarchy:args=" header or the handoff is refused.
OMARCHY_MAC_SETUP_FLAGS="--encrypt --no-encrypt --user --hostname --keymap --status --resume"
OMARCHY_LINUX_MIN_GB=50
OMARCHY_LINUX_RECOMMENDED_GB=100

# Omarchy Mac's own state signals (bin/omarchy-mac-setup).
OMS_CONF=/etc/omarchy-mac-setup.conf
OMS_SELF=/usr/local/bin/omarchy-mac-setup
OMS_UNIT=omarchy-mac-setup.service
OMS_MARKER=/var/lib/omarchy-mac-setup/installed
OMS_LOG=/var/log/omarchy-mac-setup.log
OMARCHY_RUNTIME_VERSION=/usr/share/omarchy/version
OMARCHY_DISPLAY_MANAGER=/etc/systemd/system/display-manager.service

# --- Developer tools ---------------------------------------------------------------
CLAUDE_CODE_INSTALL_URL="https://claude.ai/install.sh"
CODEX_NPM_PACKAGE="@openai/codex"

# --- Planning policy (ours, not upstream) -------------------------------------------
PLAN_DRIFT_MARGIN_BYTES=5000000000    # space macOS may consume between plan and install

# --- Devices -------------------------------------------------------------------------
# Asahi device list (docs/hw/devices/device-list.md) with the installer's
# board names. Tier follows the SoC: see soc_tier.
_devices() {
  cat <<'EOF'
Macmini9,1|j274|t8103|Mac mini (M1, 2020)
MacBookPro17,1|j293|t8103|MacBook Pro (13-inch, M1, 2020)
MacBookAir10,1|j313|t8103|MacBook Air (M1, 2020)
iMac21,1|j456|t8103|iMac (24-inch, 4-port, M1, 2021)
iMac21,2|j457|t8103|iMac (24-inch, 2-port, M1, 2021)
MacBookPro18,1|j316s|t6000|MacBook Pro (16-inch, M1 Pro, 2021)
MacBookPro18,2|j316c|t6001|MacBook Pro (16-inch, M1 Max, 2021)
MacBookPro18,3|j314s|t6000|MacBook Pro (14-inch, M1 Pro, 2021)
MacBookPro18,4|j314c|t6001|MacBook Pro (14-inch, M1 Max, 2021)
Mac13,1|j375c|t6001|Mac Studio (M1 Max, 2022)
Mac13,2|j375d|t6002|Mac Studio (M1 Ultra, 2022)
Mac14,7|j493|t8112|MacBook Pro (13-inch, M2, 2022)
Mac14,2|j413|t8112|MacBook Air (13-inch, M2, 2022)
Mac14,3|j473|t8112|Mac mini (M2, 2023)
Mac14,12|j474s|t6020|Mac mini (M2 Pro, 2023)
Mac14,9|j414s|t6020|MacBook Pro (14-inch, M2 Pro, 2023)
Mac14,10|j416s|t6020|MacBook Pro (16-inch, M2 Pro, 2023)
Mac14,5|j414c|t6021|MacBook Pro (14-inch, M2 Max, 2023)
Mac14,6|j416c|t6021|MacBook Pro (16-inch, M2 Max, 2023)
Mac14,15|j415|t8112|MacBook Air (15-inch, M2, 2023)
Mac14,13|j475c|t6021|Mac Studio (M2 Max, 2023)
Mac14,14|j475d|t6022|Mac Studio (M2 Ultra, 2023)
Mac14,8|j180d|t6022|Mac Pro (2023)
Mac15,4|j433|t8122|iMac (24-inch, 2-port, M3, 2023)
Mac15,5|j434|t8122|iMac (24-inch, 4-port, M3, 2023)
Mac15,3|j504|t8122|MacBook Pro (14-inch, M3, Nov 2023)
Mac15,6|j514s|t6030|MacBook Pro (14-inch, M3 Pro, Nov 2023)
Mac15,7|j516s|t6030|MacBook Pro (16-inch, M3 Pro, Nov 2023)
Mac15,8|j514c|t6031|MacBook Pro (14-inch, M3 Max, Nov 2023)
Mac15,9|j516c|t6031|MacBook Pro (16-inch, M3 Max, Nov 2023)
Mac15,10|j514m|t6034|MacBook Pro (14-inch, M3 Max, Nov 2023)
Mac15,11|j516m|t6034|MacBook Pro (16-inch, M3 Max, Nov 2023)
Mac15,12|j613|t8122|MacBook Air (13-inch, M3, 2024)
Mac15,13|j615|t8122|MacBook Air (15-inch, M3, 2024)
Mac15,14|j575d|t6032|Mac Studio (M3 Ultra, 2025)
Mac16,2|j623|t8132|iMac (24-inch, 2-port, M4, 2024)
Mac16,3|j624|t8132|iMac (24-inch, 4-port, M4, 2024)
Mac16,10|j773g|t8132|Mac mini (M4, 2024)
Mac16,11|j773s|t6040|Mac mini (M4 Pro, 2024)
Mac16,1|j604|t8132|MacBook Pro (14-inch, M4, Nov 2024)
Mac16,8|j614s|t6040|MacBook Pro (14-inch, M4 Pro, Nov 2024)
Mac16,7|j616s|t6040|MacBook Pro (16-inch, M4 Pro, Nov 2024)
Mac16,6|j614c|t6041|MacBook Pro (14-inch, M4 Max, Nov 2024)
Mac16,5|j616c|t6041|MacBook Pro (16-inch, M4 Max, Nov 2024)
Mac16,12|j713|t8132|MacBook Air (13-inch, M4, 2025)
Mac16,13|j715|t8132|MacBook Air (15-inch, M4, 2025)
Mac16,9|j575c|t6041|Mac Studio (M4 Max, 2025)
EOF
}

soc_chip() {
  case "$1" in
    t8103) echo "M1" ;; t6000) echo "M1 Pro" ;; t6001) echo "M1 Max" ;; t6002) echo "M1 Ultra" ;;
    t8112) echo "M2" ;; t6020) echo "M2 Pro" ;; t6021) echo "M2 Max" ;; t6022) echo "M2 Ultra" ;;
    t8122) echo "M3" ;; t6030) echo "M3 Pro" ;; t6031 | t6034) echo "M3 Max" ;; t6032) echo "M3 Ultra" ;;
    t8132) echo "M4" ;; t6040) echo "M4 Pro" ;; t6041) echo "M4 Max" ;;
    *) echo "unknown" ;;
  esac
}

# supported: installer + Omarchy Mac documented. experimental: the installer
# accepts it, Asahi lists display/USB as in progress, Omarchy Mac does not
# document it. unsupported: everything else.
soc_tier() {
  case "$1" in
    t8103 | t6000 | t6001 | t6002 | t8112 | t6020 | t6021 | t6022) echo supported ;;
    t8122 | t6030 | t6031 | t6034) echo experimental ;;
    *) echo unsupported ;;
  esac
}

_device_set() {
  DEV_MODEL=$(printf '%s' "$1" | cut -d'|' -f1)
  DEV_BOARD=$(printf '%s' "$1" | cut -d'|' -f2)
  DEV_SOC=$(printf '%s' "$1" | cut -d'|' -f3)
  DEV_NAME=$(printf '%s' "$1" | cut -d'|' -f4)
  DEV_CHIP=$(soc_chip "$DEV_SOC")
  DEV_TIER=$(soc_tier "$DEV_SOC")
}

# device_by_model MODEL_ID — sets DEV_*; returns 1 when the model is unknown.
device_by_model() {
  local line
  line=$(_devices | grep "^$1|" | head -1)
  if [ -z "$line" ]; then
    DEV_MODEL=$1 DEV_BOARD="" DEV_SOC="" DEV_NAME="" DEV_CHIP="unknown" DEV_TIER=unsupported
    return 1
  fi
  _device_set "$line"
}

# device_by_board BOARD — from the Linux device tree (e.g. j316s).
device_by_board() {
  local line
  line=$(_devices | awk -F'|' -v b="$1" '$2 == b {print; exit}')
  if [ -z "$line" ]; then
    DEV_MODEL="" DEV_BOARD=$1 DEV_SOC="" DEV_NAME="" DEV_CHIP="unknown" DEV_TIER=unsupported
    return 1
  fi
  _device_set "$line"
}

# ---------------------------------------------------------------------------
# `sources` command
# ---------------------------------------------------------------------------

cmd_sources() {
  local check=0
  [ "${1:-}" = "--check" ] && check=1
  ui_header "sources"
  ui_section "Asahi Alarm" "macOS phase"
  ui_kv "Bootstrap" "$ASAHI_ALARM_INSTALLER_URL"
  ui_kv "OS list" "$ASAHI_ALARM_DATA_URL"
  ui_kv "Choose" "$ASAHI_ALARM_OS_CHOICE"
  ui_kv "Installer verified" "$ASAHI_INSTALLER_VERIFIED" "asahi-installer"
  ui_kv "macOS kept free" "$((ASAHI_MIN_FREE_OS_BYTES / 1000000000)) GB" "MIN_FREE_OS"
  ui_kv "Boot stub + EFI" "2.5 GB + 0.5 GB" "STUB_SIZE, EFI template"
  ui_kv "Minimum macOS" "$ASAHI_MIN_MACOS"
  ui_kv "First login" "$ASAHI_ALARM_FIRST_LOGIN"
  ui_section "Omarchy Mac" "Linux phase"
  ui_kv "Repository" "$OMARCHY_MAC_REPO" "resolves to $OMARCHY_MAC_CANONICAL"
  ui_kv "Branch" "$OMARCHY_MAC_BRANCH" "Omarchy $OMARCHY_EXPECTED_MAJOR line"
  ui_kv "Setup" "$OMARCHY_MAC_SETUP_URL"
  ui_kv "Version verified" "$OMARCHY_MAC_VERIFIED"
  ui_kv "Flags used" "$OMARCHY_MAC_SETUP_FLAGS"
  ui_kv "Linux space" "≥ ${OMARCHY_LINUX_MIN_GB} GB, ${OMARCHY_LINUX_RECOMMENDED_GB} GB recommended"
  ui_section "Documentation"
  ui_kv "FAQ" "$ASAHI_DOCS_FAQ"
  ui_kv "Partitioning" "$ASAHI_DOCS_PARTITIONING"
  ui_kv "Devices" "$ASAHI_DOCS_DEVICES"
  ui_kv "Omarchy Mac" "$OMARCHY_MAC_HOME"
  ui_note ""
  ui_note "Verified against upstream source on $SOURCES_VERIFIED_ON. Defined in lib/sources.sh."
  if [ "$check" = 1 ]; then
    sources_check
    return
  fi
  ui_note "Run 'omarchy-bootstrap sources --check' to compare with upstream now."
  printf '\n'
}

# sources_check — read-only comparison with upstream. Returns 1 on any FAIL.
sources_check() {
  local v body fails=0
  ui_section "Upstream check" "$(now_utc)"

  if v=$(sys_net asahi_version "$ASAHI_ALARM_VERSION_URL") && [ -n "$v" ]; then
    v=$(printf '%s' "$v" | clean_version)
    if [ "$v" = "$ASAHI_INSTALLER_VERIFIED" ]; then
      ui_tag pass "Asahi installer" "$v (matches)"
    else
      ui_tag warn "Asahi installer" "$v, verified $ASAHI_INSTALLER_VERIFIED — re-read src/main.py constants"
    fi
  else
    ui_tag warn "Asahi installer" "could not reach $ASAHI_ALARM_VERSION_URL"
  fi

  if body=$(sys_net asahi_data "$ASAHI_ALARM_DATA_URL") && [ -n "$body" ]; then
    if printf '%s' "$body" | grep -qF "\"$ASAHI_ALARM_OS_CHOICE\""; then
      ui_tag pass "OS choice" "$ASAHI_ALARM_OS_CHOICE is offered"
    else
      ui_tag fail "OS choice" "$ASAHI_ALARM_OS_CHOICE is no longer in installer_data.json"
      fails=$((fails + 1))
    fi
  else
    ui_tag warn "OS choice" "could not fetch installer_data.json"
  fi

  if body=$(sys_net asahi_faq "$ASAHI_DOCS_FAQ_RAW") && [ -n "$body" ]; then
    if printf '%s' "$body" | grep -q "38GB"; then
      ui_tag pass "macOS reserve" "FAQ still documents 38GB"
    else
      ui_tag warn "macOS reserve" "FAQ no longer mentions 38GB — re-check MIN_FREE_OS"
    fi
  else
    ui_tag warn "macOS reserve" "could not fetch the Asahi FAQ"
  fi

  if v=$(sys_net omarchy_version "$OMARCHY_MAC_VERSION_URL") && [ -n "$v" ]; then
    v=$(printf '%s' "$v" | clean_version)
    case "$v" in
      "$OMARCHY_EXPECTED_MAJOR".*)
        if [ "$v" = "$OMARCHY_MAC_VERIFIED" ]; then
          ui_tag pass "Omarchy on $OMARCHY_MAC_BRANCH" "$v (matches)"
        else
          ui_tag pass "Omarchy on $OMARCHY_MAC_BRANCH" "$v (verified $OMARCHY_MAC_VERIFIED; same major)"
        fi
        ;;
      *)
        ui_tag fail "Omarchy on $OMARCHY_MAC_BRANCH" "$v — not Omarchy $OMARCHY_EXPECTED_MAJOR; handoff refuses"
        fails=$((fails + 1))
        ;;
    esac
  else
    ui_tag warn "Omarchy on $OMARCHY_MAC_BRANCH" "could not fetch $OMARCHY_MAC_VERSION_URL"
  fi

  if body=$(sys_net omarchy_api "$OMARCHY_MAC_API_URL") && [ -n "$body" ]; then
    if printf '%s' "$body" | grep -q "\"default_branch\": *\"$OMARCHY_MAC_BRANCH\""; then
      ui_tag pass "Default branch" "$OMARCHY_MAC_BRANCH"
    else
      v=$(printf '%s' "$body" | sed -n 's/.*"default_branch": *"\([^"]*\)".*/\1/p' | head -1 | tr -cd '[:alnum:]._/-')
      ui_tag warn "Default branch" "upstream default is now '$v'; this tool still targets $OMARCHY_MAC_BRANCH"
    fi
    v=$(printf '%s' "$body" | sed -n 's/.*"full_name": *"\([^"]*\)".*/\1/p' | head -1 | tr -cd '[:alnum:]._/-')
    [ -n "$v" ] && ui_tag info "Repository home" "$v"
  else
    ui_tag warn "Default branch" "GitHub API unreachable or rate-limited"
  fi

  if body=$(sys_net omarchy_setup "$OMARCHY_MAC_SETUP_URL") && [ -n "$body" ]; then
    local missing
    missing=$(setup_missing_flags "$body")
    if [ -z "$missing" ]; then
      ui_tag pass "Setup flags" "all declared"
    else
      ui_tag fail "Setup flags" "missing:$missing — handoff refuses"
      fails=$((fails + 1))
    fi
  else
    ui_tag warn "Setup flags" "could not fetch omarchy-mac-setup"
  fi

  if body=$(sys_net omarchy_readme "$OMARCHY_MAC_README_URL") && [ -n "$body" ]; then
    if printf '%s' "$body" | grep -q "At least ${OMARCHY_LINUX_MIN_GB} GB"; then
      ui_tag pass "Linux minimum" "README still asks for ${OMARCHY_LINUX_MIN_GB} GB"
    else
      ui_tag warn "Linux minimum" "README wording changed — re-check the space requirement"
    fi
  else
    ui_tag warn "Linux minimum" "could not fetch the Omarchy Mac README"
  fi
  printf '\n'
  log_event sources "check finished, failures=$fails"
  [ "$fails" = 0 ]
}

# setup_missing_flags SCRIPT_TEXT — prints the flags we use that the setup
# script's "# omarchy:args=" header no longer declares.
setup_missing_flags() {
  local header words flag missing=""
  header=$(printf '%s\n' "$1" | grep -m1 '^# omarchy:args=')
  # Whole words only: a renamed flag (--username, --keymap-layout) must not
  # count as the one this tool passes.
  words=" $(printf '%s' "${header#\# omarchy:args=}" | sed 's/[][|]/ /g') "
  for flag in $OMARCHY_MAC_SETUP_FLAGS; do
    case "$words" in
      *" $flag "*) ;;
      *) missing="$missing $flag" ;;
    esac
  done
  printf '%s' "$missing"
}
