#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="my-secrets.yaml"

if [ -f "$OUTPUT_FILE" ]; then
    echo "File $OUTPUT_FILE already exists. Remove it first to regenerate credentials."
    exit 1
fi

WEB_PASSWORD=$(openssl rand -hex 24)

cat > "$OUTPUT_FILE" <<EOF
credentials:
  webPassword: "${WEB_PASSWORD}"
EOF

echo "Generated $OUTPUT_FILE"
echo ""
echo "You can install from source with:"
echo "  helm upgrade --install pihole ./charts/pihole -f my-secrets.yaml"
