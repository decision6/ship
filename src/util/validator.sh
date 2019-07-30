#!/bin/bash
#
# Validation Expressions
#
# Protetore Shell Blocks - SH Utilities Package
# github.com.protetore/shell-blocks.git
#

function validator::isNumeric() {
    if [[ "$2" == "pos" ]]; then
        re='^[0-9]+([.][0-9]+)?$'
    elif [[ "$2" == "neg" ]]; then
        re='^-[0-9]+([.][0-9]+)?$'
    else
        re='^-?[0-9]+([.][0-9]+)?$'
    fi

    if ! [[ $1 =~ $re ]] ; then
        return 1
    fi

    return 0
}

function validator::isInteger() {
    if [[ "$2" == "pos" ]]; then
        re='^[0-9]+$'
    elif [[ "$2" == "neg" ]]; then
        re='^-[0-9]+$'
    else
        re='^-?[0-9]+$'
    fi

    if ! [[ $1 =~ $re ]] ; then
        return 1
    fi

    return 0
}

function validator::isBetween() {
    if isNumeric $1 && isNumeric $2 && isNumeric $3; then
        geMin=$(echo $1'>='$2 | bc -l)
        leMax=$(echo $1'<='$3 | bc -l)
        if [[ $geMin -eq 1 ]] && [[ $leMax -eq 1 ]]; then
            return 0
        else
            return 1
        fi
    fi

    return 1
}
