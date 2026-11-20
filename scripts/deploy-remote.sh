#!/bin/sh
set -eu

deploy_env="${1:-}"
image_ref="${2:-}"
: "${SMOKE_BASE_URL:?SMOKE_BASE_URL is required}"
: "${DEPLOY_HOST:?DEPLOY_HOST is required}"
: "${DEPLOY_USER:?DEPLOY_USER is required}"
: "${DEPLOY_PATH:?DEPLOY_PATH is required}"
: "${DEPLOY_SSH_KEY_FILE:?DEPLOY_SSH_KEY_FILE is required}"

case "$deploy_env" in prod) ;; *) exit 64 ;; esac
printf '%s' "$DEPLOY_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'
printf '%s' "$DEPLOY_USER" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]*$'
printf '%s' "$DEPLOY_PATH" | grep -Eq '^/[A-Za-z0-9._/-]+$'
printf '%s' "$image_ref" | grep -Eq '^[A-Za-z0-9._/:@-]+$'
printf '%s' "$SMOKE_BASE_URL" | grep -Eq '^https?://[A-Za-z0-9._~:/?&=%+-]+$'

# ControlMaster/ControlPersist: 같은 배포 잡(job) 안에서 sync-deploy-files.sh ->
# apply-ci-s3-env-remote.sh -> deploy-remote.sh 순서로 SSH를 3번 따로 여는 대신, 첫 연결의
# TCP+SSH 핸드셰이크/인증을 최대 60초간 재사용한다. %C는 호스트/유저/포트 해시라 소켓 경로가
# 짧고 배포 대상별로 자동 분리된다.
ssh -i "$DEPLOY_SSH_KEY_FILE" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ControlMaster=auto \
  -o ControlPersist=60s \
  -o ControlPath=/tmp/limit-deploy-ssh-%C \
  "$DEPLOY_USER@$DEPLOY_HOST" \
  "cd '$DEPLOY_PATH' && bash scripts/deploy-blue-green.sh '$deploy_env' '$image_ref' '$SMOKE_BASE_URL'"
