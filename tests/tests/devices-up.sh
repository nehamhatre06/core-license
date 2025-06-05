#!/bin/bash

# Expects following things:
#	- gpio-pins directions are set and exported at this point of time.
#	- hl8518-device should be started.

set -ux

# TODO: Move error messages to a common file.

audioCardName='barometerbbv1'
PPCB_VER=$(cat /tmp/tests/current_ppcb_ver) # Exactly match the string thats expected
AT_TIMEOUT=4
GSM_DEV="/dev/ttyGSM2"
MODEM_LOCKFILE="/tmp/GSM2.lock"
LOG_FILE="/run/device-test-log"
STATUS_FILE="/run/device-test-status"
RTC_CHIP_ADDR="0x51"
EEPROM_CHIP_ADDR="0x54"
TEST_STATUS=2
MODEM_START_TIMEOUT=10
BLE_DEVICE="/sys/class/bluetooth/hci0/device"
tvPin=4
mainsPin=13

gpioin $tvPin

BINDIR=$(dirname "$0")

onExit() {
	echo "INT signal received!" > $LOG_FILE
	echo 1 > $STATUS_FILE
	exit 1
}

checkErr() {
	if [ x"$1" != x"0" ]
	then
		echo "$2" >> $LOG_FILE 
		TEST_STATUS=1
	fi
}

bailErr() {
	if [ x"$1" != x"0" ]
	then
		echo "$2" > $LOG_FILE 
		echo 1 > $STATUS_FILE
		exit 1
	fi
}

trap onExit SIGINT SIGTERM

rm -f $LOG_FILE $STATUS_FILE

# To Mark START OF TEST!!!
echo $TEST_STATUS > $STATUS_FILE

# TODO: Remove and test
# We ensure a clean state whenever the test starts
systemctl stop hl8518-sim-test
while ! timeout 10 systemctl stop hl8518; do systemctl kill -s SIGKILL hl8518 ; done
systemctl stop hl8518-device

# Verify if EEPROM has meter-id
$BINDIR/eeprom_test
checkErr $? "EEPROM verification FAILED!!!!"

# Check if meter_id bin and EEPROM id matches
if [ "$($BINDIR/eeprom_meter_id)" != "$(meter_id)" ]
then
	checkErr 1 "EEPROM meter-id and meter_id reported by meter dont match"	
fi

# Detect RTC (hwclock -r can give success status even if you cant reach rtc sometimes - you must check if clock is read properly)
rtc_test_status=1
rtc_test=''
tries=0
while [ $rtc_test_status -ne 0 ] || [ -z "$rtc_test" ] && [ $tries -lt 20 ] ; do
tries=$(($tries+1))
rtc_test=$(hwclock -r)
rtc_test_status=$?
sleep 1
done

if [ -z "$rtc_test" ] ; then 
	checkErr 1 "Couldnt detect/communicate with RTC on i2c-bus. Check RTC"
fi
date -d "$rtc_test"
checkErr "$?" "Couldnt parse the date strin: $rtc_test"

# Check if both jacks are plugged and audio card is available
$BINDIR/jack_detect "ext"
checkErr $? "External mic not plugged!!"

$BINDIR/jack_detect "aux"
checkErr $? "Aux cable not plugged!!"

aplay -l | grep 'card 0' | awk '{print $3}' | grep -q "$audioCardName"
checkErr $? "Audio card name doesnt match with expected: $audioCardName"

# Check if SPI comm could be established
pcbVer=$($BINDIR/fetch_powerpcb_comm FW_VERSION)
if [ $? -ne 0 ]; then
	checkErr 1 "SPI Communication failed!!"
elif [ x"$pcbVer" != x"$PPCB_VER" ]; then
	checkErr 1 "Power PCB FW version mismatch!!"
fi

# Check if BLE device is available.
if [ ! -L $BLE_DEVICE ]; then
	checkErr 1 "BLE device not found!!!"
fi
btmgmt info 2>&1 >/dev/null
checkErr $? "BLE driver failed!!, Reboot"


if [ x"$TEST_STATUS" != x"2" ]; then
	echo $TEST_STATUS > $STATUS_FILE
	exit 1
fi

