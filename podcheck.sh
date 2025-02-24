#!/usr/bin/env bash
VERSION="v0.6.0"
# ChangeNotes: Rewrite of dependency installer. jq can now be installed via package manager or static binary.
Github="https://github.com/sudo-kraken/podcheck"
RawUrl="https://raw.githubusercontent.com/sudo-kraken/podcheck/main/podcheck.sh"

# Variables for self-updating
ScriptArgs=( "$@" )
ScriptPath="$(readlink -f "$0")"
ScriptWorkDir="$(dirname "$ScriptPath")"

# Check if there's a new release of the script
LatestRelease="$(curl -s -r 0-100 "$RawUrl" | sed -n "/VERSION/s/VERSION=//p" | tr -d '"')"
LatestChanges="$(curl -s -r 0-200 "$RawUrl" | sed -n "/ChangeNotes/s/# ChangeNotes: //p")"

# Help Function
Help() {
  echo "Syntax:     podcheck.sh [OPTION] [part of name to filter]"
  echo "Example:    podcheck.sh -y -d 10 -e nextcloud,heimdall"
  echo
  echo "Options:"
  echo "-a|y   Automatic updates, without interaction."
  echo "-c     Exports metrics as prom file for the prometheus node_exporter. Provide the collector textfile directory."
  echo "-d N   Only update to new images that are N+ days old. Lists too recent with +prefix and age."
  echo "-e X   Exclude containers, separated by comma."
  echo "-f     Force pod restart after update."
  echo "-h     Print this Help."
  echo "-i     Inform - send a preconfigured notification."
  echo "-l     Only update if label is set. See readme."
  echo "-m     Monochrome mode, no printf color codes."
  echo "-n     No updates; only checking availability."
  echo "-p     Auto-prune dangling images after update."
  echo "-r     Allow updating images for podman run; won't update the container."
  echo "-s     Include stopped containers in the check."
  echo "-t     Set a timeout (in seconds) per container for registry checkups, 10 is default."
  echo "-v     Prints current version."
  echo
  echo "Project source: $Github"
}

# Colors
c_red="\033[0;31m"
c_green="\033[0;32m"
c_yellow="\033[0;33m"
c_blue="\033[0;34m"
c_teal="\033[0;36m"
c_reset="\033[0m"

Timeout=10
Stopped=""

# Enhanced error handling
set -euo pipefail

while getopts "aynpfrhlisvmc:e:d:t:" options; do
  case "${options}" in
    a|y) AutoUp="yes" ;;
    c)   
      CollectorTextFileDirectory="${OPTARG}"
      if ! [[ -d $CollectorTextFileDirectory ]] ; then
        printf "The directory (%s) does not exist.\n" "${CollectorTextFileDirectory}"
        exit 2
      fi
      ;;
    n)   AutoUp="no" ;;
    r)   DRunUp="yes" ;;
    p)   AutoPrune="yes" ;;
    l)   OnlyLabel=true ;;
    f)   ForceRestartPods=true ;;
    i)   [ -s "$ScriptWorkDir/notify.sh" ] && { source "$ScriptWorkDir/notify.sh" ; Notify="yes" ; } ;;
    e)   Exclude=${OPTARG} ;;
    m)   declare c_{red,green,yellow,blue,teal,reset}="" ;;
    s)   Stopped="-a" ;;
    t)   Timeout="${OPTARG}" ;;
    v)   printf "%s\n" "$VERSION" ; exit 0 ;;
    d)   DaysOld=${OPTARG}
         if ! [[ $DaysOld =~ ^[0-9]+$ ]] ; then
           printf "Days -d argument given (%s) is not a number.\n" "${DaysOld}"
           exit 2
         fi
         ;;
    h|*) Help ; exit 2 ;;
  esac
done
shift "$((OPTIND-1))"

# Self-update functions
self_update_curl() {
  cp "$ScriptPath" "$ScriptPath".bak
  if command -v curl &>/dev/null; then
    curl -L "$RawUrl" > "$ScriptPath"
    chmod +x "$ScriptPath"
    printf "\n%s\n" "--- starting over with the updated version ---"
    exec "$ScriptPath" "${ScriptArgs[@]}"
    exit 1
  elif command -v wget &>/dev/null; then
    wget "$RawUrl" -O "$ScriptPath"
    chmod +x "$ScriptPath"
    printf "\n%s\n" "--- starting over with the updated version ---"
    exec "$ScriptPath" "${ScriptArgs[@]}"
    exit 1
  else
    printf "curl/wget not available - download the update manually: %s \n" "$Github"
  fi
}

