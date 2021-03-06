#!/bin/bash

# The script installs Horizon agent on an edge node

set -e

SCRIPT_VERSION="1.1.0"

SUPPORTED_OS=( "macos" "linux" )
SUPPORTED_LINUX_DISTRO=( "ubuntu" "raspbian" "debian" )
SUPPORTED_LINUX_VERSION=( "bionic" "buster" "xenial" "stretch" )
SUPPORTED_ARCH=( "amd64" "arm64" "armhf" )

# Defaults
PKG_PATH="."
PKG_TREE_IGNORE=false
SKIP_REGISTRATION=false
CFG="agent-install.cfg"
OVERWRITE=false
HZN_NODE_POLICY=""
AGENT_INSTALL_ZIP="agent-install-files.tar.gz"
NODE_ID_MAPPING_FILE="node-id-mapping.csv"
CERTIFICATE_DEFAULT="agent-install.crt"
BATCH_INSTALL=0

VERBOSITY=3 # Default logging verbosity

# required parameters and their defaults
REQUIRED_PARAMS=( "HZN_EXCHANGE_URL" "HZN_FSS_CSSURL" "HZN_ORG_ID" "HZN_EXCHANGE_USER_AUTH" )
REQUIRED_VALUE_FLAG="REQUIRED_FROM_USER"
DEFAULTS=( "${REQUIRED_VALUE_FLAG}" "${REQUIRED_VALUE_FLAG}" "${REQUIRED_VALUE_FLAG}" "${REQUIRED_VALUE_FLAG}" )

# certificate for the CLI package on MacOS
MAC_PACKAGE_CERT="horizon-cli.crt"

# Script help
function help() {
     cat << EndOfMessage
$(basename "$0") <options> -- installing Horizon software
where:
    \$HZN_EXCHANGE_URL, \$HZN_FSS_CSSURL, \$HZN_ORG_ID, \$HZN_EXCHANGE_USER_AUTH variables must be defined either in a config file or environment,

    -c          - path to a certificate file
    -k          - path to a configuration file (if not specified, uses agent-install.cfg in current directory, if present)
    -p          - pattern name to register with (if not specified, registers node w/o pattern)
    -i          - installation packages location (if not specified, uses current directory). if the argument begins with 'http' or 'https', will use as an apt repository
    -j          - file location for the public key for an apt repository specified with '-i'
    -t          - set a branch to use in the apt repo specified with -i. default is 'updates'
    -n          - path to a node policy file
    -s          - skip registration
    -v          - show version
    -l          - logging verbosity level (0-5, 5 is verbose)
    -u          - exchange user authorization credentials
    -d          - the id to register this node with
    -f          - install older version without prompt. overwrite configured node without prompt.
    -w          - wait for the named service to start executing on this node
    -o          - specify an org id for the service specified with '-w'

Example: ./$(basename "$0") -i <path_to_package(s)>

EndOfMessage

quit 1
}

function version() {
	echo "$(basename "$0") version: ${SCRIPT_VERSION}"
	exit 0
}

# Exit handling
function quit(){
  case $1 in
    1) echo "Exiting..."; exit 1
    ;;
    2) echo "Input error, exiting..."; exit 2
    ;;
    *) exit
    ;;
  esac
}

function now() {
	echo `date '+%Y-%m-%d %H:%M:%S'`
}

# Logging
VERB_SILENT=0
VERB_CRITICAL=1
VERB_ERROR=2
VERB_WARNING=3
VERB_INFO=4
VERB_DEBUG=5

function log_notify() {
    log $VERB_SILENT "$1"
}

function log_critical() {
    log $VERB_CRITICAL "CRITICAL: $1"
}

function log_error() {
    log $VERB_ERROR "ERROR: $1"
}

function log_warning() {
    log $VERB_WARNING "WARNING: $1"
}

function log_info() {
    log $VERB_INFO "INFO: $1"
}

function log_debug() {
    log $VERB_DEBUG "DEBUG: $1"
}

function now() {
	echo `date '+%Y-%m-%d %H:%M:%S'`
}

function log() {
    if [ $VERBOSITY -ge $1 ]; then
        echo `now` "$2" | fold -w80 -s
    fi
}

