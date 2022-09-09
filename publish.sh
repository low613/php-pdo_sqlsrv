#!/bin/bash
# Publishes a deb package to our aptly repositories in AWS S3
# 1. Uploads DEB package to our aptly server
# 2. Adds DEB package to a local repo in aptly server
# 3. Creates snapshot from local repo
# 4. Publishes snapshot to S3

# Global const
readonly API_URL='http://aptly.service.consul:8080/api'
readonly ARG_HELP_LONG="help"
readonly ARG_HELP_SHORT="h"
readonly ARG_PACKAGE="package"
readonly ARG_LOCAL_REPO="local-repo"
readonly ARG_PASSPHRASE="passphrase"

# Global vars
declare passphrase       # GPG key passphrase
declare package_file     # eg 'package-artifacts/schoolbox-synergetic_1.0.0-1_amd64.deb'
declare package_name_ver # eg 'schoolbox-synergetic_1.0.0-1'
declare local_repo       # eg 'ubuntu-bionic'|'schoolbox-stable-bionic'|'schoolbox-unstable-bionic'
declare snapshot_name    # eg 'ubuntu-bionic-20220511'
declare prefix           # eg 's3:ubuntu'|'s3:schoolbox'
declare distribution     # eg 'stable'|'unstable','bionic'|'focal'

function print_help() {
  echo "Publishes debian package to apt repository"
  echo "Usage: $0 --$ARG_PACKAGE <package> --$ARG_LOCAL_REPO <local_repo>"
  echo "Args:"
  echo "  --$ARG_PASSPHRASE <passphrase>  Required. GPG key passphrase"
  echo "  --$ARG_PACKAGE <package>  Required. Path to the DEB package file"
  echo "  --$ARG_LOCAL_REPO <local_repo> Required. Aptly local repository to add DEB package to"
}

function parse_args() {
  local errors=0
  while [ $# -gt 0 ]; do
    case "$1" in
    -"$ARG_HELP_SHORT" | --"$ARG_HELP_LONG")
      print_help
      exit 0
      ;;
    --"$ARG_PASSPHRASE")
      passphrase=$2
      shift 2
      ;;
    --"$ARG_PACKAGE")
      package_file=$2
      package_name_ver="${2##*/}"
      shift 2
      ;;
    --"$ARG_LOCAL_REPO")
      local_repo=$2
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      errors=1
      shift
      ;;
    esac
  done
  if [[ $errors == '1' ]]; then
    print_help
    exit 1
  fi
}

# Validate CLI args
function validate_args() {
  local errors=0
  if [[ -z $passphrase ]]; then
    echo "You must declare the passphrase --$ARG_PASSPHRASE flag" >&2
    errors=1
  fi
  if [[ -z $package_file ]]; then
    echo "You must declare the package file you wish to publish using the --$ARG_PACKAGE flag" >&2
    errors=1
  elif [[ ! -f $package_file ]]; then
    echo "Package file '$package_file' not found" >&2
  elif [[ ! $package_file =~ ^.+\.deb$ ]]; then
    echo "Package file appears invalid. Expected '*.deb', found: '$package_file'" >&2
    errors=1
  fi
  if [[ -z $local_repo ]]; then
    echo "You must declare the local_repo you wish to add the package to using the --$ARG_LOCAL_REPO flag" >&2
    errors=1
  else
    # get local repos from API, ignoring the 'upstream' repo we use to cache 3rd party packages
    valid_local_repos=$(curl --silent "$API_URL"/repos | jq -r '.[].Name' | grep -v upstream | sort)
    if [[ ! "${valid_local_repos[*]}" =~ ${local_repo} ]]; then
      echo "Local repo '$local_repo' appears invalid. Valid local repos:" >&2
      echo -e "$valid_local_repos" >&2
      errors=1
    fi
  fi
  if [[ $errors == '1' ]]; then
    print_help
    exit 1
  fi
}

# Generates a snapshot name from local_repo name
function derive_snapshot_name(){
  snapshot_name="${local_repo}-$(date +%Y%m%d%H%M)"
}