self_update() {
  cd "$ScriptWorkDir" || { printf "Path error, skipping update.\n" ; return ; }
  if command -v git &>/dev/null && [[ "$(git ls-remote --get-url 2>/dev/null)" =~ .*"sudo-kraken/podcheck".* ]]; then
    printf "\n%s\n" "Pulling the latest version."
    git pull --force || { printf "Git error, manually pull/clone.\n" ; return ; }
    printf "\n%s\n" "--- starting over with the updated version ---"
    cd - || { printf "Path error.\n" ; return ; }
    exec "$ScriptPath" "${ScriptArgs[@]}"
    exit 1
  else
    cd - || { printf "Path error.\n" ; return ; }
    self_update_curl
  fi
}

# Choose from list function
choosecontainers() {
  while [[ -z "${ChoiceClean:-}" ]]; do
    read -r -p "Enter number(s) separated by comma, [a] for all - [q] to quit: " Choice
    if [[ "$Choice" =~ [qQnN] ]]; then
      exit 0
    elif [[ "$Choice" =~ [aAyY] ]]; then
      SelectedUpdates=( "${GotUpdates[@]}" )
      ChoiceClean=${Choice//[,.:;]/ }
    else
      ChoiceClean=${Choice//[,.:;]/ }
      for CC in $ChoiceClean; do
        if [[ "$CC" -lt 1 || "$CC" -gt $UpdCount ]]; then
          echo "Number not in list: $CC"
          unset ChoiceClean
          break 1
        else
          SelectedUpdates+=( "${GotUpdates[$CC-1]}" )
        fi
      done
    fi
  done
  printf "\nUpdating containers:\n"
  printf "%s\n" "${SelectedUpdates[@]}"
  printf "\n"
}

datecheck() {
  ImageDate=$($regbin -v error image inspect "$RepoUrl" --format='{{.Created}}' | cut -d" " -f1)
  ImageAge=$(( ( $(date +%s) - $(date -d "$ImageDate" +%s) ) / 86400 ))
  if [ "$ImageAge" -gt "$DaysOld" ]; then
    return 0
  else
    return 1
  fi
}

progress_bar() {
  QueCurrent="$1"
  QueTotal="$2"
  ((Percent=100*QueCurrent/QueTotal))
  ((Complete=50*Percent/100))
  ((Left=50-Complete))
  BarComplete=$(printf "%${Complete}s" | tr " " "#")
  BarLeft=$(printf "%${Left}s" | tr " " "-")
  if [[ "$QueTotal" != "$QueCurrent" ]]; then
    printf "\r[%s%s] %s/%s " "$BarComplete" "$BarLeft" "$QueCurrent" "$QueTotal"
  else
    printf "\r[%b%s%b] %s/%s \n" "$c_teal" "$BarComplete" "$c_reset" "$QueCurrent" "$QueTotal"
  fi
}

# Static binary downloader for dependencies
binary_downloader() {
  BinaryName="$1"
  BinaryUrl="$2"
  case "$(uname --machine)" in
    x86_64|amd64) architecture="amd64" ;;
    arm64|aarch64) architecture="arm64" ;;
    *) printf "\n%bArchitecture not supported, exiting.%b\n" "$c_red" "$c_reset" ; exit 1 ;;
  esac
  GetUrl="${BinaryUrl/TEMP/"$architecture"}"
  if command -v curl &>/dev/null; then
    curl -L "$GetUrl" > "$ScriptWorkDir/$BinaryName"
  elif command -v wget &>/dev/null; then
    wget "$GetUrl" -O "$ScriptWorkDir/$BinaryName"
  else
    printf "%s\n" "curl/wget not available - get $BinaryName manually from the repo link, exiting."
    exit 1
  fi
  [[ -f "$ScriptWorkDir/$BinaryName" ]] && chmod +x "$ScriptWorkDir/$BinaryName"
}

distro_checker() {
  if [[ -f /etc/arch-release ]]; then
    PkgInstaller="pacman -S"
  elif [[ -f /etc/redhat-release ]]; then
    PkgInstaller="dnf install"
  elif [[ -f /etc/SuSE-release ]]; then
    PkgInstaller="zypper install"
  elif [[ -f /etc/debian_version ]]; then
    PkgInstaller="apt-get install"
  else
    PkgInstaller="ERROR"
    printf "\n%bNo distribution could be determined%b, falling back to static binary.\n" "$c_yellow" "$c_reset"
  fi
}

