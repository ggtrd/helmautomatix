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

dir_deployments="deployments"
dir_deployments_now="$dir_deployments/$now"
mkdir -p $dir_deployments_now


dir_tmp="/tmp/$name"
mkdir -p $dir_tmp
chmod -R 770 $dir_tmp

dir_log="logs"
mkdir -p $dir_log
chmod -R 770 $dir_log
file_logs="$dir_log/$name.logs"

file_deployments_json="$dir_deployments_now/deployments.json"




# # Symoblic link to quickly browse the latest results
# path_deployment_latest="$dir_deployments/latest"
# rm -f $path_deployment_latest/
# ln -sf "$dir_deployments_now/*" "$path_deployment_latest/"




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
	echo "$(now) $0: $1" | tee -a $file_logs
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



# Get user a confirmation that accepts differents answers and returns always the same value
# Usage: sanitize_confirmation <yes|Yes|yEs|yeS|YEs|YeS|yES|YES|y|Y>
sanitize_confirmation() {
	if [ "$1" = "yes" ] || [ "$1" = "Yes" ] || [ "$1" = "yEs" ] || [ "$1" = "yeS" ] || [ "$1" = "YEs" ] || [ "$1" = "YeS" ] || [ "$1" = "yES" ] || [ "$1" = "YES" ] || [ "$1" = "y" ] || [ "$1" = "Y" ] || [ "$1" = "-y" ]; then
		echo "yes"
	fi
}



# Delete /tmp/$0 directory created at begin
# Usage: delete_tmp
delete_tmp() {
	rm -rf $dir_tmp
}



# Stop script if missing dependency
required_commands="jq yq helm kubectl curl"
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



# Simple hook to call before any registry usage
# Usage: hook_rate_registry
hook_rate_registry() {
	# Ensure the anonymous registry API rate limit is ok
	# Docker Hub official documentation: https://docs.docker.com/docker-hub/usage/pulls/#authentication
	# Usage: rate_registry
	rate_registry() {

		local token="$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)"

		local file_response_tmp="$dir_tmp/ratelimit"
		curl -s --head -H "Authorization: Bearer $token" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest -o $file_response_tmp

		local rate_limit="$(cat $file_response_tmp | grep 'ratelimit-limit' | sed 's|.*: ||' | sed 's|;.*||')"
		local rate_remaining="$(cat $file_response_tmp | grep 'ratelimit-remaining' | sed 's|.*: ||' | sed 's|;.*||')"
		local rate_source="$(cat $file_response_tmp | grep 'docker-ratelimit-source' | sed 's|.*: \([0-9.]*\).*|\1|')"

		# echo "token		         $token"
		# echo "response             $response"
		# echo "rate_limit           $rate_limit"
		# echo "rate_remaining       $rate_remaining"
		# echo "rate_source          $rate_source"

		local rate_percent="$(echo "scale=2; $rate_remaining*100/$rate_limit" | bc | cut -d . -f 1)"
		echo "$rate_percent;$rate_limit;$rate_remaining;$rate_source"
	}
	# Cancel script if current available rate is under 90% to avoid beeing blocked for next hours
	rate_registry=$(rate_registry)
	rate_percent=$(echo $rate_registry | cut -d ';' -f 1)
	rate_limit=$(echo $rate_registry | cut -d ';' -f 2)
	rate_remaining=$(echo $rate_registry | cut -d ';' -f 3)
	rate_source=$(echo $rate_registry | cut -d ';' -f 4)
	if [ $rate_percent -le 80 ]; then
		log_error "current available rate is $rate_percent% ($rate_remaining/$rate_limit) for $rate_source, aborting."
		exit
	fi
}



# Create a JSON array containing instaleld Helm Charts informations
# Usage: json_chart $namespace $installed_name $remote_image_reference $remote_image $installed_version $remote_version "true/false"
json_chart() {

	local namespace=$1
	local installed_name=$2
	local remote_image_reference=$3
	local remote_image=$4
	local installed_version=$5
	local remote_version=$6
	local uptodate=$7

	local file_tmp_item="$dir_tmp/deployment.item.tmp"
	local file_tmp_list="$dir_tmp/deployment.list.tmp"


	jq -n --argjson chart "[]" \
		"$(jq -n \
			--arg namespace $namespace \
			--arg name $installed_name \
			--arg reference $remote_image_reference \
			--arg image $remote_image \
			--arg version_installed $installed_version \
			--arg version_available $remote_version \
			--arg uptodate $uptodate \
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
	jq '.charts += $inputs' $file_deployments_json --slurpfile inputs $file_tmp_item >$file_tmp_list
	cat $file_tmp_list >$file_deployments_json
}



