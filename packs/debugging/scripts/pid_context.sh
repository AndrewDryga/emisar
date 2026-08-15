#!/bin/sh
# Return process identity and bounded ancestry without command arguments or env.
set -eu

pid=$1
proc=/proc/$pid

if [ ! -d "$proc" ]; then
	printf 'debugging: PID %s does not exist\n' "$pid" >&2
	exit 1
fi

ps_value() {
	process_id=$1
	field=$2
	ps -p "$process_id" -o "$field=" 2>/dev/null \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

readlink_or_unavailable() {
	if value=$(readlink "$1" 2>/dev/null); then
		printf '%s' "$value"
	else
		printf '[unavailable]'
	fi
}

parent_pid=$(ps_value "$pid" ppid)
if [ -z "$parent_pid" ]; then
	printf 'debugging: PID %s disappeared during inspection\n' "$pid" >&2
	exit 1
fi

printf 'pid=%s\n' "$pid"
printf 'parent_pid=%s\n' "$parent_pid"
printf 'owner=%s\n' "$(ps_value "$pid" user)"
printf 'start_time=%s\n' "$(ps_value "$pid" lstart)"
printf 'command_name=%s\n' "$(ps_value "$pid" comm)"
printf 'executable=%s\n' "$(readlink_or_unavailable "$proc/exe")"
printf 'cwd=%s\n' "$(readlink_or_unavailable "$proc/cwd")"
printf 'parent_chain:\n'

current=$parent_pid
depth=0
while [ "$current" -gt 0 ] 2>/dev/null && [ "$depth" -lt 16 ]; do
	next=$(ps_value "$current" ppid)
	if [ -z "$next" ]; then
		break
	fi
	printf '  pid=%s ppid=%s owner=%s start_time=%s command=%s\n' \
		"$current" \
		"$next" \
		"$(ps_value "$current" user)" \
		"$(ps_value "$current" lstart)" \
		"$(ps_value "$current" comm)"
	if [ "$next" = "$current" ]; then
		break
	fi
	current=$next
	depth=$((depth + 1))
done
