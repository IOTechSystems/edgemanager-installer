#!/bin/sh
LOGFILE=eb-installer.log
log() {
    echo "[$(date +"%T-%D")]" "$@"
}
exec 3>&1 1>"$LOGFILE" 2>&1
set -x

# Progress bar, used to indicate progress from 0 to 40
bar_size=40
bar_char_done="#"
bar_char_todo="-"
total=40
show_progress() {
  progress="$1"
  todo=$((total - progress))
  # build the done and todo sub-bars
  done_sub_bar=$(printf "%${progress}s" | tr " " "${bar_char_done}")
  todo_sub_bar=$(printf "%${todo}s" | tr " " "${bar_char_todo}")
  # output the bar
  printf "\rProgress : [${done_sub_bar}${todo_sub_bar}]" >&3
  if [ $total -eq $progress ]; then
      printf "\n" >&3
  fi
}

UNINSTALL=false
FILE=""
OFFLINE_PROVISION=false
REPOAUTH=""
INSTALL_DOCKER=false
NO_FRP=false
VER="3.0.6"
FRP_VERSION="0.52.3"

UBUNTU2204="Ubuntu 22.04"
UBUNTU2004="Ubuntu 20.04"
DEBIAN10="Debian GNU/Linux 10"
DEBIAN11="Debian GNU/Linux 11"
RASPBIAN10="Raspbian GNU/Linux 10"

# docker/compose supported versions
DOCKER_VERSION="25.0.3"
COMPOSE_VERSION="v2.24.6"

KEYRINGS_DIR="/etc/apt/keyrings"

# Checks that the kernel is compatible with Golang
version_under_2_6_23(){
    # shellcheck disable=SC2046
    return $(uname -r | awk -F '.' '{
      if ($1 < 2) {
        print 0;
      } else if ($1 == 2) {
        if ($2 <= 6) {
          print 0;
        } else if ($2 == 6) {
          if ($3 <= 23) {
            print 0
          } else {
            print 1
          }
        } else {
          print 1;
        }
      } else {
        print 1;
      }
    }')
}

# Gets the distribution 'name' bionic, focal etc
get_dist_name()
{
  if [ "$1" = "$UBUNTU2204" ]; then
    echo "jammy"
  elif [ "$1" = "$UBUNTU2004" ]; then
    echo "focal"
  elif  [ "$1" = "$DEBIAN11" ]; then
    echo "bullseye"
  elif  [ "$1" = "$DEBIAN10" ] || [ "$1" = "$RASPBIAN10" ]; then
    echo "buster"
  fi
}

# Gets the distribution number 20.04, 22.04 etc
get_dist_num()
{
  if [ "$1" = "$UBUNTU2204" ]; then
    echo "22.04"
  elif [ "$1" = "$UBUNTU2004" ]; then
    echo "20.04"
  elif  [ "$1" = "$DEBIAN10" ] || [ "$1" = "$RASPBIAN10" ]; then
    echo "10"
  elif  [ "$1" = "$DEBIAN11" ]; then
    echo "11"
  fi
}

# Gets the basic distribution type ubuntu, debian etc
get_dist_type()
{
  if [ "$1" = "$UBUNTU2204" ] || [ "$1" = "$UBUNTU2004" ]; then
    echo "ubuntu"
  elif  [ "$1" = "$DEBIAN10" ] || [ "$1" = "$DEBIAN11" ]; then
    echo "debian"
  fi

}

# Get the dist mapping
get_dist_arch()
{
  if [ "$1" = "x86_64" ]; then
    echo "amd64"
  elif [ "$1" = "aarch64" ]; then
    echo "arm64"
  elif [ "$1" = "armv7l" ]; then
    echo "armhf"
  fi
}

# Get the arch names for FRP archives (https://github.com/fatedier/frp/releases)
get_frp_dist_arch()
{
  if [ "$1" = "armhf" ]; then
    echo "arm"
  else
    echo "$1"
  fi
}

