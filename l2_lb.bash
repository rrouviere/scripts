#! /bin/bash

## UNCHECKED Assumptions

# 1. arping & libcap commands are available
# 2. IP is an IPv4 address (not duplicate address detection, easily fixable)
# 5. If a large number of instances with the same TIMEOUT & TIMEOUT_COUNT are launched at exactly the same time, or TIMEOUT_COUNT=1, several LB might try to take the VIP at the same time. A random delay might be added to counteract this (unlikely) effect.
# 6. We don't have flapping countermeasures (example: takeover if host is unreachable more than x% of y times)

## Checked assumptions
# 4. CAP_NET_RAWIO is granted


####################
## Config section ##
####################

export VIP="192.168.69.1"
export INTERFACE="eth0"
export OUR_MAC=$(cat /sys/class/net/${INTERFACE}/address)

# Seconds to wait for reply from another LB
export TIMEOUT=1 # Seconds

# Number of attempt to make before seizing control of the VIP
export TIMEOUT_COUNT=1

###########################
## End of config section ##
###########################



# Check environement
function check_prerequisites() {
	if capsh --has-p="cap_net_raw" 2>&1 | grep -q 'not'; then # WORKAROUND: on some versions of capsh, exit code behaves weirdly. Hence we just check output. 
		printf "$(tput setaf 1; tput bold)Error: CAP_NET_RAW is needed to send GARP. $(tput sgr0)\n"
		exit 1
	fi
	
	
	if ! command -v arping &>/dev/null; then
		printf "$(tput setaf 1; tput bold)Error: $(tput smul)arping$(tput rmul) is not installed. $(tput sgr0)\n"
		exit 1
	fi
	
	printf "Starting bash L2 LB.\n"
	printf "$(tput bold; tput setaf 2)Our MAC: $(tput sgr0)${OUR_MAC}\n"
}


## Main script

# ${VIP} VIP to takeover
# ${INTERFACE} Interface
function release_vip() {
	if ip addr del "${1}/32" dev "${INTERFACE}"; then
		printf "$(tput setaf 2; tput bold)Successfully released the VIP.$(tput sgr0)\n"
	fi
}



# ${VIP} VIP to takeover
# ${INTERFACE} Interface
function takeover_vip() {
	ip addr add "${1}" dev "${INTERFACE}" 2>/dev/null
	if [[ "$?" != "0" && "$?" != "2" ]]; then
		printf "$(tput setaf 1)Cannot configure the VIP. Takeover failed.$(tput sgr0)\n\n"
		return 1
	fi
	return 0
}


function leader() {
	printf "$(tput setaf 2)Sending update to invalidate caches on LAN (GARP)$(tput sgr0)\n"
	arping -c1 -U "${VIP}" -i "${INTERFACE}" >/dev/null 2>&1
	printf "$(tput bold)[LEADER]: $(tput setaf 2)Successfully taken over the VIP.$(tput sgr0)\n"
	
	printf "Checking for duplicate ARP answers..."
	while true; do
		arping -d "${VIP}" -i "${INTERFACE}" >/dev/null 2>&1
		if [ "$?" -ne "0" ]; then
			break;
		else
			printf "$(tput el1)\r"	
			printf "$(tput setaf 7)[$(date --rfc-3339=seconds)] $(tput bold)[LEADER]$(tput sgr0): No duplicate ARP found.$(tput sgr0)"	
		fi	
	done


	print "\n" # Cleanup from status line

	printf "$(tput setaf 1)Duplicate ARP detected.\nRelinquishing the VIP.$(tput sgr0)\n"
	release_vip "${VIP}" "${INTERFACE}"
}


declare -i FAILURE_COUNT
FAILURE_COUNT=0

function follower() {
	while true; do
		# Check if VIP is reachable 
		arping -c "${TIMEOUT_COUNT}" -W "${TIMEOUT}" -i "${INTERFACE}" "${VIP}" >/dev/null 2>&1
		if [ "$?" -ne "0" ]; then
			printf "$(tput setaf 3)ARP request failed.$(tput sgr0)\n"
			FAILURE_COUNT=$FAILURE_COUNT+1
			if [ "$FAILURE_COUNT" -ge "$TIMEOUT_COUNT" ]; then
				printf "\n$(tput setaf 2; tput bold)Taking over the VIP.\n$(tput sgr0)"
				takeover_vip "${VIP}" "${INTERFACE}"
				if [ "$?" -ne "0" ]; then
					continue;
				fi
					FAILURE_COUNT=0
					break;
			else
				printf "Retrying...$(tput sgr0)"
			fi
				
		else
			# If the last check succeded, just update the status instead of adding another line to the logs.
			if [ ${FAILURE_COUNT} -eq 0 ]; then
				printf "$(tput el1)\r"
			fi
			
			printf "$(tput setaf 7)[$(date --rfc-3339=seconds)]: Healthcheck succeeded$(tput sgr0)"	
			FAILURE_COUNT=0 # Reset failure count once VIP is reachable again) 
		fi
	done
}






## Startup
trap 'printf "\nExiting..." ; exit' SIGINT

check_prerequisites

# FIXME: follower & leader shouldn't exit except to switch from one state to another
# TODO: Figure out how to both 1) avoid infinite recursion and 2) how to protect against accidental state transitions.
while true; do
	follower
	leader
done

