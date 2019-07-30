#!/bin/bash
#
# Ship Configuring Functions
#
# Decision6 SHIP Deployer
# github.com/decision6/ship.git

function config()
{
    dtitle "Configuring SHIP"
    decho "--------------------------------------------------"

    if [ -f $USER_CONFIG_FILE ]; then
        while true; do
            read -p "Previous ship config detected, do you want to reconfigure? [Y/n] " opt
            case $opt in
                [Yy]* ) break;;
                [Nn]* ) exit 0;;
                * ) echo "Please answer y or n";;
            esac
        done
    fi

    dsub "Detecting docker..."
    docker=$(which docker)
    if [ "$docker" == "" ];
    then
        derror "Docker not found. Please, install it."
        exit 1
    else
        decho "Docker already installed."
    fi

    dsub "Configuring contianer orchestration"
    configContainerMgmt

    dsub "Configuring private registry access..."
    while true; do
        read -p "Do you use a private registry? [Y/n] " opt
        case $opt in
            [Yy]* ) configRegistry; break;;
            [Nn]* ) break;;
            * ) dwarn "Please answer y or n";;
        esac
    done

    dsub "Configuring VCS..."
    configVCS

    # Set the workspace location
    dsub "Configuring your workspace..."
    decho
    decho "* Your workspace is used to:"
    decho "  - Look for WORKSPACE/app-name/ship.json when deploying using 'ship deploy app-name'"
    decho "  - Mount app folder insinde the contianer on local deploys"
    decho
    decho "* If you don't configure your workspace you can continue deploying by:"
    decho "  - Using 'ship deploy' inside a folder containing a ship.json file"
    decho "  - Using ship command line flags: 'ship deploy app-name --type=node'"
    decho
    while true; do
        read -p "Do uoy want to configure your workspace? [Y/n] " opt
        case $opt in
            [Yy]* ) configWorkspace; break;;
            [Nn]* ) break;;
            * ) dwarn "Please answer y or n";;
        esac
    done

    # Configure slack hook settings
    dsub "Configuring Slack notification..."

    while true; do
        read -p "Do you want to alert a slack channel on successfull deployments? [Y/n] " opt
        case $opt in
            [Yy]* ) configSlack; break;;
            [Nn]* ) break;;
            * ) dwarn "Please answer y or n";;
        esac
    done

    dsub "Saving settings..."
    saveConfig

    dsub "Adding ship to path..."
    if [ -f "/usr/local/bin/ship" ]; then
        rm -f /usr/local/bin/ship
    fi

    chmod +x $BASEDIR/ship
    ln -s $BASEDIR/ship /usr/local/bin/ship

    decho "--------------------------------------------------"

    dsuccess "~~~ Ship Ready to Sail! ~~~"
}

# Save config file to user home dir (allowing multi-user install)
function saveConfig()
{
    configDir=$(dirname ${USER_CONFIG_FILE})
    if [ ! -d ${configDir} ]; then
        \mkdir -p $configDir
    fi

    if [ ! -f $USER_CONFIG_FILE ]; then
        touch $USER_CONFIG_FILE
    fi

    config="{
      \"ship\": {
        \"user_workspace\": \"$USER_WORKSPACE\",
        \"repository\": {
          \"repo_default_url\": \"$APP_REPO_BASE_URL\",
          \"repo_default_branch\": \"$APP_BRANCH\"
        },
        \"notify\": {
          \"slack\": {
            \"channel\": \"$SLACK_CHANNEL\",
            \"hook\": \"$SLACK_HOOK\"
          }
        }
      },
      \"container_management\": {
        \"type\": \"$CONTAINER_MGMT\",
        \"api_url\": \"$CONTAINER_MGMT_URL\",
        \"api_username\": \"$CONTAINER_MGMT_USR\",
        \"api_password\": \"$CONTAINER_MGMT_PWD\"
      },
      \"registry\": {
        \"url\": \"$REGISTRY_URL\",
        \"username\": \"$REGISTRY_USR\",
        \"password\": \"$REGISTRY_PWD\"
      },
      \"cluster\": {
        \"persistent_data_dir\": \"/opt/d6/data\",
        \"shared_data_dir\": \"/opt/d6/data/shared\",
        \"container_persistent_dir\": \"/data\",
        \"container_shared_dir\": \"/shared\"
      }
    }";

    echo "$config" > $USER_CONFIG_FILE
}

function configKubernetes()
{
    decho "Detecting kubectl..."
    kubectl=$(which kubectl)
    if [ "$kubectl" == "" ];
    then
        decho "Kubectl not found. Installing..."
        release=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)

        if [ "$OS" == "$MAC" ];
        then
            curl -LO \
                "https://storage.googleapis.com/kubernetes-release/release/${release}/bin/darwin/amd64/kubectl"
        else
            curl -LO https://storage.googleapis.com/kubernetes-release/release/${release}/bin/linux/amd64/kubectl
        fi

        if [ ! -f ./kubectl ];
        then
            derror "Error downloading kubectl. Please, try again."
            exit 1
        fi

        chmod +x kubectl
        mv kubectl /usr/local/bin/
    else
        decho "Kubectl already installed."
    fi

    decho "Configuring kubectl..."
    kubectl config set-cluster ship-cluster --server=${CONTAINER_MGMT_URL}
    return $?
}

