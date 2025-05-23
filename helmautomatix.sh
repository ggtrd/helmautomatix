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



# Get now datetime
# Usage: now
now() {
	date +%y-%m-%d_%H-%M-%S
}


now="$(now)"
name="$(echo $0 | sed 's|./||' | sed 's|.sh||')"

dir_updates="updates"
dir_updates_now="$dir_updates/updates_$now"
mkdir -p $dir_updates_now

dir_tmp="/tmp/$name"
mkdir -p $dir_tmp
chmod -R 770 $dir_tmp

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


# Log general message
# Usage: log <message>
log() {
	echo "$(now) $0: $1"
}


# Log error message
# Usage: log_error <message>
log_error() {
	log "error: $1"
}



# Log error message
# Usage: log_error <message>
log_info() {
	log " info: $1"
}




# Delete /tmp/$0 directory created at begin
# Usage: delete_tmp
delete_tmp() {
	rm -rf $dir_tmp
}



# Stop script if missing dependency
required_commands="jq yq helm kubectl"
file_tmp_required_commands="$dir_tmp/required_commands"
for command in $required_commands; do
	if [ -z "$(which $command)" ]; then
		log_error "'$command' not found but required."
		echo $command >> $file_tmp_required_commands
		# exit
	fi
done
if [ -s $file_tmp_required_commands ]; then
	log_error "missing required command(s), exiting."
	delete_tmp
	exit
fi



# Create a JSON array containing instaleld Helm Charts informations
# Usage: json_chart $namespace $installed_name $remote_image_shortened $remote_image $installed_version $remote_version "true/false"
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


# List Helm Charts available updates
# Usage: list_updates
list_updates() {
	local namespaces="$(kubectl get namespaces -o json | jq -c '.items[].metadata.name' | tr -d \")"
	for namespace in $namespaces; do
		log_info "jumping to namespace '$namespace'"

		local deployments="$(helm --namespace $namespace list --deployed -o json | jq -c '.[] | {name,app_version}')"
		# deployments="$(helm list --deployed --all-namespaces -o json | jq -c '.[] | {name,app_version}')"

		if [ -z "$deployments" ]; then
			log_info "no chart found on '$namespace'"
		else 
			for deployment in $deployments; do

				log_info "checking deployment '$deployment'"

				local installed_name="$(echo "$deployment" | jq -c '.name' | sed 's|"\(.*\)"|\1|')"
				local installed_version="$(echo "$deployment" | jq -c '.app_version' | sed 's|"\(.*\)"|\1|')"
				local installed_status="$(helm --namespace $namespace status $installed_name | grep STATUS | sed 's|.*: ||')"

				local remote_image="$(helm --namespace $namespace get manifest $installed_name | grep image: | head -n 1 | sed 's|.*: ||' | tr -d \")"

				# Trick to get the repo name configured in "helm repo list" from the URL given in charts metadata
				# The purpose is to match repo name and url because the name can be differents (for example name = "cosmotech" and url contains "cosmo-tech")
				local configured_repo_url="$(echo $remote_image | cut -d '/' -f 2)"

				# Todo: this list is currently the local list of the computer, it must be a list created from metadata charts to ensure having all the repos
				local configured_repo_name="$(helm --namespace $namespace repo list -o json | jq -c '.[]' | grep $configured_repo_url | jq -c '.name' | tr -d \")"

				if [ -z $configured_repo_name ]; then
					log_error "helm repository not found on the system for chart '$installed_name', please verify with the following commands:"
					log_info "look for the chart repository:   helm --namespace $namespace get metadata $installed_name"
					log_info "ensure the repository is listed: helm repo list"
					break
				fi

				local remote_image_shortened="$(echo $configured_repo_name/$(echo $remote_image | sed 's|.*/\(.*\):.*|\1|'))"
				local remote_version="$(helm --namespace $namespace show chart $remote_image_shortened | grep appVersion | sed 's|.*: ||')"

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

		fi
	done

	cat $file_updates_now_json
}