# Version check & initiate self update
if [[ "$VERSION" != "$LatestRelease" ]] && [[ -n "$LatestRelease" ]]; then
  printf "New version available! %b%s%b ⇒ %b%s%b \n Change Notes: %s \n" "$c_yellow" "$VERSION" "$c_reset" "$c_green" "$LatestRelease" "$c_reset" "$LatestChanges"
  if [[ -z "${AutoUp:-}" ]]; then
    read -r -p "Would you like to update? y/[n]: " SelfUpdate
    [[ "$SelfUpdate" =~ [yY] ]] && self_update
  fi
fi

# Set $1 to a variable for name filtering later
SearchName="$1"
# Create array of excludes
IFS=',' read -r -a Excludes <<< "$Exclude"; unset IFS

# Dependency check for jq in PATH or directory
if command -v jq &>/dev/null; then
  jqbin="jq"
elif [[ -f "$ScriptWorkDir/jq" ]]; then
  jqbin="$ScriptWorkDir/jq"
else
  printf "%s\n" "Required dependency 'jq' missing, do you want to install it?"
  read -r -p "y: With packagemanager (sudo). / s: Download static binary. y/s/[n] " GetJq
  GetJq=${GetJq:-no}
  if [[ "$GetJq" =~ [yYsS] ]]; then
    [[ "$GetJq" =~ [yY] ]] && distro_checker
    if [[ -n "$PkgInstaller" && "$PkgInstaller" != "ERROR" ]]; then 
      (sudo $PkgInstaller jq)
      PkgExitcode="$?"
      [[ "$PkgExitcode" == 0 ]] && jqbin="jq" || printf "\n%bPackagemanager install failed%b, falling back to static binary.\n" "$c_yellow" "$c_reset"
    fi
    if [[ "$GetJq" =~ [nN] || "$PkgInstaller" == "ERROR" || "$PkgExitcode" != 0 ]]; then
      binary_downloader "jq" "https://github.com/jqlang/jq/releases/latest/download/jq-linux-TEMP"
      [[ -f "$ScriptWorkDir/jq" ]] && jqbin="$ScriptWorkDir/jq"
    fi
  else
    printf "\n%bDependency missing, exiting.%b\n" "$c_red" "$c_reset"
    exit 1
  fi
fi

# Final check if binary is correct
$jqbin --version &>/dev/null || { printf "%s\n" "jq is not working - try to remove it and re-download it, exiting."; exit 1; }

# Dependency check for regctl in PATH or directory
if command -v regctl &>/dev/null; then
  regbin="regctl"
elif [[ -f "$ScriptWorkDir/regctl" ]]; then
  regbin="$ScriptWorkDir/regctl"
else
  read -r -p "Required dependency 'regctl' missing, do you want it downloaded? y/[n] " GetRegctl
  if [[ "$GetRegctl" =~ [yY] ]]; then
    binary_downloader "regctl" "https://github.com/regclient/regclient/releases/latest/download/regctl-linux-TEMP"
    [[ -f "$ScriptWorkDir/regctl" ]] && regbin="$ScriptWorkDir/regctl"
  else
    printf "\n%bDependency missing, exiting.%b\n" "$c_red" "$c_reset"
    exit 1
  fi
fi

# Final check if binary is correct
$regbin version &>/dev/null || { printf "%s\n" "regctl is not working - try to remove it and re-download it, exiting."; exit 1; }

# Check podman compose binary
if podman compose version &>/dev/null; then
  PodmanComposeBin="podman compose"
elif command -v podman-compose &>/dev/null; then
  PodmanComposeBin="podman-compose"
elif podman version &>/dev/null; then
  printf "%s\n" "No podman-compose binary available, using plain podman"
else
  printf "%s\n" "No podman binaries available, exiting."
  exit 1
fi

# Numbered List function
options() {
  num=1
  for i in "${GotUpdates[@]}"; do
    echo "$num) $i"
    ((num++))
  done
}

# Listing typed exclusions
if [[ -n "${Excludes[*]}" ]]; then
  printf "\n%bExcluding these names:%b\n" "$c_blue" "$c_reset"
  printf "%s\n" "${Excludes[@]}"
  printf "\n"
fi

# Variables for progress_bar function
ContCount=$(podman ps $Stopped --filter "name=$SearchName" --format '{{.Names}}' | wc -l)
RegCheckQue=0

# Record start time before checking containers
start_time=$(date +%s)

