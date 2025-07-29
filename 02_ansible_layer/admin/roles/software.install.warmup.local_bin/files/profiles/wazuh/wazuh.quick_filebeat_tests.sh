#!/bin/bash

show_example() {

    echo "  $(basename "$0")"
    echo " "
}

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
    echo ""
    echo ""
    echo NAME
    echo "  $(basename "$0") -  Quick filebeat tests "
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

    sudo /var/ossec/bin/wazuh-control status
    sudo filebeat test output

    sudo tail -200 /var/ossec/logs/alerts/alerts.log

else

    echo EXAMPLE
    echo "$(show_example)"
fi
