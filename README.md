# doubao

豆包技能仓库（公有）。当前收录一个技能：

## chenzhou-lookup · 郴州知识检索

连接「瀚天知识库」（https://www.ht-think.com）并在对话里检索郴州地方文献数字化资料：郴州历史、地理、人物、苏仙传说、湘南起义、地方志、方言民俗、古迹诗词等。

流程：检查连接 → 设备授权码登录（链接只在对话里给出，用户自己点，不自动跳转）→ 后台轮询授权状态 → 主题导航 / 条目检索 / 事实卡 / 成稿合规自检 → 积分不足时给充值链接（https://www.ht-think.com/portal/recharge）。

与旧版 `chenzhou-knowledge-search`（桌面端 PowerShell + 127.0.0.1 回调，网页端不可用）的区别：新版零第三方依赖、只用 Python 标准库脚本，**桌面端与网页端都可运行**；旧版已从本仓库删除。

目录结构：

```
chenzhou-lookup/
├── SKILL.md                        主流程与话术模板（含裸 URL 禁令、积分不足三段式）
├── scripts/
│   ├── h_auth.py                   设备授权登录 / status / wait / check / logout
│   └── h_api.py                    业务查询：search / get / unit / topics / topic / gate / stats
├── references/
│   ├── knowledge-map.md            知识地图总览（九大主题群 × 关联逻辑 × 导航纪律）
│   ├── 01-history.md … 09-urban-tourism.md   九个主题分片
│   ├── retrieval-playbook.md      分场景起词攻略
│   ├── examples.md                 典型问答样例（few-shot）
│   └── aliases.json               专题别名 / 同义扩展表
└── assets/templates/
    ├── summary-template.md         专题综述模板
    └── timeline-template.md        大事记年表模板
```

### 安装方式一：从 GitHub 仓库安装（目录型技能）

仓库地址：https://github.com/ht-think/doubao

技能目录：https://github.com/ht-think/doubao/tree/main/chenzhou-lookup

在豆包里说一句：

> 帮我安装 GitHub 上的 chenzhou-lookup

或在「技能 → 从 GitHub 安装」里填入上面的仓库地址（技能在 `chenzhou-lookup/` 子目录）。

### 安装方式二：平台上传技能包（ZIP）

本仓库为纯文本目录（不包含图标二进制）；如需带图标的 ZIP（`chenzhou-lookup-1.4.0.zip`，单根目录 `chenzhou-lookup/`、UTF-8 文件名、≤16 MB），请直接使用本地技能包文件在豆包技能控制台上传。

> 说明：GitHub 版与 ZIP 版内容一致，除 `assets/icon.png`（仅 ZIP 内提供）。

### 运行前提

- Python 3.8+，无第三方依赖。解释器优先 `python3`，不可用时回落 `python`。
- 首次使用需完成一次设备授权（浏览器登录瀚天知识库并点「确认授权」）；令牌落在 `~/.hantian-skill/token.json`（0600），不会出现在对话里。
- 网页端沙箱可能随会话重建，新会话通常需重新登录一次；桌面端令牌长期有效。
- 服务端点、令牌路径可用环境变量 `HT_SKILL_BASE`、`HT_SKILL_TOKEN` 覆盖。

### 退出码

`0` 成功｜`2` 未登录/令牌失效｜`4` 限流｜`5` 积分不足（已输出充值引导）｜`6` 参数/服务异常。

### 内容纪律（摘要）

- 用事实不用表达：任何连续 ≥27 字与库内正文一致即红线。
- 输出不出现条目编号、书目著录、馆藏规模数据。
- 库内有据与「联网所得」分开标注，不混装。
