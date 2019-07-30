#!/bin/bash
#====================================================================
#title           :Ship
#description     :Marathon deploy plugin
#author          :protetore
#date            :20170609
#version         :0.1
#usage           :ship [ACTION] [OPTIONS]
#bash_version    :4.1.5(1)-release
#====================================================================

CALL_ATTEMPTS=3
PREVIOUS_FILE="marathon_previous.json"
MARATHON_API_URL=${CONTAINER_MGMT_URL:=""}
MARATHON_API_USR=${CONTAINER_MGMT_USR:=""}
MARATHON_API_PWD=${CONTAINER_MGMT_PWD:=""}
MARATHON_API_AUTH=""

if [ "$MARATHON_API_USR" != "" ] && [ "$MARATHON_API_PWD" != "" ]; then
    MARATHON_API_AUTH="-u ${MARATHON_API_USR}:${MARATHON_API_PWD}"
fi

if [ "${MARATHON_API_URL: -1}" == "/" ]; then
    MARATHON_API_URL=${MARATHON_API_URL%?}
fi

MARATHON_API_VER="v2"
MARATHON_API_CMD="curl -Lks --write-out HTTPSTATUS:%{http_code} -H 'Content-Type: application/json' ${MARATHON_API_AUTH}"
MARATHON_API_GET="${MARATHON_API_CMD} -XGET ${MARATHON_API_URL}/${MARATHON_API_VER}/apps"
MARATHON_API_PUT="${MARATHON_API_CMD} -XPUT ${MARATHON_API_URL}/${MARATHON_API_VER}/apps"
MARATHON_API_DEL="${MARATHON_API_CMD} -XDELETE ${MARATHON_API_URL}/${MARATHON_API_VER}/apps"
MARATHON_API_ALL="${MARATHON_API_CMD} -XGET ${MARATHON_API_URL}/${MARATHON_API_VER}/apps"
MARATHON_API_CANCEL="${MARATHON_API_CMD} -XDELETE ${MARATHON_API_URL}/${MARATHON_API_VER}/deployments"