check_docker_and_compose()
{
  # Install docker if requested
  if [ "$INSTALL_DOCKER" = "true" ]; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh ./get-docker.sh
  fi

  # Check if the docker is installed and running
  if [ "$(systemctl is-enabled docker.service)" != "enabled" ]; then
    log "Docker is not available, please ensure you have docker version "$DOCKER_VERSION" (or later) installed and running"  >&3
    exit 1
  fi

  # Check docker/compose version
  current_docker_version=$(docker version | sed -n '2p' | awk '{print $2}')
  current_compose_version=$(docker compose version | awk '{print $4}')
  if [ $(echo "$current_docker_version" "$DOCKER_VERSION" | tr " " "\n" | sort | sed -n '1p') != "$DOCKER_VERSION" ]; then
    log "Docker version "$current_docker_version" is not supported, please install docker version "$DOCKER_VERSION" (or later), for details see: https://docs.docker.com/engine/install/" >&3
    exit 2
  elif [ $(echo "$current_compose_version" "$COMPOSE_VERSION" | tr " " "\n" | sort | sed -n '1p') != "$COMPOSE_VERSION" ]; then
    log "Docker compose version "$current_compose_version" is not supported, please install docker compose version "$COMPOSE_VERSION" (or later), for details see: https://docs.docker.com/engine/install/" >&3
    exit 3
  fi
}

# Holds package updates, prevents upgrades via apt-get update/upgrade
hold_package_updates_deb() 
{
  PACKAGE=$1
  apt-mark hold "$PACKAGE"
}

# Holds package updates, prevents upgrades via dnf/yum
hold_package_updates_rpm()
{
  PACKAGE=$1
  PKG_MNGR=$2
  case "$PKG_MNGR" in
    dnf)
      dnf install 'dnf-command(versionlock)' -y
      dnf versionlock add "$PACKAGE-*"
      ;;
    yum)
      yum versionlock add "$PACKAGE-*"
      ;;
  esac
}

# Installs the server components
# Args: Distribution
install_server()
{
  DIST=$1
  log "Starting server ($VER) install on $DIST"
  show_progress 1
  if dpkg -l | grep -qw edgemanager-server ;then
    # shellcheck disable=SC2062
    if dpkg -s edgemanager-server | grep -qw Status.*installed ;then
      PKG_VER=$(dpkg -s edgemanager-server | grep -i version)
       show_progress 40
      log "Server ($PKG_VER) already installed, exiting" >&3
      exit 0
    fi
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wget ca-certificates curl gnupg lsb-release jq

  show_progress 5
  DIST_NAME=$(get_dist_name "$DIST")
  DIST_NUM=$(get_dist_num "$DIST")
  DIST_TYPE=$(get_dist_type "$DIST")
  DIST_ARCH=$(get_dist_arch "$ARCH")

  show_progress 10
  check_docker_and_compose

  show_progress 18
  if test -f "$FILE" ; then
    apt-get update -qq
    apt-get install -y "$FILE"
  else
    wget -q -O - https://iotech.jfrog.io/iotech/api/gpg/key/public | sudo apt-key add -
    DIST_NAME=$(get_dist_name "$DIST")
    if [ "$REPOAUTH" != "" ]; then
      if ! grep -q "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" /etc/apt/sources.list.d/eb-iotech.list ;then
        echo "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech.list
      fi
    else
      if ! grep -q "deb https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" /etc/apt/sources.list.d/eb-iotech.list ;then
        echo "deb https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech.list
      fi
    fi

    apt-get update -qq
    apt-get install -qq -y edgemanager-server="$VER"
  fi

  show_progress 30

  USER=$(logname)
  if [ "$USER" != "root" ]; then
    if ! grep -q "$USER     ALL=(ALL) NOPASSWD:ALL" /etc/sudoers ;then
      echo "$USER     ALL=(ALL) NOPASSWD:ALL" | sudo EDITOR='tee -a' visudo
    fi
    usermod -aG docker "$USER"
  fi

  show_progress 40
  log " Validating installation" >&3
  OUTPUT=$(em-server)
  if [ "$OUTPUT" = "" ]; then
    log "Server installation could not be validated" >&3
  else
    log "Server validation succeeded" >&3
  fi

  # Hold package updates
  hold_package_updates_deb "edgemanager-server"
}

