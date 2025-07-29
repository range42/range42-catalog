#!/bin/bash

#!/bin/bash

show_example() {

    echo "  $(basename "$0")"
    echo " "
}

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
    echo ""
    echo ""
    echo NAME
    echo "  $(basename "$0") -  Get status of the targeted service  units - systemctl "
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

    T_SERVICE="$1"

    sudo systemctl status "$T_SERVICE"

else
    echo EXAMPLE
    echo "$(show_example)"
fi
