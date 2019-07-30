#!/bin/bash
#====================================================================
#app             :Ship
#description     :Kubernetes deploy plugin
#author          :protetore
#date            :20160211
#====================================================================

K8S_API_URL=${CONTAINER_MGMT_URL:=""}
K8S_API_USR=${CONTAINER_MGMT_USR:=""}
K8S_API_PWD=${CONTAINER_MGMT_PWD:=""}
K8S_API_AUTH=""

if [ "$K8S_API_USR" != "" ] && [ "$K8S_API_PWD" != "" ]; then
    K8S_API_AUTH="--username=${K8S_API_USR} --password=${K8S_API_PWD}"
fi

K8S_CMD="kubectl --server=${K8S_API_URL} ${K8S_API_AUTH}"

function remoteDeploy()
{
    dtitle "Kubernetes Deploy"
    decho  "Starting Kubernetes deploy..."

    # Check if the deployment exists in K8s cluster
    existing=$($K8S_CMD get rc | grep "${APP_NAME}-controller" | grep -v grep)
    if [ "$existing" == "" ];
    then
        # If don't exists create based on template
        remoteCreate
        updateStatus=$?
    else
        # If exists, only update the image
        # Get previous image tag for rollback
        if [ ! -f $SHIP_TMP_DIR/$APP_NAME/previous_tag ];
        then
            touch $SHIP_TMP_DIR/$APP_NAME/previous_tag
        fi

        previousImage=$(echo $existing | awk '{ print $3 }' | awk -F'/' '{ print $2 }' | awk -F':' '{ print $2 }')
        echo $previousImage > $SHIP_TMP_DIR/$APP_NAME/previous_tag
        decho  "Updating from image tag $previousImage to $APP_VERSION..."

        updateResult=$($K8S_CMD rolling-update ${APP_NAME}-controller --image=$REGISTRY_URL/$APP_NAME:$APP_VERSION)
        updateStatus=$?
    fi

    if [[ $updateStatus -eq 0 ]];
    then
        # Rolling-update Success: Check for pod status
        remoteCheckDeploy
        deployStatus=$?

        if [[ $deployStatus -eq 0 ]];
        then
            # Success
            decho "App $APP_NAME deployed."
            notifySlack "App $APP_NAME deployed with version: $APP_VERSION."
            return 0
        else
            # Something wrong with pod
            # Rolling-update failed
            derror "K8s Deploy Failed. Triggering Rollback..."
            remoteRollback $existing
            return 1
        fi
    else
        # Rolling-update failed: comunication error?
        # We don't know what happened. Always force rollback?
        derror "K8s Deploy Failed. Triggering Rollback..."
        remoteRollback $existing
        return 1
    fi
}

function remoteDestroy()
{
    decho  "Destroying $APP_NAME in production..."

    # Check if the replication controller exists in K8s cluster
    existing=$($K8S_CMD get rc | grep "${APP_NAME}-controller" | grep -v grep)
    if [ "$existing" == "" ];
    then
        dwarn "Replication controller '${APP_NAME}-controller' not found in production. Skipping..."
    else
        decho "Replication controller '${APP_NAME}-controller' found. Destroying..."
        destroyResult=$($K8S_CMD delete rc ${APP_NAME}-controller)
        if [ ! $? -eq 0 ]; then
            derror "There was an error while destroying this app:"
            decho "--- ERROR DETAILS ---"
            decho $destroyResult
            decho
            return 1
        fi
    fi

    # Check if the service exists in K8s cluster
    existing=$($K8S_CMD get svc | grep "${APP_NAME}" | grep -v grep)
    if [ "$existing" == "" ];
    then
        dwarn "Service '${APP_NAME}' not found in production. Skipping..."
    else
        decho "Service '${APP_NAME}' found. Destroying..."
        destroyResult=$($K8S_CMD delete svc ${APP_NAME})
        if [ ! $? -eq 0 ]; then
            derror "There was an error while destroying this app:"
            decho "--- ERROR DETAILS ---"
            decho $destroyResult
            decho
            return 1
        fi
    fi

    notifySlack "$APP_NAME DESTROYED IN PRODUCTION! (from user@hostname: ${SHIP_USERNAME}@${SHIP_HOSTNAME})"
    return 0
}

