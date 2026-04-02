#!/bin/bash
pongo init
pongo up
KONG_DATABASE=off KONG_DECLARATIVE_CONFIG=/kong-plugin/kong.yml KONG_PREFIX=/tmp/kong_prefix pongo shell
# In the shell, run `kms -y`
