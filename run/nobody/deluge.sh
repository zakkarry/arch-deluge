#!/usr/bin/dumb-init /bin/bash

# source in script to wait for child processes to exit
source /usr/local/bin/waitproc.sh

# set location for python eggs
python_egg_cache="/config/python-eggs"
if [[ ! -d "${python_egg_cache}" ]]; then
	echo "[info] Creating Deluge Python Egg cache folder..."
	mkdir -p "${python_egg_cache}"
	chmod -R 755 "${python_egg_cache}"
fi
# export location of python egg cache
export PYTHON_EGG_CACHE="${python_egg_cache}"

# if config file doesnt exist (wont exist until user changes a setting) then copy default config file
if [[ ! -f /config/core.conf ]]; then

	echo "[info] Deluge config file doesn't exist, copying default..."
	cp /home/nobody/deluge/core.conf /config/

else

	echo "[info] Deluge config file already exists, skipping copy"

fi

# downlad latest GeoIP.dat after aged a week
geoip_dat_path="/usr/share/GeoIP/GeoIP.dat"
echo "[info] Checking GeoIP.dat ($geoip_dat_path)..."

if [ -e "$geoip_dat_path" ]; then
	current_time=$(date +%s)
	# file's modification and creation times in seconds since epoch
	modification_time=$(stat -c %Y "$geoip_dat_path")
	creation_time=$(stat -c %W "$geoip_dat_path")
	week_seconds=$((7 * 24 * 60 * 60))

	if (((current_time - modification_time) > week_seconds)) || (((current_time - creation_time) > week_seconds)); then
		echo "[info] Found outdated GeoIP.dat...updating (timeout 30s)"
		curl -s -L --retry 3 --retry-max-time 30 --retry-all-errors \
			"https://mailfud.org/geoip-legacy/GeoIP.dat.gz" |
			gunzip >/usr/share/GeoIP/GeoIP.dat
	fi
else
	echo "[info] No GeoIP.dat found...updating (timeout 30s)"
	curl -s -L --retry 3 --retry-max-time 30 --retry-all-errors \
		"https://mailfud.org/geoip-legacy/GeoIP.dat.gz" |
		gunzip >/usr/share/GeoIP/GeoIP.dat
fi

# begin startup process for deluge
echo "[info] Attempting to start Deluge..."

echo "[info] Removing deluge pid file (if it exists)..."
rm -f /config/deluged.pid

# run process non daemonised but backgrounded so we can control sigterm
nohup /usr/bin/deluged -d -c /config -L "${DELUGE_DAEMON_LOG_LEVEL}" -l /config/deluged.log &
echo "[info] Deluge process started"

echo "[info] Waiting for Deluge process to start listening on port 58846..."
while [[ $(netstat -lnt | awk "\$6 == \"LISTEN\" && \$4 ~ \".58846\"") == "" ]]; do
	sleep 0.1
done

echo "[info] Deluge process listening on port 58846"

# run script to check we don't have any torrents in an error state
# note from zak: the problem this solved has been resolved, not necessary
# /home/nobody/torrentcheck.sh

if ! pgrep -x "deluge-web" >/dev/null; then
	echo "[info] Starting Deluge Web UI..."

	# run process non daemonised (blocking)
	/usr/bin/deluge-web -d -c /config -L "${DELUGE_WEB_LOG_LEVEL}" -l /config/deluge-web.log
fi
