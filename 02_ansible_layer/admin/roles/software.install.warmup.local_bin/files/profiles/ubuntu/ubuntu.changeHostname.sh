#!/bin/bash

show_example() {

   echo "  $(basename "$0") NEW_HOSTNAME"
   echo ""
   echo ""
}

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
   echo ""
   echo ""
   echo NAME
   echo "  $(basename "$0") - Change hostname on ubuntu systems"
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

   NEW_HOSTNAME="$1"

   if [ "$(id -u)" != "0" ]; then
      echo " ::  not a root priv user " 1>&2
      exit 1

   fi

   echo "$NEW_HOSTNAME" >/etc/hostname
   sed -i "s/127.0.1.1 .*/127.0.1.1 $NEW_HOSTINFO/g" /etc/hosts

   echo "" 1>&2
   echo " :: new hostname - $(hostname)" 1>&2
   echo "" 1>&2

else
   echo EXAMPLE
   echo "$(show_example)"
fi
