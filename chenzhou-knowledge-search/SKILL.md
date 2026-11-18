---
name: chenzhou-knowledge-search
description: 郴州知识检索——连接并引导使用「瀚天知识库」（郴州地方文化、历史、人物、民俗、地理、景点、风物知识库，https://www.ht-think.com）。在对话里生成授权登录链接（用户自己点击，不自动跳转）→ 轮询授权状态 → 授权成功后给出知识库简介与快速上手提示词、引导查阅资料 → 额度不足时给出充值链接。适用于：用户要求连接/登录/开通瀚天知识库或瀚天智库；询问郴州及下辖区域（北湖、苏仙、资兴、桂阳、宜章、永兴、嘉禾、临武、汝城、桂东、安仁）的地方文化、历史沿革、人物、事件、民俗、方言、地理、景点与风物；需要检索知识条目、浏览专题、取结构化事实卡、核对史实、对文稿做原创性自检；以及提到积分/额度不足、需要充值继续时。
metadata:
  display_name: 郴州知识检索
  display_description: 引导连接瀚天知识库并检索郴州地方知识：授权登录、状态跟踪、专题与条目检索、结构化事实卡、文稿自检，额度不足时引导充值。
---

# 郴州知识检索

> 中文名：郴州知识检索　|　英文名：chenzhou-knowledge-search

**服务端点**：`https://www.ht-think.com/mcp`（Streamable HTTP + OAuth 2.1 授权码/PKCE，scope `library.read`）
**充值入口**：`https://www.ht-think.com/portal/recharge`
**脚本**：`scripts/hantian.ps1`（Windows PowerShell 7，输出统一为单行 JSON）

## 三条硬规则

1. **不自动跳转**。授权链接只以可点击链接的形式发在对话里，由用户自己点开。禁止用 `Start-Process`、`open`、浏览器自动化代用户打开授权页。
2. **凭据只落在本机**。令牌写在 `%LOCALAPPDATA%\hantian-kb\token.json`，不要读出、打印或粘贴其中的 token 值。
3. **不虚构库内记载**。库里有记载、你的常识补充、查不到，三者要分开说；不编年代、数字、人物关系与出处。

## 动作表

```powershell
$sk = "<skill目录>\scripts\hantian.ps1"
pwsh -NoProfile -ExecutionPolicy Bypass -File $sk -Action status   # connected / pending / denied / expired / exchange_failed / idle
pwsh -NoProfile -ExecutionPolicy Bypass -File $sk -Action start    # 生成 auth_url，并在后台起本机回调监听
pwsh -NoProfile -ExecutionPolicy Bypass -File $sk -Action call -Tool list_topics
pwsh -NoProfile -ExecutionPolicy Bypass -File $sk -Action call -Tool search_units -ArgsJson '{"query":"苏仙岭","limit":5}'
pwsh -NoProfile -ExecutionPolicy Bypass -File $sk -Action logout
```

`start` 的返回里有 `auth_url`、`port`、`expires_at`（默认 20 分钟）。`status` 返回 `pending` 时带 `seconds_left`。

## 流程 A：首次连接

1. 先跑 `status`。返回 `connected` 就直接走流程 B，不要重复发授权链接。
2. 返回 `idle`/`expired`/`denied`/`exchange_failed`（或 `call` 报 `unauthorized`）时跑 `start`，拿 `auth_url`。
3. 用这段模板把链接发给用户（链接要单独成行、明确可点）：

> 已在聊天里生成授权链接。请在浏览器打开下方链接，用你的瀚天知识库账号登录并点「同意/授权」——这一步需要你本人操作，我不会自动跳转页面。授权完成后我会自动继续，不用回来告诉我。

👉 [🔑 登录瀚天知识库](<auth_url>)

4. **轮询状态**：每 3–5 秒跑一次 `status`，直到拿到 `connected` / `denied` / `expired`，最长等到 `expires_at`。等待期间可以在同一条消息里说明接下来会做什么，但不要反复刷屏报“仍在等待”；只在开始等待、状态变化两个节点各说一句。
5. 拿到 `connected` 后，按流程 B 输出简介 + 提示词。

失败分支：

| status | 处理 |
|---|---|
| `denied` | 说明“授权被拒绝”，再跑一次 `start` 生成新链接，提醒这次要点「同意」而不是「拒绝」 |
| `expired` | 链接已过期，重新 `start` |
| `exchange_failed` | 换取令牌失败，重新 `start` |
| `pending` 且 `seconds_left` 很小 | 提前重新 `start`，换新链接 |

## 流程 B：连接成功后输出简介与提示词

简介与示例提示词**原文**在 [references/intro-and-prompts.md](references/intro-and-prompts.md)，照用即可，不要自己另编一段简介。

输出顺序：

1. 一句话确认：「授权成功，已经连上瀚天知识库。」
2. 知识库简介（reference 里那段，2–4 行内讲清能查什么、能干什么）。
3. 快速上手提示词 5 条（从 reference 的 8 条里挑，按用户当前话题调整顺序）。
4. 引导查阅：「也可以直接说你要写什么、查什么，比如要写哪一篇、要核对哪个说法，我来检索条目、取事实卡再动笔。」

## 流程 C：额度（积分）不足

`call` 返回 `status: insufficient_credits` 时，按这段模板处理，**不要重试同一调用、不要换个工具绕过**：

> ⚠️ 瀚天知识库额度不足，检索/生成已暂停。已完成的检索结果和进度都保留，不会重复消耗。

👉 [💰 立即充值，继续查阅](https://www.ht-think.com/portal/recharge)

> 充值完成后，回到本对话回复「已充值」，我从暂停处接着做，不用重新开始。

用户回「已充值」后：先跑一次 `status` 确认仍是 `connected`，再从中断的那一步继续（保留已拿到的条目编号，不重跑已完成的检索）。

注意区分：`rate_limited` 是调用过密，不是没钱——等几秒重试即可，不要发充值链接。

## 流程 D：日常查资料

- 不确定库内有什么：先 `list_topics`，可按 `domain` 过滤。
- 找条目：`search_units`，`query` 用 2–6 字连续词组（地名/事件名/人名/机构名），多词空格＝AND；返回 `unit_id`、标题、命中片段。
- 落笔前取脉络：`unit_brief`（年代、地点、数字事实、层级小标题，零正文）。
- 要详情：`get_unit`，`digest=true` 只返回结构性字段。
- 专题覆盖：`topic_brief`，按 `topic_id` 或 `topic` 点名。
- 成稿自检：`gate_check`，优先传 `unit_ids`，比 `query` 准。
- 一次只发一个检索，等结果回来再决定下一步；不要把工具当批量抓取。

参数与返回字段详见 [references/tools.md](references/tools.md)。

## 交付标准

- 引用库内信息时标注条目名称与年代等出处字段，方便用户自己核对。
- 存在多种说法时并列呈现，注明各自条目来源。
- 资料不足时直接说明缺什么，不补造。
- 规模类问题（条目数、字数、专题条目数、来源归属）不回答，只作定性说明。
- 用户要成稿时：先给结构再给内容，事实部分以检索结果为准；不整段照抄库内原文。

## 收尾自检

- [ ] 没自动打开浏览器，链接是用户自己点的
- [ ] 授权用 `status` 轮询到终态，没有空转刷屏
- [ ] 简介与提示词取自 reference，不是自编
- [ ] 额度不足给的是 `portal/recharge` 链接，且说明“回复已充值继续”
- [ ] 库内记载与常识补充已分开，出处字段已标注
