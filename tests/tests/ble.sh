#!/bin/bash

TEST_STATUS_FILE="/run/ble-status"
TEST_LOG_FILE="/run/ble-test-log"
BIN_LOG_FILE="/run/ble-bin-log"
PERIPHERAL_FILE="/tmp/peripheral-id"
JUDGE="/run/ble"
VERIFY_REBOOT="/var/local/factorytest-ble-reboot"
WAIT_TIME=20

# So that GUI (user) gets to see that meter will be rebooted
REBOOT_TIMEOUT=30
DO_REBOOT=1
RETRIES=3


rm -f $JUDGE $TEST_STATUS_FILE $TEST_LOG_FILE $BIN_LOG_FILE

BINDIR=$(dirname "$0")

echo 2 > $TEST_STATUS_FILE
IS_RESET=0
count=0
while true
do
	timeout $WAIT_TIME $BINDIR/client $(cat $PERIPHERAL_FILE | awk -F'=' '{print $2}') 1>$BIN_LOG_FILE 
	if [ -e $JUDGE ]; then
        rm -f $VERIFY_REBOOT
		echo 0 > $TEST_STATUS_FILE
		exit 0
	else
		case $(tail -n1 $BIN_LOG_FILE) in
		*"Scanning"*)
			echo "Device wasnt reachable, Check if the BLE service is running in RPi" >> $TEST_LOG_FILE
			# We use `3` as a failure state, and to communicate to front-end that this failure
			# should trigger a restart of BLE service in tester RPi.
			echo 3 > $TEST_STATUS_FILE
			exit 1
		;;
		*"Connected"*)
			if [[ $count -ge $RETRIES ]]
			then
				echo "Retries exceeded." >> $TEST_LOG_FILE
				echo 1 > $TEST_STATUS_FILE
				exit 1
			fi	
			count=$((count+1))
			echo "Device connection succeeded, BLE comm failed, Retrying: $count time" >> $TEST_LOG_FILE
		;;
		*)
			echo "Unknown error occured!!, Trying BLE hardware reset" >> $TEST_LOG_FILE
			if [ $IS_RESET -eq 0 ]
			then
				echo "Resetting BLE hardware..." >> $TEST_LOG_FILE
				for i in {1..2}
				do
					timeout 10 sh -c 'echo serial0-0 > /sys/bus/serial/drivers/hci_uart_bcm/unbind'
					timeout 10 sh -c 'echo serial0-0 > /sys/bus/serial/drivers/hci_uart_bcm/bind'
				done
				sleep 2
				IS_RESET=1
			else
				echo "BLE hardware reset didnt succeed. Performing a reboot on meter after $REBOOT_TIMEOUT secs" >> $TEST_LOG_FILE
                if [ -e $VERIFY_REBOOT ]
                then
                    echo "Meter already came across this condition, halting meter reboot. Possible BLE hardware problem." >> $TEST_LOG_FILE
                    echo 1 > $TEST_STATUS_FILE
                    exit 1
                fi
				echo 1 > $TEST_STATUS_FILE
				if [[ $DO_REBOOT -eq 1 ]]
				then
					sleep $REBOOT_TIMEOUT
					reboot
				fi
				exit 1
			fi

		;;
		esac
	fi
done
