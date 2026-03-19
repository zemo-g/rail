#!/bin/bash
# daily_deploy.sh — Rebuild and deploy both ledatic.org pages
# Called by com.ledatic.site-deploy at 06:00 daily
cd /Users/ledaticempire/projects/rail

echo "=== $(date) ==="

# Main site
echo "Building main site..."
./rail_native run tools/deploy/gen_site.rail 2>&1

# System page
echo "Building system page..."
./rail_native run tools/deploy/gen_mission_control.rail 2>&1
./rail_native run tools/deploy/cf_deploy.rail /tmp/mission_control.html system.html 2>&1

echo "Done."
