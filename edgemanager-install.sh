#!/bin/sh
LOGFILE=em-installer.log
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
SERVER_URL=""
SUMS_SHA256=""
DOWNLOAD_ONLY=false
LOCAL_DIR=""

FORCE_YES=false
VER="3.2.7.dev"

UBUNTU2604="Ubuntu 26.04"
UBUNTU2404="Ubuntu 24.04"
UBUNTU2204="Ubuntu 22.04"
DEBIAN13="Debian GNU/Linux 13"
DEBIAN12="Debian GNU/Linux 12"

# docker/compose supported versions
DOCKER_VERSION="25.0.3"
COMPOSE_VERSION="v2.24.6"

KEYRINGS_DIR="/etc/apt/keyrings"

# Node packages installed from an Edge Manager server are kept here, outside /opt/edgebuilder/node so uninstalling
# doesn't remove them, so an upgrade can roll back to the previous version without network access
NODE_PACKAGES_DIR="/var/lib/edgemanager/packages"

# Checks that the kernel is compatible with Golang
version_under_2_6_32(){
    # shellcheck disable=SC2046
    return $(uname -r | awk -F '.' '{
      if ($1 < 2) {
        print 0;
      } else if ($1 == 2) {
        if ($2 < 6) {
          print 0;
        } else if ($2 == 6) {
          if ($3 < 32) {
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
  if [ "$1" = "$UBUNTU2604" ]; then
    echo "resolute"
  elif [ "$1" = "$UBUNTU2404" ]; then
    echo "noble"
  elif [ "$1" = "$UBUNTU2204" ]; then
    echo "jammy"
  elif  [ "$1" = "$DEBIAN13" ]; then
    echo "trixie"
  elif  [ "$1" = "$DEBIAN12" ]; then
    echo "bookworm"
  fi
}

# Gets the distribution number 20.04, 22.04 etc
get_dist_num()
{
  if [ "$1" = "$UBUNTU2604" ]; then
    echo "26.04"
  elif [ "$1" = "$UBUNTU2404" ]; then
    echo "24.04"
  elif [ "$1" = "$UBUNTU2204" ]; then
    echo "22.04"
  elif  [ "$1" = "$DEBIAN13" ]; then
    echo "13"
  elif  [ "$1" = "$DEBIAN12" ]; then
    echo "12"
  fi
}

# Gets the basic distribution type ubuntu, debian etc
get_dist_type()
{
  if [ "$1" = "$UBUNTU2604" ] || [ "$1" = "$UBUNTU2404" ] || [ "$1" = "$UBUNTU2204" ]; then
    echo "ubuntu"
  elif  [ "$1" = "$DEBIAN13" ] || [ "$1" = "$DEBIAN12" ]; then
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

check_docker_and_compose()
{
  # Install docker if requested
  if [ "$INSTALL_DOCKER" = "true" ]; then
    # Bounded so an offline machine fails with an error rather than hanging
    if ! curl -fsSL --connect-timeout 30 --max-time 300 --retry 2 https://get.docker.com -o get-docker.sh; then
      log "Unable to download the Docker install script from https://get.docker.com, check this machine has internet access or install docker version "$DOCKER_VERSION" (or later) before running the installer" >&3
      exit 1
    fi
    # No sudo here: this script already requires root (checked at startup), and an extra
    # sudo layer adds a redundant use_pty session that newer sudo versions can freeze on
    sh ./get-docker.sh
  fi

  # Check if the docker is installed and running
  if [ "$(systemctl is-enabled docker.service)" != "enabled" ]; then
    log "Docker is not available, please ensure you have docker version "$DOCKER_VERSION" (or later) installed and running"  >&3
    exit 1
  fi

  # Check docker/compose version
  current_docker_version=$(docker version | sed -n '2p' | awk '{print $2}')
  current_compose_version=$(docker compose version | awk '{print $4}' | sed 's/+.*//' | tr -d 'v')
  COMPOSE_VERSION_CLEAN=$(echo "$COMPOSE_VERSION" | tr -d 'v')

  if [ $(echo "$current_docker_version" "$DOCKER_VERSION" | tr " " "\n" | sort | sed -n '1p') != "$DOCKER_VERSION" ]; then
    log "Docker version "$current_docker_version" is not supported, please install docker version "$DOCKER_VERSION" (or later), for details see: https://docs.docker.com/engine/install/" >&3
    exit 2
  elif [ $(printf '%s\n' "$current_compose_version" "$COMPOSE_VERSION_CLEAN" | sort -V | head -n1) != "$COMPOSE_VERSION_CLEAN" ]; then
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

unhold_package_updates_deb()
{
  PACKAGE=$1
  apt-mark unhold "$PACKAGE"
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

# Fetches and trusts the IOTech apt repo signing key via a dedicated keyring
# file. Replaces the deprecated/removed 'apt-key add', which is no longer
# available on newer distributions (e.g. Ubuntu 26.04).
# The download is bounded so an offline machine fails with an error rather than hanging. A failure is only fatal
# when installing from the IOTech repo; a local package (-f) doesn't need the key.
setup_iotech_apt_key()
{
  sudo mkdir -p "$KEYRINGS_DIR"
  KEY_URL="https://iotech.jfrog.io/iotech/api/gpg/key/public"
  KEY_FILE=$(mktemp)
  if ! wget -q --timeout=30 --tries=3 -O "$KEY_FILE" "$KEY_URL"; then
    rm -f "$KEY_FILE"
    if [ -n "$FILE" ]; then
      log "WARNING: Unable to download the IOTech package signing key from $KEY_URL, continuing with local package $FILE" >&3
      return 0
    fi
    log "Unable to download the IOTech package signing key from $KEY_URL, check this machine can reach iotech.jfrog.io" >&3
    exit 1
  fi
  sudo gpg --batch --yes --dearmor -o "$KEYRINGS_DIR/iotech.gpg" "$KEY_FILE"
  rm -f "$KEY_FILE"
}

# Downloads a file from the Edge Manager server, with timeouts so an unreachable server fails rather than hangs. The
# server commonly has a self-signed certificate, so TLS isn't verified; downloads are checked against SHA256SUMS.
# Args: URL, destination file
server_download()
{
  wget -q --timeout=30 --tries=2 --no-check-certificate -O "$2" "$1"
}

# Checks the node packages in a directory against the SHA256SUMS file in it
# Args: Directory
verify_package_dir()
{
  if [ ! -f "$1/SHA256SUMS" ]; then
    log "WARNING: no SHA256SUMS in $1, the node packages are not verified" >&3
  elif ! (cd "$1" && sha256sum -c --quiet SHA256SUMS); then
    log "The node packages in $1 do not match their checksums" >&3
    exit 1
  fi
}

# Downloads this node's packages from the Edge Manager server's node-components bundle into the package cache and
# verifies them. Already-cached packages that still match are reused. Sets PACKAGE_DIR, NODE_DEB and NODE_VER.
# Args: Distribution codename, Architecture
download_server_packages()
{
  SUMS_FILE=$(mktemp)
  if ! server_download "$SERVER_URL/SHA256SUMS" "$SUMS_FILE"; then
    rm -f "$SUMS_FILE"
    log "Unable to download $SERVER_URL/SHA256SUMS, check this machine can reach the Edge Manager server" >&3
    exit 1
  fi
  if [ -n "$SUMS_SHA256" ]; then
    if ! echo "$SUMS_SHA256  $SUMS_FILE" | sha256sum -c --quiet -; then
      rm -f "$SUMS_FILE"
      log "The node package list from the Edge Manager server does not match this provision command - generate a new provision command" >&3
      exit 1
    fi
  else
    log "WARNING: no --sums-sha256 given, the node package list from the Edge Manager server is not verified" >&3
  fi

  PACKAGE_PATH="packages/$1/$2/"
  PACKAGE_SUMS=$(grep "  $PACKAGE_PATH" "$SUMS_FILE")
  rm -f "$SUMS_FILE"
  NODE_DEB=$(echo "$PACKAGE_SUMS" | sed -n "s|.*  $PACKAGE_PATH\(edgemanager-node-.*\.deb\)\$|\1|p")
  if [ -z "$NODE_DEB" ]; then
    log "The Edge Manager server has no node packages for $1 $2" >&3
    exit 1
  fi
  NODE_VER=$(echo "$NODE_DEB" | sed 's/^edgemanager-node-\(.*\)_[^_]*\.deb$/\1/')

  PACKAGE_DIR="$NODE_PACKAGES_DIR/$NODE_VER"
  mkdir -p "$PACKAGE_DIR"
  echo "$PACKAGE_SUMS" | sed "s|  $PACKAGE_PATH|  |" > "$PACKAGE_DIR/SHA256SUMS"
  if (cd "$PACKAGE_DIR" && sha256sum -c --quiet SHA256SUMS) > /dev/null 2>&1; then
    log "Using node packages ($NODE_VER) already downloaded to $PACKAGE_DIR" >&3
    return
  fi
  log "Downloading node packages ($NODE_VER) from the Edge Manager server" >&3
  for DEB in $(awk '{print $2}' "$PACKAGE_DIR/SHA256SUMS"); do
    if ! server_download "$SERVER_URL/$PACKAGE_PATH$DEB" "$PACKAGE_DIR/$DEB"; then
      log "Unable to download $SERVER_URL/$PACKAGE_PATH$DEB, check this machine can reach the Edge Manager server" >&3
      exit 1
    fi
  done
  verify_package_dir "$PACKAGE_DIR"
}

# Lists the dependencies of a node package that aren't installed, other than the IOTech packages bundled with it
# Args: edgemanager-node deb
missing_node_dependencies()
{
  for DEP in $(dpkg-deb -f "$1" Depends | tr ',' '\n' | sed 's/(.*)//; s/|.*//; s/[[:space:]]//g' | grep -v '^iotech-'); do
    dpkg -s "$DEP" 2>/dev/null | grep -q '^Status: install ok installed' || echo "$DEP"
  done
}

# Checks a node package's dependencies are installed, installing missing ones from the distro's package sources
# unless only checking, so a node without network access gets a clear error before anything is changed
# Args: edgemanager-node deb, "check" to only check
check_node_dependencies()
{
  MISSING=$(missing_node_dependencies "$1")
  if [ -n "$MISSING" ] && [ "$2" != "check" ]; then
    log "Installing packages required by the node components: $(echo $MISSING)" >&3
    apt-get install -y -qq $MISSING
    MISSING=$(missing_node_dependencies "$1")
  fi
  if [ -n "$MISSING" ]; then
    log "Missing packages required by the node components: $(echo $MISSING) - install them, or make a package mirror available, and try again" >&3
    exit 1
  fi
}

# Keeps the two most recently used package versions in the cache: the installed one and the previous one, for rollback
prune_package_cache()
{
  ls -1t "$NODE_PACKAGES_DIR" | tail -n +3 | while read -r OLD_VER; do
    rm -rf "${NODE_PACKAGES_DIR:?}/$OLD_VER"
  done
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
      log "Server ($PKG_VER) already installed" >&3
      if [ "$INSTALL_DOCKER" = "true" ]; then
        check_docker_and_compose
      fi
      show_progress 40
      log "Exiting" >&3
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
  unhold_package_updates_deb "edgemanager-server"
  if test -f "$FILE" ; then
    apt-get update -qq
    apt-get install -y "$FILE"
  else
    setup_iotech_apt_key
    DIST_NAME=$(get_dist_name "$DIST")
    if [ "$REPOAUTH" != "" ]; then
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" | sudo tee /etc/apt/sources.list.d/em-iotech.list
    else
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" | sudo tee /etc/apt/sources.list.d/em-iotech.list
    fi

    apt-get update -qq
    apt-get install -qq -y edgemanager-server="$VER"
  fi

  show_progress 30

  USER=$(logname 2>/dev/null || true)
  if [ -n "$USER" ] && [ "$USER" != "root" ]; then
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

  # Ahead of an upgrade, on a node that still has the old version installed: fetch and verify the new packages and
  # check their dependencies, without installing anything, so the upgrade can stop before removing the old version
  if [ "$DOWNLOAD_ONLY" = "true" ]; then
    if [ -z "$SERVER_URL" ]; then
      log "--download-only needs --server" >&3
      exit 1
    fi
    download_server_packages "$(get_dist_name "$DIST")" "$(get_dist_arch "$ARCH")"
    check_node_dependencies "$PACKAGE_DIR/$NODE_DEB" check
    log "Node packages ($NODE_VER) downloaded to $PACKAGE_DIR" >&3
    exit 0
  fi

  # Packages come from the Edge Manager server's node-components bundle (or a local copy of one) rather than the
  # IOTech repo. Package source lookups are bounded so a node without network access doesn't stall on them.
  APT_UPDATE_OPTS=""
  if [ -n "$SERVER_URL" ] || [ -n "$LOCAL_DIR" ]; then
    APT_UPDATE_OPTS="-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
  fi

  # With packages from a server bundle or local directory, the version installed is theirs, not this script's VER
  if [ -n "$SERVER_URL" ]; then
    log "Starting node install on $DIST - $ARCH, from the Edge Manager server" >&3
  elif [ -n "$LOCAL_DIR" ]; then
    log "Starting node install on $DIST - $ARCH, from $LOCAL_DIR" >&3
  else
    log "Starting node ($VER) install on $DIST - $ARCH" >&3
  fi
    show_progress 1
  if dpkg -l | grep -qw edgemanager-node ;then
    # shellcheck disable=SC2062
    if dpkg -s edgemanager-node | grep -qw Status.*installed ;then
      PKG_VER=$(dpkg -s edgemanager-node | grep -i version)
      if systemctl is-active --quiet builderd; then
        log "WARNING: em-node is already installed ($PKG_VER) and builderd is running. This node may already be connected to an instance of EdgeManager." >&3
        if [ "$FORCE_YES" != "true" ]; then
          printf "Would you still like to proceed? [Y/N]: " >&3
          if [ -c /dev/tty ]; then
            read -r ANSWER </dev/tty
          else
            ANSWER="Y"
          fi
          case "$ANSWER" in
            [Yy]*) ;;
            *)
              log "Installation aborted." >&3
              exit 1
              ;;
          esac
        fi
      fi
      log "Node Components ($PKG_VER) already installed" >&3
      if [ "$INSTALL_DOCKER" = "true" ]; then
        check_docker_and_compose
      fi
      show_progress 40
      log "Exiting" >&3
      exit 0
    fi
  fi

  show_progress 2

  # The new EM Agent 'iotech-builderd-1.2' depends on 'iotech-libpaho-mqtt-1.3'.
  # Previous versions (from v3.0.6 and backwards) of EM Agent 'iotech-builderd-1.2' depends on 'libpaho-mqtt-1.3'.
  # Both packages 'libpaho-mqtt-1.3' and 'iotech-libpaho-mqtt-1.3' share some files, therefore remove 'libpaho-mqtt-1.3'
  # to ensure the new agent satisfies its dependencies
  if dpkg -s libpaho-mqtt-1.3 | grep -qw Status.*installed ;then
      log "Removing libpaho-mqtt-1.3" >&3
      sudo apt remove -y libpaho-mqtt-1.3
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq $APT_UPDATE_OPTS
  apt-get install -y -qq wget ca-certificates curl gnupg lsb-release gettext-base

  show_progress 5

  DIST_NAME=$(get_dist_name "$DIST")
  DIST_NUM=$(get_dist_num "$DIST")
  DIST_TYPE=$(get_dist_type "$DIST")
  DIST_ARCH=$(get_dist_arch "$ARCH")

  show_progress 10
  check_docker_and_compose

  PACKAGE_DIR=""
  if [ -n "$SERVER_URL" ]; then
    download_server_packages "$DIST_NAME" "$DIST_ARCH"
  elif [ -n "$LOCAL_DIR" ]; then
    PACKAGE_DIR="$LOCAL_DIR"
    verify_package_dir "$PACKAGE_DIR"
    NODE_DEB=$(cd "$PACKAGE_DIR" && ls edgemanager-node-*.deb 2>/dev/null | head -1)
    if [ -z "$NODE_DEB" ]; then
      log "No edgemanager-node package in $PACKAGE_DIR" >&3
      exit 1
    fi
    NODE_VER=$(echo "$NODE_DEB" | sed 's/^edgemanager-node-\(.*\)_[^_]*\.deb$/\1/')
    log "Installing node packages ($NODE_VER) from $PACKAGE_DIR" >&3
  else
    # Setting up repos to access iotech packages
    setup_iotech_apt_key
    if [ "$REPOAUTH" != "" ]; then
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev $DIST_NAME main" | sudo tee /etc/apt/sources.list.d/em-iotech.list
    else
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://iotech.jfrog.io/artifactory/debian-release $DIST_NAME main" | sudo tee /etc/apt/sources.list.d/em-iotech.list
    fi
  fi
  if [ -n "$PACKAGE_DIR" ]; then
    check_node_dependencies "$PACKAGE_DIR/$NODE_DEB"
  fi

  show_progress 28

  unhold_package_updates_deb "edgemanager-node"

  # check if using local file for dev purposes
  echo "FILE = ${FILE}"
  if [ -n "$PACKAGE_DIR" ]; then
    # Dependencies were checked above, so no package source lookup is needed
    apt-get install -y "$PACKAGE_DIR"/*.deb
  else
    apt-get update -qq
    if test -f "$FILE" ; then
      apt-get install -y "$FILE"
    else
      apt-get install -y -qq edgemanager-node="$VER"
    fi
  fi

  show_progress 28

  USER=$(logname 2>/dev/null || true)
  if [ -n "$USER" ] && [ "$USER" != "root" ]; then
    if ! grep -q "$USER     ALL=(ALL) NOPASSWD:ALL" /etc/sudoers ;then
      echo "$USER     ALL=(ALL) NOPASSWD:ALL" | sudo EDITOR='tee -a' visudo
    fi
    usermod -aG docker "$USER"
  fi

  # Load alpine docker image
  docker load -i /opt/edgebuilder/node/alpine_3_19_1.tar

  show_progress 40

  # enable em-node service for offline node provision
  if [ "$OFFLINE_PROVISION" = true ]; then
    systemctl enable --now em-node.service
  fi

  log "Validating installation" >&3
  OUTPUT=$(em-node)
  if [ "$OUTPUT" = "" ]; then
    log "Node installation could not be validated" >&3
  else
    log "Node validation succeeded" >&3
    # Mark these packages as the most recently used, and keep only them and the previous version
    if [ "$PACKAGE_DIR" = "$NODE_PACKAGES_DIR/${PACKAGE_DIR##*/}" ]; then
      touch "$PACKAGE_DIR"
      prune_package_cache
    fi
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
      PKG_VER=$(dpkg -s edgemanager-cli | grep -i version)
      show_progress 40
      log "CLI ($PKG_VER) already installed, exiting"  >&3
      exit 0
    fi
  fi
   show_progress 2

  if version_under_2_6_32; then
    show_progress 40
    log "Kernel version $(uname -r), requires 2.6.32 or above"  >&3
    exit 1
  fi
  show_progress 5
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wget ca-certificates curl gnupg lsb-release
  show_progress 15
  # check if using local file for dev purposes; skip repo setup if so, the install block below handles it
  if ! test -f "$FILE" ; then
    setup_iotech_apt_key
    if [ "$REPOAUTH" != "" ]; then
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://$REPOAUTH@iotech.jfrog.io/artifactory/debian-dev all main" | sudo tee /etc/apt/sources.list.d/em-iotech-cli.list
    else
      echo "deb [signed-by=$KEYRINGS_DIR/iotech.gpg] https://iotech.jfrog.io/artifactory/debian-release all main" | sudo tee /etc/apt/sources.list.d/em-iotech-cli.list
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

  if version_under_2_6_32; then
    log "Kernel version $(uname -r), requires 2.6.32 or above" >&3
    show_progress 40
    exit 1
  fi

  if [ "$REPOAUTH" != "" ]; then
    if ! grep -q "$RPM_DEV_REPO_DATA" /etc/yum.repos.d/em-iotech-cli.repo ;then
      echo "$RPM_DEV_REPO_DATA" | sudo tee -a /etc/yum.repos.d/em-iotech-cli.repo
    fi
  else
    if ! grep -q "$RPM_REPO_DATA" /etc/yum.repos.d/em-iotech-cli.repo ;then
      echo "$RPM_REPO_DATA" | sudo tee -a /etc/yum.repos.d/em-iotech-cli.repo
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
        em-server down -rv
        unhold_package_updates_deb "edgemanager-server"
        # attempt purge
        sudo apt-get -qq purge edgemanager-server -y
        show_progress 40
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
      systemctl disable --now em-node.service
      unhold_package_updates_deb "edgemanager-node"
      show_progress 40
      apt-get -qq purge edgemanager-node iotech-builderd-* -y
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
          unhold_package_updates_deb "edgemanager-cli"
          sudo apt-get -qq purge edgemanager-cli -y
          show_progress 40
          if (dpkg --list edgemanager-cli) ; then
              log "Failed to uninstall CLI" >&3
              exit 1
          else
              log "CLI Successfully Uninstalled" >&3
              exit 0
          fi
      else
          show_progress 40
          # package not currently installed, so exit
          log "CLI NOT currently installed" >&3
          exit 0
      fi
}

# Displays simple usage prompt
display_usage()
{
  echo "Usage: edgemanager-install.sh [param] [options]" >&3
  echo "params: server, node, cli" >&3
  echo "options: " >&3
  echo "     -r, --repo-auth          : IoTech repo auth token to access packages" >&3
  echo "     -u, --uninstall          : Uninstall the package" >&3
  echo "     -f, --file               : Absolute path to local package" >&3
  echo "     --offline-provision      : Enable offline node provision" >&3
  echo "     --install-docker         : Install docker as part of package install" >&3
  echo "     -y, --yes                : Automatically proceed without interactive prompts" >&3
  echo "     --server <url>           : (node) Install the packages from an Edge Manager server's node-components" >&3
  echo "                                bundle, e.g. https://<server>/node-components, instead of the IoTech repo" >&3
  echo "     --sums-sha256 <sha>      : (node) Expected sha256 of the server's SHA256SUMS package list" >&3
  echo "     --download-only          : (node) With --server, download and verify the packages without installing" >&3
  echo "     --local-dir <dir>        : (node) Install the packages from a local directory, e.g. a cached version" >&3
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
        -y | --yes)
            FORCE_YES=true
            shift
            ;;
        --server)
            SERVER_URL="${2%/}"
            shift
            shift
            ;;
        --sums-sha256)
            SUMS_SHA256="$2"
            shift
            shift
            ;;
        --download-only)
            DOWNLOAD_ONLY=true
            shift
            ;;
        --local-dir)
            LOCAL_DIR="${2%/}"
            shift
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

# Check compatibility
log "Checking compatibility"  >&3
if [ "$COMPONENT" = "server" ];then
  if "$UNINSTALL"; then
      uninstall_server
  fi

  if [ "$ARCH" = "x86_64" ]||[ "$ARCH" = "aarch64" ];then
    if [ "$OS" = "$UBUNTU2204" ]||[ "$OS" = "$UBUNTU2404" ]||[ "$OS" = "$UBUNTU2604" ]||[ "$OS" = "$DEBIAN13" ]||[ "$OS" = "$DEBIAN12" ];then
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
    if [ "$OS" = "$UBUNTU2204" ]||[ "$OS" = "$UBUNTU2404" ]||[ "$OS" = "$UBUNTU2604" ]||[ "$OS" = "$DEBIAN13" ]||[ "$OS" = "$DEBIAN12" ];then
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