# Start snapdemo, Remove the receiver dependency
# aplay is already running through system service
systemctl stop aplay_loop.service
alsactl -f $BINDIR/auxTest.conf restore
#systemctl start aplay_loop
systemctl start aplay_loop.service receiver.service snapdemo.service
#alsactl -f $BINDIR/auxTest.conf restore

# Mains ON Check.
gpioval $mainsPin | grep -q 1
bailErr "$?" "Mains ON not detected!!!"

# Tamper check.
meterTamper=$($BINDIR/fetch_powerpcb_comm METER_TAMPER_PIN_STATUS)
if [ $? -ne 0 ]; then
	bailErr 1 "SPI Communication failed!!"
elif [ $meterTamper == "FF" ]; then
	meterTamper=1
else
	meterTamper=0
fi
bailErr "$meterTamper" "Meter Tamper detected!!!"

# Setting TV Threshold
$BINDIR/fetch_powerpcb_comm "TV_THRESHOLD" "w" "A0" "00" "A0" "00"
bailErr "$?" "Couldnt set the TV threshold!!!!"

tvTamper=$($BINDIR/fetch_powerpcb_comm TV_TAMPER_PIN_STATUS)
if [ $? -ne 0 ]; then
	bailErr 1 "SPI Communication failed!!"
elif [ $tvTamper == "FF" ]; then
	tvTamper=1
else
	tvTamper=0
fi
bailErr "$tvTamper" "TV Tamper detected!!!"

MAX_COUNT=5
count=0

while [[ $count -lt $MAX_COUNT ]]
do
        gpioval $tvPin | grep -q 1
        tvonStatus=$?
        if [ x"$tvonStatus" == x"0" ]
        then
                break
        fi
        sleep 3
        count=$((count+1))
done

bailErr $tvonStatus "TV Plug not detected!!"

# HACK!! To make /tmp/tests/tv_status binary to report 1
echo 1 > /run/tv_status

# Clearing SOS states
$BINDIR/fetch_powerpcb_comm "CLR_SOS" "w" "1"
if [ "$?" -ne 0 ]
then
    bailErr 1 "Clearing SOS status failed"
fi

# Set RTC time
systemctl stop ntpd.service \
	&& ntpdate time.google.com \
	&& hwclock -w
/opt/fluctus/powerpcb/set_time
bailErr $? "Setting RTC Value, failed!!!"

echo "Current meter time: $(date)"

# Ensuring snap license
$BINDIR/ensure-snap-license
bailErr $? "Ensuring SNAP license failed!!!"

exec {modemlock}<>"$MODEM_LOCKFILE"
if ! flock --timeout 20 "$modemlock"; then
	echo "Timedout waiting for lock on ${MODEM_LOCKFILE}." > "$LOG_FILE"
	echo 1 > $STATUS_FILE
	exit 1
fi

# Modem responds or not.
atResp=$(systemctl start hl8518-device; sleep 1; echo -ne 'AT\nAT\nAT\n' | timeout $AT_TIMEOUT atinout - $GSM_DEV -)
if [[ "$atResp" != *"OK"* ]]
then
	checkErr 1 "AT comm failed!!"
fi

cat /sys/class/mmc_host/mmc0/mmc0\:*/name > /var/local/sdcard_partno
#if [[ "$(cat /var/local/sdcard_partno)" != "SA16G" ]]
if [[ "$(cat /var/local/sdcard_partno)" != "WC16G" ]]
then
	echo "SDcard part no doesnt match: $(cat /var/local/sdcard_partno)" > "$LOG_FILE"
	echo 1 > $STATUS_FILE
	exit 1
fi

# TODO: Check with nilesh
cat /sys/class/mmc_host/mmc0/mmc0\:*/serial > /var/local/sdcard_serial
if [ ! -s "/var/local/sdcard_serial" ]
then
	echo "Couldnt read SD card serial" > "$LOG_FILE"
	echo 1 > $STATUS_FILE
	exit 1
fi

CURRENT_BOOT_COMMIT=$(grep -P -a -o '\bboottarget=[^\s]*' /proc/cmdline | egrep -o '[0-9a-f]*$')
if [ -z "$CURRENT_BOOT_COMMIT" ]
then
	echo "Couldnt get the commit id" > $LOG_FILE
	echo 1 > $STATUS_FILE
	exit 1
fi

echo $CURRENT_BOOT_COMMIT > "/var/local/factory_os_commit"

echo 0 > $STATUS_FILE
exit 0
