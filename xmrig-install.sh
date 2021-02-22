#/bin/bash
if [ "$(whoami)" != "xmrnode" ]; then
	echo -e 'Error:  This script should NOT be run as any other users but xmrnode.'
	exit 1
fi

. ~/.bashrc

# perform clean up on any failed attempts
if [ -d ~/xmrig ]; then
  rm -rf ~/xmrig
fi
if [ -f /usr/sbin/xmrnode.sh ]; then
  sudo systemctl stop xmrnode.service
  sudo systemctl disable xmrnode.service
  sudo rm -f /usr/sbin/xmrnode.sh
  sudo rm -f /etc/systemd/system/xmrnode.service
fi

# install build dependencies
sudo apt-get -y install git build-essential cmake automake libtool autoconf

# clone repository
cd /home/xmrnode
git clone https://github.com/xmrig/xmrig.git

# build
mkdir xmrig/build && cd xmrig/scripts
./build_deps.sh && cd ../build
cmake .. -DXMRIG_DEPS=scripts/deps
make -j$(nproc)

# move build result to user directory
mv ./xmrig ~/xmrig.bin
rm -rfd ~/xmrig
mkdir ~/xmrig
mv ~/xmrig.bin ~/xmrig/xmrig

# configure polkit (ubuntu/debian)
sudo tee /etc/polkit-1/localauthority/50-local.d/service-auth.pkla >/dev/null <<'EOF'
[Allow xmrnode to start/stop/restart services]
Identity=unix-user:xmrnode
Action=org.freedesktop.systemd1.manage-units
ResultActive=yes
EOF

# configure hugepages
NPROC=$(nproc)
sudo tee /etc/sysctl.d/10-hugepages.conf >/dev/null <<EOF
vm.nr_hugepages = ${NPROC}
EOF
sudo sysctl -w vm.nr_hugepages=`nproc`
for i in $(sudo find /sys/devices/system/node/node* -maxdepth 0 -type d);
do
  MY_DEVFILE="$i/hugepages/hugepages-1048576kB/nr_hugepages"
  if [ -f "$MY_DEVFILE" ]; then
	  echo 3 | sudo tee $MY_DEVFILE >/dev/null
  fi
done

# configure memlock and nofile
MY_MEMLOCK=`bc -l <<< $(cat /proc/meminfo | grep -i MemTotal | awk '{print $2}')*0.90 | awk '{print int($1+0.5)}'`
sudo tee /etc/security/limits.d/60-memlock.conf >/dev/null <<EOF
*    -    memlock ${MY_MEMLOCK}
root -    memlock ${MY_MEMLOCK}
EOF
sudo tee /etc/security/limits.d/60-nofile.conf >/dev/null <<EOF 
*    soft nofile 10000
root soft nofile 10000
*    hard nofile 10000
root hard nofile 10000
EOF

# reload after changes
service procps force-reload

# install service script
sudo tee /usr/sbin/xmrnode.sh >/dev/null <<EOF
#!/bin/bash
if [[ `id -nu` != "xmrnode" ]];then
   echo "Not xmrnode user, exiting.."
   exit 1
fi
SCRIPT_NAME=$(basename -- "$0")
MY_POOL="stratum+ssl://pool.supportxmr.com:443"
MY_NODE_ID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1)
MY_WALLET="46Z4T9pKPPv82ixGexhGZW9rmMHzPyLnU9ozhewcp8EbC2QagMtz2BKdiqTCx9wo1AiVbEt8R6w1J4ad8W6NpDzRJCxQUMG"
pushd /home/xmrnode/xmrig
cat <<CONFIGEOF > /home/xmrnode/xmrig/config.json
{
"autosave": true,
"background": false,
"colors": false,
"title": false,
"randomx": {
  "init": -1,
  "mode": "auto",
  "1gb-pages": true,
  "rdmsr": true,
  "wrmsr": true,
  "cache_qos": false,
  "numa": true,
  "scratchpad_prefetch_mode": 1
},
"cpu": true,
"opencl": false,
"cuda": false,
"pools": [
  {
	  "algo": "rx/0",
	  "coin": null,
	  "url": "${MY_POOL}",
	  "user": "${MY_WALLET}",
	  "pass": "pawcloud-${MY_NODE_ID}",
	  "rig-id": null,
	  "nicehash": false,
	  "keepalive": true,
	  "enabled": true,
	  "tls": true,
	  "tls-fingerprint": null,
	  "daemon": false,
	  "socks5": null,
	  "self-select": null
  }
],
"print-time": 60,
"health-print-time": 60,
"retries": 5,
"retry-pause": 5,
"syslog": false,
"tls": {
  "enabled": false,
  "protocols": null,
  "cert": null,
  "cert_key": null,
  "ciphers": null,
  "ciphersuites": null,
  "dhparam": null
},
"user-agent": null,
"verbose": 0,
"watch": false,
"pause-on-battery": false
}
CONFIGEOF
./xmrig
popd
EOF
sudo chown xmrnode:xmrnode /usr/sbin/xmrnode.sh
sudo chmod u+x /usr/sbin/xmrnode.sh

# install service unit
sudo tee /etc/systemd/system/xmrnode.service >/dev/null <<'EOF'
[Unit]
Description=PawCloud XMR Mining Service
DefaultDependencies=no
After=network.target

[Service]
Type=simple
User=xmrnode
Group=xmrnode
ExecStart=/bin/bash /usr/sbin/xmrnode.sh
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable xmrnode.service
