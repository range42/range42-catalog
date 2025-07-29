#!/bin/bash

show_example() {

    echo "  $(basename "$0") IP_TO_WHITE_LIST"
    echo "  $(basename "$0") *SPECIAL_ARG*: \"__OPEN_SSH_ONLY___WITHOUT_IP_FILTERING\""
    echo ""
    echo ""
}

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then

    echo ""
    echo ""
    echo NAME
    echo "  $(basename "$0") - White list IP source specified in parameter to use SSH "
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

    TARGET_IP="$1"

    sudo ufw reset

    if [ "$TARGET_IP" == "__OPEN_SSH_ONLY___WITHOUT_IP_FILTERING" ]; then

        sudo ufw allow port 22
        sudo ufw allow port 2222
    else

        sudo ufw reset
        sudo ufw allow from "$TARGET_IP" to any port 22
        sudo ufw allow from "$TARGET_IP" to any port 2222

    fi

    sudo ufw enable
    sudo ufw status verbose

else

    echo EXAMPLE
    echo "$(show_example)"
fi
