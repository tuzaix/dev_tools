#!/bin/bash

bin=`dirname "$0"`
bin=`cd $bin; pwd`

echo "install ffmpeg7"

sudo apt install snapd
sudo add-apt-repository ppa:ubuntuhandbook1/ffmpeg7
sudo apt update
sudo apt install ffmpeg
ffmpeg -version

echo "finished install ffmpeg7"
