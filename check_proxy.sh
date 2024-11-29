#!/bin/bash

# HAProxy-provided parameters
RIP=$3
RPT=$4

# Fetch the URL to check from the environment variable
PROXIED_URL=${PROXIED_URL:-"https://www.google.com/search?q=hello+world"}  # Default URL if PROXY_URL is not set
MAX_TIMEOUT=${MAX_TIMEOUT:-1}

# Perform the check using curl
response=$(/usr/bin/curl -x "$RIP:$RPT" -s -o /dev/null -w "%{http_code}" "$PROXIED_URL" -m"$MAX_TIMEOUT")
echo "/usr/bin/curl -x $RIP:$RPT -s -o /dev/null -w %{http_code} $PROXIED_URL" >> /tmp/log.txt
echo "Output: ${response}" >> /tmp/log.txt

# Exit codes
if [ "$response" -eq 200 ]; then
  echo "Proxy $PROXY_HOST:$PROXY_PORT is working. URL: $PROXIED_URL"
  exit 0
else
  echo "Proxy $PROXY_HOST:$PROXY_PORT check failed. HTTP response code: $response"
  exit 1
fi

