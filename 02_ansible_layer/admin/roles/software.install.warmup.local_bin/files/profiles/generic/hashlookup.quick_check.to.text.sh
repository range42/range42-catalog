#!/bin/bash

HASHLOOKUP_THIS() {

    (
        sha1sum "$1" |
            cut -f1 -d" " |
            parallel 'curl  -s https://hashlookup.circl.lu/lookup/sha1/{}' >/tmp/quick_check
    )

    (
        cat "/tmp/quick_check" |
            sed 's/hashlookup:trust/hashlookup_trust/g' |
            jq -c '{fileName:.FileName,fileSize:.FileSize, trust:.hashlookup_trust}' |
            jq -s '. | sort_by(.trust)' |
            jq -c '.[] | select (.fileName != null) | select (.trust <55)'
    )

    echo " $1 - done." 1>&2
}

echo "" 1>&2
echo "" 1>&2
echo " starting..." 1>&2
echo "" 1>&2

HASHLOOKUP_THIS "/bin/*"
HASHLOOKUP_THIS "/sbin/*"
HASHLOOKUP_THIS "/usr/local/bin/*"
HASHLOOKUP_THIS "/usr/local/sbin/*"

echo "" 1>&2
echo "" 1>&2
echo "" 1>&2