# Installs the node components
# Args: Distribution, Architecture
install_node()
{
  DIST=$1
  ARCH=$2

  log "Starting node ($VER) install on $DIST - $ARCH" >&3
    show_progress 1
  if dpkg -l | grep -qw edgemanager-node ;then
    # shellcheck disable=SC2062
    if dpkg -s edgemanager-node | grep -qw Status.*installed ;then
      PKG_VER=$(dpkg -s edgemanager-node | grep -i version)
      show_progress 40
      log "Node Components ($PKG_VER) already installed, exiting" >&3
      exit 0
    fi
  fi

  show_progress 2

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wget ca-certificates curl gnupg lsb-release

  show_progress 5

  DIST_NAME=$(get_dist_name "$DIST")
  DIST_NUM=$(get_dist_num "$DIST")
  DIST_TYPE=$(get_dist_type "$DIST")
  DIST_ARCH=$(get_dist_arch "$ARCH")
  FRP_DIST_ARCH=$(get_frp_dist_arch "$DIST_ARCH")

  show_progress 10
  check_docker_and_compose

  # Setting up repos to access iotech packages
  wget -q -O - https://iotech.jfrog.io/iotech/api/gpg/key/public | sudo apt-key add -
  if [ "$REPOAUTH" != "" ]; then
    if ! grep -q "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" /etc/apt/sources.list.d/eb-iotech.list ;then
      echo "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech.list
    fi
  else
    if ! grep -q "deb https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" /etc/apt/sources.list.d/eb-iotech.list ;then
      echo "deb https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech.list
    fi
  fi

  show_progress 28

  # check if using local file for dev purposes
  echo "FILE = ${FILE}"
  apt-get update -qq
  if test -f "$FILE" ; then
    apt-get install -y "$FILE"
  else
    apt-get install -y -qq edgemanager-node="$VER"
  fi

  show_progress 28

  USER=$(logname)
  if [ "$USER" != "root" ]; then
    if ! grep -q "$USER     ALL=(ALL) NOPASSWD:ALL" /etc/sudoers ;then
      echo "$USER     ALL=(ALL) NOPASSWD:ALL" | sudo EDITOR='tee -a' visudo
    fi
    usermod -aG docker "$USER"
  fi

  show_progress 30

  # Install FRP if requested
  if [ "$NO_FRP" = "false" ]; then
    log "Installing FRP & configuring" >&3
   # Install the FRP client on the node
     curl -LO https://github.com/fatedier/frp/releases/download/v"$FRP_VERSION"/frp_"$FRP_VERSION"_linux_"$FRP_DIST_ARCH".tar.gz && \
       tar -xf frp_"$FRP_VERSION"_linux_"$FRP_DIST_ARCH".tar.gz && cd frp_"$FRP_VERSION"_linux_"$FRP_DIST_ARCH" && cp frpc /usr/local/bin/

     show_progress 35

    # Reconfigure the /etc/pam.d/sshd file to apply edgemanager user specific settings so that it can use vault OTP authentication
    # Note: All other users should use the default or their own custom pam configurations
    commonAuth="#@include common-auth" # We should disable common-auth for vault authentication
    pamSSHConfigFile="/etc/pam.d/sshd"
    if [ -f /etc/pam.d/sshd ] && [ "$(grep '@include common-auth' ${pamSSHConfigFile})" != "" ]
    then
      commonAuth=$(grep  '@include common-auth' ${pamSSHConfigFile})
    fi
    sed -i 's/^.*@include common-auth//' ${pamSSHConfigFile} # Remove the common-auth line and replace with the below settings
    {
      # IMP: DO NOT ADD/REMOVE any of the following lines
      echo "auth [success=2 default=ignore] pam_succeed_if.so user = edgebuilder"
      echo "${commonAuth}"
      echo "auth [success=ignore default=1] pam_succeed_if.so user = edgebuilder"
      echo "auth requisite pam_exec.so quiet expose_authtok log=/var/log/vault-ssh.log /usr/local/bin/vault-ssh-helper -config=/etc/vault-ssh-helper.d/config.hcl"
      echo "auth optional pam_unix.so use_first_pass nodelay"
    } >> ${pamSSHConfigFile}

  else
     log "No FRP install as the no-frp flag is set" >&3
  fi
  # Load alpine docker image
  docker load -i /opt/edgebuilder/node/alpine_3_19_1.tar

  show_progress 45

  # enable builderd service
  systemctl enable builderd.service
  # enable em-node service for offline node provision
  if [ "$OFFLINE_PROVISION" ]; then
    systemctl enable --now em-node.service
  fi

  log "Validating installation" >&3
  OUTPUT=$(em-node)
  if [ "$OUTPUT" = "" ]; then
    log "Node installation could not be validated" >&3
  else
    log "Node validation succeeded" >&3
  fi

  # Hold package updates
  hold_package_updates_deb "edgemanager-node"
}

