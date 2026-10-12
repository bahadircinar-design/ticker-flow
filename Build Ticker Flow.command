#!/bin/bash
# Double-click this file in Finder to build and open Ticker Flow.
cd "$(dirname "$0")"
bash ./build.sh
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Ticker Flow is installed in your Applications folder (in your home folder)."
else
  echo "The build stopped with an error. Details are in build.log in this folder."
fi
read -n 1 -s -r -p "Press any key to close this window…"