function remoteCheckDeploy()
{
    pods=$($K8S_CMD get pod | grep "${APP_NAME}-controller" | grep -v grep | awk '{ print $1 }')

    running=0
    podsFound=0
    for podName in ${pods[@]}
    do
        podRC=$($K8S_CMD describe pod $podName | grep "Replication Controllers" | grep -v grep | awk '{ print $3}')

        if [ ! "$podRC" == "${APP_NAME}-controller" ];
        then
            decho "An RC was detected with name: $podRC. Maybe it's a failed deploy, please verify."
            continue
        fi

        podsFound=$((podsFound + 1))

        podStatus=1
        attempt=1
        while [[ ! $podStatus -eq 0 ]];
        do
            remoteCheckStatus $podName
            podStatus=$?

            if [[ $attempt -ge $REMOTE_CHECKS ]];
            then
                break;
            fi

            decho "Container not ready yet. Waiting... [$attempt/$REMOTE_CHECKS]"
            sleep $SLEEP_TIME
            attempt=$(( attempt+1 ))
        done

        if [ ! $podStatus -eq 0 ];
        then
            running=1
        fi
    done

    if [[ $podsFound -eq 0 ]];
    then
        derror "No PODs found for RC ${APP_NAME}-controller."
        running=1
    fi

    return $running
}

function remoteCheckStatus()
{
    podStatus=$($K8S_CMD describe pod $1 | grep "State" | grep -v grep | awk '{ print $2}')
    case $podStatus in
        "Running")
            decho "POD $1 running."
            return 0
            ;;
        "PullImageError")
            decho "PullImageError detected. Waiting for Kubernetes to retry..."
            return 1
            ;;
        "Pending")
            decho "Pending detected. Waiting for a possible delay or unfinished pull..."
            return 2
            ;;
        "ContainerCreating")
            decho "ContainerCreating detected. Waiting for k8s to create the containers..."
            return 3
            ;;
        *)
            return 4
            ;;
    esac
}

function remoteCreate()
{
    dsub "New application detected"

    # 0. Format CPU_LIMIT and MEMORY_LIMIT to kubernetes acdepted format
    CPU_LIMIT_K8S=$(echo $CPU_LIMIT*100 | bc)
    CPU_LIMIT_K8S="${CPU_LIMIT_K8S%.*}m"
    MEMORY_LIMIT_K8S="${MEMORY_LIMIT}Mi"

    # 1. Copy templates and replace variables

    # 1.1. Replication controller
    APP_PORT=${APP_PORT:-0}

    cp $TEMPLATES_DIR/k8s/${APP_TYPE}/rc.json $SHIP_TMP_DIR/$APP_NAME/
    sed -i -e "s#__APP__#$APP_NAME#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__SCOPE__#$APP_SCOPE#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__TYPE__#$APP_TYPE#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__HEALTH__#$APP_HEALTH#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__REGISTRY__#$REGISTRY_URL#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__CONTAINER_PERSISTENT_DIR__#$CONTAINER_PERSISTENT_DIR#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__CONTAINER_SHARED_DIR__#$CONTAINER_SHARED_DIR#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__PERSISTENT_DATA_DIR__#$PERSISTENT_DIR#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__SHARED_DATA_DIR__#$SHARED_DATA_DIR#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__CPU_LIMIT__#$CPU_LIMIT_K8S#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__MEMORY_LIMIT__#$MEMORY_LIMIT_K8S#g" $SHIP_TMP_DIR/$APP_NAME/rc.json
    sed -i -e "s#__VERSION__#$APP_VERSION#g" $SHIP_TMP_DIR/$APP_NAME/rc.json

    # 1.2. Service
    if [ "$APP_EXPOSE" != "" ] && [ $APP_EXPOSE -eq 1 ];
    then
        if [ "$APP_PORT" == "" ];
        then
            decho "Detecting next available port on cluster..."
            APP_PORT=$(remoteDetectPort)
        fi

        decho "Application will be exposed on port: $APP_PORT"

        cp $TEMPLATES_DIR/k8s/${APP_TYPE}/service-external.json $SHIP_TMP_DIR/$APP_NAME/svc.json
        sed -i -e "s#__PORT__#$APP_PORT#g" $SHIP_TMP_DIR/$APP_NAME/svc.json
        sed -i -e "s#__URL__#$APP_URL#g" $SHIP_TMP_DIR/$APP_NAME/svc.json
    else
        cp $TEMPLATES_DIR/k8s/${APP_TYPE}/service-internal.json $SHIP_TMP_DIR/$APP_NAME/svc.json
    fi

    # Common service variables
    sed -i -e "s#__APP__#$APP_NAME#g" $SHIP_TMP_DIR/$APP_NAME/svc.json
    sed -i -e "s#__SCOPE__#$APP_SCOPE#g" $SHIP_TMP_DIR/$APP_NAME/svc.json
    sed -i -e "s#__TYPE__#$APP_TYPE#g" $SHIP_TMP_DIR/$APP_NAME/svc.json

    # 2. Create Service
    decho "Creting k8s service..."
    serviceLog=$($K8S_CMD create -f $SHIP_TMP_DIR/$APP_NAME/svc.json)
    serviceStatus=$?
    serviceCreated=$($K8S_CMD get service $APP_NAME)
    if [ "$serviceCreated" == "" ];
    then
        derror "Error creating k8s service."
        return 1
    fi

    # 3. Create RC
    decho "Creating k8s replication controller..."
    rcLog=$($K8S_CMD create -f $SHIP_TMP_DIR/$APP_NAME/rc.json)
    rcStatus=$?
    rcCreated=$($K8S_CMD get rc "${APP_NAME}-controller")
    if [ "$rcCreated" == "" ];
    then
        derror "Error creating k8s rc."
        return 1
    fi

    return 0
}

