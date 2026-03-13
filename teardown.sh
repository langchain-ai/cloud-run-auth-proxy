#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Tear down LangSmith Auth Proxy from Cloud Run
#
# Only deletes resources that have the managed-by=langsmith-auth-proxy-deploy
# label, so it won't touch pre-existing resources with the same names.
#
# Usage:
#   export PROJECT_ID=my-gcp-project
#   ./teardown.sh
###############################################################################

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-langsmith-auth-proxy}"
SECRET_NAME="${SECRET_NAME:-llm-provider-api-key}"
SERVICE_NAME="${SERVICE_NAME:-langsmith-auth-proxy}"

EXPECTED_LABEL="langsmith-auth-proxy-deploy"

# Check if a resource has our managed-by label.
# Returns 0 (true) if label matches, 1 (false) otherwise.
has_our_label() {
  local actual_label="$1"
  [[ "$actual_label" == "$EXPECTED_LABEL" ]]
}

echo "=== LangSmith Auth Proxy - Teardown ==="
echo "Project:    $PROJECT_ID"
echo "Region:     $REGION"
echo "Only removing resources labeled managed-by=$EXPECTED_LABEL"
echo ""

# --- Step 1: Delete Cloud Run service ---
echo "--- Step 1: Delete Cloud Run service ---"
if gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  LABEL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format='value(metadata.labels.managed-by)' 2>/dev/null || true)
  if has_our_label "$LABEL"; then
    gcloud run services delete "$SERVICE_NAME" \
      --region="$REGION" \
      --project="$PROJECT_ID" \
      --quiet
    echo "Deleted Cloud Run service: $SERVICE_NAME"
  else
    echo "SKIPPED: Service $SERVICE_NAME exists but is not managed by us (label: '${LABEL:-<none>}')"
  fi
else
  echo "Service $SERVICE_NAME does not exist (skipping)"
fi
echo ""

# --- Step 2: Delete container images from Artifact Registry ---
echo "--- Step 2: Delete container images ---"
IMAGE_PREFIX="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"

# Only delete images if the repository itself has our label
REPO_LABEL=""
if gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  REPO_LABEL=$(gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" \
    --format='value(labels.managed-by)' 2>/dev/null || true)
fi

if has_our_label "$REPO_LABEL"; then
  for image in auth-proxy-ext-authz auth-proxy-envoy; do
    FULL_IMAGE="${IMAGE_PREFIX}/${image}"
    echo "Deleting image: $image"
    gcloud artifacts docker images delete "$FULL_IMAGE" \
      --project="$PROJECT_ID" \
      --delete-tags \
      --quiet 2>/dev/null || echo "  (no images found for $image)"
  done
else
  echo "SKIPPED: Repository $REPOSITORY is not managed by us (label: '${REPO_LABEL:-<none>}')"
fi
echo ""

# --- Step 3: Delete Artifact Registry repository ---
echo "--- Step 3: Delete Artifact Registry repository ---"
if gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  REPO_LABEL=$(gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" \
    --format='value(labels.managed-by)' 2>/dev/null || true)
  if has_our_label "$REPO_LABEL"; then
    gcloud artifacts repositories delete "$REPOSITORY" \
      --location="$REGION" \
      --project="$PROJECT_ID" \
      --quiet
    echo "Deleted repository: $REPOSITORY"
  else
    echo "SKIPPED: Repository $REPOSITORY is not managed by us (label: '${REPO_LABEL:-<none>}')"
  fi
else
  echo "Repository $REPOSITORY does not exist (skipping)"
fi
echo ""

# --- Step 4: Delete Secret Manager secret ---
echo "--- Step 4: Delete Secret Manager secret ---"
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
  SECRET_LABEL=$(gcloud secrets describe "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --format='value(labels.managed-by)' 2>/dev/null || true)
  if has_our_label "$SECRET_LABEL"; then
    gcloud secrets delete "$SECRET_NAME" \
      --project="$PROJECT_ID" \
      --quiet
    echo "Deleted secret: $SECRET_NAME"
  else
    echo "SKIPPED: Secret $SECRET_NAME is not managed by us (label: '${SECRET_LABEL:-<none>}')"
  fi
else
  echo "Secret $SECRET_NAME does not exist (skipping)"
fi

echo ""
echo "=== Teardown Complete ==="
