#!/bin/sh


# MIT License

# Copyright (c) 2025 Geoffrey Gontard

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.



# Uncomment for debug
# set -x



now="$(date +%y-%m-%d_%H-%M-%S)"

dir_updates="updates"
dir_updates_now="$dir_updates/updates_$now"
mkdir -p $dir_updates_now

file_updates_now_json="$dir_updates_now/updates_$now.json"
# jq -cn '{charts: $ARGS.named}' > $file_updates_now_json
jq -n --argjson charts "[]" '$ARGS.named' >$file_updates_now_json

# - Connect to Kubernetes cluster to be able to use kubectl and helm
# - list all installed charts with their version
# 	- for each installed chart, check if a new version exist on helm repository
# 		- if a new version exist:
#			- get current installed chart values in values-current-<chart_name>.yml
#			- get available new chart values in values-new-<chart_name>.yml
#			- merge values-current-<chart_name>.yml to values-new-<chart_name>.yml
#			- helm upgrade -f values-new-<chart_name>.yml <chart_name> <chart_url>
#				- ensure the deployment has worked
#					 - check pod/deployments status
#					 	- if success : end
#					 	- if fail :
#							- helm rollback
#							- mail notification of failure
#			- go next
#		- if none new version: end
#			- go next

# Refresh Helm repo before doing anything
# helm repo update




# Stop script if missing dependency
required_commands="jq helm kubectl"
for command in $required_commands; do
	if [ -z "$(which $command)" ]; then
		echo "$0: error: '$command' not found but required to run $0"
		exit
	fi
done





json_chart() {

	local namespace=$1
	local installed_name=$2
	local remote_image_shortened=$3
	local remote_image=$4
	local installed_version=$5
	local remote_version=$6
	local updatable=$7

	local file_tmp_item="$file_updates_now_json.item.tmp"
	local file_tmp_list="$file_updates_now_json.list.tmp"

	# WORKS
	# jq -n \
	# 	--arg name $installed_name \
	# 	--arg image $remote_image \
	# 	--arg short $remote_image_shortened \
	# 	--arg version_installed $installed_version \
	# 	--arg version_available $remote_version \
	# 	--arg updatable $updatable \
	# 	'$ARGS.named' >$file_tmp_item

	# jq -n --argjson chart "[]" \
	# 	"$(jq -n \
	# 		--arg name $installed_name \
	# 		--arg short $remote_image_shortened \
	# 		--arg image $remote_image \
	# 		--arg version_installed $installed_version \
	# 		--arg version_available $remote_version \
	# 		--arg updatable $updatable \
	# 		'$ARGS.named')" \
	# 	'$ARGS.named' >$file_tmp_item



	jq -n --argjson chart "[]" \
		"$(jq -n \
			--arg namespace $namespace \
			--arg name $installed_name \
			--arg short $remote_image_shortened \
			--arg image $remote_image \
			--arg version_installed $installed_version \
			--arg version_available $remote_version \
			--arg updatable $updatable \
			'$ARGS.named')" \
		'$ARGS.named' >$file_tmp_item



	# Create this JSON structure:
	# 	{
	#   "charts": [
	#     {
	#       "field": "value";
	#       "field": "value";
	#       "field": "value";
	#     },
	#     {
	#       "field": "value";
	#       "field": "value";
	#       "field": "value";
	#     },
	#     {
	#       "field": "value";
	#       "field": "value";
	#       "field": "value";
	#     },
	#   ]
	# }
	jq '.charts += $inputs' $file_updates_now_json --slurpfile inputs $file_tmp_item >$file_tmp_list
	cat $file_tmp_list >$file_updates_now_json
}

namespaces="$(kubectl get namespaces -o json | jq -c '.items[].metadata.name' | tr -d \")"
for namespace in $namespaces; do
	echo "Jumping to namespace $namespace"

	deployments="$(helm --namespace $namespace list --deployed -o json | jq -c '.[] | {name,app_version}')"
	# deployments="$(helm list --deployed --all-namespaces -o json | jq -c '.[] | {name,app_version}')"
	for deployment in $deployments; do
		echo "Checking deployment $deployment"

		installed_name="$(echo "$deployment" | jq -c '.name' | sed 's|"\(.*\)"|\1|')"
		installed_version="$(echo "$deployment" | jq -c '.app_version' | sed 's|"\(.*\)"|\1|')"
		installed_status="$(helm --namespace $namespace status $installed_name | grep STATUS | sed 's|.*: ||')"

		remote_image="$(helm --namespace $namespace get manifest $installed_name | grep image: | head -n 1 | sed 's|.*: ||' | tr -d \")"

		# Trick to get the repo name configured in "helm repo list" from the URL given in charts metadata
		# The purpose is to match repo name and url because the name can be differents (for example name = "cosmotech" and url contains "cosmo-tech")
		configured_repo_url="$(echo $remote_image | cut -d '/' -f 2)"

		# Todo: this list is currently the local list of the computer, it must be a list created from metadata charts to ensure having all the repos
		configured_repo_name="$(helm --namespace $namespace repo list -o json | jq -c '.[]' | grep $configured_repo_url | jq -c '.name' | tr -d \")"

		remote_image_shortened="$(echo $configured_repo_name/$(echo $remote_image | sed 's|.*/\(.*\):.*|\1|'))"
		remote_version="$(helm --namespace $namespace show chart $remote_image_shortened | grep appVersion | sed 's|.*: ||')"

		# # Debug comment/uncomment
		# echo "installed_name         $installed_name"
		# echo "installed_version      $installed_version"
		# echo "installed_status       $installed_status"
		# echo "remote_image           $remote_image"
		# echo "configured_repo_url    $configured_repo_url"
		# echo "configured_repo_name   $configured_repo_name"
		# echo "remote_image_shortened $remote_image_shortened"
		# echo "remote_version         $remote_version"

		if [ "$(echo "$installed_version")" != "$(echo "$remote_version")" ]; then
			json_chart $namespace $installed_name $remote_image_shortened $remote_image $installed_version $remote_version "true"
		else
			json_chart $namespace $installed_name $remote_image_shortened $remote_image $installed_version $remote_version "up-to-date"
		fi
	done
done

cat $file_updates_now_json

# todo:
# - ensure installed: jq, helm, kubectl
# - mail notification for errors

rm *.tmp

exit
