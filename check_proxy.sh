#!/bin/bash

# HAProxy-provided parameters
RIP=$3
RPT=$4

# Fetch the URL to check from the environment variable
PROXIED_URL=${PROXIED_URL:-"https://www.google.com/search?q=hello+world"}
MAX_TIMEOUT=${MAX_TIMEOUT:-1}

# Build the curl command string
curl_cmd="/usr/bin/curl -x $RIP:$RPT -s -o /dev/null -w %{http_code} -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'Accept-Language: en-GB,en;q=0.5' -H 'Accept-Encoding: gzip, deflate, br, zstd' -H 'Sec-GPC: 1' -H 'Connection: keep-alive' -H 'Upgrade-Insecure-Requests: 1' -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-User: ?1' -H 'Priority: u=0, i' --max-time $MAX_TIMEOUT --connect-timeout 1 $PROXIED_URL"

# Perform the check using curl with headers
response=$(eval "$curl_cmd" 2>/dev/null)

# Log both command and output
#echo "$curl_cmd" >> /tmp/log.txt
#echo "Output: ${response}" >> /tmp/log.txt

# Exit codes - removed file logging to reduce I/O overhead
if [ "$response" -eq 200 ] 2>/dev/null; then
  exit 0
else
  exit 1
fi

