#!/bin/bash

show_example() {

    echo "  $(basename "$0")"
    echo " "
}

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
    echo ""
    echo ""
    echo NAME
    echo "  $(basename "$0") -  List current service units - systemctl "
    echo ""
    echo OPTIONS
    echo "                         $(basename "$0") [-h|--help]"
    echo ""
    echo EXAMPLE
    echo "$(show_example)"
    echo ""
    exit 1
fi

if [ $# -eq 1 ]; then

    systemctl list-units --type=service

else
    echo EXAMPLE
    echo "$(show_example)"
fi