# Installs the CLI using apt
# Args: Distribution, Architecture
install_cli_deb()
{

  DIST=$1
  ARCH=$2
  # shellcheck disable=SC2062
  log "Starting CLI ($VER) install on $DIST - $ARCH"  >&3

  show_progress 1

  if dpkg -l | grep -qw edgemanager-cli ;then
    # shellcheck disable=SC2062
    if dpkg -s edgemanager-cli | grep -qw Status.*installed ;then
      PKG_VER=$(dpkg -s edgemanager-node | grep -i version)
      show_progress 40
      log "CLI ($PKG_VER) already installed, exiting"  >&3
      exit 0
    fi
  fi
   show_progress 2

  if version_under_2_6_23; then
    show_progress 40
    log "Kernel version $(uname -r), requires 2.6.23 or above"  >&3
    exit 1
  fi
  show_progress 5
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wget ca-certificates curl gnupg lsb-release
  show_progress 15
  # check if using local file for dev purposes
  if test -f "$FILE" ; then
    apt-get update -qq
    apt-get install -y "$FILE"
  else
    wget -q -O - https://iotech.jfrog.io/iotech/api/gpg/key/public | sudo apt-key add -
    if [ "$REPOAUTH" != "" ]; then
      if ! grep -q "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev all main" /etc/apt/sources.list.d/eb-iotech-cli.list ;then
        echo "deb https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev all main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech-cli.list
      fi
    else
      if ! grep -q "deb https://iotech.jfrog.io/artifactory/debian-release all main" /etc/apt/sources.list.d/eb-iotech-cli.list ;then
        echo "deb https://iotech.jfrog.io/artifactory/debian-release all main" | sudo tee -a /etc/apt/sources.list.d/eb-iotech-cli.list
      fi
    fi
  fi
  show_progress 25

  # check if using local file for dev pur
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if test -f "$FILE" ; then
    apt-get install -y "$FILE"
  else
    sudo apt-get install -y -qq edgemanager-cli="$VER"
  fi

  show_progress 40

  log "Validating installation"  >&3
  OUTPUT=$(em-cli -v)
  if [ "$OUTPUT" = "" ]; then
    log "CLI installation could not be validated"  >&3
    show_progress 40
    exit 1
  else
    log "CLI validation succeeded"  >&3
  fi

  # Hold package updates
  hold_package_updates_deb "edgemanager-cli"
}

