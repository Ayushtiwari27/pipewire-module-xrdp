#!/bin/sh

if ! command -v pw-cli >/dev/null; then
    echo "pw-cli not found, exiting"
    exit 0
fi

if ! pw-cli quit 2>/dev/null; then
    echo "pipewire server is not running, exiting"
    exit 0
fi

status=0

if [ -n "$SYNCCAST_SESSION" -a -n "$SYNCCAST_SOCKET_PATH" ]; then
    # Destroy synccast sink and source if they already exist
    OBJECT_IDS=$(pw-cli ls Node | sed -e "s/^[^a-z]//" | grep -w "^id" | sed -e "s/^[^0-9]*//" -e "s/[^0-9]/-/" | cut -d- -f1)
    for OBJECT_ID in $OBJECT_IDS; do
        NODE_NAME=$(pw-cli info $OBJECT_ID | grep -w "node\.name" | cut -d\" -f2)
        if [ "$NODE_NAME" = "synccast-sink" -o "$NODE_NAME" = "synccast-source" ]; then
            pw-cli destroy $OBJECT_ID
        fi
    done

    # Kill module, if it is working
    #PID=$(ps -u $(id -u) -o pid,ruser,cmd | grep libpipewire-module-synccast | grep -v grep | sed -e 's/^ *//' | cut -d' ' -f1)
    #if [ -n "$PID" ]; then
    #    kill -HUP $PID
    #fi

    if [ "$1" = "-d" ]; then exit; fi

    export PIPEWIRE_LOG_SYSTEMD=false
    if [ "$1" = "-l" ]; then
        # debug:  0:none, 1:error, 2:warnings, 3:info, 4:debug, 5:trace
        if [ -n "$2" ]; then
            export PIPEWIRE_DEBUG=$2
        else
            export PIPEWIRE_DEBUG=3
        fi
        export PIPEWIRE_LOG=/tmp/synccast_pipewire_$(echo $DISPLAY | sed -e 's/^[^0-9]//' | cut -d. -f1).log
    else
        export PIPEWIRE_DEBUG=1
    fi

    # Reload modules
    PWCLI=pw-cli
    if [ "$(pipewire --version | sed -e "s/[ a-zA-Z]//g" | tail -n 1)" = "0.3.58" ]; then
        PWCLI=$(dirname $0)/pw-cli_0358_mod
    fi

    QUANTUMVAL=2048
    QUANTUMVAL2=$(($QUANTUMVAL * 2))

    # enable both synccast-sink ans synccast-source
    $PWCLI -m -d load-module libpipewire-module-synccast sink.node.latency=$QUANTUMVAL sink.stream.props={node.name=synccast-sink} source.stream.props={node.name=synccast-source} > /dev/null &
    # enable synccast-sink only
    # $PWCLI -m -d load-module libpipewire-module-synccast sink.node.latency=$QUANTUMVAL sink.stream.props={node.name=synccast-sink} > /dev/null &
    # enable synccast-source only
    # $PWCLI -m -d load-module libpipewire-module-synccast source.stream.props={node.name=synccast-source} > /dev/null &

    sleep 1

    #increase the quantum(latency) value to reduce choppy audio
    # from PipeWire debian
    # https://wiki.debian.org/PipeWire#choppy_audio_on_systems_with_high_load
    pw-metadata -n settings 0 clock.force-quantum $QUANTUMVAL >/dev/null
    pw-metadata -n settings 0 default.clock.force-quantum $QUANTUMVAL2 >/dev/null
    pw-metadata -n settings 0 default.clock.quantum $QUANTUMVAL2 >/dev/null
    pw-metadata -n settings 0 default.clock.min-quantum $QUANTUMVAL2 >/dev/null
    # set default sample rate = 44100, because xrdp uses it.
    pw-metadata -n settings 0 default.clock.rate 44100 >/dev/null

    if command -v pactl >/dev/null; then
        pactl set-default-sink synccast-sink
        pactl set-default-source synccast-source
    fi
fi

exit $status
