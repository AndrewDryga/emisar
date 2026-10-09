#!/bin/sh
set -eu

port=$1

# Preserve the native status, including when a failed read printed valid
# partial JSON; jq cannot decide whether the source read succeeded.
ruleset=$(nft -j -n -a -t list ruleset) || exit "$?"
printf "%s\n" "$ruleset" | jq -ce --argjson port "$port" '
  def is_port_match:
    (.left.payload.field? == "sport" or .left.payload.field? == "dport");

  # test("^[0-9]+$") needs Oniguruma, which the supported
  # --with-oniguruma=no jq build omits, and every projected rule reaches this
  # filter. Oniguruma also matched $ before a trailing newline, so "443\n"
  # used to parse as a port; refusing it is deliberate — a right operand
  # carrying a newline is not a number nft emitted.
  def all_digits: length > 0 and (explode | all(.[]; . >= 48 and . <= 57));

  def numeric:
    (if type == "number" then .
     elif type == "string" and all_digits then tonumber
     else null
     end) as $value |
    if ($value | type) != "number" then null
    elif $value < 0 or $value > 65535 then null
    elif ($value | floor) != $value then null
    else $value
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

  def member_verdict($right; $candidate):
    if ($right | type) == "number" or ($right | type) == "string" then
      scalar_verdict("=="; $right; $candidate)
    elif ($right | type) == "object" and ($right | keys) == ["range"] and
         ($right.range? | type) == "array" and
         ($right.range | length) == 2 then
      ($right.range[0] | numeric) as $start |
      ($right.range[1] | numeric) as $end |
      if $start == null or $end == null or $start > $end then null
      else $candidate >= $start and $candidate <= $end
      end
    else
      null
    end;

  def collection_verdict($members; $candidate):
    [$members[] | member_verdict(.; $candidate)] as $verdicts |
    if ($verdicts | length) == 0 or any($verdicts[]; . == null) then null
    else any($verdicts[]; . == true)
    end;

  def match_verdict($match; $candidate):
    ($match.op) as $raw_operator |
    (if ($raw_operator | type) == "string" then $raw_operator
     else ""
     end) as $operator |
    ($match.right) as $right |
    if ($right | type) == "number" or ($right | type) == "string" then
      scalar_verdict($operator; $right; $candidate)
    elif $operator == "==" or $operator == "eq" or
         $operator == "!=" or $operator == "ne" then
      (if ($right | type) == "array" then
         collection_verdict($right; $candidate)
       elif ($right | type) == "object" and ($right | keys) == ["set"] and
            ($right.set | type) == "array" then
         collection_verdict($right.set; $candidate)
       else
         member_verdict($right; $candidate)
       end) as $contains |
      if $contains == null then null
      elif $operator == "!=" or $operator == "ne" then ($contains | not)
      else $contains
      end
    else
      # Native JSON uses "in" for a bitmask test, not set membership.
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

  # Successful native reads have an object containing the nftables array.
  # Do not turn a malformed source document into an empty firewall report.
  if type != "object" then error("unexpected nftables ruleset")
  elif (.nftables | type) != "array" then error("unexpected nftables ruleset")
  else .
  end |
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
