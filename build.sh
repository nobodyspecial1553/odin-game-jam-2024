#!/bin/bash

DEBUG_FLAGS=('-o:minimal' '-debug')
RELEASE_FLAGS=('-o:speed' '-disable-assert')
FLAGS=("${DEBUG_FLAGS[@]}")

declare -i run=0

# Parse parameters
while [[ "$1" =~ ^- && ! "$1" == '--' ]]; do case "$1" in
	-release | -r )
		FLAGS=("${RELEASE_FLAGS[@]}")
		;;
	-run )
		run=1
		;;
esac; shift; done
if [[ "$1" == '--' ]]; then shift; fi

# Main executable
odin build . "${FLAGS[@]}" -out:Game

# Game Dynamic Lib
dyn_lib_success=$(odin build game/ -out:game_temp.so -build-mode:dynamic "${FLAGS[@]}")
if [[ $dyn_lib_success -ne 0 ]]; then
	exit "$dyn_lib_success"
fi
mv game_temp.so game.so # This was done for dynamic linking stuff, gonna write an Odin live-compile and reload thing some other day

if [[ $run -ne '0' ]]; then
	nohup konsole -e "./Game" > /dev/null 2>&1 &
fi