# Derives publish prefix from local repo name. Checks that it exists.
function derive_publish_prefix(){
  # Assume that the publish prefix is the first element of the local repo name
  IFS='-' read -r -a my_array <<< "$local_repo"
  prefix="s3:${my_array[0]}"

  # Fetch publish endpoints, ignoring the 'upstream' repo we use to cache 3rd party packages, eg
  # s3:schoolbox
  # s3:ubuntu
  publish_list=$(curl --silent "${API_URL}/publish" | jq -r '.[].Storage' | sort | grep -v upstream | uniq)
  if [[ ! " ${publish_list[*]} " =~ ${prefix} ]]; then
    echo "Unable to derive publish prefix. Valid ($(echo -ne "${publish_list[*]}" |  tr '\n' ','))" >&2
    exit 1
  fi
}

# Derives publish distribution from local repo name. Check that it exits.
function derive_publish_distribution(){
  # Assume distribution is local repo name with first element removed
  IFS='-' read -r -a my_array <<< "$local_repo"
  distribution=$(echo "$local_repo" | sed -E "s/${my_array[0]}-//")

  # Fetch distributions for the published repo
  distributions=$(curl --silent "${API_URL}/publish" | jq -r ".[] | select(.Storage == \"$prefix\") | .Distribution")
  if [[ ! " ${distributions[*]} " =~ ${distribution} ]]; then
    echo "Unable to derive distribution. Found '$distribution', Valid ($(echo -ne "${distributions[*]}" |  tr '\n' ','))" >&2
    exit 1
  fi
}


function upload_package() {
  # 1. Upload package(s)
  #    https://www.aptly.info/doc/api/files/
  #    POST /api/files/:dir
  #
  # ["schoolbox_17.5.19-2/schoolbox_17.5.19-2_all.deb"]
  echo "Uploading package..." >&2
  if ! curl -X POST -F file=@"$package_file" "$API_URL/files/$package_name_ver"; then
    echo "Unable to upload package" >&2
    exit 1
  fi
  echo -e "\n" >&2
}

function add_package_to_local_repo() {
  # 2. Add package(s) to repo from uploaded file/directory
  #    https://www.aptly.info/doc/api/repos/
  #    POST /api/repos/:name/file/:dir
  #    POST /api/repos/:name/file/:dir/:file
  #
  # {"FailedFiles":[],"Report":{"Warnings":[],"Added":["schoolbox_17.5.19-2_all added"],"Removed":[]}}
  echo "Adding package to local repo..." >&2
  if ! curl -X POST "$API_URL/repos/$local_repo/file/$package_name_ver"; then
    echo "Unable to add package to local repo" >&2
    exit 1
  fi
  echo -e "\n" >&2
}


function create_snapshot_from_local_repo() {
  # 3. Create a snapshot of the repository
  #    https://www.aptly.info/doc/api/snapshots/
  #    POST /api/repos/:name/snapshots
  #
  # {"Name":"schoolbox-stable-2018-04-17T05:21:28+0000","CreatedAt":"2018-04-17T05:21:28.763393073Z","Description":"Snapshot from local repo [schoolbox-stable]","Origin":"","NotAutomatic":"","ButAutomaticUpgrades":""}
  echo "Creating snapshot '$snapshot_name' from local repo..." >&2
  if ! curl -X POST -H 'Content-Type: application/json' --data '{"Name":"'"$snapshot_name"'"}' "$API_URL/repos/$local_repo/snapshots"; then
    echo "Unable to create snapshot" >&2
    exit 1
  fi
  echo -e "\n" >&2
}


function publish_snapshot() {
  # 4. Switch published repository to the above snapshot
  #    https://www.aptly.info/doc/api/publish/
  #    PUT /api/publish/:prefix/:distribution
  #
  # {"Architectures":["amd64","i386"],"ButAutomaticUpgrades":"","Distribution":"stable","Label":"","NotAutomatic":"","Origin":"","Prefix":".","SkipContents":false,"SourceKind":"snapshot","Sources":[{"Component":"main","Name":"schoolbox-stable-2018-04-17T05:21:28+0000"}],"Storage":"s3:schoolbox-repo"}
  echo "Publishing repo" >&2
  if ! curl -X PUT -H 'Content-Type: application/json' --data '{"Signing": {"Passphrase": "'"$passphrase"'", "Batch": true},"Snapshots": [{"Component": "main", "Name": "'"$snapshot_name"'"}]}' "${API_URL}/publish/${prefix}:/$distribution"; then
    echo "Unable to publish snapshot" >&2
  fi
  echo -e "\n" >&2
}

function main() {
  parse_args "$@"
  validate_args
  derive_snapshot_name
  derive_publish_prefix
  derive_publish_distribution

  upload_package
  add_package_to_local_repo
  create_snapshot_from_local_repo
  publish_snapshot
}

main "$@"
