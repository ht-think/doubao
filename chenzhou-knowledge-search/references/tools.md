# 工具参考（7 个 MCP 工具）

调用顺序：`list_topics` → `search_units` → `unit_brief` / `get_unit` → `topic_brief` → `gate_check`；`library_stats` 仅用于确认服务可用。

## list_topics — 专题目录

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `domain` | string | — | 分类过滤，分类名或编号前缀（如 `地理·地名·区划`、`HT-GEO`） |

返回 `topics[]`（`topic_id`、名称、`domain`）与 `domains[]`。不含条目数、字数。

## search_units — 检索条目

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `query` | string | 是 | 2–6 字连续词组命中率最高；多词空格＝AND |
| `topic_id` | string | — | 限定专题 |
| `domain` | string | — | 限定分类（名称或编号） |
| `kind` | string | — | 体裁，如 `verse`（韵文）、`list`（名录） |
| `source_nature` | string | — | 史料性质 |
| `place` | string | — | 地域 |
| `channel` | string | — | 来源渠道 |
| `corroboration` | string | — | 佐证等级 |
| `limit` / `offset` | integer | — | 条数上限 / 分页偏移 |

返回 `hits[]`（`unit_id`、`unit_title`、`preview`、`preview_truncated`、`era_text`、`place`）。`preview` 是命中位置附近片段，不是文首。

## get_unit — 条目详情

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `unit_id` | string | 是 | 取自检索结果，不可自行构造 |
| `digest` | boolean | — | `true` 只返回结构性字段（题名、专题、地点、年代、字数） |

`full=true` 已停用，传入返回 `-32003`；需要脉络改用 `unit_brief`。

## unit_brief — 结构化事实卡

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `unit_id` | string | 是 | 条目编号 |
| `aspect` | string | — | `all`（默认）/`chrono` 只要年代/`outline` 只要层级/`figures` 只要数字事实 |

返回 `unit_title`、`topic`、`domain`、`place`、`era_text`、`doc_date_text`、`chars`、`years[]`、`figures[]`、`sections[]`、`structure`。不含任何正文句子。

## topic_brief — 专题覆盖概览

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `topic_id` | string | 二选一 | 取自 `list_topics` |
| `topic` | string | 二选一 | 可直接按名点名 |

返回 `topic`、`domain`、`scope`、`era_span`、`doc_date_span`、`places[]`、`sample_titles[]`。不返回条目数、字数等规模信息。

## gate_check — 文稿合规自检

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `draft` | string | 是 | 待检文稿 |
| `query` | string | 二选一 | 本次取材检索词，用于收窄比对范围 |
| `unit_ids` | string[] | 二选一 | 本次命中的条目编号，判定最准 |

返回 `verdict`（`pass`/`violation`/`not_effective`）、`severity`、`overlaps[]`、`hints[]`。不返回库内原文与阈值。`not_effective` 表示比对集过大或未给比对集——收窄 `query` 或改传 `unit_ids` 重试。

## library_stats — 可用状态

无参数，返回 `{"available": true|false}`。不返回规模信息。

## 失败码与处理

| 现象 | 含义 | 处理 |
|---|---|---|
| HTTP 401 / `unauthorized` | 授权缺失或过期 | 走 SKILL.md 流程 A 重新授权 |
| HTTP 402 / `insufficient_credits` | 额度不足 | 走流程 C，给 `https://www.ht-think.com/portal/recharge` |
| HTTP 429 / `rate_limited` | 调用过密 | 按 `Retry-After` 等几秒重试，不连发、不发充值链接 |
| `-32003` | 请求了已停用能力（如 `get_unit` 的 `full`） | 改用 `unit_brief` 或 `digest` |
| 空结果 | 库内暂无该主题 | 换更短的连续词组，或去掉过滤条件再试 |
