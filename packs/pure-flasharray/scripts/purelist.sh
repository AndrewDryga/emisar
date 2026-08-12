#!/bin/sh
# Perform one bounded collection read and retain only the documented response
# envelope. Resource items are operational inventory; authentication headers
# remain inside pureget.sh and never enter this output.
set -eu

mode=$1
limit=$2
page_cursor=$3
member_type=${4:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$mode" in
	protection-groups)
		path=/protection-groups
		;;
	default-protection)
		path=/container-default-protections
		;;
	snapshots)
		path=/protection-group-snapshots
		;;
	members)
		case "$member_type" in
			volumes|hosts|host-groups)
				path="/protection-groups/$member_type"
				;;
			*)
				echo "pure-flasharray: invalid protection-group member type" >&2
				exit 2
				;;
		esac
		;;
	*)
		echo "pure-flasharray: invalid collection" >&2
		exit 2
		;;
esac

set -- --data-urlencode "limit=$limit"
if [ "$mode" = "default-protection" ]; then
	# An empty names selector means the local array on supported REST 2.x releases.
	set -- "$@" --data-urlencode "names="
fi
if [ -n "$page_cursor" ]; then
	set -- "$@" --data-urlencode "continuation_token=$page_cursor"
fi

response=$(mktemp)
trap 'rm -f "$response"' EXIT HUP INT TERM
if sh "$script_dir/pureget.sh" "$path" "$@" >"$response"; then
	jq -e '{
		items: (.items // []),
		more_items_remaining: (.more_items_remaining // false),
		total_item_count: (.total_item_count // null),
		next_page_cursor: (.continuation_token // null),
		errors: (.errors // [])
	}' "$response"
else
	status=$?
	exit "$status"
fi
