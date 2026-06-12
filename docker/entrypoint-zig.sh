#!/bin/sh
case "${ROLE:-httpz}" in
  lb)  exec /app/floating_finch_lb ;;
  api) exec /app/floating_finch_api ;;
  *)   exec /app/floating_finch_zig ;;
esac