function configRegistry()
{
    while true; do
        read -p "Which is your private registry URL?  " opt
        opt=$(echo $opt | tr '[:upper:]' '[:lower:]')
        if [ "$opt" != "" ]; then
            opt=$(echo $opt | sed 's/https\?:\/\///')
            REGISTRY_URL=$opt;
            break;
        fi
    done

    while true; do
        read -p "Which is your private registry username?  " opt
        if [ "$opt" != "" ]; then
            REGISTRY_USR=$opt;
            break;
        fi
    done

    while true; do
        read -p "Which is your private registry password?  " opt
        if [ "$opt" != "" ]; then
            REGISTRY_PWD=$opt;
            break;
        fi
    done

    docker login $REGISTRY_URL -u $REGISTRY_USR -p $REGISTRY_PWD
    if [ ! $? -eq 0 ]; then
        derror "Error authenticating with private registry, try again."
        exit 1
    fi
}

function configSlack()
{
    while true; do
        read -p "Type your Slack hook: " opt
        if [ "$opt" != "" ]; then
            SLACK_HOOK="$opt";
            break;
        else
            echo "Slack hook can not be empty."
        fi
    done

    while true; do
        read -p "Type your Slack channel: " opt
        if [ "$opt" != "" ]; then
            SLACK_CHANNEL="$opt";
            break;
        else
            echo "Slack channel can not be empty."
        fi
    done
}

function configVCS()
{
    while true; do
        read -p "Type your VCS URL (Ex.: git@github.com:yourcompany): " opt
        if [ "$opt" != "" ]; then
            APP_REPO_BASE_URL="$opt";
            break;
        else
            echo "VCS URL can not be empty."
        fi
    done

    while true; do
        read -p "Type your VCS production deployment branch (Ex: master): " opt
        if [ "$opt" != "" ]; then
            APP_BRANCH="$opt";
            break;
        else
            echo "VCS branch can not be empty."
        fi
    done
}

function configWorkspace()
{
    if [ "$SHIP_WORKSPACE" != "" ];
    then
        decho "Workspace detected in env var SHIP_WORKSPACE"
        USER_WORKSPACE=$SHIP_WORKSPACE
    elif [ "$SHIP_USER_WORKSPACE" != "" ];
    then
        decho "Workspace detected in env var SHIP_USER_WORKSPACE"
        USER_WORKSPACE=$SHIP_USER_WORKSPACE
    elif [ "$WORKSPACE" != "" ];
    then
        decho "Workspace detected in env var WORKSPACE"
        USER_WORKSPACE=$WORKSPACE
    fi

    if [ "$USER_WORKSPACE" != "" ];
    then
        decho "Workspace detected: $USER_WORKSPACE"
        while true; do
            read -p "Do you want to use it? [Y/n] " opt
            case $opt in
                [Yy]* ) break;;
                [Nn]* ) USER_WORKSPACE=""; break;;
                * ) dwarn "Please answer y or n";;
            esac
        done
    fi

    if [ "$USER_WORKSPACE" == "" ]; then
        while true; do
            read -p "Type your workspace path: " opt
            if [ "$opt" != "" ]; then
                USER_WORKSPACE=$opt;
                break;
            else
                dwarn "Workspace can not be empty."
            fi
        done
    fi

    if [ ! -d $USER_WORKSPACE ];
    then
        derror "Dir $USER_WORKSPACE not found!"
        exit 1
    fi

    return 0
}

function configContainerMgmt()
{
    while true; do
        read -p "Which is your container orchestrator? [1-Marathon, 2-Kubernetes] " opt
        case $opt in
            1) CONTAINER_MGMT=marathon; break;;
            2) CONTAINER_MGMT=kubernetes; break;;
            * ) dwarn "Please answer 1 or 2";;
        esac
    done

    while true; do
        decho "Container orchestration API url. Examples:"
        dstep "http://dcos.yourdomain.com/service/marathon/"
        dstep "http://dcos.yourdomain.com/service/kubernetes/api"
        read -p "Type your $CONTAINER_MGMT API address: " opt
        if [ "$opt" != "" ] && [ "${opt:0:4}" == "http" ]; then
            CONTAINER_MGMT_URL=$opt;
            break;
        else
            dwarn "Type the api URL begining with 'http' or 'https'."
        fi
    done

    while true; do
        read -p "Your $CONTAINER_MGMT API requires authentication? [Y/n]" opt
        opt=$(echo $opt | tr '[:upper:]' '[:lower:]')
        if [ "$opt" == "y" ] || [ "$opt" == "yes" ]; then
            while true; do
                read -p "Which is your $CONTAINER_MGMT API username?  " opt
                if [ "$opt" != "" ]; then
                    CONTAINER_MGMT_USR=$opt;
                    break;
                fi
            done

            while true; do
                read -p "Which is your $CONTAINER_MGMT API password?  " opt
                if [ "$opt" != "" ]; then
                    CONTAINER_MGMT_PWD=$opt;
                    break;
                fi
            done

            break;
        elif [ "$opt" == "n" ] || [ "$opt" == "no" ]; then
            break;
        else
            dwarn "Type yes or no."
        fi
    done

    if [ "$CONTAINER_MGMT" == "kubernetes" ]; then
        dsub "Configuring kubernetes"
        configKubernetes
    fi
}
