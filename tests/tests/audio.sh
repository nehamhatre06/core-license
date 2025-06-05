#!/bin/bash

BINDIR=$(dirname "$0")

main() {
        $BINDIR/audio_test aux
}

(
	flock -xn 9
	main
) 9>/run/audio.Lock