# get variables for the script
# if the env variable is defined uses it, if not checks it in the config file
function get_variable() {
	log_debug "get_variable() begin"

	if ! [ -z "${!1}" ]; then
		# if env/command line variable is defined, using it
		if [[ $1 == *"AUTH"* ]]; then
			log_notify "Using variable from environment/command line, ${1}"
		else
			log_notify "Using variable from environment/command line, ${1} is ${!1}"
		fi
	else
		log_notify "The ${1} is missed in environment/not specified with command line, looking for it in the config file ${2} ..."
		# the env/command line variable not defined, using config file
		# check if it exists
		log_info "Checking if the config file ${2} exists..."
		if [[ -f "$2" ]] ; then
			log_info "The config file ${2} exists"
			if [ -z "$(grep ${1} ${2} | grep "^#")" ] && ! [ -z "$(grep ${1} ${2} | cut -d'=' -f2 | cut -d'"' -f2)" ]; then
				# found variable in the config file
				ref=${1}
				IFS= read -r "$ref" <<<"$(grep ${1} ${2} | cut -d'=' -f2 | cut -d'"' -f2)"
                if [[ $1 == *"AUTH"* ]]; then
                    log_notify "Using variable from the config file ${2}, ${1}"
                else
				    log_notify "Using variable from the config file ${2}, ${1} is ${!1}"
                fi
			else
				# found neither in env nor in config file. check if the missed var is in required parameters
				if [[ " ${REQUIRED_PARAMS[*]} " == *" ${1} "* ]]; then
    				# if found neither in the env nor in the env, try to use its default value, if any
    				log_info "The required variable ${1} found neither in environment nor in the config file ${2}, checking if it has defaults..."

    				for i in "${!REQUIRED_PARAMS[@]}"; do
   						if [[ "${REQUIRED_PARAMS[$i]}" = "${1}" ]]; then
       							log_info "Found ${1} in required params with index ${i}, using it for looking up its default value...";
       							log_info "Found ${1} default, it is ${DEFAULTS[i]}"
       							ref=${1}
								IFS= read -r "$ref" <<<"${DEFAULTS[i]}"
   						fi
					done
					if [ ${!1}  = "$REQUIRED_VALUE_FLAG" ]; then
						log_notify "The ${1} is required and needs to be set either in the config file or environment, exiting..."
						exit 1
					fi
    			else
    				log_info "The variable ${1} found neither in environment nor in the config file ${2}, but it's not required, continuing..."
				fi
			fi
		else
			log_notify "The config file ${2} doesn't exist, exiting..."
			exit 1
		fi
	fi

	log_debug "get_variable() end"
}

# validates if mutually exclusive arguments are mutually exclusive
function validate_mutual_ex() {

	log_debug "validate_mutual_ex() begin"

	if [[ ! -z "${!1}" && ! -z "${!2}" ]]; then
		echo "Both ${1}=${!1} and ${2}=${!2} mutually exlusive parameters are defined, exiting..."
		exit 1
	fi

	log_debug "validate_mutual_ex() end"
}

function validate_number_int() {
	log_debug "validate_number_int() begin"

	re='^[0-9]+$'
	if [[ $1 =~ $re ]] ; then
   		# integer, validate if it's in a correct range
   		if ! (($1 >= VERB_SILENT && $1 <= VERB_DEBUG)); then
   			echo `now` "The verbosity number is not in range [${VERB_SILENT}; ${VERB_DEBUG}]."
  			quit 2
		fi
   	else
   		echo `now` "The provided verbosity value ${1} is not a number" >&2; quit 2
	fi

	log_debug "validate_number_int() end"
}

# set HZN_EXCHANGE_PATTERN to a pattern set in the exchange
function set_pattern_from_exchange(){
	log_debug "set_pattern_from_exchange() begin"
	if [[ "$NODE_ID" != "" ]]; then
        	if [[ "${HZN_EXCHANGE_URL: -1}" == "/" ]]; then
        		HZN_EXCHANGE_URL=$(echo "$HZN_EXCHANGE_URL" | sed 's/\/$//')
		fi
		if [[ $CERTIFICATE != "" ]]; then
			EXCH_OUTPUT=$(curl -fs --cacert $CERTIFICATE $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID/nodes/$NODE_ID -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH ) || true
		else
			EXCH_OUTPUT=$(curl -fs $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID/nodes/$NODE_ID -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH) || true
		fi
		if [[ "$EXCH_OUTPUT" != "" ]]; then
			EXCH_PATTERN=$(echo $EXCH_OUTPUT | jq -e '.nodes | .[].pattern')
			if [[ "$EXCH_PATTERN" != "\"\"" ]]; then
        			HZN_EXCHANGE_PATTERN=$(echo "$EXCH_PATTERN" | sed 's/"//g' )
			fi
		fi
	else
		log_notify "Node id not set. Skipping finding node pattern in the exchange."
	fi
	log_debug "set_pattern_from_exchange() end"
}

# create a file for HZN_NODE_POLICY to point to containing the node policy found in the exchange
function set_policy_from_exchange(){
	log_debug "set_policy_from_exchange() begin"
	if [[ "$NODE_ID" != "" ]]; then
		if [[ "${HZN_EXCHANGE_URL: -1}" == "/" ]]; then
			HZN_EXCHANGE_URL=$(echo "$HZN_EXCHANGE_URL" | sed 's/\/$//')
		fi
		if [[ $CERTIFICATE != "" ]]; then
			EXCH_POLICY=$(curl -fs --cacert $CERTIFICATE $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID/nodes/$NODE_ID/policy -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH) || true
		else
			EXCH_POLICY=$(curl -fs $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID/nodes/$NODE_ID/policy -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH) || true
		fi
		if [[ $EXCH_POLICY != "" ]]; then
			echo $EXCH_POLICY > exchange-node-policy.json
			HZN_NODE_POLICY="exchange-node-policy.json"
		fi
	else
		log_notify "Node id not set. Skipping finding node policy in the exchange."
	fi
	log_debug "set_policy_from_exchange() end"
}

# validate that the found credentials, org id, certificate, and exchange url will work to view the org in the exchange
function validate_exchange(){
	log_debug "validate_exchange() begin"
		if [[ "$CERTIFICATE" != "" ]]; then
			OUTPUT=$(curl -fs --cacert $CERTIFICATE $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH) || true
		else
			OUTPUT=$(curl -fs $CERTIFICATE $HZN_EXCHANGE_URL/orgs/$HZN_ORG_ID -u $HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH) || true
		fi
		if [[ "$OUTPUT" == "" ]]; then
			log_error "Failed to reach exchange using CERTIFICATE=$CERTIFICATE HZN_EXCHANGE_URL=$HZN_EXCHANGE_URL HZN_ORG_ID=$HZN_ORG_ID and HZN_EXCHANGE_USER_AUTH=<specified>"
			exit 1
		fi
	log_debug "validate_exchange() end"
}

# checks input arguments and env variables specified
function validate_args(){
	log_debug "validate_args() begin"

    log_info "Checking script arguments..."

    # preliminary check for script arguments
    check_empty "$PKG_PATH" "path to installation packages"
    if [[ ${PKG_PATH:0:4} == "http" ]]; then
	    PKG_APT_REPO="$PKG_PATH"
	    if [[ "${PKG_APT_REPO: -1}" == "/" ]]; then
		    PKG_APT_REPO=$(echo "$PKG_APT_REPO" | sed 's/\/$//')
	    fi
	    PKG_PATH="."
    else
	    PKG_PATH=$(echo "$PKG_PATH" | sed 's/\/$//')
	    check_exist d "$PKG_PATH" "The package installation"
    fi
    check_empty "$SKIP_REGISTRATION" "registration flag"
    log_info "Check finished successfully"

    log_info "Checking configuration..."
    # read and validate configuration
    get_variable HZN_EXCHANGE_URL $CFG
    check_empty HZN_EXCHANGE_URL "Exchange URL"
    get_variable HZN_FSS_CSSURL $CFG
    check_empty HZN_FSS_CSSURL "FSS_CSS URL"
    get_variable HZN_ORG_ID $CFG
    check_empty HZN_ORG_ID "ORG ID"
    get_variable HZN_EXCHANGE_USER_AUTH $CFG
    check_empty HZN_EXCHANGE_USER_AUTH "Exchange User Auth"
    get_variable NODE_ID $CFG
    get_variable CERTIFICATE $CFG
    get_variable HZN_MGMT_HUB_CERT_PATH $CFG
    if [[ "$CERTIFICATE" == "" ]]; then
	    if [[ "$HZN_MGMT_HUB_CERT_PATH" != "" ]]; then
		    CERTIFICATE=$HZN_MGMT_HUB_CERT_PATH
	    elif [ -f "$CERTIFICATE_DEFAULT" ]; then
		    CERTIFICATE="$CERTIFICATE_DEFAULT"
	    fi
    fi
    validate_exchange
    get_variable HZN_EXCHANGE_PATTERN $CFG
        if [ -z "$HZN_EXCHANGE_PATTERN" ]; then
                set_pattern_from_exchange
        fi

    get_variable HZN_NODE_POLICY $CFG
    # check on mutual exclusive params (node policy and pattern name)
	validate_mutual_ex "HZN_NODE_POLICY" "HZN_EXCHANGE_PATTERN"

	# if a node policy is non-empty, check if the file exists
	if [[ ! -z  $HZN_NODE_POLICY ]]; then
		check_exist f "$HZN_NODE_POLICY" "The node policy"
        elif [[ "$HZN_EXCHANGE_PATTERN" == "" ]] ; then
                set_policy_from_exchange
	fi

    if [[ -z "$WAIT_FOR_SERVICE_ORG" ]] && [[ ! -z "$WAIT_FOR_SERVICE" ]]; then
    	log_error "Must specify service with -w to use with -o organization. Ignoring -o flag."
	unset WAIT_FOR_SERVICE_ORG
    fi

    log_info "Check finished successfully"
    log_debug "validate_args() end"
}

function show_config() {
	log_debug "show_config() begin"

    echo "Current configuration:"
    echo "Certification file: ${CERTIFICATE}"
    echo "Configuration file: ${CFG}"
    echo "Installation packages location: ${PKG_PATH}"
    echo "Ignore package tree: ${PKG_TREE_IGNORE}"
    echo "Pattern name: ${HZN_EXCHANGE_PATTERN}"
    echo "Node policy: ${HZN_NODE_POLICY}"
    echo "Skip registration: ${SKIP_REGISTRATION}"
    echo "HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL}"
    echo "HZN_FSS_CSSURL=${HZN_FSS_CSSURL}"
    echo "HZN_ORG_ID=${HZN_ORG_ID}"
    echo "HZN_EXCHANGE_USER_AUTH=<specified>"
    echo "Verbosity is ${VERBOSITY}"

    log_debug "show_config() end"
}

function check_installed() {
	log_debug "check_installed() begin"

    if command -v "$1" >/dev/null 2>&1; then
        log_info "${2} is installed"
    elif [[ $3 != "" ]]; then
      if command -v "$3" >/dev/null 2>&1; then
        log_notify "${2} not found. Attempting to install with ${3}"
        set -x
        $3 install "$2"
        set +x
      fi
      if command -v "$1" >/dev/null 2>&1; then
        log_info "${2} is now installed"
      else
        log_info "Failed to install ${2} with ${3}. Please install ${2}"
      fi
    else
        log_notify "${2} not found, please install it"
        quit 1
    fi

    log_debug "check_installed() end"
}

# compare versions
function version_gt() {
	test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1";
}

function install_macos() {
    log_debug "install_macos() begin"

    log_notify "Installing agent on ${OS}..."

    log_info "Checking ${OS} specific prerequisites..."
    check_installed "socat" "socat"
    check_installed "docker" "Docker"
    check_installed "jq" "jq" "brew"

    # Setting up a certificate
    log_info "Importing the horizon-cli package certificate into Mac OS keychain..."
    set -x

    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${PACKAGES}/${MAC_PACKAGE_CERT}
    set +x
	if [[ "$CERTIFICATE" != "" ]]; then
		log_info "Configuring an edge node to trust the ICP certificate ..."
		set -x
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERTIFICATE"
		set +x
	fi

	PKG_NAME=$(find . -name "horizon-cli*\.pkg" | sort -V | tail -n 1 | cut -d "/" -f 2)
	log_info "Detecting packages version..."
	PACKAGE_VERSION=$(echo ${PACKAGES}/$PKG_NAME | cut -d'-' -f3 | cut -d'.' -f1-3)
	ICP_VERSION=$(echo ${PACKAGES}/$PKG_NAME | cut -d'-' -f4 | cut -d'.' -f1-3)

	log_info "The packages version is ${PACKAGE_VERSION}"
	log_info "The ICP version is ${ICP_VERSION}"
	if [[ -z "$ICP_VERSION" ]]; then
		export HC_DOCKER_TAG="$PACKAGE_VERSION"
	else
		export HC_DOCKER_TAG="${PACKAGE_VERSION}-${ICP_VERSION}"
	fi

	log_debug "Setting up the agent container tag on Mac..."
    log_debug "HC_DOCKER_TAG is ${HC_DOCKER_TAG}"

    log_info "Checking if hzn is installed..."
    if command -v hzn >/dev/null 2>&1; then
    	# if hzn is installed, need to check the current setup
		log_info "hzn found, checking setup..."
		AGENT_VERSION=$(hzn version | grep "^Horizon Agent" | sed 's/^.*: //' | cut -d'-' -f1)
		log_info "Found Agent version is ${AGENT_VERSION}"
		re='^[0-9]+([.][0-9]+)+([.][0-9]+)'
		if ! [[ $AGENT_VERSION =~ $re ]] ; then
			log_info "Something's wrong. Can't get the agent verison, installing it..."
			set -x
	        sudo installer -pkg ${PACKAGES}/$PKG_NAME -target /
	        set +x
		else
			# compare version for installing and what we have
			log_info "Comparing agent and packages versions..."
			if [ "$AGENT_VERSION" = "$PACKAGE_VERSION" ]; then
				log_info "Versions are equal: agent is ${AGENT_VERSION} and packages are ${PACKAGE_VERSION}. Don't need to install"
			else
				if version_gt "$AGENT_VERSION" "$PACKAGE_VERSION"; then
					log_info "Installed agent ${AGENT_VERSION} is newer than the packages ${PACKAGE_VERSION}"
					if [ ! "$OVERWRITE" = true ] ; then
						if [ $BATCH_INSTALL -eq 1 ]; then
							exit 1
						fi
						echo "The installed agent is newer than one you're trying to install, continue?[y/N]:"
						read RESPONSE
						if [ ! "$RESPONSE" == 'y' ]; then
							echo "Exiting at users request"
							exit
						fi
					fi
					log_notify "Installing older packages ${PACKAGE_VERSION}..."
					set -x
        			sudo installer -pkg ${PACKAGES}/$PKG_NAME -target /
        			set +x
				else
					log_info "Installed agent is ${AGENT_VERSION}, package is ${PACKAGE_VERSION}"
					log_notify "Installing newer package (${PACKAGE_VERSION}) ..."
					set -x
        			sudo installer -pkg ${PACKAGES}/$PKG_NAME -target /
        			set +x
				fi
			fi
		fi
	else
        log_notify "hzn not found, installing it..."
        set -x
        sudo installer -pkg ${PACKAGES}/$PKG_NAME -target /
        set +x
	fi

	start_horizon_service

	process_node

    # configuring agent inside the container
    HZN_CONFIG=/etc/default/horizon
    log_info "Configuring ${HZN_CONFIG} file for the agent container..."
    HZN_CONFIG_DIR=$(dirname "${HZN_CONFIG}")
    if ! [[ -f "$HZN_CONFIG" ]] ; then
	    log_info "$HZN_CONFIG file doesn't exist, creating..."
	    # check if the directory exists
	    if ! [[ -d "$(dirname "${HZN_CONFIG}")" ]] ; then
		    log_info "The directory ${HZN_CONFIG_DIR} doesn't exist, creating..."
            set -x
		    sudo mkdir -p "$HZN_CONFIG_DIR"
            set +x
	    fi
	    log_info "Creating ${HZN_CONFIG} file..."
        set -x
	if [ -z "$CERTIFICATE" ]; then
		printf "HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL} \nHZN_FSS_CSSURL=${HZN_FSS_CSSURL} \
			\nHZN_DEVICE_ID=${HOSTNAME}"  | sudo tee "$HZN_CONFIG"
	else
		if [[ ${CERTIFICATE:0:1} != "/" ]]; then
			ABS_CERTIFICATE=$(pwd)/${CERTIFICATE}
		else
			ABS_CERTIFICATE=${CERTIFICATE}
		fi
		printf "HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL} \nHZN_FSS_CSSURL=${HZN_FSS_CSSURL} \
			\nHZN_DEVICE_ID=${HOSTNAME} \nHZN_MGMT_HUB_CERT_PATH=${ABS_CERTIFICATE}"  | sudo tee "$HZN_CONFIG"
	fi

        set +x
        log_info "Config created"
    else
        if [[ ! -z "${HZN_EXCHANGE_URL}" ]] && [[ ! -z "${HZN_FSS_CSSURL}" ]]; then
                log_info "Found environment variables HZN_EXCHANGE_URL and HZN_FSS_CSSURL, updating horizon config..."
                set -x
		if [ -z "$CERTIFICATE" ]; then
			sudo sed -i.bak -e "s~^HZN_EXCHANGE_URL=[^ ]*~HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL}~g" \
				-e "s~^HZN_FSS_CSSURL=[^ ]*~HZN_FSS_CSSURL=${HZN_FSS_CSSURL}~g"  "$HZN_CONFIG"
		else
			if [[ ${CERTIFICATE:0:1} != "/" ]]; then
				ABS_CERTIFICATE=$(pwd)/${CERTIFICATE}
			else
				ABS_CERTIFICATE=${CERTIFICATE}
			fi
			sudo sed -i.bak -e "s~^HZN_EXCHANGE_URL=[^ ]*~HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL}~g" \
				-e "s~^HZN_FSS_CSSURL=[^ ]*~HZN_FSS_CSSURL=${HZN_FSS_CSSURL}~g" \
				-e "s~^HZN_MGMT_HUB_CERT_PATH=[^ ]*~HZN_MGMT_HUB_CERT_PATH=${ABS_CERTIFICATE}~g" "$HZN_CONFIG"
		fi
                set +x
                log_info "Config updated"
        fi
    fi

    CONFIG_MAC=~/.hzn/hzn.json
    log_info "Configuring hzn..."
    if [[ ! -z "${HZN_EXCHANGE_URL}" ]] && [[ ! -z "${HZN_FSS_CSSURL}" ]]; then
	    if [ -z "$CERTIFICATE" ]; then
	        if [[ ${CERTIFICATE:0:1} != "/" ]]; then
		    ABS_CERTIFICATE=$(pwd)/${CERTIFICATE}
	        else
		    ABS_CERTIFICATE=${CERTIFICATE}
	        fi
    	    fi
        if [[ -f "$CONFIG_MAC" ]]; then
	        log_info "${CONFIG_MAC} config file exists, updating..."
            set -x
		if [ -z "$CERTIFICATE" ]; then
			sed -i.bak -e "s|\"HZN_EXCHANGE_URL\": \"[^ ]*\",|\"HZN_EXCHANGE_URL\": \""$HZN_EXCHANGE_URL"\",|" \
				-e "s|\"HZN_FSS_CSSURL\": \"[^ ]*\"|\"HZN_FSS_CSSURL\": \""$HZN_FSS_CSSURL"\"|"  "$CONFIG_MAC"
		else
			sed -i.bak -e "s|\"HZN_EXCHANGE_URL\": \"[^ ]*\",|\"HZN_EXCHANGE_URL\": \""$HZN_EXCHANGE_URL"\",|" \
				-e "s|\"HZN_FSS_CSSURL\": \"[^ ]*\"|\"HZN_FSS_CSSURL\": \""$HZN_FSS_CSSURL"\"|" \
				-e "s|\"HZN_MGMT_HUB_CERT_PATH\": \"[^ ]*\"|\"HZN_MGMT_HUB_CERT_PATH\": \""$ABS_CERTIFICATE"\"|" "$CONFIG_MAC"
		fi
            set +x
            log_info "Config updated"
        else
	        log_info "${CONFIG_MAC} file doesn't exist, creating..."
            set -x
            mkdir -p "$(dirname "$CONFIG_MAC")"
		if [ -z "$CERTIFICATE" ]; then
			printf "{\n  \"HZN_EXCHANGE_URL\": \""$HZN_EXCHANGE_URL"\",\n  \"HZN_FSS_CSSURL\": \""$HZN_FSS_CSSURL"\"\n}" > "$CONFIG_MAC"
		else
			printf "{\n  \"HZN_EXCHANGE_URL\": \""$HZN_EXCHANGE_URL"\",\n  \"HZN_FSS_CSSURL\": \""$HZN_FSS_CSSURL"\",\n  \"HZN_MGMT_HUB_CERT_PATH\": \""$ABS_CERTIFICATE"\"\n}" > "$CONFIG_MAC"
		fi
            set +x
            log_info "Config created"
        fi
    fi

	start_horizon_service

	create_node

	registration "$SKIP_REGISTRATION" "$HZN_EXCHANGE_PATTERN" "$HZN_NODE_POLICY"

    log_debug "install_macos() end"
}

function install_linux(){
    log_debug "install_linux() begin"
    log_notify "Installing agent on ${DISTRO}, version ${CODENAME}, architecture ${ARCH}"

    ANAX_PORT=8510

    if [[ "$OS" == "linux" ]]; then
        if [ -f /etc/default/horizon ]; then
            log_info "Getting agent port from /etc/default/horizon file..."
            anaxPort=$(grep HZN_AGENT_PORT /etc/default/horizon |cut -d'=' -f2)
            if [[ "$anaxPort" == "" ]]; then
                log_info "Cannot detect agent port as /etc/default/horizon does not contain HZN_AGENT_PORT, using ${ANAX_PORT} instead"
            else
                ANAX_PORT=$anaxPort
            fi
        else
            log_info "Cannot detect agent port as /etc/default/horizon cannot be found, using ${ANAX_PORT} instead"
        fi
    fi

	log_info "Checking if the agent port ${ANAX_PORT} is free..."
	if [ ! -z "$(netstat -nlp | grep \":$ANAX_PORT \")" ]; then
		log_info "Something is running on ${ANAX_PORT}..."
		if [ -z "$(netstat -nlp | grep \":$ANAX_PORT \" | grep anax)" ]; then
			log_notify "It's not anax, please free the port in order to install horizon, exiting..."
			netstat -nlp | grep \":$ANAX_PORT \"
			exit 1
		else
			log_info "It's anax, continuing..."
			netstat -nlp | grep \":$ANAX_PORT \"
		fi
	else
		log_info "Anax port ${ANAX_PORT} is free, continuing..."
	fi

    log_info "Updating OS..."
    set -x
    apt update
    set +x
    log_info "Checking if curl is installed..."
    if command -v curl >/dev/null 2>&1; then
		log_info "curl found"
	else
        log_info "curl not found, installing it..."
        set -x
        apt install -y curl
        set +x
        log_info "curl installed"
	fi

	if command -v jq >/dev/null 2>&1; then
		log_info "jq found"
	else
        log_info "jq not found, installing it..."
        set -x
        apt install -y jq
        set +x
        log_info "jq installed"
	fi

    if [[ ! -z "$PKG_APT_REPO" ]]; then
	    if [[ ! -z "$PKG_APT_KEY" ]]; then
		    log_info "Adding key $PKG_APT_KEY"
		    set -x
		    apt-key add "$PKG_APT_KEY"
		    set +x
	    fi
	    if [[ -z "$APT_REPO_BRANCH" ]]; then
		    APT_REPO_BRANCH="updates"
	    fi
	    log_info "Adding $PKG_APT_REPO to /etc/sources to install with apt"
	    set -x
	    add-apt-repository "deb $PKG_APT_REPO ${CODENAME}-$APT_REPO_BRANCH main"
	    apt-get install bluehorizon -y -f
	    set +x
    else
    	log_info "Checking if hzn is installed..."
    	if command -v hzn >/dev/null 2>&1; then
    		# if hzn is installed, need to check the current setup
		log_info "hzn found, checking setup..."
		AGENT_VERSION=$(hzn version | grep "^Horizon Agent" | sed 's/^.*: //' | cut -d'-' -f1)
		log_info "Found Agent version is ${AGENT_VERSION}"
		re='^[0-9]+([.][0-9]+)+([.][0-9]+)'
		if ! [[ $AGENT_VERSION =~ $re ]] ; then
			log_notify "Something's wrong. Can't get the agent verison, installing it..."
			set -x
	        set +e
	        dpkg -i ${PACKAGES}/*horizon*${DISTRO}.${CODENAME}*.deb
	        set -e
	        set +x
        	log_notify "Resolving any dependency errors..."
        	set -x
        	apt update && apt-get install -y -f
        	set +x
		else
			# compare version for installing and what we have
			PACKAGE_VERSION=$(ls ${PACKAGES} | grep horizon-cli | cut -d'_' -f2 | cut -d'~' -f1)
			log_info "The packages version is ${PACKAGE_VERSION}"
			log_info "Comparing agent and packages versions..."
			if [ "$AGENT_VERSION" = "$PACKAGE_VERSION" ]; then
				log_notify "Versions are equal: agent is ${AGENT_VERSION} and packages are ${PACKAGE_VERSION}. Don't need to install"
			else
				if version_gt "$AGENT_VERSION" "$PACKAGE_VERSION" ; then
					log_notify "Installed agent ${AGENT_VERSION} is newer than the packages ${PACKAGE_VERSION}"
					if [ ! "$OVERWRITE" = true ] ; then
						if [ $BATCH_INSTALL -eq 1 ]; then
							exit 1
						fi
						echo "The installed agent is newer than one you're trying to install, continue?[y/N]:"
						read RESPONSE
						if [ ! "$RESPONSE" == 'y' ]; then
							echo "Exiting at users request"
							exit
						fi
					fi
					log_notify "Installing older packages ${PACKAGE_VERSION}..."
					set -x
		        	set +e
		        	dpkg -i ${PACKAGES}/*horizon*${DISTRO}.${CODENAME}*.deb
		        	set -e
		        	set +x
		        	log_notify "Resolving any dependency errors..."
		        	set -x
		        	apt update && apt-get install -y -f
		        	set +x
				else
					log_info "Installed agent is ${AGENT_VERSION}, package is ${PACKAGE_VERSION}"
					log_notify "Installing newer package (${PACKAGE_VERSION}) ..."
					set -x
		        	set +e
		        	dpkg -i ${PACKAGES}/*horizon*${DISTRO}.${CODENAME}*.deb
		        	set -e
		        	set +x
		        	log_notify "Resolving any dependency errors..."
		        	set -x
		        	apt update && apt-get install -y -f
		        	set +x
				fi
			fi
		fi
	else
        log_notify "hzn not found, installing it..."
        set -x
        set +e
        dpkg -i ${PACKAGES}/*horizon*${DISTRO}.${CODENAME}*.deb
        set -e
        set +x
        log_notify "Resolving any dependency errors..."
        set -x
        apt update && apt-get install -y -f
        set +x
	fi
    fi

    if [[ -f "/etc/horizon/anax.json" ]]; then
	    while read line; do
        	if [[ $(echo $line | grep "APIListen")  != "" ]]; then
    			if [[ $(echo $line | cut -d ":" -f 3 | cut -d "\"" -f 1 ) != "$ANAX_PORT" ]]; then
            			ANAX_PORT=$(echo $line | cut -d ":" -f 3 | cut -d "\"" -f 1 )
				log_info "Using anax port $ANAX_PORT"
    			fi
		break
		fi
    	    done </etc/horizon/anax.json
    fi

    process_node

    check_exist f "/etc/default/horizon" "horizon configuration"
    # The /etc/default/horizon creates upon horizon deb packages installation
    if [[ ! -z "${HZN_EXCHANGE_URL}" ]] && [[ ! -z "${HZN_FSS_CSSURL}" ]]; then
        log_info "Found variables HZN_EXCHANGE_URL and HZN_FSS_CSSURL, updating horizon config..."
        set -x
	if [ -z "$CERTIFICATE" ]; then
		sed -i.bak -e "s~^HZN_EXCHANGE_URL=[^ ]*~HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL}~g" \
			-e "s~^HZN_FSS_CSSURL=[^ ]*~HZN_FSS_CSSURL=${HZN_FSS_CSSURL}~g"  /etc/default/horizon
	else
		if [[ ${CERTIFICATE:0:1} != "/" ]]; then
			ABS_CERTIFICATE=$(pwd)/${CERTIFICATE}
		else
			ABS_CERTIFICATE=${CERTIFICATE}
		fi
		sed -i.bak -e "s~^HZN_EXCHANGE_URL=[^ ]*~HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL}~g" \
			-e "s~^HZN_FSS_CSSURL=[^ ]*~HZN_FSS_CSSURL=${HZN_FSS_CSSURL}~g" \
			-e "s~^HZN_MGMT_HUB_CERT_PATH=[^ ]*~HZN_MGMT_HUB_CERT_PATH=${ABS_CERTIFICATE}~g" /etc/default/horizon
	fi
        set +x
        log_info "Config updated"
    fi

    log_info "Restarting the service..."
    set -x
    systemctl restart horizon.service
    set +x

    start_anax_service_check=`date +%s`

    while [ -z "$(curl -sm 10 http://localhost:$ANAX_PORT/status | jq -r .configuration.exchange_version)" ] ; do
   		current_anax_service_check=`date +%s`
		log_notify "the service is not ready, will retry in 1 second"
		if (( current_anax_service_check - start_anax_service_check > 60 )); then
			log_notify "anax service timeout of 60 seconds occured"
			exit 1
		fi
		sleep 1
	done

    log_notify "The service is ready"

    create_node

    registration "$SKIP_REGISTRATION" "$HZN_EXCHANGE_PATTERN" "$HZN_NODE_POLICY"

    log_debug "install_linux() end"
}

# start horizon service container on mac
function start_horizon_service(){
	log_debug "start_horizon_service() begin"

	if command -v horizon-container >/dev/null 2>&1; then
		if [[ -z $(docker ps -q --filter name=horizon1) ]]; then
			# horizn services container is not running

			if [[ -z $(docker ps -aq --filter name=horizon1) ]]; then
				# horizon services container doesn't exist
		    	log_info "Starting horizon services..."
		    	set -x
		    	horizon-container start
		    	set +x
			else
				# horizon services are shutdown but the container exists
				docker start horizon1
			fi

		   	start_horizon_container_check=`date +%s`

		    while [ -z "$(hzn node list | jq -r .configuration.preferred_exchange_version 2>/dev/null)" ] ; do
		    	current_horizon_container_check=`date +%s`
				log_info "the horizon-container with anax is not ready, retry in 10 seconds"
				if (( current_horizon_container_check - start_horizon_container_check > 300 )); then
					echo `now` "horizon container timeout of 60 seconds occured"
					exit 1
				fi
				sleep 10
			done

			log_info "The horizon-container is ready"
		else
			log_info "The horizon-container is running already..."
		fi
	else
        log_notify "horizon-container not found, hzn is not installed or its installation is broken, exiting..."
        exit 1
	fi


	log_debug "start_horizon_service() end"
}

# stops horizon service container on mac
function stop_horizon_service(){
	log_debug "stop_horizon_service() begin"

	# check if the horizon-container script exists
    if command -v horizon-container >/dev/null 2>&1; then
		# horizon-container script is installed
        if ! [[ -z $(docker ps -q --filter name=horizon1) ]]; then
			log_info "Stopping the Horizon services container...."
			set -x
            horizon-container stop
            set +x
        fi
	else
        log_notify "horizon-container not found, hzn is not installed or its installation is broken, exiting..."
        exit 1
	fi

	log_debug "stop_horizon_service() end"
}

function process_node(){
	log_debug "process_node() begin"
  if [ -z "$OVERWRITE_NODE" ]; then
    OVERWRITE_NODE=$OVERWRITE
  fi

	# Checking node state
	NODE_STATE=$(hzn node list | jq -r .configstate.state)
	WORKLOADS=$(hzn agreement list | jq -r .[])
	if [[ "$NODE_ID" == "" ]] && [[ ! $OVERWRITE_NODE == "true" ]]; then
		NODE_ID=$(hzn node list | jq -r .id)
		log_notify "Registering node with existing id $NODE_ID"
	fi
	if [[ "$HZN_EXCHANGE_PATTERN" == "" ]] && [[ "$HZN_NODE_POLICY" == "" ]] && [[ ! "$OVERWRITE_NODE" == "true" ]]; then
		LOCAL_PATTERN=$(hzn node list | jq -r .pattern)
		if [[ "$LOCAL_PATTERN" != "null" ]] && [[ "$LOCAL_PATTERN" != "" ]]; then
			HZN_EXCHANGE_PATTERN=$LOCAL_PATTERN
		fi
		if [[ "$HZN_EXCHANGE_PATTERN" = "" ]]; then
			hzn policy list > local-node-policy.json
			HZN_NODE_POLICY="local-node-policy.json"
			log_info "Registering node with existing policy $(hzn policy list)"
		else
			log_info "Registering node with existing pattern $HZN_EXCHANGE_PATTERN"
		fi
	fi


	if [ "$NODE_STATE" = "configured" ]; then
		# node is registered
		log_info "Node is registered, state is ${NODE_STATE}"
		if [ -z "$WORKLOADS" ]; then
		 	# w/o pattern currently
			if [[ -z "$HZN_EXCHANGE_PATTERN" ]] && [[ -z "$HZN_NODE_POLICY" ]]; then
				log_info "Neither a pattern nor node policy has not been specified, skipping registration..."
		 	else
				if [[ ! -z "$HZN_EXCHANGE_PATTERN" ]]; then
					log_info "There's no workloads running, but ${HZN_EXCHANGE_PATTERN} pattern has been specified"
					log_info "Unregistering the node and register it again with the new ${HZN_EXCHANGE_PATTERN} pattern..."
				fi
				if [[ ! -z "$HZN_NODE_POLICY" ]]; then
					log_info "There's no workloads running, but ${HZN_NODE_POLICY} node policy has been specified"
					log_info "Unregistering the node and register it again with the new ${HZN_NODE_POLICY} node policy..."
				fi
				set -x
    			hzn unregister -rf
    			set +x
				# if mac, need to stop the horizon services container
				if [[ "$OS" == "macos" ]]; then
					stop_horizon_service
				fi
    		fi
		else
			# with a pattern currently
			log_notify "The node currently has workload(s) (check them with hzn agreement list)"
			if [[ -z "$HZN_EXCHANGE_PATTERN" ]] && [[ -z "$HZN_NODE_POLICY" ]]; then
				log_info "Neither a pattern nor node policy has been specified"
				if [[ ! "$OVERWRITE_NODE" = "true" ]] && [ $BATCH_INSTALL -eq 0 ] ; then
					echo "Do you want to unregister node and register it without pattern or node policy, continue?[y/N]:"
					read RESPONSE
					if [ ! "$RESPONSE" == 'y' ]; then
						echo "Exiting at users request"
						exit
					fi
				fi
				log_notify "Unregistering the node and register it again without pattern or node policy..."
			else
				if [[ ! -z "$HZN_EXCHANGE_PATTERN" ]]; then
					log_notify "${HZN_EXCHANGE_PATTERN} pattern has been specified"
				fi
				if [[ ! -z "$HZN_NODE_POLICY" ]]; then
					log_notify "${HZN_NODE_POLICY} node policy has been specified"
				fi
				if [[ "$OVERWRITE_NODE" != "true" ]] && [ $BATCH_INSTALL -eq 0 ] ; then
					if [[ ! -z "$HZN_EXCHANGE_PATTERN" ]]; then
						echo "Do you want to unregister and register it with a new ${HZN_EXCHANGE_PATTERN} pattern, continue?[y/N]:"
					fi
					if [[ ! -z "$HZN_NODE_POLICY" ]]; then
						echo "Do you want to unregister and register it with a new ${HZN_NODE_POLICY} node policy, continue?[y/N]:"
					fi
					read RESPONSE
					if [ ! "$RESPONSE" == 'y' ]; then
						echo "Exiting at users request"
						exit
					fi
				fi
				if [[ ! -z "$HZN_EXCHANGE_PATTERN" ]]; then
					log_notify "Unregistering the node and register it again with the new ${HZN_EXCHANGE_PATTERN} pattern..."
				fi
				if [[ ! -z "$HZN_NODE_POLICY" ]]; then
					log_notify "Unregistering the node and register it again with the new ${HZN_NODE_POLICY} node policy..."
				fi
			fi
		 	set -x
    		hzn unregister -rf
    		set +x
			# if mac, need to stop the horizon services container
			if [[ "$OS" == "macos" ]]; then
				stop_horizon_service
			fi
		fi
	else
		log_info "Node is not registered, state is ${NODE_STATE}"

		# if mac, need to stop the horizon services container
		if [[ "$OS" == "macos" ]]; then
			stop_horizon_service
		fi
	fi

	log_debug "process_node() end"

}

# creates node
function create_node(){
	log_debug "create_node() begin"

    NODE_NAME=$HOSTNAME
    log_info "Node name is $NODE_NAME"
    if [ -z "$HZN_EXCHANGE_NODE_AUTH" ]; then
        log_info "HZN_EXCHANGE_NODE_AUTH is not defined, creating it..."
        if [[ "$OS" == "linux" ]]; then
            if [ -f /etc/default/horizon ]; then
              if [[ "$NODE_ID" == "" ]]; then
                log_info "Getting node id from /etc/default/horizon file..."
                NODE_ID=$(grep HZN_DEVICE_ID /etc/default/horizon |cut -d'=' -f2)
                if [[ "$NODE_ID" == "" ]]; then
                    NODE_ID=$HOSTNAME
                fi
              fi
            else
                log_info "Cannot detect node id as /etc/default/horizon cannot be found, using ${NODE_NAME} hostname instead"
                NODE_ID=$NODE_NAME
            fi
        elif [[ "$OS" == "macos" ]]; then
            log_info "Using hostname as node id..."
            NODE_ID=$NODE_NAME
        fi
        log_info "Node id is $NODE_ID"

        log_info "Generating node token..."
        HZN_NODE_TOKEN=$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 45 | head -n 1)
        log_notify "Generated node token is ${HZN_NODE_TOKEN}"
        HZN_EXCHANGE_NODE_AUTH="${NODE_ID}:${HZN_NODE_TOKEN}"
        log_info "HZN_EXCHANGE_NODE_AUTH for a node is ${HZN_EXCHANGE_NODE_AUTH}"
    else
        log_notify "Found HZN_EXCHANGE_NODE_AUTH variable, using it..."
    fi

    log_notify "Creating a node..."

    set -x
    hzn exchange node create -n "$HZN_EXCHANGE_NODE_AUTH" -m "$NODE_NAME" -o "$HZN_ORG_ID" -u "$HZN_EXCHANGE_USER_AUTH"
    set +x

    log_notify "Verifying a node..."
    set -x
    hzn exchange node confirm -n "$HZN_EXCHANGE_NODE_AUTH" -o "$HZN_ORG_ID"
    set +x

    log_debug "create_node() end"
}

# register node depending on if registration's requested and pattern name or policy file
function registration() {
	log_debug "registration() begin"

	NODE_STATE=$(hzn node list | jq -r .configstate.state)

	if [ "$NODE_STATE" = "configured" ]; then
		log_info "Node is registered already, skipping registration..."
		return 0
	fi

	WAIT_FOR_SERVICE_ARG=""
	if [[ "$WAIT_FOR_SERVICE" != "" ]]; then
		if [[ "$WAIT_FOR_SERVICE_ORG" != "" ]]; then
			WAIT_FOR_SERVICE_ARG=" -s $WAIT_FOR_SERVICE --serviceorg $WAIT_FOR_SERVICE_ORG "
		else
			WAIT_FOR_SERVICE_ARG=" -s $WAIT_FOR_SERVICE "
		fi
	fi

    NODE_NAME=$HOSTNAME
    log_info "Node name is $NODE_NAME"
    if [ "$1" = true ] ; then
        log_notify "Skipping registration as it was specified with -s"
    else
        log_notify "Registering node..."
        if [[ -z "${2}" ]]; then
        	if [[ -z "${3}" ]]; then
        		log_info "Neither a pattern nor node policy were not specified, registering without it..."
            		set -x
            		hzn register -m "${NODE_NAME}" -o "$HZN_ORG_ID" -u "$HZN_EXCHANGE_USER_AUTH" -n "$HZN_EXCHANGE_NODE_AUTH" $WAIT_FOR_SERVICE_ARG
            		set +x
                else
        		log_info "Node policy ${HZN_NODE_POLICY} was specified, registering..."
            		set -x
            		hzn register -m "${NODE_NAME}" -o "$HZN_ORG_ID" -u "$HZN_EXCHANGE_USER_AUTH" -n "$HZN_EXCHANGE_NODE_AUTH" --policy "$3" $WAIT_FOR_SERVICE_ARG
            		set +x
                fi
        else
        	if [[ -z "${3}" ]]; then
        			log_info "Registering node with ${2} pattern"
            		set -x
            		hzn register -p "$2" -m "${NODE_NAME}" -o "$HZN_ORG_ID" -u "$HZN_EXCHANGE_USER_AUTH" -n "$HZN_EXCHANGE_NODE_AUTH" $WAIT_FOR_SERVICE_ARG
            		set +x
        	else
        		log_info "Pattern ${2} and policy ${3} were specified. However, pattern registration will override the policy, registering..."
            		set -x
           	 	hzn register -p "$2" -m "${NODE_NAME}" -o "$HZN_ORG_ID" -u "$HZN_EXCHANGE_USER_AUTH" -n "$HZN_EXCHANGE_NODE_AUTH" --policy "$3" $WAIT_FOR_SERVICE_ARG
            		set +x
                fi
        fi
    fi

    log_debug "registration() end"
}

function check_empty() {
	log_debug "check_empty() begin"

    if [ -z "$1" ]; then
        log_notify "The ${2} value is empty, exiting..."
        exit 1
    fi

    log_debug "check_empty() end"
}

# checks if file or directory exists
function check_exist() {
	log_debug "check_exist() begin"

    case $1 in
	f) if ! [[ -f "$2" ]] ; then
			log_notify "${3} file ${2} doesn't exist"
		    exit 1
		fi
	;;
	d) if ! [[ -d "$2" ]] ; then
			log_notify "${3} directory ${2} doesn't exist"
	        exit 1
		fi
    ;;
    w) if ! ls ${2} 1> /dev/null 2>&1 ; then
			log_notify "${3} files ${2} do not exist"
	        exit 1
	    fi
	;;
	*) echo "not supported"
        exit 1
	;;
	esac

	log_debug "check_exist() end"
}

# autocomplete support for CLI
function add_autocomplete() {
	log_debug "add_autocomplete() begin"

	log_info "Enabling autocomplete for the CLI commands..."

	SHELL_FILE="${SHELL##*/}"

    if [ -f "/etc/bash_completion.d/hzn_bash_autocomplete.sh" ]; then
        AUTOCOMPLETE="/etc/bash_completion.d/hzn_bash_autocomplete.sh"
    elif [ -f "/usr/local/share/horizon/hzn_bash_autocomplete.sh" ]; then
        # backward compatibility support
        AUTOCOMPLETE="/usr/local/share/horizon/hzn_bash_autocomplete.sh"
    fi

    if [[ ! -z "$AUTOCOMPLETE" ]]; then
    	if [ -f ~/.${SHELL_FILE}rc ]; then
            grep -q "^source ${AUTOCOMPLETE}" ~/.${SHELL_FILE}rc || \
            echo "source ${AUTOCOMPLETE}" >> ~/.${SHELL_FILE}rc
    	else
	    echo "source ${AUTOCOMPLETE}" > ~/.${SHELL_FILE}rc
    	fi
    else
        log_info "There's no an autocomplete script expected, skipping it..."
    fi

	log_debug "add_autocomplete() end"
}

