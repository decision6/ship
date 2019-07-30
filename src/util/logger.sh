#!/bin/bash
#
# Print user friendly and colored messages
#
# Protetore Shell Blocks - SH Utilities Package
# github.com.protetore/shell-blocks.git
#

if [[ $_ != "$0" ]]; then
    CWD=$(dirname ${BASH_SOURCE[0]})
else
    CWD=$(dirname "$0")
fi

# shellcheck source=src/util/colors.sh
source ${CWD}/colors.sh

DEBUG_DATE=0

# Message types
readonly LOGGER_ERR="ERR"
readonly LOGGER_WRN="WRN"
readonly LOGGER_INF="INF"

# Print messages to stdout or stderr if VERBOSE mode is enabled
function logger::out()
{
    if [ "$1" == "printf" ];
    then
        shift
        if [ $# -eq 1 ];
        then
            printf "$1"
        else
            printf "$@"
        fi
    else
        tmstmp=""
        if [ "$DEBUG_DATE" == "1" ];
        then
          tmstmp=$(date +"%Y-%m-%d %T")
          tmstmp="[$tmstmp] "
        fi

        if [ "$2" == "$LOGGER_ERR" ];
        then
            # Send to stderr
            printf "${COLORS_GRAY}${tmstmp}$1" 1>&2
        else
            printf "${COLORS_GRAY}${tmstmp}$1"
        fi
    fi
}

# debug using printf
function logger::printf() { logger::out printf "$@"; }

# Debug using no color
function logger::echo() { logger::out "${COLORS_NC}$1${COLORS_NC}\n"; }

# Debug sub activity
function logger::step() { logger::out "${COLORS_NC}    - $1${COLORS_NC}\n"; }

# Debug using RED for error
function logger::error() { logger::out "${COLORS_BKG_RED} $LOGGER_ERR ${COLORS_BKG_NC} ${COLORS_RED}$1${COLORS_NC}\n"; }

# Debug using ORANGE for warning
function logger::warn() { logger::out "${COLORS_BKG_LIGHTBLUE} $LOGGER_WRN ${COLORS_BKG_NC} ${COLORS_LIGHTBLUE}$1${COLORS_NC}\n"; }

# Debug using GREEN for warning
function logger::success() { logger::out "${COLORS_GREEN}$1${COLORS_NC}\n"; }

# Debug sub title using BLUE
function logger::sub() { logger::out "${COLORS_CYAN}@ $1${COLORS_NC}\n"; }

# Processing message - blinking
function logger::wait() { logger::out "${COLORS_LIGHTBLUE}█ ${COLORS_NC}\n"; }

# Debug title using YELLOW
function logger::title() {
  title=$(echo $1 | tr '[:lower:]' '[:upper:]')
  logger::out "${COLORS_YELLOW}********** $title *********${COLORS_NC}\n";
}

# Print code blocks in one color
function logger::code() { logger::out "${COLORS_BLUE}$1${COLORS_NC}\n"; }

# Print conf snipets in different color
function logger::conf() { logger::out "${COLORS_PURPLE}$1${COLORS_NC}\n"; }
