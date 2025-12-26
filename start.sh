#!/bin/bash

function log() {
   if [[ $# == 1 ]]; then
      level="info"
      msg=$1
   elif [[ $# == 2 ]]; then
      level=$1
      msg=$2
   fi
   echo "[START] $(date -u +"%Y-%m-%dT%H:%M:%SZ") [controller] [${level}] ${msg}"
}

function send_signal_newnym() {
   local ctrl_port=$1
   local password=$2
   echo -e "authenticate \"${password}\"\nsignal newnym" | nc 127.0.0.1 "${ctrl_port}" >/dev/null 2>&1
   if [[ $? -ne 0 ]]; then
      log "error" "Failed to authenticate on ControlPort ${ctrl_port}"
      return 1
   fi
   log "Circuit successfully rebuilt on ControlPort ${ctrl_port}"
   return 0
}

function check_backend_status() {
   local instance_id=$1
   local http_port=$((base_http_port + instance_id))
   local response=$(/usr/bin/curl -x "127.0.0.1:${http_port}" -s -o /dev/null -w "%{http_code}" "$PROXIED_URL" -m2 2>/dev/null)
   
   if [ "$response" -eq 200 ] 2>/dev/null; then
      return 0
   else
      return 1
   fi
}

if ((TOR_INSTANCES < 1 || TOR_INSTANCES > 150)); then
   log "fatal" "Environment variable TOR_INSTANCES has to be within the range of 1...150"
   exit 1
fi

if ((TOR_REBUILD_INTERVAL < 6)); then
   log "fatal" "Environment variable TOR_REBUILD_INTERVAL has to be bigger than 6 seconds"
   # otherwise AWS may complain about it, because http://checkip.amazonaws.com is asked too often
   exit 2
fi

base_tor_socks_port=10000
base_tor_ctrl_port=20000
base_http_port=30000
hash_control_password="16:C5D18CCFB98DC8BC60F933C9C63CA75309B0851A86D422953BE9038F2F"
control_password="my_password" # Set this to match your Tor ControlPort config
PROXIED_URL=${PROXIED_URL:-"https://www.google.com/search?q=hello+world"}
echo "[START] $PROXIED_URL"
MAX_TIMEOUT=${MAX_TIMEOUT:-1}
sed -i "s,PROXIED_URL=.*,PROXIED_URL=${PROXIED_URL}," /var/lib/haproxy/check_proxy.sh
sed -i "s,MAX_TIMEOUT=.*,MAX_TIMEOUT=${MAX_TIMEOUT}," /var/lib/haproxy/check_proxy.sh


log "Start creating a pool of ${TOR_INSTANCES} tor instances..."

# "reset" the HAProxy config file because it may contain the previous Privoxy instances information from the previous docker run
cp /etc/haproxy/haproxy.cfg.default /etc/haproxy/haproxy.cfg

for ((i = 0; i < TOR_INSTANCES; i++)); do
   #
   # start one tor instance
   #
   socks_port=$((base_tor_socks_port + i))
   ctrl_port=$((base_tor_ctrl_port + i))
   tor_data_dir="/var/local/tor/${i}"
   mkdir -p "${tor_data_dir}" && chmod -R 700 "${tor_data_dir}" && chown -R tor: "${tor_data_dir}"
   # spawn a child process to run the tor server at foreground so that logging to stdout is possible
   (tor --PidFile "${tor_data_dir}/tor.pid" \
      --SocksPort 127.0.0.1:"${socks_port}" \
      --ControlPort 127.0.0.1:"${ctrl_port}" \
      --HashedControlPassword "${hash_control_password}" \
      --dataDirectory "${tor_data_dir}" 2>&1 |
      sed -r "s/^(\w+\ [0-9 :\.]+)(\[.*)[\r\n]?$/$(date -u +"%Y-%m-%dT%H:%M:%SZ") [tor#${i}] \2/") &
   #
   # start one privoxy instance connecting to the tor socks
   #
   http_port=$((base_http_port + i))
   privoxy_data_dir="/var/local/privoxy/${i}"
   mkdir -p "${privoxy_data_dir}" && chown -R privoxy: "${privoxy_data_dir}"
   cp /etc/privoxy/config.templ "${privoxy_data_dir}/config"
   sed -i \
      -e 's@PLACEHOLDER_CONFDIR@'"${privoxy_data_dir}"'@g' \
      -e 's@PLACEHOLDER_HTTP_PORT@'"${http_port}"'@g' \
      -e 's@PLACEHOLDER_SOCKS_PORT@'"${socks_port}"'@g' \
      "${privoxy_data_dir}/config"
   # spawn a child process
   (privoxy \
      --no-daemon \
      --user privoxy \
      --pidfile "${privoxy_data_dir}/privoxy.pid" \
      "${privoxy_data_dir}/config" 2>&1 |
      sed -r "s/^([0-9\-]+\ [0-9:\.]+\ [0-9a-f]+\ )([^:]+):\ (.*)[\r\n]?$/$(date -u +"%Y-%m-%dT%H:%M:%SZ") [privoxy#${i}] [\L\2] \E\3/") &
   #
   # "register" the privoxy instance to haproxy
   #
   echo "  server privoxy${i} 127.0.0.1:${http_port} check" >>/etc/haproxy/haproxy.cfg
done
#
# start an HAProxy instance
#
(haproxy -db -- /etc/haproxy/haproxy.cfg 2>&1 |
   sed -r "s/^(\[[^]]+]\ )?([\ 0-9\/\():]+)?(.*)[\r\n]?$/$(date -u +"%Y-%m-%dT%H:%M:%SZ") [haproxy] \L\1\E\3/") &
# seems like haproxy starts logging only when the first request processed. We wait 15 seconds to build the first circuit then issue a
# request to "activate" the HAProxy
log "Wait 15 seconds to build the first Tor circuit"
sleep 15

# Main loop: periodic circuit rebuilds - only rebuild failing instances
while :; do
   log "Wait ${TOR_REBUILD_INTERVAL} seconds before next circuit rebuild cycle"
   sleep "$((TOR_REBUILD_INTERVAL))"
   log "Checking backends and rebuilding circuits for failing instances..."
   for ((i = 0; i < TOR_INSTANCES; i++)); do
      if ! check_backend_status "$i"; then
         log "info" "Backend ${i} is failing, rebuilding circuit..."
         ctrl_port=$((base_tor_ctrl_port + i))
         send_signal_newnym "${ctrl_port}" "${control_password}"
         http_port=$((base_http_port + i))
         sleep 1
         IP=$(curl -sx "http://127.0.0.1:${http_port}" -s http://checkip.amazonaws.com 2>/dev/null || echo "unknown")
         log "Current external IP address of proxy #${i}/${TOR_INSTANCES}: ${IP}"
      else
         log "info" "Backend ${i} is healthy, skipping rebuild"
      fi
   done
done
