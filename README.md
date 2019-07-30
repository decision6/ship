# SHIP

SHIP is a lightweight, shell script only, command line tool to manage application deployments on a kubernetes/marathon cluster using the power of user computer to do the builds. It was created with small startups limited on budget that can not afford paying for a CI service or havin one or their cluster.

On default Ship configuration, each assumes each app have an unique name that will represent:

1. Folder name in user workspace (only for local deploys and deploys using ship.json file - see below);
2. Git repository name. Ex.: bitbucket.org/company/**app-name**.git;
3. Docker image name: Ex.: registry.company.com:5000/**app-name**:latest;
4. Kubernetes controller and service names or Marathon app name:

  - Marathon App: **app-name**
  - K8s Service: **app-name**
  - K8s RC: **app-name**-controller

So, when you do a deploy like **ship deploy app-name -t node**, ship will use the docker template found in $SHIP_TEMPLATES/node for node apps, replace some environment variables on the template, trigger a docker build, push the image to the registry, trigger de deployment on kubernetes/marathon and watch if it was successful, otherwise it will do a rollback.

Ship assumes that the _Dockerfile_ template will do all the procedures needed by the application, like the checkout of the application inside the container and run yarn install and whatever is needed by you aplication, you are in control of the build.

All the procedures are made in the user machine, it was designed with small companies/startups in mind, when you can't afford having servers for a CI tool, or does not have the budget to pay for a commercial solution.

But nothing stops you from running ship on your Jenkins/CI server. :)

## Local Deployments

SHIP also supports local deployments to simulate production environment on developer machine. When creating a container locally, SHIP will mount the user $WORKSPACE/APP-NAME folder on the container LOCAL_DEPLOY_APP_DIR directory so you can continue the development and run the application inside the container. It will also mount your entire workspace inside /workspace so you can link projects while in development.

There are drawbacks in this method. Although you have a environment much closer to the production environment and can prevent many build problems, you have to be aware of a few things:

1. App Compiled Dependencies:

Although you can develop in your machine and do all the programming as you normally do, when installing compiled dependencies (like some nodejs dependencies and golang packages), the dependencies must be compiled inside the container, you can't execute yarn/npm install on your machine: you must use 'ship :shell app-name' and execute inside the container.

## Local Mounts

### Workspace Mount

- Your workspace is used to:

  - Look for WORKSPACE/app-name/ship.json when deploying using 'ship deploy app-name'
  - Mount app folder insinde the contianer on local deploys

- If you don't configure your workspace you can continue deploying by:

  - Using 'ship deploy' inside a folder containing a ship.json file
  - Using ship command line flags: 'ship deploy app-name -t node'

### Persistent Storage

- Two folders are mounted in each local container to simulate persistent data in your cluster:
- /data (App only data)
- /shared (Shared by all apps)

### Common Cache

- The common folders used by package management tools are mounted in each container and shared by them all:
- /root/.cache (yarn, bower)
- /root/.npm (npm)
- /root/.composer (npm)
- /root/.sbt (scala sbt projects)

## Dockerfile Templates

### Placeholders

Ship will replace by default this placeholders in the Dockerfiles:

Placeholder      | Description
:--------------- | :--------------------------------------------
**APP**\         | The app name
**APP_BRANCH**\  | The app git branch to use
**APP_VERSION**\ | The app version (the actual docker image tag)
**APP_REPO**\    | The complete repository URL
**MAIN_SCRIPT**\ | The main script to execute on nodejs apps

This way you can build generic images to language specific apps.

### Custom Variable Replacement

You can define any variable placeholder inside a docker template and set a fixed value to be replaced by SHIP either in your config.json (usualy ~/.ship/config.json), which will be applied globally to all app that uses a specific template, or in app ship.json so it will be applied to that app only.

The app _ship.json_ takes precedence over user _config.json_.

To make it work, insert the placeholders in your template Docker file and then configure the replacements in either user or app json file. Examples:

**Template Dockerfile**

```docker
FROM alpine:3.6

ENV REPLACED_VAR __PLACEHOLDER__

RUN sh -c "while :; do echo ${REPLACED_VAR}; echo '__PLACEHOLDER2__'; sleet 5; done"
```

**Global Replacement (in all apps)**

In your config.json (usualy ~/.ship/config.json) do as follow:

```json
{
  "ship": {},
  "container_management": {},
  "registry": {},
  "cluster": {},
  "dev": {},
  "replacement": {
    "TEMPLATE_NAME": {
      "__PLACEHOLDER__": "REPLACEMENT_VALUE",
      "__PLACEHOLDER2__": "REPLACEMENT_VALUE2"
    }
  }
}
```

**By APP**

In your app ship.json do as follow:

```json
{
  "ship": {},
  "remote": {},
  "vcs": {},
  "dependencies": {},
  "replacement": {
    "__PLACEHOLDER__": "REPLACEMENT_VALUE",
    "__PLACEHOLDER2__": "REPLACEMENT_VALUE2"
  }
}
```

## APP Config

Each project/app can have a ship.json file in the following format:

```json
{
  "ship": {
    "name": "company-site",
    "type": "node",
    "scope": "app",
    "script": "app.js",
    "url": "yourcompany.com,www.yourcompany.com",
    "ports": ["3024:80"]
  },
  "remote": {
    "resource_profile": "medium",
    "expose": false,
    "port": 10080,
    "health": "/health",
    "env": [{
        "name": "SOME_ENV_VAR",
        "value": "some_content"
    }],
    "labels": [{
        "name": "enableHTTP",
        "value": "1"
    }],
    "volumes": [{
      "container": "/data",
      "host": "/nfs/persistent"
    }]
  },
  "vcs": {
    "url": "git@github.org:yourcompany/company-site.git",
    "branch": "dist"
  },
  "registry": {
    "url": "registry.yourcompany.com:5000",
    "username": "user",
    "password": "pwd"
  },
  "replacement": {
    "__PLACEHOLDER__": "REPLACEMENT_VALUE",
    "__PLACEHOLDER2__": "REPLACEMENT_VALUE2"
  },
  "dependencies": [{
      "name": "api-database",
      "image": "api-database",
      "ports": [],
      "volumes": [],
      "type": "node"
    },
    {
      "name": "api-indicators",
      "image": "api-indicators",
      "ports": [],
      "volumes": [],
      "type": "node"
    }
  ]
}
```

Using a config file is easier because you don't need to pass many parameters when doing operations with ship.

Examples:

- Deploy app-name without a ship.json file:

  - Issue this command from anywhere: **ship deploy app-name -t node**

- Deploy app-name using a ship.json file:

  - Issue this command from app-name folder: **ship deploy**
  - Issue this command from anywhere: **ship deploy app-node**

### Ship Config

- **name**: The app name. Must be equal to the app folder name in your workspace and equal to the bitbucket git repo;
- **type**: The app type. Will be used to choose the right template for this app from TEMPLATES_DIR/TYPE/Dockerfile
- **scope**: The app scope. Is used to classify the application on the cluster, label it in Marathon or Kubernetes;
- **url**: The external url that this app responds to.
- **script**: The name of the main app script.
- **ports**: The ports to expose (Ex.: ["80:80", "1234:1234/udp"]).

### Remote Cluster Config

- **expose**: Boolean. This should be exposed with NodePort so external reverse proxy can reach it?
- **health**: Health check URI to http curl ping (Ex.: "/health").
- **port**: Node (mesos slave) port to expose when using expose: true.
- **resource_profile**: One of the profiles found in the ship project `config.json` file
- **env**: An array of objects containing the environment variable name and value to apply to the service if available on orchestration engine (**this will also be used on local deploys**)
- **labels**: An array of objects containing the label name and value to apply to the service if available on orchestration engine
- **volumes**: A lists of volumes to mount on the application containers (`host` path and `container` path)

**Tip**: Avoid creating large resource_profiles, your application must bre prepared to scale in number of containers. If you are creating a very large resource profile there's a great change that you are doing something wrong. Even so, there are a few applications that may require a high minimum level of resources.

### Dependencies

Dependencies are used for local deployments only.

- **name**: The app name. Must be equal to the app folder name in your workspace and equal to the bitbucket git repo;
- **type**: The app type. Will be used to choose the right template for this app (node,node6,html,php);
- **ports**: Ports array to expose in the dependency container; (Ex.: "volumes": ["80:80","443:443"])
- **volumes**: Volumes array to mount in the dependency container. (Ex.: "volumes": ["/test1:/app","/test2:/app2"])

When you put the dependencies in the ship.json file inside the project root folder you have two options:

```json
    "dependencies": [
        {"name": "api-database", "type": "node"},
        {"name": "app-database"}
    ]
```

1. Put only the dependency name

  - In this case it will look in your workspace for a folder with this name to look for a ship.json file and use the correct param when launching this application container.

2. Put the dependency name and type

  - It will use this template type if it can't find the application ship.json file.

### Template Replacements

You can define any variable placeholder inside a docker template and set a fixed value to be replaced by SHIP in your config.json (usualy ~/.ship/config.json). They will be applied globally to all app that uses a specific template.

Don't forget to add the placeholders to your template Dockerfile.

In this example, SHIUP will look for "**NPM_TOKEN\**" in the Dockerfile of the template "nodejs" and replace by "TOKEN_VALUE":

```json
"replacement": {
  "nodejs": {
    "__NPM_TOKEN__": "TOKEN_VALUE"
  }
}
```

## Commands

### Local Deploy

- Deploy a container locally pointing to the code on your machine

```bash
ship :deploy app-name  # You have the env var WORKSPACE set and a ship.json file in the app folder
ship :deploy app-name  --type=node # You have the env var WORKSPACE set and don't have a ship.json file in the app folder
ship :deploy app-name  --type=node --workspace==/home/user/workspace/ # Will look for /home/user/workspace/app-name
```

- Destroy all local containers created by Ship

```bash
ship :destroy
ship :destroy all
```

- Destroy a single local container created by Ship

```bash
ship :destroy app-name
```

- Deploy a container locally with a specific production version

```bash
ship :deploy app-name --version=999
```

### Cluster Deploy

- Deploy api-indicators with ship.json file settings:

```bash
ship deploy app-name
```

- Deploy app-name with node template:

```bash
ship deploy app-name --type=node
```

- Deploy a new application with node template, classifying as an api:

```bash
ship deploy new-awesome-app --type=node --scope=api
```

- Deploy app-name setting the default script to app/app.js:

```bash
ship deploy app-name  -type=node --script=app/app.js
ship deploy app-name --type=node --script=http-server
```

- Deploy app-name from test branch with the name app-name-beta

```bash
ship deploy app-name-beta --branch=test --repo=app-name --type=node
```

- Rollback a deployment to the previous version (saved in the previous deploy attempt):

```bash
ship rollback app-name
```

### APP Image Update

- Update to a specific existing image tag:

```bash
ship update app-name --version=32
```

## Usage (ship help)

```bash
ship ACTION APP_NAME [OPTIONS]
```

**ACTIONS [REMOTE]:**

Action   | Shorthand | Description
:------- | :-------- | :---------------------------------------------------------------------------------
deploy   | none      | Deploy APP_NAME (Build, push to registry, trigger deployment)
build    | none      | Only build the app image (do NOT push to registry and do NOT trigger deployment)
release  | none      | Build the app image and push to registry (do NOT trigger deployment)
rollback | none      | Rollback to the last saved version of APP_NAME (doesn't work if ship in container)
update   | none      | Update an app to an existing image tag
list     | none      | List all apps on cluster

**ACTIONS [LOCAL]:**

Action        | Shorthand | Description
:------------ | :-------- | :----------------------------------------------------------------------------
config        | none      | Configure ship when running directly in your computer (not in SHIP container)
local:deploy  | :deploy   | Deploy locally on your computer the app APP_NAME
local:destroy | :destroy  | Remove all containers created by SHIP (no argument) or the container APP_NAME
local:list    | :list     | List all containers created by ship
local:shell   | :shell    | Connect to a local container shell (sh)
local:restart | :restart  | Restarts a local container
local:logs    | :logs     | Retrieve local container logs
help          | none      | Display ship help
examples      | none      | Display examples of usage

**OPTIONS:**

   Option    | Description
:----------: | :---------------------------------------------------------------------------------------------
 --version   | Deploy/update to selected version
   --type    | Template to use (will look for TEMPLATES_DIR>/type/Dockerfile)
  --scope    | Scope of application to classify in cluster (Defaults to 'none')
             | Only needed for new applications that are not in k8s yet [OPTIONAL]
  --script   | Main script of the application. Defaults to app.js [OPTIONAL]
--health_uri | Health check URI for the application. Defaults to '/health' [OPTIONAL]
  --expose   | Expose port so the app can be accessed externally [OPTIONAL]
   --port    | Which host port to bind to when deploying locally, defaults to RANDOM [OPTIONAL]
   --url     | List of comma-separated external URLs that an exposed service responds to [OPTIONAL]
             | Example: app-name responds to app.company.com and web.company.com
             | `bash ship deploy app-name --type=node --url=app.company.com,web.company.com`
             | Only used when creating a new application
  --branch   | Which branch to checkout inside container for this application [OPTIONAL]
   --repo    | The name of the repository for this application [OPTIONAL]
             | Example: ship deploy app-name -beta -b test -r app-name -t node
--workspace  | Define a custom workspace path and try to mount WORKSPACE/APP_NAME inside container [OPTIONAL]
             | If not defined will use the env var WORKSPACE if set. Else will deploy production version
             | Example: ship local flow-engine -t php -w $WORKSPACE
             | Only used when deploying a loca application with the 'local' option
 --app-dir   | Where to mount your local workspace app dir inside container
--skip-mount | Does not mount your development code into the container LOCAL_DEPLOY_APP_DIR
  --force    | Force running update even if the remote version is the same as define in --version [OPTIONAL]
   --all     | Run action to all containers [OPTIONAL]