# Installs the CLI using dnf
# Args: Distribution, Architecture
install_cli_rpm()
{
  DIST=$1
  ARCH=$2
  PKG_MNGR=$3

  RPM_REPO_DATA='[IoTech]
name=IoTech
baseurl=https://iotech.jfrog.io/artifactory/rpm-release
enabled=1
gpgcheck=0'

  RPM_DEV_REPO_DATA="[IoTech]
name=IoTech
baseurl=https://$REPOAUTH@iotech.jfrog.io/artifactory/rpm-dev
enabled=1
gpgcheck=0"

  log  "Starting CLI ($VER) install on $DIST - $ARCH" >&3
  show_progress 1
  if rpm -qa | grep -qw edgemanager-cli ;then
    PKG_VER=$("$PKG_MNGR" info --installed edgemanager-cli | grep Version)
    show_progress 40
    log "CLI ($PKG_VER) already installed, exiting" >&3
    exit 0
  fi

  if version_under_2_6_23; then
    log "Kernel version $(uname -r), requires 2.6.23 or above" >&3
    show_progress 40
    exit 1
  fi

  if [ "$REPOAUTH" != "" ]; then
    if ! grep -q "$RPM_DEV_REPO_DATA" /etc/yum.repos.d/eb-iotech-cli.repo ;then
      echo "$RPM_DEV_REPO_DATA" | sudo tee -a /etc/yum.repos.d/eb-iotech-cli.repo
    fi
  else
    if ! grep -q "$RPM_REPO_DATA" /etc/yum.repos.d/eb-iotech-cli.repo ;then
      echo "$RPM_REPO_DATA" | sudo tee -a /etc/yum.repos.d/eb-iotech-cli.repo
    fi
  fi
  show_progress 15

  "$PKG_MNGR" install -y edgemanager-cli-"$VER"*

  show_progress 40

  log "Validating installation" >&3
  OUTPUT=$(em-cli -v)
  if [ "$OUTPUT" = "" ]; then
    log "CLI installation could not be validated" >&3
  else
    log "CLI validation succeeded" >&3
  fi

  # Hold package updates
  hold_package_updates_rpm "edgemanager-cli" "$PKG_MNGR"
}

# Uninstall the Server components
uninstall_server()
{
    export DEBIAN_FRONTEND=noninteractive

    log  "Starting Server ($VER) uninstall on $DIST - $ARCH" >&3
    show_progress 1
    # check if edgemanager-server is currently installed
    if dpkg -s edgemanager-server; then
        em-server down -v
        show_progress 45
        # attempt purge
        sudo apt-get -qq purge edgemanager-server -y
        if  ! (dpkg --list edgemanager-server);then
            log "Successfully uninstalled Server Components" >&3
            exit 0
        else
            log "Failed to uninstall Server Components" >&3
            exit 1
        fi
    else
        # package not currently installed, so exit
        log "Server components NOT currently installed" >&3
        exit 0
    fi
}

# Uninstall the Node components
uninstall_node()
{
   log  "Starting Node ($VER) uninstall on $DIST - $ARCH" >&3
   show_progress 1
   if dpkg -s edgemanager-node; then
      show_progress 20
      em-node down
      show_progress 40
      apt-get -qq purge edgemanager-node iotech-builderd-1.1 -y
      if ! (dpkg --list edgemanager-node) ; then
          log "Successfully uninstalled Node Components" >&3
          exit 0
      else
          log "Failed to uninstall Node Components" >&3
          exit 1
      fi
   else
      # package not currently installed, so exit
      log "Node Components NOT currently installed" >&3
      exit 0
   fi
}

# Uninstall the CLI components
uninstall_cli()
{
   show_progress 1
   # check if edgemanager-cli is currently installed
      if dpkg -s edgemanager-cli; then
          sudo apt-get -qq purge edgemanager-cli -y
          show_progress 45
          if (dpkg --list edgemanager-cli) ; then
              log "Failed to uninstall CLI" >&3
              exit 1
          else
              log "CLI Successfully Uninstalled" >&3
              exit 0
          fi
      else
          show_progress 45
          # package not currently installed, so exit
          log "CLI NOT currently installed" >&3
          exit 0
      fi
}

# Displays simple usage prompt
display_usage()
{
  echo "Usage: edgebuilder-install.sh [param] [options]" >&3
  echo "params: server, node, cli" >&3
  echo "options: " >&3
  echo "     -r, --repo-auth          : IoTech repo auth token to access packages" >&3
  echo "     -u, --uninstall          : Uninstall the package" >&3
  echo "     -f, --file               : Absolute path to local package" >&3
  echo "     --offline-provision      : Enable offline node provision" >&3
  echo "     --install-docker         : Install docker as part of package install" >&3
  echo "     --no-frp                 : Do not install FRP for tunnels as part of package install" >&3
}

