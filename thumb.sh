#!/bin/bash

if [[ -n "$4" ]]; then
    curl -H "Authorization: Basic $1" -H "Range: bytes:0-3000000" $2 | ffmpeg -i pipe: -t 00:00:02 -vf "scale=-1:240" -loop 0 "./public/thumb/$3"
else
    curl -H "Authorization: Basic $1" -H "Range: bytes:0-3000000" $2 | ffmpeg -i pipe: -vf "scale=-1:240" "./public/thumb/$3"
fi