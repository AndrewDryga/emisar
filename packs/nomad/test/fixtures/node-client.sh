#!/bin/sh
set -eu
node /fixture/node-dns.cjs &
exec nomad agent -dev -bind=0.0.0.0 -config=/fixture/node-client.hcl
