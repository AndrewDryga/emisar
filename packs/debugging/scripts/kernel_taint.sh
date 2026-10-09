#!/bin/sh
set -eu

raw=$(cat /proc/sys/kernel/tainted) || exit $?
case "$raw" in
  ''|*[!0-9]*) printf 'debugging: invalid kernel taint mask\n' >&2; exit 1 ;;
esac

# Decimal long division keeps unsigned-long masks exact, including unknown
# high bits: shell integers are signed and awk numbers can round above 2^53.
# Flag order follows https://docs.kernel.org/admin-guide/tainted-kernels.html.
awk -v raw="$raw" '
  BEGIN {
    print "tainted: " raw
    mask = raw
    sub(/^0+/, "", mask)
    if (mask == "") {
      print "flags: not tainted"
      exit
    }
    print "flags:"
    letters = "PFSRMBUDAWCIOELKXTNJ"
    while (mask != "") {
      quotient = ""
      carry = 0
      for (i = 1; i <= length(mask); i++) {
        digit = carry * 10 + substr(mask, i, 1)
        quotient = quotient int(digit / 2)
        carry = digit % 2
      }
      if (carry) {
        if (bit < length(letters))
          printf "%d %s\n", bit, substr(letters, bit + 1, 1)
        else
          printf "unknown bit %d\n", bit
      }
      sub(/^0+/, "", quotient)
      mask = quotient
      bit++
    }
  }
'
