#!/bin/bash
#====================================================================
#app             :Ship
#description     :Ship docker plugin
#author          :protetore
#date            :20160211
#====================================================================

function isRegistryAccessible()
{
    if [ "$REGISTRY_URL" != "" ]; then
        # Private registry
        decho "Checking private registry access..."
        if [ "$REGISTRY_USR" != "" ]; then
            docker login $REGISTRY_URL -u $REGISTRY_USR -p $REGISTRY_PWD > /dev/null 2>&1
            if [ ! $? -eq 0 ]; then
                return 1
            fi
        else
            status=$(curl -s -o /dev/null -w "%{http_code}" -k https://$REGISTRY_URL/v2/)
            if [ "$status" != "200" ]; then
                return 1
            fi
        fi
    else
        # Docker hub?
        decho "No private registry configured. Checking docker hub access..."
        status=$(curl -s -o /dev/null -w "%{http_code}" -k https://hub.docker.com/v2/repositories/_catalog/)
        if [ "$status" != "200" ]; then
            return 1
        fi
    fi

    return 0
}

function localDeploy()
{
    dtitle "LOCAL Deploy"
    decho "LOCAL deployment for app $APP_NAME..."
    createdContainers=""

    if ! isRegistryAccessible; then
        derror "Registry not accessible! Check your credentials and your connectivity."
        return 1
    fi

    # Create a subnet
    decho "Checking Ship docker network..."
    exists=$(docker network ls | grep $SHIP_NET | grep -v grep)
    if [ "$exists" == "" ];
    then
        dstep "Creating Ship docker network..."
        message=$(docker network create --subnet=$SHIP_NET_ADDR/$SHIP_NET_MASK $SHIP_NET)
        if [ ! $? -eq 0 ];
        then
            derror $message
            return 1
        fi
    else
        dstep  "Ship network already exists."
    fi

    # Create volumes container
    decho "Checking volumes container..."
    exists=$(docker ps -a --format="{{.Names}}" | grep $SHIP_VOL_CONTAINER)
    if [ "$exists" == "" ];
    then
        dstep "Creating Ship volumes container..."
        message=$(docker create \
            --name=$SHIP_VOL_CONTAINER \
            --net=$SHIP_NET \
            --restart=always \
            --hostname=$SHIP_VOL_CONTAINER \
            --label "ship" \
            --label "ship-dependency" \
            --dns-search=$SHIP_NET \
            -e "DNSMASQ_ENABLE_SEARCH=true" \
            -e "DNSMASQ_SEARCH_DOMAINS=$SHIP_NET" \
            -v /data \
            -v /shared \
            -v /root/.cache \
            -v /root/.npm \
            -v /root/.composer \
            -v /root/.sbt \
            alpine:3.6 \
            /bin/true)

        if [ ! $? -eq 0 ];
        then
            derror $message
            return 1
        fi
    else
        dstep  "Ship volumes container already exists."
    fi

    # Global dependencies
    count=$(echo $DEPENDENCIES | $JQ -c '. | length' | sed 's/null/0/g')
    for ((i=0;i<$count;i++))
    do
        depName=$(echo $DEPENDENCIES | $JQ '.['${i}'].name' | tr -d '"')
        exists=$(docker ps --format="{{.Names}}" | grep $depName)
        decho "Processing global dependency: $depName."

        if [ "$exists" != "" ];
        then
            dstep  "Dependency $depName container already exists."
            continue
        fi

        portsLen=$(echo $DEPENDENCIES | $JQ -c '.['${i}'].ports | length' | sed 's/null/0/g')
        volumesLen=$(echo $DEPENDENCIES | $JQ -c '.['${i}'].volumes | length' | sed 's/null/0/g')
        depImage=$(echo $DEPENDENCIES | $JQ '.['${i}'].image' | tr -d '"')

        ports=""
        depUsedPort=""
        for ((j=0;j<$portsLen;j++))
        do
            port=$(echo $DEPENDENCIES | $JQ -c '.['${i}'].ports['${j}']' | tr -d '"')
            ports="$ports -p $port"

            localPort=${port%%:*}
            if [ ${#depUsedPort} -gt 0 ]; then
                depUsedPort="$depUsedPort,$localPort"
            else
                depUsedPort=$localPort
            fi
        done

        volumes=""
        for ((k=0;k<$volumesLen;k++))
        do
            volume=$(echo $DEPENDENCIES | $JQ -c '.['${i}'].volumes['${k}']' | tr -d '"')
            volumes="$volumes -v $volume"
        done

        dstep  "Pulling most recent image: $depImage..."
        message=$(docker pull $depImage)

        dstep  "Creating container for global dependency: $depName..."
        message=$(docker run -it -d \
            --name=$depName \
            --net=$SHIP_NET \
            --restart=always \
            --hostname=$depName \
            --label "ship" \
            --label "ship-dependency" \
            --dns-search=$SHIP_NET \
            -e "DNSMASQ_ENABLE_SEARCH=true" \
            -e "DNSMASQ_SEARCH_DOMAINS=$SHIP_NET" \
            --volumes-from $SHIP_VOL_CONTAINER \
            -v $CONTAINER_PERSISTENT_DIR \
            -v $CONTAINER_SHARED_DIR \
            -v $REAL_USER_WORKSPACE:/workspace \
            $ports \
            $volumes \
            $depImage)

        if [ ! $? -eq 0 ];
        then
            derror "Could not create container for global dependency: $depName."
            derror $message
            return 1
        fi


        dstep  "Dependency '$depName' available at: http://localhost:$depUsedPort"
        createdContainers="$createdContainers|$depName:$depUsedPort"
        sleep 5
    done

    # App Dependencies
    if [ "$APP_CONFIG" != "" ];
    then
        appConfig=$(cat $APP_CONFIG)
        depCount=$(echo $appConfig | $JQ '.dependencies | length' | sed 's/null/0/g')

        for ((i=0;i<$depCount;i++))
        do
            depConfig=$(echo $appConfig | $JQ -c '.dependencies['${i}']')
            depName=$(echo $depConfig | $JQ '.name' | tr -d '"')
            exists=$(docker ps --format="{{.Names}}" | grep $depName)
            decho "Processing dependency: $depName."

            if [ "$exists" != "" ];
            then
                dstep  "Dependency $depName container already exists."
                continue
            fi

            APP_MOUNT=""
            if [ -d $USER_WORKSPACE/$depName ];
            then
                dstep  "Dependency $depName source dir found in workspace, mounting in /app."
                # Grantee that we will use the path of the user machine not the container
                APP_MOUNT="-v $REAL_USER_WORKSPACE/$depName:/app"
            fi

            # Look for this dependency config file on workspace
            if [ -f $USER_WORKSPACE/$depName/$APP_CONFIG_FILE ];
            then
                # Load dependency configuration
                dstep  "Dependency config found in: $USER_WORKSPACE/$depName/$APP_CONFIG_FILE"
                depConfig=$(cat $USER_WORKSPACE/$depName/$APP_CONFIG_FILE | $JQ '.ship')
            else
                dstep  "Dependency config NOT found in $USER_WORKSPACE/$depName"
            fi

            portsLen=$(echo $depConfig | $JQ -c '.ports | length' | sed 's/null/0/g')
            volumesLen=$(echo $depConfig | $JQ -c '.volumes | length' | sed 's/null/0/g')
            depImage=$(echo $depConfig | $JQ '.image' | tr -d '"')
            depType=$(echo $depConfig | $JQ '.type' | tr -d '"')

            ports=""
            depUsedPort=""
            for ((j=0;j<$portsLen;j++))
            do
                port=$(echo $depConfig | $JQ -c '.ports['${j}']' | tr -d '"')
                ports="$ports -p $port"

                localPort=${port%%:*}
                if [ ${#depUsedPort} -gt 0 ]; then
                    depUsedPort="$depUsedPort,$localPort"
                else
                    depUsedPort=$localPort
                fi
            done

            volumes=""
            for ((k=0;k<$volumesLen;k++))
            do
                volume=$(echo $depConfig | $JQ -c '.volumes['${k}']' | tr -d '"')
                volumes="$volumes -v $volume"
            done

            if [ "$depType" != "" -a "$depType" != "null" ];
            then
                # If the type was defined and an image was not, look for a
                # dev template image in the ship configuration for this type
                if [ "$depImage" == "" -o "$depImage" == "null" ];
                then
                    # Look for template image
                    template=$(echo $TEMPLATES | $JQ ".$depType" | tr -d '"')
                    if [ "$template" == "" -o "$template" == "null" ];
                    then
                        derror "Template image not defined for type: $depType"
                        return 1
                    fi
                    dstep  "Using dev image for dependency $depName type $depType..."
                    depImage=$template
                fi
            fi

            if [ "$depImage" == "" -o "$depImage" == "null" ];
            then
                # Using image defined on app dependecy
                dstep  "Using production image for dependency: $depName..."
                depImage=$REGISTRY_URL/$depName
            fi

            dstep  "Pulling most recent image: $depImage..."
            message=$(docker pull $depImage)

            dstep  "Creating container for app dependency: $depName..."
            message=$(docker run -it -d \
                --name=$depName \
                --net=$SHIP_NET \
                --restart=always \
                --hostname=$depName \
                --label "ship" \
                --label "ship-user-container" \
                --dns-search=$SHIP_NET \
                -e "DNSMASQ_ENABLE_SEARCH=true" \
                -e "DNSMASQ_SEARCH_DOMAINS=$SHIP_NET" \
                --volumes-from $SHIP_VOL_CONTAINER \
                -v $CONTAINER_PERSISTENT_DIR \
                -v $CONTAINER_SHARED_DIR \
                -v $REAL_USER_WORKSPACE:/workspace \
                $APP_MOUNT \
                $ports \
                $volumes \
                $depImage)

            if [ ! $? -eq 0 ];
            then
                derror "Could not create container for app dependency: $depName."
                derror $message
                return 1
            fi

            dstep  "Dependency '$depName' available at: http://localhost:$depUsedPort"
            createdContainers="$createdContainers|$depName:$depUsedPort"
            sleep 5
        done
    fi

    decho "Creating main container for app: $APP_NAME..."

    # Create app container from template image
    template=$(echo $TEMPLATES | $JQ ".$APP_TYPE" | tr -d '"')
    if [ "$template" == "" -o "$template" == "null" ];
    then
        derror "Template image not defined for type: $APP_TYPE"
        return 1
    fi

    exists=$(docker ps --format="{{.Names}}" | grep $APP_NAME)

    if [ "$exists" != "" ];
    then
        dstep  "Container for $APP_NAME already exists."
        read -p "Do you want to remove and recreate it? [y/n] " yn
        case $yn in
            [Yy]* ) removeContainer $APP_NAME;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n."; return 1;;
        esac
    fi

    portsLen=0
    if [ "$APP_CONFIG" != "" ];
    then
        appConfig=$(cat $APP_CONFIG)
        portsLen=$(echo $appConfig | $JQ -c '.ship.ports | length' | sed 's/null/0/g')
    fi

    if [ $portsLen -gt 0 ];
    then
        dstep  "Reading ports from app config file (ship.json)"
        ports=""
        usedPort=""
        for ((j=0;j<$portsLen;j++))
        do
            port=$(echo $appConfig | $JQ -c '.ship.ports['${j}']' | tr -d '"')
            ports="$ports -p $port"
            localPort=${port%%:*}
            if [ ${#usedPort} -gt 0 ]; then
                usedPort="$usedPort,$localPort"
            else
                usedPort=$localPort
            fi
        done
    elif [ "$APP_PORT" == "" ];
    then
        availPort=$(getAvailablePort)
        dstep  "No port to expose (-p). Using random port: $availPort"
        ports="-p $availPort:80"
        usedPort=$availPort
    else
        ports="-p $APP_PORT"
        usedPort=${APP_PORT%%:*}
    fi

    if [[ "$REAL_USER_WORKSPACE" != "" && $LOCAL_PRODUCTION -eq 0 ]];
    then
        devVolume="-v ${REAL_USER_WORKSPACE}/$APP_NAME:/app"
        appImage=$template
        dstep  "Using Dev Image: $template"
    else
        if [ "$APP_VERSION" == "" ];
        then
            APP_VERSION="latest"
            dstep  "Using Production Image: $REGISTRY_URL/$APP_NAME:$APP_VERSION"
        fi
        appImage=$REGISTRY_URL/$APP_NAME:$APP_VERSION
        devVolume=""
    fi

    # Add custom env vars from application ship.json
    APP_ENV_VARS=""
    if [ ! -z "$APP_ENV" ]; then
        count=$(echo $APP_ENV | $JQ '. | length' | sed 's/null/0/g')
        for ((i=0;i<$count;i)); do
            envName=$(echo $APP_ENV | $JQ '.['${i}'].name' | tr -d '"')
            envValue=$(echo $APP_ENV | $JQ '.['${i}'].value' | tr -d '"')
            APP_ENV_VARS="${APP_ENV_VARS} -e ${envName}=${envValue}"
        done
    fi

    # Resource limits
    APP_CPU_LIMIT=""
    if [[ ! -z "$CPU_LIMIT" ]]; then
        APP_CPU_LIMIT="--cpus=${CPU_LIMIT}"
    fi

    APP_MEMORY_LIMIT=""
    if [[ ! -z "$MEMORY_LIMIT" ]]; then
        APP_MEMORY_LIMIT="--memory=${MEMORY_LIMIT}m"
        APP_ENV_VARS="${APP_ENV_VARS} -e MAX_MEMORY=${MEMORY_LIMIT}"
    fi


    dstep  "Pulling most recent image: $appImage..."
    message=$(docker pull $appImage)

    dstep  "Creating container for app: $APP_NAME..."
    message=$(docker run -it -d \
        --name=$APP_NAME \
        --net=$SHIP_NET \
        --restart=always \
        --dns-search=$SHIP_NET \
        --hostname=$APP_NAME \
        --label "ship" \
        --label "ship-user-container" \
        -e "DNSMASQ_ENABLE_SEARCH=true" \
        -e "DNSMASQ_SEARCH_DOMAINS=$SHIP_NET" \
        -e "APP_NAME=$APP_NAME" \
        -e "APP_BRANCH=$APP_BRANCH" \
        -e "APP_REPO=$APP_REPO" \
        -e "NODE_ENV=development" \
        -e "APP_ENV=development" \
        ${APP_ENV_VARS} \
        --volumes-from $SHIP_VOL_CONTAINER \
        -v $CONTAINER_PERSISTENT_DIR \
        -v $CONTAINER_SHARED_DIR \
        -v $REAL_USER_WORKSPACE:/workspace \
        ${APP_MEMORY_LIMIT} \
        ${APP_CPU_LIMIT} \
        $ports \
        $devVolume \
        $appImage)

    if [ ! $? -eq 0 ];
    then
        derror "Could not create local container for $APP_NAME."
        derror $message
        return 1
    fi

    dstep  "APP '$APP_NAME' available at: http://localhost:$usedPort"
    decho "--------------------------------"
    decho "Locally deployed app ${WHITE}$APP_NAME${NC}"
    decho "Local Container Name: ${WHITE}$APP_NAME${NC}"
    decho "Locally available at: ${WHITE}http://localhost:${usedPort}${NC}"
    decho "Important: Applications running in containers communicate using app name (http://app-name/)"
    decho "--------------------------------"

    if [ ${#createdContainers} -gt 0 ]; then
        decho "Dependencies created:"

        createdDeps=(${createdContainers//|/ })
        for cDep in ${createdDeps[@]};
        do
            cDepParts=(${cDep//:/ })
            cDepName=${cDepParts[0]}
            cDepPorts=${cDepParts[1]}
            decho "- $cDepName ${UNDERLINE}http://localhost:$cDepPorts${NC}"
        done
    fi

    return 0
}

function localDestroy()
{
    dtitle "Destroy Local Containers"

    if [ "$APP_NAME" == "" -o "$APP_NAME" == "all" ];
    then
        decho "Destroying local containers..."
        decho "- Destroying local user initiated containers..."
        containers=$(docker ps --filter "label=ship-user-container" -a -q)
        if [ "$containers" != "" ];
        then
            message=$(docker rm -f $containers)
            if [ ! $? -eq 0 ];
            then
                derror $message
                return 1
            fi
        fi

        decho "- Destroying dependency containers..."
        containers=$(docker ps --filter "label=ship-dependency" -a -q)
        if [ "$containers" != "" ];
        then
            message=$(docker rm -v -f $containers)
            if [ ! $? -eq 0 ];
            then
                derror $message
                return 1
            fi
        fi

        decho "- Destroying ship network..."
        exists=$(docker network ls | grep $SHIP_NET | grep -v grep)
        if [ "$exists" != "" ];
        then
            message=$(docker network rm $SHIP_NET)
            if [ ! $? -eq 0 ];
            then
                derror $message
                return 1
            fi
        fi
    else
        decho "Destroying local container for app: $APP_NAME..."
        exists=$(docker ps -a --filter "label=ship-user-container" --filter "name=$APP_NAME" --format="{{.Names}}")
        if [ "$exists" == "" ];
        then
            derror "Container $APP_NAME doesn't exist."
            return 1
        fi

        message=$(docker rm -v -f $APP_NAME)
        stat=$?

        if [ ! $stat -eq 0 ];
        then
            derror $message
            return 1
        fi
    fi

    decho "Container destroyed!"
    return 0
}

function localShell()
{
    if [ "$APP_NAME" == "" ]; then
        dtitle  "User Workspace Shell"
        bash --rcfile <(echo "cd $USER_WORKSPACE")
    else
        dtitle "Ship: App container shell"
        decho "Connecting to app $APP_NAME container..."
        exists=$(docker ps -a --filter "label=ship" --filter "name=$APP_NAME" --format="{{.Names}}")
        if [ "$exists" == "" ];
        then
            derror "Container $APP_NAME doesn't exist."
            return 1
        fi

        docker exec -it $APP_NAME sh
        return
    fi
}

function localList()
{
    dtitle "List Local Containers"
    decho

    dsub  "User Containers (Created with Ship):"
    decho
    docker ps --filter "label=ship-user-container" --format="table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    decho
    dsub  "Dependency Containers:"
    decho
    docker ps --filter "label=ship-dependency" --format="table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    return 0
}

function localRestart()
{
    if [ "$APP_NAME" == "" ]; then
        if [ $ALL_CONTAINERS -eq 1 ]; then
            dtitle "All Ship Containers Restart"
            decho "Restarting ALL Ship containers..."
            docker restart $(docker ps --filter "label=ship" -q)
        else
            dtitle "Ship User Containers Restart"
            decho "Restarting Ship USER containers..."
            docker restart $(docker ps --filter "ship-user-container" -q)
        fi
    else
        dtitle "Ship: Restart Local Containers"
        decho "Restarting Container: $APP_NAME"
        docker restart $APP_NAME
    fi
}

function localLogs()
{
    dtitle "Local Container Logs"
    decho "Logs for Container: $APP_NAME"
    docker logs -f $APP_NAME
}

function removeContainer()
{
    container=$1

    if [ "$container" == "" ];
    then
        derror "Please, inform the container name to remove."
        return 1
    fi

    docker rm -f $container > /dev/null
    return $?
}

function getAvailablePort()
{
    usedPorts=$(\
        docker ps --filter "label=ship-user-container" --format "{{.Ports}}" | \
        tr ',' '\n' | \
        sed 's/\/tcp//g' | \
        sed 's/\/udp//g' | \
        awk -F'->' '{print $1}' | \
        awk -F":" '{ print $2 }'
    )

    m=3000
    for p in ${usedPorts[@]}
    do
        if [ $p -gt $m ];
        then
            m=$p
        fi
    done

    m=$((m+1))

    echo $m
}

function imageTagExists()
{
    status=$(curl -s -o /dev/null -w "%{http_code}" -k $REGISTRY_AUTH https://$REGISTRY_URL/v2/$APP_NAME/manifests/$APP_VERSION)
    if [ "$status" == "200" ]; then
        return 0
    else
        return 1
    fi
}

function getNextTag()
{
    latestTag=0
    tags=$(curl -s -k $REGISTRY_AUTH https://$REGISTRY_URL/v2/$APP_NAME/tags/list)

    if echo "$tags" | $JQ -e 'has("tags")' > /dev/null; then
        tagsArr=( $(echo $tags | $JQ '.tags[]') )

        for tag in ${tagsArr[@]}
        do
            # Remove double quotes from json value
            tag=$(echo $tag | tr -d '"')

            # Ignore tags that aren't numbers
            regex='^[0-9]+$'
            if ! [[ $tag =~ $regex ]] ; then
               continue
            fi

            if [[ $tag -gt $latestTag ]];
            then
                latestTag=$tag
            fi
        done
    fi

    echo $(( latestTag + 1 ))
}

function dockerPush()
{
    dsub "Docker Image Push"
    if ! isRegistryAccessible; then
        derror "Registry not accessible! Check your credentials and your connectivity."
        return 1
    fi

    decho "Pushing image to registry: $REGISTRY_URL/$APP_NAME..."
    pushResult=$(docker push $REGISTRY_URL/$APP_NAME > $SHIP_TMP_DIR/$APP_NAME/push.log 2>&1)
    pushStatus=$?

    if [ ! $pushStatus -eq 0 ];
    then
        derror "There was a problem pushing the docker image for app $APP_NAME"
        decho "Trying again..."
        sleep 5
        pushResult=$(docker push $REGISTRY_URL/$APP_NAME > $SHIP_TMP_DIR/$APP_NAME/push.log 2>&1)
        pushStatus=$?

        if [ ! $pushStatus -eq 0 ];
        then
            derror "There was a problem pushing the docker image for app $APP_NAME"
            derror "Full log file in $SHIP_TMP_DIR/$APP_NAME/push.log"
            tail -n 10 $SHIP_TMP_DIR/$APP_NAME/build.log
            return 1
        fi
    fi

    decho "Docker image pushed successfully"
    return 0
}

function dockerBuild()
{
    dsub "Docker Image Build"
    # Check for app template
    if [ "$APP_TYPE" == "" ];
    then
        derror "You must specify the template type using the --type option"
        return 1
    fi

    if [ ! -f $TEMPLATES_DIR/docker/$APP_TYPE/Dockerfile ];
    then
        derror "Template $TEMPLATES_DIR/docker/$APP_TYPE/Dockerfile no found"
        return 1
    fi

    if ! isRegistryAccessible; then
        derror "Registry not accessible! Check your credentials, registry URL and your connectivity"
        return 1
    fi

    # Needs to get latest tag?
    if [ "$APP_VERSION" == "" ];
    then
        APP_VERSION=$(getNextTag)
    fi

    # Copy the template
    cp $TEMPLATES_DIR/docker/$APP_TYPE/Dockerfile $SHIP_TMP_DIR/$APP_NAME/
    cd $SHIP_TMP_DIR/$APP_NAME/ || return 1

    # Pull most recent base image
    decho "Checking base image update (FROM)..."
    docker pull $(awk '/^FROM[ \t\r\n\v\f]/ { print /:/ ? $2 : $2":latest" }' Dockerfile) > /dev/null 2>&1

    # Substitute the variables
    decho "Preparing template..."
    sed -i -e "s#__APP__#$APP_NAME#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__APP_VERSION__#$APP_VERSION#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__APP_BRANCH__#$APP_BRANCH#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__APP_REPO__#$APP_REPO#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__MAIN_SCRIPT__#$APP_MAIN_SCRIPT#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__MAX_MEMORY__#$MEMORY_LIMIT#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
    sed -i -e "s#__MAX_CPU__#$CPU_LIMIT#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile

    # Replace app config defined variables
    # Replacements defined in app ship.json takes precedence over global
    # replacements defined in .ship/config.json and SHIP_DIR/config.json
    decho "Processing app (ship.json) template variable replacements..."
    if [ "$APP_REPLACEMENTS" != "" ]; then
        count=$(echo $APP_REPLACEMENTS | $JQ -c ". | length" | sed 's/null/0/g')
        if [ $count -gt 0 ]; then
            keys=$(echo "$APP_REPLACEMENTS" | $JQ '. | keys[]')
            for key in $keys; do
                key=$(echo $key | tr -d '"')
                value=$(echo $APP_REPLACEMENTS | $JQ ".${key}" | tr -d '"' )
                sed -i -e "s#$key#$value#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
            done
        fi
    fi

    # Replace user defined variables by template type
    decho "Processing global variable replacements for this template type..."
    if echo "$GLOBAL_REPLACEMENTS" | $JQ -e "has(\"$APP_TYPE\")" > /dev/null; then
        count=$(echo $GLOBAL_REPLACEMENTS | $JQ -c ".${APP_TYPE} | length" | sed 's/null/0/g')
        if [ $count -gt 0 ]; then
            replacements=$(echo $GLOBAL_REPLACEMENTS | $JQ ".${APP_TYPE}")
            keys=$(echo "$replacements" | $JQ '. | keys[]')
            for key in $keys; do
                key=$(echo $key | tr -d '"')
                value=$(echo $replacements | $JQ ".${key}" | tr -d '"' )
                sed -i -e "s#$key#$value#g" $SHIP_TMP_DIR/$APP_NAME/Dockerfile
            done
        fi
    fi

    # Remove preivous images of this application
    dockerRemoveImages

    # Build the new image
    decho "Building docker image..."
    buildResult=$(docker build -t $REGISTRY_URL/$APP_NAME:$APP_VERSION -t $REGISTRY_URL/$APP_NAME:latest . > $SHIP_TMP_DIR/$APP_NAME/build.log 2>&1)
    buildStatus=$?

    if [ ! $buildStatus -eq 0 ];
    then
        derror "There was a problem building the docker image for app $APP_NAME"
        derror "FULL LOG:"
        cat $SHIP_TMP_DIR/$APP_NAME/build.log
        return 1
    fi

    decho "Docker build successful"
    decho "Image tags: "
    decho "  - $REGISTRY_URL/$APP_NAME:$APP_VERSION"
    decho "  - $REGISTRY_URL/$APP_NAME:latest"
    return 0
}

function dockerRemoveImages()
{
    decho "Removing previous images..."
    previousImages=$(docker images | grep "$REGISTRY_URL/$APP_NAME" | awk '{ print $3 }')

    if [ ! "$previousImages" == "" ];
    then
        previousImages=$(echo $previousImages | tr '\n' ' ')
        previousImages=${previousImages%?}
        status=$(docker rmi -f $previousImages > /dev/null 2>&1)
    fi
}
