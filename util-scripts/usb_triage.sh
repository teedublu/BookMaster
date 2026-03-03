#!/usr/bin/env bash

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
NC="\033[0m"

TARGET_SIZE_BYTES=1006632960   # exact 1GB size you showed

echo -e "${BLUE}USB 1GB Batch Triage (Manual Trigger)${NC}"
echo "Insert device → press ENTER to check."
echo "Press Ctrl+C to quit."
echo ""

while true; do
    read -p "Press ENTER to scan..."

    # Look for 1GB external physical disk
    DISK=$(diskutil list | awk -v size="$TARGET_SIZE_BYTES" '
        /^\/dev\/disk/ {disk=$1; gsub(":","",disk)}
        /external, physical/ {ext=1}
        $0 ~ size && ext==1 {print disk; ext=0}
    ')

    # Check profiler for UDisk
    PROFILER_PRESENT=$(system_profiler SPUSBDataType 2>/dev/null | grep -i "UDisk")

    if [[ -n "$DISK" ]]; then
        INFO=$(diskutil info "$DISK")
        RO=$(echo "$INFO" | grep "Media Read-Only" | awk '{print $3}')

        if [[ "$RO" == "No" ]]; then
            echo -e "${GREEN}RECOVERABLE:${NC} $DISK visible + writable"
        else
            echo -e "${YELLOW}READ-ONLY:${NC} $DISK visible but controller locked"
        fi

    elif [[ -n "$PROFILER_PRESENT" ]]; then
        echo -e "${YELLOW}USB-ONLY:${NC} Visible in USB but no mass storage (firmware likely bricked)"
    else
        echo -e "${RED}DEAD:${NC} Not detected at all"
    fi

    echo ""
done
