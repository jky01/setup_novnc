#!/bin/bash
export DISPLAY=:99
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE

RES=$1
if [ -z "$RES" ]; then
    echo "Usage: $0 <width>x<height>"
    exit 1
fi

MODE="${RES}_60.00"

# Check if the mode exists in xrandr output
if ! xrandr | grep -q "$MODE"; then
    # Generate modeline
    WIDTH=$(echo $RES | cut -d'x' -f1)
    HEIGHT=$(echo $RES | cut -d'x' -f2)
    MODELINE=$(cvt $WIDTH $HEIGHT | grep Modeline | cut -d' ' -f3-)
    
    if [ -n "$MODELINE" ]; then
        xrandr --newmode "$MODE" $MODELINE 2>/dev/null || true
        xrandr --addmode screen "$MODE" 2>/dev/null || true
    fi
fi

xrandr --output screen --mode "$MODE"