function call()
{
    url="$@"
    c=0
    while [ $c -le $CALL_ATTEMPTS ]; do
        c=$((c+1))
        result=$(eval $url)
        if [ $? -eq 0 ]; then
            # extract the body and HTTP status
            HTTP_BODY=$(echo $result | tr -d '\n' | sed -e 's/HTTPSTATUS\:.*//g' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            HTTP_STATUS=$(echo $result | tr -d '\n' | sed -e 's/.*HTTPSTATUS://' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

            if [ "$result" == "" ] || [ "$HTTP_STATUS" == "" ]; then
                return 1
            fi

            $JQ -n --arg s "$HTTP_STATUS" --argjson b "$HTTP_BODY" '{"status": $s, "body": $b}'
            return 0
        fi
    done

    return 1
}

# ######################
# Marathon API Functions
# ######################

function get()
{
    appName=$1
    result=$(call "${MARATHON_API_GET}/${appName}")
    if [ ! $? -eq 0 ]; then
        derror "Error calling Marathon API (${MARATHON_API_GET}/${appName})"
        return 1
    fi

    status=$(echo $result | $JQ '.status' | tr -d '"')
    body=$(echo $result | $JQ '.body')
    if [ $status -eq 200 ]; then
        echo $body
        return 0
    fi

    return 1
}

function list()
{
    result=$(call "${MARATHON_API_ALL}")
    if [ ! $? -eq 0 ]; then
        echo "Error calling Marathon API (${MARATHON_API_ALL})"
        return 1
    fi

    status=$(echo $result | $JQ '.status' | tr -d '"')
    body=$(echo $result | $JQ '.body')
    echo $body

    if [ $status -eq 200 ]; then
        return 0
    fi

    return 1
}

function create()
{
    appName=$1
    jsonFile=$2
    params=""

    if [ "$3" == "--force" ]; then
        params="?force=true"
    fi

    result=$(call "${MARATHON_API_PUT}/${appName}${params} -d@${jsonFile}")
    if [ ! $? -eq 0 ]; then
        echo "Error calling Marathon API (${MARATHON_API_PUT}/${appName})"
        return 1
    fi

    status=$(echo $result | $JQ '.status' | tr -d '"')
    body=$(echo $result | $JQ '.body')
    echo $body

    if [ "$status" == "200" ] || [ "$status" == "201" ]; then
        return 0
    elif [ "$status" -eq "409" ]; then
        return 2
    fi

    return 1
}

function delete()
{
    appName=$1
    result=$(call "${MARATHON_API_DEL}/${appName}")
    if [ ! $? -eq 0 ]; then
        echo "Error calling Marathon API (${MARATHON_API_DEL}/${appName})"
        return 1
    fi

    status=$(echo $result | $JQ '.status' | tr -d '"')
    body=$(echo $result | $JQ '.body')
    if [ $status -eq 200 ]; then
        echo $body
        return 0
    fi

    return 1
}

function remoteUpdate()
{
    appName=$1
    updateData=$2

    result=$(call "${MARATHON_API_PUT}/${appName} -d '$updateData'")
    if [ ! $? -eq 0 ]; then
        echo "Error calling Marathon API (${MARATHON_API_DEL}/${appName})"
        return 1
    fi

    status=$(echo $result | $JQ '.status' | tr -d '"')
    body=$(echo $result | $JQ '.body')
    echo $body

    if [ $status -eq 200 ]; then
        return 0
    elif [ $status -eq 409 ]; then
        return 2
    elif [ $status -eq 404 ]; then
        return 3
    fi

    return 1
}

# #################
# Cluster Functions
# #################

function remoteDeploy()
{
    dtitle "Marathon Deploy"
    decho  "Starting Marathon deploy..."
    previousTag=""
    previousVersion=""
    APP_INSTANCES=1

    if [ -f $SHIP_TMP_DIR/$APP_NAME/$PREVIOUS_FILE ]; then
        > $SHIP_TMP_DIR/$APP_NAME/$PREVIOUS_FILE
    else
        touch $SHIP_TMP_DIR/$APP_NAME/$PREVIOUS_FILE
    fi

    # Check if the app exists in cluster
    isNew=0
    app=$(get "$APP_NAME")
    if [[ $? -eq 1 ]] || [[ "$app" == "" ]]; then
        # If don't exists create based on template
        decho "New application detected!"
        dstep "Creating new application..."
        isNew=1
    else
        dstep "Updating existing application..."

        # Get actual image tag for information
        previousTag=$(echo $app | $JQ '.app.container.docker.image' | tr -d '"' | awk -F":" '{ print $NF }')
        if [ "$previousTag" == "" ]; then
            previousTag="latest"
        fi

        if [ "$previousTag" == "$APP_VERSION" ]; then
            dwarn "Application already on version $APP_VERSION (use --force to execute anyway)"
            if [[ $FORCE -eq 1 ]]; then
                decho "Forcing deploy anyway (--force used)"
            else
                return 1
            fi
        fi

        # Get previous version for rollback
        previousVersion=$(echo $app | $JQ '.app.version' | tr -d '"')
        echo $app > $SHIP_TMP_DIR/$APP_NAME/$PREVIOUS_FILE

        # Get actual number of instances to keep the same
        instances=$(echo $app | $JQ '.app.instances' | tr -d '"')
        if [ "$instances" != "" ] && [ "$instances" != "null" ]; then
            APP_INSTANCES=$instances
        fi

        decho  "Updating from image tag $previousTag to $APP_VERSION..."
    fi

    # Copy template to temp dir
    dstep "Creating template..."
    cp $TEMPLATES_DIR/marathon/app.json $SHIP_TMP_DIR/$APP_NAME/
    TEMPLATE_FILE=$SHIP_TMP_DIR/$APP_NAME/app.json

    # Replace variables
    APP_PORT=${APP_PORT:-0}
    APP_EXPOSE=${APP_EXPOSE:-0}
    APP_VERSION=${APP_VERSION:-"latest"}

    sed -i -e "s#__APP__#$APP_NAME#g" $TEMPLATE_FILE
    sed -i -e "s#__VERSION__#$APP_VERSION#g" $TEMPLATE_FILE
    sed -i -e "s#__PORT__#$APP_PORT#g" $TEMPLATE_FILE
    sed -i -e "s#__SCOPE__#$APP_SCOPE#g" $TEMPLATE_FILE
    sed -i -e "s#__TYPE__#$APP_TYPE#g" $TEMPLATE_FILE
    sed -i -e "s#__URL__#$APP_URL#g" $TEMPLATE_FILE
    sed -i -e "s#__INSTANCES__#$APP_INSTANCES#g" $TEMPLATE_FILE
    sed -i -e "s#__EXTERNAL__#$APP_EXPOSE#g" $TEMPLATE_FILE
    sed -i -e "s#__HEALTH__#$APP_HEALTH#g" $TEMPLATE_FILE
    sed -i -e "s#__REGISTRY__#$REGISTRY_URL#g" $TEMPLATE_FILE
    sed -i -e "s#__CONTAINER_PERSISTENT_DIR__#$CONTAINER_PERSISTENT_DIR#g" $TEMPLATE_FILE
    sed -i -e "s#__CONTAINER_SHARED_DIR__#$CONTAINER_SHARED_DIR#g" $TEMPLATE_FILE
    sed -i -e "s#__PERSISTENT_DATA_DIR__#$PERSISTENT_DIR#g" $TEMPLATE_FILE
    sed -i -e "s#__SHARED_DATA_DIR__#$SHARED_DATA_DIR#g" $TEMPLATE_FILE
    sed -i -e "s#__CPU_LIMIT__#$CPU_LIMIT#g" $TEMPLATE_FILE
    sed -i -e "s#__MEMORY_LIMIT__#$MEMORY_LIMIT#g" $TEMPLATE_FILE

    template=$(cat $TEMPLATE_FILE)

    # Add custom labels
    if [ ! -z "$APP_LABELS" ]; then
        count=$(echo $APP_LABELS | $JQ '. | length' | sed 's/null/0/g')
        for ((i=0;i<$count;i)); do
            labelName=$(echo $APP_LABELS | $JQ '.['${i}'].name' | tr -d '"')
            labelValue=$(echo $APP_LABELS | $JQ '.['${i}'].value' | tr -d '"')
            template=$(echo $template | jq ".labels = {\"$labelName\": \"$labelValue\"}")
        done
    fi

    # Add custom env vars
    if [ ! -z "$APP_ENV" ]; then
        count=$(echo $APP_ENV | $JQ '. | length' | sed 's/null/0/g')
        for ((i=0;i<$count;i)); do
            envName=$(echo $APP_ENV | $JQ '.['${i}'].name' | tr -d '"')
            envValue=$(echo $APP_ENV | $JQ '.['${i}'].value' | tr -d '"')
            template=$(echo $template | jq ".env = {\"$envName\": \"$envValue\"}")
        done
     fi

         # Prepare mounts
    if [ ! -z "$APP_VOLUMES" ]; then
        count=$(echo $APP_VOLUMES | $JQ '. | length' | sed 's/null/0/g')
        for ((i=0;i<$count;i)); do
            hostPath=$(echo $APP_VOLUMES | $JQ '.['${i}'].host' | tr -d '"')
            containerPath=$(echo $APP_VOLUMES | $JQ '.['${i}'].container' | tr -d '"')
            mode=$(echo $APP_VOLUMES | $JQ '.['${i}'].mode' | tr -d '"' | tr '[:lower:]' '[:upper:]')

            if [ "$mode" == "" ] || [ "$mode" == "NULL" ]; then
                mode="RW"
            elif [ "$mode" != "RW" ] && [ "$mode" != "RO" ]; then
                derror "Wrong mount point mode: $mode"
                return 1
            fi

            if [ "${hostPath:0:1}" != "/" ] || [ "${containerPath:0:1}" != "/" ]; then
                derror "Host and container paths in mount points must start with /"
                return 1
            fi

            template=$(echo $template | jq ".container.volumes[.container.volumes| length] |= .  {\"containerPath\": \"${containerPath}\", \"hostPath\": \"${hostPath}\", \"mode\": \"${mode}\"}")
        done
    fi

    # Save the updated template
    echo -n "$template" > $TEMPLATE_FILE

    # Try to deploy and ask to force if a deployment is already running
    dstep "Starting deploy..."
    force=""
    while true; do
        result=$(create "$APP_NAME" "$TEMPLATE_FILE" "$force")
        stat=$?
        if [ $stat -eq 0 ]; then
            dstep "Deploy started"
            break
        elif [ $stat -eq 2 ]; then
            decho "There is another deployment running for this app"

            while true; do
                read -p "Do you want to overwrite it? [Y/n] " opt
                case $opt in
                    [Yy]* ) force="--force"; break;;
                    [Nn]* ) derror "Deploy aborted"; return 1;;
                    * ) echo "Please answer y or n";;
                esac
            done
        else
            derror "There was an error creating Marathon app:"
            decho $result
            return 1
        fi
    done

    #deploymentId=$(echo $result | $JQ '.deploymentId' | tr -d '"')
    deployVersion=$(echo $result | $JQ '.version' | tr -d '"')
    remoteCheckDeploy "$APP_NAME" "$deployVersion" $APP_INSTANCES
    deployStatus=$?

    if [[ $deployStatus -eq 0 ]]; then
        # Success
        decho "App $APP_NAME deployed."
        return 0
    else
        # Something went wrong, if its an existing app, try to rollback
        if [ $isNew -eq 0 ]; then
            derror "Deploy failed, triggering rollback..."
            remoteRollback $APP_NAME $previousVersion
            if [ ! $? -eq 0 ]; then
                derror "Error triggering rollback"
                return 1
            fi

            remoteCheckDeploy "$APP_NAME" "$previousVersion" $APP_INSTANCES
            deployStatus=$?

            if [[ $deployStatus -eq 0 ]]; then
                derror "Error performing rollback"
                derror "Application never went ready"
                return 1
            fi

            decho "Rollback succeeded"
        else
            derror "Deploy Failed"
        fi

        return 1
    fi

    return 0
}