# Update all Helm Charts
# Usage: update_charts
update_charts() {

	list_updates > /dev/null

	# local updatable_charts="$(cat $file_updates_now_json | jq -c '.charts[] | select(.updatable == "true").name')"
	local updatable_charts="$(cat $file_updates_now_json | jq -c '.charts[] | select(.updatable == "true")')"
	for chart in $updatable_charts; do

		local chart_name="$(echo $chart | jq '.name' | tr -d \")"

		# Deployed (=on cluster)
		local file_tmp_chart_pairs_deployed="$dir_updates_now/pairs_deployed_$chart_name.yml"
		helm get values $chart_name -o json > $file_tmp_chart_pairs_deployed                               # Get the YAML keys/values of the current deployed chart and store it as JSON
		if [ -f $file_tmp_chart_pairs_deployed ]; then     # Ensure the tmp file containing values exists, if not it means no values are specified
			local pairs_deployed="$(cat $file_tmp_chart_pairs_deployed | yq)"                              # Get keys/values pairs of the chart
			# local keys_deployed="$(echo $pairs_deployed | jq -r '. | keys[]')"                             # Get the keys names only to be able to compare them with the new remote chart version
			local keys_deployed="$(echo $pairs_deployed | jq -r --stream 'select(has(1)) | ".\(first | join(".")) = \(last | @json)"' | sed 's| =.*||')"                             # Get the keys names only to be able to compare them with the new remote chart version

			

		fi

		# Remote (=repository)
		local file_tmp_chart_pairs_remote="$dir_tmp/pairs_remote_$chart_name.yml"
		helm show values bitnami/wordpress > $file_tmp_chart_pairs_remote                                  # Get the new available values of the Chart to be able to ensure that the current values are still compatibles
		if [ -f $file_tmp_chart_pairs_remote ]; then         # Ensure the tmp file containing values exists, if not it means no values are specified
			local pairs_remote="$(cat $file_tmp_chart_pairs_remote | yq)"                                  # Get keys/values pairs of the chart
			# local keys_remote="$(echo $pairs_remote | jq -r '. | keys[]')"                                 # Get the keys names only to be able to compare them with the new deployed chart version
			local keys_remote="$(echo $pairs_deployed | jq -r --stream 'select(has(1)) | ".\(first | join(".")) = \(last | @json)"' | sed 's| =.*||')"                             # Get the keys names only to be able to compare them with the new remote chart version
		fi

		
		# echo -n "chart             " $chart_name
		# # echo -n "pairs_deployed    " $pairs_deployed
		# echo -n "keys_deployed     " $keys_deployed
		# # echo -n "pairs_remote      " $pairs_remote
		# echo -n "keys_remote       " $keys_remote

		if [ ! -z "$(echo $keys_remote)" ] && [ ! -z "$(echo $keys_deployed)" ]; then
			for key_remote in $keys_remote; do
				for key_deployed in $keys_deployed; do
					if [ "$(echo $key_remote)" = "$(echo $key_deployed)" ]; then
						echo $key_remote
						echo $key_deployed

						# cat $file_tmp_chart_pairs_remote | grep $key_remote
					fi
				done
			done
		fi


		# # Ensure the key list is not empty
		# if [ ! -z "$(echo $keys)" ]; then
		# 	for key in $keys; do

		# 		# Here use yq and not jq since the remotes pairs are in YAML and not JSON
		# 		local values="$(cat $file_tmp_chart_pairs_remote | yq ".$key")"
		# 	done
		# fi


		# Ensure the current configured pairs are still compatible with the new chart version, or give up the update
		#helm show values $short | yq '.'


	done
	
}


# Help message
# Usage: display_help
display_help() {
	echo "Usage: $0 [OPTION]..." \
	&&	echo "" \
	&&	echo "Options:" \
	&&	echo " -l, --list-updates        list available Helm Charts updates." \
	&&	echo " -u, --do-update           update Helm Charts." 
}





# The options (except --help) must be called with root
case "$1" in
	-l|--list-updates)		list_updates ;;
	-u|--do-update)			update_charts ;;
	-h|--help|help)			display_help ;;
	*)
							if [ -z "$1" ]; then
								display_help
							else
								log_error "unknown option '$1', $0 --help"
							fi
esac





# todo:
# - mail notification for errors


# rm -rf $dir_tmp

exit
