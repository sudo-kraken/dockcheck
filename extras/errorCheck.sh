#!/usr/bin/env bash
# Usage: ./script.sh <SearchName>

SearchName="$1"

# Iterate over containers whose name contains the search term.
podman ps --filter "name=$SearchName" --format '{{.Names}}' | while read -r container; do
  echo "------------ $container ------------"
  
  # Retrieve container labels and image name.
  ContLabels=$(podman inspect "$container" --format '{{json .Config.Labels}}')
  ContImage=$(podman inspect "$container" --format '{{.ImageName}}')
  
  # Extract values from labels; if not set, default to an empty string.
  ContPath=$(jq -r '."com.docker.compose.project.working_dir"' <<< "$ContLabels")
  [ "$ContPath" == "null" ] && ContPath=""
  
  ContConfigFile=$(jq -r '."com.docker.compose.project.config_files"' <<< "$ContLabels")
  [ "$ContConfigFile" == "null" ] && ContConfigFile=""
  
  ContName=$(jq -r '."com.docker.compose.service"' <<< "$ContLabels")
  [ "$ContName" == "null" ] && ContName=""
  
  ContEnv=$(jq -r '."com.docker.compose.project.environment_file"' <<< "$ContLabels")
  [ "$ContEnv" == "null" ] && ContEnv=""
  
  ContUpdateLabel=$(jq -r '."sudo-kraken.podcheck.update"' <<< "$ContLabels")
  [ "$ContUpdateLabel" == "null" ] && ContUpdateLabel=""
  
  ContRestartStack=$(jq -r '."sudo-kraken.podcheck.restart-stack"' <<< "$ContLabels")
  [ "$ContRestartStack" == "null" ] && ContRestartStack=""
  
  # Determine the compose file location.
  if [[ $ContConfigFile = '/'* ]]; then
    ComposeFile="$ContConfigFile"
  else
    ComposeFile="$ContPath/$ContConfigFile"
  fi
  
  # Output the extracted details.
  echo -e "Service name:\t\t$ContName"
  echo -e "Project working dir:\t$ContPath"
  echo -e "Compose files:\t\t$ComposeFile"
  echo -e "Environment files:\t$ContEnv"
  echo -e "Container image:\t$ContImage"
  echo -e "Update label:\t\t$ContUpdateLabel"
  echo -e "Restart Stack label:\t$ContRestartStack"
  echo
  echo "Mounts:"
  
  # Display container mount points.
  podman inspect -f '{{ range .Mounts }}{{ .Source }}:{{ .Destination }}{{ "\n" }}{{ end }}' "$container"
  echo
done

