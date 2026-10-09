#!/bin/sh
# SSH_ASKPASS helper for the one-time enrollment: prints the password held in the environment of this ssh
# process only (set by x_servers.py enroll, never in argv or on disk).
printf '%s\n' "${SERP_ASKPASS_PW:-}"