# Check the image-hash of every running container VS the registry
for i in $(podman ps $Stopped --filter "name=$SearchName" --format '{{.Names}}'); do
  ((RegCheckQue+=1))
  progress_bar "$RegCheckQue" "$ContCount"
  
  # Loop over the list of excluded names and skip if a match is found
  for e in "${Excludes[@]}"; do 
    [[ "$i" == "$e" ]] && continue 2
  done
  
  ImageId=$(podman inspect "$i" --format='{{.Image}}')
  RepoUrl=$(podman inspect "$i" --format='{{.ImageName}}')
  LocalHash=$(podman image inspect "$ImageId" --format '{{.RepoDigests}}')
  
  # Checking for errors while setting the variable
  if RegHash=$(${t_out} $regbin -v error image digest --list "$RepoUrl" 2>&1); then
    if [[ "$LocalHash" == *"$RegHash"* ]]; then
      NoUpdates+=("$i")
    else
      if [[ -n "$DaysOld" ]] && ! datecheck; then
        NoUpdates+=("+$i ${ImageAge}d")
      else
        GotUpdates+=("$i")
      fi
    fi
  else
    # Here the RegHash is the result of an error code
    GotErrors+=("$i - ${RegHash}")
  fi
done

# Sort arrays alphabetically
IFS=$'\n'
NoUpdates=($(sort <<<"${NoUpdates[*]}"))
GotUpdates=($(sort <<<"${GotUpdates[*]}"))
unset IFS

# Run the Prometheus exporter function if a collector directory is provided
if [ -n "$CollectorTextFileDirectory" ]; then
  end_time=$(date +%s)
  check_duration=$(( end_time - start_time ))
  source "$ScriptWorkDir/addons/prometheus/prometheus_collector.sh" && \
    prometheus_exporter "${#NoUpdates[@]}" "${#GotUpdates[@]}" "${#GotErrors[@]}" "$ContCount" "$check_duration"
fi

# Define how many updates are available
UpdCount="${#GotUpdates[@]}"

# List what containers got updates or not
if [[ -n "${NoUpdates[*]}" ]]; then
  printf "\n%bContainers on latest version:%b\n" "$c_green" "$c_reset"
  printf "%s\n" "${NoUpdates[@]}"
fi
if [[ -n "${GotErrors[*]}" ]]; then
  printf "\n%bContainers with errors; won't get updated:%b\n" "$c_red" "$c_reset"
  printf "%s\n" "${GotErrors[@]}"
  printf "%binfo:%b 'unauthorized' often means not found in a public registry.\n" "$c_blue" "$c_reset"
fi
if [[ -n "${GotUpdates[*]}" ]]; then
  printf "\n%bContainers with updates available:%b\n" "$c_yellow" "$c_reset"
  [[ -z "$AutoUp" ]] && options || printf "%s\n" "${GotUpdates[@]}"
  [[ -n "$Notify" ]] && { [[ $(type -t send_notification) == function ]] && send_notification "${GotUpdates[@]}" || printf "Could not source notification function.\n"; }
fi

