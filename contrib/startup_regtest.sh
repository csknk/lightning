#!/bin/bash

## Short script to startup two local nodes with
## bitcoind, all running on regtest
## Makes it easier to test things out, by hand.

## Should be called by source since it sets aliases
##
##  First load this file up.
##
##  $ source contrib/startup_regtest.sh
##
##  Start up the nodeset
##
##  $ start_ln
##
##  Let's connect the nodes.
##
##  $ l2-cli getinfo | jq .id
##    "02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb"
##  $ l2-cli getinfo | jq .binding[0].port
##    9090
##  $ l1-cli connect 02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb@localhost:9090
##    {
##      "id" : "030b02fc3d043d2d47ae25a9306d98d2abb7fc9bee824e68b8ce75d6d8f09d5eb7"
##    }
##
##  When you're finished, clean up or stop
##
##  $ stop_ln  # stops the services, keeps the aliases
##  $ cleanup_ln # stops and cleans up aliases
##

set -o nounset
set -o errexit

exit_early() {
	echo "ERROR" >&2
	[[ -n ${1} ]] && printf ": %s\n" "${1}" >&2 || printf ".\n" >&2
	exit 1
}

set_variables() {
	PATH_TO_LIGHTNING=""
	n_nodes=4
	local parent_dir=""
	local grandparent_dir=""
	local data_dir=""

	# Do the Right Thing if we're currently in top of srcdir.
	if [ -z "${PATH_TO_LIGHTNING}" ] && [ -x cli/lightning-cli ] && [ -x lightningd/lightningd ]; then
		PATH_TO_LIGHTNING=$(pwd)
	fi

	if [ -z "${PATH_TO_LIGHTNING}" ]; then
		# Already installed maybe?  Prints
		local no_path_set_no_executable="
		A lightning-cli executable is needed, and has not been found. If
		you have an (uninstalled) executable, please set $PATH_TO_LIGHTNING in your shell.
		"
		type lightning-cli || exit_early "${no_path_set_no_executable}"
		# shellcheck disable=SC2039
		type lightningd || return
		LCLI=lightning-cli
		LIGHTNINGD=lightningd
	else
		LCLI="${PATH_TO_LIGHTNING}"/cli/lightning-cli
		LIGHTNINGD="${PATH_TO_LIGHTNING}"/lightningd/lightningd
		# This mirrors "type" output above.
		echo lightning-cli is "$LCLI"
		echo lightningd is "$LIGHTNINGD"
	fi

	if [ -z "$PATH_TO_BITCOIN" ]; then
		if [ -d "$HOME/.bitcoin" ]; then
			PATH_TO_BITCOIN="$HOME/.bitcoin"
		else
			echo "\$PATH_TO_BITCOIN not set to a .bitcoin dir?" >&2
			return
		fi
	fi

	cat <<-EOF
	You can specify a parent directory for regtest data directories if required.
	This can be handy if your experiments are likely to span a system reboot.

	If this is not important, select 'N' and the data directories will be placed in \`/tmp\`.
EOF
	read -pr "Do you want to choose a parent directory for regtest data directories? [Yn]" TMP_SESSION_REQ
	if [[ ${TMP_SESSION_REQ} =~ [nN](o)* ]]; then
		parent_dir=/tmp
	else
	while [[ ! -d ${parent_dir} ]]
	do
		read -pr "Please enter a path for the data directory for lightning development instances:" parent_dir
		parent_dir="${parent_dir//\~/$HOME}"
		grandparent_dir=$(dirname "${parent_dir}")
		[[ ! -d ${grandparent_dir} ]] && { echo "Invalid path...please try again."; continue; } 
		[[ ! -w ${grandparent_dir} ]] && { echo "${grandparent_dir} is not writeable...please try again."; continue; } 
	done
fi
# Make the data directories
# If there is already a data directory at the specified $parent_dir, use this.
# Otherwise, create a new data directory for each node.
for i in $(seq $n_nodes); do
	data_dir=${parent_dir}/l${i}-regtest
	[[ ! -d ${data_dir} ]] && mkdir -p "${data_dir}"
done
}

write_config() {
	for i in $(seq $n_nodes); do
		port=$((9000 + i))
		# Node one config
		cat <<- EOF > "${parent_dir}/l${i}-regtest/config"
		network=regtest
		log-level=debug
		log-file=${parent_dir}/l${i}-regtest/log
		addr=localhost:${port}
EOF
	done

}

set_aliases() {
	alias bt-cli='bitcoin-cli -regtest'
	for i in $(seq $n_nodes); do
		# shellcheck disable=SC2139,SC2086
		alias l${i}-cli='$LCLI --lightning-dir=${parent_dir}/l${i}-regtest'
		# shellcheck disable=SC2139,SC2086
		alias l${i}-log='less ${parent_dir}/l${i}-regtest/log'
	done
}

start_ln() {
	# Start bitcoind in the background
	[[ -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" ]] || bitcoind -daemon -regtest -txindex

	# Wait for it to start.
	while ! bt-cli ping 2> /dev/null; do sleep 1; done

	# Kick it out of initialblockdownload if necessary
	if bt-cli getblockchaininfo | grep -q 'initialblockdownload.*true'; then
		bt-cli generatetoaddress 1 "$(bt-cli getnewaddress)" > /dev/null
	fi

	# Start the lightning nodes
	for i in $(seq $n_nodes); do
		if [[ -f "${parent_dir}"/l"${i}"-regtest/lightningd-regtest.pid ]]; then
		       	"$LIGHTNINGD" --lightning-dir="${parent_dir}"/l"${i}"-regtest &
			echo "Commands: l${i}=cli, l${i}-log"
		fi
	done

	# Give a hint.
	echo "Common commands: bt-cli, stop_ln, cleanup_ln"
}

stop_ln() {
	local pid_file
	local pid
	for i in $(seq $n_nodes); do
		# If there is a pid for this node, kill the node process & remove .pid file
		pid_file="${parent_dir}/l${i}-regtest/lightningd-regtest.pid"
		if [[ -f "${pid_file}" ]]; then
			pid=$(cat "${pid_file}")
			kill "$pid"
			rm "${pid_file}"
		fi
	done

	[[ -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" ]] && bitcoin-cli -regtest stop
}

cleanup_ln() {
	stop_ln
	for i in $(seq $n_nodes); do
		# shellcheck disable=2086
		unalias l${i}-cli
		# shellcheck disable=2086
		unalias l${i}-log
	done
	unalias bt-cli
	unset -f set_variables
	unset -f write_config
	unset -f set_aliases
	unset -f start_ln
	unset -f stop_ln
	unset -f cleanup_ln
}

set_variables
write_config
set_aliases