function remoteDetectPort()
{
    usedPorts=$($K8S_CMD get service -o json | grep nodePort | grep -v grep | awk '{ print $2 }')

    if [ "$usedPorts" == "" ];
    then
        echo 30001
        return 0
    fi

    biggestPort=30000
    for port in ${usedPorts[@]}
    do
        # Remove possible double quotes from json value
        port=$(echo $port | tr -d '"')

        # Ignore values that aren't numbers
        regex='^[0-9]+$'
        if ! [[ $port =~ $regex ]] ; then
           continue
        fi

        if [[ $port -gt $biggestPort ]];
        then
            biggestPort=$port
        fi
    done

    echo $(( biggestPort + 1 ))
}

function remoteRollback()
{
    dtitle "Rollback Application"
    decho "Triggering rollback..."

    existing=$1

    if [ "$existing" == "" ];
    then
        decho "Deleting k8s service..."
        deleteSVC=$($K8S_CMD delete service "${APP_NAME}")
        decho "Deleting k8s replication controller..."
        deleteRC=$($K8S_CMD delete rc "${APP_NAME}-controller")
        return $?
    else
        if [ -f $SHIP_TMP_DIR/$APP_NAME/previous_tag ];
        then
            PREVIOUS_TAG=$(cat $SHIP_TMP_DIR/$APP_NAME/previous_tag)
        else
            derror "No previous TAG to rollback to."
            return 1
        fi

        APP_VERSION=$PREVIOUS_TAG
        k8sDeploy

        if [ $? -eq 1 ];
        then
            derror "Rollback failed!"
            return 1
        else
            decho "Rollback completed."
            return 0
        fi
    fi
}

function remoteList()
{
    dtitle "K8s Replication Controllers"
    $K8S_CMD get rc
}

function kubePrompt() {
    trap '' INT
    trap '' HUP

    echo "@@ SHIP SHELL: KUBECTL"
    echo
    echo "Usage:"
    echo "   ~> kube-cmds arguments   Any valid kubect command except delete and stop (without 'kubectl')"
    echo "   ~> exit                  Disconnect"
    echo

    while true; do
        read -r -e -d $'\n' -p ":: ship-kubectl ~> " opt
        if [ "$opt" == "exit" ];
        then
            exit 0
        elif [[ "$opt" == "" ]];
        then
            echo "Empty option"
        elif [[ $opt =~ .*del.* ]] || [[ "$opt" == "stop" ]];
        then
            echo "Blocked action"
        else
            history -s "$opt"
            $K8S_CMD $opt
        fi
    done
}
