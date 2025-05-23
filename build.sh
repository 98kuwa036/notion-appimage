#!/bin/bash
set -e  # Exit on error

# Check Node.js version
echo "Checking Node.js version..."
node_version=$(node --version | cut -d 'v' -f2)
node_major_version=$(echo $node_version | cut -d '.' -f1)

if [ "$node_major_version" -lt 14 ]; then
  echo "Warning: Your Node.js version is too old. This script requires Node.js 14 or higher."
  echo "Attempting to use nvm to switch to a compatible version..."
  
  # Try to use nvm if available
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    source "$NVM_DIR/nvm.sh"
    nvm use 16 || nvm install 16
    node_version=$(node --version)
    echo "Switched to Node.js $node_version using nvm"
  else
    echo "nvm not found. Please install Node.js 14 or higher manually."
    exit 1
  fi
else
  echo "Using Node.js $node_version"
fi

# Create build directory if it doesn't exist
mkdir -p build
cd build

echo "Downloading Notion installer..."
curl --location https://www.notion.so/desktop/windows-arm/download --output installer

echo "Extracting app files..."
7z e installer \$PLUGINSDIR/app-64.7z
7z e app-64.7z resources/app.asar

# Create directories for unpacked files
mkdir -p app.asar.unpacked/node_modules/better-sqlite3/build/Release
mkdir -p app.asar.unpacked/node_modules/native-progress-bar/build/Release
mkdir -p app.asar.unpacked/node_modules/node-mac-window/build/Release

# Create empty dummy files to satisfy the extraction
touch app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node
touch app.asar.unpacked/node_modules/better-sqlite3/build/Release/test_extension.node
touch app.asar.unpacked/node_modules/native-progress-bar/build/Release/progress_bar.node
touch app.asar.unpacked/node_modules/node-mac-window/build/Release/mac_window.node

echo "Extracting app.asar..."
npx --yes @electron/asar extract app.asar app

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

echo "Rebuilding better-sqlite3..."
cd package
npm install
echo "Running node-gyp rebuild..."
npx node-gyp rebuild --target=$electron --arch=x64 --dist-url=https://nodejs.org/dist

echo "Copying built module..."
cp build/Release/better_sqlite3.node ../app/node_modules/better-sqlite3/build/Release/
cd ..

cd app

# Create or update package.json with required fields and dynamic version
echo "Creating package.json for electron-builder..."
cat > package.json << EOF
{
  "name": "notion",
  "version": "$notion_version",
  "description": "Notion AppImage",
  "main": ".webpack/main/index.js",
  "author": "Notion",
  "license": "UNLICENSED",
  "dependencies": {
    "better-sqlite3": "$sqlite"
  },
  "devDependencies": {
    "electron": "$electron"
  },
  "build": {
    "appId": "notion.id",
    "productName": "Notion",
    "files": [
      "**/*",
      "!**/node_modules/*/{CHANGELOG.md,README.md,README,readme.md,readme}",
      "!**/node_modules/*/{test,__tests__,tests,powered-test,example,examples}",
      "!**/node_modules/*.d.ts",
      "!**/node_modules/.bin"
    ],
    "extraResources": [
      {
        "from": "node_modules/better-sqlite3/build/Release/",
        "to": "app.asar.unpacked/node_modules/better-sqlite3/build/Release/",
        "filter": ["*.node"]
      }
    ],
    "linux": {
      "category": "Office",
      "target": [
        {
          "target": "AppImage",
          "arch": [
            "arm-aarch64"
          ]
        }
      ]
  }
}
EOF

# Check if .webpack/main/index.js exists before modifying
if [ -f ".webpack/main/index.js" ]; then
  echo "Patching platform detection and auto update..."
  sed -i '
    s/"win32"===process.platform/(true)/g
    s/_.Store.getState().app.preferences?.isAutoUpdaterDisabled/(true)/g
  ' .webpack/main/index.js
  
  # Add patch to force using the latest Electron/Chromium
  echo "Patching to use latest Electron/Chromium..."
  # This is a simple patch - may need to be adjusted for specific Notion versions
  electron_version_json="{\"electron\":\"$electron\",\"chromium\":\"$chromium_version\"}"
  sed -i "s/const\s*electronVersion\s*=\s*[^;]*;/const electronVersion = $electron_version_json;/g" .webpack/main/index.js 2>/dev/null || echo "Could not patch electron version reference"
else
  echo "Warning: .webpack/main/index.js not found, skipping patches"
fi

# Create a dummy icon.png if needed
mkdir -p ../../assets
if [ ! -f "../../assets/icon.png" ]; then
  echo "Creating a dummy icon.png..."
  convert -size 256x256 xc:white -fill black -draw "text 30,125 'Notion'" ../../assets/icon.png 2>/dev/null || echo "Warning: Could not create icon (ImageMagick not installed), using blank file"
  if [ ! -f "../../assets/icon.png" ]; then
    # If convert fails, create an empty file
    touch ../../assets/icon.png
  fi
fi
cp ../../assets/icon.png .

# Log the final versions being used
echo "==================================="
echo "Building Notion AppImage with:"
echo "Notion version: $notion_version"
echo "Electron version: $electron"
echo "Chromium version: $chromium_version"
echo "SQLite version: $sqlite"
echo "==================================="

echo "Running electron-builder..."
npx --yes electron-builder --linux AppImage --config.npmRebuild=false