# List deployed Helm Charts
# Usage: list_charts_deployed
list_charts_deployed() {

	# First ensure the file containing the charts list doesn't exist (because this function will be called several time over the script)
	if [ ! -f $file_deployments_json ] && [ ! -z $file_deployments_json ]; then 

		# Prepare an empty JSON array to receive the charts properties
		jq -n --argjson charts "[]" '$ARGS.named' >$file_deployments_json

		local namespaces="$(kubectl get namespaces -o json | jq -c '.items[].metadata.name' | tr -d \")"
		for namespace in $namespaces; do
			log_info "jumping to namespace '$namespace'"

			local deployments="$(helm --namespace $namespace list --deployed -o json | jq -c '.[] | {name,app_version}')"
			# deployments="$(helm list --deployed --all-namespaces -o json | jq -c '.[] | {name,app_version}')"

			if [ -z "$deployments" ]; then
				log_info "no chart found on '$namespace'"
			else 
				for deployment in $deployments; do

					log_info "found deployment '$deployment'"

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

					local remote_image_reference="$(echo $configured_repo_name/$(echo $remote_image | sed 's|.*/\(.*\):.*|\1|'))"
					local remote_version="$(helm --namespace $namespace show chart $remote_image_reference | grep appVersion | sed 's|.*: ||')"

					# # Debug comment/uncomment
					# echo "installed_name         $installed_name"
					# echo "installed_version      $installed_version"
					# echo "installed_status       $installed_status"
					# echo "remote_image           $remote_image"
					# echo "configured_repo_url    $configured_repo_url"
					# echo "configured_repo_name   $configured_repo_name"
					# echo "remote_image_reference $remote_image_reference"
					# echo "remote_version         $remote_version"

					if [ "$(echo "$installed_version")" != "$(echo "$remote_version")" ]; then
						json_chart $namespace $installed_name $remote_image_reference $remote_image $installed_version $remote_version "false"
					else
						json_chart $namespace $installed_name $remote_image_reference $remote_image $installed_version $remote_version "true"
					fi
				done

			fi
		done

		if [ -f $file_deployments_json ] && [ ! -z $file_deployments_json ]; then
			log_info "deployments value written in $file_deployments_json"
		fi
	fi

	cat $file_deployments_json
}



# Get the reference (= "repository/name") of a given Helm Chart
# Usage: get_chart_reference <deployed chart>
get_chart_reference() {

	local deployment_name=$1
	list_charts_deployed > /dev/null

	# cat $file_deployments_json | jq ".charts[].reference" | grep -w $deployment_name
	cat $file_deployments_json | jq '.charts[] | select(.name=="'$deployment_name'") | .reference' | tr -d \"
}



# # Match current deployed Helm Charts values with the new available remote version
# # Usage: match_charts_values
# match_charts_values() {

# 	list_charts_deployed > /dev/null

# 	local uptodate_charts="$(cat $file_deployments_json | jq -c '.charts[] | select(.uptodate == "false")')"
# 	for chart in $uptodate_charts; do

# 		local chart_name="$(echo $chart | jq '.name' | tr -d \")"

# 		log_info "getting values of '$chart_name'"


# 		# Deployed (=on cluster)
# 		local file_chart_pairs_deployed="$dir_deployments_now/pairs_deployed_$chart_name.yml"
# 		helm get values $chart_name -o json > $file_chart_pairs_deployed                                                                                     # Get the YAML keys/values of the current deployed chart and store it as JSON
# 		if [ -f $file_chart_pairs_deployed ]; then                                                                                                           # Ensure the tmp file containing values exists, if not it means no values are specified
# 			local pairs_deployed="$(cat $file_chart_pairs_deployed | yq)"                                                                                    # Get keys/values pairs of the chart
# 			local keys_deployed="$(echo $pairs_deployed | jq -r --stream 'select(has(1)) | ".\(first | join(".")) = \(last | @json)"' | sed 's| =.*||')"     # Get the keys names only to be able to compare them with the new remote chart version
# 		fi

