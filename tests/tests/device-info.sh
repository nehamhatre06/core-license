#!/bin/bash

GSM_DEVICE="/dev/ttyGSM2"
MODEM_LOCKFILE="/tmp/GSM2.lock"
SIGNAL_STRENGTH_TIMEOUT=5
INFO_ERR_FILE="/run/devices_info_err"

set -uxo pipefail

while true; do
	signal_strength=$(flock --timeout 4 "$MODEM_LOCKFILE" sh -c "echo -en 'AT+CSQ\n' | timeout $SIGNAL_STRENGTH_TIMEOUT atinout -e - $GSM_DEVICE - | sed -n '/^+CSQ/{p}' | awk -F':' '{print "'$2'"}' | awk -F',' '{print "'$1'"}' | tr -d '[:space:]'")
	if [[ "$signal_strength" =~ ^[0-9]+$ ]]
	then
		echo $signal_strength > /run/signal_strength
	fi

	fetch_pmic
	if [ $? -ne 0 ]
	then
	    echo "Couldnt read PMIC register" >> $INFO_ERR_FILE
	fi
	sleep 2
done
