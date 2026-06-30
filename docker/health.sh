#!/bin/bash
#  HEALTHCHECK script for the MCP help server container.

exec &> health.log

check()
{ auth=
  if [ -r health.auth ]; then
     auth="$(cat health.auth)"
  fi
  curl --fail -s --retry 3 --max-time 5 \
       http://localhost:3410/mcp/health
  return $?
}

stop()
{ pid=1
  echo "Health check failed.  Killing swish with SIGTERM"
  kill -s TERM 1 $pid
  timeout 10 tail --pid=$pid -f /dev/null
  if [ $? == 124 ]; then
      echo "Gracefull termination failed.  Trying QUIT"
      kill -s QUIT $pid
      timeout 10 tail --pid=$pid -f /dev/null
      if [ $? == 124 ]; then
	   echo "QUIT failed.  Trying KILL"
	   kill -s KILL $pid
      fi
  fi
  echo "Done"
}

starting()
{ if [ -f epoch ]; then
      epoch=$(cat epoch)
      running=$(($(date "+%s") - $epoch))
      [ $running -lt 60 ] || return 1
  fi
  echo "Starting, so not killing"
  return 0
}

check || starting || stop