# 		# Remote (=repository)
# 		local file_tmp_chart_pairs_remote="$dir_tmp/pairs_remote_$chart_name.yml"
# 		helm show values "$(get_chart_reference $chart_name)" > $file_tmp_chart_pairs_remote                                                                 # Get the YAML keys/values of the new version to be able to ensure that the current values are still compatibles
# 		if [ -f $file_tmp_chart_pairs_remote ]; then                                                                                                         # Ensure the tmp file containing values exists, if not it means no values are specified
# 			local pairs_remote="$(cat $file_tmp_chart_pairs_remote | yq)"                                                                                    # Get keys/values pairs of the chart
# 			local keys_remote="$(echo $pairs_deployed | jq -r --stream 'select(has(1)) | ".\(first | join(".")) = \(last | @json)"' | sed 's| =.*||')"       # Get the keys names only to be able to compare them with the new remote chart version
# 		fi

		
# 		# echo "chart             " $chart_name
# 		# echo "pairs_deployed    " $pairs_deployed
# 		# echo "keys_deployed     " $keys_deployed
# 		# echo "pairs_remote      " $pairs_remote
# 		# echo "keys_remote       " $keys_remote

# 		if [ ! -z "$(echo $keys_remote)" ] && [ ! -z "$(echo $keys_deployed)" ]; then
# 			for key_remote in $keys_remote; do
# 				for key_deployed in $keys_deployed; do
# 					if [ "$(echo $key_remote)" = "$(echo $key_deployed)" ] && [ "$(echo $key_remote)" != "." ]; then
# 						echo $key_deployed
# 					elif [ "$(echo $key_remote)" = "." ]; then
# 						log_info "no value found on '$chart_name'"				
# 					fi
# 				done
# 			done
# 		fi


# 		# # Ensure the key list is not empty
# 		# if [ ! -z "$(echo $keys)" ]; then
# 		# 	for key in $keys; do

# 		# 		# Here use yq and not jq since the remotes pairs are in YAML and not JSON
# 		# 		local values="$(cat $file_tmp_chart_pairs_remote | yq ".$key")"
# 		# 	done
# 		# fi


# 		# Ensure the current configured pairs are still compatible with the new chart version, or give up the update
# 		#helm show values $reference | yq '.'


# 	done
	
# }



# Update all Helm Charts
# Usage:
# - update_charts
# - update_charts -y
update_charts() {

	# Permit to use -y argument
	local confirmation=$1
	if [ -z $confirmation ]; then
		read -p "Confirm update all Charts ? " confirmation
	fi
	local confirmation="$(sanitize_confirmation $confirmation)"
	if [ "$(echo $confirmation)" = "yes" ]; then

		log_info "starting update"

		list_charts_deployed > /dev/null

		local uptodate_charts="$(cat $file_deployments_json | jq -c '.charts[] | select(.uptodate == "false")')"
		for chart in $uptodate_charts; do

			local chart_name="$(echo $chart | jq '.name' | tr -d \")"
			local chart_reference="$(echo $chart | jq '.reference' | tr -d \")"

			log_info "updating '$chart_name'"

			helm upgrade --reuse-values $chart_name $chart_reference > /dev/null

			local chart_status="$(helm status $chart_name | grep STATUS: | cut -d ' ' -f 2)"
			if [ "$(echo $chart_status)" = "deployed" ]; then
				log_info "update of '$chart_name' success (status: $chart_status)"
			else
				log_error "update of '$chart_name' failed (status: $chart_status)"
			fi
		done

		log_info "end of updates"

	else
		log_info "update aborted"
	fi
}



# Check the status of a deployment. Permit to ensure an upgrade has well worked.
# Usage: check_deployment_status <deployment name>
check_deployment_status() {

	local deployment_name=$1



	# helm rollback
	# email alert
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
	-l|--list-deployment)
							hook_rate_registry
							list_charts_deployed ;;
	-u|--do-update)
							# hook_rate_registry
							if [ "$(echo $2)" = "-y" ]; then
								update_charts $2
							else 
								update_charts
							fi ;;
	-h|--help|help)			display_help ;;
	# -z)					placeholder ;;
	*)
							if [ -z "$1" ]; then
								display_help
							else
								log_error "unknown option '$1', $0 --help"
							fi
esac



# todo:
# - mail notification for errors



# delete_tmp



exit
