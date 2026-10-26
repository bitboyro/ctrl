#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
mkdir -p .local/test
javac --release 17 -d .local/test src/main/java/demo/App.java src/test/java/demo/GreetingTest.java
exec java -cp .local/test demo.GreetingTest
