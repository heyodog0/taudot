#!/bin/sh
# Builds tau-attach (tau-attach.c: no dependencies beyond libc).
set -e
cd "$(dirname "$0")"
cc -O2 -Wall -Wextra -o tau-attach tau-attach.c
