#!/bin/sh
# FIXTURE — a stand-in for the Asahi Alarm bootstrap. Never executed by tests.
    export INSTALLER_DATA="https://asahi-alarm.org/installer_data.json"
echo "fixture: would exec ./install.sh"
exit 0