function remoteDestroy()
{
    # Check if the app exists in cluster
    dsub "Checking if application exists..."
    app=$(get "$APP_NAME")
    if [[ $? -eq 1 ]] || [[ "$app" == "" ]]; then
        # If don't exists create based on template
        derror "Application $APP_NAME not found on cluster"
        return 1
    else
        dsub "Performing destruction..."
        decho "Destroying $APP_NAME in production..."
        result=$(delete $APP_NAME)
        if [ ! $? -eq 0 ]; then
            decho
            derror "There was an error removing app:"
            decho $result
            return 1
        else
            decho
            dwarn "Application $APP_NAME destroyed"
            return 0
        fi
    fi

    return 0
}

function remoteCheckDeploy()
{
    appName="$1"
    desiredVersion="$2"
    instances=$3
    attempts=0
    decho "Monitoring deployment status..."
    dstep "DESIRED VERSION: $desiredVersion"
    dstep "DESIRED INSTANCES: $instances"

    if [ "$desiredVersion" == "" ]; then
        derror "Empty version, monitoring deployment is not possible"
        return 1
    fi

    while [[ $attempts -lt $REMOTE_CHECKS ]];
    do
        attempts=$(( attempts+1 ))

        # Progress
        dots=$(echo -ne `yes '-'| head -${attempts}` | tr -d ' ')
        progress=$(printf "%-${REMOTE_CHECKS}s" "$dots>")
        echo -ne "    - PROGESS: [ ${progress} ] ( ${attempts} / ${REMOTE_CHECKS} )\r"

        app=$(get $appName)
        currentVersion=$(echo $app | $JQ '.app.version' | tr -d '"')
        running=$(echo $app | $JQ '.app.tasksRunning' | tr -d '"')
        healthy=$(echo $app | $JQ '.app.tasksHealthy' | tr -d '"')
        staged=$(echo $app | $JQ '.app.tasksStaged' | tr -d '"')
        deployments=$(echo $app | $JQ '.app.deployments | length' | tr -d '"')

        # App is in the desired version with the desired number of healty and
        # runnign instances
        if [ "$currentVersion" == "$desiredVersion" ] && \
           [ "$staged" == "0" ] && \
           [ "$deployments" == "0" ] && \
           [ "$running" == "$instances" ] && \
           [ "$healthy" == "$instances" ]; then
            echo
            return 0
        fi

        sleep $SLEEP_TIME
    done

    echo
    return 1
}

