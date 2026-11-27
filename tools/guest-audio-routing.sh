#!/bin/sh
# Run inside the virtual Mac. Sequoia reads this preference when it starts.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
library=/Library
domain="$library/Preferences/FeatureFlags/Domain"
file="$domain/BluetoothFeatures.plist"
state=/var/db/henge-audio-routing
key=SmartRoutingMacOS
enabled=$key.Enabled
plist=/usr/bin/plutil
action=${1:-status}

case "$action" in
    status)
        if [ -f "$file" ]; then
            "$plist" -lint "$file" >/dev/null
            if value=$("$plist" -extract "$enabled" raw -expect bool -o - "$file" 2>/dev/null); then
                echo "Smart audio routing enabled: $value"
                exit 0
            fi
        fi
        echo "No explicit smart audio routing setting."
        exit 0 ;;
    apply|restore) ;;
    *) echo "Usage: sh $0 [status|apply|restore]" >&2; exit 2 ;;
esac

if [ "$(id -u)" != 0 ]; then
    echo "Run $action with sudo inside the virtual Mac." >&2
    exit 1
fi
if [ "$action" = restore ] && [ ! -f "$state/original.plist" ]; then
    echo "No Henge audio setting to restore."
    exit 0
fi
(umask 077 && mkdir -p "$state") || { echo "Run this command with sudo inside the virtual Mac." >&2; exit 1; }
if [ "${2:-}" != locked ]; then
    exec /usr/bin/lockf -k "$state/change.lock" /bin/sh "$0" "$action" locked
fi
mkdir -p "$domain"
tmp=$(mktemp -d "$domain/.henge-audio.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
prefs="$tmp/preferences.plist"
original="$state/original.plist"

has() { "$plist" -type "$1" "$2" >/dev/null 2>&1; }
if [ -f "$file" ]; then
    cp -p "$file" "$tmp/input.plist"
    cp -p "$tmp/input.plist" "$prefs"
    "$plist" -lint "$prefs" >/dev/null
else
    "$plist" -create xml1 "$prefs"
    chmod 644 "$prefs"
fi
if has "$key" "$prefs" && [ "$("$plist" -type "$key" "$prefs")" != dictionary ]; then
    echo "The existing smart routing setting has an unexpected format." >&2
    exit 1
fi

check_current() {
    if [ -f "$tmp/input.plist" ]; then
        cmp -s "$tmp/input.plist" "$file" && return 0
    elif [ ! -e "$file" ]; then
        return 0
    fi
    echo "Bluetooth preferences changed during this operation. Run the command again." >&2
    return 1
}

if [ "$action" = apply ]; then
    if [ -f "$file" ] && [ "$("$plist" -extract "$enabled" raw -expect bool -o - "$file" 2>/dev/null || :)" = false ]; then
        echo "Smart audio routing is already off."
        exit 0
    fi
    if [ ! -f "$original" ]; then
        saved="$tmp/original.plist"
        "$plist" -create xml1 "$saved"
        [ ! -f "$file" ] || "$plist" -insert hadFile -bool YES "$saved"
        if has "$key" "$prefs"; then "$plist" -insert hadRouting -bool YES "$saved"; fi
        if has "$enabled" "$prefs"; then
            prior=$("$plist" -extract "$enabled" xml1 -o - "$prefs")
            "$plist" -insert value -xml "$prior" "$saved"
        fi
    fi
    if ! has "$key" "$prefs"; then "$plist" -insert "$key" -dictionary "$prefs"; fi
    "$plist" -replace "$enabled" -bool NO "$prefs"
    check_current
    if [ -f "$tmp/original.plist" ]; then mv "$tmp/original.plist" "$original"; fi
    mv -f "$prefs" "$file"
    echo "Smart audio routing is off. Restart the virtual Mac to apply it."
else
    [ -f "$original" ] || exit 0
    "$plist" -lint "$original" >/dev/null
    if has value "$original"; then
        prior=$("$plist" -extract value xml1 -o - "$original")
        if ! has "$key" "$prefs"; then "$plist" -insert "$key" -dictionary "$prefs"; fi
        "$plist" -replace "$enabled" -xml "$prior" "$prefs"
    elif has "$enabled" "$prefs"; then
        "$plist" -remove "$enabled" "$prefs"
    fi
    if ! has hadRouting "$original" && has "$key" "$prefs" && [ -z "$("$plist" -extract "$key" raw -o - "$prefs")" ]; then
        "$plist" -remove "$key" "$prefs"
    fi
    check_current
    if ! has hadFile "$original" && [ "$("$plist" -convert json -o - "$prefs" 2>/dev/null || :)" = '{}' ]; then
        rm -f "$file"
    else
        mv -f "$prefs" "$file"
    fi
    rm -f "$original"
    echo "Restored the previous setting. Restart the virtual Mac to apply it."
fi
