#!/usr/bin/env bash
# WhisperFlow REA Assessment Test Harness
set -euo pipefail

echo "=========================================================="
echo "   WhisperFlow REA Automated Assessment Suite            "
echo "=========================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "📁 Project root: $PROJECT_ROOT"
echo "🔍 Validating REA structure..."

required_dirs=(
    "$PROJECT_ROOT/REA/research"
    "$PROJECT_ROOT/REA/architecture"
    "$PROJECT_ROOT/REA/execution/audio"
    "$PROJECT_ROOT/REA/execution/speech"
    "$PROJECT_ROOT/REA/execution/cleanup"
    "$PROJECT_ROOT/REA/execution/injection"
    "$PROJECT_ROOT/REA/execution/coordinator"
    "$PROJECT_ROOT/REA/assessment"
)

for dir in "${required_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
        echo "  ✅ Found: ${dir#$PROJECT_ROOT/}"
    else
        echo "  ❌ Missing: ${dir#$PROJECT_ROOT/}"
        exit 1
    fi
done

echo ""
echo "⚙️  Verifying Rust implementation modules syntax..."
if command -v rustc &> /dev/null; then
    echo "  Checking REA/execution/audio/ring_buffer.rs..."
    rustc --crate-type lib --emit=metadata "$PROJECT_ROOT/REA/execution/audio/ring_buffer.rs" -o /tmp/ring_buffer_test.rmeta
    echo "  Checking REA/execution/cleanup/fast_cleaner.rs..."
    rustc --crate-type lib --emit=metadata "$PROJECT_ROOT/REA/execution/cleanup/fast_cleaner.rs" -o /tmp/fast_cleaner_test.rmeta
    echo "  Checking REA/execution/coordinator/shortcut_coordinator.rs..."
    rustc --crate-type lib --emit=metadata "$PROJECT_ROOT/REA/execution/coordinator/shortcut_coordinator.rs" -o /tmp/shortcut_coordinator_test.rmeta
    rm -f /tmp/*_test.rmeta
    echo "  ✅ All standalone Rust modules verified cleanly!"
else
    echo "  ⚠️ rustc not found in PATH; skipping standalone rust compilation check."
fi

echo ""
echo "⚙️  Verifying Swift implementation modules syntax..."
if command -v swiftc &> /dev/null; then
    echo "  Checking REA/execution/audio/RingBuffer.swift..."
    swiftc -typecheck "$PROJECT_ROOT/REA/execution/audio/RingBuffer.swift"
    echo "  Checking REA/execution/injection/ax_injector.swift..."
    swiftc -typecheck "$PROJECT_ROOT/REA/execution/injection/ax_injector.swift"
    echo "  ✅ All standalone Swift modules verified cleanly!"
else
    echo "  ⚠️ swiftc not found in PATH; skipping standalone swift compilation check."
fi

echo ""
echo "=========================================================="
echo "   All REA verification checks passed successfully!       "
echo "=========================================================="
