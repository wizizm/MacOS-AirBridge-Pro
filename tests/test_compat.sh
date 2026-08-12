#!/bin/bash
# Compatibility guards for building/running AirBridge on the host macOS SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
COMPILE_ERR="$(mktemp /tmp/phy_mode_compile.XXXXXX)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# Print lines from first match of START through first later match of END.
slice_main() {
  local start="$1"
  local end="$2"
  awk -v s="$start" -v e="$end" '
    index($0, s) { show=1 }
    show { print }
    show && index($0, e) && index($0, s) == 0 { exit }
  ' "$ROOT/main.swift"
}

if grep -qE 'WORKSPACE_DIR="/Users/tiwut' "$ROOT/build.sh"; then
  fail "build.sh does not hardcode /Users/tiwut workspace"
else
  pass "build.sh does not hardcode /Users/tiwut workspace"
fi

if grep -q 'SCRIPT_DIR=' "$ROOT/build.sh"; then
  pass "build.sh derives WORKSPACE_DIR from script path"
else
  fail "build.sh derives WORKSPACE_DIR from script path"
fi

if grep -qE '\.mode11be' "$ROOT/main.swift"; then
  fail "main.swift does not reference unavailable CWPHYMode.mode11be member"
else
  pass "main.swift does not reference unavailable CWPHYMode.mode11be member"
fi

if grep -Eq 'DEPLOY_TARGET="15\.0"' "$ROOT/build.sh"; then
  pass "build.sh sets DEPLOY_TARGET to 15.0"
else
  fail "build.sh sets DEPLOY_TARGET to 15.0"
fi

if grep -q 'xattr -cr' "$ROOT/build.sh"; then
  pass "build.sh clears quarantine (xattr -cr)"
else
  fail "build.sh clears quarantine (xattr -cr)"
fi

if grep -q 'codesign' "$ROOT/build.sh"; then
  pass "build.sh ad-hoc codesigns the app bundle"
else
  fail "build.sh ad-hoc codesigns the app bundle"
fi

if grep -Eq -- '--sign[[:space:]]+-' "$ROOT/build.sh"; then
  pass "build.sh uses ad-hoc identity (-)"
else
  fail "build.sh uses ad-hoc identity (-)"
fi

if grep -q 'IfconfigParser.swift' "$ROOT/build.sh"; then
  pass "build.sh compiles IfconfigParser.swift"
else
  fail "build.sh compiles IfconfigParser.swift"
fi

if grep -q 'InternetSharingConfig.swift' "$ROOT/build.sh"; then
  pass "build.sh compiles InternetSharingConfig.swift"
else
  fail "build.sh compiles InternetSharingConfig.swift"
fi

if grep -qE 'InternetSharing\.plist|SharingInterfaces' "$ROOT/main.swift"; then
  fail "main does not reference InternetSharing.plist or SharingInterfaces"
else
  pass "main does not reference InternetSharing.plist or SharingInterfaces"
fi

if grep -q 'SharingDevices' "$ROOT/main.swift" \
  && grep -q 'selectInternetSharingBridge' "$ROOT/main.swift" \
  && { grep -q 'NetworkSharing' "$ROOT/main.swift" || grep -q 'NetworkSharing' "$ROOT/InternetSharingConfig.swift"; }; then
  pass "main references NetworkSharing / SharingDevices / selectInternetSharingBridge"
else
  fail "main references NetworkSharing / SharingDevices / selectInternetSharingBridge"
fi

if grep -q 'isEnterprise8021XSecurity' "$ROOT/main.swift" \
  && grep -q 'internetSharingBypassEnableShell' "$ROOT/main.swift" \
  && grep -q 'hotspotBypass8021XSuccess' "$ROOT/main.swift"; then
  pass "main wires 802.1X bypass path"
else
  fail "main wires 802.1X bypass path"
fi

if grep -q 'isEnterprise8021XSecurity' "$ROOT/InternetSharingConfig.swift" \
  && grep -q 'internetSharingBypassEnableShell' "$ROOT/InternetSharingConfig.swift" \
  && grep -q 'com.apple.internet-sharing' "$ROOT/InternetSharingConfig.swift" \
  && ! grep -qE 'pfctl -f -' "$ROOT/InternetSharingConfig.swift"; then
  pass "bypass loads NAT into system nat-anchor (no stdin wipe)"
else
  fail "bypass loads NAT into system nat-anchor (no stdin wipe)"
fi

if grep -q 'L10n.swift' "$ROOT/build.sh"; then
  pass "build.sh compiles L10n.swift"
else
  fail "build.sh compiles L10n.swift"
fi

if grep -q 'L10n.text' "$ROOT/main.swift"; then
  pass "main.swift contains L10n.text (wired)"
else
  fail "main.swift contains L10n.text (wired)"
fi

if grep -q 'schedulePeriodicRefresh' "$ROOT/main.swift"; then
  pass "timer refresh is scheduled off the main thread"
else
  fail "timer refresh is scheduled off the main thread"
fi

if slice_main "developerInfoView" "private func selectedTitle" | grep -Fq 'shell('; then
  fail "developer info view does not shell out in body"
