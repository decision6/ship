#!/bin/bash
#
# Publish Messages to Slack Channel
#
# Protetore Shell Blocks - SH Utilities Package
# github.com.protetore/shell-blocks.git
#

SLACK_HOOK=""
SLACK_CHANNEL=""

function slack::send() {

    if [ "$SLACK_HOOK" == "" ] || [ "$SLACK_CHANNEL" == "" ];
    then
        return 0
    fi

    # format message as a code block ```${msg}```
    SLACK_MESSAGE="\`\`\`$1\`\`\`"
    SLACK_URL=https://hooks.slack.com/services/${SLACK_HOOK}

    if [ "$2" == "" ];
    then
        messageType="INFO"
    else
        messageType=$2
    fi

    case "$messageType" in
        INFO)
            SLACK_ICON=''
            ;;
        WARNING)
            SLACK_ICON=':warning:'
            ;;
        ERROR)
            SLACK_ICON=':bangbang:'
            ;;
        *)
            SLACK_ICON=''
            ;;
    esac

    #-o /dev/null -w "%{http_code}"
    status=$(curl -s -X POST --data "payload={\"text\": \"${SLACK_ICON} ${SLACK_MESSAGE}\", \"username\": \"ship\", \"channel\": \"${SLACK_CHANNEL}\"}" ${SLACK_URL})

    if [ "$status" == "ok" ];
    then
        decho "Slack notified."
        return 0
    else
        derror "Error notifying Slack."
        return 1
    fi
}
