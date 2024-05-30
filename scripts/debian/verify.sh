#!/usr/bin/env bash
set -x

CHANNEL=umt-mainnet
VERSION=3.0.0-f872d85
CODENAME=bullseye

while [[ "$#" -gt 0 ]]; do case $1 in
  -c|--channel) CHANNEL="$2"; shift;;
  -v|--version) VERSION="$2"; shift;;
  -p|--package) PACKAGE="$2"; shift;;
  -m|--codename) CODENAME="$2"; shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

SCRIPT=' set -x \
    && export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    && echo installing mina \
    && apt-get update > /dev/null \
    && apt-get install -y lsb-release ca-certificates > /dev/null \
    && echo "deb [trusted=yes] http://packages.o1test.net $(lsb_release -cs) '$CHANNEL'" > /etc/apt/sources.list.d/mina.list \
    && apt-get update > /dev/null \
    && apt list -a mina-mainnet \
    && apt-get install -y --allow-downgrades '$PACKAGE=$VERSION' \
    && mina help \
    && mina version
    '

case $CODENAME in
  buster) DOCKER_IMAGE="debian:buster" ;;
  bullseye) DOCKER_IMAGE="debian:bullseye" ;;
  focal) DOCKER_IMAGE="ubuntu:focal" ;;
  *) echo "Unknown codename passed: $CODENAME"; exit 1;;
esac

echo "Testing packages on all images" \
  $& docker run --platform linux/amd64 -it --rm $DOCKER_IMAGE bash -c "$SCRIPT" \
  && echo && echo 'OK: ALL WORKED FINE!' || (echo 'KO: ERROR!!!' && exit 1)
