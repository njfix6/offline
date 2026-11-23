#!/bin/bash
# Automated part of the acceptance checks in VERIFY.md.
#
#   Scripts/check-privacy.sh                 checks the source tree
#   Scripts/check-privacy.sh path/Offline.app   also checks a built app
#
# It fails if the code or the build gains anything the spec forbids: network
# or iCloud entitlements, networking / indexing / Siri / AI / logging APIs,
# unexpected dependencies, or text views and windows that bypass the hardened
# classes. Runs on macOS and Linux (the app checks need macOS).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
pass() { echo "ok    $1"; }

# Swift sources we wrote (vendored GRDB is checked separately below).
SOURCES=(App OfflineKit/Sources/OfflineCore OfflineKit/Sources/OfflineKit)

# Prints matching code lines, ignoring comments.
scan() {
    grep -rnE --include='*.swift' "$1" "${SOURCES[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

forbid() {
    local label="$1" pattern="$2" hits
    hits="$(scan "$pattern")"
    if [ -n "$hits" ]; then
        fail "$label"
        echo "$hits" | sed 's/^/        /'
    else
        pass "$label"
    fi
}

echo "== Entitlements (source) =="
check_entitlements() {
    python3 - "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)
allowed = {
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    # Added by Xcode when signing; none of them grant access to anything.
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.get-task-allow",
    "keychain-access-groups",
}
problems = []
if entitlements.get("com.apple.security.app-sandbox") is not True:
    problems.append("App Sandbox is not enabled")
for key in entitlements:
    if key not in allowed:
        problems.append("unexpected entitlement: " + key)
    if "network" in key or "icloud" in key.lower() or "ubiquity" in key:
        problems.append("forbidden entitlement: " + key)
for problem in problems:
    print("        " + problem)
sys.exit(1 if problems else 0)
PY
}
if check_entitlements App/Offline.entitlements; then
    pass "sandbox on; no network, iCloud or other entitlements"
else
    fail "App/Offline.entitlements"
fi

echo "== Forbidden APIs in our sources =="
forbid "no networking frameworks" \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(Network|CFNetwork|FoundationNetworking|WebKit|MultipeerConnectivity|NetworkExtension)\b'
forbid "no networking calls" \
    '\b(URLSession|URLRequest|NWConnection|NWListener|CFSocket|CFStream|NSURLConnection|WKWebView|URLSessionConfiguration)\b|String\(contentsOf:[[:space:]]*URL\(string'
forbid "no iCloud" \
    '^[[:space:]]*import[[:space:]]+CloudKit\b|\b(NSUbiquitousKeyValueStore|CKContainer|NSMetadataQuery|url\(forUbiquityContainerIdentifier)'
forbid "no Spotlight indexing" \
    '^[[:space:]]*import[[:space:]]+CoreSpotlight\b|\b(CSSearchableItem|CSSearchableIndex)\b'
forbid "no Siri, App Intents, Shortcuts or user activities" \
    '^[[:space:]]*import[[:space:]]+(AppIntents|Intents|IntentsUI)\b|\b(NSUserActivity|AppIntent|AppShortcutsProvider|INInteraction|userActivity\()'
forbid "no AI, ML or language-model frameworks" \
    '^[[:space:]]*import[[:space:]]+(CoreML|NaturalLanguage|Vision|Speech|FoundationModels|Translation|CreateML|SoundAnalysis)\b'
forbid "no analytics, crash reporting or updater SDKs" \
    '^[[:space:]]*import[[:space:]]+(Sparkle|Firebase[A-Za-z]*|Sentry|Bugsnag|AppCenter[A-Za-z]*|Mixpanel|Amplitude|TelemetryDeck|MetricKit)\b'
forbid "no logging of any kind" \
    '^[[:space:]]*import[[:space:]]+(os|OSLog|os\.log)\b|\b(os_log|NSLog|debugPrint|dump)\(|(^|[^A-Za-z_.])print\(|\bLogger\('
forbid "no Services provider and no sharing" \
    '\b(servicesProvider|registerServicesMenuSendTypes|NSSharingService|NSSharingServicePicker|ShareLink)\b'
forbid "no Quick Look or document types" \
    '^[[:space:]]*import[[:space:]]+(QuickLook|QuickLookUI|QuickLookThumbnailing)\b'

echo "== Hardened text views and windows =="
forbid "no SwiftUI text inputs (HardenedTextField is used instead)" \
    '(^|[^A-Za-z_])(TextField|TextEditor)\('
forbid "no windows or sheets outside HardenedWindow" \
    '(^|[^A-Za-z_])(NSWindow|NSPanel)\(|\bWindowGroup\b|\.(sheet|popover|inspector|fullScreenCover)\('
forbid "no web views or attributed-string HTML importers" \
    '\b(WKWebView|WebView)\b|documentType:[[:space:]]*\.html'

bad_text_views="$(grep -rnE --include='*.swift' 'class[[:space:]]+[A-Za-z_]+[[:space:]]*:[[:space:]]*NSTextView\b' "${SOURCES[@]}" | grep -v 'class HardenedTextView' || true)"
if [ -n "$bad_text_views" ]; then
    fail "every text view must derive from HardenedTextView"
    echo "$bad_text_views" | sed 's/^/        /'
else
    pass "every text view derives from HardenedTextView"
fi
if grep -q 'writingToolsBehavior = \.none' OfflineKit/Sources/OfflineKit/Editor/HardenedTextView.swift \
    && grep -q 'sharingType = \.none' OfflineKit/Sources/OfflineKit/Lock/HardenedWindow.swift \
    && grep -q 'org.nspasteboard.ConcealedType' OfflineKit/Sources/OfflineKit/Editor/ConcealedPasteboard.swift \
    && grep -q 'org.nspasteboard.TransientType' OfflineKit/Sources/OfflineKit/Editor/ConcealedPasteboard.swift; then
    pass "Writing Tools off, capture exclusion and concealed clipboard are in place"
else
    fail "a hardening line is missing (writingToolsBehavior / sharingType / pasteboard types)"
fi

echo "== Encryption and storage =="
if grep -q 'cipher_memory_security = ON' OfflineKit/Sources/OfflineCore/Store/Store+Key.swift \
    && grep -q 'temp_store = MEMORY' OfflineKit/Sources/OfflineCore/Store/Store+Key.swift \
    && grep -q 'encryptionUnavailable' OfflineKit/Sources/OfflineCore/Store/Store+Key.swift \
    && grep -q 'usePassphrase' OfflineKit/Sources/OfflineCore/Store/Store+Key.swift; then
    pass "database is keyed, refuses to run unencrypted, and keeps temp data in memory"
else
    fail "Store+Key.swift lost a required pragma or the encryption check"
fi
if grep -q 'Data.noindex' OfflineKit/Sources/OfflineCore/Vault/Vault.swift; then
    pass "data directory is named Data.noindex"
else
    fail "data directory must end in .noindex"
fi
if grep -q 'userPresence' OfflineKit/Sources/OfflineCore/Vault/KeychainKeyStore.swift \
    && grep -q 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' OfflineKit/Sources/OfflineCore/Vault/KeychainKeyStore.swift \
    && grep -q 'kSecAttrSynchronizable as String: false' OfflineKit/Sources/OfflineCore/Vault/KeychainKeyStore.swift; then
    pass "Keychain item needs user presence, is device-only and not synced"
else
    fail "Keychain protection attributes changed"
fi

echo "== Dependencies =="
deps="$(grep -hE '\.package\(' OfflineKit/Package.swift Vendor/GRDB.swift/Package.swift | sed 's/^[[:space:]]*//' | sort -u)"
expected='.package(path: "../Vendor/GRDB.swift"),
.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.20.0"),'
if [ "$deps" = "$expected" ]; then
    pass "only GRDB (vendored) and SQLCipher"
else
    fail "unexpected package dependencies"
    echo "$deps" | sed 's/^/        /'
fi
if grep -rnE '^[[:space:]]*import[[:space:]]+(Network|CFNetwork|CloudKit|CoreSpotlight)\b|\bURLSession\b' Vendor/GRDB.swift/GRDB OfflineKit/Sources/CArgon2 >/dev/null 2>&1; then
    fail "vendored code references a networking or indexing API"
else
    pass "vendored GRDB and Argon2 contain no networking or indexing APIs"
fi

if [ $# -ge 1 ]; then
    APP="$1"
    BINARY="$APP/Contents/MacOS/Offline"
    echo "== Built app: $APP =="
    if [ ! -x "$BINARY" ]; then
        fail "no executable at $BINARY"
    else
        TMP="$(mktemp)"
        if codesign -d --entitlements - --xml "$APP" > "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
            if check_entitlements "$TMP"; then
                pass "signed entitlements: sandbox on, nothing forbidden"
            else
                fail "signed entitlements"
            fi
        else
            fail "could not read entitlements from the signed app (is it signed?)"
        fi
        rm -f "$TMP"

        linked="$(otool -L "$BINARY" | grep -E '/(CFNetwork|Network|CloudKit|CoreSpotlight|Intents|AppIntents|WebKit|CoreML|NaturalLanguage)\.framework' || true)"
        if [ -n "$linked" ]; then
            fail "binary links a forbidden framework"
            echo "$linked" | sed 's/^/        /'
        else
            pass "binary links no networking, iCloud, Spotlight, Siri, web or ML framework"
        fi

        symbols="$(nm -u "$BINARY" 2>/dev/null | grep -E 'NSURLSession|CKContainer|CSSearchableIndex|NSUserActivity|_os_log_impl|_NSLog' || true)"
        if [ -n "$symbols" ]; then
            fail "binary references a forbidden symbol"
            echo "$symbols" | sed 's/^/        /'
        else
            pass "binary references no networking, indexing or logging symbols"
        fi

        flags="$(codesign -d --verbose=4 "$APP" 2>&1 | grep -E '^CodeDirectory' || true)"
        case "$flags" in
            *runtime*) pass "Hardened Runtime is on" ;;
            *) fail "Hardened Runtime flag not found in the signature" ;;
        esac
    fi
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "All automated privacy checks passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
