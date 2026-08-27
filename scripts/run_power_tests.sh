#!/bin/zsh
# Compiles and runs the Mac sleep / wake power-management
# regression matrix. This is independent of `run_tests.sh` so the
# matrix can be validated even when other self-tests have
# pre-existing failures unrelated to power management.
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
mkdir -p "$ROOT/.build/self-tests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/AppIdentityMigration.swift" \
  "$ROOT/Sources/CellDock/CellularModuleID.swift" \
  "$ROOT/Sources/CellDock/CallModels.swift" \
  "$ROOT/Sources/CellDock/CallHistoryStore.swift" \
  "$ROOT/Sources/CellDock/PhoneNumberNormalizer.swift" \
  "$ROOT/Sources/CellDock/PrivacyPresentation.swift" \
  "$ROOT/Sources/CellDock/CallATParser.swift" \
  "$ROOT/Sources/CellDock/ATConsoleModels.swift" \
  "$ROOT/Sources/CellDock/VoiceSignalProcessor.swift" \
  "$ROOT/Sources/CellDock/CarrierNameFormatter.swift" \
  "$ROOT/Sources/CellDock/NotificationRouting.swift" \
  "$ROOT/Sources/CellDock/LaunchAtLoginController.swift" \
  "$ROOT/Sources/CellDock/ADBProtocol.swift" \
  "$ROOT/Sources/CellDock/ModuleVoicePayload.swift" \
  "$ROOT/Sources/CellDockNetworkIPC/CellDockNetworkIPC.swift" \
  "$ROOT/Sources/CellDockNetworkHelper/NetworkHelperState.swift" \
  "$ROOT/Sources/CellDock/Models.swift" \
  "$ROOT/Sources/CellDock/ModemConnectionRecovery.swift" \
  "$ROOT/Sources/CellDock/ModemRecoveryEngine.swift" \
  "$ROOT/Sources/CellDock/ModemPowerManager.swift" \
  "$ROOT/Sources/CellDock/ModemModuleStatusPresentation.swift" \
  "$ROOT/Sources/CellDock/QADBKeyDeriver.swift" \
  "$ROOT/Sources/CellDock/MessageConversation.swift" \
  "$ROOT/Sources/CellDock/CellularLinkRecovery.swift" \
  "$ROOT/Sources/CellDock/CellularModuleModels.swift" \
  "$ROOT/Sources/CellDock/NetworkThroughput.swift" \
  "$ROOT/Sources/CellDock/DeletedMessageRegistry.swift" \
  "$ROOT/Sources/CellDock/EUICCModels.swift" \
  "$ROOT/Sources/CellDock/ATResponseParser.swift" \
  "$ROOT/Sources/CellDock/SMSPDUDecoder.swift" \
  "$ROOT/Sources/CellDock/SMSPDUEncoder.swift" \
  "$ROOT/Sources/CellDock/SMSVerificationCode.swift" \
  "$ROOT/Sources/CellDock/SOCKSProtocol.swift" \
  "$ROOT/Sources/CellDock/BoundSocket.swift" \
  "$ROOT/Sources/CellDock/CellularInternetProbe.swift" \
  "$ROOT/Sources/CellDock/SOCKSDNSResolver.swift" \
  "$ROOT/Sources/CellDock/SOCKSProxyModels.swift" \
  "$ROOT/Sources/CellDock/VoWiFiRuntimeModels.swift" \
  "$ROOT/Sources/CellDock/VoWiFiRuntimeControl.swift" \
  "$ROOT/Sources/CellDock/VoWiFiUpstreamProxyModels.swift" \
  "$ROOT/Sources/CellDock/VerificationMessageAutoDelete.swift" \
  "$ROOT/Sources/CellDock/USBConfiguration.swift" \
  "$ROOT/Sources/CellDock/USBModeController.swift" \
  "$ROOT/Sources/CellDock/USBConfigBackup.swift" \
  "$ROOT/Tests/PowerManagementSelfTests/main.swift" \
  -framework AppKit \
  -o "$ROOT/.build/self-tests/CellDockPowerSelfTests"

"$ROOT/.build/self-tests/CellDockPowerSelfTests"
