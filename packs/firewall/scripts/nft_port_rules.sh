#!/bin/sh
set -eu

port=$1

nft -j -n -a -t list ruleset | jq -ce --argjson port "$port" '
  def is_port_match:
    (.left.payload.field? == "sport" or .left.payload.field? == "dport");

  def numeric:
    if type == "number" then .
    elif type == "string" and test("^[0-9]+$") then tonumber
    else null
    end;

  def scalar_verdict($operator; $right; $candidate):
    ($right | numeric) as $value |
    if $value == null then null
    elif $operator == "==" or $operator == "eq" then $candidate == $value
    elif $operator == "!=" or $operator == "ne" then $candidate != $value
    elif $operator == "<" or $operator == "lt" then $candidate < $value
    elif $operator == "<=" or $operator == "le" then $candidate <= $value
    elif $operator == ">" or $operator == "gt" then $candidate > $value
    elif $operator == ">=" or $operator == "ge" then $candidate >= $value
    else null
    end;

  def match_verdict($match; $candidate):
    ($match.op // "==") as $operator |
    ($match.right) as $right |
    if ($right | type) == "number" or ($right | type) == "string" then
      scalar_verdict($operator; $right; $candidate)
    elif ($right | type) == "array" and
         ($operator == "==" or $operator == "eq") then
      if all($right[]; (numeric != null)) then
        any($right[]; numeric == $candidate)
      else
        null
      end
    elif ($right | type) == "object" and
         ($right.range? | type) == "array" and
         ($right.range | length) == 2 and
         ($operator == "==" or $operator == "eq") then
      ($right.range[0] | numeric) as $start |
      ($right.range[1] | numeric) as $end |
      if $start == null or $end == null then null
      else $candidate >= $start and $candidate <= $end
      end
    else
      null
    end;

  def rule_verdict($candidate):
    [
      .expr[]?.match? |
      select(is_port_match) |
      match_verdict(.; $candidate)
    ] as $verdicts |
    if any($verdicts[]; . == true) then "direct_match"
    elif any($verdicts[]; . == null) then "unresolved"
    else "no_match"
    end;

  def project($evaluation):
    {
      family,
      table,
      chain,
      handle: (.handle // null),
      comment: (.comment // null),
      port_evaluation: $evaluation,
      expr
    };

  [
    .nftables[]?.rule? |
    select(. != null) |
    . as $rule |
    (rule_verdict($port)) as $evaluation |
    select($evaluation != "no_match") |
    ($rule | project($evaluation))
  ] as $rules |
  {
    port: $port,
    direct_matches: [$rules[] | select(.port_evaluation == "direct_match")],
    unresolved: [$rules[] | select(.port_evaluation == "unresolved")]
  }
'