function remoteRollback()
{
    dtitle "Rollback Application"
    appName=$1
    previousVersion=$2

    dstep "PREVIOUS VERSION: $previousVersion"

    dstep "Checking Previous Version..."
    if [ "$previousVersion" == "" ]; then
        if [ ! -f $SHIP_TMP_DIR/$appName/$PREVIOUS_FILE ]; then
            derror "No previous version specified"
            return 1
        fi

        previousVersion=$($JQ '.app.version' $SHIP_TMP_DIR/$APP_NAME/$PREVIOUS_FILE | tr -d '"' | sed 's/null//g')
        if [ "$previousVersion" == "" ]; then
            derror "No previous version specified"
            return 1
        fi
    else
        previousVersion=$1
    fi

    dstep "Triggering rollback..."
    result=$(remoteUpdate $appName "{\"version\": \"$previousVersion\"}")
    if [ ! $? -eq 0 ]; then
        derror "Error performing rollback"
        return 1
    fi

    dstep "Rollback triggered"
    return 0
}

function remoteList()
{
    dtitle "Marathon Services"
    decho

    apps=$(list)
    if [ ! $? -eq 0 ]; then
        derror "Error listing apps"
        return 1
    fi

    appsCount=$(echo $apps | $JQ '.apps | length' | sed 's/null/0/g')
    if [ ! $? -eq 0 ]; then
        derror "Error listing apps"
        return 1
    fi

    if [ $appsCount -eq 0 ]; then
        derror "No apps found"
        return 0
    fi

    dprintf "%18s\t%9s\t%9s\t%9s\t%9s\t%24s\t%s\n" "ID" "STAGED" "RUNNING" "HEALTHY" "UNHEALTHY" "VERSION" "IMAGE"
    for ((i=0;i<$appsCount;i++))
    do
        app=$(echo $apps | $JQ -c '.apps['${i}']')
        appId=$(echo $app | $JQ '.id' | tr -d '"')
        appImage=$(echo $app | $JQ '.container.docker.image' | tr -d '"')
        appStaged=$(echo $app | $JQ '.tasksStaged' | tr -d '"' | xargs -I{} printf "%04d" {})
        appRunning=$(echo $app | $JQ '.tasksRunning' | tr -d '"' | xargs -I{} printf "%04d" {})
        appHealthy=$(echo $app | $JQ '.tasksHealthy' | tr -d '"' | xargs -I{} printf "%04d" {})
        appUnhealthy=$(echo $app | $JQ '.tasksUnhealthy' | tr -d '"' | xargs -I{} printf "%04d" {})
        appVersion=$(echo $app | $JQ '.version' | tr -d '"')
        dprintf "%18s\t%9s\t%9s\t%9s\t%9s\t%24s\t%s\n" ${appId} $appStaged $appRunning $appHealthy $appUnhealthy $appVersion ${appImage:0:60}
    done

    return 0
}
