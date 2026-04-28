#!/usr/bin/env bash
LGSM=/home/pzserver/pzserver

send_msg() {
    for i in {1..5}; do
        cd /home/pzserver && $LGSM send "servermsg \"$1\"" &
    done
    wait
}

send_msg "[NOTICE] Server going down in 2 minutes for nightly update and restart."
sleep 60
send_msg "[NOTICE] Server going down in 1 minute. Finish what you are doing."
sleep 50
send_msg "[NOTICE] Going down now. Back in a moment."
sleep 10

# flush world save before stopping so nothing gets wiped
cd /home/pzserver && $LGSM send "save"
sleep 15

systemctl stop pzserver
sudo -u pzserver bash -c 'cd /home/pzserver && ./pzserver update'
systemctl start pzserver