else
  pass "developer info view does not shell out in body"
fi

if slice_main "func blockClient" "func unblockClient" | grep -Fq enqueueRefreshData; then
  pass "blockClient enqueues refreshData via refreshQueue"
else
  fail "blockClient enqueues refreshData via refreshQueue"
fi

if slice_main "func addIPReservation" "private func parseHardwarePorts" | grep -Fq enqueueRefreshData; then
  pass "addIPReservation enqueues refreshData via refreshQueue"
else
  fail "addIPReservation enqueues refreshData via refreshQueue"
fi

if slice_main "func toggleIntegratedHotspot" "func blockClient" | grep -Fq enqueueRefreshData; then
  pass "toggleIntegratedHotspot enqueues refreshData via refreshQueue"
else
  fail "toggleIntegratedHotspot enqueues refreshData via refreshQueue"
fi

if grep -q 'speedometerBaselineNeedsReset' "$ROOT/main.swift"; then
  pass "speedometer resets baseline on NIC change"
else
  fail "speedometer resets baseline on NIC change"
fi

SCHED="$(slice_main "func schedulePeriodicRefresh" "private func enqueueRefreshData")"
if printf '%s\n' "$SCHED" | grep -q 'refreshQueue.async' \
  && printf '%s\n' "$SCHED" | grep -q 'refreshWLANTelemetry' \
  && ! printf '%s\n' "$SCHED" | grep -q 'CoreWLAN reads are cheap'; then
  pass "WLAN telemetry runs on refreshQueue (not main-thread CoreWiFi XPC)"
else
  fail "WLAN telemetry runs on refreshQueue (not main-thread CoreWiFi XPC)"
fi

if grep -q 'interfaceByteCounters' "$ROOT/main.swift" \
  && ! grep -q 'netstat -ib' "$ROOT/main.swift"; then
  pass "speedometer uses getifaddrs (not netstat shell)"
else
  fail "speedometer uses getifaddrs (not netstat shell)"
fi

APP="$ROOT/AirBridge.app"
BIN="$APP/Contents/MacOS/AirBridge"
if [[ -x "$BIN" ]]; then
  MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  case "$MINOS" in
    15.*) pass "AirBridge binary minos is 15.x (not macOS 26)" ;;
    *) fail "AirBridge binary minos is 15.x (not macOS 26)" ;;
  esac
  if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    fail "AirBridge.app has no com.apple.quarantine"
  else
    pass "AirBridge.app has no com.apple.quarantine"
  fi
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    pass "AirBridge.app codesign verifies"
  else
    fail "AirBridge.app codesign verifies"
  fi
else
  fail "AirBridge binary missing at $BIN"
fi

TMP_BIN="$(mktemp /tmp/phy_mode_label_test.XXXXXX)"
if swiftc "$ROOT/L10n.swift" "$ROOT/PhyModeLabel.swift" "$ROOT/tests/test_phy_mode_label.swift" -o "$TMP_BIN" 2>"$COMPILE_ERR"; then
  if "$TMP_BIN"; then
    pass "phyModeLabel unit tests"
  else
    fail "phyModeLabel unit tests"
  fi
else
  fail "phyModeLabel failed to compile"
  cat "$COMPILE_ERR"
fi
rm -f "$TMP_BIN"

PARSE_BIN="$(mktemp /tmp/ifconfig_parser_test.XXXXXX)"
if swiftc "$ROOT/IfconfigParser.swift" "$ROOT/tests/test_ifconfig_parser.swift" -o "$PARSE_BIN" 2>"$COMPILE_ERR"; then
  if "$PARSE_BIN"; then
    pass "ifconfig/netstat parser unit tests"
  else
    fail "ifconfig/netstat parser unit tests"
  fi
else
  fail "ifconfig parser failed to compile"
  cat "$COMPILE_ERR"
fi
rm -f "$PARSE_BIN"

L10N_BIN="$(mktemp /tmp/l10n_test.XXXXXX)"
if swiftc "$ROOT/L10n.swift" "$ROOT/tests/test_l10n.swift" -o "$L10N_BIN" 2>"$COMPILE_ERR"; then
  if "$L10N_BIN"; then
    pass "L10n unit tests"
  else
    fail "L10n unit tests"
  fi
else
  fail "L10n failed to compile"
  cat "$COMPILE_ERR"
fi
rm -f "$L10N_BIN"

ISC_BIN="$(mktemp /tmp/internet_sharing_config_test.XXXXXX)"
if swiftc "$ROOT/InternetSharingConfig.swift" "$ROOT/tests/test_internet_sharing_config.swift" -o "$ISC_BIN" 2>"$COMPILE_ERR"; then
  if "$ISC_BIN"; then
    pass "InternetSharingConfig unit tests"
  else
    fail "InternetSharingConfig unit tests"
  fi
else
  fail "InternetSharingConfig failed to compile"
  cat "$COMPILE_ERR"
fi
rm -f "$ISC_BIN" "$COMPILE_ERR"

if [[ "$FAIL" -ne 0 ]]; then
  echo "Compatibility tests failed."
  exit 1
fi
echo "All compatibility tests passed."