# detects operating system.
function detect_os() {
    log_debug "detect_os() begin"

    if [[ "$OSTYPE" == "linux"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        OS="unknown"
    fi

    log_info "Detected OS is ${OS}"

    log_debug "detect_os() end"
}

# detects linux distributive name, version, and codename
function detect_distro() {
    log_debug "detect_distro() begin"

    if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO=$ID
            VER=$VERSION_ID
            CODENAME=$VERSION_CODENAME
    elif type lsb_release >/dev/null 2>&1; then
            DISTRO=$(lsb_release -si)
            VER=$(lsb_release -sr)
            CODENAME=$(lsb_release -sc)
    elif [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            DISTRO=$DISTRIB_ID
            VER=$DISTRIB_RELEASE
            CODENAME=$DISTRIB_CODENAME
    else
            log_notify "Cannot detect Linux version, exiting..."
            exit 1
    fi

    # Raspbian has a codename embedded in a version
    if [[ "$DISTRO" == "raspbian" ]]; then
        CODENAME=$(echo ${VERSION} | sed -e 's/.*(\(.*\))/\1/')
    fi

    log_info "Detected distributive is ${DISTRO}, verison is ${VER}, codename is ${CODENAME}"

    log_debug "detect_distro() end"
}

# detects hardware architecture on linux
function detect_arch() {
    log_debug "detect_arch() begin"

    # detecting architecture
    uname="$(uname -m)"
    if [[ "$uname" =~ "aarch64" ]]; then
        ARCH="arm64"
    elif [[ "$uname" =~ "arm" ]]; then
        ARCH="armhf"
    elif [[ "$uname" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$uname" == "ppc64le" ]]; then
        ARCH="ppc64el"
    else
        (>&2 echo "Unknown architecture $uname")
        exit 1
    fi

    log_info "Detected architecture is ${ARCH}"

    log_debug "detect_arch() end"
}

# checks if OS/distributive/codename/arch is supported
function check_support() {
    log_debug "check_support() begin"

    # checks if OS, distro or arch is supported

    if [[ ! "${1}" = *"${2}"* ]]; then
        echo "Supported components are: "
        for i in "${1}"; do echo -n "${i} "; done
        echo ""
        log_notify "The detected ${2} is not supported, exiting..."
        exit 1
    else
        log_info "The detected ${2} is supported"
    fi

    log_debug "check_support() end"
}

# checks if requirements are met
function check_requirements() {
    log_debug "check_requirements() begin"

    detect_os

    log_info "Checking support of detected OS..."
    check_support "${SUPPORTED_OS[*]}" "$OS"

    if [ "$OS" = "linux" ]; then
        detect_distro
        log_info "Checking support of detected Linux distributive..."
        check_support "${SUPPORTED_LINUX_DISTRO[*]}" "$DISTRO"
        log_info "Checking support of detected Linux version/codename..."
        check_support "${SUPPORTED_LINUX_VERSION[*]}" "$CODENAME"
        detect_arch
        log_info "Checking support of detected architecture..."
        check_support "${SUPPORTED_ARCH[*]}" "$ARCH"

	if [[ -z "$PKG_APT_REPO" ]]; then
        	log_info "Checking the path with packages..."

        	if [ "$PKG_TREE_IGNORE" = true ] ; then
        		# ignoring the package tree, checking the current dir
        		PACKAGES="${PKG_PATH}"
      		else
        		# checking the package tree for linux
        		PACKAGES="${PKG_PATH}/${OS}/${DISTRO}/${CODENAME}/${ARCH}"
        	fi

        	log_info "Checking path with packages ${PACKAGES}"
        	check_exist w "${PACKAGES}/*horizon*${DISTRO}.${CODENAME}*.deb" "Linux installation"
	fi

        if [ $(id -u) -ne 0 ]; then
	        log_notify "Please run script with the root priveleges by running 'sudo -s' command first"
            quit 1
        fi

    	elif [ "$OS" = "macos" ]; then
	    if [[ -z "$PKG_APT_REPO" ]]; then
    		log_info "Checking the path with packages..."

    		if [ "$PKG_TREE_IGNORE" = true ] ; then
      			# ignoring the package tree, checking the current dir
      			PACKAGES="${PKG_PATH}"
      		else
      			# checking the package tree for macos
      			PACKAGES="${PKG_PATH}/${OS}"
      		fi

      		log_info "Checking path with packages ${PACKAGES}"
      		check_exist w "${PACKAGES}/horizon-cli-*.pkg" "MacOS installation"
      		check_exist f "${PACKAGES}/${MAC_PACKAGE_CERT}" "The CLI package certificate"
	fi
    fi

    log_debug "check_requirements() end"
}

function check_node_state() {
	log_debug "check_node_state() begin"

	if command -v hzn >/dev/null 2>&1; then
		local NODE_STATE=$(hzn node list | jq -r .configstate.state)
		log_info "Current node state is: ${NODE_STATE}"

		if [ $BATCH_INSTALL -eq 0 ] && [[ "$NODE_STATE" = "configured" ]] && [[ ! $OVERWRITE = "true" ]]; then
			# node is configured need to ask what to do
			log_notify "Your node is registered"
			echo "Do you want to overwrite the current node configuration?[y/N]:"
			read RESPONSE
			if [ "$RESPONSE" == 'y' ]; then
				OVERWRITE_NODE=true
				log_notify "The configuration will be overwritten..."
			else
				log_notify "You might be asked for overwrite confirmations later..."
			fi
		elif [[ "$NODE_STATE" = "unconfigured" ]]; then
			# node is unconfigured
			log_info "The node is in unconfigured state, continuing..."
		fi
	else
		log_info "The hzn doesn't seem to be installed, continuing..."
	fi

	log_debug "check_node_state() end"
}

function unzip_install_files() {
	if [ -f $AGENT_INSTALL_ZIP ]; then
		tar -zxf $AGENT_INSTALL_ZIP
	else
		log_error "Agent install tar file $AGENT_INSTALL_ZIP does not exist."
	fi
}

function find_node_id() {
	log_debug "start find_node_id"
	if [ -f $NODE_ID_MAPPING_FILE ]; then
		BATCH_INSTALL=1
		log_debug "found id mapping file $NODE_ID_MAPPING_FILE"
		ID_LINE=$(grep $(hostname) "$NODE_ID_MAPPING_FILE" || [[ $? == 1 ]] )
		if [ -z $ID_LINE ]; then
			log_debug "Did not find node id with hostname. Trying with ip"
			find_node_ip_address
			for IP in $(echo $NODE_IP); do
				ID_LINE=$(grep "$IP" "$NODE_ID_MAPPING_FILE" || [[ $? == 1 ]] )
				if [[ ! "$ID_LINE" = "" ]];then break; fi
			done
			if [[ ! "$ID_LINE" = "" ]]; then
				NODE_ID=$(echo $ID_LINE | cut -d "," -f 2)
			else
				log_notify "Failed to find node id in mapping file $NODE_ID_MAPPING_FILE with $(hostname) or $NODE_IP"
				exit 1
			fi
		else
			NODE_ID=$(echo $ID_LINE | cut -d "," -f 2)
		fi
	fi
	log_debug "finished find_node_id"
}

function find_node_ip_address() {
	NODE_IP=$(hostname -I)
}

# Accept the parameters from command line
while getopts "c:i:j:p:k:u:d:z:hvl:n:sfw:o:t:" opt; do
	case $opt in
		c) CERTIFICATE="$OPTARG"
		;;
		i) PKG_PATH="$OPTARG" PKG_TREE_IGNORE=true
		;;
		j) PKG_APT_KEY="$OPTARG"
		;;
		p) HZN_EXCHANGE_PATTERN="$OPTARG"
		;;
		k) CFG="$OPTARG"
		;;
		u) HZN_EXCHANGE_USER_AUTH="$OPTARG"
		;;
		d) NODE_ID="$OPTARG"
		;;
		z) AGENT_INSTALL_ZIP="$OPTARG"
		;;
		h) help
		;;
		v) version
		;;
		l) validate_number_int "$OPTARG"; VERBOSITY="$OPTARG"
		;;
		n) HZN_NODE_POLICY="$OPTARG"
		;;
		s) SKIP_REGISTRATION=true
		;;
		f) OVERWRITE=true
		;;
		w) WAIT_FOR_SERVICE="$OPTARG"
		;;
		o) WAIT_FOR_SERVICE_ORG="$OPTARG"
		;;
		t) APT_REPO_BRANCH="$OPTARG"
		;;
		\?) echo "Invalid option: -$OPTARG"; help
		;;
		:) echo "Option -$OPTARG requires an argument"; help
		;;
	esac
done

if [ -f "$AGENT_INSTALL_ZIP" ]; then
	unzip_install_files
	find_node_id
	NODE_ID=$(echo "$NODE_ID" | sed -e 's/^[[:space:]]*//' | sed -e 's/[[:space:]]*$//' )
	if [[ $NODE_ID != "" ]]; then
		log_info "Found node id $NODE_ID"
	fi
fi

# checking the supplied arguments
validate_args "$*" "$#"
# showing current configuration
show_config
# checking if the requirements are met
check_requirements

check_node_state

if [[ "$OS" == "linux" ]]; then
	echo `now` "Detection results: OS is ${OS}, distributive is ${DISTRO}, release is ${CODENAME}, architecture is ${ARCH}"
	install_${OS} ${OS} ${DISTRO} ${CODENAME} ${ARCH}
elif [[ "$OS" == "macos" ]]; then
	echo `now` "Detection results: OS is ${OS}"
	install_${OS}
fi

add_autocomplete
