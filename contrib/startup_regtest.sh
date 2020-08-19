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

#set -o nounset
#set -o errexit # same as set -e
trap 'last_command=$BASH_COMMAND' ERR DEBUG
#trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT
trap 'echo "\"$BASH_COMMAND\" command filed with exit code $?."' EXIT

exit_early() {
	echo "ERROR" >&2
	[[ -n ${1} ]] && printf ": %s\n" "${1}" >&2 || printf ".\n" >&2
	exit 1
}

set_variables() {
	PATH_TO_LIGHTNING=""
	PARENT_DIR=""
	GRANDPARENT_DIR=""

	# Do the Right Thing if we're currently in top of srcdir.
	if [ -z "${PATH_TO_LIGHTNING}" ] && [ -x cli/lightning-cli ] && [ -x lightningd/lightningd ]; then
		PATH_TO_LIGHTNING=$(pwd)
	fi

	if [ -z "${PATH_TO_LIGHTNING}" ]; then
		# Already installed maybe?  Prints
		type lightning-cli || exit_early "lightning-cli not found."
		# shellcheck disable=SC2039
		type lightningd || exit_early "lightningd not found."
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

	read -rp "Do you want to choose a parent directory for regtest data directories? [Yn]" TMP_SESSION_REQ
	if [[ ${TMP_SESSION_REQ} =~ [nN](o)* ]]; then
		PARENT_DIR=/tmp
	else
		while true; do
			read -rp  "Please enter a path for a parent directory that will hold lightning node data directories:" PARENT_DIR
			PARENT_DIR="${PARENT_DIR//\~/$HOME}"
			GRANDPARENT_DIR=$(dirname "${PARENT_DIR}")
			[[ ! -d ${GRANDPARENT_DIR} ]] && { echo "Invalid path...try again."; continue; } 
			[[ ! -w ${GRANDPARENT_DIR} ]] && { echo "${GRANDPARENT_DIR} not writeable...try again."; continue; } 
			break	
		done
	fi
	# Make the data directories if they do not already exist.
	for i in $(seq "$N_NODES"); do
		mkdir -p "${PARENT_DIR}/l${i}-regtest"
	done
}

write_config() {
	for i in $(seq "$N_NODES"); do
		port=$((9000 + i))
		cat <<- EOF > "${PARENT_DIR}/l${i}-regtest/config"
		network=regtest
		log-level=debug
		log-file=${PARENT_DIR}/l${i}-regtest/log
		addr=localhost:${port}
EOF
	done

}

set_aliases() {
	echo "Setting aliases..."
	alias bt-cli='bitcoin-cli -regtest'
	for i in $(seq "$N_NODES"); do
		# shellcheck disable=SC2139,SC2086
		alias l${i}-cli="${LCLI} --lightning-dir=${PARENT_DIR}/l${i}-regtest"
		# shellcheck disable=SC2139,SC2086
		alias l${i}-log="less ${PARENT_DIR}/l${i}-regtest/log"
	done
}

start_ln() {
	echo "Starting lightning regtest nodes..."
	# Start bitcoind in the background
	[[ -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" ]] || bitcoind -daemon -regtest -txindex

	# Wait for it to start.
#	while ! bt-cli ping 2> /dev/null; do
	while ! bt-cli ping 2>&1 /dev/null; do
		echo "Waiting for bitcoind to start..."
		sleep 1
	done

	# Kick it out of initialblockdownload if necessary
	if bt-cli getblockchaininfo | grep -q 'initialblockdownload.*true'; then
		bt-cli generatetoaddress 1 "$(bt-cli getnewaddress)" > /dev/null
	fi

	# Start the lightning nodes
	for i in $(seq "$N_NODES"); do
		echo "Node ${i}..."
		if [[ -f "${PARENT_DIR}"/l"${i}"-regtest/lightningd-regtest.pid ]]; then
		       	"$LIGHTNINGD" --lightning-dir="${PARENT_DIR}"/l"${i}" -regtest &
			echo "Commands: l${i}=cli, l${i}-log"
		fi
	done

	# Give a hint.
	echo "Common commands: bt-cli, stop_ln, cleanup_ln"
}

stop_ln() {
	echo "Stopping any running lightning nodes..."
	local pid_file
	local pid
	for i in $(seq "$N_NODES"); do
		# If there is a pid for this node, kill the node process & remove .pid file
		pid_file="${PARENT_DIR}/l${i}-regtest/lightningd-regtest.pid"
		if [[ -f "${pid_file}" ]]; then
			pid=$(cat "${pid_file}")
			kill "$pid"
			rm "${pid_file}"
		fi
	done

	[[ -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" ]] && bitcoin-cli -regtest stop
}

cleanup_ln() {
	echo "Cleaning up lightning regtest..."
	stop_ln
	for i in $(seq "$N_NODES"); do
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

N_NODES=${1:-2}
set_variables
write_config
set_aliases
