#!/bin/bash

if [ -d snapshots ]; then
  rm -rf snapshots
fi

if [ -d privatedb ]; then
  rm -rf privatedb
fi

if [ -f keys.txt ]; then
  rm keys.txt
fi

if [ -f inx_keys.txt ]; then
  rm inx_keys.txt
fi

if [ -f coo_key_1.txt ]; then
  rm coo_key_1.txt
fi

if [ -f coo_key_2.txt ]; then
  rm coo_key_2.txt
fi

count=`ls -1 *.out 2>/dev/null | wc -l`
if [ $count != 0 ]; then
  rm *.out
fi