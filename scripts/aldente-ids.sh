#!/bin/bash
# Lists AlDente's processes, launchd jobs and helper files, so fwhelperd can detect it (spec §2).
# Run with AlDente running. Uses sudo for the system launchd domain.
echo "== processes";          pgrep -fil aldente || echo "(none)"
echo "== launchd (system)";   sudo launchctl print system | grep -i dente || echo "(none)"
echo "== launchd (user)";     launchctl print "gui/$(id -u)" | grep -i dente || echo "(none)"
echo "== helper files";       ls -l /Library/PrivilegedHelperTools /Library/LaunchDaemons 2>/dev/null | grep -i dente || echo "(none)"
echo "== app bundle id";      mdls -name kMDItemCFBundleIdentifier /Applications/AlDente.app
