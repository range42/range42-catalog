#!/bin/bash

show_example() {

    echo "  $(basename "$0")"
    echo " "
}

T_SERVICE="wazuh-dashboard"

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
    echo ""
    echo ""
    echo NAME
    echo "  $(basename "$0") -  Get status $T_SERVICE  - systemctl "
    echo ""
    echo OPTIONS
    echo "                         $(basename "$0") [-h|--help]"
    echo ""
    echo EXAMPLE
    echo "$(show_example)"
    echo ""
    exit 1
fi

if [ $# -eq 0 ]; then

    sudo systemctl status "$T_SERVICE"

else
    echo EXAMPLE
    echo "$(show_example)"
fi