# Optionally get updates if there's any
if [ -n "$GotUpdates" ]; then
  if [ -z "$AutoUp" ]; then
    printf "\n%bChoose what containers to update.%b\n" "$c_teal" "$c_reset"
    choosecontainers
  else
    SelectedUpdates=( "${GotUpdates[@]}" )
  fi
  if [ "$AutoUp" == "${AutoUp#[Nn]}" ]; then
    NumberofUpdates="${#SelectedUpdates[@]}"
    CurrentQue=0
    for i in "${SelectedUpdates[@]}"; do
      ((CurrentQue+=1))
      unset CompleteConfs
      # Extract labels and metadata
      ContLabels=$(podman inspect "$i" --format '{{json .Config.Labels}}')
      ContImage=$(podman inspect "$i" --format='{{.ImageName}}')
      ContPath=$($jqbin -r '."com.docker.compose.project.working_dir"' <<< "$ContLabels")
      [ "$ContPath" == "null" ] && ContPath=""
      ContConfigFile=$($jqbin -r '."com.docker.compose.project.config_files"' <<< "$ContLabels")
      [ "$ContConfigFile" == "null" ] && ContConfigFile=""
      ContName=$($jqbin -r '."com.docker.compose.service"' <<< "$ContLabels")
      [ "$ContName" == "null" ] && ContName=""
      ContEnv=$($jqbin -r '."com.docker.compose.project.environment_file"' <<< "$ContLabels")
      [ "$ContEnv" == "null" ] && ContEnv=""
      ContUpdateLabel=$($jqbin -r '."sudo-kraken.podcheck.update"' <<< "$ContLabels")
      [ "$ContUpdateLabel" == "null" ] && ContUpdateLabel=""
      ContRestartStack=$($jqbin -r '."sudo-kraken.podcheck.restart-stack"' <<< "$ContLabels")
      [ "$ContRestartStack" == "null" ] && ContRestartStack=""
      
      # Checking if compose-values are empty - possibly started with podman run or managed by Quadlet
      if [ -z "$ContPath" ]; then
        # Try exact match first:
        if systemctl --user status "$i.service" &>/dev/null; then
          unit="$i.service"
        elif [ "$(id -u)" -eq 0 ] && systemctl status "$i.service" &>/dev/null; then
          unit="$i.service"
        else
          # Build a flexible regex pattern from the container name,
          # allowing underscores or hyphens interchangeably.
          pattern="^$(echo "$i" | sed 's/_/[_-]/g')\.service$"
          # List all user service units that match the pattern.
          candidates=$(systemctl --user list-units --type=service --no-legend | awk '{print $1}' | grep -iE "$pattern")
          if [ "$(echo "$candidates" | wc -l)" -eq 1 ]; then
            unit="$candidates"
          elif [ "$(echo "$candidates" | wc -l)" -gt 1 ]; then
            # If multiple candidates are found, attempt to choose the one that exactly matches (ignoring case).
            for cand in $candidates; do
              if [[ "${cand,,}" == "${i,,}.service" ]]; then
                unit="$cand"
                break
              fi
            done
            # If no exact match is found, default to the first candidate.
            if [ -z "${unit:-}" ]; then
              unit=$(echo "$candidates" | head -n 1)
            fi
          fi
        fi

        if [ -n "${unit:-}" ]; then
          echo "Detected Quadlet-managed container: $i (matched unit: $unit)"
          podman pull "$ContImage"
          # Attempt to restart in user scope first, then system scope if needed.
          if systemctl --user restart "$unit" &>/dev/null; then
            echo "Quadlet container $i updated and restarted (user scope)."
          elif [ "$(id -u)" -eq 0 ] && systemctl restart "$unit" &>/dev/null; then
            echo "Quadlet container $i updated and restarted (system scope)."
          else
            echo "Failed to restart unit $unit for container $i."
          fi
        else
          if [ "$DRunUp" == "yes" ]; then
            podman pull "$ContImage"
            printf "%s\n" "$i got a new image downloaded; rebuild manually with preferred 'podman run' parameters"
          else
            printf "\n%b%s%b has no compose labels or associated systemd unit; %bskipping%b\n\n" "$c_yellow" "$i" "$c_reset" "$c_yellow" "$c_reset"
          fi
        fi

        continue
      fi
      # cd to the compose-file directory to account for people who use relative volumes
      cd "$ContPath" || { echo "Path error - skipping $i" ; continue ; }
      # Reformatting path + multi compose
      if [[ $ContConfigFile = /* ]]; then
        CompleteConfs=$(for conf in ${ContConfigFile//,/ }; do printf -- "-f %s " "$conf"; done)
      else
        CompleteConfs=$(for conf in ${ContConfigFile//,/ }; do printf -- "-f %s/%s " "$ContPath" "$conf"; done)
      fi
      printf "\n%bNow updating (%s/%s): %b%s%b\n" "$c_teal" "$CurrentQue" "$NumberofUpdates" "$c_blue" "$i" "$c_reset"
      # Checking if Label Only option is set, and if container got the label
      [[ "$OnlyLabel" == true ]] && { [[ "$ContUpdateLabel" != "true" ]] && { echo "No update label, skipping." ; continue ; } }
      podman pull "$ContImage"
      # Check if the container got an environment file set and reformat it
      if [ -n "$ContEnv" ]; then
        ContEnvs=$(for env in ${ContEnv//,/ }; do printf -- "--env-file %s " "$env"; done)
      fi
      # Check if the whole pod should be restarted
      if [[ "$ContRestartStack" == "true" ]] || [[ "$ForceRestartPods" == true ]]; then
        $PodmanComposeBin ${CompleteConfs} down
        $PodmanComposeBin ${CompleteConfs} ${ContEnvs} up -d
      else
        $PodmanComposeBin ${CompleteConfs} ${ContEnvs} up -d ${ContName}
      fi
    done
    printf "\n%bAll done!%b\n" "$c_green" "$c_reset"
    if [[ -z "$AutoPrune" ]] && [[ -z "$AutoUp" ]]; then
      read -r -p "Would you like to prune dangling images? y/[n]: " AutoPrune
    fi
    [[ "$AutoPrune" =~ [yY] ]] && podman image prune -f
  else
    printf "\nNo updates installed, exiting.\n"
  fi
else
  printf "\nNo updates available, exiting.\n"
fi

exit 0
