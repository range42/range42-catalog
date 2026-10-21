#!/usr/bin/env bash
# customize_misp.sh — range42 lab settings applied on top of the misp-docker defaults.
# misp-core runs it on every boot after its own configuration, before PHP-FPM starts.
set -euo pipefail

CAKE=(sudo -u www-data /var/www/MISP/app/Console/cake)

# set_setting NAME VALUE [extra setSetting flags]
set_setting() {
    echo "[customize] $1 = $2"
    "${CAKE[@]}" Admin setSetting -q "${@:3}" "$1" "$2"
}

# New content stays inside the creating org until a team shares it on purpose.
set_setting "MISP.default_event_distribution"        0
set_setting "MISP.default_attribute_distribution"    0
set_setting "MISP.default_object_distribution"       0
set_setting "MISP.default_galaxy_distribution"       0
set_setting "MISP.default_eventreport_distribution"  0
set_setting "MISP.default_analyst_data_distribution" 0

# The stack ships no mail relay; MISP's validator rejects this without --force.
set_setting "MISP.disable_emailing" true --force

# Students export events as PDF deliverables.
set_setting "Plugin.Export_pdfexport_enabled" true
