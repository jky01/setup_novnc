#!/bin/bash

# Terminate any existing instances
killall xfreerdp Xvfb x11vnc websockify autocutsel 2>/dev/null
sleep 1

# Define display number and clear Wayland environment variables
export DISPLAY=:99
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE

echo "Starting Xvfb on $DISPLAY..."
Xvfb :99 -screen 0 2560x1600x24 > /tmp/xvfb.log 2>&1 &
sleep 1

# Start autocutsel to synchronize clipboards between X11 and VNC cutbuffer
echo "Starting autocutsel..."
autocutsel -selection CLIPBOARD -fork
autocutsel -selection PRIMARY -fork

# Pre-register common resolutions and set default 1280x720
/home/aa/setup_novnc/set_resolution.sh 1280x720

# Start x11vnc server on :99
echo "Starting x11vnc..."
x11vnc -display :99 -forever -shared -rfbauth /home/aa/setup_novnc/vnc_passwd -rfbport 5900 -bg -o /tmp/x11vnc.log 2>&1

# Run xfreerdp connecting to local GNOME RDP
echo "Starting FreeRDP client to local RDP..."
# Loop in case it drops before the session is fully ready
(
  while true; do
    xfreerdp /v:127.0.0.1:3389 /u:aa /p:vncpassword /cert:ignore /dynamic-resolution /f +auto-reconnect +clipboard +decorations +fonts +menu-anims +window-drag >> /tmp/xfreerdp.log 2>&1
    sleep 2
  done
) &

# Run websockify for noVNC
echo "Starting websockify on port 6080..."
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &

echo "Bridge started successfully!"
wait

