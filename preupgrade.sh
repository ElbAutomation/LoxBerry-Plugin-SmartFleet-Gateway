#!/usr/bin/env bash
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

pfolder="$3"
lbhomedir="$5"
tempfolder="$6"

quelle="$lbhomedir/config/plugins/$pfolder"

sicherung="$tempfolder/.fm-config"
mkdir -p "$sicherung" 2>/dev/null

if [ -d "$quelle" ]; then
    for datei in "$quelle"/* "$quelle"/.[!.]*; do
        [ -f "$datei" ] || continue
        name=$(basename "$datei")
        case "$name" in
            *.lock|pin.session) continue ;;
        esac
        cp -p "$datei" "$sicherung/" 2>/dev/null
        if ! cmp -s "$datei" "$sicherung/$name"; then
            echo "SmartFleet: Sicherung von $name fehlgeschlagen (Platte voll?) - Upgrade abgebrochen, die bestehende Installation bleibt unangetastet." >&2
            exit 2
        fi
    done
fi

exit 0

