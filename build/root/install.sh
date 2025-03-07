#!/bin/bash

# exit script if return code != 0
set -e

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"

# target arch from buildx arg
TARGETARCH="${2}"

# if [[ -z "${RELEASETAG}" ]]; then
# 	echo "[warn] Release tag name from build arg is empty, exiting script..."
# 	exit 1
# fi

# if [[ -z "${TARGETARCH}" ]]; then
# 	echo "[warn] Target architecture name from build arg is empty, exiting script..."
# 	exit 1
# fi
# write RELEASETAG to file to record the release tag used to build the image
echo "IMAGE_RELEASE_TAG=${RELEASETAG}" >>'/etc/image-release'

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/binhex/scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /root
mv /tmp/scripts-master/shell/arch/docker/*.sh /usr/local/bin/

# pacman packages
####
cat <<'EOF' >/etc/pacman.d/mirrorlist
Server = https://iad.mirror.rackspace.com/archlinux/$repo/os/$arch 
Server = http://mirror.umd.edu/archlinux/$repo/os/$arch 
Server = http://mirrors.rit.edu/archlinux/$repo/os/$arch 
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.dal10.us.leaseweb.net/archlinux/$repo/os/$arch
EOF

pacman -Sy --disable-sandbox
pacman -S --needed curl wget rsync reflector --noconfirm --disable-sandbox

sed -i \
	-e 's|https://arch\.mirror\.constant\.com/\$repo/os/\$arch|https://iad.mirror.rackspace.com/archlinux/\$repo/os/\$arch|g' \
	-e 's|rsync://arch\.mirror\.constant\.com/archlinux/\$repo/os/\$arch|https://mirrors.kernel.org/archlinux/\$repo/os/\$arch|g' \
	-e 's|rsync://arch\.mirror\.square-r00t\.net/arch/\$repo/os/\$arch|https://mirror.dal10.us.leaseweb.net/archlinux/\$repo/os/\$arch|g' \
	-e 's|https://arch\.mirror\.square-r00t\.net/\$repo/os/\$arch|http://mirror.umd.edu/archlinux/\$repo/os/\$arch|g' \
	-e 's|http://arch\.mirror\.square-r00t\.net/\$repo/os/\$arch|http://mirrors.rit.edu/archlinux/\$repo/os/\$arch|g' \
	/usr/local/bin/upd.sh

# call pacman db and package updater script
source upd.sh

# define pacman packages
pacman_packages="geoip python-geoip"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm --disable-sandbox
	pacman -Syu --noconfirm --disable-sandbox
fi

# aur packages
###
# define aur packages
aur_packages="p7zip-full-bin deluge-git"

# call aur install script (arch user repo)
source aur.sh

# ignore aor package 'libtorrent-rasterbar' to prevent upgrade to libtorrent v2 as libtorrent
# v2 causes numerous issues, including crashing on unraid due to kernel bug
#sed -i -e 's~IgnorePkg.*~IgnorePkg = filesystem libtorrent-rasterbar~g' '/etc/pacman.conf'

# tweaks
####

# change peerid to appear to be 2.1.1 stable - note this does not work for all/any private trackers at present
sed -i -e "s~peer_id = substitute_chr(peer_id, 6, release_chr)~peer_id = \'-DE211s-\'\n        release_chr = \'s\'~g" /usr/lib/python3*/site-packages/deluge/core/core.py

# container perms
####

# define comma separated list of paths
install_paths="/home/nobody"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<<"${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..."
		exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# set permissions for python eggs to be a more restrictive 755, this prevents the warning message thrown by deluge on startup
mkdir -p /home/nobody/.cache/Python-Eggs
chmod -R 755 /home/nobody/.cache/Python-Eggs

# disable built-in Deluge Plugin 'stats', as its currently broken in Deluge 2.x and causes log spam
# see here for details https://dev.deluge-torrent.org/ticket/3310
# note from zak:
# this now fixed and will grab the latest updated version by mhertz
rm -rf /usr/lib/python3*/site-packages/deluge/plugins/Stats*py*.egg

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF >/tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

cat <<'EOF' >/tmp/envvars_heredoc

export DELUGE_DAEMON_LOG_LEVEL=$(echo "${DELUGE_DAEMON_LOG_LEVEL}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${DELUGE_DAEMON_LOG_LEVEL}" ]]; then
	echo "[info] DELUGE_DAEMON_LOG_LEVEL defined as '${DELUGE_DAEMON_LOG_LEVEL}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] DELUGE_DAEMON_LOG_LEVEL not defined,(via -e DELUGE_DAEMON_LOG_LEVEL), defaulting to 'info'" | ts '%Y-%m-%d %H:%M:%.S'
	export DELUGE_DAEMON_LOG_LEVEL="info"
fi

export DELUGE_WEB_LOG_LEVEL=$(echo "${DELUGE_WEB_LOG_LEVEL}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${DELUGE_WEB_LOG_LEVEL}" ]]; then
	echo "[info] DELUGE_WEB_LOG_LEVEL defined as '${DELUGE_WEB_LOG_LEVEL}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] DELUGE_WEB_LOG_LEVEL not defined,(via -e DELUGE_WEB_LOG_LEVEL), defaulting to 'info'" | ts '%Y-%m-%d %H:%M:%.S'
	export DELUGE_WEB_LOG_LEVEL="info"
fi

EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
    s/# ENVVARS_PLACEHOLDER//g
    r /tmp/envvars_heredoc
}' /usr/local/bin/init.sh
rm /tmp/envvars_heredoc

# cleanup
cleanup.sh
