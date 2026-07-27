#!/usr/bin/env bash
set -euo pipefail

: "${LARK_WEBHOOK_URL:?Secret LARK_BOT_WEB_HOOK_URL 未配置}"
: "${GH_TOKEN:?GH_TOKEN 未配置}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未配置}"
: "${PRODUCT_NAME:?PRODUCT_NAME 未配置}"
: "${VERSION:?VERSION 未配置}"
: "${RELEASE_KIND:?RELEASE_KIND 未配置}"
: "${UPGRADE_COMMAND:?UPGRADE_COMMAND 未配置}"
: "${DELIVERY_LABEL:?DELIVERY_LABEL 未配置}"
: "${DELIVERY_RESULT:?DELIVERY_RESULT 未配置}"

JENKINS_RESULT="${JENKINS_RESULT:-not_applicable}"
TAG="${RELEASE_TAG:-v${VERSION}}"
TAG_GLOB="${TAG_GLOB:-v*}"
CHANGE_PATH="${CHANGE_PATH:-.}"

if RELEASE_JSON="$(
  gh release view "$TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --json body,url 2>/dev/null
)"; then
  RELEASE_URL="$(jq -r '.url' <<< "$RELEASE_JSON")"
  RELEASE_NOTES="$(jq -r '.body // empty' <<< "$RELEASE_JSON")"
else
  git fetch --force --tags origin >/dev/null
  RELEASE_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/tree/${TAG}"
  TAGS="$(git tag --list "$TAG_GLOB" --sort=-v:refname)"
  PREVIOUS_TAG="$(printf '%s\n' "$TAGS" | grep -A1 -Fx "$TAG" | tail -n1 || true)"
  [[ "$PREVIOUS_TAG" == "$TAG" ]] && PREVIOUS_TAG=""

  if [[ -n "$PREVIOUS_TAG" ]]; then
    RELEASE_NOTES="$(
      git log "${PREVIOUS_TAG}..${TAG}" \
        --pretty=format:'- %s' \
        --no-merges \
        -- "$CHANGE_PATH"
    )"
  else
    RELEASE_NOTES="$(
      git log "$TAG" \
        -10 \
        --pretty=format:'- %s' \
        --no-merges \
        -- "$CHANGE_PATH"
    )"
  fi
fi

if [[ -z "${RELEASE_NOTES//[[:space:]]/}" ]]; then
  RELEASE_NOTES="- 发布 ${PRODUCT_NAME} ${TAG}"
else
  NOTE_LINES="$(printf '%s\n' "$RELEASE_NOTES" | awk 'END { print NR }')"
  RELEASE_NOTES="$(printf '%s\n' "$RELEASE_NOTES" | sed -n '1,15p')"
  if (( NOTE_LINES > 15 )); then
    RELEASE_NOTES+=$'\n- …更多内容请查看 Release'
  fi
fi

job_status() {
  case "$1" in
    success) echo "✅ 已完成" ;;
    failure) echo "❌ 失败" ;;
    cancelled) echo "⚠️ 已取消" ;;
    skipped) echo "⚠️ 未执行" ;;
    *) echo "⚠️ 状态未知" ;;
  esac
}

DELIVERY_STATUS="$(job_status "$DELIVERY_RESULT")"
case "$JENKINS_RESULT" in
  not_applicable) JENKINS_LINE="" ;;
  success) JENKINS_LINE=$'\n- Jenkins 工具链更新：✅ 更新任务已进入队列' ;;
  failure) JENKINS_LINE=$'\n- Jenkins 工具链更新：❌ 触发失败' ;;
  cancelled) JENKINS_LINE=$'\n- Jenkins 工具链更新：⚠️ 触发任务已取消' ;;
  skipped) JENKINS_LINE=$'\n- Jenkins 工具链更新：⚠️ 未触发' ;;
  *) JENKINS_LINE=$'\n- Jenkins 工具链更新：⚠️ 状态未知' ;;
esac

if [[ "$DELIVERY_RESULT" == "success" &&
  ( "$JENKINS_RESULT" == "success" || "$JENKINS_RESULT" == "not_applicable" ) ]]; then
  HEADER_TEMPLATE="green"
  TITLE="🚀 发布成功 · ${PRODUCT_NAME} ${TAG}"
else
  HEADER_TEMPLATE="yellow"
  TITLE="⚠️ 发布完成但同步异常 · ${PRODUCT_NAME} ${TAG}"
fi

PAYLOAD="$(
  jq -n \
    --arg title "$TITLE" \
    --arg template "$HEADER_TEMPLATE" \
    --arg notes "$RELEASE_NOTES" \
    --arg command "$UPGRADE_COMMAND" \
    --arg release_kind "$RELEASE_KIND" \
    --arg delivery_label "$DELIVERY_LABEL" \
    --arg delivery_status "$DELIVERY_STATUS" \
    --arg jenkins_line "$JENKINS_LINE" \
    --arg release_url "$RELEASE_URL" \
    --arg tag "$TAG" \
    '{
      msg_type: "interactive",
      card: {
        config: { wide_screen_mode: true },
        header: {
          template: $template,
          title: { tag: "plain_text", content: $title }
        },
        elements: [
          { tag: "markdown", content: ("**📝 更新内容**\n\n" + $notes) },
          { tag: "markdown", content: ("**⬆️ 升级方式**\n```bash\n" + $command + "\n```") },
          {
            tag: "markdown",
            content: (
              "**📦 发布状态**\n" +
              "- GitHub " + $release_kind + "：✅ 已创建\n" +
              "- " + $delivery_label + "：" + $delivery_status +
              $jenkins_line
            )
          },
          { tag: "hr" },
          { tag: "markdown", content: ("🔗 [" + $tag + "](" + $release_url + ")") }
        ]
      }
    }'
)"

RESPONSE="$(
  curl --silent --show-error --fail-with-body \
    --retry 2 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 30 \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$PAYLOAD" \
    "$LARK_WEBHOOK_URL"
)"

echo "Lark response: $RESPONSE"
OK="$(jq -r '((.code // .StatusCode) == 0)' <<< "$RESPONSE" 2>/dev/null || echo false)"
if [[ "$OK" != "true" ]]; then
  echo "::error::Lark 推送失败：$RESPONSE"
  exit 1
fi

echo "已推送 ${PRODUCT_NAME} ${TAG} 发布卡片"
