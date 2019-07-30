#!/bin/bash
#
# Configuration File Reader and Exporter to Variable
#
# Protetore Shell Blocks - SH Utilities Package
# github.com.protetore/shell-blocks.git
#

# Config files
declare -a CONFIG_FILES

function config::setFile() {
    local name=$1
    local file=$2
    CONFIG_FILES[name]=$file
}

function config::file() {
    local file

    if [[ ! ${CONFIG_FILES[key]+abc} ]]; then
        debugger::error "Config file not found ${file}"
        return 1
    fi

    file=${CONFIG_FILES[key]}
    if [[ ! -f ${file} ]]; then
        debugger::error "Config file not found ${file}"
        return 1
    fi

    echo "$(cat $file)"
}

function config::get() {
    local configPath=$1
    local config
    config=$(config::file $2)

    if [ "$3" == "--quotes" ]; then
        v=$(echo $config | $JQ "$configPath")
    else
        v=$(echo $config | $JQ -r "$configPath")
    fi

    if [[ ! "$v" == "" && ! "$v" == "null" && ! "$v" == "\"\"" ]]; then
        if [[ "$v" == "false" ]]; then
            v="0"
        elif [[ "$v" == "true" ]]; then
            v="1"
        fi
        echo "$v"
        return 0
    else
        v=""
    fi

    echo "$v"
}

function config::toVar() {
    local configVar=$1 value
    value=$(config::get $2 $3 $4)
    [[ $value ]] && eval $configVar=\$value
    return 0
}