## Main starts here: ##
# If no options are specified, print help
while [ "$1" != "" ]; do
    case $1 in
        node | server | cli)
            COMPONENT="$1"
            shift
            ;;
        -f | --file)
            FILE="$2"
            shift
            shift
            ;;
        -r | --repo-auth)
            REPOAUTH="$2"
            shift
            shift
            ;;
        -u | --uninstall)
            UNINSTALL=true
            shift
            ;;
        --offline-provision)
            OFFLINE_PROVISION=true
            shift
            ;;
        --install-docker)
            INSTALL_DOCKER=true
            shift
            ;;
        --no-frp)
            NO_FRP=true
            shift
            ;;
        *)
            UNKNOWN_ARG="$1"
            echo "$NODE_ERROR_PREFIX unknown argument '$UNKNOWN_ARG'"
            display_usage
            exit 3
            ;;
    esac
done

# If no params, display help
if [ -z "$COMPONENT" ];then
    display_usage
    exit 1
fi

# If not run as sudo, exit
if [ "$(id -u)" -ne 0 ]; then
  echo "Insufficient permissions, please run as root/sudo"
  exit 1
fi

# if the FILE argument has been supplied and is not a valid path to a file, output an error then exit
if [ "$FILE" != "" ] && ! [ -f "$FILE" ]; then
  log "File $FILE does not exist."  >&3
  exit 1
fi

log "Detecting OS and Architecture"  >&3

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$NAME $VERSION_ID"
elif type lsb_release >/dev/null 2>&1; then
    OS="$(lsb_release -si) $(lsb_release -sr)"
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS="$DISTRIB_ID $DISTRIB_RELEASE"
elif [ -f /etc/debian_version ]; then
    OS="Debian $(cat /etc/debian_version)"
else
    OS="$(uname -s) $(uname -r)"
fi

# Detect Arch
ARCH="$(uname -m)"

# Set the FRP flag to enable/disable
export NO_FRP

# Check compatibility
log "Checking compatibility"  >&3
if [ "$COMPONENT" = "server" ];then
  if "$UNINSTALL"; then
      uninstall_server
  fi

  if [ "$ARCH" = "x86_64" ]||[ "$ARCH" = "aarch64" ];then
    if [ "$OS" = "$UBUNTU2004" ]||[ "$OS" = "$UBUNTU2204" ]||[ "$OS" = "$DEBIAN10" ]||[ "$OS" = "$DEBIAN11" ];then
      install_server "$OS"
    else
      log "The Edge Manager server components are not supported on $OS - $ARCH"  >&3
    fi
  else
    log "The Edge Manager server components are not supported on $ARCH"  >&3
    exit 1
  fi
elif [ "$COMPONENT" = "node" ]; then
  if "$UNINSTALL"; then
     uninstall_node
  fi

  if [ "$ARCH" = "x86_64" ]||[ "$ARCH" = "aarch64" ]||[ "$ARCH" = "armv7l" ];then
    if [ "$OS" = "$UBUNTU2004" ]||[ "$OS" = "$UBUNTU2204" ]||[ "$OS" = "$DEBIAN10" ]||[ "$OS" = "$DEBIAN11" ];then
      install_node "$OS" "$ARCH"
    else
      log "Edge Manager node components are not supported on $OS - $ARCH"  >&3
      exit 1
    fi
  else
    log "Edge Manager node components are not supported on $ARCH"  >&3
    exit 1
  fi
elif [ "$COMPONENT" = "cli" ]; then

  if "$UNINSTALL"; then
      uninstall_cli
  fi

  if [ "$ARCH" = "x86_64" ]||[ "$ARCH" = "aarch64" ]||[ "$ARCH" = "armv7l" ];then
    if [ -x "$(command -v apt-get)" ]; then
      install_cli_deb "$OS" "$ARCH"
    elif [ -x "$(command -v dnf)" ]; then
      install_cli_rpm "$OS" "$ARCH" "dnf"
    elif [ -x "$(command -v yum)" ]; then
      install_cli_rpm "$OS" "$ARCH" "yum"
    else
      log "Edge Manager CLI cannot be installed as no suitable package manager has been found (apt, dnf or yum)"  >&3
      exit 1
    fi
  else
    log "Edge Manager CLI is not supported on $ARCH"  >&3
    exit 1
  fi
fi
