#!/bin/bash
# Get dependency versions and Notion version from package.json
cd app
echo "Reading dependency versions and app version..."

# Try multiple approaches to find version
# First try from the original package.json
notion_version=$(node --print "try { require('./package.json').version || '' } catch(e) { '' }")

# If that fails, look in other locations
if [ -z "$notion_version" ]; then
  # Try to find version in the main js file
  echo "Trying to find version in JS files..."
  if [ -f ".webpack/main/index.js" ]; then
    notion_version=$(grep -o '"version":"[^"]*"' .webpack/main/index.js | head -1 | cut -d'"' -f4)
  fi
  
  # Try to find in renderer file if exists
  if [ -z "$notion_version" ] && [ -f ".webpack/renderer/index.js" ]; then
    notion_version=$(grep -o '"version":"[^"]*"' .webpack/renderer/index.js | head -1 | cut -d'"' -f4)
  fi
  
  # If still not found, check any package.json files in the directories
  if [ -z "$notion_version" ]; then
    echo "Searching for version in other package.json files..."
    found_version=$(find . -name "package.json" -exec grep -l "\"version\"" {} \; | xargs grep "\"version\"" | head -1)
    notion_version=$(echo "$found_version" | grep -o '"version": "[^"]*"' | cut -d'"' -f4)
  fi
fi

# If still not found, fall back to a default version
if [ -z "$notion_version" ]; then
  echo "Could not detect Notion version, using date-based version"
  notion_version=$(date +"%Y.%m.%d")
fi

echo "Using Notion version: $notion_version"

# Determine dependency versions
if [ -f "package.json" ]; then
  # Try to get versions safely
  sqlite=$(node --print "try { require('./package.json').dependencies['better-sqlite3'] } catch(e) { 'unknown' }")
  electron=$(node --print "try { require('./package.json').devDependencies['electron'] } catch(e) { 'unknown' }")
  
  # If versions are unknown, try to get them from any package.json present
  if [ "$sqlite" == "unknown" ] || [ "$electron" == "unknown" ]; then
    echo "Searching for dependency versions in node_modules..."
    find . -name "package.json" -exec grep -l "better-sqlite3\|electron" {} \; | head -1 | xargs cat > /tmp/pkg.json
    sqlite=$(node --print "try { require('/tmp/pkg.json').dependencies['better-sqlite3'] || '7.4.3' } catch(e) { '7.4.3' }")
    electron=$(node --print "try { require('/tmp/pkg.json').devDependencies['electron'] || '25.8.0' } catch(e) { '25.8.0' }")
  fi
else
  # Default versions if package.json doesn't exist
  echo "No package.json found, using default versions"
  sqlite="7.4.3"
  electron="25.8.0"
fi

# Get the current Electron version from the extracted app
echo "Detected Electron version from Notion app: $electron"

# Check for the latest Electron version
echo "Checking latest Electron version..."
latest_electron=$(npm view electron version)
echo "Latest Electron version available: $latest_electron"

# Compare versions and decide which to use
if [ "$(printf '%s\n' "$latest_electron" "$electron" | sort -V | head -n1)" = "$electron" ]; then
  echo "Detected Electron version is older than latest. Upgrading to latest: $latest_electron"
  electron="$latest_electron"
else
  echo "Using detected Electron version: $electron"
fi

# Get corresponding Chromium version for the selected Electron
chromium_version=$(npm view electron@$electron chromium)
echo "Using Chromium version: $chromium_version (from Electron $electron)"

echo "Using sqlite version: $sqlite, electron version: $electron"

# Create directories for native modules
mkdir -p node_modules/better-sqlite3/build/Release
cd ..

echo "Downloading better-sqlite3..."
npm pack better-sqlite3@$sqlite
tar --extract --file better-sqlite3-*.tgz
