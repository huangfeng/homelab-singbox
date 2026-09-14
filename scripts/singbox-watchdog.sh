#!/bin/sh
# singbox-watchdog.sh — 88.4 透明代理 watchdog
# 探测 88.4 本地 singbox 代理能否真正出外网(经7890代理访问generate_204)
# 连续失败 >= FAIL_THRESHOLD 次 → restart singbox; 再失败 → 通知88.10(触发Hermes修复)
# 由 cron 每分钟调用。OpenWrt/busybox ash 兼容。

# 日志大小保护: 超过 50MB 则截断保留最近 10000 行
MAX_LOG_SIZE=52428800
if [ -f /tmp/sing-box.log ]; then
  LOG_SIZE=$(wc -c < /tmp/sing-box.log 2>/dev/null || echo 0)
  if [ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]; then
    tail -n 10000 /tmp/sing-box.log > /tmp/sing-box.log.tmp && mv /tmp/sing-box.log.tmp /tmp/sing-box.log
  fi
fi

PROBE_URL="https://www.google.com/"
PROXY="http://127.0.0.1:7890"
TIMEOUT=10
FAIL_THRESHOLD=3
TEST_MODE="${TEST_MODE:-0}"
STATE_FILE="/tmp/singbox-watchdog.state"
LOG="/tmp/singbox-watchdog.log"
NOTIFY_HOST="192.168.88.10"
ALERT_FILE="/tmp/singbox-watchdog.alert"
SINGBOX_INIT="/etc/init.d/singbox"

ts() { date '+%F %T'; }
log() { echo "$(ts) $1" >> "$LOG"; }

fail_count=0
[ -f "$STATE_FILE" ] && fail_count=$(cat "$STATE_FILE" 2>/dev/null)

if [ "$TEST_MODE" = "1" ]; then
    PROBE_FAIL=1
else
    PROBE_FAIL=0
    if curl -s -m "$TIMEOUT" -x "$PROXY" -o /dev/null "$PROBE_URL" 2>/dev/null; then
        PROBE_FAIL=0
    else
        PROBE_FAIL=1
    fi
fi

if [ "$PROBE_FAIL" = "0" ]; then
    if [ "$fail_count" -ne 0 ]; then
        log "恢复: 代理出站成功, 清零连续失败"
        echo 0 > "$STATE_FILE"
    fi
    exit 0
fi

fail_count=$((fail_count + 1))
echo "$fail_count" > "$STATE_FILE"
log "探测失败(连续 $fail_count/$FAIL_THRESHOLD): 经7890访问 $PROBE_URL 不通"

if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
    exit 0
fi

if ! netstat -tln 2>/dev/null | grep -q ":7890"; then
    log "7890未监听 → singbox 崩溃, 执行重启"
else
    log "7890在监听但代理出站失败 → singbox 存活但节点失效, 执行重启"
fi

if [ "$TEST_MODE" = "1" ]; then
    log "TEST_MODE: 跳过重启, 模拟演练"
else
    "$SINGBOX_INIT" restart 2>>"$LOG"
    log "已执行 /etc/init.d/singbox restart"
fi

sleep 8
if curl -s -m "$TIMEOUT" -x "$PROXY" -o /dev/null "$PROBE_URL" 2>/dev/null; then
    log "重启后自愈: 代理出站恢复"
    echo 0 > "$STATE_FILE"
    exit 0
fi

log "重启后仍不通 → 写告警标记 $ALERT_FILE"
echo "$(ts) 88.4 singbox 重启后仍无法出外网, 待人工/Hermes修复" > "$ALERT_FILE"
touch /tmp/singbox-watchdog-FAIL.flag 2>/dev/null
echo 0 > "$STATE_FILE"
