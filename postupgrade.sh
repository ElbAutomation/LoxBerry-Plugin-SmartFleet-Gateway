#!/usr/bin/env bash
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

pfolder="$3"
lbhomedir="$5"
tempfolder="$6"

ziel="$lbhomedir/config/plugins/$pfolder"

mkdir -p "$ziel" 2>/dev/null

chmod 0775 "$ziel" 2>/dev/null

sicherung="$tempfolder/.fm-config"

if [ -d "$sicherung" ]; then
    for datei in "$sicherung"/* "$sicherung"/.[!.]*; do
        [ -f "$datei" ] || continue
        cp -p "$datei" "$ziel/" 2>/dev/null
    done
fi

exit 0

